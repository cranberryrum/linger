import SwiftUI

struct SettingsView: View {
    let scheduler: BreakScheduler

    var body: some View {
        TabView {
            BreaksSettingsView(scheduler: scheduler)
                .tabItem { Label("Breaks", systemImage: "eye") }
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 480, height: 360)
    }
}

// MARK: - Breaks

struct BreaksSettingsView: View {
    @Bindable var scheduler: BreakScheduler
    @AppStorage(DefaultsKey.skipDifficulty) private var skipDifficulty: SkipDifficulty = .balanced
    @AppStorage(DefaultsKey.soundOn) private var soundOn = true

    @State private var customInterval: Bool
    @State private var customDuration: Bool
    @State private var messages: [String]

    private static let intervalPresets = [15, 20, 30, 45, 60]
    private static let durationPresets = [15, 20, 30, 45, 60]

    init(scheduler: BreakScheduler) {
        self.scheduler = scheduler
        _customInterval = State(initialValue: !Self.intervalPresets.contains(Int(scheduler.workInterval) / 60))
        _customDuration = State(initialValue: !Self.durationPresets.contains(Int(scheduler.breakDuration)))
        _messages = State(initialValue: UserDefaults.standard.stringArray(forKey: DefaultsKey.messages) ?? BreakMessages.defaults)
    }

    var body: some View {
        Form {
            Section {
                PresetPicker(
                    title: "Break every",
                    presets: Self.intervalPresets,
                    unit: "min",
                    value: intervalMinutes,
                    isCustom: $customInterval
                )
                if customInterval {
                    Stepper("Custom interval: \(Int(scheduler.workInterval) / 60) min", value: intervalMinutes, in: 5...120)
                }

                PresetPicker(
                    title: "Break lasts",
                    presets: Self.durationPresets,
                    unit: "s",
                    value: durationSeconds,
                    isCustom: $customDuration
                )
                if customDuration {
                    Stepper("Custom duration: \(Int(scheduler.breakDuration)) s", value: durationSeconds, in: 10...300, step: 5)
                }
            }

            Section {
                Picker("Skipping", selection: $skipDifficulty) {
                    Text("Casual").tag(SkipDifficulty.casual)
                    Text("Balanced").tag(SkipDifficulty.balanced)
                    Text("Hardcore").tag(SkipDifficulty.hardcore)
                }
                .pickerStyle(.segmented)
                Text(skipDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Messages") {
                ForEach(messages.indices, id: \.self) { index in
                    HStack {
                        TextField("Message", text: $messages[index])
                        Button {
                            messages.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .disabled(messages.count == 1)
                    }
                }
                Button("Add Message") {
                    messages.append("")
                }
            }
            .onChange(of: messages) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: DefaultsKey.messages)
            }

            Section {
                Toggle("Play a sound when a break ends", isOn: $soundOn)
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

    private var skipDescription: String {
        switch skipDifficulty {
        case .casual: "You can skip a break at any time."
        case .balanced: "Skip is disabled for the first 5 seconds of each break."
        case .hardcore: "Breaks cannot be skipped."
        }
    }
}

private struct PresetPicker: View {
    let title: String
    let presets: [Int]
    let unit: String
    @Binding var value: Int
    @Binding var isCustom: Bool

    private enum Choice: Hashable {
        case preset(Int)
        case custom
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            Picker(title, selection: selection) {
                ForEach(presets, id: \.self) { preset in
                    Text("\(preset) \(unit)").tag(Choice.preset(preset))
                }
                Text("Custom").tag(Choice.custom)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var selection: Binding<Choice> {
        Binding(
            get: { isCustom ? .custom : .preset(value) },
            set: { choice in
                switch choice {
                case .custom:
                    isCustom = true
                case .preset(let preset):
                    isCustom = false
                    value = preset
                }
            }
        )
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @AppStorage(DefaultsKey.showCountdownInMenuBar) private var showCountdown = true

    var body: some View {
        Form {
            Section {
                Toggle("Show time to next break in the menu bar", isOn: $showCountdown)
            }
        }
        .formStyle(.grouped)
    }
}
