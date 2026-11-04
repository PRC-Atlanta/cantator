import CantorCore
import SwiftUI

struct ShowView: View {
    /// The narrowest cue list, its divider and the narrowest current cue panel.
    static let minWidth: CGFloat = 240 + 1 + CurrentCuePanel.minWidth

    @Environment(AppModel.self) private var model

    var body: some View {
        let show = model.show
        FullShowView()
            .frame(minWidth: Self.minWidth)
        .background(Theme.showBackground)
        .navigationTitle(model.loadedPlan.map { $0.dates.isEmpty ? $0.title : $0.dates } ?? "Show")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: Binding(get: { show.showMode }, set: { show.setShowMode($0) })) {
                    Label("Show Mode", systemImage: show.showMode ? "lock.fill" : "lock.open")
                        .labelStyle(.titleAndIcon)
                }
                .toggleStyle(.button)
                .disabled((show.cues.isEmpty || model.isLoadingService) && !show.showMode)
                .help("Show Mode locks editing, except the EQ, and shows the program in the sidebar (Command-Shift-L)")

                if model.loadedPlanID != nil {
                    Button("Unload") { model.unloadService() }
                        .disabled(show.showMode || show.state.holdsHouseEngine)
                        .help("Release memory, allow sleep and restore macOS sound outputs")
                }
            }
        }
    }
}

/// The Advanced view: the cue list with its pointer, the current cue's waveform, EQ, readouts and
/// meters, and every key.
private struct FullShowView: View {
    var body: some View {
        VStack(spacing: 0) {
            StateBar()
            Divider()
            GeometryReader { geometry in
                // The meters give up width first, then the cue list.
                let listWidth = min(320, max(240, geometry.size.width - 1 - CurrentCuePanel.minWidth))
                let meterSpace = geometry.size.width - 1 - listWidth - CurrentCuePanel.widthWithoutMeters
                HStack(spacing: 0) {
                    CueListPanel()
                        .frame(width: listWidth)
                    Divider()
                    CurrentCuePanel(meterWidth: min(190, max(110, meterSpace / 2)))
                }
            }
            Divider()
            KeyLegend()
        }
    }
}

/// Shared with the Simple Show view.
struct StateBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        let show = model.show
        let style = StateStyle(show.state)
        let foreground: Color = style.color == nil ? .secondary : .black
        HStack(spacing: 18) {
            Label(style.word, systemImage: style.symbol)
                .font(.system(size: 40, weight: .heavy))
                .labelStyle(.titleAndIcon)
                .frame(minWidth: 250, alignment: .leading)
            Text(model.frontCue?.title ?? (model.isSimple ? "No song picked" : "No service loaded"))
                .font(.system(size: 22, weight: .semibold))
                .lineLimit(1)
            Spacer()
            if let cue = model.frontCue, let track = cue.track {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("REMAINING").font(.system(size: 10, weight: .semibold)).opacity(0.7)
                    Text(TimeText.tenths(CurrentCuePanel.remaining(track, show: show)))
                        .font(.system(size: 44, weight: .medium, design: .monospaced))
                        .foregroundStyle(style.color == nil ? Color.primary : .black)
                        .contentTransition(.identity)
                        .monospacedDigit()
                }
                // The time is never cut short; the title gives way first in the narrower Simple pane.
                .fixedSize()
                .accessibilityElement(children: .combine)
            }
            if activeState != .key, show.state.holdsHouseEngine {
                Label("KEYS NOT FOCUSED", systemImage: "keyboard.badge.ellipsis")
                    .font(.system(size: 15, weight: .bold))
            }
            if let since = show.armedSince, case .armed = show.state {
                Text(since, style: .timer)
                    .font(.system(size: 20, weight: .medium, design: .monospaced))
                    .help("Time armed")
            }
            VStack(alignment: .trailing, spacing: 2) {
                Label(model.deviceName(model.settings.routing.houseDeviceUID), systemImage: "hifispeaker.2")
                if model.isSimple {
                    Label("Simple view", systemImage: "square.grid.2x2")
                } else {
                    Label(show.showMode ? "Show Mode on" : "Show Mode off", systemImage: show.showMode ? "lock.fill" : "lock.open")
                }
            }
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .fixedSize()
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 20)
        .frame(height: 76)
        // Kept inside the safe area, so the state color ends at the sidebar instead of running under it.
        .background(style.color ?? EQTheme.chrome, ignoresSafeAreaEdges: [])
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }
}

