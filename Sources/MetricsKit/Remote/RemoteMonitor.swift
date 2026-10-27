import Foundation
import Observation
import os

/// Shows another Mac's metrics by running `SystemMetrics --stream` there over SSH.
///
/// Uses the user's own `ssh` setup (`~/.ssh/config`, keys, agent, known_hosts) in batch mode:
/// no password prompt, no new listening port on either Mac, and an unknown host key fails
/// instead of being accepted. The connection is kept open while the monitor runs and re-opened
/// with a growing delay after it drops.
@MainActor
@Observable
public final class RemoteMonitor {
    public enum State: Equatable, Sendable {
        case connecting
        case connected
        /// Not connected; `message` is shown in the panel. Another attempt follows on its own.
        case failed(String)
    }

    /// Run by the remote login shell. A build from before `--stream` existed would ignore the
    /// flag and start a second, invisible menu bar app on each attempt, so the build number is
    /// checked first (first build with `--stream`: 2); a missing or older app exits with
    /// `missingAppStatus` and a marker on stderr instead.
    public static let remoteCommand =
        #"app=/Applications/SystemMetrics.app; "# +
        #"v=$(/usr/bin/plutil -extract CFBundleVersion raw "$app/Contents/Info.plist" 2>/dev/null); "# +
        #"if [ "${v:-0}" -ge 2 ] 2>/dev/null; then exec "$app/Contents/MacOS/SystemMetrics" --stream; fi; "# +
        "echo \(missingAppMarker) >&2; exit \(missingAppStatus)"
    nonisolated static let missingAppStatus: Int32 = 3
    nonisolated static let missingAppMarker = "systemmetrics-stream-unavailable"
    /// No data for this long while connected means the stream is stuck; it is dropped and re-opened.
    static let staleAfter: TimeInterval = 20
    static let retryDelays: [TimeInterval] = [2, 5, 10, 30, 60]
    /// The retry delay resets only after a connection has delivered frames for this long.
    static let stableAfter: TimeInterval = 30
    /// Frames are applied (and the panel redrawn) at most this often.
    static let minApplyGap: TimeInterval = 0.5
    /// How often a heartbeat goes to the remote side; it gives up after `MetricsStreamer.livenessTimeout`.
    static let heartbeatInterval: TimeInterval = 5
    nonisolated static let log = Logger(subsystem: "com.serhadtekkol.SystemMetrics", category: "remote")

    public let host: String
    public private(set) var state: State = .connecting
    public private(set) var snapshot: SystemSnapshot = .empty
    public private(set) var hostInfo: HostInfo?
    public private(set) var history: History
    /// Set while the panel is open: the remote side then samples everything (GPU, disks,
    /// processes, Docker); otherwise only CPU and RAM, to keep its idle cost low.
    @ObservationIgnored public var wantsDetail = false {
        didSet { if wantsDetail != oldValue { sendHeartbeat() } }
    }

    @ObservationIgnored private let interval: TimeInterval
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var buffer = LineBuffer()
    @ObservationIgnored private var stderrTail = Data()
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Timer?
    @ObservationIgnored private var lastFrame: Date?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var connectedSince: Date?
    @ObservationIgnored private var pendingFrame: RemoteFrame?
    @ObservationIgnored private var applyScheduled = false
    @ObservationIgnored private var lastApplied: Date?

    /// `host` must already be valid (`isValidHost`); it is passed to ssh as the destination.
    public init(host: String, interval: TimeInterval = 2) {
        precondition(Self.isValidHost(host))
        // Writing the heartbeat to a pipe whose reader (ssh) just exited must fail with EPIPE,
        // not kill the app.
        signal(SIGPIPE, SIG_IGN)
        self.host = host
        self.interval = interval
        history = History(capacity: History.capacity(forInterval: interval))
    }

