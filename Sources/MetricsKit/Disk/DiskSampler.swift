import Foundation
import IOKit

/// Lists the volumes to show.
public protocol VolumeSource { func volumes() -> [VolumeInfo] }

/// The block storage driver behind a BSD name: which physical device it is, and its
/// cumulative byte counters if the driver publishes them.
public struct BlockDevice: Equatable, Sendable {
    /// Stable for as long as the device stays attached; volumes on one device share it.
    public var id: String
    public var counters: DiskIOCounters?
    public init(id: String, counters: DiskIOCounters?) { self.id = id; self.counters = counters }
}

/// Resolves the device behind a BSD name; `nil` if there is none.
public protocol DiskIOSource { func device(bsdName: String) -> BlockDevice? }

/// One row of the kernel mount table (`getfsstat`).
public struct MountEntry: Equatable, Sendable {
    public var path: String
    /// `f_mntfromname`: `/dev/disk3s1s1` for block devices, `//user@host/share` for SMB, etc.
    public var source: String
    public var flags: UInt32
    public init(path: String, source: String, flags: UInt32) { self.path = path; self.source = source; self.flags = flags }
    /// `MNT_LOCAL`: backed by local storage, so `statfs`/capacity queries cannot hang on a network.
    public var isLocal: Bool { flags & UInt32(MNT_LOCAL) != 0 }
    /// `MNT_DONTBROWSE` marks system and hidden mounts (Recovery, Preboot, the Data volume).
    public var isBrowsable: Bool { flags & UInt32(MNT_DONTBROWSE) == 0 }
    /// `disk3s1s1` for a mount from `/dev/disk3s1s1`, `nil` for anything without a `/dev` node.
    public var bsdName: String? { source.hasPrefix("/dev/") ? String(source.dropFirst(5)) : nil }
}

