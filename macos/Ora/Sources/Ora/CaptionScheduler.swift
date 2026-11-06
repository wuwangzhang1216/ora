import AppKit

struct ScheduledCaption: Equatable, Identifiable {
    var id = UUID()
    let utteranceID: UUID
    var source: CaptionSlice
    var translation: CaptionSlice
    var isDraft: Bool
    var isCorrection = false
}

/// A text-only FIFO with rolling translation lines. It never drops completed captions to catch up with audio.
/// Tests supply a virtual monotonic clock; production uses ContinuousClock.
struct CaptionScheduler {
    private struct Utterance {
        let id: UUID
        var sourceTrack = CaptionTextTrack()
        var translationTrack = CaptionTextTrack()
        var final = false
        var lastSourcePage = ""
        var lastTranslationPage = ""
        var source: String { sourceTrack.text }
        var translation: String { translationTrack.text }
        var consumedSource: String { sourceTrack.consumed }
        var consumedTranslation: String { translationTrack.consumed }
    }

    var typography = CaptionTypography()
    // Live overlay follows the newest ready text; full transcripts live in history.
    var followsLiveSpeech = false
    private(set) var catchUpCount = 0
    private var queue: [Utterance] = []
    private var completed: Set<UUID> = []
    private(set) var current: ScheduledCaption?
    private(set) var retained: ScheduledCaption?
    private var startedAt: TimeInterval = 0
    private var protectedUntil: TimeInterval = 0
    var visible: ScheduledCaption? { current ?? retained }
    var queuedUtteranceCount: Int { max(0, queue.count - 1) }
    var isDraining: Bool { !queue.isEmpty }

    mutating func update(id: UUID, source: String, translation: String?, final: Bool, now: TimeInterval) {
        guard !completed.contains(id) else { return }
        if !queue.contains(where: { $0.id == id }) {
            queue.append(Utterance(id: id))
        }
        var index = queue.firstIndex { $0.id == id }!
        if followsLiveSpeech, index > 0, translation?.isEmpty == false {
            for older in queue.prefix(index) { completed.insert(older.id) }
            queue.removeFirst(index)
            index = 0
            current = nil
            retained = nil
            catchUpCount += 1
        }
        var item = queue[index]
        // Finalization must not rewind a live reader. Keep the monotonic
        // read boundary and update only text that has not yet been consumed.
        let oldSource = item.sourceTrack.remaining
        let oldTranslation = item.translationTrack.remaining
        if followsLiveSpeech { item.sourceTrack = CaptionTextTrack() }
        item.sourceTrack.update(source, final: final)
        if let translation {
            // Live deliveries are complete snapshots, including corrections
            // shorter than an earlier window. Read offsets cannot reject them.
            if followsLiveSpeech { item.translationTrack = CaptionTextTrack() }
            item.translationTrack.update(translation, final: final)
        }
        if followsLiveSpeech {
            let skipped = Self.prefixOutsideLiveWindow(item.translationTrack.remaining,
                font: typography.translationFont, typography: typography)
            if !skipped.isEmpty {
                item.translationTrack.consume(skipped)
                catchUpCount += 1
            }
            let sourcePrefix = Self.prefixOutsideLiveWindow(item.sourceTrack.remaining,
                font: typography.sourceFont, typography: typography)
            if !sourcePrefix.isEmpty { item.sourceTrack.consume(sourcePrefix) }
        }
        let correction = (!oldSource.isEmpty && !item.sourceTrack.remaining.hasPrefix(oldSource))
            || (!oldTranslation.isEmpty && !item.translationTrack.remaining.hasPrefix(oldTranslation))
        let growsTranslation = !oldTranslation.isEmpty && item.translationTrack.remaining.hasPrefix(oldTranslation)
            && item.translationTrack.remaining.count > oldTranslation.count
        item.final = item.final || final
        queue[index] = item
        if index == 0 {
            render(now: now, correction: correction, expand: growsTranslation)
            advance(now: now)
        } else if followsLiveSpeech {
            // Recognition is live even while the next translation is pending.
            render(now: now)
        } else if canYieldSourceTail(queue[0]) {
            // The translation was already read. Secondary original-language
            // pages must not hold the next ready translated utterance hostage.
            completed.insert(queue.removeFirst().id)
            current = nil
            render(now: now)
        }
    }

