#!/usr/bin/env bash
# Build a Release Sukiru.app once, thin it into one build per architecture
# and package each into dist/: Sukiru-<arch>.dmg, Sukiru-<arch>.zip and that
# architecture's Sparkle feed, plus checksums.txt. Homebrew installs the
# build for the Mac's architecture, and each build's feed offers only its
# own architecture.
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
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  build

application="$DERIVED_DATA/Build/Products/Release/Sukiru.app"
if [ ! -d "$application" ]; then
  echo "error: build reported success but $application is missing" >&2
  exit 1
fi
architectures=(arm64 x86_64)
echo "==> Building size-optimized release CLI..."
cli_build=(swift build -c release --product sukiru --arch arm64 --arch x86_64)
"${cli_build[@]}" -Xswiftc -Osize
cli_bin_dir="$("${cli_build[@]}" --show-bin-path)"
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
# Sparkle's XPC services exist for sandboxed apps only (ADR 0015).
sparkle="$application/Contents/Frameworks/Sparkle.framework"
rm -rf "$sparkle/XPCServices" "$sparkle/Versions/B/XPCServices"

escaped_version="${MARKETING_VERSION//./\\.}"
release_notes="$(awk "/^## \\[${escaped_version}\\]/{found=1; next} /^## \\[/{if(found) exit} found{print}" CHANGELOG.md)"
if ! grep -q '[^[:space:]]' <<< "$release_notes"; then
  echo "error: CHANGELOG.md has no section for $MARKETING_VERSION" >&2
  exit 1
fi

dist_dir="$REPO_ROOT/dist"
rm -rf "$dist_dir"
mkdir -p "$dist_dir"
signing=(--force --timestamp --options runtime --sign "$APPLE_SIGNING_IDENTITY"
  --keychain "$APPLE_SIGNING_KEYCHAIN")

for arch in "${architectures[@]}"; do
  echo "==> Packaging the $arch build..."
  staging="$REPO_ROOT/.build/release-$arch"
  thin="$staging/Sukiru.app"
  rm -rf "$staging"
  mkdir -p "$staging"
  ditto "$application" "$thin"
  # Keep only this architecture's slice in every Mach-O file (ditto --arch
  # leaves them universal).
  while IFS= read -r -d '' file; do
    if lipo -archs "$file" >/dev/null 2>&1 && [ "$(lipo -archs "$file")" != "$arch" ]; then
      lipo "$file" -thin "$arch" -output "$file"
    fi
  done < <(find "$thin" -type f -perm +111 -print0)
  # arm64 keeps the original feed name that 1.10.0 reads; generate_appcast
  # marks that feed arm64-only, so an Intel 1.10.0 never installs it.
  feed="appcast.xml"
  if [ "$arch" != arm64 ]; then feed="appcast-$arch.xml"; fi
  /usr/libexec/PlistBuddy -c \
    "Set :SUFeedURL https://github.com/thedavidweng/sukiru/releases/latest/download/$feed" \
    "$thin/Contents/Info.plist"
  # Thinning invalidates every signature: Sparkle innermost first, then the
  # helper, then the app (Scripts/sign-and-notarize.sh).
  thin_sparkle="$thin/Contents/Frameworks/Sparkle.framework"
  for component in "$thin_sparkle/Versions/B/Autoupdate" "$thin_sparkle/Versions/B/Updater.app" \
    "$thin_sparkle" "$thin/Contents/Helpers/sukiru"; do
    codesign "${signing[@]}" "$component"
  done
  if [ "$arch" = "$(uname -m)" ]; then
    shipped_cli_version="$("$thin/Contents/Helpers/sukiru" --version)"
    if [ "$shipped_cli_version" != "$MARKETING_VERSION" ]; then
      echo "error: app and CLI versions differ ($MARKETING_VERSION / $shipped_cli_version)" >&2
      exit 1
    fi
  fi
  xattr -cr "$thin"
  "$REPO_ROOT/Scripts/sign-and-notarize.sh" "$thin"

  ditto -c -k --keepParent "$thin" "$dist_dir/Sukiru-$arch.zip"

  dmg_staging="$staging/dmg"
  mkdir -p "$dmg_staging"
  cp -R "$thin" "$dmg_staging/"
  ln -s /Applications "$dmg_staging/Applications"
  hdiutil create \
    -volname "Sukiru" \
    -srcfolder "$dmg_staging" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$dist_dir/Sukiru-$arch.dmg"
  "$REPO_ROOT/Scripts/sign-and-notarize.sh" "$dist_dir/Sukiru-$arch.dmg"

  # generate_appcast reads every archive in its directory, so it sees only
  # this zip, with the release's CHANGELOG section beside it as notes.
  feed_dir="$staging/appcast"
  mkdir -p "$feed_dir"
  cp "$dist_dir/Sukiru-$arch.zip" "$feed_dir/"
  printf '%s\n' "$release_notes" > "$feed_dir/Sukiru-$arch.md"
  printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SPARKLE_BIN/generate_appcast" --ed-key-file - \
    --download-url-prefix "https://github.com/thedavidweng/sukiru/releases/download/v$MARKETING_VERSION/" \
    --embed-release-notes --link "https://thedavidweng.github.io/sukiru/" \
    -o "$dist_dir/$feed" "$feed_dir"
  rm -rf "$staging"
done

echo "==> Generating SHA-256 checksums..."
cd "$dist_dir"
shasum -a 256 Sukiru-*.dmg Sukiru-*.zip > checksums.txt

echo "==> Packaging complete! Artifacts in $dist_dir:"
ls -lh "$dist_dir"
cat "$dist_dir/checksums.txt"
