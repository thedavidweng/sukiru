# FIX-DANGER — expectation (collision-matrix scenario 6 pre-state)

Contents: in the claude-code host dir, one gh-owned skill (`gh-tool`, frontmatter
github-* provenance, no lock entry) and one ownerless skill (`orphan`, no ledger).
In the canonical store, one vercel-owned control (`vercel-ctl`, global lock entry).

A correct scan MUST:
- exit 0;
- resolve ownership: gh-tool=github, orphan=ownerless, vercel-ctl=vercel;
- emit a `dangerous-removal-surface` advisory for gh-tool AND orphan (both would be
  deleted by name by `npx skills remove`), each naming skillName/placementPath/ownership;
- NOT emit that advisory for vercel-ctl (its removal is ledger-consistent);
- additionally emit `files-without-lock` for `orphan` (ownerless inventory listing).
