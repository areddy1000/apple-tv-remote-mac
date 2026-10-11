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

    /// Resumes with the result. Returns false when an earlier result already went out.
    @discardableResult
    func resume(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
        return pending != nil
    }

    /// Fails with `error` after `seconds` when no result went out before.
    /// Calls `onTimeout` only when this timer gave the result, so the caller can close the socket.
    func fail(after seconds: Double, on queue: DispatchQueue, with error: Error, onTimeout: @escaping @Sendable () -> Void) {
        queue.asyncAfter(deadline: .now() + seconds) { [self] in
            if resume(.failure(error)) { onTimeout() }
        }
    }
}

/// Limits for a socket that opens.
enum SocketLimits {
    /// An open that takes longer than this fails. The TCP option covers only the handshake,
    /// and a Bonjour name that never resolves can wait for ever without this limit.
    static let openTimeout: Double = 10
}
