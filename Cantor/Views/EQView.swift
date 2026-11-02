import CantorCore
import SwiftUI

/// The per-track EQ, in its own window so the curve has room. Edits are saved with the track and
/// heard right away in preview. House playback picks them up the next time the cue is armed.
struct EQWindow: View {
    @Environment(AppModel.self) private var model
    let trackID: UUID
    @State private var selected = 3

    var body: some View {
        if let track = model.library.track(id: trackID) {
            let eq = track.eq ?? TrackEQ()
            let editing = !model.show.showMode
            VStack(spacing: 0) {
                header(track, eq, editing)
                EQGraph(eq: eq, selected: $selected) { change in edit(change) }
                    .frame(minHeight: 280)
                    .disabled(!editing)
                BandStrip(eq: eq, selected: $selected) { index in edit { $0.bands[index].isOn.toggle() } }
                    .disabled(!editing)
                BandControls(eq: eq, index: selected, edit: edit)
                    .disabled(!editing)
            }
            .frame(minWidth: 760, minHeight: 560)
            .background(EQTheme.chrome)
            .tint(EQTheme.accent)
            .navigationTitle("EQ: \(track.title)")
        } else {
            ContentUnavailableView("Track Not Found", systemImage: "slider.vertical.3")
                .frame(minWidth: 400, minHeight: 300)
        }
    }

    private func header(_ track: Track, _ eq: TrackEQ, _ editing: Bool) -> some View {
        let previewing = model.cueBus.isPlaying && model.cueBus.trackID == track.id
        return HStack(spacing: 12) {
            Toggle(isOn: Binding(get: { eq.isOn }, set: { value in edit { $0.isOn = value } })) {
                Label(eq.isOn ? "EQ On" : "Bypassed", systemImage: "power")
            }
            .toggleStyle(.button)
            .disabled(!editing)
            .help("Compare with the track as mixed")

            Button {
                previewing ? model.stopAudition() : model.audition(track, fromSec: model.auditionPositionSec ?? track.startSec)
            } label: {
                Label(previewing ? "Stop" : "Preview", systemImage: previewing ? "stop.fill" : "headphones")
            }
            .disabled(!track.isLocal)
            if previewing, let position = model.auditionPositionSec {
                Text(TimeText.tenths(position)).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            }

            Spacer()
            if model.show.showMode {
                Label("Locked in Show Mode", systemImage: "lock.fill").foregroundStyle(.secondary)
            }
            Button("Reset") { model.updateTrack(trackID) { $0.eq = nil } }
                .disabled(!editing || track.eq == nil)
                .help("Back to the track as mixed")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(EQTheme.chrome)
    }

    private func edit(_ change: (inout TrackEQ) -> Void) {
        model.updateTrack(trackID) { track in
            var eq = track.eq ?? TrackEQ()
            change(&eq)
            for index in eq.bands.indices { eq.bands[index].clamp() }
            eq.outputDb = min(max(eq.outputDb, TrackEQ.outputRange.lowerBound), TrackEQ.outputRange.upperBound)
            track.eq = eq
        }
    }
}

/// The EQ window's palette, after the Waves F6. This is the one place in Cantor where color marks
/// something other than show state: here it only tells the bands apart.
enum EQTheme {
    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255)
    }

    static let chrome = rgb(28, 30, 34)
    static let graphTop = rgb(46, 60, 68)
    static let graphBottom = rgb(20, 27, 32)
    static let handleFill = rgb(26, 34, 40)
    static let grid = Color.white.opacity(0.08)
    static let label = Color.white.opacity(0.5)
    static let panelTop = rgb(54, 57, 62)
    static let panelBottom = rgb(34, 36, 40)
    static let knobFace = rgb(30, 32, 36)
    static let knobTrack = rgb(66, 68, 74)
    static let accent = rgb(242, 140, 96)
    static let selection = rgb(242, 200, 60)
    static let passes = rgb(226, 229, 233)
    private static let numbered = [
        rgb(232, 112, 76), rgb(196, 222, 96), rgb(84, 200, 188), rgb(80, 186, 232), rgb(126, 134, 236), rgb(236, 96, 152),
    ]

    /// HP and LP are white, bands 1 to 6 each have a color.
    static func band(_ index: Int, _ band: EQBand) -> Color {
        band.shape.hasGain ? numbered[(index - 1 + numbered.count) % numbered.count] : passes
    }
}

// MARK: Graph

private enum EQScale {
    static let minHz = 20.0, maxHz = 20_000.0, rangeDb = 18.0

