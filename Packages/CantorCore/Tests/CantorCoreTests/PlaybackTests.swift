import AVFoundation
import XCTest
@testable import CantorCore

final class ShowStateMachineTests: XCTestCase {
    func testGoFromIdleDoesNothing() {
        var machine = ShowStateMachine()
        XCTAssertEqual(machine.handle(.go), [])
        XCTAssertEqual(machine.state, .idle)
    }

    func testArmThenGoIsTheOnlyPathToLive() {
        var machine = ShowStateMachine()
        XCTAssertEqual(machine.handle(.arm("a")), [.prepare("a")])
        XCTAssertFalse(machine.state.isAudible)
        XCTAssertEqual(machine.handle(.go), [.start])
        XCTAssertEqual(machine.state, .live("a"))
    }

    func testEveryEventFromIdleExceptArmStaysSilent() {
        for event: ShowEvent in [.disarm, .go, .hold, .fade, .panic, .hardStop, .finished, .acknowledgeFault] {
            var machine = ShowStateMachine()
            machine.handle(event)
            XCTAssertFalse(machine.state.isAudible, "\(event)")
        }
    }

    func testSecondGoWhileLiveIsIgnored() {
        var machine = ShowStateMachine()
        machine.handle(.arm("a"))
        machine.handle(.go)
        XCTAssertEqual(machine.handle(.go), [])
        XCTAssertEqual(machine.state, .live("a"))
    }

    func testCannotArmSecondCueWhileLive() {
        var machine = ShowStateMachine()
        machine.handle(.arm("a"))
        machine.handle(.go)
        XCTAssertEqual(machine.handle(.arm("b")), [])
        XCTAssertEqual(machine.state, .live("a"))
    }

    func testHeldCueCanStillFinish() {
        var machine = ShowStateMachine()
        machine.handle(.arm("a"))
        machine.handle(.go)
        machine.handle(.hold)
        XCTAssertEqual(machine.handle(.finished), [.teardown])
        XCTAssertEqual(machine.state, .idle)
    }

    func testHoldResumesOnlyThroughGo() {
        var machine = ShowStateMachine()
        machine.handle(.arm("a"))
        machine.handle(.go)
        XCTAssertEqual(machine.handle(.hold), [.hold])
        XCTAssertEqual(machine.state, .held("a"))
        XCTAssertFalse(machine.state.isAudible)
        XCTAssertEqual(machine.handle(.go), [.start])
        XCTAssertEqual(machine.state, .live("a"))
    }

    func testFadeFinishesToIdle() {
        var machine = ShowStateMachine()
        machine.handle(.arm("a"))
        machine.handle(.go)
        XCTAssertEqual(machine.handle(.fade), [.fade])
        XCTAssertEqual(machine.state, .fading("a"))
        XCTAssertEqual(machine.handle(.finished), [.teardown])
        XCTAssertEqual(machine.state, .idle)
    }

    func testPanicOverridesFadeAndHardStopFollows() {
        var machine = ShowStateMachine()
        machine.handle(.arm("a"))
        machine.handle(.go)
        machine.handle(.fade)
        XCTAssertEqual(machine.handle(.panic), [.panic])
        XCTAssertEqual(machine.state, .panicking("a"))
        XCTAssertEqual(machine.handle(.hardStop), [.hardStop, .teardown])
        XCTAssertEqual(machine.state, .idle)
    }

    func testPanicWhileArmedDisarms() {
        var machine = ShowStateMachine()
        machine.handle(.arm("a"))
        XCTAssertEqual(machine.handle(.panic), [.teardown])
        XCTAssertEqual(machine.state, .idle)
    }

    func testDeviceLossFaultsAndNeverResumes() {
        var machine = ShowStateMachine()
        machine.handle(.arm("a"))
        machine.handle(.go)
        XCTAssertEqual(machine.handle(.deviceLost), [.hardStop, .teardown])
        XCTAssertEqual(machine.state, .faulted("a"))
        XCTAssertEqual(machine.handle(.go), [])
        XCTAssertEqual(machine.handle(.arm("a")), [])
        machine.handle(.acknowledgeFault)
        XCTAssertEqual(machine.state, .idle)
    }
}

final class GuardTests: XCTestCase {
    func testGoNeedsArmedDwell() {
        var guardState = GoGuard()
        XCTAssertFalse(guardState.allowsGo(at: 10, isRepeat: false))
        guardState.noteArmed(at: 10)
        XCTAssertFalse(guardState.allowsGo(at: 10.1, isRepeat: false))
        XCTAssertTrue(guardState.allowsGo(at: 10.31, isRepeat: false))
    }

    func testKeyRepeatNeverGoes() {
        var guardState = GoGuard()
        guardState.noteArmed(at: 0)
        XCTAssertFalse(guardState.allowsGo(at: 100, isRepeat: true))
    }

    func testPanicGateEscalatesWithinWindowOnly() {
        var gate = PanicGate()
        XCTAssertEqual(gate.press(at: 0), .fade)
        XCTAssertEqual(gate.press(at: 0.5), .hardStop)
        var slow = PanicGate()
        XCTAssertEqual(slow.press(at: 0), .fade)
        XCTAssertEqual(slow.press(at: 2), .fade)
    }
}

final class FadeCurveTests: XCTestCase {
    func testEndpointsAndEqualPower() {
        XCTAssertEqual(FadeCurve.down(0), 1, accuracy: 1e-6)
        XCTAssertEqual(FadeCurve.down(1), 0, accuracy: 1e-6)
        XCTAssertEqual(FadeCurve.up(0), 0, accuracy: 1e-6)
        XCTAssertEqual(FadeCurve.up(1), 1, accuracy: 1e-6)
        let down = FadeCurve.down(0.5), up = FadeCurve.up(0.5)
        XCTAssertEqual(down * down + up * up, 1, accuracy: 1e-5)
    }

    func testClampsOutOfRange() {
        XCTAssertEqual(FadeCurve.down(-1), 1, accuracy: 1e-6)
        XCTAssertEqual(FadeCurve.down(2), 0, accuracy: 1e-6)
    }
}

final class PlaybackKernelTests: XCTestCase {
    private let rate = 48_000.0

