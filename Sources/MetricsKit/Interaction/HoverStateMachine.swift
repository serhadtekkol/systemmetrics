/// Pure hover/click/Esc logic for the menu bar item and its panel.
///
/// The AppKit layer feeds pointer and timer events in and executes the returned effects;
/// timers are owned by the caller, so a timer that fires after its state was left is simply ignored.
///
/// Pointer flags (`inItem`, `inPanel`) are only as good as the enter/exit events behind them, and
/// AppKit does not promise a `mouseExited` when a window is ordered out under the pointer. The
/// caller therefore reports every hide with `.panelHidden(pointerInItem:)`, which resets both flags
/// from a fresh pointer reading.
public struct HoverStateMachine: Sendable {
    public enum State: Equatable, Sendable { case closed, opening, open, closing, pinned }
    public enum Event: Equatable, Sendable {
        case itemEntered, itemExited, panelEntered, panelExited, openTimerFired, closeTimerFired, clicked
        /// Esc, a mouse-down outside the panel (in any app), app deactivation or a Space change.
        case dismiss
        /// The panel is no longer on screen, for whatever reason (including a show that could not
        /// happen). `pointerInItem` is the pointer's current position, read by the caller.
        case panelHidden(pointerInItem: Bool)
    }
    public enum Effect: Equatable, Sendable {
        case startOpenTimer(Double), startCloseTimer(Double), cancelTimers, showPanel(pinned: Bool), hidePanel
    }
    /// NN/g guidance for hover-revealed content: ~0.3 s before showing (so passing the pointer over
    /// the menu bar does not flash the panel) and ~0.5 s grace before hiding.
    public static let openDelay = 0.3
    public static let closeDelay = 0.5

    public private(set) var state: State = .closed
    private var inItem = false, inPanel = false
    public init() {}

    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .itemEntered: inItem = true
        case .itemExited: inItem = false
        case .panelEntered: inPanel = true
        case .panelExited: inPanel = false
        case .panelHidden(let pointerInItem):
            inItem = pointerInItem
            inPanel = false
            guard state != .closed else { return [] }
            state = .closed; return [.cancelTimers]
        default: break
        }
        switch (state, event) {
        case (.closed, .dismiss):
            return []
        case (.pinned, .clicked), (_, .dismiss):
            state = .closed; return [.cancelTimers, .hidePanel]
        case (.pinned, _):
            return []
        // Deliberate: a click on the item while the hover panel is showing pins it instead of
        // closing it. The pointer is already on the item, so the user just watched it open; a
        // click there means "keep this", and closing would make the first click feel broken.
        case (_, .clicked):
            state = .pinned; return [.cancelTimers, .showPanel(pinned: true)]
        case (.closed, .itemEntered):
            state = .opening; return [.startOpenTimer(Self.openDelay)]
        case (.opening, .itemExited):
            state = .closed; return [.cancelTimers]
        case (.opening, .openTimerFired):
            state = .open; return [.showPanel(pinned: false)]
        case (.open, .itemExited), (.open, .panelExited):
            guard !inItem && !inPanel else { return [] }
            state = .closing; return [.startCloseTimer(Self.closeDelay)]
        case (.closing, .itemEntered), (.closing, .panelEntered):
            state = .open; return [.cancelTimers]
        case (.closing, .closeTimerFired):
            state = .closed; return [.hidePanel]
        default:
            return []
        }
    }
}
