#!/bin/zsh
# Runs the tests, then builds Email.app next to this script.
#   ./build.sh          → Email.app
#   ./build.sh --demo   → "Email Demo.app": separate data and Keychain, starts at onboarding like a new user
#   ./build.sh --release → signed with Developer ID, hardened runtime, notarized by Apple, zipped for download.
#                          One-time setup: a "Developer ID Application" certificate in Keychain, then
#                          xcrun notarytool store-credentials email-notary --apple-id YOU --team-id TEAM
set -euo pipefail
cd "$(dirname "$0")"
NAME=Lightmail; BUNDLE_ID=local.email.app  # dev bundle id kept so settings and Keychain carry over
MODE="${1:-}"
if [[ "$MODE" == "--demo" ]]; then NAME="Lightmail Demo"; BUNDLE_ID=local.email.app.demo; fi
if [[ "$MODE" == "--release" ]]; then
  BUNDLE_ID="${RELEASE_BUNDLE_ID:-org.truecompetitors.lightmail}"
  RELEASE_ID=$(security find-identity -v -p codesigning | grep -m1 "Developer ID Application" | awk '{print $2}' || true)
  if [[ -z "$RELEASE_ID" ]]; then
    echo "No 'Developer ID Application' certificate found. Create one at developer.apple.com → Certificates (Account Holder role), install it, then rerun."
    exit 1
  fi
fi
swift test
swift build -c release
APP="$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Built-in Google sign-in: users never see Google Cloud. Set GOOGLE_CLIENT_JSON to use a different client file.
CLIENT="${GOOGLE_CLIENT_JSON:-$HOME/Library/Application Support/Email/google_client.json}"
if [[ -f "$CLIENT" ]]; then cp "$CLIENT" "$APP/Contents/Resources/google_client.json"
else echo "Note: no Google client file at $CLIENT; this build will ask users to set one up."; fi
cp .build/release/Email "$APP/Contents/MacOS/Email"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Email</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoadsInWebContent</key><true/></dict>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Lightmail shows your schedule next to your inbox and turns emails into calendar events.</string>
</dict></plist>
PLIST
if [[ "$MODE" == "--release" ]]; then
  # Hardened runtime + entitlements, then Apple's notarization so it opens on any Mac without warnings.
  codesign --force --options runtime --timestamp --entitlements Email.entitlements --sign "$RELEASE_ID" "$APP"
  ZIP="$NAME-$(date +%Y%m%d).zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile email-notary --wait
  xcrun stapler staple "$APP"
  rm "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"   # re-zip with the notarization ticket attached
  echo "Release ready: $(pwd)/$ZIP"
  exit 0
fi
# Sign with a stable identity so macOS recognizes rebuilds as the same app.
# Otherwise every build re-triggers the Keychain "Email wants to use..." prompt.
IDENTITY=$(security find-identity -v -p codesigning | grep -m1 "Apple Development" | awk '{print $2}' || true)
if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "No Apple Development certificate found; using ad-hoc signing (Keychain will ask after each rebuild)."
  codesign --force --sign - "$APP"
fi
echo "Built $(pwd)/$APP"
