import Foundation

/// One line of the `--stream` protocol: the sending Mac's identity and its latest snapshot,
/// encoded as a single line of JSON. Both ends run the same build, so the format is the model's
/// own `Codable` encoding; `version` lets a receiver reject a peer running an incompatible build
/// instead of showing half-decoded data.
public struct RemoteFrame: Equatable, Sendable, Codable {
    public static let currentVersion = 1
    /// Upper bound for one encoded line. A real frame is a few kilobytes (a few hundred
    /// containers stay well below this); anything larger is treated as a broken stream.
    public static let maxLineBytes = 1 << 20

    public var version: Int
    public var host: HostInfo
    public var snapshot: SystemSnapshot

    public init(version: Int = RemoteFrame.currentVersion, host: HostInfo, snapshot: SystemSnapshot) {
        self.version = version; self.host = host; self.snapshot = snapshot
    }

    /// The frame as one line of JSON, newline-terminated.
    public func encodedLine() throws -> Data {
        var data = try JSONEncoder().encode(self)
        data.append(0x0A)
        return data
    }

    public enum DecodeError: Error, Equatable { case incompatibleVersion(Int) }

    /// Decodes one line (without its newline) and bounds it with `validated()`.
    public static func decode(line: Data) throws -> RemoteFrame {
        // Version first: a newer peer may have changed the shape, and that must read as
        // "incompatible version", not as garbage.
        let probe = try JSONDecoder().decode(VersionProbe.self, from: line)
        guard probe.version == currentVersion else { throw DecodeError.incompatibleVersion(probe.version) }
        return try JSONDecoder().decode(RemoteFrame.self, from: line).validated()
    }

    private struct VersionProbe: Decodable { var version: Int }

    static let maxCores = 256
    static let maxVolumes = 64
    static let maxProcessRows = 10

    /// The frame with every value the UI relies on brought into range. The sender is another
    /// machine: its values must not be able to trap a formatter or make the panel build
    /// thousands of views. Fractions are clamped to 0...1, list lengths to what a real Mac has,
    /// and dates outside 2001...tomorrow are dropped. The sender applies it too, because
    /// JSONEncoder refuses NaN and infinity and one such value would stop every frame.
    public func validated(now: Date = Date()) -> RemoteFrame {
        func fraction(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : 0 }
        func date(_ d: Date?) -> Date? {
            guard let d, d.timeIntervalSinceReferenceDate >= 0, d <= now.addingTimeInterval(86_400) else { return nil }
            return d
        }
        var f = self
        f.host.bootTime = date(host.bootTime)
        f.snapshot.timestamp = date(snapshot.timestamp) ?? now
        if var cpu = f.snapshot.cpu {
            cpu.total = fraction(cpu.total)
            cpu.perCore = cpu.perCore.prefix(Self.maxCores).map(fraction)
            cpu.efficiencyCoreCount = min(max(0, cpu.efficiencyCoreCount), cpu.perCore.count)
            f.snapshot.cpu = cpu
        }
        if var gpu = f.snapshot.gpu {
            gpu.utilization = fraction(gpu.utilization)
            f.snapshot.gpu = gpu
        }
        func rate(_ v: Double?) -> Double? { v.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
        f.snapshot.volumes = snapshot.volumes.prefix(Self.maxVolumes).map { v in
            var v = v
            v.readBytesPerSecond = rate(v.readBytesPerSecond)
            v.writeBytesPerSecond = rate(v.writeBytesPerSecond)
            return v
        }
        if var processes = f.snapshot.processes {
            func bound(_ rows: [ProcessUsage]) -> [ProcessUsage] {
                rows.prefix(Self.maxProcessRows).map { row in
                    var row = row
                    row.cpu = row.cpu.flatMap { $0.isFinite ? min(max($0, 0), Double(Self.maxCores)) : nil }
                    row.processCount = min(max(0, row.processCount), 100_000)
                    return row
                }
            }
            processes.topCPU = bound(processes.topCPU)
            processes.topMemory = bound(processes.topMemory)
            processes.unreadableCount = min(max(0, processes.unreadableCount), 100_000)
            f.snapshot.processes = processes
        }
        if var docker = f.snapshot.docker {
            docker.containers = Array(docker.containers.prefix(DockerSampler.maxContainers))
            docker.containers = docker.containers.map { c in
                var c = c
                c.cpuPercent = c.cpuPercent.flatMap { $0.isFinite ? min(max($0, 0), 100_000) : nil }
                return c
            }
            if let n = docker.vmCPUCount { docker.vmCPUCount = min(max(0, n), 4_096) }
            f.snapshot.docker = docker
        }
        return f
    }
}

/// Splits a byte stream into newline-terminated lines, with a cap on how much an unterminated
/// line may buffer.
public struct LineBuffer: Sendable {
    public let maxLineBytes: Int
    private var pending = Data()
    public init(maxLineBytes: Int = RemoteFrame.maxLineBytes) { self.maxLineBytes = maxLineBytes }

    public enum Overflow: Error, Equatable { case lineTooLong }

    /// Appends `chunk` and returns the complete lines it finished, without their newlines.
    /// Empty lines are dropped. Throws when the unfinished remainder grows past `maxLineBytes`;
    /// the buffer is then empty and the caller should drop the connection.
    public mutating func append(_ chunk: Data) throws -> [Data] {
        pending.append(chunk)
        var lines: [Data] = []
        var start = pending.startIndex
        // One scan, one copy of the remainder at the end (not one per line).
        while let newline = pending[start...].firstIndex(of: 0x0A) {
            let line = pending[start..<newline]
            if !line.isEmpty {
                guard line.count <= maxLineBytes else { pending = Data(); throw Overflow.lineTooLong }
                lines.append(Data(line))
            }
            start = pending.index(after: newline)
        }
        pending = Data(pending[start...])
        if pending.count > maxLineBytes { pending = Data(); throw Overflow.lineTooLong }
        return lines
    }
}
