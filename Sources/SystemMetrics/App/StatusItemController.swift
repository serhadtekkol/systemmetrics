import AppKit
import MetricsKit

/// Owns the `NSStatusItem`, forwards hover/click events, renders the label and shows the
/// right-click (or Control-click) menu with Settings and Quit.
///
/// An `NSResponder` subclass so the tracking area can deliver `mouseEntered:` / `mouseExited:`
/// to it directly.
@MainActor
final class StatusItemController: NSResponder {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var onEvent: ((HoverStateMachine.Event) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    private var lastTitle: String?

    override init() {
        super.init()
        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "SystemMetrics")
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.addTrackingArea(NSTrackingArea(rect: .zero,
                                              options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                              owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            onEvent?(.clicked)
        }
    }

    private func showMenu() {
        onEvent?(.dismiss)
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Ayarlar…", action: #selector(openSettings), keyEquivalent: ",")
        let quit = NSMenuItem(title: "SystemMetrics'ten Çık", action: #selector(quit), keyEquivalent: "q")
        for menuItem in [settings, quit] { menuItem.target = self }
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(quit)
        // Assigning the menu for one click gives the native placement and highlight; leaving it set
        // would turn every left click into a menu too.
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func openSettings() { onOpenSettings?() }
    @objc private func quit() { onQuit?() }
    override func mouseEntered(with event: NSEvent) { onEvent?(.itemEntered) }
    override func mouseExited(with event: NSEvent) { onEvent?(.itemExited) }

    /// The status bar window the button lives in.
    var buttonWindow: NSWindow? { item.button?.window }

    /// Whether the pointer is over the button right now (read after the panel hides, because
    /// tracking-area events are not guaranteed around window ordering).
    var containsPointer: Bool { buttonScreenFrame?.contains(NSEvent.mouseLocation) ?? false }

    /// Screen rect of the button, used to position the panel.
    var buttonScreenFrame: NSRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    func update(snapshot: SystemSnapshot, content: MenuBarContent) {
        guard let button = item.button else { return }
        let cpu = snapshot.cpu.map { "CPU \(Self.stableWidth(Formatters.percent($0.total)))" } ?? "CPU —"
        let ram = snapshot.memory.map { "RAM \(Self.stableWidth(Formatters.percent($0.usedFraction)))" } ?? "RAM —"
        let text: String = switch content {
        case .cpuAndMemory: "\(cpu)  \(ram)"
        case .cpuOnly: cpu
        case .memoryOnly: ram
        case .iconOnly: ""
        }
        // Called on every tick; touching the button only when the text changes avoids a relayout
        // of the status item (and of the menu bar) every couple of seconds.
        guard text != lastTitle else { return }
        lastTitle = text
        button.attributedTitle = NSAttributedString(string: text.isEmpty ? "" : " " + text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small) + 1, weight: .medium)
        ])
        button.setAccessibilityLabel(text.isEmpty ? "SystemMetrics" : text)
    }

    /// Pads single-digit percentages with a figure space (same advance as a digit), so the
    /// item keeps its width between "9%" and "23%" and the menu bar does not shift.
    static func stableWidth(_ percent: String) -> String {
        percent.count < 3 ? "\u{2007}" + percent : percent
    }
}
