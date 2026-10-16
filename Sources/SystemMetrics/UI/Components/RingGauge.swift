import SwiftUI
import MetricsKit

/// Apple Watch–style ring. `fraction == nil` means the metric is unavailable: empty track and "—".
/// The ring is load-coloured by its own fraction unless the caller passes `color` (RAM colours
/// by memory pressure, not by how full it is).
struct RingGauge: View {
    var fraction: Double?
    var color: Color?
    var lineWidth: CGFloat = 8
    var size: CGFloat = 56
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clamped: Double { min(max(fraction ?? 0, 0), 1) }

    var body: some View {
        ZStack {
            Circle()
                .inset(by: lineWidth / 2)
                .stroke(Theme.track, lineWidth: lineWidth)
            Circle()
                .inset(by: lineWidth / 2)
                .trim(from: 0, to: clamped)
                .stroke(color ?? Theme.loadColor(clamped), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(fraction == nil ? 0 : 1)
            Text(fraction.map(Formatters.percent) ?? "—")
                .font(Theme.Font.gauge)
                .foregroundStyle(fraction == nil ? Theme.textSecondary : Color.primary)
                .contentTransition(.numericText(value: clamped))
                .minimumScaleFactor(0.8)
                .lineLimit(1)
                .padding(.horizontal, lineWidth + Theme.Space.xxs)
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : Theme.valueAnimation, value: clamped)
        .accessibilityHidden(true)
    }
}

#Preview("RingGauge") {
    HStack(spacing: 16) {
        RingGauge(fraction: 0.23)
        RingGauge(fraction: 0.72)
        RingGauge(fraction: 0.93)
        RingGauge(fraction: nil)
    }
    .padding()
}
