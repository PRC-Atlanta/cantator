import CantorCore
import SwiftUI

struct ServiceView: View {
    @Environment(AppModel.self) private var model
    let planID: String
    @State private var selectedCue: CueID?

    private var plan: ServicePlan? { model.plans.first { $0.id == planID } }

    var body: some View {
        Group {
            if let plan {
                table(plan)
                    .inspector(isPresented: .constant(true)) {
                        CueInspector(plan: plan, cue: plan.cues.first { $0.id == selectedCue })
                            .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
                    }
                    .navigationTitle(plan.dates.isEmpty ? plan.title : plan.dates)
                    .navigationSubtitle("Synced \(plan.syncedAt.formatted(date: .abbreviated, time: .shortened))")
                    .toolbar { toolbar(plan) }
            } else {
                ContentUnavailableView("Service Not Found", systemImage: "calendar.badge.exclamationmark")
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ plan: ServicePlan) -> some ToolbarContent {
        ToolbarItemGroup {
            Button {
                model.refreshPlans(alsoRead: plan.id)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isSyncing)
            .help("Pull the latest from Planning Center, then turn on and match lines from their notes and your library")

            Button {
                model.runAIMatch(planID: plan.id)
            } label: {
                Label("Resolve Ambiguous", systemImage: "questionmark.diamond")
            }
            .disabled(model.isMatching)
            .help("Ask Claude to rank ambiguous matches. You still confirm each one.")

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

    private func table(_ plan: ServicePlan) -> some View {
        Table(of: ServiceCue.self, selection: $selectedCue) {
            TableColumn("Item") { cue in
                if cue.itemType == "header" {
                    // A section label, as in Planning Center, so the items under it read as a group.
                    Text(cue.title)
                        .font(.system(size: 11, weight: .bold))
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .foregroundStyle(Theme.cue)
                        .lineLimit(1)
                        .padding(.top, 10)
                        .padding(.bottom, 2)
                        .help(cue.title)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cue.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        let detail = cue.isManual
                            ? ["Added in Cantator"]
                            : [cue.notes.components(separatedBy: "\n").first ?? "", cue.arrangement].filter { !$0.isEmpty }
                        if !detail.isEmpty {
                            Text(detail.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                .help(cue.notes)
                        }
                    }
                    .padding(.vertical, 3)
                    .padding(.leading, plan.cues.contains { $0.itemType == "header" } ? 10 : 0)
                }
            }
            .width(min: 180, ideal: 240)

            TableColumn("Needs") { cue in
                if cue.itemType != "header" {
                    Toggle("", isOn: Binding(
                        get: { cue.needsPlayback },
                        set: { model.setNeeded(planID: plan.id, cue: cue, needed: $0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                }
            }
            .width(46)

            TableColumn("File") { cue in
                if cue.needsPlayback {
                    Text(fileName(cue)).foregroundStyle(cue.trackID == nil ? .secondary : .primary).lineLimit(1)
                }
            }
            .width(min: 180, ideal: 280)

            TableColumn("Match") { cue in
                if cue.needsPlayback, cue.trackID == nil, let top = cue.candidates.first {
                    Text(top.score.formatted(.percent.precision(.fractionLength(0))))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .width(52)

            TableColumn("State") { cue in
                if cue.needsPlayback { StateChip(cue: cue) }
            }
            .width(min: 90, ideal: 110)
        } rows: {
            ForEach(plan.orderedCues) { cue in
                // Library tracks dropped on an item go right after it.
                TableRow(cue).dropDestination(for: String.self) { items in
                    model.addTracks(TrackDrag.trackIDs(items), to: plan.id, at: .after(cue.id))
                }
            }
        }
        // Stripes fall on headers and items alike and blur the sections, so rows are left plain.
        .alternatingRowBackgrounds(.disabled)
    }

    private func fileName(_ cue: ServiceCue) -> String {
        let id = cue.trackID ?? cue.candidates.first?.trackID
        return id.flatMap { model.library.track(id: $0)?.primaryFilename } ?? "No match"
    }
}

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

private struct CueInspector: View {
    @Environment(AppModel.self) private var model
    let plan: ServicePlan
    let cue: ServiceCue?
    @State private var search = ""

    var body: some View {
        if let cue, cue.itemType != "header" {
            Form {
                Section("Item") {
                    LabeledContent("Title", value: cue.title)
                    if !cue.arrangement.isEmpty { LabeledContent("Arrangement", value: cue.arrangement) }
                    if let length = cue.lengthSec { LabeledContent("Length", value: TimeText.plain(length)) }
                    if !cue.notes.isEmpty { Text(cue.notes).foregroundStyle(.secondary) }
                }
                if let id = cue.trackID, let track = model.library.track(id: id) {
                    Section(cue.autoConfirmed ? "Auto-confirmed" : "Confirmed") {
                        LabeledContent("File", value: track.primaryFilename)
                        Button {
                            model.toggleAudition(track)
                        } label: {
                            Label(model.isAuditioning(track) ? "Stop Preview" : "Preview on Cue Output",
                                  systemImage: model.isAuditioning(track) ? "stop.fill" : "headphones")
                        }
                        if cue.isManual {
                            Button("Remove from Service") { model.removeManualCue(planID: plan.id, cueID: cue.id) }
                                .disabled(model.show.showMode)
                        } else {
                            Button("Clear Match") { model.clearMatch(planID: plan.id, cue: cue) }
                        }
                    }
                }
                Section("Candidates") {
                    if cue.candidates.isEmpty {
                        Text("No likely files. Search below.").foregroundStyle(.secondary)
                    }
                    ForEach(cue.candidates) { candidate in
                        if let track = model.library.track(id: candidate.trackID) {
                            candidateRow(cue: cue, candidate: candidate, track: track)
                        }
                    }
                }
                Section("Choose Another") {
                    TextField("Search library", text: $search)
                    ForEach(searchResults) { track in
                        HStack {
                            Text(track.primaryFilename).lineLimit(1)
                            Spacer()
                            Button("Confirm") { model.confirm(planID: plan.id, cue: cue, track: track) }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("No Item Selected", systemImage: "music.note")
        }
    }

    private var searchResults: [Track] {
        let query = search.lowercased()
        guard query.count >= 2 else { return [] }
        return Array(model.library.playbackTracks.filter {
            $0.title.lowercased().contains(query) || $0.primaryFilename.lowercased().contains(query)
        }.prefix(12))
    }

    private func candidateRow(cue: ServiceCue, candidate: MatchCandidate, track: Track) -> some View {
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
                Button("Confirm") { model.confirm(planID: plan.id, cue: cue, track: track) }
            }
        }
        .padding(.vertical, 2)
    }
}
