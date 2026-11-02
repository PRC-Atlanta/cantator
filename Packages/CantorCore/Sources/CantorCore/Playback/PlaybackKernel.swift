import Foundation
import Synchronization

/// Equal-power fade shapes. Progress runs 0 to 1.
public enum FadeCurve {
    public static func down(_ progress: Double) -> Float {
        Float(cos(min(max(progress, 0), 1) * .pi / 2))
    }

    public static func up(_ progress: Double) -> Float {
        Float(sin(min(max(progress, 0), 1) * .pi / 2))
    }
}

public struct PlaybackParameters: Sendable {
    public var startFrame: Int
    public var endFrame: Int
    public var fadeOutFrames: Int
    public var fadeInFrames: Int
    public var gainLinear: Float
    public var eq: EQCoefficients

    public init(startFrame: Int, endFrame: Int, fadeOutFrames: Int, fadeInFrames: Int, gainLinear: Float, eq: EQCoefficients = .flat) {
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.fadeOutFrames = fadeOutFrames
        self.fadeInFrames = fadeInFrames
        self.gainLinear = gainLinear
        self.eq = eq
    }

    public init(track: Track, sampleRate: Double, frames: Int, gainDb: Double) {
        let toFrames = { (s: Double) in Int((s * sampleRate).rounded()) }
        let end = max(min(track.endSec.map(toFrames) ?? frames, frames), 0)
        self.init(
            startFrame: min(max(toFrames(track.startSec), 0), end),
            endFrame: end,
            fadeOutFrames: toFrames(track.fadeOutSec),
            fadeInFrames: toFrames(track.fadeInSec),
            gainLinear: Float(pow(10, gainDb / 20)),
            eq: EQCoefficients(track.eq, sampleRate: sampleRate)
        )
    }
}

public enum KernelPhase: UInt8, Sendable {
    case paused, playing, fading, finished
}

/// Real-time playback core. The control thread posts commands; `render` runs on the audio thread
/// and does no locking, allocation or file access. It has no Core Audio dependency, so tests can
/// drive it offline and inspect every sample.
public final class PlaybackKernel: @unchecked Sendable {
    public static let declickSeconds = 0.005
    /// How long `]` takes to bring an automatic end fade back up to full level.
    static let recoverSeconds = 0.25

    enum Command {
        case play
        case hold
        case fade(frames: Int)
        case panic(frames: Int)
        case stop
        case seek(frame: Int)
        case setEnd(frame: Int)
        case setEQ(EQCoefficients)
    }

    private enum RampKind { case up, down }
    private enum RampAction { case none, pause, finish }

    private static let ringCapacity = 32

    public let buffer: PCMBuffer
    public let parameters: PlaybackParameters
    private let declickFrames: Int
    private let recoverFrames: Int
    /// Where the automatic end fade begins, counted back from the end. Fixed when armed, so Hold and
    /// marker jumps cannot shorten it.
    private let fadeLead: Int

    // Single-producer, single-consumer command ring.
    private let ring: UnsafeMutablePointer<Command>
    private let ringHead = Atomic<Int>(0)
    private let ringTail = Atomic<Int>(0)

    // EQ sections as b0, b1, b2, a1, a2 runs, and two states per section per channel.
    private let eqCoefficients: UnsafeMutablePointer<Double>
    private let eqState: UnsafeMutablePointer<Double>
    private var eqCount = 0
    private var eqOutput: Float = 1

    // Telemetry, written by the render thread.
    private let telemetryPosition = Atomic<Int>(0)
    private let telemetryEnd = Atomic<Int>(0)
    private let telemetryPhase = Atomic<UInt8>(KernelPhase.paused.rawValue)
    private let telemetryPeakL = Atomic<UInt32>(0)
    private let telemetryPeakR = Atomic<UInt32>(0)

    // Render-thread state.
    private var position: Int
    private var endFrame: Int
    private var playing = false
    private var finished = false
    private var envelope: Float = 0
    private var rampActive = false
    private var rampKind = RampKind.down
    private var rampFrom: Float = 0
    private var rampPosition = 0
    private var rampLength = 0
    private var rampAction = RampAction.none
    // The rise at each GO, multiplied with the envelope so a run that starts inside its end fade
    // is still heard.
    private var entryActive = false
    private var entryPosition = 0
    private var entryLength = 0
    private var isFadingOut = false
    /// F or panic: the operator is ending the cue, so nothing may bring it back up.
    private var isStopping = false
    private var didFadeIn = false

