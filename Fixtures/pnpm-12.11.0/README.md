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
The tests restore only the native evidence and package payload needed by a scan;
they never run pnpm, use the network, or write to the real home/project.

First-slice support is intentionally explicit: pnpm 12.11+ in major 12,
layoutVersion 5, isolated node linker, default `.pnpm` virtual store, and a
direct dependency in the registered project's package.json. Other layouts,
workspace importer indirection, package aliases, external virtual stores and
future versions are unverified, never guessed.

Ownership requires the recorded placement, actual symlink, in-project virtual
store target at `skills/<folder>`, installed dependency symlink and matching
package manifest. Original frontmatter names are retained. Mixed evidence does
not grant group ownership, and all verified or unverified package-manager
placements remain read-only.

English and Simplified Chinese UI text is in `App/Resources/Localizable.xcstrings`:
`Managed by pnpm`, `Unverified pnpm ownership`, `Package`, `Original skill name`,
`Dependency`, and `library.pnpm.readOnly`. CLI diagnostics use the stable
`pnpm-ownership-unverified` issue kind.
