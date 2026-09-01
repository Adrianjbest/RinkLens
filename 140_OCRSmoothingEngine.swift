// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation

// MARK: - Phase 4 OCR Smoothing and Trust Model

struct OCRFieldConfidence: Identifiable, Hashable {
    var id: OCRRegionKey { key }
    var key: OCRRegionKey
    var raw: String
    var cleaned: String
    var accepted: String
    var recognizer: RecognitionStrategy
    var confidence: Float
    var validation: String
    var stabilityCount: Int
    var lastUpdated: Date = .now

    var isAccepted: Bool { !accepted.isEmpty && validation.lowercased() != "low confidence" }

    var trustLabel: String {
        if !isAccepted { return "Verify" }
        if confidence >= 0.75 { return "High" }
        if confidence >= 0.55 { return "Medium" }
        return "Low"
    }

    var displayValue: String {
        if !accepted.isEmpty { return accepted }
        if !cleaned.isEmpty { return cleaned }
        if !raw.isEmpty { return raw }
        return "--"
    }
}

struct OCRTrustSummary: Equatable {
    var fieldCount: Int = 0
    var acceptedCount: Int = 0
    var lowConfidenceCount: Int = 0
    var verifyCount: Int = 0
    var lastUpdated: Date?

    // v0.8.2b: Aggregated validation failures for field diagnostics.
    // Example values: ["Low confidence": 2, "Format mismatch": 1].
    var failureReasons: [String: Int] = [:]

    var publicOverlayTrusted: Bool {
        fieldCount > 0 && verifyCount == 0
    }

    var failureReasonText: String {
        guard !failureReasons.isEmpty else { return "" }
        return failureReasons
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ", ")
    }

    var statusText: String {
        guard fieldCount > 0 else { return "No OCR sample yet" }
        if verifyCount > 0 {
            let reasonSuffix = failureReasonText.isEmpty ? "" : " (\(failureReasonText))"
            return "OCR verify: \(verifyCount) field(s) need review\(reasonSuffix)"
        }
        if lowConfidenceCount > 0 { return "OCR stable with \(lowConfidenceCount) low-confidence field(s)" }
        return "OCR stable"
    }
}

/// Centralises the Phase 4 public-overlay guardrail:
/// raw OCR can be shown to the operator, but public state only changes when values are stable and valid.
final class OCRSmoothingEngine {
    private var pendingInt: [String: Int] = [:]
    private var pendingIntCount: [String: Int] = [:]
    private var pendingIntFirstSeenAt: [String: Date] = [:]
    private var pendingString: [String: String] = [:]
    private var pendingStringCount: [String: Int] = [:]
    private var pendingStringFirstSeenAt: [String: Date] = [:]
    private var fieldConfidence: [OCRRegionKey: OCRFieldConfidence] = [:]

    /// Used only when the template clock direction is set to Auto.
    /// Penalty timers never use auto-detection; they are always treated as count-down fields.
    private var detectedGameClockDirection: GameClockDirection?

    private let normalClockJumpSeconds = 3
    // v0.7.7.4: the game clock must publish the first valid OCR read immediately.
    // Previous v0.7.7.3 logic could show the clock correctly in Test OCR but keep
    // the public clock at No detection because the trust gate was waiting for 2/3
    // frames before any current clock value existed.
    private let normalClockConfirmationFrames = 1
    private let suspiciousClockConfirmationFrames = 4
    private let resetClockConfirmationFrames = 3

    // v0.7.5 score/time guardrails:
    // - Normal hockey goals are +1 and can be accepted quickly after confirmation.
    // - If OCR missed an event and the displayed score genuinely jumps by 2 or 3,
    //   allow it only after the same value has remained stable for a short period.
    // - Very large score jumps are treated as OCR errors and held for manual review.
    private let suspiciousScoreConfirmationFrames = 4
    private let suspiciousScoreMinimumStableSeconds: TimeInterval = 2.0
    private let maximumAutoScoreJump = 3

    // Clock corrections are allowed when small, or when they look like a known period reset.
    // Large non-reset jumps are rejected so one bad OCR read cannot move the public clock.
    private let suspiciousClockMinimumStableSeconds: TimeInterval = 2.0
    private let maximumNonResetClockCorrectionSeconds = 15
    private let knownPenaltyResetSeconds: Set<Int> = [120, 300, 600]

