import Foundation
import Observation

/// UserDefaults-backed preferences singleton. Observable so SwiftUI views can
/// bind directly, and every setter writes through to disk so changes persist
/// across launches. The engine reads from here at prepare-time.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    // MARK: - Keys

    private enum Key {
        static let targetLanguage = "targetLanguage"
        static let quality = "quality"
        static let asrLanguage = "asrLanguage"
        static let vadThreshold = "vadThreshold"
        static let speechEndMs = "speechEndMs"
        static let captionOriginX = "captionOriginX"
        static let captionOriginY = "captionOriginY"
        static let audioSource = "audioSource"
        static let captionFontSize = "captionFontSize"
        static let captionSourceFontSize = "captionSourceFontSize"
        static let captionDisplayMode = "captionDisplayMode"
        static let vadPreset = "vadPreset"
        static let startStopHotkey = "startStopHotkey"
        static let llmBackend = "llmBackend"
        static let rapidMLXURL = "rapidMLXURL"
        static let rapidMLXModel = "rapidMLXModel"
    }

    static let captionFontSizeRange: ClosedRange<Double> = 14...40
    static let defaultCaptionFontSize: Double = 22
    static let captionSourceFontSizeRange: ClosedRange<Double> = 9...28
    static let defaultCaptionSourceFontSize: Double = 12

    // MARK: - Stored values (with write-through)

    var targetLanguage: String {
        didSet { UserDefaults.standard.set(targetLanguage, forKey: Key.targetLanguage) }
    }

    var quality: TranslatorQuality {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: Key.quality) }
    }

    /// nil = auto-detect
    var asrLanguage: String? {
        didSet {
            if let asrLanguage {
                UserDefaults.standard.set(asrLanguage, forKey: Key.asrLanguage)
            } else {
                UserDefaults.standard.removeObject(forKey: Key.asrLanguage)
            }
        }
    }

    var vadThreshold: Double {
        didSet { UserDefaults.standard.set(vadThreshold, forKey: Key.vadThreshold) }
    }

    var speechEndMs: Int {
        didSet { UserDefaults.standard.set(speechEndMs, forKey: Key.speechEndMs) }
    }

    var vadPreset: VADPreset {
        didSet { UserDefaults.standard.set(vadPreset.rawValue, forKey: Key.vadPreset) }
    }

    var audioSource: AudioSourceKind {
        didSet { UserDefaults.standard.set(audioSource.rawValue, forKey: Key.audioSource) }
    }

    var captionFontSize: Double {
        didSet { UserDefaults.standard.set(captionFontSize, forKey: Key.captionFontSize) }
    }

    var captionSourceFontSize: Double {
        didSet { UserDefaults.standard.set(captionSourceFontSize, forKey: Key.captionSourceFontSize) }
    }

    var captionDisplayMode: CaptionDisplayMode {
        didSet { UserDefaults.standard.set(captionDisplayMode.rawValue, forKey: Key.captionDisplayMode) }
    }

    var startStopHotkey: GlobalHotkey {
        didSet { UserDefaults.standard.set(startStopHotkey.rawValue, forKey: Key.startStopHotkey) }
    }

    var llmBackend: LLMBackendKind {
        didSet { UserDefaults.standard.set(llmBackend.rawValue, forKey: Key.llmBackend) }
    }

    var rapidMLXURL: String {
        didSet { UserDefaults.standard.set(rapidMLXURL, forKey: Key.rapidMLXURL) }
    }

    var rapidMLXModel: String {
        didSet { UserDefaults.standard.set(rapidMLXModel, forKey: Key.rapidMLXModel) }
    }

    /// Remembered caption window origin, or nil if never saved.
    var captionWindowOrigin: CGPoint? {
        didSet {
            if let p = captionWindowOrigin {
                UserDefaults.standard.set(Double(p.x), forKey: Key.captionOriginX)
                UserDefaults.standard.set(Double(p.y), forKey: Key.captionOriginY)
            }
        }
    }

    // MARK: - Init

    private init() {
        let d = UserDefaults.standard
        targetLanguage = d.string(forKey: Key.targetLanguage) ?? "English"
        let qualityRaw = d.string(forKey: Key.quality) ?? TranslatorQuality.standard.rawValue
        quality = TranslatorQuality(rawValue: qualityRaw) ?? .standard
        asrLanguage = d.string(forKey: Key.asrLanguage) ?? "zh"
        let vt = d.object(forKey: Key.vadThreshold) as? Double
        vadThreshold = vt ?? Double(Config.vadThreshold)
        let em = d.object(forKey: Key.speechEndMs) as? Int
        speechEndMs = em ?? Config.speechEndMs
        let presetRaw = d.string(forKey: Key.vadPreset) ?? VADPreset.meeting.rawValue
        vadPreset = VADPreset(rawValue: presetRaw) ?? .meeting
        let asRaw = d.string(forKey: Key.audioSource) ?? AudioSourceKind.microphone.rawValue
        audioSource = AudioSourceKind(rawValue: asRaw) ?? .microphone
        let cfs = d.object(forKey: Key.captionFontSize) as? Double
        let resolvedCfs = cfs ?? Self.defaultCaptionFontSize
        captionFontSize = min(
            max(resolvedCfs, Self.captionFontSizeRange.lowerBound),
            Self.captionFontSizeRange.upperBound
        )
        let csfs = d.object(forKey: Key.captionSourceFontSize) as? Double
        let resolvedCsfs = csfs ?? Self.defaultCaptionSourceFontSize
        captionSourceFontSize = min(
            max(resolvedCsfs, Self.captionSourceFontSizeRange.lowerBound),
            Self.captionSourceFontSizeRange.upperBound
        )
        let displayRaw = d.string(forKey: Key.captionDisplayMode) ?? CaptionDisplayMode.bilingual.rawValue
        captionDisplayMode = CaptionDisplayMode(rawValue: displayRaw) ?? .bilingual
        let hotkeyRaw = d.string(forKey: Key.startStopHotkey) ?? GlobalHotkey.defaultShortcut.rawValue
        startStopHotkey = GlobalHotkey(rawValue: hotkeyRaw) ?? .defaultShortcut
        let backendRaw = d.string(forKey: Key.llmBackend) ?? LLMBackendKind.mlxSwift.rawValue
        llmBackend = LLMBackendKind(rawValue: backendRaw) ?? .mlxSwift
        rapidMLXURL = d.string(forKey: Key.rapidMLXURL) ?? Config.rapidMLXURL
        rapidMLXModel = d.string(forKey: Key.rapidMLXModel) ?? Config.rapidMLXModel

        if d.object(forKey: Key.captionOriginX) != nil {
            let x = d.double(forKey: Key.captionOriginX)
            let y = d.double(forKey: Key.captionOriginY)
            captionWindowOrigin = CGPoint(x: x, y: y)
        } else {
            captionWindowOrigin = nil
        }
    }

    func applyVADPreset(_ preset: VADPreset) {
        vadPreset = preset
        guard let settings = preset.settings else { return }
        vadThreshold = settings.threshold
        speechEndMs = settings.speechEndMs
    }

    func markCustomVADPreset() {
        vadPreset = .custom
    }
}
