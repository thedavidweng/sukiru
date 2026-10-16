# Maintainable code and repository footprint

- Remove dead code, deprecated helpers, speculative abstractions, commented-out code and compatibility shims not tied to a demonstrated requirement.
- Keep Swift types, functions and views cohesive; split unrelated responsibilities rather than creating catch-all utilities or views.
- Reuse existing system APIs and assets; avoid near-identical resources and oversized assets for one-off UI elements. Compress raster images and prefer suitable size-efficient formats.
- Format with `.swift-format` and keep SwiftLint clean for `Sources`, `Tests` and `App`.
- Generated sources must be reproducible and formatted by their generator.
- Do not commit build products, Xcode DerivedData, cache directories or scratch artifacts. Check that intentionally committed generated inputs and fixtures are necessary.
