import Foundation

struct LiveTranslationPlan: Equatable {
    let source: String
    let text: String
    let preceding: TranslationExchange?
    var provisional = false
}

/// Confirm source words across recognition snapshots. Completed units become
/// reusable checkpoints; the unfinished tail can be translated provisionally
/// without locking its wording or adding it to final translation context.
struct StableTranslation {
    private var previousSource = ""
    private(set) var source = ""
    private(set) var published = ""
    private(set) var displayed = ""
    private var checkpoints: [TranslationExchange] = []
    private var previewSource = ""

    func translation(for confirmedSource: String) -> String? {
        checkpoints.last(where: {
            RecognitionTextAgreement.equivalent($0.source, confirmedSource, ignoresSegmentation: false)
        })?.translation
    }

    mutating func plan(for candidate: String, confirmed: Bool = false, preview: Bool = false) -> LiveTranslationPlan? {
        // An append-only RNN-T recognizer has already committed these tokens.
        // Requiring a second ASR snapshot would add another update interval.
        let agreement = confirmed ? candidate : RecognitionTextAgreement.previewPrefix(previousSource, candidate)
        let boundaries = confirmed ? candidate : RecognitionTextAgreement.commonPrefix(previousSource, candidate, ignoresSegmentation: false)
        previousSource = candidate
        let stable = Self.readablePrefix(boundaries)
        // Never roll a longer committed word sequence back to an earlier
        // clause because ASR has restyled its punctuation/capitalization.
        let olderPrefix = RecognitionTextAgreement.remainder(after: stable, in: source)
        if !stable.isEmpty, !RecognitionTextAgreement.equivalent(stable, source, ignoresSegmentation: false),
           olderPrefix == nil || olderPrefix?.isEmpty == true {
            // A changed sentence boundary needs full-sentence refinement.
            // Treating it as an append can translate "baskets of flowers" in
            // isolation and turn a fluent sentence into disconnected fragments.
            let remainder = source.isEmpty ? nil : RecognitionTextAgreement.remainder(after: source, in: stable, ignoresSegmentation: false)
            let appending = remainder != nil
            let text = remainder ?? stable
            // A comma clause is readable but its meaning may depend on what
            // follows (e.g. "the English" may mean people, not a language).
            // Show it provisionally, then refine the full sentence. Only an
            // agreed sentence ending can become a permanent checkpoint.
            let provisional = !SentenceBoundary.isComplete(stable)
            let coveredByPreview = RecognitionTextAgreement.alignedPrefix(stable, in: previewSource) != nil
            if !provisional || (!coveredByPreview && shouldPreview(stable)) {
                return LiveTranslationPlan(source: stable, text: text,
                    preceding: appending ? TranslationExchange(source: source, translation: published) : nil,
                    provisional: provisional)
            }
        }
        // Punctuation is not required for a preview. Volatile recognizers still
        // need word agreement above. Mask the newest English word and keep
        // the whole unfinished tail available for later revision.
        guard confirmed || preview else { return nil }
        let remainder: String
        let preceding: TranslationExchange?
        if source.isEmpty {
            remainder = agreement
            preceding = nil
        } else if let suffix = RecognitionTextAgreement.remainder(after: source, in: agreement, ignoresSegmentation: false) {
            remainder = suffix
            preceding = TranslationExchange(source: source, translation: published)
        } else {
            // A corrected period/comma or negation can invalidate a checkpoint.
            // Preview the agreed full sentence instead of waiting for another
            // punctuation mark or translating a detached remainder.
            guard RecognitionTextAgreement.remainder(after: agreement, in: source, ignoresSegmentation: false) == nil else { return nil }
            remainder = agreement
            preceding = nil
        }
        let tail: String
        if Self.cjkCount(remainder) >= 12 {
            tail = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            guard let lastSpace = remainder.lastIndex(where: \.isWhitespace) else { return nil }
            tail = String(remainder[..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard tail.split(whereSeparator: \.isWhitespace).count >= 8 || Self.cjkCount(tail) >= 12,
              SentenceBoundary.isComplete(tail + ".", allowDependentClause: true) else { return nil }
        let prefix = preceding == nil ? tail : source + " " + tail
        guard shouldPreview(prefix) else { return nil }
        return LiveTranslationPlan(source: prefix, text: tail,
            preceding: preceding, provisional: true)
    }

    private func shouldPreview(_ candidate: String) -> Bool {
        guard !previewSource.isEmpty else { return true }
        // Never request an older comma clause after a longer tail was shown.
        if RecognitionTextAgreement.remainder(after: candidate, in: previewSource, ignoresSegmentation: false) != nil { return false }
        if let growth = RecognitionTextAgreement.remainder(after: previewSource, in: candidate, ignoresSegmentation: false),
           growth.split(whereSeparator: \.isWhitespace).count < 2, Self.cjkCount(growth) < 4 { return false }
        return true // genuine corrections need not grow the source
    }

    private static func cjkCount(_ text: String) -> Int {
        text.unicodeScalars.filter { (0x3400...0x9FFF).contains($0.value) }.count
    }

    /// Compose a streamed draft without modifying checkpoints or context.
    func display(_ plan: LiveTranslationPlan, translation: String) -> String {
        TranslationStreamDisplay.join(prefix: plan.preceding?.translation ?? "", text: translation)
    }

    /// A long spoken sentence can contain several readable subtitle blocks.
    /// A confirmed comma-delimited clause need not wait for its final period.
    private static func readablePrefix(_ text: String) -> String {
        let chars = Array(text)
        var end = SentenceBoundary.completePrefix(text).count
        var start = end
        for i in end..<chars.count {
            let c = chars[i]
            if ".!?。！？".contains(c), c != "." || SentenceBoundary.isSentencePeriod(chars, at: i) { break }
            guard "，,；;：:".contains(c) else { continue }
            if i > 0, i + 1 < chars.count, chars[i - 1].isNumber, chars[i + 1].isNumber { continue }
            let clause = String(chars[start..<i]).trimmingCharacters(in: .whitespacesAndNewlines)
            let words = clause.split(whereSeparator: \.isWhitespace).count
            let chinese = clause.unicodeScalars.filter { (0x3400...0x9FFF).contains($0.value) }.count
            guard words >= 6 || chinese >= 12,
                  SentenceBoundary.isComplete(clause + ".", allowDependentClause: true) else { continue }
            end = i + 1
            start = end
        }
        return String(chars.prefix(end)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func commit(_ plan: LiveTranslationPlan, translation: String) -> String {
        let translated = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        if plan.provisional {
            previewSource = plan.source
            displayed = display(plan, translation: translated)
            return displayed
        }
        previewSource = ""
        if plan.preceding != nil, !published.isEmpty {
            let separator = translated.first?.isASCII == true || published.last?.isASCII == true ? " " : ""
            published += separator + translated
        } else {
            published = translated
            checkpoints.removeAll()
        }
        source = plan.source
        checkpoints.append(TranslationExchange(source: source, translation: published))
        if checkpoints.count > 128 { checkpoints.removeFirst(checkpoints.count - 128) }
        displayed = published
        return published
    }
}

/// Coalesce actual generated tokens into readable screen updates. No timer or
/// artificial typing delay: a short response is flushed immediately at EOS.
struct TranslationStreamDisplay {
    private(set) var text = ""
    private var emitted = ""
    private var lastEmissionMS: Double?
    private let previousText: String
    private let prefix: String

    init(prefix: String = "", previousText: String = "") {
        self.prefix = prefix
        self.previousText = previousText.trimmingCharacters(in: CharacterSet(charactersIn: ".。,…，；;：: \n"))
    }

    static func join(prefix: String, text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return trimmed }
        guard !trimmed.isEmpty else { return prefix }
        let separator = trimmed.first?.isASCII == true || prefix.last?.isASCII == true ? " " : ""
        return prefix + separator + trimmed
    }

    mutating func append(_ chunk: String, elapsedMS: Double) -> String? {
        text += chunk
        let cjk = text.unicodeScalars.filter { (0x3400...0x9FFF).contains($0.value) }.count
        var readable = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cjk < 8 {
            // An English token can end in the middle of a word.
            if let last = text.last, last.isLetter || last.isNumber {
                guard let boundary = text.lastIndex(where: \.isWhitespace) else { return nil }
                readable = String(text[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard readable.split(whereSeparator: \.isWhitespace).count >= 3 else { return nil }
        }
        let visible = Self.join(prefix: prefix, text: readable)
        // A new request starts from the beginning. Do not repaint its short
        // opening over a fuller response, but allow revised wording once the
        // generated text has caught up. Requiring an identical prefix would
        // hide useful revisions until EOS and make long translations stall.
        if !previousText.isEmpty {
            guard visible.count >= previousText.count else { return nil }
        }
        guard visible != emitted,
              lastEmissionMS == nil || elapsedMS - lastEmissionMS! >= 80 else { return nil }
        emitted = visible
        lastEmissionMS = elapsedMS
        return visible
    }
}
