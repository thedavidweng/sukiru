# own-vercel — expectation (VAL-SCAN-015 / VAL-SCAN-019)

Contents: two skills with lock entries and NO github frontmatter.
`global-tool` (user scope, global v3 lock) and `proj-tool` (project scope,
project v1 lock whose computedHash matches disk).

Scan with SUKIRU_HOME=<this>/.home, SUKIRU_ROOTS=<this>/proj.

A correct scan MUST:
- exit 0 and resolve ownership=vercel for BOTH skills;
- surface per entry: source, sourceType, sourceUrl, ref, skillPath, and the
  stored hash — mechanically, the PROJECT entry exposes `computedHash` and MUST
  NOT expose `skillFolderHash`, the GLOBAL entry exposes `skillFolderHash` and
  MUST NOT expose `computedHash`; all values byte-equal to the fixture locks;
- emit NO vercel-lock-drift (the project entry matches disk) and NO
  double-booked / files-without-lock findings.
