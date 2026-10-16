import Testing
import Foundation
@testable import MetricsKit

/// Independent QA tests that pin the plan's "Review Focus" items harder than the original
/// suites do, plus the defects found while verifying them. Pure, deterministic, CI-safe.
///
/// Tests wrapped in `withKnownIssue` reproduce an open defect. When the defect is fixed, the
/// wrapper reports "known issue was not recorded" — remove the wrapper then, keep the test.
struct ReviewFocusEdgeTests {

    // MARK: Review Focus 1 — counters going backwards

    /// The existing `countersGoingBackwardsYieldZero` only asserts the result lies in 0...1, which
    /// an implementation that treated the reset value as a fresh delta (2 busy / 3 total = 67%)
    /// would also satisfy. A full reset must produce exactly one quiet (0%) sample.
    @Test func fullCounterResetIsExactlyZero() throws {
        let before = [CPUTicks(user: 100, system: 50, idle: 850, nice: 3)]
        let after = [CPUTicks(user: 1, system: 1, idle: 1, nice: 0)]
        let s = try #require(CPUCalculator.usage(previous: before, current: after, efficiencyCoreCount: 0))
        #expect(s.perCore == [0])
        #expect(s.total == 0)
    }

    /// Defect: the Mach tick counters are unsigned 32-bit and the idle counter, being the
    /// largest, wraps first (~497 days per core at 100 Hz). Only `idle` wrapping while `user`
    /// advances normally makes the clamped idle delta 0, so the core reads **100% busy** — the
    /// spike the clamp was meant to prevent. Modular `UInt32` subtraction gives the true delta.
    @Test(.bug("qa: CPU idle 32-bit wrap reads as 100% busy"))
    func idleCounterWrapDoesNotSpikeTo100Percent() throws {
        let nearMax = UInt64(UInt32.max) - 10
        let before = [CPUTicks(user: 1_000, system: 0, idle: nearMax, nice: 0)]
        // 10 user ticks and 100 idle ticks really elapsed; idle wrapped past 2^32.
        let after = [CPUTicks(user: 1_010, system: 0, idle: 89, nice: 0)]
        let s = try #require(CPUCalculator.usage(previous: before, current: after, efficiencyCoreCount: 0))
        #expect(abs(s.perCore[0] - 10.0 / 110.0) < 0.01, "core reads \(s.perCore[0])")
    }

