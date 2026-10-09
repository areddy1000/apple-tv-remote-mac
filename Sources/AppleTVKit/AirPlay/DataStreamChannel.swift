import CryptoKit
import Foundation
import Network

/// The 32 byte header of a data stream message. All integers are big-endian.
public struct DataStreamHeader: Sendable, Equatable {
    public static let length = 32
    public static let padding: UInt32 = 0

    /// Total size, header included.
    public var size: UInt32
    /// 12 bytes. `sync` for a request, `rply` for a reply. Zero padded.
    public var messageType: Data
    /// 4 bytes. `comm` for a request. Zero for a reply.
    public var command: Data
    public var sequence: UInt64
    public var padding: UInt32

    public init(size: UInt32, messageType: Data, command: Data, sequence: UInt64, padding: UInt32 = DataStreamHeader.padding) {
        self.size = size
        self.messageType = DataStreamHeader.pad(messageType, to: 12)
        self.command = DataStreamHeader.pad(command, to: 4)
        self.sequence = sequence
        self.padding = padding
    }

    static func pad(_ data: Data, to width: Int) -> Data {
        var out = Data(data.prefix(width))
        if out.count < width { out.append(Data(repeating: 0, count: width - out.count)) }
        return out
    }

    public var isSync: Bool { messageType.starts(with: Data("sync".utf8)) }

    public func encoded() -> Data {
        var out = Data(capacity: Self.length)
        out.append(contentsOf: withUnsafeBytes(of: size.bigEndian) { Data($0) })
        out.append(messageType)
        out.append(command)
        out.append(contentsOf: withUnsafeBytes(of: sequence.bigEndian) { Data($0) })
        out.append(contentsOf: withUnsafeBytes(of: padding.bigEndian) { Data($0) })
        return out
    }

    public static func decode(_ data: Data) -> DataStreamHeader? {
        guard data.count >= length else { return nil }
        let start = data.startIndex
        func be32(_ offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(data[start + offset + $1]) }
        }
        func be64(_ offset: Int) -> UInt64 {
            (0..<8).reduce(UInt64(0)) { ($0 << 8) | UInt64(data[start + offset + $1]) }
        }
        return DataStreamHeader(
            size: be32(0),
            messageType: Data(data[(start + 4)..<(start + 16)]),
            command: Data(data[(start + 16)..<(start + 20)]),
            sequence: be64(20),
            padding: be32(28)
        )
    }
}

/// Pure helpers for the data stream wire format. Tests cover these.
public enum DataStreamCodec {
    /// Wraps protobufs in the binary plist the stream carries.
    public static func encodePayload(protobufs: [Data]) -> Data {
        var joined = Data()
        for message in protobufs {
            joined.append(Varint.encode(UInt64(message.count)))
            joined.append(message)
        }
        return BinaryPlist.encode(.dict([("params", .dict([("data", .data(joined))]))]))
    }

    /// Reads the protobufs out of a payload. Returns nil when the plist has no data.
    public static func decodePayload(_ payload: Data) -> [Data]? {
        guard let plist = try? BinaryPlist.decode(payload),
              let data = plist["params"]?["data"]?.dataValue
        else { return nil }
        return splitProtobufs(data)
    }

    /// Splits varint-prefixed protobufs. A message that starts with the type tag 0x08
    /// and no prefix is taken whole, as pyatv does for ConfigureConnectionMessage.
    public static func splitProtobufs(_ data: Data) -> [Data] {
        var out: [Data] = []
        var index = data.startIndex
        while index < data.endIndex {
            if data[index] == 0x08 {
                out.append(Data(data[index...]))
                break
            }
            var cursor = index - data.startIndex
            guard let length = try? Varint.decode(Data(data[data.startIndex...]), at: &cursor) else { break }
            let bodyStart = data.startIndex + cursor
            let bodyEnd = bodyStart + Int(length)
            guard bodyEnd <= data.endIndex else { break }
            out.append(Data(data[bodyStart..<bodyEnd]))
            index = bodyEnd
        }
        return out
    }

    public static func encodeMessage(header: DataStreamHeader, payload: Data) -> Data {
        var fixed = header
        fixed.size = UInt32(DataStreamHeader.length + payload.count)
        var out = fixed.encoded()
        out.append(payload)
        return out
    }

    /// Reads one message from the front of the buffer.
    public static func decodeMessage(_ buffer: Data) -> (header: DataStreamHeader, payload: Data, consumed: Int)? {
        guard let header = DataStreamHeader.decode(buffer) else { return nil }
        let size = Int(header.size)
        guard size >= DataStreamHeader.length, buffer.count >= size else { return nil }
        let payload = Data(buffer[(buffer.startIndex + DataStreamHeader.length)..<(buffer.startIndex + size)])
        return (header, payload, size)
    }

    public static func reply(sequence: UInt64) -> Data {
        encodeMessage(
            header: DataStreamHeader(size: 0, messageType: Data("rply".utf8), command: Data(), sequence: sequence),
            payload: Data()
        )
    }
}

/// The encrypted channel that carries MRP protobufs inside the AirPlay session.
public actor DataStreamChannel {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "atv.airplay.data", qos: .userInitiated)
    private var cipher: HAPFramedCipher
    private var sealedBuffer = Data()
    private var plainBuffer = Data()
    private var isOpen = false
    /// pyatv keeps one sequence number for the whole session.
    private let sequence: UInt64 = UInt64.random(in: 0x1_0000_0000..<0x1_FFFF_FFFF)
    public nonisolated let messages: AsyncStream<Data>
    private let messagesContinuation: AsyncStream<Data>.Continuation

    public init(host: String, port: UInt16, outKey: SymmetricKey, inKey: SymmetricKey) {
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 8
        }
        self.connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 7000, using: params)
        self.cipher = HAPFramedCipher(outKey: outKey, inKey: inKey)
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        self.messages = stream
        self.messagesContinuation = continuation
    }

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
        receiveNext()
    }

    /// Sends one protobuf as a `sync` message.
    public func send(protobuf: Data) async throws {
        let payload = DataStreamCodec.encodePayload(protobufs: [protobuf])
        let header = DataStreamHeader(size: 0, messageType: Data("sync".utf8), command: Data("comm".utf8), sequence: sequence)
        try await write(DataStreamCodec.encodeMessage(header: header, payload: payload))
    }

    private func write(_ plain: Data) async throws {
        guard isOpen else { throw AirPlayHTTPError.notConnected }
        let sealed = try cipher.encrypt(plain)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: sealed, completion: .contentProcessed { error in
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

    private func ingest(_ data: Data) async {
        sealedBuffer.append(data)
        do {
            let (plain, consumed) = try cipher.decrypt(buffer: sealedBuffer)
            sealedBuffer.removeFirst(consumed)
            plainBuffer.append(plain)
        } catch {
            ATVLog.airplay.error("data stream decrypt failed")
            close()
            return
        }
        while let (header, payload, consumed) = DataStreamCodec.decodeMessage(plainBuffer) {
            plainBuffer.removeFirst(consumed)
            if !payload.isEmpty, let protobufs = DataStreamCodec.decodePayload(payload) {
                for message in protobufs { messagesContinuation.yield(message) }
            }
            if header.isSync {
                try? await write(DataStreamCodec.reply(sequence: header.sequence))
            }
        }
    }

    public func close() {
        guard isOpen else { return }
        isOpen = false
        connection.cancel()
        messagesContinuation.finish()
    }
}
