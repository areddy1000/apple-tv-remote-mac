import Foundation

/// A physical button on the Siri Remote. The raw value is the Companion HID code.
public enum RemoteButton: Int, Sendable, CaseIterable, Codable, Hashable {
    case up = 1
    case down = 2
    case left = 3
    case right = 4
    case menu = 5
    case select = 6
    case home = 7
    case volumeUp = 8
    case volumeDown = 9
    case siri = 10
    case screensaver = 11
    case sleep = 12
    case wake = 13
    case playPause = 14
    case channelUp = 15
    case channelDown = 16
    case guide = 17
    case pageUp = 18
    case pageDown = 19

    /// The SF Symbol for the button.
    public var symbolName: String {
        switch self {
        case .up: "chevron.up"
        case .down: "chevron.down"
        case .left: "chevron.left"
        case .right: "chevron.right"
        case .menu: "chevron.backward"
        case .select: "circle.fill"
        case .home: "tv"
        case .volumeUp: "plus"
        case .volumeDown: "minus"
        case .siri: "mic.fill"
        case .screensaver: "sparkles.tv"
        case .sleep: "power"
        case .wake: "sun.max"
        case .playPause: "playpause.fill"
        case .channelUp: "chevron.up.2"
        case .channelDown: "chevron.down.2"
        case .guide: "list.bullet.rectangle"
        case .pageUp: "arrow.up.to.line"
        case .pageDown: "arrow.down.to.line"
        }
    }

    /// The label for menus and accessibility.
    public var title: String {
        switch self {
        case .up: "Up"
        case .down: "Down"
        case .left: "Left"
        case .right: "Right"
        case .menu: "Back"
        case .select: "Select"
        case .home: "TV"
        case .volumeUp: "Volume Up"
        case .volumeDown: "Volume Down"
        case .siri: "Siri"
        case .screensaver: "Screensaver"
        case .sleep: "Sleep"
        case .wake: "Wake"
        case .playPause: "Play/Pause"
        case .channelUp: "Channel Up"
        case .channelDown: "Channel Down"
        case .guide: "Guide"
        case .pageUp: "Page Up"
        case .pageDown: "Page Down"
        }
    }

    /// The command line name, for example `select` or `volume-up`.
    public var commandName: String {
        switch self {
        case .volumeUp: "volume-up"
        case .volumeDown: "volume-down"
        case .playPause: "play-pause"
        case .channelUp: "channel-up"
        case .channelDown: "channel-down"
        case .pageUp: "page-up"
        case .pageDown: "page-down"
        default: String(describing: self)
        }
    }

    public init?(commandName: String) {
        guard let match = RemoteButton.allCases.first(where: { $0.commandName == commandName }) else {
            return nil
        }
        self = match
    }
}

/// One touch sample on the virtual 1000 x 1000 surface.
public struct TouchEvent: Sendable, Equatable {
    public enum Phase: Int, Sendable {
        case press = 1
        case hold = 3
        case release = 4
        case tap = 5
    }

    public var x: Double
    public var y: Double
    public var phase: Phase

    public init(x: Double, y: Double, phase: Phase) {
        self.x = min(1000, max(0, x))
        self.y = min(1000, max(0, y))
        self.phase = phase
    }
}

/// Transport commands for the current player.
public enum MediaCommand: String, Sendable, CaseIterable {
    case play
    case pause
    case togglePlayPause
    case nextTrack
    case previousTrack
    case skipForward
    case skipBackward

    /// The command line and URL name, for example `toggle` or `skip-forward`.
    public var commandName: String {
        switch self {
        case .play: "play"
        case .pause: "pause"
        case .togglePlayPause: "toggle"
        case .nextTrack: "next"
        case .previousTrack: "previous"
        case .skipForward: "skip-forward"
        case .skipBackward: "skip-backward"
        }
    }

    public init?(commandName: String) {
        guard let match = MediaCommand.allCases.first(where: { $0.commandName == commandName }) else {
            return nil
        }
        self = match
    }
}

