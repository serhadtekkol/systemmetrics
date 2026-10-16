import Foundation

/// About five minutes of the series shown as sparklines.
public struct History: Sendable {
    public private(set) var cpu: RingBuffer<Double>
    public private(set) var memory: RingBuffer<Double>
    public private(set) var gpu: RingBuffer<Double>
    public init(capacity: Int) {
        cpu = RingBuffer(capacity: capacity); memory = RingBuffer(capacity: capacity); gpu = RingBuffer(capacity: capacity)
    }
    public static func capacity(forInterval interval: TimeInterval) -> Int { max(1, Int((300 / interval).rounded())) }
    public mutating func record(_ s: SystemSnapshot) {
        if let v = s.cpu?.total { cpu.append(v) }
        if let v = s.memory?.usedFraction { memory.append(v) }
        if let v = s.gpu?.utilization { gpu.append(v) }
    }
}
