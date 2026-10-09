import Foundation

/// Now-playing for one Apple TV over the AirPlay 2 MRP tunnel.
/// Pairs on first use, then verifies, opens the channels and runs MRP.
public actor AirPlayNowPlaying {
    private let host: String
    private let port: UInt16
    private let clientID: String
    private let name: String
    /// The address this Mac presents to the TV, as colon-separated hex.
    private let deviceAddress: String
    private let pin: @Sendable (String) async -> String?
    private var session: AP2Session?
    private var mrp: MRPSession?
    private var forwardTask: Task<Void, Never>?
    public nonisolated let nowPlaying: AsyncStream<NowPlaying?>
    private let nowPlayingContinuation: AsyncStream<NowPlaying?>.Continuation

    public init(
        host: String,
        port: UInt16,
        clientID: String,
        name: String,
        deviceAddress: String,
        pin: @escaping @Sendable (String) async -> String?
    ) {
        self.host = host
        self.port = port
        self.clientID = clientID
        self.name = name
        self.deviceAddress = deviceAddress
        self.pin = pin
        let (stream, continuation) = AsyncStream.makeStream(of: NowPlaying?.self, bufferingPolicy: .bufferingNewest(1))
        self.nowPlaying = stream
        self.nowPlayingContinuation = continuation
    }

    /// Connects. Pairs with a PIN when `credentials` is nil. Returns the credentials in use.
    public func connect(credentials: HAPCredentials?) async throws -> HAPCredentials {
        await close()
        let identity = AirPlayIdentity(name: name, deviceID: deviceAddress, macAddress: deviceAddress)
        let session = AP2Session(host: host, port: port, identity: identity)
        try await session.openControl()
        var inUse = credentials
        if inUse == nil {
            let connection = await session.controlConnection
            inUse = try await AirPlayAuth.pairSetup(connection: connection, clientID: clientID, name: name) { [pin, name] in
                await pin("Pair AirPlay with \(name)")
            }
        }
        guard let active = inUse else { throw CompanionError.pairingCancelled }
        try await session.verify(credentials: active)
        try await session.setupRemoteControl()
        guard let channel = await session.dataChannel else { throw AP2Error.badResponse("no data channel") }
        let mrp = MRPSession(channel: channel, name: name, clientID: clientID)
        try await mrp.start()
        self.session = session
        self.mrp = mrp
        forwardTask = Task { [weak self, mrp] in
            for await value in mrp.nowPlaying {
                guard let self else { return }
                await self.forward(value)
            }
            await self?.forward(nil)
        }
        return active
    }

    private func forward(_ value: NowPlaying?) {
        nowPlayingContinuation.yield(value)
    }

    public func send(_ command: MediaCommand) async throws {
        guard let mrp else { throw MRPError.closed }
        try await mrp.send(command)
    }

    /// True once the MRP session runs.
    public var isConnected: Bool { mrp != nil }

    public func close() async {
        forwardTask?.cancel()
        forwardTask = nil
        await mrp?.close()
        mrp = nil
        await session?.close()
        session = nil
    }
}
