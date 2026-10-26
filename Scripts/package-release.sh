#!/usr/bin/env bash
# Build a Release Sukiru.app and package the distributable artifacts
# (Sukiru.dmg, Sukiru.zip, appcast.xml, checksums.txt) into dist/.
#
# The marketing version is injected at build time (MARKETING_VERSION) so the
# release workflow can derive it from the git tag without touching
# project.yml. Debug builds keep project.yml's MARKETING_VERSION.
set -euo pipefail

: "${APPLE_SIGNING_IDENTITY:?release signing identity required}"
: "${APPLE_SIGNING_KEYCHAIN:?}" "${APPLE_TEAM_ID:?}"
: "${APPLE_API_KEY_PATH:?}" "${APPLE_API_KEY_ID:?}" "${APPLE_API_ISSUER:?}"
: "${SPARKLE_BIN:?Sparkle tools directory required}" "${SPARKLE_PRIVATE_KEY:?}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

: "${MARKETING_VERSION:?set MARKETING_VERSION (e.g. 1.0.0)}"
# Sparkle orders releases by CFBundleVersion, so it follows the release.
BUILD_NUMBER="${CURRENT_PROJECT_VERSION:-$MARKETING_VERSION}"

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
echo "==> Building size-optimized release CLI..."
swift build -c release --product sukiru -Xswiftc -Osize
cli_bin_dir="$(swift build -c release --show-bin-path)"
# Contents/MacOS would collide with the app executable "Sukiru" on a
# case-insensitive volume, so the CLI ships as a helper tool.
mkdir -p "$application/Contents/Helpers"
cp "$cli_bin_dir/sukiru" "$application/Contents/Helpers/sukiru"
# Remove development signatures before changing executable bytes. Keep the
# generated dSYMs beside the build products for crash symbolication; only
# local/debug symbols are removed, before any final Developer ID signing.
codesign --remove-signature "$application/Contents/Helpers/sukiru"
codesign --remove-signature "$application/Contents/MacOS/Sukiru"
xcrun strip -S -x "$application/Contents/Helpers/sukiru"
xcrun strip -S -x "$application/Contents/MacOS/Sukiru"
# Sparkle's XPC services exist for sandboxed apps only (ADR 0015). Its
# remaining executables are re-signed, innermost first, with the release
# identity under the hardened runtime.
sparkle="$application/Contents/Frameworks/Sparkle.framework"
rm -rf "$sparkle/XPCServices" "$sparkle/Versions/B/XPCServices"
for component in "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle"; do
  codesign --force --timestamp --options runtime --sign "$APPLE_SIGNING_IDENTITY" \
    --keychain "$APPLE_SIGNING_KEYCHAIN" "$component"
done
# Embedding a second executable changes the app signature.
codesign --force --timestamp --options runtime --sign "$APPLE_SIGNING_IDENTITY" \
  --keychain "$APPLE_SIGNING_KEYCHAIN" "$application/Contents/Helpers/sukiru"
shipped_cli_version="$("$application/Contents/Helpers/sukiru" --version)"
if [ "$shipped_cli_version" != "$MARKETING_VERSION" ]; then
  echo "error: app and CLI versions differ ($MARKETING_VERSION / $shipped_cli_version)" >&2
  exit 1
fi
xattr -cr "$application"
"$REPO_ROOT/Scripts/sign-and-notarize.sh" "$application"

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

"$REPO_ROOT/Scripts/sign-and-notarize.sh" "$dist_dir/Sukiru.dmg"

echo "==> Generating appcast.xml..."
# generate_appcast reads every archive in its directory, so it sees only the
# zip, with the release's CHANGELOG section beside it as release notes.
appcast_dir="$REPO_ROOT/.build/appcast"
rm -rf "$appcast_dir"
mkdir -p "$appcast_dir"
cp "$dist_dir/Sukiru.zip" "$appcast_dir/"
escaped_version="${MARKETING_VERSION//./\\.}"
awk "/^## \\[${escaped_version}\\]/{found=1; next} /^## \\[/{if(found) exit} found{print}" \
  CHANGELOG.md > "$appcast_dir/Sukiru.md"
if ! grep -q '[^[:space:]]' "$appcast_dir/Sukiru.md"; then
  echo "error: CHANGELOG.md has no section for $MARKETING_VERSION" >&2
  exit 1
fi
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SPARKLE_BIN/generate_appcast" --ed-key-file - \
  --download-url-prefix "https://github.com/thedavidweng/sukiru/releases/download/v$MARKETING_VERSION/" \
  --embed-release-notes --link "https://thedavidweng.github.io/sukiru/" \
  -o "$dist_dir/appcast.xml" "$appcast_dir"
rm -rf "$appcast_dir"

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
