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

# reset_pw_fixture NAME -> wipes/recreates Fixtures/NAME with the two-part
# project-scope layout (.home = fake HOME, proj = a project root scanned via
# SUKIRU_ROOTS), echoes the fixture dir. Mirrors the CM-*/hash-parity layout
# so the smoke test picks up both scopes automatically.
reset_pw_fixture() {
    local dir; dir="$(reset_fixture "$1")"
    mkdir -p "$dir/.home" "$dir/proj"
    printf '%s' "$dir"
}

# skill_md_hash DIR -> the upstream computedHash of a SINGLE-FILE skill dir
# (SKILL.md only, no subdirs): SHA-256 over utf8("SKILL.md") concatenated with
# the file bytes, no separators. With one file the ICU ordering is trivial, so
# this matches ContentHasher and the pinned CLI exactly for this file set.
# Use it to write project v1 lock entries whose computedHash matches disk.
skill_md_hash() {
    ( printf '%s' 'SKILL.md'; cat "$1/SKILL.md" ) | shasum -a 256 | awk '{print $1}'
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
# by design), keeping this the true zero-findings baseline.
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

Note: the Health UI originally called for a richer FIX-CLEAN
spanning all four ownership classes. Because github/ownerless skills always
raise a `dangerous-removal-surface` advisory, a genuinely
zero-findings tree can contain vercel-owned skills only; this fixture honors
the scan engine's zero-findings baseline.
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

The app additionally hides internal skills from host-facing listings while
still surfacing the internal marker; for the scan engine the requirement
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
  keys;
- still inventory the `healthy` sibling.
EOF

# =====================================================================
# skillmd-invalid-a..f — one malformed-frontmatter variant per tree, each with
# a healthy sibling.
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
# the later required `name` field.
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
  survives once readable; nested a level down, it is out of `npx skills
  remove` reach and raises no `dangerous-removal-surface` advisory.

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

Scan MUST exit 0. Under the hash-based ambiguity trigger, no ledger claims
any name here, so every copy is UNEXPLAINED: div-demo's unexplained copies
hold 2 distinct content hashes and DO raise `ambiguous-name`
(ownership=ownerless, attribution voided), while exact-demo's copies share ONE
hash and are NOT ambiguous (plain ownerless, listed via `files-without-lock`).
alias-demo is never ambiguous.
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
claim as data (not authoritative ownership). Ambiguity is judged per scope
after alias collapse; these are two REAL dirs with DIVERGENT content, and
neither is explained: the lock claims `dup` but there is NO canonical-store
placement to hash-anchor them to, and neither carries gh frontmatter
— two unexplained copies, two distinct hashes, so the rule fires.
EOF

# =====================================================================
# alias-link-mode — canonical dir + two host symlinks (the ambiguity negative case).
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
ZERO `ambiguous-name` findings and report `demo` with ambiguous=false (the
negative case: aliases collapse to one canonical path).
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

# =====================================================================
# scope-isolation — the same skill name in user scope and one project root,
# plus one finding-generating defect per scope.
# =====================================================================
d="$(reset_pw_fixture scope-isolation)"
skill "$d/.home/.agents/skills/shared-skill" "shared-skill" "User-scope copy of the shared name."
skill "$d/.home/.agents/skills/user-orphan" "user-orphan" "Ownerless user-scope defect (files-without-lock)."
skill "$d/proj/.agents/skills/shared-skill" "shared-skill" "Project-scope copy of the shared name."
skill "$d/proj/.agents/skills/proj-orphan" "proj-orphan" "Ownerless project-scope defect (files-without-lock)."
shared_hash="$(skill_md_hash "$d/proj/.agents/skills/shared-skill")"
cat >"$d/.home/.agents/.skill-lock.json" <<'EOF'
{
  "version": 3,
  "skills": {
    "shared-skill": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "skillPath": ".agents/skills/shared-skill/SKILL.md",
      "skillFolderHash": "8888888888888888888888888888888888888888",
      "installedAt": "2026-06-15T23:27:24.742Z",
      "updatedAt": "2026-06-15T23:27:24.742Z"
    }
  },
  "dismissed": {}
}
EOF
cat >"$d/proj/skills-lock.json" <<EOF
{
  "version": 1,
  "skills": {
    "shared-skill": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "skillPath": ".agents/skills/shared-skill/SKILL.md",
      "computedHash": "$shared_hash"
    }
  }
}
EOF
note "$d" <<'EOF'
# scope-isolation — expectation

Contents: the name `shared-skill` installed TWICE — user scope
(`.home/.agents/skills/shared-skill`, claimed by the global v3 lock) and project
scope (`proj/.agents/skills/shared-skill`, claimed by the project v1 lock whose
computedHash matches disk). Plus ONE finding-generating defect per scope:
`user-orphan` (ownerless, user scope) and `proj-orphan` (ownerless, project
scope), each raising `files-without-lock` in ITS OWN scope only.

Scan with SUKIRU_HOME=<this>/.home, SUKIRU_ROOTS=<this>/proj.

A correct scan MUST:
- exit 0;
- tag every workspace/placement/finding with an unambiguous scope;
- resolve `shared-skill` ownership per scope: vercel in BOTH, but the user-scope
  resolution MUST come from the global lock only and the project-scope one from
  the project lock only (no cross-scope ledger bleed);
- keep the `user-orphan` finding out of every project-scope workspace section
  and the `proj-orphan` finding out of every user-scope section;
- with `--scope user` report ONLY user-scope items, with `--scope project` ONLY
  project-scope items, and with `--scope all` exactly the union;
- NOT flag `shared-skill` as ambiguous (one placement per scope; the ambiguity
  rule is per-scope).
EOF

# =====================================================================
# multi-host-inventory — several host global dirs + one project root, a
# distinct skill in each.
# =====================================================================
d="$(reset_pw_fixture multi-host-inventory)"
mkdir -p "$d/.home/.claude" "$d/.home/.codex"
: >"$d/.home/.claude/config.json"; : >"$d/.home/.codex/config.json"
skill "$d/.home/.agents/skills/canon-tool" "canon-tool" "Lives in the user canonical store."
skill "$d/.home/.claude/skills/claude-tool" "claude-tool" "Visible to claude-code only."
skill "$d/.home/.codex/skills/codex-tool" "codex-tool" "Visible to codex only."
skill "$d/proj/.agents/skills/proj-canon" "proj-canon" "Project canonical store skill."
skill "$d/proj/.claude/skills/proj-claude" "proj-claude" "Project claude-code host skill."
note "$d" <<'EOF'
# multi-host-inventory — expectation

Contents (placement manifest — five distinct skills, one placement each):
- user scope: `.home/.agents/skills/canon-tool` (canonical store),
  `.home/.claude/skills/claude-tool` (claude-code host, detected via
  config.json), `.home/.codex/skills/codex-tool` (codex host, detected via
  config.json);
- project scope (`proj/`): `.agents/skills/proj-canon` (canonical),
  `.claude/skills/proj-claude` (claude-code project dir).

Scan with SUKIRU_HOME=<this>/.home, SUKIRU_ROOTS=<this>/proj.

A correct scan MUST exit 0 and report EXACTLY these five placements — no
missing, no extra — each with correct workspace attribution, placement kind
(directory), and the skill name parsed from SKILL.md. All five are ownerless,
so `files-without-lock` findings are expected; they do not affect the
placement-set assertion.
EOF

# =====================================================================
# ignore-list — noise containers with valid-looking SKILL.md files inside must
# never become placements.
# =====================================================================
d="$(reset_fixture ignore-list)"
skill "$d/.agents/skills/real-skill" "real-skill" "The one true skill amid the noise dirs."
for noise in node_modules __pycache__ .archive .hidden-junk; do
    skill "$d/.agents/skills/$noise" "noise" "A valid-looking SKILL.md inside an ignored container."
done
mkdir -p "$d/.agents/skills/dist" "$d/.agents/skills/build"
echo "bundled output" >"$d/.agents/skills/dist/bundle.js"
echo "object file" >"$d/.agents/skills/build/app.o"
# git itself refuses to track any path containing a `.git` component, so this
# noise dir exists only in generator output (same caveat as hash-parity's
# inner .git); the checked-in tree simply lacks it.
skill "$d/.agents/skills/.git" "noise" "A valid-looking SKILL.md inside a .git dir."
note "$d" <<'EOF'
# ignore-list — expectation

