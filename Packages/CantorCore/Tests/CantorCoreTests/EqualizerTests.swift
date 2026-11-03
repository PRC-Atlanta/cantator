import XCTest
@testable import CantorCore

final class EqualizerTests: XCTestCase {
    private let rate = 48_000.0

    func testBandsHitTheirGainAtTheirFrequency() {
        let bell = Biquad(EQBand(shape: .bell, frequency: 1000, q: 2, gainDb: 6), sampleRate: rate)
        XCTAssertEqual(20 * log10(bell.magnitude(atHz: 1000, sampleRate: rate)), 6, accuracy: 0.01)
        XCTAssertEqual(20 * log10(bell.magnitude(atHz: 50, sampleRate: rate)), 0, accuracy: 0.1)

        let low = Biquad(EQBand(shape: .lowShelf, frequency: 200, gainDb: -9), sampleRate: rate)
        XCTAssertEqual(20 * log10(low.magnitude(atHz: 20, sampleRate: rate)), -9, accuracy: 0.2)
        XCTAssertEqual(20 * log10(low.magnitude(atHz: 10_000, sampleRate: rate)), 0, accuracy: 0.1)

        let high = Biquad(EQBand(shape: .highShelf, frequency: 5000, gainDb: 4), sampleRate: rate)
        XCTAssertEqual(20 * log10(high.magnitude(atHz: 20_000, sampleRate: rate)), 4, accuracy: 0.3)

        let pass = Biquad(EQBand(shape: .highPass, frequency: 100), sampleRate: rate)
        XCTAssertEqual(20 * log10(pass.magnitude(atHz: 100, sampleRate: rate)), -3, accuracy: 0.1)
        XCTAssertLessThan(20 * log10(pass.magnitude(atHz: 25, sampleRate: rate)), -20)
    }

    func testNewEQIsFlatAndCostsNothing() {
        let eq = TrackEQ()
        XCTAssertTrue(eq.isFlat)
        XCTAssertTrue(EQCoefficients(eq, sampleRate: rate).isFlat)
        XCTAssertTrue(EQCoefficients(nil, sampleRate: rate).isFlat)
        XCTAssertEqual(eq.responseDb(atHz: 1000), 0, accuracy: 1e-9)

        var bypassed = eq
        bypassed.bands[3].gainDb = 6
        bypassed.isOn = false
        XCTAssertTrue(EQCoefficients(bypassed, sampleRate: rate).isFlat)
    }

    func testClampKeepsBandsInRange() {
        var band = EQBand(shape: .highPass, frequency: 5, q: 40, gainDb: 12)
        band.clamp()
        XCTAssertEqual(band.frequency, 20)
        XCTAssertEqual(band.q, 18)
        XCTAssertEqual(band.gainDb, 0)
    }