    private func kernel(seconds: Double = 10, start: Double = 0, end: Double? = nil, fade: Double = 3, fadeIn: Double = 0, gain: Float = 1) -> PlaybackKernel {
        let frames = Int(seconds * rate)
        let buffer = PCMBuffer(left: [Float](repeating: 1, count: frames), right: [Float](repeating: 1, count: frames), sampleRate: rate)
        return PlaybackKernel(buffer: buffer, parameters: PlaybackParameters(
            startFrame: Int(start * rate), endFrame: Int((end ?? seconds) * rate), fadeOutFrames: Int(fade * rate),
            fadeInFrames: Int(fadeIn * rate), gainLinear: gain
        ))
    }

    /// Renders in device-sized blocks and returns every left sample.
    private func render(_ kernel: PlaybackKernel, seconds: Double, block: Int = 512) -> [Float] {
        let total = Int(seconds * rate)
        var output = [Float](repeating: 0, count: total)
        var right = [Float](repeating: 0, count: block)
        var offset = 0
        while offset < total {
            let n = min(block, total - offset)
            output.withUnsafeMutableBufferPointer { left in
                right.withUnsafeMutableBufferPointer { r in
                    kernel.render(frames: n, left: left.baseAddress! + offset, right: r.baseAddress!)
                }
            }
            offset += n
        }
        return output
    }

    func testSilentUntilPlay() {
        let k = kernel()
        XCTAssertTrue(render(k, seconds: 1).allSatisfy { $0 == 0 })
        XCTAssertEqual(k.positionFrames, 0)
    }

    func testPlayRampsInWithoutClick() {
        let k = kernel()
        k.play()
        let out = render(k, seconds: 0.1)
        XCTAssertEqual(out[0], 0, accuracy: 0.01)
        let declick = Int(PlaybackKernel.declickSeconds * rate)
        XCTAssertEqual(out[declick + 1], 1, accuracy: 1e-5)
        for i in 1..<declick { XCTAssertGreaterThanOrEqual(out[i], out[i - 1]) }
    }

    func testAutomaticFadeLandsExactlyOnEndMarker() {
        let k = kernel(seconds: 10, end: 6, fade: 3)
        k.play()
        let out = render(k, seconds: 7)
        let end = Int(6 * rate), fadeStart = Int(3 * rate)
        XCTAssertEqual(out[fadeStart - 1], 1, accuracy: 1e-5)
        XCTAssertEqual(out[fadeStart + Int(1.5 * rate)], FadeCurve.down(0.5), accuracy: 1e-3)
        XCTAssertLessThan(out[end - 1], 0.001)
        XCTAssertTrue(out[end...].allSatisfy { $0 == 0 })
        XCTAssertEqual(k.phase, .finished)
        XCTAssertEqual(k.positionFrames, end)
    }

    func testManualFadeTakesRequestedTime() {
        let k = kernel(seconds: 20)
        k.play()
        _ = render(k, seconds: 1)
        k.fade(seconds: 3)
        let out = render(k, seconds: 4)
        XCTAssertEqual(out[Int(1.5 * rate)], FadeCurve.down(0.5), accuracy: 1e-3)
        XCTAssertLessThan(out[Int(3 * rate) - 1], 0.001)
        XCTAssertTrue(out[(Int(3 * rate) + 1)...].allSatisfy { $0 == 0 })
        XCTAssertEqual(k.phase, .finished)
    }

    func testManualFadeIsShortenedToLandOnMarker() {
        let k = kernel(seconds: 10, end: 5, fade: 0)
        k.play()
        _ = render(k, seconds: 4)
        k.fade(seconds: 3)
        _ = render(k, seconds: 2)
        XCTAssertEqual(k.positionFrames, Int(5 * rate))
        XCTAssertEqual(k.phase, .finished)
    }

    func testPanicIsFasterThanARunningFade() {
        let k = kernel(seconds: 20)
        k.play()
        _ = render(k, seconds: 1)
        k.fade(seconds: 3)
        _ = render(k, seconds: 0.5)
        k.panic(seconds: 0.5)
        let out = render(k, seconds: 1)
        XCTAssertTrue(out[Int(0.51 * rate)...].allSatisfy { $0 == 0 })
        XCTAssertEqual(k.phase, .finished)
    }

    func testPanicContinuesFromCurrentLevelWithoutJump() {
        let k = kernel(seconds: 20)
        k.play()
        _ = render(k, seconds: 1)
        k.fade(seconds: 2)
        let before = render(k, seconds: 1).last!
        k.panic(seconds: 0.5)
        let after = render(k, seconds: 0.01).first!
        XCTAssertEqual(before, after, accuracy: 0.01)
    }

    func testPanicNearEndOfFileCompletes() {
        let k = kernel(seconds: 2, fade: 0)
        k.play()
        _ = render(k, seconds: 1.9)
        k.panic(seconds: 1.5)
        _ = render(k, seconds: 1)
        XCTAssertEqual(k.phase, .finished)
    }

    func testHoldKeepsPositionAndResumes() {
        let k = kernel(seconds: 20)
        k.play()
        _ = render(k, seconds: 1)
        k.hold()
        _ = render(k, seconds: 0.5)
        let held = k.positionFrames
        XCTAssertEqual(held, Int(rate) + Int(PlaybackKernel.declickSeconds * rate), accuracy: 512)
        XCTAssertEqual(k.phase, .paused)
        XCTAssertTrue(render(k, seconds: 0.5).allSatisfy { $0 == 0 })
        k.play()
        _ = render(k, seconds: 1)
        XCTAssertEqual(k.positionFrames, held + Int(rate))
    }

    func testStartPointIsHonored() {
        let k = kernel(seconds: 10, start: 2)
        k.play()
        _ = render(k, seconds: 1)
        XCTAssertEqual(k.positionFrames, Int(3 * rate))
    }

    func testFadeInUsesSavedTime() {
        let k = kernel(seconds: 10, fadeIn: 1)
        k.play()
        let out = render(k, seconds: 1.5)
        XCTAssertEqual(out[Int(0.5 * rate)], FadeCurve.up(0.5), accuracy: 1e-3)
        XCTAssertEqual(out[Int(1.1 * rate)], 1, accuracy: 1e-5)
    }

