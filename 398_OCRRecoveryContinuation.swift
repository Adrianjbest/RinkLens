import Foundation

/// Value-only policy for the RecordingEngine-owned USB OCR recovery boundary.
/// It contains no AVFoundation, writer, timer, frame or UI state. RecordingEngine
/// executes the returned commands and feeds physical acknowledgements back in.
nonisolated struct RinkLensOCRRecoveryContinuationMachine: Equatable, Sendable {
    enum Phase: String, Codable, Equatable, Sendable {
        case settling
        case closingSegment
        case convergingOCR
        case openingContinuation
        case awaitingContinuationFirstFrame
        case resumed
        case resumedOCRDegraded
        case cancelled
        case stopped
    }

    enum Event: Equatable, Sendable {
        case topologySettled(revision: UInt64)
        case topologyChanged(revision: UInt64)
        case writerClosed
        case ocrConverged(freshFrameVerified: Bool)
        case continuationWriterOpened
        case continuationFirstFrameAppended
        case operatorStopRequested
    }

    enum Command: Equatable, Sendable {
        case closeCurrentSegment
        case convergeOCRBranch
        case openContinuationSegment
        case reportRecordingResumed
        case reportRecordingContinuedOCRDegraded
        case cancelWithoutWriterMutation
        case stopContinuationAndCompleteOperatorStop
        case completeOperatorStop
    }

    enum PendingReplacementDisposition: Equatable, Sendable {
        case replaceSettlingTransaction
        case retainCurrentTransaction
        case ignoreDuplicate
    }

    let transactionID: UUID
    let logicalRecordingID: UUID
    let deviceID: String
    let topologyRevision: UInt64
    let captureGeneration: Int
    private(set) var phase: Phase = .settling
    private(set) var freshOCRFrameVerified = false
    private var operatorStopPending = false

    func replacementDisposition(for newerTopologyRevision: UInt64) -> PendingReplacementDisposition {
        guard newerTopologyRevision != topologyRevision else { return .ignoreDuplicate }
        return phase == .settling && newerTopologyRevision > topologyRevision
            ? .replaceSettlingTransaction
            : .retainCurrentTransaction
    }

    init(
        transactionID: UUID,
        logicalRecordingID: UUID,
        deviceID: String,
        topologyRevision: UInt64,
        captureGeneration: Int
    ) {
        self.transactionID = transactionID
        self.logicalRecordingID = logicalRecordingID
        self.deviceID = deviceID
        self.topologyRevision = topologyRevision
        self.captureGeneration = captureGeneration
    }

    mutating func handle(_ event: Event) -> [Command] {
        switch (phase, event) {
        case (.settling, .topologySettled(let revision)) where revision == topologyRevision:
            phase = .closingSegment
            return [.closeCurrentSegment]

        case (.settling, .topologyChanged(let revision)) where revision != topologyRevision:
            phase = .cancelled
            return [.cancelWithoutWriterMutation]

        case (.settling, .operatorStopRequested):
            phase = .stopped
            return [.cancelWithoutWriterMutation, .completeOperatorStop]

        case (.closingSegment, .operatorStopRequested):
            operatorStopPending = true
            return []

        case (.closingSegment, .writerClosed):
            if operatorStopPending {
                phase = .stopped
                return [.completeOperatorStop]
            }
            phase = .convergingOCR
            return [.convergeOCRBranch]

        case (.convergingOCR, .operatorStopRequested):
            operatorStopPending = true
            return []

        case (.convergingOCR, .ocrConverged(let verified)):
            if operatorStopPending {
                phase = .stopped
                return [.completeOperatorStop]
            }
            freshOCRFrameVerified = verified
            phase = .openingContinuation
            return [.openContinuationSegment]

        case (.openingContinuation, .continuationWriterOpened):
            phase = .awaitingContinuationFirstFrame
            return []

        case (.openingContinuation, .continuationFirstFrameAppended),
             (.awaitingContinuationFirstFrame, .continuationFirstFrameAppended):
            if operatorStopPending {
                phase = .stopped
                return [.completeOperatorStop]
            }
            if freshOCRFrameVerified {
                phase = .resumed
                return [.reportRecordingResumed]
            }
            phase = .resumedOCRDegraded
            return [.reportRecordingContinuedOCRDegraded]

        case (.openingContinuation, .operatorStopRequested),
             (.awaitingContinuationFirstFrame, .operatorStopRequested):
            phase = .stopped
            return [.stopContinuationAndCompleteOperatorStop]

        default:
            return []
        }
    }
}
