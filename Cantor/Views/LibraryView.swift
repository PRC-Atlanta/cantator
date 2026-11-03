import AppKit
import CantorCore
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    let filter: LibraryFilter
    @State private var selection: Set<UUID> = []
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\Track.title)]

    static func needsAttention(_ track: Track) -> Bool {
        track.endSec == nil || !track.isLocal || !track.isAnalyzed
    }

    private var tracks: [Track] {
        var result = filter == .excluded ? model.library.excludedTracks : model.library.playbackTracks
        switch filter {
        case .all, .excluded: break
        case .attention: result = result.filter(Self.needsAttention)
        case .notDownloaded: result = result.filter { !$0.isLocal && $0.hasCloudOnlyCopy }
        case .tag(let tag): result = result.filter { $0.tags.contains(tag) }
        case .duplicates:
            let ids = Set(model.library.duplicateGroups.flatMap(\.trackIDs))
            result = result.filter { ids.contains($0.id) }
        }
        if !search.isEmpty {
            let query = search.lowercased()
            result = result.filter { $0.title.lowercased().contains(query) || $0.primaryFilename.lowercased().contains(query) }
        }
        return result.sorted(using: sortOrder)
    }

    var body: some View {
        Table(of: Track.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Title", value: \.title) { track in
                Text(track.title).lineLimit(1)
            }
            .width(min: 200, ideal: 300)
            TableColumn(filter == .excluded ? "Why" : "Tags") { (track: Track) in
                Text(track.exclusion?.reason ?? track.tags.joined(separator: ", ")).foregroundStyle(.secondary).lineLimit(1)
                    .help(track.exclusion?.reason ?? "")
            }
            .width(min: 70, ideal: filter == .excluded ? 260 : 110)
            TableColumn("Length", value: \.durationSec) { track in
                Text(TimeText.plain(track.durationSec)).font(.system(.body, design: .monospaced))
            }
            .width(60)
            TableColumn("Local") { (track: Track) in
                if track.isLocal {
                    Image(systemName: "internaldrive").foregroundStyle(.secondary).help("On this Mac")
                } else if track.hasCloudOnlyCopy {
                    Image(systemName: "icloud").foregroundStyle(Theme.armed).help("Not downloaded")
                } else {
                    Image(systemName: "questionmark.folder").foregroundStyle(Theme.danger).help("File is missing")
                }
            }
            .width(44)
            TableColumn("End") { (track: Track) in
                Image(systemName: track.endSec == nil ? "circle" : "checkmark.circle")
                    .foregroundStyle(track.endSec == nil ? Color.secondary : Color.primary)
            }
            .width(36)
            TableColumn("LUFS") { (track: Track) in
                Text(track.integratedLUFS.map { String(format: "%.1f", $0) } ?? "-")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(56)
            TableColumn("Files") { (track: Track) in
                Text("\(track.files.count)").foregroundStyle(.secondary)
            }
            .width(40)
        } rows: {
            ForEach(tracks) { track in
                // Drag onto a service in the sidebar, or onto an item in a service.
                TableRow(track).draggable(TrackDrag.payload(track.id))
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            TrackActions(ids: ids, clearSelection: { selection = [] })
            Divider()
            AddToServiceMenu(trackIDs: inTableOrder(ids))
        }
        .onDeleteCommand { exclude(selection) }
        .searchable(text: $search, placement: .toolbar, prompt: "Search")
        .inspector(isPresented: .constant(true)) {
            Group {
                if selection.count == 1, let id = selection.first, let track = model.library.track(id: id) {
                    TrackInspector(track: track)
                } else if selection.count > 1 {
                    SelectionInspector(ids: selection, clearSelection: { selection = [] })
                } else {
                    ContentUnavailableView(
                        "No Track Selected", systemImage: "waveform",
                        description: Text("Shift-click or Command-click to select several tracks, or press Command-A for all.")
                    )
                }
            }
            .inspectorColumnWidth(min: 320, ideal: 380, max: 460)
        }
        .navigationTitle("Library")
        .navigationSubtitle(subtitle)
        // Leaving a list clears what was selected in it, so actions never reach hidden tracks.
        .onChange(of: filter) { selection = [] }
        .onChange(of: selection) { model.preparePlayNow(selectedTrack) }
        .toolbar {
            ToolbarItem {
                PlayNowButton(track: selectedTrack)
            }
            ToolbarItemGroup {
                TrackActions(ids: selection, clearSelection: { selection = [] })
                    .labelStyle(.titleAndIcon)
            }
            ToolbarItem {
                ImportButton()
            }
            ToolbarItem {
                Button {
                    model.rescan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(model.isScanning)
                .help("Rescan your folders")
            }
        }
    }

    private var selectedTrack: Track? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return model.library.track(id: id)
    }

    private func inTableOrder(_ ids: Set<UUID>) -> [UUID] {
        tracks.map(\.id).filter(ids.contains)
    }

    private func exclude(_ ids: Set<UUID>) {
        let ids = ids.filter { model.library.track(id: $0)?.isExcluded == false }
        guard !ids.isEmpty else { return }
        model.excludeTracks(ids)
        selection = []
    }

    private var subtitle: String {
        if !selection.isEmpty { return "\(selection.count) of \(tracks.count) selected" }
        if let status = model.imports.status {
            return status.paused ? "Import paused until the show is idle" : "Importing \(status.filename) · \(status.percent)%"
        }
        if model.isScanning { return "Scanning" }
        if model.analyzingCount > 0 { return "Analyzing \(model.analyzingCount)" }
        if filter == .excluded { return "\(model.library.excludedTracks.count) left out of matching" }
        return "\(model.library.playbackTracks.count) tracks"
    }
}

