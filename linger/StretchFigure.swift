import SwiftUI

// Head, neck and shoulders in the same stroke as the countdown ring. Front view for tilts and
// shoulder moves, side view for chin tucks and nods, which only read in profile.
struct StretchFigure: View {
    enum Side { case front, side }

    static let size: CGFloat = 160

    let move: StretchMove
    let startedAt: Date
    // Once the move has been shown, the figure holds still so there is nothing left to watch.
    let animating: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let (from, to) = move.poses
        TimelineView(.periodic(from: startedAt, by: move.period / 2)) { context in
            let halves = Int(context.date.timeIntervalSince(startedAt) / (move.period / 2))
            let toward = animating && halves % 2 == 1
            ZStack {
                if reduceMotion {
                    // No motion: the two ends of the move dissolve into each other.
                    FigureShape(side: move.view, pose: from).opacity(toward ? 0 : 1)
                    FigureShape(side: move.view, pose: to).opacity(toward ? 1 : 0)
                } else {
                    FigureShape(side: move.view, pose: toward ? to : from)
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.6) : Motion.gentle(move.period / 2), value: toward)
        }
        .frame(width: Self.size, height: Self.size)
        .accessibilityHidden(true)
    }
}

private struct FigureShape: View {
    let side: StretchFigure.Side
    let pose: StretchPose

    var body: some View {
        FigurePath(side: side, pose: pose)
            .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
    }
}

// Drawn in a 120-point box centred on the base of the neck; every pose value animates.
private struct FigurePath: Shape {
    let side: StretchFigure.Side
    var pose: StretchPose

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>>> {
        get {
            AnimatablePair(
                AnimatablePair(pose.headDX, pose.headDY),
                AnimatablePair(AnimatablePair(pose.headTilt, pose.headTurn), AnimatablePair(pose.shoulderLift, pose.shoulderInset))
            )
        }
        set {
            pose.headDX = newValue.first.first
            pose.headDY = newValue.first.second
            pose.headTilt = newValue.second.first.first
            pose.headTurn = newValue.second.first.second
            pose.shoulderLift = newValue.second.second.first
            pose.shoulderInset = newValue.second.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 120
        let origin = CGPoint(x: rect.midX, y: rect.midY + 8 * scale)
        func p(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }

        var path = Path()
        let lift = pose.shoulderLift

        // Shoulders. In profile, only the near shoulder and a hint of the back.
        switch side {
        case .front:
            // Blades drawn together pull the shoulders in and arch them a little.
            let inset = pose.shoulderInset * 14
            path.move(to: p(-42 + inset, 20 - lift + pose.shoulderInset * 2))
            path.addQuadCurve(to: p(42 - inset, 20 - lift + pose.shoulderInset * 2), control: p(0, 12 - lift * 0.4 - pose.shoulderInset * 4))
        case .side:
            path.move(to: p(-16, 21 - lift))
            path.addQuadCurve(to: p(18, 20 - lift), control: p(2, 12 - lift * 0.4))
        }

        // Head, as a circle and a nose tick, rotated about the base of the neck.
        let headCentre = CGPoint(x: pose.headDX, y: -14 + pose.headDY)
        let radius = 16.0
        let turnScale = 1 - 0.18 * abs(pose.headTurn)
        var head = Path()
        head.addEllipse(in: CGRect(x: headCentre.x - radius * turnScale, y: headCentre.y - radius, width: radius * 2 * turnScale, height: radius * 2))
        switch side {
        case .front:
            if abs(pose.headTurn) > 0.05 {
                let nx = headCentre.x + pose.headTurn * 12
                head.move(to: CGPoint(x: nx, y: headCentre.y - 2))
                head.addLine(to: CGPoint(x: nx + pose.headTurn * 5, y: headCentre.y + 3))
            }
        case .side:
            head.move(to: CGPoint(x: headCentre.x + radius - 2, y: headCentre.y - 3))
            head.addLine(to: CGPoint(x: headCentre.x + radius + 5, y: headCentre.y + 3))
        }
        // Neck: from the shoulders up to the chin.
        head.move(to: CGPoint(x: 0, y: 12 - lift * 0.4))
        head.addLine(to: CGPoint(x: headCentre.x * 0.9, y: headCentre.y + radius - 1))

        let tilt = CGAffineTransform(translationX: 0, y: 12 - lift * 0.4)
            .rotated(by: pose.headTilt * .pi / 180)
            .translatedBy(x: 0, y: -(12 - lift * 0.4))
        let place = CGAffineTransform(translationX: origin.x, y: origin.y).scaledBy(x: scale, y: scale)
        path.addPath(head.applying(tilt.concatenating(place)))
        return path
    }
}
