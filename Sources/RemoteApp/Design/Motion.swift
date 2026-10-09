import SwiftUI

/// The motion language. Springs are critically damped by default.
/// Bounce appears only after a gesture with momentum.
enum Motion {
    /// Button press down. Starts on mouse down.
    static let press = Animation.spring(response: 0.15, dampingFraction: 1.0)
    /// Button release. A small settle.
    static let release = Animation.spring(response: 0.25, dampingFraction: 0.75)
    /// Hover highlight. Background only.
    static let hover = Animation.easeOut(duration: 0.12)
    /// The glow on the touch surface follows the pointer.
    static let surface = Animation.spring(response: 0.2, dampingFraction: 1.0)
    /// A swipe hands its velocity to this spring.
    static let swipe = Animation.spring(response: 0.3, dampingFraction: 0.8)
    /// A panel or palette opens.
    static let panelOpen = Animation.spring(response: 0.3, dampingFraction: 0.85)
    /// A panel or palette closes. Exit is faster than enter.
    static let panelClose = Animation.spring(response: 0.2, dampingFraction: 1.0)
    /// Rows in the app palette.
    static let rows = Animation.spring(response: 0.25, dampingFraction: 0.9)
    /// Artwork crossfade.
    static let crossfade = Animation.easeOut(duration: 0.25)
    /// Content changes when the device switches.
    static let deviceSwitch = Animation.spring(response: 0.25, dampingFraction: 1.0)
    /// Reduced motion: a short crossfade with no movement.
    static let reduced = Animation.easeOut(duration: 0.15)

    /// Picks the animation for the current accessibility setting.
    static func pick(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? reduced : animation
    }

    /// Scale while a button is pressed.
    static let pressScale: CGFloat = 0.96
    /// Stagger between palette rows.
    static let stagger: Double = 0.03
    /// Rubber-band constant for the touch surface edges.
    static let rubberBand: CGFloat = 0.55
}

/// Apple's momentum projection. Returns the distance a flick travels.
func projectMomentum(velocity: CGFloat, decelerationRate: CGFloat = 0.998) -> CGFloat {
    (velocity / 1000) * decelerationRate / (1 - decelerationRate)
}

/// Progressive resistance past a boundary.
func rubberBand(overshoot: CGFloat, dimension: CGFloat, constant: CGFloat = Motion.rubberBand) -> CGFloat {
    (overshoot * dimension * constant) / (dimension + constant * abs(overshoot))
}
