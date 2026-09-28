#!/usr/bin/env python3
"""Reusable Hybrid-v2 upsampling head for training and model export."""

from __future__ import annotations

import torch
import torch.nn as nn
import torch.nn.functional as F


class HybridV2Upsample(nn.Module):
    """Add a cheap, subpixel-aware correction to ZipDepth's NPU head.

    The original mobile head predicts one half-resolution alpha field, then
    bilinearly resizes it to blend nearest and bilinear depth. Hybrid-v2 keeps
    that complete pretrained path and adds four correction values per
    half-resolution pixel--one for each output pixel in the final 2x2 block.

    The final refinement convolution is initialized to zero. Consequently an
    untrained Hybrid-v2 is bit-for-bit the old Hybrid in PyTorch, giving
    training a safe starting point and making any quality change measurable.
    """

    def __init__(
        self,
        base_head: nn.Module,
        feature_channels: int = 32,
        refinement_channels: int = 8,
        correction_limit: float = 0.5,
    ) -> None:
        super().__init__()
        if getattr(base_head, "use_unfold", True):
            raise ValueError("Hybrid-v2 requires ZipDepth's unfold-free mobile head")
        self.scale = int(base_head.scale)
        self.where_conv = base_head.where_conv
        self.correction_limit = float(correction_limit)
        self.subpixel_refine = nn.Sequential(
            nn.Conv2d(feature_channels, refinement_channels, 1, bias=True),
            nn.ReLU(inplace=True),
            nn.Conv2d(
                refinement_channels,
                self.scale * self.scale,
                1,
                bias=True,
            ),
        )
        nn.init.kaiming_normal_(
            self.subpixel_refine[0].weight, mode="fan_out", nonlinearity="relu"
        )
        nn.init.zeros_(self.subpixel_refine[0].bias)
        nn.init.zeros_(self.subpixel_refine[2].weight)
        nn.init.zeros_(self.subpixel_refine[2].bias)

    def forward(self, features: torch.Tensor, depth: torch.Tensor) -> torch.Tensor:
        nearest = F.interpolate(depth, scale_factor=self.scale, mode="nearest")
        bilinear = F.interpolate(
            depth,
            scale_factor=self.scale,
            mode="bilinear",
            align_corners=False,
        )

        base_logits = F.interpolate(
            self.where_conv(features),
            scale_factor=self.scale,
            mode="bilinear",
            align_corners=False,
        )
        base_alpha = torch.sigmoid(base_logits)
        correction = F.pixel_shuffle(
            self.subpixel_refine(features), self.scale
        )
        correction = torch.tanh(correction) * self.correction_limit
        alpha = torch.clamp(base_alpha + correction, 0.0, 1.0)
        return F.relu(alpha * nearest + (1.0 - alpha) * bilinear)


def install_hybrid_v2_head(
    model: nn.Module,
    refinement_channels: int = 8,
    correction_limit: float = 0.5,
) -> HybridV2Upsample:
    """Replace a model's NPU head and return the installed Hybrid-v2 module."""
    old_head = model.decoder.convex_up
    feature_channels = model.decoder.head_half.in_channels
    new_head = HybridV2Upsample(
        old_head,
        feature_channels=feature_channels,
        refinement_channels=refinement_channels,
        correction_limit=correction_limit,
    )
    model.decoder.convex_up = new_head
    return new_head
