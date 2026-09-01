// BUILD 706 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation
import CoreFoundation

/// UX16d25 Build 547 physical-board penalty authority.
///
/// Contract:
/// - a penalty exists only while a confirmed player number exists;
/// - the timer cannot create or preserve a penalty by itself;
/// - live initial durations are 2, 4, 5 or 10 minutes;
/// - once anchored, the penalty loses the same amount of trusted playing time as
///   the main game clock, regardless of whether that clock counts up or down;
/// - reaching predicted zero increases clear vigilance but never removes the
///   penalty until the physical player-number zone is confirmed blank.
struct RinkLensPenaltyClockAuthorityState: Equatable {
    struct Anchor: Equatable {
        let player: Int
        let initialDurationSeconds: Int
        var lastAcceptedPenaltySeconds: Int
        var lastAcceptedGameClockSeconds: Int?
        var lastAcceptedAt: CFAbsoluteTime
        var awaitingPhysicalPlayerClear: Bool
    }

    enum Decision: Equatable {
        case accepted(seconds: Int, initialDuration: Int, expectedSeconds: Int?, awaitingPhysicalClear: Bool, reason: String)
        case held(reason: String)
        case rejected(reason: String)

        var acceptedSeconds: Int? {
            if case .accepted(let seconds, _, _, _, _) = self { return seconds }
            return nil
        }

        var reason: String {
            switch self {
            case .accepted(_, _, _, _, let reason), .held(let reason), .rejected(let reason):
                return reason
            }
        }
    }

    static let allowedInitialDurationsSeconds: [Int] = [120, 240, 300, 600]
    static let liveInitialEntryToleranceSeconds = 15
    static let runningTimerToleranceSeconds = 4
    static let stoppedTimerToleranceSeconds = 2

    private(set) var anchors: [RinkLensMatchPenaltySlot: Anchor] = [:]

    mutating func reset() {
        let previous = anchors
        anchors.removeAll()
        recordAnchorTransition(
            event: "penalty_clock_anchors_reset",
            slot: nil,
            previous: previous,
            next: anchors,
            reason: "Penalty authority reset"
        )
    }

    mutating func invalidate(slot: RinkLensMatchPenaltySlot) {
        let previous = anchors
        anchors.removeValue(forKey: slot)
        recordAnchorTransition(
            event: "penalty_clock_anchor_invalidated",
            slot: slot,
            previous: previous,
            next: anchors,
            reason: "Physical player ownership ended or changed"
        )
    }

    func anchor(for slot: RinkLensMatchPenaltySlot) -> Anchor? {
        anchors[slot]
    }

    mutating func establishExistingBaseline(
        slot: RinkLensMatchPenaltySlot,
        player: Int,
        observedPenaltySeconds: Int,
        gameClockSeconds: Int?,
        now: CFAbsoluteTime
    ) -> Decision {
        guard (1...99).contains(player), observedPenaltySeconds >= 0 else {
            return .rejected(reason: "invalid player or penalty timer baseline")
        }
        guard let duration = Self.smallestAllowedDuration(containing: observedPenaltySeconds) else {
            return .rejected(reason: "baseline timer exceeds supported 10-minute penalty")
        }
        let anchor = Anchor(
            player: player,
            initialDurationSeconds: duration,
            lastAcceptedPenaltySeconds: observedPenaltySeconds,
            lastAcceptedGameClockSeconds: gameClockSeconds,
            lastAcceptedAt: now,
            awaitingPhysicalPlayerClear: observedPenaltySeconds <= 0
        )
        let previous = anchors
        anchors[slot] = anchor
        recordAnchorTransition(
            event: "penalty_clock_baseline_established",
            slot: slot,
            previous: previous,
            next: anchors,
            reason: "Existing physical penalty baseline accepted"
        )
        return .accepted(
            seconds: observedPenaltySeconds,
            initialDuration: duration,
            expectedSeconds: observedPenaltySeconds,
            awaitingPhysicalClear: false,
            reason: "existing physical penalty baseline anchored to inferred \(duration / 60)-minute class"
        )
    }

