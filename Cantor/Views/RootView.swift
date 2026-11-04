import CantorCore
import SwiftUI

enum LibraryFilter: Hashable {
    case all, attention, notDownloaded, duplicates, excluded
    case tag(String)
}

enum SidebarItem: Hashable {
    case show, check
    case plan(String)
    case library(LibraryFilter)
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var model = model
        Group {
            if model.isSimple {
                // The Simple view: library tags, songs, and the song on the right. The sheets and
                // alerts below still belong to the window.
                SimpleRootView()
            } else {
                NavigationSplitView(columnVisibility: $columns) {
                    Group {
                        // Show Mode trades the sidebar's links, which lead to text fields, for the program.
                        if model.show.showMode {
                            ProgramSidebar()
                        } else {
                            SidebarView(selection: $model.selection)
                        }
                    }
                    .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
                    .toolbar { OperatorModeToolbarItem() }
                } detail: {
                    detail
                        .sheet(isPresented: $model.showingServicePicker) { ServicePickerSheet() }
                }
                .toolbar(removing: model.show.showMode ? .sidebarToggle : nil)
                .onChange(of: columns) { _, value in
                    // The program stays in view in Show Mode.
                    if model.show.showMode, value != .all { columns = .all }
                }
            }
        }
        .onChange(of: model.selection) { _, item in
            // Leaving the Show view lets go of an armed cue, so nothing waits on a GO no one can see.
            // A cue playing or on hold keeps the Show view, since its controls and keys live there.
            guard item != .show else { return }
            if case .armed = model.show.state {
                model.show.disarm()
            } else if model.show.state.holdsHouseEngine {
                model.selection = .show
                model.alert = "Stop the cue before leaving the Show view."
            }
        }
        .onChange(of: model.show.showMode) { _, locked in
            if locked {
                model.showingServicePicker = false
                model.showingNewService = false
                model.selection = .show
            }
            columns = .all
        }
        .sheet(isPresented: $model.showingNewService) { NewServiceSheet() }
        // The first-launch question. Older installs answered it by having used Planning Center.
        .sheet(isPresented: Binding(get: { !model.settings.hasChosenServiceSource }, set: { _ in })) { WelcomeSheet() }
        .sheet(item: Binding(
            get: { model.newFileToPresent },
            set: { value in
                // Esc or a close counts as Later. A sheet closed because playback started is not a choice.
                if value == nil, model.newFileToPresent != nil { model.snoozeNewFiles() }
            }
        )) { item in
            NewFileSheet(item: item)
        }
        .alert("Not a Playback?", isPresented: Binding(
            get: { model.pendingExclusion != nil },
            set: { if !$0 { model.pendingExclusion = nil } }
        ), presenting: model.pendingExclusion) { pending in
            Button("Remove and Exclude", role: .destructive) { model.confirmExclusion(pending) }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.message)
        }
        // An alert is a sheet, which would take the transport keys. The Show view shows it inline instead.
        .alert("Cantator", isPresented: Binding(get: { model.alert != nil && !model.show.showMode && model.selection != .show }, set: { if !$0 { model.alert = nil } })) {
            if model.claudeConnection == .signedOut {
                Button("Sign In to Claude") { model.signInToClaude() }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alert ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection ?? .show {
        case .show: ShowView()
        case .check: CheckView()
        case .plan(let id): ServiceView(planID: id)
        case .library(let filter): LibraryView(filter: filter)
        }
    }
}

