// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import UIKit

// MARK: - Streamlined penalty / strength event banner

struct PenaltyBannerView: View {
    let event: BroadcastEvent
    let homeLogo: UIImage?
    let awayLogo: UIImage?
    var homeTeamName: String = "HOME"
    var awayTeamName: String = "AWAY"
    var useActualTeamNames: Bool = false
    var teamLogosEnabled: Bool = true

    @State private var isVisible = false

    var body: some View {
        Group {
            if isStrengthEvent {
                strengthBanner
            } else {
                penaltyBanner
            }
        }
        .opacity(isVisible ? 1.0 : 0.0)
        .onAppear {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                isVisible = true
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var penaltyBanner: some View {
        HStack(spacing: 14) {
            teamBadge(size: BroadcastEventPopupTemplateMetrics.penaltyBadgeSize)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(event.popupTitle.uppercased())
                        .font(.system(size: 20, weight: .black, design: .rounded))
                        .tracking(1.0)
                        .foregroundStyle(BroadcastTheme.penaltyAccent)
                    Text(teamLabel)
                        .font(.system(size: 24, weight: .black, design: .rounded))
                        .foregroundStyle(strengthAccent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.70)
                }

                if let sponsor = event.sponsor {
                    penaltySponsorCard(sponsor)
                }
            }

            Spacer(minLength: 10)

            VStack(alignment: .trailing, spacing: 2) {
                HStack(alignment: .center, spacing: 8) {
                    if let playerName = recognisedPlayerName {
                        Text(playerName)
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                            .foregroundStyle(BroadcastTheme.clockAccent)
                            .lineLimit(1)
                            .minimumScaleFactor(0.62)
                            .frame(maxWidth: 150, alignment: .trailing)
                    }
                    playerPresentation
                    if let penaltyTimeText {
                        Text(penaltyTimeText)
                            .font(.system(size: 20, weight: .black, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(BroadcastTheme.primaryText)
                            .frame(minWidth: 74, alignment: .trailing)
                    }
                }
                .frame(height: 38, alignment: .trailing)

                BroadcastEventClockPresentationView(
                    event: event,
                    fallbackText: event.gameClock ?? "",
                    fallbackFontSize: 20,
                    textColour: BroadcastTheme.secondaryText,
                    periodFontSize: 0,
                    showsPeriod: false
                )
                .frame(width: 142, height: 34, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(
            width: BroadcastEventPopupTemplateMetrics.penaltyWidth,
            height: BroadcastEventPopupTemplateMetrics.penaltyHeight
        )
        .background(background(accent: BroadcastTheme.penaltyAccent))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(border(accent: BroadcastTheme.penaltyAccent, cornerRadius: 20))
        .shadow(color: BroadcastTheme.penaltyAccent.opacity(0.34), radius: 16, x: 0, y: 8)
    }

    private var strengthBanner: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(strengthAccent.opacity(0.20))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(strengthAccent.opacity(0.78), lineWidth: 1.5)
                    )
                Image(systemName: event.type == .timeoutStart ? "timer" : (event.type == .timeoutEnd ? "play.fill" : "person.3.fill"))
                    .font(.system(size: 25, weight: .black))
                    .foregroundStyle(strengthAccent)
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.popupTitle.uppercased())
                    .font(.system(size: 16, weight: .black, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(BroadcastTheme.penaltyAccent)
                Text(strengthSummary)
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundStyle(BroadcastTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: BroadcastEventPopupTemplateMetrics.strengthWidth)
        .background(background(accent: strengthAccent))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(border(accent: strengthAccent, cornerRadius: 20))
        .shadow(color: strengthAccent.opacity(0.30), radius: 14, x: 0, y: 7)
    }

    @ViewBuilder
    private var playerPresentation: some View {
        if prefersFrozenPenaltyPlayerImage, let frozenPenaltyPlayerImage {
            frozenPenaltyPlayerView(frozenPenaltyPlayerImage)
        } else if let playerNumber = displayedPenaltyPlayerNumber {
            Text("#\(playerNumber)")
                .font(.system(size: 34, weight: .black, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(BroadcastTheme.clockAccent)
                .lineLimit(1)
                .minimumScaleFactor(0.80)
                .accessibilityLabel("Penalty player number \(playerNumber)")
        } else if let frozenPenaltyPlayerImage {
            frozenPenaltyPlayerView(frozenPenaltyPlayerImage)
        }
    }

    private var isStrengthEvent: Bool {
        [.powerPlayStart, .penaltyEnd, .timeoutStart, .timeoutEnd].contains(event.type)
    }

    private var frozenPenaltyPlayerImage: UIImage? {
        guard let data = event.frozenPenaltyPlayerImagePNGData else { return nil }
        return UIImage(data: data)
    }

    private var prefersFrozenPenaltyPlayerImage: Bool {
        event.team == .away && frozenPenaltyPlayerImage != nil
    }

    private var displayedPenaltyPlayerNumber: Int? {
        prefersFrozenPenaltyPlayerImage ? nil : event.recognisedPenaltyPlayerNumber
    }

    private var recognisedPlayerName: String? {
        guard let value = event.recognisedHomePlayerName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value.uppercased()
    }

    private var penaltyTimeText: String? {
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

    private var strengthSummary: String {
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

    private func frozenPenaltyPlayerView(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: 78, height: 30)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(BroadcastTheme.clockAccent.opacity(0.38), lineWidth: 1)
            )
            .accessibilityLabel("Penalty player number from saved Image Relay event")
    }

    private var teamLabel: String {
        displayName(for: event.team)
    }

    private func displayName(for team: Team?) -> String {
        guard useActualTeamNames else { return team?.displayName ?? "TEAM" }
        switch team {
        case .home:
            return cleanTeamName(homeTeamName, fallback: "HOME")
        case .away:
            return cleanTeamName(awayTeamName, fallback: "AWAY")
        case .none:
            return "TEAM"
        }
    }

    private func cleanTeamName(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed.uppercased()
    }

    private var logo: UIImage? {
        guard teamLogosEnabled else { return nil }
        switch event.team {
        case .home: return homeLogo
        case .away: return awayLogo
        case .none: return nil
        }
    }

    private var strengthAccent: Color {
        switch event.team {
        case .home: return BroadcastTheme.homeAccent
        case .away: return BroadcastTheme.awayAccent
        case .none: return BroadcastTheme.clockAccent
        }
    }

    private func penaltySponsorCard(_ sponsor: SponsorResolvedBroadcastSponsor) -> some View {
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
                .fill(BroadcastTheme.penaltyAccent.opacity(0.16))
                .overlay(Circle().stroke(BroadcastTheme.penaltyAccent.opacity(0.82), lineWidth: 1.5))

            if let logo {
                Image(uiImage: logo)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 23, weight: .heavy))
                    .foregroundStyle(BroadcastTheme.penaltyAccent)
            }
        }
        .frame(width: size, height: size)
    }

    private func background(accent: Color) -> some View {
        LinearGradient(
            colors: [BroadcastTheme.glassStrong, BroadcastTheme.panel.opacity(0.96), accent.opacity(0.16)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func border(accent: Color, cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
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
