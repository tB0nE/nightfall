#!/usr/bin/env python3
"""Check small committed generated inputs and build invariants."""

from __future__ import annotations

import hashlib
import re
import subprocess
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def check_spirv_header() -> None:
    binary_path = PROJECT_ROOT / "addons/nightfall-stream/src/video/ycbcr_to_rgba.spv"
    header_path = PROJECT_ROOT / "addons/nightfall-stream/src/video/ycbcr_to_rgba_spirv.h"
    header = header_path.read_text(encoding="utf-8")
    array_match = re.search(r"YCBCR_TO_RGBA_SPIRV\[\]\s*=\s*\{(.*?)\};", header, re.DOTALL)
    if not array_match:
        fail(f"could not parse byte array in {header_path.relative_to(PROJECT_ROOT)}")
    header_bytes = bytes(int(value, 16) for value in re.findall(r"0x([0-9a-fA-F]{2})", array_match.group(1)))
    binary = binary_path.read_bytes()
    if header_bytes != binary:
        fail("ycbcr_to_rgba_spirv.h does not match ycbcr_to_rgba.spv")
    length_match = re.search(r"YCBCR_TO_RGBA_SPIRV_LEN\s*=\s*(\d+)", header)
    if not length_match or int(length_match.group(1)) != len(binary):
        fail("YCBCR_TO_RGBA_SPIRV_LEN does not match the SPIR-V binary size")


def check_litert_checksum() -> None:
    versions_path = PROJECT_ROOT / "tools/build_support/native_xr_versions.sh"
    versions = versions_path.read_text(encoding="utf-8")
    checksum_match = re.search(r'^NIGHTFALL_LITERT_GPU_AAR_SHA256="([0-9a-f]{64})"$', versions, re.MULTILINE)
    if not checksum_match:
        fail("LiteRT checksum is missing from native_xr_versions.sh")
    aar_path = PROJECT_ROOT / "android/libs/litert-gpu-nightfall-1.4.2.aar"
    actual = hashlib.sha256(aar_path.read_bytes()).hexdigest()
    if actual != checksum_match.group(1):
        fail(f"checksum mismatch for {aar_path.relative_to(PROJECT_ROOT)}")


def check_native_xr_descriptor() -> None:
    descriptor_path = PROJECT_ROOT / "extensions/nightfall-xr/bin/nightfall-xr.gdextension"
    descriptor = descriptor_path.read_text(encoding="utf-8")
    expected = {
        'android.arm64.single.debug = "./android/libnightfall-xr.android.template_debug.arm64.so"',
        'android.arm64.single.release = "./android/libnightfall-xr.android.template_release.arm64.so"',
    }
    missing = sorted(line for line in expected if line not in descriptor)
    if missing:
        fail(f"native-XR descriptor is missing: {', '.join(missing)}")


def check_tracked_artifacts() -> None:
    result = subprocess.run(
        ["git", "ls-files", "-z", "*.apk", "*.AppImage", "*.so", "*.a"],
        cwd=PROJECT_ROOT,
        check=True,
        capture_output=True,
    )
    artifacts = [item.decode() for item in result.stdout.split(b"\0") if item]
    if artifacts:
        fail(f"compiled artifacts are tracked: {', '.join(artifacts)}")


def main() -> int:
    check_spirv_header()
    check_litert_checksum()
    check_native_xr_descriptor()
    check_tracked_artifacts()
    print("Generated files and build invariants are consistent")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
