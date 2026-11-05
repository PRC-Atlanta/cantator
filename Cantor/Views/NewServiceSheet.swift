import CantorCore
import SwiftUI

/// New Service…: a name, a date and time, and what to start from. A copy or a template brings the
/// sections and item titles, never the tracks.
struct NewServiceSheet: View {
    @AppEnvironment private var model
    @State private var title = "Sunday Morning"
    @State private var date = NewServiceSheet.nextSunday()
    @State private var start = AppModel.ServiceStart.blank

    private var copySources: [ServicePlan] { model.sidebarPlans.reversed() }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Service").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $title, prompt: Text("Sunday Morning"))
                DatePicker("Date and time", selection: $date)
                Picker("Start from", selection: $start) {
                    Text("Blank").tag(AppModel.ServiceStart.blank)
                    if !copySources.isEmpty {
                        Section("Copy of") {
                            ForEach(copySources) { plan in
                                Text("\(plan.dates.isEmpty ? plan.title : plan.dates) · \(plan.isManual ? plan.title : plan.serviceTypeName)")
                                    .tag(AppModel.ServiceStart.copy(plan.id))
                            }
                        }
                    }
                    if !model.settings.templates.isEmpty {
                        Section("Template") {
                            ForEach(model.settings.templates) { template in
                                Text("\(template.name) · \(template.summary)").tag(AppModel.ServiceStart.template(template.id))
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            VStack(alignment: .leading, spacing: 6) {
                if start != .blank {
                    Text("The sections and item titles come along. The tracks don't, so last week's song can't play by mistake.")
                }
                if !model.newServiceTrackIDs.isEmpty {
                    let count = model.newServiceTrackIDs.count
                    Text("The \(count == 1 ? "track" : "\(count) tracks") you dropped go in at the end, each as an item of its own, already matched.")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") {
                    model.newServiceTrackIDs = []
                    model.showingNewService = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Create") {
                    model.createService(title: title, date: date, start: start, trackIDs: model.newServiceTrackIDs)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            // Most new services are next week's edition of the latest one.
            if let latest = model.upcomingSidebarPlans.last ?? model.pastSidebarPlans.first, latest.isManual {
                title = latest.title
            }
        }
    }

    /// The coming Sunday at 10:30, or today at 10:30 if today is Sunday.
    static func nextSunday(from now: Date = Date(), calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today)
        let days = (8 - weekday) % 7
        let sunday = calendar.date(byAdding: .day, value: days, to: today) ?? today
        return calendar.date(bySettingHour: 10, minute: 30, second: 0, of: sunday) ?? sunday
    }
}
