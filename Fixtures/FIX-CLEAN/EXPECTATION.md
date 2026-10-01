# FIX-CLEAN — expectation

Contents: canonical user store `.agents/skills/greet` (one physical placement)
plus the global v3 lock `.agents/.skill-lock.json` claiming `greet`.

A correct scan MUST:
- exit 0, valid JSON;
- list exactly one skill `greet`, scope=user, ownership=vercel, ambiguous=false,
  with a single placement of kind=directory;
- surface the vercel provenance (source/sourceType/sourceUrl/skillPath and the
  GLOBAL-scope `skillFolderHash`; NO `computedHash` for a global entry);
- report ZERO findings (global scope has no drift check; single placement means
  no duplicates; a lock entry means no files-without-lock).

Note: the Health UI originally called for a richer FIX-CLEAN
spanning all four ownership classes. Because github/ownerless skills always
raise a `dangerous-removal-surface` advisory, a genuinely
zero-findings tree can contain vercel-owned skills only; this fixture honors
the scan engine's zero-findings baseline.
