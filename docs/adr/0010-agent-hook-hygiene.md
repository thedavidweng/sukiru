# 0010: Passive Agent Hook inventory and structural cleanup

- Status: Accepted
- Date: 2026-10-04
- Origin: [#29](https://github.com/thedavidweng/sukiru/issues/29)

## Decision

Hooks form an independent inventory domain for Claude Code and Codex. Every
scan reconstructs configured handlers from current local files. OpenCode hooks
remain plugin behavior; Sukiru never loads or transforms plugin code. Inventory
does not establish runtime activation, successful execution, or host trust.

ADR-0001 remains unchanged: there is no Sukiru Hook ledger. Source hashes,
structural positions, producer evidence, and proposed edits are scan/Command
Batch facts, not a persisted lifecycle registry. Producer names without a known
payload boundary never establish attribution.

For standalone user/project/local hook definitions, the documented source file
is the lifecycle interface. This is a narrow exception to ADR-0008's plugin
write boundary: reviewed cleanup may remove exact configured handlers from JSON
settings, dedicated hook JSON, or supported Codex TOML array tables. Plugin,
skill, subagent, and managed-policy sources remain read-only. No per-hook
Claude enablement, Codex trust hashes, or trust bypass is introduced.

JSON token ranges and TOML table blocks preserve unrelated bytes, settings,
order, and comments. Duplicate JSON keys, unsupported TOML representations, and
unreadable sources produce inspection Problems rather than approximate edits.
Only containers emptied by the selected removal are removed. Existing empty
sibling containers are retained.

## Safety and lifecycle

Each source edit carries the exact scan content hash and resolved path. The
executor checks every precondition before snapshot capture and immediately
before its command. A changed source requires rescan/replan; cleanup never
searches for a similar-looking definition. Saved CLI plans preserve this review
boundary across processes. The native cart retains the original scan evidence.

The shared executor captures the source files and individually disclosed helper
files before running anything. Existing execution records, post-run diffs, and
conflict-aware restore/preserve rollback apply without a second safety system.

Helpers may be removed only inside the recognized producer's hook payload
boundary, while the producer is absent, and with no remaining discovered
reference. Unknown commands or inspection errors prevent that proof. References
are checked at preflight and again before deletion. Symlinked helpers and
general application-support directories are not deleted.

Muxy's documented staging boundary is `~/Library/Application Support/Muxy/hooks`.
Orca's generated script boundary is `~/.orca/agent-hooks`. Installed Orca hooks
can also be attributed by its verified runtime-home wrapper (the HOME guard,
producer script readability/executable guards, and shell invocation together).
That recognizer supplies attribution only: runtime target existence stays
Unknown and dynamic wrappers never authorize helper deletion. Installed Orca hooks
prefer its supported `orca agent hooks off --json` operation. That operation
changes producer settings across hosts: Pending Changes discloses native argv,
captured hook sources/payloads, and external state effects requiring separate
consent. File rollback does not restore Orca runtime/profile state or uncaptured
host changes; re-enablement belongs in Orca.

## Inspection limits

Inspection remains offline and never launches a hook, host, producer, HTTP
request, or MCP tool. Dynamic shell expressions and runtime working directories
remain Unknown when a literal target cannot be proven. Producer attribution and
presence are static disk/PATH evidence; a configured integration is not a
runtime health guarantee.

System policy files and on-disk managed preference payloads are inventoried as
configured, read-only evidence, not a claim about which policy layer a running
host selected. Remote policy that has no documented on-disk representation is
not fetched. Host trust/review remains Unknown unless stable local evidence is
available. `SUKIRU_HOME` scans exclude real system policies;
`SUKIRU_SYSTEM_ROOT` explicitly supplies a mounted system tree for isolated
policy inspection and CLI tests.

## Evidence

- [Claude hooks](https://code.claude.com/docs/en/hooks)
- [Claude managed settings](https://code.claude.com/docs/en/managed-settings)
- [Codex hooks](https://learn.chatgpt.com/docs/hooks)
- [Codex managed preferences](https://learn.chatgpt.com/docs/enterprise/managed-configuration)
- [Muxy staging and refresh](https://muxy.app/docs/user-guide/troubleshooting)
- [Orca native lifecycle](https://www.onorca.dev/docs/cli/reference)
- [Orca producer implementation](https://github.com/stablyai/orca/blob/main/src/main/claude/hook-service.ts)
- [Orca runtime-home wrapper](https://github.com/stablyai/orca/blob/main/src/main/agent-hooks/runtime-home-hook-command.ts)

Behavioral acceptance tests use the real CLI over temporary home, project, and
policy trees. Producer executables are substituted only when the requested
operation explicitly invokes the producer.
