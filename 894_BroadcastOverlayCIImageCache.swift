// BUILD 699 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation
import CoreGraphics
import CoreImage
import SwiftUI
import UIKit

// MARK: - v9.2 Stage 5 cached overlay CIImage cache

/// Converts the existing cached broadcast overlay CGImage into a reusable CIImage
/// for the PixelBuffer compositor.
///
/// Stage 5 rules:
/// - Reuse the existing overlay renderer/cache as the source of truth.
/// - Do not redraw per frame.
/// - Rebuild the CIImage only when the underlying cached overlay CGImage changes,
///   which happens when score/team/logo/layout/banner state changes through the
///   existing `BroadcastRecordingOverlayCache` key.
final class BroadcastOverlayCIImageCache: @unchecked Sendable {
    static let shared = BroadcastOverlayCIImageCache()

    private let lock = NSLock()
    private var cachedCGImageIdentity: String?
    private var cachedCIImage: CIImage?
    private var hitCount: Int = 0
    private var missCount: Int = 0
    private var lastTraceAt: Date = .distantPast

    private init() {}

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
        guard outputSize.width > 0, outputSize.height > 0 else { return nil }
        guard let cgImage = BroadcastRecordingOverlayCache.shared.overlayImage(
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
        ) else {
            traceIfNeeded("CI overlay cache unavailable: source overlay image missing", force: true)
            return nil
        }

        let identity = Self.identity(for: cgImage, outputSize: outputSize, overlayMode: overlayMode)

        lock.lock()
        if identity == cachedCGImageIdentity, let cachedCIImage {
            hitCount += 1
            let hits = hitCount
            let misses = missCount
            lock.unlock()
            traceIfNeeded("CI overlay cache hit hits=\(hits) misses=\(misses) mode=\(overlayMode.rawValue)")
            return cachedCIImage
        }
        lock.unlock()

        let ciImage = CIImage(cgImage: cgImage).cropped(to: CGRect(origin: .zero, size: outputSize))

        lock.lock()
        cachedCGImageIdentity = identity
        cachedCIImage = ciImage
        missCount += 1
        let hits = hitCount
        let misses = missCount
        lock.unlock()
        traceIfNeeded("CI overlay cache miss redraw hits=\(hits) misses=\(misses) mode=\(overlayMode.rawValue)", force: true)
        return ciImage
    }

    /// Build 631 recording fast-start path. Return the last complete Broadcast
    /// overlay without triggering a synchronous redraw on the Record button.
    func currentCachedImage(outputSize: CGSize) -> CIImage? {
        lock.lock()
        let image = cachedCIImage
        lock.unlock()
        if let image { return image.cropped(to: CGRect(origin: .zero, size: outputSize)) }
        guard let retained = BroadcastRecordingOverlayCache.shared.currentRetainedOverlayImage() else {
            return nil
        }
        return CIImage(cgImage: retained).cropped(to: CGRect(origin: .zero, size: outputSize))
    }

    func reset(reason: String) {
        lock.lock()
        cachedCGImageIdentity = nil
        cachedCIImage = nil
        hitCount = 0
        missCount = 0
        lock.unlock()
        traceIfNeeded("CI overlay cache reset: \(reason)", force: true)
    }

    private static func identity(for cgImage: CGImage, outputSize: CGSize, overlayMode: BroadcastRecordingRenderOverlayMode) -> String {
        let pointer = Unmanaged.passUnretained(cgImage).toOpaque()
        return "\(pointer)|\(Int(outputSize.width))x\(Int(outputSize.height))|\(overlayMode.rawValue)"
    }

    private func traceIfNeeded(_ message: String, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastTraceAt) >= 2.0 else { return }
        lastTraceAt = now
        DispatchQueue.main.async {
            MainThreadStallMonitor.shared.trace("recording \(message)")
        }
    }
}
#endif
