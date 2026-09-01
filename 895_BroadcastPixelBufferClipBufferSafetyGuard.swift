// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation

// MARK: - v9.2 Stage 7b PixelBuffer clip buffer guard

/// Stage 7b re-enables clips for the promoted Stage 6 full PixelBuffer path.
///
/// Rules:
/// - Full PixelBuffer recording path: rolling/manual/automatic clips use
///   PixelBuffer segments generated from the same composed output buffer that
///   is written to the full-match recording.
/// - Stage 4/5 test modes: clips remain blocked so test recordings cannot export
///   stale legacy UIImage windows.
/// - Legacy UIImage recording fallback: existing UIImage clip buffer remains valid.
@MainActor
enum BroadcastPixelBufferClipBufferSafetyGuard {
    static let clipMigrationPendingText = "Clips unavailable — PixelBuffer clip migration is Stage 7"
    static let clipMigrationPendingDetailText = "Clip buffer disabled for PixelBuffer test path; full recording continues"
    static let clipMigrationPendingReason = "PixelBuffer test path active; clip buffer remains blocked until full Stage 7b path is active"

    static let pixelBufferClipSegmentsActiveText = "PixelBuffer clip segments active"
    static let pixelBufferClipSegmentsDetailText = "Clip buffer path: PixelBuffer segments from full recording output"
    static let pixelBufferClipSegmentsReason = "Stage 7b PixelBuffer clip buffer migration active"

    static var shouldUsePixelBufferClipSegments: Bool {
        BroadcastPixelBufferRecordingRolloutStore.shared.shouldUseFullPixelBufferRecordingPath
    }

    static var shouldDisableRollingClipBuffer: Bool {
        BroadcastPixelBufferRecordingRolloutStore.shared.shouldUsePixelBufferRecording && !shouldUsePixelBufferClipSegments
    }

    static var shouldBlockManualClipExport: Bool {
        BroadcastPixelBufferRecordingRolloutStore.shared.shouldUsePixelBufferRecording && !shouldUsePixelBufferClipSegments
    }

    static var shouldSuppressAutomaticClipExport: Bool {
        BroadcastPixelBufferRecordingRolloutStore.shared.shouldUsePixelBufferRecording && !shouldUsePixelBufferClipSegments
    }
}
#endif
