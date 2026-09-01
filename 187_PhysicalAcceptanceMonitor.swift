// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
import Foundation

// MARK: - Build 556 physical acceptance summariser

/// Diagnostic-only acceptance monitor for the Build 551-based runtime.
///
/// Raw OCR evidence, publication decisions and overlay presentation are already
/// logged elsewhere. This monitor joins those stages into operator-facing
/// latency/staleness metrics and an automatic release verdict. It never mutates
/// OCR scheduling, MatchState, event generation or the Broadcast overlay.
@MainActor
final class RinkLensPhysicalAcceptanceMonitor {
    static let shared = RinkLensPhysicalAcceptanceMonitor()

    private struct PendingValue {
        var value: String
        var firstSeenAt: Date
        var lastSeenAt: Date
        var count: Int
    }

    struct Summary: Codable {
        let generatedAt: String
        let applicable: Bool
        let buildNumber: Int
        let baselineBuildNumber: Int
        let verdict: String
        let releaseStatus: String
        let sessionReason: String
        let sessionAgeSeconds: Double
        let clockObservationCount: Int
        let clockCommitCount: Int
        let overlayClockUpdateCount: Int
        let calibrationPublicationBypassCount: Int
        let maximumRecognitionToCommitLatencySeconds: Double
        let maximumCommitToOverlayLatencySeconds: Double
        let maximumVisibleClockStalenessSeconds: Double
        let currentVisibleClockStalenessSeconds: Double
        let maximumScoreServiceGapSeconds: Double
        let maximumScoreRecognitionToCommitLatencySeconds: Double
        let twoReadScoresStillUnpublished: Int
        let falseClockPublicationCount: Int
        let lastPhysicalClock: String
        let lastPublicClock: String
        let lastOverlayClock: String
        let failures: [String]
        let notes: [String]
    }

    private let baselineBuildNumber = 551
    private let maximumAcceptedLatency: TimeInterval = 3.0
    private let maximumAcceptedStaleness: TimeInterval = 3.0
    private let maximumAcceptedScoreServiceGap: TimeInterval = 4.0

    private var sessionStartedAt = Date()
    private var sessionReason = "Application launch"
    private var isApplicable = true

    private var clockObservationCount = 0
    private var clockCommitCount = 0
    private var overlayClockUpdateCount = 0
    private var calibrationPublicationBypassCount = 0
    private var falseClockPublicationCount = 0

    private var lastPhysicalClock = "--:--"
    private var lastPhysicalClockAt: Date?
    private var lastPublicClock = "--:--"
    private var lastPublicClockAt: Date?
    private var lastOverlayClock = "--:--"
    private var lastOverlayClockAt: Date?

    private var pendingPhysicalClockByValue: [String: Date] = [:]
    private var pendingPublicClockByValue: [String: Date] = [:]
    private var scorePending: [String: PendingValue] = [:]
    private var lastScoreAttemptAt: [String: Date] = [:]

    private var clockMismatchStartedAt: Date?
    private var maximumRecognitionToCommitLatency: TimeInterval = 0
    private var maximumCommitToOverlayLatency: TimeInterval = 0
    private var maximumVisibleClockStaleness: TimeInterval = 0
    private var maximumScoreServiceGap: TimeInterval = 0
    private var maximumScoreRecognitionToCommitLatency: TimeInterval = 0

    private var recentNotes: [String] = []
    private let maximumRecentNotes = 16

    private init() {}

    func beginSession(reason: String) {
        sessionStartedAt = Date()
        sessionReason = reason
        isApplicable = true
        clockObservationCount = 0
        clockCommitCount = 0
        overlayClockUpdateCount = 0
        calibrationPublicationBypassCount = 0
        falseClockPublicationCount = 0
        lastPhysicalClock = "--:--"
        lastPhysicalClockAt = nil
        lastPublicClock = "--:--"
        lastPublicClockAt = nil
        lastOverlayClock = "--:--"
        lastOverlayClockAt = nil
        pendingPhysicalClockByValue.removeAll(keepingCapacity: true)
        pendingPublicClockByValue.removeAll(keepingCapacity: true)
        scorePending.removeAll(keepingCapacity: true)
        // Build 558: seed both score service clocks at OCR-session start so a
        // field that is never attempted (or first appears 20 seconds late) is
        // reported as a service failure rather than escaping the gap metric.
        lastScoreAttemptAt = [
            "homeScore": sessionStartedAt,
            "awayScore": sessionStartedAt
        ]
        clockMismatchStartedAt = nil
        maximumRecognitionToCommitLatency = 0
        maximumCommitToOverlayLatency = 0
        maximumVisibleClockStaleness = 0
        maximumScoreServiceGap = 0
        maximumScoreRecognitionToCommitLatency = 0
        recentNotes.removeAll(keepingCapacity: true)
        note("Acceptance session started: \(reason)")
    }

