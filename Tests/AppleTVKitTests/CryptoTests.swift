import CryptoKit
import Foundation
import SRP
import Testing
@testable import AppleTVKit

@Suite struct CryptoTests {
    // MARK: - Counter cipher

    @Test func counterCipherRoundTripsBothDirections() throws {
        let k1 = SymmetricKey(size: .bits256)
        let k2 = SymmetricKey(size: .bits256)
        var client = ChaChaCounterCipher(outKey: k1, inKey: k2, layout: .counter12)
        var server = ChaChaCounterCipher(outKey: k2, inKey: k1, layout: .counter12)
        let aad = Data([0x08, 0x00, 0x00, 0x10])

        for index in 0..<5 {
            let message = Data("hello \(index)".utf8)
            let sealed = try client.encrypt(message, aad: aad)
            #expect(sealed.count == message.count + 16)
            #expect(try server.decrypt(sealed, aad: aad) == message)

            let reply = Data("reply \(index)".utf8)
            let sealedReply = try server.encrypt(reply, aad: aad)
            #expect(try client.decrypt(sealedReply, aad: aad) == reply)
        }
    }

    @Test func counterCipherRejectsWrongAAD() throws {
        let k1 = SymmetricKey(size: .bits256)
        let k2 = SymmetricKey(size: .bits256)
        var client = ChaChaCounterCipher(outKey: k1, inKey: k2, layout: .zeroPrefixed8)
        var server = ChaChaCounterCipher(outKey: k2, inKey: k1, layout: .zeroPrefixed8)
        let sealed = try client.encrypt(Data([1, 2, 3]), aad: Data([1]))
        #expect(throws: HAPError.decryptFailed) {
            try server.decrypt(sealed, aad: Data([2]))
        }
    }

    @Test func counterNonceLayouts() {
        let counter: UInt64 = 0x0102_0304_0506_0708
        let little: [UInt8] = [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01]
        let zeros: [UInt8] = [0, 0, 0, 0]

        let prefixed = ChaChaCounterCipher.nonce(for: counter, layout: .zeroPrefixed8)
        #expect(prefixed.withUnsafeBytes { Data($0) } == Data(zeros + little))

        let full = ChaChaCounterCipher.nonce(for: counter, layout: .counter12)
        #expect(full.withUnsafeBytes { Data($0) } == Data(little + zeros))
    }

    @Test func labelNonceIsLeftPadded() {
        let nonce = HAPCrypto.nonce("PS-Msg05")
        #expect(nonce.withUnsafeBytes { Data($0) } == Data([0, 0, 0, 0]) + Data("PS-Msg05".utf8))
    }

    // MARK: - Framed cipher

    @Test func framedCipherSplitsAndReassembles() throws {
        let k1 = SymmetricKey(size: .bits256)
        let k2 = SymmetricKey(size: .bits256)
        var sender = HAPFramedCipher(outKey: k1, inKey: k2)
        var receiver = HAPFramedCipher(outKey: k2, inKey: k1)
        let message = Data((0..<3000).map { UInt8($0 % 251) })

        let wire = try sender.encrypt(message)
        // Three frames: 1024, 1024, 952 plaintext bytes plus 18 bytes of overhead each.
        #expect(wire.count == 3000 + 3 * 18)

        // A partial buffer yields nothing and consumes nothing.
        let partial = try receiver.decrypt(buffer: wire.prefix(100))
        #expect(partial.plaintext.isEmpty)
        #expect(partial.consumed == 0)

        // The first frame plus part of the second yields one frame.
        let oneAndHalf = try receiver.decrypt(buffer: wire.prefix(1024 + 18 + 50))
        #expect(oneAndHalf.plaintext == message.prefix(1024))
        #expect(oneAndHalf.consumed == 1024 + 18)

        // The rest yields the other two frames.
        let rest = try receiver.decrypt(buffer: wire.suffix(from: oneAndHalf.consumed))
        #expect(rest.plaintext == message.suffix(from: 1024))
        #expect(rest.consumed == wire.count - oneAndHalf.consumed)
    }

    // MARK: - HKDF

    @Test func hkdfIsDeterministic() {
        let secret = Data(repeating: 7, count: 32)
        let a = HAPKDF.derive(secret: secret, salt: "Control-Salt", info: "Control-Write-Encryption-Key")
        let b = HAPKDF.derive(secret: secret, salt: "Control-Salt", info: "Control-Write-Encryption-Key")
        let c = HAPKDF.derive(secret: secret, salt: "Control-Salt", info: "Control-Read-Encryption-Key")
        #expect(HAPKDF.bytes(of: a) == HAPKDF.bytes(of: b))
        #expect(HAPKDF.bytes(of: a) != HAPKDF.bytes(of: c))
        #expect(HAPKDF.bytes(of: a).count == 32)
    }

    // MARK: - Hex

    @Test func hexRoundTrips() {
        let bytes = Data([0x00, 0x7f, 0xa5, 0xff])
        #expect(bytes.hexString == "007fa5ff")
        #expect(Data(hexString: "007FA5ff") == bytes)
        #expect(Data(hexString: "abc") == nil)
        #expect(Data(hexString: "zz") == nil)
    }

    // MARK: - SRP vector from srptools (the library pyatv uses)

    @Test func srpProofMatchesSrptoolsVector() throws {
        let configuration = SRPConfiguration<SHA512>(.N3072, padGeneratorForProof: false)
        let client = SRPClient(configuration: configuration)
        let salt = try #require(Data(hexString: "0f1e2d3c4b5a69788796a5b4c3d2e1f0"))
        let privateA = Data(repeating: 0x2c, count: 32)
        let publicA = try #require(Data(hexString: Vectors.a))
        let publicB = try #require(Data(hexString: Vectors.b))
        let keys = SRPKeyPair(public: SRPKey([UInt8](publicA)), private: SRPKey([UInt8](privateA)))

        let shared = try client.calculateSharedSecret(
            username: "Pair-Setup",
            password: "1234",
            salt: [UInt8](salt),
            clientKeys: keys,
            serverPublicKey: SRPKey([UInt8](publicB))
        )
        let k = Data(SHA512.hash(data: Data(shared.unpaddedBytes)))
        #expect(k.hexString == Vectors.k)

        let m1 = HAPPairSetup.clientProof(configuration: configuration, salt: salt, a: publicA, b: publicB, k: k)
        #expect(m1.hexString == Vectors.m)

        let hamk = HAPPairSetup.serverProof(a: publicA, m1: m1, k: k)
        #expect(hamk.hexString == Vectors.hamk)
    }

    // MARK: - Pair-setup loop against a fake accessory

    @Test func pairSetupFullLoop() throws {
        let configuration = SRPConfiguration<SHA512>(.N3072, padGeneratorForProof: false)
        let srpClient = SRPClient(configuration: configuration)
        let srpServer = SRPServer(configuration: configuration)
        let (saltBytes, verifier) = srpClient.generateSaltAndVerifier(username: "Pair-Setup", password: "1234", saltLength: 16)
        let salt = Data(saltBytes)
        let serverKeys = srpServer.generateKeys(verifier: verifier)
        let accessorySigning = Curve25519.Signing.PrivateKey()
        let accessoryID = Data("02:00:00:00:00:01".utf8)

        let setup = HAPPairSetup(clientID: "client-1", name: "Test Mac")

        // M1
        let m1 = try TLV8.decode(setup.m1())
        #expect(m1[.method] == Data([0]))
        #expect(m1[.state] == Data([1]))

        // M2 from the accessory.
        let m2 = TLV8.encode([
            (.state, Data([2])),
            (.salt, salt),
            (.publicKey, Data(serverKeys.public.unpaddedBytes)),
        ])

        // M3 from the client.
        let m3 = try TLV8.decode(try setup.m3(m2: m2, pin: "1234"))
        let a = try #require(m3[.publicKey])
        let proof = try #require(m3[.proof])
        #expect(a.count == 384)
        #expect(proof.count == 64)

        // The accessory checks the proof with the same conventions.
        let shared = try srpServer.calculateSharedSecret(clientPublicKey: SRPKey([UInt8](a)), serverKeys: serverKeys, verifier: verifier)
        let k = Data(SHA512.hash(data: Data(shared.unpaddedBytes)))
        let expected = HAPPairSetup.clientProof(configuration: configuration, salt: salt, a: a, b: Data(serverKeys.public.unpaddedBytes), k: k)
        #expect(expected == proof)
        let hamk = HAPPairSetup.serverProof(a: a, m1: proof, k: k)
        let m4 = TLV8.encode([(.state, Data([4])), (.proof, hamk)])

        // M5 from the client. The accessory decrypts and verifies the signature.
        let m5 = try TLV8.decode(try setup.m5(m4: m4))
        let encryptKey = HAPKDF.derive(secret: k, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
        let m5Plain = try HAPCrypto.open(try #require(m5[.encryptedData]), key: encryptKey, nonce: HAPCrypto.nonce("PS-Msg05"), aad: Data())
        let m5Sub = try TLV8.decode(m5Plain)
        let clientID = try #require(m5Sub[.identifier])
        let clientLTPK = try #require(m5Sub[.publicKey])
        let clientSignature = try #require(m5Sub[.signature])
        #expect(clientID == Data("client-1".utf8))
        #expect(m5Sub[.name] == OPACK.encode(["name": "Test Mac"]))
        let controllerSalt = HAPKDF.derive(secret: k, salt: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info")
        let clientInfo = HAPKDF.bytes(of: controllerSalt) + clientID + clientLTPK
        let clientKey = try Curve25519.Signing.PublicKey(rawRepresentation: clientLTPK)
        #expect(clientKey.isValidSignature(clientSignature, for: clientInfo))

        // M6 from the accessory.
        let accessorySalt = HAPKDF.derive(secret: k, salt: "Pair-Setup-Accessory-Sign-Salt", info: "Pair-Setup-Accessory-Sign-Info")
        let accessoryLTPK = accessorySigning.publicKey.rawRepresentation
        let accessoryInfo = HAPKDF.bytes(of: accessorySalt) + accessoryID + accessoryLTPK
        let accessorySignature = try accessorySigning.signature(for: accessoryInfo)
        let m6Sub = TLV8.encode([
            (.identifier, accessoryID),
            (.publicKey, accessoryLTPK),
            (.signature, accessorySignature),
        ])
        let m6 = TLV8.encode([
            (.state, Data([6])),
            (.encryptedData, try HAPCrypto.seal(m6Sub, key: encryptKey, nonce: HAPCrypto.nonce("PS-Msg06"), aad: Data())),
        ])

        let credentials = try setup.finish(m6: m6)
        #expect(credentials.ltpk == accessoryLTPK)
        #expect(credentials.accessoryID == accessoryID)
        #expect(credentials.clientID == Data("client-1".utf8))
        #expect(credentials.ltsk.count == 32)
        let restored = try Curve25519.Signing.PrivateKey(rawRepresentation: credentials.ltsk)
        #expect(restored.publicKey.rawRepresentation == clientLTPK)
    }

    @Test func pairSetupRejectsBadServerProof() throws {
        let configuration = SRPConfiguration<SHA512>(.N3072, padGeneratorForProof: false)
        let srpClient = SRPClient(configuration: configuration)
        let srpServer = SRPServer(configuration: configuration)
        let (saltBytes, verifier) = srpClient.generateSaltAndVerifier(username: "Pair-Setup", password: "1234", saltLength: 16)
        let serverKeys = srpServer.generateKeys(verifier: verifier)
        let setup = HAPPairSetup(clientID: "c", name: "n")
        _ = setup.m1()
        let m2 = TLV8.encode([
            (.state, Data([2])),
            (.salt, Data(saltBytes)),
            (.publicKey, Data(serverKeys.public.unpaddedBytes)),
        ])
        _ = try setup.m3(m2: m2, pin: "1234")
        let m4 = TLV8.encode([(.state, Data([4])), (.proof, Data(repeating: 1, count: 64))])
        #expect(throws: HAPError.proofMismatch) {
            try setup.m5(m4: m4)
        }
    }

    @Test func pairSetupReportsAccessoryError() {
        let setup = HAPPairSetup(clientID: "c", name: "n")
        _ = setup.m1()
        let m2 = TLV8.encode([(.state, Data([2])), (.error, Data([2]))])
        #expect(throws: HAPError.accessoryError(2)) {
            try setup.m3(m2: m2, pin: "0000")
        }
    }

    @Test func pairSetupRejectsCallsOutOfOrder() {
        let setup = HAPPairSetup(clientID: "c", name: "n")
        #expect(throws: HAPError.wrongStep) {
            try setup.m5(m4: TLV8.encode([(.state, Data([4]))]))
        }
    }

    // MARK: - Pair-verify loop against a fake accessory

    @Test func pairVerifyFullLoop() throws {
        let accessorySigning = Curve25519.Signing.PrivateKey()
        let clientSigning = Curve25519.Signing.PrivateKey()
        let accessoryID = Data("02:00:00:00:00:01".utf8)
        let clientID = Data("client-uuid".utf8)
        let credentials = HAPCredentials(
            ltpk: accessorySigning.publicKey.rawRepresentation,
            ltsk: clientSigning.rawRepresentation,
            accessoryID: accessoryID,
            clientID: clientID
        )
        let verify = HAPPairVerify(credentials: credentials)

        // M1
        let m1 = try TLV8.decode(verify.m1())
        #expect(m1[.state] == Data([1]))
        let clientEphemeral = try #require(m1[.publicKey])
        #expect(clientEphemeral.count == 32)

        // Accessory side of M2.
        let accessoryEphemeralKey = Curve25519.KeyAgreement.PrivateKey()
        let accessoryEphemeral = accessoryEphemeralKey.publicKey.rawRepresentation
        let agreement = try accessoryEphemeralKey.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientEphemeral)
        )
        let shared = agreement.withUnsafeBytes { Data($0) }
        let sessionKey = HAPKDF.derive(secret: shared, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
        let accessoryInfo = accessoryEphemeral + accessoryID + clientEphemeral
        let accessorySub = TLV8.encode([
            (.identifier, accessoryID),
            (.signature, try accessorySigning.signature(for: accessoryInfo)),
        ])
        let m2 = TLV8.encode([
            (.state, Data([2])),
            (.publicKey, accessoryEphemeral),
            (.encryptedData, try HAPCrypto.seal(accessorySub, key: sessionKey, nonce: HAPCrypto.nonce("PV-Msg02"), aad: Data())),
        ])

        // M3 from the client. The accessory verifies it.
        let m3 = try TLV8.decode(try verify.m3(m2: m2))
        #expect(m3[.state] == Data([3]))
        let m3Plain = try HAPCrypto.open(try #require(m3[.encryptedData]), key: sessionKey, nonce: HAPCrypto.nonce("PV-Msg03"), aad: Data())
        let m3Sub = try TLV8.decode(m3Plain)
        #expect(m3Sub[.identifier] == clientID)
        let clientInfo = clientEphemeral + clientID + accessoryEphemeral
        #expect(clientSigning.publicKey.isValidSignature(try #require(m3Sub[.signature]), for: clientInfo))

        // M4
        try verify.finish(m4: TLV8.encode([(.state, Data([4]))]))

        // Both sides derive the same channel keys.
        let keys = verify.sessionKeys(salt: "", outputInfo: "ClientEncrypt-main", inputInfo: "ServerEncrypt-main")
        let accessoryOut = HAPKDF.derive(secret: shared, salt: "", info: "ServerEncrypt-main")
        let accessoryIn = HAPKDF.derive(secret: shared, salt: "", info: "ClientEncrypt-main")
        #expect(HAPKDF.bytes(of: keys.out) == HAPKDF.bytes(of: accessoryIn))
        #expect(HAPKDF.bytes(of: keys.in) == HAPKDF.bytes(of: accessoryOut))

        var client = ChaChaCounterCipher(outKey: keys.out, inKey: keys.in, layout: .counter12)
        var accessory = ChaChaCounterCipher(outKey: accessoryOut, inKey: accessoryIn, layout: .counter12)
        let header = Data([0x08, 0, 0, 5])
        let sealed = try client.encrypt(Data("hello".utf8), aad: header)
        #expect(try accessory.decrypt(sealed, aad: header) == Data("hello".utf8))
    }

    @Test func pairVerifyRejectsWrongAccessoryKey() throws {
        let realAccessory = Curve25519.Signing.PrivateKey()
        let impostor = Curve25519.Signing.PrivateKey()
        let credentials = HAPCredentials(
            ltpk: realAccessory.publicKey.rawRepresentation,
            ltsk: Curve25519.Signing.PrivateKey().rawRepresentation,
            accessoryID: Data("id".utf8),
            clientID: Data("c".utf8)
        )
        let verify = HAPPairVerify(credentials: credentials)
        let clientEphemeral = try #require(try TLV8.decode(verify.m1())[.publicKey])
        let ephemeralKey = Curve25519.KeyAgreement.PrivateKey()
        let ephemeral = ephemeralKey.publicKey.rawRepresentation
        let shared = try ephemeralKey.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientEphemeral))
        let sessionKey = HAPKDF.derive(secret: shared.withUnsafeBytes { Data($0) }, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
        let sub = TLV8.encode([
            (.identifier, Data("id".utf8)),
            (.signature, try impostor.signature(for: ephemeral + Data("id".utf8) + clientEphemeral)),
        ])
        let m2 = TLV8.encode([
            (.state, Data([2])),
            (.publicKey, ephemeral),
            (.encryptedData, try HAPCrypto.seal(sub, key: sessionKey, nonce: HAPCrypto.nonce("PV-Msg02"), aad: Data())),
        ])
        #expect(throws: HAPError.signatureInvalid) {
            try verify.m3(m2: m2)
        }
    }

    // MARK: - Credential store

    @Test func credentialStoreRoundTrips() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("atv-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CredentialStore(directory: directory)
        let creds = HAPCredentials(ltpk: Data([1]), ltsk: Data([2]), accessoryID: Data([3]), clientID: Data([4]))
        try await store.save(StoredDevice(name: "Living Room", companion: creds, macAddress: "02:00:00:00:00:01"), for: "dev-1")

        let fresh = CredentialStore(directory: directory)
        let loaded = try await fresh.device(for: "dev-1")
        #expect(loaded?.name == "Living Room")
        #expect(loaded?.companion == creds)
        #expect(loaded?.macAddress == "02:00:00:00:00:01")

        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("credentials.json").path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)

        try await fresh.remove(for: "dev-1")
        #expect(try await fresh.device(for: "dev-1") == nil)
    }

    @Test func clientIdentifierIsStable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("atv-id-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = CredentialStore.clientID(directory: directory)
        #expect(CredentialStore.clientID(directory: directory) == first)
        #expect(UUID(uuidString: first) != nil)
    }
}

