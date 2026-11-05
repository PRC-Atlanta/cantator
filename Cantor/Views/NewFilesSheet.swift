import CantorCore
import SwiftUI

/// Every file waiting under New Files, in one list, with Claude's suggestion filled in. Rows can be
/// changed one at a time or several at once, and nothing is applied until Apply. The answers live in
/// the model, so Later or an alert over the list never loses them.
struct NewFilesSheet: View {
    @AppEnvironment private var model
    @State private var selection: Set<UUID> = []
    @State private var showing = Showing.all

    enum Showing: Hashable {
        case all, playbacks, notPlaybacks
    }

    private struct Row: Identifiable {
        let item: NewFileItem
        let track: Track
        let filename: String
        let folder: String
        let path: String
        var id: UUID { item.trackID }

        /// Named and placed by the original file, not Cantator's copy, so a song's files sit together.
        init(item: NewFileItem, track: Track) {
            self.item = item
            self.track = track
            let file = StemDetector.sourceFile(track)
            filename = file?.filename ?? track.title
            folder = file.map { $0.url.deletingLastPathComponent().pathComponents.suffix(2).joined(separator: "/") } ?? ""
            path = file?.path ?? ""
        }
    }

    /// Grouped by folder, so a song's stems, parts and playback sit together. Built once per update:
    /// with hundreds of files a lookup per row in the library would be slow.
    private func allRows() -> [Row] {
        let tracks = Dictionary(model.library.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return model.inbox.ready
            .compactMap { item in tracks[item.trackID].map { Row(item: item, track: $0) } }
            .sorted { ($0.folder, $0.filename) < ($1.folder, $1.filename) }
    }

    private func isPlayback(_ id: UUID) -> Bool {
        model.newFileAnswers[id]?.isPlayback ?? true
    }

    var body: some View {
        let all = allRows()
        let rows = switch showing {
        case .all: all
        case .playbacks: all.filter { isPlayback($0.id) }
        case .notPlaybacks: all.filter { !isPlayback($0.id) }
        }
        let tags = model.tagNames
        let upcoming = model.upcomingItemsForPicker
        VStack(alignment: .leading, spacing: 12) {
            header(all, tags: tags)
            Table(rows, selection: $selection) {
                TableColumn("Playback") { (row: Row) in
                    Toggle("Playback", isOn: binding(row.id, \.isPlayback, default: true)).labelsHidden().toggleStyle(.checkbox)
                }
                .width(56)
                TableColumn("Title") { (row: Row) in
                    // Written as typed, so Apply, which takes no focus, always has the latest title.
                    TextField("Title", text: binding(row.id, \.title, default: row.track.title)).labelsHidden()
                        .disabled(!isPlayback(row.id))
                }
                .width(min: 130, ideal: 190)
                TableColumn("Tag") { (row: Row) in
                    tagPicker(row.id, tags: tags).disabled(!isPlayback(row.id))
                }
                .width(min: 110, ideal: 120)
                if !upcoming.isEmpty {
                    TableColumn("Service Item") { (row: Row) in
                        serviceItemPicker(row.id, upcoming: upcoming).disabled(!isPlayback(row.id))
                    }
                    .width(min: 110, ideal: 140)
                }
                TableColumn("File") { (row: Row) in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.filename).lineLimit(1).truncationMode(.middle)
                        Text("\(row.folder) · \(TimeText.plain(row.track.durationSec))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .help(row.path)
                }
                .width(min: 150, ideal: 220)
                TableColumn("Why") { (row: Row) in
                    reason(row.item.suggestion)
                }
                .width(min: 120, ideal: 200)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                bulkActions(ids, tags: tags)
            }
            footer(all)
        }
        .padding(20)
        .frame(minWidth: 900, idealWidth: 1080, minHeight: 440, idealHeight: 640)
        .onAppear { syncAnswers(all, upcoming: upcoming) }
        .onChange(of: model.inbox.ready.map(\.trackID)) { syncAnswers(allRows(), upcoming: model.upcomingItemsForPicker) }
    }

    private func header(_ all: [Row], tags: [String]) -> some View {
        let notPlaybacks = all.filter { !isPlayback($0.id) }.count
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("New Files").font(.title2.weight(.semibold))
                Text("\(all.count) \(all.count == 1 ? "file" : "files"): \(all.count - notPlaybacks) playbacks, \(notPlaybacks) not")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Show", selection: $showing) {
                Text("All").tag(Showing.all)
                Text("Playbacks").tag(Showing.playbacks)
                Text("Not Playbacks").tag(Showing.notPlaybacks)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Menu("Selected") { bulkActions(selection, tags: tags) }
                .disabled(selection.isEmpty)
                .fixedSize()
                .help("Change every selected row. Shift-click or Command-click to select several, or press Command-A for all.")
        }
    }

