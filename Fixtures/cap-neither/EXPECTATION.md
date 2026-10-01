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
