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

/// Identity the Mac presents to the Apple TV.
public struct CompanionIdentity: Sendable {
    public var clientID: String
    public var name: String
    public var model: String
    /// 12 hex characters. Also sent as a colon-separated address.
    public var deviceID: String

    public init(clientID: String, name: String, model: String, deviceID: String) {
        self.clientID = clientID
        self.name = name
        self.model = model
        self.deviceID = deviceID
    }

    /// The identifier for the AirPlay pairing. A separate UUID from the Companion one.
    public var airplayClientID: String {
        CredentialStore.clientID(role: "airplay")
    }

    var colonAddress: String {
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
    case mediaFlags(Int64)
    case unknown(id: String, content: OPACKValue?)
}

/// One paired and verified Companion Link session.
/// Every request carries an `_x` id and waits for the matching response.
public actor CompanionSession {
    public let identity: CompanionIdentity
    private let connection: CompanionConnection
    private var nextXID: Int64 = 1
    private var pending: [Int64: CheckedContinuation<OPACKValue, Error>] = [:]
    private var reader: Task<Void, Never>?
    private var sessionID: Int64 = 0
    private var textSessionUUID: Data?
    private var touchStarted = false
    public nonisolated let events: AsyncStream<CompanionEvent>
    private let eventsContinuation: AsyncStream<CompanionEvent>.Continuation
    private(set) public var isVerified = false

    public init(endpoint: NWEndpoint, identity: CompanionIdentity) {
        self.identity = identity
        self.connection = CompanionConnection(endpoint: endpoint)
        let (stream, continuation) = AsyncStream.makeStream(of: CompanionEvent.self, bufferingPolicy: .unbounded)
        self.events = stream
        self.eventsContinuation = continuation
    }

    // MARK: Lifecycle

    public func open() async throws {
        try await connection.open()
        startReader()
    }

    public func close() async {
        reader?.cancel()
        await connection.close()
        for (_, continuation) in pending {
            continuation.resume(throwing: CompanionError.notConnected)
        }
        pending.removeAll()
        eventsContinuation.finish()
    }

    private func startReader() {
        reader = Task { [weak self] in
            guard let self else { return }
            for await frame in connection.frames {
                await self.dispatch(frame)
            }
            await self.linkDropped()
        }
    }

    private func linkDropped() {
        isVerified = false
        for (_, continuation) in pending {
            continuation.resume(throwing: CompanionError.notConnected)
        }
        pending.removeAll()
        eventsContinuation.finish()
    }

    // MARK: Raw frames during pairing

    private var rawWaiters: [CheckedContinuation<CompanionFrame, Error>] = []

    private func nextRawFrame() async throws -> CompanionFrame {
        try await withCheckedThrowingContinuation { continuation in
            rawWaiters.append(continuation)
        }
    }

    private func dispatch(_ frame: CompanionFrame) {
        if frame.type.isAuth || !isVerified {
            if !rawWaiters.isEmpty {
                let waiter = rawWaiters.removeFirst()
                waiter.resume(returning: frame)
                return
            }
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
        if type == 2, let xid = value["_x"]?.intValue {
            // The TV asked us something. Answer, then treat it as an event too.
            Task { await self.reply(to: value["_i"]?.stringValue ?? "", xid: xid) }
        }
        if type == 1 || type == 2 {
            handleEvent(id: value["_i"]?.stringValue ?? "", content: value["_c"], xid: value["_x"]?.intValue)
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
            "_pubID": .string(identity.colonAddress),
            "_sf": .int(256),
            "_sv": .string("170.18"),
            "model": .string(identity.model),
            "name": .string(identity.name),
        ])
    }

    private func handleEvent(id: String, content: OPACKValue?, xid: Int64?) {
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
            ATVLog.companion.debug("event \(id, privacy: .public)")
            eventsContinuation.yield(.unknown(id: id, content: content))
        }
    }

    // MARK: Requests

