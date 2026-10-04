import Foundation

/// Supported array-table hooks keep their original text blocks, comments, and order.
/// Other hook representations are reported for host inspection, never approximated.
struct HookTOMLDocument {
    struct Handler {
        let event: String
        let group: Int
        let index: Int
        var details: [String: JSONValue]
        var lines: Range<Int>
    }
    struct Group {
        let event: String
        let index: Int
        var matcher: String?
        var lines: Range<Int>
    }
    let lines: [String]
    var groups: [Group] = []
    var handlers: [Handler] = []

    private struct Cursor {
        var group: Int?
        var handler: Int?
        var nestedInput = false
        var unrelatedTable = false
        var hooksTable = false
    }

    init(_ data: Data) throws {
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw HookError("Hook TOML is not UTF-8")
        }
        lines = text.components(separatedBy: "\n")
        var cursor = Cursor()
        for (index, raw) in lines.enumerated() {
            let line = Self.withoutComment(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                try table(line, at: index, cursor: &cursor)
            } else if let group = cursor.group {
                try field(line, group: group, cursor: cursor)
            } else if !cursor.unrelatedTable {
                try rootField(line, hooksTable: cursor.hooksTable)
            }
        }
        for group in groups
        where !handlers.contains(where: { $0.event == group.event && $0.group == group.index }) {
            throw HookError("Hook group has no handlers: " + group.event)
        }
    }

    private mutating func table(_ line: String, at index: Int, cursor: inout Cursor) throws {
        if let handler = cursor.handler {
            handlers[handler].lines = handlers[handler].lines.lowerBound..<index
        }
        if let group = cursor.group { groups[group].lines = groups[group].lines.lowerBound..<index }
        let previousHandler = cursor.handler
        cursor.handler = nil
        cursor.nestedInput = false
        cursor.hooksTable = line == "[hooks]"
        cursor.unrelatedTable = !line.hasPrefix("[hooks") && !line.hasPrefix("[[hooks")
        if line.hasPrefix("[[hooks."), line.hasSuffix("]]") {
            try arrayTable(line, at: index, cursor: &cursor)
        } else if let previousHandler, isInputTable(line, cursor: cursor) {
            let group = cursor.group!
            cursor.handler = previousHandler
            cursor.nestedInput = true
            handlers[previousHandler].lines =
                handlers[previousHandler].lines.lowerBound..<lines.count
            groups[group].lines = groups[group].lines.lowerBound..<lines.count
        } else {
            cursor.group = nil
            if line != "[hooks]", !cursor.unrelatedTable {
                throw HookError("Unsupported inline hook representation; inspect in Codex")
            }
        }
    }

    private mutating func arrayTable(_ line: String, at index: Int, cursor: inout Cursor) throws {
        let parts = line.dropFirst(8).dropLast(2).split(separator: ".").map(String.init)
        guard let event = parts.first, event.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
        else {
            throw HookError("Unsupported hook table; inspect in Codex")
        }
        if parts.count == 1 {
            groups.append(
                Group(
                    event: event, index: groups.filter { $0.event == event }.count,
                    lines: index..<lines.count))
            cursor.group = groups.count - 1
        } else if let group = cursor.group, parts == [event, "hooks"] {
            guard groups[group].event == event else { throw HookError("Hook table event mismatch") }
            groups[group].lines = groups[group].lines.lowerBound..<lines.count
            let count = handlers.filter { $0.event == event && $0.group == groups[group].index }
                .count
            handlers.append(
                Handler(
                    event: event, group: groups[group].index, index: count, details: [:],
                    lines: index..<lines.count))
            cursor.handler = handlers.count - 1
        } else {
            throw HookError("Unsupported hook table nesting; inspect in Codex")
        }
    }

    private func isInputTable(_ line: String, cursor: Cursor) -> Bool {
        guard let group = cursor.group else { return false }
        return line == "[hooks.\(groups[group].event).hooks.input]"
    }

    private mutating func field(_ line: String, group: Int, cursor: Cursor) throws {
        guard let equal = line.firstIndex(of: "=") else {
            throw HookError("Malformed hook TOML field")
        }
        let key = line[..<equal].trimmingCharacters(in: .whitespaces)
        let value = try Self.value(
            String(line[line.index(after: equal)...]).trimmingCharacters(in: .whitespaces))
        if let handler = cursor.handler {
            try handlerField(key: key, value: value, index: handler, input: cursor.nestedInput)
        } else if key == "matcher" {
            guard groups[group].matcher == nil, let matcher = value.stringValue else {
                throw HookError("Invalid hook matcher")
            }
            groups[group].matcher = matcher
        } else {
            throw HookError("Unsupported hook group field: " + key)
        }
    }

    private mutating func handlerField(
        key: String, value: JSONValue, index: Int, input: Bool
    ) throws {
        if input {
            var fields = handlers[index].details["input"]?.objectValue ?? [:]
            guard fields[key] == nil else { throw HookError("Duplicate hook input field") }
            fields[key] = value
            handlers[index].details["input"] = .object(fields)
        } else {
            guard handlers[index].details[key] == nil else {
                throw HookError("Duplicate hook handler field")
            }
            handlers[index].details[key] = value
        }
    }

    private func rootField(_ line: String, hooksTable: Bool) throws {
        let key =
            line.split(separator: "=", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if hooksTable || key == "hooks" || key.hasPrefix("hooks.") {
            throw HookError("Inline hook objects require inspection in Codex")
        }
    }

    func removing(_ selected: [AgentHook]) -> Data {
        var removed: Set<Int> = []
        for group in groups {
            let members = handlers.filter { $0.event == group.event && $0.group == group.index }
            let chosen = members.filter { handler in
                selected.contains {
                    $0.event == handler.event && $0.groupIndex == handler.group
                        && $0.handlerIndex == handler.index
                }
            }
            if !chosen.isEmpty && chosen.count == members.count {
                removed.formUnion(group.lines)
            } else {
                for handler in chosen { removed.formUnion(handler.lines) }
            }
        }
        let preserved = lines.enumerated().filter {
            !removed.contains($0.offset)
                || $0.element.trimmingCharacters(in: .whitespaces).hasPrefix("#")
        }
        return Data(
            preserved.map(\.element).joined(
                separator: "\n"
            ).utf8)
    }

    static func value(_ text: String) throws -> JSONValue {
        if text.hasPrefix("'"), text.hasSuffix("'"), !text.hasPrefix("'''") {
            return .string(String(text.dropFirst().dropLast()))
        }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else {
            throw HookError("Unsupported hook TOML value; source is read-only")
        }
        return value
    }

    static func withoutComment(_ text: String) -> String {
        var quote: Character?
        var escaped = false
        for index in text.indices {
            let char = text[index]
            if escaped {
                escaped = false
                continue
            }
            if char == "\\", quote == "\"" {
                escaped = true
                continue
            }
            if let current = quote {
                if char == current { quote = nil }
            } else if char == "\"" || char == "'" {
                quote = char
            } else if char == "#" {
                return String(text[..<index])
            }
        }
        return text
    }
}
