#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import argparse, io, json, time, uuid, threading, os, sys
from PIL import Image
import paho.mqtt.client as mqtt
from models import load_model, preprocess_image, infer_once

def encode_jpeg(path: str, quality: int = 95) -> bytes:
    img = Image.open(path).convert("RGB")
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=quality, optimize=True)
    return buf.getvalue()

def run_local_image(image_path: str, model_name: str):
    if not os.path.isfile(image_path):
        print(json.dumps({"ok": False, "error": "image not found", "image": image_path}, ensure_ascii=False))
        return
    model, pp = load_model(model_name)
    try:
        x = preprocess_image(image_path, pp)
        lat_ms, idx, probs = infer_once(model, x)
        rec = {
            "image": image_path, "ok": True,
            "latency_ms": round(lat_ms, 3),
            "top5_indices": idx,
            "top5_probs": [round(float(v), 6) for v in probs]
        }
    except Exception as e:
        rec = {"image": image_path, "ok": False, "error": str(e)}

    print(json.dumps(rec, ensure_ascii=False))

def run_remote_image(image_path: str, model_name: str, broker_host: str, broker_port: int, jpeg_q: int, timeout: float):
    if not os.path.isfile(image_path):
        print(json.dumps({"ok": False, "error": "image not found", "image": image_path}, ensure_ascii=False))
        return

    client = mqtt.Client(protocol=mqtt.MQTTv5, client_id="device-single")
    result_holder = {}
    wait_events = {}

    def on_connect(c,u,f,rc,p=None):
        print(f"[device] connected with result code {rc}", file=sys.stderr)

    def on_message(c,u,msg):
        try:
            payload = json.loads(msg.payload.decode("utf-8"))
            tid = payload.get("task_id")
            result_holder[tid] = payload
            ev = wait_events.get(tid)
            if ev: ev.set()
        except Exception as e:
            print(f"[device] on_message error: {e}", file=sys.stderr)

    client.on_connect = on_connect
    client.on_message = on_message
    client.connect(broker_host, broker_port, keepalive=60)
    client.loop_start()

    task_id = str(uuid.uuid4())
    meta = {"task_id": task_id, "model": model_name, "quant": "fp32",
            "jpeg_q": jpeg_q, "t_device_send": time.time(), "image": os.path.basename(image_path)}
    img_bytes = encode_jpeg(image_path, jpeg_q)

    topic_resp = f"edge/response/{task_id}"
    client.subscribe(topic_resp, qos=1)
    ev = threading.Event()
    wait_events[task_id] = ev

    t0 = time.perf_counter()
    client.publish(f"device/request/{task_id}/meta", json.dumps(meta), qos=1)
    client.publish(f"device/request/{task_id}/image", img_bytes, qos=1)
    bytes_up = len(json.dumps(meta).encode("utf-8")) + len(img_bytes)

    got = ev.wait(timeout)
    t1 = time.perf_counter()

    if not got:
        rec = {
            "image": image_path, "ok": False, "error": "timeout",
            "rtt_ms": round((t1 - t0) * 1000.0, 3),
            "bytes_up": bytes_up, "bytes_down": 0
        }
    else:
        resp = result_holder.get(task_id, {})
        bytes_down = len(json.dumps(resp).encode("utf-8"))
        rec = {
            "image": image_path, "ok": resp.get("ok", False),
            "rtt_ms": round((t1 - t0) * 1000.0, 3),
            "edge_latency_ms": resp.get("edge_latency_ms"),
            "bytes_up": bytes_up, "bytes_down": bytes_down,
            "top5_indices": resp.get("top5_indices"),
            "top5_probs": resp.get("top5_probs"),
            "task_id": task_id,
            "error": resp.get("error")
        }

    print(json.dumps(rec, ensure_ascii=False))

    client.unsubscribe(topic_resp)
    wait_events.pop(task_id, None)
    result_holder.pop(task_id, None)
    client.loop_stop(); client.disconnect()

def main():
    ap = argparse.ArgumentParser(description="Infer a single image locally or via MQTT")
    ap.add_argument("--mode", choices=["local","remote"], required=True)
    ap.add_argument("--model", default="mv3_small", help="mv3_small|mv3_large|mv2|eff0|eff2|eff4|eff5|eff6")
    ap.add_argument("--image", required=True, help="path to a single image")
    # remote only
    ap.add_argument("--broker_host", default="localhost")
    ap.add_argument("--broker_port", type=int, default=1883)
    ap.add_argument("--jpeg_q", type=int, default=95)
    ap.add_argument("--timeout", type=float, default=10.0)
    args = ap.parse_args()

    if args.mode == "local":
        run_local_image(args.image, args.model)
    else:
        run_remote_image(args.image, args.model, args.broker_host, args.broker_port, args.jpeg_q, args.timeout)

if __name__ == "__main__":
    main()