Contents: `.agents/skills/` holds ONE real skill (`real-skill`) plus noise
containers that must never become placements: `node_modules/`, `__pycache__/`,
`.archive/`, and an unknown dot-dir `.hidden-junk/` (each carrying a
valid-looking SKILL.md), `dist/` and `build/` (non-skill files), and — in
generator output only — `.git/` (git refuses to track a `.git` path component,
so the checked-in tree lacks it; the assertion is unchanged either way).

A correct scan MUST exit 0 and inventory EXACTLY ONE placement: `real-skill`.
No ignored container may surface as a placement or skill.
EOF

# =====================================================================
# own-vercel — lock entry, no gh frontmatter. One skill per
# scope so both scope-correct hash keys are exercised.
# =====================================================================
d="$(reset_pw_fixture own-vercel)"
skill "$d/.home/.agents/skills/global-tool" "global-tool" "Vercel-owned via the global v3 lock."
skill "$d/proj/.agents/skills/proj-tool" "proj-tool" "Vercel-owned via the project v1 lock."
proj_hash="$(skill_md_hash "$d/proj/.agents/skills/proj-tool")"
cat >"$d/.home/.agents/.skill-lock.json" <<'EOF'
{
  "version": 3,
  "skills": {
    "global-tool": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "ref": "refs/heads/main",
      "skillPath": ".agents/skills/global-tool/SKILL.md",
      "skillFolderHash": "9999999999999999999999999999999999999999",
      "installedAt": "2026-06-15T23:27:24.742Z",
      "updatedAt": "2026-06-15T23:27:24.742Z"
    }
  },
  "dismissed": {}
}
EOF
cat >"$d/proj/skills-lock.json" <<EOF
{
  "version": 1,
  "skills": {
    "proj-tool": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "ref": "refs/heads/main",
      "skillPath": ".agents/skills/proj-tool/SKILL.md",
      "computedHash": "$proj_hash"
    }
  }
}
EOF
note "$d" <<'EOF'
# own-vercel — expectation

Contents: two skills with lock entries and NO github frontmatter.
`global-tool` (user scope, global v3 lock) and `proj-tool` (project scope,
project v1 lock whose computedHash matches disk).

Scan with SUKIRU_HOME=<this>/.home, SUKIRU_ROOTS=<this>/proj.

A correct scan MUST:
- exit 0 and resolve ownership=vercel for BOTH skills;
- surface per entry: source, sourceType, sourceUrl, ref, skillPath, and the
  stored hash — mechanically, the PROJECT entry exposes `computedHash` and MUST
  NOT expose `skillFolderHash`, the GLOBAL entry exposes `skillFolderHash` and
  MUST NOT expose `computedHash`; all values byte-equal to the fixture locks;
- emit NO vercel-lock-drift (the project entry matches disk) and NO
  double-booked / files-without-lock findings.
EOF

# =====================================================================
# own-github — metadata.github-repo, no lock entry; one pinned + one unpinned
# placement.
# =====================================================================
d="$(reset_fixture own-github)"
mkdir -p "$d/.claude"; : >"$d/.claude/config.json"
gh_skill "$d/.claude/skills/pinned-tool" "pinned-tool" "A pinned gh-owned skill." \
    "https://github.com/thedavidweng/skills.git" "tools/pinned-tool/SKILL.md" \
    "refs/heads/main" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "pinned"
gh_skill "$d/.claude/skills/unpinned-tool" "unpinned-tool" "An unpinned gh-owned skill." \
    "https://github.com/thedavidweng/skills" "tools/unpinned-tool/SKILL.md" \
    "refs/heads/main" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
note "$d" <<'EOF'
# own-github — expectation

Contents: two gh-owned skills in the claude-code host dir (detected via
config.json), NO lock file anywhere. `pinned-tool` carries
`metadata.github-pinned: true` and a repo URL stored WITH its `.git` suffix;
`unpinned-tool` OMITS the `github-pinned` key entirely.

A correct scan MUST:
- exit 0 and resolve ownership=github for both;
- surface per placement: github-repo (the stored value preserved as-is,
  including the `.git` suffix on pinned-tool), github-path, github-ref (the
  FULL ref `refs/heads/main`, never truncated to a bare branch name), and
  github-tree-sha;
- report pinned-tool as pinned and unpinned-tool as unpinned (an ABSENT
  github-pinned key means unpinned, never pinned);
- emit NO files-without-lock (gh provenance satisfies the ledger requirement)
  and NO vercel findings; a `dangerous-removal-surface` advisory per gh-owned
  skill is expected.
EOF

# =====================================================================
# own-double — lock entry AND metadata.github-repo on the same name.
# =====================================================================
d="$(reset_fixture own-double)"
gh_skill "$d/.agents/skills/double-tool" "double-tool" "Claimed by both ledgers." \
    "https://github.com/thedavidweng/skills" "tools/double-tool/SKILL.md" \
    "refs/heads/main" "cccccccccccccccccccccccccccccccccccccccc"
cat >"$d/.agents/.skill-lock.json" <<'EOF'
{
  "version": 3,
  "skills": {
    "double-tool": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "skillPath": ".agents/skills/double-tool/SKILL.md",
      "skillFolderHash": "dddddddddddddddddddddddddddddddddddddddd",
      "installedAt": "2026-06-15T23:27:24.742Z",
      "updatedAt": "2026-06-15T23:27:24.742Z"
    }
  },
  "dismissed": {}
}
EOF
note "$d" <<'EOF'
# own-double — expectation

Contents: `double-tool` is present in the global v3 lock AND carries
`metadata.github-repo` frontmatter — both ledgers claim the same name.

A correct scan MUST exit 0, resolve ownership=double-booked, and emit a
`double-booked` finding whose evidence references BOTH sides: the lock (lock
path + entry key) and the frontmatter provenance (SKILL.md path + github-repo
value). One-sided evidence or single-ledger ownership is a fail.
EOF

# =====================================================================
# prov-cross-ws — the same logical skill in two workspaces with byte-identical
# provenance.
# =====================================================================
d="$(reset_pw_fixture prov-cross-ws)"
mkdir -p "$d/.home/.claude"; : >"$d/.home/.claude/config.json"
gh_skill "$d/.home/.claude/skills/shared" "shared" "Same logical skill in two workspaces." \
    "https://github.com/thedavidweng/skills" "tools/shared/SKILL.md" \
    "refs/heads/main" "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" "pinned"
gh_skill "$d/proj/.claude/skills/shared" "shared" "Same logical skill in two workspaces." \
    "https://github.com/thedavidweng/skills" "tools/shared/SKILL.md" \
    "refs/heads/main" "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" "pinned"
note "$d" <<'EOF'
# prov-cross-ws — expectation

Contents: the same logical skill `shared` installed by gh into TWO workspaces —
the user-scope claude-code host dir (`.home/.claude/skills/shared`) and a
project-scope claude-code dir (`proj/.claude/skills/shared`). Both copies carry
BYTE-IDENTICAL frontmatter, hence identical github provenance (repo, path,
ref=refs/heads/main, tree-sha, pinned=true). No lock files anywhere.

Scan with SUKIRU_HOME=<this>/.home, SUKIRU_ROOTS=<this>/proj.

A correct scan MUST exit 0 and report the github provenance of `shared`
BYTE-EQUAL in every workspace context in which the skill appears. (One
placement per scope, so no ambiguity; gh-owned, so a
dangerous-removal-surface advisory per workspace is expected.)
EOF

# =====================================================================
# lock-unknown-fields — extra unknown keys on entries and at top level must be
# preserved and surfaced, never dropped.
# =====================================================================
d="$(reset_fixture lock-unknown-fields)"
skill "$d/.agents/skills/known-tool" "known-tool" "Locked, with unknown keys around the entry."
cat >"$d/.agents/.skill-lock.json" <<'EOF'
{
  "version": 3,
  "skills": {
    "known-tool": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "skillPath": ".agents/skills/known-tool/SKILL.md",
      "skillFolderHash": "ffffffffffffffffffffffffffffffffffffffff",
      "channel": "beta",
      "priority": 7,
      "installedAt": "2026-06-15T23:27:24.742Z",
      "updatedAt": "2026-06-15T23:27:24.742Z"
    }
  },
  "dismissed": {},
  "futureTopLevelKey": "preserved",
  "experimental": {"flag": true}
}
EOF
note "$d" <<'EOF'
# lock-unknown-fields — expectation

