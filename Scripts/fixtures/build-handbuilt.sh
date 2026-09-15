#!/usr/bin/env bash
# Rebuild every hand-built fixture tree under Fixtures/ deterministically.
#
# These trees are checked in, but this generator is the source of truth for how
# they are constructed: it is idempotent (each target is wiped and rebuilt) and
# creates the parts git cannot faithfully represent on its own (symlinks,
# broken symlinks). Runtime-only states that git cannot store (chmod-000
# unreadable dirs) are applied separately by prepare-runtime.sh.
#
# Usage: Scripts/fixtures/build-handbuilt.sh [FIXTURES_DIR]
#   FIXTURES_DIR defaults to <repo>/Fixtures.
#
# No network, no CLIs, never touches $HOME. Pure filesystem construction.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIX="${1:-$REPO_ROOT/Fixtures}"

mkdir -p "$FIX"

# --- helpers ---------------------------------------------------------------

# reset_fixture NAME -> wipes and recreates Fixtures/NAME, echoes its path.
reset_fixture() {
    local name="$1"
    local dir="$FIX/$name"
    rm -rf "$dir"
    mkdir -p "$dir"
    printf '%s' "$dir"
}

# skill DIR NAME DESCRIPTION -> a minimal valid SKILL.md skill directory.
skill() {
    local dir="$1" name="$2" desc="$3"
    mkdir -p "$dir"
    cat >"$dir/SKILL.md" <<EOF
---
name: $name
description: $desc
---

# $name

$desc
EOF
}

# gh_skill DIR NAME DESC REPO GHPATH REF TREESHA [PINNED]
# A skill whose frontmatter carries GitHub provenance (gh-owned).
gh_skill() {
    local dir="$1" name="$2" desc="$3" repo="$4" ghpath="$5" ref="$6" sha="$7" pinned="${8:-}"
    mkdir -p "$dir"
    {
        echo "---"
        echo "name: $name"
        echo "description: $desc"
        echo "metadata:"
        echo "  github-repo: $repo"
        echo "  github-path: $ghpath"
        echo "  github-ref: $ref"
        echo "  github-tree-sha: $sha"
        if [ -n "$pinned" ]; then
            echo "  github-pinned: true"
        fi
        echo "---"
        echo ""
        echo "# $name"
        echo ""
        echo "$desc"
    } >"$dir/SKILL.md"
}

note() {
    # note FIXTURE_DIR  (reads heredoc from stdin into EXPECTATION.md)
    cat >"$1/EXPECTATION.md"
}

# =====================================================================
# FIX-EMPTY — nothing at all.
# =====================================================================
d="$(reset_fixture FIX-EMPTY)"
note "$d" <<'EOF'
# FIX-EMPTY — expectation

Contents: an otherwise-empty fake HOME (only this note). No skill directories,
no host config dirs, no lock files anywhere.

A correct scan (SUKIRU_HOME=<this dir>, default scope) MUST:
- exit 0 with valid JSON;
- report zero workspaces that contain content, zero placements (skills == []);
- report zero findings and zero issues.
EOF

# =====================================================================
# FIX-CLEAN — one minimal vercel-owned skill, single placement, zero findings.
# The lock is the GLOBAL v3 lock (skillFolderHash = git tree SHA) so no
# project-scope computedHash drift check applies (drift is project-only,
# by design), keeping this the true zero-findings baseline (VAL-SCAN-041b, D3).
# =====================================================================
d="$(reset_fixture FIX-CLEAN)"
skill "$d/.agents/skills/greet" "greet" "Greet the user politely."
cat >"$d/.agents/.skill-lock.json" <<'EOF'
{
  "version": 3,
  "skills": {
    "greet": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "skillPath": ".agents/skills/greet/SKILL.md",
      "skillFolderHash": "3066c474cfe70dc936b3c8c86664f0913e1b228b",
      "installedAt": "2026-06-15T23:27:24.742Z",
      "updatedAt": "2026-06-15T23:27:24.742Z"
    }
  },
  "dismissed": {}
}
EOF
note "$d" <<'EOF'
# FIX-CLEAN — expectation

Contents: canonical user store `.agents/skills/greet` (one physical placement)
plus the global v3 lock `.agents/.skill-lock.json` claiming `greet`.

