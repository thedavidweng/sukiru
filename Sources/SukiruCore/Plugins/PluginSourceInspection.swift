import Foundation

/// Removes comments and string literals for conservative static shape checks.
enum PluginSourceInspection {
    static func code(_ text: String) -> String {
        let characters = Array(text)
        var result = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if ["\"", "'", "`"].contains(character) {
                let quote = character
                index += 1
                skipString(characters, quote: quote, index: &index)
                result += " "
            } else if character == "/", next == "/" {
                index += 2
                while index < characters.count && characters[index] != "\n" { index += 1 }
            } else if character == "/", next == "*" {
                index += 2
                while index + 1 < characters.count {
                    if characters[index] == "*", characters[index + 1] == "/" {
                        index += 2
                        break
                    }
                    if characters[index] == "\n" { result += "\n" }
                    index += 1
                }
                result += " "
            } else {
                result.append(character)
                index += 1
            }
        }
        return result
    }

    private static func skipString(_ characters: [Character], quote: Character, index: inout Int) {
        while index < characters.count {
            if characters[index] == "\\" {
                index += 2
                continue
            }
            let closing = characters[index] == quote
            index += 1
            if closing { break }
        }
    }
}
