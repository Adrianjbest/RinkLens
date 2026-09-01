// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation
import CoreFoundation

/// Build 550 executable OCR architecture contract.
///
/// Production ownership:
/// - `OCRWorkScheduler` selects exactly one bounded work unit.
/// - `ScoreboardOCRProcessor` recognises only the selected crop(s).
/// - `OCREvidenceStore` owns provisional/confirmed/expired evidence.
/// - `RinkLensMatchStateReducer` is the only public scoreboard mutation boundary.
/// - `RinkLensGameEventCoordinator` creates/cancels exactly-once events.
/// - the Broadcast renderer consumes snapshots and contains no OCR policy.
nonisolated enum RinkLensOCRServiceContract {
    // Build 550 physical-rink service levels. The UI interval is not treated as
    // the effective Clock cadence: the production scheduler owns these deadlines.
    static let runningClockRoutineInterval: CFTimeInterval = 1.25
    static let stoppedClockRoutineInterval: CFTimeInterval = 1.50
    static let clockAcquisitionInterval: CFTimeInterval = 0.70
    static let clockServiceCeiling: CFTimeInterval = 2.20
    static let scoreServiceCeiling: CFTimeInterval = 2.25
    static let periodServiceCeiling: CFTimeInterval = 8.00
    static let pendingConfirmationCeiling: CFTimeInterval = 2.30
    static let activePenaltyAuditCeiling: CFTimeInterval = 4.00
    static let inactivePenaltyFallbackAudit: CFTimeInterval = 20.00
    static let maximumConsecutiveNonClockPasses = 2
    static let maximumConsecutiveClockConfirmationPasses = 2
    static let maximumEventAttempts = 3
    // A player observation must survive stopped-Clock confirmation plus the
    // immediately reserved timer and second-pair verification passes.
    static let penaltyEvidenceWindow: CFTimeInterval = 10.00
}

enum RinkLensOCRTransactionTerminalOutcome: String, Codable, Equatable {
    case confirmed
    case confirmedBlank
    case rejected
    case expired
    case superseded
}

/// These invariants are deliberately represented in source as well as in the
/// delivery documentation so future changes can be guarded by tests and grep
/// gates rather than relying on recollection.
nonisolated enum RinkLensOCRArchitectureInvariant {
    static let singleScheduler = "Only OCRWorkScheduler selects production OCR work."
    static let scoreHashFirst = "A goal transaction starts from a material active-foreground Home/Away score-zone change or the independent bounded stopped-window score service; public commit still requires repeated trusted OCR evidence and the trusted game Clock to be stopped."
    static let playerOwnsPenalty = "A new penalty starts from an active-foreground player-number change or a bounded stopped-window player safety verification; that player change schedules one atomic player+timer crop pair, while public commit still requires repeated trusted pair evidence and the trusted game Clock to be stopped."
    static let timerCannotCreatePenalty = "A penalty timer cannot create, preserve or clear a slot independently."
    static let physicalClear = "Predicted penalty zero never removes the slot; confirmed blank player-zone evidence does."
    static let boundedTransactions = "Every OCR transaction confirms, confirms blank, rejects, expires or is superseded; uncommitted goal/new-penalty transactions close when the Clock restarts."
}
#endif
