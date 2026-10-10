import Foundation

/// Collects what a session sent and received, so a device test shows the exact bytes.
/// Thread-safe: CoreNFC completion handlers and the UI touch it from different threads.
final class SessionTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(line)
    }
}
