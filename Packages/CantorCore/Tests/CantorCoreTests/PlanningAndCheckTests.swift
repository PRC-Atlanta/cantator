import XCTest
@testable import CantorCore

final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (Int, [String: String], Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let (status, headers, data) = Self.responder?(request) ?? (500, [:], Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }
}

final class PCOClientTests: XCTestCase {
    override func setUp() {
        StubProtocol.requests = []
    }

    private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    private func fixture(_ request: URLRequest) -> (Int, [String: String], Data) {
        let url = request.url!.absoluteString
        if url.contains("/attachments") {
            return (200, [:], json(["data": [["id": "a1", "attributes": ["filename": "Anthem_track.mp3"]]]]))
        }
        if url.contains("/plan_times") {
            return (200, [:], json(["data": [
                ["id": "t1", "attributes": ["time_type": "rehearsal", "starts_at": "2026-11-08T13:00:00Z"]],
                ["id": "t2", "attributes": ["time_type": "service", "starts_at": "2026-11-08T15:00:00Z"]],
            ]]))
        }
        if url.contains("/items") {
            return (200, [:], json([
                "data": [
                    ["id": "i1", "attributes": ["title": "Welcome", "item_type": "item", "sequence": 1]],
                    ["id": "i2", "attributes": ["title": "Worship", "item_type": "header", "sequence": 2]],
                    ["id": "i3", "attributes": ["title": "Be Still", "item_type": "song", "sequence": 3, "length": 240,
                                                "html_details": "<p>Choir starts at verse 2</p>"],
                     "relationships": ["song": ["data": ["type": "Song", "id": "s9"]],
                                       "arrangement": ["data": ["type": "Arrangement", "id": "r1"]]]],
                ],
                "included": [
                    ["type": "Song", "id": "s9", "attributes": ["title": "Be Still"]],
                    ["type": "Arrangement", "id": "r1", "attributes": ["name": "Choir SATB"]],
                ],
            ]))
        }
        if url.contains("/plans?") {
            return (200, [:], json(["data": [["id": "p1", "attributes": [
                "title": "Sunday", "dates": "November 8, 2026", "sort_date": "2026-11-08T15:00:00Z",
            ]]]]))
        }
        return (200, [:], json(["data": [["id": "st1", "attributes": ["name": "Traditional"]]]]))
    }

    func testFetchBuildsPlanAndDetectsPlayback() async throws {
        StubProtocol.responder = fixture
        let client = PCOClient(appID: "id", secret: "secret", session: StubProtocol.session(), spacing: .zero)
        let plans = try await client.fetchUpcomingPlans(memory: AliasMemory())

        let plan = try XCTUnwrap(plans.first)
        XCTAssertEqual(plan.serviceTypeName, "Traditional")
        XCTAssertEqual(plan.serviceTimes.count, 1)
        XCTAssertEqual(plan.cues.count, 3)

        let cue = try XCTUnwrap(plan.cues.first { $0.id == "i3" })
        XCTAssertTrue(cue.needsPlayback)
        XCTAssertEqual(cue.arrangement, "Choir SATB")
        XCTAssertEqual(cue.songID, "s9")
        XCTAssertEqual(cue.lengthSec, 240)
        XCTAssertEqual(cue.notes, "Choir starts at verse 2")
        XCTAssertEqual(cue.attachmentFilenames, ["Anthem_track.mp3"])
        XCTAssertNil(cue.trackID, "sync must never confirm a match")

        XCTAssertFalse(plan.cues.first { $0.id == "i1" }!.needsPlayback)
        XCTAssertFalse(plan.cues.first { $0.id == "i2" }!.needsPlayback)
        XCTAssertEqual(plan.playbackCues.map(\.id), ["i3"])
    }

