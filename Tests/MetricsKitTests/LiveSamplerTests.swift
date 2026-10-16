import Testing
import Foundation
import Darwin
import IOKit
@testable import MetricsKit

/// Live integration tests against the real machine (Task 11). They read real hardware, the real
/// file system and the real Docker socket, so they are skipped on CI where hardware differs.
/// Nothing here mutates system state except a temporary file in `NSTemporaryDirectory()`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil))
struct LiveSamplerTests {

    // MARK: - Plan Task 11 Step 1 (verbatim intent)

    @Test func cpuInRange() async throws {
        let s = CPUSampler()
        try await Task.sleep(for: .milliseconds(600))     // > CPUSampler.minimumWindow
        let cpu = try #require(s.sample())
        #expect((0...1).contains(cpu.total))
        #expect(cpu.perCore.count == ProcessInfo.processInfo.activeProcessorCount)
    }
    @Test func memoryTotalIsPhysical() throws {
        let m = try #require(MemorySampler().sample())
        #expect(m.total == ProcessInfo.processInfo.physicalMemory)
        #expect(m.used > 0 && m.used <= m.total)
    }
    @Test func swapReadable() { #expect(SwapSampler().sample() != nil) }
    @Test func gpuReadable() throws { #expect((0...1).contains(try #require(GPUSampler().sample()).utilization)) }
    @Test func rootVolumePresentWithIOStats() throws {
        let d = DiskSampler()
        _ = d.sample(now: Date())
        let vols = d.sample(now: Date().addingTimeInterval(1))
        let root = try #require(vols.first)
        #expect(root.isRoot)
        #expect(root.total > 0)
        #expect(root.readBytesPerSecond != nil)
        #expect(root.deviceID != nil)
    }
    @Test func dockerStateResolvesWithinTimeout() async {
        let start = Date()
        let s = await DockerSampler().sample(now: Date())
        #expect([.running, .notRunning, .notInstalled].contains(s.state))
        #expect(Date().timeIntervalSince(start) < 10)
    }

    // MARK: - CPU beyond the plan

    @Test func perCoreValuesInRangeAndEfficiencyCountMatchesSysctl() async throws {
        let s = CPUSampler()
        try await Task.sleep(for: .milliseconds(600))     // > CPUSampler.minimumWindow
        let cpu = try #require(s.sample())
        #expect(cpu.perCore.allSatisfy { (0...1).contains($0) })
        #expect(cpu.efficiencyCoreCount == Sysctl.int("hw.perflevel1.logicalcpu"))
        #expect(cpu.efficiencyCores.count + cpu.performanceCores.count == cpu.perCore.count)
    }

    /// Pins the "E-cores are numbered first" assumption in `CPUSampler` against this machine's
    /// IODeviceTree (`cluster-type` per `logical-cpu-id`). If Apple ever interleaves clusters,
    /// the P/E bars in the CPU card would silently swap; this test catches that.
    @Test func efficiencyCoresAreNumberedFirstInDeviceTree() throws {
        let types = Self.deviceTreeClusterTypes()
        try #require(!types.isEmpty, "IODeviceTree:/cpus not readable")
        let eCount = try #require(Sysctl.int("hw.perflevel1.logicalcpu"))
        #expect(types.count == ProcessInfo.processInfo.activeProcessorCount)
        for (id, type) in types.sorted(by: { $0.key < $1.key }) {
            #expect(type == (id < eCount ? "E" : "P"), "logical-cpu-id \(id) is \(type)")
        }
    }

    /// Ticks must actually move: saturate every core for ~1 s and the total must read high.
    /// (A sampler that, for example, read the same buffer twice would report ~0 here.)
    @Test func cpuUnderFullLoadReadsHigh() throws {
        let sampler = CPUSampler()
        let n = ProcessInfo.processInfo.activeProcessorCount
        let stop = Date().addingTimeInterval(1.0)
        let group = DispatchGroup()
        for _ in 0..<n {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                var x: UInt64 = 1
                while Date() < stop { for _ in 0..<10_000 { x = x &* 6364136223846793005 &+ 1 } }
                withExtendedLifetime(x) {}
            }
        }
        group.wait()
        let cpu = try #require(sampler.sample())
        #expect(cpu.total > 0.6, "total busy under \(n) spinning threads was \(cpu.total)")
    }

    // MARK: - Memory / swap beyond the plan

    @Test func memoryBreakdownIsConsistentAndPressureMatchesKernel() throws {
        let m = try #require(MemorySampler().sample())
        #expect(m.used == min(m.total, m.app + m.wired + m.compressed))
        #expect(m.wired > 0)
        let level = Sysctl.int("kern.memorystatus_vm_pressure_level")
        let expected: MemoryPressure = switch level { case 4: .critical; case 2: .warning; default: .normal }
        #expect(m.pressure == expected)
    }

    @Test func swapStructIsSaneAndPageAligned() throws {
        let s = try #require(SwapSampler().sample())
        #expect(s.used <= s.total)
        // Swap files are allocated in whole MiB; a misread struct layout would break this.
        #expect(s.total % (1 << 20) == 0)
        #expect(MemoryLayout<xsw_usage>.size == 32)
    }

    // MARK: - GPU beyond the plan

    /// With a window server running, the AGX driver always holds some system memory. Zero here
    /// means the `In use system memory` key was renamed and the GPU card would show 0 B.
    @Test func gpuMemoryKeyPresent() throws {
        let raw = try #require(GPUSampler.readIOAccelerator())
        #expect(raw["Device Utilization %"] is NSNumber)
        #expect(raw["In use system memory"] is NSNumber)
        #expect(try #require(GPUSampler().sample()).memoryInUse > 0)
    }

    // MARK: - Disks beyond the plan

    @Test func rootVolumeCapacityMatchesStatfs() throws {
        let root = try #require(DiskSampler().sample(now: Date()).first)
        let fs = try #require(Self.statfsBytes("/"))
        #expect(root.id == "/")
        #expect(root.isInternal)
        #expect(root.total == fs.total)
        // "Important usage" includes purgeable space, so it can only be >= plain f_bavail
        // (allow 1% for writes between the two reads).
        #expect(Double(root.available) >= Double(fs.available) * 0.99)
        #expect(root.available <= root.total)
    }

    /// The sealed system volume's IOMedia must walk up to the physical NVMe block driver.
    @Test func rootBlockDeviceResolvesToCounters() throws {
        let bsd = try #require(FileManagerVolumeSource.mountTable().first { $0.path == "/" }?.bsdName)
        let device = try #require(IOKitDiskIOSource().device(bsdName: bsd))
        #expect(!device.id.isEmpty)
        #expect(try #require(device.counters).read > 0)
    }

    /// The mount table is read with `MNT_NOWAIT`; the root must be a local candidate and nothing
    /// non-local may survive the filter (a dead SMB/NFS mount would block `statfs`).
    @Test func mountTableHasLocalRootAndFiltersNonLocal() throws {
        let table = FileManagerVolumeSource.mountTable()
        let root = try #require(table.first { $0.path == "/" })
        #expect(root.isLocal && root.bsdName != nil)
        #expect(FileManagerVolumeSource.candidates(table).allSatisfy { $0.isLocal })
        #expect(FileManagerVolumeSource.candidates(table).contains { $0.path == "/" })
    }

    @Test func hiddenAndSystemVolumesAreNotListed() {
        let ids = DiskSampler().sample(now: Date()).map(\.id)
        #expect(ids.filter { $0 == "/" }.count == 1)
        #expect(!ids.contains("/Volumes/Recovery"))
        #expect(!ids.contains { $0.hasPrefix("/System/Volumes") })
        #expect(!ids.contains { $0.contains("CoreSimulator") || $0.contains("DeviceFS") })
        #expect(Set(ids).count == ids.count)
    }

    /// Writes 32 MB with F_FULLFSYNC between two samples; the root's write rate must reflect it.
    @Test func rootWriteThroughputReflectsRealWrites() throws {
        let sampler = DiskSampler()
        let start = Date()
        _ = sampler.sample(now: start)
        let size = 32 << 20
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sm-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let fd = open(url.path, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
        try #require(fd >= 0)
        _ = fcntl(fd, F_NOCACHE, 1)
        var bytes = [UInt8](repeating: 0, count: size)
        for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 2654435761 >> 13) } // not compressible to zero
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, size) }
        _ = fcntl(fd, F_FULLFSYNC)
        close(fd)
        try #require(written == size)
        let end = Date()
        let root = try #require(sampler.sample(now: end).first)
        let rate = try #require(root.writeBytesPerSecond)
        let floor = 0.8 * Double(size) / end.timeIntervalSince(start)
        #expect(rate >= floor, "write rate \(rate) B/s below \(floor) B/s after writing \(size) bytes")
    }

    /// Review Focus 4 on real hardware: the FSKit exFAT disk must show correct capacity.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/Volumes/Elements")))
    func externalFSKitVolumeShowsCapacity() throws {
        let d = DiskSampler()
        _ = d.sample(now: Date())
        let vols = d.sample(now: Date().addingTimeInterval(1))
        let ext = try #require(vols.first { $0.id == "/Volumes/Elements" })
        let fs = try #require(Self.statfsBytes("/Volumes/Elements"))
        #expect(!ext.isInternal && !ext.isRoot)
        #expect(ext.total == fs.total)
        #expect(abs(Double(ext.available) - Double(fs.available)) <= Double(fs.total) * 0.01)
        #expect(ext.usedFraction > 0 && ext.usedFraction < 1)   // FSKit important=0 must not read as 100% full
        #expect(vols.last?.isInternal == false)                  // external volumes are ordered after internal
    }

    // MARK: - Docker: live daemon (only when the socket answers)

    @Test(.enabled(if: Self.liveDockerSocket() != nil))
    func dockerLiveMatchesEngineAPI() async throws {
        let path = try #require(Self.liveDockerSocket())
        let raw = try UnixSocketHTTPClient(socketPath: path).get("/containers/json")
        let list = try #require(try JSONSerialization.jsonObject(with: raw.body) as? [[String: Any]])
        let sampler = DockerSampler()
        let first = await sampler.sample(now: Date())
        #expect(first.state == .running)
        #expect(first.containers.count == min(list.count, DockerSampler.maxContainers))
        #expect(first.containers.allSatisfy { $0.cpuPercent == nil })
        #expect((first.diskUsage ?? 0) > 0)
        #expect((first.vmCPUCount ?? 0) > 0)
        #expect((first.vmMemoryTotal ?? 0) > 0)
        try await Task.sleep(for: .seconds(1))
        let second = await sampler.sample(now: Date())
        #expect(second.state == .running)
        // Every container that survived both samples has a CPU value now.
        let both = Set(first.containers.map(\.id)).intersection(second.containers.map(\.id))
        #expect(second.containers.filter { both.contains($0.id) }.allSatisfy { $0.cpuPercent != nil })
        #expect(second.containers.compactMap(\.cpuPercent).allSatisfy { $0 >= 0 && $0.isFinite })
        #expect(zip(second.containers, second.containers.dropFirst()).allSatisfy { $0.memory >= $1.memory })
        #expect(second.containers.allSatisfy { !$0.name.isEmpty && !$0.name.hasPrefix("/") })
    }

    /// GUI apps do not inherit the shell's `DOCKER_HOST`; the locator must still find the live
    /// socket from the Docker context / known runtime paths with an empty environment.
    @Test(.enabled(if: Self.liveDockerSocket() != nil))
    func dockerSocketFoundWithoutEnvironment() throws {
        let live = try #require(Self.liveDockerSocket())
        let found = try #require(DockerLocator.socketPath(environment: [:]))
        #expect(try UnixSocketHTTPClient(socketPath: found).get("/_ping").status == 200, "found \(found), live \(live)")
    }

    // MARK: - Docker: "not running" simulated without touching Docker Desktop

    @Test func dockerBogusSocketPathIsNotRunningFast() async {
        let bogus = "/tmp/sm-bogus-\(UUID().uuidString.prefix(8)).sock"
        let s = DockerSampler(transportFactory: { UnixSocketHTTPClient(socketPath: bogus, timeout: 2) },
                              isInstalled: { true })
        let start = Date()
        #expect(await s.sample(now: Date()).state == .notRunning)
        #expect(Date().timeIntervalSince(start) < 1)
    }

    @Test func dockerBogusSocketWithoutInstallIsNotInstalled() async {
        // No socket file anywhere and nothing installed -> card hidden.
        let s = DockerSampler(transportFactory: {
            DockerLocator.socketPath(environment: [:], fileExists: { _ in false })
                .map { UnixSocketHTTPClient(socketPath: $0) } }, isInstalled: { false })
        #expect(await s.sample(now: Date()).state == .notInstalled)
    }

    /// Review Focus 2 end-to-end: a real stale socket file (bound, nobody listening) through the
    /// real client and the real sampler, with the production 2 s timeout.
    @Test func dockerStaleSocketFileIsNotRunningWithinTimeout() async throws {
        let path = Self.shortSocketPath()
        let fd = try Self.bindSocket(at: path, listen: false)
        close(fd)
        defer { unlink(path) }
        let s = DockerSampler(transportFactory: { UnixSocketHTTPClient(socketPath: path, timeout: 2) }, isInstalled: { true })
        let start = Date()
        #expect(await s.sample(now: Date()).state == .notRunning)
        #expect(Date().timeIntervalSince(start) < 2.5)
    }

    /// Daemon accepts the connection (kernel backlog) but never answers `/_ping`.
    @Test func dockerHungDaemonIsNotRunningWithinTimeout() async throws {
        let path = Self.shortSocketPath()
        let fd = try Self.bindSocket(at: path, listen: true)
        defer { close(fd); unlink(path) }
        let s = DockerSampler(transportFactory: { UnixSocketHTTPClient(socketPath: path, timeout: 2) }, isInstalled: { true })
        let start = Date()
        #expect(await s.sample(now: Date()).state == .notRunning)
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed >= 1.9 && elapsed < 4.5, "elapsed \(elapsed)")   // spec §5: ~2 s, worst case ~2x
    }

    /// `DOCKER_HOST` pointing at a missing socket falls back to the default locations (spec §3
    /// discovery order), so a bogus `DOCKER_HOST` alone cannot simulate "not running".
    @Test func dockerHostBogusFallsBackToDefaultSocket() {
        let env = ["DOCKER_HOST": "unix:///tmp/sm-definitely-missing.sock"]
        let found = DockerLocator.socketPath(environment: env)
        let defaults = ["\(NSHomeDirectory())/.docker/run/docker.sock", "/var/run/docker.sock"]
        if let found { #expect(defaults.contains(found)) }
        else { #expect(!defaults.contains { FileManager.default.fileExists(atPath: $0) }) }
    }

    /// A daemon that answers `/_ping` and the list but hangs on every stats call. Each stats
    /// request is bounded by the client timeout, so the whole sample is bounded by
    /// containers x timeout (not forever) and the card stays `running`.
    /// Measures the total so the report can state the real worst case.
    @Test func dockerHangingStatsIsBoundedPerContainer() async throws {
        let server = try HangingStatsServer(containers: 4)
        defer { server.stop() }
        let timeout = 0.3
        let s = DockerSampler(transportFactory: { UnixSocketHTTPClient(socketPath: server.path, timeout: timeout) },
                              isInstalled: { true })
        let start = Date()
        let snap = await s.sample(now: Date())
        let elapsed = Date().timeIntervalSince(start)
        #expect(snap.state == .running)
        #expect(snap.containers.isEmpty)
        // 4 stats calls x 0.3 s each; must not exceed 2x per request (client contract).
        #expect(elapsed >= 4 * timeout * 0.9 && elapsed < 4 * timeout * 2 + 0.5, "elapsed \(elapsed)")
    }

    // MARK: - Engine with live samplers

    @MainActor
    @Test func liveEngineFillsEveryCardWhenPanelOpens() async throws {
        let e = MetricsEngine(refreshInterval: 2, samplers: .live(), hostInfo: .current())
        // CPU needs a window of at least CPUSampler.minimumWindow after the samplers prime.
        try await Task.sleep(for: .seconds(CPUSampler.minimumWindow + 0.1))
        e.isPanelOpen = true
        #expect(e.snapshot.cpu != nil)
        #expect(e.snapshot.memory != nil)
        #expect(e.snapshot.swap != nil)
        #expect(e.snapshot.gpu != nil)
        #expect(e.snapshot.volumes.first?.isRoot == true)
        for _ in 0..<100 where e.snapshot.docker == nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(e.snapshot.docker != nil, "Docker sample did not land within 5 s")
    }

    /// Defect: opening the panel ticks immediately, independent of the timer. When that lands
    /// shortly after (or before) a timer tick, `CPUSampler` computes usage over a few ms. Mach
    /// ticks advance at 100 Hz, so a < 10 ms window has 0-1 ticks per core: every core reads
    /// exactly 0% or 100% and the total is noise — shown in the menu bar and stored in History.
    /// Here the timer tick is followed by the panel opening ~immediately (worst case).
    @MainActor
    @Test(.bug("qa: panel-open tick resamples CPU over a few ms"))
    func panelOpenRightAfterTickDoesNotRecordQuantizedCPU() async throws {
        let e = MetricsEngine(refreshInterval: 2, samplers: .live(), hostInfo: .current())
        try await Task.sleep(for: .seconds(1))
        e.tick(now: Date())                         // the timer tick: a real 1 s window
        let timerSample = try #require(e.snapshot.cpu)
        #expect(!timerSample.perCore.allSatisfy { $0 == 0 || $0 == 1 })   // sanity: real window is not quantized
        e.isPanelOpen = true                         // hover-open a few µs later
        let openSample = try #require(e.snapshot.cpu)
        #expect(!openSample.perCore.allSatisfy { $0 == 0 || $0 == 1 },
                "per-core after panel open: \(openSample.perCore)")
        #expect(e.history.cpu.elements.count == 1, "the open tick must not add a second History point")
    }

    @Test func hostInfoMatchesSysctl() throws {
        let h = HostInfo.current()
        #expect(h.chip == Sysctl.string("machdep.cpu.brand_string"))
        #expect(!h.modelName.isEmpty && h.modelName != "Mac")
        let boot = try #require(h.bootTime)
        #expect(boot < Date() && boot > Date(timeIntervalSince1970: 1_600_000_000))
    }

    // MARK: - Resource leaks (idle-cost budget: the app samples every 1-5 s for days)

    /// Mach send rights and IOKit objects are port names in our task; a leaked right per call
    /// would show as growth proportional to the iteration count.
    @Test(arguments: ["cpu", "memory", "swap", "gpu", "disk"])
    func samplerDoesNotLeakMachPorts(_ which: String) {
        let iterations = 500
        // A fake clock one second per call keeps CPUSampler from short-circuiting the read
        // (it reuses the last value within `minimumWindow`), so every iteration hits Mach.
        var fakeNow: TimeInterval = 0
        let cpu = CPUSampler(clock: { fakeNow += 1; return fakeNow }), mem = MemorySampler(), swap = SwapSampler(), gpu = GPUSampler(), disk = DiskSampler()
        func once(_ i: Int) {
            switch which {
            case "cpu": _ = cpu.sample()
            case "memory": _ = mem.sample()
            case "swap": _ = swap.sample()
            case "gpu": _ = gpu.sample()
            default: _ = disk.sample(now: Date(timeIntervalSince1970: TimeInterval(i)))
            }
        }
        for i in 0..<20 { once(i) }                // warm up lazily created ports
        let before = Self.machPortNameCount()
        for i in 0..<iterations { once(i) }
        let growth = Self.machPortNameCount() - before
        // Other suites run in parallel in this process, so allow some noise; a per-call leak is >= 500.
        #expect(growth < 100, "\(which): \(growth) new port names after \(iterations) samples")
    }

    // MARK: - Helpers

    static func statfsBytes(_ path: String) -> (total: UInt64, available: UInt64)? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        return (UInt64(fs.f_blocks) * UInt64(fs.f_bsize), UInt64(fs.f_bavail) * UInt64(fs.f_bsize))
    }

    static func deviceTreeClusterTypes() -> [Int: String] {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return [:] }
        defer { IOObjectRelease(cpus) }
        var it: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &it) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(it) }
        var result: [Int: String] = [:]
        while case let child = IOIteratorNext(it), child != 0 {
            defer { IOObjectRelease(child) }
            func prop(_ key: String) -> AnyObject? {
                IORegistryEntryCreateCFProperty(child, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            // `logical-cpu-id` is published as a number, `cluster-type` as NUL-terminated bytes ("E\0").
            guard let id = (prop("logical-cpu-id") as? NSNumber)?.intValue,
                  let typeData = prop("cluster-type") as? Data else { continue }
            result[id] = String(decoding: typeData.prefix { $0 != 0 }, as: UTF8.self)
        }
        return result
    }

    static func machPortNameCount() -> Int {
        var names: mach_port_name_array_t?
        var namesCount: mach_msg_type_number_t = 0
        var types: mach_port_type_array_t?
        var typesCount: mach_msg_type_number_t = 0
        guard mach_port_names(mach_task_self_, &names, &namesCount, &types, &typesCount) == KERN_SUCCESS else { return -1 }
        if let names {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: names)),
                          vm_size_t(Int(namesCount) * MemoryLayout<mach_port_name_t>.stride))
        }
        if let types {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: types)),
                          vm_size_t(Int(typesCount) * MemoryLayout<mach_port_type_t>.stride))
        }
        return Int(namesCount)
    }

    /// Path of a Docker socket that currently answers `/_ping`, or `nil`.
    static func liveDockerSocket() -> String? {
        guard let path = DockerLocator.socketPath(),
              let r = try? UnixSocketHTTPClient(socketPath: path, timeout: 2).get("/_ping"), r.status == 200 else { return nil }
        return path
    }

    /// `sun_path` is limited to 104 bytes; the test-runner temp dir can be longer.
    static func shortSocketPath() -> String { "/tmp/sm-\(UUID().uuidString.prefix(8)).sock" }

    static func bindSocket(at path: String, listen shouldListen: Bool) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(rc == 0)
        if shouldListen { try #require(listen(fd, 16) == 0) }
        return fd
    }
}

