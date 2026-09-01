// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import AVFoundation
import Vision
import CoreMedia
import CoreGraphics
import PhotosUI
import Foundation
#if canImport(MLKitVision) && canImport(MLKitTextRecognition) && canImport(MLKitTextRecognitionLatin)
import MLKitVision
import MLKitTextRecognition
import MLKitTextRecognitionLatin
#endif

struct CompactLiveScoreboardBanner: View {
    let state: ScoreboardState
    let homeLogo: UIImage?
    let awayLogo: UIImage?
    var showClockShotsAndPenalties: Bool = true

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            teamColumn(
                title: state.homeTeam ?? "HOME",
                logo: homeLogo,
                score: state.homeScore,
                p1Player: state.homePenalty1Player,
                p1Time: state.homePenalty1Clock,
                p2Player: state.homePenalty2Player,
                p2Time: state.homePenalty2Clock,
                alignment: .leading
            )

            VStack(spacing: 2) {
                if showClockShotsAndPenalties {
                    Text(state.clock ?? "--:--")
                        .font(.headline.monospacedDigit())
                }
                Text(state.periodDisplay)
                    .font(.caption.bold())
            }
            .frame(minWidth: showClockShotsAndPenalties ? 86 : 62)

            teamColumn(
                title: state.awayTeam ?? "GUEST",
                logo: awayLogo,
                score: state.awayScore,
                p1Player: state.awayPenalty1Player,
                p1Time: state.awayPenalty1Clock,
                p2Player: state.awayPenalty2Player,
                p2Time: state.awayPenalty2Clock,
                alignment: .trailing
            )
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: showClockShotsAndPenalties ? 520 : 420)
    }

    private func teamColumn(
        title: String,
        logo: UIImage?,
        score: Int?,
        p1Player: Int?,
        p1Time: String?,
        p2Player: Int?,
        p2Time: String?,
        alignment: HorizontalAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            HStack(spacing: 6) {
                if alignment == .leading { logoView(logo) }
                Text(title)
                    .font(.caption.bold())
                if alignment == .trailing { logoView(logo) }
            }
            Text("Score \(score.map { String($0) } ?? "-")")
                .font(.caption2.monospacedDigit().weight(.semibold))
            if showClockShotsAndPenalties {
                compactPenaltyStrip(
                    entries: [(p1Player, p1Time), (p2Player, p2Time)]
                )
                .padding(.top, 1)
            }
        }
        .frame(minWidth: 160, alignment: alignment == .leading ? .leading : .trailing)
    }

    @ViewBuilder
    private func logoView(_ image: UIImage?) -> some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        } else {
            RoundedRectangle(cornerRadius: 5)
                .fill(.white.opacity(0.15))
                .frame(width: 24, height: 24)
        }
    }

    private func compactPenaltyStrip(entries: [(Int?, String?)]) -> some View {
        let active = entries.compactMap { player, time -> (Int?, String)? in
            guard let time, time != "0:00", time != "00:00" else { return nil }
            return (player, time)
        }
        return HStack(spacing: 2) {
            Text("PENALTY")
                .font(.system(size: 9, weight: .black, design: .rounded))
                .minimumScaleFactor(0.65)
                .frame(width: 43)
            compactPenaltySlot(active.indices.contains(0) ? active[0] : nil)
            compactPenaltySlot(active.indices.contains(1) ? active[1] : nil)
        }
    }

    private func compactPenaltySlot(_ entry: (Int?, String)?) -> some View {
        HStack(spacing: 2) {
            Text(entry?.0.map { "#\($0)" } ?? "")
            Text(entry?.1 ?? "").monospacedDigit()
        }
        .font(.system(size: 13, weight: .black, design: .rounded))
        .lineLimit(1)
        .minimumScaleFactor(0.70)
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, minHeight: 18)
        .background(.white.opacity(entry == nil ? 0.05 : 0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}

#endif
