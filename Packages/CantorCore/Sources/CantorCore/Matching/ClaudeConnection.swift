import Foundation

/// Whether Cantor can use the operator's Claude account right now, worded for the sidebar.
public enum ClaudeConnection: Equatable, Sendable {
    case checking
    case connected
    case off
    case notInstalled
    case signedOut
    case usesAPIKey
    case limitReached
    case unavailable(String)

    public init(error: Error) {
        switch error as? LLMError {
        case .notInstalled: self = .notInstalled
        case .notLoggedIn: self = .signedOut
        case .usesAPIKey: self = .usesAPIKey
        case .limitReached: self = .limitReached
        case let other?: self = .unavailable(other.localizedDescription)
        case nil: self = .unavailable(error.localizedDescription)
        }
    }

    public var isConnected: Bool { self == .connected }

    /// Only a problem the operator can fix gets attention. Off is a choice, not a problem.
    public var needsAttention: Bool {
        switch self {
        case .checking, .connected, .off: false
        default: true
        }
    }

    public var title: String {
        switch self {
        case .checking: "Checking Claude"
        case .connected: "Claude connected"
        case .off: "Claude off"
        case .notInstalled: "Claude not found"
        case .signedOut: "Claude signed out"
        case .usesAPIKey: "Claude uses an API key"
        case .limitReached: "Claude limit reached"
        case .unavailable: "Claude unavailable"
        }
    }

    public var detail: String {
        switch self {
        case .checking: "Checking whether Claude Code is signed in."
        case .connected: "New files and Resolve Ambiguous use your Claude account."
        case .off: "Turned off in Settings. New files are guessed from their names."
        case .notInstalled: LLMError.notInstalled.localizedDescription
        case .signedOut: LLMError.notLoggedIn.localizedDescription
        case .usesAPIKey: LLMError.usesAPIKey.localizedDescription
        case .limitReached: LLMError.limitReached.localizedDescription
        case .unavailable(let message): message
        }
    }

    /// Short enough for the sidebar. The full detail is in the tooltip and Settings.
    public var hint: String? {
        switch self {
        case .checking, .connected, .off: nil
        case .notInstalled: "Set its path in Settings"
        case .signedOut: "Sign in again in Settings"
        case .usesAPIKey: "Sign in with your Claude account"
        case .limitReached: "Try again later"
        case .unavailable: "Click to check again"
        }
    }
}

/// One request Cantor made to Claude, for the record in Settings.
public struct ClaudeUse: Equatable, Sendable {
    public var date: Date
    public var purpose: String
    public var failure: String?

    public init(date: Date = Date(), purpose: String, failure: String? = nil) {
        self.date = date
        self.purpose = purpose
        self.failure = failure
    }
}

extension ClaudeConnection {
    /// What Claude is used for, or why it is not and what Cantor does instead.
    public var usageSummary: String {
        switch self {
        case .connected: return "New files are filed by Claude, and Resolve Ambiguous asks Claude."
        case .checking: return "Checking."
        default: break
        }
        let reason = switch self {
        case .off: "Claude is turned off"
        case .notInstalled: "Claude Code was not found"
        case .signedOut: "Claude Code is signed out"
        case .usesAPIKey: "Claude Code is set up with an API key"
        case .limitReached: "your Claude usage limit was reached"
        default: "Claude is unavailable"
        }
        return "\(reason.prefix(1).uppercased() + reason.dropFirst()), so new files are guessed from their names, and matching works by name."
    }
}
