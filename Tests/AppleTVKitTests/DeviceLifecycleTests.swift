import Foundation
import Testing
@testable import AppleTVKit

/// The app lets go of a device and comes back to it. The device must still work then,
/// and a device the app drops must leave memory.
@Suite("DeviceLifecycleTests")
struct DeviceLifecycleTests {
    /// A device with no Companion service. A connect fails at once and opens no socket.
    private func makeDevice() -> AppleTVDevice {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atv-lifecycle-\(UUID().uuidString)")
        return AppleTVDevice(
            device: DiscoveredDevice(id: "test", name: "Test"),
            identity: CompanionIdentity(clientID: "client", name: "Mac", model: "Mac", deviceID: "020000000001"),
            store: CredentialStore(directory: directory),
            pinProvider: { _ in nil }
        )
    }

    /// Reads connection states until a failure arrives, or the stream ends.
    private static func statesUntilFailure(_ events: AsyncStream<DeviceEvent>) async -> [ConnectionState] {
        var states: [ConnectionState] = []
        for await event in events {
            guard case .connection(let state) = event else { continue }
            states.append(state)
            if case .failed = state { break }
        }
        return states
    }

    /// The store cancels its reader when it detaches. The next attach must still get events.
    @Test func aNewSubscriberGetsEventsAfterTheLastOneStops() async {
        let device = makeDevice()

        let first = device.subscribe()
        let reader = Task { await Self.statesUntilFailure(first) }
        await device.connect()
        let firstStates = await reader.value
        #expect(firstStates.first == .connecting)
        // The store cancels its reader on detach. This ends that one stream.
        let stopped = Task { for await _ in device.subscribe() {} }
        stopped.cancel()
        await stopped.value

        let second = device.subscribe()
        let secondReader = Task { await Self.statesUntilFailure(second) }
        await device.connect()
        let secondStates = await secondReader.value
        #expect(secondStates.first == .connecting)
        #expect(secondStates.contains { if case .failed = $0 { true } else { false } })
        await device.shutdown()
    }

    /// The coordinator drops a device after a disconnect. Nothing may keep it alive.
    @Test func aDeviceThatShutsDownLeavesMemory() async throws {
        weak var weakDevice: AppleTVDevice?
        do {
            let device = makeDevice()
            weakDevice = device
            let events = device.subscribe()
            await device.connect()
            _ = await Self.statesUntilFailure(events)
            await device.disconnect()
            await device.shutdown()
        }
        // The loops end on their own tasks. Give them a moment.
        for _ in 0..<50 where weakDevice != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(weakDevice == nil)
    }

    /// After a shutdown the stream ends, so a reader does not wait for ever.
    /// A reader that waits fails the test at the time limit.
    @Test(.timeLimit(.minutes(1))) func aShutdownEndsTheEventStream() async {
        let device = makeDevice()
        let events = device.subscribe()
        await device.shutdown()
        for await _ in events {}
    }
}

@Suite("EventHubTests")
struct EventHubTests {
    @Test func aNewSubscriberEndsTheOldStream() async {
        let hub = EventHub<Int>()
        let old = hub.subscribe()
        let new = hub.subscribe()
        hub.yield(1)
        hub.finish()
        var oldValues: [Int] = []
        for await value in old { oldValues.append(value) }
        var newValues: [Int] = []
        for await value in new { newValues.append(value) }
        #expect(oldValues.isEmpty)
        #expect(newValues == [1])
    }

    @Test func aSubscriberAfterFinishGetsAnEndedStream() async {
        let hub = EventHub<Int>()
        hub.finish()
        let stream = hub.subscribe()
        hub.yield(1)
        var values: [Int] = []
        for await value in stream { values.append(value) }
        #expect(values.isEmpty)
    }
}
