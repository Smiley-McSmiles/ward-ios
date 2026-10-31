#!/usr/bin/env bash
# Capture iPhone App Store screenshots from the simulator using Ward's demo data.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${APP_PATH:-build/Build/Products/Debug-iphonesimulator/Ward.app}"
OUT="${OUT_DIR:-fastlane/screenshots/en-US}"
DEVICE="${DEVICE:-iPhone 16 Pro Max}"
PREFIX="${PREFIX:-6.9-inch}"
mkdir -p "$OUT"
echo "Device: $DEVICE"
echo "App: $APP"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl privacy "$DEVICE" grant notifications org.ward.ios 2>/dev/null || true
xcrun simctl status_bar "$DEVICE" override --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 2>/dev/null || true

shoot() {
  local name="$1"
  shift
  echo "Capturing $name"
  xcrun simctl terminate "$DEVICE" org.ward.ios 2>/dev/null || true
  xcrun simctl launch "$DEVICE" org.ward.ios "$@" >/dev/null
  sleep 5
  xcrun simctl io "$DEVICE" screenshot "$OUT/${PREFIX}-${name}.png"
}
shoot chats -ward-demo
shoot conversation -ward-demo -ward-demo-chat
shoot settings -ward-demo -ward-demo-settings
xcrun simctl terminate "$DEVICE" org.ward.ios 2>/dev/null || true
ls -la "$OUT"
