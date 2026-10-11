# YAML migration blocker (#51)

Owner decision A requires Apple-only app, core and CLI dependencies while
preserving existing YAML/config behavior. The YAML migration is blocked:
Foundation has JSON and property-list serialization, but no public YAML parser.
Its [serialization APIs](https://developer.apple.com/documentation/foundation/archives-and-serialization)
and [property-list formats](https://developer.apple.com/documentation/foundation/propertylistserialization)
do not provide a replacement for Yams.

The current compatibility boundary is broader than line-based key/value parsing:

- `FrontmatterParser.parse` and `summary` compose YAML mappings, resolve scalar
  tags, aliases, flow collections, quoted escapes and folded/literal blocks.
  Unknown nested values remain accepted. Numeric names are rejected, explicit
  `!!str` names are accepted, and quoted booleans differ from actual booleans.
- `GitHubProvenanceReader` consumes those resolved nodes. Pin refs that spell
  `true`/`false` must remain strings when tagged/quoted as strings.
- `HookInventoryReader` decodes nested YAML objects/arrays in skill and agent
  frontmatter into `JSONValue`, including aliased hook declarations.

`YAMLCompatibilityTests` records these accepted skill cases; existing hook
source integration tests cover nested hook frontmatter. These are examples,
not permission to restrict YAML to a subset.

Do not remove Yams by accepting JSON-only frontmatter, silently rejecting YAML
features, invoking an external parser, or vendoring third-party Swift/C code.
Landing the YAML migration requires a complete first-party Swift implementation
that preserves these contracts, an Apple-provided YAML API, or an explicit owner
revision to the compatibility/dependency requirement. Until then Yams and its
resolved pin remain; the repository does **not** satisfy decision A yet. The
independent CLI migration removes swift-argument-parser without changing YAML.
