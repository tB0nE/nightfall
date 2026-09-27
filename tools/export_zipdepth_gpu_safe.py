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
from zipdepth_hybrid_v2 import install_hybrid_v2_head  # noqa: E402


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


def expand_unaligned_grouped_convolution(model: nn.Module) -> None:
    """Avoid LiteRT's OpenGL-only grouped-convolution split shader gap.

    The hybrid checkpoint has one 1x1 grouped convolution with four groups,
    six input channels per group and eight output channels per group. LiteRT
    rewrites it to SPLIT -> four convolutions -> CONCAT because six is not a
    multiple of four, but its OpenGL backend has no SPLIT shader. An ordinary
    convolution with block-diagonal weights is mathematically identical and
    stays a single supported TFLite CONV_2D operation.
    """
    expanded = 0
    for name, module in list(model.named_modules()):
        if not isinstance(module, nn.Conv2d) or module.groups <= 1:
            continue
        if module.groups == module.in_channels:  # Native depthwise path.
            continue
        input_per_group = module.in_channels // module.groups
        output_per_group = module.out_channels // module.groups
        if input_per_group % 4 == 0 and output_per_group % 4 == 0:
            continue

        dense = nn.Conv2d(
            module.in_channels, module.out_channels, module.kernel_size,
            stride=module.stride, padding=module.padding,
            dilation=module.dilation, groups=1, bias=module.bias is not None,
            padding_mode=module.padding_mode,
        ).to(device=module.weight.device, dtype=module.weight.dtype)
        with torch.no_grad():
            dense.weight.zero_()
            for group in range(module.groups):
                out_slice = slice(group * output_per_group, (group + 1) * output_per_group)
                in_slice = slice(group * input_per_group, (group + 1) * input_per_group)
                dense.weight[out_slice, in_slice].copy_(module.weight[out_slice])
            if module.bias is not None:
                dense.bias.copy_(module.bias)
        parent_name, _, child_name = name.rpartition(".")
        parent = model.get_submodule(parent_name) if parent_name else model
        parent._modules[child_name] = dense
        expanded += 1
        print(f"Expanded unaligned grouped convolution: {name}")
    if expanded != 1:
        raise RuntimeError(f"Expected one unaligned grouped convolution, found {expanded}")


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


def expose_half_resolution_depth(model: nn.Module) -> None:
    """Return the decoder's trained half-resolution depth before upsampling.

    A 384x384 ZipDepth input naturally produces a 192x192 depth prediction.
    This keeps the complete encoder, feature pyramid, half-resolution fusion,
    and trained depth head; only the final learned 2x reconstruction is
    omitted so Nightfall's existing colour-guided pass can upscale it.
    """
    decoder = model.decoder

    def forward_direct_half(self_m, s_half, feats, _size):
        c1, c2, c3, c4 = feats
        f4 = self_m.proj4(c4)
        f3 = self_m.fuse3(c3, f4)
        f2 = self_m.fuse2(c2, f3)
        f1 = self_m.fuse1(c1, f2)
        f_half = self_m.fuse_half(s_half, f1)
        return F.relu(self_m.head_half(f_half))

    decoder.forward = types.MethodType(forward_direct_half, decoder)


