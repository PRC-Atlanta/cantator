#if DEBUG
import AppKit
import AVFoundation
import CantorCore

/// Debug-only end-to-end run, started with CANTOR_SELF_CHECK=<directory>. It walks the real flow
/// through AppModel, records each step and saves images of its own window. Only for use with a
/// throwaway home (CFFIXED_USER_HOME) and virtual output devices.
@MainActor
enum SelfCheck {
    static func runIfRequested(model: AppModel) {
        guard let directory = ProcessInfo.processInfo.environment["CANTOR_SELF_CHECK"] else { return }
        Task { await run(model: model, directory: URL(fileURLWithPath: directory)) }
    }

    private static func run(model: AppModel, directory: URL) async {
        var log: [String] = []
        let note = { (line: String) in log.append(line) }
        let show = model.show
        NSApp.windows.first?.setFrame(NSRect(x: 40, y: 40, width: 1360, height: 860), display: true)

        await waitUntil { !model.isScanning && model.analyzingCount == 0 && model.library.tracks.count >= 3 && model.library.tracks.allSatisfy(\.isAnalyzed) }
        note("tracks \(model.library.tracks.count), duplicate groups \(model.library.duplicateGroups.count)")
        for track in model.library.tracks {
            note("  \(track.title) lufs \(track.integratedLUFS ?? 0) gain \(model.gainDb(for: track)) files \(track.files.count)")
        }

        model.rankAllPlans()
        guard let plan = model.plans.first else { return finish(log, directory) }
        for cue in plan.playbackCues {
            note("rank \(cue.title): \(model.plans[0].cues.first { $0.id == cue.id }?.candidates.first?.score ?? 0) \(MatchBand(candidates: model.plans[0].cues.first { $0.id == cue.id }?.candidates ?? []).rawValue)")
        }
        model.selection = .plan(plan.id)
        await snapshot("service", directory)

        model.selection = .check
        await snapshot("check-before", directory)

        for cue in model.plans[0].playbackCues {
            if let id = cue.candidates.first?.trackID, let track = model.library.track(id: id) {
                model.confirm(planID: plan.id, cue: cue, track: track)
                model.updateTrack(id) { $0.endSec = ($0.suggestedEndSec ?? $0.durationSec) - 5 }
            }
        }
        model.selection = .library(.all)
        await snapshot("library", directory)

        model.loadService(planID: plan.id)
        await waitUntil { !model.isLoadingService && show.cues.count == 3 }
        note("loaded \(show.cues.count) cues, resident \(model.resident.count)")
        model.selection = .check
        await snapshot("check-after", directory)
        for issue in model.checkResults() { note("  check \(issue.severity) \(issue.kind.rawValue)") }

        // A file arriving during a service waits: Cantor files it, but the pop-up must not appear.
        if let folder = model.settings.folders.first {
            writeTone(to: URL(fileURLWithPath: folder).appendingPathComponent("Sanctuary Choir - Joyful Joyful (practice mix).wav"))
        }
        await waitUntil(timeout: 40) { !model.inbox.ready.isEmpty }
        note("new files during service: \(model.inbox.items.count), suggestion \(model.inbox.ready.first?.suggestion.map { "\($0.title) / \($0.category) / claude \($0.byClaude) / \($0.note ?? "")" } ?? "none")")
        note("pop-up during service: \(model.newFileToPresent == nil ? "held" : "SHOWN")")

        model.selection = .show
        show.go()
        note("GO with nothing armed: \(show.state)")
        show.setShowMode(true)
        await snapshot("show-idle", directory)
        let refusal = show.arm()
        note("arm: \(refusal?.message ?? "ok"), \(show.state)")
        show.go()
        note("GO inside dwell: \(show.state)")
        await snapshot("show-armed", directory)
        show.go()
        note("GO: \(show.state)")
        try? await Task.sleep(for: .seconds(4))
        note("position after 4 s: \(show.positionSec)")
        await snapshot("show-live", directory)
        show.hold()
        await snapshot("show-hold", directory)
        try? await Task.sleep(for: .seconds(0.5))
        show.go()
        try? await Task.sleep(for: .seconds(1))
        show.fadeOut()
        try? await Task.sleep(for: .seconds(1))
        await snapshot("show-fading", directory)
        try? await Task.sleep(for: .seconds(2.5))
        note("after fade: \(show.state), next \(show.nextIndex)")

        show.arm()
        try? await Task.sleep(for: .seconds(0.4))
        show.go()
        try? await Task.sleep(for: .seconds(1))
        show.panicPressed()
        note("panic: \(show.state)")
        await snapshot("show-panic", directory)
        try? await Task.sleep(for: .seconds(2))
        note("after panic: \(show.state)")

        show.arm()
        try? await Task.sleep(for: .seconds(0.4))
        show.go()
        try? await Task.sleep(for: .seconds(0.5))
        show.deviceLost()
        note("device lost: \(show.state), \(show.notice ?? "")")
        await snapshot("show-fault", directory)
        show.acknowledgeFault()

        model.updateSettings { $0.appearance = "light" }
        show.arm()
        await snapshot("show-armed-light", directory)
        show.disarm()

        model.updateSettings { $0.appearance = "dark" }
        model.unloadService()
        model.selection = .library(.all)
        await waitUntil { model.newFileToPresent != nil }
        note("pop-up after unload: \(model.newFileToPresent == nil ? "held" : "shown")")
        await snapshotSheet("new-file", directory)
        if let item = model.newFileToPresent, let suggestion = item.suggestion {
            model.acceptNewFile(item.trackID, title: suggestion.title, category: suggestion.category, serviceItem: nil, copyToCantor: false)
            let track = model.library.track(id: item.trackID)
            note("accepted: \(track?.title ?? "?") tags \(track?.tags ?? []), inbox \(model.inbox.items.count)")
        }
        finish(log, directory)
    }

    private static func finish(_ log: [String], _ directory: URL) {
        try? log.joined(separator: "\n").write(to: directory.appendingPathComponent("self-check.txt"), atomically: true, encoding: .utf8)
        exit(0)
    }

    private static func waitUntil(timeout: Double = 30, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func writeTone(to url: URL) {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let frames = AVAudioFrameCount(44_100 * 20)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        for channel in 0..<2 {
            let samples = buffer.floatChannelData![channel]
            for n in 0..<Int(frames) { samples[n] = 0.2 * sinf(2 * .pi * 349.2 * Float(n) / 44_100) }
        }
        let partial = url.deletingLastPathComponent().appendingPathComponent(".incoming.wav")
        do {
            let file = try AVAudioFile(forWriting: partial, settings: format.settings)
            try file.write(from: buffer)
        } catch {
            return
        }
        try? FileManager.default.moveItem(at: partial, to: url)
    }

    private static func snapshotSheet(_ name: String, _ directory: URL) async {
        try? await Task.sleep(for: .milliseconds(800))
        guard let sheet = NSApp.windows.first(where: { $0.attachedSheet != nil })?.attachedSheet,
              let view = sheet.contentView?.superview,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private static func snapshot(_ name: String, _ directory: URL) async {
        try? await Task.sleep(for: .milliseconds(600))
        guard let frame = NSApp.windows.first(where: { $0.isVisible })?.contentView?.superview else { return }
        guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
#endif
