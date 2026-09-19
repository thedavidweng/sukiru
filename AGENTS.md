## Code cleanliness and footprint

- Keep changes minimal and focused. Do not add dead code, speculative abstractions,
  duplicate helpers, commented-out code, or compatibility shims without a
  demonstrated need.
- Prefer the existing Swift, SwiftUI, Foundation, and SukiruCore patterns before
  introducing a new dependency, service, abstraction, or utility. Every new
  dependency must justify its maintenance and bundle-size cost.
- Keep types, files, and functions cohesive and small. Separate unrelated
  responsibilities instead of growing a catch-all type or view. Remove stale
  code and comments when behavior changes.
- Preserve the repository's formatting and lint gates. Format Swift changes with
  `.swift-format` and keep SwiftLint clean for `Sources`, `Tests`, and `App`.
  Generated sources must remain reproducible and formatted by their generator.
- Keep the app and repository footprint small. Reuse system APIs, semantic
  colors, and existing assets; do not add duplicate resources or large assets
  for one-off use. Compress raster assets and choose size-optimized formats.
- Do not commit build output, generated Xcode data, caches, scratch files, or
  other reproducible artifacts. Keep generated files only when they are
  intentional, reproducible project inputs or load-bearing fixtures.
- For release or distribution builds, prefer size-optimized compiler and asset
  settings, and check that new code, resources, and dependencies have not added
  avoidable bundle or repository weight.
