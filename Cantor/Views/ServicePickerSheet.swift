import CantorCore
import SwiftUI

/// Every service from six weeks back to three weeks ahead. Choosing one reads its items from
/// Planning Center and adds it to the sidebar.
struct ServicePickerSheet: View {
    @Environment(AppModel.self) private var model
    @State private var selected: String?
    @State private var serviceType = ""

    private var typeNames: [String] { Array(Set(model.pickerServices.map(\.serviceTypeName))).sorted() }

    private var shown: [PlanSummary] {
        model.pickerServices.filter { serviceType.isEmpty || $0.serviceTypeName == serviceType }
    }

    private var upcoming: [PlanSummary] {
        let today = Calendar.current.startOfDay(for: Date())
        return shown.filter { ($0.sortDate ?? .distantFuture) >= today }
    }

    private var past: [PlanSummary] {
        let today = Calendar.current.startOfDay(for: Date())
        return shown.filter { ($0.sortDate ?? .distantFuture) < today }.reversed()
    }

    private var reading: PlanSummary? { model.pickerServices.first { $0.id == model.readingServiceID } }
    private var choice: PlanSummary? { model.pickerServices.first { $0.id == selected } }
    private var viaClaude: Bool { model.settings.planningCenterSource == .connector }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 520, height: 560)
        .onAppear {
            // Read once a day on opening. Refresh reads again.
            let listedToday = model.pickerListedAt.map { Calendar.current.isDateInToday($0) } ?? false
            if !listedToday { model.listPickerServices() }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Choose a Service").font(.title3.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if typeNames.count > 1 {
                Picker("Service Type", selection: $serviceType) {
                    Text("All Types").tag("")
                    ForEach(typeNames, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Button {
                model.listPickerServices()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .disabled(model.isListingServices || model.readingServiceID != nil)
            .help("Read the list from Planning Center again")
        }
        .padding(16)
    }

    private var subtitle: String {
        let range = "\(PlanSummary.weeksBack) weeks back to \(PlanSummary.weeksAhead) weeks ahead"
        guard let listed = model.pickerListedAt else { return range }
        return "\(range). Listed \(listed.formatted(date: .omitted, time: .shortened))."
    }

    @ViewBuilder
    private var list: some View {
        if model.isListingServices && model.pickerServices.isEmpty {
            ProgressView(viaClaude ? "Claude is listing services from Planning Center…" : "Listing services from Planning Center…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.pickerServices.isEmpty {
            ContentUnavailableView(
                "No Services", systemImage: "calendar",
                description: Text(model.pickerMessage == nil ? "Planning Center has no services in this window." : "The list couldn't be read.")
            )
        } else {
            List(selection: $selected) {
                if !upcoming.isEmpty {
                    Section("Upcoming") { ForEach(upcoming) { row($0) } }
                }
                if !past.isEmpty {
                    Section("Past") { ForEach(past) { row($0) } }
                }
            }
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                if let id = ids.first, let summary = model.pickerServices.first(where: { $0.id == id }) { model.pickService(summary) }
            }
            .disabled(model.readingServiceID != nil)
        }
    }

    private func row(_ summary: PlanSummary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.dates.isEmpty ? summary.title : summary.dates).lineLimit(1)
                Text(detail(summary)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if model.loadedPlanID == summary.id {
                Text("Loaded").font(.caption).foregroundStyle(Theme.live)
            } else if model.plans.contains(where: { $0.id == summary.id }) {
                Text("In sidebar").font(.caption).foregroundStyle(.secondary)
            }
            if model.readingServiceID == summary.id { ProgressView().controlSize(.small) }
        }
        .padding(.vertical, 2)
        .tag(summary.id)
    }

    private func detail(_ summary: PlanSummary) -> String {
        var parts = [summary.serviceTypeName]
        if !summary.title.isEmpty, !summary.dates.isEmpty { parts.append(summary.title) }
        if !summary.serviceTimes.isEmpty {
            parts.append(summary.serviceTimes.map { $0.formatted(date: .omitted, time: .shortened) }.joined(separator: ", "))
        }
        if let count = summary.itemsCount { parts.append(count == 0 ? "No items yet" : "\(count) \(count == 1 ? "item" : "items")") }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        HStack {
            if let reading {
                ProgressView().controlSize(.small)
                Text(viaClaude ? "Claude is reading \(name(reading))…" : "Reading \(name(reading))…")
                    .foregroundStyle(.secondary).lineLimit(1)
            } else if model.isListingServices, !model.pickerServices.isEmpty {
                ProgressView().controlSize(.small)
                Text("Refreshing the list…").foregroundStyle(.secondary)
            } else if let message = model.pickerMessage {
                Text(message).foregroundStyle(Theme.armed).lineLimit(3)
            }
            Spacer()
            Button(model.readingServiceID == nil ? "Cancel" : "Close") { model.showingServicePicker = false }
                .keyboardShortcut(.cancelAction)
                .help(model.readingServiceID == nil ? "" : "The service keeps reading and appears in the sidebar when done")
            Button("Read Service") {
                if let choice { model.pickService(choice) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(choice == nil || model.readingServiceID != nil)
        }
        .padding(16)
    }

    private func name(_ summary: PlanSummary) -> String { summary.dates.isEmpty ? summary.title : summary.dates }
}