Contents: a SUPPORTED (v3) global lock whose `known-tool` entry carries extra
unknown keys (`channel: "beta"`, `priority: 7`) and whose top level carries
unknown keys (`futureTopLevelKey`, an `experimental` object).

A correct scan MUST exit 0, use the entry normally (ownership=vercel), and
surface the unknown keys with their ORIGINAL values in the report's
entry/top-level extras — never drop them, never error on them.
EOF

# =====================================================================
# lock-drift — project lock computedHash stale after an out-of-band edit, plus
# a global-scope control proving drift detection is project-only.
# =====================================================================
d="$(reset_pw_fixture lock-drift)"
skill "$d/proj/.agents/skills/drifted" "drifted" "Original content, as installed."
stale_hash="$(skill_md_hash "$d/proj/.agents/skills/drifted")"
skill "$d/proj/.agents/skills/drifted" "drifted" "Edited out-of-band AFTER install; the lock computedHash is now stale."
skill "$d/.home/.agents/skills/global-ctl" "global-ctl" "Global control; its tree SHA is never recomputed."
cat >"$d/.home/.agents/.skill-lock.json" <<'EOF'
{
  "version": 3,
  "skills": {
    "global-ctl": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "skillPath": ".agents/skills/global-ctl/SKILL.md",
      "skillFolderHash": "0000000000000000000000000000000000000000",
      "installedAt": "2026-06-15T23:27:24.742Z",
      "updatedAt": "2026-06-15T23:27:24.742Z"
    }
  },
  "dismissed": {}
}
EOF
cat >"$d/proj/skills-lock.json" <<EOF
{
  "version": 1,
  "skills": {
    "drifted": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "skillPath": ".agents/skills/drifted/SKILL.md",
      "computedHash": "$stale_hash"
    }
  }
}
EOF
note "$d" <<'EOF'
# lock-drift — expectation

Contents: project scope (`proj/`) holds `drifted`, whose SKILL.md was edited
out-of-band AFTER the v1 lock entry was written — the lock's computedHash is
the hash of the ORIGINAL content, so it no longer matches disk. User scope
holds `global-ctl` under a global v3 lock whose skillFolderHash (a git tree
SHA) also disagrees with disk — but global hashes are never recomputed, so
that disagreement is by-design silent.

Scan with SUKIRU_HOME=<this>/.home, SUKIRU_ROOTS=<this>/proj.

A correct scan MUST exit 0 and emit a `vercel-lock-drift` finding for
`drifted` whose evidence names the lock path, the entry key, the stored
(expected) hash, and the recomputed (actual) hash. It MUST emit ZERO drift
findings for the global-scope entry.
EOF

# =====================================================================
# divergence-canonical — canonical vs host copy hash mismatch under one source
# identity (collision-matrix scenario-3 shape).
# =====================================================================
d="$(reset_pw_fixture divergence-canonical)"
skill "$d/proj/.agents/skills/web-tool" "web-tool" "Canonical copy, untouched since install."
skill "$d/proj/.claude/skills/web-tool" "web-tool" "Canonical copy, untouched since install."
skill "$d/proj/.claude/skills/web-tool" "web-tool" "Overwritten out-of-band; content now diverges from the canonical copy."
canon_hash="$(skill_md_hash "$d/proj/.agents/skills/web-tool")"
: >"$d/.home/.gitkeep"
cat >"$d/proj/skills-lock.json" <<EOF
{
  "version": 1,
  "skills": {
    "web-tool": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "skillPath": ".agents/skills/web-tool/SKILL.md",
      "computedHash": "$canon_hash"
    }
  }
}
EOF
note "$d" <<'EOF'
# divergence-canonical — expectation

Contents: a copy-mode install in `proj/` — canonical `.agents/skills/web-tool`
plus host copy `.claude/skills/web-tool`, both under ONE v1 lock source
identity. After install, the HOST COPY was overwritten out-of-band, so the two
placements hash differently; the lock's computedHash still matches the
canonical copy.

Scan with SUKIRU_HOME=<this>/.home, SUKIRU_ROOTS=<this>/proj.

A correct scan MUST exit 0 and emit a `canonical-host-divergence` finding
naming both placement paths, the shared source identity, and BOTH content
hashes. (A divergent-subtype cross-host-duplicate finding for the same pair is
also legitimate; the assertion targets canonical-host-divergence.)
EOF

# =====================================================================
# lock-version-old — project lock version 0, below the supported v1.
# =====================================================================
d="$(reset_pw_fixture lock-version-old)"
skill "$d/proj/.agents/skills/old-tool" "old-tool" "Claimed by a version-0 lock that must not be used."
: >"$d/.home/.gitkeep"
cat >"$d/proj/skills-lock.json" <<'EOF'
{
  "version": 0,
  "skills": {
    "old-tool": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "skillPath": ".agents/skills/old-tool/SKILL.md",
      "computedHash": "0000000000000000000000000000000000000000000000000000000000000000"
    }
  }
}
EOF
note "$d" <<'EOF'
# lock-version-old — expectation

Contents: `proj/skills-lock.json` has `version: 0`, BELOW the supported
project-lock v1, with an entry claiming the on-disk `old-tool`.

Scan with SUKIRU_HOME=<this>/.home, SUKIRU_ROOTS=<this>/proj.

A correct scan MUST exit 0, report an incompatible-lock issue (found version 0,
supported 1), and NOT use the stale entries: `old-tool` resolves ownership from
disk/frontmatter alone (ownerless here, so a `files-without-lock` finding is
expected). Silent acceptance of the old lock is a fail.
EOF

# =====================================================================
# lock-malformed — truncated/invalid lock JSON is an issue, never fatal.
# =====================================================================
d="$(reset_fixture lock-malformed)"
skill "$d/.agents/skills/survivor" "survivor" "Healthy skill; its scope's lock is truncated JSON."
printf '{ "version": 3, "skills": { "survivor": { "source":' >"$d/.agents/.skill-lock.json"
note "$d" <<'EOF'
# lock-malformed — expectation

Contents: `.agents/.skill-lock.json` is TRUNCATED, invalid JSON; one healthy
skill `survivor` sits alongside.

A correct scan MUST exit 0, report a `ledger-unreadable` issue naming the lock
path, treat the scope as having NO lock entries, and still inventory `survivor`
(ownership resolved from disk/frontmatter alone → ownerless, so a
`files-without-lock` finding is expected). A crash, non-zero exit, or dropped
placement is a fail.

(FIX-GARBAGE plants the same defect amid other garbage; this tree isolates it.)
EOF

# =====================================================================
# clean-copy-mode — stock npx copy-mode layout: canonical + physical host copy,
# v1 project lock matching disk. Yields ONLY the warning-level exact-duplicate
# finding (a stock copy-mode layout is NOT the zero-findings baseline).
# =====================================================================
d="$(reset_pw_fixture clean-copy-mode)"
skill "$d/proj/.agents/skills/web-tool" "web-tool" "Installed by npx copy mode."
skill "$d/proj/.claude/skills/web-tool" "web-tool" "Installed by npx copy mode."
copy_hash="$(skill_md_hash "$d/proj/.agents/skills/web-tool")"
: >"$d/.home/.gitkeep"
cat >"$d/proj/skills-lock.json" <<EOF
{
  "version": 1,
  "skills": {
    "web-tool": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "skillPath": ".agents/skills/web-tool/SKILL.md",
      "computedHash": "$copy_hash"
    }
  }
}
EOF
note "$d" <<'EOF'
# clean-copy-mode — expectation

Contents: the stock `npx skills add --copy` layout in `proj/` — canonical
`.agents/skills/web-tool` plus a byte-identical physical copy at
`.claude/skills/web-tool`, with a v1 project lock whose computedHash matches
disk.

Scan with SUKIRU_HOME=<this>/.home, SUKIRU_ROOTS=<this>/proj.

A correct scan MUST exit 0 with valid JSON (this is the well-formed
baseline tree), show ownership=vercel, surface the lock provenance fields,
and emit the warning-level exact-subtype cross-host-duplicate finding that a
stock copy-mode layout legitimately produces (so it is NOT the
zero-findings baseline — that is FIX-CLEAN). NO drift, NO double-booked, NO
files-without-lock findings.
EOF

