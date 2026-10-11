# Native implementation policy

Across app, SukiruCore and CLI, use Swift standard library and Apple-provided frameworks (SwiftUI, AppKit, Foundation, etc.) only. Do not use third-party runtime/package dependencies. Native UI inherits platform materials, semantic colors and visual updates; no custom window chrome. Gate new system APIs with `#available`.

YAML and CLI parsing are first-party: `Sources/SukiruCore/YAML/` parses the
supported configuration/frontmatter subset, and CLI command/flag handling
uses first-party facilities. Keep existing supported YAML/config documents,
validation/errors, command names, options, output contracts and tests
functionally equivalent. Do not silently narrow the accepted inputs. The
completed YAML migration is recorded in
[YAML migration blocker](yaml-migration-blocker.md).

Use existing SwiftUI, Foundation and SukiruCore patterns. ADR 0006 remains the canonical UI rationale.
