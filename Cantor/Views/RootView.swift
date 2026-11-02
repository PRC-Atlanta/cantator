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
        }
        .toolbar(removing: model.show.showMode ? .sidebarToggle : nil)
        .onChange(of: columns) { _, value in
            // The sidebar leads to text fields, so it stays closed in Show Mode.
            if model.show.showMode, value != .detailOnly { columns = .detailOnly }
        }
        .onChange(of: model.show.showMode) { _, locked in
            if locked {
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
        // An alert is a sheet, which would take the transport keys. Show Mode puts it in the Show view instead.
        .alert("Cantor", isPresented: Binding(get: { model.alert != nil && !model.show.showMode }, set: { if !$0 { model.alert = nil } })) {
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

private struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?

    var body: some View {
        let library = model.library
        List(selection: $selection) {
            Section("Service") {
                Label("Show", systemImage: "play.rectangle").tag(SidebarItem.show)
                Label("Pre-Service Check", systemImage: "checklist").tag(SidebarItem.check)
            }
            Section("Upcoming") {
                ForEach(model.plans) { plan in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(plan.dates.isEmpty ? plan.title : plan.dates).lineLimit(1)
                        Text(plan.serviceTypeName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .tag(SidebarItem.plan(plan.id))
                }
                if model.plans.isEmpty {
                    Text("None synced").foregroundStyle(.secondary)
                }
            }
            Section("Library") {
                row("All Tracks", "music.note.list", .all, library.playbackTracks.count)
                ForEach(library.allTags, id: \.self) { tag in
                    row(tag.capitalized, "tag", .tag(tag), library.playbackTracks.filter { $0.tags.contains(tag) }.count)
                }
                if !model.inbox.items.isEmpty {
                    Button {
                        model.reviewNewFiles()
                    } label: {
                        Label("New Files", systemImage: "tray.and.arrow.down").badge(model.inbox.items.count)
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.newFilesCanAppear)
                    .help(model.newFilesCanAppear ? "Review new files" : "New files wait until no service is loaded")
                }
                row("Needs Attention", "exclamationmark.triangle", .attention, library.playbackTracks.filter(LibraryView.needsAttention).count)
                row("Not Downloaded", "icloud", .notDownloaded, library.playbackTracks.filter { !$0.isLocal && $0.hasCloudOnlyCopy }.count)
                row("Duplicates", "square.on.square", .duplicates, library.duplicateGroups.count)
                row("Excluded", "eye.slash", .excluded, library.excludedTracks.count)
            }
            Section("Claude") {
                ClaudeStatusRow()
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ title: String, _ symbol: String, _ filter: LibraryFilter, _ count: Int) -> some View {
        Label(title, systemImage: symbol)
            .badge(count)
            .tag(SidebarItem.library(filter))
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
                .help("Claude settings")
            }
            if let hint = connection.hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .contentShape(Rectangle())
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
