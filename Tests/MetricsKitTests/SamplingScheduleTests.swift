import Testing
import Foundation
@testable import MetricsKit

struct SamplingScheduleTests {
    let t0 = Date(timeIntervalSince1970: 0)
    @Test func closedPanelSamplesCoreOnly() {
        var s = SamplingSchedule()
        #expect(s.due(now: t0, panelOpen: false) == [.core])
    }
    @Test func openingPanelSamplesEverythingImmediately() {
        var s = SamplingSchedule()
        #expect(s.due(now: t0, panelOpen: true) == [.core, .detail, .docker])
    }
    @Test func dockerOnItsOwnCadence() {
        var s = SamplingSchedule()
        _ = s.due(now: t0, panelOpen: true)
        #expect(s.due(now: t0.addingTimeInterval(2), panelOpen: true) == [.core, .detail])
        #expect(s.due(now: t0.addingTimeInterval(4), panelOpen: true) == [.core, .detail, .docker])
    }
    @Test func reopeningSamplesDockerAgainAtOnce() {
        var s = SamplingSchedule()
        _ = s.due(now: t0, panelOpen: true)
        _ = s.due(now: t0.addingTimeInterval(1), panelOpen: false)
        #expect(s.due(now: t0.addingTimeInterval(2), panelOpen: true).contains(.docker))
    }
    @Test func clockSteppingBackwardsDoesNotStallDocker() {
        // Without this, a wall clock set back by an hour would suppress Docker for an hour.
        var s = SamplingSchedule()
        _ = s.due(now: t0, panelOpen: true)
        #expect(s.due(now: t0.addingTimeInterval(-3_600), panelOpen: true).contains(.docker))
    }
}
