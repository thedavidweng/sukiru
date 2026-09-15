# FIX-FILES-NO-LOCK — expectation

Contents: `.agents/skills/orphan` with NO lock file and NO github provenance.

A correct scan MUST exit 0, resolve ownership=ownerless for `orphan`, and emit a
`files-without-lock` finding (info severity) naming the placement path.
