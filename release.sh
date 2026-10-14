#!/bin/zsh
# Publishes an update that installed copies of Lightmail download on their own.
#   1. Bump the number in VERSION (e.g. 1.0.0 → 1.0.1) and commit.
#   2. ./release.sh
# Builds a notarized release, signs it with the Sparkle key in your Keychain (account "lightmail"),
# writes appcast.xml, and uploads both to a GitHub release. Apps check
# releases/latest/download/appcast.xml, so the newest release is what everyone gets.
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(cat VERSION)
TAG="v$VERSION"
if gh release view "$TAG" >/dev/null 2>&1; then echo "Release $TAG already exists. Bump VERSION first."; exit 1; fi
if [[ -n "$(git status --porcelain)" ]]; then echo "Commit your changes first, so the release matches the code on GitHub."; exit 1; fi
./build.sh --release
ZIP="Lightmail-$VERSION.zip"
OUT=$(mktemp -d); cp "$ZIP" "$OUT/"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast --account lightmail \
  --download-url-prefix "https://github.com/dcdunk/lightmail-app/releases/download/$TAG/" "$OUT"
git push
gh release create "$TAG" "$OUT/$ZIP" "$OUT/appcast.xml" --title "Lightmail $VERSION" --generate-notes
rm -rf "$OUT" "$ZIP"
echo "Published $TAG. Installed copies will pick it up within a day, or right away from Settings → About → Check for Updates."
