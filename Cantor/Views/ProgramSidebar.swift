import CantorCore
import SwiftUI

/// The sidebar in Show Mode: the loaded service's whole program, headers and all, so the operator
/// can see where the service is. Rows have no action, like the cue list, and nothing here edits.
struct ProgramSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let show = model.show
        // The cue the show is on: the one engaged, or else the one GO comes to next.
        let current = show.activeCue?.id ?? show.pointedCue?.id
        VStack(alignment: .leading, spacing: 0) {
            Text(model.loadedPlan.map { $0.dates.isEmpty ? $0.title : $0.dates } ?? "Program")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 6)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.loadedPlan?.orderedCues ?? []) { cue in
                            ProgramRow(cue: cue, isCurrent: cue.id == current, state: show.state)
                                .id(cue.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
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
    }
}

private struct ProgramRow: View {
    let cue: ServiceCue
    let isCurrent: Bool
    let state: ShowState

    var body: some View {
        if cue.itemType == "header" {
            Text(cue.title)
                .font(.system(size: 11, weight: .bold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(Theme.cue)
                .lineLimit(2)
                .padding(.horizontal, 8)
                .padding(.top, 14)
                .padding(.bottom, 4)
        } else {
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
                        .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                        .lineLimit(2)
                    let detail = [cue.notes.components(separatedBy: "\n").first ?? "", cue.arrangement].filter { !$0.isEmpty }
                    if !detail.isEmpty {
                        Text(detail.joined(separator: " · "))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(isCurrent ? tint.opacity(0.18) : .clear))
            .help(cue.notes)
        }
    }
}
