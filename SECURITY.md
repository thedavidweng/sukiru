# Security policy

## Supported versions

Security fixes are released for the latest version of Sukiru only. Update to
the newest release before reporting.

## Reporting a vulnerability

Do not open a public issue for security problems.

Report vulnerabilities privately through
[GitHub private vulnerability reporting](https://github.com/thedavidweng/sukiru/security/advisories/new).
Include:

- the affected version and macOS version,
- a description of the issue and its impact,
- steps to reproduce or a proof of concept.

You will receive an acknowledgement within 7 days. We will keep you informed
while we investigate, and credit you in the release notes unless you prefer
otherwise.

## Scope

Areas of particular interest:

- file operations that escape the intended skill directories (path traversal,
  symlink following),
- snapshot and rollback logic that could lose or corrupt user data,
- command construction for the official CLIs (argument injection),
- handling of `GH_TOKEN` and other credentials.

Vulnerabilities in `npx skills`, `gh skill`, Node.js, or the GitHub CLI
themselves should be reported to those projects.
