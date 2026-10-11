import Foundation
import Testing
@testable import AppleTVKit

/// A lost link comes back with a growing wait, and never wakes a sleeping TV.
@Suite("ReconnectPolicyTests")
struct ReconnectPolicyTests {
    @Test func theWaitDoublesAfterEachDrop() {
        #expect(AppleTVDevice.reconnectDelay(forDrop: 1) == .seconds(1))
        #expect(AppleTVDevice.reconnectDelay(forDrop: 2) == .seconds(2))
        #expect(AppleTVDevice.reconnectDelay(forDrop: 3) == .seconds(4))
        #expect(AppleTVDevice.reconnectDelay(forDrop: 4) == .seconds(8))
    }

    @Test func theAppStopsAfterTooManyDrops() {
        #expect(AppleTVDevice.reconnectDelay(forDrop: 5) == nil)
        #expect(AppleTVDevice.reconnectDelay(forDrop: 0) == nil)
    }

    /// A connect to a sleeping Apple TV can wake it through the Bonjour Sleep Proxy.
    @Test func aSleepingAppleTVIsNotReconnected() {
        #expect(!AppleTVDevice.mayReconnect(afterDropWith: .asleep))
        #expect(AppleTVDevice.mayReconnect(afterDropWith: .awake))
        #expect(AppleTVDevice.mayReconnect(afterDropWith: .screensaver))
        #expect(AppleTVDevice.mayReconnect(afterDropWith: .unknown))
    }
}
