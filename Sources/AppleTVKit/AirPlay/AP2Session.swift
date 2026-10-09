import CryptoKit
import Foundation

/// The identity the Mac presents on the AirPlay side.
/// The defaults mirror pyatv, which the TV accepts.
public struct AirPlayIdentity: Sendable {
    public var name: String
    public var model: String
    public var osName: String
    public var osVersion: String
    public var osBuild: String
    public var deviceID: String
    public var macAddress: String

    public init(
        name: String,
        model: String = "iPhone10,6",
        osName: String = "iPhone OS",
        osVersion: String = "14.7.1",
        osBuild: String = "18G82",
        deviceID: String = "FF:70:79:61:74:76",
        macAddress: String = "FF:70:79:61:74:76"
    ) {
        self.name = name
        self.model = model
        self.osName = osName
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.deviceID = deviceID
        self.macAddress = macAddress
    }
}

public enum AP2Error: Error, Sendable {
    case notVerified
    case badResponse(String)
}

/// One AirPlay 2 remote-control session: control channel, event channel, data channel.
public actor AP2Session {
    public let host: String
    public let port: UInt16
    private let identity: AirPlayIdentity
    private let control: AirPlayHTTPConnection
    private var verifier: HAPPairVerify?
    private var event: AirPlayHTTPConnection?
    private var eventTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    private(set) public var dataChannel: DataStreamChannel?

    // RTSP session values. pyatv picks them at random once per session.
    private let sessionID = UInt32.random(in: 0...UInt32.max)
    private let dacpID = String(format: "%llX", UInt64.random(in: 0...UInt64.max))
    private let activeRemote = UInt32.random(in: 0...UInt32.max)
    private var cseq = 0

    static let userAgent = "AirPlay/550.10"
    static let plistType = "application/x-apple-binary-plist"

    public init(host: String, port: UInt16, identity: AirPlayIdentity) {
        self.host = host
        self.port = port
        self.identity = identity
        self.control = AirPlayHTTPConnection(host: host, port: port)
    }

    /// The control connection, for pairing before `open`.
    public var controlConnection: AirPlayHTTPConnection { control }

    public func openControl() async throws {
        ATVLog.airplay.info("control channel opening \(self.host, privacy: .public):\(self.port)")
        try await control.open()
        ATVLog.airplay.info("control channel open")
    }

    /// Verifies the credentials and seals the control channel.
    public func verify(credentials: HAPCredentials) async throws {
        let verifier = try await AirPlayAuth.pairVerify(connection: control, credentials: credentials)
        let keys = verifier.sessionKeys(
            salt: "Control-Salt",
            outputInfo: "Control-Write-Encryption-Key",
            inputInfo: "Control-Read-Encryption-Key"
        )
        await control.enableEncryption(outKey: keys.out, inKey: keys.in)
        self.verifier = verifier
    }

    /// Opens the event and data channels. Needs a verified control channel.
    public func setupRemoteControl() async throws {
        guard let verifier else { throw AP2Error.notVerified }
        _ = try? await rtsp(method: "GET", uri: "/info")
        try await setupEventChannel(verifier)
        _ = try await rtsp(method: "RECORD", uri: nil)
        try await setupDataChannel(verifier)
        startFeedback()
    }

    private var rtspURI: String {
        get async {
            let local = await control.localAddress ?? "127.0.0.1"
            return "rtsp://\(local)/\(sessionID)"
        }
    }

    /// One RTSP exchange with the headers iOS sends.
    @discardableResult
    func rtsp(method: String, uri: String?, body: PlistValue? = nil) async throws -> HTTPResponse {
        let sequence = cseq
        cseq += 1
        let headers: [(String, String)] = [
            ("CSeq", String(sequence)),
            ("DACP-ID", dacpID),
            ("Active-Remote", String(activeRemote)),
            ("Client-Instance", dacpID),
        ]
        let target: String
        if let uri {
            target = uri
        } else {
            target = await rtspURI
        }
        let response = try await control.send(
            method: method,
            path: target,
            headers: headers,
            body: body.map { BinaryPlist.encode($0) },
            contentType: body == nil ? nil : Self.plistType,
            protocolLine: "RTSP/1.0",
            userAgent: Self.userAgent,
            timeout: .seconds(6)
        )
        guard (200..<300).contains(response.status) else {
            throw AirPlayHTTPError.status(response.status, "\(method) \(target): \(response.reason)")
        }
        return response
    }

    private func setupEventChannel(_ verifier: HAPPairVerify) async throws {
        let body: PlistValue = .dict([
            ("isRemoteControlOnly", .bool(true)),
            ("osName", .string(identity.osName)),
            ("sourceVersion", .string("550.10")),
            ("timingProtocol", .string("None")),
            ("model", .string(identity.model)),
            ("deviceID", .string(identity.deviceID)),
            ("osVersion", .string(identity.osVersion)),
            ("osBuildVersion", .string(identity.osBuild)),
            ("macAddress", .string(identity.macAddress)),
            ("sessionUUID", .string(UUID().uuidString)),
            ("name", .string(identity.name)),
        ])
        let response = try await rtsp(method: "SETUP", uri: nil, body: body)
        let plist = try BinaryPlist.decode(response.body)
        guard let eventPort = plist["eventPort"]?.intValue, eventPort > 0, eventPort <= 65535 else {
            throw AP2Error.badResponse("SETUP returned no eventPort")
        }
        // The device writes to us on this channel, so the read and write names swap.
        let keys = verifier.sessionKeys(
            salt: "Events-Salt",
            outputInfo: "Events-Read-Encryption-Key",
            inputInfo: "Events-Write-Encryption-Key"
        )
        let event = AirPlayHTTPConnection(host: host, port: UInt16(eventPort))
        try await event.open()
        await event.enableEncryption(outKey: keys.out, inKey: keys.in)
        self.event = event
        eventTask = Task { [event] in
            for await request in event.incomingRequests {
                var headers: [(String, String)] = [("Content-Length", "0"), ("Audio-Latency", "0")]
                if let server = request.header("Server") { headers.append(("Server", server)) }
                if let cseq = request.header("CSeq") { headers.append(("CSeq", cseq)) }
                try? await event.respond(status: 200, headers: headers, to: request)
            }
        }
        ATVLog.airplay.info("event channel open on port \(eventPort)")
    }

    private func setupDataChannel(_ verifier: HAPPairVerify) async throws {
        // The seed is part of the data stream salt. Keep it positive so the plist stays a signed int.
        let seed = UInt64.random(in: 0...UInt64(Int64.max))
        let body: PlistValue = .dict([
            ("streams", .array([
                .dict([
                    ("controlType", .int(2)),
                    ("channelID", .string(UUID().uuidString)),
                    ("seed", .int(Int64(seed))),
                    ("clientUUID", .string(UUID().uuidString)),
                    ("type", .int(130)),
                    ("wantsDedicatedSocket", .bool(true)),
                    ("clientTypeUUID", .string("1910A70F-DBC0-4242-AF95-115DB30604E1")),
                ]),
            ])),
        ])
        let response = try await rtsp(method: "SETUP", uri: nil, body: body)
        let plist = try BinaryPlist.decode(response.body)
        guard let dataPort = plist["streams"]?[0]?["dataPort"]?.intValue, dataPort > 0, dataPort <= 65535 else {
            throw AP2Error.badResponse("SETUP returned no dataPort")
        }
        let keys = verifier.sessionKeys(
            salt: "DataStream-Salt\(seed)",
            outputInfo: "DataStream-Output-Encryption-Key",
            inputInfo: "DataStream-Input-Encryption-Key"
        )
        let channel = DataStreamChannel(host: host, port: UInt16(dataPort), outKey: keys.out, inKey: keys.in)
        try await channel.open()
        dataChannel = channel
        ATVLog.airplay.info("data channel open on port \(dataPort)")
    }

    /// iOS posts feedback every two seconds to keep the session alive.
    private func startFeedback() {
        feedbackTask?.cancel()
        feedbackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                do {
                    try await self.rtsp(method: "POST", uri: "/feedback")
                } catch {
                    ATVLog.airplay.error("feedback failed: \(String(describing: error), privacy: .public)")
                    await self.close()
                    return
                }
            }
        }
    }

    public func close() async {
        feedbackTask?.cancel()
        feedbackTask = nil
        eventTask?.cancel()
        eventTask = nil
        await dataChannel?.close()
        dataChannel = nil
        await event?.close()
        event = nil
        await control.close()
    }
}
