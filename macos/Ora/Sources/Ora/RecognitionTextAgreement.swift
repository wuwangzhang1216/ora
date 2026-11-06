import Foundation

/// Match spoken words across ASR's case/spacing/segmentation revisions while
/// retaining indices into the latest original text. Numbers, negation,
/// apostrophes, currency/signs and question/exclamation marks remain evidence;
/// an acronym such as US is not equated with the pronoun us.
enum RecognitionTextAgreement {
    private struct Token {
        let key: String
        let start: String.Index
    }

    static func commonPrefix(_ previous: String, _ current: String, ignoresSegmentation: Bool = true) -> String {
        let a = tokens(previous, ignoresSegmentation: ignoresSegmentation), b = tokens(current, ignoresSegmentation: ignoresSegmentation)
        let count = zip(a, b).prefix { $0.key == $1.key }.count
        guard count > 0 else { return "" }
        let end = count < b.count ? b[count].start : current.endIndex
        return String(current[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An earlier ASR revision ("two thirty" → "2:30") must not hide a
    /// later, already agreed endpoint. Require a unique eight-token anchor
    /// near its previous position; ambiguous or weak matches stay pending.
    static func alignedPrefix(_ previous: String, in current: String) -> String? {
        guard !previous.isEmpty else { return nil }
        if remainder(after: previous, in: current) != nil { return commonPrefix(previous, current) }
        let a = tokens(previous, ignoresSegmentation: true), b = tokens(current, ignoresSegmentation: true)
        let size = 8
        guard a.count >= size, b.count >= size else { return nil }
        let anchor = a.suffix(size).map(\.key)
        let matches = (size...b.count).filter { end in
            b[(end-size)..<end].map(\.key) == anchor
        }
        guard matches.count == 1, let end = matches.first, abs(end-a.count) <= size else { return nil }
        let index = end < b.count ? b[end].start : current.endIndex
        return String(current[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func previewPrefix(_ previous: String, _ current: String) -> String {
        var result = commonPrefix(previous, current)
        let prior = tokens(previous, ignoresSegmentation: true)
        var candidates = [previous]
        if let last = prior.last { candidates.append(String(previous[..<last.start])) }
        for candidate in candidates {
            if let aligned = alignedPrefix(candidate, in: current), aligned.count > result.count { result = aligned }
        }
        return result
    }

    static func remainder(after prefix: String, in text: String, ignoresSegmentation: Bool = true) -> String? {
        let a = tokens(prefix, ignoresSegmentation: ignoresSegmentation), b = tokens(text, ignoresSegmentation: ignoresSegmentation)
        guard !a.isEmpty, a.count <= b.count,
              zip(a, b).allSatisfy({ $0.key == $1.key }) else { return nil }
        guard a.count < b.count else { return "" }
        return String(text[b[a.count].start...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func equivalent(_ a: String, _ b: String, ignoresSegmentation: Bool = true) -> Bool {
        tokens(a, ignoresSegmentation: ignoresSegmentation).map(\.key) == tokens(b, ignoresSegmentation: ignoresSegmentation).map(\.key)
    }

    private static func tokens(_ text: String, ignoresSegmentation: Bool) -> [Token] {
        let chars = Array(text), indices = Array(text.indices)
        var result: [Token] = []
        var i = 0
        func cjk(_ c: Character) -> Bool {
            c.unicodeScalars.contains { (0x2E80...0x9FFF).contains($0.value)
                || (0xAC00...0xD7AF).contains($0.value) || (0x20000...0x3134F).contains($0.value) }
        }
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            let numericSeparator = i > 0 && i + 1 < chars.count && chars[i - 1].isNumber && chars[i + 1].isNumber
            if ignoresSegmentation, ".,;:。，；：".contains(c), !numericSeparator { i += 1; continue }
            let start = i
            if (c.isLetter || c.isNumber) && !cjk(c) {
                i += 1
                while i < chars.count {
                    let next = chars[i]
                    if (next.isLetter || next.isNumber) && !cjk(next) { i += 1; continue }
                    if "'’".contains(next), i + 1 < chars.count,
                       chars[i - 1].isLetter, chars[i + 1].isLetter { i += 1; continue }
                    break
                }
            } else { i += 1 }
            let word = String(chars[start..<i]).replacingOccurrences(of: "’", with: "'")
            let acronym = word.count >= 2 && word.allSatisfy(\.isUppercase)
            result.append(Token(key: acronym ? word : word.lowercased(), start: indices[start]))
        }
        return result
    }
}
