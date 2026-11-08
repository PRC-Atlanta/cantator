import XCTest
@testable import CantorCore

final class DuplicateDetectorTests: XCTestCase {
    private func track(_ path: String, _ seconds: Double = 200, locality: FileLocality = .local) -> Track {
        Track(files: [TrackFile(path: path, locality: locality)], title: TitleNormalizer.displayTitle(filename: URL(fileURLWithPath: path).lastPathComponent), durationSec: seconds)
    }

    func testCopiesOfAFileKeepOne() {
        let wav = track("/Drive/Choir/Way Maker.wav", 300.00)
        let mp3 = track("/Downloads/Way Maker.mp3", 300.05)
        let again = track("/Downloads/Way Maker (1).mp3", 300.04)
        let numbered = track("/Drive/Old/03 Way Maker copy.mp3", 300.02)
        let reasons = DuplicateDetector.detect(tracks: [mp3, again, wav, numbered])
        XCTAssertNil(reasons[wav.id], "the WAV stays")
        XCTAssertEqual(reasons[mp3.id], "Duplicate of “Way Maker.wav” in Choir")
        XCTAssertNotNil(reasons[again.id])
        XCTAssertNotNil(reasons[numbered.id])
    }

    func testVersionsAndDifferentLengthsAreNotCopies() {
        let mix = track("/Drive/Song/Holy Forever - Full Mix.mp3", 280)
        let instrumental = track("/Drive/Song/Holy Forever - Instrumental.mp3", 280)
        let inG = track("/Drive/Song/Holy Forever (Key of G).mp3", 280)
        let inA = track("/Drive/Song/Holy Forever (Key of A).mp3", 280)
        let short = track("/Drive/Short/Holy Forever - Full Mix.mp3", 200)
        let psalm23 = track("/Drive/Psalms/Psalm 23.mp3", 150)
        let psalm91 = track("/Drive/Psalms/Psalm 91.mp3", 150)
        XCTAssertTrue(DuplicateDetector.detect(tracks: [mix, instrumental, inG, inA, short, psalm23, psalm91]).isEmpty)
    }

    func testTheCopyWithWorkOnItOrInAServiceStays() {
        var worked = track("/Downloads/Amazing Grace.mp3", 200)
        worked.endSec = 190
        let wav = track("/Drive/Amazing Grace.wav", 200)
        XCTAssertNotNil(DuplicateDetector.detect(tracks: [worked, wav])[wav.id])

        let used = track("/Downloads/Be Still.mp3", 180)
        let lossless = track("/Drive/Be Still.wav", 180)
        let reasons = DuplicateDetector.detect(tracks: [used, lossless], protected: [used.id])
        XCTAssertNil(reasons[used.id])
        XCTAssertNotNil(reasons[lossless.id])
    }

    func testALocalCopyStaysOverOneOnlyInTheCloud() {
        let cloud = track("/Drive/Amazing Grace.wav", 200, locality: .cloudOnly)
        let local = track("/Downloads/Amazing Grace.mp3", 200)
        XCTAssertNotNil(DuplicateDetector.detect(tracks: [cloud, local])[cloud.id])
    }

    func testTheOperatorsChoicesStand() {
        var kept = track("/Downloads/Song.mp3", 200)
        kept.keptByOperator = true
        let wav = track("/Drive/Song.wav", 200)
        var excluded = track("/Drive/Old/Song.wav", 200)
        excluded.exclusion = Exclusion(reason: "You chose Not a Playback", byOperator: true)
        let reasons = DuplicateDetector.detect(tracks: [kept, wav, excluded])
        XCTAssertNil(reasons[kept.id])
        XCTAssertNotNil(reasons[wav.id], "the kept copy is the one that stays")
        XCTAssertNil(reasons[excluded.id])
    }

    func testLibraryBringsACopyBackWhenTheOtherGoes() {
        var library = Library(tracks: [track("/Drive/Song.wav", 200), track("/Downloads/Song.mp3", 200)])
        let mp3 = library.tracks[1].id
        XCTAssertTrue(library.excludeStems(protecting: []))
        XCTAssertEqual(library.track(id: mp3)?.exclusion?.byOperator, false)
        XCTAssertEqual(library.playbackTracks.count, 1)

        library.tracks.removeFirst()
        XCTAssertTrue(library.excludeStems(protecting: []))
        XCTAssertNil(library.track(id: mp3)?.exclusion)
    }

