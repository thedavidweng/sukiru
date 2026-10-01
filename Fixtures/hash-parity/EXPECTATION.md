# hash-parity — upstream computedHash parity canary

`proj/skills-lock.json` was written by the REAL pinned skills@1.5.26 CLI
(`add ../gen-source -s hashprobe -a claude-code --copy -y`, local source, in a
sandbox). `proj/.agents/skills/hashprobe` ships the CLI-hashed SOURCE tree
byte-exactly — including files a real copy-mode install would have stripped
(`metadata.json`) or materialized differently —
because this fixture isolates HASH ALGORITHM parity, not copy fidelity.

Adversarial contents: ICU-collation-tricky names (`SKILL.md` vs `scripts/`
vs `agents/`, numeric `10-x.md`/`2-y.md`, mixed case, `_notes.md`),
`metadata.json` (included), `.git/` + `node_modules/` (excluded), and a
symlink at `node_modules/.bin/pkg` — inside an excluded directory, because
upstream EXCLUDES symlinks from the hash while Sukiru hashes a visible one as
`symlink:"<target>"`; the two rules only agree when no hash-visible symlink
exists (see HashingTests for the symlink-convention vectors).

Scan with SUKIRU_HOME=<hash-parity>/.home, SUKIRU_ROOTS=<hash-parity>/proj.
Expect: recomputed computedHash for the `hashprobe` placement byte-equals the
lock's `c25270a735115a815934f0c6f5d0f4539411871e22b3fa935d95ff182abbf4c3`; ZERO vercel-lock-drift findings (and no other findings).

Regenerate: SUKIRU_E2E=1 Scripts/fixtures/generate-hash-parity.sh
Note: git never tracks the fixture's inner `.git/` directory, so a fresh
regeneration contains `.git/cfg` while the committed tree does not — the
digest is identical either way (that exclusion is the point).
