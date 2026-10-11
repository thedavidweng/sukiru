# Native implementation policy

Across app, SukiruCore and CLI, use Swift standard library and Apple-provided frameworks (SwiftUI, AppKit, Foundation, etc.) only. Do not use third-party runtime/package dependencies. Native UI inherits platform materials, semantic colors and visual updates; no custom window chrome. Gate new system APIs with `#available`.

Remove the current Yams dependency from SukiruCore and `swift-argument-parser` from the CLI; migrate configuration parsing and CLI command/flag handling to first-party facilities. Keep existing supported YAML/config documents, validation/errors, command names, options, output contracts and tests functionally equivalent. Do not silently narrow the accepted inputs or hand-roll an incomplete general YAML parser; if native parsing cannot preserve an existing supported YAML case, document the blocker for resolution before landing the migration.

Use existing SwiftUI, Foundation and SukiruCore patterns. ADR 0006 remains the canonical UI rationale.

The current YAML migration blocker is recorded in
[YAML migration blocker](yaml-migration-blocker.md). Do not land the dependency
migration until it is resolved.
