import Foundation
import Testing
@testable import MetricsKit

struct ProcessCalculatorTests {
    typealias Key = ProcessCalculator.Key
    func r(_ pid: Int32, _ group: String, cpu: UInt64, mem: UInt64, start: UInt64 = 1) -> ProcessReading {
        ProcessReading(pid: pid, start: start, group: group, cpuTime: cpu, memory: mem)
    }

    @Test func groupsHelpersAndRanksByCPUAndMemory() {
        let previous: [Key: UInt64] = [Key(pid: 1, start: 1): 0, Key(pid: 2, start: 1): 0, Key(pid: 3, start: 1): 0]
        let s = ProcessCalculator.snapshot(
            readings: [r(1, "Chrome", cpu: 500_000_000, mem: 100), r(2, "Chrome", cpu: 500_000_000, mem: 300),
                       r(3, "Xcode", cpu: 1_500_000_000, mem: 200)],
            previous: previous, elapsed: 2, unreadable: 7)
        #expect(s.topCPU.map(\.name) == ["Xcode", "Chrome"])
        #expect(s.topCPU[0].cpu == 0.75)                // 1.5 s of CPU in 2 s
        #expect(s.topCPU[1].cpu == 0.5)
        #expect(s.topCPU[1].processCount == 2)
        #expect(s.topMemory.map(\.name) == ["Chrome", "Xcode"])
        #expect(s.topMemory[0].memory == 400)
        #expect(s.unreadableCount == 7)
    }

    @Test func withoutBaselineCPUIsUnknownButMemoryIsListed() {
        let s = ProcessCalculator.snapshot(readings: [r(1, "A", cpu: 10, mem: 5)], previous: nil, elapsed: 0, unreadable: 0)
        #expect(s.topCPU.isEmpty)
        #expect(s.topMemory.first?.cpu == nil)
        #expect(s.topMemory.first?.memory == 5)
    }

    @Test func reusedPidOrNewProcessDoesNotCountItsWholeLifetime() {
        // pid 1 was another process before (different start): no delta for it.
        let s = ProcessCalculator.snapshot(readings: [r(1, "New", cpu: 9_000_000_000, mem: 1, start: 2)],
                                           previous: [Key(pid: 1, start: 1): 0], elapsed: 2, unreadable: 0)
        #expect(s.topCPU.first?.cpu == 0)
    }

    @Test func counterGoingBackwardsIsIgnored() {
        let s = ProcessCalculator.snapshot(readings: [r(1, "A", cpu: 5, mem: 1)],
                                           previous: [Key(pid: 1, start: 1): 10], elapsed: 2, unreadable: 0)
        #expect(s.topCPU.first?.cpu == 0)
    }

    @Test func limitsRows() {
        let readings = (0..<20).map { r(Int32($0), "p\($0)", cpu: UInt64($0), mem: UInt64($0)) }
        let s = ProcessCalculator.snapshot(readings: readings, previous: [:], elapsed: 1, unreadable: 0, limit: 5)
        #expect(s.topCPU.count == 5 && s.topMemory.count == 5)
        #expect(s.topMemory.first?.name == "p19")
    }

    @Test(arguments: [
        ("/Applications/Google Chrome.app/Contents/Frameworks/X.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)", "Google Chrome"),
        ("/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild", "Xcode"),
        ("/usr/sbin/sshd", "sshd"),
        ("", "fallback"),
    ])
    func groupsByOutermostApp(_ path: String, _ expected: String) {
        #expect(ProcessCalculator.group(forExecutablePath: path, fallbackName: "fallback") == expected)
    }

    @Test func liveSamplerReadsOwnProcess() throws {
        let sampler = ProcessSampler()
        let first = try #require(sampler.sample(now: Date()))
        #expect(first.topCPU.isEmpty)                 // no baseline yet
        #expect(!first.topMemory.isEmpty)
        Thread.sleep(forTimeInterval: 0.3)
        let second = try #require(sampler.sample(now: Date()))
        #expect(!second.topCPU.isEmpty)
        #expect(second.topCPU.allSatisfy { ($0.cpu ?? -1) >= 0 })
    }
}
