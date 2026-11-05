import AppKit
import CantorCore

/// Sees every key before the responder chain. In the Show view, or anywhere in Show Mode, keys aimed
/// at the main window drive the transport and go nowhere else. A key for any other window, a sheet, a dialog or a text field is
/// left alone, so typing can never arm or start a cue. Esc is panic everywhere.
@MainActor
final class KeyRouter {
    static let shared = KeyRouter()
    private var monitor: Any?
    private weak var model: AppModel?
    weak var mainWindow: NSWindow?

    func install(model: AppModel) {
        self.model = model
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                (self?.handle(event) ?? false) ? nil : event
            }
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let model else { return false }
        let show = model.show
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.keyCode == KeyCode.escape, show.state.holdsHouseEngine {
            if !event.isARepeat { show.panicPressed() }
            return true
        }

        // Simple has no other view, so its keys work whatever the sidebar selection was left at.
        guard show.showMode || model.isSimple || model.selection == .show, !flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else {
            return false
        }
        guard let window = event.window, window === mainWindow, window.attachedSheet == nil, NSApp.modalWindow == nil,
              !(window.firstResponder is NSText)
        else { return false }

        // In Simple, the keys for Hold, markers, end nudges and audition do nothing, so a stray press
        // can neither silence a track nor move its ending. They are swallowed, not passed on. The
        // arrow keys are the one exception: Simple leaves them to its song list, which only selects.
        let answers = { (key: TransportKey) in model.settings.operatorMode.answers(key) }
        switch event.keyCode {
        case KeyCode.space: if answers(.go) { show.go(isRepeat: event.isARepeat) }
        case KeyCode.up, KeyCode.down:
            guard answers(.pointer) else { return false }
            show.movePointer(by: event.keyCode == KeyCode.up ? -1 : 1)
        case KeyCode.returnKey:
            if case .faulted = show.state, answers(.acknowledge) { show.acknowledgeFault() }
        default:
            guard !event.isARepeat else { return true }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": if answers(.arm) { model.arm() }
            case "d": if answers(.disarm) { show.disarm() }
            case "f": if answers(.fade) { show.fadeOut() }
            case "p": if answers(.hold) { show.hold() }
            case "m": if answers(.marker) { show.jumpMarker(forward: !flags.contains(.shift)) }
            case "[": if answers(.nudgeEnd) { show.nudgeEnd(seconds: -1) }
            case "]": if answers(.nudgeEnd) { show.nudgeEnd(seconds: 1) }
            case "h": if answers(.audition) { toggleAudition(model) }
            default: break
            }
        }
        return true
    }

    private func toggleAudition(_ model: AppModel) {
        if model.cueBus.isPlaying || model.auditioning != nil {
            model.stopAudition()
        } else if let track = (model.show.state.holdsHouseEngine ? model.show.upcomingCue : model.show.pointedCue)?.track {
            model.audition(track)
        }
    }
}

enum KeyCode {
    static let space: UInt16 = 49
    static let returnKey: UInt16 = 36
    static let escape: UInt16 = 53
    static let up: UInt16 = 126
    static let down: UInt16 = 125
}
