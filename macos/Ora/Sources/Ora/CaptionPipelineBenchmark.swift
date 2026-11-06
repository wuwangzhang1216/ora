import AVFoundation
import Foundation

/// Opt-in recorded/synthetic audio replay through the actual app engine and caption
/// clock. Uses temporary history and never starts microphone/system capture.
enum CaptionPipelineBenchmark {
    struct SourceUpdate: Encodable {
        let ms: Double
        let text: String
    }

    struct CueUpdate: Encodable {
        let ms: Double
        let cueID: UUID
        let utteranceID: UUID
        let source: String
        let translation: String
        let draft: Bool
        let correction: Bool
    }

    struct Segment: Encodable {
        let source: String
        let translation: String
        let finishedMS: Double
    }

    struct Delivery: Encodable {
        let ms: Double
        let utteranceID: UUID
        let source: String
        let translation: String
        let final: Bool
        let hasTranslation: Bool
    }

    struct Row: Encodable {
        let kind = "pipeline"
        let fixture: String
        let reference: String
        let source: String
        let translation: String
        let segments: Int
        let firstSourceMS: Double?
        let firstCaptionMS: Double?
        let completeMS: Double
        let minimumReadingRatio: Double?
        let maximumCaptionQueue: Int
        let droppedSegments: Int
        let sourceUpdates: [SourceUpdate]
        let cueUpdates: [CueUpdate]
        let deliveries: [Delivery]
        let segmentResults: [Segment]
        let audioSeconds: Double
        let inferenceFinishedMS: Double?
        let inputFinished: Bool
        let captionsDrained: Bool
        let readingViolations: Int
        let liveCatchUps: Int
        let drainBudgetSeconds: Double
        let error: String?
        let timingEvents: [PipelineTiming.Event]
    }

