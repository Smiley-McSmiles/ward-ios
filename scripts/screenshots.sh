#!/usr/bin/env bash
# Capture App Store screenshots from the simulator using Ward's demo data.
# Requires macOS, Xcode and a built simulator app.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${APP_PATH:-build/Build/Products/Debug-iphonesimulator/Ward.app}"
OUT="${OUT_DIR:-fastlane/screenshots/en-US}"
mkdir -p "$OUT"

pick_device() {
  local wanted="$1"
  local fallback="$2"
  if xcrun simctl list devices available | grep -q "$wanted ("; then echo "$wanted"; else echo "$fallback"; fi
}

capture() {
  local device="$1"
  local prefix="$2"
  if ! xcrun simctl list devices available | grep -q "$device ("; then
    echo "Skipping unavailable simulator: $device"
    return
  fi
  xcrun simctl boot "$device" 2>/dev/null || true
  xcrun simctl bootstatus "$device" -b
  xcrun simctl install "$device" "$APP"
  xcrun simctl privacy "$device" grant notifications org.ward.ios 2>/dev/null || true
  xcrun simctl status_bar "$device" override --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 2>/dev/null || true

  for spec in "chats:-ward-demo" "conversation:-ward-demo -ward-demo-chat" "settings:-ward-demo -ward-demo-settings"; do
    local name="${spec%%:*}"
    local args="${spec#*:}"
    xcrun simctl terminate "$device" org.ward.ios 2>/dev/null || true
    xcrun simctl launch "$device" org.ward.ios $args >/dev/null
    sleep 5
    xcrun simctl io "$device" screenshot "$OUT/${prefix}-${name}.png"
  done
  xcrun simctl terminate "$device" org.ward.ios 2>/dev/null || true
}

PHONE=$(pick_device "iPhone 16 Pro Max" "iPhone 16 Plus")
TABLET=$(pick_device "iPad Pro 13-inch (M4)" "iPad Pro (12.9-inch) (6th generation)")
capture "$PHONE" "6.9-inch"
capture "$TABLET" "13-inch-ipad"
echo "Screenshots written to $OUT"