    static func x(_ hz: Double, _ width: CGFloat) -> CGFloat {
        CGFloat((log10(hz) - log10(minHz)) / (log10(maxHz) - log10(minHz))) * width
    }

    static func hz(_ x: CGFloat, _ width: CGFloat) -> Double {
        pow(10, log10(minHz) + Double(min(max(x / max(width, 1), 0), 1)) * (log10(maxHz) - log10(minHz)))
    }

    static func y(_ db: Double, _ height: CGFloat) -> CGFloat {
        CGFloat((rangeDb - min(max(db, -rangeDb), rangeDb)) / (2 * rangeDb)) * height
    }

    static func db(_ y: CGFloat, _ height: CGFloat) -> Double {
        rangeDb - Double(min(max(y / max(height, 1), 0), 1)) * 2 * rangeDb
    }

    static func label(_ hz: Double) -> String {
        hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))"
    }

    static func bandName(_ index: Int, _ band: EQBand) -> String {
        switch band.shape {
        case .highPass: "HP"
        case .lowPass: "LP"
        default: "\(index)"
        }
    }
}

/// The response curve with a handle per band. Drag a handle to move its frequency and gain.
private struct EQGraph: View {
    let eq: TrackEQ
    @Binding var selected: Int
    let edit: ((inout TrackEQ) -> Void) -> Void
    @State private var dragging: Int?
    @State private var hovered: Int?

    private static let gridHz = [30.0, 60, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                Canvas { context, size in draw(context, size) }
                ForEach(eq.bands.indices, id: \.self) { index in
                    handle(index, size)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hovered = nearest(to: location, size)
                case .ended: hovered = nil
                }
            }
            .pointerStyle(dragging != nil ? .grabActive : (hovered != nil ? .grabIdle : .default))
            .gesture(drag(size))
        }
        .padding(14)
        .background(LinearGradient(colors: [EQTheme.graphTop, EQTheme.graphBottom], startPoint: .top, endPoint: .bottom))
    }

    private func draw(_ context: GraphicsContext, _ size: CGSize) {
        for hz in Self.gridHz {
            let x = EQScale.x(hz, size.width)
            context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) }, with: .color(EQTheme.grid), lineWidth: 1)
            context.draw(Text(EQScale.label(hz)).font(.system(size: 10)).foregroundStyle(EQTheme.label), at: CGPoint(x: x, y: size.height - 8))
        }
        for db in stride(from: -18.0, through: 18, by: 6) {
            let y = EQScale.y(db, size.height)
            context.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                           with: .color(db == 0 ? Color.white.opacity(0.3) : EQTheme.grid), lineWidth: 1)
            if abs(db) < 18 {
                context.draw(Text(db > 0 ? "+\(Int(db))" : "\(Int(db))").font(.system(size: 10)).foregroundStyle(EQTheme.label), at: CGPoint(x: 14, y: y - 7))
            }
        }

        // Each band's own shape, shaded in its color, under the combined curve.
        let zero = EQScale.y(0, size.height)
        for (index, band) in eq.bands.enumerated() where eq.isOn && !band.isNeutral {
            var area = Path()
            area.move(to: CGPoint(x: 0, y: zero))
            for step in 0...150 {
                let x = size.width * CGFloat(step) / 150
                area.addLine(to: CGPoint(x: x, y: EQScale.y(band.responseDb(atHz: EQScale.hz(x, size.width)), size.height)))
            }
            area.addLine(to: CGPoint(x: size.width, y: zero))
            area.closeSubpath()
            context.fill(area, with: .color(EQTheme.band(index, band).opacity(band.shape.hasGain ? 0.32 : 0.12)))
        }

        let steps = 300
        var curve = Path()
        for step in 0...steps {
            let x = size.width * CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: x, y: EQScale.y(eq.responseDb(atHz: EQScale.hz(x, size.width)), size.height))
            step == 0 ? curve.move(to: point) : curve.addLine(to: point)
        }
        context.stroke(curve, with: .color(eq.isOn ? Color.white : Color.white.opacity(0.3)), lineWidth: 2)
    }

    private func point(_ band: EQBand, _ size: CGSize) -> CGPoint {
        CGPoint(x: EQScale.x(band.frequency, size.width), y: EQScale.y(band.shape.hasGain ? band.gainDb : 0, size.height))
    }

    private func handle(_ index: Int, _ size: CGSize) -> some View {
        let band = eq.bands[index]
        let color = EQTheme.band(index, band)
        return Text(EQScale.bandName(index, band))
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 24, height: 24)
            .background(Circle().fill(EQTheme.handleFill))
            .overlay(Circle().strokeBorder(color, style: StrokeStyle(lineWidth: 2, dash: band.isOn ? [] : [3, 2])))
            .opacity(band.isOn ? 1 : 0.5)
            .shadow(color: color.opacity(index == hovered || index == dragging ? 0.8 : 0), radius: 6)
            .scaleEffect(index == hovered || index == dragging ? 1.15 : 1)
            .animation(.easeOut(duration: 0.12), value: hovered)
            .overlay {
                if index == selected { Brackets().stroke(EQTheme.selection, lineWidth: 2).frame(width: 34, height: 34) }
            }
            .position(point(band, size))
            .allowsHitTesting(false)
    }

    /// The handle under the pointer, the selected one first when they overlap.
    private func nearest(to location: CGPoint, _ size: CGSize) -> Int? {
        eq.bands.indices
            .map { ($0, hypot(point(eq.bands[$0], size).x - location.x, point(eq.bands[$0], size).y - location.y) - ($0 == selected ? 4 : 0)) }
            .filter { $0.1 < 18 }
            .min { $0.1 < $1.1 }?.0
    }

    private func drag(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragging == nil {
                    guard let index = nearest(to: value.startLocation, size) else { return }
                    dragging = index
                    selected = index
                }
                guard let index = dragging else { return }
                let hz = EQScale.hz(value.location.x, size.width)
                let db = EQScale.db(value.location.y, size.height)
                edit { eq in
                    eq.bands[index].frequency = hz
                    if eq.bands[index].shape.hasGain { eq.bands[index].gainDb = (db * 10).rounded() / 10 }
                    // Moving a band means it should be heard.
                    eq.bands[index].isOn = true
                }
            }
            .onEnded { _ in dragging = nil }
    }
}