A correct scan MUST:
- exit 0, valid JSON;
- list exactly one skill `greet`, scope=user, ownership=vercel, ambiguous=false,
  with a single placement of kind=directory;
- surface the vercel provenance (source/sourceType/sourceUrl/skillPath and the
  GLOBAL-scope `skillFolderHash`; NO `computedHash` for a global entry);
- report ZERO findings (global scope has no drift check; single placement means
  no duplicates; a lock entry means no files-without-lock).

Note (cross-milestone): the M3 health contract describes a richer FIX-CLEAN
spanning all four ownership classes. Because github/ownerless skills always
raise a `dangerous-removal-surface` advisory (VAL-SCAN-030), a genuinely
zero-findings tree can contain vercel-owned skills only; this fixture honors
the core-read VAL-SCAN-041b zero-findings requirement.
EOF

# =====================================================================
# FIX-INTERNAL — a metadata.internal:true skill plus a normal control.
# Both are vercel-owned (global lock) so the ONLY signal under test is the
# internal flag.
# =====================================================================
d="$(reset_fixture FIX-INTERNAL)"
skill "$d/.agents/skills/normal" "normal" "A normal, host-visible skill."
mkdir -p "$d/.agents/skills/hidden-helper"
cat >"$d/.agents/skills/hidden-helper/SKILL.md" <<'EOF'
---
name: hidden-helper
description: An internal helper hidden from host-facing listings.
metadata:
  internal: true
---

# hidden-helper

Internal-only skill; inventoried but flagged, never shown as host-visible.
EOF
cat >"$d/.agents/.skill-lock.json" <<'EOF'
{
  "version": 3,
  "skills": {
    "normal": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "skillPath": ".agents/skills/normal/SKILL.md",
      "skillFolderHash": "1111111111111111111111111111111111111111",
      "installedAt": "2026-06-15T23:27:24.742Z",
      "updatedAt": "2026-06-15T23:27:24.742Z"
    },
    "hidden-helper": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "skillPath": ".agents/skills/hidden-helper/SKILL.md",
      "skillFolderHash": "2222222222222222222222222222222222222222",
      "installedAt": "2026-06-15T23:27:24.742Z",
      "updatedAt": "2026-06-15T23:27:24.742Z"
    }
  },
  "dismissed": {}
}
EOF
note "$d" <<'EOF'
# FIX-INTERNAL — expectation

Contents: two vercel-owned user-scope skills. `hidden-helper` carries
`metadata.internal: true`; `normal` does not.

A correct scan MUST:
- exit 0;
- inventory BOTH placements (internal skills are inventoried, never dropped);
- flag the `hidden-helper` placement `internal: true` and `normal` `internal: false`.

The M3 UI additionally hides internal skills from host-facing listings while
still surfacing the internal marker (VAL-HEALTH-010); at seam A the requirement
is only that both placements appear with correct internal flags.
EOF

# =====================================================================
# FIX-MALFORMED — SKILL.md missing `name` + a lock whose version is NEWER
# than supported (global v3 -> version 4). Plus a healthy sibling.
# =====================================================================
d="$(reset_fixture FIX-MALFORMED)"
skill "$d/.agents/skills/healthy" "healthy" "A healthy control skill."
mkdir -p "$d/.agents/skills/nameless"
cat >"$d/.agents/skills/nameless/SKILL.md" <<'EOF'
---
description: This frontmatter is missing the required name field.
---

# nameless

Should produce a skill-md-invalid issue, not a placement.
EOF
cat >"$d/.agents/.skill-lock.json" <<'EOF'
{
  "version": 4,
  "skills": {
    "healthy": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "skillPath": ".agents/skills/healthy/SKILL.md",
      "skillFolderHash": "3333333333333333333333333333333333333333",
      "channel": "beta",
      "installedAt": "2026-06-15T23:27:24.742Z",
      "updatedAt": "2026-06-15T23:27:24.742Z"
    }
  },
  "dismissed": {},
  "futureTopLevelKey": "preserved"
}
EOF
note "$d" <<'EOF'
# FIX-MALFORMED — expectation

Contents: a healthy skill `healthy`, a malformed skill `nameless` (frontmatter
missing the required `name`), and a global lock whose `version` (4) is NEWER
than the supported v3. The lock also carries an unknown entry key (`channel`)
and an unknown top-level key (`futureTopLevelKey`).

