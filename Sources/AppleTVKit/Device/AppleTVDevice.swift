import Foundation
import Network

/// Asks the user for the PIN the TV shows. Returns nil on cancel.
public typealias PINProvider = @Sendable (_ title: String) async -> String?

/// Media control codes for the Companion `_mcc` request.
enum MediaControlCode: Int64 {
    case play = 1
    case pause = 2
    case nextTrack = 3
    case previousTrack = 4
    case getVolume = 5
    case setVolume = 6
    case skipBy = 7
}

/// A command queued from the UI. The queue keeps down and up in order.
enum QueuedCommand: Sendable {
    case button(RemoteButton, down: Bool)
    case touch(TouchEvent)
}

/// One Apple TV. Owns the Companion session, the credentials and the reconnect loop.
public actor AppleTVDevice: RemoteController {
    public nonisolated let id: String
    public nonisolated let events: AsyncStream<DeviceEvent>
    private let eventsContinuation: AsyncStream<DeviceEvent>.Continuation

    private var device: DiscoveredDevice
    private let identity: CompanionIdentity
    private let store: CredentialStore
    private let pinProvider: PINProvider

    private var session: CompanionSession?
    private var sessionEvents: Task<Void, Never>?
    private var airplay: AirPlayNowPlaying?
    private var airplayTask: Task<Void, Never>?
    /// Set when the user declines the AirPlay PIN. Cleared on the next launch.
    private var airplayDeclined = false
    private var connectLoop: Task<Void, Never>?
    private var commandLoop: Task<Void, Never>?
    private let commands: AsyncStream<QueuedCommand>
    private let commandsContinuation: AsyncStream<QueuedCommand>.Continuation
    private var wantsConnection = false
    private var state: ConnectionState = .idle

    public init(device: DiscoveredDevice, identity: CompanionIdentity, store: CredentialStore, pinProvider: @escaping PINProvider) {
        self.id = device.id
        self.device = device
        self.identity = identity
        self.store = store
        self.pinProvider = pinProvider
        let (events, eventsContinuation) = AsyncStream.makeStream(of: DeviceEvent.self, bufferingPolicy: .unbounded)
        self.events = events
        self.eventsContinuation = eventsContinuation
        let (commands, commandsContinuation) = AsyncStream.makeStream(of: QueuedCommand.self, bufferingPolicy: .unbounded)
        self.commands = commands
        self.commandsContinuation = commandsContinuation
    }

    // MARK: RemoteController, hot path

    public nonisolated func button(_ button: RemoteButton, down: Bool) {
        commandsContinuation.yield(.button(button, down: down))
    }

    public nonisolated func touch(_ event: TouchEvent) {
        commandsContinuation.yield(.touch(event))
    }

    private func startCommandLoop() {
        guard commandLoop == nil else { return }
        commandLoop = Task { [weak self] in
            guard let self else { return }
            for await command in commands {
                await self.perform(command)
            }
        }
    }

    private func perform(_ command: QueuedCommand) async {
        guard let session else { return }
        switch command {
        case .button(let button, let down):
            await session.hid(button, down: down)
        case .touch(let event):
            await session.touch(event)
        }
    }

    // MARK: Connection

    public func connect() async {
        wantsConnection = true
        startCommandLoop()
        guard connectLoop == nil else { return }
        connectLoop = Task { [weak self] in
            guard let self else { return }
            await self.runConnectLoop()
        }
    }

    public func disconnect() async {
        wantsConnection = false
        connectLoop?.cancel()
        connectLoop = nil
        sessionEvents?.cancel()
        await session?.close()
        session = nil
        await stopAirPlay()
        set(.idle)
    }

    // MARK: AirPlay now-playing

    /// Opens the AirPlay tunnel for now-playing. Pairs with a second PIN on first use.
    /// Takes a fresh discovery record. Endpoints can arrive after the first sighting.
    public func update(device: DiscoveredDevice) {
        self.device = device
        if state == .connected, airplay == nil, device.airplayEndpoint != nil {
            Task { await self.startAirPlay() }
        }
    }

    private func startAirPlay() async {
        guard airplay == nil, !airplayDeclined else { return }
        guard let endpoint = device.airplayEndpoint else {
            ATVLog.airplay.info("no AirPlay endpoint yet for \(self.device.name, privacy: .public)")
            return
        }
        ATVLog.airplay.info("opening now-playing tunnel")
        do {
            let (host, port) = try await withThrowingTaskGroup(of: (String, UInt16).self) { group in
                group.addTask { try await DeviceBrowser.resolve(endpoint) }
                group.addTask {
                    try await Task.sleep(for: .seconds(6))
                    throw CompanionError.timeout
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw CompanionError.timeout }
                return first
            }
            ATVLog.airplay.info("resolved \(host, privacy: .public):\(port)")
            let stored = try? await store.device(for: id)
            let tunnel = AirPlayNowPlaying(
                host: host,
                port: port,
                clientID: identity.airplayClientID,
                // A distinct name. The TV keeps one pairing per name.
                name: identity.name + " Now Playing",
                pin: { [pinProvider, device] title in
                    await pinProvider(title.isEmpty ? "Pair now playing with \(device.name)" : title)
                }
            )
            airplay = tunnel
            var current = stored?.airplay
            if current == nil { set(.awaitingPIN) }
            let credentials: HAPCredentials
            do {
                credentials = try await tunnel.connect(credentials: current)
            } catch where current != nil {
                // The TV rejected the stored key. Pair again with a PIN.
                ATVLog.airplay.info("stored now-playing key rejected (\(String(describing: error), privacy: .public)), pairing again")
                current = nil
                set(.awaitingPIN)
                credentials = try await tunnel.connect(credentials: nil)
            }
            if current == nil {
                var record = stored ?? StoredDevice(name: device.name)
                record.airplay = credentials
                try? await store.save(record, for: id)
                set(.connected)
            }
            ATVLog.airplay.info("now-playing tunnel open")
            airplayTask = Task { [weak self] in
                for await info in tunnel.nowPlaying {
                    guard let self else { return }
                    await self.publish(nowPlaying: info)
                }
            }
        } catch CompanionError.pairingCancelled {
            airplayDeclined = true
            airplay = nil
            if state == .awaitingPIN { set(.connected) }
        } catch {
            ATVLog.airplay.error("now-playing failed: \(String(describing: error), privacy: .public)")
            airplay = nil
            if state == .awaitingPIN { set(.connected) }
        }
    }

    private func publish(nowPlaying: NowPlaying?) {
        eventsContinuation.yield(.nowPlaying(nowPlaying))
    }

    private func stopAirPlay() async {
        airplayTask?.cancel()
        airplayTask = nil
        await airplay?.close()
        airplay = nil
    }

    private func set(_ newState: ConnectionState) {
        state = newState
        eventsContinuation.yield(.connection(newState))
    }

    private func runConnectLoop() async {
        var attempt = 0
        while wantsConnection, !Task.isCancelled {
            set(attempt == 0 ? .connecting : .reconnecting)
            do {
                try await establish()
                attempt = 0
                await waitForDrop()
                if !wantsConnection { return }
                ATVLog.companion.info("link dropped, reconnecting")
                await stopAirPlay()
            } catch CompanionError.pairingCancelled {
                set(.idle)
                wantsConnection = false
                return
            } catch {
                ATVLog.companion.error("connect failed: \(String(describing: error), privacy: .public)")
                set(.failed(describe(error)))
            }
            attempt += 1
            let delay = min(15, pow(2, Double(min(attempt, 4))))
            try? await Task.sleep(for: .seconds(delay))
        }
        connectLoop = nil
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case CompanionError.accessoryError(let code, let message): "Apple TV error \(code): \(message)"
        case CompanionError.timeout: "The Apple TV did not answer."
        case CompanionConnectionError.failed(let text): text
        case is HAPError: "Pairing failed. Check the PIN and try again."
        default: String(describing: error)
        }
    }

    private func establish() async throws {
        guard let endpoint = device.companionEndpoint else {
            throw CompanionConnectionError.failed("No Companion service on this Apple TV.")
        }
        ATVLog.companion.info("connecting to \(self.device.name, privacy: .public)")
        let session = CompanionSession(endpoint: endpoint, identity: identity)
        do {
            try await session.open()
        } catch {
            try await wakeIfPossible()
            throw error
        }
        self.session = session

        let stored = try? await store.device(for: id)
        if let credentials = stored?.companion {
            do {
                try await session.pairVerify(credentials: credentials)
            } catch {
                ATVLog.pairing.error("pair-verify failed, pairing again: \(String(describing: error), privacy: .public)")
                // Drop the stale key. The next attempt asks for a PIN.
                if var record = stored {
                    record.companion = nil
                    try? await store.save(record, for: id)
                }
                await session.close()
                throw error
            }
        } else {
            set(.awaitingPIN)
            let credentials = try await session.pairSetup { [pinProvider, device] in
                await pinProvider("Pair with \(device.name)")
            }
            set(.pairing)
            var record = stored ?? StoredDevice(name: device.name)
            record.companion = credentials
            record.macAddress = device.macAddress
            record.lastHost = device.host
            try await store.save(record, for: id)
            // Verify once more to turn on the session cipher.
            try await session.pairVerify(credentials: credentials)
        }

        try await session.startSession()
        set(.connected)
        watch(session)
        if let power = try? await session.attentionState() {
            eventsContinuation.yield(.power(power))
        }
        Task { await self.startAirPlay() }
    }

    private var dropWaiter: CheckedContinuation<Void, Never>?

    /// Consumes the session events. When the stream ends the link is gone.
    private func watch(_ session: CompanionSession) {
        sessionEvents?.cancel()
        sessionEvents = Task { [weak self] in
            for await event in session.events {
                guard let self else { return }
                await self.handle(event)
            }
            await self?.linkDidDrop()
        }
    }

    private func linkDidDrop() {
        session = nil
        dropWaiter?.resume()
        dropWaiter = nil
    }

    private func handle(_ event: CompanionEvent) {
        switch event {
        case .textInputStarted(let current):
            eventsContinuation.yield(.textInput(.active(current: current)))
        case .textInputStopped:
            eventsContinuation.yield(.textInput(.inactive))
        case .attention(let power):
            eventsContinuation.yield(.power(power))
        case .mediaFlags(let flags):
            // The volume bit toggles when the output changes. Read the level when it is on.
            if flags & 0x100 != 0 {
                Task { [weak self] in
                    guard let self, let level = try? await self.volumeLevel() else { return }
                    await self.publish(volume: level)
                }
            } else {
                eventsContinuation.yield(.volume(-1))
            }
        case .unknown:
            break
        }
    }

    private func publish(volume: Double) {
        eventsContinuation.yield(.volume(volume))
    }

    // MARK: Volume and power

    public func volumeLevel() async throws -> Double? {
        guard let session else { throw CompanionError.notConnected }
        return try await session.volumeLevel()
    }

    public func setVolume(_ level: Double) async throws {
        guard let session else { throw CompanionError.notConnected }
        try await session.setVolume(level)
    }

    public func powerState() async throws -> PowerState {
        guard let session else { throw CompanionError.notConnected }
        return try await session.attentionState()
    }

    public func sleep() async {
        button(.sleep, down: true)
        button(.sleep, down: false)
    }

    /// Returns when the session's event stream ends.
    private func waitForDrop() async {
        guard session != nil else { return }
        await withCheckedContinuation { continuation in
            dropWaiter = continuation
        }
    }

    private func wakeIfPossible() async throws {
        let storedMAC = try? await store.device(for: id)?.macAddress
        guard let mac = device.macAddress ?? storedMAC else { return }
        ATVLog.companion.info("sending wake-on-lan")
        try? await WakeOnLAN.send(mac: mac)
    }

    // MARK: RemoteController, requests

    public func typeText(_ text: String) async throws {
        guard let session else { throw CompanionError.notConnected }
        try await session.typeText(text)
    }

    public func clearText() async throws {
        guard let session else { throw CompanionError.notConnected }
        try await session.clearText()
    }

    public func launchableApps() async throws -> [LaunchableApp] {
        guard let session else { throw CompanionError.notConnected }
        return try await session.launchableApps()
    }

    public func launch(bundleID: String) async throws {
        guard let session else { throw CompanionError.notConnected }
        try await session.launch(bundleID: bundleID)
    }

    public func media(_ command: MediaCommand) async throws {
        if let airplay, await airplay.isConnected {
            try await airplay.send(command)
            return
        }
        guard let session else { throw CompanionError.notConnected }
        switch command {
        case .play: try await session.mediaControl(MediaControlCode.play.rawValue)
        case .pause: try await session.mediaControl(MediaControlCode.pause.rawValue)
        case .togglePlayPause: await session.hid(.playPause, down: true); await session.hid(.playPause, down: false)
        case .nextTrack: try await session.mediaControl(MediaControlCode.nextTrack.rawValue)
        case .previousTrack: try await session.mediaControl(MediaControlCode.previousTrack.rawValue)
        case .skipForward: try await session.mediaControl(MediaControlCode.skipBy.rawValue, arguments: ["_skpS": .int(10)])
        case .skipBackward: try await session.mediaControl(MediaControlCode.skipBy.rawValue, arguments: ["_skpS": .int(-10)])
        }
    }

    /// Wakes the Apple TV with a HID wake and a magic packet.
    public func wake() async {
        try? await wakeIfPossible()
        button(.wake, down: true)
        button(.wake, down: false)
    }

    /// Forgets the stored credentials. The next connect pairs again.
    public func forget() async {
        try? await store.remove(for: id)
        await disconnect()
    }
}

extension CompanionIdentity {
    /// The identity for this Mac. The ids persist in UserDefaults.
    public static func thisMac(clientID: String) -> CompanionIdentity {
        let defaults = UserDefaults.standard
        let key = "atv.deviceID"
        let deviceID: String
        if let saved = defaults.string(forKey: key), saved.count == 12 {
            deviceID = saved
        } else {
            var bytes = [UInt8](repeating: 0, count: 6)
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
            bytes[0] = (bytes[0] | 0x02) & 0xFE
            deviceID = bytes.map { String(format: "%02x", $0) }.joined()
            defaults.set(deviceID, forKey: key)
        }
        let name = Host.current().localizedName ?? "Mac"
        // Each HAP pairing on the TV is keyed by the client identifier.
        // Companion and AirPlay need different ones, or the second pairing replaces the first.
        return CompanionIdentity(clientID: clientID + "-companion", name: name, model: hardwareModel(), deviceID: deviceID)
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var buffer = [UInt8](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        let bytes = buffer.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}
