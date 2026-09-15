#!/usr/bin/env bash
# Generate the Xcode project from project.yml and build a Debug Sukiru.app.
# Prints the path to the built .app on the last line (APP_PATH=<path>).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# .build is gitignored, so the generated project and DerivedData never pollute
# the working tree. run-app.sh reads the same DERIVED_DATA location.
DERIVED_DATA="${DERIVED_DATA:-$REPO_ROOT/.build/xcode}"

xcodegen generate

xcodebuild \
  -scheme Sukiru \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  build

APP_PATH="$DERIVED_DATA/Build/Products/Debug/Sukiru.app"
if [ ! -d "$APP_PATH" ]; then
  echo "error: build reported success but $APP_PATH is missing" >&2
  exit 1
fi

echo "APP_PATH=$APP_PATH"
