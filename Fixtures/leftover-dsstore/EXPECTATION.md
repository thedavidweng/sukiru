# leftover-dsstore — expectation

Contents: `~/.qoder/` containing only `skills/`, `.DS_Store`, and
`.localized` — CLI spray residue plus macOS Finder noise.

A correct scan MUST: classify the host as leftover
(`installed: false`), exactly as in `leftover-spray`. `.DS_Store` and
`.localized` never count as installation content, so a Finder visit cannot
flip a leftover into a false positive.
