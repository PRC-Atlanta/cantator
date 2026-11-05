import CantorCore
import SwiftUI

enum LibraryFilter: Hashable {
    case all, attention, notDownloaded, duplicates, excluded
    case tag(String)
}

enum SidebarItem: Hashable {
    case show, check
    case plan(String)
    case library(LibraryFilter)
}

struct RootView: View {
    @AppEnvironment private var model
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var model = model
        Group {
            if model.isSimple {
                // The Simple view: library tags, songs, and the song on the right. The sheets and
                // alerts below still belong to the window.
                SimpleRootView()
            } else {
                NavigationSplitView(columnVisibility: $columns) {
                    Group {
                        // Show Mode trades the sidebar's links, which lead to text fields, for the program.
                        if model.show.showMode {
                            ProgramSidebar()
                        } else {
                            SidebarView(selection: $model.selection)
                        }
                    }
                    // Wide enough at its narrowest for its longest title, Pre-Service Check.
                    .navigationSplitViewColumnWidth(min: 222, ideal: 230, max: 300)
                    .toolbar { OperatorModeToolbarItem() }
                } detail: {
                    detail
                        // Every view keeps the Show view's minimum, which the split view then keeps
                        // when the sidebar is dragged wider or the window narrower: it stops the
                        // divider, or holds the window wider, instead of letting the columns overflow
                        // the window, which pushed the sidebar off its left edge. A minimum per view
                        // would not do: a sidebar widened in Library is not narrowed again in Show.
                        .navigationSplitViewColumnWidth(min: ShowView.minWidth, ideal: ShowView.minWidth)
                        .sheet(isPresented: $model.showingServicePicker) { ServicePickerSheet() }
                }
                .toolbar(removing: model.show.showMode ? .sidebarToggle : nil)
                .onChange(of: columns) { _, value in
                    // The program stays in view in Show Mode.
                    if model.show.showMode, value != .all { columns = .all }
                }
            }
        }
        .onChange(of: model.selection) { _, item in
            // Leaving the Show view lets go of an armed cue, so nothing waits on a GO no one can see.
            // A cue playing or on hold keeps the Show view, since its controls and keys live there.
            guard item != .show else { return }
            if case .armed = model.show.state {
                model.show.disarm()
            } else if model.show.state.holdsHouseEngine {
                model.selection = .show
                model.alert = "Stop the cue before leaving the Show view."
            }
        }
        .onChange(of: model.show.showMode) { _, locked in
            if locked {
                model.showingServicePicker = false
                model.showingNewService = false
                model.selection = .show
            }
            columns = .all
        }
        .sheet(isPresented: $model.showingNewService) { NewServiceSheet() }
        // The first-launch question. Older installs answered it by having used Planning Center.
        .sheet(isPresented: Binding(get: { !model.settings.hasChosenServiceSource }, set: { _ in })) { WelcomeSheet() }
        .sheet(item: Binding(
            get: { model.newFileToPresent },
            set: { value in
                // Esc or a close counts as Later. A sheet closed because playback started is not a choice.
                if value == nil, model.newFileToPresent != nil { model.snoozeNewFiles() }
            }
        )) { item in
            NewFileSheet(item: item)
        }
        .alert("Not a Playback?", isPresented: Binding(
            get: { model.pendingExclusion != nil },
            set: { if !$0 { model.pendingExclusion = nil } }
        ), presenting: model.pendingExclusion) { pending in
            Button("Remove and Exclude", role: .destructive) { model.confirmExclusion(pending) }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.message)
        }
        // An alert is a sheet, which would take the transport keys. The Show view shows it inline instead.
        .alert("Cantator", isPresented: Binding(get: { model.alert != nil && !model.show.showMode && !model.isSimple && model.selection != .show }, set: { if !$0 { model.alert = nil } })) {
            if model.claudeConnection == .signedOut, !model.show.state.holdsHouseEngine {
                Button("Sign In to Claude") { model.signInToClaude() }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alert ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection ?? .show {
        case .show: ShowView()
        case .check: CheckView()
        case .plan(let id): ServiceView(planID: id)
        case .library(let filter): LibraryView(filter: filter)
        }
    }
}
