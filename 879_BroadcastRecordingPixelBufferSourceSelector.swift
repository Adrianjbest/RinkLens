// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import CoreVideo
import CoreMedia
import Foundation

// MARK: - v0.9.1w10 Direct recording sample selector

/// Source selection for the direct CVPixelBuffer recording path.
///
/// This mirrors the earlier UIImage selector but avoids converting every camera
/// sample into a UIImage before the recorder can decide whether the frame is usable.
/// The selector samples luma directly from the pixel buffer, which is cheap enough
/// to run at the recording cadence and preserves true source-frame diagnostics.
struct BroadcastRecordingPixelBufferFrameSourceSelection {
    enum SourceRole: String {
        case primary
        case fallback
    }

    let snapshot: RecordingCameraPixelBufferSnapshot
    let role: SourceRole
    let sourceLabel: String
    let qualitySummary: String
    let rejectedPrimarySummary: String?

    var usedFallbackBecausePrimaryWasBlank: Bool {
        role == .fallback && rejectedPrimarySummary != nil
    }
}

struct BroadcastRecordingPixelBufferFrameSourceSelector {
    private struct Candidate {
        let role: BroadcastRecordingPixelBufferFrameSourceSelection.SourceRole
        let snapshot: RecordingCameraPixelBufferSnapshot
        let label: String
        let quality: Quality
    }

    private struct Quality {
        let averageLuma: Double
        let brightRatio: Double
        let sampled: Bool

        var isUsable: Bool {
            sampled && (averageLuma >= 0.018 || brightRatio >= 0.006)
        }

        var summary: String {
            guard sampled else { return "quality unavailable" }
            return String(format: "avg %.3f bright %.1f%%", averageLuma, brightRatio * 100.0)
        }
    }

    @MainActor
    static func select(
        primary: RecordingCameraPixelBufferSnapshot?,
        primaryLabel: String,
        fallback: RecordingCameraPixelBufferSnapshot?,
        fallbackLabel: String
    ) -> BroadcastRecordingPixelBufferFrameSourceSelection? {
        let primaryCandidate = primary.map {
            Candidate(role: .primary, snapshot: $0, label: primaryLabel, quality: quality(of: $0.pixelBuffer))
        }
        let fallbackCandidate = fallback.map {
            Candidate(role: .fallback, snapshot: $0, label: fallbackLabel, quality: quality(of: $0.pixelBuffer))
        }

        let selected: Candidate?
        if primaryCandidate?.quality.isUsable == true {
            selected = primaryCandidate
        } else if fallbackCandidate?.quality.isUsable == true {
            selected = fallbackCandidate
        } else {
            traceNoUsableSource(primary: primaryCandidate, fallback: fallbackCandidate)
            return nil
        }

        guard let selected else { return nil }
        let rejectedPrimarySummary: String?
        if selected.role == .fallback, let primaryCandidate, !primaryCandidate.quality.isUsable {
            rejectedPrimarySummary = "rejected \(primaryCandidate.label) \(primaryCandidate.quality.summary)"
        } else {
            rejectedPrimarySummary = nil
        }

        let result = BroadcastRecordingPixelBufferFrameSourceSelection(
            snapshot: selected.snapshot,
            role: selected.role,
            sourceLabel: selected.label,
            qualitySummary: selected.quality.summary,
            rejectedPrimarySummary: rejectedPrimarySummary
        )
        traceSelection(result)
        return result
    }

    private static func quality(of pixelBuffer: CVPixelBuffer) -> Quality {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        if CVPixelBufferIsPlanar(pixelBuffer), CVPixelBufferGetPlaneCount(pixelBuffer) > 0 {
            return lumaPlaneQuality(pixelBuffer)
        }

        switch pixelFormat {
        case kCVPixelFormatType_32BGRA,
             kCVPixelFormatType_32ARGB,
             kCVPixelFormatType_32RGBA:
            return packedRGBQuality(pixelBuffer, pixelFormat: pixelFormat)
        default:
            // Most AVCapture video outputs are bi-planar YUV and are handled above.
            // Unknown formats are not rejected as black; use a conservative usable
            // value so the frame can still flow while diagnostics expose the format.
            return Quality(averageLuma: 0.20, brightRatio: 0.20, sampled: true)
        }
    }

