#if DEBUG
import AppKit
import SwiftUI
import MetricsKit

/// `SystemMetrics --render-panel <dir>` (Debug builds only): draws the panel with preview data
/// into PNGs, so layout can be checked without a screen (a locked Mac, a CI runner). AppKit's
/// own drawing is used instead of ImageRenderer, which cannot draw AppKit-backed controls.
@MainActor
enum PanelSnapshot {
    static func render(to directory: URL) {
        let remote = RemoteMonitor(host: "mini")
        for (name, showsRemote) in [("local", false), ("remote", true)] {
            for (scheme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let selection = PanelSelection()
                selection.showsRemote = showsRemote
                let view = PanelView(engine: .preview(), remote: remote, selection: selection, onOpenSettings: {})
                    .padding(20)
                    .background(Color(nsColor: .windowBackgroundColor))
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: appearance)
                hosting.frame.size = hosting.fittingSize
                let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = hosting
                hosting.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                let url = directory.appendingPathComponent("panel-\(name)-\(scheme).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                print(url.path)
            }
        }
    }
}
#endif
