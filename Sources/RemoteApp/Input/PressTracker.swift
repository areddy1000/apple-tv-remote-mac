import AppKit
import SwiftUI

/// A transparent AppKit overlay that reports press and hover with no delay.
/// SwiftUI buttons fire on mouse up. A remote must fire on mouse down.
struct PressTracker: NSViewRepresentable {
    var onHover: (Bool) -> Void
    var onPress: (Bool) -> Void

    func makeNSView(context: Context) -> PressTrackerView {
        let view = PressTrackerView()
        view.onHover = onHover
        view.onPress = onPress
        return view
    }

    func updateNSView(_ view: PressTrackerView, context: Context) {
        view.onHover = onHover
        view.onPress = onPress
    }
}

final class PressTrackerView: NSView {
    var onHover: ((Bool) -> Void)?
    var onPress: ((Bool) -> Void)?

    /// Pointer travel allowed outside the bounds before the press cancels.
    private let slop: CGFloat = 12
    private var isDown = false
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard !isDown else { return }
        isDown = true
        onPress?(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDown else { return }
        let point = convert(event.locationInWindow, from: nil)
        let inside = bounds.insetBy(dx: -slop, dy: -slop).contains(point)
        if !inside {
            isDown = false
            onPress?(false)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isDown else { return }
        isDown = false
        onPress?(false)
    }
}
