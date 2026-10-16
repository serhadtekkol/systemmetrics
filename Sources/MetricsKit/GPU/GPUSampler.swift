import Foundation
import IOKit

/// Parses the IOAccelerator `PerformanceStatistics` dictionary.
///
/// The keys are undocumented (observed on M-series with macOS 14–27). If Apple renames them,
/// `parse` returns `nil` and the GPU card shows "veri yok" instead of failing.
public enum GPUStatsParser {
    /// - Returns: `nil` when `Device Utilization %` is missing, not a number, or not finite
    ///   (`min`/`max` let NaN through, so it would otherwise reach History and the gauge). A
    ///   missing memory key yields `memoryInUse == 0` rather than hiding the utilization.
    public static func parse(_ stats: [String: Any]) -> GPUSnapshot? {
        guard let util = (stats["Device Utilization %"] as? NSNumber)?.doubleValue, util.isFinite else { return nil }
        let memory = (stats["In use system memory"] as? NSNumber)?.uint64Value ?? 0
        return GPUSnapshot(utilization: min(max(util / 100, 0), 1), memoryInUse: memory)
    }
}

/// Stateless GPU sampler; the reader is injectable so tests never touch IOKit.
public final class GPUSampler {
    private let read: () -> [String: Any]?
    public init(read: @escaping () -> [String: Any]? = GPUSampler.readIOAccelerator) { self.read = read }

    /// Current utilization and memory, or `nil` if the registry read or the parse fails.
    public func sample() -> GPUSnapshot? { read().flatMap(GPUStatsParser.parse) }

    /// `PerformanceStatistics` of the first IOAccelerator that publishes one (Apple Silicon has
    /// a single AGXAccelerator). Public registry read; no entitlement or root needed.
    public static func readIOAccelerator() -> [String: Any]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                                                           kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
                return stats
            }
        }
        return nil
    }
}
