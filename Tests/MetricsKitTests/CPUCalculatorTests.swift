import Testing
import Foundation
@testable import MetricsKit

struct CPUCalculatorTests {
    let t0 = [CPUTicks(user: 100, system: 50, idle: 850, nice: 0), CPUTicks(user: 0, system: 0, idle: 1000, nice: 0)]
    @Test func computesPerCoreAndTotal() throws {
        let t1 = [CPUTicks(user: 150, system: 100, idle: 900, nice: 0), CPUTicks(user: 0, system: 0, idle: 1100, nice: 0)]
        let s = try #require(CPUCalculator.usage(previous: t0, current: t1, efficiencyCoreCount: 1))
        #expect(s.perCore == [100.0 / 150.0, 0])
        #expect(abs(s.total - 100.0 / 250.0) < 1e-9)
        #expect(Array(s.efficiencyCores) == [100.0 / 150.0])
        #expect(Array(s.performanceCores) == [0])
    }
    @Test func countersGoingBackwardsYieldZero() throws {
        let reset = [CPUTicks(user: 1, system: 1, idle: 1, nice: 0), CPUTicks(user: 0, system: 0, idle: 5, nice: 0)]
        let s = try #require(CPUCalculator.usage(previous: t0, current: reset, efficiencyCoreCount: 0))
        #expect(s.perCore.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(s.total >= 0 && s.total <= 1)
    }
    @Test func mismatchedCoreCountReturnsNil() {
        #expect(CPUCalculator.usage(previous: t0, current: [t0[0]], efficiencyCoreCount: 0) == nil)
    }
    final class FakeTicks: CPUTickSource {
        var reads: [[CPUTicks]]
        private(set) var readCount = 0
        init(_ r: [[CPUTicks]]) { reads = r }
        func read() -> [CPUTicks]? { readCount += 1; return reads.isEmpty ? nil : reads.removeFirst() }
    }
    final class FakeClock {
        var now: TimeInterval = 100
        func read() -> TimeInterval { now }
    }
    @Test func samplerPrimesOnInitSoFirstSampleHasValue() {
        let clock = FakeClock()
        let sampler = CPUSampler(source: FakeTicks([[CPUTicks(user: 0, system: 0, idle: 0, nice: 0)],
                                                    [CPUTicks(user: 50, system: 0, idle: 50, nice: 0)]]),
                                 efficiencyCoreCount: 0, clock: clock.read)
        clock.now += 1
        #expect(sampler.sample()?.total == 0.5)
        clock.now += 1
        #expect(sampler.sample() == nil)   // source failure → nil, no crash
    }
    /// Mach ticks advance at 100 Hz, so a window of a few ms quantizes every core to 0% or 100%.
    /// A sample requested sooner than `minimumWindow` after the last read reuses the last value
    /// and leaves the baseline alone.
    @Test func sampleWithinMinimumWindowReusesLastValueWithoutReading() {
        let clock = FakeClock()
        let source = FakeTicks([[CPUTicks(user: 0, system: 0, idle: 0, nice: 0)],
                                [CPUTicks(user: 50, system: 0, idle: 50, nice: 0)],
                                [CPUTicks(user: 51, system: 0, idle: 150, nice: 0)]])
        let sampler = CPUSampler(source: source, efficiencyCoreCount: 0, clock: clock.read)
        clock.now += 2
        #expect(sampler.sample()?.total == 0.5)
        clock.now += 0.001
        #expect(sampler.sample()?.total == 0.5)        // reused, not 1/1 = 100%
        #expect(source.readCount == 2)
        clock.now += 2
        // Baseline is still the read at t=2, so the window covers the skipped instant too.
        #expect(sampler.sample()?.total == 1.0 / 101.0)
    }
    /// The engine ticks right after creating the samplers; that first window is microseconds
    /// long and must not be published.
    @Test func firstSampleWithinMinimumWindowOfPrimingIsNil() {
        let clock = FakeClock()
        let source = FakeTicks([[CPUTicks(user: 0, system: 0, idle: 0, nice: 0)],
                                [CPUTicks(user: 50, system: 0, idle: 50, nice: 0)]])
        let sampler = CPUSampler(source: source, efficiencyCoreCount: 0, clock: clock.read)
        clock.now += 0.0001
        #expect(sampler.sample() == nil)
        #expect(source.readCount == 1)
        clock.now += 1
        #expect(sampler.sample()?.total == 0.5)
    }
    /// A clock that goes backwards (it should not, it is monotonic) must not freeze sampling.
    @Test func clockGoingBackwardsStillSamples() {
        let clock = FakeClock()
        let sampler = CPUSampler(source: FakeTicks([[CPUTicks(user: 0, system: 0, idle: 0, nice: 0)],
                                                    [CPUTicks(user: 50, system: 0, idle: 50, nice: 0)]]),
                                 efficiencyCoreCount: 0, clock: clock.read)
        clock.now -= 10
        #expect(sampler.sample()?.total == 0.5)
    }
    @Test func busyCounterWrapIsTheRealDelta() throws {
        let nearMax = UInt64(UInt32.max) - 4
        let before = [CPUTicks(user: nearMax, system: 0, idle: 100, nice: 0)]
        let after = [CPUTicks(user: 5, system: 0, idle: 110, nice: 0)]     // 10 user ticks across the wrap
        let s = try #require(CPUCalculator.usage(previous: before, current: after, efficiencyCoreCount: 0))
        #expect(s.perCore == [0.5])
    }
}
