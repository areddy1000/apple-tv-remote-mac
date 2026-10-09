import CryptoKit
import Foundation
import Network

public enum CompanionError: Error, Sendable, Equatable {
    case notConnected
    case unexpectedFrame(UInt8)
    case badPayload
    case pairingCancelled
    case accessoryError(code: Int64, message: String)
    case timeout
    case textInputInactive
}

/// The identity the Mac presents to the Apple TV.
public struct CompanionIdentity: Sendable {
    /// The HAP pairing identifier for the Companion link.
    public var clientID: String
    /// The HAP pairing identifier for the AirPlay link. The TV keeps one pairing per
    /// identifier, so the two links must not share one.
    public var airplayClientID: String
    public var name: String
    public var model: String
    /// 12 hex characters. A random, persisted, locally administered address.
    public var deviceID: String

    public init(clientID: String, airplayClientID: String, name: String, model: String, deviceID: String) {
        self.clientID = clientID
        self.airplayClientID = airplayClientID
        self.name = name
        self.model = model
        self.deviceID = deviceID
    }

    /// `deviceID` as a colon-separated address, for example `7A:D2:6A:01:5A:46`.
    public var deviceAddress: String {
        stride(from: 0, to: deviceID.count, by: 2).map { offset -> String in
            let start = deviceID.index(deviceID.startIndex, offsetBy: offset)
            let end = deviceID.index(start, offsetBy: 2, limitedBy: deviceID.endIndex) ?? deviceID.endIndex
            return String(deviceID[start..<end])
        }.joined(separator: ":").uppercased()
    }
}

/// An event the Apple TV pushes over the session.
public enum CompanionEvent: Sendable {
    case textInputStarted(current: String)
    case textInputStopped
    case attention(PowerState)
    /// The media control flags for the current output. See `CompanionSession.volumeFlag`.
    case mediaFlags(Int64)
}

/// Commands for the Companion `_mcc` request.
public enum MediaControlCode: Int64, Sendable {
    case play = 1
    case pause = 2
    case nextTrack = 3
    case previousTrack = 4
    case getVolume = 5
    case setVolume = 6
    case skipBy = 7
}

