import CantorCore
import SwiftUI

/// A service cue dragged within its service, marked so it is told from a dragged library track.
enum CueDrag {
    private static let prefix = "cantator-cue:"

    static func payload(_ id: CueID) -> String { prefix + id }

    static func cueID(_ items: [String]) -> CueID? {
        items.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
}

struct ServiceView: View {
    @AppEnvironment private var model
    let planID: String
    @State private var selectedCue: CueID?
    @State private var namingTemplate = false
    @State private var templateName = ""
    @State private var confirmingDelete = false
    @State private var hoveredCue: CueID?
    @State private var swipedCue: CueID?
    @State private var rowSwipe = RowSwipe()

    private var plan: ServicePlan? { model.plans.first { $0.id == planID } }
    private var locked: Bool { model.show.showMode }

    var body: some View {
        Group {
            if let plan {
                ScrollViewReader { proxy in
                    table(plan)
                        .onAppear { takeReveal(plan, proxy) }
                        .onChange(of: model.revealedCue) { takeReveal(plan, proxy) }
                        .onChange(of: planID) { takeReveal(plan, proxy) }
                }
                    .inspector(isPresented: .constant(true)) {
                        Group {
                            if let cue = plan.cues.first(where: { $0.id == selectedCue }) {
                                CueInspector(plan: plan, cue: cue, deselect: { selectedCue = nil })
                            } else if plan.isManual {
                                ServiceInspector(plan: plan)
                            } else {
                                ContentUnavailableView("No Item Selected", systemImage: "music.note")
                            }
                        }
                        .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
                    }
                    .navigationTitle(plan.dates.isEmpty ? plan.title : plan.dates)
                    .navigationSubtitle(subtitle(plan))
                    .toolbar { toolbar(plan) }
                    .alert("Save as Template", isPresented: $namingTemplate) {
                        TextField("Name", text: $templateName)
                        Button("Save") { model.saveTemplate(planID: plan.id, name: templateName) }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("The sections and item titles are kept, never the tracks. New Service… can start from it.")
                    }
                    .alert("Delete this service?", isPresented: $confirmingDelete) {
                        Button("Delete", role: .destructive) { model.deleteService(planID: plan.id) }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("\(plan.dates) · \(plan.title) is removed from the sidebar. Your tracks stay in the library.")
                    }
            } else {
                ContentUnavailableView("Service Not Found", systemImage: "calendar.badge.exclamationmark")
            }
        }
    }

    /// Selects the item a Pre-Service Check issue points at, and scrolls it into view.
    private func takeReveal(_ plan: ServicePlan, _ proxy: ScrollViewProxy) {
        guard let cue = model.revealedCue, plan.cues.contains(where: { $0.id == cue }) else { return }
        model.revealedCue = nil
        selectedCue = cue
        DispatchQueue.main.async { proxy.scrollTo(cue, anchor: .center) }
    }

    private func subtitle(_ plan: ServicePlan) -> String {
        guard plan.isManual else { return "Synced \(plan.syncedAt.formatted(date: .abbreviated, time: .shortened))" }
        let needing = plan.playbackCues.filter { $0.itemType != "header" }
        let ready = needing.filter { cue in cue.trackID.flatMap { model.library.track(id: $0) }.map { $0.isLocal } ?? false }.count
        var parts = ["Built in Cantator", "\(ready) of \(needing.count) \(needing.count == 1 ? "track" : "tracks") ready"]
        if model.loadedPlanID == plan.id { parts.append("Loaded for the show") }
        return parts.joined(separator: " · ")
    }

