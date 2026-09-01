// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation
import CoreFoundation

// MARK: - UX16c34 Stage 6 unified MatchState reducer
//
// This reducer is the single pure transition boundary for accepted scoreboard
// state. Camera, OCR, manual controls and local-clock code submit typed actions;
// only HockeyScoreboardViewModel commits the returned state and performs the
// existing event/overlay side effects.

enum RinkLensMatchStateOrigin: String {
    case bootstrap
    case reset
    case ocr
    case calibration
    case manual
    case localClock
    case recovery

    var broadcastEventSource: BroadcastEventSource? {
        switch self {
        case .ocr:
            return .ocr
        case .manual:
            return .manual
        case .bootstrap, .reset, .calibration, .localClock, .recovery:
            return nil
        }
    }

    var operatorConfirmed: Bool {
        self == .manual
    }
}

struct RinkLensMatchEventPolicy: OptionSet {
    let rawValue: Int

    static let score = RinkLensMatchEventPolicy(rawValue: 1 << 0)
    static let penalty = RinkLensMatchEventPolicy(rawValue: 1 << 1)
    static let period = RinkLensMatchEventPolicy(rawValue: 1 << 2)
    static let all: RinkLensMatchEventPolicy = [.score, .penalty, .period]
}

struct RinkLensMatchStateContext {
    let origin: RinkLensMatchStateOrigin
    let eventPolicy: RinkLensMatchEventPolicy
    let diagnosticsOnly: Bool
    let reason: String

    init(
        origin: RinkLensMatchStateOrigin,
        eventPolicy: RinkLensMatchEventPolicy = [],
        diagnosticsOnly: Bool = false,
        reason: String
    ) {
        self.origin = origin
        self.eventPolicy = eventPolicy
        self.diagnosticsOnly = diagnosticsOnly
        self.reason = reason
    }
}

enum RinkLensMatchPenaltySlot: String, CaseIterable, Hashable {
    case home1
    case home2
    case away1
    case away2
}

enum RinkLensMatchStateField: String, CaseIterable, Hashable {
    case homeTeam
    case awayTeam
    case homeScore
    case awayScore
    case clock
    case period
    case periodLabel
    case homeShots
    case awayShots
    case homePenalty1Player
    case homePenalty1Clock
    case homePenalty2Player
    case homePenalty2Clock
    case awayPenalty1Player
    case awayPenalty1Clock
    case awayPenalty2Player
    case awayPenalty2Clock

    var isScoreField: Bool {
        self == .homeScore || self == .awayScore
    }

    var isPenaltyField: Bool {
        switch self {
        case .homePenalty1Player, .homePenalty1Clock,
             .homePenalty2Player, .homePenalty2Clock,
             .awayPenalty1Player, .awayPenalty1Clock,
             .awayPenalty2Player, .awayPenalty2Clock:
            return true
        default:
            return false
        }
    }

    var isPeriodField: Bool {
        self == .period || self == .periodLabel
    }
}

enum RinkLensMatchStateAction {
    case replace(ScoreboardState, context: RinkLensMatchStateContext)
    case applyAcceptedOCR(
        ScoreboardState,
        manualProtection: ManualScoreState,
        context: RinkLensMatchStateContext
    )
    case setTeams(home: String?, away: String?, context: RinkLensMatchStateContext)
    case setClock(String?, context: RinkLensMatchStateContext)
    case setScores(home: Int?, away: Int?, context: RinkLensMatchStateContext)
    case adjustScore(team: Team, delta: Int, context: RinkLensMatchStateContext)
    case setPeriod(Int?, label: String?, context: RinkLensMatchStateContext)
    case setShots(home: Int?, away: Int?, context: RinkLensMatchStateContext)
    case setPenalty(
        slot: RinkLensMatchPenaltySlot,
        player: Int?,
        clock: String?,
        context: RinkLensMatchStateContext
    )
    /// Recovery EC: one accepted Image Relay penalty observation owns all four
    /// player slots atomically without becoming a whole-scoreboard replacement.
    case setPenaltySnapshot(
        home1: Int?,
        home2: Int?,
        away1: Int?,
        away2: Int?,
        context: RinkLensMatchStateContext
    )
    case registerPenalty(team: Team, seconds: Int, context: RinkLensMatchStateContext)
    case clearPenalties(context: RinkLensMatchStateContext)

    var context: RinkLensMatchStateContext {
        switch self {
        case .replace(_, let context),
             .applyAcceptedOCR(_, _, let context),
             .setTeams(_, _, let context),
             .setClock(_, let context),
             .setScores(_, _, let context),
             .adjustScore(_, _, let context),
             .setPeriod(_, _, let context),
             .setShots(_, _, let context),
             .setPenalty(_, _, _, let context),
             .setPenaltySnapshot(_, _, _, _, let context),
             .registerPenalty(_, _, let context),
             .clearPenalties(let context):
            return context
        }
    }

    var diagnosticName: String {
        switch self {
        case .replace: return "replace"
        case .applyAcceptedOCR: return "applyAcceptedOCR"
        case .setTeams: return "setTeams"
        case .setClock: return "setClock"
        case .setScores: return "setScores"
        case .adjustScore: return "adjustScore"
        case .setPeriod: return "setPeriod"
        case .setShots: return "setShots"
        case .setPenalty: return "setPenalty"
        case .setPenaltySnapshot: return "setPenaltySnapshot"
        case .registerPenalty: return "registerPenalty"
        case .clearPenalties: return "clearPenalties"
        }
    }

    /// Build 517 keeps every reducer attempt that can propose or mutate a score,
    /// including unchanged continuous-OCR observations.
    var isScoreRelevant: Bool {
        switch self {
        case .replace, .applyAcceptedOCR, .setScores, .adjustScore:
            return true
        case .setTeams, .setClock, .setPeriod, .setShots, .setPenalty, .setPenaltySnapshot, .registerPenalty, .clearPenalties:
            return false
        }
    }
}

struct RinkLensMatchStateReduction {
    let previous: ScoreboardState
    let next: ScoreboardState
    let actionName: String
    let context: RinkLensMatchStateContext
    let changedFields: Set<RinkLensMatchStateField>

    var changed: Bool { previous != next }

    var shouldEvaluateScoreEvents: Bool {
        !context.diagnosticsOnly
            && context.eventPolicy.contains(.score)
            && changedFields.contains(where: \.isScoreField)
    }

    var shouldEvaluatePenaltyEvents: Bool {
        !context.diagnosticsOnly
            && context.eventPolicy.contains(.penalty)
            && changedFields.contains(where: \.isPenaltyField)
    }

    var shouldEvaluatePeriodEvents: Bool {
        !context.diagnosticsOnly
            && context.eventPolicy.contains(.period)
            && changedFields.contains(where: \.isPeriodField)
    }

    var diagnosticSummary: String {
        let changedText = changedFields
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
        return "action=\(actionName) origin=\(context.origin.rawValue) changed=\(changed ? "yes" : "no") fields=\(changedText.isEmpty ? "none" : changedText) diagnosticsOnly=\(context.diagnosticsOnly) reason=\(context.reason)"
    }
}

enum RinkLensMatchStateReducer {
    static func reduce(
        current: ScoreboardState,
        action: RinkLensMatchStateAction
    ) -> RinkLensMatchStateReduction {
        var next = current

        switch action {
        case .replace(let replacement, _):
            next = replacement
            // Build 691: TeamIdentityStore is authoritative. Generic state
            // replacement may update scores/clock/period/penalties, but it may
            // not replace the team-name projection.
            next.homeTeam = current.homeTeam
            next.awayTeam = current.awayTeam

        case .applyAcceptedOCR(let candidate, let manualProtection, _):
            next = candidate
            // Build 691: OCR owns no team-identity fields. Preserve the
            // TeamIdentityStore projection even when OCR creates a fresh state
            // containing generic HOME/GUEST placeholders.
            next.homeTeam = current.homeTeam
            next.awayTeam = current.awayTeam
            applyManualProtection(manualProtection, current: current, to: &next)

        case .setTeams(let home, let away, _):
            next.homeTeam = Self.normalisedTeamName(home, fallback: current.homeTeam ?? "HOME")
            next.awayTeam = Self.normalisedTeamName(away, fallback: current.awayTeam ?? "GUEST")

        case .setClock(let clock, _):
            next.clock = clock

        case .setScores(let home, let away, _):
            next.homeScore = home.map { max(0, min(99, $0)) }
            next.awayScore = away.map { max(0, min(99, $0)) }

        case .adjustScore(let team, let delta, _):
            switch team {
            case .home:
                next.homeScore = clampScore((current.homeScore ?? 0) + delta)
            case .away:
                next.awayScore = clampScore((current.awayScore ?? 0) + delta)
            }

        case .setPeriod(let period, let label, _):
            next.period = period.map { max(1, min(9, $0)) }
            if let label {
                next.periodLabel = label
            } else {
                next.periodLabel = next.period.map { String($0) }
            }

        case .setShots(let home, let away, _):
            next.homeShots = home.map { max(0, min(99, $0)) }
            next.awayShots = away.map { max(0, min(99, $0)) }

        case .setPenalty(let slot, let player, let clock, _):
            applyPenalty(slot: slot, player: player, clock: clock, to: &next)

        case .setPenaltySnapshot(let home1, let home2, let away1, let away2, _):
            // All four physical player slots are one semantic observation. Apply
            // them inside a single reducer transaction so score/clock/period can
            // never be copied from a stale snapshot and no intermediate penalty
            // arrangement is visible to the scorebug or popup coordinator.
            applyPenalty(slot: .home1, player: home1, clock: nil, to: &next)
            applyPenalty(slot: .home2, player: home2, clock: nil, to: &next)
            applyPenalty(slot: .away1, player: away1, clock: nil, to: &next)
            applyPenalty(slot: .away2, player: away2, clock: nil, to: &next)

        case .registerPenalty(let team, let seconds, _):
            registerPenalty(team: team, seconds: seconds, in: &next)

        case .clearPenalties:
            next.homePenalty1Player = nil
            next.homePenalty1Clock = "--:--"
            next.homePenalty2Player = nil
            next.homePenalty2Clock = "--:--"
            next.awayPenalty1Player = nil
            next.awayPenalty1Clock = "--:--"
            next.awayPenalty2Player = nil
            next.awayPenalty2Clock = "--:--"
        }

        let changedFields = changedFields(from: current, to: next)
        return RinkLensMatchStateReduction(
            previous: current,
            next: next,
            actionName: action.diagnosticName,
            context: action.context,
            changedFields: changedFields
        )
    }

    private static func applyManualProtection(
        _ protection: ManualScoreState,
        current: ScoreboardState,
        to candidate: inout ScoreboardState
    ) {
        if protection.globalManualModeEnabled || protection.homeScoreOverrideActive {
            candidate.homeScore = protection.manualHomeScore ?? current.homeScore
        }
        if protection.globalManualModeEnabled || protection.awayScoreOverrideActive {
            candidate.awayScore = protection.manualAwayScore ?? current.awayScore
        }
        if protection.globalManualModeEnabled || protection.clockOverrideActive {
            candidate.clock = protection.manualClockText ?? current.clock
        }
        if protection.globalManualModeEnabled || protection.periodOverrideActive {
            candidate.period = protection.manualPeriod ?? current.period
            if let manualPeriod = protection.manualPeriod {
                candidate.periodLabel = String(manualPeriod)
            } else {
                candidate.periodLabel = current.periodLabel
            }
        }
    }

