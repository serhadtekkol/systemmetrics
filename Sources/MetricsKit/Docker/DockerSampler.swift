import Foundation
import os

/// Stateful Docker sampler: daemon state, per-container CPU/RAM, total disk usage and VM size.
///
/// Concurrency: blocking socket I/O runs on a private serial queue, never on the main thread
/// or the Swift cooperative pool (blocking a pool thread for up to the 2 s timeout would starve
/// other tasks). All mutable state below is touched only on `queue`, which is what makes the
/// `@unchecked Sendable` sound. Concurrent `sample` calls are serialized by the queue.
///
/// Trust: the socket is local, but anything that can bind it (or a broken daemon) controls
/// every byte we read. Responses are size-capped per endpoint, ids are validated before they
/// go into a path, arithmetic on daemon numbers saturates or clamps, and one sample has a
/// total time budget.
public final class DockerSampler: @unchecked Sendable {
    /// While Docker is down, the socket is probed at most this often (spec §5).
    public static let reprobeInterval: TimeInterval = 10
    /// `/system/df` walks every image and volume (~0.5 s with 20 containers), so it is cached.
    public static let diskUsageInterval: TimeInterval = 30
    /// VM size only changes when the user changes Docker's resources (which restarts the VM).
    public static let infoInterval: TimeInterval = 60
    /// Bounds one sample to ~30 stats requests; the panel shows at most six rows anyway.
    public static let maxContainers = 30
    /// Wall-time budget for one sample. Checked before each request, so the worst case is the
    /// budget plus one request (≤ 2 × the client timeout): ~10 s with the default 2 s timeout,
    /// instead of `maxContainers` × 4 s against a daemon that answers just before the timeout.
    /// Requests not made in time are skipped: remaining containers are left out, and cached
    /// disk usage / VM size are kept.
    public static let sampleBudget: TimeInterval = 6
    /// A CPU baseline older than this is dropped instead of used: Docker is only sampled while
    /// the panel is open, so after a closed period the delta would be the average over the
    /// whole gap, shown as the current value. Three Docker cadences (`SamplingSchedule`).
    static let maxBaselineAge: TimeInterval = 3 * SamplingSchedule.dockerInterval

    /// Response caps per endpoint. Real sizes on Docker Desktop 4.x / Engine 29 with ~20
    /// containers: ping 2 B, list ~30 KB, one stats ~5 KB, info ~6 KB, df up to a few MB.
    enum ResponseLimit {
        static let ping = 1 << 10
        static let containers = 1 << 20
        static let stats = 256 << 10
        static let diskUsage = 16 << 20
        static let info = 256 << 10
    }

    /// `.info` is not persisted by default; it shows in `log stream --level info` and in a
    /// sysdiagnose, which is what makes a fake or misbehaving socket visible after the fact.
    /// Only failure kinds are logged; container names are `.private`, socket paths (they
    /// contain the user name) and response bodies are never logged.
    private static let log = Logger(subsystem: "com.serhadtekkol.SystemMetrics", category: "docker")

    private let queue = DispatchQueue(label: "com.serhadtekkol.SystemMetrics.docker", qos: .utility)
    private let transportFactory: () -> HTTPTransport?
    private let isInstalled: () -> Bool
    private let clock: () -> TimeInterval
    private var transport: HTTPTransport?
    private var last: DockerSnapshot?
    private var lastProbe: Date?
    private var lastDiskUsage: (value: UInt64, at: Date)?
    private var lastInfo: (value: DockerInfo, at: Date)?
    /// Previous CPU counters per container id; `one-shot` stats carry no `precpu_stats`.
    private var previousCPU: [String: (sample: DockerCPUSample, at: Date)] = [:]

    /// - Parameters:
    ///   - transportFactory: Returns a transport for the current socket, or `nil` if none exists.
    ///     Called again after every failure so a socket that appears later is picked up.
    ///   - isInstalled: Consulted only when no transport can be made.
    ///   - clock: Monotonic seconds for the `sampleBudget`; injectable for tests.
    public init(transportFactory: @escaping () -> HTTPTransport? = {
                    DockerLocator.socketPath().map { UnixSocketHTTPClient(socketPath: $0, timeout: 2) } },
                isInstalled: @escaping () -> Bool = { DockerLocator.isInstalled() },
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.transportFactory = transportFactory
        self.isInstalled = isInstalled
        self.clock = clock
    }

