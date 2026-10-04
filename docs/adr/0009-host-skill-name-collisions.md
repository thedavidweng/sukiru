# 0009: Skill-name collisions follow host discovery scopes

Status: Accepted

## Context

ADR 0007 treats links into a shared skill folder as informational aliases.
That describes file identity, but does not establish host loading health:
local Droid diagnostics reported 31 duplicate names across `.agents/skills`
and `.factory/skills`, even though each pair resolved to the same folder.

## Decision

Run `host-name-collision` across every scanned host's directories, grouped by
skill frontmatter name and ownership scope. Multiple discovery paths count
even when they resolve to one target; repeated inventory records of the
same path count once. Broken links do not participate. Agent-managed
directories participate because ownership does not prevent name collisions.

The installer host table supplies destinations, not complete loading rules.
The rule includes these documented compatibility roots:

- Droid reads the shared `.agents/skills` store as well as `.factory/skills`.
  Its project Factory directory is already scanned as a legacy destination.
  [Factory skills](https://docs.factory.com/harness/skills) specifies that
  duplicate names within one source bucket are invalid configuration.
- OpenCode reads the shared store, Claude-compatible skills, and its own
  scanned directories. [OpenCode skills](https://opencode.ai/docs/skills/)
  lists these locations and requires unique names across locations.
- [Claude Code skills](https://code.claude.com/docs/en/skills) explicitly
  deduplicates symlinks resolving to one target; such aliases do not produce
  a Claude Code collision.

Different user/project scopes stay separate. Sharing one skill between
different hosts remains an informational alias unless one host discovers
multiple entries within its own scope. No loading behavior is inferred for
additional compatibility roots that a host has not documented.
Compatibility roots are combined only when the host is detected or has its
own scanned directory; a host merely listed as a potential shared-store
consumer does not turn unrelated project links into a conflict.

## Amendment: classify by what the user can do

Most collisions in a real library were entries resolving to one folder:
`npx skills` links `~/.claude/skills/<name>` for Claude Code, and OpenCode
also reads `~/.agents/skills`. Every host loads the same files, and no
removal could help: Claude Code needs that link. Counting these as problems
buried the actionable ones. Each finding now carries a `subtype`:

- `distinct`: a host sees entries backed by different folders and loads
  only one. A warning; the user keeps one entry (`arbitrate` with choice
  `{"keep": "<entry path>"}`). Entries resolving to the kept folder stay,
  since other hosts may load the skill through them. Every other entry is
  deleted when Sukiru can do so safely: links, and ownerless or gh-ledger
  folders. Agent-managed and Vercel-owned folders are refused (a name-based
  `npx skills remove` would delete the kept entry too), and so is a deletion
  that would leave another link dead.
- `redundant`: every entry is one folder, but a host that reports such
  aliases sees them. Droid does: its startup diagnostics list each one.
  `redundantPath` lists the links in folders only that host reads, never the
  shared store, and `cleanup` deletes them as a one-click fix. The host still
  reads the shared entry, so nothing is lost. Such links were left by skills
  releases before 1.5.25, which linked Droid's user-scope installs into
  `~/.factory/skills`; vercel-labs/skills#2012 made Droid a universal agent,
  so current installs no longer create them. Droid itself could deduplicate
  same-target entries (Factory-AI/factory#48).
- `alias`: every entry is one folder and no host involved reports it. Severity
  `info`; Health lists it as a note.

## Consequences

Health counts `distinct` and `redundant` collisions as warnings under
Duplicate skill names, with host IDs and discovery paths as evidence;
`alias` collisions are notes. Existing content and alias rules remain
independent. Repairs touch discovery entries only, never the skill as a whole,
so the ownership-routed update and removal repairs do not apply.

Coverage is limited to directories Sukiru inventories; arbitrary host
configuration, plugin namespaces, and unscanned roots are outside this rule.
