import Foundation

public struct CPUSnapshot: Equatable, Sendable, Codable {
    public var total: Double
    public var perCore: [Double]
    public var efficiencyCoreCount: Int
    public init(total: Double, perCore: [Double], efficiencyCoreCount: Int) {
        self.total = total; self.perCore = perCore; self.efficiencyCoreCount = efficiencyCoreCount
    }
    private var efficiencySplit: Int { min(max(0, efficiencyCoreCount), perCore.count) }
    public var efficiencyCores: ArraySlice<Double> { perCore.prefix(efficiencySplit) }
    public var performanceCores: ArraySlice<Double> { perCore.dropFirst(efficiencySplit) }
}

public enum MemoryPressure: Equatable, Sendable, Codable { case normal, warning, critical }

public struct MemorySnapshot: Equatable, Sendable, Codable {
    public var total: UInt64, used: UInt64, app: UInt64, wired: UInt64, compressed: UInt64
    public var pressure: MemoryPressure
    public init(total: UInt64, used: UInt64, app: UInt64, wired: UInt64, compressed: UInt64, pressure: MemoryPressure) {
        self.total = total; self.used = used; self.app = app; self.wired = wired
        self.compressed = compressed; self.pressure = pressure
    }
    public var usedFraction: Double { total == 0 ? 0 : min(1, Double(used) / Double(total)) }
}

public struct SwapSnapshot: Equatable, Sendable, Codable {
    public var total: UInt64, used: UInt64
    public init(total: UInt64, used: UInt64) { self.total = total; self.used = used }
    public var usedFraction: Double { total == 0 ? 0 : min(1, Double(used) / Double(total)) }
}

public struct GPUSnapshot: Equatable, Sendable, Codable {
    public var utilization: Double
    public var memoryInUse: UInt64
    public init(utilization: Double, memoryInUse: UInt64) { self.utilization = utilization; self.memoryInUse = memoryInUse }
}

public struct VolumeSnapshot: Equatable, Sendable, Codable, Identifiable {
    public var id: String           // mount path
    public var name: String
    public var isInternal: Bool
    public var isRoot: Bool
    public var total: UInt64
    public var available: UInt64
    public var readBytesPerSecond: Double?
    public var writeBytesPerSecond: Double?
    /// Identifies the physical device the throughput counters belong to. Volumes that share a
    /// device (APFS volumes in one container, partitions of one disk) report the same rates, so
    /// the UI shows the rates once per device. `nil` when the device could not be resolved.
    public var deviceID: String?
    public init(id: String, name: String, isInternal: Bool, isRoot: Bool, total: UInt64, available: UInt64,
                readBytesPerSecond: Double? = nil, writeBytesPerSecond: Double? = nil, deviceID: String? = nil) {
        self.id = id; self.name = name; self.isInternal = isInternal; self.isRoot = isRoot
        self.total = total; self.available = available
        self.readBytesPerSecond = readBytesPerSecond; self.writeBytesPerSecond = writeBytesPerSecond
        self.deviceID = deviceID
    }
    public var used: UInt64 { total > available ? total - available : 0 }
    public var usedFraction: Double { total == 0 ? 0 : min(1, Double(used) / Double(total)) }
}

public enum DockerState: Equatable, Sendable, Codable { case notInstalled, notRunning, running }

public struct ContainerSnapshot: Equatable, Sendable, Codable, Identifiable {
    public var id: String, name: String
    public var cpuPercent: Double?    // percent of one core, may exceed 100
    public var memory: UInt64
    public init(id: String, name: String, cpuPercent: Double?, memory: UInt64) {
        self.id = id; self.name = name; self.cpuPercent = cpuPercent; self.memory = memory
    }
}

public struct DockerSnapshot: Equatable, Sendable, Codable {
    public var state: DockerState
    public var containers: [ContainerSnapshot]     // sorted by memory desc
    public var diskUsage: UInt64?                  // images + volumes + build cache + container rw
    /// CPUs and memory of the Docker VM (`/info` NCPU, MemTotal) — container CPU % is relative
    /// to one of these vCPUs, not to the Mac's cores.
    public var vmCPUCount: Int?
    public var vmMemoryTotal: UInt64?
    public init(state: DockerState, containers: [ContainerSnapshot] = [], diskUsage: UInt64? = nil,
                vmCPUCount: Int? = nil, vmMemoryTotal: UInt64? = nil) {
        self.state = state; self.containers = containers; self.diskUsage = diskUsage
        self.vmCPUCount = vmCPUCount; self.vmMemoryTotal = vmMemoryTotal
    }
    /// Total container CPU expressed in vCPUs (100% of one core = 1.0).
    public var totalCPUCores: Double { totalCPUPercent / 100 }
    public var totalCPUPercent: Double { containers.compactMap(\.cpuPercent).reduce(0, +) }
    /// Saturates at `UInt64.max`: the per-container values come from the daemon.
    public var totalMemory: UInt64 { containers.map(\.memory).saturatingSum }
    public static let notInstalled = DockerSnapshot(state: .notInstalled)
}

/// One app (all of its helper processes together) or one standalone process.
public struct ProcessUsage: Equatable, Sendable, Codable, Identifiable {
    public var id: String { name }
    public var name: String
    /// Processes summed into this row (an app's helpers count here).
    public var processCount: Int
    /// CPU since the previous sample, as a fraction of one core (1.0 = 100%, can exceed 1).
    /// `nil` on the first sample after the panel opens, before there is a window to measure.
    public var cpu: Double?
    /// Physical footprint (what Activity Monitor calls Memory), summed.
    public var memory: UInt64
    public init(name: String, processCount: Int, cpu: Double?, memory: UInt64) {
        self.name = name; self.processCount = processCount; self.cpu = cpu; self.memory = memory
    }
}

public struct ProcessesSnapshot: Equatable, Sendable, Codable {
    public var topCPU: [ProcessUsage]
    public var topMemory: [ProcessUsage]
    /// Processes of other users and of the system (WindowServer, kernel_task…) that an
    /// unprivileged app cannot read; they are not in the lists.
    public var unreadableCount: Int
    public init(topCPU: [ProcessUsage], topMemory: [ProcessUsage], unreadableCount: Int) {
        self.topCPU = topCPU; self.topMemory = topMemory; self.unreadableCount = unreadableCount
    }
}

public struct SystemSnapshot: Equatable, Sendable, Codable {
    public var timestamp: Date
    public var cpu: CPUSnapshot?
    public var memory: MemorySnapshot?
    public var swap: SwapSnapshot?
    public var gpu: GPUSnapshot?
    public var volumes: [VolumeSnapshot]
    public var docker: DockerSnapshot?          // nil = not sampled yet
    /// Top apps by CPU and memory; nil = not sampled yet (or a peer from before this field).
    public var processes: ProcessesSnapshot?
    public init(timestamp: Date = .distantPast, cpu: CPUSnapshot? = nil, memory: MemorySnapshot? = nil,
                swap: SwapSnapshot? = nil, gpu: GPUSnapshot? = nil, volumes: [VolumeSnapshot] = [],
                docker: DockerSnapshot? = nil, processes: ProcessesSnapshot? = nil) {
        self.timestamp = timestamp; self.cpu = cpu; self.memory = memory; self.swap = swap
        self.gpu = gpu; self.volumes = volumes; self.docker = docker; self.processes = processes
    }
    public static let empty = SystemSnapshot()
}