/// Picks audio files and converts them into ~/Music/Cantor as m4a. Used in the toolbar and the File menu.
struct ImportButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            Self.choose(model)
        } label: {
            if let status = model.imports.status {
                Label {
                    Text(Self.text(status)).monospacedDigit()
                } icon: {
                    ProgressView(value: status.fraction).progressViewStyle(.circular).controlSize(.small)
                }
            } else {
                Label("Import…", systemImage: "square.and.arrow.down")
            }
        }
        .disabled(!model.canImport)
        .help(model.imports.status.map { status in
            status.paused
                ? "Import waits while a cue is armed or playing, or Show Mode is on."
                : "Converting \(status.filename). Choose more files to add them after it."
        }
            ?? "Convert audio files, or the audio from movies, to m4a in ~/Music/Cantor and add them to the library")
    }

    static func text(_ status: ImportQueue.Status) -> String {
        let count = status.total > 1 ? " \(status.number) of \(status.total)" : ""
        if status.paused { return "Import paused\(count)" }
        return count.isEmpty ? "Importing \(status.percent)%" : "Importing\(count) · \(status.percent)%"
    }

    static func choose(_ model: AppModel) {
        let panel = NSOpenPanel()
        panel.title = "Import Audio"
        panel.prompt = "Import"
        panel.message = "Files are converted to m4a. From a movie, only the audio is kept. Some file types need FFmpeg."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Importer.pickableExtensions.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        model.importFiles(panel.urls)
    }
}

/// Exclude, Include, Make Local and Tag for the selected tracks. Used in the toolbar, the
/// right-click menu and the inspector when several tracks are selected.
/// Emergency: one click on a track, one click here, and it plays on the house output. It skips
/// the service, the arm-to-GO wait and the Show Mode lock, then hands over to the Show view.
private struct PlayNowButton: View {
    @Environment(AppModel.self) private var model
    let track: Track?

    var body: some View {
        let loading = track != nil && model.playNowLoading == track?.id
        Button {
            if let track { model.playNow(track) }
        } label: {
            Label(loading ? "Loading…" : "Arm + Play", systemImage: "play.fill")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.danger)
        .disabled(!canPlay || model.playNowLoading != nil)
        .help(help)
    }

    private var canPlay: Bool {
        guard let track, track.isLocal else { return false }
        switch model.show.state {
        case .idle, .armed, .faulted: return true
        default: return false
        }
    }

