import CantorCore
import SwiftUI

struct ShowView: View {
    /// The narrowest cue list, its divider and the narrowest current cue panel.
    static let minWidth: CGFloat = 240 + 1 + CurrentCuePanel.minWidth

    @Environment(AppModel.self) private var model

    var body: some View {
        let show = model.show
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
                .help("Show Mode enables the house transport and locks editing (Command-L)")

                if model.loadedPlanID != nil {
                    Button("Unload") { model.unloadService() }
                        .disabled(show.showMode || show.state.holdsHouseEngine)
                        .help("Release memory, allow sleep and restore macOS sound outputs")
                }
            }
        }
    }
}

private struct StateBar: View {
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
            Text(show.activeCue?.title ?? show.pointedCue?.title ?? "No service loaded")
                .font(.system(size: 22, weight: .semibold))
                .lineLimit(1)
            Spacer()
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
                Label(show.showMode ? "Show Mode on" : "Show Mode off", systemImage: show.showMode ? "lock.fill" : "lock.open")
            }
            .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 20)
        .frame(height: 76)
        .background(style.color ?? Theme.panel)
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
                    description: Text("Open a service, confirm its matches, then choose Load Service.")
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
        VStack(alignment: .leading, spacing: 14) {
            if let cue, let track = cue.track {
                ShowWaveform(track: track)
                    .frame(maxHeight: .infinity)
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("REMAINING").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        Text(TimeText.tenths(remaining(track)))
                            .font(.system(size: 76, weight: .medium, design: .monospaced))
                            .foregroundStyle(StateStyle(show.state).color ?? .primary)
                            .contentTransition(.identity)
                            .monospacedDigit()
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("Fade \(String(format: "%.1f", track.fadeOutSec)) s")
                        Text("Gain \(TimeText.decibels(cue.gainDb))")
                        if let resume = show.resumeSec, show.state != .idle || show.pointedCue?.id == cue.id {
                            Text("Starts at \(TimeText.tenths(resume))").foregroundStyle(Theme.armed)
                        }
                        Text(track.endSec == nil ? "End: file end" : "End: \(TimeText.tenths(track.endSec ?? 0))")
                    }
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.secondary)
                }
                if !cue.notes.isEmpty {
                    Text(cue.notes).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(2)
                }
            } else {
                Spacer()
            }
            NextCueLine()
            HStack(alignment: .bottom, spacing: 20) {
                TransportButtons()
                Spacer()
                MeterGroup(title: "HOUSE", meter: model.houseMeter, fill: Theme.meterFill, width: meterWidth)
                MeterGroup(title: "CUE", meter: model.cueMeter, fill: Theme.cue, width: meterWidth)
            }
        }
        .padding(18)
    }

    private func remaining(_ track: Track) -> Double {
        let show = model.show
        if show.state.holdsHouseEngine { return show.remainingSec }
        return (track.endSec ?? track.durationSec) - track.startSec
    }
}

private struct NextCueLine: View {
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
            if show.showMode, let alert = model.alert {
                Spacer()
                Label(alert, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.armed)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(2)
                    .help(alert)
                Button("Dismiss") { model.alert = nil }
                    .buttonStyle(.borderless)
                    .focusable(false)
            }
        }
    }
}

private struct TransportButtons: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let show = model.show
        let enabled = show.showMode
        HStack(spacing: 8) {
            control("Arm", "A", enabled && show.state == .idle) { show.arm() }
            // Also clears a mid-track start while idle, like D.
            control("Disarm", "D", isArmedOrHeld || (enabled && show.resumeSec != nil)) { show.disarm() }
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
        guard model.show.showMode else { return false }
        switch model.show.state {
        case .armed, .held: return true
        default: return false
        }
    }

    private var isLive: Bool {
        guard model.show.showMode, case .live = model.show.state else { return false }
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
        ("M", "Marker"), ("[ ]", "Move end"), ("H", "Phones next"), ("D", "Disarm"), ("Cmd-L", "Show Mode"),
    ]
}

struct MeterGroup: View {
    let title: String
    let meter: MeterState
    let fill: Color
    var width: CGFloat = 190

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            MeterBar(level: meter.left, fill: fill)
            MeterBar(level: meter.right, fill: fill)
        }
        .frame(width: width)
    }
}

private struct MeterBar: View {
    let level: Float
    let fill: Color

    private var fraction: CGFloat {
        guard level > 0 else { return 0 }
        let db = 20 * log10(level)
        return CGFloat(min(max((db + 60) / 60, 0), 1))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.meterTrack)
                Rectangle().fill(level >= 0.89 ? Theme.danger : fill).frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 10)
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
            endSec: live ? show.endSec : track.endSec, fadeSec: track.fadeOutSec, markers: track.markers
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