private struct CueListPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let show = model.show
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(show.cues.enumerated()), id: \.element.id) { index, cue in
                        CueRow(index: index, cue: cue).id(cue.id)
                        Divider()
                    }
                }
            }
            .onChange(of: show.nextIndex) { _, index in
                if show.cues.indices.contains(index) { proxy.scrollTo(show.cues[index].id) }
            }
        }
        .overlay {
            if show.cues.isEmpty {
                ContentUnavailableView(
                    "No Service Loaded", systemImage: "list.bullet.rectangle",
                    description: Text("Open a service, give each item its track, then choose Load Service.")
                )
            }
        }
        .background(Theme.panel)
    }
}

/// A row has no tap action. Only the arrow keys move the pointer, so nothing here can start sound.
private struct CueRow: View {
    @Environment(AppModel.self) private var model
    let index: Int
    let cue: ShowCue

    var body: some View {
        let show = model.show
        let isActive = show.state.cueID == cue.id
        let isPointed = show.nextIndex == index
        let style = StateStyle(isActive ? show.state : .idle)
        HStack(spacing: 10) {
            Image(systemName: isActive ? style.symbol : (isPointed ? "arrowtriangle.right.fill" : "circle"))
                .foregroundStyle(isActive ? (style.color ?? Color.secondary) : (isPointed ? Color.primary : Color.secondary))
                .font(.system(size: isPointed || isActive ? 16 : 7))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(cue.title)
                    .font(.system(size: 15, weight: isPointed || isActive ? .semibold : .regular))
                    .lineLimit(1)
                Text(cue.track?.primaryFilename ?? "No file")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !cue.isPlayable {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.armed).help("Not loaded")
            } else if let track = cue.track {
                Text(TimeText.plain((track.endSec ?? track.durationSec) - track.startSec))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background(isPointed ? Color.primary.opacity(0.07) : .clear)
    }
}

private struct CurrentCuePanel: View {
    /// The transport buttons, which never shrink, with the row's spacing and the panel's padding.
    static let widthWithoutMeters: CGFloat = 670
    static let minWidth: CGFloat = widthWithoutMeters + 2 * 110

    @Environment(AppModel.self) private var model
    let meterWidth: CGFloat

    private var cue: ShowCue? { model.show.activeCue ?? model.show.pointedCue }

    var body: some View {
        let show = model.show
        VStack(alignment: .leading, spacing: 12) {
            if let cue, let track = cue.track {
                ShowWaveform(track: track)
                    .frame(height: 110)
                    .f6Panel()
                // The track's EQ in full. Edits apply the next time the cue is armed; Show Mode locks it.
                EQEditor(trackID: track.id, graphMinHeight: 120)
                    .frame(maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                HStack(alignment: .firstTextBaseline, spacing: 22) {
                    F6Readout("FADE", "\(String(format: "%.1f", track.fadeOutSec)) s")
                    F6Readout("GAIN", TimeText.decibels(cue.gainDb))
                    F6Readout("END", track.endSec == nil ? "file end" : TimeText.tenths(track.endSec ?? 0))
                    if let resume = show.resumeSec, show.state != .idle || show.pointedCue?.id == cue.id {
                        F6Readout("STARTS AT", TimeText.tenths(resume), color: Theme.armed)
                    }
                    Spacer()
                }
                if !cue.notes.isEmpty {
                    Text(cue.notes).font(.system(size: 14)).foregroundStyle(EQTheme.label).lineLimit(2)
                }
            } else {
                Spacer()
            }
            NextCueLine()
            HStack(alignment: .bottom, spacing: 20) {
                TransportButtons()
                Spacer()
                MeterGroup(title: "HOUSE", meter: model.houseMeter, width: meterWidth)
                MeterGroup(title: "CUE", meter: model.cueMeter, width: meterWidth)
            }
        }
        .padding(18)
        .background(EQTheme.chrome)
        // The F6 palette is always dark, like the EQ window.
        .environment(\.colorScheme, .dark)
    }

    /// What is left of the cue: live while it plays, otherwise from its start to its end.
    static func remaining(_ track: Track, show: ShowController) -> Double {
        if show.state.holdsHouseEngine { return show.remainingSec }
        return (track.endSec ?? track.durationSec) - track.startSec
    }
}

/// A label over a value, as under the F6's knobs.
private struct F6Readout: View {
    let title: String
    let value: String
    var color = EQTheme.passes

