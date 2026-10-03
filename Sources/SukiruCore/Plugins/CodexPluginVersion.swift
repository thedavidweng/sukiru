import Foundation

/// Matches Codex's active-cache choice: local, otherwise semver or lexical order.
enum CodexPluginVersion {
    static func active(in directory: String) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        let versions = names.filter { name in
            guard name != ".", name != "..", !name.isEmpty,
                name.utf8.allSatisfy({ byte in
                    (48...57).contains(byte) || (65...90).contains(byte)
                        || (97...122).contains(byte) || [45, 95, 46, 43].contains(byte)
                })
            else { return false }
            let path = HostPathResolver.join(directory, name)
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return attributes?[.type] as? FileAttributeType == .typeDirectory
        }
        if versions.contains("local") { return "local" }
        return versions.sorted(by: less).last
    }

    private static func less(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = semantic(lhs), let right = semantic(rhs) else { return lhs < rhs }
        if left.numbers != right.numbers {
            return left.numbers.lexicographicallyPrecedes(right.numbers)
        }
        if left.prerelease.isEmpty { return false }
        if right.prerelease.isEmpty { return true }
        for (first, second) in zip(left.prerelease, right.prerelease) where first != second {
            let firstNumber = UInt64(first)
            let secondNumber = UInt64(second)
            if let firstNumber, let secondNumber { return firstNumber < secondNumber }
            if firstNumber != nil { return true }
            if secondNumber != nil { return false }
            return first < second
        }
        return left.prerelease.count < right.prerelease.count
    }

    private static func semantic(_ value: String) -> (numbers: [UInt64], prerelease: [String])? {
        let pattern =
            #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"#
            + #"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let version = value.split(separator: "+", maxSplits: 1)[0]
        let pieces = version.split(separator: "-", maxSplits: 1)
        let numbers = pieces[0].split(separator: ".").compactMap { UInt64($0) }
        guard numbers.count == 3 else { return nil }
        let prerelease = pieces.count == 2 ? pieces[1].split(separator: ".").map(String.init) : []
        guard
            !prerelease.contains(where: { token in
                token.utf8.allSatisfy { (48...57).contains($0) } && token.count > 1
                    && token.first == "0"
            })
        else { return nil }
        return (numbers, prerelease)
    }
}
