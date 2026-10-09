import Foundation

/// Message types in `ProtocolMessage.type`.
public enum MRPMessageType: Int, Sendable {
    case sendCommand = 1
    case sendCommandResult = 2
    case setState = 4
    case deviceInfo = 15
    case clientUpdatesConfig = 16
    case getKeyboardSession = 24
    case playbackQueueRequest = 32
    case setConnectionState = 38
    case genericMessage = 42
    case setNowPlayingClient = 46
    case setNowPlayingPlayer = 47
    case removeClient = 53
    case removePlayer = 54
    case updateClient = 55
    case updateContentItem = 56
    case updateContentItemArtwork = 57
    case setDefaultSupportedCommands = 72
}

/// Extension field numbers on `ProtocolMessage` for the inner messages.
enum MRPExtension {
    static let sendCommand = 6
    static let setState = 9
    static let deviceInfo = 20
    static let clientUpdatesConfig = 21
    static let playbackQueueRequest = 37
    static let setConnectionState = 42
    static let genericMessage = 46
    static let setNowPlayingClient = 50
    static let setNowPlayingPlayer = 51
    static let removeClient = 57
    static let removePlayer = 58
    static let updateClient = 59
    static let updateContentItem = 60
    static let updateContentItemArtwork = 61
    static let setDefaultSupportedCommands = 75
}

/// Commands for SEND_COMMAND.
public enum MRPCommand: Int, Sendable {
    case play = 1
    case pause = 2
    case togglePlayPause = 3
    case stop = 4
    case nextTrack = 5
    case previousTrack = 6
    case skipForward = 18
    case skipBackward = 19
}

/// Playback state in SET_STATE.
public enum MRPPlaybackState: Int, Sendable {
    case unknown = 0
    case playing = 1
    case paused = 2
    case stopped = 3
    case interrupted = 4
    case seeking = 5
}

/// Fields of ProtocolMessage: type 1, identifier 2, errorCode 4, uniqueIdentifier 85.
public struct MRPMessage: Sendable {
    public var type: Int
    public var identifier: String?
    public var errorCode: Int?
    public var uniqueIdentifier: String?
    /// The whole message, for the inner extension fields.
    public let reader: ProtobufReader?

    public init(type: Int, identifier: String? = nil, errorCode: Int? = nil, uniqueIdentifier: String? = nil, reader: ProtobufReader? = nil) {
        self.type = type
        self.identifier = identifier
        self.errorCode = errorCode
        self.uniqueIdentifier = uniqueIdentifier
        self.reader = reader
    }

    public var messageType: MRPMessageType? { MRPMessageType(rawValue: type) }

    public static func decode(_ data: Data) throws -> MRPMessage {
        let reader = try ProtobufReader(data)
        return MRPMessage(
            type: Int(reader.uint64(1) ?? 0),
            identifier: reader.string(2),
            errorCode: reader.uint64(4).map(Int.init),
            uniqueIdentifier: reader.string(85),
            reader: reader
        )
    }

    /// The inner message for an extension field.
    public func inner(_ field: Int) -> ProtobufReader? {
        reader?.message(field)
    }
}

/// Builds outgoing messages. The type field comes first, as the device expects.
public enum MRPMessageBuilder {
    /// The common envelope: type, identifier, errorCode 0, uniqueIdentifier.
    static func envelope(_ type: MRPMessageType, identifier: String?) -> ProtobufWriter {
        var writer = ProtobufWriter()
        writer.varint(field: 1, value: UInt64(type.rawValue))
        if let identifier { writer.string(field: 2, value: identifier) }
        writer.varint(field: 4, value: 0)
        return writer
    }

    static func finish(_ writer: inout ProtobufWriter) -> Data {
        writer.string(field: 85, value: UUID().uuidString)
        return writer.data
    }

    public static func deviceInfo(identifier: String, name: String, uniqueIdentifier: String, osBuild: String = "18G82") -> Data {
        var info = ProtobufWriter()
        info.string(field: 1, value: uniqueIdentifier)
        info.string(field: 2, value: name)
        info.string(field: 3, value: "iPhone")
        info.string(field: 4, value: osBuild)
        info.string(field: 5, value: "com.apple.TVRemote")
        info.string(field: 6, value: "344.28")
        info.int32(field: 7, value: 1)
        info.uint32(field: 8, value: 108)
        info.bool(field: 9, value: true)
        info.bool(field: 10, value: true)
        info.string(field: 12, value: "com.apple.TVMusic")
        info.bool(field: 13, value: true)
        info.bool(field: 14, value: true)
        info.bool(field: 15, value: true)
        info.uint32(field: 17, value: 2)
        info.varint(field: 21, value: 1) // DeviceClass iPhone
        info.uint32(field: 22, value: 1)
        var writer = envelope(.deviceInfo, identifier: identifier)
        writer.message(field: MRPExtension.deviceInfo, writer: info)
        return finish(&writer)
    }

