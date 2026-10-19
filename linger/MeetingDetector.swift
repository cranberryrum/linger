import AppKit
import CoreAudio
import CoreMediaIO
import os

private let log = Logger(subsystem: "com.adityakolte.linger", category: "meetings")

// Tells the scheduler when a break would land on a call or a presentation. Everything here is a
// read of system state that needs no permission: which processes are recording from a microphone,
// whether a camera is running, and which windows are on screen.
final class MeetingDetector {
    enum Activity: Equatable {
        case call(app: String)
        case presenting(app: String)
    }

    // A call keeps counting for this long after the last signal, so a device switch or a moment of
    // silence on a flaky stream doesn't end it.
    private static let endGrace: TimeInterval = 20
    // Apps we don't recognise must hold the microphone this long before it reads as a call; a
    // dictation burst is over well before this.
    private static let unknownAppSustain: TimeInterval = 120
    // Browsers host Meet, Teams and Zoom web, but also the odd voice search.
    private static let browserSustain: TimeInterval = 15
    private static let pollInterval: TimeInterval = 4

    private(set) var activity: Activity?

    private var lastPoll: Date = .distantPast
    private var lastSeen: Date = .distantPast
    private var lastSeenActivity: Activity?
    private var inputSince: [String: Date] = [:]
    private var debugUntil: Date?

    // Cheap to call every tick; the system is only queried every few seconds.
    func update(now: Date = Date()) {
        if let debugUntil {
            if now < debugUntil {
                activity = .call(app: "Simulated call")
                return
            }
            self.debugUntil = nil
        }
        guard now.timeIntervalSince(lastPoll) >= Self.pollInterval else { return }
        lastPoll = now

        if let found = detect(now: now) {
            if found != lastSeenActivity { log.debug("Detected \(String(describing: found))") }
            lastSeen = now
            lastSeenActivity = found
            activity = found
        } else if activity != nil, now.timeIntervalSince(lastSeen) >= Self.endGrace {
            log.debug("Meeting ended")
            activity = nil
            lastSeenActivity = nil
        }
    }

    func debugSimulate(for seconds: TimeInterval) {
        debugUntil = Date().addingTimeInterval(seconds)
        update()
    }

    private func detect(now: Date) -> Activity? {
        if let presenter = Self.presentingApp() { return .presenting(app: presenter) }
        if let caller = callApp(now: now) { return .call(app: caller) }
        if Self.cameraIsRunning() { return .call(app: "Camera") }
        return nil
    }

    // MARK: Microphone

    private func callApp(now: Date) -> String? {
        // The process list is only walked while some input device is actually recording.
        guard Self.anyInputDeviceRunning() else {
            inputSince.removeAll()
            return nil
        }
        let recording = Set(Self.processesRecordingInput())
        inputSince = inputSince.filter { recording.contains($0.key) }

        for bundleID in recording {
            let since = inputSince[bundleID] ?? now
            inputSince[bundleID] = since
            let held = now.timeIntervalSince(since)

            switch AppKind(bundleID: bundleID) {
            case .dictation:
                continue
            case .call:
                return Self.displayName(for: bundleID)
            case .browser where held >= Self.browserSustain:
                return Self.displayName(for: bundleID)
            case .unknown where held >= Self.unknownAppSustain:
                return Self.displayName(for: bundleID)
            case .browser, .unknown:
                continue
            }
        }
        return nil
    }