    /// Image Relay and Manual modes intentionally produce no OCR value or
    /// MatchState publication. Keep the acceptance header truthful instead of
    /// grading a non-OCR session against OCR latency thresholds.
    func markNotApplicable(reason: String) {
        beginSession(reason: reason)
        isApplicable = false
        lastScoreAttemptAt.removeAll(keepingCapacity: true)
        recentNotes.removeAll(keepingCapacity: true)
        note("OCR physical acceptance is not applicable to this scoreboard input mode")
    }

    func recordFieldPublication(
        field: String,
        recognisedValue: String?,
        visibleValue: String,
        flow: String,
        reducerOutcome: String,
        route: String,
        continuousOCRRequested: Bool,
        at timestamp: Date = Date()
    ) {
        let recognised = recognisedValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasRecognisedValue = !(recognised ?? "").isEmpty

        if field == "clock", let recognised, hasRecognisedValue {
            clockObservationCount += 1
            lastPhysicalClock = recognised
            lastPhysicalClockAt = timestamp
            pendingPhysicalClockByValue[recognised] = pendingPhysicalClockByValue[recognised] ?? timestamp

            if flow == "calibration-selected-zone", continuousOCRRequested {
                calibrationPublicationBypassCount += 1
                note("FAIL route bypass: recognised Clock \(recognised) on \(route) while continuous OCR was requested, but flow was diagnostics-only")
            }

            if visibleValue != recognised {
                if clockMismatchStartedAt == nil { clockMismatchStartedAt = timestamp }
                updateStaleness(now: timestamp)
            } else {
                finishStaleInterval(now: timestamp)
            }

            if reducerOutcome.contains("Committed") {
                recordPublicClock(recognised, at: timestamp, source: reducerOutcome)
            } else if reducerOutcome.contains("retained existing") && visibleValue == recognised {
                lastPublicClock = visibleValue
                lastPublicClockAt = timestamp
            }
        }

        if field == "homeScore" || field == "awayScore" {
            if let previousAttempt = lastScoreAttemptAt[field] {
                maximumScoreServiceGap = max(maximumScoreServiceGap, timestamp.timeIntervalSince(previousAttempt))
            }
            lastScoreAttemptAt[field] = timestamp

            if let recognised, hasRecognisedValue {
                let key = "\(field)=\(recognised)"
                if visibleValue == recognised {
                    if let pending = scorePending.removeValue(forKey: key) {
                        maximumScoreRecognitionToCommitLatency = max(
                            maximumScoreRecognitionToCommitLatency,
                            timestamp.timeIntervalSince(pending.firstSeenAt)
                        )
                    }
                } else if var pending = scorePending[key] {
                    pending.lastSeenAt = timestamp
                    pending.count += 1
                    scorePending[key] = pending
                } else {
                    scorePending[key] = PendingValue(value: recognised, firstSeenAt: timestamp, lastSeenAt: timestamp, count: 1)
                }
            }
        }
    }

    func recordPublicClock(_ value: String, at timestamp: Date = Date(), source: String) {
        guard isValidClock(value) else {
            falseClockPublicationCount += 1
            note("FAIL invalid public Clock published: \(value) source=\(source)")
            return
        }
        if value != lastPublicClock { clockCommitCount += 1 }
        lastPublicClock = value
        lastPublicClockAt = timestamp
        pendingPublicClockByValue[value] = timestamp

        if let observedAt = pendingPhysicalClockByValue.removeValue(forKey: value) {
            maximumRecognitionToCommitLatency = max(maximumRecognitionToCommitLatency, timestamp.timeIntervalSince(observedAt))
        }
        if value == lastPhysicalClock {
            finishStaleInterval(now: timestamp)
        } else {
            if clockMismatchStartedAt == nil { clockMismatchStartedAt = lastPhysicalClockAt ?? timestamp }
            updateStaleness(now: timestamp)
        }
    }

