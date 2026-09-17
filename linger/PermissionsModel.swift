import AppKit
import Observation
import ServiceManagement
import os

private let log = Logger(subsystem: "com.adityakolte.linger", category: "permissions")

// The toggle stores the user's intent; the status label reports what macOS actually granted.
@Observable
final class PermissionsModel {
    enum LoginItemStatus { case notEnabled, enabled, needsApproval }

    static let shared = PermissionsModel()

    static let loginItemsPane = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

    private(set) var loginItemStatus: LoginItemStatus = .notEnabled

    private(set) var launchAtLoginOn: Bool {
        didSet { UserDefaults.standard.set(launchAtLoginOn, forKey: DefaultsKey.launchAtLoginOn) }
    }

    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?

    private init() {
        launchAtLoginOn = UserDefaults.standard.bool(forKey: DefaultsKey.launchAtLoginOn)
        // The user may have changed it in System Settings while we were in the background.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        loginItemStatus = switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .needsApproval
        default: .notEnabled
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        launchAtLoginOn = on
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("Login item \(on ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
        refresh()
    }
}
