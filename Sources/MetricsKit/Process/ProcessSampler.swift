import Darwin
import Foundation

/// Reads every process the current user may inspect (`proc_pid_rusage`, no privileges) and
/// reports the top apps by CPU and by memory. CPU is measured between two calls, so the first
/// call after a pause (panel closed) returns memory only.
///
/// Not thread-safe; the engine calls it on the main actor while the panel is open.
public final class ProcessSampler {
    /// A baseline older than this is discarded: CPU averaged over minutes would not be "now".
    static let maxWindow: TimeInterval = 15

    private var previous: [ProcessCalculator.Key: UInt64]?
    private var previousTime: Date?
    /// Executable groups by process identity; a path never changes for a running process.
    private var groups: [ProcessCalculator.Key: String] = [:]
    private let timebase: (numer: UInt64, denom: UInt64)

    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = (UInt64(max(info.numer, 1)), UInt64(max(info.denom, 1)))
    }

    public func sample(now: Date) -> ProcessesSnapshot? {
        let capacity = 8_192
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return nil }

        var readings: [ProcessReading] = []
        readings.reserveCapacity(count)
        var unreadable = 0
        var seen: [ProcessCalculator.Key: String] = [:]
        for pid in pids.prefix(min(count, capacity)) where pid > 0 {
            var info = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard status == 0 else { unreadable += 1; continue }
            let key = ProcessCalculator.Key(pid: pid, start: info.ri_proc_start_abstime)
            let group = groups[key] ?? Self.group(of: pid)
            seen[key] = group
            readings.append(ProcessReading(pid: pid, start: key.start, group: group,
                                           cpuTime: nanoseconds(info.ri_user_time &+ info.ri_system_time),
                                           memory: info.ri_phys_footprint))
        }
        groups = seen       // drops exited processes

        let elapsed = previousTime.map { now.timeIntervalSince($0) } ?? 0
        let baseline = (elapsed > 0 && elapsed <= Self.maxWindow) ? previous : nil
        let result = ProcessCalculator.snapshot(readings: readings, previous: baseline, elapsed: elapsed,
                                                unreadable: unreadable)
        previous = Dictionary(uniqueKeysWithValues: readings.map {
            (ProcessCalculator.Key(pid: $0.pid, start: $0.start), $0.cpuTime)
        })
        previousTime = now
        return result
    }

    private func nanoseconds(_ machTime: UInt64) -> UInt64 {
        let (q, overflow) = machTime.multipliedReportingOverflow(by: timebase.numer)
        return overflow ? machTime / timebase.denom * timebase.numer : q / timebase.denom
    }

    private static func group(of pid: pid_t) -> String {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        var name = [CChar](repeating: 0, count: 256)
        proc_name(pid, &name, UInt32(name.count))
        let fallback = String(cString: name)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return fallback.isEmpty ? "pid \(pid)" : fallback }
        return ProcessCalculator.group(forExecutablePath: String(cString: path), fallbackName: fallback)
    }
}
