import Foundation

/// Caches `CapabilityDetector` results (detection never
/// blocks anything; results are cached).
///
/// The app queries capabilities repeatedly — the Settings panel, inline
/// degradation hints — and probing shells out to `gh`/`npx` (cold `npx`
/// resolution takes seconds). The cache guarantees repeat queries are free:
/// `current()` probes once and serves the cached report until `refresh()`
/// (or `invalidate()`) is called. `sukiru-cli capabilities` does NOT use the
/// cache — each invocation is a fresh process reporting the live state.
///
/// Thread-safe. Detection runs OUTSIDE the lock so a slow probe never blocks
/// another thread's `current()` on a cached value.
public final class CapabilityCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: CapabilityReport?
    private let detector: CapabilityDetector

    public init(detector: CapabilityDetector) {
        self.detector = detector
    }

    /// The cached report, running detection on first use.
    public func current() -> CapabilityReport {
        lock.lock()
        if let cached {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let report = detector.detect()
        lock.lock()
        defer { lock.unlock() }
        // Another thread may have won the detection race; keep the first.
        if let cached { return cached }
        cached = report
        return report
    }

    /// Re-runs detection and replaces the cached report.
    @discardableResult
    public func refresh() -> CapabilityReport {
        let report = detector.detect()
        lock.lock()
        cached = report
        lock.unlock()
        return report
    }

    /// Drops the cached report; the next `current()` re-probes.
    public func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
    }
}
