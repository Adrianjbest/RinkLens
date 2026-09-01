// BUILD 699 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation
import CoreFoundation

// MARK: - v0.8.8m13 Game Event Detector

/// Lightweight, camera-free model of the current game clock.
///
/// This is intentionally independent from OCR/camera/SwiftUI. The ViewModel passes
/// already-parsed clock values into the detector; the detector only decides whether
/// a game-state transition may have happened.
struct GameClockState: Equatable {
    let clockText: String
    let secondsRemaining: Int?
    let isRunning: Bool
    let observedAt: Date
}

/// Small optional score/period snapshot used only for event candidates.
///
/// The detector does not accept score or period values. It only reports that a
/// possible event occurred so the existing validation/smoothing/manual-protection
/// paths can continue to decide the accepted broadcast value.
struct GameScoreSnapshot: Equatable {
    var homeScore: Int?
    var awayScore: Int?
    var periodText: String?

    init(homeScore: Int?, awayScore: Int?, periodText: String?) {
        self.homeScore = homeScore
        self.awayScore = awayScore
        self.periodText = periodText
    }
}

enum GameEventMode: String, Equatable {
    case normalPlay
    case stoppedClockEventWindow
    case longStoppage
    case clockResumed
    case unknown

    var title: String {
        switch self {
        case .normalPlay: return "Normal play"
        case .stoppedClockEventWindow: return "Stopped-clock event window"
        case .longStoppage: return "Long stoppage"
        case .clockResumed: return "Clock resumed"
        case .unknown: return "Unknown"
        }
    }
}

enum GameEventTeamSide: String, Equatable {
    case home
    case away
}

enum GameEventCandidate: Equatable {
    case stoppedClockStarted
    case clockResumed
    case possibleGoal(team: GameEventTeamSide?)
    case possiblePenalty
    case possiblePeriodChange(from: String?, to: String)
    case possibleEndOfPeriod

    var diagnosticText: String {
        switch self {
        case .stoppedClockStarted:
            return "stoppedClockStarted"
        case .clockResumed:
            return "clockResumed"
        case .possibleGoal(let team):
            return "possibleGoal(\(team?.rawValue ?? "unknown"))"
        case .possiblePenalty:
            return "possiblePenalty"
        case .possiblePeriodChange(let from, let to):
            return "possiblePeriodChange(\(from ?? "?")->\(to))"
        case .possibleEndOfPeriod:
            return "possibleEndOfPeriod"
        }
    }
}

struct GameEventDetectionResult: Equatable {
    let mode: GameEventMode
    let events: [GameEventCandidate]
    let eventWindowActive: Bool
    let longStoppage: Bool
    let diagnosticsText: String?

    static let idle = GameEventDetectionResult(
        mode: .unknown,
        events: [],
        eventWindowActive: false,
        longStoppage: false,
        diagnosticsText: nil
    )
}


struct PenaltyBroadcastEventUpdate: Equatable {
    let nextClocks: [PenaltyClock]
    let nextStrength: StrengthState
    let nextSignature: String
    let signatureChanged: Bool
    let event: BroadcastEvent?
}

struct GameEventDetectorConfig: Equatable {
    var stoppedClockEventWindowSeconds: TimeInterval = 8.0
    var duplicateEventSuppressionSeconds: TimeInterval = 3.0
    var longStoppageThresholdSeconds: TimeInterval = 8.0
    // UX16d15k Build 526: OCR goal/penalty popups are deliberately held
    // until the physical board clock has run continuously for this period.
    // The accepted MatchState changes immediately; only the public popup waits.
    var postRestartNormalizationSeconds: TimeInterval = 5.0
    // Release also requires a recent trusted running observation. This prevents
    // OCR lateness from satisfying the dwell using only a stale running flag.
    var runningEvidenceFreshnessSeconds: TimeInterval = 4.5
    // UX16d16b Build 537: confirmed OCR goals must not be suppressed indefinitely
    // when Clock authority is unavailable. Clock proof remains preferred, but a
    // still-valid goal may use this bounded score-stability fallback.
    var goalPopupFallbackSeconds: TimeInterval = 10.0
    var goalPopupFallbackRequiredConfirmations: Int = 2
}

