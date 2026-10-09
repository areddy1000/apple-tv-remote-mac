import CryptoKit
import Foundation

/// TLV8 tags that the HAP pairing flow uses.
enum HAPTag {
    static let method: UInt8 = 0x00
    static let identifier: UInt8 = 0x01
    static let salt: UInt8 = 0x02
    static let publicKey: UInt8 = 0x03
    static let proof: UInt8 = 0x04
    static let encryptedData: UInt8 = 0x05
    static let state: UInt8 = 0x06
    static let error: UInt8 = 0x07
    static let signature: UInt8 = 0x0A
    static let name: UInt8 = 0x11
}

/// Minimal TLV8 codec for the crypto module.
/// The Codec module has the public TLV8 type. This one stays internal.
enum HAPTLV {
    /// Encodes items in order. A value longer than 255 bytes splits into fragments with the same tag.
    static func encode(_ items: [(UInt8, Data)]) -> Data {
        var out = Data()
        for (tag, value) in items {
            if value.isEmpty {
                out.append(tag)
                out.append(0)
                continue
            }
            var offset = 0
            while offset < value.count {
                let chunk = min(255, value.count - offset)
                out.append(tag)
                out.append(UInt8(chunk))
                out.append(value.subdata(in: (value.startIndex + offset)..<(value.startIndex + offset + chunk)))
                offset += chunk
            }
        }
        return out
    }

    /// Decodes a TLV8 buffer. Fragments with the same tag concatenate.
    static func decode(_ data: Data) -> [UInt8: Data] {
        var result: [UInt8: Data] = [:]
        var index = data.startIndex
        while index + 1 < data.endIndex {
            let tag = data[index]
            let length = Int(data[index + 1])
            let start = index + 2
            let end = min(start + length, data.endIndex)
            let value = data.subdata(in: start..<end)
            result[tag, default: Data()].append(value)
            index = end
        }
        return result
    }

    /// Encodes the OPACK dictionary `{"name": name}`.
    /// The Codec module has the full OPACK codec. This covers the single pairing case.
    static func encodeNameDictionary(_ name: String) -> Data {
        var out = Data([0xE1])
        out.append(opackString("name"))
        out.append(opackString(name))
        return out
    }

    private static func opackString(_ string: String) -> Data {
        let bytes = Data(string.utf8)
        var out = Data()
        if bytes.count <= 32 {
            out.append(0x40 + UInt8(bytes.count))
        } else {
            out.append(0x61)
            out.append(UInt8(min(bytes.count, 255)))
        }
        out.append(bytes.prefix(255))
        return out
    }
}

/// Errors from the HAP pairing state machines.
public enum HAPError: Error, Equatable, Sendable {
    /// The accessory sent a state that the flow did not expect.
    case stateMismatch(expected: UInt8, got: UInt8)
    /// The accessory sent a TLV error code.
    case accessoryError(UInt8)
    /// The SRP proof from the accessory did not match.
    case proofMismatch
    /// The AEAD open operation failed.
    case decryptFailed
    /// A required TLV tag is absent.
    case missingField(UInt8)
    /// An Ed25519 signature did not verify.
    case signatureInvalid
    /// The accessory identifier did not match the stored credentials.
    case identifierMismatch
    /// A key had the wrong size or format.
    case invalidKey
    /// The flow is not in the right step for this call.
    case wrongStep
}

/// Shared helpers for the HAP AEAD operations.
enum HAPCrypto {
    /// Makes a 12 byte nonce from a short label. Zero bytes pad the label on the left.
    static func nonce(_ label: String) -> ChaChaPoly.Nonce {
        let bytes = Data(label.utf8)
        var padded = Data(repeating: 0, count: max(0, 12 - bytes.count))
        padded.append(bytes)
        // The label is at most 12 bytes, so the nonce init cannot fail.
        return try! ChaChaPoly.Nonce(data: padded)
    }

    /// Seals data and returns ciphertext followed by the 16 byte tag.
    static func seal(_ plaintext: Data, key: SymmetricKey, nonce: ChaChaPoly.Nonce, aad: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        return box.ciphertext + box.tag
    }

    /// Opens ciphertext that has the 16 byte tag at the end.
    static func open(_ combined: Data, key: SymmetricKey, nonce: ChaChaPoly.Nonce, aad: Data) throws -> Data {
        guard combined.count >= 16 else { throw HAPError.decryptFailed }
        let split = combined.endIndex - 16
        let ciphertext = combined.subdata(in: combined.startIndex..<split)
        let tag = combined.subdata(in: split..<combined.endIndex)
        do {
            let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try ChaChaPoly.open(box, using: key, authenticating: aad)
        } catch {
            throw HAPError.decryptFailed
        }
    }

    /// Reads the state tag and checks it.
    static func checkState(_ tlv: [UInt8: Data], expected: UInt8) throws {
        if let error = tlv[HAPTag.error], let code = error.first {
            throw HAPError.accessoryError(code)
        }
        guard let state = tlv[HAPTag.state]?.first else { throw HAPError.missingField(HAPTag.state) }
        guard state == expected else { throw HAPError.stateMismatch(expected: expected, got: state) }
    }

    /// Returns the value for a tag or throws.
    static func field(_ tlv: [UInt8: Data], _ tag: UInt8) throws -> Data {
        guard let value = tlv[tag] else { throw HAPError.missingField(tag) }
        return value
    }
}
