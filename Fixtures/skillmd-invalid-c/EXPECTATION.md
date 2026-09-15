# skillmd-invalid-c — frontmatter is not a mapping

The frontmatter parses as a YAML sequence, not a mapping. A correct scan MUST
exit 0, emit a `skill-md-invalid` issue (not a mapping), create NO placement for
`bad`, and still inventory the healthy sibling.
