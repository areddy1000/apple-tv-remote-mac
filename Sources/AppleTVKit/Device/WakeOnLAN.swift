import Foundation
import Network

/// Wakes a sleeping Apple TV with a magic packet.
public enum WakeOnLAN {
    public enum WakeError: Error {
        case badMACAddress
    }

    private static let broadcastAddress = "255.255.255.255"
    private static let ports: [UInt16] = [9, 7]

    /// Sends the magic packet two times to the broadcast address on ports 9 and 7.
    public static func send(mac: String) async throws {
        let packet = try magicPacket(mac: mac)
        for _ in 0..<2 {
            for port in ports {
                try await send(packet, to: broadcastAddress, port: port)
            }
        }
    }

    /// Builds the packet: six 0xFF bytes, then the MAC address sixteen times.
    static func magicPacket(mac: String) throws -> Data {
        let parts = mac.split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6 else { throw WakeError.badMACAddress }
        var address: [UInt8] = []
        for part in parts {
            guard let byte = UInt8(part, radix: 16) else { throw WakeError.badMACAddress }
            address.append(byte)
        }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: address) }
        return packet
    }

    private static func send(_ packet: Data, to host: String, port: UInt16) async throws {
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: port))
        let connection = NWConnection(to: endpoint, using: parameters)
        let queue = DispatchQueue(label: "atv.wol")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: packet, completion: .contentProcessed { error in
                        connection.cancel()
                        once.resume(error.map { .failure($0) } ?? .success(()))
                    })
                case .failed(let error):
                    connection.cancel()
                    once.resume(.failure(error))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }
}