    private static func registerPenalty(
        team: Team,
        seconds: Int,
        in state: inout ScoreboardState
    ) {
        let clock = formatPenaltyClock(seconds: seconds)
        switch team {
        case .home:
            if !isActivePenaltyClock(state.homePenalty1Clock) {
                state.homePenalty1Clock = clock
                state.homePenalty1Player = nil
            } else {
                state.homePenalty2Clock = clock
                state.homePenalty2Player = nil
            }
        case .away:
            if !isActivePenaltyClock(state.awayPenalty1Clock) {
                state.awayPenalty1Clock = clock
                state.awayPenalty1Player = nil
            } else {
                state.awayPenalty2Clock = clock
                state.awayPenalty2Player = nil
            }
        }
    }

    private static func applyPenalty(
        slot: RinkLensMatchPenaltySlot,
        player: Int?,
        clock: String?,
        to state: inout ScoreboardState
    ) {
        let clampedPlayer = player.map { max(1, min(99, $0)) }
        switch slot {
        case .home1:
            state.homePenalty1Player = clampedPlayer
            state.homePenalty1Clock = clock
        case .home2:
            state.homePenalty2Player = clampedPlayer
            state.homePenalty2Clock = clock
        case .away1:
            state.awayPenalty1Player = clampedPlayer
            state.awayPenalty1Clock = clock
        case .away2:
            state.awayPenalty2Player = clampedPlayer
            state.awayPenalty2Clock = clock
        }
    }

    private static func changedFields(
        from previous: ScoreboardState,
        to next: ScoreboardState
    ) -> Set<RinkLensMatchStateField> {
        var fields: Set<RinkLensMatchStateField> = []
        if previous.homeTeam != next.homeTeam { fields.insert(.homeTeam) }
        if previous.awayTeam != next.awayTeam { fields.insert(.awayTeam) }
        if previous.homeScore != next.homeScore { fields.insert(.homeScore) }
        if previous.awayScore != next.awayScore { fields.insert(.awayScore) }
        if previous.clock != next.clock { fields.insert(.clock) }
        if previous.period != next.period { fields.insert(.period) }
        if previous.periodLabel != next.periodLabel { fields.insert(.periodLabel) }
        if previous.homeShots != next.homeShots { fields.insert(.homeShots) }
        if previous.awayShots != next.awayShots { fields.insert(.awayShots) }
        if previous.homePenalty1Player != next.homePenalty1Player { fields.insert(.homePenalty1Player) }
        if previous.homePenalty1Clock != next.homePenalty1Clock { fields.insert(.homePenalty1Clock) }
        if previous.homePenalty2Player != next.homePenalty2Player { fields.insert(.homePenalty2Player) }
        if previous.homePenalty2Clock != next.homePenalty2Clock { fields.insert(.homePenalty2Clock) }
        if previous.awayPenalty1Player != next.awayPenalty1Player { fields.insert(.awayPenalty1Player) }
        if previous.awayPenalty1Clock != next.awayPenalty1Clock { fields.insert(.awayPenalty1Clock) }
        if previous.awayPenalty2Player != next.awayPenalty2Player { fields.insert(.awayPenalty2Player) }
        if previous.awayPenalty2Clock != next.awayPenalty2Clock { fields.insert(.awayPenalty2Clock) }
        return fields
    }

    nonisolated private static func normalisedTeamName(_ value: String?, fallback: String) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : String(trimmed.prefix(40))
    }

    nonisolated private static func clampScore(_ value: Int) -> Int {
        max(0, min(99, value))
    }

    nonisolated private static func clampPeriod(_ value: Int) -> Int {
        max(1, min(9, value))
    }

    private static func formatPenaltyClock(seconds: Int) -> String {
        let clamped = max(0, seconds)
        return String(format: "%d:%02d", clamped / 60, clamped % 60)
    }

    private static func isActivePenaltyClock(_ value: String?) -> Bool {
        guard let value else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != "--:--", trimmed != "0:00", trimmed != "00:00" else { return false }
        let parts = trimmed.split(separator: ":")
        guard parts.count == 2,
              let minutes = Int(parts[0]),
              let seconds = Int(parts[1]) else {
            return false
        }
        return minutes > 0 || seconds > 0
    }
}

// MARK: - UX16d2c continuous OCR publication safety

/// Evidence supplied by the OCR publication boundary. Recognition confidence is
/// not treated as semantic truth; this evidence is only one input to the live
/// transition policy.
enum RinkLensOCRClockEvidenceTrust: String, Equatable {
    case none
    case provisionalSingleSource
    case confirmedAgreement
}

/// UX16d15e Build 520: trust classification for structurally accepted static
/// fields. Initial baseline acquisition and sequential +1 score verification may
/// retain a strong single-mask observation as provisional evidence. A following
/// matching provisional or dual-mask read completes confirmation; arbitrary
/// unattended score jumps remain prohibited.
enum RinkLensOCRStaticBaselineTrust: String, Equatable {
    case none
    case provisionalSingleSource
    case confirmedAgreement

    var diagnosticLabel: String {
        switch self {
        case .none: return "untrusted"
        case .provisionalSingleSource: return "provisional"
        case .confirmedAgreement: return "confirmed"
        }
    }
}

struct RinkLensOCRFieldEvidence: Equatable {
    let acceptedText: String
    let rawText: String
    let confidence: Float
    let segmentationBacked: Bool
    let deterministicAgreement: Bool
    let strongSingleSource: Bool
    /// Build 532: a deliberately observed empty crop is different from an OCR
    /// failure. This flag is only set when the recogniser inspected a fresh field
    /// and both masks found no character-height content. It lets an already-active
    /// penalty clear safely without treating a deadline or malformed read as blank.
    let confirmedBlank: Bool

    init(
        acceptedText: String,
        rawText: String,
        confidence: Float,
        segmentationBacked: Bool,
        deterministicAgreement: Bool = true,
        strongSingleSource: Bool = false,
        confirmedBlank: Bool = false
    ) {
        self.acceptedText = acceptedText
        self.rawText = rawText
        self.confidence = confidence
        self.segmentationBacked = segmentationBacked
        self.deterministicAgreement = deterministicAgreement
        self.strongSingleSource = strongSingleSource
        self.confirmedBlank = confirmedBlank
    }

    var isHighTrust: Bool {
        // Retain Build 509 behaviour for non-clock fields: a structurally strong
        // colour-only short circuit remains usable by the existing score/period/
        // penalty confirmation policies. Clock publication applies the stricter
        // clockTrust classification below.
        confidence >= 0.58 && segmentationBacked
            && (deterministicAgreement || strongSingleSource)
    }

    var isDashDominated: Bool {
        let text = (rawText + acceptedText)
            .uppercased()
            .filter { !$0.isWhitespace }
        guard !text.isEmpty else { return true }
        let meaningful = text.filter { $0.isNumber || $0.isLetter }
        let dashCount = text.filter { $0 == "-" || $0 == "_" || $0 == ":" || $0 == "." }.count
        return meaningful.isEmpty || dashCount > meaningful.count * 2
    }
}

struct RinkLensOCRPublicationEvidence: Equatable {
    var fields: [OCRRegionKey: RinkLensOCRFieldEvidence] = [:]

    func field(_ key: OCRRegionKey) -> RinkLensOCRFieldEvidence? {
        fields[key]
    }

    func highTrust(_ key: OCRRegionKey, matching expected: String) -> Bool {
        guard let field = fields[key] else { return false }
        let accepted = field.acceptedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if key == .clock {
            guard field.confidence >= 0.58,
                  field.segmentationBacked,
                  field.deterministicAgreement else { return false }
            return Self.canonicalClockSeconds(accepted) == Self.canonicalClockSeconds(expected)
                && Self.canonicalClockSeconds(expected) != nil
        }
        return field.isHighTrust && accepted == expected
    }

    func clockTrust(matching expected: String) -> RinkLensOCRClockEvidenceTrust {
        guard let field = fields[.clock],
              field.confidence >= 0.58,
              field.segmentationBacked,
              let expectedSeconds = Self.canonicalClockSeconds(expected),
              Self.canonicalClockSeconds(field.acceptedText) == expectedSeconds else {
            return .none
        }
        if field.deterministicAgreement {
            return .confirmedAgreement
        }
        if field.strongSingleSource {
            return .provisionalSingleSource
        }
        return .none
    }

    /// Initial static baseline acquisition is deliberately more permissive than
    /// unattended live transitions. The parser has already validated and accepted
    /// this field; a structurally-backed single-mask result can therefore become
    /// provisional evidence rather than being discarded merely because the other
    /// mask was blank or unclassified.
    func staticBaselineTrust(_ key: OCRRegionKey, matching expected: String) -> RinkLensOCRStaticBaselineTrust {
        guard let field = fields[key] else { return .none }
        let accepted = field.acceptedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard accepted == expected,
              field.confidence >= 0.68,
              field.segmentationBacked,
              !field.isDashDominated else {
            return .none
        }
        if field.deterministicAgreement {
            return .confirmedAgreement
        }
        if field.strongSingleSource || field.confidence >= 0.70 {
            return .provisionalSingleSource
        }
        return .none
    }

    static func canonicalClockSeconds(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.replacingOccurrences(of: ".", with: ":")
        let parts = normalized.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let minutes = Int(parts[0]),
              let seconds = Int(parts[1]),
              minutes >= 0,
              (0...59).contains(seconds) else { return nil }
        return minutes * 60 + seconds
    }
}


struct RinkLensClockContinuityResolution: Equatable {
    let value: String
    let seconds: Int
    let replacementCount: Int
    let diagnostic: String
}

