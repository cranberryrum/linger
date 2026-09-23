import AppKit
import SwiftUI

// A click-through capsule that trails the cursor for the last few seconds before a break,
// so the countdown is where the eyes already are.
final class CursorCountdownController {
    private static let height: CGFloat = 34
    private static let cursorGap: CGFloat = 18
    private static let followRate: CGFloat = 0.28
    private static let settleDistance: CGFloat = 0.5

    private let scheduler: BreakScheduler
    private var panel: NSPanel?
    private var hosting: NSHostingView<CursorPillView>?
    private var followTimer: Timer?
    private var mouseMonitors: [Any] = []
    private var position: NSPoint = .zero
    private var target: NSPoint = .zero
    private var reduceMotion = false

    init(scheduler: BreakScheduler) {
        self.scheduler = scheduler
        observe()
    }

    private func observe() {
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
    }

    private func update() {
        let text: String? = switch scheduler.state {
        case .working where scheduler.remaining > 0 && scheduler.remaining <= BreakScheduler.finalCountdownLead:
            "Starting break in \(Int(scheduler.remaining.rounded(.up)))"
        case .waitingForInputPause:
            "Starting break when you pause"
        default:
            nil
        }
        if let text { show(text) } else { hide() }
    }

    private func show(_ text: String) {
        if panel == nil { create() }
        guard let panel, let hosting else { return }

        hosting.rootView = CursorPillView(text: text)
        let size = NSSize(width: hosting.fittingSize.width, height: Self.height)
        if panel.frame.size != size {
            panel.setContentSize(size)
            pointerMoved()
        }
    }

    private func create() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 160, height: Self.height)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)

        let backdrop = NSVisualEffectView(frame: panel.contentLayoutRect)
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = Self.height / 2
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.borderWidth = 1
        backdrop.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        backdrop.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: CursorPillView(text: ""))
        hosting.frame = backdrop.bounds
        hosting.autoresizingMask = [.width, .height]
        backdrop.addSubview(hosting)
        panel.contentView = backdrop

        reduceMotion = Motion.reduceMotion
        target = targetOrigin(for: panel.frame.size)
        position = target
        panel.setFrameOrigin(position)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = Motion.easeOutCurve
            panel.animator().alphaValue = 1
        }

        self.panel = panel
        self.hosting = hosting

        // The pill moves only when the pointer does: mouse events wake the follow loop and it stops
        // again once the pill has settled, so a still cursor costs no frames at all.
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    private func hide() {
        guard let panel else { return }
        self.panel = nil
        hosting = nil
        stopFollowing()
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        mouseMonitors = []

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = Motion.easeOutCurve
            panel.animator().alphaValue = 0
        }, completionHandler: {
            // Close so the panel is actually released; an ordered-out panel stays alive in NSApp's window list.
            MainActor.assumeIsolated { panel.close() }
        })
    }

    private func pointerMoved() {
        guard let panel else { return }
        target = targetOrigin(for: panel.frame.size)
        if reduceMotion {
            position = target
            panel.setFrameOrigin(position)
            return
        }
        guard followTimer == nil else { return }
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
    }

    private func follow() {
        guard let panel else {
            stopFollowing()
            return
        }
        position.x += (target.x - position.x) * Self.followRate
        position.y += (target.y - position.y) * Self.followRate
        if abs(target.x - position.x) < Self.settleDistance, abs(target.y - position.y) < Self.settleDistance {
            position = target
            stopFollowing()
        }
        panel.setFrameOrigin(position)
    }

    private func stopFollowing() {
        followTimer?.invalidate()
        followTimer = nil
    }

    private func targetOrigin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        var origin = NSPoint(x: mouse.x + Self.cursorGap, y: mouse.y - Self.cursorGap - size.height)

        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            if origin.x + size.width > area.maxX { origin.x = mouse.x - Self.cursorGap - size.width }
            if origin.y < area.minY { origin.y = mouse.y + Self.cursorGap }
        }
        return origin
    }
}

struct CursorPillView: View {
    let text: String
    @State private var appeared = false

    var body: some View {
        Text(text)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .monospacedDigit()
            .lineLimit(1)
            .contentTransition(.numericText(countsDown: true))
            .animation(Motion.easeOut(0.25), value: text)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .fixedSize()
            .scaleEffect(appeared ? 1 : 0.96)
            .animation(Motion.easeOut(0.2), value: appeared)
            .onAppear { appeared = true }
    }
}
