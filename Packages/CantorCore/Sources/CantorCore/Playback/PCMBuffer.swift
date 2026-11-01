import Foundation

/// Immutable decoded audio held in RAM. Playback reads only from here, never from disk.
/// Mono audio shares one allocation for both channels.
public final class PCMBuffer: @unchecked Sendable {
    public let left: UnsafeMutablePointer<Float>
    public let right: UnsafeMutablePointer<Float>
    public let frames: Int
    public let sampleRate: Double
    private let isMono: Bool

    public init(left leftSamples: [Float], right rightSamples: [Float]?, sampleRate: Double) {
        let copy = { (samples: [Float]) -> UnsafeMutablePointer<Float> in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(samples.count, 1))
            samples.withUnsafeBufferPointer { src in
                if let base = src.baseAddress { pointer.update(from: base, count: samples.count) }
            }
            return pointer
        }
        precondition(rightSamples == nil || rightSamples?.count == leftSamples.count)
        frames = leftSamples.count
        self.sampleRate = sampleRate
        isMono = rightSamples == nil
        left = copy(leftSamples)
        right = rightSamples.map(copy) ?? left
    }

    /// Takes ownership of pointers from the decoder, avoiding a second copy of a large track.
    init(adoptingLeft left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, frames: Int, sampleRate: Double) {
        self.left = left
        self.right = right ?? left
        self.frames = frames
        self.sampleRate = sampleRate
        isMono = right == nil
    }

    deinit {
        left.deallocate()
        if !isMono { right.deallocate() }
    }

    public var durationSeconds: Double { sampleRate > 0 ? Double(frames) / sampleRate : 0 }
    public var byteSize: Int { frames * MemoryLayout<Float>.size * (isMono ? 1 : 2) }
}
