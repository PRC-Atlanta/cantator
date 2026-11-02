import XCTest
@testable import CantorCore

final class NewFileDetectorTests: XCTestCase {
    private let watchStart = Date(timeIntervalSince1970: 1_000_000)

    private func scanned(_ path: String, id: String, added: Date?) -> ScannedFile {
        ScannedFile(path: path, locality: .local, contentID: id, durationSec: 200, sampleRate: 48_000, channels: 2, addedDate: added)
    }

    private func detect(_ scan: [ScannedFile], existing: Library = Library(), since: [String: Date]? = nil) -> (Library, [UUID]) {
        var library = existing
        let previous = Set(library.tracks.map(\.id))
        library.merge(scan: scan)
        let ids = NewFileDetector.newTrackIDs(
            previousIDs: previous, tracks: library.tracks, scan: scan, watchedSince: since ?? ["/Drive/Choir": watchStart]
        )
        return (library, ids)
    }

    func testFileArrivingAfterWatchStartIsNew() {
        let (library, ids) = detect([scanned("/Drive/Choir/Be Still.mp3", id: "a", added: watchStart.addingTimeInterval(60))])
        XCTAssertEqual(ids, library.tracks.map(\.id))
    }

    func testFilesAlreadyThereWhenFolderWasAddedAreNotNew() {
        let (_, ids) = detect([scanned("/Drive/Choir/Old.mp3", id: "a", added: watchStart.addingTimeInterval(-3600))])
        XCTAssertTrue(ids.isEmpty)
    }

    func testFileFoundAfterRelaunchIsStillNew() {
        // Arrived while the app was closed: the library has never seen it, and it came after the watch began.
        var existing = Library()
        existing.merge(scan: [scanned("/Drive/Choir/Old.mp3", id: "a", added: watchStart.addingTimeInterval(-10))])
        let scan = [
            scanned("/Drive/Choir/Old.mp3", id: "a", added: watchStart.addingTimeInterval(-10)),
            scanned("/Drive/Choir/New.mp3", id: "b", added: watchStart.addingTimeInterval(86_400)),
        ]
        let (library, ids) = detect(scan, existing: existing)
        XCTAssertEqual(ids, [library.track(contentID: "b")!.id])
    }

    func testAnotherCopyOfKnownAudioIsNotNew() {
        var existing = Library()
        existing.merge(scan: [scanned("/Drive/Choir/Song.mp3", id: "a", added: watchStart.addingTimeInterval(-10))])
        let scan = [
            scanned("/Drive/Choir/Song.mp3", id: "a", added: watchStart.addingTimeInterval(-10)),
            scanned("/Drive/Choir/Song copy.mp3", id: "a", added: watchStart.addingTimeInterval(100)),
        ]
        XCTAssertTrue(detect(scan, existing: existing).1.isEmpty)
    }

    func testUnwatchedFolderAndUnknownDateAreNotNew() {
        XCTAssertTrue(detect([scanned("/Elsewhere/Song.mp3", id: "a", added: Date())]).1.isEmpty)
        XCTAssertTrue(detect([scanned("/Drive/Choir/Song.mp3", id: "a", added: nil)]).1.isEmpty)
    }

    func testNestedFolderUsesItsOwnStart() {
        let since = ["/Drive": watchStart, "/Drive/Choir": watchStart.addingTimeInterval(1000)]
        let scan = [scanned("/Drive/Choir/Song.mp3", id: "a", added: watchStart.addingTimeInterval(500))]
        XCTAssertTrue(detect(scan, since: since).1.isEmpty)
    }

    func testSiblingFolderWithSharedPrefixIsNotMatched() {
        let scan = [scanned("/Drive/Choir Archive/Song.mp3", id: "a", added: watchStart.addingTimeInterval(500))]
        XCTAssertTrue(detect(scan).1.isEmpty)
    }

    func testStampingStartsNewFoldersAndForgetsRemovedOnes() {
        var settings = AppSettings()
        settings.folders = ["/A"]
        settings.watchedSince = ["/A": watchStart, "/Gone": watchStart]
        settings.folders.append("/B")
        let now = watchStart.addingTimeInterval(50)
        settings.stampWatchedFolders(now: now)
        XCTAssertEqual(settings.watchedSince, ["/A": watchStart, "/B": now])
    }
}

