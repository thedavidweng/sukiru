# skillmd-invalid-a — missing `name`

The `bad` skill's frontmatter has no `name` key. A correct scan MUST exit 0,
emit a `skill-md-invalid` issue for `.agents/skills/bad/SKILL.md` (missing name),
create NO placement for `bad`, and still inventory the healthy sibling.
