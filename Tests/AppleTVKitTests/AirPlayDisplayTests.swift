import Foundation
import Testing
@testable import AppleTVKit

@Suite("AirPlayDisplayTests")
struct AirPlayDisplayTests {
    @Test func saysWhichWayTheScreenGoes() {
        let extending = AirPlayDisplay(name: "Living Room", isMirroring: false)
        #expect(extending.label == "Extending to Living Room")
        let mirroring = AirPlayDisplay(name: "Living Room", isMirroring: true)
        #expect(mirroring.label == "Mirroring to Living Room")
    }

    /// macOS names the screen after the receiver and adds its own mark.
    @Test func takesTheSuffixOffTheScreenName() {
        #expect(AirPlayDisplay.receiverName(from: "Living Room (AirPlay)") == "Living Room")
    }

    @Test func leavesAScreenNameWithNoSuffix() {
        #expect(AirPlayDisplay.receiverName(from: "Built-in Retina Display") == "Built-in Retina Display")
        #expect(AirPlayDisplay.receiverName(from: "") == "")
    }

    /// A television the user named "Den (AirPlay)" keeps its name. macOS calls that screen
    /// "Den (AirPlay) (AirPlay)", so only the last mark comes off.
    @Test func takesOffOnlyTheLastSuffix() {
        #expect(AirPlayDisplay.receiverName(from: "Den (AirPlay) (AirPlay)") == "Den (AirPlay)")
    }

    /// The four bytes of the vendor code read "airp". A wrong constant would match nothing.
    @Test func theVendorCodeSpellsAirp() {
        let bytes = withUnsafeBytes(of: AirPlayDisplay.vendorCode.bigEndian) { Array($0) }
        #expect(String(decoding: bytes, as: UTF8.self) == "airp")
    }
}