    init(_ title: String, _ value: String, color: Color = EQTheme.passes) {
        self.title = title
        self.value = value
        self.color = color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.white.opacity(0.75))
            Text(value).font(.system(size: 15, weight: .medium, design: .monospaced)).foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    /// The F6's slate panel behind the waveform.
    func f6Panel() -> some View {
        background(LinearGradient(colors: [EQTheme.graphTop, EQTheme.graphBottom], startPoint: .top, endPoint: .bottom))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Shared with the Simple Show view.
struct NextCueLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let show = model.show
        let upcoming = show.state.holdsHouseEngine ? show.upcomingCue : (show.cues.indices.contains(show.nextIndex + 1) ? show.cues[show.nextIndex + 1] : nil)
        HStack(spacing: 8) {
            Text("NEXT").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Text(upcoming?.title ?? "End of list").font(.system(size: 18, weight: .medium)).lineLimit(1)
            if let notice = show.notice {
                Spacer()
                Label(notice, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.armed).font(.system(size: 14, weight: .medium))
            }
            if let alert = model.alert {
                Spacer()
                Label(alert, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.armed)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(2)
                    .help(alert)
                Button("Dismiss") { model.alert = nil }
                    .buttonStyle(.borderless)
                    .hoverHighlight(outset: 3)
                    .focusable(false)
            }
        }
    }
}

private struct TransportButtons: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let show = model.show
        HStack(spacing: 8) {
            control("Arm", "A", show.state == .idle) { model.arm() }
            // Also clears a mid-track start while idle, like D.
            control("Disarm", "D", isArmedOrHeld || show.resumeSec != nil) { show.disarm() }
            Spacer().frame(width: 34)
            control("GO", "Space", isArmedOrHeld) { show.go() }
            control("Hold", "P", isLive) { show.hold() }
            control("Fade", "F", isLive) { show.fadeOut() }
            Spacer().frame(width: 34)
            control("Panic", "Esc", show.state.holdsHouseEngine) { show.panicPressed() }
            if case .faulted = show.state {
                Button("Acknowledge") { show.acknowledgeFault() }.controlSize(.large)
            }
        }
    }

    private var isArmedOrHeld: Bool {
        switch model.show.state {
        case .armed, .held: return true
        default: return false
        }
    }

    private var isLive: Bool {
        guard case .live = model.show.state else { return false }
        return true
    }

    private func control(_ title: String, _ key: String, _ enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(key).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            .frame(width: 64, height: 40)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .focusable(false)
        .hoverBrighten()
        .disabled(!enabled)
    }
}

private struct KeyLegend: View {
    var body: some View {
        HStack(spacing: 20) {
            ForEach(Self.items, id: \.0) { key, action in
                HStack(spacing: 5) {
                    Text(key).font(.system(size: 11, weight: .semibold, design: .monospaced))
                    Text(action).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 26)
        .background(Theme.panel)
    }

    private static let items = [
        ("A", "Arm"), ("Space", "GO"), ("F", "End fade"), ("P", "Hold"), ("Esc", "Panic"), ("Esc Esc", "Hard stop"),
        ("M", "Marker"), ("[ ]", "Move end"), ("H", "Phones next"), ("D", "Disarm"), ("Cmd-Shift-L", "Show Mode"),
    ]
}

struct MeterGroup: View {
    let title: String
    let meter: MeterState
    var width: CGFloat = 190

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            MeterZoneTicks()
            MeterBar(level: meter.left)
            MeterBar(level: meter.right)
            MeterScale(width: width)
        }
        .frame(width: width)
    }
}

