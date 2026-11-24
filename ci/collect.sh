#!/bin/sh
# Gathers what the cloud build produced into build/results (pushed to the ci-results branch).
set -u
R=build/results
rm -rf "$R"
mkdir -p "$R/shots" "$R/app-debug" "$R/logs"
for f in tools.txt simulators.txt simulator.txt; do [ -f "build/$f" ] && cp "build/$f" "$R/logs/"; done
for f in device.log uitest.log engine-ios.log engine-sim.log; do
  [ -f "build/$f" ] || continue
  grep -nE "error:|warning: .*(deprecated|will never|never mutated|unused)|BUILD (SUCCEEDED|FAILED)|TEST (SUCCEEDED|FAILED)|Test Case .*(passed|failed)|XCTAssert|failed" "build/$f" | head -400 > "$R/logs/$f.summary.txt"
  tail -250 "build/$f" > "$R/logs/$f.tail.txt"
done
if [ -d build/UITests.xcresult ]; then
  xcrun xcresulttool export attachments --path build/UITests.xcresult --output-path "$R/shots" >/dev/null 2>&1 || true
  if [ -f "$R/shots/manifest.json" ]; then
    python3 - "$R/shots" <<'PY'
import json, os, sys
folder = sys.argv[1]
manifest = json.load(open(os.path.join(folder, "manifest.json")))
for test in manifest:
    for a in test.get("attachments", []):
        src = os.path.join(folder, a["exportedFileName"])
        name = a.get("suggestedHumanReadableName") or a["exportedFileName"]
        name = name.replace("/", "-")
        if os.path.exists(src):
            os.rename(src, os.path.join(folder, name))
PY
  fi
  xcrun xcresulttool get test-results summary --path build/UITests.xcresult > "$R/logs/test-summary.json" 2>/dev/null || true
fi
ID=$(cat build/simulator-id.txt 2>/dev/null || true)
if [ -n "$ID" ]; then
  DATA=$(xcrun simctl get_app_container "$ID" com.haydocs.reader data 2>/dev/null || true)
  if [ -n "$DATA" ] && [ -d "$DATA/Documents/Debug" ]; then
    cp -R "$DATA/Documents/Debug/." "$R/app-debug/"
  fi
fi
[ -f build/HayDocs.ipa ] && cp build/HayDocs.ipa "$R/"
echo "run ${GITHUB_RUN_NUMBER:-local} commit ${GITHUB_SHA:-}" > "$R/README.txt"
du -sh "$R"/* || true
