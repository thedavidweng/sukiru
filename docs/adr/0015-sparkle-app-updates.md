# 0015: In-app updates through Sparkle

- Status: Accepted
- Date: 2026-10-26
- Amends: [0006](0006-pure-swift-apple-native-feel.md)

## Context

Sukiru ships outside the Mac App Store as a Developer ID signed, notarized
app, installed from the Homebrew tap or the DMG. Updating meant leaving the
app to run `brew upgrade --cask sukiru` or download a new DMG.

macOS gives non-App Store apps no update API. The Mac App Store is not an
option: its required App Sandbox would block the agent configuration
directories and external CLIs (`gh`, `npx`, `brew`) Sukiru works with.
Sparkle 2 is the de facto updater for Developer ID apps: EdDSA-signed
archives, a signed feed, privileged installation through its own helper, and
the standard update alert.

Options considered:

1. **Keep Homebrew and the DMG only.** No in-app path.
2. **A first-party updater on Apple frameworks.** Download, verify the code
   signature against the team and bundle identifier, swap the bundle after
   quitting. Covers the happy path but has to re-solve interrupted swaps,
   non-writable `/Applications`, App Translocation and update UI, all on the
   trust boundary.
3. **Sparkle 2.** Mature answers to the cases above for about 3 MB.

## Decision

Embed Sparkle 2 in the app target only, pinned to an exact version. This is
the single exception to ADR-0006's "no third-party runtime/package
dependencies" rule. SukiruCore and the CLI stay dependency-free, and every
other third-party dependency remains forbidden.

- The App menu has **Check for Sukiru Updates…**, and Settings › General
  mirrors Sparkle's automatic-check preference. Sparkle's standard alert is
  the only update UI. Debug builds never start the updater.
- Each architecture ships its own thinned build and feed on the latest GitHub
  release: `appcast.xml` (arm64, the name 1.10.0 reads) and
  `appcast-x86_64.xml`. Both the archive and the feed are EdDSA-signed
  (`SURequireSignedFeed`); the private key lives in the `SPARKLE_PRIVATE_KEY`
  release secret, backed up in Bitwarden Secrets Manager as
  `SUKIRU_SPARKLE_PRIVATE_KEY`.
- `CFBundleVersion` equals the marketing version so Sparkle can order
  releases.
- The release build removes Sparkle's XPC services, which only sandboxed apps
  need, and re-signs the remaining Sparkle executables with the Developer ID
  identity before the app is signed and notarized.
- The Homebrew cask declares `auto_updates true`, so `brew upgrade` leaves an
  updated app alone and stays available through `--greedy`. The stanza is
  added only once the cask has shipped a Sparkle release for a while: before
  that, it would make `brew upgrade` skip installs that have no updater yet.

## Consequences

- Bumping Sparkle means changing the exact version in `project.yml` and the
  pinned tools tarball and checksum in the release workflow together.
- Losing the EdDSA key strands users on their current version unless the
  Developer ID certificate is used for key rotation.
- Library commands that act on skills say so (**Check for Skill Updates**,
  **Update All Skills**), keeping them apart from the app update command.
- Users on releases before this ADR update once through Homebrew or the DMG.
