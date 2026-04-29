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

    func install(shortcut: GlobalHotkey, handler: @escaping () -> Void) {
        self.handler = handler
        register(shortcut: shortcut)
    }

    func updateShortcut(_ shortcut: GlobalHotkey) {
        register(shortcut: shortcut)
    }

    private func register(shortcut: GlobalHotkey) {
        unregisterHotKey()

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
            shortcut.carbonKeyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if regStatus == noErr {
            hotKeyRef = ref
            FileHandle.standardError.write(
                "[hotkey] registered \(shortcut.glyphs)\n".data(using: .utf8) ?? Data()
            )
        } else {
            FileHandle.standardError.write(
                "[hotkey] RegisterEventHotKey failed for \(shortcut.glyphs): \(regStatus)\n".data(using: .utf8) ?? Data()
            )
        }
    }

    private func unregisterHotKey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let eh = eventHandler {
            RemoveEventHandler(eh)
            eventHandler = nil
        }
    }

    func uninstall() {
        unregisterHotKey()
        handler = nil
    }
}
