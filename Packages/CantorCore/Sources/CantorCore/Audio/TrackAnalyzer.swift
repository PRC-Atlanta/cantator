import Foundation

/// ITU-R BS.1770-4 integrated loudness with EBU R128 gating.
public enum LoudnessMeter {
    private struct Biquad {
        var b0, b1, b2, a1, a2: Double
        var z1 = 0.0
        var z2 = 0.0

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    private static func kWeighting(sampleRate fs: Double) -> (Biquad, Biquad) {
        var f0 = 1681.974450955533
        let gainDb = 3.999843853973347
        var q = 0.7071752369554196
        var k = tan(.pi * f0 / fs)
        let vh = pow(10, gainDb / 20)
        let vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf = Biquad(
            b0: (vh + vb * k / q + k * k) / a0,
            b1: 2 * (k * k - vh) / a0,
            b2: (vh - vb * k / q + k * k) / a0,
            a1: 2 * (k * k - 1) / a0,
            a2: (1 - k / q + k * k) / a0
        )
        f0 = 38.13547087602444
        q = 0.5003270373238773
        k = tan(.pi * f0 / fs)
        a0 = 1 + k / q + k * k
        let highPass = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        return (shelf, highPass)
    }

    public static func integrated(_ buffer: PCMBuffer) -> Double? {
        let fs = buffer.sampleRate
        let blockFrames = Int(fs * 0.4)
        let hop = Int(fs * 0.1)
        guard buffer.frames >= blockFrames, hop > 0 else { return nil }

        var (shelfL, passL) = kWeighting(sampleRate: fs)
        var (shelfR, passR) = kWeighting(sampleRate: fs)

        // Energy per hop, then a 4-hop sliding block gives 75% overlap.
        var hopEnergy: [Double] = []
        hopEnergy.reserveCapacity(buffer.frames / hop + 1)
        var accumulator = 0.0
        var count = 0
        for i in 0..<buffer.frames {
            let l = passL.process(shelfL.process(Double(buffer.left[i])))
            let r = passR.process(shelfR.process(Double(buffer.right[i])))
            accumulator += l * l + r * r
            count += 1
            if count == hop {
                hopEnergy.append(accumulator / Double(hop))
                accumulator = 0
                count = 0
            }
        }
        guard hopEnergy.count >= 4 else { return nil }

        var blocks: [Double] = []
        blocks.reserveCapacity(hopEnergy.count)
        for i in 3..<hopEnergy.count {
            blocks.append((hopEnergy[i] + hopEnergy[i - 1] + hopEnergy[i - 2] + hopEnergy[i - 3]) / 4)
        }

        let loudness = { (energy: Double) in -0.691 + 10 * log10(max(energy, 1e-12)) }
        let aboveAbsolute = blocks.filter { loudness($0) > -70 }
        guard !aboveAbsolute.isEmpty else { return nil }
        let relativeGate = loudness(aboveAbsolute.reduce(0, +) / Double(aboveAbsolute.count)) - 10
        let gated = aboveAbsolute.filter { loudness($0) > relativeGate }
        guard !gated.isEmpty else { return nil }
        return loudness(gated.reduce(0, +) / Double(gated.count))
    }

    /// 4x oversampled true peak. Only samples near the sample peak are interpolated.
    public static func truePeakDb(_ buffer: PCMBuffer) -> Double {
        let taps = 24
        let phases = 4
        var filters = [[Float]](repeating: [Float](repeating: 0, count: taps), count: phases)
        for phase in 1..<phases {
            let fraction = Double(phase) / Double(phases)
            var sum = 0.0
            for t in 0..<taps {
                let x = Double(t - taps / 2 + 1) - fraction
                let sinc = abs(x) < 1e-9 ? 1 : sin(.pi * x) / (.pi * x)
                let window = 0.5 + 0.5 * cos(.pi * x / Double(taps / 2))
                let value = sinc * window
                filters[phase][t] = Float(value)
                sum += value
            }
            for t in 0..<taps { filters[phase][t] /= Float(sum) }
        }

        var peak: Float = 0
        for channel in [buffer.left, buffer.right] {
            var samplePeak: Float = 0
            for i in 0..<buffer.frames { samplePeak = max(samplePeak, abs(channel[i])) }
            peak = max(peak, samplePeak)
            let threshold = samplePeak * 0.7
            guard buffer.frames > taps else { continue }
            for i in (taps / 2)..<(buffer.frames - taps / 2) where abs(channel[i]) >= threshold {
                for phase in 1..<phases {
                    var value: Float = 0
                    for t in 0..<taps { value += filters[phase][t] * channel[i + t - taps / 2 + 1] }
                    peak = max(peak, abs(value))
                }
            }
            if buffer.left == buffer.right { break }
        }
        return 20 * log10(Double(max(peak, 1e-6)))
    }

    /// Static gain to reach the target without pushing true peak past the ceiling.
    public static func gain(lufs: Double, truePeakDb: Double, targetLUFS: Double, ceilingDb: Double = -1) -> (gainDb: Double, capped: Bool) {
        let wanted = targetLUFS - lufs
        let allowed = ceilingDb - truePeakDb
        return wanted > allowed ? (allowed, true) : (wanted, false)
    }
}

public struct TrackAnalysis: Sendable {
    public var integratedLUFS: Double?
    public var truePeakDb: Double
    public var suggestedEndSec: Double?
    public var leadingSilenceSec: Double
    public var peaks: [Float]
}

public enum TrackAnalyzer {
    public static let silenceThresholdDb = -50.0
    public static let peakBuckets = 2000

    public static func analyze(_ buffer: PCMBuffer) -> TrackAnalysis {
        let threshold = Float(pow(10, silenceThresholdDb / 20))
        var last = -1
        var first = -1
        for i in 0..<buffer.frames where max(abs(buffer.left[i]), abs(buffer.right[i])) >= threshold {
            if first < 0 { first = i }
            last = i
        }
        return TrackAnalysis(
            integratedLUFS: LoudnessMeter.integrated(buffer),
            truePeakDb: LoudnessMeter.truePeakDb(buffer),
            suggestedEndSec: last >= 0 ? Double(last + 1) / buffer.sampleRate : nil,
            leadingSilenceSec: first > 0 ? Double(first) / buffer.sampleRate : 0,
            peaks: peaks(buffer, buckets: peakBuckets)
        )
    }

    public static func peaks(_ buffer: PCMBuffer, buckets: Int) -> [Float] {
        guard buffer.frames > 0, buckets > 0 else { return [] }
        var result = [Float](repeating: 0, count: buckets)
        for bucket in 0..<buckets {
            let start = bucket * buffer.frames / buckets
            let end = max((bucket + 1) * buffer.frames / buckets, start + 1)
            var peak: Float = 0
            for i in start..<min(end, buffer.frames) {
                peak = max(peak, abs(buffer.left[i]), abs(buffer.right[i]))
            }
            result[bucket] = peak
        }
        return result
    }
}
