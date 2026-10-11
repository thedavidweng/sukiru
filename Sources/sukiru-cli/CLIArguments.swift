import Foundation
import SukiruCore

struct CLIArguments: Sendable {
    private var optionValues: [String: [String]] = [:]
    private var flags: Set<String> = []
    private(set) var positionals: [String] = []
    private(set) var errors: [String] = []

    var positional: String? { positionals.first }
    func flag(_ name: String) -> Bool { flags.contains(name) }
    func string(_ name: String) -> String? { optionValues[name]?.last }
    func values(_ name: String) -> [String] { optionValues[name] ?? [] }

    func required(_ name: String) throws -> String {
        guard let value = string(name) else {
            throw CLIUsageError("Missing expected argument '--\(name) <\(name)>'")
        }
        return value
    }

    func requiredPositional() throws -> String {
        guard let positional else { throw CLIUsageError("Missing expected argument") }
        return positional
    }

    func integer(_ name: String, default defaultValue: Int) -> Int {
        guard let text = string(name) else { return defaultValue }
        return Int(text)!
    }

    func double(_ name: String) -> Double? {
        guard let text = string(name) else { return nil }
        return Double(text)!
    }

    func enumeration<Value: RawRepresentable>(
        _ name: String, default defaultValue: Value? = nil
    ) throws -> Value where Value.RawValue == String {
        if string(name) == nil, let defaultValue { return defaultValue }
        return Value(rawValue: try required(name))!
    }

    init(_ tokens: [String], options: [CLIOption]) throws {
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            if token == "--" {
                positionals += tokens[index...]
                break
            }
            if token.hasPrefix("--") {
                try consumeLong(token, tokens: tokens, index: &index, options: options)
            } else if token.hasPrefix("-"), token != "-" {
                try consumeShort(token, options: options)
            } else {
                positionals.append(token)
            }
        }
    }

    private mutating func consumeLong(
        _ token: String, tokens: [String], index: inout Int, options: [CLIOption]
    ) throws {
        let parts = token.dropFirst(2).split(
            separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(parts[0])
        if name == "help" || name == "help-hidden" || name == "version" {
            flags.insert(name == "help-hidden" ? "help" : name)
            return
        }
        let supplied = parts.count == 2 ? String(parts[1]) : nil
        let option = options.first { $0.name == name }
        guard let option else {
            errors.append("Unknown option '\(token)'")
            return
        }
        if option.takesValue {
            let value: String
            if let supplied {
                value = supplied
            } else {
                guard index < tokens.count,
                    !tokens[index].hasPrefix("-") || tokens[index] == "-"
                else {
                    throw CLIUsageError("Missing value for '--\(name) <\(name)>'")
                }
                value = tokens[index]
                index += 1
            }
            try validateValue(value, option: name)
            optionValues[name, default: []].append(value)
        } else if let supplied {
            throw CLIUsageError(
                "The option '--\(name)' does not take any value, but '\(supplied)' was specified.")
        } else {
            flags.insert(name)
        }
    }

    private func validateValue(_ value: String, option: String) throws {
        let valid: Bool
        switch option {
        case "scope": valid = Scope(rawValue: value) != nil
        case "installer": valid = InstallerChoice(rawValue: value) != nil
        case "mode": valid = PlacementMode(rawValue: value) != nil
        case "backend": valid = SkillSearchResult.Backend(rawValue: value) != nil
        case "limit": valid = Int(value) != nil
        case "command-timeout": valid = Double(value) != nil
        default: return
        }
        if !valid { throw CLIUsageError("Invalid value '\(value)' for '--\(option)'") }
    }

    private mutating func consumeShort(_ token: String, options: [CLIOption]) throws {
        if let separator = token.firstIndex(of: "=") {
            let name = String(token[..<separator])
            if name == "-h" {
                flags.insert("help")
            } else if name == "-y", options.contains(where: { $0.name == "yes" }) {
                throw CLIUsageError("The option '-y' does not take any value.")
            } else {
                errors.append("Unknown option '\(name)'")
            }
            return
        }
        for character in token.dropFirst() {
            if character == "h" {
                flags.insert("help")
            } else if character == "y", options.contains(where: { $0.name == "yes" }) {
                flags.insert("yes")
            } else {
                errors.append("Unknown option '-\(character)'")
            }
        }
    }
}

struct CLIUsageError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

struct CLIExit: Error {
    let code: Int32
    init(_ code: Int32) { self.code = code }
}
