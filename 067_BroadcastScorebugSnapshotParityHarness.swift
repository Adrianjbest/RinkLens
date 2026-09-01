// BUILD 700 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if DEBUG && canImport(SwiftUI)
import SwiftUI
import UIKit

/// Build 590 simulator/device validation for the two real scorebug render paths.
/// It renders SwiftUI and Core Graphics frames, crops their alpha bounds and
/// compares geometry plus a normalized alpha mask. This deliberately complements
/// syntax/static gates; it is not replaced by arithmetic simulation.
struct BroadcastScorebugSnapshotParityResult: Equatable {
    let teamFontSize: CGFloat
    let liveBounds: CGSize
    let recordingBounds: CGSize
    let dimensionDrift: CGFloat
    let alphaMismatch: CGFloat
    let passed: Bool
}

enum BroadcastScorebugSnapshotParityHarness {
    @MainActor
    static func runStandardMatrix(
        state: ScoreboardState,
        homeLogo: UIImage? = nil,
        awayLogo: UIImage? = nil,
        baseLayout: BroadcastScoreboardLayoutSnapshot? = nil
    ) -> [BroadcastScorebugSnapshotParityResult] {
        let resolvedBaseLayout = baseLayout ?? BroadcastScoreboardLayoutSnapshot.default
        return [34, 22, 18, 10].compactMap { fontSize in
            var layout = resolvedBaseLayout
            layout.teamNameFontSize = CGFloat(fontSize)
            return renderAndCompare(
                state: state,
                homeLogo: homeLogo,
                awayLogo: awayLogo,
                layout: layout
            )
        }
    }

    @MainActor
    static func renderAndCompare(
        state: ScoreboardState,
        homeLogo: UIImage? = nil,
        awayLogo: UIImage? = nil,
        layout: BroadcastScoreboardLayoutSnapshot
    ) -> BroadcastScorebugSnapshotParityResult? {
        let modeStatus = "OCR RUNNING"
        let metrics = BroadcastScorebugTemplateMetrics.resolve(
            layout: layout,
            homeTeamName: state.homeTeam,
            awayTeamName: state.awayTeam,
            includesGameSponsor: false,
            outputScale: 1
        )
        let logicalSize = metrics.scorebugLogicalSize
        guard logicalSize.width > 1, logicalSize.height > 1 else { return nil }

        let viewerScoreboard = RinkLensViewerScoreboardSnapshot.acceptedOnly(state: state)
        let root = ScorebugView(
            viewerScoreboard: viewerScoreboard,
            homeLogo: homeLogo,
            awayLogo: awayLogo,
            isLive: true,
            modeStatusText: modeStatus,
            showClockShotsAndPenalties: true,
            layout: layout,
            gameSponsorName: "",
            gameSponsorLogo: nil,
            strengthState: .evenStrength
        )
        .frame(width: logicalSize.width, height: logicalSize.height, alignment: .topLeading)

        let host = UIHostingController(rootView: root)
        host.view.bounds = CGRect(origin: .zero, size: logicalSize)
        host.view.backgroundColor = .clear
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        let liveFormat = UIGraphicsImageRendererFormat.default()
        liveFormat.scale = 1
        liveFormat.opaque = false
        let liveImage = UIGraphicsImageRenderer(size: logicalSize, format: liveFormat).image { context in
            host.view.layer.render(in: context.cgContext)
        }

        BroadcastRecordingOverlayCache.shared.reset(reason: "Build 590 snapshot parity harness")
        let sponsorSnapshot = SponsorRecordingOverlaySnapshot(isOutputOverlayEnabled: false)
        guard let recordingCG = BroadcastRecordingOverlayCache.shared.previewOverlayImage(
            outputSize: BroadcastCompositeStandard.canonicalCanvas,
            modeStatusText: modeStatus,
            strengthState: .evenStrength,
            banner: nil,
            homeLogo: homeLogo,
            awayLogo: awayLogo,
            sponsorSnapshot: sponsorSnapshot,
            overlayMode: .full,
            layout: layout,
            timelineEvents: [],
            viewerScoreboard: viewerScoreboard
        ) else { return nil }

        guard let liveCG = liveImage.cgImage,
              let liveCrop = alphaCropped(liveCG),
              let recordingCrop = alphaCropped(recordingCG) else { return nil }

        let liveBounds = CGSize(width: liveCrop.width, height: liveCrop.height)
        let recordingBounds = CGSize(width: recordingCrop.width, height: recordingCrop.height)
        let widthDrift = abs(liveBounds.width - recordingBounds.width) / max(1, max(liveBounds.width, recordingBounds.width))
        let heightDrift = abs(liveBounds.height - recordingBounds.height) / max(1, max(liveBounds.height, recordingBounds.height))
        let dimensionDrift = max(widthDrift, heightDrift)
        let mismatch = normalizedAlphaMismatch(liveCrop, recordingCrop)

        return BroadcastScorebugSnapshotParityResult(
            teamFontSize: layout.teamNameFontSize,
            liveBounds: liveBounds,
            recordingBounds: recordingBounds,
            dimensionDrift: dimensionDrift,
            alphaMismatch: mismatch,
            passed: dimensionDrift <= 0.03 && mismatch <= 0.18
        )
    }

    private static func alphaCropped(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return image.cropping(to: CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        ))
    }

    private static func normalizedAlphaMismatch(_ lhs: CGImage, _ rhs: CGImage) -> CGFloat {
        let size = CGSize(width: 512, height: 256)
        guard let left = normalizedRGBA(lhs, size: size),
              let right = normalizedRGBA(rhs, size: size),
              left.count == right.count else { return 1 }
        var mismatches = 0
        let pixelCount = left.count / 4
        for index in 0..<pixelCount {
            let leftOn = left[index * 4 + 3] > 24
            let rightOn = right[index * 4 + 3] > 24
            if leftOn != rightOn { mismatches += 1 }
        }
        return CGFloat(mismatches) / CGFloat(max(1, pixelCount))
    }

    private static func normalizedRGBA(_ image: CGImage, size: CGSize) -> [UInt8]? {
        let width = Int(size.width)
        let height = Int(size.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return pixels
    }
}
#endif