    func reset() {
        pendingInt.removeAll()
        pendingIntCount.removeAll()
        pendingIntFirstSeenAt.removeAll()
        pendingString.removeAll()
        pendingStringCount.removeAll()
        pendingStringFirstSeenAt.removeAll()
        fieldConfidence.removeAll()
        detectedGameClockDirection = nil
    }

    func reset(field: String) {
        pendingInt.removeValue(forKey: field)
        pendingIntCount.removeValue(forKey: field)
        pendingIntFirstSeenAt.removeValue(forKey: field)
        pendingString.removeValue(forKey: field)
        pendingStringCount.removeValue(forKey: field)
        pendingStringFirstSeenAt.removeValue(forKey: field)
        if field == "clock" {
            detectedGameClockDirection = nil
        }
    }

    func reset(key: OCRRegionKey) {
        reset(field: smoothingFieldName(for: key))
        fieldConfidence.removeValue(forKey: key)
    }

    func merge(
        previous: ScoreboardState,
        next: ScoreboardState,
        gameClockDirection: GameClockDirection = .auto
    ) -> ScoreboardState {
        var merged = previous
        merged.homeTeam = smoothString(field: "homeTeam", current: previous.homeTeam, incoming: next.homeTeam)
        merged.awayTeam = smoothString(field: "awayTeam", current: previous.awayTeam, incoming: next.awayTeam)
        merged.homeScore = smoothInt(field: "homeScore", current: previous.homeScore, incoming: next.homeScore)
        merged.awayScore = smoothInt(field: "awayScore", current: previous.awayScore, incoming: next.awayScore)
        let smoothedPeriod = smoothInt(field: "period", current: previous.period, incoming: next.period)
        merged.period = smoothedPeriod
        if let incomingLabel = next.periodLabel,
           OCRValidationEngine.isValidPeriodLabel(incomingLabel),
           let incomingPeriod = next.period,
           smoothedPeriod == incomingPeriod {
            merged.periodLabel = incomingLabel.uppercased()
        } else if smoothedPeriod == previous.period {
            merged.periodLabel = previous.periodLabel
        } else {
            merged.periodLabel = smoothedPeriod.map { String($0) }
        }
        merged.homeShots = smoothInt(field: "homeShots", current: previous.homeShots, incoming: next.homeShots)
        merged.awayShots = smoothInt(field: "awayShots", current: previous.awayShots, incoming: next.awayShots)

        merged.homePenalty1Player = smoothInt(field: "homePenalty1Player", current: previous.homePenalty1Player, incoming: next.homePenalty1Player)
        merged.homePenalty2Player = smoothInt(field: "homePenalty2Player", current: previous.homePenalty2Player, incoming: next.homePenalty2Player)
        merged.awayPenalty1Player = smoothInt(field: "awayPenalty1Player", current: previous.awayPenalty1Player, incoming: next.awayPenalty1Player)
        merged.awayPenalty2Player = smoothInt(field: "awayPenalty2Player", current: previous.awayPenalty2Player, incoming: next.awayPenalty2Player)

        // Penalty clocks are always forced to count down. They do not use the game clock direction setting.
        merged.homePenalty1Clock = smoothPenaltyTime(field: "homePenalty1Clock", current: previous.homePenalty1Clock, incoming: next.homePenalty1Clock)
        merged.homePenalty2Clock = smoothPenaltyTime(field: "homePenalty2Clock", current: previous.homePenalty2Clock, incoming: next.homePenalty2Clock)
        merged.awayPenalty1Clock = smoothPenaltyTime(field: "awayPenalty1Clock", current: previous.awayPenalty1Clock, incoming: next.awayPenalty1Clock)
        merged.awayPenalty2Clock = smoothPenaltyTime(field: "awayPenalty2Clock", current: previous.awayPenalty2Clock, incoming: next.awayPenalty2Clock)

        merged.clock = smoothGameClock(current: previous.clock, incoming: next.clock, direction: gameClockDirection)
        return merged
    }

