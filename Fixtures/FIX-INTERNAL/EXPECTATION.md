# FIX-INTERNAL — expectation

Contents: two vercel-owned user-scope skills. `hidden-helper` carries
`metadata.internal: true`; `normal` does not.

A correct scan MUST:
- exit 0;
- inventory BOTH placements (internal skills are inventoried, never dropped);
- flag the `hidden-helper` placement `internal: true` and `normal` `internal: false`.

The app additionally hides internal skills from host-facing listings while
still surfacing the internal marker; for the scan engine the requirement
is only that both placements appear with correct internal flags.