    private static func lumaPlaneQuality(_ pixelBuffer: CVPixelBuffer) -> Quality {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            return Quality(averageLuma: 0, brightRatio: 0, sampled: false)
        }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        guard width > 0, height > 0, rowBytes > 0 else {
            return Quality(averageLuma: 0, brightRatio: 0, sampled: false)
        }

        let samplesX = 32
        let samplesY = 18
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var total = 0.0
        var bright = 0
        var sampled = 0

        for yIndex in 0..<samplesY {
            let y = min(height - 1, max(0, (yIndex * height) / samplesY))
            for xIndex in 0..<samplesX {
                let x = min(width - 1, max(0, (xIndex * width) / samplesX))
                let value = Double(bytes[y * rowBytes + x]) / 255.0
                total += value
                if value > 0.08 { bright += 1 }
                sampled += 1
            }
        }

        return Quality(
            averageLuma: total / Double(max(1, sampled)),
            brightRatio: Double(bright) / Double(max(1, sampled)),
            sampled: sampled > 0
        )
    }

    private static func packedRGBQuality(_ pixelBuffer: CVPixelBuffer, pixelFormat: OSType) -> Quality {
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return Quality(averageLuma: 0, brightRatio: 0, sampled: false)
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0, rowBytes > 0 else {
            return Quality(averageLuma: 0, brightRatio: 0, sampled: false)
        }

        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let samplesX = 32
        let samplesY = 18
        var total = 0.0
        var bright = 0
        var sampled = 0

        for yIndex in 0..<samplesY {
            let y = min(height - 1, max(0, (yIndex * height) / samplesY))
            for xIndex in 0..<samplesX {
                let x = min(width - 1, max(0, (xIndex * width) / samplesX))
                let offset = y * rowBytes + x * 4
                let r: Double
                let g: Double
                let b: Double
                if pixelFormat == kCVPixelFormatType_32BGRA {
                    b = Double(bytes[offset]) / 255.0
                    g = Double(bytes[offset + 1]) / 255.0
                    r = Double(bytes[offset + 2]) / 255.0
                } else if pixelFormat == kCVPixelFormatType_32ARGB {
                    r = Double(bytes[offset + 1]) / 255.0
                    g = Double(bytes[offset + 2]) / 255.0
                    b = Double(bytes[offset + 3]) / 255.0
                } else {
                    r = Double(bytes[offset]) / 255.0
                    g = Double(bytes[offset + 1]) / 255.0
                    b = Double(bytes[offset + 2]) / 255.0
                }
                let luma = (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
                total += luma
                if luma > 0.08 { bright += 1 }
                sampled += 1
            }
        }

        return Quality(
            averageLuma: total / Double(max(1, sampled)),
            brightRatio: Double(bright) / Double(max(1, sampled)),
            sampled: sampled > 0
        )
    }

    @MainActor
    private static func traceSelection(_ selection: BroadcastRecordingPixelBufferFrameSourceSelection) {
        BroadcastRecordingFrameSourceTrace.shared.trace(
            "recording source selected: direct \(selection.sourceLabel) \(selection.qualitySummary)" +
            (selection.rejectedPrimarySummary.map { " (\($0))" } ?? "")
        )
    }

    @MainActor
    private static func traceNoUsableSource(primary: Candidate?, fallback: Candidate?) {
        let primaryText = primary.map { "\($0.label) \($0.quality.summary)" } ?? "primary missing"
        let fallbackText = fallback.map { "\($0.label) \($0.quality.summary)" } ?? "fallback missing"
        BroadcastRecordingFrameSourceTrace.shared.trace("recording source rejected: no usable direct camera sample; \(primaryText); \(fallbackText)")
    }
}

#endif