    func updateConfidence(from fieldDebug: [ScoreboardOCRProcessor.OCRFieldDebug]) -> [OCRRegionKey: OCRFieldConfidence] {
        for field in fieldDebug {
            fieldConfidence[field.key] = OCRFieldConfidence(
                key: field.key,
                raw: field.raw,
                cleaned: field.cleaned,
                accepted: field.accepted,
                recognizer: field.recognizer,
                confidence: field.confidence,
                validation: field.validation,
                stabilityCount: stabilityCount(for: smoothingFieldName(for: field.key))
            )
        }
        return fieldConfidence
    }

    func trustSummary() -> OCRTrustSummary {
        let values = Array(fieldConfidence.values)
        let accepted = values.filter(\.isAccepted)
        let lowConfidence = values.filter { $0.isAccepted && $0.confidence < 0.55 }
        let verify = values.filter { !$0.isAccepted && !$0.raw.isEmpty }
        let failureReasons = Dictionary(
            grouping: verify,
            by: { normalizedFailureReason(from: $0.validation) }
        ).mapValues { $0.count }

        return OCRTrustSummary(
            fieldCount: values.count,
            acceptedCount: accepted.count,
            lowConfidenceCount: lowConfidence.count,
            verifyCount: verify.count,
            lastUpdated: values.map(\.lastUpdated).max(),
            failureReasons: failureReasons
        )
    }

    private func normalizedFailureReason(from validation: String) -> String {
        let reason = validation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { return "Unknown rejection" }

        let lower = reason.lowercased()
        if lower.contains("low confidence") { return "Low confidence" }
        if lower.contains("invalid character") || lower.contains("invalid characters") { return "Invalid character" }
        if lower.contains("regex") || lower.contains("format") { return "Format mismatch" }
        if lower.contains("out of bounds") || lower.contains("range") { return "Out of bounds" }
        if lower.contains("non-numeric") { return "Non-numeric text" }
        if lower.contains("no valid") { return "No valid candidate" }
        return reason
    }

    /// Exposes the smoothing engine's auto-detected game-clock direction back to
    /// the shared ViewModel so Live and Calibration display the same synthetic
    /// clock direction. Penalty clocks never use this value.
    var autoDetectedGameClockDirection: GameClockDirection? {
        detectedGameClockDirection
    }

    func stabilityCount(for field: String) -> Int {
        max(pendingIntCount[field] ?? 0, pendingStringCount[field] ?? 0)
    }

    private func smoothingFieldName(for key: OCRRegionKey) -> String {
        switch key {
        case .clock: return "clock"
        case .period: return "period"
        case .homeScore: return "homeScore"
        case .awayScore: return "awayScore"
        case .homeShots: return "homeShots"
        case .awayShots: return "awayShots"
        case .homePenalty1Player: return "homePenalty1Player"
        case .homePenalty2Player: return "homePenalty2Player"
        case .awayPenalty1Player: return "awayPenalty1Player"
        case .awayPenalty2Player: return "awayPenalty2Player"
        case .homePenalty1Time: return "homePenalty1Clock"
        case .homePenalty2Time: return "homePenalty2Clock"
        case .awayPenalty1Time: return "awayPenalty1Clock"
        case .awayPenalty2Time: return "awayPenalty2Clock"
        }
    }

    private func smoothInt(field: String, current: Int?, incoming: Int?) -> Int? {
        guard let incoming, (0...99).contains(incoming) else { return current }
        if field == "period", !(1...5).contains(incoming) { return current }
        if ["homePenalty1Player", "homePenalty2Player", "awayPenalty1Player", "awayPenalty2Player"].contains(field), !(1...99).contains(incoming) { return current }

        let isScoreField = field == "homeScore" || field == "awayScore"
        let isShotsField = field == "homeShots" || field == "awayShots"

        if (isScoreField || isShotsField), let current, incoming < current {
            return current
        }

        if isScoreField, let current {
            let jump = incoming - current
            if jump > maximumAutoScoreJump {
                // Do not auto-accept very large score jumps. These should be operator-confirmed.
                reset(field: field)
                return current
            }

            if jump > 1 {
                return confirmIntCandidate(
                    field: field,
                    current: current,
                    incoming: incoming,
                    requiredMatches: suspiciousScoreConfirmationFrames,
                    minimumStableSeconds: suspiciousScoreMinimumStableSeconds
                )
            }
        }

        if field == "period", let current, incoming > current + 1 {
            return current
        }

        return confirmIntCandidate(
            field: field,
            current: current,
            incoming: incoming,
            requiredMatches: requiredMatches(for: field)
        )
    }

