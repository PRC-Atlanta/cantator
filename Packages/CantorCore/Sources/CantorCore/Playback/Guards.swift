import Foundation

/// Rejects a GO that arrives too soon after arming, or that is a key repeat.
public struct GoGuard: Sendable {
    public static let minimumArmedSeconds: TimeInterval = 0.3
    private var armedAt: TimeInterval?

    public init() {}

    public mutating func noteArmed(at time: TimeInterval) { armedAt = time }
    public mutating func clear() { armedAt = nil }

    public func allowsGo(at time: TimeInterval, isRepeat: Bool) -> Bool {
        guard !isRepeat, let armedAt else { return false }
        return time - armedAt >= Self.minimumArmedSeconds
    }
}

/// First Esc fades, a second within the window stops hard.
public struct PanicGate: Sendable {
    public enum Action: Equatable, Sendable { case fade, hardStop }
    public static let window: TimeInterval = 1.0
    private var lastPress: TimeInterval?

    public init() {}

    public mutating func press(at time: TimeInterval) -> Action {
        defer { lastPress = time }
        if let lastPress, time - lastPress <= Self.window { return .hardStop }
        return .fade
    }
}
