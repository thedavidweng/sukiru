import Foundation

extension Result {
    /// The success value, or nil — convenience for tests. Shared by the
    /// parser/reader/hasher suites; lives in Support so no suite's helpers
    /// hide inside another suite's file.
    var successValue: Success? {
        if case .success(let value) = self { return value }
        return nil
    }
}
