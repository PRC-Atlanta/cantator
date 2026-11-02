import CantorCore
import SwiftUI

/// Shown for each new file once nothing is loaded or playing. Nothing is applied until Accept.
struct NewFileSheet: View {
    @Environment(AppModel.self) private var model
    let item: NewFileItem

    @State private var title = ""
    @State private var category = ""
    @State private var serviceItem: ServiceItemRef?
    @State private var copyToCantor = false

    private var track: Track? { model.library.track(id: item.trackID) }
    private var suggestion: FileSuggestion? { item.suggestion }
    private var isManaged: Bool { track?.files.contains { $0.path.hasPrefix(ManagedFolder.path + "/") } ?? false }
    private var categories: [String] { PlaybackCategory.all(libraryTags: model.library.allTags) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let suggestion, !suggestion.isPlayback {
                Label("Claude doesn't think this is a service playback track.", systemImage: "questionmark.circle")
                    .foregroundStyle(Theme.armed)
            }
            Form {
                TextField("Title", text: $title)
                LabeledContent("Category") {
                    HStack {
                        TextField("Category", text: $category, prompt: Text("Uncategorized")).labelsHidden()
                        Menu {
                            ForEach(categories, id: \.self) { name in
                                Button(PlaybackCategory.display(name)) { category = name }
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                Picker("Service Item", selection: $serviceItem) {
                    Text("None").tag(ServiceItemRef?.none)
                    ForEach(model.upcomingItemsForPicker, id: \.ref) { upcoming in
                        Text("\(upcoming.service) · \(upcoming.title)").tag(ServiceItemRef?.some(upcoming.ref))
                    }
                }
                // An imported file is already there.
                if !isManaged {
                    Toggle("Keep a copy in ~/Music/Cantor", isOn: $copyToCantor)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            source
            HStack {
                Button("Not a Playback") { model.skipNewFile(item.trackID) }
                    .help("Leave it in the library without filing it, and stop asking")
                Spacer()
                Button("Later") { model.snoozeNewFiles() }
                    .keyboardShortcut(.cancelAction)
                Button("Accept") {
                    model.acceptNewFile(item.trackID, title: title, category: category, serviceItem: serviceItem, copyToCantor: copyToCantor)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: fill)
        .onChange(of: item) { _, _ in fill() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("New File").font(.title2.weight(.semibold))
                Spacer()
                if model.inbox.ready.count > 1 {
                    Text("\(model.inbox.ready.count) waiting").foregroundStyle(.secondary)
                }
            }
            if let track {
                Label(track.primaryFilename, systemImage: track.isLocal ? "waveform" : "icloud")
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let file = track.files.first {
                    Text((file.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(TimeText.plain(track.durationSec)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var source: some View {
        if let suggestion {
            if suggestion.byClaude {
                Label("Filed by Claude, \(Int(suggestion.confidence * 100))% sure. \(suggestion.reason)", systemImage: "sparkle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Label("\(suggestion.reason). \(suggestion.note ?? "")", systemImage: "text.magnifyingglass")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func fill() {
        title = suggestion?.title ?? track?.title ?? ""
        category = suggestion?.category ?? ""
        serviceItem = suggestion?.serviceItem.flatMap { ref in model.serviceCue(ref)?.trackID == nil ? ref : nil }
        // Downloads and Desktop get cleaned out, so a copy is the safer default there.
        copyToCantor = !isManaged && track?.files.contains { file in
            file.url.pathComponents.contains("Downloads") || file.url.pathComponents.contains("Desktop")
        } ?? false
    }
}
