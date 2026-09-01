// BUILD 701 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
import Foundation
import UIKit
import SwiftUI

/// Canonical scorebug raster boundary for encoded programme output. The live
/// Broadcast view and this raster use the same ScorebugView implementation.
/// ImageRenderer is the supported off-screen SwiftUI rendering boundary; an
/// unattached UIHostingController does not guarantee that its root view has
/// produced visible pixels before CALayer.render returns.
@MainActor
private enum BroadcastCanonicalScorebugViewRasterizer {
    /// ScorebugView deliberately draws outside its layout bounds for its shadow.
    /// Programme output must preserve that visual extent rather than treating
    /// the calculated content size as a clipping rectangle.
    static let logicalInsets = EdgeInsets(top: 6, leading: 28, bottom: 28, trailing: 28)
    static let supersampleFactor: CGFloat = 2

    struct Raster {
        let image: CGImage
        let renderScale: CGFloat
    }

    static func render(
        outputSize: CGSize,
        modeStatusText: String,
        strengthState: StrengthState,
        homeLogo: UIImage?,
        awayLogo: UIImage?,
        sponsorSnapshot: SponsorRecordingOverlaySnapshot,
        layout: BroadcastScoreboardLayoutSnapshot,
        viewerScoreboard: RinkLensViewerScoreboardSnapshot
    ) -> Raster? {
        guard layout.isVisible else { return nil }
        let state = viewerScoreboard.state
        let metrics = BroadcastScorebugTemplateMetrics.resolve(
            layout: layout,
            homeTeamName: state.homeTeam,
            awayTeamName: state.awayTeam,
            includesGameSponsor: BroadcastScorebugTemplateMetrics.reservesInvariantUtilityStripGeometry,
            outputScale: 1
        )
        let logicalSize = metrics.scorebugLogicalSize
        guard logicalSize.width > 1, logicalSize.height > 1 else { return nil }
        let sponsorName = sponsorSnapshot.isOutputOverlayEnabled ? sponsorSnapshot.gameSponsorName : ""
        let sponsorLogo = sponsorSnapshot.isOutputOverlayEnabled
            ? sponsorSnapshot.gameSponsorLogoData.flatMap(UIImage.init(data:))
            : nil
        let showsAutomaticGameState = modeStatusText != OperatingMode.manual.broadcastStatusText
        let root = ScorebugView(
            viewerScoreboard: viewerScoreboard,
            homeLogo: homeLogo,
            awayLogo: awayLogo,
            isLive: true,
            modeStatusText: modeStatusText,
            showClockShotsAndPenalties: showsAutomaticGameState,
            layout: layout,
            gameSponsorName: sponsorName,
            gameSponsorLogo: sponsorLogo,
            strengthState: strengthState
        )
        .frame(width: logicalSize.width, height: logicalSize.height, alignment: .topLeading)
        .padding(logicalInsets)

        let renderer = ImageRenderer(content: root)
        renderer.proposedSize = ProposedViewSize(
            width: logicalSize.width + logicalInsets.leading + logicalInsets.trailing,
            height: logicalSize.height + logicalInsets.top + logicalInsets.bottom
        )
        // Render above the final programme resolution, then perform one
        // controlled downsample during full-canvas composition. This preserves
        // small sponsor lettering, rounded borders and diagonal logo edges much
        // better through H.264 4:2:0 compression without changing layout size.
        let renderScale = max(
            1,
            BroadcastCompositeStandard.scale(for: outputSize) * supersampleFactor
        )
        renderer.scale = renderScale
        renderer.isOpaque = false
        guard let image = renderer.cgImage else { return nil }
        return Raster(image: image, renderScale: renderScale)
    }
}

// MARK: - UX3 Cached broadcast composite overlay renderer

/// Caches the static/slow overlay drawing used by the recording renderer and UX3 WYSIWYG preview.
///
/// The camera frame still changes every sample, but the scorebug text, period,
/// clock, mode badge and optional banner only change when the scoreboard state
/// changes. Rendering those strings every frame was contributing to 60fps budget
/// misses, so this helper returns a transparent overlay CGImage that can be
/// reused across camera frames until the overlay key changes.
final class BroadcastRecordingOverlayCache: @unchecked Sendable {
    static let shared = BroadcastRecordingOverlayCache()

    private let lock = NSLock()
    private let redrawQueue = DispatchQueue(label: "rinklens.recording.overlay.redraw", qos: RinkLensExecutionQoSHierarchy.semantic)
    // A 1920x1080 scorebug render is presentation work, never operator-input
    // work. Running this at userInteractive starved taps once recording added
    // compositor/VideoToolbox load. Capacity-one scheduling still preserves the
    // newest complete image at the shared viewer QoS.
    private let previewRedrawQueue = DispatchQueue(
        label: "rinklens.broadcast.preview.overlay.redraw",
        qos: RinkLensExecutionQoSHierarchy.viewer
    )
    private var cachedKey: String?
    private var cachedImage: CGImage?
    // Recovery CT / RL-218: the exact SwiftUI stream raster and the legacy
    // full-match recording raster are different physical products. They must
    // never overwrite one retained-image slot or recording startup can inherit
    // the stream geometry before snapping back to its own compositor raster.
    private var canonicalStreamCachedKey: String?
    private var canonicalStreamCachedImage: CGImage?
    private var pendingAsyncKey: String?
    private var pendingAsyncBannerSignature: String?
    private var cachedBannerSignature: String = "banner=nil"
    private var hitCount: Int = 0
    private var missCount: Int = 0
    private var recordingLockoutReuseCount: Int = 0
    private var lastLockoutText: String = "idle"
    private var lastTraceAt: Date = .distantPast
    private var memoryWarningObserver: NSObjectProtocol?

    // UX1: preview-only cache. The Broadcast screen can hide sponsor branding for
    // the operator without changing the recording/stream output snapshot. Keeping
    // a separate cache prevents a preview-hidden sponsor frame being reused by
    // the recording writer during the recording lockout path.
    private var previewCachedKey: String?
    private var previewCachedImage: CGImage?
    private var lastPreviewRenderedClockText: String = "--:--"


    /// Build 574 separates the frequently changing scorebug from sponsors,
    /// timeline and event banners. Image Relay revisions therefore redraw only
    /// the scorebug layer; the slow full-canvas layer is reused.
    private final class LayeredRenderer: @unchecked Sendable {
        static let shared = LayeredRenderer()

        private let lock = NSLock()
        private var staticKey: String?
        private var staticImage: CGImage?
        private var scorebugKey: String?
        private var scorebugImage: CGImage?
        private var scorebugRect: CGRect = .zero
        private var compositeKey: String?
        private var compositeImage: CGImage?
        private var lastCompositionMode: String?

        private init() {}

        func resetAll() {
            lock.lock()
            staticKey = nil
            staticImage = nil
            scorebugKey = nil
            scorebugImage = nil
            scorebugRect = .zero
            compositeKey = nil
            compositeImage = nil
            lastCompositionMode = nil
            lock.unlock()
        }

        func invalidateScorebug() {
            lock.lock()
            scorebugKey = nil
            scorebugImage = nil
            scorebugRect = .zero
            compositeKey = nil
            compositeImage = nil
            lock.unlock()
        }

        func render(
            outputSize: CGSize,
            modeStatusText: String,
            strengthState: StrengthState,
            banner: BroadcastEvent?,
            homeLogo: UIImage?,
            awayLogo: UIImage?,
            overlayMode: BroadcastRecordingRenderOverlayMode,
            sponsorSnapshot: SponsorRecordingOverlaySnapshot,
            layout: BroadcastScoreboardLayoutSnapshot,
            timelineEvents: [BroadcastEvent],
            viewerScoreboard: RinkLensViewerScoreboardSnapshot
        ) -> CGImage? {
            guard outputSize.width > 1, outputSize.height > 1 else { return nil }
            let state = viewerScoreboard.state

            // Recovery CP / RL-209: rendering pressure may reduce optional
            // sponsor/banner work, but it must never select a second scorebug
            // template. Full and compact modes therefore share the same canonical
            // scorebug geometry and centre-status pill.

            let staticLayerKey = makeStaticKey(
                outputSize: outputSize,
                state: state,
                banner: banner,
                homeLogo: homeLogo,
                awayLogo: awayLogo,
                sponsorSnapshot: sponsorSnapshot,
                layout: layout,
                timelineEvents: timelineEvents
            )
            let scorebugLayerKey = makeScorebugKey(
                outputSize: outputSize,
                state: state,
                modeStatusText: modeStatusText,
                strengthState: strengthState,
                homeLogo: homeLogo,
                awayLogo: awayLogo,
                sponsorSnapshot: sponsorSnapshot,
                layout: layout,
                viewerScoreboard: viewerScoreboard
            )

            let resolvedStatic: CGImage?
            if overlayMode == .compact {
                // Compact is now strictly an optional-layer budget decision.
                // The viewer scorebug itself remains the full canonical template.
                resolvedStatic = nil
            } else {
                lock.lock()
                if staticKey == staticLayerKey, let staticImage {
                    resolvedStatic = staticImage
                    lock.unlock()
                } else {
                    lock.unlock()
                    let rendered = renderStaticLayer(
                        outputSize: outputSize,
                        state: state,
                        banner: banner,
                        homeLogo: homeLogo,
                        awayLogo: awayLogo,
                        sponsorSnapshot: sponsorSnapshot,
                        layout: layout,
                        timelineEvents: timelineEvents
                    )
                    lock.lock()
                    staticKey = staticLayerKey
                    staticImage = rendered
                    resolvedStatic = rendered
                    lock.unlock()
                }
            }

            let resolvedScorebug: CGImage?
            let resolvedRect: CGRect
            lock.lock()
            if scorebugKey == scorebugLayerKey, let scorebugImage {
                resolvedScorebug = scorebugImage
                resolvedRect = scorebugRect
                lock.unlock()
            } else {
                lock.unlock()
                let rect = BroadcastRecordingOverlayCache.resolvedScorebugRect(
                    outputSize: outputSize,
                    state: state,
                    modeStatusText: modeStatusText,
                    sponsorSnapshot: sponsorSnapshot,
                    layout: layout,
                    viewerScoreboard: viewerScoreboard
                )
                let rendered = renderScorebugLayer(
                    outputSize: outputSize,
                    scorebugRect: rect,
                    state: state,
                    modeStatusText: modeStatusText,
                    strengthState: strengthState,
                    homeLogo: homeLogo,
                    awayLogo: awayLogo,
                    sponsorSnapshot: sponsorSnapshot,
                    layout: layout,
                    viewerScoreboard: viewerScoreboard
                )
                lock.lock()
                scorebugKey = scorebugLayerKey
                scorebugImage = rendered
                scorebugRect = rect
                resolvedScorebug = rendered
                resolvedRect = rect
                lock.unlock()
            }

            guard resolvedStatic != nil || resolvedScorebug != nil else { return nil }
            let compositionMode = RinkLensRiskFeaturePolicy.isEnabled(.orientationSafeOverlayCompositionV23)
                ? "upright-uikit-v23"
                : (RinkLensRiskFeaturePolicy.isEnabled(.boundedDerivedRenderingV22) ? "direct-cg-v22" : "uikit-legacy")
            let nextCompositeKey = staticLayerKey + "||" + scorebugLayerKey + "||" + compositionMode + "||overlay=" + overlayMode.rawValue
            lock.lock()
            if compositeKey == nextCompositeKey, let compositeImage {
                lock.unlock()
                return compositeImage
            }
            lock.unlock()

            let result: CGImage?
            if RinkLensRiskFeaturePolicy.isEnabled(.orientationSafeOverlayCompositionV23) {
                result = composeLayersUpright(
                    outputSize: outputSize,
                    staticImage: resolvedStatic,
                    scorebugImage: resolvedScorebug,
                    scorebugRect: resolvedRect
                )
            } else if RinkLensRiskFeaturePolicy.isEnabled(.boundedDerivedRenderingV22) {
                // Build 742 rollback path. Its global Core Graphics Y flip is
                // retained only for controlled comparison because it inverted
                // already-upright UIKit-rendered layer images on physical iPad.
                result = composeLayersDirect(
                    outputSize: outputSize,
                    staticImage: resolvedStatic,
                    scorebugImage: resolvedScorebug,
                    scorebugRect: resolvedRect
                )
            } else {
                result = composeLayersUpright(
                    outputSize: outputSize,
                    staticImage: resolvedStatic,
                    scorebugImage: resolvedScorebug,
                    scorebugRect: resolvedRect
                )
            }
            lock.lock()
            let previousMode = lastCompositionMode
            compositeKey = nextCompositeKey
            compositeImage = result
            lastCompositionMode = compositionMode
            lock.unlock()
            if previousMode != compositionMode {
                RinkLensStructuredEventLogger.shared.record(
                    domain: .scoreboardPresentation,
                    event: "overlay_composition_mode_changed",
                    entityID: "broadcast-overlay",
                    previous: ["mode": previousMode ?? "none"],
                    next: ["mode": compositionMode, "size": "\(Int(outputSize.width))x\(Int(outputSize.height))"],
                    source: "BroadcastRecordingOverlayCache.LayeredRenderer",
                    reason: "Cached overlay compositor resolved for Broadcast, recording and clips"
                )
            }
            return result
        }

        /// Programme-output parity path. The scorebug pixels come directly
        /// from ScorebugView; this compositor adds only the independent sponsor
        /// canvas and event popup layers. There is no second scorebug painter.
        func renderUsingCanonicalScorebugView(
            outputSize: CGSize,
            state: ScoreboardState,
            banner: BroadcastEvent?,
            homeLogo: UIImage?,
            awayLogo: UIImage?,
            sponsorSnapshot: SponsorRecordingOverlaySnapshot,
            layout: BroadcastScoreboardLayoutSnapshot,
            timelineEvents: [BroadcastEvent],
            canonicalScorebugRaster: BroadcastCanonicalScorebugViewRasterizer.Raster?
        ) -> CGImage? {
            // A non-nil transparent bitmap is not a physical scorebug
            // acknowledgement. Refuse to compose or cache it so streaming can
            // report the failed visual boundary instead of publishing sponsor-
            // only frames while claiming that the scorebug was included.
            guard let canonicalScorebugRaster else { return nil }
            let canonicalScorebugImage = canonicalScorebugRaster.image
            guard Self.containsVisibleAlpha(canonicalScorebugImage) else { return nil }
            let staticLayer = renderStaticLayer(
                outputSize: outputSize,
                state: state,
                banner: banner,
                homeLogo: homeLogo,
                awayLogo: awayLogo,
                sponsorSnapshot: sponsorSnapshot,
                layout: layout,
                timelineEvents: timelineEvents
            )
            let contentRect = BroadcastRecordingOverlayCache.resolvedScorebugRect(
                outputSize: outputSize,
                state: state,
                modeStatusText: "",
                sponsorSnapshot: sponsorSnapshot,
                layout: layout,
                viewerScoreboard: .acceptedOnly(state: state)
            )
            let outputScale = BroadcastCompositeStandard.scale(for: outputSize)
            let insets = BroadcastCanonicalScorebugViewRasterizer.logicalInsets
            let scorebugRect = CGRect(
                x: contentRect.minX - insets.leading * outputScale,
                y: contentRect.minY - insets.top * outputScale,
                width: contentRect.width + (insets.leading + insets.trailing) * outputScale,
                height: contentRect.height + (insets.top + insets.bottom) * outputScale
            ).integral
            return composeLayersUpright(
                outputSize: outputSize,
                staticImage: staticLayer,
                scorebugImage: canonicalScorebugImage,
                scorebugRect: scorebugRect
            )
        }

        private static func containsVisibleAlpha(_ image: CGImage) -> Bool {
            let width = 64
            let height = 16
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            guard let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 8 }
        }


        /// Build 743 uses the same top-left UIKit coordinate contract as every
        /// individual layer renderer. The returned CGImage is cached and shared
        /// by Broadcast preview, recording and clips, so orientation has one owner.
        private func composeLayersUpright(
            outputSize: CGSize,
            staticImage: CGImage?,
            scorebugImage: CGImage?,
            scorebugRect: CGRect
        ) -> CGImage? {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            format.opaque = false
            let renderer = UIGraphicsImageRenderer(size: outputSize, format: format)
            return renderer.image { _ in
                if let staticImage {
                    UIImage(cgImage: staticImage).draw(in: CGRect(origin: .zero, size: outputSize))
                }
                if let scorebugImage, scorebugRect.width > 1, scorebugRect.height > 1 {
                    UIImage(cgImage: scorebugImage).draw(in: scorebugRect)
                }
            }.cgImage
        }