    public static func setConnectionState() -> Data {
        var inner = ProtobufWriter()
        inner.varint(field: 1, value: 2) // Connected
        var writer = envelope(.setConnectionState, identifier: nil)
        writer.message(field: MRPExtension.setConnectionState, writer: inner)
        return finish(&writer)
    }

    public static func clientUpdatesConfig(identifier: String, artwork: Bool = true, nowPlaying: Bool = true, volume: Bool = true, keyboard: Bool = true, outputDevice: Bool = true) -> Data {
        var inner = ProtobufWriter()
        inner.bool(field: 1, value: artwork)
        inner.bool(field: 2, value: nowPlaying)
        inner.bool(field: 3, value: volume)
        inner.bool(field: 4, value: keyboard)
        inner.bool(field: 5, value: outputDevice)
        var writer = envelope(.clientUpdatesConfig, identifier: identifier)
        writer.message(field: MRPExtension.clientUpdatesConfig, writer: inner)
        return finish(&writer)
    }

    public static func getKeyboardSession(identifier: String) -> Data {
        var writer = envelope(.getKeyboardSession, identifier: identifier)
        return finish(&writer)
    }

    public static func genericMessage(identifier: String) -> Data {
        var writer = envelope(.genericMessage, identifier: identifier)
        return finish(&writer)
    }

    public static func playbackQueueRequest(identifier: String, location: Int32 = 0, artworkWidth: Double = -1, artworkHeight: Double = 400) -> Data {
        var inner = ProtobufWriter()
        inner.int32(field: 1, value: location)
        inner.int32(field: 2, value: 1)
        inner.bool(field: 3, value: true)
        inner.double(field: 4, value: artworkWidth)
        inner.double(field: 5, value: artworkHeight)
        inner.bool(field: 13, value: true)
        var writer = envelope(.playbackQueueRequest, identifier: identifier)
        writer.message(field: MRPExtension.playbackQueueRequest, writer: inner)
        return finish(&writer)
    }

    /// - Parameter skipInterval: Seconds for `skipForward` and `skipBackward`. CommandOptions field 5.
    public static func sendCommand(identifier: String, command: MRPCommand, skipInterval: Float? = nil) -> Data {
        var inner = ProtobufWriter()
        inner.varint(field: 1, value: UInt64(command.rawValue))
        if let skipInterval {
            var options = ProtobufWriter()
            options.float(field: 5, value: skipInterval)
            inner.message(field: 2, writer: options)
        }
        var writer = envelope(.sendCommand, identifier: identifier)
        writer.message(field: MRPExtension.sendCommand, writer: inner)
        return finish(&writer)
    }
}

// MARK: Decoded now-playing structures

/// Metadata of one content item. Field numbers from ContentItemMetadata.proto.
public struct MRPContentMetadata: Sendable, Equatable {
    public var title: String?
    public var albumName: String?
    public var trackArtistName: String?
    public var seriesName: String?
    public var duration: Double?
    public var elapsedTime: Double?
    public var elapsedTimeTimestamp: Double?
    public var playbackRate: Float?
    public var artworkAvailable: Bool?
    public var artworkIdentifier: String?
    public var mediaType: Int?

    public init() {}

    public static func decode(_ reader: ProtobufReader) -> MRPContentMetadata {
        var m = MRPContentMetadata()
        m.title = reader.string(1)
        m.albumName = reader.string(6)
        m.trackArtistName = reader.string(7)
        m.seriesName = reader.string(63)
        m.duration = reader.double(14)
        m.elapsedTime = reader.double(35)
        m.elapsedTimeTimestamp = reader.double(74)
        m.playbackRate = reader.float(39)
        m.artworkAvailable = reader.bool(19)
        m.artworkIdentifier = reader.string(80)
        m.mediaType = reader.uint64(64).map(Int.init)
        return m
    }

