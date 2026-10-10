import Foundation

/// HAP pair-verify over the AirPlay HTTP port.
/// The TLV travels as the raw request body. The Companion pairing record serves here too.
public enum AirPlayAuth {
    static let headers: [(String, String)] = [
        ("User-Agent", "AirPlay/320.20"),
        ("Connection", "keep-alive"),
        ("X-Apple-HKP", "3"),
    ]
    static let contentType = "application/octet-stream"

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
