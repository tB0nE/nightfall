#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TOOLS="$ROOT/tools/experiments/browser-quest-linux"
WORK="$ROOT/.build-cache/browser-quest-linux/lab-build"
SDK=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}
: "${SDK:?Set ANDROID_HOME to the Android SDK}"
BT="$SDK/build-tools/36.1.0"
ANDROID_JAR="$SDK/platforms/android-36/android.jar"
mkdir -p "$WORK/classes" "$WORK/dex"
javac -source 8 -target 8 -classpath "$ANDROID_JAR" -d "$WORK/classes" "$TOOLS"/lab/*.java
mapfile -t classes < <(rg --files "$WORK/classes" -g '*.class')
"$BT/d8" --release --min-api 28 --lib "$ANDROID_JAR" --output "$WORK/dex" "${classes[@]}"
"$BT/aapt2" link -o "$WORK/unsigned.apk" -I "$ANDROID_JAR" --manifest "$TOOLS/lab/AndroidManifest.xml"
(cd "$WORK/dex" && zip -q "$WORK/unsigned.apk" classes.dex)
"$BT/zipalign" -f 4 "$WORK/unsigned.apk" "$WORK/aligned.apk"
if [[ ! -f "$WORK/lab.keystore" ]]; then
  keytool -genkeypair -keystore "$WORK/lab.keystore" -storepass android -keypass android \
    -alias lab -keyalg RSA -keysize 2048 -validity 3650 -dname 'CN=Nightfall Browser Lab'
fi
"$BT/apksigner" sign --ks "$WORK/lab.keystore" --ks-pass pass:android \
  --key-pass pass:android --ks-key-alias lab --out "$WORK/Nightfall-Browser-Lab.apk" "$WORK/aligned.apk"
"$BT/apksigner" verify "$WORK/Nightfall-Browser-Lab.apk"
echo "$WORK/Nightfall-Browser-Lab.apk"
