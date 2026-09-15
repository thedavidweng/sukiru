# skillmd-early-close — early frontmatter close (upstream parity)

The multi-line `description` block is followed by a line beginning `---`, which
upstream's "first `\n---` closes the frontmatter" rule treats as the closing
delimiter. That truncates the frontmatter BEFORE the `name:` line, orphaning the
required field. A correct scan MUST reproduce upstream behavior (do NOT hunt for
the real closing delimiter): parse the truncated frontmatter and emit a
`skill-md-invalid` issue for missing `name`. Exit 0; healthy sibling inventoried.
