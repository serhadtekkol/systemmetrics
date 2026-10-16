import Testing
import Foundation
import Darwin
@testable import MetricsKit

struct DiskCalculatorTests {
    @Test func rateUsesElapsedTime() throws {
        let r = try #require(DiskCalculator.rate(previous: DiskIOCounters(read: 0, write: 100),
                                                 current: DiskIOCounters(read: 4_000, write: 300), elapsed: 2))
        #expect(r.read == 2_000)
        #expect(r.write == 100)
    }
    @Test func counterResetYieldsZeroNotHuge() throws {
        let r = try #require(DiskCalculator.rate(previous: DiskIOCounters(read: 10_000, write: 10_000),
                                                 current: DiskIOCounters(read: 5, write: 5), elapsed: 1))
        #expect(r.read == 0 && r.write == 0)
    }
    @Test func zeroElapsedIsNil() {
        #expect(DiskCalculator.rate(previous: DiskIOCounters(read: 0, write: 0),
                                    current: DiskIOCounters(read: 1, write: 1), elapsed: 0) == nil)
    }
    @Test func negativeElapsedIsNil() {
        // Wall clock stepped backwards (NTP correction, manual change).
        #expect(DiskCalculator.rate(previous: DiskIOCounters(read: 0, write: 0),
                                    current: DiskIOCounters(read: 1, write: 1), elapsed: -5) == nil)
    }
    @Test func orderRootThenInternalThenExternalByName() {
        let v = [VolumeSnapshot(id: "/Volumes/b", name: "b", isInternal: false, isRoot: false, total: 1, available: 1),
                 VolumeSnapshot(id: "/Volumes/a", name: "a", isInternal: false, isRoot: false, total: 1, available: 1),
                 VolumeSnapshot(id: "/Volumes/Data", name: "Data", isInternal: true, isRoot: false, total: 1, available: 1),
                 VolumeSnapshot(id: "/", name: "Macintosh HD", isInternal: true, isRoot: true, total: 1, available: 1)]
        #expect(DiskCalculator.ordered(v).map(\.name) == ["Macintosh HD", "Data", "a", "b"])
    }
    @Test func fskitZeroImportantCapacityFallsBackToPlainAvailable() {
        // Measured on /Volumes/Elements (exFAT via FSKit, macOS 27): important = 0, plain = 755 GB.
        #expect(DiskCalculator.availableBytes(plain: 755_690_635_264, important: 0, total: 1_000_151_973_888)
                == 755_690_635_264)
    }
    @Test func apfsPrefersImportantCapacityIncludingPurgeable() {
        #expect(DiskCalculator.availableBytes(plain: 128, important: 133, total: 494) == 133)
        #expect(DiskCalculator.availableBytes(plain: 128, important: nil, total: 494) == 128)
    }
    @Test func availableClampsToTotalAndNegative() {
        #expect(DiskCalculator.availableBytes(plain: 50, important: 900, total: 100) == 100)
        #expect(DiskCalculator.availableBytes(plain: -1, important: -1, total: 100) == 0)
        #expect(DiskCalculator.availableBytes(plain: nil, important: nil, total: 100) == 0)
    }
    @Test func zeroTotalVolumeHasZeroFraction() {
        #expect(VolumeSnapshot(id: "/x", name: "x", isInternal: false, isRoot: false, total: 0, available: 0).usedFraction == 0)
    }
    @Test func fskitVolumeWithoutIOStatsStillShown() {
        struct Vols: VolumeSource {
            func volumes() -> [VolumeInfo] {
                [VolumeInfo(path: "/Volumes/Elements", name: "Elements", isInternal: false, isRoot: false,
                            total: 1_000, available: 400, bsdName: "disk6s1")]
            }
        }
        struct NoIO: DiskIOSource { func device(bsdName: String) -> BlockDevice? { nil } }
        let sampler = DiskSampler(volumes: Vols(), io: NoIO())
        _ = sampler.sample(now: Date(timeIntervalSince1970: 0))
        let v = sampler.sample(now: Date(timeIntervalSince1970: 2))
        #expect(v.count == 1)
        #expect(v[0].used == 600)
        #expect(v[0].readBytesPerSecond == nil)
    }
    @Test func throughputOnSecondSample() {
        struct Vols: VolumeSource {
            func volumes() -> [VolumeInfo] {
                [VolumeInfo(path: "/", name: "HD", isInternal: true, isRoot: true, total: 10, available: 5, bsdName: "disk3s1s1")]
            }
        }
        final class IO: DiskIOSource {
            var n: UInt64 = 0
            func device(bsdName: String) -> BlockDevice? {
                n += 1_000; return BlockDevice(id: "1", counters: DiskIOCounters(read: n, write: n * 2))
            }
        }
        let sampler = DiskSampler(volumes: Vols(), io: IO())
        #expect(sampler.sample(now: Date(timeIntervalSince1970: 0))[0].readBytesPerSecond == nil)
        let v = sampler.sample(now: Date(timeIntervalSince1970: 2))[0]
        #expect(v.readBytesPerSecond == 500)
        #expect(v.writeBytesPerSecond == 1_000)
    }
    @Test func replugStartsFreshBaseline() {
        // Volume disappears for one sample, then returns with a reset counter: no spike, no negative.
        final class Vols: VolumeSource {
            var present = true
            func volumes() -> [VolumeInfo] {
                present ? [VolumeInfo(path: "/Volumes/X", name: "X", isInternal: false, isRoot: false,
                                      total: 10, available: 5, bsdName: "disk9s1")] : []
            }
        }
        final class IO: DiskIOSource {
            var value: UInt64 = 1_000_000
            func device(bsdName: String) -> BlockDevice? { BlockDevice(id: "9", counters: DiskIOCounters(read: value, write: value)) }
        }
        let vols = Vols(), io = IO()
        let sampler = DiskSampler(volumes: vols, io: io)
        _ = sampler.sample(now: Date(timeIntervalSince1970: 0))
        vols.present = false
        #expect(sampler.sample(now: Date(timeIntervalSince1970: 2)).isEmpty)
        vols.present = true; io.value = 10
        #expect(sampler.sample(now: Date(timeIntervalSince1970: 4))[0].readBytesPerSecond == nil)
    }

    // MARK: - Device identity (one physical device → one throughput row)

    @Test func volumesOnSameDeviceShareDeviceID() {
        struct Vols: VolumeSource {
            func volumes() -> [VolumeInfo] {
                [VolumeInfo(path: "/", name: "HD", isInternal: true, isRoot: true, total: 10, available: 5, bsdName: "disk3s1s1"),
                 VolumeInfo(path: "/Volumes/Data2", name: "Data2", isInternal: true, isRoot: false, total: 10, available: 5, bsdName: "disk3s7"),
                 VolumeInfo(path: "/Volumes/USB", name: "USB", isInternal: false, isRoot: false, total: 10, available: 5, bsdName: "disk6s1"),
                 VolumeInfo(path: "/Volumes/Net", name: "Net", isInternal: false, isRoot: false, total: 10, available: 5, bsdName: nil)]
            }
        }
        struct IO: DiskIOSource {
            // disk3* hang off one NVMe driver, disk6 off a USB one; the USB driver has no stats.
            func device(bsdName: String) -> BlockDevice? {
                bsdName.hasPrefix("disk3") ? BlockDevice(id: "4294968123", counters: DiskIOCounters(read: 1, write: 1))
                    : BlockDevice(id: "4294970001", counters: nil)
            }
        }
        let v = Dictionary(uniqueKeysWithValues: DiskSampler(volumes: Vols(), io: IO()).sample(now: Date()).map { ($0.id, $0) })
        #expect(v["/"]?.deviceID == "4294968123")
        #expect(v["/Volumes/Data2"]?.deviceID == "4294968123")
        #expect(v["/Volumes/USB"]?.deviceID == "4294970001")
        #expect(v["/Volumes/Net"]?.deviceID == nil)
    }

    // MARK: - Stale baseline (design review)

    /// Disks are only sampled while the panel is open. Reopening after a minute must not show
    /// the minute's average as the current "/s" rate.
    @Test func staleBaselineAfterClosedPanelGivesNoRate() {
        struct Vols: VolumeSource {
            func volumes() -> [VolumeInfo] {
                [VolumeInfo(path: "/", name: "HD", isInternal: true, isRoot: true, total: 10, available: 5, bsdName: "disk3s1s1")]
            }
        }
        final class IO: DiskIOSource {
            var n: UInt64 = 0
            func device(bsdName: String) -> BlockDevice? {
                n += 1_000; return BlockDevice(id: "1", counters: DiskIOCounters(read: n, write: n))
            }
        }
        let sampler = DiskSampler(volumes: Vols(), io: IO())
        _ = sampler.sample(now: Date(timeIntervalSince1970: 0))
        #expect(sampler.sample(now: Date(timeIntervalSince1970: 60))[0].readBytesPerSecond == nil)
        #expect(sampler.sample(now: Date(timeIntervalSince1970: 62))[0].readBytesPerSecond == 500)
        #expect(sampler.sample(now: Date(timeIntervalSince1970: 62 + DiskSampler.maxBaselineAge))[0].readBytesPerSecond != nil)
    }

    // MARK: - Mount filtering (security review)

    @Test func onlyLocalBrowsableRootOrVolumesMountsAreCandidates() {
        let local = UInt32(MNT_LOCAL), nobrowse = UInt32(MNT_DONTBROWSE)
        let table = [
            MountEntry(path: "/", source: "/dev/disk3s1s1", flags: local),
            MountEntry(path: "/System/Volumes/Data", source: "/dev/disk3s5", flags: local | nobrowse),
            MountEntry(path: "/Volumes/Recovery", source: "/dev/disk3s3", flags: local | nobrowse),
            MountEntry(path: "/Volumes/Elements", source: "/dev/disk6s1", flags: local),
            MountEntry(path: "/Volumes/share", source: "//user@nas/share", flags: 0),          // SMB: not local
            MountEntry(path: "/Volumes/nfs", source: "nas:/export", flags: 0),                 // NFS: not local
            MountEntry(path: "/Users/x/mnt", source: "/dev/disk7s1", flags: local),            // outside /Volumes
        ]
        #expect(FileManagerVolumeSource.candidates(table).map(\.path) == ["/", "/Volumes/Elements"])
        #expect(table[0].bsdName == "disk3s1s1")
        #expect(table[4].bsdName == nil)
    }
}
