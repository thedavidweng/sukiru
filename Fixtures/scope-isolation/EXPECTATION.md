# scope-isolation — expectation

Contents: the name `shared-skill` installed TWICE — user scope
(`.home/.agents/skills/shared-skill`, claimed by the global v3 lock) and project
scope (`proj/.agents/skills/shared-skill`, claimed by the project v1 lock whose
computedHash matches disk). Plus ONE finding-generating defect per scope:
`user-orphan` (ownerless, user scope) and `proj-orphan` (ownerless, project
scope), each raising `files-without-lock` in ITS OWN scope only.

Scan with SUKIRU_HOME=<this>/.home, SUKIRU_ROOTS=<this>/proj.

A correct scan MUST:
- exit 0;
- tag every workspace/placement/finding with an unambiguous scope;
- resolve `shared-skill` ownership per scope: vercel in BOTH, but the user-scope
  resolution MUST come from the global lock only and the project-scope one from
  the project lock only (no cross-scope ledger bleed);
- keep the `user-orphan` finding out of every project-scope workspace section
  and the `proj-orphan` finding out of every user-scope section;
- with `--scope user` report ONLY user-scope items, with `--scope project` ONLY
  project-scope items, and with `--scope all` exactly the union;
- NOT flag `shared-skill` as ambiguous (one placement per scope; the ambiguity
  rule is per-scope).