    @ToolbarContentBuilder
    private func toolbar(_ plan: ServicePlan) -> some ToolbarContent {
        ToolbarItemGroup {
            if plan.isManual {
                Button {
                    selectedCue = model.addCue(planID: plan.id, header: false, after: selectedCue)
                } label: {
                    Label("Add Item", systemImage: "plus")
                }
                .disabled(locked)
                .help("Add an item after the selected one, or at the end")

                Button {
                    selectedCue = model.addCue(planID: plan.id, header: true, after: selectedCue)
                } label: {
                    Label("Add Section", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                .disabled(locked)
                .help("Add a section heading, such as Worship or Message")

                Menu {
                    Button("Duplicate for Next Week") { duplicate(plan) }
                    Button("Save as Template…") {
                        templateName = plan.title
                        namingTemplate = true
                    }
                    Divider()
                    Button("Delete Service…", role: .destructive) { confirmingDelete = true }
                        .disabled(model.loadedPlanID == plan.id)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .disabled(locked)
            } else if model.settings.usesPlanningCenter {
                Button {
                    model.refreshPlans(alsoRead: plan.id)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isSyncing || model.show.state.holdsHouseEngine)
                .help("Pull the latest from Planning Center, then turn on and match lines from their notes and your library")
            }

            if model.settings.llmEnabled {
                Button {
                    model.runAIMatch(planID: plan.id)
                } label: {
                    Label("Resolve Ambiguous", systemImage: "questionmark.diamond")
                }
                .disabled(model.isMatching)
                .help("Ask Claude to rank ambiguous matches. You still confirm each one.")
            }

            Button {
                model.loadService(planID: plan.id)
            } label: {
                Label(model.loadedPlanID == plan.id ? "Reload Service" : "Load Service", systemImage: "square.and.arrow.down.on.square")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(model.isLoadingService || model.show.showMode || model.show.state.holdsHouseEngine)
            .help("Load every confirmed cue into memory for the show")
        }
    }

    /// The same order, a week later, with no tracks. The date can be changed in the inspector.
    private func duplicate(_ plan: ServicePlan) {
        let date = Calendar.current.date(byAdding: .day, value: 7, to: plan.sortDate ?? Date()) ?? Date()
        model.createService(title: plan.title, date: date, start: .copy(plan.id))
    }

    private func table(_ plan: ServicePlan) -> some View {
        let indented = plan.cues.contains { $0.itemType == "header" }
        return Table(of: ServiceCue.self, selection: $selectedCue) {
            TableColumn("Item") { cue in
                Group {
                    if cue.itemType == "header" {
                        // A section label, as in Planning Center, so the items under it read as a group.
                        if cue.isManual {
                            TextField("Section", text: titleBinding(plan, cue))
                                .textFieldStyle(.plain)
                                .font(.system(size: 11, weight: .bold))
                                .textCase(.uppercase)
                                .foregroundStyle(Theme.cue)
                                .disabled(locked)
                                .padding(.top, 10)
                                .padding(.bottom, 2)
                        } else {
                            Text(cue.title)
                                .font(.system(size: 11, weight: .bold))
                                .textCase(.uppercase)
                                .tracking(0.6)
                                .foregroundStyle(Theme.cue)
                                .lineLimit(1)
                                .padding(.top, 10)
                                .padding(.bottom, 2)
                                .help(cue.title)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            if cue.isManual {
                                TextField("Item", text: titleBinding(plan, cue))
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13, weight: .medium))
                                    .disabled(locked)
                            } else {
                                Text(cue.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            }
                            let detail = [cue.notes.components(separatedBy: "\n").first ?? "", cue.arrangement].filter { !$0.isEmpty }
                            if !detail.isEmpty {
                                Text(detail.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                    .help(cue.notes)
                            } else if cue.isManual, !plan.isManual {
                                Text("Added in Cantator").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                        .padding(.leading, indented ? 10 : 0)
                    }
                }
                .swipeTarget(cue.id, $hoveredCue)
            }
            .width(min: 180, ideal: 240)

            TableColumn(plan.isManual ? "Track" : "Needs") { cue in
                Group {
                    if cue.itemType != "header" {
                        Toggle("", isOn: Binding(
                            get: { cue.needsPlayback },
                            set: { model.setNeeded(planID: plan.id, cue: cue, needed: $0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .disabled(locked && plan.isManual)
                        .help(plan.isManual ? "This item runs on a track" : "This item needs a playback track")
                    }
                }
                .swipeTarget(cue.id, $hoveredCue)
            }
            .width(46)

            TableColumn("File") { cue in
                Group {
                    if cue.itemType != "header", selectedCue == cue.id, !(locked && cue.isManual) {
                        // The selected item's file can be found by typing, without the inspector.
                        TrackSearchField(placeholder: cue.needsPlayback ? fileName(cue) : "Search for a track") { track in
                            if !cue.needsPlayback { model.setNeeded(planID: plan.id, cue: cue, needed: true) }
                            model.confirm(planID: plan.id, cue: cue, track: track)
                        }
                    } else if cue.needsPlayback {
                        Text(fileName(cue)).foregroundStyle(cue.trackID == nil ? .secondary : .primary).lineLimit(1)
                    }
                }
                .swipeTarget(cue.id, $hoveredCue)
            }
            .width(min: 180, ideal: 280)

            TableColumn("Match") { cue in
                Group {
                    if cue.needsPlayback, cue.trackID == nil, let top = cue.candidates.first {
                        Text(top.score.formatted(.percent.precision(.fractionLength(0))))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeTarget(cue.id, $hoveredCue)
            }
            .width(52)

            TableColumn("State") { cue in
                Group {
                    if swipedCue == cue.id, !locked {
                        Button(role: .destructive) {
                            delete(plan, cue.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.danger)
                        .controlSize(.small)
                        .help(cue.isManual ? "Remove from the service" : "Remove until the next Refresh brings it back from Planning Center")
                    } else if cue.needsPlayback {
                        if cue.isManual {
                            ManualStateChip(cue: cue)
                        } else {
                            StateChip(cue: cue)
                        }
                    }
                }
                .swipeTarget(cue.id, $hoveredCue)
            }
            .width(min: 90, ideal: 120)

            TableColumn("") { cue in
                Group {
                    if cue.isManual {
                        let ordered = plan.orderedCues
                        let index = ordered.firstIndex { $0.id == cue.id } ?? 0
                        HStack(spacing: 2) {
                            Button {
                                model.moveCue(planID: plan.id, cueID: cue.id, by: -1)
                            } label: {
                                Image(systemName: "chevron.up")
                            }
                            .disabled(locked || index == 0)
                            .help("Move up")
                            Button {
                                model.moveCue(planID: plan.id, cueID: cue.id, by: 1)
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .disabled(locked || index == ordered.count - 1)
                            .help("Move down")
                            Button {
                                delete(plan, cue.id)
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .disabled(locked)
                            .help("Remove from the service")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .opacity(selectedCue == cue.id ? 1 : 0.4)
                    }
                }
                .swipeTarget(cue.id, $hoveredCue)
            }
            .width(plan.isManual ? 70 : 0)
        } rows: {
            ForEach(plan.orderedCues) { cue in
                // Library tracks dropped on an item go right after it; a dragged item lands there too.
                TableRow(cue)
                    .draggable(CueDrag.payload(cue.id))
                    .dropDestination(for: String.self) { items in
                        if let moved = CueDrag.cueID(items) {
                            model.moveCue(planID: plan.id, cueID: moved, to: .after(cue.id))
                        } else {
                            model.addTracks(TrackDrag.trackIDs(items), to: plan.id, at: .after(cue.id))
                        }
                    }
                    .contextMenu { rowMenu(plan, cue) }
            }
        }
        .onChange(of: selectedCue) { if selectedCue != swipedCue { swipedCue = nil } }
        .onChange(of: planID) { swipedCue = nil }
        .onAppear {
            // Swiping left on a row shows its Delete button, as in Mail; swiping right puts it away.
            // Only a row still there takes a swipe, and a swipe right only when a Delete is showing,
            // so sideways scrolling goes on everywhere else.
            rowSwipe.start { left in
                guard let row = hoveredCue, model.plans.contains(where: { $0.cues.contains { $0.id == row } }) else { return false }
                if left {
                    guard !model.show.showMode else { return false }
                    swipedCue = row
                } else {
                    guard swipedCue != nil else { return false }
                    swipedCue = nil
                }
                return true
            }
        }
        .onDisappear { rowSwipe.stop() }
        // Stripes fall on headers and items alike and blur the sections, so rows are left plain.
        .alternatingRowBackgrounds(.disabled)
        .overlay {
            if plan.cues.isEmpty {
                ContentUnavailableView(
                    "No Items Yet", systemImage: "music.note.list",
                    description: Text("Use Add Item and Add Section, or drag tracks here from the Library.")
                )
                .allowsHitTesting(false)
            }
        }
        .acceptsTracks { model.addTracks($0, to: plan.id, at: .end) }
    }

    /// The row's actions for the mouse: what the inspector, the toolbar and the row's buttons do.
    @ViewBuilder
    private func rowMenu(_ plan: ServicePlan, _ cue: ServiceCue) -> some View {
        let header = cue.itemType == "header"
        let track = cue.trackID.flatMap { model.library.track(id: $0) }
        let suggested = cue.candidates.first.flatMap { model.library.track(id: $0.trackID) }
        if !header {
            if track == nil, let suggested {
                Button("\(cue.isManual ? "Use" : "Confirm") “\(suggested.primaryFilename)”") {
                    if !cue.needsPlayback { model.setNeeded(planID: plan.id, cue: cue, needed: true) }
                    model.confirm(planID: plan.id, cue: cue, track: suggested)
                }
                .disabled(locked && cue.isManual)
            }
            if let heard = track ?? suggested {
                Button(model.isAuditioning(heard) ? "Stop Preview" : "Preview on Cue Output") { model.toggleAudition(heard) }
                    .disabled(!heard.isLocal)
                if !heard.isLocal, heard.hasCloudOnlyCopy {
                    Button("Make Local") { model.makeLocal(heard) }
                        .disabled(locked)
                }
            }
            if track != nil {
                if cue.isManual {
                    Button("Change Track") { model.clearTrack(planID: plan.id, cueID: cue.id) }
                        .disabled(locked)
                } else {
                    Button("Clear Match") { model.clearMatch(planID: plan.id, cue: cue) }
                }
            }
            Toggle(plan.isManual ? "Runs on a Track" : "Needs a Track", isOn: Binding(
                get: { cue.needsPlayback },
                set: { model.setNeeded(planID: plan.id, cue: cue, needed: $0) }
            ))
            .disabled(locked && plan.isManual)
            Divider()
        }
        if plan.isManual {
            Button("Add Item Below") { selectedCue = model.addCue(planID: plan.id, header: false, after: cue.id) }
                .disabled(locked)
            Button("Add Section Below") { selectedCue = model.addCue(planID: plan.id, header: true, after: cue.id) }
                .disabled(locked)
        }
        if cue.isManual {
            let ordered = plan.orderedCues
            let index = ordered.firstIndex { $0.id == cue.id } ?? 0
            Button("Move Up") { model.moveCue(planID: plan.id, cueID: cue.id, by: -1) }
                .disabled(locked || index == 0)
            Button("Move Down") { model.moveCue(planID: plan.id, cueID: cue.id, by: 1) }
                .disabled(locked || index == ordered.count - 1)
        }
        if plan.isManual || cue.isManual { Divider() }
        Button(header ? "Delete Section" : "Delete Item", role: .destructive) { delete(plan, cue.id) }
            .disabled(locked)
    }

    /// A Planning Center item comes back with the next Refresh; one added by hand is gone.
    private func delete(_ plan: ServicePlan, _ id: CueID) {
        if selectedCue == id { selectedCue = nil }
        swipedCue = nil
        // The row's cells go without the pointer leaving them, so it is no longer under the pointer.
        if hoveredCue == id { hoveredCue = nil }
        model.removeCue(planID: plan.id, cueID: id)
    }

    private func titleBinding(_ plan: ServicePlan, _ cue: ServiceCue) -> Binding<String> {
        Binding(
            get: { plan.cues.first { $0.id == cue.id }?.title ?? cue.title },
            set: { model.renameCue(planID: plan.id, cueID: cue.id, title: $0) }
        )
    }

    private func fileName(_ cue: ServiceCue) -> String {
        if let id = cue.trackID, let track = model.library.track(id: id) { return track.primaryFilename }
        if cue.isManual { return cue.candidates.first.flatMap { model.library.track(id: $0.trackID)?.primaryFilename }.map { "Looks like \($0)" } ?? "No track" }
        return cue.candidates.first.flatMap { model.library.track(id: $0.trackID)?.primaryFilename } ?? "No match"
    }
}

/// Planning Center items: what the matcher found and what the operator did about it.
private struct StateChip: View {
    let cue: ServiceCue

    var body: some View {
        if cue.trackID != nil {
            if cue.removedInPCO {
                Label("Removed in Planning Center", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.armed)
            } else if cue.changedSinceConfirm {
                Label("Changed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.armed)
            } else if cue.autoConfirmed {
                Label("Auto-confirmed", systemImage: "checkmark.circle").foregroundStyle(Theme.live)
                    .help("Matched by Cantor. Choose another file or Clear Match to change it.")
            } else {
                Label("Confirmed", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.live)
            }
        } else {
            switch MatchBand(candidates: cue.candidates) {
            case .proposed: Label("Proposed", systemImage: "circle.dashed").foregroundStyle(Theme.live)
            case .likely: Label("Review", systemImage: "questionmark.circle").foregroundStyle(Theme.armed)
            case .none: Label("No match", systemImage: "xmark.circle").foregroundStyle(Theme.danger)
            }
        }
    }
}

/// Items added by hand: whether the track they were given is ready to play. Same colors as the show.
private struct ManualStateChip: View {
    @AppEnvironment private var model
    let cue: ServiceCue

    var body: some View {
        if let id = cue.trackID, let track = model.library.track(id: id) {
            if model.resident[id] != nil {
                Label("Loaded", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.live)
            } else if !track.isLocal {
                Label(track.hasCloudOnlyCopy ? "Not downloaded" : "File missing", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.armed)
            } else if track.needsEndPoint {
                Label("No end point", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.armed)
                    .help("Set or accept an end point in Library. It plays to the end of the file until then.")
            } else {
                Label("Ready", systemImage: "checkmark.circle").foregroundStyle(Theme.live)
            }
        } else if cue.trackID != nil {
            Label("File missing", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
        } else if !cue.candidates.isEmpty {
            Label("Suggested", systemImage: "circle.dashed").foregroundStyle(Theme.armed)
                .help("A library track shares words with this title. Choose Use in the inspector to take it.")
        } else {
            Label("No track", systemImage: "xmark.circle").foregroundStyle(Theme.danger)
        }
    }
}

/// A service built in Cantator, when no item is selected: its name and date, or pinned with no date that counts.
private struct ServiceInspector: View {
    @AppEnvironment private var model
    let plan: ServicePlan
    // Typed here first, so the field can be emptied on the way to a new name without the old one
    // snapping back. The service takes each non-blank name as it is typed.
    @State private var name = ""

    var body: some View {
        Form {
            Section("Service") {
                TextField("Name", text: $name)
                    .onAppear { name = plan.title }
                    .onChange(of: plan.id) { name = plan.title }
                    .onChange(of: name) { model.renameManualPlan(planID: plan.id, title: name) }
                Toggle("Pinned", isOn: Binding(get: { plan.pinned }, set: { model.setPinned(planID: plan.id, $0) }))
                    .help("Keeps this service at the top of the sidebar whatever its date, for practice days")
                if !plan.pinned {
                    DatePicker("Date", selection: Binding(
                        get: { plan.sortDate ?? Date() },
                        set: { model.moveManualPlan(planID: plan.id, to: $0) }
                    ))
                }
                let items = plan.cues.filter { $0.itemType != "header" }
                LabeledContent("Items", value: "\(items.count), \(items.filter(\.needsPlayback).count) on tracks")
            }
            Section {
                Text("Select an item to give it a track, or drag tracks in from the Library. Add Item and Add Section are in the toolbar.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(model.show.showMode)
    }
}

private struct CueInspector: View {
    @AppEnvironment private var model
    let plan: ServicePlan
    let cue: ServiceCue
    let deselect: () -> Void
    @State private var search = ""

    private var locked: Bool { model.show.showMode }

    var body: some View {
        if cue.itemType == "header" {
            Form {
                Section("Section") {
                    if cue.isManual {
                        TextField("Title", text: Binding(
                            get: { cue.title },
                            set: { model.renameCue(planID: plan.id, cueID: cue.id, title: $0) }
                        ))
                        .disabled(locked)
                        Button("Remove Section") {
                            deselect()
                            model.removeCue(planID: plan.id, cueID: cue.id)
                        }
                        .disabled(locked)
                    } else {
                        LabeledContent("Title", value: cue.title)
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            Form {
                Section("Item") {
                    if cue.isManual {
                        TextField("Title", text: Binding(
                            get: { cue.title },
                            set: { model.renameCue(planID: plan.id, cueID: cue.id, title: $0) }
                        ))
                        .disabled(locked)
                        TextField("Notes", text: Binding(
                            get: { cue.notes },
                            set: { model.setCueNotes(planID: plan.id, cueID: cue.id, notes: $0) }
                        ), prompt: Text("For the show, such as “starts after the prayer”"), axis: .vertical)
                        .lineLimit(1...3)
                        .disabled(locked)
                    } else {
                        LabeledContent("Title", value: cue.title)
                        if !cue.arrangement.isEmpty { LabeledContent("Arrangement", value: cue.arrangement) }
                        if let length = cue.lengthSec { LabeledContent("Length", value: TimeText.plain(length)) }
                        if !cue.notes.isEmpty { Text(cue.notes).foregroundStyle(.secondary) }
                    }
                }
                if let id = cue.trackID, let track = model.library.track(id: id) {
                    Section(cue.isManual ? "Track" : (cue.autoConfirmed ? "Auto-confirmed" : "Confirmed")) {
                        LabeledContent("File", value: track.primaryFilename)
                        LabeledContent("Length", value: TimeText.plain(track.durationSec))
                        if !track.isLocal {
                            Label(track.hasCloudOnlyCopy ? "Not downloaded. Use Make Local in Library." : "The file is missing.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(Theme.armed)
                        }
                        Button {
                            model.toggleAudition(track)
                        } label: {
                            Label(model.isAuditioning(track) ? "Stop Preview" : "Preview on Cue Output",
                                  systemImage: model.isAuditioning(track) ? "stop.fill" : "headphones")
                        }
                        .disabled(!track.isLocal)
                        if cue.isManual {
                            Button("Change Track") { model.clearTrack(planID: plan.id, cueID: cue.id) }
                                .disabled(locked)
                        } else {
                            Button("Clear Match") { model.clearMatch(planID: plan.id, cue: cue) }
                        }
                    }
                }
                if cue.trackID == nil || !cue.isManual {
                    Section(cue.isManual ? "Looks Like" : "Candidates") {
                        if cue.candidates.isEmpty {
                            Text(cue.isManual ? "No library track shares words with this title. Search below." : "No likely files. Search below.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(cue.candidates) { candidate in
                            if let track = model.library.track(id: candidate.trackID) {
                                candidateRow(candidate: candidate, track: track)
                            }
                        }
                    }
                }
                Section("Choose Another") {
                    TextField("Search library", text: $search)
                    ForEach(searchResults) { track in
                        HStack {
                            Text(track.primaryFilename).lineLimit(1)
                            Spacer()
                            Text(TimeText.plain(track.durationSec)).font(.caption).foregroundStyle(.secondary)
                            Button(cue.isManual ? "Use" : "Confirm") { model.confirm(planID: plan.id, cue: cue, track: track) }
                                .disabled(locked && cue.isManual)
                        }
                    }
                }
                if cue.isManual {
                    Section {
                        Button("Remove Item", role: .destructive) {
                            deselect()
                            model.removeCue(planID: plan.id, cueID: cue.id)
                        }
                        .disabled(locked)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private var searchResults: [Track] {
        TrackSearchField.results(search, in: model.library.playbackTracks, limit: 12)
    }

    private func candidateRow(candidate: MatchCandidate, track: Track) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(track.primaryFilename).lineLimit(2)
                Spacer()
                Text(candidate.score.formatted(.percent.precision(.fractionLength(0))))
                    .font(.system(.body, design: .monospaced))
            }
            Text(candidate.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 10) {
                Text(TimeText.plain(track.durationSec)).font(.caption).foregroundStyle(.secondary)
                if candidate.durationMismatch {
                    Label("Length differs", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.armed)
                }
                if !track.isLocal {
                    Label("Not downloaded", systemImage: "icloud").font(.caption).foregroundStyle(Theme.armed)
                }
                Spacer()
                Button {
                    model.toggleAudition(track)
                } label: {
                    Image(systemName: model.isAuditioning(track) ? "stop.fill" : "headphones")
                }
                .help(model.isAuditioning(track) ? "Stop the preview" : "Preview on the cue output")
                .hoverBrighten()
                .disabled(!track.isLocal)
                Button(cue.isManual ? "Use" : "Confirm") { model.confirm(planID: plan.id, cue: cue, track: track) }
                    .disabled(locked && cue.isManual)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A search field for the selected item's File cell. Matching playbacks are offered under it as
/// the system's text suggestions, which leave the keyboard in the field: the arrow keys move
/// through them and Return or a click takes one. Return with none showing takes the first match.
private struct TrackSearchField: View {
    @AppEnvironment private var model
    let placeholder: String
    let choose: (Track) -> Void
    @State private var search = ""
    /// The text each offered suggestion puts in the field, and its track. Choosing one is seen as
    /// the field changing to one of these.
    @State private var offered: [String: UUID] = [:]

    /// Playbacks with every typed word in the title or filename, ignoring case and accents, so
    /// "chiar vale" finds "Chiar și acolo în vale.mp3". Titles that start with the search come first.
    static func results(_ search: String, in tracks: [Track], limit: Int) -> [Track] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let words = query.split(separator: " ").map(String.init)
        guard query.count >= 2 else { return [] }
        let found = tracks.filter { track in
            words.allSatisfy { track.title.localizedStandardContains($0) || track.primaryFilename.localizedStandardContains($0) }
        }
        let leading = found.filter { $0.title.range(of: query, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil }
        let rest = found.filter { $0.title.range(of: query, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) == nil }
        return Array((leading + rest).prefix(limit))
    }

    private var results: [Track] { Self.results(search, in: model.library.playbackTracks, limit: 10) }

    /// The filename, with its folder when another offered file has the same name.
    private static func completion(_ track: Track, among shown: [Track]) -> String {
        let name = track.primaryFilename
        guard shown.contains(where: { $0.id != track.id && $0.primaryFilename == name }),
              let file = track.files.first(where: { $0.filename == name })
        else { return name }
        return "\(name) — \(file.url.deletingLastPathComponent().lastPathComponent)"
    }

    var body: some View {
        let shown = results
        TextField(placeholder, text: $search)
            .textFieldStyle(.roundedBorder)
            .textInputSuggestions {
                ForEach(shown) { track in
                    HStack {
                        Text(track.primaryFilename)
                        Spacer()
                        if !track.isLocal { Image(systemName: "icloud") }
                        Text(TimeText.plain(track.durationSec)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .textInputCompletion(Self.completion(track, among: shown))
                }
            }
            .onChange(of: search) {
                if let id = offered[search] {
                    take(id)
                } else {
                    let shown = results
                    offered = Dictionary(shown.map { (Self.completion($0, among: shown), $0.id) }, uniquingKeysWith: { a, _ in a })
                }
            }
            .onSubmit {
                if let id = offered[search] ?? results.first?.id { take(id) }
            }
            .onExitCommand { search = "" }
    }

    private func take(_ id: UUID) {
        guard let track = model.library.track(id: id) else { return }
        offered = [:]
        search = ""
        choose(track)
    }
}

private extension View {
    /// Notes which row the pointer is over, so a trackpad swipe knows its row.
    func swipeTarget(_ id: CueID, _ hovered: Binding<CueID?>) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { hovered.wrappedValue = id } else if hovered.wrappedValue == id { hovered.wrappedValue = nil }
            }
    }
}

/// A sideways two-finger swipe on the trackpad. SwiftUI's swipe actions belong to List, not Table,
/// so the scroll events are read here. Only the main window's events count, with no sheet over it.
/// A swipe is taken once it has gone far enough sideways and a row answers for it; from then its
/// events and its momentum go no further. The gesture's end always goes on, so a scroll view that
/// saw it begin also sees it finish.
@MainActor
final class RowSwipe {
    private var monitor: Any?
    private var travel = CGSize.zero
    private var taken = false
    private var momentumTaken = false

    /// `swiped` gets true for a swipe to the left, and answers whether a row took it.
    func start(_ swiped: @escaping (Bool) -> Bool) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                (self?.handle(event, swiped) ?? false) ? nil : event
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        taken = false
        momentumTaken = false
    }

    private func handle(_ event: NSEvent, _ swiped: (Bool) -> Bool) -> Bool {
        guard event.hasPreciseScrollingDeltas else { return false }
        if !event.momentumPhase.isEmpty {
            let swallow = momentumTaken
            if !event.momentumPhase.isDisjoint(with: [.ended, .cancelled]) { momentumTaken = false }
            return swallow
        }
        if event.phase.contains(.began) {
            travel = .zero
            taken = false
            momentumTaken = false
        }
        if !event.phase.isDisjoint(with: [.ended, .cancelled]) {
            momentumTaken = taken
            taken = false
            return false
        }
        guard event.phase.contains(.changed) else { return false }
        if taken { return true }
        guard let window = event.window, window === KeyRouter.shared.mainWindow, window.attachedSheet == nil else { return false }
        // Where the fingers went, whichever way the content scrolls.
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        travel.width += event.scrollingDeltaX * sign
        travel.height += event.scrollingDeltaY
        if abs(travel.width) > 40, abs(travel.width) > 2 * abs(travel.height) {
            taken = swiped(travel.width < 0)
        }
        return taken
    }
}
