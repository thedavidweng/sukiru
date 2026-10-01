# FIX-SCOPES — expectation

Contents: user scope holds `shared-name` + `user-only` (global v3 lock);
project root `proj/` holds `shared-name` + `proj-only` (project v1 lock whose
computedHash values match disk). Everything is vercel-owned and consistent:
ZERO findings — scope separation is the only signal.

Scan with SUKIRU_HOME=<this>/.home SUKIRU_ROOTS=<this>/proj.

A correct scan MUST exit 0, report the user-scope skills under the `user`
workspace and the project-scope skills under `project:<root>` workspaces, and
show `shared-name` ONCE PER SCOPE (per-scope ownership resolution, never
merged, never ambiguous — ambiguity is judged per scope). The app Library
MUST render a `sukiru.library.section.user` section and a distinct
`sukiru.library.section.project.*` section, each skill under its true scope.
