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

    // Review 3, finding 8.
    func testLowSampleRatesImport() throws {
        for (rate, channels) in [(8_000.0, 1), (11_025.0, 1), (16_000.0, 2), (22_050.0, 1), (22_050.0, 2), (32_000.0, 2)] {
            let source = try writeTone("Memo \(Int(rate)) \(channels).wav", rate: rate, channels: channels, seconds: 2)
            let result = try Importer.importFile(source, into: managed)
            try assertM4A(result, channels: channels, rate: rate, seconds: 2)
        }
        // At the usual rates the bit rate is unchanged.
        XCTAssertEqual(Importer.bitRate(sampleRate: 44_100, channels: 2), 256_000)
        XCTAssertEqual(Importer.bitRate(sampleRate: 48_000, channels: 1), 128_000)
    }

    func testMonoStaysMono() throws {
        let source = try writeTone("Solo.wav", channels: 1)
        try assertM4A(try Importer.importFile(source, into: managed), channels: 1, rate: 44_100, seconds: 3)
    }

    func testAACm4aIsPassedThroughNotReencoded() throws {
        let wav = try writeTone("Prelude.wav", seconds: 10)
        let first = try Importer.importFile(wav, into: managed)
        let elsewhere = folder.appendingPathComponent("Prelude Copy.m4a")
        try FileManager.default.moveItem(at: first, to: elsewhere)

        let result = try Importer.importFile(elsewhere, into: managed)
        XCTAssertEqual(result.lastPathComponent, "Prelude Copy.m4a")
        try assertM4A(result, channels: 2, rate: 44_100, seconds: 10)
        // The same AAC packets in a new file: the size barely moves.
        let before = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: elsewhere.path)[.size] as? Int)
        let after = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: result.path)[.size] as? Int)
        XCTAssertEqual(Double(after), Double(before), accuracy: Double(before) * 0.05)
    }

    // Review 2, finding 6.
    func testALACm4aIsConverted() throws {
        let wav = try writeTone("Lossless.wav", settings: [AVLinearPCMBitDepthKey: 24], rate: 96_000)
        let source = folder.appendingPathComponent("Lossless.m4a")
        try afconvert(["-f", "m4af", "-d", "alac", wav.path, source.path])
        // Held in a constant: the description points into the file's format, which must stay alive.
        let lossless = try AVAudioFile(forReading: source)
        XCTAssertEqual(lossless.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatAppleLossless)
        let result = try Importer.importFile(source, into: managed)
        XCTAssertEqual(result.lastPathComponent, "Lossless.m4a")
        try assertM4A(result, channels: 2, rate: 48_000, seconds: 3)
    }

    func testMP3IsCopiedAsItIs() throws {
        try requireFFmpeg()
        let mp3 = try ffmpegMake("Hymn.mp3", tone + ["-c:a", "libmp3lame"])
        let result = try Importer.importFile(mp3, into: managed)
        XCTAssertEqual(try Data(contentsOf: result), try Data(contentsOf: mp3))
    }

    // Review 2, finding 3.
    func testFullDiskEndsTheImportInsteadOfHanging() throws {
        let image = folder.appendingPathComponent("tiny.dmg")
        let mount = folder.appendingPathComponent("tiny")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        func hdiutil(_ arguments: [String]) -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return -1 }
            process.waitUntilExit()
            return process.terminationStatus
        }
        try XCTSkipIf(hdiutil(["create", "-size", "1m", "-fs", "HFS+", "-volname", "Tiny", image.path]) != 0, "could not make a disk image")
        try XCTSkipIf(hdiutil(["attach", "-nobrowse", "-mountpoint", mount.path, image.path]) != 0, "could not mount a disk image")
        defer { _ = hdiutil(["detach", "-force", mount.path]) }

        // About 2 MB of AAC, twice what fits.
        let source = try writeTone("Long.wav", seconds: 60)
        let target = mount.appendingPathComponent("Cantor")
        let finished = expectation(description: "import ends")
        let outcome = OutcomeBox()
        DispatchQueue.global().async {
            do {
                _ = try Importer.importFile(source, into: target)
            } catch {
                outcome.error = error
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 60)
        XCTAssertNotNil(outcome.error)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: target.path)) ?? [], [], "no partial file is left")
    }

    private final class OutcomeBox: @unchecked Sendable {
        var error: Error?
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool
        init(_ value: Bool) { stored = value }
        var value: Bool {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
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
        process.arguments = ["-p", FFmpeg.sandboxProfile(writableFolder: resolved.path, executable: ffmpeg), ffmpeg, "-nostdin", "-loglevel", "quiet"]
            + tone + [outside.path]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }

    /// Runs a program under the FFmpeg profile, as if it were the allowed program.
    private func sandboxed(_ program: String, _ arguments: [String]) throws -> Int32 {
        let writable = URL(fileURLWithPath: try XCTUnwrap(realpath(folder.path, nil).map { String(cString: $0) }))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: FFmpeg.sandboxExec)
        process.arguments = ["-p", FFmpeg.sandboxProfile(writableFolder: writable.path, executable: program), program] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    // Review 2, finding 8.
    func testSandboxBlocksWritesThroughSystemServices() throws {
        let domain = "org.prcatlanta.cantor.sandboxprobe.\(UUID().uuidString)"
        defer { CFPreferencesSetAppValue("k" as CFString, nil, domain as CFString); CFPreferencesAppSynchronize(domain as CFString) }
        XCTAssertNotEqual(try sandboxed("/usr/bin/defaults", ["write", domain, "k", "v"]), 0)
        XCTAssertNil(CFPreferencesCopyAppValue("k" as CFString, domain as CFString))
    }

    func testSandboxStartsNoOtherProgram() throws {
        // The profile allows only /usr/bin/true, so the shell it tries to start is refused.
        let writable = URL(fileURLWithPath: try XCTUnwrap(realpath(folder.path, nil).map { String(cString: $0) }))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: FFmpeg.sandboxExec)
        process.arguments = ["-p", FFmpeg.sandboxProfile(writableFolder: writable.path, executable: "/usr/bin/true"), "/bin/sh", "-c", "true"]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertEqual(try sandboxed("/usr/bin/true", []), 0, "the allowed program still runs")
    }

    func testFFmpegArgumentsReadNamesAsFiles() {
        let arguments = FFmpeg.arguments(source: "/tmp/concat:a.mkv", output: "/tmp/out.flac")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-i")! + 1], "file:/tmp/concat:a.mkv")
        XCTAssertEqual(arguments.last, "file:/tmp/out.flac")
    }

    // MARK: Progress

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Double] = []
        var values: [Double] { lock.withLock { stored } }
        func record(_ value: Double) { lock.withLock { stored.append(value) } }
    }

    private func assertSteadyProgress(_ values: [Double], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(values.last, 1, file: file, line: line)
        XCTAssertEqual(values, values.sorted(), "never goes backwards", file: file, line: line)
        XCTAssertEqual(values.count, Set(values).count, "no repeats", file: file, line: line)
        XCTAssertGreaterThan(values.filter { $0 > 0 && $0 < 1 }.count, 5, "moves through the middle", file: file, line: line)
    }

    func testConversionReportsProgress() throws {
        let source = try writeTone("Long.wav", seconds: 20)
        let recorder = Recorder()
        _ = try Importer.importFile(source, into: managed, progress: recorder.record)
        assertSteadyProgress(recorder.values)
    }

    func testCopyReportsDone() throws {
        let wav = try writeTone("Short.wav")
        let adts = folder.appendingPathComponent("Short.aac")
        try afconvert(["-f", "adts", "-d", "aac", wav.path, adts.path])
        let recorder = Recorder()
        _ = try Importer.importFile(adts, into: managed, progress: recorder.record)
        XCTAssertEqual(recorder.values, [1])
    }

    private func afconvert(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        try XCTSkipIf(process.terminationStatus != 0, "afconvert could not make the test file")
    }

    func testFFmpegImportReportsBothHalves() throws {
        try requireFFmpeg()
        let movie = try ffmpegMake("Long.mkv", ["-f", "lavfi", "-i", "sine=frequency=440:duration=60", "-c:a", "libopus"])
        let recorder = Recorder()
        _ = try Importer.importFile(movie, into: managed, progress: recorder.record)
        let values = recorder.values
        assertSteadyProgress(values)
        XCTAssertTrue(values.contains { $0 > 0 && $0 <= 0.5 }, "FFmpeg's half")
        XCTAssertTrue(values.contains { $0 > 0.5 && $0 < 1 }, "the encoder's half")
    }

    func testDurationFromFFmpegLog() {
        XCTAssertEqual(FFmpeg.duration(inLog: "[info] Input #0\n[info]   Duration: 01:02:03.50, start: 0.000000, bitrate: 132 kb/s"), 3723.5)
        XCTAssertNil(FFmpeg.duration(inLog: "[info]   Duration: N/A, start: 0.000000"))
        XCTAssertNil(FFmpeg.duration(inLog: "[info] Input #0"))
    }

    func testFFmpegErrorIsReportedWithoutItsLevel() throws {
        try requireFFmpeg()
        let source = folder.appendingPathComponent("Corrupt.mkv")
        try Data(repeating: 7, count: 4096).write(to: source)
        XCTAssertThrowsError(try Importer.importFile(source, into: managed)) { error in
            XCTAssertFalse(error.localizedDescription.contains("[error]"), error.localizedDescription)
        }
    }

    // MARK: Review 2, finding 7: the queue

    @MainActor
    func testQueueWaitsWhileTheShowIsBusyAndRunsInOrder() async throws {
        let log = Recorder()
        let busy = Flag(true)
        let queue = ImportQueue(pollInterval: .milliseconds(10), canRun: { !busy.value }) { url, progress in
            progress(0.5)
            log.record(Double(url.lastPathComponent.dropLast(4))!)
            return url
        }
        var finished: ([URL], [String])?
        queue.onFinished = { finished = ($0, $1) }
        queue.add([URL(fileURLWithPath: "/x/1.wav"), URL(fileURLWithPath: "/x/2.wav")])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(log.values, [], "nothing converts while a cue is engaged")
        XCTAssertEqual(queue.status?.paused, true)

        queue.add([URL(fileURLWithPath: "/x/3.wav")])
        XCTAssertEqual(queue.status?.total, 3)
        busy.value = false
        for _ in 0..<200 where finished == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(log.values, [1, 2, 3])
        XCTAssertEqual(finished?.0.count, 3)
        XCTAssertNil(queue.status)
    }

    @MainActor
    func testQueuePausesBetweenFilesWhenACueIsArmed() async throws {
        let log = Recorder()
        let busy = Flag(false)
        let queue = ImportQueue(pollInterval: .milliseconds(10), canRun: { !busy.value }) { url, _ in
            log.record(Double(url.lastPathComponent.dropLast(4))!)
            // A cue is armed while the first file converts.
            busy.value = true
            return url
        }
        var done = false
        queue.onFinished = { _, _ in done = true }
        queue.add([URL(fileURLWithPath: "/x/1.wav"), URL(fileURLWithPath: "/x/2.wav")])
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(log.values, [1], "the second file waits")
        XCTAssertEqual(queue.status?.number, 2)
        XCTAssertEqual(queue.status?.paused, true)
        busy.value = false
        for _ in 0..<200 where !done { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(log.values, [1, 2])
    }

    @MainActor
    func testQueueReportsFailuresTogether() async throws {
        struct Broken: LocalizedError { var errorDescription: String? { "broken" } }
        let queue = ImportQueue(pollInterval: .milliseconds(10), canRun: { true }) { url, _ in
            if url.lastPathComponent.hasPrefix("bad") { throw Broken() }
            return url
        }
        var finished: ([URL], [String])?
        queue.onFinished = { finished = ($0, $1) }
        queue.add([URL(fileURLWithPath: "/x/bad1.wav"), URL(fileURLWithPath: "/x/good.wav"), URL(fileURLWithPath: "/x/bad2.wav")])
        for _ in 0..<200 where finished == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(finished?.0.map(\.lastPathComponent), ["good.wav"])
        XCTAssertEqual(finished?.1, ["broken", "broken"])
    }
}
