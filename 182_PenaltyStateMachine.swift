// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
import Foundation

// MARK: - v0.8.8m15c Penalty State Machine Hardening

/// Owns penalty OCR confirmation state that was previously stored directly in
/// HockeyScoreboardViewModel.
///
/// This pass deliberately hardens the API before aggressively deleting penalty
/// logic from the main ViewModel. The state machine now owns candidate counts,
/// locked player state and missing-read counters, while the authoritative
/// OCREvidenceStore owns timer validation and physical slot identity.
final class PenaltyStateMachine {
    // MARK: Candidate / confirmation state

    private(set) var penaltyPlayerMissingCount: [OCRRegionKey: Int] = [:]
    private(set) var penaltyPlayerLockedValues: [OCRRegionKey: Int] = [:]
    private(set) var penaltyPlayerChangeCandidate: [OCRRegionKey: Int] = [:]
    private(set) var penaltyPlayerChangeCandidateCount: [OCRRegionKey: Int] = [:]

    // MARK: Existing confirmation thresholds

    let penaltyPlayerLockConfirmationCount = 2
    let penaltyPlayerRemovalConfirmationCount = 5
    let penaltyPlayerChangeConfirmationCount = 3

    // MARK: Player lock API

    func lockedPlayer(for key: OCRRegionKey) -> Int? {
        penaltyPlayerLockedValues[key]
    }

    func lockedPlayer(for key: OCRRegionKey, fallback fallbackValue: Int?) -> Int? {
        penaltyPlayerLockedValues[key] ?? fallbackValue
    }

    func setLockedPlayer(_ value: Int, for key: OCRRegionKey) {
        penaltyPlayerLockedValues[key] = value
    }

    func clearLockedPlayer(for key: OCRRegionKey) {
        penaltyPlayerLockedValues.removeValue(forKey: key)
    }

    func hasLockedOrExistingPlayer(for key: OCRRegionKey, existingValue: Int?) -> Bool {
        lockedPlayer(for: key) != nil || existingValue != nil
    }

    // MARK: Player candidate / missing-read confirmation

    @discardableResult
    func registerMissingPlayerRead(for key: OCRRegionKey) -> Int {
        let count = (penaltyPlayerMissingCount[key] ?? 0) + 1
        penaltyPlayerMissingCount[key] = count
        clearPlayerChangeCandidate(for: key)
        return count
    }

    @discardableResult
    func registerPlayerChangeCandidate(_ candidate: Int, for key: OCRRegionKey) -> Int {
        if penaltyPlayerChangeCandidate[key] == candidate {
            let count = (penaltyPlayerChangeCandidateCount[key] ?? 0) + 1
            penaltyPlayerChangeCandidateCount[key] = count
            return count
        }

        penaltyPlayerChangeCandidate[key] = candidate
        penaltyPlayerChangeCandidateCount[key] = 1
        return 1
    }

    func noteValidPlayerRead(for key: OCRRegionKey) {
        penaltyPlayerMissingCount[key] = 0
    }

    func resetPlayerCandidates(for key: OCRRegionKey) {
        noteValidPlayerRead(for: key)
        clearPlayerChangeCandidate(for: key)
    }

    func clearPlayerChangeCandidate(for key: OCRRegionKey) {
        penaltyPlayerChangeCandidate.removeValue(forKey: key)
        penaltyPlayerChangeCandidateCount.removeValue(forKey: key)
    }

    func clearPlayerConfirmationState(for key: OCRRegionKey) {
        penaltyPlayerMissingCount.removeValue(forKey: key)
        clearPlayerChangeCandidate(for: key)
        clearLockedPlayer(for: key)
    }

    // Build 547: timer confirmation moved to OCREvidenceStore and the
    // game-clock-correlated penalty authority. This compatibility state machine
    // retains player locks only.

    // MARK: Slot state movement / clearing

    func clearPenaltySlotConfirmationState(playerKey: OCRRegionKey, timeKey: OCRRegionKey) {
        _ = timeKey
        clearPlayerConfirmationState(for: playerKey)
    }

    // MARK: Reset

