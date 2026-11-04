import Foundation
import Testing

@testable import SukiruCore

struct HermesPluginLifecycleTests {
    private let planner = PluginLifecyclePlanner(
        environment: SukiruEnvironment(reader: DictionaryEnvironmentReader(["SUKIRU_HOME": "/h"])))

    @Test("Hermes lifecycle is limited to user scope, one named plugin, and the verified version")
    func limitations() {
        let user = { (action: String, target: String) in
            PluginLifecycleRequest(
                host: .hermes, action: action, target: target, scope: "user", scopeRoot: "/h")
        }
        #expect(
            planner.hermesLimitation(user("enable", "x"), version: "0.22.7", inventory: empty)
                == nil)
        #expect(
            planner.hermesLimitation(user("check", "*"), version: "0.22.7", inventory: empty) == nil
        )
        #expect(
            planner.hermesLimitation(user("check", "x"), version: "0.22.7", inventory: empty) != nil
        )
        #expect(
            planner.hermesLimitation(user("enable", "*"), version: "0.22.7", inventory: empty)
                != nil)
        #expect(
            planner.hermesLimitation(user("install", "x"), version: "0.22.6", inventory: empty)
                != nil)
        #expect(
            planner.hermesLimitation(
                user("marketplace-add", "x"), version: "0.22.7", inventory: empty) != nil)
        let project = PluginLifecycleRequest(
            host: .hermes, action: "enable", target: "x", scope: "project", scopeRoot: "/p")
        #expect(planner.hermesLimitation(project, version: "0.22.7", inventory: empty) != nil)
    }

    @Test("Install targets reject option-like names before reaching the host")
    func installTargetValidation() throws {
        let request = PluginLifecycleRequest(
            host: .hermes, action: "enable", target: "--force", scope: "user", scopeRoot: "/h")
        #expect(throws: PluginLifecycleError.self) { try planner.validate(request) }
    }

    @Test("Hermes captures only config.yaml, not plugin directories, so payloads are not rolled back")
    func captureScope() throws {
        let home = "/h"
        let installed = PluginInstallation(
            host: .hermes, source: "local", identifier: "x", scope: "user", scopeRoot: home,
            version: nil, path: home + "/.hermes/plugins/x", enablement: .disabled,
            loadStatus: "unknown", components: [], name: "x")
        let inventory = PluginInventory(installations: [installed], marketplaces: [], issues: [])
        let request = PluginLifecycleRequest(
            host: .hermes, action: "remove", target: "x", scope: "user", scopeRoot: home)
        let result = try PluginLifecycleCapture(
            environment: SukiruEnvironment(reader: DictionaryEnvironmentReader(["SUKIRU_HOME": home]))
        ).roots(request: request, inventory: inventory)
        #expect(result.paths == [home + "/.hermes/config.yaml"])
    }

    private var empty: PluginInventory {
        PluginInventory(installations: [], marketplaces: [], issues: [])
    }
}
