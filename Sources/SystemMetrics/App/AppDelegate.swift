import AppKit
import SwiftUI
import MetricsKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var engine: MetricsEngine!
    private var settings: AppSettings!
    private var statusItem: StatusItemController!
    private var panel: PanelController!
    private var machine = HoverStateMachine()
    private var openTimer: Timer?
    private var closeTimer: Timer?
    private var settingsWindow: NSWindow?
    /// Last layout-relevant shape of the visible panel; the window is re-fitted only when it changes.
    private var panelLayout: PanelLayoutKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = AppSettings()
        engine = MetricsEngine(refreshInterval: settings.refreshInterval)
        statusItem = StatusItemController()
        let engine = engine!
        panel = PanelController(
            makeContent: { [weak self] in
                AnyView(PanelView(engine: engine, onOpenSettings: { self?.openSettings() }))
            },
            statusItemWindow: { [weak self] in self?.statusItem.buttonWindow })
        statusItem.onEvent = { [weak self] in self?.handle($0) }
        statusItem.onOpenSettings = { [weak self] in self?.openSettings() }
        statusItem.onQuit = { NSApp.terminate(nil) }
        panel.onEvent = { [weak self] in self?.handle($0) }
        observe()
        engine.start()
    }

    private func handle(_ event: HoverStateMachine.Event) {
        for effect in machine.handle(event) {
            switch effect {
            case .startOpenTimer(let delay):
                openTimer = .scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.handle(.openTimerFired) }
                }
            case .startCloseTimer(let delay):
                closeTimer = .scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.handle(.closeTimerFired) }
                }
            case .cancelTimers:
                openTimer?.invalidate(); closeTimer?.invalidate()
            case .showPanel(let pinned):
                guard let anchor = statusItem.buttonScreenFrame else {
                    // No place to show it (status item not on screen yet): tell the machine, so it
                    // does not believe a panel is open.
                    handle(.panelHidden(pointerInItem: statusItem.containsPointer))
                    continue
                }
                engine.isPanelOpen = true
                panel.show(below: anchor, pinned: pinned)
                panelLayout = PanelLayoutKey(engine.snapshot)
            case .hidePanel:
                panel.hide()
                engine.isPanelOpen = false
                panelLayout = nil
                // Ordering a window out under the pointer does not reliably deliver mouseExited;
                // re-read the pointer so the next hover starts from the truth.
                handle(.panelHidden(pointerInItem: statusItem.containsPointer))
            }
        }
    }

    /// Re-arms itself after each change. Everything `render()` reads is tracked, and each change
    /// renders exactly once.
    private func observe() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func render() {
        statusItem.update(snapshot: engine.snapshot, content: settings.menuBarContent)
        if engine.refreshInterval != settings.refreshInterval { engine.refreshInterval = settings.refreshInterval }
        guard panel.isVisible else { return }
        let layout = PanelLayoutKey(engine.snapshot)
        if layout != panelLayout, let anchor = statusItem.buttonScreenFrame {
            panelLayout = layout
            panel.reposition(below: anchor)
        }
    }

    private func openSettings() {
        panel.leaveFocusOnHide()
        handle(.dismiss)
        if settingsWindow == nil {
            let view = SettingsView(settings: settings, onQuit: { NSApp.terminate(nil) })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "SystemMetrics Ayarları"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
