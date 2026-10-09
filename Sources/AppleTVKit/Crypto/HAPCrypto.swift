import CryptoKit
import Foundation

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
    case missingField(TLV8Tag)
    /// An Ed25519 signature did not verify.
    case signatureInvalid
    /// The accessory identifier did not match the stored credentials.
    case identifierMismatch
    /// A key had the wrong size or format.
    case invalidKey
    /// The flow is not in the right step for this call.
    case wrongStep
}

/// Shared helpers for the HAP AEAD operations and TLV checks.
enum HAPCrypto {
    /// Makes a 12 byte nonce from a short label. Zero bytes pad the label on the left.
    static func nonce(_ label: String) -> ChaChaPoly.Nonce {
        let bytes = Data(label.utf8)
        precondition(bytes.count <= 12, "A nonce label has at most 12 bytes.")
        var padded = Data(repeating: 0, count: 12 - bytes.count)
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

    /// Throws when the TLV carries an error code or a state other than `expected`.
    static func checkState(_ tlv: [UInt8: Data], expected: UInt8) throws {
        if let code = tlv[.error]?.first {
            throw HAPError.accessoryError(code)
        }
        guard let state = tlv[.state]?.first else { throw HAPError.missingField(.state) }
        guard state == expected else { throw HAPError.stateMismatch(expected: expected, got: state) }
    }

    /// Returns the value for a tag or throws.
    static func field(_ tlv: [UInt8: Data], _ tag: TLV8Tag) throws -> Data {
        guard let value = tlv[tag] else { throw HAPError.missingField(tag) }
        return value
    }
}