    /// Plays a sine through the kernel and returns the steady-state peak.
    private func peak(hz: Double, eq: TrackEQ?, change: TrackEQ? = nil) -> Float {
        let frames = Int(rate)
        let samples = (0..<frames).map { Float(0.25 * sin(2 * .pi * hz * Double($0) / rate)) }
        let buffer = PCMBuffer(left: samples, right: samples, sampleRate: rate)
        let kernel = PlaybackKernel(buffer: buffer, parameters: PlaybackParameters(
            startFrame: 0, endFrame: frames, fadeOutFrames: 0, fadeInFrames: 0, gainLinear: 1, eq: EQCoefficients(eq, sampleRate: rate)
        ))
        if let change { kernel.setEQ(EQCoefficients(change, sampleRate: rate)) }
        kernel.play()
        let block = 4800
        let left = UnsafeMutablePointer<Float>.allocate(capacity: block)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: block)
        defer { left.deallocate(); right.deallocate() }
        var result: Float = 0
        for index in 0..<6 {
            kernel.render(frames: block, left: left, right: right)
            // Skip the declick and the filters settling.
            if index >= 2 { result = max(result, (0..<block).map { max(abs(left[$0]), abs(right[$0])) }.max() ?? 0) }
        }
        return result
    }

    func testKernelAppliesTheEQ() {
        var cut = TrackEQ()
        cut.bands[3].frequency = 1000
        cut.bands[3].gainDb = -12
        XCTAssertEqual(peak(hz: 1000, eq: nil), 0.25, accuracy: 0.002)
        XCTAssertEqual(Double(peak(hz: 1000, eq: cut)), 0.25 * pow(10, -12 / 20), accuracy: 0.003)
        XCTAssertEqual(peak(hz: 100, eq: cut), 0.25, accuracy: 0.005)

        var louder = TrackEQ()
        louder.outputDb = 6
        XCTAssertEqual(Double(peak(hz: 1000, eq: louder)), 0.25 * pow(10, 6.0 / 20), accuracy: 0.003)
    }

    func testPreviewCanChangeTheEQWhilePlaying() {
        var cut = TrackEQ()
        cut.bands[3].frequency = 1000
        cut.bands[3].gainDb = -12
        XCTAssertEqual(peak(hz: 1000, eq: cut, change: TrackEQ()), 0.25, accuracy: 0.002)
    }

    func testTrackWithoutEQStillLoadsAndEQSurvivesSaving() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"Old","files":[]}"#
        var track = try JSONDecoder().decode(Track.self, from: Data(json.utf8))
        XCTAssertNil(track.eq)

        var eq = TrackEQ()
        eq.bands[0].isOn = true
        eq.bands[0].frequency = 80
        track.eq = eq
        XCTAssertEqual(try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(track)).eq, eq)
    }

    // MARK: Review 2, finding 5: live changes on the house

    /// Plays a 97 Hz sine, applies `change` halfway, and returns the largest sample-to-sample
    /// step just after the change, and the largest in the steady parts before and after it. A
    /// click is a step bigger than the tone ever makes on its own. 97 Hz, so the change doesn't
    /// land on a zero crossing.
    private func steps(from eq: TrackEQ?, to change: TrackEQ?) -> (atChange: Float, steady: Float) {
        let frames = Int(rate)
        let samples = (0..<frames).map { Float(0.25 * sin(2 * .pi * 97 * Double($0) / rate)) }
        let buffer = PCMBuffer(left: samples, right: samples, sampleRate: rate)
        let kernel = PlaybackKernel(buffer: buffer, parameters: PlaybackParameters(
            startFrame: 0, endFrame: frames, fadeOutFrames: 0, fadeInFrames: 0, gainLinear: 1, eq: EQCoefficients(eq, sampleRate: rate)
        ))
        kernel.play()
        let block = 4800
        let left = UnsafeMutablePointer<Float>.allocate(capacity: block)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: block)
        defer { left.deallocate(); right.deallocate() }
        var out: [Float] = []
        for index in 0..<6 {
            if index == 3 { kernel.setEQ(EQCoefficients(change, sampleRate: rate)) }
            kernel.render(frames: block, left: left, right: right)
            out += (0..<block).map { left[$0] }
        }
        func largestStep(_ range: Range<Int>) -> Float { range.dropFirst().map { abs(out[$0] - out[$0 - 1]) }.max() ?? 0 }
        let steady = max(largestStep(block..<3 * block), largestStep(5 * block..<6 * block))
        // From the last sample before the change, so the step into the first one after it counts.
        return (largestStep(3 * block - 1..<3 * block + 2400), steady)
    }

    func testTurningABandOffLiveDoesNotClick() {
        // A high-pass above the tone and a bell on it, so both shape what is heard.
        var filtered = TrackEQ()
        filtered.bands[0].isOn = true
        filtered.bands[0].frequency = 200
        filtered.bands[3].frequency = 97
        filtered.bands[3].gainDb = 6
        // The bell lands on 0 dB while being dragged, so its section drops out of the chain.
        var dragged = filtered
        dragged.bands[3].gainDb = 0
        var passOff = filtered
        passOff.bands[0].isOn = false
        for change in [dragged, passOff] {
            let (atChange, steady) = steps(from: filtered, to: change)
            XCTAssertLessThan(atChange, steady * 1.2, "no jump bigger than the tone's own movement")
        }
    }

    func testBypassOnABoostedTrackGlides() {
        var boosted = TrackEQ()
        boosted.outputDb = 12
        var bypassed = boosted
        bypassed.isOn = false
        let (atChange, steady) = steps(from: boosted, to: bypassed)
        // A 12 dB step would jump by about three quarters of the boosted peak in one sample.
        XCTAssertLessThan(atChange, steady * 1.2)
        // And it does arrive: a second later the level is the plain one.
        XCTAssertEqual(peak(hz: 1000, eq: boosted, change: bypassed), 0.25, accuracy: 0.003)
    }
}
