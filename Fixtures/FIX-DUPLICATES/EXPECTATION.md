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

Scan MUST exit 0. Under the D23 refined ambiguity trigger, no ledger claims
any name here, so every copy is UNEXPLAINED: div-demo's unexplained copies
hold 2 distinct content hashes and DO raise `ambiguous-name`
(ownership=ownerless, attribution voided), while exact-demo's copies share ONE
hash and are NOT ambiguous (plain ownerless, listed via `files-without-lock`).
alias-demo is never ambiguous.
