# FIX-LOCK-NO-FILES — expectation

Contents: a global lock claiming `ghost`, but no `ghost` directory on disk.

A correct scan MUST exit 0, emit a `lock-without-files` finding naming the lock
path and entry key `ghost`, and MUST NOT list `ghost` as a healthy placement
(a ledger claim alone conjures no skill).
