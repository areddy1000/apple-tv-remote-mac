import Foundation
import Network

/// Finds Apple TVs with Bonjour.
/// It browses `_companion-link._tcp` and `_airplay._tcp` and merges the results.
public actor DeviceBrowser {
    public static let companionType = "_companion-link._tcp"
    public static let airplayType = "_airplay._tcp"

    /// Emits the merged and sorted device list on every change.
    public nonisolated let devices: AsyncStream<[DiscoveredDevice]>
    private let continuation: AsyncStream<[DiscoveredDevice]>.Continuation

    private var companionBrowser: NWBrowser?
    private var airplayBrowser: NWBrowser?
    private var companion: [String: ServiceRecord] = [:]
    private var airplay: [String: ServiceRecord] = [:]
    private var isRunning = false
    private let queue = DispatchQueue(label: "atv.discovery")

    /// Delay before a failed browser restarts.
    private static let restartDelay: Duration = .seconds(2)

    public init() {
        (devices, continuation) = AsyncStream.makeStream(of: [DiscoveredDevice].self, bufferingPolicy: .bufferingNewest(1))
    }

    /// Starts both browsers. A second call does nothing.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        companionBrowser = makeBrowser(type: Self.companionType)
        airplayBrowser = makeBrowser(type: Self.airplayType)
        companionBrowser?.start(queue: queue)
        airplayBrowser?.start(queue: queue)
        ATVLog.discovery.info("browser started")
    }

    /// Stops both browsers and clears the results.
    public func stop() {
        isRunning = false
        companionBrowser?.cancel()
        airplayBrowser?.cancel()
        companionBrowser = nil
        airplayBrowser = nil
        companion = [:]
        airplay = [:]
        ATVLog.discovery.info("browser stopped")
    }

    /// The current merged list.
    public var current: [DiscoveredDevice] {
        DeviceMerger.merge(companion: companion, airplay: airplay)
    }

    private func makeBrowser(type: String) -> NWBrowser {
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: type, domain: nil)
        let browser = NWBrowser(for: descriptor, using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.handle(state: state, type: type) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let records = results.compactMap(Self.record(from:))
            Task { await self.update(type: type, records: records) }
        }
        return browser
    }

    private func handle(state: NWBrowser.State, type: String) {
        switch state {
        case .ready:
            ATVLog.discovery.debug("\(type, privacy: .public) ready")
        case .failed(let error):
            ATVLog.discovery.error("\(type, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            restart(type: type)
        case .waiting(let error):
            ATVLog.discovery.notice("\(type, privacy: .public) waiting: \(error.localizedDescription, privacy: .public)")
        default:
            break
        }
    }

    /// Replaces the failed browser after a short delay.
    private func restart(type: String) {
        guard isRunning else { return }
        Task {
            try? await Task.sleep(for: Self.restartDelay)
            replaceBrowser(type: type)
        }
    }

    private func replaceBrowser(type: String) {
        guard isRunning else { return }
        let browser = makeBrowser(type: type)
        if type == Self.companionType {
            companionBrowser?.cancel()
            companionBrowser = browser
        } else {
            airplayBrowser?.cancel()
            airplayBrowser = browser
        }
        browser.start(queue: queue)
    }

    private func update(type: String, records: [ServiceRecord]) {
        var table: [String: ServiceRecord] = [:]
        for record in records { table[record.name] = record }
        if type == Self.companionType {
            companion = table
        } else {
            airplay = table
        }
        let merged = current
        ATVLog.discovery.debug("\(type, privacy: .public): \(records.count) results, \(merged.count) Apple TVs")
        continuation.yield(merged)
    }

    private static func record(from result: NWBrowser.Result) -> ServiceRecord? {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        var txt: [String: String] = [:]
        if case .bonjour(let record) = result.metadata {
            txt = record.dictionary
        }
        return ServiceRecord(name: name, txt: txt, endpoint: result.endpoint)
    }

    /// Resolves a Bonjour service endpoint to a host and a port.
    /// It opens a TCP connection, reads the remote endpoint, and closes it.
    /// IPv4 only: a link-local IPv6 address needs an interface scope that other
    /// connections cannot get back from the text form.
    public static func resolve(_ endpoint: NWEndpoint) async throws -> (host: String, port: UInt16) {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        let queue = DispatchQueue(label: "atv.discovery.resolve")
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint else {
                        once.resume(.failure(ResolveError.noRemoteEndpoint))
                        connection.cancel()
                        return
                    }
                    // Resume first. A cancel can report the cancelled state before this handler returns.
                    once.resume(.success((Self.hostText(host), port.rawValue)))
                    connection.cancel()
                case .failed(let error):
                    connection.cancel()
                    once.resume(.failure(error))
                case .cancelled:
                    once.resume(.failure(ResolveError.cancelled))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    /// Returns the address or name as text.
    static func hostText(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address): return "\(address)"
        case .name(let name, _): return name
        @unknown default: return "\(host)"
        }
    }

    public enum ResolveError: Error {
        case noRemoteEndpoint
        case cancelled
    }
}