/// UX16d14 resolves a structurally invalid Clock only from alternatives actually
/// emitted by the glyph classifier. It never predicts or locally ticks the Clock.
/// A candidate must form a valid time, remain within the trusted physical-board
/// continuity window and be the unique best alternative.
enum RinkLensClockContinuityResolver {
    static func resolve(
        raw: String,
        alternativesByToken: [Int: [Int]],
        anchorSeconds: Int,
        elapsedSeconds: CFTimeInterval,
        direction: GameClockDirection?
    ) -> RinkLensClockContinuityResolution? {
        let compact = raw
            .replacingOccurrences(of: ";", with: ":")
            .filter { $0.isNumber || $0 == ":" || $0 == "?" }
        guard compact.filter({ $0 == ":" }).count == 1 else { return nil }

        let characters = Array(compact)
        let colonIndex = characters.firstIndex(of: ":")
        guard let colonIndex,
              colonIndex >= 1,
              characters.count - colonIndex - 1 == 2,
              characters.count == 4 || characters.count == 5 else { return nil }

        var tokenChoices: [[Character]] = []
        tokenChoices.reserveCapacity(characters.count)
        for (index, character) in characters.enumerated() {
            if character == ":" {
                tokenChoices.append([character])
                continue
            }

            let alternatives = (alternativesByToken[index] ?? [])
                .filter { (0...9).contains($0) }
                .map { Character(String($0)) }

            if character == "?" {
                let choices = Array(Set(alternatives)).sorted { String($0) < String($1) }
                guard !choices.isEmpty else { return nil }
                tokenChoices.append(choices)
                continue
            }

            guard character.isNumber else { return nil }
            var choices = [character]
            for alternative in alternatives where !choices.contains(alternative) {
                choices.append(alternative)
            }
            tokenChoices.append(choices)
        }

        var generated: [(value: String, seconds: Int, replacements: Int, score: Double)] = []
        var candidate = characters
        func visit(_ index: Int, _ replacements: Int) {
            guard generated.count < 64 else { return }
            if index == tokenChoices.count {
                guard replacements > 0 else { return }
                let value = String(candidate)
                guard let seconds = RinkLensOCRPublicationEvidence.canonicalClockSeconds(value) else { return }
                let elapsed = max(0.05, elapsedSeconds)
                let delta = seconds - anchorSeconds
                let maximumOrdinaryDelta = max(3, Int(ceil(elapsed)) + 3)
                guard abs(delta) <= maximumOrdinaryDelta else { return }

                if delta != 0, let direction {
                    let observed: GameClockDirection = delta > 0 ? .countUp : .countDown
                    guard observed == direction else { return }
                }

                let score = Double(abs(delta)) + Double(replacements) * 0.20
                generated.append((value, seconds, replacements, score))
                return
            }

            for choice in tokenChoices[index] {
                let changed = characters[index] == "?" || choice != characters[index]
                candidate[index] = choice
                visit(index + 1, replacements + (changed ? 1 : 0))
            }
            candidate[index] = characters[index]
        }
        visit(0, 0)

        let ranked = generated.sorted {
            if $0.score != $1.score { return $0.score < $1.score }
            if $0.replacements != $1.replacements { return $0.replacements < $1.replacements }
            return $0.value < $1.value
        }
        guard let best = ranked.first else { return nil }
        if let second = ranked.dropFirst().first,
           second.score - best.score < 0.75 {
            return nil
        }

        return RinkLensClockContinuityResolution(
            value: best.value,
            seconds: best.seconds,
            replacementCount: best.replacements,
            diagnostic: "raw=\(compact) resolved=\(best.value) anchor=\(anchorSeconds) elapsed=\(String(format: "%.2f", elapsedSeconds))s replacements=\(best.replacements) candidates=\(ranked.count)"
        )
    }
}

/// UX16d10 owns only bounded pending evidence. The accepted physical-board anchor
/// remains in HockeyScoreboardViewModel; this value object prevents a stale single-
/// source, reversal or large-jump observation from being confirmed much later.
struct RinkLensBoundedClockEvidenceState: Equatable {
    private(set) var observationSequence: Int = 0

    private(set) var provisionalSeconds: Int?
    private(set) var provisionalLastAt: CFAbsoluteTime = 0
    private(set) var provisionalLastSequence: Int = 0
    private(set) var provisionalCount: Int = 0

    private(set) var reanchorDirection: GameClockDirection?
    private(set) var reanchorLastSeconds: Int?
    private(set) var reanchorLastAt: CFAbsoluteTime = 0
    private(set) var reanchorLastSequence: Int = 0
    private(set) var reanchorCount: Int = 0

    mutating func beginObservation(
        now: CFAbsoluteTime,
        maximumAge: CFTimeInterval = 3.0,
        maximumCycles: Int = 3
    ) {
        observationSequence &+= 1
        expireIfNeeded(now: now, maximumAge: maximumAge, maximumCycles: maximumCycles)
    }

    mutating func observeProvisional(
        seconds: Int,
        now: CFAbsoluteTime,
        maximumAge: CFTimeInterval = 3.0,
        maximumCycles: Int = 3
    ) -> Bool {
        expireIfNeeded(now: now, maximumAge: maximumAge, maximumCycles: maximumCycles)

        if let lastSeconds = provisionalSeconds,
           provisionalLastAt > 0,
           now - provisionalLastAt <= maximumAge,
           observationSequence - provisionalLastSequence <= maximumCycles {
            let elapsed = max(0.05, now - provisionalLastAt)
            let delta = seconds - lastSeconds
            let maximumDelta = max(2, Int(ceil(elapsed)) + 2)
            provisionalCount = (delta == 0 || abs(delta) <= maximumDelta)
                ? provisionalCount + 1
                : 1
        } else {
            provisionalCount = 1
        }

        provisionalSeconds = seconds
        provisionalLastAt = now
        provisionalLastSequence = observationSequence
        return provisionalCount >= 2
    }

    mutating func observeReanchor(
        seconds: Int,
        direction: GameClockDirection,
        now: CFAbsoluteTime,
        maximumAge: CFTimeInterval = 3.0,
        maximumCycles: Int = 3
    ) -> Bool {
        expireIfNeeded(now: now, maximumAge: maximumAge, maximumCycles: maximumCycles)

        if reanchorDirection == direction,
           let lastSeconds = reanchorLastSeconds,
           reanchorLastAt > 0,
           now - reanchorLastAt <= maximumAge,
           observationSequence - reanchorLastSequence <= maximumCycles {
            let elapsed = max(0.05, now - reanchorLastAt)
            let delta = seconds - lastSeconds
            let followsDirection = direction == .countUp ? delta > 0 : delta < 0
            let maximumDelta = max(2, Int(ceil(elapsed)) + 2)
            reanchorCount = (followsDirection && abs(delta) <= maximumDelta)
                ? reanchorCount + 1
                : 1
        } else {
            reanchorCount = 1
        }

        reanchorDirection = direction
        reanchorLastSeconds = seconds
        reanchorLastAt = now
        reanchorLastSequence = observationSequence
        return reanchorCount >= 2
    }

    mutating func expireIfNeeded(
        now: CFAbsoluteTime,
        maximumAge: CFTimeInterval = 3.0,
        maximumCycles: Int = 3
    ) {
        if provisionalLastAt > 0,
           (now - provisionalLastAt > maximumAge
                || observationSequence - provisionalLastSequence > maximumCycles) {
            clearProvisional()
        }
        if reanchorLastAt > 0,
           (now - reanchorLastAt > maximumAge
                || observationSequence - reanchorLastSequence > maximumCycles) {
            clearReanchor()
        }
    }

    mutating func clearProvisional() {
        provisionalSeconds = nil
        provisionalLastAt = 0
        provisionalLastSequence = 0
        provisionalCount = 0
    }

    mutating func clearReanchor() {
        reanchorDirection = nil
        reanchorLastSeconds = nil
        reanchorLastAt = 0
        reanchorLastSequence = 0
        reanchorCount = 0
    }

    mutating func clearPending() {
        clearProvisional()
        clearReanchor()
    }

    mutating func reset() {
        observationSequence = 0
        clearPending()
    }
}

struct RinkLensOCRPenaltyPair: Equatable {
    let player: Int
    let clock: String
}

private struct RinkLensOCRConfirmation<Value: Equatable>: Equatable {
    var value: Value?
    var count: Int = 0
    var lastObservedAt: CFAbsoluteTime = 0

    mutating func observe(
        _ next: Value?,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent(),
        within window: CFTimeInterval = 3.0
    ) -> Int {
        guard let next else {
            reset()
            return 0
        }

        if lastObservedAt > 0, now - lastObservedAt > window {
            value = nil
            count = 0
        }

        if value == next {
            count += 1
        } else {
            value = next
            count = 1
        }
        lastObservedAt = now
        return count
    }

    mutating func expireIfNeeded(
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent(),
        after window: CFTimeInterval = 3.0
    ) {
        guard lastObservedAt > 0, now - lastObservedAt > window else { return }
        reset()
    }

    mutating func reset() {
        value = nil
        count = 0
        lastObservedAt = 0
    }
}

/// Stateful confirmation memory for continuous Broadcast OCR. This state is
/// intentionally separate from ScoreboardState: observations may be pending
/// without becoming public state or producing broadcast events.
fileprivate struct RinkLensOCRPenaltySequenceConfirmation: Equatable {
    var player: Int?
    var playerObservedAt: CFAbsoluteTime = 0
    var lastClockSeconds: Int?
    var latestClock: String?
    var clockObservedAt: CFAbsoluteTime = 0
    var lastPairObservedAt: CFAbsoluteTime = 0
    var count: Int = 0
    var blankPairCount: Int = 0
    var blankPairObservedAt: CFAbsoluteTime = 0
    var openedByPlayerHash: Bool = false

    /// Build 531: player and timer evidence are allowed to arrive on adjacent
    /// full-budget passes. A running penalty is confirmed by a stable player plus
    /// a monotonically decreasing timer, not by requiring an identical timer text
    /// twice. This matches the physical board where 1:58 -> 1:55 is the same
    /// penalty, while a stopped board still requires a repeated timer value.
    mutating func observeComponents(
        player observedPlayer: Int?,
        clock observedClock: String?,
        playerTrusted: Bool,
        clockTrusted: Bool,
        allowDescendingTimer: Bool,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent(),
        within window: CFTimeInterval = RinkLensOCRServiceContract.penaltyEvidenceWindow
    ) -> (pair: RinkLensOCRPenaltyPair, count: Int)? {
        expireComponentsIfNeeded(now: now, after: window)
        let wasComplete = player != nil && latestClock != nil
        if playerTrusted || clockTrusted {
            clearBlankEvidence()
        }

        if playerTrusted,
           let observedPlayer,
           (1...99).contains(observedPlayer) {
            if player != nil, player != observedPlayer {
                lastClockSeconds = nil
                latestClock = nil
                clockObservedAt = 0
                lastPairObservedAt = 0
                count = 0
            }
            player = observedPlayer
            playerObservedAt = now
        }

        var parsedClockSeconds: Int?
        // Build 547: a timer has no independent lifecycle. Ignore timer-only
        // evidence until the associated player number exists in this transaction.
        if player != nil,
           clockTrusted,
           let observedClock,
           let seconds = Self.clockSeconds(observedClock),
           seconds > 0 {
            parsedClockSeconds = seconds
            latestClock = observedClock
            clockObservedAt = now
        }

        guard let player,
              let latestClock,
              let currentClockSeconds = parsedClockSeconds ?? lastClockSeconds,
              now - playerObservedAt <= window,
              now - clockObservedAt <= window else {
            return nil
        }

        // Do not advance confirmation merely because the player field repeated
        // while an old timer remained cached. A fresh timer, or the player that
        // completes a timer-first pair, is required for each pair observation.
        let completedPairThisPass = clockTrusted || (!wasComplete && playerTrusted)
        guard completedPairThisPass else {
            return (RinkLensOCRPenaltyPair(player: player, clock: latestClock), count)
        }

        let continuesSequence: Bool
        if let previousSeconds = lastClockSeconds,
           lastPairObservedAt > 0 {
            let elapsed = max(0.05, now - lastPairObservedAt)
            if allowDescendingTimer {
                // The penalty display is independent evidence of board movement.
                // Do not require the main game Clock to have established authority
                // before accepting a stable player with a plausible descending
                // penalty timer. Only a positively confirmed stopped board requires
                // exact timer equality.
                let maximumDrop = max(3, min(10, Int(ceil(elapsed)) + 4))
                continuesSequence = currentClockSeconds <= previousSeconds
                    && previousSeconds - currentClockSeconds <= maximumDrop
            } else {
                continuesSequence = currentClockSeconds == previousSeconds
            }
        } else {
            continuesSequence = false
        }

        if continuesSequence {
            count += 1
        } else {
            count = 1
        }
        lastClockSeconds = currentClockSeconds
        lastPairObservedAt = now
        return (RinkLensOCRPenaltyPair(player: player, clock: latestClock), count)
    }

    /// Two separate fresh frames must agree that both cells are blank before an
    /// active penalty may be removed. A single empty/deadline frame is never enough.
    mutating func observeBlankPair(
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent(),
        within window: CFTimeInterval = 4.0
    ) -> Int {
        if blankPairObservedAt > 0, now - blankPairObservedAt > window {
            blankPairCount = 0
        }
        blankPairCount += 1
        blankPairObservedAt = now
        return blankPairCount
    }

    mutating func clearBlankEvidence() {
        blankPairCount = 0
        blankPairObservedAt = 0
    }

    mutating func expireComponentsIfNeeded(
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent(),
        after window: CFTimeInterval = RinkLensOCRServiceContract.penaltyEvidenceWindow
    ) {
        if playerObservedAt > 0, now - playerObservedAt > window {
            player = nil
            playerObservedAt = 0
        }
        if clockObservedAt > 0, now - clockObservedAt > window {
            lastClockSeconds = nil
            latestClock = nil
            clockObservedAt = 0
            lastPairObservedAt = 0
            count = 0
        }
        if player == nil || latestClock == nil {
            lastPairObservedAt = 0
            count = 0
        }
    }

    var hasCompleteComponents: Bool {
        player != nil && latestClock != nil
    }

    var hasPendingComponents: Bool {
        // A timer-only fragment never creates pending work. Player identity is the
        // authority that opens and owns a penalty transaction.
        player != nil || count > 0 || blankPairCount > 0
    }

    mutating func reset() {
        player = nil
        playerObservedAt = 0
        lastClockSeconds = nil
        latestClock = nil
        clockObservedAt = 0
        lastPairObservedAt = 0
        count = 0
        openedByPlayerHash = false
        clearBlankEvidence()
    }

    private static func clockSeconds(_ value: String) -> Int? {
        let parts = value.split(separator: ":")
        guard parts.count == 2,
              let minutes = Int(parts[0]),
              let seconds = Int(parts[1]),
              minutes >= 0,
              (0...59).contains(seconds) else { return nil }
        return minutes * 60 + seconds
    }
}