A correct scan MUST:
- exit 0;
- emit a `skill-md-invalid` issue naming `.agents/skills/nameless/SKILL.md`
  with a missing-name reason, and NOT create a placement for `nameless`;
- emit a `lock-version-unsupported` finding (found=4, supported=3) yet
  best-effort parse the lock (`healthy` still readable) and surface the unknown
  keys (VAL-SCAN-022/031);
- still inventory the `healthy` sibling.
EOF

# =====================================================================
# skillmd-invalid-a..f — one malformed-frontmatter variant per tree, each with
# a healthy sibling (VAL-SCAN-033). Names/semantics per validation-contract.md.
# =====================================================================
mk_invalid_tree() {
    # mk_invalid_tree LETTER   (writes bad SKILL.md via stdin heredoc)
    local letter="$1"
    local dir; dir="$(reset_fixture "skillmd-invalid-$letter")"
    skill "$dir/.agents/skills/healthy" "healthy" "A healthy control skill."
    mkdir -p "$dir/.agents/skills/bad"
    cat >"$dir/.agents/skills/bad/SKILL.md"
    printf '%s' "$dir"
}

# a: missing `name`
d="$(mk_invalid_tree a <<'EOF'
---
description: Missing the name field entirely.
---

# bad
EOF
)"
note "$d" <<'EOF'
# skillmd-invalid-a — missing `name`

The `bad` skill's frontmatter has no `name` key. A correct scan MUST exit 0,
emit a `skill-md-invalid` issue for `.agents/skills/bad/SKILL.md` (missing name),
create NO placement for `bad`, and still inventory the healthy sibling.
EOF

# b: missing/blank `description`
d="$(mk_invalid_tree b <<'EOF'
---
name: bad
description: ""
---

# bad
EOF
)"
note "$d" <<'EOF'
# skillmd-invalid-b — blank `description`

The `bad` skill has an empty `description`. A correct scan MUST exit 0, emit a
`skill-md-invalid` issue (blank/missing description), create NO placement for
`bad`, and still inventory the healthy sibling.
EOF

# c: frontmatter not a YAML mapping (a sequence)
d="$(mk_invalid_tree c <<'EOF'
---
- item one
- item two
---

# bad
EOF
)"
note "$d" <<'EOF'
# skillmd-invalid-c — frontmatter is not a mapping

The frontmatter parses as a YAML sequence, not a mapping. A correct scan MUST
exit 0, emit a `skill-md-invalid` issue (not a mapping), create NO placement for
`bad`, and still inventory the healthy sibling.
EOF

# d: file does not start with `---`
d="$(mk_invalid_tree d <<'EOF'
# bad

name: bad
description: There is no frontmatter start delimiter at byte 0.
EOF
)"
note "$d" <<'EOF'
# skillmd-invalid-d — no start delimiter

The file does not begin with `---` at byte 0 (strict start delimiter). A correct
scan MUST exit 0, emit a `skill-md-invalid` issue (missing/late start delimiter),
create NO placement for `bad`, and still inventory the healthy sibling.
EOF

# e: UTF-8 BOM before `---`
d="$(reset_fixture skillmd-invalid-e)"
skill "$d/.agents/skills/healthy" "healthy" "A healthy control skill."
mkdir -p "$d/.agents/skills/bad"
# EF BB BF BOM, then the frontmatter. printf the BOM bytes first.
printf '\xEF\xBB\xBF' >"$d/.agents/skills/bad/SKILL.md"
cat >>"$d/.agents/skills/bad/SKILL.md" <<'EOF'
---
name: bad
description: A UTF-8 BOM precedes the start delimiter, so byte 0 is not '-'.
---

# bad
EOF
note "$d" <<'EOF'
# skillmd-invalid-e — UTF-8 BOM before `---`

A 3-byte UTF-8 BOM (EF BB BF) precedes the `---`, so the delimiter is not at
byte 0 (no BOM tolerance). A correct scan MUST exit 0, emit a `skill-md-invalid`
issue (BOM / delimiter not at byte 0), create NO placement for `bad`, and still
inventory the healthy sibling.
EOF

