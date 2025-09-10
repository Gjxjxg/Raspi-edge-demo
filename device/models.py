#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import torch
import torchvision.models as M
from PIL import Image

def load_model(name: str):
    name = name.lower()
    if name in ["mv3_small", "mobilenet_v3_small"]:
        w = M.MobileNet_V3_Small_Weights.IMAGENET1K_V1
        model = M.mobilenet_v3_small(weights=w); preprocess = w.transforms()
    elif name in ["mv3_large", "mobilenet_v3_large"]:
        w = M.MobileNet_V3_Large_Weights.IMAGENET1K_V2
        model = M.mobilenet_v3_large(weights=w); preprocess = w.transforms()
    elif name in ["mv2", "mobilenet_v2"]:
        w = M.MobileNet_V2_Weights.IMAGENET1K_V1
        model = M.mobilenet_v2(weights=w); preprocess = w.transforms()
    elif name in ["eff0", "efficientnet_b0"]:
        w = M.EfficientNet_B0_Weights.IMAGENET1K_V1
        model = M.efficientnet_b0(weights=w); preprocess = w.transforms()
    elif name in ["eff2", "efficientnet_b2"]:
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
        raise ValueError("model must be: mv3_small|mv3_large|mv2|eff0|eff2|eff4|eff5|eff6")
    model.eval()
    return model, preprocess

def preprocess_image(img_path: str, preprocess):
    img = Image.open(img_path).convert("RGB")
    x = preprocess(img).unsqueeze(0)  # [1,3,224,224]
    return x

def infer_once(model, x):
    import torch, time
    t0 = time.perf_counter()
    with torch.inference_mode():
        y = model(x)
    t1 = time.perf_counter()
    lat_ms = (t1 - t0) * 1000.0
    probs = torch.softmax(y, dim=1)
    p, idx = torch.topk(probs, 5, dim=1)
    return lat_ms, [int(v) for v in idx[0]], [float(v) for v in p[0]]
