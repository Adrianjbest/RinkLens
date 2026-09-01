import Foundation

nonisolated enum RinkLensImageRelaySemanticRoute: Equatable, Sendable {
    case clock
    case directScore
    case visual
}

nonisolated enum RinkLensImageRelaySemanticRouting {
    static func route(
        for kind: ScoreboardImageRelayMetadataObservation.Kind
    ) -> RinkLensImageRelaySemanticRoute {
        switch kind {
        case .clock: .clock
        case .scoreCandidate: .directScore
        case .visual: .visual
        }
    }
}

nonisolated enum RinkLensAuxiliaryLaneExecutionDecision: Equatable, Sendable {
    case executeCurrentLane
    case rebindUnstartedRemainder
    case discardInvalidFrame
}

/// One admitted lane completes against its immutable frame. A capacity-one newer
/// request may inherit only the lanes that have not started yet.
nonisolated enum RinkLensAuxiliaryLaneExecutionPolicy {
    static func decision(
        currentFrameIsValid: Bool,
        laneHasStarted: Bool,
        hasNewerPendingFrame: Bool
    ) -> RinkLensAuxiliaryLaneExecutionDecision {
        guard currentFrameIsValid else { return .discardInvalidFrame }
        guard laneHasStarted, hasNewerPendingFrame else { return .executeCurrentLane }
        return .rebindUnstartedRemainder
    }
}

nonisolated struct RinkLensPenaltyPlayerSignalEvidence: Equatable, Sendable {
    let activePercent: Double
    let strongPercent: Double
    let maximumAlpha: Double
    let widthFraction: Double
    let heightFraction: Double
    let geometryRejected: Bool
}

nonisolated enum RinkLensPenaltyPlayerSignalDecision: Equatable, Sendable {
    case trustedOccupied
    case rejectAmbient
    case holdUnresolved
}

nonisolated enum RinkLensPenaltyPlayerSignalTrustPolicy {
    static func decision(
        for evidence: RinkLensPenaltyPlayerSignalEvidence
    ) -> RinkLensPenaltyPlayerSignalDecision {
        guard !evidence.geometryRejected else { return .holdUnresolved }
        let strongToActive = evidence.strongPercent / max(0.1, evidence.activePercent)
        let broadWeakLight = evidence.activePercent >= 18.0
            && evidence.strongPercent < 3.0
            && evidence.maximumAlpha < 180.0
        let lowContrastFlood = evidence.activePercent >= 28.0
            && strongToActive < 0.10
            && evidence.maximumAlpha < 195.0
        if broadWeakLight || lowContrastFlood { return .rejectAmbient }
        if evidence.heightFraction >= 0.36,
           evidence.strongPercent >= 4.0,
           evidence.maximumAlpha >= 150.0,
           strongToActive >= 0.18 {
            return .trustedOccupied
        }
        return .holdUnresolved
    }
}

/// A crop with no active or strong pixels is physical blank evidence even when
/// glyph extraction reports "too weak" rather than one of the board-specific
/// placeholder labels. The three-observation baseline owner remains responsible
/// for accepting the blank transition; this policy only classifies one sample.
nonisolated enum RinkLensPenaltyPlayerBlankEvidencePolicy {
    static func acceptsNearZeroSignal(
        maximumAlpha: Int,
        activePixelCount: Int,
        strongPixelCount: Int
    ) -> Bool {
        maximumAlpha <= 24 && activePixelCount <= 2 && strongPixelCount == 0
    }

    /// Some scoreboards illuminate a wide, low-density placeholder in an empty
    /// player cell. It is not a digit: the supplied 17:25 trace measured only
    /// 5.8-7.3% active and 2.4-3.0% strong pixels, while real players measured
    /// 32-42% active and 24-35% strong. This classifies one sample only; the
    /// hash owner still requires three compatible samples before it establishes
    /// the blank baseline, so a single dim scan cannot clear or create state.
    static func acceptsStablePlaceholderSignal(
        activePercent: Double,
        strongPercent: Double
    ) -> Bool {
        activePercent <= 9.0 && strongPercent <= 3.5
    }
}

/// Bounded source chronology only. Processing time is deliberately absent.
nonisolated struct RinkLensPenaltyPairSourceEvidenceState: Equatable, Sendable {
    private(set) var count = 0
    private(set) var captureGeneration: Int?
    private(set) var lastSourceSequence: Int?

    mutating func observePositive(sourceSequence: Int, captureGeneration: Int) -> Int {
        if self.captureGeneration != captureGeneration {
            reset(captureGeneration: captureGeneration)
        }
        guard lastSourceSequence != sourceSequence else { return count }
        guard lastSourceSequence.map({ sourceSequence > $0 }) ?? true else { return count }
        lastSourceSequence = sourceSequence
        count = min(4, count + 1)
        return count
    }

    mutating func observeConfirmedBlank(captureGeneration: Int) {
        reset(captureGeneration: captureGeneration)
    }

    private mutating func reset(captureGeneration: Int) {
        self.captureGeneration = captureGeneration
        lastSourceSequence = nil
        count = 0
    }
}

nonisolated enum RinkLensExternalOCRRecoveryAction: Equatable, Sendable {
    case none
    case convergeBranchDirectly
    case requestRecordingContinuation
}

nonisolated enum RinkLensExternalOCRRecoveryAdmission {
    static func action(
        deviceIsDiscoverable: Bool,
        ocrIsDesired: Bool,
        writerContractIsOpen: Bool,
        continuationIsActive: Bool
    ) -> RinkLensExternalOCRRecoveryAction {
        guard deviceIsDiscoverable, ocrIsDesired, !continuationIsActive else { return .none }
        return writerContractIsOpen ? .requestRecordingContinuation : .convergeBranchDirectly
    }
}
