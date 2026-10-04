# 0011: First-class Sukiru CLI

- Status: Accepted
- Date: 2026-10-04
- Spec: [GitHub issue #30](https://github.com/thedavidweng/sukiru/issues/30)

## Decision

Ship `sukiru` alongside Sukiru.app. Apple Swift Argument Parser is the sole
public parsing architecture, confined to the executable target. It replaces
the general parser formerly in SukiruCore and the separate Plugin/Hook parsers.
Its maintenance and bundle cost replaces project-specific parsing, help,
validation, and completion code; the native UI gains no dependency.

The primary workflows are passive `health`, cleanup-only `clean`, and
ProblemKind's deterministic one-click `fix`. Resource commands delegate Skill
and Plugin lifecycle, discovery, and planning to the existing core. Unresolved
Adoption, ownership, and source choices remain explicit. Existing machine plan
contracts remain available through Argument Parser.

Reports default to human text, with `--json` reserving stdout for data.
Health check mode distinguishes healthy (0), Problems (1), and incomplete
scan/environment failures (2). Parser usage errors follow Argument Parser's
standard exit status (64); execution refusals/failures exit 1.

All mutation adapters share dry-run, confirmation, danger acknowledgement,
and the existing CLIExecutor. Normal `--yes` does not grant danger consent.
The executor remains responsible for snapshots, serialization, first-error
stopping, rescans, differences, and rollback. Scoped mutations retain the user
ledger in their scan context because GitHub companion writes cross scopes.

CLI and GUI release versions come from the same bundled Info.plist. Release
packaging builds the CLI with size optimization, embeds and signs it, and
checks the version before producing archives. The Homebrew cask links that
bundled executable onto PATH. The cask lives in the separate homebrew-tap
repository and must be released with an artifact containing the executable.

## Verification

The feature seam is the real built executable against isolated HOME/project
fixtures and controlled official-command substitutes, as agreed in issue #30.
Core domain tests remain intact; framework parsing is not reimplemented or
unit-tested. Existing integration contracts now use `sukiru`, `--json`,
`--yes`, and rollback `--dry-run`.