    func testBasicAuthHeader() async throws {
        StubProtocol.responder = fixture
        let client = PCOClient(appID: "id", secret: "secret", session: StubProtocol.session(), spacing: .zero)
        _ = try await client.fetchUpcomingPlans(memory: AliasMemory())
        let expected = "Basic " + Data("id:secret".utf8).base64EncodedString()
        XCTAssertEqual(StubProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), expected)
    }

    func testOperatorOverrideWinsOverDetection() async throws {
        StubProtocol.responder = fixture
        var memory = AliasMemory()
        memory.rememberNeeds(ServiceCue(id: "x", position: 0, title: "Be Still", songID: "s9"), needed: false)
        let client = PCOClient(appID: "id", secret: "secret", session: StubProtocol.session(), spacing: .zero)
        let plans = try await client.fetchUpcomingPlans(memory: memory)
        XCTAssertTrue(plans[0].playbackCues.isEmpty)
    }

    func testUnauthorized() async {
        StubProtocol.responder = { _ in (401, [:], Data()) }
        let client = PCOClient(appID: "id", secret: "bad", session: StubProtocol.session(), spacing: .zero)
        do {
            _ = try await client.fetchUpcomingPlans(memory: AliasMemory())
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? PCOError, .unauthorized)
        }
    }

    func testRetriesAfter429() async throws {
        nonisolated(unsafe) var first = true
        StubProtocol.responder = { [self] request in
            if first {
                first = false
                return (429, ["Retry-After": "0"], Data())
            }
            return fixture(request)
        }
        let client = PCOClient(appID: "id", secret: "secret", session: StubProtocol.session(), spacing: .zero)
        let plans = try await client.fetchUpcomingPlans(memory: AliasMemory())
        XCTAssertEqual(plans.count, 1)
    }

    func testFollowsPagination() async throws {
        StubProtocol.responder = { [self] request in
            let url = request.url!.absoluteString
            if url.hasSuffix("service_types?per_page=100") {
                return (200, [:], json(["data": [["id": "st1", "attributes": ["name": "A"]]],
                                        "links": ["next": PCOClient.base + "/service_types?offset=1"]]))
            }
            if url.hasSuffix("service_types?offset=1") {
                return (200, [:], json(["data": [["id": "st2", "attributes": ["name": "B"]]]]))
            }
            return fixture(request)
        }
        let client = PCOClient(appID: "id", secret: "secret", session: StubProtocol.session(), spacing: .zero)
        let plans = try await client.fetchUpcomingPlans(memory: AliasMemory())
        XCTAssertEqual(Set(plans.map(\.serviceTypeID)), ["st1", "st2"])
    }
}

final class DetectorTests: XCTestCase {
    func testRules() {
        XCTAssertTrue(PlaybackDetector.needsPlayback(ServiceCue(id: "1", position: 0, title: "Special Music")))
        XCTAssertTrue(PlaybackDetector.needsPlayback(ServiceCue(id: "1", position: 0, title: "Anything", itemType: "song")))
        XCTAssertTrue(PlaybackDetector.needsPlayback(ServiceCue(id: "1", position: 0, title: "Offertory", notes: "")))
        XCTAssertFalse(PlaybackDetector.needsPlayback(ServiceCue(id: "1", position: 0, title: "Sermon")))
        XCTAssertFalse(PlaybackDetector.needsPlayback(ServiceCue(id: "1", position: 0, title: "Choir", itemType: "header")))
    }
}

final class PlanMergeTests: XCTestCase {
    private func plan(_ cues: [ServiceCue]) -> ServicePlan {
        ServicePlan(id: "p", serviceTypeID: "s", serviceTypeName: "S", title: "", dates: "", sortDate: nil, cues: cues)
    }

    func testResyncKeepsConfirmationAndFlagsChange() {
        var cue = ServiceCue(id: "1", position: 0, title: "Be Still")
        cue.trackID = UUID()
        let manual = ServiceCue(id: "m", position: 9, title: "Added", isManual: true)
        let fresh = plan([ServiceCue(id: "1", position: 1, title: "Be Still My Soul")])

        let merged = plan([cue, manual]).merging(fresh: fresh)
        XCTAssertEqual(merged.cues.count, 2)
        XCTAssertEqual(merged.cues[0].trackID, cue.trackID)
        XCTAssertEqual(merged.cues[0].position, 1)
        XCTAssertTrue(merged.cues[0].changedSinceConfirm)
    }

    func testSyncKeepsLoadedAndWorkedPlansOnly() {
        let now = Date()
        func make(_ id: String, daysAgo: Double, confirmed: Bool) -> ServicePlan {
            var cue = ServiceCue(id: "c", position: 0, title: "x")
            if confirmed { cue.trackID = UUID() }
            return ServicePlan(id: id, serviceTypeID: "s", serviceTypeName: "S", title: "", dates: "", sortDate: now - daysAgo * 86_400, cues: [cue])
        }
        let existing = [make("loaded", daysAgo: 30, confirmed: false), make("worked", daysAgo: 1, confirmed: true),
                        make("idle", daysAgo: 1, confirmed: false), make("old", daysAgo: 30, confirmed: true)]
        let result = ServicePlan.applySync(existing: existing, fresh: [make("new", daysAgo: -3, confirmed: false)], loadedID: "loaded", now: now)
        XCTAssertEqual(Set(result.map(\.id)), ["loaded", "worked", "new"])
    }

