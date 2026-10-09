import Foundation
import Testing
@testable import AppleTVKit

@Suite("MRPTests")
struct MRPTests {
    @Test func deviceInfoRoundTrip() throws {
        let data = MRPMessageBuilder.deviceInfo(identifier: "ID-1", name: "Mac", uniqueIdentifier: "CLIENT")
        #expect(data.first == 0x08)
        let message = try MRPMessage.decode(data)
        #expect(message.messageType == .deviceInfo)
        #expect(message.identifier == "ID-1")
        #expect(message.errorCode == 0)
        #expect(message.uniqueIdentifier?.count == 36)
        let info = try #require(message.inner(MRPExtension.deviceInfo))
        #expect(info.string(1) == "CLIENT")
        #expect(info.string(2) == "Mac")
        #expect(info.string(3) == "iPhone")
        #expect(info.string(5) == "com.apple.TVRemote")
        #expect(info.uint32(8) == 108)
        #expect(info.bool(9) == true)
        #expect(info.uint64(21) == 1)
        #expect(info.uint32(22) == 1)
    }

    @Test func sendCommandCarriesSkipInterval() throws {
        let data = MRPMessageBuilder.sendCommand(identifier: "X", command: .skipForward, skipInterval: 10)
        let message = try MRPMessage.decode(data)
        #expect(message.messageType == .sendCommand)
        let inner = try #require(message.inner(MRPExtension.sendCommand))
        #expect(inner.uint64(1) == 18)
        #expect(inner.message(2)?.float(5) == 10)
    }

    /// Builds a SET_STATE message the way the device sends it.
    private func setState(
        bundle: String = "com.apple.TVWatchList",
        clientName: String? = "TV",
        player: String = MRPPlayerPath.defaultPlayer,
        playback: MRPPlaybackState = .playing,
        title: String = "Severance",
        artworkAvailable: Bool = true,
        artwork: Data? = nil,
        elapsed: Double = 120,
        timestamp: Double = 700_000_000
    ) -> Data {
        var metadata = ProtobufWriter()
        metadata.string(field: 1, value: title)
        metadata.string(field: 7, value: "Artist")
        metadata.double(field: 14, value: 3240)
        metadata.bool(field: 19, value: artworkAvailable)
        metadata.double(field: 35, value: elapsed)
        metadata.float(field: 39, value: 1)
        metadata.string(field: 63, value: "Series")
        metadata.double(field: 74, value: timestamp)

        var item = ProtobufWriter()
        item.string(field: 1, value: "item-1")
        item.message(field: 2, writer: metadata)
        if let artwork { item.bytes(field: 3, value: artwork) }

        var queue = ProtobufWriter()
        queue.int32(field: 1, value: 0)
        queue.message(field: 2, writer: item)

        var client = ProtobufWriter()
        client.string(field: 2, value: bundle)
        if let clientName { client.string(field: 7, value: clientName) }
        var playerWriter = ProtobufWriter()
        playerWriter.string(field: 1, value: player)
        var path = ProtobufWriter()
        path.message(field: 2, writer: client)
        path.message(field: 3, writer: playerWriter)

        var command = ProtobufWriter()
        command.varint(field: 1, value: 2) // Pause
        command.bool(field: 2, value: true)
        var supported = ProtobufWriter()
        supported.message(field: 1, writer: command)

        var state = ProtobufWriter()
        state.message(field: 2, writer: supported)
        state.message(field: 3, writer: queue)
        state.varint(field: 6, value: UInt64(playback.rawValue))
        state.message(field: 9, writer: path)

        var writer = ProtobufWriter()
        writer.varint(field: 1, value: UInt64(MRPMessageType.setState.rawValue))
        writer.message(field: MRPExtension.setState, writer: state)
        writer.string(field: 85, value: "U")
        return writer.data
    }

    private func setNowPlayingClient(bundle: String, name: String? = nil) -> Data {
        var client = ProtobufWriter()
        client.string(field: 2, value: bundle)
        if let name { client.string(field: 7, value: name) }
        var inner = ProtobufWriter()
        inner.message(field: 1, writer: client)
        var writer = ProtobufWriter()
        writer.varint(field: 1, value: UInt64(MRPMessageType.setNowPlayingClient.rawValue))
        writer.message(field: MRPExtension.setNowPlayingClient, writer: inner)
        return writer.data
    }

