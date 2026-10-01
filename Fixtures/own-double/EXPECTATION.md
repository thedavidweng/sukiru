# own-double — expectation

Contents: `double-tool` is present in the global v3 lock AND carries
`metadata.github-repo` frontmatter — both ledgers claim the same name.

A correct scan MUST exit 0, resolve ownership=double-booked, and emit a
`double-booked` finding whose evidence references BOTH sides: the lock (lock
path + entry key) and the frontmatter provenance (SKILL.md path + github-repo
value). One-sided evidence or single-ledger ownership is a fail.