    func testCueShorterThanItsFadeIsStillAudible() {
        let k = kernel(seconds: 2, fade: 3)
        k.play()
        let out = render(k, seconds: 2.1)
        XCTAssertGreaterThan(out.max() ?? 0, 0.9)
        XCTAssertEqual(k.phase, .finished)
    }

    func testGoInsideFadeZoneIsAudible() {
        let k = kernel(seconds: 10, start: 9, fade: 3)
        k.play()
        let out = render(k, seconds: 1.1)
        XCTAssertGreaterThan(out.max() ?? 0, 0.9)
    }

    func testBadPointsCannotReadOutOfBounds() {
        let k = kernel(seconds: 1, start: -5)
        XCTAssertEqual(k.positionFrames, 0)
        let empty = PlaybackKernel(buffer: PCMBuffer(left: [1, 1], right: nil, sampleRate: 48_000), parameters: PlaybackParameters(
            startFrame: 5, endFrame: 1, fadeOutFrames: 0, fadeInFrames: 0, gainLinear: 1
        ))
        empty.play()
        var left: [Float] = [0, 0], right: [Float] = [0, 0]
        empty.render(frames: 2, left: &left, right: &right)
        XCTAssertEqual(empty.phase, .finished, "an empty run ends rather than sitting LIVE and silent")
    }

    func testStaticGainIsApplied() {
        let k = kernel(gain: 0.5)
        k.play()
        XCTAssertEqual(render(k, seconds: 0.1).last!, 0.5, accuracy: 1e-5)
    }

    func testSeekOnlyWhenNotPlaying() {
        let k = kernel(seconds: 10)
        k.seek(toFrame: 1000)
        _ = render(k, seconds: 0.01)
        XCTAssertEqual(k.positionFrames, 1000)
        k.play()
        _ = render(k, seconds: 0.01)
        let here = k.positionFrames
        k.seek(toFrame: 0)
        _ = render(k, seconds: 0.01)
        XCTAssertGreaterThan(k.positionFrames, here)
    }

    func testEndNudgeMovesFadeLanding() {
        let k = kernel(seconds: 10, end: 5, fade: 1)
        k.play()
        _ = render(k, seconds: 1)
        k.setEnd(toFrame: Int(3 * rate))
        _ = render(k, seconds: 3)
        XCTAssertEqual(k.positionFrames, Int(3 * rate))
        XCTAssertEqual(k.phase, .finished)
    }

    func testPeaksResetAfterReading() {
        let k = kernel(gain: 0.25)
        k.play()
        _ = render(k, seconds: 0.1)
        XCTAssertEqual(k.takePeaks().left, 0.25, accuracy: 1e-5)
        XCTAssertEqual(k.takePeaks().left, 0)
    }

    func testParametersFromTrackClampToFile() {
        var track = Track(title: "T")
        track.endSec = 100
        track.startSec = 200
        let params = PlaybackParameters(track: track, sampleRate: 48_000, frames: 48_000, gainDb: -6)
        XCTAssertEqual(params.endFrame, 48_000)
        XCTAssertEqual(params.startFrame, 48_000)
        XCTAssertEqual(params.gainLinear, 0.501, accuracy: 0.001)
    }
}

@MainActor
final class FakeHouse: HouseOutput {
    var starts = 0
    var stops = 0
    var kernel: PlaybackKernel?
    var failure: Error?
    var running = true
    var isRunning: Bool { kernel != nil && running }

    func start(kernel: PlaybackKernel, deviceUID: String, firstChannel: Int) throws {
        if let failure { throw failure }
        starts += 1
        self.kernel = kernel
    }

    func stop() {
        stops += 1
        kernel = nil
    }

    func render(seconds: Double, rate: Double = 48_000) {
        guard let kernel else { return }
        var left = [Float](repeating: 0, count: 512), right = left
        for _ in 0..<(Int(seconds * rate) / 512 + 1) {
            kernel.render(frames: 512, left: &left, right: &right)
        }
    }
}

@MainActor
final class ShowControllerTests: XCTestCase {
    private var time = 0.0
    private var house = FakeHouse()
    private var available = true
    private var played: [String] = []

    private func cue(_ id: String, loaded: Bool = true) -> ShowCue {
        var track = Track(title: id)
        track.markers = [Marker(name: "V2", seconds: 4)]
        let buffer = loaded ? PCMBuffer(left: [Float](repeating: 0.5, count: 480_000), right: nil, sampleRate: 48_000) : nil
        return ShowCue(id: id, title: id, track: track, buffer: buffer)
    }

    private func controller(cues: [ShowCue]? = nil) -> ShowController {
        time = 100
        house = FakeHouse()
        available = true
        played = []
        let show = ShowController(house: house, clock: { [unowned self] in time }, deviceAvailable: { [unowned self] _ in available })
        show.routing = OutputRouting(houseDeviceUID: "house", cueDeviceUID: "cue")
        show.load(cues: cues ?? [cue("a"), cue("b")])
        show.onPlayed = { [unowned self] in played.append($0.title) }
        return show
    }

    private func armAndGo(_ show: ShowController) {
        show.setShowMode(true)
        XCTAssertNil(show.arm())
        time += 1
        show.go()
    }

