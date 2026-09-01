// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation
import CoreFoundation

// MARK: - v0.8.8m7 Central OCR Scheduler

/// Central cadence/scheduling policy for OCR.
///
/// Important boundaries:
/// - Does not perform OCR.
/// - Does not validate OCR results.
/// - Does not own camera sessions or preview layers.
/// - Does not publish accepted scoreboard values.
/// - Only answers when specific OCR regions are allowed to run.
final class OCRScheduler {
    let stoppedClockEventWindowSeconds: CFTimeInterval

    private(set) var mode: OCRSchedulerMode = .idle
    private var stoppedClockWindowStartedAt: CFTimeInterval?
    private var previousClockConfirmedStopped = false

    private var lastClockOCRAt: CFTimeInterval = -Double.greatestFiniteMagnitude
    private var lastScoreOCRAt: CFTimeInterval = -Double.greatestFiniteMagnitude
    private var lastPeriodOCRAt: CFTimeInterval = -Double.greatestFiniteMagnitude
    private var lastPenaltyOCRAt: CFTimeInterval = -Double.greatestFiniteMagnitude
    private var lastPlayerOCRAt: CFTimeInterval = -Double.greatestFiniteMagnitude
    private var lastDiagnosticsOCRAt: CFTimeInterval = -Double.greatestFiniteMagnitude

    init(stoppedClockEventWindowSeconds: CFTimeInterval = 8.0) {
        self.stoppedClockEventWindowSeconds = stoppedClockEventWindowSeconds
    }

    func updateMode(now: CFTimeInterval, state: OCRGameState) -> OCRSchedulerMode {
        if state.manualModeEnabled {
            mode = .manual
            previousClockConfirmedStopped = state.clockIsConfirmedStopped
            return mode
        }

        if state.calibrationVisible || state.activeScreen == .calibration {
            mode = state.debugModeEnabled || state.diagnosticsVisible ? .debug : .calibration
            previousClockConfirmedStopped = state.clockIsConfirmedStopped
            return mode
        }

        if !state.clockIsConfirmedStopped {
            stoppedClockWindowStartedAt = nil
            previousClockConfirmedStopped = false
            mode = .runningClock
            return mode
        }

        if state.clockIsConfirmedStopped && !previousClockConfirmedStopped {
            stoppedClockWindowStartedAt = now
        }
        previousClockConfirmedStopped = true

        let windowStartedAt = stoppedClockWindowStartedAt ?? now
        stoppedClockWindowStartedAt = windowStartedAt
        mode = now - windowStartedAt <= stoppedClockEventWindowSeconds
            ? .stoppedClockEventWindow
            : .longStoppage
        return mode
    }

    func frameAttemptInterval(now: CFTimeInterval, state: OCRGameState, baseClockCadence: CFTimeInterval) -> CFTimeInterval {
        let currentMode = updateMode(now: now, state: state)
        let base = max(0.15, baseClockCadence)

        if state.performanceSafeModeEnabled { return max(base, state.activeScreen == .calibration ? 0.75 : 2.0) }
        if state.motionProtectionActive { return max(base, state.activeScreen == .calibration ? 1.0 : 2.5) }

        switch currentMode {
        case .idle:
            return max(base, 2.0)
        case .manual:
            return max(base, 2.5)
        case .debug:
            return max(base, 0.25)
        case .calibration:
            return max(base, 0.75)
        case .runningClock:
            // UX16d2e: hash event zones while play continues. The hash pass is
            // cheap and bounded; recognition still runs only for changed zones.
            return max(base, 0.75)
        case .stoppedClockEventWindow:
            return max(base, state.activeScreen == .broadcast ? 0.90 : 0.50)
        case .longStoppage:
            return max(base, state.activeScreen == .broadcast ? 1.25 : 0.75)
        }
    }

    func shouldRunClockOCR(now: CFTimeInterval, state: OCRGameState) -> Bool {
        let currentMode = updateMode(now: now, state: state)
        let interval: CFTimeInterval
        switch currentMode {
        case .debug, .calibration:
            interval = 0.35
        case .stoppedClockEventWindow:
            interval = 0.45
        case .longStoppage:
            interval = 1.25
        case .runningClock:
            interval = 0.70
        case .manual:
            interval = 2.0
        case .idle:
            interval = 2.0
        }
        return state.regionChangeState.clockChanged || shouldRun(last: lastClockOCRAt, now: now, interval: interval)
    }

    func shouldRunScoreOCR(now: CFTimeInterval, state: OCRGameState) -> Bool {
        let currentMode = updateMode(now: now, state: state)
        guard currentMode != .runningClock else {
            return state.regionChangeState.scoreChanged
        }
        guard currentMode != .manual else { return false }

        let interval: CFTimeInterval = currentMode == .stoppedClockEventWindow ? 0.75 : 4.0
        return state.regionChangeState.scoreChanged || shouldRun(last: lastScoreOCRAt, now: now, interval: interval)
    }

