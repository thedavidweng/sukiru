# FIX-DOUBLE-BOOKED — expectation (M3 health-area, VAL-HEALTH-037)

Contents: `double-tool` in the user-scope canonical store, present in the
global v3 lock AND carrying `metadata.github-repo` frontmatter — both ledgers
claim the same name.

A correct scan MUST exit 0, resolve ownership=double-booked, and emit a
`double-booked` finding (severity action) with two-sided evidence (lock path +
entry key; SKILL.md path + github-repo value). Library and Health MUST show
identical provenance for the skill (VAL-HEALTH-037).
