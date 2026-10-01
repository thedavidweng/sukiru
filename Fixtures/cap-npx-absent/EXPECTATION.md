# cap-npx-absent — expectation

Contents: an EMPTY `bin/` (only a .gitkeep) — no npx on PATH.

Use: `PATH="<this>/bin:/usr/bin:/bin" sukiru-cli capabilities --format json`.

A correct capabilities report MUST exit 0 and report npx resolvable=false
with no skillsVersion. Unresolvable npx NEVER blocks anything: exit stays 0
and scans are unaffected.
