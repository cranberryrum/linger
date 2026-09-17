import AppKit
import SwiftUI

enum Motion {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // Strong ease-out: instant start, long settle. For controls and panels the user is waiting on.
    static let easeOutCurve = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)

    static func easeOut(_ duration: TimeInterval) -> Animation {
        .timingCurve(0.23, 1, 0.32, 1, duration: duration)
    }

    // Gentle ease-in-out: slow start, slow settle. Only for the break, where the point is to slow down.
    static let gentleCurve = CAMediaTimingFunction(controlPoints: 0.3, 0.1, 0.25, 1)

    static func gentle(_ duration: TimeInterval) -> Animation {
        .timingCurve(0.3, 0.1, 0.25, 1, duration: duration)
    }

    static var overlayIn: TimeInterval { reduceMotion ? 0.25 : 0.9 }
    static var overlayOut: TimeInterval { reduceMotion ? 0.2 : 0.45 }
    // How long the break text stays at full strength before receding so the eyes can leave.
    static let overlaySettle: TimeInterval = 4
}

private struct Entrance: ViewModifier {
    let shown: Bool
    let delay: TimeInterval
    let soft: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : (soft ? 8 : 10))
            .blur(radius: shown || reduceMotion ? 0 : (soft ? 12 : 6))
            .scaleEffect(shown || reduceMotion || !soft ? 1 : 0.985)
            .animation(animation.delay(delay), value: shown)
    }

    private var animation: Animation {
        if reduceMotion { return Motion.easeOut(0.2) }
        return soft ? Motion.gentle(1.1) : Motion.easeOut(0.5)
    }
}

extension View {
    func entrance(_ shown: Bool, delay: TimeInterval = 0, soft: Bool = false) -> some View {
        modifier(Entrance(shown: shown, delay: delay, soft: soft))
    }
}