# f: YAML syntax error
d="$(mk_invalid_tree f <<'EOF'
---
name: [unterminated
description: broken YAML flow sequence
---

# bad
EOF
)"
note "$d" <<'EOF'
# skillmd-invalid-f — YAML syntax error

The frontmatter contains an unterminated flow sequence. A correct scan MUST
exit 0, emit a `skill-md-invalid` issue (YAML parse error), create NO placement
for `bad`, and still inventory the healthy sibling.
EOF

# =====================================================================
# skillmd-early-close — a multi-line YAML string containing a line beginning
# `---` truncates the frontmatter early (upstream "first \n--- closes"), orphaning
# the later required `name` field (VAL-SCAN-034).
# =====================================================================
d="$(reset_fixture skillmd-early-close)"
skill "$d/.agents/skills/healthy" "healthy" "A healthy control skill."
mkdir -p "$d/.agents/skills/early"
cat >"$d/.agents/skills/early/SKILL.md" <<'EOF'
---
description: |
  A multi-line description whose author included a horizontal rule.
  The next line begins with three dashes:
---
name: early-close-demo
extra: this and name were orphaned by the premature delimiter
---

# early-close-demo
EOF
note "$d" <<'EOF'
# skillmd-early-close — early frontmatter close (upstream parity)

The multi-line `description` block is followed by a line beginning `---`, which
upstream's "first `\n---` closes the frontmatter" rule treats as the closing
delimiter. That truncates the frontmatter BEFORE the `name:` line, orphaning the
required field. A correct scan MUST reproduce upstream behavior (do NOT hunt for
the real closing delimiter): parse the truncated frontmatter and emit a
`skill-md-invalid` issue for missing `name`. Exit 0; healthy sibling inventoried.
EOF

# =====================================================================
# FIX-GARBAGE — every defect kind in one tree.
# =====================================================================
d="$(reset_fixture FIX-GARBAGE)"
# one healthy skill (must survive)
skill "$d/.agents/skills/survivor" "survivor" "A healthy skill amid the garbage."
# malformed SKILL.md (missing name)
mkdir -p "$d/.agents/skills/nameless"
cat >"$d/.agents/skills/nameless/SKILL.md" <<'EOF'
---
description: no name here
---
# nameless
EOF
# malformed lock (truncated JSON)
printf '{ "version": 3, "skills": { "x": { "source":' >"$d/.agents/.skill-lock.json"
# broken symlink inside a host skills dir
mkdir -p "$d/.claude/skills"
: >"$d/.claude/config.json"           # make claude-code a detected host
ln -s /nonexistent/rotted-target "$d/.claude/skills/rotted"
# stray non-skill files
echo "just a note" >"$d/.agents/skills/README.txt"
echo "not yaml, not a skill" >"$d/.agents/skills/loose.bin"
# a dir that LOOKS like a skill but has no SKILL.md
mkdir -p "$d/.agents/skills/no-skill-md"
echo "helper" >"$d/.agents/skills/no-skill-md/helper.py"
# placeholder for a runtime chmod-000 dir (git cannot store 000 perms; see
# prepare-runtime.sh). Contains a healthy skill that should survive once the
# dir is made readable again.
skill "$d/.agents/skills/locked-dir/inner" "inner" "A skill inside a dir that prepare-runtime.sh chmods 000."
note "$d" <<'EOF'
# FIX-GARBAGE — expectation (defect manifest)

One tree, many independent defects. Every defect MUST surface as its own
issue/finding and none may suppress the others. Scan MUST exit 0.

Planted defects:
- `.agents/skills/survivor` — HEALTHY; MUST be inventoried (ownerless).
- `.agents/skills/nameless/SKILL.md` — malformed (missing name) -> skill-md-invalid issue, no placement.
- `.agents/.skill-lock.json` — truncated JSON -> ledger-unreadable issue; scope treated as no-lock.
- `.claude/skills/rotted -> /nonexistent/rotted-target` — dangling symlink -> brokenSymlink placement + broken-symlink finding.
- `.agents/skills/README.txt`, `loose.bin` — stray non-skill files -> ignored, never placements.
- `.agents/skills/no-skill-md/` — dir without SKILL.md -> not a placement.
- `.agents/skills/locked-dir/` — see prepare-runtime.sh: chmodded 000 at runtime
  to exercise the unreadable-dir path (issue naming the path). Its inner skill
  survives once readable.

