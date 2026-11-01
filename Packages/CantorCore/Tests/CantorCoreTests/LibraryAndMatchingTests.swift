import XCTest
@testable import CantorCore

final class ContentHasherTests: XCTestCase {
    private let audio = Data((0..<4096).map { UInt8($0 % 251) })

    private func id3v2(payloadSize: Int) -> Data {
        let size = payloadSize
        var header = Data("ID3".utf8) + Data([4, 0, 0])
        header.append(contentsOf: [UInt8(size >> 21 & 0x7F), UInt8(size >> 14 & 0x7F), UInt8(size >> 7 & 0x7F), UInt8(size & 0x7F)])
        return header + Data(repeating: 0x41, count: size)
    }

    func testRetaggingMP3KeepsContentID() {
        let plain = ContentHasher.contentID(data: audio, isMP3: true)
        let tagged = id3v2(payloadSize: 300) + audio
        XCTAssertEqual(ContentHasher.contentID(data: tagged, isMP3: true), plain)

        let trailer = Data("TAG".utf8) + Data(repeating: 0x20, count: 125)
        XCTAssertEqual(ContentHasher.contentID(data: id3v2(payloadSize: 9000) + audio + trailer, isMP3: true), plain)
    }

    func testStackedAndLargeID3HeadersAreStripped() {
        let plain = ContentHasher.contentID(data: audio, isMP3: true)
        XCTAssertEqual(ContentHasher.contentID(data: id3v2(payloadSize: 20) + id3v2(payloadSize: 70_000) + audio, isMP3: true), plain)
    }

    func testAPETagIsStripped() {
        let plain = ContentHasher.contentID(data: audio, isMP3: true)
        var footer = Data("APETAGEX".utf8)
        footer.append(contentsOf: [0xD0, 0x07, 0, 0])              // version
        footer.append(contentsOf: [UInt8(32 + 8), 0, 0, 0])        // size incl. footer
        footer.append(contentsOf: [1, 0, 0, 0])                    // item count
        footer.append(contentsOf: [0, 0, 0, 0])                    // flags, no header
        footer.append(Data(repeating: 0, count: 8))
        let tagged = audio + Data(repeating: 0x55, count: 8) + footer
        XCTAssertEqual(ContentHasher.contentID(data: tagged, isMP3: true), plain)
    }

    func testDifferentAudioDiffers() {
        var other = audio
        other[100] ^= 0xFF
        XCTAssertNotEqual(ContentHasher.contentID(data: audio, isMP3: true), ContentHasher.contentID(data: other, isMP3: true))
    }

    func testNonMP3HashesWholeFile() {
        let tagged = Data("ID3".utf8) + audio
        XCTAssertNotEqual(ContentHasher.contentID(data: tagged, isMP3: false), ContentHasher.contentID(data: audio, isMP3: false))
    }

    func testDataSliceWithNonZeroIndexIsHandled() {
        let padded = Data([1, 2, 3]) + id3v2(payloadSize: 40) + audio
        let slice = padded[3...]
        XCTAssertEqual(ContentHasher.contentID(data: slice, isMP3: true), ContentHasher.contentID(data: audio, isMP3: true))
    }
}

final class LibraryMergeTests: XCTestCase {
    private func file(_ path: String, id: String?, locality: FileLocality = .local, duration: Double = 200) -> ScannedFile {
        ScannedFile(path: path, locality: locality, contentID: id, durationSec: duration, sampleRate: 48_000, channels: 2)
    }

    func testSameAudioInTwoFoldersBecomesOneTrack() {
        var library = Library()
        library.merge(scan: [file("/a/Song.mp3", id: "x"), file("/b/Song (1).mp3", id: "x")])
        XCTAssertEqual(library.tracks.count, 1)
        XCTAssertEqual(library.tracks[0].files.count, 2)
        XCTAssertEqual(library.duplicateGroups.first?.kind, .sameAudio)
    }

