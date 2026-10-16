import Foundation

/// What a tick should sample.
/// - `core`: CPU and RAM (the menu bar values), every tick.
/// - `detail`: GPU, swap, disks; only while the panel is open.
/// - `docker`: containers and disk usage; panel open, on its own slower cadence.
public enum SampleKind: Hashable, Sendable { case core, detail, docker }

/// Pure decision of what is due on a tick. Closed panel: only the two menu bar values, which
/// is what keeps idle cost below 1% CPU. Open panel: everything, Docker every `dockerInterval`.
public struct SamplingSchedule: Sendable {
    public static let dockerInterval: TimeInterval = 4
    private var lastDocker: Date?
    public init() {}

    /// Kinds due at `now`. Mutating: records when Docker was last scheduled. Closing the panel
    /// forgets that, so reopening samples Docker immediately.
    public mutating func due(now: Date, panelOpen: Bool) -> Set<SampleKind> {
        guard panelOpen else { lastDocker = nil; return [.core] }
        var kinds: Set<SampleKind> = [.core, .detail]
        // A negative interval means the wall clock was set back; treat it as due rather than
        // stalling Docker until the clock catches up.
        if lastDocker.map({ let e = now.timeIntervalSince($0); return e >= Self.dockerInterval || e < 0 }) ?? true {
            kinds.insert(.docker)
            lastDocker = now
        }
        return kinds
    }
}
