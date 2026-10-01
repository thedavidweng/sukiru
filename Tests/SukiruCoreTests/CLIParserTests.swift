import Testing

@testable import SukiruCore

@Suite("CLIParser argument parsing")
struct CLIParserTests {
    @Test("Bare scan defaults to scope all and json format")
    func scanDefaults() {
        #expect(CLIParser.parse(["scan"]) == .success(.scan(roots: [], scope: .all, format: .json)))
    }

    @Test("Repeated --root flags accumulate in order")
    func scanRoots() {
        let parsed = CLIParser.parse(["scan", "--root", "/a", "--root", "/b"])
        #expect(parsed == .success(.scan(roots: ["/a", "/b"], scope: .all, format: .json)))
    }

    @Test("--scope accepts user, project, all")
    func scanScope() {
        #expect(
            CLIParser.parse(["scan", "--scope", "user"])
                == .success(.scan(roots: [], scope: .user, format: .json))
        )
        #expect(
            CLIParser.parse(["scan", "--scope", "project"])
                == .success(.scan(roots: [], scope: .project, format: .json))
        )
    }

    @Test("--format json is accepted for scan")
    func scanFormat() {
        #expect(
            CLIParser.parse(["scan", "--format", "json"])
                == .success(.scan(roots: [], scope: .all, format: .json))
        )
    }

    @Test("Invalid --scope value is a usage error")
    func scanInvalidScope() {
        #expect(
            CLIParser.parse(["scan", "--scope", "bogus"])
                == .failure(.invalidValue(flag: "--scope", value: "bogus"))
        )
    }

    @Test("Unknown scan flag is a usage error")
    func scanUnknownFlag() {
        #expect(
            CLIParser.parse(["scan", "--frobnicate"])
                == .failure(.unknownFlag(command: "scan", flag: "--frobnicate"))
        )
    }

    @Test("--root without a value is a usage error")
    func scanMissingRootValue() {
        #expect(CLIParser.parse(["scan", "--root"]) == .failure(.missingValue(flag: "--root")))
    }

    @Test("capabilities parses with and without --format")
    func capabilities() {
        #expect(CLIParser.parse(["capabilities"]) == .success(.capabilities(format: .json)))
        #expect(
            CLIParser.parse(["capabilities", "--format", "json"])
                == .success(.capabilities(format: .json))
        )
    }

    @Test("Unknown capabilities flag is a usage error")
    func capabilitiesUnknownFlag() {
        #expect(
            CLIParser.parse(["capabilities", "--verbose"])
                == .failure(.unknownFlag(command: "capabilities", flag: "--verbose"))
        )
    }

    // MARK: - batch execution flags

    @Test("batch --execute --reviewed parses; timeout only with --execute")
    func batchExecuteFlags() {
        let plain = CLICommand.batch(
            decisionsFile: "d.json", dryRun: false, execute: true, reviewed: true,
            commandTimeout: nil, roots: [], scope: .all, format: .json)
        #expect(
            CLIParser.parse(["batch", "--decisions", "d.json", "--execute", "--reviewed"])
                == .success(plain)
        )
        let timed = CLICommand.batch(
            decisionsFile: "d.json", dryRun: false, execute: true, reviewed: true,
            commandTimeout: 2.5, roots: [], scope: .all, format: .json)
        let base = ["batch", "--decisions", "d.json", "--execute", "--reviewed"]
        #expect(CLIParser.parse(base + ["--command-timeout", "2.5"]) == .success(timed))
    }

    @Test("batch --execute alone parses (review refusal happens at run time)")
    func batchExecuteWithoutReviewParses() {
        let expected = CLICommand.batch(
            decisionsFile: "d.json", dryRun: false, execute: true, reviewed: false,
            commandTimeout: nil, roots: [], scope: .all, format: .json)
        #expect(
            CLIParser.parse(["batch", "--decisions", "d.json", "--execute"])
                == .success(expected)
        )
    }

    @Test("conflicting batch flags are usage errors")
    func batchInvalidCombinations() {
        let both = CLIParser.parse(["batch", "--decisions", "d.json", "--dry-run", "--execute"])
        let conflict = CLIParseError.invalidCombination(
            command: "batch", detail: "--dry-run and --execute are mutually exclusive")
        #expect(both == .failure(conflict))
        let reviewOnly = CLIParser.parse(["batch", "--decisions", "d.json", "--reviewed"])
        let needsExecute = CLIParseError.invalidCombination(
            command: "batch", detail: "--reviewed requires --execute")
        #expect(reviewOnly == .failure(needsExecute))
        let timeoutOnly = CLIParser.parse(
            ["batch", "--decisions", "d.json", "--command-timeout", "5"])
        let misplaced = CLIParseError.invalidCombination(
            command: "batch", detail: "--command-timeout requires --execute")
        #expect(timeoutOnly == .failure(misplaced))
        let badTimeout = CLIParser.parse(
            ["batch", "--decisions", "d.json", "--execute", "--command-timeout", "abc"])
        #expect(badTimeout == .failure(.invalidValue(flag: "--command-timeout", value: "abc")))
    }

    // MARK: - rollback (one-click rollback surface)

    @Test("rollback --batch parses")
    func rollbackParses() {
        #expect(
            CLIParser.parse(["rollback", "--batch", "b-1"])
                == .success(.rollback(batchID: "b-1", format: .json))
        )
        #expect(
            CLIParser.parse(["rollback", "--batch", "b-1", "--format", "json"])
                == .success(.rollback(batchID: "b-1", format: .json))
        )
    }

    @Test("rollback without --batch is a usage error")
    func rollbackRequiresBatch() {
        #expect(
            CLIParser.parse(["rollback"])
                == .failure(.missingFlag(command: "rollback", flag: "--batch"))
        )
    }

    @Test("Unknown rollback flag is a usage error")
    func rollbackUnknownFlag() {
        #expect(
            CLIParser.parse(["rollback", "--batch", "b-1", "--verbose"])
                == .failure(.unknownFlag(command: "rollback", flag: "--verbose"))
        )
    }

    @Test("No command is a usage error")
    func noCommand() {
        #expect(CLIParser.parse([]) == .failure(.noCommand))
    }

    @Test("Unknown command is a usage error")
    func unknownCommand() {
        #expect(CLIParser.parse(["frobnicate"]) == .failure(.unknownCommand("frobnicate")))
    }
}
