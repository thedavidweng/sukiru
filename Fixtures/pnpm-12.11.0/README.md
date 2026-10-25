# Native pnpm ownership fixture

Captured on 2026-10-18 from `pnpm --version` = `12.11.0`, on macOS.
The files are copied from an actual isolated install, not an invented metadata schema.
Only the native manifest's machine-specific `storeDir` prefix is replaced with
`<fixture-store>`; `linkedSkills`, the package manifests, SKILL.md and raw link
targets are unchanged.

Reproduce in a temporary directory:

1. Create `package/package.json` from `dependency.json` and
   `package/skills/guide/SKILL.md` from `SKILL.md`.
2. Run `tar -czf fixture.tgz package`.
3. Create `project/package.json` from `project.json`, copy `pnpm-workspace.yaml`,
   and create `project/.claude/skills` and `project/.codebuddy/skills`.
4. With pnpm 12.11.0, an isolated HOME/XDG cache/config/data environment, and no
   CLAUDECODE/CODEBUDDY_CLI/GEMINI_CLI variables, run in `project`:
   `pnpm install --ignore-scripts --store-dir <temporary-directory>/store`.
5. Copy `node_modules/.modules.yaml` to `modules.json`; capture both symlinks
   using `readlink` as `links.json`.

The file dependency requires the exact
`@sukiru/fixture-skills@file:../fixture.tgz` permission selector. A grant for the
package name alone leaves this file dependency pending and creates no links.
Static scan fixtures restore native evidence without running pnpm. The gated
real lifecycle suite below runs only isolated local tarball projects.

Support is explicit: pnpm 12.11+ in major 12, layoutVersion 5, isolated node
linker, default `.pnpm` virtual store, and a direct dependency of the project
or one of its native lock importers. Project-contained `skills.dirs` custom
targets are scanned without inferring host compatibility. Other linkers,
package aliases, external virtual stores and future schemas remain unverified.

Ownership requires the recorded placement, actual symlink, in-project virtual
store target at `skills/<folder>`, installed dependency symlink and matching
package manifest. Original frontmatter names are retained. Verified package
entries are grouped separately from unrelated same-name installations; actual
overlapping manager claims remain read-only conflicts. Verified and unverified
package-manager placements stay protected.

Health excludes verified and unverified pnpm placements from installer-copy
comparisons, not the entire skill-name group. Non-pnpm copies of the same name
still report real drift. Lock-without-files checks use the complete inventory:
a readable pnpm link is not a missing file. Host collision detection also keeps
the complete inventory; aliases remain Notes unless the host reports them as
duplicates. Repairs involving protected entries are skipped with pnpm guidance.

`PnpmHealthTests` covers scan/Health and batch/CLI dry runs against this restored
fixture: same-name Vercel records, mixed-copy drift, damaged targets and manifests,
host collision blocking, and unrelated Vercel/GitHub repairs. Tree checksums verify
that files and raw symlink targets remain unchanged.

English and Simplified Chinese UI text is in `App/Resources/Localizable.xcstrings`:
`Managed by pnpm`, `Unverified pnpm ownership`, `Package`, `Original skill name`,
`Dependency`, and `library.pnpm.readOnly`. CLI diagnostics use the stable
`pnpm-ownership-unverified` issue kind.

## Real pnpm lifecycle and host evidence

With pnpm **12.11.0** installed separately (without changing global selection):

```sh
SUKIRU_PNPM_E2E=1 SUKIRU_PNPM_BINARY=/absolute/path/to/pnpm-12.11.0 \
  swift test -Xswiftc -warnings-as-errors --filter PnpmRealEndToEndTests
```

The suite rejects other versions. It builds local tarballs and exercises pending
installation, package approval, actual links, upgrade with an added skill, resync,
denial/revocation, removal, same-name sources, workspace importers and custom targets.
HOME, XDG directories, npm config/cache, pnpm store and temporary files are isolated;
installs use `--offline --ignore-scripts`. Sukiru scan/Health run with pnpm absent
from PATH; dry-run plans and tree checksums verify the read-only boundary.

Permissions remain package-wide observations separate from installed skills.
`installed` means at least one verified link exists for the package, not that an
individual saved permission selector or every host is active. Old grants can remain
after an upgrade or removal. A newer file artifact can be pending despite an old
selector's approval. Unknown or malformed metadata never grants mutation rights.

[compatibility.json](compatibility.json) records exact real tool versions, commands,
native schema observations and offline host probe results. pnpm-created links were
observed for Claude Code, Codex, Cursor and OpenCode. Codex's local context enumeration
included the skill; the other hosts' discovery remains unverified. Invocation is
unverified for all four: no authenticated/paid model turn was sent. OpenCode's empty
enumeration also omitted an ordinary-directory control, so it is not evidence of
pnpm symlink rejection. These are point-in-time observations, not support promises.

Native UI refresh is exercised by `PnpmUITests`: pending permission without a Skill,
refresh to verified installation, package entry identity and read-only details.