Runtime note: git cannot store a chmod-000 directory; run
`Scripts/fixtures/prepare-runtime.sh <FIXTURES_DIR>` before validators exercise
the unreadable-dir behavior. The offline smoke test does not require it.
EOF

# =====================================================================
# FIX-DANGER — collision-matrix scenario-6 pre-state: gh-owned + ownerless in a
# host dir (neither in the vercel lock) + one vercel-owned control.
# =====================================================================
d="$(reset_fixture FIX-DANGER)"
mkdir -p "$d/.claude"; : >"$d/.claude/config.json"   # claude-code detected
gh_skill "$d/.claude/skills/gh-tool" "gh-tool" "A gh-owned skill." \
    "https://github.com/thedavidweng/skills" "tools/gh-tool/SKILL.md" \
    "refs/heads/main" "214349b9b6ede59ff72ba15797186668fcfec535"
skill "$d/.claude/skills/orphan" "orphan" "An ownerless skill, no ledger anywhere."
# vercel-owned control lives in the canonical store with a global lock entry
skill "$d/.agents/skills/vercel-ctl" "vercel-ctl" "A vercel-owned control skill."
cat >"$d/.agents/.skill-lock.json" <<'EOF'
{
  "version": 3,
  "skills": {
    "vercel-ctl": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "skillPath": ".agents/skills/vercel-ctl/SKILL.md",
      "skillFolderHash": "4444444444444444444444444444444444444444",
      "installedAt": "2026-06-15T23:27:24.742Z",
      "updatedAt": "2026-06-15T23:27:24.742Z"
    }
  },
  "dismissed": {}
}
EOF
note "$d" <<'EOF'
# FIX-DANGER — expectation (collision-matrix scenario 6 pre-state)

Contents: in the claude-code host dir, one gh-owned skill (`gh-tool`, frontmatter
github-* provenance, no lock entry) and one ownerless skill (`orphan`, no ledger).
In the canonical store, one vercel-owned control (`vercel-ctl`, global lock entry).

A correct scan MUST:
- exit 0;
- resolve ownership: gh-tool=github, orphan=ownerless, vercel-ctl=vercel;
- emit a `dangerous-removal-surface` advisory for gh-tool AND orphan (both would be
  deleted by name by `npx skills remove`), each naming skillName/placementPath/ownership;
- NOT emit that advisory for vercel-ctl (its removal is ledger-consistent);
- additionally emit `files-without-lock` for `orphan` (ownerless inventory listing).
EOF

# =====================================================================
# FIX-BIG — ~40 vercel-owned skills to force scrolling / output-size checks.
# =====================================================================
d="$(reset_fixture FIX-BIG)"
mkdir -p "$d/.agents"
lock="$d/.agents/.skill-lock.json"
{
    echo '{'
    echo '  "version": 3,'
    echo '  "skills": {'
    for i in $(seq 0 39); do
        n=$(printf 'skill-%03d' "$i")
        skill "$d/.agents/skills/$n" "$n" "Bulk skill number $i for scrolling tests."
        comma=","
        if [ "$i" -eq 39 ]; then comma=""; fi
        cat <<EOF
    "$n": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "skillPath": ".agents/skills/$n/SKILL.md",
      "skillFolderHash": "000000000000000000000000000000000000$(printf '%04d' "$i")",
      "installedAt": "2026-06-15T23:27:24.742Z",
      "updatedAt": "2026-06-15T23:27:24.742Z"
    }$comma
EOF
    done
    echo '  },'
    echo '  "dismissed": {}'
    echo '}'
} >"$lock"
note "$d" <<'EOF'
# FIX-BIG — expectation

Contents: 40 vercel-owned user-scope skills `skill-000`..`skill-039`, each with a
global lock entry.

A correct scan MUST exit 0 and inventory all 40 skills (ownership=vercel,
single placement each), producing zero actionable findings. Used for launch
non-blocking, scrolling, and output-size checks; the count (40) is fixed so
validators can assert it.
EOF

