import AVFoundation
import XCTest
@testable import CantorCore

final class ImporterTests: XCTestCase {
    private var folder: URL!
    private var managed: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ImporterTests-\(UUID().uuidString)")
        managed = folder.appendingPathComponent("Cantor")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Writes a 440 Hz tone in the format the settings describe.
    private func writeTone(_ name: String, settings extra: [String: Any] = [:], rate: Double = 44_100, channels: Int = 2, seconds: Double = 3) throws -> URL {
        let url = folder.appendingPathComponent(name)
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ]
        // More than two channels needs a layout to describe them.
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!
        if channels > 2 { settings[AVChannelLayoutKey] = Data(bytes: layout.layout, count: MemoryLayout<AudioChannelLayout>.size) }
        settings.merge(extra) { _, new in new }
        let format = channels > 2
            ? AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: layout)
            : AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels))!
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<channels {
            for frame in 0..<Int(frames) {
                buffer.floatChannelData![channel][frame] = Float(0.4 * sin(2 * .pi * 440 * Double(frame) / rate))
            }
        }
        // Closing the file finishes it, so it is written in its own scope.
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        return url
    }

    private func assertM4A(_ url: URL, channels: Int, rate: Double, seconds: Double, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(url.pathExtension, "m4a", file: file, line: line)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, managed.standardizedFileURL, file: file, line: line)
        let info = try XCTUnwrap(PCMDecoder.info(url: url), file: file, line: line)
        XCTAssertEqual(info.channels, channels, file: file, line: line)
        XCTAssertEqual(info.sampleRate, rate, file: file, line: line)
        XCTAssertEqual(info.durationSec, seconds, accuracy: 0.1, file: file, line: line)
        let audio = try AVAudioFile(forReading: url)
        XCTAssertEqual(audio.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC, file: file, line: line)
    }

    func testWAVBecomesM4A() throws {
        let source = try writeTone("Be Still.wav")
        let result = try Importer.importFile(source, into: managed)
        XCTAssertEqual(result.lastPathComponent, "Be Still.m4a")
        try assertM4A(result, channels: 2, rate: 44_100, seconds: 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the original stays")
    }

    func testAIFFBecomesM4A() throws {
        let source = try writeTone("Anthem.aiff", settings: [AVLinearPCMIsBigEndianKey: true])
        try assertM4A(try Importer.importFile(source, into: managed), channels: 2, rate: 44_100, seconds: 3)
    }

    func testFLACBecomesM4A() throws {
        let source = try writeTone("Offertory.flac", settings: [AVFormatIDKey: kAudioFormatFLAC], rate: 48_000)
        try assertM4A(try Importer.importFile(source, into: managed), channels: 2, rate: 48_000, seconds: 3)
    }

    func testHighRateMultichannelIsResampledAndMixedToStereo() throws {
        let source = try writeTone("Session.wav", settings: [AVLinearPCMBitDepthKey: 24], rate: 96_000, channels: 6, seconds: 2)
        try assertM4A(try Importer.importFile(source, into: managed), channels: 2, rate: 48_000, seconds: 2)
    }

    func testMonoStaysMono() throws {
        let source = try writeTone("Solo.wav", channels: 1)
        try assertM4A(try Importer.importFile(source, into: managed), channels: 1, rate: 44_100, seconds: 3)
    }

    func testCompressedFileIsCopiedNotReencoded() throws {
        let wav = try writeTone("Prelude.wav")
        let first = try Importer.importFile(wav, into: managed)
        let elsewhere = folder.appendingPathComponent("Prelude Copy.m4a")
        try FileManager.default.moveItem(at: first, to: elsewhere)

        let result = try Importer.importFile(elsewhere, into: managed)
        XCTAssertEqual(result.lastPathComponent, "Prelude Copy.m4a")
        XCTAssertEqual(try Data(contentsOf: result), try Data(contentsOf: elsewhere))
    }

    func testTakenNameGetsANumber() throws {
        let source = try writeTone("Hymn.wav")
        let first = try Importer.importFile(source, into: managed)
        let second = try Importer.importFile(source, into: managed)
        XCTAssertEqual(first.lastPathComponent, "Hymn.m4a")
        XCTAssertEqual(second.lastPathComponent, "Hymn 2.m4a")
    }

    func testUnreadableFileIsRefusedAndLeavesNothing() throws {
        let source = folder.appendingPathComponent("Notes.wav")
        try Data("not audio".utf8).write(to: source)
        XCTAssertThrowsError(try Importer.importFile(source, into: managed))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: managed.path), [])
    }

    func testTagsAreCarriedOver() throws {
        let wav = try writeTone("Untitled.wav")
        // Core Audio writes info tags to CAF, which stands in for a tagged WAV or AIFF.
        let tagged = folder.appendingPathComponent("Tagged.caf")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "caff", "-d", "LEI16", wav.path, tagged.path]
        try process.run()
        process.waitUntilExit()
        try XCTSkipIf(process.terminationStatus != 0, "afconvert unavailable")

        var file: AudioFileID?
        XCTAssertEqual(AudioFileOpenURL(tagged as CFURL, .readWritePermission, 0, &file), noErr)
        var info = ["title": "Great Is Thy Faithfulness", "artist": "Chancel Choir", "genre": "Choir", "comments": "Key of D"] as CFDictionary
        AudioFileSetProperty(file!, kAudioFilePropertyInfoDictionary, UInt32(MemoryLayout<CFDictionary>.size), &info)
        AudioFileClose(file!)
        try XCTSkipIf(AudioTags.read(url: tagged)["title"] == nil, "this format did not keep the tag")

        let result = try Importer.importFile(tagged, into: managed)
        let tags = AudioTags.read(url: result)
        XCTAssertEqual(tags["title"], "Great Is Thy Faithfulness")
        XCTAssertEqual(tags["artist"], "Chancel Choir")
        XCTAssertEqual(tags["genre"], "Choir")
        XCTAssertEqual(tags["comments"], "Key of D")
    }
}