    func recordOverlayPresentation(
        clock: String?,
        homeScore: Int?,
        awayScore: Int?,
        reason: String,
        at timestamp: Date = Date()
    ) {
        guard let clock, isValidClock(clock) else { return }
        if clock != lastOverlayClock { overlayClockUpdateCount += 1 }
        lastOverlayClock = clock
        lastOverlayClockAt = timestamp
        if let committedAt = pendingPublicClockByValue.removeValue(forKey: clock) {
            maximumCommitToOverlayLatency = max(maximumCommitToOverlayLatency, timestamp.timeIntervalSince(committedAt))
        }
        if clock != lastPublicClock, lastPublicClock != "--:--" {
            note("Overlay Clock differs from public MatchState: overlay=\(clock) public=\(lastPublicClock) reason=\(reason)")
        }
        _ = homeScore
        _ = awayScore
    }

    func exportLines(now: Date = Date()) -> [String] {
        let summary = makeSummary(now: now)
        var lines = [
            "Verdict: \(summary.verdict)",
            "Applicable to current mode: \(summary.applicable ? "Yes" : "No")",
            "Release status: \(summary.releaseStatus)",
            "Build: \(summary.buildNumber)",
            "Protected physical baseline: Build \(summary.baselineBuildNumber)",
            "Session: \(summary.sessionReason) (\(format(summary.sessionAgeSeconds))s)",
            "Clock observations / commits / overlay updates: \(summary.clockObservationCount) / \(summary.clockCommitCount) / \(summary.overlayClockUpdateCount)",
            "Last Clock physical / public / overlay: \(summary.lastPhysicalClock) / \(summary.lastPublicClock) / \(summary.lastOverlayClock)",
            "Maximum OCR-to-MatchState latency: \(format(summary.maximumRecognitionToCommitLatencySeconds))s (limit \(format(maximumAcceptedLatency))s)",
            "Maximum MatchState-to-overlay latency: \(format(summary.maximumCommitToOverlayLatencySeconds))s (limit \(format(maximumAcceptedLatency))s)",
            "Maximum visible Clock staleness: \(format(summary.maximumVisibleClockStalenessSeconds))s (limit \(format(maximumAcceptedStaleness))s)",
            "Current visible Clock staleness: \(format(summary.currentVisibleClockStalenessSeconds))s",
            "Maximum Home/Away score service gap: \(format(summary.maximumScoreServiceGapSeconds))s (limit \(format(maximumAcceptedScoreServiceGap))s)",
            "Maximum recognised-score-to-MatchState latency: \(format(summary.maximumScoreRecognitionToCommitLatencySeconds))s (limit \(format(maximumAcceptedLatency))s)",
            "Diagnostics-only publications while continuous OCR requested: \(summary.calibrationPublicationBypassCount)",
            "Two-read scores still unpublished: \(summary.twoReadScoresStillUnpublished)",
            "Invalid Clock publications: \(summary.falseClockPublicationCount)"
        ]
        if !summary.failures.isEmpty {
            lines += ["Failures:"] + summary.failures.map { "- \($0)" }
        }
        if !summary.notes.isEmpty {
            lines += ["Recent evidence:"] + summary.notes.map { "- \($0)" }
        }
        lines.append("Acceptance rule: compilation and synthetic harness success cannot override a physical FAIL. Build 551 remains the accepted baseline until a later physical run passes these limits.")
        return lines
    }