    @Test func diskCounterResetOnBothDirectionsIsZero() throws {
        let r = try #require(DiskCalculator.rate(previous: DiskIOCounters(read: .max, write: 5),
                                                 current: DiskIOCounters(read: 0, write: 4), elapsed: 2))
        #expect(r.read == 0 && r.write == 0)
    }

    // MARK: Review Focus 3 — container disappears between list and stats

    /// The existing test covers a 404. A 200 with an unusable body (daemon mid-teardown) and a
    /// transport error on one stats call must also drop only that container.
    @Test func undecodableOrFailingStatsDropOnlyThatContainer() async {
        final class Transport: HTTPTransport {
            func get(_ path: String, maxBytes: Int) throws -> HTTPResponse {
                switch path {
                case "/_ping": return .init(status: 200, body: Data("OK".utf8))
                case "/containers/json":
                    return .init(status: 200, body: Data(#"[{"Id":"\#(idA)","Names":["/ok"]},{"Id":"\#(idB)","Names":["/junk"]},{"Id":"\#(idC)","Names":["/err"]}]"#.utf8))
                case statsPath(idA):
                    return .init(status: 200, body: Data(#"{"cpu_stats":{"cpu_usage":{"total_usage":1},"system_cpu_usage":2,"online_cpus":1},"memory_stats":{"usage":7}}"#.utf8))
                case statsPath(idB):
                    return .init(status: 200, body: Data("{\"cpu_stats\":".utf8))
                case statsPath(idC):
                    throw UnixSocketError.timeout
                default: return .init(status: 404, body: Data())
                }
            }
        }
        let t = Transport()
        let snap = await DockerSampler(transportFactory: { t }, isInstalled: { true }).sample(now: Date(timeIntervalSince1970: 0))
        #expect(snap.state == .running)
        #expect(snap.containers.map(\.name) == ["ok"])
        #expect(snap.containers.first?.memory == 7)
    }

    /// A stopped container listed a moment earlier answers stats with empty `memory_stats` and
    /// no `system_cpu_usage`; it must not take the card down or produce a CPU value.
    @Test func stoppedContainerStatsShapeIsTolerated() async {
        final class Transport: HTTPTransport {
            func get(_ path: String, maxBytes: Int) throws -> HTTPResponse {
                switch path {
                case "/_ping": return .init(status: 200, body: Data("OK".utf8))
                case "/containers/json": return .init(status: 200, body: Data(#"[{"Id":"\#(idA)","Names":["/stopping"]}]"#.utf8))
                case statsPath(idA):
                    return .init(status: 200, body: Data(#"{"read":"0001-01-01T00:00:00Z","cpu_stats":{"cpu_usage":{"total_usage":0},"throttling_data":{}},"memory_stats":{}}"#.utf8))
                default: return .init(status: 404, body: Data())
                }
            }
        }
        let t = Transport()
        let s = DockerSampler(transportFactory: { t }, isInstalled: { true })
        _ = await s.sample(now: Date(timeIntervalSince1970: 0))
        let snap = await s.sample(now: Date(timeIntervalSince1970: 4))
        #expect(snap.state == .running)
        #expect(snap.containers.count == 1)
        #expect(snap.containers[0].cpuPercent == nil && snap.containers[0].memory == 0)
    }

    // MARK: Review Focus 5 — zero / odd values

    /// Defect (trivial, defensive): `min(max(NaN, 0), 1)` is NaN in Swift, so a NaN utilization
    /// escaped the clamp and reached History and the ring gauge. A non-finite reading is not a
    /// measurement, so the parser now reports "no data" (`nil`) instead of inventing 0%.
    @Test(.bug("qa: GPU NaN utilization escapes the clamp"),
          arguments: [Double.nan, .infinity, -.infinity])
    func gpuNaNUtilizationIsClamped(_ value: Double) {
        #expect(GPUStatsParser.parse(["Device Utilization %": NSNumber(value: value)]) == nil)
    }

    @Test func gpuNegativeAndHugeMemoryDoNotTrap() throws {
        let g = try #require(GPUStatsParser.parse(["Device Utilization %": NSNumber(value: -5),
                                                   "In use system memory": NSNumber(value: -1)]))
        #expect(g.utilization == 0)
        _ = g.memoryInUse    // reaching here means no trap on a negative NSNumber
    }

    @Test func zeroEverythingVolumeAndSwapAreSafe() {
        let v = VolumeSnapshot(id: "/x", name: "", isInternal: false, isRoot: false, total: 0, available: 5)
        #expect(v.used == 0 && v.usedFraction == 0)
        #expect(SwapSnapshot(total: 0, used: 5).usedFraction == 0)
        #expect(MemorySnapshot(total: 0, used: 0, app: 0, wired: 0, compressed: 0, pressure: .normal).usedFraction == 0)
        #expect(DiskCalculator.availableBytes(plain: Int.max, important: Int64.max, total: 0) == 0)
    }

    @Test func emptyCPUReadIsNilNotZeroDivision() {
        #expect(CPUCalculator.usage(previous: [], current: [], efficiencyCoreCount: 0) == nil)
        let idle = [CPUTicks(user: 5, system: 5, idle: 5, nice: 5)]
        #expect(CPUCalculator.usage(previous: idle, current: idle, efficiencyCoreCount: 4)?.total == 0)
        // efficiencyCoreCount larger than the core list must not trap in the slices.
        let s = CPUCalculator.usage(previous: idle, current: idle, efficiencyCoreCount: 4)
        #expect(s?.efficiencyCores.count == 1 && s?.performanceCores.isEmpty == true)
    }
}
