// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation

// MARK: - v9.2 Stage 4 PixelBuffer diagnostics update hook

@MainActor
extension RecordingEngine {

    /// Allows the Stage 4 camera-only PixelBuffer provider to update the
    /// recording diagnostics without exposing the raw diagnostics property publicly.
    func updateRecordingRawFrameCorrectionText(_ text: String) {
        recordingRawFrameCorrectionText = text
    }
}
#endif
