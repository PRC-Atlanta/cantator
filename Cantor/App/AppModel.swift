import AppKit
import CantorCore
import Foundation
import OSLog
import Observation

/// App-level state: everything the views read, and the wiring between CantorCore's parts.
@MainActor
@Observable
final class AppModel {
    /// The app's one model, for a view that SwiftUI updates after it has lost the environment.
    static weak var current: AppModel?

    var selection: SidebarItem? = .show
    var settings: AppSettings
    var library: Library
    var plans: [ServicePlan] = []
    var memory: AliasMemory
    var devices: [AudioOutputDevice] = []

    var loadedPlanID: String?
    var resident: [UUID: PCMBuffer] = [:]
    var isLoadingService = false
    var isScanning = false
    var isSyncing = false
    /// The service picker: its list, when it was read, and the service being read, if any.
    var showingServicePicker = false
    var pickerServices: [PlanSummary] = []
    var pickerListedAt: Date?
    var isListingServices = false
    var readingServiceID: String?
    var pickerMessage: String?
    var isMatching = false
    var analyzingCount = 0
    var alert: String?
    /// Not a Playback for tracks that services use, waiting on the operator's OK.
    var pendingExclusion: PendingExclusion?
    var status: String?
    var makingLocal: Set<UUID> = []
    /// Tracks waiting to be copied into ~/Music/Cantor, one at a time. See `queueCopies`.
    private(set) var copyQueue: [UUID] = []
    private var copyFailures: [String] = []
    var unreadableFiles: [String] = []
    var systemSoundStuckOnHouse = false
    // However the last waiting file leaves, answered, excluded, folded into a track or dropped as
    // stale, the review the operator opened from New Files is over, so quiet handling stays quiet.
    var inbox: NewFileInbox {
        didSet {
            if inbox.items.isEmpty { reviewingNewFiles = false }
            // An answer leaves with its file, however the file leaves.
            if !newFileAnswers.isEmpty {
                let waiting = Set(inbox.items.map(\.trackID))
                newFileAnswers = newFileAnswers.filter { waiting.contains($0.key) }
            }
        }
    }
    var isClassifying = false
    var claudeConnection = ClaudeConnection.checking
    /// What Claude is doing right now, if anything.
    var claudeWorking: String?
    var lastClaudeUse: ClaudeUse?
    var claudeRequestsThisSession = 0
    /// Where the last successful Planning Center sync came from, for Settings.
    var lastPlanningCenterSource: PlanningCenterSource?
    /// Set by Later. Cleared when another new file arrives or the app starts again.
    var newFilesSnoozed = false
    /// The operator clicked New Files or Sort with Claude, so the list shows even when new files are handled quietly.
    var reviewingNewFiles = false
    /// The New Service sheet, and tracks dropped on New Service… that the new service starts with.
    var showingNewService = false
    var showingTagEditor = false
    /// The operator's answers in the New Files list, kept here so closing the list, or an alert
    /// over it, never loses them. An answer leaves with its file.
    var newFileAnswers: [UUID: NewFileAnswer] = [:]
    /// The tracks New Tag… was chosen for, while it asks for the name.
    var newTagTrackIDs: Set<UUID>?
    var newServiceTrackIDs: [UUID] = []
    /// The Settings pane to show. The sidebar's outputs row opens Outputs.
    var settingsTab = SettingsTab.outputs

    var houseMeter = MeterState()
    var cueMeter = MeterState()
    var auditionPositionSec: Double?
    /// The preview asked for last, from the press until it stops, including while it decodes, so
    /// the button that started it can stop it.
    private(set) var auditioning: AuditionRequest?

    struct AuditionRequest: Equatable {
        var trackID: UUID
        var fromSec: Double?
    }
    /// The track Play Now, or the Simple view's Arm, is decoding before it starts.
    var playNowLoading: UUID?
    /// The Simple view: the song picked in its list, and the tag its list is narrowed to.
    var simpleTrackID: UUID?
    /// Counts Arm presses in Simple, so its search field lets go of the keys on an arm the operator
    /// asked for, and only then: a field that lost focus mid-word would turn typing into transport keys.
    var simpleArmPresses = 0
    var simpleTag: String?

    let show: ShowController
    let cueBus = CueBus()
    /// Files chosen with Import, converting one at a time. Set at the end of init.
    @ObservationIgnored private(set) var imports: ImportQueue!

    @ObservationIgnored private let houseBus = HouseBus()
    /// Imported files the next scan should send to New Files. The managed folder has no
    /// watch start, so the scan alone would not count them as new.
    @ObservationIgnored private var pendingImports: Set<String> = []
    @ObservationIgnored private let sleepGuard = SleepGuard()
    @ObservationIgnored private let soundGuard = SystemSoundGuard()
    @ObservationIgnored private var hashCache: HashCache
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var stopDeviceObservation: (() -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var rescanTask: Task<Void, Never>?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var peakCache: [UUID: [Float]] = [:]
    @ObservationIgnored private var auditionCache: [UUID: PCMBuffer] = [:]
    /// The library track last selected, decoded ahead so Play Now starts at once.
    @ObservationIgnored private var playNowCache: [UUID: PCMBuffer] = [:]
    @ObservationIgnored private var playNowPreload: UUID?
    @ObservationIgnored private var playNowRequest: UUID?
    @ObservationIgnored private var failedAnalysis = Set<UUID>()
    @ObservationIgnored private var cuesNeedRefresh = false
    /// A Load Service finished while a Play Now held the house, so the show takes the cues once idle.
    @ObservationIgnored private var showLoadPending = false
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var saveErrors: [String: String] = [:]
    @ObservationIgnored private var isCheckingClaude = false
    /// A request found the Claude login expired. Cleared only by a request that works.
    @ObservationIgnored private var loginExpired = false
    /// Asked for while a scan was running or a cue was engaged. Runs once that ends.
    @ObservationIgnored private var rescanPending = false
    /// Saves wait while a cue is engaged, so encoding the library never stalls the transport.
    @ObservationIgnored private var savePending = false
    @ObservationIgnored private var auditionRequest: UUID?
    @ObservationIgnored private let runLog = RunLog()

    private static func file<T>(_ name: String) -> JSONFile<T> {
        JSONFile(url: AppPaths.support.appendingPathComponent(name))
    }

    private let settingsFile: JSONFile<AppSettings> = AppModel.file("settings.json")
    private let libraryFile: JSONFile<Library> = AppModel.file("library.json")
    private let memoryFile: JSONFile<AliasMemory> = AppModel.file("aliases.json")
    private let plansFile: JSONFile<[ServicePlan]> = AppModel.file("services.json")
    private let cacheFile: JSONFile<HashCache> = AppModel.file("hash-cache.json")
    private let inboxFile: JSONFile<NewFileInbox> = AppModel.file("new-files.json")

    init() {
        var setAside: [String] = []
        let note = { (url: URL) in setAside.append(url.lastPathComponent) }
        settings = settingsFile.load(onQuarantine: note) ?? AppSettings()
        library = libraryFile.load(onQuarantine: note) ?? Library()
        memory = memoryFile.load(onQuarantine: note) ?? AliasMemory()
        plans = plansFile.load(onQuarantine: note) ?? []
        hashCache = cacheFile.load(onQuarantine: note) ?? HashCache()
        inbox = inboxFile.load(onQuarantine: note) ?? NewFileInbox()
        show = ShowController(house: houseBus, log: runLog)
        houseBus.onLost = { [weak self] in self?.show.deviceLost() }
        show.onPlayed = { [weak self] track in
            self?.library.update(id: track.id) {
                $0.playCount += 1
                $0.lastPlayed = Date()
            }
            self?.scheduleSave()
        }
        show.onEndMoved = { [weak self] id, end in self?.updateTrackEnd(id, end) }
        settings.stampWatchedFolders()
        try? settingsFile.save(settings)
        // Services built here leave on their own once they are old; synced ones leave with a sync.
        plans = ServicePlan.pruningPastManual(plans, keepWeeks: settings.keepPastServicesWeeks, loadedID: nil)
        if settings.newFileHandling == .quiet { inbox.dropStale() }
        applySettingsToShow()
        if !setAside.isEmpty {
            alert = "Some saved data could not be read and was set aside: \(setAside.joined(separator: ", "))"
        }
        imports = ImportQueue(canRun: { [weak self] in self?.canImport ?? false })
        imports.onFinished = { [weak self] imported, failures in
            guard let self else { return }
            pendingImports.formUnion(imported.map(\.path))
            if !failures.isEmpty { alert = failures.joined(separator: "\n") }
            rescan()
        }
    }

    // MARK: Lifecycle

    func start() {
        guard timer == nil else { return }
        // A previous run may have crashed with system sound moved off the house.
        soundGuard.release()
        refreshDevices()
        stopDeviceObservation = AudioDevices.observeDeviceChanges { [weak self] in
            Task { @MainActor in self?.refreshDevices() }
        }
        let tick = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(tick, forMode: .common)
        timer = tick

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSleep() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        // Signing in happens in Terminal, so coming back to Cantor is when the status may have changed.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshClaudeConnection() }
        }
        refreshClaudeConnection()

        restartWatcher()
        rescan()
    }

    func prepareToQuit() {
        stopAudition()
        soundGuard.release()
        sleepGuard.release()
        saveNow()
        runLog.flush()
    }

    private func handleSleep() {
        // Waking must always land in a silent, unarmed state.
        if show.state.holdsHouseEngine {
            show.deviceLost()
        }
        stopAudition()
    }

    private func tick() {
        show.tick()
        tickCount += 1
        if tickCount.isMultiple(of: 30) {
            show.checkDevice()
            classifyNewFiles()
            copyNext()
        }
        if tickCount.isMultiple(of: 30 * 300) { refreshClaudeConnection() }
        if showLoadPending, loadedPlanID != nil, show.load(cues: showCues()) {
            showLoadPending = false
            cuesNeedRefresh = false
        }
        if cuesNeedRefresh, !showLoadPending { refreshLoadedCues() }
        if !show.state.holdsHouseEngine {
            if savePending { saveNow() }
            if rescanPending, !isScanning { rescan() }
            if claudeConnection == .checking, !isCheckingClaude { refreshClaudeConnection() }
        }
        houseMeter.update(left: show.peakLeft, right: show.peakRight)
        if let kernel = cueBus.kernel {
            let peaks = kernel.takePeaks()
            cueMeter.update(left: peaks.left, right: peaks.right)
            auditionPositionSec = Double(kernel.positionFrames) / kernel.buffer.sampleRate
            if kernel.phase == .finished { stopAudition() }
        } else {
            cueMeter.update(left: 0, right: 0)
            // The cue bus can stop on its own, after a device change.
            if auditionPositionSec != nil {
                auditionPositionSec = nil
                auditioning = nil
            }
        }
    }

