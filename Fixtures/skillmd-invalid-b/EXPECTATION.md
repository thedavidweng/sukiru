# skillmd-invalid-b — blank `description`

The `bad` skill has an empty `description`. A correct scan MUST exit 0, emit a
`skill-md-invalid` issue (blank/missing description), create NO placement for
`bad`, and still inventory the healthy sibling.