    func testEQEditIsHeardOnThePlayingCueOnly() throws {
        let show = controller()
        armAndGo(show)
        let kernel = try XCTUnwrap(house.kernel)
        var left = [Float](repeating: 0, count: 4_800), right = left
        let level = { () -> Float in
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in kernel.render(frames: 4_800, left: l.baseAddress!, right: r.baseAddress!) }
            }
            return left.last ?? 0
        }
        _ = level()
        let before = level()
        var louder = TrackEQ()
        louder.outputDb = 6
        // Another track's edit leaves the playing cue alone.
        show.setLiveEQ(louder, trackID: UUID())
        XCTAssertEqual(level(), before, accuracy: 0.001)
        show.setLiveEQ(louder, trackID: try XCTUnwrap(show.activeCue?.track?.id))
        XCTAssertEqual(level() / before, 2, accuracy: 0.05)
    }

    func testPlayNowStartsAtOnceOutsideShowModeAndLeavesTheListAlone() {
        let show = controller()
        show.movePointer(by: 1)
        XCTAssertNil(show.playNow(cue("x")))
        XCTAssertEqual(show.state, .live("x"))
        XCTAssertFalse(show.showMode)
        XCTAssertEqual(show.activeCue?.title, "x")
        XCTAssertEqual(show.cues.map(\.id), ["a", "b"])
        XCTAssertEqual(played, ["x"])
        house.render(seconds: 0.1)
        show.fadeOut()
        house.render(seconds: 3.2)
        show.tick()
        XCTAssertEqual(show.state, .idle)
        XCTAssertNil(show.activeCue)
        XCTAssertEqual(show.nextIndex, 1)
    }

    func testPlayNowReplacesAnArmedCueButNeverASoundingOne() {
        let show = controller()
        show.setShowMode(true)
        show.arm()
        XCTAssertNil(show.playNow(cue("x")))
        XCTAssertEqual(show.state, .live("x"))
        XCTAssertEqual(show.playNow(cue("y")), .notIdle)
        XCTAssertEqual(show.state, .live("x"))
        XCTAssertEqual(house.starts, 2)
    }

    // Review 2, finding 4.
    func testLatePlayNowIsCancelledWhenTheShowChanged() {
        let show = controller()
        // Pressed while idle. Before it loads, the operator enters Show Mode and arms cue a.
        let pressed = show.moment
        show.setShowMode(true)
        show.arm()
        XCTAssertEqual(show.playNow(cue("x"), pressedAt: pressed), .showChanged("x"))
        XCTAssertEqual(show.state, .armed("a"), "the cue the operator armed stays armed")
        XCTAssertEqual(house.starts, 1)

        // Show Mode on its own also counts: the operator is running the service now.
        let quiet = controller()
        let before = quiet.moment
        quiet.setShowMode(true)
        XCTAssertEqual(quiet.playNow(cue("x"), pressedAt: before), .showChanged("x"))
        XCTAssertEqual(quiet.state, .idle)

        // Nothing changed: it plays.
        let ready = controller()
        XCTAssertNil(ready.playNow(cue("x"), pressedAt: ready.moment))
        XCTAssertEqual(ready.state, .live("x"))
    }

    func testLatePlayNowDoesNotAcknowledgeAFaultItNeverSaw() {
        let show = controller()
        let pressed = show.moment
        show.setShowMode(true)
        show.arm()
        show.deviceLost()
        guard case .faulted = show.state else { return XCTFail("expected a fault") }
        XCTAssertEqual(show.playNow(cue("x"), pressedAt: pressed), .showChanged("x"))
        guard case .faulted = show.state else { return XCTFail("the fault stays for the operator") }
    }

    // Review 3, finding 5: a Load Service that finishes during a Play Now.
    func testLoadWaitsWhileAPlayNowIsSounding() {
        let show = controller()
        XCTAssertNil(show.playNow(cue("x")))
        XCTAssertFalse(show.load(cues: [cue("new")]), "refused, so the app knows to load again")
        XCTAssertEqual(show.cues.map(\.id), ["a", "b"], "the list is unchanged until it can be replaced")
        house.render(seconds: 0.1)
        show.fadeOut()
        house.render(seconds: 3.2)
        show.tick()
        XCTAssertEqual(show.state, .idle)
        XCTAssertTrue(show.load(cues: [cue("new")]))
        XCTAssertEqual(show.cues.map(\.id), ["new"])
    }

    func testPlayNowRefusalStaysSilent() {
        let show = controller()
        available = false
        XCTAssertEqual(show.playNow(cue("x")), .noHouseOutput)
        XCTAssertEqual(show.state, .idle)
        XCTAssertFalse(show.showMode)
        XCTAssertNil(show.activeCue)
    }

    func testArmAndGoWorkOutsideShowMode() {
        let show = controller()
        XCTAssertNil(show.arm())
        XCTAssertEqual(show.state, .armed("a"))
        time += 1
        show.go()
        XCTAssertEqual(show.state, .live("a"))
        XCTAssertFalse(show.showMode)
    }

    func testGoWithoutArmDoesNothing() {
        let show = controller()
        show.setShowMode(true)
        show.go()
        XCTAssertEqual(show.state, .idle)
        XCTAssertEqual(house.starts, 0)
    }

    func testDoubleTapOfArmAndGoInsideDwellDoesNotStart() {
        let show = controller()
        show.setShowMode(true)
        show.arm()
        time += 0.1
        show.go()
        XCTAssertEqual(show.state, .armed("a"))
    }

    func testRepeatGoIgnored() {
        let show = controller()
        show.setShowMode(true)
        show.arm()
        time += 5
        show.go(isRepeat: true)
        XCTAssertEqual(show.state, .armed("a"))
    }

    func testArmRefusedWhenNotLoadedOrDeviceGone() {
        let show = controller(cues: [cue("a", loaded: false)])
        show.setShowMode(true)
        XCTAssertEqual(show.arm(), .notLoaded("a"))
        let other = controller()
        other.setShowMode(true)
        available = false
        XCTAssertEqual(other.arm(), .noHouseOutput)
    }

    func testArmRefusedOnSameDevice() {
        let show = controller()
        show.routing = OutputRouting(houseDeviceUID: "x", cueDeviceUID: "x")
        show.setShowMode(true)
        XCTAssertEqual(show.arm(), .sameOutput)
    }

    func testEngineFailureLeavesIdle() {
        let show = controller()
        show.setShowMode(true)
        house.failure = OutputError.engine("boom")
        XCTAssertNotNil(show.arm())
        XCTAssertEqual(show.state, .idle)
    }

    func testFullRunAdvancesPointerWithoutArmingNext() {
        let show = controller()
        armAndGo(show)
        XCTAssertEqual(show.state, .live("a"))
        house.render(seconds: 0.1)
        show.fadeOut()
        XCTAssertEqual(show.state, .fading("a"))
        house.render(seconds: 3.2)
        show.tick()
        XCTAssertEqual(show.state, .idle)
        XCTAssertEqual(show.nextIndex, 1)
        XCTAssertEqual(house.stops, 1)
        XCTAssertEqual(played, ["a"])
    }

    func testCannotLeaveShowModeWhileArmed() {
        let show = controller()
        show.setShowMode(true)
        show.arm()
        XCTAssertFalse(show.setShowMode(false))
        XCTAssertTrue(show.showMode)
    }

    func testPanicWorksOutsideShowModeGateAndEscalates() {
        let show = controller()
        armAndGo(show)
        house.render(seconds: 0.1)
        show.panicPressed()
        XCTAssertEqual(show.state, .panicking("a"))
        time += 0.5
        show.panicPressed()
        XCTAssertEqual(show.state, .idle)
        XCTAssertEqual(house.stops, 1)
    }

    func testDeviceLossKeepsPositionForManualRearm() {
        let show = controller()
        armAndGo(show)
        house.render(seconds: 1)
        available = false
        show.checkDevice()
        XCTAssertEqual(show.state, .faulted("a"))
        XCTAssertEqual(house.stops, 1)

        show.acknowledgeFault()
        available = true
        XCTAssertEqual(show.state, .idle)
        show.arm()
        XCTAssertEqual(show.state, .armed("a"))
        XCTAssertGreaterThan(house.kernel!.parameters.startFrame, 40_000)
    }

    func testHoldThenGoResumesAndCountsOnePlay() {
        let show = controller()
        armAndGo(show)
        show.hold()
        XCTAssertEqual(show.state, .held("a"))
        time += 0.1
        show.go()
        XCTAssertEqual(show.state, .held("a"), "GO right after Hold is ignored")
        time += 1
        show.go()
        XCTAssertEqual(show.state, .live("a"))
        XCTAssertEqual(played, ["a"], "resume is not a new play")
    }

    func testMarkerJumpOnlyWhenNotAudible() {
        let show = controller()
        show.setShowMode(true)
        show.arm()
        show.jumpMarker(forward: true)
        XCTAssertEqual(show.positionSec, 4, accuracy: 0.01)
        time += 1
        show.go()
        house.render(seconds: 0.1)
        show.tick()
        let here = show.positionSec
        show.jumpMarker(forward: false)
        house.render(seconds: 0.1)
        show.tick()
        XCTAssertGreaterThan(show.positionSec, here)
    }

    func testHoldRefusedDuringAutomaticFade() {
        var track = Track(title: "a")
        track.fadeOutSec = 5
        let buffer = PCMBuffer(left: [Float](repeating: 0.5, count: 240_000), right: nil, sampleRate: 48_000)
        let show = controller(cues: [ShowCue(id: "a", title: "a", track: track, buffer: buffer)])
        armAndGo(show)
        house.render(seconds: 2.7)
        show.tick()
        XCTAssertEqual(show.state, .fading("a"), "the screen says FADING as soon as the kernel does")
        show.hold()
        XCTAssertEqual(show.state, .fading("a"))
    }

    func testRemainingFollowsAManualFade() {
        let show = controller()
        armAndGo(show)
        house.render(seconds: 0.1)
        show.fadeOut()
        house.render(seconds: 0.1)
        show.tick()
        XCTAssertEqual(show.remainingSec, 2.9, accuracy: 0.05)
    }

    func testEmptyRangeRefusesToArm() {
        var track = Track(title: "a")
        track.startSec = 9
        track.endSec = 3
        let buffer = PCMBuffer(left: [Float](repeating: 0.5, count: 480_000), right: nil, sampleRate: 48_000)
        let show = controller(cues: [ShowCue(id: "a", title: "a", track: track, buffer: buffer)])
        show.setShowMode(true)
        XCTAssertEqual(show.arm(), .emptyRange("a"))
    }

    func testRefreshKeepsPointerAndAppliesEdits() {
        let show = controller()
        show.movePointer(by: 1)
        var edited = show.cues
        edited[1].gainDb = -3
        XCTAssertTrue(show.refresh(cues: edited))
        XCTAssertEqual(show.nextIndex, 1)
        XCTAssertEqual(show.cues[1].gainDb, -3)
        show.setShowMode(true)
        show.arm()
        XCTAssertFalse(show.refresh(cues: []))
    }

    func testResumeIsVisibleAndDisarmClearsIt() {
        let show = controller()
        armAndGo(show)
        house.render(seconds: 1)
        show.deviceLost()
        show.acknowledgeFault()
        XCTAssertGreaterThan(show.resumeSec ?? 0, 0.9)
        show.arm()
        show.disarm()
        XCTAssertNil(show.resumeSec)
        show.arm()
        XCTAssertEqual(house.kernel?.parameters.startFrame, 0)
    }

    func testLateLossNotificationDoesNotFaultIdleShow() {
        let show = controller()
        show.deviceLost()
        XCTAssertEqual(show.state, .idle)
    }

    func testPointerFrozenWhileArmed() {
        let show = controller()
        show.setShowMode(true)
        show.arm()
        show.movePointer(by: 1)
        XCTAssertEqual(show.nextIndex, 0)
    }

    func testLoadRefusedWhileEngineHeld() {
        let show = controller()
        show.setShowMode(true)
        show.arm()
        show.load(cues: [])
        XCTAssertEqual(show.cues.count, 2)
    }
}