    /// Sends a request and waits for the response content.
    @discardableResult
    public func request(_ id: String, content: OPACKValue = .dictionary([:]), timeout: Duration = .seconds(8)) async throws -> OPACKValue {
        let xid = nextXID
        nextXID += 1
        let message: OPACKValue = .dictionary([
            "_i": .string(id),
            "_t": .int(2),
            "_x": .int(xid),
            "_c": content,
        ])
        let frame = CompanionFrame(type: .eOPACK, payload: OPACK.encode(message))
        try await connection.send(frame)
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

    /// Sends an event with no response.
    public func event(_ id: String, content: OPACKValue = .dictionary([:])) async throws {
        try await fire(id, type: 1, content: content)
    }

    /// Sends a request and does not wait for the reply. The reply is dropped on arrival.
    /// Buttons use this. The TV acts on requests, but a wait would add latency.
    public func fireRequest(_ id: String, content: OPACKValue = .dictionary([:])) async throws {
        try await fire(id, type: 2, content: content)
    }

    private func fire(_ id: String, type: Int64, content: OPACKValue) async throws {
        let xid = nextXID
        nextXID += 1
        let message: OPACKValue = .dictionary([
            "_i": .string(id),
            "_t": .int(type),
            "_x": .int(xid),
            "_c": content,
        ])
        try await connection.send(CompanionFrame(type: .eOPACK, payload: OPACK.encode(message)))
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
        _ = try await request("_systemInfo", content: systemInfo())

        let localSID = Int64.random(in: 1...Int64(UInt32.max))
        let response = try await request("_sessionStart", content: .dictionary([
            "_srvT": .string("com.apple.tvremoteservices"),
            "_sid": .int(localSID),
        ]))
        let remoteSID = response["_sid"]?.intValue ?? 0
        sessionID = (remoteSID << 32) | localSID
        // The remote control service answers queries only after this registration.
        _ = try await request("TVRCSessionStart", content: .dictionary(["ProtocolVersionKey": .string("1.2")]))
        ATVLog.companion.info("session started")
        try await startTouch()
        try await subscribeInterest()
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

    private func startTouch() async throws {
        guard !touchStarted else { return }
        _ = try? await request("_touchStart", content: .dictionary([
            "_width": .double(1000),
            "_height": .double(1000),
            "_tFl": .int(0),
        ]))
        touchStarted = true
    }

    private func subscribeInterest() async throws {
        try? await event("_interest", content: .dictionary(["_regEvents": .array([.string("_iMC")])]))
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
            ATVLog.companion.error("hid send failed: \(error)")
        }
    }

    /// One touch sample. Timestamps use the uptime clock in nanoseconds.
    public func touch(_ touch: TouchEvent) async {
        let ns = Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        try? await event("_hidT", content: .dictionary([
            "_ns": .int(ns),
            "_tFg": .int(1),
            "_cx": .double(touch.x),
            "_cy": .double(touch.y),
            "_tPh": .int(Int64(touch.phase.rawValue)),
        ]))
    }

    public func launch(bundleID: String) async throws {
        _ = try await request("_launchApp", content: .dictionary(["_bundleID": .string(bundleID)]))
    }

    public func launchableApps() async throws -> [LaunchableApp] {
        let response = try await request("FetchLaunchableApplicationsEvent")
        guard let dict = response.dictValue else { return [] }
        return dict.compactMap { key, value in
            guard let name = value.stringValue else { return nil }
            return LaunchableApp(bundleID: key, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func attentionState() async throws -> PowerState {
        // tvOS 26 does not always answer this. Keep the timeout short.
        let response = try await request("FetchAttentionState", timeout: .seconds(3))
        let raw = response["state"]?.intValue ?? response.intValue ?? 0
        return PowerState(rawValue: Int(raw)) ?? .unknown
    }

    /// Media control through the Companion `_mcc` command.
    @discardableResult
    public func mediaControl(_ command: Int64, arguments: [String: OPACKValue] = [:]) async throws -> OPACKValue {
        var content = arguments
        content["_mcc"] = .int(command)
        return try await request("_mcc", content: .dictionary(content))
    }

    /// The media control flags the TV last reported. Bit 0x100 means volume control.
    private(set) public var mediaFlags: Int64 = 0

    /// The volume as 0...1. Nil when the current output has no volume control.
    public func volumeLevel() async throws -> Double? {
        ATVLog.companion.debug("volume query, flags \(self.mediaFlags)")
        guard mediaFlags & 0x100 != 0 else { return nil }
        let response = try await mediaControl(5, arguments: [:])
        ATVLog.companion.debug("volume reply \(String(describing: response), privacy: .public)")
        return response["_vol"]?.doubleValue
    }

    public func setVolume(_ level: Double) async throws {
        let clamped = min(1, max(0, level))
        try await mediaControl(6, arguments: ["_vol": .double(clamped)])
    }

    // MARK: Text input

    /// Opens a text input session and returns the current field text when known.
    public func beginTextInput() async throws {
        // pyatv stops any old session first. The TV then returns a fresh session id.
        _ = try? await request("_tiStop")
        let response = try await request("_tiStart")
        if let data = response["_tiD"]?.dataValue {
            textSessionUUID = RTISession.sessionUUID(from: data)
        }
        guard textSessionUUID != nil else { throw CompanionError.textInputInactive }
    }

    public func typeText(_ text: String) async throws {
        if textSessionUUID == nil { try await beginTextInput() }
        guard let uuid = textSessionUUID else { throw CompanionError.textInputInactive }
        try await event("_tiC", content: .dictionary([
            "_tiV": .int(1),
            "_tiD": .data(RTIPayload.inputText(sessionUUID: uuid, text: text)),
        ]))
    }

    public func clearText() async throws {
        if textSessionUUID == nil { try await beginTextInput() }
        guard let uuid = textSessionUUID else { throw CompanionError.textInputInactive }
        try await event("_tiC", content: .dictionary([
            "_tiV": .int(1),
            "_tiD": .data(RTIPayload.clearText(sessionUUID: uuid)),
        ]))
    }

    public func endTextInput() async {
        _ = try? await request("_tiStop")
        textSessionUUID = nil
    }
}
