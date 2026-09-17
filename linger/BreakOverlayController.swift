import AppKit

final class BreakOverlayController {
    private let scheduler: BreakScheduler
    private let presenter = OverlayPresenter()
    private var presentation: BreakPresentation?
    private var messageIndex = 0

    init(scheduler: BreakScheduler) {
        self.scheduler = scheduler
        observe()
    }

    private func observe() {
        withObservationTracking {
            handle(state: scheduler.state)
        } onChange: {
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
            skipDifficulty: SkipDifficulty.current
        )
        self.presentation = presentation
        presenter.present(presentation) { [weak self] in self?.skipIfAllowed() }
        Sounds.play(.breakStart)
    }

    private func hide() {
        presentation = nil
        presenter.dismiss()
    }

    private func skipIfAllowed() {
        guard let presentation, presentation.canSkip else { return }
        Sounds.play(.skip)
        scheduler.skipBreak()
    }
}
