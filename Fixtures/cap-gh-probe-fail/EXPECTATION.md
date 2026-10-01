# cap-gh-probe-fail — expectation

Contents: `bin/gh` — a stub reporting `gh version 2.100.0 (2026-01-15)`
(meets the 2.90.0 floor) whose `gh skill --help` EXITS 1: the version is new
enough but the skill surface does not work (the `gh skill --help` probe).

Use: `PATH="<this>/bin:/usr/bin:/bin" sukiru-cli capabilities --format json`.

A correct capabilities report MUST exit 0 and report gh available=false,
present=true, version="2.100.0", meetsMinimum=true, reason="probe-failed".
(This tree is the probe-failure environment exercised by
`CapabilitiesFixtureTests`.)
