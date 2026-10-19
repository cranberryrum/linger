import SwiftUI

struct SettingsView: View {
    let scheduler: BreakScheduler
    let debug: DebugActions

    @State private var selection: SettingsSection? = .breaks

    private enum SettingsSection: String, CaseIterable, Identifiable {
        case breaks = "Breaks", messages = "Messages", general = "General", debug = "Debug"

        var id: Self { self }
        var symbol: String {
            switch self {
            case .breaks: "eye"
            case .messages: "text.quote"
            case .general: "gearshape"
            case .debug: "ladybug"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            // Native sidebar rows include 8 pt of inset; match the form's 20 pt gutter.
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                AuthorRow()
                    .padding(20)
            }
            .background(SettingsBackground(sidebar: true))
            .frame(width: 220)

            Divider()

            Group {
                switch selection ?? .breaks {
                case .breaks:
                    BreaksSettingsView(scheduler: scheduler)
                case .messages:
                    MessagesSettingsView()
                case .general:
                    GeneralSettingsView(showOnboarding: debug.showOnboarding)
                case .debug:
                    DebugSettingsView(scheduler: scheduler, actions: debug)
                }
            }
            .scrollContentBackground(.hidden)
            .background(SettingsBackground())
            .navigationTitle("linger")
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 700, height: 480)
    }
}

// MARK: - Breaks

struct BreaksSettingsView: View {
    @Bindable var scheduler: BreakScheduler
    @AppStorage(DefaultsKey.skipDifficulty) private var skipDifficulty: SkipDifficulty = .balanced
    @AppStorage(DefaultsKey.soundOn) private var soundOn = true
    @State private var preview = BreakPreviewController()
    @State private var isPreviewing = false

