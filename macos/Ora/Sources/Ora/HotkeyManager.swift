import AppKit
import Carbon.HIToolbox

/// Carbon-based global hotkey registration. Unlike `NSEvent.addGlobalMonitor`,
/// Carbon's `RegisterEventHotKey` does NOT require Accessibility permission —
/// so the app works out of the box without prompting the user to grant
/// sensitive rights.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var handler: (() -> Void)?
    private var eventHandler: EventHandlerRef?

    private init() {}

    /// Register ⌘⇧T as the toggle-listening hotkey.
    func installDefault(handler: @escaping () -> Void) {
        install(
            keyCode: UInt32(kVK_ANSI_T),
            modifiers: UInt32(cmdKey | shiftKey),
            handler: handler
        )
    }

    func install(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        uninstall()
        self.handler = handler

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData, let event else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    manager.handler?()
                }
                _ = event
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandler
        )
        guard status == noErr else {
            FileHandle.standardError.write(
                "[hotkey] InstallEventHandler failed: \(status)\n".data(using: .utf8) ?? Data()
            )
            return
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x54525458), id: 1)  // 'TRTX'
        var ref: EventHotKeyRef?
        let regStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if regStatus == noErr {
            hotKeyRef = ref
            FileHandle.standardError.write(
                "[hotkey] registered ⌘⇧T\n".data(using: .utf8) ?? Data()
            )
        } else {
            FileHandle.standardError.write(
                "[hotkey] RegisterEventHotKey failed: \(regStatus)\n".data(using: .utf8) ?? Data()
            )
        }
    }

    func uninstall() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let eh = eventHandler {
            RemoveEventHandler(eh)
            eventHandler = nil
        }
        handler = nil
    }
}