# =====================================================================
# FIX-DUPLICATES — alias + exact + divergent triplet across host dirs.
# =====================================================================
d="$(reset_fixture FIX-DUPLICATES)"
mkdir -p "$d/.claude" "$d/.codex"; : >"$d/.claude/config.json"; : >"$d/.codex/config.json"
# alias pair: one canonical dir, two host symlinks to it
skill "$d/.agents/skills/alias-demo" "alias-demo" "Aliased via symlinks; one canonical copy."
mkdir -p "$d/.claude/skills" "$d/.codex/skills"
ln -s ../../.agents/skills/alias-demo "$d/.claude/skills/alias-demo"
ln -s ../../.agents/skills/alias-demo "$d/.codex/skills/alias-demo"
# exact pair: two real dirs, byte-identical content, distinct paths
skill "$d/.claude/skills/exact-demo" "exact-demo" "Exact copy in two hosts."
skill "$d/.codex/skills/exact-demo" "exact-demo" "Exact copy in two hosts."
# divergent pair: two real dirs, same name, DIFFERENT content
skill "$d/.claude/skills/div-demo" "div-demo" "Divergent copy A."
mkdir -p "$d/.codex/skills/div-demo"
cat >"$d/.codex/skills/div-demo/SKILL.md" <<'EOF'
---
name: div-demo
description: Divergent copy B (content differs from the claude copy).
---

# div-demo

This copy has extra, differing content so its hash diverges.
EOF
note "$d" <<'EOF'
# FIX-DUPLICATES — expectation

Three cross-host duplicate situations in one user-scope tree (claude-code and
codex hosts detected via a config marker):

- `alias-demo` — canonical `.agents/skills/alias-demo` + symlinks in
  `.claude/skills` and `.codex/skills`. ONE logical skill, 3 placements sharing
  one canonical path -> cross-host-duplicate subtype=alias, severity=info,
  ambiguous=false.
- `exact-demo` — two REAL dirs (`.claude`, `.codex`) with byte-identical content
  -> cross-host-duplicate subtype=exact, severity=warning, one shared contentHash.
- `div-demo` — two REAL dirs with DIFFERENT content -> cross-host-duplicate
  subtype=divergent, severity=warning, two distinct contentHashes.

Scan MUST exit 0. exact-demo and div-demo are ambiguous names (2 distinct
canonical paths per scope) and also raise `ambiguous-name`; alias-demo does not.
EOF

# =====================================================================
# FIX-LOCK-NO-FILES — a global lock entry whose skill has no placement on disk.
# =====================================================================
d="$(reset_fixture FIX-LOCK-NO-FILES)"
mkdir -p "$d/.agents/skills"       # exists but empty of the ghost skill
cat >"$d/.agents/.skill-lock.json" <<'EOF'
{
  "version": 3,
  "skills": {
    "ghost": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "skillPath": ".agents/skills/ghost/SKILL.md",
      "skillFolderHash": "5555555555555555555555555555555555555555",
      "installedAt": "2026-06-15T23:27:24.742Z",
      "updatedAt": "2026-06-15T23:27:24.742Z"
    }
  },
  "dismissed": {}
}
EOF
note "$d" <<'EOF'
# FIX-LOCK-NO-FILES — expectation

Contents: a global lock claiming `ghost`, but no `ghost` directory on disk.

A correct scan MUST exit 0, emit a `lock-without-files` finding naming the lock
path and entry key `ghost`, and MUST NOT list `ghost` as a healthy placement
(a ledger claim alone conjures no skill).
EOF

# =====================================================================
# FIX-FILES-NO-LOCK — a placement with no lock entry and no gh provenance.
# =====================================================================
d="$(reset_fixture FIX-FILES-NO-LOCK)"
skill "$d/.agents/skills/orphan" "orphan" "A skill with no ledger of any kind."
note "$d" <<'EOF'
# FIX-FILES-NO-LOCK — expectation

Contents: `.agents/skills/orphan` with NO lock file and NO github provenance.

A correct scan MUST exit 0, resolve ownership=ownerless for `orphan`, and emit a
`files-without-lock` finding (info severity) naming the placement path.
EOF

