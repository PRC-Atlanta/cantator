import XCTest
@testable import CantorCore

final class LenientDecodingTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(json.utf8))
    }

    func testTrackWithUnknownValuesAndMissingFieldsLoads() throws {
        let id = UUID()
        let json = #"""
        {"tracks":[{"id":"\#(id)","title":"T",
          "files":[{"path":"/a.mp3","locality":"archived"},{"locality":"local"}],
          "markers":[{"name":"Verse 2"}],
          "exclusion":{"reason":"stem"},
          "eq":{"bands":[{"shape":"tilt","frequency":500,"gainDb":6},{"shape":"bell","frequency":250}]}}]}
        """#
        let track = try decode(Library.self, json).tracks[0]
        XCTAssertEqual(track.files[0].locality, .missing, "an unknown locality is never played")
        XCTAssertEqual(track.files[1].path, "")
        XCTAssertEqual(track.markers[0].seconds, 0)
        XCTAssertEqual(track.exclusion?.byOperator, false)
        let eq = try XCTUnwrap(track.eq)
        XCTAssertTrue(eq.isOn)
        XCTAssertFalse(eq.bands[0].isOn, "an unknown shape is turned off, so the track plays unchanged")
        XCTAssertEqual(eq.bands[1].shape, .bell)
        XCTAssertTrue(eq.bands[1].isOn)
        XCTAssertEqual(try decode(TrackEQ.self, "{}").bands, TrackEQ.defaultBands)
    }

    func testPlanWithMissingFieldsAndUnknownSourceLoads() throws {
        let track = UUID()
        let json = #"""
        [{"id":"p","cues":[{"id":"c","title":"Anthem","trackID":"\#(track)",
          "candidates":[{"trackID":"\#(track)","source":"vector"}]}]}]
        """#
        let plan = try decode([ServicePlan].self, json)[0]
        XCTAssertEqual(plan.syncedAt, .distantPast, "unknown sync age reads as stale")
        let cue = plan.cues[0]
        XCTAssertTrue(cue.needsPlayback)
        XCTAssertEqual(cue.trackID, track)
        XCTAssertNil(cue.keyName)
        XCTAssertFalse(cue.removedInPCO)
        XCTAssertEqual(cue.candidates[0].source, .string)
        XCTAssertEqual(cue.candidates[0].score, 0)
    }

    func testSettingsWithPartialRoutingAndAliasesLoad() throws {
        let settings = try decode(AppSettings.self, #"{"routing":{"houseDeviceUID":"h"}}"#)
        XCTAssertEqual(settings.routing, OutputRouting(houseDeviceUID: "h"))
        XCTAssertEqual(try decode(AliasMemory.self, #"{"confirmed":{"song:1":"abc"}}"#).confirmed, ["song:1": "abc"])
    }

    func testEncodingKeepsItsShapeAndRoundTrips() throws {
        var cue = ServiceCue(id: "c", position: 2, title: "Anthem", arrangement: "SATB", keyName: "D", songID: "s")
        cue.attachmentsUnavailable = true
        var plan = ServicePlan(id: "p", serviceTypeID: "s", serviceTypeName: "S", title: "", dates: "", sortDate: nil, cues: [cue])
        plan.syncFailed = true
        plan.serviceTimesUnavailable = true
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(plan)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["id", "serviceTypeID", "serviceTypeName", "title", "dates", "serviceTimes", "syncedAt", "cues", "picked"])
        let cueObject = try XCTUnwrap((object["cues"] as? [[String: Any]])?.first)
        XCTAssertNil(cueObject["attachmentsUnavailable"], "sync markers are not saved")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var back = try decoder.decode(ServicePlan.self, from: encoder.encode(plan))
        back.syncedAt = plan.syncedAt
        plan.syncFailed = false
        plan.serviceTimesUnavailable = false
        plan.cues[0].attachmentsUnavailable = false
        XCTAssertEqual(back.cues, plan.cues)
        XCTAssertEqual(try decoder.decode(EQBand.self, from: encoder.encode(TrackEQ.defaultBands[0])), TrackEQ.defaultBands[0])
    }
}

final class RunLogTests: XCTestCase {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("runlog.jsonl")
    }

    func testEntriesLandInOrderWithMilliseconds() throws {
        let url = temporaryURL()
        let log = RunLog(url: url)
        for index in 0..<200 { log.record("e\(index)", cue: "c", at: Date(timeIntervalSince1970: 1_800_000_000.125)) }
        log.flush()
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 200)
        let events = try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String])["event"] }
        XCTAssertEqual(events, (0..<200).map { "e\($0)" })
        let time = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: String])["time"]
        XCTAssertEqual(time, "2027-01-15T08:00:00.125Z")
    }

    func testUnopenableLogIsNotReplaced() throws {
        let url = temporaryURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("history\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        let log = RunLog(url: url)
        log.record("go", cue: "Anthem")
        log.flush()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "history\n")
    }
}

final class SoundGuardRecordTests: XCTestCase {
    private func file() -> JSONFile<SystemSoundGuard.Record> {
        JSONFile(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
    }

    func testNothingMovesWhenTheRecordCannotBeSaved() {
        let backend = SystemSoundGuardTests.Backend()
        let unsavable = JSONFile<SystemSoundGuard.Record>(url: URL(fileURLWithPath: "/dev/null/cantor/sound-guard.json"))
        let guardian = SystemSoundGuard(backend: backend, file: unsavable)
        XCTAssertFalse(guardian.engage(houseUID: "house", preferredUID: "cue"))
        XCTAssertNotNil(guardian.lastError)
        XCTAssertEqual(backend.system, "house")
        XCTAssertEqual(backend.output, "house")
    }

    func testAbsentOriginalStaysRecordedUntilItReturns() {
        let backend = SystemSoundGuardTests.Backend()
        backend.devices = ["house", "usb", "cue"]
        backend.system = "usb"
        backend.output = "house"
        let record = file()
        let guardian = SystemSoundGuard(backend: backend, file: record)
        XCTAssertTrue(guardian.engage(houseUID: "house", preferredUID: "cue"))
        XCTAssertEqual(backend.output, "cue")

        // The house interface is unplugged before unload: nothing can be restored yet.
        backend.devices = ["usb", "cue"]
        guardian.release()
        XCTAssertEqual(backend.output, "cue")
        XCTAssertEqual(record.load(), SystemSoundGuard.Record(originalDefault: "house", originalSystem: nil))

        // Next launch, with it back.
        backend.devices = ["house", "usb", "cue"]
        SystemSoundGuard(backend: backend, file: record).release()
        XCTAssertEqual(backend.output, "house")
        XCTAssertNil(record.load())
    }

    func testEngageAfterPartialReleaseFillsTheRestoredField() {
        let backend = SystemSoundGuardTests.Backend()
        let record = file()
        try? record.save(SystemSoundGuard.Record(originalDefault: nil, originalSystem: "usb"))
        let guardian = SystemSoundGuard(backend: backend, file: record)
        XCTAssertTrue(guardian.engage(houseUID: "house", preferredUID: "cue"))
        XCTAssertEqual(record.load(), SystemSoundGuard.Record(originalDefault: "house", originalSystem: "usb"))
        guardian.release()
        XCTAssertEqual(backend.output, "house")
    }
}

final class JSONFileReadErrorTests: XCTestCase {
    func testUnreadableFileIsReportedAndKept() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let file = JSONFile<AliasMemory>(url: url)
        var memory = AliasMemory()
        memory.confirmed["a"] = "1"
        try file.save(memory)
        memory.confirmed["b"] = "2"
        try file.save(memory)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

        var reported: [URL] = []
        XCTAssertEqual(file.load { reported.append($0) }?.confirmed, ["a": "1"], "falls back to the backup")
        XCTAssertEqual(reported.count, 1, "but says so")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: reported[0].path)
        XCTAssertEqual(try JSONFile<AliasMemory>(url: reported[0]).load()?.confirmed.count, 2, "the unreadable file is kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "so the next save cannot overwrite it")
    }
}
