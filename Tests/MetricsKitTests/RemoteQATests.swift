import Foundation
import Testing
@testable import MetricsKit

// QA verification of the remote-Mac feature.
//
// - `RemoteProtocolQATests`, `RemoteHostQATests`, `RemoteDescribeQATests`: pure, always run.
// - `MetricsStreamerQATests`: drives the real streamer with fake samplers and real time.
// - `RemoteMonitorLiveQATests`: real `/usr/bin/ssh`; opt-in with `TEST_RUNNER_REMOTE_QA=1`
//   (and `TEST_RUNNER_REMOTE_QA_HOST=<alias>` for the tests that need a reachable Mac).

struct RemoteProtocolQATests {
    /// A future build that changed the frame shape must be reported as a version mismatch,
    /// not as garbage: that is the reason `version` exists.
    @Test func newerPeerWithChangedShapeIsReportedAsVersionMismatch() {
        let line = Data(#"{"version":2,"host":{"modelName":"MacBook Air","chip":"Apple M2"},"payload":{}}"#.utf8)
        #expect(throws: RemoteFrame.DecodeError.incompatibleVersion(2)) { try RemoteFrame.decode(line: line) }
    }

    @Test func newerPeerWithRenamedFieldIsReportedAsVersionMismatch() throws {
        var object = try JSONSerialization.jsonObject(with: RemoteFrameTests.sample.encodedLine().dropLast()) as! [String: Any]
        object["version"] = 2
        var snapshot = object["snapshot"] as! [String: Any]
        snapshot["cpuLoad"] = snapshot.removeValue(forKey: "timestamp")
        object["snapshot"] = snapshot
        let line = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: RemoteFrame.DecodeError.incompatibleVersion(2)) { try RemoteFrame.decode(line: line) }
    }

    /// JSONEncoder still refuses non-finite doubles (a fact about Foundation, pinned here).
    @Test func rawNonFiniteValueCannotBeEncoded() {
        var frame = RemoteFrameTests.sample
        frame.snapshot.gpu = GPUSnapshot(utilization: .nan, memoryInUse: 0)
        #expect(throws: EncodingError.self) { try frame.encodedLine() }
    }

    /// Regression for systemmetrics-59: the sender runs `validated()` before encoding, so a
    /// NaN/Inf anywhere in a snapshot no longer stops every frame.
    @Test func validatedFrameWithEveryDoubleNonFiniteEncodesAndRoundTrips() throws {
        var frame = RemoteFrameTests.sample
        frame.host.bootTime = Date(timeIntervalSinceReferenceDate: .nan)
        frame.snapshot.timestamp = Date(timeIntervalSinceReferenceDate: .infinity)
        frame.snapshot.cpu = CPUSnapshot(total: .nan, perCore: [.nan, .infinity, -.infinity, 0.5], efficiencyCoreCount: 2)
        frame.snapshot.gpu = GPUSnapshot(utilization: -.infinity, memoryInUse: 0)
        frame.snapshot.volumes[0].readBytesPerSecond = .nan
        frame.snapshot.volumes[0].writeBytesPerSecond = .infinity
        frame.snapshot.docker?.containers = [ContainerSnapshot(id: "a", name: "db", cpuPercent: .nan, memory: 1)]
        let now = Date()
        let line = try frame.validated(now: now).encodedLine()
        let decoded = try RemoteFrame.decode(line: line.dropLast())
        #expect(decoded.host.bootTime == nil)
        #expect(decoded.snapshot.cpu == CPUSnapshot(total: 0, perCore: [0, 0, 0, 0.5], efficiencyCoreCount: 2))
        #expect(decoded.snapshot.gpu?.utilization == 0)
        #expect(decoded.snapshot.volumes[0].readBytesPerSecond == nil && decoded.snapshot.volumes[0].writeBytesPerSecond == nil)
        #expect(decoded.snapshot.docker?.containers.first?.cpuPercent == nil)
    }

