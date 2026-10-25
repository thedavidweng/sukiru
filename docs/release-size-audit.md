# Release size audit — issue #36

Measured on 2026-10-25 with macOS 27.0.1 (26A434), Xcode 27.1 (27A9275), Apple Swift 6.4, on Apple Silicon. The verified improvement is removing local/debug symbols **before final signing**, using Apple's `strip -S -x`. No resources, architectures, compiler optimization settings, dependencies, or archive formats changed.

## Comparable before/after

Both columns use the same freshly built Release app and helper, with ad-hoc signatures. The candidate copies that payload, removes development signatures, strips the two executables, and signs helper then app again. ZIP uses `ditto -c -k --keepParent`; DMG uses `hdiutil create -format UDZO -imagekey zlib-level=9` with the app and an Applications symlink. Logical app/resource bytes sum regular file lengths; disk allocation is actual `du -sk`, in KiB. Archive values include filesystem/image overhead and signatures.

| Payload | Before bytes | After bytes | Reduction | Before `du -sk` | After `du -sk` |
| --- | ---: | ---: | ---: | ---: | ---: |
| Sukiru.app | 27,818,777 | 13,376,105 | 51.92% | 27,200 | 13,096 |
| Contents/MacOS/Sukiru | 20,984,880 | 8,791,072 | 58.11% | 20,496 | 8,588 |
| Contents/Helpers/sukiru | 4,456,912 | 2,208,048 | 50.46% | 4,356 | 2,160 |
| Contents/Resources | 2,370,665 | 2,370,665 | 0% | 2,332 | 2,332 |
| Contents/Resources/Assets.car | 2,127,400 | 2,127,400 | 0% | 2,080 | 2,080 |
| Sukiru.zip | 8,850,934 | 6,732,331 | 23.94% | 8,644 | 6,576 |
| Sukiru.dmg | 9,018,796 | 6,926,611 | 23.20% | 8,808 | 6,768 |

The existing, untouched `dist/` held a ZIP of 3,861,334 bytes (`du -sk`: 3,772) and DMG of 4,030,123 bytes (3,936 KiB). Its extracted app was 9,459,918 bytes (9,264 KiB), with a 7,108,768-byte executable and **no bundled CLI helper**. These stale artifacts are not a comparable baseline for the current payload. They were extracted only into the audit directory and never overwritten.

The largest remaining files are the universal GUI (8,791,072 bytes), independent arm64 CLI (2,208,048), compiled asset catalog (2,127,400), Simplified Chinese strings (111,604), English strings (59,082), native app icon (49,100), English plural strings (18,724), resource signature manifest (4,654), icon license (4,165), Info.plist (1,658), localized InfoPlist strings (590), and PkgInfo (8). There are no bundled replacement system frameworks or third-party runtime libraries.

## Effective build and symbols

Actual commands, with isolated paths under `.build/size-audit-20261025-133357/`:

```sh
xcodebuild -scheme Sukiru -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$AUDIT/derived" -showBuildSettings
xcodebuild -scheme Sukiru -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$AUDIT/derived" build
swift build --scratch-path "$AUDIT/swift" -c release \
  --product sukiru -Xswiftc -Osize -v
```

`AUDIT` denotes that unique audit directory. Effective GUI settings were `SWIFT_OPTIMIZATION_LEVEL=-Osize`, `DEAD_CODE_STRIPPING=YES`, `DEBUG_INFORMATION_FORMAT=dwarf-with-dsym`, `STRIP_INSTALLED_PRODUCT=YES`, `STRIP_STYLE=all`, `COPY_PHASE_STRIP=NO`, `DEPLOYMENT_POSTPROCESSING=NO`, and macOS deployment target 14.0. GUI and CLI build logs contain actual `-Osize` compiler flags and `-dead_strip` linker flags. Thus duplicating optimization flags would accomplish nothing, while claiming that the normal build fully strips local symbols would be incorrect.

Release GUI output is universal x86_64 + arm64 despite the destination specifying arm64; this support is preserved. The helper uses the host arm64 architecture, matching existing packaging behavior. No architecture was removed to achieve these savings. Both executables have no embedded `__DWARF` section. `nm -gU` before/after output is exactly equal for each executable (2,944 output lines each); removing local/debug symbols preserves exported definitions. `otool -L` dependencies are unchanged and refer only to Apple system frameworks/libraries.

Both generated dSYMs remain outside the shipping app, untouched. `dwarfdump --uuid` confirms that stripped executables still match them:

