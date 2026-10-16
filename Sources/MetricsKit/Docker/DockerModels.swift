import Foundation

// Decodable subsets of Docker Engine API responses (verified against Engine 29.x).
// Only the fields the app reads are declared, so additive API changes cannot break decoding.
// Property names mirror the JSON keys on purpose, which keeps these types greppable against the API docs.

/// One entry of `GET /containers/json`.
struct DockerContainerSummary: Decodable {
    let id: String
    let names: [String]
    enum CodingKeys: String, CodingKey { case id = "Id", names = "Names" }
    /// `Names` entries carry a leading `/`; falls back to the short id like `docker ps`.
    var displayName: String { names.first.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 } ?? String(id.prefix(12)) }
}

/// `GET /containers/{id}/stats?stream=false&one-shot=true`.
struct DockerStats: Decodable {
    struct CPUStats: Decodable {
        struct Usage: Decodable { let total_usage: UInt64 }
        let cpu_usage: Usage
        /// Host-wide CPU time in ns; absent on Windows daemons.
        let system_cpu_usage: UInt64?
        let online_cpus: Int?
    }
    struct MemoryStats: Decodable {
        let usage: UInt64?
        /// Raw cgroup `memory.stat` counters (all non-negative integers on Linux).
        let stats: [String: UInt64]?
    }
    let cpu_stats: CPUStats
    let memory_stats: MemoryStats
}

/// `GET /system/df`. Arrays may be `null` on an empty daemon.
struct DockerDiskUsage: Decodable {
    struct Volume: Decodable {
        /// `Size` is -1 when the daemon has not computed it.
        struct Usage: Decodable { let Size: Int64 }
        let UsageData: Usage?
    }
    struct Cache: Decodable { let Size: Int64? }
    struct Container: Decodable { let SizeRw: Int64? }
    let LayersSize: Int64?
    let Volumes: [Volume]?
    let BuildCache: [Cache]?
    let Containers: [Container]?
}

/// `GET /info`, only the Docker VM's size. On Docker Desktop, OrbStack and Colima these are
/// the Linux VM's CPUs and memory, which is what container CPU % and memory are relative to.
struct DockerInfo: Decodable {
    let NCPU: Int?
    let MemTotal: Int64?

    /// `NCPU` when plausible (`1...DockerCalculator.maxCPUs`), else `nil`.
    var cpuCount: Int? { NCPU.flatMap { (1...DockerCalculator.maxCPUs).contains($0) ? $0 : nil } }
    /// `MemTotal` in bytes when positive, else `nil`.
    var memoryTotal: UInt64? { MemTotal.flatMap { $0 > 0 ? UInt64($0) : nil } }
}
