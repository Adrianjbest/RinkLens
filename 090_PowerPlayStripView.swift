// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import UIKit

// MARK: - Build 532 Scorebug-Attached Strength Rail

/// Persistent manpower state shown as a compact extension of the scorebug.
/// This rail deliberately excludes player numbers: the transient penalty popup
/// remains the authoritative announcement for the penalised player and event time.
struct PowerPlayStripView: View {
    let strengthState: StrengthState
    let activePenaltyClocks: [PenaltyClock]
    let homeLogo: UIImage?
    let awayLogo: UIImage?
    let layout: BroadcastScoreboardLayoutSnapshot

    var body: some View {
        if strengthState.isPubliclyVisible {
            HStack(spacing: 10) {
                Capsule()
                    .fill(accent)
                    .frame(width: 5, height: 24)

                Text(strengthState.broadcastRailTitle)
                    .font(.system(size: 17, weight: .black, design: .rounded))
                    .tracking(0.45)
                    .foregroundStyle(BroadcastTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Spacer(minLength: 8)

                if !strengthState.broadcastRailAdvantage.isEmpty {
                    Text(strengthState.broadcastRailAdvantage)
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                }

                if !clockText.isEmpty {
                    Text(clockText)
                        .font(.system(size: 18, weight: .black, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(BroadcastTheme.clockAccent)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .frame(width: BroadcastTheme.scorebugWidth * 0.86, height: 42)
            .background(railBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(accent.opacity(0.72), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.30), radius: 7, x: 0, y: 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var accent: Color {
        switch strengthState.broadcastRailAccentTeam {
        case .home:
            return layout.useSharedScoreColour ? layout.scoreColour : layout.homeScoreColour
        case .away:
            return layout.useSharedScoreColour ? layout.scoreColour : layout.awayScoreColour
        case nil:
            return layout.accentColour
        }
    }

    private var clockText: String {
        let direct = strengthState.broadcastRailClockText
        if !direct.isEmpty { return direct }
        return activePenaltyClocks
            .filter(\.isActive)
            .sortedForStrengthRail
            .first?
            .displayClock ?? ""
    }

    private var railBackground: some View {
        LinearGradient(
            colors: [
                layout.scoreboardBackgroundColour.opacity(0.98),
                layout.scoreboardBackgroundColour.opacity(0.92),
                accent.opacity(0.14)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var accessibilityText: String {
        [strengthState.broadcastRailTitle, strengthState.broadcastRailAdvantage, clockText]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

private extension Array where Element == PenaltyClock {
    var sortedForStrengthRail: [PenaltyClock] {
        sorted {
            if $0.team.rawValue != $1.team.rawValue { return $0.team.rawValue < $1.team.rawValue }
            if $0.slot != $1.slot { return $0.slot < $1.slot }
            return ($0.remainingSeconds ?? 0) > ($1.remainingSeconds ?? 0)
        }
    }
}

#endif