/// Detects clock transitions and likely game-event candidates.
///
/// Boundaries:
/// - Does not run OCR.
/// - Does not parse camera frames.
/// - Does not accept score/period/penalty values.
/// - Does not own penalty state.
/// - Does not bypass ManualScoreController.
final class RinkLensGameEventCoordinator {
    private let config: GameEventDetectorConfig
    private var previousClockState: GameClockState?
    private var stoppedWindowStartedAt: Date?
    private var lastScoreSnapshot: GameScoreSnapshot?
    private var lastEmittedAt: [String: Date] = [:]
    private var longStoppageAlreadyReported = false

    private(set) var lastResult: GameEventDetectionResult = .idle
    private var stoppedClockEventClock: String?
    private let lifecycleStore = RinkLensGameEventLifecycleStore.shared
    private var pendingStoppedClockBroadcastEvents: [BroadcastEvent] {
        get { lifecycleStore.stoppedClockPendingEvents }
        _modify {
            var draft = lifecycleStore.stoppedClockPendingEvents
            defer {
                lifecycleStore.replaceStoppedClockPendingEvents(
                    draft,
                    source: "RinkLensGameEventCoordinator",
                    reason: "Stopped-clock pending-event transaction"
                )
            }
            yield &draft
        }
    }
    private var pendingStoppedClockEventEligibleAt: [UUID: Date] {
        get { lifecycleStore.stoppedClockEligibleAt }
        _modify {
            var draft = lifecycleStore.stoppedClockEligibleAt
            defer { lifecycleStore.replaceStoppedClockEligibleAt(draft) }
            yield &draft
        }
    }
    private var pendingGoalScoreConfirmationCount: [UUID: Int] {
        get { lifecycleStore.goalScoreConfirmationCount }
        _modify {
            var draft = lifecycleStore.goalScoreConfirmationCount
            defer { lifecycleStore.replaceGoalScoreConfirmationCount(draft) }
            yield &draft
        }
    }
    private var pendingGoalLastObservationID: [UUID: UInt64] {
        get { lifecycleStore.goalLastObservationID }
        _modify {
            var draft = lifecycleStore.goalLastObservationID
            defer { lifecycleStore.replaceGoalLastObservationID(draft) }
            yield &draft
        }
    }
    private var hasFlushedCurrentStoppedClockWindow = false
    private var physicalClockRestartedAt: Date?
    private var lastPhysicalClockStoppedAt: Date?
    private var lastPhysicalClockRunningEvidenceAt: Date?

    convenience init() {
        self.init(config: GameEventDetectorConfig())
    }

    init(config: GameEventDetectorConfig) {
        self.config = config
    }

    func reset() {
        previousClockState = nil
        stoppedWindowStartedAt = nil
        lastScoreSnapshot = nil
        lastEmittedAt.removeAll()
        longStoppageAlreadyReported = false
        stoppedClockEventClock = nil
        pendingStoppedClockBroadcastEvents.removeAll()
        pendingStoppedClockEventEligibleAt.removeAll()
        pendingGoalScoreConfirmationCount.removeAll()
        pendingGoalLastObservationID.removeAll()
        hasFlushedCurrentStoppedClockWindow = false
        physicalClockRestartedAt = nil
        lastPhysicalClockStoppedAt = nil
        lastPhysicalClockRunningEvidenceAt = nil
        lastResult = .idle
    }

    /// Compatibility entry point matching the requirement wording.
    ///
    /// If a caller supplies an explicit previous state, it is used for this pass;
    /// otherwise the detector uses its internal lightweight history.
    func processClockState(
        previous: GameClockState?,
        current: GameClockState,
        now: Date
    ) -> GameEventDetectionResult {
        processClockState(
            previousOverride: previous,
            current: current,
            scoreSnapshot: nil,
            penaltyRegionChanged: false,
            now: now
        )
    }

    /// Primary entry point used by the ViewModel.
    func processClockState(
        current: GameClockState,
        scoreSnapshot: GameScoreSnapshot? = nil,
        penaltyRegionChanged: Bool = false,
        now: Date
    ) -> GameEventDetectionResult {
        processClockState(
            previousOverride: nil,
            current: current,
            scoreSnapshot: scoreSnapshot,
            penaltyRegionChanged: penaltyRegionChanged,
            now: now
        )
    }

