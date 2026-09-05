#!/usr/bin/env python3
"""Export ZipDepth with GPU-delegate-sensitive tensor operations rewritten.

LiteRT's GPU delegate lowers a global average pool to its work-group reduction
kernel and emits long nested loops for the 48x1/1x48 strip pools.  It also
implements ZipDepth's attention gates with implicit spatial broadcasting.  The
Quest 3 Adreno delegate produces numerically incorrect results in this region
even though every op passes the compatibility check.  This exporter preserves
the deployed model math while decomposing large reductions into small stages
and explicitly materializing attention maps before element-wise operations.

The downloaded upstream checkout is deliberately left untouched.  This script
expects it at tools/ZipDepth and is called by tools/convert_zipdepth.py.
"""

import argparse
import copy
import sys
import types
from pathlib import Path

import torch
import torch.nn as nn
import torch.nn.functional as F


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_DIR = SCRIPT_DIR / "ZipDepth"
sys.path.insert(0, str(REPO_DIR))

from zipdepth.model.architecture import create_model  # noqa: E402
from zipdepth.utils.model_utils import (  # noqa: E402
    fuse_remaining_conv_bn,
    strip_state_dict_prefixes,
)


def _checkpoint_state(checkpoint: Path) -> dict[str, torch.Tensor]:
    checkpoint_data = torch.load(checkpoint, map_location="cpu", weights_only=True)
    state_dict = checkpoint_data.get("model_state_dict", checkpoint_data)
    return strip_state_dict_prefixes(state_dict)


def load_model(
    checkpoint: Path,
    backbone_checkpoint: Path | None = None,
    upsample_unfold: bool = False,
) -> nn.Module:
    model = create_model(
        variant="base",
        global_mode="balanced",
        upsample_unfold=upsample_unfold,
    )
    state_dict = _checkpoint_state(checkpoint)
    if backbone_checkpoint is not None:
        # The standard checkpoint has a materially sharper backbone and
        # decoder, but its torch.nn.Unfold-based convex head is unsuitable
        # for LiteRT's mobile GPU delegate.  All other tensor shapes match.
        # Keep the NPU checkpoint's export-friendly where_conv head and take
        # every compatible non-head weight from the standard checkpoint.
        backbone_state = _checkpoint_state(backbone_checkpoint)
        model_state = model.state_dict()
        compatible = {
            key: value
            for key, value in backbone_state.items()
            if key in model_state and model_state[key].shape == value.shape
        }
        compatible.update({
            key: value
            for key, value in state_dict.items()
            if key.startswith("decoder.convex_up.where_conv.")
        })
        state_dict = compatible
        print(
            "Hybrid weights: standard backbone/decoder + "
            f"NPU upsampling head ({len(state_dict)} tensors)"
        )
    missing, unexpected = model.load_state_dict(state_dict, strict=False)
    if unexpected:
        print(f"Ignored training-only keys: {unexpected}")
    if missing:
        print(f"Warning - missing keys: {missing}")
    model.eval()
    model.fuse_for_inference()
    fuse_remaining_conv_bn(model)
    return model


def _factor_for(size: int) -> int:
    """Choose a small exact factor for staged spatial reductions."""
    for factor in (2, 3, 5, 7):
        if size % factor == 0:
            return factor
    raise ValueError(f"Cannot exactly decompose spatial reduction of size {size}")


def staged_mean(x: torch.Tensor, reduce_height: bool, reduce_width: bool) -> torch.Tensor:
    """Exact mean implemented with small non-overlapping average pools."""
    height, width = x.shape[-2:]
    while (reduce_height and height > 1) or (reduce_width and width > 1):
        kh = _factor_for(height) if reduce_height and height > 1 else 1
        kw = _factor_for(width) if reduce_width and width > 1 else 1
        x = F.avg_pool2d(x, kernel_size=(kh, kw), stride=(kh, kw))
        height //= kh
        width //= kw
    return x