struct OCREvidenceStore: Equatable {
    fileprivate var baselineClock = RinkLensOCRConfirmation<String>()
    fileprivate var baselineHomeScore = RinkLensOCRConfirmation<Int>()
    fileprivate var baselineAwayScore = RinkLensOCRConfirmation<Int>()
    fileprivate var baselinePeriod = RinkLensOCRConfirmation<Int>()
    fileprivate var baselineEstablishedKeys: Set<OCRRegionKey> = []
    fileprivate var penaltyBaselineEstablishedSlots: Set<RinkLensMatchPenaltySlot> = []
    fileprivate var penaltyBaselineAcquisitionStartedAt: CFAbsoluteTime?

    init(baselineEstablished: Bool = false) {
        if baselineEstablished {
            baselineEstablishedKeys = [.clock, .homeScore, .awayScore, .period]
        }
    }
    fileprivate var homeScore = RinkLensOCRConfirmation<Int>()
    fileprivate var awayScore = RinkLensOCRConfirmation<Int>()
    fileprivate var period = RinkLensOCRConfirmation<Int>()
    fileprivate var penalties: [RinkLensMatchPenaltySlot: RinkLensOCRPenaltySequenceConfirmation] = [:]
    fileprivate var penaltyClockAuthority = RinkLensPenaltyClockAuthorityState()

    mutating func reset() {
        baselineClock.reset()
        baselineHomeScore.reset()
        baselineAwayScore.reset()
        baselinePeriod.reset()
        baselineEstablishedKeys.removeAll()
        penaltyBaselineEstablishedSlots.removeAll()
        penaltyBaselineAcquisitionStartedAt = nil
        homeScore.reset()
        awayScore.reset()
        period.reset()
        penalties.removeAll()
        penaltyClockAuthority.reset()
    }

    /// UX16d15: an operator-confirmed Test & Apply result is already a trusted
    /// physical-board baseline for that one static field. Keep this memory separate
    /// per field so an unresolved Period read cannot prevent Home/Away score tracking.
    mutating func seedOperatorConfirmedBaseline(for key: OCRRegionKey) {
        switch key {
        case .homeScore:
            baselineEstablishedKeys.insert(.homeScore)
            baselineHomeScore.reset()
            homeScore.reset()
        case .awayScore:
            baselineEstablishedKeys.insert(.awayScore)
            baselineAwayScore.reset()
            awayScore.reset()
        case .period:
            baselineEstablishedKeys.insert(.period)
            baselinePeriod.reset()
            period.reset()
        default:
            break
        }
    }

    /// UX16d15j Build 525: editing one saved OCR zone invalidates only that
    /// field's baseline and pending confirmation. An unrelated Period or score
    /// zone must not erase trusted evidence for the other static fields.
    mutating func invalidateBaseline(for key: OCRRegionKey) {
        switch key {
        case .homeScore:
            baselineEstablishedKeys.remove(.homeScore)
            baselineHomeScore.reset()
            homeScore.reset()
        case .awayScore:
            baselineEstablishedKeys.remove(.awayScore)
            baselineAwayScore.reset()
            awayScore.reset()
        case .period:
            baselineEstablishedKeys.remove(.period)
            baselinePeriod.reset()
            period.reset()
        case .homePenalty1Player, .homePenalty1Time:
            penaltyBaselineEstablishedSlots.remove(.home1)
            penalties[.home1]?.reset()
            penaltyClockAuthority.invalidate(slot: .home1)
        case .homePenalty2Player, .homePenalty2Time:
            penaltyBaselineEstablishedSlots.remove(.home2)
            penalties[.home2]?.reset()
            penaltyClockAuthority.invalidate(slot: .home2)
        case .awayPenalty1Player, .awayPenalty1Time:
            penaltyBaselineEstablishedSlots.remove(.away1)
            penalties[.away1]?.reset()
            penaltyClockAuthority.invalidate(slot: .away1)
        case .awayPenalty2Player, .awayPenalty2Time:
            penaltyBaselineEstablishedSlots.remove(.away2)
            penalties[.away2]?.reset()
            penaltyClockAuthority.invalidate(slot: .away2)
        default:
            break
        }
    }

    var pendingBaselineKeys: Set<OCRRegionKey> {
        // UX16d9: the game clock has its own sequence-aware authority. Requiring
        // three identical clock strings is invalid for a running timer and could
        // block or jump the public clock. Baseline confirmation remains for the
        // static score and period fields only.
        Set([OCRRegionKey.homeScore, .awayScore, .period])
            .subtracting(baselineEstablishedKeys)
    }

    var isBaselineEstablished: Bool { pendingBaselineKeys.isEmpty }

    var isPenaltyBaselineEstablished: Bool {
        penaltyBaselineEstablishedSlots.count == RinkLensMatchPenaltySlot.allCases.count
    }

    func isPenaltyBaselineEstablished(for slot: RinkLensMatchPenaltySlot) -> Bool {
        penaltyBaselineEstablishedSlots.contains(slot)
    }

    mutating func markPenaltyBaselineEstablished(for slot: RinkLensMatchPenaltySlot) {
        penaltyBaselineEstablishedSlots.insert(slot)
    }

    var pendingPenaltyBaselineKeys: Set<OCRRegionKey> {
        guard isBaselineEstablished else { return [] }
        // Build 547: the player-number zone is the sole existence authority.
        // Inactive slots baseline and hash-watch only the player cell; their timer
        // cell is not recognised until a player number has been confirmed.
        var keys: Set<OCRRegionKey> = []
        for slot in RinkLensMatchPenaltySlot.allCases where !penaltyBaselineEstablishedSlots.contains(slot) {
            switch slot {
            case .home1: keys.insert(.homePenalty1Player)
            case .home2: keys.insert(.homePenalty2Player)
            case .away1: keys.insert(.awayPenalty1Player)
            case .away2: keys.insert(.awayPenalty2Player)
            }
        }
        return keys
    }

    /// Build 533 lets the scheduler keep the exact pair that already has one
    /// player/timer/blank observation at the front of the next full-budget pass.
    /// This prevents the four-slot baseline rotation from allowing a four-second
    /// confirmation window to expire before the same pair is revisited.
    var pendingPenaltyEvidenceKeys: Set<OCRRegionKey> {
        var keys: Set<OCRRegionKey> = []
        for (slot, confirmation) in penalties where confirmation.hasPendingComponents {
            let pair: (OCRRegionKey, OCRRegionKey)
            switch slot {
            case .home1: pair = (.homePenalty1Player, .homePenalty1Time)
            case .home2: pair = (.homePenalty2Player, .homePenalty2Time)
            case .away1: pair = (.awayPenalty1Player, .awayPenalty1Time)
            case .away2: pair = (.awayPenalty2Player, .awayPenalty2Time)
            }
            // Blank/player verification remains player-only. The timer joins only
            // after a player number owns the transaction.
            keys.insert(pair.0)
            if confirmation.player != nil { keys.insert(pair.1) }
        }
        return keys
    }

    var baselineDiagnostic: String {
        isBaselineEstablished
            ? "established"
            : "pending \(pendingBaselineKeys.map(\.rawValue).sorted().joined(separator: ","))"
    }

    // UX16d13: compact, bounded evidence for All Logs. This makes it possible to
    // distinguish a scheduler failure from a confirmation/publication failure
    // without exposing or mutating private confirmation state elsewhere.
    var liveConfirmationDiagnostic: String {
        func item<T: Equatable>(_ name: String, _ confirmation: RinkLensOCRConfirmation<T>) -> String {
            let value = confirmation.value.map { String(describing: $0) } ?? "--"
            return "\(name)=\(value)/\(confirmation.count)"
        }
        return [
            "baseline=\(baselineDiagnostic)",
            item("baselineHome", baselineHomeScore),
            item("baselineAway", baselineAwayScore),
            item("baselinePeriod", baselinePeriod),
            item("home", homeScore),
            item("away", awayScore),
            item("period", period),
            "penaltyBaseline=\(penaltyBaselineEstablishedSlots.count)/\(RinkLensMatchPenaltySlot.allCases.count)"
        ].joined(separator: " ")
    }