/// Show and Pre-Service Check stay at the top and the library and Claude at the bottom, with
/// the services scrolling between them. A List scrolls as one piece, so the rows are drawn here.
private struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?
    @State private var pastOpen = false

    var body: some View {
        let library = model.library
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                SidebarHeader("Service")
                row(.show) { SidebarLabel("Show", "play.rectangle") }
                // A yellow mark while the check finds something to fix or look at, so it is seen before opening it.
                let problems = model.checkResults().filter { $0.severity > .ok }.count
                row(.check) { SidebarLabel("Pre-Service Check", "checklist", alert: problems > 0) }
                    .help(problems > 0 ? "Pre-Service Check found \(problems) \(problems == 1 ? "issue" : "issues")" : "")
            }
            .padding(10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    SidebarHeader("Services")
                    let busy = model.show.showMode || model.show.state.holdsHouseEngine || model.isLoadingService
                    Button {
                        model.startNewService()
                    } label: {
                        SidebarLabel("New Service…", "calendar.badge.plus").sidebarRowPadding()
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight(cornerRadius: 6)
                    .disabled(busy)
                    .help("Build a service here: blank, a copy of another, or from a template. Drop tracks on it to start with them.")
                    .acceptsTracks { model.startNewService(with: $0) }
                    if model.settings.usesPlanningCenter {
                        HStack(spacing: 6) {
                            Button {
                                model.showingServicePicker = true
                            } label: {
                                SidebarLabel("Choose Service…", "calendar").sidebarRowPadding()
                            }
                            .buttonStyle(.plain)
                            .hoverHighlight(cornerRadius: 6)
                            .disabled(busy)
                            .help("Pick a Planning Center service from six weeks back to three weeks ahead")
                            UpdateServicesButton()
                                .padding(.trailing, 6)
                        }
                    }
                    ForEach(model.upcomingSidebarPlans) { plan in
                        planRow(plan)
                    }
                    if model.upcomingSidebarPlans.isEmpty {
                        Text(model.sidebarPlans.isEmpty ? (model.plans.isEmpty ? "No services yet" : "None of the shown types") : "Nothing coming up")
                            .foregroundStyle(.secondary)
                            .sidebarRowPadding()
                    }
                    let past = model.pastSidebarPlans
                    if !past.isEmpty {
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { pastOpen.toggle() }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: pastOpen ? "chevron.down" : "chevron.right").frame(width: 18).font(.caption)
                                Text("Past Services").lineLimit(1)
                                Spacer(minLength: 4)
                                Text("\(past.count)").font(.callout).monospacedDigit()
                            }
                            .foregroundStyle(.secondary)
                            .sidebarRowPadding()
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight(cornerRadius: 6)
                        .help("Services already over. Open one to run it again or copy its order.")
                        if pastOpen {
                            ForEach(past) { plan in
                                planRow(plan).padding(.leading, 12)
                            }
                        }
                    }
                }
                .padding(10)
            }
            Divider()
            VStack(alignment: .leading, spacing: 1) {
                SidebarHeader("Library")
                libraryRow("All Tracks", "music.note.list", .all, library.playbackTracks.count)
                ForEach(library.allTags, id: \.self) { tag in
                    libraryRow(tag.capitalized, "tag", .tag(tag), library.playbackTracks.filter { $0.tags.contains(tag) }.count)
                }
                if !model.inbox.items.isEmpty {
                    Button {
                        model.reviewNewFiles()
                    } label: {
                        SidebarLabel("New Files", "tray.and.arrow.down", count: model.inbox.items.count).sidebarRowPadding()
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight(cornerRadius: 6)
                    .disabled(!model.newFilesCanAppear)
                    .help(model.newFilesCanAppear ? "Review new files" : "New files wait until no service is loaded")
                }
                libraryRow("Needs Attention", "exclamationmark.triangle", .attention, library.playbackTracks.filter(LibraryView.needsAttention).count)
                libraryRow("Not Downloaded", "icloud", .notDownloaded, library.playbackTracks.filter { !$0.isLocal && $0.hasCloudOnlyCopy }.count)
                libraryRow("Duplicates", "square.on.square", .duplicates, library.duplicateGroups.count)
                libraryRow("Excluded", "eye.slash", .excluded, library.excludedTracks.count)
                if model.settings.llmEnabled {
                    SidebarHeader("Claude")
                    ClaudeStatusRow()
                }
                SidebarHeader("Outputs")
                OutputsStatusRow()
            }
            .padding(10)
        }
    }

    private func planRow(_ plan: ServicePlan) -> some View {
        row(.plan(plan.id)) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(plan.dates.isEmpty ? plan.title : plan.dates).lineLimit(1)
                    Text(plan.isManual ? plan.title : plan.serviceTypeName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if plan.id == model.loadedPlanID {
                    Spacer(minLength: 4)
                    Text("LOADED")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.live)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.live.opacity(0.7)))
                }
            }
        }
        .acceptsTracks(open: { selection = .plan(plan.id) }) { model.addTracks($0, to: plan.id, at: .end) }
    }

    private func row(_ item: SidebarItem, @ViewBuilder content: () -> some View) -> some View {
        let selected = selection == item
        return Button {
            selection = item
        } label: {
            content().sidebarRowPadding()
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.75) : .clear))
        .hoverHighlight(cornerRadius: 6)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func libraryRow(_ title: String, _ symbol: String, _ filter: LibraryFilter, _ count: Int) -> some View {
        row(.library(filter)) { SidebarLabel(title, symbol, count: count) }
    }
}

