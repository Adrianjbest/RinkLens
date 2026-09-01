// BUILD 700 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import UIKit

/// Recovery CQ / RL-212: one paint contract for the scorebug surfaces that
/// must remain visually identical in SwiftUI preview and Core Graphics encoded
/// output. Renderers may differ for real-time cost, but colour/opacity decisions
/// do not.
nonisolated enum BroadcastScorebugPaintContract {
    static let backgroundLeadingOpacity = 0.98
    static let backgroundMiddleOpacity = 0.90
    static let backgroundGlassOpacity = 0.82
    static let borderLeadingOpacity = 0.95
    static let borderTrailingOpacity = 0.60
    static let centreFillOpacity = 0.28
    static let centreStrokeOpacity = 0.62
}

// MARK: - Phase 1 Public Scorebug

/// Viewer-safe scorebug for the broadcast output.
/// It intentionally does not render OCR debug information, calibration boxes, or operator controls.
struct ScorebugView: View {
    let viewerScoreboard: RinkLensViewerScoreboardSnapshot
    private var state: ScoreboardState { viewerScoreboard.state }
    let homeLogo: UIImage?
    let awayLogo: UIImage?
    var isLive: Bool = true
    var modeStatusText: String = "OCR Enabled"
    var showClockShotsAndPenalties: Bool = true
    var layout: BroadcastScoreboardLayoutSnapshot = .default
    var gameSponsorName: String = ""
    var gameSponsorLogo: UIImage? = nil
    var strengthState: StrengthState = .evenStrength

    private enum TeamSide { case home, away }

    private struct PenaltyEntry: Identifiable {
        let id: String
        let player: Int?
        let clock: String
    }

    private var resolvedMetrics: BroadcastScorebugResolvedMetrics {
        BroadcastScorebugTemplateMetrics.resolve(
            layout: layout,
            homeTeamName: state.homeTeam,
            awayTeamName: state.awayTeam,
            includesGameSponsor: BroadcastScorebugTemplateMetrics.reservesInvariantUtilityStripGeometry,
            outputScale: 1
        )
    }
    private func teamCellWidth(for side: TeamSide) -> CGFloat {
        side == .home ? resolvedMetrics.homeTeamCellWidth : resolvedMetrics.awayTeamCellWidth
    }
    private var logoSize: CGFloat { resolvedMetrics.logoSize }
    private var logoNameSpacing: CGFloat { resolvedMetrics.logoNameSpacing }
    private var scoreFontSize: CGFloat { resolvedMetrics.scoreFontSize }
    private var scoreColumnWidth: CGFloat { resolvedMetrics.scoreColumnWidth }
    private var centreWidth: CGFloat { resolvedMetrics.centreWidth }
    private var clockZoneSize: CGSize { resolvedMetrics.clockZoneSize }
    private var clockFontSize: CGFloat { resolvedMetrics.clockFontSize }
    private var effectiveTeamNameFontSize: CGFloat { resolvedMetrics.effectiveTeamNameFontSize }
    private var hasGameSponsor: Bool {
        !gameSponsorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var imageRelaySnapshot: ScoreboardImageRelaySnapshot {
        viewerScoreboard.relay
    }
    private var imageRelayIsActuallyLive: Bool {
        guard isLive else { return false }
        return imageRelaySnapshot.isFresh
            || modeStatusText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "IMAGE RELAY LIVE"
    }
    private var ocrIsActuallyLive: Bool {
        guard isLive else { return false }
        switch modeStatusText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "OCR RUNNING", "OCR ACQUIRING SCOREBOARD", "OCR ARMING PENALTIES":
            return true
        default:
            return false
        }
    }
    private var automaticFeedIsLive: Bool { ocrIsActuallyLive || imageRelayIsActuallyLive }
    private var scorebugLogicalSize: CGSize { resolvedMetrics.scorebugLogicalSize }

