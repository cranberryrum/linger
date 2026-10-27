import SwiftUI

// A bust drawn in the ring's stroke: face, neck, shoulders and the top of the arms. Front view
// for tilts and shoulder moves, profile for chin tucks and nods, which only read from the side.
// Under the moving figure sits a faint copy at rest, and a thin arrow says which way to go, the
// way an exercise card does.
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
                StretchStill(side: move.view, pose: .neutral, arrow: nil)
                    .opacity(0.22)
                if reduceMotion {
                    // No motion: the two ends of the move dissolve into each other.
                    StretchStill(side: move.view, pose: from, arrow: move).opacity(toward ? 0 : 1)
                    StretchStill(side: move.view, pose: to, arrow: move).opacity(toward ? 1 : 0)
                } else {
                    StretchStill(side: move.view, pose: toward ? to : from, arrow: move)
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.6) : Motion.gentle(move.period / 2), value: toward)
        }
        .frame(width: Self.size, height: Self.size)
        .accessibilityHidden(true)
    }
}

// One pose, with its arrow if asked for. Also what Settings and the design sheet draw.
struct StretchStill: View {
    let side: StretchFigure.Side
    let pose: StretchPose
    let arrow: StretchMove?

    var body: some View {
        ZStack {
            FigurePath(side: side, pose: pose)
                .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
            FigurePath(side: side, pose: pose, part: .eyes)
                .fill(.white.opacity(0.9))
            if let arrow {
                ArrowPath(move: arrow)
                    .stroke(.white.opacity(0.55), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

// MARK: - Figure

// Drawn in a 120-unit box with the origin at the base of the neck; every pose value animates.
private struct FigurePath: Shape {
    enum Part { case lines, eyes }

    let side: StretchFigure.Side
    var pose: StretchPose
    var part: Part = .lines

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
        let place = Self.placement(in: rect)
        let lift = pose.shoulderLift
        let neckBase = CGPoint(x: 0, y: 14 - lift * 0.5)

        var body = Path()
        var eyes = Path()

        switch side {
        case .front:
            // Trapezius slope out to the shoulders, then the upper arms. Blades drawn together
            // pull the shoulders in and arch them a little.
            let inset = pose.shoulderInset * 10
            let sy = 24 - lift + pose.shoulderInset * 2
            for sx in [-1.0, 1.0] {
                body.move(to: CGPoint(x: 42 * sx - inset * sx, y: 56))
                body.addLine(to: CGPoint(x: 40 * sx - inset * sx, y: sy + 4))
                body.addQuadCurve(
                    to: CGPoint(x: 8 * sx, y: neckBase.y + 2),
                    control: CGPoint(x: 26 * sx - inset * sx, y: sy - 4 - pose.shoulderInset * 3)
                )
            }
        case .side:
            // Back, the near shoulder and a flat chest, seen from the right.
            body.move(to: CGPoint(x: -18, y: 56))
            body.addQuadCurve(to: CGPoint(x: -8, y: neckBase.y + 2), control: CGPoint(x: -14, y: 30 - lift))
            body.move(to: CGPoint(x: 6, y: neckBase.y + 4))
            body.addQuadCurve(to: CGPoint(x: 22, y: 28 - lift), control: CGPoint(x: 18, y: 18 - lift))
            body.addQuadCurve(to: CGPoint(x: 16, y: 56), control: CGPoint(x: 23, y: 42 - lift * 0.5))
        }

        // Head and neck in neck-base coordinates, then rotated about the base of the neck.
        var head = Path()
        let centre = CGPoint(x: pose.headDX, y: -32 + pose.headDY)
        switch side {
        case .front:
            let turn = pose.headTurn
            let w = 15.0 * (1 - 0.16 * abs(turn))
            head.addEllipse(in: CGRect(x: centre.x - w, y: centre.y - 17, width: w * 2, height: 34))
            // Neck, two lines from the jaw to the shoulders.
            head.move(to: CGPoint(x: centre.x - 6, y: centre.y + 15))
            head.addLine(to: CGPoint(x: -7, y: 2))
            head.move(to: CGPoint(x: centre.x + 6, y: centre.y + 15))
            head.addLine(to: CGPoint(x: 7, y: 2))
            // Eyes slide toward the turn; a nose tick appears on that side.
            let ey = centre.y - 3
            eyes.addEllipse(in: CGRect(x: centre.x - 6 + turn * 7 - 1.6, y: ey - 1.6, width: 3.2, height: 3.2))
            eyes.addEllipse(in: CGRect(x: centre.x + 6 + turn * 7 - 1.6, y: ey - 1.6, width: 3.2, height: 3.2))
            if abs(turn) > 0.3 {
                let nx = centre.x + turn * (w + 1)
                head.move(to: CGPoint(x: nx, y: ey + 2))
                head.addLine(to: CGPoint(x: nx + turn * 4, y: ey + 6))
            }
        case .side:
            // Profile facing right: skull, forehead, nose, lips, chin, back to the neck.
            let c = centre
            head.move(to: CGPoint(x: c.x - 4, y: c.y + 16))
            head.addCurve(to: CGPoint(x: c.x, y: c.y - 17), control1: CGPoint(x: c.x - 22, y: c.y + 10), control2: CGPoint(x: c.x - 20, y: c.y - 17))
            head.addCurve(to: CGPoint(x: c.x + 14, y: c.y - 5), control1: CGPoint(x: c.x + 10, y: c.y - 17), control2: CGPoint(x: c.x + 14, y: c.y - 12))
            head.addLine(to: CGPoint(x: c.x + 19, y: c.y + 2))
            head.addLine(to: CGPoint(x: c.x + 14, y: c.y + 4))
            head.addQuadCurve(to: CGPoint(x: c.x + 12, y: c.y + 12), control: CGPoint(x: c.x + 16, y: c.y + 9))
            head.addQuadCurve(to: CGPoint(x: c.x - 4, y: c.y + 16), control: CGPoint(x: c.x + 6, y: c.y + 17))
            // Neck: the throat and the nape.
            head.move(to: CGPoint(x: c.x + 6, y: c.y + 15))
            head.addLine(to: CGPoint(x: 6, y: 4))
            head.move(to: CGPoint(x: c.x - 4, y: c.y + 16))
            head.addLine(to: CGPoint(x: -8, y: 2))
            eyes.addEllipse(in: CGRect(x: c.x + 7 - 1.6, y: c.y - 4 - 1.6, width: 3.2, height: 3.2))
        }

        // The head turns about the top of the neck, not the shoulders, so a nod stays on its neck.
        let pivot = CGPoint(x: 0, y: -8)
        let tilt = CGAffineTransform(translationX: pivot.x, y: pivot.y)
            .rotated(by: pose.headTilt * .pi / 180)
            .translatedBy(x: -pivot.x, y: -pivot.y)
        let toFigure = CGAffineTransform(translationX: neckBase.x, y: neckBase.y)
        let headTransform = tilt.concatenating(toFigure).concatenating(place)

        switch part {
        case .lines:
            var path = body.applying(place)
            path.addPath(head.applying(headTransform))
            return path
        case .eyes:
            return eyes.applying(headTransform)
        }
    }

    // Figure units to the view: the drawing runs from about -62 (arrow over the head) to 56 (arms).
    static func placement(in rect: CGRect) -> CGAffineTransform {
        let scale = min(rect.width, rect.height) / 120
        return CGAffineTransform(translationX: rect.midX, y: rect.midY + 3 * scale).scaledBy(x: scale, y: scale)
    }
}

// MARK: - Arrows

// Thin direction cues in figure units, around the part that moves.
private struct ArrowPath: Shape {
    let move: StretchMove

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch move {
        case .chinTuck:
            // Straight back, above the head.
            path.move(to: CGPoint(x: 10, y: -46))
            path.addLine(to: CGPoint(x: -12, y: -46))
            head(&path, at: CGPoint(x: -12, y: -46), angle: .pi)
        case .nod:
            // Down and in, in front of the face.
            path.move(to: CGPoint(x: 30, y: -30))
            path.addQuadCurve(to: CGPoint(x: 28, y: 2), control: CGPoint(x: 38, y: -14))
            head(&path, at: CGPoint(x: 28, y: 2), angle: .pi / 2 + 0.3)
        case .sideTilt:
            // A rainbow over the head, pointing down at both ends.
            path.move(to: CGPoint(x: -26, y: -40))
            path.addQuadCurve(to: CGPoint(x: 26, y: -40), control: CGPoint(x: 0, y: -62))
            head(&path, at: CGPoint(x: -26, y: -40), angle: .pi / 2 + 0.6)
            head(&path, at: CGPoint(x: 26, y: -40), angle: .pi / 2 - 0.6)
        case .lookOver:
            // Out to either side at eye level.
            path.move(to: CGPoint(x: -24, y: -8))
            path.addLine(to: CGPoint(x: -36, y: -8))
            head(&path, at: CGPoint(x: -36, y: -8), angle: .pi)
            path.move(to: CGPoint(x: 24, y: -8))
            path.addLine(to: CGPoint(x: 36, y: -8))
            head(&path, at: CGPoint(x: 36, y: -8), angle: 0)
        case .shoulderRolls:
            // A circle above each shoulder, running up and back.
            for sx in [-1.0, 1.0] {
                let c = CGPoint(x: 44 * sx, y: 2)
                let start = Angle.degrees(sx > 0 ? 150 : 30)
                let end = Angle.degrees(sx > 0 ? -120 : 300)
                path.move(to: CGPoint(x: c.x + 9 * cos(start.radians), y: c.y + 9 * sin(start.radians)))
                path.addArc(center: c, radius: 9, startAngle: start, endAngle: end, clockwise: sx > 0)
                let tip = CGPoint(x: c.x + 9 * cos(end.radians), y: c.y + 9 * sin(end.radians))
                head(&path, at: tip, angle: end.radians + (sx > 0 ? -.pi / 2 : .pi / 2))
            }
        case .bladeSqueeze:
            // In toward the spine, at shoulder height.
            path.move(to: CGPoint(x: -56, y: 30))
            path.addLine(to: CGPoint(x: -44, y: 30))
            head(&path, at: CGPoint(x: -44, y: 30), angle: 0)
            path.move(to: CGPoint(x: 56, y: 30))
            path.addLine(to: CGPoint(x: 44, y: 30))
            head(&path, at: CGPoint(x: 44, y: 30), angle: .pi)
        }
        return path.applying(FigurePath.placement(in: rect))
    }

    // An open arrowhead whose point is at `tip`, pointing along `angle`.
    private func head(_ path: inout Path, at tip: CGPoint, angle: Double) {
        let length = 5.0
        for spread in [0.75, -0.75] {
            let a = angle + .pi + spread
            path.move(to: tip)
            path.addLine(to: CGPoint(x: tip.x + length * cos(a), y: tip.y + length * sin(a)))
        }
    }
}