    /// UX16d15e Build 520: fields that have already supplied the first credible
    /// observation and should be verified on the next admitted OCR pass rather
    /// than waiting for the normal Clock/static scheduler rotation.
    /// Build 542: pair-level completion is distinct from one accepted component.
    /// A player-only artefact must not be treated as a usable penalty pair or keep
    /// publication confirmation permanently urgent.
    func hasCompletePendingPenaltyPair(for playerKey: OCRRegionKey) -> Bool {
        guard let slot = Self.penaltySlot(for: playerKey) else { return false }
        return penalties[slot]?.hasCompleteComponents == true
    }

    mutating func expirePendingPenaltyEvidence(for playerKey: OCRRegionKey) {
        guard let slot = Self.penaltySlot(for: playerKey) else { return }
        penalties[slot]?.reset()
    }

    private static func penaltySlot(for key: OCRRegionKey) -> RinkLensMatchPenaltySlot? {
        switch key {
        case .homePenalty1Player, .homePenalty1Time: return .home1
        case .homePenalty2Player, .homePenalty2Time: return .home2
        case .awayPenalty1Player, .awayPenalty1Time: return .away1
        case .awayPenalty2Player, .awayPenalty2Time: return .away2
        default: return nil
        }
    }

    var pendingPriorityVerificationKeys: Set<OCRRegionKey> {
        var keys: Set<OCRRegionKey> = []
        if baselineHomeScore.count > 0 || homeScore.count > 0 { keys.insert(.homeScore) }
        if baselineAwayScore.count > 0 || awayScore.count > 0 { keys.insert(.awayScore) }
        if baselinePeriod.count > 0 || period.count > 0 { keys.insert(.period) }

        for (slot, confirmation) in penalties where confirmation.hasPendingComponents {
            let pair: (OCRRegionKey, OCRRegionKey)
            switch slot {
            case .home1: pair = (.homePenalty1Player, .homePenalty1Time)
            case .home2: pair = (.homePenalty2Player, .homePenalty2Time)
            case .away1: pair = (.awayPenalty1Player, .awayPenalty1Time)
            case .away2: pair = (.awayPenalty2Player, .awayPenalty2Time)
            }
            keys.insert(pair.0)
            if confirmation.player != nil { keys.insert(pair.1) }
        }
        // UX16d16c Build 538: an unresolved penalty *baseline* is ordinary
        // acquisition work, not publication confirmation. Treating all four
        // empty slots as urgent kept them permanently ahead of Home/Away score
        // changes. Only a slot that already holds fresh player/timer/blank
        // evidence receives immediate verification priority.
        keys.formUnion(pendingPenaltyEvidenceKeys)
        return keys
    }
}

/// Compatibility alias retained while call sites migrate. The single evidence
/// authority is `OCREvidenceStore`.
struct RinkLensOCRPublicationSafetyDecision: Equatable {
    let state: ScoreboardState
    let eventPolicy: RinkLensMatchEventPolicy
    let diagnosticText: String
}

/// UX16d15d Build 519 policy for the Calibration `Test & Apply` action.
/// The button itself is explicit operator confirmation, so any parser-accepted
/// numeric score or period may deliberately resynchronise the visible state.
/// Unattended continuous OCR still rejects non-sequential upward score jumps.
struct RinkLensTestOCRAutoApplyDecision: Equatable {
    let shouldAutoApply: Bool
    let reason: String
}

enum RinkLensTestOCRAutoApplyPolicy {
    static func evaluate(
        key: OCRRegionKey,
        candidateText: String,
        visibleState: ScoreboardState
    ) -> RinkLensTestOCRAutoApplyDecision {
        switch key {
        case .homeScore, .awayScore:
            guard let incoming = Int(candidateText), incoming >= 0 else {
                return RinkLensTestOCRAutoApplyDecision(
                    shouldAutoApply: false,
                    reason: "score candidate is not a valid non-negative number"
                )
            }
            let current = key == .homeScore ? visibleState.homeScore : visibleState.awayScore
            let reason: String
            if let current {
                reason = incoming == current
                    ? "operator-confirmed value matches the visible score"
                    : "operator-confirmed absolute score resynchronisation \(current)->\(incoming)"
            } else {
                reason = "operator-confirmed score baseline"
            }
            return RinkLensTestOCRAutoApplyDecision(
                shouldAutoApply: true,
                reason: reason
            )

        case .period:
            guard let incoming = Int(candidateText), incoming >= 0 else {
                return RinkLensTestOCRAutoApplyDecision(
                    shouldAutoApply: false,
                    reason: "period candidate is not a valid non-negative number"
                )
            }
            let reason: String
            if let current = visibleState.period {
                reason = incoming == current
                    ? "operator-confirmed value matches the visible period"
                    : "operator-confirmed absolute period resynchronisation \(current)->\(incoming)"
            } else {
                reason = "operator-confirmed period baseline"
            }
            return RinkLensTestOCRAutoApplyDecision(
                shouldAutoApply: true,
                reason: reason
            )

        default:
            return RinkLensTestOCRAutoApplyDecision(
                shouldAutoApply: true,
                reason: "operator-confirmed Test & Apply field"
            )
        }
    }
}

/// Shared unattended score-transition guard used by continuous OCR and the
/// Image Relay visual/metadata paths. Operator-confirmed calibration or manual
/// correction remains the only route for arbitrary absolute score changes.
nonisolated struct RinkLensUnattendedScoreTransitionDecision: Equatable {
    let isAllowed: Bool
    let reason: String
}

nonisolated enum RinkLensUnattendedScoreTransitionPolicy {
    static func evaluate(
        current: Int?,
        candidate: Int,
        operatorConfirmed: Bool = false
    ) -> RinkLensUnattendedScoreTransitionDecision {
        guard (0...99).contains(candidate) else {
            return .init(isAllowed: false, reason: "score-out-of-range")
        }
        if operatorConfirmed {
            return .init(isAllowed: true, reason: "operator-confirmed-absolute-score")
        }
        guard let current else {
            return .init(isAllowed: true, reason: "baseline-candidate-requires-local-confirmation")
        }
        if candidate == current {
            return .init(isAllowed: true, reason: "score-unchanged")
        }
        if candidate == current + 1 {
            return .init(isAllowed: true, reason: "sequential-score-increase")
        }
        if candidate == current - 1 {
            return .init(isAllowed: true, reason: "single-step-score-correction")
        }
        if candidate > current + 1 {
            return .init(isAllowed: false, reason: "operator-confirmation-required-upward-score-jump-\(current)->\(candidate)")
        }
        return .init(isAllowed: false, reason: "operator-confirmation-required-downward-score-jump-\(current)->\(candidate)")
    }
}

/// Converts continuous OCR observations into safe, confirmed MatchState
/// transitions. Large score resynchronisation and arbitrary penalty/period jumps
/// are deliberately unavailable here; Calibration Apply or manual controls own
/// those operator-confirmed corrections.
enum RinkLensOCRPublicationSafetyPolicy {
    private static let baselineConfirmationCount = 2
    private static let scoreConfirmationCount = 2
    private static let scoreCatchUpConfirmationCount = 3
    private static let periodConfirmationCount = 3
    private static let penaltyPairConfirmationCount = 2

    // UX16d15c Build 518: static fields are deliberately sampled less often than
    // the clock. Build 517 used the confirmation helper's three-second default,
    // while the observed full static verification cadence was approximately 5.8s.
    // Every correct second observation therefore expired and restarted at 1/2.
    // Keep evidence long enough to span two scheduled static passes, but still
    // bound it so an abandoned candidate cannot linger indefinitely.
    private static let staticFieldConfirmationWindow: CFTimeInterval = 12.0
    private static let periodConfirmationWindow: CFTimeInterval = 18.0