    /// Reflow only the unread page when preferences change. Read offsets stay
    /// in original text coordinates, so no text disappears at a new font size.
    mutating func reflow(_ typography: CaptionTypography, now: TimeInterval) {
        guard self.typography != typography else { return }
        self.typography = typography
        if queue.isEmpty, let retained {
            var item = Utterance(id: retained.utteranceID)
            item.sourceTrack.update(retained.source.raw, final: true)
            item.translationTrack.update(retained.translation.raw, final: true)
            item.final = true
            queue.append(item)
            completed.remove(retained.utteranceID)
        }
        current = nil
        render(now: now)
    }

    var nextDeadline: TimeInterval? {
        guard let cue = current, let item = queue.first else { return nil }
        let sourceDone = item.consumedSource.count + cue.source.raw.count >= item.source.count
        let translationDone = item.consumedTranslation.count + cue.translation.raw.count >= item.translation.count
        let hasMore = !sourceDone || !translationDone || queue.count > 1
        // Never page recognized words ahead while their translation is still
        // empty. At final/error/stop, a source-only cue can still drain.
        guard item.final || (!cue.translation.raw.isEmpty && cue.translation.sealed && hasMore) else { return nil }
        let translationTime = CaptionPaginator.readingUnits(cue.translation.raw)
        // Meeting captions prioritize the translation. A verbose source
        // must not hold a short translated cue for five seconds.
        let effort = cue.translation.raw.isEmpty
            ? (item.translation.isEmpty ? CaptionPaginator.readingUnits(cue.source.raw) : 0)
            : translationTime
        let dwell = max(1.2, min(6, effort + 0.35))
        let deadline = max(startedAt + dwell, protectedUntil)
        return deadline
    }

    mutating func advance(now: TimeInterval) {
        guard let deadline = nextDeadline, now >= deadline, let cue = current, !queue.isEmpty else { return }
        var item = queue[0]
        item.sourceTrack.consume(cue.source.raw)
        item.translationTrack.consume(cue.translation.raw)
        if !cue.source.raw.isEmpty { item.lastSourcePage = cue.source.raw }
        if !cue.translation.raw.isEmpty { item.lastTranslationPage = cue.translation.raw }
        retained = cue
        current = nil
        let done = item.consumedSource.count == item.source.count && item.consumedTranslation.count == item.translation.count
        if item.final && (done || canYieldSourceTail(item)) {
            completed.insert(item.id)
            queue.removeFirst()
        } else {
            queue[0] = item
        }
        render(now: now)
    }

    private func canYieldSourceTail(_ item: Utterance) -> Bool {
        item.final && !item.translation.isEmpty && item.translationTrack.remaining.isEmpty
            && queue.count > 1 && !queue[1].translation.isEmpty
    }

    /// Pause capture but finish reading text already received. Aborted model
    /// output stays a draft in history; presentation alone is allowed to drain.
    mutating func finishPending(now: TimeInterval) {
        for i in queue.indices { queue[i].final = true }
        render(now: now)
    }

