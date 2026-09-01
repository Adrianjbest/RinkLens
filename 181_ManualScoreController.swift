// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation
import SwiftUI

enum ManualScoreField: Hashable, CaseIterable {
    case homeScore
    case awayScore
    case clock
    case period
}

struct ManualScoreState: Equatable {
    var globalManualModeEnabled: Bool = false

    var homeScoreOverrideActive: Bool = false
    var awayScoreOverrideActive: Bool = false
    var clockOverrideActive: Bool = false
    var periodOverrideActive: Bool = false

    var manualHomeScore: Int?
    var manualAwayScore: Int?
    var manualClockText: String?
    var manualPeriod: Int?

    /// UI drafts live with the manual-score authority. They remain available
    /// when protection is cleared, replacing the former ViewModel mirror values.
    var homeScoreDraft: Int = 0
    var awayScoreDraft: Int = 0
    var periodDraft: Int = 1

    var protectedFieldsDescription: String {
        var fields: [String] = []
        if globalManualModeEnabled { fields.append("global") }
        if homeScoreOverrideActive { fields.append("home score") }
        if awayScoreOverrideActive { fields.append("away score") }
        if clockOverrideActive { fields.append("clock") }
        if periodOverrideActive { fields.append("period") }
        return fields.isEmpty ? "none" : fields.joined(separator: ", ")
    }
}

final class ManualScoreController: ObservableObject {
    @Published private(set) var state = ManualScoreState()

    func setGlobalManualMode(
        _ enabled: Bool,
        currentHomeScore: Int?,
        currentAwayScore: Int?,
        currentClock: String?,
        currentPeriod: Int?
    ) {
        let previous = state
        state.globalManualModeEnabled = enabled

        if enabled {
            state.homeScoreOverrideActive = true
            state.awayScoreOverrideActive = true
            state.clockOverrideActive = true
            state.periodOverrideActive = true

            state.manualHomeScore = clampScore(currentHomeScore ?? state.manualHomeScore ?? state.homeScoreDraft)
            state.manualAwayScore = clampScore(currentAwayScore ?? state.manualAwayScore ?? state.awayScoreDraft)
            state.manualClockText = currentClock.flatMap { isValidClockText($0) ? normalisedClockText($0) : nil } ?? state.manualClockText
            state.manualPeriod = clampPeriod(currentPeriod ?? state.manualPeriod ?? state.periodDraft)
            state.homeScoreDraft = state.manualHomeScore ?? state.homeScoreDraft
            state.awayScoreDraft = state.manualAwayScore ?? state.awayScoreDraft
            state.periodDraft = state.manualPeriod ?? state.periodDraft
        }
        recordTransition(event: "manual_mode_changed", previous: previous, source: "ManualScoreController", reason: enabled ? "Operator enabled manual protection" : "Operator disabled global manual mode")
    }

    func canOCRUpdate(_ field: ManualScoreField) -> Bool {
        if state.globalManualModeEnabled { return false }

        switch field {
        case .homeScore:
            return !state.homeScoreOverrideActive
        case .awayScore:
            return !state.awayScoreOverrideActive
        case .clock:
            return !state.clockOverrideActive
        case .period:
            return !state.periodOverrideActive
        }
    }

    func applyManualHomeScore(_ value: Int) -> Int {
        let previous = state
        let clamped = clampScore(value)
        state.manualHomeScore = clamped
        state.homeScoreDraft = clamped
        state.homeScoreOverrideActive = true
        recordTransition(event: "manual_home_score_applied", previous: previous, source: "ManualScoreController", reason: "Operator applied Home score")
        return clamped
    }

    func applyManualAwayScore(_ value: Int) -> Int {
        let previous = state
        let clamped = clampScore(value)
        state.manualAwayScore = clamped
        state.awayScoreDraft = clamped
        state.awayScoreOverrideActive = true
        recordTransition(event: "manual_away_score_applied", previous: previous, source: "ManualScoreController", reason: "Operator applied Guest score")
        return clamped
    }

    func applyManualClock(_ value: String) -> String? {
        let previous = state
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidClockText(trimmed) else { return nil }
        let normalised = normalisedClockText(trimmed)
        state.manualClockText = normalised
        state.clockOverrideActive = true
        recordTransition(event: "manual_clock_applied", previous: previous, source: "ManualScoreController", reason: "Operator applied game clock")
        return normalised
    }

    func applyManualPeriod(_ value: Int) -> Int {
        let previous = state
        let clamped = clampPeriod(value)
        state.manualPeriod = clamped
        state.periodDraft = clamped
        state.periodOverrideActive = true
        recordTransition(event: "manual_period_applied", previous: previous, source: "ManualScoreController", reason: "Operator applied period")
        return clamped
    }

