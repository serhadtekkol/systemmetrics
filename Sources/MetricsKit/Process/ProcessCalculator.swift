import Foundation

/// One process as read in one sample.
public struct ProcessReading: Equatable, Sendable {
    public var pid: Int32
    /// Start time; with the pid it identifies the process across samples (pids are reused).
    public var start: UInt64
    /// Display group: the outermost app bundle the executable is in, else the executable name.
    public var group: String
    /// User + system CPU time, nanoseconds.
    public var cpuTime: UInt64
    public var memory: UInt64
    public init(pid: Int32, start: UInt64, group: String, cpuTime: UInt64, memory: UInt64) {
        self.pid = pid; self.start = start; self.group = group; self.cpuTime = cpuTime; self.memory = memory
    }
}

/// Pure part of the process list: CPU deltas between two samples, grouping, ranking.
public enum ProcessCalculator {
    public struct Key: Hashable, Sendable { var pid: Int32; var start: UInt64 }

    /// `previous` maps processes to their CPU time at `elapsed` seconds ago; nil = no usable
    /// baseline, so CPU is unknown. A process new since then counts from zero only if it started
    /// inside the window, otherwise it is skipped for CPU (its whole lifetime is not "now").
    public static func snapshot(readings: [ProcessReading], previous: [Key: UInt64]?, elapsed: TimeInterval,
                                unreadable: Int, limit: Int = 5) -> ProcessesSnapshot {
        struct Group { var count = 0; var cpuNs: UInt64 = 0; var memory: UInt64 = 0 }
        var groups: [String: Group] = [:]
        for r in readings {
            var g = groups[r.group, default: Group()]
            g.count += 1
            g.memory = g.memory.addingReportingOverflow(r.memory).overflow ? .max : g.memory + r.memory
            if let previous, let before = previous[Key(pid: r.pid, start: r.start)], r.cpuTime >= before {
                g.cpuNs += r.cpuTime - before
            }
            groups[r.group] = g
        }
        let haveCPU = previous != nil && elapsed > 0
        let rows = groups.map { name, g in
            ProcessUsage(name: name, processCount: g.count,
                         cpu: haveCPU ? Double(g.cpuNs) / 1e9 / elapsed : nil, memory: g.memory)
        }
        let byCPU = haveCPU
            ? rows.sorted { ($0.cpu ?? 0, $0.memory) > ($1.cpu ?? 0, $1.memory) }.prefix(limit)
            : []
        let byMemory = rows.sorted { ($0.memory, $0.name) > ($1.memory, $1.name) }.prefix(limit)
        return ProcessesSnapshot(topCPU: Array(byCPU), topMemory: Array(byMemory), unreadableCount: unreadable)
    }

    /// "Google Chrome" for ".../Google Chrome.app/.../Google Chrome Helper (Renderer)", the
    /// executable's file name for anything outside an app bundle.
    public static func group(forExecutablePath path: String, fallbackName: String) -> String {
        let parts = path.split(separator: "/")
        if let app = parts.first(where: { $0.hasSuffix(".app") }) { return String(app.dropLast(4)) }
        return parts.last.map(String.init) ?? fallbackName
    }
}
