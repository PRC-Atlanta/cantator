import AppKit
import CantorCore
import Foundation
import Observation

/// App-level state: everything the views read, and the wiring between CantorCore's parts.
@MainActor
@Observable
final class AppModel {
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
    var isMatching = false
    var analyzingCount = 0
    var alert: String?
    var status: String?
    var makingLocal: Set<UUID> = []
    var unreadableFiles: [String] = []
    var systemSoundStuckOnHouse = false

    var houseMeter = MeterState()
    var cueMeter = MeterState()
    var auditionPositionSec: Double?

    let show: ShowController
    let cueBus = CueBus()

    @ObservationIgnored private let houseBus = HouseBus()
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
    @ObservationIgnored private var failedAnalysis = Set<UUID>()
    @ObservationIgnored private var cuesNeedRefresh = false
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var lastSaveError: String?

    private static func file<T>(_ name: String) -> JSONFile<T> {
        JSONFile(url: AppPaths.support.appendingPathComponent(name))
    }

    private let settingsFile: JSONFile<AppSettings> = AppModel.file("settings.json")
    private let libraryFile: JSONFile<Library> = AppModel.file("library.json")
    private let memoryFile: JSONFile<AliasMemory> = AppModel.file("aliases.json")
    private let plansFile: JSONFile<[ServicePlan]> = AppModel.file("services.json")
    private let cacheFile: JSONFile<HashCache> = AppModel.file("hash-cache.json")

