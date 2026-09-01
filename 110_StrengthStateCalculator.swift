// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation

// MARK: - Phase 3 Strength State Calculator

/// Converts accepted scoreboard penalty clocks into viewer-safe strength state.
/// The public stream should render the calculated state, not the raw penalty boxes.
enum StrengthStateCalculator {
    static func penaltyClocks(from state: ScoreboardState) -> [PenaltyClock] {
        [
            PenaltyClock(team: .home, slot: 1, playerNumber: state.homePenalty1Player, rawClock: state.homePenalty1Clock, remainingSeconds: seconds(from: state.homePenalty1Clock)),
            PenaltyClock(team: .home, slot: 2, playerNumber: state.homePenalty2Player, rawClock: state.homePenalty2Clock, remainingSeconds: seconds(from: state.homePenalty2Clock)),
            PenaltyClock(team: .away, slot: 1, playerNumber: state.awayPenalty1Player, rawClock: state.awayPenalty1Clock, remainingSeconds: seconds(from: state.awayPenalty1Clock)),
            PenaltyClock(team: .away, slot: 2, playerNumber: state.awayPenalty2Player, rawClock: state.awayPenalty2Clock, remainingSeconds: seconds(from: state.awayPenalty2Clock))
        ]
    }

    static func activePenaltyClocks(from state: ScoreboardState) -> [PenaltyClock] {
        penaltyClocks(from: state).filter(\.isActive)
    }

    static func strengthState(from state: ScoreboardState) -> StrengthState {
        strengthState(from: activePenaltyClocks(from: state))
    }

    static func strengthState(from activeClocks: [PenaltyClock]) -> StrengthState {
        let home = activeClocks
            .filter { $0.team == .home && $0.isActive }
            .sorted { ($0.remainingSeconds ?? 0) > ($1.remainingSeconds ?? 0) }
        let away = activeClocks
            .filter { $0.team == .away && $0.isActive }
            .sorted { ($0.remainingSeconds ?? 0) > ($1.remainingSeconds ?? 0) }

        if home.isEmpty && away.isEmpty { return .evenStrength }

        // v0.8.1.7u: full manpower matrix. Do not offset matching penalties before
        // calculating displayed skaters. The scoreboard has up to two active slots
        // per team, so each active penalty reduces that team by one skater down
        // to the hockey minimum of 3.
        // Examples:
        //   HOME 0, AWAY 0 -> 5-on-5 (hidden)
        //   HOME 1, AWAY 0 -> AWAY POWER PLAY 5-on-4
        //   HOME 2, AWAY 0 -> AWAY POWER PLAY 5-on-3
        //   HOME 1, AWAY 1 -> 4-on-4 (not power play)
        //   HOME 2, AWAY 1 -> AWAY POWER PLAY 4-on-3
        //   HOME 2, AWAY 2 -> 3-on-3 (not power play)
        let homeSkaters = skaterCount(activePenalties: home.count)
        let awaySkaters = skaterCount(activePenalties: away.count)

        if homeSkaters == awaySkaters {
            if homeSkaters == 3 { return .threeOnThree }
            if homeSkaters == 4 { return .fourOnFour }
            return .evenStrength
        }

        if homeSkaters < awaySkaters {
            let penalisingClocks = home
            if homeSkaters == 3, awaySkaters == 5, penalisingClocks.count >= 2 {
                return .fiveOnThree(
                    team: .away,
                    secondsOne: penalisingClocks[0].remainingSeconds ?? 0,
                    secondsTwo: penalisingClocks[1].remainingSeconds ?? 0
                )
            }
            return .awayPowerPlay(
                seconds: penalisingClocks.first?.remainingSeconds ?? 0,
                advantage: advantageLabel(advantagedSkaters: awaySkaters, shorthandedSkaters: homeSkaters)
            )
        }

        let penalisingClocks = away
        if awaySkaters == 3, homeSkaters == 5, penalisingClocks.count >= 2 {
            return .fiveOnThree(
                team: .home,
                secondsOne: penalisingClocks[0].remainingSeconds ?? 0,
                secondsTwo: penalisingClocks[1].remainingSeconds ?? 0
            )
        }
        return .homePowerPlay(
            seconds: penalisingClocks.first?.remainingSeconds ?? 0,
            advantage: advantageLabel(advantagedSkaters: homeSkaters, shorthandedSkaters: awaySkaters)
        )
    }

    static func signature(for activeClocks: [PenaltyClock]) -> String {
        activeClocks
            .filter(\.isActive)
            .map { "\($0.team.rawValue)-\($0.slot)-\($0.playerNumber ?? 0)" }
            .sorted()
            .joined(separator: "|")
    }