    /// An ssh destination we accept: a `Host` alias, hostname, IP or `user@host`. Anything else
    /// (spaces, a leading dash that ssh would read as an option, shell characters) is rejected.
    public nonisolated static func isValidHost(_ host: String) -> Bool {
        guard (1...253).contains(host.utf8.count), let first = host.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_@:%")
        return host.unicodeScalars.allSatisfy(allowed.contains) && host.filter { $0 == "@" }.count <= 1
    }

    public func start() {
        guard !running else { return }
        running = true
        connect()
    }

    public func stop() {
        running = false
        retryTask?.cancel(); retryTask = nil
        watchdog?.invalidate(); watchdog = nil
        terminateProcess()
    }

    // MARK: Connection

    private func connect() {
        guard running else { return }
        state = .connecting
        buffer = LineBuffer()
        stderrTail = Data()
        lastFrame = nil
        connectedSince = nil
        pendingFrame = nil

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = [
            "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2",
            "-o", "StrictHostKeyChecking=yes",
            // Command-line options win over ~/.ssh/config: this long-lived session must not
            // carry the agent, X11 or port forwards to the other Mac, and must own its own
            // connection (a shared ControlMaster would outlive `terminate()`).
            "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "ClearAllForwardings=yes",
            "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "PermitLocalCommand=no",
            "--", host, Self.remoteCommand,
        ]
        // stdin carries the heartbeat (see MetricsStreamer): the remote side exits when it stops.
        let input = Pipe(), out = Pipe(), err = Pipe()
        p.standardInput = input
        p.standardOutput = out
        p.standardError = err
        // Main queue, not one Task per chunk: dispatch keeps the chunks in order.
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            // EOF: an empty read repeats forever unless the handler is removed.
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(chunk, from: p) } }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receivedError(chunk, from: p) } }
        }
        p.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.terminated(p, status: status) } }
        }
        do {
            try p.run()
            process = p
            sendHeartbeat()
            startWatchdog()
        } catch {
            Self.closePipes(of: p)
            fail("ssh başlatılamadı: \(error.localizedDescription)")
        }
    }

    private func received(_ chunk: Data, from p: Process) {
        guard p === process, !chunk.isEmpty else { return }
        do {
            // Only the newest complete line matters; older ones in the same chunk are stale.
            guard let line = try buffer.append(chunk).last else { return }
            let frame = try RemoteFrame.decode(line: line)
            pendingFrame = frame
            scheduleApply()
        } catch RemoteFrame.DecodeError.incompatibleVersion {
            drop("Karşı Mac'teki SystemMetrics sürümü bununla uyumlu değil.")
        } catch {
            drop("Karşı Mac'ten anlaşılmayan veri geldi.")
        }
    }

    /// Applies the newest frame at most every `minApplyGap`, however fast the other side sends.
    private func scheduleApply() {
        guard !applyScheduled else { return }
        let wait = lastApplied.map { Self.minApplyGap - Date().timeIntervalSince($0) } ?? 0
        guard wait > 0 else { applyPending(); return }
        applyScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                self?.applyScheduled = false
                self?.applyPending()
            }
        }
    }

    private func applyPending() {
        guard let frame = pendingFrame, process != nil else { return }
        pendingFrame = nil
        let now = Date()
        lastApplied = now
        // History holds one point per interval (~5 minutes in total); frames can arrive more
        // often (Docker lands a moment after the rest of a tick).
        if lastFrame.map({ now.timeIntervalSince($0) >= interval / 2 }) ?? true { history.record(frame.snapshot) }
        lastFrame = now
        snapshot = frame.snapshot
        hostInfo = frame.host
        state = .connected
        // Back off from scratch only after the link has held for a while; a peer that sends
        // one good frame and then garbage would otherwise be retried every 2 s.
        if connectedSince == nil { connectedSince = now }
        if let since = connectedSince, now.timeIntervalSince(since) >= Self.stableAfter { attempt = 0 }
    }

    private func receivedError(_ chunk: Data, from p: Process) {
        guard p === process else { return }
        stderrTail.append(chunk)
        if stderrTail.count > 4096 { stderrTail = stderrTail.suffix(4096) }
    }

    private func terminated(_ p: Process, status: Int32) {
        Self.closePipes(of: p)
        guard p === process else { return }
        process = nil
        guard running else { return }
        fail(Self.describe(status: status, stderr: stderrTail))
    }

    /// Ends the current connection because of `message`; a retry follows.
    private func drop(_ message: String) {
        terminateProcess()
        fail(message)
    }

    private func fail(_ message: String) {
        let detail = String(decoding: stderrTail.suffix(512), as: UTF8.self)
        // stderr is text from the other machine (banners, MOTD): keep it out of the public log.
        Self.log.error("remote \(self.host, privacy: .public): \(message, privacy: .public) \(detail, privacy: .private)")
        watchdog?.invalidate(); watchdog = nil
        state = .failed(message)
        guard running else { return }
        let delay = Self.retryDelays[min(attempt, Self.retryDelays.count - 1)]
        attempt += 1
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func terminateProcess() {
        guard let p = process else { return }
        process = nil
        if p.isRunning { p.terminate() }
        // The termination handler closes the pipes once ssh has exited; close the read ends
        // now too so a stuck child cannot keep them (and their descriptors) alive.
        (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (p.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
    }

    /// Releases all three pipes' descriptors. Without this every attempt leaks two (the read
    /// ends stay open while a FileHandle with a handler references them).
    nonisolated private static func closePipes(of p: Process) {
        for case let pipe as Pipe in [p.standardInput, p.standardOutput, p.standardError] {
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
    }

    /// "o\n" (panel open) or "c\n" (closed). Also proves to the remote side that we are alive.
    /// Fails harmlessly (EPIPE, SIGPIPE ignored) when ssh has just exited; the termination
    /// handler deals with that.
    private func sendHeartbeat(to p: Process? = nil) {
        guard let p = p ?? process else { return }
        let line = Data((wantsDetail ? "o\n" : "c\n").utf8)
        try? (p.standardInput as? Pipe)?.fileHandleForWriting.write(contentsOf: line)
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        let started = Date()
        let t = Timer(timeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let p = self.process else { return }
                let since = Date().timeIntervalSince(self.lastFrame ?? started)
                if since > Self.staleAfter { self.drop("Karşı Mac yanıt vermiyor."); return }
                self.sendHeartbeat(to: p)
            }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    /// A short Turkish explanation of why ssh ended, from its exit status and last stderr lines.
    nonisolated static func describe(status: Int32, stderr: Data) -> String {
        let text = String(decoding: stderr, as: UTF8.self).lowercased()
        if status == missingAppStatus && text.contains(missingAppMarker) {
            return "Karşı Mac'te SystemMetrics yok ya da eski; aynı sürümü kurun."
        }
        // ssh's own wording; a remote shell's "permission denied: <file>" is something else.
        if text.contains("permission denied (") { return "SSH anahtarı kabul edilmedi." }
        if text.contains("host key verification failed") || text.contains("no matching host key") {
            return "Karşı Mac'in SSH anahtarı tanınmıyor. Önce Terminal'den bir kez bağlanın."
        }
        if text.contains("could not resolve") { return "Mac bulunamadı (ad çözülemedi)." }
        if text.contains("timed out") || text.contains("no route") || text.contains("connection refused")
            || text.contains("network is unreachable") || text.contains("host is down") {
            // macOS's Local Network privacy check drops the connection the same way an
            // unreachable host does; the permission is the cause users can fix themselves.
            return "Mac'e ulaşılamıyor. Açıksa, Sistem Ayarları > Gizlilik ve Güvenlik > Yerel Ağ'da SystemMetrics'e izin verin."
        }
        return "Bağlantı kesildi."
    }
}
