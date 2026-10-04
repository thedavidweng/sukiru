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
        let command = details["command"]?.stringValue
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
        if let command, isOrcaRuntimeWrapper(command, host: source.host) {
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
                evidence: ["Orca runtime-home wrapper with guarded producer payload invocation"],
                producerPresent: installed),
            health: installed ? .externallyManaged : .leftover,
            evidence: ["Runtime HOME target existence is unknown"]
                + (installed
                    ? ["Producer may regenerate these hooks"]
                    : ["Producer application/executable is absent"]),
            targets: [])
    }

    private func isOrcaRuntimeWrapper(_ command: String, host: PluginHost) -> Bool {
        let script = host == .claude ? "claude-hook" : "codex-hook"
        let target = "\"${HOME-}/.orca/agent-hooks/\(script).sh\""
        return command.hasPrefix("if [ -z \"${HOME-}\" ]; then ")
            && command.contains("[ -f \(target) ] && [ -r \(target) ] && [ -x \(target) ]")
            && command.contains("/bin/sh " + target)
            && command.hasSuffix(";; esac; fi")
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
