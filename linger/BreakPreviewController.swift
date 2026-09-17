import AppKit

// A real break overlay for a fixed duration, without touching BreakScheduler.
final class BreakPreviewController {
    private let presenter = OverlayPresenter()
    private var finishTask: Task<Void, Never>?
    private var completion: (() -> Void)?

    func present(duration: TimeInterval, completion: @escaping () -> Void) {
        guard !presenter.isPresenting else { return }
        self.completion = completion

        let startedAt = Date()
        let message = BreakMessages.current.first ?? "Look far away"
        let presentation = BreakPresentation(
            message: message,
            subline: BreakMessages.subline(for: message),
            startedAt: startedAt,
            endsAt: startedAt.addingTimeInterval(duration),
            skipDifficulty: SkipDifficulty.current
        )

        presenter.present(presentation) { [weak self] in
            guard presentation.canSkip else { return }
            self?.finish(skipped: true)
        }
        Sounds.play(.breakStart)
        finishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.finish(skipped: false)
        }
    }

    // The preview plays the real sounds too, so the palette is heard once during onboarding.
    private func finish(skipped: Bool) {
        finishTask?.cancel()
        finishTask = nil
        presenter.dismiss()
        Sounds.play(skipped ? .skip : .breakEnd)
        completion?()
        completion = nil
    }
}
