import Foundation

/// Remove comments and trailing commas without changing string contents.
enum PluginJSONC {
    static func data(_ text: String) -> Data {
        let chars = Array(text)
        var result = ""
        var index = 0
        var quoted = false
        var escaped = false
        while index < chars.count {
            let char = chars[index]
            if quoted {
                result.append(char)
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    quoted = false
                }
                index += 1
            } else if char == "\"" {
                quoted = true
                result.append(char)
                index += 1
            } else if let end = commentEnd(chars, at: index) {
                index = end
                result.append(" ")
            } else if char == "," {
                let next = nextContent(chars, after: index)
                if next >= chars.count || (chars[next] != "}" && chars[next] != "]") {
                    result.append(char)
                }
                index += 1
            } else {
                result.append(char)
                index += 1
            }
        }
        return Data(result.utf8)
    }
    private static func commentEnd(_ chars: [Character], at index: Int) -> Int? {
        guard chars[index] == "/", index + 1 < chars.count else { return nil }
        var end = index + 2
        if chars[index + 1] == "/" {
            while end < chars.count, chars[end] != "\n" { end += 1 }
            return end
        }
        if chars[index + 1] == "*" {
            while end + 1 < chars.count, !(chars[end] == "*" && chars[end + 1] == "/") { end += 1 }
            guard end + 1 < chars.count else { return nil }
            return end + 2
        }
        return nil
    }

    private static func nextContent(_ chars: [Character], after index: Int) -> Int {
        var next = index + 1
        while next < chars.count {
            if chars[next].isWhitespace {
                next += 1
            } else if let end = commentEnd(chars, at: next) {
                next = end
            } else {
                break
            }
        }
        return next
    }
}
