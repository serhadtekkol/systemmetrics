import Testing
import Foundation
import Darwin
@testable import MetricsKit

// Independent verification of the fix round for #23, #24, #27, #28-#33 and the hover machine
// (#20). Written by QA against the original repros, not against the implementation's own tests.
// The hostile-daemon tests talk to a real unix socket so the whole client path (socket options,
// read loop, caps, deadline, header strip, decode, arithmetic) is exercised, not a fake transport.

// MARK: - Scripted fake Docker daemon on a real unix socket

/// Each connection is served on its own thread, so a slow or silent reply never blocks the
/// next request. `handler` gets the request target and how many times it was asked before.
final class ScriptedDockerDaemon: @unchecked Sendable {
    enum Reply {
        case json(String)
        case raw([UInt8])
        /// Sends `bytes` one chunk at a time with `interval` between chunks.
        case trickle([UInt8], chunk: Int, interval: TimeInterval)
        /// Accepts the request and never answers (connection held until `stop`).
        case silent
    }

    let path = "/tmp/sm-qa-\(UUID().uuidString.prefix(8)).sock"
    private let fd: Int32
    private let handler: @Sendable (String, Int) -> Reply
    private let lock = NSLock()
    private var stopped = false
    private var counts: [String: Int] = [:]
    private var held: [Int32] = []
    private var acceptThread: Thread?

    init(handler: @escaping @Sendable (String, Int) -> Reply) throws {
        self.handler = handler
        fd = try LiveSamplerTests.bindSocket(at: path, listen: true)
        let t = Thread { [self] in acceptLoop() }
        acceptThread = t
        t.start()
    }

    var requestCounts: [String: Int] { lock.withLock { counts } }

    private func acceptLoop() {
        while !lock.withLock({ stopped }) {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 20) > 0 else { continue }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            Thread { [self] in serve(client) }.start()
        }
    }

    private func serve(_ client: Int32) {
        var request = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 4096)
        while !request.contains(13) || !String(decoding: request, as: UTF8.self).contains("\r\n\r\n") {
            let n = read(client, &buf, buf.count)
            guard n > 0 else { close(client); return }
            request += buf[..<n]
        }
        let target = String(decoding: request, as: UTF8.self).split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let n = lock.withLock { () -> Int in
            let c = counts[target, default: 0]; counts[target] = c + 1; return c
        }
        func send(_ bytes: [UInt8]) -> Bool {
            var off = 0
            while off < bytes.count {
                let w = bytes[off...].withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                if w <= 0 { return false }
                off += w
            }
            return true
        }
        switch handler(target, n) {
        case .json(let body):
            _ = send(Array("HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n\(body)".utf8))
            close(client)
        case .raw(let bytes):
            _ = send(bytes)
            close(client)
        case .trickle(let bytes, let chunk, let interval):
            var i = 0
            while i < bytes.count, !lock.withLock({ stopped }) {
                guard send(Array(bytes[i..<min(i + chunk, bytes.count)])) else { break }
                i += chunk
                usleep(useconds_t(interval * 1_000_000))
            }
            close(client)
        case .silent:
            lock.withLock { held.append(client) }
        }
    }

    func stop() {
        lock.withLock { stopped = true }
        while acceptThread?.isFinished == false { usleep(5_000) }
        lock.withLock { held.forEach { close($0) }; held = [] }
        close(fd)
        unlink(path)
    }
}