    mutating func finish(id: UUID, now: TimeInterval) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[index].final = true
        if index == 0 { render(now: now) }
    }

    private mutating func render(now: TimeInterval, correction: Bool = false, expand: Bool = false) {
        while let first = queue.first, first.final,
              first.consumedSource == first.source, first.consumedTranslation == first.translation {
            completed.insert(first.id)
            if retained?.utteranceID == first.id { retained?.isDraft = false }
            queue.removeFirst()
            current = nil
        }
        guard let item = queue.first else { current = nil; return }
        let src = String(item.source.dropFirst(item.consumedSource.count))
        let dst = String(item.translation.dropFirst(item.consumedTranslation.count))
        guard !src.isEmpty || !dst.isEmpty else {
            // A live stream can temporarily catch up to everything received.
            // Keep its last cue on screen until more text or finalization.
            current = nil
            return
        }
        let old = current?.utteranceID == item.id ? current : nil
        func slice(_ text: String, old: CaptionSlice?, font: NSFont, pack: Bool = false, lines: Int? = nil) -> CaptionSlice {
            let fillsLines = followsLiveSpeech || pack || expand || old?.fillsAvailableLines == true
            let page = CaptionPaginator.page(text, font: font, width: typography.width,
                                             lines: lines ?? typography.lines, final: item.final, fillAvailableLines: fillsLines)
            if let old, old.sealed, !old.raw.isEmpty, text.hasPrefix(old.raw) {
                return fillsLines && page.raw.hasPrefix(old.raw) ? page : old
            }
            return page
        }
        func pairedSlice(_ text: String, held: String, old: CaptionSlice?, font: NSFont, pack: Bool = false, lines: Int? = nil) -> CaptionSlice {
            guard text.isEmpty, !held.isEmpty else { return slice(text, old: old, font: font, pack: pack, lines: lines) }
            // The two languages need not have the same number of pages. Keep
            // context from THIS utterance visible while the other continues.
            // Empty raw means it is neither consumed twice nor re-queued.
            let context = CaptionPaginator.page(held, font: font, width: typography.width,
                                                lines: lines ?? typography.lines, final: true, fillAvailableLines: true)
            return CaptionSlice(raw: "", display: context.display, sealed: true)
        }
        var source = typography.showsSource
            ? pairedSlice(src, held: item.lastSourcePage, old: old?.source, font: typography.sourceFont)
            : CaptionSlice(raw: src, display: "", sealed: item.final)
        if followsLiveSpeech, typography.showsSource, let newest = queue.last,
           newest.id != item.id, !newest.sourceTrack.remaining.isEmpty {
            let liveSource = CaptionPaginator.page(newest.sourceTrack.remaining,
                font: typography.sourceFont, width: typography.width, lines: typography.lines,
                final: false, fillAvailableLines: true)
            // raw still belongs to the current owner so advancing its reading
            // cursor cannot consume words from a future utterance.
            source = CaptionSlice(raw: source.raw, display: liveSource.display, sealed: source.sealed)
        }
        // After the first cue, fill available space instead of allocating a
        // separate minimum dwell to an orphan such as "坦诚。" when the next
        // completed sentence fits on the same page. Reading effort is unchanged.
        // Advance one fresh line at a time. The preceding line stays visible
        // as context, so introducing new words does not clear the whole card.
        var translation = pairedSlice(dst, held: item.lastTranslationPage, old: old?.translation,
                                      font: typography.translationFont, pack: followsLiveSpeech || retained != nil,
                                      lines: followsLiveSpeech ? typography.lines : 1)
        if !followsLiveSpeech, typography.lines > 1, !translation.raw.isEmpty, let previous = retained,
           !previous.translation.raw.isEmpty {
            let priorLine = CaptionPaginator.page(previous.translation.raw,
                font: typography.translationFont, width: typography.width, lines: 1,
                final: true, fillAvailableLines: true).display
            translation = CaptionSlice(raw: translation.raw,
                display: priorLine + "\n" + CaptionPaginator.page(translation.raw,
                    font: typography.translationFont, width: typography.width, lines: 1,
                    final: true, fillAvailableLines: true).display, sealed: translation.sealed,
                fillsAvailableLines: translation.fillsAvailableLines)
        }
        if followsLiveSpeech, translation.display.isEmpty, let retained {
            translation = CaptionSlice(raw: "", display: retained.translation.display, sealed: true)
        }
        // Reading the unchanged prefix counts. Give changed words their own
        // allowance instead of restarting the entire page on every revision.
        let translatedPageChanged = old?.translation.display != translation.display
        let sourceOnlyChanged = translation.display.isEmpty && old?.source.display != source.display
        if old == nil || (old?.translation.raw.isEmpty == true && !translation.raw.isEmpty) {
            startedAt = now
            protectedUntil = now
        } else if translatedPageChanged || sourceOnlyChanged {
            let before = translation.display.isEmpty ? old!.source.raw : old!.translation.raw
            let after = translation.display.isEmpty ? source.raw : translation.raw
            let changed = Self.changedWords(from: before, to: after)
            let allowance = now + CaptionPaginator.readingUnits(changed) + 0.35
            protectedUntil = after.hasPrefix(before) ? max(protectedUntil, allowance) : allowance
        }
        current = ScheduledCaption(id: old?.id ?? UUID(), utteranceID: item.id, source: source,
                                   translation: translation, isDraft: !item.final,
                                   isCorrection: correction || old?.isCorrection == true)
    }

    private static func prefixOutsideLiveWindow(_ text: String, font: NSFont,
                                                typography: CaptionTypography) -> String {
        var tail = text
        while !tail.isEmpty {
            let visible = CaptionPaginator.page(tail, font: font, width: typography.width,
                lines: typography.lines, final: true, fillAvailableLines: true)
            if visible.raw.count == tail.count { break }
            let line = CaptionPaginator.page(tail, font: font, width: typography.width,
                lines: 1, final: true, fillAvailableLines: true)
            guard !line.raw.isEmpty else { break }
            tail.removeFirst(line.raw.count)
        }
        return String(text.prefix(text.count - tail.count))
    }

    private static func changedWords(from before: String, to after: String) -> String {
        let a = Array(before), b = Array(after)
        let prefix = zip(a, b).prefix(while: { $0 == $1 }).count
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix,
              a[a.count - suffix - 1] == b[b.count - suffix - 1] { suffix += 1 }
        return String(b[prefix..<(b.count - suffix)])
    }
}
