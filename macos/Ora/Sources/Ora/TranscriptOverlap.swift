import Foundation

/// Only used for audio deliberately carried across a confirmed sentence cut.
/// Ordinary repeated speech never enters this deduplication path.
enum TranscriptOverlap {
    private struct Word {
        let value: String
        let end: String.Index
        let cjk: Bool
    }

    static func strip(_ text: String, previous: String?) -> String {
        guard let previous, !previous.isEmpty else { return text }
        let before = words(previous), after = words(text)
        let limit = min(16, before.count, after.count)
        guard limit > 0 else { return text }
        for count in stride(from: limit, through: 1, by: -1) {
            if count == 1, after[0].cjk { continue }
            if before.suffix(count).map(\.value) == after.prefix(count).map(\.value) {
                return String(text[after[count - 1].end...].drop(while: {
                    $0.isWhitespace || $0.isPunctuation
                }))
            }
        }
        return text
    }

    private static func words(_ text: String) -> [Word] {
        var result: [Word] = [], word = ""
        var end = text.startIndex
        func flush() {
            if !word.isEmpty { result.append(Word(value: word.lowercased(), end: end, cjk: false)); word = "" }
        }
        for index in text.indices {
            let c = text[index], next = text.index(after: index)
            let cjk = c.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
            if cjk {
                flush(); result.append(Word(value: String(c), end: next, cjk: true))
            } else if c.isLetter || c.isNumber || c == "'" || c == "’" {
                word.append(c); end = next
            } else { flush() }
        }
        flush()
        return result
    }
}
