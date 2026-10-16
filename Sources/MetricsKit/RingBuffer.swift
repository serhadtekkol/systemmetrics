public struct RingBuffer<Element: Sendable>: Sendable {
    public let capacity: Int
    private var storage: [Element] = []
    private var head = 0
    public init(capacity: Int) {
        precondition(capacity > 0, "RingBuffer capacity must be positive")
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }
    public var count: Int { storage.count }
    public mutating func append(_ element: Element) {
        if storage.count < capacity { storage.append(element); return }
        storage[head] = element
        head = (head + 1) % capacity
    }
    /// Oldest first.
    public var elements: [Element] {
        storage.count < capacity ? storage : Array(storage[head...] + storage[..<head])
    }
}
