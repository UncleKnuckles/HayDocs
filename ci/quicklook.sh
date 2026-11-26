#!/bin/sh
# Opens the Word files the UI test exported the way iPhone previews show them (Quick Look, as in
# Files, Mail and WhatsApp) on the same simulator, and keeps where each picture landed and
# screenshots in build/results/quicklook.
set -u
R=build/results
O="$R/quicklook"
mkdir -p "$O"
ID=$(cat build/simulator-id.txt 2>/dev/null || true)
[ -n "$ID" ] || { echo "no simulator" | tee "$O/log.txt"; exit 0; }
ls "$R"/app-debug/export-*.docx > /dev/null 2>&1 || { echo "no exported Word files" | tee "$O/log.txt"; exit 0; }
xcrun simctl boot "$ID" 2>/dev/null || true
xcrun simctl bootstatus "$ID" -b > /dev/null 2>&1 || true
APP=build/QuickLookCheck.app
rm -rf "$APP"
mkdir -p "$APP/docs"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun --sdk iphonesimulator swiftc -swift-version 5 -parse-as-library -module-name QuickLookCheck \
  -target "$(uname -m)-apple-ios17.0-simulator" -sdk "$SDK" ci/quicklook/QuickLookCheck.swift \
  -o "$APP/QuickLookCheck" > "$O/compile.log" 2>&1
cp ci/quicklook/Info.plist "$APP/"
cp "$R"/app-debug/export-*.docx "$APP/docs/"
codesign --force --sign - "$APP" >> "$O/compile.log" 2>&1
[ -f "$APP/QuickLookCheck" ] || { echo "the check did not build" | tee -a "$O/log.txt"; exit 0; }
xcrun simctl install "$ID" "$APP"
DATA=$(xcrun simctl get_app_container "$ID" com.haydocs.quicklookcheck data)
xcrun simctl launch "$ID" com.haydocs.quicklookcheck > /dev/null
n=0
while [ $n -lt 300 ] && [ ! -f "$DATA/Documents/out/done.txt" ]; do
  sleep 1
  n=$((n + 1))
done
cp -R "$DATA/Documents/out/." "$O/" 2>/dev/null || true
xcrun simctl terminate "$ID" com.haydocs.quicklookcheck > /dev/null 2>&1 || true
ls "$O" | head -60