# =====================================================================
# impostor-copy — the managed layout implies a symlink into the canonical
# store, but the host path is a physical copy.
# =====================================================================
d="$(reset_fixture impostor-copy)"
mkdir -p "$d/.claude"; : >"$d/.claude/config.json"
skill "$d/.agents/skills/tool" "tool" "Canonical copy in the managed store."
skill "$d/.claude/skills/tool" "tool" "Canonical copy in the managed store."
cat >"$d/.agents/.skill-lock.json" <<'EOF'
{
  "version": 3,
  "skills": {
    "tool": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "skillPath": ".agents/skills/tool/SKILL.md",
      "skillFolderHash": "1212121212121212121212121212121212121212",
      "installedAt": "2026-06-15T23:27:24.742Z",
      "updatedAt": "2026-06-15T23:27:24.742Z"
    }
  },
  "dismissed": {}
}
EOF
note "$d" <<'EOF'
# impostor-copy — expectation

Contents: `tool` exists in the canonical store (`.agents/skills/tool`, claimed
by the global v3 lock) AND in the claude-code host dir — but
`.claude/skills/tool` is a REAL DIRECTORY (a physical copy, byte-identical
content) where the managed canonical-store layout implies a symlink into the
store. A double-copied impostor.

A correct scan MUST exit 0 and emit a `symlink-authenticity` finding
identifying the impostor path (`.claude/skills/tool`) and the canonical path it
should link to (`.agents/skills/tool`). Accepting the copy silently as a
normal placement is a fail. (An exact-subtype cross-host-duplicate finding for
the pair is also legitimate; the assertion targets symlink-authenticity.)
EOF

# =====================================================================
# FIX-USER-SCOPE-COPY-MODE — a LEGITIMATE user-scope copy-mode install:
# global lock entry + canonical store copy + physical host copies. The
# symlink-authenticity heuristic false-positives on this shape in v1
# (accepted limitation; see EXPECTATION.md).
# =====================================================================
d="$(reset_fixture FIX-USER-SCOPE-COPY-MODE)"
mkdir -p "$d/.claude"; : >"$d/.claude/config.json"
mkdir -p "$d/.cursor"; : >"$d/.cursor/config.json"
skill "$d/.agents/skills/copy-tool" "copy-tool" "Installed in user scope with copy mode."
skill "$d/.claude/skills/copy-tool" "copy-tool" "Installed in user scope with copy mode."
skill "$d/.cursor/skills/copy-tool" "copy-tool" "Installed in user scope with copy mode."
cat >"$d/.agents/.skill-lock.json" <<'EOF'
{
  "version": 3,
  "skills": {
    "copy-tool": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "skillPath": ".agents/skills/copy-tool/SKILL.md",
      "skillFolderHash": "3434343434343434343434343434343434343434",
      "installedAt": "2026-06-16T10:00:00.000Z",
      "updatedAt": "2026-06-16T10:00:00.000Z"
    }
  },
  "dismissed": {}
}
EOF
note "$d" <<'EOF'
# FIX-USER-SCOPE-COPY-MODE — expectation (accepted v1 false positive)

Contents: `copy-tool` is a LEGITIMATE user-scope COPY-MODE install — the
global v3 lock claims it, the canonical store holds the real directory
(`.agents/skills/copy-tool`), and the claude-code and cursor host dirs hold
byte-identical PHYSICAL copies (not symlinks). This is what a copy-mode
install (`add --copy`, or older CLI versions that always copied) produces at
user scope. Nothing is rotted; nothing needs repair.

KNOWN v1 LIMITATION (accepted per the health-analyzer handoff): the
`symlink-authenticity` rule is a structural heuristic — a user-scope managed
layout implies host placements are symlinks into the canonical store, so it
flags every physical host copy as an impostor. The global lock records no
install-mode bit, so this legitimate shape is indistinguishable from a rotted
link-mode install (see `impostor-copy`).

PINNED CURRENT BEHAVIOR: a correct v1 scan MUST exit 0, resolve
ownership=vercel with ambiguous=false, emit the exact-subtype
cross-host-duplicate warning (three physical copies, one hash), NO drift and
NO lock-without-files — AND emit TWO `symlink-authenticity` warnings, one per
host copy (`.claude/skills/copy-tool`, `.cursor/skills/copy-tool`), each
carrying `canonicalPath` = the store copy. Those two findings are FALSE
POSITIVES by design in v1.

A future fix (e.g. flagging only when SIBLING host placements are symlinks
into the same store — mixed link/copy shape is the true rot signal) must flip
this expectation deliberately, with the fixture updated in the same commit.
EOF

# =====================================================================
# own-per-project — the SAME name locked in one project root and
# unprovenanced in another. Two project roots, one scan.
# Layout: .home (fake HOME, empty) + p1 + p2 (no `proj`, so the corpus smoke
# test scans the tree as a plain home and finds nothing — by design).
# =====================================================================
d="$(reset_fixture own-per-project)"
mkdir -p "$d/.home"
: >"$d/.home/.gitkeep"
: >"$d/.home/.gitkeep"
skill "$d/p1/.agents/skills/shared" "shared" "Locked in p1 only."
skill "$d/p2/.agents/skills/shared" "shared" "Unprovenanced in p2."
p1_hash="$(skill_md_hash "$d/p1/.agents/skills/shared")"
cat >"$d/p1/skills-lock.json" <<EOF
{
  "version": 1,
  "skills": {
    "shared": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "ref": "refs/heads/main",
      "skillPath": ".agents/skills/shared/SKILL.md",
      "computedHash": "$p1_hash"
    }
  }
}
EOF
note "$d" <<'EOF'
# own-per-project — expectation

Contents: the name `shared` in TWO project roots — locked by the project v1
lock in `p1` (whose computedHash matches disk), present as a bare placement
with NO lock and NO gh provenance in `p2`. The fake home is empty.

Scan with SUKIRU_HOME=<this>/.home SUKIRU_ROOTS=<this>/p1:<this>/p2.

A correct scan MUST exit 0 and, in ONE report, resolve ownership=vercel for
`shared` in p1 AND ownership=ownerless for `shared` in p2 with a
files-without-lock finding anchored to p2's workspace only. Any cross-root
ledger bleed (the p1 lock claiming p2's placement) is a fail.
EOF

# =====================================================================
# Health-area fixtures. These are the trees the
# app-level assertions drive: FIX-OWNERSHIP-QUAD, FIX-SCOPES, FIX-MULTI-HOST,
# FIX-DRIFT, FIX-DOUBLE-BOOKED, FIX-SYMLINK, FIX-HOST-DIVERGENCE,
# FIX-DIRTY-SUITE, FIX-MUTABLE.
# =====================================================================

# =====================================================================
# FIX-OWNERSHIP-QUAD — FIVE skills covering every ownership state the UI
# asserts on: one vercel (lock-derived source/ref), TWO
# github (one pinned, one unpinned), one double-booked, one ownerless.
# =====================================================================
d="$(reset_fixture FIX-OWNERSHIP-QUAD)"
mkdir -p "$d/.claude"; : >"$d/.claude/config.json"
skill "$d/.agents/skills/vercel-skill" "vercel-skill" "Owned by the vercel global lock."
gh_skill "$d/.claude/skills/gh-pinned" "gh-pinned" "GitHub-owned, pinned." \
    "https://github.com/thedavidweng/skills" "tools/gh-pinned/SKILL.md" \
    "refs/tags/v1.2.3" "aaaaaaaabbbbbbbbccccccccddddddddeeeeeeee" "pinned"
gh_skill "$d/.claude/skills/gh-unpinned" "gh-unpinned" "GitHub-owned, unpinned." \
    "https://github.com/thedavidweng/skills" "tools/gh-unpinned/SKILL.md" \
    "refs/heads/main" "ffffffff00000000111111112222222233333333"
gh_skill "$d/.agents/skills/double-booked-skill" "double-booked-skill" "Claimed by both ledgers." \
    "https://github.com/thedavidweng/skills" "tools/double-booked-skill/SKILL.md" \
    "refs/heads/main" "4444444455555555666666667777777788888888"
skill "$d/.agents/skills/ownerless-skill" "ownerless-skill" "No ledger of any kind."
cat >"$d/.agents/.skill-lock.json" <<'EOF'
{
  "version": 3,
  "skills": {
    "vercel-skill": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "ref": "refs/heads/main",
      "skillPath": ".agents/skills/vercel-skill/SKILL.md",
      "skillFolderHash": "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1",
      "installedAt": "2026-06-15T23:27:24.742Z",
      "updatedAt": "2026-06-15T23:27:24.742Z"
    },
    "double-booked-skill": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "skillPath": ".agents/skills/double-booked-skill/SKILL.md",
      "skillFolderHash": "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2",
      "installedAt": "2026-06-15T23:27:24.742Z",
      "updatedAt": "2026-06-15T23:27:24.742Z"
    }
  },
  "dismissed": {}
}
EOF
note "$d" <<'EOF'
# FIX-OWNERSHIP-QUAD — expectation

