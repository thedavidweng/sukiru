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