final class NewFileInboxTests: XCTestCase {
    func testAddIgnoresDuplicatesAndKeepsOrder() {
        let a = UUID(), b = UUID()
        var inbox = NewFileInbox()
        inbox.add([a, b])
        inbox.add([a])
        XCTAssertEqual(inbox.items.map(\.trackID), [a, b])
        XCTAssertEqual(inbox.awaitingSuggestion.count, 2)
        inbox.setSuggestion(FileSuggestion(title: "A", category: "choir"), for: a)
        XCTAssertEqual(inbox.ready.map(\.trackID), [a])
    }

    func testReconcileDropsFoldedAndRemovedTracks() {
        let kept = UUID(), folded = UUID(), gone = UUID()
        var inbox = NewFileInbox()
        inbox.add([kept, folded, gone])
        inbox.reconcile(replaced: [folded: UUID()], existing: [kept, folded])
        XCTAssertEqual(inbox.items.map(\.trackID), [kept])
    }

    func testInboxSurvivesSaving() throws {
        var inbox = NewFileInbox()
        let id = UUID()
        inbox.add([id])
        inbox.setSuggestion(FileSuggestion(title: "Be Still", category: "special", serviceItem: ServiceItemRef(planID: "p", cueID: "c")), for: id)
        let decoded = try JSONDecoder().decode(NewFileInbox.self, from: JSONEncoder().encode(inbox))
        XCTAssertEqual(decoded, inbox)
    }
}

final class InboxGateTests: XCTestCase {
    func testPopUpOnlyWhenNothingIsLoadedOrPlaying() {
        XCTAssertTrue(InboxGate.canPresent(serviceLoaded: false, showState: .idle, showMode: false, auditioning: false, loadingService: false))
        XCTAssertFalse(InboxGate.canPresent(serviceLoaded: true, showState: .idle, showMode: false, auditioning: false, loadingService: false))
        XCTAssertFalse(InboxGate.canPresent(serviceLoaded: false, showState: .live("1"), showMode: false, auditioning: false, loadingService: false))
        XCTAssertFalse(InboxGate.canPresent(serviceLoaded: false, showState: .armed("1"), showMode: false, auditioning: false, loadingService: false))
        XCTAssertFalse(InboxGate.canPresent(serviceLoaded: false, showState: .faulted(nil), showMode: false, auditioning: false, loadingService: false))
        XCTAssertFalse(InboxGate.canPresent(serviceLoaded: false, showState: .idle, showMode: true, auditioning: false, loadingService: false))
        XCTAssertFalse(InboxGate.canPresent(serviceLoaded: false, showState: .idle, showMode: false, auditioning: true, loadingService: false))
        XCTAssertFalse(InboxGate.canPresent(serviceLoaded: false, showState: .idle, showMode: false, auditioning: false, loadingService: true))
    }

    func testClaudeWaitsWhileACueIsEngaged() {
        XCTAssertTrue(InboxGate.canClassify(showState: .idle, showMode: false))
        XCTAssertFalse(InboxGate.canClassify(showState: .live("1"), showMode: false))
        XCTAssertFalse(InboxGate.canClassify(showState: .held("1"), showMode: false))
        XCTAssertFalse(InboxGate.canClassify(showState: .idle, showMode: true))
    }
}

final class FileClassifierTests: XCTestCase {
    struct FakeRunner: ClaudeRunner {
        var output: String
        func run(system: String, prompt: String, schema: String, model: String) async throws -> Data { Data(output.utf8) }
    }

    final class CountingRunner: ClaudeRunner, @unchecked Sendable {
        var prompts: [String] = []
        func run(system: String, prompt: String, schema: String, model: String) async throws -> Data {
            prompts.append(prompt)
            return Data(#"{"structured_output":{"results":[]}}"#.utf8)
        }
    }

    private let file = NewFileFacts(
        trackID: UUID(), filename: "BeStill_special_v2.mp3", folder: "Pat Smith/Specials", durationSec: 241.6,
        tags: ["genre": "Gospel"]
    )
    private let item = UpcomingItem(ref: ServiceItemRef(planID: "p1", cueID: "c7"), service: "November 8, 2026", title: "Offertory Special: Be Still")

