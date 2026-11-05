import CantorCore
import SwiftUI

struct CheckView: View {
    @AppEnvironment private var model
    @State private var issues: [CheckIssue] = []

    private var plan: ServicePlan? { model.currentPlan }

    var body: some View {
        List {
            section("Must Fix", .blocking, symbol: "xmark.octagon.fill", color: Theme.danger)
            section("Warnings", .warning, symbol: "exclamationmark.triangle.fill", color: Theme.armed)
            section("Reminders", .ok, symbol: "info.circle", color: .secondary)
        }
        .overlay {
            if plan == nil {
                ContentUnavailableView(
                    "No Service", systemImage: "checklist",
                    description: Text(model.settings.usesPlanningCenter
                        ? "Sync Planning Center, or create a service with New Service… in the sidebar."
                        : "Create a service with New Service… in the sidebar, then come back here before it starts.")
                )
            }
        }
        .navigationTitle("Pre-Service Check")
        .navigationSubtitle(plan.map { $0.dates.isEmpty ? $0.title : $0.dates } ?? "")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.rescan()
                    refresh()
                } label: {
                    Label("Run Check", systemImage: "arrow.clockwise")
                }
                if let plan, plan.cues.contains(where: { cue in
                    cue.trackID.flatMap { model.library.track(id: $0) }.map { !$0.isLocal || $0.bestFile()?.path.hasPrefix(ManagedFolder.path + "/") == false } ?? false
                }) {
                    Button("Make All Local") {
                        plan.playbackCues.compactMap { $0.trackID.flatMap { model.library.track(id: $0) } }.forEach(model.makeLocal)
                    }
                    .help("Copy every matched file to ~/Music/Cantor")
                }
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: model.devices) { refresh() }
        .onChange(of: model.resident.count) { refresh() }
        .onChange(of: model.library) { refresh() }
        .onChange(of: model.settings.routing) { refresh() }
        .onChange(of: model.plans) { refresh() }
        .onChange(of: model.loadedPlanID) { refresh() }
    }

    private func refresh() { issues = model.checkResults() }

    private func label(_ issue: CheckIssue, symbol: String, color: Color, opens: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title).font(.system(size: 14, weight: .medium))
                Text(issue.action).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if opens {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// Where a click takes the operator to fix the issue: the item in Service, or Settings for an
    /// output. Nil when there is nowhere to go, as for the Do Not Disturb reminder.
    private func destination(_ issue: CheckIssue) -> (() -> Void)? {
        if let cue = issue.cueID, let plan {
            return { model.reveal(cue: cue, planID: plan.id) }
        }
        switch issue.kind {
        case .noHouseOutput, .houseOutputMissing, .housePairMissing, .noCueOutput, .cueOutputMissing, .cuePairMissing, .sameOutput:
            return { model.openSettings(.outputs) }
        case .noCues:
            return plan.map { plan in { model.selection = .plan(plan.id) } }
        default:
            return nil
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ severity: CheckSeverity, symbol: String, color: Color) -> some View {
        let rows = issues.filter { $0.severity == severity }
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows) { issue in
                    if let open = destination(issue) {
                        Button(action: open) { label(issue, symbol: symbol, color: color, opens: true) }
                            .buttonStyle(.plain)
                    } else {
                        label(issue, symbol: symbol, color: color, opens: false)
                    }
                }
            }
        }
    }
}
