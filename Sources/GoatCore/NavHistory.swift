import Foundation

/// Browser-style back/forward history over any equatable state. Recording
/// the current state again is a no-op; recording anything else truncates
/// the forward tail (going back then somewhere new forgets "forward", like
/// a browser). Capped so a long session can't grow it unbounded.
public struct NavHistory<State: Equatable & Sendable>: Sendable {
    private var entries: [State]
    private var index: Int
    private let cap: Int

    public init(initial: State, cap: Int = 100) {
        entries = [initial]
        index = 0
        self.cap = max(2, cap)
    }

    public var current: State { entries[index] }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index < entries.count - 1 }

    public mutating func record(_ state: State) {
        guard state != entries[index] else { return }
        entries.removeSubrange((index + 1)...)
        entries.append(state)
        index = entries.count - 1
        if entries.count > cap {
            entries.removeFirst(entries.count - cap)
            index = entries.count - 1
        }
    }

    public mutating func goBack() -> State? {
        guard canGoBack else { return nil }
        index -= 1
        return entries[index]
    }

    public mutating func goForward() -> State? {
        guard canGoForward else { return nil }
        index += 1
        return entries[index]
    }
}