    @ViewBuilder
    private func footer(_ all: [Row]) -> some View {
        let waiting = model.inbox.awaitingSuggestion.count
        HStack {
            if waiting > 0 {
                ProgressView().controlSize(.small)
                Text(model.settings.llmEnabled ? "Claude is sorting \(waiting) more" : "Sorting \(waiting) more")
                    .foregroundStyle(.secondary)
            }
            Toggle("Copy playbacks into ~/Music/Cantor", isOn: Binding(
                get: { model.settings.copyPlaybacksToCantor },
                set: { model.setCopyPlaybacksToCantor($0) }
            ))
            .help("Each playback is copied, downloading from Drive first if needed, so it plays even if the original moves or is deleted. Originals stay where they are. Copies run one at a time after Apply.")
            Spacer()
            // Esc keeps the answers, since they live in the model.
            Button("Later") { model.snoozeNewFiles() }
                .keyboardShortcut(.cancelAction)
                .help("Close and keep these files, and your changes, waiting under New Files")
            // No Return shortcut: Return in a title field must never file hundreds of rows.
            Button("Apply to \(all.count) \(all.count == 1 ? "File" : "Files")") {
                model.applyNewFiles(all.compactMap { model.newFileAnswers[$0.id] })
                selection = []
            }
            .buttonStyle(.borderedProminent)
            .disabled(all.isEmpty)
            .help("File the playbacks with their titles and tags, and move the rest to Excluded")
        }
    }

    @ViewBuilder
    private func bulkActions(_ ids: Set<UUID>, tags: [String]) -> some View {
        Button("Playback") { set(ids) { $0.isPlayback = true } }
        Button("Not a Playback") { set(ids) { $0.isPlayback = false } }
        Menu("Tag") {
            Button("Uncategorized") { set(ids) { $0.category = "" } }
            Divider()
            ForEach(tags, id: \.self) { tag in
                Button(PlaybackCategory.display(tag)) { set(ids) { $0.category = tag } }
            }
        }
    }

    private func tagPicker(_ id: UUID, tags: [String]) -> some View {
        let current = model.newFileAnswers[id]?.category ?? ""
        // Claude may suggest a tag not on the list yet. Applying adds it.
        let options = tags + (current.isEmpty || tags.contains(current) ? [] : [current])
        return Picker("Tag", selection: binding(id, \.category, default: "")) {
            Text("Uncategorized").tag("")
            ForEach(options, id: \.self) { Text(PlaybackCategory.display($0)).tag($0) }
        }
        .labelsHidden()
    }

    private func serviceItemPicker(_ id: UUID, upcoming: [UpcomingItem]) -> some View {
        Picker("Service Item", selection: binding(id, \.serviceItem, default: nil)) {
            Text("None").tag(ServiceItemRef?.none)
            ForEach(upcoming, id: \.ref) { item in
                Text("\(item.service) · \(item.title)").tag(ServiceItemRef?.some(item.ref))
            }
        }
        .labelsHidden()
    }

    @ViewBuilder
    private func reason(_ suggestion: FileSuggestion?) -> some View {
        if let suggestion {
            let text = suggestion.byClaude ? "\(Int(suggestion.confidence * 100))% · \(suggestion.reason)" : suggestion.reason
            Label(text, systemImage: suggestion.byClaude ? "sparkle" : "text.magnifyingglass")
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(suggestion.byClaude ? text : [suggestion.reason, suggestion.note ?? ""].joined(separator: ". "))
        }
    }

    private func binding<Value>(_ id: UUID, _ path: WritableKeyPath<NewFileAnswer, Value>, default value: Value) -> Binding<Value> {
        Binding(
            get: { model.newFileAnswers[id]?[keyPath: path] ?? value },
            set: { model.newFileAnswers[id]?[keyPath: path] = $0 }
        )
    }

    private func set(_ ids: Set<UUID>, _ change: (inout NewFileAnswer) -> Void) {
        for id in ids where model.newFileAnswers[id] != nil { change(&model.newFileAnswers[id]!) }
    }

    /// Rows that arrive start from their suggestion; answers already there stay. A title the
    /// operator set, one that is not just the file's name, is kept over Claude's.
    private func syncAnswers(_ rows: [Row], upcoming: [UpcomingItem]) {
        let ids = Set(rows.map(\.id))
        selection.formIntersection(ids)
        let waiting = Set(model.inbox.items.map(\.trackID))
        model.newFileAnswers = model.newFileAnswers.filter { waiting.contains($0.key) }
        let offered = Set(upcoming.map(\.ref))
        for row in rows where model.newFileAnswers[row.id] == nil {
            let named = row.track.files.contains { TitleNormalizer.displayTitle(filename: $0.filename) == row.track.title }
            model.newFileAnswers[row.id] = NewFileAnswer(
                item: row.item, currentTitle: row.track.title, titleWasSet: !named,
                openItem: { offered.contains($0) && model.serviceCue($0)?.trackID == nil }
            )
        }
    }
}
