import SwiftUI
import MetricsKit

/// macOS grows swap on demand (1 GiB swapfiles as needed), so "total" is just what has been
/// allocated so far and a used % / fill bar would be meaningless — it reads ~100% whenever swap
/// exists. The card shows used bytes, the allocated size as context, and compressed memory: the
/// other half of how macOS relieves memory pressure, and the number that rises first.
/// Neutral colour throughout: none of these values has a healthy/unhealthy threshold on its own
/// (memory pressure on the RAM card is the signal).
struct SwapCard: View {
    var swap: SwapSnapshot?
    var compressed: UInt64?

    var body: some View {
        Card(title: "Swap", symbol: "arrow.left.arrow.right") {
            switch swap {
            case .none:
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text("—").font(Theme.Font.gauge).foregroundStyle(Theme.textSecondary)
                    UnavailableLabel()
                }
            case .some(let swap) where swap.total == 0:
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text("Kullanılmıyor").font(Theme.Font.gauge)
                    Text("swap ayrılmadı")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                .lineLimit(1)
            case .some(let swap):
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(Formatters.bytes(swap.used)).font(Theme.Font.gauge)
                    Text("ayrılan: \(Formatters.bytes(swap.total))")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .help("macOS swap alanını gerektikçe büyütür; ayrılan boyut bir üst sınır değildir.")
                }
                .lineLimit(1)
            }
            Spacer(minLength: Theme.Space.m)
            if let compressed {
                ValuePair(value: Formatters.bytes(compressed), detail: "sıkıştırılmış bellek")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var text: String
        switch swap {
        case .none: text = "Swap, veri yok"
        case .some(let swap) where swap.total == 0: text = "Swap kullanılmıyor"
        case .some(let swap):
            text = "Swap kullanımı \(Formatters.bytes(swap.used)), ayrılan \(Formatters.bytes(swap.total))"
        }
        if let compressed { text += ", sıkıştırılmış bellek \(Formatters.bytes(compressed))" }
        return text
    }
}
