import AppKit

final class BreakOverlayController {
    private let scheduler: BreakScheduler
    private let presenter = OverlayPresenter()
    private var presentation: BreakPresentation?
    private var messageIndex = 0
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
        let messages = BreakMessages.current
        let message = messages[messageIndex % messages.count]
        messageIndex += 1

        let presentation = BreakPresentation(
            message: message,
            subline: BreakMessages.subline(for: message),
            startedAt: endsAt.addingTimeInterval(-scheduler.breakDuration),
            endsAt: endsAt,
            skipDifficulty: SkipDifficulty.current,
            workInterval: scheduler.workInterval
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
