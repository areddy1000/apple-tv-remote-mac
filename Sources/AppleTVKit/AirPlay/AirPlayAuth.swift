import Foundation

/// HAP pair-setup and pair-verify over the AirPlay HTTP port.
/// The TLV travels as the raw request body.
public enum AirPlayAuth {
    static let headers: [(String, String)] = [
        ("User-Agent", "AirPlay/320.20"),
        ("Connection", "keep-alive"),
        ("X-Apple-HKP", "3"),
    ]
    static let contentType = "application/octet-stream"

    /// Pairs with the TV. The TV shows a PIN after the first request.
    public static func pairSetup(
        connection: AirPlayHTTPConnection,
        clientID: String,
        name: String,
        pin: @Sendable () async -> String?
    ) async throws -> HAPCredentials {
        let setup = HAPPairSetup(clientID: clientID, name: name)
        _ = try await post(connection, "/pair-pin-start", body: nil)
        let m2 = try await post(connection, "/pair-setup", body: setup.m1())
        try checkError(m2)
        guard let pin = await pin() else { throw CompanionError.pairingCancelled }
        let m4 = try await post(connection, "/pair-setup", body: try setup.m3(m2: m2, pin: pin))
        try checkError(m4)
        let m6 = try await post(connection, "/pair-setup", body: try setup.m5(m4: m4))
        try checkError(m6)
        let credentials = try setup.finish(m6: m6)
        ATVLog.pairing.info("airplay pair-setup complete")
        return credentials
    }

    /// Verifies stored credentials. The caller derives channel keys from the result.
    public static func pairVerify(connection: AirPlayHTTPConnection, credentials: HAPCredentials) async throws -> HAPPairVerify {
        let verify = HAPPairVerify(credentials: credentials)
        let m2 = try await post(connection, "/pair-verify", body: verify.m1())
        try checkError(m2)
        let m4 = try await post(connection, "/pair-verify", body: try verify.m3(m2: m2))
        try verify.finish(m4: m4)
        ATVLog.pairing.info("airplay pair-verify complete")
        return verify
    }

    private static func post(_ connection: AirPlayHTTPConnection, _ path: String, body: Data?) async throws -> Data {
        let response = try await connection.send(
            method: "POST", path: path, headers: headers, body: body, contentType: contentType
        )
        guard (200..<300).contains(response.status) else {
            throw AirPlayHTTPError.status(response.status, response.reason)
        }
        return response.body
    }

    private static func checkError(_ tlv: Data) throws {
        let decoded = try TLV8.decode(tlv)
        if let error = TLV8.error(in: decoded) {
            throw CompanionError.accessoryError(code: Int64(error.rawValue), message: "pairing error \(error)")
        }
    }
}