Contents: FIVE user-scope skills, one per ownership state the UI asserts on:
- `vercel-skill` — canonical `.agents/skills/vercel-skill` + global v3 lock
  entry (lock-derived source `thedavidweng/skills`, ref `refs/heads/main`).
- `gh-pinned` — `.claude/skills/gh-pinned`, github provenance, `github-pinned:
  true`, ref `refs/tags/v1.2.3`.
- `gh-unpinned` — `.claude/skills/gh-unpinned`, github provenance, NO
  `github-pinned` key (absent = unpinned), ref `refs/heads/main`.
- `double-booked-skill` — canonical store, global lock entry AND
  `metadata.github-repo` frontmatter.
- `ownerless-skill` — canonical store, no ledger of any kind.

A correct scan MUST exit 0 and resolve ownership: vercel-skill=vercel,
gh-pinned=github (pinned), gh-unpinned=github (unpinned),
double-booked-skill=double-booked, ownerless-skill=ownerless. Expected
findings: `double-booked` (both-ledger evidence), `dangerous-removal-surface`
for gh-pinned, gh-unpinned, and ownerless-skill, and `files-without-lock` for
ownerless-skill. This is deliberately NOT a clean tree — github/ownerless
skills always raise the advisory, which is why FIX-CLEAN stays vercel-only;
do not merge the two.
EOF

# =====================================================================
# FIX-SCOPES — user scope + one project root (via SUKIRU_ROOTS), including one
# same-named skill in BOTH scopes.
# All skills vercel-owned with matching hashes: zero findings, so scope
# separation is the only signal under test.
# =====================================================================
d="$(reset_pw_fixture FIX-SCOPES)"
skill "$d/.home/.agents/skills/shared-name" "shared-name" "The user-scope copy of the shared name."
skill "$d/.home/.agents/skills/user-only" "user-only" "Only in the user scope."
skill "$d/proj/.agents/skills/shared-name" "shared-name" "The project-scope copy of the shared name."
skill "$d/proj/.agents/skills/proj-only" "proj-only" "Only in the project scope."
proj_shared_hash="$(skill_md_hash "$d/proj/.agents/skills/shared-name")"
proj_only_hash="$(skill_md_hash "$d/proj/.agents/skills/proj-only")"
cat >"$d/.home/.agents/.skill-lock.json" <<'EOF'
{
  "version": 3,
  "skills": {
    "shared-name": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "skillPath": ".agents/skills/shared-name/SKILL.md",
      "skillFolderHash": "c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3",
      "installedAt": "2026-06-15T23:27:24.742Z",
      "updatedAt": "2026-06-15T23:27:24.742Z"
    },
    "user-only": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "skillPath": ".agents/skills/user-only/SKILL.md",
      "skillFolderHash": "d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4",
      "installedAt": "2026-06-15T23:27:24.742Z",
      "updatedAt": "2026-06-15T23:27:24.742Z"
    }
  },
  "dismissed": {}
}
EOF
cat >"$d/proj/skills-lock.json" <<EOF
{
  "version": 1,
  "skills": {
    "shared-name": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "skillPath": ".agents/skills/shared-name/SKILL.md",
      "computedHash": "$proj_shared_hash"
    },
    "proj-only": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "skillPath": ".agents/skills/proj-only/SKILL.md",
      "computedHash": "$proj_only_hash"
    }
  }
}
EOF
note "$d" <<'EOF'
# FIX-SCOPES — expectation

Contents: user scope holds `shared-name` + `user-only` (global v3 lock);
project root `proj/` holds `shared-name` + `proj-only` (project v1 lock whose
computedHash values match disk). Everything is vercel-owned and consistent:
ZERO findings — scope separation is the only signal.

Scan with SUKIRU_HOME=<this>/.home SUKIRU_ROOTS=<this>/proj.

A correct scan MUST exit 0, report the user-scope skills under the `user`
workspace and the project-scope skills under `project:<root>` workspaces, and
show `shared-name` ONCE PER SCOPE (per-scope ownership resolution, never
merged, never ambiguous — ambiguity is judged per scope). The app Library
MUST render a `sukiru.library.section.user` section and a distinct
`sukiru.library.section.project.*` section, each skill under its true scope.
EOF

# =====================================================================
# FIX-SCOPES-CROSS — multi-workspace ownership/findings split: the SAME
# skill name in both scopes with DIFFERENT
# ownership (vercel in user scope, ownerless in project scope) and findings
# in BOTH scopes. This is the committed counterpart of a scenario manual
# testing once had to hand-edit onto a FIX-SCOPES copy; committed
# FIX-SCOPES stays the all-vercel/zero-findings tree.
# =====================================================================
d="$(reset_pw_fixture FIX-SCOPES-CROSS)"
skill "$d/.home/.agents/skills/shared-tool" "shared-tool" "The user-scope copy of the shared name."
skill "$d/.home/.agents/skills/user-orphan" "user-orphan" "Ownerless user-scope skill (files-without-lock)."
skill "$d/proj/.agents/skills/shared-tool" "shared-tool" "The project-scope copy of the shared name."
skill "$d/proj/.agents/skills/proj-locked" "proj-locked" "Vercel-owned project-scope skill."
proj_locked_hash="$(skill_md_hash "$d/proj/.agents/skills/proj-locked")"
cat >"$d/.home/.agents/.skill-lock.json" <<'EOF'
{
  "version": 3,
  "skills": {
    "shared-tool": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "skillPath": ".agents/skills/shared-tool/SKILL.md",
      "skillFolderHash": "a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7",
      "installedAt": "2026-06-15T23:27:24.742Z",
      "updatedAt": "2026-06-15T23:27:24.742Z"
    }
  },
  "dismissed": {}
}
EOF
cat >"$d/proj/skills-lock.json" <<EOF
{
  "version": 1,
  "skills": {
    "proj-locked": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "skillPath": ".agents/skills/proj-locked/SKILL.md",
      "computedHash": "$proj_locked_hash"
    }
  }
}
EOF
note "$d" <<'EOF'
# FIX-SCOPES-CROSS — expectation

Contents: the name `shared-tool` exists in BOTH scopes with DIFFERENT
ownership — user scope (`.home/.agents/skills/shared-tool`) is vercel-owned
via the global v3 lock; project scope (`proj/.agents/skills/shared-tool`) is
OWNERLESS (no project lock entry, no gh provenance). Each scope also carries
its own second skill: `user-orphan` (ownerless, user scope) and `proj-locked`
(vercel-owned, project v1 lock whose computedHash matches disk).

Scan with SUKIRU_HOME=<this>/.home SUKIRU_ROOTS=<this>/proj.

A correct scan MUST exit 0 and:
- resolve `shared-tool` ownership INDEPENDENTLY per scope: vercel in user
  scope (global lock), ownerless in project scope (no ledger bleed);
- report findings in BOTH scopes: `files-without-lock` for `user-orphan`
  (user) and for `shared-tool` (project), plus the ownerless
  `dangerous-removal-surface` advisories for those two names;
- emit NO findings for `shared-tool` in user scope or `proj-locked`.

The cross-scope isolation test drives a repair batch against the
PROJECT-scope ownerless `shared-tool` (direct file-op cleanup): the user scope's lock file,
placements, and findings MUST stay byte-identical, and the snapshot manifest
records only project-scope paths (plus the project lock probes).
EOF

