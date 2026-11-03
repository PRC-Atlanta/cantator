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
                .frame(minWidth: 1370, minHeight: 700)
                .background(WindowCapture())
                .windowDismissBehavior(model.show.showMode || model.show.state.holdsHouseEngine ? .disabled : .automatic)
                .onAppear {
                    delegate.model = model
                    KeyRouter.shared.install(model: model)
                    model.start()
                    #if DEBUG
                    SelfCheck.runIfRequested(model: model)
                    #endif
                }
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
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

private struct ImportMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("New Service…") { model.startNewService() }
            .keyboardShortcut("n")
            .disabled(model.show.showMode || model.show.state.holdsHouseEngine || model.isLoadingService)
        Button("Import Audio…") { ImportButton.choose(model) }
            .keyboardShortcut("i")
            .disabled(!model.canImport)
    }
}

private struct ShowModeMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button(model.show.showMode ? "Leave Show Mode" : "Enter Show Mode") {
            model.show.setShowMode(!model.show.showMode)
        }
        // Not Command-L, which locks the screen on some Macs.
        .keyboardShortcut("l", modifiers: [.command, .shift])
        .disabled((model.show.cues.isEmpty || model.isLoadingService) && !model.show.showMode)
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
    @Environment(AppModel.self) private var model

    var body: some View {
        let show = model.show
        // Like the keys: only where the Show view, and so the state of the show, is on screen.
        let inShow = show.showMode || model.selection == .show
        Button("Arm Next Cue (A)") { show.arm() }.disabled(!inShow)
        Button("Disarm (D)") { show.disarm() }.disabled(!inShow)
        Button("GO (Space)") { show.go() }.disabled(!inShow)
        Divider()
        Button("Hold (P)") { show.hold() }.disabled(!inShow)
        Button("End of Song Fade (F)") { show.fadeOut() }.disabled(!inShow)
        Button("Panic Fade (Esc)") { show.panicPressed() }.disabled(!show.state.holdsHouseEngine)
        Divider()
        Button("Next Marker (M)") { show.jumpMarker(forward: true) }.disabled(!inShow)
        Button("Previous Marker (Shift-M)") { show.jumpMarker(forward: false) }.disabled(!inShow)
        Button("End Point 1 s Earlier ([)") { show.nudgeEnd(seconds: -1) }.disabled(!inShow)
        Button("End Point 1 s Later (])") { show.nudgeEnd(seconds: 1) }.disabled(!inShow)
    }
}
