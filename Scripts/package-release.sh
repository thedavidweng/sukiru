#!/usr/bin/env bash
# Build a Release Sukiru.app and package the distributable artifacts
# (Sukiru.dmg, Sukiru.zip, checksums.txt) into dist/.
#
# The marketing version is injected at build time (MARKETING_VERSION) so the
# release workflow can derive it from the git tag without touching
# project.yml. Debug builds keep project.yml's MARKETING_VERSION.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

: "${MARKETING_VERSION:?set MARKETING_VERSION (e.g. 1.0.0)}"
BUILD_NUMBER="${CURRENT_PROJECT_VERSION:-1}"

echo "==> Generating Xcode project..."
xcodegen generate

# Separate derived data from the Debug tree (Scripts/build-app.sh) so a
# release package never reuses debug intermediates.
DERIVED_DATA="${DERIVED_DATA:-$REPO_ROOT/.build/xcode-release}"

echo "==> Building Release Sukiru.app (v${MARKETING_VERSION})..."
xcodebuild \
  -scheme Sukiru \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  build

application="$DERIVED_DATA/Build/Products/Release/Sukiru.app"
if [ ! -d "$application" ]; then
  echo "error: build reported success but $application is missing" >&2
  exit 1
fi
xattr -cr "$application"

dist_dir="$REPO_ROOT/dist"
rm -rf "$dist_dir"
mkdir -p "$dist_dir"

echo "==> Packaging Sukiru.zip..."
ditto -c -k --keepParent "$application" "$dist_dir/Sukiru.zip"

echo "==> Packaging Sukiru.dmg..."
dmg_staging="$REPO_ROOT/.build/dmg_staging"
rm -rf "$dmg_staging"
mkdir -p "$dmg_staging"
cp -R "$application" "$dmg_staging/"
ln -s /Applications "$dmg_staging/Applications"

hdiutil create \
  -volname "Sukiru" \
  -srcfolder "$dmg_staging" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$dist_dir/Sukiru.dmg"
rm -rf "$dmg_staging"

echo "==> Generating SHA-256 checksums..."
cd "$dist_dir"
if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 Sukiru.dmg Sukiru.zip > checksums.txt
elif command -v sha256sum >/dev/null 2>&1; then
  sha256sum Sukiru.dmg Sukiru.zip > checksums.txt
fi

echo "==> Packaging complete! Artifacts in $dist_dir:"
ls -lh "$dist_dir"
cat "$dist_dir/checksums.txt"
