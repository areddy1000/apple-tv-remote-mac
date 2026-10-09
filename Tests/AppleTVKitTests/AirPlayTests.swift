import CryptoKit
import Foundation
import Testing
@testable import AppleTVKit

@Suite("AirPlayTests")
struct AirPlayTests {
    // MARK: HTTP messages

    @Test func parsesResponseAcrossChunks() throws {
        let body = Data("hello world".utf8)
        var full = Data("RTSP/1.0 200 OK\r\nCSeq: 3\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        full.append(body)
        full.append(Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".utf8))

        var buffer = Data()
        var parsed: [HTTPMessage] = []
        for chunk in stride(from: 0, to: full.count, by: 7) {
            buffer.append(full[chunk..<min(chunk + 7, full.count)])
            while let (message, consumed) = HTTPMessage.parse(buffer) {
                parsed.append(message)
                buffer.removeFirst(consumed)
            }
        }
        #expect(parsed.count == 2)
        guard case .response(let first) = parsed[0], case .response(let second) = parsed[1] else {
            Issue.record("expected two responses")
            return
        }
        #expect(first.protocolName == "RTSP")
        #expect(first.version == "1.0")
        #expect(first.status == 200)
        #expect(first.header("cseq") == "3")
        #expect(first.header("Content-Type") == "text/plain")
        #expect(first.body == body)
        #expect(second.status == 404)
        #expect(second.reason == "Not Found")
        #expect(buffer.isEmpty)
    }

    @Test func parsesDeviceRequest() throws {
        let raw = Data("POST /command HTTP/1.1\r\nCSeq: 9\r\nServer: AirTunes/366.0\r\nContent-Length: 2\r\n\r\nok".utf8)
        let result = try #require(HTTPMessage.parse(raw))
        guard case .request(let request) = result.message else {
            Issue.record("expected a request")
            return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/command")
        #expect(request.protocolName == "HTTP")
        #expect(request.header("Server") == "AirTunes/366.0")
        #expect(request.body == Data("ok".utf8))
        #expect(result.consumed == raw.count)
    }

    @Test func requestFormatMatchesPyatvOrder() {
        let data = HTTPMessage.formatRequest(
            method: "SETUP", uri: "rtsp://10.0.0.2/123", protocolLine: "RTSP/1.0",
            userAgent: "AirPlay/550.10", contentType: "application/x-apple-binary-plist",
            headers: [("CSeq", "0"), ("DACP-ID", "ABC")], body: Data([1, 2, 3])
        )
        let text = String(decoding: data.prefix(data.count - 3), as: UTF8.self)
        #expect(text == "SETUP rtsp://10.0.0.2/123 RTSP/1.0\r\nUser-Agent: AirPlay/550.10\r\nContent-Type: application/x-apple-binary-plist\r\nContent-Length: 3\r\nCSeq: 0\r\nDACP-ID: ABC\r\n\r\n")
        #expect(data.suffix(3) == Data([1, 2, 3]))
    }

    @Test func parsesEncryptedResponseAcrossChunks() throws {
        let key1 = SymmetricKey(size: .bits256)
        let key2 = SymmetricKey(size: .bits256)
        var device = HAPFramedCipher(outKey: key1, inKey: key2)
        var client = HAPFramedCipher(outKey: key2, inKey: key1)

        let body = Data(repeating: 0x41, count: 2500)
        var plain = Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        plain.append(body)
        let sealed = try device.encrypt(plain)
        #expect(sealed.count == plain.count + 3 * 18)

        var sealedBuffer = Data()
        var plainBuffer = Data()
        var parsed: HTTPResponse?
        for chunk in stride(from: 0, to: sealed.count, by: 333) {
            sealedBuffer.append(sealed[chunk..<min(chunk + 333, sealed.count)])
            let (decrypted, consumed) = try client.decrypt(buffer: sealedBuffer)
            sealedBuffer.removeFirst(consumed)
            plainBuffer.append(decrypted)
            if let (message, used) = HTTPMessage.parse(plainBuffer), case .response(let response) = message {
                parsed = response
                plainBuffer.removeFirst(used)
            }
        }
        #expect(parsed?.status == 200)
        #expect(parsed?.body == body)
        #expect(sealedBuffer.isEmpty)
    }

    // MARK: Data stream

    @Test func dataStreamHeaderRoundTrip() throws {
        let header = DataStreamHeader(size: 40, messageType: Data("sync".utf8), command: Data("comm".utf8), sequence: 0x1_2345_6789)
        let encoded = header.encoded()
        #expect(encoded.count == 32)
        #expect(Array(encoded.prefix(4)) == [0, 0, 0, 40])
        #expect(Array(encoded[4..<16]) == Array("sync".utf8) + [0, 0, 0, 0, 0, 0, 0, 0])
        #expect(Array(encoded[16..<20]) == Array("comm".utf8))
        #expect(Array(encoded[20..<28]) == [0, 0, 0, 1, 0x23, 0x45, 0x67, 0x89])
        let decoded = try #require(DataStreamHeader.decode(encoded))
        #expect(decoded == header)
        #expect(decoded.isSync)
    }

    @Test func dataStreamMessageRoundTrip() throws {
        let protobuf = Data([0x08, 0x0F, 0x12, 0x03, 0x61, 0x62, 0x63])
        let payload = DataStreamCodec.encodePayload(protobufs: [protobuf])
        let header = DataStreamHeader(size: 0, messageType: Data("sync".utf8), command: Data("comm".utf8), sequence: 7)
        let message = DataStreamCodec.encodeMessage(header: header, payload: payload)
        var buffer = message
        buffer.append(DataStreamCodec.reply(sequence: 7))

        let first = try #require(DataStreamCodec.decodeMessage(buffer))
        #expect(first.header.sequence == 7)
        #expect(Int(first.header.size) == 32 + payload.count)
        #expect(first.consumed == message.count)
        let protobufs = try #require(DataStreamCodec.decodePayload(first.payload))
        #expect(protobufs == [protobuf])

        buffer.removeFirst(first.consumed)
        let second = try #require(DataStreamCodec.decodeMessage(buffer))
        #expect(second.header.isSync == false)
        #expect(second.header.messageType.starts(with: Data("rply".utf8)))
        #expect(second.payload.isEmpty)
        #expect(second.consumed == 32)
    }

    @Test func splitProtobufsHandlesPrefixedAndBare() {
        let a = Data([0x08, 0x01])
        let b = Data([0x08, 0x02, 0x12, 0x01, 0x78])
        var joined = Varint.encode(UInt64(a.count)) + a
        joined.append(Varint.encode(UInt64(b.count)))
        joined.append(b)
        #expect(DataStreamCodec.splitProtobufs(joined) == [a, b])
        // A bare message with no prefix starts with the type tag 0x08.
        #expect(DataStreamCodec.splitProtobufs(b) == [b])
        // A short buffer stops cleanly.
        #expect(DataStreamCodec.splitProtobufs(Data([0x05, 0x08])) == [])
    }

    @Test func partialDataStreamMessageWaits() {
        let payload = DataStreamCodec.encodePayload(protobufs: [Data([0x08, 0x01])])
        let header = DataStreamHeader(size: 0, messageType: Data("sync".utf8), command: Data("comm".utf8), sequence: 1)
        let message = DataStreamCodec.encodeMessage(header: header, payload: payload)
        #expect(DataStreamCodec.decodeMessage(message.prefix(31)) == nil)
        #expect(DataStreamCodec.decodeMessage(message.prefix(message.count - 1)) == nil)
        #expect(DataStreamCodec.decodeMessage(message) != nil)
    }
}