    private static func anyInputDeviceRunning() -> Bool {
        audioObjects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).contains { device in
            var streams = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &size) == noErr, size > 0 else { return false }
            return uint32(device, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1
        }
    }

    private static func processesRecordingInput() -> [String] {
        audioObjects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).compactMap { process in
            guard uint32(process, kAudioProcessPropertyIsRunningInput) == 1 else { return nil }
            var bundle = address(kAudioProcessPropertyBundleID)
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var value: Unmanaged<CFString>?
            guard AudioObjectGetPropertyData(process, &bundle, 0, nil, &size, &value) == noErr,
                  let id = value?.takeRetainedValue() as String?, !id.isEmpty
            else { return nil }
            return id
        }
    }

    // MARK: Camera

    private static func cameraIsRunning() -> Bool {
        var devices = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &devices, 0, nil, &size) == noErr, size > 0 else { return false }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &devices, 0, nil, size, &used, &ids) == noErr else { return false }

        return ids.contains { id in
            var running = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            var value: UInt32 = 0
            var read: UInt32 = 0
            return CMIOObjectGetPropertyData(id, &running, 0, nil, 4, &read, &value) == noErr && value == 1
        }
    }

    // MARK: Presentations

    // Presenting means a slide app covers a whole display, or the screen is mirrored to a projector.
    private static func presentingApp() -> String? {
        if displayIsMirrored() { return "Mirrored display" }

        let displays = NSScreen.screens.map { screen in
            // CGWindow bounds are top-left based in global coordinates; only the size matters here.
            screen.frame.size
        }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let app = NSRunningApplication(processIdentifier: pid),
                  let bundleID = app.bundleIdentifier,
                  presentationApps.contains(where: { bundleID.lowercased().hasPrefix($0) }),
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { continue }
            if displays.contains(where: { abs($0.width - bounds.width) < 1 && abs($0.height - bounds.height) < 1 }) {
                return app.localizedName ?? bundleID
            }
        }
        return nil
    }

    private static func displayIsMirrored() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 1 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return false }
        return ids.contains { CGDisplayMirrorsDisplay($0) != kCGNullDirectDisplay }
    }

    private static let presentationApps = [
        "com.apple.iwork.keynote",
        "com.microsoft.powerpoint",
        "io.pitch.",
        "com.figma.desktop", // Figma's presentation view
    ]

    // MARK: Helpers

    private static func displayName(for bundleID: String) -> String {
        let base = AppKind.baseBundleID(bundleID)
        if base.lowercased().hasPrefix("com.apple.webkit") { return "Safari" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: base) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return base
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func audioObjects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}

// Who is holding the microphone decides what it means.
private enum AppKind {
    case call, browser, dictation, unknown

    init(bundleID: String) {
        let id = bundleID.lowercased()
        func matches(_ list: [String]) -> Bool { list.contains { id.hasPrefix($0) } }
        // Dictation first: some of these are Electron apps whose helpers would otherwise look unknown.
        if matches(Self.dictationApps) { self = .dictation }
        else if matches(Self.callApps) { self = .call }
        else if matches(Self.browserApps) { self = .browser }
        else { self = .unknown }
    }

    // "com.google.Chrome.helper" and "company.thebrowser.browser.helper" belong to their app.
    static func baseBundleID(_ id: String) -> String {
        for suffix in [".helper", ".Helper"] where id.hasSuffix(suffix) {
            return String(id.dropLast(suffix.count))
        }
        return id
    }

    // Voice typing and always-listening tools: the mic is busy, but nobody is on a call.
    private static let dictationApps = [
        "com.pais.handy",
        "com.zeitalabs.jottleai",
        "com.electron.wispr-flow", "com.wispr.",
        "com.superduper.superwhisper",
        "com.goodsnooze.macwhisper",
        "com.prakashjoshipax.voiceink",
        "com.aquavoice.", "com.withaqua.",
        "com.openai.chat", // ChatGPT voice mode
        "com.raycast.",
        "ai.krisp.", // Krisp holds the real mic for whichever app uses its virtual one
        "com.apple.corespeech", "com.apple.assistantd", "com.apple.siri",
        "com.apple.speechrecognitioncore", "com.apple.accessibility.heard",
        "com.apple.universalaccessd", "com.apple.dictation",
    ]

    private static let callApps = [
        "us.zoom.", "com.microsoft.teams", "com.tinyspeck.slackmacgap",
        "com.cisco.webex", "cisco-systems.spark", "com.webex.",
        "com.hnc.discord", "com.apple.facetime", "com.apple.avconferenced",
        "com.apple.telephonyutilities", "net.whatsapp.", "org.whispersystems.signal",
        "ru.keepcoder.telegram", "com.skype.", "com.logmein.", "com.ringcentral.",
        "com.amazon.chime", "com.bytedance.lark", "co.around.", "com.tuple.",
        "com.loom.", "com.granola.", "com.getgather.", "com.google.meet",
    ]

    private static let browserApps = [
        "com.google.chrome", "company.thebrowser.", "com.apple.safari", "com.apple.webkit",
        "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.browser",
        "com.vivaldi.vivaldi", "com.operasoftware.", "app.zen-browser.",
    ]
}
