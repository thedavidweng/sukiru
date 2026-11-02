import Foundation
import Testing

@testable import SukiruCore

@Suite("Plugin health log tail")
struct PluginHealthLogTests {
    @Test("Only the tail is read and its cut first line is dropped")
    func tail() throws {
        let tree = try TempTree()
        let path = try tree.file(
            "opencode.log", contents: "first error\nsecond error\nthird error\n")
        #expect(PluginHealthAnalyzer.recentLogLines(path).count == 3)
        #expect(PluginHealthAnalyzer.recentLogLines(path, limit: 14) == ["third error"])
        #expect(PluginHealthAnalyzer.recentLogLines(tree.path + "/missing.log").isEmpty)
    }
}
