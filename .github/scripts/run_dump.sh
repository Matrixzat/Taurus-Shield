#!/usr/bin/env bash
set -e
PKG="$1"
echo "=== Target package: $PKG ==="

echo "=== Rooting emulator ==="
adb root && sleep 3
adb remount 2>/dev/null || true

echo "=== Installing APK ==="
adb install -r input.apk
echo "APK installed"

echo "=== Pushing frida-server ==="
adb push frida-server-bin /data/local/tmp/frida-server
adb shell chmod 755 /data/local/tmp/frida-server

echo "=== Starting frida-server ==="
adb shell "nohup /data/local/tmp/frida-server > /dev/null 2>&1 &"
sleep 4

echo "=== Verifying frida-server is running ==="
adb shell "ps -e | grep frida-server" || true

echo "=== Launching app via monkey ==="
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1
sleep 5

echo "=== Pushing Frida script ==="
adb push .github/scripts/dump_dex.js /data/local/tmp/dump_dex.js

echo "=== Attaching Frida to $PKG (no-spawn, avoids --no-pause) ==="
timeout 90 frida -U -n "$PKG" -l .github/scripts/dump_dex.js 2>&1 | tee frida_output.txt || true

echo ""
echo "=== Frida output ==="
cat frida_output.txt

echo ""
echo "=== Pulling dumped DEX files ==="
mkdir -p dex_output
adb pull "/data/data/$PKG/files/dump_dex_$PKG/" dex_output/ 2>&1 || \
adb pull "/data/data/$PKG/files/"                dex_output/ 2>&1 || true

echo "=== Dump results ==="
find dex_output -type f -name "*.dex" | sort
echo "Total: $(find dex_output -name '*.dex' | wc -l) DEX file(s)"