    /// `runStartFrame` is where the run would begin from the top. A resume passes the cue's own start
    /// point, so the end fade keeps its saved length. Defaults to `parameters.startFrame`.
    public init(buffer: PCMBuffer, parameters: PlaybackParameters, runStartFrame: Int? = nil) {
        self.buffer = buffer
        self.parameters = parameters
        declickFrames = Self.declickFrames(sampleRate: buffer.sampleRate)
        recoverFrames = max(Int(buffer.sampleRate * Self.recoverSeconds), declickFrames)
        endFrame = max(min(parameters.endFrame, buffer.frames), 0)
        position = min(max(parameters.startFrame, 0), endFrame)
        fadeLead = Self.fadeLeadFrames(
            fadeOutFrames: parameters.fadeOutFrames, declickFrames: declickFrames,
            run: endFrame - min(max(runStartFrame ?? parameters.startFrame, 0), endFrame)
        )
        ring = .allocate(capacity: Self.ringCapacity)
        ring.initialize(repeating: .stop, count: Self.ringCapacity)
        eqCoefficients = .allocate(capacity: EQCoefficients.capacity * EQCoefficients.stride)
        eqCoefficients.initialize(repeating: 0, count: EQCoefficients.capacity * EQCoefficients.stride)
        eqState = .allocate(capacity: EQCoefficients.capacity * 4)
        eqState.initialize(repeating: 0, count: EQCoefficients.capacity * 4)
        parameters.eq.write(to: eqCoefficients)
        eqCount = parameters.eq.count
        eqOutput = parameters.eq.outputGain
        telemetryPosition.store(position, ordering: .relaxed)
        telemetryEnd.store(endFrame, ordering: .relaxed)
    }

    deinit {
        ring.deinitialize(count: Self.ringCapacity)
        ring.deallocate()
        eqCoefficients.deallocate()
        eqState.deallocate()
    }

    static func declickFrames(sampleRate: Double) -> Int {
        max(Int(sampleRate * declickSeconds), 1)
    }

    /// A run shorter than its fade would otherwise never get above silence, so it fades over its second half.
    static func fadeLeadFrames(fadeOutFrames: Int, declickFrames: Int, run: Int) -> Int {
        min(max(fadeOutFrames, declickFrames), max(run / 2, 1))
    }

    /// The fade lead for a run from `parameters.startFrame`, as the kernel would use it.
    static func fadeLeadFrames(_ parameters: PlaybackParameters, sampleRate: Double) -> Int {
        fadeLeadFrames(
            fadeOutFrames: parameters.fadeOutFrames, declickFrames: declickFrames(sampleRate: sampleRate),
            run: parameters.endFrame - parameters.startFrame
        )
    }

    // MARK: Control thread

    public func play() { post(.play) }
    public func hold() { post(.hold) }
    public func fade(seconds: Double) { post(.fade(frames: Int(seconds * buffer.sampleRate))) }
    public func panic(seconds: Double) { post(.panic(frames: Int(seconds * buffer.sampleRate))) }
    public func stop() { post(.stop) }
    public func seek(toFrame frame: Int) { post(.seek(frame: frame)) }
    public func setEnd(toFrame frame: Int) { post(.setEnd(frame: frame)) }
    /// Changes the EQ while playing. Used by preview, so the operator hears edits as they make them.
    public func setEQ(_ eq: EQCoefficients) { post(.setEQ(eq)) }

    private func post(_ command: Command) {
        let tail = ringTail.load(ordering: .relaxed)
        let next = (tail + 1) % Self.ringCapacity
        guard next != ringHead.load(ordering: .acquiring) else { return }
        ring[tail] = command
        ringTail.store(next, ordering: .releasing)
    }