# =====================================================================
# FIX-AMBIGUOUS — one name, two distinct canonical dirs in one scope, plus a
# lock claim on that name.
# =====================================================================
d="$(reset_fixture FIX-AMBIGUOUS)"
mkdir -p "$d/.claude" "$d/.codex"; : >"$d/.claude/config.json"; : >"$d/.codex/config.json"
skill "$d/.claude/skills/dup" "dup" "Ambiguous name, copy in claude."
skill "$d/.codex/skills/dup" "dup" "Ambiguous name, copy in codex."
mkdir -p "$d/.agents"
cat >"$d/.agents/.skill-lock.json" <<'EOF'
{
  "version": 3,
  "skills": {
    "dup": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "skillPath": ".agents/skills/dup/SKILL.md",
      "skillFolderHash": "6666666666666666666666666666666666666666",
      "installedAt": "2026-06-15T23:27:24.742Z",
      "updatedAt": "2026-06-15T23:27:24.742Z"
    }
  },
  "dismissed": {}
}
EOF
note "$d" <<'EOF'
# FIX-AMBIGUOUS — expectation

Contents: the name `dup` present as TWO distinct canonical directories in the
SAME (user) scope — `.claude/skills/dup` and `.codex/skills/dup` — plus a global
lock entry claiming `dup`.

A correct scan MUST exit 0, emit an `ambiguous-name` finding naming both
colliding placement paths, resolve `dup` as ownership=ownerless with
ambiguous=true (attribution voided, never guessed), and still surface the lock
claim as data (not authoritative ownership). Per D1 this is per-scope after
alias collapse; these are two REAL dirs, not symlinks, so the rule fires.
EOF

# =====================================================================
# alias-link-mode — canonical dir + two host symlinks (the D1 negative case).
# =====================================================================
d="$(reset_fixture alias-link-mode)"
mkdir -p "$d/.claude" "$d/.codex"; : >"$d/.claude/config.json"; : >"$d/.codex/config.json"
skill "$d/.agents/skills/demo" "demo" "One canonical skill aliased into two hosts."
mkdir -p "$d/.claude/skills" "$d/.codex/skills"
ln -s ../../.agents/skills/demo "$d/.claude/skills/demo"
ln -s ../../.agents/skills/demo "$d/.codex/skills/demo"
note "$d" <<'EOF'
# alias-link-mode — expectation

Contents: canonical `.agents/skills/demo` plus two host symlinks
(`.claude/skills/demo`, `.codex/skills/demo`) pointing at it.

A correct scan MUST exit 0 and present `demo` as ONE logical skill with exactly
3 placements: the canonical directory plus two kind=symlink placements, each
recording its linkTarget and the SAME resolved canonicalPath. The group is an
alias duplicate (cross-host-duplicate subtype=alias, info). It MUST produce
ZERO `ambiguous-name` findings and report `demo` with ambiguous=false (D1
negative: aliases collapse to one canonical path).
EOF

# =====================================================================
# symlink-mode — a clean symlink-mode install: canonical + one host symlink,
# vercel-owned. The "correct" install shape (contrast copy mode's double copy).
# =====================================================================
d="$(reset_fixture symlink-mode)"
mkdir -p "$d/.claude"; : >"$d/.claude/config.json"
skill "$d/.agents/skills/tool" "tool" "A vercel-owned skill installed in symlink mode."
mkdir -p "$d/.claude/skills"
ln -s ../../.agents/skills/tool "$d/.claude/skills/tool"
cat >"$d/.agents/.skill-lock.json" <<'EOF'
{
  "version": 3,
  "skills": {
    "tool": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "skillPath": ".agents/skills/tool/SKILL.md",
      "skillFolderHash": "7777777777777777777777777777777777777777",
      "installedAt": "2026-06-15T23:27:24.742Z",
      "updatedAt": "2026-06-15T23:27:24.742Z"
    }
  },
  "dismissed": {}
}
EOF
note "$d" <<'EOF'
# symlink-mode — expectation

Contents: canonical `.agents/skills/tool` (vercel-owned, global lock) aliased
into the claude-code host via a symlink. This is the healthy symlink-mode install
shape (one canonical copy, hosts symlink to it) — contrast copy mode, which
double-copies.

A correct scan MUST exit 0 and present `tool` as ONE logical skill,
ownership=vercel, ambiguous=false, with 2 placements (canonical directory + one
symlink sharing the canonical path). The only finding permitted is the
info-severity alias duplicate; NO actionable findings (no divergence, no drift,
no double-booking).
EOF

echo "Hand-built fixtures rebuilt under: $FIX"
