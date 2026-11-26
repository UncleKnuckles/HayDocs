#!/bin/sh
# Builds the probe app for the simulator, runs it on the iPhone Duo simulator and collects its output.
set -u
O=out/sim
mkdir -p "$O" build
DEVICE_ID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
found = ""
for runtime in sorted(devices, reverse=True):
    if "iOS" in runtime:
        for d in devices[runtime]:
            if d["name"] == "iPhone Duo" and not found:
                found = d["udid"]
if not found:
    for runtime in sorted(devices, reverse=True):
        if "iOS" in runtime:
            for d in devices[runtime]:
                if d["name"].startswith("iPhone") and not found:
                    found = d["udid"]
print(found)
')
xcrun simctl list devices available | grep "$DEVICE_ID" | tee "$O/simulator.txt"
xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE_ID" -b > /dev/null 2>&1 || true
APP=build/Probe.app
mkdir -p "$APP/docs"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
ARCH=$(uname -m)
xcrun --sdk iphonesimulator swiftc -swift-version 5 -parse-as-library -module-name Probe \
  -target "$ARCH-apple-ios17.0-simulator" -sdk "$SDK" probe/app/Probe.swift -o "$APP/Probe" 2>&1 | tee "$O/compile.log"
cp probe/app/Info.plist "$APP/"
cp probe/docs/*.docx "$APP/docs/"
codesign --force --sign - "$APP" 2>&1 | tee -a "$O/compile.log"
[ -f "$APP/Probe" ] || { echo "no binary"; exit 1; }
xcrun simctl install "$DEVICE_ID" "$APP"
DATA=$(xcrun simctl get_app_container "$DEVICE_ID" com.haydocs.qlprobe data)
echo "data: $DATA"
xcrun simctl launch "$DEVICE_ID" com.haydocs.qlprobe
D="$DATA/Documents/out"
n=0
while [ $n -lt 1200 ]; do
  [ -f "$D/done.txt" ] && break
  for r in "$D"/ql-ready-*.txt; do
    [ -f "$r" ] || continue
    k=$(basename "$r" .txt | sed 's/ql-ready-//')
    [ -f "$D/ql-shot-$k.txt" ] && continue
    name=$(cat "$r")
    xcrun simctl io "$DEVICE_ID" screenshot "$O/ql-$name.png" >> "$O/shots.log" 2>&1 || xcrun simctl io "$DEVICE_ID" screenshot --display=internal "$O/ql-$name.png" >> "$O/shots.log" 2>&1
    echo shot > "$D/ql-shot-$k.txt"
  done
  sleep 0.5
  n=$((n + 1))
done
xcrun simctl io "$DEVICE_ID" screenshot "$O/final.png" > /dev/null 2>&1
cp -R "$D/." "$O/" 2>/dev/null || true
ls "$O" | head -100