/// One paired and verified Companion Link session.
/// Every request carries an `_x` id and waits for the matching response.
public actor CompanionSession {
    /// The bit in the media control flags that means the output has a volume level.
    public static let volumeFlag: Int64 = 0x100

    public let identity: CompanionIdentity
    public nonisolated let events: AsyncStream<CompanionEvent>

    private let connection: CompanionConnection
    private let eventsContinuation: AsyncStream<CompanionEvent>.Continuation
    private var nextXID: Int64 = 1
    private var pending: [Int64: CheckedContinuation<OPACKValue, Error>] = [:]
    private var rawWaiters: [CheckedContinuation<CompanionFrame, Error>] = []
    private var reader: Task<Void, Never>?
    private var isVerified = false
    private var textSessionUUID: Data?
    private var mediaFlags: Int64 = 0

    public init(endpoint: NWEndpoint, identity: CompanionIdentity) {
        self.identity = identity
        self.connection = CompanionConnection(endpoint: endpoint)
        let (stream, continuation) = AsyncStream.makeStream(of: CompanionEvent.self, bufferingPolicy: .unbounded)
        self.events = stream
        self.eventsContinuation = continuation
    }

    // MARK: Lifecycle

    /// Opens the socket and starts the frame reader.
    public func open() async throws {
        try await connection.open()
        reader = Task { [weak self] in
            guard let self else { return }
            for await frame in connection.frames {
                await self.dispatch(frame)
            }
            await self.linkDropped()
        }
    }

    /// Closes the socket. Pending requests fail and the event stream ends.
    public func close() async {
        reader?.cancel()
        reader = nil
        await connection.close()
        linkDropped()
    }

    private func linkDropped() {
        isVerified = false
        for (_, continuation) in pending {
            continuation.resume(throwing: CompanionError.notConnected)
        }
        pending.removeAll()
        for waiter in rawWaiters {
            waiter.resume(throwing: CompanionError.notConnected)
        }
        rawWaiters.removeAll()
        eventsContinuation.finish()
    }

    // MARK: Inbound frames

    private func nextRawFrame() async throws -> CompanionFrame {
        try await withCheckedThrowingContinuation { continuation in
            rawWaiters.append(continuation)
        }
    }

    private func dispatch(_ frame: CompanionFrame) {
        if frame.type.isAuth || !isVerified, !rawWaiters.isEmpty {
            rawWaiters.removeFirst().resume(returning: frame)
            return
        }
        guard frame.type == .eOPACK || frame.type == .uOPACK else {
            if frame.type != .noOp {
                ATVLog.companion.debug("ignored frame type \(frame.type.rawValue)")
            }
            return
        }
        guard let value = try? OPACK.decode(frame.payload) else {
            ATVLog.companion.error("bad OPACK payload")
            return
        }
        let type = value["_t"]?.intValue ?? 0
        if type == 3, let xid = value["_x"]?.intValue, let continuation = pending.removeValue(forKey: xid) {
            if let code = value["_ec"]?.intValue, code != 0 {
                let message = value["_em"]?.stringValue ?? "error"
                continuation.resume(throwing: CompanionError.accessoryError(code: code, message: message))
            } else {
                continuation.resume(returning: value["_c"] ?? .null)
            }
            return
        }
        let id = value["_i"]?.stringValue ?? ""
        if type == 2, let xid = value["_x"]?.intValue {
            // The TV asked us something. Answer, then treat it as an event too.
            Task { await self.reply(to: id, xid: xid) }
        }
        if type == 1 || type == 2 {
            handleEvent(id: id, content: value["_c"])
        }
    }

    /// Answers a request from the TV. System info gets our identity, the rest an empty dict.
    private func reply(to id: String, xid: Int64) async {
        let content: OPACKValue = id == "_systemInfo" ? systemInfo() : .dictionary([:])
        let message: OPACKValue = .dictionary([
            "_i": .string(id),
            "_t": .int(3),
            "_x": .int(xid),
            "_c": content,
        ])
        try? await connection.send(CompanionFrame(type: .eOPACK, payload: OPACK.encode(message)))
    }

    private func systemInfo() -> OPACKValue {
        .dictionary([
            "_bf": .int(0),
            "_cf": .int(512),
            "_clFl": .int(128),
            "_i": .string(identity.deviceID.lowercased()),
            "_idsID": .string(identity.clientID),
            "_pubID": .string(identity.deviceAddress),
            "_sf": .int(256),
            "_sv": .string("170.18"),
            "model": .string(identity.model),
            "name": .string(identity.name),
        ])
    }

    private func handleEvent(id: String, content: OPACKValue?) {
        switch id {
        case "_tiStarted":
            let data = content?["_tiD"]?.dataValue
            textSessionUUID = data.flatMap { RTISession.sessionUUID(from: $0) } ?? textSessionUUID
            eventsContinuation.yield(.textInputStarted(current: data.flatMap { RTISession.currentText(from: $0) } ?? ""))
        case "_tiStopped":
            textSessionUUID = nil
            eventsContinuation.yield(.textInputStopped)
        case "_iMC":
            if let flags = content?["_mcF"]?.intValue {
                mediaFlags = flags
                eventsContinuation.yield(.mediaFlags(flags))
            }
        case "SystemStatus", "TVSystemStatus":
            if let state = content?["state"]?.intValue, let power = PowerState(rawValue: Int(state)) {
                eventsContinuation.yield(.attention(power))
            }
        default:
            ATVLog.companion.debug("unhandled event \(id, privacy: .public)")
        }
    }

    // MARK: Outbound messages

    /// Sends a request and waits for the response content.
    @discardableResult
    public func request(_ id: String, content: OPACKValue = .dictionary([:]), timeout: Duration = .seconds(8)) async throws -> OPACKValue {
        let xid = try await send(id, type: 2, content: content)
        return try await withCheckedThrowingContinuation { continuation in
            pending[xid] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.expire(xid: xid)
            }
        }
    }

    /// Fails a request that got no answer in time.
    private func expire(xid: Int64) {
        guard let continuation = pending.removeValue(forKey: xid) else { return }
        continuation.resume(throwing: CompanionError.timeout)
    }

    /// Sends an event. The TV never answers an event.
    public func event(_ id: String, content: OPACKValue = .dictionary([:])) async throws {
        _ = try await send(id, type: 1, content: content)
    }

    /// Sends a request and does not wait for the reply. The reply is dropped on arrival.
    /// Buttons use this. The TV acts on requests only, but a wait would add latency.
    public func fireRequest(_ id: String, content: OPACKValue = .dictionary([:])) async throws {
        _ = try await send(id, type: 2, content: content)
    }

    /// Writes one OPACK message and returns its `_x` id.
    private func send(_ id: String, type: Int64, content: OPACKValue) async throws -> Int64 {
        let xid = nextXID
        nextXID += 1
        let message: OPACKValue = .dictionary([
            "_i": .string(id),
            "_t": .int(type),
            "_x": .int(xid),
            "_c": content,
        ])
        try await connection.send(CompanionFrame(type: .eOPACK, payload: OPACK.encode(message)))
        return xid
    }

    // MARK: Pairing

    /// Runs HAP pair-setup. The PIN comes from the callback when the TV shows it.
    public func pairSetup(pin: @Sendable () async -> String?) async throws -> HAPCredentials {
        let setup = HAPPairSetup(clientID: identity.clientID, name: identity.name)
        try await sendPairing(type: .psStart, tlv: setup.m1(), extra: ("_pwTy", .int(1)))
        let m2 = try await receivePairing()
        guard let pin = await pin() else { throw CompanionError.pairingCancelled }
        try await sendPairing(type: .psNext, tlv: try setup.m3(m2: m2, pin: pin), extra: ("_pwTy", .int(1)))
        let m4 = try await receivePairing()
        try await sendPairing(type: .psNext, tlv: try setup.m5(m4: m4), extra: ("_pwTy", .int(1)))
        let m6 = try await receivePairing()
        let credentials = try setup.finish(m6: m6)
        ATVLog.pairing.info("companion pair-setup complete")
        return credentials
    }

    /// Runs HAP pair-verify and turns on encryption.
    public func pairVerify(credentials: HAPCredentials) async throws {
        let verify = HAPPairVerify(credentials: credentials)
        try await sendPairing(type: .pvStart, tlv: verify.m1(), extra: ("_auTy", .int(4)))
        let m2 = try await receivePairing()
        try await sendPairing(type: .pvNext, tlv: try verify.m3(m2: m2), extra: nil)
        let m4 = try await receivePairing()
        try verify.finish(m4: m4)
        let keys = verify.sessionKeys(salt: "", outputInfo: "ClientEncrypt-main", inputInfo: "ServerEncrypt-main")
        await connection.enableEncryption(outKey: keys.out, inKey: keys.in)
        isVerified = true
        ATVLog.pairing.info("companion pair-verify complete")
    }

    private func sendPairing(type: CompanionFrameType, tlv: Data, extra: (String, OPACKValue)?) async throws {
        var dict: [String: OPACKValue] = ["_pd": .data(tlv)]
        if let extra { dict[extra.0] = extra.1 }
        try await connection.send(CompanionFrame(type: type, payload: OPACK.encode(.dictionary(dict))))
    }

    private func receivePairing() async throws -> Data {
        let frame = try await nextRawFrame()
        guard frame.type.isAuth else { throw CompanionError.unexpectedFrame(frame.type.rawValue) }
        let value = try OPACK.decode(frame.payload)
        guard let tlv = value["_pd"]?.dataValue else { throw CompanionError.badPayload }
        let decoded = try TLV8.decode(tlv)
        if let error = TLV8.error(in: decoded) {
            throw CompanionError.accessoryError(code: Int64(error.rawValue), message: "pairing error \(error)")
        }
        return tlv
    }

    // MARK: Session setup

    /// Sends system info and starts the remote service session.
    public func startSession() async throws {
        try await request("_systemInfo", content: systemInfo())
        try await request("_sessionStart", content: .dictionary([
            "_srvT": .string("com.apple.tvremoteservices"),
            "_sid": .int(Int64.random(in: 1...Int64(UInt32.max))),
        ]))
        // The remote control service answers queries only after this registration.
        try await request("TVRCSessionStart", content: .dictionary(["ProtocolVersionKey": .string("1.2")]))
        ATVLog.companion.info("session started")
        _ = try? await request("_touchStart", content: .dictionary([
            "_width": .double(1000),
            "_height": .double(1000),
            "_tFl": .int(0),
        ]))
        try? await event("_interest", content: .dictionary(["_regEvents": .array([.string("_iMC")])]))
        await probeTextInput()
    }

    /// Asks for a text session once. A reply with `_tiD` means a field is open right now.
    private func probeTextInput() async {
        guard let response = try? await request("_tiStart", timeout: .seconds(3)) else { return }
        if let data = response["_tiD"]?.dataValue, let uuid = RTISession.sessionUUID(from: data) {
            textSessionUUID = uuid
            eventsContinuation.yield(.textInputStarted(current: RTISession.currentText(from: data) ?? ""))
        }
    }

    // MARK: Commands

    /// A button down or up. This is the hot path. No waiting on a response.
    public func hid(_ button: RemoteButton, down: Bool) async {
        let probe = LatencyProbe("companion.hid")
        defer { probe.end() }
        do {
            try await fireRequest("_hidC", content: .dictionary([
                "_hBtS": .int(down ? 1 : 2),
                "_hidC": .int(Int64(button.rawValue)),
            ]))
        } catch {
            ATVLog.companion.error("hid send failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// One touch sample. Timestamps use the uptime clock in nanoseconds.
    public func touch(_ touch: TouchEvent) async {
        let nanoseconds = Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        try? await event("_hidT", content: .dictionary([
            "_ns": .int(nanoseconds),
            "_tFg": .int(1),
            "_cx": .double(touch.x),
            "_cy": .double(touch.y),
            "_tPh": .int(Int64(touch.phase.rawValue)),
        ]))
    }

    public func launch(bundleID: String) async throws {
        try await request("_launchApp", content: .dictionary(["_bundleID": .string(bundleID)]))
    }

    public func launchableApps() async throws -> [LaunchableApp] {
        let response = try await request("FetchLaunchableApplicationsEvent")
        guard let dict = response.dictValue else { return [] }
        return dict.compactMap { key, value in
            value.stringValue.map { LaunchableApp(bundleID: key, name: $0) }
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func attentionState() async throws -> PowerState {
        // tvOS does not always answer this. Keep the timeout short.
        let response = try await request("FetchAttentionState", timeout: .seconds(3))
        return response["state"]?.intValue.flatMap { PowerState(rawValue: Int($0)) } ?? .unknown
    }

    /// Media control through the Companion `_mcc` request.
    @discardableResult
    public func mediaControl(_ command: MediaControlCode, arguments: [String: OPACKValue] = [:]) async throws -> OPACKValue {
        var content = arguments
        content["_mcc"] = .int(command.rawValue)
        return try await request("_mcc", content: .dictionary(content))
    }

    /// The volume as 0...1. Nil when the current output has no volume level.
    public func volumeLevel() async throws -> Double? {
        guard mediaFlags & Self.volumeFlag != 0 else { return nil }
        let response = try await mediaControl(.getVolume)
        return response["_vol"]?.doubleValue
    }

    public func setVolume(_ level: Double) async throws {
        try await mediaControl(.setVolume, arguments: ["_vol": .double(min(1, max(0, level)))])
    }

    // MARK: Text input

    /// Opens a text input session. Throws when no field is active on the TV.
    private func beginTextInput() async throws {
        // Stop any old session first, as pyatv does. The TV then returns a fresh session id.
        _ = try? await request("_tiStop")
        let response = try await request("_tiStart")
        textSessionUUID = response["_tiD"]?.dataValue.flatMap { RTISession.sessionUUID(from: $0) }
        guard textSessionUUID != nil else { throw CompanionError.textInputInactive }
    }

    /// Inserts `text` at the cursor of the active field.
    public func typeText(_ text: String) async throws {
        try await sendTextOperation { RTIPayload.inputText(sessionUUID: $0, text: text) }
    }

    /// Clears the active field.
    public func clearText() async throws {
        try await sendTextOperation { RTIPayload.clearText(sessionUUID: $0) }
    }

    private func sendTextOperation(_ payload: (Data) -> Data) async throws {
        if textSessionUUID == nil { try await beginTextInput() }
        guard let uuid = textSessionUUID else { throw CompanionError.textInputInactive }
        try await event("_tiC", content: .dictionary([
            "_tiV": .int(1),
            "_tiD": .data(payload(uuid)),
        ]))
    }
}
