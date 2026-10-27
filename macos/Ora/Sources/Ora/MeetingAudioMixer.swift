import Foundation

/// Aligns resampled ScreenCaptureKit system/microphone buffers on their shared
/// presentation clock. Call on one serial queue. Never concatenate the two
/// inputs: that would double elapsed audio time and interleave words.
struct MeetingAudioMixer {
    enum Input { case system, microphone }

    private struct Sample {
        var index: Int64 = .min
        var system: Float = 0
        var microphone: Float = 0
    }

    private let sampleRate: Double
    private let frameSamples: Int
    private var slots: [Sample]
    private var cursor: Int64?
    private var hasRendered = false

    init(sampleRate: Int = Config.sampleRate, frameSamples: Int = 320,
         capacity: Int = Config.sampleRate * 2) {
        precondition(sampleRate > 0 && frameSamples > 0 && capacity >= frameSamples)
        self.sampleRate = Double(sampleRate)
        self.frameSamples = frameSamples
        slots = Array(repeating: Sample(), count: capacity)
    }

    mutating func append(_ samples: [Float], from input: Input, at time: Double) {
        guard time.isFinite, time >= 0, !samples.isEmpty else { return }
        let start = Int64((time * sampleRate).rounded())
        if cursor == nil { cursor = start }
        if !hasRendered, let first = cursor, start < first,
           first - start < Int64(slots.count) {
            cursor = start
        }
        guard let cursor else { return }
        // A delayed callback may overlap already-rendered samples. Ignore that
        // portion; never replay it. The fixed ring also bounds stalled capture.
        let lower = Int(max(0, cursor - start))
        let upper = Int(min(Int64(samples.count), cursor + Int64(slots.count) - start))
        guard lower < upper else { return }
        for offset in lower..<upper {
            let index = start + Int64(offset)
            let slot = Int(index % Int64(slots.count))
            if slots[slot].index != index { slots[slot] = Sample(index: index) }
            let value = samples[offset].isFinite ? samples[offset] : 0
            switch input {
            case .system: slots[slot].system = value
            case .microphone: slots[slot].microphone = value
            }
        }
    }

    /// Emit complete 20 ms frames through the supplied capture-clock deadline.
    /// The caller leaves a short jitter allowance so both callbacks can arrive.
    /// Missing input becomes silence, so one silent source never stalls the other.
    mutating func render(until time: Double) -> [[Float]] {
        guard time.isFinite, time >= 0, var cursor else { return [] }
        let end = Int64((time * sampleRate).rounded(.down))
        guard end > cursor else { return [] }
        if end - cursor > Int64(slots.count) {
            cursor = end - Int64(slots.count)
        }
        var frames: [[Float]] = []
        while cursor + Int64(frameSamples) <= end {
            var frame = [Float](repeating: 0, count: frameSamples)
            for offset in 0..<frameSamples {
                let index = cursor + Int64(offset)
                let slot = Int(index % Int64(slots.count))
                if slots[slot].index == index {
                    // Fixed headroom prevents clipping when both people speak.
                    frame[offset] = max(-1, min(1, (slots[slot].system + slots[slot].microphone) * 0.5))
                    slots[slot] = Sample()
                }
            }
            frames.append(frame)
            hasRendered = true
            cursor += Int64(frameSamples)
        }
        self.cursor = cursor
        return frames
    }
}
