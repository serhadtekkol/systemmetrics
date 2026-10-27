import AppKit
import SwiftUI
import MetricsKit

/// Design tokens for the panel. Every color here resolves for both appearances; views never
/// hard-code a color or a size that has a token.
enum Theme {
    // MARK: Load

    /// Load tiers from the spec: 0–60% green, 60–85% orange, above 85% red.
    /// Color is never the only carrier: every gauge and bar sits next to its value in text.
    static func loadColor(_ f: Double) -> Color {
        if f < 0.60 { return Load.normal }
        if f < 0.85 { return Load.elevated }
        return Load.high
    }

    /// Tier colors, used for rings, bars, sparklines and status dots. The system green/orange are
    /// only ~2.2:1 against the light card, under the 3:1 WCAG 1.4.11 asks of graphics that carry
    /// meaning (the CPU core meters have no number next to them). Light mode uses darker variants
    /// of the same hues (OKLCH L≈0.55–0.60, hue within 7°). Measured against the card composited over
    /// a #D0D0D0…white backdrop: green 3.65–4.40, orange 3.45–4.15, red 4.48–5.38:1. Dark keeps
    /// system green/orange (4.52 / 4.45:1 at worst, card over #3A3A3A) and lifts red to #FF6961
    /// (3.24:1 at worst), since system red measured 2.68:1 there.
    enum Load {
        static let normal = dynamic("normal", light: 0x248A3D, dark: 0x30D158)
        static let elevated = dynamic("elevated", light: 0xC06400, dark: 0xFF9F0A)
        static let high = dynamic("high", light: 0xD70015, dark: 0xFF6961)

        private static func dynamic(_ name: String, light: UInt32, dark: UInt32) -> Color {
            Color(nsColor: NSColor(name: "SystemMetrics.load.\(name)") { appearance in
                appearance.isDark ? NSColor(hex: dark) : NSColor(hex: light)
            })
        }
    }

    // MARK: Surfaces

    static let panelRadius: CGFloat = 20
    static let cardRadius: CGFloat = 16
    /// Light: the spec's `controlBackgroundColor` at 55%. Dark: that color is near-black and reads
    /// as a hole in the material, so the card is lifted with a white veil instead (elevation in dark
    /// mode comes from lighter surfaces).
    static let cardFill = Color(nsColor: NSColor(name: "SystemMetrics.cardFill") { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.07) : NSColor.controlBackgroundColor.withAlphaComponent(0.55)
    })
    static let hairline = Color.primary.opacity(0.08)
    /// Background track of rings and bars.
    static let track = Color.primary.opacity(0.08)
    /// Resting fill of the round header buttons and the uptime / status pills.
    static let chipFill = Color.primary.opacity(0.06)

    // MARK: Text

    /// Muted text. `secondaryLabelColor` is 50% black in light mode, which lands just under
    /// 4.5:1 on the light card; 62% keeps 11 pt captions at AA in both appearances.
    static let textSecondary = Color(nsColor: NSColor(name: "SystemMetrics.textSecondary") { appearance in
        appearance.isDark
            ? NSColor(white: 1, alpha: 0.62)
            : NSColor(white: 0, alpha: 0.62)
    })

    // MARK: Type ramp (10 / 11 / 13 / 15)

    enum Font {
        static let micro = SwiftUI.Font.system(size: 10, weight: .semibold).monospacedDigit()
        static let caption = SwiftUI.Font.system(size: 11).monospacedDigit()
        static let cardTitle = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13).monospacedDigit()
        static let value = SwiftUI.Font.system(size: 13, weight: .semibold).monospacedDigit()
        static let headline = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let gauge = SwiftUI.Font.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit()
    }

    // MARK: Spacing (4-pt grid with a 10 for the panel rhythm)

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 6
        static let m: CGFloat = 8
        static let grid: CGFloat = 10
        static let l: CGFloat = 12
    }

    // MARK: Motion

    /// The one curve used for value changes; callers drop it when Reduce Motion is on.
    static let valueAnimation = Animation.smooth(duration: 0.35)
    /// Panel entrance.
    static let panelAnimation = Animation.spring(response: 0.34, dampingFraction: 0.8)
    /// Switching between this Mac and the remote one.
    static let tabAnimation = Animation.spring(response: 0.32, dampingFraction: 0.86)
    /// Selected segment of the host switch: white on light, raised grey on dark (iOS style).
    static let segmentFill = Color(nsColor: NSColor(name: "SystemMetrics.segmentFill") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.42, alpha: 0.55) : .white
    })
}

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension MemoryPressure {
    var title: String {
        switch self {
        case .normal: "normal"
        case .warning: "uyarı"
        case .critical: "kritik"
        }
    }
    var color: Color {
        switch self {
        case .normal: Theme.Load.normal
        case .warning: Theme.Load.elevated
        case .critical: Theme.Load.high
        }
    }
}
