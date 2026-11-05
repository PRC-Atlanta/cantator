import AudioToolbox
import AVFoundation
import Foundation

public enum OutputError: LocalizedError, Equatable {
    case deviceUnavailable(String)
    case audioUnit(OSStatus)
    case engine(String)
    /// Zero-based first channel of the pair, and how many outputs the device has.
    case channelPairMissing(firstChannel: Int, deviceChannels: Int)

    public var errorDescription: String? {
        switch self {
        case .deviceUnavailable(let uid): "Output device is not connected (\(uid))."
        case .audioUnit(let status): "Could not configure the output device (error \(status))."
        case .engine(let message): "Audio engine failed to start: \(message)"
        case .channelPairMissing(let first, let channels):
            "Outputs \(first + 1)-\(first + 2) are not on this device, which has \(channels) output\(channels == 1 ? "" : "s"). Choose another pair in Settings > Outputs."
        }
    }
}

/// One AVAudioEngine bound to one device. A new engine is built for every start, so nothing carries
/// over from a previous device, and a stopped engine cannot produce sound.
@MainActor
final class OutputEngine {
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private let onConfigurationChange: @MainActor () -> Void

    init(onConfigurationChange: @escaping @MainActor () -> Void) {
        self.onConfigurationChange = onConfigurationChange
    }

    /// False once the engine has stopped by itself, for example after its device dropped out and came back.
    var isRunning: Bool { engine?.isRunning ?? false }

    /// The pair must exist as configured. Moving to another pair would put the cue on a console
    /// channel nobody is watching. A device with two outputs or fewer only has the pair 1-2.
    nonisolated static func validatePair(firstChannel: Int, deviceChannels: Int) throws {
        guard OutputRouting.pairFits(firstChannel: firstChannel, deviceChannels: deviceChannels) else { throw OutputError.channelPairMissing(firstChannel: firstChannel, deviceChannels: deviceChannels) }
    }

    func start(kernel: PlaybackKernel, deviceUID: String, firstChannel: Int) throws {
        stop()
        guard let device = AudioDevices.device(uid: deviceUID) else { throw OutputError.deviceUnavailable(deviceUID) }
        try Self.validatePair(firstChannel: firstChannel, deviceChannels: device.outputChannels)

        let engine = AVAudioEngine()
        let output = engine.outputNode
        guard let unit = output.audioUnit else { throw OutputError.engine("no output unit") }

        var id = device.deviceID
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw OutputError.audioUnit(status) }

        if device.outputChannels > 2 {
            try applyChannelMap(unit: unit, deviceChannels: device.outputChannels, firstChannel: firstChannel)
        }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: kernel.buffer.sampleRate, channels: 2) else {
            throw OutputError.engine("unsupported sample rate")
        }
        let source = Self.makeSource(kernel: kernel, format: format)
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.prepare()

        // Observe before starting, so a change during start is not missed. A notification can still
        // arrive late from an engine already replaced, so only the current engine counts, and only
        // once it has actually stopped: Core Audio stops the engine before it posts a real change.
        self.engine = engine
        let handler = onConfigurationChange
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self, weak engine] _ in
            MainActor.assumeIsolated {
                guard let self, let engine, self.engine === engine, !engine.isRunning else { return }
                handler()
            }
        }
        do {
            try engine.start()
        } catch {
            stop()
            throw OutputError.engine(error.localizedDescription)
        }
    }

    /// Nonisolated, so the render block never inherits the main actor: it runs on the audio thread.
    nonisolated private static func makeSource(kernel: PlaybackKernel, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }
            kernel.render(frames: Int(frameCount), left: left, right: right)
            return noErr
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.stop()
        engine = nil
    }

    private func applyChannelMap(unit: AudioUnit, deviceChannels: Int, firstChannel: Int) throws {
        // One entry per device channel: which source channel feeds it, or -1 for silence.
        // validatePair has already checked that the pair is on the device.
        var map = [Int32](repeating: -1, count: deviceChannels)
        map[firstChannel] = 0
        map[firstChannel + 1] = 1
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 0, &map,
            UInt32(map.count * MemoryLayout<Int32>.size)
        )
        guard status == noErr else { throw OutputError.audioUnit(status) }
    }
}

/// What ShowController needs from the house output. Tests use a fake, so they cannot reach hardware.
@MainActor
public protocol HouseOutput: AnyObject {
    func start(kernel: PlaybackKernel, deviceUID: String, firstChannel: Int) throws
    func stop()
    /// False once a started engine has stopped by itself. ShowController treats that as device loss.
    var isRunning: Bool { get }
}

extension HouseOutput {
    public var isRunning: Bool { true }
}

/// The house engine. Only ShowController holds one.
@MainActor
public final class HouseBus: HouseOutput {
    private lazy var output = OutputEngine { [weak self] in self?.onLost?() }
    public var onLost: (@MainActor () -> Void)?

    public init() {}

    public func start(kernel: PlaybackKernel, deviceUID: String, firstChannel: Int) throws {
        try output.start(kernel: kernel, deviceUID: deviceUID, firstChannel: firstChannel)
    }

    public func stop() { output.stop() }

    public var isRunning: Bool { output.isRunning }
}

/// The audition engine. It shares nothing with HouseBus and refuses the house outputs.
@MainActor
public final class CueBus {
    private lazy var output = OutputEngine { [weak self] in self?.stop() }
    public private(set) var kernel: PlaybackKernel?
    public private(set) var trackID: UUID?

    public init() {}

    public func audition(
        trackID: UUID, buffer: PCMBuffer, parameters: PlaybackParameters, from startFrame: Int? = nil, routing: OutputRouting
    ) throws {
        guard let uid = routing.cueDeviceUID else { throw OutputError.deviceUnavailable("no cue output set") }
        guard !routing.sharesOutputs else { throw OutputError.deviceUnavailable("cue output is the house output") }
        var parameters = parameters
        if let startFrame { parameters.startFrame = min(max(startFrame, 0), parameters.endFrame) }
        // Audition plays to the end of the file so the operator can hear past a marker.
        parameters.endFrame = buffer.frames
        parameters.fadeOutFrames = 0
        parameters.fadeInFrames = 0
        let kernel = PlaybackKernel(buffer: buffer, parameters: parameters)
        try output.start(kernel: kernel, deviceUID: uid, firstChannel: routing.cueFirstChannel)
        kernel.play()
        self.kernel = kernel
        self.trackID = trackID
    }

    public func stop() {
        output.stop()
        kernel = nil
        trackID = nil
    }

    public var isPlaying: Bool {
        guard let kernel else { return false }
        return kernel.phase != .finished
    }
}