extension PlaybackKernelTests {
    /// Largest step between neighbouring samples. A steady 1.0 source makes any jump in level show up.
    private func largestStep(_ samples: [Float]) -> Float {
        zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0
    }

    func testEndPulledInStillFadesForAtLeastTheDeclick() {
        let k = kernel(seconds: 10, end: 5, fade: 0.5)
        k.play()
        _ = render(k, seconds: 1)
        k.setEnd(toFrame: 0)
        let out = render(k, seconds: 0.1)
        let declick = Int(PlaybackKernel.declickSeconds * rate)
        XCTAssertEqual(k.phase, .finished)
        XCTAssertGreaterThanOrEqual(k.positionFrames, Int(rate) + declick)
        XCTAssertGreaterThanOrEqual(out.filter { $0 > 0 }.count, declick - 1, "no one-sample cut")
        XCTAssertLessThan(largestStep(out), 0.02)
    }

    func testBracketDuringAutomaticFadeRisesBackAndExtends() {
        let k = kernel(seconds: 10, end: 8, fade: 3)
        k.play()
        let before = render(k, seconds: 5.5)
        XCTAssertEqual(k.phase, .fading)
        k.setEnd(toFrame: Int(9 * rate))
        let rise = render(k, seconds: 0.4)
        XCTAssertEqual(k.phase, .playing)
        XCTAssertEqual(rise.last!, 1, accuracy: 1e-5)
        XCTAssertLessThan(largestStep([before.last!] + rise), 0.01, "rises smoothly from the fade level")
        let rest = render(k, seconds: 3.5)
        XCTAssertEqual(k.phase, .finished)
        XCTAssertEqual(k.positionFrames, Int(9 * rate))
        // The full saved fade still runs before the new end: it starts at 6 s, and rest starts at 5.9 s.
        XCTAssertEqual(rest[Int(1.6 * rate)], FadeCurve.down(0.5), accuracy: 1e-3)
    }

