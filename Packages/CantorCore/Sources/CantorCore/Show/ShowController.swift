import Foundation
import Observation

/// A cue as the show sees it: everything needed to play with no disk or network.
public struct ShowCue: Identifiable, Sendable {
    public var id: CueID
    public var title: String
    public var notes: String
    public var track: Track?
    public var buffer: PCMBuffer?
    public var gainDb: Double

    public init(id: CueID, title: String, notes: String = "", track: Track?, buffer: PCMBuffer?, gainDb: Double = 0) {
        self.id = id
        self.title = title
        self.notes = notes
        self.track = track
        self.buffer = buffer
        self.gainDb = gainDb
    }

    public var isPlayable: Bool { track != nil && buffer != nil }
}

public enum ArmRefusal: Equatable, Sendable {
    case notInShowMode, noCue, noHouseOutput, sameOutput, notLoaded(String), notIdle, deviceFailed(String), emptyRange(String)

    public var message: String {
        switch self {
        case .notInShowMode: "Turn on Show Mode to arm."
        case .noCue: "No cue selected."
        case .noHouseOutput: "House output is not available."
        case .sameOutput: "House and cue must be different devices."
        case .notLoaded(let title): "\(title) is not loaded."
        case .notIdle: "Finish the current cue first."
        case .deviceFailed(let reason): reason
        case .emptyRange(let title): "\(title) has no audio between its start and end points."
        }
    }
}

/// The only owner of the house output. Every path to sound runs through `go`.
@MainActor
@Observable
public final class ShowController {
    public private(set) var state: ShowState = .idle
    public private(set) var showMode = false
    public private(set) var cues: [ShowCue] = []
    public var nextIndex = 0
    public private(set) var positionSec = 0.0
    public private(set) var endSec = 0.0
    public private(set) var peakLeft: Float = 0
    public private(set) var peakRight: Float = 0
    public private(set) var armedSince: Date?
    public private(set) var notice: String?

    public var routing = OutputRouting()
    public var panicFadeSec = 1.5
    public var onPlayed: ((Track) -> Void)?

    @ObservationIgnored private var machine = ShowStateMachine()
    @ObservationIgnored private var goGuard = GoGuard()
    @ObservationIgnored private var panicGate = PanicGate()
    @ObservationIgnored private var kernel: PlaybackKernel?
    @ObservationIgnored private var retained: [CueID: Int] = [:]
    @ObservationIgnored private let house: HouseOutput
    @ObservationIgnored private let clock: () -> TimeInterval
    @ObservationIgnored private let log: RunLog?
    @ObservationIgnored private let deviceAvailable: (String) -> Bool

    public init(
        house: HouseOutput, log: RunLog? = nil, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        deviceAvailable: @escaping (String) -> Bool = { AudioDevices.isAlive(uid: $0) }
    ) {
        self.house = house
        self.log = log
        self.clock = clock
        self.deviceAvailable = deviceAvailable
    }

    public var activeCue: ShowCue? { state.cueID.flatMap { id in cues.first { $0.id == id } } }
    public var pointedCue: ShowCue? { cues.indices.contains(nextIndex) ? cues[nextIndex] : nil }
    public var upcomingCue: ShowCue? {
        guard let id = state.cueID, let index = cues.firstIndex(where: { $0.id == id }) else { return pointedCue }
        return cues.indices.contains(index + 1) ? cues[index + 1] : nil
    }
    public var remainingSec: Double { max(endSec - positionSec, 0) }
    public var isFading: Bool { if case .fading = state { true } else { false } }

    // MARK: Setup

    public func load(cues: [ShowCue]) {
        guard !state.holdsHouseEngine else { return }
        self.cues = cues
        nextIndex = 0
        retained = [:]
    }

    /// Applies edits to the same service, keeping the pointer. Returns false while a cue is engaged.
    @discardableResult
    public func refresh(cues: [ShowCue]) -> Bool {
        guard !state.holdsHouseEngine else { return false }
        let pointed = pointedCue?.id
        self.cues = cues
        nextIndex = cues.firstIndex { $0.id == pointed } ?? min(nextIndex, max(cues.count - 1, 0))
        return true
    }

    /// Where the pointed cue will start if it is not at its start point.
    public var resumeSec: Double? {
        guard let cue = activeCue ?? pointedCue, let frame = retained[cue.id], let rate = cue.buffer?.sampleRate else { return nil }
        return Double(frame) / rate
    }

    @discardableResult
    public func setShowMode(_ enabled: Bool) -> Bool {
        if !enabled, state.holdsHouseEngine {
            notice = "Stop the cue before leaving Show Mode."
            return false
        }
        showMode = enabled
        notice = nil
        return true
    }

    public func movePointer(by delta: Int) {
        guard !state.isAudible, case .idle = state, !cues.isEmpty else { return }
        nextIndex = min(max(nextIndex + delta, 0), cues.count - 1)
        notice = nil
    }

    // MARK: Transport

    @discardableResult
    public func arm() -> ArmRefusal? {
        let refusal = attemptArm()
        notice = refusal?.message
        return refusal
    }

