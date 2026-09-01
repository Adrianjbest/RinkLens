// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import UIKit
import CoreGraphics

// MARK: - v0.9.1w6 Recording frame source guard

/// Chooses the camera snapshot used by the broadcast recorder.
///
/// The recording path can briefly have both a Live camera cache and an OCR camera cache
/// after Calibration/Broadcast handoffs. The latest cache is not always the usable cache:
/// recent logs showed fresh Live frames with an average luma around 0.002, so every
/// composed recording frame was rejected as black while the recorder continued running.
/// This helper keeps that source selection isolated from the large camera/view-model files.
struct BroadcastRecordingFrameSourceSelection {
    enum SourceRole: String {
        case primary
        case fallback
    }

    let snapshot: RecordingCameraFrameSnapshot
    let role: SourceRole
    let sourceLabel: String
    let qualitySummary: String
    let rejectedPrimarySummary: String?

    var usedFallbackBecausePrimaryWasBlank: Bool {
        role == .fallback && rejectedPrimarySummary != nil
    }
}

struct BroadcastRecordingFrameSourceSelector {
    private struct Candidate {
        let role: BroadcastRecordingFrameSourceSelection.SourceRole
        let snapshot: RecordingCameraFrameSnapshot
        let label: String
        let quality: Quality
    }

    private struct Quality {
        let averageLuma: Double
        let brightRatio: Double
        let sampled: Bool

        var isUsable: Bool {
            // True black/blank frames from the logs sit around avg=0.002 / bright=0.0%.
            // Rink camera frames, even when dim, are materially above this. Keep the
            // threshold conservative so dark rinks are not rejected.
            sampled && (averageLuma >= 0.018 || brightRatio >= 0.006)
        }

        var summary: String {
            guard sampled else { return "quality unavailable" }
            return String(format: "avg %.3f bright %.1f%%", averageLuma, brightRatio * 100.0)
        }
    }

    @MainActor
    static func select(
        primary: RecordingCameraFrameSnapshot?,
        primaryLabel: String,
        fallback: RecordingCameraFrameSnapshot?,
        fallbackLabel: String
    ) -> BroadcastRecordingFrameSourceSelection? {
        let primaryCandidate = primary.map {
            Candidate(role: .primary, snapshot: $0, label: primaryLabel, quality: quality(of: $0.image))
        }
        let fallbackCandidate = fallback.map {
            Candidate(role: .fallback, snapshot: $0, label: fallbackLabel, quality: quality(of: $0.image))
        }

        let usablePrimary = primaryCandidate?.quality.isUsable == true
        let usableFallback = fallbackCandidate?.quality.isUsable == true

        let selected: Candidate?
        if usablePrimary {
            selected = primaryCandidate
        } else if usableFallback {
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

        let result = BroadcastRecordingFrameSourceSelection(
            snapshot: selected.snapshot,
            role: selected.role,
            sourceLabel: selected.label,
            qualitySummary: selected.quality.summary,
            rejectedPrimarySummary: rejectedPrimarySummary
        )
        traceSelection(result)
        return result
    }

    private static func quality(of image: UIImage) -> Quality {
        guard let cgImage = image.cgImage else {
            return Quality(averageLuma: 0, brightRatio: 0, sampled: false)
        }

        let width = 32
        let height = 18
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return Quality(averageLuma: 0, brightRatio: 0, sampled: false)
        }

        context.interpolationQuality = .none
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var totalLuma = 0.0
        var brightCount = 0
        let pixelCount = width * height
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[index]) / 255.0
            let g = Double(pixels[index + 1]) / 255.0
            let b = Double(pixels[index + 2]) / 255.0
            let luma = (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
            totalLuma += luma
            if luma > 0.08 { brightCount += 1 }
        }

        return Quality(
            averageLuma: totalLuma / Double(max(1, pixelCount)),
            brightRatio: Double(brightCount) / Double(max(1, pixelCount)),
            sampled: true
        )
    }

    @MainActor
    private static func traceSelection(_ selection: BroadcastRecordingFrameSourceSelection) {
        BroadcastRecordingFrameSourceTrace.shared.trace(
            "recording source selected: \(selection.sourceLabel) \(selection.qualitySummary)" +
            (selection.rejectedPrimarySummary.map { " (\($0))" } ?? "")
        )
    }

    @MainActor
    private static func traceNoUsableSource(primary: Candidate?, fallback: Candidate?) {
        let primaryText = primary.map { "\($0.label) \($0.quality.summary)" } ?? "primary missing"
        let fallbackText = fallback.map { "\($0.label) \($0.quality.summary)" } ?? "fallback missing"
        BroadcastRecordingFrameSourceTrace.shared.trace("recording source rejected: no usable camera frame; \(primaryText); \(fallbackText)")
    }
}

@MainActor
final class BroadcastRecordingFrameSourceTrace {
    static let shared = BroadcastRecordingFrameSourceTrace()

    private var lastSourceKey = ""
    private var lastTraceAt = Date.distantPast

    private init() {}

    func trace(_ message: String) {
        let now = Date()
        let sourceKey: String
        if message.contains("no usable camera frame") {
            sourceKey = "rejected"
        } else if message.contains("OCR primary") {
            sourceKey = "ocr-primary"
        } else if message.contains("Live primary") {
            sourceKey = "live-primary"
        } else if message.contains("OCR fallback") {
            sourceKey = "ocr-fallback"
        } else if message.contains("Live fallback") {
            sourceKey = "live-fallback"
        } else {
            sourceKey = "other"
        }

        let sourceChanged = sourceKey != lastSourceKey
        // Quality values naturally change every frame. Do not let those tiny string
        // changes create 60 breadcrumbs/sec in Engineering diagnostics.
        guard sourceChanged || now.timeIntervalSince(lastTraceAt) > 2.0 else { return }
        lastSourceKey = sourceKey
        lastTraceAt = now
        MainThreadStallMonitor.shared.trace(message)
    }
}

#endif