    func resetAllPenaltyConfirmationState() {
        penaltyPlayerMissingCount.removeAll()
        penaltyPlayerLockedValues.removeAll()
        penaltyPlayerChangeCandidate.removeAll()
        penaltyPlayerChangeCandidateCount.removeAll()
    }
}

// MARK: - v0.8.8m16 Larger Penalty Prune APIs

struct PenaltyStateMutationResult: Equatable {
    var changed: Bool = false
    var displayStateChanged: Bool = false
    var diagnosticsChanged: Bool = false
    var clearedPlayerKeys: [OCRRegionKey] = []

    static let unchanged = PenaltyStateMutationResult()

    mutating func markChanged() {
        changed = true
        displayStateChanged = true
    }

    mutating func recordCleared(_ key: OCRRegionKey) {
        if !clearedPlayerKeys.contains(key) {
            clearedPlayerKeys.append(key)
        }
        markChanged()
    }

    mutating func merge(_ other: PenaltyStateMutationResult) {
        changed = changed || other.changed
        displayStateChanged = displayStateChanged || other.displayStateChanged
        diagnosticsChanged = diagnosticsChanged || other.diagnosticsChanged
        for key in other.clearedPlayerKeys where !clearedPlayerKeys.contains(key) {
            clearedPlayerKeys.append(key)
        }
    }
}

extension PenaltyStateMachine {
    static let penaltyPlayerRegionKeys: [OCRRegionKey] = [
        .homePenalty1Player,
        .homePenalty2Player,
        .awayPenalty1Player,
        .awayPenalty2Player
    ]

    static func penaltyTimeKey(forPlayerKey key: OCRRegionKey) -> OCRRegionKey {
        switch key {
        case .homePenalty1Player: return .homePenalty1Time
        case .homePenalty2Player: return .homePenalty2Time
        case .awayPenalty1Player: return .awayPenalty1Time
        case .awayPenalty2Player: return .awayPenalty2Time
        default: return key
        }
    }

    static func penaltyPlayerKey(forTimeKey key: OCRRegionKey) -> OCRRegionKey {
        switch key {
        case .homePenalty1Time: return .homePenalty1Player
        case .homePenalty2Time: return .homePenalty2Player
        case .awayPenalty1Time: return .awayPenalty1Player
        case .awayPenalty2Time: return .awayPenalty2Player
        default: return key
        }
    }

    // Build 547: penalty timers are projected from trusted game-clock movement
    // by OCREvidenceStore. This compatibility state machine never advances a
    // timer from wall-clock time and never moves a physical slot.

