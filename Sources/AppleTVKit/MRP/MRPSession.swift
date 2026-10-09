import Foundation

public enum MRPError: Error, Sendable {
    case timeout(String)
    case closed
}

/// What one media player on the TV reports.
struct MRPPlayer {
    var identifier: String
    var displayName: String?
    var playbackState: MRPPlaybackState?
    var location = 0
    var items: [MRPContentItem] = []
    var supportedCommands: [Int: Bool] = [:]

    var currentItem: MRPContentItem? {
        items.indices.contains(location) ? items[location] : nil
    }
}

/// One app that owns players.
struct MRPClient {
    var bundleIdentifier: String
    var displayName: String?
    var players: [String: MRPPlayer] = [:]
    var activePlayerID: String?
    var supportedCommands: [Int: Bool] = [:]

    var activePlayer: MRPPlayer? {
        if let activePlayerID, let player = players[activePlayerID] { return player }
        return players[MRPPlayerPath.defaultPlayer]
    }
}

/// Tracks players and clients the way pyatv's PlayerStateManager does.
/// Pure logic so tests can drive it with hand-built messages.
public struct MRPPlayerStateManager: Sendable {
    private var clients: [String: MRPClient] = [:]
    private var activeClientID: String?

    public init() {}

    /// Applies one message. Returns true when the active now-playing state may have changed.
    public mutating func apply(_ message: MRPMessage) -> Bool {
        guard let type = message.messageType else { return false }
        switch type {
        case .setState:
            guard let state = MRPSetState.decode(message) else { return false }
            ATVLog.mrp.debug("set state client \(state.playerPath.bundleIdentifier ?? "-", privacy: .public) playback \(state.playbackState.map { String(describing: $0) } ?? "-", privacy: .public) items \(state.items?.count ?? -1) title \(state.items?.first?.metadata?.title ?? "-", privacy: .private)")
            // A state with a live playback stands in for the missing "now playing client" message.
            if activeClientID == nil, let playback = state.playbackState, playback == .playing || playback == .paused,
               let bundle = state.playerPath.bundleIdentifier {
                ensureClient(bundle, displayName: state.playerPath.clientDisplayName)
                activeClientID = bundle
            }
            return update(path: state.playerPath) { player in
                if let playback = state.playbackState { player.playbackState = playback }
                if let items = state.items {
                    player.items = items
                    player.location = state.location ?? 0
                }
                if let commands = state.supportedCommands { player.supportedCommands = commands }
            }
        case .updateContentItem, .updateContentItemArtwork:
            let field = type == .updateContentItem ? MRPExtension.updateContentItem : MRPExtension.updateContentItemArtwork
            guard let update = MRPContentItemUpdate.decode(message, field: field) else { return false }
            return self.update(path: update.playerPath) { player in
                for updated in update.items {
                    for index in player.items.indices where player.items[index].identifier == updated.identifier {
                        if let metadata = updated.metadata {
                            if player.items[index].metadata == nil {
                                player.items[index].metadata = metadata
                            } else {
                                player.items[index].metadata?.merge(metadata)
                            }
                        }
                        if let artwork = updated.artworkData { player.items[index].artworkData = artwork }
                    }
                }
            }
        case .setNowPlayingClient:
            let path = MRPPlayerPath.decodeClient(message.inner(MRPExtension.setNowPlayingClient)?.message(1))
            guard let bundle = path.bundleIdentifier else { return false }
            ensureClient(bundle, displayName: path.clientDisplayName)
            activeClientID = bundle
            return true
        case .setNowPlayingPlayer:
            let path = MRPPlayerPath.decode(message.inner(MRPExtension.setNowPlayingPlayer)?.message(1))
            guard let bundle = path.bundleIdentifier else { return false }
            ensureClient(bundle, displayName: path.clientDisplayName)
            let playerID = path.playerIdentifier ?? ""
            if !playerID.isEmpty, clients[bundle]?.players[playerID] == nil {
                clients[bundle]?.players[playerID] = MRPPlayer(identifier: playerID, displayName: path.playerDisplayName)
            }
            clients[bundle]?.activePlayerID = playerID.isEmpty ? nil : playerID
            return bundle == activeClientID
        case .updateClient:
            let path = MRPPlayerPath.decodeClient(message.inner(MRPExtension.updateClient)?.message(1))
            guard let bundle = path.bundleIdentifier else { return false }
            ensureClient(bundle, displayName: path.clientDisplayName)
            return bundle == activeClientID
        case .removeClient:
            let path = MRPPlayerPath.decodeClient(message.inner(MRPExtension.removeClient)?.message(1))
            guard let bundle = path.bundleIdentifier, clients[bundle] != nil else { return false }
            clients[bundle] = nil
            if activeClientID == bundle {
                activeClientID = nil
                return true
            }
            return false
        case .removePlayer:
            let path = MRPPlayerPath.decode(message.inner(MRPExtension.removePlayer)?.message(1))
            guard let bundle = path.bundleIdentifier, let playerID = path.playerIdentifier,
                  clients[bundle]?.players[playerID] != nil
            else { return false }
            clients[bundle]?.players[playerID] = nil
            if clients[bundle]?.activePlayerID == playerID { clients[bundle]?.activePlayerID = nil }
            return bundle == activeClientID
        case .setDefaultSupportedCommands:
            guard let inner = message.inner(MRPExtension.setDefaultSupportedCommands) else { return false }
            let path = MRPPlayerPath.decode(inner.message(2))
            guard let bundle = path.bundleIdentifier else { return false }
            ensureClient(bundle, displayName: path.clientDisplayName)
            var commands: [Int: Bool] = [:]
            for info in inner.message(1)?.messages(1) ?? [] {
                if let command = info.uint64(1) { commands[Int(command)] = info.bool(2) ?? true }
            }
            clients[bundle]?.supportedCommands = commands
            return bundle == activeClientID
        default:
            return false
        }
    }

