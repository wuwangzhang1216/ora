import AppKit
import CoreText

/// The same fonts are used for measurement and rendering. No character-count
/// approximation: wide CJK, proportional Latin, emoji and user font sizes fit.
struct CaptionTypography: Equatable {
    var width: CGFloat = 560
    var sourceSize: CGFloat = 12
    var translationSize: CGFloat = 22
    var showsSource = true
    var lines = 2

    var sourceFont: NSFont { .systemFont(ofSize: sourceSize) }
    var translationFont: NSFont { .systemFont(ofSize: translationSize, weight: .medium) }
}

struct CaptionSlice: Equatable {
    /// Exact original substring, including inter-page spaces, for consumption.
    let raw: String
    /// Explicit line breaks using the font metrics used by SwiftUI. A scheduler
    /// may hold a previously read page here with empty raw while its paired
    /// language continues; paginator output itself is always a fresh slice.
    let display: String
    let sealed: Bool
    var fillsAvailableLines = false
    static let empty = CaptionSlice(raw: "", display: "", sealed: false)
}

enum CaptionPaginator {
    static let cjkCharactersPerSecond: Double = 8
    private static let endings = Set<Character>("。！？!?；;\n")
    private static let clauses = Set<Character>("，,：:、")
    private static let closers = Set<Character>("\"'”’」』】）》)]}")

    static func page(_ text: String, font: NSFont, width: CGFloat, lines: Int = 2, final: Bool,
                     fillAvailableLines: Bool = false) -> CaptionSlice {
        guard !text.isEmpty else { return .empty }
        let chars = Array(text)
        var fit = fittedCount(text, font: font, width: width, lines: lines)
        // A small source font can fit an unreadably long paragraph into two
        // lines. Bound reading effort as well as physical line width.
        for end in 1...fit where readingUnits(String(chars.prefix(end))) > 5 {
            fit = max(1, end - 1)
            if fit < chars.count, chars[fit].isASCII, chars[fit].isLetter {
                let wordStart = chars[..<fit].lastIndex(where: { $0.isWhitespace }).map { $0 + 1 }
                if let wordStart, wordStart > 0 { fit = wordStart }
            }
            break
        }
        var sentence: Int?
        var clause: Int?
        for i in 0..<min(fit, chars.count) {
            let c = chars[i]
            var end = i + 1
            while end < chars.count && (closers.contains(chars[end]) || endings.contains(chars[end]) || chars[end] == ".") {
                end += 1
            }
            // Never push closing punctuation off the physical page.
            guard end <= fit else { continue }
            if endings.contains(c) || (c == "." && isSentencePeriod(chars, at: i)) {
                if fillAvailableLines || sentence == nil { sentence = end }
            } else if clauses.contains(c), readingUnits(String(chars[0...i])) >= 2.0 {
                if fillAvailableLines || clause == nil { clause = end }
            }
        }
        // A displayed continuation can occupy the remaining line even when
        // the next full translated sentence needs another page afterwards.
        var end = fillAvailableLines ? fit : min(sentence ?? fit, clause ?? fit)
        // Consume spacing with the preceding page so the next starts on text.
        while end < chars.count && chars[end].isWhitespace { end += 1 }
        var raw = String(chars.prefix(end))
        var rendered = wrappedLines(raw.trimmingCharacters(in: .whitespacesAndNewlines), font: font, width: width)
        // Shaping an isolated prefix can change kerning/line breaks compared
        // with the full paragraph (notably a long unbroken Latin token).
        // Move excess graphemes to the NEXT cue; never clip them in the view.
        while rendered.count > max(1, lines) && end > 1 {
            end -= 1
            raw = String(chars.prefix(end))
            rendered = wrappedLines(raw.trimmingCharacters(in: .whitespacesAndNewlines), font: font, width: width)
        }
        return CaptionSlice(raw: raw, display: rendered.joined(separator: "\n"),
                            sealed: final || sentence != nil || clause != nil || end < chars.count,
                            fillsAvailableLines: fillAvailableLines)
    }

    /// Seconds of reading effort: ~3 Latin words/s or ~8 CJK characters/s.
    /// This is local presentation pacing, unrelated to ASR endpointing.
    static func readingUnits(_ text: String) -> Double {
        var words = 0
        var wide = 0
        var inWord = false
        var wordCharacters = 0
        for c in text {
            if isWide(c) {
                wide += 1
                inWord = false
            } else if c.isLetter || c.isNumber {
                wordCharacters += 1
                if !inWord { words += 1 }
                inWord = true
            } else {
                inWord = false
            }
        }
        return max(Double(words) / 3, Double(wordCharacters) / 18) + Double(wide) / cjkCharactersPerSecond
    }

    private static func isWide(_ c: Character) -> Bool {
        c.unicodeScalars.contains {
            (0x2E80...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value)
                || (0xF900...0xFAFF).contains($0.value) || $0.properties.isEmojiPresentation
        }
    }

    private static func isSentencePeriod(_ chars: [Character], at i: Int) -> Bool {
        SentenceBoundary.isSentencePeriod(chars, at: i)
    }

    private static func typesetter(_ text: String, font: NSFont) -> CTTypesetter {
        CTTypesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
    }

    private static func fittedCount(_ text: String, font: NSFont, width: CGFloat, lines: Int) -> Int {
        let setter = typesetter(text, font: font)
        let length = text.utf16.count
        var offset = 0
        for _ in 0..<max(1, lines) where offset < length {
            let count = CTTypesetterSuggestLineBreak(setter, offset, Double(max(1, width - 2)))
            if count == 0 { break }
            offset += count
        }
        // Iterate by extended grapheme clusters to never split a surrogate,
        // combining mark, flag, or family emoji at a page boundary.
        var used = 0
        var count = 0
        for c in text {
            let size = String(c).utf16.count
            if used + size > offset { break }
            used += size
            count += 1
        }
        return max(1, count)
    }

    static func wrappedLines(_ text: String, font: NSFont, width: CGFloat) -> [String] {
        var remaining = text
        var result: [String] = []
        while !remaining.isEmpty {
            let count = fittedCount(remaining, font: font, width: width, lines: 1)
            result.append(String(remaining.prefix(count)).trimmingCharacters(in: .whitespacesAndNewlines))
            remaining = String(remaining.dropFirst(count))
        }
        return result
    }
}