    private func processClockState(
        previousOverride: GameClockState?,
        current: GameClockState,
        scoreSnapshot: GameScoreSnapshot?,
        penaltyRegionChanged: Bool,
        now: Date
    ) -> GameEventDetectionResult {
        let previous = previousOverride ?? previousClockState
        var events: [GameEventCandidate] = []
        var mode: GameEventMode = .unknown

        if current.isRunning {
            if let previous, !previous.isRunning {
                stoppedWindowStartedAt = nil
                longStoppageAlreadyReported = false
                append(.clockResumed, to: &events, now: now)
                mode = .clockResumed
            } else {
                mode = .normalPlay
            }
        } else {
            if let previous, previous.isRunning {
                stoppedWindowStartedAt = now
                longStoppageAlreadyReported = false
                append(.stoppedClockStarted, to: &events, now: now)
            } else if stoppedWindowStartedAt == nil {
                stoppedWindowStartedAt = now
            }

            let windowStart = stoppedWindowStartedAt ?? now
            let stoppedDuration = now.timeIntervalSince(windowStart)
            let inEventWindow = stoppedDuration <= config.stoppedClockEventWindowSeconds
            let isLongStoppage = stoppedDuration >= config.longStoppageThresholdSeconds

            if isLongStoppage {
                mode = .longStoppage
                longStoppageAlreadyReported = true
            } else if inEventWindow {
                mode = .stoppedClockEventWindow
            } else {
                mode = .longStoppage
            }

            if current.secondsRemaining == 0 {
                append(.possibleEndOfPeriod, to: &events, now: now)
            }

            if penaltyRegionChanged && inEventWindow {
                append(.possiblePenalty, to: &events, now: now)
            }

            if let scoreSnapshot {
                appendScoreAndPeriodEvents(
                    previous: lastScoreSnapshot,
                    current: scoreSnapshot,
                    eventWindowActive: inEventWindow,
                    events: &events,
                    now: now
                )
            }
        }

        if current.isRunning == false, scoreSnapshot != nil {
            lastScoreSnapshot = scoreSnapshot
        } else if current.isRunning {
            lastScoreSnapshot = scoreSnapshot ?? lastScoreSnapshot
        }

        previousClockState = current

        let eventWindowActive: Bool
        if let stoppedWindowStartedAt, !current.isRunning {
            eventWindowActive = now.timeIntervalSince(stoppedWindowStartedAt) <= config.stoppedClockEventWindowSeconds
        } else {
            eventWindowActive = false
        }

        let result = GameEventDetectionResult(
            mode: mode,
            events: events,
            eventWindowActive: eventWindowActive,
            longStoppage: mode == .longStoppage,
            diagnosticsText: diagnosticsText(mode: mode, events: events, current: current, now: now)
        )
        lastResult = result
        return result
    }

    private func appendScoreAndPeriodEvents(
        previous: GameScoreSnapshot?,
        current: GameScoreSnapshot,
        eventWindowActive: Bool,
        events: inout [GameEventCandidate],
        now: Date
    ) {
        guard eventWindowActive, let previous else { return }

        let previousHome = previous.homeScore ?? 0
        let previousAway = previous.awayScore ?? 0
        let currentHome = current.homeScore ?? previousHome
        let currentAway = current.awayScore ?? previousAway
        let homeDelta = currentHome - previousHome
        let awayDelta = currentAway - previousAway

        if homeDelta == 1 && awayDelta == 0 {
            append(.possibleGoal(team: .home), to: &events, now: now)
        } else if awayDelta == 1 && homeDelta == 0 {
            append(.possibleGoal(team: .away), to: &events, now: now)
        }

        if let to = current.periodText, !to.isEmpty, previous.periodText != nil, previous.periodText != to {
            append(.possiblePeriodChange(from: previous.periodText, to: to), to: &events, now: now)
        }
    }

    private func append(_ event: GameEventCandidate, to events: inout [GameEventCandidate], now: Date) {
        let key = event.diagnosticText
        if let last = lastEmittedAt[key], now.timeIntervalSince(last) < config.duplicateEventSuppressionSeconds {
            return
        }
        lastEmittedAt[key] = now
        events.append(event)
    }

    private func diagnosticsText(mode: GameEventMode, events: [GameEventCandidate], current: GameClockState, now: Date) -> String {
        let eventText = events.map(\.diagnosticText).joined(separator: ", ")
        let windowText: String
        if let stoppedWindowStartedAt, !current.isRunning {
            let elapsed = now.timeIntervalSince(stoppedWindowStartedAt)
            let remaining = max(0, config.stoppedClockEventWindowSeconds - elapsed)
            windowText = String(format: "%.1fs remaining", remaining)
        } else {
            windowText = "inactive"
        }

        return "GameEvent mode=\(mode.rawValue) clock=\(current.clockText) running=\(current.isRunning) window=\(windowText) events=[\(eventText)]"
    }
}


