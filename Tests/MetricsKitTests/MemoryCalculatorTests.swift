import Testing
import Darwin
@testable import MetricsKit

struct MemoryCalculatorTests {
    let page: UInt64 = 16_384
    @Test func activityMonitorFormula() {
        let pages = VMPageCounts(pageSize: page, internal: 1000, purgeable: 100, wired: 200, compressed: 50)
        let s = MemoryCalculator.snapshot(pages: pages, physical: 10_000 * page, pressureLevel: 1)
        #expect(s.app == 900 * page)
        #expect(s.wired == 200 * page)
        #expect(s.compressed == 50 * page)
        #expect(s.used == 1150 * page)
        #expect(s.pressure == .normal)
    }
    @Test func purgeableLargerThanInternalDoesNotUnderflow() {
        let pages = VMPageCounts(pageSize: page, internal: 10, purgeable: 50, wired: 0, compressed: 0)
        #expect(MemoryCalculator.snapshot(pages: pages, physical: page * 100, pressureLevel: 1).app == 0)
    }
    @Test func usedNeverExceedsPhysical() {
        let pages = VMPageCounts(pageSize: page, internal: 100, purgeable: 0, wired: 100, compressed: 100)
        #expect(MemoryCalculator.snapshot(pages: pages, physical: 10 * page, pressureLevel: 1).used == 10 * page)
    }
    @Test func pressureLevels() {
        let p = VMPageCounts(pageSize: page, internal: 0, purgeable: 0, wired: 0, compressed: 0)
        #expect(MemoryCalculator.snapshot(pages: p, physical: 1, pressureLevel: 2).pressure == .warning)
        #expect(MemoryCalculator.snapshot(pages: p, physical: 1, pressureLevel: 4).pressure == .critical)
        #expect(MemoryCalculator.snapshot(pages: p, physical: 1, pressureLevel: 0).pressure == .normal)
    }
    @Test func swapFromStructNotText() {
        var u = xsw_usage()
        u.xsu_total = 8 * 1024 * 1024 * 1024
        u.xsu_used = 6_855 * 1024 * 1024
        let s = MemoryCalculator.swap(u)
        #expect(s.total == 8 * 1024 * 1024 * 1024)
        #expect(s.used == 6_855 * 1024 * 1024)
    }
    @Test func zeroSwapTotalHasZeroFraction() {
        #expect(SwapSnapshot(total: 0, used: 0).usedFraction == 0)
    }
}
