import XCTest
@testable import CantorCore

/// Services built in Cantator, with no Planning Center and no Claude.
final class StandaloneSettingsTests: XCTestCase {
    func testFreshInstallStartsStandaloneWithClaudeOffAndTheQuestionUnanswered() {
        let settings = AppSettings()
        XCTAssertEqual(settings.serviceSource, .standalone)
        XCTAssertFalse(settings.llmEnabled)
        XCTAssertFalse(settings.hasChosenServiceSource)
        XCTAssertEqual(settings.newFileHandling, .ask)
        XCTAssertEqual(settings.keepPastServicesWeeks, 8)
    }

    func testOlderSettingsReadAsPlanningCenterWithClaudeOnAndNoQuestion() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings.serviceSource, .planningCenter, "everyone before this choice existed used Planning Center")
        XCTAssertTrue(settings.llmEnabled, "and Claude was on for them")
        XCTAssertTrue(settings.hasChosenServiceSource, "so they are not asked")
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data(#"{"serviceSource":"later"}"#.utf8)).serviceSource, .planningCenter)
    }

    func testTheFirstLaunchAnswerSetsClaudeToMatch() {
        var settings = AppSettings()
        settings.chooseServiceSource(.planningCenter)
        XCTAssertTrue(settings.llmEnabled)
        XCTAssertTrue(settings.hasChosenServiceSource)
        XCTAssertTrue(settings.usesPlanningCenter)
        settings.chooseServiceSource(.standalone)
        XCTAssertFalse(settings.llmEnabled)
        XCTAssertFalse(settings.usesPlanningCenter)
    }

    func testNewSettingsRoundTrip() throws {
        var settings = AppSettings()
        settings.chooseServiceSource(.standalone)
        settings.llmEnabled = true
        settings.newFileHandling = .quiet
        settings.keepPastServicesWeeks = 0
        settings.templates = [ServiceTemplate(name: "Standard", items: [.init(title: "Worship", isHeader: true), .init(title: "Choir")])]
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.templates[0].summary, "1 section, 1 item")
    }
}

final class ManualServiceTests: XCTestCase {
    private let sunday = Date(timeIntervalSince1970: 1_794_306_600) // Sun Nov 8 2026, 10:30 local-ish

    private func built() -> ServicePlan {
        var choir = ServicePlan.manualCue(title: "Choir: Total Praise")
        choir.trackID = UUID()
        return .manual(title: "Sunday Morning", date: sunday, cues: [
            ServicePlan.manualCue(title: "Worship", header: true),
            choir,
            ServicePlan.manualCue(title: "Welcome", needsPlayback: false),
            ServicePlan.manualCue(title: "Special: Way Maker", notes: "after the prayer"),
        ])
    }

    func testABuiltServiceIsManualAndNamedByTheOperator() {
        let plan = built()
        XCTAssertTrue(plan.isManual)
        XCTAssertEqual(plan.serviceTypeName, "Sunday Morning")
        XCTAssertEqual(plan.sortDate, sunday)
        XCTAssertEqual(plan.serviceTimes, [sunday])
        XCTAssertTrue(plan.dates.contains("Nov"))
        XCTAssertEqual(plan.orderedCues.map(\.position), [0, 1, 2, 3])
        XCTAssertTrue(plan.cues.allSatisfy(\.isManual))
        XCTAssertEqual(plan.cues[0].itemType, "header")
        XCTAssertFalse(plan.cues[0].needsPlayback, "a section never plays")
        XCTAssertEqual(plan.cues[2].operatorNeeds, false)
        XCTAssertEqual(plan.playbackCues.map(\.title), ["Choir: Total Praise", "Special: Way Maker"])
        XCTAssertEqual(ServicePlan.manual(title: "  ", date: sunday).title, "Service")
    }

    func testBuiltServicesSurviveASyncThatDoesNotListThem() {
        let plan = built()
        let empty = ServicePlan.manual(title: "Wedding", date: sunday.addingTimeInterval(-40 * 24 * 3600))
        let synced = ServicePlan(id: "99", serviceTypeID: "1", serviceTypeName: "Sunday", title: "", dates: "", sortDate: sunday)
        let result = ServicePlan.applySync(existing: [plan, empty], fresh: [synced], loadedID: nil, now: sunday)
        XCTAssertEqual(Set(result.map(\.id)), [plan.id, empty.id, "99"], "even an old, empty one: only the operator or the past-services setting removes it")
    }

    func testCopyingAnOrderKeepsTheItemsAndDropsTheTracks() {
        let plan = built()
        let next = plan.copyingOrder(title: "Sunday Morning", date: sunday.addingTimeInterval(7 * 24 * 3600))
        XCTAssertNotEqual(next.id, plan.id)
        XCTAssertEqual(next.orderedCues.map(\.title), plan.orderedCues.map(\.title))
        XCTAssertEqual(next.orderedCues.map(\.itemType), plan.orderedCues.map(\.itemType))
        XCTAssertEqual(next.orderedCues.map(\.needsPlayback), plan.orderedCues.map(\.needsPlayback))
        XCTAssertEqual(next.orderedCues[3].notes, "after the prayer")
        XCTAssertTrue(next.cues.allSatisfy { $0.trackID == nil })
        XCTAssertTrue(Set(next.cues.map(\.id)).isDisjoint(with: plan.cues.map(\.id)))
    }

