import Foundation
import Testing
@testable import MetricsKit

struct RemoteFrameTests {
    static let sample = RemoteFrame(
        host: HostInfo(modelName: "MacBook Air", chip: "Apple M2", bootTime: Date(timeIntervalSince1970: 1_700_000_000)),
        snapshot: SystemSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_700_000_100),
            cpu: CPUSnapshot(total: 0.25, perCore: [0.1, 0.4], efficiencyCoreCount: 1),
            memory: MemorySnapshot(total: 16 << 30, used: 9 << 30, app: 6 << 30, wired: 2 << 30,
                                   compressed: 1 << 30, pressure: .warning),
            swap: SwapSnapshot(total: 2 << 30, used: 1 << 30),
            gpu: GPUSnapshot(utilization: 0.1, memoryInUse: 300 << 20),
            volumes: [VolumeSnapshot(id: "/", name: "Macintosh HD", isInternal: true, isRoot: true,
                                     total: 500_000_000_000, available: 100_000_000_000,
                                     readBytesPerSecond: 1_000, writeBytesPerSecond: nil, deviceID: "disk3")],
            docker: DockerSnapshot(state: .running,
                                   containers: [ContainerSnapshot(id: "a", name: "db", cpuPercent: nil, memory: 10)],
                                   diskUsage: 5, vmCPUCount: 4, vmMemoryTotal: 8 << 30)))

    @Test func roundTripsThroughOneLine() throws {
        let line = try Self.sample.encodedLine()
        #expect(line.last == 0x0A)
        #expect(line.dropLast().firstIndex(of: 0x0A) == nil)
        let decoded = try RemoteFrame.decode(line: line.dropLast())
        #expect(decoded == Self.sample)
    }

    @Test func rejectsOtherVersions() throws {
        var frame = Self.sample
        frame.version = RemoteFrame.currentVersion + 1
        let line = try frame.encodedLine().dropLast()
        #expect(throws: RemoteFrame.DecodeError.incompatibleVersion(RemoteFrame.currentVersion + 1)) {
            try RemoteFrame.decode(line: Data(line))
        }
    }

    @Test func rejectsGarbage() {
        #expect(throws: (any Error).self) { try RemoteFrame.decode(line: Data("not json".utf8)) }
    }
}

struct LineBufferTests {
    @Test func splitsLinesAcrossChunks() throws {
        var buffer = LineBuffer(maxLineBytes: 100)
        #expect(try buffer.append(Data("ab".utf8)).isEmpty)
        let lines = try buffer.append(Data("c\n\nde\nf".utf8))
        #expect(lines == [Data("abc".utf8), Data("de".utf8)])
        #expect(try buffer.append(Data("\n".utf8)) == [Data("f".utf8)])
    }

    @Test func capsAnUnterminatedLine() throws {
        var buffer = LineBuffer(maxLineBytes: 4)
        #expect(throws: LineBuffer.Overflow.lineTooLong) { try buffer.append(Data("12345".utf8)) }
        // The buffer starts over after an overflow.
        #expect(try buffer.append(Data("ok\n".utf8)) == [Data("ok".utf8)])
    }

    @Test func capsATerminatedLongLine() {
        var buffer = LineBuffer(maxLineBytes: 4)
        #expect(throws: LineBuffer.Overflow.lineTooLong) { try buffer.append(Data("12345\n".utf8)) }
    }
}

