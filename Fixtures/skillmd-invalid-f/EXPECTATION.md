# skillmd-invalid-f — YAML syntax error

The frontmatter contains an unterminated flow sequence. A correct scan MUST
exit 0, emit a `skill-md-invalid` issue (YAML parse error), create NO placement
for `bad`, and still inventory the healthy sibling.
