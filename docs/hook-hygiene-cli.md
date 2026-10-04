# Hook hygiene CLI

`scan --json` includes optional `hookInventory` with configured handlers,
source tiers, exact source positions, producer evidence, health, and inspection
issues. `hooks inventory` emits the same shared report. Multiple Claude/Codex
sources are additive; OpenCode remains in `pluginInventory`.

Create a requests file containing exact scanned hook IDs:

```json
[{"action":"remove","hookID":"<id from hookInventory.hooks>"}]
```

Or choose `{"action":"remove-leftovers","producer":"Muxy"}` (also Orca), or
`{"action":"disable-producer","producer":"Orca"}` for installed Orca. Producer
disable applies across hosts, not to one handler. Source-managed definitions
return instructions rather than independently executable mutations.

```sh
sukiru hooks plan --requests requests.json --json > hook-plan.json
sukiru hooks execute --plan hook-plan.json --yes --confirm-dangerous --json
sukiru rollback --batch <execution batchID> --yes --json
```

Review the plan's `hooks`, `helperPaths`, `instructions`, and every batch command
before execution. Execute the saved plan, not a re-created plan: source bytes and
resolved paths must still match the scan. Changes require rescan and replanning.
Execution returns the shared record including snapshot ID, command diagnostics,
and post-run diff, even after a producer command fails. Existing conflict-aware
rollback options apply.

The native app offers per-host Hooks destinations, Needs Attention grouping,
source/target reveal, source-unit navigation, Health inspection, and cleanup in
the shared Pending Changes cart. Hook edits join other queued changes in one
reviewed batch and one snapshot.

`SUKIRU_HOME` and `SUKIRU_ROOTS` isolate home/project sources as elsewhere in the
CLI. `SUKIRU_SYSTEM_ROOT` points to a mounted system tree for managed-policy
inspection; an overridden home otherwise excludes the machine's system policy.
Managed files are always read-only, even when writable by the current user.