    private mutating func ensureClient(_ bundle: String, displayName: String?) {
        if clients[bundle] == nil {
            clients[bundle] = MRPClient(bundleIdentifier: bundle, displayName: displayName)
        } else if let displayName, !displayName.isEmpty {
            clients[bundle]?.displayName = displayName
        }
    }

    private mutating func update(path: MRPPlayerPath, _ body: (inout MRPPlayer) -> Void) -> Bool {
        let bundle = path.bundleIdentifier ?? ""
        ensureClient(bundle, displayName: path.clientDisplayName)
        let playerID = (path.playerIdentifier?.isEmpty == false) ? path.playerIdentifier! : MRPPlayerPath.defaultPlayer
        var player = clients[bundle]?.players[playerID] ?? MRPPlayer(identifier: playerID, displayName: path.playerDisplayName)
        if let name = path.playerDisplayName, !name.isEmpty { player.displayName = name }
        body(&player)
        clients[bundle]?.players[playerID] = player
        let isActive = bundle == activeClientID && (clients[bundle]?.activePlayer?.identifier == playerID)
        return isActive || activeClientID == nil
    }

    /// The active client, else nil.
    var activeClient: MRPClient? {
        guard let activeClientID else { return nil }
        return clients[activeClientID]
    }

    /// The now-playing state for the active player, or nil when nothing plays.
    public var nowPlaying: NowPlaying? {
        guard let client = activeClient, let player = client.activePlayer else { return nil }
        guard let item = player.currentItem, let metadata = item.metadata else { return nil }
        guard let state = player.playbackState, state != .stopped, state != .unknown else { return nil }
        // Apps differ. HBO Max puts the film name in the artist field and sends an empty title.
        let names = [metadata.title, metadata.seriesName, metadata.trackArtistName, metadata.albumName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        guard let title = names.first else { return nil }
        let subtitle = names.dropFirst().first ?? ""
        let rate: Double
        if let playbackRate = metadata.playbackRate {
            rate = Double(playbackRate)
        } else {
            rate = state == .playing ? 1 : 0
        }
        return NowPlaying(
            title: title,
            subtitle: subtitle,
            appName: client.displayName ?? player.displayName ?? client.bundleIdentifier,
            duration: metadata.duration,
            elapsed: metadata.elapsedTime ?? 0,
            elapsedAt: metadata.elapsedDate ?? .now,
            rate: state == .paused ? 0 : rate,
            artwork: item.artworkData
        )
    }

    /// True when the active item advertises artwork we do not hold yet.
    public var needsArtwork: Bool {
        guard let player = activeClient?.activePlayer, let item = player.currentItem else { return false }
        return item.metadata?.artworkAvailable == true && item.artworkData == nil
    }

    /// True when the active item has no title yet.
    public var needsMetadata: Bool {
        guard let player = activeClient?.activePlayer, let item = player.currentItem else { return false }
        guard let metadata = item.metadata else { return true }
        return [metadata.title, metadata.seriesName, metadata.trackArtistName, metadata.albumName]
            .compactMap { $0 }.allSatisfy(\.isEmpty)
    }

    /// The identifier of the active item, used to avoid repeat artwork requests.
    public var activeItemIdentifier: String? {
        activeClient?.activePlayer?.currentItem?.identifier
    }

    public var activeLocation: Int {
        activeClient?.activePlayer?.location ?? 0
    }
}

/// Runs MRP over the AirPlay data channel and publishes now-playing.
public actor MRPSession {
    private let channel: DataStreamChannel
    private let name: String
    private let clientID: String
    private var reader: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<MRPMessage, Error>] = [:]
    private var state = MRPPlayerStateManager()
    private var artworkRequested: String?
    private var lastPublished: NowPlaying?
    public nonisolated let nowPlaying: AsyncStream<NowPlaying?>
    private let nowPlayingContinuation: AsyncStream<NowPlaying?>.Continuation

