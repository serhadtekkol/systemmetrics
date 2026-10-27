import SwiftUI
import MetricsKit

/// The panel's content. `PanelController` mounts it only while the panel is on screen, so a
/// hidden panel holds no observation of `engine` and costs nothing per tick.
///
/// Height: the content is laid out once inside a ScrollView. When it fits, the controller sizes
/// the window to the content and nothing scrolls; on a short screen the controller caps the window
/// at the visible frame of the screen it is on and the ScrollView takes over. The cap lives only
/// in `PanelController` (it knows which screen the panel is on).
struct PanelView: View {
    let engine: MetricsEngine
    var remote: RemoteMonitor? = nil
    var selection: PanelSelection = PanelSelection()
    var onOpenSettings: () -> Void

    private var panelShape: RoundedRectangle { RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous) }

    /// False for the first frame after the panel is mounted; the content then springs in.
    @State private var appeared = false

    var body: some View {
        ScrollView(.vertical) { content }
            .scrollIndicators(.automatic)
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: PanelController.width)
            .background(.ultraThinMaterial, in: panelShape)
            .clipShape(panelShape)
            .overlay(panelShape.strokeBorder(Theme.hairline, lineWidth: 0.5))
            // Control Center style entrance: grows down from the menu bar with a soft spring.
            .scaleEffect(appeared ? 1 : 0.92, anchor: .top)
            .offset(y: appeared ? 0 : -8)
            .opacity(appeared ? 1 : 0)
            .onAppear { withAnimation(Theme.panelAnimation) { appeared = true } }
    }

    private var content: some View {
        VStack(spacing: Theme.Space.grid) {
            if let remote {
                HostPicker(remote: remote, selection: selection)
            }
            if let remote, selection.showsRemote {
                RemoteContent(remote: remote, onOpenSettings: onOpenSettings)
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing))
                        .combined(with: .opacity))
            } else {
                MetricsContent(snapshot: engine.snapshot, history: engine.history, hostInfo: engine.hostInfo,
                               onOpenSettings: onOpenSettings)
                    .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading))
                        .combined(with: .opacity))
            }
        }
        .padding(Theme.Space.l)
        // Cards stretch to their row's height; measuring at ideal height keeps that stretch
        // inside each grid row instead of letting it spill into the panel.
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Which Mac the panel shows. Owned by the app delegate so it survives the panel being
/// unmounted between openings, and so the window is re-fitted when it changes.
@MainActor
@Observable
final class PanelSelection {
    var showsRemote = false
}

/// "Bu Mac / <remote>" switch, iOS segmented-control style: a recessed track with a raised pill
/// under the selected segment that slides between them. Drawn in SwiftUI rather than with the
/// AppKit segmented control, which sized the status symbol and the selection badly in a panel.
private struct HostPicker: View {
    let remote: RemoteMonitor
    @Bindable var selection: PanelSelection
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            segment(isRemote: false) { Text("Bu Mac") }
            segment(isRemote: true) {
                HStack(spacing: Theme.Space.xs + 1) {
                    Circle()
                        .fill(remote.state == .connected ? Theme.Load.normal : Theme.textSecondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(verbatim: UntrustedText.clean(remote.host))
                }
            }
        }
        .padding(2)
        .background(Theme.chipFill, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mac")
    }