    public var phase: KernelPhase { KernelPhase(rawValue: telemetryPhase.load(ordering: .relaxed)) ?? .paused }
    public var positionFrames: Int { telemetryPosition.load(ordering: .relaxed) }
    public var currentEndFrame: Int { telemetryEnd.load(ordering: .relaxed) }

    /// Returns the peak since the last call, for meters.
    public func takePeaks() -> (left: Float, right: Float) {
        let l = telemetryPeakL.exchange(0, ordering: .relaxed)
        let r = telemetryPeakR.exchange(0, ordering: .relaxed)
        return (Float(bitPattern: l), Float(bitPattern: r))
    }

    // MARK: Render thread

    public func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        drainCommands()
        let srcL = buffer.left
        let srcR = buffer.right
        var peakL: Float = 0
        var peakR: Float = 0
        let gain = parameters.gainLinear * eqOutput
        var i = 0

        while i < frames {
            guard playing else { break }
            if position >= endFrame {
                finishNow()
                break
            }
            // A Hold, or the rise back up after `]`, finishes before the end fade can begin.
            if !isFadingOut, !rampActive, position >= endFrame - fadeLead {
                beginRamp(.down, length: endFrame - position, action: .finish)
                isFadingOut = true
            }

            let sampleGain = nextEnvelope() * gain
            var inL = srcL[position]
            var inR = srcR[position]
            if eqCount > 0 { equalize(&inL, &inR) }
            let outL = inL * sampleGain
            let outR = inR * sampleGain
            left[i] = outL
            right[i] = outR
            peakL = max(peakL, abs(outL))
            peakR = max(peakR, abs(outR))
            position += 1
            i += 1

            if rampActive, rampPosition >= rampLength {
                completeRamp()
            }
            if entryActive, entryPosition >= entryLength {
                entryActive = false
            }
        }

        while i < frames {
            left[i] = 0
            right[i] = 0
            i += 1
        }