| Executable slice | Mach-O and retained dSYM UUID |
| --- | --- |
| GUI x86_64 | `4E32812D-7E75-365B-8218-57DEA0A777EA` |
| GUI arm64 | `D53F5D9F-9492-3842-955C-DACEF2E42FB8` |
| CLI arm64 | `30781195-D809-3731-9D6D-6CB8EB153198` |

`Scripts/package-release.sh` now embeds the helper, removes both development signatures, runs `xcrun strip -S -x` on helper and GUI, signs the helper, and invokes the existing final app signing/notarization pipeline. All executable mutations precede final Developer ID signing. There is no post-sign stripping, UPX, additional dependency, or GUI/CLI deduplication.

The unconditional `codesign --remove-signature` calls rely on the build products carrying development signatures. This was observed for both audit executables: signing the freshly built app/helper reported “replacing existing signature,” and both removal commands succeeded before stripping. The GUI's configured signing identity is ad-hoc (`CODE_SIGN_IDENTITY=-`); the helper build also supplied its development signature. The audit launch harness retained each `Popen` process handle and terminated only that owned PID after the five-second timeout; it used no name-based or global app termination.

## Resource and packaging decisions

The production app resource inventory contains compiled native icon/catalog data, English and Simplified Chinese localization/plural data, and the icon license. All 53 agent image sets have corresponding names in `AgentLogo.assetName(for:)`; brand PDF inputs are small (largest 11,525 bytes). Their compiled catalog and native icon remain useful production content. Every production resource is byte-identical between the baseline and candidate, including localizations and license text. Accessibility code is unchanged. Repository screenshots and other nonproduction assets were not treated as shipping payload.

No redundant production asset was proven, so none was removed or resized. Binary symbols dominated the measured payload; packaging overhead did not. Accordingly, no alternate compression/format experiment or shipping-format change was warranted. Single-run packaging wall times were ZIP 0.59 → 0.40 seconds and DMG 5.06 → 4.02 seconds; these are observations, not performance guarantees.

## Exercised smoke and limitations

Before and after stripping, both the extracted ZIP app and the read-only mounted DMG app passed:

- `codesign --verify --deep --strict` on the app and strict verification of `Contents/Helpers/sukiru`.
- Bundled helper `--version` returning `1.0`, equal to the app's `CFBundleShortVersionString`.
- Helper `scan --root <temporary-project> --json`, exit 0 with valid JSON and no findings/issues in the empty fixture.
- Direct GUI executable launch, remaining alive for five seconds before terminating only the audit-owned process; launch logs were empty.

Launches and scans used isolated `HOME`, `CFFIXED_USER_HOME`, `SUKIRU_HOME`, `SUKIRU_ROOTS`, XDG paths, working directory, and an Apple-tools-only PATH under the audit directory. No real user skill roots or existing release artifacts were modified. Both disk image mounts were detached successfully. This is bounded launch evidence, not exhaustive visual/UI coverage; the x86_64 GUI slice was inspected but not executed on this arm64 machine.

`shasum -a 256 -c checksums.txt` passed for both baseline and candidate archives. Candidate SHA-256:

```text
e8ed029edae65ba869b5503163c7cb229d6cade17ab03005420c8133d84981c2  Sukiru.dmg
9c0be8ec347de51ea9e45684719dab6ef2b270887f9e28bea1b8bba069cd170d  Sukiru.zip
```

Baseline SHA-256:

```text
a64a544ed7cf4406f8ab1e77ee023320a95eb20dd60766dbb344125b0a53b1bb  Sukiru.dmg
dd3a3b7b10735ec864fab2b56797c1e2c9ea316790be104406cbfaabb61c7049  Sukiru.zip
```

Raw build settings/logs, measurements, symbol/dependency/UUID output, checksum verification, extracted archives, and retained dSYMs remain in the ignored audit directory. The GUI build reported the AppIntents metadata warning: “Metadata extraction skipped, no AppIntents.framework dependency found.” Verbose SwiftPM output labeled the manifest compiler invocation as a warning. This OS also warns that `hdiutil create`, `attach`, and `detach` are deprecated in favor of `diskutil` equivalents; all three operations succeeded. No packaging command was changed solely to suppress these tool warnings.

The production release script was not invoked because it requires Developer ID
and notary credentials. These artifacts are **ad-hoc audit outputs**: no
notarization, stapling, or Gatekeeper approval is claimed, and measurements do
not include a future Developer ID/notarization payload. Final integration passed
759 tests in 104 suites with compiler warnings treated as errors, including
pinned real pnpm lifecycle coverage; strict formatting, SwiftLint and localization
checks; shell syntax checks; and five controlled release signing/notarization gate
tests. Debug/native and isolated Release app builds succeeded. Native pnpm Refresh,
long-description layout and Cursor Plugin preview were each exercised successfully.
