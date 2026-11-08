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

    func testNameKeyDropsWhatACopyAdds() {
        XCTAssertEqual(DuplicateDetector.nameKey("01 Way Maker (2).mp3"), "way maker")
        XCTAssertEqual(DuplicateDetector.nameKey("Way_Maker - Copy.wav"), "way maker")
        XCTAssertEqual(DuplicateDetector.nameKey("Way Maker 320kbps.mp3"), "way maker")
        XCTAssertEqual(DuplicateDetector.nameKey("Psalm 23.mp3"), "psalm 23")
    }
}
