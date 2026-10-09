import CryptoKit
import Foundation
import SRP

/// HAP pair-setup state machine. It has no transport.
/// Companion wraps each TLV in an OPACK `_pd` field. AirPlay posts the TLV as an HTTP body.
///
/// SRP byte conventions. These match srptools, the library pyatv uses, and HAP-python.
/// - k = H(N | PAD(g)) and u = H(PAD(A) | PAD(B)). swift-srp does both.
/// - K = H(S) with S as minimal big-endian bytes, no padding.
/// - M1 = H( H(N) xor H(g) | H("Pair-Setup") | salt | A | B | K ) with A, B and g minimal.
/// - HAMK = H( A | M1 | K ) with A minimal.
/// swift-srp pads A, B, S and g in its proof, so this file computes K, M1 and HAMK itself.
/// The client key A regenerates until it has no leading zero byte, so A is the same in both forms.
public final class HAPPairSetup {
    private enum Step { case start, sentM1, sentM3, sentM5, done }

    private let clientID: String
    private let name: String
    private let configuration = SRPConfiguration<SHA512>(.N3072, padGeneratorForProof: false)
    private var step: Step = .start
    private var clientPublic = Data()
    private var clientProof = Data()
    private var sessionKey = Data()
    private var signingKey: Curve25519.Signing.PrivateKey?

    /// - Parameters:
    ///   - clientID: Our pairing identifier. The accessory keeps one pairing per identifier.
    ///   - name: The name the accessory shows for this controller.
    public init(clientID: String, name: String) {
        self.clientID = clientID
        self.name = name
    }

    /// Builds M1: method 0 and state 1.
    public func m1() -> Data {
        step = .sentM1
        return TLV8.encode([(.method, Data([0])), (.state, Data([1]))])
    }

    /// Consumes M2 and builds M3 with the client public key and proof.
    public func m3(m2: Data, pin: String) throws -> Data {
        guard step == .sentM1 else { throw HAPError.wrongStep }
        let tlv = try TLV8.decode(m2)
        try HAPCrypto.checkState(tlv, expected: 2)
        let salt = try HAPCrypto.field(tlv, .salt)
        let serverPublic = try HAPCrypto.field(tlv, .publicKey)

        let client = SRPClient(configuration: configuration)
        var keys = client.generateKeys()
        while keys.public.unpaddedBytes.count != configuration.sizeN {
            keys = client.generateKeys()
        }
        let serverKey = SRPKey([UInt8](serverPublic))
        let shared: SRPKey
        do {
            shared = try client.calculateSharedSecret(
                username: "Pair-Setup",
                password: pin,
                salt: [UInt8](salt),
                clientKeys: keys,
                serverPublicKey: serverKey
            )
        } catch {
            // swift-srp rejects a server key that is zero modulo N.
            throw HAPError.invalidKey
        }

        let a = Data(keys.public.unpaddedBytes)
        let b = Data(serverKey.unpaddedBytes)
        let k = Data(SHA512.hash(data: Data(shared.unpaddedBytes)))
        let proof = Self.clientProof(configuration: configuration, salt: salt, a: a, b: b, k: k)

        clientPublic = a
        clientProof = proof
        sessionKey = k
        step = .sentM3
        return TLV8.encode([
            (.state, Data([3])),
            (.publicKey, a),
            (.proof, proof),
        ])
    }

    /// Consumes M4, checks the server proof, and builds the encrypted M5.
    public func m5(m4: Data) throws -> Data {
        guard step == .sentM3 else { throw HAPError.wrongStep }
        let tlv = try TLV8.decode(m4)
        try HAPCrypto.checkState(tlv, expected: 4)
        let serverProof = try HAPCrypto.field(tlv, .proof)
        let expected = Self.serverProof(a: clientPublic, m1: clientProof, k: sessionKey)
        guard Self.constantTimeEqual(serverProof, expected) else { throw HAPError.proofMismatch }

        let encryptKey = HAPKDF.derive(secret: sessionKey, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
        let signSalt = HAPKDF.derive(secret: sessionKey, salt: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info")
        let key = Curve25519.Signing.PrivateKey()
        signingKey = key
        let ltpk = key.publicKey.rawRepresentation
        let clientIDData = Data(clientID.utf8)
        let deviceInfo = HAPKDF.bytes(of: signSalt) + clientIDData + ltpk
        let signature = try key.signature(for: deviceInfo)

        let sub = TLV8.encode([
            (.identifier, clientIDData),
            (.publicKey, ltpk),
            (.signature, signature),
            (.name, OPACK.encode(.dictionary(["name": .string(name)]))),
        ])
        let encrypted = try HAPCrypto.seal(sub, key: encryptKey, nonce: HAPCrypto.nonce("PS-Msg05"), aad: Data())
        step = .sentM5
        return TLV8.encode([
            (.state, Data([5])),
            (.encryptedData, encrypted),
        ])
    }

    /// Consumes M6, verifies the accessory signature, and returns the credentials.
    public func finish(m6: Data) throws -> HAPCredentials {
        guard step == .sentM5, let key = signingKey else { throw HAPError.wrongStep }
        let tlv = try TLV8.decode(m6)
        try HAPCrypto.checkState(tlv, expected: 6)
        let encrypted = try HAPCrypto.field(tlv, .encryptedData)
        let encryptKey = HAPKDF.derive(secret: sessionKey, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
        let plain = try HAPCrypto.open(encrypted, key: encryptKey, nonce: HAPCrypto.nonce("PS-Msg06"), aad: Data())
        let sub = try TLV8.decode(plain)
        let accessoryID = try HAPCrypto.field(sub, .identifier)
        let accessoryLTPK = try HAPCrypto.field(sub, .publicKey)
        let signature = try HAPCrypto.field(sub, .signature)

        let accessorySalt = HAPKDF.derive(secret: sessionKey, salt: "Pair-Setup-Accessory-Sign-Salt", info: "Pair-Setup-Accessory-Sign-Info")
        let accessoryInfo = HAPKDF.bytes(of: accessorySalt) + accessoryID + accessoryLTPK
        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: accessoryLTPK) else {
            throw HAPError.invalidKey
        }
        guard publicKey.isValidSignature(signature, for: accessoryInfo) else { throw HAPError.signatureInvalid }

        step = .done
        return HAPCredentials(
            ltpk: accessoryLTPK,
            ltsk: key.rawRepresentation,
            accessoryID: accessoryID,
            clientID: clientIDData
        )
    }

    private var clientIDData: Data { Data(clientID.utf8) }

    // MARK: - SRP proofs

    /// M1 = H( H(N) xor H(g) | H(I) | s | A | B | K ).
    static func clientProof(configuration: SRPConfiguration<SHA512>, salt: Data, a: Data, b: Data, k: Data) -> Data {
        let hashN = Data(SHA512.hash(data: Data(configuration.N.bytes)))
        let hashG = Data(SHA512.hash(data: Data(configuration.g.bytes)))
        var xored = Data(count: hashN.count)
        for index in 0..<hashN.count {
            xored[index] = hashN[index] ^ hashG[index]
        }
        let hashUser = Data(SHA512.hash(data: Data("Pair-Setup".utf8)))
        return Data(SHA512.hash(data: xored + hashUser + salt + a + b + k))
    }

    /// HAMK = H( A | M1 | K ).
    static func serverProof(a: Data, m1: Data, k: Data) -> Data {
        Data(SHA512.hash(data: a + m1 + k))
    }

    /// Compares two buffers in a time that depends on the length only.
    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(lhs, rhs) {
            diff |= x ^ y
        }
        return diff == 0
    }
}