// MARK: - Broadcast-safe event helpers

extension RinkLensGameEventCoordinator {
    func hasConfirmedStoppedClock(
        lastObservedClockOCRSeconds: Int?,
        repeatedClockOCRReadCount: Int,
        candidateStartedAt: CFAbsoluteTime?,
        lastClockMovementObservedAt: CFAbsoluteTime,
        lastClockOCRConfirmationAt: CFAbsoluteTime,
        now: CFAbsoluteTime,
        minimumRepeatCount: Int,
        minimumConfirmationDuration: CFTimeInterval,
        movementCooldown: CFTimeInterval,
        safetyOCRInterval: CFTimeInterval
    ) -> Bool {
        guard lastObservedClockOCRSeconds != nil,
              repeatedClockOCRReadCount >= minimumRepeatCount else { return false }
        guard let candidateStartedAt,
              now - candidateStartedAt >= minimumConfirmationDuration else { return false }
        if lastClockMovementObservedAt > 0, now - lastClockMovementObservedAt < movementCooldown {
            return false
        }
        guard lastClockOCRConfirmationAt > 0,
              now - lastClockOCRConfirmationAt <= max(safetyOCRInterval * 2.5, minimumConfirmationDuration + 1.0) else { return false }
        return true
    }

    func shouldFastAcceptClockRestart(
        rawSeconds: Int,
        displayedSeconds: Int,
        direction: GameClockDirection
    ) -> Bool {
        let delta = rawSeconds - displayedSeconds
        guard delta != 0 else { return false }
        guard abs(delta) <= 8 else { return false }

        switch direction {
        case .countUp:
            return delta > 0
        case .countDown, .auto:
            return delta < 0
        }
    }

    func shouldArmScoreBurstWindow(
        previous: ScoreboardState,
        next: ScoreboardState,
        rawClockShowsMovement: Bool,
        hasConfirmedStoppedClock: Bool,
        localClockIsRunning: Bool
    ) -> Bool {
        let homeChanged = previous.homeScore != nil && previous.homeScore != next.homeScore
        let awayChanged = previous.awayScore != nil && previous.awayScore != next.awayScore
        guard homeChanged || awayChanged else { return false }
        guard hasConfirmedStoppedClock, !localClockIsRunning, !rawClockShowsMovement else { return false }
        return true
    }

    func captureStoppedClockEventTime(clockText: String) {
        if stoppedClockEventClock == nil || hasFlushedCurrentStoppedClockWindow {
            stoppedClockEventClock = clockText
            hasFlushedCurrentStoppedClockWindow = false
        }
    }

    func eventClock(
        acceptedClock: String?,
        source: BroadcastEventSource,
        operatorConfirmed: Bool,
        localClockIsRunning: Bool
    ) -> String? {
        if source == .ocr && !operatorConfirmed && !localClockIsRunning {
            return stoppedClockEventClock ?? acceptedClock
        }
        return acceptedClock
    }

    func shouldHoldBroadcastEventUntilClockRestart(
        _ event: BroadcastEvent,
        operatingModeIsOCR: Bool,
        localClockIsRunning: Bool
    ) -> Bool {
        _ = localClockIsRunning
        guard operatingModeIsOCR else { return false }
        guard event.source == .ocr, !event.operatorConfirmed else { return false }
        switch event.type {
        case .goal, .powerPlayGoal, .shortHandedGoal,
             .penalty, .penalties, .powerPlayStart, .penaltyEnd, .timeoutStart, .timeoutEnd:
            // Build 549 removes the second serial confirmation layer. These events
            // already crossed hash-first recognition, repeated publication evidence,
            // strict stopped-Clock commit and the MatchState reducer. Holding them
            // for another five seconds of movement (or a ten-second fallback) made
            // correct popups 19-36 seconds late. Legacy queued events can still be
            // flushed/cancelled, but newly confirmed reducer events enqueue now.
            return false
        default:
            return false
        }
    }