    private func segment(isRemote: Bool, @ViewBuilder label: () -> some View) -> some View {
        let selected = selection.showsRemote == isRemote
        return Button {
            withAnimation(Theme.tabAnimation) { selection.showsRemote = isRemote }
        } label: {
            label()
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.primary : Theme.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background {
                    if selected {
                        Capsule()
                            .fill(Theme.segmentFill)
                            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                            .matchedGeometryEffect(id: "pill", in: pill)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The cards for one Mac.
private struct MetricsContent: View {
    var snapshot: SystemSnapshot
    var history: History
    var hostInfo: HostInfo
    var onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.grid) {
            HeaderView(hostInfo: hostInfo, now: snapshot.timestamp, onOpenSettings: onOpenSettings)
            Grid(horizontalSpacing: Theme.Space.grid, verticalSpacing: Theme.Space.grid) {
                GridRow {
                    CPUCard(cpu: snapshot.cpu, history: history.cpu.elements)
                    MemoryCard(memory: snapshot.memory, history: history.memory.elements)
                }
                GridRow {
                    GPUCard(gpu: snapshot.gpu, history: history.gpu.elements)
                    SwapCard(swap: snapshot.swap, compressed: snapshot.memory?.compressed)
                }
            }
            DisksCard(volumes: snapshot.volumes)
            if snapshot.docker?.state != .notInstalled {
                DockerCard(docker: snapshot.docker)
            }
        }
    }
}

/// The remote Mac's cards, or why there are none yet. Data that arrived before a disconnect
/// stays visible under a banner rather than being blanked.
private struct RemoteContent: View {
    let remote: RemoteMonitor
    var onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.grid) {
            if case .failed(let message) = remote.state {
                StatusBanner(symbol: "exclamationmark.triangle.fill", text: message, tint: Theme.Load.elevated)
            }
            if let host = remote.hostInfo {
                MetricsContent(snapshot: remote.snapshot, history: remote.history, hostInfo: host,
                               onOpenSettings: onOpenSettings)
            } else if remote.state == .connecting {
                StatusBanner(symbol: "antenna.radiowaves.left.and.right", text: "Bağlanıyor…", tint: Theme.textSecondary)
            }
        }
    }
}

private struct StatusBanner: View {
    var symbol: String
    var text: String
    var tint: Color

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(Theme.Font.body).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.l)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The parts of a snapshot that change the panel's height. Values (percentages, bytes, rates)
/// never do: every row reserves its space, including "—" for values not read yet. While the
/// panel is visible the window is re-fitted only when this key changes, instead of measuring the
/// SwiftUI content on every tick. Keep it in step with `PanelView.content` when adding a row
/// that can appear or disappear.
struct PanelLayoutKey: Equatable {
    var volumeIDs: [String]
    var docker: DockerState?
    var dockerRows: Int
    var dockerOverflow: Bool
    var swap: Int                  // 0 = no data, 1 = none allocated, 2 = in use
    var hasCPU: Bool, hasMemory: Bool, hasGPU: Bool

