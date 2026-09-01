// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation

// MARK: - v9.2 Stage 8 production recording path policy

/// Stage 8 keeps CoreImage/CVPixelBuffer as the production default. Build 690
/// temporarily restores comparison switches so a replacement can be proven
/// before the previous route is removed.
///
/// Rule:
/// - Recording hot path must not perform per-frame UIImage rendering/conversion.
/// - UIImage rendering remains available only for preview/snapshot/export fallback
///   code paths that are outside the 60fps recording writer loop.
enum BroadcastRecordingStage8Policy {
    static let stageName = "RNG-S8A production PixelBuffer renderer"
    static let writerPathText = "appendPixelBuffer(CVPixelBuffer) - live recording hot path"
    static let frameProviderPathText = "direct CVPixelBuffer + cached overlay CIImage"
    static let rendererPathText = "CoreImage / CVPixelBuffer compositor"
    static let overlayPathText = "cached overlay CIImage"

    static let fullPixelBufferRecordingPathLockedOn = false
    static let cameraOnlyTestModeAvailable = true
    static let cachedOverlayTestModeAvailable = true
    static let diagnosticTogglesRemoved = false

    /// Keep this false for production recording. If a direct camera PixelBuffer is
    /// missing, the recording loop drops the tick instead of converting UIImage ->
    /// CVPixelBuffer inside the 60fps writer path.
    static let allowPerFrameUIImageRecordingFallback = false

    static let legacyUIImageScopeText = "UIImage retained for preview/export fallback only"

    static var summaryText: String {
        [
            "RNG-S8A production PixelBuffer path: default on",
            "camera-only comparison: available in Engineering",
            "cached overlay comparison: available in Engineering",
            "UIImage recording fallback: disabled"
        ].joined(separator: "; ")
    }

    static var diagnosticsText: String {
        "RNG-S8A defaults to CoreImage/CVPixelBuffer. Build 690 retains controlled Engineering comparison flags until the production route is accepted. The live writer loop still drops missing PixelBuffer ticks rather than converting UIImage per frame. \(legacyUIImageScopeText)."
    }
}
#endif
