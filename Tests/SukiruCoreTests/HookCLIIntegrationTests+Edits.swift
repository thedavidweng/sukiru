import Foundation
import SukiruCore
import Testing

extension HookCLIIntegrationTests {
    @Test("Add appends a group in the file's indentation and rollback restores the bytes")
    func addIntoExistingFile() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let original = Self.settingsWithPermissions
        let source = try tree.file("home/.claude/settings.json", contents: original)
        let env = CLIRunner.fixtureEnvironment(home: home)
        let plan = try planEdits(
            [
                [
                    "action": "add", "host": "claude", "event": "PostToolUse",
                    "matcher": "Edit|Write",
                    "handler": ["type": "command", "command": "fmt", "timeout": 5]
                ]
            ], tree: tree, environment: env)
        let executed = try executePlan(plan, environment: env)
        #expect(executed.exitCode == 0, "\(String(bytes: executed.stderr, encoding: .utf8)!)")
        let expected = original.replacingOccurrences(
            of: "    ]\n  },\n  \"permissions\"",
            with: """
                    ],
                    "PostToolUse": [
                      {
                        "matcher": "Edit|Write",
                        "hooks": [
                          {
                            "type": "command",
                            "command": "fmt",
                            "timeout": 5
                          }
                        ]
                      }
                    ]
                  },
                  "permissions"
                """)
        #expect(try String(contentsOfFile: source, encoding: .utf8) == expected)
        let batchID = try #require(try executed.jsonObject()?["batchID"] as? String)
        let rollback = try CLIRunner.run(
            ["rollback", "--yes", "--batch", batchID], environment: env)
        #expect(rollback.exitCode == 0)
        #expect(try String(contentsOfFile: source, encoding: .utf8) == original)
    }

    @Test("Add creates a missing project settings file and rollback deletes it")
    func addIntoMissingFile() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let project = try tree.dir("project")
        let env = CLIRunner.fixtureEnvironment(home: home, roots: [project])
        let plan = try planEdits(
            [
                [
                    "action": "add", "host": "claude", "scope": "project", "scopeRoot": project,
                    "event": "SessionStart",
                    "handler": ["type": "command", "command": "echo hi"]
                ]
            ], tree: tree, environment: env)
        let executed = try executePlan(plan, environment: env)
        #expect(executed.exitCode == 0, "\(String(bytes: executed.stderr, encoding: .utf8)!)")
        let path = project + "/.claude/settings.json"
        #expect(
            try String(contentsOfFile: path, encoding: .utf8) == """
                {
                  "hooks": {
                    "SessionStart": [
                      {
                        "hooks": [
                          {
                            "type": "command",
                            "command": "echo hi"
                          }
                        ]
                      }
                    ]
                  }
                }

                """)
        let batchID = try #require(try executed.jsonObject()?["batchID"] as? String)
        let rollback = try CLIRunner.run(
            ["rollback", "--yes", "--batch", batchID], environment: env)
        #expect(rollback.exitCode == 0, "\(String(bytes: rollback.stderr, encoding: .utf8)!)")
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(!FileManager.default.fileExists(atPath: project + "/.claude"))
    }

    @Test("Add creates the hooks object in a four-space file without one")
    func addWithoutHooksKey() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let source = try tree.file(
            "home/.claude/settings.json", contents: "{\n    \"model\": \"opus\"\n}\n")
        let env = CLIRunner.fixtureEnvironment(home: home)
        let plan = try planEdits(
            [
                [
                    "action": "add", "host": "claude", "event": "Stop",
                    "handler": ["type": "command", "command": "say done"]
                ]
            ], tree: tree, environment: env)
        #expect(try executePlan(plan, environment: env).exitCode == 0)
        #expect(
            try String(contentsOfFile: source, encoding: .utf8) == """
                {
                    "model": "opus",
                    "hooks": {
                        "Stop": [
                            {
                                "hooks": [
                                    {
                                        "type": "command",
                                        "command": "say done"
                                    }
                                ]
                            }
                        ]
                    }
                }

                """)
    }

    @Test("Codex add fills an existing empty event array in a tab-indented hooks.json")
    func codexAddWithTabs() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let source = try tree.file(
            "home/.codex/hooks.json", contents: "{\n\t\"hooks\": {\n\t\t\"Stop\": []\n\t}\n}\n")
        let env = CLIRunner.fixtureEnvironment(home: home)
        let plan = try planEdits(
            [
                [
                    "action": "add", "host": "codex", "event": "Stop",
                    "handler": [
                        "type": "command", "command": "notify", "statusMessage": "Notifying"
                    ]
                ]
            ], tree: tree, environment: env)
        let saved = try JSONDecoder().decode(
            HookCleanupPlan.self, from: Data(contentsOf: URL(fileURLWithPath: plan)))
        #expect(saved.batch.commands.first?.warning?.contains("trust") == true)
        #expect(try executePlan(plan, environment: env).exitCode == 0)
        let expected = [
            "{", "\t\"hooks\": {", "\t\t\"Stop\": [", "\t\t\t{", "\t\t\t\t\"hooks\": [",
            "\t\t\t\t\t{", "\t\t\t\t\t\t\"type\": \"command\",",
            "\t\t\t\t\t\t\"command\": \"notify\",", "\t\t\t\t\t\t\"statusMessage\": \"Notifying\"",
            "\t\t\t\t\t}", "\t\t\t\t]", "\t\t\t}", "\t\t]", "\t}", "}", ""
        ].joined(separator: "\n")
        #expect(try String(contentsOfFile: source, encoding: .utf8) == expected)
    }

    @Test("Edit rewrites only the command, timeout, and matcher tokens of a compact file")
    func editCommandAndMatcher() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let original =
            #"{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "#
            + #""command": "rtk hook claude", "async": true}]}]}, "model": "opus"}"# + "\n"
        let source = try tree.file("home/.claude/settings.json", contents: original)
        let env = CLIRunner.fixtureEnvironment(home: home)
        let id = try hookID(command: "rtk hook claude", environment: env)
        let plan = try planEdits(
            [
                [
                    "action": "edit", "hookID": id, "matcher": "Bash|Zsh",
                    "handler": ["type": "command", "command": "rtk hook claude --v2", "timeout": 3]
                ]
            ], tree: tree, environment: env)
        #expect(try executePlan(plan, environment: env).exitCode == 0)
        let expected =
            #"{"hooks": {"PreToolUse": [{"matcher": "Bash|Zsh", "hooks": [{"type": "command", "#
            + #""command": "rtk hook claude --v2", "async": true, "timeout": 3}]}]}, "#
            + #""model": "opus"}"# + "\n"
        #expect(try String(contentsOfFile: source, encoding: .utf8) == expected)
    }

    @Test("A matcher edit in a shared group moves only that handler to a new group")
    func editSharedGroupMatcher() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let first = Self.sharedGroupFirstHandler
        let source = try tree.file("home/.codex/hooks.json", contents: Self.sharedGroupHooks)
        let env = CLIRunner.fixtureEnvironment(home: home)
        let id = try hookID(command: "lint", environment: env)
        let plan = try planEdits(
            [
                [
                    "action": "edit", "hookID": id, "matcher": "Bash",
                    "handler": [
                        "type": "command", "command": "lint --fix", "statusMessage": "Linting"
                    ]
                ]
            ], tree: tree, environment: env)
        #expect(try executePlan(plan, environment: env).exitCode == 0)
        #expect(
            try String(contentsOfFile: source, encoding: .utf8) == """
                {
                  "hooks": {
                    "PostToolUse": [
                      {
                        "matcher": "Edit|Write",
                        "hooks": [
                \(first)
                        ]
                      },
                      {
                        "matcher": "Bash",
                        "hooks": [
                          {
                            "type": "command",
                            "command": "lint --fix",
                            "statusMessage": "Linting"
                          }
                        ]
                      }
                    ]
                  }
                }

                """)
    }

    @Test("disableAllHooks is inserted, then removed back to the original bytes")
    func disableAllHooksToggle() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let original = "{\n  \"model\": \"opus\"\n}\n"
        let source = try tree.file("home/.claude/settings.json", contents: original)
        let env = CLIRunner.fixtureEnvironment(home: home)
        let disable = try planEdits(
            [["action": "set-disable-all", "path": source, "disableAllHooks": true]],
            tree: tree, environment: env)
        #expect(try executePlan(disable, environment: env).exitCode == 0)
        #expect(
            try String(contentsOfFile: source, encoding: .utf8)
                == "{\n  \"model\": \"opus\",\n  \"disableAllHooks\": true\n}\n")
        let repeated = try runPlan(
            [["action": "set-disable-all", "path": source, "disableAllHooks": true]],
            tree: tree, environment: env)
        #expect(repeated.exitCode != 0)
        let enable = try planEdits(
            [["action": "set-disable-all", "path": source, "disableAllHooks": false]],
            tree: tree, environment: env)
        #expect(try executePlan(enable, environment: env).exitCode == 0)
        #expect(try String(contentsOfFile: source, encoding: .utf8) == original)
    }

    func runPlan(
        _ requests: [[String: Any]], tree: TempTree, environment: [String: String]
    ) throws -> CLIRunner.Result {
        let path = tree.path + "/edit-requests.json"
        try JSONSerialization.data(withJSONObject: requests).write(to: URL(fileURLWithPath: path))
        return try CLIRunner.run(
            ["hooks", "plan", "--requests", path, "--json"], environment: environment)
    }

    func planEdits(
        _ requests: [[String: Any]], tree: TempTree, environment: [String: String]
    ) throws -> String {
        let result = try runPlan(requests, tree: tree, environment: environment)
        #expect(result.exitCode == 0, "\(String(bytes: result.stderr, encoding: .utf8)!)")
        let path = tree.path + "/edit-plan.json"
        try result.stdout.write(to: URL(fileURLWithPath: path))
        return path
    }

    func hookID(command: String, environment: [String: String]) throws -> String {
        let scan = try CLIRunner.run(["scan", "--json"], environment: environment)
        let report = try JSONDecoder().decode(ScanReport.self, from: scan.stdout)
        let hooks = try #require(report.hookInventory?.hooks)
        return try #require(hooks.first { $0.details["command"]?.stringValue == command }?.id)
    }

    private static let settingsWithPermissions = """
        {
          "model": "opus",
          "hooks": {
            "PreToolUse": [
              {
                "matcher": "Bash",
                "hooks": [
                  {
                    "type": "command",
                    "command": "rtk hook claude"
                  }
                ]
              }
            ]
          },
          "permissions": {
            "allow": ["Read"]
          }
        }

        """

    private static let sharedGroupFirstHandler = """
                  {
                    "type": "command",
                    "command": "fmt",
                    "timeout": 5,
                    "statusMessage": "Formatting"
                  }
        """

    private static let sharedGroupHooks = """
        {
          "hooks": {
            "PostToolUse": [
              {
                "matcher": "Edit|Write",
                "hooks": [
        \(sharedGroupFirstHandler),
                  {
                    "type": "command",
                    "command": "lint"
                  }
                ]
              }
            ]
          }
        }

        """
}
