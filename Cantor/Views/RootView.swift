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
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(selection: $model.selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            detail
                .sheet(isPresented: $model.showingServicePicker) { ServicePickerSheet() }
        }
        .toolbar(removing: model.show.showMode ? .sidebarToggle : nil)
        .onChange(of: columns) { _, value in
            // The sidebar leads to text fields, so it stays closed in Show Mode.
            if model.show.showMode, value != .detailOnly { columns = .detailOnly }
        }
        .onChange(of: model.show.showMode) { _, locked in
            if locked {
                model.showingServicePicker = false
                model.selection = .show
                columns = .detailOnly
            } else {
                columns = .all
            }
        }
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
        // An alert is a sheet, which would take the transport keys. Show Mode puts it in the Show view instead.
        .alert("Cantator", isPresented: Binding(get: { model.alert != nil && !model.show.showMode }, set: { if !$0 { model.alert = nil } })) {
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

    var body: some View {
        let library = model.library
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                SidebarHeader("Service")
                row(.show) { SidebarLabel("Show", "play.rectangle") }
                row(.check) { SidebarLabel("Pre-Service Check", "checklist") }
            }
            .padding(10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    SidebarHeader("Services")
                    HStack(spacing: 6) {
                        Button {
                            model.showingServicePicker = true
                        } label: {
                            SidebarLabel("Choose Service…", "calendar.badge.plus").sidebarRowPadding()
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight(cornerRadius: 6)
                        .disabled(model.show.showMode || model.isLoadingService)
                        .help("Pick a service from six weeks back to three weeks ahead")
                        UpdateServicesButton()
                            .padding(.trailing, 6)
                    }
                    ForEach(model.sidebarPlans) { plan in
                        row(.plan(plan.id)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(plan.dates.isEmpty ? plan.title : plan.dates).lineLimit(1)
                                Text(plan.serviceTypeName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .acceptsTracks(open: { selection = .plan(plan.id) }) { model.addTracks($0, to: plan.id, at: .end) }
                    }
                    if model.sidebarPlans.isEmpty {
                        Text(model.plans.isEmpty ? "None synced" : "None of the shown types")
                            .foregroundStyle(.secondary)
                            .sidebarRowPadding()
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
                SidebarHeader("Claude")
                ClaudeStatusRow()
            }
            .padding(10)
        }
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

    init(_ title: String, _ symbol: String, count: Int = 0) {
        self.title = title
        self.symbol = symbol
        self.count = count
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).frame(width: 18)
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
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
