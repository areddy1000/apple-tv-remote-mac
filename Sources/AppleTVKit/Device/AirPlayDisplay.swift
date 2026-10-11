import Foundation

/// A display this Mac sends to an Apple TV over AirPlay.
///
/// The Mac can extend its desktop onto the television or copy its screen to it. Neither
/// shows as now-playing on the Apple TV, so the app reports this itself.
public struct AirPlayDisplay: Equatable, Sendable {
    /// The receiver name, without the suffix macOS adds.
    public var name: String
    /// True when the television copies the Mac screen. False when it extends the desktop.
    public var isMirroring: Bool

    public init(name: String, isMirroring: Bool) {
        self.name = name
        self.isMirroring = isMirroring
    }

    /// The line for the menu bar, for example "Extending to Living Room".
    public var label: String {
        "\(isMirroring ? "Mirroring" : "Extending") to \(name)"
    }

    /// The vendor code macOS gives an AirPlay display. The four bytes read "airp".
    public static let vendorCode: UInt32 = 0x6169_7270
    /// macOS adds this to the receiver name, for example "Living Room (AirPlay)".
    public static let nameSuffix = " (AirPlay)"

    /// Takes the suffix off a screen name.
    ///
    /// A television named "Den (AirPlay)" keeps its name, because macOS would call that
    /// screen "Den (AirPlay) (AirPlay)". Only the last suffix comes off.
    public static func receiverName(from screenName: String) -> String {
        guard screenName.hasSuffix(nameSuffix) else { return screenName }
        return String(screenName.dropLast(nameSuffix.count))
    }
}
