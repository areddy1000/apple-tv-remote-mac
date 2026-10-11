import Foundation
import Synchronization

/// Gives events to one subscriber at a time.
///
/// A subscriber that stops ends its own stream for good. So each subscriber gets a new
/// stream, and the device keeps its events after the UI lets go and comes back.
/// Events that arrive with no subscriber are dropped.
public final class EventHub<Event: Sendable>: Sendable {
    private struct State {
        var continuation: AsyncStream<Event>.Continuation?
        var finished = false
    }

    private let state = Mutex(State())

    public init() {}

    /// Returns a new stream and ends the stream of the last subscriber.
    public func subscribe() -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
        let old = state.withLock { state -> AsyncStream<Event>.Continuation? in
            // After `finish` the new stream ends at once.
            guard !state.finished else { return continuation }
            defer { state.continuation = continuation }
            return state.continuation
        }
        old?.finish()
        return stream
    }

    /// Sends one event to the current subscriber.
    public func yield(_ event: Event) {
        state.withLock { $0.continuation }?.yield(event)
    }

    /// Ends the current stream. Later subscribers get a stream that has already ended.
    public func finish() {
        let old = state.withLock { state -> AsyncStream<Event>.Continuation? in
            state.finished = true
            defer { state.continuation = nil }
            return state.continuation
        }
        old?.finish()
    }
}
