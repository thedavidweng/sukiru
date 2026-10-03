# Host plugin management implementation tickets

Specification: [#14](https://github.com/thedavidweng/sukiru/issues/14).
All tickets are published with `ready-for-agent`; blocking edges use GitHub's
native issue dependencies. Implement the frontier whose blockers are complete.
Do not close or modify the specification issue as part of ticket publication.

| Issue | Deliverable | Blocked by |
| --- | --- | --- |
| [#15](https://github.com/thedavidweng/sukiru/issues/15) | Rollback conflict protection | None |
| [#16](https://github.com/thedavidweng/sukiru/issues/16) | Claude Code passive Plugins Library | None |
| [#17](https://github.com/thedavidweng/sukiru/issues/17) | Codex passive Plugins Library | #16 |
| [#18](https://github.com/thedavidweng/sukiru/issues/18) | OpenCode v1/v2 passive Plugins Library | #16 |
| [#19](https://github.com/thedavidweng/sukiru/issues/19) | OpenCode compatibility diagnosis and local disable | #15, #18 |
| [#20](https://github.com/thedavidweng/sukiru/issues/20) | Claude Code enable/disable and protected mutation | #15, #16 |
| [#21](https://github.com/thedavidweng/sukiru/issues/21) | Claude Code install with host-owned approvals | #20 |
| [#22](https://github.com/thedavidweng/sukiru/issues/22) | Claude Code update/uninstall | #20 |
| [#23](https://github.com/thedavidweng/sukiru/issues/23) | Codex official plugin lifecycle | #15, #17 |
| [#24](https://github.com/thedavidweng/sukiru/issues/24) | OpenCode v1 package install/replacement | #15, #18 |
| [#25](https://github.com/thedavidweng/sukiru/issues/25) | OpenCode v2 package management | #15, #18 |
| [#26](https://github.com/thedavidweng/sukiru/issues/26) | Claude Code marketplace management | #20 |
| [#27](https://github.com/thedavidweng/sukiru/issues/27) | Codex marketplace management | #15, #17 |

Every slice includes its visible behavior, CLI contract and integration tests;
the issue body contains its acceptance criteria. ADR-0008 and the confirmed
specification govern all slices. The existing local plugin investigation is
evidence, not authorization to mutate the user's installed plugins.