    func testATemplateIsTheOrderWithoutTracks() {
        let plan = built()
        let template = ServiceTemplate(plan: plan, name: "Standard")
        XCTAssertEqual(template.items.map(\.title), plan.orderedCues.map(\.title))
        XCTAssertEqual(template.items.map(\.isHeader), [true, false, false, false])
        XCTAssertEqual(template.summary, "1 section, 3 items")
        let cues = ServicePlan.cues(from: template)
        XCTAssertEqual(cues.map(\.title), template.items.map(\.title))
        XCTAssertEqual(cues.map(\.position), [0, 1, 2, 3])
        XCTAssertTrue(cues.allSatisfy { $0.trackID == nil && $0.isManual })
        XCTAssertEqual(cues[0].itemType, "header")
        XCTAssertFalse(cues[2].needsPlayback)
    }

    func testReorderingAndRemoving() {
        var plan = built()
        let ids = plan.orderedCues.map(\.id)
        XCTAssertFalse(plan.move(ids[0], by: -1), "already first")
        XCTAssertFalse(plan.move(ids[3], by: 1), "already last")
        XCTAssertTrue(plan.move(ids[3], by: -1))
        XCTAssertEqual(plan.orderedCues.map(\.id), [ids[0], ids[1], ids[3], ids[2]])
        plan.move(ids[0], to: .after(ids[2]))
        XCTAssertEqual(plan.orderedCues.map(\.id), [ids[1], ids[3], ids[2], ids[0]])
        plan.move(ids[1], to: .after(ids[1]))
        XCTAssertEqual(plan.orderedCues.map(\.id), [ids[1], ids[3], ids[2], ids[0]], "dropping a cue on itself changes nothing")
        plan.move(ids[0], to: .start)
        XCTAssertEqual(plan.orderedCues.map(\.id), [ids[0], ids[1], ids[3], ids[2]])
        plan.remove(ids[1])
        XCTAssertEqual(plan.orderedCues.map(\.id), [ids[0], ids[3], ids[2]])
        XCTAssertEqual(plan.orderedCues.map(\.position), [0, 1, 2])
    }

    func testATypedItemIsNeverConfirmedByCantator() {
        var plan = built()
        let file = UUID()
        plan.cues[3].candidates = [MatchCandidate(trackID: file, score: 0.96, source: .string, reason: "")]
        XCTAssertEqual(plan.autoConfirmStrongMatches(), 0)
        XCTAssertNil(plan.cues[3].trackID, "the operator is choosing a track, not confirming a plan's")
    }

    func testPastBuiltServicesLeaveAfterTheKeepPeriod() {
        let day = 24 * 3600.0
        let now = sunday.addingTimeInterval(70 * day)
        let old = built()
        let recent = ServicePlan.manual(title: "Recent", date: now.addingTimeInterval(-20 * day))
        let loaded = ServicePlan.manual(title: "Loaded", date: sunday)
        let synced = ServicePlan(id: "99", serviceTypeID: "1", serviceTypeName: "Sunday", title: "", dates: "", sortDate: sunday)
        let plans = [old, recent, loaded, synced]
        let kept = ServicePlan.pruningPastManual(plans, keepWeeks: 8, loadedID: loaded.id, now: now)
        XCTAssertEqual(Set(kept.map(\.id)), [recent.id, loaded.id, "99"], "the loaded one and synced ones stay")
        XCTAssertEqual(ServicePlan.pruningPastManual(plans, keepWeeks: 0, loadedID: nil, now: now).count, 4, "0 keeps them forever")
        XCTAssertEqual(ServicePlan.pruningPastManual(plans, keepWeeks: 2, loadedID: nil, now: now).map(\.id), ["99"])
    }

    func testABuiltServiceIsNeverStale() {
        var cue = ServicePlan.manualCue(title: "Anthem")
        var track = Track(files: [TrackFile(path: "/x/a.mp3", locality: .local)], title: "A")
        track.endSec = 100
        track.integratedLUFS = -18
        track.truePeakDb = -6
        cue.trackID = track.id
        var plan = ServicePlan.manual(title: "Sunday", date: sunday, cues: [cue], now: .distantPast)
        plan.syncedAt = .distantPast
        let input = CheckInput(
            plan: plan, tracks: [track.id: track], residentTrackIDs: [track.id],
            routing: OutputRouting(houseDeviceUID: "h", cueDeviceUID: "c"), availableDeviceUIDs: ["h", "c"], now: sunday
        )
        let kinds = Set(PreServiceCheck.run(input).filter { $0.severity > .ok }.map(\.kind))
        XCTAssertFalse(kinds.contains(.staleSync), "there is nothing to refresh")
        XCTAssertEqual(kinds, [])
    }

    func testQuietNewFilesStopWaitingAfterAWeek() {
        var inbox = NewFileInbox()
        let now = Date()
        inbox.add([UUID()], at: now.addingTimeInterval(-8 * 24 * 3600))
        inbox.add([UUID()], at: now.addingTimeInterval(-6 * 24 * 3600))
        XCTAssertEqual(inbox.dropStale(now: now), 1)
        XCTAssertEqual(inbox.items.count, 1)
    }
}
