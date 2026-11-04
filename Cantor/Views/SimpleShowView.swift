import CantorCore
import SwiftUI

/// The Simple view, for an operator who is not a mixer. Three columns: the library's tags, its
/// songs, and the song on the right with the same state bar as the Advanced view and four big
/// buttons: Arm, Disarm, GO and Fade. It drives the same `ShowController`, so every safety rule
/// holds: picking a song is silent, Arm is silent, only GO makes the house audible, and GO keeps
/// its guards. The loaded service, if any, stays loaded and comes back with the Advanced view.
struct SimpleRootView: View {
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SimpleTagList()
                // The column width alone isn't kept for the first of three columns.
                .frame(minWidth: AppDelegate.sidebarMinWidth)
                .navigationSplitViewColumnWidth(min: AppDelegate.sidebarMinWidth, ideal: 220, max: 260)
                .toolbar(removing: .sidebarToggle)
                .toolbar { OperatorModeToolbarItem(columns: $columns, collapsed: .doubleColumn, inSidebar: true) }
        } content: {
            SimpleSongList()
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        } detail: {
            SimpleShowView()
        }
        .toolbar { OperatorModeToolbarItem(columns: $columns, collapsed: .doubleColumn, inSidebar: false) }
    }
}

/// Settings, the sidebar button and the switch below, in the title bar beside the window buttons, so
/// they are on every screen of both views. The sidebar button is Cantor's own rather than the
/// system's, which macOS keeps in a slot of its own, so it and Settings sit at icon spacing. The
/// icons sit in the sidebar's part of the title bar while it is shown, and in the window's when it
/// is hidden, since an item of a hidden sidebar goes to the overflow menu.
struct OperatorModeToolbarItem: ToolbarContent {
    @Binding var columns: NavigationSplitViewVisibility
    /// What hiding the sidebar shows: the detail alone with two columns, two of three with three.
    let collapsed: NavigationSplitViewVisibility
    var showsSidebarButton = true
    /// True on the sidebar column, false on the split view.
    let inSidebar: Bool

    var body: some ToolbarContent {
        let shown = columns != collapsed
        if inSidebar {
            if shown { ToolbarItem(placement: .automatic) { icons(shown: true) } }
        } else {
            if !shown { ToolbarItem(placement: .navigation) { icons(shown: false) } }
            ToolbarItem(placement: .navigation) { OperatorModeToggle() }
        }
    }

    /// One item, so the two icons sit at icon-button spacing rather than in two toolbar slots.
    private func icons(shown: Bool) -> some View {
        HStack(spacing: 11) {
            SettingsLink { Label("Settings", systemImage: "gearshape") }
                .help("Settings (Command-,)")
            if showsSidebarButton {
                Button {
                    withAnimation { columns = shown ? collapsed : .all }
                } label: {
                    Label(shown ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left")
                }
                .help(shown ? "Hide Sidebar" : "Show Sidebar")
            }
        }
        .buttonStyle(.borderless)
        .imageScale(.large)
        .labelStyle(.iconOnly)
        .frame(height: 28)
    }
}

/// Advanced or Simple. Off while a cue is armed or playing, since the two views arm different
/// things, and in Show Mode, which is a lock.
struct OperatorModeToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Picker("View", selection: Binding(get: { model.settings.operatorMode }, set: { model.setOperatorMode($0) })) {
            Text("Advanced").tag(OperatorMode.full)
            Text("Simple").tag(OperatorMode.simple)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .disabled(model.show.showMode || model.show.state.holdsHouseEngine || model.isLoadingService)
        .help("Advanced: the service's cue list with waveform, EQ and every key. Simple: pick a song from the library, then Arm, GO and Fade.")
    }
}

/// All Songs and each tag that has a playable song, with counts.
private struct SimpleTagList: View {
    @Environment(AppModel.self) private var model

    private static let all = "\u{0}all"