    private var help: String {
        guard let track else { return "Select one track to play it on the house output right away" }
        if !track.isLocal { return "\(track.title) is not on this Mac yet" }
        if !canPlay { return "A cue is playing. Stop it first." }
        return "Play \(track.title) on the house output now, skipping arm and the service"
    }
}

private struct TrackActions: View {
    @Environment(AppModel.self) private var model
    let ids: Set<UUID>
    let clearSelection: () -> Void

    var body: some View {
        let tracks = ids.compactMap { model.library.track(id: $0) }
        let included = Set(tracks.filter { !$0.isExcluded }.map(\.id))
        let excluded = Set(tracks.filter(\.isExcluded).map(\.id))
        let locked = model.show.showMode
        Button {
            model.excludeTracks(included)
            clearSelection()
        } label: {
            Label("Exclude", systemImage: "eye.slash")
        }
        .disabled(included.isEmpty || locked)
        .help("Not a playback: leave out of matching and the library lists (Delete)")

        Button {
            model.keepTracks(excluded)
            clearSelection()
        } label: {
            Label("Include", systemImage: "eye")
        }
        .disabled(excluded.isEmpty || locked)
        .help("This is a playback: bring back from Excluded")

        Button {
            for track in tracks where !model.makingLocal.contains(track.id) { model.makeLocal(track) }
        } label: {
            Label("Make Local", systemImage: "arrow.down.circle")
        }
        .disabled(tracks.isEmpty)
        .help("Copy to ~/Music/Cantor, downloading from Drive if needed")

        Menu {
            ForEach(PlaybackCategory.all(libraryTags: model.library.allTags), id: \.self) { tag in
                let all = !tracks.isEmpty && tracks.allSatisfy { $0.tags.contains(tag) }
                Button {
                    model.toggleTag(tag, on: ids)
                } label: {
                    if all { Label(PlaybackCategory.display(tag), systemImage: "checkmark") } else { Text(PlaybackCategory.display(tag)) }
                }
            }
        } label: {
            Label("Tag", systemImage: "tag")
        }
        .disabled(tracks.isEmpty || locked)
        .help("Add a tag to the selected tracks, or remove it when they all have it")
    }
}

/// Shown in place of the track inspector when several tracks are selected.
private struct SelectionInspector: View {
    @Environment(AppModel.self) private var model
    let ids: Set<UUID>
    let clearSelection: () -> Void

