# cap-gh-ok — expectation (VAL-SCAN-002 / VAL-SCAN-037)

Contents: `bin/gh` — a stub reporting `gh version 2.100.0 (2026-01-15)` whose
`gh skill --help` exits 0. No npx stub here (compose with `cap-npx-ok`).

Use: `PATH="<this>/bin[:<cap-npx-ok>/bin]:/usr/bin:/bin" sukiru-cli capabilities --format json`.

A correct capabilities report MUST exit 0 and report gh available=true,
present=true, meetsMinimum=true, version="2.100.0", with NO `reason` key.
With SUKIRU_STUB_TRANSCRIPT=<file> set, the transcript MUST record both
`gh --version` and `gh skill --help` invocations.