        publish(peakL: peakL, peakR: peakR)
    }

    private func drainCommands() {
        var head = ringHead.load(ordering: .relaxed)
        let tail = ringTail.load(ordering: .acquiring)
        while head != tail {
            apply(ring[head])
            head = (head + 1) % Self.ringCapacity
        }
        ringHead.store(head, ordering: .releasing)
    }

    private func apply(_ command: Command) {
        guard !finished else { return }
        switch command {
        case .play:
            guard !playing else { return }
            guard position < endFrame else {
                finishNow()
                return
            }
            playing = true
            // The envelope is at full and the entry ramp brings the sound in. An end fade that
            // starts at once then fades from the level the entry ramp reaches, not from silence.
            envelope = 1
            rampActive = false
            let wantsFadeIn = !didFadeIn && parameters.fadeInFrames > declickFrames
            didFadeIn = true
            entryLength = wantsFadeIn ? parameters.fadeInFrames : declickFrames
            entryPosition = 0
            entryActive = true

        case .hold:
            guard playing, !isFadingOut else { return }
            foldEntry()
            beginRamp(.down, length: declickFrames, action: .pause)

        case .fade(let requested):
            guard playing else { return }
            isStopping = true
            let length = max(min(requested, endFrame - position), 1)
            if isFadingOut, rampActive, length >= rampLength - rampPosition { return }
            foldEntry()
            beginRamp(.down, length: length, action: .finish)
            isFadingOut = true

        case .panic(let requested):
            guard playing else {
                finishNow()
                return
            }
            isStopping = true
            let length = max(requested, 1)
            if isFadingOut, rampActive, length >= rampLength - rampPosition { return }
            foldEntry()
            beginRamp(.down, length: length, action: .finish)
            isFadingOut = true
            // Panic may run past the marker; it must always be able to complete.
            endFrame = min(max(endFrame, position + length), buffer.frames)
            if position + length > buffer.frames {
                rampLength = max(buffer.frames - position, 1)
            }

        case .stop:
            finishNow()

        case .seek(let frame):
            guard !playing else { return }
            position = min(max(frame, 0), max(endFrame - 1, 0))
            clearEQState()

        case .setEnd(let frame):
            // F and panic are the operator ending the cue. A nudge never undoes them.
            guard !isStopping else { return }
            // Never so close that the end fade would be shorter than the declick.
            endFrame = min(max(frame, position + declickFrames), buffer.frames)
            // Otherwise the render loop starts the end fade where the new end needs it.
            guard isFadingOut || (rampActive && rampKind == .up) else { return }
            // Inside the automatic end fade: rise back to full when there is room before the new
            // fade point, or else fade again from the current level to land on the new end.
            let room = endFrame - fadeLead - position
            if room >= declickFrames {
                isFadingOut = false
                beginRamp(.up, length: min(room, recoverFrames), action: .none)
            } else {
                beginRamp(.down, length: endFrame - position, action: .finish)
                isFadingOut = true
            }

        case .setEQ(let eq):
            // Sections keep their history while a knob moves. A band turned on or off shifts the
            // sections, so their history no longer fits and starts over.
            if eq.count != eqCount { clearEQState() }
            eq.write(to: eqCoefficients)
            eqCount = eq.count
            eqOutput = eq.outputGain
        }
    }

    @inline(__always)
    private func equalize(_ left: inout Float, _ right: inout Float) {
        var l = Double(left)
        var r = Double(right)
        for section in 0..<eqCount {
            let c = eqCoefficients + section * EQCoefficients.stride
            let s = eqState + section * 4
            // Transposed direct form II, one pair of states per channel.
            let yl = c[0] * l + s[0]
            s[0] = c[1] * l - c[3] * yl + s[1]
            s[1] = c[2] * l - c[4] * yl
            let yr = c[0] * r + s[2]
            s[2] = c[1] * r - c[3] * yr + s[3]
            s[3] = c[2] * r - c[4] * yr
            l = yl
            r = yr
        }
        left = Float(l)
        right = Float(r)
    }

    private func clearEQState() {
        eqState.update(repeating: 0, count: EQCoefficients.capacity * 4)
    }

    private func beginRamp(_ kind: RampKind, length: Int, action: RampAction) {
        rampKind = kind
        rampFrom = envelope
        rampPosition = 0
        rampLength = max(length, 1)
        rampAction = action
        rampActive = true
    }

    /// Bakes the entry ramp's current level into the envelope, so an operator's Hold, F or panic
    /// only ever goes down from what is playing now.
    private func foldEntry() {
        guard entryActive else { return }
        envelope *= FadeCurve.up(Double(entryPosition) / Double(entryLength))
        entryActive = false
    }

    @inline(__always)
    private func nextEnvelope() -> Float {
        if rampActive {
            let progress = Double(rampPosition) / Double(rampLength)
            rampPosition += 1
            switch rampKind {
            case .down:
                envelope = rampFrom * FadeCurve.down(progress)
            case .up:
                envelope = rampFrom + (1 - rampFrom) * FadeCurve.up(progress)
            }
        }
        guard entryActive else { return envelope }
        let entry = FadeCurve.up(Double(entryPosition) / Double(entryLength))
        entryPosition += 1
        return envelope * entry
    }

    private func completeRamp() {
        rampActive = false
        switch rampKind {
        case .up: envelope = 1
        case .down: envelope = 0
        }
        switch rampAction {
        case .none: break
        case .pause:
            playing = false
            entryActive = false
        case .finish: finishNow()
        }
    }

    private func finishNow() {
        playing = false
        finished = true
        rampActive = false
        entryActive = false
        envelope = 0
    }

    private func publish(peakL: Float, peakR: Float) {
        telemetryPosition.store(position, ordering: .relaxed)
        // While fading, the real end is where the fade lands.
        let landing = isFadingOut && rampActive ? position + rampLength - rampPosition : endFrame
        telemetryEnd.store(landing, ordering: .relaxed)
        let phase: KernelPhase = finished ? .finished : (!playing ? .paused : (isFadingOut ? .fading : .playing))
        telemetryPhase.store(phase.rawValue, ordering: .relaxed)
        if peakL > Float(bitPattern: telemetryPeakL.load(ordering: .relaxed)) {
            telemetryPeakL.store(peakL.bitPattern, ordering: .relaxed)
        }
        if peakR > Float(bitPattern: telemetryPeakR.load(ordering: .relaxed)) {
            telemetryPeakR.store(peakR.bitPattern, ordering: .relaxed)
        }
    }
}
