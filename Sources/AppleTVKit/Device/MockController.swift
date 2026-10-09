import Foundation

/// A controller that logs every command and answers with fixed data.
///
/// Development aid only. The app uses it when the environment variable ATV_MOCK is "1",
/// so the interface can run with no Apple TV on the network.
public final class MockController: RemoteController, Sendable {
    public let id: String
    public let events: AsyncStream<DeviceEvent>
    private let continuation: AsyncStream<DeviceEvent>.Continuation

    public init(id: String = "mock") {
        self.id = id
        (events, continuation) = AsyncStream.makeStream(of: DeviceEvent.self)
    }

    public func button(_ button: RemoteButton, down: Bool) {
        ATVLog.input.info("mock button \(button.title, privacy: .public) \(down ? "down" : "up", privacy: .public)")
    }

    public func touch(_ event: TouchEvent) {
        ATVLog.input.debug("mock touch \(event.phase.rawValue) \(Int(event.x)),\(Int(event.y))")
    }

    public func typeText(_ text: String) async throws {
        continuation.yield(.textInput(.active(current: text)))
    }

    public func clearText() async throws {
        continuation.yield(.textInput(.active(current: "")))
    }

    public func launchableApps() async throws -> [LaunchableApp] {
        [
            LaunchableApp(bundleID: "com.apple.TVWatchList", name: "Apple TV"),
            LaunchableApp(bundleID: "com.apple.TVMusic", name: "Music"),
            LaunchableApp(bundleID: "com.apple.TVPhotos", name: "Photos"),
            LaunchableApp(bundleID: "com.apple.TVSettings", name: "Settings"),
            LaunchableApp(bundleID: "com.apple.TVAppStore", name: "App Store"),
        ]
    }

    public func launch(bundleID: String) async throws {
        ATVLog.input.info("mock launch \(bundleID, privacy: .public)")
    }

    public func media(_ command: MediaCommand) async throws {
        ATVLog.input.info("mock media \(command.rawValue, privacy: .public)")
    }

    public func volumeLevel() async throws -> Double? { 0.42 }

    public func setVolume(_ level: Double) async throws {
        continuation.yield(.volume(level))
    }

    public func powerState() async throws -> PowerState { .awake }

    public func wake() async {
        continuation.yield(.power(.awake))
    }

    public func sleep() async {
        continuation.yield(.power(.asleep))
    }

    public func connect() async {
        continuation.yield(.connection(.connecting))
        try? await Task.sleep(for: .milliseconds(400))
        continuation.yield(.connection(.connected))
        continuation.yield(.power(.awake))
        continuation.yield(.nowPlaying(NowPlaying(
            title: "Sample Film",
            subtitle: "A subtitle",
            appName: "Apple TV",
            duration: 3_240,
            elapsed: 1_212,
            elapsedAt: .now,
            rate: 1
        )))
    }

    public func disconnect() async {
        continuation.yield(.connection(.idle))
    }
}