    func testBracketLateInAutomaticFadeRefadesFromCurrentLevel() {
        let k = kernel(seconds: 10, end: 5, fade: 3)
        k.play()
        let before = render(k, seconds: 4)
        k.setEnd(toFrame: Int(6 * rate))
        let rest = render(k, seconds: 2.5)
        XCTAssertEqual(k.positionFrames, Int(6 * rate))
        XCTAssertEqual(k.phase, .finished)
        XCTAssertLessThan(largestStep([before.last!] + rest), 0.01)
        XCTAssertGreaterThan(rest[Int(1 * rate)], 0.05, "still audible past the old end")
    }

    func testNudgeNeverUndoesManualFadeOrPanic() {
        let k = kernel(seconds: 20)
        k.play()
        _ = render(k, seconds: 1)
        k.fade(seconds: 1)
        k.setEnd(toFrame: Int(15 * rate))
        _ = render(k, seconds: 1.5)
        XCTAssertEqual(k.phase, .finished)
        XCTAssertEqual(k.positionFrames, Int(2 * rate), accuracy: 512)

        let p = kernel(seconds: 20)
        p.play()
        _ = render(p, seconds: 1)
        p.panic(seconds: 0.5)
        p.setEnd(toFrame: Int(15 * rate))
        _ = render(p, seconds: 1)
        XCTAssertEqual(p.phase, .finished)
    }

    func testResumeFromHoldKeepsFullEndFade() {
        let k = kernel(seconds: 10, fade: 3)
        k.play()
        _ = render(k, seconds: 6)
        k.hold()
        _ = render(k, seconds: 0.1)
        let held = k.positionFrames
        k.play()
        let out = render(k, seconds: 4.1)
        let fadeStart = Int(7 * rate) - held
        XCTAssertEqual(out[fadeStart - 1], 1, accuracy: 1e-5, "the fade does not start early")
        XCTAssertEqual(out[fadeStart + Int(1.5 * rate)], FadeCurve.down(0.5), accuracy: 1e-3)
        XCTAssertEqual(k.phase, .finished)
    }

    func testGoAfterMarkerJumpIntoEndFadeIsAudibleAndLands() {
        let k = kernel(seconds: 10, fade: 3)
        k.play()
        _ = render(k, seconds: 1)
        k.hold()
        _ = render(k, seconds: 0.1)
        k.seek(toFrame: Int(9.5 * rate))
        _ = render(k, seconds: 0.01)
        k.play()
        let out = render(k, seconds: 0.6)
        XCTAssertGreaterThan(out.max() ?? 0, 0.9)
        XCTAssertLessThan(largestStep(out), 0.05)
        XCTAssertEqual(k.phase, .finished)
        XCTAssertEqual(k.positionFrames, Int(10 * rate))
    }

    func testHoldJustBeforeFadePointStaysAHold() {
        let k = kernel(seconds: 10, fade: 3)
        k.play()
        _ = render(k, seconds: (7 * rate - 100) / rate)
        k.hold()
        _ = render(k, seconds: 0.1)
        XCTAssertEqual(k.phase, .paused, "a Hold is not turned into the end fade")
        k.play()
        _ = render(k, seconds: 3.1)
        XCTAssertEqual(k.phase, .finished)
        XCTAssertEqual(k.positionFrames, Int(10 * rate))
    }

    func testPanicDuringFadeInNeverGetsLouder() {
        let k = kernel(seconds: 10, fadeIn: 2)
        k.play()
        let before = render(k, seconds: 0.5)
        k.panic(seconds: 1)
        let out = render(k, seconds: 1.1)
        XCTAssertLessThanOrEqual(out.max() ?? 0, before.last! + 1e-3)
        XCTAssertEqual(k.phase, .finished)
    }
}

extension ShowControllerTests {
    private func cue(_ id: String, endSec: Double?, fadeOutSec: Double = 3, frames: Int = 480_000) -> ShowCue {
        var track = Track(title: id)
        track.endSec = endSec
        track.fadeOutSec = fadeOutSec
        return ShowCue(id: id, title: id, track: track, buffer: PCMBuffer(left: [Float](repeating: 0.5, count: frames), right: nil, sampleRate: 48_000))
    }

    private func loseDevice(_ show: ShowController) {
        show.deviceLost()
        show.acknowledgeFault()
    }

    func testDisarmWhileIdleClearsKeptStart() {
        let show = controller()
        armAndGo(show)
        house.render(seconds: 1)
        loseDevice(show)
        XCTAssertNotNil(show.resumeSec)
        show.disarm()
        XCTAssertNil(show.resumeSec)
        XCTAssertNil(show.arm())
        XCTAssertEqual(house.kernel?.parameters.startFrame, 0)
    }

    func testKeptPositionInsideEndFadeArmsFromTheTop() {
        let show = controller(cues: [cue("a", endSec: 5)])
        armAndGo(show)
        house.render(seconds: 3)
        show.deviceLost()
        show.acknowledgeFault()
        XCTAssertNil(show.arm())
        XCTAssertEqual(house.kernel?.parameters.startFrame, 0)
        XCTAssertNil(show.resumeSec)
    }

    func testKeptPositionPastAnEditedEndArmsFromTheTop() {
        let show = controller(cues: [cue("a", endSec: nil)])
        armAndGo(show)
        house.render(seconds: 4)
        loseDevice(show)
        show.refresh(cues: [cue("a", endSec: 2)])
        XCTAssertNil(show.arm(), "never refused with emptyRange")
        XCTAssertEqual(house.kernel?.parameters.startFrame, 0)
    }

