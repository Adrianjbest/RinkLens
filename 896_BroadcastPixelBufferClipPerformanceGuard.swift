// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(UIKit)
import Foundation

// MARK: - Full-rate compressed-sample clip policy

/// ClipEngine muxes the primary RecordingCompressionEngine output. There is no
/// second clip encoder, full-frame copy, or independent recording pixel owner.
///
/// UX16c52a policy:
/// - manual clips target the active recording cadence, including 60fps;
/// - a capacity-one mailbox replaces pending compressed samples under backpressure;
/// - source timestamps preserve real clip duration when replacement occurs;
/// - the main recording never waits for the clip encoder;
/// - manual clips are only allowed when the current PixelBuffer window can
///   satisfy the requested duration.
nonisolated enum BroadcastPixelBufferClipPerformanceGuard {
    static let pixelBufferSegmentDuration: TimeInterval = 10.0
    static let minimumReadyCoverageSeconds: TimeInterval = BroadcastManualClipPostRollPolicy.minimumExportableSeconds
    static let exportDurationToleranceSeconds: TimeInterval = 0.25

    static func clipFPS(for recordingFPS: Int32) -> Int32 {
        // No hard 30fps cap. The lower-priority clip writer aims for the active
        // recording cadence and sheds only clip frames when its mailbox backs up.
        max(1, recordingFPS)
    }

    static func clipSegmentStartReason(recordingFPS: Int32, clipFPS: Int32) -> String {
        "single-encoder compressed-sample clip mux active: clipTargetFPS=\(clipFPS) recordingFPS=\(recordingFPS) encoder=RecordingCompressionEngine mailbox=capacity-one/keyframe-preserving segment=\(String(format: "%.1f", pixelBufferSegmentDuration))s"
    }

    static func notReadyReason(readyCoverage: TimeInterval, requested: TimeInterval) -> String {
        "Compressed-sample clip window warming up — ready coverage \(String(format: "%.1f", readyCoverage))s / requested \(Int(requested.rounded()))s"
    }
}
#endif
