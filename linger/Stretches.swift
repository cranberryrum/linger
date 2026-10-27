import Foundation

// Gentle neck and shoulder moves guided during a long break. Each is shown once by the line
// figure, then the screen lets go and a tone marks the switch to the next, so the moves are done
// looking anywhere but here. Nothing forceful, nothing pulled with the hands, no neck circles.
enum StretchMove: String, CaseIterable, Codable, Identifiable {
    case chinTuck, nod, sideTilt, lookOver, shoulderRolls, bladeSqueeze

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chinTuck: "Chin tucks"
        case .nod: "Slow nods"
        case .sideTilt: "Ear to shoulder"
        case .lookOver: "Look over each shoulder"
        case .shoulderRolls: "Shoulder rolls"
        case .bladeSqueeze: "Squeeze your shoulder blades"
        }
    }

    var cue: String {
        switch self {
        case .chinTuck: "Slide your chin straight back, then let it go"
        case .nod: "Chin toward your chest, slowly back up"
        case .sideTilt: "Left, then right. Let the weight of your head do it"
        case .lookOver: "Turn as far as is comfortable, left then right"
        case .shoulderRolls: "Lift, roll back, let them drop"
        case .bladeSqueeze: "Draw them together, hold, release"
        }
    }

    // Seconds for one there-and-back of the figure, and of the move itself.
    var period: TimeInterval {
        switch self {
        case .chinTuck, .bladeSqueeze: 4
        case .nod, .sideTilt, .lookOver: 6
        case .shoulderRolls: 3
        }
    }

    var view: StretchFigure.Side {
        switch self {
        case .chinTuck, .nod: .side
        default: .front
        }
    }

    var poses: (StretchPose, StretchPose) {
        switch self {
        case .chinTuck: (.neutral, StretchPose(headDX: -9))
        case .nod: (.neutral, StretchPose(headTilt: 22))
        case .sideTilt: (StretchPose(headTilt: -22), StretchPose(headTilt: 22))
        case .lookOver: (StretchPose(headTurn: -1), StretchPose(headTurn: 1))
        case .shoulderRolls: (.neutral, StretchPose(shoulderLift: 8))
        case .bladeSqueeze: (.neutral, StretchPose(shoulderLift: -2, shoulderInset: 1))
        }
    }
}

struct StretchPose: Equatable {
    var headDX: Double = 0
    var headDY: Double = 0
    // Degrees about the base of the neck; positive leans toward the nose in side view, right in front view.
    var headTilt: Double = 0
    // -1…1, front view only.
    var headTurn: Double = 0
    var shoulderLift: Double = 0
    // 0…1, how far the shoulders draw in toward the spine.
    var shoulderInset: Double = 0

    static let neutral = StretchPose()
}

// One timed part of a long break: a move, or the plain message at either end.
struct StretchStep: Identifiable, Equatable {
    enum Content: Equatable {
        case message(title: String, subline: String)
        case move(StretchMove)
    }

    let id: Int
    let content: Content
    let start: TimeInterval
    let duration: TimeInterval

    var title: String {
        switch content {
        case .message(let title, _): title
        case .move(let move): move.title
        }
    }

    var subline: String {
        switch content {
        case .message(_, let subline): subline
        case .move(let move): move.cue
        }
    }

    var move: StretchMove? {
        if case .move(let move) = content { return move }
        return nil
    }
}

enum Stretches {
    static let closingTitle = "Look far away"
    static let closingSubline = "Let your eyes rest on the farthest thing you can see"

    static var isOn: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.stretchesOn)
    }

    // Moves switched off, stored as one comma-separated string so Settings can watch it with @AppStorage.
    static var enabledMoves: [StretchMove] {
        enabledMoves(off: UserDefaults.standard.string(forKey: DefaultsKey.stretchesOff) ?? "")
    }

    static func enabledMoves(off: String) -> [StretchMove] {
        let off = Set(off.split(separator: ",").map(String.init))
        return StretchMove.allCases.filter { !off.contains($0.rawValue) }
    }

    static func setEnabled(_ enabled: Bool, _ move: StretchMove) {
        var off = Set((UserDefaults.standard.string(forKey: DefaultsKey.stretchesOff) ?? "").split(separator: ",").map(String.init))
        if enabled { off.remove(move.rawValue) } else { off.insert(move.rawValue) }
        UserDefaults.standard.set(off.sorted().joined(separator: ","), forKey: DefaultsKey.stretchesOff)
    }

    // Lays a long break out: the break's own message to get up, a few moves, then eyes far away.
    // Which moves come up rotates between breaks so the same three don't repeat every hour.
    static func plan(duration: TimeInterval, opening: (title: String, subline: String), moves: [StretchMove] = enabledMoves, rotation: Int = 0) -> [StretchStep] {
        let intro = min(12, max(3, duration * 0.07))
        let outro = min(45, max(5, duration * 0.22))
        let middle = duration - intro - outro
        let minMove: TimeInterval = min(20, max(8, duration * 0.1))
        let count = min(moves.count, 6, Int(middle / minMove))

        var steps = [StretchStep(id: 0, content: .message(title: opening.title, subline: opening.subline), start: 0, duration: intro)]
        if count > 0 {
            let each = middle / Double(count)
            for i in 0..<count {
                let move = moves[(rotation + i) % moves.count]
                steps.append(StretchStep(id: i + 1, content: .move(move), start: intro + each * Double(i), duration: each))
            }
        }
        let closingStart = steps.last.map { $0.start + $0.duration } ?? 0
        steps.append(StretchStep(id: steps.count, content: .message(title: closingTitle, subline: closingSubline), start: closingStart, duration: duration - closingStart))
        return steps
    }

    static func step(at elapsed: TimeInterval, in steps: [StretchStep]) -> StretchStep? {
        steps.last { $0.start <= elapsed } ?? steps.first
    }

    // Advances the rotation after a planned break, so the next one starts on fresh moves.
    static func consumeRotation(count: Int) -> Int {
        let current = UserDefaults.standard.integer(forKey: DefaultsKey.stretchRotation)
        let total = max(1, enabledMoves.count)
        UserDefaults.standard.set((current + count) % total, forKey: DefaultsKey.stretchRotation)
        return current
    }
}
