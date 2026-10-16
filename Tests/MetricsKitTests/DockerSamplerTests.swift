import Testing
import Foundation
@testable import MetricsKit

final class FakeTransport: HTTPTransport {
    var routes: [String: HTTPResponse] = [:]
    var fail = false
    /// Called before every request; tests use it to advance a fake clock.
    var onRequest: (String) -> Void = { _ in }
    private(set) var requested: [String] = []
    private(set) var limits: [String: Int] = [:]
    func get(_ path: String, maxBytes: Int) throws -> HTTPResponse {
        requested.append(path)
        limits[path] = maxBytes
        onRequest(path)
        if fail { throw UnixSocketError.connectFailed(61) }
        return routes[path] ?? HTTPResponse(status: 404, body: Data())
    }
    static func ok(_ s: String) -> HTTPResponse { HTTPResponse(status: 200, body: Data(s.utf8)) }
}

/// Docker-shaped container ids (64 hex chars); the sampler rejects anything else.
let idA = String(repeating: "a", count: 64)
let idB = String(repeating: "b", count: 64)
let idC = String(repeating: "c", count: 64)
func statsPath(_ id: String) -> String { "/containers/\(id)/stats?stream=false&one-shot=true" }

struct DockerSamplerTests {
    func stats(_ total: UInt64, _ system: UInt64, mem: UInt64) -> String {
        #"{"cpu_stats":{"cpu_usage":{"total_usage":\#(total)},"system_cpu_usage":\#(system),"online_cpus":2},"memory_stats":{"usage":\#(mem)}}"#
    }
    func list(_ entries: [(String, String)]) -> HTTPResponse {
        FakeTransport.ok("[" + entries.map { #"{"Id":"\#($0.0)","Names":["/\#($0.1)"]}"# }.joined(separator: ",") + "]")
    }
    @Test func notInstalledWhenNoSocketAndNoApp() async {
        let s = DockerSampler(transportFactory: { nil }, isInstalled: { false })
        #expect(await s.sample(now: Date()).state == .notInstalled)
    }
    @Test func notRunningWhenNoSocketButAppInstalled() async {
        let s = DockerSampler(transportFactory: { nil }, isInstalled: { true })
        #expect(await s.sample(now: Date()).state == .notRunning)
    }
    @Test func notRunningWhenSocketDead() async {
        let t = FakeTransport(); t.fail = true
        let s = DockerSampler(transportFactory: { t }, isInstalled: { true })
        #expect(await s.sample(now: Date()).state == .notRunning)
    }
    @Test func containerVanishingDropsOnlyThatContainer() async {
        let t = FakeTransport()
        t.routes["/_ping"] = FakeTransport.ok("OK")
        t.routes["/containers/json"] = list([(idA, "api"), (idB, "gone")])
        t.routes[statsPath(idA)] = FakeTransport.ok(stats(10, 100, mem: 500))
        t.routes["/system/df"] = FakeTransport.ok(#"{"LayersSize":10}"#)
        let s = DockerSampler(transportFactory: { t }, isInstalled: { true })
        let snap = await s.sample(now: Date(timeIntervalSince1970: 0))
        #expect(snap.state == .running)
        #expect(snap.containers.map(\.name) == ["api"])
        #expect(snap.containers[0].cpuPercent == nil)   // first sample has no delta
        #expect(snap.diskUsage == 10)
    }
    @Test func cpuPercentFromOwnPreviousSampleAndSortedByMemory() async {
        let t = FakeTransport()
        t.routes["/_ping"] = FakeTransport.ok("OK")
        t.routes["/containers/json"] = list([(idA, "small"), (idB, "big")])
        t.routes[statsPath(idA)] = FakeTransport.ok(stats(0, 0, mem: 10))
        t.routes[statsPath(idB)] = FakeTransport.ok(stats(0, 0, mem: 99))
        let s = DockerSampler(transportFactory: { t }, isInstalled: { true })
        _ = await s.sample(now: Date(timeIntervalSince1970: 0))
        t.routes[statsPath(idA)] = FakeTransport.ok(stats(50, 100, mem: 10))
        t.routes[statsPath(idB)] = FakeTransport.ok(stats(0, 100, mem: 99))
        let snap = await s.sample(now: Date(timeIntervalSince1970: 4))
        #expect(snap.containers.map(\.name) == ["big", "small"])
        #expect(snap.containers[1].cpuPercent == 100)   // 50/100 * 2 cpus * 100
    }
    @Test func notRunningIsReprobedOnlyEvery10Seconds() async {
        let t = FakeTransport(); t.fail = true
        var factoryCalls = 0
        let s = DockerSampler(transportFactory: { factoryCalls += 1; return t }, isInstalled: { true })
        _ = await s.sample(now: Date(timeIntervalSince1970: 0))
        _ = await s.sample(now: Date(timeIntervalSince1970: 4))
        #expect(factoryCalls == 1)
        _ = await s.sample(now: Date(timeIntervalSince1970: 11))
        #expect(factoryCalls == 2)
    }
    @Test func recoversWhenDaemonStarts() async {
        let t = FakeTransport(); t.fail = true
        let s = DockerSampler(transportFactory: { t }, isInstalled: { true })
        #expect(await s.sample(now: Date(timeIntervalSince1970: 0)).state == .notRunning)
        t.fail = false
        t.routes["/_ping"] = FakeTransport.ok("OK")
        t.routes["/containers/json"] = FakeTransport.ok("[]")
        #expect(await s.sample(now: Date(timeIntervalSince1970: 10)).state == .running)
    }
    @Test func systemDfIsCachedFor30Seconds() async {
        let t = FakeTransport()
        t.routes["/_ping"] = FakeTransport.ok("OK")
        t.routes["/containers/json"] = FakeTransport.ok("[]")
        t.routes["/system/df"] = FakeTransport.ok(#"{"LayersSize":10}"#)
        let s = DockerSampler(transportFactory: { t }, isInstalled: { true })
        _ = await s.sample(now: Date(timeIntervalSince1970: 0))
        t.routes["/system/df"] = FakeTransport.ok(#"{"LayersSize":20}"#)
        #expect(await s.sample(now: Date(timeIntervalSince1970: 4)).diskUsage == 10)
        #expect(await s.sample(now: Date(timeIntervalSince1970: 30)).diskUsage == 20)
        #expect(t.requested.filter { $0 == "/system/df" }.count == 2)
    }

    // MARK: - /info (Docker VM size)

    @Test func vmSizeFromInfoIsCachedFor60Seconds() async {
        let t = FakeTransport()
        t.routes["/_ping"] = FakeTransport.ok("OK")
        t.routes["/containers/json"] = FakeTransport.ok("[]")
        // Trimmed from Docker Desktop 4.x on an M4 (Engine 29): NCPU and MemTotal are top-level.
        t.routes["/info"] = FakeTransport.ok(#"{"ID":"x","Containers":3,"NCPU":12,"MemTotal":8217473024,"OperatingSystem":"Docker Desktop"}"#)
        let s = DockerSampler(transportFactory: { t }, isInstalled: { true })
        let first = await s.sample(now: Date(timeIntervalSince1970: 0))
        #expect(first.vmCPUCount == 12)
        #expect(first.vmMemoryTotal == 8_217_473_024)
        t.routes["/info"] = FakeTransport.ok(#"{"NCPU":4,"MemTotal":1}"#)
        #expect(await s.sample(now: Date(timeIntervalSince1970: 59)).vmCPUCount == 12)
        #expect(await s.sample(now: Date(timeIntervalSince1970: 60)).vmCPUCount == 4)
        #expect(t.requested.filter { $0 == "/info" }.count == 2)
    }
    @Test func implausibleInfoValuesAreNil() async {
        let t = FakeTransport()
        t.routes["/_ping"] = FakeTransport.ok("OK")
        t.routes["/containers/json"] = FakeTransport.ok("[]")
        t.routes["/info"] = FakeTransport.ok(#"{"NCPU":0,"MemTotal":-5}"#)
        let snap = await DockerSampler(transportFactory: { t }, isInstalled: { true }).sample(now: Date(timeIntervalSince1970: 0))
        #expect(snap.state == .running)
        #expect(snap.vmCPUCount == nil && snap.vmMemoryTotal == nil)
    }
    @Test func failingInfoKeepsCardRunning() async {
        let t = FakeTransport()
        t.routes["/_ping"] = FakeTransport.ok("OK")
        t.routes["/containers/json"] = FakeTransport.ok("[]")
        t.routes["/info"] = FakeTransport.ok("{not json")
        let snap = await DockerSampler(transportFactory: { t }, isInstalled: { true }).sample(now: Date(timeIntervalSince1970: 0))
        #expect(snap.state == .running && snap.vmCPUCount == nil)
    }

    // MARK: - Stale CPU baseline (design review)

    /// The panel was closed for a minute: the stored counters are 60 s old, and a percentage
    /// from them would be the average over the closed period, not "now".
    @Test func staleCPUBaselineIsDroppedAfterLongGap() async {
        let t = FakeTransport()
        t.routes["/_ping"] = FakeTransport.ok("OK")
        t.routes["/containers/json"] = list([(idA, "api")])
        t.routes[statsPath(idA)] = FakeTransport.ok(stats(0, 0, mem: 1))
        let s = DockerSampler(transportFactory: { t }, isInstalled: { true })
        _ = await s.sample(now: Date(timeIntervalSince1970: 0))
        t.routes[statsPath(idA)] = FakeTransport.ok(stats(50, 100, mem: 1))
        #expect(await s.sample(now: Date(timeIntervalSince1970: 60)).containers.first?.cpuPercent == nil)
        t.routes[statsPath(idA)] = FakeTransport.ok(stats(100, 200, mem: 1))
        #expect(await s.sample(now: Date(timeIntervalSince1970: 64)).containers.first?.cpuPercent == 100)
    }
    @Test func baselineWithinWindowIsUsed() async {
        let t = FakeTransport()
        t.routes["/_ping"] = FakeTransport.ok("OK")
        t.routes["/containers/json"] = list([(idA, "api")])
        t.routes[statsPath(idA)] = FakeTransport.ok(stats(0, 0, mem: 1))
        let s = DockerSampler(transportFactory: { t }, isInstalled: { true })
        _ = await s.sample(now: Date(timeIntervalSince1970: 0))
        t.routes[statsPath(idA)] = FakeTransport.ok(stats(50, 100, mem: 1))
        #expect(await s.sample(now: Date(timeIntervalSince1970: DockerSampler.maxBaselineAge)).containers.first?.cpuPercent == 100)
    }

    // MARK: - Hostile / broken daemon (security review)

    /// Overflowing sizes from a fake socket used to trap the whole app in `diskUsage`.
    @Test func overflowingDiskUsageSaturatesInsteadOfTrapping() async {
        let t = FakeTransport()
        t.routes["/_ping"] = FakeTransport.ok("OK")
        t.routes["/containers/json"] = FakeTransport.ok("[]")
        let max = Int64.max
        t.routes["/system/df"] = FakeTransport.ok(#"{"LayersSize":\#(max),"Volumes":[{"UsageData":{"Size":\#(max)}},{"UsageData":{"Size":\#(max)}}],"BuildCache":[{"Size":\#(max)}],"Containers":[{"SizeRw":\#(max)}]}"#)
        let snap = await DockerSampler(transportFactory: { t }, isInstalled: { true }).sample(now: Date(timeIntervalSince1970: 0))
        #expect(snap.diskUsage == .max)
    }
    @Test func hugeContainerMemoryTotalSaturates() async {
        let t = FakeTransport()
        t.routes["/_ping"] = FakeTransport.ok("OK")
        t.routes["/containers/json"] = list([(idA, "a"), (idB, "b")])
        t.routes[statsPath(idA)] = FakeTransport.ok(stats(0, 0, mem: .max))
        t.routes[statsPath(idB)] = FakeTransport.ok(stats(0, 0, mem: .max))
        let snap = await DockerSampler(transportFactory: { t }, isInstalled: { true }).sample(now: Date(timeIntervalSince1970: 0))
        #expect(snap.containers.count == 2)
        #expect(snap.totalMemory == .max)
    }
    @Test func absurdOnlineCPUsIsClamped() async throws {
        let t = FakeTransport()
        t.routes["/_ping"] = FakeTransport.ok("OK")
        t.routes["/containers/json"] = list([(idA, "a")])
        func s(_ total: UInt64, _ system: UInt64) -> HTTPResponse {
            FakeTransport.ok(#"{"cpu_stats":{"cpu_usage":{"total_usage":\#(total)},"system_cpu_usage":\#(system),"online_cpus":\#(Int.max)},"memory_stats":{}}"#)
        }
        t.routes[statsPath(idA)] = s(0, 0)
        let sampler = DockerSampler(transportFactory: { t }, isInstalled: { true })
        _ = await sampler.sample(now: Date(timeIntervalSince1970: 0))
        t.routes[statsPath(idA)] = s(UInt64.max, 1)
        let snap = await sampler.sample(now: Date(timeIntervalSince1970: 4))
        let p = try #require(snap.containers.first?.cpuPercent)
        #expect(p == Double(DockerCalculator.maxCPUs) * 100)
        _ = Formatters.cpuPercent(snap.totalCPUPercent)     // reaching here: no trap
    }
    /// An id is interpolated into the request path; anything but Docker's hex ids is skipped
    /// before a request is made.
    @Test func invalidContainerIdsAreSkippedWithoutRequest() async {
        let t = FakeTransport()
        t.routes["/_ping"] = FakeTransport.ok("OK")
        let evil = #"../../v1.41/containers/create?x=1 HTTP/1.0\r\n"#
        t.routes["/containers/json"] = FakeTransport.ok(#"[{"Id":"\#(evil)","Names":["/evil"]},{"Id":"ABCDEF123456","Names":["/upper"]},{"Id":"abc","Names":["/short"]},{"Id":"\#(idA)","Names":["/ok"]}]"#)
        t.routes[statsPath(idA)] = FakeTransport.ok(stats(0, 0, mem: 1))
        let snap = await DockerSampler(transportFactory: { t }, isInstalled: { true }).sample(now: Date(timeIntervalSince1970: 0))
        #expect(snap.containers.map(\.name) == ["ok"])
        #expect(t.requested.filter { $0.hasPrefix("/containers/") && $0 != "/containers/json" } == [statsPath(idA)])
    }
    @Test func containerIDValidation() {
        #expect(DockerSampler.isValidContainerID(String(repeating: "0", count: 12)))
        #expect(DockerSampler.isValidContainerID(idA))
        #expect(!DockerSampler.isValidContainerID(String(repeating: "0", count: 11)))
        #expect(!DockerSampler.isValidContainerID(String(repeating: "0", count: 65)))
        #expect(!DockerSampler.isValidContainerID("abcdefabcdeg"))
        #expect(!DockerSampler.isValidContainerID("ABCDEFABCDEF"))
        #expect(!DockerSampler.isValidContainerID("abcdefabcde/"))
        #expect(!DockerSampler.isValidContainerID(""))
    }
    @Test func eachEndpointHasItsOwnResponseCap() async {
        let t = FakeTransport()
        t.routes["/_ping"] = FakeTransport.ok("OK")
        t.routes["/containers/json"] = list([(idA, "a")])
        t.routes[statsPath(idA)] = FakeTransport.ok(stats(0, 0, mem: 1))
        _ = await DockerSampler(transportFactory: { t }, isInstalled: { true }).sample(now: Date(timeIntervalSince1970: 0))
        #expect(t.limits["/_ping"] == 1 << 10)
        #expect(t.limits["/containers/json"] == 1 << 20)
        #expect(t.limits[statsPath(idA)] == 256 << 10)
        #expect(t.limits["/system/df"] == 16 << 20)
        #expect(t.limits["/info"] == 256 << 10)
    }
    /// A daemon answering every request just under the client timeout must not hold one sample
    /// for containers x timeout: after `sampleBudget` the remaining containers are skipped.
    @Test func sampleStopsAfterTimeBudget() async {
        let t = FakeTransport()
        var clock: TimeInterval = 1_000
        t.onRequest = { _ in clock += 1 }      // every request "takes" one second
        t.routes["/_ping"] = FakeTransport.ok("OK")
        let ids = (1...10).map { String(format: "%064x", $0) }
        t.routes["/containers/json"] = list(ids.map { ($0, "c\($0.suffix(2))") })
        for id in ids { t.routes[statsPath(id)] = FakeTransport.ok(stats(0, 0, mem: 1)) }
        let s = DockerSampler(transportFactory: { t }, isInstalled: { true }, clock: { clock })
        let snap = await s.sample(now: Date(timeIntervalSince1970: 0))
        #expect(snap.state == .running)
        // ping + list = 2 s; four stats calls reach the 6 s budget; df and info are skipped too.
        #expect(snap.containers.count == 4)
        #expect(!t.requested.contains("/system/df") && !t.requested.contains("/info"))
    }
}
