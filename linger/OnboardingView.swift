import SwiftUI

struct OnboardingView: View {
    @Bindable var scheduler: BreakScheduler
    let onFinish: () -> Void

    private enum Step: Int {
        case welcome, interval, breakLength, permissions
    }

    @State private var step: Step = .welcome
    @State private var customInterval: Bool
    @State private var previewController: BreakPreviewController?

    private static let intervalPresets = [15, 20, 30, 45, 60]
    private static let durationPresets = [15, 20, 30, 45, 60]

    init(scheduler: BreakScheduler, onFinish: @escaping () -> Void) {
        self.scheduler = scheduler
        self.onFinish = onFinish
        _customInterval = State(initialValue: !Self.intervalPresets.contains(Int(scheduler.workInterval) / 60))
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 32)

            Group {
                switch step {
                case .welcome:
                    WelcomeStep()
                case .interval:
                    IntervalStep(scheduler: scheduler, customInterval: $customInterval, presets: Self.intervalPresets)
                case .breakLength:
                    BreakLengthStep(scheduler: scheduler, presets: Self.durationPresets, previewController: $previewController)
                case .permissions:
                    PermissionsStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 44)

            Spacer(minLength: 32)

            buttons
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
        }
        .frame(width: 560, height: 460)
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            if step != .welcome {
                Button("Back") { back() }
            }
            Spacer()
            if step == .permissions {
                Button("Finish") { finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") { forward() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    private func forward() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: DefaultsKey.hasCompletedOnboarding)
        onFinish()
    }
}

// MARK: - Screen 1: Welcome

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 96, height: 96)
            Text("linger blurs your screen at regular intervals so you remember to look far away.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Screen 2: Interval

private struct IntervalStep: View {
    @Bindable var scheduler: BreakScheduler
    @Binding var customInterval: Bool
    let presets: [Int]

    private enum Choice: Hashable {
        case preset(Int)
        case custom
    }

    var body: some View {
        VStack(spacing: 24) {
            Text("How long do you want to work before each break?")
                .font(.title3)
                .multilineTextAlignment(.center)

            Picker("", selection: selection) {
                ForEach(presets, id: \.self) { preset in
                    Text("\(preset) min").tag(Choice.preset(preset))
                }
                Text("Custom").tag(Choice.custom)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if customInterval {
                Stepper("Custom interval: \(Int(scheduler.workInterval) / 60) min", value: intervalMinutes, in: 5...120)
            }
        }
    }

    private var selection: Binding<Choice> {
        Binding(
            get: { customInterval ? .custom : .preset(Int(scheduler.workInterval) / 60) },
            set: { choice in
                switch choice {
                case .custom:
                    customInterval = true
                case .preset(let value):
                    customInterval = false
                    scheduler.workInterval = TimeInterval(value * 60)
                }
            }
        )
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
    @Binding var previewController: BreakPreviewController?
    @State private var isPreviewing = false

    var body: some View {
        VStack(spacing: 24) {
            Text("How long should each break last?")
                .font(.title3)
                .multilineTextAlignment(.center)

            Picker("", selection: duration) {
                ForEach(presets, id: \.self) { preset in
                    Text("\(preset) s").tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Button("See what a break looks like") { preview() }
                .disabled(isPreviewing)
        }
    }

    private var duration: Binding<Int> {
        Binding(
            get: { Int(scheduler.breakDuration) },
            set: { scheduler.breakDuration = TimeInterval($0) }
        )
    }

    private func preview() {
        guard !isPreviewing else { return }
        isPreviewing = true
        let controller = BreakPreviewController()
        previewController = controller
        controller.present(duration: 5) {
            isPreviewing = false
            previewController = nil
        }
    }
}

// MARK: - Screen 4: Permissions

private struct PermissionsStep: View {
    @AppStorage(DefaultsKey.headsUpOn) private var notificationsOn = false
    @AppStorage(DefaultsKey.launchAtLoginOn) private var launchAtLoginOn = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Two optional settings")
                    .font(.headline)
                Text("linger can blur your screen without any special permissions. These two just make it more convenient.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            PermissionRow(
                systemImage: "bell.badge",
                title: "Heads-up before each break",
                detail: "Get a small notification 60 seconds before the screen blurs, with a Postpone button. If you skip this, linger shows the heads-up in its own small panel.",
                isOn: $notificationsOn,
                status: notificationsOn ? "Allowed" : "Not enabled"
            )

            PermissionRow(
                systemImage: "power",
                title: "Start linger when I log in",
                detail: "Runs quietly in the menu bar every time you start your Mac. macOS may show a \"Background Items Added\" notice, that is expected.",
                isOn: $launchAtLoginOn,
                status: launchAtLoginOn ? "Enabled" : "Needs approval — open Login Items"
            )

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PermissionRow: View {
    let systemImage: String
    let title: String
    let detail: String
    @Binding var isOn: Bool
    let status: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .fontWeight(.semibold)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}
