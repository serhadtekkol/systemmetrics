import Testing
@testable import MetricsKit

struct HoverStateMachineTests {
    typealias M = HoverStateMachine
    @Test func hoverOpensAfterDelay() {
        var m = M()
        #expect(m.handle(.itemEntered) == [.startOpenTimer(M.openDelay)])
        #expect(m.handle(.openTimerFired) == [.showPanel(pinned: false)])
        #expect(m.state == .open)
    }
    @Test func briefHoverDoesNotOpen() {
        var m = M()
        _ = m.handle(.itemEntered)
        #expect(m.handle(.itemExited) == [.cancelTimers])
        #expect(m.state == .closed)
        #expect(m.handle(.openTimerFired) == [])          // stale timer ignored
    }
    @Test func movingFromItemIntoPanelKeepsItOpen() {
        var m = M()
        _ = m.handle(.itemEntered); _ = m.handle(.openTimerFired)
        #expect(m.handle(.itemExited) == [.startCloseTimer(M.closeDelay)])
        #expect(m.handle(.panelEntered) == [.cancelTimers])
        #expect(m.state == .open)
    }
    @Test func leavingBothCloses() {
        var m = M()
        _ = m.handle(.itemEntered); _ = m.handle(.openTimerFired); _ = m.handle(.itemExited)
        #expect(m.handle(.closeTimerFired) == [.hidePanel])
        #expect(m.state == .closed)
    }
    @Test func clickPinsAndIgnoresPointer() {
        var m = M()
        #expect(m.handle(.clicked) == [.cancelTimers, .showPanel(pinned: true)])
        #expect(m.handle(.itemExited) == [])
        #expect(m.handle(.panelExited) == [])
        #expect(m.state == .pinned)
    }
    @Test func clickWhileHoverOpenPins() {
        var m = M()
        _ = m.handle(.itemEntered); _ = m.handle(.openTimerFired)
        #expect(m.handle(.clicked) == [.cancelTimers, .showPanel(pinned: true)])
    }
    @Test func clickWhilePinnedCloses() {
        var m = M()
        _ = m.handle(.clicked)
        #expect(m.handle(.clicked) == [.cancelTimers, .hidePanel])
        #expect(m.state == .closed)
    }
    @Test func dismissClosesFromAnyOpenState() {
        var m = M()
        _ = m.handle(.clicked)
        #expect(m.handle(.dismiss) == [.cancelTimers, .hidePanel])
        #expect(m.handle(.dismiss) == [])
    }
    @Test func staleCloseTimerAfterReentryIsIgnored() {
        var m = M()
        _ = m.handle(.itemEntered); _ = m.handle(.openTimerFired); _ = m.handle(.itemExited)
        _ = m.handle(.itemEntered)
        #expect(m.handle(.closeTimerFired) == [])
        #expect(m.state == .open)
    }
    @Test func leavingPanelBackIntoItemKeepsItOpen() {
        var m = M()
        _ = m.handle(.itemEntered); _ = m.handle(.openTimerFired)
        _ = m.handle(.panelEntered); _ = m.handle(.itemExited)
        _ = m.handle(.itemEntered)
        #expect(m.handle(.panelExited) == [])
        #expect(m.state == .open)
    }
    @Test func hoverWorksAgainAfterUnpinning() {
        var m = M()
        _ = m.handle(.clicked); _ = m.handle(.dismiss)
        _ = m.handle(.itemExited)
        #expect(m.handle(.itemEntered) == [.startOpenTimer(M.openDelay)])
    }

    @Test func delaysFollowNNGGuidance() {
        #expect(M.openDelay == 0.3)
        #expect(M.closeDelay == 0.5)
    }
    /// #20: Settings is opened from inside the hover panel. The panel is ordered out under the
    /// pointer, so no `panelExited` arrives. The next hover-opened panel must still auto-close.
    @Test func hidingUnderThePointerDoesNotLeaveInPanelStuck() {
        var m = M()
        _ = m.handle(.itemEntered); _ = m.handle(.openTimerFired)
        _ = m.handle(.panelEntered); _ = m.handle(.itemExited)
        #expect(m.handle(.dismiss) == [.cancelTimers, .hidePanel])      // "Ayarlar…" clicked
        #expect(m.handle(.panelHidden(pointerInItem: false)) == [])
        // Later, a normal hover cycle.
        #expect(m.handle(.itemEntered) == [.startOpenTimer(M.openDelay)])
        #expect(m.handle(.openTimerFired) == [.showPanel(pinned: false)])
        #expect(m.handle(.itemExited) == [.startCloseTimer(M.closeDelay)])
        #expect(m.handle(.closeTimerFired) == [.hidePanel])
        #expect(m.state == .closed)
    }
    @Test func withoutTheResetTheStaleFlagWouldBlockClosing() {
        // Documents the failure mode the reset guards against: same sequence, no `.panelHidden`.
        var m = M()
        _ = m.handle(.itemEntered); _ = m.handle(.openTimerFired)
        _ = m.handle(.panelEntered); _ = m.handle(.itemExited)
        _ = m.handle(.dismiss)
        _ = m.handle(.itemEntered); _ = m.handle(.openTimerFired)
        #expect(m.handle(.itemExited) == [])
    }
    @Test func hiddenWhilePointerStillOnItemKeepsItemFlag() {
        var m = M()
        _ = m.handle(.clicked)
        _ = m.handle(.dismiss)
        _ = m.handle(.panelHidden(pointerInItem: true))
        // Hover-open again from the item, then into the panel and out: the item flag was
        // re-read as true, and the exit from the item clears it.
        _ = m.handle(.itemExited); _ = m.handle(.itemEntered); _ = m.handle(.openTimerFired)
        #expect(m.handle(.itemExited) == [.startCloseTimer(M.closeDelay)])
    }
    @Test func showThatCouldNotHappenReturnsToClosed() {
        // AppDelegate reports `.panelHidden` when the status button has no screen frame.
        var m = M()
        _ = m.handle(.clicked)
        #expect(m.state == .pinned)
        #expect(m.handle(.panelHidden(pointerInItem: true)) == [.cancelTimers])
        #expect(m.state == .closed)
        #expect(m.handle(.clicked) == [.cancelTimers, .showPanel(pinned: true)])
    }
    @Test func outsideDismissClosesHoverPanelToo() {
        var m = M()
        _ = m.handle(.itemEntered); _ = m.handle(.openTimerFired)
        #expect(m.handle(.dismiss) == [.cancelTimers, .hidePanel])
        #expect(m.state == .closed)
    }
    @Test func dismissWhileOpeningCancelsTheOpenTimer() {
        var m = M()
        _ = m.handle(.itemEntered)
        #expect(m.handle(.dismiss) == [.cancelTimers, .hidePanel])
        #expect(m.handle(.openTimerFired) == [])
    }
}
