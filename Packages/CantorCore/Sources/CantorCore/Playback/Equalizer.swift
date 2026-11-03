import Foundation

public enum EQShape: String, Codable, CaseIterable, Sendable {
    case highPass, lowShelf, bell, highShelf, lowPass

    /// Shapes that cut or boost by a gain. The passes only roll off.
    public var hasGain: Bool { self != .highPass && self != .lowPass }
}

public struct EQBand: Codable, Equatable, Sendable {
    public static let frequencyRange = 20.0...20_000.0
    public static let qRange = 0.1...18.0
    public static let gainRange = -18.0...18.0

    public var shape: EQShape
    public var isOn: Bool
    public var frequency: Double
    public var q: Double
    public var gainDb: Double

    public init(shape: EQShape, isOn: Bool = true, frequency: Double, q: Double = 0.71, gainDb: Double = 0) {
        self.shape = shape
        self.isOn = isOn
        self.frequency = frequency
        self.q = q
        self.gainDb = gainDb
    }

    /// True when the band changes nothing.
    public var isNeutral: Bool { !isOn || (shape.hasGain && gainDb == 0) }

    /// This band's own response in dB, for drawing it apart from the others.
    public func responseDb(atHz frequency: Double, sampleRate: Double = 48_000) -> Double {
        guard !isNeutral else { return 0 }
        return 20 * log10(max(Biquad(self, sampleRate: sampleRate).magnitude(atHz: frequency, sampleRate: sampleRate), 1e-9))
    }

    public mutating func clamp() {
        frequency = min(max(frequency, Self.frequencyRange.lowerBound), Self.frequencyRange.upperBound)
        q = min(max(q, Self.qRange.lowerBound), Self.qRange.upperBound)
        gainDb = shape.hasGain ? min(max(gainDb, Self.gainRange.lowerBound), Self.gainRange.upperBound) : 0
    }
}

/// A track's EQ: a high-pass, six bands and a low-pass, then output gain. Saved with the track.
public struct TrackEQ: Codable, Equatable, Sendable {
    public static let outputRange = -18.0...18.0

    public var isOn: Bool
    public var bands: [EQBand]
    public var outputDb: Double

    public init(isOn: Bool = true, bands: [EQBand] = TrackEQ.defaultBands, outputDb: Double = 0) {
        self.isOn = isOn
        self.bands = bands
        self.outputDb = outputDb
    }

    /// The passes start off, so a new EQ changes nothing until a band is moved.
    public static let defaultBands: [EQBand] = [
        EQBand(shape: .highPass, isOn: false, frequency: 40),
        EQBand(shape: .lowShelf, frequency: 100),
        EQBand(shape: .bell, frequency: 250, q: 1),
        EQBand(shape: .bell, frequency: 600, q: 1),
        EQBand(shape: .bell, frequency: 1500, q: 1),
        EQBand(shape: .bell, frequency: 4000, q: 1),
        EQBand(shape: .highShelf, frequency: 9000),
        EQBand(shape: .lowPass, isOn: false, frequency: 18_000),
    ]

    public var isFlat: Bool { !isOn || (outputDb == 0 && bands.allSatisfy(\.isNeutral)) }

    /// Response in dB at a frequency, for drawing the curve.
    public func responseDb(atHz frequency: Double, sampleRate: Double = 48_000) -> Double {
        guard isOn else { return 0 }
        var db = outputDb
        for band in bands { db += band.responseDb(atHz: frequency, sampleRate: sampleRate) }
        return db
    }
}

/// One second-order section, normalized so a0 is 1. Formulas from the RBJ Audio EQ Cookbook.
public struct Biquad: Equatable, Sendable {
    public var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double

