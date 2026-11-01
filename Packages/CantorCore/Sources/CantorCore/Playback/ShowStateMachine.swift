import Foundation

public typealias CueID = String

/// The house output state. Only `live` and `fading` and `panicking` are audible.
public enum ShowState: Equatable, Sendable {
    case idle
    case armed(CueID)
    case live(CueID)
    case held(CueID)
    case fading(CueID)
    case panicking(CueID)
    case faulted(CueID?)

    public var cueID: CueID? {
        switch self {
        case .idle: nil
        case .armed(let id), .live(let id), .held(let id), .fading(let id), .panicking(let id): id
        case .faulted(let id): id
        }
    }

    public var isAudible: Bool {
        switch self {
        case .live, .fading, .panicking: true
        default: false
        }
    }

    /// True whenever the house engine is running, audible or not.
    public var holdsHouseEngine: Bool {
        switch self {
        case .idle, .faulted: false
        default: true
        }
    }
}

public enum ShowEvent: Equatable, Sendable {
    case arm(CueID)
    case disarm
    case go
    case hold
    case fade
    case panic
    case hardStop
    case autoFadeStarted
    case finished
    case deviceLost
    case acknowledgeFault
}

public enum ShowEffect: Equatable, Sendable {
    case prepare(CueID)
    case start
    case hold
    case fade
    case panic
    case hardStop
    case teardown
}

/// Pure transition table. An event that is not valid in the current state changes nothing and
/// returns no effects, which is how a stray GO is ignored.
public struct ShowStateMachine: Sendable {
    public private(set) var state: ShowState = .idle

    public init() {}

    @discardableResult
    public mutating func handle(_ event: ShowEvent) -> [ShowEffect] {
        switch (state, event) {
        case (.idle, .arm(let id)):
            state = .armed(id)
            return [.prepare(id)]

        case (.armed, .disarm), (.held, .disarm):
            state = .idle
            return [.teardown]

        case (.armed(let id), .go), (.held(let id), .go):
            state = .live(id)
            return [.start]

        case (.live(let id), .hold):
            state = .held(id)
            return [.hold]

        case (.live(let id), .fade):
            state = .fading(id)
            return [.fade]

        case (.live(let id), .panic), (.held(let id), .panic), (.fading(let id), .panic):
            state = .panicking(id)
            return [.panic]

        case (.armed, .panic):
            // Armed is silent, so panic only has to make it safe.
            state = .idle
            return [.teardown]

        case (.armed, .hardStop), (.live, .hardStop), (.held, .hardStop), (.fading, .hardStop), (.panicking, .hardStop):
            state = .idle
            return [.hardStop, .teardown]

        case (.live(let id), .autoFadeStarted), (.held(let id), .autoFadeStarted):
            // The kernel reached the fade before the end marker. Nothing to command, only to show.
            state = .fading(id)
            return []

        case (.live, .finished), (.held, .finished), (.fading, .finished), (.panicking, .finished):
            state = .idle
            return [.teardown]

        case (.armed(let id), .deviceLost), (.live(let id), .deviceLost), (.held(let id), .deviceLost),
             (.fading(let id), .deviceLost), (.panicking(let id), .deviceLost):
            state = .faulted(id)
            return [.hardStop, .teardown]

        case (.idle, .deviceLost):
            state = .faulted(nil)
            return []

        case (.faulted, .acknowledgeFault):
            state = .idle
            return []

        default:
            return []
        }
    }
}
