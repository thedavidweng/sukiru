import Foundation

/// JSON token ranges retain all unrelated bytes. Duplicate keys are ambiguous and refused.
struct HookJSONDocument {
    struct Member {
        let key: String?
        let range: Range<Int>
        let node: Node
    }
    struct Node {
        let members: [Member]
        func member(_ key: String) -> Node? { members.first { $0.key == key }?.node }
    }
    let bytes: [UInt8]
    let root: Node

    init(_ data: Data) throws {
        _ = try JSONDecoder().decode(JSONValue.self, from: data)
        bytes = Array(data)
        var parser = Parser(bytes: bytes)
        root = try parser.node()
    }

    func removing(_ hooks: [AgentHook]) throws -> Data {
        guard let container = root.member("hooks") else { throw HookError("Missing hooks object") }
        var edits: [Range<Int>] = []
        var emptyEvents: Set<Int> = []
        for (eventIndex, event) in container.members.enumerated() {
            let selected = hooks.filter { $0.event == event.key }
            guard !selected.isEmpty else { continue }
            var emptyGroups: Set<Int> = []
            for (groupIndex, group) in event.node.members.enumerated() {
                let indices = Set(
                    selected.filter { $0.groupIndex == groupIndex }.map(\.handlerIndex))
                guard !indices.isEmpty, let handlers = group.node.member("hooks"),
                    indices.allSatisfy({ handlers.members.indices.contains($0) })
                else {
                    if indices.isEmpty { continue }
                    throw HookError("Hook structure changed; rescan and replan")
                }
                if indices.count == handlers.members.count {
                    emptyGroups.insert(groupIndex)
                } else {
                    edits += removals(in: handlers, indices: indices)
                }
            }
            if emptyGroups.count == event.node.members.count {
                emptyEvents.insert(eventIndex)
            } else {
                edits += removals(in: event.node, indices: emptyGroups)
            }
        }
        if emptyEvents.count == container.members.count {
            let index = root.members.firstIndex(where: { $0.key == "hooks" })!
            edits += removals(in: root, indices: [index])
        } else {
            edits += removals(in: container, indices: emptyEvents)
        }
        var result = bytes
        for range in edits.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            result.removeSubrange(range)
        }
        _ = try HookJSONDocument(Data(result))
        return Data(result)
    }

    private func removals(in node: Node, indices: Set<Int>) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var index = 0
        while index < node.members.count {
            guard indices.contains(index) else {
                index += 1
                continue
            }
            let start = index
            while index + 1 < node.members.count && indices.contains(index + 1) { index += 1 }
            let end = index
            if end + 1 < node.members.count {
                ranges.append(
                    node.members[start].range.lowerBound..<node.members[end + 1].range.lowerBound)
            } else if start > 0 {
                ranges.append(
                    node.members[start - 1].range.upperBound..<node.members[end].range.upperBound)
            } else {
                ranges.append(
                    node.members[start].range.lowerBound..<node.members[end].range.upperBound)
            }
            index += 1
        }
        return ranges
    }

    private struct Parser {
        let bytes: [UInt8]
        var offset = 0

        mutating func whitespace() {
            while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
        }

        mutating func string() throws -> String {
            let start = offset
            offset += 1
            while offset < bytes.count {
                if bytes[offset] == 92 {
                    offset += 2
                    continue
                }
                if bytes[offset] == 34 {
                    offset += 1
                    return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset]))
                }
                offset += 1
            }
            throw HookError("Unterminated JSON string")
        }

        mutating func node() throws -> Node {
            whitespace()
            let token = bytes[offset]
            var members: [Member] = []
            if token == 123 || token == 91 {
                offset += 1
                whitespace()
                let closing: UInt8 = token == 123 ? 125 : 93
                var keys: Set<String> = []
                while bytes[offset] != closing {
                    let memberStart = offset
                    var key: String?
                    if token == 123 {
                        key = try string()
                        guard keys.insert(key!).inserted else {
                            throw HookError("Duplicate JSON key: " + key!)
                        }
                        whitespace()
                        offset += 1
                    }
                    let child = try node()
                    members.append(Member(key: key, range: memberStart..<offset, node: child))
                    whitespace()
                    if bytes[offset] == 44 {
                        offset += 1
                        whitespace()
                    } else {
                        break
                    }
                }
                offset += 1
            } else if token == 34 {
                _ = try string()
            } else {
                let delimiters: Set<UInt8> = [9, 10, 13, 32, 44, 93, 125]
                while offset < bytes.count && !delimiters.contains(bytes[offset]) {
                    offset += 1
                }
            }
            return Node(members: members)
        }
    }
}
