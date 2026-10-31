#!/usr/bin/env bash
# Lightweight syntax check for Linux workstations. This does not replace Xcode: it only parses
# Swift source and cannot resolve SwiftUI/UIKit. Run the real build on macOS with Xcode.
set -euo pipefail
SWIFTC="${SWIFTC:-swiftc}"
find WardiOS -name '*.swift' -print0 | xargs -0 "$SWIFTC" -frontend -parse
echo "Swift sources parse cleanly."
