import AppKit
import Combine
import Sparkle
import SwiftUI

/// Checks GitHub Releases for a new version through Sparkle, and installs one only when the
/// operator says so. An update never interrupts a show: no check runs while a cue is armed or
/// playing, in Show Mode or while a service loads, no update window opens on its own while the
/// Show view is up, and an update chosen meanwhile waits to relaunch until the show is idle.
@MainActor
@Observable
final class Updates: NSObject, SPUUpdaterDelegate {
    weak var model: AppModel?
    private(set) var canCheck = false
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var pendingInstall: (() -> Void)?
    @ObservationIgnored private var waitTimer: Timer?
    @ObservationIgnored private var subscriptions: Set<AnyCancellable> = []

    override init() {
        super.init()
        // Debug builds are signed ad hoc; replacing one with a release would only confuse.
        #if !DEBUG
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.canCheck = value }
            .store(in: &subscriptions)
        #endif
    }

    /// A cue armed or playing, Show Mode on or a service loading.
    var showIsBusy: Bool {
        guard let model else { return false }
        return model.show.state.holdsHouseEngine || model.show.showMode || model.isLoadingService
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        try MainActor.assumeIsolated {
            if showIsBusy {
                throw Self.refusal("Cantator checks for updates when no cue is armed or playing and Show Mode is off.")
            }
            // A scheduled check could open its window over the Show view and take the transport keys.
            if updateCheck == .updatesInBackground, model?.selection == .show {
                throw Self.refusal("Cantator skips scheduled update checks while the Show view is open.")
            }
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        MainActor.assumeIsolated {
            guard showIsBusy else { return false }
            pendingInstall = installHandler
            waitTimer?.invalidate()
            waitTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.installIfIdle() }
            }
            return true
        }
    }

    private func installIfIdle() {
        guard !showIsBusy, let install = pendingInstall else { return }
        pendingInstall = nil
        waitTimer?.invalidate()
        waitTimer = nil
        install()
    }

    private static func refusal(_ reason: String) -> NSError {
        NSError(domain: "org.prcatlanta.Cantor.updates", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
    }
}