    func testPromptCarriesOnlyNamesFoldersAndTitles() throws {
        let prompt = try FileClassifier.prompt(files: [file], categories: ["choir", "special"], upcoming: [item])
        XCTAssertTrue(prompt.contains("BeStill_special_v2.mp3"))
        XCTAssertTrue(prompt.contains("Pat Smith/Specials"))
        XCTAssertTrue(prompt.contains("\"s0\""))
        XCTAssertTrue(prompt.contains("\"duration_seconds\":241"))
        XCTAssertFalse(prompt.contains("/Users"))
        XCTAssertFalse(prompt.contains("p1"))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(FileClassifier.schema.utf8)))
    }

    func testFolderIsLastTwoComponents() {
        XCTAssertEqual(NewFileFacts.folder(of: "/Users/me/Library/CloudStorage/Drive/Choir/Nov/song.mp3"), "Choir/Nov")
    }

    func testParseMapsIdsBack() async throws {
        let output = """
        {"type":"result","is_error":false,"structured_output":{"results":[{"file_id":"f0","is_playback":true,"title":"Be Still",\
        "category":" Special ","service_item_id":"s0","confidence":0.92,"reason":"Title and folder match the offertory special"}]}}
        """
        let result = try await FileClassifier(runner: FakeRunner(output: output)).classify(files: [file], categories: [], upcoming: [item])
        let suggestion = try XCTUnwrap(result[file.trackID])
        XCTAssertEqual(suggestion.title, "Be Still")
        XCTAssertEqual(suggestion.category, "special")
        XCTAssertEqual(suggestion.serviceItem, item.ref)
        XCTAssertTrue(suggestion.byClaude)
    }

    func testUnknownIdsAreIgnored() throws {
        let output = """
        {"structured_output":{"results":[{"file_id":"f9","is_playback":true,"title":"X","category":"choir","service_item_id":null,"confidence":1,"reason":""},\
        {"file_id":"f0","is_playback":false,"title":"","category":"choir","service_item_id":"s4","confidence":3,"reason":""}]}}
        """
        let result = try FileClassifier.parse(Data(output.utf8), files: [file], upcoming: [item])
        XCTAssertEqual(result.count, 1)
        let suggestion = try XCTUnwrap(result[file.trackID])
        XCTAssertNil(suggestion.serviceItem)
        XCTAssertFalse(suggestion.isPlayback)
        XCTAssertEqual(suggestion.confidence, 1)
        XCTAssertEqual(suggestion.title, TitleNormalizer.displayTitle(filename: file.filename))
    }

    func testSignedOutIsReported() {
        let output = #"{"type":"result","is_error":true,"result":"Not logged in · Please run /login"}"#
        XCTAssertThrowsError(try FileClassifier.parse(Data(output.utf8), files: [file], upcoming: [])) {
            XCTAssertEqual($0 as? LLMError, .notLoggedIn)
        }
    }

    func testLargeDropsAreSentInBatches() async throws {
        let runner = CountingRunner()
        let files = (0..<(FileClassifier.batchSize + 3)).map { NewFileFacts(trackID: UUID(), filename: "\($0).mp3", folder: "", durationSec: 0) }
        _ = try await FileClassifier(runner: runner).classify(files: files, categories: [], upcoming: [])
        XCTAssertEqual(runner.prompts.count, 2)
    }

    func testFallbackGuessesFromNameAndFolder() {
        let suggestion = FileClassifier.fallback(file, serviceItem: nil, note: "signed out")
        XCTAssertEqual(suggestion.category, "special")
        XCTAssertFalse(suggestion.byClaude)
        XCTAssertEqual(suggestion.note, "signed out")
        XCTAssertEqual(PlaybackCategory.guess(filename: "Offertory Special - Be Still.mp3", folder: "", tags: [:]), "offertory")
        XCTAssertEqual(PlaybackCategory.guess(filename: "Track 3.mp3", folder: "Sanctuary Choir/Nov", tags: [:]), "choir")
        XCTAssertEqual(PlaybackCategory.guess(filename: "Track 3.mp3", folder: "Downloads", tags: [:]), "")
        XCTAssertEqual(PlaybackCategory.guess(filename: "solo.mp3", folder: "", tags: [:]), "special")
        XCTAssertEqual(PlaybackCategory.guess(filename: "Resolution.mp3", folder: "", tags: [:]), "")
    }

    func testCategoryListAddsLibraryTags() {
        XCTAssertEqual(PlaybackCategory.all(libraryTags: ["choir", "easter"]).last, "easter")
        XCTAssertEqual(PlaybackCategory.display(""), "Uncategorized")
    }

    func testTagCleaningKeepsKnownKeys() {
        XCTAssertEqual(AudioTags.clean(["title": " Be Still ", "genre": "", "approximate duration in seconds": "241", "artist": 5]), ["title": "Be Still"])
    }
}
