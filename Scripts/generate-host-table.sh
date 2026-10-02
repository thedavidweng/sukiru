#!/usr/bin/env bash
# Generates Sources/SukiruCore/Hosts/HostTableData.swift from
# research/host-table.json. Deterministic: the emitted file is a pure function
# of the JSON. Run from the repo root; re-run whenever the host table changes.
#
#   Scripts/generate-host-table.sh
#
# After generating, the file is normalized with `swift format --in-place` so it
# satisfies the repo lint gates (it contains no multi-line collection literals,
# so the in-place trailing-comma hazard does not apply).
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
json="$repo_root/research/host-table.json"
out="$repo_root/Sources/SukiruCore/Hosts/HostTableData.swift"

count="$(jq '.hosts | length' "$json")"

# Emit one `hosts.append(spec(...))` line per host. Optional arguments are
# omitted when they equal the factory defaults so the common case stays short.
appends="$(
    jq -r '
        .hosts[]
        | "    hosts.append(spec("
          + (.id | @json) + ", "
          + (.displayName | @json) + ", "
          + (.projectSkillDir | @json) + ", "
          + (.globalSkillDirRelative | @json) + ", "
          + (.detectionMarker | @json)
          + (if .envHomeVar != null then ", env: " + (.envHomeVar | @json) else "" end)
          + (if .envFallbackDir != null then ", fallback: " + (.envFallbackDir | @json) else "" end)
          + (if (.extraMarkers | length) > 0
               then ", extra: [" + (.extraMarkers | map(@json) | join(", ")) + "]"
               else "" end)
          + (if .globalBase != "Home" then ", base: ." + (.globalBase | ascii_downcase) else "" end)
          + (if .detectInProject then ", detectInProject: true" else "" end)
          + (if .showInUniversalList == false then ", universal: false" else "" end)
          + (if (.legacyProjectSkillDirs | length) > 0
               then ", legacyProject: [" + (.legacyProjectSkillDirs | map(@json) | join(", ")) + "]"
               else "" end)
          + (if (.legacyGlobalSkillDirs | length) > 0
               then ", legacyGlobal: [" + (.legacyGlobalSkillDirs | map(@json) | join(", ")) + "]"
               else "" end)
          + (if .ghAgentId != null then ", gh: " + (.ghAgentId | @json) else "" end)
          + "))"
    ' "$json"
)"

# Split the appends into chunks of at most PER_CHUNK hosts so no builder
# function trips swiftlint's function_body_length rule (limit 50; wrapped
# entries can span up to ~4 lines each).
per_chunk=10
total="$(printf '%s\n' "$appends" | wc -l | tr -d ' ')"
num_chunks=$(((total + per_chunk - 1) / per_chunk))

{
    echo "// Generated from research/host-table.json by Scripts/generate-host-table.sh."
    echo "// Do NOT edit by hand — regenerate instead. Host count: $count."
    echo ""
    echo "extension HostTable {"
    echo "    /// The generated $count-host table backing \`HostTable.hosts\`."
    combined=""
    for ((c = 0; c < num_chunks; c++)); do
        combined+="hostsChunk${c}()"
        if ((c < num_chunks - 1)); then combined+=" + "; fi
    done
    echo "    static let generatedHosts: [HostSpec] = $combined"
    echo ""
    for ((c = 0; c < num_chunks; c++)); do
        start=$((c * per_chunk + 1))
        end=$(((c + 1) * per_chunk))
        chunk="$(printf '%s\n' "$appends" | sed -n "${start},${end}p")"
        echo "    private static func hostsChunk${c}() -> [HostSpec] {"
        echo "        var hosts: [HostSpec] = []"
        echo "$chunk"
        echo "        return hosts"
        echo "    }"
        echo ""
    done
    cat <<'FACTORY'
    // swift-format-ignore: NeverUseImplicitlyUnwrappedOptionals
    private static func spec(
        _ id: String,
        _ displayName: String,
        _ projectSkillDir: String,
        _ globalSkillDirRelative: String,
        _ detectionMarker: String,
        env envHomeVar: String? = nil,
        fallback envFallbackDir: String? = nil,
        extra extraMarkers: [String] = [],
        base globalBase: HostSpec.GlobalBase = .home,
        detectInProject: Bool = false,
        universal showInUniversalList: Bool = true,
        legacyProject legacyProjectSkillDirs: [String] = [],
        legacyGlobal legacyGlobalSkillDirs: [String] = [],
        gh ghAgentId: String? = nil
    ) -> HostSpec {
        HostSpec(
            id: id,
            displayName: displayName,
            projectSkillDir: projectSkillDir,
            globalSkillDirRelative: globalSkillDirRelative,
            detectionMarker: detectionMarker,
            envHomeVar: envHomeVar,
            envFallbackDir: envFallbackDir,
            extraMarkers: extraMarkers,
            globalBase: globalBase,
            detectInProject: detectInProject,
            showInUniversalList: showInUniversalList,
            legacyProjectSkillDirs: legacyProjectSkillDirs,
            legacyGlobalSkillDirs: legacyGlobalSkillDirs,
            ghAgentId: ghAgentId
        )
    }
}
FACTORY
} > "$out"

swift format --in-place --configuration "$repo_root/.swift-format" "$out"

echo "wrote $out ($count hosts)"