    private func attemptArm() -> ArmRefusal? {
        guard showMode else { return .notInShowMode }
        guard case .idle = state else { return .notIdle }
        guard let cue = pointedCue else { return .noCue }
        guard let track = cue.track, let buffer = cue.buffer else { return .notLoaded(cue.title) }
        guard !routing.isSameDevice else { return .sameOutput }
        guard let uid = routing.houseDeviceUID, deviceAvailable(uid) else { return .noHouseOutput }

        var parameters = PlaybackParameters(track: track, sampleRate: buffer.sampleRate, frames: buffer.frames, gainDb: cue.gainDb)
        if let frame = retained[cue.id] { parameters.startFrame = frame }
        guard parameters.startFrame < parameters.endFrame else { return .emptyRange(cue.title) }
        let kernel = PlaybackKernel(buffer: buffer, parameters: parameters)
        do {
            try house.start(kernel: kernel, deviceUID: uid, firstChannel: routing.houseFirstChannel)
        } catch {
            return .deviceFailed(error.localizedDescription)
        }
        self.kernel = kernel
        apply(.arm(cue.id))
        goGuard.noteArmed(at: clock())
        armedSince = Date()
        refreshTelemetry()
        log?.record("arm", cue: cue.title)
        return nil
    }

    /// Also forgets a kept position, so disarm then arm starts the cue from the top.
    public func disarm() {
        if let id = state.cueID, case .armed = state { retained[id] = nil }
        apply(.disarm)
    }

    /// `isRepeat` comes from the key event. A held key must never start a track.
    public func go(isRepeat: Bool = false) {
        guard showMode, goGuard.allowsGo(at: clock(), isRepeat: isRepeat) else { return }
        let isNewStart: Bool
        switch state {
        case .armed: isNewStart = true
        case .held: isNewStart = false
        default: return
        }
        apply(.go)
        if let cue = activeCue {
            log?.record("go", cue: cue.title)
            if isNewStart, retained[cue.id] == nil, let track = cue.track { onPlayed?(track) }
            retained[cue.id] = nil
        }
    }

    public func hold() {
        guard showMode, kernel?.phase != .fading else { return }
        apply(.hold)
        goGuard.noteArmed(at: clock())
    }

    public func fadeOut() {
        guard showMode else { return }
        apply(.fade)
    }

    /// Works in every mode and view. A second press within a second stops hard.
    public func panicPressed() {
        guard state.holdsHouseEngine else { return }
        switch panicGate.press(at: clock()) {
        case .fade: apply(.panic)
        case .hardStop: apply(.hardStop)
        }
    }

    public func jumpMarker(forward: Bool) {
        switch state {
        case .armed, .held: break
        default: return
        }
        guard let track = activeCue?.track, let kernel else { return }
        let rate = kernel.buffer.sampleRate
        let stops = ([track.startSec] + track.markers.map(\.seconds)).sorted().map { Int($0 * rate) }
        let here = kernel.positionFrames
        let target = forward ? stops.first { $0 > here + 1 } : stops.last { $0 < here - Int(rate / 2) }
        guard let target else { return }
        kernel.seek(toFrame: target)
        positionSec = Double(target) / rate
        log?.record("marker", cue: track.title)
    }

    /// Moves the end for this run only. The saved end point is untouched.
    public func nudgeEnd(seconds: Double) {
        guard case .live = state, let kernel else { return }
        kernel.setEnd(toFrame: kernel.currentEndFrame + Int(seconds * kernel.buffer.sampleRate))
    }

    public func acknowledgeFault() {
        apply(.acknowledgeFault)
        notice = nil
    }

    /// A late notification from an engine that has already stopped must not fault an idle show.
    public func deviceLost() {
        guard state.holdsHouseEngine else { return }
        if let id = state.cueID, let kernel {
            retained[id] = kernel.positionFrames
        }
        apply(.deviceLost)
        notice = "House output stopped. Press Return to acknowledge, then re-arm."
        log?.record("device-lost", cue: nil)
    }

    /// Call from a display-rate timer. Reads render-thread telemetry and notices the end of a cue.
    public func tick() {
        refreshTelemetry()
        switch kernel?.phase {
        case .finished: apply(.finished)
        case .fading: apply(.autoFadeStarted)
        default: break
        }
    }

    /// Call about once a second and on device changes. This goes to Core Audio, so it stays off the display timer.
    public func checkDevice() {
        if let uid = routing.houseDeviceUID, state.holdsHouseEngine, !deviceAvailable(uid) {
            deviceLost()
        }
    }

    private func refreshTelemetry() {
        guard let kernel else {
            peakLeft = 0
            peakRight = 0
            return
        }
        let rate = kernel.buffer.sampleRate
        positionSec = Double(kernel.positionFrames) / rate
        endSec = Double(kernel.currentEndFrame) / rate
        let peaks = kernel.takePeaks()
        peakLeft = peaks.left
        peakRight = peaks.right
    }

    private func apply(_ event: ShowEvent) {
        let finishedCue = activeCue
        let effects = machine.handle(event)
        state = machine.state
        for effect in effects {
            switch effect {
            case .prepare:
                break
            case .start:
                kernel?.play()
            case .hold:
                kernel?.hold()
            case .fade:
                kernel?.fade(seconds: max(activeCue?.track?.fadeOutSec ?? 3, 0.05))
                log?.record("fade", cue: activeCue?.title)
            case .panic:
                kernel?.panic(seconds: panicFadeSec)
                log?.record("panic", cue: activeCue?.title)
            case .hardStop:
                kernel?.stop()
                log?.record("hard-stop", cue: finishedCue?.title)
            case .teardown:
                house.stop()
                kernel = nil
                goGuard.clear()
                armedSince = nil
                positionSec = 0
                endSec = 0
                refreshTelemetry()
            }
        }
        if event == .finished, let finishedCue {
            log?.record("finished", cue: finishedCue.title)
            if let index = cues.firstIndex(where: { $0.id == finishedCue.id }), index + 1 < cues.count {
                nextIndex = index + 1
            }
        }
    }
}
