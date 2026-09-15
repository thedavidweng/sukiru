#!/usr/bin/env bash
# Apply runtime-only fixture states that git cannot store (chmod-000 dirs).
#
# Run this after checkout / build-handbuilt.sh when a validator needs to
# exercise the unreadable-directory code path. It is idempotent and safe to run
# repeatedly. The offline smoke test does NOT require it.
#
# Usage: Scripts/fixtures/prepare-runtime.sh [FIXTURES_DIR]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIX="${1:-$REPO_ROOT/Fixtures}"

locked="$FIX/FIX-GARBAGE/.agents/skills/locked-dir"
if [ -d "$locked" ]; then
    chmod 000 "$locked"
    echo "chmod 000 $locked"
fi

echo "Runtime states prepared under: $FIX"
echo "To restore readability: chmod -R u+rwX \"$FIX/FIX-GARBAGE\""
