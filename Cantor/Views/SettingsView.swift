import AppKit
import CantorCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            OutputsSettings().tabItem { Label("Outputs", systemImage: "hifispeaker.2") }
            PlaybackSettings().tabItem { Label("Playback", systemImage: "slider.horizontal.3") }
            PlanningCenterSettings().tabItem { Label("Planning Center", systemImage: "calendar") }
            AISettings().tabItem { Label("Claude", systemImage: "sparkle.magnifyingglass") }
            FolderSettings().tabItem { Label("Folders", systemImage: "folder") }
        }
        .frame(width: 560, height: 420)
    }
}

private struct OutputsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let routing = model.settings.routing
        Form {
            Section("House") {
                devicePicker("Device", selection: routing.houseDeviceUID) { uid in
                    model.updateSettings { $0.routing.houseDeviceUID = uid }
                }
                pairPicker(uid: routing.houseDeviceUID, first: routing.houseFirstChannel) { first in
                    model.updateSettings { $0.routing.houseFirstChannel = first }
                }
            }
            Section("Cue (headphones)") {
                devicePicker("Device", selection: routing.cueDeviceUID) { uid in
                    model.updateSettings { $0.routing.cueDeviceUID = uid }
                }
                pairPicker(uid: routing.cueDeviceUID, first: routing.cueFirstChannel) { first in
                    model.updateSettings { $0.routing.cueFirstChannel = first }
                }
                if routing.isSameDevice {
                    Label("House and cue must be different devices.", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(Theme.danger)
                }
            }
            Section {
                Toggle("Move macOS sounds off the house output while a service is loaded", isOn: Binding(
                    get: { model.settings.isolateSystemSound },
                    set: { value in model.updateSettings { $0.isolateSystemSound = value } }
                ))
            }
        }
        .formStyle(.grouped)
        .disabled(model.show.state.holdsHouseEngine)
    }

    private func devicePicker(_ title: String, selection: String?, set: @escaping (String?) -> Void) -> some View {
        Picker(title, selection: Binding(get: { selection }, set: set)) {
            Text("None").tag(String?.none)
            ForEach(model.devices) { device in
                Text(device.name).tag(String?.some(device.uid))
            }
            if let selection, !model.devices.contains(where: { $0.uid == selection }) {
                Text("Disconnected device").tag(String?.some(selection))
            }
        }
    }

    @ViewBuilder
    private func pairPicker(uid: String?, first: Int, set: @escaping (Int) -> Void) -> some View {
        if let device = model.devices.first(where: { $0.uid == uid }), device.outputChannels > 2 {
            Picker("Outputs", selection: Binding(get: { first }, set: set)) {
                ForEach(Array(stride(from: 0, to: device.outputChannels - 1, by: 2)), id: \.self) { channel in
                    Text("\(channel + 1)-\(channel + 2)").tag(channel)
                }
            }
        }
    }
}

private struct PlaybackSettings: View {
    @Environment(AppModel.self) private var model

    private func binding<T>(_ path: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: path] }, set: { value in model.updateSettings { $0[keyPath: path] = value } })
    }

    var body: some View {
        Form {
            Section("Fades") {
                Stepper("Panic fade: \(String(format: "%.1f", model.settings.panicFadeSec)) s", value: binding(\.panicFadeSec), in: 0.2...5, step: 0.1)
                Stepper("Default end fade: \(String(format: "%.1f", model.settings.defaultFadeOutSec)) s", value: binding(\.defaultFadeOutSec), in: 0...15, step: 0.5)
            }
            Section("Level") {
                Toggle("Match track loudness", isOn: binding(\.normalize))
                Stepper("Target: \(String(format: "%.0f", model.settings.targetLUFS)) LUFS", value: binding(\.targetLUFS), in: -30 ... -10, step: 1)
                    .disabled(!model.settings.normalize)
            }
            Section("Appearance") {
                Picker("Appearance", selection: binding(\.appearance)) {
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                    Text("System").tag("system")
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Secrets go straight to the Keychain and are never kept in app state.
private struct SecretField: View {
    let title: String
    let key: Keychain.Key
    @State private var value = ""
    @State private var isSaved = false
    @State private var failure: String?

    var body: some View {
        LabeledContent(title) {
            HStack {
                SecureField(title, text: $value, prompt: Text(isSaved ? "Saved in Keychain" : "Not set")).labelsHidden()
                Button("Save") {
                    do {
                        try Keychain.write(value, for: key)
                        value = ""
                        isSaved = Keychain.read(key) != nil
                        failure = nil
                    } catch {
                        failure = error.localizedDescription
                    }
                }
                .disabled(value.isEmpty)
                Button("Clear") {
                    try? Keychain.write("", for: key)
                    isSaved = false
                }
                .disabled(!isSaved)
            }
        }
        .onAppear { isSaved = Keychain.read(key) != nil }
        if let failure { Text(failure).foregroundStyle(Theme.danger) }
    }
}

private struct PlanningCenterSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                SecretField(title: "Application ID", key: .pcoAppID)
                SecretField(title: "Secret", key: .pcoSecret)
            } footer: {
                Text("Create a Personal Access Token at api.planningcenteronline.com/oauth/applications.")
            }
            Section {
                Button("Sync Now") { model.refreshPlans() }.disabled(model.isSyncing)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AISettings: View {
    @Environment(AppModel.self) private var model
    @State private var accountSummary = "Checking"

    private func binding(_ path: WritableKeyPath<AppSettings, String>) -> Binding<String> {
        Binding(get: { model.settings[keyPath: path] }, set: { value in model.updateSettings { $0[keyPath: path] = value } })
    }

    var body: some View {
        Form {
            Section {
                Toggle("Use Claude to file new files and rank ambiguous matches", isOn: Binding(
                    get: { model.settings.llmEnabled },
                    set: { value in model.updateSettings { $0.llmEnabled = value } }
                ))
                LabeledContent("Claude Account") {
                    HStack {
                        Text(accountSummary).multilineTextAlignment(.trailing)
                        Button("Check") { Task { await refresh() } }
                    }
                }
            } footer: {
                Text("Uses the Claude account that Claude Code is signed in to, and counts toward that account's usage. No API key is used. Claude gets filenames, the two folders above each file, durations, embedded tags, category names and service item titles. It never gets paths, notes or audio, and nothing is applied until you accept it. When Claude is off or signed out, new files are guessed from their names.")
            }
            Section {
                TextField("Model", text: binding(\.llmModel), prompt: Text("Account default"))
                TextField("Claude Code Path", text: binding(\.claudePath), prompt: Text("Found automatically"))
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
    }

    private func refresh() async {
        accountSummary = await model.claudeAccountSummary()
    }
}

private struct FolderSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading) {
            List(model.settings.folders, id: \.self, selection: $selection) { folder in
                Text(folder).lineLimit(1).truncationMode(.middle)
            }
            HStack {
                Button("Add Folder") { addFolder() }
                Button("Remove") {
                    if let selection {
                        model.updateSettings { $0.folders.removeAll { $0 == selection } }
                    }
                }
                .disabled(selection == nil)
                Spacer()
                Button("Rescan") { model.rescan() }.disabled(model.isScanning)
            }
            Text("Cantor watches these folders while it is open, and catches up when it starts. Files that arrive after a folder is added appear in the New File pop-up, once no service is loaded and nothing is playing.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !model.unreadableFiles.isEmpty {
                Text("\(model.unreadableFiles.count) files could not be read as audio.").foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map(\.path)
        model.updateSettings { settings in
            for path in paths where !settings.folders.contains(path) { settings.folders.append(path) }
        }
    }
}