private func hexID(_ n: Int) -> String { String(format: "%064x", n) }
private func listJSON(_ ids: [String]) -> String {
    "[" + ids.enumerated().map { #"{"Id":"\#($1)","Names":["/c\#($0)"]}"# }.joined(separator: ",") + "]"
}
private func statsJSON(total: String, system: String, cpus: String = "4", mem: String = "1") -> String {
    #"{"cpu_stats":{"cpu_usage":{"total_usage":\#(total)},"system_cpu_usage":\#(system),"online_cpus":\#(cpus)},"memory_stats":{"usage":\#(mem),"stats":{"inactive_file":0}}}"#
}

struct FixRoundVerificationTests {

    // MARK: Security review / #32 — hostile numbers over a real socket

    /// /system/df with Int64.max everywhere, /info with Int64.max memory, and two stats
    /// responses where total_usage jumps by 2^63. Also a container whose counter does not fit
    /// UInt64 and one with a negative memory value. Nothing may trap; values are clamped.
    @Test func hostileNumbersOverRealSocketDoNotTrapAndAreClamped() async throws {
        let a = hexID(1), b = hexID(2), c = hexID(3)
        let max = Int64.max
        let daemon = try ScriptedDockerDaemon { target, n in
            switch target {
            case "/_ping": return .json("OK")
            case "/containers/json": return .json(listJSON([a, b, c]))
            case statsPath(a):
                return .json(n == 0 ? statsJSON(total: "0", system: "1000000", mem: "\(UInt64.max)")
                                    : statsJSON(total: "9223372036854775808", system: "2000000", mem: "\(UInt64.max)"))
            case statsPath(b): return .json(statsJSON(total: "18446744073709551616", system: "1"))   // 2^64: not a UInt64
            case statsPath(c): return .json(statsJSON(total: "1", system: "1", mem: "-5"))
            case "/system/df":
                return .json(#"{"LayersSize":\#(max),"Volumes":[{"UsageData":{"Size":\#(max)}},{"UsageData":{"Size":\#(max)}}],"BuildCache":[{"Size":\#(max)},{"Size":\#(max)}],"Containers":[{"SizeRw":\#(max)},{"SizeRw":\#(max)}]}"#)
            case "/info": return .json(#"{"NCPU":4,"MemTotal":\#(max)}"#)
            default: return .raw(Array("HTTP/1.0 404 Not Found\r\n\r\n".utf8))
            }
        }
        defer { daemon.stop() }
        let sampler = DockerSampler(transportFactory: { UnixSocketHTTPClient(socketPath: daemon.path, timeout: 1) },
                                    isInstalled: { true })
        let t0 = Date(timeIntervalSince1970: 1_000)
        let first = await sampler.sample(now: t0)
        #expect(first.state == .running)
        #expect(first.diskUsage == UInt64.max)
        #expect(first.vmCPUCount == 4)
        #expect(first.vmMemoryTotal == UInt64(Int64.max))
        // b (counter out of UInt64 range) and c (negative memory) are undecodable -> dropped.
        #expect(first.containers.map(\.id) == [a])
        #expect(first.containers.first?.cpuPercent == nil)

        let second = await sampler.sample(now: t0.addingTimeInterval(SamplingSchedule.dockerInterval))
        let p = try #require(second.containers.first?.cpuPercent)
        #expect(p == 400, "2^63 ns over a 1 ms system window on 4 CPUs must clamp to 400%, got \(p)")
        #expect(second.totalMemory == UInt64.max)
        // The display path must not trap either.
        _ = Formatters.cpuPercent(second.totalCPUPercent)
        _ = Formatters.cores(second.totalCPUCores)
        _ = Formatters.bytes(second.totalMemory)
        _ = Formatters.diskBytes(second.diskUsage ?? 0)
        _ = Formatters.bytes(second.vmMemoryTotal ?? 0)
    }

    /// Non-numbers, NaN-ish tokens and exponents where integers are expected.
    @Test(arguments: ["1e400", "-1", "NaN", "\"12\"", "1.5", "null"])
    func malformedCounterIsDroppedNotTrapped(_ token: String) async throws {
        let a = hexID(1)
        let daemon = try ScriptedDockerDaemon { target, _ in
            switch target {
            case "/_ping": return .json("OK")
            case "/containers/json": return .json(listJSON([a]))
            case statsPath(a): return .json(statsJSON(total: token, system: token, cpus: token, mem: token))
            case "/system/df": return .json(#"{"LayersSize":\#(token)}"#)
            case "/info": return .json(#"{"NCPU":\#(token),"MemTotal":\#(token)}"#)
            default: return .raw(Array("HTTP/1.0 404 Not Found\r\n\r\n".utf8))
            }
        }
        defer { daemon.stop() }
        let s = DockerSampler(transportFactory: { UnixSocketHTTPClient(socketPath: daemon.path, timeout: 1) },
                              isInstalled: { true })
        let snap = await s.sample(now: Date(timeIntervalSince1970: 0))
        #expect(snap.state == .running)
        _ = Formatters.cpuPercent(snap.totalCPUPercent)
    }

    // MARK: #33 — oversized responses are capped per endpoint over a real socket

    @Test func oversizedResponsesAreRejectedPerEndpoint() async throws {
        let a = hexID(1), b = hexID(2)
        let bigStats = statsJSON(total: "1", system: "1") + String(repeating: " ", count: 300 << 10)   // > 256 KB
        let bigDF = "{\"LayersSize\":1}" + String(repeating: " ", count: 17 << 20)                     // > 16 MB
        let bigInfo = "{\"NCPU\":4}" + String(repeating: " ", count: 300 << 10)
        let daemon = try ScriptedDockerDaemon { target, _ in
            switch target {
            case "/_ping": return .json("OK")
            case "/containers/json": return .json(listJSON([a, b]))
            case statsPath(a): return .json(statsJSON(total: "1", system: "1"))
            case statsPath(b): return .json(bigStats)
            case "/system/df": return .json(bigDF)
            case "/info": return .json(bigInfo)
            default: return .raw(Array("HTTP/1.0 404 Not Found\r\n\r\n".utf8))
            }
        }
        defer { daemon.stop() }
        let s = DockerSampler(transportFactory: { UnixSocketHTTPClient(socketPath: daemon.path, timeout: 2) },
                              isInstalled: { true })
        let snap = await s.sample(now: Date(timeIntervalSince1970: 0))
        #expect(snap.state == .running)
        #expect(snap.containers.map(\.id) == [a])
        #expect(snap.diskUsage == nil)
        #expect(snap.vmCPUCount == nil)
    }

    @Test func oversizedPingMeansNotRunning() async throws {
        let daemon = try ScriptedDockerDaemon { target, _ in
            target == "/_ping" ? .json("OK" + String(repeating: "x", count: 2048)) : .json("[]")
        }
        defer { daemon.stop() }
        let s = DockerSampler(transportFactory: { UnixSocketHTTPClient(socketPath: daemon.path, timeout: 1) },
                              isInstalled: { true })
        #expect(await s.sample(now: Date(timeIntervalSince1970: 0)).state == .notRunning)
    }

    /// A daemon that trickles every stats response one byte per 50 ms (each read succeeds, so
    /// SO_RCVTIMEO never fires; only the client's own deadline can stop it), for 20 containers.
    /// One request is bounded by ~the client timeout; the whole sample by sampleBudget plus one
    /// request. Before the fix this was 20 x timeout.
    @Test func tricklingDaemonIsBoundedPerRequestAndPerSample() async throws {
        let ids = (1...20).map(hexID)
        let slow = Array(("HTTP/1.0 200 OK\r\n\r\n" + statsJSON(total: "1", system: "1") + String(repeating: " ", count: 4096)).utf8)
        let daemon = try ScriptedDockerDaemon { target, _ in
            switch target {
            case "/_ping": return .json("OK")
            case "/containers/json": return .json(listJSON(ids))
            default: return .trickle(slow, chunk: 1, interval: 0.05)
            }
        }
        defer { daemon.stop() }
        let timeout = 0.8
        let s = DockerSampler(transportFactory: { UnixSocketHTTPClient(socketPath: daemon.path, timeout: timeout) },
                              isInstalled: { true })
        let start = Date()
        let snap = await s.sample(now: Date(timeIntervalSince1970: 0))
        let elapsed = Date().timeIntervalSince(start)
        #expect(snap.state == .running)
        #expect(snap.containers.isEmpty)
        #expect(elapsed < DockerSampler.sampleBudget + 2 * timeout + 0.5, "sample took \(elapsed) s")
        let statsRequests = daemon.requestCounts.filter { $0.key.hasSuffix("one-shot=true") }.values.reduce(0, +)
        #expect(statsRequests < ids.count, "budget did not cut the container loop: \(statsRequests) stats requests")
    }

    @Test func singleTricklingRequestStopsAtClientDeadline() throws {
        let slow = Array(("HTTP/1.0 200 OK\r\n\r\n" + String(repeating: "x", count: 10_000)).utf8)
        let daemon = try ScriptedDockerDaemon { _, _ in .trickle(slow, chunk: 1, interval: 0.02) }
        defer { daemon.stop() }
        let client = UnixSocketHTTPClient(socketPath: daemon.path, timeout: 0.5)
        let start = Date()
        #expect(throws: UnixSocketError.timeout) { try client.get("/_ping", maxBytes: 1 << 20) }
        #expect(Date().timeIntervalSince(start) < 1.0)
    }

    // MARK: #23 (design review) — stale baselines

    private final class Vols: VolumeSource {
        func volumes() -> [VolumeInfo] {
            [VolumeInfo(path: "/", name: "HD", isInternal: true, isRoot: true, total: 100, available: 50, bsdName: "disk9s1")]
        }
    }
    private final class GrowingIO: DiskIOSource {
        var bytes: UInt64 = 0
        func device(bsdName: String) -> BlockDevice? {
            bytes += 1_000_000
            return BlockDevice(id: "dev", counters: DiskIOCounters(read: bytes, write: bytes))
        }
    }

    @Test(arguments: [(10.0, true), (10.5, false), (11.0, false), (600.0, false)])
    func diskRateUsesBaselineOnlyWithinMaxAge(_ gap: Double, _ hasRate: Bool) {
        let s = DiskSampler(volumes: Vols(), io: GrowingIO())
        let t0 = Date(timeIntervalSince1970: 0)
        _ = s.sample(now: t0)
        let v = s.sample(now: t0.addingTimeInterval(gap)).first
        #expect((v?.readBytesPerSecond != nil) == hasRate, "gap \(gap)")
        // The stale sample re-baselines: the next normal tick has a rate again.
        #expect(s.sample(now: t0.addingTimeInterval(gap + 2)).first?.readBytesPerSecond != nil)
    }

    @Test(arguments: [(12.0, true), (12.5, false), (60.0, false)])
    func dockerCPUUsesBaselineOnlyWithinMaxAge(_ gap: Double, _ hasValue: Bool) async {
        let t = FakeTransport()
        t.routes["/_ping"] = FakeTransport.ok("OK")
        t.routes["/containers/json"] = FakeTransport.ok(listJSON([idA]))
        t.routes[statsPath(idA)] = FakeTransport.ok(statsJSON(total: "0", system: "0"))
        let s = DockerSampler(transportFactory: { t }, isInstalled: { true })
        _ = await s.sample(now: Date(timeIntervalSince1970: 0))
        t.routes[statsPath(idA)] = FakeTransport.ok(statsJSON(total: "10", system: "100"))
        let p = await s.sample(now: Date(timeIntervalSince1970: gap)).containers.first?.cpuPercent
        #expect((p != nil) == hasValue, "gap \(gap) -> \(String(describing: p))")
    }

    /// End to end through the engine: panel open (disk sampled), closed for 30 s, reopened.
    /// The first disk rate after reopening must be nil ("—"), not a 30 s average.
    @MainActor
    @Test func reopeningPanelAfterLongCloseShowsNoDiskRate() {
        let disk = DiskSampler(volumes: Vols(), io: GrowingIO())
        var offset: TimeInterval = 0
        let samplers = Samplers(
            cpu: { CPUSnapshot(total: 0.1, perCore: [0.1], efficiencyCoreCount: 0) },
            memory: { nil }, swap: { nil }, gpu: { nil },
            volumes: { now in disk.sample(now: now.addingTimeInterval(offset)) },
            docker: { _ in DockerSnapshot(state: .notInstalled) })
        let e = MetricsEngine(refreshInterval: 2, samplers: samplers, hostInfo: .current())
        e.isPanelOpen = true                                   // first disk sample, no rate yet
        offset = 2; e.tick(now: Date())                        // normal tick while open
        #expect(e.snapshot.volumes.first?.readBytesPerSecond != nil)
        e.isPanelOpen = false
        offset = 32                                            // closed for 30 s
        e.isPanelOpen = true
        #expect(e.snapshot.volumes.first?.readBytesPerSecond == nil)
    }

    // MARK: #29 / #30 / #31 — re-run of the original repros plus a variation each

    /// Original #29 repro, verbatim shape: live engine, sleep 2 s, timer-like tick, panel opens
    /// immediately. CPU must not collapse to 0% and History must not gain the off-grid point.
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil))
    func originalPanelOpenRepro() async throws {
        let e = MetricsEngine(refreshInterval: 2, samplers: .live(), hostInfo: .current())
        try await Task.sleep(for: .seconds(2))
        e.tick(now: Date())
        let before = try #require(e.snapshot.cpu)
        e.isPanelOpen = true
        let after = try #require(e.snapshot.cpu)
        #expect(after.total == before.total, "open tick within minimumWindow must reuse the last value")
        #expect(e.history.cpu.elements.count == 1)
        #expect(!after.perCore.allSatisfy { $0 == 0 })
    }

    /// Variation: cold start. The first value after `start()` must arrive within ~minimumWindow
    /// (startup retry), not after a whole refresh interval, and must not be quantized.
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil))
    func coldStartGetsRealCPUValueQuickly() async throws {
        let e = MetricsEngine(refreshInterval: 5, samplers: .live(), hostInfo: .current())
        e.start()
        defer { e.stop() }
        #expect(e.snapshot.cpu == nil)
        try await Task.sleep(for: .seconds(CPUSampler.minimumWindow + 0.3))
        let cpu = try #require(e.snapshot.cpu, "no CPU value 0.8 s after start with a 5 s interval")
        #expect(!cpu.perCore.allSatisfy { $0 == 0 || $0 == 1 }, "\(cpu.perCore)")
    }

    private final class ScriptedTicks: CPUTickSource {
        var reads: [[CPUTicks]]
        private(set) var count = 0
        init(_ reads: [[CPUTicks]]) { self.reads = reads }
        func read() -> [CPUTicks]? { defer { count += 1 }; return count < reads.count ? reads[count] : reads.last }
    }

    @Test func cpuSamplerShortWindowReusesLastValueAndKeepsBaseline() throws {
        let src = ScriptedTicks([[CPUTicks(user: 0, system: 0, idle: 0, nice: 0)],
                                 [CPUTicks(user: 50, system: 0, idle: 50, nice: 0)],
                                 [CPUTicks(user: 150, system: 0, idle: 50, nice: 0)]])
        var now: TimeInterval = 100
        let s = CPUSampler(source: src, efficiencyCoreCount: 0, clock: { now })
        now = 100.2
        #expect(s.sample() == nil)                 // too soon after init, nothing computed yet
        #expect(src.count == 1)                    // and the source was not read
        now = 101
        #expect(try #require(s.sample()).total == 0.5)
        now = 101.1
        #expect(try #require(s.sample()).total == 0.5)   // reused, baseline not moved
        #expect(src.count == 2)
        now = 102
        #expect(try #require(s.sample()).total == 1.0)   // 100 busy of 100 since t=101
    }

    @Test func cpuIdleWrapOriginalReproAndVariations() throws {
        // Original #30 repro.
        let wrap = CPUCalculator.usage(previous: [CPUTicks(user: 1000, system: 0, idle: UInt64(UInt32.max) - 10, nice: 0)],
                                       current: [CPUTicks(user: 1010, system: 0, idle: 89, nice: 0)],
                                       efficiencyCoreCount: 0)
        let p = try #require(wrap?.perCore.first)
        #expect(abs(p - 10.0 / 110.0) < 1e-9, "got \(p)")
        // Variation: the *user* counter wraps while idle advances normally.
        let userWrap = CPUCalculator.usage(previous: [CPUTicks(user: UInt64(UInt32.max) - 4, system: 0, idle: 1000, nice: 0)],
                                           current: [CPUTicks(user: 5, system: 0, idle: 1090, nice: 0)],
                                           efficiencyCoreCount: 0)
        #expect(abs(try #require(userWrap?.perCore.first) - 10.0 / 100.0) < 1e-9)
        // Variation: a real reset to small values (sleep/wake) stays a quiet sample, not a spike.
        let reset = CPUCalculator.usage(previous: [CPUTicks(user: 900_000, system: 300_000, idle: 5_000_000, nice: 0)],
                                        current: [CPUTicks(user: 10, system: 5, idle: 20, nice: 0)],
                                        efficiencyCoreCount: 0)
        if let r = reset?.perCore.first { #expect(r <= 0.5, "reset produced \(r)") }
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, -Double.nan])
    func gpuNonFiniteUtilizationIsRejected(_ v: Double) {
        #expect(GPUStatsParser.parse(["Device Utilization %": NSNumber(value: v)]) == nil)
    }
    @Test func gpuOutOfRangeUtilizationIsClamped() throws {
        #expect(try #require(GPUStatsParser.parse(["Device Utilization %": NSNumber(value: 1e308)])).utilization == 1)
        #expect(try #require(GPUStatsParser.parse(["Device Utilization %": NSNumber(value: -3)])).utilization == 0)
    }

    // MARK: #18 — Formatters (Turkish, small values)

    @Test func formattersSmallValuesAndTurkishDecimals() {
        #expect(Formatters.rate(0) == "0 B/s")
        #expect(Formatters.rate(999) == "999 B/s")
        #expect(!Formatters.rate(1_000).contains("byte"))
        #expect(!Formatters.bytes(1_023).contains("byte"))
        #expect(!Formatters.bytes(0).contains("byte"))
        #expect(Formatters.cpuPercent(2.5) == "2,5%")
        #expect(Formatters.cores(0.83) == "0,8")
        #expect(Formatters.cpuPercent(.infinity) == "0,0%")
        _ = Formatters.cpuPercent(Double.greatestFiniteMagnitude)
        _ = Formatters.rate(.greatestFiniteMagnitude)
    }
    /// Values that round across the 10% switch: 9.96 must not show "10,0%" next to "10%".
    @Test func cpuPercentRoundingAcrossTheDecimalSwitch() {
        #expect(Formatters.cpuPercent(9.96) == "10%", "got \(Formatters.cpuPercent(9.96))")
        #expect(Formatters.cpuPercent(9.94) == "9,9%")
    }

    // MARK: #35 — only local, browsable mounts get a capacity query

    @Test func mountCandidatesSkipNetworkAndHiddenMounts() {
        let local = UInt32(MNT_LOCAL), hidden = UInt32(MNT_DONTBROWSE)
        let table = [MountEntry(path: "/", source: "/dev/disk3s1s1", flags: local),
                     MountEntry(path: "/Volumes/share", source: "//user@nas/share", flags: 0),          // SMB
                     MountEntry(path: "/Volumes/nfs", source: "nas:/export", flags: 0),                  // NFS
                     MountEntry(path: "/Volumes/Recovery", source: "/dev/disk3s3", flags: local | hidden),
                     MountEntry(path: "/System/Volumes/Data", source: "/dev/disk3s5", flags: local | hidden),
                     MountEntry(path: "/Volumes/Elements", source: "/dev/disk6s1", flags: local),
                     MountEntry(path: "/private/var/x", source: "/dev/disk7s1", flags: local)]
        #expect(FileManagerVolumeSource.candidates(table).map(\.path) == ["/", "/Volumes/Elements"])
    }

    // MARK: Live, this machine only (#24 / #27, deviceID)

    static let live = ProcessInfo.processInfo.environment["CI"] == nil

    /// Socket found with an empty environment, through the CLI context alone: the home passed
    /// in has no known sockets, and /var/run/docker.sock is hidden from the locator.
    @Test(.enabled(if: live && LiveSamplerTests.liveDockerSocket() != nil))
    func socketFoundViaContextWithEmptyEnvironment() throws {
        let realHome = NSHomeDirectory()
        let path = DockerLocator.socketPath(
            environment: ["DOCKER_CONFIG": "\(realHome)/.docker"],
            fileExists: { $0 != "/var/run/docker.sock" && FileManager.default.fileExists(atPath: $0) },
            home: "/nonexistent-home")
        #expect(path == "\(realHome)/.docker/run/docker.sock")
        #expect(DockerLocator.socketPath(environment: [:]) == "\(realHome)/.docker/run/docker.sock")
    }

    @Test(.enabled(if: live && LiveSamplerTests.liveDockerSocket() != nil))
    func vmSizeMatchesDaemonInfo() async throws {
        let socket = try #require(DockerLocator.socketPath(environment: [:]))
        let raw = try UnixSocketHTTPClient(socketPath: socket, timeout: 2).get("/info")
        let info = try #require(try JSONSerialization.jsonObject(with: raw.body) as? [String: Any])
        let ncpu = try #require(info["NCPU"] as? Int)
        let mem = try #require((info["MemTotal"] as? NSNumber)?.uint64Value)
        let snap = await DockerSampler(transportFactory: { UnixSocketHTTPClient(socketPath: socket, timeout: 2) },
                                       isInstalled: { true }).sample(now: Date())
        #expect(snap.state == .running)
        #expect(snap.vmCPUCount == ncpu)
        #expect(snap.vmMemoryTotal == mem)
    }

    /// Every APFS volume on the internal SSD (both containers on disk0) resolves to one device
    /// id; the external FSKit disk and a disk image resolve to different ones.
    @Test(.enabled(if: live))
    func deviceIDGroupsVolumesByPhysicalDisk() throws {
        let table = FileManagerVolumeSource.mountTable()
        func bsd(_ mount: String) -> String? { table.first { $0.path == mount }?.bsdName }
        let io = IOKitDiskIOSource()
        let internalMounts = ["/", "/System/Volumes/Data", "/System/Volumes/Preboot", "/System/Volumes/VM",
                              "/System/Volumes/Update", "/System/Volumes/xarts", "/System/Volumes/Hardware"]
        let ids = try internalMounts.compactMap(bsd).map { try #require(io.device(bsdName: $0)?.id, "\($0)") }
        #expect(ids.count >= 4)
        #expect(Set(ids).count == 1, "internal ids: \(zip(internalMounts, ids).map { "\($0)=\($1)" })")
        if let elements = bsd("/Volumes/Elements") {
            let ext = try #require(io.device(bsdName: elements)?.id)
            #expect(!ids.contains(ext))
        }
        if let image = table.first(where: { $0.path.hasPrefix("/Library/Developer/CoreSimulator/Volumes/") })?.bsdName,
           let imageID = io.device(bsdName: image)?.id {
            #expect(!ids.contains(imageID))
        }
        // Through the sampler the app actually uses.
        let vols = DiskSampler().sample(now: Date())
        let root = try #require(vols.first { $0.isRoot })
        #expect(root.deviceID == ids.first)
        if let ext = vols.first(where: { $0.id == "/Volumes/Elements" }) {
            #expect(ext.deviceID != nil && ext.deviceID != root.deviceID)
        }
    }
}

// MARK: - Hover state machine: transitions the shipped tests do not cover

struct HoverStateMachineGapTests {
    typealias M = HoverStateMachine

    private func opened() -> M { var m = M(); _ = m.handle(.itemEntered); _ = m.handle(.openTimerFired); return m }
    private func closing() -> M { var m = opened(); _ = m.handle(.itemExited); return m }

    @Test func panelHiddenWhileOpeningCancelsAndIgnoresLateTimer() {
        var m = M(); _ = m.handle(.itemEntered)
        #expect(m.handle(.panelHidden(pointerInItem: true)) == [.cancelTimers])
        #expect(m.state == .closed)
        #expect(m.handle(.openTimerFired) == [])
    }
    @Test func panelHiddenWhileOpenReturnsToClosed() {
        var m = opened()
        #expect(m.handle(.panelHidden(pointerInItem: false)) == [.cancelTimers])
        #expect(m.state == .closed)
        #expect(m.handle(.itemEntered) == [.startOpenTimer(M.openDelay)])
    }
    @Test func panelHiddenWhileClosingIgnoresLateCloseTimer() {
        var m = closing()
        #expect(m.handle(.panelHidden(pointerInItem: false)) == [.cancelTimers])
        #expect(m.handle(.closeTimerFired) == [])
        #expect(m.state == .closed)
    }
    @Test func panelHiddenWhileClosedOnlyResetsFlags() {
        var m = M()
        #expect(m.handle(.panelHidden(pointerInItem: true)) == [])
        #expect(m.state == .closed)
    }
    @Test func clickDuringClosingPinsAndCancelsCloseTimer() {
        var m = closing()
        #expect(m.handle(.clicked) == [.cancelTimers, .showPanel(pinned: true)])
        #expect(m.handle(.closeTimerFired) == [])
        #expect(m.state == .pinned)
    }
    @Test func clickDuringOpeningPinsImmediately() {
        var m = M(); _ = m.handle(.itemEntered)
        #expect(m.handle(.clicked) == [.cancelTimers, .showPanel(pinned: true)])
        #expect(m.handle(.openTimerFired) == [])
        #expect(m.state == .pinned)
    }
    @Test func dismissDuringClosingHidesNowAndIgnoresLateTimer() {
        var m = closing()
        #expect(m.handle(.dismiss) == [.cancelTimers, .hidePanel])
        #expect(m.handle(.closeTimerFired) == [])
    }
    @Test func lateOpenTimerWhileOpenOrPinnedIsIgnored() {
        var m = opened()
        #expect(m.handle(.openTimerFired) == [])
        _ = m.handle(.clicked)
        #expect(m.handle(.openTimerFired) == [])
        #expect(m.handle(.closeTimerFired) == [])
        #expect(m.state == .pinned)
    }
    /// The AppDelegate feeds `.panelHidden` back after executing `.hidePanel`. That re-entrant
    /// event must be a no-op so the effect loop cannot recurse or emit a second hide.
    @Test func panelHiddenAfterHideEffectIsNoOp() {
        for start in [opened(), closing()] {
            var m = start
            #expect(m.handle(.dismiss).contains(.hidePanel))
            #expect(m.handle(.panelHidden(pointerInItem: false)) == [])
        }
        var p = M(); _ = p.handle(.clicked)
        #expect(p.handle(.clicked) == [.cancelTimers, .hidePanel])
        #expect(p.handle(.panelHidden(pointerInItem: true)) == [])
    }
    /// Pointer still on the item after a pinned panel is dismissed with Esc: the panel stays
    /// closed (no re-open without a new enter), and a click re-pins it.
    @Test func escWithPointerOnItemDoesNotReopenButClickPins() {
        var m = M(); _ = m.handle(.itemEntered); _ = m.handle(.clicked)
        _ = m.handle(.dismiss); _ = m.handle(.panelHidden(pointerInItem: true))
        #expect(m.state == .closed)
        #expect(m.handle(.clicked) == [.cancelTimers, .showPanel(pinned: true)])
    }
    /// Panel ordered out under the pointer with no exit event, then the user goes straight from
    /// the item into where the panel will reappear: the stale `inPanel` must not keep it open.
    @Test func everyHidePathClearsInPanel() {
        for hide in [HoverStateMachine.Event.dismiss, .panelHidden(pointerInItem: false)] {
            var m = opened(); _ = m.handle(.panelEntered); _ = m.handle(.itemExited)
            _ = m.handle(hide)
            _ = m.handle(.panelHidden(pointerInItem: false))
            _ = m.handle(.itemEntered); _ = m.handle(.openTimerFired)
            #expect(m.handle(.itemExited) == [.startCloseTimer(M.closeDelay)], "after \(hide)")
        }
    }
}
