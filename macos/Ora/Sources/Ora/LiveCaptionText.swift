import Foundation

/// Agreement between consecutive ASR snapshots is presented at full contrast;
/// the revisable suffix is dimmed. Agreement is recomputed, not permanently
/// locked: the recognizer can still correct names and incomplete words.
struct LiveSourceText {
    private(set) var text = ""
    private(set) var stablePrefix = ""
    var tentativeSuffix: String { String(text.dropFirst(stablePrefix.count)) }

    mutating func update(_ candidate: String) {
        var common = String(zip(text, candidate).prefix { $0 == $1 }.map(\.0))
        let next = candidate.dropFirst(common.count).first
        if let last = common.last, let next,
           Self.isLatinWord(last) && Self.isLatinWord(next) {
            while let last = common.last, Self.isLatinWord(last) { common.removeLast() }
        }
        stablePrefix = common
        text = candidate
    }

    mutating func commit(_ candidate: String) {
        text = candidate
        stablePrefix = candidate
    }

    private static func isLatinWord(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "'" || c == "’")
    }
}
