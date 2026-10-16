import SwiftUI
import MetricsKit

/// Shown only when Docker is installed; PanelView omits it for `.notInstalled`.
///
/// Docker runs in a VM, so its totals are VM numbers, not the Mac's: CPU is expressed in vCPUs of
/// that VM and RAM is what the containers use out of the VM's memory. The labels say so, because
/// "CPU 80%" next to the Mac's own CPU card reads as host load.
struct DockerCard: View {
    var docker: DockerSnapshot?
    static let maxRows = 6

    var body: some View {
        Card(title: "Docker", symbol: "shippingbox", accessory: { statusPill }) {
            switch docker?.state {
            case .none:
                // Same shape as a running daemon with no containers, so the panel does not jump
                // when the first Docker sample lands.
                totals(cpu: nil, memory: nil, disk: nil)
                Text("yükleniyor…")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            case .running:
                if let docker { running(docker) }
            case .notRunning, .notInstalled:
                Text("Docker çalışmıyor")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder private var statusPill: some View {
        if let state = docker?.state {
            Pill {
                StatusDot(color: state == .running ? Theme.Load.normal : Theme.textSecondary)
                Text(state == .running ? "çalışıyor" : "çalışmıyor")
            }
        }
    }

    private func totals(cpu: Stat.Value?, memory: Stat.Value?, disk: Stat.Value?) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Stat(label: "Konteyner CPU", value: cpu)
            Stat(label: "Konteyner RAM", value: memory)
            Stat(label: "Disk", value: disk)
        }
    }

    @ViewBuilder private func running(_ docker: DockerSnapshot) -> some View {
        totals(cpu: Self.cpu(docker), memory: Self.memory(docker),
               disk: docker.diskUsage.map { Stat.Value(main: Formatters.diskBytes($0), detail: nil) })
        if docker.containers.isEmpty {
            Text("Çalışan konteyner yok")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
        } else {
            VStack(spacing: Theme.Space.s) {
                ContainerRowLayout(name: Text("Konteyner"), cpu: Text("CPU"), memory: Text("RAM"))
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.textSecondary)
                ForEach(docker.containers.prefix(Self.maxRows)) { container in
                    ContainerRowLayout(name: Text(verbatim: UntrustedText.clean(container.name)),
                                       cpu: Text(container.cpuPercent.map(Formatters.cpuPercent) ?? "—"),
                                       memory: Text(Formatters.bytes(container.memory)))
                        .font(Theme.Font.body)
                }
                if docker.containers.count > Self.maxRows {
                    Text("+\(docker.containers.count - Self.maxRows) daha")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, Theme.Space.xxs)
        }
    }

    /// "0,8" over "/ 4 vCPU"; without the VM size, "0,8" over "vCPU".
    private static func cpu(_ docker: DockerSnapshot) -> Stat.Value {
        let used = Formatters.cores(docker.totalCPUCores)
        return Stat.Value(main: used, detail: docker.vmCPUCount.map { "/ \($0) vCPU" } ?? "vCPU")
    }

    /// "3,4 GB" over "/ 7,3 GB VM"; without the VM size, the detail says whose memory it is.
    private static func memory(_ docker: DockerSnapshot) -> Stat.Value {
        Stat.Value(main: Formatters.bytes(docker.totalMemory),
                   detail: docker.vmMemoryTotal.map { "/ \(Formatters.bytes($0)) VM" } ?? "VM içinde")
    }

    private var accessibilityText: String {
        switch docker?.state {
        case .none: return "Docker, yükleniyor"
        case .notRunning, .notInstalled: return "Docker çalışmıyor"
        case .running:
            guard let docker else { return "Docker çalışıyor" }
            var cpu = "\(Formatters.cores(docker.totalCPUCores)) vCPU"
            if let n = docker.vmCPUCount { cpu += " / \(n) vCPU" }
            var memory = Formatters.bytes(docker.totalMemory)
            if let total = docker.vmMemoryTotal { memory += " / \(Formatters.bytes(total)) VM belleği" }
            var text = "Docker çalışıyor, konteyner CPU \(cpu), konteyner RAM \(memory), "
                + "\(docker.containers.count) konteyner"
            if let disk = docker.diskUsage { text += ", disk \(Formatters.diskBytes(disk))" }
            return text
        }
    }
}

/// Docker totals: label, value, muted detail; three equal columns. A missing value shows "—"
/// with an empty detail line, so every state has the same height.
private struct Stat: View {
    struct Value { var main: String; var detail: String? }
    var label: String
    var value: Value?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Text(label)
                .font(Theme.Font.micro)
                .foregroundStyle(Theme.textSecondary)
            Text(value?.main ?? "—")
                .font(Theme.Font.value)
                .foregroundStyle(value == nil ? Theme.textSecondary : Color.primary)
            Text(value?.detail ?? " ")    // keeps the line when there is no detail
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shared column geometry for the header row and every container row.
private struct ContainerRowLayout: View {
    var name: Text
    var cpu: Text
    var memory: Text

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            name
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            cpu.frame(width: 52, alignment: .trailing)
            memory.frame(width: 72, alignment: .trailing)
        }
    }
}
