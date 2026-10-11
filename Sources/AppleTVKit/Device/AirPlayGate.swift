import Foundation
import Network

/// Decides when the AirPlay tunnel for now-playing may be open.
///
/// The tunnel posts feedback every 2 s while it is open. A sleeping Apple TV shows nothing,
/// so the tunnel closes then and opens again on a wake. A failed tunnel waits for the next
/// connect or the next wake. It never retries on a timer.
struct AirPlayGate: Sendable, Equatable {
    enum Action: Equatable {
        case open
        case close
        case none
    }

    /// The last power state the Apple TV reported. An unknown answer does not change it.
    private(set) var power: PowerState = .unknown
    /// True after the tunnel failed. It blocks a new try until the next connect or wake.
    private(set) var failed = false

    /// True when a new tunnel may open now.
    var mayOpen: Bool { !failed && power != .asleep }

    /// Starts again for a new connect that the user asked for.
    mutating func reset() {
        power = .unknown
        failed = false
    }

    mutating func markFailed() {
        failed = true
    }

    /// Takes a power report and returns what to do with the tunnel.
    mutating func observe(_ new: PowerState) -> Action {
        guard new != .unknown else { return .none }
        let old = power
        power = new
        if new == .asleep { return old == .asleep ? .none : .close }
        if old == .asleep {
            // A wake is rare and comes from the user, so it may try one more time.
            failed = false
            return .open
        }
        return .none
    }

    /// True when Bonjour reports an AirPlay endpoint that differs from the last one.
    static func endpointChanged(from old: NWEndpoint?, to new: NWEndpoint?) -> Bool {
        guard let new else { return false }
        return new != old
    }
}