    func upsertPendingStoppedClockBroadcastEvent(_ event: BroadcastEvent) {
        var removedIDs: [UUID] = []
        switch event.type {
        case .goal, .powerPlayGoal, .shortHandedGoal:
            pendingStoppedClockBroadcastEvents.removeAll { pending in
                let remove: Bool
                switch pending.type {
                case .goal, .powerPlayGoal, .shortHandedGoal:
                    remove = pending.team == event.team
                default:
                    remove = false
                }
                if remove { removedIDs.append(pending.id) }
                return remove
            }
        case .penalty, .penalties, .powerPlayStart, .penaltyEnd, .timeoutStart, .timeoutEnd:
            pendingStoppedClockBroadcastEvents.removeAll { pending in
                let remove = [.penalty, .penalties, .powerPlayStart, .penaltyEnd, .timeoutStart, .timeoutEnd].contains(pending.type)
                if remove { removedIDs.append(pending.id) }
                return remove
            }
        default:
            break
        }
        for id in removedIDs {
            pendingStoppedClockEventEligibleAt.removeValue(forKey: id)
            pendingGoalScoreConfirmationCount.removeValue(forKey: id)
            pendingGoalLastObservationID.removeValue(forKey: id)
        }
        pendingStoppedClockBroadcastEvents.append(event)
        if event.isGoalPopupEvent {
            // The event itself already passed the score publication confirmation
            // policy. A later accepted observation is still required before the
            // no-Clock fallback can release it.
            pendingGoalScoreConfirmationCount[event.id] = 1
        }

        let eventMinimum = event.createdAt.addingTimeInterval(config.postRestartNormalizationSeconds)
        if let restart = physicalClockRestartedAt {
            let restartMinimum = restart.addingTimeInterval(config.postRestartNormalizationSeconds)
            pendingStoppedClockEventEligibleAt[event.id] = max(eventMinimum, restartMinimum)
        } else {
            pendingStoppedClockEventEligibleAt[event.id] = eventMinimum
        }
    }

    func notePhysicalClockStopped(clockText: String?) {
        lastPhysicalClockStoppedAt = Date()
        if let clockText, !clockText.isEmpty {
            captureStoppedClockEventTime(clockText: clockText)
        }
        // A second stoppage before the five-second dwell completes restarts the
        // normalisation window. Pending events remain available for correction.
        physicalClockRestartedAt = nil
        lastPhysicalClockRunningEvidenceAt = nil
    }

    func notePhysicalClockRunning(now: Date) {
        if physicalClockRestartedAt == nil {
            physicalClockRestartedAt = now
            let restartMinimum = now.addingTimeInterval(config.postRestartNormalizationSeconds)
            for event in pendingStoppedClockBroadcastEvents {
                let existing = pendingStoppedClockEventEligibleAt[event.id]
                    ?? event.createdAt.addingTimeInterval(config.postRestartNormalizationSeconds)
                pendingStoppedClockEventEligibleAt[event.id] = max(existing, restartMinimum)
            }
        }
        lastPhysicalClockRunningEvidenceAt = now
    }

    /// Build 548 compatibility API. New goals and initial penalties are never
    /// publication-eligible after the trusted physical Clock has restarted.
    func hasRecentStoppedClockEventContext(now: Date) -> Bool {
        false
    }

    func clearPendingStoppedClockBroadcastEvents() {
        pendingStoppedClockBroadcastEvents.removeAll()
        pendingStoppedClockEventEligibleAt.removeAll()
        pendingGoalScoreConfirmationCount.removeAll()
        pendingGoalLastObservationID.removeAll()
        stoppedClockEventClock = nil
        physicalClockRestartedAt = nil
        lastPhysicalClockStoppedAt = nil
        lastPhysicalClockRunningEvidenceAt = nil
        hasFlushedCurrentStoppedClockWindow = true
    }

    /// Removes pending OCR events that no longer match the accepted board state.
    /// This is the safety valve for accidental score additions and penalty-entry
    /// corrections during the five-second post-restart normalisation period.
    func reconcilePendingStoppedClockBroadcastEvents(
        currentState: ScoreboardState
    ) -> [BroadcastEvent] {
        guard !pendingStoppedClockBroadcastEvents.isEmpty else { return [] }
        var cancelled: [BroadcastEvent] = []
        pendingStoppedClockBroadcastEvents.removeAll { event in
            let valid = pendingEventStillMatchesAcceptedState(event, state: currentState)
            if !valid {
                cancelled.append(event)
                pendingStoppedClockEventEligibleAt.removeValue(forKey: event.id)
                pendingGoalScoreConfirmationCount.removeValue(forKey: event.id)
                pendingGoalLastObservationID.removeValue(forKey: event.id)
            }
            return !valid
        }
        return cancelled
    }

