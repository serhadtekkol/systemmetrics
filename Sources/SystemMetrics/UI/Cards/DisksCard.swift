import SwiftUI
import MetricsKit

struct DisksCard: View {
    var volumes: [VolumeSnapshot]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Card(title: "Diskler", symbol: "internaldrive") {
            if volumes.isEmpty {
                HStack(spacing: Theme.Space.s) {
                    Text("—").font(Theme.Font.value).foregroundStyle(Theme.textSecondary)
                    UnavailableLabel()
                }
            } else {
                let ratesShown = Self.volumesShowingRates(volumes)
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    ForEach(volumes) { volume in
                        VolumeRow(volume: volume, showsRates: ratesShown.contains(volume.id))
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : .smooth, value: volumes.map(\.id))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// Read/write counters belong to the physical device, so APFS volumes in one container (or
    /// partitions of one disk) all report the same numbers. Rates are shown on the first volume of
    /// each device only; a volume whose device is unknown (`deviceID == nil`) shows its own.
    static func volumesShowingRates(_ volumes: [VolumeSnapshot]) -> Set<VolumeSnapshot.ID> {
        var seenDevices = Set<String>()
        var shown = Set<VolumeSnapshot.ID>()
        for volume in volumes {
            guard let device = volume.deviceID else { shown.insert(volume.id); continue }
            if seenDevices.insert(device).inserted { shown.insert(volume.id) }
        }
        return shown
    }

    private var accessibilityText: String {
        guard !volumes.isEmpty else { return "Diskler, veri yok" }
        return "Diskler: " + volumes.map { v in
            "\(UntrustedText.clean(v.name)), \(v.isInternal ? "dahili" : "harici"), \(Formatters.diskBytes(v.used)) / \(Formatters.diskBytes(v.total)) dolu"
        }.joined(separator: "; ")
    }
}

private struct VolumeRow: View {
    var volume: VolumeSnapshot
    var showsRates: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.grid) {
            Image(systemName: volume.isInternal ? "internaldrive" : "externaldrive")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                    UntrustedName(raw: volume.name)
                        .font(Theme.Font.headline)
                    Spacer(minLength: Theme.Space.xs)
                    Text("\(Formatters.diskBytes(volume.used)) / \(Formatters.diskBytes(volume.total))")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                UsageBar(fraction: volume.usedFraction)
                // Always one line tall, so the panel does not grow when the first rates arrive
                // (they need two samples) or shrink between devices.
                if showsRates {
                    HStack(spacing: Theme.Space.l) {
                        Throughput(symbol: "arrow.down", label: "okuma", value: volume.readBytesPerSecond)
                        Throughput(symbol: "arrow.up", label: "yazma", value: volume.writeBytesPerSecond)
                    }
                } else {
                    Text("aynı aygıt · hızlar yukarıda")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }
}

private struct Throughput: View {
    var symbol: String
    var label: String
    /// `nil` until the sampler has two readings; shows "—" in the same space.
    var value: Double?

    var body: some View {
        HStack(spacing: Theme.Space.xxs) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .accessibilityLabel(label)
            Text(value.map(Formatters.rate) ?? "—")
        }
        .font(Theme.Font.caption)
        .foregroundStyle(Theme.textSecondary)
    }
}
