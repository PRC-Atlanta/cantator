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
    private var isFadingOut = false
    private var didFadeIn = false
    private var playStart = 0

    public init(buffer: PCMBuffer, parameters: PlaybackParameters) {
        self.buffer = buffer
        self.parameters = parameters
        declickFrames = max(Int(buffer.sampleRate * Self.declickSeconds), 1)
        endFrame = max(min(parameters.endFrame, buffer.frames), 0)
        position = min(max(parameters.startFrame, 0), endFrame)
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
            if !isFadingOut {
                // A run shorter than its fade would otherwise never get above silence.
                let lead = min(max(parameters.fadeOutFrames, declickFrames), max((endFrame - playStart) / 2, 1))
                if position >= endFrame - lead {
                    beginRamp(.down, length: endFrame - position, action: .finish)
                    isFadingOut = true
                }
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
            playStart = position
            let wantsFadeIn = !didFadeIn && parameters.fadeInFrames > declickFrames
            didFadeIn = true
            beginRamp(.up, length: wantsFadeIn ? parameters.fadeInFrames : declickFrames, action: .none)

        case .hold:
            guard playing, !isFadingOut else { return }
            beginRamp(.down, length: declickFrames, action: .pause)

        case .fade(let requested):
            guard playing else { return }
            let length = max(min(requested, endFrame - position), 1)
            if isFadingOut, rampActive, length >= rampLength - rampPosition { return }
            beginRamp(.down, length: length, action: .finish)
            isFadingOut = true

        case .panic(let requested):
            guard playing else {
                finishNow()
                return
            }
            let length = max(requested, 1)
            if isFadingOut, rampActive, length >= rampLength - rampPosition { return }
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
            guard !isFadingOut else { return }
            endFrame = min(max(frame, position + 1), buffer.frames)

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

    @inline(__always)
    private func nextEnvelope() -> Float {
        guard rampActive else { return envelope }
        let progress = Double(rampPosition) / Double(rampLength)
        rampPosition += 1
        switch rampKind {
        case .down:
            envelope = rampFrom * FadeCurve.down(progress)
        case .up:
            envelope = rampFrom + (1 - rampFrom) * FadeCurve.up(progress)
        }
        return envelope
    }

    private func completeRamp() {
        rampActive = false
        switch rampKind {
        case .up: envelope = 1
        case .down: envelope = 0
        }
        switch rampAction {
        case .none: break
        case .pause: playing = false
        case .finish: finishNow()
        }
    }

    private func finishNow() {
        playing = false
        finished = true
        rampActive = false
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
