# lock-drift — expectation (VAL-SCAN-027)

Contents: project scope (`proj/`) holds `drifted`, whose SKILL.md was edited
out-of-band AFTER the v1 lock entry was written — the lock's computedHash is
the hash of the ORIGINAL content, so it no longer matches disk. User scope
holds `global-ctl` under a global v3 lock whose skillFolderHash (a git tree
SHA) also disagrees with disk — but global hashes are never recomputed, so
that disagreement is by-design silent.

Scan with SUKIRU_HOME=<this>/.home, SUKIRU_ROOTS=<this>/proj.

A correct scan MUST exit 0 and emit a `vercel-lock-drift` finding for
`drifted` whose evidence names the lock path, the entry key, the stored
(expected) hash, and the recomputed (actual) hash. It MUST emit ZERO drift
findings for the global-scope entry.
