import XCTest
@testable import CantorCore

/// Runs real Core Audio against virtual devices only, so it can never reach speakers.
/// Skipped unless CANTOR_HARDWARE_TEST=1. Needs BlackHole 2ch, and optionally a device with more
/// than two outputs named "Pro Tools Audio Bridge" for the channel map case.
@MainActor
final class HardwareTests: XCTestCase {
    private func virtualDevice(_ namePrefix: String, minChannels: Int = 2) throws -> AudioOutputDevice {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CANTOR_HARDWARE_TEST"] == "1", "hardware tests are opt-in")
        let device = AudioDevices.outputDevices().first { $0.name.hasPrefix(namePrefix) && $0.outputChannels >= minChannels }
        return try XCTUnwrap(device, "\(namePrefix) not installed")
    }

    private func tone(seconds: Double = 5, rate: Double = 48_000) -> PCMBuffer {
        let samples = (0..<Int(seconds * rate)).map { Float(0.1 * sin(2 * .pi * 440 * Double($0) / rate)) }
        return PCMBuffer(left: samples, right: samples, sampleRate: rate)
    }

    private func wait(seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    func testArmedEngineStaysSilentUntilGoThenFadesToFinish() async throws {
        let device = try virtualDevice("BlackHole")
        let house = HouseBus()
        let kernel = PlaybackKernel(buffer: tone(), parameters: PlaybackParameters(
            startFrame: 0, endFrame: 240_000, fadeOutFrames: 0, fadeInFrames: 0, gainLinear: 1
        ))
        try house.start(kernel: kernel, deviceUID: device.uid, firstChannel: 0)
        defer { house.stop() }

        await wait(seconds: 0.5)
        XCTAssertEqual(kernel.positionFrames, 0, "armed engine must not advance")
        XCTAssertEqual(kernel.takePeaks().left, 0, "armed engine must emit nothing")

        kernel.play()
        await wait(seconds: 0.5)
        XCTAssertGreaterThan(kernel.positionFrames, 10_000, "the device must pull audio after GO")
        XCTAssertGreaterThan(kernel.takePeaks().left, 0.05)

        kernel.fade(seconds: 0.2)
        await wait(seconds: 0.5)
        XCTAssertEqual(kernel.phase, .finished)
    }

    func testChannelMapStartsOnMultichannelDevice() async throws {
        let device = try virtualDevice("Pro Tools Audio Bridge", minChannels: 6)
        let house = HouseBus()
        let kernel = PlaybackKernel(buffer: tone(), parameters: PlaybackParameters(
            startFrame: 0, endFrame: 240_000, fadeOutFrames: 0, fadeInFrames: 0, gainLinear: 1
        ))
        try house.start(kernel: kernel, deviceUID: device.uid, firstChannel: 2)
        defer { house.stop() }
        kernel.play()
        await wait(seconds: 0.5)
        XCTAssertGreaterThan(kernel.positionFrames, 10_000)
    }

    func testCueBusRefusesHouseDevice() throws {
        let device = try virtualDevice("BlackHole")
        let cue = CueBus()
        let buffer = tone(seconds: 1)
        let parameters = PlaybackParameters(startFrame: 0, endFrame: buffer.frames, fadeOutFrames: 0, fadeInFrames: 0, gainLinear: 1)
        XCTAssertThrowsError(try cue.audition(
            trackID: UUID(), buffer: buffer, parameters: parameters,
            routing: OutputRouting(houseDeviceUID: device.uid, cueDeviceUID: device.uid)
        ))
    }

    func testDevicesEnumerate() throws {
        let device = try virtualDevice("BlackHole")
        XCTAssertTrue(AudioDevices.isAlive(uid: device.uid))
        XCTAssertFalse(AudioDevices.isAlive(uid: "no-such-device"))
    }

    func testDecodesCompressedAudio() throws {
        // afconvert cannot write MP3, so AAC covers the compressed path.
        _ = try virtualDevice("BlackHole")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wav = directory.appendingPathComponent("t.wav")
        let m4a = directory.appendingPathComponent("t.m4a")
        var data = Data("RIFF".utf8)
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        let frames = 96_000
        data += le32(36 + frames * 2) + Data("WAVEfmt ".utf8) + le32(16) + le16(1) + le16(1) + le32(48_000) + le32(96_000) + le16(2) + le16(16)
        data += Data("data".utf8) + le32(frames * 2)
        data += Data((0..<frames).flatMap { n -> [UInt8] in
            let sample = Int16(8000 * sin(2 * Double.pi * 440 * Double(n) / 48_000))
            return withUnsafeBytes(of: sample.littleEndian) { Array($0) }
        })
        try data.write(to: wav)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = [wav.path, m4a.path, "-f", "m4af", "-d", "aac"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let buffer = try PCMDecoder.decode(url: m4a)
        XCTAssertEqual(buffer.durationSeconds, 2, accuracy: 0.1)
        XCTAssertGreaterThan(TrackAnalyzer.analyze(buffer).integratedLUFS ?? -99, -40)
    }
}
