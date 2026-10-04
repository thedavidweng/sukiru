# cap-gh-absent — expectation

Contents: an EMPTY `bin/` (only a .gitkeep) — no gh on PATH. Compose with
other cap-* bins as needed (e.g. `<this>/bin:<cap-npx-ok>/bin` for
"gh absent, npx fine").

Use: `PATH="<this>/bin:/usr/bin:/bin" sukiru capabilities --json`.

A correct capabilities report MUST exit 0 and report gh available=false,
present=false, meetsMinimum=false, no version, reason="absent". Scans in
this environment MUST be unaffected: `sukiru scan` over the
`own-github` fixture still exits 0 and surfaces `metadata.github-*`
provenance from disk.