    var body: some View {
        Form {
            Section {
                NowCard(scheduler: scheduler)
            }

            Section {
                PresetSlider(title: "Break every", unit: "min", range: 5...120, step: 1, presets: [15, 20, 30, 45, 60], value: intervalMinutes)
                PresetSlider(title: "Break lasts", unit: "s", range: 10...120, step: 5, presets: [15, 20, 30, 45, 60], value: durationSeconds)
            }

            WorkHoursSection(scheduler: scheduler)
            LongBreaksSection(scheduler: scheduler)

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

// MARK: - Work hours

private struct WorkHoursSection: View {
    @Bindable var scheduler: BreakScheduler

    var body: some View {
        Section {
            Toggle("Only during work hours", isOn: $scheduler.workHoursOn)
            if scheduler.workHoursOn {
                LabeledContent("Days") {
                    HStack(spacing: 4) {
                        ForEach(Self.weekdays, id: \.self) { weekday in
                            Toggle(Calendar.current.veryShortWeekdaySymbols[weekday - 1], isOn: day(weekday))
                                .toggleStyle(.button)
                                .accessibilityLabel(Calendar.current.weekdaySymbols[weekday - 1])
                        }
                    }
                }
                DatePicker("From", selection: time(\.start), displayedComponents: .hourAndMinute)
                DatePicker("To", selection: time(\.end), displayedComponents: .hourAndMinute)
            }
        } footer: {
            if scheduler.workHoursOn {
                Text("Outside these hours linger rests. Take a Break Now still works.")
            }
        }
    }

    // In the locale's order, starting from its first weekday.
    private static var weekdays: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    private func day(_ weekday: Int) -> Binding<Bool> {
        Binding(
            get: { scheduler.workHours.days.contains(weekday) },
            set: { on in
                if on { scheduler.workHours.days.insert(weekday) } else { scheduler.workHours.days.remove(weekday) }
            }
        )
    }

    private func time(_ keyPath: WritableKeyPath<WorkHours, Int>) -> Binding<Date> {
        Binding(
            get: {
                let minutes = scheduler.workHours[keyPath: keyPath]
                return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                scheduler.workHours[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }
}

// MARK: - Long breaks

private struct LongBreaksSection: View {
    @Bindable var scheduler: BreakScheduler

    private static let everyOptions = [2, 3, 4, 6]
    private static let durationOptions = [2, 3, 5]

    var body: some View {
        Section {
            Toggle("Long breaks", isOn: $scheduler.longBreaksOn)
            if scheduler.longBreaksOn {
                Picker("Every", selection: $scheduler.longBreakEvery) {
                    ForEach(Self.everyOptions, id: \.self) { count in
                        Text(everyLabel(count)).tag(count)
                    }
                }
                Picker("Lasts", selection: durationMinutes) {
                    ForEach(Self.durationOptions, id: \.self) { minutes in
                        Text("\(minutes) min").tag(minutes)
                    }
                }
            }
        }
    }

    private var durationMinutes: Binding<Int> {
        Binding(
            get: { Int(scheduler.longBreakDuration) / 60 },
            set: { scheduler.longBreakDuration = TimeInterval($0 * 60) }
        )
    }

    // "3rd break · about every hour", from the current interval.
    private func everyLabel(_ count: Int) -> String {
        let ordinal = NumberFormatter.localizedString(from: count as NSNumber, number: .ordinal)
        return "\(ordinal) break · about every \(Self.approximate(minutes: Int(scheduler.workInterval) / 60 * count))"
    }

    private static func approximate(minutes: Int) -> String {
        let rounded = max(5, Int((Double(minutes) / 5).rounded()) * 5)
        if rounded % 60 == 0 { return rounded == 60 ? "hour" : "\(rounded / 60) hours" }
        return Duration.seconds(rounded * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}

// MARK: - Messages

struct MessagesSettingsView: View {
    @AppStorage(DefaultsKey.longBreaksOn) private var longBreaksOn = false
    @State private var preview = BreakPreviewController()
    @State private var isPreviewing = false

    var body: some View {
        Form {
            MessageListSection(kind: .short)
            if longBreaksOn {
                MessageListSection(kind: .long)
            }

            Section {
                HStack {
                    Spacer()
                    PreviewButton(isPreviewing: $isPreviewing, preview: preview)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// One editable list of break messages; the short and long lists share the model and the editor.
private struct MessageListSection: View {
    let kind: BreakKind
    @State private var messages: [BreakMessage]
    @FocusState private var focusedMessage: BreakMessage.ID?

    init(kind: BreakKind) {
        self.kind = kind
        _messages = State(initialValue: BreakMessages.all(kind))
    }

    var body: some View {
        Section {
            ForEach($messages) { $message in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Message", text: $message.title)
                            .focused($focusedMessage, equals: message.id)
                            .accessibilityLabel("Break message")
                        TextField("Sub-line (optional)", text: $message.subline)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Message sub-line")
                    }
                    .textFieldStyle(.plain)
                    .padding(.vertical, 4)

                    Menu {
                        Button("Move up") { move(message.id, by: -1) }
                            .disabled(messages.first?.id == message.id)
                        Button("Move down") { move(message.id, by: 1) }
                            .disabled(messages.last?.id == message.id)
                        Divider()
                        Button("Delete message", role: .destructive) {
                            messages.removeAll { $0.id == message.id }
                        }
                        .disabled(messages.count == 1)
                    } label: {
                        Label("Message actions", systemImage: "ellipsis")
                    }
                    .labelStyle(.iconOnly)
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Move or delete this message")
                }
            }

            Button {
                let message = BreakMessage(title: "")
                messages.append(message)
                focusedMessage = message.id
            } label: {
                Label("Add message", systemImage: "plus")
            }
        } header: {
            if kind == .long { Text("Long breaks") }
        } footer: {
            Text(kind == .long ? "One message per long break, in this order." : "One message per break, in this order.")
        }
        .onChange(of: messages) { _, newValue in BreakMessages.save(newValue, kind: kind) }
        .onDisappear { prune() }
    }

    private func move(_ id: BreakMessage.ID, by offset: Int) {
        guard let index = messages.firstIndex(where: { $0.id == id }),
              messages.indices.contains(index + offset) else { return }
        messages.swapAt(index, index + offset)
    }

    // Blank rows are dropped when the pane goes away, so what you see in the list is what plays.
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
                CalendarRow(model: MeetingCalendar.shared)
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
            }

            Section {
                Button("Show welcome again") { showOnboarding() }
            }

        }
        .formStyle(.grouped)
    }
}


private struct AuthorRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Aditya Kolte")
                    .font(.callout.weight(.medium))
                Text("Product designer who builds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 16) {
                Link("Website", destination: URL(string: "https://adityakolte.com/")!)
                Link("Twitter", destination: URL(string: "https://x.com/adityakvlte")!)
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}
