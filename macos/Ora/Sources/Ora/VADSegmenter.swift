import Foundation
import SpeechVAD

/// Events emitted by the VAD segmenter. Mirrors the Python VADSegmenter.events() API.
enum VADEvent {
    case speechStart        // VAD just triggered — new utterance is starting
    case partial([Float])   // rolling snapshot of the current utterance (every ~800ms)
    case final([Float])     // processing slice / endpoint; empty closes an already emitted slice
}

/// Frame-level Silero VAD endpointing. Consumes an AsyncStream of mic audio chunks
/// (any size) and emits partial / final events gated by speech activity.
final class VADSegmenter: @unchecked Sendable {
    /// Speech probability for one 512-sample frame. Injected so the endpointing
    /// state machine is testable without CoreML weights.
    private let probe: ([Float]) -> Float
    private let resetVADState: () -> Void

    init(vad: SileroVADModel) {
        self.probe = { vad.processChunk($0) }
        self.resetVADState = { vad.resetState() }
    }

    init(probe: @escaping ([Float]) -> Float, resetState: @escaping () -> Void = {}) {
        self.probe = probe
        self.resetVADState = resetState
    }

    static func load() async throws -> VADSegmenter {
        let model = try await SileroVADModel.fromPretrained(engine: .coreml)
        return VADSegmenter(vad: model)
    }

    /// Convert a raw mic stream into a stream of VAD events. Thresholds are
    /// passed in so that the UI's Preferences slider can actually take effect
    /// at each new listening session.
    func events(
        from audio: AsyncStream<[Float]>,
        startThreshold: Float = Config.vadThreshold,
        stopThreshold: Float = Config.vadStopThreshold,
        endSilenceMs: Int = Config.speechEndMs,
        partialIntervalS: Double = Config.partialIntervalS
    ) -> AsyncStream<VADEvent> {
        // Bounded buffer: if the downstream consumer stalls on ASR + LLM, this
        // VAD task keeps emitting partials/finals. Dropping the oldest events
        // beyond the cap keeps end-to-end latency bounded instead of letting a
        // long session accumulate a minutes-deep backlog (freeze + repetition).
        AsyncStream(bufferingPolicy: .bufferingNewest(Config.maxPendingVADEvents)) { continuation in
            let task = Task { [probe, resetVADState] in
                // A new listening/replay session must not inherit recurrent
                // state from speech stopped without trailing silence.
                resetVADState()
                let frameSize = Config.vadFrameSamples
                let preRollFrames = max(1, Config.preRollMs / Config.vadFrameMs)
                let endSilenceFrames = max(1, endSilenceMs / Config.vadFrameMs)
                let minFrames = max(1, Config.minUtteranceMs / Config.vadFrameMs)
                let maxFrames = Int(Config.maxUtteranceS * 1_000 / Double(Config.vadFrameMs))
                let partialGrowthFrames = max(1, Int(Config.partialMinGrowthS * 1_000 / Double(Config.vadFrameMs)))

                var leftover: [Float] = []
                var preRoll: [[Float]] = []
                var voiced: [[Float]] = []       // list of frame arrays
                var triggered = false
                var hasPriorSlice = false
                var voicedRun = 0
                var silenceRun = 0
                var lastPartialTime = Date.distantPast
                var lastPartialFrames = 0

                func flatten(_ frames: [[Float]]) -> [Float] {
                    var out: [Float] = []
                    out.reserveCapacity(frames.count * frameSize)
                    for f in frames { out.append(contentsOf: f) }
                    return out
                }

                for await chunk in audio {
                    leftover.append(contentsOf: chunk)
                    while leftover.count >= frameSize {
                        let frame = Array(leftover.prefix(frameSize))
                        leftover.removeFirst(frameSize)
                        let prob = probe(frame)

                        // Hysteresis: use the HIGHER start threshold to decide
                        // when speech begins, and the LOWER stop threshold to
                        // decide silence while already in a speech region.
                        // Prevents rapid toggling around a single boundary.
                        if !triggered {
                            let isSpeech = prob >= startThreshold
                            preRoll.append(frame)
                            if preRoll.count > preRollFrames {
                                preRoll.removeFirst(preRoll.count - preRollFrames)
                            }
                            if isSpeech {
                                voicedRun += 1
                                if voicedRun >= Config.speechStartFrames {
                                    triggered = true
                                    voiced.append(contentsOf: preRoll)
                                    preRoll.removeAll()
                                    silenceRun = 0
                                    lastPartialTime = Date()
                                    lastPartialFrames = voiced.count
                                    continuation.yield(.speechStart)
                                }
                            } else {
                                voicedRun = 0
                            }
                        } else {
                            let isStillSpeech = prob >= stopThreshold
                            voiced.append(frame)
                            if isStillSpeech {
                                silenceRun = 0
                            } else {
                                silenceRun += 1
                            }

                            // Rolling partial emit. Gate on actual speech
                            // frames (buffer minus trailing silence) so a
                            // mostly-silence buffer can't trigger a partial
                            // that ASR would hallucinate text for.
                            let grewEnough = (voiced.count - lastPartialFrames) >= partialGrowthFrames
                            let timeElapsed = Date().timeIntervalSince(lastPartialTime) >= partialIntervalS
                            if timeElapsed && grewEnough && (voiced.count - silenceRun) >= minFrames {
                                continuation.yield(.partial(flatten(voiced)))
                                lastPartialTime = Date()
                                lastPartialFrames = voiced.count
                            }

                            let endBySilence = silenceRun >= endSilenceFrames
                            let endByLength = voiced.count >= maxFrames
                            if endBySilence || endByLength {
                                // Measure actual speech, not buffer length —
                                // the buffer ends with the end-silence window,
                                // which alone exceeds minFrames and made this
                                // guard dead code: noise blips produced
                                // spurious finals (and hallucinated ASR).
                                let speechFrames = voiced.count - silenceRun
                                let continues = endByLength && !endBySilence
                                if !continues { resetVADState() }
                                if speechFrames >= minFrames || hasPriorSlice {
                                    // A short last word still belongs to the
                                    // speech emitted in prior slices. Pure
                                    // silence only signals its endpoint.
                                    continuation.yield(.final(speechFrames > 0 ? flatten(voiced) : []))
                                }
                                triggered = continues
                                hasPriorSlice = continues
                                voiced.removeAll()
                                voicedRun = 0
                                if !continues { silenceRun = 0 }
                                lastPartialFrames = 0
                                preRoll.removeAll()
                                if continues {
                                    // A processing slice is not a new voice
                                    // onset. Preserve VAD state and every next
                                    // sample, without another trigger delay.
                                    lastPartialTime = Date()
                                    continuation.yield(.speechStart)
                                }
                            }
                        }
                    }
                }
                // Finite replays / a naturally ended audio source may stop
                // without trailing silence. Preserve the last spoken words.
                if !Task.isCancelled, triggered, voiced.count - silenceRun >= minFrames || hasPriorSlice {
                    continuation.yield(.final(voiced.count - silenceRun > 0 ? flatten(voiced) : []))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