    /// Records a later accepted OCR score observation for any pending goal that
    /// still matches the public MatchState. This is deliberately keyed by the
    /// scoring side so a later goal by the other team does not cancel or falsely
    /// confirm the pending event.
    func noteConfirmedGoalScoreObservation(
        currentState: ScoreboardState,
        observedScoreTeams: Set<Team>,
        observationID: UInt64
    ) {
        guard !observedScoreTeams.isEmpty else { return }
        for event in pendingStoppedClockBroadcastEvents where event.isGoalPopupEvent {
            guard pendingEventStillMatchesAcceptedState(event, state: currentState),
                  let scoringTeam = event.team,
                  observedScoreTeams.contains(scoringTeam),
                  pendingGoalLastObservationID[event.id] != observationID else {
                continue
            }
            pendingGoalLastObservationID[event.id] = observationID
            pendingGoalScoreConfirmationCount[event.id, default: 1] += 1
        }
    }

    /// Bounded fallback for confirmed goals only. Trusted Clock movement remains
    /// the primary release path. This path is used only when Clock authority is
    /// unavailable, the scoring side still retains the confirmed goal, at least
    /// one later accepted OCR observation has corroborated it, and ten seconds
    /// have elapsed without a correction.
    func flushStableGoalFallbackEvents(
        now: Date,
        currentState: ScoreboardState
    ) -> [BroadcastEvent] {
        guard !pendingStoppedClockBroadcastEvents.isEmpty else { return [] }
        if physicalClockRestartedAt != nil,
           let runningEvidenceAt = lastPhysicalClockRunningEvidenceAt,
           now.timeIntervalSince(runningEvidenceAt) <= config.runningEvidenceFreshnessSeconds {
            // Fresh trusted Clock evidence owns release while its five-second dwell
            // is active. The fallback must never race or pre-empt the safer path.
            return []
        }

        var released: [BroadcastEvent] = []
        var retained: [BroadcastEvent] = []
        for event in pendingStoppedClockBroadcastEvents {
            guard pendingEventStillMatchesAcceptedState(event, state: currentState) else {
                pendingStoppedClockEventEligibleAt.removeValue(forKey: event.id)
                pendingGoalScoreConfirmationCount.removeValue(forKey: event.id)
                pendingGoalLastObservationID.removeValue(forKey: event.id)
                continue
            }
            guard event.isGoalPopupEvent else {
                retained.append(event)
                continue
            }

            let age = now.timeIntervalSince(event.createdAt)
            let confirmations = pendingGoalScoreConfirmationCount[event.id] ?? 1
            if age >= config.goalPopupFallbackSeconds,
               confirmations >= max(2, config.goalPopupFallbackRequiredConfirmations) {
                released.append(event)
                pendingStoppedClockEventEligibleAt.removeValue(forKey: event.id)
                pendingGoalScoreConfirmationCount.removeValue(forKey: event.id)
                pendingGoalLastObservationID.removeValue(forKey: event.id)
            } else {
                retained.append(event)
            }
        }
        pendingStoppedClockBroadcastEvents = retained
        clearPendingWindowStateIfEmpty()
        return released
    }

