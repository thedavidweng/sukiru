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
    # BSD find has no -printf; stat -f is the macOS spelling (same approach as
    # generate-hash-parity.sh's canary_fp). Tolerate perms errors quietly.
    local p
    for p in "$REAL_HOME/.agents" "$REAL_HOME/.claude" "$REAL_HOME/.codex" \
             "$REAL_HOME/.config/agents"; do
        if [ -e "$p" ]; then
            find "$p" -maxdepth 3 -exec stat -f '%N|%z|%m' {} \; 2>/dev/null
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

# force_rm_rf PATH — rm -rf that tolerates transient "Directory not empty"
# failures: freshly-exited CLI processes (npx/npm cache writers) can still be
# recreating sandbox files while the removal walks the tree. Retries a few
# times with a short backoff, then lets the final rm's exit status speak.
force_rm_rf() {
    local path="$1" attempt
    for attempt in 1 2 3 4 5; do
        if rm -rf "$path" 2>/dev/null && [ ! -e "$path" ]; then
            return 0
        fi
        sleep 1
    done
    rm -rf "$path"
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

# Real node + npx-cli.js, resolved lazily (same trick as
# generate-hash-parity.sh): under a sandbox HOME the mise shims would
# bootstrap a whole Node toolchain into the sandbox (hundreds of MB), so
# run_skills bypasses the shim and invokes npx-cli.js with the real node.
REAL_NODE=""
NPX_CLI=""
resolve_real_node() {
    [ -n "$NPX_CLI" ] && return 0
    REAL_NODE="$(HOME="$REAL_HOME" mise which node 2>/dev/null || true)"
    if [ -n "$REAL_NODE" ]; then
        local candidate
        candidate="$(cd "$(dirname "$REAL_NODE")/../lib/node_modules/npm/bin" 2>/dev/null && pwd)/npx-cli.js"
        [ -f "$candidate" ] && NPX_CLI="$candidate"
    fi
}

# run_skills SANDBOX_HOME PROJECT_CWD ARGS... -> pinned skills CLI in a sandbox.
# stdout/stderr go to files (npx --json truncates at 64 KiB on a pipe).
run_skills() {
    local home="$1" cwd="$2"; shift 2
    resolve_real_node
    local -a cmd
    if [ -n "$NPX_CLI" ]; then
        cmd=("$REAL_NODE" "$NPX_CLI" -y "$SKILLS_PIN")
    else
        # Fall back to the PATH npx when no mise-managed node exists.
        cmd=("$NPX_BIN" -y "$SKILLS_PIN")
    fi
    ( cd "$cwd" && \
      HOME="$home" CI=1 SKILLS_TELEMETRY=0 \
      "${cmd[@]}" "$@" ) \
      >"$cwd/.skills.out" 2>"$cwd/.skills.err" || {
        echo "skills CLI failed (see $cwd/.skills.err):" >&2
        cat "$cwd/.skills.err" >&2
        return 1
    }
}

# run_gh SANDBOX_HOME PROJECT_CWD ARGS... -> gh in a sandbox with GH_TOKEN.
# gh's config/state (incl. the async-written device-id and update-notifier
# state) is redirected to a per-invocation throwaway dir so it never lands in
# the committed fixture's sandbox home; GH_NO_UPDATE_NOTIFIER mutes the
# background update check that otherwise recreates state AFTER gh exits.
run_gh() {
    local home="$1" cwd="$2"; shift 2
    if [ -z "${GH_TOKEN:-}" ]; then
        echo "FATAL: GH_TOKEN not set (needed for gh network install)." >&2
        exit 2
    fi
    local gh_state rc=0
    gh_state="$(mktemp -d /tmp/sukiru-gh-state.XXXXXX)"
    ( cd "$cwd" && \
      HOME="$home" GH_TOKEN="$GH_TOKEN" CI=1 GH_NO_UPDATE_NOTIFIER=1 \
      GH_CONFIG_DIR="$gh_state/config" XDG_STATE_HOME="$gh_state/state" \
      "$GH_BIN" "$@" ) \
      >"$cwd/.gh.out" 2>"$cwd/.gh.err" || rc=$?
    force_rm_rf "$gh_state"
    if [ "$rc" -ne 0 ]; then
        echo "gh failed (see $cwd/.gh.err):" >&2
        cat "$cwd/.gh.err" >&2
        return 1
    fi
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
