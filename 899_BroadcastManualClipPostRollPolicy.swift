// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(UIKit)
import Foundation

// MARK: - v9.2 Stage 7c7 manual clip post-roll policy

/// Centralises manual clip timing and user-facing feedback so the clip UI is
/// driven by the final export result, not by an earlier buffer-readiness state.
///
/// Manual clips are now intended to capture:
/// - configurable pre-roll before the operator presses CLIP; and
/// - 5 seconds of post-roll after the button press.
///
/// Partial clips are valid at the start of a recording, or when the recording is
/// stopped before the full post-roll has elapsed.
nonisolated enum BroadcastManualClipPostRollPolicy {
    static let postRollSeconds: TimeInterval = 5.0
    static let minimumExportableSeconds: TimeInterval = 3.0
    static let fullDurationToleranceSeconds: TimeInterval = 1.25

    static let manualTag = "MANUAL"
    static let postRollTag = "POST_ROLL"
    static let allowPartialTag = "ALLOW_START_PARTIAL"

    static let partialReasonStartOfRecording = "startOfRecording"
    static let partialReasonRecordingStoppedBeforePostRoll = "recordingStoppedBeforePostRoll"
    static let partialReasonTimingVariance = "selectedSegmentTimingVariance"

    static func requestedDuration(preRollSeconds: Int, postRollSeconds: TimeInterval = postRollSeconds) -> TimeInterval {
        Swift.max(0, TimeInterval(preRollSeconds)) + Swift.max(0, postRollSeconds)
    }

    static func isManualPostRoll(_ metadata: HighlightClipMetadata) -> Bool {
        metadata.eventTags.contains(manualTag) && metadata.eventTags.contains(postRollTag)
    }

    static func isExpectedPartialReason(_ reason: String?) -> Bool {
        guard let reason else { return false }
        return reason == partialReasonStartOfRecording
            || reason == partialReasonRecordingStoppedBeforePostRoll
    }

    static func feedback(for metadata: HighlightClipMetadata) -> String {
        let actual = Swift.max(0, metadata.actualDuration ?? 0)
        let requested = Swift.max(0, metadata.requestedDuration ?? metadata.sourceEndTime.timeIntervalSince(metadata.sourceStartTime))

        if requested <= 0 || actual + fullDurationToleranceSeconds >= requested {
            return "Clip saved"
        }

        switch metadata.shortClipReason {
        case partialReasonStartOfRecording:
            return "Clip saved from recording start — requested pre-roll was not fully available"
        case partialReasonRecordingStoppedBeforePostRoll:
            return "Clip saved — recording stopped before full post-roll"
        default:
            return "Short clip saved — only \(Int(actual.rounded())) seconds available"
        }
    }

    static func normalisedStatusText(for metadata: HighlightClipMetadata) -> String {
        let actual = Swift.max(0, metadata.actualDuration ?? 0)
        let requested = Swift.max(0, metadata.requestedDuration ?? metadata.sourceEndTime.timeIntervalSince(metadata.sourceStartTime))
        if actual + fullDurationToleranceSeconds >= requested { return "saved/full" }
        if isExpectedPartialReason(metadata.shortClipReason) { return "saved/expected-partial" }
        return "saved/short"
    }
}
#endif