    func exportJSON(now: Date = Date()) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(makeSummary(now: now)),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"verdict\":\"ERROR\",\"reason\":\"Unable to encode physical acceptance summary\"}"
        }
        return text
    }

    private func makeSummary(now: Date) -> Summary {
        updateStaleness(now: now)
        let currentStaleness = clockMismatchStartedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
        let unpublishedScores = scorePending.values.filter { $0.count >= 2 }.count
        var failures: [String] = []
        if calibrationPublicationBypassCount > 0 {
            failures.append("\(calibrationPublicationBypassCount) accepted OCR result(s) were routed to diagnostics-only publication while continuous OCR was requested")
        }
        if maximumRecognitionToCommitLatency > maximumAcceptedLatency {
            failures.append("OCR-to-MatchState latency \(format(maximumRecognitionToCommitLatency))s exceeded \(format(maximumAcceptedLatency))s")
        }
        if maximumVisibleClockStaleness > maximumAcceptedStaleness {
            failures.append("visible Clock staleness \(format(maximumVisibleClockStaleness))s exceeded \(format(maximumAcceptedStaleness))s")
        }
        if currentStaleness > maximumAcceptedStaleness {
            failures.append("Clock is currently stale by \(format(currentStaleness))s")
        }
        if maximumScoreServiceGap > maximumAcceptedScoreServiceGap {
            failures.append("Home/Away score service gap \(format(maximumScoreServiceGap))s exceeded \(format(maximumAcceptedScoreServiceGap))s")
        }
        if maximumScoreRecognitionToCommitLatency > maximumAcceptedLatency {
            failures.append("recognised-score-to-MatchState latency \(format(maximumScoreRecognitionToCommitLatency))s exceeded \(format(maximumAcceptedLatency))s")
        }
        if unpublishedScores > 0 {
            failures.append("\(unpublishedScores) score value(s) have at least two matching reads but remain unpublished")
        }
        if falseClockPublicationCount > 0 {
            failures.append("\(falseClockPublicationCount) invalid Clock publication(s) occurred")
        }

        let hasEnoughEvidence = clockObservationCount >= 2
        let verdict: String
        let releaseStatus: String
        if !isApplicable {
            failures.removeAll(keepingCapacity: true)
            verdict = "NOT APPLICABLE"
            releaseStatus = "IMAGE RELAY / MANUAL VISUAL MODE — validate visual freshness and recording parity separately"
        } else if !failures.isEmpty {
            verdict = "FAIL"
            releaseStatus = "HOLD — do not replace Build \(baselineBuildNumber)"
        } else if !hasEnoughEvidence {
            verdict = "NOT TESTED"
            releaseStatus = "ENGINEERING CANDIDATE ONLY"
        } else {
            verdict = "PASS"
            releaseStatus = "PHYSICAL METRICS PASSED FOR THIS SESSION; compare full fixture evidence before replacing Build \(baselineBuildNumber)"
        }

        return Summary(
            generatedAt: ISO8601DateFormatter().string(from: now),
            applicable: isApplicable,
            buildNumber: RinkLensBuildInfo.buildNumber,
            baselineBuildNumber: baselineBuildNumber,
            verdict: verdict,
            releaseStatus: releaseStatus,
            sessionReason: sessionReason,
            sessionAgeSeconds: max(0, now.timeIntervalSince(sessionStartedAt)),
            clockObservationCount: clockObservationCount,
            clockCommitCount: clockCommitCount,
            overlayClockUpdateCount: overlayClockUpdateCount,
            calibrationPublicationBypassCount: calibrationPublicationBypassCount,
            maximumRecognitionToCommitLatencySeconds: maximumRecognitionToCommitLatency,
            maximumCommitToOverlayLatencySeconds: maximumCommitToOverlayLatency,
            maximumVisibleClockStalenessSeconds: maximumVisibleClockStaleness,
            currentVisibleClockStalenessSeconds: currentStaleness,
            maximumScoreServiceGapSeconds: maximumScoreServiceGap,
            maximumScoreRecognitionToCommitLatencySeconds: maximumScoreRecognitionToCommitLatency,
            twoReadScoresStillUnpublished: unpublishedScores,
            falseClockPublicationCount: falseClockPublicationCount,
            lastPhysicalClock: lastPhysicalClock,
            lastPublicClock: lastPublicClock,
            lastOverlayClock: lastOverlayClock,
            failures: failures,
            notes: recentNotes
        )
    }

    private func updateStaleness(now: Date) {
        guard let startedAt = clockMismatchStartedAt else { return }
        maximumVisibleClockStaleness = max(maximumVisibleClockStaleness, now.timeIntervalSince(startedAt))
    }

    private func finishStaleInterval(now: Date) {
        updateStaleness(now: now)
        clockMismatchStartedAt = nil
    }

    private func note(_ text: String) {
        recentNotes.append(text)
        if recentNotes.count > maximumRecentNotes {
            recentNotes.removeFirst(recentNotes.count - maximumRecentNotes)
        }
    }

    private func isValidClock(_ text: String) -> Bool {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let minutes = Int(parts[0]),
              let seconds = Int(parts[1]) else { return false }
        return minutes >= 0 && minutes <= 99 && seconds >= 0 && seconds < 60
    }

    private func format(_ value: TimeInterval) -> String {
        String(format: "%.2f", max(0, value))
    }
}
