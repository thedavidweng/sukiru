import Foundation

/// One parsed decision from the decisions file (finding ID → action +
/// optional choice).
public struct DecisionEntry: Equatable, Sendable {
    public let findingID: String
    public let action: DecisionAction
    public let choice: DecisionChoice?

    public init(findingID: String, action: DecisionAction, choice: DecisionChoice? = nil) {
        self.findingID = findingID
        self.action = action
        self.choice = choice
    }
}

/// A decisions-file shape error. Every message names the
/// offending finding ID and/or value so a hand-written file is fixable
/// without guessing.
public enum DecisionsFileError: Error, Equatable, Sendable {
    case notValidJSON
    case topLevelNotObject
    case entryNotObject(findingID: String)
    case missingAction(findingID: String)
    case unknownAction(findingID: String, action: String)
    case unknownKey(findingID: String, key: String)
    case missingChoice(findingID: String, action: DecisionAction)
    case unexpectedChoice(findingID: String, action: DecisionAction)
    case invalidChoice(findingID: String, action: DecisionAction, detail: String)

    /// Human-readable message written to stderr by the CLI (exit 1).
    public var message: String {
        switch self {
        case .notValidJSON:
            return "decisions file is not valid JSON"
        case .topLevelNotObject:
            return "decisions file must be a JSON object mapping finding IDs to decisions"
        case .entryNotObject(let findingID):
            return "decision for finding '\(findingID)' must be an object with an 'action'"
        case .missingAction(let findingID):
            return "decision for finding '\(findingID)' is missing its 'action' string"
        case .unknownAction(let findingID, let action):
            return "unknown action '\(action)' for finding '\(findingID)'; valid actions: "
                + DecisionAction.allCases.map(\.rawValue).joined(separator: ", ")
        case .unknownKey(let findingID, let key):
            return "unknown key '\(key)' in the decision for finding '\(findingID)'; "
                + "only 'action' and 'choice' are allowed"
        case .missingChoice(let findingID, let action):
            switch action {
            case .arbitrate:
                return "arbitrate on finding '\(findingID)' requires an explicit choice: "
                    + "'keep-vercel' or 'keep-github' (no default), or {\"keep\": "
                    + "\"<entry path>\"} for a name collision"
            case .adopt:
                return "adopt on finding '\(findingID)' requires a choice object with "
                    + "'source' (Vercel install source), or 'repo' (owner/repo) and 'path' "
                    + "(repo-relative skill path)"
            default:
                return "action '\(action.rawValue)' on finding '\(findingID)' requires a choice"
            }
        case .unexpectedChoice(let findingID, let action):
            return "action '\(action.rawValue)' on finding '\(findingID)' takes no choice"
        case .invalidChoice(let findingID, let action, let detail):
            return "invalid choice for action '\(action.rawValue)' on finding '\(findingID)': "
                + detail
        }
    }
}

/// Parses and validates the decisions file:
/// `{"<findingID>": {"action": "update|adopt|cleanup|leave|arbitrate|relink",
/// "choice": …}}`.
///
/// Validation here is shape-only (vocabulary, choice types); applicability to
/// the CURRENT scan (unknown or stale IDs, ownership routing rules) is the
/// CommandBatchBuilder's job.
public enum DecisionsFile {
    /// The keys allowed inside one decision entry.
    private static let entryKeys: Set<String> = Set(
        "action choice".split(separator: " ").map(String.init))

    /// Parses decisions-file bytes into entries, sorted by finding ID
    /// (the JSON object is unordered; the batch needs a defined order).
    public static func parse(_ data: Data) -> Result<[DecisionEntry], DecisionsFileError> {
        let root: JSONValue
        do {
            root = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            return .failure(.notValidJSON)
        }
        guard case .object(let object) = root else {
            return .failure(.topLevelNotObject)
        }
        var entries: [DecisionEntry] = []
        for findingID in object.keys.sorted() {
            guard let value = object[findingID] else { continue }
            switch parseEntry(findingID: findingID, value: value) {
            case .failure(let error):
                return .failure(error)
            case .success(let entry):
                entries.append(entry)
            }
        }
        return .success(entries)
    }

