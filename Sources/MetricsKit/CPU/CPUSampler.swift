import Darwin
import Foundation

/// Reads the current cumulative ticks for every logical CPU. Returns `nil` on failure.
public protocol CPUTickSource: AnyObject { func read() -> [CPUTicks]? }

/// `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` — public Mach API, no privileges needed.
public final class MachCPUTickSource: CPUTickSource {
    // Fetched once: every `mach_host_self()` call adds a send right that would otherwise leak.
    private let host = mach_host_self()
    public init() {}
    public func read() -> [CPUTicks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        // The kernel allocates the array in our address space; we own it.
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        // The loop below indexes `cpuCount * CPU_STATE_MAX` slots; never trust that the two
        // counts the kernel returned agree.
        guard Int(infoCount) >= Int(cpuCount) * Int(CPU_STATE_MAX) else { return nil }
        return (0..<Int(cpuCount)).map { cpu in
            let base = cpu * Int(CPU_STATE_MAX)
            // Ticks are unsigned 32-bit counters stored in signed integer_t slots.
            func tick(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[base + Int(state)])) }
            return CPUTicks(user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM),
                            idle: tick(CPU_STATE_IDLE), nice: tick(CPU_STATE_NICE))
        }
    }
}

/// Stateful CPU sampler: each `sample()` reports usage since the previous read.
///
/// On Apple Silicon the kernel numbers efficiency cores first (verified via IODeviceTree
/// `cluster-type` on an M4), so the first `hw.perflevel1.logicalcpu` entries are E-cores.
/// Not thread-safe; call from one thread (the engine calls it on the main actor).
public final class CPUSampler {
    /// Shortest window usage is computed over. Mach ticks advance at 100 Hz, so a window of a
    /// few milliseconds holds 0 or 1 tick per core and every core reads exactly 0% or 100%.
    /// That happens whenever the engine ticks off-schedule (panel opening right after a timer
    /// tick, the immediate tick in `start()`); 0.5 s gives ~50 ticks per core, i.e. 2% steps.
    public static let minimumWindow: TimeInterval = 0.5

    private let source: CPUTickSource
    private let efficiencyCoreCount: Int
    private let clock: () -> TimeInterval
    private var previous: (ticks: [CPUTicks], at: TimeInterval)?
    private var last: CPUSnapshot?

    /// Reads once immediately so a `sample()` one window later already has a baseline.
    ///
    /// - Parameter clock: Monotonic seconds; injectable for tests. `systemUptime` does not
    ///   advance during sleep, which matches the tick counters (they do not either).
    public init(source: CPUTickSource = MachCPUTickSource(),
                efficiencyCoreCount: Int = Sysctl.int("hw.perflevel1.logicalcpu") ?? 0,
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.source = source
        self.efficiencyCoreCount = efficiencyCoreCount
        self.clock = clock
        previous = source.read().map { ($0, clock()) }
    }

    /// Usage since the last read.
    ///
    /// Called sooner than `minimumWindow` after the last read, returns the last value without
    /// reading (and without moving the baseline), so a burst of extra ticks never publishes a
    /// quantized value; that is `nil` when nothing has been computed yet (e.g. right after
    /// `init`). Also `nil` if the source fails now or there is no baseline.
    public func sample() -> CPUSnapshot? {
        let now = clock()
        if let previous, now >= previous.at, now - previous.at < Self.minimumWindow { return last }
        guard let current = source.read() else { last = nil; return nil }
        defer { previous = (current, now) }
        guard let previous else { return nil }
        last = CPUCalculator.usage(previous: previous.ticks, current: current, efficiencyCoreCount: efficiencyCoreCount)
        return last
    }
}
