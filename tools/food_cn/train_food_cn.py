"""中式食物辨识：以 CNFOOD-241（CC BY-NC 3.0，非商业）挑选糖尿病患者常吃的菜色，微调 MobileNetV2 的分类层。

步骤：
1. 只用 CNFOOD-241 的验证集压缩档（约 2.1 万张）；挑选的每类照片按固定 seed 切成训练 70% / 测试 30%，测试照片完全不参与训练。
2. ImageNet 预训练 MobileNetV2 作为特征提取器（冻结），先抽 1280 维特征，再训练新的分类层（含少量数据增强的特征）。
3. 在测试照片上报告 top-1 / top-3 准确率与各类准确率，并导出 ONNX（输入 1×3×224×224，与 APP 现有前处理一致）。

用法（Anaconda Python，含 torch/torchvision）：
  python tools/food_cn/train_food_cn.py extract   # 抽特征（只需一次）
  python tools/food_cn/train_food_cn.py train     # 训练、评估、导出（只用验证集的 70%）
  python tools/food_cn/train_food_cn.py extract_full          # 完整训练集特征（9.3 GB 压缩档）
  python tools/food_cn/train_food_cn.py train full [mlp512]   # 加入完整训练集；mlp512 为多一层隐藏层的分类层
资料与特征放在 D:/MediLens/.datasets/（不上传 GitHub）。
"""
from __future__ import annotations

import io
import json
import random
import sys
import time
import zipfile
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torchvision
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / ".datasets" / "cnfood241"
ZIP = DATA / "val600x600.zip"
TRAIN_ZIP = DATA / "train600x600.zip"   # 完整训练集（9.3 GB），只用于训练；测试照片仍是验证集保留的 30%
OUT = ROOT / ".datasets" / "food_cn_build"
SEED = 2026

# 挑选的类别：CNFOOD-241 编号 → (中文名, 类型)。主食与甜点碳水差异大，家常菜为常见搭配。
CLASSES = {
    172: "米饭", 130: "炒饭", 171: "大米粥", 167: "小米粥", 168: "红薯粥", 215: "南瓜粥", 170: "皮蛋瘦肉粥",
    144: "馒头", 145: "包子", 159: "饺子", 165: "煎饺", 164: "馄饨", 132: "小笼汤包", 133: "烧麦", 148: "油条",
    139: "葱花手抓饼", 140: "芝麻烧饼", 141: "肉夹馍", 142: "韭菜盒子", 149: "炸酱面", 152: "西红柿鸡蛋面", 158: "炒面",
    161: "红烧牛肉面", 162: "河粉", 155: "凉皮", 150: "酸辣粉", 166: "汤圆", 160: "玉米棒", 173: "紫菜包饭",
    240: "煲仔饭", 131: "蛋包饭", 195: "蛋糕", 197: "面包", 199: "吐司", 200: "饼干", 204: "冰激凌", 207: "水果沙拉",
    0: "麻婆豆腐", 71: "宫保鸡丁", 77: "红烧肉", 50: "西红柿炒鸡蛋", 58: "糖醋排骨", 87: "糖醋里脊", 97: "鱼香肉丝",
    96: "青椒肉丝", 84: "回锅肉", 19: "炒青菜", 5: "酸辣土豆丝", 11: "鱼香茄子", 113: "清蒸鲈鱼", 68: "黄焖鸡",
    65: "白斩鸡", 106: "酸菜鱼", 85: "猪肉炖粉条", 101: "蚂蚁上树", 180: "西红柿鸡蛋汤", 53: "鸡蛋羹", 26: "蚝油西兰花",
    60: "可乐鸡翅",
}

MEAN = torch.tensor([0.485, 0.456, 0.406]).view(3, 1, 1)
STD = torch.tensor([0.229, 0.224, 0.225]).view(3, 1, 1)


def load_image(data: bytes, augment: bool = False, rng: random.Random | None = None) -> torch.Tensor:
    """与 APP 相同：等比缩放后居中裁成 224×224，再按 ImageNet 均值方差标准化。增强只在训练用。"""
    im = Image.open(io.BytesIO(data)).convert("RGB")
    if augment and rng:
        if rng.random() < 0.5:
            im = im.transpose(Image.FLIP_LEFT_RIGHT)
        w, h = im.size
        s = rng.uniform(0.75, 1.0)
        cw, ch = int(w * s), int(h * s)
        x, y = rng.randint(0, w - cw), rng.randint(0, h - ch)
        im = im.crop((x, y, x + cw, y + ch))
    w, h = im.size
    scale = 256 / min(w, h)
    im = im.resize((max(224, round(w * scale)), max(224, round(h * scale))), Image.BILINEAR)
    w, h = im.size
    left, top = (w - 224) // 2, (h - 224) // 2
    im = im.crop((left, top, left + 224, top + 224))
    t = torch.from_numpy(np.asarray(im, dtype=np.float32) / 255.0).permute(2, 0, 1)
    return (t - MEAN) / STD


