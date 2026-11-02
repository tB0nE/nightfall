#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TOOLS="$ROOT/tools/experiments/quest-browser-display"
WORK="$ROOT/.build-cache/quest-browser-display"
SDK=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}
: "${SDK:?Set ANDROID_HOME}"
BT="$SDK/build-tools/36.1.0"
JAR="$SDK/platforms/android-36/android.jar"
mkdir -p "$WORK/classes" "$WORK/dex"
javac -source 8 -target 8 -classpath "$JAR" -d "$WORK/classes" "$TOOLS"/*.java
mapfile -t classes < <(rg --files "$WORK/classes" -g '*.class')
"$BT/d8" --release --min-api 29 --lib "$JAR" --output "$WORK/dex" "${classes[@]}"
"$BT/aapt2" link -o "$WORK/unsigned.apk" -I "$JAR" --manifest "$TOOLS/AndroidManifest.xml"
(cd "$WORK/dex" && zip -q "$WORK/unsigned.apk" classes.dex)
"$BT/zipalign" -f 4 "$WORK/unsigned.apk" "$WORK/aligned.apk"
if [[ ! -f "$WORK/probe.keystore" ]]; then
  keytool -genkeypair -keystore "$WORK/probe.keystore" -storepass android -keypass android \
    -alias probe -keyalg RSA -keysize 2048 -validity 3650 -dname 'CN=Nightfall display capability probe'
fi
"$BT/apksigner" sign --ks "$WORK/probe.keystore" --ks-pass pass:android \
  --key-pass pass:android --ks-key-alias probe --out "$WORK/Nightfall-Browser-Display-Probe.apk" "$WORK/aligned.apk"
"$BT/apksigner" verify "$WORK/Nightfall-Browser-Display-Probe.apk"
echo "$WORK/Nightfall-Browser-Display-Probe.apk"
