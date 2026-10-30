import Foundation

struct HookDiagnosis {
    let environment: SukiruEnvironment

    struct Assessment {
        let attribution: HookAttribution
        let health: HookHealth
        let evidence: [String]
        let targets: [String]
    }

    func inspect(details: [String: JSONValue], source: HookSource) -> Assessment {
        let command = source.host.command(details)
        let targets = command.flatMap(literalTargets) ?? []
        let missing = targets.filter { !FileManager.default.fileExists(atPath: $0) }
        let missingExecutable =
            command.flatMap(Self.words)?.first.map {
                !$0.contains("/") && literalTargets(command!) != nil && executable($0) == nil
            } ?? false
        let boundaries = [
            ("Muxy", environment.home + "/Library/Application Support/Muxy/hooks"),
            ("Orca", environment.home + "/.orca/agent-hooks")
        ]
        let recognized = boundaries.first { boundary in
            targets.contains { $0.hasPrefix(boundary.1 + "/") }
        }
        if let recognized {
            return producerAssessment(recognized, missing: missing, targets: targets)
        }
        if let command, let payloads = orcaPayloads(command) {
            guard payloads.isEmpty else {
                return producerAssessment(
                    boundaries[1],
                    missing: payloads.filter {
                        !FileManager.default.fileExists(atPath: $0)
                    }, targets: payloads)
            }
            return orcaRuntimeAssessment()
        }
        let producer =
            source.managingPluginID ?? source.managingSource
            ?? (source.tier == "managed" ? "Managed Policy" : "Unknown")
        let attribution = HookAttribution(
            producer: producer,
            evidence: producer == "Unknown" ? [] : ["Defined by " + source.path],
            producerPresent: nil)
        let managed = ["plugin", "skill", "subagent", "managed"].contains(source.tier)
        let health: HookHealth =
            !missing.isEmpty || missingExecutable
            ? .brokenTarget
            : managed ? .sourceManaged : command != nil && targets.isEmpty ? .unknown : .observed
        return Assessment(
            attribution: attribution, health: health,
            evidence:
                missing.map { "Missing literal target: " + $0 }
                + (missingExecutable ? ["Executable not found on Sukiru's PATH"] : []),
            targets: targets
        )
    }

    private func orcaRuntimeAssessment() -> Assessment {
        let installed = producerPresent("Orca")
        return Assessment(
            attribution: HookAttribution(
                producer: "Orca",
                evidence: ["Command invokes Orca's hook payload through a runtime-resolved path"],
                producerPresent: installed),
            health: installed ? .externallyManaged : .leftover,
            evidence: ["Runtime HOME target existence is unknown"]
                + (installed
                    ? ["Producer may regenerate these hooks"]
                    : ["Producer application/executable is absent"]),
            targets: [])
    }

    /// Orca owns every command that runs a script in its payload boundary, the rule its own
    /// installers use. Guarded wrappers hide the script from word parsing, so literal
    /// `~/.orca/agent-hooks/…` paths are read from the text; an empty result means every
    /// reference resolves at runtime (`${HOME-}` or `${ORCA_AGENT_HOOK_ROOT-}`). Nil: not Orca's,
    /// including commands that only mention a payload (`echo`, a `[ -f … ]` test alone).
    func orcaPayloads(_ command: String) -> [String]? {
        let literal = environment.home + "/.orca/agent-hooks/"
        let forms = [
            literal, "${HOME-}/.orca/agent-hooks/", "${HOME}/.orca/agent-hooks/",
            "$HOME/.orca/agent-hooks/", "${ORCA_AGENT_HOOK_ROOT-}/agent-hooks/"
        ]
        var invoked = false
        var payloads: Set<String> = []
        for form in forms {
            var rest = command[...]
            while let range = rest.range(of: form) {
                invoked = invoked || Self.runsWord(at: range.lowerBound, in: command)
                if form == literal, let name = Self.payloadName(after: range, in: command) {
                    payloads.insert(literal + name)
                }
                rest = rest[range.upperBound...]
            }
        }
        return invoked ? payloads.sorted() : nil
    }

