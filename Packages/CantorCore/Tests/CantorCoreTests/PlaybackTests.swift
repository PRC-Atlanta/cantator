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

    func testArmRefusedOutsideShowMode() {
        let show = controller()
        XCTAssertEqual(show.arm(), .notInShowMode)
        XCTAssertEqual(house.starts, 0)
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
