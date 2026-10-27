#!/usr/bin/env bash
set -euo pipefail
BLOCKER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLOCKER_LOCK_HASH="$(sha256sum "$BLOCKER_ROOT/Cargo.lock" | cut -d ' ' -f 1)"
if ! grep -Fq "Cargo.lock SHA256: $BLOCKER_LOCK_HASH" "$BLOCKER_ROOT/../../licences/browser-adblock-dependencies.txt"; then
    echo "Regenerate browser adblock dependency notices for the current Cargo.lock before packaging." >&2
    exit 1
fi
BLOCKER_NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-/home/linuxbrew/.linuxbrew/share/android-commandlinetools/ndk/29.0.14206865}}"
BLOCKER_TOOLCHAIN="$BLOCKER_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$BLOCKER_TOOLCHAIN/aarch64-linux-android26-clang"
export RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-Wl,-z,max-page-size=16384"
"${NIGHTFALL_CARGO:-$HOME/.cargo/bin/cargo}" build --locked --release \
    --target aarch64-linux-android --manifest-path "$BLOCKER_ROOT/Cargo.toml"