def install_profile_probe(model: nn.Module, stage: str) -> None:
    """Stop Standard at a cumulative profiling boundary.

    These probes are diagnostic models, not candidate heads.  The f1/f_half
    probes use a fixed channel-average 1x1 projection so both expose a
    192x192x1 tensor.  Later probes expose their natural cumulative tensors;
    concatenating depth_half prevents conversion from pruning the Direct path.
    """
    decoder = model.decoder
    if stage == "f1":
        channels = decoder.fuse1.proj_high.out_channels
    elif stage == "f-half":
        channels = decoder.fuse_half.proj_high.out_channels
    else:
        channels = 0

    if channels:
        projection = nn.Conv2d(channels, 1, 1, bias=False)
        with torch.no_grad():
            projection.weight.fill_(1.0 / channels)
        projection.weight.requires_grad_(False)
        decoder.add_module("profile_projection", projection)

    if stage in ("weighted",):
        neighbor_conv = nn.Conv2d(1, 9, 3, bias=False)
        with torch.no_grad():
            neighbor_conv.weight.zero_()
            for index in range(9):
                neighbor_conv.weight[index, 0, index // 3, index % 3] = 1.0
        neighbor_conv.weight.requires_grad_(False)
        decoder.add_module("profile_neighbor_conv", neighbor_conv)

    def forward_probe(self_m, s_half, feats, _size):
        c1, c2, c3, c4 = feats
        f4 = self_m.proj4(c4)
        f3 = self_m.fuse3(c3, f4)
        f2 = self_m.fuse2(c2, f3)
        f1 = self_m.fuse1(c1, f2)
        if stage == "f1":
            projected = self_m.profile_projection(f1)
            return F.interpolate(
                projected, scale_factor=2, mode="bilinear", align_corners=False
            )

        f_half = self_m.fuse_half(s_half, f1)
        if stage == "f-half":
            return self_m.profile_projection(f_half)

        depth_half = self_m.head_half(f_half)
        mask_logits = self_m.convex_up.mask_pred(f_half)
        if stage == "mask":
            return torch.cat((depth_half, mask_logits), dim=1)

        batch, _, height, width = mask_logits.shape
        mask = mask_logits.view(batch, 9, 4, height, width)
        mask = F.softmax(mask / self_m.convex_up.temperature, dim=1)
        mask_flat = mask.reshape(batch, 36, height, width)
        if stage == "softmax":
            return torch.cat((depth_half, mask_flat), dim=1)

        depth_pad = F.pad(depth_half, (1, 1, 1, 1), mode="replicate")
        neighbors = self_m.profile_neighbor_conv(depth_pad)
        subpixels = []
        for index in range(4):
            weights = mask[:, :, index, :, :]
            subpixels.append((weights * neighbors).sum(dim=1, keepdim=True))
        return torch.cat(subpixels, dim=1)

    decoder.forward = types.MethodType(forward_probe, decoder)


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


def rewrite_standard_upsampling_head_v2(model: nn.Module) -> None:
    """Vectorize the exact standard convex head for mobile GPU execution.

    ``rewrite_standard_upsampling_head`` deliberately emits four independent
    subpixel branches.  That graph proved correct on Adreno, but onnx2tf lowers
    each branch to its own GATHER/TRANSPOSE/MUL/SUM chain.  This version keeps
    all four subpixels in one tensor, explicitly duplicates the nine depth
    neighbours to avoid unsafe implicit broadcasting, and performs the four
    reductions with one fixed 1x1 convolution.  The weights and mathematics
    are unchanged; only the graph layout differs.
    """
    upsampler = model.decoder.convex_up
    if not upsampler.use_unfold:
        raise ValueError("standard-mobile-v2 rewrite requires the standard unfold head")

    def forward_mobile_v2(self_m, feat, depth):
        batch, _, height, width = depth.shape
        subpixel_count = self_m.scale * self_m.scale

        # Preserve the checkpoint's [neighbour, subpixel] channel ordering.
        mask = self_m.mask_pred(feat)
        mask = mask.view(batch, 9, subpixel_count, height, width)
        mask = F.softmax(mask / self_m.temperature, dim=1)

        kernels = depth.new_zeros((9, 1, 3, 3))
        for index in range(9):
            kernels[index, 0, index // 3, index % 3] = 1.0
        depth_pad = F.pad(depth, (1, 1, 1, 1), mode="replicate")
        neighbors = F.conv2d(depth_pad, kernels)

        # CONCAT is well supported by LiteRT GPU and materializes equal shapes
        # before MUL, avoiding the Adreno implicit-broadcast correctness bug.
        neighbors = torch.stack([neighbors] * subpixel_count, dim=2)
        weighted = (mask * neighbors).reshape(
            batch, 9 * subpixel_count, height, width
        )

        # Channel order is neighbour-major: n0s0,n0s1,...,n8s3.  A fixed
        # block-sparse 1x1 convolution computes all four nine-neighbour sums
        # in one GPU kernel instead of four separate reductions.
        reduce_weights = depth.new_zeros(
            (subpixel_count, 9 * subpixel_count, 1, 1)
        )
        for subpixel in range(subpixel_count):
            for neighbor in range(9):
                reduce_weights[subpixel, neighbor * subpixel_count + subpixel, 0, 0] = 1.0
        up = F.conv2d(weighted, reduce_weights)
        return F.relu(F.pixel_shuffle(up, self_m.scale))

    upsampler.forward = types.MethodType(forward_mobile_v2, upsampler)


def rewrite_standard_upsampling_head_v3(model: nn.Module) -> None:
    """Accumulate exact convex weights as GPU-native four-channel vectors.

    V2 materializes all 36 neighbour/subpixel products and reduces them with
    a sparse 1x1 convolution.  That is compact as a graph, but it creates a
    large 192x192x36 intermediate and asks the mobile GPU to read it again.
    V3 instead treats the four output subpixels as one RGBA-like vector and
    adds each of the nine weighted neighbour contributions in sequence.
    LiteRT's GPU graph optimizer can fuse elementwise MUL/ADD chains, while
    every intermediate remains only four channels wide.  The softmax,
    learned masks, neighbours, and final values are mathematically unchanged.
    """
    upsampler = model.decoder.convex_up
    if not upsampler.use_unfold:
        raise ValueError("standard-mobile-v3 rewrite requires the standard unfold head")

    def forward_mobile_v3(self_m, feat, depth):
        batch, _, height, width = depth.shape
        subpixel_count = self_m.scale * self_m.scale

        mask = self_m.mask_pred(feat)
        mask = mask.view(batch, 9, subpixel_count, height, width)
        mask = F.softmax(mask / self_m.temperature, dim=1)

        kernels = depth.new_zeros((9, 1, 3, 3))
        for index in range(9):
            kernels[index, 0, index // 3, index % 3] = 1.0
        depth_pad = F.pad(depth, (1, 1, 1, 1), mode="replicate")
        neighbors = F.conv2d(depth_pad, kernels)

        up = None
        for neighbor in range(9):
            # Materialize four equal channels before MUL.  This preserves the
            # Adreno no-implicit-broadcast rule and aligns each operation to
            # the delegate's native four-channel texture slices.
            value = neighbors[:, neighbor:neighbor + 1, :, :]
            value4 = torch.cat([value] * subpixel_count, dim=1)
            contribution = mask[:, neighbor, :, :, :] * value4
            up = contribution if up is None else up + contribution

        # Anchor the NCHW channel layout before DEPTH_TO_SPACE.  Without this
        # no-op projection, onnx2tf incorrectly folded the elementwise chain's
        # final transpose into pixel shuffle and emitted [1,8,384,48] output.
        # A convolution boundary follows the same proven conversion path as
        # Standard-v2's reducer while reading/writing only four channels.
        identity = depth.new_zeros(
            (subpixel_count, subpixel_count, 1, 1)
        )
        for channel in range(subpixel_count):
            identity[channel, channel, 0, 0] = 1.0
        up = F.conv2d(up, identity)
        return F.relu(F.pixel_shuffle(up, self_m.scale))

    upsampler.forward = types.MethodType(forward_mobile_v3, upsampler)


def rewrite_standard_packed_softmax4(model: nn.Module) -> None:
    """Emit exact packed Standard depth using four GPU-friendly softmaxes.

    The checkpoint stores mask logits neighbour-major as ``n0s0,n0s1,...``.
    The normal export reshapes that into a five-dimensional tensor so one
    softmax can normalize the nine neighbours for all four output subpixels.
    LiteRT lowers that path through multiple transposes and CPU partitions on
    Adreno. Reorder the final learned convolution's output channels once to
    subpixel-major ``s0n0,s0n1,...``. Four contiguous 9-channel tensors can
    then use ordinary 4D channel softmax without changing any values.
    """
    upsampler = model.decoder.convex_up
    if not upsampler.use_unfold:
        raise ValueError("standard-packed-softmax4 requires the standard unfold head")

    final_convs = [
        module for module in upsampler.mask_pred.modules()
        if isinstance(module, nn.Conv2d)
    ]
    if not final_convs or final_convs[-1].out_channels != 36:
        raise RuntimeError("Expected Standard mask predictor to end in 36 channels")
    output_conv = final_convs[-1]
    channel_order = [
        neighbor * 4 + subpixel
        for subpixel in range(4)
        for neighbor in range(9)
    ]
    with torch.no_grad():
        output_conv.weight.copy_(output_conv.weight[channel_order].clone())
        if output_conv.bias is not None:
            output_conv.bias.copy_(output_conv.bias[channel_order].clone())

    def forward_packed_softmax4(self_m, feat, depth):
        mask_logits = self_m.mask_pred(feat)
        mask_groups = torch.split(mask_logits, 9, dim=1)
        masks = [
            F.softmax(group / self_m.temperature, dim=1)
            for group in mask_groups
        ]

        kernels = depth.new_zeros((9, 1, 3, 3))
        for index in range(9):
            kernels[index, 0, index // 3, index % 3] = 1.0
        depth_pad = F.pad(depth, (1, 1, 1, 1), mode="replicate")
        neighbors = F.conv2d(depth_pad, kernels)

        subpixels = [
            (weights * neighbors).sum(dim=1, keepdim=True)
            for weights in masks
        ]
        return torch.cat(subpixels, dim=1)

    upsampler.forward = types.MethodType(forward_packed_softmax4, upsampler)


def rewrite_standard_packed_conv4(
    model: nn.Module, *, convolution_reduction: bool = False,
    delegate_safe_padding: bool = False,
    explicit_replicate_padding: bool = False,
) -> None:
    """Emit exact packed Standard depth without a 36-channel split op.

    The final mask predictor is a 1x1 convolution, so its output channels are
    independent. Four 9-channel convolutions using slices of the same learned
    weights are mathematically equivalent to one 36-channel convolution
    followed by SPLIT, while presenting the GPU delegate with four directly
    consumable softmax inputs.
    """
    upsampler = model.decoder.convex_up
    if not upsampler.use_unfold:
        raise ValueError("standard-packed-conv4 requires the standard unfold head")

    mask_layers = list(upsampler.mask_pred.children())
    if len(mask_layers) != 3 or not isinstance(mask_layers[-1], nn.Conv2d):
        raise RuntimeError("Unexpected Standard mask predictor structure")
    output_conv = mask_layers[-1]
    if output_conv.in_channels != 8 or output_conv.out_channels != 36:
        raise RuntimeError("Expected Standard mask predictor 8->36 output convolution")

    upsampler.mask_softmax4_stem = nn.Sequential(*mask_layers[:-1])
    heads = []
    for subpixel in range(4):
        indices = [neighbor * 4 + subpixel for neighbor in range(9)]
        head = nn.Conv2d(8, 9, kernel_size=1, bias=output_conv.bias is not None)
        with torch.no_grad():
            head.weight.copy_(output_conv.weight[indices])
            if output_conv.bias is not None:
                head.bias.copy_(output_conv.bias[indices])
        heads.append(head)
    upsampler.mask_softmax4_heads = nn.ModuleList(heads)
    # Avoid retaining/exporting an unused duplicate of the predictor weights.
    upsampler.mask_pred = nn.Identity()

    def forward_packed_conv4(self_m, feat, depth):
        hidden = self_m.mask_softmax4_stem(feat)
        masks = [
            F.softmax(head(hidden) / self_m.temperature, dim=1)
            for head in self_m.mask_softmax4_heads
        ]

        kernels = depth.new_zeros((9, 1, 3, 3))
        for index in range(9):
            kernels[index, 0, index // 3, index % 3] = 1.0
        if explicit_replicate_padding:
            # Express replicate padding using only slices and concatenation.
            # Unlike ONNX Pad(mode=edge), these operators are candidates for
            # LiteRT GPU delegation, while preserving Standard-v1 exactly.
            left = depth[:, :, :, :1]
            right = depth[:, :, :, -1:]
            horizontal = torch.cat((left, depth, right), dim=3)
            top = horizontal[:, :, :1, :]
            bottom = horizontal[:, :, -1:, :]
            depth_pad = torch.cat((top, horizontal, bottom), dim=2)
            neighbors = F.conv2d(depth_pad, kernels)
        elif delegate_safe_padding:
            # Replicate padding exports as MIRROR_PAD, which LiteRT 1.4.2's
            # GPU delegate cannot claim. That splits this tiny reconstruction
            # tail into CPU/GPU partitions and forces four 9-channel softmax
            # maps through CPU memory. Zero-padding inside CONV_2D keeps the
            # entire tail delegated; it differs only on the outermost pixel.
            neighbors = F.conv2d(depth, kernels, padding=1)
        else:
            depth_pad = F.pad(depth, (1, 1, 1, 1), mode="replicate")
            neighbors = F.conv2d(depth_pad, kernels)
        products = [weights * neighbors for weights in masks]
        if convolution_reduction:
            # A fixed 1x1 9->1 convolution is the same dot product as SUM,
            # but uses the delegate's best-supported primitive.
            reduction_kernel = depth.new_ones((1, 9, 1, 1))
            subpixels = [
                F.conv2d(product, reduction_kernel) for product in products
            ]
        else:
            subpixels = [
                product.sum(dim=1, keepdim=True) for product in products
            ]
        packed = torch.cat(subpixels, dim=1)
        return packed

    upsampler.forward = types.MethodType(forward_packed_conv4, upsampler)


def rewrite_standard_packed_rgba(model: nn.Module) -> None:
    """Map exact Standard reconstruction onto four-channel GPU lanes.

    Each of the nine neighbours owns four mask logits, one for every 2x2
    output subpixel. Keeping those four values together matches the GPU
    delegate's RGBA texture slices. An explicit stable softmax across nine
    RGBA tensors replaces four generic 9-channel softmax/reduction branches;
    elementwise maximum/exp/add/mul/div chains can be fused by the delegate.
    """
    upsampler = model.decoder.convex_up
    if not upsampler.use_unfold:
        raise ValueError("standard-packed-rgba requires the standard unfold head")

    mask_layers = list(upsampler.mask_pred.children())
    if len(mask_layers) != 3 or not isinstance(mask_layers[-1], nn.Conv2d):
        raise RuntimeError("Unexpected Standard mask predictor structure")
    output_conv = mask_layers[-1]
    if output_conv.in_channels != 8 or output_conv.out_channels != 36:
        raise RuntimeError("Expected Standard mask predictor 8->36 output convolution")

    upsampler.mask_rgba_stem = nn.Sequential(*mask_layers[:-1])
    heads = []
    for neighbor in range(9):
        indices = list(range(neighbor * 4, neighbor * 4 + 4))
        head = nn.Conv2d(8, 4, kernel_size=1, bias=output_conv.bias is not None)
        with torch.no_grad():
            head.weight.copy_(output_conv.weight[indices])
            if output_conv.bias is not None:
                head.bias.copy_(output_conv.bias[indices])
        heads.append(head)
    upsampler.mask_rgba_heads = nn.ModuleList(heads)
    upsampler.mask_pred = nn.Identity()

    def forward_packed_rgba(self_m, feat, depth):
        hidden = self_m.mask_rgba_stem(feat)
        logits = [
            head(hidden) / self_m.temperature for head in self_m.mask_rgba_heads
        ]

        maximum = logits[0]
        for logit in logits[1:]:
            maximum = torch.maximum(maximum, logit)
        exponentials = [torch.exp(logit - maximum) for logit in logits]
        denominator = exponentials[0]
        for exponential in exponentials[1:]:
            denominator = denominator + exponential

        depth_pad = F.pad(depth, (1, 1, 1, 1), mode="replicate")
        weighted = None
        for neighbor, exponential in enumerate(exponentials):
            # Four duplicate outputs place scalar neighbour depth in the same
            # RGBA lanes as its subpixel weights without channel broadcast.
            kernel = depth.new_zeros((4, 1, 3, 3))
            kernel[:, 0, neighbor // 3, neighbor % 3] = 1.0
            neighbor4 = F.conv2d(depth_pad, kernel)
            contribution = exponential * neighbor4
            weighted = contribution if weighted is None else weighted + contribution
        return weighted / denominator

    upsampler.forward = types.MethodType(forward_packed_rgba, upsampler)


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
            "direct-half",
            "bilinear",
            "standard-mobile",
            "standard-mobile-v2",
            "standard-mobile-v3",
            "standard-packed",
            "standard-packed-softmax4",
            "standard-packed-conv4",
            "standard-packed-conv4-reduceconv",
            "standard-packed-conv4-reduceconv-zeropad",
            "standard-packed-conv4-reduceconv-edgepad",
            "standard-packed-rgba",
            "hybrid-v2",
            "profile-f1",
            "profile-f-half",
            "profile-mask",
            "profile-softmax",
            "profile-weighted",
            "encoder-mosaic",
            "stage2-mosaic",
            "decoder-mosaic",
        ),
        default="full",
        help="use the complete NPU blend head or bypass it for diagnosis",
    )
    parser.add_argument(
        "--hybrid-v2-checkpoint",
        type=Path,
        help="trained head checkpoint required by --head-mode hybrid-v2",
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

    standard_modes = (
        "direct-half",
        "standard-mobile",
        "standard-mobile-v2",
        "standard-mobile-v3",
        "standard-packed",
        "standard-packed-softmax4",
        "standard-packed-conv4",
        "standard-packed-conv4-reduceconv",
        "standard-packed-conv4-reduceconv-zeropad",
        "standard-packed-conv4-reduceconv-edgepad",
        "standard-packed-rgba",
        "profile-f1",
        "profile-f-half",
        "profile-mask",
        "profile-softmax",
        "profile-weighted",
    )
    if args.head_mode in standard_modes:
        standard_checkpoint = args.backbone_ckpt or args.ckpt
        reference = load_model(standard_checkpoint, upsample_unfold=True)
    else:
        reference = load_model(args.ckpt, args.backbone_ckpt)
    candidate = copy.deepcopy(reference)
    if args.head_mode == "hybrid-v2":
        if args.hybrid_v2_checkpoint is None:
            parser.error("--head-mode hybrid-v2 requires --hybrid-v2-checkpoint")
        checkpoint = torch.load(
            args.hybrid_v2_checkpoint, map_location="cpu", weights_only=False
        )
        refinement_channels = int(checkpoint.get("refinement_channels", 8))
        correction_limit = float(checkpoint.get("correction_limit", 0.5))
        reference_head = install_hybrid_v2_head(
            reference, refinement_channels, correction_limit
        )
        candidate_head = install_hybrid_v2_head(
            candidate, refinement_channels, correction_limit
        )
        reference_head.load_state_dict(checkpoint["head_state_dict"])
        candidate_head.load_state_dict(checkpoint["head_state_dict"])
    patch_export_graph(reference, height, width, gpu_safe=False)
    patch_export_graph(candidate, height, width, gpu_safe=True)
    expand_unaligned_grouped_convolution(candidate)
    verify_equivalence(reference, candidate, height, width)
    if args.head_mode == "direct-half":
        expose_half_resolution_depth(candidate)
    elif args.head_mode == "standard-mobile":
        rewrite_standard_upsampling_head(candidate)
        report_standard_head_equivalence(reference, candidate, height, width)
    elif args.head_mode == "standard-mobile-v2":
        rewrite_standard_upsampling_head_v2(candidate)
        report_standard_head_equivalence(reference, candidate, height, width)
    elif args.head_mode == "standard-mobile-v3":
        rewrite_standard_upsampling_head_v3(candidate)
        report_standard_head_equivalence(reference, candidate, height, width)
    elif args.head_mode == "standard-packed":
        install_profile_probe(candidate, "weighted")
    elif args.head_mode == "standard-packed-softmax4":
        rewrite_standard_packed_softmax4(candidate)
    elif args.head_mode == "standard-packed-conv4":
        rewrite_standard_packed_conv4(candidate)
    elif args.head_mode == "standard-packed-conv4-reduceconv":
        rewrite_standard_packed_conv4(candidate, convolution_reduction=True)
    elif args.head_mode == "standard-packed-conv4-reduceconv-zeropad":
        rewrite_standard_packed_conv4(
            candidate, convolution_reduction=True, delegate_safe_padding=True
        )
    elif args.head_mode == "standard-packed-conv4-reduceconv-edgepad":
        rewrite_standard_packed_conv4(
            candidate,
            convolution_reduction=True,
            explicit_replicate_padding=True,
        )
    elif args.head_mode == "standard-packed-rgba":
        rewrite_standard_packed_rgba(candidate)
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
    elif args.head_mode.startswith("profile-"):
        install_profile_probe(candidate, args.head_mode.removeprefix("profile-"))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    export_onnx(candidate, height, width, args.output, args.opset)


if __name__ == "__main__":
    main()