    func shouldRunPeriodOCR(now: CFTimeInterval, state: OCRGameState) -> Bool {
        let currentMode = updateMode(now: now, state: state)
        guard currentMode != .runningClock else {
            return state.regionChangeState.periodChanged
        }
        guard currentMode != .manual else { return false }

        let interval: CFTimeInterval = currentMode == .stoppedClockEventWindow ? 1.5 : 6.0
        return state.regionChangeState.periodChanged || shouldRun(last: lastPeriodOCRAt, now: now, interval: interval)
    }

    func shouldRunPenaltyOCR(now: CFTimeInterval, slot: PenaltySlotState) -> Bool {
        guard slot.isVisible || slot.isLockedOrAccepted else { return false }
        if slot.regionChanged { return true }
        let lastRunAt = slot.lastRunAt ?? lastPenaltyOCRAt
        return shouldRun(last: lastRunAt, now: now, interval: max(0.5, slot.safetyInterval))
    }

    func shouldRunDiagnosticsOCR(now: CFTimeInterval, state: OCRGameState) -> Bool {
        guard state.debugModeEnabled || state.diagnosticsVisible else { return false }
        let interval: CFTimeInterval = state.activeScreen == .calibration ? 0.75 : 1.5
        return shouldRun(last: lastDiagnosticsOCRAt, now: now, interval: interval)
    }

    func shouldRunPlayerNumberOCR(now: CFTimeInterval, state: OCRGameState) -> Bool {
        let currentMode = updateMode(now: now, state: state)
        guard currentMode != .runningClock else { return state.regionChangeState.playerNumberChanged }
        guard currentMode != .manual else { return false }
        let interval: CFTimeInterval = currentMode == .stoppedClockEventWindow ? 1.0 : 5.0
        return state.regionChangeState.playerNumberChanged || shouldRun(last: lastPlayerOCRAt, now: now, interval: interval)
    }

    func allowedKeys(
        now: CFTimeInterval,
        state: OCRGameState,
        activePenaltyTimeKeys: Set<OCRRegionKey>,
        allPenaltyTimeKeys: Set<OCRRegionKey>,
        penaltyPlayerKeys: Set<OCRRegionKey>
    ) -> Set<OCRRegionKey> {
        _ = activePenaltyTimeKeys
        _ = allPenaltyTimeKeys
        let currentMode = updateMode(now: now, state: state)
        var keys = Set<OCRRegionKey>()

        // Build 631: production OCR is restricted to Home score, Away score,
        // Period and penalty player numbers. Clock movement and penalty timers
        // are Image Relay-only and are never admitted to this scheduler.
        switch currentMode {
        case .runningClock:
            if shouldRunScoreOCR(now: now, state: state) {
                keys.formUnion([.homeScore, .awayScore])
            }
            if shouldRunPeriodOCR(now: now, state: state) {
                keys.insert(.period)
            }
            if state.regionChangeState.playerNumberChanged || state.regionChangeState.penaltyChanged {
                keys.formUnion(penaltyPlayerKeys)
            }
        case .stoppedClockEventWindow:
            if shouldRunScoreOCR(now: now, state: state) { keys.formUnion([.homeScore, .awayScore]) }
            if shouldRunPeriodOCR(now: now, state: state) { keys.insert(.period) }
            if shouldRunPlayerNumberOCR(now: now, state: state) { keys.formUnion(penaltyPlayerKeys) }
        case .longStoppage:
            if shouldRunScoreOCR(now: now, state: state) { keys.formUnion([.homeScore, .awayScore]) }
            if shouldRunPeriodOCR(now: now, state: state) { keys.insert(.period) }
            if state.regionChangeState.playerNumberChanged || state.regionChangeState.penaltyChanged {
                keys.formUnion(penaltyPlayerKeys)
            }
        case .calibration, .debug:
            keys.formUnion(OCRRegionKey.productionOCRCases)
        case .manual, .idle:
            break
        }

        return keys.intersection(Set(OCRRegionKey.productionOCRCases))
    }

    func markRun(keys: Set<OCRRegionKey>, at now: CFTimeInterval) {
        guard !keys.isEmpty else { return }
        if !keys.intersection([.homeScore, .awayScore]).isEmpty { lastScoreOCRAt = now }
        if keys.contains(.period) { lastPeriodOCRAt = now }
        if !keys.intersection([.homePenalty1Player, .homePenalty2Player, .awayPenalty1Player, .awayPenalty2Player]).isEmpty { lastPlayerOCRAt = now }
    }

    func markDiagnosticsRun(at now: CFTimeInterval) {
        lastDiagnosticsOCRAt = now
    }

    private func shouldRun(last: CFTimeInterval, now: CFTimeInterval, interval: CFTimeInterval) -> Bool {
        now - last >= interval
    }
}
#endif
