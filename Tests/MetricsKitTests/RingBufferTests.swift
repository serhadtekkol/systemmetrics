import Testing
@testable import MetricsKit

struct RingBufferTests {
    @Test func keepsInsertionOrderBelowCapacity() {
        var b = RingBuffer<Int>(capacity: 3)
        b.append(1); b.append(2)
        #expect(b.elements == [1, 2])
        #expect(b.count == 2)
    }
    @Test func dropsOldestWhenFull() {
        var b = RingBuffer<Int>(capacity: 3)
        for i in 1...5 { b.append(i) }
        #expect(b.elements == [3, 4, 5])
        #expect(b.count == 3)
    }
    @Test func capacityOne() {
        var b = RingBuffer<Int>(capacity: 1)
        b.append(1); b.append(2)
        #expect(b.elements == [2])
    }
    @Test func historyRecordsAvailableSeriesOnly() {
        var h = History(capacity: 2)
        h.record(SystemSnapshot(cpu: CPUSnapshot(total: 0.5, perCore: [], efficiencyCoreCount: 0)))
        #expect(h.cpu.elements == [0.5])
        #expect(h.gpu.elements.isEmpty)
    }
}