    /// Whether the shell word starting at `index` is a command or an interpreter's script.
    private static func runsWord(at index: String.Index, in command: String) -> Bool {
        let before = command[..<index].reversed().drop { "\"'\\ \t\n".contains($0) }
        let previous = String(before.prefix { !" \t\n".contains($0) }.reversed())
        let operators = [";", "&&", "||", "|", "(", "{"]
        let runners: Set<String> = [
            "", "then", "do", "else", "exec", "command", "sh", "bash", "zsh", "node", "python3",
            "/bin/sh", "/bin/bash", "/bin/zsh", "/usr/bin/env"
        ]
        return runners.contains(previous) || operators.contains(where: previous.hasSuffix)
    }

    /// The file name after a payload prefix: up to the closing quote when quoted, else up to
    /// the first shell delimiter. Nil for nested paths.
    private static func payloadName(
        after range: Range<String.Index>, in command: String
    ) -> String? {
        let quote = command[..<range.lowerBound].last.flatMap { "\"'".contains($0) ? $0 : nil }
        let unquoted: Set<Character> = [
            " ", "\t", "\n", ";", "&", "|", "<", ">", ")", "`", "\"", "'", "\\"
        ]
        let stops = quote.map { [$0, "\\"] } ?? unquoted
        let name = command[range.upperBound...].prefix { !stops.contains($0) }
        return name.isEmpty || name.contains("/") ? nil : String(name)
    }
    private func producerAssessment(
        _ recognized: (String, String), missing: [String], targets: [String]
    ) -> Assessment {

        let installed = producerPresent(recognized.0)
        let attribution = HookAttribution(
            producer: recognized.0,
            evidence: ["Literal target inside producer hook payload: " + recognized.1],
            producerPresent: installed)
        let health: HookHealth = !missing.isEmpty || !installed ? .leftover : .externallyManaged
        return Assessment(
            attribution: attribution, health: health,
            evidence:
                missing.map { "Missing target: " + $0 }
                + (!installed
                    ? ["Producer application/executable is absent"]
                    : ["Producer may regenerate these hooks"]),
            targets: targets
        )
    }

    func producerPresent(_ name: String) -> Bool {
        let apps =
            [environment.home + "/Applications/" + name + ".app"]
            + (environment.homeIsOverridden ? [] : ["/Applications/" + name + ".app"])
        return apps.contains { FileManager.default.fileExists(atPath: $0) }
            || (name == "Orca" && executable("orca") != nil)
    }

    /// No shell evaluation. Runtime cwd, substitutions, operators, and shell builtins remain unknown.
    func literalTargets(_ command: String) -> [String]? {
        guard let words = Self.words(command), let first = words.first else { return nil }
        let builtins: Set<String> = [
            "echo", "printf", "cd", "export", "source", ".", "eval", "exec", "test", "true",
            "false", "if", "function"
        ]
        if builtins.contains(first) { return nil }
        var paths: [String] = []
        if let path = path(first) {
            paths.append(path)
        } else if !first.contains("/"), let found = executable(first) {
            paths.append(found)
        } else if first.contains("/") {
            return nil
        }
        let interpreters: Set<String> = [
            "sh", "bash", "zsh", "python", "python3", "node", "ruby", "perl"
        ]
        if interpreters.contains(URL(fileURLWithPath: first).lastPathComponent), words.count > 1 {
            guard !words[1].hasPrefix("-"), let script = path(words[1]) else { return nil }
            paths.append(script)
        }
        return paths
    }

    func path(_ text: String) -> String? {
        let expanded = text.hasPrefix("~/") ? environment.home + String(text.dropFirst()) : text
        guard expanded.hasPrefix("/"), !expanded.contains("/../") else { return nil }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    func executable(_ name: String) -> String? {
        (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .map { String($0) + "/" + name }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func words(_ text: String) -> [String]? { HookCommandWords.parse(text) }
}
