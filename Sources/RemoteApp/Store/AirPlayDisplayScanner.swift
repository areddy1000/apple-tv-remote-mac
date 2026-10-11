import AppKit
import AppleTVKit

/// Finds the display this Mac sends over AirPlay.
enum AirPlayDisplayScanner {
    /// The AirPlay display, or nil when the Mac sends to none.
    ///
    /// Only a display counts here. Sending one video to the television leaves the desktop
    /// alone, and the Apple TV reports that as now-playing instead.
    @MainActor
    static func current() -> AirPlayDisplay? {
        for screen in NSScreen.screens {
            guard let id = screen.displayID, isAirPlay(screen: screen, id: id) else { continue }
            return AirPlayDisplay(
                name: AirPlayDisplay.receiverName(from: screen.localizedName),
                isMirroring: CGDisplayIsInMirrorSet(id) != 0
            )
        }
        return nil
    }

    /// The vendor code is the sure mark. The name carries the mark in every language.
    static func isAirPlay(screen: NSScreen, id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == AirPlayDisplay.vendorCode
            || screen.localizedName.hasSuffix(AirPlayDisplay.nameSuffix)
    }
}

extension NSScreen {
    /// The Core Graphics identifier for this screen.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
