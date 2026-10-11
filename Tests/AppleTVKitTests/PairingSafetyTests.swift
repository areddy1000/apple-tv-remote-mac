import Foundation
import Testing
@testable import AppleTVKit

/// The app must never throw away a pairing because the network had a bad moment.
///
/// A pairing costs the user a trip to the television, and asking for a new one turns the
/// television on. Only the Apple TV itself may decide that a key is dead.
@Suite("PairingSafetyTests")
struct PairingSafetyTests {
    /// The error the app saw when the Mac woke and the socket was already gone.
    /// This one deleted a good pairing before the fix.
    @Test func aClosedSocketIsNotARejection() {
        #expect(!AppleTVDevice.isRejection(CompanionConnectionError.closed))
    }

    @Test func noTransportFailureIsARejection() {
        let transport: [any Error] = [
            CompanionConnectionError.closed,
            CompanionConnectionError.cancelled,
            CompanionConnectionError.failed("the network went away"),
            CompanionError.timeout,
            CompanionError.notConnected,
            CompanionError.badPayload,
            CancellationError(),
            URLError(.notConnectedToInternet),
        ]
        for error in transport {
            #expect(!AppleTVDevice.isRejection(error), "\(error) must not cost the user the pairing")
        }
    }

    /// The handshake ran and the Apple TV turned the key down. Only these count.
    @Test func theAppleTVTurningTheKeyDownIsARejection() {
        let refusals: [any Error] = [
            HAPError.accessoryError(2),
            HAPError.proofMismatch,
            HAPError.signatureInvalid,
            HAPError.identifierMismatch,
            HAPError.decryptFailed,
        ]
        for error in refusals {
            #expect(AppleTVDevice.isRejection(error), "\(error) means the key is dead")
        }
    }

    /// A short frame can break the handshake without the Apple TV saying anything.
    /// The app keeps the key, because the next attempt may still work.
    @Test func aBrokenHandshakeKeepsTheKey() {
        #expect(!AppleTVDevice.isRejection(HAPError.stateMismatch(expected: 2, got: 0)))
        #expect(!AppleTVDevice.isRejection(HAPError.missingField(.publicKey)))
    }
}

@Suite("ConnectionStateTests")
struct ConnectionStateTests {
    @Test func needsPairingIsNotBusyAndNotConnected() {
        #expect(!ConnectionState.needsPairing.isBusy)
        #expect(!ConnectionState.needsPairing.isConnected)
        #expect(ConnectionState.needsPairing.label == "Needs Pairing")
    }

    @Test func theBusyStatesAreTheOnesTheAppIsWorkingOn() {
        #expect(ConnectionState.connecting.isBusy)
        #expect(ConnectionState.reconnecting.isBusy)
        #expect(ConnectionState.pairing.isBusy)
        #expect(ConnectionState.awaitingPIN.isBusy)
        #expect(!ConnectionState.idle.isBusy)
        #expect(!ConnectionState.connected.isBusy)
        #expect(!ConnectionState.failed("x").isBusy)
    }
}
