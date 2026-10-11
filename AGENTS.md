# Sukiru

Native macOS SwiftUI app and Swift CLI for inspecting, repairing and managing coding-agent skills.

- Entire repository (UI, core and CLI): Swift standard library and Apple frameworks only; remove Yams and swift-argument-parser and do not add third-party runtime/package dependencies. Preserve public configuration and CLI behavior.
- Before changing the native design, read [ADR 0006](docs/adr/0006-pure-swift-apple-native-feel.md).
- Verify affected Swift targets with the repository's `.swift-format` and SwiftLint gates; use `swift test` for SukiruCore changes.

Task-specific references:
- [Native implementation and dependency policy](docs/agents/native-ui.md)
- [Code and repository footprint](docs/agents/code-footprint.md)
- [Distribution checks](docs/agents/distribution.md)