    func testMovingAFileKeepsCuePoints() {
        var library = Library()
        library.merge(scan: [file("/a/Song.mp3", id: "x")])
        library.update(id: library.tracks[0].id) { $0.endSec = 180 }
        library.merge(scan: [file("/new/Renamed.mp3", id: "x")])
        XCTAssertEqual(library.tracks.count, 1)
        XCTAssertEqual(library.tracks[0].endSec, 180)
        XCTAssertEqual(library.tracks[0].bestFile()?.path, "/new/Renamed.mp3")
    }

    func testDeletedFileIsMarkedMissingNotForgotten() {
        var library = Library()
        library.merge(scan: [file("/a/Song.mp3", id: "x")])
        library.update(id: library.tracks[0].id) { $0.endSec = 180 }
        library.merge(scan: [])
        XCTAssertEqual(library.tracks.count, 1)
        XCTAssertEqual(library.tracks[0].files[0].locality, .missing)
        XCTAssertFalse(library.tracks[0].isLocal)
    }

    func testPlaceholderGainsContentIDWhenDownloaded() {
        var library = Library()
        library.merge(scan: [file("/drive/Song.mp3", id: nil, locality: .cloudOnly, duration: 0)])
        XCTAssertFalse(library.tracks[0].isLocal)
        XCTAssertTrue(library.tracks[0].hasCloudOnlyCopy)
        let id = library.tracks[0].id
        library.merge(scan: [file("/drive/Song.mp3", id: "x")])
        XCTAssertEqual(library.tracks.count, 1)
        XCTAssertEqual(library.tracks[0].id, id)
        XCTAssertEqual(library.tracks[0].contentID, "x")
        XCTAssertTrue(library.tracks[0].isLocal)
    }

    func testPlaceholderThatTurnsOutDuplicateFoldsIntoExistingTrack() {
        var library = Library()
        library.merge(scan: [file("/a/Song.mp3", id: "x"), file("/drive/Copy.mp3", id: nil, locality: .cloudOnly)])
        XCTAssertEqual(library.tracks.count, 2)
        library.update(id: library.track(contentID: "x")!.id) { $0.endSec = 100 }
        library.merge(scan: [file("/a/Song.mp3", id: "x"), file("/drive/Copy.mp3", id: "x")])
        XCTAssertEqual(library.tracks.count, 1)
        XCTAssertEqual(library.tracks[0].endSec, 100)
        XCTAssertEqual(library.tracks[0].files.count, 2)
    }

    func testFoldedPlaceholderReportsItsReplacement() {
        var library = Library()
        library.merge(scan: [file("/a/Song.mp3", id: "x"), file("/drive/Copy.mp3", id: nil, locality: .cloudOnly)])
        let placeholder = library.tracks.first { $0.contentID == nil }!.id
        let kept = library.track(contentID: "x")!.id
        let replaced = library.merge(scan: [file("/a/Song.mp3", id: "x"), file("/drive/Copy.mp3", id: "x")])
        XCTAssertEqual(replaced, [placeholder: kept])
    }

    func testSanitizePoints() {
        var track = Track(title: "T", durationSec: 100)
        track.startSec = -4
        track.endSec = -2
        track.sanitizePoints()
        XCTAssertEqual(track.startSec, 0)
        XCTAssertEqual(track.endSec ?? 0, 0.1, accuracy: 1e-9)
        track.startSec = 500
        track.endSec = 50
        track.sanitizePoints()
        XCTAssertLessThan(track.startSec, track.endSec!)
        XCTAssertLessThanOrEqual(track.endSec!, 100)
    }

    func testManagedNamesDoNotCollide() {
        var one = Track(contentID: "aaaaaaaa11", title: "Be Still")
        var two = Track(contentID: "bbbbbbbb22", title: "Be Still")
        one.tags = ["choir"]
        two.tags = ["choir"]
        XCTAssertNotEqual(Materializer.managedFilename(track: one, sourceExtension: "mp3"), Materializer.managedFilename(track: two, sourceExtension: "mp3"))
    }

