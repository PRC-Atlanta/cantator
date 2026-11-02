import AppKit
import CantorCore
import SwiftUI

/// Color carries state and nothing else. Everything else stays neutral.
enum Theme {
    private static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }

    static let armed = dynamic(dark: rgb(245, 166, 35), light: rgb(176, 104, 0))
    static let live = dynamic(dark: rgb(48, 209, 88), light: rgb(20, 128, 50))
    static let fading = dynamic(dark: rgb(255, 122, 40), light: rgb(196, 76, 0))
    static let danger = dynamic(dark: rgb(255, 69, 58), light: rgb(196, 30, 24))
    static let cue = dynamic(dark: rgb(90, 200, 250), light: rgb(0, 112, 160))

    static let showBackground = dynamic(dark: rgb(16, 16, 18), light: rgb(236, 236, 238))
    static let panel = dynamic(dark: rgb(26, 26, 29), light: rgb(246, 246, 248))
    static let separator = dynamic(dark: rgb(58, 58, 62), light: rgb(205, 205, 210))
    static let waveform = dynamic(dark: rgb(150, 150, 156), light: rgb(110, 110, 116))
    static let waveformDim = dynamic(dark: rgb(70, 70, 76), light: rgb(190, 190, 196))
    static let neutralAccent = dynamic(dark: rgb(170, 170, 176), light: rgb(84, 84, 90))
}

struct StateStyle {
    var word: String
    var symbol: String
    var color: Color?

    init(_ state: ShowState) {
        switch state {
        case .idle: self = .init(word: "IDLE", symbol: "stop.circle", color: nil)
        case .armed: self = .init(word: "ARMED", symbol: "bolt.circle.fill", color: Theme.armed)
        case .live: self = .init(word: "LIVE", symbol: "play.circle.fill", color: Theme.live)
        case .held: self = .init(word: "HOLD", symbol: "pause.circle.fill", color: Theme.armed)
        case .fading: self = .init(word: "FADING", symbol: "speaker.wave.1.fill", color: Theme.fading)
        case .panicking: self = .init(word: "PANIC", symbol: "exclamationmark.octagon.fill", color: Theme.danger)
        case .faulted: self = .init(word: "FAULT", symbol: "xmark.octagon.fill", color: Theme.danger)
        }
    }

    private init(word: String, symbol: String, color: Color?) {
        self.word = word
        self.symbol = symbol
        self.color = color
    }
}

enum TimeText {
    /// 02:41.3
    static func tenths(_ seconds: Double) -> String {
        let total = Int((max(seconds, 0) * 10).rounded(.down))
        return String(format: "%02d:%02d.%d", total / 600, total / 10 % 60, total % 10)
    }

    /// 2:41
    static func plain(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func decibels(_ value: Double) -> String {
        String(format: "%+.1f dB", value)
    }
}

/// A soft wash under something clickable while the pointer is over it.
struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = 5
    /// How far the wash reaches past the content.
    var outset: CGFloat = 0
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.primary.opacity(isHovered && isEnabled ? 0.08 : 0))
                    .padding(-outset)
                    .animation(.easeOut(duration: 0.12), value: isHovered)
            }
            .onHover { isHovered = $0 }
    }
}

/// Lifts a bordered button a little while the pointer is over it.
struct HoverBrighten: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .brightness(isHovered && isEnabled ? 0.06 : 0)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

extension View {
    func hoverHighlight(cornerRadius: CGFloat = 5, outset: CGFloat = 0) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius, outset: outset))
    }

    func hoverBrighten() -> some View {
        modifier(HoverBrighten())
    }
}
