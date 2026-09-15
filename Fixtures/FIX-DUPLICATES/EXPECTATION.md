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