    /// Releases each still-valid OCR event through the preferred physical-Clock
    /// path after its own five-second eligibility deadline and fresh continuous
    /// running evidence. The separate bounded fallback applies to goals only.
    func flushNormalizedStoppedClockBroadcastEvents(
        now: Date,
        currentState: ScoreboardState
    ) -> [BroadcastEvent] {
        guard !pendingStoppedClockBroadcastEvents.isEmpty,
              physicalClockRestartedAt != nil,
              let runningEvidenceAt = lastPhysicalClockRunningEvidenceAt,
              now.timeIntervalSince(runningEvidenceAt) <= config.runningEvidenceFreshnessSeconds else {
            return []
        }

        var released: [BroadcastEvent] = []
        var retained: [BroadcastEvent] = []
        for event in pendingStoppedClockBroadcastEvents {
            guard pendingEventStillMatchesAcceptedState(event, state: currentState) else {
                pendingStoppedClockEventEligibleAt.removeValue(forKey: event.id)
                pendingGoalScoreConfirmationCount.removeValue(forKey: event.id)
                pendingGoalLastObservationID.removeValue(forKey: event.id)
                continue
            }
            let eligibleAt = pendingStoppedClockEventEligibleAt[event.id]
                ?? event.createdAt.addingTimeInterval(config.postRestartNormalizationSeconds)
            if now >= eligibleAt {
                released.append(event)
                pendingStoppedClockEventEligibleAt.removeValue(forKey: event.id)
                pendingGoalScoreConfirmationCount.removeValue(forKey: event.id)
                pendingGoalLastObservationID.removeValue(forKey: event.id)
            } else {
                retained.append(event)
            }
        }
        pendingStoppedClockBroadcastEvents = retained
        clearPendingWindowStateIfEmpty()
        return released
    }

    func postRestartNormalizationRemaining(now: Date) -> TimeInterval? {
        guard !pendingStoppedClockBroadcastEvents.isEmpty,
              physicalClockRestartedAt != nil else { return nil }
        let nextEligible = pendingStoppedClockBroadcastEvents.compactMap { pendingStoppedClockEventEligibleAt[$0.id] }.min()
        guard let nextEligible else { return nil }
        return max(0, nextEligible.timeIntervalSince(now))
    }

    private func clearPendingWindowStateIfEmpty() {
        guard pendingStoppedClockBroadcastEvents.isEmpty else { return }
        pendingGoalScoreConfirmationCount.removeAll()
        pendingGoalLastObservationID.removeAll()
        stoppedClockEventClock = nil
        physicalClockRestartedAt = nil
        lastPhysicalClockRunningEvidenceAt = nil
        hasFlushedCurrentStoppedClockWindow = true
    }

    private func pendingEventStillMatchesAcceptedState(
        _ event: BroadcastEvent,
        state: ScoreboardState
    ) -> Bool {
        switch event.type {
        case .goal, .powerPlayGoal, .shortHandedGoal:
            // A later legitimate goal by the other team must not cancel this
            // pending popup. Only a correction that removes the scoring side's
            // confirmed goal invalidates it.
            switch event.team {
            case .home:
                guard let expected = event.homeScoreAfter,
                      let current = state.homeScore else { return false }
                return current >= expected
            case .away:
                guard let expected = event.awayScoreAfter,
                      let current = state.awayScore else { return false }
                return current >= expected
            case .none:
                return event.homeScoreAfter == state.homeScore
                    && event.awayScoreAfter == state.awayScore
            }
        case .penalty, .penalties, .powerPlayStart, .penaltyEnd, .timeoutStart, .timeoutEnd:
            // A legitimate countdown changes the raw penalty timer every second.
            // Comparing the full signature therefore cancelled a pending popup
            // simply because its timer progressed while waiting for Clock proof.
            // Match stable slot/player identity instead; a corrected player or a
            // cleared slot still invalidates the pending event.
            let expected = event.penaltyClockSnapshot.filter(\.isActive)
            let current = StrengthStateCalculator.activePenaltyClocks(from: state).filter(\.isActive)
            guard !expected.isEmpty else { return false }
            let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
            return expected.allSatisfy { expectedPenalty in
                guard let currentPenalty = currentByID[expectedPenalty.id] else { return false }
                if let expectedPlayer = expectedPenalty.playerNumber {
                    return currentPenalty.playerNumber == expectedPlayer
                }
                return true
            }
        default:
            return true
        }
    }