    init() {
        var setAside: [String] = []
        let note = { (url: URL) in setAside.append(url.lastPathComponent) }
        settings = settingsFile.load(onQuarantine: note) ?? AppSettings()
        library = libraryFile.load(onQuarantine: note) ?? Library()
        memory = memoryFile.load(onQuarantine: note) ?? AliasMemory()
        plans = plansFile.load(onQuarantine: note) ?? []
        hashCache = cacheFile.load(onQuarantine: note) ?? HashCache()
        show = ShowController(house: houseBus, log: RunLog())
        houseBus.onLost = { [weak self] in self?.show.deviceLost() }
        show.onPlayed = { [weak self] track in
            self?.library.update(id: track.id) {
                $0.playCount += 1
                $0.lastPlayed = Date()
            }
            self?.scheduleSave()
        }
        applySettingsToShow()
        if !setAside.isEmpty {
            alert = "Some saved data could not be read and was set aside: \(setAside.joined(separator: ", "))"
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

        restartWatcher()
        rescan()
    }

    func prepareToQuit() {
        cueBus.stop()
        soundGuard.release()
        sleepGuard.release()
        saveNow()
    }

    private func handleSleep() {
        // Waking must always land in a silent, unarmed state.
        if show.state.holdsHouseEngine {
            show.deviceLost()
        }
        cueBus.stop()
    }

    private func tick() {
        show.tick()
        tickCount += 1
        if tickCount.isMultiple(of: 30) { show.checkDevice() }
        if cuesNeedRefresh { refreshLoadedCues() }
        houseMeter.update(left: show.peakLeft, right: show.peakRight)
        if let kernel = cueBus.kernel {
            let peaks = kernel.takePeaks()
            cueMeter.update(left: peaks.left, right: peaks.right)
            auditionPositionSec = Double(kernel.positionFrames) / kernel.buffer.sampleRate
            if kernel.phase == .finished { stopAudition() }
        } else {
            cueMeter.update(left: 0, right: 0)
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
    }

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        let previousFolders = settings.folders
        let previousRouting = settings.routing
        change(&settings)
        applySettingsToShow()
        if settings.routing != previousRouting {
            // An audition already playing could be on the device that just became the house.
            stopAudition()
        }
        syncSoundGuard()
        markCuesChanged()
        record { try settingsFile.save(settings) }
        if settings.folders != previousFolders {
            restartWatcher()
            rescan()
        }
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
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        record { try libraryFile.save(library) }
        record { try memoryFile.save(memory) }
        record { try plansFile.save(plans) }
        try? cacheFile.save(hashCache)
    }

    private func record(_ save: () throws -> Void) {
        do {
            try save()
            lastSaveError = nil
        } catch {
            // Say so once per failure, not on every debounced save.
            if lastSaveError != error.localizedDescription {
                alert = "Could not save: \(error.localizedDescription)"
            }
            lastSaveError = error.localizedDescription
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

    func rescan() {
        guard !isScanning else { return }
        isScanning = true
        let roots = scanRoots
        var cache = hashCache
        Task {
            let result = await Task.detached(priority: .utility) { () -> (ScanResult, HashCache) in
                let result = FolderScanner.scan(roots: roots, cache: &cache)
                return (result, cache)
            }.value
            hashCache = result.1
            let replaced = library.merge(scan: result.0.files, defaultFadeOutSec: settings.defaultFadeOutSec)
            remapCues(replaced)
            unreadableFiles = result.0.unreadable
            isScanning = false
            scheduleSave()
            if result.0.hasUnsettledFiles { scheduleRescan(after: 3) }
            analyzePending()
        }
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

    private func analyzePending() {
        guard analysisTask == nil else { return }
        analysisTask = Task { [weak self] in
            while let self, let track = self.library.tracks.first(where: { self.needsAnalysis($0) }), let file = track.bestFile() {
                self.analyzingCount = self.library.tracks.filter { self.needsAnalysis($0) }.count
                let id = track.id
                let url = file.url
                let analysis = await Task.detached(priority: .background) { () -> TrackAnalysis? in
                    guard let buffer = try? PCMDecoder.decode(url: url) else { return nil }
                    return TrackAnalyzer.analyze(buffer)
                }.value
                guard let analysis else {
                    // Leave it unanalyzed so Check still reports it.
                    self.failedAnalysis.insert(id)
                    continue
                }
                self.library.update(id: id) { track in
                    track.integratedLUFS = analysis.integratedLUFS ?? -70
                    track.truePeakDb = analysis.truePeakDb
                    track.suggestedEndSec = analysis.suggestedEndSec
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
        !track.isAnalyzed && track.isLocal && !failedAnalysis.contains(track.id)
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
        markCuesChanged()
        scheduleSave()
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
        Task {
            do {
                var buffer = resident[track.id] ?? auditionCache[track.id]
                if buffer == nil {
                    let url = file.url
                    buffer = try await Task.detached(priority: .userInitiated) { try PCMDecoder.decode(url: url) }.value
                    auditionCache = [track.id: buffer!]
                }
                guard let buffer else { return }
                let parameters = PlaybackParameters(track: track, sampleRate: buffer.sampleRate, frames: buffer.frames, gainDb: gainDb(for: track))
                try cueBus.audition(
                    trackID: track.id, buffer: buffer, parameters: parameters,
                    from: fromSec.map { Int($0 * buffer.sampleRate) }, routing: settings.routing
                )
            } catch {
                alert = error.localizedDescription
            }
        }
    }

    func stopAudition() {
        cueBus.stop()
        auditionPositionSec = nil
    }

    // MARK: Planning Center

    func hasPCOCredentials() -> Bool {
        Keychain.read(.pcoAppID) != nil && Keychain.read(.pcoSecret) != nil
    }

    func refreshPlans() {
        guard !isSyncing else { return }
        guard let appID = Keychain.read(.pcoAppID), let secret = Keychain.read(.pcoSecret) else {
            alert = "Add your Planning Center token in Settings."
            return
        }
        isSyncing = true
        Task {
            defer { isSyncing = false }
            do {
                let client = PCOClient(appID: appID, secret: secret)
                let fresh = try await client.fetchUpcomingPlans(memory: memory)
                plans = ServicePlan.applySync(existing: plans, fresh: fresh, loadedID: loadedPlanID)
                rankAllPlans()
                markCuesChanged()
                scheduleSave()
            } catch {
                alert = "\(error.localizedDescription) Using saved plans."
            }
        }
    }

    func rankAllPlans() {
        for planIndex in plans.indices {
            for cueIndex in plans[planIndex].cues.indices where plans[planIndex].cues[cueIndex].needsPlayback {
                let cue = plans[planIndex].cues[cueIndex]
                plans[planIndex].cues[cueIndex].candidates = Matcher.rank(cue: cue, tracks: library.tracks, memory: memory)
            }
        }
    }

    func runAIMatch(planID: String) {
        guard settings.llmEnabled, let key = Keychain.read(.anthropicAPIKey) else {
            alert = "Add a Claude API key in Settings to use AI matching. String matching still works without one."
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
        let tiebreaker = LLMTiebreaker(apiKey: key, model: settings.llmModel)
        Task {
            defer { isMatching = false }
            do {
                let results = try await tiebreaker.resolve(cues: cues, tracks: tracks)
                guard let index = plans.firstIndex(where: { $0.id == planID }) else { return }
                for cueIndex in plans[index].cues.indices {
                    if let updated = results[plans[index].cues[cueIndex].id] {
                        plans[index].cues[cueIndex].candidates = updated
                    }
                }
                scheduleSave()
            } catch {
                alert = error.localizedDescription
            }
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
        }
        if let contentID = track.contentID { memory.remember(cue, contentID: contentID) }
        if let song = cue.songID {
            library.update(id: track.id) { value in
                if !value.pcoSongIDs.contains(song) { value.pcoSongIDs.append(song) }
            }
        }
        scheduleSave()
    }

    func clearMatch(planID: String, cue: ServiceCue) {
        updateCue(planID: planID, cueID: cue.id) { $0.trackID = nil }
    }

    func setNeeded(planID: String, cue: ServiceCue, needed: Bool) {
        updateCue(planID: planID, cueID: cue.id) { $0.needsPlayback = needed }
        memory.rememberNeeds(cue, needed: needed)
        rankAllPlans()
        scheduleSave()
    }

    func addManualCue(planID: String, track: Track) {
        guard let index = plans.firstIndex(where: { $0.id == planID }) else { return }
        var cue = ServiceCue(
            id: "manual-\(UUID().uuidString)", position: (plans[index].cues.map(\.position).max() ?? 0) + 1,
            title: track.title, isManual: true
        )
        cue.trackID = track.id
        plans[index].cues.append(cue)
        markCuesChanged()
        scheduleSave()
    }

    // MARK: Service load

    var loadedPlan: ServicePlan? { plans.first { $0.id == loadedPlanID } }

    /// Decodes every confirmed cue into RAM, then holds sleep and system sound for the service.
    /// Each file is checked against the audio that was confirmed, in case it changed since the last scan.
    func loadService(planID: String) {
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
            let decoded = await Task.detached(priority: .userInitiated) { () -> ([UUID: PCMBuffer], [String]) in
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
            }.value

            resident = decoded.0
            loadedPlanID = planID
            show.load(cues: showCues())
            sleepGuard.engage()
            syncSoundGuard()
            isLoadingService = false
            if !decoded.1.isEmpty { alert = decoded.1.joined(separator: "\n") }
        }
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
        if loadedPlanID != nil { cuesNeedRefresh = true }
    }

    /// Show must play what the operator last saved. Edits wait until no cue is engaged.
    private func refreshLoadedCues() {
        if show.refresh(cues: showCues()) { cuesNeedRefresh = false }
    }

    func unloadService() {
        guard !show.state.holdsHouseEngine else { return }
        show.setShowMode(false)
        show.load(cues: [])
        resident = [:]
        loadedPlanID = nil
        sleepGuard.release()
        syncSoundGuard()
    }

    // MARK: Pre-service check

    func checkResults() -> [CheckIssue] {
        guard let plan = loadedPlan ?? plans.first else { return [] }
        let tracks = Dictionary(library.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let defaults = Set([AudioDevices.defaultDeviceUID(system: false), AudioDevices.defaultDeviceUID(system: true)].compactMap { $0 })
        return PreServiceCheck.run(CheckInput(
            plan: plan, tracks: tracks, residentTrackIDs: Set(resident.keys), routing: settings.routing,
            availableDeviceUIDs: Set(devices.map(\.uid)), targetLUFS: settings.targetLUFS, defaultOutputUIDs: defaults,
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