/// The link between the Mac and one Apple TV.
public enum ConnectionState: Sendable, Equatable {
    case idle
    case connecting
    /// The Apple TV has no pairing this Mac can use. The user starts the pairing.
    case needsPairing
    case awaitingPIN
    case pairing
    case connected
    case reconnecting
    case failed(String)

    public var isConnected: Bool { self == .connected }

    public var label: String {
        switch self {
        case .idle: "Not Connected"
        case .connecting: "Connecting"
        case .needsPairing: "Needs Pairing"
        case .awaitingPIN: "Enter PIN"
        case .pairing: "Pairing"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting"
        case .failed: "Connection Failed"
        }
    }

    /// True while the app is working on the link. The UI shows a spinner.
    public var isBusy: Bool {
        switch self {
        case .connecting, .reconnecting, .pairing, .awaitingPIN: true
        default: false
        }
    }
}

/// The attention state the Apple TV reports.
public enum PowerState: Int, Sendable {
    case unknown = 0
    case asleep = 1
    case screensaver = 2
    case awake = 3
}

/// Now-playing metadata for the current item.
public struct NowPlaying: Sendable, Equatable {
    public var title: String
    public var subtitle: String
    public var appName: String
    public var duration: Double?
    public var elapsed: Double
    public var elapsedAt: Date
    public var rate: Double
    public var artwork: Data?

    public init(
        title: String,
        subtitle: String = "",
        appName: String = "",
        duration: Double? = nil,
        elapsed: Double = 0,
        elapsedAt: Date = .now,
        rate: Double = 0,
        artwork: Data? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.appName = appName
        self.duration = duration
        self.elapsed = elapsed
        self.elapsedAt = elapsedAt
        self.rate = rate
        self.artwork = artwork
    }

    public var isPlaying: Bool { rate > 0 }

    /// Elapsed time projected to `date` with the playback rate.
    public func elapsed(at date: Date) -> Double {
        let projected = elapsed + rate * date.timeIntervalSince(elapsedAt)
        if let duration { return min(max(0, projected), duration) }
        return max(0, projected)
    }
}

/// An app installed on the Apple TV.
public struct LaunchableApp: Identifiable, Sendable, Hashable, Codable {
    public var bundleID: String
    public var name: String
    public var id: String { bundleID }

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// The state of the on-screen text field on the Apple TV.
public enum TextInputState: Sendable, Equatable {
    case inactive
    case active(current: String)
}

/// Events a device sends to the UI.
public enum DeviceEvent: Sendable {
    case connection(ConnectionState)
    case power(PowerState)
    case nowPlaying(NowPlaying?)
    case textInput(TextInputState)
    case apps([LaunchableApp])
    /// The volume as 0...1, or `noVolumeLevel` when the output has no level.
    case volume(Double)

    /// The value `volume` carries when the output reports no level.
    public static let noVolumeLevel: Double = -1
}

/// The control surface the UI talks to. `AppleTVDevice` and `MockController` conform.
public protocol RemoteController: AnyObject, Sendable {
    var id: String { get }

    /// Returns a new event stream. The stream of the last subscriber ends.
    /// A subscriber that stops does not end the events for the next one.
    func subscribe() -> AsyncStream<DeviceEvent>

    /// Sends a button down or up event. Call is fire and forget to keep latency low.
    func button(_ button: RemoteButton, down: Bool)
    /// Sends one touch sample on the 1000 x 1000 surface.
    func touch(_ event: TouchEvent)
    func typeText(_ text: String) async throws
    func clearText() async throws
    func launchableApps() async throws -> [LaunchableApp]
    func launch(bundleID: String) async throws
    func media(_ command: MediaCommand) async throws
    /// Moves playback to an absolute position in seconds.
    func seek(to seconds: Double) async throws
    /// The volume as 0...1, or nil when the TV has no volume control.
    func volumeLevel() async throws -> Double?
    func setVolume(_ level: Double) async throws
    func powerState() async throws -> PowerState
    /// Wakes the TV. Uses the network wake packet and the HID wake key.
    func wake() async
    func sleep() async
    func connect() async
    func disconnect() async
}

extension RemoteController {
    /// A full click: down then up.
    public func press(_ button: RemoteButton) {
        self.button(button, down: true)
        self.button(button, down: false)
    }
}