    var body: some View {
        VStack(spacing: resolvedMetrics.utilityStripGap) {
            // Recovery S / RL-054: keep this row mounted even when it has no
            // visible contents. Feed freshness is presentation state and must
            // never move the scorebug's main geometry.
            utilityRow
                .frame(width: scorebugLogicalSize.width)

            HStack(alignment: .center, spacing: resolvedMetrics.teamSpacing) {
                HStack(alignment: .center, spacing: resolvedMetrics.penaltyPanelSpacing) {
                    penaltyPanel(side: .home, accent: scoreColour(for: .home))
                    teamCell(
                        title: state.homeTeam ?? "HOME",
                        score: state.homeScore,
                        logo: homeLogo,
                        accent: BroadcastTheme.homeAccent,
                        logoBackground: layout.homeLogoContainerBackground,
                        teamNameColour: layout.homeTeamNameColour,
                        teamBackground: layout.homeTeamBackgroundColour,
                        side: .home
                    )
                }

                centerStatusCell

                HStack(alignment: .center, spacing: resolvedMetrics.penaltyPanelSpacing) {
                    teamCell(
                        title: state.awayTeam ?? "GUEST",
                        score: state.awayScore,
                        logo: awayLogo,
                        accent: BroadcastTheme.awayAccent,
                        logoBackground: layout.awayLogoContainerBackground,
                        teamNameColour: layout.awayTeamNameColour,
                        teamBackground: layout.awayTeamBackgroundColour,
                        side: .away
                    )
                    penaltyPanel(side: .away, accent: scoreColour(for: .away))
                }
            }
            .padding(.horizontal, resolvedMetrics.horizontalPadding)
            .padding(.vertical, resolvedMetrics.verticalPadding)
            .background(scorebugBackground)
            .clipShape(RoundedRectangle(cornerRadius: BroadcastTheme.scorebugCornerRadius, style: .continuous))
            .overlay(scorebugBorder)
            .shadow(color: BroadcastTheme.shadow, radius: 18, x: 0, y: 7)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }

    private var utilityRow: some View {
        // Recovery CS / RL-216: these are invariant physical zones. Relay
        // freshness may show or hide the left badge, but can never reflow the
        // game sponsor from centre to the recording's right edge.
        ZStack {
            if automaticFeedIsLive {
                liveBadge
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if hasGameSponsor {
                gameSponsorBadge
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(
            width: scorebugLogicalSize.width,
            height: resolvedMetrics.utilityStripHeight
        )
    }

    private var centerStatusCell: some View {
        let largerPeriodGlyph = RinkLensRiskFeaturePolicy.isEnabled(.largerPeriodGlyphV9)
        return VStack(spacing: largerPeriodGlyph ? 0 : 2) {
            Text(state.periodDisplay.replacingOccurrences(of: "PERIOD", with: "P"))
                .font(.system(size: resolvedMetrics.periodFontSize, weight: .black, design: .rounded))
                .foregroundStyle(layout.periodColour)
                .monospacedDigit()
                .lineLimit(1)
                // Build 719 enlarges only the rendered Period glyph. scaleEffect
                // does not participate in layout, so centreWidth, centreHeight,
                // Clock zone and the overall scorebug canvas remain unchanged.
                .scaleEffect(largerPeriodGlyph ? 1.20 : 1.0, anchor: .center)
                .id("viewer-period-text-\(imageRelaySnapshot.revision)-\(state.periodDisplay)")
            if showClockShotsAndPenalties {
                if imageRelaySnapshot.enabled {
                    if let clockImage = imageRelaySnapshot.image(for: .clock) {
                        BroadcastImageRelayClockView(
                            image: clockImage,
                            colour: layout.clockColour,
                            zoneSize: clockZoneSize
                        )
                        // Build 734 keeps one stable SwiftUI identity for the
                        // Clock image. Recreating the view on every relay revision
                        // could briefly retain the old layer under an animated
                        // parent update, making two digit states appear overlaid.
                        .transaction { transaction in
                            transaction.animation = nil
                        }
                    } else {
                        Text(state.clock ?? "--:--")
                            .font(.system(size: clockFontSize, weight: .black, design: .monospaced))
                            .foregroundStyle(layout.clockColour)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                            .frame(width: clockZoneSize.width, height: clockZoneSize.height)
                    }
                } else {
                    Text(state.clock ?? "--:--")
                        .font(.system(size: clockFontSize, weight: .black, design: .monospaced))
                        .foregroundStyle(layout.clockColour)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .frame(width: clockZoneSize.width, height: clockZoneSize.height)
                }
            }
            if showClockShotsAndPenalties {
                Text(imageRelaySnapshot.enabled ? imageRelaySnapshot.visualManpowerText : strengthState.scorebugManpowerText)
                    .font(.system(size: resolvedMetrics.strengthFontSize, weight: .black, design: .rounded))
                    .foregroundStyle(strengthAccent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .allowsTightening(true)
                    .frame(
                        width: max(1, centreWidth - 4),
                        height: resolvedMetrics.strengthBandHeight,
                        alignment: .center
                    )
                    .accessibilityLabel("Players on ice \(imageRelaySnapshot.enabled ? imageRelaySnapshot.visualManpowerText : strengthState.scorebugManpowerText)")
            }
        }
        .frame(
            width: centreWidth,
            height: resolvedMetrics.centreHeight
        )
        .background(Color.black.opacity(BroadcastScorebugPaintContract.centreFillOpacity))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(strengthAccent.opacity(BroadcastScorebugPaintContract.centreStrokeOpacity), lineWidth: 1)
        )
    }

    private var strengthAccent: Color {
        let advantagedTeam = imageRelaySnapshot.enabled
            ? imageRelaySnapshot.visualAdvantagedTeam
            : strengthState.advantagedTeam
        switch advantagedTeam {
        case .home:
            return layout.useSharedScoreColour ? layout.scoreColour : layout.homeScoreColour
        case .away:
            return layout.useSharedScoreColour ? layout.scoreColour : layout.awayScoreColour
        case nil:
            return layout.accentColour
        }
    }

    @ViewBuilder
    private func teamCell(
        title: String,
        score: Int?,
        logo: UIImage?,
        accent: Color,
        logoBackground: Color,
        teamNameColour: Color,
        teamBackground: Color,
        side: TeamSide
    ) -> some View {
        switch layout.logoPosition {
        case .besideTeamName:
            besideTeamNameCell(
                title: title,
                score: score,
                logo: logo,
                accent: accent,
                logoBackground: logoBackground,
                teamNameColour: teamNameColour,
                teamBackground: teamBackground,
                side: side
            )
        case .centredAboveTeamName:
            logoAboveTeamNameCell(
                title: title,
                score: score,
                logo: logo,
                accent: accent,
                logoBackground: logoBackground,
                teamNameColour: teamNameColour,
                teamBackground: teamBackground,
                side: side
            )
        }
    }

    private func besideTeamNameCell(
        title: String,
        score: Int?,
        logo: UIImage?,
        accent: Color,
        logoBackground: Color,
        teamNameColour: Color,
        teamBackground: Color,
        side: TeamSide
    ) -> some View {
        let isHome = side == .home
        return HStack(spacing: logoNameSpacing) {
            if isHome {
                logoView(logo: logo, accent: accent, logoBackground: logoBackground)
                justifiedTeamName(
                    title: title,
                    accent: accent,
                    colour: teamNameColour,
                    side: side,
                    alignment: teamNameAlignment(for: side)
                )
                scoreText(score, side: side)
            } else {
                scoreText(score, side: side)
                justifiedTeamName(
                    title: title,
                    accent: accent,
                    colour: teamNameColour,
                    side: side,
                    alignment: teamNameAlignment(for: side)
                )
                logoView(logo: logo, accent: accent, logoBackground: logoBackground)
            }
        }
        .frame(width: teamCellWidth(for: side), alignment: .center)
        .frame(minHeight: logoSize + 4, alignment: .center)
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(teamBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func logoAboveTeamNameCell(
        title: String,
        score: Int?,
        logo: UIImage?,
        accent: Color,
        logoBackground: Color,
        teamNameColour: Color,
        teamBackground: Color,
        side: TeamSide
    ) -> some View {
        HStack(alignment: .bottom, spacing: 7) {
            if side == .away { scoreText(score, side: side) }

            VStack(spacing: logoNameSpacing) {
                logoView(logo: logo, accent: accent, logoBackground: logoBackground)
                alignedTeamNameAboveLogo(
                    title: title,
                    accent: accent,
                    colour: teamNameColour,
                    side: side
                )
            }
            .frame(
                width: BroadcastScorebugTemplateMetrics.centredNameMaxWidth(
                    for: layout,
                    teamName: title
                ),
                alignment: .center
            )

            if side == .home { scoreText(score, side: side) }
        }
        .frame(minWidth: teamCellWidth(for: side), alignment: .center)
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(teamBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private struct PenaltyPanelColumns {
        let player: CGFloat
        let timer: CGFloat
    }

    private var penaltyPanelColumns: PenaltyPanelColumns {
        let available = max(
            2,
            resolvedMetrics.penaltyPanelWidth - resolvedMetrics.penaltyColumnGap
        )
        // Fixed column geometry prevents left/right pulsing as the physical
        // number changes. The player column reserves the accepted widest
        // two-digit aspect; the timer receives the remainder.
        let requestedPlayer = max(
            resolvedMetrics.penaltyPlayerWidth,
            resolvedMetrics.penaltyTimerReferenceHeight
                * BroadcastScorebugTemplateMetrics.penaltyPlayerReservedWidthToHeightRatio
        )
        // Build 656 reserves the player at its accepted maximum aspect and
        // gives the remaining width to the Clock-style timer. The former 42/58
        // split starved wide timers and forced their visible height smaller.
        let player = min(available, requestedPlayer)
        return PenaltyPanelColumns(player: floor(player), timer: max(1, available - floor(player)))
    }

    private func penaltyPanel(side: TeamSide, accent: Color) -> some View {
        let columns = penaltyPanelColumns
        return VStack(spacing: resolvedMetrics.penaltyRowGap) {
            HStack(spacing: resolvedMetrics.penaltyColumnGap) {
                Text("PLYR")
                    .frame(width: columns.player)
                Text("PENALTY")
                    .frame(width: columns.timer)
            }
            .font(.system(size: max(8, resolvedMetrics.penaltyHeaderHeight * 0.58), weight: .black, design: .rounded))
            .foregroundStyle(.white.opacity(0.70))
            .lineLimit(1)
            .minimumScaleFactor(0.68)
            .frame(height: resolvedMetrics.penaltyHeaderHeight)

            penaltyPanelRow(side: side, slot: 1, accent: accent, columns: columns)
            penaltyPanelRow(side: side, slot: 2, accent: accent, columns: columns)
        }
        .frame(
            width: resolvedMetrics.penaltyPanelWidth,
            height: resolvedMetrics.penaltyPanelHeight,
            alignment: .center
        )
        .padding(.horizontal, 2)
        .background(Color.black.opacity(0.20), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(accent.opacity(0.34), lineWidth: 1)
        )
        .accessibilityLabel(side == .home ? "Home penalties" : "Away penalties")
    }

    @ViewBuilder
    private func penaltyPanelRow(
        side: TeamSide,
        slot: Int,
        accent: Color,
        columns: PenaltyPanelColumns
    ) -> some View {
        if imageRelaySnapshot.enabled {
            relayPenaltyPanelRow(
                side: side,
                slot: slot,
                accent: accent,
                columns: columns
            )
        } else {
            softwarePenaltyPanelRow(
                penaltyEntry(for: side, slot: slot),
                side: side,
                accent: accent,
                columns: columns
            )
        }
    }

    private func softwarePenaltyPanelRow(
        _ penalty: PenaltyEntry?,
        side: TeamSide,
        accent: Color,
        columns: PenaltyPanelColumns
    ) -> some View {
        let active = penalty != nil
        let colour = scoreColour(for: side).opacity(active ? 0.98 : 0.0)
        return HStack(spacing: resolvedMetrics.penaltyColumnGap) {
            penaltyPanelCell(active: active, accent: accent) {
                Text(penalty?.player.map { "#\($0)" } ?? "")
                    .font(.system(size: 16, weight: .black, design: .rounded))
                    .foregroundStyle(colour)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)
            }
            .frame(width: columns.player)

            penaltyPanelCell(active: active, accent: accent) {
                Text(penalty?.clock ?? "")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundStyle(colour)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)
            }
            .frame(width: columns.timer)
        }
        .frame(height: resolvedMetrics.penaltyRowHeight)
    }

    private func penaltyPanelCell<Content: View>(
        active: Bool,
        accent: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(
                accent.opacity(active ? 0.24 : 0.07),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(accent.opacity(active ? 0.66 : 0.16), lineWidth: 1)
            )
    }

    @ViewBuilder
    private func relayGlyph(
        _ image: CGImage,
        colour: Color,
        crisp: Bool = false,
        stretchToFill: Bool = false
    ) -> some View {
        Group {
            if stretchToFill {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(crisp ? .none : .medium)
            } else if crisp {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.none)
                    .scaledToFit()
            } else {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.medium)
                    .scaledToFit()
            }
        }
        .foregroundStyle(colour)
        .accessibilityHidden(true)
    }

    private func sharedPenaltyGlyphLayout(
        pair: ScoreboardImageRelayPenaltyPair,
        rowHeight: CGFloat,
        availableWidth: CGFloat? = nil
    ) -> BroadcastScorebugPenaltyPairLayout {
        BroadcastScorebugGlyphLayoutResolver.penaltyPair(
            // Player and timer relay images are both normalised to the same
            // 90px canvas height. Layout from that published canvas, not a second
            // tight-content measurement, otherwise transparent padding makes each
            // physical slot render at a different visible height.
            playerSourceSize: pair.playerImage.map { CGSize(width: $0.width, height: $0.height) },
            timerSourceSize: pair.time.map { CGSize(width: $0.width, height: $0.height) },
            rowHeight: rowHeight,
            referenceVisibleHeight: resolvedMetrics.penaltyTimerReferenceHeight,
            minimumPlayerWidth: resolvedMetrics.penaltyPlayerWidth,
            minimumTimerWidth: resolvedMetrics.penaltyTimerMinimumWidth,
            minimumSlotWidth: resolvedMetrics.penaltySlotMinimumWidth,
            gap: 0,
            availableWidth: availableWidth
        )
    }

    private func relayPenaltyPanelRow(
        side: TeamSide,
        slot: Int,
        accent: Color,
        columns: PenaltyPanelColumns
    ) -> some View {
        let team: Team = side == .home ? .home : .away
        let pair = imageRelaySnapshot.penaltyPair(side: team, slot: slot)
        let stableCanvasEnabled = RinkLensRiskFeaturePolicy.isEnabled(.stablePenaltyTimerCanvasScaleV2)
        let heightParityEnabled = !stableCanvasEnabled
            && RinkLensRiskFeaturePolicy.isEnabled(.penaltyTimerVisibleHeightParityV2)
        // Build 697 restores the stable producer canvases. The Build 696 tight
        // alpha crop remains available only when the new comparison flag is off.
        let playerDisplayImage = pair.playerImage.map { image in
            (heightParityEnabled || slot == 2)
                ? BroadcastScorebugGlyphLayoutResolver.visibleContentImage(of: image)
                : image
        }
        let timerDisplayImage = pair.time.map { image in
            (heightParityEnabled || slot == 2)
                ? BroadcastScorebugGlyphLayoutResolver.visibleContentImage(of: image)
                : image
        }
        let timerDisplayScale = stableCanvasEnabled
            ? BroadcastScorebugTemplateMetrics.stablePenaltyTimerDisplayScale
            : 1.0
        let glyphHeight = max(1, min(
            resolvedMetrics.penaltyTimerReferenceHeight,
            resolvedMetrics.penaltyRowHeight - 4
        ))
        let pairLayout = BroadcastScorebugGlyphLayoutResolver.penaltyPairInSeparateCells(
            playerSourceSize: playerDisplayImage.map { CGSize(width: $0.width, height: $0.height) },
            timerSourceSize: timerDisplayImage.map { CGSize(width: $0.width, height: $0.height) },
            playerAvailableSize: CGSize(width: max(1, columns.player - 4), height: glyphHeight),
            timerAvailableSize: CGSize(width: max(1, columns.timer - 4), height: glyphHeight),
            referenceVisibleHeight: glyphHeight
        )
        let playerFontSize = max(18, pairLayout.player.visibleHeight + 1)
        let glyphColour = BroadcastScorebugColourResolver.penaltyColour(
            layout: layout,
            side: side == .home ? .home : .away
        ).opacity(0.98)

        return HStack(spacing: resolvedMetrics.penaltyColumnGap) {
            penaltyPanelCell(active: pair.active, accent: accent) {
                // Build 645: a timer crop can still contain the physical board's
                // decorative dots/dashes while the player slot is empty. The
                // confirmed player glyph is the sole visual occupancy authority.
                if pair.active {
                    if let playerImage = playerDisplayImage {
                        relayGlyph(
                            playerImage,
                            colour: glyphColour,
                            crisp: false,
                            stretchToFill: false
                        )
                        .frame(width: pairLayout.player.frameSize.width, height: pairLayout.player.frameSize.height)
                        .id("relay-pen-player-side-panel-\(team.rawValue)-\(slot)")
                    } else if let player = pair.player {
                        Text(player)
                            .font(.system(size: playerFontSize, weight: .black, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(glyphColour)
                            .lineLimit(1)
                            .minimumScaleFactor(0.70)
                    }
                }
            }
            .frame(width: columns.player)

            penaltyPanelCell(active: pair.active, accent: accent) {
                // Build 647: blank physical penalty slots on this scoreboard can
                // still carry decorative timer-side dots/dashes. Never render
                // the timer crop unless the slot itself is confirmed active.
                if pair.active, let time = timerDisplayImage {
                    relayGlyph(
                        time,
                        colour: glyphColour,
                        crisp: false,
                        stretchToFill: false
                    )
                    .frame(width: pairLayout.timer.frameSize.width, height: pairLayout.timer.frameSize.height)
                    .scaleEffect(timerDisplayScale, anchor: .center)
                    .frame(width: max(1, columns.timer - 4), height: glyphHeight, alignment: .center)
                    .clipped()
                    .id("relay-pen-timer-side-panel-\(team.rawValue)-\(slot)")
                }
            }
            .frame(width: columns.timer)
        }
        .frame(height: resolvedMetrics.penaltyRowHeight)
    }

    private func penaltyEntry(for side: TeamSide, slot: Int) -> PenaltyEntry? {
        let id: String
        let player: Int?
        let clock: String?
        switch (side, slot) {
        case (.home, 1):
            id = "home1"; player = state.homePenalty1Player; clock = state.homePenalty1Clock
        case (.home, _):
            id = "home2"; player = state.homePenalty2Player; clock = state.homePenalty2Clock
        case (.away, 1):
            id = "away1"; player = state.awayPenalty1Player; clock = state.awayPenalty1Clock
        case (.away, _):
            id = "away2"; player = state.awayPenalty2Player; clock = state.awayPenalty2Clock
        }
        guard let clock, isActivePenaltyClock(clock) else { return nil }
        return PenaltyEntry(id: id, player: player, clock: clock)
    }

    private func penaltyEntries(for side: TeamSide) -> [PenaltyEntry] {
        [penaltyEntry(for: side, slot: 1), penaltyEntry(for: side, slot: 2)].compactMap { $0 }
    }

    private func isActivePenaltyClock(_ value: String) -> Bool {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard parts.count == 2,
              let minutes = Int(parts[0]),
              let seconds = Int(parts[1]),
              (0...59).contains(seconds) else { return false }
        return minutes > 0 || seconds > 0
    }

    private func justifiedTeamName(
        title: String,
        accent: Color,
        colour: Color,
        side: TeamSide,
        alignment: HorizontalAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 5) {
            Text(cleanTeamName(title))
                .font(.system(size: effectiveTeamNameFontSize, weight: layout.teamNameFontWeight.swiftUIFontWeight, design: .rounded))
                .foregroundStyle(colour)
                .lineLimit(2)
                .minimumScaleFactor(0.56)
                .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
                .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
            Rectangle()
                .fill(accent)
                .frame(width: min(44, max(28, teamCellWidth(for: side) * 0.16)), height: 3)
                .clipShape(Capsule())
        }
        .layoutPriority(2)
    }

    private func alignedTeamNameAboveLogo(
        title: String,
        accent: Color,
        colour: Color,
        side: TeamSide
    ) -> some View {
        let alignment = teamNameAlignment(for: side)
        let textAlignment: TextAlignment = alignment == .leading ? .leading : .trailing
        return VStack(alignment: alignment, spacing: 5) {
            Text(cleanTeamName(title))
                .font(.system(size: effectiveTeamNameFontSize, weight: layout.teamNameFontWeight.swiftUIFontWeight, design: .rounded))
                .foregroundStyle(colour)
                .lineLimit(2)
                .minimumScaleFactor(0.56)
                .multilineTextAlignment(textAlignment)
                .frame(
                    minWidth: max(88, min(118, teamCellWidth(for: side) * 0.42)),
                    maxWidth: BroadcastScorebugTemplateMetrics.centredNameMaxWidth(for: layout, teamName: title),
                    alignment: alignment == .leading ? .leading : .trailing
                )
            Rectangle()
                .fill(accent)
                .frame(width: 54, height: 3)
                .clipShape(Capsule())
        }
        .layoutPriority(3)
    }

    private func teamNameAlignment(for side: TeamSide) -> HorizontalAlignment {
        switch BroadcastScorebugTeamNameAlignmentResolver.alignment(
            for: side == .home ? .home : .away
        ) {
        case .leading:
            return .leading
        case .trailing:
            return .trailing
        }
    }

    @ViewBuilder
    private func scoreText(_ score: Int?, side: TeamSide) -> some View {
        let key: OCRRegionKey = side == .home ? .homeScore : .awayScore
        let fallback = score.map { String($0) } ?? "0"

        if imageRelaySnapshot.enabled,
           imageRelaySnapshot.visualValue(for: key) == nil,
           let relayImage = imageRelaySnapshot.image(for: key) {
            // Build 631 failure-safe score path. A material physical score change
            // remains visible even while OCR is unresolved.
            Image(decorative: relayImage, scale: 1)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(width: scoreColumnWidth, height: scoreFontSize * 1.12, alignment: .center)
                .clipped()
                .accessibilityLabel("Score image awaiting recognition")
                .id("score-relay-fallback-\(key.rawValue)-\(imageRelaySnapshot.revision)")
        } else {
            Text(fallback)
                .font(.system(size: scoreFontSize, weight: .black, design: .rounded))
                .foregroundStyle(scoreColour(for: side))
                .monospacedDigit()
                .lineLimit(1)
                // The shared metrics reserve a full two-digit column. Do not scale
                // the score down when it changes from 9 to 10.
                .frame(width: scoreColumnWidth, alignment: .center)
                .id("score-text-\(key.rawValue)-\(imageRelaySnapshot.revision)")
        }
    }

    private func scoreColour(for side: TeamSide) -> Color {
        BroadcastScorebugColourResolver.scoreColour(
            layout: layout,
            side: side == .home ? .home : .away
        )
    }

    private func cleanTeamName(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Team" : trimmed
    }

    private func logoView(logo: UIImage?, accent: Color, logoBackground: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(logoBackground)
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(accent.opacity(0.65), lineWidth: 1))
            if let logo {
                Image(uiImage: logo)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
            } else {
                Image(systemName: "shield.fill")
                    .font(.system(size: logoSize * 0.42, weight: .bold))
                    .foregroundStyle(accent.opacity(0.8))
            }
        }
        .frame(width: logoSize, height: logoSize)
    }

    private var liveBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(BroadcastTheme.liveAccent.opacity(0.82))
                .frame(width: 6, height: 6)
            Text(imageRelayIsActuallyLive ? "IMAGE LIVE" : "OCR LIVE")
                .font(.system(size: 10, weight: .bold, design: .rounded))
        }
        .foregroundStyle(BroadcastTheme.liveAccent.opacity(0.86))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(layout.scoreboardBackgroundColour.opacity(0.46))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(layout.scoreboardBorderColour.opacity(0.30), lineWidth: 1))
    }

