import CryptoKit
import Foundation
import Network

public enum AirPlayHTTPError: Error, Sendable, Equatable {
    case notConnected
    case closed
    case timeout(String)
    case status(Int, String)
    case failed(String)
}

/// A long-lived HTTP or RTSP connection to the Apple TV on one TCP socket.
/// After pair-verify every byte is sealed in HAP frames.
/// The device sends its own requests on the event channel. They arrive on `incomingRequests`.
public actor AirPlayHTTPConnection {
    let host: String
    let port: UInt16
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "atv.airplay.http", qos: .userInitiated)
    private var cipher: HAPFramedCipher?
    private var sealedBuffer = Data()
    private var plainBuffer = Data()
    /// Requests that wait for a response, oldest first. Responses arrive in request order.
    private var pending = PendingReplies<UInt64, HTTPResponse>()
    private var nextRequestID: UInt64 = 0
    private var isOpen = false
    private(set) public var localAddress: String?
    public nonisolated let incomingRequests: AsyncStream<HTTPRequest>
    private let incomingContinuation: AsyncStream<HTTPRequest>.Continuation

    static let trace = ProcessInfo.processInfo.environment["ATV_TRACE"] == "1"

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 8
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 15
        }
        self.connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 7000, using: params)
        let (stream, continuation) = AsyncStream.makeStream(of: HTTPRequest.self, bufferingPolicy: .unbounded)
        self.incomingRequests = stream
        self.incomingContinuation = continuation
    }

    /// Opens the socket. Returns when the link is ready.
    public func open() async throws {
        guard !isOpen else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = ResumeOnce(continuation)
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    box.resume(.success(()))
                    Task { await self.markOpen() }
                case .failed(let error):
                    box.resume(.failure(AirPlayHTTPError.failed(error.localizedDescription)))
                    Task { await self.close() }
                case .cancelled:
                    box.resume(.failure(AirPlayHTTPError.closed))
                    Task { await self.close() }
                case .waiting(let error):
                    // A waiting socket tries again by itself, for ever. Fail the open instead.
                    box.resume(.failure(AirPlayHTTPError.failed(error.localizedDescription)))
                    Task { await self.close() }
                default:
                    break
                }
            }
            box.fail(after: SocketLimits.openTimeout, on: queue, with: AirPlayHTTPError.timeout("open")) { [weak self] in
                Task { await self?.close() }
            }
            connection.start(queue: queue)
        }
    }

    private func markOpen() {
        guard !isOpen else { return }
        isOpen = true
        if let path = connection.currentPath, let local = path.localEndpoint, case .hostPort(let host, _) = local {
            // The host may carry an interface suffix such as "%en0". Drop it.
            localAddress = host.debugDescription.split(separator: "%").first.map(String.init)
        }
        receiveNext()
    }

    /// Installs the HAP session cipher. Later requests and responses are sealed.
    public func enableEncryption(outKey: SymmetricKey, inKey: SymmetricKey) {
        cipher = HAPFramedCipher(outKey: outKey, inKey: inKey)
    }

    /// Sends one request and waits for its response. Responses arrive in request order.
    public func send(
        method: String,
        path: String,
        headers: [(String, String)] = [],
        body: Data? = nil,
        contentType: String? = nil,
        protocolLine: String = "HTTP/1.1",
        userAgent: String = "AirPlay/320.20",
        timeout: Duration = .seconds(10)
    ) async throws -> HTTPResponse {
        guard isOpen else { throw AirPlayHTTPError.notConnected }
        let data = HTTPMessage.formatRequest(
            method: method, uri: path, protocolLine: protocolLine, userAgent: userAgent,
            contentType: contentType, headers: headers, body: body
        )
        if Self.trace {
            ATVLog.airplay.debug("send \(method, privacy: .public) \(path, privacy: .public) \(body?.count ?? 0) bytes")
        }
        try await write(data)
        let requestID = nextRequestID
        nextRequestID += 1
        let label = "\(method) \(path)"
        let response: HTTPResponse = try await withCheckedThrowingContinuation { continuation in
            let timer = PendingReplies<UInt64, HTTPResponse>.timer(after: timeout) { [weak self] in
                await self?.expire(requestID: requestID, label: label)
            }
            pending.add(requestID, continuation: continuation, timer: timer)
        }
        if Self.trace {
            ATVLog.airplay.debug("recv \(response.status) for \(method, privacy: .public) \(path, privacy: .public) \(response.body.count) bytes")
        }
        return response
    }

    /// Fails one request that got no answer in time. A request that was answered is left alone.
    private func expire(requestID: UInt64, label: String) {
        pending.resolve(requestID, with: .failure(AirPlayHTTPError.timeout(label)))
    }

    /// Answers a request the device sent us.
    public func respond(status: Int, reason: String = "OK", headers: [(String, String)], to request: HTTPRequest) async throws {
        let data = HTTPMessage.formatResponse(
            protocolName: request.protocolName, version: request.version,
            status: status, reason: reason, headers: headers, body: Data()
        )
        try await write(data)
    }

    private func write(_ plain: Data) async throws {
        guard isOpen else { throw AirPlayHTTPError.notConnected }
        var data = plain
        if var cipher {
            data = try cipher.encrypt(plain)
            self.cipher = cipher
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: AirPlayHTTPError.failed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            Task {
                if let content { await self.ingest(content) }
                if error != nil || isComplete {
                    await self.close()
                } else {
                    await self.receiveNext()
                }
            }
        }
    }

    private func ingest(_ data: Data) {
        if var cipher {
            sealedBuffer.append(data)
            do {
                let (plain, consumed) = try cipher.decrypt(buffer: sealedBuffer)
                self.cipher = cipher
                sealedBuffer.removeFirst(consumed)
                plainBuffer.append(plain)
            } catch {
                ATVLog.airplay.error("decrypt failed on \(self.host, privacy: .public):\(self.port)")
                close()
                return
            }
        } else {
            plainBuffer.append(data)
        }
        while let (message, consumed) = HTTPMessage.parse(plainBuffer) {
            plainBuffer.removeFirst(consumed)
            switch message {
            case .response(let response):
                if let oldest = pending.oldestKey {
                    pending.resolve(oldest, with: .success(response))
                } else {
                    ATVLog.airplay.debug("response with no request: \(response.status)")
                }
            case .request(let request):
                incomingContinuation.yield(request)
            }
        }
    }

    /// Cancels the socket, fails the waiting requests and ends the request stream.
    /// It always cancels, also for a socket that never opened. A second call does no harm.
    public func close() {
        isOpen = false
        connection.cancel()
        pending.failAll(AirPlayHTTPError.closed)
        incomingContinuation.finish()
    }
}
