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
    private var panelLayout: PanelShape?
    private let selection = PanelSelection()
    /// The other Mac, when one is set in Settings.
    private var remote: RemoteMonitor?
    private var remoteChange: Task<Void, Never>?
    /// Set after the first remote host is applied; later changes are debounced.
    private var remoteStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = AppSettings()
        engine = MetricsEngine(refreshInterval: settings.refreshInterval)
        statusItem = StatusItemController()
        let engine = engine!
        let selection = selection
        panel = PanelController(
            makeContent: { [weak self] in
                AnyView(PanelView(engine: engine, remote: self?.remote, selection: selection,
                                  onOpenSettings: { self?.openSettings() }))
            },
            statusItemWindow: { [weak self] in self?.statusItem.buttonWindow })
        statusItem.onEvent = { [weak self] in self?.handle($0) }
        statusItem.onOpenSettings = { [weak self] in self?.openSettings() }
        statusItem.onQuit = { NSApp.terminate(nil) }
        panel.onEvent = { [weak self] in self?.handle($0) }
        observe()
        engine.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        remote?.stop()
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
                panelLayout = currentShape()
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
        syncRemote()
        guard panel.isVisible else { return }
        let layout = currentShape()
        if layout != panelLayout, let anchor = statusItem.buttonScreenFrame {
            panelLayout = layout
            panel.reposition(below: anchor)
        }
    }

    /// Starts, replaces or stops the remote monitor to match Settings.
    private func syncRemote() {
        let host = settings.validRemoteHost
        guard host != remote?.host else { remoteChange?.cancel(); remoteChange = nil; return }
        // Typing "mini" would otherwise try "m", "mi", "min" first. Apply once the field has
        // been still for a moment; the first value at launch applies at once.
        if remote != nil || remoteStarted {
            remoteChange?.cancel()
            remoteChange = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.remoteChange = nil
                self?.applyRemote(host)
            }
            return
        }
        applyRemote(host)
    }

    private func applyRemote(_ host: String?) {
        guard host == settings.validRemoteHost, host != remote?.host else { return }
        remoteStarted = true
        remote?.stop()
        remote = host.map { RemoteMonitor(host: $0, interval: 2) }
        remote?.start()
        if remote == nil { selection.showsRemote = false }
        // The panel's content captured the old monitor; remount it with the new one.
        if panel.isVisible { panel.reloadContent() }
    }

    /// Everything that changes the panel's height: which Mac is shown, its connection state,
    /// and the layout of the snapshot on screen.
    private func currentShape() -> PanelShape {
        guard let remote, selection.showsRemote else {
            return PanelShape(hasRemote: remote != nil, showsRemote: false, remoteState: nil,
                              hasRemoteData: false, layout: PanelLayoutKey(engine.snapshot))
        }
        return PanelShape(hasRemote: true, showsRemote: true, remoteState: remote.state,
                          hasRemoteData: remote.hostInfo != nil, layout: PanelLayoutKey(remote.snapshot))
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

private struct PanelShape: Equatable {
    var hasRemote: Bool
    var showsRemote: Bool
    var remoteState: RemoteMonitor.State?
    var hasRemoteData: Bool
    var layout: PanelLayoutKey
}
