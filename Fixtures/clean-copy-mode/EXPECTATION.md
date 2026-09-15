# clean-copy-mode — expectation (VAL-SCAN-001 tree; D3 caveat)

Contents: the stock `npx skills add --copy` layout in `proj/` — canonical
`.agents/skills/web-tool` plus a byte-identical physical copy at
`.claude/skills/web-tool`, with a v1 project lock whose computedHash matches
disk.

Scan with SUKIRU_HOME=<this>/.home, SUKIRU_ROOTS=<this>/proj.

A correct scan MUST exit 0 with valid JSON (this is the VAL-SCAN-001
well-formed tree), show ownership=vercel, surface the lock provenance fields,
and emit the warning-level exact-subtype cross-host-duplicate finding that a
stock copy-mode layout legitimately produces (per D3 it is therefore NOT the
zero-findings baseline — that is FIX-CLEAN). NO drift, NO double-booked, NO
files-without-lock findings.
