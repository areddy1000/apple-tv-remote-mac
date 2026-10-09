import Foundation

/// Everything the app remembers about one paired Apple TV.
public struct StoredDevice: Codable, Sendable, Equatable {
    public var name: String
    public var companion: HAPCredentials?
    public var airplay: HAPCredentials?
    public var macAddress: String?
    public var lastHost: String?

    public init(name: String, companion: HAPCredentials? = nil, airplay: HAPCredentials? = nil, macAddress: String? = nil, lastHost: String? = nil) {
        self.name = name
        self.companion = companion
        self.airplay = airplay
        self.macAddress = macAddress
        self.lastHost = lastHost
    }
}

/// Persists credentials as JSON in Application Support with mode 0600.
/// A file store avoids Keychain prompts that an ad-hoc signed build triggers on each rebuild.
public actor CredentialStore {
    public static let directoryName = "AppleTVRemote"

    private let fileURL: URL
    private var devices: [String: StoredDevice] = [:]
    private var loaded = false

    public init(directory: URL? = nil) {
        let base = directory ?? Self.defaultDirectory()
        fileURL = base.appendingPathComponent("credentials.json")
    }

    /// Reads the file. A missing file gives an empty store.
    public func load() throws {
        loaded = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            devices = [:]
            return
        }
        let data = try Data(contentsOf: fileURL)
        devices = try JSONDecoder().decode([String: StoredDevice].self, from: data)
    }

    public func device(for identifier: String) throws -> StoredDevice? {
        try loadIfNeeded()
        return devices[identifier]
    }

    public func save(_ device: StoredDevice, for identifier: String) throws {
        try loadIfNeeded()
        devices[identifier] = device
        try persist()
    }

    public func remove(for identifier: String) throws {
        try loadIfNeeded()
        devices[identifier] = nil
        try persist()
    }

    public func all() throws -> [String: StoredDevice] {
        try loadIfNeeded()
        return devices
    }

    private func loadIfNeeded() throws {
        if !loaded { try load() }
    }

    private func persist() throws {
        try Self.ensureDirectory(fileURL.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(devices)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    // MARK: - Shared helpers

    /// The default directory in Application Support.
    public static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Creates the directory with mode 0700 when it is absent.
    static func ensureDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    /// Returns a stable pairing identifier for this Mac.
    /// The first call makes a random UUID and stores it in `client-id.txt`.
    /// Each `role` gets its own UUID. The TV keeps one pairing per UUID, so the
    /// Companion pairing and the AirPlay pairing must not share one.
    public static func clientID(role: String = "", directory: URL? = nil) -> String {
        let base = directory ?? defaultDirectory()
        let file = role.isEmpty ? "client-id.txt" : "client-id-\(role).txt"
        let url = base.appendingPathComponent(file)
        if let data = try? Data(contentsOf: url) {
            let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        let value = UUID().uuidString
        try? ensureDirectory(base)
        try? Data(value.utf8).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return value
    }
}