    func testAStemNeverStandsInForThePlayback() {
        let click = track("/Drive/Song/Song - Click.wav", 200)
        let playback = track("/Drive/Song/Song.mp3", 200)
        var library = Library(tracks: [click, playback])
        library.excludeStems(protecting: [])
        XCTAssertEqual(library.track(id: click.id)?.exclusion?.reason, "Name says Click")
        XCTAssertNil(library.track(id: playback.id)?.exclusion)
    }

    private func placeholder(_ path: String, bytes: Int64?, seconds: Double = 0, locality: FileLocality = .cloudOnly) -> Track {
        Track(files: [TrackFile(path: path, locality: locality, sizeBytes: bytes)], title: TitleNormalizer.displayTitle(filename: URL(fileURLWithPath: path).lastPathComponent), durationSec: seconds)
    }

    func testCopiesNotDownloadedMatchByName() {
        let songs = placeholder("/Drive/Songs/There Is a King/06_There is a King-Split.mp3", bytes: 11_894_491)
        let andreea = placeholder("/Drive/Andreea/There Is a King/06_There is a King-Split.mp3", bytes: 11_894_491)
        let easter = placeholder("/Drive/Easter 2025/There Is a King/06_There is a King-Split.mp3", bytes: 11_894_491)
        let reasons = DuplicateDetector.detect(tracks: [songs, andreea, easter])
        XCTAssertEqual(reasons.count, 2, "one copy stays")
        XCTAssertNil(reasons[andreea.id], "the first path settles a tie")
    }

    func testACopyOnThisMacStaysOverOneNotDownloaded() {
        let desktop = placeholder("/Desktop/Playbacks/Chiar si acolo in vale.mp3", bytes: 8_889_589, seconds: 222.22, locality: .local)
        let drive = placeholder("/Drive/Old Playbacks/Chiar si acolo in vale.mp3", bytes: 8_889_589)
        let reasons = DuplicateDetector.detect(tracks: [drive, desktop])
        XCTAssertNil(reasons[desktop.id])
        XCTAssertEqual(reasons[drive.id], "Duplicate of “Chiar si acolo in vale.mp3” in Playbacks")
    }

    func testACopyWithEditedTagsIsStillACopy() {
        let desktop = placeholder("/Desktop/Playbacks/ALL THE PRAISE-Stereo.mp3", bytes: 11_630_901, seconds: 386.41, locality: .local)
        let drive = placeholder("/Drive/Numai Tu/ALL THE PRAISE-Stereo.mp3", bytes: 11_628_672)
        XCTAssertNotNil(DuplicateDetector.detect(tracks: [desktop, drive])[drive.id])
    }

    func testANotDownloadedFileOfAnotherSizeOrNoSizeIsNotACopy() {
        let edit = placeholder("/Drive/A/Canta Cerul.mp3", bytes: 9_016_022)
        let other = placeholder("/Drive/B/Canta Cerul.mp3", bytes: 7_500_000)
        let unknown = placeholder("/Drive/C/Canta Cerul.mp3", bytes: nil)
        let local = placeholder("/Desktop/Canta Cerul.mp3", bytes: 6_000_000, seconds: 217.5, locality: .local)
        XCTAssertTrue(DuplicateDetector.detect(tracks: [edit, other, unknown, local]).isEmpty)
    }

    func testAScanRecordsEachFilesSize() {
        var library = Library()
        library.merge(scan: [ScannedFile(path: "/Drive/Song.mp3", locality: .cloudOnly, contentID: nil, sizeBytes: 1234)])
        XCTAssertEqual(library.tracks.first?.files.first?.sizeBytes, 1234)
    }

    func testNameKeyDropsWhatACopyAdds() {
        XCTAssertEqual(DuplicateDetector.nameKey("01 Way Maker (2).mp3"), "way maker")
        XCTAssertEqual(DuplicateDetector.nameKey("Way_Maker - Copy.wav"), "way maker")
        XCTAssertEqual(DuplicateDetector.nameKey("Way Maker 320kbps.mp3"), "way maker")
        XCTAssertEqual(DuplicateDetector.nameKey("Psalm 23.mp3"), "psalm 23")
    }
}