# =====================================================================
# FIX-ADOPT — one ownerless skill whose name MATCHES the real upstream
# test repo's skill (thedavidweng/skills: maintenance/stale-docs-cleanup),
# so the adopt shape (`gh skill install <repo> <path>
# --force --dir <parent>`) re-anchors provenance onto THIS directory
# instead of creating a differently-named sibling (probe-verified gh
# semantics: --dir is the skills ROOT; the installed dir name comes from
# the repo skill). This is the adopt end-to-end pre-state. It lives in the
# PROJECT scope: probe-verified, gh install writes a vercel global lock
# entry for USER-scope installs (→ double-booked), while project-scope
# installs leave every vercel ledger untouched → clean github ownership.
# =====================================================================
d="$(reset_pw_fixture FIX-ADOPT)"
skill "$d/proj/.agents/skills/stale-docs-cleanup" "stale-docs-cleanup" "Local un-owned copy of the upstream stale-docs-cleanup skill."
: >"$d/.home/.gitkeep"
note "$d" <<'EOF'
# FIX-ADOPT — expectation

Contents: a two-part tree (`.home` + `proj`, scan with
SUKIRU_HOME=<this>/.home SUKIRU_ROOTS=<this>/proj) whose project scope
holds exactly one skill, `.agents/skills/stale-docs-cleanup`, with NO
project lock entry and NO gh frontmatter provenance → ownerless.

A correct scan MUST exit 0 and report:
- skill `stale-docs-cleanup` in the PROJECT workspace with ownership
  `ownerless`;
- findings `files-without-lock` and `dangerous-removal-surface` for it;
- nothing else.

The name deliberately MATCHES the real upstream test skill
(thedavidweng/skills, path `maintenance/stale-docs-cleanup/SKILL.md`):
probe-verified `gh skill install <repo> <path> --force --dir <parent>`
treats `--dir` as the skills ROOT and installs into `<parent>/<repo skill
name>`, so adopt only re-anchors provenance onto an existing directory
when the names agree. The skill lives in PROJECT scope because gh install
pollutes the vercel GLOBAL lock on user-scope installs (→ instant
double-booked); project-scope installs stay github-only. After the adopt
batch executes (GH_TOKEN injected), a rescan MUST show ownership `github`
with frontmatter `github-repo`/`github-path`/`github-ref`/`github-tree-sha`
on disk and NO `files-without-lock` finding.
EOF

# =====================================================================
# FIX-MULTI-HOST — one canonical skill symlinked into THREE host global dirs,
# plus one bare-`skills` residue host dir.
# =====================================================================
d="$(reset_fixture FIX-MULTI-HOST)"
mkdir -p "$d/.claude" "$d/.codex" "$d/.cursor"
: >"$d/.claude/config.json"; : >"$d/.codex/config.json"; : >"$d/.cursor/config.json"
skill "$d/.agents/skills/web-api" "web-api" "One canonical skill aliased into three hosts."
mkdir -p "$d/.claude/skills" "$d/.codex/skills" "$d/.cursor/skills"
ln -s ../../.agents/skills/web-api "$d/.claude/skills/web-api"
ln -s ../../.agents/skills/web-api "$d/.codex/skills/web-api"
ln -s ../../.agents/skills/web-api "$d/.cursor/skills/web-api"
# CLI spray residue: `.qoder` contains ONLY a bare (empty) `skills/` entry —
# leftover, NOT installed (marks_installation tri-state).
mkdir -p "$d/.qoder/skills"
: >"$d/.qoder/skills/.gitkeep"
cat >"$d/.agents/.skill-lock.json" <<'EOF'
{
  "version": 3,
  "skills": {
    "web-api": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "skillPath": ".agents/skills/web-api/SKILL.md",
      "skillFolderHash": "e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5",
      "installedAt": "2026-06-15T23:27:24.742Z",
      "updatedAt": "2026-06-15T23:27:24.742Z"
    }
  },
  "dismissed": {}
}
EOF
note "$d" <<'EOF'
# FIX-MULTI-HOST — expectation

Contents: `web-api` lives in the canonical user store (`.agents/skills`,
global v3 lock, ownership=vercel) and is SYMLINKED into three host global
dirs — claude-code (`.claude/skills`), codex (`.codex/skills`), cursor
(`.cursor/skills`) — each host detected via a config.json marker. `.qoder/`
contains ONLY an empty `skills/` entry: CLI spray residue (leftover,
installed=false), which sees NO skills.

A correct scan MUST exit 0 and present `web-api` as ONE logical skill with 4
placements (1 canonical directory + 3 symlinks sharing one canonical path) —
never as four skills. The ONLY finding is the info-severity alias
cross-host-duplicate. The qoder workspace MUST be reported installed=false
(leftover) and must NOT count as a host that sees `web-api`; the app's
host-presence region lists exactly claude-code, codex, and cursor.
EOF

# =====================================================================
# FIX-DRIFT — project-scope vercel lock whose computedHash disagrees with disk.
# =====================================================================
d="$(reset_pw_fixture FIX-DRIFT)"
skill "$d/proj/.agents/skills/drifted" "drifted" "Original content, as installed."
stale_hash="$(skill_md_hash "$d/proj/.agents/skills/drifted")"
skill "$d/proj/.agents/skills/drifted" "drifted" "Edited out-of-band AFTER install; the lock hash is stale."
: >"$d/.home/.gitkeep"
cat >"$d/proj/skills-lock.json" <<EOF
{
  "version": 1,
  "skills": {
    "drifted": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "skillPath": ".agents/skills/drifted/SKILL.md",
      "computedHash": "$stale_hash"
    }
  }
}
EOF
note "$d" <<'EOF'
# FIX-DRIFT — expectation

Contents: project root `proj/` holds `drifted`, whose SKILL.md was edited
out-of-band after install — the v1 lock's computedHash (hash of the ORIGINAL
content) no longer matches disk. The fake home is empty.

Scan with SUKIRU_HOME=<this>/.home SUKIRU_ROOTS=<this>/proj.

A correct scan MUST exit 0, resolve `drifted` as ownership=vercel, and emit a
`vercel-lock-drift` finding (severity action) whose evidence names the lock
path, the entry key, the stored (expected) hash, and the recomputed (actual)
hash. The app Health surface MUST render that finding with an expandable
evidence block and a reveal-in-Library navigation action.
EOF

# =====================================================================
# FIX-DOUBLE-BOOKED — one name claimed by both the vercel lock and gh
# frontmatter provenance (spot-check tree).
# =====================================================================
d="$(reset_fixture FIX-DOUBLE-BOOKED)"
gh_skill "$d/.agents/skills/double-tool" "double-tool" "Claimed by both ledgers." \
    "https://github.com/thedavidweng/skills" "tools/double-tool/SKILL.md" \
    "refs/heads/main" "9999999988888888777777776666666655555555"
cat >"$d/.agents/.skill-lock.json" <<'EOF'
{
  "version": 3,
  "skills": {
    "double-tool": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "skillPath": ".agents/skills/double-tool/SKILL.md",
      "skillFolderHash": "abababababababababababababababababababab",
      "installedAt": "2026-06-15T23:27:24.742Z",
      "updatedAt": "2026-06-15T23:27:24.742Z"
    }
  },
  "dismissed": {}
}
EOF
note "$d" <<'EOF'
# FIX-DOUBLE-BOOKED — expectation

Contents: `double-tool` in the user-scope canonical store, present in the
global v3 lock AND carrying `metadata.github-repo` frontmatter — both ledgers
claim the same name.

A correct scan MUST exit 0, resolve ownership=double-booked, and emit a
`double-booked` finding (severity action) with two-sided evidence (lock path +
entry key; SKILL.md path + github-repo value). Library and Health MUST show
identical provenance for the skill.
EOF

# =====================================================================
# FIX-SYMLINK — one dangling symlink + one double-copied impostor
# (coverage tree for the symlink rules).
# =====================================================================
d="$(reset_fixture FIX-SYMLINK)"
mkdir -p "$d/.claude/skills"; : >"$d/.claude/config.json"
# dangling symlink
ln -s /nonexistent/rotted-target "$d/.claude/skills/rotted"
# impostor: canonical store + lock claim, but the host path is a physical copy
skill "$d/.agents/skills/tool" "tool" "Canonical copy in the managed store."
skill "$d/.claude/skills/tool" "tool" "Canonical copy in the managed store."
cat >"$d/.agents/.skill-lock.json" <<'EOF'
{
  "version": 3,
  "skills": {
    "tool": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "skillPath": ".agents/skills/tool/SKILL.md",
      "skillFolderHash": "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd",
      "installedAt": "2026-06-15T23:27:24.742Z",
      "updatedAt": "2026-06-15T23:27:24.742Z"
    }
  },
  "dismissed": {}
}
EOF
note "$d" <<'EOF'
# FIX-SYMLINK — expectation

