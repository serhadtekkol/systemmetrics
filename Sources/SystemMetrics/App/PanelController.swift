import AppKit
import SwiftUI
import MetricsKit

final class MetricsPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
}

/// Container that reports pointer enter/exit for the whole panel.
final class TrackingContainerView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

/// Owns the borderless panel: placement, showing/hiding, and everything that dismisses it.
///
/// Dismissal, in both hover and pinned mode, reported to the state machine as `.dismiss`:
/// - a mouse-down anywhere outside the panel — in another app (global monitor) or in one of our
///   own windows other than the panel and the status item (local monitor);
/// - Esc, through a local key monitor, so it works whatever view is first responder;
/// - the app resigning active while pinned (Cmd-Tab, Mission Control, a notification click);
/// - a change of the active Space. The panel joins all Spaces so it opens on whichever Space the
///   menu bar is on; it must not then follow the user to the next one.
///
/// Focus: pinning activates the app so the panel can take keys. When the user dismisses it from
/// inside (Esc, clicking the item again) the app that was frontmost before is re-activated. When the
/// dismissal came from the user going somewhere else (outside click, app switch, Space change, a
/// Settings window) focus already belongs there and is left alone.
///
/// Idle cost: the SwiftUI content is mounted only while the panel is visible. A hidden panel holds
/// an empty root view, so engine ticks do not invalidate or lay out anything in it.
@MainActor
final class PanelController {
    static let width: CGFloat = 360
    /// Gap between the bottom of the menu bar item and the top of the panel.
    private static let anchorGap: CGFloat = 6
    /// Minimum distance from the visible screen edges.
    private static let screenInset: CGFloat = 8
    private static let escapeKeyCode: UInt16 = 53

    private let panel: MetricsPanel
    private let hosting: NSHostingView<AnyView>
    private let container = TrackingContainerView()
    private let makeContent: () -> AnyView
    /// The status item's window: clicks there are the item's own business (toggle / menu).
    private let statusItemWindow: () -> NSWindow?
    private var monitors: [Any] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var previousApp: NSRunningApplication?
    private var restoresFocusOnHide = true
    var onEvent: ((HoverStateMachine.Event) -> Void)?

    init(makeContent: @escaping () -> AnyView, statusItemWindow: @escaping () -> NSWindow?) {
        self.makeContent = makeContent
        self.statusItemWindow = statusItemWindow
        panel = MetricsPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false      // hover mode shows it while another app is active
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .utilityWindow

        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        // The controller sizes the window explicitly; letting SwiftUI drive window min/max size
        // would stop the panel from shrinking below its content on short screens. The intrinsic
        // size is still needed: `fittingSize` is what the window is sized from, and without it the
        // panel opens at 0×0. Low priorities let the window cut the content on short screens.
        hosting.sizingOptions = [.intrinsicContentSize]
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            hosting.setContentCompressionResistancePriority(.defaultLow, for: axis)
            hosting.setContentHuggingPriority(.defaultLow, for: axis)
        }
        hosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.contentView = container
        container.onEnter = { [weak self] in self?.onEvent?(.panelEntered) }
        container.onExit = { [weak self] in self?.onEvent?(.panelExited) }
    }

    var isVisible: Bool { panel.isVisible }
    private var isPinned: Bool { panel.allowsKey }

    /// Shows the panel, or switches an already visible hover panel to pinned.
    func show(below anchor: NSRect, pinned: Bool) {
        if !panel.isVisible {
            hosting.rootView = makeContent()
            restoresFocusOnHide = true
            installDismissTriggers()
        }
        reposition(below: anchor)
        if pinned {
            if !isPinned {
                let front = NSWorkspace.shared.frontmostApplication
                previousApp = front?.processIdentifier == NSRunningApplication.current.processIdentifier ? nil : front
            }
            panel.allowsKey = true
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    /// Re-fit to SwiftUI content and keep the top edge just under the menu bar item. The height
    /// cap comes from the screen the item is on — the one place the panel's maximum is decided.
    func reposition(below anchor: NSRect) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let size = NSSize(width: Self.width, height: min(hosting.fittingSize.height, visible.height - 12))
        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + Self.screenInset), visible.maxX - size.width - Self.screenInset)
        let y = anchor.minY - Self.anchorGap - size.height
        let frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
        // The shadow follows the rounded, transparent content; recompute it when the size changes.
        panel.invalidateShadow()
    }

    /// Keeps the frontmost app where it is on the next hide (the user is going to a window of ours,
    /// e.g. Settings).
    func leaveFocusOnHide() { restoresFocusOnHide = false }

    func hide() {
        removeDismissTriggers()
        let wasPinned = isPinned
        panel.allowsKey = false
        panel.orderOut(nil)
        hosting.rootView = AnyView(EmptyView())
        if wasPinned, restoresFocusOnHide, NSApp.isActive, let previousApp, !previousApp.isTerminated {
            previousApp.activate(from: .current, options: [])
        }
        previousApp = nil
    }

    // MARK: Dismiss triggers (installed only while visible)

    private func installDismissTriggers() {
        guard monitors.isEmpty else { return }
        let mouseDown: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(restoringFocus: false) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mouseDown, handler: { [weak self] event in
            let window = event.window
            MainActor.assumeIsolated {
                guard let self, window !== self.panel, window !== self.statusItemWindow() else { return }
                self.dismiss(restoringFocus: false)
            }
            return event
        }) { monitors.append(local) }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == Self.escapeKeyCode else { return event }
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.panel.isVisible else { return false }
                self.dismiss(restoringFocus: true)
                return true
            }
            return consumed ? nil : event
        }) { monitors.append(keys) }

        let app = NotificationCenter.default
        observers.append((app, app.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.isPinned == true { self?.dismiss(restoringFocus: false) } }
        }))
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(restoringFocus: false) }
        }))
    }

    private func removeDismissTriggers() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        observers.forEach { center, token in center.removeObserver(token) }
        observers = []
    }

    private func dismiss(restoringFocus: Bool) {
        if !restoringFocus { restoresFocusOnHide = false }
        onEvent?(.dismiss)
    }
}
