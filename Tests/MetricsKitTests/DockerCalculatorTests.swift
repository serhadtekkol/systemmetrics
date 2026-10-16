import Testing
import Foundation
@testable import MetricsKit

struct DockerCalculatorTests {
    @Test func cpuPercentLikeDockerStats() throws {
        let p = DockerCPUSample(container: 1_000_000_000, system: 100_000_000_000, onlineCPUs: 8)
        let c = DockerCPUSample(container: 1_500_000_000, system: 101_000_000_000, onlineCPUs: 8)
        // 0.5e9 / 1e9 * 8 * 100 = 400
        #expect(try #require(DockerCalculator.cpuPercent(previous: p, current: c)) == 400)
    }
    @Test func cpuPercentNilWhenSystemDidNotAdvance() {
        let s = DockerCPUSample(container: 1, system: 1, onlineCPUs: 8)
        #expect(DockerCalculator.cpuPercent(previous: s, current: s) == nil)
    }
    @Test func cpuPercentNilWhenContainerCounterWentBackwards() {
        // Container restarted under the same id: its cgroup counter starts again from 0.
        let p = DockerCPUSample(container: 5_000, system: 100, onlineCPUs: 2)
        let c = DockerCPUSample(container: 10, system: 200, onlineCPUs: 2)
        #expect(DockerCalculator.cpuPercent(previous: p, current: c) == nil)
    }
    @Test func memorySubtractsInactiveFileCgroupV2() throws {
        let json = #"{"cpu_stats":{"cpu_usage":{"total_usage":1},"system_cpu_usage":2,"online_cpus":4},"memory_stats":{"usage":1000,"stats":{"inactive_file":300}}}"#
        let stats = try JSONDecoder().decode(DockerStats.self, from: Data(json.utf8))
        #expect(DockerCalculator.memoryUsage(stats) == 700)
    }
    @Test func memoryWithoutStatsUsesUsage() throws {
        let json = #"{"cpu_stats":{"cpu_usage":{"total_usage":1}},"memory_stats":{"usage":1000}}"#
        #expect(DockerCalculator.memoryUsage(try JSONDecoder().decode(DockerStats.self, from: Data(json.utf8))) == 1000)
    }
    @Test func emptyMemoryStatsIsZero() throws {
        // Engine returns `"memory_stats":{}` for a container that is just starting or stopping.
        let json = #"{"cpu_stats":{"cpu_usage":{"total_usage":0}},"memory_stats":{}}"#
        #expect(DockerCalculator.memoryUsage(try JSONDecoder().decode(DockerStats.self, from: Data(json.utf8))) == 0)
    }
    @Test func diskUsageSumsAndClampsNegative() throws {
        let json = #"{"LayersSize":1000,"Volumes":[{"UsageData":{"Size":200}},{"UsageData":{"Size":-1}}],"BuildCache":[{"Size":50}],"Containers":[{"SizeRw":5}]}"#
        #expect(DockerCalculator.diskUsage(try JSONDecoder().decode(DockerDiskUsage.self, from: Data(json.utf8))) == 1255)
    }
    @Test func diskUsageToleratesNullArrays() throws {
        let json = #"{"LayersSize":7,"Volumes":null,"BuildCache":null,"Containers":null,"Images":null}"#
        #expect(DockerCalculator.diskUsage(try JSONDecoder().decode(DockerDiskUsage.self, from: Data(json.utf8))) == 7)
    }

    @Test func cpuPercentClampedToOnlineCPUs() throws {
        // A container cannot use more than all online CPUs; a daemon claiming it did is clamped.
        let p = DockerCPUSample(container: 0, system: 0, onlineCPUs: 2)
        let c = DockerCPUSample(container: 300, system: 100, onlineCPUs: 2)
        #expect(try #require(DockerCalculator.cpuPercent(previous: p, current: c)) == 200)
    }
    @Test func cpuPercentWithNonPositiveOnlineCPUsCountsOne() throws {
        let p = DockerCPUSample(container: 0, system: 0, onlineCPUs: -7)
        let c = DockerCPUSample(container: 50, system: 100, onlineCPUs: -7)
        #expect(try #require(DockerCalculator.cpuPercent(previous: p, current: c)) == 50)
    }
    @Test func diskUsageSaturatesAtUInt64Max() throws {
        let m = Int64.max
        let json = #"{"LayersSize":\#(m),"Volumes":[{"UsageData":{"Size":\#(m)}},{"UsageData":{"Size":\#(m)}}]}"#
        #expect(DockerCalculator.diskUsage(try JSONDecoder().decode(DockerDiskUsage.self, from: Data(json.utf8))) == .max)
    }
    @Test func saturatingSum() {
        #expect([UInt64.max, 1].saturatingSum == .max)
        #expect([UInt64]().saturatingSum == 0)
        #expect([1, 2, 3].saturatingSum == 6)
    }
    @Test func infoDecodesVMSize() throws {
        let info = try JSONDecoder().decode(DockerInfo.self, from: Data(#"{"NCPU":12,"MemTotal":8217473024,"Name":"docker-desktop"}"#.utf8))
        #expect(info.cpuCount == 12 && info.memoryTotal == 8_217_473_024)
        let odd = try JSONDecoder().decode(DockerInfo.self, from: Data(#"{"NCPU":5000,"MemTotal":0}"#.utf8))
        #expect(odd.cpuCount == nil && odd.memoryTotal == nil)
        let missing = try JSONDecoder().decode(DockerInfo.self, from: Data("{}".utf8))
        #expect(missing.cpuCount == nil && missing.memoryTotal == nil)
    }
}
