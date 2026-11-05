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

    func testStreamedHashIsUnchanged() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Known SHA-256 of these bytes, so saved hash caches stay valid.
        let wav = folder.appendingPathComponent("a.wav")
        try audio.write(to: wav)
        XCTAssertEqual(try ContentHasher.contentID(url: wav), "d67c656e01756650d77717b0839985a056ec28ffe174601d690fc407a2ceffca")

        var footer = Data("APETAGEX".utf8) + Data([0xD0, 0x07, 0, 0, 40, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0]) + Data(repeating: 0, count: 8)
        footer = Data(repeating: 0x55, count: 8) + footer
        let trailer = Data("TAG".utf8) + Data(repeating: 0x20, count: 125)
        let mp3 = folder.appendingPathComponent("a.mp3")
        try (id3v2(payloadSize: 20) + id3v2(payloadSize: 9000) + audio + footer + trailer).write(to: mp3)
        XCTAssertEqual(try ContentHasher.contentID(url: mp3), ContentHasher.contentID(data: audio, isMP3: true))

        // Larger than one read, so the chunks have to join up.
        let big = Data((0..<3_000_000).map { UInt8($0 * 7 % 256) })
        let bigURL = folder.appendingPathComponent("big.mp3")
        try (id3v2(payloadSize: 100) + big).write(to: bigURL)
        XCTAssertEqual(try ContentHasher.contentID(url: bigURL), "0a5d49e5dd9cc7aa647824dc6f29fbbbffe477e210f5668eed4420c51c381521")
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

    func testCantatorsOwnCopyIsNotADuplicate() {
        var library = Library()
        library.merge(scan: [file("/a/Song.mp3", id: "x"), file(ManagedFolder.path + "/Song [choir] x.mp3", id: "x")])
        XCTAssertEqual(library.tracks[0].files.count, 2)
        XCTAssertTrue(library.duplicateGroups.isEmpty)

        library.merge(scan: [file("/a/Song.mp3", id: "x"), file(ManagedFolder.path + "/Song [choir] x.mp3", id: "x"), file("/b/Song.mp3", id: "x")])
        XCTAssertEqual(library.duplicateGroups.first?.kind, .sameAudio)
        library.merge(scan: [file(ManagedFolder.path + "/Song [choir] x.mp3", id: "x"), file(ManagedFolder.path + "/Song [choir] x 2.mp3", id: "x")])
        XCTAssertEqual(library.duplicateGroups.first?.kind, .sameAudio, "two copies in ~/Music/Cantor are one too many")
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

    func testFilesTheScanCouldNotSeeKeepTheirState() {
        var library = Library()
        library.merge(scan: [file("/a/Unsettled.mp3", id: "x"), file("/a/Broken.mp3", id: "y"), file("/drive/Song.mp3", id: "z")])
        let gaps = ScanGaps(paths: ["/a/Unsettled.mp3", "/a/Broken.mp3"], folders: ["/drive"])
        library.merge(scan: [], gaps: gaps)
        XCTAssertTrue(library.tracks.allSatisfy { $0.files[0].locality == .local })
        library.merge(scan: [])
        XCTAssertTrue(library.tracks.allSatisfy { $0.files[0].locality == .missing })
    }

    func testFailedFolderDoesNotCoverASiblingWithTheSamePrefix() {
        XCTAssertTrue(ScanGaps(folders: ["/drive"]).contains("/drive/a.mp3"))
        XCTAssertFalse(ScanGaps(folders: ["/drive"]).contains("/drive2/a.mp3"))
    }

    func testMovedPlaceholderKeepsItsTrack() {
        var library = Library()
        library.merge(scan: [file("/drive/A/Song.mp3", id: nil, locality: .cloudOnly, duration: 0)])
        let id = library.tracks[0].id
        library.update(id: id) { $0.endSec = 120 }
        library.merge(scan: [file("/drive/B/Song.mp3", id: nil, locality: .cloudOnly, duration: 0)])
        XCTAssertEqual(library.tracks.count, 1)
        XCTAssertEqual(library.tracks[0].id, id)
        XCTAssertEqual(library.tracks[0].endSec, 120)
        XCTAssertEqual(library.tracks[0].files, [TrackFile(path: "/drive/B/Song.mp3", locality: .cloudOnly)])
    }

    func testPlaceholderMoveIsOnlyFollowedWhenUnambiguous() {
        var library = Library()
        library.merge(scan: [
            file("/drive/A/Song.mp3", id: nil, locality: .cloudOnly, duration: 0),
            file("/drive/B/Song.mp3", id: nil, locality: .cloudOnly, duration: 0),
            file("/drive/A/Other.mp3", id: nil, locality: .cloudOnly, duration: 0),
        ])
        // Two of the same name went away, and Other was renamed, so none can be told apart.
        library.merge(scan: [
            file("/drive/C/Song.mp3", id: nil, locality: .cloudOnly, duration: 0),
            file("/drive/A/Renamed.mp3", id: nil, locality: .cloudOnly, duration: 0),
        ])
        XCTAssertEqual(library.tracks.count, 5)
        XCTAssertEqual(library.tracks.filter { $0.files.allSatisfy { $0.locality == .missing } }.count, 3)
    }

    func testPlaceholderInAFailedFolderIsNotTreatedAsMoved() {
        var library = Library()
        library.merge(scan: [file("/drive/A/Song.mp3", id: nil, locality: .cloudOnly, duration: 0)])
        library.merge(scan: [file("/other/Song.mp3", id: nil, locality: .cloudOnly, duration: 0)], gaps: ScanGaps(folders: ["/drive"]))
        XCTAssertEqual(library.tracks.count, 2)
        XCTAssertEqual(library.tracks[0].files[0].path, "/drive/A/Song.mp3")
        XCTAssertEqual(library.tracks[0].files[0].locality, .cloudOnly)
    }

    func testNumberedTitlesAreNotDuplicates() {
        var library = Library()
        library.merge(scan: [file("/a/Psalm 23.mp3", id: "1"), file("/a/Psalm 91.mp3", id: "2")])
        XCTAssertTrue(library.duplicateGroups.isEmpty)
    }

    func testManagedNamesStayUnderTheLimit() {
        let track = Track(contentID: "abcdef1234", title: String(repeating: "é", count: 300))
        let name = Materializer.managedFilename(track: track, sourceExtension: "mp3")
        XCTAssertLessThanOrEqual(name.utf8.count, 255)
        XCTAssertTrue(name.hasSuffix(" abcdef12.mp3"))
        XCTAssertFalse(Materializer.managedFilename(track: Track(contentID: "x", title: ".hidden"), sourceExtension: "mp3").hasPrefix("."))
    }

    func testManagedCopyNeedsTheFolderItself() {
        let sibling = Track(contentID: "x", files: [TrackFile(path: "/Music/Cantor Old/a.mp3", locality: .local)], title: "a")
        XCTAssertNil(Materializer.managedCopy(of: sibling, managedPath: "/Music/Cantor"))
        let inside = Track(contentID: "x", files: [TrackFile(path: "/Music/Cantor/a.mp3", locality: .local)], title: "a")
        XCTAssertEqual(Materializer.managedCopy(of: inside, managedPath: "/Music/Cantor")?.path, "/Music/Cantor/a.mp3")
    }

    func testDefaultFadeAppliedToNewTracks() {
        var library = Library()
        library.merge(scan: [file("/a/x.mp3", id: "x")], defaultFadeOutSec: 5)
        XCTAssertEqual(library.tracks[0].fadeOutSec, 5)
    }
}

