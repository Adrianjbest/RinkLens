// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// v0.9.1w10h: Broadcast zoom slider tuning kept separate from the large
/// Broadcast and camera files so future zoom feel changes do not touch camera
/// ownership, recording, OCR, or startup logic.
nonisolated enum BroadcastZoomGranularity {
    static let minimumLogicalZoom: CGFloat = 0.5
    static let maximumLogicalZoom: CGFloat = 5.0

    /// Fine UI step used while dragging. This makes the slider feel granular
    /// without introducing duplicate preset buttons.
    static let sliderStep: CGFloat = 0.01

    /// Camera updates may be slightly less frequent than visual UI updates.
    /// This is small enough to feel smooth, but avoids mutating the camera for
    /// every raw iPad touch event.
    static let cameraUpdateMinimumDelta: CGFloat = 0.03
    static let cameraUpdateMinimumInterval: Double = 1.0 / 15.0

    static func clamp(_ zoom: CGFloat) -> CGFloat {
        min(max(zoom, minimumLogicalZoom), maximumLogicalZoom)
    }

    static func quantize(_ zoom: CGFloat) -> CGFloat {
        let clamped = clamp(zoom)
        let stepped = (clamped / sliderStep).rounded() * sliderStep
        return clamp(stepped)
    }

    static func label(for zoom: CGFloat) -> String {
        String(format: "%.2fx", Double(quantize(zoom)))
    }
}

/// Build 134 separates the finger-owned visual draft from bounded physical
/// camera intent. It owns no persistent requested or applied zoom truth.
nonisolated enum BroadcastZoomGestureProjection {
    static func displayDraft(_ zoom: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(zoom, range.lowerBound), range.upperBound)
    }

    static func hardwarePreview(_ zoom: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        BroadcastZoomGranularity.quantize(displayDraft(zoom, range: range))
    }

    static func committedRequest(_ zoom: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        hardwarePreview(zoom, range: range)
    }
}
