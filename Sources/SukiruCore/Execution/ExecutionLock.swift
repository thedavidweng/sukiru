import Foundation

/// A cross-process, mkdir-based mutual exclusion lock for batch execution
/// (VAL-REPAIR-027: two batches never execute concurrently, across app and
/// CLI instances alike). The lock is a directory carrying a `pid` file; a
/// lock whose holder process no longer exists is stale and broken.
final class ExecutionLock: Sendable {
    let path: String

    init(path: String) {
        self.path = path
    }

    /// Acquires the lock, breaking a stale holder (dead pid) once.
    ///
    /// - Throws: `ExecutionError.busy` when a live process holds the lock.
    func acquire() throws {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try FileManager.default.createDirectory(
            atPath: parent, withIntermediateDirectories: true)
        if try makeLockDirectory() {
            return
        }
        if let holder = holderPID(), processIsAlive(holder) {
            throw ExecutionError.busy(lockPath: path)
        }
        // Stale (dead holder, or a crash between mkdir and the pid write):
        // break it and retry exactly once.
        try? FileManager.default.removeItem(atPath: path)
        if try makeLockDirectory() {
            return
        }
        throw ExecutionError.busy(lockPath: path)
    }

    /// Releases the lock. Best-effort: a failure here never masks the
    /// execution result.
    func release() {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Creates the lock directory and records our pid. Returns false when
    /// the directory already exists.
    private func makeLockDirectory() throws -> Bool {
        do {
            try FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: false)
            let pid = "\(ProcessInfo.processInfo.processIdentifier)"
            try Data(pid.utf8).write(
                to: URL(fileURLWithPath: path + "/pid"), options: .atomic)
            return true
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                return false
            }
            throw error
        }
    }

    private func holderPID() -> Int32? {
        guard let data = FileManager.default.contents(atPath: path + "/pid"),
            let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// kill(pid, 0) liveness: EPERM still means the process exists.
    private func processIsAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }
}