private struct SidebarHeader: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

/// An icon, a title and a count, which is left out at zero as a List badge is.
private struct SidebarLabel: View {
    let title: String
    let symbol: String
    var count = 0
    var alert = false

    init(_ title: String, _ symbol: String, count: Int = 0, alert: Bool = false) {
        self.title = title
        self.symbol = symbol
        self.count = count
        self.alert = alert
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).frame(width: 18)
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
            if alert {
                Image(systemName: "info.circle.fill").foregroundStyle(Theme.armed)
                    .accessibilityLabel("Needs attention")
            }
            if count > 0 {
                Text("\(count)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

/// Sync Now from the sidebar. Reads the service types checked in Settings.
private struct UpdateServicesButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.refreshPlans()
        } label: {
            if model.isSyncing {
                ProgressView().controlSize(.small).frame(width: 16, height: 16)
            } else {
                Image(systemName: "arrow.clockwise").frame(width: 16, height: 16)
            }
        }
        .buttonStyle(.borderless)
        .hoverHighlight(outset: 3)
        .disabled(model.isSyncing || model.show.showMode || model.isLoadingService)
        .help(help)
        .accessibilityLabel("Update Services")
    }

    private var help: String {
        if model.isSyncing { return model.claudeWorking ?? "Updating services" }
        let settings = model.settings
        let skipped = settings.skippedServiceTypeIDs
        guard !skipped.isEmpty else { return "Update services from Planning Center: all service types" }
        let types = model.knownServiceTypes.filter { !skipped.contains($0.id) }.map(\.name)
        return "Update services from Planning Center: \(types.isEmpty ? "no types are checked in Settings" : types.joined(separator: ", "))"
    }
}

/// Claude status in the sidebar, whenever the sidebar is open. Click to check again.
private struct ClaudeStatusRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let connection = model.claudeConnection
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                ClaudeStatusLabel(connection: connection)
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .hoverHighlight(outset: 3)
                .help("Claude settings")
            }
            if let hint = connection.hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .sidebarRowPadding()
        .hoverHighlight(cornerRadius: 6)
        .onTapGesture { model.refreshClaudeConnection() }
        .help("\(connection.detail) Click to check again.")
    }
}

/// House and cue, always in view while preparing. Amber until both are set, connected and
/// different, which is what Arm will insist on. Click to open Settings > Outputs.
private struct OutputsStatusRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let routing = model.settings.routing
        let connected = Set(model.devices.map(\.uid))
        let houseOK = routing.houseDeviceUID.map(connected.contains) ?? false
        let cueOK = routing.cueDeviceUID.map(connected.contains) ?? false
        let distinct = !routing.isSameDevice
        Button {
            model.openSettings(.outputs)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                line("House", name: houseName(routing), ok: houseOK && distinct)
                line("Cue", name: model.deviceName(routing.cueDeviceUID), ok: cueOK && distinct)
                if routing.isSameDevice {
                    Text("Must be different devices").font(.caption).foregroundStyle(Theme.armed)
                }
            }
            .sidebarRowPadding()
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 6)
        .help("Open Settings > Outputs")
    }

    private func houseName(_ routing: OutputRouting) -> String {
        let name = model.deviceName(routing.houseDeviceUID)
        guard let uid = routing.houseDeviceUID, let device = model.devices.first(where: { $0.uid == uid }), device.outputChannels > 2 else { return name }
        return "\(name) \(routing.houseFirstChannel + 1)-\(routing.houseFirstChannel + 2)"
    }

    private func line(_ label: String, name: String, ok: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(ok ? Color.secondary : Theme.armed)
                .frame(width: 14)
            Text("\(label) · \(name)").font(.callout).lineLimit(1).truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Color only when something needs fixing. Green is kept for LIVE.
struct ClaudeStatusLabel: View {
    let connection: ClaudeConnection

    var body: some View {
        Label {
            Text(connection.title)
        } icon: {
            if connection == .checking {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol).foregroundStyle(connection.needsAttention ? Theme.armed : .secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch connection {
        case .connected: "checkmark.circle"
        case .off: "minus.circle"
        default: "exclamationmark.triangle"
        }
    }
}

private extension View {
    /// Fills the row so the hover wash and the selection span the sidebar.
    func sidebarRowPadding() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
    }
}
