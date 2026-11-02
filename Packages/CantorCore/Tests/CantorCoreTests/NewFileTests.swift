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

    func testMovedPlaceholderIsNotNew() {
        var existing = Library()
        let old = ScannedFile(path: "/Drive/Choir/A/Song.mp3", locality: .cloudOnly, contentID: nil, addedDate: watchStart.addingTimeInterval(-10))
        existing.merge(scan: [old])
        let moved = ScannedFile(path: "/Drive/Choir/B/Song.mp3", locality: .cloudOnly, contentID: nil, addedDate: watchStart.addingTimeInterval(500))
        let (library, ids) = detect([moved], existing: existing)
        XCTAssertTrue(ids.isEmpty)
        XCTAssertEqual(library.tracks.count, 1)
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
        // Without roots, account and home folder names are still left out.
        XCTAssertEqual(NewFileFacts.folder(of: "/Users/me/Library/CloudStorage/GoogleDrive-me@example.com/My Drive/a.mp3", home: "/Users/me"), "My Drive")
        XCTAssertEqual(NewFileFacts.folder(of: "/Users/me/Downloads/a.mp3", home: "/Users/me"), "Downloads")
    }

    func testFolderStaysInsideTheWatchedFolder() {
        let drive = "/Users/me/Library/CloudStorage/GoogleDrive-me@example.com/My Drive"
        let roots = [drive, "/Users/me/Downloads", "/Users/me/Library/CloudStorage/GoogleDrive-me@example.com", "/Users/me"]
        func folder(_ path: String) -> String { NewFileFacts.folder(of: path, roots: roots, home: "/Users/me") }

        XCTAssertEqual(folder("\(drive)/song.mp3"), "My Drive")
        XCTAssertEqual(folder("/Users/me/Downloads/song.mp3"), "Downloads")
        XCTAssertEqual(folder("\(drive)/Choir/song.mp3"), "My Drive/Choir")
        XCTAssertEqual(folder("\(drive)/Choir/2026/Nov/song.mp3"), "2026/Nov")
        // The account folder or home folder as a root is not sent, and neither is an email address below it.
        XCTAssertEqual(folder("/Users/me/Library/CloudStorage/GoogleDrive-me@example.com/Shared/song.mp3"), "Shared")
        XCTAssertEqual(folder("/Users/me/song.mp3"), "")
        XCTAssertEqual(folder("\(drive)/from pat@example.com/song.mp3"), "My Drive")
        XCTAssertEqual(folder("/Elsewhere/Choir/song.mp3"), "")
        XCTAssertEqual(NewFileFacts.folder(of: "/Users/me/Downloads2/a.mp3", roots: ["/Users/me/Downloads"], home: "/Users/me"), "")

        for path in ["\(drive)/song.mp3", "/Users/me/Downloads/song.mp3", "\(drive)/Choir/2026/Nov/song.mp3"] {
            XCTAssertFalse(folder(path).contains("@"))
            XCTAssertFalse(folder(path).contains("GoogleDrive"))
            XCTAssertFalse(folder(path).split(separator: "/").contains("me"))
        }
    }

    func testFailedBatchKeepsEarlierAnswers() async throws {
        final class FailingSecondRunner: ClaudeRunner, @unchecked Sendable {
            var calls = 0
            func run(system: String, prompt: String, schema: String, model: String) async throws -> Data {
                calls += 1
                guard calls == 1 else { throw LLMError.limitReached }
                let results = (0..<FileClassifier.batchSize).map {
                    #"{"file_id":"f\#($0)","is_playback":true,"title":"T","category":"choir","service_item_id":null,"confidence":0.5,"reason":""}"#
                }
                return Data(#"{"structured_output":{"results":[\#(results.joined(separator: ","))]}}"#.utf8)
            }
        }
        let files = (0..<(FileClassifier.batchSize + 3)).map { NewFileFacts(trackID: UUID(), filename: "\($0).mp3", folder: "", durationSec: 0) }
        let (partial, error) = await FileClassifier(runner: FailingSecondRunner()).classifyKeepingPartial(files: files, categories: [], upcoming: [])
        XCTAssertEqual(partial.count, FileClassifier.batchSize)
        XCTAssertEqual(error as? LLMError, .limitReached)
        let kept = try await FileClassifier(runner: FailingSecondRunner()).classify(files: files, categories: [], upcoming: [])
        XCTAssertEqual(kept.count, FileClassifier.batchSize)

        final class AlwaysFailing: ClaudeRunner {
            func run(system: String, prompt: String, schema: String, model: String) async throws -> Data { throw LLMError.timedOut }
        }
        do {
            _ = try await FileClassifier(runner: AlwaysFailing()).classify(files: files, categories: [], upcoming: [])
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? LLMError, .timedOut)
        }
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

final class ClaudeConnectionTests: XCTestCase {
    func testErrorsMapToWhatTheOperatorCanFix() {
        XCTAssertEqual(ClaudeConnection(error: LLMError.notLoggedIn), .signedOut)
        XCTAssertEqual(ClaudeConnection(error: LLMError.notInstalled), .notInstalled)
        XCTAssertEqual(ClaudeConnection(error: LLMError.usesAPIKey), .usesAPIKey)
        XCTAssertEqual(ClaudeConnection(error: LLMError.limitReached), .limitReached)
        XCTAssertEqual(ClaudeConnection(error: LLMError.timedOut), .unavailable(LLMError.timedOut.localizedDescription))
        XCTAssertEqual(ClaudeConnection(error: CocoaError(.fileNoSuchFile)), .unavailable(CocoaError(.fileNoSuchFile).localizedDescription))
    }

    func testOnlyFixableStatesAskForAttention() {
        XCTAssertFalse(ClaudeConnection.connected.needsAttention)
        XCTAssertFalse(ClaudeConnection.off.needsAttention)
        XCTAssertFalse(ClaudeConnection.checking.needsAttention)
        XCTAssertTrue(ClaudeConnection.signedOut.needsAttention)
        XCTAssertTrue(ClaudeConnection.signedOut.detail.contains("claude auth login"))
        XCTAssertTrue(ClaudeConnection.connected.isConnected)
    }
}

final class ClaudeConnectionHintTests: XCTestCase {
    func testEveryProblemHasAShortHint() {
        let problems: [ClaudeConnection] = [.notInstalled, .signedOut, .usesAPIKey, .limitReached, .unavailable("x")]
        for problem in problems {
            XCTAssertLessThanOrEqual(problem.hint?.count ?? 99, 36, "\(problem)")
        }
        XCTAssertNil(ClaudeConnection.connected.hint)
    }
}

final class ClaudeUsageSummaryTests: XCTestCase {
    func testSummarySaysWhetherClaudeIsUsedAndWhy() {
        XCTAssertTrue(ClaudeConnection.connected.usageSummary.contains("filed by Claude"))
        XCTAssertEqual(ClaudeConnection.signedOut.usageSummary, "Claude Code is signed out, so new files are guessed from their names, and matching works by name.")
        XCTAssertTrue(ClaudeConnection.limitReached.usageSummary.hasPrefix("Your Claude usage limit"))
        XCTAssertTrue(ClaudeConnection.off.usageSummary.contains("turned off"))
        XCTAssertTrue(ClaudeConnection.usesAPIKey.usageSummary.contains("API key"))
    }
}