Contents: in the claude-code host dir (detected via config.json), a DANGLING
symlink `.claude/skills/rotted -> /nonexistent/rotted-target`; plus `tool` in
the canonical store (global v3 lock) with a PHYSICAL copy at
`.claude/skills/tool` where the managed layout implies a symlink — a
double-copied impostor.

A correct scan MUST exit 0 and report:
- a brokenSymlink placement `rotted` (null canonical path/hash) AND a
  `broken-symlink` finding (severity action) naming the link path and its
  unreadable target — the link also surfaces as a `broken-symlink` ISSUE (no
  `dangerous-removal-surface` advisory: `npx skills remove` cannot match a
  link without SKILL.md);
- a `symlink-authenticity` finding (severity warning) naming the impostor path
  (`.claude/skills/tool`) and the canonical path it should link to;
- an exact-subtype `cross-host-duplicate` (warning) for the two identical
  physical copies of `tool`;
- `tool` stays ownership=vercel (the lock claim is intact).
EOF

# =====================================================================
# FIX-HOST-DIVERGENCE — one name, same lock source identity, distinct hashes
# across canonical store and a host copy.
# =====================================================================
d="$(reset_pw_fixture FIX-HOST-DIVERGENCE)"
skill "$d/proj/.agents/skills/web-tool" "web-tool" "Canonical copy, untouched since install."
skill "$d/proj/.claude/skills/web-tool" "web-tool" "Canonical copy, untouched since install."
skill "$d/proj/.claude/skills/web-tool" "web-tool" "Overwritten out-of-band; content now diverges."
canon_hash="$(skill_md_hash "$d/proj/.agents/skills/web-tool")"
: >"$d/.home/.gitkeep"
cat >"$d/proj/skills-lock.json" <<EOF
{
  "version": 1,
  "skills": {
    "web-tool": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "skillPath": ".agents/skills/web-tool/SKILL.md",
      "computedHash": "$canon_hash"
    }
  }
}
EOF
note "$d" <<'EOF'
# FIX-HOST-DIVERGENCE — expectation

Contents: a copy-mode install in `proj/` — canonical `.agents/skills/web-tool`
plus host copy `.claude/skills/web-tool` under ONE v1 lock source identity.
The host copy was overwritten out-of-band, so the two placements hash
differently; the lock computedHash still matches the CANONICAL copy.

Scan with SUKIRU_HOME=<this>/.home SUKIRU_ROOTS=<this>/proj.

A correct scan MUST exit 0 and emit a `canonical-host-divergence` finding
(severity action) naming both placement paths, the shared source identity,
and BOTH content hashes. The drifted host copy also legitimately raises
`vercel-lock-drift` (its hash no longer matches the lock) and the pair is a
divergent cross-host duplicate; `web-tool` stays ownership=vercel,
ambiguous=false (the lock hash explains the canonical placement).
EOF

# =====================================================================
# FIX-DIRTY-SUITE — combined dirty tree with findings in BOTH scopes and at
# least two severity levels.
# =====================================================================
d="$(reset_pw_fixture FIX-DIRTY-SUITE)"
mkdir -p "$d/.home/.claude/skills"; : >"$d/.home/.claude/config.json"
# CLI spray residue: `.qoder` contains ONLY a bare (empty) `skills/` entry —
# a leftover (installed=false) workspace with ZERO findings, so the Health
# workspace filter has a reachable empty-filter state.
# (git cannot track the empty dir; `reset_pw_fixture` rebuilds it, and the
# committed tree keeps it via the same convention as FIX-MULTI-HOST.)
mkdir -p "$d/.home/.qoder/skills"
: >"$d/.home/.qoder/skills/.gitkeep"
# user scope: dangling symlink (action) + gh-owned skill (danger advisory,
# action) + ownerless skill (files-without-lock, info)
ln -s /nonexistent/rotted-target "$d/.home/.claude/skills/rotted-link"
gh_skill "$d/.home/.claude/skills/gh-owned" "gh-owned" "GitHub-owned user-scope skill." \
    "https://github.com/thedavidweng/skills" "tools/gh-owned/SKILL.md" \
    "refs/heads/main" "1212121234343434565656567878787890909090"
skill "$d/.home/.agents/skills/user-orphan" "user-orphan" "Ownerless user-scope skill."
# project scope: drifted vercel skill (action) + ownerless skill (info)
skill "$d/proj/.agents/skills/drifted" "drifted" "Original content, as installed."
dirty_stale_hash="$(skill_md_hash "$d/proj/.agents/skills/drifted")"
skill "$d/proj/.agents/skills/drifted" "drifted" "Edited out-of-band; project lock hash is stale."
skill "$d/proj/.agents/skills/proj-orphan" "proj-orphan" "Ownerless project-scope skill."
cat >"$d/proj/skills-lock.json" <<EOF
{
  "version": 1,
  "skills": {
    "drifted": {
      "source": "thedavidweng/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/thedavidweng/skills.git",
      "skillPath": ".agents/skills/drifted/SKILL.md",
      "computedHash": "$dirty_stale_hash"
    }
  }
}
EOF
note "$d" <<'EOF'
# FIX-DIRTY-SUITE — expectation

One tree triggering several rules at once, with findings in BOTH scopes:

- user scope (`.home`, claude-code detected via config.json):
  `rotted-link` dangling symlink -> `broken-symlink` (action);
  `gh-owned` github-provenanced -> `dangerous-removal-surface` (action);
  `user-orphan` no ledger -> `files-without-lock` (info).
- project scope (`proj`):
  `drifted` edited after install -> `vercel-lock-drift` (action);
  `proj-orphan` no ledger -> `files-without-lock` (info).
- `.qoder/` contains ONLY an empty `skills/` entry: CLI spray residue, a
  leftover workspace (installed=false) with ZERO placements and ZERO
  findings — the Health workspace filter's reachable empty state.

Scan with SUKIRU_HOME=<this>/.home SUKIRU_ROOTS=<this>/proj.

A correct scan MUST exit 0 with exactly these SEVEN findings: the five above
PLUS a `dangerous-removal-surface` advisory for each ownerless name
(`user-orphan`, `proj-orphan`) — the advisory fires on gh-owned AND
ownerless skills, but not on `rotted-link`: a dangling link holds no
SKILL.md, so `npx skills remove` cannot match it. Two severity levels render (action + info);
the dangling link additionally surfaces as a `broken-symlink` ISSUE. Each
finding carries its rule's concrete evidence. Ownership: gh-owned=github,
drifted=vercel, the two orphans and rotted-link=ownerless. The app drives
its grouped-findings, severity-display, per-workspace filter,
keyboard-disclosure, and selection-persistence assertions off this tree.
EOF

# =====================================================================
# FIX-MUTABLE — clean tree the validator mutates on disk mid-session
# (no file watchers; the app relies on explicit Refresh). Same zero-findings
# shape as FIX-CLEAN; kept separate so mutation flows never touch FIX-CLEAN.
# =====================================================================
d="$(reset_fixture FIX-MUTABLE)"
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
      "skillFolderHash": "efefefefefefefefefefefefefefefefefefefef",
      "installedAt": "2026-06-15T23:27:24.742Z",
      "updatedAt": "2026-06-15T23:27:24.742Z"
    }
  },
  "dismissed": {}
}
EOF
note "$d" <<'EOF'
# FIX-MUTABLE — expectation

Contents: one vercel-owned user-scope skill `greet` (global v3 lock) — a
zero-findings clean tree. Validators COPY this tree, launch the app against
the copy, mutate the copy on disk mid-session (add/remove a skill), and
assert: nothing changes without explicit Refresh (no watchers); after
Refresh (Settings control or keyboard shortcut) the new disk state renders.

A correct scan of the UNMUTATED tree MUST exit 0 with exactly one skill,
ownership=vercel, zero findings, zero issues.
EOF

