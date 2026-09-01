// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation
import CoreFoundation

/// Build 550: the sole authoritative production OCR work scheduler.
///
/// The control plane owns *which production domain gets the next bounded OCR pass*.
/// Hashing, publication safety and the MatchState reducer remain separate concerns,
/// but none of them may independently rewrite the selected production work unit.
/// Test OCR is deliberately excluded and continues through its exclusive one-shot lane.
@MainActor
final class OCRWorkScheduler {
    enum WorkUnit: Hashable {
        case clock
        case staticField(OCRRegionKey)
        case penaltyPlayer(OCRRegionKey)
        case penaltyPair(player: OCRRegionKey, time: OCRRegionKey)

        var keys: Set<OCRRegionKey> {
            switch self {
            case .clock:
                return [.clock]
            case .staticField(let key):
                return [key]
            case .penaltyPlayer(let player):
                return [player]
            case .penaltyPair(let player, let time):
                return [player, time]
            }
        }

        var diagnosticName: String {
            switch self {
            case .clock:
                return "clock"
            case .staticField(let key):
                return key.rawValue
            case .penaltyPlayer(let player):
                return "penaltyPlayer(\(player.rawValue))"
            case .penaltyPair(let player, let time):
                return "penaltyPair(\(player.rawValue)+\(time.rawValue))"
            }
        }

        var routineInterval: CFTimeInterval {
            switch self {
            case .clock:
                return 0.70
            case .staticField(.homeScore), .staticField(.awayScore):
                return 2.25
            case .staticField(.period):
                return 10.0
            case .staticField:
                return 4.0
            case .penaltyPlayer:
                return RinkLensOCRServiceContract.inactivePenaltyFallbackAudit
            case .penaltyPair:
                return 6.0
            }
        }

        var isPenaltyPlayerUnit: Bool {
            if case .penaltyPlayer = self { return true }
            return false
        }

        var isPenaltyPairUnit: Bool {
            if case .penaltyPair = self { return true }
            return false
        }

        var deterministicOrder: Int {
            switch self {
            case .clock: return 0
            case .staticField(.homeScore): return 1
            case .staticField(.awayScore): return 2
            case .staticField(.period): return 3
            case .staticField: return 4
            case .penaltyPlayer(let player):
                switch player {
                case .homePenalty1Player: return 5
                case .homePenalty2Player: return 7
                case .awayPenalty1Player: return 9
                case .awayPenalty2Player: return 11
                default: return 13
                }
            case .penaltyPair(let player, _):
                switch player {
                case .homePenalty1Player: return 6
                case .homePenalty2Player: return 8
                case .awayPenalty1Player: return 10
                case .awayPenalty2Player: return 12
                default: return 14
                }
            }
        }
    }

    enum ReasonPriority: Int, Comparable {
        case routine = 0
        case activePenaltyAudit = 1
        case baseline = 2
        case visualChange = 3
        case publicationConfirmation = 4
        case resetRecovery = 5
        case clockConfirmation = 6
        case startupBootstrap = 7
        case safeMode = 8