    func testResumeKeepsTheSavedFadeLength() {
        let show = controller(cues: [cue("a", endSec: nil)])
        armAndGo(show)
        house.render(seconds: 5)
        loseDevice(show)
        XCTAssertNil(show.arm())
        let kernel = house.kernel!
        XCTAssertGreaterThan(kernel.parameters.startFrame, 200_000)
        time += 1
        show.go()
        // From 5 s with 5 s left, a halved lead would start the fade at 7.5 s. The saved 3 s fade starts at 7 s.
        house.render(seconds: 2.2)
        show.tick()
        XCTAssertEqual(show.state, .fading("a"))
    }

    func testDeviceLostDuringFadeOrPanicDoesNotKeepPosition() {
        let show = controller()
        armAndGo(show)
        house.render(seconds: 1)
        show.fadeOut()
        house.render(seconds: 0.1)
        loseDevice(show)
        XCTAssertNil(show.resumeSec)

        show.movePointer(by: 1)
        armAndGo(show)
        house.render(seconds: 1)
        show.panicPressed()
        house.render(seconds: 0.1)
        loseDevice(show)
        XCTAssertNil(show.resumeSec)
    }

    func testRefreshDropsKeptPositionWhenAudioChanges() {
        let show = controller()
        armAndGo(show)
        house.render(seconds: 1)
        loseDevice(show)
        var edited = show.cues
        edited[0].gainDb = -2
        show.refresh(cues: edited)
        XCTAssertNotNil(show.resumeSec, "a level change keeps the position")

        edited[0].buffer = PCMBuffer(left: [Float](repeating: 0.5, count: 240_000), right: nil, sampleRate: 48_000)
        show.refresh(cues: edited)
        XCTAssertNil(show.resumeSec)
    }

    func testRefreshDropsKeptPositionWhenTrackChanges() {
        let show = controller()
        armAndGo(show)
        house.render(seconds: 1)
        loseDevice(show)
        var edited = show.cues
        edited[0].track = Track(title: "other")
        show.refresh(cues: edited)
        XCTAssertNil(show.resumeSec)
    }

    func testTwoQuickNudgesBothApply() {
        let show = controller(cues: [cue("a", endSec: 6)])
        armAndGo(show)
        house.render(seconds: 0.1)
        show.nudgeEnd(seconds: 1)
        show.nudgeEnd(seconds: 1)
        house.render(seconds: 0.01)
        show.tick()
        XCTAssertEqual(show.endSec, 8, accuracy: 0.001)
    }

    func testBracketDuringAutomaticFadeReturnsToLive() {
        let show = controller(cues: [cue("a", endSec: 5)])
        armAndGo(show)
        house.render(seconds: 2.5)
        show.tick()
        XCTAssertEqual(show.state, .fading("a"))
        show.nudgeEnd(seconds: 1)
        house.render(seconds: 0.4)
        show.tick()
        XCTAssertEqual(show.state, .live("a"))
        XCTAssertEqual(show.endSec, 6, accuracy: 0.001)
        house.render(seconds: 3.7)
        show.tick()
        XCTAssertEqual(show.state, .idle)
    }

    func testBracketAfterFIsIgnored() {
        let show = controller(cues: [cue("a", endSec: 5)])
        armAndGo(show)
        house.render(seconds: 2.5)
        show.tick()
        XCTAssertEqual(show.state, .fading("a"))
        show.fadeOut()
        show.nudgeEnd(seconds: 1)
        house.render(seconds: 0.4)
        show.tick()
        XCTAssertEqual(show.state, .fading("a"), "F during the automatic fade is final")

        let manual = controller()
        armAndGo(manual)
        house.render(seconds: 1)
        manual.fadeOut()
        manual.nudgeEnd(seconds: 5)
        house.render(seconds: 3.2)
        manual.tick()
        XCTAssertEqual(manual.state, .idle)
    }

    func testEngineThatStoppedByItselfFaults() {
        let show = controller()
        armAndGo(show)
        house.running = false
        show.checkDevice()
        XCTAssertEqual(show.state, .faulted("a"))
    }

    func testMissingChannelPairRefusesWithReadableReason() {
        let show = controller()
        show.setShowMode(true)
        house.failure = OutputError.channelPairMissing(firstChannel: 4, deviceChannels: 2)
        guard case .deviceFailed(let reason) = show.arm() else { return XCTFail("expected a device refusal") }
        XCTAssertTrue(reason.contains("Outputs 5-6"), reason)
        XCTAssertEqual(show.state, .idle)
    }

    func testDeviceLostLogNamesTheCue() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("runlog.jsonl")
        let log = RunLog(url: url)
        time = 100
        house = FakeHouse()
        let show = ShowController(house: house, log: log, clock: { [unowned self] in time }, deviceAvailable: { _ in true })
        show.routing = OutputRouting(houseDeviceUID: "house", cueDeviceUID: "cue")
        show.load(cues: [cue("Anthem", endSec: nil)])
        armAndGo(show)
        show.deviceLost()
        log.flush()
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        let lost = try XCTUnwrap(lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] }
            .first { $0["event"] == "device-lost" })
        XCTAssertEqual(lost["cue"], "Anthem")
    }
}

final class OutputPairTests: XCTestCase {
    func testPairMustExistOnTheDevice() {
        XCTAssertNoThrow(try OutputEngine.validatePair(firstChannel: 0, deviceChannels: 2))
        XCTAssertNoThrow(try OutputEngine.validatePair(firstChannel: 0, deviceChannels: 1))
        XCTAssertNoThrow(try OutputEngine.validatePair(firstChannel: 2, deviceChannels: 8))
        XCTAssertNoThrow(try OutputEngine.validatePair(firstChannel: 6, deviceChannels: 8))
        XCTAssertThrowsError(try OutputEngine.validatePair(firstChannel: 2, deviceChannels: 2))
        XCTAssertThrowsError(try OutputEngine.validatePair(firstChannel: 7, deviceChannels: 8))
        XCTAssertThrowsError(try OutputEngine.validatePair(firstChannel: 8, deviceChannels: 8))
        XCTAssertThrowsError(try OutputEngine.validatePair(firstChannel: -2, deviceChannels: 8))
        XCTAssertThrowsError(try OutputEngine.validatePair(firstChannel: 4, deviceChannels: 4)) { error in
            XCTAssertEqual(error as? OutputError, .channelPairMissing(firstChannel: 4, deviceChannels: 4))
        }
    }
}

