import CantorCore
import SwiftUI

struct CheckView: View {
    @Environment(AppModel.self) private var model
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
                    description: Text("Add your Planning Center token in Settings and refresh.")
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

    @ViewBuilder
    private func section(_ title: String, _ severity: CheckSeverity, symbol: String, color: Color) -> some View {
        let rows = issues.filter { $0.severity == severity }
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows) { issue in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: symbol).foregroundStyle(color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.title).font(.system(size: 14, weight: .medium))
                            Text(issue.action).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}