    func testReplacedFileBecomesANewTrack() {
        var library = Library()
        library.merge(scan: [file("/a/Song.mp3", id: "old")])
        library.merge(scan: [file("/a/Song.mp3", id: "new")])
        XCTAssertEqual(library.tracks.count, 2)
        XCTAssertTrue(library.track(contentID: "old")!.files.isEmpty)
        XCTAssertEqual(library.track(contentID: "new")!.files.count, 1)
    }

    func testPossibleDuplicatesByTitleAndDuration() {
        var library = Library()
        library.merge(scan: [
            file("/a/Amazing Grace 128k_final.mp3", id: "1", duration: 200),
            file("/b/Amazing_Grace_v2.mp3", id: "2", duration: 200.6),
            file("/c/Amazing Grace.mp3", id: "3", duration: 300),
        ])
        let near = library.duplicateGroups.filter { $0.kind == .possible }
        XCTAssertEqual(near.count, 1)
        XCTAssertEqual(near[0].trackIDs.count, 2)
    }

    func testDefaultFadeAppliedToNewTracks() {
        var library = Library()
        library.merge(scan: [file("/a/x.mp3", id: "x")], defaultFadeOutSec: 5)
        XCTAssertEqual(library.tracks[0].fadeOutSec, 5)
    }
}

final class FolderScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func writeWAV(_ name: String, frames: Int = 4800, value: Int16 = 1000) throws {
        var data = Data("RIFF".utf8)
        let bytes = frames * 2
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        data += le32(36 + bytes) + Data("WAVEfmt ".utf8) + le32(16) + le16(1) + le16(1) + le32(48_000) + le32(96_000) + le16(2) + le16(16)
        data += Data("data".utf8) + le32(bytes)
        data += Data((0..<frames).flatMap { _ in withUnsafeBytes(of: value.littleEndian) { Array($0) } })
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: url.path)
    }

    func testFindsAudioRecursivelyAndDedupes() throws {
        try writeWAV("one.wav")
        try writeWAV("sub/copy.wav")
        try writeWAV("sub/other.wav", value: 2000)
        try Data("nope".utf8).write(to: root.appendingPathComponent("notes.txt"))

        var cache = HashCache()
        let result = FolderScanner.scan(roots: [root.path], cache: &cache)
        XCTAssertEqual(result.files.count, 3)
        XCTAssertEqual(Set(result.files.compactMap(\.contentID)).count, 2)
        XCTAssertEqual(result.files[0].sampleRate, 48_000)

        var library = Library()
        library.merge(scan: result.files)
        XCTAssertEqual(library.tracks.count, 2)
    }

    func testFileStillBeingWrittenWaits() throws {
        try writeWAV("fresh.wav")
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: root.appendingPathComponent("fresh.wav").path)
        var cache = HashCache()
        let result = FolderScanner.scan(roots: [root.path], cache: &cache)
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertTrue(result.hasUnsettledFiles)
    }

    func testBrokenFileIsReportedNotFatal() throws {
        let url = root.appendingPathComponent("broken.mp3")
        try Data("junk".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: url.path)
        var cache = HashCache()
        let result = FolderScanner.scan(roots: [root.path], cache: &cache)
        XCTAssertEqual(result.unreadable.count, 1)
    }

    func testCacheAvoidsRehash() throws {
        try writeWAV("one.wav")
        var cache = HashCache()
        _ = FolderScanner.scan(roots: [root.path], cache: &cache)
        let path = cache.entries.keys.first!
        cache.entries[path]?.contentID = "sentinel"
        let second = FolderScanner.scan(roots: [root.path], cache: &cache)
        XCTAssertEqual(second.files[0].contentID, "sentinel")
    }

    func testLocalFileProbe() throws {
        try writeWAV("one.wav")
        XCTAssertEqual(FileLocalityProbe.locality(path: root.appendingPathComponent("one.wav").path), .local)
        XCTAssertEqual(FileLocalityProbe.locality(path: "/no/such/file"), .missing)
    }

    func testDecodeRoundTrip() throws {
        try writeWAV("one.wav", frames: 4800, value: 16384)
        let buffer = try PCMDecoder.decode(url: root.appendingPathComponent("one.wav"))
        XCTAssertEqual(buffer.frames, 4800)
        XCTAssertEqual(buffer.left[100], 0.5, accuracy: 0.001)
        XCTAssertEqual(buffer.left, buffer.right, "mono shares one allocation")
    }
}

