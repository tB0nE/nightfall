#!/usr/bin/env python3
"""Distil ZipDepth's Standard head into the lightweight Hybrid-v2 head.

The encoder, decoder, and half-resolution depth predictor remain frozen. Only
the existing mobile ``where_conv`` and the new four-subpixel refinement branch
are trained. Teacher depth is generated online by the unmodified Standard
checkpoint, so RGB frames are the only dataset input required.
"""

from __future__ import annotations

import argparse
import json
import random
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image
import torch
import torch.nn.functional as F
from torch.utils.data import DataLoader, Dataset


TOOLS_DIR = Path(__file__).resolve().parent
ZIPDEPTH_DIR = TOOLS_DIR / "ZipDepth"
sys.path.insert(0, str(TOOLS_DIR))
sys.path.insert(0, str(ZIPDEPTH_DIR))

from export_zipdepth_gpu_safe import load_model  # noqa: E402
from zipdepth.loss import ZipDepthLoss  # noqa: E402
from zipdepth_hybrid_v2 import install_hybrid_v2_head  # noqa: E402


IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".webp", ".bmp"}


class FrameDataset(Dataset):
    def __init__(self, root: Path, size: int, augment: bool) -> None:
        self.paths = sorted(
            path for path in root.rglob("*") if path.suffix.lower() in IMAGE_SUFFIXES
        )
        if not self.paths:
            raise ValueError(f"No training images found under {root}")
        self.size = size
        self.augment = augment

    def __len__(self) -> int:
        return len(self.paths)

    def __getitem__(self, index: int) -> torch.Tensor:
        with Image.open(self.paths[index]) as image:
            image = image.convert("RGB").resize(
                (self.size, self.size), Image.Resampling.BILINEAR
            )
            pixels = np.asarray(image, dtype=np.float32).copy() / 255.0
        tensor = torch.from_numpy(pixels).permute(2, 0, 1)
        if self.augment and random.random() < 0.5:
            tensor = tensor.flip(-1)
        return tensor


def relative_raw_l1(prediction: torch.Tensor, target: torch.Tensor) -> torch.Tensor:
    error = F.smooth_l1_loss(prediction, target)
    return error / target.abs().mean().clamp_min(1e-4)