    static let trace = ProcessInfo.processInfo.environment["ATV_TRACE"] == "1"

    public init(channel: DataStreamChannel, name: String, clientID: String) {
        self.channel = channel
        self.name = name
        self.clientID = clientID
        let (stream, continuation) = AsyncStream.makeStream(of: NowPlaying?.self, bufferingPolicy: .bufferingNewest(1))
        self.nowPlaying = stream
        self.nowPlayingContinuation = continuation
    }

    /// The handshake pyatv uses. Device info must go first.
    public func start() async throws {
        startReader()
        _ = try await request(MRPMessageBuilder.deviceInfo(identifier: UUID().uuidString, name: name, uniqueIdentifier: clientID), identifier: nil, timeout: .seconds(8))
        try await channel.send(protobuf: MRPMessageBuilder.setConnectionState())
        _ = try? await request(MRPMessageBuilder.clientUpdatesConfig(identifier: UUID().uuidString), identifier: nil, timeout: .seconds(5))
        _ = try? await request(MRPMessageBuilder.getKeyboardSession(identifier: UUID().uuidString), identifier: nil, timeout: .seconds(5))
        try? await channel.send(protobuf: MRPMessageBuilder.playbackQueueRequest(identifier: UUID().uuidString))
        startHeartbeat()
        ATVLog.mrp.info("mrp session started")
    }

    private func startReader() {
        reader = Task { [weak self] in
            guard let self else { return }
            for await data in channel.messages {
                await self.handle(data)
            }
            await self.closed()
        }
    }

    private func closed() {
        for (_, continuation) in pending { continuation.resume(throwing: MRPError.closed) }
        pending.removeAll()
        nowPlayingContinuation.finish()
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                try? await self.channel.send(protobuf: MRPMessageBuilder.genericMessage(identifier: UUID().uuidString))
            }
        }
    }

    /// Sends a message and waits for the reply that carries the same identifier.
    private func request(_ data: Data, identifier: String?, timeout: Duration) async throws -> MRPMessage {
        let id = identifier ?? (try? MRPMessage.decode(data).identifier) ?? UUID().uuidString
        try await channel.send(protobuf: data)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.expire(id)
            }
        }
    }

    private func expire(_ id: String) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: MRPError.timeout(id))
    }

    private func handle(_ data: Data) async {
        guard let message = try? MRPMessage.decode(data) else {
            ATVLog.mrp.error("bad protobuf message")
            return
        }
        if Self.trace {
            ATVLog.mrp.debug("recv type \(message.type) id \(message.identifier ?? "-", privacy: .public)")
        }
        if let id = message.identifier, let continuation = pending.removeValue(forKey: id) {
            continuation.resume(returning: message)
            // A reply can also carry state, for example the playback queue with artwork.
        }
        if state.apply(message) {
            await publish()
        }
    }

    private func publish() async {
        let current = state.nowPlaying
        if current != lastPublished {
            lastPublished = current
            nowPlayingContinuation.yield(current)
        }
        if Self.trace, let metadata = state.activeClient?.activePlayer?.currentItem?.metadata {
            ATVLog.mrp.debug("active item metadata \(String(describing: metadata), privacy: .private)")
        }
        // Some apps send a thin state first. The queue request returns the full metadata.
        let itemKey = state.activeItemIdentifier ?? "current"
        if state.needsArtwork || state.needsMetadata, artworkRequested != itemKey {
            artworkRequested = itemKey
            try? await channel.send(protobuf: MRPMessageBuilder.playbackQueueRequest(identifier: UUID().uuidString, location: Int32(state.activeLocation)))
        }
    }

    /// Sends a transport command.
    public func send(_ command: MediaCommand) async throws {
        let data: Data
        switch command {
        case .play: data = MRPMessageBuilder.sendCommand(identifier: UUID().uuidString, command: .play)
        case .pause: data = MRPMessageBuilder.sendCommand(identifier: UUID().uuidString, command: .pause)
        case .togglePlayPause: data = MRPMessageBuilder.sendCommand(identifier: UUID().uuidString, command: .togglePlayPause)
        case .nextTrack: data = MRPMessageBuilder.sendCommand(identifier: UUID().uuidString, command: .nextTrack)
        case .previousTrack: data = MRPMessageBuilder.sendCommand(identifier: UUID().uuidString, command: .previousTrack)
        case .skipForward: data = MRPMessageBuilder.sendCommand(identifier: UUID().uuidString, command: .skipForward, skipInterval: 10)
        case .skipBackward: data = MRPMessageBuilder.sendCommand(identifier: UUID().uuidString, command: .skipBackward, skipInterval: 10)
        }
        _ = try await request(data, identifier: nil, timeout: .seconds(5))
    }

    public func close() async {
        heartbeat?.cancel()
        reader?.cancel()
        await channel.close()
        closed()
    }
}
