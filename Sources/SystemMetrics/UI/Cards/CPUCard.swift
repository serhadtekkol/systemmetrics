import SwiftUI
import MetricsKit

struct CPUCard: View {
    var cpu: CPUSnapshot?
    var history: [Double]

    var body: some View {
        Card(title: "CPU", symbol: "cpu") {
            HStack(spacing: Theme.Space.grid) {
                RingGauge(fraction: cpu?.total)
                if let cpu {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        if !cpu.efficiencyCores.isEmpty { CoreRow(label: "E", loads: Array(cpu.efficiencyCores)) }
                        if !cpu.performanceCores.isEmpty { CoreRow(label: "P", loads: Array(cpu.performanceCores)) }
                    }
                } else {
                    UnavailableLabel()
                }
            }
            Spacer(minLength: 0)
            Sparkline(values: history, color: Theme.loadColor(cpu?.total ?? 0))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let cpu else { return "CPU kullanımı, veri yok" }
        var parts = ["CPU kullanımı \(Formatters.percent(cpu.total))"]
        if !cpu.performanceCores.isEmpty {
            parts.append("\(cpu.performanceCores.count) performans çekirdeği ortalama \(Formatters.percent(Self.mean(cpu.performanceCores)))")
        }
        if !cpu.efficiencyCores.isEmpty {
            parts.append("\(cpu.efficiencyCores.count) verimlilik çekirdeği ortalama \(Formatters.percent(Self.mean(cpu.efficiencyCores)))")
        }
        return parts.joined(separator: ", ")
    }

    private static func mean(_ values: ArraySlice<Double>) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
}

/// One cluster: a letter and one vertical meter per core.
private struct CoreRow: View {
    var label: String
    var loads: [Double]

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Text(label)
                .font(Theme.Font.micro)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 9, alignment: .leading)
            HStack(spacing: Theme.Space.xxs + 1) {
                ForEach(loads.indices, id: \.self) { CoreMeter(load: loads[$0]) }
            }
        }
    }
}

private struct CoreMeter: View {
    var load: Double
    static let height: CGFloat = 18
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clamped: Double { min(max(load, 0), 1) }

    var body: some View {
        ZStack(alignment: .bottom) {
            Capsule().fill(Theme.track)
            Capsule()
                .fill(Theme.loadColor(clamped))
                .frame(height: clamped == 0 ? 0 : max(4, Self.height * clamped))
        }
        // Shrinks to 2 pt on Macs with many cores so a cluster never overflows the card.
        .frame(minWidth: 2, idealWidth: 4, maxWidth: 4)
        .frame(height: Self.height)
        .animation(reduceMotion ? nil : Theme.valueAnimation, value: clamped)
    }
}