    /// Regression for systemmetrics-55: version is probed before the shape.
    @Test func bareVersionOnlyLineIsVersionMismatch() {
        #expect(throws: RemoteFrame.DecodeError.incompatibleVersion(3)) { try RemoteFrame.decode(line: Data(#"{"version":3}"#.utf8)) }
        #expect(throws: RemoteFrame.DecodeError.incompatibleVersion(0)) { try RemoteFrame.decode(line: Data(#"{"version":0,"x":1}"#.utf8)) }
    }

    @Test(arguments: [#"{"host":{}}"#, #"{"version":"1"}"#, #"{"version":1e30}"#, #"[1]"#, #"{"version":null}"#])
    func lineWithoutUsableVersionIsGarbageNotMismatch(_ text: String) {
        #expect(throws: (any Error).self) { try RemoteFrame.decode(line: Data(text.utf8)) }
        do { _ = try RemoteFrame.decode(line: Data(text.utf8)) } catch {
            #expect(!(error is RemoteFrame.DecodeError), "\(text) -> \(error)")
        }
    }

    /// Regression for systemmetrics-48 with the values from the original finding.
    @Test func hostileFrameFromFindingDoesNotTrapTheUIPaths() throws {
        let frame = try RemoteFrameValidationTests.decode { json in
            var host = json["host"] as! [String: Any]
            host["bootTime"] = 1e300
            json["host"] = host
            var snap = json["snapshot"] as! [String: Any]
            snap["timestamp"] = -1e300
            var cpu = snap["cpu"] as! [String: Any]
            cpu["efficiencyCoreCount"] = Int.min
            cpu["perCore"] = Array(repeating: 0.5, count: 5_000)
            snap["cpu"] = cpu
            json["snapshot"] = snap
        }
        let cpu = try #require(frame.snapshot.cpu)
        #expect(cpu.efficiencyCores.isEmpty && cpu.performanceCores.count == RemoteFrame.maxCores)
        #expect(frame.host.bootTime == nil)
        // A boot time slightly in the future (clock skew, still accepted) must read as "0dk".
        let now = Date()
        let skewed = RemoteFrame(host: HostInfo(modelName: "x", chip: "y", bootTime: now.addingTimeInterval(3_600)),
                                 snapshot: SystemSnapshot(timestamp: now)).validated(now: now)
        let boot = try #require(skewed.host.bootTime)
        #expect(Formatters.uptime(since: boot, now: now) == "0dk")
    }

    @Test func manyContainersStayBelowLineCapAndAreCappedOnReceive() throws {
        var frame = RemoteFrameTests.sample
        frame.snapshot.docker?.containers = (0..<300).map {
            ContainerSnapshot(id: String(repeating: "f", count: 64) + "\($0)", name: "container-\($0)-ğüşİ🙂",
                              cpuPercent: 12.5, memory: 1 << 30)
        }
        let line = try frame.encodedLine()
        #expect(line.count < RemoteFrame.maxLineBytes / 4)
        let decoded = try RemoteFrame.decode(line: line.dropLast())
        #expect(decoded.snapshot.docker?.containers == Array(frame.snapshot.docker!.containers.prefix(DockerSampler.maxContainers)))
        #expect(decoded.snapshot.docker?.containers.first?.name == "container-0-ğüşİ🙂")
    }

    @Test func lineBufferHandlesCRLFAndByteAtATime() throws {
        let encoded = try RemoteFrameTests.sample.encodedLine()
        var buffer = LineBuffer()
        var lines: [Data] = []
        for byte in encoded + encoded { lines += try buffer.append(Data([byte])) }
        #expect(lines.count == 2)
        #expect(try lines.map { try RemoteFrame.decode(line: $0) } == [RemoteFrameTests.sample, RemoteFrameTests.sample])
        // A CR before the newline (e.g. a remote shell banner) must not crash; it is just garbage.
        #expect(throws: (any Error).self) { try RemoteFrame.decode(line: Data("{}\r".utf8)) }
    }

    @Test func lineExactlyAtCapIsAccepted() throws {
        var buffer = LineBuffer(maxLineBytes: 4)
        #expect(try buffer.append(Data("1234\n".utf8)) == [Data("1234".utf8)])
        #expect(try buffer.append(Data("1234".utf8)).isEmpty)        // unterminated, at cap: still fine
    }
}

struct RemoteHostQATests {
    @Test(arguments: ["user@", "a@-x", "host:22"])
    func acceptedButNotAUsableDestination(_ host: String) {
        // Documents current behaviour: these pass validation. "user@" has no host; the dash
        // after "@" is harmless only because RemoteMonitor puts "--" before the destination.
        #expect(RemoteMonitor.isValidHost(host))
    }

    @Test(arguments: ["mäc", "ğ", "air\t", "air\r", "air/x", "a'b", "a\"b", "a|b", "a&b", "a>b", "~x", "*"])
    func rejectsNonAsciiAndShellCharacters(_ host: String) { #expect(!RemoteMonitor.isValidHost(host)) }

    @Test func maxLengthBoundary() {
        #expect(RemoteMonitor.isValidHost(String(repeating: "a", count: 253)))
        #expect(!RemoteMonitor.isValidHost(String(repeating: "a", count: 254)))
    }
}

struct RemoteDescribeQATests {
    func d(_ s: String, _ status: Int32 = 255) -> String { RemoteMonitor.describe(status: status, stderr: Data(s.utf8)) }

    @Test func remoteBinaryNotExecutableIsNotReportedAsBadKey() {
        // zsh on the remote Mac, binary present but not executable (exit 126).
        #expect(d("zsh:1: permission denied: /Applications/SystemMetrics.app/Contents/MacOS/SystemMetrics", 126)
                != "SSH anahtarı kabul edilmedi.")
    }

    @Test func unrelatedNotFoundFromRemoteShellProfileIsNotReportedAsMissingApp() {
        // A remote ~/.zshenv printing a harmless "command not found", then the stream ending.
        #expect(!d("/Users/x/.zshenv:3: command not found: brew\nConnection to air closed by remote host.")
                .contains("SystemMetrics"))
    }

    @Test func sshPublickeyRefusalIsStillReportedAsBadKey() {
        #expect(d("mini: Permission denied (publickey,password,keyboard-interactive).") == "SSH anahtarı kabul edilmedi.")
    }

    /// Regression for systemmetrics-56/57: only status 3 *and* the marker mean "old or missing app".
    @Test func missingAppNeedsBothStatusAndMarker() {
        let missing = "Karşı Mac'te SystemMetrics yok ya da eski; aynı sürümü kurun."
        #expect(d(RemoteMonitor.missingAppMarker + "\n", RemoteMonitor.missingAppStatus) == missing)
        #expect(d("", RemoteMonitor.missingAppStatus) != missing)
        #expect(d(RemoteMonitor.missingAppMarker, 255) != missing)
        #expect(d("zsh:1: no such file or directory: /Applications/SystemMetrics.app/Contents/MacOS/SystemMetrics", 127) != missing)
    }

    @Test func hostKeyChangedIsExplained() {
        #expect(d("@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@\nHost key verification failed.")
                .hasPrefix("Karşı Mac'in SSH anahtarı"))
    }
}

