import Foundation

/// Cumulative CPU counters for one container at one moment.
struct DockerCPUSample: Equatable, Sendable {
    var container: UInt64, system: UInt64, onlineCPUs: Int
}

enum DockerCalculator {
    /// Upper bound on `online_cpus` taken from the daemon. Linux's default `NR_CPUS` ceiling is
    /// far below this; the bound only exists so a hostile value cannot make the result absurd.
    static let maxCPUs = 1024

    /// Same formula as `docker stats`: Δcontainer / Δsystem × online CPUs × 100, i.e. percent of
    /// one core (400 = four cores busy).
    ///
    /// `one-shot=true` returns an empty `precpu_stats`, so the caller supplies its own previous
    /// sample. Returns `nil` when the system counter did not advance or the container counter
    /// went backwards (container restarted under the same id). The result is clamped to
    /// `0...cores × 100` with `cores = online_cpus` limited to `1...maxCPUs`: a container cannot
    /// use more than every CPU, and the inputs are daemon-controlled.
    static func cpuPercent(previous: DockerCPUSample, current: DockerCPUSample) -> Double? {
        guard current.system > previous.system, current.container >= previous.container else { return nil }
        let c = Double(current.container - previous.container), s = Double(current.system - previous.system)
        let cores = Double(min(max(1, current.onlineCPUs), maxCPUs))
        return min(max(0, c / s * cores * 100), cores * 100)
    }

    static func cpuSample(_ stats: DockerStats) -> DockerCPUSample? {
        guard let system = stats.cpu_stats.system_cpu_usage else { return nil }
        return DockerCPUSample(container: stats.cpu_stats.cpu_usage.total_usage, system: system,
                               onlineCPUs: stats.cpu_stats.online_cpus ?? 1)
    }

    /// Working set as `docker stats` shows it: usage minus reclaimable page cache
    /// (cgroup v2 `inactive_file`, cgroup v1 `total_inactive_file`).
    static func memoryUsage(_ stats: DockerStats) -> UInt64 {
        let usage = stats.memory_stats.usage ?? 0
        let cache = stats.memory_stats.stats?["inactive_file"] ?? stats.memory_stats.stats?["total_inactive_file"] ?? 0
        return usage > cache ? usage - cache : 0
    }

    /// Images (layers) + volumes + build cache + container writable layers, in bytes.
    /// Negative sizes (-1 = "not computed") count as zero; the sum saturates at `UInt64.max`.
    static func diskUsage(_ df: DockerDiskUsage) -> UInt64 {
        func pos(_ v: Int64?) -> UInt64 { UInt64(max(0, v ?? 0)) }
        return ([pos(df.LayersSize)]
            + (df.Volumes ?? []).map { pos($0.UsageData?.Size) }
            + (df.BuildCache ?? []).map { pos($0.Size) }
            + (df.Containers ?? []).map { pos($0.SizeRw) }).saturatingSum
    }
}