    @MainActor
    static func measure(_ fixture: APILocalBenchmark.Fixture, asr: any SpeechRecognitionBackend,
                        translator: any TranslationBackend, vad: VADSegmenter) async throws -> Row {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: fixture.audioPath))
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw APILocalBenchmark.BenchmarkError.configuration("Fixtures must be 16 kHz mono audio.")
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            throw APILocalBenchmark.BenchmarkError.configuration("Cannot decode fixture audio.")
        }
        var audio = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let duration = Double(audio.count) / 16_000
        let drainBudget = max(10, min(180, fixture.drainBudgetSeconds ?? 45))
        let tailSeconds = max(0, min(5, fixture.tailSilenceSeconds ?? 2))
        audio += [Float](repeating: 0, count: Int(Double(Config.sampleRate) * tailSeconds))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ora-caption-benchmark-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = TranscriptHistory(directory: directory)
        let begin = ContinuousClock.now
        let timing = PipelineTiming(epoch: begin)
        let engine = TranslatorEngine(history: history, recognizer: asr, translator: translator,
                                      segmenter: vad, targetLanguage: fixture.targetLanguage, timing: timing)
        var deliveries: [Delivery] = []
        engine.captions.onDelivery = { id, source, translation, final in
            timing.note("caption_delivery", id: id, text: translation,
                        reason: final ? "final" : translation == nil ? "source_only" : "partial")
            deliveries.append(Delivery(ms: seconds(begin.duration(to: .now)) * 1000,
                                      utteranceID: id, source: source, translation: translation ?? "", final: final,
                                      hasTranslation: translation != nil))
        }
        await engine.start(sourceOverride: BenchmarkPacedAudio(audio: audio, timing: timing))
        let progress = ReplayProgress()
        let completion = Task {
            await engine.waitForInputCompletion()
            progress.finishedMS = seconds(begin.duration(to: .now)) * 1000
        }
        var firstSource: Double?, firstCaption: Double?, minimumRatio: Double?
        var previous: ScheduledCaption?, shownAt = 0.0, maximumQueue = 0
        var timedOut = true
        var sourceUpdates: [SourceUpdate] = []
        var cueUpdates: [CueUpdate] = []
        var segmentResults: [Segment] = []
        var readingViolations = 0
        while begin.duration(to: .now) < .seconds(duration + drainBudget) {
            let elapsed = seconds(begin.duration(to: .now))
            if firstSource == nil, !engine.sourceText.isEmpty { firstSource = elapsed * 1000 }
            if !engine.sourceText.isEmpty, sourceUpdates.last?.text != engine.sourceText {
                sourceUpdates.append(SourceUpdate(ms: elapsed * 1000, text: engine.sourceText))
            }
            let current = engine.captions.visible
            if history.currentSession.count > segmentResults.count {
                for entry in history.currentSession.dropFirst(segmentResults.count) {
                    segmentResults.append(Segment(source: entry.sourceText, translation: entry.translationText,
                                                  finishedMS: elapsed * 1000))
                }
            }
            if current?.id != previous?.id || current?.translation.raw != previous?.translation.raw {
                let sameReadingPage = current?.id == previous?.id && previous?.translation.raw.isEmpty == false
                    && current?.translation.raw.isEmpty == false
                if let previous, !previous.translation.raw.isEmpty {
                    let effort = CaptionPaginator.readingUnits(previous.translation.raw)
                    // Replacing a draft is a revision, not a consumed page.
                    let revision = current?.utteranceID == previous.utteranceID
                        && (current?.id == previous.id
                            || (current?.isCorrection == true && !previous.isCorrection)
                            || (current?.isCorrection == true && previous.isDraft && current?.isDraft == false))
                    if effort > 0, !revision {
                        let ratio = (elapsed - shownAt) / effort
                        minimumRatio = min(minimumRatio ?? ratio, ratio)
                        if ratio < 0.95 { readingViolations += 1 }
                    }
                }
                previous = current
                if !sameReadingPage { shownAt = elapsed }
                if let current {
                    timing.note("caption_visible", id: current.utteranceID, text: current.translation.display,
                                reason: current.id.uuidString)
                    cueUpdates.append(CueUpdate(ms: elapsed * 1000, cueID: current.id, utteranceID: current.utteranceID,
                        source: current.source.display, translation: current.translation.display,
                        draft: current.isDraft, correction: current.isCorrection))
                }
            }
            if firstCaption == nil, current?.translation.raw.isEmpty == false { firstCaption = elapsed * 1000 }
            maximumQueue = max(maximumQueue, engine.captions.queuedCount)
            if case .error = engine.phase { timedOut = false; break }
            if progress.finishedMS != nil, !engine.captions.isDraining {
                timedOut = false
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let completeMS = seconds(begin.duration(to: .now)) * 1000
        let entries = history.currentSession
        let dropped = engine.droppedUtteranceCount
        let phase = engine.phase
        let captionsDrained = !engine.captions.isDraining
        let inputFinished = progress.finishedMS != nil
        let inferenceFinishedMS = progress.finishedMS
        let translationError = engine.lastTranslationError
        let liveCatchUps = engine.captions.scheduler.catchUpCount
        engine.stop()
        await completion.value
        try await history.flush(sessionID: history.sessionId)
        let error: String?
        if case .error(let message) = phase { error = message }
        else if let translationError { error = "Translation failed: \(translationError)" }
        else if timedOut { error = "Exceeded the \(Int(drainBudget))s post-audio reading/inference budget." }
        else if dropped > 0 { error = "Speech segments were dropped." }
        else { error = nil }
        return Row(fixture: fixture.id, reference: fixture.reference,
                   source: entries.map(\.sourceText).joined(separator: " "),
                   translation: entries.map(\.translationText).joined(separator: " "), segments: entries.count,
                   firstSourceMS: firstSource, firstCaptionMS: firstCaption, completeMS: completeMS,
                   minimumReadingRatio: minimumRatio, maximumCaptionQueue: maximumQueue,
                   droppedSegments: dropped, sourceUpdates: sourceUpdates, cueUpdates: cueUpdates,
                   deliveries: deliveries, segmentResults: segmentResults, audioSeconds: duration, inferenceFinishedMS: inferenceFinishedMS,
                   inputFinished: inputFinished, captionsDrained: captionsDrained,
                   readingViolations: readingViolations, liveCatchUps: liveCatchUps, drainBudgetSeconds: drainBudget, error: error,
                   timingEvents: timing.snapshot())
    }

    private static func seconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
}

@MainActor
private final class ReplayProgress {
    var finishedMS: Double?
}

private final class BenchmarkPacedAudio: AudioSource, @unchecked Sendable {
    let audio: [Float]
    let timing: PipelineTiming
    init(audio: [Float], timing: PipelineTiming) { self.audio = audio; self.timing = timing }
    func stream() -> AsyncStream<[Float]> {
        AsyncStream { continuation in
            let task = Task {
                let start = ContinuousClock.now
                for offset in stride(from: 0, to: audio.count, by: 512) {
                    do { try await Task.sleep(until: start + .seconds(Double(offset) / 16_000), clock: .continuous) }
                    catch { break }
                    continuation.yield(Array(audio[offset..<min(offset + 512, audio.count)]))
                    timing.note("audio_received", samples: min(offset + 512, audio.count))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