    func clearManualOverride(_ field: ManualScoreField) {
        let previous = state
        switch field {
        case .homeScore:
            state.homeScoreOverrideActive = false
            state.manualHomeScore = nil
        case .awayScore:
            state.awayScoreOverrideActive = false
            state.manualAwayScore = nil
        case .clock:
            state.clockOverrideActive = false
            state.manualClockText = nil
        case .period:
            state.periodOverrideActive = false
            state.manualPeriod = nil
        }

        if !state.homeScoreOverrideActive,
           !state.awayScoreOverrideActive,
           !state.clockOverrideActive,
           !state.periodOverrideActive {
            state.globalManualModeEnabled = false
        }
        recordTransition(event: "manual_override_cleared", previous: previous, source: "ManualScoreController", reason: "Operator cleared \(field) protection")
    }

    func seedDrafts(home: Int, away: Int, period: Int, source: String, reason: String) {
        let previous = state
        state.homeScoreDraft = clampScore(home)
        state.awayScoreDraft = clampScore(away)
        state.periodDraft = clampPeriod(period)
        recordTransition(event: "manual_drafts_seeded", previous: previous, source: source, reason: reason)
    }

    func setHomeScoreDraft(_ value: Int, source: String, reason: String) {
        seedDrafts(home: value, away: state.awayScoreDraft, period: state.periodDraft, source: source, reason: reason)
    }

    func setAwayScoreDraft(_ value: Int, source: String, reason: String) {
        seedDrafts(home: state.homeScoreDraft, away: value, period: state.periodDraft, source: source, reason: reason)
    }

    func setPeriodDraft(_ value: Int, source: String, reason: String) {
        seedDrafts(home: state.homeScoreDraft, away: state.awayScoreDraft, period: value, source: source, reason: reason)
    }

    func clearAllManualOverrides() {
        let previous = state
        let drafts = (state.homeScoreDraft, state.awayScoreDraft, state.periodDraft)
        state = ManualScoreState(homeScoreDraft: drafts.0, awayScoreDraft: drafts.1, periodDraft: drafts.2)
        recordTransition(event: "manual_overrides_cleared", previous: previous, source: "ManualScoreController", reason: "Clear all manual protection while retaining UI drafts")
    }

    func resolveHomeScore(currentAccepted: Int?, ocrCandidate: Int?) -> Int? {
        guard canOCRUpdate(.homeScore) else { return state.manualHomeScore ?? currentAccepted }
        return ocrCandidate ?? currentAccepted
    }

    func resolveAwayScore(currentAccepted: Int?, ocrCandidate: Int?) -> Int? {
        guard canOCRUpdate(.awayScore) else { return state.manualAwayScore ?? currentAccepted }
        return ocrCandidate ?? currentAccepted
    }

    func resolveClock(currentAccepted: String?, ocrCandidate: String?) -> String? {
        guard canOCRUpdate(.clock) else { return state.manualClockText ?? currentAccepted }
        return ocrCandidate ?? currentAccepted
    }

    func resolvePeriod(currentAccepted: Int?, ocrCandidate: Int?) -> Int? {
        guard canOCRUpdate(.period) else { return state.manualPeriod ?? currentAccepted }
        return ocrCandidate ?? currentAccepted
    }

    private func recordTransition(event: String, previous: ManualScoreState, source: String, reason: String) {
        guard previous != state else { return }
        RinkLensStructuredEventLogger.shared.record(
            domain: .manualScore,
            event: event,
            entityID: "manual-score-controller",
            previous: Self.summary(previous),
            next: Self.summary(state),
            source: source,
            reason: reason
        )
    }

    private static func summary(_ state: ManualScoreState) -> [String: String] {
        [
            "global": String(state.globalManualModeEnabled),
            "protected": state.protectedFieldsDescription,
            "home": state.manualHomeScore.map { String($0) } ?? "none",
            "away": state.manualAwayScore.map { String($0) } ?? "none",
            "clock": state.manualClockText ?? "none",
            "period": state.manualPeriod.map { String($0) } ?? "none",
            "homeDraft": String(state.homeScoreDraft),
            "awayDraft": String(state.awayScoreDraft),
            "periodDraft": String(state.periodDraft)
        ]
    }

    func diagnosticsSummary() -> String {
        "Manual Mode: \(state.globalManualModeEnabled ? "ON" : "OFF") | Protected: \(state.protectedFieldsDescription)"
    }

    private func clampScore(_ value: Int) -> Int {
        max(0, min(99, value))
    }

    private func clampPeriod(_ value: Int) -> Int {
        max(1, min(9, value))
    }

    private func isValidClockText(_ value: String) -> Bool {
        let parts = value.split(separator: ":")
        guard parts.count == 2,
              let minutes = Int(parts[0]),
              let seconds = Int(parts[1]) else {
            return false
        }
        return minutes >= 0 && minutes <= 99 && seconds >= 0 && seconds <= 59
    }

    private func normalisedClockText(_ value: String) -> String {
        let parts = value.split(separator: ":")
        guard parts.count == 2,
              let minutes = Int(parts[0]),
              let seconds = Int(parts[1]) else {
            return value
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
#endif