/// The meter's zones, on a linear dB scale from -60 to 0: quiet, the target, hot, clipping.
private enum MeterZones {
    static let floorDb: Float = -60
    static let targetLow: Float = -30
    static let targetHigh: Float = -10
    static let hot: Float = -3

    static let quiet = Color(red: 72 / 255, green: 190 / 255, blue: 210 / 255)
    static let target = Color(red: 120 / 255, green: 210 / 255, blue: 80 / 255)
    static let warm = Color(red: 236 / 255, green: 196 / 255, blue: 64 / 255)
    static let clip = Color(red: 1, green: 69 / 255, blue: 58 / 255)

    static func color(atDb db: Float) -> Color {
        if db < targetLow { return quiet }
        if db < targetHigh { return target }
        if db < hot { return warm }
        return clip
    }

    static func x(_ db: Float, in width: CGFloat) -> CGFloat {
        width * CGFloat((db - floorDb) / -floorDb)
    }
}

/// Marks over the meter where the target zone starts and ends.
private struct MeterZoneTicks: View {
    var body: some View {
        Canvas { context, size in
            for db in [MeterZones.targetLow, MeterZones.targetHigh] {
                let x = MeterZones.x(db, in: size.width).rounded()
                context.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)), with: .color(MeterZones.target))
            }
        }
        .frame(height: 3)
    }
}

private struct MeterBar: View {
    let level: Float

    var body: some View {
        Canvas { context, size in
            let db = level > 0 ? 20 * log10(level) : -.infinity
            // 1.25 dB a segment when there is room, else 2.5, so a segment never gets thinner than the gap.
            let step: Float = size.width >= 160 ? 1.25 : 2.5
            let count = Int(-MeterZones.floorDb / step)
            let gap: CGFloat = 1
            let segment = (size.width + gap) / CGFloat(count)
            for index in 0..<count {
                let low = MeterZones.floorDb + Float(index) * step
                let color = MeterZones.color(atDb: low)
                let rect = CGRect(x: CGFloat(index) * segment, y: 0, width: segment - gap, height: size.height)
                context.fill(Path(rect), with: .color(db > low ? color : color.opacity(0.16)))
            }
        }
        .frame(height: 12)
    }
}

/// dB labels under the meter, thinned out when it is narrow.
private struct MeterScale: View {
    let width: CGFloat

    private var marks: [Float] { width >= 160 ? [-60, -40, -30, -20, -10, -3, 0] : [-60, -30, -10, 0] }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(marks, id: \.self) { db in
                Text(db == 0 ? "0" : "\(Int(db))")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .alignmentGuide(.leading) { label in
                        let x = MeterZones.x(db, in: width)
                        if db == MeterZones.floorDb { return 0 }
                        if db == 0 { return label.width - x }
                        return label.width / 2 - x
                    }
            }
        }
        .frame(width: width, height: 11, alignment: .topLeading)
    }
}

private struct ShowWaveform: View {
    @Environment(AppModel.self) private var model
    let track: Track

    var body: some View {
        let show = model.show
        let live = show.state.cueID == show.activeCue?.id && show.state.holdsHouseEngine
        WaveformCanvas(
            peaks: model.peaks(for: track.id), durationSec: track.durationSec, startSec: track.startSec,
            endSec: live ? show.endSec : track.endSec, fadeSec: track.fadeOutSec, markers: track.markers,
            background: .clear, fill: Color.white.opacity(0.62), dimFill: Color.white.opacity(0.18)
        )
        .overlay {
            GeometryReader { geometry in
                if live, track.durationSec > 0 {
                    Rectangle()
                        .fill(StateStyle(show.state).color ?? .primary)
                        .frame(width: 2)
                        .offset(x: geometry.size.width * CGFloat(show.positionSec / track.durationSec))
                }
            }
        }
    }
}