    static func evaluateContinuous(
        previous: ScoreboardState,
        candidate: ScoreboardState,
        evidence: RinkLensOCRPublicationEvidence,
        confirmedStoppedClock: Bool,
        hashTriggeredKeys: Set<OCRRegionKey>,
        localClockIsRunning: Bool,
        memory: inout OCREvidenceStore,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> RinkLensOCRPublicationSafetyDecision {
        var safe = candidate
        var events: RinkLensMatchEventPolicy = []
        var diagnostics: [String] = []
        memory.penaltyClockAuthority.noteTrustedGameClock(
            seconds: clockSeconds(candidate.clock ?? previous.clock),
            running: localClockIsRunning,
            now: now
        )
        if memory.penaltyBaselineAcquisitionStartedAt == nil {
            memory.penaltyBaselineAcquisitionStartedAt = now
        }

        // UX16d2f root correction: default/manual placeholder state is not a live
        // OCR baseline. After OCR starts or the capture generation changes, collect
        // a stable full-board snapshot and commit it with zero event permission.
        // Without this phase a real 18:18 / 1-0 / P1 board is incorrectly judged as
        // an implausible transition from stale 8:00 / 0-0 defaults.
        if !memory.isBaselineEstablished {
            var baselineState = previous
            // UX16d9: clock publication is already sequence-validated by the
            // monotonic clock authority before this policy is called. Preserve
            // that clock even while score/period baselines are still pending.
            baselineState.clock = candidate.clock ?? previous.clock
            var baselineNotes: [String] = []
            var baselineEvents: RinkLensMatchEventPolicy = []
            let pendingAtStart = memory.pendingBaselineKeys

            if pendingAtStart.contains(.clock), let field = evidence.field(.clock) {
                if let value = candidate.clock, evidence.highTrust(.clock, matching: value) {
                    let count = memory.baselineClock.observe(value, now: now, within: staticFieldConfirmationWindow)
                    baselineNotes.append("clock \(count)/\(baselineConfirmationCount)=\(value)")
                    if count >= baselineConfirmationCount {
                        memory.baselineEstablishedKeys.insert(.clock)
                        memory.baselineClock.reset()
                        baselineState.clock = value
                    }
                } else if !field.acceptedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    memory.baselineClock.reset()
                }
            }
            if pendingAtStart.contains(.homeScore), let field = evidence.field(.homeScore) {
                if let value = candidate.homeScore {
                    let trust = evidence.staticBaselineTrust(.homeScore, matching: String(value))
                    if trust != .none {
                        let count = memory.baselineHomeScore.observe(value, now: now, within: staticFieldConfirmationWindow)
                        let requiredCount = trust == .confirmedAgreement ? 1 : baselineConfirmationCount
                        baselineNotes.append("home \(trust.diagnosticLabel) \(count)/\(requiredCount)=\(value)")
                        if count >= requiredCount {
                            memory.baselineEstablishedKeys.insert(.homeScore)
                            memory.baselineHomeScore.reset()
                            baselineState.homeScore = value
                            baselineNotes.append("home physical baseline synchronised without event")
                        }
                    } else {
                        retainOrResetBaselineConfirmation(
                            field: field,
                            expectedValue: value,
                            confirmation: &memory.baselineHomeScore,
                            label: "home",
                            diagnostics: &baselineNotes
                        )
                    }
                }
            }
            if pendingAtStart.contains(.awayScore), let field = evidence.field(.awayScore) {
                if let value = candidate.awayScore {
                    let trust = evidence.staticBaselineTrust(.awayScore, matching: String(value))
                    if trust != .none {
                        let count = memory.baselineAwayScore.observe(value, now: now, within: staticFieldConfirmationWindow)
                        let requiredCount = trust == .confirmedAgreement ? 1 : baselineConfirmationCount
                        baselineNotes.append("away \(trust.diagnosticLabel) \(count)/\(requiredCount)=\(value)")
                        if count >= requiredCount {
                            memory.baselineEstablishedKeys.insert(.awayScore)
                            memory.baselineAwayScore.reset()
                            baselineState.awayScore = value
                            baselineNotes.append("away physical baseline synchronised without event")
                        }
                    } else {
                        retainOrResetBaselineConfirmation(
                            field: field,
                            expectedValue: value,
                            confirmation: &memory.baselineAwayScore,
                            label: "away",
                            diagnostics: &baselineNotes
                        )
                    }
                }
            }
            if pendingAtStart.contains(.period), let field = evidence.field(.period) {
                if let value = candidate.period {
                    let trust = evidence.staticBaselineTrust(.period, matching: String(value))
                    if trust != .none {
                        let count = memory.baselinePeriod.observe(value, now: now, within: periodConfirmationWindow)
                        let requiredCount = trust == .confirmedAgreement ? 1 : baselineConfirmationCount
                        baselineNotes.append("period \(trust.diagnosticLabel) \(count)/\(requiredCount)=\(value)")
                        if count >= requiredCount {
                            memory.baselineEstablishedKeys.insert(.period)
                            memory.baselinePeriod.reset()
                            baselineState.period = value
                            baselineState.periodLabel = String(value)
                        }
                    } else {
                        retainOrResetBaselineConfirmation(
                            field: field,
                            expectedValue: value,
                            confirmation: &memory.baselinePeriod,
                            label: "period",
                            diagnostics: &baselineNotes
                        )
                    }
                }
            }

            // UX16d15: baseline acquisition is genuinely fieldwise. A field that was
            // already established before this pass continues through its normal live
            // confirmation policy even while another static field is unresolved.
            // This prevents a bad/missing Period read from freezing both scores at the
            // last Test & Apply values.
            if !pendingAtStart.contains(.homeScore) {
                baselineState.homeScore = confirmedScore(
                    key: .homeScore,
                    previous: previous.homeScore,
                    incoming: candidate.homeScore,
                    evidence: evidence,
                    hashTriggered: hashTriggeredKeys.contains(.homeScore),
                    confirmation: &memory.homeScore,
                    now: now,
                    eventPolicy: &baselineEvents,
                    diagnostics: &baselineNotes
                )
            }
            if !pendingAtStart.contains(.awayScore) {
                baselineState.awayScore = confirmedScore(
                    key: .awayScore,
                    previous: previous.awayScore,
                    incoming: candidate.awayScore,
                    evidence: evidence,
                    hashTriggered: hashTriggeredKeys.contains(.awayScore),
                    confirmation: &memory.awayScore,
                    now: now,
                    eventPolicy: &baselineEvents,
                    diagnostics: &baselineNotes
                )
            }
            if !pendingAtStart.contains(.period) {
                let safePeriod = confirmedPeriod(
                    previousState: previous,
                    candidateState: candidate,
                    evidence: evidence,
                    confirmation: &memory.period,
                    now: now,
                    diagnostics: &baselineNotes
                )
                baselineState.period = safePeriod
                baselineState.periodLabel = safePeriod.map { String($0) } ?? previous.periodLabel
            }

            let pending = memory.pendingBaselineKeys.map(\.rawValue).sorted().joined(separator: ",")
            let status = memory.isBaselineEstablished
                ? "OCR fieldwise baseline complete without events"
                : "OCR fieldwise baseline pending [\(pending)]"
            return RinkLensOCRPublicationSafetyDecision(
                state: baselineState,
                eventPolicy: baselineEvents,
                diagnosticText: ([status] + baselineNotes).joined(separator: "; ")
            )
        }

        safe.homeScore = confirmedScore(
            key: .homeScore,
            previous: previous.homeScore,
            incoming: candidate.homeScore,
            evidence: evidence,
            hashTriggered: hashTriggeredKeys.contains(.homeScore),
            confirmation: &memory.homeScore,
            now: now,
            eventPolicy: &events,
            diagnostics: &diagnostics
        )
        safe.awayScore = confirmedScore(
            key: .awayScore,
            previous: previous.awayScore,
            incoming: candidate.awayScore,
            evidence: evidence,
            hashTriggered: hashTriggeredKeys.contains(.awayScore),
            confirmation: &memory.awayScore,
            now: now,
            eventPolicy: &events,
            diagnostics: &diagnostics
        )

        let safePeriod = confirmedPeriod(
            previousState: previous,
            candidateState: candidate,
            evidence: evidence,
            confirmation: &memory.period,
            now: now,
            diagnostics: &diagnostics
        )
        safe.period = safePeriod
        safe.periodLabel = safePeriod.map { String($0) } ?? previous.periodLabel

        for slot in RinkLensMatchPenaltySlot.allCases {
            applySafePenalty(
                slot: slot,
                previous: previous,
                candidate: candidate,
                evidence: evidence,
                confirmedStoppedClock: confirmedStoppedClock,
                playerHashTriggered: hashTriggeredKeys.contains(penaltyKeys(slot).player),
                localClockIsRunning: localClockIsRunning,
                now: now,
                memory: &memory,
                safe: &safe,
                events: &events,
                diagnostics: &diagnostics
            )
        }

        // Build 547 physical-board continuity: once a player-owned penalty is
        // anchored, its displayed remaining time follows the absolute movement of
        // the trusted game clock. Count-up and countdown clocks therefore remove
        // identical playing time. Predicted 0:00 retains the player until the
        // physical player-number zone confirms blank.
        applyGameClockPenaltyProjection(
            to: &safe,
            memory: memory,
            gameClockSeconds: clockSeconds(safe.clock ?? previous.clock),
            gameClockRunning: localClockIsRunning,
            diagnostics: &diagnostics
        )

        return RinkLensOCRPublicationSafetyDecision(
            state: safe,
            eventPolicy: events,
            diagnosticText: diagnostics.isEmpty ? "continuous OCR observations retained existing public state" : diagnostics.joined(separator: "; ")
        )
    }

    private static func clearPenalty(slot: RinkLensMatchPenaltySlot, in state: inout ScoreboardState) {
        switch slot {
        case .home1: state.homePenalty1Player = nil; state.homePenalty1Clock = nil
        case .home2: state.homePenalty2Player = nil; state.homePenalty2Clock = nil
        case .away1: state.awayPenalty1Player = nil; state.awayPenalty1Clock = nil
        case .away2: state.awayPenalty2Player = nil; state.awayPenalty2Clock = nil
        }
    }

    /// Preserve provisional baseline progress through blank/low-trust reads, but
    /// discard it when the recogniser accepts a different concrete value.
    private static func retainOrResetBaselineConfirmation(
        field: RinkLensOCRFieldEvidence,
        expectedValue: Int,
        confirmation: inout RinkLensOCRConfirmation<Int>,
        label: String,
        diagnostics: inout [String]
    ) {
        let accepted = field.acceptedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accepted.isEmpty else { return }
        if let acceptedValue = Int(accepted),
           let pendingValue = confirmation.value,
           acceptedValue != pendingValue {
            confirmation.reset()
            diagnostics.append("\(label) provisional baseline reset by contradictory accepted value \(acceptedValue)")
            return
        }
        diagnostics.append("\(label) matching low-trust baseline evidence ignored; pending evidence preserved for \(expectedValue)")
    }

    private static func confirmedScore(
        key: OCRRegionKey,
        previous: Int?,
        incoming: Int?,
        evidence: RinkLensOCRPublicationEvidence,
        hashTriggered: Bool,
        confirmation: inout RinkLensOCRConfirmation<Int>,
        now: CFAbsoluteTime,
        eventPolicy: inout RinkLensMatchEventPolicy,
        diagnostics: inout [String]
    ) -> Int? {
        // A clock-only pass must not erase a live event confirmation that was
        // opened by a changed score hash. Only a pass that actually processed
        // this score field may advance or reset its confirmation memory.
        guard evidence.field(key) != nil else { return previous }
        confirmation.expireIfNeeded(now: now, after: staticFieldConfirmationWindow)
        guard let incoming else {
            // UX16d8: a no-candidate frame is absence of evidence, not evidence
            // that the pending score was wrong. Keep confirmation progress until
            // a different accepted value arrives or the field window expires.
            return previous
        }
        guard let previous else {
            guard evidence.highTrust(key, matching: String(incoming)) else { return nil }
            let count = confirmation.observe(incoming, now: now, within: staticFieldConfirmationWindow)
            if count >= scoreConfirmationCount {
                confirmation.reset()
                diagnostics.append("\(key.rawValue) bootstrap confirmed at \(incoming)")
                return incoming
            }
            return nil
        }
        guard incoming != previous else {
            confirmation.reset()
            return previous
        }

        let highTrust = evidence.highTrust(key, matching: String(incoming))
        let structuralTrust = evidence.staticBaselineTrust(key, matching: String(incoming))
        guard highTrust || structuralTrust != .none else {
            // A rejected/weak read is absence of confirmation, not contradictory
            // evidence. Preserve any existing 1/2 observation until timeout or a
            // different accepted value arrives.
            diagnostics.append("\(key.rawValue) held low-trust live transition \(previous)->\(incoming); pending evidence preserved")
            return previous
        }

        if incoming == previous + 1 {
            // Build 551 simplified publication contract. Hashing opens the
            // transaction but is not an approval gate after the first observation.
            // Two matching trusted score reads publish directly through MatchState.
            // The separate global stopped-Clock candidate is deliberately removed:
            // it was expiring before the score pass and discarding correct OCR.
            let transactionAlreadyOpen = confirmation.count > 0 && confirmation.value == incoming
            guard hashTriggered || transactionAlreadyOpen else {
                diagnostics.append("\(key.rawValue) held +1 score change because no score-zone change transaction exists")
                return previous
            }

            let requiredCount = scoreConfirmationCount
            let count = confirmation.observe(incoming, now: now, within: staticFieldConfirmationWindow)
            guard count >= requiredCount else {
                diagnostics.append("\(key.rawValue) direct goal confirmation pending \(previous)->\(incoming) \(count)/\(requiredCount) trust=\(highTrust ? "confirmed" : structuralTrust.diagnosticLabel)")
                return previous
            }
            confirmation.reset()
            eventPolicy.insert(.score)
            diagnostics.append("\(key.rawValue) committed to Broadcast after two matching hash-opened reads \(previous)->\(incoming)")
            return incoming
        }

        // Build 533: if one genuine goal confirmation was lost, two later real
        // goals can leave the public score permanently two behind. Permit only a
        // tightly fenced +2 catch-up: three matching deterministic dual-mask
        // observations, no goal event permission, and no larger jump. This repairs
        // display truth without fabricating either of the missed goal events.
        if incoming == previous + 2 {
            let deterministicAgreement = evidence.field(key)?.deterministicAgreement == true
            guard highTrust && deterministicAgreement else {
                diagnostics.append("\(key.rawValue) held +2 catch-up \(previous)->\(incoming); deterministic dual-mask evidence required")
                return previous
            }
            let catchUpCount = confirmation.observe(incoming, now: now, within: staticFieldConfirmationWindow)
            guard catchUpCount >= scoreCatchUpConfirmationCount else {
                diagnostics.append("\(key.rawValue) trusted catch-up pending \(previous)->\(incoming) \(catchUpCount)/\(scoreCatchUpConfirmationCount); goal events fenced")
                return previous
            }
            confirmation.reset()
            diagnostics.append("\(key.rawValue) trusted catch-up committed \(previous)->\(incoming) after three dual-mask observations; goal events fenced")
            return incoming
        }

        // UX16d15: a live hockey score normally increases by one goal at a time.
        // Larger upward changes remain blocked unless the narrow +2 catch-up above
        // is proven. Downward corrections may still repair a false-high display
        // without creating a goal event.
        guard incoming < previous else {
            confirmation.reset()
            diagnostics.append("\(key.rawValue) held upward non-goal jump \(previous)->\(incoming); explicit Apply confirmation required")
            return previous
        }

        let difference = previous - incoming
        guard difference <= 10 else {
            confirmation.reset()
            diagnostics.append("\(key.rawValue) rejected excessive downward correction \(previous)->\(incoming)")
            return previous
        }
        let requiredCorrectionCount = 2
        let correctionCount = confirmation.observe(incoming, now: now, within: staticFieldConfirmationWindow)
        guard correctionCount >= requiredCorrectionCount else {
            diagnostics.append("\(key.rawValue) pending downward display correction \(previous)->\(incoming) \(correctionCount)/\(requiredCorrectionCount)")
            return previous
        }
        confirmation.reset()
        diagnostics.append("\(key.rawValue) committed to Broadcast downward display correction \(previous)->\(incoming); goal event fenced")
        return incoming
    }

