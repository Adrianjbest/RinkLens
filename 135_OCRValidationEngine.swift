// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation

// MARK: - v0.8.0.0 OCR Hard Validation

/// Hard validation runs before smoothing/trust so invalid OCR cannot pollute
/// Live, Overlay or Broadcast state.
nonisolated enum OCRValidationEngine {
    static let allowedPeriodLabels: Set<String> = ["1", "2", "3", "4", "5", "OT", "SO"]

    static func cleanClockCandidate(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "O", with: "0")
            .replacingOccurrences(of: "o", with: "0")
            .replacingOccurrences(of: ";", with: ":")
            .replacingOccurrences(of: "，", with: ".")
    }

    static func isValidGameClock(_ value: String) -> Bool {
        let cleaned = cleanClockCandidate(value)

        // Standard game clock: 00:00 to 20:00 inclusive.
        if cleaned.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil {
            let parts = cleaned.split(separator: ":")
            guard parts.count == 2, let minutes = Int(parts[0]), let seconds = Int(parts[1]) else { return false }
            guard (0...20).contains(minutes), (0...59).contains(seconds) else { return false }
            if minutes == 20 && seconds > 0 { return false }
            return true
        }

        // Final minute display: 59.9 down to 0.0.
        if cleaned.range(of: #"^\d{1,2}\.\d$"#, options: .regularExpression) != nil {
            let parts = cleaned.split(separator: ".")
            guard parts.count == 2, let seconds = Int(parts[0]), let tenths = Int(parts[1]) else { return false }
            return (0...59).contains(seconds) && (0...9).contains(tenths)
        }

        return false
    }

    static func isValidPenaltyTime(_ value: String) -> Bool {
        let cleaned = cleanClockCandidate(value)
        guard cleaned.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil else { return false }
        let parts = cleaned.split(separator: ":")
        guard parts.count == 2, let minutes = Int(parts[0]), let seconds = Int(parts[1]) else { return false }
        guard (0...20).contains(minutes), (0...59).contains(seconds) else { return false }
        if minutes == 20 && seconds > 0 { return false }
        return true
    }

    static func isValidPlayerNumber(_ value: Int?) -> Bool {
        guard let value else { return false }
        return (1...99).contains(value)
    }

    static func cleanPeriod(_ raw: String) -> String? {
        let upper = raw.uppercased()
            .replacingOccurrences(of: "PERIOD", with: "")
            .replacingOccurrences(of: "1ST", with: "1")
            .replacingOccurrences(of: "2ND", with: "2")
            .replacingOccurrences(of: "3RD", with: "3")
            .replacingOccurrences(of: "4TH", with: "4")
            .replacingOccurrences(of: "5TH", with: "5")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if upper.contains("SO") { return "SO" }
        if upper.contains("OT") { return "OT" }
        for value in ["1", "2", "3", "4", "5"] where upper.contains(value) { return value }
        return nil
    }

    static func isValidPeriodLabel(_ value: String?) -> Bool {
        guard let value else { return false }
        return allowedPeriodLabels.contains(value.uppercased())
    }

    static func seconds(fromGameClock value: String) -> Int? {
        let cleaned = cleanClockCandidate(value)
        if cleaned.contains(":") {
            let parts = cleaned.split(separator: ":")
            guard parts.count == 2, let minutes = Int(parts[0]), let seconds = Int(parts[1]) else { return nil }
            return minutes * 60 + seconds
        }
        if cleaned.contains(".") {
            let parts = cleaned.split(separator: ".")
            guard let seconds = Int(parts.first ?? "") else { return nil }
            return seconds
        }
        return nil
    }

    static func validateCandidateState(_ state: ScoreboardState) -> ScoreboardState {
        var output = state

        if let clock = output.clock, !isValidGameClock(clock) { output.clock = nil }

        if let score = output.homeScore, score < 0 || score > 99 { output.homeScore = nil }
        if let score = output.awayScore, score < 0 || score > 99 { output.awayScore = nil }

        if let label = output.periodLabel {
            let normalized = label.uppercased()
            if allowedPeriodLabels.contains(normalized) {
                output.periodLabel = normalized
                output.period = periodValue(from: normalized)
            } else {
                output.periodLabel = nil
                output.period = nil
            }
        } else if let period = output.period, !(1...5).contains(period) {
            output.period = nil
        }

        // v0.8.2b: Shootout has no active game clock. Suppress any clock OCR
        // that leaks through so it cannot pollute smoothing or the public state.
        if output.periodLabel?.uppercased() == "SO" {
            output.clock = nil
        }

        if !isValidPlayerNumber(output.homePenalty1Player) { output.homePenalty1Player = nil }
        if !isValidPlayerNumber(output.homePenalty2Player) { output.homePenalty2Player = nil }
        if !isValidPlayerNumber(output.awayPenalty1Player) { output.awayPenalty1Player = nil }
        if !isValidPlayerNumber(output.awayPenalty2Player) { output.awayPenalty2Player = nil }

        if let value = output.homePenalty1Clock, !isValidPenaltyTime(value) { output.homePenalty1Clock = nil }
        if let value = output.homePenalty2Clock, !isValidPenaltyTime(value) { output.homePenalty2Clock = nil }
        if let value = output.awayPenalty1Clock, !isValidPenaltyTime(value) { output.awayPenalty1Clock = nil }
        if let value = output.awayPenalty2Clock, !isValidPenaltyTime(value) { output.awayPenalty2Clock = nil }

        return output
    }

    static func periodValue(from label: String) -> Int {
        switch label.uppercased() {
        case "OT": return 4
        case "SO": return 5
        default: return Int(label) ?? 1
        }
    }
}
#endif
