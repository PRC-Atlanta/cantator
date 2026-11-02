import CantorCore
import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    let filter: LibraryFilter
    @State private var selection: UUID?
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
        Table(tracks, selection: $selection, sortOrder: $sortOrder) {
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
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search")
        .inspector(isPresented: .constant(true)) {
            Group {
                if let id = selection, let track = model.library.track(id: id) {
                    TrackInspector(track: track)
                } else {
                    ContentUnavailableView("No Track Selected", systemImage: "waveform")
                }
            }
            .inspectorColumnWidth(min: 320, ideal: 380, max: 460)
        }
        .navigationTitle("Library")
        .navigationSubtitle(subtitle)
        .toolbar {
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

    private var subtitle: String {
        if model.isScanning { return "Scanning" }
        if model.analyzingCount > 0 { return "Analyzing \(model.analyzingCount)" }
        if filter == .excluded { return "\(model.library.excludedTracks.count) left out of matching" }
        return "\(model.library.playbackTracks.count) tracks"
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
                    Button {
                        model.cueBus.isPlaying ? model.stopAudition() : model.audition(track, fromSec: track.startSec)
                    } label: {
                        Label(model.cueBus.isPlaying ? "Stop" : "Preview", systemImage: model.cueBus.isPlaying ? "stop.fill" : "headphones")
                    }
                    Button("Preview Ending") {
                        model.audition(track, fromSec: max((track.endSec ?? track.durationSec) - 15, 0))
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
                if let plan = model.loadedPlan ?? model.plans.first {
                    Button("Add to \(plan.dates.isEmpty ? plan.title : plan.dates)") {
                        model.addManualCue(planID: plan.id, track: track)
                    }
                }
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
