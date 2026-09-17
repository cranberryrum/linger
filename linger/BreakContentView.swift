import SwiftUI

struct BreakPresentation {
    let message: String
    let subline: String
    let startedAt: Date
    let endsAt: Date
    let skipDifficulty: SkipDifficulty

    var duration: TimeInterval { endsAt.timeIntervalSince(startedAt) }

    func canSkip(at date: Date) -> Bool {
        skipDifficulty.allowsSkip(elapsed: date.timeIntervalSince(startedAt))
    }
}

struct BreakContentView: View {
    let presentation: BreakPresentation
    let onSkip: () -> Void

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let remaining = max(0, presentation.endsAt.timeIntervalSince(context.date))
            let elapsed = context.date.timeIntervalSince(presentation.startedAt)

            ZStack {
                VStack(spacing: 0) {
                    Text(presentation.message)
                        .font(.system(size: 44, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                    Text(presentation.subline)
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.top, 12)
                    ring(remaining: remaining)
                        .padding(.top, 48)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 600)

                if presentation.skipDifficulty != .hardcore {
                    VStack {
                        Spacer()
                        skipButton(elapsed: elapsed)
                            .padding(.bottom, 40)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func ring(remaining: TimeInterval) -> some View {
        let progress = presentation.duration > 0 ? remaining / presentation.duration : 0
        return ZStack {
            Circle()
                .stroke(.white.opacity(0.3), lineWidth: 4)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(remaining.rounded(.up)))")
                .font(.system(size: 28, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.9))
        }
        .frame(width: 96, height: 96)
    }

    private func skipButton(elapsed: TimeInterval) -> some View {
        let wait = presentation.skipDifficulty == .balanced ? max(0, SkipDifficulty.balancedDelay - elapsed) : 0
        let locked = wait > 0
        return Button(locked ? "Skip in \(Int(wait.rounded(.up)))" : "Skip", action: onSkip)
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(locked)
    }
}
