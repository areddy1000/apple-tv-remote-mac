import CryptoKit
import Foundation
import Network

public enum CompanionConnectionError: Error, Sendable {
    case closed
    case cancelled
    case failed(String)
}

/// A TCP link to one Apple TV. Frames go out in order on a dedicated queue.
/// After pair-verify the OPACK frames are encrypted. Pairing frames stay clear.
public actor CompanionConnection {
    public let endpoint: NWEndpoint
    public nonisolated let frames: AsyncStream<CompanionFrame>

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "atv.companion", qos: .userInteractive)
    private let framesContinuation: AsyncStream<CompanionFrame>.Continuation
    private var cipher: ChaChaCounterCipher?
    private var buffer = Data()
    private var isOpen = false

    /// Logs every frame when ATV_TRACE is set. Development aid. Payloads stay private.
    static let trace = ProcessInfo.processInfo.environment["ATV_TRACE"] == "1"

    public init(endpoint: NWEndpoint) {
        self.endpoint = endpoint
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 8
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 15
        }
        self.connection = NWConnection(to: endpoint, using: parameters)
        let (stream, continuation) = AsyncStream.makeStream(of: CompanionFrame.self, bufferingPolicy: .unbounded)
        self.frames = stream
        self.framesContinuation = continuation
    }

    /// Opens the socket. Returns when the link is ready.
    public func open() async throws {
        guard !isOpen else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce(continuation)
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    once.resume(.success(()))
                    Task { await self.markOpen() }
                case .failed(let error):
                    once.resume(.failure(CompanionConnectionError.failed(error.localizedDescription)))
                    Task { await self.close() }
                case .cancelled:
                    once.resume(.failure(CompanionConnectionError.cancelled))
                    Task { await self.close() }
                case .waiting(let error):
                    // A waiting socket tries again by itself, for ever. Fail the open instead.
                    ATVLog.companion.info("waiting: \(error.localizedDescription, privacy: .public)")
                    once.resume(.failure(CompanionConnectionError.failed(error.localizedDescription)))
                    Task { await self.close() }
                default:
                    break
                }
            }
            once.fail(after: SocketLimits.openTimeout, on: queue, with: CompanionConnectionError.failed("The Apple TV did not answer.")) { [weak self] in
                Task { await self?.close() }
            }
            connection.start(queue: queue)
        }
    }

    private func markOpen() {
        guard !isOpen else { return }
        isOpen = true
        receiveLoop()
    }

    /// Installs the session cipher after pair-verify.
    public func enableEncryption(outKey: SymmetricKey, inKey: SymmetricKey) {
        cipher = ChaChaCounterCipher(outKey: outKey, inKey: inKey, layout: .counter12)
    }

    /// Sends one frame. Encrypts OPACK frames when the cipher is set.
    public func send(_ frame: CompanionFrame) async throws {
        guard isOpen else { throw CompanionConnectionError.closed }
        let data: Data
        if var cipher, !frame.type.isAuth {
            let header = CompanionFrame.header(type: frame.type, length: frame.payload.count + 16)
            let sealed = try cipher.encrypt(frame.payload, aad: header)
            self.cipher = cipher
            data = header + sealed
        } else {
            data = frame.encoded()
        }
        if Self.trace {
            ATVLog.companion.debug("send type \(frame.type.rawValue) \(frame.payload.count) bytes \(Self.describe(frame.payload), privacy: .private)")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: CompanionConnectionError.failed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private static func describe(_ payload: Data) -> String {
        (try? OPACK.decode(payload)).map { String(describing: $0) } ?? payload.hexString
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            Task {
                if let content { await self.ingest(content) }
                if error != nil || isComplete {
                    await self.close()
                } else {
                    await self.receiveLoop()
                }
            }
        }
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        while let (frame, header, consumed) = CompanionFrame.read(from: buffer) {
            buffer.removeFirst(consumed)
            var delivered = frame
            if var cipher, !frame.type.isAuth {
                do {
                    delivered.payload = try cipher.decrypt(frame.payload, aad: header)
                    self.cipher = cipher
                } catch {
                    ATVLog.companion.error("decrypt failed for frame type \(frame.type.rawValue)")
                    continue
                }
            }
            if Self.trace {
                ATVLog.companion.debug("recv type \(frame.type.rawValue) \(delivered.payload.count) bytes \(Self.describe(delivered.payload), privacy: .private)")
            }
            framesContinuation.yield(delivered)
        }
    }

    /// Cancels the socket and ends the frame stream.
    public func close() {
        guard isOpen || connection.state != .cancelled else { return }
        isOpen = false
        connection.cancel()
        framesContinuation.finish()
    }
}
