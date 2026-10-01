# lock-version-old — expectation

Contents: `proj/skills-lock.json` has `version: 0`, BELOW the supported
project-lock v1, with an entry claiming the on-disk `old-tool`.

Scan with SUKIRU_HOME=<this>/.home, SUKIRU_ROOTS=<this>/proj.

A correct scan MUST exit 0, report an incompatible-lock issue (found version 0,
supported 1), and NOT use the stale entries: `old-tool` resolves ownership from
disk/frontmatter alone (ownerless here, so a `files-without-lock` finding is
expected). Silent acceptance of the old lock is a fail.
