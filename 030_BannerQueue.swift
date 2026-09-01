// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation

// MARK: - Phase 2 Banner Queue

struct BannerQueue: Equatable {
    private(set) var pending: [BroadcastEvent] = []

    var isEmpty: Bool { pending.isEmpty }

    mutating func enqueue(_ event: BroadcastEvent) {
        pending.append(event)
    }

    mutating func next() -> BroadcastEvent? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    mutating func clear() {
        pending.removeAll()
    }
}

#endif
