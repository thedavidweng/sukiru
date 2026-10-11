# Distribution and size checks

When modifying packaging or release settings, inspect size-optimized Swift compiler flags and asset settings and compare resulting bundle size with the previous release. Remove/avoid third-party runtime dependencies across the entire repository; prefer Apple-provided frameworks and existing assets over duplicated UI libraries or asset packs.

For code changes that affect SukiruCore, run `swift test` and the repo's existing format/lint gates. For app changes, use the app/CI build and formatting targets already configured in the repo; do not invent a new framework or a second dependency manifest.
