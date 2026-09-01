// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import UIKit

// MARK: - Slim goal popup aligned to penalty popup metrics

struct GoalBannerView: View {
    let event: BroadcastEvent
    let homeLogo: UIImage?
    let awayLogo: UIImage?
    var homeTeamName: String = "HOME"
    var awayTeamName: String = "AWAY"
    var useActualTeamNames: Bool = false
    var teamLogosEnabled: Bool = true

    @State private var isVisible = false

    var body: some View {
        HStack(spacing: 14) {
            teamBadge(size: BroadcastEventPopupTemplateMetrics.badgeSize)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(event.popupTitle)
                        .font(.system(size: BroadcastEventPopupTemplateMetrics.goalTitleFont, weight: .black, design: .rounded))
                        .tracking(1.0)
                        .foregroundStyle(BroadcastTheme.primaryText)
                    Text(teamLabel)
                        .font(.system(size: BroadcastEventPopupTemplateMetrics.goalTeamFont, weight: .black, design: .rounded))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                if let sponsor = event.sponsor {
                    sponsorCard(sponsor)
                } else if event.isImageRelayCue {
                    Text("SCORE SHOWN LIVE FROM SCOREBOARD IMAGE")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(BroadcastTheme.secondaryText)
                } else {
                    Text("Score now \(scoreLine)")
                        .font(.system(size: BroadcastEventPopupTemplateMetrics.goalScoreFont, weight: .bold, design: .rounded))
                        .foregroundStyle(BroadcastTheme.secondaryText)
                        .monospacedDigit()
                }
            }

            Spacer(minLength: 10)

            VStack(alignment: .trailing, spacing: 4) {
                Image(systemName: "hockey.puck.fill")
                    .font(.system(size: 22, weight: .black))
                    .foregroundStyle(accent)
                    .shadow(color: accent.opacity(0.55), radius: 6)

                BroadcastEventClockPresentationView(
                    event: event,
                    fallbackText: event.isImageRelayCue ? "IMAGE RELAY" : event.periodClockLine,
                    fallbackFontSize: 20,
                    textColour: BroadcastTheme.clockAccent,
                    periodFontSize: 0,
                    showsPeriod: false
                )
                .frame(minWidth: 142, minHeight: 44, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: BroadcastEventPopupTemplateMetrics.goalWidth)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(border)
        .shadow(color: accent.opacity(0.34), radius: 16, x: 0, y: 8)
        .opacity(isVisible ? 1.0 : 0.0)
        .onAppear {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                isVisible = true
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var teamLabel: String { displayName(for: event.team) }

    private var scoreLine: String {
        let home = displayName(for: .home)
        let away = displayName(for: .away)
        return "\(home) \(event.homeScoreAfter.map { String($0) } ?? "-") - \(away) \(event.awayScoreAfter.map { String($0) } ?? "-")"
    }

    private func displayName(for team: Team?) -> String {
        guard useActualTeamNames else { return team?.displayName ?? "TEAM" }
        switch team {
        case .home: return cleanTeamName(homeTeamName, fallback: "HOME")
        case .away: return cleanTeamName(awayTeamName, fallback: "AWAY")
        case .none: return "TEAM"
        }
    }

    private func cleanTeamName(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed.uppercased()
    }

    private var accent: Color {
        event.team == .away ? BroadcastTheme.awayAccent : BroadcastTheme.homeAccent
    }

    private var logo: UIImage? {
        guard teamLogosEnabled else { return nil }
        return event.team == .away ? awayLogo : homeLogo
    }

    private func sponsorCard(_ sponsor: SponsorResolvedBroadcastSponsor) -> some View {
        HStack(spacing: 6) {
            if let logoData = sponsor.logoData, let image = UIImage(data: logoData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 19)
                    .padding(3)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(sponsor.subtitle)
                    .font(.system(size: 8, weight: .black, design: .rounded))
                    .foregroundStyle(BroadcastTheme.secondaryText.opacity(0.76))
                    .lineLimit(1)
                Text(sponsor.displayTitle)
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(BroadcastTheme.primaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }

    private func teamBadge(size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(accent.opacity(0.18))
                .overlay(Circle().stroke(accent.opacity(0.85), lineWidth: 1.5))
            if let logo {
                Image(uiImage: logo)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            } else {
                Text(teamLabel.prefix(1))
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(accent)
            }
        }
        .frame(width: size, height: size)
    }

    private var background: some View {
        LinearGradient(
            colors: [BroadcastTheme.glassStrong, BroadcastTheme.panel.opacity(0.96), accent.opacity(0.16)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(
                LinearGradient(
                    colors: [accent.opacity(0.90), .white.opacity(0.18), BroadcastTheme.clockAccent.opacity(0.56)],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                lineWidth: 1.4
            )
    }
}

#endif
