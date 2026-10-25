# 0013: pnpm dependency skills are externally managed, source-qualified installations

- Status: Accepted
- Date: 2026-10-25
- Issues: #43, #45, #46, #47, #48, #49

## Context

pnpm 12.11.0 records dependency skill links in its JSON modules manifest and
package-wide permissions in workspace YAML. Its qualified link entries can carry
an unqualified SKILL.md name. Grouping solely by declared name merges independent
packages or misattributes an unrelated Vercel/GitHub installation. Applying Shared
Copy repairs to those links would take over pnpm's dependency lifecycle.

## Decision

- Keep the original declared name and verified package-qualified entry name
  separately. Logical ownership groups use project, entry name and canonical
  dependency target. Host aliases collapse; distinct package sources do not.
  Existing ordinary ownership grouping remains unchanged.
- Verify native linkedSkills against a project-contained symlink, package payload,
  and installed direct dependency. Workspace importers are obtained from the native
  lock's importer inventory and their package manifests. Native `skills.dirs`
  targets inside a registered project are scanned without inventing a host owner.
  Unknown schemas, external stores and unverifiable evidence remain protected and
  diagnostic, never authorization to write.
- A same declared name in another installation is not a competing claim. A lock
  keyed by the real pnpm entry, or GitHub provenance on its actual payload, is an
  ownership conflict. Preserve evidence and block repair rather than picking a
  winner. Vercel/GitHub Double-booked retains its existing meaning.
- Health excludes pnpm placements from installer-copy comparisons, not entire
  declared-name groups. File-presence and host-collision rules retain the full
  inventory. Healthy links are not Ownerless or repair candidates. Broken or
  uncertain state remains visible through scan issues and pnpm guidance.
- Read pendingSkills and workspace permissions as separate informational package
  observations. Pending, approval, explicit denial and unknown are distinct.
  Permissions apply package-wide and may remain after dependency removal; they
  never establish a successful installation or host invocation. Refresh rereads
  current local evidence; no history, watchers, network or pnpm subprocess exists
  in the production read side.
- Preserve the centralized mutation firewall for verified/unverified placements,
  colliding real entry names and containing paths. Original-name equality alone
  does not authorize deleting a different installation. Fix All, CLI repairs,
  individual lifecycle, adoption, mode changes and host removal retain protection.
- Native Library details and Health observations use the existing SwiftUI controls
  and English/Simplified Chinese catalog. JSON additions are optional, deterministic
  and omitted for unaffected installations.

## Verification and limitations

The [native fixture](../../Fixtures/pnpm-12.11.0/README.md) documents reproduction,
real pnpm lifecycle coverage, and separate deployment/discovery/invocation evidence.
A link is not a claim of host compatibility. Offline host probes and explicit
unverified results are preserved in its compatibility evidence.

Swift standard library and Apple frameworks only. pnpm remains the sole writer;
Sukiru is not a third standalone installer and keeps no ownership ledger.
