import AppKit
import CantorCore
import SwiftUI

@main
struct CantorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Cantator", id: "main") {
            RootView()
                .environment(model)
                .preferredColorScheme(colorScheme)
                .tint(Theme.neutralAccent)
                // The split views set the minimum width: the sidebar as wide as it is now, plus the
                // narrowest the view beside it can be. A fixed width here held the window narrower
                // than a widened sidebar needed.
                .frame(minHeight: 700)
                .background(WindowCapture())
                .windowDismissBehavior(model.show.showMode || model.show.state.holdsHouseEngine ? .disabled : .automatic)
                .onAppear {
                    AppModel.current = model
                    delegate.model = model
                    delegate.updates.model = model
                    KeyRouter.shared.install(model: model)
                    model.start()
                    #if DEBUG
                    SelfCheck.runIfRequested(model: model)
                    #endif
                }
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(after: .appInfo) { UpdatesMenu(updates: delegate.updates).environment(model) }
            CommandGroup(replacing: .newItem) { ImportMenu().environment(model) }
            CommandMenu("Transport") { TransportMenu().environment(model) }
            CommandGroup(after: .sidebar) { ShowModeMenu().environment(model) }
        }

        WindowGroup("EQ", id: "eq", for: UUID.self) { $trackID in
            if let trackID {
                EQWindow(trackID: trackID)
                    .environment(model)
                    .preferredColorScheme(.dark)
                    .tint(Theme.neutralAccent)
            }
        }
        .windowToolbarStyle(.unified(showsTitle: true))

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(colorScheme)
        }
    }

    private var colorScheme: ColorScheme? {
        switch model.settings.appearance {
        case "light": .light
        case "system": nil
        default: .dark
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    @MainActor let updates = Updates()

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.show.state.holdsHouseEngine {
            let alert = NSAlert()
            alert.messageText = "A cue is armed or playing."
            alert.informativeText = "Quitting stops the house output immediately."
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Keep Running")
            alert.addButton(withTitle: "Quit")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        model.prepareToQuit()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private struct UpdatesMenu: View {
    @AppEnvironment private var model
    let updates: Updates

    var body: some View {
        Button("Check for Updates…") { updates.checkForUpdates() }
            .disabled(!updates.canCheck || updates.showIsBusy)
    }
}

private struct ImportMenu: View {
    @AppEnvironment private var model

    var body: some View {
        // Simple has no service editor to open it in.
        Button("New Service…") { model.startNewService() }
            .keyboardShortcut("n")
            .disabled(model.isSimple || model.show.showMode || model.show.state.holdsHouseEngine || model.isLoadingService)
        Button("Import Audio…") { ImportButton.choose(model) }
            .keyboardShortcut("i")
            .disabled(!model.canImport)
    }
}

private struct ShowModeMenu: View {
    @AppEnvironment private var model

    var body: some View {
        Button(model.show.showMode ? "Leave Show Mode" : "Enter Show Mode") {
            model.show.setShowMode(!model.show.showMode)
        }
        // Not Command-L, which locks the screen on some Macs.
        .keyboardShortcut("l", modifiers: [.command, .shift])
        .disabled((model.show.cues.isEmpty || model.isLoadingService || model.isSimple) && !model.show.showMode)
        Button(model.isSimple ? "Advanced View" : "Simple View") {
            model.setOperatorMode(model.isSimple ? .full : .simple)
        }
        .disabled(model.show.showMode || model.show.state.holdsHouseEngine || model.isLoadingService)
    }
}

/// Records the main window so KeyRouter can tell it from Settings.
private struct WindowCapture: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { KeyRouter.shared.mainWindow = view.window }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// The keys are in the titles rather than set as menu shortcuts. A bare-key menu shortcut would
/// fire from a text field in Settings, and only KeyRouter knows which window a key was aimed at.
private struct TransportMenu: View {
    @AppEnvironment private var model

    var body: some View {
        let show = model.show
        // Like the keys: only where the Show view, and so the state of the show, is on screen.
        let inShow = show.showMode || model.isSimple || model.selection == .show
        // The same gate as the keys: Simple leaves Hold, markers and end nudges to Full.
        let allows = { (key: TransportKey) in inShow && model.settings.operatorMode.answers(key) }
        Button(model.isSimple ? "Arm Picked Song (A)" : "Arm Next Cue (A)") { model.arm() }.disabled(!allows(.arm))
        Button("Disarm (D)") { show.disarm() }.disabled(!allows(.disarm))
        Button("GO (Space)") { show.go() }.disabled(!allows(.go))
        Divider()
        Button("Hold (P)") { show.hold() }.disabled(!allows(.hold))
        Button("End of Song Fade (F)") { show.fadeOut() }.disabled(!allows(.fade))
        Button("Panic Fade (Esc)") { show.panicPressed() }.disabled(!show.state.holdsHouseEngine)
        Divider()
        Button("Next Marker (M)") { show.jumpMarker(forward: true) }.disabled(!allows(.marker))
        Button("Previous Marker (Shift-M)") { show.jumpMarker(forward: false) }.disabled(!allows(.marker))
        Button("End Point 1 s Earlier ([)") { show.nudgeEnd(seconds: -1) }.disabled(!allows(.nudgeEnd))
        Button("End Point 1 s Later (])") { show.nudgeEnd(seconds: 1) }.disabled(!allows(.nudgeEnd))
    }
}