    private static func confirmedPeriod(
        previousState: ScoreboardState,
        candidateState: ScoreboardState,
        evidence: RinkLensOCRPublicationEvidence,
        confirmation: inout RinkLensOCRConfirmation<Int>,
        now: CFAbsoluteTime,
        diagnostics: inout [String]
    ) -> Int? {
        let previous = previousState.period
        guard evidence.field(.period) != nil else { return previous }
        confirmation.expireIfNeeded(now: now, after: periodConfirmationWindow)
        guard let incoming = candidateState.period else {
            // Missing/partial Period OCR is not contradictory evidence.
            return previous
        }
        guard incoming != previous else {
            confirmation.reset()
            return previous
        }
        guard let previous else {
            guard evidence.highTrust(.period, matching: String(incoming)) else {
                return nil
            }
            let count = confirmation.observe(incoming, now: now, within: periodConfirmationWindow)
            guard count >= periodConfirmationCount else {
                diagnostics.append("period bootstrap pending -->\(incoming) \(count)/\(periodConfirmationCount)")
                return nil
            }
            confirmation.reset()
            diagnostics.append("period bootstrap aligned to \(incoming); intermission event fenced")
            return incoming
        }
        guard evidence.highTrust(.period, matching: String(incoming)) else {
            diagnostics.append("period held low-trust transition \(previous)->\(incoming); pending evidence preserved")
            return previous
        }

        let provenPeriodReset: Bool
        if incoming == previous + 1,
           let oldClock = clockSeconds(previousState.clock), oldClock <= 10,
           let newClock = clockSeconds(candidateState.clock), newClock >= 15 * 60 {
            provenPeriodReset = true
        } else {
            provenPeriodReset = false
        }

        let count = confirmation.observe(incoming, now: now, within: periodConfirmationWindow)
        guard count >= periodConfirmationCount else {
            let mode = provenPeriodReset ? "reset" : "display-correction"
            diagnostics.append("period pending \(mode) \(previous)->\(incoming) \(count)/\(periodConfirmationCount)")
            return previous
        }
        confirmation.reset()

        if provenPeriodReset {
            // Deliberately no .period event permission: OCR may align the displayed
            // period after a proven reset, but only the operator may launch an
            // intermission reel or next-period prompt.
            diagnostics.append("period display aligned and committed to Broadcast \(previous)->\(incoming); intermission event fenced")
            return incoming
        }

        // UX16d13: when the clock itself is unreadable, a stale visible period must
        // still be repairable from three repeated dual-mask observations. This is
        // display alignment only and can never launch intermission side effects.
        guard (1...5).contains(incoming), abs(incoming - previous) <= 4 else {
            diagnostics.append("period rejected implausible display correction \(previous)->\(incoming)")
            return previous
        }
        diagnostics.append("period absolute display correction committed to Broadcast \(previous)->\(incoming); intermission event fenced")
        return incoming
    }

    private static func applySafePenalty(
        slot: RinkLensMatchPenaltySlot,
        previous: ScoreboardState,
        candidate: ScoreboardState,
        evidence: RinkLensOCRPublicationEvidence,
        confirmedStoppedClock: Bool,
        playerHashTriggered: Bool,
        localClockIsRunning: Bool,
        now: CFAbsoluteTime,
        memory: inout OCREvidenceStore,
        safe: inout ScoreboardState,
        events: inout RinkLensMatchEventPolicy,
        diagnostics: inout [String]
    ) {
        let old = penaltyPair(slot: slot, in: previous)
        let candidateValues = penaltyValues(slot: slot, in: candidate)
        var confirmation = memory.penalties[slot] ?? RinkLensOCRPenaltySequenceConfirmation()
        defer { memory.penalties[slot] = confirmation }

        let keys = penaltyKeys(slot)
        let playerEvidence = evidence.field(keys.player)
        let timeEvidence = evidence.field(keys.time)
        guard playerEvidence != nil || timeEvidence != nil else {
            // Preserve an in-progress player-owned transaction through intervening
            // Clock/score passes. Timer-only evidence can never open this state.
            retainPenalty(slot: slot, from: previous, in: &safe)
            return
        }

        let playerTrusted = playerEvidence?.isHighTrust == true
            && playerEvidence?.isDashDominated == false
        let timeTrusted = timeEvidence?.isHighTrust == true
            && timeEvidence?.isDashDominated == false
        let playerConfirmedBlank = playerEvidence?.confirmedBlank == true
        if playerHashTriggered {
            confirmation.openedByPlayerHash = true
        }
        let gameClockSeconds = clockSeconds(candidate.clock ?? previous.clock)
        // Build 551: player-zone hashing opens a local two-read transaction.
        // New-penalty publication no longer depends on the separate global
        // stopped-Clock candidate, which was expiring before paired OCR completed.

        // A timer has no independent lifecycle. A timer-only fragment is ignored
        // before it can create confirmation memory or scheduler urgency.
        if candidateValues.player == nil,
           confirmation.player == nil,
           old == nil,
           timeEvidence != nil,
           playerEvidence == nil {
            confirmation.reset()
            retainPenalty(slot: slot, from: previous, in: &safe)
            diagnostics.append("\(slot.rawValue) ignored timer-only evidence because no player number owns the slot")
            return
        }

        // Wholly unusable noise must terminate immediately rather than keeping a
        // half-open penalty transaction ahead of Clock and score work.
        if !memory.isPenaltyBaselineEstablished(for: slot),
           !playerTrusted,
           !playerConfirmedBlank {
            confirmation.reset()
            retainPenalty(slot: slot, from: previous, in: &safe)
            diagnostics.append("\(slot.rawValue) ignored unusable player-zone baseline observation")
            return
        }

        // Player-number-only baseline. Inactive timer zones are deliberately not
        // sampled until a player exists.
        if !memory.isPenaltyBaselineEstablished(for: slot) {
            if playerConfirmedBlank {
                let blankCount = confirmation.observeBlankPair()
                guard blankCount >= 2 else {
                    retainPenalty(slot: slot, from: previous, in: &safe)
                    diagnostics.append("\(slot.rawValue) blank player baseline pending \(blankCount)/2")
                    return
                }
                confirmation.reset()
                memory.markPenaltyBaselineEstablished(for: slot)
                memory.penaltyClockAuthority.invalidate(slot: slot)
                setPenalty(slot: slot, pair: nil, in: &safe)
                diagnostics.append("\(slot.rawValue) blank player baseline established without timer OCR")
                return
            }

            confirmation.clearBlankEvidence()
            let baselineComponents = confirmation.observeComponents(
                player: playerEvidence != nil ? candidateValues.player : nil,
                clock: timeEvidence != nil ? candidateValues.clock : nil,
                playerTrusted: playerTrusted,
                clockTrusted: timeTrusted,
                allowDescendingTimer: !confirmedStoppedClock,
                now: now
            )
            guard let observed = baselineComponents?.pair,
                  let observedSeconds = clockSeconds(observed.clock) else {
                retainPenalty(slot: slot, from: previous, in: &safe)
                diagnostics.append("\(slot.rawValue) player-owned active baseline awaiting associated timer")
                return
            }

            let hashOpenedTransaction = confirmation.openedByPlayerHash
            let baselineStartedAt = memory.penaltyBaselineAcquisitionStartedAt ?? now
            let withinStartupArmingWindow = now - baselineStartedAt <= 8.0
            guard hashOpenedTransaction || withinStartupArmingWindow else {
                confirmation.reset()
                retainPenalty(slot: slot, from: previous, in: &safe)
                diagnostics.append("\(slot.rawValue) held late active baseline because no player-zone change transaction exists")
                return
            }

            let authority: RinkLensPenaltyClockAuthorityState.Decision
            if hashOpenedTransaction {
                authority = memory.penaltyClockAuthority.establishLivePenalty(
                    slot: slot,
                    player: observed.player,
                    observedPenaltySeconds: observedSeconds,
                    gameClockSeconds: gameClockSeconds,
                    now: now
                )
            } else {
                authority = memory.penaltyClockAuthority.establishExistingBaseline(
                    slot: slot,
                    player: observed.player,
                    observedPenaltySeconds: observedSeconds,
                    gameClockSeconds: gameClockSeconds,
                    now: now
                )
            }
            guard authority.acceptedSeconds != nil else {
                confirmation.reset()
                retainPenalty(slot: slot, from: previous, in: &safe)
                diagnostics.append("\(slot.rawValue) rejected active baseline: \(authority.reason)")
                return
            }

            let baselineCount = baselineComponents?.count ?? 0
            guard baselineCount >= penaltyPairConfirmationCount else {
                retainPenalty(slot: slot, from: previous, in: &safe)
                diagnostics.append("\(slot.rawValue) active baseline pending \(baselineCount)/\(penaltyPairConfirmationCount) player=\(observed.player) timer=\(observed.clock)")
                return
            }

            confirmation.reset()
            memory.markPenaltyBaselineEstablished(for: slot)
            setPenalty(slot: slot, pair: observed, in: &safe)
            if hashOpenedTransaction {
                events.insert(.penalty)
                diagnostics.append("\(slot.rawValue) committed to Broadcast after two matching player+timer reads: \(authority.reason)")
            } else {
                diagnostics.append("\(slot.rawValue) existing active penalty synchronised event-free during startup arming")
            }
            return
        }

        // The player-number zone is authoritative for physical clear. The timer is
        // ignored once the player is confirmed blank, even if residual digits remain.
        if old != nil, playerConfirmedBlank {
            let blankCount = confirmation.observeBlankPair()
            guard blankCount >= 2 else {
                retainPenalty(slot: slot, from: previous, in: &safe)
                diagnostics.append("\(slot.rawValue) physical player clear pending \(blankCount)/2")
                return
            }
            confirmation.reset()
            memory.penaltyClockAuthority.invalidate(slot: slot)
            setPenalty(slot: slot, pair: nil, in: &safe)
            diagnostics.append("\(slot.rawValue) cleared atomically from confirmed blank player-number zone")
            return
        }
        if playerEvidence != nil || timeEvidence != nil {
            confirmation.clearBlankEvidence()
        }

        if let old {
            // A direct player replacement is a new physical penalty transaction and
            // therefore requires a material player-zone change plus stopped/recent-
            // restart context. It cannot be inferred from timer movement.
            if playerTrusted,
               let newPlayer = candidateValues.player,
               newPlayer != old.player {
                guard confirmation.openedByPlayerHash else {
                    confirmation.reset()
                    retainPenalty(slot: slot, from: previous, in: &safe)
                    diagnostics.append("\(slot.rawValue) held changed player because no player-zone change transaction exists")
                    return
                }
                let replacement = confirmation.observeComponents(
                    player: newPlayer,
                    clock: candidateValues.clock,
                    playerTrusted: true,
                    clockTrusted: timeTrusted,
                    allowDescendingTimer: true,
                    now: now
                )
                guard let observed = replacement?.pair,
                      let observedSeconds = clockSeconds(observed.clock),
                      (replacement?.count ?? 0) >= penaltyPairConfirmationCount else {
                    retainPenalty(slot: slot, from: previous, in: &safe)
                    diagnostics.append("\(slot.rawValue) replacement penalty player/timer pairing pending")
                    return
                }
                memory.penaltyClockAuthority.invalidate(slot: slot)
                let authority = memory.penaltyClockAuthority.establishLivePenalty(
                    slot: slot,
                    player: observed.player,
                    observedPenaltySeconds: observedSeconds,
                    gameClockSeconds: gameClockSeconds,
                    now: now
                )
                guard authority.acceptedSeconds != nil else {
                    confirmation.reset()
                    retainPenalty(slot: slot, from: previous, in: &safe)
                    diagnostics.append("\(slot.rawValue) replacement rejected: \(authority.reason)")
                    return
                }
                confirmation.reset()
                setPenalty(slot: slot, pair: observed, in: &safe)
                events.insert(.penalty)
                diagnostics.append("\(slot.rawValue) replacement penalty committed: \(authority.reason)")
                return
            }

            guard timeTrusted,
                  let freshClock = candidateValues.clock,
                  let freshSeconds = clockSeconds(freshClock) else {
                confirmation.reset()
                retainPenalty(slot: slot, from: previous, in: &safe)
                diagnostics.append("\(slot.rawValue) retained player-owned penalty; no fresh trusted timer")
                return
            }

            if memory.penaltyClockAuthority.anchor(for: slot) == nil,
               let oldSeconds = clockSeconds(old.clock) {
                _ = memory.penaltyClockAuthority.establishExistingBaseline(
                    slot: slot,
                    player: old.player,
                    observedPenaltySeconds: oldSeconds,
                    gameClockSeconds: gameClockSeconds,
                    now: now
                )
            }

            let authority = memory.penaltyClockAuthority.validateExistingTimer(
                slot: slot,
                player: old.player,
                observedPenaltySeconds: freshSeconds,
                gameClockSeconds: gameClockSeconds,
                gameClockRunning: localClockIsRunning && !confirmedStoppedClock,
                now: now
            )
            guard authority.acceptedSeconds != nil else {
                confirmation.reset()
                retainPenalty(slot: slot, from: previous, in: &safe)
                diagnostics.append("\(slot.rawValue) retained confirmed penalty: \(authority.reason)")
                return
            }

            confirmation.reset()
            setPenalty(
                slot: slot,
                pair: RinkLensOCRPenaltyPair(player: old.player, clock: freshClock),
                in: &safe
            )
            diagnostics.append("\(slot.rawValue) updated from game-clock-correlated timer: \(authority.reason)")
            return
        }

        // Build 551 simplified new-penalty transaction. A material player-zone
        // change opens the transaction; two trusted player+timer observations then
        // publish it. The timer may descend between reads if the board restarts.
        guard confirmation.openedByPlayerHash else {
            confirmation.reset()
            retainPenalty(slot: slot, from: previous, in: &safe)
            diagnostics.append("\(slot.rawValue) held new penalty because no player-number change transaction exists")
            return
        }

        let observedComponents = confirmation.observeComponents(
            player: candidateValues.player,
            clock: candidateValues.clock,
            playerTrusted: playerTrusted,
            clockTrusted: timeTrusted,
            allowDescendingTimer: true,
            now: now
        )
        guard let observed = observedComponents?.pair,
              let observedSeconds = clockSeconds(observed.clock) else {
            retainPenalty(slot: slot, from: previous, in: &safe)
            diagnostics.append("\(slot.rawValue) player retained; associated timer acquisition pending")
            return
        }

        let count = observedComponents?.count ?? 0
        guard count >= penaltyPairConfirmationCount else {
            retainPenalty(slot: slot, from: previous, in: &safe)
            diagnostics.append("\(slot.rawValue) direct player+timer confirmation pending \(count)/\(penaltyPairConfirmationCount)")
            return
        }

        let authority = memory.penaltyClockAuthority.establishLivePenalty(
            slot: slot,
            player: observed.player,
            observedPenaltySeconds: observedSeconds,
            gameClockSeconds: gameClockSeconds,
            now: now
        )
        guard authority.acceptedSeconds != nil else {
            confirmation.reset()
            retainPenalty(slot: slot, from: previous, in: &safe)
            diagnostics.append("\(slot.rawValue) rejected new penalty: \(authority.reason)")
            return
        }

        confirmation.reset()
        setPenalty(slot: slot, pair: observed, in: &safe)
        events.insert(.penalty)
        diagnostics.append("\(slot.rawValue) committed to Broadcast after two matching player+timer reads: \(authority.reason)")
    }

