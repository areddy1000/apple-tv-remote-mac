import Foundation

/// A response from the device. Header names are lower-cased.
public struct HTTPResponse: Sendable, Equatable {
    public var protocolName: String
    public var version: String
    public var status: Int
    public var reason: String
    public var headers: [String: String]
    public var body: Data

    public init(protocolName: String = "HTTP", version: String = "1.1", status: Int, reason: String = "OK", headers: [String: String] = [:], body: Data = Data()) {
        self.protocolName = protocolName
        self.version = version
        self.status = status
        self.reason = reason
        self.headers = HTTPMessage.lowercased(headers)
        self.body = body
    }

    /// Looks up a header without regard to case.
    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

/// A request the device sends to us on the event channel.
public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    public var path: String
    public var protocolName: String
    public var version: String
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, protocolName: String = "HTTP", version: String = "1.1", headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.protocolName = protocolName
        self.version = version
        self.headers = HTTPMessage.lowercased(headers)
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

/// One parsed message. The first line decides which kind it is.
public enum HTTPMessage: Sendable, Equatable {
    case response(HTTPResponse)
    case request(HTTPRequest)

    static func lowercased(_ headers: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in headers { out[key.lowercased()] = value }
        return out
    }

    /// Formats a request the way pyatv and iOS do. The body length comes last among
    /// the fixed headers, then the caller's headers follow.
    public static func formatRequest(
        method: String,
        uri: String,
        protocolLine: String,
        userAgent: String,
        contentType: String?,
        headers: [(String, String)],
        body: Data?
    ) -> Data {
        var text = "\(method) \(uri) \(protocolLine)"
        if !headers.contains(where: { $0.0.lowercased() == "user-agent" }) {
            text += "\r\nUser-Agent: \(userAgent)"
        }
        if let contentType {
            text += "\r\nContent-Type: \(contentType)"
        }
        if let body, !body.isEmpty {
            text += "\r\nContent-Length: \(body.count)"
        }
        for (key, value) in headers {
            text += "\r\n\(key): \(value)"
        }
        text += "\r\n\r\n"
        var data = Data(text.utf8)
        if let body { data.append(body) }
        return data
    }

    /// Formats a response to a device request.
    public static func formatResponse(
        protocolName: String,
        version: String,
        status: Int,
        reason: String,
        headers: [(String, String)],
        body: Data
    ) -> Data {
        var text = "\(protocolName)/\(version) \(status) \(reason)\r\n"
        for (key, value) in headers {
            text += "\(key): \(value)\r\n"
        }
        if !body.isEmpty {
            text += "Content-Length: \(body.count)\r\n"
        }
        text += "\r\n"
        var data = Data(text.utf8)
        data.append(body)
        return data
    }

    /// Parses one message from the front of the buffer.
    /// Returns nil when the buffer holds less than one full message.
    public static func parse(_ buffer: Data) -> (message: HTTPMessage, consumed: Int)? {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer[buffer.startIndex..<separator.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let firstLine = lines.first, !firstLine.isEmpty else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = separator.upperBound
        guard buffer.endIndex - bodyStart >= contentLength else { return nil }
        let body = Data(buffer[bodyStart..<(bodyStart + contentLength)])
        let consumed = (bodyStart + contentLength) - buffer.startIndex

        let parts = firstLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }

        if let slash = parts[0].firstIndex(of: "/"), let status = Int(parts[1]) {
            // Response: PROTO/VERSION CODE REASON
            let protocolName = String(parts[0][..<slash])
            let version = String(parts[0][parts[0].index(after: slash)...])
            let reason = parts.count > 2 ? parts[2] : ""
            let response = HTTPResponse(protocolName: protocolName, version: version, status: status, reason: reason, headers: headers, body: body)
            return (.response(response), consumed)
        }

        // Request: METHOD PATH PROTO/VERSION
        guard parts.count == 3, let slash = parts[2].firstIndex(of: "/") else { return nil }
        let protocolName = String(parts[2][..<slash])
        let version = String(parts[2][parts[2].index(after: slash)...])
        let request = HTTPRequest(method: parts[0], path: parts[1], protocolName: protocolName, version: version, headers: headers, body: body)
        return (.request(request), consumed)
    }
}