    func testUnchangedStaysUnflagged() {
        var cue = ServiceCue(id: "1", position: 0, title: "Be Still")
        cue.trackID = UUID()
        XCTAssertFalse(plan([cue]).merging(fresh: plan([ServiceCue(id: "1", position: 0, title: "Be Still")])).cues[0].changedSinceConfirm)
    }
}

final class PreServiceCheckTests: XCTestCase {
    private func goodTrack() -> Track {
        var track = Track(files: [TrackFile(path: "/x/a.mp3", locality: .local)], title: "A")
        track.endSec = 100
        track.integratedLUFS = -18
        track.truePeakDb = -6
        return track
    }

    private func input(track: Track?, resident: Bool = true, routing: OutputRouting? = nil, syncedAgo: TimeInterval = 60) -> CheckInput {
        var cue = ServiceCue(id: "c", position: 0, title: "Anthem")
        cue.trackID = track?.id
        let now = Date()
        let plan = ServicePlan(id: "p", serviceTypeID: "s", serviceTypeName: "S", title: "", dates: "", sortDate: nil, syncedAt: now - syncedAgo, cues: [cue])
        return CheckInput(
            plan: plan, tracks: track.map { [$0.id: $0] } ?? [:], residentTrackIDs: resident ? Set([track?.id].compactMap { $0 }) : [],
            routing: routing ?? OutputRouting(houseDeviceUID: "h", cueDeviceUID: "c"), availableDeviceUIDs: ["h", "c"], now: now
        )
    }

    private func kinds(_ input: CheckInput) -> Set<CheckKind> {
        Set(PreServiceCheck.run(input).filter { $0.severity > .ok }.map(\.kind))
    }

    func testCleanServiceHasNoIssues() {
        XCTAssertEqual(kinds(input(track: goodTrack())), [])
    }

    func testUnmatchedCueBlocks() {
        let issues = PreServiceCheck.run(input(track: nil))
        XCTAssertEqual(issues.first?.kind, .unmatched)
        XCTAssertEqual(issues.first?.severity, .blocking)
    }

    func testCloudOnlyIsNotDownloaded() {
        var track = goodTrack()
        track.files = [TrackFile(path: "/drive/a.mp3", locality: .cloudOnly)]
        XCTAssertTrue(kinds(input(track: track, resident: false)).contains(.notDownloaded))
    }

    func testMissingFile() {
        var track = goodTrack()
        track.files = [TrackFile(path: "/gone/a.mp3", locality: .missing)]
        XCTAssertTrue(kinds(input(track: track, resident: false)).contains(.fileMissing))
    }

    func testLocalButNotLoaded() {
        XCTAssertTrue(kinds(input(track: goodTrack(), resident: false)).contains(.notInMemory))
    }

    func testMissingEndPointAndLevel() {
        var track = goodTrack()
        track.endSec = nil
        track.integratedLUFS = nil
        let found = kinds(input(track: track))
        XCTAssertTrue(found.contains(.noEndPoint))
        XCTAssertTrue(found.contains(.notAnalyzed))
    }

    func testCappedGainWarns() {
        var track = goodTrack()
        track.integratedLUFS = -30
        track.truePeakDb = -2
        XCTAssertTrue(kinds(input(track: track)).contains(.gainCapped))
    }

    func testDeviceProblems() {
        XCTAssertTrue(kinds(input(track: goodTrack(), routing: OutputRouting())).contains(.noHouseOutput))
        XCTAssertTrue(kinds(input(track: goodTrack(), routing: OutputRouting(houseDeviceUID: "gone", cueDeviceUID: "c"))).contains(.houseOutputMissing))
        XCTAssertTrue(kinds(input(track: goodTrack(), routing: OutputRouting(houseDeviceUID: "h", cueDeviceUID: "h"))).contains(.sameOutput))
        XCTAssertTrue(kinds(input(track: goodTrack(), routing: OutputRouting(houseDeviceUID: "h"))).contains(.noCueOutput))
    }

