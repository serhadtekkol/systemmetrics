import Foundation
import Observation
import os

/// Headless sampler behind `SystemMetrics --stream`, the command another Mac runs over SSH.
///
/// Samples everything (as if the panel were open) and writes one `RemoteFrame` line to `output`
/// whenever the snapshot changes, coalescing changes that arrive close together (the Docker
/// sample lands a moment after the rest of a tick). Exits the process when the reader goes away:
/// a failed write means the SSH session has ended. A connection that dies without closing (the
/// other Mac sleeps, the network changes) produces no write error until TCP gives up hours
/// later, so the reader also sends a heartbeat on stdin; without one for `livenessTimeout`, or
/// on stdin EOF, the process exits. That check runs off the main thread, because a write to a
/// stalled connection blocks the main thread.
@MainActor
public final class MetricsStreamer {
    /// Changes closer together than this go out as one frame.
    static let coalesceDelay: TimeInterval = 0.25
    public static let livenessTimeout: TimeInterval = 45
    static let log = Logger(subsystem: "com.serhadtekkol.SystemMetrics", category: "stream")

    private let engine: MetricsEngine
    private let write: (Data) -> Bool
    private var pendingEmit = false

    /// `write` returns false when the reader is gone.
    public init(engine: MetricsEngine, write: @escaping (Data) -> Bool) {
        self.engine = engine
        self.write = write
    }

    /// Writes to standard output; the process exits on the first failed write.
    public static func standardOutput(interval: TimeInterval) -> MetricsStreamer {
        // A closed pipe must surface as a write error, not kill the process mid-write.
        signal(SIGPIPE, SIG_IGN)
        let streamer = MetricsStreamer(engine: MetricsEngine(refreshInterval: interval)) { data in
            do { try FileHandle.standardOutput.write(contentsOf: data); return true } catch { return false }
        }
        Liveness.onDetailRequest = { [weak streamer] wanted in
            DispatchQueue.main.async { MainActor.assumeIsolated { streamer?.setDetail(wanted) } }
        }
        // Run by hand in a terminal there is no heartbeat; only a pipe (ssh) is supervised.
        if isatty(STDIN_FILENO) == 0 { Liveness.watchStandardInput(timeout: livenessTimeout) }
        return streamer
    }

    /// Whether the reader's panel is open. Closed, only CPU and RAM are sampled (the same idle
    /// budget as the menu bar app); open, everything. A reader that never says (an older build,
    /// a terminal) gets everything.
    func setDetail(_ wanted: Bool) {
        guard engine.isPanelOpen != wanted else { return }
        engine.isPanelOpen = wanted
    }

    public func start() {
        engine.start()
        engine.isPanelOpen = true
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = engine.snapshot
        } onChange: { [weak self] in
            Task { @MainActor in self?.snapshotChanged() }
        }
    }

    private func snapshotChanged() {
        observe()
        guard !pendingEmit else { return }
        pendingEmit = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.coalesceDelay))
            self?.emit()
        }
    }

    func emit() {
        pendingEmit = false
        let frame = RemoteFrame(host: engine.hostInfo, snapshot: engine.snapshot).validated()
        let line: Data
        do { line = try frame.encodedLine() } catch {
            Self.log.error("stream: frame not encoded: \(String(describing: error), privacy: .public)")
            return
        }
        if !write(line) {
            engine.stop()
            exit(0)
        }
    }
}

/// Exits the process when stdin reaches EOF or stays silent past the timeout. Everything here
/// runs on its own queue so it still fires while the main thread is blocked in a write.
enum Liveness {
    private static let queue = DispatchQueue(label: "com.serhadtekkol.SystemMetrics.liveness")
    nonisolated(unsafe) private static var lastHeard = Date()
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?
    nonisolated(unsafe) private static var heardAnything = false
    /// Called with the reader's latest "o" (panel open) / "c" (closed) heartbeat.
    nonisolated(unsafe) static var onDetailRequest: ((Bool) -> Void)?

    static func watchStandardInput(timeout: TimeInterval) {
        // Statics initialise lazily: without this the first read would happen inside the timer
        // handler, at the deadline, and the stream would never look silent.
        queue.sync { lastHeard = Date() }
        let input = FileHandle.standardInput
        input.readabilityHandler = { handle in
            let data = handle.availableData
            // EOF before any heartbeat: a reader from before the heartbeat existed (stdin
            // /dev/null). Stop supervising and rely on write errors, as that reader expects.
            // EOF later: the session ended.
            if data.isEmpty {
                handle.readabilityHandler = nil
                queue.async {
                    if heardAnything { exit(0) }
                    timer?.cancel(); timer = nil
                }
                return
            }
            // Heartbeat lines: "o" panel open, "c" closed, empty from older readers.
            let request: Bool? = data.last(where: { $0 == UInt8(ascii: "o") || $0 == UInt8(ascii: "c") })
                .map { $0 == UInt8(ascii: "o") }
            queue.async {
                lastHeard = Date(); heardAnything = true
                if let request { onDetailRequest?(request) }
            }
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + timeout, repeating: 5, leeway: .seconds(1))
        t.setEventHandler {
            if Date().timeIntervalSince(lastHeard) > timeout { exit(0) }
        }
        t.resume()
        timer = t
    }
}