/// Regression for systemmetrics-56: `RemoteMonitor.remoteCommand` run by the remote login shell
/// (zsh on macOS, sh for good measure) against a fake app in a temp dir. /Applications is never
/// touched: the app path in the command is replaced.
@MainActor
struct RemoteCommandQATests {
    static let appPath = "/Applications/SystemMetrics.app"

    struct Run { var status: Int32; var out: String; var err: String }

    /// `version` nil: no Info.plist / no app at all.
    func run(shell: String, version: String?, makeApp: Bool = true) throws -> Run {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qa-remotecmd-\(UUID().uuidString)")
        let app = dir.appendingPathComponent("SystemMetrics.app")
        defer { try? FileManager.default.removeItem(at: dir) }
        if makeApp {
            let macos = app.appendingPathComponent("Contents/MacOS")
            try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
            let exe = macos.appendingPathComponent("SystemMetrics")
            try Data("#!/bin/sh\necho \"fake-stream $*\"\n".utf8).write(to: exe)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
            if let version {
                let plist: [String: Any] = ["CFBundleVersion": version]
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
            }
        } else {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let command = RemoteMonitor.remoteCommand.replacingOccurrences(of: Self.appPath, with: app.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-c", command]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Run(status: p.terminationStatus, out: String(decoding: o, as: UTF8.self), err: String(decoding: e, as: UTF8.self))
    }

    @Test func commandNamesTheInstalledAppExactlyOnce() {
        #expect(RemoteMonitor.remoteCommand.components(separatedBy: Self.appPath).count == 2)
    }

    @Test(arguments: ["/bin/zsh", "/bin/sh"])
    func currentBuildIsExecWithStream(_ shell: String) throws {
        for v in ["2", "10"] {
            let r = try run(shell: shell, version: v)
            #expect(r.status == 0 && r.out == "fake-stream --stream\n" && r.err.isEmpty, "\(shell) v=\(v): \(r)")
        }
    }

    @Test(arguments: ["/bin/zsh", "/bin/sh"])
    func oldOrUnreadableBuildExits3WithMarker(_ shell: String) throws {
        for v: String? in ["1", "0", "", "abc", "1.9", nil] {
            let r = try run(shell: shell, version: v)
            #expect(r.status == RemoteMonitor.missingAppStatus, "\(shell) v=\(String(describing: v)): \(r)")
            #expect(r.out.isEmpty, "old build must not be started: \(r.out)")
            #expect(r.err.contains(RemoteMonitor.missingAppMarker))
            #expect(RemoteMonitor.describe(status: r.status, stderr: Data(r.err.utf8)).contains("yok ya da eski"))
        }
    }

    @Test func missingAppExits3WithMarker() throws {
        let r = try run(shell: "/bin/zsh", version: nil, makeApp: false)
        #expect(r.status == RemoteMonitor.missingAppStatus && r.out.isEmpty && r.err.contains(RemoteMonitor.missingAppMarker), "\(r)")
    }
}

/// Regression for systemmetrics-59, through the real sender: a sampler that reports NaN must
/// still produce frames.
@MainActor
struct MetricsStreamerNaNQATests {
    @Test func nanFromSamplersStillProducesFrames() async throws {
        var lines: [Data] = []
        let samplers = Samplers(cpu: { CPUSnapshot(total: .nan, perCore: [.nan, 0.5], efficiencyCoreCount: 1) },
                                memory: { MemorySnapshot(total: 10, used: 5, app: 5, wired: 0, compressed: 0, pressure: .normal) },
                                swap: { SwapSnapshot(total: 2, used: 1) },
                                gpu: { GPUSnapshot(utilization: .nan, memoryInUse: 1) },
                                volumes: { _ in [] },
                                docker: { _ in DockerSnapshot(state: .running) })
        let engine = MetricsEngine(refreshInterval: 1, samplers: samplers,
                                   hostInfo: HostInfo(modelName: "Fake", chip: "M0", bootTime: nil))
        let streamer = MetricsStreamer(engine: engine) { lines.append($0); return true }
        streamer.start()
        try await Task.sleep(for: .seconds(3.5))
        engine.stop()
        #expect(lines.count >= 2, "frames: \(lines.count)")
        let frames = try lines.map { try RemoteFrame.decode(line: $0.dropLast()) }
        #expect(frames.allSatisfy { ($0.snapshot.gpu?.utilization ?? 0).isFinite && ($0.snapshot.cpu?.total ?? 0) == 0 })
    }
}

/// Real streamer, fake samplers, real time. Counts frames per tick.
@MainActor
struct MetricsStreamerQATests {
    static func samplers(dockerDelay: Duration) -> Samplers {
        Samplers(cpu: { CPUSnapshot(total: 0.5, perCore: [0.5], efficiencyCoreCount: 0) },
                 memory: { MemorySnapshot(total: 10, used: 5, app: 5, wired: 0, compressed: 0, pressure: .normal) },
                 swap: { SwapSnapshot(total: 2, used: 1) },
                 gpu: { GPUSnapshot(utilization: 0.1, memoryInUse: 1) },
                 volumes: { _ in [] },
                 docker: { _ in try? await Task.sleep(for: dockerDelay); return DockerSnapshot(state: .running) })
    }

    func frames(dockerDelay: Duration, seconds: Double, interval: TimeInterval = 1) async throws -> [RemoteFrame] {
        var lines: [Data] = []
        let engine = MetricsEngine(refreshInterval: interval, samplers: Self.samplers(dockerDelay: dockerDelay),
                                   hostInfo: HostInfo(modelName: "Fake", chip: "M0", bootTime: nil))
        let streamer = MetricsStreamer(engine: engine) { lines.append($0); return true }
        streamer.start()
        try await Task.sleep(for: .seconds(seconds))
        engine.stop()
        return try lines.map { try RemoteFrame.decode(line: $0.dropLast()) }
    }

    // Load tolerance: both cases keep a wide margin around `coalesceDelay` (0.25 s), because
    // under full-suite load the 0.25 s coalescing sleep itself can run late. Coalescing is a
    // best-effort optimisation (fewer frames), not a correctness property, so a late timer
    // merging a slow Docker result into the tick frame is acceptable product behaviour.
    @Test func fastDockerIsCoalescedIntoTheTickFrame() async throws {
        let f = try await frames(dockerDelay: .zero, seconds: 5.5)
        let ticks = Set(f.map(\.snapshot.timestamp)).count
        // One frame per tick: no tick timestamp appears twice.
        #expect(f.count == ticks, "frames=\(f.count) distinct ticks=\(ticks)")
        #expect(f.last?.snapshot.docker?.state == .running)
    }

    @Test func slowDockerProducesASecondFrameForTheSameTick() async throws {
        // Docker landing well after coalesceDelay (1.5 s vs 0.25 s) goes out as its own frame.
        // Timeline (interval 3 s, Docker every 4 s): ticks at 0, 3, 6, 9. The ticks at 0 run
        // before the streamer observes, so the first frame is Docker's (≈1.5 s, tick-0 stamp).
        // Docker is due again at 6 and lands at ≈7.5, after the tick-6 frame went out at ≈6.25:
        // that tick's stamp appears twice. 10 s leaves 2.5 s of slack after it.
        let f = try await frames(dockerDelay: .milliseconds(1_500), seconds: 10, interval: 3)
        let ticks = Set(f.map(\.snapshot.timestamp)).count
        #expect(f.count > ticks, "frames=\(f.count) distinct ticks=\(ticks) \(f.map { ($0.snapshot.timestamp.timeIntervalSince1970, String(describing: $0.snapshot.docker?.state)) })")
    }
}

/// Real ssh. Opt-in: `TEST_RUNNER_REMOTE_QA=1 ./scripts/test.sh -only-testing:MetricsKitTests/RemoteMonitorLiveQATests`
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["REMOTE_QA"] != nil), .serialized)
struct RemoteMonitorLiveQATests {
    static let liveHost = ProcessInfo.processInfo.environment["REMOTE_QA_HOST"]

