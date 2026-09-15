import Testing

@testable import SukiruCore

@Suite("SukiruCore package skeleton")
struct SukiruCorePackageTests {
    @Test("Core module exposes its stable identifier")
    func identifier() {
        #expect(SukiruCore.identifier == "sukiru-core")
    }

    @Test("Yams dependency links and parses YAML")
    func yamsLinks() {
        #expect(SukiruCore.yamsAvailable())
    }
}