    public static let identity = Biquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    public init(_ band: EQBand, sampleRate: Double) {
        // Above about 0.45 of the sample rate the filters fold over, so the frequency stops there.
        let frequency = min(max(band.frequency, 1), sampleRate * 0.45)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let c = cos(w0)
        let alpha = sin(w0) / (2 * max(band.q, 0.01))
        let a = pow(10, band.gainDb / 40)
        let root = 2 * a.squareRoot() * alpha
        let (b0, b1, b2, a0, a1, a2): (Double, Double, Double, Double, Double, Double)
        switch band.shape {
        case .highPass:
            (b0, b1, b2, a0, a1, a2) = ((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + alpha, -2 * c, 1 - alpha)
        case .lowPass:
            (b0, b1, b2, a0, a1, a2) = ((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + alpha, -2 * c, 1 - alpha)
        case .bell:
            (b0, b1, b2, a0, a1, a2) = (1 + alpha * a, -2 * c, 1 - alpha * a, 1 + alpha / a, -2 * c, 1 - alpha / a)
        case .lowShelf:
            (b0, b1, b2, a0, a1, a2) = (
                a * ((a + 1) - (a - 1) * c + root), 2 * a * ((a - 1) - (a + 1) * c), a * ((a + 1) - (a - 1) * c - root),
                (a + 1) + (a - 1) * c + root, -2 * ((a - 1) + (a + 1) * c), (a + 1) + (a - 1) * c - root
            )
        case .highShelf:
            (b0, b1, b2, a0, a1, a2) = (
                a * ((a + 1) + (a - 1) * c + root), -2 * a * ((a - 1) + (a + 1) * c), a * ((a + 1) + (a - 1) * c - root),
                (a + 1) - (a - 1) * c + root, 2 * ((a - 1) - (a + 1) * c), (a + 1) - (a - 1) * c - root
            )
        }
        self.init(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// Linear gain at a frequency.
    public func magnitude(atHz frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let numRe = b0 + b1 * cos(w) + b2 * cos(2 * w), numIm = -(b1 * sin(w) + b2 * sin(2 * w))
        let denRe = 1 + a1 * cos(w) + a2 * cos(2 * w), denIm = -(a1 * sin(w) + a2 * sin(2 * w))
        return ((numRe * numRe + numIm * numIm) / max(denRe * denRe + denIm * denIm, 1e-300)).squareRoot()
    }
}

/// Coefficients ready for the audio thread: a fixed number of sections and no heap storage, so it
/// can travel through the kernel's command ring and be copied without allocating.
public struct EQCoefficients: Sendable {
    public static let capacity = 8
    static let stride = 5

    public private(set) var count = 0
    public private(set) var outputGain: Float = 1
    /// Which bands the sections come from, one bit per band. Sections are packed, so when this
    /// changes, a section's history belongs to another band.
    public private(set) var layout: UInt8 = 0
    private var values: (
        Biquad, Biquad, Biquad, Biquad, Biquad, Biquad, Biquad, Biquad
    ) = (.identity, .identity, .identity, .identity, .identity, .identity, .identity, .identity)

    public static let flat = EQCoefficients()

    private init() {}

    public init(_ eq: TrackEQ?, sampleRate: Double) {
        guard let eq, !eq.isFlat, sampleRate > 0 else { return }
        outputGain = Float(pow(10, eq.outputDb / 20))
        for (index, band) in eq.bands.prefix(Self.capacity).enumerated() where !band.isNeutral {
            set(count, Biquad(band, sampleRate: sampleRate))
            count += 1
            layout |= 1 << UInt8(index)
        }
    }

    public var isFlat: Bool { count == 0 && outputGain == 1 }

    private mutating func set(_ index: Int, _ biquad: Biquad) {
        withUnsafeMutableBytes(of: &values) { $0.bindMemory(to: Biquad.self)[index] = biquad }
    }

    /// Writes the active sections as b0, b1, b2, a1, a2 runs.
    func write(to destination: UnsafeMutablePointer<Double>) {
        withUnsafeBytes(of: values) { raw in
            let sections = raw.bindMemory(to: Biquad.self)
            for index in 0..<count {
                let s = sections[index]
                let base = destination + index * Self.stride
                base[0] = s.b0
                base[1] = s.b1
                base[2] = s.b2
                base[3] = s.a1
                base[4] = s.a2
            }
        }
    }
}
