# skillmd-invalid-e — UTF-8 BOM before `---`

A 3-byte UTF-8 BOM (EF BB BF) precedes the `---`, so the delimiter is not at
byte 0 (no BOM tolerance). A correct scan MUST exit 0, emit a `skill-md-invalid`
issue (BOM / delimiter not at byte 0), create NO placement for `bad`, and still
inventory the healthy sibling.