    func refreshDevices() {
        devices = AudioDevices.outputDevices()
        if let cue = settings.routing.cueDeviceUID, !devices.contains(where: { $0.uid == cue }) {
            stopAudition()
        }
        show.checkDevice()
        syncSoundGuard()
    }

    /// Runs whenever the house device, the device list or a macOS default changes, not only at load.
    private func syncSoundGuard() {
        guard loadedPlanID != nil, settings.isolateSystemSound, let house = settings.routing.houseDeviceUID else {
            soundGuard.release()
            systemSoundStuckOnHouse = false
            return
        }
        systemSoundStuckOnHouse = !soundGuard.engage(houseUID: house, preferredUID: settings.routing.cueDeviceUID)
        if systemSoundStuckOnHouse, let error = soundGuard.lastError {
            alert = "macOS sounds were left on the house output: \(error.localizedDescription)"
        }
    }

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        let previousFolders = settings.folders
        let previousRouting = settings.routing
        let previousClaude = (settings.llmEnabled, settings.claudePath)
        let previousKeep = settings.keepPastServicesWeeks
        change(&settings)
        if settings.routing.houseDeviceUID != previousRouting.houseDeviceUID || settings.routing.cueDeviceUID != previousRouting.cueDeviceUID {
            settings.routing.fitPairs(deviceChannels: Dictionary(devices.map { ($0.uid, $0.outputChannels) }, uniquingKeysWith: { a, _ in a }))
        }
        settings.stampWatchedFolders()
        applySettingsToShow()
        if settings.routing != previousRouting {
            // An audition already playing could be on the device that just became the house.
            stopAudition()
        }
        syncSoundGuard()
        markCuesChanged()
        record("settings") { try settingsFile.save(settings) }
        if previousClaude != (settings.llmEnabled, settings.claudePath) { refreshClaudeConnection() }
        if settings.folders != previousFolders {
            restartWatcher()
            rescan()
        }
        if settings.newFileHandling == .quiet, inbox.dropStale() > 0 { scheduleSave() }
        if !settings.usesPlanningCenter { showingServicePicker = false }
        if settings.keepPastServicesWeeks != previousKeep { prunePastServices() }
    }

    /// Past services built here leave as soon as the keep-for setting is shortened, not at the next launch.
    private func prunePastServices() {
        let kept = ServicePlan.pruningPastManual(plans, keepWeeks: settings.keepPastServicesWeeks, loadedID: loadedPlanID)
        guard kept.count != plans.count else { return }
        if case .plan(let id) = selection, !kept.contains(where: { $0.id == id }) { selection = .show }
        plans = kept
        scheduleSave()
    }

    /// The first-launch answer, also changeable in Settings > Services.
    func chooseServiceSource(_ source: ServiceSource) {
        updateSettings { $0.chooseServiceSource(source) }
    }

    /// An item the Service view should select and scroll to once it shows its service.
    var revealedCue: CueID?

    /// Opens a service on one of its items, as a Pre-Service Check issue does.
    func reveal(cue: CueID, planID: String) {
        revealedCue = cue
        selection = .plan(planID)
    }

    /// Opens Settings on a pane, as the sidebar's outputs row does.
    func openSettings(_ tab: SettingsTab) {
        settingsTab = tab
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    private func applySettingsToShow() {
        show.routing = settings.routing
        show.panicFadeSec = settings.panicFadeSec
    }

    // MARK: Persistence

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            if self.show.state.holdsHouseEngine {
                self.savePending = true
            } else {
                self.saveNow()
            }
        }
    }

    func saveNow() {
        savePending = false
        record("library") { try libraryFile.save(library) }
        record("aliases") { try memoryFile.save(memory) }
        record("services") { try plansFile.save(plans) }
        record("new files") { try inboxFile.save(inbox) }
        try? cacheFile.save(hashCache)
    }

    private func record(_ name: String, _ save: () throws -> Void) {
        do {
            try save()
            saveErrors[name] = nil
        } catch {
            // Say so once per failure of each file, not on every debounced save.
            if saveErrors[name] != error.localizedDescription {
                alert = "Could not save the \(name): \(error.localizedDescription)"
            }
            saveErrors[name] = error.localizedDescription
        }
    }

    // MARK: Library

    private var scanRoots: [String] {
        Array(Set(settings.folders + [ManagedFolder.path]))
    }

    private func restartWatcher() {
        let watcher = FolderWatcher { [weak self] in
            Task { @MainActor in self?.scheduleRescan() }
        }
        watcher.start(paths: scanRoots.filter { FileManager.default.fileExists(atPath: $0) })
        self.watcher = watcher
    }

    private func scheduleRescan(after seconds: Double = 2.5) {
        rescanTask?.cancel()
        rescanTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.rescan()
        }
    }

    /// Merging a scan runs on the main thread, so it waits while a cue is engaged.
    func rescan() {
        guard !isScanning, !show.state.holdsHouseEngine else {
            rescanPending = true
            return
        }
        rescanPending = false
        isScanning = true
        let roots = scanRoots
        var cache = hashCache
        Task {
            let result = await Task.detached(priority: .utility) { () -> (ScanResult, HashCache) in
                let result = FolderScanner.scan(roots: roots, cache: &cache)
                return (result, cache)
            }.value
            hashCache = result.1
            // A cue was armed or started while the folders were read. Merging and ranking are heavy
            // main-thread work, so they wait: the scan runs again once the show is idle.
            guard !show.state.holdsHouseEngine else {
                isScanning = false
                rescanPending = true
                return
            }
            let previousIDs = Set(library.tracks.map(\.id))
            let replaced = library.merge(scan: result.0.files, gaps: result.0.gaps, defaultFadeOutSec: settings.defaultFadeOutSec)
            remapCues(replaced)
            if library.excludeStems(protecting: confirmedTrackIDs) { rankAllPlans() }
            noteNewFiles(previousIDs: previousIDs, scan: result.0.files, replaced: replaced)
            unreadableFiles = result.0.unreadable
            isScanning = false
            scheduleSave()
            if result.0.hasUnsettledFiles { scheduleRescan(after: 3) }
            analyzePending()
        }
    }

    /// Tracks confirmed for any service. Stem detection never takes these away.
    private var confirmedTrackIDs: Set<UUID> {
        Set(plans.flatMap { $0.cues.compactMap(\.trackID) })
    }

    private func remapCues(_ replaced: [UUID: UUID]) {
        guard !replaced.isEmpty else { return }
        for planIndex in plans.indices {
            for cueIndex in plans[planIndex].cues.indices {
                if let id = plans[planIndex].cues[cueIndex].trackID, let new = replaced[id] {
                    plans[planIndex].cues[cueIndex].trackID = new
                }
            }
        }
        markCuesChanged()
    }

    /// Paused while a service is loaded: a finished analysis changes a track's level and start,
    /// and the show must play what the operator rehearsed. Check reports what is still unanalyzed.
    private func analyzePending() {
        guard analysisTask == nil, loadedPlanID == nil else { return }
        analysisTask = Task { [weak self] in
            while let self, self.loadedPlanID == nil,
                  let track = self.library.tracks.first(where: { self.needsAnalysis($0) }), let file = track.bestFile() {
                self.analyzingCount = self.library.tracks.filter { self.needsAnalysis($0) }.count
                let id = track.id
                let url = file.url
                let analysis = await Task.detached(priority: .background) { () -> TrackAnalysis? in
                    guard let buffer = try? PCMDecoder.decode(url: url) else { return nil }
                    return TrackAnalyzer.analyze(buffer)
                }.value
                // A service loaded during the decode. Analyze this track again after unload.
                guard self.loadedPlanID == nil else { break }
                guard let analysis else {
                    // Leave it unanalyzed so Check still reports it.
                    self.failedAnalysis.insert(id)
                    continue
                }
                self.library.update(id: id) { track in
                    track.integratedLUFS = analysis.integratedLUFS ?? -70
                    track.truePeakDb = analysis.truePeakDb
                    track.suggestedEndSec = analysis.suggestedEndSec
                    // A copy made from a Drive placeholder has no length until the next scan.
                    if track.durationSec <= 0 { track.durationSec = analysis.lengthSec }
                    if analysis.leadingSilenceSec > 0.05, track.startSec == 0 {
                        track.startSec = analysis.leadingSilenceSec
                    }
                }
                self.storePeaks(analysis.peaks, for: id)
                self.markCuesChanged()
                self.scheduleSave()
            }
            self?.analyzingCount = 0
            self?.analysisTask = nil
        }
    }

    private func needsAnalysis(_ track: Track) -> Bool {
        !track.isAnalyzed && track.isLocal && !track.isExcluded && !failedAnalysis.contains(track.id)
    }

    private func peaksURL(_ id: UUID) -> URL {
        AppPaths.support.appendingPathComponent("waveforms/\(id.uuidString).peaks")
    }

    private func storePeaks(_ peaks: [Float], for id: UUID) {
        peakCache[id] = peaks
        let url = peaksURL(id)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? peaks.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: url, options: .atomic)
    }

    func peaks(for id: UUID) -> [Float] {
        if let cached = peakCache[id] { return cached }
        guard let data = try? Data(contentsOf: peaksURL(id)) else { return [] }
        let peaks = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        peakCache[id] = peaks
        return peaks
    }

    func updateTrack(_ id: UUID, _ change: (inout Track) -> Void) {
        guard !show.showMode else { return }
        library.update(id: id) {
            change(&$0)
            $0.sanitizePoints()
        }
        // Preview follows EQ edits as they happen. House waits for the next arm.
        if cueBus.trackID == id, let kernel = cueBus.kernel, let track = library.track(id: id) {
            kernel.setEQ(EQCoefficients(track.eq, sampleRate: kernel.buffer.sampleRate))
        }
        markCuesChanged()
        scheduleSave()
    }

    /// The one track edit allowed in Show Mode, so the operator can adjust the mix as it plays. The
    /// playing cue and preview hear it at once. It is saved with the track like any edit; while a
    /// cue is engaged the save waits, as every save does, and lands once the cue stops.
    func updateTrackEQ(_ id: UUID, _ eq: TrackEQ?) {
        library.update(id: id) { $0.eq = eq }
        if cueBus.trackID == id, let kernel = cueBus.kernel {
            kernel.setEQ(EQCoefficients(eq, sampleRate: kernel.buffer.sampleRate))
        }
        show.setLiveEQ(eq, trackID: id)
        markCuesChanged()
        scheduleSave()
    }

    /// The end `[` and `]` moved, allowed in Show Mode like EQ. The show already plays to it; the
    /// save waits while a cue is engaged, as every save does.
    func updateTrackEnd(_ id: UUID, _ endSec: Double) {
        library.update(id: id) {
            $0.endSec = endSec
            $0.sanitizePoints()
        }
        // Only the end changed, so the cue list catches up without decoding anything again,
        // which during a song would retry a file that failed its check on every press.
        if loadedPlanID != nil { cuesNeedRefresh = true }
        scheduleSave()
    }

    /// Import is off while a cue is engaged: encoding is heavy, and the scan it needs would wait anyway.
    var canImport: Bool {
        !show.showMode && !show.state.holdsHouseEngine
    }

    /// Converts the chosen files into ~/Music/Cantor, then scans so they reach the library and the
    /// New Files list. The queue waits between files while a cue is engaged.
    func importFiles(_ urls: [URL]) {
        guard canImport, !urls.isEmpty else { return }
        imports.add(urls)
    }

    func makeLocal(_ track: Track) {
        guard !makingLocal.contains(track.id) else { return }
        makingLocal.insert(track.id)
        Task {
            defer { makingLocal.remove(track.id) }
            do {
                let file = try await Materializer.makeLocal(track: track)
                library.update(id: track.id) { value in
                    if !value.files.contains(file) { value.files.append(file) }
                }
                scheduleSave()
                analyzePending()
            } catch {
                alert = error.localizedDescription
            }
        }
    }

    /// Copies many tracks into ~/Music/Cantor, one at a time, so hundreds of files never download
    /// from Drive or copy all at once. Waits while a cue is armed or playing, and reports every
    /// file that could not be copied in one alert once the queue is done.
    func queueCopies(_ ids: [UUID]) {
        let waiting = Set(copyQueue)
        copyQueue += ids.filter { id in
            !waiting.contains(id) && !makingLocal.contains(id)
                && library.track(id: id).map { Materializer.managedCopy(of: $0) == nil } == true
        }
        copyNext()
    }

    /// Playbacks with no copy on this Mac yet, only in a cloud drive. Stems, parts and duplicates
    /// are excluded, so they are never downloaded from here.
    var notDownloadedPlaybacks: [UUID] {
        library.playbackTracks.filter { !$0.isLocal && $0.hasCloudOnlyCopy }.map(\.id)
    }

    /// Downloads every playback that is only in the cloud into ~/Music/Cantor, one at a time, so
    /// each gets its length and analysis.
    func makeAllLocal() {
        queueCopies(notDownloadedPlaybacks)
    }

    /// How many tracks are still to be copied, the one copying now included.
    var copiesLeft: Int { copyQueue.count + makingLocal.count }

    private func copyNext() {
        // Like imports, copies wait through Show Mode, so no download runs between songs.
        guard makingLocal.isEmpty, !show.state.holdsHouseEngine, !show.showMode else { return }
        guard !copyQueue.isEmpty else {
            reportCopyFailures()
            return
        }
        let id = copyQueue.removeFirst()
        guard let track = library.track(id: id) else { return copyNext() }
        makingLocal.insert(id)
        Task {
            do {
                let file = try await Materializer.makeLocal(track: track)
                library.update(id: id) { value in
                    if !value.files.contains(file) { value.files.append(file) }
                }
                scheduleSave()
            } catch MaterializeError.timedOut {
                // A copy stuck on Drive can't be stopped and keeps going, so the rest wait for
                // another try rather than piling more downloads on top of it.
                copyFailures.append(track.title)
                copyFailures += copyQueue.compactMap { library.track(id: $0)?.title }
                copyQueue = []
            } catch {
                copyFailures.append(track.title)
            }
            makingLocal.remove(id)
            if copyQueue.isEmpty, !show.state.holdsHouseEngine { analyzePending() }
            copyNext()
        }
    }

    private func reportCopyFailures() {
        // Waits for the New Files list to close, so the alert never takes its place.
        guard !copyFailures.isEmpty, !showsNewFiles else { return }
        let names = copyFailures.prefix(5).joined(separator: ", ") + (copyFailures.count > 5 ? " and \(copyFailures.count - 5) more" : "")
        alert = "\(copyFailures.count == 1 ? "1 file" : "\(copyFailures.count) files") could not be copied into ~/Music/Cantor: \(names). They still play from where they are. If Drive is slow or offline, try Make Local on them later."
        copyFailures = []
    }

    /// Effective static gain: loudness correction plus operator trim.
    func gainDb(for track: Track) -> Double {
        var gain = track.trimDb
        if settings.normalize, let lufs = track.integratedLUFS, let peak = track.truePeakDb {
            gain += LoudnessMeter.gain(lufs: lufs, truePeakDb: peak, targetLUFS: settings.targetLUFS).gainDb
        }
        return min(max(gain, -24), 24)
    }

    // MARK: Audition

    func audition(_ track: Track, fromSec: Double? = nil) {
        guard let file = track.bestFile() else {
            alert = "\(track.title) is not on this Mac yet."
            return
        }
        // Only the latest request may start. Stop, sleep or another preview cancels a decode in progress.
        let request = UUID()
        auditionRequest = request
        auditioning = AuditionRequest(trackID: track.id, fromSec: fromSec)
        Task {
            do {
                var buffer = resident[track.id] ?? auditionCache[track.id]
                if buffer == nil {
                    let url = file.url
                    buffer = try await Task.detached(priority: .userInitiated) { try PCMDecoder.decode(url: url) }.value
                    auditionCache = [track.id: buffer!]
                }
                guard let buffer, auditionRequest == request else { return }
                // Edits made while it decoded, such as EQ, are heard from the start.
                let current = library.track(id: track.id) ?? track
                let parameters = PlaybackParameters(track: current, sampleRate: buffer.sampleRate, frames: buffer.frames, gainDb: gainDb(for: current))
                try cueBus.audition(
                    trackID: track.id, buffer: buffer, parameters: parameters,
                    from: fromSec.map { Int($0 * buffer.sampleRate) }, routing: settings.routing
                )
            } catch {
                guard auditionRequest == request else { return }
                auditioning = nil
                alert = error.localizedDescription
            }
        }
    }

    /// A second press of the same preview stops it. A different track or start point plays that instead.
    func toggleAudition(_ track: Track, fromSec: Double? = nil) {
        if isAuditioning(track, fromSec: fromSec) { stopAudition() } else { audition(track, fromSec: fromSec) }
    }

    func isAuditioning(_ track: Track, fromSec: Double? = nil) -> Bool {
        auditioning == AuditionRequest(trackID: track.id, fromSec: fromSec)
    }

    func stopAudition() {
        auditionRequest = nil
        auditioning = nil
        cueBus.stop()
        auditionPositionSec = nil
    }

    // MARK: Play Now

    /// Decodes the one selected library track in the background, so Play Now needs no wait.
    func preparePlayNow(_ track: Track?) {
        guard let track, let file = track.bestFile() else { return }
        guard playNowCache[track.id] == nil, resident[track.id] == nil, playNowPreload != track.id else { return }
        playNowPreload = track.id
        let url = file.url
        Task {
            let buffer = await Task.detached(priority: .utility) { try? PCMDecoder.decode(url: url) }.value
            guard playNowPreload == track.id else { return }
            playNowPreload = nil
            if let buffer { playNowCache = [track.id: buffer] }
        }
    }

    /// Emergency: plays a library track on the house output straight away, outside any service.
    /// The Show view takes over from there.
    func playNow(_ track: Track) {
        engage(track, andGo: true)
    }

    // MARK: Simple view

    var isSimple: Bool { settings.operatorMode == .simple }

    /// The song the Simple view is on.
    var simpleTrack: Track? { simpleTrackID.flatMap { library.track(id: $0) } }

    /// The song the Simple view is on, as the cue its state bar and card describe. No buffer: the
    /// one that plays is built when Arm is pressed, from the decoded audio.
    var simpleCue: ShowCue? {
        simpleTrack.map { ShowCue(id: "simple-\($0.id.uuidString)", title: $0.title, track: $0, buffer: nil, gainDb: gainDb(for: $0)) }
    }

    /// The cue the state bar names: the one engaged, else the one Arm would take.
    var frontCue: ShowCue? { show.activeCue ?? (isSimple ? simpleCue : show.pointedCue) }

    /// Picks a song in the Simple view and decodes it ahead, so Arm is instant. Selecting never plays.
    func selectSimpleTrack(_ id: UUID?) {
        simpleTrackID = id
        preparePlayNow(simpleTrack)
    }

    /// Arm, from the A key, the Transport menu and the big button: the pointed cue in Advanced, the
    /// picked song in Simple.
    func arm() {
        if isSimple {
            guard let track = simpleTrack else {
                alert = "Pick a song first."
                return
            }
            // Like Advanced, a second A does nothing: not while a song plays, not on the song
            // already armed or loading. A different picked song still replaces the armed one.
            // A fault is acknowledged first, as the Arm button and Advanced's A ask.
            if case .faulted = show.state { return }
            var replacesArmed = false
            if case .armed = show.state { replacesArmed = show.activeCue?.track?.id != track.id }
            guard playNowLoading != track.id, replacesArmed || !show.state.holdsHouseEngine else { return }
            // A song that can't load leaves the armed one armed.
            guard track.bestFile() != nil else {
                alert = "\(track.title) is not on this Mac yet."
                return
            }
            simpleArmPresses += 1
            // The old song lets go at once, so a GO while the new one loads plays nothing rather
            // than the song the operator just moved away from.
            if replacesArmed { show.disarm() }
            engage(track, andGo: false)
        } else {
            show.arm()
        }
    }

    /// Disarm, from the D key, the Transport menu and the big button. In Simple it also drops a song
    /// still loading, which would otherwise arm once it is in.
    func disarm() {
        if isSimple, playNowLoading != nil {
            playNowRequest = nil
            playNowLoading = nil
        }
        show.disarm()
    }

    /// Switches between the Advanced and Simple views. Refused while a cue is armed or playing, since
    /// the two views arm different things, and it leaves Show Mode, which has nothing to lock in Simple.
    func setOperatorMode(_ mode: OperatorMode) {
        guard mode != settings.operatorMode else { return }
        guard !show.state.holdsHouseEngine else {
            alert = "Stop the cue before switching views."
            return
        }
        if show.showMode, !show.setShowMode(false) { return }
        stopAudition()
        // A song still loading was asked for in the other view, which is no longer on screen.
        playNowRequest = nil
        playNowLoading = nil
        updateSettings { $0.operatorMode = mode }
        selection = .show
        if mode == .simple, simpleTrackID == nil || simpleTrack == nil {
            selectSimpleTrack(library.playbackTracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }.first?.id)
        }
    }

    /// Decodes a library track if it is not in RAM yet, then arms it outside the cue list, and plays
    /// it at once for Play Now. The Show view, or the Simple view, has the controls from there.
    private func engage(_ track: Track, andGo: Bool) {
        guard let file = track.bestFile() else {
            alert = "\(track.title) is not on this Mac yet."
            return
        }
        let request = UUID()
        playNowRequest = request
        playNowLoading = track.id
        let pressedAt = show.moment
        Task {
            defer { if playNowRequest == request { playNowLoading = nil } }
            var buffer = resident[track.id] ?? playNowCache[track.id] ?? auditionCache[track.id]
            if buffer == nil {
                let url = file.url
                do {
                    buffer = try await Task.detached(priority: .userInitiated) { try PCMDecoder.decode(url: url) }.value
                } catch {
                    if playNowRequest == request { alert = error.localizedDescription }
                    return
                }
            }
            guard let buffer, playNowRequest == request else { return }
            // A Simple arm that outlived the switch to Advanced would arm something that view
            // never shows; the operator arms again from the cue list instead.
            guard andGo || isSimple else { return }
            playNowCache = [track.id: buffer]
            // Edits made while it decoded are heard too.
            let current = library.track(id: track.id) ?? track
            let cue = ShowCue(
                id: "\(andGo ? "play-now" : "simple")-\(request.uuidString)", title: current.title, track: current, buffer: buffer,
                gainDb: gainDb(for: current)
            )
            let refusal = andGo ? show.playNow(cue, pressedAt: pressedAt) : show.armStandalone(cue, pressedAt: pressedAt)
            if let refusal {
                alert = refusal.message
            } else {
                // The Show view has the controls that stop it.
                selection = .show
            }
        }
    }

    // MARK: Planning Center

    func hasPCOCredentials() -> Bool {
        (try? Keychain.lookup(.pcoAppID)) != nil && (try? Keychain.lookup(.pcoSecret)) != nil
    }

    /// Not in Show Mode: a sync can add, remove or reorder the loaded cues. Reads Planning Center
    /// through the Claude connector when that is the chosen source, and with the token otherwise or
    /// whenever the connector can't be used. Every service is checked against the library first, so
    /// lines turn on and strong matches land at once. `alsoRead` is a service the sync may not cover,
    /// such as a past one, read on its own afterwards.
    func refreshPlans(alsoRead planID: String? = nil) {
        guard settings.usesPlanningCenter, !isSyncing, !show.showMode, !show.state.holdsHouseEngine, !isLoadingService else { return }
        rematchAllPlans()
        isSyncing = true
        Task {
            defer { isSyncing = false }
            let memory = memory
            let hidden = settings.skippedServiceTypeIDs
            let (fresh, readNotes) = await readPlanningCenter(
                connector: { stream in try PlanningCenterConnector.plans(fromStream: stream, skipping: hidden, memory: memory) },
                prompt: PlanningCenterConnector.prompt(skipping: hidden), purpose: "Syncing Planning Center",
                // Reading every service type's next plans takes many tool calls.
                timeout: 480,
                token: { try await $0.fetchUpcomingPlans(skipping: hidden, memory: memory) }
            )
            var notes = readNotes
            // Show Mode can be turned on while Planning Center is read, which takes minutes. The
            // services must not change under a live show, so this read is set aside.
            guard !show.showMode else {
                alert = "Planning Center was read while Show Mode was on, so nothing was changed. Choose Refresh again after the service."
                return
            }
            if let fresh {
                plans = ServicePlan.applySync(existing: plans, fresh: fresh, loadedID: loadedPlanID)
                noteServiceTypes(fresh.map { ($0.serviceTypeID, $0.serviceTypeName) })
                let failed = fresh.filter(\.syncFailed).count
                if failed > 0 {
                    notes.append("\(failed) \(failed == 1 ? "service" : "services") could not be refreshed. Saved copies were kept.")
                }
            } else {
                notes.append("Using saved plans.")
            }
            if let planID, fresh?.contains(where: { $0.id == planID }) != true,
               let plan = plans.first(where: { $0.id == planID }), !show.showMode, !show.state.holdsHouseEngine {
                let (one, oneNotes) = await readService(plan.summary)
                if let one, let index = plans.firstIndex(where: { $0.id == planID }), !show.showMode {
                    plans[index] = plans[index].merging(fresh: one)
                }
                notes += oneNotes
            }
            if !notes.isEmpty { alert = notes.joined(separator: " ") }
            rematchAllPlans()
            markCuesChanged()
            scheduleSave()
        }
    }

    /// Checks every line against its notes and the library: lines whose notes say tracks turn on,
    /// and strong matches confirm themselves.
    func rematchAllPlans() {
        for index in plans.indices { plans[index].redetect(memory: memory) }
        rankAllPlans()
        markCuesChanged()
        scheduleSave()
    }

    /// Reads one service's items, as the service picker does.
    private func readService(_ summary: PlanSummary) async -> (ServicePlan?, [String]) {
        let memory = memory
        let prompt: String
        do {
            prompt = try PlanningCenterConnector.planPrompt(summary)
        } catch {
            return (nil, [error.localizedDescription])
        }
        return await readPlanningCenter(
            connector: { stream in try PlanningCenterConnector.plan(fromStream: stream, summary: summary, memory: memory) },
            prompt: prompt, purpose: "Reading \(summary.dates.isEmpty ? summary.title : summary.dates)", timeout: 300,
            token: { try await $0.fetchPlan(summary, memory: memory) }
        )
    }

    /// Every service type seen in a sync, the picker or a saved service, sorted by name.
    var knownServiceTypes: [(id: String, name: String)] {
        var types = settings.serviceTypes
        for plan in plans where !plan.serviceTypeID.isEmpty { types[plan.serviceTypeID] = plan.serviceTypeName }
        for summary in pickerServices where !summary.serviceTypeID.isEmpty { types[summary.serviceTypeID] = summary.serviceTypeName }
        return types.map { (id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Hiding a type takes it out of the sidebar now. Showing one again brings its services in at the next sync.
    func setServiceType(_ type: (id: String, name: String), shown: Bool) {
        updateSettings { settings in
            settings.noteServiceTypes([type])
            if shown { settings.hiddenServiceTypeIDs.remove(type.id) } else { settings.hiddenServiceTypeIDs.insert(type.id) }
        }
    }

    /// Remembers service type names for Settings, saving only when one is new or renamed.
    private func noteServiceTypes(_ types: [(id: String, name: String)]) {
        var updated = settings
        updated.noteServiceTypes(types)
        guard updated != settings else { return }
        settings = updated
        record("settings") { try settingsFile.save(settings) }
    }

    // MARK: Service picker

    /// Lists the services from six weeks back to three weeks ahead, without their items.
    func listPickerServices() {
        guard !isListingServices, !show.state.holdsHouseEngine else { return }
        isListingServices = true
        pickerMessage = nil
        Task {
            defer { isListingServices = false }
            let (summaries, notes) = await readPlanningCenter(
                connector: { stream in try PlanningCenterConnector.summaries(fromStream: stream) },
                prompt: PlanningCenterConnector.listPrompt(), purpose: "Listing services", timeout: 300,
                token: { try await $0.listPlans() }
            )
            if let summaries {
                pickerServices = summaries
                pickerListedAt = Date()
                noteServiceTypes(summaries.map { ($0.serviceTypeID, $0.serviceTypeName) })
            }
            pickerMessage = notes.isEmpty ? nil : notes.joined(separator: " ")
        }
    }

    /// Reads the chosen service's items and adds it to the sidebar, then shows it.
    /// Not in Show Mode, for the same reason as a sync.
    func pickService(_ summary: PlanSummary) {
        guard readingServiceID == nil, !show.showMode, !show.state.holdsHouseEngine, !isLoadingService else { return }
        readingServiceID = summary.id
        pickerMessage = nil
        Task {
            defer { readingServiceID = nil }
            let (fresh, notes) = await readService(summary)
            guard let fresh, !show.showMode else {
                pickerMessage = notes.isEmpty ? nil : notes.joined(separator: " ")
                return
            }
            plans = ServicePlan.applyPicked(existing: plans, fresh: fresh)
            rankAllPlans()
            markCuesChanged()
            scheduleSave()
            if !notes.isEmpty { alert = notes.joined(separator: " ") }
            showingServicePicker = false
            selection = .plan(fresh.id)
        }
    }

    /// Where the next Planning Center read goes first: the token whenever one is saved, since it is
    /// faster, gives attachment filenames and uses no Claude usage. The connector otherwise.
    var planningCenterSource: PlanningCenterSource { hasPCOCredentials() ? .token : .connector }

    /// One Planning Center read: with the token when one is saved, and through the connector
    /// otherwise or whenever the token can't be used and Claude is on. The notes say what went wrong.
    private func readPlanningCenter<T>(
        connector: @escaping (Data) throws -> T, prompt: String, purpose: String, timeout: TimeInterval,
        token: (PCOClient) async throws -> T
    ) async -> (T?, [String]) {
        var notes: [String] = []
        do {
            if let appID = try Keychain.lookup(.pcoAppID), let secret = try Keychain.lookup(.pcoSecret) {
                let value = try await token(PCOClient(appID: appID, secret: secret))
                lastPlanningCenterSource = .token
                return (value, notes)
            }
        } catch {
            notes.append(error.localizedDescription)
            // Offline, the connector can't reach Planning Center either, and would only add minutes.
            if let error = error as? URLError, PCOClient.isConnectionLoss(error) { return (nil, notes) }
        }
        guard settings.llmEnabled else {
            if notes.isEmpty { notes.append("Add your Planning Center token in Settings.") }
            return (nil, notes)
        }
        do {
            let stream = try await runConnector(prompt: prompt, purpose: purpose, timeout: timeout)
            let value = try connector(stream)
            lastPlanningCenterSource = .connector
            if !notes.isEmpty { notes.append("Used the Claude connector instead.") }
            return (value, notes)
        } catch {
            noteClaudeFailure(error)
            notes.append(error.localizedDescription)
            if !hasPCOCredentials() { notes.append("Add a Planning Center token in Settings to read it without the connector.") }
            return (nil, notes)
        }
    }

    /// Runs Claude Code with only the Planning Center connector's read-only Services tools. The
    /// caller reads the data from the tools' own results in the stream.
    private func runConnector(prompt: String, purpose: String, timeout: TimeInterval) async throws -> Data {
        guard settings.llmEnabled else { throw PlanningCenterConnectorError.claudeOff }
        var cli = try await claudeAccount()
        let server: MCPServerStatus
        do {
            server = try PlanningCenterConnector.server(in: try await cli.mcpServers())
        } catch PlanningCenterConnectorError.notConnected {
            // An expired login hides every connector, so check it before blaming the connector.
            // Only a login problem replaces the connector message; a probe that fails otherwise
            // says nothing about the connector.
            do {
                if try await cli.signInWorks() { noteSignInWorks() }
            } catch LLMError.notLoggedIn {
                throw LLMError.notLoggedIn
            } catch LLMError.limitReached {
                loginExpired = false
                throw LLMError.limitReached
            } catch {}
            throw PlanningCenterConnectorError.notConnected
        }
        cli.timeout = timeout
        let model = settings.llmModel
        return try await usingClaude(purpose) {
            try await cli.runWithTools(
                system: PlanningCenterConnector.system, prompt: prompt,
                allowedTools: PlanningCenterConnector.allowedTools(server: server.name),
                disallowedTools: PlanningCenterConnector.disallowedTools(server: server.name), model: model
            )
        }
    }

    func rankAllPlans() {
        for planIndex in plans.indices {
            for cueIndex in plans[planIndex].cues.indices where plans[planIndex].cues[cueIndex].needsPlayback {
                let cue = plans[planIndex].cues[cueIndex]
                plans[planIndex].cues[cueIndex].candidates = Matcher.rank(cue: cue, tracks: library.playbackTracks, memory: memory)
            }
        }
        autoConfirmStrongMatches()
    }

    /// Strong matches confirm themselves, outside Show Mode so a loaded service never changes mid-show.
    private func autoConfirmStrongMatches() {
        guard !show.showMode else { return }
        var confirmed = 0
        for planIndex in plans.indices { confirmed += plans[planIndex].autoConfirmStrongMatches() }
        guard confirmed > 0 else { return }
        markCuesChanged()
        scheduleSave()
    }

    func runAIMatch(planID: String) {
        guard !show.state.holdsHouseEngine else { return }
        guard settings.llmEnabled else {
            alert = "AI matching is turned off in Settings. Matching by name still works."
            return
        }
        guard let planIndex = plans.firstIndex(where: { $0.id == planID }), !isMatching else { return }
        let cues = plans[planIndex].cues.filter { $0.needsPlayback && $0.trackID == nil && Matcher.needsTiebreak($0.candidates) }
        guard !cues.isEmpty else {
            status = "No ambiguous matches to resolve."
            return
        }
        isMatching = true
        let tracks = Dictionary(library.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let model = settings.llmModel
        Task {
            defer { isMatching = false }
            do {
                let tiebreaker = LLMTiebreaker(runner: try await claudeAccount(), model: model)
                let purpose = "Ranking \(cues.count) ambiguous \(cues.count == 1 ? "match" : "matches")"
                let results = try await usingClaude(purpose) { try await tiebreaker.resolve(cues: cues, tracks: tracks) }
                guard let index = plans.firstIndex(where: { $0.id == planID }) else { return }
                // The answer can take minutes. Skip cues confirmed since, and tracks excluded or gone since.
                let current = Set(library.playbackTracks.map(\.id))
                for cueIndex in plans[index].cues.indices where plans[index].cues[cueIndex].trackID == nil {
                    if let updated = results[plans[index].cues[cueIndex].id] {
                        plans[index].cues[cueIndex].candidates = updated.filter { current.contains($0.trackID) }
                    }
                }
                scheduleSave()
            } catch {
                noteClaudeFailure(error)
                alert = error.localizedDescription
            }
        }
    }

    /// Claude Code, checked to be signed in to a Claude account rather than set up with an API key.
    /// Every check updates the status the sidebar shows.
    private func claudeAccount() async throws -> ClaudeCLI {
        do {
            guard let path = ClaudeCLI.locate(override: settings.claudePath) else { throw LLMError.notInstalled }
            let cli = ClaudeCLI(path: path)
            let account = try await cli.accountStatus()
            guard account.isLoggedIn else { throw LLMError.notLoggedIn }
            guard !account.usesAPIKey else { throw LLMError.usesAPIKey }
            // `auth status` still reads as logged in once a login has expired, so it can't undo a
            // request that found it expired; only a request that works can.
            if settings.llmEnabled, !loginExpired { claudeConnection = .connected }
            return cli
        } catch {
            if settings.llmEnabled { claudeConnection = ClaudeConnection(error: error) }
            throw error
        }
    }

    /// Records a request for Settings: shown as working while it runs, then as the last use.
    private func usingClaude<T>(_ purpose: String, _ work: () async throws -> T) async throws -> T {
        claudeWorking = purpose
        claudeRequestsThisSession += 1
        defer { claudeWorking = nil }
        do {
            let result = try await work()
            if loginExpired { noteSignInWorks() }
            lastClaudeUse = ClaudeUse(purpose: purpose)
            return result
        } catch {
            lastClaudeUse = ClaudeUse(purpose: purpose, failure: error.localizedDescription)
            throw error
        }
    }

    /// A request was answered, so the login works, whatever an earlier one found.
    private func noteSignInWorks() {
        loginExpired = false
        if settings.llmEnabled { claudeConnection = .connected }
    }

    /// A request that failed after the account check, such as a usage limit, also changes the status.
    private func noteClaudeFailure(_ error: Error) {
        guard settings.llmEnabled, let error = error as? LLMError else { return }
        switch error {
        case .notInstalled, .notLoggedIn, .usesAPIKey, .limitReached: claudeConnection = ClaudeConnection(error: error)
        default: break
        }
        if case .notLoggedIn = error { loginExpired = true }
    }

    /// Opens Terminal on `claude auth login`. Coming back to Cantor checks the status again.
    func signInToClaude() {
        // Terminal would come forward and take the transport keys.
        guard !show.showMode, !show.state.holdsHouseEngine else { return }
        guard let path = ClaudeCLI.locate(override: settings.claudePath) else {
            alert = LLMError.notInstalled.localizedDescription
            return
        }
        do {
            try ClaudeCLI(path: path).openSignInInTerminal()
        } catch {
            alert = "Couldn't open Terminal. Run claude auth login there yourself. \(error.localizedDescription)"
        }
    }

    /// Runs `claude auth status`, which needs no network and uses no account usage. `verify`, for a
    /// check the operator asked for, also sends a one-word request, since a saved login can have expired.
    func refreshClaudeConnection(verify: Bool = false) {
        guard settings.llmEnabled else {
            claudeConnection = .off
            return
        }
        if claudeConnection == .off { claudeConnection = .checking }
        guard !isCheckingClaude, !show.state.holdsHouseEngine else { return }
        isCheckingClaude = true
        Task {
            defer { isCheckingClaude = false }
            // Once a login was found expired, every check sends the request, so coming back from
            // signing in in Terminal shows connected without pressing Check.
            guard let cli = try? await claudeAccount(), verify || loginExpired else { return }
            do {
                if try await cli.signInWorks() { noteSignInWorks() }
            } catch {
                // Out of usage means the login was accepted.
                if case LLMError.limitReached = error { loginExpired = false }
                noteClaudeFailure(error)
            }
            // No clear answer (offline, overloaded) leaves an expired login as it was, not checking.
            if loginExpired, settings.llmEnabled { claudeConnection = .signedOut }
        }
    }

    private func updateCue(planID: String, cueID: CueID, _ change: (inout ServiceCue) -> Void) {
        guard let planIndex = plans.firstIndex(where: { $0.id == planID }),
              let cueIndex = plans[planIndex].cues.firstIndex(where: { $0.id == cueID })
        else { return }
        change(&plans[planIndex].cues[cueIndex])
        markCuesChanged()
        scheduleSave()
    }

    func confirm(planID: String, cue: ServiceCue, track: Track) {
        updateCue(planID: planID, cueID: cue.id) {
            $0.trackID = track.id
            $0.changedSinceConfirm = false
            $0.autoConfirmed = false
        }
        if let contentID = track.contentID { memory.remember(cue, contentID: contentID) }
        if let song = cue.songID {
            library.update(id: track.id) { value in
                if !value.pcoSongIDs.contains(song) { value.pcoSongIDs.append(song) }
            }
        }
        scheduleSave()
    }

    /// Also stops Cantor from confirming a strong match on this item by itself again.
    func clearMatch(planID: String, cue: ServiceCue) {
        updateCue(planID: planID, cueID: cue.id) {
            $0.trackID = nil
            $0.autoConfirmed = false
            $0.matchCleared = true
        }
    }

    func setNeeded(planID: String, cue: ServiceCue, needed: Bool) {
        updateCue(planID: planID, cueID: cue.id) {
            $0.needsPlayback = needed
            $0.operatorNeeds = needed
        }
        memory.rememberNeeds(cue, needed: needed)
        rankAllPlans()
        scheduleSave()
    }

    /// Adds library tracks to a service as items of their own, already confirmed. Locked in Show Mode
    /// like every other edit.
    func addTracks(_ trackIDs: [UUID], to planID: String, at point: ServicePlan.InsertPoint) {
        guard !show.showMode, let index = plans.firstIndex(where: { $0.id == planID }) else { return }
        let cues = trackIDs.compactMap { library.track(id: $0) }.map { track in
            var cue = ServiceCue(id: "manual-\(UUID().uuidString)", position: 0, title: track.title, isManual: true)
            cue.trackID = track.id
            return cue
        }
        guard !cues.isEmpty else { return }
        plans[index].insert(cues, at: point)
        markCuesChanged()
        scheduleSave()
    }

    /// An item from Planning Center comes back on the next Refresh as Planning Center has it, and is
    /// matched as a new item would be, remembered choices included. One added by hand is gone for good.
    func removeCue(planID: String, cueID: CueID) {
        guard !show.showMode, let index = plans.firstIndex(where: { $0.id == planID }),
              plans[index].cues.contains(where: { $0.id == cueID })
        else { return }
        plans[index].remove(cueID)
        markCuesChanged()
        scheduleSave()
    }

    // MARK: Services built in Cantator

    /// How a new service starts: empty, as a copy of another service's order, or from a template.
    enum ServiceStart: Hashable {
        case blank
        case copy(String)
        case template(UUID)
    }

    /// Creates a service and shows it. Tracks dropped on New Service… go in at the end, each as an
    /// item of its own, already matched.
    func createService(title: String, date: Date, start: ServiceStart, trackIDs: [UUID] = []) {
        guard !show.showMode else { return }
        var plan: ServicePlan
        switch start {
        case .blank:
            plan = .manual(title: title, date: date)
        case .copy(let id):
            guard let source = plans.first(where: { $0.id == id }) else { return }
            plan = source.copyingOrder(title: title, date: date)
        case .template(let id):
            guard let template = settings.templates.first(where: { $0.id == id }) else { return }
            plan = .manual(title: title, date: date, cues: ServicePlan.cues(from: template))
        }
        plans.append(plan)
        plans.sort { ($0.sortDate ?? .distantFuture) < ($1.sortDate ?? .distantFuture) }
        addTracks(trackIDs, to: plan.id, at: .end)
        rankAllPlans()
        showingNewService = false
        newServiceTrackIDs = []
        selection = .plan(plan.id)
        scheduleSave()
    }

    /// Opens the New Service sheet, with tracks that were dropped on it.
    func startNewService(with trackIDs: [UUID] = []) {
        guard !show.showMode, !show.state.holdsHouseEngine, !isLoadingService else { return }
        newServiceTrackIDs = trackIDs
        showingNewService = true
    }

    /// Only a service built in Cantator can be deleted, and not while it is loaded.
    func deleteService(planID: String) {
        guard !show.showMode, planID != loadedPlanID, let plan = plans.first(where: { $0.id == planID }), plan.isManual else { return }
        plans.removeAll { $0.id == planID }
        if selection == .plan(planID) { selection = .show }
        scheduleSave()
    }

    func saveTemplate(planID: String, name: String) {
        guard let plan = plans.first(where: { $0.id == planID }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updateSettings { settings in
            settings.templates.append(ServiceTemplate(plan: plan, name: trimmed.isEmpty ? plan.title : trimmed))
        }
        status = "Saved as a template. New Service… can start from it."
    }

    func deleteTemplate(_ id: UUID) {
        updateSettings { $0.templates.removeAll { $0.id == id } }
    }

    /// Adds an item or a section after a cue, or at the end. Returns the new cue's id so it can be selected.
    @discardableResult
    func addCue(planID: String, header: Bool, after cueID: CueID?) -> CueID? {
        guard !show.showMode, let index = plans.firstIndex(where: { $0.id == planID }) else { return nil }
        let cue = ServicePlan.manualCue(title: header ? "New Section" : "New Item", header: header)
        plans[index].insert([cue], at: cueID.map { .after($0) } ?? .end)
        markCuesChanged()
        scheduleSave()
        return cue.id
    }

    func renameCue(planID: String, cueID: CueID, title: String) {
        guard !show.showMode else { return }
        updateCue(planID: planID, cueID: cueID) { cue in
            guard cue.isManual else { return }
            cue.title = title
        }
        // The name is what the matcher works from, but not on every keystroke.
        scheduleRank()
    }

    /// Renames a service built in Cantator. A blank name is not a name, so it changes nothing.
    func renameManualPlan(planID: String, title: String) {
        guard !show.showMode, let index = plans.firstIndex(where: { $0.id == planID }), plans[index].isManual else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != plans[index].title else { return }
        plans[index].title = name
        plans[index].serviceTypeName = name
        scheduleSave()
    }

    /// Moves a service built in Cantator to another date.
    func moveManualPlan(planID: String, to date: Date) {
        guard !show.showMode, let index = plans.firstIndex(where: { $0.id == planID }), plans[index].isManual else { return }
        plans[index].dates = ServicePlan.dateLabel(date)
        plans[index].sortDate = date
        plans[index].serviceTimes = [date]
        plans.sort { ($0.sortDate ?? .distantFuture) < ($1.sortDate ?? .distantFuture) }
        scheduleSave()
    }

    @ObservationIgnored private var rankTask: Task<Void, Never>?

    private func scheduleRank() {
        rankTask?.cancel()
        rankTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            self.rankAllPlans()
        }
    }

    func setCueNotes(planID: String, cueID: CueID, notes: String) {
        guard !show.showMode else { return }
        updateCue(planID: planID, cueID: cueID) { cue in
            guard cue.isManual else { return }
            cue.notes = notes
        }
    }

    /// Moves a cue one place. Only cues added by hand move; Planning Center owns the order of its own.
    func moveCue(planID: String, cueID: CueID, by offset: Int) {
        guard !show.showMode, let index = plans.firstIndex(where: { $0.id == planID }),
              plans[index].cues.contains(where: { $0.id == cueID && $0.isManual })
        else { return }
        guard plans[index].move(cueID, by: offset) else { return }
        markCuesChanged()
        scheduleSave()
    }

    /// A cue dragged onto another lands right after it.
    func moveCue(planID: String, cueID: CueID, to point: ServicePlan.InsertPoint) {
        guard !show.showMode, let index = plans.firstIndex(where: { $0.id == planID }),
              plans[index].cues.contains(where: { $0.id == cueID && $0.isManual })
        else { return }
        plans[index].move(cueID, to: point)
        markCuesChanged()
        scheduleSave()
    }

    /// Takes the track off an item added by hand, keeping the item. Not Clear Match: nothing was
    /// confirmed by Cantator, so there is nothing to stop it doing again.
    func clearTrack(planID: String, cueID: CueID) {
        guard !show.showMode else { return }
        updateCue(planID: planID, cueID: cueID) { cue in
            guard cue.isManual else { return }
            cue.trackID = nil
            cue.autoConfirmed = false
        }
        rankAllPlans()
    }

    // MARK: Service load

    var loadedPlan: ServicePlan? { plans.first { $0.id == loadedPlanID } }

    /// The services in the sidebar: hidden service types are left out, unless picked by hand or loaded.
    var sidebarPlans: [ServicePlan] { plans.filter { !settings.hides($0) || $0.id == loadedPlanID } }

    /// Pinned services, listed first whatever their dates, for practice days that only load songs.
    var pinnedSidebarPlans: [ServicePlan] {
        sidebarPlans.filter(\.pinned).sorted { a, b in
            let order = a.sidebarName.localizedStandardCompare(b.sidebarName)
            return order == .orderedSame ? (a.sortDate ?? .distantFuture) < (b.sortDate ?? .distantFuture) : order == .orderedAscending
        }
    }

    /// Today's and later services, then the ones already over, which the sidebar folds away. Pinned
    /// services are in neither: their dates don't count. The loaded service stays with the upcoming
    /// ones after midnight, so it never folds away while it is in use.
    var upcomingSidebarPlans: [ServicePlan] {
        let today = Calendar.current.startOfDay(for: Date())
        return sidebarPlans.filter { !$0.pinned && (($0.sortDate ?? .distantFuture) >= today || $0.id == loadedPlanID) }
    }

    /// The upcoming services inside the sidebar's rolling window, which moves on with the date. The
    /// loaded service and one with no date always show.
    var shownUpcomingPlans: [ServicePlan] {
        guard let end = ServicePlan.upcomingWindowEnd(weeks: settings.upcomingServicesWeeks) else { return upcomingSidebarPlans }
        return upcomingSidebarPlans.filter { ($0.sortDate.map { $0 < end } ?? true) || $0.id == loadedPlanID }
    }

    var pastSidebarPlans: [ServicePlan] {
        let today = Calendar.current.startOfDay(for: Date())
        return sidebarPlans.filter { !$0.pinned && $0.id != loadedPlanID && ($0.sortDate ?? .distantFuture) < today }.reversed()
    }

    /// The loaded service, else the next one from today on. A pinned Planning Center service still
    /// counts by its date, since pinning Sunday's service keeps it Sunday's; a pinned one built here
    /// is a practice list and never stands in for a service. Plans are sorted by date and keep recent
    /// past ones.
    var currentPlan: ServicePlan? {
        let today = Calendar.current.startOfDay(for: Date())
        return loadedPlan ?? sidebarPlans.first { (!$0.pinned || !$0.isManual) && ($0.sortDate ?? .distantFuture) >= today }
            ?? sidebarPlans.last { !$0.pinned } ?? sidebarPlans.last { !($0.pinned && $0.isManual) }
    }

    /// Pinning only changes where the service is listed, so it is allowed in Show Mode too.
    func setPinned(planID: String, _ pinned: Bool) {
        guard let index = plans.firstIndex(where: { $0.id == planID }) else { return }
        plans[index].pinned = pinned
        // A service of a hidden type was only showing because of the pin. Unpinned, it stays as if
        // chosen in the service picker, so it doesn't vanish with no way back.
        if !pinned, settings.hides(plans[index]) { plans[index].picked = true }
        scheduleSave()
    }

    /// A double-click on a service: loads it unless it is already loaded, then opens the Show view in
    /// Show Mode, ready to arm. Simple has no Show Mode, so it only opens the Show view.
    func goLive(planID: String) {
        if loadedPlanID == planID {
            selection = .show
            // Not while files are still decoding, or while a load waits behind a cue and the show
            // still holds the old service's cues.
            if !isSimple, !isLoadingService, !showLoadPending, !show.cues.isEmpty { show.setShowMode(true) }
            return
        }
        if isLoadingService {
            alert = "A service is still loading. Try again in a moment."
        } else if show.showMode {
            alert = "Leave Show Mode before loading another service."
        } else if show.state.holdsHouseEngine {
            alert = "Stop the cue before loading another service."
        } else {
            loadService(planID: planID, thenShow: true)
        }
    }

    /// Decodes every confirmed cue into RAM, then holds sleep and system sound for the service.
    /// Each file is checked against the audio that was confirmed, in case it changed since the last scan.
    /// `thenShow` opens the Show view in Show Mode once the cues are in.
    func loadService(planID: String, thenShow: Bool = false) {
        guard !show.state.holdsHouseEngine, !show.showMode, !isLoadingService,
              let plan = plans.first(where: { $0.id == planID })
        else { return }
        isLoadingService = true
        rescan()
        let trackIDs = Set(plan.playbackCues.compactMap(\.trackID))
        let files: [(UUID, URL, String?, String)] = trackIDs.compactMap { id in
            guard let track = library.track(id: id), let file = track.bestFile() else { return nil }
            return (id, file.url, track.contentID, track.title)
        }
        let existing = resident
        Task {
            let decoded = await Task.detached(priority: .userInitiated) { Self.decode(files, existing: existing) }.value

            isLoadingService = false
            guard plans.contains(where: { $0.id == planID }) else {
                alert = "That service is gone, so it was not loaded."
                return
            }
            resident = decoded.0
            loadedPlanID = planID
            showLoadPending = !show.load(cues: showCues())
            sleepGuard.engage()
            syncSoundGuard()
            if !decoded.1.isEmpty { alert = decoded.1.joined(separator: "\n") }
            if thenShow {
                selection = .show
                if !isSimple, !showLoadPending, !show.cues.isEmpty { show.setShowMode(true) }
            }
            // A file confirmed while the service decoded wasn't in the list read at the start.
            loadMissingBuffers()
        }
    }

    /// Each file is checked against the audio that was confirmed, in case it changed since the last scan.
    nonisolated private static func decode(
        _ files: [(UUID, URL, String?, String)], existing: [UUID: PCMBuffer] = [:]
    ) -> ([UUID: PCMBuffer], [String]) {
        var buffers: [UUID: PCMBuffer] = [:]
        var failures: [String] = []
        for (id, url, contentID, title) in files {
            do {
                if let contentID, try ContentHasher.contentID(url: url) != contentID {
                    failures.append("\(title) changed on disk since you confirmed it. Rescan and confirm it again.")
                    continue
                }
                buffers[id] = try existing[id] ?? PCMDecoder.decode(url: url)
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        return (buffers, failures)
    }

    private func showCues() -> [ShowCue] {
        guard let plan = loadedPlan else { return [] }
        return plan.playbackCues.map { cue in
            let track = cue.trackID.flatMap { library.track(id: $0) }
            return ShowCue(
                id: cue.id, title: cue.title, notes: cue.notes, track: track,
                buffer: track.flatMap { resident[$0.id] }, gainDb: track.map(gainDb(for:)) ?? 0
            )
        }
    }

    private func markCuesChanged() {
        guard loadedPlanID != nil else { return }
        cuesNeedRefresh = true
        loadMissingBuffers()
    }

    /// A cue confirmed or added after Load Service is decoded too, so it can be armed.
    private func loadMissingBuffers() {
        guard !isLoadingService, let plan = loadedPlan else { return }
        let files: [(UUID, URL, String?, String)] = Set(plan.playbackCues.compactMap(\.trackID)).compactMap { id in
            guard resident[id] == nil, let track = library.track(id: id), let file = track.bestFile() else { return nil }
            return (id, file.url, track.contentID, track.title)
        }
        guard !files.isEmpty else { return }
        isLoadingService = true
        let planID = plan.id
        Task {
            let decoded = await Task.detached(priority: .userInitiated) { Self.decode(files) }.value
            isLoadingService = false
            guard loadedPlanID == planID else { return }
            resident.merge(decoded.0) { old, _ in old }
            cuesNeedRefresh = true
            if !decoded.1.isEmpty { alert = decoded.1.joined(separator: "\n") }
        }
    }

    /// Show must play what the operator last saved. Edits wait until no cue is engaged.
    private func refreshLoadedCues() {
        if show.refresh(cues: showCues()) { cuesNeedRefresh = false }
    }

    func unloadService() {
        guard !show.state.holdsHouseEngine, !isLoadingService else { return }
        show.setShowMode(false)
        show.load(cues: [])
        showLoadPending = false
        resident = [:]
        loadedPlanID = nil
        sleepGuard.release()
        syncSoundGuard()
        classifyNewFiles()
        analyzePending()
    }

    // MARK: New files

    private func noteNewFiles(previousIDs: Set<UUID>, scan: [ScannedFile], replaced: [UUID: UUID]) {
        let before = inbox
        // A file found to be a stem leaves the inbox.
        inbox.reconcile(replaced: replaced, existing: Set(library.playbackTracks.map(\.id)))
        // A cloud drive once reported its files as added when it first synced the folder.
        let early = NewFileDetector.arrivedBeforeWatch(
            Set(inbox.items.map(\.trackID)), tracks: library.playbackTracks, scan: scan, watchedSince: settings.watchedSince
        )
        for id in early {
            inbox.remove(id)
            newFileAnswers[id] = nil
        }
        var found = NewFileDetector.newTrackIDs(
            previousIDs: previousIDs, tracks: library.playbackTracks, scan: scan, watchedSince: settings.watchedSince
        )
        // An import whose audio was already in the library joins that track and is not new.
        let imported = library.playbackTracks.filter { track in
            !previousIDs.contains(track.id) && track.files.contains { pendingImports.contains($0.path) }
        }
        found += imported.map(\.id).filter { !found.contains($0) }
        let scanned = Set(scan.map(\.path))
        pendingImports.subtract(scanned)
        inbox.add(found)
        if !found.isEmpty { newFilesSnoozed = false }
        if inbox != before {
            scheduleSave()
            classifyNewFiles()
        }
    }

    /// Fills in suggestions for new files: Claude when it is on and signed in, otherwise a guess
    /// from the filename. Waits while a cue is armed or playing.
    func classifyNewFiles() {
        guard !isClassifying, !inbox.awaitingSuggestion.isEmpty,
              InboxGate.canClassify(showState: show.state, showMode: show.showMode)
        else { return }
        isClassifying = true
        // One batch per run. The tick starts the next only while the gate still allows it.
        let tracks = inbox.awaitingSuggestion.prefix(FileClassifier.batchSize).compactMap { library.track(id: $0.trackID) }
        let upcoming = upcomingItems()
        let categories = tagNames
        let useClaude = settings.llmEnabled
        let model = settings.llmModel
        let roots = scanRoots
        Task {
            defer { isClassifying = false }
            let facts = await Task.detached(priority: .utility) { tracks.map { Self.facts(for: $0, roots: roots) } }.value
            var suggestions: [UUID: FileSuggestion] = [:]
            // With Claude off, a guess is simply how files are filed, so the pop-up says no more than that.
            var note: String?
            if useClaude {
                do {
                    let classifier = FileClassifier(runner: try await claudeAccount(), model: model)
                    let purpose = "Filing \(facts.count) new \(facts.count == 1 ? "file" : "files")"
                    suggestions = try await usingClaude(purpose) {
                        try await classifier.classify(files: facts, categories: categories, upcoming: upcoming)
                    }
                } catch {
                    noteClaudeFailure(error)
                    note = error.localizedDescription
                }
            }
            for fact in facts {
                var suggestion = suggestions[fact.trackID]
                    ?? FileClassifier.fallback(fact, serviceItem: bestUpcomingItem(for: fact.trackID, among: upcoming), note: note ?? "Claude did not answer for this file.")
                // A guess comes from built-in names, which the operator may have renamed or deleted.
                if !suggestion.byClaude, !categories.contains(suggestion.category) { suggestion.category = "" }
                inbox.setSuggestion(suggestion, for: fact.trackID)
            }
            scheduleSave()
        }
    }

    /// Folder names only from inside the watched folder, so no account or home folder name reaches Claude.
    nonisolated private static func facts(for track: Track, roots: [String]) -> NewFileFacts {
        let file = track.bestFile() ?? track.files.first
        return NewFileFacts(
            trackID: track.id, filename: track.primaryFilename, folder: file.map { NewFileFacts.folder(of: $0.path, roots: roots) } ?? "",
            durationSec: track.durationSec, tags: track.bestFile().map { AudioTags.read(url: $0.url) } ?? [:]
        )
    }

    /// Items in the next few services that still need a file.
    private func upcomingItems() -> [UpcomingItem] {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        return plans
            .filter { ($0.sortDate ?? .distantFuture) >= cutoff }
            .prefix(4)
            .flatMap { plan in
                plan.playbackCues.filter { $0.trackID == nil }.map { cue in
                    UpcomingItem(
                        ref: ServiceItemRef(planID: plan.id, cueID: cue.id), service: plan.dates.isEmpty ? plan.title : plan.dates,
                        title: cue.title, arrangement: cue.arrangement
                    )
                }
            }
    }

    /// Without Claude, the name matcher picks an item only when it is fairly sure.
    private func bestUpcomingItem(for trackID: UUID, among items: [UpcomingItem]) -> ServiceItemRef? {
        guard let track = library.track(id: trackID) else { return nil }
        let scored = items.compactMap { item -> (ServiceItemRef, Double)? in
            guard let cue = serviceCue(item.ref), let top = Matcher.rank(cue: cue, tracks: [track], memory: memory).first else { return nil }
            return (item.ref, top.score)
        }
        return scored.filter { $0.1 >= 0.75 }.max { $0.1 < $1.1 }?.0
    }

    func serviceCue(_ ref: ServiceItemRef) -> ServiceCue? {
        plans.first { $0.id == ref.planID }?.cues.first { $0.id == ref.cueID }
    }

    func serviceItemLabel(_ ref: ServiceItemRef) -> String? {
        guard let plan = plans.first(where: { $0.id == ref.planID }), let cue = serviceCue(ref) else { return nil }
        return "\(plan.dates.isEmpty ? plan.title : plan.dates) · \(cue.title)"
    }

    var upcomingItemsForPicker: [UpcomingItem] { upcomingItems() }

    var newFilesCanAppear: Bool {
        InboxGate.canPresent(
            serviceLoaded: loadedPlanID != nil, showState: show.state, showMode: show.showMode,
            auditioning: auditionPositionSec != nil || cueBus.isPlaying, loadingService: isLoadingService
        )
    }

    /// Whether the New Files list shows now. Handled quietly, files wait in the sidebar until the
    /// operator clicks New Files.
    var showsNewFiles: Bool {
        guard !newFilesSnoozed, alert == nil, newFilesCanAppear, settings.hasChosenServiceSource, !showingNewService,
              !showingTagEditor, newTagTrackIDs == nil else { return false }
        guard settings.newFileHandling == .ask || reviewingNewFiles else { return false }
        // Opened by the operator, the list shows at once and fills in as Claude answers.
        return !inbox.ready.isEmpty || (reviewingNewFiles && !inbox.items.isEmpty)
    }

    func reviewNewFiles() {
        newFilesSnoozed = false
        reviewingNewFiles = true
    }

    func snoozeNewFiles() {
        newFilesSnoozed = true
        reviewingNewFiles = false
    }

    /// Sends library tracks through the New Files list, so Claude sorts files that were already in
    /// a folder when Cantor started watching it. A track a service uses is a playback already, so it
    /// stays out. A track asked about before is asked afresh.
    func sortWithClaude(_ ids: Set<UUID>) {
        guard !show.showMode else { return }
        let inUse = confirmedTrackIDs
        let chosen = library.playbackTracks.map(\.id).filter { ids.contains($0) && !inUse.contains($0) }
        guard !chosen.isEmpty else { return }
        for id in chosen {
            inbox.remove(id)
            newFileAnswers[id] = nil
        }
        inbox.add(chosen)
        reviewNewFiles()
        scheduleSave()
        classifyNewFiles()
    }

    /// The operator's answers from the New Files list, applied together. Matching a service item
    /// here is the operator confirming it. A track a service uses is never excluded from here.
    func applyNewFiles(_ answers: [NewFileAnswer]) {
        guard newFilesCanAppear, !answers.isEmpty else { return }
        let inUse = confirmedTrackIDs
        let waiting = Set(inbox.items.map(\.trackID))
        // Only items the list offers now: one Claude suggested may have passed while the file waited.
        let offered = Set(upcomingItems().map(\.ref))
        var tagsChanged = false
        var toCopy: [UUID] = []
        let suggestions = Dictionary(inbox.items.map { ($0.trackID, $0.suggestion) }, uniquingKeysWith: { a, _ in a })
        for answer in answers where waiting.contains(answer.trackID) && library.track(id: answer.trackID) != nil {
            // The operator turned a "not" into a playback. A suggestion accepted as it came stays
            // open to detection, so a stem whose set arrives later still leaves.
            let suggestion = suggestions[answer.trackID] ?? nil
            let judged = suggestion?.isPlayback == false
            inbox.remove(answer.trackID)
            newFileAnswers[answer.trackID] = nil
            guard answer.isPlayback else {
                if !inUse.contains(answer.trackID) { library.exclude(id: answer.trackID) }
                continue
            }
            let before = settings.tags
            let category = settings.addTag(answer.category) ?? ""
            tagsChanged = tagsChanged || settings.tags != before
            if !category.isEmpty {
                Self.tagLog.notice("New Files: added \(category, privacy: .public) on \(answer.title, privacy: .public)")
            }
            library.update(id: answer.trackID) { track in
                // The operator's own call, so stem detection leaves it alone from now on.
                if judged { track.keptByOperator = true }
                let title = answer.title.trimmingCharacters(in: .whitespacesAndNewlines)
                // A title left as suggested doesn't undo a rename made in the Library since.
                let renamedSince = answer.title == answer.startTitle && track.title != answer.trackTitle
                if !title.isEmpty, !renamedSince { track.title = title }
                if !category.isEmpty, !track.tags.contains(category) { track.tags.append(category) }
            }
            if let ref = answer.serviceItem, offered.contains(ref), let cue = serviceCue(ref), cue.trackID == nil, let track = library.track(id: answer.trackID) {
                confirm(planID: ref.planID, cue: cue, track: track)
            }
            if settings.copyPlaybacksToCantor { toCopy.append(answer.trackID) }
        }
        if tagsChanged { record("settings") { try settingsFile.save(settings) } }
        rankAllPlans()
        scheduleSave()
        queueCopies(toCopy)
    }

    /// The New Files list's copy checkbox, remembered for next time.
    func setCopyPlaybacksToCantor(_ on: Bool) {
        settings.copyPlaybacksToCantor = on
        record("settings") { try settingsFile.save(settings) }
    }

    // MARK: Tags

    /// Every tag added to tracks, and how, so a tag that seems to appear by itself can be traced.
    /// Read with `log show --predicate 'subsystem == "org.prcatlanta.Cantor" && category == "tags"'`.
    static let tagLog = Logger(subsystem: "org.prcatlanta.Cantor", category: "tags")

    /// The tags to offer: the operator's list, then any a track still has.
    var tagNames: [String] { PlaybackCategory.all(saved: settings.tags, libraryTags: library.allTags) }

    /// Adds a tag to the list, and to the tracks given. Returns the cleaned name.
    @discardableResult
    func addTag(_ name: String, to ids: Set<UUID> = []) -> String? {
        guard !show.showMode, let tag = settings.addTag(name) else { return nil }
        record("settings") { try settingsFile.save(settings) }
        if !ids.isEmpty {
            Self.tagLog.notice("New Tag: added \(tag, privacy: .public) on \(ids.compactMap { self.library.track(id: $0)?.title }, privacy: .public)")
        }
        for id in ids {
            updateTrack(id) { if !$0.tags.contains(tag) { $0.tags.append(tag) } }
        }
        return tag
    }

    /// Renames the tag everywhere, on excluded tracks too. Renaming onto another tag merges them.
    func renameTag(_ old: String, to name: String) {
        let new = FileClassifier.cleanCategory(name)
        // A tag deleted a moment ago, while its name was being edited, stays deleted.
        guard !show.showMode, !new.isEmpty, new != old, tagNames.contains(old) else { return }
        settings.renameTag(old, to: new)
        library.renameTag(old, to: new)
        if selection == .library(.tag(old)) { selection = .library(.tag(new)) }
        if simpleTag == old { simpleTag = new }
        record("settings") { try settingsFile.save(settings) }
        scheduleSave()
    }

    /// Takes the tag off the list and off every track. The tracks stay.
    func deleteTag(_ tag: String) {
        guard !show.showMode else { return }
        settings.tags.removeAll { $0 == tag }
        library.removeTag(tag)
        if selection == .library(.tag(tag)) { selection = .library(.all) }
        if simpleTag == tag { simpleTag = nil }
        record("settings") { try settingsFile.save(settings) }
        scheduleSave()
    }

    /// The operator's This Is a Playback, from the Excluded list.
    func keepTrack(_ id: UUID) {
        keepTracks([id])
    }

    // MARK: Actions on several tracks

    /// Not a Playback for each track. When a service uses one of them, the operator is asked first,
    /// since excluding takes it out of those services.
    func excludeTracks(_ ids: Set<UUID>, reason: String = "You chose Not a Playback") {
        guard !show.showMode, !ids.isEmpty else { return }
        let inUse = ids.intersection(confirmedTrackIDs)
        guard inUse.isEmpty else {
            pendingExclusion = PendingExclusion(trackIDs: ids, message: exclusionWarning(inUse), reason: reason)
            return
        }
        exclude(ids, reason: reason)
    }

    /// The other tracks offered as duplicates of this one, for Keep This One.
    func otherDuplicates(of id: UUID) -> Set<UUID> {
        Set(library.duplicateGroups.filter { $0.trackIDs.count > 1 && $0.trackIDs.contains(id) }.flatMap(\.trackIDs)).subtracting([id])
    }

    /// Keeps this track and excludes the others offered as its duplicates.
    func keepOnly(_ id: UUID) {
        guard !show.showMode, let track = library.track(id: id) else { return }
        let others = otherDuplicates(of: id)
        let name = StemDetector.sourceFile(track).map { "“\($0.filename)”" } ?? "“\(track.title)”"
        keepTracks([id])
        excludeTracks(others, reason: "Duplicate of \(name), which you kept")
    }

    /// Takes the tracks out of every service, then excludes them. In a synced service, items added by
    /// hand and removed items kept only for their file go, while Planning Center's items stay,
    /// unmatched. Items of a service built here are the operator's: they keep their title and notes
    /// and only lose the track.
    func confirmExclusion(_ pending: PendingExclusion) {
        pendingExclusion = nil
        guard !show.showMode else { return }
        if show.state.holdsHouseEngine, let id = show.activeCue?.track?.id, pending.trackIDs.contains(id) {
            alert = "That track is armed or playing. Stop it, then mark it Not a Playback."
            return
        }
        let uses = { (cue: ServiceCue) in cue.trackID.map(pending.trackIDs.contains) ?? false }
        for planIndex in plans.indices {
            if !plans[planIndex].isManual {
                plans[planIndex].cues.removeAll { uses($0) && ($0.isManual || $0.removedInPCO) }
            }
            for cueIndex in plans[planIndex].cues.indices where uses(plans[planIndex].cues[cueIndex]) {
                plans[planIndex].cues[cueIndex].trackID = nil
                plans[planIndex].cues[cueIndex].changedSinceConfirm = false
            }
        }
        markCuesChanged()
        exclude(pending.trackIDs, reason: pending.reason)
    }

    private func exclude(_ ids: Set<UUID>, reason: String) {
        for id in ids {
            library.exclude(id: id, reason: reason)
            inbox.remove(id)
        }
        rankAllPlans()
        scheduleSave()
    }

    private func exclusionWarning(_ inUse: Set<UUID>) -> String {
        let services = plans.filter { $0.cues.contains { $0.trackID.map(inUse.contains) ?? false } }
            .map { "\($0.dates.isEmpty ? $0.title : $0.dates) (\($0.serviceTypeName))" }
        let names = services.joined(separator: ", ")
        if inUse.count == 1, let title = inUse.first.flatMap({ library.track(id: $0)?.title }) {
            return "“\(title)” is used in \(names). Marking it Not a Playback takes it off \(services.count == 1 ? "that service" : "those services")."
        }
        return "\(inUse.count) of these tracks are used in \(names). Marking them Not a Playback takes them off \(services.count == 1 ? "that service" : "those services")."
    }

    func keepTracks(_ ids: Set<UUID>) {
        guard !show.showMode else { return }
        for id in ids { library.keep(id: id) }
        rankAllPlans()
        scheduleSave()
        analyzePending()
    }

    /// Adds the tag to every track, or removes it when every track already has it.
    func toggleTag(_ tag: String, on ids: Set<UUID>) {
        let tracks = ids.compactMap { library.track(id: $0) }
        let remove = !tracks.isEmpty && tracks.allSatisfy { $0.tags.contains(tag) }
        Self.tagLog.notice("Tag menu: \(remove ? "removed" : "added", privacy: .public) \(tag, privacy: .public) on \(tracks.map(\.title), privacy: .public)")
        for id in ids {
            updateTrack(id) { track in
                track.tags.removeAll { $0 == tag }
                if !remove { track.tags.append(tag) }
            }
        }
    }

    // MARK: Pre-service check

    func checkResults() -> [CheckIssue] {
        guard let plan = currentPlan else { return [] }
        let tracks = Dictionary(library.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let defaults = Set([AudioDevices.defaultDeviceUID(system: false), AudioDevices.defaultDeviceUID(system: true)].compactMap { $0 })
        return PreServiceCheck.run(CheckInput(
            plan: plan, tracks: tracks, residentTrackIDs: Set(resident.keys),
            residentLengths: resident.mapValues { ResidentLength(frames: $0.frames, sampleRate: $0.sampleRate) }, routing: settings.routing,
            availableDeviceUIDs: Set(devices.map(\.uid)),
            deviceOutputChannels: Dictionary(devices.map { ($0.uid, $0.outputChannels) }, uniquingKeysWith: { a, _ in a }),
            targetLUFS: settings.targetLUFS, defaultOutputUIDs: defaults,
            isOnBattery: PowerStatus.isOnBattery
        ))
    }

    func deviceName(_ uid: String?) -> String {
        guard let uid else { return "Not set" }
        return devices.first { $0.uid == uid }?.name ?? "Disconnected"
    }
}

/// Peak meter ballistics: instant attack, about 20 dB per second release.
struct MeterState {
    var left: Float = 0
    var right: Float = 0

    mutating func update(left newLeft: Float, right newRight: Float) {
        let release: Float = 0.926
        left = max(newLeft, left * release)
        right = max(newRight, right * release)
        if left < 0.0001 { left = 0 }
        if right < 0.0001 { right = 0 }
    }
}

/// Tracks to mark Not a Playback once the operator agrees to take them out of their services.
struct PendingExclusion: Identifiable {
    let id = UUID()
    let trackIDs: Set<UUID>
    let message: String
    var reason = "You chose Not a Playback"
}
