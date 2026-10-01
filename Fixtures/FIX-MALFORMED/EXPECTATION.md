# FIX-MALFORMED — expectation

Contents: a healthy skill `healthy`, a malformed skill `nameless` (frontmatter
missing the required `name`), and a global lock whose `version` (4) is NEWER
than the supported v3. The lock also carries an unknown entry key (`channel`)
and an unknown top-level key (`futureTopLevelKey`).

A correct scan MUST:
- exit 0;
- emit a `skill-md-invalid` issue naming `.agents/skills/nameless/SKILL.md`
  with a missing-name reason, and NOT create a placement for `nameless`;
- emit a `lock-version-unsupported` finding (found=4, supported=3) yet
  best-effort parse the lock (`healthy` still readable) and surface the unknown
  keys;
- still inventory the `healthy` sibling.