    /// Never throws: every failure maps to `.notRunning` / `.notInstalled`. A container whose
    /// stats request fails (e.g. 404 because it stopped after the list call) is omitted
    /// without affecting the others. `cpuPercent` is `nil` on a container's first sample and
    /// after a gap longer than `maxBaselineAge`.
    public func sample(now: Date) async -> DockerSnapshot {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.sampleSync(now: now)) }
        }
    }

    /// Docker container ids are 64 lowercase hex characters; 12 is the short form. Anything
    /// else did not come from a real daemon and must not be interpolated into a request path.
    static func isValidContainerID(_ id: String) -> Bool {
        (12...64).contains(id.utf8.count)
            && id.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0) }
    }

    private func sampleSync(now: Date) -> DockerSnapshot {
        if let last, last.state != .running, let lastProbe, now.timeIntervalSince(lastProbe) < Self.reprobeInterval {
            return last
        }
        let result = probeAndSample(now: now)
        if result.state != .running {
            lastProbe = now; transport = nil; previousCPU = [:]
            // Changing the VM's CPUs/memory restarts the daemon, so a size from before is stale.
            lastInfo = nil
        }
        last = result
        return result
    }

    private func probeAndSample(now: Date) -> DockerSnapshot {
        if transport == nil { transport = transportFactory() }
        guard let transport else { return DockerSnapshot(state: isInstalled() ? .notRunning : .notInstalled) }
        let started = clock()
        func withinBudget() -> Bool { clock() - started < Self.sampleBudget }

        guard fetch(transport, "/_ping", endpoint: "ping", maxBytes: ResponseLimit.ping) != nil,
              let summaries = decode([DockerContainerSummary].self, transport, "/containers/json", endpoint: "containers",
                                     maxBytes: ResponseLimit.containers) else {
            return DockerSnapshot(state: .notRunning)
        }
        var nextCPU: [String: (sample: DockerCPUSample, at: Date)] = [:]
        var containers: [ContainerSnapshot] = []
        for summary in summaries.prefix(Self.maxContainers) {
            guard withinBudget() else {
                Self.log.info("sample budget exhausted; skipping remaining containers")
                break
            }
            guard Self.isValidContainerID(summary.id) else {
                Self.log.info("container list: invalid id for \(summary.displayName, privacy: .private); skipped")
                continue
            }
            guard let stats = decode(DockerStats.self, transport, "/containers/\(summary.id)/stats?stream=false&one-shot=true",
                                     endpoint: "stats", maxBytes: ResponseLimit.stats, container: summary.displayName)
            else { continue }
            let cpu = DockerCalculator.cpuSample(stats)
            if let cpu { nextCPU[summary.id] = (cpu, now) }
            var percent: Double?
            if let previous = previousCPU[summary.id], let cpu {
                let age = now.timeIntervalSince(previous.at)
                if age >= 0, age <= Self.maxBaselineAge {
                    percent = DockerCalculator.cpuPercent(previous: previous.sample, current: cpu)
                }
            }
            containers.append(ContainerSnapshot(id: summary.id, name: summary.displayName, cpuPercent: percent,
                                                memory: DockerCalculator.memoryUsage(stats)))
        }
        // Rebuilt each time, so containers that stopped drop their baseline.
        previousCPU = nextCPU
        // On failure (or no budget left) the previous value is kept and retried next sample;
        // `nil` only until the first success.
        if lastDiskUsage.map({ now.timeIntervalSince($0.at) >= Self.diskUsageInterval }) ?? true, withinBudget(),
           let df = decode(DockerDiskUsage.self, transport, "/system/df", endpoint: "df", maxBytes: ResponseLimit.diskUsage) {
            lastDiskUsage = (DockerCalculator.diskUsage(df), now)
        }
        if lastInfo.map({ now.timeIntervalSince($0.at) >= Self.infoInterval }) ?? true, withinBudget(),
           let info = decode(DockerInfo.self, transport, "/info", endpoint: "info", maxBytes: ResponseLimit.info) {
            lastInfo = (info, now)
        }
        return DockerSnapshot(state: .running, containers: containers.sorted { $0.memory > $1.memory },
                              diskUsage: lastDiskUsage?.value,
                              vmCPUCount: lastInfo?.value.cpuCount, vmMemoryTotal: lastInfo?.value.memoryTotal)
    }

    /// One GET that must answer 200; logs and returns `nil` otherwise.
    /// `endpoint` is a fixed label for the log, never the path (it may contain an id).
    private func fetch(_ transport: HTTPTransport, _ path: String, endpoint: String, maxBytes: Int,
                       container: String? = nil) -> HTTPResponse? {
        do {
            let r = try transport.get(path, maxBytes: maxBytes)
            guard r.status == 200 else {
                Self.logFailure(endpoint, container, "HTTP \(r.status)")
                return nil
            }
            return r
        } catch {
            Self.logFailure(endpoint, container, Self.describe(error))
            return nil
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ transport: HTTPTransport, _ path: String, endpoint: String,
                                      maxBytes: Int, container: String? = nil) -> T? {
        guard let r = fetch(transport, path, endpoint: endpoint, maxBytes: maxBytes, container: container) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: r.body)
        } catch {
            // The decoding error's description can quote parts of the body; log only the kind.
            Self.logFailure(endpoint, container, "undecodable response")
            return nil
        }
    }

    /// `reason` must be a fixed, body-free string; only the container name is private.
    private static func logFailure(_ endpoint: String, _ container: String?, _ reason: String) {
        if let container {
            log.info("\(endpoint, privacy: .public) \(container, privacy: .private): \(reason, privacy: .public)")
        } else {
            log.info("\(endpoint, privacy: .public): \(reason, privacy: .public)")
        }
    }

    /// Fixed, body-free description of a transport failure for the log.
    private static func describe(_ error: Error) -> String {
        guard let e = error as? UnixSocketError else { return "transport error" }
        switch e {
        case .timeout: return "timeout"
        case .responseTooLarge: return "response too large"
        case .malformedResponse: return "malformed response"
        case .invalidPath: return "invalid request path"
        case .socketPathTooLong: return "socket path too long"
        case .socketFailed(let n): return "socket() failed errno=\(n)"
        case .socketOptionFailed(let n): return "setsockopt failed errno=\(n)"
        case .connectFailed(let n): return "connect failed errno=\(n)"
        case .writeFailed(let n): return "write failed errno=\(n)"
        case .readFailed(let n): return "read failed errno=\(n)"
        }
    }
}