    private func confirmIntCandidate(
        field: String,
        current: Int?,
        incoming: Int,
        requiredMatches: Int,
        minimumStableSeconds: TimeInterval = 0
    ) -> Int? {
        guard current != incoming else {
            pendingInt[field] = nil
            pendingIntCount[field] = 0
            pendingIntFirstSeenAt.removeValue(forKey: field)
            return current
        }

        let now = Date()
        if pendingInt[field] == incoming {
            let count = (pendingIntCount[field] ?? 1) + 1
            pendingIntCount[field] = count
            let firstSeen = pendingIntFirstSeenAt[field] ?? now
            pendingIntFirstSeenAt[field] = firstSeen
            let stableLongEnough = now.timeIntervalSince(firstSeen) >= minimumStableSeconds

            if count >= requiredMatches && stableLongEnough {
                pendingInt[field] = nil
                pendingIntCount[field] = 0
                pendingIntFirstSeenAt.removeValue(forKey: field)
                return incoming
            }
        } else {
            pendingInt[field] = incoming
            pendingIntCount[field] = 1
            pendingIntFirstSeenAt[field] = now
        }

        return current
    }

    private func smoothString(
        field: String,
        current: String?,
        incoming: String?,
        requiredMatches: Int = 2,
        minimumStableSeconds: TimeInterval = 0
    ) -> String? {
        guard let incoming, !incoming.isEmpty else { return current }
        guard current != incoming else {
            pendingString[field] = nil
            pendingStringCount[field] = 0
            pendingStringFirstSeenAt.removeValue(forKey: field)
            return current
        }

        let now = Date()
        if pendingString[field] == incoming {
            let count = (pendingStringCount[field] ?? 1) + 1
            pendingStringCount[field] = count
            let firstSeen = pendingStringFirstSeenAt[field] ?? now
            pendingStringFirstSeenAt[field] = firstSeen
            let stableLongEnough = now.timeIntervalSince(firstSeen) >= minimumStableSeconds

            if count >= requiredMatches && stableLongEnough {
                pendingString[field] = nil
                pendingStringCount[field] = 0
                pendingStringFirstSeenAt.removeValue(forKey: field)
                return incoming
            }
        } else {
            pendingString[field] = incoming
            pendingStringCount[field] = 1
            pendingStringFirstSeenAt[field] = now
        }
        return current
    }

    private func smoothPenaltyTime(field: String, current: String?, incoming: String?) -> String? {
        smoothClock(
            field: field,
            current: current,
            incoming: incoming,
            direction: .countDown,
            isPenaltyClock: true
        )
    }

    private func smoothGameClock(current: String?, incoming: String?, direction: GameClockDirection) -> String? {
        smoothClock(
            field: "clock",
            current: current,
            incoming: incoming,
            direction: direction,
            isPenaltyClock: false
        )
    }

