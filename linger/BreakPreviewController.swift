import AppKit

// A real break overlay for a fixed duration, without touching BreakScheduler.
final class BreakPreviewController {
    private let presenter = OverlayPresenter()
    private var finishTask: Task<Void, Never>?
    private var completion: (() -> Void)?

    func present(duration: TimeInterval, kind: BreakKind = .short, completion: @escaping () -> Void) {
        guard !presenter.isPresenting else { return }
        self.completion = completion

        let startedAt = Date()
        let message = BreakMessages.current(kind).first ?? "Look far away"
        let subline = BreakMessages.subline(for: message, kind: kind)
        // The long preview is a whole guided break squeezed into a few seconds per move.
        let steps = kind == .long && Stretches.isOn && !Stretches.enabledMoves.isEmpty
            ? Stretches.plan(duration: duration, opening: (message, subline))
            : []
        let presentation = BreakPresentation(
            message: message,
            subline: subline,
            startedAt: startedAt,
            endsAt: startedAt.addingTimeInterval(duration),
            skipDifficulty: SkipDifficulty.current,
            workInterval: UserDefaults.standard.double(forKey: DefaultsKey.workIntervalSec),
            isLong: kind == .long,
            steps: steps
        )

        presenter.present(
            presentation,
            onSkip: { [weak self] in
                guard presentation.canSkip else { return }
                self?.finish(skipped: true)
            },
            onEmergencyExit: { [weak self] in self?.finish(skipped: true) }
        )
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
