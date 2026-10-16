import SwiftUI

/// Horizontal capsule meter coloured by load.
struct UsageBar: View {
    var fraction: Double
    static let height: CGFloat = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clamped: Double { min(max(fraction, 0), 1) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(Theme.loadColor(clamped))
                    // A non-zero value never disappears into the track.
                    .frame(width: clamped == 0 ? 0 : max(Self.height, proxy.size.width * clamped))
            }
        }
        .frame(height: Self.height)
        .animation(reduceMotion ? nil : Theme.valueAnimation, value: clamped)
        .accessibilityHidden(true)
    }
}

#Preview("UsageBar") {
    VStack(spacing: 12) {
        UsageBar(fraction: 0)
        UsageBar(fraction: 0.01)
        UsageBar(fraction: 0.45)
        UsageBar(fraction: 0.7)
        UsageBar(fraction: 0.95)
    }
    .frame(width: 200)
    .padding()
}