    var body: some View {
        let tracks = ids.compactMap { model.library.track(id: $0) }
        Form {
            Section {
                LabeledContent("Selected", value: "\(tracks.count) tracks")
                LabeledContent("Total length", value: TimeText.plain(tracks.reduce(0) { $0 + $1.durationSec }))
                let excluded = tracks.filter(\.isExcluded).count
                if excluded > 0 { LabeledContent("Excluded", value: "\(excluded)") }
                let notLocal = tracks.filter { !$0.isLocal }.count
                if notLocal > 0 { LabeledContent("Not on this Mac", value: "\(notLocal)") }
            }
            Section("Actions") {
                VStack(alignment: .leading, spacing: 8) {
                    TrackActions(ids: ids, clearSelection: clearSelection)
                        .labelStyle(.titleAndIcon)
                    AddToServiceMenu(trackIDs: tracks.sorted { $0.title < $1.title }.map(\.id))
                        .fixedSize()
                }
            }
            Section("Titles") {
                ForEach(tracks.sorted { $0.title < $1.title }.prefix(50), id: \.id) { track in
                    Text(track.title).lineLimit(1)
                }
                if tracks.count > 50 { Text("and \(tracks.count - 50) more").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct TrackInspector: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let track: Track
    @State private var tagText = ""

    private var editing: Bool { !model.show.showMode }

    var body: some View {
        Form {
            if let exclusion = track.exclusion {
                Section("Excluded") {
                    Text(exclusion.reason)
                    Text("Excluded files are left out of matching and the other library lists.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("This Is a Playback") { model.keepTrack(track.id) }
                        .disabled(!editing)
                }
            }
            Section {
                WaveformEditor(track: track)
                    .frame(height: 110)
                    .listRowInsets(EdgeInsets())
                HStack {
                    let ending = max((track.endSec ?? track.durationSec) - 15, 0)
                    Button {
                        model.toggleAudition(track, fromSec: track.startSec)
                    } label: {
                        let on = model.isAuditioning(track, fromSec: track.startSec)
                        Label(on ? "Stop" : "Preview", systemImage: on ? "stop.fill" : "headphones")
                    }
                    Button {
                        model.toggleAudition(track, fromSec: ending)
                    } label: {
                        let on = model.isAuditioning(track, fromSec: ending)
                        Label(on ? "Stop" : "Preview Ending", systemImage: on ? "stop.fill" : "forward.end")
                    }
                    Spacer()
                    if let position = model.auditionPositionSec {
                        Text(TimeText.tenths(position)).font(.system(.body, design: .monospaced))
                    }
                }
                .disabled(!track.isLocal)
            }

            Section("EQ") {
                let eq = track.eq ?? TrackEQ()
                EQThumbnail(eq: eq)
                    .frame(height: 44)
                HStack {
                    Button("Edit EQ") { openWindow(id: "eq", value: track.id) }
                    if track.eq != nil {
                        Toggle("On", isOn: Binding(get: { eq.isOn }, set: { value in model.updateTrack(track.id) { $0.eq?.isOn = value } }))
                            .disabled(!editing)
                    }
                    Spacer()
                    Text(eq.isFlat ? "Flat" : "Shaped").foregroundStyle(.secondary)
                }
            }

            Section("Points") {
                secondsField("Start", value: track.startSec) { value in model.updateTrack(track.id) { $0.startSec = value } }
                if let end = track.endSec {
                    secondsField("End", value: end) { value in model.updateTrack(track.id) { $0.endSec = value } }
                } else {
                    LabeledContent("End", value: "Not set")
                }
                HStack {
                    Button("Set End Here") {
                        if let position = model.auditionPositionSec { model.updateTrack(track.id) { $0.endSec = position } }
                    }
                    .disabled(model.auditionPositionSec == nil)
                    if let suggested = track.suggestedEndSec {
                        Button("Use \(TimeText.tenths(suggested))") { model.updateTrack(track.id) { $0.endSec = suggested } }
                            .help("Last point above -50 dBFS")
                    }
                }
                secondsField("Fade Out", value: track.fadeOutSec) { value in model.updateTrack(track.id) { $0.fadeOutSec = value } }
                secondsField("Fade In", value: track.fadeInSec) { value in model.updateTrack(track.id) { $0.fadeInSec = value } }
            }

            Section("Markers") {
                ForEach(track.markers) { marker in
                    HStack {
                        Text(marker.name)
                        Spacer()
                        Text(TimeText.tenths(marker.seconds)).font(.system(.body, design: .monospaced))
                        Button {
                            model.updateTrack(track.id) { $0.markers.removeAll { $0.id == marker.id } }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .hoverHighlight(outset: 3)
                    }
                }
                Button("Add Marker at Preview Position") {
                    if let position = model.auditionPositionSec {
                        model.updateTrack(track.id) {
                            $0.markers.append(Marker(name: "M\($0.markers.count + 1)", seconds: position))
                            $0.markers.sort { $0.seconds < $1.seconds }
                        }
                    }
                }
                .disabled(model.auditionPositionSec == nil)
            }

            Section("Level") {
                LabeledContent("Integrated", value: track.integratedLUFS.map { String(format: "%.1f LUFS", $0) } ?? "Not analyzed")
                LabeledContent("True Peak", value: track.truePeakDb.map { String(format: "%.1f dBTP", $0) } ?? "Not analyzed")
                LabeledContent("Playback Gain", value: TimeText.decibels(model.gainDb(for: track)))
                LabeledContent("Trim") {
                    Stepper(TimeText.decibels(track.trimDb), value: Binding(
                        get: { track.trimDb },
                        set: { value in model.updateTrack(track.id) { $0.trimDb = min(max(value, -12), 12) } }
                    ), step: 0.5)
                }
            }

            Section("Details") {
                TextField("Title", text: stringBinding(\.title))
                TextField("Key", text: stringBinding(\.key))
                TextField("Notes", text: stringBinding(\.notes), axis: .vertical).lineLimit(2...4)
                HStack {
                    tagToggle("choir")
                    tagToggle("special")
                    tagToggle("offertory")
                }
                TextField("Add tag", text: $tagText)
                    .onSubmit {
                        let tag = tagText.trimmingCharacters(in: .whitespaces).lowercased()
                        guard !tag.isEmpty else { return }
                        model.updateTrack(track.id) { if !$0.tags.contains(tag) { $0.tags.append(tag) } }
                        tagText = ""
                    }
                if !track.tags.isEmpty {
                    LabeledContent("Tags", value: track.tags.joined(separator: ", "))
                }
            }

            Section("Files") {
                ForEach(track.files, id: \.path) { file in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.filename).lineLimit(1)
                        Text(file.path).font(.caption2).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    }
                }
                Button(model.makingLocal.contains(track.id) ? "Copying" : "Make Local") { model.makeLocal(track) }
                    .disabled(model.makingLocal.contains(track.id))
                    .help("Copy to ~/Music/Cantor. The original stays where it is.")
                AddToServiceMenu(trackIDs: [track.id])
            }
        }
        .formStyle(.grouped)
        .disabled(!editing)
    }

    private func stringBinding(_ path: WritableKeyPath<Track, String>) -> Binding<String> {
        Binding(get: { track[keyPath: path] }, set: { value in model.updateTrack(track.id) { $0[keyPath: path] = value } })
    }

    private func tagToggle(_ tag: String) -> some View {
        Toggle(tag.capitalized, isOn: Binding(
            get: { track.tags.contains(tag) },
            set: { on in
                model.updateTrack(track.id) {
                    $0.tags.removeAll { $0 == tag }
                    if on { $0.tags.append(tag) }
                }
            }
        ))
        .toggleStyle(.checkbox)
    }

    private func secondsField(_ title: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        LabeledContent(title) {
            TextField(title, value: Binding(get: { value }, set: set), format: .number.precision(.fractionLength(1)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .font(.system(.body, design: .monospaced))
                .frame(width: 80)
        }
    }
}

/// Dragging near a boundary moves it. Dragging never plays anything.
private struct WaveformEditor: View {
    @Environment(AppModel.self) private var model
    let track: Track
    @State private var dragging: Boundary?

    private enum Boundary { case start, end }

    var body: some View {
        GeometryReader { geometry in
            WaveformCanvas(
                peaks: model.peaks(for: track.id), durationSec: track.durationSec, startSec: track.startSec,
                endSec: track.endSec, fadeSec: track.fadeOutSec, markers: track.markers
            )
            .overlay(alignment: .topLeading) {
                if let position = model.auditionPositionSec, track.durationSec > 0, model.cueBus.trackID == track.id {
                    Rectangle().fill(Theme.cue).frame(width: 2)
                        .offset(x: geometry.size.width * CGFloat(position / track.durationSec))
                }
            }
            .contentShape(Rectangle())
            // Any drag moves the nearer boundary, so the whole waveform shows the resize pointer.
            .pointerStyle(model.show.showMode ? .default : .columnResize)
            .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                guard track.durationSec > 0, !model.show.showMode else { return }
                let seconds = min(max(Double(value.location.x / geometry.size.width) * track.durationSec, 0), track.durationSec)
                if dragging == nil {
                    let toStart = abs(seconds - track.startSec)
                    let toEnd = abs(seconds - (track.endSec ?? track.durationSec))
                    dragging = toStart < toEnd ? .start : .end
                }
                switch dragging {
                case .start: model.updateTrack(track.id) { $0.startSec = min(seconds, ($0.endSec ?? $0.durationSec) - 0.1) }
                case .end: model.updateTrack(track.id) { $0.endSec = max(seconds, $0.startSec + 0.1) }
                case nil: break
                }
            }.onEnded { _ in dragging = nil })
        }
    }
}
