import CantorCore
import Combine
import SwiftUI

/// The sidebar while preparing: system sidebar lists, so macOS draws the Liquid Glass panel, the
/// selection and the row sizes, and the panel stays against the window's leading edge. Only the
/// services scroll: the service sits in a bar pinned above them, and the library and the outputs in
/// one pinned under them, always in view.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?
    @State private var pastOpen = false
    /// Which services are upcoming, and inside the rolling window, depends on the date.
    @State private var today = Date()
    @State private var height: CGFloat = 0

    var body: some View {
        let _ = today
        List(selection: $selection) {
            servicesSection
        }
        .listStyle(.sidebar)
        // Double-clicking a service loads it and enters Show Mode, so going live is one step.
        .contextMenu(forSelectionType: SidebarItem.self) { items in
            if case .plan(let id) = items.first, items.count == 1 {
                Button(model.isSimple ? "Load and Open Show" : "Load and Enter Show Mode") { model.goLive(planID: id) }
                    .disabled(model.isLoadingService)
                Button(model.loadedPlanID == id ? "Reload Service" : "Load Service") { model.loadService(planID: id) }
                    .disabled(model.isLoadingService || model.show.showMode || model.show.state.holdsHouseEngine)
            }
        } primaryAction: { items in
            if case .plan(let id) = items.first, items.count == 1 { model.goLive(planID: id) }
        }
        .sidebarBar(.top) {
            PinnedSidebarList(selection: $selection) { serviceSection }
        }
        .sidebarBar(.bottom) {
            VStack(spacing: 0) {
                // Never more than half the sidebar, so a long tag list can't push the services out.
                PinnedSidebarList(selection: $selection, maxHeight: max(height / 2, 120)) { librarySection }
                OutputsStatusRow()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        // The window rolls on at midnight even while nothing else changes.
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in
            today = Date()
        }
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
        Section {
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
            let shown = model.shownUpcomingPlans
            ForEach(shown) { plan in
                planRow(plan)
            }
            let weeks = model.settings.upcomingServicesWeeks
            if shown.isEmpty {
                Text(model.sidebarPlans.isEmpty ? (model.plans.isEmpty ? "No services yet" : "None of the shown types")
                    : model.upcomingSidebarPlans.isEmpty ? "Nothing coming up" : "Nothing in the \(UpcomingFilterMenu.name(weeks).lowercased())")
                    .foregroundStyle(.secondary)
            }
            let later = model.upcomingSidebarPlans.count - shown.count
            if later > 0 {
                Text("\(later) later \(later == 1 ? "service" : "services") not shown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("The filter beside Services shows the \(UpcomingFilterMenu.name(weeks).lowercased()). Choose All Upcoming to see every service.")
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
        } header: {
            HStack(spacing: 4) {
                Text("Services")
                Spacer(minLength: 4)
                UpcomingFilterMenu()
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

    /// A count is left out at zero, as a badge is.
    private func libraryRow(_ title: String, _ symbol: String, _ filter: LibraryFilter, _ count: Int) -> some View {
        Label(title, systemImage: symbol)
            .badge(count)
            .tag(SidebarItem.library(filter))
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
        .help(model.isSimple ? "Double-click to load it and open the Show view" : "Double-click to load it and enter Show Mode")
        .acceptsTracks(open: { selection = .plan(plan.id) }) { model.addTracks($0, to: plan.id, at: .end) }
    }
}

/// How far ahead the sidebar lists services. The window is counted from today, so it moves on
/// as the weeks pass: two weeks always means the next two weeks.
private struct UpcomingFilterMenu: View {
    @Environment(AppModel.self) private var model

    static let choices = [0, 1, 2, 3, 4, 8]

    static func name(_ weeks: Int) -> String {
        switch weeks {
        case 0: "All Upcoming"
        case 1: "Next Week"
        default: "Next \(weeks) Weeks"
        }
    }

    var body: some View {
        let weeks = model.settings.upcomingServicesWeeks
        HStack(spacing: 4) {
            if weeks > 0 {
                Text(Self.name(weeks))
            }
            Menu {
                Picker("Show", selection: Binding(
                    get: { weeks },
                    set: { value in model.updateSettings { $0.upcomingServicesWeeks = value } }
                )) {
                    ForEach(Self.choices, id: \.self) { choice in
                        Text(Self.name(choice)).tag(choice)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: weeks > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(weeks > 0 ? "Showing services in the \(Self.name(weeks).lowercased()), counted from today" : "Show only the services in the next few weeks")
            .accessibilityLabel("Filter Services")
        }
    }
}

/// A sidebar list pinned above or below the services, sharing their selection. As tall as its
/// rows, so it does not scroll, up to `maxHeight`.
private struct PinnedSidebarList<Content: View>: View {
    @Binding var selection: SidebarItem?
    var maxHeight: CGFloat = .infinity
    @ViewBuilder var content: Content
    /// Measured from the rows once the list lays them out.
    @State private var contentHeight: CGFloat = 200

    var body: some View {
        List(selection: $selection) {
            content
        }
        .listStyle(.sidebar)
        .scrollDisabled(contentHeight <= maxHeight)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in
            contentHeight = height
        }
        .frame(height: min(contentHeight, maxHeight))
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

/// House and cue, always in view while preparing. Amber until both are set, connected and on
/// different outputs, which is what Arm will insist on. Click to open Settings > Outputs.
private struct OutputsStatusRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let routing = model.settings.routing
        let connected = Set(model.devices.map(\.uid))
        let houseOK = routing.houseDeviceUID.map(connected.contains) ?? false
        let cueOK = routing.cueDeviceUID.map(connected.contains) ?? false
        let distinct = !routing.sharesOutputs
        Button {
            model.openSettings(.outputs)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                line("House", name: name(routing.houseDeviceUID, first: routing.houseFirstChannel), ok: houseOK && distinct)
                line("Cue", name: name(routing.cueDeviceUID, first: routing.cueFirstChannel), ok: cueOK && distinct)
                if routing.sharesOutputs {
                    Text("Must use different outputs").font(.caption).foregroundStyle(Theme.armed)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .statusRowPadding()
        .help("Open Settings > Outputs")
    }

    /// The device, with its pair when it has more than one.
    private func name(_ uid: String?, first: Int) -> String {
        let name = model.deviceName(uid)
        guard let uid, let device = model.devices.first(where: { $0.uid == uid }), device.outputChannels > 2 else { return name }
        return "\(name) \(first + 1)-\(first + 2)"
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
    /// Pins `bar` above or under a sidebar list. On macOS 26 it is a bar the list scrolls under, with
    /// a hard scroll edge so the rows never show through it.
    @ViewBuilder
    func sidebarBar(_ edge: VerticalEdge, @ViewBuilder _ bar: () -> some View) -> some View {
        if #available(macOS 26, *) {
            safeAreaBar(edge: edge, spacing: 0, content: bar)
                .scrollEdgeEffectStyle(.hard, for: edge == .top ? .top : .bottom)
        } else {
            safeAreaInset(edge: edge, spacing: 0) {
                VStack(spacing: 0) {
                    if edge == .bottom { Divider() }
                    bar()
                    if edge == .top { Divider() }
                }
                .background(.bar)
            }
        }
    }
}