    init(_ snapshot: SystemSnapshot) {
        volumeIDs = snapshot.volumes.map(\.id)
        docker = snapshot.docker?.state
        let containers = snapshot.docker?.containers.count ?? 0
        dockerRows = min(containers, DockerCard.maxRows)
        dockerOverflow = containers > DockerCard.maxRows
        swap = snapshot.swap.map { $0.total == 0 ? 1 : 2 } ?? 0
        hasCPU = snapshot.cpu != nil
        hasMemory = snapshot.memory != nil
        hasGPU = snapshot.gpu != nil
    }
}

#if DEBUG
extension MetricsEngine {
    /// Engine filled with fixed, made-up values (generic names, no real machine) and about five
    /// minutes of history. Used by previews; does not sample.
    static func preview(docker: DockerSnapshot? = .previewRunning, gpu: Bool = true) -> MetricsEngine {
        let engine = MetricsEngine(refreshInterval: 2, samplers: .previewInert,
                                   hostInfo: HostInfo(modelName: "MacBook Pro", chip: "Apple M3 Pro",
                                                      bootTime: Date(timeIntervalSinceNow: -(3 * 86_400 + 4 * 3_600))))
        let n = 150
        let cpu: [Double] = (0..<n).map { i -> Double in
            let x = Double(i)
            let slow: Double = 0.12 * sin(x / 9)
            let fast: Double = 0.05 * sin(x / 2.3)
            return 0.28 + slow + fast
        }
        let memory: [Double] = (0..<n).map { i -> Double in 0.71 + 0.02 * sin(Double(i) / 15) }
        let gpuHistory: [Double] = gpu ? (0..<n).map { i -> Double in 0.14 + 0.1 * sin(Double(i) / 5) } : []
        let snapshot = SystemSnapshot(
            timestamp: Date(),
            cpu: CPUSnapshot(total: cpu.last ?? 0.3,
                             perCore: [0.42, 0.31, 0.55, 0.12, 0.36, 0.30, 0.71, 0.48, 0.66, 0.92, 0.18, 0.08],
                             efficiencyCoreCount: 6),
            memory: MemorySnapshot(total: 18 << 30, used: UInt64(Double(18 << 30) * (memory.last ?? 0.7)),
                                   app: 8 << 30, wired: 2 << 30, compressed: 1_536 << 20, pressure: .normal),
            swap: SwapSnapshot(total: 2 << 30, used: 1_240 << 20),
            gpu: gpu ? GPUSnapshot(utilization: gpuHistory.last ?? 0.2, memoryInUse: 612 << 20) : nil,
            volumes: [
                VolumeSnapshot(id: "/", name: "Macintosh HD", isInternal: true, isRoot: true,
                               total: 494_000_000_000, available: 212_000_000_000,
                               readBytesPerSecond: 1_240_000, writeBytesPerSecond: 380_000, deviceID: "internal"),
                VolumeSnapshot(id: "/Volumes/Veri", name: "Veri", isInternal: true, isRoot: false,
                               total: 494_000_000_000, available: 212_000_000_000,
                               readBytesPerSecond: 1_240_000, writeBytesPerSecond: 380_000, deviceID: "internal"),
                VolumeSnapshot(id: "/Volumes/Yedek SSD", name: "Yedek SSD", isInternal: false, isRoot: false,
                               total: 1_000_000_000_000, available: 386_000_000_000,
                               readBytesPerSecond: 0, writeBytesPerSecond: 24_600_000, deviceID: "external"),
            ],
            docker: docker)
        engine.setPreviewState(snapshot: snapshot, cpuHistory: cpu, memoryHistory: memory, gpuHistory: gpuHistory)
        return engine
    }
}

extension Samplers {
    /// Samplers that return nothing; previews never start the engine.
    static let previewInert = Samplers(cpu: { nil }, memory: { nil }, swap: { nil }, gpu: { nil },
                                       volumes: { _ in [] }, docker: { _ in .notInstalled })
}

extension DockerSnapshot {
    static let previewRunning = DockerSnapshot(state: .running, containers: [
        ContainerSnapshot(id: "1", name: "postgres", cpuPercent: 3.4, memory: 412 << 20),
        ContainerSnapshot(id: "2", name: "api", cpuPercent: 52.6, memory: 268 << 20),
        ContainerSnapshot(id: "3", name: "web", cpuPercent: 12.1, memory: 164 << 20),
        ContainerSnapshot(id: "4", name: "worker", cpuPercent: 8.7, memory: 121 << 20),
        ContainerSnapshot(id: "5", name: "redis", cpuPercent: 0.4, memory: 18 << 20),
        ContainerSnapshot(id: "6", name: "cache", cpuPercent: nil, memory: 9 << 20),
    ], diskUsage: 18_400_000_000, vmCPUCount: 8, vmMemoryTotal: 7_838_000_000)
}

#Preview("Panel — açık") {
    PanelView(engine: .preview(), onOpenSettings: {})
        .padding()
        .preferredColorScheme(.light)
}

#Preview("Panel — koyu") {
    PanelView(engine: .preview(), onOpenSettings: {})
        .padding()
        .preferredColorScheme(.dark)
}

#Preview("Panel — GPU yok, Docker çalışmıyor") {
    PanelView(engine: .preview(docker: DockerSnapshot(state: .notRunning), gpu: false), onOpenSettings: {})
        .padding()
}

#Preview("Panel — Docker yükleniyor") {
    PanelView(engine: .preview(docker: nil), onOpenSettings: {})
        .padding()
}
#endif
