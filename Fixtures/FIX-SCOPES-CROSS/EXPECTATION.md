# FIX-SCOPES-CROSS — expectation (VAL-CROSS-017 / VAL-CROSS-018)

Contents: the name `shared-tool` exists in BOTH scopes with DIFFERENT
ownership — user scope (`.home/.agents/skills/shared-tool`) is vercel-owned
via the global v3 lock; project scope (`proj/.agents/skills/shared-tool`) is
OWNERLESS (no project lock entry, no gh provenance). Each scope also carries
its own second skill: `user-orphan` (ownerless, user scope) and `proj-locked`
(vercel-owned, project v1 lock whose computedHash matches disk).

Scan with SUKIRU_HOME=<this>/.home SUKIRU_ROOTS=<this>/proj.

A correct scan MUST exit 0 and:
- resolve `shared-tool` ownership INDEPENDENTLY per scope: vercel in user
  scope (global lock), ownerless in project scope (no ledger bleed);
- report findings in BOTH scopes: `files-without-lock` for `user-orphan`
  (user) and for `shared-tool` (project), plus the ownerless
  `dangerous-removal-surface` advisories for those two names;
- emit NO findings for `shared-tool` in user scope or `proj-locked`.

VAL-CROSS-018 drives a repair batch against the PROJECT-scope ownerless
`shared-tool` (direct file-op cleanup): the user scope's lock file,
placements, and findings MUST stay byte-identical, and the snapshot manifest
records only project-scope paths (plus the project lock probes).
