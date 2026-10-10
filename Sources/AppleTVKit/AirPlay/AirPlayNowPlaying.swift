import Foundation

/// Now-playing for one Apple TV over the AirPlay 2 MRP tunnel.
/// It verifies with the Companion pairing key, opens the channels and runs MRP.
/// The TV keeps one pairing store for both services, so one PIN serves both links.
public actor AirPlayNowPlaying {
    private let host: String
    private let port: UInt16
    private let clientID: String
    private let name: String
    /// The address this Mac presents to the TV, as colon-separated hex.
    private let deviceAddress: String
    private var session: AP2Session?
    private var mrp: MRPSession?
    private var forwardTask: Task<Void, Never>?
    public nonisolated let nowPlaying: AsyncStream<NowPlaying?>
    private let nowPlayingContinuation: AsyncStream<NowPlaying?>.Continuation

    public init(host: String, port: UInt16, clientID: String, name: String, deviceAddress: String) {
        self.host = host
        self.port = port
        self.clientID = clientID
        self.name = name
        self.deviceAddress = deviceAddress
        let (stream, continuation) = AsyncStream.makeStream(of: NowPlaying?.self, bufferingPolicy: .bufferingNewest(1))
        self.nowPlaying = stream
        self.nowPlayingContinuation = continuation
    }

    /// Verifies with the pairing key, then opens the tunnel.
    public func connect(credentials: HAPCredentials) async throws {
        await close()
        let identity = AirPlayIdentity(name: name, deviceID: deviceAddress, macAddress: deviceAddress)
        let session = AP2Session(host: host, port: port, identity: identity)
        try await session.openControl()
        try await session.verify(credentials: credentials)
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
    }

    private func forward(_ value: NowPlaying?) {
        nowPlayingContinuation.yield(value)
    }

    public func send(_ command: MediaCommand) async throws {
        guard let mrp else { throw MRPError.closed }
        try await mrp.send(command)
    }

    /// Moves playback to an absolute position in seconds.
    public func seek(to seconds: Double) async throws {
        guard let mrp else { throw MRPError.closed }
        try await mrp.seek(to: seconds)
    }

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