def evaluate(
    student: torch.nn.Module,
    teacher: torch.nn.Module,
    loader: DataLoader,
    criterion: ZipDepthLoss,
    device: torch.device,
    amp_dtype: torch.dtype,
) -> dict[str, float]:
    student.eval()
    totals = {"loss": 0.0, "ssi": 0.0, "grad": 0.0, "raw": 0.0}
    samples = 0
    with torch.no_grad():
        for images in loader:
            images = images.to(device, non_blocking=True)
            with torch.autocast("cuda", dtype=amp_dtype, enabled=device.type == "cuda"):
                target = teacher(images)
                prediction = student(images)
                distil, parts = criterion(prediction, target)
                raw = relative_raw_l1(prediction, target)
                loss = distil + 0.25 * raw
            batch = images.shape[0]
            totals["loss"] += float(loss) * batch
            totals["ssi"] += parts["ssi"] * batch
            totals["grad"] += parts["grad"] * batch
            totals["raw"] += float(raw) * batch
            samples += batch
    return {key: value / max(samples, 1) for key, value in totals.items()}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--train-dir", type=Path, required=True)
    parser.add_argument("--val-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--epochs", type=int, default=12)
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument("--learning-rate", type=float, default=3e-4)
    parser.add_argument("--size", type=int, default=384)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--refinement-channels", type=int, default=8)
    parser.add_argument("--seed", type=int, default=20260925)
    parser.add_argument(
        "--npu-checkpoint",
        type=Path,
        default=ZIPDEPTH_DIR / "checkpoints/zipdepth_base_npu.pth",
    )
    parser.add_argument(
        "--standard-checkpoint",
        type=Path,
        default=ZIPDEPTH_DIR / "checkpoints/zipdepth_base.pth",
    )
    args = parser.parse_args()

    random.seed(args.seed)
    np.random.seed(args.seed)
    torch.manual_seed(args.seed)
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    if device.type != "cuda":
        raise RuntimeError("Hybrid-v2 training requires a CUDA GPU")
    torch.backends.cudnn.benchmark = True
    torch.backends.cuda.matmul.allow_tf32 = True

    train_data = FrameDataset(args.train_dir, args.size, augment=True)
    val_data = FrameDataset(args.val_dir, args.size, augment=False)
    train_loader = DataLoader(
        train_data,
        batch_size=args.batch_size,
        shuffle=True,
        num_workers=args.workers,
        pin_memory=True,
        persistent_workers=args.workers > 0,
    )
    val_loader = DataLoader(
        val_data,
        batch_size=args.batch_size,
        shuffle=False,
        num_workers=args.workers,
        pin_memory=True,
        persistent_workers=args.workers > 0,
    )

    teacher = load_model(args.standard_checkpoint, upsample_unfold=True).to(device)
    teacher.eval()
    teacher.requires_grad_(False)

    student = load_model(
        args.npu_checkpoint,
        backbone_checkpoint=args.standard_checkpoint,
        upsample_unfold=False,
    ).to(device)
    head = install_hybrid_v2_head(
        student, refinement_channels=args.refinement_channels
    ).to(device)
    student.requires_grad_(False)
    head.requires_grad_(True)
    student.eval()
    head.train()

    trainable = sum(parameter.numel() for parameter in head.parameters())
    total = sum(parameter.numel() for parameter in student.parameters())
    print(
        f"Training {trainable:,}/{total:,} parameters "
        f"({100.0 * trainable / total:.4f}%) on {device}"
    )
    print(f"Frames: train={len(train_data):,} validation={len(val_data):,}")

    optimizer = torch.optim.AdamW(
        head.parameters(), lr=args.learning_rate, weight_decay=1e-4
    )
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(
        optimizer, T_max=max(args.epochs, 1), eta_min=args.learning_rate * 0.03
    )
    criterion = ZipDepthLoss(alpha_ssi=1.0, alpha_grad=3.0).to(device)
    amp_dtype = torch.bfloat16

    args.output.parent.mkdir(parents=True, exist_ok=True)
    history: list[dict[str, object]] = []
    baseline = evaluate(student, teacher, val_loader, criterion, device, amp_dtype)
    print(f"Baseline validation: {baseline}")
    best_loss = baseline["loss"]

    for epoch in range(args.epochs):
        start = time.monotonic()
        head.train()
        running = 0.0
        seen = 0
        for images in train_loader:
            images = images.to(device, non_blocking=True)
            optimizer.zero_grad(set_to_none=True)
            with torch.no_grad(), torch.autocast("cuda", dtype=amp_dtype):
                target = teacher(images)
            with torch.autocast("cuda", dtype=amp_dtype):
                prediction = student(images)
                distil, _ = criterion(prediction, target)
                raw = relative_raw_l1(prediction, target)
                loss = distil + 0.25 * raw
            loss.backward()
            torch.nn.utils.clip_grad_norm_(head.parameters(), 1.0)
            optimizer.step()
            running += float(loss.detach()) * images.shape[0]
            seen += images.shape[0]

        scheduler.step()
        validation = evaluate(
            student, teacher, val_loader, criterion, device, amp_dtype
        )
        record = {
            "epoch": epoch + 1,
            "train_loss": running / max(seen, 1),
            "validation": validation,
            "seconds": time.monotonic() - start,
            "learning_rate": scheduler.get_last_lr()[0],
        }
        history.append(record)
        print(json.dumps(record))
        if validation["loss"] < best_loss:
            best_loss = validation["loss"]
            torch.save(
                {
                    "format": "nightfall-zipdepth-hybrid-v2",
                    "model_state_dict": student.state_dict(),
                    "head_state_dict": head.state_dict(),
                    "refinement_channels": args.refinement_channels,
                    "correction_limit": head.correction_limit,
                    "baseline_validation": baseline,
                    "best_validation": validation,
                    "history": history,
                    "training_args": vars(args),
                },
                args.output,
            )

    print(f"Best validation loss: {best_loss:.6f}")
    print(f"Checkpoint: {args.output}")


if __name__ == "__main__":
    main()
