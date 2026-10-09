import AppKit
import AppleTVKit
import SwiftUI

/// Feedback the touch surface view shows.
struct SurfaceFeedback: Equatable {
    var pointer: CGPoint?
    var pressed: Bool
    var edge: RemoteButton?
    var swipeOffset: CGSize
}

/// A transparent AppKit view over the touch surface.
/// It turns trackpad scrolls into touch events and clicks into Select or an edge button.
struct TrackpadBridge: NSViewRepresentable {
    var onTouch: (TouchEvent) -> Void
    var onButton: (RemoteButton, Bool) -> Void
    var onFeedback: (SurfaceFeedback) -> Void

    func makeNSView(context: Context) -> TrackpadBridgeView {
        let view = TrackpadBridgeView()
        view.onTouch = onTouch
        view.onButton = onButton
        view.onFeedback = onFeedback
        return view
    }

    func updateNSView(_ view: TrackpadBridgeView, context: Context) {
        view.onTouch = onTouch
        view.onButton = onButton
        view.onFeedback = onFeedback
    }
}

final class TrackpadBridgeView: NSView {
    var onTouch: ((TouchEvent) -> Void)?
    var onButton: ((RemoteButton, Bool) -> Void)?
    var onFeedback: ((SurfaceFeedback) -> Void)?

    /// Points of trackpad travel per surface unit. 1000 units is the whole surface.
    private let gain: CGFloat = 5.5
    /// Minimum time between hold samples. The Siri Remote sends one each 20 ms.
    private let sampleInterval: TimeInterval = 0.018
    /// Share of each edge that acts as a direction button on click.
    private let edgeShare: CGFloat = 0.2

    private var trackingArea: NSTrackingArea?
    private var feedback = SurfaceFeedback(pointer: nil, pressed: false, edge: nil, swipeOffset: .zero)
    private var activeButton: RemoteButton?
    private var swiping = false
    private var swipePoint = CGPoint(x: 500, y: 500)
    private var lastSample: TimeInterval = 0
    private var pendingSample: TouchEvent?
    private var flushTimer: Timer?

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    private func publish() {
        onFeedback?(feedback)
    }

    // MARK: Pointer

    override func mouseMoved(with event: NSEvent) {
        feedback.pointer = flipped(event)
        publish()
    }

    override func mouseEntered(with event: NSEvent) {
        feedback.pointer = flipped(event)
        publish()
    }

    override func mouseExited(with event: NSEvent) {
        feedback.pointer = nil
        publish()
    }

    /// Converts the event location to a top-left origin point in this view.
    private func flipped(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: bounds.height - p.y)
    }

    // MARK: Click

    override func mouseDown(with event: NSEvent) {
        let point = flipped(event)
        let button = edgeButton(at: point) ?? .select
        activeButton = button
        feedback.pressed = true
        feedback.edge = button == .select ? nil : button
        feedback.pointer = point
        publish()
        onButton?(button, true)
    }

    override func mouseDragged(with event: NSEvent) {
        feedback.pointer = flipped(event)
        publish()
    }

    override func mouseUp(with event: NSEvent) {
        guard let button = activeButton else { return }
        activeButton = nil
        feedback.pressed = false
        feedback.edge = nil
        publish()
        onButton?(button, false)
    }

    /// Returns the direction button when the click lands near an edge.
    private func edgeButton(at point: CGPoint) -> RemoteButton? {
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return nil }
        let nx = point.x / w
        let ny = point.y / h
        let dx = nx - 0.5
        let dy = ny - 0.5
        let limit = 0.5 - edgeShare
        if abs(dx) <= limit, abs(dy) <= limit { return nil }
        if abs(dx) > abs(dy) {
            return dx < 0 ? .left : .right
        }
        return dy < 0 ? .up : .down
    }

    // MARK: Scroll to swipe

    override func scrollWheel(with event: NSEvent) {
        if !event.hasPreciseScrollingDeltas {
            discreteSwipe(event)
            return
        }
        let direction: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        let dx = event.scrollingDeltaX * direction
        let dy = event.scrollingDeltaY * direction

        switch event.phase {
        case .began:
            beginSwipe()
            moveSwipe(dx: dx, dy: dy)
        case .changed:
            if !swiping { beginSwipe() }
            moveSwipe(dx: dx, dy: dy)
        case .ended, .cancelled:
            moveSwipe(dx: dx, dy: dy)
            endSwipe()
        default:
            // Momentum phases carry no finger. tvOS projects its own momentum.
            if event.momentumPhase == .began, swiping { endSwipe() }
        }
    }

    private func beginSwipe() {
        swiping = true
        swipePoint = CGPoint(x: 500, y: 500)
        feedback.swipeOffset = .zero
        feedback.pressed = true
        publish()
        lastSample = 0
        send(TouchEvent(x: 500, y: 500, phase: .press), force: true)
    }

    private func moveSwipe(dx: CGFloat, dy: CGFloat) {
        guard swiping else { return }
        swipePoint.x += dx * gain
        swipePoint.y += dy * gain
        feedback.swipeOffset = CGSize(
            width: rubberBand(overshoot: (swipePoint.x - 500) / 1000, dimension: bounds.width),
            height: rubberBand(overshoot: (swipePoint.y - 500) / 1000, dimension: bounds.height)
        )
        publish()
        send(TouchEvent(x: swipePoint.x, y: swipePoint.y, phase: .hold), force: false)
    }

    private func endSwipe() {
        guard swiping else { return }
        swiping = false
        flushTimer?.invalidate()
        flushTimer = nil
        pendingSample = nil
        send(TouchEvent(x: swipePoint.x, y: swipePoint.y, phase: .release), force: true)
        feedback.pressed = false
        feedback.swipeOffset = .zero
        publish()
    }

    /// Rate-limits hold samples. The last sample always goes out.
    private func send(_ event: TouchEvent, force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if force || now - lastSample >= sampleInterval {
            lastSample = now
            pendingSample = nil
            flushTimer?.invalidate()
            flushTimer = nil
            onTouch?(event)
            return
        }
        pendingSample = event
        if flushTimer == nil {
            flushTimer = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let pending = self.pendingSample else { return }
                    self.flushTimer = nil
                    self.lastSample = ProcessInfo.processInfo.systemUptime
                    self.pendingSample = nil
                    self.onTouch?(pending)
                }
            }
        }
    }

    /// A mouse wheel has no phases. One notch becomes one short swipe.
    private func discreteSwipe(_ event: NSEvent) {
        let dy = event.scrollingDeltaY
        let dx = event.scrollingDeltaX
        guard dx != 0 || dy != 0 else { return }
        let vertical = abs(dy) >= abs(dx)
        let sign: CGFloat = (vertical ? dy : dx) > 0 ? -1 : 1
        let travel: CGFloat = 220 * sign
        let start = CGPoint(x: 500, y: 500)
        onTouch?(TouchEvent(x: start.x, y: start.y, phase: .press))
        for step in 1...4 {
            let t = CGFloat(step) / 4
            onTouch?(TouchEvent(
                x: start.x + (vertical ? 0 : travel * t),
                y: start.y + (vertical ? travel * t : 0),
                phase: .hold
            ))
        }
        onTouch?(TouchEvent(
            x: start.x + (vertical ? 0 : travel),
            y: start.y + (vertical ? travel : 0),
            phase: .release
        ))
    }
}