def class_of(name: str) -> int | None:
    """压缩档内的路径形如 val600x600/<编号>/<文件>.jpg。"""
    parts = [p for p in name.replace("\\", "/").split("/") if p]
    for p in parts[:-1][::-1]:
        if p.isdigit():
            return int(p)
    return None


def backbone() -> nn.Module:
    m = torchvision.models.mobilenet_v2(weights=torchvision.models.MobileNet_V2_Weights.IMAGENET1K_V1)
    m.classifier = nn.Identity()
    return m.eval()


def extract():
    OUT.mkdir(parents=True, exist_ok=True)
    torch.set_num_threads(12)
    z = zipfile.ZipFile(ZIP)
    names = [n for n in z.namelist() if n.lower().endswith((".jpg", ".jpeg", ".png")) and class_of(n) in CLASSES]
    by_cls: dict[int, list[str]] = {}
    for n in sorted(names):
        by_cls.setdefault(class_of(n), []).append(n)
    rng = random.Random(SEED)
    split = {}
    for c, ns in by_cls.items():
        ns = ns[:]
        rng.shuffle(ns)
        k = max(1, round(len(ns) * 0.3))
        split[c] = {"test": ns[:k], "train": ns[k:]}
    (OUT / "split.json").write_text(json.dumps(split, ensure_ascii=False), encoding="utf-8")
    print("类别", len(by_cls), "照片", len(names), {CLASSES[c]: len(v) for c, v in sorted(by_cls.items())})
    net = backbone()
    feats = {"train": [], "test": [], "train_aug": []}
    labels = {"train": [], "test": [], "train_aug": []}
    order = sorted(CLASSES)
    idx = {c: i for i, c in enumerate(order)}
    aug_rng = random.Random(SEED + 1)
    t0 = time.time()
    jobs = [("test", c, n, False) for c in order for n in split.get(c, {}).get("test", [])]
    jobs += [("train", c, n, False) for c in order for n in split.get(c, {}).get("train", [])]
    jobs += [("train_aug", c, n, True) for c in order for n in split.get(c, {}).get("train", [])]   # 每张训练照片再加一张增强版
    batch, meta = [], []
    for k, (part, c, n, aug) in enumerate(jobs):
        batch.append(load_image(z.read(n), aug, aug_rng))
        meta.append((part, c))
        if len(batch) == 64 or k == len(jobs) - 1:
            with torch.no_grad():
                f = net(torch.stack(batch)).numpy()
            for (p, cc), v in zip(meta, f):
                feats[p].append(v)
                labels[p].append(idx[cc])
            batch, meta = [], []
            if k % 1280 < 64:
                print(f"{k + 1}/{len(jobs)}  {time.time() - t0:.0f}s", flush=True)
    np.savez_compressed(OUT / "features.npz", **{f"x_{p}": np.array(v, np.float32) for p, v in feats.items()},
                        **{f"y_{p}": np.array(v, np.int64) for p, v in labels.items()}, classes=np.array(order))
    print("特征完成", {p: len(v) for p, v in feats.items()}, f"{time.time() - t0:.0f}s")


def extract_full():
    """完整训练集里挑选类别的照片：原图＋一张增强版的特征。"""
    torch.set_num_threads(12)
    d = np.load(OUT / "features.npz")
    order = [int(c) for c in d["classes"]]
    idx = {c: i for i, c in enumerate(order)}
    z = zipfile.ZipFile(TRAIN_ZIP)
    names = sorted(n for n in z.namelist() if n.lower().endswith((".jpg", ".jpeg", ".png")) and class_of(n) in idx)
    print("完整训练集照片", len(names), flush=True)
    net = backbone()
    rng = random.Random(SEED + 2)
    xs, ys, t0 = [], [], time.time()
    jobs = [(n, False) for n in names] + [(n, True) for n in names]
    for i in range(0, len(jobs), 64):
        part = jobs[i:i + 64]
        batch = []
        for n, aug in part:
            try:
                batch.append(load_image(z.read(n), aug, rng))
            except Exception:
                batch.append(None)
        keep = [(b, class_of(n)) for b, (n, _) in zip(batch, part) if b is not None]
        with torch.no_grad():
            f = net(torch.stack([b for b, _ in keep])).numpy()
        xs.extend(f)
        ys.extend(idx[c] for _, c in keep)
        if i % 6400 == 0:
            print(f"{i + len(part)}/{len(jobs)}  {time.time() - t0:.0f}s", flush=True)
    np.savez_compressed(OUT / "features_full.npz", x=np.array(xs, np.float32), y=np.array(ys, np.int64))
    print("完整训练集特征完成", len(xs), f"{time.time() - t0:.0f}s")


