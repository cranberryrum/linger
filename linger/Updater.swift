import AppKit
import Observation
import Sparkle
import os

private let log = Logger(subsystem: "com.adityakolte.linger", category: "updates")

// Keeps linger current through Sparkle without ever interrupting. Updates download in the
// background and install the next time you've stepped away: after three idle minutes the scheduler
// restarts the cycle anyway, so a relaunch then costs nothing. Until that moment the only trace is
// the menu item reading "Install Update and Relaunch".
@Observable
final class Updater: NSObject {
    static let shared = Updater()

    // A downloaded update waiting for a quiet moment.
    private(set) var readyVersion: String?
    // An update Sparkle found but won't fetch on its own (automatic updates off); the menu offers it.
    private(set) var availableVersion: String?

    @ObservationIgnored private var installNow: (() -> Void)?
    @ObservationIgnored private var quietMomentTimer: Timer?
    @ObservationIgnored private weak var scheduler: BreakScheduler?
    @ObservationIgnored private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: self
    )

    func start(scheduler: BreakScheduler) {
        self.scheduler = scheduler
        controller.startUpdater()
    }

    var automaticallyUpdates: Bool {
        get {
            access(keyPath: \.automaticallyUpdates)
            return controller.updater.automaticallyDownloadsUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyUpdates) {
                controller.updater.automaticallyChecksForUpdates = newValue
                controller.updater.automaticallyDownloadsUpdates = newValue
            }
        }
    }

    var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    func checkForUpdates() {
        if let installNow {
            installNow()
        } else {
            controller.checkForUpdates(nil)
        }
    }

    // MARK: Quiet moment

    private func waitForQuietMoment() {
        guard quietMomentTimer == nil else { return }
        // Only alive while an update is waiting, so an up-to-date app pays nothing.
        quietMomentTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.installIfQuiet() }
        }
    }

    private func installIfQuiet() {
        guard let installNow, isQuietMoment else { return }
        log.info("Installing \(self.readyVersion ?? "?", privacy: .public) while the user is away")
        quietMomentTimer?.invalidate()
        quietMomentTimer = nil
        installNow()
    }

    // A relaunch must never land on a break, a heads-up, a meeting, a pause the user chose (pauses
    // don't survive a relaunch) or an open window.
    private var isQuietMoment: Bool {
        guard let scheduler, case .working = scheduler.state,
              scheduler.remaining > BreakScheduler.headsUpLead,
              !scheduler.isHoldingForMeeting,
              scheduler.secondsSinceLastInput >= BreakScheduler.idleThreshold
        else { return false }
        return !NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
    }
}

extension Updater: SPUUpdaterDelegate {
    // The Debug build lives in DerivedData and must never swap itself for a release from the feed;
    // it still checks when asked from the menu, so the flow can be tried.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        #if DEBUG
        if updateCheck != .updates {
            throw CocoaError(.userCancelled)
        }
        #endif
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        readyVersion = item.displayVersionString
        availableVersion = nil
        installNow = immediateInstallHandler
        waitForQuietMoment()
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        log.debug("Update check ended: \(error.localizedDescription, privacy: .public)")
    }
}

extension Updater: SPUStandardUserDriverDelegate {
    // linger has no Dock icon; a scheduled alert would pop up over whatever you're doing.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        availableVersion = handleShowingUpdate ? nil : update.displayVersionString
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        availableVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
    }
}
