# leftover-dsstore — expectation

Contents: `~/.qoder/` containing only `skills/`, `.DS_Store`, and
`.localized` — CLI spray residue plus macOS Finder noise.

A correct scan MUST (VAL-SCAN-013): classify the host as leftover
(`installed: false`), exactly as in VAL-SCAN-012. `.DS_Store` and
`.localized` never count as installation content, so a Finder visit cannot
flip a leftover into a false positive.
