import Foundation

/// Resumes a continuation one time only.
///
/// Network state handlers can report `.ready` and later `.cancelled` for one open call.
/// Only the first result reaches the caller.
///
/// `@unchecked Sendable`: the lock guards the one mutable field.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
