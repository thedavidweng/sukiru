import Foundation

/// Tokenizes only literal shell words. Unsupported expressions have no static target verdict.
struct HookCommandWords {
    private var result: [String] = []
    private var current = ""
    private var quote: Character?
    private var escaped = false
    private var wordStarted = false

    static func parse(_ text: String) -> [String]? {
        var parser = Self()
        for char in text {
            guard parser.consume(char) else { return nil }
        }
        guard parser.quote == nil, !parser.escaped else { return nil }
        parser.finishWord()
        return parser.result
    }

    private mutating func consume(_ char: Character) -> Bool {
        if escaped {
            if char == "\n" { return false }
            if current.isEmpty && char == "~" { return false }
            current.append(char)
            escaped = false
        } else if char == "\\", quote != "'" {
            if quote == "\"" { return false }
            escaped = true
        } else if let delimiter = quote {
            return quoted(char, delimiter: delimiter)
        } else {
            return unquoted(char)
        }
        return true
    }

    private mutating func quoted(_ char: Character, delimiter: Character) -> Bool {
        if current.isEmpty && char == "~" { return false }
        if char == delimiter {
            quote = nil
        } else if delimiter == "\"", "$`".contains(char) {
            return false
        } else {
            current.append(char)
        }
        return true
    }

    private mutating func unquoted(_ char: Character) -> Bool {
        if char == "'" || char == "\"" {
            if current.hasPrefix("~") { return false }
            wordStarted = true
            quote = char
        } else if "$`|;&<>\n(){}*?[]".contains(char) {
            return false
        } else if char.isWhitespace {
            finishWord()
        } else {
            if char == "~" && current.isEmpty && wordStarted { return false }
            wordStarted = true
            current.append(char)
        }
        return true
    }

    private mutating func finishWord() {
        if wordStarted || !current.isEmpty {
            result.append(current)
            current = ""
            wordStarted = false
        }
    }
}