    /// Observations go to stdout and, when `REMOTE_QA_LOG` is set, to that file (xcodebuild
    /// -quiet hides test stdout).
    func note(_ items: Any...) {
        let line = items.map { "\($0)" }.joined(separator: " ")
        print(line)
        guard let path = ProcessInfo.processInfo.environment["REMOTE_QA_LOG"] else { return }
        if let h = FileHandle(forWritingAtPath: path) ?? {
            FileManager.default.createFile(atPath: path, contents: nil); return FileHandle(forWritingAtPath: path) }() {
            h.seekToEndOfFile(); h.write(Data((line + "\n").utf8)); try? h.close()
        }
    }

    /// Records every change of `monitor.state` (observation, not polling: a DNS failure goes
    /// connecting → failed in ~50 ms, which a poller misses).
    func transitions(_ monitor: RemoteMonitor, for seconds: Double) async throws -> [(Double, RemoteMonitor.State)] {
        final class Recorder { var out: [(Double, RemoteMonitor.State)] = []; var active = true }
        let start = Date(), r = Recorder()
        r.out.append((0, monitor.state))
        func arm() {
            withObservationTracking { _ = monitor.state } onChange: {
                // onChange runs before the new value is stored; read it on the next main-queue turn.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard r.active else { return }
                        if monitor.state != r.out.last!.1 { r.out.append((Date().timeIntervalSince(start), monitor.state)) }
                        arm()
                    }
                }
            }
        }
        arm()
        try await Task.sleep(for: .seconds(seconds))
        r.active = false
        return r.out
    }

    func connectStarts(_ t: [(Double, RemoteMonitor.State)]) -> [Double] { t.filter { $0.1 == .connecting }.map(\.0) }
    func failures(_ t: [(Double, RemoteMonitor.State)]) -> [Double] {
        t.filter { if case .failed = $0.1 { return true } else { return false } }.map(\.0)
    }

    @Test func unresolvableHostBacksOff2Then5Then10() async throws {
        let m = RemoteMonitor(host: "qa-no-such-host.invalid")
        m.start()
        let t = try await transitions(m, for: 22)
        m.stop()
        note("QA transitions:", t)
        let f = failures(t), c = connectStarts(t)
        #expect(f.count >= 3)
        if case .failed(let message) = t.first(where: { if case .failed = $0.1 { true } else { false } })?.1 {
            #expect(message.hasPrefix("Mac bulunamadı"))
        }
        // Gap between a failure and the next connect attempt: 2, 5, 10 s (±0.6 s).
        let gaps = zip(f, c.dropFirst()).map { $1 - $0 }
        note("QA retry gaps:", gaps)
        for (gap, expected) in zip(gaps, [2.0, 5.0, 10.0]) { #expect(abs(gap - expected) < 0.6, "gap \(gap) vs \(expected)") }
    }

    @Test func unreachableAddressFailsWithinConnectTimeout() async throws {
        let m = RemoteMonitor(host: "192.0.2.1")      // TEST-NET-1, never routed
        m.start()
        let t = try await transitions(m, for: 12)
        m.stop()
        note("QA transitions:", t)
        let f = failures(t)
        #expect(f.first.map { $0 < 10 } == true, "first failure at \(String(describing: f.first))")
    }

    @Test func stopDuringBackoffDoesNotReconnect() async throws {
        let m = RemoteMonitor(host: "qa-no-such-host.invalid")
        m.start()
        for _ in 0..<200 { if case .failed = m.state { break }; try await Task.sleep(for: .milliseconds(50)) }
        m.stop()
        let t = try await transitions(m, for: 4)
        #expect(connectStarts(t).isEmpty, "\(t)")
    }

    func openDescriptors() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1 }

    /// Regression for systemmetrics-49: neither failed attempts nor a stop() while ssh is still
    /// connecting (a host change in Settings) may leave descriptors behind.
    @Test func failedAndAbandonedAttemptsDoNotLeakDescriptors() async throws {
        let before = openDescriptors()
        for _ in 0..<40 {
            let m = RemoteMonitor(host: "qa-no-such-host.invalid")
            m.start()
            for _ in 0..<200 { if case .failed = m.state { break }; try await Task.sleep(for: .milliseconds(10)) }
            m.stop()
        }
        for _ in 0..<15 {
            let m = RemoteMonitor(host: "192.0.2.1")
            m.start()
            try await Task.sleep(for: .milliseconds(300))
            m.stop()                         // ssh still in ConnectTimeout; monitor released right away
        }
        try await Task.sleep(for: .seconds(2))
        let after = openDescriptors()
        note("QA fds before/after 55 attempts:", before, after)
        #expect(after - before <= 3, "fds \(before) -> \(after)")
    }

    @Test(.enabled(if: liveHost != nil)) func connectsRecordsHistoryOncePerIntervalAndCleansUp() async throws {
        let host = Self.liveHost!
        let before = try remoteStreamPIDs(host)
        let m = RemoteMonitor(host: host)
        m.start()
        for _ in 0..<300 where m.state != .connected { try await Task.sleep(for: .milliseconds(50)) }
        #expect(m.state == .connected)
        let mine = try remoteStreamPIDs(host).subtracting(before)
        #expect(mine.count == 1, "new remote stream processes: \(mine)")
        let startCount = m.history.cpu.count
        try await Task.sleep(for: .seconds(30))
        let recorded = m.history.cpu.count - startCount
        note("QA history points in 30 s:", recorded, "hostInfo:", String(describing: m.hostInfo))
        #expect((13...16).contains(recorded))
        #expect(m.hostInfo != nil && m.snapshot.memory != nil)
        m.stop()
        try await Task.sleep(for: .seconds(5))
        let left = try remoteStreamPIDs(host).intersection(mine)
        #expect(left.isEmpty, "remote stream still running after stop(): \(left)")
    }

    /// The remote stream stops writing (SIGSTOP): the watchdog must drop it and reconnect.
    @Test(.enabled(if: liveHost != nil)) func silentStreamIsDroppedAndReconnected() async throws {
        let host = Self.liveHost!
        let before = try remoteStreamPIDs(host)
        let m = RemoteMonitor(host: host)
        m.start()
        for _ in 0..<300 where m.state != .connected { try await Task.sleep(for: .milliseconds(50)) }
        #expect(m.state == .connected)
        let mine = try remoteStreamPIDs(host).subtracting(before)
        try #require(mine.count == 1)
        let pid = mine.first!
        _ = try ssh(host, "kill -STOP \(pid)")
        let t = try await transitions(m, for: 40)
        note("QA watchdog transitions:", t)
        let drop = t.first { $0.1 == .failed("Karşı Mac yanıt vermiyor.") }
        #expect(drop != nil)
        if let drop { #expect(drop.0 > 18 && drop.0 < 28, "dropped after \(drop.0) s") }
        #expect(t.last?.1 == .connected, "reconnected")
        m.stop()
        // The frozen process lost its reader; resumed, it must exit on its next write.
        let stillThere = try remoteStreamPIDs(host).contains(pid)
        note("QA frozen stream still present before SIGCONT:", stillThere)
        _ = try ssh(host, "kill -CONT \(pid)")
        try await Task.sleep(for: .seconds(5))
        let left = try remoteStreamPIDs(host).subtracting(before)
        #expect(left.isEmpty, "remote stream processes left behind: \(left)")
        for p in left { _ = try? ssh(host, "kill \(p)") }      // clean up our own processes only
    }

    // MARK: helpers

    func ssh(_ host: String, _ command: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-T", "-o", "BatchMode=yes", "--", host, command]
        let out = Pipe()
        p.standardOutput = out
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func remoteStreamPIDs(_ host: String) throws -> Set<Int> {
        Set(try ssh(host, "pgrep -f 'MacOS/SystemMetrics --stream$' || true")
            .split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
    }
}
