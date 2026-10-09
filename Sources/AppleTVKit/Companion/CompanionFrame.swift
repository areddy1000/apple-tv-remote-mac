import Foundation

/// Frame types on the Companion Link transport.
public enum CompanionFrameType: UInt8, Sendable {
    case unknown = 0x00
    case noOp = 0x01
    case psStart = 0x03
    case psNext = 0x04
    case pvStart = 0x05
    case pvNext = 0x06
    case uOPACK = 0x07
    case eOPACK = 0x08
    case pOPACK = 0x09
    case paReq = 0x0A
    case paRsp = 0x0B

    /// Pairing frames travel in the clear.
    public var isAuth: Bool {
        switch self {
        case .psStart, .psNext, .pvStart, .pvNext: true
        default: false
        }
    }
}

/// One frame: a type byte, a 3 byte big-endian length, and the payload.
public struct CompanionFrame: Sendable, Equatable {
    public var type: CompanionFrameType
    public var payload: Data

    public init(type: CompanionFrameType, payload: Data) {
        self.type = type
        self.payload = payload
    }

    /// The 4 byte header. It is also the AAD for encrypted frames.
    public static func header(type: CompanionFrameType, length: Int) -> Data {
        var data = Data(capacity: 4)
        data.append(type.rawValue)
        data.append(UInt8((length >> 16) & 0xFF))
        data.append(UInt8((length >> 8) & 0xFF))
        data.append(UInt8(length & 0xFF))
        return data
    }

    public func encoded() -> Data {
        var data = CompanionFrame.header(type: type, length: payload.count)
        data.append(payload)
        return data
    }

    /// Reads one frame from the front of the buffer. Returns nil when the buffer is short.
    public static func read(from buffer: Data) -> (frame: CompanionFrame, header: Data, consumed: Int)? {
        guard buffer.count >= 4 else { return nil }
        let start = buffer.startIndex
        let typeByte = buffer[start]
        let length = (Int(buffer[start + 1]) << 16) | (Int(buffer[start + 2]) << 8) | Int(buffer[start + 3])
        guard buffer.count >= 4 + length else { return nil }
        let type = CompanionFrameType(rawValue: typeByte) ?? .unknown
        let header = Data(buffer[start..<start + 4])
        let payload = Data(buffer[(start + 4)..<(start + 4 + length)])
        return (CompanionFrame(type: type, payload: payload), header, 4 + length)
    }
}
