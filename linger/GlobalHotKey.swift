import Carbon.HIToolbox

final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(
            GetApplicationEventTarget(), hotKeyPressed, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(), &handlerRef
        )
        guard installed == noErr else { return nil }

        let signature = "lngr".utf8.reduce(OSType(0)) { $0 << 8 | OSType($1) }
        let hotKeyID = EventHotKeyID(signature: signature, id: 1)
        let registered = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef
        )
        guard registered == noErr else {
            RemoveEventHandler(handlerRef)
            return nil
        }
    }

    fileprivate func fire() {
        action()
    }
}

private nonisolated func hotKeyPressed(_: EventHandlerCallRef?, _: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { hotKey.fire() }
    return noErr
}