        private func composeLayersDirect(
            outputSize: CGSize,
            staticImage: CGImage?,
            scorebugImage: CGImage?,
            scorebugRect: CGRect
        ) -> CGImage? {
            let width = Int(outputSize.width.rounded())
            let height = Int(outputSize.height.rounded())
            guard width > 1, height > 1 else { return nil }
            let colourSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colourSpace,
                bitmapInfo: bitmapInfo
            ) else { return nil }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .none
            if let staticImage {
                context.draw(staticImage, in: CGRect(origin: .zero, size: outputSize))
            }
            if let scorebugImage, scorebugRect.width > 1, scorebugRect.height > 1 {
                context.draw(scorebugImage, in: scorebugRect)
            }
            return context.makeImage()
        }

        private func renderStaticLayer(
            outputSize: CGSize,
            state: ScoreboardState,
            banner: BroadcastEvent?,
            homeLogo: UIImage?,
            awayLogo: UIImage?,
            sponsorSnapshot: SponsorRecordingOverlaySnapshot,
            layout: BroadcastScoreboardLayoutSnapshot,
            timelineEvents: [BroadcastEvent]
        ) -> CGImage? {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            format.opaque = false
            let renderer = UIGraphicsImageRenderer(size: outputSize, format: format)
            return renderer.image { context in
                let cg = context.cgContext
                BroadcastRecordingOverlayCache.drawSponsorOverlay(
                    sponsorSnapshot,
                    in: cg,
                    outputSize: outputSize
                )
                if let banner {
                    BroadcastRecordingOverlayCache.drawBanner(
                        banner,
                        in: cg,
                        outputSize: outputSize,
                        state: state,
                        homeLogo: homeLogo,
                        awayLogo: awayLogo,
                        layout: layout
                    )
                }
            }.cgImage
        }

        private func renderScorebugLayer(
            outputSize: CGSize,
            scorebugRect: CGRect,
            state: ScoreboardState,
            modeStatusText: String,
            strengthState: StrengthState,
            homeLogo: UIImage?,
            awayLogo: UIImage?,
            sponsorSnapshot: SponsorRecordingOverlaySnapshot,
            layout: BroadcastScoreboardLayoutSnapshot,
            viewerScoreboard: RinkLensViewerScoreboardSnapshot
        ) -> CGImage? {
            guard layout.isVisible, scorebugRect.width > 1, scorebugRect.height > 1 else { return nil }
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            format.opaque = false
            let renderer = UIGraphicsImageRenderer(size: scorebugRect.size, format: format)
            return renderer.image { context in
                context.cgContext.translateBy(x: -scorebugRect.minX, y: -scorebugRect.minY)
                BroadcastRecordingOverlayCache.drawScorebug(
                    in: context.cgContext,
                    outputSize: outputSize,
                    state: state,
                    modeStatusText: modeStatusText,
                    strengthState: strengthState,
                    sponsorSnapshot: sponsorSnapshot,
                    homeLogo: homeLogo,
                    awayLogo: awayLogo,
                    layout: layout,
                    viewerScoreboard: viewerScoreboard
                )
            }.cgImage
        }

        private func makeStaticKey(
            outputSize: CGSize,
            state: ScoreboardState,
            banner: BroadcastEvent?,
            homeLogo: UIImage?,
            awayLogo: UIImage?,
            sponsorSnapshot: SponsorRecordingOverlaySnapshot,
            layout: BroadcastScoreboardLayoutSnapshot,
            timelineEvents: [BroadcastEvent]
        ) -> String {
            let timeline = "removed"
            return [
                "\(Int(outputSize.width))x\(Int(outputSize.height))",
                sponsorSnapshot.cacheKey,
                layout.overlayCacheKey,
                banner?.id.uuidString ?? "banner=nil",
                banner?.type.rawValue ?? "none",
                // The sponsor/banner layer is static during a popup. Live Clock
                // and Period revisions belong only to the scorebug layer.
                state.homeTeam ?? "HOME",
                state.awayTeam ?? "AWAY",
                BroadcastRecordingOverlayCache.imageCacheKey(homeLogo),
                BroadcastRecordingOverlayCache.imageCacheKey(awayLogo),
                "timeline=\(timeline)"
            ].joined(separator: "|")
        }

        private func makeScorebugKey(
            outputSize: CGSize,
            state: ScoreboardState,
            modeStatusText: String,
            strengthState: StrengthState,
            homeLogo: UIImage?,
            awayLogo: UIImage?,
            sponsorSnapshot: SponsorRecordingOverlaySnapshot,
            layout: BroadcastScoreboardLayoutSnapshot,
            viewerScoreboard: RinkLensViewerScoreboardSnapshot
        ) -> String {
            let relay = viewerScoreboard.relay
            return [
                "\(Int(outputSize.width))x\(Int(outputSize.height))",
                state.homeTeam ?? "HOME",
                state.awayTeam ?? "AWAY",
                state.homeScore.map { String($0) } ?? "0",
                state.awayScore.map { String($0) } ?? "0",
                state.clock ?? "--:--",
                state.periodDisplay,
                modeStatusText,
                strengthState.description,
                sponsorSnapshot.cacheKey,
                layout.overlayCacheKey,
                BroadcastRecordingOverlayCache.imageCacheKey(homeLogo),
                BroadcastRecordingOverlayCache.imageCacheKey(awayLogo),
                RinkLensRiskFeaturePolicy.isEnabled(.materialOverlayChangeOnlyV25)
                    ? viewerScoreboard.materialRenderIdentity
                    : "relay=\(relay.enabled ? relay.revision : 0)",
                "hp1=\(state.homePenalty1Player.map { String($0) } ?? "-")/\(state.homePenalty1Clock ?? "-")",
                "hp2=\(state.homePenalty2Player.map { String($0) } ?? "-")/\(state.homePenalty2Clock ?? "-")",
                "ap1=\(state.awayPenalty1Player.map { String($0) } ?? "-")/\(state.awayPenalty1Clock ?? "-")",
                "ap2=\(state.awayPenalty2Player.map { String($0) } ?? "-")/\(state.awayPenalty2Clock ?? "-")"
            ].joined(separator: "|")
        }
    }

    private init() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.purgeDerivedCaches(reason: "system memory warning")
        }
    }

    deinit {
        if let memoryWarningObserver { NotificationCenter.default.removeObserver(memoryWarningObserver) }
    }

    private func purgeDerivedCaches(reason: String) {
        lock.lock()
        cachedKey = nil
        cachedImage = nil
        canonicalStreamCachedKey = nil
        canonicalStreamCachedImage = nil
        previewCachedKey = nil
        previewCachedImage = nil
        pendingAsyncKey = nil
        pendingAsyncBannerSignature = nil
        lastLockoutText = "derived overlay caches purged: \(reason)"
        lock.unlock()
        LayeredRenderer.shared.resetAll()
        traceIfNeeded("derived overlay caches purged: \(reason)", force: true)
    }

    /// Build 631 fast recording start. Return the last complete output or
    /// preview overlay without rendering or invalidating any cache.
    func currentRetainedOverlayImage() -> CGImage? {
        lock.lock()
        let image = cachedImage ?? previewCachedImage
        lock.unlock()
        return image
    }

    /// Returns the canonical broadcast overlay image. UX3 uses this same
    /// method for iPad preview, full-match recording, manual clips and future stream
    /// overlay parity so text boxes and sponsor/logo layout have one source of truth.
    func overlayImage(
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
    ) -> CGImage? {
        let key = cacheKey(
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
        )

        let requestedBannerSignature = Self.bannerCacheSignature(banner)

        lock.lock()
        if key == cachedKey, let cachedImage {
            hitCount += 1
            let hits = hitCount
            let misses = missCount
            lock.unlock()
            traceIfNeeded("overlay cache hit hits=\(hits) misses=\(misses) mode=\(overlayMode.rawValue)")
            return cachedImage
        }

        if RinkLensRecordingCaptureLease.shared.isRecordingActive() {
            // Corrected Build 573: an overlay update must never create a blank
            // recording frame. Reuse the last complete output overlay, or the
            // already-rendered preview overlay during recording startup, while
            // the replacement is drawn on the dedicated overlay queue.
            let fallbackImage = cachedImage ?? previewCachedImage
            if fallbackImage != nil {
                hitCount += 1
                recordingLockoutReuseCount += 1
            }
            let hits = hitCount
            let misses = missCount
            let reuse = recordingLockoutReuseCount
            // Do not supersede an in-flight redraw for every 0.30-second relay
            // revision. That previously starved six-second event banners. A new
            // banner transition may supersede scorebug-only work immediately.
            let bannerTransitionPending = cachedBannerSignature != requestedBannerSignature
            let shouldScheduleRedraw = pendingAsyncKey == nil
                || pendingAsyncBannerSignature != requestedBannerSignature
                || (bannerTransitionPending && pendingAsyncBannerSignature == nil)
            if shouldScheduleRedraw {
                pendingAsyncKey = key
                pendingAsyncBannerSignature = requestedBannerSignature
            }
            lastLockoutText = fallbackImage == nil
                ? "recording lease active with no retained overlay; asynchronous first render requested"
                : "recording overlay invalidated; retained complete frame reused while redraw runs reuse=\(reuse) mode=\(overlayMode.rawValue)"
            lock.unlock()
            if shouldScheduleRedraw {
                scheduleAsyncOverlayRedraw(
                    key: key,
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
                )
            }
            if let fallbackImage {
                traceIfNeeded("overlay recording lockout retained complete overlay hits=\(hits) misses=\(misses) reuse=\(reuse) mode=\(overlayMode.rawValue)")
                return fallbackImage
            }
            return nil
        }
        let fallbackImage = cachedImage ?? previewCachedImage
        lock.unlock()

        guard let image = Self.renderOverlay(
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
            traceIfNeeded("overlay cache miss render failed; retained complete overlay returned mode=\(overlayMode.rawValue)", force: true)
            return fallbackImage
        }

        lock.lock()
        cachedKey = key
        cachedImage = image
        cachedBannerSignature = requestedBannerSignature
        missCount += 1
        let hits = hitCount
        let misses = missCount
        lock.unlock()
        traceIfNeeded("overlay cache miss redraw hits=\(hits) misses=\(misses) mode=\(overlayMode.rawValue)", force: true)
        return image
    }

    /// UX1: preview-only render path used by the WYSIWYG Broadcast screen.
    /// This lets the on-screen Hide Sponsors button affect only the iPad preview.
    /// Recording, clips and future stream still use the normal output snapshot.
    func previewOverlayImage(
        outputSize: CGSize,
        modeStatusText: String,
        strengthState: StrengthState,
        banner: BroadcastEvent?,
        homeLogo: UIImage? = nil,
        awayLogo: UIImage? = nil,
        sponsorSnapshot: SponsorRecordingOverlaySnapshot,
        overlayMode: BroadcastRecordingRenderOverlayMode,
        layout: BroadcastScoreboardLayoutSnapshot = .default,
        timelineEvents: [BroadcastEvent] = [],
        viewerScoreboard: RinkLensViewerScoreboardSnapshot
    ) -> CGImage? {
        let state = viewerScoreboard.state
        let baseKey = cacheKey(
            outputSize: outputSize,
            modeStatusText: modeStatusText,
            strengthState: strengthState,
            banner: banner,
            homeLogo: homeLogo,
            awayLogo: awayLogo,
            overlayMode: overlayMode,
            sponsorSnapshotOverride: sponsorSnapshot,
            cacheScope: "preview",
            layout: layout,
            timelineEvents: timelineEvents,
            viewerScoreboard: viewerScoreboard
        )
        let key = baseKey

        lock.lock()
        if key == previewCachedKey, let previewCachedImage {
            lock.unlock()
            return previewCachedImage
        }
        // Build 657: the preview and recording outputs must not share a
        // popup-bearing cache. The recording cache may already contain the active
        // event banner, while BroadcastView intentionally renders the one thin
        // SwiftUI popup above a popup-free preview composite. Reusing cachedImage
        // here caused one queued event to appear twice whenever recording was
        // active. Keep the preview cache independent and render the requested
        // banner=nil state through the layered renderer even during recording.
        // Recovery AV: a preview cache miss is not allowed to reuse an image
        // whose presentation identity belongs to a previous route/profile. The
        // view keeps its own current-session complete image while this replacement
        // renders; a failed render therefore returns nil rather than stale pixels.
        lock.unlock()

        guard let image = Self.renderOverlay(
            outputSize: outputSize,
            modeStatusText: modeStatusText,
            strengthState: strengthState,
            banner: banner,
            homeLogo: homeLogo,
            awayLogo: awayLogo,
            overlayMode: overlayMode,
            sponsorSnapshotOverride: sponsorSnapshot,
            layout: layout,
            timelineEvents: timelineEvents,
            viewerScoreboard: viewerScoreboard
        ) else {
            traceIfNeeded("preview overlay render failed; current-session view image retained locally mode=\(overlayMode.rawValue)", force: true)
            return nil
        }

        let renderedClock = state.clock ?? "--:--"
        lock.lock()
        let previousRenderedClock = lastPreviewRenderedClockText
        previewCachedKey = key
        previewCachedImage = image
        lastPreviewRenderedClockText = renderedClock
        lock.unlock()
        if previousRenderedClock != renderedClock {
            traceIfNeeded(
                "UX16d15h preview compositor rendered Clock \(previousRenderedClock) -> \(renderedClock)",
                force: true
            )
        }
        return image
    }

    /// Build 628 Settings preview renderer. Expensive canonical overlay drawing
    /// runs on the existing dedicated overlay queue and returns only the complete
    /// cached image to MainActor. This removes compositor work from Settings
    /// navigation and colour/slider interaction.
    func previewOverlayImageAsync(
        outputSize: CGSize,
        modeStatusText: String,
        strengthState: StrengthState,
        banner: BroadcastEvent?,
        homeLogo: UIImage? = nil,
        awayLogo: UIImage? = nil,
        sponsorSnapshot: SponsorRecordingOverlaySnapshot,
        overlayMode: BroadcastRecordingRenderOverlayMode,
        layout: BroadcastScoreboardLayoutSnapshot = .default,
        timelineEvents: [BroadcastEvent] = [],
        viewerScoreboard: RinkLensViewerScoreboardSnapshot,
        completion: @escaping @MainActor (CGImage?) -> Void
    ) {
        previewRedrawQueue.async { [weak self] in
            guard let self else { return }
            let image = self.previewOverlayImage(
                outputSize: outputSize,
                modeStatusText: modeStatusText,
                strengthState: strengthState,
                banner: banner,
                homeLogo: homeLogo,
                awayLogo: awayLogo,
                sponsorSnapshot: sponsorSnapshot,
                overlayMode: overlayMode,
                layout: layout,
                timelineEvents: timelineEvents,
                viewerScoreboard: viewerScoreboard
            )
            Task { @MainActor in
                completion(image)
            }
        }
    }

    /// Build 574 recording prewarm. Render the current layered overlay on
    /// the dedicated overlay queue before the recording lease starts, then hand
    /// the complete image back to the MainActor. No 1920x1080 overlay drawing is
    /// performed synchronously by the Record button.
    func prewarmOverlayImage(
        outputSize: CGSize,
        modeStatusText: String,
        strengthState: StrengthState,
        banner: BroadcastEvent?,
        homeLogo: UIImage? = nil,
        awayLogo: UIImage? = nil,
        overlayMode: BroadcastRecordingRenderOverlayMode,
        layout: BroadcastScoreboardLayoutSnapshot = .default,
        timelineEvents: [BroadcastEvent] = [],
        viewerScoreboard: RinkLensViewerScoreboardSnapshot,
        completion: @escaping @MainActor (CGImage?) -> Void
    ) {
        redrawQueue.async { [weak self] in
            guard let self else { return }
            let image = Self.renderOverlay(
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
            )
            if image != nil {
                // Build 682: recording startup renders into the recording source
                // context only. Mutating the shared live/preview cache here could
                // occupy its redraw slot and hold the Broadcast scorebug at one
                // revision for several seconds while the writer started.
                self.lock.lock()
                self.lastLockoutText = "recording overlay prewarmed detached from live cache"
                self.lock.unlock()
            }
            Task { @MainActor in
                completion(image)
            }
        }
    }

    /// Stream-only canonical visual path. ScorebugView is rasterised on the
    /// presentation actor at the selected output scale; full-canvas composition
    /// remains on the overlay queue. This makes sponsor pill, gradients, fonts,
    /// spacing and relay glyphs byte-for-byte descendants of the Broadcast view.
    @MainActor
    func prewarmCanonicalScorebugViewOverlayImage(
        outputSize: CGSize,
        modeStatusText: String,
        strengthState: StrengthState,
        banner: BroadcastEvent?,
        homeLogo: UIImage? = nil,
        awayLogo: UIImage? = nil,
        layout: BroadcastScoreboardLayoutSnapshot,
        timelineEvents: [BroadcastEvent] = [],
        viewerScoreboard: RinkLensViewerScoreboardSnapshot,
        completion: @escaping @MainActor (CGImage?) -> Void
    ) {
        let sponsorSnapshot = SponsorRecordingOverlaySnapshotStore.shared.snapshot()
        let key = cacheKey(
            outputSize: outputSize,
            modeStatusText: modeStatusText,
            strengthState: strengthState,
            banner: banner,
            homeLogo: homeLogo,
            awayLogo: awayLogo,
            overlayMode: .full,
            sponsorSnapshotOverride: sponsorSnapshot,
            cacheScope: "canonical-scorebug-view",
            layout: layout,
            timelineEvents: timelineEvents,
            viewerScoreboard: viewerScoreboard
        )
        lock.lock()
        if canonicalStreamCachedKey == key, let canonicalStreamCachedImage {
            lock.unlock()
            completion(canonicalStreamCachedImage)
            return
        }
        lock.unlock()

        let renderStartedAt = CFAbsoluteTimeGetCurrent()
        let canonicalScorebug = BroadcastCanonicalScorebugViewRasterizer.render(
            outputSize: outputSize,
            modeStatusText: modeStatusText,
            strengthState: strengthState,
            homeLogo: homeLogo,
            awayLogo: awayLogo,
            sponsorSnapshot: sponsorSnapshot,
            layout: layout,
            viewerScoreboard: viewerScoreboard
        )
        redrawQueue.async { [weak self] in
            guard let self else { return }
            let image = LayeredRenderer.shared.renderUsingCanonicalScorebugView(
                outputSize: outputSize,
                state: viewerScoreboard.state,
                banner: banner,
                homeLogo: homeLogo,
                awayLogo: awayLogo,
                sponsorSnapshot: sponsorSnapshot,
                layout: layout,
                timelineEvents: timelineEvents,
                canonicalScorebugRaster: canonicalScorebug
            )
            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - renderStartedAt) * 1_000)
            RinkLensStructuredEventLogger.shared.record(
                domain: .scoreboardPresentation,
                event: image == nil
                    ? "canonical_scorebug_raster_rejected"
                    : "canonical_scorebug_raster_acknowledged",
                entityID: "stream-scorebug",
                previous: ["state": "requested"],
                next: [
                    "state": image == nil ? "no-visible-pixels" : "visible-pixels",
                    "elapsedMs": String(elapsedMs),
                    "rasterSize": canonicalScorebug.map { "\($0.image.width)x\($0.image.height)" } ?? "nil",
                    "renderScale": canonicalScorebug.map { String(format: "%.2f", $0.renderScale) } ?? "nil",
                    "contentInsets": "top=6 left=28 bottom=28 right=28"
                ],
                source: "BroadcastRecordingOverlayCache",
                reason: "Encoded programme output requires visible canonical ScorebugView pixels before admission"
            )
            if let image {
                self.lock.lock()
                self.canonicalStreamCachedKey = key
                self.canonicalStreamCachedImage = image
                self.lock.unlock()
            }
            Task { @MainActor in completion(image) }
        }
    }

    /// Build 574 recording start keeps the prewarmed complete overlay and
    /// layered caches intact. Only transient counters and pending work are reset.
    func beginRecordingWithPrewarmedOverlay(reason: String) {
        lock.lock()
        pendingAsyncKey = nil
        pendingAsyncBannerSignature = nil
        cachedBannerSignature = "banner=nil"
        hitCount = 0
        missCount = 0
        recordingLockoutReuseCount = 0
        lastLockoutText = "recording start retained prewarmed overlay: \(reason)"
        lock.unlock()
        traceIfNeeded("recording start retained prewarmed overlay: \(reason)", force: true)
    }

    func reset(reason: String) {
        lock.lock()
        // Invalidate the keys but retain the last complete images. The next
        // caller renders a replacement, while preview and recording continue to
        // display a valid overlay. This prevents scorebug/IMAGE LIVE flashing and
        // camera-only recording frames during Image Relay updates.
        cachedKey = nil
        canonicalStreamCachedKey = nil
        pendingAsyncKey = nil
        pendingAsyncBannerSignature = nil
        previewCachedKey = nil
        hitCount = 0
        missCount = 0
        recordingLockoutReuseCount = 0
        lastLockoutText = "invalidated while retaining last complete overlay: \(reason)"
        lock.unlock()
        LayeredRenderer.shared.resetAll()
        traceIfNeeded("overlay cache invalidated with retained frame: \(reason)", force: true)
    }

    /// Build 574 fast Image Relay invalidation. Keep sponsors, timeline and
    /// event-banner layers cached and invalidate only the scorebug layer plus the
    /// final composite. The previous complete overlay remains visible until the
    /// new scorebug composite is ready.
    func invalidateRelayScorebug(reason: String) {
        let recordingActive = RinkLensRecordingCaptureLease.shared.isRecordingActive()
        // The direct stream publisher owns its own immutable overlay refresh. This
        // cache is only latency-critical while the recording raster is consumed.
        let rasterOutputActive = recordingActive
        lock.lock()
        if rasterOutputActive {
            cachedKey = nil
            if !recordingActive {
                pendingAsyncKey = nil
                pendingAsyncBannerSignature = nil
            }
            previewCachedKey = nil
            lastLockoutText = "relay scorebug invalidated for active encoded output: \(reason)"
        } else {
            // Recovery CY / RL-167: the live Broadcast scorebug is the SwiftUI/value
            // projection. The raster cache key already includes relay revision, so
            // idle recording/stream caches can miss naturally when next requested.
            lastLockoutText = "relay raster invalidation skipped; no encoded output active: \(reason)"
        }
        lock.unlock()
        guard rasterOutputActive else { return }
        LayeredRenderer.shared.invalidateScorebug()
        traceIfNeeded("relay scorebug layer invalidated: \(reason)", force: false)
    }

    func recordingLockoutDiagnosticText() -> String {
        lock.lock()
        let text = "reuse=\(recordingLockoutReuseCount) hits=\(hitCount) misses=\(missCount) last=\(lastLockoutText)"
        lock.unlock()
        return text
    }

    private func scheduleAsyncOverlayRedraw(
        key: String,
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
    ) {
        redrawQueue.async { [weak self] in
            guard let self else { return }
            guard let image = Self.renderOverlay(
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
                self.lock.lock()
                if self.pendingAsyncKey == key {
                    self.pendingAsyncKey = nil
                    self.pendingAsyncBannerSignature = nil
                }
                self.lastLockoutText = "async overlay redraw failed mode=\(overlayMode.rawValue)"
                self.lock.unlock()
                self.traceIfNeeded("overlay async redraw failed mode=\(overlayMode.rawValue)", force: true)
                return
            }

            self.lock.lock()
            guard self.pendingAsyncKey == key else {
                self.lock.unlock()
                return
            }
            self.cachedKey = key
            self.cachedImage = image
            self.cachedBannerSignature = Self.bannerCacheSignature(banner)
            self.pendingAsyncKey = nil
            self.pendingAsyncBannerSignature = nil
            self.missCount += 1
            let hits = self.hitCount
            let misses = self.missCount
            self.lastLockoutText = "async overlay redraw committed mode=\(overlayMode.rawValue)"
            self.lock.unlock()
            self.traceIfNeeded("overlay async redraw committed hits=\(hits) misses=\(misses) mode=\(overlayMode.rawValue)", force: true)
        }
    }

    private static func bannerCacheSignature(_ banner: BroadcastEvent?) -> String {
        guard let banner else { return "banner=nil" }
        let imageHash = banner.frozenPenaltyPlayerImagePNGData.map { String($0.hashValue) } ?? "none"
        return [
            banner.id.uuidString,
            banner.type.rawValue,
            banner.team?.rawValue ?? "none",
            banner.popupTitle,
            banner.popupHeadline,
            banner.popupDetail,
            banner.recognisedPenaltyPlayerNumber.map { String($0) } ?? "none",
            banner.recognisedHomePlayerName ?? "none",
            banner.penaltyLifecycleID ?? "none",
            imageHash
        ].joined(separator: "~")
    }

    private func cacheKey(
        outputSize: CGSize,
        modeStatusText: String,
        strengthState: StrengthState,
        banner: BroadcastEvent?,
        homeLogo: UIImage? = nil,
        awayLogo: UIImage? = nil,
        overlayMode: BroadcastRecordingRenderOverlayMode,
        sponsorSnapshotOverride: SponsorRecordingOverlaySnapshot? = nil,
        cacheScope: String = "output",
        layout: BroadcastScoreboardLayoutSnapshot = .default,
        timelineEvents: [BroadcastEvent] = [],
        viewerScoreboard: RinkLensViewerScoreboardSnapshot
    ) -> String {
        let state = viewerScoreboard.state
        let width = Int(outputSize.width)
        let height = Int(outputSize.height)
        let sizePart = String(width) + "x" + String(height)
        let homeTeam = Self.cleanTeamName(state.homeTeam ?? "HOME")
        let awayTeam = Self.cleanTeamName(state.awayTeam ?? "AWAY")
        let homeScore = state.homeScore.map { String($0) } ?? "0"
        let awayScore = state.awayScore.map { String($0) } ?? "0"
        let clock = state.clock ?? "--:--"
        let period = state.periodDisplay
        let strength = strengthState.description
        let bannerType = banner?.type.title ?? "none"
        let bannerTeam = banner?.team?.rawValue ?? "none"
        let bannerClock = banner?.gameClock ?? "none"
        let sponsorSnapshot = sponsorSnapshotOverride ?? SponsorRecordingOverlaySnapshotStore.shared.snapshot()

        var parts: [String] = []
        parts.reserveCapacity(17)
        parts.append(sizePart)
        parts.append(BroadcastCompositeStandard.version)
        parts.append(BroadcastCompositeStandard.diagnosticSummary)
        parts.append(cacheScope)
        parts.append(overlayMode.rawValue)
        parts.append(homeTeam)
        parts.append(awayTeam)
        parts.append(homeScore)
        parts.append(awayScore)
        parts.append(clock)
        parts.append(period)
        parts.append(modeStatusText)
        parts.append(strength)
        parts.append(strengthState.broadcastRailClockText)
        parts.append(bannerType)
        parts.append(bannerTeam)
        parts.append(bannerClock)
        parts.append(Self.bannerCacheSignature(banner))
        parts.append(Self.imageCacheKey(homeLogo))
        parts.append(Self.imageCacheKey(awayLogo))
        parts.append(sponsorSnapshot.cacheKey)
        parts.append(layout.overlayCacheKey)
        let relaySnapshot = viewerScoreboard.relay
        // Recovery CS / RL-217: cache identity follows visible material, not
        // Image Relay's diagnostic revision. Feed freshness is included because
        // it alone controls the utility LIVE badge. This prevents unchanged
        // pixels from forcing a full SwiftUI raster while still invalidating
        // every genuinely visible scorebug change.
        parts.append("material=\(viewerScoreboard.materialRenderIdentity)")
        parts.append("feedFresh=\(relaySnapshot.isFresh)")
        parts.append("hp1=\(state.homePenalty1Player.map { String($0) } ?? "-")/\(state.homePenalty1Clock ?? "-")")
        parts.append("hp2=\(state.homePenalty2Player.map { String($0) } ?? "-")/\(state.homePenalty2Clock ?? "-")")
        parts.append("ap1=\(state.awayPenalty1Player.map { String($0) } ?? "-")/\(state.awayPenalty1Clock ?? "-")")
        parts.append("ap2=\(state.awayPenalty2Player.map { String($0) } ?? "-")/\(state.awayPenalty2Clock ?? "-")")
        return parts.joined(separator: "|")
    }

    private static func imageCacheKey(_ image: UIImage?) -> String {
        guard let image else { return "logo=nil" }
        let orientation = image.imageOrientation.rawValue
        let scale = String(format: "%.2f", image.scale)
        return "logo=\(Int(image.size.width))x\(Int(image.size.height))@\(scale):\(orientation)"
    }

    private func traceIfNeeded(_ message: String, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastTraceAt) >= 2.0 else { return }
        lastTraceAt = now
        DispatchQueue.main.async {
            MainThreadStallMonitor.shared.trace("recording \(message)")
        }
    }

    private static func renderOverlay(
        outputSize: CGSize,
        modeStatusText: String,
        strengthState: StrengthState,
        banner: BroadcastEvent?,
        homeLogo: UIImage? = nil,
        awayLogo: UIImage? = nil,
        overlayMode: BroadcastRecordingRenderOverlayMode,
        sponsorSnapshotOverride: SponsorRecordingOverlaySnapshot? = nil,
        layout: BroadcastScoreboardLayoutSnapshot = .default,
        timelineEvents: [BroadcastEvent] = [],
        viewerScoreboard: RinkLensViewerScoreboardSnapshot
    ) -> CGImage? {
        let sponsorSnapshot = sponsorSnapshotOverride ?? SponsorRecordingOverlaySnapshotStore.shared.snapshot()
        return LayeredRenderer.shared.render(
            outputSize: outputSize,
            modeStatusText: modeStatusText,
            strengthState: strengthState,
            banner: banner,
            homeLogo: homeLogo,
            awayLogo: awayLogo,
            overlayMode: overlayMode,
            sponsorSnapshot: sponsorSnapshot,
            layout: layout,
            timelineEvents: timelineEvents,
            viewerScoreboard: viewerScoreboard
        )
    }

    private static func resolvedScorebugRect(
        outputSize: CGSize,
        state: ScoreboardState,
        modeStatusText: String,
        sponsorSnapshot: SponsorRecordingOverlaySnapshot,
        layout: BroadcastScoreboardLayoutSnapshot,
        viewerScoreboard: RinkLensViewerScoreboardSnapshot
    ) -> CGRect {
        guard layout.isVisible else { return .zero }
        let home = cleanTeamName(state.homeTeam ?? "HOME")
        let away = cleanTeamName(state.awayTeam ?? "AWAY")
        // Recovery S / RL-054: output geometry is independent of transient
        // feed/sponsor visibility. This matches ScorebugView and reserves the
        // maximum template utility strip even when its contents are empty.
        let rect = BroadcastCompositeStandard.scorebugRect(
            outputSize: outputSize,
            layout: layout,
            includesGameSponsor: BroadcastScorebugTemplateMetrics.reservesInvariantUtilityStripGeometry,
            homeTeamName: home,
            awayTeamName: away
        )
        return rect.integral
    }

    private static func drawScorebug(
        in cg: CGContext,
        outputSize: CGSize,
        state: ScoreboardState,
        modeStatusText: String,
        strengthState: StrengthState,
        sponsorSnapshot: SponsorRecordingOverlaySnapshot,
        homeLogo: UIImage? = nil,
        awayLogo: UIImage? = nil,
        layout: BroadcastScoreboardLayoutSnapshot = .default,
        viewerScoreboard: RinkLensViewerScoreboardSnapshot
    ) {
        let hasGameSponsor = sponsorSnapshot.isOutputOverlayEnabled
            && !sponsorSnapshot.gameSponsorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let relaySnapshot = viewerScoreboard.relay
        let imageRelayIsLive = relaySnapshot.isFresh
            || modeStatusText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "IMAGE RELAY LIVE"
        let ocrIsLive = isActivelyRunningOCRStatus(modeStatusText)
        let automaticFeedIsLive = ocrIsLive || imageRelayIsLive
        // `modeStatusText` is the immutable projection produced by the
        // scoreboard-input lifecycle owner and is already part of this layer's
        // cache key. Manual output deliberately retains Period and scores while
        // omitting automatic Clock/manpower presentation.
        let showsAutomaticGameState = modeStatusText != OperatingMode.manual.broadcastStatusText
        let home = Self.cleanTeamName(state.homeTeam ?? "HOME")
        let away = Self.cleanTeamName(state.awayTeam ?? "AWAY")
        let rect = BroadcastCompositeStandard.scorebugRect(
            outputSize: outputSize,
            layout: layout,
            includesGameSponsor: BroadcastScorebugTemplateMetrics.reservesInvariantUtilityStripGeometry,
            homeTeamName: home,
            awayTeamName: away
        )
        let homeScore = state.homeScore.map { String($0) } ?? "0"
        let awayScore = state.awayScore.map { String($0) } ?? "0"
        let clock = state.clock ?? "--:--"
        let period = state.periodDisplay.replacingOccurrences(of: "PERIOD", with: "P")
        let outputScale = BroadcastCompositeStandard.scale(for: outputSize)
        let metrics = BroadcastScorebugTemplateMetrics.resolve(
            layout: layout,
            homeTeamName: home,
            awayTeamName: away,
            includesGameSponsor: BroadcastScorebugTemplateMetrics.reservesInvariantUtilityStripGeometry,
            outputScale: outputScale
        )
        let utilityHeight = metrics.renderedUtilityStripHeight
        let utilityGap = metrics.renderedUtilityStripGap
        let utilityRect = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: utilityHeight
        )
        let mainRect = CGRect(
            x: rect.minX,
            y: utilityRect.maxY + utilityGap,
            width: rect.width,
            height: max(1, rect.maxY - utilityRect.maxY - utilityGap)
        )

        let bg = UIColor(layout.scoreboardBackgroundColour)
        let border = UIColor(layout.scoreboardBorderColour)

        // Recovery CQ / RL-212: encoded output previously painted a solid Core
        // Graphics base while the live ScorebugView used a top-left to bottom-
        // right gradient. The centre black pill is translucent, so identical
        // pill alpha values produced visibly different colours over those two
        // bases. Use the exact live background/border paint contract here.
        let backgroundPath = UIBezierPath(
            roundedRect: mainRect,
            cornerRadius: BroadcastTheme.scorebugCornerRadius
        ).cgPath
        let backgroundColours = [
            multipliedAlpha(bg, CGFloat(BroadcastScorebugPaintContract.backgroundLeadingOpacity)).cgColor,
            multipliedAlpha(bg, CGFloat(BroadcastScorebugPaintContract.backgroundMiddleOpacity)).cgColor,
            multipliedAlpha(UIColor(BroadcastTheme.glass), CGFloat(BroadcastScorebugPaintContract.backgroundGlassOpacity)).cgColor
        ] as CFArray
        cg.saveGState()
        cg.addPath(backgroundPath)
        cg.clip()
        if let gradient = CGGradient(
            colorsSpace: nil,
            colors: backgroundColours,
            locations: [0.0, 0.5, 1.0]
        ) {
            cg.drawLinearGradient(
                gradient,
                start: CGPoint(x: mainRect.minX, y: mainRect.minY),
                end: CGPoint(x: mainRect.maxX, y: mainRect.maxY),
                options: []
            )
        } else {
            cg.setFillColor(bg.cgColor)
            cg.fill(mainRect)
        }
        cg.restoreGState()

        let borderColours = [
            multipliedAlpha(UIColor(layout.accentColour), CGFloat(BroadcastScorebugPaintContract.borderLeadingOpacity)).cgColor,
            border.cgColor,
            multipliedAlpha(UIColor(BroadcastTheme.awayAccent), CGFloat(BroadcastScorebugPaintContract.borderTrailingOpacity)).cgColor
        ] as CFArray
        cg.saveGState()
        cg.addPath(backgroundPath)
        cg.setLineWidth(1.5)
        cg.replacePathWithStrokedPath()
        cg.clip()
        if let gradient = CGGradient(
            colorsSpace: nil,
            colors: borderColours,
            locations: [0.0, 0.5, 1.0]
        ) {
            cg.drawLinearGradient(
                gradient,
                start: CGPoint(x: mainRect.minX, y: mainRect.minY),
                end: CGPoint(x: mainRect.maxX, y: mainRect.maxY),
                options: []
            )
        }
        cg.restoreGState()

        let outerPadding = metrics.renderedHorizontalPadding
        let verticalPadding = metrics.renderedVerticalPadding
        let topRow = CGRect(
            x: mainRect.minX + outerPadding,
            y: mainRect.minY + verticalPadding,
            width: mainRect.width - outerPadding * 2,
            height: mainRect.height - verticalPadding * 2
        )
        let centerWidth = metrics.renderedCentreWidth
        let spacing = metrics.renderedTeamSpacing
        let panelSpacing = metrics.renderedPenaltyPanelSpacing
        let requestedPenaltyWidth = metrics.renderedPenaltyPanelWidth
        let requestedHomeWidth = metrics.renderedHomeTeamCellWidth
        let requestedAwayWidth = metrics.renderedAwayTeamCellWidth
        let requestedTotal = requestedPenaltyWidth * 2
            + requestedHomeWidth + requestedAwayWidth + centerWidth
            + spacing * 2 + panelSpacing * 2
        let availableScale = requestedTotal > topRow.width ? topRow.width / requestedTotal : 1
        let penaltyWidth = requestedPenaltyWidth * availableScale
        let homeWidth = requestedHomeWidth * availableScale
        let awayWidth = requestedAwayWidth * availableScale
        let scaledCenterWidth = centerWidth * availableScale
        let scaledSpacing = spacing * availableScale
        let scaledPanelSpacing = panelSpacing * availableScale
        let usedWidth = penaltyWidth * 2 + homeWidth + awayWidth + scaledCenterWidth
            + scaledSpacing * 2 + scaledPanelSpacing * 2
        let startX = topRow.midX - usedWidth / 2
        let homePenaltyRect = CGRect(x: startX, y: topRow.minY, width: penaltyWidth, height: topRow.height)
        let homeRect = CGRect(
            x: homePenaltyRect.maxX + scaledPanelSpacing,
            y: topRow.minY,
            width: homeWidth,
            height: topRow.height
        )
        let centerRect = CGRect(
            x: homeRect.maxX + scaledSpacing,
            y: topRow.minY,
            width: scaledCenterWidth,
            height: topRow.height
        )
        let awayRect = CGRect(
            x: centerRect.maxX + scaledSpacing,
            y: topRow.minY,
            width: awayWidth,
            height: topRow.height
        )
        let awayPenaltyRect = CGRect(
            x: awayRect.maxX + scaledPanelSpacing,
            y: topRow.minY,
            width: penaltyWidth,
            height: topRow.height
        )

        let teamWeight = uiFontWeight(layout.teamNameFontWeight)
        let scoreFontSize = metrics.renderedScoreFontSize
        let teamFont = UIFont.systemFont(
            ofSize: metrics.renderedTeamNameFontSize,
            weight: teamWeight
        )
        let scoreFont = UIFont.monospacedDigitSystemFont(ofSize: scoreFontSize, weight: .black)
        let clockFont = UIFont.monospacedDigitSystemFont(
            ofSize: metrics.renderedClockFontSize,
            weight: .black
        )
        let periodFont = UIFont.systemFont(
            ofSize: metrics.renderedPeriodFontSize,
            weight: .black
        )

        drawPenaltyLabels(
            penaltyLabels(state: state, side: .home),
            in: homePenaltyRect,
            accent: scoreUIColor(layout: layout, side: .home),
            side: .home,
            layout: layout,
            metrics: metrics,
            layoutFitScale: availableScale,
            relay: relaySnapshot
        )
        drawTemplateTeamCell(
            home,
            score: homeScore,
            logo: homeLogo,
            in: homeRect,
            accent: UIColor(layout.accentColour),
            teamColor: UIColor(layout.homeTeamNameColour),
            scoreColor: scoreUIColor(layout: layout, side: .home),
            logoBackground: UIColor(layout.homeLogoContainerBackground),
            teamBackground: UIColor(layout.homeTeamBackgroundColour),
            teamFont: teamFont,
            scoreFont: scoreFont,
            side: .home,
            logoPosition: layout.logoPosition,
            densityMode: layout.densityMode,
            layout: layout,
            metrics: metrics,
            layoutFitScale: availableScale,
            relay: relaySnapshot
        )
        drawTemplateCenterCell(
            period: period,
            clock: clock,
            strengthText: relaySnapshot.enabled
                ? relaySnapshot.visualManpowerText
                : strengthState.scorebugManpowerText,
            showsClockAndStrength: showsAutomaticGameState,
            in: centerRect,
            periodFont: periodFont,
            clockFont: clockFont,
            periodColor: UIColor(layout.periodColour),
            clockColor: UIColor(layout.clockColour),
            strengthColor: relaySnapshot.enabled
                ? strengthAccentColor(advantagedTeam: relaySnapshot.visualAdvantagedTeam, layout: layout)
                : strengthAccentColor(strengthState, layout: layout),
            borderColor: border,
            layout: layout,
            metrics: metrics,
            layoutFitScale: availableScale,
            relay: relaySnapshot
        )
        drawTemplateTeamCell(
            away,
            score: awayScore,
            logo: awayLogo,
            in: awayRect,
            accent: UIColor(red: 1.0, green: 0.23, blue: 0.31, alpha: 1.0),
            teamColor: UIColor(layout.awayTeamNameColour),
            scoreColor: scoreUIColor(layout: layout, side: .away),
            logoBackground: UIColor(layout.awayLogoContainerBackground),
            teamBackground: UIColor(layout.awayTeamBackgroundColour),
            teamFont: teamFont,
            scoreFont: scoreFont,
            side: .away,
            logoPosition: layout.logoPosition,
            densityMode: layout.densityMode,
            layout: layout,
            metrics: metrics,
            layoutFitScale: availableScale,
            relay: relaySnapshot
        )
        drawPenaltyLabels(
            penaltyLabels(state: state, side: .away),
            in: awayPenaltyRect,
            accent: scoreUIColor(layout: layout, side: .away),
            side: .away,
            layout: layout,
            metrics: metrics,
            layoutFitScale: availableScale,
            relay: relaySnapshot
        )

        // OCR LIVE is deliberately truthful: it is drawn only while the OCR
        // runtime is genuinely running/acquiring/arming. Starting, waiting,
        // interrupted, deferred, stalled, failed and off states show no live
        // claim. The pill is intentionally translucent and subordinate to the
        // scorebug.
        var liveRect: CGRect?
        if automaticFeedIsLive {
            let liveWidth = max(82 * outputScale, utilityRect.width * 0.14)
            let rect = CGRect(
                x: utilityRect.minX,
                y: utilityRect.midY - max(12, utilityRect.height * 0.39),
                width: liveWidth,
                height: max(24, utilityRect.height * 0.78)
            ).integral
            liveRect = rect
            cg.setFillColor(bg.withAlphaComponent(0.44).cgColor)
            cg.fillRoundedW10i(rect, radius: rect.height / 2)
            cg.setStrokeColor(border.withAlphaComponent(0.28).cgColor)
            cg.setLineWidth(1)
            cg.strokeRoundedW10i(rect, radius: rect.height / 2)
            drawText(
                imageRelayIsLive ? "●  IMAGE LIVE" : "●  OCR LIVE",
                in: rect.insetBy(dx: 8, dy: 3),
                font: UIFont.systemFont(ofSize: max(9, rect.height * 0.30), weight: .bold),
                color: UIColor(red: 0.14, green: 0.90, blue: 0.54, alpha: 0.84),
                alignment: .left
            )
        }

        if hasGameSponsor {
            let sponsorStartX = (liveRect?.maxX ?? utilityRect.minX) + (liveRect == nil ? 0 : 8)
            let sponsorRect = CGRect(
                x: sponsorStartX,
                y: utilityRect.minY,
                width: max(1, utilityRect.maxX - sponsorStartX),
                height: utilityRect.height
            )
            drawGameSponsorStrip(
                sponsorSnapshot,
                in: sponsorRect,
                cg: cg,
                badgeFont: UIFont.systemFont(ofSize: max(9, utilityRect.height * 0.24), weight: .black),
                layout: layout
            )
        }
    }

    // Build 708: viewer event-timeline drawing and textual Clock parsing were removed.

    private static func drawBanner(_ banner: BroadcastEvent, in cg: CGContext, outputSize: CGSize, state: ScoreboardState, homeLogo: UIImage? = nil, awayLogo: UIImage? = nil, layout: BroadcastScoreboardLayoutSnapshot) {
        // COMPOSITE4: event popups are drawn by the same renderer used for
        // preview, full recording, clips and future stream. This replaces the
        // previous simple yellow recording banner with a richer popup matching
        // the operator Broadcast event popup style.
        switch banner.type {
        case .powerPlayStart, .penaltyEnd, .timeoutStart, .timeoutEnd:
            drawStrengthPopup(banner, in: cg, outputSize: outputSize, layout: layout)
        case .penalty, .penalties:
            drawPenaltyPopup(banner, in: cg, outputSize: outputSize, state: state, homeLogo: homeLogo, awayLogo: awayLogo, layout: layout)
        default:
            drawGoalPopup(banner, in: cg, outputSize: outputSize, state: state, homeLogo: homeLogo, awayLogo: awayLogo, layout: layout)
        }
    }

    private static func drawGoalPopup(_ event: BroadcastEvent, in cg: CGContext, outputSize: CGSize, state: ScoreboardState, homeLogo: UIImage?, awayLogo: UIImage?, layout: BroadcastScoreboardLayoutSnapshot) {
        let width = min(outputSize.width * 0.62, BroadcastEventPopupTemplateMetrics.goalWidth)
        let height = max(BroadcastEventPopupTemplateMetrics.goalHeight, outputSize.height * 0.128)
        let rect = CGRect(x: (outputSize.width - width) / 2, y: outputSize.height - height - max(24, outputSize.height * 0.050), width: width, height: height).integral
        let accent = event.team == .away ? UIColor(red: 1.0, green: 0.23, blue: 0.31, alpha: 1.0) : UIColor(red: 0.0, green: 0.64, blue: 1.0, alpha: 1.0)
        drawPopupBackground(rect, accent: accent, cg: cg)

        let team = popupTeamName(for: event.team, state: state)
        let logo = event.team == .away ? awayLogo : homeLogo
        let badgeRect = CGRect(x: rect.minX + BroadcastEventPopupTemplateMetrics.horizontalPadding, y: rect.midY - BroadcastEventPopupTemplateMetrics.badgeSize / 2, width: BroadcastEventPopupTemplateMetrics.badgeSize, height: BroadcastEventPopupTemplateMetrics.badgeSize).integral
        drawCircularTeamBadge(team: team, logo: logo, accent: accent, in: badgeRect, cg: cg)

        let textX = badgeRect.maxX + BroadcastEventPopupTemplateMetrics.bodyGap
        let rightWidth: CGFloat = 128
        let rightRect = CGRect(x: rect.maxX - rightWidth - 22, y: rect.minY + 22, width: rightWidth, height: rect.height - 44)
        let bodyRect = CGRect(x: textX, y: rect.minY + 20, width: max(80, rightRect.minX - textX - 16), height: rect.height - 40)
        drawText(event.popupTitle.uppercased(), in: CGRect(x: bodyRect.minX, y: bodyRect.minY, width: bodyRect.width, height: bodyRect.height * 0.38), font: UIFont.systemFont(ofSize: BroadcastEventPopupTemplateMetrics.goalTitleFont, weight: .black), color: .white, alignment: .left)
        drawText(team, in: CGRect(x: bodyRect.minX, y: bodyRect.minY + bodyRect.height * 0.37, width: bodyRect.width, height: bodyRect.height * 0.26), font: UIFont.systemFont(ofSize: BroadcastEventPopupTemplateMetrics.goalTeamFont, weight: .heavy), color: accent, alignment: .left)
        let scoreLine = event.isImageRelayCue
            ? "SCORE SHOWN LIVE FROM SCOREBOARD IMAGE"
            : "Score now \(popupTeamName(for: .home, state: state)) \(event.homeScoreAfter.map { String($0) } ?? "-") - \(popupTeamName(for: .away, state: state)) \(event.awayScoreAfter.map { String($0) } ?? "-")"
        drawText(scoreLine, in: CGRect(x: bodyRect.minX, y: bodyRect.minY + bodyRect.height * 0.66, width: bodyRect.width, height: bodyRect.height * 0.28), font: UIFont.systemFont(ofSize: event.isImageRelayCue ? 14 : BroadcastEventPopupTemplateMetrics.goalScoreFont, weight: .bold), color: UIColor.white.withAlphaComponent(0.72), alignment: .left)
        drawText("●", in: CGRect(x: rightRect.minX, y: rightRect.minY, width: rightRect.width, height: rightRect.height * 0.34), font: UIFont.systemFont(ofSize: 30, weight: .black), color: accent, alignment: .right)
        let goalClockRect = CGRect(x: rightRect.minX, y: rightRect.minY + rightRect.height * 0.34, width: rightRect.width, height: rightRect.height * 0.66)
        if !drawFrozenEventClock(event, in: goalClockRect, layout: layout, textColor: UIColor(layout.clockColour)) {
            drawText(event.isImageRelayCue ? "IMAGE RELAY" : event.periodClockLine, in: goalClockRect, font: UIFont.monospacedDigitSystemFont(ofSize: 18, weight: .heavy), color: UIColor(layout.clockColour), alignment: .right)
        }
    }

    private static func drawPenaltyPopup(_ event: BroadcastEvent, in cg: CGContext, outputSize: CGSize, state: ScoreboardState, homeLogo: UIImage?, awayLogo: UIImage?, layout: BroadcastScoreboardLayoutSnapshot) {
        let width = min(outputSize.width * 0.58, BroadcastEventPopupTemplateMetrics.penaltyWidth)
        let height = BroadcastEventPopupTemplateMetrics.penaltyHeight
        let rect = CGRect(
            x: (outputSize.width - width) / 2,
            y: outputSize.height - height - max(24, outputSize.height * 0.050),
            width: width,
            height: height
        ).integral
        let accent = UIColor(red: 1.0, green: 0.64, blue: 0.08, alpha: 1.0)
        drawPopupBackground(rect, accent: accent, cg: cg)

        let team = popupTeamName(for: event.team, state: state)
        let logo = event.team == .away ? awayLogo : homeLogo
        let badgeSize = BroadcastEventPopupTemplateMetrics.penaltyBadgeSize
        let badgeRect = CGRect(
            x: rect.minX + 16,
            y: rect.midY - badgeSize / 2,
            width: badgeSize,
            height: badgeSize
        ).integral
        drawCircularTeamBadge(team: team, logo: logo, accent: accent, in: badgeRect, cg: cg)

        let rightWidth: CGFloat = 330
        let textX = badgeRect.maxX + 14
        let rightRect = CGRect(
            x: rect.maxX - rightWidth - 16,
            y: rect.minY + 12,
            width: rightWidth,
            height: rect.height - 24
        )
        let bodyRect = CGRect(
            x: textX,
            y: rect.minY + 12,
            width: max(100, rightRect.minX - textX - 12),
            height: rect.height - 24
        )

        drawText(
            event.popupTitle.uppercased(),
            in: CGRect(x: bodyRect.minX, y: bodyRect.minY, width: bodyRect.width, height: bodyRect.height * 0.25),
            font: UIFont.systemFont(ofSize: 18, weight: .black),
            color: accent,
            alignment: .left
        )
        drawText(
            team,
            in: CGRect(x: bodyRect.minX, y: bodyRect.minY + bodyRect.height * 0.23, width: bodyRect.width, height: bodyRect.height * 0.34),
            font: UIFont.systemFont(ofSize: 25, weight: .black),
            color: .white,
            alignment: .left
        )
        if let sponsor = event.sponsor {
            let sponsorRect = CGRect(
                x: bodyRect.minX,
                y: bodyRect.minY + bodyRect.height * 0.76,
                width: min(bodyRect.width, 220),
                height: bodyRect.height * 0.24
            ).integral
            drawResolvedSponsorCard(sponsor, in: sponsorRect, cg: cg)
        }

        let frozenPlayerImage = event.frozenPenaltyPlayerImagePNGData.flatMap { UIImage(data: $0)?.cgImage }
        let popupPlayerNumber = (event.team == .away && frozenPlayerImage != nil)
            ? nil
            : event.recognisedPenaltyPlayerNumber
        let recognisedName = event.recognisedHomePlayerName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let nameWidth: CGFloat = (recognisedName?.isEmpty == false) ? 150 : 0
        let nameRect = CGRect(
            x: rightRect.minX,
            y: rightRect.minY,
            width: nameWidth,
            height: rightRect.height * 0.46
        )
        let playerRect = CGRect(
            x: rightRect.minX + nameWidth + (nameWidth > 0 ? 8 : 0),
            y: rightRect.minY,
            width: rightRect.width - nameWidth - (nameWidth > 0 ? 8 : 0),
            height: rightRect.height * 0.46
        )
        if let recognisedName, !recognisedName.isEmpty {
            drawText(
                recognisedName.uppercased(),
                in: nameRect,
                font: UIFont.systemFont(ofSize: 14, weight: .heavy),
                color: UIColor(layout.clockColour),
                alignment: .right
            )
        }
        if let popupPlayerNumber {
            drawText(
                "#\(popupPlayerNumber)",
                in: playerRect,
                font: UIFont.monospacedDigitSystemFont(ofSize: 34, weight: .black),
                color: UIColor(layout.clockColour),
                alignment: .right
            )
        } else if let frozenPlayerImage {
            drawRelayGlyphImage(
                frozenPlayerImage,
                in: playerRect.insetBy(dx: 8, dy: 3),
                color: UIColor(layout.clockColour)
            )
        }

        if let timeText = penaltyPopupTimeText(event) {
            drawText(
                timeText,
                in: CGRect(x: rightRect.minX, y: rightRect.minY + rightRect.height * 0.43, width: rightRect.width, height: rightRect.height * 0.18),
                font: UIFont.monospacedDigitSystemFont(ofSize: 17, weight: .black),
                color: .white,
                alignment: .right
            )
        }

        let clockRect = CGRect(
            x: rightRect.minX,
            y: rightRect.minY + rightRect.height * 0.59,
            width: rightRect.width,
            height: rightRect.height * 0.41
        )
        if !drawFrozenEventClockOnly(event, in: clockRect, layout: layout, textColor: UIColor(layout.clockColour)) {
            drawText(
                event.gameClock ?? "",
                in: clockRect,
                font: UIFont.monospacedDigitSystemFont(ofSize: 20, weight: .heavy),
                color: UIColor.white.withAlphaComponent(0.80),
                alignment: .right
            )
        }
    }

    private static func drawStrengthPopup(_ event: BroadcastEvent, in cg: CGContext, outputSize: CGSize, layout: BroadcastScoreboardLayoutSnapshot) {
        let width = min(outputSize.width * 0.42, BroadcastEventPopupTemplateMetrics.strengthWidth)
        let height = max(BroadcastEventPopupTemplateMetrics.strengthHeight, outputSize.height * 0.080)
        let rect = CGRect(
            x: (outputSize.width - width) / 2,
            y: outputSize.height - height - max(24, outputSize.height * 0.050),
            width: width,
            height: height
        ).integral
        let accent: UIColor
        switch event.team {
        case .home: accent = UIColor(layout.homeScoreColour)
        case .away: accent = UIColor(layout.awayScoreColour)
        case .none: accent = UIColor(layout.clockColour)
        }
        drawPopupBackground(rect, accent: accent, cg: cg)

        let iconRect = CGRect(x: rect.minX + 16, y: rect.midY - 27, width: 54, height: 54).integral
        cg.setFillColor(accent.withAlphaComponent(0.18).cgColor)
        cg.fillRoundedW10i(iconRect, radius: 14)
        cg.setStrokeColor(accent.withAlphaComponent(0.76).cgColor)
        cg.setLineWidth(1.5)
        cg.strokeRoundedW10i(iconRect, radius: 14)
        drawText("3", in: iconRect.insetBy(dx: 5, dy: 5), font: UIFont.systemFont(ofSize: 25, weight: .black), color: accent, alignment: .center)

        let body = CGRect(x: iconRect.maxX + 14, y: rect.minY + 11, width: rect.maxX - iconRect.maxX - 30, height: rect.height - 22)
        drawText("STRENGTH", in: CGRect(x: body.minX, y: body.minY, width: body.width, height: body.height * 0.38), font: UIFont.systemFont(ofSize: 15, weight: .black), color: UIColor(red: 1.0, green: 0.64, blue: 0.08, alpha: 1.0), alignment: .left)
        drawText(strengthPopupSummary(event), in: CGRect(x: body.minX, y: body.minY + body.height * 0.34, width: body.width, height: body.height * 0.62), font: UIFont.systemFont(ofSize: 25, weight: .black), color: .white, alignment: .left)
    }

    private static func strengthPopupSummary(_ event: BroadcastEvent) -> String {
        let detail = event.popupDetail.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail == "5 v 5" { return "FULL STRENGTH" }
        if detail == "4 v 4" || detail == "3 v 3" { return detail }
        let headline = event.popupHeadline.trimmingCharacters(in: .whitespacesAndNewlines)
        if headline.uppercased().contains("FULL STRENGTH") { return "FULL STRENGTH" }
        if let range = headline.range(of: " — ") {
            return String(headline[..<range.lowerBound])
        }
        return headline.isEmpty ? "STRENGTH UPDATED" : headline
    }

    private static func penaltyPopupTimeText(_ event: BroadcastEvent) -> String? {
        let candidates = event.penaltyClockSnapshot.filter { clock in
            guard let eventTeam = event.team, clock.team == eventTeam else { return false }
            if let player = event.recognisedPenaltyPlayerNumber {
                return clock.playerNumber == player
            }
            return clock.isActive
        }
        guard let clock = candidates.first else { return nil }
        let text = clock.displayClock.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text == "--:--" ? nil : text
    }

    @discardableResult
    private static func drawFrozenEventClockOnly(
        _ event: BroadcastEvent,
        in rect: CGRect,
        layout: BroadcastScoreboardLayoutSnapshot,
        textColor: UIColor
    ) -> Bool {
        guard let data = event.frozenClockImagePNGData,
              let image = UIImage(data: data)?.cgImage else { return false }
        let desired = BroadcastScorebugTemplateMetrics.desiredClockZoneSize(for: layout)
        let targetHeight = min(rect.height, max(40, min(54, desired.height)))
        let available = CGRect(
            x: rect.maxX - min(rect.width, targetHeight * BroadcastScorebugTemplateMetrics.clockZoneWidthToHeightRatio),
            y: rect.midY - targetHeight / 2,
            width: min(rect.width, targetHeight * BroadcastScorebugTemplateMetrics.clockZoneWidthToHeightRatio),
            height: targetHeight
        )
        let clockRect = BroadcastScorebugTemplateMetrics.clockZoneRect(fitting: available)
            .insetBy(dx: 0, dy: 2)
        let glyphRect = BroadcastScorebugGlyphLayoutResolver.clockRect(
            sourceSize: BroadcastScorebugGlyphLayoutResolver.visibleContentSize(of: image),
            in: clockRect,
            targetVisibleHeight: clockRect.height
        )
        drawRelayGlyphImage(image, in: glyphRect, color: textColor)
        return true
    }

    @discardableResult
    private static func drawFrozenEventClock(
        _ event: BroadcastEvent,
        in rect: CGRect,
        layout: BroadcastScoreboardLayoutSnapshot,
        textColor: UIColor
    ) -> Bool {
        guard let data = event.frozenClockImagePNGData,
              let image = UIImage(data: data)?.cgImage else { return false }
        let periodHeight = min(24, max(18, rect.height * 0.24))
        drawText(
            event.period.map { "P\($0)" } ?? "P–",
            in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: periodHeight),
            font: UIFont.systemFont(ofSize: 21, weight: .heavy),
            color: textColor.withAlphaComponent(0.74),
            alignment: .right
        )
        let imageBand = CGRect(
            x: rect.minX,
            y: rect.minY + periodHeight,
            width: rect.width,
            height: max(1, rect.height - periodHeight)
        )
        let desired = BroadcastScorebugTemplateMetrics.desiredClockZoneSize(for: layout)
        let available = CGRect(
            x: imageBand.maxX - min(imageBand.width, desired.width),
            y: imageBand.midY - min(imageBand.height, desired.height) / 2,
            width: min(imageBand.width, desired.width),
            height: min(imageBand.height, desired.height)
        )
        let clockRect = BroadcastScorebugTemplateMetrics.clockZoneRect(fitting: available)
            .insetBy(dx: 0, dy: 2)
        let glyphRect = BroadcastScorebugGlyphLayoutResolver.clockRect(
            sourceSize: BroadcastScorebugGlyphLayoutResolver.visibleContentSize(of: image),
            in: clockRect,
            targetVisibleHeight: clockRect.height
        )
        drawRelayGlyphImage(image, in: glyphRect, color: textColor)
        return true
    }

    private static func drawPopupBackground(_ rect: CGRect, accent: UIColor, cg: CGContext) {
        cg.setFillColor(UIColor.black.withAlphaComponent(0.86).cgColor)
        cg.fillRoundedW10i(rect, radius: BroadcastEventPopupTemplateMetrics.cornerRadius)
        cg.setStrokeColor(accent.withAlphaComponent(0.88).cgColor)
        cg.setLineWidth(2)
        cg.strokeRoundedW10i(rect, radius: BroadcastEventPopupTemplateMetrics.cornerRadius)
    }

    private static func drawCircularTeamBadge(team: String, logo: UIImage?, accent: UIColor, in rect: CGRect, cg: CGContext) {
        cg.saveGState()
        cg.setFillColor(accent.withAlphaComponent(0.18).cgColor)
        cg.fillEllipse(in: rect)
        cg.setStrokeColor(accent.withAlphaComponent(0.86).cgColor)
        cg.setLineWidth(2)
        cg.strokeEllipse(in: rect.insetBy(dx: 1, dy: 1))
        if let logo, let cgLogo = logo.cgImage {
            drawUprightImage(logo, naturalWidth: CGFloat(cgLogo.width), naturalHeight: CGFloat(cgLogo.height), in: rect.insetBy(dx: BroadcastEventPopupTemplateMetrics.badgePadding, dy: BroadcastEventPopupTemplateMetrics.badgePadding), cg: cg)
        } else {
            drawText(String(team.prefix(1)), in: rect.insetBy(dx: 6, dy: 8), font: UIFont.systemFont(ofSize: 31, weight: .black), color: accent, alignment: .center)
        }
        cg.restoreGState()
    }

    private static func drawResolvedSponsorCard(_ sponsor: SponsorResolvedBroadcastSponsor, in rect: CGRect, cg: CGContext) {
        cg.setFillColor(UIColor.black.withAlphaComponent(0.30).cgColor)
        cg.fillRoundedW10i(rect, radius: 12)
        cg.setStrokeColor(UIColor.white.withAlphaComponent(0.14).cgColor)
        cg.setLineWidth(1)
        cg.strokeRoundedW10i(rect, radius: 12)
        var textRect = rect.insetBy(dx: 9, dy: 5)
        if let logoData = sponsor.logoData, let image = UIImage(data: logoData), let cgLogo = image.cgImage {
            let logoRect = CGRect(x: rect.minX + 7, y: rect.midY - BroadcastEventPopupTemplateMetrics.sponsorLogoHeight / 2, width: BroadcastEventPopupTemplateMetrics.sponsorLogoWidth, height: BroadcastEventPopupTemplateMetrics.sponsorLogoHeight)
            drawUprightImage(image, naturalWidth: CGFloat(cgLogo.width), naturalHeight: CGFloat(cgLogo.height), in: logoRect, cg: cg)
            textRect.origin.x = logoRect.maxX + BroadcastEventPopupTemplateMetrics.sponsorGap
            textRect.size.width = max(0, rect.maxX - textRect.minX - 8)
        }
        drawText(sponsor.subtitle.uppercased(), in: CGRect(x: textRect.minX, y: textRect.minY, width: textRect.width, height: textRect.height * 0.42), font: UIFont.systemFont(ofSize: 9, weight: .black), color: UIColor.white.withAlphaComponent(0.65), alignment: .right)
        drawText(sponsor.displayTitle.uppercased(), in: CGRect(x: textRect.minX, y: textRect.midY - 1, width: textRect.width, height: textRect.height * 0.55), font: UIFont.systemFont(ofSize: 11, weight: .heavy), color: .white, alignment: .right)
    }

    private static func popupTeamName(for team: Team?, state: ScoreboardState) -> String {
        switch team {
        case .home:
            return cleanTeamName(state.homeTeam ?? "HOME")
        case .away:
            return cleanTeamName(state.awayTeam ?? "AWAY")
        case .none:
            return "TEAM"
        }
    }


    private static func drawGameSponsorStrip(_ snapshot: SponsorRecordingOverlaySnapshot, in badgeRow: CGRect, cg: CGContext, badgeFont: UIFont, layout: BroadcastScoreboardLayoutSnapshot) {
        guard snapshot.isOutputOverlayEnabled else { return }
        let name = snapshot.gameSponsorName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, badgeRow.width > 24, badgeRow.height > 12 else { return }

        let labelFont = UIFont.systemFont(ofSize: max(badgeFont.pointSize + 1, badgeRow.height * 0.20), weight: .black)
        let sponsorFont = UIFont.systemFont(ofSize: max(badgeFont.pointSize + 5, badgeRow.height * 0.38), weight: .black)
        let labelWidth = ("GAME SPONSOR" as NSString).size(withAttributes: [.font: labelFont]).width
        let nameWidth = (name.uppercased() as NSString).size(withAttributes: [.font: sponsorFont]).width
        var logoWidth: CGFloat = 0
        var logoImage: UIImage?
        var naturalSize = CGSize.zero
        if let logoData = snapshot.gameSponsorLogoData,
           let image = UIImage(data: logoData),
           let cgLogo = image.cgImage {
            logoImage = image
            naturalSize = CGSize(width: CGFloat(cgLogo.width), height: CGFloat(cgLogo.height))
            let logoHeight = max(18, BroadcastScorebugTemplateMetrics.gameSponsorLogoMaxHeight(for: layout))
            let naturalAspect = naturalSize.width / max(naturalSize.height, 1)
            logoWidth = min(max(38, logoHeight * naturalAspect), min(badgeRow.width * 0.30, BroadcastScorebugTemplateMetrics.gameSponsorLogoMaxWidth(for: layout)))
        }

        let gap: CGFloat = logoWidth > 0 ? BroadcastScorebugTemplateMetrics.gameSponsorGap(for: layout) : 0
        let rawWidth = max(labelWidth, nameWidth) + logoWidth + gap + (BroadcastScorebugTemplateMetrics.gameSponsorHorizontalPadding(for: layout) * 2)
        let sponsorWidth = min(max(104, rawWidth), badgeRow.width)
        let sponsorRect = CGRect(x: badgeRow.maxX - sponsorWidth, y: badgeRow.minY + 3, width: sponsorWidth, height: badgeRow.height - 6).integral
        cg.setFillColor(UIColor.white.withAlphaComponent(0.08).cgColor)
        cg.fillRoundedW10i(sponsorRect, radius: sponsorRect.height / 2)

        var textRect = sponsorRect.insetBy(dx: BroadcastScorebugTemplateMetrics.gameSponsorHorizontalPadding(for: layout), dy: 3)
        if let logoImage {
            let logoHeight = max(18, min(BroadcastScorebugTemplateMetrics.gameSponsorLogoMaxHeight(for: layout), sponsorRect.height - 8))
            let logoRect = CGRect(x: sponsorRect.minX + BroadcastScorebugTemplateMetrics.gameSponsorHorizontalPadding(for: layout), y: sponsorRect.midY - logoHeight / 2, width: logoWidth, height: logoHeight).integral
            drawUprightImage(logoImage, naturalWidth: naturalSize.width, naturalHeight: naturalSize.height, in: logoRect, cg: cg)
            textRect.origin.x = logoRect.maxX + gap
            textRect.size.width = sponsorRect.maxX - textRect.minX - BroadcastScorebugTemplateMetrics.gameSponsorHorizontalPadding(for: layout)
        }

        let labelRect = CGRect(x: textRect.minX, y: textRect.minY, width: textRect.width, height: textRect.height * 0.40)
        let nameRect = CGRect(x: textRect.minX, y: textRect.minY + textRect.height * 0.32, width: textRect.width, height: textRect.height * 0.68)
        drawText("GAME SPONSOR", in: labelRect, font: labelFont, color: UIColor.white.withAlphaComponent(0.66), alignment: .right)
        drawText(name.uppercased(), in: nameRect, font: sponsorFont, color: UIColor.white.withAlphaComponent(0.96), alignment: .right)
    }

    private static func aspectFitRect(imageWidth: CGFloat, imageHeight: CGFloat, in rect: CGRect) -> CGRect {
        guard imageWidth > 0, imageHeight > 0, rect.width > 0, rect.height > 0 else { return rect }
        let scale = min(rect.width / imageWidth, rect.height / imageHeight)
        let fittedSize = CGSize(width: imageWidth * scale, height: imageHeight * scale)
        return CGRect(
            x: rect.midX - fittedSize.width / 2,
            y: rect.midY - fittedSize.height / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }


    private static func drawUprightImage(_ image: UIImage, naturalWidth: CGFloat, naturalHeight: CGFloat, in rect: CGRect, cg: CGContext) {
        let fitted = aspectFitRect(imageWidth: naturalWidth, imageHeight: naturalHeight, in: rect)
        cg.saveGState()
        cg.clip(to: rect)
        // UIGraphicsImageRenderer uses a UIKit-style context. UIImage.draw(in:)
        // preserves orientation and avoids the upside-down CGImage draw that was
        // visible in recorded game sponsor assets.
        image.draw(in: fitted)
        cg.restoreGState()
    }

    private static func drawSponsorOverlay(_ snapshot: SponsorRecordingOverlaySnapshot, in cg: CGContext, outputSize: CGSize) {
        guard snapshot.isOutputOverlayEnabled else { return }

        if snapshot.leagueEnabled {
            drawSponsorBadge(
                title: snapshot.leagueName,
                subtitle: "LEAGUE",
                logoData: snapshot.leagueLogoData,
                in: BroadcastCompositeStandard.leagueBadgeRect(outputSize: outputSize),
                cg: cg,
                alignment: .left
            )
        }

        if !snapshot.seasonSponsorName.isEmpty {
            drawSponsorBadge(
                title: snapshot.seasonSponsorName,
                subtitle: "SEASON SPONSOR",
                logoData: snapshot.seasonSponsorLogoData,
                in: BroadcastCompositeStandard.seasonSponsorBadgeRect(outputSize: outputSize),
                cg: cg,
                alignment: .right
            )
        }

    }

    private static func drawSponsorBadge(title: String, subtitle: String, logoData: Data?, in anchorRect: CGRect, cg: CGContext, alignment: NSTextAlignment) {
        let resolved = dynamicSponsorBadgeRect(title: title, subtitle: subtitle, logoData: logoData, anchorRect: anchorRect, alignment: alignment)
        let rect = resolved.rect
        cg.setFillColor(UIColor.black.withAlphaComponent(0.46).cgColor)
        cg.fillRoundedW10i(rect, radius: rect.height / 2)
        cg.setStrokeColor(UIColor.white.withAlphaComponent(0.16).cgColor)
        cg.setLineWidth(1)
        cg.strokeRoundedW10i(rect, radius: rect.height / 2)

        var textRect = rect.insetBy(dx: 12, dy: 5)
        if let logoData, let logoImage = UIImage(data: logoData), let cgLogo = logoImage.cgImage {
            let logoSide = min(max(22, rect.height - 10), resolved.logoWidth)
            let logoRect: CGRect
            if alignment == .right {
                logoRect = CGRect(x: rect.maxX - logoSide - 7, y: rect.midY - logoSide / 2, width: logoSide, height: logoSide)
                textRect.size.width = max(0, logoRect.minX - textRect.minX - 5)
            } else {
                logoRect = CGRect(x: rect.minX + 7, y: rect.midY - logoSide / 2, width: logoSide, height: logoSide)
                textRect.origin.x = logoRect.maxX + 5
                textRect.size.width = rect.maxX - textRect.minX - 12
            }
            cg.saveGState()
            cg.setFillColor(UIColor.white.withAlphaComponent(0.12).cgColor)
            cg.fillRoundedW10i(logoRect, radius: 8)
            cg.restoreGState()
            drawUprightImage(logoImage, naturalWidth: CGFloat(cgLogo.width), naturalHeight: CGFloat(cgLogo.height), in: logoRect.insetBy(dx: 3, dy: 3), cg: cg)
        }

        let subtitleRect = CGRect(x: textRect.minX, y: textRect.minY + 1, width: textRect.width, height: textRect.height * 0.38)
        let titleRect = CGRect(x: textRect.minX, y: textRect.minY + textRect.height * 0.36, width: textRect.width, height: textRect.height * 0.60)
        drawText(subtitle.uppercased(), in: subtitleRect, font: UIFont.systemFont(ofSize: max(7, rect.height * 0.20), weight: .black), color: UIColor.white.withAlphaComponent(0.58), alignment: alignment)
        drawText(title.isEmpty ? "SPONSOR" : title.uppercased(), in: titleRect, font: UIFont.systemFont(ofSize: max(10, rect.height * 0.31), weight: .heavy), color: .white, alignment: alignment)
    }

    private static func dynamicSponsorBadgeRect(title: String, subtitle: String, logoData: Data?, anchorRect: CGRect, alignment: NSTextAlignment) -> (rect: CGRect, logoWidth: CGFloat) {
        let titleText = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "SPONSOR" : title.uppercased()
        let subtitleText = subtitle.uppercased()
        let titleFont = UIFont.systemFont(ofSize: max(10, anchorRect.height * 0.31), weight: .heavy)
        let subtitleFont = UIFont.systemFont(ofSize: max(7, anchorRect.height * 0.20), weight: .black)
        let titleWidth = (titleText as NSString).size(withAttributes: [.font: titleFont]).width
        let subtitleWidth = (subtitleText as NSString).size(withAttributes: [.font: subtitleFont]).width
        var logoWidth: CGFloat = 0
        if let logoData, let image = UIImage(data: logoData), let cgLogo = image.cgImage {
            let logoSide = max(22, anchorRect.height - 10)
            let aspect = CGFloat(cgLogo.width) / max(CGFloat(cgLogo.height), 1)
            logoWidth = min(max(logoSide, logoSide * aspect), min(anchorRect.width * 0.42, logoSide * 3.2))
        }
        let textWidth = max(titleWidth, subtitleWidth)
        let padding: CGFloat = 20
        let gap: CGFloat = logoWidth > 0 ? 6 : 0
        let rawWidth = textWidth + logoWidth + gap + padding
        let width = min(max(112, rawWidth), anchorRect.width)
        let x = alignment == .right ? anchorRect.maxX - width : anchorRect.minX
        return (BroadcastCompositeStandard.pixelAligned(CGRect(x: x, y: anchorRect.minY, width: width, height: anchorRect.height)), logoWidth)
    }

    private static func isActivelyRunningOCRStatus(_ text: String) -> Bool {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "OCR RUNNING", "OCR ACQUIRING SCOREBOARD", "OCR ARMING PENALTIES":
            return true
        default:
            return false
        }
    }

    private static func cleanTeamName(_ name: String) -> String {
        // UX9: preserve the configured full team name so Broadcast/recording
        // cannot drift to an abbreviated value while Settings shows the full one.
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Team" : trimmed
    }

    private enum OverlayTeamSide { case home, away }

    private struct PenaltyOverlayEntry {
        let player: String
        let clock: String
    }

    private static func uiFontWeight(_ weight: BroadcastScoreboardFontWeight) -> UIFont.Weight {
        switch weight {
        case .regular: return .regular
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }

    private static func relayScoreText(for side: OverlayTeamSide, fallback: String, relay snapshot: ScoreboardImageRelaySnapshot) -> String {
        guard snapshot.enabled else { return fallback }
        let key: OCRRegionKey = side == .home ? .homeScore : .awayScore
        return snapshot.visualValue(for: key) ?? fallback
    }

    /// Build 631 recording/clip parity for unresolved scores. Use the same fixed
    /// score geometry as text, but draw the physical relay crop when a material
    /// change is visible and OCR has not yet resolved a valid 0...99 value.
    private static func drawRelayScore(
        for side: OverlayTeamSide,
        fallback: String,
        in rect: CGRect,
        font: UIFont,
        color: UIColor,
        relay snapshot: ScoreboardImageRelaySnapshot
    ) {
        let key: OCRRegionKey = side == .home ? .homeScore : .awayScore
        if snapshot.enabled,
           snapshot.visualValue(for: key) == nil,
           let image = snapshot.image(for: key) {
            drawRelayGlyphImage(image, in: rect, color: color, crisp: true)
            return
        }
        drawScoreText(
            snapshot.enabled ? (snapshot.visualValue(for: key) ?? fallback) : fallback,
            in: rect,
            font: font,
            color: color,
            alignment: .center
        )
    }

    private static func drawRelayGlyphImage(
        _ image: CGImage,
        in rect: CGRect,
        color: UIColor,
        crisp: Bool = false,
        stretchToFill: Bool = false,
        cropVisibleContent: Bool = false
    ) {
        guard rect.width > 1, rect.height > 1 else { return }
        let displayImage = cropVisibleContent
            ? BroadcastScorebugGlyphLayoutResolver.visibleContentImage(of: image)
            : image
        let fitted = stretchToFill
            ? rect
            : aspectFitRect(
                imageWidth: CGFloat(displayImage.width),
                imageHeight: CGFloat(displayImage.height),
                in: rect
            )
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let previousInterpolation = context.interpolationQuality
        context.interpolationQuality = crisp ? .none : .medium
        defer { context.interpolationQuality = previousInterpolation }
        let tinted = UIImage(cgImage: displayImage)
            .withTintColor(color, renderingMode: .alwaysOriginal)
        tinted.draw(in: fitted)
    }

    private static func scoreUIColor(layout: BroadcastScoreboardLayoutSnapshot, side: OverlayTeamSide) -> UIColor {
        BroadcastScorebugColourResolver.scoreUIColor(
            layout: layout,
            side: side == .home ? .home : .away
        )
    }

    private static func strengthAccentColor(
        _ strengthState: StrengthState,
        layout: BroadcastScoreboardLayoutSnapshot
    ) -> UIColor {
        strengthAccentColor(advantagedTeam: strengthState.advantagedTeam, layout: layout)
    }

    private static func strengthAccentColor(
        advantagedTeam: Team?,
        layout: BroadcastScoreboardLayoutSnapshot
    ) -> UIColor {
        switch advantagedTeam {
        case .home:
            return scoreUIColor(layout: layout, side: .home)
        case .away:
            return scoreUIColor(layout: layout, side: .away)
        case nil:
            return UIColor(layout.accentColour)
        }
    }

    private static func penaltyLabels(state: ScoreboardState, side: OverlayTeamSide) -> [PenaltyOverlayEntry?] {
        let values: [(Int?, String?)]
        switch side {
        case .home:
            values = [
                (state.homePenalty1Player, state.homePenalty1Clock),
                (state.homePenalty2Player, state.homePenalty2Clock)
            ]
        case .away:
            values = [
                (state.awayPenalty1Player, state.awayPenalty1Clock),
                (state.awayPenalty2Player, state.awayPenalty2Clock)
            ]
        }
        return values.map { player, clock in
            guard let clock, isActivePenaltyClockText(clock) else { return nil }
            return PenaltyOverlayEntry(
                player: player.map { "#\($0)" } ?? "",
                clock: clock
            )
        }
    }

    private static func isActivePenaltyClockText(_ value: String) -> Bool {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard parts.count == 2,
              let minutes = Int(parts[0]),
              let seconds = Int(parts[1]),
              (0...59).contains(seconds) else { return false }
        return minutes > 0 || seconds > 0
    }

    private static func drawPenaltyLabels(
        _ labels: [PenaltyOverlayEntry?],
        in rect: CGRect,
        accent: UIColor,
        side: OverlayTeamSide,
        layout: BroadcastScoreboardLayoutSnapshot,
        metrics: BroadcastScorebugResolvedMetrics,
        layoutFitScale: CGFloat,
        relay: ScoreboardImageRelaySnapshot
    ) {
        guard let cg = UIGraphicsGetCurrentContext(), rect.width > 8, rect.height > 8 else { return }
        let geometryScale = max(0.0001, layoutFitScale)
        let requestedHeight = metrics.renderedPenaltyPanelHeight * geometryScale
        let panelRect = CGRect(
            x: rect.minX,
            y: rect.midY - min(rect.height, requestedHeight) / 2,
            width: rect.width,
            height: min(rect.height, requestedHeight)
        ).integral
        let headerHeight = min(
            panelRect.height * 0.25,
            metrics.renderedPenaltyHeaderHeight * geometryScale
        )
        let rowGap = max(1, metrics.renderedPenaltyRowGap * geometryScale)
        let columnGap = max(1, metrics.renderedPenaltyColumnGap * geometryScale)
        let rowsAvailable = max(2, panelRect.height - headerHeight - rowGap * 2)
        let rowHeight = rowsAvailable / 2
        let availableColumns = max(2, panelRect.width - columnGap)
        let requestedPlayerWidth = max(
            metrics.renderedPenaltyPlayerWidth,
            metrics.renderedPenaltyTimerReferenceHeight * 2.20
        ) * geometryScale
        // Build 656 mirrors the live scorebug column contract. Width is
        // reserved for the player maximum, and the timer receives the remainder;
        // neither field is allowed to reduce the shared visible height.
        let playerWidth = floor(min(availableColumns, requestedPlayerWidth))
        let timerWidth = max(1, availableColumns - playerWidth)

        cg.setFillColor(UIColor.black.withAlphaComponent(0.20).cgColor)
        cg.fillRoundedW10i(panelRect, radius: 12)
        cg.setStrokeColor(accent.withAlphaComponent(0.34).cgColor)
        cg.setLineWidth(1)
        cg.strokeRoundedW10i(panelRect, radius: 12)

        func columns(in row: CGRect) -> (player: CGRect, timer: CGRect) {
            let player = CGRect(x: row.minX, y: row.minY, width: playerWidth, height: row.height).integral
            let timer = CGRect(
                x: player.maxX + columnGap,
                y: row.minY,
                width: timerWidth,
                height: row.height
            ).integral
            return (player, timer)
        }

        let header = CGRect(x: panelRect.minX, y: panelRect.minY, width: panelRect.width, height: headerHeight)
        let headerColumns = columns(in: header)
        let headerFont = UIFont.systemFont(ofSize: max(8, headerHeight * 0.58), weight: .black)
        drawText("PLYR", in: headerColumns.player.insetBy(dx: 1, dy: 0), font: headerFont, color: UIColor.white.withAlphaComponent(0.70), alignment: .center)
        drawText("PENALTY", in: headerColumns.timer.insetBy(dx: 1, dy: 0), font: headerFont, color: UIColor.white.withAlphaComponent(0.70), alignment: .center)

        let team: Team = side == .home ? .home : .away
        let penaltyColor = BroadcastScorebugColourResolver.penaltyUIColor(
            layout: layout,
            side: side == .home ? .home : .away,
            opacity: 0.98
        )

        for slotIndex in 0..<2 {
            let row = CGRect(
                x: panelRect.minX,
                y: header.maxY + rowGap + CGFloat(slotIndex) * (rowHeight + rowGap),
                width: panelRect.width,
                height: rowHeight
            ).integral
            let cellRects = columns(in: row)
            let pair = relay.penaltyPair(side: team, slot: slotIndex + 1)
            let softwareEntry = labels.indices.contains(slotIndex) ? labels[slotIndex] : nil
            let active = relay.enabled ? pair.active : softwareEntry != nil

            for cell in [cellRects.player, cellRects.timer] {
                cg.setFillColor(accent.withAlphaComponent(active ? 0.24 : 0.07).cgColor)
                cg.fillRoundedW10i(cell, radius: 5)
                cg.setStrokeColor(accent.withAlphaComponent(active ? 0.66 : 0.16).cgColor)
                cg.setLineWidth(1)
                cg.strokeRoundedW10i(cell, radius: 5)
            }
            guard active else { continue }

            let playerInner = cellRects.player.insetBy(dx: 2, dy: 2)
            let timerInner = cellRects.timer.insetBy(dx: 2, dy: 2)
            let stableCanvasEnabled = RinkLensRiskFeaturePolicy.isEnabled(.stablePenaltyTimerCanvasScaleV2)
            let heightParityEnabled = !stableCanvasEnabled
                && RinkLensRiskFeaturePolicy.isEnabled(.penaltyTimerVisibleHeightParityV2)
            let playerSourceSize = pair.playerImage.map { image in
                heightParityEnabled
                    ? BroadcastScorebugGlyphLayoutResolver.visibleContentSize(of: image)
                    : CGSize(width: image.width, height: image.height)
            }
            let timerSourceSize = pair.time.map { image in
                heightParityEnabled
                    ? BroadcastScorebugGlyphLayoutResolver.visibleContentSize(of: image)
                    : CGSize(width: image.width, height: image.height)
            }
            let pairLayout = BroadcastScorebugGlyphLayoutResolver.penaltyPairInSeparateCells(
                playerSourceSize: playerSourceSize,
                timerSourceSize: timerSourceSize,
                playerAvailableSize: playerInner.size,
                timerAvailableSize: timerInner.size,
                referenceVisibleHeight: min(playerInner.height, timerInner.height)
            )
            let playerGlyphRect = CGRect(
                x: playerInner.midX - pairLayout.player.frameSize.width / 2,
                y: playerInner.midY - pairLayout.player.frameSize.height / 2,
                width: pairLayout.player.frameSize.width,
                height: pairLayout.player.frameSize.height
            ).integral
            let baseTimerGlyphRect = CGRect(
                x: timerInner.midX - pairLayout.timer.frameSize.width / 2,
                y: timerInner.midY - pairLayout.timer.frameSize.height / 2,
                width: pairLayout.timer.frameSize.width,
                height: pairLayout.timer.frameSize.height
            )
            let timerDisplayScale = stableCanvasEnabled
                ? BroadcastScorebugTemplateMetrics.stablePenaltyTimerDisplayScale
                : 1.0
            let scaledTimerSize = CGSize(
                width: min(timerInner.width, baseTimerGlyphRect.width * timerDisplayScale),
                height: min(timerInner.height, baseTimerGlyphRect.height * timerDisplayScale)
            )
            let timerGlyphRect = CGRect(
                x: timerInner.midX - scaledTimerSize.width / 2,
                y: timerInner.midY - scaledTimerSize.height / 2,
                width: scaledTimerSize.width,
                height: scaledTimerSize.height
            ).integral
            if relay.enabled {
                if let playerImage = pair.playerImage {
                    drawRelayGlyphImage(
                        playerImage,
                        in: playerGlyphRect,
                        color: penaltyColor,
                        crisp: false,
                        stretchToFill: false,
                        cropVisibleContent: heightParityEnabled
                    )
                } else if let player = pair.player {
                    drawText(
                        player,
                        in: playerInner,
                        font: UIFont.monospacedDigitSystemFont(ofSize: max(11, playerInner.height * 0.82), weight: .black),
                        color: penaltyColor,
                        alignment: .center
                    )
                }
                if let time = pair.time {
                    drawRelayGlyphImage(
                        time,
                        in: timerGlyphRect,
                        color: penaltyColor,
                        crisp: false,
                        stretchToFill: false,
                        cropVisibleContent: heightParityEnabled
                    )
                }
            } else if let entry = softwareEntry {
                let font = UIFont.monospacedDigitSystemFont(ofSize: max(11, rowHeight * 0.56), weight: .black)
                drawText(entry.player, in: playerInner, font: font, color: penaltyColor, alignment: .center)
                drawText(entry.clock, in: timerInner, font: font, color: penaltyColor, alignment: .center)
            }
        }
    }

    private static func drawTemplateTeamCell(
        _ team: String,
        score: String,
        logo: UIImage?,
        in rect: CGRect,
        accent: UIColor,
        teamColor: UIColor,
        scoreColor: UIColor,
        logoBackground: UIColor,
        teamBackground: UIColor,
        teamFont: UIFont,
        scoreFont: UIFont,
        side: OverlayTeamSide,
        logoPosition: BroadcastScoreboardLogoPosition,
        densityMode: BroadcastScoreboardDensityMode,
        layout: BroadcastScoreboardLayoutSnapshot,
        metrics: BroadcastScorebugResolvedMetrics,
        layoutFitScale: CGFloat,
        relay: ScoreboardImageRelaySnapshot
    ) {
        guard let cg = UIGraphicsGetCurrentContext(), rect.width > 20, rect.height > 20 else { return }
        let contentRect = rect

        cg.setFillColor(teamBackground.cgColor)
        cg.fillRoundedW10i(rect.insetBy(dx: 1, dy: 1), radius: 20)

        switch logoPosition {
        case .besideTeamName:
            drawTemplateBesideTeamNameCell(
                team,
                score: score,
                logo: logo,
                in: contentRect,
                accent: accent,
                teamColor: teamColor,
                scoreColor: scoreColor,
                logoBackground: logoBackground,
                teamBackground: teamBackground,
                teamFont: teamFont,
                scoreFont: scoreFont,
                side: side,
                densityMode: densityMode,
                layout: layout,
                metrics: metrics,
                layoutFitScale: layoutFitScale,
                relay: relay
            )
        case .centredAboveTeamName:
            drawTemplateLogoAboveTeamNameCell(
                team,
                score: score,
                logo: logo,
                in: contentRect,
                accent: accent,
                teamColor: teamColor,
                scoreColor: scoreColor,
                logoBackground: logoBackground,
                teamBackground: teamBackground,
                teamFont: teamFont,
                scoreFont: scoreFont,
                side: side,
                densityMode: densityMode,
                layout: layout,
                metrics: metrics,
                layoutFitScale: layoutFitScale,
                relay: relay
            )
        }
    }

    private static func drawTemplateBesideTeamNameCell(
        _ team: String,
        score: String,
        logo: UIImage?,
        in rect: CGRect,
        accent: UIColor,
        teamColor: UIColor,
        scoreColor: UIColor,
        logoBackground: UIColor,
        teamBackground: UIColor,
        teamFont: UIFont,
        scoreFont: UIFont,
        side: OverlayTeamSide,
        densityMode: BroadcastScoreboardDensityMode,
        layout: BroadcastScoreboardLayoutSnapshot,
        metrics: BroadcastScorebugResolvedMetrics,
        layoutFitScale: CGFloat,
        relay: ScoreboardImageRelaySnapshot
    ) {
        guard let cg = UIGraphicsGetCurrentContext() else { return }
        cg.setFillColor(teamBackground.cgColor)
        cg.fillRoundedW10i(rect.insetBy(dx: 1, dy: 2), radius: max(18, rect.height / 2))
        let geometryScale = max(0.0001, layoutFitScale)
        let logoSide = min(
            metrics.renderedLogoSize * geometryScale,
            max(1, rect.height - 4)
        )
        let logoRect: CGRect
        let scoreWidth = metrics.renderedScoreColumnWidth * geometryScale
        let nameGap = metrics.renderedLogoNameSpacing * geometryScale
        let scoreRect: CGRect
        let nameRect: CGRect
        if side == .home {
            logoRect = CGRect(x: rect.minX, y: rect.midY - logoSide / 2, width: logoSide, height: logoSide)
            scoreRect = CGRect(x: rect.maxX - scoreWidth, y: rect.midY - scoreFont.lineHeight / 2 - 2, width: scoreWidth, height: scoreFont.lineHeight + 4)
            nameRect = CGRect(x: logoRect.maxX + nameGap, y: rect.minY + 5, width: max(0, scoreRect.minX - logoRect.maxX - nameGap - 5), height: rect.height - 10)
            drawLogoBox(logo, in: logoRect, accent: accent, background: logoBackground)
            drawJustifiedTeamName(
                team,
                in: nameRect,
                accent: accent,
                teamColor: teamColor,
                teamFont: teamFont,
                alignment: teamNameTextAlignment(for: side)
            )
            drawRelayScore(
                for: side,
                fallback: score,
                in: scoreRect,
                font: scoreFont,
                color: scoreColor,
                relay: relay
            )
        } else {
            scoreRect = CGRect(x: rect.minX, y: rect.midY - scoreFont.lineHeight / 2 - 2, width: scoreWidth, height: scoreFont.lineHeight + 4)
            logoRect = CGRect(x: rect.maxX - logoSide, y: rect.midY - logoSide / 2, width: logoSide, height: logoSide)
            nameRect = CGRect(x: scoreRect.maxX + nameGap + 3, y: rect.minY + 5, width: max(0, logoRect.minX - scoreRect.maxX - nameGap - 6), height: rect.height - 10)
            drawRelayScore(
                for: side,
                fallback: score,
                in: scoreRect,
                font: scoreFont,
                color: scoreColor,
                relay: relay
            )
            drawJustifiedTeamName(
                team,
                in: nameRect,
                accent: accent,
                teamColor: teamColor,
                teamFont: teamFont,
                alignment: teamNameTextAlignment(for: side)
            )
            drawLogoBox(logo, in: logoRect, accent: accent, background: logoBackground)
        }
    }

    private static func drawTemplateLogoAboveTeamNameCell(
        _ team: String,
        score: String,
        logo: UIImage?,
        in rect: CGRect,
        accent: UIColor,
        teamColor: UIColor,
        scoreColor: UIColor,
        logoBackground: UIColor,
        teamBackground: UIColor,
        teamFont: UIFont,
        scoreFont: UIFont,
        side: OverlayTeamSide,
        densityMode: BroadcastScoreboardDensityMode,
        layout: BroadcastScoreboardLayoutSnapshot,
        metrics: BroadcastScorebugResolvedMetrics,
        layoutFitScale: CGFloat,
        relay: ScoreboardImageRelaySnapshot
    ) {
        guard let cg = UIGraphicsGetCurrentContext() else { return }
        cg.setFillColor(teamBackground.cgColor)
        cg.fillRoundedW10i(rect.insetBy(dx: 1, dy: 2), radius: max(18, rect.height / 2))
        let geometryScale = max(0.0001, layoutFitScale)
        let logoSide = min(
            metrics.renderedLogoSize * geometryScale,
            max(30 * metrics.outputScale * geometryScale, rect.height * 0.76)
        )
        let lowerY = rect.minY + logoSide + metrics.renderedLogoNameSpacing * geometryScale
        let lowerRect = CGRect(x: rect.minX, y: lowerY, width: rect.width, height: max(1, rect.maxY - lowerY))
        let scoreWidth = metrics.renderedScoreColumnWidth * geometryScale
        let availableNameWidth = max(70 * metrics.outputScale * geometryScale, lowerRect.width - scoreWidth - 8 * metrics.outputScale * geometryScale)
        let measuredNameWidth = min(
            availableNameWidth,
            max(
                88 * metrics.outputScale * geometryScale,
                min(
                    BroadcastScorebugTemplateMetrics.centredNameMaxWidth(for: layout, teamName: team) * metrics.outputScale * geometryScale,
                    (team as NSString).size(withAttributes: [.font: teamFont]).width + 18 * metrics.outputScale * geometryScale
                )
            )
        )
        var nameRect = CGRect(x: lowerRect.midX - measuredNameWidth / 2, y: lowerRect.minY, width: measuredNameWidth, height: lowerRect.height)
        var scoreRect: CGRect
        if side == .home {
            scoreRect = CGRect(x: nameRect.maxX + 7 * metrics.outputScale * geometryScale, y: lowerRect.midY - scoreFont.lineHeight / 2 - 2 * metrics.outputScale * geometryScale, width: scoreWidth, height: scoreFont.lineHeight + 4 * metrics.outputScale * geometryScale)
        } else {
            scoreRect = CGRect(x: nameRect.minX - scoreWidth - 7 * metrics.outputScale * geometryScale, y: lowerRect.midY - scoreFont.lineHeight / 2 - 2 * metrics.outputScale * geometryScale, width: scoreWidth, height: scoreFont.lineHeight + 4 * metrics.outputScale * geometryScale)
        }
        let unionMin = min(nameRect.minX, scoreRect.minX)
        let unionMax = max(nameRect.maxX, scoreRect.maxX)
        var shift: CGFloat = 0
        if unionMin < lowerRect.minX { shift = lowerRect.minX - unionMin }
        if unionMax + shift > lowerRect.maxX { shift = lowerRect.maxX - unionMax }
        nameRect = nameRect.offsetBy(dx: shift, dy: 0)
        scoreRect = scoreRect.offsetBy(dx: shift, dy: 0)
        let logoRect = CGRect(x: nameRect.midX - logoSide / 2, y: rect.minY, width: logoSide, height: logoSide)
        drawLogoBox(logo, in: logoRect, accent: accent, background: logoBackground)
        if side == .home {
            drawJustifiedTeamName(
                team,
                in: nameRect,
                accent: accent,
                teamColor: teamColor,
                teamFont: teamFont,
                alignment: teamNameTextAlignment(for: side)
            )
            drawRelayScore(
                for: side,
                fallback: score,
                in: scoreRect,
                font: scoreFont,
                color: scoreColor,
                relay: relay
            )
        } else {
            drawRelayScore(
                for: side,
                fallback: score,
                in: scoreRect,
                font: scoreFont,
                color: scoreColor,
                relay: relay
            )
            drawJustifiedTeamName(
                team,
                in: nameRect,
                accent: accent,
                teamColor: teamColor,
                teamFont: teamFont,
                alignment: teamNameTextAlignment(for: side)
            )
        }
    }

    private static func drawLogoBox(_ logo: UIImage?, in rect: CGRect, accent: UIColor, background: UIColor) {
        guard let cg = UIGraphicsGetCurrentContext() else { return }
        cg.setFillColor(background.cgColor)
        cg.fillRoundedW10i(rect, radius: 11)
        cg.setStrokeColor(accent.withAlphaComponent(0.65).cgColor)
        cg.setLineWidth(1)
        cg.strokeRoundedW10i(rect, radius: 11)
        if let logo, let cgLogo = logo.cgImage {
            drawUprightImage(logo, naturalWidth: CGFloat(cgLogo.width), naturalHeight: CGFloat(cgLogo.height), in: rect.insetBy(dx: 6, dy: 6), cg: cg)
        } else {
            drawText("◆", in: rect.insetBy(dx: 8, dy: 8), font: UIFont.systemFont(ofSize: rect.height * 0.40, weight: .bold), color: accent.withAlphaComponent(0.80), alignment: .center)
        }
    }

    private static func teamNameTextAlignment(for side: OverlayTeamSide) -> NSTextAlignment {
        switch BroadcastScorebugTeamNameAlignmentResolver.alignment(
            for: side == .home ? .home : .away
        ) {
        case .leading:
            return .left
        case .trailing:
            return .right
        }
    }

    private static func drawJustifiedTeamName(_ team: String, in rect: CGRect, accent: UIColor, teamColor: UIColor, teamFont: UIFont, alignment: NSTextAlignment) {
        let lineHeight: CGFloat = 3
        let textRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(1, rect.height - 8))
        drawTemplateTeamName(team, in: textRect, font: teamFont, color: teamColor, alignment: alignment)
        let lineWidth = min(max(34, rect.width * 0.44), 54)
        let lineX: CGFloat
        switch alignment {
        case .right:
            lineX = rect.maxX - lineWidth
        case .center:
            lineX = rect.midX - lineWidth / 2
        default:
            lineX = rect.minX
        }
        guard let cg = UIGraphicsGetCurrentContext(), rect.width > 4 else { return }
        cg.setFillColor(accent.cgColor)
        cg.fillRoundedW10i(CGRect(x: lineX, y: rect.maxY - lineHeight, width: lineWidth, height: lineHeight), radius: lineHeight / 2)
    }

    private static func multipliedAlpha(_ color: UIColor, _ opacity: CGFloat) -> UIColor {
        color.withAlphaComponent(color.cgColor.alpha * opacity)
    }

    private static func drawTemplateCenterCell(
        period: String,
        clock: String,
        strengthText: String,
        showsClockAndStrength: Bool,
        in rect: CGRect,
        periodFont: UIFont,
        clockFont: UIFont,
        periodColor: UIColor,
        clockColor: UIColor,
        strengthColor: UIColor,
        borderColor: UIColor,
        layout: BroadcastScoreboardLayoutSnapshot,
        metrics: BroadcastScorebugResolvedMetrics,
        layoutFitScale: CGFloat,
        relay: ScoreboardImageRelaySnapshot
    ) {
        guard let cg = UIGraphicsGetCurrentContext() else { return }
        cg.setFillColor(UIColor.black.withAlphaComponent(CGFloat(BroadcastScorebugPaintContract.centreFillOpacity)).cgColor)
        cg.fillRoundedW10i(rect, radius: 16)
        cg.setStrokeColor(multipliedAlpha(showsClockAndStrength ? strengthColor : borderColor, CGFloat(BroadcastScorebugPaintContract.centreStrokeOpacity)).cgColor)
        cg.setLineWidth(1)
        cg.strokeRoundedW10i(rect, radius: 16)

        // Fixed typography and the scalable Clock band come from the same
        // resolved metric object. `layoutFitScale` is the explicit hard-fit
        // constraint for a smaller output rectangle; no font is used as a scale proxy.
        let geometryScale = max(0.0001, layoutFitScale)
        let desiredContentHeight = metrics.renderedCentreHeight * geometryScale
        let contentRect = CGRect(
            x: rect.minX,
            y: rect.midY - min(rect.height, desiredContentHeight) / 2,
            width: rect.width,
            height: min(rect.height, desiredContentHeight)
        )
        let periodBandHeight = metrics.renderedPeriodBandHeight * geometryScale
        let strengthBandHeight = metrics.renderedStrengthBandHeight * geometryScale
        let periodRect = CGRect(
            x: contentRect.minX,
            y: contentRect.minY,
            width: contentRect.width,
            height: min(contentRect.height, periodBandHeight)
        )
        let strengthRect = CGRect(
            x: contentRect.minX,
            y: max(periodRect.maxY, contentRect.maxY - strengthBandHeight),
            width: contentRect.width,
            height: min(contentRect.height, strengthBandHeight)
        )
        // Recovery CP / RL-209: the accepted MatchState value is the
        // presentation fallback while a physical relay image/value is absent.
        // A transient relay gap must never replace a valid P1 with P–.
        let displayedPeriod = relay.enabled
            ? relay.visualValue(for: .period).map { "P\($0)" } ?? period
            : period
        if !showsClockAndStrength {
            drawText(
                displayedPeriod,
                in: contentRect,
                font: periodFont,
                color: periodColor,
                alignment: .center
            )
            return
        }
        drawText(
            displayedPeriod,
            in: periodRect,
            font: periodFont,
            color: periodColor,
            alignment: .center
        )

        let clockBandRect = CGRect(
            x: contentRect.minX,
            y: periodRect.maxY,
            width: contentRect.width,
            height: max(1, strengthRect.minY - periodRect.maxY)
        )
        let preferredClock = metrics.renderedClockZoneSize
        let clockAvailable = CGRect(
            x: clockBandRect.midX - min(clockBandRect.width - 6 * metrics.outputScale * geometryScale, preferredClock.width * geometryScale) / 2,
            y: clockBandRect.midY - min(clockBandRect.height - 2 * metrics.outputScale * geometryScale, preferredClock.height * geometryScale) / 2,
            width: max(1, min(clockBandRect.width - 6 * metrics.outputScale * geometryScale, preferredClock.width * geometryScale)),
            height: max(1, min(clockBandRect.height - 2 * metrics.outputScale * geometryScale, preferredClock.height * geometryScale))
        )
        let clockRect = BroadcastScorebugTemplateMetrics.clockZoneRect(fitting: clockAvailable)
        if relay.enabled {
            if let clockImage = relay.image(for: .clock) {
                let glyphRect = BroadcastScorebugGlyphLayoutResolver.clockRect(
                    sourceSize: BroadcastScorebugGlyphLayoutResolver.visibleContentSize(of: clockImage),
                    in: clockRect,
                    targetVisibleHeight: clockRect.height
                )
                drawRelayGlyphImage(clockImage, in: glyphRect, color: clockColor, crisp: true)
            } else {
                // Keep the accepted clock visible inside the same centre pill
                // until a fresh physical relay glyph is actually available.
                drawText(
                    clock,
                    in: clockRect,
                    font: clockFont,
                    color: clockColor,
                    alignment: .center
                )
            }
        } else {
            drawText(
                clock,
                in: clockRect,
                font: clockFont,
                color: clockColor,
                alignment: .center
            )
        }
        // Build 597: use the same enlarged, fit-to-band manpower contract as
        // SwiftUI. `drawText` reduces only when the rendered output is smaller
        // than the resolved centre cell, preserving preview/recording parity.
        drawText(
            strengthText,
            in: strengthRect.insetBy(dx: 3 * metrics.outputScale * geometryScale, dy: 0),
            font: UIFont.systemFont(ofSize: metrics.renderedStrengthFontSize * geometryScale, weight: .black),
            color: strengthColor,
            alignment: .center
        )
    }

    private static func drawTeamCell(_ team: String, score: String, logo: UIImage? = nil, in rect: CGRect, accent: UIColor, teamFont: UIFont, scoreFont: UIFont, alignRight: Bool, relay: ScoreboardImageRelaySnapshot) {
        guard rect.width > 20, rect.height > 20 else { return }
        var contentRect = rect
        if let logo, let cgLogo = logo.cgImage {
            let logoSide = min(max(30, rect.height * 0.64), min(58, rect.width * 0.22))
            let logoRect = alignRight
                ? CGRect(x: rect.maxX - logoSide, y: rect.midY - logoSide / 2, width: logoSide, height: logoSide)
                : CGRect(x: rect.minX, y: rect.midY - logoSide / 2, width: logoSide, height: logoSide)
            drawRoundedLogoBackground(in: logoRect, accent: accent)
            if let cg = UIGraphicsGetCurrentContext() {
                drawUprightImage(logo, naturalWidth: CGFloat(cgLogo.width), naturalHeight: CGFloat(cgLogo.height), in: logoRect.insetBy(dx: 5, dy: 5), cg: cg)
            }
            if alignRight {
                contentRect.size.width = max(0, logoRect.minX - rect.minX - 8)
            } else {
                contentRect.origin.x = logoRect.maxX + 8
                contentRect.size.width = max(0, rect.maxX - contentRect.minX)
            }
        }

        let scoreWidth = min(max(58, contentRect.width * 0.26), 82)
        let gap: CGFloat = 8
        let scoreRect = alignRight
            ? CGRect(x: contentRect.minX, y: contentRect.minY + 3, width: scoreWidth, height: contentRect.height - 6)
            : CGRect(x: contentRect.maxX - scoreWidth, y: contentRect.minY + 3, width: scoreWidth, height: contentRect.height - 6)
        let teamRect = alignRight
            ? CGRect(x: scoreRect.maxX + gap, y: contentRect.minY + 4, width: max(0, contentRect.maxX - scoreRect.maxX - gap), height: contentRect.height * 0.62)
            : CGRect(x: contentRect.minX, y: contentRect.minY + 4, width: max(0, scoreRect.minX - contentRect.minX - gap), height: contentRect.height * 0.62)
        let relayKey: OCRRegionKey = alignRight ? .awayScore : .homeScore
        let displayedScore = relay.enabled
            ? (relay.visualValue(for: relayKey) ?? score)
            : score
        drawText(
            displayedScore,
            in: scoreRect,
            font: scoreFont,
            color: relay.enabled && relay.visualValue(for: relayKey) == nil
                ? accent.withAlphaComponent(0.35)
                : accent,
            alignment: .center
        )
        drawText(team, in: teamRect, font: teamFont, color: .white, alignment: alignRight ? .right : .left)
        let lineWidth = min(max(34, teamRect.width * 0.44), 82)
        let lineX = alignRight ? teamRect.maxX - lineWidth : teamRect.minX
        guard let cg = UIGraphicsGetCurrentContext(), teamRect.width > 4 else { return }
        cg.setFillColor(accent.cgColor)
        cg.fillRoundedW10i(CGRect(x: lineX, y: rect.maxY - 7, width: lineWidth, height: 3), radius: 1.5)
    }

    private static func drawRoundedLogoBackground(in rect: CGRect, accent: UIColor) {
        guard let cg = UIGraphicsGetCurrentContext() else { return }
        cg.setFillColor(UIColor.black.withAlphaComponent(0.22).cgColor)
        cg.fillRoundedW10i(rect, radius: 11)
        cg.setStrokeColor(accent.withAlphaComponent(0.62).cgColor)
        cg.setLineWidth(1)
        cg.strokeRoundedW10i(rect, radius: 11)
    }

    private static func drawCenterCell(period: String, clock: String, in rect: CGRect, periodFont: UIFont, clockFont: UIFont) {
        guard let cg = UIGraphicsGetCurrentContext() else { return }
        cg.setFillColor(UIColor.black.withAlphaComponent(0.28).cgColor)
        cg.fillRoundedW10i(rect, radius: min(10, rect.height / 2))
        drawText(period, in: CGRect(x: rect.minX, y: rect.minY + 2, width: rect.width, height: rect.height * 0.34), font: periodFont, color: UIColor.white.withAlphaComponent(0.72), alignment: .center)
        drawText(clock, in: CGRect(x: rect.minX, y: rect.minY + rect.height * 0.35, width: rect.width, height: rect.height * 0.55), font: clockFont, color: UIColor(red: 1.0, green: 0.82, blue: 0.25, alpha: 1.0), alignment: .center)
    }

    private static func drawTemplateTeamName(_ text: String, in rect: CGRect, font: UIFont, color: UIColor, alignment: NSTextAlignment) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, rect.width > 1, rect.height > 1 else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.maximumLineHeight = font.lineHeight
        paragraph.minimumLineHeight = font.lineHeight * 0.86

        let minimumSize = max(9, font.pointSize * 0.58)
        var fittedFont = font
        let maxHeight = rect.height
        let maxSize = CGSize(width: rect.width, height: maxHeight)

        while fittedFont.pointSize >= minimumSize {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: fittedFont,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
            let measured = (clean as NSString).boundingRect(
                with: maxSize,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs,
                context: nil
            ).integral.size
            if measured.width <= rect.width + 0.5 && measured.height <= maxHeight + 0.5 { break }
            fittedFont = fittedFont.withSize(fittedFont.pointSize - 1)
            paragraph.maximumLineHeight = fittedFont.lineHeight
            paragraph.minimumLineHeight = fittedFont.lineHeight * 0.86
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: fittedFont,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        let measured = (clean as NSString).boundingRect(
            with: maxSize,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs,
            context: nil
        ).integral.size
        let drawRect = CGRect(
            x: rect.minX,
            y: rect.midY - min(rect.height, measured.height) / 2,
            width: rect.width,
            height: min(rect.height, max(measured.height, fittedFont.lineHeight))
        ).integral
        (clean as NSString).draw(in: drawRect, withAttributes: attrs)
    }

    /// Score-only draw path. Shared metrics guarantee a full two-digit width,
    /// so unlike general labels this function never reduces the requested font.
    private static func drawScoreText(
        _ text: String,
        in rect: CGRect,
        font: UIFont,
        color: UIColor,
        alignment: NSTextAlignment
    ) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, rect.width > 1, rect.height > 1 else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byClipping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        let measured = (clean as NSString).size(withAttributes: attrs)
        let drawHeight = min(rect.height, max(measured.height, font.lineHeight))
        let drawRect = CGRect(
            x: rect.minX,
            y: rect.midY - drawHeight / 2,
            width: rect.width,
            height: drawHeight
        ).integral
        (clean as NSString).draw(in: drawRect, withAttributes: attrs)
    }

    private static func drawText(_ text: String, in rect: CGRect, font: UIFont, color: UIColor, alignment: NSTextAlignment) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, rect.width > 1, rect.height > 1 else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail

        let minimumSize = max(6, font.pointSize * 0.54)
        var fittedFont = font
        var measured = CGSize.zero

        while fittedFont.pointSize >= minimumSize {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: fittedFont,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
            measured = (clean as NSString).size(withAttributes: attrs)
            if measured.width <= rect.width + 0.5 && measured.height <= rect.height + 0.5 { break }
            fittedFont = fittedFont.withSize(fittedFont.pointSize - 1)
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: fittedFont,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        measured = (clean as NSString).size(withAttributes: attrs)
        let drawHeight = min(rect.height, max(measured.height, fittedFont.lineHeight))
        let drawRect = CGRect(
            x: rect.minX,
            y: rect.midY - drawHeight / 2,
            width: rect.width,
            height: drawHeight
        ).integral
        (clean as NSString).draw(in: drawRect, withAttributes: attrs)
    }
}

private extension CGContext {
    func fillRoundedW10i(_ rect: CGRect, radius: CGFloat) {
        addPath(UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath)
        fillPath()
    }

    func strokeRoundedW10i(_ rect: CGRect, radius: CGFloat) {
        addPath(UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath)
        strokePath()
    }
}
