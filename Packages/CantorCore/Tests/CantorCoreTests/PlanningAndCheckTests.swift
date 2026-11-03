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
                                                "description": "Choir - tracks", "html_details": "<p>Starts at verse 2</p>"],
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
        XCTAssertEqual(cue.notes, "Choir - tracks\nStarts at verse 2")
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

    func testTrackNotesWinOverARememberedChoice() async throws {
        StubProtocol.responder = fixture
        var memory = AliasMemory()
        // Be Still's notes say tracks, so a remembered Not Needed loses. Welcome has no notes, so a
        // remembered Needed turns it on.
        memory.rememberNeeds(ServiceCue(id: "x", position: 0, title: "Be Still", songID: "s9"), needed: false)
        memory.rememberNeeds(ServiceCue(id: "y", position: 0, title: "Welcome"), needed: true)
        let client = PCOClient(appID: "id", secret: "secret", session: StubProtocol.session(), spacing: .zero)
        let plans = try await client.fetchUpcomingPlans(memory: memory)
        XCTAssertEqual(Set(plans[0].playbackCues.map(\.id)), ["i1", "i3"])
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
        let needs = { (title: String, type: String, notes: String) in
            PlaybackDetector.needsPlayback(ServiceCue(id: "1", position: 0, title: title, itemType: type, notes: notes))
        }
        XCTAssertTrue(needs("Esti Viu", "song", "Choir - tracks"))
        XCTAssertTrue(needs("Cantare", "item", "Fr Ilie Pop - negativ"))
        XCTAssertTrue(needs("Solo", "item", "PISTĂ"))
        // Live songs, by the band or the choir, and items with no notes.
        XCTAssertFalse(needs("Thank You Jesus For The Blood", "song", "Choir - band SOLO orange mic"))
        XCTAssertFalse(needs("Mai Sus De Oameni Si De-mparati", "song", ""))
        XCTAssertFalse(needs("Fanfara", "item", "Nr. 79 - Veniți Creștini"))
        XCTAssertFalse(needs("Sermon", "item", ""))
        XCTAssertFalse(needs("Tracks", "header", ""))
    }

    func testTrackNotesBeatARememberedNotNeeded() {
        var memory = AliasMemory()
        let live = ServiceCue(id: "1", position: 0, title: "Esti Viu", itemType: "song", songID: "9")
        memory.rememberNeeds(live, needed: false)
        var tracks = live
        tracks.notes = "Choir - tracks"
        XCTAssertTrue(PlaybackDetector.needsPlayback(tracks, memory: memory))
        XCTAssertFalse(PlaybackDetector.needsPlayback(live, memory: memory))
        // A remembered Needed still turns on an item whose notes say nothing.
        memory.rememberNeeds(live, needed: true)
        XCTAssertTrue(PlaybackDetector.needsPlayback(live, memory: memory))
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
        XCTAssertEqual(merged.orderedCues.map(\.id), ["1", "m"])
        XCTAssertTrue(merged.cues[0].changedSinceConfirm)
    }

    func testStrongMatchesConfirmThemselvesUntilCleared() {
        let file = UUID(), other = UUID()
        func cue(_ id: String, score: Double, needs: Bool = true) -> ServiceCue {
            var cue = ServiceCue(id: id, position: 0, title: id, needsPlayback: needs)
            cue.candidates = [MatchCandidate(trackID: file, score: score, source: .string, reason: "")]
            return cue
        }
        var cleared = cue("cleared", score: 0.95)
        cleared.matchCleared = true
        var chosen = cue("chosen", score: 0.95)
        chosen.trackID = other
        var service = plan([cue("strong", score: 0.94), cue("weak", score: 0.7), cue("live", score: 0.95, needs: false), cleared, chosen])
        XCTAssertEqual(service.autoConfirmStrongMatches(), 1)
        let byID = Dictionary(uniqueKeysWithValues: service.cues.map { ($0.id, $0) })
        XCTAssertEqual(byID["strong"]?.trackID, file)
        XCTAssertEqual(byID["strong"]?.autoConfirmed, true)
        XCTAssertNil(byID["weak"]?.trackID)
        XCTAssertNil(byID["live"]?.trackID)
        XCTAssertNil(byID["cleared"]?.trackID)
        XCTAssertEqual(byID["chosen"]?.trackID, other)

        // A sync keeps both marks.
        let fresh = plan(service.cues.map { ServiceCue(id: $0.id, position: 0, title: $0.id) })
        let merged = Dictionary(uniqueKeysWithValues: service.merging(fresh: fresh).cues.map { ($0.id, $0) })
        XCTAssertEqual(merged["strong"]?.autoConfirmed, true)
        XCTAssertEqual(merged["cleared"]?.matchCleared, true)
    }

    func testRedetectFollowsTheNotes() {
        var memory = AliasMemory()
        let unchecked = ServiceCue(id: "x", position: 0, title: "Esti Viu", itemType: "song", songID: "9")
        memory.rememberNeeds(unchecked, needed: false)
        var tracks = ServiceCue(id: "a", position: 0, title: "Esti Viu", itemType: "song", notes: "Choir - tracks", songID: "9", needsPlayback: false)
        tracks.trackID = UUID()
        let live = ServiceCue(id: "b", position: 1, title: "Mai Sus", itemType: "song", needsPlayback: true)
        var kept = ServiceCue(id: "c", position: 2, title: "Special", needsPlayback: true)
        kept.trackID = UUID()
        let added = ServiceCue(id: "m", position: 3, title: "Added", needsPlayback: true, isManual: true)
        var service = plan([tracks, live, kept, added])
        service.redetect(memory: memory)
        let needs = Dictionary(uniqueKeysWithValues: service.cues.map { ($0.id, $0.needsPlayback) })
        // Notes turn a matched line on; a line with no notes and no file goes off; a line with a
        // file and no notes keeps the operator's choice; an added item is left alone.
        XCTAssertEqual(needs, ["a": true, "b": false, "c": true, "m": true])
    }

    // Review 2, finding 9.
    func testOperatorNotNeededSticksThroughNotesAndSyncs() {
        var cue = ServiceCue(id: "a", position: 0, title: "Choir Anthem", itemType: "song", notes: "Choir live, no tracks", needsPlayback: true)
        cue.operatorNeeds = false
        cue.needsPlayback = false
        var service = plan([cue])
        service.redetect(memory: AliasMemory())
        XCTAssertEqual(service.cues[0].needsPlayback, false, "the notes say tracks, but the operator said no")

        // A strong match doesn't land on it either.
        service.cues[0].candidates = [MatchCandidate(trackID: UUID(), score: 0.97, source: .string, reason: "")]
        XCTAssertEqual(service.autoConfirmStrongMatches(), 0)

        // A sync brings the notes back in, and the operator's choice stays.
        let fresh = plan([ServiceCue(id: "a", position: 0, title: "Choir Anthem", itemType: "song", notes: "Choir live, no tracks", needsPlayback: true)])
        let merged = service.merging(fresh: fresh)
        XCTAssertEqual(merged.cues[0].operatorNeeds, false)
        XCTAssertEqual(merged.cues[0].needsPlayback, false)

        // And it is saved.
        let decoded = try? JSONDecoder().decode(ServiceCue.self, from: JSONEncoder().encode(merged.cues[0]))
        XCTAssertEqual(decoded?.operatorNeeds, false)
    }

    // Review 2, finding 11.
    func testWrongLengthNameMatchWaitsForTheOperator() {
        let file = UUID()
        func cue(_ id: String, source: MatchSource, mismatch: Bool) -> ServiceCue {
            var cue = ServiceCue(id: id, position: 0, title: "Gloria", needsPlayback: true)
            cue.candidates = [MatchCandidate(trackID: file, score: 1, source: source, reason: "", durationMismatch: mismatch)]
            return cue
        }
        var service = plan([
            cue("other-setting", source: .string, mismatch: true),
            cue("same-length", source: .string, mismatch: false),
            cue("chosen-before", source: .remembered, mismatch: true),
        ])
        XCTAssertEqual(service.autoConfirmStrongMatches(), 2)
        let byID = Dictionary(uniqueKeysWithValues: service.cues.map { ($0.id, $0.trackID) })
        XCTAssertNil(byID["other-setting"]!)
        XCTAssertEqual(byID["same-length"], file)
        XCTAssertEqual(byID["chosen-before"], file)
    }

    func testAddedCuesGoWhereChosen() {
        var service = plan([
            ServiceCue(id: "a", position: 1, title: "Welcome"),
            ServiceCue(id: "b", position: 5, title: "Choir"),
        ])
        let added = { (id: String) in ServiceCue(id: id, position: 0, title: id, isManual: true) }
        service.insert([added("x")], at: .after("a"))
        service.insert([added("y"), added("z")], at: .start)
        service.insert([added("w")], at: .end)
        service.insert([added("v")], at: .after("gone"))
        XCTAssertEqual(service.orderedCues.map(\.id), ["y", "z", "a", "x", "b", "w", "v"])
        XCTAssertEqual(service.orderedCues.map(\.position), Array(0..<7))
    }

    func testAddedCuesKeepTheirPlaceThroughSyncs() {
        var service = plan([
            ServiceCue(id: "a", position: 1, title: "Welcome"),
            ServiceCue(id: "b", position: 2, title: "Choir"),
            ServiceCue(id: "c", position: 3, title: "Sermon"),
        ])
        service.insert([ServiceCue(id: "x", position: 0, title: "Added", isManual: true)], at: .after("b"))
        service.insert([ServiceCue(id: "s", position: 0, title: "First", isManual: true)], at: .start)
        // Planning Center adds an item before Choir and drops Sermon.
        let fresh = plan([
            ServiceCue(id: "a", position: 1, title: "Welcome"),
            ServiceCue(id: "n", position: 2, title: "Reading"),
            ServiceCue(id: "b", position: 3, title: "Choir"),
        ])
        XCTAssertEqual(service.merging(fresh: fresh).orderedCues.map(\.id), ["s", "a", "n", "b", "x"])
    }

    func testResyncFollowsTheNotesUntilConfirmed() {
        var live = ServiceCue(id: "1", position: 0, title: "Mai Sus", itemType: "song", needsPlayback: true)
        var confirmed = ServiceCue(id: "2", position: 1, title: "Esti Viu", itemType: "song", needsPlayback: true)
        confirmed.trackID = UUID()
        let fresh = plan([
            ServiceCue(id: "1", position: 0, title: "Mai Sus", itemType: "song", needsPlayback: false),
            ServiceCue(id: "2", position: 1, title: "Esti Viu", itemType: "song", needsPlayback: false),
        ])
        let merged = plan([live, confirmed]).merging(fresh: fresh)
        XCTAssertFalse(merged.cues[0].needsPlayback)
        XCTAssertTrue(merged.cues[1].needsPlayback)
        live.needsPlayback = false
        XCTAssertEqual(merged.cues[0].needsPlayback, live.needsPlayback)
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

    // Review 3, finding 7.
    func testMissingOutputPairIsFlagged() {
        var check = input(track: goodTrack(), routing: OutputRouting(houseDeviceUID: "h", houseFirstChannel: 2, cueDeviceUID: "c", cueFirstChannel: 4))
        check.deviceOutputChannels = ["h": 2, "c": 4]
        let issues = PreServiceCheck.run(check)
        XCTAssertEqual(issues.first { $0.kind == .housePairMissing }?.severity, .blocking)
        XCTAssertEqual(issues.first { $0.kind == .cuePairMissing }?.severity, .warning)
        // The pairs exist on larger devices.
        check.deviceOutputChannels = ["h": 8, "c": 8]
        XCTAssertFalse(kinds(check).contains(.housePairMissing))
        XCTAssertFalse(kinds(check).contains(.cuePairMissing))
    }

    func testChoosingASmallerDeviceResetsItsPair() {
        var routing = OutputRouting(houseDeviceUID: "big", houseFirstChannel: 2, cueDeviceUID: "phones", cueFirstChannel: 6)
        routing.houseDeviceUID = "usb"
        routing.fitPairs(deviceChannels: ["usb": 2, "phones": 8, "big": 8])
        XCTAssertEqual(routing.houseFirstChannel, 0, "3-4 doesn't exist on a two-output device")
        XCTAssertEqual(routing.cueFirstChannel, 6, "7-8 still exists on the cue device")

        // A device that isn't connected right now keeps its pair.
        var unplugged = OutputRouting(houseDeviceUID: "big", houseFirstChannel: 2)
        unplugged.fitPairs(deviceChannels: [:])
        XCTAssertEqual(unplugged.houseFirstChannel, 2)

        // A 16-out pair on an 8-out device goes back too.
        var smaller = OutputRouting(houseDeviceUID: "eight", houseFirstChannel: 12)
        smaller.fitPairs(deviceChannels: ["eight": 8])
        XCTAssertEqual(smaller.houseFirstChannel, 0)
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

// MARK: Sync failures

extension PCOClientTests {
    func testDefaultSpacingStaysUnderRateLimit() {
        let perWindow = Duration.seconds(20) / PCOClient.defaultSpacing
        XCTAssertLessThan(perWindow, 100)
    }

    func testReadsItemKey() async throws {
        StubProtocol.responder = { [self] request in
            if request.url!.absoluteString.contains("/items") {
                return (200, [:], json(["data": [["id": "i3", "attributes": ["title": "Be Still", "item_type": "song", "key_name": "Eb"]]]]))
            }
            return fixture(request)
        }
        let client = PCOClient(appID: "id", secret: "secret", session: StubProtocol.session(), spacing: .zero)
        let plans = try await client.fetchUpcomingPlans(memory: AliasMemory())
        XCTAssertEqual(plans.first?.cues.first?.keyName, "Eb")
    }

    func testFailedTimesAndAttachmentsKeepSavedValues() async throws {
        StubProtocol.responder = { [self] request in
            let url = request.url!.absoluteString
            if url.contains("/plan_times") || url.contains("/attachments") { return (500, [:], Data()) }
            return fixture(request)
        }
        let client = PCOClient(appID: "id", secret: "secret", session: StubProtocol.session(), spacing: .zero)
        let fresh = try await client.fetchUpcomingPlans(memory: AliasMemory())
        XCTAssertTrue(fresh[0].serviceTimesUnavailable)
        XCTAssertTrue(try XCTUnwrap(fresh[0].cues.first { $0.id == "i3" }).attachmentsUnavailable)

        let time = Date(timeIntervalSince1970: 1_800_000_000)
        var saved = fresh[0]
        saved.serviceTimes = [time]
        saved.serviceTimesUnavailable = false
        for index in saved.cues.indices {
            saved.cues[index].attachmentFilenames = ["Saved.mp3"]
            saved.cues[index].attachmentsUnavailable = false
        }
        let merged = ServicePlan.applySync(existing: [saved], fresh: fresh, loadedID: nil)
        XCTAssertEqual(merged[0].serviceTimes, [time])
        XCTAssertEqual(merged[0].cues.first { $0.id == "i3" }?.attachmentFilenames, ["Saved.mp3"])
    }

    func testOnePlanFailingKeepsTheOthersAndItsSavedCopy() async throws {
        StubProtocol.responder = { [self] request in
            let url = request.url!.absoluteString
            if url.contains("/plans?") {
                return (200, [:], json(["data": [
                    ["id": "p1", "attributes": ["title": "One", "sort_date": "2026-11-08T15:00:00Z"]],
                    ["id": "p2", "attributes": ["title": "Two", "sort_date": "2026-11-15T15:00:00Z"]],
                ]]))
            }
            if url.contains("/plans/p2/") { return (404, [:], Data()) }
            return fixture(request)
        }
        let client = PCOClient(appID: "id", secret: "secret", session: StubProtocol.session(), spacing: .zero)
        let fresh = try await client.fetchUpcomingPlans(memory: AliasMemory())
        XCTAssertEqual(fresh.map(\.id), ["p1", "p2"])
        XCTAssertFalse(fresh[0].syncFailed)
        XCTAssertTrue(fresh[1].syncFailed)

        var saved = ServicePlan(id: "p2", serviceTypeID: "st1", serviceTypeName: "T", title: "Two", dates: "", sortDate: nil,
                                cues: [ServiceCue(id: "c", position: 0, title: "Saved")])
        saved.cues[0].trackID = nil
        let result = ServicePlan.applySync(existing: [saved], fresh: fresh, loadedID: nil)
        XCTAssertEqual(result.first { $0.id == "p2" }, saved, "a plan that failed to fetch keeps its saved copy")
        XCTAssertEqual(ServicePlan.applySync(existing: [], fresh: fresh, loadedID: nil).map(\.id), ["p1"], "and is not added empty")
    }

    func testRejectedTokenMidSyncStillFails() async {
        StubProtocol.responder = { [self] request in
            request.url!.absoluteString.contains("/items") ? (401, [:], Data()) : fixture(request)
        }
        let client = PCOClient(appID: "id", secret: "secret", session: StubProtocol.session(), spacing: .zero)
        do {
            _ = try await client.fetchUpcomingPlans(memory: AliasMemory())
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? PCOError, .unauthorized)
        }
    }
}

// MARK: Resync

extension PlanMergeTests {
    private func confirmed(_ id: String, _ title: String, song: String? = nil, arrangement: String = "", key: String? = nil) -> ServiceCue {
        var cue = ServiceCue(id: id, position: 0, title: title, arrangement: arrangement, keyName: key, songID: song)
        cue.trackID = UUID()
        return cue
    }

    func testRemovedConfirmedCueStaysFlagged() {
        let cue = confirmed("1", "Anthem")
        let merged = plan([cue]).merging(fresh: plan([ServiceCue(id: "2", position: 0, title: "Welcome")]))
        let kept = try? XCTUnwrap(merged.cues.first { $0.id == "1" })
        XCTAssertEqual(kept?.trackID, cue.trackID)
        XCTAssertEqual(kept?.removedInPCO, true)

        // Still gone next time: still kept. Back with the same id: no longer removed.
        let again = merged.merging(fresh: plan([ServiceCue(id: "2", position: 0, title: "Welcome")]))
        XCTAssertEqual(again.cues.first { $0.id == "1" }?.removedInPCO, true)
        let back = again.merging(fresh: plan([ServiceCue(id: "1", position: 0, title: "Anthem")]))
        XCTAssertEqual(back.cues.map(\.id), ["1"])
        XCTAssertFalse(back.cues[0].removedInPCO)
        XCTAssertEqual(back.cues[0].trackID, cue.trackID)
    }

    func testUnconfirmedRemovedCueIsDropped() {
        let merged = plan([ServiceCue(id: "1", position: 0, title: "Anthem")]).merging(fresh: plan([]))
        XCTAssertTrue(merged.cues.isEmpty)
    }

    func testRecreatedItemTakesOverConfirmation() {
        let bySong = confirmed("1", "Be Still", song: "s9")
        let byTitle = confirmed("2", "Total Praise")
        let fresh = plan([
            ServiceCue(id: "10", position: 0, title: "Be Still (choir)", songID: "s9"),
            ServiceCue(id: "11", position: 1, title: "total praise!"),
        ])
        let merged = plan([bySong, byTitle]).merging(fresh: fresh)
        XCTAssertEqual(merged.cues.map(\.id), ["10", "11"])
        XCTAssertEqual(merged.cues[0].trackID, bySong.trackID)
        XCTAssertEqual(merged.cues[1].trackID, byTitle.trackID)
        XCTAssertFalse(merged.cues.contains { $0.removedInPCO })
    }

    func testAmbiguousRecreatedItemDoesNotTakeConfirmation() {
        let cue = confirmed("1", "Anthem")
        let fresh = plan([ServiceCue(id: "10", position: 0, title: "Anthem"), ServiceCue(id: "11", position: 1, title: "Anthem")])
        let merged = plan([cue]).merging(fresh: fresh)
        XCTAssertNil(merged.cues.first { $0.id == "10" }?.trackID)
        XCTAssertNil(merged.cues.first { $0.id == "11" }?.trackID)
        XCTAssertEqual(merged.cues.first { $0.id == "1" }?.removedInPCO, true)
    }

    func testArrangementAndKeyChangesFlag() {
        let cue = confirmed("1", "Be Still", arrangement: "SATB", key: "D")
        let arrangement = plan([cue]).merging(fresh: plan([ServiceCue(id: "1", position: 0, title: "Be Still", arrangement: "SAB", keyName: "D")]))
        XCTAssertTrue(arrangement.cues[0].changedSinceConfirm)
        let key = plan([cue]).merging(fresh: plan([ServiceCue(id: "1", position: 0, title: "Be Still", arrangement: "SATB", keyName: "Eb")]))
        XCTAssertTrue(key.cues[0].changedSinceConfirm)
        let same = plan([cue]).merging(fresh: plan([ServiceCue(id: "1", position: 0, title: "Be Still", arrangement: "SATB", keyName: "D")]))
        XCTAssertFalse(same.cues[0].changedSinceConfirm)
    }

    func testKeySavedBeforeKeysWereReadIsNotAChange() {
        let cue = confirmed("1", "Be Still", key: nil)
        let merged = plan([cue]).merging(fresh: plan([ServiceCue(id: "1", position: 0, title: "Be Still", keyName: "D")]))
        XCTAssertFalse(merged.cues[0].changedSinceConfirm)
        XCTAssertEqual(merged.cues[0].keyName, "D")
    }
}

// MARK: Check gaps

extension PreServiceCheckTests {
    func testStartPastBufferEndBlocks() {
        var track = goodTrack()
        track.startSec = 50
        track.endSec = nil
        var value = input(track: track)
        value.residentLengths = [track.id: ResidentLength(frames: 48_000 * 40, sampleRate: 48_000)]
        let issue = PreServiceCheck.run(value).first { $0.kind == .emptyRange }
        XCTAssertEqual(issue?.severity, .blocking)
    }

    func testEndBeforeStartBlocksWithoutBuffer() {
        var track = goodTrack()
        track.startSec = 30
        track.endSec = 20
        XCTAssertTrue(kinds(input(track: track, resident: false)).contains(.emptyRange))
        XCTAssertFalse(kinds(input(track: goodTrack())).contains(.emptyRange))
    }

    func testResidentTrackWithMissingFileOnlyWarns() {
        var track = goodTrack()
        track.files = [TrackFile(path: "/gone/a.mp3", locality: .missing)]
        let issues = PreServiceCheck.run(input(track: track, resident: true))
        XCTAssertEqual(issues.first { $0.kind == .fileMissing }?.severity, .warning)
        XCTAssertFalse(issues.contains { $0.severity == .blocking })
    }

    func testRemovedInPlanningCenterWarns() {
        let track = goodTrack()
        var value = input(track: track)
        value.plan.cues[0].removedInPCO = true
        XCTAssertEqual(PreServiceCheck.run(value).first { $0.kind == .removedInPCO }?.severity, .warning)
    }
}