/// Values from srptools 1.0.1 with username "Pair-Setup", PIN "1234",
/// salt 0f1e2d3c4b5a69788796a5b4c3d2e1f0, client private 0x2c * 32, server private 0x1b * 32.
private enum Vectors {
    static let a = "47b81e115d8d4c644bdf6c7413a5f8565e855bb26bcca1e1bf918c33ac04f21150ae33b77ead22bc649cace1bcf31f2b244f7323bc7ea8738c75bdd95267610c1b4e7be6b06e07da5e12a198598a9bf97ea17525552d4a3857cef1181a31c0670f4b8fc01968e2b6ae63b338c9dd283f74e4736b368873c08b7e8c99a2834906868db568d87e4286cacaf50b42f1fdbb961fc889099693bd9c8597d7b45fe7ede3a2d93f11e85609806f7cf91acadb49577b11ab52d4c85f62adbf6e8e6ffc49aead4c72edb3e591c378c5f627e94dfc23203dc0b7581d38ccec391a7bba993364418cf92ca618343787e48523358e0c3f2ad7677807bbf35a82b3bea178aee0113618e0975a22d899163792ce365cab1195ce75f07b4ce1b90ee8ac7f0764f46b227e000fe2a9e780d8ead1014a03d9e73ff1a5f3f75d63f80fb8103fe236db3db12bed68a7a213d60f7ba2d780aeab65810e2aaae0d749026c2dfcdd37ce7706dfba44a7cef3e2334bdf7a09d7fd3b5f363a112efcca32e0fc52e34742d5bd"
    static let b = "9b9e4d95c85cc1f8538343c95e8ab45e43b8d02720f365f694a935a37e224be871b2c7477f80cae0916f0a515d3ff1ceded79b08f5419da7604917901b07724264cf10d7e0477bd18d0b8d4ba449923854dfa943b500fa31dc6a1854689b71652d16e3de0be9f1947e7e9413924b98f5d4fb147d985ba59d3f7a0676642ddb55e2b88603380f393f4572435d0629e86122da9f6b51c02b7e8a7078736e639908b33fc9309097702dd5b806935b167508d30cef35b3e47a2a5be9ce7e26cb5c0008d13ea7014b96a8f5d014bc41d39a178856897096742c59e6272ba02f6f454037c6856545f11c64b90f6b1693cdcce91663ba9012f8a63ef201f1f7f36603733c4fd5fb121af3884358eceddb1687a6a121f7a6c0e37f4d710fffa5b29651b95ad6d35a321de9b7afb23f792a5ba5f7b6153c39a4ad0f7442f383666069ef7adeb073e08b0c0865d93ef659b8d1d52fab948bf4538c98d12ad83120b6d7b637d23669cf722f0e13734ded934f4912bffcfdeefb67c85cb634ed8d933659d830"
    static let m = "68033aa3cab121198e99f0a5e5c81daa977d4ebbd2c60b5a4be323a30034ac1c35c7454f527e056b97ddc271db1253d5eb66e5c28d1333951081674173a23af9"
    static let k = "2637ed6fa51c2b06157f26055500959ff06c8a92de775105c79f39981bcf6b49d07cbedbde411f338eb9826f913ea507592312486fbff059aa95f9d675e9f8be"
    static let hamk = "d18519e2845d8cf6021391cbe8f57d7850e5ac99628d75afc8426052b33cb06392421325d1b9b27d1aa4c6d51078913381c6d49c5d568bcb907365962dce71eb"
}
