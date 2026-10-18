#!/bin/zsh
# Runs the tests, then builds Keymail.app next to this script.
#   ./build.sh          → Email.app
#   ./build.sh --demo   → "Email Demo.app": separate data and Keychain, starts at onboarding like a new user
#   ./build.sh --release → signed with Developer ID, hardened runtime, notarized by Apple, zipped for download.
#                          One-time setup: a "Developer ID Application" certificate in Keychain, then
#                          xcrun notarytool store-credentials email-notary --apple-id YOU --team-id TEAM
set -euo pipefail
cd "$(dirname "$0")"
NAME=Keymail; BUNDLE_ID=local.email.app  # dev bundle id kept so settings and Keychain carry over
MODE="${1:-}"
if [[ "$MODE" == "--demo" ]]; then NAME="Keymail Demo"; BUNDLE_ID=local.email.app.demo; fi
if [[ "$MODE" == "--release" ]]; then
  BUNDLE_ID="${RELEASE_BUNDLE_ID:-com.dannychait.keymail}"   # permanent once people install the app
  # Sign only with the publishing team (True Competitors, Inc.), never another certificate that happens to be installed.
  RELEASE_TEAM="${RELEASE_TEAM:-SL5NZ49S43}"
  RELEASE_ID=$(security find-identity -v -p codesigning | grep "Developer ID Application" | grep -m1 "($RELEASE_TEAM)" | awk '{print $2}' || true)
  if [[ -z "$RELEASE_ID" ]]; then
    echo "No 'Developer ID Application' certificate for team $RELEASE_TEAM. In Xcode → Settings → Accounts, pick your personal team → Manage Certificates → + → Developer ID Application, then rerun."
    exit 1
  fi
fi
swift test
swift build -c release
APP="$NAME.app"
VERSION=$(cat VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)   # always increases; Sparkle compares this
# Only release builds check for updates: dev and demo builds have different bundle IDs and signatures.
FEED=""
if [[ "$MODE" == "--release" ]]; then
  FEED="<key>SUFeedURL</key><string>https://github.com/dcdunk/keymail-app/releases/latest/download/appcast.xml</string>
  <key>SUEnableAutomaticChecks</key><true/>"
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Full-size icon in the current macOS format (Assets.car); a lone .icns gets drawn smaller in the Dock.
# icon/AppIcon.icon's art comes from icon/make_full_bleed.swift. actool also refreshes AppIcon.icns for older macOS.
xcrun actool "$PWD/icon/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" --app-icon AppIcon --platform macosx --target-device mac \
  --minimum-deployment-target 14.0 --output-partial-info-plist "$(mktemp -d)/icon.plist" >/dev/null
# Built-in Google sign-in: users never see Google Cloud. Set GOOGLE_CLIENT_JSON to use a different client file.
CLIENT="${GOOGLE_CLIENT_JSON:-$HOME/Library/Application Support/Email/google_client.json}"
if [[ -f "$CLIENT" ]]; then cp "$CLIENT" "$APP/Contents/Resources/google_client.json"
else echo "Note: no Google client file at $CLIENT; this build will ask users to set one up."; fi
cp .build/release/Email "$APP/Contents/MacOS/Email"
cp .build/release/KeymailMCP "$APP/Contents/MacOS/keymail-mcp"   # the MCP server AI agents launch (Settings → MCP)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Email</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>SUPublicEDKey</key><string>MY9y3p3nMe7NvNtLFW9RhPurRihWhN98WswU02c9M7k=</string>
  $FEED
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoadsInWebContent</key><true/></dict>
  <key>NSContactsUsageDescription</key><string>Keymail shows the photo on your own contact card for your iCloud account.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Keymail shows your schedule next to your inbox and turns emails into calendar events.</string>
</dict></plist>
PLIST
if [[ "$MODE" == "--release" ]]; then
  # Hardened runtime + entitlements, then Apple's notarization so it opens on any Mac without warnings.
  # Sparkle's helpers are signed inside-out first (per sparkle-project.org/documentation/sandboxing).
  SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  for item in "$SP/XPCServices/Installer.xpc" "$SP/XPCServices/Downloader.xpc" "$SP/Autoupdate" "$SP/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework"; do
    codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$RELEASE_ID" "$item"
  done
  codesign --force --options runtime --timestamp --sign "$RELEASE_ID" "$APP/Contents/MacOS/keymail-mcp"
  codesign --force --options runtime --timestamp --entitlements Email.entitlements --sign "$RELEASE_ID" "$APP"
  ZIP="$NAME-$VERSION.zip"
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
  codesign --force --deep --sign "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "No Apple Development certificate found; using ad-hoc signing (Keychain will ask after each rebuild)."
  codesign --force --deep --sign - "$APP/Contents/Frameworks/Sparkle.framework"
  codesign --force --sign - "$APP"
fi
echo "Built $(pwd)/$APP"
