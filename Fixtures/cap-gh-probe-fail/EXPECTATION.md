# cap-gh-probe-fail — expectation (VAL-SCAN-057)

Contents: `bin/gh` — a stub reporting `gh version 2.100.0 (2026-01-15)`
(meets the 2.90.0 floor) whose `gh skill --help` EXITS 1: the version is new
enough but the skill surface does not work (D6 probe).

Use: `PATH="<this>/bin:/usr/bin:/bin" sukiru-cli capabilities --format json`.

A correct capabilities report MUST exit 0 and report gh available=false,
present=true, version="2.100.0", meetsMinimum=true, reason="probe-failed".
(This tree is not in the contract's six-name legend; it is the VAL-SCAN-057
environment, named here for validators.)
