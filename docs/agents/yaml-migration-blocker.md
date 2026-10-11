# YAML migration — resolved (#51)

Owner decision A requires Apple-only app, core and CLI dependencies while
preserving existing YAML/config behavior. This migration is complete:
Foundation has JSON and property-list serialization, but no public YAML
parser, so SukiruCore now ships a first-party YAML 1.2 subset parser under
`Sources/SukiruCore/YAML/` (no third-party code, no external process).

Covered contract (all previously listed cases preserved):

- `FrontmatterParser.parse` and `summary` compose YAML mappings, resolve
  scalar tags, aliases, flow collections, quoted escapes and folded/literal
  blocks. Unknown nested values remain accepted. Numeric names are rejected,
  explicit `!!str` names are accepted, and quoted booleans differ from actual
  booleans.
- `GitHubProvenanceReader` consumes those resolved nodes. Pin refs that spell
  `true`/`false` remain strings when tagged/quoted as strings.
- `HookInventoryReader` decodes nested YAML objects/arrays in skill and agent
  frontmatter into `JSONValue`, including aliased hook declarations.

`YAMLCompatibilityTests` records these accepted skill cases; existing hook
source integration tests cover nested hook frontmatter. Anything outside the
subset throws `YAMLError` and surfaces as an `Issue` — inputs are never
silently narrowed.

Yams and its resolved pin are removed (`Package.swift`, `Package.resolved`);
`swift-argument-parser` was already removed by the independent CLI migration.
The repository satisfies decision A.
