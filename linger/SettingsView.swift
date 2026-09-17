import SwiftUI

struct SettingsView: View {
    let scheduler: BreakScheduler
    let debug: DebugActions

    var body: some View {
        TabView {
            BreaksSettingsView(scheduler: scheduler)
                .tabItem { Label("Breaks", systemImage: "eye") }
            MessagesSettingsView()
                .tabItem { Label("Messages", systemImage: "text.quote") }
            GeneralSettingsView(showOnboarding: debug.showOnboarding)
                .tabItem { Label("General", systemImage: "gearshape") }
            DebugSettingsView(scheduler: scheduler, actions: debug)
                .tabItem { Label("Debug", systemImage: "ladybug") }
        }
        .frame(width: 480)
    }
}

// MARK: - Breaks

struct BreaksSettingsView: View {
    @Bindable var scheduler: BreakScheduler
    @AppStorage(DefaultsKey.skipDifficulty) private var skipDifficulty: SkipDifficulty = .balanced
    @AppStorage(DefaultsKey.soundOn) private var soundOn = true
    @State private var preview = BreakPreviewController()
    @State private var isPreviewing = false

    private static let presets = [15, 20, 30, 45, 60]

    var body: some View {
        Form {
            Section {
                NowCard(scheduler: scheduler)
            }

            Section {
                PresetSlider(title: "Break every", unit: "min", range: 5...120, step: 1, presets: Self.presets, value: intervalMinutes)
                PresetSlider(title: "Break lasts", unit: "s", range: 10...120, step: 5, presets: Self.presets, value: durationSeconds)
            }

            Section {
                Picker("Skip breaks", selection: $skipDifficulty) {
                    Text("Anytime").tag(SkipDifficulty.casual)
                    Text("Hold to skip").tag(SkipDifficulty.balanced)
                    Text("Never").tag(SkipDifficulty.hardcore)
                }
                .pickerStyle(.segmented)

                HStack {
                    Toggle("Play sounds", isOn: $soundOn)
                    Button {
                        Sounds.play(.breakEnd, ignoringPreference: true)
                    } label: {
                        Image(systemName: "speaker.wave.2")
                    }
                    .buttonStyle(.borderless)
                    .help("Hear the break-end tone")
                }

                PreviewButton(isPreviewing: $isPreviewing, preview: preview)
            } footer: {
                Text("Soft tones ten seconds before a break, when it starts and ends, and when you skip one.")
            }
        }
        .formStyle(.grouped)
    }

    private var intervalMinutes: Binding<Int> {
        Binding(
            get: { Int(scheduler.workInterval) / 60 },
            set: { scheduler.workInterval = TimeInterval($0 * 60) }
        )
    }

    private var durationSeconds: Binding<Int> {
        Binding(
            get: { Int(scheduler.breakDuration) },
            set: { scheduler.breakDuration = TimeInterval($0) }
        )
    }

}

private struct PreviewButton: View {
    @Binding var isPreviewing: Bool
    let preview: BreakPreviewController

    var body: some View {
        Button(isPreviewing ? "Previewing…" : "Preview a break") {
            guard !isPreviewing else { return }
            isPreviewing = true
            preview.present(duration: 5) { isPreviewing = false }
        }
        .disabled(isPreviewing)
    }
}

// MARK: - Messages

struct MessagesSettingsView: View {
    @State private var messages = BreakMessages.all
    @State private var selection: BreakMessage.ID?
    @State private var preview = BreakPreviewController()
    @State private var isPreviewing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("One message is shown per break, in this order.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List(selection: $selection) {
                ForEach($messages) { $message in
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("Message", text: $message.title)
                        TextField("Sub-line (optional)", text: $message.subline)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .textFieldStyle(.plain)
                    .padding(.vertical, 4)
                    .tag(message.id)
                }
                .onMove { messages.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(height: 260)

            HStack(spacing: 8) {
                Button {
                    let message = BreakMessage(title: "")
                    withAnimation(Motion.easeOut(0.25)) { messages.append(message) }
                    selection = message.id
                } label: {
                    Image(systemName: "plus")
                }
                Button {
                    withAnimation(Motion.easeOut(0.25)) { messages.removeAll { $0.id == selection } }
                    selection = nil
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil || messages.count == 1)

                Spacer()

                PreviewButton(isPreviewing: $isPreviewing, preview: preview)
            }
        }
        .padding(20)
        .onChange(of: messages) { _, newValue in BreakMessages.save(newValue) }
        .onDisappear { prune() }
    }

    // Blank rows are dropped when the tab goes away, so what you see in the list is what plays.
    private func prune() {
        let kept = messages.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !kept.isEmpty, kept.count != messages.count else { return }
        messages = kept
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    let showOnboarding: () -> Void
    @AppStorage(DefaultsKey.menuBarCountdown) private var countdown: MenuBarCountdown = .minutes

    var body: some View {
        Form {
            Section {
                LaunchAtLoginRow(model: PermissionsModel.shared)
            }

            Section {
                Picker("Time to next break in the menu bar", selection: $countdown) {
                    Text("Off").tag(MenuBarCountdown.off)
                    Text("Minutes").tag(MenuBarCountdown.minutes)
                    Text("Precise").tag(MenuBarCountdown.precise)
                }
            } footer: {
                Text("Minutes shows “18m” and counts down in seconds only during the last minute.")
            }

            Section {
                LabeledContent("Take a break now") {
                    Text("⌃⌥⌘L")
                        .monospaced()
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("The shortcut is fixed in this version.")
            }

            Section {
                Button("Show welcome again") { showOnboarding() }
            }
        }
        .formStyle(.grouped)
    }
}
