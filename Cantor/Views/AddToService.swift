import CantorCore
import SwiftUI

/// A library track dragged as text, marked so stray text dropped from another app is ignored.
enum TrackDrag {
    private static let prefix = "cantator-track:"

    static func payload(_ id: UUID) -> String { prefix + id.uuidString }

    static func trackIDs(_ items: [String]) -> [UUID] {
        items.compactMap { item in
            guard item.hasPrefix(prefix) else { return nil }
            return UUID(uuidString: String(item.dropFirst(prefix.count)))
        }
    }
}

/// Add to Service, then a service from the sidebar, then where in it. Items are grouped under
/// their headers, so a spot reads as it does in Planning Center.
struct AddToServiceMenu: View {
    @Environment(AppModel.self) private var model
    let trackIDs: [UUID]

    var body: some View {
        Menu {
            Button("New Service with \(trackIDs.count == 1 ? "This Track" : "These Tracks")…") { model.startNewService(with: trackIDs) }
            Divider()
            ForEach(model.sidebarPlans) { plan in
                Menu(Self.name(plan)) {
                    Button("At the Start") { add(plan, .start) }
                    Button("At the End") { add(plan, .end) }
                    ForEach(Self.sections(plan), id: \.id) { section in
                        Section(section.title) {
                            if let header = section.header {
                                Button("At the Start of \(header.title)") { add(plan, .after(header.id)) }
                            }
                            ForEach(section.items) { cue in
                                Button("After \(cue.title)") { add(plan, .after(cue.id)) }
                            }
                        }
                    }
                }
            }
        } label: {
            Label("Add to Service", systemImage: "text.badge.plus")
        }
        .disabled(trackIDs.isEmpty || model.show.showMode)
        .help(model.show.showMode ? "Locked in Show Mode" : "Add to a service as an item of its own, already matched")
    }

    private func add(_ plan: ServicePlan, _ point: ServicePlan.InsertPoint) {
        model.addTracks(trackIDs, to: plan.id, at: point)
    }

    static func name(_ plan: ServicePlan) -> String {
        "\(plan.dates.isEmpty ? plan.title : plan.dates) · \(plan.isManual ? plan.title : plan.serviceTypeName)"
    }

    private struct CueSection {
        var id: String
        var title: String
        var header: ServiceCue?
        var items: [ServiceCue]
    }

    /// The items before the first header, then each header with its items.
    private static func sections(_ plan: ServicePlan) -> [CueSection] {
        var sections = [CueSection(id: "top", title: "", header: nil, items: [])]
        for cue in plan.orderedCues {
            if cue.itemType == "header" {
                sections.append(CueSection(id: cue.id, title: cue.title, header: cue, items: []))
            } else {
                sections[sections.count - 1].items.append(cue)
            }
        }
        return sections.filter { $0.header != nil || !$0.items.isEmpty }
    }
}

/// Outlines a drop target while library tracks are dragged over it. Holding a drag there for a
/// moment calls `open`, so a service can open and take the drop on one of its items.
struct TrackDropTarget: ViewModifier {
    @Environment(AppModel.self) private var model
    let add: ([UUID]) -> Void
    var open: (() -> Void)?
    @State private var isTargeted = false
    @State private var opening: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(isTargeted ? 0.7 : 0), lineWidth: 2)
            }
            .dropDestination(for: String.self) { items, _ in
                let ids = TrackDrag.trackIDs(items)
                guard !ids.isEmpty, !model.show.showMode else { return false }
                add(ids)
                return true
            } isTargeted: { targeted in
                isTargeted = targeted
                opening?.cancel()
                guard targeted, let open else { return }
                opening = Task {
                    try? await Task.sleep(for: .milliseconds(800))
                    if !Task.isCancelled { open() }
                }
            }
    }
}

extension View {
    func acceptsTracks(open: (() -> Void)? = nil, _ add: @escaping ([UUID]) -> Void) -> some View {
        modifier(TrackDropTarget(add: add, open: open))
    }
}
