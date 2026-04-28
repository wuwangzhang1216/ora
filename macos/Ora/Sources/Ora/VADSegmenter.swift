import Foundation
import SpeechVAD

/// Events emitted by the VAD segmenter. Mirrors the Python VADSegmenter.events() API.
enum VADEvent {
    case speechStart        // VAD just triggered — new utterance is starting
    case partial([Float])   // rolling snapshot of the current utterance (every ~800ms)
    case final([Float])     // end-of-speech; full utterance audio
}

/// Frame-level Silero VAD endpointing. Consumes an AsyncStream of mic audio chunks
/// (any size) and emits partial / final events gated by speech activity.
final class VADSegmenter: @unchecked Sendable {
    private let vad: SileroVADModel

    init(vad: SileroVADModel) {
        self.vad = vad
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
        AsyncStream { continuation in
            let task = Task { [vad] in
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
                        let prob = vad.processChunk(frame)

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

                            // Rolling partial emit
                            let grewEnough = (voiced.count - lastPartialFrames) >= partialGrowthFrames
                            let timeElapsed = Date().timeIntervalSince(lastPartialTime) >= partialIntervalS
                            if timeElapsed && grewEnough && voiced.count >= minFrames {
                                continuation.yield(.partial(flatten(voiced)))
                                lastPartialTime = Date()
                                lastPartialFrames = voiced.count
                            }

                            let endBySilence = silenceRun >= endSilenceFrames
                            let endByLength = voiced.count >= maxFrames
                            if endBySilence || endByLength {
                                if voiced.count >= minFrames {
                                    vad.resetState()
                                    continuation.yield(.final(flatten(voiced)))
                                }
                                triggered = false
                                voiced.removeAll()
                                voicedRun = 0
                                silenceRun = 0
                                lastPartialFrames = 0
                                preRoll.removeAll()
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
