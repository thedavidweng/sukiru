#!/usr/bin/env bash
# Launch the built Sukiru.app by executing its binary directly.
#
# NEVER use `open -F` here: launching through LaunchServices suppresses the
# window for a freshly built, ad-hoc-signed debug app and breaks computer-use
# window inspection. Executing the Mach-O binary keeps env overrides
# (SUKIRU_HOME, SUKIRU_ROOTS, …) and shows a normal focusable window.
#
# Env passthrough works because the caller's environment is inherited by exec.
# Any extra arguments are forwarded to the binary.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${DERIVED_DATA:-$REPO_ROOT/.build/xcode}"
BIN="$DERIVED_DATA/Build/Products/Debug/Sukiru.app/Contents/MacOS/Sukiru"

if [ ! -x "$BIN" ]; then
  echo "error: $BIN not found — run Scripts/build-app.sh first" >&2
  exit 1
fi

exec "$BIN" "$@"
