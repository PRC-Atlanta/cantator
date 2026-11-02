import XCTest
@testable import CantorCore

final class StemDetectorTests: XCTestCase {
    private func track(_ path: String, _ seconds: Double = 200) -> Track {
        Track(files: [TrackFile(path: path, locality: .local)], title: TitleNormalizer.displayTitle(filename: URL(fileURLWithPath: path).lastPathComponent), durationSec: seconds)
    }

    func testStrongWordsAndStemFoldersExcludeOnTheirOwn() {
        let click = track("/Music/Choir/Amazing Grace - Click.wav", 210)
        let bgv = track("/Music/Choir/Amazing Grace BGVs.wav", 215)
        let inFolder = track("/Music/Choir/Amazing Grace Stems/Track 3.wav", 220)
        let playback = track("/Music/Choir/Amazing Grace.wav", 230)
        let reasons = StemDetector.detect(tracks: [click, bgv, inFolder, playback])
        XCTAssertEqual(reasons[click.id], "Name says Click")
        XCTAssertEqual(reasons[bgv.id], "Name says Bgvs")
        XCTAssertEqual(reasons[inFolder.id], "In a folder named Amazing Grace Stems")
        XCTAssertNil(reasons[playback.id])
    }

    func testOnlyNearbyFoldersCount() {
        let nested = track("/Music/Stems/Way Maker/Way Maker.wav")
        let distant = track("/Music/Old Stems/Choir/November/Be Still.wav")
        let reasons = StemDetector.detect(tracks: [nested, distant])
        XCTAssertEqual(reasons[nested.id], "In a folder named Stems")
        XCTAssertNil(reasons[distant.id])
    }

    func testMultiTracksIsAStemWordHoweverItIsWritten() {
        let camel = track("/Music/Choir/Way Maker MultiTracks/Bass.wav", 210)
        let spaced = track("/Music/Choir/Multi Tracks/Way Maker/Keys.wav", 220)
        let file = track("/Music/Choir/Way Maker - MultiTracks.wav", 230)
        let plain = track("/Music/Choir/Multitracks/Organ.wav", 240)
        let reasons = StemDetector.detect(tracks: [camel, spaced, file, plain])
        XCTAssertEqual(reasons[camel.id], "In a folder named Way Maker MultiTracks")
        XCTAssertEqual(reasons[spaced.id], "In a folder named Multi Tracks")
        XCTAssertEqual(reasons[file.id], "Name says Multitracks")
        XCTAssertEqual(reasons[plain.id], "In a folder named Multitracks")
        XCTAssertTrue(StemDetector.detect(tracks: [track("/Music/Choir/Multiply Track Joy.wav")]).isEmpty)
    }

    func testWeakWordsNeedASameLengthSet() {
        // A hymn title with "Guide" and a piano accompaniment on their own stay in.
        let hymn = track("/Music/Special/Guide Me O Thou Great Jehovah.wav", 180)
        let piano = track("/Music/Special/Be Still Piano.wav", 150)
        XCTAssertTrue(StemDetector.detect(tracks: [hymn, piano]).isEmpty)
    }

    func testSameLengthSetExcludesStemsButKeepsTheMix() {
        let folder = "/Music/Choir/Way Maker"
        let mix = track("\(folder)/Way Maker - Full Mix.wav", 300.02)
        let bass = track("\(folder)/Way Maker - Bass.wav", 300.0)
        let keys = track("\(folder)/Way Maker - Keys.wav", 300.05)
        let numbered = track("\(folder)/Way Maker 07.wav", 300.01)
        let other = track("\(folder)/Another Song.wav", 260)
        let reasons = StemDetector.detect(tracks: [mix, bass, keys, numbered, other])
        XCTAssertNil(reasons[mix.id])
        XCTAssertEqual(reasons[bass.id], "Name says Bass, one of 4 files the same length")
        XCTAssertNotNil(reasons[keys.id])
        XCTAssertEqual(reasons[numbered.id], "One of 4 files the same length as stems in Way Maker")
        XCTAssertNil(reasons[other.id])
    }

    func testVersionsOfAMixAreNotStems() {
        let folder = "/Music/Special"
        let tracks = [
            track("\(folder)/Holy Forever (Key of G).wav"), track("\(folder)/Holy Forever (Key of A).wav"),
            track("\(folder)/Holy Forever No BGVs.wav"), track("\(folder)/Holy Forever with Vocals.wav"),
        ]
        XCTAssertTrue(StemDetector.detect(tracks: tracks).isEmpty)
    }

    func testKeptConfirmedAndExcludedTracksAreLeftAlone() {
        var kept = track("/Music/Choir/Song - Click.wav")
        kept.keptByOperator = true
        let confirmed = track("/Music/Choir/Song - Drums.wav")
        var excluded = track("/Music/Choir/Song - Snare.wav")
        excluded.exclusion = Exclusion(reason: "You chose Not a Playback", byOperator: true)
        XCTAssertTrue(StemDetector.detect(tracks: [kept, confirmed, excluded], protected: [confirmed.id]).isEmpty)
    }

    func testLibraryKeepsAndExcludes() {
        var library = Library(tracks: [track("/Music/Choir/Song - Click.wav", 100), track("/Music/Choir/Song.wav", 120)])
        let click = library.tracks[0].id, song = library.tracks[1].id
        XCTAssertTrue(library.excludeStems(protecting: []))
        XCTAssertEqual(library.playbackTracks.map(\.id), [song])
        XCTAssertEqual(library.track(id: click)?.exclusion?.byOperator, false)

        library.keep(id: click)
        XCTAssertFalse(library.excludeStems(protecting: []))
        XCTAssertEqual(library.playbackTracks.count, 2)

        library.exclude(id: song)
        XCTAssertEqual(library.excludedTracks.map(\.id), [song])
        XCTAssertEqual(library.track(id: song)?.exclusion?.byOperator, true)
    }

    func testDetectedExclusionClearsWhenTheSetBreaksUp() {
        let folder = "/Music/Choir/Way Maker"
        var library = Library(tracks: [
            track("\(folder)/Way Maker - Full Mix.wav"), track("\(folder)/Way Maker - Bass.wav"), track("\(folder)/Way Maker - Keys.wav"),
        ])
        let bass = library.tracks[1].id
        library.excludeStems(protecting: [])
        XCTAssertNotNil(library.track(id: bass)?.exclusion)

        library.tracks.removeLast()
        XCTAssertTrue(library.excludeStems(protecting: []))
        XCTAssertNil(library.track(id: bass)?.exclusion)
    }

    func testOlderLibraryWithoutExclusionStillLoads() throws {
        let json = #"{"tracks":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"Old","files":[]}]}"#
        let library = try JSONDecoder().decode(Library.self, from: Data(json.utf8))
        XCTAssertNil(library.tracks[0].exclusion)
        XCTAssertFalse(library.tracks[0].keptByOperator)

        var track = library.tracks[0]
        track.exclusion = Exclusion(reason: "Name says Click", byOperator: false)
        let decoded = try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(track))
        XCTAssertEqual(decoded.exclusion, track.exclusion)
    }
}