/// Minimal fake Docker daemon on a unix socket: answers `/_ping`, `/containers/json` (N
/// containers) and `/system/df`, and never answers stats requests (holds the connection open).
final class HangingStatsServer: @unchecked Sendable {
    let path = LiveSamplerTests.shortSocketPath()
    private let fd: Int32
    private let list: String
    private let lock = NSLock()
    private var stopped = false
    private var held: [Int32] = []
    private var thread: Thread?

    init(containers: Int) throws {
        fd = try LiveSamplerTests.bindSocket(at: path, listen: true)
        // Ids must look like real Docker ids (hex, 12-64 chars) or the sampler skips them.
        list = "[" + (0..<containers).map { #"{"Id":"\#(String(format: "%064x", $0 + 1))","Names":["/c\#($0)"]}"# }
            .joined(separator: ",") + "]"
        let t = Thread { [self] in run() }
        thread = t
        t.start()
    }

    private func run() {
        while !lock.withLock({ stopped }) {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 50) > 0 else { continue }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(client, &buf, buf.count)
            let req = n > 0 ? String(decoding: buf[..<n], as: UTF8.self) : ""
            let target = req.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let body: String?
            switch target {
            case "/_ping": body = "OK"
            case "/containers/json": body = list
            case "/system/df": body = "{}"
            default: body = nil      // stats: never answer, keep the connection open
            }
            if let body {
                let resp = Array("HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n\(body)".utf8)
                _ = resp.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                close(client)
            } else {
                lock.withLock { held.append(client) }
            }
        }
    }

    func stop() {
        lock.withLock { stopped = true }
        while thread?.isFinished == false { usleep(10_000) }
        lock.withLock { held.forEach { close($0) }; held = [] }
        close(fd)
        unlink(path)
    }
}