    @ViewBuilder
    private var gameSponsorBadge: some View {
        let trimmed = gameSponsorName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            HStack(spacing: BroadcastScorebugTemplateMetrics.gameSponsorGap(for: layout)) {
                if let gameSponsorLogo {
                    Image(uiImage: gameSponsorLogo)
                        .resizable()
                        .scaledToFit()
                        .frame(
                            maxWidth: BroadcastScorebugTemplateMetrics.gameSponsorLogoMaxWidth(for: layout),
                            maxHeight: 25
                        )
                        .clipped()
                        .layoutPriority(5)
                }

                VStack(alignment: .trailing, spacing: 0) {
                    Text("GAME SPONSOR")
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.58))
                    Text(trimmed.uppercased())
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.98))
                        .lineLimit(1)
                        .minimumScaleFactor(0.52)
                }
            }
            .padding(.horizontal, 9)
            .frame(
                height: resolvedMetrics.utilityStripHeight - 2
            )
            .background(layout.scoreboardBackgroundColour.opacity(0.94))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(layout.scoreboardBorderColour.opacity(0.62), lineWidth: 1))
        }
    }

    private var scorebugBackground: some View {
        LinearGradient(
            colors: [
                layout.scoreboardBackgroundColour.opacity(BroadcastScorebugPaintContract.backgroundLeadingOpacity),
                layout.scoreboardBackgroundColour.opacity(BroadcastScorebugPaintContract.backgroundMiddleOpacity),
                BroadcastTheme.glass.opacity(BroadcastScorebugPaintContract.backgroundGlassOpacity)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var scorebugBorder: some View {
        RoundedRectangle(cornerRadius: BroadcastTheme.scorebugCornerRadius, style: .continuous)
            .stroke(
                LinearGradient(
                    colors: [
                        layout.accentColour.opacity(BroadcastScorebugPaintContract.borderLeadingOpacity),
                        layout.scoreboardBorderColour,
                        BroadcastTheme.awayAccent.opacity(BroadcastScorebugPaintContract.borderTrailingOpacity)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1.5
            )
    }
}


// MARK: - UX9 Canonical Broadcast Preview

/// Renders the Settings preview through the same cached compositor used by the
/// Broadcast screen, full-match recording and clips. This deliberately avoids a
/// separate SwiftUI-only preview path so names, logo sizing, opacity and sponsor
/// pills cannot drift between Settings and Broadcast.
struct BroadcastCanonicalOverlayPreview: View {
    let viewerScoreboard: RinkLensViewerScoreboardSnapshot
    let homeLogo: UIImage?
    let awayLogo: UIImage?
    var modeStatusText: String = "Preview"
    var banner: BroadcastEvent? = nil
    var sponsorConfiguration: SponsorCatalogueConfiguration = SponsorCatalogueStore.shared.configuration
    var layout: BroadcastScoreboardLayoutSnapshot = .default
    var visibleVerticalFraction: CGFloat = 1.0

    private var state: ScoreboardState { viewerScoreboard.state }

    @State private var renderedOverlayImage: UIImage? = nil
    @State private var previewRenderTask: Task<Void, Never>?
    @State private var previewRenderInFlight = false
    @State private var queuedPreviewRenderKey: String?

    var body: some View {
        let visibleFraction = min(max(visibleVerticalFraction, 0.24), 1.0)
        GeometryReader { proxy in
            let fullWidth = proxy.size.width
            let fullHeight = fullWidth / BroadcastCompositeStandard.aspectRatio

            ZStack(alignment: .top) {
                LinearGradient(
                    colors: [Color.black.opacity(0.84), Color.blue.opacity(0.18), Color.black.opacity(0.90)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .frame(width: fullWidth, height: fullHeight, alignment: .top)

                if let renderedOverlayImage {
                    Image(uiImage: renderedOverlayImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fullWidth, height: fullHeight, alignment: .top)
                } else {
                    ProgressView()
                        .tint(.white.opacity(0.72))
                        .frame(width: fullWidth, height: fullHeight * visibleFraction)
                }
            }
            .frame(width: fullWidth, height: fullHeight * visibleFraction, alignment: .top)
            .clipped()
        }
        .aspectRatio(BroadcastCompositeStandard.aspectRatio / visibleFraction, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
        .onAppear {
            schedulePreviewRender(immediate: renderedOverlayImage == nil)
        }
        .onChange(of: previewRenderKey) { _, _ in
            // Keep the last complete overlay visible while team-name, logo or
            // colour edits settle. Build 658 cancelled and restarted a full
            // 1920x1080 render on every keystroke, leaving only the background.
            schedulePreviewRender(immediate: false)
        }
        .onDisappear {
            previewRenderTask?.cancel()
            previewRenderTask = nil
            previewRenderInFlight = false
            queuedPreviewRenderKey = nil
        }
    }

    private var previewRenderKey: String {
        [
            layout.overlayCacheKey,
            state.homeTeam ?? "HOME",
            state.awayTeam ?? "GUEST",
            "homeLogo=\(logoIdentity(homeLogo))",
            "awayLogo=\(logoIdentity(awayLogo))",
            state.homeScore.map { String($0) } ?? "0",
            state.awayScore.map { String($0) } ?? "0",
            state.clock ?? "--:--",
            state.periodDisplay,
            modeStatusText,
            banner?.id.uuidString ?? "banner=nil",
            sponsorConfiguration.placements.seasonSponsorID?.uuidString ?? "season=nil",
            sponsorConfiguration.placements.gameSponsorID?.uuidString ?? "game=nil",
            "sponsors=\(sponsorConfiguration.sponsors.count)",
            "relay=\(viewerScoreboard.relayRevision)",
            String(format: "visible=%.2f", Double(visibleVerticalFraction))
        ].joined(separator: "|")
    }

    private func logoIdentity(_ image: UIImage?) -> String {
        guard let image else { return "nil" }
        // UIImage is retained by the ViewModel. Object identity changes when a
        // logo is actually loaded/replaced and avoids expensive pngData() encoding
        // on every SwiftUI body evaluation while the operator types.
        return "\(ObjectIdentifier(image).hashValue):\(Int(image.size.width))x\(Int(image.size.height))"
    }

    private func schedulePreviewRender(immediate: Bool) {
        // Build 682 coalesces Team Font/profile edits without cancelling the
        // active compositor job. Repeated slider updates previously cancelled
        // every render before it completed; if SwiftUI also recreated this view,
        // the operator saw only the coloured background/ProgressView indefinitely.
        queuedPreviewRenderKey = previewRenderKey
        guard !previewRenderInFlight else { return }
        previewRenderInFlight = true
        previewRenderTask = Task { @MainActor in
            var firstPass = true
            while !Task.isCancelled, let requestedKey = queuedPreviewRenderKey {
                queuedPreviewRenderKey = nil
                if !immediate || !firstPass {
                    try? await Task.sleep(nanoseconds: 180_000_000)
                }
                guard !Task.isCancelled else { break }
                firstPass = false

                let image = await renderOverlayImageAsync(viewerScoreboard: viewerScoreboard)
                guard !Task.isCancelled else { break }

                // A completed older request is still a valid full scorebug and is
                // safer than blanking. The queued latest key is rendered next.
                if let image, overlayContainsVisibleContent(image) {
                    renderedOverlayImage = image
                } else if image != nil {
                    MainThreadStallMonitor.shared.traceSponsorOverlay(
                        "Build 682 Settings preview candidate rejected: text/digit evidence missing key=\(requestedKey); retained last complete overlay"
                    )
                }
            }
            previewRenderInFlight = false
            previewRenderTask = nil
            if queuedPreviewRenderKey != nil {
                schedulePreviewRender(immediate: true)
            }
        }
    }

    private func renderOverlayImageAsync(viewerScoreboard: RinkLensViewerScoreboardSnapshot) async -> UIImage? {
        let snapshot = SponsorRecordingOverlaySnapshot(
            isOutputOverlayEnabled: sponsorConfiguration.overlay.isOutputOverlayEnabled,
            leagueEnabled: sponsorConfiguration.overlay.isOutputOverlayEnabled && sponsorConfiguration.league.isEnabled,
            leagueName: sponsorConfiguration.league.name,
            leagueLogoData: sponsorConfiguration.league.logoData,
            seasonSponsorName: resolvedSponsorName(sponsorConfiguration.placements.seasonSponsorID),
            seasonSponsorLogoData: resolvedSponsorLogoData(sponsorConfiguration.placements.seasonSponsorID),
            gameSponsorName: resolvedSponsorName(sponsorConfiguration.placements.gameSponsorID),
            gameSponsorLogoData: resolvedSponsorLogoData(sponsorConfiguration.placements.gameSponsorID)
        )
        return await withCheckedContinuation { continuation in
            BroadcastRecordingOverlayCache.shared.previewOverlayImageAsync(
                // Settings does not need a 1920x1080 raster. The canonical
                // compositor still owns geometry, but a half-size 16:9 target
                // cuts first-entry and edit redraw work by roughly four times.
                outputSize: CGSize(width: 960, height: 540),
                modeStatusText: modeStatusText,
                strengthState: .evenStrength,
                banner: banner,
                homeLogo: homeLogo,
                awayLogo: awayLogo,
                sponsorSnapshot: snapshot,
                overlayMode: .full,
                layout: layout,
                viewerScoreboard: viewerScoreboard
            ) { cgImage in
                continuation.resume(returning: cgImage.map { UIImage(cgImage: $0) })
            }
        }
    }

    private func overlayContainsVisibleContent(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage, cg.width > 32, cg.height > 32 else { return false }
        guard let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return true }
        let length = CFDataGetLength(data)
        let bytesPerPixel = max(1, cg.bitsPerPixel / 8)
        let alphaIndex = bytesPerPixel >= 4 ? 3 : bytesPerPixel - 1

        func luminance(x: Int, y: Int) -> Int? {
            guard x >= 0, y >= 0, x < cg.width, y < cg.height else { return nil }
            let offset = y * cg.bytesPerRow + x * bytesPerPixel
            guard offset + bytesPerPixel <= length else { return nil }
            let alpha = Int(bytes[offset + alphaIndex])
            guard alpha > 16 else { return nil }
            let c0 = Int(bytes[offset])
            let c1 = bytesPerPixel > 1 ? Int(bytes[offset + 1]) : c0
            let c2 = bytesPerPixel > 2 ? Int(bytes[offset + 2]) : c0
            return (c0 * 30 + c1 * 59 + c2 * 11) / 100
        }

        func edgeCount(in normalised: CGRect) -> Int {
            let x0 = max(1, Int(CGFloat(cg.width) * normalised.minX))
            let x1 = min(cg.width - 2, Int(CGFloat(cg.width) * normalised.maxX))
            let y0 = max(1, Int(CGFloat(cg.height) * normalised.minY))
            let y1 = min(cg.height - 2, Int(CGFloat(cg.height) * normalised.maxY))
            guard x1 > x0, y1 > y0 else { return 0 }
            var edges = 0
            for y in Swift.stride(from: y0, through: y1, by: 2) {
                for x in Swift.stride(from: x0, through: x1, by: 2) {
                    guard let l = luminance(x: x, y: y) else { continue }
                    if let right = luminance(x: x + 2, y: y), abs(l - right) >= 34 { edges += 1 }
                    if let below = luminance(x: x, y: y + 2), abs(l - below) >= 34 { edges += 1 }
                }
            }
            return edges
        }

        // The scorebug occupies the top-middle canonical area. Background-only
        // frames still contain large coloured rectangles, so colour spread is not
        // proof of a complete render. Text and digits create dense local edges in
        // the Home, Clock and Away regions. Require evidence in at least two of
        // those three regions before replacing the last complete Settings image.
        let homeEdges = edgeCount(in: CGRect(x: 0.30, y: 0.01, width: 0.14, height: 0.23))
        let clockEdges = edgeCount(in: CGRect(x: 0.44, y: 0.01, width: 0.12, height: 0.23))
        let awayEdges = edgeCount(in: CGRect(x: 0.56, y: 0.01, width: 0.14, height: 0.23))
        let strongRegions = [homeEdges, clockEdges, awayEdges].filter { $0 >= 10 }.count
        return strongRegions >= 2 && homeEdges + clockEdges + awayEdges >= 38
    }

    private func resolvedSponsorName(_ id: UUID?) -> String {
        guard let id, let sponsor = sponsorConfiguration.sponsors.first(where: { $0.id == id && $0.isActive }) else { return "" }
        return sponsor.displayName
    }

    private func resolvedSponsorLogoData(_ id: UUID?) -> Data? {
        guard let id, let sponsor = sponsorConfiguration.sponsors.first(where: { $0.id == id && $0.isActive }) else { return nil }
        return sponsor.logoData
    }
}

/// Shared Image Relay Clock renderer used by the live scorebug and event popups.
/// Both surfaces therefore use the same aspect-fit, template tint, interpolation
/// and zone metrics without introducing a popup-only scale factor.
struct BroadcastImageRelayClockView: View {
    let image: CGImage
    let colour: Color
    let zoneSize: CGSize
    var verticalSafetyInset: CGFloat = 0

    var body: some View {
        let safeZoneSize = CGSize(
            width: zoneSize.width,
            height: max(1, zoneSize.height - verticalSafetyInset * 2)
        )
        let placement = BroadcastScorebugGlyphLayoutResolver.placement(
            kind: .clock,
            // The producer already publishes a fixed transparent Clock canvas.
            // Measuring alpha bounds again on every frame made the Clock pulse
            // and flash larger after Broadcast remount.
            sourceSize: CGSize(width: image.width, height: image.height),
            availableSize: safeZoneSize,
            targetVisibleHeight: safeZoneSize.height
        )
        Image(decorative: image, scale: 1, orientation: .up)
            .resizable()
            .renderingMode(.template)
            .interpolation(.none)
            .scaledToFit()
            .foregroundStyle(colour)
            .frame(width: placement.frameSize.width, height: placement.frameSize.height)
            .frame(width: zoneSize.width, height: zoneSize.height)
            .compositingGroup()
            .transaction { transaction in
                transaction.animation = nil
            }
            .accessibilityHidden(true)
    }
}


#endif