final class NormalizerTests: XCTestCase {
    func testMessyFilename() {
        XCTAssertEqual(TitleNormalizer.normalize("Great_Is_Thy_Faithfulness_choir_FINAL_v2 (1).mp3"), ["great", "is", "thy", "faithfulness"])
    }

    func testHintsSurvive() {
        XCTAssertEqual(TitleNormalizer.hints("Alleluia - Choir Track.mp3"), ["choir"])
    }

    func testDiacriticsAndPunctuation() {
        XCTAssertEqual(TitleNormalizer.normalize("Bénédiction: Lord's Prayer"), ["benediction", "lords", "prayer"])
    }

    func testDisplayTitle() {
        XCTAssertEqual(TitleNormalizer.displayTitle(filename: "Be_Still__My_Soul (2).mp3"), "Be Still My Soul")
    }
}

final class SimilarityTests: XCTestCase {
    func testLevenshteinAndJaroBounds() {
        XCTAssertEqual(StringSimilarity.levenshteinRatio("abc", "abc"), 1)
        XCTAssertEqual(StringSimilarity.levenshteinRatio("abc", "xyz"), 0)
        XCTAssertEqual(StringSimilarity.jaroWinkler("martha", "marhta"), 0.961, accuracy: 0.001)
        XCTAssertEqual(StringSimilarity.jaroWinkler("abc", ""), 0)
    }

    func testJaccard() {
        XCTAssertEqual(StringSimilarity.jaccard(["a", "b"], ["b", "c"]), 1.0 / 3, accuracy: 1e-9)
    }

    func testExactTokensScoreOne() {
        XCTAssertEqual(StringSimilarity.score(["be", "still"], ["be", "still"]), 1)
    }
}

final class MatcherTests: XCTestCase {
    private func track(_ filename: String, duration: Double = 240, contentID: String? = nil, tags: [String] = []) -> Track {
        var track = Track(
            contentID: contentID ?? filename, files: [TrackFile(path: "/x/\(filename)", locality: .local)],
            title: TitleNormalizer.displayTitle(filename: filename), durationSec: duration
        )
        track.tags = tags
        return track
    }

    func testFindsMessyFilename() {
        let tracks = [track("Great_Is_Thy_Faithfulness_choir_FINAL_v2 (1).mp3"), track("How Great Thou Art.mp3"), track("Amazing Grace.mp3")]
        let cue = ServiceCue(id: "1", position: 0, title: "Great Is Thy Faithfulness")
        let ranked = Matcher.rank(cue: cue, tracks: tracks, memory: AliasMemory())
        XCTAssertEqual(ranked.first?.trackID, tracks[0].id)
        XCTAssertEqual(MatchBand(candidates: ranked), .proposed)
    }

    func testRunTogetherFilenameAndServiceSlotPrefix() {
        let tracks = [track("BeStill_special_accompaniment.mp3"), track("Amazing Grace.mp3")]
        let ranked = Matcher.rank(cue: ServiceCue(id: "1", position: 0, title: "Offertory Special: Be Still"), tracks: tracks, memory: AliasMemory())
        XCTAssertEqual(ranked.first?.trackID, tracks[0].id)
        XCTAssertEqual(MatchBand(candidates: ranked), .proposed)
    }

    func testLowercaseRunTogetherName() {
        let tracks = [track("bestill.mp3")]
        let ranked = Matcher.rank(cue: ServiceCue(id: "1", position: 0, title: "Be Still"), tracks: tracks, memory: AliasMemory())
        XCTAssertEqual(ranked.first?.trackID, tracks[0].id)
    }

    func testUnrelatedFileScoresNoMatch() {
        let cue = ServiceCue(id: "1", position: 0, title: "Holy Holy Holy")
        let ranked = Matcher.rank(cue: cue, tracks: [track("Amazing Grace.mp3")], memory: AliasMemory())
        XCTAssertNotEqual(MatchBand(candidates: ranked), .proposed)
    }