    mutating func establishLivePenalty(
        slot: RinkLensMatchPenaltySlot,
        player: Int,
        observedPenaltySeconds: Int,
        gameClockSeconds: Int?,
        now: CFAbsoluteTime
    ) -> Decision {
        guard (1...99).contains(player), observedPenaltySeconds > 0 else {
            return .rejected(reason: "new penalty rejected: invalid player or timer")
        }
        guard let duration = Self.allowedInitialDurationsSeconds.first(where: {
            observedPenaltySeconds <= $0 && $0 - observedPenaltySeconds <= Self.liveInitialEntryToleranceSeconds
        }) else {
            return .rejected(reason: "new penalty rejected: timer is not a 2/4/5/10-minute start or bounded post-restart continuation")
        }

        let previous = anchors
        anchors[slot] = Anchor(
            player: player,
            initialDurationSeconds: duration,
            lastAcceptedPenaltySeconds: observedPenaltySeconds,
            lastAcceptedGameClockSeconds: gameClockSeconds,
            lastAcceptedAt: now,
            awaitingPhysicalPlayerClear: false
        )
        recordAnchorTransition(
            event: "penalty_clock_live_anchor_established",
            slot: slot,
            previous: previous,
            next: anchors,
            reason: "New physical penalty accepted"
        )
        return .accepted(
            seconds: observedPenaltySeconds,
            initialDuration: duration,
            expectedSeconds: observedPenaltySeconds,
            awaitingPhysicalClear: false,
            reason: "new penalty anchored as \(duration / 60)-minute physical-board entry"
        )
    }

    mutating func validateExistingTimer(
        slot: RinkLensMatchPenaltySlot,
        player: Int,
        observedPenaltySeconds: Int,
        gameClockSeconds: Int?,
        gameClockRunning: Bool,
        now: CFAbsoluteTime
    ) -> Decision {
        guard var anchor = anchors[slot] else {
            return .held(reason: "timer held: no player-owned penalty anchor")
        }
        guard anchor.player == player else {
            return .rejected(reason: "timer rejected: player identity changed")
        }
        guard observedPenaltySeconds >= 0, observedPenaltySeconds <= anchor.initialDurationSeconds else {
            return .rejected(reason: "timer rejected: outside anchored penalty duration")
        }

        let expected = expectedRemainingSeconds(anchor: anchor, currentGameClockSeconds: gameClockSeconds, gameClockRunning: gameClockRunning)
        let tolerance = gameClockRunning ? Self.runningTimerToleranceSeconds : Self.stoppedTimerToleranceSeconds

        if let expected {
            guard abs(observedPenaltySeconds - expected) <= tolerance else {
                return .held(reason: "timer held: observed \(observedPenaltySeconds)s differs from game-clock prediction \(expected)s")
            }
        } else if gameClockRunning {
            let maximumFallbackDrop = max(4, min(10, Int(ceil(max(0, now - anchor.lastAcceptedAt))) + 4))
            guard observedPenaltySeconds <= anchor.lastAcceptedPenaltySeconds,
                  anchor.lastAcceptedPenaltySeconds - observedPenaltySeconds <= maximumFallbackDrop else {
                return .held(reason: "timer held: no game-clock anchor and fallback progression is implausible")
            }
        } else {
            guard abs(observedPenaltySeconds - anchor.lastAcceptedPenaltySeconds) <= tolerance else {
                return .held(reason: "timer held: penalty moved while physical game clock was stopped")
            }
        }

        let previous = anchors
        anchor.lastAcceptedPenaltySeconds = observedPenaltySeconds
        anchor.lastAcceptedGameClockSeconds = gameClockSeconds ?? anchor.lastAcceptedGameClockSeconds
        anchor.lastAcceptedAt = now
        anchor.awaitingPhysicalPlayerClear = observedPenaltySeconds == 0
        anchors[slot] = anchor
        recordAnchorTransition(
            event: "penalty_clock_anchor_advanced",
            slot: slot,
            previous: previous,
            next: anchors,
            reason: "Timer validated against the trusted game Clock"
        )

        return .accepted(
            seconds: observedPenaltySeconds,
            initialDuration: anchor.initialDurationSeconds,
            expectedSeconds: expected,
            awaitingPhysicalClear: anchor.awaitingPhysicalPlayerClear,
            reason: anchor.awaitingPhysicalPlayerClear
                ? "predicted penalty reached zero; waiting for physical player-number clear"
                : "timer validated against trusted game-clock elapsed time"
        )
    }

