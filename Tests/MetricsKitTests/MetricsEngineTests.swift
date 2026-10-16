import Testing
import Foundation
@testable import MetricsKit

@MainActor
struct MetricsEngineTests {
    func fakes(docker: @escaping (Date) async -> DockerSnapshot = { _ in DockerSnapshot(state: .running) }) -> Samplers {
        Samplers(cpu: { CPUSnapshot(total: 0.5, perCore: [0.5], efficiencyCoreCount: 0) },
                 memory: { MemorySnapshot(total: 10, used: 5, app: 5, wired: 0, compressed: 0, pressure: .normal) },
                 swap: { SwapSnapshot(total: 2, used: 1) },
                 gpu: { GPUSnapshot(utilization: 0.1, memoryInUse: 1) },
                 volumes: { _ in [VolumeSnapshot(id: "/", name: "HD", isInternal: true, isRoot: true, total: 2, available: 1)] },
                 docker: docker)
    }
    let host = HostInfo(modelName: "Mac", chip: "Apple M4", bootTime: nil)

    @Test func closedPanelSkipsDetailMetrics() {
        let e = MetricsEngine(refreshInterval: 2, samplers: fakes(), hostInfo: host)
        e.tick(now: Date())
        #expect(e.snapshot.cpu?.total == 0.5)
        #expect(e.snapshot.swap == nil && e.snapshot.gpu == nil && e.snapshot.volumes.isEmpty)
        #expect(e.history.cpu.elements == [0.5])
    }
    @Test func openPanelSamplesDetailAndDocker() async throws {
        let e = MetricsEngine(refreshInterval: 2, samplers: fakes(), hostInfo: host)
        e.isPanelOpen = true          // triggers an immediate tick
        #expect(e.snapshot.gpu?.utilization == 0.1)
        #expect(e.snapshot.volumes.count == 1)
        for _ in 0..<50 where e.snapshot.docker == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(e.snapshot.docker?.state == .running)
    }
    @Test func slowDockerIsNotStartedTwice() async {
        // The fake Docker call blocks on a gate the test opens, so "slow" is deterministic.
        // `@MainActor` keeps the captured state on one actor (no data race with the polling below).
        var calls = 0
        var gate: CheckedContinuation<Void, Never>?
        let docker: @MainActor (Date) async -> DockerSnapshot = { _ in
            calls += 1
            await withCheckedContinuation { gate = $0 }
            return DockerSnapshot(state: .running)
        }
        let e = MetricsEngine(refreshInterval: 2, samplers: fakes(docker: docker), hostInfo: host)
        e.isPanelOpen = true
        for _ in 0..<10_000 where gate == nil { await Task.yield() }
        e.tick(now: Date().addingTimeInterval(10))     // Docker due again, but one is in flight
        e.tick(now: Date().addingTimeInterval(20))
        for _ in 0..<100 { await Task.yield() }        // give any wrongly spawned task a chance to run
        #expect(calls == 1)
        gate?.resume()
        for _ in 0..<10_000 where e.snapshot.docker == nil { await Task.yield() }
        #expect(e.snapshot.docker?.state == .running)
        gate = nil
        e.tick(now: Date().addingTimeInterval(30))     // previous one finished: a new one starts
        for _ in 0..<10_000 where calls < 2 { await Task.yield() }
        #expect(calls == 2)
        for _ in 0..<10_000 where gate == nil { await Task.yield() }
        gate?.resume()
    }
    @Test func historyCapacityFollowsInterval() {
        #expect(MetricsEngine(refreshInterval: 1, samplers: fakes(), hostInfo: host).history.cpu.capacity == 300)
        #expect(MetricsEngine(refreshInterval: 5, samplers: fakes(), hostInfo: host).history.cpu.capacity == 60)
    }
    @Test func changingIntervalResizesHistory() {
        let e = MetricsEngine(refreshInterval: 2, samplers: fakes(), hostInfo: host)
        e.refreshInterval = 5
        #expect(e.history.cpu.capacity == 60)
    }
    @Test func failedCoreSamplerShowsNilNotStaleValue() {
        var cpuOK = true
        let base = fakes()
        let samplers = Samplers(cpu: { cpuOK ? CPUSnapshot(total: 0.5, perCore: [0.5], efficiencyCoreCount: 0) : nil },
                                memory: base.memory, swap: base.swap, gpu: base.gpu, volumes: base.volumes, docker: base.docker)
        let e = MetricsEngine(refreshInterval: 2, samplers: samplers, hostInfo: host)
        e.tick(now: Date())
        cpuOK = false
        e.tick(now: Date())
        #expect(e.snapshot.cpu == nil)
        #expect(e.history.cpu.elements == [0.5])
    }
    /// Opening the panel ticks immediately, often right after a timer tick. A second History
    /// point a few ms later would compress the sparkline's time axis (capacity encodes ~5 min).
    @Test func extraTickRightAfterTimerTickDoesNotAddHistoryPoint() {
        let e = MetricsEngine(refreshInterval: 2, samplers: fakes(), hostInfo: host)
        let t0 = Date(timeIntervalSince1970: 1_000)
        e.tick(now: t0)
        e.tick(now: t0.addingTimeInterval(0.01))
        #expect(e.history.cpu.elements.count == 1 && e.history.memory.elements.count == 1)
        #expect(e.snapshot.timestamp == t0.addingTimeInterval(0.01))      // the snapshot itself is fresh
        e.tick(now: t0.addingTimeInterval(2))
        #expect(e.history.cpu.elements.count == 2)
    }
    @Test func clockSteppedBackRecordsHistoryAgain() {
        let e = MetricsEngine(refreshInterval: 2, samplers: fakes(), hostInfo: host)
        e.tick(now: Date(timeIntervalSince1970: 1_000))
        e.tick(now: Date(timeIntervalSince1970: 500))
        #expect(e.history.cpu.elements.count == 2)
    }
    /// The immediate tick in `start()` comes microseconds after the samplers primed, so CPU
    /// has no value yet; a single follow-up tick fills the menu bar after `minimumWindow`
    /// instead of leaving it empty for a whole refresh interval (up to 5 s).
    @Test func startRetriesOnceWhenFirstCPUSampleIsMissing() async throws {
        var calls = 0
        let base = fakes()
        let samplers = Samplers(cpu: { calls += 1; return calls == 1 ? nil : CPUSnapshot(total: 0.3, perCore: [0.3], efficiencyCoreCount: 0) },
                                memory: base.memory, swap: base.swap, gpu: base.gpu, volumes: base.volumes, docker: base.docker)
        let e = MetricsEngine(refreshInterval: 5, samplers: samplers, hostInfo: host)
        e.start()
        defer { e.stop() }
        #expect(e.snapshot.cpu == nil)
        // Wait for the condition (bounded), not for a fixed time; the timer is 5 s away.
        for _ in 0..<300 where e.snapshot.cpu == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(e.snapshot.cpu?.total == 0.3)
        #expect(calls == 2)
    }
}
