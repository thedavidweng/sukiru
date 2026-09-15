# skillmd-invalid-d — no start delimiter

The file does not begin with `---` at byte 0 (strict start delimiter). A correct
scan MUST exit 0, emit a `skill-md-invalid` issue (missing/late start delimiter),
create NO placement for `bad`, and still inventory the healthy sibling.