    @Test func decodesSetState() throws {
        let message = try MRPMessage.decode(setState(artwork: Data([0xFF, 0xD8])))
        let state = try #require(MRPSetState.decode(message))
        #expect(state.playerPath.bundleIdentifier == "com.apple.TVWatchList")
        #expect(state.playerPath.clientDisplayName == "TV")
        #expect(state.playerPath.playerIdentifier == MRPPlayerPath.defaultPlayer)
        #expect(state.playbackState == .playing)
        #expect(state.location == 0)
        #expect(state.supportedCommands?[2] == true)
        let item = try #require(state.items?.first)
        #expect(item.identifier == "item-1")
        #expect(item.artworkData == Data([0xFF, 0xD8]))
        let metadata = try #require(item.metadata)
        #expect(metadata.title == "Severance")
        #expect(metadata.seriesName == "Series")
        #expect(metadata.duration == 3240)
        #expect(metadata.elapsedTime == 120)
        #expect(metadata.playbackRate == 1)
        #expect(metadata.artworkAvailable == true)
    }

    @Test func elapsedTimestampConvertsFromReferenceDate() throws {
        let message = try MRPMessage.decode(setState(timestamp: 700_000_000))
        let metadata = try #require(MRPSetState.decode(message)?.items?.first?.metadata)
        let date = try #require(metadata.elapsedDate)
        #expect(date == Date(timeIntervalSinceReferenceDate: 700_000_000))
        #expect(date.timeIntervalSince1970 == 700_000_000 + 978_307_200)
    }

    @Test func stateManagerPublishesActivePlayer() throws {
        var manager = MRPPlayerStateManager()
        // State arrives before any client is active. A live playback makes that client active.
        let changed = manager.apply(try MRPMessage.decode(setState()))
        #expect(changed)
        #expect(manager.nowPlaying?.title == "Severance")

        #expect(manager.apply(try MRPMessage.decode(setNowPlayingClient(bundle: "com.apple.TVWatchList"))))
        let playing = try #require(manager.nowPlaying)
        #expect(playing.title == "Severance")
        #expect(playing.subtitle == "Series")
        #expect(playing.appName == "TV")
        #expect(playing.duration == 3240)
        #expect(playing.elapsed == 120)
        #expect(playing.rate == 1)
        #expect(playing.elapsedAt == Date(timeIntervalSinceReferenceDate: 700_000_000))
        #expect(playing.artwork == nil)
        #expect(manager.needsArtwork)
        #expect(manager.activeItemIdentifier == "item-1")
    }

    @Test func stateManagerMergesArtworkAndPause() throws {
        var manager = MRPPlayerStateManager()
        _ = manager.apply(try MRPMessage.decode(setNowPlayingClient(bundle: "com.apple.TVWatchList")))
        _ = manager.apply(try MRPMessage.decode(setState()))
        // The playback queue reply carries the artwork.
        _ = manager.apply(try MRPMessage.decode(setState(artwork: Data([1, 2, 3]))))
        #expect(manager.nowPlaying?.artwork == Data([1, 2, 3]))
        #expect(manager.needsArtwork == false)

        _ = manager.apply(try MRPMessage.decode(setState(playback: .paused, artwork: Data([1, 2, 3]))))
        #expect(manager.nowPlaying?.rate == 0)

        _ = manager.apply(try MRPMessage.decode(setState(playback: .stopped, artwork: Data([1, 2, 3]))))
        #expect(manager.nowPlaying == nil)
    }

    @Test func stateManagerIgnoresInactiveClient() throws {
        var manager = MRPPlayerStateManager()
        _ = manager.apply(try MRPMessage.decode(setNowPlayingClient(bundle: "com.apple.TVWatchList")))
        _ = manager.apply(try MRPMessage.decode(setState()))
        let other = setState(bundle: "com.netflix.Netflix", clientName: "Netflix", title: "Other")
        let changed = manager.apply(try MRPMessage.decode(other))
        #expect(changed == false)
        #expect(manager.nowPlaying?.title == "Severance")

        _ = manager.apply(try MRPMessage.decode(setNowPlayingClient(bundle: "com.netflix.Netflix")))
        #expect(manager.nowPlaying?.title == "Other")
        #expect(manager.nowPlaying?.appName == "Netflix")
    }
}