    func applyPenaltyPlayerLockingIfNeeded(
        from fieldDebug: [ScoreboardOCRProcessor.OCRFieldDebug],
        currentState: ScoreboardState,
        to merged: inout ScoreboardState,
        localClockIsRunning: Bool,
        penaltyPlayerLastSafetyOCRAt: inout [OCRRegionKey: CFAbsoluteTime]
    ) -> PenaltyStateMutationResult {
        let fieldsByKey = Dictionary(uniqueKeysWithValues: fieldDebug.map { ($0.key, $0) })
        var result = PenaltyStateMutationResult()

        for key in Self.penaltyPlayerRegionKeys {
            let field = fieldsByKey[key]
            let incoming = field.flatMap { cleanedPenaltyPlayerCandidate(from: $0) }
            let incomingDigitCount = field.flatMap { cleanedPenaltyPlayerDigitCount(from: $0) } ?? 0
            let currentLocked = lockedPlayer(for: key, fallback: Self.penaltyPlayerValue(for: key, in: currentState))

            guard !localClockIsRunning else {
                if let currentLocked {
                    setLockedPlayer(currentLocked, for: key)
                    setPenaltyPlayerValue(currentLocked, for: key, in: &merged, clearClockWhenNil: false)
                }
                continue
            }

            if let currentLocked {
                setLockedPlayer(currentLocked, for: key)
                setPenaltyPlayerValue(currentLocked, for: key, in: &merged, clearClockWhenNil: false)

                guard let field else { continue }

                if incoming == nil && isBlankPenaltyOCR(field) {
                    let count = registerMissingPlayerRead(for: key)
                    if count >= penaltyPlayerRemovalConfirmationCount {
                        result.merge(clearLockedPenaltySlot(key, in: &merged))
                    }
                    continue
                }

                guard let incoming else { continue }

                if incoming == currentLocked {
                    resetPlayerCandidates(for: key)
                } else {
                    noteValidPlayerRead(for: key)

                    if incomingDigitCount >= 2 && currentLocked < 10 {
                        setLockedPlayer(incoming, for: key)
                        resetPlayerCandidates(for: key)
                        setPenaltyPlayerValue(incoming, for: key, in: &merged, clearClockWhenNil: false)
                        result.markChanged()
                    } else {
                        let count = registerPlayerChangeCandidate(incoming, for: key)
                        if count >= penaltyPlayerChangeConfirmationCount {
                            setLockedPlayer(incoming, for: key)
                            resetPlayerCandidates(for: key)
                            setPenaltyPlayerValue(incoming, for: key, in: &merged, clearClockWhenNil: false)
                            result.markChanged()
                        }
                    }
                }
                continue
            }

            if let incoming, OCRValidationEngine.isValidPlayerNumber(incoming) {
                let count = registerPlayerChangeCandidate(incoming, for: key)
                let requiredCount = incomingDigitCount >= 2 ? penaltyPlayerLockConfirmationCount : penaltyPlayerLockConfirmationCount + 1
                if count >= requiredCount {
                    setLockedPlayer(incoming, for: key)
                    resetPlayerCandidates(for: key)
                    setPenaltyPlayerValue(incoming, for: key, in: &merged, clearClockWhenNil: false)
                    penaltyPlayerLastSafetyOCRAt[key] = CFAbsoluteTimeGetCurrent()
                    result.markChanged()
                }
            } else if let field, incoming == nil && isBlankPenaltyOCR(field) {
                resetPlayerCandidates(for: key)
            }
        }

        return result
    }

    // Build 547 removes the unused timer-led confirmation and automatic
    // power-play clear paths. Timer evidence is evaluated only by the
    // player-owned publication authority; goals merely increase player-zone
    // clear vigilance and never mutate a penalty directly.

    private func clearLockedPenaltySlot(_ key: OCRRegionKey, in state: inout ScoreboardState) -> PenaltyStateMutationResult {
        var result = PenaltyStateMutationResult()
        clearPenaltySlot(for: key, in: &state)
        clearLockedPlayer(for: key)
        clearPenaltySlotConfirmationState(playerKey: key, timeKey: Self.penaltyTimeKey(forPlayerKey: key))
        result.recordCleared(key)
        return result
    }

    private func clearPenaltySlot(for key: OCRRegionKey, in state: inout ScoreboardState) {
        switch key {
        case .homePenalty1Player:
            state.homePenalty1Player = nil
            state.homePenalty1Clock = nil
        case .homePenalty2Player:
            state.homePenalty2Player = nil
            state.homePenalty2Clock = nil
        case .awayPenalty1Player:
            state.awayPenalty1Player = nil
            state.awayPenalty1Clock = nil
        case .awayPenalty2Player:
            state.awayPenalty2Player = nil
            state.awayPenalty2Clock = nil
        default:
            break
        }
    }

    static func penaltyPlayerValue(for key: OCRRegionKey, in state: ScoreboardState) -> Int? {
        switch key {
        case .homePenalty1Player: return state.homePenalty1Player
        case .homePenalty2Player: return state.homePenalty2Player
        case .awayPenalty1Player: return state.awayPenalty1Player
        case .awayPenalty2Player: return state.awayPenalty2Player
        default: return nil
        }
    }

