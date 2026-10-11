import Foundation

/// Now-playing for one Apple TV over the AirPlay 2 MRP tunnel.
/// It verifies with the Companion pairing key, opens the channels and runs MRP.
/// The TV keeps one pairing store for both services, so one PIN serves both links.
/// When the tunnel ends, `nowPlaying` ends too. The owner then drops this object.
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
        await teardown()
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
            await self?.tunnelEnded(mrp)
        }
    }

    /// Closes everything when the MRP stream ends, for example after a feedback post fails.
    /// Without this, `isConnected` stays true and commands go to a dead link.
    private func tunnelEnded(_ ended: MRPSession) async {
        guard mrp === ended else { return }
        ATVLog.airplay.info("now-playing tunnel closed")
        await close()
    }

    private func forward(_ value: NowPlaying?) {
        nowPlayingContinuation.yield(value)
    }

    public func send(_ command: MediaCommand) async throws {
        guard let mrp else { throw MRPError.closed }
        try await mrp.send(command)
    }

    /// Sends a volume key through the MediaRemote link. This is the path HDMI-CEC listens to.
    public func sendVolumeKey(up: Bool, down: Bool) async throws {
        guard let mrp else { throw MRPError.closed }
        try await mrp.sendKey(usagePage: 12, usage: up ? 0xE9 : 0xEA, down: down)
    }

    /// Moves playback to an absolute position in seconds.
    public func seek(to seconds: Double) async throws {
        guard let mrp else { throw MRPError.closed }
        try await mrp.seek(to: seconds)
    }

    public var isConnected: Bool { mrp != nil }

    /// Closes the tunnel and ends `nowPlaying`.
    public func close() async {
        await teardown()
        nowPlayingContinuation.finish()
    }

    private func teardown() async {
        forwardTask?.cancel()
        forwardTask = nil
        let mrp = self.mrp
        let session = self.session
        self.mrp = nil
        self.session = nil
        await mrp?.close()
        await session?.close()
    }
}
