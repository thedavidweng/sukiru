# own-github — expectation (VAL-SCAN-015 / VAL-SCAN-020)

Contents: two gh-owned skills in the claude-code host dir (detected via
config.json), NO lock file anywhere. `pinned-tool` carries
`metadata.github-pinned: true` and a repo URL stored WITH its `.git` suffix;
`unpinned-tool` OMITS the `github-pinned` key entirely.

A correct scan MUST:
- exit 0 and resolve ownership=github for both;
- surface per placement: github-repo (the stored value preserved as-is,
  including the `.git` suffix on pinned-tool), github-path, github-ref (the
  FULL ref `refs/heads/main`, never truncated to a bare branch name), and
  github-tree-sha;
- report pinned-tool as pinned and unpinned-tool as unpinned (an ABSENT
  github-pinned key means unpinned, never pinned);
- emit NO files-without-lock (gh provenance satisfies the ledger requirement)
  and NO vercel findings; a `dangerous-removal-surface` advisory per gh-owned
  skill is expected (VAL-SCAN-030).
