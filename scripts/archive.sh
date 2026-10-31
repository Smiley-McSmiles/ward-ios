#!/usr/bin/env bash
# Create an App Store archive and export an IPA. Run on macOS with Xcode 16+.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple team id}"
: "${APPSTORE_KEY_ID:?Set APPSTORE_KEY_ID}"
: "${APPSTORE_ISSUER_ID:?Set APPSTORE_ISSUER_ID}"
: "${APPSTORE_KEY_PATH:?Set APPSTORE_KEY_PATH to your AuthKey_*.p8}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
mkdir -p build
xcodebuild \
  -project Ward.xcodeproj \
  -scheme Ward \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -archivePath build/Ward.xcarchive \
  ARCHIVE=YES \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$APPSTORE_KEY_PATH" \
  -authenticationKeyID "$APPSTORE_KEY_ID" \
  -authenticationKeyIssuerID "$APPSTORE_ISSUER_ID" \
  archive
xcodebuild \
  -exportArchive \
  -archivePath build/Ward.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist ExportOptions.plist \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$APPSTORE_KEY_PATH" \
  -authenticationKeyID "$APPSTORE_KEY_ID" \
  -authenticationKeyIssuerID "$APPSTORE_ISSUER_ID"
echo "IPA: build/export/Ward.ipa (build $BUILD_NUMBER)"