// MARK: Review 3, finding 6: merge speed

/// The merge as it was before it used lookup tables, kept as a reference for what the faster
/// one must still do.
private extension Library {
    mutating func referenceMerge(scan: [ScannedFile], gaps: ScanGaps = ScanGaps(), defaultFadeOutSec: Double = 3) -> [UUID: UUID] {
        var replaced: [UUID: UUID] = [:]
        let scannedPaths = Set(scan.map(\.path))
        let known = Set(tracks.flatMap { $0.files.map(\.path) })
        let appeared = Dictionary(grouping: scan.filter { $0.contentID == nil && $0.locality == .cloudOnly && !known.contains($0.path) }) {
            URL(fileURLWithPath: $0.path).lastPathComponent
        }
        if !appeared.isEmpty {
            var vanished: [String: [(track: Int, file: Int)]] = [:]
            for index in tracks.indices {
                for fileIndex in tracks[index].files.indices {
                    let file = tracks[index].files[fileIndex]
                    guard file.locality == .cloudOnly, !scannedPaths.contains(file.path), !gaps.contains(file.path) else { continue }
                    vanished[file.filename, default: []].append((index, fileIndex))
                }
            }
            for (name, arrivals) in appeared where arrivals.count == 1 {
                guard let gone = vanished[name], gone.count == 1 else { continue }
                tracks[gone[0].track].files[gone[0].file].path = arrivals[0].path
            }
        }
        for index in tracks.indices {
            for fileIndex in tracks[index].files.indices {
                let path = tracks[index].files[fileIndex].path
                guard !scannedPaths.contains(path), !gaps.contains(path) else { continue }
                tracks[index].files[fileIndex].locality = .missing
            }
        }
        func apply(_ file: ScannedFile, to index: Int, entry: TrackFile) {
            if let fileIndex = tracks[index].files.firstIndex(where: { $0.path == file.path }) {
                tracks[index].files[fileIndex] = entry
            } else {
                tracks[index].files.append(entry)
            }
            if file.durationSec > 0 {
                tracks[index].durationSec = file.durationSec
                tracks[index].sampleRate = file.sampleRate
                tracks[index].channels = file.channels
            }
        }
        for file in scan {
            let entry = TrackFile(path: file.path, locality: file.locality)
            if let contentID = file.contentID {
                let holder = tracks.firstIndex { $0.files.contains { $0.path == file.path } }
                if let holder, tracks[holder].contentID == nil {
                    if let existing = track(contentID: contentID) {
                        replaced[tracks[holder].id] = existing.id
                    } else {
                        tracks[holder].contentID = contentID
                        apply(file, to: holder, entry: entry)
                        continue
                    }
                }
                for index in tracks.indices where tracks[index].contentID != contentID {
                    tracks[index].files.removeAll { $0.path == file.path }
                }
                if let index = tracks.firstIndex(where: { $0.contentID == contentID }) {
                    apply(file, to: index, entry: entry)
                } else {
                    var track = Track(
                        contentID: contentID, files: [entry], title: TitleNormalizer.displayTitle(filename: entry.filename),
                        durationSec: file.durationSec, sampleRate: file.sampleRate, channels: file.channels
                    )
                    track.fadeOutSec = defaultFadeOutSec
                    tracks.append(track)
                }
            } else if let index = tracks.firstIndex(where: { $0.files.contains { $0.path == file.path } }) {
                apply(file, to: index, entry: entry)
            } else {
                var track = Track(files: [entry], title: TitleNormalizer.displayTitle(filename: entry.filename))
                track.fadeOutSec = defaultFadeOutSec
                tracks.append(track)
            }
        }
        tracks.removeAll { $0.contentID == nil && $0.files.isEmpty }
        return replaced
    }
}

