import CantorCore
import SwiftUI

/// Adds, renames and deletes tags. A rename or delete reaches every track that has the tag.
struct TagEditor: View {
    @AppEnvironment private var model
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var deleting: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tags").font(.title2.weight(.semibold))
            Text("Click a name to rename it. Renaming or deleting a tag changes every track that has it, and renaming onto another tag merges the two.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(model.tagNames, id: \.self) { tag in
                    TagRow(tag: tag, count: count(tag)) {
                        if count(tag) > 0 { deleting = tag } else { model.deleteTag(tag) }
                    }
                }
            }
            .frame(minHeight: 280)
            HStack {
                TextField("New tag", text: $newName).onSubmit(add)
                Button("Add", action: add).disabled(FileClassifier.cleanCategory(newName).isEmpty)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .disabled(model.show.showMode)
        .alert(
            "Delete “\(PlaybackCategory.display(deleting ?? ""))”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { tag in
            Button("Delete", role: .destructive) { model.deleteTag(tag) }
            Button("Cancel", role: .cancel) {}
        } message: { tag in
            let count = count(tag)
            Text("It comes off \(count == 1 ? "1 track" : "\(count) tracks"). The tracks stay in the library.")
        }
    }

    private func count(_ tag: String) -> Int {
        model.library.tracks.count { $0.tags.contains(tag) }
    }

    private func add() {
        guard model.addTag(newName) != nil else { return }
        newName = ""
    }
}

private struct TagRow: View {
    @AppEnvironment private var model
    let tag: String
    let count: Int
    let delete: () -> Void
    @State private var name = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack {
            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .focused($editing)
                .onSubmit(rename)
            Spacer()
            Text(count == 1 ? "1 track" : "\(count) tracks").foregroundStyle(.secondary)
            Button(action: delete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete this tag")
        }
        .onAppear { name = PlaybackCategory.display(tag) }
        .onChange(of: tag) { name = PlaybackCategory.display(tag) }
        // Clicking away renames too, so a typed name is never lost.
        .onChange(of: editing) { if !editing { rename() } }
    }

    private func rename() {
        let new = FileClassifier.cleanCategory(name)
        if new.isEmpty || new == tag {
            name = PlaybackCategory.display(tag)
        } else {
            model.renameTag(tag, to: new)
        }
    }
}

/// Adds a tag to every track, or removes it when they all have it, plus New Tag… and Edit Tags….
struct TagMenu: View {
    @AppEnvironment private var model
    let ids: Set<UUID>

    var body: some View {
        let tracks = ids.compactMap { model.library.track(id: $0) }
        Menu {
            ForEach(model.tagNames, id: \.self) { tag in
                let all = !tracks.isEmpty && tracks.allSatisfy { $0.tags.contains(tag) }
                Button {
                    model.toggleTag(tag, on: ids)
                } label: {
                    if all { Label(PlaybackCategory.display(tag), systemImage: "checkmark") } else { Text(PlaybackCategory.display(tag)) }
                }
            }
            Divider()
            Button("New Tag…") { model.newTagTrackIDs = ids }
            Button("Edit Tags…") { model.showingTagEditor = true }
        } label: {
            Label("Tag", systemImage: "tag")
        }
        .disabled(tracks.isEmpty || model.show.showMode)
        .help("Add a tag to the selected tracks, or remove it when they all have it")
    }
}
