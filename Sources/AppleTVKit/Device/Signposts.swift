import Foundation
import OSLog

/// Loggers and signposts for the whole kit.
/// Filter in Console with the subsystem `atv`.
public enum ATVLog {
    public static let subsystem = "atv"
    public static let discovery = Logger(subsystem: subsystem, category: "discovery")
    public static let companion = Logger(subsystem: subsystem, category: "companion")
    public static let pairing = Logger(subsystem: subsystem, category: "pairing")
    public static let airplay = Logger(subsystem: subsystem, category: "airplay")
    public static let mrp = Logger(subsystem: subsystem, category: "mrp")
    public static let input = Logger(subsystem: subsystem, category: "input")
    static let signposter = OSSignposter(subsystem: subsystem, category: "latency")
}

/// Measures the time from an input event to the socket write.
/// Use one instance per input event.
public struct LatencyProbe: Sendable {
    private let name: StaticString
    private let state: OSSignpostIntervalState
    private let start: ContinuousClock.Instant

    public init(_ name: StaticString) {
        self.name = name
        self.start = .now
        self.state = ATVLog.signposter.beginInterval(name, id: ATVLog.signposter.makeSignpostID())
    }

    /// Ends the interval and logs the elapsed time in microseconds.
    public func end() {
        ATVLog.signposter.endInterval(name, state)
        let micros = Int((ContinuousClock.now - start) / .microseconds(1))
        ATVLog.input.debug("\(self.name, privacy: .public) took \(micros, privacy: .public) µs")
    }
}