# =====================================================================
# cap-* — PATH-stub capability environments.
#
# These are NOT scan fixtures: each tree holds ONLY a bin/ of stub executables
# plus its EXPECTATION.md. Validators compose an environment by concatenating
# bin dirs onto PATH, e.g.
#   PATH="<FIX>/cap-gh-ok/bin:<FIX>/cap-npx-ok/bin:/usr/bin:/bin"
# Every stub is a POSIX sh script: controlled output, no network, no side
# effects. When SUKIRU_STUB_TRANSCRIPT is set, a stub appends one
# "<name> <args>" line per invocation to that file — the validator's evidence
# that the real binary really probed the stub.
# =====================================================================

# gh_stub DIR VERSION PROBE_EXIT -> bin/gh reporting VERSION on --version;
# `gh skill --help` exits PROBE_EXIT (0 = the skill surface works).
gh_stub() {
    local dir="$1" version="$2" probe_exit="$3"
    mkdir -p "$dir/bin"
    cat >"$dir/bin/gh" <<'EOF'
#!/bin/sh
# gh PATH stub: `gh --version` reports @VERSION@; `gh skill --help` exits
# @PROBE_EXIT@. Everything else exits 1. No network, no side effects.
if [ -n "${SUKIRU_STUB_TRANSCRIPT:-}" ]; then
    printf 'gh %s\n' "$*" >>"$SUKIRU_STUB_TRANSCRIPT"
fi
if [ "${1:-}" = "--version" ]; then
    echo "gh version @VERSION@ (2026-01-15)"
    exit 0
fi
if [ "${1:-}" = "skill" ] && [ "${2:-}" = "--help" ]; then
    echo "Work with agent skills"
    exit @PROBE_EXIT@
fi
exit 1
EOF
    sed -i '' -e "s/@VERSION@/$version/g" -e "s/@PROBE_EXIT@/$probe_exit/g" "$dir/bin/gh"
    chmod 755 "$dir/bin/gh"
}

# npx_stub DIR VERSION -> bin/npx answering ONLY the capability probe
# (`npx --offline skills --version`) with VERSION; no network.
npx_stub() {
    local dir="$1" version="$2"
    mkdir -p "$dir/bin"
    cat >"$dir/bin/npx" <<'EOF'
#!/bin/sh
# npx PATH stub: answers the skills capability probe with @VERSION@.
# Everything else exits 1. No network, no side effects.
if [ -n "${SUKIRU_STUB_TRANSCRIPT:-}" ]; then
    printf 'npx %s\n' "$*" >>"$SUKIRU_STUB_TRANSCRIPT"
fi
case "$*" in
    *--offline*skills*--version*)
        echo "@VERSION@"
        exit 0
        ;;
esac
exit 1
EOF
    sed -i '' -e "s/@VERSION@/$version/g" "$dir/bin/npx"
    chmod 755 "$dir/bin/npx"
}

# empty_bin DIR -> a bin/ holding nothing but a .gitkeep (git drops empty
# dirs): the "tool absent from PATH" environment.
empty_bin() {
    mkdir -p "$1/bin"
    : >"$1/bin/.gitkeep"
}

d="$(reset_fixture cap-gh-ok)"
gh_stub "$d" "2.100.0" 0
note "$d" <<'EOF'
# cap-gh-ok — expectation

Contents: `bin/gh` — a stub reporting `gh version 2.100.0 (2026-01-15)` whose
`gh skill --help` exits 0. No npx stub here (compose with `cap-npx-ok`).

Use: `PATH="<this>/bin[:<cap-npx-ok>/bin]:/usr/bin:/bin" sukiru-cli capabilities --format json`.

A correct capabilities report MUST exit 0 and report gh available=true,
present=true, meetsMinimum=true, version="2.100.0", with NO `reason` key.
With SUKIRU_STUB_TRANSCRIPT=<file> set, the transcript MUST record both
`gh --version` and `gh skill --help` invocations.
EOF

d="$(reset_fixture cap-gh-old)"
gh_stub "$d" "2.80.0" 1
note "$d" <<'EOF'
# cap-gh-old — expectation

Contents: `bin/gh` — a stub reporting `gh version 2.80.0 (2026-01-15)`, BELOW
the 2.90.0 `gh skill` floor (its `skill --help` exits 1, but a correct
detector never probes a below-minimum gh). The date string comes from the
shared `gh_stub` heredoc in Scripts/fixtures/build-handbuilt.sh (the
generator is the source of truth); version parsing reads only the number.

Use: `PATH="<this>/bin:/usr/bin:/bin" sukiru-cli capabilities --format json`.

A correct capabilities report MUST exit 0 and report gh available=false,
present=true, version="2.80.0", meetsMinimum=false, reason="too-old". Scans
in this environment MUST be unaffected: `sukiru-cli scan` over the
`own-github` fixture still exits 0 and surfaces `metadata.github-*`
provenance from disk.
EOF

d="$(reset_fixture cap-gh-probe-fail)"
gh_stub "$d" "2.100.0" 1
note "$d" <<'EOF'
# cap-gh-probe-fail — expectation

Contents: `bin/gh` — a stub reporting `gh version 2.100.0 (2026-01-15)`
(meets the 2.90.0 floor) whose `gh skill --help` EXITS 1: the version is new
enough but the skill surface does not work (the `gh skill --help` probe).

Use: `PATH="<this>/bin:/usr/bin:/bin" sukiru-cli capabilities --format json`.

A correct capabilities report MUST exit 0 and report gh available=false,
present=true, version="2.100.0", meetsMinimum=true, reason="probe-failed".
(This tree is the probe-failure environment exercised by
`CapabilitiesFixtureTests`.)
EOF

d="$(reset_fixture cap-gh-absent)"
empty_bin "$d"
note "$d" <<'EOF'
# cap-gh-absent — expectation

Contents: an EMPTY `bin/` (only a .gitkeep) — no gh on PATH. Compose with
other cap-* bins as needed (e.g. `<this>/bin:<cap-npx-ok>/bin` for
"gh absent, npx fine").

Use: `PATH="<this>/bin:/usr/bin:/bin" sukiru-cli capabilities --format json`.

A correct capabilities report MUST exit 0 and report gh available=false,
present=false, meetsMinimum=false, no version, reason="absent". Scans in
this environment MUST be unaffected: `sukiru-cli scan` over the
`own-github` fixture still exits 0 and surfaces `metadata.github-*`
provenance from disk.
EOF

d="$(reset_fixture cap-npx-ok)"
npx_stub "$d" "1.5.26"
note "$d" <<'EOF'
# cap-npx-ok — expectation

Contents: `bin/npx` — a stub answering the capability probe
(`npx --offline skills --version`) with `1.5.26`. No gh stub here (compose
with `cap-gh-ok`).

Use: `PATH="<this>/bin[:<cap-gh-ok>/bin]:/usr/bin:/bin" sukiru-cli capabilities --format json`.

A correct capabilities report MUST exit 0 and report npx resolvable=true,
skillsVersion="1.5.26".
EOF

d="$(reset_fixture cap-npx-absent)"
empty_bin "$d"
note "$d" <<'EOF'
# cap-npx-absent — expectation

Contents: an EMPTY `bin/` (only a .gitkeep) — no npx on PATH.

Use: `PATH="<this>/bin:/usr/bin:/bin" sukiru-cli capabilities --format json`.

A correct capabilities report MUST exit 0 and report npx resolvable=false
with no skillsVersion. Unresolvable npx NEVER blocks anything: exit stays 0
and scans are unaffected.
EOF

d="$(reset_fixture cap-neither)"
empty_bin "$d"
note "$d" <<'EOF'
# cap-neither — expectation

Contents: an EMPTY `bin/` (only a .gitkeep) — neither gh nor npx on PATH.
Sukiru degrades to the full read-only diagnostician: capability absence
degrades repair features, never scanning.

Use: `PATH="<this>/bin:/usr/bin:/bin" sukiru-cli {capabilities,scan} ...`.

A correct capabilities report MUST exit 0 with gh reason="absent" and npx
resolvable=false. A scan over a rich fixture (CM-3) in this environment MUST
produce the COMPLETE report — full inventory, ownership from both on-disk
ledgers, all findings — BYTE-IDENTICAL to the same fixture scanned under
`cap-gh-ok` + `cap-npx-ok` (scan is subprocess-free).
EOF

echo "Hand-built fixtures rebuilt under: $FIX"
