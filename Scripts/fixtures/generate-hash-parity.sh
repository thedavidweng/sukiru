#!/usr/bin/env bash
# Generate the hash-parity canary fixture (VAL-SCAN-036, feature content-hasher).
#
# The real pinned skills CLI (skills@1.5.26) computes the project-lock
# computedHash over a SOURCE skill tree whose file set is adversarial to the
# hash algorithm (research/hash-algorithm.md):
#   - ICU-collation-tricky names: SKILL.md vs scripts/ vs agents/, numeric-
#     leading 10-x.md / 2-y.md, mixed case, a leading-underscore file;
#   - metadata.json            — INCLUDED in project-scope hashing (unlike the
#                                install-time copy filter, §4.2);
#   - .git/ and node_modules/  — EXCLUDED from hashing (content planted inside
#                                must not change the digest);
#   - node_modules/.bin/pkg    — a symlink inside the skill dir. It lives in an
#     EXCLUDED directory on purpose: upstream's collectFiles excludes symlinks
#     from the hash entirely (Node Dirent.isFile() is false for links), while
#     Sukiru hashes a top-level symlink as the literal symlink:"<target>" bytes
#     (archive convention, port-reference trap #7). Those two rules can never
#     produce the same digest for a symlink the CLI can see, so a CLI-parity
#     canary cannot carry a hash-visible symlink. The symlink-convention
#     behavior is pinned by unit vectors in HashingTests instead.
#
# The fixture ships the CLI-hashed SOURCE tree byte-exactly as the placement
# (proj/.agents/skills/hashprobe). A real copy-mode install would diverge from
# the lock (copyDirectory strips metadata.json, dereferences symlinks, keeps
# node_modules — §4.2); this fixture isolates HASH ALGORITHM parity, not copy
# fidelity.
#
# Gated behind SUKIRU_E2E=1 (runs the real CLI over the network). Never
# touches the real $HOME (asserted by a real-canary check that works with
# BSD find/stat, unlike -printf).
#
# Usage:
#   Scripts/fixtures/generate-hash-parity.sh --check     # plumbing only
#   SUKIRU_E2E=1 Scripts/fixtures/generate-hash-parity.sh [TARGET_DIR]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

MODE="generate"
TARGET="$REPO_ROOT/Fixtures"
case "${1:-}" in
    --check) MODE="check" ;;
    "") : ;;
    *) TARGET="$1" ;;
esac

SKILL="hashprobe"

if [ "$MODE" = "check" ]; then
    preflight_dummy=1 # keep shellcheck quiet about unused lib functions
    [ -n "$NPX_BIN" ] || { echo "missing: npx" >&2; exit 2; }
    [ -n "$GH_BIN" ] || { echo "missing: gh" >&2; exit 2; }
    echo "check OK — npx: $NPX_BIN, pin: $SKILLS_PIN"
    exit 0
fi

require_e2e

# Resolve the REAL node + npx-cli.js, bypassing mise shims: under a sandbox
# HOME the shims bootstrap a whole Node toolchain into the sandbox (hundreds
# of MB), which must not land in the committed fixture (library/environment.md).
REAL_NODE="$(HOME="$REAL_HOME" mise which node 2>/dev/null || true)"
NPX_CLI=""
if [ -n "$REAL_NODE" ]; then
    candidate="$(cd "$(dirname "$REAL_NODE")/../lib/node_modules/npm/bin" && pwd)/npx-cli.js"
    [ -f "$candidate" ] && NPX_CLI="$candidate"
fi
if [ -z "$NPX_CLI" ]; then
    echo "FATAL: could not resolve real node/npx (mise which node failed)" >&2
    exit 2
fi

# --- real-$HOME canary (BSD find/stat — no GNU -printf on macOS) -----------
canary_fp() {
    local p
    for p in "$REAL_HOME/.agents" "$REAL_HOME/.claude" "$REAL_HOME/.codex" \
             "$REAL_HOME/.config/agents"; do
        if [ -e "$p" ]; then
            find "$p" -maxdepth 3 -exec stat -f '%N|%z|%m' {} \; 2>/dev/null
        fi
    done | LC_ALL=C sort | shasum | awk '{print $1}'
}
CANARY_BEFORE="$(canary_fp)"

# --- sandbox + adversarial source tree --------------------------------------
home="$(make_sandbox "$TARGET" "hash-parity")"
dir="$TARGET/hash-parity"
proj="$dir/proj"
src="$dir/gen-source/$SKILL"
mkdir -p "$proj" "$src/scripts" "$src/agents" "$src/.git" \
         "$src/node_modules/pkg" "$src/node_modules/.bin"

cat >"$src/SKILL.md" <<'EOF'
---
name: hashprobe
description: Hash-parity canary for the upstream computedHash algorithm.
---

body
EOF
printf 'numeric ten\n'   >"$src/10-x.md"
printf 'numeric two\n'   >"$src/2-y.md"
printf 'ccc\n'           >"$src/Zebra.md"
printf 'ddd\n'           >"$src/apple.md"
printf 'bbb\n'           >"$src/_notes.md"
printf '{"note": "included in project-scope hashing"}\n' >"$src/metadata.json"
printf 'agent instructions\n' >"$src/agents/helper.md"
printf 'aaa\n'           >"$src/scripts/run.sh"
printf 'git internals — excluded from the hash\n' >"$src/.git/cfg"
printf 'module code — excluded with node_modules\n' >"$src/node_modules/pkg/index.js"
ln -s "../pkg/index.js" "$src/node_modules/.bin/pkg"

