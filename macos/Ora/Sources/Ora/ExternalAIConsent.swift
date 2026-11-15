import AppKit
import Foundation

/// Snapshot the services actually loaded by the engine, so editing a URL in
/// Preferences cannot make the disclosure name a different recipient.
struct ExternalAIUsage: Equatable, Sendable {
    let server: String
    let sendsAudio: Bool
    let sendsText: Bool

    var disclosure: String {
        let data = sendsAudio
            ? (sendsText ? "Audio segments, recognized speech, and recent translation context" : "Audio segments")
            : "Recognized speech and recent translation context"
        return "\(data) will be sent to \(server) and any AI providers it uses. This may include other people's speech captured from your selected audio source. The server's privacy and retention policies apply.\n\nLocal recognition and MLX Swift translation work without sharing speech with an external service. Cancel and choose local backends in Preferences to keep processing on this Mac."
    }

    static func services(recognition: RecognitionBackendKind, translation: LLMBackendKind,
                         realRouterURL: String, rapidMLXURL: String) -> [Self] {
        var result: [Self] = []
        if recognition == .realRouter || translation == .realRouter {
            result.append(Self(server: realRouterURL, sendsAudio: recognition == .realRouter,
                               sendsText: translation == .realRouter))
        }
        if translation == .rapidMLX {
            result.append(Self(server: rapidMLXURL, sendsAudio: false, sendsText: true))
        }
        return result
    }

    /// Consent is per listening session; stopping revokes it automatically.
    /// No persistent approval or extra state machine is needed.
    @MainActor static func confirm(_ services: [Self], testing: Bool = false) -> Bool {
        guard !services.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = testing ? "Send a test sample to the AI service?" : "Share speech with an AI service?"
        alert.informativeText = testing
            ? "This test sends a synthetic English sample, not microphone audio or your history, to:\n\n" + services.map(\.server).joined(separator: "\n") + "\n\nThe servers and their AI providers process the sample under their own privacy policies."
            : services.map(\.disclosure).joined(separator: "\n\n")
        alert.addButton(withTitle: testing ? "Send Test Sample" : "Allow for This Session")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

enum OraLinks {
    static let privacy = URL(string: "https://main.d1cdtuylr567og.amplifyapp.com/privacy.html")!
    static let support = URL(string: "https://main.d1cdtuylr567og.amplifyapp.com/support.html")!
}
