import CantorCore
import SwiftUI

/// Every file waiting under New Files, in one list, with Claude's suggestion filled in. Rows can be
/// changed one at a time or several at once, and nothing is applied until Apply.
struct NewFilesSheet: View {
    @AppEnvironment private var model
    @State private var answers: [UUID: NewFileAnswer] = [:]
    @State private var selection: Set<UUID> = []
    @State private var showing = Showing.all

    enum Showing: Hashable {
        case all, playbacks, notPlaybacks
    }

    private struct Row: Identifiable {
        let item: NewFileItem
        let track: Track
        var id: UUID { item.trackID }
        var file: TrackFile? { track.bestFile() ?? track.files.first }
        var folder: String { file.map { $0.url.deletingLastPathComponent().pathComponents.suffix(2).joined(separator: "/") } ?? "" }
    }

    /// Grouped by folder, so a song's stems, parts and playback sit together.
    private var allRows: [Row] {
        model.inbox.ready
            .compactMap { item in model.library.track(id: item.trackID).map { Row(item: item, track: $0) } }
            .sorted { ($0.folder, $0.track.primaryFilename) < ($1.folder, $1.track.primaryFilename) }
    }

    private var rows: [Row] {
        switch showing {
        case .all: allRows
        case .playbacks: allRows.filter { answers[$0.id]?.isPlayback ?? true }
        case .notPlaybacks: allRows.filter { !(answers[$0.id]?.isPlayback ?? true) }
        }
    }

    var body: some View {
        let all = allRows
        VStack(alignment: .leading, spacing: 12) {
            header(all)
            Table(rows, selection: $selection) {
                TableColumn("Playback") { (row: Row) in
                    Toggle("Playback", isOn: binding(row.id, \.isPlayback, default: true)).labelsHidden().toggleStyle(.checkbox)
                }
                .width(56)
                TableColumn("Title") { (row: Row) in
                    TextField("Title", text: binding(row.id, \.title, default: row.track.title)).labelsHidden()
                        .disabled(!(answers[row.id]?.isPlayback ?? true))
                }
                .width(min: 130, ideal: 190)
                TableColumn("Tag") { (row: Row) in
                    tagPicker(row.id).disabled(!(answers[row.id]?.isPlayback ?? true))
                }
                .width(min: 110, ideal: 120)
                if !model.upcomingItemsForPicker.isEmpty {
                    TableColumn("Service Item") { (row: Row) in
                        serviceItemPicker(row.id).disabled(!(answers[row.id]?.isPlayback ?? true))
                    }
                    .width(min: 110, ideal: 140)
                }
                TableColumn("File") { (row: Row) in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.track.primaryFilename).lineLimit(1).truncationMode(.middle)
                        Text("\(row.folder) · \(TimeText.plain(row.track.durationSec))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .help(row.file?.path ?? "")
                }
                .width(min: 150, ideal: 220)
                TableColumn("Why") { (row: Row) in
                    reason(row.item.suggestion)
                }
                .width(min: 120, ideal: 200)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                bulkActions(ids)
            }
            footer(all)
        }
        .padding(20)
        .frame(minWidth: 900, idealWidth: 1080, minHeight: 440, idealHeight: 640)
        .onAppear { syncAnswers() }
        .onChange(of: model.inbox.ready.map(\.trackID)) { syncAnswers() }
    }

    private func header(_ all: [Row]) -> some View {
        let notPlaybacks = all.filter { !(answers[$0.id]?.isPlayback ?? true) }.count
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
            Menu("Selected") { bulkActions(selection) }
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
            Button("Later") { model.snoozeNewFiles() }
                .keyboardShortcut(.cancelAction)
                .help("Close and keep these files waiting under New Files")
            Button("Apply to \(all.count) \(all.count == 1 ? "File" : "Files")") {
                model.applyNewFiles(all.compactMap { answers[$0.id] })
                selection = []
            }
            .keyboardShortcut(.defaultAction)
            .disabled(all.isEmpty)
            .help("File the playbacks with their titles and tags, and move the rest to Excluded")
        }
    }

    @ViewBuilder
    private func bulkActions(_ ids: Set<UUID>) -> some View {
        Button("Playback") { set(ids) { $0.isPlayback = true } }
        Button("Not a Playback") { set(ids) { $0.isPlayback = false } }
        Menu("Tag") {
            Button("Uncategorized") { set(ids) { $0.category = "" } }
            Divider()
            ForEach(model.tagNames, id: \.self) { tag in
                Button(PlaybackCategory.display(tag)) { set(ids) { $0.category = tag } }
            }
        }
    }

    private func tagPicker(_ id: UUID) -> some View {
        let current = answers[id]?.category ?? ""
        // Claude may suggest a tag not on the list yet. Applying adds it.
        let options = model.tagNames + (current.isEmpty || model.tagNames.contains(current) ? [] : [current])
        return Picker("Tag", selection: binding(id, \.category, default: "")) {
            Text("Uncategorized").tag("")
            ForEach(options, id: \.self) { Text(PlaybackCategory.display($0)).tag($0) }
        }
        .labelsHidden()
    }

    private func serviceItemPicker(_ id: UUID) -> some View {
        Picker("Service Item", selection: binding(id, \.serviceItem, default: nil)) {
            Text("None").tag(ServiceItemRef?.none)
            ForEach(model.upcomingItemsForPicker, id: \.ref) { upcoming in
                Text("\(upcoming.service) · \(upcoming.title)").tag(ServiceItemRef?.some(upcoming.ref))
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
            get: { answers[id]?[keyPath: path] ?? value },
            set: { answers[id]?[keyPath: path] = $0 }
        )
    }

    private func set(_ ids: Set<UUID>, _ change: (inout NewFileAnswer) -> Void) {
        for id in ids where answers[id] != nil { change(&answers[id]!) }
    }

    /// Rows that arrive while the list is open start from their suggestion. Answers already changed stay.
    private func syncAnswers() {
        let ready = model.inbox.ready
        let ids = Set(ready.map(\.trackID))
        answers = answers.filter { ids.contains($0.key) }
        selection.formIntersection(ids)
        for item in ready where answers[item.trackID] == nil {
            answers[item.trackID] = NewFileAnswer(
                item: item, currentTitle: model.library.track(id: item.trackID)?.title ?? "",
                openItem: { model.serviceCue($0)?.trackID == nil }
            )
        }
    }
}
