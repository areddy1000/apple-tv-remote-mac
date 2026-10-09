import CryptoKit
import Foundation

/// ChaCha20-Poly1305 stream with one message counter per direction.
/// The counter forms the nonce. `NonceLayout` picks where it sits.
public struct ChaChaCounterCipher: Sendable {
    /// Where the counter sits inside the 12 byte nonce.
    public enum NonceLayout: Sendable {
        /// The counter fills all 12 bytes little-endian. Companion Link uses this.
        case counter12
        /// 4 zero bytes then the 8 byte little-endian counter. The AirPlay channels use this.
        case zeroPrefixed8
    }

    private let outKey: SymmetricKey
    private let inKey: SymmetricKey
    private let layout: NonceLayout
    private var outCounter: UInt64 = 0
    private var inCounter: UInt64 = 0

    public init(outKey: SymmetricKey, inKey: SymmetricKey, layout: NonceLayout) {
        self.outKey = outKey
        self.inKey = inKey
        self.layout = layout
    }

    /// Seals one message. Returns ciphertext followed by the 16 byte tag.
    public mutating func encrypt(_ plaintext: Data, aad: Data) throws -> Data {
        let nonce = Self.nonce(for: outCounter, layout: layout)
        outCounter += 1
        return try HAPCrypto.seal(plaintext, key: outKey, nonce: nonce, aad: aad)
    }

    /// Opens one message that has the 16 byte tag at the end.
    public mutating func decrypt(_ ciphertext: Data, aad: Data) throws -> Data {
        let nonce = Self.nonce(for: inCounter, layout: layout)
        let plaintext = try HAPCrypto.open(ciphertext, key: inKey, nonce: nonce, aad: aad)
        inCounter += 1
        return plaintext
    }

    static func nonce(for counter: UInt64, layout: NonceLayout) -> ChaChaPoly.Nonce {
        var bytes = Data(capacity: 12)
        let zeros = Data(repeating: 0, count: 4)
        if layout == .zeroPrefixed8 { bytes.append(zeros) }
        bytes.append(littleEndian: counter, width: 8)
        if layout == .counter12 { bytes.append(zeros) }
        // The buffer is 12 bytes in both layouts, so the nonce init cannot fail.
        return try! ChaChaPoly.Nonce(data: bytes)
    }
}

/// Framed cipher for the AirPlay HTTP and event channels.
/// Each frame is a 2 byte little-endian plaintext length, the ciphertext, and the 16 byte tag.
/// The length bytes are the AAD. A frame holds at most 1024 plaintext bytes.
public struct HAPFramedCipher: Sendable {
    static let maxFrame = 1024
    private static let tagLength = 16
    private var cipher: ChaChaCounterCipher

    public init(outKey: SymmetricKey, inKey: SymmetricKey) {
        cipher = ChaChaCounterCipher(outKey: outKey, inKey: inKey, layout: .zeroPrefixed8)
    }

    /// Seals data into one or more frames.
    public mutating func encrypt(_ plaintext: Data) throws -> Data {
        var out = Data()
        var offset = plaintext.startIndex
        repeat {
            let end = min(offset + Self.maxFrame, plaintext.endIndex)
            let block = plaintext.subdata(in: offset..<end)
            var header = Data(capacity: 2)
            header.append(littleEndian: UInt64(block.count), width: 2)
            out.append(header)
            out.append(try cipher.encrypt(block, aad: header))
            offset = end
        } while offset < plaintext.endIndex
        return out
    }

    /// Opens every full frame in `buffer`. Returns the plaintext and the number of bytes consumed.
    /// A partial frame at the end stays in the buffer for the next call.
    public mutating func decrypt(buffer: Data) throws -> (plaintext: Data, consumed: Int) {
        var out = Data()
        var index = buffer.startIndex
        while index + 2 <= buffer.endIndex {
            let length = Int(buffer[index]) | Int(buffer[index + 1]) << 8
            let frameEnd = index + 2 + length + Self.tagLength
            guard frameEnd <= buffer.endIndex else { break }
            let header = buffer.subdata(in: index..<(index + 2))
            let body = buffer.subdata(in: (index + 2)..<frameEnd)
            out.append(try cipher.decrypt(body, aad: header))
            index = frameEnd
        }
        return (out, index - buffer.startIndex)
    }
}
