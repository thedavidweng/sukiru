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

## Consequences

Health counts collisions as warnings under Duplicate skill names, with
host IDs and discovery paths as evidence. Existing content and alias rules
remain independent. No automatic repair is assigned: relinking preserves
the duplicate discovery entry, and name-based removal may delete the wanted
definition too. Users review the paths before renaming or removing an entry.

Coverage is limited to directories Sukiru inventories; arbitrary host
configuration, plugin namespaces, and unscanned roots are outside this rule.
