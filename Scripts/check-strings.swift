// Fails when a String Catalog has stale strings or strings missing a
// translation in any language the catalog ships.
// Usage: xcrun swift Scripts/check-strings.swift <catalog.xcstrings>…
import Foundation

var problems: [String] = []

for path in CommandLine.arguments.dropFirst() {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let strings = catalog["strings"] as? [String: [String: Any]],
        let source = catalog["sourceLanguage"] as? String
    else {
        problems.append("\(path): not a String Catalog")
        continue
    }
    var languages = Set<String>()
    for entry in strings.values {
        let localizations = entry["localizations"] as? [String: Any] ?? [:]
        languages.formUnion(localizations.keys)
    }
    languages.remove(source)

    for (key, entry) in strings.sorted(by: { $0.key < $1.key }) {
        if entry["extractionState"] as? String == "stale" {
            problems.append("\(path): stale \"\(key)\"")
            continue
        }
        if entry["shouldTranslate"] as? Bool == false {
            continue
        }
        let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
        for language in languages.sorted() {
            let localization = localizations[language]
            let unit = localization?["stringUnit"] as? [String: Any]
            let translated =
                unit?["state"] as? String == "translated"
                || localization?["variations"] != nil
                || localization?["substitutions"] != nil
            if !translated {
                problems.append("\(path): \"\(key)\" lacks a \(language) translation")
            }
        }
    }
}

for problem in problems {
    FileHandle.standardError.write(Data((problem + "\n").utf8))
}
exit(problems.isEmpty ? 0 : 1)
