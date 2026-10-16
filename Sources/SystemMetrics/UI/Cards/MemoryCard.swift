import SwiftUI
import MetricsKit

/// RAM is coloured by memory pressure, never by used %: macOS keeps RAM 80–90% full on purpose
/// (file cache, compressed pages) while healthy, so a used-% colour would show orange or red on
/// a Mac that is fine. The used % stays as the number in the ring.
struct MemoryCard: View {
    var memory: MemorySnapshot?
    var history: [Double]

    var body: some View {
        Card(title: "RAM", symbol: "memorychip", accessory: {
            if let memory {
                HStack(spacing: Theme.Space.xs) {
                    StatusDot(color: memory.pressure.color)
                    Text(memory.pressure.title)
                }
            }
        }) {
            HStack(spacing: Theme.Space.grid) {
                RingGauge(fraction: memory?.usedFraction, color: memory?.pressure.color)
                if let memory {
                    ValuePair(value: Formatters.bytes(memory.used), detail: "/ \(Formatters.bytes(memory.total))")
                } else {
                    UnavailableLabel()
                }
            }
            Spacer(minLength: 0)
            Sparkline(values: history, color: memory?.pressure.color ?? Theme.Load.normal)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let memory else { return "Bellek kullanımı, veri yok" }
        return "Bellek kullanımı \(Formatters.percent(memory.usedFraction)), "
            + "\(Formatters.bytes(memory.used)) / \(Formatters.bytes(memory.total)), bellek basıncı \(memory.pressure.title)"
    }
}

/// Primary value with a muted second line, used next to rings.
struct ValuePair: View {
    var value: String
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Text(value)
                .font(Theme.Font.value)
            Text(detail)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }
}
