# prov-cross-ws — expectation (VAL-SCAN-021)

Contents: the same logical skill `shared` installed by gh into TWO workspaces —
the user-scope claude-code host dir (`.home/.claude/skills/shared`) and a
project-scope claude-code dir (`proj/.claude/skills/shared`). Both copies carry
BYTE-IDENTICAL frontmatter, hence identical github provenance (repo, path,
ref=refs/heads/main, tree-sha, pinned=true). No lock files anywhere.

Scan with SUKIRU_HOME=<this>/.home, SUKIRU_ROOTS=<this>/proj.

A correct scan MUST exit 0 and report the github provenance of `shared`
BYTE-EQUAL in every workspace context in which the skill appears. (One
placement per scope, so no ambiguity; gh-owned, so a
dangerous-removal-surface advisory per workspace is expected.)
