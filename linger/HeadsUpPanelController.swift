import AppKit
import SwiftUI

final class HeadsUpPanelController {
    private static let size = NSSize(width: 384, height: 148)
    private static let cornerRadius: CGFloat = 22
    private static let margin: CGFloat = 16
    private static let autoDismiss: TimeInterval = 10
    // Once touched, the panel stays until the user has left it alone this long.
    private static let dismissAfterActivity: TimeInterval = 4
    private static let swipeDistance: CGFloat = 60
    private static let swipeVelocity: CGFloat = 500
    private static let meetingConfirmationHold: TimeInterval = 2

    private let scheduler: BreakScheduler
    private var panel: NSPanel?
    private var resting: NSRect = .zero
    private var dismissTask: Task<Void, Never>?
    private var hovering = false
    private var postponedThisShowing: TimeInterval = 0
    private var confirmingMeetingHold = false

    private var dragStartX: CGFloat?
    private var lastDragSample: (x: CGFloat, time: TimeInterval)?
    private var dragVelocity: CGFloat = 0

    init(scheduler: BreakScheduler) {
        self.scheduler = scheduler
        observe()
    }

    // Anything other than plain working (a break, a pause, sleep, a meeting) makes the panel stale.
    private func observe() {
        withObservationTracking {
            let heldElsewhere = scheduler.isHoldingForMeeting && !confirmingMeetingHold
            if scheduler.state != .working || heldElsewhere { dismiss() }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
    }

    func show() {
        guard panel == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = makeContent(meeting: MeetingCalendar.shared.currentMeeting())
        panel.invalidateShadow()

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? .zero
        resting = NSRect(
            x: area.maxX - Self.margin - Self.size.width,
            y: area.maxY - Self.margin - Self.size.height,
            width: Self.size.width,
            height: Self.size.height
        )
        let lifted = resting.offsetBy(dx: 0, dy: Motion.reduceMotion ? 0 : 8)

        panel.setFrame(lifted, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { [resting] context in
            context.duration = Motion.reduceMotion ? 0.15 : 0.2
            context.timingFunction = Motion.easeOutCurve
            panel.animator().alphaValue = 1
            panel.animator().setFrame(resting, display: true)
        }

        self.panel = panel
        scheduleDismiss(after: Self.autoDismiss)
    }

    func dismiss() {
        dismiss(swipedAway: false)
    }

    private func dismiss(swipedAway: Bool) {
        guard let panel else { return }
        self.panel = nil
        dismissTask?.cancel()
        dismissTask = nil
        dragStartX = nil
        hovering = false
        postponedThisShowing = 0
        confirmingMeetingHold = false

        let exit = swipedAway
            ? panel.frame.offsetBy(dx: Motion.reduceMotion ? 0 : 80, dy: 0)
            : panel.frame.offsetBy(dx: 0, dy: Motion.reduceMotion ? 0 : 6)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Motion.reduceMotion ? 0.1 : 0.15
            context.timingFunction = Motion.easeOutCurve
            panel.animator().alphaValue = 0
            panel.animator().setFrame(exit, display: true)
        }, completionHandler: {
            // Close, not orderOut: a hidden panel would stay alive and keep re-rendering the countdown every second.
            MainActor.assumeIsolated { panel.close() }
        })
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    // The first postpone on a showing counts toward the per-cycle limit; later clicks add to it,
    // up to the per-card cap.
    private func postpone(by amount: TimeInterval) {
        guard postponedThisShowing + amount <= BreakScheduler.maxPostponePerHeadsUp else { return }
        if postponedThisShowing > 0 {
            scheduler.extendPostpone(by: amount)
        } else {
            scheduler.postpone(by: amount)
        }
        postponedThisShowing += amount
        activity()
    }

    // The card confirms, then leaves on its own; the menu bar carries the state from here.
    private func holdForMeeting(_ meeting: CalendarMeeting) {
        confirmingMeetingHold = true
        scheduler.holdUntilMeetingEnds(meeting.end)
        scheduleDismiss(after: Self.meetingConfirmationHold)
    }

    private func hoverChanged(_ hovering: Bool) {
        self.hovering = hovering
        activity()
    }

    // Hovering holds the panel open; any other interaction restarts the idle countdown.
    private func activity() {
        guard panel != nil, dragStartX == nil, !confirmingMeetingHold else { return }
        if hovering {
            dismissTask?.cancel()
            dismissTask = nil
        } else {
            scheduleDismiss(after: Self.dismissAfterActivity)
        }
    }

    // MARK: Swipe to dismiss

    // Measured in screen space: the panel moves under the pointer, so view-local translation would feed back.
    private func dragChanged() {
        guard let panel else { return }
        let mouseX = NSEvent.mouseLocation.x
        let now = ProcessInfo.processInfo.systemUptime
        if dragStartX == nil {
            dragStartX = mouseX
            dismissTask?.cancel()
            dismissTask = nil
        }
        if let last = lastDragSample, now > last.time {
            dragVelocity = (mouseX - last.x) / (now - last.time)
        }
        lastDragSample = (mouseX, now)

        let dx = mouseX - (dragStartX ?? mouseX)
        let offset = dx >= 0 ? dx : dx * 0.2
        panel.setFrameOrigin(NSPoint(x: resting.minX + offset, y: resting.minY))
        panel.alphaValue = 1 - min(0.4, max(0, dx) / 250)
    }

    private func dragEnded() {
        guard let panel, let startX = dragStartX else { return }
        let dx = NSEvent.mouseLocation.x - startX
        dragStartX = nil
        lastDragSample = nil

        if dx > Self.swipeDistance || dragVelocity > Self.swipeVelocity {
            dismiss(swipedAway: true)
            return
        }
        NSAnimationContext.runAnimationGroup { [resting] context in
            context.duration = 0.2
            context.timingFunction = Motion.easeOutCurve
            panel.animator().alphaValue = 1
            panel.animator().setFrame(resting, display: true)
        }
        activity()
    }

    // MARK: Content

    private func makeContent(meeting: CalendarMeeting?) -> NSView {
        let frame = NSRect(origin: .zero, size: Self.size)
        let backdrop = NSVisualEffectView(frame: frame)
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        // Behind-window blur ignores layer masking and fills the whole window rect; only maskImage clips it.
        backdrop.maskImage = Self.roundedMask(size: Self.size, radius: Self.cornerRadius)
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = Self.cornerRadius
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.borderWidth = 1
        backdrop.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor

        let tint = NSView(frame: frame)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        tint.autoresizingMask = [.width, .height]
        backdrop.addSubview(tint)

        let view = HeadsUpView(
            scheduler: scheduler,
            size: Self.size,
            onStartNow: { [weak self] in
                self?.dismiss()
                self?.scheduler.startBreakNow()
            },
            onPostpone: { [weak self] amount in self?.postpone(by: amount) },
            meeting: meeting,
            calendarReadable: MeetingCalendar.shared.canRead,
            onAfterMeeting: { [weak self] in
                if let meeting { self?.holdForMeeting(meeting) }
            },
            onHover: { [weak self] hovering in self?.hoverChanged(hovering) },
            onDragChanged: { [weak self] in self?.dragChanged() },
            onDragEnded: { [weak self] in self?.dragEnded() }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = frame
        hosting.autoresizingMask = [.width, .height]
        backdrop.addSubview(hosting)
        return backdrop
    }

    // Rendered from a layer so the mask uses the same continuous corner curve as the border.
    private static func roundedMask(size: NSSize, radius: CGFloat) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let shape = CALayer()
            shape.frame = rect
            shape.cornerRadius = radius
            shape.cornerCurve = .continuous
            shape.backgroundColor = NSColor.black.cgColor
            shape.render(in: context)
            return true
        }
    }
}

