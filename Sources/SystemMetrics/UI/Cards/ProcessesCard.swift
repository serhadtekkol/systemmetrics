import SwiftUI
import MetricsKit

/// Top apps by CPU or by memory, switchable. An app's helper processes are summed into one row
/// ("Google Chrome ×24"), the way people think about what is using the machine.
///
/// Always `rows` lines tall, filled or not, so switching the list or a short list does not change
/// the panel's height.
struct ProcessesCard: View {
    var processes: ProcessesSnapshot?
    static let rows = 5
    @AppStorage("processesByMemory") private var byMemory = false
    @Namespace private var pill

    var body: some View {
        Card(title: "En çok kullananlar", symbol: "list.number", accessory: { modeSwitch }) {
            VStack(spacing: Theme.Space.s) {
                let list = currentList
                ForEach(0..<Self.rows, id: \.self) { index in
                    if index < list.count {
                        row(list[index], top: list.first)
                    } else if index == 0 {
                        Text(emptyText)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                    } else {
                        Color.clear.frame(height: 20)
                    }
                }
                if let hidden = processes?.unreadableCount, hidden > 0 {
                    Text("Sistem süreçleri (\(hidden)) izin gerektirdiği için listede yok")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .animation(Theme.valueAnimation, value: currentList.map(\.name))
        }
        .accessibilityElement(children: .contain)
    }

    private var currentList: [ProcessUsage] {
        guard let processes else { return [] }
        return Array((byMemory ? processes.topMemory : processes.topCPU).prefix(Self.rows))
    }

    private var emptyText: String {
        if processes == nil { return "yükleniyor…" }
        return byMemory ? "veri yok" : "ölçülüyor…"
    }

    private func value(_ p: ProcessUsage) -> String {
        byMemory ? Formatters.bytes(p.memory) : (p.cpu.map { Formatters.cpuPercent($0 * 100) } ?? "—")
    }

    private func fraction(_ p: ProcessUsage, top: ProcessUsage?) -> Double {
        let v = byMemory ? Double(p.memory) : (p.cpu ?? 0)
        let max = byMemory ? Double(top?.memory ?? 0) : (top?.cpu ?? 0)
        return max > 0 ? min(1, v / max) : 0
    }

    private func row(_ p: ProcessUsage, top: ProcessUsage?) -> some View {
        HStack(spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.xs) {
                Text(verbatim: UntrustedText.clean(p.name))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if p.processCount > 1 {
                    Text(verbatim: "×\(p.processCount)")
                        .font(Theme.Font.micro)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(value(p))
                .font(Theme.Font.value)
                .contentTransition(.numericText())
                .frame(width: 72, alignment: .trailing)
        }
        .font(Theme.Font.body)
        .frame(height: 20)
        .background(alignment: .leading) {
            // Share of the top row, as a faint bar behind the text.
            GeometryReader { geo in
                Capsule()
                    .fill(Theme.track)
                    .frame(width: max(4, geo.size.width * fraction(p, top: top)))
            }
            .padding(.vertical, 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(UntrustedText.clean(p.name)), \(value(p))")
    }

    private var modeSwitch: some View {
        HStack(spacing: 0) {
            modeButton("CPU", memory: false)
            modeButton("Bellek", memory: true)
        }
        .padding(1.5)
        .background(Theme.chipFill, in: Capsule())
    }

    private func modeButton(_ title: String, memory: Bool) -> some View {
        let selected = byMemory == memory
        return Button {
            withAnimation(Theme.tabAnimation) { byMemory = memory }
        } label: {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(selected ? Color.primary : Theme.textSecondary)
                .padding(.horizontal, Theme.Space.s + 1)
                .frame(height: 18)
                .background {
                    if selected {
                        Capsule().fill(Theme.segmentFill)
                            .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                            .matchedGeometryEffect(id: "mode", in: pill)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