    static func displayClock(seconds: Int) -> String {
        guard seconds > 0 else { return "--:--" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private static func seconds(from clock: String?) -> Int? {
        guard let clock else { return nil }
        let trimmed = clock.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != "--:--", !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":")
        guard parts.count == 2, let minutes = Int(parts[0]), let seconds = Int(parts[1]) else { return nil }
        guard (0...10).contains(minutes), (0...59).contains(seconds) else { return nil }
        let total = minutes * 60 + seconds
        guard total > 0 else { return nil }
        return total
    }

    private static func skaterCount(activePenalties: Int) -> Int {
        max(3, 5 - min(activePenalties, 2))
    }

    private static func advantageLabel(advantagedSkaters: Int, shorthandedSkaters: Int) -> String {
        "\(advantagedSkaters)-on-\(shorthandedSkaters)"
    }
}

extension StrengthState {
    var advantagedTeam: Team? {
        switch self {
        case .homePowerPlay: return .home
        case .awayPowerPlay: return .away
        case .fiveOnThree(let team, _, _): return team
        default: return nil
        }
    }

    var isPowerPlay: Bool {
        switch self {
        case .homePowerPlay, .awayPowerPlay, .fiveOnThree:
            return true
        default:
            return false
        }
    }

    var isPubliclyVisible: Bool {
        switch self {
        case .evenStrength, .unknown:
            return false
        default:
            return true
        }
    }

    var headline: String {
        switch self {
        case .homePowerPlay: return "HOME POWER PLAY"
        case .awayPowerPlay: return "AWAY POWER PLAY"
        case .fiveOnThree(let team, _, _): return "\(team.displayName) POWER PLAY 5-on-3"
        case .fourOnFour: return "4-on-4"
        case .threeOnThree: return "3-on-3"
        case .evenStrength: return "EVEN STRENGTH"
        case .unknown: return "POWER PLAY"
        }
    }

    var detail: String {
        switch self {
        case .homePowerPlay(let seconds, let advantage), .awayPowerPlay(let seconds, let advantage):
            return "\(StrengthStateCalculator.displayClock(seconds: seconds))   \(advantage)"
        case .fiveOnThree(_, let first, let second):
            return "\(StrengthStateCalculator.displayClock(seconds: first)) / \(StrengthStateCalculator.displayClock(seconds: second))"
        case .fourOnFour:
            return "Penalty balance active"
        case .threeOnThree:
            return "Double penalty balance active"
        case .evenStrength:
            return "No active penalties"
        case .unknown:
            return "Verify penalty clocks"
        }
    }

    var remainingSeconds: Int? {
        switch self {
        case .homePowerPlay(let seconds, _), .awayPowerPlay(let seconds, _): return seconds
        case .fiveOnThree(_, let first, _): return first
        default: return nil
        }
    }

    /// Build 532: one compact strength-rail contract is shared by the SwiftUI
    /// preview and the canonical PixelBuffer compositor. The persistent rail
    /// communicates current manpower only; player numbers remain exclusive to
    /// the transient penalty popup.


    /// UX16d18: compact home-versus-away manpower shown inside the centre
    /// scorebug cell. Values are always ordered HOME v AWAY so the viewer does
    /// not have to interpret which team owns a separate power-play banner.
    var scorebugManpowerText: String {
        switch self {
        case .evenStrength:
            return "5v5"
        case .homePowerPlay(_, let advantage):
            let parts = advantage.lowercased().components(separatedBy: "-on-")
            if parts.count == 2 { return "\(parts[0])v\(parts[1])" }
            return "5v4"
        case .awayPowerPlay(_, let advantage):
            let parts = advantage.lowercased().components(separatedBy: "-on-")
            if parts.count == 2 { return "\(parts[1])v\(parts[0])" }
            return "4v5"
        case .fourOnFour:
            return "4v4"
        case .threeOnThree:
            return "3v3"
        case .fiveOnThree(let team, _, _):
            return team == .home ? "5v3" : "3v5"
        case .unknown:
            return "—v—"
        }
    }
    var broadcastRailTitle: String {
        switch self {
        case .homePowerPlay: return "HOME POWER PLAY"
        case .awayPowerPlay: return "AWAY POWER PLAY"
        case .fiveOnThree(let team, _, _): return "\(team.displayName.uppercased()) POWER PLAY"
        case .fourOnFour: return "4-ON-4"
        case .threeOnThree: return "3-ON-3"
        case .evenStrength: return "EVEN STRENGTH"
        case .unknown: return "POWER PLAY"
        }
    }

    var broadcastRailAdvantage: String {
        switch self {
        case .homePowerPlay(_, let advantage), .awayPowerPlay(_, let advantage):
            return advantage.uppercased()
        case .fiveOnThree:
            return "5-ON-3"
        default:
            return ""
        }
    }

    var broadcastRailClockText: String {
        switch self {
        case .homePowerPlay(let seconds, _), .awayPowerPlay(let seconds, _):
            return StrengthStateCalculator.displayClock(seconds: seconds)
        case .fiveOnThree(_, let first, let second):
            return "\(StrengthStateCalculator.displayClock(seconds: first)) / \(StrengthStateCalculator.displayClock(seconds: second))"
        default:
            return ""
        }
    }

    var broadcastRailAccentTeam: Team? {
        switch self {
        case .homePowerPlay: return .home
        case .awayPowerPlay: return .away
        case .fiveOnThree(let team, _, _): return team
        default: return nil
        }
    }
}

#endif