private struct HeadsUpView: View {
    let scheduler: BreakScheduler
    let size: NSSize
    let onStartNow: () -> Void
    let onPostpone: (TimeInterval) -> Void
    let meeting: CalendarMeeting?
    let calendarReadable: Bool
    let onAfterMeeting: () -> Void
    let onHover: (Bool) -> Void
    let onDragChanged: () -> Void
    let onDragEnded: () -> Void

    @State private var postponedBy: TimeInterval?
    @State private var afterMeeting = false

    private static let postponeMinutes = [1, 10, 15]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    titleRow
                    countdown
                }
                Spacer(minLength: 8)
                if !afterMeeting {
                    meetingControl
                        .transition(.opacity)
                }
            }
            .animation(Motion.easeOut(0.2), value: afterMeeting)

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                Button("Start now", action: onStartNow)
                    .buttonStyle(PillButtonStyle(prominent: true))
                Spacer(minLength: 8)
                ForEach(Self.postponeMinutes, id: \.self) { minutes in
                    let amount = TimeInterval(minutes * 60)
                    Button("+\(minutes) min") { postpone(amount) }
                        .buttonStyle(PillButtonStyle(prominent: false))
                        // Once this card has postponed, further clicks add to it rather than using up
                        // another, but one card never pushes the break back more than 15 minutes.
                        .disabled(!canPostpone(amount))
                }
                .help("Push the break back, up to 15 minutes from this card")
            }
            .disabled(afterMeeting)
            .opacity(afterMeeting ? 0.5 : 1)
            .animation(Motion.easeOut(0.2), value: afterMeeting)
        }
        .padding(20)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { _ in onDragChanged() }
                .onEnded { _ in onDragEnded() }
        )
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            Text(afterMeeting ? "Next break" : "Break starting in")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .contentTransition(.opacity)
            if let postponedBy, !afterMeeting {
                Text("+\(Int(postponedBy / 60)) min")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
                    .contentTransition(.numericText())
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(.white.opacity(0.1), in: Capsule())
                    .transition(.opacity)
            }
        }
        .frame(height: 22)
        .animation(Motion.easeOut(0.2), value: postponedBy)
    }

    private var countdown: some View {
        let seconds = Int(scheduler.remaining.rounded(.up))
        return Group {
            if afterMeeting {
                Text("After your meeting")
                    .transition(.opacity)
            } else {
                Text("\(seconds / 60):\(String(format: "%02d", seconds % 60))")
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(Motion.easeOut(0.3), value: seconds)
            }
        }
        .font(.system(size: 34, weight: .bold))
        .tracking(-0.7)
        .foregroundStyle(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.top, 2)
        .animation(Motion.easeOut(0.2), value: afterMeeting)
    }

    // Secondary, so it sits apart from the postpone row. It names the meeting from the calendar,
    // and is only offered when there is one to wait for.
    private var meetingControl: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Button("After meeting") {
                afterMeeting = true
                onAfterMeeting()
            }
            .buttonStyle(PillButtonStyle(prominent: false, compact: true))
            .disabled(meeting == nil)
            .help(meetingHelp)

            if let meeting {
                Text(meetingCaption(meeting))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 150, alignment: .trailing)
            }
        }
    }

    private var meetingHelp: String {
        if let meeting { return "Hold the break until \(meeting.title) ends at \(meeting.end.formatted(date: .omitted, time: .shortened))" }
        return calendarReadable
            ? "No meeting on your calendar right now"
            : "Turn on Calendar in linger Settings › General to use this"
    }

    // A meeting that hasn't started yet carries its start time, so it's clear which one is meant.
    private func meetingCaption(_ meeting: CalendarMeeting) -> String {
        guard meeting.start > Date() else { return meeting.title }
        return "\(meeting.title) · \(meeting.start.formatted(date: .omitted, time: .shortened))"
    }

    private func canPostpone(_ amount: TimeInterval) -> Bool {
        guard (postponedBy ?? 0) + amount <= BreakScheduler.maxPostponePerHeadsUp else { return false }
        return postponedBy != nil || scheduler.canPostpone
    }

    private func postpone(_ amount: TimeInterval) {
        guard canPostpone(amount) else { return }
        postponedBy = (postponedBy ?? 0) + amount
        onPostpone(amount)
    }
}

// Translucent pills over the dark material; feedback lands on press, not release.
private struct PillButtonStyle: ButtonStyle {
    let prominent: Bool
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(.white.opacity(isEnabled ? (compact ? 0.8 : 0.95) : 0.35))
            .padding(.horizontal, compact ? 9 : 13)
            .frame(height: compact ? 22 : 30)
            .background(fill(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: compact ? 7 : 9, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.easeOut(0.12), value: configuration.isPressed)
    }

    private func fill(pressed: Bool) -> Color {
        let base = prominent ? 0.26 : 0.13
        return .white.opacity(isEnabled ? base + (pressed ? 0.08 : 0) : 0.06)
    }
}