    private static func penaltyValues(
        slot: RinkLensMatchPenaltySlot,
        in state: ScoreboardState
    ) -> (player: Int?, clock: String?) {
        switch slot {
        case .home1: return (state.homePenalty1Player, state.homePenalty1Clock)
        case .home2: return (state.homePenalty2Player, state.homePenalty2Clock)
        case .away1: return (state.awayPenalty1Player, state.awayPenalty1Clock)
        case .away2: return (state.awayPenalty2Player, state.awayPenalty2Clock)
        }
    }

    private static func penaltyPair(slot: RinkLensMatchPenaltySlot, in state: ScoreboardState) -> RinkLensOCRPenaltyPair? {
        let values: (Int?, String?)
        switch slot {
        case .home1: values = (state.homePenalty1Player, state.homePenalty1Clock)
        case .home2: values = (state.homePenalty2Player, state.homePenalty2Clock)
        case .away1: values = (state.awayPenalty1Player, state.awayPenalty1Clock)
        case .away2: values = (state.awayPenalty2Player, state.awayPenalty2Clock)
        }
        guard let player = values.0,
              (1...99).contains(player),
              let clock = values.1,
              let seconds = clockSeconds(clock),
              seconds >= 0 else { return nil }
        return RinkLensOCRPenaltyPair(player: player, clock: clock)
    }

    private static func retainPenalty(
        slot: RinkLensMatchPenaltySlot,
        from previous: ScoreboardState,
        in state: inout ScoreboardState
    ) {
        switch slot {
        case .home1:
            state.homePenalty1Player = previous.homePenalty1Player
            state.homePenalty1Clock = previous.homePenalty1Clock
        case .home2:
            state.homePenalty2Player = previous.homePenalty2Player
            state.homePenalty2Clock = previous.homePenalty2Clock
        case .away1:
            state.awayPenalty1Player = previous.awayPenalty1Player
            state.awayPenalty1Clock = previous.awayPenalty1Clock
        case .away2:
            state.awayPenalty2Player = previous.awayPenalty2Player
            state.awayPenalty2Clock = previous.awayPenalty2Clock
        }
    }

    private static func setPenalty(slot: RinkLensMatchPenaltySlot, pair: RinkLensOCRPenaltyPair?, in state: inout ScoreboardState) {
        switch slot {
        case .home1:
            state.homePenalty1Player = pair?.player
            state.homePenalty1Clock = pair?.clock
        case .home2:
            state.homePenalty2Player = pair?.player
            state.homePenalty2Clock = pair?.clock
        case .away1:
            state.awayPenalty1Player = pair?.player
            state.awayPenalty1Clock = pair?.clock
        case .away2:
            state.awayPenalty2Player = pair?.player
            state.awayPenalty2Clock = pair?.clock
        }
    }

    private static func applyGameClockPenaltyProjection(
        to state: inout ScoreboardState,
        memory: OCREvidenceStore,
        gameClockSeconds: Int?,
        gameClockRunning: Bool,
        diagnostics: inout [String]
    ) {
        guard let gameClockSeconds else { return }
        for slot in RinkLensMatchPenaltySlot.allCases {
            guard let pair = penaltyPair(slot: slot, in: state),
                  let anchor = memory.penaltyClockAuthority.anchor(for: slot),
                  anchor.player == pair.player,
                  let expected = memory.penaltyClockAuthority.expectedRemainingSeconds(
                    slot: slot,
                    currentGameClockSeconds: gameClockSeconds,
                    gameClockRunning: gameClockRunning
                  ) else { continue }

            let projected = formatPenaltyClock(seconds: expected)
            guard projected != pair.clock else { continue }
            setPenalty(
                slot: slot,
                pair: RinkLensOCRPenaltyPair(player: pair.player, clock: projected),
                in: &state
            )
            diagnostics.append(
                expected == 0
                    ? "\(slot.rawValue) projected to 0:00 from trusted game-clock movement; waiting for physical player clear"
                    : "\(slot.rawValue) projected to \(projected) from trusted game-clock movement"
            )
        }
    }

    private static func formatPenaltyClock(seconds: Int) -> String {
        let clamped = max(0, seconds)
        return String(format: "%d:%02d", clamped / 60, clamped % 60)
    }

    private static func penaltyKeys(_ slot: RinkLensMatchPenaltySlot) -> (player: OCRRegionKey, time: OCRRegionKey) {
        switch slot {
        case .home1: return (.homePenalty1Player, .homePenalty1Time)
        case .home2: return (.homePenalty2Player, .homePenalty2Time)
        case .away1: return (.awayPenalty1Player, .awayPenalty1Time)
        case .away2: return (.awayPenalty2Player, .awayPenalty2Time)
        }
    }

    private static func clockSeconds(_ value: String?) -> Int? {
        guard let value else { return nil }
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard parts.count == 2,
              let minutes = Int(parts[0]),
              let seconds = Int(parts[1]),
              minutes >= 0,
              (0...59).contains(seconds) else { return nil }
        return minutes * 60 + seconds
    }
}

#endif