    mutating func noteTrustedGameClock(
        seconds: Int?,
        running: Bool,
        now: CFAbsoluteTime
    ) {
        guard let seconds else { return }
        let previous = anchors
        for slot in anchors.keys {
            guard var anchor = anchors[slot] else { continue }
            if let expected = expectedRemainingSeconds(
                anchor: anchor,
                currentGameClockSeconds: seconds,
                gameClockRunning: running
            ), expected == 0 {
                anchor.awaitingPhysicalPlayerClear = true
            }
            anchors[slot] = anchor
        }
        if previous != anchors {
            recordAnchorTransition(
                event: "penalty_clock_zero_clear_watch_changed",
                slot: nil,
                previous: previous,
                next: anchors,
                reason: "Trusted game Clock changed the physical-clear expectation"
            )
        }
        _ = now
    }

    func expectedRemainingSeconds(
        slot: RinkLensMatchPenaltySlot,
        currentGameClockSeconds: Int?,
        gameClockRunning: Bool
    ) -> Int? {
        guard let anchor = anchors[slot] else { return nil }
        return expectedRemainingSeconds(anchor: anchor, currentGameClockSeconds: currentGameClockSeconds, gameClockRunning: gameClockRunning)
    }

    private func expectedRemainingSeconds(
        anchor: Anchor,
        currentGameClockSeconds: Int?,
        gameClockRunning: Bool
    ) -> Int? {
        // The accepted game-clock value is the elapsed-playing-time authority.
        // A newly observed stopped value still contains the movement that occurred
        // before the stop, so projection must use the absolute delta regardless of
        // the clock's current running flag. If the stopped value does not move, the
        // delta is zero and the penalty naturally remains frozen.
        guard let previousGameClock = anchor.lastAcceptedGameClockSeconds,
              let currentGameClockSeconds else {
            return anchor.lastAcceptedPenaltySeconds
        }
        _ = gameClockRunning
        let elapsedPlayingSeconds = abs(currentGameClockSeconds - previousGameClock)
        return max(0, anchor.lastAcceptedPenaltySeconds - elapsedPlayingSeconds)
    }

    private func recordAnchorTransition(
        event: String,
        slot: RinkLensMatchPenaltySlot?,
        previous: [RinkLensMatchPenaltySlot: Anchor],
        next: [RinkLensMatchPenaltySlot: Anchor],
        reason: String
    ) {
        guard previous != next else { return }
        RinkLensStructuredEventLogger.shared.record(
            domain: .penalty,
            event: event,
            entityID: slot?.rawValue ?? "all-slots",
            previous: Self.summary(previous),
            next: Self.summary(next),
            source: "RinkLensPenaltyClockAuthorityState",
            reason: reason,
            authoritativeOwner: "RinkLensMatchStateReducer"
        )
    }

    private static func summary(_ values: [RinkLensMatchPenaltySlot: Anchor]) -> [String: String] {
        var result: [String: String] = ["count": String(values.count)]
        for (slot, anchor) in values {
            result[slot.rawValue] = "player=\(anchor.player),initial=\(anchor.initialDurationSeconds),remaining=\(anchor.lastAcceptedPenaltySeconds),gameClock=\(anchor.lastAcceptedGameClockSeconds.map { String($0) } ?? "none"),awaitingClear=\(anchor.awaitingPhysicalPlayerClear)"
        }
        return result
    }

    private static func smallestAllowedDuration(containing seconds: Int) -> Int? {
        allowedInitialDurationsSeconds.first(where: { seconds <= $0 })
    }
}
#endif
