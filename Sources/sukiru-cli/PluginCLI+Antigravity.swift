extension CLI {
    static let antigravityPluginCommands: [CLICommand] = [
        CLICommand(
            path: "plugins import",
            abstract: "Import plugins through Antigravity's native interface.",
            options: pluginOperationOptions,
            argument: CLIPositional(
                name: "source", required: false,
                help:
                    "gemini or claude; omitted imports both sources. Other targets are passed to the host."
            )
        ) { arguments in
            var options = try PluginOperationOptions(arguments, defaultTarget: "*")
            if options.inputs.host == nil { options.inputs.host = "antigravity" }
            try options.run(action: "import")
        },
        CLICommand(
            path: "plugins validate",
            abstract: "Validate an Antigravity plugin's manifest and components.",
            options: pluginOperationOptions,
            argument: CLIPositional(
                name: "path", required: false,
                help: "Plugin directory or plugin.json; defaults to the selected scope root.")
        ) { arguments in
            var options = try PluginOperationOptions(arguments, defaultTarget: ".")
            if options.inputs.host == nil { options.inputs.host = "antigravity" }
            try options.run(action: "validate")
        },
        CLICommand(
            path: "plugins link",
            abstract: "Generate an Antigravity marketplace link through the host.",
            options: pluginOperationOptions,
            argument: CLIPositional(
                name: "target", required: true, help: "Host-supported marketplace target.")
        ) { arguments in
            var options = try PluginOperationOptions(arguments)
            if options.inputs.host == nil { options.inputs.host = "antigravity" }
            try options.run(action: "link")
        },
        CLICommand(
            path: "plugins inspect",
            abstract: "Run the host's explicit plugin list and retain its transcript.",
            options: pluginOperationOptions
        ) { arguments in
            try PluginOperationOptions(arguments, defaultTarget: "*").run(action: "list")
        }
    ]
}
