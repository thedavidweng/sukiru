#!/usr/bin/env bash
# Best-effort release packaging. No Node.js is used or bundled.
#
# macOS without an Apple Developer account:
#   - builds Gino.app
#   - ad-hoc codesign (identity "-") so Gatekeeper at least sees a signature
#   - cannot notarize or staple (needs a paid Developer ID)
#   - other Macs may still need right-click → Open the first time
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
version="$(sed -n 's/^version = "\([^"]*\)"/\1/p' Cargo.toml | head -n1)"
dist="$root/dist"
rm -rf "$dist"
mkdir -p "$dist"

echo "Building Gino ${version} (release, no Node.js)..."
cargo build --release

if [[ "$(uname -s)" == "Darwin" ]]; then
  app="$dist/Gino.app"
  macos="$app/Contents/MacOS"
  resources="$app/Contents/Resources"
  mkdir -p "$macos" "$resources"
  cp target/release/gino "$macos/gino"
  chmod +x "$macos/gino"
  # Keep CFBundleShortVersionString in sync with Cargo.toml.
  sed "s/<string>1.0.0<\\/string>/<string>${version}<\\/string>/g" \
    packaging/macos/Info.plist > "$app/Contents/Info.plist"
  printf 'APPL????' > "$app/Contents/PkgInfo"

  echo "Ad-hoc codesign (no Developer ID on this machine)..."
  if codesign --force --deep --sign - "$app"; then
    codesign --verify --verbose=2 "$app" || true
    echo "Signed ad-hoc. Notarization skipped: no Apple Developer identity."
  else
    echo "codesign failed; the .app is still usable on this Mac." >&2
  fi

  (
    cd "$dist"
    ditto -c -k --keepParent Gino.app "Gino-${version}-macos-adhoc.zip"
  )
  echo "Wrote $app"
  echo "Wrote $dist/Gino-${version}-macos-adhoc.zip"
elif [[ "$(uname -s)" == "Linux" ]]; then
  mkdir -p "$dist/linux"
  cp target/release/gino "$dist/linux/gino"
  cp packaging/linux/gino.desktop "$dist/linux/gino.desktop"
  cp LICENSE "$dist/linux/LICENSE"
  echo "Wrote $dist/linux/gino (unsigned; install the .desktop next to it)"
else
  cp target/release/gino.exe "$dist/gino.exe" 2>/dev/null || cp target/release/gino "$dist/gino"
  echo "Wrote Windows/other binary to $dist (Authenticode not available here)"
fi

cp LICENSE "$dist/LICENSE"
cat > "$dist/README.txt" <<EOF
Gino ${version}

What you get
------------
On this Mac: Gino.app plus a zip. It is ad-hoc signed, not notarized.

Why Gatekeeper may warn
-----------------------
Apple notarization requires a paid Apple Developer account and a Developer ID
certificate. This machine has none, so we cannot upload to Apple's notary
service. First launch on another Mac: right-click the app → Open → Open.

Windows / Linux
---------------
This script only builds a real installer/bundle on the OS you run it on.
Windows Authenticode and Linux distro packages need those machines (or CI).

No Node.js is required. There is no in-app self-update.
Releases: https://github.com/thedavidweng/gino/releases
EOF

echo "Done."