// MARK: Bands

private struct BandStrip: View {
    let eq: TrackEQ
    @Binding var selected: Int
    let toggle: (Int) -> Void
    @State private var hovered: Int?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(eq.bands.indices, id: \.self) { index in
                let band = eq.bands[index]
                Button {
                    selected = index
                } label: {
                    let color = EQTheme.band(index, band)
                    HStack(spacing: 6) {
                        Image(systemName: Self.symbol(band.shape))
                        Text(EQScale.bandName(index, band)).font(.system(size: 13, weight: .semibold))
                    }
                    .frame(width: 66, height: 26)
                    .foregroundStyle(color)
                    .background(RoundedRectangle(cornerRadius: 4).fill(index == selected ? color.opacity(0.22) : (index == hovered ? color.opacity(0.12) : EQTheme.knobFace)))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(index == selected ? 1 : 0.6), lineWidth: index == selected ? 2 : 1))
                    .overlay(alignment: .bottom) {
                        if index == selected { Rectangle().fill(color).frame(height: 3).offset(y: 7) }
                    }
                    .opacity(band.isOn ? 1 : 0.45)
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
                .animation(.easeOut(duration: 0.12), value: hovered)
                .simultaneousGesture(TapGesture(count: 2).onEnded { toggle(index) })
                .help(band.isOn ? "Double-click to turn off" : "Double-click to turn on")
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(EQTheme.chrome)
    }

    static func symbol(_ shape: EQShape) -> String {
        switch shape {
        case .highPass: "line.diagonal.arrow"
        case .lowShelf: "chart.line.downtrend.xyaxis"
        case .bell: "waveform.path"
        case .highShelf: "chart.line.uptrend.xyaxis"
        case .lowPass: "line.diagonal"
        }
    }
}

private struct BandControls: View {
    let eq: TrackEQ
    let index: Int
    let edit: ((inout TrackEQ) -> Void) -> Void

