# 0012: Host-scoped Skill removal delegates to the official CLI

- Status: Accepted (core and CLI; Library presentation is a separate handoff)
- Date: 2026-10-04
- Spec: [GitHub issue #32](https://github.com/thedavidweng/sukiru/issues/32)

## Decision

Remove Skills from Agent is one Library request per Agent Host and concrete
ownership bucket (`user` or `project:<root>`). The pure Command Batch builder
combines those requests with repairs and individual Library changes. A separate
read-only `HostRemovalContext` captures path resolution and upstream detection
evidence; callers recreate it after scanning, rather than making the builder
read disk. Queueing freezes the eligible names and building rejects stale names.

The command factory emits one `npx skills remove <names…> -a <host> (-g|-p) -y`.
Project commands run in the project root. Sukiru performs no removal file
operations and never passes `*` or `--all` to npx. Names which could be parsed
as options or wildcard selection are excluded, as are sanitized name collisions.

Three mitigations address the pinned skills@1.7.0 removal behavior:

1. Select only Vercel-owned entries in the host's own folder: links resolving
   to the scope's Shared Copy, or Vercel-locked directory copies. Preserve
   Ownerless, GitHub Ledger, Agent-managed, double-booked, ambiguous, and
   unofficial placements, with a reason and next step. A shared destination
   cannot be cleared for one host alone.
2. Predict Shared Copy deletion using other hosts' plain configuration-marker
   existence and lstat-style install-path existence, including universal hosts'
   canonical install path. Sukiru's stricter spray-residue detection is not the
   upstream rule. Several queued removals account for earlier removed paths.
   Scan issues or a detected CLI version other than 1.7.0 make the prediction
   uncertain and disclose possible deletion. Affected names and paths use the
   structured `removesLockedSkill` consequence, with an explicit every-agent
   warning. Every official removal retains the existing danger flag; `--yes`
   alone grants no danger acknowledgement.
3. Report surviving discovery entries using ADR 0009's loading roots, plus the
   universal shared store. OpenCode's report points to `permission.skill` to
   hide remaining skills. Sukiru does not write host configuration.

One plan contains ordered removed, left-in-place, and still-visible lists,
predicted Shared Copy deletions, uncertainty, a setting hint, and blocking
problems. Both presentation layers consume this model. No eligible names means
no command, with an explanation; missing Node uses the existing needs-npx
blocker. CLI dry-run JSON contains `{plan, batch}`, and human output includes
all three lists and exact argv. Other mutation output remains ExecutionRecord.

`sukiru skills uninstall --all --host <host>` defaults to user scope without an
explicit root, or project scope with one. Project removal requires exactly one
root. An individual uninstall retains its existing whole-skill ownership policy.

## Snapshot and verification

Each removal carries capture roots for the host folder, the scope's shared
folder, and its Vercel lock. Existing snapshots, execution, rescans, diff, and
rollback handle the batch. Core tests exercise the scan-to-builder seam and
built-executable CLI tests exercise previews and confirmation. Isolated real
npx tests pin 1.7.0, verify both shared-store outcomes, protect Ownerless entries
and other host links, and verify byte-identical rollback within affected roots.
npm's package cache is outside those mutation bounds.

Sources: pinned upstream [remove.ts](https://github.com/vercel-labs/skills/blob/v1.7.0/src/remove.ts),
[agents.ts](https://github.com/vercel-labs/skills/blob/v1.7.0/src/agents.ts), and
[installer.ts](https://github.com/vercel-labs/skills/blob/v1.7.0/src/installer.ts).

## Library handoff

The GUI remains unimplemented in this change. It must expose the Library
command, choose a concrete scope and a host from `hostRemovalCandidates`, show
the plan's three lists and shared-copy consequences, and queue `plan.request`
in Pending Changes. Rebuild with `hostRemovals`, a fresh `hostRemovalContext`,
and current capabilities. Localize enum reasons and plan problems in English
and Simplified Chinese; use only system controls and the existing danger
acknowledgement flow (ADR 0006).