# --- real CLI run (project scope, local source) ------------------------------
# stdout/stderr to files (npx --json truncates at 64 KiB on a pipe).
( cd "$proj" && HOME="$home" CI=1 SKILLS_TELEMETRY=0 \
  "$REAL_NODE" "$NPX_CLI" -y "$SKILLS_PIN" \
  add "../gen-source" -s "$SKILL" -a claude-code --copy -y ) \
  >"$proj/.skills.out" 2>"$proj/.skills.err" || {
    echo "skills CLI failed (see $proj/.skills.err):" >&2
    cat "$proj/.skills.err" >&2
    exit 1
}
[ -f "$proj/skills-lock.json" ] || { echo "FATAL: CLI wrote no lock" >&2; exit 1; }
LOCK_HASH="$(sed -n 's/.*"computedHash": "\([0-9a-f]*\)".*/\1/p' "$proj/skills-lock.json")"
[ -n "$LOCK_HASH" ] || { echo "FATAL: no computedHash in lock" >&2; exit 1; }

# Ship the CLI-hashed SOURCE tree byte-exactly as the placement (ditto
# preserves the node_modules symlink); drop the divergent installed copy.
rm -rf "$proj/.claude"
mkdir -p "$proj/.agents/skills"
ditto "$src" "$proj/.agents/skills/$SKILL"
rm -rf "$dir/gen-source"

# --- self-check: independent Node recompute must equal the lock value -------
RECOMPUTED="$("$REAL_NODE" - "$proj/.agents/skills/$SKILL" <<'EOF'
const { createHash } = require("crypto");
const { readdirSync, readFileSync } = require("fs");
const { join, relative } = require("path");
const files = [];
(function walk(base, current) {
    for (const entry of readdirSync(current, { withFileTypes: true })) {
        const full = join(current, entry.name);
        if (entry.isDirectory()) {
            if (entry.name === ".git" || entry.name === "node_modules") continue;
            walk(base, full);
        } else if (entry.isFile()) {
            files.push({ rel: relative(base, full).split("\\").join("/"), content: readFileSync(full) });
        }
    }
})(process.argv[2], process.argv[2]);
files.sort((a, b) => a.rel.localeCompare(b.rel));
const h = createHash("sha256");
for (const f of files) { h.update(f.rel); h.update(f.content); }
console.log(h.digest("hex"));
EOF
)"
if [ "$RECOMPUTED" != "$LOCK_HASH" ]; then
    echo "FATAL: self-check failed — recompute $RECOMPUTED != lock $LOCK_HASH" >&2
    exit 1
fi

# --- provenance + expectation note ------------------------------------------
record_pin "$dir"
# The committed fixture keeps a pristine empty home and no CLI transcripts;
# PIN.txt + EXPECTATION.md carry the provenance.
rm -rf "$home"
mkdir -p "$home"
: >"$home/.gitkeep"
rm -f "$proj/.skills.out" "$proj/.skills.err"
cat >"$dir/EXPECTATION.md" <<EOF
# hash-parity — upstream computedHash parity canary (VAL-SCAN-036)

\`proj/skills-lock.json\` was written by the REAL pinned $SKILLS_PIN CLI
(\`add ../gen-source -s $SKILL -a claude-code --copy -y\`, local source, in a
sandbox). \`proj/.agents/skills/$SKILL\` ships the CLI-hashed SOURCE tree
byte-exactly — including files a real copy-mode install would have stripped
(\`metadata.json\`) or materialized differently (hash-algorithm.md §4.2) —
because this fixture isolates HASH ALGORITHM parity, not copy fidelity.

Adversarial contents: ICU-collation-tricky names (\`SKILL.md\` vs \`scripts/\`
vs \`agents/\`, numeric \`10-x.md\`/\`2-y.md\`, mixed case, \`_notes.md\`),
\`metadata.json\` (included), \`.git/\` + \`node_modules/\` (excluded), and a
symlink at \`node_modules/.bin/pkg\` — inside an excluded directory, because
upstream EXCLUDES symlinks from the hash while Sukiru hashes a visible one as
\`symlink:"<target>"\`; the two rules only agree when no hash-visible symlink
exists (see HashingTests for the symlink-convention vectors).

Scan with SUKIRU_HOME=<hash-parity>/.home, SUKIRU_ROOTS=<hash-parity>/proj.
Expect: recomputed computedHash for the \`$SKILL\` placement byte-equals the
lock's \`$LOCK_HASH\`; ZERO vercel-lock-drift findings (and no other findings).

Regenerate: SUKIRU_E2E=1 Scripts/fixtures/generate-hash-parity.sh
Note: git never tracks the fixture's inner \`.git/\` directory, so a fresh
regeneration contains \`.git/cfg\` while the committed tree does not — the
digest is identical either way (that exclusion is the point).
EOF

CANARY_AFTER="$(canary_fp)"
if [ "$CANARY_AFTER" != "$CANARY_BEFORE" ]; then
    echo "FATAL: canary tripped — real \$HOME changed during generation." >&2
    exit 3
fi
echo "hash-parity generated: $dir (lock computedHash $LOCK_HASH)"
