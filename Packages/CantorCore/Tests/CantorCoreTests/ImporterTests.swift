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

    // MARK: Movies and FFmpeg

    /// Makes a test file with FFmpeg's own generators. Skips when FFmpeg isn't installed.
    private func ffmpegMake(_ name: String, _ arguments: [String]) throws -> URL {
        let ffmpeg = try XCTUnwrap(FFmpeg.locate(), "FFmpeg is not installed")
        let url = folder.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y"] + arguments + [url.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "could not make \(name)")
        return url
    }

    private func requireFFmpeg() throws {
        try XCTSkipIf(FFmpeg.locate() == nil, "FFmpeg is not installed")
    }

    private let tone = ["-f", "lavfi", "-i", "sine=frequency=440:duration=3"]
    private let picture = ["-f", "lavfi", "-i", "testsrc=duration=3:size=160x120:rate=10"]

    func testMovieAACIsCopiedOutWithoutReencoding() throws {
        try requireFFmpeg()
        // 96 kbps is well under the 256 kbps a re-encode would use, so the size shows which happened.
        let movie = try ffmpegMake("Choir Video.mov", tone + picture + ["-ac", "2", "-c:a", "aac", "-b:a", "96k", "-c:v", "mpeg4", "-shortest"])
        let result = try Importer.importFile(movie, into: managed, ffmpeg: nil)
        XCTAssertEqual(result.lastPathComponent, "Choir Video.m4a")
        try assertM4A(result, channels: 2, rate: 44_100, seconds: 3)
        let bytes = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: result.path)[.size] as? Int)
        XCTAssertLessThan(bytes, 3 * 140_000 / 8, "a 3 second copy at 96 kbps, not a 256 kbps re-encode")
    }

    func testMP4WithUncompressedAudioIsEncoded() throws {
        try requireFFmpeg()
        let movie = try ffmpegMake("Camera.mov", tone + picture + ["-ac", "2", "-ar", "48000", "-c:a", "pcm_s24le", "-c:v", "mpeg4", "-shortest"])
        try assertM4A(try Importer.importFile(movie, into: managed, ffmpeg: nil), channels: 2, rate: 48_000, seconds: 3)
    }

    func testM4VSurroundIsMixedToStereo() throws {
        try requireFFmpeg()
        let movie = try ffmpegMake("Concert.m4v", tone + picture + ["-ac", "6", "-c:a", "aac", "-c:v", "mpeg4", "-shortest"])
        try assertM4A(try Importer.importFile(movie, into: managed, ffmpeg: nil), channels: 2, rate: 44_100, seconds: 3)
    }

    func testSilentMovieSaysItHasNoAudio() throws {
        try requireFFmpeg()
        let movie = try ffmpegMake("B Roll.mp4", picture + ["-c:v", "mpeg4"])
        XCTAssertThrowsError(try Importer.importFile(movie, into: managed, ffmpeg: nil)) { error in
            guard case ImportError.noAudio = error else { return XCTFail("\(error)") }
        }
    }

    func testMKVWithoutFFmpegSaysFFmpegIsNeeded() throws {
        let source = folder.appendingPathComponent("Service.mkv")
        try Data([0x1A, 0x45, 0xDF, 0xA3, 0, 0, 0, 0]).write(to: source)
        XCTAssertThrowsError(try Importer.importFile(source, into: managed, ffmpeg: nil)) { error in
            guard case ImportError.needsFFmpeg = error else { return XCTFail("\(error)") }
            XCTAssertTrue(error.localizedDescription.contains("FFmpeg"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: managed.path), [])
    }

    func testMKVGoesThroughFFmpeg() throws {
        try requireFFmpeg()
        let movie = try ffmpegMake("Livestream.mkv", tone + picture + ["-ac", "2", "-ar", "48000", "-c:a", "libopus", "-c:v", "libvpx", "-shortest",
                                                                  "-metadata", "title=Way Maker"])
        let result = try Importer.importFile(movie, into: managed)
        XCTAssertEqual(result.lastPathComponent, "Livestream.m4a")
        try assertM4A(result, channels: 2, rate: 48_000, seconds: 3)
        XCTAssertEqual(AudioTags.read(url: result)["title"], "Way Maker")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("cantor-ffmpeg-") }
        XCTAssertEqual(leftovers, [], "FFmpeg's temporary folder is removed")
    }

    func testOGGAndAVIGoThroughFFmpeg() throws {
        try requireFFmpeg()
        // Opus, since not every FFmpeg build can write Vorbis. It decodes at 48 kHz.
        let ogg = try ffmpegMake("Prelude.ogg", tone + ["-c:a", "libopus"])
        try assertM4A(try Importer.importFile(ogg, into: managed), channels: 1, rate: 48_000, seconds: 3)
        let avi = try ffmpegMake("Old Tape.avi", tone + picture + ["-c:a", "mp3", "-c:v", "mpeg4", "-shortest"])
        try assertM4A(try Importer.importFile(avi, into: managed), channels: 1, rate: 44_100, seconds: 3)
    }

    func testBrokenFileThroughFFmpegIsRefusedAndLeavesNothing() throws {
        try requireFFmpeg()
        let source = folder.appendingPathComponent("Corrupt.avi")
        try Data(repeating: 7, count: 4096).write(to: source)
        XCTAssertThrowsError(try Importer.importFile(source, into: managed))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: managed.path), [])
    }

    func testFFmpegCannotWriteOutsideItsFolder() throws {
        try requireFFmpeg()
        let ffmpeg = try XCTUnwrap(FFmpeg.locate())
        let allowed = folder.appendingPathComponent("allowed")
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        let resolved = URL(fileURLWithPath: try XCTUnwrap(realpath(allowed.path, nil).map { String(cString: $0) }))
        let outside = resolved.deletingLastPathComponent().appendingPathComponent("escaped.flac")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: FFmpeg.sandboxExec)
        process.arguments = ["-p", FFmpeg.sandboxProfile(writableFolder: resolved.path), ffmpeg, "-nostdin", "-loglevel", "quiet"]
            + tone + [outside.path]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }

    func testFFmpegArgumentsReadNamesAsFiles() {
        let arguments = FFmpeg.arguments(source: "/tmp/concat:a.mkv", output: "/tmp/out.flac")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-i")! + 1], "file:/tmp/concat:a.mkv")
        XCTAssertEqual(arguments.last, "file:/tmp/out.flac")
    }
}
