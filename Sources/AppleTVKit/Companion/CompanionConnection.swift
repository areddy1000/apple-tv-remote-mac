import CryptoKit
import Foundation
import Network

public enum CompanionConnectionError: Error, Sendable {
    case closed
    case cancelled
    case failed(String)
    case decrypt
}

/// A TCP link to one Apple TV. Frames go out in order on a dedicated queue.
/// After pair-verify the OPACK frames are encrypted. Pairing frames stay clear.
public actor CompanionConnection {
    public let endpoint: NWEndpoint
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "atv.companion", qos: .userInteractive)
    private var cipher: ChaChaCounterCipher?
    private var buffer = Data()
    private var inbound: AsyncStream<CompanionFrame>.Continuation?
    public nonisolated let frames: AsyncStream<CompanionFrame>
    private let framesContinuation: AsyncStream<CompanionFrame>.Continuation
    private var isOpen = false

    public init(endpoint: NWEndpoint) {
        self.endpoint = endpoint
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 8
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 15
        }
        self.connection = NWConnection(to: endpoint, using: params)
        let (stream, continuation) = AsyncStream.makeStream(of: CompanionFrame.self, bufferingPolicy: .unbounded)
        self.frames = stream
        self.framesContinuation = continuation
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
                    box.resume(.failure(CompanionConnectionError.failed(error.localizedDescription)))
                    Task { await self.close() }
                case .cancelled:
                    box.resume(.failure(CompanionConnectionError.cancelled))
                    Task { await self.close() }
                case .waiting(let error):
                    ATVLog.companion.info("waiting: \(error.localizedDescription, privacy: .public)")
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func markOpen() {
        guard !isOpen else { return }
        isOpen = true
        receiveLoop()
    }

    /// Remote host and port as resolved by the socket.
    public func remote() -> (host: String, port: UInt16)? {
        guard let path = connection.currentPath, let remote = path.remoteEndpoint else { return nil }
        if case .hostPort(let host, let port) = remote {
            return (host.debugDescription, port.rawValue)
        }
        return nil
    }

    /// Installs the session cipher after pair-verify.
    public func enableEncryption(outKey: SymmetricKey, inKey: SymmetricKey) {
        cipher = ChaChaCounterCipher(outKey: outKey, inKey: inKey, layout: .counter12)
    }

    /// Logs every frame when ATV_TRACE is set. Development aid.
    static let trace = ProcessInfo.processInfo.environment["ATV_TRACE"] == "1"

    /// Sends one frame. Encrypts OPACK frames when the cipher is set.
    public func send(_ frame: CompanionFrame) async throws {
        guard isOpen else { throw CompanionConnectionError.closed }
        let data: Data
        if var cipher, !frame.type.isAuth {
            let aad = CompanionFrame.header(type: frame.type, length: frame.payload.count + 16)
            let sealed = try cipher.encrypt(frame.payload, aad: aad)
            self.cipher = cipher
            data = aad + sealed
        } else {
            data = frame.encoded()
        }
        if Self.trace {
            let text = (try? OPACK.decode(frame.payload)).map { String(describing: $0) } ?? frame.payload.hexString
            ATVLog.companion.debug("send \(frame.type.rawValue) \(text, privacy: .public)")
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
                    ATVLog.companion.error("decrypt failed for frame \(frame.type.rawValue)")
                    continue
                }
            }
            if Self.trace {
                let text = (try? OPACK.decode(delivered.payload)).map { String(describing: $0) } ?? delivered.payload.hexString
                ATVLog.companion.debug("recv \(frame.type.rawValue) \(text, privacy: .public)")
            }
            framesContinuation.yield(delivered)
        }
    }

    public func close() {
        guard isOpen || connection.state != .cancelled else { return }
        isOpen = false
        connection.cancel()
        framesContinuation.finish()
    }
}

/// Resumes a continuation one time only.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }
}
