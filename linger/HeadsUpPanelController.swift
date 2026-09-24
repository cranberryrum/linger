import AppKit
import SwiftUI

final class HeadsUpPanelController {
    private static let size = NSSize(width: 384, height: 148)
    private static let cornerRadius: CGFloat = 22
    private static let margin: CGFloat = 16
    private static let autoDismiss: TimeInterval = 10
    private static let dismissAfterHover: TimeInterval = 3
    private static let confirmationHold: TimeInterval = 4
    private static let swipeDistance: CGFloat = 60
    private static let swipeVelocity: CGFloat = 500

    private let scheduler: BreakScheduler
    private var panel: NSPanel?
    private var resting: NSRect = .zero
    private var dismissTask: Task<Void, Never>?
    private var confirming = false

    private var dragStartX: CGFloat?
    private var lastDragSample: (x: CGFloat, time: TimeInterval)?
    private var dragVelocity: CGFloat = 0

    init(scheduler: BreakScheduler) {
        self.scheduler = scheduler
        observe()
    }

    // Anything other than plain working (a break, a pause, sleep) makes the panel stale.
    private func observe() {
        withObservationTracking {
            if scheduler.state != .working { dismiss() }
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
        panel.contentView = makeContent()

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
        confirming = false

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

    // After a postpone the panel stays just long enough to read the confirmation, then leaves on its own.
    private func postpone(by amount: TimeInterval) {
        scheduler.postpone(by: amount)
        confirming = true
        scheduleDismiss(after: Self.confirmationHold)
    }

    private func hoverChanged(_ hovering: Bool) {
        guard !confirming else { return }
        if hovering {
            dismissTask?.cancel()
            dismissTask = nil
        } else if panel != nil, dragStartX == nil {
            scheduleDismiss(after: Self.dismissAfterHover)
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
        scheduleDismiss(after: Self.dismissAfterHover)
    }

    // MARK: Content

    private func makeContent() -> NSView {
        let frame = NSRect(origin: .zero, size: Self.size)
        let backdrop = NSVisualEffectView(frame: frame)
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
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
}

private struct HeadsUpView: View {
    let scheduler: BreakScheduler
    let size: NSSize
    let onStartNow: () -> Void
    let onPostpone: (TimeInterval) -> Void
    let onHover: (Bool) -> Void
    let onDragChanged: () -> Void
    let onDragEnded: () -> Void

    @State private var postponedBy: TimeInterval?

    private static let postponeMinutes = [1, 10, 15]

    var body: some View {
        let seconds = Int(scheduler.remaining.rounded(.up))
        VStack(alignment: .leading, spacing: 0) {
            Text("Break starting in")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
            Text("\(seconds / 60):\(String(format: "%02d", seconds % 60))")
                .font(.system(size: 34, weight: .bold))
                .tracking(-0.7)
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: true))
                .animation(Motion.easeOut(0.3), value: seconds)
                .padding(.top, 2)

            Spacer(minLength: 12)

            ZStack(alignment: .leading) {
                if let postponedBy {
                    Text("Postponed \(Int(postponedBy / 60)) min · next break at \(scheduler.nextBreakAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .frame(height: 30, alignment: .leading)
                        .transition(.opacity)
                } else {
                    HStack(spacing: 6) {
                        Button("Start now", action: onStartNow)
                            .buttonStyle(PillButtonStyle(prominent: true))
                        Spacer(minLength: 8)
                        ForEach(Self.postponeMinutes, id: \.self) { minutes in
                            Button("+\(minutes) min") { postpone(TimeInterval(minutes * 60)) }
                                .buttonStyle(PillButtonStyle(prominent: false))
                        }
                        .disabled(!scheduler.canPostpone)
                        .help("Postpone the break, up to three times per cycle")
                    }
                    .transition(.opacity)
                }
            }
            .animation(Motion.easeOut(0.2), value: postponedBy)
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

    private func postpone(_ amount: TimeInterval) {
        guard postponedBy == nil else { return }
        postponedBy = amount
        onPostpone(amount)
    }
}

// Translucent pills over the dark material; feedback lands on press, not release.
private struct PillButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(.white.opacity(isEnabled ? 0.95 : 0.35))
            .padding(.horizontal, 13)
            .frame(height: 30)
            .background(fill(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.easeOut(0.12), value: configuration.isPressed)
    }

    private func fill(pressed: Bool) -> Color {
        let base = prominent ? 0.26 : 0.13
        return .white.opacity(isEnabled ? base + (pressed ? 0.08 : 0) : 0.06)
    }
}
