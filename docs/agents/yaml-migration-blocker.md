# YAML migration compatibility (#51)

Owner decision A requires Apple-only app, core and CLI dependencies while
preserving existing YAML/config behavior. The dependency replacements are in place:
Foundation has JSON and property-list serialization, but no public YAML
parser, so SukiruCore now ships a first-party YAML 1.2 subset parser under
`Sources/SukiruCore/YAML/` (no third-party code, no external process).

Covered contract:

- `FrontmatterParser.parse` and `summary` compose YAML mappings with plain,
  single-quoted and double-quoted keys, resolve
  scalar tags, aliases, flow collections, quoted escapes and folded/literal
  blocks. Unknown nested values remain accepted. Numeric names are rejected,
  explicit `!!str` names are accepted, and quoted booleans differ from actual
  booleans.
- `GitHubProvenanceReader` consumes those resolved nodes. Pin refs that spell
  `true`/`false` remain strings when tagged/quoted as strings.
- `HookInventoryReader` decodes nested YAML objects/arrays in skill and agent
  frontmatter into `JSONValue`, including aliased hook declarations.

`YAMLCompatibilityTests` records these accepted skill cases, including escaped
quotes and colons in keys. Hook source integration tests cover quoted keys in
nested skill and subagent hook frontmatter through the passive CLI scan.
Unsupported syntax throws `YAMLError` and surfaces as an `Issue`; that error
handling does not establish compatibility with every input accepted by Yams.

Yams and its resolved pin are removed (`Package.swift`, `Package.resolved`);
`swift-argument-parser` was already removed by the independent CLI migration.
The repository uses only first-party Swift and Apple dependencies. Issue #51
tracks acceptance of the preserved YAML/config and CLI behavior.