    private static func parseEntry(
        findingID: String, value: JSONValue
    ) -> Result<DecisionEntry, DecisionsFileError> {
        guard case .object(let entry) = value else {
            return .failure(.entryNotObject(findingID: findingID))
        }
        for key in entry.keys where !entryKeys.contains(key) {
            return .failure(.unknownKey(findingID: findingID, key: key))
        }
        guard let actionValue = entry["action"] else {
            return .failure(.missingAction(findingID: findingID))
        }
        guard let actionName = actionValue.stringValue,
            let action = DecisionAction(rawValue: actionName)
        else {
            let raw = actionValue.stringValue ?? "(not a string)"
            return .failure(.unknownAction(findingID: findingID, action: raw))
        }
        let choice = entry["choice"]
        switch action {
        case .update, .cleanup, .leave, .relink:
            if choice != nil {
                return .failure(.unexpectedChoice(findingID: findingID, action: action))
            }
            return .success(DecisionEntry(findingID: findingID, action: action))
        case .arbitrate:
            guard let choice else {
                return .failure(.missingChoice(findingID: findingID, action: action))
            }
            return parseArbitrationChoice(findingID: findingID, choice: choice)
        case .adopt:
            guard let choice else {
                return .failure(.missingChoice(findingID: findingID, action: action))
            }
            return parseAdoptChoice(findingID: findingID, choice: choice)
        }
    }

    private static func parseArbitrationChoice(
        findingID: String, choice: JSONValue
    ) -> Result<DecisionEntry, DecisionsFileError> {
        let detail =
            "expected the string 'keep-vercel' or 'keep-github', or {\"keep\": \"<entry path>\"}"
        if case .object(let object) = choice {
            guard object.count == 1, let path = object["keep"]?.stringValue, !path.isEmpty else {
                return .failure(
                    .invalidChoice(findingID: findingID, action: .arbitrate, detail: detail))
            }
            return .success(
                DecisionEntry(
                    findingID: findingID, action: .arbitrate, choice: .keepEntry(path: path)))
        }
        guard let value = choice.stringValue else {
            return .failure(
                .invalidChoice(findingID: findingID, action: .arbitrate, detail: detail))
        }
        switch value {
        case "keep-vercel":
            return .success(
                DecisionEntry(findingID: findingID, action: .arbitrate, choice: .keepVercel))
        case "keep-github":
            return .success(
                DecisionEntry(findingID: findingID, action: .arbitrate, choice: .keepGitHub))
        default:
            return .failure(
                .invalidChoice(
                    findingID: findingID, action: .arbitrate,
                    detail: "'\(value)' is not one of 'keep-vercel' or 'keep-github'"))
        }
    }

    private static func parseAdoptChoice(
        findingID: String, choice: JSONValue
    ) -> Result<DecisionEntry, DecisionsFileError> {
        guard case .object(let object) = choice else {
            return .failure(
                .invalidChoice(
                    findingID: findingID, action: .adopt,
                    detail: "expected an object with 'source', or 'repo' (owner/repo) and "
                        + "'path'"))
        }
        if let source = object["source"] {
            guard object.count == 1, let value = source.stringValue, !value.isEmpty else {
                return .failure(
                    .invalidChoice(
                        findingID: findingID, action: .adopt,
                        detail: "'source' must be a non-empty string and the only key"))
            }
            return .success(
                DecisionEntry(
                    findingID: findingID, action: .adopt, choice: .adoptVercel(source: value)))
        }
        for key in object.keys where key != "repo" && key != "path" {
            return .failure(
                .invalidChoice(
                    findingID: findingID, action: .adopt,
                    detail: "unknown key '\(key)'; only 'repo' and 'path' are allowed"))
        }
        guard let repo = object["repo"]?.stringValue, !repo.isEmpty else {
            return .failure(
                .invalidChoice(
                    findingID: findingID, action: .adopt,
                    detail: "missing or empty 'repo' (expected owner/repo)"))
        }
        guard let path = object["path"]?.stringValue, !path.isEmpty else {
            return .failure(
                .invalidChoice(
                    findingID: findingID, action: .adopt,
                    detail: "missing or empty 'path' (repo-relative skill path)"))
        }
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            return .failure(
                .invalidChoice(
                    findingID: findingID, action: .adopt,
                    detail: "'repo' must be in owner/repo shape, got '\(repo)'"))
        }
        return .success(
            DecisionEntry(
                findingID: findingID, action: .adopt,
                choice: .adoptSource(repo: repo, path: path)))
    }
}
