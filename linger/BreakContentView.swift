import SwiftUI

struct BreakPresentation {
    let message: String
    let subline: String
    let startedAt: Date
    let endsAt: Date
    let skipDifficulty: SkipDifficulty

    var duration: TimeInterval { endsAt.timeIntervalSince(startedAt) }
    var canSkip: Bool { skipDifficulty.canSkip }
}

struct BreakContentView: View {
    let presentation: BreakPresentation
    let input: OverlayInput
    let onSkip: () -> Void

    @State private var appeared = false
    @State private var settled = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let remaining = max(0, presentation.endsAt.timeIntervalSince(context.date))

            ZStack {
                VStack(spacing: 0) {
                    Text(presentation.message)
                        .font(.system(size: 44, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .opacity(settled ? 0.4 : 1)
                        .entrance(appeared, delay: 0.45, soft: true)
                    Text(presentation.subline)
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.6))
                        .opacity(settled ? 0.4 : 1)
                        .padding(.top, 12)
                        .entrance(appeared, delay: 0.6, soft: true)
                    ring(remaining: remaining)
                        .padding(.top, 48)
                        .entrance(appeared, delay: 0.75, soft: true)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 600)
                .animation(Motion.gentle(Motion.reduceMotion ? 0 : 1.4), value: settled)

                if presentation.canSkip {
                    VStack {
                        Spacer()
                        skipControl
                            .padding(.bottom, 40)
                            .opacity(settled ? 0.6 : 1)
                            .animation(Motion.gentle(Motion.reduceMotion ? 0 : 1.4), value: settled)
                            .entrance(appeared, delay: 0.95, soft: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The text dissolves before the blur lifts, so the room comes back after the words have gone.
            .opacity(input.isDismissing ? 0 : 1)
            .blur(radius: input.isDismissing && !Motion.reduceMotion ? 10 : 0)
            .animation(Motion.gentle(Motion.reduceMotion ? 0.15 : 0.35), value: input.isDismissing)
        }
        .onAppear { appeared = true }
        // Once the message has been read, everything recedes so there is nothing left to watch.
        .task {
            try? await Task.sleep(for: .seconds(Motion.overlaySettle))
            settled = true
        }
    }

    private func ring(remaining: TimeInterval) -> some View {
        let progress = presentation.duration > 0 ? remaining / presentation.duration : 0
        let secondsLeft = Int(remaining.rounded(.up))
        return ZStack {
            Circle()
                .stroke(.white.opacity(0.3), lineWidth: 4)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(secondsLeft)")
                .font(.system(size: 28, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.9))
                .contentTransition(.numericText(countsDown: true))
                .animation(Motion.easeOut(0.3), value: secondsLeft)
                .opacity(settled ? 0 : 1)
                .animation(Motion.gentle(Motion.reduceMotion ? 0 : 1.4), value: settled)
        }
        .frame(width: 96, height: 96)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(secondsLeft) seconds remaining")
    }

    @ViewBuilder
    private var skipControl: some View {
        switch presentation.skipDifficulty {
        case .casual:
            Button(action: onSkip) { SkipLabel(verb: "Press") }
                .buttonStyle(OverlayButtonStyle())
                .onChange(of: input.escapeIsDown) { _, down in
                    if down { onSkip() }
                }
        case .balanced:
            HoldToSkipButton(escapeIsDown: input.escapeIsDown, onComplete: onSkip)
        case .hardcore:
            EmptyView()
        }
    }
}

// MARK: - Controls

// "Hold Esc to skip": the key is drawn as a key so it reads as a key, not a word.
private struct SkipLabel: View {
    let verb: String

    var body: some View {
        HStack(spacing: 6) {
            Text(verb)
            Text("Esc")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 6)
                .frame(height: 20)
                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 1))
            Text("to skip")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(verb) Escape to skip")
    }
}

private struct OverlayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 18)
            .frame(height: 34)
            .background(.white.opacity(configuration.isPressed ? 0.2 : 0.12), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.easeOut(0.16), value: configuration.isPressed)
    }
}

// Deliberate on the way in (1 s linear fill), snappy on release (200 ms ease-out).
private struct HoldToSkipButton: View {
    let escapeIsDown: Bool
    let onComplete: () -> Void

    @State private var fill: Double = 0
    @State private var holding = false
    @State private var holdTask: Task<Void, Never>?

    var body: some View {
        SkipLabel(verb: "Hold")
            .font(.body.weight(.medium))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 18)
            .frame(height: 34)
            .background {
                ZStack(alignment: .leading) {
                    Color.white.opacity(0.12)
                    GeometryReader { geometry in
                        Color.white.opacity(0.28)
                            .frame(width: geometry.size.width * fill)
                    }
                }
            }
            .clipShape(Capsule())
            .scaleEffect(holding ? 0.97 : 1)
            .animation(Motion.easeOut(0.16), value: holding)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !holding { begin() } }
                    .onEnded { _ in end() }
            )
            .onChange(of: escapeIsDown) { _, down in
                if down { begin() } else { end() }
            }
    }

    private func begin() {
        guard !holding else { return }
        holding = true
        withAnimation(.linear(duration: SkipDifficulty.holdDuration)) { fill = 1 }
        holdTask = Task {
            try? await Task.sleep(for: .seconds(SkipDifficulty.holdDuration))
            guard !Task.isCancelled else { return }
            onComplete()
        }
    }

    private func end() {
        guard holding else { return }
        holding = false
        holdTask?.cancel()
        holdTask = nil
        withAnimation(Motion.easeOut(0.2)) { fill = 0 }
    }
}
