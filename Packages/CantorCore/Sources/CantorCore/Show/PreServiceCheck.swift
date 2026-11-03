import Foundation

public enum CheckSeverity: Int, Comparable, Sendable {
    case ok, warning, blocking
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public enum CheckKind: String, Sendable {
    case unmatched, fileMissing, notDownloaded, notInMemory, noEndPoint, notAnalyzed, gainCapped, cueChanged
    case emptyRange, removedInPCO
    case noHouseOutput, houseOutputMissing, noCueOutput, cueOutputMissing, sameOutput
    case systemSoundOnHouse, staleSync, onBattery, focusReminder, noCues, housePairMissing, cuePairMissing
}

public struct CheckIssue: Identifiable, Equatable, Sendable {
    public var id: String { kind.rawValue + (cueID ?? "") }
    public var severity: CheckSeverity
    public var kind: CheckKind
    public var cueID: CueID?
    public var title: String
    public var action: String
}

/// A loaded buffer's length, so Check sees the same range Arm will play.
public struct ResidentLength: Equatable, Sendable {
    public var frames: Int
    public var sampleRate: Double

    public init(frames: Int, sampleRate: Double) {
        self.frames = frames
        self.sampleRate = sampleRate
    }
}

public struct CheckInput: Sendable {
    public var plan: ServicePlan
    public var tracks: [UUID: Track]
    public var residentTrackIDs: Set<UUID>
    /// Lengths of the loaded buffers. A track missing here is checked against its saved duration.
    public var residentLengths: [UUID: ResidentLength]
    public var routing: OutputRouting
    public var availableDeviceUIDs: Set<String>
    /// Output counts of the connected devices, so a saved pair can be checked against them.
    public var deviceOutputChannels: [String: Int]
    public var targetLUFS: Double
    public var defaultOutputUIDs: Set<String>
    public var isOnBattery: Bool
    public var now: Date

    public init(
        plan: ServicePlan, tracks: [UUID: Track], residentTrackIDs: Set<UUID>, residentLengths: [UUID: ResidentLength] = [:],
        routing: OutputRouting, availableDeviceUIDs: Set<String>, deviceOutputChannels: [String: Int] = [:], targetLUFS: Double = -18,
        defaultOutputUIDs: Set<String> = [], isOnBattery: Bool = false, now: Date = Date()
    ) {
        self.deviceOutputChannels = deviceOutputChannels
        self.plan = plan
        self.tracks = tracks
        self.residentTrackIDs = residentTrackIDs
        self.residentLengths = residentLengths
        self.routing = routing
        self.availableDeviceUIDs = availableDeviceUIDs
        self.targetLUFS = targetLUFS
        self.defaultOutputUIDs = defaultOutputUIDs
        self.isOnBattery = isOnBattery
        self.now = now
    }
}

public enum PreServiceCheck {
    public static let staleAfter: TimeInterval = 12 * 3600

