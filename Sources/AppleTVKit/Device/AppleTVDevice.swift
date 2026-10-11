import Foundation
import Network

/// Asks the user for the PIN the TV shows. Returns nil on cancel.
public typealias PINProvider = @Sendable (_ title: String) async -> String?

public enum DeviceError: Error, Sendable, Equatable {
    /// The Apple TV has no pairing this Mac can use.
    ///
    /// The app never pairs on its own, because pairing puts a PIN on the screen and turns
    /// the television on. The user starts it with `pair()`.
    case needsPairing
}

/// A command queued from the UI. The queue keeps down and up in order.
private enum QueuedCommand: Sendable {
    case button(RemoteButton, down: Bool)
    case touch(TouchEvent)
}

/// One Apple TV. Owns the Companion session, the credentials and the reconnect loop.
public actor AppleTVDevice: RemoteController {
    public nonisolated let id: String

    /// Each subscriber gets its own stream. A subscriber that stops ends only its stream.
    private let hub = EventHub<DeviceEvent>()
    private let commands: AsyncStream<QueuedCommand>
    private let commandsContinuation: AsyncStream<QueuedCommand>.Continuation
    private let identity: CompanionIdentity
    private let store: CredentialStore
    private let pinProvider: PINProvider

    private var device: DiscoveredDevice
    private var state: ConnectionState = .idle
    private var wantsConnection = false
    /// Grows on every `connect`. A loop that ends only clears its own generation.
    private var connectGeneration = 0
    private var connectLoop: Task<Void, Never>?
    private var commandLoop: Task<Void, Never>?
    /// True after `shutdown`. The device then does nothing more.
    private var isShutDown = false

    private var session: CompanionSession?
    private var sessionEvents: Task<Void, Never>?
    private var dropWaiter: CheckedContinuation<Void, Never>?

    private var airplay: AirPlayNowPlaying?
    private var airplayTask: Task<Void, Never>?
    private var airplayStarting = false
    /// Closes the tunnel while the TV sleeps, and keeps a failed tunnel from retrying.
    private var airplayGate = AirPlayGate()

    /// The user's volume commands, for televisions that give the Apple TV no volume route.
    private let volumeHook = VolumeCommandRunner()
    /// True when the Apple TV reports a volume route. Nil until it first says.
    private var hasVolumeRoute: Bool?
    /// True for one attempt after the user asks to pair. Only then may a PIN appear.
    private var pairingRequested = false
    /// Set when the user declines the AirPlay PIN. Cleared on the next `connect`.

    public init(device: DiscoveredDevice, identity: CompanionIdentity, store: CredentialStore, pinProvider: @escaping PINProvider) {
        self.id = device.id
        self.device = device
        self.identity = identity
        self.store = store
        self.pinProvider = pinProvider
        (commands, commandsContinuation) = AsyncStream.makeStream(of: QueuedCommand.self, bufferingPolicy: .unbounded)
    }

    public nonisolated func subscribe() -> AsyncStream<DeviceEvent> {
        hub.subscribe()
    }

    // MARK: Hot path

    public nonisolated func button(_ button: RemoteButton, down: Bool) {
        commandsContinuation.yield(.button(button, down: down))
    }

    public nonisolated func touch(_ event: TouchEvent) {
        commandsContinuation.yield(.touch(event))
    }

    private func startCommandLoop() {
        guard commandLoop == nil else { return }
        // The loop holds the device only for one command. A strong hold for the whole
        // stream keeps the device alive for ever, because the device owns the stream.
        commandLoop = Task { [weak self, commands] in
            for await command in commands {
                guard let self else { return }
                await self.perform(command)
            }
        }
    }

    private func perform(_ command: QueuedCommand) async {
        guard let session else { return }
        switch command {
        case .button(let button, let down):
            if button == .volumeUp || button == .volumeDown,
               await routeVolumeKey(up: button == .volumeUp, down: down) {
                return
            }
            await session.hid(button, down: down)
        case .touch(let event):
            await session.touch(event)
        }
    }

    /// Sends a volume key the best way this television allows.
    ///
    /// The Apple TV carries volume to an HDMI-CEC television over the MediaRemote link.
    /// A television that offers no volume route leaves the Apple TV on infrared, which no
    /// network client can reach, so the user's own command runs instead.
    /// Returns false when neither path exists, and the caller falls back to the Companion key.
    private func routeVolumeKey(up: Bool, down: Bool) async -> Bool {
        // Only take the MediaRemote path once the Apple TV has confirmed a volume route.
        if hasVolumeRoute == true, let airplay, await airplay.isConnected {
            do {
                try await airplay.sendVolumeKey(up: up, down: down)
                return true
            } catch {
                ATVLog.airplay.error("volume key failed: \(String(describing: error), privacy: .public)")
            }
        }
        guard await volumeHook.isConfigured() else { return false }
        // One step for each press. The key-up is swallowed so the step does not repeat.
        guard down else { return true }
        guard await volumeHook.step(up: up) else { return false }
        if let level = await volumeHook.level() { hub.yield(.volume(level)) }
        return true
    }

    // MARK: Connection

    public func connect() async {
        guard !isShutDown else { return }
        wantsConnection = true
        startCommandLoop()
        // A connect the user asks for may try the AirPlay tunnel again.
        if connectLoop == nil { airplayGate.reset() }
        guard connectLoop == nil else { return }
        connectGeneration += 1
        let generation = connectGeneration
        connectLoop = Task { [weak self] in
            await self?.runConnectLoop(generation: generation)
        }
    }

    public func disconnect() async {
        wantsConnection = false
        connectLoop?.cancel()
        connectLoop = nil
        await dropSession()
        await stopAirPlay()
        await volumeHook.stop()
        set(.idle)
    }

    /// Disconnects and ends every loop and stream. The owner drops the device after this.
    public func shutdown() async {
        await disconnect()
        isShutDown = true
        commandLoop?.cancel()
        commandLoop = nil
        commandsContinuation.finish()
        hub.finish()
    }

    /// Takes a fresh discovery record. Endpoints can arrive after the first sighting.
    /// Only a new AirPlay endpoint starts the tunnel. Other Bonjour updates do nothing.
    public func update(device: DiscoveredDevice) {
        let changed = AirPlayGate.endpointChanged(from: self.device.airplayEndpoint, to: device.airplayEndpoint)
        self.device = device
        if changed, state == .connected {
            Task { await self.startAirPlay() }
        }
    }

    private func set(_ newState: ConnectionState) {
        state = newState
        hub.yield(.connection(newState))
    }

    private func runConnectLoop(generation: Int) async {
        // The drops in a row. A link that holds for `stableLink` starts the count again.
        var drops = 0
        while wantsConnection, !Task.isCancelled {
            set(drops == 0 ? .connecting : .reconnecting)
            do {
                try await establish()
            } catch {
                // The app waits for the user after a failure, and retries when the user asks
                // for something. A retry loop in the background keeps the panel in an error.
                ATVLog.companion.error("connect failed: \(String(describing: error), privacy: .public)")
                set(Self.stateAfterFailure(error))
                wantsConnection = false
                await volumeHook.stop()
                break
            }
            let linkStart = ContinuousClock.now
            await waitForDrop()
            if !wantsConnection { break }
            await stopAirPlay()
            if ContinuousClock.now - linkStart >= Self.stableLink { drops = 0 }
            drops += 1
            guard Self.mayReconnect(afterDropWith: airplayGate.power) else {
                ATVLog.companion.info("link dropped while the Apple TV sleeps, waiting for the user")
                set(.idle)
                wantsConnection = false
                break
            }
            guard let delay = Self.reconnectDelay(forDrop: drops) else {
                ATVLog.companion.error("link dropped \(drops) times, waiting for the user")
                set(.failed("The link to the Apple TV keeps dropping."))
                wantsConnection = false
                break
            }
            ATVLog.companion.info("link dropped, reconnecting")
            set(.reconnecting)
            try? await Task.sleep(for: delay)
        }
        if connectGeneration == generation { connectLoop = nil }
    }

    /// The most reconnects in a row after lost links. Then the app waits for the user.
    static let maxReconnects = 4
    /// A link that holds this long counts as good, and the drop count starts again.
    static let stableLink: Duration = .seconds(60)

    /// The wait before the reconnect after drop number `drop`: 1, 2, 4 and 8 s.
    /// Nil means no more reconnects. The app then waits for the user.
    static func reconnectDelay(forDrop drop: Int) -> Duration? {
        guard (1...maxReconnects).contains(drop) else { return nil }
        return .seconds(1 << (drop - 1))
    }

    /// True when a lost link may come back by itself.
    /// A connect to a sleeping Apple TV can wake it through the Bonjour Sleep Proxy, and
    /// that turns the television on. So a sleeping Apple TV waits for the user.
    static func mayReconnect(afterDropWith power: PowerState) -> Bool {
        power != .asleep
    }

    /// The state the device waits in after a failed connection.
    /// A rejected key waits for a pairing, because a PIN would turn the television on.
    static func stateAfterFailure(_ error: Error) -> ConnectionState {
        switch error {
        case CompanionError.pairingCancelled: .idle
        case DeviceError.needsPairing: .needsPairing
        default: .failed(describe(error))
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case CompanionError.accessoryError(let code, let message): "Apple TV error \(code): \(message)"
        case CompanionError.timeout: "The Apple TV did not answer."
        case CompanionConnectionError.failed(let text): text
        case is HAPError: "Pairing failed. Check the PIN and try again."
        default: String(describing: error)
        }
    }

    /// Opens, pairs or verifies, and starts the session. On any failure the socket closes.
    private func establish() async throws {
        guard let endpoint = device.companionEndpoint else {
            throw CompanionConnectionError.failed("No Companion service on this Apple TV.")
        }
        ATVLog.companion.info("connecting to \(self.device.name, privacy: .public)")
        let session = CompanionSession(endpoint: endpoint, identity: identity)
        // A magic packet wakes the Apple TV, which turns the television on. Only `wake()`
        // may do that, because the user asked for it. A reconnect waits instead.
        try await session.open()
        do {
            try await authenticate(session)
            try await session.startSession()
        } catch {
            await session.close()
            throw error
        }
        self.session = session
        set(.connected)
        watch(session)
        if let power = try? await session.attentionState() {
            hub.yield(.power(power))
            observe(power)
        }
        Task { await self.startAirPlay() }
    }

    /// Verifies the stored key. Pairs only when the user asked for it.
    ///
    /// The stored key is never deleted here. A pairing the user starts replaces it, and
    /// everything else leaves it alone, so one bad moment on the network cannot cost the
    /// user their pairing.
    private func authenticate(_ session: CompanionSession) async throws {
        let stored = try? await store.device(for: id)
        if let credentials = stored?.companion, !pairingRequested {
            do {
                try await session.pairVerify(credentials: credentials)
                return
            } catch {
                ATVLog.pairing.error("pair-verify failed: \(String(describing: error), privacy: .public)")
                // Only the Apple TV turning the key down means the key is dead. Anything
                // else is the network, and the next attempt can still work.
                if Self.isRejection(error) { throw DeviceError.needsPairing }
                throw error
            }
        }
        guard pairingRequested else { throw DeviceError.needsPairing }
        pairingRequested = false

        set(.awaitingPIN)
        let credentials = try await session.pairSetup { [pinProvider, device] in
            await pinProvider("Pair with \(device.name)")
        }
        set(.pairing)
        var record = stored ?? StoredDevice(name: device.name)
        record.companion = credentials
        record.macAddress = device.macAddress
        try await store.save(record, for: id)
        // Verify once more to turn on the session cipher.
        try await session.pairVerify(credentials: credentials)
    }

    /// True when the Apple TV turned the key down.
    ///
    /// The handshake ran and the Apple TV refused it. A socket that closed, a timeout or a
    /// cancelled task are not refusals, and the stored key is still good.
    static func isRejection(_ error: any Error) -> Bool {
        switch error {
        case HAPError.accessoryError, HAPError.proofMismatch, HAPError.signatureInvalid,
             HAPError.identifierMismatch, HAPError.decryptFailed:
            true
        default:
            false
        }
    }

    /// Pairs with a PIN. Only the user starts this.
    ///
    /// The Apple TV shows the PIN on the screen, which turns the television on, so the app
    /// never does it alone.
    public func pair() async {
        pairingRequested = true
        if connectLoop != nil {
            // Drop the loop that is waiting, so the next attempt starts now.
            connectLoop?.cancel()
            connectLoop = nil
            await dropSession()
        }
        await connect()
    }

    /// Consumes the session events. When the stream ends the link is gone.
    private func watch(_ session: CompanionSession) {
        sessionEvents?.cancel()
        sessionEvents = Task { [weak self] in
            for await event in session.events {
                guard let self else { return }
                await self.handle(event)
            }
            await self?.linkDidDrop(session)
        }
    }

    /// Clears the session, but only when it is still the current one.
    private func linkDidDrop(_ dropped: CompanionSession) {
        guard session === dropped else { return }
        session = nil
        dropWaiter?.resume()
        dropWaiter = nil
    }

    /// Returns when the current session's event stream ends.
    private func waitForDrop() async {
        guard session != nil else { return }
        await withCheckedContinuation { continuation in
            dropWaiter = continuation
        }
    }

    private func dropSession() async {
        sessionEvents?.cancel()
        sessionEvents = nil
        let current = session
        session = nil
        await current?.close()
        dropWaiter?.resume()
        dropWaiter = nil
    }

    private func handle(_ event: CompanionEvent) {
        switch event {
        case .textInputStarted(let current):
            hub.yield(.textInput(.active(current: current)))
        case .textInputStopped:
            hub.yield(.textInput(.inactive))
        case .attention(let power):
            hub.yield(.power(power))
            observe(power)
        case .mediaFlags(let flags):
            // The volume bit changes with the output. Read the level when it is on.
            hasVolumeRoute = flags & CompanionSession.volumeFlag != 0
            Task { [weak self] in
                guard let self else { return }
                let level = try? await self.volumeLevel()
                await self.publish(.volume(level ?? DeviceEvent.noVolumeLevel))
            }
        }
    }

    private func publish(_ event: DeviceEvent) {
        hub.yield(event)
    }

    /// Opens or closes the AirPlay tunnel when the power state changes.
    private func observe(_ power: PowerState) {
        switch airplayGate.observe(power) {
        case .open:
            Task { await self.startAirPlay() }
        case .close:
            ATVLog.airplay.info("Apple TV asleep, closing now-playing tunnel")
            Task { await self.stopAirPlay() }
        case .none:
            break
        }
    }

    private func wakeIfPossible() async {
        let storedAddress = try? await store.device(for: id)?.macAddress
        guard let address = device.macAddress ?? storedAddress else { return }
        ATVLog.companion.info("sending wake-on-lan")
        try? await WakeOnLAN.send(mac: address)
    }

    // MARK: AirPlay now-playing

    /// Opens the AirPlay tunnel for now-playing. It uses the Companion key and asks for no PIN.
    private func startAirPlay() async {
        guard airplay == nil, !airplayStarting, state == .connected, airplayGate.mayOpen else { return }
        guard let endpoint = device.airplayEndpoint else {
            ATVLog.airplay.info("no AirPlay endpoint yet for \(self.device.name, privacy: .public)")
            return
        }
        airplayStarting = true
        defer { airplayStarting = false }
        ATVLog.airplay.info("opening now-playing tunnel")
        do {
            let (host, port) = try await resolveWithTimeout(endpoint)
            // The Companion record serves this link too. The TV holds one record per client.
            guard let record = try? await store.device(for: id)?.companion else { return }
            let tunnel = AirPlayNowPlaying(
                host: host,
                port: port,
                clientID: identity.clientID,
                name: identity.name,
                deviceAddress: identity.deviceAddress
            )
            try await tunnel.connect(credentials: record)
            // The link dropped or the TV fell asleep while the tunnel opened.
            guard state == .connected, airplayGate.mayOpen else {
                await tunnel.close()
                return
            }
            airplay = tunnel
            airplayTask = Task { [weak self] in
                for await info in tunnel.nowPlaying {
                    guard let self else { return }
                    await self.publish(.nowPlaying(info))
                }
                await self?.airplayEnded(tunnel)
            }
            ATVLog.airplay.info("now-playing tunnel open")
        } catch {
            // The tunnel waits for the next connect or wake. A timer retry costs power all day.
            airplayGate.markFailed()
            ATVLog.airplay.error("now-playing failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Clears a tunnel that ended by itself. Media commands then use the Companion link.
    private func airplayEnded(_ tunnel: AirPlayNowPlaying) {
        guard airplay === tunnel else { return }
        airplay = nil
        airplayTask = nil
        hub.yield(.nowPlaying(nil))
    }

    private func resolveWithTimeout(_ endpoint: NWEndpoint) async throws -> (host: String, port: UInt16) {
        try await withThrowingTaskGroup(of: (host: String, port: UInt16).self) { group in
            group.addTask { try await DeviceBrowser.resolve(endpoint) }
            group.addTask {
                try await Task.sleep(for: .seconds(6))
                throw CompanionError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CompanionError.timeout }
            return first
        }
    }

    private func stopAirPlay() async {
        airplayTask?.cancel()
        airplayTask = nil
        guard let tunnel = airplay else { return }
        airplay = nil
        await tunnel.close()
        // Nothing reports now-playing without the tunnel, so the UI must not keep the old item.
        hub.yield(.nowPlaying(nil))
    }

    // MARK: Requests

    public func typeText(_ text: String) async throws {
        try await liveSession().typeText(text)
    }

    public func clearText() async throws {
        try await liveSession().clearText()
    }

    public func launchableApps() async throws -> [LaunchableApp] {
        try await liveSession().launchableApps()
    }

    public func launch(bundleID: String) async throws {
        try await liveSession().launch(bundleID: bundleID)
    }

    public func media(_ command: MediaCommand) async throws {
        if let airplay, await airplay.isConnected {
            try await airplay.send(command)
            return
        }
        let session = try liveSession()
        switch command {
        case .play: try await session.mediaControl(.play)
        case .pause: try await session.mediaControl(.pause)
        case .togglePlayPause: await session.hid(.playPause, down: true); await session.hid(.playPause, down: false)
        case .nextTrack: try await session.mediaControl(.nextTrack)
        case .previousTrack: try await session.mediaControl(.previousTrack)
        case .skipForward: try await session.mediaControl(.skipBy, arguments: ["_skpS": .int(10)])
        case .skipBackward: try await session.mediaControl(.skipBy, arguments: ["_skpS": .int(-10)])
        }
    }

    /// Seeks over the now-playing link. Only that link reports a position.
    public func seek(to seconds: Double) async throws {
        guard let airplay, await airplay.isConnected else { throw CompanionError.notConnected }
        try await airplay.seek(to: seconds)
    }

    /// The level the Apple TV reports, else the level the user's command prints.
    public func volumeLevel() async throws -> Double? {
        if let session, let native = try? await session.volumeLevel() { return native }
        return await volumeHook.level()
    }

    public func setVolume(_ level: Double) async throws {
        if hasVolumeRoute == true, let session {
            try await session.setVolume(level)
            return
        }
        guard await volumeHook.setLevel(level) else { throw CompanionError.notConnected }
    }

    public func powerState() async throws -> PowerState {
        let power = try await liveSession().attentionState()
        observe(power)
        return power
    }

    /// Wakes the Apple TV with a magic packet and the HID wake key.
    public func wake() async {
        await wakeIfPossible()
        press(.wake)
    }

    public func sleep() async {
        press(.sleep)
    }

    /// Forgets the stored credentials. The next connect pairs again.
    public func forget() async {
        try? await store.remove(for: id)
        await disconnect()
    }

    private func liveSession() throws -> CompanionSession {
        guard let session else { throw CompanionError.notConnected }
        return session
    }
}

extension CompanionIdentity {
    /// The identity for this Mac. The address persists in UserDefaults.
    /// - Parameter clientID: The base pairing identifier from `CredentialStore.clientID()`.
    ///   Both links use it. The TV keeps one pairing store for both services.
    public static func thisMac(clientID: String) -> CompanionIdentity {
        let defaults = UserDefaults.standard
        let key = "atv.deviceID"
        let deviceID: String
        if let saved = defaults.string(forKey: key), saved.count == 12 {
            deviceID = saved
        } else {
            var bytes = [UInt8](repeating: 0, count: 6)
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
            // Locally administered, unicast.
            bytes[0] = (bytes[0] | 0x02) & 0xFE
            deviceID = bytes.map { String(format: "%02x", $0) }.joined()
            defaults.set(deviceID, forKey: key)
        }
        return CompanionIdentity(
            clientID: clientID,
            name: Host.current().localizedName ?? "Mac",
            model: hardwareModel(),
            deviceID: deviceID
        )
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var buffer = [UInt8](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}
