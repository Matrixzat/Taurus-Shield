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

echo "=== Running frida-dexdump (spawn mode — Frida 17 auto-resumes) ==="
mkdir -p dex_raw
# frida-dexdump -U -f spawns the app and scans memory for DEX magic bytes
# Frida 17 removed --no-pause; spawn+script auto-resumes by default
timeout 120 python3 -m frida_dexdump -U -f "$PKG" -o dex_raw/ 2>&1 | tee frida_output.txt || true

echo ""
echo "=== Raw dump results ==="
find dex_raw -type f | sort
echo "Total DEX files: $(find dex_raw -name '*.dex' 2>/dev/null | wc -l)"

echo ""
echo "=== Fallback: custom hook via frida -f (if dexdump found nothing) ==="
DEX_COUNT=$(find dex_raw -name '*.dex' 2>/dev/null | wc -l)
if [ "$DEX_COUNT" -eq 0 ]; then
  echo "frida-dexdump found 0 files — trying custom ClassLinker hook..."
  mkdir -p dex_hook
  timeout 90 frida -U -f "$PKG" -l .github/scripts/dump_dex.js 2>&1 | tee -a frida_output.txt || true

  # Give app time to load classes then pull
  sleep 5
  adb pull "/data/data/$PKG/files/" dex_hook/ 2>&1 || true
  find dex_hook -name '*.dex' -exec cp {} dex_raw/ \; 2>/dev/null || true
  echo "Hook method found: $(find dex_raw -name '*.dex' | wc -l) DEX file(s)"
fi

echo ""
echo "=== Pulling additional files from device ==="
mkdir -p dex_output
cp dex_raw/*.dex dex_output/ 2>/dev/null || true
adb pull "/data/data/$PKG/files/" dex_output/ 2>&1 || true

echo "=== Final DEX count ==="
find dex_output -name '*.dex' | sort
echo "Total: $(find dex_output -name '*.dex' | wc -l) DEX file(s)"
