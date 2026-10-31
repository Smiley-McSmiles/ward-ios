#!/usr/bin/env bash
# Build Ward for the iOS Simulator. Requires macOS with Xcode 15.4+.
set -euo pipefail
cd "$(dirname "$0")/.."
DESTINATION="${DESTINATION:-platform=iOS Simulator,name=iPhone 16}"
xcodebuild -project Ward.xcodeproj \
  -scheme Ward \
  -configuration Debug \
  -destination "$DESTINATION" \
  build
