// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import UIKit

// MARK: - v0.9.0n2a Broadcast Scoreboard Layout Settings

/// Scoreboard-only layout settings. This file deliberately avoids camera,
/// OCR, recording and clip-export behaviour.
enum BroadcastScoreboardPositionPreset: String, CaseIterable, Identifiable, Codable {
    case topMiddle
    case leftDefault
    case topRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topMiddle: return "Top Middle"
        case .leftDefault: return "Left Default"
        case .topRight: return "Top Right"
        }
    }
}

enum BroadcastScoreboardLogoPosition: String, CaseIterable, Identifiable, Codable {
    case besideTeamName
    case centredAboveTeamName

    var id: String { rawValue }

    var title: String {
        switch self {
        case .besideTeamName: return "Beside Name"
        case .centredAboveTeamName: return "Centred Above Name"
        }
    }
}

enum BroadcastScoreboardDensityMode: String, CaseIterable, Identifiable, Codable {
    case compact
    case expanded

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum BroadcastScoreboardFontWeight: String, CaseIterable, Identifiable, Codable {
    case regular
    case semibold
    case bold
    case heavy
    case black

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var swiftUIFontWeight: Font.Weight {
        switch self {
        case .regular: return .regular
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }
}

struct BroadcastScoreboardLayoutSnapshot: Equatable {
    var isVisible: Bool = true
    var positionPreset: BroadcastScoreboardPositionPreset = .topMiddle
    var logoPosition: BroadcastScoreboardLogoPosition = .besideTeamName
    var densityMode: BroadcastScoreboardDensityMode = .compact
    var showEventTimeline: Bool = false
    var safeMargin: CGFloat = 28
    var horizontalOffset: CGFloat = 0
    var verticalOffset: CGFloat = 0
    var teamNameFontSize: CGFloat = 26
    var teamNameFontWeight: BroadcastScoreboardFontWeight = .heavy
    var homeTeamNameColour: Color = .white
    var awayTeamNameColour: Color = .white
    var homeTeamBackgroundColour: Color = BroadcastTheme.homeAccent.opacity(0.16)
    var awayTeamBackgroundColour: Color = BroadcastTheme.awayAccent.opacity(0.16)
    var scoreboardBackgroundColour: Color = Color.black.opacity(0.82)
    var scoreboardBorderColour: Color = Color.white.opacity(0.20)
    var scoreColour: Color = .white
    var useSharedScoreColour: Bool = false
    var homeScoreColour: Color = BroadcastTheme.homeAccent
    var awayScoreColour: Color = BroadcastTheme.awayAccent
    var clockColour: Color = BroadcastTheme.clockAccent
    var periodColour: Color = Color.white.opacity(0.72)
    var logoContainerBackground: Color = Color.white.opacity(0.06)
    var homeLogoContainerBackground: Color = Color.white.opacity(0.06)
    var awayLogoContainerBackground: Color = Color.white.opacity(0.06)
    var accentColour: Color = Color.cyan.opacity(0.85)

    static let `default` = BroadcastScoreboardLayoutSnapshot()

    /// UX3: stable key for cached WYSIWYG scorebug rendering. The recording/
    /// preview overlay renderer now honours the same template controls used by
    /// Settings -> Live Broadcast Preview, so changes must invalidate the cached
    /// transparent overlay image.
    var overlayCacheKey: String {
        [
            isVisible ? "visible" : "hidden",
            positionPreset.rawValue,
            logoPosition.rawValue,
            String(format: "safe=%.1f", Double(safeMargin)),
            String(format: "h=%.1f", Double(horizontalOffset)),
            String(format: "v=%.1f", Double(verticalOffset)),
            String(format: "font=%.1f", Double(teamNameFontSize)),
            teamNameFontWeight.rawValue,
            homeTeamNameColour.rgbaString,
            awayTeamNameColour.rgbaString,
            homeTeamBackgroundColour.rgbaString,
            awayTeamBackgroundColour.rgbaString,
            scoreboardBackgroundColour.rgbaString,
            scoreboardBorderColour.rgbaString,
            scoreColour.rgbaString,
            useSharedScoreColour ? "score=shared" : "score=split",
            homeScoreColour.rgbaString,
            awayScoreColour.rgbaString,
            clockColour.rgbaString,
            periodColour.rgbaString,
            logoContainerBackground.rgbaString,
            homeLogoContainerBackground.rgbaString,
            awayLogoContainerBackground.rgbaString,
            accentColour.rgbaString
        ].joined(separator: "~")
    }
}



// MARK: - UX9 Canonical Scorebug Template Metrics

/// One fully-resolved metric contract shared by SwiftUI, Settings preview,
/// recording and clips. Logical values are expressed in scorebug points;
/// `outputScale` is explicit and never recovered from a font or another derived
/// value.
struct BroadcastScorebugResolvedMetrics {
    let layout: BroadcastScoreboardLayoutSnapshot
    let outputScale: CGFloat
    let primaryContentScale: CGFloat
    let effectiveTeamNameFontSize: CGFloat

    let homeTeamCellWidth: CGFloat
    let awayTeamCellWidth: CGFloat
    let logoSize: CGFloat
    let logoNameSpacing: CGFloat
    let scoreFontSize: CGFloat
    let scoreColumnWidth: CGFloat
    let clockZoneSize: CGSize
    let clockFontSize: CGFloat
    let centreWidth: CGFloat
    let centreHeight: CGFloat
    let teamSpacing: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat

    // Secondary template elements. Build 600 resolves them from the same
    // master scale, with hidden readability floors where required.
    let periodFontSize: CGFloat
    let periodBandHeight: CGFloat
    let strengthFontSize: CGFloat
    let strengthBandHeight: CGFloat
    let penaltyRowHeight: CGFloat
    let penaltyLabelWidth: CGFloat
    let penaltyPlayerWidth: CGFloat
    let penaltyTimerReferenceHeight: CGFloat
    let penaltyTimerMinimumWidth: CGFloat
    let penaltySlotMinimumWidth: CGFloat
    let penaltyStripMinimumWidth: CGFloat
    /// Build 641 moves penalties into mirrored side panels. These metrics are
    /// shared by SwiftUI, recording, clips and stream output so Home and Guest
    /// always use identical player/timer columns and row heights.
    let penaltyHeaderHeight: CGFloat
    let penaltyPanelWidth: CGFloat
    let penaltyPanelHeight: CGFloat
    let penaltyPanelSpacing: CGFloat
    let penaltyColumnGap: CGFloat
    let penaltyRowGap: CGFloat

    let utilityStripHeight: CGFloat
    let utilityStripGap: CGFloat
    let scorebugLogicalSize: CGSize

    func scaled(_ value: CGFloat) -> CGFloat { value * outputScale }
    func scaled(_ size: CGSize) -> CGSize {
        CGSize(width: size.width * outputScale, height: size.height * outputScale)
    }

    var renderedTeamNameFontSize: CGFloat { scaled(effectiveTeamNameFontSize) }
    var renderedHomeTeamCellWidth: CGFloat { scaled(homeTeamCellWidth) }
    var renderedAwayTeamCellWidth: CGFloat { scaled(awayTeamCellWidth) }
    var renderedLogoSize: CGFloat { scaled(logoSize) }
    var renderedLogoNameSpacing: CGFloat { scaled(logoNameSpacing) }
    var renderedScoreFontSize: CGFloat { scaled(scoreFontSize) }
    var renderedScoreColumnWidth: CGFloat { scaled(scoreColumnWidth) }
    var renderedClockZoneSize: CGSize { scaled(clockZoneSize) }
    var renderedClockFontSize: CGFloat { scaled(clockFontSize) }
    var renderedCentreWidth: CGFloat { scaled(centreWidth) }
    var renderedCentreHeight: CGFloat { scaled(centreHeight) }
    var renderedTeamSpacing: CGFloat { scaled(teamSpacing) }
    var renderedHorizontalPadding: CGFloat { scaled(horizontalPadding) }
    var renderedVerticalPadding: CGFloat { scaled(verticalPadding) }
    var renderedPeriodFontSize: CGFloat { scaled(periodFontSize) }
    var renderedPeriodBandHeight: CGFloat { scaled(periodBandHeight) }
    var renderedStrengthFontSize: CGFloat { scaled(strengthFontSize) }
    var renderedStrengthBandHeight: CGFloat { scaled(strengthBandHeight) }
    var renderedPenaltyRowHeight: CGFloat { scaled(penaltyRowHeight) }
    var renderedPenaltyLabelWidth: CGFloat { scaled(penaltyLabelWidth) }
    var renderedPenaltyPlayerWidth: CGFloat { scaled(penaltyPlayerWidth) }
    var renderedPenaltyTimerReferenceHeight: CGFloat { scaled(penaltyTimerReferenceHeight) }
    var renderedPenaltyTimerMinimumWidth: CGFloat { scaled(penaltyTimerMinimumWidth) }
    var renderedPenaltySlotMinimumWidth: CGFloat { scaled(penaltySlotMinimumWidth) }
    var renderedPenaltyStripMinimumWidth: CGFloat { scaled(penaltyStripMinimumWidth) }
    var renderedPenaltyHeaderHeight: CGFloat { scaled(penaltyHeaderHeight) }
    var renderedPenaltyPanelWidth: CGFloat { scaled(penaltyPanelWidth) }
    var renderedPenaltyPanelHeight: CGFloat { scaled(penaltyPanelHeight) }
    var renderedPenaltyPanelSpacing: CGFloat { scaled(penaltyPanelSpacing) }
    var renderedPenaltyColumnGap: CGFloat { scaled(penaltyColumnGap) }
    var renderedPenaltyRowGap: CGFloat { scaled(penaltyRowGap) }
    var renderedUtilityStripHeight: CGFloat { scaled(utilityStripHeight) }
    var renderedUtilityStripGap: CGFloat { scaled(utilityStripGap) }
    var scorebugRenderedSize: CGSize { scaled(scorebugLogicalSize) }
}


// MARK: - Build 628 shared glyph layout and colour authority

/// Team-side identifier used by the platform-neutral scorebug render plan.
/// SwiftUI Broadcast, recording, clips and Settings preview must all resolve
/// colours through this type rather than keeping renderer-local mappings.
enum BroadcastScorebugTeamSide {
    case home
    case away
}

/// Shared mirrored team-name alignment. Home names sit against the Home score
/// on the right; Guest names sit against the Guest score on the left. Drawing
/// adapters convert this platform-neutral value to SwiftUI/UIKit alignment.
enum BroadcastScorebugTeamNameAlignment {
    case leading
    case trailing
}

enum BroadcastScorebugTeamNameAlignmentResolver {
    static func alignment(for side: BroadcastScorebugTeamSide) -> BroadcastScorebugTeamNameAlignment {
        side == .home ? .trailing : .leading
    }
}

enum BroadcastScorebugGlyphKind {
    case clock
    case penaltyTimer
    case penaltyPlayer
}

/// Fully resolved visible-glyph placement. The source images published by Image
/// Relay are already alpha-cropped around their illuminated components, so this
/// contract sizes the visible glyph itself rather than its original camera zone.
struct BroadcastScorebugGlyphPlacement {
    let frameSize: CGSize
    let visibleHeight: CGFloat
    let sourceAspectRatio: CGFloat

    func rect(centeredIn availableRect: CGRect) -> CGRect {
        CGRect(
            x: availableRect.midX - frameSize.width * 0.5,
            y: availableRect.midY - frameSize.height * 0.5,
            width: frameSize.width,
            height: frameSize.height
        )
    }
}

/// One penalty-pair geometry contract used by both the live SwiftUI scorebug and
/// the Core Graphics recording/clip renderer. Player and timer always receive
/// the same visible height; width is derived from each extracted glyph's aspect.
struct BroadcastScorebugPenaltyPairLayout {
    let player: BroadcastScorebugGlyphPlacement
    let timer: BroadcastScorebugGlyphPlacement
    let gap: CGFloat
    let slotWidth: CGFloat

    var contentWidth: CGFloat {
        player.frameSize.width + gap + timer.frameSize.width
    }

    func rects(in availableRect: CGRect) -> (player: CGRect, timer: CGRect) {
        let startX = availableRect.midX - contentWidth * 0.5
        let playerRect = CGRect(
            x: startX,
            y: availableRect.midY - player.frameSize.height * 0.5,
            width: player.frameSize.width,
            height: player.frameSize.height
        )
        let timerRect = CGRect(
            x: playerRect.maxX + gap,
            y: availableRect.midY - timer.frameSize.height * 0.5,
            width: timer.frameSize.width,
            height: timer.frameSize.height
        )
        return (playerRect, timerRect)
    }
}

/// Single colour mapping for scores and penalty glyphs. No drawing adapter is
/// allowed to hardcode white for an active penalty player or timer.
enum BroadcastScorebugColourResolver {
    static func scoreColour(
        layout: BroadcastScoreboardLayoutSnapshot,
        side: BroadcastScorebugTeamSide
    ) -> Color {
        if layout.useSharedScoreColour {
            return layout.scoreColour
        }
        return side == .home ? layout.homeScoreColour : layout.awayScoreColour
    }

    static func scoreUIColor(
        layout: BroadcastScoreboardLayoutSnapshot,
        side: BroadcastScorebugTeamSide,
        opacity: CGFloat = 1
    ) -> UIColor {
        UIColor(scoreColour(layout: layout, side: side)).withAlphaComponent(opacity)
    }

    static func penaltyColour(
        layout: BroadcastScoreboardLayoutSnapshot,
        side: BroadcastScorebugTeamSide
    ) -> Color {
        scoreColour(layout: layout, side: side)
    }

    static func penaltyUIColor(
        layout: BroadcastScoreboardLayoutSnapshot,
        side: BroadcastScorebugTeamSide,
        opacity: CGFloat = 0.98
    ) -> UIColor {
        scoreUIColor(layout: layout, side: side, opacity: opacity)
    }
}

/// Shared visible-glyph fitter for the Clock, penalty timer and player number.
///
/// The Clock and penalty timer reserve independent wide envelopes. Build 674
/// gives the Clock room for sub-second digits and gives every penalty timer enough
/// width to preserve one common visible character height. Player width is derived
/// from its real one/two-digit aspect and no glyph is stretched.
enum BroadcastScorebugGlyphLayoutResolver {
    private static func safeAspect(
        sourceSize: CGSize?,
        fallback: CGFloat
    ) -> CGFloat {
        guard let sourceSize,
              sourceSize.width > 0,
              sourceSize.height > 0 else { return fallback }
        return max(0.10, sourceSize.width / sourceSize.height)
    }

    private static func effectiveWidthAspect(
        kind: BroadcastScorebugGlyphKind,
        sourceAspect: CGFloat
    ) -> CGFloat {
        switch kind {
        case .clock:
            return min(5.00, max(2.80, sourceAspect))
        case .penaltyTimer:
            return min(5.60, max(2.70, sourceAspect))
        case .penaltyPlayer:
            // Keep malformed/wide extraction artefacts from forcing an unbounded
            // scorebug while still allowing legitimate two-digit player images.
            // Preserve the real one/two-digit player aspect so contain-fit does
            // not reduce its visible height below the adjacent timer. Extreme
            // extraction artefacts remain bounded.
            return min(2.20, max(0.45, sourceAspect))
        }
    }

    /// Returns the non-transparent glyph bounds so player, timer and Clock
    /// heights are based on illuminated pixels rather than their outer canvas.
    static func visibleContentBounds(of image: CGImage) -> CGRect {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return .zero }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return CGRect(x: 0, y: 0, width: width, height: height) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if pixels[i + 3] > 20 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else {
            return CGRect(x: 0, y: 0, width: width, height: height)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    static func visibleContentSize(of image: CGImage) -> CGSize {
        visibleContentBounds(of: image).size
    }

    /// Removes transparent safety canvas before aspect-fit. Equal outer canvas
    /// heights do not imply equal character heights when the glyph occupies a
    /// different fraction of each source crop.
    static func visibleContentImage(of image: CGImage) -> CGImage {
        let bounds = visibleContentBounds(of: image).integral
        guard bounds.width > 0, bounds.height > 0,
              bounds.width < CGFloat(image.width) || bounds.height < CGFloat(image.height),
              let cropped = image.cropping(to: bounds) else { return image }
        return cropped
    }

    static func placement(
        kind: BroadcastScorebugGlyphKind,
        sourceSize: CGSize?,
        availableSize: CGSize,
        targetVisibleHeight: CGFloat? = nil
    ) -> BroadcastScorebugGlyphPlacement {
        guard availableSize.width > 0, availableSize.height > 0 else {
            return BroadcastScorebugGlyphPlacement(
                frameSize: .zero,
                visibleHeight: 0,
                sourceAspectRatio: 1
            )
        }

        let fallbackAspect: CGFloat
        switch kind {
        case .clock, .penaltyTimer:
            fallbackAspect = BroadcastScorebugTemplateMetrics.timerZoneMinimumWidthToHeightRatio
        case .penaltyPlayer:
            fallbackAspect = 1.45
        }
        let sourceAspect = safeAspect(sourceSize: sourceSize, fallback: fallbackAspect)
        let widthAspect = effectiveWidthAspect(kind: kind, sourceAspect: sourceAspect)
        let requestedHeight = min(
            availableSize.height,
            max(1, targetVisibleHeight ?? availableSize.height)
        )
        let visibleHeight = max(
            1,
            min(requestedHeight, availableSize.width / max(0.10, widthAspect))
        )
        // The image remains natural-aspect. The wider effective envelope only
        // limits height where required; it never stretches a narrow extraction.
        let frameWidth = max(1, min(availableSize.width, visibleHeight * sourceAspect))
        return BroadcastScorebugGlyphPlacement(
            frameSize: CGSize(width: ceil(frameWidth), height: floor(visibleHeight)),
            visibleHeight: floor(visibleHeight),
            sourceAspectRatio: sourceAspect
        )
    }

    static func penaltyPair(
        playerSourceSize: CGSize?,
        timerSourceSize: CGSize?,
        rowHeight: CGFloat,
        referenceVisibleHeight: CGFloat,
        minimumPlayerWidth: CGFloat,
        minimumTimerWidth: CGFloat,
        minimumSlotWidth: CGFloat,
        gap: CGFloat = 0,
        availableWidth: CGFloat? = nil
    ) -> BroadcastScorebugPenaltyPairLayout {
        let safeRowHeight = max(1, rowHeight)
        let safeGap = max(0, gap)
        let targetHeight = min(safeRowHeight, max(1, referenceVisibleHeight))
        let playerAspect = effectiveWidthAspect(
            kind: .penaltyPlayer,
            sourceAspect: safeAspect(sourceSize: playerSourceSize, fallback: 1.45)
        )
        let timerAspect = effectiveWidthAspect(
            kind: .penaltyTimer,
            sourceAspect: safeAspect(
                sourceSize: timerSourceSize,
                fallback: BroadcastScorebugTemplateMetrics.penaltyTimerReservedWidthToHeightRatio
            )
        )

        var visibleHeight = targetHeight
        if let availableWidth {
            let widthLimitedHeight = max(
                1,
                (max(1, availableWidth) - safeGap) / max(0.10, playerAspect + timerAspect)
            )
            visibleHeight = min(visibleHeight, widthLimitedHeight)
        }

        let isWidthConstrained = availableWidth != nil
        let playerWidth = isWidthConstrained
            ? max(1, ceil(visibleHeight * playerAspect))
            : max(minimumPlayerWidth, ceil(visibleHeight * playerAspect))
        let timerWidth = isWidthConstrained
            ? max(1, ceil(visibleHeight * timerAspect))
            : max(minimumTimerWidth, ceil(visibleHeight * timerAspect))
        let requestedWidth = playerWidth + safeGap + timerWidth
        let slotWidth: CGFloat
        if let availableWidth {
            slotWidth = max(1, availableWidth)
        } else {
            slotWidth = max(minimumSlotWidth, ceil(requestedWidth))
        }

        return BroadcastScorebugPenaltyPairLayout(
            player: BroadcastScorebugGlyphPlacement(
                frameSize: CGSize(width: playerWidth, height: floor(visibleHeight)),
                visibleHeight: floor(visibleHeight),
                sourceAspectRatio: playerAspect
            ),
            timer: BroadcastScorebugGlyphPlacement(
                frameSize: CGSize(width: timerWidth, height: floor(visibleHeight)),
                visibleHeight: floor(visibleHeight),
                sourceAspectRatio: timerAspect
            ),
            gap: safeGap,
            slotWidth: slotWidth
        )
    }

    /// Resolves player and timer glyphs in their own calibrated columns while
    /// forcing the same visible character height. Independent `scaledToFit`
    /// calls shrink wide timer crops more than player crops and caused the two
    /// fields to look like different font sizes.
    static func penaltyPairInSeparateCells(
        playerSourceSize: CGSize?,
        timerSourceSize: CGSize?,
        playerAvailableSize: CGSize,
        timerAvailableSize: CGSize,
        referenceVisibleHeight: CGFloat
    ) -> BroadcastScorebugPenaltyPairLayout {
        // Build 656 restores one fixed visible height across every penalty row.
        // Width is reserved by the side-panel metrics; it must never feed back
        // into character height. This prevents a wide timer from making one slot
        // smaller than the other three.
        let fixedHeight = max(
            1,
            floor(min(
                referenceVisibleHeight,
                playerAvailableSize.height,
                timerAvailableSize.height
            ))
        )

        func fixedPlacement(
            kind: BroadcastScorebugGlyphKind,
            sourceSize: CGSize?,
            availableSize: CGSize
        ) -> BroadcastScorebugGlyphPlacement {
            let fallback: CGFloat
            switch kind {
            case .penaltyPlayer:
                fallback = 1.45
            case .clock, .penaltyTimer:
                fallback = BroadcastScorebugTemplateMetrics.penaltyTimerReservedWidthToHeightRatio
            }
            let sourceAspect = safeAspect(sourceSize: sourceSize, fallback: fallback)
            let reservedAspect = effectiveWidthAspect(kind: kind, sourceAspect: sourceAspect)
            let width = max(1, min(availableSize.width, ceil(fixedHeight * reservedAspect)))
            return BroadcastScorebugGlyphPlacement(
                frameSize: CGSize(width: width, height: fixedHeight),
                visibleHeight: fixedHeight,
                sourceAspectRatio: sourceAspect
            )
        }

        return BroadcastScorebugPenaltyPairLayout(
            player: fixedPlacement(
                kind: .penaltyPlayer,
                sourceSize: playerSourceSize,
                availableSize: playerAvailableSize
            ),
            timer: fixedPlacement(
                kind: .penaltyTimer,
                sourceSize: timerSourceSize,
                availableSize: timerAvailableSize
            ),
            gap: 0,
            slotWidth: playerAvailableSize.width + timerAvailableSize.width
        )
    }

    static func clockRect(
        sourceSize: CGSize?,
        in availableRect: CGRect,
        targetVisibleHeight: CGFloat? = nil
    ) -> CGRect {
        placement(
            kind: .clock,
            sourceSize: sourceSize,
            availableSize: availableRect.size,
            targetVisibleHeight: targetVisibleHeight
        ).rect(centeredIn: availableRect)
    }
}

/// UX12/Build 600 canonical scorebug metrics.
///
/// Build 600 removes Compact / Expanded as a user-facing size authority.
/// Team Font is the single bounded master scale for team names, scores, Clock,
/// logos, centre readouts, penalty presentation, spacing and the overall panel.
/// The legacy density value remains serialisable only for profile compatibility
/// and is deliberately ignored by the renderer.
enum BroadcastScorebugTemplateMetrics {
    // Recovery S / RL-054: scorebug geometry is owned by the template, not by
    // transient OCR/Image Relay/sponsor content. Reserve the maximum utility
    // strip contract on every viewer surface; only the strip contents may vary.
    nonisolated static let reservesInvariantUtilityStripGeometry = true
    nonisolated static let timerZoneMinimumWidthToHeightRatio: CGFloat = 5.40
    // Build 715 widens only the Clock member for five-character timeout formats
    // such as 0:30.0. The established centre-visual rollout flag retains the
    // previous 5.40/no-padding path for direct A/B comparison.
    nonisolated static var clockZoneWidthToHeightRatio: CGFloat {
        RinkLensRiskFeaturePolicy.isEnabled(.largerPeriodStrengthTextV2) ? 5.80 : 5.40
    }
    nonisolated static var clockSourceCropPaddingFraction: CGFloat {
        RinkLensRiskFeaturePolicy.isEnabled(.largerPeriodStrengthTextV2) ? 0.08 : 0
    }
    nonisolated static let legacyPenaltyTimerReservedWidthToHeightRatio: CGFloat = 5.60
    nonisolated static let compactPenaltyTimerReservedWidthToHeightRatio: CGFloat = 3.75
    nonisolated static let legacyPenaltyPlayerReservedWidthToHeightRatio: CGFloat = 2.20
    nonisolated static let compactPenaltyPlayerReservedWidthToHeightRatio: CGFloat = 1.65
    // Build 697: one fixed display scale is applied to the producer-owned timer
    // canvas. It does not alter the penalty cell, row or side-panel dimensions.
    nonisolated static let stablePenaltyTimerDisplayScale: CGFloat = 1.08

    nonisolated static func resolvedPenaltyTimerWidthRatio(compact: Bool) -> CGFloat {
        compact ? compactPenaltyTimerReservedWidthToHeightRatio : legacyPenaltyTimerReservedWidthToHeightRatio
    }

    static var penaltyTimerReservedWidthToHeightRatio: CGFloat {
        resolvedPenaltyTimerWidthRatio(
            compact: RinkLensRiskFeaturePolicy.isEnabled(.compactPenaltyPanelV2)
        )
    }
    static var penaltyPlayerReservedWidthToHeightRatio: CGFloat {
        RinkLensRiskFeaturePolicy.isEnabled(.compactPenaltyPanelV2)
            ? compactPenaltyPlayerReservedWidthToHeightRatio
            : legacyPenaltyPlayerReservedWidthToHeightRatio
    }
    static let primaryReferenceTeamFontSize: CGFloat = 34
    static let minimumSupportedTeamFontSize: CGFloat = 20
    static let maximumLegacyTeamFontSize: CGFloat = 48

    private struct PrimaryBases {
        let teamCellWidth: CGFloat
        let teamCellMaximumWidth: CGFloat
        let logoSize: CGFloat
        let scoreFontSize: CGFloat
        let scoreColumnWidth: CGFloat
        let clockHeight: CGFloat
        let teamSpacing: CGFloat
        let horizontalPadding: CGFloat
        let verticalPadding: CGFloat
        let logoNameSpacing: CGFloat
        let minimumLogoSize: CGFloat
        let minimumScoreFontSize: CGFloat
        let minimumClockHeight: CGFloat
    }

    private static func requestedTeamNameFontSize(for layout: BroadcastScoreboardLayoutSnapshot) -> CGFloat {
        // Build 600 exposes the supported 20...48 operator range. Imported legacy
        // values remain bounded so one setting safely controls the whole bug.
        min(maximumLegacyTeamFontSize, max(minimumSupportedTeamFontSize, layout.teamNameFontSize))
    }

    static func effectiveTeamNameFontSize(for layout: BroadcastScoreboardLayoutSnapshot) -> CGFloat {
        // Team Font and all primary scorebug geometry share one common scale.
        primaryReferenceTeamFontSize * primaryContentScale(for: layout)
    }

    static func primaryContentScale(for layout: BroadcastScoreboardLayoutSnapshot) -> CGFloat {
        let bases = primaryBases(for: layout)
        let requested = requestedTeamNameFontSize(for: layout) / primaryReferenceTeamFontSize
        let sharedMinimum = max(
            0.40,
            max(
                bases.minimumLogoSize / max(1, bases.logoSize),
                max(
                    bases.minimumScoreFontSize / max(1, bases.scoreFontSize),
                    bases.minimumClockHeight / max(1, bases.clockHeight)
                )
            )
        )
        let maximum = maximumLegacyTeamFontSize / primaryReferenceTeamFontSize
        return min(maximum, max(sharedMinimum, requested))
    }

    static func resolve(
        layout: BroadcastScoreboardLayoutSnapshot,
        homeTeamName: String? = nil,
        awayTeamName: String? = nil,
        includesGameSponsor: Bool = false,
        outputScale: CGFloat = 1
    ) -> BroadcastScorebugResolvedMetrics {
        let safeOutputScale = max(0.0001, outputScale)
        let bases = primaryBases(for: layout)
        let scale = primaryContentScale(for: layout)
        let effectiveFont = effectiveTeamNameFontSize(for: layout)

        // Penalty presentation follows the master scale too, with hidden
        // readability floors so recent timer/player stability fixes are kept.
        // Build 634 readability floor. Relay glyphs are normalised from measured
        // illuminated bounds, then player and timer share one visible-height target.
        let fixedPenaltyRowHeight: CGFloat = max(24, 28 * scale)
        let fixedPenaltyLabelWidth: CGFloat = max(36, 42 * scale)
        // Two-digit player images must reach the timer glyph height rather than
        // being squeezed into the legacy 29pt column.
        let fixedPenaltyPlayerWidth: CGFloat = max(30, 36 * scale)
        // Image Relay glyphs already carry measured visible bounds. Do not reduce
        // them again to software-font capHeight; use one shared physical height.
        let timerReferenceHeight = max(22, fixedPenaltyRowHeight - 3)
        let timerMinimumWidth = ceil(timerReferenceHeight * penaltyTimerReservedWidthToHeightRatio)
        let penaltyColumnGap: CGFloat = max(2, 3 * scale)
        let penaltyRowGap: CGFloat = max(2, 3 * scale)
        let penaltyHeaderHeight: CGFloat = max(13, 15 * scale)
        let penaltyPanelSpacing: CGFloat = max(3, 5 * scale)
        // One row contains one player and one timer. The old horizontal strip
        // reserved two complete slots inside each team cell, which squeezed the
        // physical glyphs and allowed Home/Guest to resolve at different sizes.
        let slotMinimumWidth = ceil(fixedPenaltyPlayerWidth + timerMinimumWidth + penaltyColumnGap)
        let stripMinimumWidth = slotMinimumWidth
        // Build 695 uses the same single geometry authority for the physical player
        // and timer canvases. The feature-flagged 1.65 + 3.75 contract reduces the
        // total side-panel reserve from 7.80h to 5.40h (30.8%) while the observed
        // full timer groups remain contain-fitted inside a 3.75:1 canvas.
        let penaltyPanelWidth = ceil(max(
            slotMinimumWidth,
            timerReferenceHeight * (penaltyPlayerReservedWidthToHeightRatio + penaltyTimerReservedWidthToHeightRatio) + penaltyColumnGap
        ))
        let penaltyPanelHeight = ceil(
            penaltyHeaderHeight + fixedPenaltyRowHeight * 2 + penaltyRowGap * 2
        )

        let logo = bases.logoSize * scale
        let logoGap = bases.logoNameSpacing * scale
        let scoreFont = bases.scoreFontSize * scale
        // Reserve the full measured width of two monospaced score digits at the
        // requested font size. The score must never be reduced when it reaches
        // double figures; the scorebug grows instead.
        let fullSizeScoreFont = UIFont.monospacedDigitSystemFont(
            ofSize: scoreFont,
            weight: .black
        )
        let doubleDigitScoreWidth = ("88" as NSString).size(
            withAttributes: [.font: fullSizeScoreFont]
        ).width
        let scoreColumn = ceil(max(
            bases.scoreColumnWidth * scale,
            doubleDigitScoreWidth + max(6, 8 * scale)
        ))
        // The physical Clock remains readable even when Team Font is reduced.
        // Measured relay digits are contain-fitted into this shared minimum rather
        // than being collapsed to a 16px frame at the 24pt team-font setting.
        let clockHeight = max(36, bases.clockHeight * scale)
        let legacyClockWidth = clockHeight * clockZoneWidthToHeightRatio
        // Build 704 uses the centre cell’s existing 4pt safety inset for a wider MM:SS clock crop.
        // The centre cell and overall scorebug canvas remain unchanged.
        let clockSize = CGSize(width: legacyClockWidth + 4 * scale, height: clockHeight)
        let clockFont = clockHeight * 0.94
        let spacing = bases.teamSpacing * scale
        let horizontalPadding = bases.horizontalPadding * scale
        let verticalPadding = bases.verticalPadding * scale

        // Build 601: Period, main Clock and visual manpower are explicit
        // members of the Team Font master scale. The small hidden floors protect
        // readability only below the supported 20pt operator minimum.
        // Build 697 increases typography only. periodBand, strengthBand and
        // centreHeight retain the established geometry, so no canvas resizes.
        // Build 705: these are the actual Broadcast/recording metrics, not the
        // calibration preview. Apply the increase unconditionally so a persisted
        // rollout flag cannot silently leave the live scorebug at the old size.
        // Band and centre geometry remain unchanged; only glyph size changes.
        let centreTextScale: CGFloat = 1.38
        let periodFont: CGFloat = max(10, 19 * scale * centreTextScale)
        let periodBand: CGFloat = max(13, 22 * scale)
        let strengthFont: CGFloat = max(10, 19 * scale * centreTextScale)
        let strengthBand: CGFloat = max(15, 26 * scale)
        let centreHeight = ceil(max(
            30,
            max(
                52 * scale,
                clockHeight + periodBand + strengthBand + 2 * scale
            )
        ))
        // Build 641 removes the legacy left/right Clock padding. The centre is
        // now governed by the physical Clock itself, with only a 2pt safety inset.
        let centreWidth = ceil(max(
            legacyClockWidth + 4 * scale,
            74 * scale
        ))

        func resolvedTeamWidth(_ teamName: String?) -> CGFloat {
            // The fixed penalty strip is the one documented floor. Primary
            // content itself remains proportional because every scalable item
            // uses the same resolved scale and has no independent clamp.
            // The penalty row must fit inside the team cell; it must not widen
            // the whole scorebug. Both penalty slots use contain-fit geometry.
            let baseWidth = bases.teamCellWidth * scale
            guard let clean = cleanedTeamName(teamName), !clean.isEmpty else { return ceil(baseWidth) }
            let font = UIFont.systemFont(ofSize: effectiveFont, weight: uiFontWeight(layout.teamNameFontWeight))
            let textWidth = (clean as NSString).size(withAttributes: [.font: font]).width
            let logoAllowance = layout.logoPosition == .besideTeamName ? logo + logoGap : 0
            let basePadding: CGFloat = layout.logoPosition == .besideTeamName ? 18 : 42
            let desired = ceil(textWidth + scoreColumn + logoAllowance + basePadding * scale)
            let maximum = max(baseWidth, bases.teamCellMaximumWidth * scale)
            return min(max(baseWidth, desired), maximum)
        }

        let homeWidth = resolvedTeamWidth(homeTeamName)
        let awayWidth = resolvedTeamWidth(awayTeamName)
        let topWidth = homeWidth + awayWidth + centreWidth
            + penaltyPanelWidth * 2
            + spacing * 2
            + penaltyPanelSpacing * 2
            + horizontalPadding * 2
        let teamCoreHeight: CGFloat
        if layout.logoPosition == .centredAboveTeamName {
            teamCoreHeight = logo + logoGap + max(scoreFont + 8 * scale, effectiveFont * 1.65)
        } else {
            teamCoreHeight = max(logo, centreHeight)
        }
        let topHeight = max(teamCoreHeight, max(centreHeight, penaltyPanelHeight))
        let utilityHeight: CGFloat
        if includesGameSponsor {
            utilityHeight = max(30, 40 * scale)
        } else {
            utilityHeight = max(24, 32 * scale)
        }
        let utilityGap: CGFloat = max(3, 4 * scale)
        let sponsorWidth: CGFloat = includesGameSponsor ? 250 * scale : 0
        let logicalWidth = ceil(max(topWidth, sponsorWidth))
        let logicalHeight = ceil(
            utilityHeight + utilityGap + verticalPadding * 2 + topHeight
        )

        return BroadcastScorebugResolvedMetrics(
            layout: layout,
            outputScale: safeOutputScale,
            primaryContentScale: scale,
            effectiveTeamNameFontSize: effectiveFont,
            homeTeamCellWidth: homeWidth,
            awayTeamCellWidth: awayWidth,
            logoSize: logo,
            logoNameSpacing: logoGap,
            scoreFontSize: scoreFont,
            scoreColumnWidth: scoreColumn,
            clockZoneSize: clockSize,
            clockFontSize: clockFont,
            centreWidth: centreWidth,
            centreHeight: centreHeight,
            teamSpacing: spacing,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding,
            periodFontSize: periodFont,
            periodBandHeight: periodBand,
            strengthFontSize: strengthFont,
            strengthBandHeight: strengthBand,
            penaltyRowHeight: fixedPenaltyRowHeight,
            penaltyLabelWidth: fixedPenaltyLabelWidth,
            penaltyPlayerWidth: fixedPenaltyPlayerWidth,
            penaltyTimerReferenceHeight: timerReferenceHeight,
            penaltyTimerMinimumWidth: timerMinimumWidth,
            penaltySlotMinimumWidth: slotMinimumWidth,
            penaltyStripMinimumWidth: stripMinimumWidth,
            penaltyHeaderHeight: penaltyHeaderHeight,
            penaltyPanelWidth: penaltyPanelWidth,
            penaltyPanelHeight: penaltyPanelHeight,
            penaltyPanelSpacing: penaltyPanelSpacing,
            penaltyColumnGap: penaltyColumnGap,
            penaltyRowGap: penaltyRowGap,
            utilityStripHeight: utilityHeight,
            utilityStripGap: utilityGap,
            scorebugLogicalSize: CGSize(width: logicalWidth, height: logicalHeight)
        )
    }

    /// Preferred Clock size derived from the template's shared primary scale.
    static func desiredClockZoneSize(for layout: BroadcastScoreboardLayoutSnapshot) -> CGSize {
        resolve(layout: layout).clockZoneSize
    }

    /// Hard contain-fit constraint for an available rectangle. The ratio is a
    /// minimum presentation ratio; content remains aspect-fit and is never
    /// cropped or stretched.
    static func clockZoneSize(fitting availableSize: CGSize) -> CGSize {
        guard availableSize.width > 0, availableSize.height > 0 else { return .zero }
        let width = min(availableSize.width, availableSize.height * clockZoneWidthToHeightRatio)
        return CGSize(width: width, height: width / clockZoneWidthToHeightRatio)
    }

    static func clockZoneRect(fitting availableRect: CGRect) -> CGRect {
        let size = clockZoneSize(fitting: availableRect.size)
        return CGRect(
            x: availableRect.midX - size.width / 2,
            y: availableRect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    // Compatibility wrappers for older diagnostics/source references. New code
    // uses the explicit desired/fitting names above.
    static func clockZoneSize(maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        clockZoneSize(fitting: CGSize(width: maxWidth, height: maxHeight))
    }
    static func clockZoneSize(for layout: BroadcastScoreboardLayoutSnapshot) -> CGSize {
        desiredClockZoneSize(for: layout)
    }
    static func clockZoneRect(in availableRect: CGRect) -> CGRect {
        clockZoneRect(fitting: availableRect)
    }

    static func clockZoneHeight(for layout: BroadcastScoreboardLayoutSnapshot) -> CGFloat {
        resolve(layout: layout).clockZoneSize.height
    }
    static func clockFontSize(for layout: BroadcastScoreboardLayoutSnapshot) -> CGFloat {
        resolve(layout: layout).clockFontSize
    }
    static func teamCellWidth(for layout: BroadcastScoreboardLayoutSnapshot) -> CGFloat {
        resolve(layout: layout).homeTeamCellWidth
    }
    static func teamCellWidth(for layout: BroadcastScoreboardLayoutSnapshot, teamName: String?) -> CGFloat {
        resolve(layout: layout, homeTeamName: teamName).homeTeamCellWidth
    }
    static func logoSize(for layout: BroadcastScoreboardLayoutSnapshot) -> CGFloat { resolve(layout: layout).logoSize }
    static func logoNameSpacing(for layout: BroadcastScoreboardLayoutSnapshot) -> CGFloat { resolve(layout: layout).logoNameSpacing }
    static func scoreFontSize(for layout: BroadcastScoreboardLayoutSnapshot) -> CGFloat { resolve(layout: layout).scoreFontSize }
    static func scoreColumnWidth(for layout: BroadcastScoreboardLayoutSnapshot) -> CGFloat { resolve(layout: layout).scoreColumnWidth }
    static func centreWidth(for layout: BroadcastScoreboardLayoutSnapshot) -> CGFloat { resolve(layout: layout).centreWidth }
    static func centreHeight(for layout: BroadcastScoreboardLayoutSnapshot) -> CGFloat { resolve(layout: layout).centreHeight }
    static func teamSpacing(for layout: BroadcastScoreboardLayoutSnapshot) -> CGFloat { resolve(layout: layout).teamSpacing }
    static func horizontalPadding(for layout: BroadcastScoreboardLayoutSnapshot) -> CGFloat { resolve(layout: layout).horizontalPadding }
    static func verticalPadding(for layout: BroadcastScoreboardLayoutSnapshot) -> CGFloat { resolve(layout: layout).verticalPadding }
    static func utilityStripHeight(for layout: BroadcastScoreboardLayoutSnapshot, includesGameSponsor: Bool) -> CGFloat {
        resolve(layout: layout, includesGameSponsor: includesGameSponsor).utilityStripHeight
    }
    static func utilityStripGap(for layout: BroadcastScoreboardLayoutSnapshot) -> CGFloat { resolve(layout: layout).utilityStripGap }
    static func penaltyRowHeight(for layout: BroadcastScoreboardLayoutSnapshot) -> CGFloat { resolve(layout: layout).penaltyRowHeight }
    static func penaltyLabelWidth(for layout: BroadcastScoreboardLayoutSnapshot) -> CGFloat { resolve(layout: layout).penaltyLabelWidth }
    static func penaltyPlayerWidth(for layout: BroadcastScoreboardLayoutSnapshot) -> CGFloat { resolve(layout: layout).penaltyPlayerWidth }
    static func penaltyTimerReferenceHeight(for layout: BroadcastScoreboardLayoutSnapshot) -> CGFloat { resolve(layout: layout).penaltyTimerReferenceHeight }
    static func penaltyTimerMinimumWidth(for layout: BroadcastScoreboardLayoutSnapshot) -> CGFloat { resolve(layout: layout).penaltyTimerMinimumWidth }
    static func penaltySlotMinimumWidth(for layout: BroadcastScoreboardLayoutSnapshot) -> CGFloat { resolve(layout: layout).penaltySlotMinimumWidth }
    static func penaltyStripMinimumWidth(for layout: BroadcastScoreboardLayoutSnapshot) -> CGFloat { resolve(layout: layout).penaltyStripMinimumWidth }
    static func penaltyHeaderHeight(for layout: BroadcastScoreboardLayoutSnapshot) -> CGFloat { resolve(layout: layout).penaltyHeaderHeight }
    static func penaltyPanelWidth(for layout: BroadcastScoreboardLayoutSnapshot) -> CGFloat { resolve(layout: layout).penaltyPanelWidth }
    static func penaltyPanelHeight(for layout: BroadcastScoreboardLayoutSnapshot) -> CGFloat { resolve(layout: layout).penaltyPanelHeight }
    static func penaltyPanelSpacing(for layout: BroadcastScoreboardLayoutSnapshot) -> CGFloat { resolve(layout: layout).penaltyPanelSpacing }

    static func bottomStripHeight(for layout: BroadcastScoreboardLayoutSnapshot, includesGameSponsor: Bool) -> CGFloat {
        utilityStripHeight(for: layout, includesGameSponsor: includesGameSponsor)
    }

    static func centredNameMaxWidth(for layout: BroadcastScoreboardLayoutSnapshot) -> CGFloat {
        centredNameMaxWidth(for: layout, teamName: nil)
    }
    static func centredNameMaxWidth(for layout: BroadcastScoreboardLayoutSnapshot, teamName: String?) -> CGFloat {
        let metrics = resolve(layout: layout, homeTeamName: teamName)
        return max(88 * metrics.primaryContentScale, metrics.homeTeamCellWidth - metrics.scoreColumnWidth - 24 * metrics.primaryContentScale)
    }

    static func gameSponsorGap(for layout: BroadcastScoreboardLayoutSnapshot) -> CGFloat { 1 }
    static func gameSponsorHorizontalPadding(for layout: BroadcastScoreboardLayoutSnapshot) -> CGFloat {
        max(3, 4 * primaryContentScale(for: layout))
    }
    static func gameSponsorLogoMaxWidth(for layout: BroadcastScoreboardLayoutSnapshot) -> CGFloat {
        84 * primaryContentScale(for: layout)
    }
    static func gameSponsorLogoMaxHeight(for layout: BroadcastScoreboardLayoutSnapshot) -> CGFloat {
        30 * primaryContentScale(for: layout)
    }

    static func scorebugLogicalSize(for layout: BroadcastScoreboardLayoutSnapshot, includesGameSponsor: Bool) -> CGSize {
        resolve(layout: layout, includesGameSponsor: includesGameSponsor).scorebugLogicalSize
    }
    static func scorebugLogicalSize(
        for layout: BroadcastScoreboardLayoutSnapshot,
        includesGameSponsor: Bool,
        homeTeamName: String?,
        awayTeamName: String?
    ) -> CGSize {
        resolve(
            layout: layout,
            homeTeamName: homeTeamName,
            awayTeamName: awayTeamName,
            includesGameSponsor: includesGameSponsor
        ).scorebugLogicalSize
    }

    private static func primaryBases(for layout: BroadcastScoreboardLayoutSnapshot) -> PrimaryBases {
        // The former Compact table is now the neutral 34pt reference geometry.
        // Team Font scales it continuously; legacy density values are ignored.
        switch layout.logoPosition {
        case .centredAboveTeamName:
            return PrimaryBases(
                teamCellWidth: 326, teamCellMaximumWidth: 560,
                logoSize: 70, scoreFontSize: 48, scoreColumnWidth: 44,
                clockHeight: 23, teamSpacing: 10, horizontalPadding: 10,
                verticalPadding: 10, logoNameSpacing: 4,
                minimumLogoSize: 38, minimumScoreFontSize: 24, minimumClockHeight: 13
            )
        case .besideTeamName:
            return PrimaryBases(
                teamCellWidth: 224, teamCellMaximumWidth: 480,
                logoSize: 70, scoreFontSize: 48, scoreColumnWidth: 44,
                clockHeight: 23, teamSpacing: 6, horizontalPadding: 6,
                verticalPadding: 10, logoNameSpacing: 3,
                minimumLogoSize: 38, minimumScoreFontSize: 24, minimumClockHeight: 13
            )
        }
    }

    private static func cleanedTeamName(_ name: String?) -> String? {
        guard let name else { return nil }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
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
}


// MARK: - v0.9.0n2b Template persistence DTO

/// Codable representation of the broadcast scoreboard display settings.
/// Kept separate from the SwiftUI Color-based live snapshot so rink templates
/// can save and restore scoreboard appearance without affecting OCR calibration.
struct BroadcastScoreboardTemplateSettings: Codable, Hashable {
    var isVisible: Bool = true
    var positionPresetRawValue: String = BroadcastScoreboardPositionPreset.topMiddle.rawValue
    var logoPositionRawValue: String = BroadcastScoreboardLogoPosition.besideTeamName.rawValue
    var densityModeRawValue: String = BroadcastScoreboardDensityMode.compact.rawValue
    var showEventTimeline: Bool? = nil
    var safeMargin: Double = 28
    var horizontalOffset: Double = 0
    var verticalOffset: Double = 0
    var teamNameFontSize: Double = 26
    var teamNameFontWeightRawValue: String = BroadcastScoreboardFontWeight.heavy.rawValue
    var homeTeamNameColourRGBA: String = Color.white.rgbaString
    var awayTeamNameColourRGBA: String = Color.white.rgbaString
    var homeTeamBackgroundColourRGBA: String? = nil
    var awayTeamBackgroundColourRGBA: String? = nil
    var scoreboardBackgroundColourRGBA: String = Color.black.opacity(0.82).rgbaString
    var scoreboardBorderColourRGBA: String = Color.white.opacity(0.20).rgbaString
    var scoreColourRGBA: String = Color.white.rgbaString
    var useSharedScoreColour: Bool? = nil
    var homeScoreColourRGBA: String? = nil
    var awayScoreColourRGBA: String? = nil
    var clockColourRGBA: String = BroadcastTheme.clockAccent.rgbaString
    var periodColourRGBA: String = Color.white.opacity(0.72).rgbaString
    var logoContainerBackgroundRGBA: String = Color.white.opacity(0.06).rgbaString
    var homeLogoContainerBackgroundRGBA: String? = nil
    var awayLogoContainerBackgroundRGBA: String? = nil
    var accentColourRGBA: String = Color.cyan.opacity(0.85).rgbaString
}

@MainActor
final class BroadcastScoreboardLayoutSettings: ObservableObject {
    static let shared = BroadcastScoreboardLayoutSettings()

    /// The only presentation acknowledgement emitted by the scorebug owner.
    /// Individual properties remain editable bindings, but renderers consume
    /// this immutable value so a saved profile can never be observed half-applied.
    @Published private(set) var snapshot: BroadcastScoreboardLayoutSnapshot = .default

    private var persistenceTask: Task<Void, Never>?
    private var mutationSource = "BroadcastScoreboardLayoutSettings"
    private var mutationReason = "Direct scorebug setting edit"
    // Editable fields are intentionally not independent publishers. The owner
    // acknowledges their resolved value through `snapshot` once per mutation
    // transaction; direct controls also commit a snapshot from settingDidChange.
    private var mutationBatchDepth = 0
    private var batchedMutations: [String: (previous: String, next: String)] = [:]

    var isVisible: Bool { didSet { settingDidChange("isVisible", previous: String(oldValue), next: String(isVisible)) } }
    var positionPreset: BroadcastScoreboardPositionPreset { didSet { settingDidChange("positionPreset", previous: oldValue.rawValue, next: positionPreset.rawValue) } }
    var logoPosition: BroadcastScoreboardLogoPosition { didSet { settingDidChange("logoPosition", previous: oldValue.rawValue, next: logoPosition.rawValue) } }
    var densityMode: BroadcastScoreboardDensityMode { didSet { settingDidChange("densityMode", previous: oldValue.rawValue, next: densityMode.rawValue) } }
    var showEventTimeline: Bool { didSet { settingDidChange("showEventTimeline", previous: String(oldValue), next: String(showEventTimeline)) } }
    var safeMargin: CGFloat { didSet { settingDidChange("safeMargin", previous: Self.number(oldValue), next: Self.number(safeMargin)) } }
    var horizontalOffset: CGFloat { didSet { settingDidChange("horizontalOffset", previous: Self.number(oldValue), next: Self.number(horizontalOffset)) } }
    var verticalOffset: CGFloat { didSet { settingDidChange("verticalOffset", previous: Self.number(oldValue), next: Self.number(verticalOffset)) } }
    var teamNameFontSize: CGFloat { didSet { settingDidChange("teamNameFontSize", previous: Self.number(oldValue), next: Self.number(teamNameFontSize)) } }
    var teamNameFontWeight: BroadcastScoreboardFontWeight { didSet { settingDidChange("teamNameFontWeight", previous: oldValue.rawValue, next: teamNameFontWeight.rawValue) } }
    var homeTeamNameColour: Color { didSet { settingDidChange("homeTeamNameColour", previous: oldValue.rgbaString, next: homeTeamNameColour.rgbaString) } }
    var awayTeamNameColour: Color { didSet { settingDidChange("awayTeamNameColour", previous: oldValue.rgbaString, next: awayTeamNameColour.rgbaString) } }
    var homeTeamBackgroundColour: Color { didSet { settingDidChange("homeTeamBackgroundColour", previous: oldValue.rgbaString, next: homeTeamBackgroundColour.rgbaString) } }
    var awayTeamBackgroundColour: Color { didSet { settingDidChange("awayTeamBackgroundColour", previous: oldValue.rgbaString, next: awayTeamBackgroundColour.rgbaString) } }
    var scoreboardBackgroundColour: Color { didSet { settingDidChange("scoreboardBackgroundColour", previous: oldValue.rgbaString, next: scoreboardBackgroundColour.rgbaString) } }
    var scoreboardBorderColour: Color { didSet { settingDidChange("scoreboardBorderColour", previous: oldValue.rgbaString, next: scoreboardBorderColour.rgbaString) } }
    var scoreColour: Color { didSet { settingDidChange("scoreColour", previous: oldValue.rgbaString, next: scoreColour.rgbaString) } }
    var useSharedScoreColour: Bool { didSet { settingDidChange("useSharedScoreColour", previous: String(oldValue), next: String(useSharedScoreColour)) } }
    var homeScoreColour: Color { didSet { settingDidChange("homeScoreColour", previous: oldValue.rgbaString, next: homeScoreColour.rgbaString) } }
    var awayScoreColour: Color { didSet { settingDidChange("awayScoreColour", previous: oldValue.rgbaString, next: awayScoreColour.rgbaString) } }
    var clockColour: Color { didSet { settingDidChange("clockColour", previous: oldValue.rgbaString, next: clockColour.rgbaString) } }
    var periodColour: Color { didSet { settingDidChange("periodColour", previous: oldValue.rgbaString, next: periodColour.rgbaString) } }
    var logoContainerBackground: Color { didSet { settingDidChange("logoContainerBackground", previous: oldValue.rgbaString, next: logoContainerBackground.rgbaString) } }
    var homeLogoContainerBackground: Color { didSet { settingDidChange("homeLogoContainerBackground", previous: oldValue.rgbaString, next: homeLogoContainerBackground.rgbaString) } }
    var awayLogoContainerBackground: Color { didSet { settingDidChange("awayLogoContainerBackground", previous: oldValue.rgbaString, next: awayLogoContainerBackground.rgbaString) } }
    var accentColour: Color { didSet { settingDidChange("accentColour", previous: oldValue.rgbaString, next: accentColour.rgbaString) } }

    private func makeSnapshot() -> BroadcastScoreboardLayoutSnapshot {
        BroadcastScoreboardLayoutSnapshot(
            isVisible: isVisible,
            positionPreset: .topMiddle,
            logoPosition: logoPosition,
            densityMode: densityMode,
            showEventTimeline: showEventTimeline,
            safeMargin: safeMargin,
            horizontalOffset: horizontalOffset,
            verticalOffset: verticalOffset,
            teamNameFontSize: teamNameFontSize,
            teamNameFontWeight: teamNameFontWeight,
            homeTeamNameColour: homeTeamNameColour,
            awayTeamNameColour: awayTeamNameColour,
            homeTeamBackgroundColour: homeTeamBackgroundColour,
            awayTeamBackgroundColour: awayTeamBackgroundColour,
            scoreboardBackgroundColour: scoreboardBackgroundColour,
            scoreboardBorderColour: scoreboardBorderColour,
            scoreColour: scoreColour,
            useSharedScoreColour: useSharedScoreColour,
            homeScoreColour: homeScoreColour,
            awayScoreColour: awayScoreColour,
            clockColour: clockColour,
            periodColour: periodColour,
            logoContainerBackground: logoContainerBackground,
            homeLogoContainerBackground: homeLogoContainerBackground,
            awayLogoContainerBackground: awayLogoContainerBackground,
            accentColour: accentColour
        )
    }

    private init() {
        isVisible = UserDefaults.standard.object(forKey: Keys.isVisible) as? Bool ?? true
        positionPreset = .topMiddle
        logoPosition = BroadcastScoreboardLogoPosition(rawValue: UserDefaults.standard.string(forKey: Keys.logoPosition) ?? "") ?? .besideTeamName
        densityMode = .compact
        showEventTimeline = false // Build 708: viewer timeline retired; persisted legacy value ignored
        safeMargin = CGFloat(UserDefaults.standard.object(forKey: Keys.safeMargin) as? Double ?? 28)
        horizontalOffset = CGFloat(UserDefaults.standard.object(forKey: Keys.horizontalOffset) as? Double ?? 0)
        verticalOffset = CGFloat(UserDefaults.standard.object(forKey: Keys.verticalOffset) as? Double ?? 0)
        teamNameFontSize = CGFloat(max(20, min(48, UserDefaults.standard.object(forKey: Keys.teamNameFontSize) as? Double ?? 26)))
        teamNameFontWeight = BroadcastScoreboardFontWeight(rawValue: UserDefaults.standard.string(forKey: Keys.teamNameFontWeight) ?? "") ?? .heavy
        homeTeamNameColour = UserDefaults.standard.color(forKey: Keys.homeTeamNameColour) ?? .white
        awayTeamNameColour = UserDefaults.standard.color(forKey: Keys.awayTeamNameColour) ?? .white
        homeTeamBackgroundColour = UserDefaults.standard.color(forKey: Keys.homeTeamBackgroundColour) ?? BroadcastTheme.homeAccent.opacity(0.16)
        awayTeamBackgroundColour = UserDefaults.standard.color(forKey: Keys.awayTeamBackgroundColour) ?? BroadcastTheme.awayAccent.opacity(0.16)
        scoreboardBackgroundColour = UserDefaults.standard.color(forKey: Keys.scoreboardBackgroundColour) ?? Color.black.opacity(0.82)
        scoreboardBorderColour = UserDefaults.standard.color(forKey: Keys.scoreboardBorderColour) ?? Color.white.opacity(0.20)
        scoreColour = UserDefaults.standard.color(forKey: Keys.scoreColour) ?? .white
        useSharedScoreColour = UserDefaults.standard.object(forKey: Keys.useSharedScoreColour) as? Bool ?? false
        homeScoreColour = UserDefaults.standard.color(forKey: Keys.homeScoreColour) ?? BroadcastTheme.homeAccent
        awayScoreColour = UserDefaults.standard.color(forKey: Keys.awayScoreColour) ?? BroadcastTheme.awayAccent
        clockColour = UserDefaults.standard.color(forKey: Keys.clockColour) ?? BroadcastTheme.clockAccent
        periodColour = UserDefaults.standard.color(forKey: Keys.periodColour) ?? Color.white.opacity(0.72)
        let resolvedLogoContainerBackground = UserDefaults.standard.color(forKey: Keys.logoContainerBackground) ?? Color.white.opacity(0.06)
        logoContainerBackground = resolvedLogoContainerBackground
        homeLogoContainerBackground = UserDefaults.standard.color(forKey: Keys.homeLogoContainerBackground) ?? resolvedLogoContainerBackground
        awayLogoContainerBackground = UserDefaults.standard.color(forKey: Keys.awayLogoContainerBackground) ?? resolvedLogoContainerBackground
        accentColour = UserDefaults.standard.color(forKey: Keys.accentColour) ?? Color.cyan.opacity(0.85)
        snapshot = makeSnapshot()
    }

    func resetToDefault(source: String = "ScorebugSettings", reason: String = "Restore scorebug defaults") {
        withMutationContext(source: source, reason: reason) {
        let defaults = BroadcastScoreboardLayoutSnapshot.default
        isVisible = defaults.isVisible
        positionPreset = defaults.positionPreset
        logoPosition = defaults.logoPosition
        densityMode = defaults.densityMode
        showEventTimeline = false
        safeMargin = defaults.safeMargin
        horizontalOffset = defaults.horizontalOffset
        verticalOffset = defaults.verticalOffset
        teamNameFontSize = defaults.teamNameFontSize
        teamNameFontWeight = defaults.teamNameFontWeight
        homeTeamNameColour = defaults.homeTeamNameColour
        awayTeamNameColour = defaults.awayTeamNameColour
        homeTeamBackgroundColour = defaults.homeTeamBackgroundColour
        awayTeamBackgroundColour = defaults.awayTeamBackgroundColour
        scoreboardBackgroundColour = defaults.scoreboardBackgroundColour
        scoreboardBorderColour = defaults.scoreboardBorderColour
        scoreColour = defaults.scoreColour
        useSharedScoreColour = defaults.useSharedScoreColour
        homeScoreColour = defaults.homeScoreColour
        awayScoreColour = defaults.awayScoreColour
        clockColour = defaults.clockColour
        periodColour = defaults.periodColour
        logoContainerBackground = defaults.logoContainerBackground
        homeLogoContainerBackground = defaults.homeLogoContainerBackground
        awayLogoContainerBackground = defaults.awayLogoContainerBackground
        accentColour = defaults.accentColour
        }
    }


    var templateSettings: BroadcastScoreboardTemplateSettings {
        BroadcastScoreboardTemplateSettings(
            isVisible: isVisible,
            positionPresetRawValue: BroadcastScoreboardPositionPreset.topMiddle.rawValue,
            logoPositionRawValue: logoPosition.rawValue,
            densityModeRawValue: densityMode.rawValue,
            showEventTimeline: showEventTimeline,
            safeMargin: Double(safeMargin),
            horizontalOffset: Double(horizontalOffset),
            verticalOffset: Double(verticalOffset),
            teamNameFontSize: Double(teamNameFontSize),
            teamNameFontWeightRawValue: teamNameFontWeight.rawValue,
            homeTeamNameColourRGBA: homeTeamNameColour.rgbaString,
            awayTeamNameColourRGBA: awayTeamNameColour.rgbaString,
            homeTeamBackgroundColourRGBA: homeTeamBackgroundColour.rgbaString,
            awayTeamBackgroundColourRGBA: awayTeamBackgroundColour.rgbaString,
            scoreboardBackgroundColourRGBA: scoreboardBackgroundColour.rgbaString,
            scoreboardBorderColourRGBA: scoreboardBorderColour.rgbaString,
            scoreColourRGBA: scoreColour.rgbaString,
            useSharedScoreColour: useSharedScoreColour,
            homeScoreColourRGBA: homeScoreColour.rgbaString,
            awayScoreColourRGBA: awayScoreColour.rgbaString,
            clockColourRGBA: clockColour.rgbaString,
            periodColourRGBA: periodColour.rgbaString,
            logoContainerBackgroundRGBA: logoContainerBackground.rgbaString,
            homeLogoContainerBackgroundRGBA: homeLogoContainerBackground.rgbaString,
            awayLogoContainerBackgroundRGBA: awayLogoContainerBackground.rgbaString,
            accentColourRGBA: accentColour.rgbaString
        )
    }

    func applyTemplateSettings(
        _ template: BroadcastScoreboardTemplateSettings?,
        source: String = "ScorebugSettings",
        reason: String = "Apply scorebug template settings"
    ) {
        guard let template else { return }
        withMutationContext(source: source, reason: reason) {
        isVisible = template.isVisible
        positionPreset = .topMiddle
        logoPosition = BroadcastScoreboardLogoPosition(rawValue: template.logoPositionRawValue) ?? .besideTeamName
        densityMode = .compact
        showEventTimeline = false // Build 708: imported legacy timeline preference is ignored
        safeMargin = CGFloat(max(12, min(80, template.safeMargin)))
        horizontalOffset = CGFloat(max(-220, min(220, template.horizontalOffset)))
        verticalOffset = CGFloat(max(-160, min(160, template.verticalOffset)))
        teamNameFontSize = CGFloat(max(20, min(48, template.teamNameFontSize)))
        teamNameFontWeight = BroadcastScoreboardFontWeight(rawValue: template.teamNameFontWeightRawValue) ?? .heavy
        homeTeamNameColour = Color(rgbaString: template.homeTeamNameColourRGBA) ?? .white
        awayTeamNameColour = Color(rgbaString: template.awayTeamNameColourRGBA) ?? .white
        homeTeamBackgroundColour = Color(rgbaString: template.homeTeamBackgroundColourRGBA ?? "") ?? BroadcastTheme.homeAccent.opacity(0.16)
        awayTeamBackgroundColour = Color(rgbaString: template.awayTeamBackgroundColourRGBA ?? "") ?? BroadcastTheme.awayAccent.opacity(0.16)
        scoreboardBackgroundColour = Color(rgbaString: template.scoreboardBackgroundColourRGBA) ?? Color.black.opacity(0.82)
        scoreboardBorderColour = Color(rgbaString: template.scoreboardBorderColourRGBA) ?? Color.white.opacity(0.20)
        scoreColour = Color(rgbaString: template.scoreColourRGBA) ?? .white
        useSharedScoreColour = template.useSharedScoreColour ?? false
        homeScoreColour = Color(rgbaString: template.homeScoreColourRGBA ?? "") ?? BroadcastTheme.homeAccent
        awayScoreColour = Color(rgbaString: template.awayScoreColourRGBA ?? "") ?? BroadcastTheme.awayAccent
        clockColour = Color(rgbaString: template.clockColourRGBA) ?? BroadcastTheme.clockAccent
        periodColour = Color(rgbaString: template.periodColourRGBA) ?? Color.white.opacity(0.72)
        logoContainerBackground = Color(rgbaString: template.logoContainerBackgroundRGBA) ?? Color.white.opacity(0.06)
        homeLogoContainerBackground = Color(rgbaString: template.homeLogoContainerBackgroundRGBA ?? "") ?? logoContainerBackground
        awayLogoContainerBackground = Color(rgbaString: template.awayLogoContainerBackgroundRGBA ?? "") ?? logoContainerBackground
        accentColour = Color(rgbaString: template.accentColourRGBA) ?? Color.cyan.opacity(0.85)
        }
    }

    private func withMutationContext(source: String, reason: String, _ changes: () -> Void) {
        let previousSource = mutationSource
        let previousReason = mutationReason
        let isOuterTransaction = mutationBatchDepth == 0
        mutationSource = source
        mutationReason = reason
        mutationBatchDepth += 1
        changes()
        mutationBatchDepth = max(0, mutationBatchDepth - 1)

        if isOuterTransaction, !batchedMutations.isEmpty {
            let previousValues = Dictionary(uniqueKeysWithValues: batchedMutations.map { key, value in
                (key, value.previous)
            })
            let nextValues = Dictionary(uniqueKeysWithValues: batchedMutations.map { key, value in
                (key, value.next)
            })
            if RinkLensRiskFeaturePolicy.isEnabled(.scorebugStructuredMutationsV2) {
                RinkLensStructuredEventLogger.shared.record(
                    domain: .scorebug,
                    event: "scorebug_settings_transaction_changed",
                    entityID: "appearance",
                    previous: previousValues,
                    next: nextValues,
                    source: mutationSource,
                    reason: mutationReason
                )
            }
            batchedMutations.removeAll(keepingCapacity: true)
            // This is the physical presentation boundary for the transaction.
            // Every renderer receives one complete scorebug value, never the
            // sequence of editable fields used to construct it.
            snapshot = makeSnapshot()
            schedulePersistence()
        }

        mutationSource = previousSource
        mutationReason = previousReason
    }

    private func settingDidChange(_ field: String, previous: String, next: String) {
        guard previous != next else { return }
        if mutationBatchDepth > 0 {
            if let existing = batchedMutations[field] {
                batchedMutations[field] = (previous: existing.previous, next: next)
            } else {
                batchedMutations[field] = (previous: previous, next: next)
            }
            return
        }
        if RinkLensRiskFeaturePolicy.isEnabled(.scorebugStructuredMutationsV2) {
            RinkLensStructuredEventLogger.shared.record(
                domain: .scorebug,
                event: "scorebug_setting_changed",
                entityID: field,
                previous: [field: previous],
                next: [field: next],
                source: mutationSource,
                reason: mutationReason
            )
        }
        snapshot = makeSnapshot()
        schedulePersistence()
    }

    private static func number(_ value: CGFloat) -> String {
        String(format: "%.3f", Double(value))
    }

    private func schedulePersistence() {
        persistenceTask?.cancel()
        persistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, !Task.isCancelled else { return }
            self.persistCurrentSettings()
            self.persistenceTask = nil
        }
    }

    private func persistCurrentSettings() {
        let defaults = UserDefaults.standard
        defaults.set(isVisible, forKey: Keys.isVisible)
        defaults.set(positionPreset.rawValue, forKey: Keys.positionPreset)
        defaults.set(logoPosition.rawValue, forKey: Keys.logoPosition)
        defaults.set(densityMode.rawValue, forKey: Keys.densityMode)
        defaults.set(showEventTimeline, forKey: Keys.showEventTimeline)
        defaults.set(Double(safeMargin), forKey: Keys.safeMargin)
        defaults.set(Double(horizontalOffset), forKey: Keys.horizontalOffset)
        defaults.set(Double(verticalOffset), forKey: Keys.verticalOffset)
        defaults.set(Double(teamNameFontSize), forKey: Keys.teamNameFontSize)
        defaults.set(teamNameFontWeight.rawValue, forKey: Keys.teamNameFontWeight)
        defaults.set(homeTeamNameColour.rgbaString, forKey: Keys.homeTeamNameColour)
        defaults.set(awayTeamNameColour.rgbaString, forKey: Keys.awayTeamNameColour)
        defaults.set(homeTeamBackgroundColour.rgbaString, forKey: Keys.homeTeamBackgroundColour)
        defaults.set(awayTeamBackgroundColour.rgbaString, forKey: Keys.awayTeamBackgroundColour)
        defaults.set(scoreboardBackgroundColour.rgbaString, forKey: Keys.scoreboardBackgroundColour)
        defaults.set(scoreboardBorderColour.rgbaString, forKey: Keys.scoreboardBorderColour)
        defaults.set(scoreColour.rgbaString, forKey: Keys.scoreColour)
        defaults.set(useSharedScoreColour, forKey: Keys.useSharedScoreColour)
        defaults.set(homeScoreColour.rgbaString, forKey: Keys.homeScoreColour)
        defaults.set(awayScoreColour.rgbaString, forKey: Keys.awayScoreColour)
        defaults.set(clockColour.rgbaString, forKey: Keys.clockColour)
        defaults.set(periodColour.rgbaString, forKey: Keys.periodColour)
        defaults.set(logoContainerBackground.rgbaString, forKey: Keys.logoContainerBackground)
        defaults.set(homeLogoContainerBackground.rgbaString, forKey: Keys.homeLogoContainerBackground)
        defaults.set(awayLogoContainerBackground.rgbaString, forKey: Keys.awayLogoContainerBackground)
        defaults.set(accentColour.rgbaString, forKey: Keys.accentColour)
    }

    private enum Keys {
        static let prefix = "broadcast.scoreboard.layout."
        static let isVisible = prefix + "isVisible"
        static let positionPreset = prefix + "positionPreset"
        static let logoPosition = prefix + "logoPosition"
        static let densityMode = prefix + "densityMode"
        static let showEventTimeline = prefix + "showEventTimeline"
        static let safeMargin = prefix + "safeMargin"
        static let horizontalOffset = prefix + "horizontalOffset"
        static let verticalOffset = prefix + "verticalOffset"
        static let teamNameFontSize = prefix + "teamNameFontSize"
        static let teamNameFontWeight = prefix + "teamNameFontWeight"
        static let homeTeamNameColour = prefix + "homeTeamNameColour"
        static let awayTeamNameColour = prefix + "awayTeamNameColour"
        static let homeTeamBackgroundColour = prefix + "homeTeamBackgroundColour"
        static let awayTeamBackgroundColour = prefix + "awayTeamBackgroundColour"
        static let scoreboardBackgroundColour = prefix + "scoreboardBackgroundColour"
        static let scoreboardBorderColour = prefix + "scoreboardBorderColour"
        static let scoreColour = prefix + "scoreColour"
        static let useSharedScoreColour = prefix + "useSharedScoreColour"
        static let homeScoreColour = prefix + "homeScoreColour"
        static let awayScoreColour = prefix + "awayScoreColour"
        static let clockColour = prefix + "clockColour"
        static let periodColour = prefix + "periodColour"
        static let logoContainerBackground = prefix + "logoContainerBackground"
        static let homeLogoContainerBackground = prefix + "homeLogoContainerBackground"
        static let awayLogoContainerBackground = prefix + "awayLogoContainerBackground"
        static let accentColour = prefix + "accentColour"
    }
}

private extension UserDefaults {
    func color(forKey key: String) -> Color? {
        guard let string = string(forKey: key) else { return nil }
        return Color(rgbaString: string)
    }
}


#endif
