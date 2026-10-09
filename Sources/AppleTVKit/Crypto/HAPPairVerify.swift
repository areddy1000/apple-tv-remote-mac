import CryptoKit
import Foundation

/// HAP pair-verify state machine. It has no transport.
/// After `finish`, `sessionKeys` derives the channel keys for the caller.
public final class HAPPairVerify {
    private enum Step { case start, sentM1, sentM3, done }

    private let credentials: HAPCredentials
    private let ephemeral = Curve25519.KeyAgreement.PrivateKey()
    private var step: Step = .start
    private var sharedSecret = Data()

    public init(credentials: HAPCredentials) {
        self.credentials = credentials
    }

    /// Builds M1 with state 1 and our ephemeral public key.
    public func m1() -> Data {
        step = .sentM1
        return HAPTLV.encode([
            (HAPTag.state, Data([1])),
            (HAPTag.publicKey, ephemeral.publicKey.rawRepresentation),
        ])
    }

    /// Consumes M2, verifies the accessory, and builds the encrypted M3.
    public func m3(m2: Data) throws -> Data {
        guard step == .sentM1 else { throw HAPError.wrongStep }
        let tlv = HAPTLV.decode(m2)
        try HAPCrypto.checkState(tlv, expected: 2)
        let accessoryEphemeral = try HAPCrypto.field(tlv, HAPTag.publicKey)
        let encrypted = try HAPCrypto.field(tlv, HAPTag.encryptedData)

        guard let accessoryKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: accessoryEphemeral) else {
            throw HAPError.invalidKey
        }
        let agreement: SharedSecret
        do {
            agreement = try ephemeral.sharedSecretFromKeyAgreement(with: accessoryKey)
        } catch {
            throw HAPError.invalidKey
        }
        sharedSecret = agreement.withUnsafeBytes { Data($0) }
        let sessionKey = HAPKDF.derive(secret: sharedSecret, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")

        let plain = try HAPCrypto.open(encrypted, key: sessionKey, nonce: HAPCrypto.nonce("PV-Msg02"), aad: Data())
        let sub = HAPTLV.decode(plain)
        let identifier = try HAPCrypto.field(sub, HAPTag.identifier)
        let signature = try HAPCrypto.field(sub, HAPTag.signature)
        guard identifier == credentials.accessoryID else { throw HAPError.identifierMismatch }
        guard let ltpk = try? Curve25519.Signing.PublicKey(rawRepresentation: credentials.ltpk) else {
            throw HAPError.invalidKey
        }
        let clientEphemeral = ephemeral.publicKey.rawRepresentation
        let accessoryInfo = accessoryEphemeral + identifier + clientEphemeral
        guard ltpk.isValidSignature(signature, for: accessoryInfo) else { throw HAPError.signatureInvalid }

        guard let ltsk = try? Curve25519.Signing.PrivateKey(rawRepresentation: credentials.ltsk) else {
            throw HAPError.invalidKey
        }
        let clientInfo = clientEphemeral + credentials.clientID + accessoryEphemeral
        let clientSignature = try ltsk.signature(for: clientInfo)
        let reply = HAPTLV.encode([
            (HAPTag.identifier, credentials.clientID),
            (HAPTag.signature, clientSignature),
        ])
        let sealed = try HAPCrypto.seal(reply, key: sessionKey, nonce: HAPCrypto.nonce("PV-Msg03"), aad: Data())
        step = .sentM3
        return HAPTLV.encode([
            (HAPTag.state, Data([3])),
            (HAPTag.encryptedData, sealed),
        ])
    }

    /// Consumes M4 and checks for success.
    public func finish(m4: Data) throws {
        guard step == .sentM3 else { throw HAPError.wrongStep }
        let tlv = HAPTLV.decode(m4)
        try HAPCrypto.checkState(tlv, expected: 4)
        step = .done
    }

    /// Derives the two channel keys from the shared secret.
    /// Companion: salt "", "ClientEncrypt-main", "ServerEncrypt-main".
    /// AirPlay control: "Control-Salt", "Control-Write-Encryption-Key", "Control-Read-Encryption-Key".
    public func sessionKeys(salt: String, outputInfo: String, inputInfo: String) -> (out: SymmetricKey, in: SymmetricKey) {
        (
            HAPKDF.derive(secret: sharedSecret, salt: salt, info: outputInfo),
            HAPKDF.derive(secret: sharedSecret, salt: salt, info: inputInfo)
        )
    }
}
