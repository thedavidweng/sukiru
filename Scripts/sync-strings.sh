#!/usr/bin/env bash
# Sync the app's String Catalogs with the strings the compiler extracted in
# the last Scripts/build-app.sh run, then fail if any string is stale or
# lacks a translation. This is what Xcode does on build, made reproducible
# for the xcodegen + xcodebuild workflow.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DERIVED_DATA="${DERIVED_DATA:-$REPO_ROOT/.build/xcode}"
OBJECTS="$DERIVED_DATA/Build/Intermediates.noindex/Sukiru.build/Debug/Sukiru.build/Objects-normal"

if [ ! -d "$OBJECTS" ]; then
  echo "error: $OBJECTS not found — run Scripts/build-app.sh first" >&2
  exit 1
fi

stringsdata=()
while IFS= read -r file; do
  stringsdata+=(--stringsdata "$file")
done < <(find "$OBJECTS" -name '*.stringsdata')

xcrun xcstringstool sync App/Resources/Localizable.xcstrings "${stringsdata[@]}"
xcrun swift Scripts/check-strings.swift App/Resources/*.xcstrings
