import Carbon.HIToolbox
import SwiftUI

enum GlobalHotkey: String, CaseIterable {
    case optionSpace
    case commandOptionT
    case commandShiftY
    case controlOptionT
    case commandOptionS
    case legacyCommandShiftT

    static let defaultShortcut: GlobalHotkey = .optionSpace

    var displayName: String {
        switch self {
        case .optionSpace: return "Option-Space"
        case .commandOptionT: return "Command-Option-T"
        case .commandShiftY: return "Command-Shift-Y"
        case .controlOptionT: return "Control-Option-T"
        case .commandOptionS: return "Command-Option-S"
        case .legacyCommandShiftT: return "Command-Shift-T"
        }
    }

    var glyphs: String {
        switch self {
        case .optionSpace: return "⌥Space"
        case .commandOptionT: return "⌘⌥T"
        case .commandShiftY: return "⌘⇧Y"
        case .controlOptionT: return "⌃⌥T"
        case .commandOptionS: return "⌘⌥S"
        case .legacyCommandShiftT: return "⌘⇧T"
        }
    }

    var helpText: String {
        switch self {
        case .legacyCommandShiftT:
            return "Legacy shortcut. Conflicts with Chrome and Brave reopen-closed-tab."
        default:
            return "Applies immediately. If another app already owns the shortcut, choose a different one."
        }
    }

    var carbonKeyCode: UInt32 {
        switch self {
        case .optionSpace: return UInt32(kVK_Space)
        case .commandOptionT, .controlOptionT, .legacyCommandShiftT:
            return UInt32(kVK_ANSI_T)
        case .commandShiftY:
            return UInt32(kVK_ANSI_Y)
        case .commandOptionS:
            return UInt32(kVK_ANSI_S)
        }
    }

    var carbonModifiers: UInt32 {
        switch self {
        case .optionSpace:
            return UInt32(optionKey)
        case .commandOptionT:
            return UInt32(cmdKey | optionKey)
        case .commandShiftY:
            return UInt32(cmdKey | shiftKey)
        case .controlOptionT:
            return UInt32(controlKey | optionKey)
        case .commandOptionS:
            return UInt32(cmdKey | optionKey)
        case .legacyCommandShiftT:
            return UInt32(cmdKey | shiftKey)
        }
    }

    var keyEquivalent: KeyEquivalent {
        switch self {
        case .optionSpace:
            return " "
        case .commandOptionT, .controlOptionT, .legacyCommandShiftT:
            return "t"
        case .commandShiftY:
            return "y"
        case .commandOptionS:
            return "s"
        }
    }

    var eventModifiers: SwiftUI.EventModifiers {
        switch self {
        case .optionSpace:
            return [.option]
        case .commandOptionT:
            return [.command, .option]
        case .commandShiftY:
            return [.command, .shift]
        case .controlOptionT:
            return [.control, .option]
        case .commandOptionS:
            return [.command, .option]
        case .legacyCommandShiftT:
            return [.command, .shift]
        }
    }
}
