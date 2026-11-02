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
        case .signedOut: "Run claude auth login in Terminal"
        case .usesAPIKey: "Sign in with your Claude account"
        case .limitReached: "Try again later"
        case .unavailable: "Click to check again"
        }
    }
}