        static func < (lhs: ReasonPriority, rhs: ReasonPriority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    struct Signals {
        let generation: Int
        let now: CFAbsoluteTime
        let performanceSafeMode: Bool
        let startupClockBootstrap: Bool
        let clockConfirmationRequired: Bool
        let trustedClockRunning: Bool
        let confirmedStoppedClock: Bool
        let pendingBaselineKeys: Set<OCRRegionKey>
        let pendingPenaltyBaselineKeys: Set<OCRRegionKey>
        let publicationPriorityKeys: Set<OCRRegionKey>
        let resetRecoveryKeys: Set<OCRRegionKey>
        let visualChangeKeys: Set<OCRRegionKey>
        let activePenaltyKeys: Set<OCRRegionKey>
    }

    struct Plan {
        let sequence: UInt64
        let generation: Int
        let unit: WorkUnit
        let keys: Set<OCRRegionKey>
        let reason: String
        let priority: ReasonPriority
        let hardDeadlineAt: CFAbsoluteTime
        let attemptNumberSinceUsable: Int

        var diagnosticText: String {
            let now = CFAbsoluteTimeGetCurrent()
            let overdue = max(0, now - hardDeadlineAt)
            return "plan#\(sequence) unit=\(unit.diagnosticName) priority=\(priority.rawValue) reason=\(reason) attempt=\(attemptNumberSinceUsable) deadline=\(String(format: "%.3f", hardDeadlineAt)) overdue=\(String(format: "%.2f", overdue))s"
        }
    }

    struct Completion {
        let usableKeys: Set<OCRRegionKey>
        let completedKeys: Set<OCRRegionKey>
        let confirmedBlankKeys: Set<OCRRegionKey>
        let now: CFAbsoluteTime
        let reason: String
    }

    private struct WorkState {
        var nextEligibleAt: CFAbsoluteTime
        var hardDeadlineAt: CFAbsoluteTime
        var lastAttemptAt: CFAbsoluteTime?
        var lastCompletedAt: CFAbsoluteTime?
        var lastUsableAt: CFAbsoluteTime?
        var attemptsSinceUsable: Int
        var priority: ReasonPriority
        var reason: String
        var signalActive: Bool
        var lastSelectedSequence: UInt64
    }

    private var states: [WorkUnit: WorkState] = [:]
    private var currentGeneration: Int?
    private var sequence: UInt64 = 0
    private var inFlightPlan: Plan?
    private var currentClockRoutineInterval: CFTimeInterval = RinkLensOCRServiceContract.clockAcquisitionInterval
    private var lastSelectedUnit: WorkUnit?
    private var consecutiveSelectionsOfSameUnit: Int = 0
    private(set) var lastCompletionDiagnostic = "No production OCR completion recorded"

    private let penaltyPairs: [(player: OCRRegionKey, time: OCRRegionKey)] = [
        (.homePenalty1Player, .homePenalty1Time),
        (.homePenalty2Player, .homePenalty2Time),
        (.awayPenalty1Player, .awayPenalty1Time),
        (.awayPenalty2Player, .awayPenalty2Time)
    ]

    func reset(generation: Int, now: CFAbsoluteTime, reason: String) {
        currentGeneration = generation
        states.removeAll(keepingCapacity: true)
        inFlightPlan = nil
        sequence = 0
        currentClockRoutineInterval = RinkLensOCRServiceContract.clockAcquisitionInterval
        lastSelectedUnit = nil
        consecutiveSelectionsOfSameUnit = 0

        // Build 631 production OCR baseline: scores, Period and penalty-player
        // numbers only. Clock movement and penalty timers remain Image Relay-only.
        install(.staticField(.homeScore), deadline: now, reason: "initial Home score baseline", priority: .baseline)
        install(.staticField(.awayScore), deadline: now + 0.40, reason: "initial Away score baseline", priority: .baseline)
        install(.staticField(.period), deadline: now + 0.80, reason: "initial Period baseline", priority: .baseline)
        for pair in penaltyPairs {
            install(
                .penaltyPlayer(pair.player),
                eligibleAt: Double.greatestFiniteMagnitude,
                deadline: Double.greatestFiniteMagnitude,
                reason: "inactive penalty player hash watch",
                priority: .routine
            )
        }
        lastCompletionDiagnostic = "control plane reset generation=\(generation) reason=\(reason)"
    }

    func nextPlan(signals: Signals) -> Plan {
        ensureGeneration(signals.generation, now: signals.now)
        ingest(signals)

        // Legacy Clock bootstrap/confirmation signals are intentionally ignored.
        // Performance Safe Mode reduces workload but never re-enables Clock OCR.
        let selectedUnit = selectUnit(now: signals.now, clockOnly: false)
        if lastSelectedUnit == selectedUnit {
            consecutiveSelectionsOfSameUnit += 1
        } else {
            lastSelectedUnit = selectedUnit
            consecutiveSelectionsOfSameUnit = 1
        }
        var selectedState = states[selectedUnit] ?? defaultState(now: signals.now)
        selectedState.lastAttemptAt = signals.now
        selectedState.attemptsSinceUsable += 1
        selectedState.lastSelectedSequence = sequence &+ 1
        states[selectedUnit] = selectedState

        sequence &+= 1
        let plan = Plan(
            sequence: sequence,
            generation: signals.generation,
            unit: selectedUnit,
            keys: selectedUnit.keys,
            reason: selectedState.reason,
            priority: selectedState.priority,
            hardDeadlineAt: selectedState.hardDeadlineAt,
            attemptNumberSinceUsable: selectedState.attemptsSinceUsable
        )
        inFlightPlan = plan
        return plan
    }

    @discardableResult
    func complete(_ completion: Completion) -> String {
        guard let plan = inFlightPlan else {
            lastCompletionDiagnostic = "completion ignored: no production plan in flight reason=\(completion.reason)"
            return lastCompletionDiagnostic
        }
        inFlightPlan = nil

        guard plan.generation == currentGeneration else {
            lastCompletionDiagnostic = "completion ignored: stale generation plan=\(plan.generation) active=\(currentGeneration.map { String($0) } ?? "none")"
            return lastCompletionDiagnostic
        }

        var state = states[plan.unit] ?? defaultState(now: completion.now)
        state.lastCompletedAt = completion.now
        let unitKeys = plan.keys
        let completed = !unitKeys.intersection(completion.completedKeys).isEmpty
        let usable = !unitKeys.intersection(completion.usableKeys).isEmpty

        if usable {
            state.lastUsableAt = completion.now
            state.attemptsSinceUsable = 0
            let confirmedBlank = plan.keys.isSubset(of: completion.confirmedBlankKeys)
            switch plan.unit {
            case .clock:
                state.nextEligibleAt = completion.now + currentClockRoutineInterval
                state.hardDeadlineAt = state.nextEligibleAt
                state.reason = "routine Clock cadence \(String(format: "%.2f", currentClockRoutineInterval))s"
            case .penaltyPlayer:
                state.nextEligibleAt = completion.now + RinkLensOCRServiceContract.inactivePenaltyFallbackAudit
                state.hardDeadlineAt = state.nextEligibleAt
                state.reason = confirmedBlank
                    ? "confirmed blank penalty-player slot idle hash watch"
                    : "player evidence handed to bounded penalty transaction"
            case .penaltyPair where confirmedBlank:
                // UX16d17: a settled empty slot is not active workload. Auditing
                // four confirmed-blank pairs every four seconds consumes enough
                // single-lane capacity to make the score/active-penalty service
                // contracts mathematically impossible. A hash change still wakes
                // the slot immediately.
                state.nextEligibleAt = completion.now + RinkLensOCRServiceContract.inactivePenaltyFallbackAudit
                state.hardDeadlineAt = state.nextEligibleAt
                state.reason = "confirmed blank penalty slot idle audit"
            default:
                state.nextEligibleAt = completion.now + plan.unit.routineInterval
                state.hardDeadlineAt = state.nextEligibleAt
                state.reason = "routine audit after usable observation"
            }
            state.priority = .routine
        } else {
            let retryOrdinal = max(1, state.attemptsSinceUsable)

            if (plan.unit.isPenaltyPlayerUnit || plan.unit.isPenaltyPairUnit),
               plan.priority == .baseline {
                // One unusable initial sample is enough to establish scheduler
                // ownership. Keep the reducer baseline unresolved, but do not keep
                // burning the OCR lane on a visually unchanged empty/noisy slot.
                // Hash change remains immediate; this 20-second audit is only the
                // bounded fallback for a missed visual change.
                state.nextEligibleAt = completion.now + RinkLensOCRServiceContract.inactivePenaltyFallbackAudit
                state.hardDeadlineAt = completion.now + RinkLensOCRServiceContract.inactivePenaltyFallbackAudit
                state.priority = .routine
                state.reason = "unresolved penalty slot idle hash watch"
            } else {
                let exponential = 0.30 * pow(2.0, Double(min(3, retryOrdinal - 1)))
                let backoff = min(2.40, exponential)
                state.nextEligibleAt = completion.now + backoff
                // Failed event/confirmation work remains overdue, but bounded
                // backoff gives Clock and scores a turn.
                if retryOrdinal >= 5 {
                    state.nextEligibleAt = completion.now + 4.0
                    state.reason = "bounded retry cool-off after repeated unusable observations"
                    state.priority = max(.routine, state.priority)
                }
            }
        }
        states[plan.unit] = state

        lastCompletionDiagnostic = "complete plan#\(plan.sequence) unit=\(plan.unit.diagnosticName) completed=\(completed) usable=\(usable) usableKeys=[\(orderedKeyText(completion.usableKeys))] nextEligible=\(String(format: "%.3f", state.nextEligibleAt)) hardDeadline=\(String(format: "%.3f", state.hardDeadlineAt)) reason=\(completion.reason)"
        return lastCompletionDiagnostic
    }

    func invalidate(keys: Set<OCRRegionKey>, now: CFAbsoluteTime, reason: String) {
        for unit in unitsForInvalidation(keys: keys) {
            guard var state = states[unit] else { continue }
            state.hardDeadlineAt = min(state.hardDeadlineAt, now)
            state.nextEligibleAt = min(state.nextEligibleAt, now)
            state.lastUsableAt = nil
            state.attemptsSinceUsable = 0
            state.priority = max(state.priority, .baseline)
            state.reason = reason
            state.signalActive = false
            states[unit] = state
        }
        lastCompletionDiagnostic = "invalidated keys=[\(orderedKeyText(keys))] reason=\(reason)"
    }

    func cancelInFlight(reason: String) {
        guard let plan = inFlightPlan else { return }
        inFlightPlan = nil
        if var state = states[plan.unit] {
            state.nextEligibleAt = min(state.nextEligibleAt, CFAbsoluteTimeGetCurrent() + 0.20)
            states[plan.unit] = state
        }
        lastCompletionDiagnostic = "cancelled plan#\(plan.sequence) unit=\(plan.unit.diagnosticName) reason=\(reason)"
    }

    var diagnosticText: String {
        let ordered = states.keys.sorted { $0.deterministicOrder < $1.deterministicOrder }
        let rows = ordered.map { unit -> String in
            let state = states[unit] ?? defaultState(now: 0)
            let lastAttempt = state.lastAttemptAt.map { String(format: "%.2f", $0) } ?? "--"
            let lastUsable = state.lastUsableAt.map { String(format: "%.2f", $0) } ?? "--"
            return "\(unit.diagnosticName){eligible=\(String(format: "%.2f", state.nextEligibleAt)) deadline=\(String(format: "%.2f", state.hardDeadlineAt)) lastAttempt=\(lastAttempt) lastUsable=\(lastUsable) attempts=\(state.attemptsSinceUsable) priority=\(state.priority.rawValue) reason=\(state.reason)}"
        }
        return rows.joined(separator: " | ")
    }

    private func ensureGeneration(_ generation: Int, now: CFAbsoluteTime) {
        guard currentGeneration == generation, !states.isEmpty else {
            reset(generation: generation, now: now, reason: "capture/OCR generation changed")
            return
        }
    }

    private func install(
        _ unit: WorkUnit,
        eligibleAt: CFAbsoluteTime = 0,
        deadline: CFAbsoluteTime,
        reason: String,
        priority: ReasonPriority
    ) {
        states[unit] = WorkState(
            nextEligibleAt: eligibleAt,
            hardDeadlineAt: deadline,
            lastAttemptAt: nil,
            lastCompletedAt: nil,
            lastUsableAt: nil,
            attemptsSinceUsable: 0,
            priority: priority,
            reason: reason,
            signalActive: false,
            lastSelectedSequence: 0
        )
    }

    private func ingest(_ signals: Signals) {
        // Build 549: effective Clock service is adaptive and explicitly owned by
        // the production scheduler. Running play is sampled at 1.25s, a confirmed
        // stoppage at 1.50s, and acquisition/confirmation at 0.70s. When upgrading
        // from Build 548's 3s cadence, pull the already-installed Clock deadline
        // forward immediately instead of waiting for the stale deadline to expire.
        let previousClockInterval = currentClockRoutineInterval
        if signals.performanceSafeMode || signals.startupClockBootstrap || signals.clockConfirmationRequired {
            currentClockRoutineInterval = RinkLensOCRServiceContract.clockAcquisitionInterval
        } else if signals.confirmedStoppedClock {
            currentClockRoutineInterval = RinkLensOCRServiceContract.stoppedClockRoutineInterval
        } else if signals.trustedClockRunning {
            currentClockRoutineInterval = RinkLensOCRServiceContract.runningClockRoutineInterval
        } else {
            currentClockRoutineInterval = RinkLensOCRServiceContract.clockAcquisitionInterval
        }
        if currentClockRoutineInterval != previousClockInterval,
           var clock = states[.clock],
           let lastCompletedAt = clock.lastCompletedAt {
            let revisedDeadline = lastCompletedAt + currentClockRoutineInterval
            clock.nextEligibleAt = min(clock.nextEligibleAt, revisedDeadline)
            clock.hardDeadlineAt = min(clock.hardDeadlineAt, revisedDeadline)
            clock.reason = "adaptive Clock cadence \(String(format: "%.2f", currentClockRoutineInterval))s"
            states[.clock] = clock
        }

        var strongestSignal: [WorkUnit: (priority: ReasonPriority, reason: String)] = [:]

        func merge(_ units: Set<WorkUnit>, priority: ReasonPriority, reason: String) {
            for unit in units {
                if let existing = strongestSignal[unit], existing.priority >= priority { continue }
                strongestSignal[unit] = (priority, reason)
            }
        }

        merge(units(for: signals.pendingBaselineKeys), priority: .baseline, reason: "physical baseline unresolved")

        // UX16d20 Build 542: unresolved penalty slots get one initial baseline
        // sample, then return to cheap whole-zone hash watch. Build 541 kept every
        // unusable empty/noisy pair permanently baseline-urgent, forcing four
        // expensive full-pair OCR reads around every seven seconds and starving
        // Clock/score work. A later visual hash change still wakes the exact pair.
        let initialPenaltyBaselineUnits = units(for: signals.pendingPenaltyBaselineKeys).filter { unit in
            states[unit]?.lastCompletedAt == nil
        }
        merge(Set(initialPenaltyBaselineUnits), priority: .baseline, reason: "initial penalty slot baseline sample")

        // During initial score/period acquisition, every untouched penalty zone
        // naturally has a different hash from an empty cache. Treating those four
        // first-frame differences as real penalty events consumes the entire lane
        // before Home/Away baselines can be verified. Until the static scoreboard
        // baseline is settled, only score/period visual changes receive event
        // priority; penalty slots continue their fair baseline rotation.
        let staticBaselinePending = !signals.pendingBaselineKeys.isEmpty
        let visualKeys: Set<OCRRegionKey>
        if staticBaselinePending {
            visualKeys = signals.visualChangeKeys.intersection([.homeScore, .awayScore, .period])
        } else {
            visualKeys = signals.visualChangeKeys
        }
        // The perceptual-hash helper records the first sample as its baseline and
        // reports only a later material change. Therefore a penalty visual change
        // after static baseline acquisition is real work even when blank OCR never
        // produced a usable text baseline. Build 541 filtered those genuine changes
        // out and relied on costly forced audits instead.
        // Defensive player-authority gate: even if an upstream caller supplies a
        // timer-only visual signal, it cannot activate an inactive penalty pair.
        // Timer hashes are legal only for an already-active player-owned slot or
        // a publication transaction opened by a confirmed player observation.
        let playerOwnedTimerKeys = Set(penaltyPairs.compactMap { pair -> OCRRegionKey? in
            let playerOwned = signals.activePenaltyKeys.contains(pair.player)
                || signals.publicationPriorityKeys.contains(pair.player)
            return playerOwned ? pair.time : nil
        })
        let gatedVisualKeys = Set(visualKeys.filter { key in
            if penaltyPairs.contains(where: { $0.time == key }) {
                return playerOwnedTimerKeys.contains(key)
            }
            return true
        })
        // Build 558: the physical log showed a player-zone hash waking only the
        // player crop. If that first player read was partial, the timer was never
        // reserved and the penalty could not form a pair. A player visual change
        // now owns one atomic player+timer work unit; timer-only visual changes are
        // still gated above and can never create a penalty.
        let eligibleVisualUnits = visualTransactionUnits(for: gatedVisualKeys)
        merge(Set(eligibleVisualUnits), priority: .visualChange, reason: "perspective-corrected visual change pending")
        let publicationUnits = units(for: signals.publicationPriorityKeys)
        let atomicPenaltyUnits = Set(publicationUnits.filter { $0.isPenaltyPairUnit })
        let otherPublicationUnits = publicationUnits.subtracting(atomicPenaltyUnits)
        merge(otherPublicationUnits, priority: .publicationConfirmation, reason: "publication confirmation pending")
        merge(atomicPenaltyUnits, priority: .publicationConfirmation, reason: "atomic penalty player+timer confirmation transaction")
        merge(units(for: signals.resetRecoveryKeys), priority: .resetRecovery, reason: "full-board reset recovery pending")

        for unit in allUnits {
            guard var state = states[unit] else { continue }
            if let signal = strongestSignal[unit] {
                let newlyActive = !state.signalActive
                let escalated = signal.priority > state.priority
                if newlyActive || escalated {
                    state.hardDeadlineAt = min(state.hardDeadlineAt, signals.now)
                    state.nextEligibleAt = min(state.nextEligibleAt, signals.now)
                }
                // Active evidence, not historical maximum, owns current priority.
                // This prevents a first-frame hash or expired confirmation from
                // leaving a field permanently urgent after that signal disappears.
                state.priority = signal.priority
                state.reason = signal.reason
                state.signalActive = true
            } else {
                if state.signalActive {
                    state.priority = .routine
                    state.reason = "routine audit after signal resolved"
                }
                state.signalActive = false
            }
            states[unit] = state
        }

        let activePenaltyUnits = units(for: signals.activePenaltyKeys).filter {
            if case .penaltyPair = $0 { return true }
            return false
        }
        for unit in activePenaltyUnits {
            guard var state = states[unit] else { continue }
            if state.hardDeadlineAt == Double.greatestFiniteMagnitude {
                state.hardDeadlineAt = signals.now
                state.reason = "active penalty pair initial audit"
                state.priority = .activePenaltyAudit
            } else if let usable = state.lastUsableAt,
                      signals.now >= usable + unit.routineInterval {
                state.hardDeadlineAt = min(state.hardDeadlineAt, usable + unit.routineInterval)
                state.reason = "active penalty pair running/clear audit"
                state.priority = max(state.priority, .activePenaltyAudit)
            }
            states[unit] = state
        }

        // Clear one-shot Clock promotions when their corresponding signal disappears.
        if !signals.clockConfirmationRequired && !signals.startupClockBootstrap && !signals.performanceSafeMode,
           var clock = states[.clock],
           clock.priority > .routine,
           clock.reason.contains("Clock") {
            clock.priority = .routine
            clock.reason = "routine Clock cadence"
            clock.signalActive = false
            states[.clock] = clock
        }
    }

    private func promote(
        _ unit: WorkUnit,
        now: CFAbsoluteTime,
        priority: ReasonPriority,
        reason: String,
        signalIsActive: Bool
    ) {
        guard var state = states[unit] else { return }
        state.hardDeadlineAt = min(state.hardDeadlineAt, now)
        state.nextEligibleAt = min(state.nextEligibleAt, now)
        state.priority = max(state.priority, priority)
        state.reason = reason
        state.signalActive = signalIsActive
        states[unit] = state
    }

    private func selectUnit(now: CFAbsoluteTime, clockOnly: Bool) -> WorkUnit {
        _ = clockOnly
        let candidates = states.compactMap { unit, state -> (WorkUnit, WorkState, CFAbsoluteTime)? in
            guard state.nextEligibleAt <= now else { return nil }
            return (unit, state, max(state.hardDeadlineAt, state.nextEligibleAt))
        }

        // When every unit is in bounded backoff, select the earliest authorised
        // unit rather than manufacturing a legacy Clock plan.
        if candidates.isEmpty {
            return states.min { lhs, rhs in
                if lhs.value.nextEligibleAt != rhs.value.nextEligibleAt {
                    return lhs.value.nextEligibleAt < rhs.value.nextEligibleAt
                }
                return lhs.key.deterministicOrder < rhs.key.deterministicOrder
            }?.key ?? .staticField(.homeScore)
        }

        func serviceAge(_ state: WorkState) -> CFTimeInterval {
            now - (state.lastUsableAt ?? state.lastCompletedAt ?? 0)
        }

        // Publication confirmations and material visual changes are event work.
        if let urgent = candidates.sorted(by: { lhs, rhs in
            if lhs.1.priority != rhs.1.priority { return lhs.1.priority > rhs.1.priority }
            let lhsAge = serviceAge(lhs.1)
            let rhsAge = serviceAge(rhs.1)
            if lhsAge != rhsAge { return lhsAge > rhsAge }
            if lhs.1.lastSelectedSequence != rhs.1.lastSelectedSequence {
                return lhs.1.lastSelectedSequence < rhs.1.lastSelectedSequence
            }
            return lhs.0.deterministicOrder < rhs.0.deterministicOrder
        }).first(where: { $0.1.priority >= .visualChange }) {
            return urgent.0
        }

        // Home/Away scores retain the shortest service ceiling because they drive
        // both the visible score and stoppage goal decisions.
        let overdueScores = candidates.filter { item in
            guard case .staticField(let key) = item.0,
                  key == .homeScore || key == .awayScore else { return false }
            return serviceAge(item.1) >= RinkLensOCRServiceContract.scoreServiceCeiling
        }
        if let score = overdueScores.max(by: { serviceAge($0.1) < serviceAge($1.1) }) {
            return score.0
        }

        return candidates.sorted { lhs, rhs in
            let lhsDue = now >= lhs.1.hardDeadlineAt
            let rhsDue = now >= rhs.1.hardDeadlineAt
            if lhsDue != rhsDue { return lhsDue && !rhsDue }
            if lhs.1.priority != rhs.1.priority { return lhs.1.priority > rhs.1.priority }
            if lhs.1.lastSelectedSequence != rhs.1.lastSelectedSequence {
                return lhs.1.lastSelectedSequence < rhs.1.lastSelectedSequence
            }
            if lhs.2 != rhs.2 { return lhs.2 < rhs.2 }
            return lhs.0.deterministicOrder < rhs.0.deterministicOrder
        }.first?.0 ?? .staticField(.homeScore)
    }

    private var allUnits: Set<WorkUnit> {
        Set(states.keys)
    }

    private func units(for keys: Set<OCRRegionKey>) -> Set<WorkUnit> {
        let authorised = keys.intersection(Set(OCRRegionKey.productionOCRCases))
        var result = Set<WorkUnit>()
        if authorised.contains(.homeScore) { result.insert(.staticField(.homeScore)) }
        if authorised.contains(.awayScore) { result.insert(.staticField(.awayScore)) }
        if authorised.contains(.period) { result.insert(.staticField(.period)) }
        for pair in penaltyPairs where authorised.contains(pair.player) {
            result.insert(.penaltyPlayer(pair.player))
        }
        return result
    }

    private func visualTransactionUnits(for keys: Set<OCRRegionKey>) -> Set<WorkUnit> {
        units(for: keys)
    }

    private func unitsForInvalidation(keys: Set<OCRRegionKey>) -> Set<WorkUnit> {
        units(for: keys)
    }

    private func defaultState(now: CFAbsoluteTime) -> WorkState {
        WorkState(
            nextEligibleAt: now,
            hardDeadlineAt: now,
            lastAttemptAt: nil,
            lastCompletedAt: nil,
            lastUsableAt: nil,
            attemptsSinceUsable: 0,
            priority: .routine,
            reason: "default",
            signalActive: false,
            lastSelectedSequence: 0
        )
    }

    private func orderedKeyText(_ keys: Set<OCRRegionKey>) -> String {
        keys.sorted { $0.rawValue < $1.rawValue }.map(\.rawValue).joined(separator: ",")
    }
}

#endif
