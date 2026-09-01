// BUILD 699 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import CoreGraphics
import CoreImage
import UIKit

// MARK: - v9.2 Stage 5 preparation: cached overlay as CIImage

extension BroadcastRecordingOverlayCache {
    /// Returns the existing cached overlay as a CIImage for the future CoreImage
    /// full-composite path. This is not used by default in v9.2; the camera-only
    /// PixelBuffer test deliberately records without overlay first.
    func overlayCIImage(
        outputSize: CGSize,
        modeStatusText: String,
        strengthState: StrengthState,
        banner: BroadcastEvent?,
        homeLogo: UIImage? = nil,
        awayLogo: UIImage? = nil,
        overlayMode: BroadcastRecordingRenderOverlayMode,
        layout: BroadcastScoreboardLayoutSnapshot = .default,
        timelineEvents: [BroadcastEvent] = [],
        viewerScoreboard: RinkLensViewerScoreboardSnapshot
    ) -> CIImage? {
        guard let cgImage = overlayImage(
            outputSize: outputSize,
            modeStatusText: modeStatusText,
            strengthState: strengthState,
            banner: banner,
            homeLogo: homeLogo,
            awayLogo: awayLogo,
            overlayMode: overlayMode,
            layout: layout,
            timelineEvents: timelineEvents,
            viewerScoreboard: viewerScoreboard
        ) else { return nil }
        return CIImage(cgImage: cgImage)
    }
}
#endif
