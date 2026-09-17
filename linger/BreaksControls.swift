import AppKit
import SwiftUI

// MARK: - Now card

struct NowCard: View {
    let scheduler: BreakScheduler

    var body: some View {
        let seconds = Int(displayedSeconds.rounded(.up))
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(eyebrow)
                    .font(.caption.weight(.semibold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                Text(Self.clock(seconds))
                    .font(.system(size: 36, weight: .semibold))
                    .tracking(-0.7)
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .opacity(isActive ? 1 : 0.4)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            .animation(Motion.easeOut(0.3), value: seconds)
            .animation(Motion.easeOut(0.2), value: scheduler.state)

            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: 4)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: progress)
                PlayPauseButton(isRunning: isActive, action: toggle)
                    .disabled(isSuspended)
            }
            .frame(width: 72, height: 72)
            .accessibilityElement(children: .contain)
        }
        .padding(.vertical, 6)
    }

    private var isActive: Bool {
        switch scheduler.state {
        case .working, .waitingForInputPause, .onBreak: true
        case .paused, .suspended: false
        }
    }

    private var isSuspended: Bool {
        if case .suspended = scheduler.state { return true }
        return false
    }

    private var displayedSeconds: TimeInterval {
        switch scheduler.state {
        case .paused: scheduler.workInterval
        case .suspended(let remaining, _): remaining
        default: scheduler.remaining
        }
    }

    private var progress: Double {
        switch scheduler.state {
        case .onBreak:
            scheduler.breakDuration > 0 ? scheduler.remaining / scheduler.breakDuration : 0
        case .working, .waitingForInputPause:
            cycleLength > 0 ? scheduler.remaining / cycleLength : 0
        case .paused, .suspended:
            0
        }
    }

    private var cycleLength: TimeInterval { scheduler.workInterval + scheduler.postponedTotal }

    private var eyebrow: String {
        switch scheduler.state {
        case .working: "Next break in"
        case .waitingForInputPause: "Starting when you pause"
        case .onBreak: "On a break"
        case .paused, .suspended: "Paused"
        }
    }

    private var caption: String {
        switch scheduler.state {
        case .working, .waitingForInputPause:
            "Break lasts \(Int(scheduler.breakDuration)) s · at \(Self.time(scheduler.nextBreakAt))"
        case .onBreak(let endsAt):
            "Back at \(Self.time(endsAt))"
        case .paused(let until):
            until == .distantFuture ? "Press play to start again" : "Resumes at \(Self.time(until))"
        case .suspended:
            "Resumes when the screen wakes"
        }
    }

    private func toggle() {
        if isActive {
            scheduler.pauseIndefinitely()
        } else {
            scheduler.resume()
        }
    }

    private static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Play / pause

struct PlayPauseButton: View {
    let isRunning: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isRunning ? "pause.fill" : "play.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .offset(x: isRunning ? 0 : 1)
                .frame(width: 40, height: 40)
                .background(Color.accentColor, in: Circle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(isRunning ? "Pause breaks" : "Resume breaks")
        .animation(Motion.easeOut(0.2), value: isRunning)
    }
}

// Feedback lands on pointer-down, not release.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(Motion.easeOut(0.12), value: configuration.isPressed)
    }
}

// MARK: - Slider with preset ticks

struct PresetSlider: View {
    let title: String
    let unit: String
    let range: ClosedRange<Int>
    let step: Int
    let presets: [Int]
    @Binding var value: Int

    private static let knobInset: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                Text("\(value) \(unit)")
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(Motion.easeOut(0.15), value: value)
            }
            Slider(
                value: sliderValue,
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(step)
            )
            .labelsHidden()
            .accessibilityLabel(title)
            .accessibilityValue("\(value) \(unit)")

            ticks
                .frame(height: 18)
        }
        .padding(.vertical, 4)
    }

    private var sliderValue: Binding<Double> {
        Binding(
            get: { Double(value) },
            set: { newValue in
                let next = Int(newValue.rounded())
                guard next != value else { return }
                if presets.contains(next) {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
                value = next
            }
        )
    }

    private var ticks: some View {
        GeometryReader { geometry in
            let usable = geometry.size.width - 2 * Self.knobInset
            ForEach(presets, id: \.self) { preset in
                let fraction = Double(preset - range.lowerBound) / Double(range.upperBound - range.lowerBound)
                Button {
                    withAnimation(Motion.easeOut(0.2)) { value = preset }
                } label: {
                    VStack(spacing: 3) {
                        Rectangle()
                            .fill(.tertiary)
                            .frame(width: 1, height: 4)
                        Text("\(preset)")
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(value == preset ? Color.accentColor : Color.secondary)
                    }
                    .padding(.horizontal, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .position(x: Self.knobInset + usable * fraction, y: 9)
                .accessibilityLabel("\(preset) \(unit)")
            }
        }
        .animation(Motion.easeOut(0.15), value: value)
    }
}