    func testStaleSyncAndBattery() {
        var value = input(track: goodTrack(), syncedAgo: 13 * 3600)
        value.isOnBattery = true
        let found = kinds(value)
        XCTAssertTrue(found.contains(.staleSync))
        XCTAssertTrue(found.contains(.onBattery))
    }

    func testHouseAsSystemOutputWarns() {
        var value = input(track: goodTrack())
        value.defaultOutputUIDs = ["h"]
        XCTAssertTrue(kinds(value).contains(.systemSoundOnHouse))
    }

    func testBlockingSortsFirst() {
        var track = goodTrack()
        track.endSec = nil
        let issues = PreServiceCheck.run(input(track: track, routing: OutputRouting()))
        XCTAssertEqual(issues.first?.severity, .blocking)
    }
}

final class SystemSoundGuardTests: XCTestCase {
    final class Backend: SoundRoutingBackend {
        var output = "house"
        var system = "house"
        var devices = ["house", "speakers", "cue"]
        func defaultUID(system isSystem: Bool) -> String? { isSystem ? system : output }
        func setDefault(uid: String, system isSystem: Bool) -> Bool {
            if isSystem { system = uid } else { output = uid }
            return true
        }
        func availableUIDs() -> [String] { devices }
    }

    private func file() -> JSONFile<SystemSoundGuard.Record> {
        JSONFile(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
    }

    func testMovesOffHouseAndRestores() {
        let backend = Backend()
        let guardian = SystemSoundGuard(backend: backend, file: file())
        XCTAssertTrue(guardian.engage(houseUID: "house", preferredUID: "cue"))
        XCTAssertEqual(backend.system, "cue")
        XCTAssertEqual(backend.output, "cue")
        guardian.release()
        XCTAssertEqual(backend.system, "house")
        XCTAssertEqual(backend.output, "house")
    }

    func testLeavesThingsAloneWhenNotOnHouse() {
        let backend = Backend()
        backend.output = "speakers"
        backend.system = "speakers"
        let record = file()
        XCTAssertTrue(SystemSoundGuard(backend: backend, file: record).engage(houseUID: "house", preferredUID: nil))
        XCTAssertEqual(backend.system, "speakers")
        XCTAssertNil(record.load())
    }

    func testCrashRecoveryRestoresOnNextLaunch() {
        let backend = Backend()
        let record = file()
        SystemSoundGuard(backend: backend, file: record).engage(houseUID: "house", preferredUID: "speakers")
        // New process after a crash.
        SystemSoundGuard(backend: backend, file: record).release()
        XCTAssertEqual(backend.system, "house")
    }

    func testReportsWhenNoOtherDevice() {
        let backend = Backend()
        backend.devices = ["house"]
        XCTAssertFalse(SystemSoundGuard(backend: backend, file: file()).engage(houseUID: "house", preferredUID: nil))
    }

    func testSecondEngageKeepsOriginals() {
        let backend = Backend()
        let guardian = SystemSoundGuard(backend: backend, file: file())
        guardian.engage(houseUID: "house", preferredUID: "cue")
        backend.system = "house"
        guardian.engage(houseUID: "house", preferredUID: "cue")
        guardian.release()
        XCTAssertEqual(backend.output, "house")
    }
}

final class JSONFileTests: XCTestCase {
    func testRoundTripAndBackupRecovery() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let file = JSONFile<Library>(url: url)
        var library = Library()
        library.tracks = [Track(title: "One")]
        try file.save(library)
        library.tracks.append(Track(title: "Two"))
        try file.save(library)
        XCTAssertEqual(file.load()?.tracks.count, 2)

        try Data("corrupt".utf8).write(to: url)
        var quarantined: [URL] = []
        XCTAssertEqual(file.load { quarantined.append($0) }?.tracks.count, 1)
        XCTAssertEqual(quarantined.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantined[0].path), "a bad file is kept for recovery")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "so the next save cannot copy it over the backup")
    }

    func testOlderFilesMissingFieldsStillLoad() throws {
        let id = UUID()
        let json = #"{"tracks":[{"id":"\#(id)","title":"Old","endSec":12.5}]}"#
        let library = try JSONDecoder().decode(Library.self, from: Data(json.utf8))
        XCTAssertEqual(library.tracks[0].endSec, 12.5)
        XCTAssertEqual(library.tracks[0].fadeOutSec, 3)
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"panicFadeSec":2}"#.utf8))
        XCTAssertEqual(settings.panicFadeSec, 2)
        XCTAssertEqual(settings.targetLUFS, -18)
    }
}