    var body: some View {
        let songs = model.library.playbackTracks
        let tags = model.library.allTags.filter { tag in songs.contains { $0.tags.contains(tag) } }
        List(selection: Binding(get: { model.simpleTag ?? Self.all }, set: { model.simpleTag = $0 == Self.all ? nil : $0 })) {
            Label("All Songs", systemImage: "music.note.list")
                .badge(songs.count)
                .tag(Self.all)
            ForEach(tags, id: \.self) { tag in
                Label(tag.capitalized, systemImage: "tag")
                    .badge(songs.filter { $0.tags.contains(tag) }.count)
                    .tag(tag)
            }
        }
        .navigationTitle("Library")
    }
}

/// The songs under the chosen tag, by title, with a search field. Selecting never plays.
private struct SimpleSongList: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    private var tracks: [Track] {
        var result = model.library.playbackTracks
        if let tag = model.simpleTag { result = result.filter { $0.tags.contains(tag) } }
        if !search.isEmpty {
            let query = search.lowercased()
            result = result.filter { $0.title.lowercased().contains(query) || $0.primaryFilename.lowercased().contains(query) }
        }
        return result.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        let tracks = tracks
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search songs", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
            .padding(10)
            Divider()
            List(tracks, selection: Binding(get: { model.simpleTrackID }, set: { model.selectSimpleTrack($0) })) { track in
                SimpleSongRow(track: track, isCurrent: model.show.activeCue?.track?.id == track.id, state: model.show.state)
                    .tag(track.id)
            }
            .overlay {
                if tracks.isEmpty {
                    ContentUnavailableView(
                        search.isEmpty ? "No Songs" : "No Matches", systemImage: "music.note",
                        description: Text(search.isEmpty ? "Songs in the watched folders appear here." : "No song title or file name contains “\(search)”.")
                    )
                }
            }
        }
        .navigationTitle(model.simpleTag?.capitalized ?? "All Songs")
    }
}

private struct SimpleSongRow: View {
    let track: Track
    let isCurrent: Bool
    let state: ShowState

    var body: some View {
        let style = StateStyle(isCurrent ? state : .idle)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.system(size: 14, weight: isCurrent ? .semibold : .regular)).lineLimit(1)
                let detail = ([TimeText.plain((track.endSec ?? track.durationSec) - track.startSec)] + track.tags.map(\.capitalized)).joined(separator: " · ")
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if isCurrent, state != .idle {
                Image(systemName: style.symbol).foregroundStyle(style.color ?? .secondary)
            } else if !track.isLocal {
                Image(systemName: track.hasCloudOnlyCopy ? "icloud" : "questionmark.folder")
                    .foregroundStyle(track.hasCloudOnlyCopy ? Theme.armed : Theme.danger)
                    .help(track.hasCloudOnlyCopy ? "Not downloaded" : "File is missing")
            }
        }
        .padding(.vertical, 3)
    }
}

/// The right side: the state bar, the song, the buttons.
struct SimpleShowView: View {
    static let minWidth: CGFloat = 560

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            StateBar()
            Divider()
            SimpleSongCard()
            Divider()
            SimpleTransportBar()
            Divider()
            SimpleKeyLegend()
        }
        .frame(minWidth: Self.minWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.showBackground)
        .navigationTitle(model.frontCue?.title ?? "Simple")
    }
}