/// User-visible local volumes: the root file system plus anything under `/Volumes/`.
///
/// Network volumes (SMB, NFS, AFP, WebDAV) are **omitted** in v1. Listing comes from the
/// kernel mount table with `MNT_NOWAIT`, which returns cached data and never contacts a
/// server; capacity is then queried only for local mounts. Asking a dead SMB/NFS server for
/// its capacity blocks for seconds, and the engine samples disks on the main actor.
public struct FileManagerVolumeSource: VolumeSource {
    private static let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey,
        .volumeIsBrowsableKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey]
    public init() {}

    public func volumes() -> [VolumeInfo] {
        Self.candidates(Self.mountTable()).compactMap { mount in
            let url = URL(fileURLWithPath: mount.path, isDirectory: true)
            // A volume unmounted between listing and reading fails here and is dropped silently.
            guard let v = try? url.resourceValues(forKeys: Self.keys), v.volumeIsBrowsable == true else { return nil }
            let total = UInt64(max(0, v.volumeTotalCapacity ?? 0))
            let available = DiskCalculator.availableBytes(plain: v.volumeAvailableCapacity,
                                                          important: v.volumeAvailableCapacityForImportantUsage,
                                                          total: total)
            return VolumeInfo(path: mount.path, name: v.volumeName ?? url.lastPathComponent,
                              isInternal: v.volumeIsInternal ?? false, isRoot: v.volumeIsRootFileSystem == true,
                              total: total, available: available, bsdName: mount.bsdName)
        }
    }

    /// Mounts worth a capacity query: local, browsable, and either `/` or under `/Volumes/`.
    static func candidates(_ table: [MountEntry]) -> [MountEntry] {
        table.filter { $0.isLocal && $0.isBrowsable && ($0.path == "/" || $0.path.hasPrefix("/Volumes/")) }
    }

    /// The kernel mount table via `getfsstat(MNT_NOWAIT)`: no file system is asked for fresh
    /// statistics, so this cannot block on an unreachable server. Empty on failure.
    static func mountTable() -> [MountEntry] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        // Room for a few mounts appearing between the two calls; extra slots stay unused.
        var buffer = Array(repeating: statfs(), count: Int(count) + 8)
        let filled = buffer.withUnsafeMutableBufferPointer {
            getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        guard filled > 0 else { return [] }
        // The name fields are fixed-size C char arrays (tuples in Swift), NUL-terminated.
        func string<T>(_ field: T) -> String {
            withUnsafeBytes(of: field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
        return buffer.prefix(Int(filled)).map {
            MountEntry(path: string($0.f_mntonname), source: string($0.f_mntfromname), flags: $0.f_flags)
        }
    }
}

/// Walks up the IOService plane from the volume's IOMedia to the IOBlockStorageDriver that
/// owns the byte counters.
///
/// Observed chains on macOS 27 / M4:
/// - APFS root snapshot (8 hops): AppleAPFSSnapshot → AppleAPFSVolume → AppleAPFSContainer →
///   AppleAPFSMedia → AppleAPFSContainerScheme → IOMedia → IOGUIDPartitionScheme → IOMedia →
///   IOBlockStorageDriver.
/// - FSKit exFAT on USB (3 hops): IOMedia → IOGUIDPartitionScheme → IOMedia → IOBlockStorageDriver.
///
/// The counters belong to the *physical device*, so every APFS volume in one container (and
/// every partition on one disk) reports the same throughput. The device id is the driver's
/// IORegistry entry id: unique per attached device, and identical for every volume on it.
public struct IOKitDiskIOSource: DiskIOSource {
    /// Generous upper bound on the walk; the deepest observed chain is 8.
    private static let maxDepth = 24
    public init() {}

    public func device(bsdName: String) -> BlockDevice? {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
        // IOServiceGetMatchingService consumes `matching`.
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard entry != 0 else { return nil }
        for _ in 0..<Self.maxDepth {
            if IOObjectConformsTo(entry, "IOBlockStorageDriver") != 0 {
                defer { IOObjectRelease(entry) }
                var registryID: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(entry, &registryID) == KERN_SUCCESS else { return nil }
                var counters: DiskIOCounters?
                if let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                   let r = (stats["Bytes (Read)"] as? NSNumber)?.uint64Value,
                   let w = (stats["Bytes (Write)"] as? NSNumber)?.uint64Value {
                    counters = DiskIOCounters(read: r, write: w)
                }
                return BlockDevice(id: String(registryID), counters: counters)
            }
            var parent: io_registry_entry_t = 0
            let kr = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard kr == KERN_SUCCESS else { return nil }
            entry = parent
        }
        IOObjectRelease(entry)
        return nil
    }
}

/// Stateful disk sampler: capacity on every sample, throughput from the second sample of a
/// volume onwards. Not thread-safe; the engine calls it on the main actor.
public final class DiskSampler {
    /// A baseline older than this is not used for a rate. Disks are sampled only while the
    /// panel is open, so the first sample after reopening would otherwise show the average
    /// over the whole closed period as the current "/s". 10 s is two ticks at the slowest
    /// refresh interval (5 s) plus timer tolerance.
    public static let maxBaselineAge: TimeInterval = 10

    private let volumeSource: VolumeSource
    private let io: DiskIOSource
    /// Last counters per mount path. Rebuilt every sample, so a volume that disappears loses
    /// its baseline and a re-plugged device starts fresh instead of producing a spike.
    private var previous: [String: (counters: DiskIOCounters, at: Date)] = [:]

    public init(volumes: VolumeSource = FileManagerVolumeSource(), io: DiskIOSource = IOKitDiskIOSource()) {
        self.volumeSource = volumes; self.io = io
    }

    /// Current volumes in display order (`DiskCalculator.ordered`). Throughput fields are
    /// `nil` on a volume's first sample, after a gap longer than `maxBaselineAge`, and for
    /// volumes without block-driver statistics. `deviceID` is set whenever the driver is found.
    public func sample(now: Date) -> [VolumeSnapshot] {
        var next: [String: (counters: DiskIOCounters, at: Date)] = [:]
        let snapshots = volumeSource.volumes().map { info -> VolumeSnapshot in
            var s = VolumeSnapshot(id: info.path, name: info.name, isInternal: info.isInternal, isRoot: info.isRoot,
                                   total: info.total, available: info.available)
            guard let bsd = info.bsdName, let device = io.device(bsdName: bsd) else { return s }
            s.deviceID = device.id
            if let current = device.counters {
                if let prev = previous[info.path], now.timeIntervalSince(prev.at) <= Self.maxBaselineAge,
                   let r = DiskCalculator.rate(previous: prev.counters, current: current, elapsed: now.timeIntervalSince(prev.at)) {
                    s.readBytesPerSecond = r.read; s.writeBytesPerSecond = r.write
                }
                next[info.path] = (current, now)
            }
            return s
        }
        previous = next
        return DiskCalculator.ordered(snapshots)
    }
}
