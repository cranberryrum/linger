import AppKit

final class BreakOverlayController {
    private let scheduler: BreakScheduler
    private let presenter = OverlayPresenter()
    private var presentation: BreakPresentation?
    private var messageIndex = 0
    private var longMessageIndex = 0
    private var watchdog: Task<Void, Never>?

    // However the scheduler got there, a break never outlives its end by more than this.
    private static let watchdogGrace: TimeInterval = 5

    init(scheduler: BreakScheduler) {
        self.scheduler = scheduler
        observe()
    }

    private func observe() {
        withObservationTracking {
            handle(state: scheduler.state)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
    }

    private func handle(state: BreakScheduler.State) {
        switch state {
        case .onBreak(let endsAt):
            if presentation == nil { show(endsAt: endsAt) }
        default:
            if presentation != nil { hide() }
        }
    }

    private func show(endsAt: Date) {
        let isLong = scheduler.currentBreakIsLong
        let kind: BreakKind = isLong ? .long : .short
        let messages = BreakMessages.current(kind)
        let message: String
        if isLong {
            message = messages[longMessageIndex % messages.count]
            longMessageIndex += 1
        } else {
            message = messages[messageIndex % messages.count]
            messageIndex += 1
        }

        let subline = BreakMessages.subline(for: message, kind: kind)
        let presentation = BreakPresentation(
            message: message,
            subline: subline,
            startedAt: endsAt.addingTimeInterval(-scheduler.currentBreakDuration),
            endsAt: endsAt,
            skipDifficulty: SkipDifficulty.current,
            workInterval: scheduler.workInterval,
            isLong: isLong,
            steps: isLong ? Self.stretchSteps(duration: scheduler.currentBreakDuration, opening: (message, subline)) : []
        )
        self.presentation = presentation
        presenter.present(
            presentation,
            onSkip: { [weak self] in self?.skipIfAllowed() },
            onEmergencyExit: { [weak self] in self?.endBreak() }
        )
        Sounds.play(.breakStart)

        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(endsAt.timeIntervalSinceNow + Self.watchdogGrace))
            guard !Task.isCancelled, let self, self.presentation?.endsAt == endsAt else { return }
            self.scheduler.skipBreak()
            // If the scheduler had already moved on without telling us, lift the blur regardless.
            if self.presentation != nil { self.hide() }
        }
    }

    private static func stretchSteps(duration: TimeInterval, opening: (title: String, subline: String)) -> [StretchStep] {
        let moves = Stretches.enabledMoves
        guard Stretches.isOn, !moves.isEmpty else { return [] }
        let planned = Stretches.plan(duration: duration, opening: opening, moves: moves)
        let rotation = Stretches.consumeRotation(count: planned.filter { $0.move != nil }.count)
        return Stretches.plan(duration: duration, opening: opening, moves: moves, rotation: rotation)
    }

    private func hide() {
        watchdog?.cancel()
        watchdog = nil
        presentation = nil
        presenter.dismiss()
    }

    private func endBreak() {
        Sounds.play(.skip)
        scheduler.skipBreak()
    }

    private func skipIfAllowed() {
        guard let presentation, presentation.canSkip else { return }
        Sounds.play(.skip)
        scheduler.skipBreak()
    }
}