    public static func run(_ input: CheckInput) -> [CheckIssue] {
        var issues: [CheckIssue] = []
        let add = { (severity: CheckSeverity, kind: CheckKind, cue: ServiceCue?, title: String, action: String) in
            issues.append(CheckIssue(severity: severity, kind: kind, cueID: cue?.id, title: title, action: action))
        }

        let cues = input.plan.playbackCues
        if cues.isEmpty {
            add(.warning, .noCues, nil, "This service has no playback cues", "Mark the items that need a track in Service.")
        }

        for cue in cues {
            let name = cue.title
            guard let trackID = cue.trackID, let track = input.tracks[trackID] else {
                add(.blocking, .unmatched, cue, "\(name): no file confirmed", "Confirm a match in Service.")
                continue
            }
            if cue.removedInPCO {
                add(.warning, .removedInPCO, cue, "\(name): removed in Planning Center", "Check the order with the worship leader, or unconfirm it in Service.")
            } else if cue.changedSinceConfirm {
                add(.warning, .cueChanged, cue, "\(name): changed in Planning Center after you confirmed", "Review the match in Service.")
            }
            let resident = input.residentTrackIDs.contains(trackID)
            if !track.isLocal {
                // A track already in memory still plays. The file only matters for the next load.
                if resident {
                    let kind: CheckKind = track.hasCloudOnlyCopy ? .notDownloaded : .fileMissing
                    add(.warning, kind, cue, "\(name): file is gone, but the loaded copy will play", "Find the file before the next Load Service.")
                } else if track.hasCloudOnlyCopy {
                    add(.blocking, .notDownloaded, cue, "\(name): not downloaded", "Use Make Local to copy it to this Mac.")
                } else {
                    add(.blocking, .fileMissing, cue, "\(name): file is missing", "Find the file or choose another in Service.")
                }
            } else if !resident {
                add(.blocking, .notInMemory, cue, "\(name): not loaded", "Use Load Service to load it into memory.")
            }
            if isEmptyRange(track, length: input.residentLengths[trackID]) {
                add(.blocking, .emptyRange, cue, "\(name): nothing to play between start and end", "Fix the start and end points in Library.")
            }
            if track.endSec == nil {
                add(.warning, .noEndPoint, cue, "\(name): no end point set", "Set or accept an end point in Library.")
            }
            if let lufs = track.integratedLUFS, let peak = track.truePeakDb {
                if LoudnessMeter.gain(lufs: lufs, truePeakDb: peak, targetLUFS: input.targetLUFS).capped {
                    add(.warning, .gainCapped, cue, "\(name): will play quieter than the others", "Peak limits gain. Add level at the console for this cue.")
                }
            } else {
                add(.warning, .notAnalyzed, cue, "\(name): level not checked", "Wait for analysis or run Analyze in Library.")
            }
        }

        let routing = input.routing
        if let house = routing.houseDeviceUID {
            if !input.availableDeviceUIDs.contains(house) {
                add(.blocking, .houseOutputMissing, nil, "House output is not connected", "Reconnect the interface or choose another output in Settings.")
            } else if let channels = input.deviceOutputChannels[house],
                      !OutputRouting.pairFits(firstChannel: routing.houseFirstChannel, deviceChannels: channels) {
                add(.blocking, .housePairMissing, nil, "House outputs \(routing.houseFirstChannel + 1)-\(routing.houseFirstChannel + 2) are not on this device",
                    "Choose the house device again in Settings > Outputs.")
            }
        } else {
            add(.blocking, .noHouseOutput, nil, "No house output selected", "Choose one in Settings.")
        }
        if let cue = routing.cueDeviceUID {
            if !input.availableDeviceUIDs.contains(cue) {
                add(.warning, .cueOutputMissing, nil, "Cue output is not connected", "Reconnect headphones or choose another output in Settings.")
            } else if let channels = input.deviceOutputChannels[cue],
                      !OutputRouting.pairFits(firstChannel: routing.cueFirstChannel, deviceChannels: channels) {
                add(.warning, .cuePairMissing, nil, "Cue outputs \(routing.cueFirstChannel + 1)-\(routing.cueFirstChannel + 2) are not on this device",
                    "Choose the cue device again in Settings > Outputs.")
            }
        } else {
            add(.warning, .noCueOutput, nil, "No cue output selected", "Choose one in Settings to preview tracks.")
        }
        if routing.isSameDevice {
            add(.blocking, .sameOutput, nil, "House and cue use the same device", "Choose a different cue output in Settings.")
        }
        if let house = routing.houseDeviceUID, input.defaultOutputUIDs.contains(house) {
            add(.warning, .systemSoundOnHouse, nil, "macOS sounds can reach the house output", "Connect a second output so Cantator can move alerts off the house.")
        }

        if !input.plan.isManual, !input.plan.cues.allSatisfy(\.isManual), input.now.timeIntervalSince(input.plan.syncedAt) > staleAfter {
            add(.warning, .staleSync, nil, "Planning Center data is more than 12 hours old", "Refresh while you have internet.")
        }
        if input.isOnBattery {
            add(.warning, .onBattery, nil, "Running on battery", "Plug in the Mac. Keep the lid open: closing it sleeps the Mac.")
        }
        add(.ok, .focusReminder, nil, "Turn on Do Not Disturb", "macOS does not let apps set a Focus. Turn it on in Control Center.")

        return issues.sorted { $0.severity > $1.severity }
    }

    /// The same test Arm makes. Without a loaded buffer, the saved duration stands in for its length.
    static func isEmptyRange(_ track: Track, length: ResidentLength?) -> Bool {
        let measured = length ?? (track.durationSec > 0 && track.sampleRate > 0
            ? ResidentLength(frames: Int((track.durationSec * track.sampleRate).rounded()), sampleRate: track.sampleRate) : nil)
        guard let measured, measured.sampleRate > 0 else {
            return track.endSec.map { $0 <= track.startSec } ?? false
        }
        let parameters = PlaybackParameters(track: track, sampleRate: measured.sampleRate, frames: measured.frames, gainDb: 0)
        return parameters.startFrame >= parameters.endFrame
    }
}