final class LibraryMergeSpeedTests: XCTestCase {
    /// What a merge leaves, without the random ids new tracks get.
    private func shape(_ library: Library, _ replaced: [UUID: UUID]) -> [String] {
        let position = Dictionary(uniqueKeysWithValues: library.tracks.enumerated().map { ($1.id, $0) })
        let tracks = library.tracks.map { "\($0.contentID ?? "-") \($0.title) \($0.durationSec) \($0.files.map { "\($0.path):\($0.locality)" })" }
        let moves = replaced.map { "\(position[$0.key].map(String.init) ?? "gone")->\(position[$0.value].map(String.init) ?? "gone")" }.sorted()
        return tracks + moves
    }

    func testFastMergeMatchesTheReference() {
        var generator = SystemRandomNumberGenerator()
        for round in 0..<200 {
            var fast = Library(), reference = Library()
            for _ in 0..<6 {
                // Few paths and contents, so they collide: moves, duplicates, downloads, vanishings.
                let scan: [ScannedFile] = (0..<Int.random(in: 0...12, using: &generator)).map { _ in
                    let local = Bool.random(using: &generator)
                    let folder = ["a", "b", "c"].randomElement(using: &generator)!
                    let name = ["One", "Two", "Three", "Four"].randomElement(using: &generator)!
                    return ScannedFile(
                        path: "/\(folder)/\(name).mp3", locality: local ? .local : .cloudOnly,
                        contentID: local ? ["x", "y", "z", "w"].randomElement(using: &generator)! : nil,
                        durationSec: local ? Double.random(in: 100...300, using: &generator).rounded() : 0, sampleRate: 48_000, channels: 2
                    )
                }
                var seen = Set<String>()
                let unique = scan.filter { seen.insert($0.path).inserted }
                let gaps = Bool.random(using: &generator) ? ScanGaps(folders: ["/c"]) : ScanGaps()
                // Same starting ids on both sides, so their results compare directly.
                reference.tracks = fast.tracks
                let a = fast.merge(scan: unique, gaps: gaps)
                let b = reference.referenceMerge(scan: unique, gaps: gaps)
                XCTAssertEqual(shape(fast, a), shape(reference, b), "round \(round)")
                if shape(fast, a) != shape(reference, b) { return }
            }
        }
    }