/// The song the show is on: engaged, or else picked. Big, with what matters before pressing Arm.
private struct SimpleSongCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let show = model.show
        Group {
            if let cue = model.frontCue, let track = cue.track {
                let engaged = show.activeCue?.id == cue.id && show.state.holdsHouseEngine
                let style = StateStyle(engaged ? show.state : .idle)
                VStack(alignment: .leading, spacing: 14) {
                    Spacer(minLength: 0)
                    Text(track.title)
                        .font(.system(size: 34, weight: .bold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                    HStack(spacing: 18) {
                        info("LENGTH", TimeText.plain((track.endSec ?? track.durationSec) - track.startSec))
                        if !track.tags.isEmpty { info("TAGS", track.tags.map(\.capitalized).joined(separator: ", ")) }
                        info("FADE", "\(String(format: "%.1f", track.fadeOutSec)) s")
                    }
                    if !track.notes.isEmpty {
                        Text(track.notes).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(3)
                    }
                    if engaged, track.durationSec > 0 {
                        // Where the song is, in the state's color.
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.12))
                                Capsule().fill(style.color ?? .primary)
                                    .frame(width: geometry.size.width * CGFloat(min(max(show.positionSec / track.durationSec, 0), 1)))
                            }
                        }
                        .frame(height: 8)
                    } else if !track.isLocal {
                        Label(track.hasCloudOnlyCopy ? "Not downloaded to this Mac yet, so it cannot be armed." : "The file is missing, so it cannot be armed.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.armed)
                            .font(.system(size: 14, weight: .medium))
                    } else if model.playNowLoading == track.id {
                        Label("Loading…", systemImage: "arrow.down.circle").foregroundStyle(.secondary).font(.system(size: 14, weight: .medium))
                    }
                    Spacer(minLength: 0)
                }
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                ContentUnavailableView(
                    "Pick a Song", systemImage: "music.note.list",
                    description: Text("Choose a song from the list. Nothing plays until you press Arm, then GO.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel)
    }

    private func info(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 16, weight: .medium)).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Notices, the four big buttons and a house meter. The keys and the Transport menu do the same things.
private struct SimpleTransportBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let show = model.show
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if let notice = show.notice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.armed).font(.system(size: 14, weight: .medium))
                }
                if let alert = model.alert {
                    Label(alert, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.armed)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(2)
                        .help(alert)
                    Button("Dismiss") { model.alert = nil }
                        .buttonStyle(.borderless)
                        .hoverHighlight(outset: 3)
                        .focusable(false)
                }
                if show.notice == nil, model.alert == nil {
                    Text(hint).font(.system(size: 14)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(minHeight: 20)
            HStack(alignment: .bottom, spacing: 12) {
                bigButton("Arm", "A", enabled: canArm) { model.arm() }
                bigButton("Disarm", "D", enabled: isArmedOrHeld) { show.disarm() }
                Spacer().frame(width: 24)
                bigButton("GO", "Space", enabled: isArmedOrHeld, prominent: true) { show.go() }
                bigButton("Fade", "F", enabled: isLiveOrHeld) { show.fadeOut() }
                if case .faulted = show.state {
                    bigButton("Acknowledge", "Return", enabled: true) { show.acknowledgeFault() }
                }
                Spacer()
                MeterGroup(title: "HOUSE", meter: model.houseMeter, width: 150)
            }
        }
        .padding(18)
        .background(EQTheme.chrome)
        .environment(\.colorScheme, .dark)
    }

    /// What to do next, in one line.
    private var hint: String {
        switch model.show.state {
        case .idle: model.simpleTrack == nil ? "Pick a song." : "Arm, then GO when it is time."
        case .armed: "GO plays it. Disarm lets it go."
        case .live: "Fade ends it with its saved fade. Esc stops it."
        case .held: "GO resumes."
        case .fading, .panicking: "Ending."
        case .faulted: "The house output stopped. Acknowledge, then Arm again."
        }
    }

    private var canArm: Bool {
        guard model.show.state == .idle, let track = model.simpleTrack else { return false }
        return track.isLocal && model.playNowLoading == nil
    }

    private var isArmedOrHeld: Bool {
        switch model.show.state {
        case .armed, .held: return true
        default: return false
        }
    }

    private var isLiveOrHeld: Bool {
        switch model.show.state {
        case .live, .held: return true
        default: return false
        }
    }

    private func bigButton(_ title: String, _ key: String, enabled: Bool, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title).font(.system(size: 18, weight: .bold))
                Text(key).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            .frame(minWidth: 96, minHeight: 56)
            .padding(.horizontal, 6)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(prominent ? Theme.neutralAccent : nil)
        .focusable(false)
        .hoverBrighten()
        .disabled(!enabled)
    }
}

private struct SimpleKeyLegend: View {
    var body: some View {
        HStack(spacing: 24) {
            ForEach(Self.items, id: \.0) { key, action in
                HStack(spacing: 6) {
                    Text(key).font(.system(size: 12, weight: .semibold, design: .monospaced))
                    Text(action).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 28)
        .background(Theme.panel)
    }

    private static let items = [
        ("A", "Arm"), ("Space", "GO"), ("F", "Fade"), ("D", "Disarm"), ("Esc", "Stop (fade)"), ("Esc Esc", "Stop now"), ("↑ ↓", "Pick song"),
    ]
}
