#!/usr/bin/env bash
# Shared helpers for the CLI-driven fixture generators.
#
# Sourced by generate.sh. Provides the sandbox recipe, the real-$HOME canary,
# the pinned-CLI wrappers, and the SUKIRU_E2E gate. Never persists GH_TOKEN.

# The pinned skills CLI version for the whole corpus (architecture D17).
SKILLS_PIN="skills@1.5.26"

# The canary must be captured BEFORE any HOME override. Records the real home
# and a fingerprint of its skill-bearing top-level entries so we can prove the
# generation never mutated it.
REAL_HOME="$HOME"
_CANARY_BEFORE=""

canary_capture() {
    # Fingerprint = names + sizes + mtimes of the real home's ledger/skill dirs.
    _CANARY_BEFORE="$(_canary_fingerprint)"
}

_canary_fingerprint() {
    # Only the paths a mutating skills/gh run could plausibly touch.
    local p
    for p in "$REAL_HOME/.agents" "$REAL_HOME/.claude" "$REAL_HOME/.codex" \
             "$REAL_HOME/.config/agents"; do
        if [ -e "$p" ]; then
            # -print with %m mtime; tolerate perms errors quietly.
            find "$p" -maxdepth 3 -printf '%p|%s|%T@\n' 2>/dev/null
        fi
    done | LC_ALL=C sort | shasum | awk '{print $1}'
}

canary_assert_unchanged() {
    local after; after="$(_canary_fingerprint)"
    if [ "$after" != "$_CANARY_BEFORE" ]; then
        echo "FATAL: canary tripped — the real \$HOME ($REAL_HOME) changed during generation." >&2
        echo "  before=$_CANARY_BEFORE after=$after" >&2
        exit 3
    fi
}

# make_sandbox TARGET_DIR NAME -> creates an isolated HOME under TARGET_DIR/NAME,
# echoes its absolute path. Asserts it is NOT the real home.
make_sandbox() {
    local target="$1" name="$2"
    local sb="$target/$name/.home"
    rm -rf "$target/$name"
    mkdir -p "$sb"
    sb="$(cd "$sb" && pwd)"
    if [ "$sb" = "$REAL_HOME" ] || [ -z "$sb" ]; then
        echo "FATAL: refusing to use the real \$HOME as a sandbox ($sb)." >&2
        exit 3
    fi
    case "$sb" in
        "$REAL_HOME"|"$REAL_HOME"/)
            echo "FATAL: sandbox resolves to the real \$HOME ($sb)." >&2
            exit 3
            ;;
    esac
    printf '%s' "$sb"
}

# require_e2e — the network gate. Generation that shells real CLIs only runs
# under SUKIRU_E2E=1 (architecture §9, testing strategy).
require_e2e() {
    if [ "${SUKIRU_E2E:-0}" != "1" ]; then
        cat >&2 <<'EOF'
CM-* generation runs the REAL skills/gh CLIs over the network and is gated.
Re-run with:  SUKIRU_E2E=1 GH_TOKEN="$(gh auth token)" Scripts/fixtures/generate.sh [TARGET_DIR]
EOF
        exit 2
    fi
}

# Resolve a real node/npx even under a sandbox HOME (mise shims read the real
# passwd home and print trust warnings; we prefer the real binaries directly).
NPX_BIN="$(command -v npx || true)"
GH_BIN="$(command -v gh || true)"

# run_skills SANDBOX_HOME PROJECT_CWD ARGS... -> pinned skills CLI in a sandbox.
# stdout/stderr go to files (npx --json truncates at 64 KiB on a pipe).
run_skills() {
    local home="$1" cwd="$2"; shift 2
    ( cd "$cwd" && \
      HOME="$home" CI=1 SKILLS_TELEMETRY=0 \
      "$NPX_BIN" -y "$SKILLS_PIN" "$@" ) \
      >"$cwd/.skills.out" 2>"$cwd/.skills.err" || {
        echo "skills CLI failed (see $cwd/.skills.err):" >&2
        cat "$cwd/.skills.err" >&2
        return 1
    }
}

# run_gh SANDBOX_HOME PROJECT_CWD ARGS... -> gh in a sandbox with GH_TOKEN.
run_gh() {
    local home="$1" cwd="$2"; shift 2
    if [ -z "${GH_TOKEN:-}" ]; then
        echo "FATAL: GH_TOKEN not set (needed for gh network install)." >&2
        exit 2
    fi
    ( cd "$cwd" && \
      HOME="$home" GH_TOKEN="$GH_TOKEN" CI=1 \
      "$GH_BIN" "$@" ) \
      >"$cwd/.gh.out" 2>"$cwd/.gh.err" || {
        echo "gh failed (see $cwd/.gh.err):" >&2
        cat "$cwd/.gh.err" >&2
        return 1
    }
}

# record_pin DIR -> writes the CLI pin used to generate the fixture.
record_pin() {
    local dir="$1"
    {
        echo "skills-cli: $SKILLS_PIN"
        echo "gh: $("$GH_BIN" --version 2>/dev/null | head -1 || echo 'n/a')"
        echo "node: $(HOME="$REAL_HOME" node --version 2>/dev/null || echo 'n/a')"
        echo "generated-at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >"$dir/PIN.txt"
}
