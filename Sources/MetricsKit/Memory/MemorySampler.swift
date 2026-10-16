import Darwin
import Foundation

/// Physical memory breakdown via `host_statistics64(HOST_VM_INFO64)`. Stateless.
public final class MemorySampler {
    // Fetched once: every `mach_host_self()` call adds a send right that would otherwise leak.
    private let host = mach_host_self()
    private let physical = ProcessInfo.processInfo.physicalMemory
    public init() {}

    /// Current breakdown, or `nil` if the Mach call fails.
    public func sample() -> MemorySnapshot? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pages = VMPageCounts(pageSize: UInt64(vm_kernel_page_size),
                                 internal: UInt64(stats.internal_page_count),
                                 purgeable: UInt64(stats.purgeable_count),
                                 wired: UInt64(stats.wire_count),
                                 compressed: UInt64(stats.compressor_page_count))
        let level = Sysctl.int("kern.memorystatus_vm_pressure_level") ?? 1
        return MemoryCalculator.snapshot(pages: pages, physical: physical, pressureLevel: level)
    }
}

/// Swap usage via the binary `vm.swapusage` sysctl (`xsw_usage`). Stateless.
public final class SwapSampler {
    public init() {}
    /// Current swap usage, or `nil` if the sysctl fails.
    public func sample() -> SwapSnapshot? {
        Sysctl.value("vm.swapusage", as: xsw_usage.self).map(MemoryCalculator.swap)
    }
}