    /// Fills missing fields from another metadata value. Present fields win.
    public mutating func merge(_ other: MRPContentMetadata) {
        if other.title != nil { title = other.title }
        if other.albumName != nil { albumName = other.albumName }
        if other.trackArtistName != nil { trackArtistName = other.trackArtistName }
        if other.seriesName != nil { seriesName = other.seriesName }
        if other.duration != nil { duration = other.duration }
        if other.elapsedTime != nil { elapsedTime = other.elapsedTime }
        if other.elapsedTimeTimestamp != nil { elapsedTimeTimestamp = other.elapsedTimeTimestamp }
        if other.playbackRate != nil { playbackRate = other.playbackRate }
        if other.artworkAvailable != nil { artworkAvailable = other.artworkAvailable }
        if other.artworkIdentifier != nil { artworkIdentifier = other.artworkIdentifier }
        if other.mediaType != nil { mediaType = other.mediaType }
    }

    /// Converts the Core Foundation absolute time stamp to a Date.
    public var elapsedDate: Date? {
        elapsedTimeTimestamp.map { Date(timeIntervalSinceReferenceDate: $0) }
    }
}

/// One item in the playback queue. Fields from ContentItem.proto.
public struct MRPContentItem: Sendable, Equatable {
    public var identifier: String?
    public var metadata: MRPContentMetadata?
    public var artworkData: Data?

    public init(identifier: String? = nil, metadata: MRPContentMetadata? = nil, artworkData: Data? = nil) {
        self.identifier = identifier
        self.metadata = metadata
        self.artworkData = artworkData
    }

    public static func decode(_ reader: ProtobufReader) -> MRPContentItem {
        MRPContentItem(
            identifier: reader.string(1),
            metadata: reader.message(2).map(MRPContentMetadata.decode),
            artworkData: reader.bytes(3)
        )
    }
}

/// Identifies the app and the player a state belongs to. Fields from PlayerPath.proto.
public struct MRPPlayerPath: Sendable, Equatable {
    public var bundleIdentifier: String?
    public var clientDisplayName: String?
    public var playerIdentifier: String?
    public var playerDisplayName: String?

    public static let defaultPlayer = "MediaRemote-DefaultPlayer"

    public init(bundleIdentifier: String? = nil, clientDisplayName: String? = nil, playerIdentifier: String? = nil, playerDisplayName: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.clientDisplayName = clientDisplayName
        self.playerIdentifier = playerIdentifier
        self.playerDisplayName = playerDisplayName
    }

    public static func decode(_ reader: ProtobufReader?) -> MRPPlayerPath {
        guard let reader else { return MRPPlayerPath() }
        let client = reader.message(2)
        let player = reader.message(3)
        return MRPPlayerPath(
            bundleIdentifier: client?.string(2),
            clientDisplayName: client?.string(7),
            playerIdentifier: player?.string(1),
            playerDisplayName: player?.string(2)
        )
    }

    public static func decodeClient(_ reader: ProtobufReader?) -> MRPPlayerPath {
        MRPPlayerPath(bundleIdentifier: reader?.string(2), clientDisplayName: reader?.string(7))
    }
}

/// A decoded SET_STATE message.
public struct MRPSetState: Sendable, Equatable {
    public var playerPath: MRPPlayerPath
    public var displayName: String?
    public var playbackState: MRPPlaybackState?
    public var location: Int?
    public var items: [MRPContentItem]?
    public var supportedCommands: [Int: Bool]?

    public static func decode(_ message: MRPMessage) -> MRPSetState? {
        guard let inner = message.inner(MRPExtension.setState) else { return nil }
        var state = MRPSetState(playerPath: MRPPlayerPath.decode(inner.message(9)))
        state.displayName = inner.string(5)
        state.playbackState = inner.uint64(6).flatMap { MRPPlaybackState(rawValue: Int($0)) }
        if let queue = inner.message(3) {
            state.location = queue.int32(1).map(Int.init) ?? 0
            state.items = queue.messages(2).map(MRPContentItem.decode)
        }
        if let supported = inner.message(2) {
            var commands: [Int: Bool] = [:]
            for info in supported.messages(1) {
                if let command = info.uint64(1) {
                    commands[Int(command)] = info.bool(2) ?? true
                }
            }
            state.supportedCommands = commands
        }
        return state
    }
}

/// A decoded UPDATE_CONTENT_ITEM message.
public struct MRPContentItemUpdate: Sendable, Equatable {
    public var playerPath: MRPPlayerPath
    public var items: [MRPContentItem]

    public static func decode(_ message: MRPMessage, field: Int) -> MRPContentItemUpdate? {
        guard let inner = message.inner(field) else { return nil }
        return MRPContentItemUpdate(
            playerPath: MRPPlayerPath.decode(inner.message(2)),
            items: inner.messages(1).map(MRPContentItem.decode)
        )
    }
}
