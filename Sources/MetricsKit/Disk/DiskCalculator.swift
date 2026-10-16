import Foundation

/// Cumulative bytes transferred by a block device since it attached.
public struct DiskIOCounters: Equatable, Sendable {
    public var read: UInt64, write: UInt64
    public init(read: UInt64, write: UInt64) { self.read = read; self.write = write }
}

/// One mounted volume as reported by the volume source, before throughput is attached.
public struct VolumeInfo: Equatable, Sendable {
    public var path: String, name: String, isInternal: Bool, isRoot: Bool
    public var total: UInt64, available: UInt64
    /// BSD name of the mounted device (`disk3s1s1`), or `nil` for volumes without a `/dev`
    /// node (network shares, some FSKit/FUSE mounts) — those simply get no throughput.
    public var bsdName: String?
    public init(path: String, name: String, isInternal: Bool, isRoot: Bool, total: UInt64, available: UInt64, bsdName: String?) {
        self.path = path; self.name = name; self.isInternal = isInternal; self.isRoot = isRoot
        self.total = total; self.available = available; self.bsdName = bsdName
    }
}

public enum DiskCalculator {
    /// Bytes per second between two counter reads.
    ///
    /// - Returns: `nil` when `elapsed <= 0` (first sample at the same instant, or the wall clock
    ///   stepped backwards). A counter that went backwards (device re-attached) yields 0 for
    ///   that direction instead of a huge unsigned wrap-around.
    public static func rate(previous: DiskIOCounters, current: DiskIOCounters, elapsed: TimeInterval) -> (read: Double, write: Double)? {
        guard elapsed > 0 else { return nil }
        let r = current.read >= previous.read ? current.read - previous.read : 0
        let w = current.write >= previous.write ? current.write - previous.write : 0
        return (Double(r) / elapsed, Double(w) / elapsed)
    }

    /// Free space to display, from the two capacity keys `URLResourceValues` offers.
    ///
    /// "Important usage" counts purgeable space as free and matches Finder on APFS, so it wins
    /// when larger. FSKit volumes (exFAT/NTFS on macOS 15+) report it as **0** rather than
    /// omitting it — taking the larger value keeps them from showing as 100% full.
    /// The result is clamped to `0...total`.
    public static func availableBytes(plain: Int?, important: Int64?, total: UInt64) -> UInt64 {
        let p = UInt64(max(0, plain ?? 0)), i = UInt64(max(0, important ?? 0))
        return min(max(p, i), total)
    }

    /// Display order: the root volume first, then other internal volumes, then external ones,
    /// each group sorted by name the way Finder sorts (`localizedStandardCompare`).
    public static func ordered(_ volumes: [VolumeSnapshot]) -> [VolumeSnapshot] {
        volumes.sorted { a, b in
            if a.isRoot != b.isRoot { return a.isRoot }
            if a.isInternal != b.isInternal { return a.isInternal }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
