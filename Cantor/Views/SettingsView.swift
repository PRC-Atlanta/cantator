import AppKit
import CantorCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            OutputsSettings().tabItem { Label("Outputs", systemImage: "hifispeaker.2") }
            PlaybackSettings().tabItem { Label("Playback", systemImage: "slider.horizontal.3") }
            PlanningCenterSettings().tabItem { Label("Planning Center", systemImage: "calendar") }
            ClaudeSettings().tabItem { Label("Claude", systemImage: "sparkle.magnifyingglass") }
            FolderSettings().tabItem { Label("Folders", systemImage: "folder") }
        }
        .frame(width: 560, height: 520)
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
        // The next arm uses these, so they are part of the show.
        .disabled(model.show.showMode || model.show.state.holdsHouseEngine)
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
            .disabled(model.show.showMode)
            Section("Level") {
                Toggle("Match track loudness", isOn: binding(\.normalize))
                Stepper("Target: \(String(format: "%.0f", model.settings.targetLUFS)) LUFS", value: binding(\.targetLUFS), in: -30 ... -10, step: 1)
                    .disabled(!model.settings.normalize)
            }
            .disabled(model.show.showMode)
            if model.show.showMode {
                Text("Fades and levels are locked in Show Mode.").foregroundStyle(.secondary)
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
                        isSaved = (try? Keychain.lookup(key)) != nil
                        failure = nil
                    } catch {
                        failure = error.localizedDescription
                    }
                }
                .disabled(value.isEmpty)
                Button("Clear") {
                    do {
                        try Keychain.write("", for: key)
                        isSaved = false
                        failure = nil
                    } catch {
                        failure = error.localizedDescription
                    }
                }
                .disabled(!isSaved)
            }
        }
        .onAppear {
            do {
                isSaved = try Keychain.lookup(key) != nil
            } catch {
                // Denied access is not the same as no token.
                isSaved = true
                failure = error.localizedDescription
            }
        }
        if let failure { Text(failure).foregroundStyle(Theme.danger) }
    }
}

private struct PlanningCenterSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Picker("Sync With", selection: Binding(
                    get: { model.settings.planningCenterSource },
                    set: { value in model.updateSettings { $0.planningCenterSource = value } }
                )) {
                    Text("Claude Connector").tag(PlanningCenterSource.connector)
                    Text("API Token").tag(PlanningCenterSource.token)
                }
                .pickerStyle(.radioGroup)
                if let source = model.lastPlanningCenterSource {
                    LabeledContent("Last sync", value: source == .connector ? "Claude connector" : "API token")
                }
            } footer: {
                Text(model.settings.planningCenterSource == .connector
                    ? "Reads the next \(PlanningCenterConnector.plansPerType) plans of each service type through the Planning Center connector on your Claude account, using Claude Code. Claude can only use the connector's read-only Services tools, and Cantator reads the plans from the connector's own answers. Claude does see item titles and descriptions, which can include names. It can take a few minutes and counts toward your Claude usage. Attachment filenames aren't available this way, so matching keeps the ones from the last token sync. If the connector can't be used, the token below is used instead."
                    : "Reads Planning Center directly with the token below. Claude isn't involved.")
            }
            Section {
                let types = model.knownServiceTypes
                let importAll = model.settings.importAllServiceTypes
                Toggle("Import all service types", isOn: Binding(
                    get: { importAll },
                    set: { value in model.updateSettings { $0.importAllServiceTypes = value } }
                ))
                .toggleStyle(.checkbox)
                if types.isEmpty {
                    Text("Sync once to list your service types.").foregroundStyle(.secondary)
                }
                ForEach(types, id: \.id) { type in
                    Toggle(type.name, isOn: Binding(
                        get: { importAll || !model.settings.hiddenServiceTypeIDs.contains(type.id) },
                        set: { shown in model.setServiceType(type, shown: shown) }
                    ))
                    .toggleStyle(.checkbox)
                    .padding(.leading, 20)
                    .disabled(importAll)
                }
            } header: {
                Text("Service Types")
            } footer: {
                Text(model.settings.importAllServiceTypes
                    ? "Sync Now reads every service type. Turn this off to import only the types you check."
                    : "Sync Now reads only the checked types, and only they appear in the sidebar. Choose Service… still lists every type, so a wedding or funeral can be added when it's needed. A type you check again comes back at the next sync.")
            }
            Section("API Token") {
                SecretField(title: "Application ID", key: .pcoAppID)
                SecretField(title: "Secret", key: .pcoSecret)
                Text("Create a Personal Access Token at api.planningcenteronline.com/oauth/applications.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Sync Now") { model.refreshPlans() }.disabled(model.isSyncing || model.show.showMode)
                    if model.isSyncing {
                        ProgressView().controlSize(.small)
                        Text(model.claudeWorking ?? "Syncing").foregroundStyle(.secondary)
                    }
                }
            } footer: {
                if model.show.showMode { Text("Sync is off in Show Mode, because it can change the loaded cues.") }
            }
        }
        .formStyle(.grouped)
    }
}

struct ClaudeSettings: View {
    @Environment(AppModel.self) private var model

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
                        ClaudeStatusLabel(connection: model.claudeConnection)
                        Button("Check") { model.refreshClaudeConnection() }
                    }
                }
                if model.claudeConnection != .connected {
                    Text(model.claudeConnection.detail).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Uses the Claude account that Claude Code is signed in to, and counts toward that account's usage. No API key is used. Claude gets filenames, the two folders above each file, durations, embedded tags, category names and service item titles. It never gets paths or audio, and nothing is applied until you accept it. When Planning Center syncs through the Claude connector, Claude also reads service items' titles and descriptions there.")
            }
            Section("Usage") {
                LabeledContent("In Use") {
                    Label(model.claudeConnection.isConnected ? "Yes" : "No", systemImage: model.claudeConnection.isConnected ? "checkmark.circle" : "minus.circle")
                }
                Text(model.claudeConnection.usageSummary).foregroundStyle(.secondary)
                LabeledContent("Right Now") {
                    if let working = model.claudeWorking {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(working)
                        }
                    } else {
                        Text("Idle")
                    }
                }
                LabeledContent("Last Request") {
                    if let use = model.lastClaudeUse {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(use.purpose), \(use.date.formatted(date: .omitted, time: .shortened))")
                            Text(use.failure ?? "Succeeded")
                                .font(.caption)
                                .foregroundStyle(use.failure == nil ? Color.secondary : Theme.armed)
                                .multilineTextAlignment(.trailing)
                        }
                    } else {
                        Text("None since Cantator opened")
                    }
                }
                LabeledContent("Requests Since Opening", value: "\(model.claudeRequestsThisSession)")
            }
            Section {
                TextField("Model", text: binding(\.llmModel), prompt: Text("Account default"))
                TextField("Claude Code Path", text: binding(\.claudePath), prompt: Text("Found automatically"))
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshClaudeConnection() }
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
            // Adding a folder starts a full scan, and its panel takes the keys.
            .disabled(model.show.showMode)
            Text("Cantator watches these folders while it is open, and catches up when it starts. Files that arrive after a folder is added appear in the New File pop-up, once no service is loaded and nothing is playing.")
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
