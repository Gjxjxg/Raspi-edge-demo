#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os, io, time, json, threading
from typing import Dict, Any
import paho.mqtt.client as mqtt
from PIL import Image
import torch
import torchvision.models as M

BROKER_HOST = os.getenv("BROKER_HOST", "broker")
BROKER_PORT = int(os.getenv("BROKER_PORT", "1883"))
MODEL_NAME = os.getenv("MODEL_NAME", "mv3_small").lower()
THREADS = int(os.getenv("TORCH_THREADS", "4"))
CLIENT_ID = os.getenv("CLIENT_ID", "edge-infer")
CLEANUP_SEC = int(os.getenv("TASK_CLEANUP_SEC", "120"))

def load_model(name: str):
    name = name.lower()
    if name in ["mv3_small","mobilenet_v3_small"]:
        w = M.MobileNet_V3_Small_Weights.IMAGENET1K_V1
        model = M.mobilenet_v3_small(weights=w); preprocess = w.transforms()
    elif name in ["mv3_large","mobilenet_v3_large"]:
        w = M.MobileNet_V3_Large_Weights.IMAGENET1K_V2
        model = M.mobilenet_v3_large(weights=w); preprocess = w.transforms()
    elif name in ["mv2","mobilenet_v2"]:
        w = M.MobileNet_V2_Weights.IMAGENET1K_V1
        model = M.mobilenet_v2(weights=w); preprocess = w.transforms()
    elif name in ["eff0","efficientnet_b0"]:
        w = M.EfficientNet_B0_Weights.IMAGENET1K_V1
        model = M.efficientnet_b0(weights=w); preprocess = w.transforms()
    elif name in ["eff2","efficientnet_b2"]:
        w = M.EfficientNet_B2_Weights.IMAGENET1K_V1
        model = M.efficientnet_b2(weights=w); preprocess = w.transforms()
    elif name in ["eff4", "efficientnet_b4"]:
        w = M.EfficientNet_B4_Weights.IMAGENET1K_V1
        model = M.efficientnet_b4(weights=w); preprocess = w.transforms()
    elif name in ["eff5", "efficientnet_b5"]:
        w = M.EfficientNet_B5_Weights.IMAGENET1K_V1
        model = M.efficientnet_b5(weights=w); preprocess = w.transforms()
    elif name in ["eff6", "efficientnet_b6"]:
        w = M.EfficientNet_B6_Weights.IMAGENET1K_V1
        model = M.efficientnet_b6(weights=w); preprocess = w.transforms()

    else:
        raise ValueError("MODEL_NAME must be mv3_small|mv3_large|mv2|eff0|eff2|eff4|eff5|eff6")
    model.eval()
    torch.set_num_threads(max(1, THREADS))
    return model, preprocess

model, preprocess = load_model(MODEL_NAME)
tasks_lock = threading.Lock()
tasks: Dict[str, Dict[str, Any]] = {}

def ensure_task(tid: str):
    with tasks_lock:
        if tid not in tasks:
            tasks[tid] = {"meta": None, "image": None, "t_start": time.time()}

def cleanup_tasks():
    now = time.time()
    with tasks_lock:
        doomed = [k for k,v in tasks.items() if now - v.get("t_start", now) > CLEANUP_SEC]
        for k in doomed: tasks.pop(k, None)

def infer(img_bytes: bytes):
    img = Image.open(io.BytesIO(img_bytes)).convert("RGB")
    x = preprocess(img).unsqueeze(0)
    t0 = time.perf_counter()
    with torch.inference_mode():
        y = model(x)
    t1 = time.perf_counter()
    lat_ms = (t1 - t0) * 1000.0
    probs = torch.softmax(y, dim=1)
    p, idx = torch.topk(probs, 5, dim=1)
    return lat_ms, [int(v) for v in idx[0]], [float(v) for v in p[0]]

def on_connect(c,u,f,rc,p=None):
    c.subscribe("device/request/+/meta", qos=1)
    c.subscribe("device/request/+/image", qos=1)

def on_message(c,u,msg):
    try:
        parts = msg.topic.split("/")
        if len(parts)!=4 or parts[0]!="device" or parts[1]!="request":
            return
        tid, kind = parts[2], parts[3]
        ensure_task(tid)
        if kind=="meta":
            meta = json.loads(msg.payload.decode("utf-8"))
            with tasks_lock: tasks[tid]["meta"]=meta
        elif kind=="image":
            with tasks_lock: tasks[tid]["image"]=bytes(msg.payload)

        with tasks_lock:
            rec = tasks.get(tid, {})
            meta, img = rec.get("meta"), rec.get("image")
        if meta is not None and img is not None:
            t_edge_start = time.time()
            try:
                lat_ms, idx, probs = infer(img)
                resp = {"task_id": tid, "model": MODEL_NAME, "ok": True,
                        "edge_latency_ms": round(lat_ms,3),
                        "top5_indices": idx,
                        "top5_probs": [round(v,6) for v in probs],
                        "t_edge_start": t_edge_start,
                        "t_edge_end": time.time()}
            except Exception as e:
                resp = {"task_id": tid, "model": MODEL_NAME, "ok": False, "error": str(e)}
            c.publish(f"edge/response/{tid}", json.dumps(resp), qos=1)
            with tasks_lock: tasks.pop(tid, None)
        cleanup_tasks()
    except Exception as e:
        print("[edge] on_message error:", e)

def main():
    client = mqtt.Client(client_id=CLIENT_ID, protocol=mqtt.MQTTv5)
    client.on_connect = on_connect
    client.on_message = on_message
    client.connect(BROKER_HOST, BROKER_PORT, 60)
    print(f"[edge] connected to {BROKER_HOST}:{BROKER_PORT}, model={MODEL_NAME}")
    client.loop_forever()

if __name__ == "__main__":
    main()
