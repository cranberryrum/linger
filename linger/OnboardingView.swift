import SwiftUI

struct OnboardingView: View {
    @Bindable var scheduler: BreakScheduler
    let onFinish: () -> Void

    private enum Step: Int, CaseIterable {
        case welcome, interval, breakLength, permissions
    }

    private enum Direction {
        case forward, back
    }

    @State private var step: Step = .welcome
    @State private var direction: Direction = .forward
    @State private var preview = BreakPreviewController()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let intervalPresets = [15, 20, 30, 45, 60]
    private static let durationPresets = [15, 20, 30, 45, 60]

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                stepContent
                    .id(step)
                    .transition(stepTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 48)
            .padding(.top, 36)

            footer
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
        }
        .frame(width: 560, height: 420)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:
            WelcomeStep()
        case .interval:
            IntervalStep(scheduler: scheduler, presets: Self.intervalPresets)
        case .breakLength:
            BreakLengthStep(scheduler: scheduler, presets: Self.durationPresets, preview: preview)
        case .permissions:
            PermissionsStep()
        }
    }

    private var footer: some View {
        ZStack {
            PageDots(count: Step.allCases.count, index: step.rawValue)

            HStack {
                Button("Back") { back() }
                    .opacity(step == .welcome ? 0 : 1)
                    .disabled(step == .welcome)
                    .animation(Motion.easeOut(0.2), value: step)
                Spacer()
                Button(step == .permissions ? "Finish" : "Continue") {
                    if step == .permissions { onFinish() } else { forward() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // The incoming page slides in from the direction of travel; the outgoing page just
    // fades so a direction change never makes the old page move the wrong way.
    private var stepTransition: AnyTransition {
        let shift: CGFloat = reduceMotion ? 0 : (direction == .forward ? 28 : -28)
        return .asymmetric(
            insertion: .modifier(active: PageShift(x: shift, visible: false), identity: PageShift(x: 0, visible: true))
                .animation(Motion.easeOut(0.32)),
            removal: .modifier(active: PageShift(x: 0, visible: false), identity: PageShift(x: 0, visible: true))
                .animation(Motion.easeOut(0.16))
        )
    }

    private func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        direction = .back
        withAnimation(Motion.easeOut(0.32)) { step = previous }
    }

    private func forward() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        direction = .forward
        withAnimation(Motion.easeOut(0.32)) { step = next }
    }
}

private struct PageShift: ViewModifier {
    let x: CGFloat
    let visible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(x: x)
            .opacity(visible ? 1 : 0)
            .blur(radius: visible || reduceMotion ? 0 : 3)
    }
}

private struct PageDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { dot in
                Capsule()
                    .fill(dot == index ? Color.accentColor : Color.primary.opacity(0.15))
                    .frame(width: dot == index ? 18 : 7, height: 7)
            }
        }
        .animation(Motion.easeOut(0.3), value: index)
    }
}

// MARK: - Shared page layout

private struct StepPage<Controls: View>: View {
    let symbol: String
    let title: String
    let text: String
    var staggered = false
    @ViewBuilder let controls: Controls

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)
                .frame(height: 76)
                .entrance(shown, delay: 0)
            Text(title)
                .font(.largeTitle.weight(.semibold))
                .padding(.top, 16)
                .entrance(shown, delay: 0.05)
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .entrance(shown, delay: 0.1)
            controls
                .padding(.top, 24)
                .entrance(shown, delay: 0.15)
            Spacer(minLength: 0)
        }
        .onAppear { appeared = true }
    }

    private var shown: Bool { staggered ? appeared : true }
}

// MARK: - Screen 1: Welcome

private struct WelcomeStep: View {
    var body: some View {
        StepPage(
            symbol: "eye",
            title: "linger",
            text: "linger blurs your screen at regular intervals so you remember to look far away.",
            staggered: true
        ) {
            EmptyView()
        }
    }
}

// MARK: - Screen 2: Interval

private struct IntervalStep: View {
    @Bindable var scheduler: BreakScheduler
    let presets: [Int]

    var body: some View {
        StepPage(symbol: "timer", title: "Work interval", text: "How long do you want to work before each break?") {
            PresetSlider(title: "Break every", unit: "min", range: 5...120, step: 1, presets: presets, value: intervalMinutes)
                .frame(maxWidth: 360)
        }
    }

    private var intervalMinutes: Binding<Int> {
        Binding(
            get: { Int(scheduler.workInterval) / 60 },
            set: { scheduler.workInterval = TimeInterval($0 * 60) }
        )
    }
}

// MARK: - Screen 3: Break length

private struct BreakLengthStep: View {
    @Bindable var scheduler: BreakScheduler
    let presets: [Int]
    let preview: BreakPreviewController
    @State private var isPreviewing = false

    var body: some View {
        StepPage(symbol: "hourglass", title: "Break length", text: "How long should each break last?") {
            VStack(spacing: 16) {
                PresetSlider(title: "Break lasts", unit: "s", range: 10...120, step: 5, presets: presets, value: duration)
                    .frame(maxWidth: 360)

                Button("See what a break looks like") { runPreview() }
                    .disabled(isPreviewing)
            }
        }
    }

    private var duration: Binding<Int> {
        Binding(
            get: { Int(scheduler.breakDuration) },
            set: { scheduler.breakDuration = TimeInterval($0) }
        )
    }

    private func runPreview() {
        guard !isPreviewing else { return }
        isPreviewing = true
        preview.present(duration: 5) { isPreviewing = false }
    }
}

// MARK: - Screen 4: Permissions

private struct PermissionsStep: View {
    var body: some View {
        StepPage(
            symbol: "power",
            title: "One optional setting",
            text: "linger blurs your screen without any special permissions. This one just means you never have to remember to open it."
        ) {
            LaunchAtLoginRow(model: PermissionsModel.shared)
                .frame(maxWidth: 460)
        }
    }
}
