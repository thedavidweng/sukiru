# Sukiru Privacy Policy

Last updated: October 1, 2026

Sukiru does not collect, sell, or share personal data. It has no accounts,
analytics, advertising, telemetry, or cloud service of its own.

## What Sukiru reads

Sukiru reads skill directories, installer lockfiles, and `SKILL.md` files on
your Mac to build its health report. Scanning happens only at launch and when
you click Refresh; there are no background watchers, and Sukiru does not check
for updates to itself or to your skills.

To find `gh` and Node.js, Sukiru starts your login shell once per installer
check and reads its PATH, so your shell startup files run as they do in a new
terminal window. Sukiru sets `SUKIRU_RESOLVING_ENVIRONMENT=1` for that shell;
your startup files can check it to skip slow work.

## When Sukiru uses the network

Sukiru makes these network requests, and no others:

- **Installer detection**: at launch and when you click Check Again in
  Settings, Sukiru runs `gh --version` and, if Node.js is installed,
  `npx --offline skills --version`. The `--offline` flag keeps `npx` from
  contacting the npm registry, so detection never downloads or updates the
  `skills` CLI.
- **skills CLI update check**: when the `skills` CLI is present, Sukiru reads
  `https://registry.npmjs.org/skills/latest` to learn the latest version
  number. This only shows a hint in Settings; nothing is installed.
- **skills CLI download**: only when you click Download or Update in Settings,
  Sukiru runs `npx --yes --prefer-online skills --version`, which fetches the
  latest `skills` package from the npm registry.
- **Search**: your query is sent to the skills.sh search API
  (`https://skills.sh/api/search`) and to `gh skill search`, which runs the
  GitHub CLI with your existing `gh` login.
- **Preview**: a selected skill's `SKILL.md` is downloaded from
  `raw.githubusercontent.com`.
- **Commands you confirm**: installs, updates, and repairs run `npx skills` or
  `gh skill`, which may contact npm, GitHub, or a skill's source repository.
  Those tools follow their own privacy policies. Sukiru runs them with
  `SKILLS_TELEMETRY=0` to opt out of the `skills` CLI's telemetry, and with
  `npm_config_prefer_offline=true` so `npx` uses the `skills` CLI already on
  your Mac instead of updating it.

## Credentials

If `GH_TOKEN` is set in Sukiru's environment, it is passed only to `gh`
commands in a repair or install batch. It is removed from every other command
Sukiru runs, and Sukiru never writes it to disk.

## What Sukiru stores

- **Snapshots and execution records** in
  `~/Library/Application Support/Sukiru`. Before each batch, Sukiru snapshots
  the files the batch can change so you can roll it back. Execution records
  hold the commands that ran and their output. Sukiru keeps the last 10
  snapshots and deletes older ones.
- **Preferences** such as your project roots, language, and install options,
  in the standard macOS user defaults.

This data stays on your Mac. Sukiru never uploads it. Delete the folder above
to remove it.

## This website

The Sukiru website is hosted on GitHub Pages and sets no cookies. It stores
your language choice in your browser's local storage when you switch or
dismiss the language suggestion. GitHub may log requests as described in the
[GitHub Privacy Statement](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement).

## Contact

For privacy questions or support, open an issue at
<https://github.com/thedavidweng/sukiru/issues>.