    func testLargeLibraryMergesQuickly() {
        let scan = (0..<10_000).map { index in
            ScannedFile(path: "/Drive/Folder \(index / 50)/Stem \(index).wav", locality: .local, contentID: "c\(index)", durationSec: 200, sampleRate: 48_000, channels: 2)
        }
        var library = Library()
        library.merge(scan: scan)
        // A rescan where nothing changed: the old merge took about 6 s here in a Release build.
        let start = Date()
        library.merge(scan: scan)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        XCTAssertEqual(library.tracks.count, 10_000)
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

    private func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
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

    // Review 3, finding 9.
    func testFutureDatedFileIsNotTreatedAsBeingWritten() throws {
        try writeWAV("from abroad.wav")
        let future = Date(timeIntervalSinceNow: 5 * 3600)
        try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: root.appendingPathComponent("from abroad.wav").path)
        var cache = HashCache()
        let result = FolderScanner.scan(roots: [root.path], cache: &cache)
        XCTAssertFalse(result.hasUnsettledFiles, "no rescan every few seconds")
        XCTAssertEqual(result.files.count, 1)
    }

    func testBrokenFileIsReportedNotFatal() throws {
        let url = root.appendingPathComponent("broken.mp3")
        try Data("junk".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: url.path)
        var cache = HashCache()
        let result = FolderScanner.scan(roots: [root.path], cache: &cache)
        XCTAssertEqual(result.unreadable.count, 1)
    }

