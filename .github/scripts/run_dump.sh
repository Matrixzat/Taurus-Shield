#!/usr/bin/env bash
set -e
PKG="$1"
echo "=== Target package: $PKG ==="

echo "=== Rooting emulator ==="
adb root && sleep 3
adb remount || true

echo "=== Installing APK ==="
adb install -r input.apk
echo "APK installed"

echo "=== Pushing frida-server ==="
adb push frida-server-bin /data/local/tmp/frida-server
adb shell chmod 755 /data/local/tmp/frida-server

echo "=== Starting frida-server ==="
adb shell "nohup /data/local/tmp/frida-server > /dev/null 2>&1 &"
sleep 5

echo "=== Verifying frida-server ==="
adb shell "ps -e | grep frida" || true

echo "=== Pushing dump_dex.js ==="
adb push .github/scripts/dump_dex.js /data/local/tmp/dump_dex.js

echo "=== Spawning $PKG with Frida ==="
timeout 120 frida -U -f "$PKG" -l .github/scripts/dump_dex.js --no-pause 2>&1 | tee frida_output.txt || true

echo ""
echo "=== Frida output ==="
cat frida_output.txt

echo ""
echo "=== Pulling dumped DEX files ==="
mkdir -p dex_output
adb pull "/data/data/$PKG/files/dump_dex_$PKG/" dex_output/ 2>&1 || \
adb pull "/data/data/$PKG/files/" dex_output/ 2>&1 || true

echo "=== Dump results ==="
find dex_output -type f -name "*.dex" | sort
ls -lh dex_output/ 2>/dev/null || echo "No files pulled"