    private func setPenaltyPlayerValue(
        _ value: Int?,
        for key: OCRRegionKey,
        in state: inout ScoreboardState,
        clearClockWhenNil: Bool = true
    ) {
        switch key {
        case .homePenalty1Player:
            state.homePenalty1Player = value
            if value == nil && clearClockWhenNil { state.homePenalty1Clock = nil }
        case .homePenalty2Player:
            state.homePenalty2Player = value
            if value == nil && clearClockWhenNil { state.homePenalty2Clock = nil }
        case .awayPenalty1Player:
            state.awayPenalty1Player = value
            if value == nil && clearClockWhenNil { state.awayPenalty1Clock = nil }
        case .awayPenalty2Player:
            state.awayPenalty2Player = value
            if value == nil && clearClockWhenNil { state.awayPenalty2Clock = nil }
        default:
            break
        }
    }

    private func penaltyTimeValue(for key: OCRRegionKey, in state: ScoreboardState) -> String? {
        switch key {
        case .homePenalty1Time: return state.homePenalty1Clock
        case .homePenalty2Time: return state.homePenalty2Clock
        case .awayPenalty1Time: return state.awayPenalty1Clock
        case .awayPenalty2Time: return state.awayPenalty2Clock
        default: return nil
        }
    }

    private func setPenaltyTimeValue(_ value: String?, for key: OCRRegionKey, in state: inout ScoreboardState) {
        switch key {
        case .homePenalty1Time: state.homePenalty1Clock = value
        case .homePenalty2Time: state.homePenalty2Clock = value
        case .awayPenalty1Time: state.awayPenalty1Clock = value
        case .awayPenalty2Time: state.awayPenalty2Clock = value
        default: break
        }
    }

    private func cleanedPenaltyPlayerCandidate(from field: ScoreboardOCRProcessor.OCRFieldDebug) -> Int? {
        for source in penaltyPlayerCandidateSources(from: field) {
            let digits = String(source.filter { $0.isNumber })
            guard !digits.isEmpty, digits.count <= 2, let value = Int(digits) else { continue }
            if OCRValidationEngine.isValidPlayerNumber(value) { return value }
        }
        return nil
    }

    private func cleanedPenaltyPlayerDigitCount(from field: ScoreboardOCRProcessor.OCRFieldDebug) -> Int {
        for source in penaltyPlayerCandidateSources(from: field) {
            let digits = String(source.filter { $0.isNumber })
            guard !digits.isEmpty, digits.count <= 2, let value = Int(digits) else { continue }
            if OCRValidationEngine.isValidPlayerNumber(value) { return digits.count }
        }
        return 0
    }

    private func penaltyPlayerCandidateSources(from field: ScoreboardOCRProcessor.OCRFieldDebug) -> [String] {
        [field.accepted, field.cleaned, field.raw]
            .map {
                $0.uppercased()
                    .replacingOccurrences(of: "O", with: "0")
                    .replacingOccurrences(of: "I", with: "1")
                    .replacingOccurrences(of: "L", with: "1")
                    .replacingOccurrences(of: "S", with: "5")
                    .replacingOccurrences(of: "B", with: "8")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }

    private func cleanedPenaltyTimeCandidate(from field: ScoreboardOCRProcessor.OCRFieldDebug) -> String? {
        for candidate in [field.accepted, field.cleaned, field.raw] {
            let cleaned = OCRValidationEngine.cleanClockCandidate(candidate)
                .replacingOccurrences(of: " ", with: "")
            if OCRValidationEngine.isValidPenaltyTime(cleaned) {
                return cleaned
            }
        }
        return nil
    }

    private func isBlankPenaltyOCR(_ field: ScoreboardOCRProcessor.OCRFieldDebug) -> Bool {
        let combined = (field.accepted + field.cleaned + field.raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        return combined.isEmpty || combined == "RETAIN" || combined == "NO DETECTION"
    }

    private func isActivePenaltyClock(_ clock: String?) -> Bool {
        guard let clock, let seconds = seconds(from: clock) else { return false }
        return seconds > 0
    }

    private func seconds(from clock: String) -> Int? {
        OCRValidationEngine.seconds(fromGameClock: clock)
    }

    private func formatPenaltyClock(seconds: Int) -> String {
        let clamped = max(0, min(seconds, 600))
        return String(format: "%d:%02d", clamped / 60, clamped % 60)
    }
}