    func testRememberedConfirmationBeatsString() {
        let tracks = [track("Choir Anthem Easter.mp3", contentID: "abc"), track("Offertory.mp3", contentID: "def")]
        var cue = ServiceCue(id: "1", position: 0, title: "Offertory", songID: "77")
        var memory = AliasMemory()
        memory.remember(cue, contentID: "abc")
        cue.id = "2"
        let ranked = Matcher.rank(cue: cue, tracks: tracks, memory: memory)
        XCTAssertEqual(ranked.first?.trackID, tracks[0].id)
        XCTAssertEqual(ranked.first?.source, .remembered)
    }

    func testMemorySurvivesTitleChangeThroughSongID() {
        let tracks = [track("anything.mp3", contentID: "abc")]
        var memory = AliasMemory()
        memory.remember(ServiceCue(id: "1", position: 0, title: "Old Name", songID: "77"), contentID: "abc")
        let ranked = Matcher.rank(cue: ServiceCue(id: "2", position: 0, title: "New Name", songID: "77"), tracks: tracks, memory: memory)
        XCTAssertEqual(ranked.first?.source, .remembered)
    }

    func testAttachmentFilenameIsStrongSignal() {
        let tracks = [track("xyz123.mp3")]
        var cue = ServiceCue(id: "1", position: 0, title: "Totally Different")
        cue.attachmentFilenames = ["XYZ123.mp3"]
        XCTAssertEqual(Matcher.rank(cue: cue, tracks: tracks, memory: AliasMemory()).first?.source, .attachment)
    }

    func testDurationMismatchLowersScoreAndFlags() {
        let matching = track("Be Still.mp3", duration: 200, contentID: "a")
        let long = track("Be Still.mp3", duration: 400, contentID: "b")
        var cue = ServiceCue(id: "1", position: 0, title: "Be Still")
        cue.lengthSec = 200
        let ranked = Matcher.rank(cue: cue, tracks: [long, matching], memory: AliasMemory())
        XCTAssertEqual(ranked.first?.trackID, matching.id)
        XCTAssertEqual(ranked.last?.durationMismatch, true)
    }

    func testChoirHintBreaksTie() {
        let plain = track("Alleluia congregation.mp3", contentID: "a")
        let choir = track("Alleluia congregation choir.mp3", contentID: "b")
        let cue = ServiceCue(id: "1", position: 0, title: "Alleluia", arrangement: "Choir")
        XCTAssertEqual(Matcher.rank(cue: cue, tracks: [plain, choir], memory: AliasMemory()).first?.trackID, choir.id)
    }

    func testNeverAssignsATrack() {
        let tracks = [track("Be Still.mp3")]
        let cue = ServiceCue(id: "1", position: 0, title: "Be Still")
        _ = Matcher.rank(cue: cue, tracks: tracks, memory: AliasMemory())
        XCTAssertNil(cue.trackID)
    }

    func testTiebreakBand() {
        let id1 = UUID(), id2 = UUID()
        let close = [
            MatchCandidate(trackID: id1, score: 0.9, source: .string, reason: ""),
            MatchCandidate(trackID: id2, score: 0.86, source: .string, reason: ""),
        ]
        XCTAssertTrue(Matcher.needsTiebreak(close))
        XCTAssertFalse(Matcher.needsTiebreak([MatchCandidate(trackID: id1, score: 0.95, source: .string, reason: "")]))
        XCTAssertTrue(Matcher.needsTiebreak([MatchCandidate(trackID: id1, score: 0.6, source: .string, reason: "")]))
        XCTAssertFalse(Matcher.needsTiebreak([MatchCandidate(trackID: id1, score: 0.3, source: .string, reason: "")]))
        XCTAssertFalse(Matcher.needsTiebreak([MatchCandidate(trackID: id1, score: 0.6, source: .remembered, reason: "")]))
    }

