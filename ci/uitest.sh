#!/bin/sh
# Runs the UI test on the iPhone Duo simulator (another iPhone if there is none).
set -u
mkdir -p build
xcrun simctl list devices available > build/simulators.txt
DEVICE_ID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
found = ""
for runtime in sorted(devices, reverse=True):
    if "iOS" not in runtime:
        continue
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
echo "$DEVICE_ID" > build/simulator-id.txt
grep "$DEVICE_ID" build/simulators.txt | tee build/simulator.txt
xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE_ID" -b >/dev/null 2>&1 || true
set -o pipefail
xcodebuild test -project HayDocs.xcodeproj -scheme HayDocs -configuration Debug \
  -destination "id=$DEVICE_ID" -derivedDataPath build/sim -resultBundlePath build/UITests.xcresult \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tee build/uitest.log | xcbeautify --quiet
