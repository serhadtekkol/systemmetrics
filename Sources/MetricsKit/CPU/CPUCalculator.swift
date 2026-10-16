/// Cumulative scheduler ticks for one logical CPU, as reported by `host_processor_info`.
public struct CPUTicks: Equatable, Sendable {
    public var user: UInt64, system: UInt64, idle: UInt64, nice: UInt64
    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user; self.system = system; self.idle = idle; self.nice = nice
    }
}

/// Pure tick-delta math; the sampler owns the state between two reads.
public enum CPUCalculator {
    /// Ticks elapsed between two reads of one 32-bit kernel counter.
    ///
    /// The counters are `UInt32` (widened to `UInt64` only for storage), so they **wrap**:
    /// idle wraps first, after ~497 days of one core idling at 100 Hz. Modular `UInt32`
    /// subtraction gives the true delta across a wrap. Clamping a "negative" delta to 0
    /// instead would turn an idle-only wrap into a 100%-busy spike.
    ///
    /// A modular delta above 2^31 cannot be real — that is ~248 days of ticks between two
    /// samples taken seconds apart — so it is read as a counter **reset** and counts as 0,
    /// which keeps a reset to one quiet sample.
    static func delta(_ old: UInt64, _ new: UInt64) -> UInt64 {
        let d = UInt32(truncatingIfNeeded: new) &- UInt32(truncatingIfNeeded: old)
        return d > UInt32.max / 2 ? 0 : UInt64(d)
    }

    /// Busy fraction (0...1) per core and in total between two tick reads.
    ///
    /// - Parameters:
    ///   - previous: Ticks from the earlier read.
    ///   - current: Ticks from the later read; must have the same core count.
    ///   - efficiencyCoreCount: How many leading entries are E-cores (passed through to the snapshot).
    /// - Returns: `nil` when either read is empty or the core counts differ (e.g. CPUs taken
    ///   offline between reads), because per-core deltas would then be meaningless.
    public static func usage(previous: [CPUTicks], current: [CPUTicks], efficiencyCoreCount: Int) -> CPUSnapshot? {
        guard !current.isEmpty, previous.count == current.count else { return nil }
        var perCore: [Double] = []
        perCore.reserveCapacity(current.count)
        var busySum: UInt64 = 0, totalSum: UInt64 = 0
        for (p, c) in zip(previous, current) {
            let busy = delta(p.user, c.user) + delta(p.system, c.system) + delta(p.nice, c.nice)
            let total = busy + delta(p.idle, c.idle)
            perCore.append(total == 0 ? 0 : Double(busy) / Double(total))
            busySum += busy; totalSum += total
        }
        return CPUSnapshot(total: totalSum == 0 ? 0 : Double(busySum) / Double(totalSum),
                           perCore: perCore, efficiencyCoreCount: efficiencyCoreCount)
    }
}