    private func smoothClock(
        field: String,
        current: String?,
        incoming: String?,
        direction: GameClockDirection,
        isPenaltyClock: Bool
    ) -> String? {
        guard let incoming else { return current }
        let incomingIsValid = isPenaltyClock
            ? OCRValidationEngine.isValidPenaltyTime(incoming)
            : OCRValidationEngine.isValidGameClock(incoming)
        guard incomingIsValid, let incomingSeconds = seconds(from: incoming) else { return current }

        guard let current, let currentSeconds = seconds(from: current) else {
            // v0.7.7.4 Clock Bootstrap Re-arm Fix:
            // if OCR has produced a valid timer and the accepted clock is empty /
            // No detection, publish it immediately rather than retaining nil while
            // the stability counter warms up. This keeps Test OCR and Live/Broadcast
            // acceptance aligned after OCR start, restart, or trust reset.
            pendingString[field] = nil
            pendingStringCount[field] = 1
            pendingStringFirstSeenAt.removeValue(forKey: field)
            return incoming
        }

        guard current != incoming else {
            pendingString[field] = nil
            pendingStringCount[field] = 0
            return current
        }

        let delta = incomingSeconds - currentSeconds
        let configuredDirection = isPenaltyClock ? GameClockDirection.countDown : direction
        let resolvedDirection = resolveDirection(configuredDirection, delta: delta)
        let normalDirection = isNormalDirection(delta: delta, direction: resolvedDirection)
        let normalJump = abs(delta) <= normalClockJumpSeconds

        if normalDirection && normalJump {
            // v0.7.6: do not auto-detect direction from public displayed state.
            // Live/Broadcast may be locally coasting, so comparing incoming OCR with
            // the displayed clock can invert the direction. Direction is now inferred
            // only from consecutive raw OCR readings in the shared ViewModel.
            return smoothString(field: field, current: current, incoming: incoming, requiredMatches: normalClockConfirmationFrames)
        }

        if isPenaltyClock, delta > 0, knownPenaltyResetSeconds.contains(incomingSeconds) {
            // New penalty values such as 2:00, 5:00 and 10:00 are allowed, but require confirmation.
            return smoothString(field: field, current: current, incoming: incoming, requiredMatches: resetClockConfirmationFrames)
        }

        if !isPenaltyClock, looksLikeGameClockReset(currentSeconds: currentSeconds, incomingSeconds: incomingSeconds) {
            detectedGameClockDirection = nil
            return smoothString(field: field, current: current, incoming: incoming, requiredMatches: resetClockConfirmationFrames)
        }

        // Suspicious jumps are not discarded immediately, but they must remain stable
        // for a short period. Large non-reset game-clock jumps are held back so a
        // single OCR mistake cannot move the public Live/Overlay/Broadcast clock.
        if !isPenaltyClock && abs(delta) > maximumNonResetClockCorrectionSeconds {
            return current
        }

        let accepted = smoothString(
            field: field,
            current: current,
            incoming: incoming,
            requiredMatches: suspiciousClockConfirmationFrames,
            minimumStableSeconds: suspiciousClockMinimumStableSeconds
        )
        // v0.7.6: keep smoothing separate from direction detection.
        // Suspicious but stable values can be accepted, but they must not flip the
        // Live/Broadcast synthetic clock direction.
        return accepted
    }

    private func resolveDirection(_ configuredDirection: GameClockDirection, delta: Int) -> GameClockDirection {
        switch configuredDirection {
        case .countUp, .countDown:
            return configuredDirection
        case .auto:
            // Auto means "do not force a direction inside the smoothing engine".
            // The shared ViewModel owns auto-direction detection from consecutive raw OCR reads.
            return .auto
        }
    }

    private func isNormalDirection(delta: Int, direction: GameClockDirection) -> Bool {
        switch direction {
        case .countUp:
            return delta >= 0
        case .countDown:
            return delta <= 0
        case .auto:
            return true
        }
    }

    private func looksLikeGameClockReset(currentSeconds: Int, incomingSeconds: Int) -> Bool {
        let commonResetValues: Set<Int> = [0, 20 * 60, 15 * 60, 10 * 60, 5 * 60]
        if commonResetValues.contains(incomingSeconds) { return true }
        if currentSeconds >= 19 * 60, incomingSeconds <= 5 { return true }
        if currentSeconds <= 5, incomingSeconds >= 19 * 60 { return true }
        return false
    }

    private func requiredMatches(for field: String) -> Int {
        switch field {
        case "clock":
            // Game clock changes every second, so a valid step should publish immediately.
            return 1

        case "homePenalty1Clock", "homePenalty2Clock", "awayPenalty1Clock", "awayPenalty2Clock":
            // Penalty time also changes every second. Keep it responsive like the main clock.
            return 1

        case "homePenalty1Player", "homePenalty2Player", "awayPenalty1Player", "awayPenalty2Player":
            // Player numbers are stable values. Require a second matching read to reduce false positives.
            return 2

        case "homeScore", "awayScore":
            return 2

        case "period", "homeShots", "awayShots":
            return 3

        default:
            return 2
        }
    }

    private func isValidClock(_ clock: String) -> Bool {
        OCRValidationEngine.isValidGameClock(clock)
    }

    private func seconds(from clock: String) -> Int? {
        OCRValidationEngine.seconds(fromGameClock: clock)
    }
}
#endif