    var body: some View {
        let band = eq.bands[index]
        let defaults = TrackEQ.defaultBands[index]
        HStack(alignment: .center, spacing: 26) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Band On", isOn: Binding(get: { band.isOn }, set: { value in edit { $0.bands[index].isOn = value } }))
                if band.shape.hasGain {
                    Picker("Shape", selection: Binding(get: { band.shape }, set: { value in edit { $0.bands[index].shape = value } })) {
                        Text("Low Shelf").tag(EQShape.lowShelf)
                        Text("Bell").tag(EQShape.bell)
                        Text("High Shelf").tag(EQShape.highShelf)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 230)
                } else {
                    Text(band.shape == .highPass ? "High-pass, 12 dB per octave" : "Low-pass, 12 dB per octave")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 240, alignment: .leading)

            Knob(title: "FREQ", value: band.frequency, range: EQBand.frequencyRange, logarithmic: true, defaultValue: defaults.frequency,
                 format: { $0 >= 1000 ? String(format: "%.2fk", $0 / 1000) : String(format: "%.0f", $0) }) { value in
                edit { $0.bands[index].frequency = value }
            }
            Knob(title: "Q", value: band.q, range: EQBand.qRange, logarithmic: true, defaultValue: defaults.q,
                 format: { String(format: "%.2f", $0) }) { value in
                edit { $0.bands[index].q = value }
            }
            Knob(title: "GAIN", value: band.gainDb, range: EQBand.gainRange, logarithmic: false, defaultValue: 0,
                 format: { String(format: "%+.1f", $0) }) { value in
                edit { $0.bands[index].gainDb = (value * 10).rounded() / 10 }
            }
            .disabled(!band.shape.hasGain)
            .opacity(band.shape.hasGain ? 1 : 0.35)

            Spacer()
            Divider().frame(height: 80)
            Knob(title: "OUT", value: eq.outputDb, range: TrackEQ.outputRange, logarithmic: false, defaultValue: 0,
                 format: { String(format: "%+.1f", $0) }) { value in
                edit { $0.outputDb = (value * 10).rounded() / 10 }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(LinearGradient(colors: [EQTheme.panelTop, EQTheme.panelBottom], startPoint: .top, endPoint: .bottom))
    }
}

/// Drag up or down to turn. Option-drag for fine moves, double-click to reset.
private struct Knob: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let logarithmic: Bool
    let defaultValue: Double
    let format: (Double) -> String
    let set: (Double) -> Void
    @State private var dragStart: Double?
    @State private var isHovered = false

    private static let sweep = 270.0

    private func normalized(_ value: Double) -> Double {
        let v = min(max(value, range.lowerBound), range.upperBound)
        return logarithmic
            ? (log(v) - log(range.lowerBound)) / (log(range.upperBound) - log(range.lowerBound))
            : (v - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    private func denormalized(_ n: Double) -> Double {
        let n = min(max(n, 0), 1)
        return logarithmic
            ? exp(log(range.lowerBound) + n * (log(range.upperBound) - log(range.lowerBound)))
            : range.lowerBound + n * (range.upperBound - range.lowerBound)
    }

    var body: some View {
        let n = normalized(value)
        VStack(spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.white.opacity(0.75))
            ZStack {
                Circle().trim(from: 0, to: Self.sweep / 360)
                    .stroke(EQTheme.knobTrack, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle().trim(from: 0, to: n * Self.sweep / 360)
                    .stroke(EQTheme.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle().fill(EQTheme.knobFace).padding(9).brightness(isHovered || dragStart != nil ? 0.08 : 0)
                Circle().strokeBorder(Color.black.opacity(0.5), lineWidth: 1).padding(9)
                Rectangle().fill(EQTheme.accent).frame(width: 2, height: 12)
                    .offset(y: -15)
                    .rotationEffect(.degrees(-135 + n * Self.sweep))
            }
            .frame(width: 58, height: 58)
            .contentShape(Circle())
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .pointerStyle(.rowResize)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let start = dragStart ?? n
                        if dragStart == nil { dragStart = n }
                        let fine = NSEvent.modifierFlags.contains(.option)
                        set(denormalized(start - Double(drag.translation.height) / (fine ? 800 : 160)))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { set(defaultValue) })
            Text(format(value)).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(EQTheme.accent)
        }
        .help("Drag up or down. Option-drag for fine moves. Double-click to reset.")
    }
}

/// Corner marks around the selected handle, as in the F6.
private struct Brackets: Shape {
    func path(in rect: CGRect) -> Path {
        let arm = rect.width * 0.28
        var path = Path()
        for (corner, dx, dy) in [(CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0), (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
                                 (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0), (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0)] {
            path.move(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
        }
        return path
    }
}

/// A small, read-only curve for the track inspector.
struct EQThumbnail: View {
    let eq: TrackEQ

    var body: some View {
        Canvas { context, size in
            let zero = EQScale.y(0, size.height)
            context.stroke(Path { $0.move(to: CGPoint(x: 0, y: zero)); $0.addLine(to: CGPoint(x: size.width, y: zero)) },
                           with: .color(Theme.separator), lineWidth: 0.5)
            var curve = Path()
            for step in 0...120 {
                let x = size.width * CGFloat(step) / 120
                let point = CGPoint(x: x, y: EQScale.y(eq.responseDb(atHz: EQScale.hz(x, size.width)), size.height))
                step == 0 ? curve.move(to: point) : curve.addLine(to: point)
            }
            context.stroke(curve, with: .color(eq.isOn ? Color.primary : Theme.waveformDim), lineWidth: 1.5)
        }
    }
}
