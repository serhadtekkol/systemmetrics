import AppKit
import MetricsKit

@main
@MainActor
enum Main {
    static let delegate = AppDelegate()
    static var streamer: MetricsStreamer?

    static func main() {
        // `SystemMetrics --stream`: headless, run by another Mac over SSH (see RemoteMonitor).
        // No status item, no windows; one JSON line per snapshot on standard output.
        if CommandLine.arguments.dropFirst().contains("--stream") {
            streamer = .standardOutput(interval: 2)
            streamer?.start()
            RunLoop.main.run()
            return
        }
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "--render-panel"), i + 1 < CommandLine.arguments.count {
            _ = NSApplication.shared
            PanelSnapshot.render(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            return
        }
        #endif
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}
