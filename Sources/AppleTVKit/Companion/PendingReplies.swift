import Foundation

/// Requests that wait for a reply. Each request has a timer that fails it when no reply comes.
///
/// A reply stops the timer of its request. So no sleeping task stays behind for each
/// request, and the timer does not wake the process for nothing.
struct PendingReplies<Key: Hashable & Sendable, Value: Sendable> {
    private struct Entry {
        let continuation: CheckedContinuation<Value, Error>
        let timer: Task<Void, Never>?
    }

    private var entries: [Key: Entry] = [:]
    /// The keys in the order they arrived, oldest first.
    private var order: [Key] = []

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }
    /// The key of the request that waits longest.
    var oldestKey: Key? { order.first }

    /// Adds one request. The timer is the task that fails the request when time runs out.
    mutating func add(_ key: Key, continuation: CheckedContinuation<Value, Error>, timer: Task<Void, Never>?) {
        if entries[key] == nil { order.append(key) }
        entries[key] = Entry(continuation: continuation, timer: timer)
    }

    /// Resumes the request with the result and stops its timer.
    /// Returns false when no request waits for that key.
    @discardableResult
    mutating func resolve(_ key: Key, with result: Result<Value, Error>) -> Bool {
        guard let entry = entries.removeValue(forKey: key) else { return false }
        order.removeAll { $0 == key }
        entry.timer?.cancel()
        entry.continuation.resume(with: result)
        return true
    }

    /// Fails every request and stops every timer.
    mutating func failAll(_ error: Error) {
        let all = entries
        entries.removeAll()
        order.removeAll()
        for entry in all.values {
            entry.timer?.cancel()
            entry.continuation.resume(throwing: error)
        }
    }

    /// Makes a timer that calls `expire` after `timeout`. A cancel ends it at once.
    static func timer(after timeout: Duration, expire: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await expire()
        }
    }
}
