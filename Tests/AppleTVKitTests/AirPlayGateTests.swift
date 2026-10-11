import Foundation
import Network
import Testing
@testable import AppleTVKit

/// The AirPlay tunnel posts every 2 s. It must close while the Apple TV sleeps, and a
/// failure must not turn into a retry loop in the background.
@Suite("AirPlayGateTests")
struct AirPlayGateTests {
    @Test func aSleepingAppleTVClosesTheTunnel() {
        var gate = AirPlayGate()
        #expect(gate.observe(.awake) == .none)
        #expect(gate.observe(.asleep) == .close)
        #expect(!gate.mayOpen)
    }

    @Test func aWakeOpensTheTunnelAgain() {
        var gate = AirPlayGate()
        _ = gate.observe(.asleep)
        #expect(gate.observe(.awake) == .open)
        #expect(gate.mayOpen)
    }

    @Test func theScreensaverCountsAsAwake() {
        var gate = AirPlayGate()
        _ = gate.observe(.asleep)
        #expect(gate.observe(.screensaver) == .open)
    }

    /// The store asks for the power state on a timer. The same answer must do nothing.
    @Test func aRepeatedStateDoesNothing() {
        var gate = AirPlayGate()
        #expect(gate.observe(.awake) == .none)
        #expect(gate.observe(.awake) == .none)
        _ = gate.observe(.asleep)
        #expect(gate.observe(.asleep) == .none)
    }

    /// An unknown answer says nothing about the TV. The last known state stays.
    @Test func anUnknownStateKeepsTheLastState() {
        var gate = AirPlayGate()
        _ = gate.observe(.asleep)
        #expect(gate.observe(.unknown) == .none)
        #expect(gate.power == .asleep)
        #expect(gate.observe(.awake) == .open)
    }

    @Test func aFailureBlocksTheTunnelUntilTheNextConnect() {
        var gate = AirPlayGate()
        _ = gate.observe(.awake)
        gate.markFailed()
        #expect(!gate.mayOpen)
        #expect(gate.observe(.awake) == .none)
        gate.reset()
        #expect(gate.mayOpen)
    }

    /// A wake is rare and comes from the user, so it may try one more time.
    @Test func aWakeAfterAFailureTriesOnce() {
        var gate = AirPlayGate()
        gate.markFailed()
        _ = gate.observe(.asleep)
        #expect(gate.observe(.awake) == .open)
        #expect(gate.mayOpen)
    }

    @Test func onlyANewEndpointCountsAsAChange() {
        let first = NWEndpoint.service(name: "Living Room", type: "_airplay._tcp", domain: "local.", interface: nil)
        let second = NWEndpoint.service(name: "Den", type: "_airplay._tcp", domain: "local.", interface: nil)
        #expect(AirPlayGate.endpointChanged(from: nil, to: first))
        #expect(!AirPlayGate.endpointChanged(from: first, to: first))
        #expect(AirPlayGate.endpointChanged(from: first, to: second))
        #expect(!AirPlayGate.endpointChanged(from: first, to: nil))
    }
}
