# own-per-project — expectation

Contents: the name `shared` in TWO project roots — locked by the project v1
lock in `p1` (whose computedHash matches disk), present as a bare placement
with NO lock and NO gh provenance in `p2`. The fake home is empty.

Scan with SUKIRU_HOME=<this>/.home SUKIRU_ROOTS=<this>/p1:<this>/p2.

A correct scan MUST exit 0 and, in ONE report, resolve ownership=vercel for
`shared` in p1 AND ownership=ownerless for `shared` in p2 with a
files-without-lock finding anchored to p2's workspace only. Any cross-root
ledger bleed (the p1 lock claiming p2's placement) is a fail.