    func testBandRequiresMargin() {
        let close = [
            MatchCandidate(trackID: UUID(), score: 0.9, source: .string, reason: ""),
            MatchCandidate(trackID: UUID(), score: 0.88, source: .string, reason: ""),
        ]
        XCTAssertEqual(MatchBand(candidates: close), .likely)
        XCTAssertEqual(MatchBand(candidates: []), .none)
    }
}

final class LLMTiebreakerTests: XCTestCase {
    private func cue() -> (ServiceCue, [UUID: Track]) {
        let a = Track(contentID: "a", files: [TrackFile(path: "/Users/someone/Drive/Pat Smith/one.mp3", locality: .local)], title: "One", durationSec: 200)
        let b = Track(contentID: "b", files: [TrackFile(path: "/Users/someone/two.mp3", locality: .local)], title: "Two", durationSec: 210)
        var cue = ServiceCue(id: "9", position: 0, title: "Song", notes: "ask Pat Smith", arrangement: "Choir")
        cue.candidates = [
            MatchCandidate(trackID: a.id, score: 0.7, source: .string, reason: "s"),
            MatchCandidate(trackID: b.id, score: 0.65, source: .string, reason: "s"),
        ]
        return (cue, [a.id: a, b.id: b])
    }

    func testRequestContainsNoPathsOrNotes() throws {
        let (cue, tracks) = cue()
        let body = String(decoding: try LLMTiebreaker.requestBody(model: "m", cues: [cue], tracks: tracks), as: UTF8.self)
        XCTAssertFalse(body.contains("/Users"))
        XCTAssertFalse(body.contains("Pat Smith"))
        XCTAssertTrue(body.contains("one.mp3"))
    }

    func testRequestShape() throws {
        let (cue, tracks) = cue()
        let body = try JSONSerialization.jsonObject(with: LLMTiebreaker.requestBody(model: "claude-opus-5-5", cues: [cue], tracks: tracks)) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertNil(body["thinking"])
        XCTAssertNil(body["temperature"])
        let config = body["output_config"] as! [String: Any]
        XCTAssertEqual(config["effort"] as? String, "low")
        XCTAssertEqual((config["format"] as! [String: Any])["type"] as? String, "json_schema")
    }

    func testParsesResponse() throws {
        let text = #"{\"results\":[{\"item_id\":\"9\",\"chosen_index\":1,\"confidence\":0.9,\"reason\":\"same song\"},{\"item_id\":\"8\",\"chosen_index\":null,\"confidence\":0.1,\"reason\":\"none\"}]}"#
        let data = Data(#"{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":""},{"type":"text","text":"\#(text)"}]}"#.utf8)
        let verdicts = try LLMTiebreaker.parse(data)
        XCTAssertEqual(verdicts.count, 2)
        XCTAssertEqual(verdicts[0].chosenIndex, 1)
        XCTAssertNil(verdicts[1].chosenIndex)
    }

    func testRefusalIsAnError() {
        XCTAssertThrowsError(try LLMTiebreaker.parse(Data(#"{"stop_reason":"refusal","content":[]}"#.utf8))) {
            XCTAssertEqual($0 as? LLMError, .refused)
        }
    }

    func testBlendReordersButNeverPassesCeiling() {
        let (cue, _) = cue()
        let blended = LLMTiebreaker.blend(
            candidates: cue.candidates, verdict: .init(cueID: "9", chosenIndex: 1, confidence: 1, reason: "same")
        )
        XCTAssertEqual(blended.first?.trackID, cue.candidates[1].trackID)
        XCTAssertEqual(blended.first?.source, .llm)
        XCTAssertEqual(blended.first?.score ?? 0, 0.79, accuracy: 0.001)
        XCTAssertLessThan(blended.first?.score ?? 1, 0.98)
    }

    func testNullVerdictLowersEverything() {
        let (cue, _) = cue()
        let blended = LLMTiebreaker.blend(candidates: cue.candidates, verdict: .init(cueID: "9", chosenIndex: nil, confidence: 0.9, reason: ""))
        XCTAssertLessThan(blended[0].score, cue.candidates[0].score)
    }
}
