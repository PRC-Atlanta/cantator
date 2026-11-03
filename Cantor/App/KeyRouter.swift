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

        guard show.showMode || model.selection == .show, !flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else {
            return false
        }
        guard let window = event.window, window === mainWindow, window.attachedSheet == nil, NSApp.modalWindow == nil,
              !(window.firstResponder is NSText)
        else { return false }

        switch event.keyCode {
        case KeyCode.space: show.go(isRepeat: event.isARepeat)
        case KeyCode.up: show.movePointer(by: -1)
        case KeyCode.down: show.movePointer(by: 1)
        case KeyCode.returnKey:
            if case .faulted = show.state { show.acknowledgeFault() }
        default:
            guard !event.isARepeat else { return true }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": show.arm()
            case "d": show.disarm()
            case "f": show.fadeOut()
            case "p": show.hold()
            case "m": show.jumpMarker(forward: !flags.contains(.shift))
            case "[": show.nudgeEnd(seconds: -1)
            case "]": show.nudgeEnd(seconds: 1)
            case "h": toggleAudition(model)
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
