# Architecture decision records

Each record captures one decision, its context, the options considered, and
its consequences. Records are not rewritten after acceptance; later changes
are added as amendments or new records that reference the old one.

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-pivot-to-zero-ledger-referee.md) | Pivot to a zero-ledger referee and retire the Rust implementation | Accepted |
| [0002](0002-backend-model-ownership-routing.md) | Capability detection, ownership routing, installer choice, graceful degradation | Accepted |
| [0003](0003-product-name-sukiru.md) | Name the product Sukiru (formerly Gino) | Accepted |
| [0004](0004-v1-product-contract.md) | v1 product contract: local read side, command-batch safety model | Accepted, amended by 0007 |
| [0005](0005-glossary-and-legacy-disposition.md) | Unify vocabulary and dispose of legacy assets | Accepted |
| [0006](0006-pure-swift-apple-native-feel.md) | Pure Swift and an Apple first-party feel | Accepted, amended 2026-10-01 |
| [0007](0007-problem-first-health-and-one-click-fixes.md) | Problem-first Health, one-click fixes, one confirmation per batch | Accepted |
| [0008](0008-host-plugin-management.md) | Independent plugin units, initial host scope, official lifecycle writes and local-file disable boundary | Accepted |
| [0009](0009-host-skill-name-collisions.md) | Detect same-name discovery entries within each host's loading scope | Accepted |
| [0010](0010-agent-hook-hygiene.md) | Passive hook inventory, evidenced attribution, and protected structural cleanup | Accepted |
| [0013](0013-pnpm-read-only-skills.md) | Source-qualified pnpm dependency skills, passive permissions and read-only mutation protection | Accepted |
| [0014](0014-native-first-management-and-bounded-history.md) | Native-first writes, documented-config fallback, bounded snapshot and execution history | Accepted, amends 0008 and 0010 |
| [0015](0015-sparkle-app-updates.md) | In-app updates through Sparkle, the single third-party dependency exception | Accepted, amends 0006 |
| [0016](0016-third-party-integrations-across-agents.md) | Hooks and extensions third-party apps install across every agent | Accepted, amends 0010 and 0014; amended by 0017 |
| [0017](0017-native-add-on-management.md) | Remove and disable every agent's extensions, packages, plugins and MCP servers through native commands | Accepted, amends 0014 and 0016 |

Domain terms are defined in the [glossary](../../CONTEXT.md).

- [0011: First-class Sukiru CLI](0011-first-class-cli.md)
- [0012: Host-scoped Skill removal](0012-host-scoped-skill-removal.md)