    func testSkippedFilesAndFailedFoldersAreReportedAsGaps() throws {
        try writeWAV("fresh.wav")
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: root.appendingPathComponent("fresh.wav").path)
        let broken = root.appendingPathComponent("broken.mp3")
        try Data("junk".utf8).write(to: broken)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: broken.path)
        let missingRoot = root.appendingPathComponent("not-there").path

        var cache = HashCache()
        let result = FolderScanner.scan(roots: [root.path, missingRoot], cache: &cache)
        // The scan reports paths with symlinks resolved, as in /private/var.
        let listed = URL(fileURLWithPath: realPath(root))
        XCTAssertTrue(result.gaps.contains(listed.appendingPathComponent("fresh.wav").path))
        XCTAssertTrue(result.gaps.contains(listed.appendingPathComponent("broken.mp3").path))
        XCTAssertTrue(result.gaps.contains(missingRoot + "/Song.mp3"))
        XCTAssertFalse(result.gaps.contains(listed.appendingPathComponent("gone.wav").path))
    }

    func testUnreadableSubfolderIsAGap() throws {
        let locked = root.appendingPathComponent("sub")
        try writeWAV("sub/one.wav")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        var cache = HashCache()
        let result = FolderScanner.scan(roots: [root.path], cache: &cache)
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertTrue(result.gaps.contains(realPath(locked) + "/one.wav"))
    }

    func testSymlinkedAudioIsReadThroughItsTarget() throws {
        try writeWAV("sub/one.wav")
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("link.wav").path, withDestinationPath: root.appendingPathComponent("sub/one.wav").path
        )
        var cache = HashCache()
        let result = FolderScanner.scan(roots: [root.path], cache: &cache)
        let link = try XCTUnwrap(result.files.first { $0.path.hasSuffix("/link.wav") })
        XCTAssertEqual(link.locality, .local)
        XCTAssertEqual(link.contentID, result.files.first { $0.path.hasSuffix("/one.wav") }?.contentID)
        XCTAssertEqual(link.sampleRate, 48_000)
    }

    func testMakeLocalCopyIsVerifiedAndSwappedIntoPlace() throws {
        try writeWAV("one.wav")
        let destination = root.appendingPathComponent("managed/One abc.wav")
        let file = try Materializer.copyAndVerify(from: root.appendingPathComponent("one.wav"), to: destination)
        XCTAssertEqual(file.path, destination.path)
        // A second copy replaces the first, and no partial file is left behind.
        _ = try Materializer.copyAndVerify(from: root.appendingPathComponent("one.wav"), to: destination)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path), ["One abc.wav"])
    }

    // Review 3, finding 10.
    func testMakeLocalCopiesTheAudioBehindALink() throws {
        try writeWAV("one.wav")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("links"), withIntermediateDirectories: true)
        let link = root.appendingPathComponent("links/One.wav")
        // Relative, as Finder aliases made in Terminal often are.
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../one.wav")
        let destination = root.appendingPathComponent("managed/One abc.wav")
        _ = try Materializer.copyAndVerify(from: link, to: destination)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular, "a real file, not a link")
        try FileManager.default.removeItem(at: root.appendingPathComponent("one.wav"))
        XCTAssertNotNil(PCMDecoder.info(url: destination), "still plays once the original is gone")
    }

    func testMakeLocalRemovesACopyThatDoesNotVerify() throws {
        let junk = root.appendingPathComponent("junk.mp3")
        try Data(repeating: 0x55, count: 5000).write(to: junk)
        let destination = root.appendingPathComponent("managed/Junk abc.mp3")
        XCTAssertThrowsError(try Materializer.copyAndVerify(from: junk, to: destination))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path), [])
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

    func testTitleNumbersSkipTrackNumbersVersionsAndBitrates() {
        XCTAssertEqual(TitleNormalizer.titleNumbers("Psalm 23"), ["23"])
        XCTAssertEqual(TitleNormalizer.titleNumbers("01 - Psalm 23 v2 128k (1).mp3"), ["23"])
        XCTAssertEqual(TitleNormalizer.titleNumbers("Track 03 Way Maker 2019.mp3"), [])
        XCTAssertEqual(TitleNormalizer.titleNumbers("03 Way Maker.mp3"), [])
        XCTAssertTrue(TitleNormalizer.numbersConflict("Psalm 23", "Psalm 91.mp3"))
        XCTAssertFalse(TitleNormalizer.numbersConflict("Psalm 23", "02 Psalm 023.mp3"))
        XCTAssertFalse(TitleNormalizer.numbersConflict("Way Maker", "03 Way Maker.mp3"))
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

    func testNumberedTitlesDoNotMatchEachOther() {
        let psalm91 = track("Psalm 91.mp3"), psalm23 = track("01 - Psalm 23 choir 320k.mp3")
        let ranked = Matcher.rank(cue: ServiceCue(id: "1", position: 0, title: "Psalm 23"), tracks: [psalm91, psalm23], memory: AliasMemory())
        XCTAssertEqual(ranked.first?.trackID, psalm23.id)
        XCTAssertEqual(MatchBand(candidates: ranked), .proposed)
        let other = ranked.first { $0.trackID == psalm91.id }?.score ?? 0
        XCTAssertLessThan(other, 0.85)

        let hymn2 = track("Hymn 2.mp3")
        let alone = Matcher.rank(cue: ServiceCue(id: "2", position: 0, title: "Hymn 1"), tracks: [hymn2], memory: AliasMemory())
        XCTAssertNotEqual(MatchBand(candidates: alone), .proposed)
        XCTAssertLessThan(alone.first?.score ?? 0, 0.85)
    }

    func testLeadingTrackNumberStillMatches() {
        let tracks = [track("03 Way Maker.mp3")]
        let ranked = Matcher.rank(cue: ServiceCue(id: "1", position: 0, title: "Way Maker"), tracks: tracks, memory: AliasMemory())
        XCTAssertEqual(ranked.first?.score ?? 0, 0.97, accuracy: 0.001)
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

    // Review 3, release blocker: a file remembered for one song went onto another.
    func testRememberedFileStaysWithItsOwnSong() {
        let x = track("Psalm 23 Choir.mp3", contentID: "x")
        var memory = AliasMemory()
        memory.remember(ServiceCue(id: "1", position: 0, title: "Psalm 23", songID: "100"), contentID: "x")

        // Another song whose title differs only by number gets nothing from memory.
        let psalm91 = ServiceCue(id: "2", position: 0, title: "Psalm 91", songID: "200")
        XCTAssertFalse(Matcher.rank(cue: psalm91, tracks: [x], memory: memory).contains { $0.source == .remembered || $0.source == .rememberedTitle })
        // Nor does one with no song attached.
        let untagged = ServiceCue(id: "3", position: 0, title: "Psalm 91")
        XCTAssertNil(memory.contentID(for: untagged))

        // An item with a song is matched by its song alone, not by a shared title.
        let sameTitleOtherSong = ServiceCue(id: "4", position: 0, title: "Psalm 23", songID: "300")
        XCTAssertNil(memory.contentID(for: sameTitleOtherSong))
    }

    func testGenericTitlesHaveNoMemory() {
        var memory = AliasMemory()
        let special = ServiceCue(id: "1", position: 0, title: "Choir Special")
        memory.remember(special, contentID: "x")
        memory.rememberNeeds(special, needed: true)
        XCTAssertEqual(AliasMemory.keys(for: special), [], "nothing is left of the title to key by")
        XCTAssertNil(memory.contentID(for: ServiceCue(id: "2", position: 0, title: "Special")))
        XCTAssertNil(memory.needsOverride(for: ServiceCue(id: "3", position: 0, title: "Solo")))
    }

    func testTitleOnlyMemoryIsOfferedButNeverConfirmsItself() {
        let x = track("Last Week.mp3", contentID: "x")
        var memory = AliasMemory()
        memory.remember(ServiceCue(id: "1", position: 0, title: "Special Music"), contentID: "x")
        let nextWeek = ServiceCue(id: "2", position: 0, title: "Special Music", needsPlayback: true)
        let ranked = Matcher.rank(cue: nextWeek, tracks: [x], memory: memory)
        XCTAssertEqual(ranked.first?.source, .rememberedTitle)

        var service = ServicePlan(id: "p", serviceTypeID: "1", serviceTypeName: "Sunday", title: "", dates: "", sortDate: nil)
        var cue = nextWeek
        cue.candidates = ranked
        service.cues = [cue]
        XCTAssertEqual(service.autoConfirmStrongMatches(), 0)
        XCTAssertNil(service.cues[0].trackID)
    }

    func testRememberedNeedsStayWithTheirSong() {
        var memory = AliasMemory()
        memory.rememberNeeds(ServiceCue(id: "1", position: 0, title: "Psalm 23", songID: "100"), needed: false)
        XCTAssertNil(memory.needsOverride(for: ServiceCue(id: "2", position: 0, title: "Psalm 91", songID: "200")))
        XCTAssertEqual(memory.needsOverride(for: ServiceCue(id: "3", position: 0, title: "Psalm 23 (renamed)", songID: "100")), false)
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
    struct FakeRunner: ClaudeRunner {
        var output: String
        func run(system: String, prompt: String, schema: String, model: String) async throws -> Data { Data(output.utf8) }
    }

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

    func testPromptContainsNoPathsOrNotes() throws {
        let (cue, tracks) = cue()
        let prompt = try LLMTiebreaker.prompt(cues: [cue], tracks: tracks)
        XCTAssertFalse(prompt.contains("/Users"))
        XCTAssertFalse(prompt.contains("Pat Smith"))
        XCTAssertTrue(prompt.contains("one.mp3"))
    }

    func testSchemaIsValidJSON() throws {
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(LLMTiebreaker.schema.utf8)))
    }

    func testReadsStructuredOutput() throws {
        let output = #"{"type":"result","is_error":false,"result":"","structured_output":{"results":[{"item_id":"9","chosen_index":1,"confidence":0.9,"reason":"same song"},{"item_id":"8","chosen_index":null,"confidence":0.1,"reason":"none"}]}}"#
        let verdicts = try LLMTiebreaker.parse(Data(output.utf8))
        XCTAssertEqual(verdicts.count, 2)
        XCTAssertEqual(verdicts[0].chosenIndex, 1)
        XCTAssertNil(verdicts[1].chosenIndex)
    }

    func testResolveReordersThroughRunner() async throws {
        let (cue, tracks) = cue()
        let output = #"{"is_error":false,"structured_output":{"results":[{"item_id":"9","chosen_index":1,"confidence":1,"reason":"same"}]}}"#
        let result = try await LLMTiebreaker(runner: FakeRunner(output: output)).resolve(cues: [cue], tracks: tracks)
        XCTAssertEqual(result["9"]?.first?.trackID, cue.candidates[1].trackID)
    }

    func testSignedOutIsReported() {
        // The exact output Claude Code printed when signed out.
        let output = #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}"#
        XCTAssertThrowsError(try LLMTiebreaker.parse(Data(output.utf8))) {
            XCTAssertEqual($0 as? LLMError, .notLoggedIn)
        }
    }

    func testUsageLimitIsReported() {
        let output = #"{"is_error":true,"result":"You've hit your usage limit"}"#
        XCTAssertThrowsError(try LLMTiebreaker.parse(Data(output.utf8))) {
            XCTAssertEqual($0 as? LLMError, .limitReached)
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

    func testConfidenceIsReadAsPercentOrClamped() {
        XCTAssertEqual(LLMTiebreaker.confidence(85), 0.85, accuracy: 1e-9)
        XCTAssertEqual(LLMTiebreaker.confidence(0.4), 0.4, accuracy: 1e-9)
        XCTAssertEqual(LLMTiebreaker.confidence(1.2), 1)
        XCTAssertEqual(LLMTiebreaker.confidence(3), 1)
        XCTAssertEqual(LLMTiebreaker.confidence(500), 1)
        XCTAssertEqual(LLMTiebreaker.confidence(-3), 0)
        XCTAssertEqual(LLMTiebreaker.confidence(nil), 0)
        let output = #"{"is_error":false,"structured_output":{"results":[{"item_id":"9","chosen_index":1,"confidence":85,"reason":"x"}]}}"#
        XCTAssertEqual(try LLMTiebreaker.parse(Data(output.utf8)).first?.confidence ?? 0, 0.85, accuracy: 1e-9)
    }

    func testOutOfRangeChoiceLeavesCandidatesAlone() async throws {
        let (cue, tracks) = cue()
        let output = #"{"is_error":false,"structured_output":{"results":[{"item_id":"9","chosen_index":7,"confidence":0.9,"reason":"x"}]}}"#
        let result = try await LLMTiebreaker(runner: FakeRunner(output: output)).resolve(cues: [cue], tracks: tracks)
        XCTAssertNil(result["9"])
        XCTAssertEqual(LLMTiebreaker.blend(candidates: cue.candidates, verdict: .init(cueID: "9", chosenIndex: -1, confidence: 1, reason: "")), cue.candidates)
    }

    func testOnlyUsageLimitsCountAsLimitReached() {
        func error(_ message: String) -> LLMError? {
            let output = try! JSONSerialization.data(withJSONObject: ["is_error": true, "result": message])
            do { _ = try LLMTiebreaker.parse(output) } catch { return error as? LLMError }
            return nil
        }
        XCTAssertEqual(error("Claude AI usage limit reached|1700000000"), .limitReached)
        XCTAssertEqual(error("5-hour limit reached \u{2219} resets 3pm"), .limitReached)
        XCTAssertEqual(error("Weekly limit reached"), .limitReached)
        XCTAssertEqual(error("Output token limit exceeded"), .failed("Output token limit exceeded"))
        XCTAssertEqual(error("Context limit reached"), .failed("Context limit reached"))
    }

    func testNullVerdictLowersEverything() {
        let (cue, _) = cue()
        let blended = LLMTiebreaker.blend(candidates: cue.candidates, verdict: .init(cueID: "9", chosenIndex: nil, confidence: 0.9, reason: ""))
        XCTAssertLessThan(blended[0].score, cue.candidates[0].score)
    }
}

final class ClaudeCLITests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    /// A stand-in for the claude binary. It records what it was given.
    private func script(_ body: String) throws -> String {
        let url = directory.appendingPathComponent("claude")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func testFindsNewestDesktopAppCopy() throws {
        let files = FileManager.default
        XCTAssertNil(ClaudeCLI.desktopAppCopy(in: directory))
        for version in ["2.1.9", "2.1.10"] {
            let folder = directory.appendingPathComponent("\(version)/abc123/claude.app/Contents/MacOS")
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            let binary = folder.appendingPathComponent("claude")
            try Data("#!/bin/sh\n".utf8).write(to: binary)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        // An update still unpacking, with no binary yet, is skipped.
        try files.createDirectory(at: directory.appendingPathComponent("2.2.0/def456"), withIntermediateDirectories: true)
        XCTAssertEqual(ClaudeCLI.desktopAppCopy(in: directory), directory.appendingPathComponent("2.1.10/abc123/claude.app/Contents/MacOS/claude").path)
    }

    func testPrefersAVerifiedDesktopAppCopyAndIgnoresOddFolders() throws {
        let files = FileManager.default
        func install(_ relative: String, verified: Bool) throws {
            let folder = directory.appendingPathComponent("\(relative)/claude.app/Contents/MacOS")
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            let binary = folder.appendingPathComponent("claude")
            try Data("#!/bin/sh\n".utf8).write(to: binary)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            if verified { try Data().write(to: directory.appendingPathComponent("\(relative)/.verified")) }
        }
        try install("2.1.9/aaa", verified: true)
        try install("2.1.10/bbb", verified: false)
        try install("latest/ccc", verified: true)
        try install("2.2.0-beta/ddd", verified: true)
        XCTAssertEqual(ClaudeCLI.desktopAppCopy(in: directory), directory.appendingPathComponent("2.1.9/aaa/claude.app/Contents/MacOS/claude").path,
                       "a newer build still being written loses to a verified one")
        try files.removeItem(at: directory.appendingPathComponent("2.1.9"))
        XCTAssertEqual(ClaudeCLI.desktopAppCopy(in: directory), directory.appendingPathComponent("2.1.10/bbb/claude.app/Contents/MacOS/claude").path,
                       "with nothing verified, an unmarked build still counts")
    }

    func testArgumentsDisableToolsAndNeverUseBareMode() {
        let arguments = ClaudeCLI.arguments(system: "s", schema: "{}", model: "")
        let tools = try! XCTUnwrap(arguments.firstIndex(of: "--tools"))
        XCTAssertEqual(arguments[tools + 1], "")
        XCTAssertTrue(arguments.contains("--strict-mcp-config"))
        XCTAssertTrue(arguments.contains("--no-session-persistence"))
        XCTAssertFalse(arguments.contains("--bare"), "bare mode skips the account login")
        XCTAssertFalse(arguments.contains("--model"))
        XCTAssertTrue(ClaudeCLI.arguments(system: "s", schema: "{}", model: "sonnet").contains("sonnet"))
    }

    func testAPICredentialsAreRemoved() {
        let environment = ClaudeCLI.environment(from: ["ANTHROPIC_API_KEY": "x", "ANTHROPIC_AUTH_TOKEN": "y", "ANTHROPIC_BASE_URL": "z", "HOME": "/h"])
        XCTAssertEqual(environment, ["HOME": "/h"])
    }

    func testOtherProvidersAreRemoved() {
        let environment = ClaudeCLI.environment(from: [
            "CLAUDE_CODE_USE_BEDROCK": "1", "CLAUDE_CODE_USE_VERTEX": "1", "ANTHROPIC_CUSTOM_HEADERS": "x", "ANTHROPIC_MODEL": "m",
            "ANTHROPIC_SMALL_FAST_MODEL": "m", "AWS_BEARER_TOKEN_BEDROCK": "t", "PATH": "/bin",
        ])
        XCTAssertEqual(environment, ["PATH": "/bin"])
    }

    func testHungProcessIsKilledAndTheCallReturns() async throws {
        // Ignores SIGTERM, and leaves a child holding stdout open after it is killed.
        let path = try script("trap '' TERM; sleep 30 & sleep 30")
        let started = Date()
        do {
            _ = try await ClaudeCLI(path: path, timeout: 1).run(system: "s", prompt: "", schema: "{}", model: "")
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? LLMError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1 + ClaudeCLI.killGraceSec + ClaudeCLI.drainGraceSec + 3)
    }

    func testRunsProcessWithPromptOnStdin() async throws {
        let log = directory.appendingPathComponent("stdin.txt").path
        let path = try script(#"cat > "\#(log)"; echo '{"is_error":false}'"#)
        let output = try await ClaudeCLI(path: path).run(system: "s", prompt: "hello", schema: "{}", model: "")
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "{\"is_error\":false}\n")
        XCTAssertEqual(try String(contentsOfFile: log, encoding: .utf8), "hello")
    }

    func testFailureOutputIsStillReturnedForTheReason() async throws {
        let path = try script(#"echo '{"is_error":true,"result":"Not logged in"}'; exit 1"#)
        let output = try await ClaudeCLI(path: path).run(system: "s", prompt: "", schema: "{}", model: "")
        XCTAssertThrowsError(try LLMTiebreaker.parse(output))
    }

    func testProcessThatExitsWithoutReadingDoesNotKillTheApp() async throws {
        let path = try script("exit 3")
        do {
            _ = try await ClaudeCLI(path: path).run(system: "s", prompt: String(repeating: "x", count: 200_000), schema: "{}", model: "")
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? LLMError, .failed("Claude Code exited with status 3."))
        }
    }

    func testMissingBinary() async {
        do {
            _ = try await ClaudeCLI(path: "/no/such/claude").run(system: "", prompt: "", schema: "{}", model: "")
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? LLMError, .notInstalled)
        }
    }

    func testAccountStatusRefusesAPIKey() async throws {
        let path = try script(#"echo '{"loggedIn":true,"authMethod":"apiKey"}'"#)
        let status = try await ClaudeCLI(path: path).accountStatus()
        XCTAssertTrue(status.isLoggedIn)
        XCTAssertTrue(status.usesAPIKey)
        XCTAssertFalse(ClaudeAccountStatus(isLoggedIn: true, authMethod: "claude.ai").usesAPIKey)
    }
}
