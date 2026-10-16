import Foundation
import IOKit

public struct HostInfo: Equatable, Sendable {
    public var modelName: String      // "Mac mini (2024)"
    public var chip: String           // "Apple M4"
    public var bootTime: Date?
    public init(modelName: String, chip: String, bootTime: Date?) {
        self.modelName = modelName; self.chip = chip; self.bootTime = bootTime
    }
    public static func current() -> HostInfo {
        HostInfo(modelName: productName() ?? Sysctl.string("hw.model") ?? "Mac",
                 chip: Sysctl.string("machdep.cpu.brand_string") ?? "Apple Silicon",
                 bootTime: Sysctl.value("kern.boottime", as: timeval.self).map {
                     Date(timeIntervalSince1970: TimeInterval($0.tv_sec) + TimeInterval($0.tv_usec) / 1_000_000)
                 })
    }
    private static func productName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data else { return nil }
        return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
    }
}