def patch_export_graph(
    model: nn.Module, input_height: int, input_width: int, gpu_safe: bool
) -> None:
    """Apply ZipDepth's deployed export substitutions, optionally decomposed."""
    stage3_shape = (input_height // 16, input_width // 16)

    for module in model.modules():
        if type(module).__name__ == "GlobalContextBlock":
            if gpu_safe:
                def forward_global(self_m, x):
                    context = self_m.transform(staged_mean(x, True, True))
                    context = F.interpolate(
                        context, size=x.shape[-2:], mode="nearest"
                    )
                    return x + context
            else:
                def forward_global(self_m, x, size=stage3_shape):
                    context = F.avg_pool2d(x, kernel_size=size)
                    return x + self_m.transform(context)
            module.forward = types.MethodType(forward_global, module)

        elif type(module).__name__ == "StripPoolingAttention":
            if gpu_safe:
                def forward_strip(self_m, x):
                    horizontal = staged_mean(x, False, True)
                    vertical = staged_mean(x, True, False)
                    horizontal = F.interpolate(
                        horizontal, size=x.shape[-2:], mode="nearest"
                    )
                    vertical = F.interpolate(
                        vertical, size=x.shape[-2:], mode="nearest"
                    )
                    return x * self_m.gate_conv(horizontal + vertical)
            else:
                def forward_strip(self_m, x):
                    height, width = x.shape[-2:]
                    gate = self_m.gate_conv(
                        F.adaptive_avg_pool2d(x, (height, 1))
                        + F.adaptive_avg_pool2d(x, (1, width))
                    )
                    return x * gate
            module.forward = types.MethodType(forward_strip, module)

        elif type(module).__name__ == "ChannelAttention" and gpu_safe:
            def forward_channel(self_m, x):
                gate = self_m.fc(staged_mean(x, True, True))
                gate = F.interpolate(gate, size=x.shape[-2:], mode="nearest")
                return x * gate
            module.forward = types.MethodType(forward_channel, module)

    cross_scale = model.encoder.cross_scale

    def forward_cross_scale(self_m, x_high, x_low, size=stage3_shape):
        low_up = F.interpolate(
            self_m.low_to_high(x_low), size=size, mode="nearest"
        )
        high_down = F.avg_pool2d(self_m.high_to_low(x_high), 2, 2)
        return x_high + low_up * 0.3, x_low + high_down * 0.3

    cross_scale.forward = types.MethodType(forward_cross_scale, cross_scale)


def verify_equivalence(
    reference: nn.Module, candidate: nn.Module, height: int, width: int
) -> None:
    torch.manual_seed(0)
    sample = torch.rand(1, 3, height, width)
    with torch.no_grad():
        expected = reference(sample)
        actual = candidate(sample)
    max_error = float((expected - actual).abs().max())
    mean_error = float((expected - actual).abs().mean())
    print(f"GPU-safe graph equivalence: max={max_error:.9g}, mean={mean_error:.9g}")
    if max_error > 1e-5:
        raise RuntimeError("GPU-safe graph rewrite changed ZipDepth output")


def bypass_npu_upsampling_head(model: nn.Module) -> None:
    """Replace the learned nearest/bilinear blend with its bilinear branch."""
    upsampler = model.decoder.convex_up

    def forward_bilinear(self_m, _features, depth):
        return F.relu(
            F.interpolate(
                depth,
                scale_factor=self_m.scale,
                mode="bilinear",
                align_corners=False,
            )
        )

    upsampler.forward = types.MethodType(forward_bilinear, upsampler)


def rewrite_standard_upsampling_head(model: nn.Module) -> None:
    """Replace ``unfold`` with an equivalent fixed one-hot convolution.

    The standard ZipDepth head learns four independent 3x3 convex kernels for
    every half-resolution pixel.  ``torch.nn.Unfold`` only supplies the nine
    neighboring scalar depth values to those kernels; it has no learned
    parameters.  A convolution with nine one-hot 3x3 filters supplies the same
    values using an operator that mobile GPU delegates handle much better.

    The four weighted sums are written out explicitly so every MUL has equal
    input shapes.  This avoids the implicit spatial/channel broadcasting that
    is known to compute incorrectly on the Quest 3 Adreno OpenCL delegate.
    """
    upsampler = model.decoder.convex_up
    if not upsampler.use_unfold:
        raise ValueError("standard-mobile rewrite requires the standard unfold head")

    def forward_mobile(self_m, feat, depth):
        batch, _, height, width = depth.shape
        scale = self_m.scale

        mask = self_m.mask_pred(feat)
        mask = mask.view(batch, 9, scale * scale, height, width)
        mask = F.softmax(mask / self_m.temperature, dim=1)

        # F.unfold() enumerates a 3x3 neighborhood in row-major order.  These
        # fixed filters produce the identical nine channels.  Preserve the
        # upstream replicate-padding behavior at the one-pixel image border.
        kernels = depth.new_zeros((9, 1, 3, 3))
        for index in range(9):
            kernels[index, 0, index // 3, index % 3] = 1.0
        depth_pad = F.pad(depth, (1, 1, 1, 1), mode="replicate")
        neighbors = F.conv2d(depth_pad, kernels)

        subpixels = []
        for index in range(scale * scale):
            weights = mask[:, :, index, :, :]
            subpixels.append((weights * neighbors).sum(dim=1, keepdim=True))
        up = torch.cat(subpixels, dim=1)
        return F.relu(F.pixel_shuffle(up, scale))

    upsampler.forward = types.MethodType(forward_mobile, upsampler)


def report_standard_head_equivalence(
    reference: nn.Module, candidate: nn.Module, height: int, width: int
) -> None:
    """Require the rewritten standard head to preserve the pretrained model."""
    torch.manual_seed(2)
    sample = torch.rand(1, 3, height, width)
    with torch.no_grad():
        expected = reference(sample)
        actual = candidate(sample)
    difference = (expected - actual).abs()
    max_error = float(difference.max())
    mean_error = float(difference.mean())
    correlation = float(
        torch.corrcoef(torch.stack((expected.flatten(), actual.flatten())))[0, 1]
    )
    print(
        "Standard mobile-head equivalence: "
        f"max={max_error:.9g}, mean={mean_error:.9g}, "
        f"correlation={correlation:.9g}"
    )
    if max_error > 1e-5:
        raise RuntimeError("mobile rewrite changed the standard ZipDepth head")


def report_head_difference(
    reference: nn.Module, candidate: nn.Module, height: int, width: int
) -> None:
    torch.manual_seed(1)
    sample = torch.rand(1, 3, height, width)
    with torch.no_grad():
        expected = reference(sample)
        actual = candidate(sample)
    difference = (expected - actual).abs()
    correlation = float(torch.corrcoef(torch.stack((expected.flatten(), actual.flatten())))[0, 1])
    print(
        "Bilinear-head diagnostic difference: "
        f"max={float(difference.max()):.9g}, "
        f"mean={float(difference.mean()):.9g}, correlation={correlation:.9g}"
    )
    if not torch.isfinite(actual).all() or float(actual.std()) < 1e-6:
        raise RuntimeError("Bilinear-head diagnostic output is invalid")


class EncoderMosaic(nn.Module):
    """Pack four encoder checkpoints into quadrants for one-run bisection."""

    def __init__(self, model: nn.Module):
        super().__init__()
        self.model = model
        channels = (24, 48, 96, 192)
        self.projections = nn.ModuleList(
            nn.Conv2d(count, 1, 1, bias=False) for count in channels
        )
        for projection, count in zip(self.projections, channels):
            projection.weight.data.fill_(1.0 / count)
            projection.weight.requires_grad_(False)

        # Calibration from the original captured Quest desktop frame.  It is
        # only an affine display aid so all four tiles occupy comparable
        # ranges; CPU-vs-GPU comparisons remain exact after the same transform.
        self.register_buffer(
            "centers",
            torch.tensor((0.00927864, 0.02950940, 0.03459717, 0.01076398)),
        )
        self.register_buffer(
            "scales",
            torch.tensor((0.00518319, 0.00468427, 0.00268576, 0.00181762)),
        )

    def _display_tile(self, activation: torch.Tensor, index: int) -> torch.Tensor:
        tile = self.projections[index](activation)
        if tile.shape[-2:] != (192, 192):
            tile = F.interpolate(
                tile, size=(192, 192), mode="bilinear", align_corners=False
            )
        return (tile - self.centers[index]) / self.scales[index]

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        model = self.model
        encoder = model.encoder
        normalized = (x - model.mean) / model.std
        stem = encoder.stem_half(normalized)
        quarter = encoder.stem_quarter(stem)
        stage1 = encoder.stage1(quarter)
        stage2 = encoder.stage2(encoder.down2(stage1))
        stage3 = encoder.stage3(encoder.down3(stage2))

        tiles = (
            self._display_tile(stem, 0),
            self._display_tile(stage1, 1),
            self._display_tile(stage2, 2),
            self._display_tile(stage3, 3),
        )
        top = torch.cat((tiles[0], tiles[1]), dim=3)
        bottom = torch.cat((tiles[2], tiles[3]), dim=3)
        return torch.cat((top, bottom), dim=2)


class Stage2Mosaic(nn.Module):
    """Pack stage-2 internal boundaries into quadrants."""

    def __init__(self, model: nn.Module):
        super().__init__()
        self.model = model
        self.projections = nn.ModuleList(
            nn.Conv2d(96, 1, 1, bias=False) for _ in range(4)
        )
        for projection in self.projections:
            projection.weight.data.fill_(1.0 / 96.0)
            projection.weight.requires_grad_(False)
        self.register_buffer(
            "centers",
            torch.tensor((0.01135072, 0.01591982, 0.05003943, 0.07210460)),
        )
        self.register_buffer(
            "scales",
            torch.tensor((0.00299676, 0.00220345, 0.00452710, 0.00508975)),
        )

    def _display_tile(self, activation: torch.Tensor, index: int) -> torch.Tensor:
        tile = self.projections[index](activation)
        tile = F.interpolate(
            tile, size=(192, 192), mode="bilinear", align_corners=False
        )
        return (tile - self.centers[index]) / self.scales[index]

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        model = self.model
        encoder = model.encoder
        normalized = (x - model.mean) / model.std
        stem = encoder.stem_half(normalized)
        quarter = encoder.stem_quarter(stem)
        stage1 = encoder.stage1(quarter)
        down = encoder.down2(stage1)
        rep0 = encoder.stage2[0](down)
        rep1 = encoder.stage2[1](rep0)
        multiscale = encoder.stage2[2](rep1)

        activations = (down, rep0, rep1, multiscale)
        tiles = tuple(
            self._display_tile(activation, index)
            for index, activation in enumerate(activations)
        )
        top = torch.cat((tiles[0], tiles[1]), dim=3)
        bottom = torch.cat((tiles[2], tiles[3]), dim=3)
        return torch.cat((top, bottom), dim=2)


class DecoderMosaic(nn.Module):
    """Pack the four decoder pyramid fusion outputs into quadrants."""

    def __init__(self, model: nn.Module):
        super().__init__()
        self.model = model
        channels = (288, 192, 144, 96)
        self.projections = nn.ModuleList(
            nn.Conv2d(count, 1, 1, bias=False) for count in channels
        )
        for projection, count in zip(self.projections, channels):
            projection.weight.data.fill_(1.0 / count)
            projection.weight.requires_grad_(False)

        # Affine display calibration from the captured desktop frame.  These
        # constants only make each checkpoint easy to inspect; they do not
        # alter the decoder operations being tested.
        self.register_buffer(
            "centers",
            torch.tensor((0.01380842, 0.02172993, 0.02013145, 0.01460069)),
        )
        self.register_buffer(
            "scales",
            torch.tensor((0.00127373, 0.00186272, 0.00117185, 0.00066297)),
        )

    def _display_tile(self, activation: torch.Tensor, index: int) -> torch.Tensor:
        tile = self.projections[index](activation)
        tile = F.interpolate(
            tile, size=(192, 192), mode="bilinear", align_corners=False
        )
        return (tile - self.centers[index]) / self.scales[index]

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        model = self.model
        s_half, features = model.encoder((x - model.mean) / model.std)
        c1, c2, c3, c4 = features
        decoder = model.decoder

        f4 = decoder.proj4(c4)
        f3 = decoder.fuse3(c3, f4)
        f2 = decoder.fuse2(c2, f3)
        f1 = decoder.fuse1(c1, f2)

        tiles = tuple(
            self._display_tile(activation, index)
            for index, activation in enumerate((f4, f3, f2, f1))
        )
        top = torch.cat((tiles[0], tiles[1]), dim=3)
        bottom = torch.cat((tiles[2], tiles[3]), dim=3)
        return torch.cat((top, bottom), dim=2)


def export_onnx(
    model: nn.Module, height: int, width: int, output: Path, opset: int
) -> None:
    dummy = torch.randn(1, 3, height, width)
    raw_output = output.with_name(output.stem + "_raw.onnx")
    with torch.no_grad():
        torch.onnx.export(
            model,
            dummy,
            raw_output,
            input_names=["image"],
            output_names=["depth"],
            opset_version=opset,
            do_constant_folding=True,
        )
    print(f"Raw ONNX: {raw_output.stat().st_size / 1e6:.1f} MB")

    import onnx
    from onnxsim import simplify

    simplified, valid = simplify(onnx.load(raw_output))
    if not valid:
        raise RuntimeError("onnxsim rejected the GPU-safe ZipDepth graph")
    onnx.save(simplified, output)
    raw_output.unlink()
    print(f"GPU-safe ONNX: {output} ({output.stat().st_size / 1e6:.1f} MB)")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ckpt", type=Path, required=True)
    parser.add_argument(
        "--backbone-ckpt",
        type=Path,
        help="optionally use compatible weights from the sharper standard checkpoint",
    )
    parser.add_argument(
        "--size",
        type=int,
        help="legacy square input size; cannot be combined with width/height",
    )
    parser.add_argument("--width", type=int)
    parser.add_argument("--height", type=int)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--opset", type=int, default=17)
    parser.add_argument(
        "--head-mode",
        choices=(
            "full",
            "bilinear",
            "standard-mobile",
            "encoder-mosaic",
            "stage2-mosaic",
            "decoder-mosaic",
        ),
        default="full",
        help="use the complete NPU blend head or bypass it for diagnosis",
    )
    args = parser.parse_args()

    if args.size is not None and (args.width is not None or args.height is not None):
        parser.error("--size cannot be combined with --width or --height")
    if (args.width is None) != (args.height is None):
        parser.error("--width and --height must be provided together")
    if args.size is not None:
        width = height = args.size
    elif args.width is not None:
        width, height = args.width, args.height
    else:
        width = height = 384
    if width % 32 or height % 32:
        parser.error("ZipDepth export dimensions must both be multiples of 32")

    if args.head_mode == "standard-mobile":
        standard_checkpoint = args.backbone_ckpt or args.ckpt
        reference = load_model(standard_checkpoint, upsample_unfold=True)
    else:
        reference = load_model(args.ckpt, args.backbone_ckpt)
    candidate = copy.deepcopy(reference)
    patch_export_graph(reference, height, width, gpu_safe=False)
    patch_export_graph(candidate, height, width, gpu_safe=True)
    verify_equivalence(reference, candidate, height, width)
    if args.head_mode == "standard-mobile":
        rewrite_standard_upsampling_head(candidate)
        report_standard_head_equivalence(reference, candidate, height, width)
    elif args.head_mode == "bilinear":
        full_head = copy.deepcopy(candidate)
        bypass_npu_upsampling_head(candidate)
        report_head_difference(full_head, candidate, height, width)
    elif args.head_mode == "encoder-mosaic":
        candidate = EncoderMosaic(candidate).eval()
    elif args.head_mode == "stage2-mosaic":
        candidate = Stage2Mosaic(candidate).eval()
    elif args.head_mode == "decoder-mosaic":
        candidate = DecoderMosaic(candidate).eval()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    export_onnx(candidate, height, width, args.output, args.opset)


if __name__ == "__main__":
    main()
