import CantorCore
import SwiftUI

/// The sidebar in Show Mode: the loaded service's whole program, each header a section, so the
/// operator can see where the service is. A system sidebar list like the one it replaces, but rows
/// are not selected: clicking one points the show at it, like clicking the cue list, and nothing
/// here edits or plays.
struct ProgramSidebar: View {
    @AppEnvironment private var model

    var body: some View {
        let show = model.show
        // The cue the show is on: the one engaged, or else the one GO comes to next.
        let current = show.activeCue?.id ?? show.pointedCue?.id
        ScrollViewReader { proxy in
            List {
                if let plan = model.loadedPlan {
                    ForEach(Self.sections(plan)) { section in
                        Section {
                            ForEach(section.items) { cue in
                                ProgramRow(cue: cue, isCurrent: cue.id == current, state: show.state)
                                    .id(cue.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if let index = show.cues.firstIndex(where: { $0.id == cue.id }) { show.point(at: index) }
                                    }
                            }
                        } header: {
                            ProgramHeader(title: section.title(plan), isHeader: section.isHeader)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
            .onChange(of: current) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
        .overlay {
            if model.loadedPlan == nil {
                ContentUnavailableView("No Service Loaded", systemImage: "list.bullet.rectangle")
            }
        }
    }

    private struct ProgramSection: Identifiable {
        var id: String
        var header: ServiceCue?
        var items: [ServiceCue]

        var isHeader: Bool { header != nil }

        /// The service's date over the items before its first header.
        func title(_ plan: ServicePlan) -> String {
            header?.title ?? (plan.dates.isEmpty ? plan.title : plan.dates)
        }
    }

    /// The items before the first header, then each header with its items.
    private static func sections(_ plan: ServicePlan) -> [ProgramSection] {
        var sections = [ProgramSection(id: "top", header: nil, items: [])]
        for cue in plan.orderedCues {
            if cue.itemType == "header" {
                sections.append(ProgramSection(id: cue.id, header: cue, items: []))
            } else {
                sections[sections.count - 1].items.append(cue)
            }
        }
        // The date heads the program even when the first item is a header.
        return sections.enumerated().filter { $0.offset == 0 || $0.element.isHeader || !$0.element.items.isEmpty }.map(\.element)
    }
}

private struct ProgramHeader: View {
    let title: String
    let isHeader: Bool

    var body: some View {
        if isHeader {
            Text(title)
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(Theme.cue)
                .lineLimit(2)
        } else {
            Text(title)
        }
    }
}

private struct ProgramRow: View {
    let cue: ServiceCue
    let isCurrent: Bool
    let state: ShowState

    var body: some View {
        let style = StateStyle(state)
        let tint = isCurrent ? (style.color ?? Color.primary) : Color.secondary
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // A matched track in the show gets a note; the one the show is on, its state's symbol.
            Image(systemName: isCurrent ? (state == .idle ? "arrowtriangle.right.fill" : style.symbol) : "music.note")
                .font(.system(size: 10))
                .foregroundStyle(tint)
                .opacity(cue.needsPlayback && cue.trackID != nil ? 1 : 0)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(cue.title)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(2)
                let detail = [cue.notes.components(separatedBy: "\n").first ?? "", cue.arrangement].filter { !$0.isEmpty }
                if !detail.isEmpty {
                    Text(detail.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        // The state's color marks the cue the show is on, as in the cue list.
        .background(RoundedRectangle(cornerRadius: 6).fill(isCurrent ? tint.opacity(0.18) : .clear))
        .help(cue.notes)
    }
}
