import CantorCore
import SwiftUI

/// Static waveform with region shading. The moving playhead is an overlay, so this only redraws
/// when its inputs change.
struct WaveformCanvas: View, Equatable {
    let peaks: [Float]
    let durationSec: Double
    let startSec: Double
    let endSec: Double?
    let fadeSec: Double
    let markers: [Marker]
    var background = Theme.panel
    var fill = Theme.waveform
    var dimFill = Theme.waveformDim
    /// The part of the track to draw, such as the last 20 seconds. Nil draws all of it.
    var window: ClosedRange<Double>? = nil

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(background))
            guard durationSec > 0 else { return }
            let view = window ?? 0...durationSec
            let span = max(view.upperBound - view.lowerBound, 0.001)
            let x = { (seconds: Double) in CGFloat((seconds - view.lowerBound) / span) * size.width }
            let end = endSec ?? durationSec
            let midY = size.height / 2

            if !peaks.isEmpty {
                let count = Int(size.width)
                var active = Path()
                var dim = Path()
                for column in 0..<max(count, 1) {
                    let seconds = view.lowerBound + Double(column) / Double(max(count, 1)) * span
                    let index = min(max(Int(seconds / durationSec * Double(peaks.count)), 0), peaks.count - 1)
                    let height = max(CGFloat(peaks[index]) * size.height * 0.92, 1)
                    let rect = CGRect(x: CGFloat(column), y: midY - height / 2, width: 1, height: height)
                    if seconds >= startSec && seconds <= end {
                        active.addRect(rect)
                    } else {
                        dim.addRect(rect)
                    }
                }
                context.fill(dim, with: .color(dimFill))
                context.fill(active, with: .color(fill))
            }

            let fadeStart = max(end - fadeSec, startSec)
            let fadeRect = CGRect(x: x(fadeStart), y: 0, width: x(end) - x(fadeStart), height: size.height)
            context.fill(Path(fadeRect), with: .color(Theme.fading.opacity(0.18)))

            func line(_ seconds: Double, _ color: Color, _ width: CGFloat) {
                context.fill(Path(CGRect(x: x(seconds) - width / 2, y: 0, width: width, height: size.height)), with: .color(color))
            }
            for marker in markers {
                line(marker.seconds, .secondary, 1)
                context.draw(
                    Text(marker.name).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary),
                    at: CGPoint(x: x(marker.seconds) + 4, y: 4), anchor: .topLeading
                )
            }
            line(startSec, .primary, 1)
            line(end, Theme.danger, 2)
            context.draw(
                Text("END").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.danger),
                at: CGPoint(x: x(end) - 4, y: 4), anchor: .topTrailing
            )
        }
    }
}
