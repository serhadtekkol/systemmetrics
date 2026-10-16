import SwiftUI
import MetricsKit

struct GPUCard: View {
    var gpu: GPUSnapshot?
    var history: [Double]

    var body: some View {
        Card(title: "GPU", symbol: "square.stack.3d.up") {
            HStack(spacing: Theme.Space.grid) {
                RingGauge(fraction: gpu?.utilization)
                if let gpu {
                    // Apple silicon has no separate VRAM: this is unified memory the GPU holds, and
                    // it is already part of the RAM card's "used". The label says so, so nobody adds
                    // the two together.
                    ValuePair(value: Formatters.bytes(gpu.memoryInUse), detail: "birleşik bellek")
                        .help("GPU'nun kullandığı birleşik bellek; RAM kullanımına zaten dahildir.")
                } else {
                    UnavailableLabel()
                }
            }
            Spacer(minLength: 0)
            Sparkline(values: history, color: Theme.loadColor(gpu?.utilization ?? 0))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(gpu.map {
            "GPU kullanımı \(Formatters.percent($0.utilization)), birleşik bellekten \(Formatters.bytes($0.memoryInUse)), RAM kullanımına dahil"
        } ?? "GPU kullanımı, veri yok")
    }
}
