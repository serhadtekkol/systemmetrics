import Darwin

/// The subset of `vm_statistics64` the memory breakdown needs, widened to `UInt64`.
public struct VMPageCounts: Equatable, Sendable {
    public var pageSize: UInt64, `internal`: UInt64, purgeable: UInt64, wired: UInt64, compressed: UInt64
    public init(pageSize: UInt64, `internal`: UInt64, purgeable: UInt64, wired: UInt64, compressed: UInt64) {
        self.pageSize = pageSize; self.`internal` = `internal`; self.purgeable = purgeable
        self.wired = wired; self.compressed = compressed
    }
}

public enum MemoryCalculator {
    /// Same breakdown as Activity Monitor: app = internal − purgeable; used = app + wired + compressed.
    ///
    /// - Parameter pressureLevel: raw `kern.memorystatus_vm_pressure_level`
    ///   (1 normal, 2 warning, 4 critical — the kernel's `kVMPressure*` values). Unknown values map to normal.
    /// - Returns: A snapshot whose `used` is clamped to `physical`, because the page counters
    ///   are read non-atomically and can briefly overshoot.
    public static func snapshot(pages: VMPageCounts, physical: UInt64, pressureLevel: Int) -> MemorySnapshot {
        let appPages = pages.internal > pages.purgeable ? pages.internal - pages.purgeable : 0
        let app = appPages * pages.pageSize
        let wired = pages.wired * pages.pageSize
        let compressed = pages.compressed * pages.pageSize
        let pressure: MemoryPressure = switch pressureLevel { case 4: .critical; case 2: .warning; default: .normal }
        return MemorySnapshot(total: physical, used: min(physical, app + wired + compressed),
                              app: app, wired: wired, compressed: compressed, pressure: pressure)
    }

    /// Converts the `vm.swapusage` struct. The struct is used instead of the text form because
    /// `sysctl` prints localized decimals (`8192,00M` under a Turkish locale).
    public static func swap(_ usage: xsw_usage) -> SwapSnapshot {
        SwapSnapshot(total: usage.xsu_total, used: usage.xsu_used)
    }
}