struct RemoteHostValidationTests {
    @Test(arguments: ["mini", "air", "Serhad-Mac-mini.local", "user@host", "192.168.1.10", "fe80::1%en0", "a_b"])
    func acceptsDestinations(_ host: String) { #expect(RemoteMonitor.isValidHost(host)) }

    @Test(arguments: ["", "-oProxyCommand=x", " mini", "mini air", "a;b", "a$(b)", "a@b@c", "`x`", "a\nb",
                      String(repeating: "a", count: 254)])
    func rejectsUnsafeOrMalformed(_ host: String) { #expect(!RemoteMonitor.isValidHost(host)) }

    @Test func explainsCommonSSHFailures() {
        func d(_ s: String, _ status: Int32 = 255) -> String { RemoteMonitor.describe(status: status, stderr: Data(s.utf8)) }
        #expect(d("user@x: Permission denied (publickey).") == "SSH anahtarı kabul edilmedi.")
        #expect(d("Host key verification failed.").hasPrefix("Karşı Mac'in SSH anahtarı"))
        #expect(d("ssh: Could not resolve hostname x: nodename nor servname provided").hasPrefix("Mac bulunamadı"))
        #expect(d("ssh: connect to host x port 22: Operation timed out") == "Mac'e ulaşılamıyor.")
        #expect(d("systemmetrics-stream-unavailable", 3).hasPrefix("Karşı Mac'te SystemMetrics yok ya da eski"))
        #expect(d("zsh:1: permission denied: /x/SystemMetrics", 126) == "Bağlantı kesildi.")
        #expect(d("", 0) == "Bağlantı kesildi.")
    }
}

/// Hostile or broken frames from the other Mac must not trap or blow up the panel.
struct RemoteFrameValidationTests {
    static func decode(_ mutate: (inout [String: Any]) -> Void) throws -> RemoteFrame {
        let line = try RemoteFrameTests.sample.encodedLine().dropLast()
        var json = try JSONSerialization.jsonObject(with: line) as! [String: Any]
        mutate(&json)
        return try RemoteFrame.decode(line: JSONSerialization.data(withJSONObject: json))
    }

    @Test func negativeEfficiencyCoreCountIsClamped() throws {
        let frame = try Self.decode { json in
            var snap = json["snapshot"] as! [String: Any]
            var cpu = snap["cpu"] as! [String: Any]
            cpu["efficiencyCoreCount"] = -1
            snap["cpu"] = cpu; json["snapshot"] = snap
        }
        let cpu = try #require(frame.snapshot.cpu)
        #expect(cpu.efficiencyCoreCount == 0)
        #expect(cpu.efficiencyCores.isEmpty)
        #expect(cpu.performanceCores.count == cpu.perCore.count)
    }

    @Test func absurdDatesAreDropped() throws {
        let frame = try Self.decode { json in
            var host = json["host"] as! [String: Any]
            host["bootTime"] = -1e300
            json["host"] = host
            var snap = json["snapshot"] as! [String: Any]
            snap["timestamp"] = 1e300
            json["snapshot"] = snap
        }
        #expect(frame.host.bootTime == nil)
        #expect(abs(frame.snapshot.timestamp.timeIntervalSinceNow) < 60)
    }

    @Test func hugeListsAndFractionsAreBounded() throws {
        let frame = try Self.decode { json in
            var snap = json["snapshot"] as! [String: Any]
            var cpu = snap["cpu"] as! [String: Any]
            cpu["perCore"] = Array(repeating: 7.0, count: 10_000)
            cpu["total"] = -3.0
            cpu["efficiencyCoreCount"] = 100_000
            snap["cpu"] = cpu
            let volume = (snap["volumes"] as! [[String: Any]])[0]
            snap["volumes"] = Array(repeating: volume, count: 1_000)
            json["snapshot"] = snap
        }
        let cpu = try #require(frame.snapshot.cpu)
        #expect(cpu.perCore.count == RemoteFrame.maxCores)
        #expect(cpu.perCore.allSatisfy { $0 == 1 })
        #expect(cpu.total == 0)
        #expect(cpu.efficiencyCoreCount == RemoteFrame.maxCores)
        #expect(frame.snapshot.volumes.count == RemoteFrame.maxVolumes)
    }

    @Test func uptimeDoesNotTrapOnExtremeBootTimes() {
        let now = Date()
        _ = Formatters.uptime(since: Date(timeIntervalSince1970: -1e300), now: now)
        #expect(Formatters.uptime(since: Date(timeIntervalSince1970: 1e300), now: now) == "0dk")
    }

    @Test func coreSplitToleratesNegativeCount() {
        let cpu = CPUSnapshot(total: 0, perCore: [0.1, 0.2], efficiencyCoreCount: -5)
        #expect(cpu.efficiencyCores.isEmpty)
        #expect(cpu.performanceCores.count == 2)
    }
}
