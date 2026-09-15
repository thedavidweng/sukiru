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

    @Test("No command is a usage error")
    func noCommand() {
        #expect(CLIParser.parse([]) == .failure(.noCommand))
    }

    @Test("Unknown command is a usage error")
    func unknownCommand() {
        #expect(CLIParser.parse(["frobnicate"]) == .failure(.unknownCommand("frobnicate")))
    }
}
