import CantorCore
import SwiftUI

/// The sidebar while preparing: a system sidebar list, so macOS draws the Liquid Glass panel, the
/// selection and the row sizes, and the panel stays against the window's leading edge. Claude and
/// the outputs sit in a bar pinned under the list, always in view.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?
    @State private var pastOpen = false

    var body: some View {
        List(selection: $selection) {
            serviceSection
            servicesSection
            librarySection
        }
        .listStyle(.sidebar)
        .sidebarBar { SidebarStatusBar() }
    }

    private var serviceSection: some View {
        Section("Service") {
            Label("Show", systemImage: "play.rectangle")
                .tag(SidebarItem.show)
            // A yellow mark while the check finds something to fix or look at, so it is seen before opening it.
            let problems = model.checkResults().filter { $0.severity > .ok }.count
            HStack(spacing: 4) {
                Label("Pre-Service Check", systemImage: "checklist")
                if problems > 0 {
                    Spacer(minLength: 0)
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(Theme.armed)
                        .accessibilityLabel("Needs attention")
                }
            }
            .help(problems > 0 ? "Pre-Service Check found \(problems) \(problems == 1 ? "issue" : "issues")" : "")
            .tag(SidebarItem.check)
        }
    }

    private var servicesSection: some View {
        Section("Services") {
            let busy = model.show.showMode || model.show.state.holdsHouseEngine || model.isLoadingService
            Button {
                model.startNewService()
            } label: {
                Label("New Service…", systemImage: "calendar.badge.plus")
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .help("Build a service here: blank, a copy of another, or from a template. Drop tracks on it to start with them.")
            .acceptsTracks { model.startNewService(with: $0) }
            if model.settings.usesPlanningCenter {
                HStack(spacing: 4) {
                    Button {
                        model.showingServicePicker = true
                    } label: {
                        Label("Choose Service…", systemImage: "calendar")
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .help("Pick a Planning Center service from six weeks back to three weeks ahead")
                    Spacer(minLength: 0)
                    UpdateServicesButton()
                }
            }
            ForEach(model.upcomingSidebarPlans) { plan in
                planRow(plan)
            }
            if model.upcomingSidebarPlans.isEmpty {
                Text(model.sidebarPlans.isEmpty ? (model.plans.isEmpty ? "No services yet" : "None of the shown types") : "Nothing coming up")
                    .foregroundStyle(.secondary)
            }
            let past = model.pastSidebarPlans
            if !past.isEmpty {
                DisclosureGroup(isExpanded: $pastOpen) {
                    ForEach(past) { plan in
                        planRow(plan)
                    }
                } label: {
                    Label("Past Services", systemImage: "clock.arrow.circlepath")
                        .badge(past.count)
                        .help("Services already over. Open one to run it again or copy its order.")
                }
            }
        }
    }

    private var librarySection: some View {
        Section("Library") {
            let library = model.library
            libraryRow("All Tracks", "music.note.list", .all, library.playbackTracks.count)
            ForEach(library.allTags, id: \.self) { tag in
                libraryRow(tag.capitalized, "tag", .tag(tag), library.playbackTracks.filter { $0.tags.contains(tag) }.count)
            }
            if !model.inbox.items.isEmpty {
                Button {
                    model.reviewNewFiles()
                } label: {
                    Label("New Files", systemImage: "tray.and.arrow.down")
                        .badge(model.inbox.items.count)
                }
                .buttonStyle(.plain)
                .disabled(!model.newFilesCanAppear)
                .help(model.newFilesCanAppear ? "Review new files" : "New files wait until no service is loaded")
            }
            libraryRow("Needs Attention", "exclamationmark.triangle", .attention, library.playbackTracks.filter(LibraryView.needsAttention).count)
            libraryRow("Not Downloaded", "icloud", .notDownloaded, library.playbackTracks.filter { !$0.isLocal && $0.hasCloudOnlyCopy }.count)
            libraryRow("Duplicates", "square.on.square", .duplicates, library.duplicateGroups.count)
            libraryRow("Excluded", "eye.slash", .excluded, library.excludedTracks.count)
        }
    }

    /// The date, and the service type or a built service's name under it.
    private func planRow(_ plan: ServicePlan) -> some View {
        HStack(spacing: 4) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(plan.dates.isEmpty ? plan.title : plan.dates).lineLimit(1)
                    Text(plan.isManual ? plan.title : plan.serviceTypeName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemName: "list.bullet.rectangle")
            }
            if plan.id == model.loadedPlanID {
                Spacer(minLength: 0)
                Text("LOADED")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.live)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.live.opacity(0.7)))
            }
        }
        .tag(SidebarItem.plan(plan.id))
        .acceptsTracks(open: { selection = .plan(plan.id) }) { model.addTracks($0, to: plan.id, at: .end) }
    }

    /// A count is left out at zero, as a badge is.
    private func libraryRow(_ title: String, _ symbol: String, _ filter: LibraryFilter, _ count: Int) -> some View {
        Label(title, systemImage: symbol)
            .badge(count)
            .tag(SidebarItem.library(filter))
    }
}

/// Claude, when it is on, and the house and cue outputs, pinned under the sidebar list.
private struct SidebarStatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.settings.llmEnabled {
                ClaudeStatusRow()
            }
            OutputsStatusRow()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
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

/// Claude status. Click to check again.
private struct ClaudeStatusRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let connection = model.claudeConnection
        HStack(alignment: .firstTextBaseline) {
            Button {
                model.refreshClaudeConnection()
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    ClaudeStatusLabel(connection: connection)
                    if let hint = connection.hint {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(connection.detail) Click to check again.")
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Claude settings")
        }
        .statusRowPadding()
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .statusRowPadding()
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
    /// A status row's hover wash spans the bar.
    func statusRowPadding() -> some View {
        padding(.horizontal, 8)
            .padding(.vertical, 4)
            .hoverHighlight(cornerRadius: 6)
    }
}

extension View {
    /// Pins `bar` under a sidebar list. On macOS 26 it is a bar the list scrolls under, with a hard
    /// scroll edge so the rows never show through the status.
    @ViewBuilder
    func sidebarBar(@ViewBuilder _ bar: () -> some View) -> some View {
        if #available(macOS 26, *) {
            safeAreaBar(edge: .bottom, spacing: 0, content: bar)
                .scrollEdgeEffectStyle(.hard, for: .bottom)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    bar()
                }
                .background(.bar)
            }
        }
    }
}