    func makePenaltyBroadcastEventUpdate(
        from previous: ScoreboardState,
        to next: ScoreboardState,
        source: BroadcastEventSource,
        operatorConfirmed: Bool,
        eventClock: String?
    ) -> PenaltyBroadcastEventUpdate {
        let previousClocks = StrengthStateCalculator.activePenaltyClocks(from: previous)
        let nextClocks = StrengthStateCalculator.activePenaltyClocks(from: next)
        let previousSignature = StrengthStateCalculator.signature(for: previousClocks)
        let nextSignature = StrengthStateCalculator.signature(for: nextClocks)
        let nextStrength = StrengthStateCalculator.strengthState(from: nextClocks)
        let signatureChanged = previousSignature != nextSignature
        let previousActiveSlotIDs = Set(previousClocks.filter(\.isActive).map(\.id))
        let nextActiveSlotIDs = Set(nextClocks.filter(\.isActive).map(\.id))
        let newlyActiveSlotIDs = nextActiveSlotIDs.subtracting(previousActiveSlotIDs)
        let newPenaltyAdded = !newlyActiveSlotIDs.isEmpty

        // Player-number corrections, timer updates, removals and slot-preserving
        // OCR repairs update MatchState/strength but do not create another popup.
        guard signatureChanged, nextStrength.isPubliclyVisible, newPenaltyAdded else {
            return PenaltyBroadcastEventUpdate(
                nextClocks: nextClocks,
                nextStrength: nextStrength,
                nextSignature: nextSignature,
                signatureChanged: signatureChanged,
                event: nil
            )
        }

        let eventType: BroadcastEventType = (nextStrength == .fourOnFour || nextStrength == .threeOnThree) ? .penalties : .penalty
        let penalisedTeam = inferredPenalisedTeam(from: previousClocks, to: nextClocks)
        let event = BroadcastEvent(
            type: eventType,
            team: penalisedTeam,
            period: next.period,
            gameClock: eventClock,
            homeScoreAfter: next.homeScore,
            awayScoreAfter: next.awayScore,
            strengthState: nextStrength,
            source: source,
            operatorConfirmed: operatorConfirmed,
            penaltyClockSnapshot: nextClocks
        )

        return PenaltyBroadcastEventUpdate(
            nextClocks: nextClocks,
            nextStrength: nextStrength,
            nextSignature: nextSignature,
            signatureChanged: signatureChanged,
            event: event
        )
    }

    private func inferredPenalisedTeam(from previous: [PenaltyClock], to next: [PenaltyClock]) -> Team? {
        let previousIDs = Set(previous.map(\.id))
        if let newClock = next.first(where: { !previousIDs.contains($0.id) }) {
            return newClock.team
        }
        return next.first?.team
    }

    func makeGoalEvent(
        from previous: ScoreboardState,
        to next: ScoreboardState,
        source: BroadcastEventSource,
        operatorConfirmed: Bool,
        eventClock: String?,
        currentStrengthState: StrengthState,
        activePenaltyClocks: [PenaltyClock]
    ) -> BroadcastEvent? {
        let previousHome = previous.homeScore ?? 0
        let previousAway = previous.awayScore ?? 0
        let nextHome = next.homeScore ?? previousHome
        let nextAway = next.awayScore ?? previousAway
        let homeDelta = nextHome - previousHome
        let awayDelta = nextAway - previousAway

        guard homeDelta >= 0, awayDelta >= 0 else { return nil }
        guard (homeDelta == 1 && awayDelta == 0) || (awayDelta == 1 && homeDelta == 0) else { return nil }

        let team: Team = homeDelta == 1 ? .home : .away
        let type = goalEventType(for: team, currentStrengthState: currentStrengthState)
        return BroadcastEvent(
            type: type,
            team: team,
            period: next.period,
            gameClock: eventClock,
            homeScoreAfter: nextHome,
            awayScoreAfter: nextAway,
            strengthState: currentStrengthState,
            source: source,
            operatorConfirmed: operatorConfirmed,
            penaltyClockSnapshot: activePenaltyClocks
        )
    }

    private func goalEventType(for scoringTeam: Team, currentStrengthState: StrengthState) -> BroadcastEventType {
        switch currentStrengthState {
        case .homePowerPlay where scoringTeam == .home:
            return .powerPlayGoal
        case .awayPowerPlay where scoringTeam == .away:
            return .powerPlayGoal
        case .homePowerPlay where scoringTeam == .away:
            return .shortHandedGoal
        case .awayPowerPlay where scoringTeam == .home:
            return .shortHandedGoal
        case .fiveOnThree(let team, _, _) where team == scoringTeam:
            return .powerPlayGoal
        case .fiveOnThree:
            return .shortHandedGoal
        default:
            return .goal
        }
    }
}


private extension BroadcastEvent {
    var isGoalPopupEvent: Bool {
        switch type {
        case .goal, .powerPlayGoal, .shortHandedGoal:
            return true
        default:
            return false
        }
    }
}


/// Compatibility alias. Event creation, correction, hold/release and exactly-once
/// popup lifecycle are owned by RinkLensGameEventCoordinator.

#endif