final class PCMDecoderTests: XCTestCase {
    private func writeWAV(frames: Int) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("t.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for n in 0..<frames {
            buffer.floatChannelData![0][n] = Float(n % 1000) / 1000
            buffer.floatChannelData![1][n] = -Float(n % 1000) / 1000
        }
        try file.write(from: buffer)
        return url
    }

    // Review 3, finding 11.
    func testBadFloatSamplesAreZeroedSoTheEQKeepsPlaying() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("bad.wav")
        let frames = 48_000
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = AVAudioFrameCount(frames)
            for n in 0..<frames {
                let value = Float(0.25 * sin(2 * .pi * 440 * Double(n) / 48_000))
                buffer.floatChannelData![0][n] = value
                buffer.floatChannelData![1][n] = value
            }
            buffer.floatChannelData![0][10_000] = .nan
            buffer.floatChannelData![1][20_000] = .infinity
            try file.write(from: buffer)
        }
        let decoded = try PCMDecoder.decode(url: url)
        XCTAssertTrue((0..<decoded.frames).allSatisfy { decoded.left[$0].isFinite && decoded.right[$0].isFinite })
        XCTAssertEqual(decoded.left[10_000], 0)

        var eq = TrackEQ()
        eq.bands[3].frequency = 440
        eq.bands[3].gainDb = 3
        let kernel = PlaybackKernel(buffer: decoded, parameters: PlaybackParameters(
            startFrame: 0, endFrame: frames, fadeOutFrames: 0, fadeInFrames: 0, gainLinear: 1, eq: EQCoefficients(eq, sampleRate: 48_000)
        ))
        kernel.play()
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { left.deallocate(); right.deallocate() }
        kernel.render(frames: frames, left: left, right: right)
        XCTAssertTrue((0..<frames).allSatisfy { left[$0].isFinite && right[$0].isFinite })
        XCTAssertGreaterThan((40_000..<41_000).map { abs(left[$0]) }.max() ?? 0, 0.2, "still playing after the bad sample")
    }

    func testReadsEveryChunkToTheEnd() throws {
        let url = try writeWAV(frames: 10_000)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let buffer = try PCMDecoder.decode(url: url, chunkFrames: 4096)
        XCTAssertEqual(buffer.frames, 10_000)
        XCTAssertEqual(buffer.left[9_999], 0.999, accuracy: 1e-4)
        XCTAssertEqual(buffer.right[4_500], -0.5, accuracy: 1e-4)
    }

    func testExactLengthDecodeIsUnchanged() throws {
        let url = try writeWAV(frames: 48_000)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let buffer = try PCMDecoder.decode(url: url)
        XCTAssertEqual(buffer.frames, 48_000)
        XCTAssertEqual(buffer.sampleRate, 48_000)
        XCTAssertEqual(buffer.left[47_999], 0.999, accuracy: 1e-4)
    }
}

final class LoudnessTests: XCTestCase {
    private func sine(frequency: Double, dbfs: Double, seconds: Double, rate: Double = 48_000) -> PCMBuffer {
        let amplitude = pow(10, dbfs / 20)
        let samples = (0..<Int(seconds * rate)).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / rate)) }
        return PCMBuffer(left: samples, right: samples, sampleRate: rate)
    }

    func testEBUReferenceTone() throws {
        // EBU Tech 3341 case 1: stereo 997 Hz at -23 dBFS reads -23.0 LUFS.
        let lufs = try XCTUnwrap(LoudnessMeter.integrated(sine(frequency: 997, dbfs: -23, seconds: 20)))
        XCTAssertEqual(lufs, -23, accuracy: 0.1)
    }

    func testSampleRateIndependent() throws {
        let lufs = try XCTUnwrap(LoudnessMeter.integrated(sine(frequency: 997, dbfs: -23, seconds: 20, rate: 44_100)))
        XCTAssertEqual(lufs, -23, accuracy: 0.1)
    }

    func testGatingIgnoresSilence() throws {
        let tone = sine(frequency: 997, dbfs: -23, seconds: 10)
        let padded = [Float](UnsafeBufferPointer(start: tone.left, count: tone.frames)) + [Float](repeating: 0, count: 48_000 * 30)
        let lufs = try XCTUnwrap(LoudnessMeter.integrated(PCMBuffer(left: padded, right: padded, sampleRate: 48_000)))
        XCTAssertEqual(lufs, -23, accuracy: 0.2)
    }

    func testTruePeakSeesInterSamplePeak() {
        // A tone at fs/4 sampled 45 degrees off the crest: samples read -3 dB, the wave reaches 0 dB.
        let samples: [Float] = (0..<4800).map { (n: Int) -> Float in
            let phase: Double = Double.pi / 2 * Double(n) + Double.pi / 4
            return Float(sin(phase))
        }
        let buffer = PCMBuffer(left: samples, right: samples, sampleRate: 48_000)
        XCTAssertEqual(LoudnessMeter.truePeakDb(buffer), 0, accuracy: 0.6)
    }

    func testGainCapRespectsCeiling() {
        let open = LoudnessMeter.gain(lufs: -22, truePeakDb: -8, targetLUFS: -18)
        XCTAssertEqual(open.gainDb, 4)
        XCTAssertFalse(open.capped)
        let capped = LoudnessMeter.gain(lufs: -24, truePeakDb: -3, targetLUFS: -18)
        XCTAssertEqual(capped.gainDb, 2)
        XCTAssertTrue(capped.capped)
    }

    func testSuggestedEndFindsTail() {
        let tone = [Float](repeating: 0.5, count: 48_000 * 2)
        let buffer = PCMBuffer(left: tone + [Float](repeating: 0.0001, count: 48_000 * 3), right: nil, sampleRate: 48_000)
        XCTAssertEqual(TrackAnalyzer.analyze(buffer).suggestedEndSec ?? 0, 2, accuracy: 0.001)
    }

    func testPeakBucketsReduce() {
        let buffer = PCMBuffer(left: [Float](repeating: 0.5, count: 10_000), right: nil, sampleRate: 48_000)
        let peaks = TrackAnalyzer.peaks(buffer, buckets: 100)
        XCTAssertEqual(peaks.count, 100)
        XCTAssertTrue(peaks.allSatisfy { $0 == 0.5 })
    }
}