def train(full: bool = False, hidden: int = 0):
    d = np.load(OUT / "features.npz")
    order = list(d["classes"])
    xtr = torch.from_numpy(np.concatenate([d["x_train"], d["x_train_aug"]]))
    ytr = torch.from_numpy(np.concatenate([d["y_train"], d["y_train_aug"]]))
    n_images = len(d["y_train"])  # 不含增强版
    if full:
        f = np.load(OUT / "features_full.npz")
        xtr = torch.cat([xtr, torch.from_numpy(f["x"])])
        ytr = torch.cat([ytr, torch.from_numpy(f["y"])])
        n_images += len(f["y"]) // 2
    xte, yte = torch.from_numpy(d["x_test"]), torch.from_numpy(d["y_test"])
    torch.manual_seed(SEED)
    if hidden:
        head = nn.Sequential(nn.Dropout(0.2), nn.Linear(1280, hidden), nn.ReLU(), nn.Dropout(0.3), nn.Linear(hidden, len(order)))
    else:
        head = nn.Sequential(nn.Dropout(0.2), nn.Linear(1280, len(order)))
    epochs = 40 if full else 60
    opt = torch.optim.AdamW(head.parameters(), lr=1e-3, weight_decay=1e-3)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, epochs)
    lossf = nn.CrossEntropyLoss(label_smoothing=0.1)
    for ep in range(epochs):
        head.train()
        perm = torch.randperm(len(xtr))
        for i in range(0, len(perm), 256):
            b = perm[i:i + 256]
            opt.zero_grad()
            lossf(head(xtr[b]), ytr[b]).backward()
            opt.step()
        sched.step()
    head.eval()
    with torch.no_grad():
        logits = head(xte)
    top1 = (logits.argmax(1) == yte).float().mean().item()
    top3 = (logits.topk(3, 1).indices == yte[:, None]).any(1).float().mean().item()
    probs = logits.softmax(1)
    conf = probs.max(1).values
    per = {}
    for i, c in enumerate(order):
        m = yte == i
        per[CLASSES[int(c)]] = {"n": int(m.sum()), "top1": round((logits[m].argmax(1) == i).float().mean().item(), 3)}
    # 置信度门槛（APP 只在最高机率 ≥ 门槛时自动给候选）：报告覆盖率与该部分的准确率
    gates = {}
    for g in (0.3, 0.5, 0.7):
        keep = conf >= g
        gates[str(g)] = {"coverage": round(keep.float().mean().item(), 3),
                         "top1_when_shown": round((logits[keep].argmax(1) == yte[keep]).float().mean().item(), 3) if keep.any() else None}
    report = {"classes": len(order), "train_images": int(n_images),
              "full_train_set": full, "head": f"mlp{hidden}" if hidden else "linear", "test_images": int(len(yte)),
              "top1": round(top1, 3), "top3": round(top3, 3), "confidence_gate": gates, "per_class": per}
    tag = ("_full" if full else "") + (f"_mlp{hidden}" if hidden else "")
    (OUT / f"report{tag}.json").write_text(json.dumps(report, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps({k: v for k, v in report.items() if k != "per_class"}, ensure_ascii=False))
    worst = sorted(per.items(), key=lambda kv: kv[1]["top1"])[:8]
    print("最弱的类别", worst)
    # 导出：骨干＋新分类层（去掉 Dropout），输出 logits；与现有 APP 推理一致
    model = backbone()
    model.classifier = nn.Sequential(*[m for m in head if not isinstance(m, nn.Dropout)])
    model.eval()
    # torch 2.3 在导出最后会尝试附加 onnxscript 自定义函数（需要 onnx 套件）；本模型没有自定义函数，直接略过这一步
    from torch.onnx._internal import onnx_proto_utils
    onnx_proto_utils._add_onnxscript_fn = lambda model_bytes, custom_opsets: model_bytes
    torch.onnx.export(model, torch.zeros(1, 3, 224, 224), str(OUT / f"food_cn{tag}.onnx"), input_names=["input"],
                      output_names=["logits"], opset_version=17, dynamic_axes=None)
    (OUT / "labels_cn.txt").write_text("\n".join(f"cn{int(c):03d}" for c in order) + "\n", encoding="utf-8")
    (OUT / "names_cn.json").write_text(json.dumps({f"cn{int(c):03d}": CLASSES[int(c)] for c in order}, ensure_ascii=False, indent=1),
                                        encoding="utf-8")
    print("已导出", OUT / f"food_cn{tag}.onnx")


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "train":
        train(full="full" in sys.argv[2:], hidden=int(next((a[3:] for a in sys.argv[2:] if a.startswith("mlp")), 0)))
    else:
        {"extract": extract, "extract_full": extract_full}[cmd]()
