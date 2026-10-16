import AppKit
import Foundation
import Observation

/// The engine's inputs as closures, so tests can drive it without touching the system.
/// Each closure returns `nil` (or an empty list) on failure; the UI then shows "veri yok"
/// on that card only.
public struct Samplers {
    public var cpu: () -> CPUSnapshot?
    public var memory: () -> MemorySnapshot?
    public var swap: () -> SwapSnapshot?
    public var gpu: () -> GPUSnapshot?
    public var volumes: (Date) -> [VolumeSnapshot]
    /// Called off the main actor's critical path; must return within a few seconds.
    public var docker: (Date) async -> DockerSnapshot
    public init(cpu: @escaping () -> CPUSnapshot?, memory: @escaping () -> MemorySnapshot?,
                swap: @escaping () -> SwapSnapshot?, gpu: @escaping () -> GPUSnapshot?,
                volumes: @escaping (Date) -> [VolumeSnapshot], docker: @escaping (Date) async -> DockerSnapshot) {
        self.cpu = cpu; self.memory = memory; self.swap = swap; self.gpu = gpu; self.volumes = volumes; self.docker = docker
    }

    /// The real samplers. CPU primes itself on creation so the first tick already has a value.
    public static func live() -> Samplers {
        let cpu = CPUSampler(), memory = MemorySampler(), swap = SwapSampler()
        let gpu = GPUSampler(), disks = DiskSampler(), docker = DockerSampler()
        return Samplers(cpu: cpu.sample, memory: memory.sample, swap: swap.sample, gpu: gpu.sample,
                        volumes: disks.sample(now:), docker: docker.sample(now:))
    }
}

/// Owns the samplers and publishes one immutable `SystemSnapshot` per tick for the UI.
///
/// Timer-driven on the main run loop. Synchronous samplers (CPU, RAM, GPU, swap, disks) are
/// cheap system calls and run inline on the main actor; Docker runs as a separate task and
/// writes `snapshot.docker` when it finishes, so a slow daemon never delays the other cards.
/// At most one Docker sample is in flight; a due Docker sample is skipped while one is running.
@MainActor
@Observable
public final class MetricsEngine {
    public private(set) var snapshot: SystemSnapshot = .empty
    public private(set) var history: History
    public let hostInfo: HostInfo

    /// Seconds between ticks (1, 2 or 5 in Settings). Changing it resets the history, because
    /// a ring buffer's capacity encodes the interval (always ~5 minutes of samples), and
    /// restarts the timer if it is running.
    public var refreshInterval: TimeInterval {
        didSet {
            guard refreshInterval != oldValue else { return }
            history = History(capacity: History.capacity(forInterval: refreshInterval))
            lastHistoryRecord = nil
            if timer != nil { start() }
        }
    }

    /// Set by the panel controller. Opening triggers an immediate full tick so the panel never
    /// shows stale detail data. That tick is off the timer's schedule: CPU reuses its last value
    /// if the window would be too short (`CPUSampler.minimumWindow`), and History skips it
    /// (see `tick`).
    public var isPanelOpen = false {
        didSet { if isPanelOpen && !oldValue { tick(now: Date()) } }
    }

    @ObservationIgnored private let samplers: Samplers
    @ObservationIgnored private var schedule = SamplingSchedule()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var dockerTask: Task<Void, Never>?
    @ObservationIgnored private var mountObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var lastHistoryRecord: Date?
    @ObservationIgnored private var startupRetry: Task<Void, Never>?

    public init(refreshInterval: TimeInterval = 2, samplers: Samplers = .live(), hostInfo: HostInfo = .current()) {
        self.refreshInterval = refreshInterval
        self.samplers = samplers
        self.hostInfo = hostInfo
        history = History(capacity: History.capacity(forInterval: refreshInterval))
    }

    /// Starts (or restarts) the timer and the mount/unmount observers, and ticks once now.
    ///
    /// On a cold start that tick has no CPU value (the samplers primed microseconds earlier,
    /// below `CPUSampler.minimumWindow`), so one extra tick runs once the window has passed;
    /// otherwise the menu bar would stay empty for a whole interval (up to 5 s).
    public func start() {
        timer?.invalidate()
        let t = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(now: Date()) }
        }
        t.tolerance = refreshInterval * 0.2       // let the system coalesce wakeups (idle-cost budget)
        RunLoop.main.add(t, forMode: .common)     // .common: keep ticking while a menu is tracking
        timer = t
        if mountObservers.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
                mountObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { if self?.isPanelOpen == true { self?.tick(now: Date()) } }
                })
            }
        }
        tick(now: Date())
        startupRetry?.cancel()
        startupRetry = nil
        if snapshot.cpu == nil {
            startupRetry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(CPUSampler.minimumWindow + 0.05))
                guard !Task.isCancelled, let self, self.timer != nil else { return }
                self.tick(now: Date())
            }
        }
    }

    /// Stops the timer and observers. An in-flight Docker sample still completes.
    public func stop() {
        timer?.invalidate(); timer = nil
        startupRetry?.cancel(); startupRetry = nil
        let center = NSWorkspace.shared.notificationCenter
        mountObservers.forEach { center.removeObserver($0) }
        mountObservers = []
    }

    /// Fills the engine with fixed data for SwiftUI previews and screenshot renders; does not
    /// start sampling. Not for production use.
    public func setPreviewState(snapshot: SystemSnapshot, cpuHistory: [Double], memoryHistory: [Double],
                                gpuHistory: [Double]) {
        var h = History(capacity: max(1, max(cpuHistory.count, memoryHistory.count, gpuHistory.count)))
        for i in 0..<max(cpuHistory.count, memoryHistory.count, gpuHistory.count) {
            h.record(SystemSnapshot(
                cpu: i < cpuHistory.count ? CPUSnapshot(total: cpuHistory[i], perCore: [], efficiencyCoreCount: 0) : nil,
                memory: i < memoryHistory.count
                    ? MemorySnapshot(total: 100, used: UInt64((memoryHistory[i] * 100).rounded()), app: 0, wired: 0,
                                     compressed: 0, pressure: .normal) : nil,
                gpu: i < gpuHistory.count ? GPUSnapshot(utilization: gpuHistory[i], memoryInUse: 0) : nil))
        }
        history = h
        self.snapshot = snapshot
    }

    /// One sampling pass. Internal so tests can drive time explicitly.
    func tick(now: Date) {
        let kinds = schedule.due(now: now, panelOpen: isPanelOpen)
        var next = snapshot
        next.timestamp = now
        next.cpu = samplers.cpu()
        next.memory = samplers.memory()
        if kinds.contains(.detail) {
            next.swap = samplers.swap()
            next.gpu = samplers.gpu()
            next.volumes = samplers.volumes(now)
        }
        snapshot = next
        // History capacity encodes ~5 minutes at one point per interval. Off-schedule ticks
        // (panel open, mount notifications) land between timer ticks and would compress the
        // sparkline's time axis, so a point is recorded only if half an interval has passed.
        // A clock stepped backwards records again rather than stalling History.
        if lastHistoryRecord.map({ let e = now.timeIntervalSince($0); return e >= refreshInterval / 2 || e < 0 }) ?? true {
            history.record(next)
            lastHistoryRecord = now
        }
        if kinds.contains(.docker), dockerTask == nil {
            let docker = samplers.docker
            dockerTask = Task { [weak self] in
                let result = await docker(now)
                self?.snapshot.docker = result
                self?.dockerTask = nil
            }
        }
    }
}
