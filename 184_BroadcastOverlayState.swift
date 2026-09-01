// BUILD 699 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import UIKit
import Foundation


// MARK: - Build 699 authoritative viewer scoreboard snapshot

/// The only complete scoreboard payload permitted to reach live Broadcast,
/// recording, clips or Settings preview. Image Relay is an input candidate; its
/// immutable physical payload is frozen here together with the resolved public
/// state and exact source map. Renderers must not query input stores directly.
struct RinkLensViewerScoreboardSnapshot: @unchecked Sendable {
    var state: ScoreboardState
    var relay: ScoreboardImageRelaySnapshot
    var fieldSources: [String: String]

    static let empty = RinkLensViewerScoreboardSnapshot(
        state: ScoreboardState(),
        relay: .disabled,
        fieldSources: [:]
    )

    static func acceptedOnly(state: ScoreboardState, source: String = "acceptedMatchState") -> RinkLensViewerScoreboardSnapshot {
        RinkLensViewerScoreboardSnapshot(
            state: state,
            relay: .disabled,
            fieldSources: Dictionary(uniqueKeysWithValues: [
                "homeTeam", "awayTeam", "clock", "homeScore", "awayScore", "period",
                "homePenalty1", "homePenalty2", "awayPenalty1", "awayPenalty2", "strength"
            ].map { ($0, source) })
        )
    }

    var relayRevision: UInt64 { relay.enabled ? relay.revision : 0 }

    /// Pixel-relevant identity only. Raw relay revision remains available for
    /// diagnostics, but it cannot invalidate a completed overlay unless the
    /// visible value/image hash, occupancy, generation or accepted state changed.
    var penaltyMaterialIdentity: String {
        [
            "hp1=\(visibleDescriptor(for: "homePenalty1"))",
            "hp2=\(visibleDescriptor(for: "homePenalty2"))",
            "ap1=\(visibleDescriptor(for: "awayPenalty1"))",
            "ap2=\(visibleDescriptor(for: "awayPenalty2"))"
        ].joined(separator: "|")
    }

    var materialRenderIdentity: String {
        [
            "generation=\(relay.captureGeneration)",
            "clock=\(visibleDescriptor(for: "clock"))",
            "home=\(visibleDescriptor(for: "homeScore"))",
            "away=\(visibleDescriptor(for: "awayScore"))",
            "period=\(visibleDescriptor(for: "period"))",
            "hp1=\(visibleDescriptor(for: "homePenalty1"))",
            "hp2=\(visibleDescriptor(for: "homePenalty2"))",
            "ap1=\(visibleDescriptor(for: "awayPenalty1"))",
            "ap2=\(visibleDescriptor(for: "awayPenalty2"))",
            "strength=\(visibleDescriptor(for: "strength"))"
        ].joined(separator: "|")
    }

    var renderIdentity: String {
        if RinkLensRiskFeaturePolicy.isEnabled(.materialOverlayChangeOnlyV25) {
            return materialRenderIdentity
        }
        return "relay=\(relayRevision)|\(materialRenderIdentity)"
    }

    func source(for field: String) -> String {
        if relay.enabled {
            switch field {
            case "clock":
                if relay.visualValue(for: .clock) != nil { return "imageRelayPhysicalValue" }
                if relay.image(for: .clock) != nil { return "imageRelayPhysicalImage" }
            case "homeScore":
                if relay.visualValue(for: .homeScore) != nil { return "imageRelayPhysicalValue" }
                if relay.image(for: .homeScore) != nil { return "imageRelayPhysicalImage" }
            case "awayScore":
                if relay.visualValue(for: .awayScore) != nil { return "imageRelayPhysicalValue" }
                if relay.image(for: .awayScore) != nil { return "imageRelayPhysicalImage" }
            case "period":
                if relay.visualValue(for: .period) != nil { return "imageRelayPhysicalValue" }
                if relay.image(for: .period) != nil { return "imageRelayPhysicalImage" }
            case "homePenalty1": if relay.penaltySlotIsConfirmedOccupied(.homePenalty1Player) { return "imageRelayPhysicalPair" }
            case "homePenalty2": if relay.penaltySlotIsConfirmedOccupied(.homePenalty2Player) { return "imageRelayPhysicalPair" }
            case "awayPenalty1": if relay.penaltySlotIsConfirmedOccupied(.awayPenalty1Player) { return "imageRelayPhysicalPair" }
            case "awayPenalty2": if relay.penaltySlotIsConfirmedOccupied(.awayPenalty2Player) { return "imageRelayPhysicalPair" }
            case "strength": if relay.hasRetainedPresentation { return "imageRelayPhysicalManpower" }
            default: break
            }
        }
        return fieldSources[field] ?? "acceptedMatchState"
    }

    func visibleDescriptor(for field: String) -> String {
        switch field {
        case "homeTeam": return state.homeTeam ?? "none"
        case "awayTeam": return state.awayTeam ?? "none"
        case "clock": return relayDescriptor(.clock, fallback: state.clock ?? "none")
        case "homeScore": return relayDescriptor(.homeScore, fallback: state.homeScore.map { String($0) } ?? "none")
        case "awayScore": return relayDescriptor(.awayScore, fallback: state.awayScore.map { String($0) } ?? "none")
        case "period": return relayDescriptor(.period, fallback: state.periodDisplay)
        case "homePenalty1": return penaltyDescriptor(player: .homePenalty1Player, timer: .homePenalty1Time, fallbackPlayer: state.homePenalty1Player, fallbackClock: state.homePenalty1Clock)
        case "homePenalty2": return penaltyDescriptor(player: .homePenalty2Player, timer: .homePenalty2Time, fallbackPlayer: state.homePenalty2Player, fallbackClock: state.homePenalty2Clock)
        case "awayPenalty1": return penaltyDescriptor(player: .awayPenalty1Player, timer: .awayPenalty1Time, fallbackPlayer: state.awayPenalty1Player, fallbackClock: state.awayPenalty1Clock)
        case "awayPenalty2": return penaltyDescriptor(player: .awayPenalty2Player, timer: .awayPenalty2Time, fallbackPlayer: state.awayPenalty2Player, fallbackClock: state.awayPenalty2Clock)
        case "strength": return relay.enabled && relay.hasRetainedPresentation ? relay.visualManpowerText : "accepted"
        default: return "none"
        }
    }

    private func relayDescriptor(_ key: OCRRegionKey, fallback: String) -> String {
        guard relay.enabled else { return fallback }
        if let value = relay.visualValue(for: key) { return value }
        if relay.image(for: key) != nil { return "image#\(relay.fieldHashes[key].map { String($0) } ?? "unhashed")" }
        return fallback
    }

    private func penaltyDescriptor(
        player: OCRRegionKey,
        timer: OCRRegionKey,
        fallbackPlayer: Int?,
        fallbackClock: String?
    ) -> String {
        guard relay.enabled, relay.penaltySlotIsConfirmedOccupied(player) else {
            return "player=\(fallbackPlayer.map { String($0) } ?? "none"),timer=\(fallbackClock ?? "none")"
        }
        let playerValue = relay.visualValue(for: player)
            ?? relay.fieldHashes[player].map { "image#\($0)" }
            ?? "image"
        let timerValue = relay.visualValue(for: timer)
            ?? relay.fieldHashes[timer].map { "image#\($0)" }
            ?? "image"
        return "player=\(playerValue),timer=\(timerValue)"
    }

    func isMateriallyEqual(to other: RinkLensViewerScoreboardSnapshot) -> Bool {
        let materialEqual = state == other.state
            && relay.enabled == other.relay.enabled
            && relay.processingEnabled == other.relay.processingEnabled
            && relay.captureGeneration == other.relay.captureGeneration
            && relay.visualFieldValues == other.relay.visualFieldValues
            && relay.fieldHashes == other.relay.fieldHashes
            && relay.confirmedPenaltyPlayerKeys == other.relay.confirmedPenaltyPlayerKeys
            && fieldSources == other.fieldSources
        guard RinkLensRiskFeaturePolicy.isEnabled(.materialOverlayChangeOnlyV25) else {
            return materialEqual && relay.revision == other.relay.revision
        }
        return materialEqual
    }
}

// MARK: - v0.8.8m14 Broadcast Overlay State

/// Score values that are safe for the public broadcast overlay.
struct BroadcastScoreDisplayState: Equatable {
    var homeScoreText: String
    var awayScoreText: String

    static let empty = BroadcastScoreDisplayState(homeScoreText: "0", awayScoreText: "0")
}

/// Clock value that is safe for the public broadcast overlay.
struct BroadcastClockDisplayState: Equatable {
    var clockText: String
    var isManual: Bool
    var isStale: Bool

    static let empty = BroadcastClockDisplayState(clockText: "20:00", isManual: false, isStale: false)
}

/// Period value that is safe for the public broadcast overlay.
struct BroadcastPeriodDisplayState: Equatable {
    var periodText: String
    var isManual: Bool

    static let empty = BroadcastPeriodDisplayState(periodText: "1", isManual: false)
}

/// Public recording badge state only. This does not own the recording pipeline.
enum RecordingBadgeState: Equatable {
    case idle
    case starting
    case recording(durationText: String)
    case paused(durationText: String)
    case stopping
    case saving
    case saved(message: String)
    case failed(message: String)

    var label: String {
        switch self {
        case .idle:
            return "Idle"
        case .starting:
            return "Starting"
        case .recording(let durationText):
            return "Recording \(durationText)"
        case .paused(let durationText):
            return "Paused \(durationText)"
        case .stopping:
            return "Stopping"
        case .saving:
            return "Saving"
        case .saved(let message):
            return message
        case .failed(let message):
            return message
        }
    }

    @MainActor
    static func current() -> RecordingBadgeState {
        let recorder = BroadcastRecordingManager.shared

        if recorder.manualClipExportStateText == "Failed" {
            return .failed(message: recorder.manualClipFeedbackText)
        }

        if recorder.manualClipExportStateText == "Saved" {
            return .saved(message: recorder.manualClipFeedbackText)
        }

        if recorder.manualClipExportStateText == "Queued" || recorder.manualClipExportStateText == "Recording" {
            return .saving
        }

        switch recorder.state {
        case .idle:
            return .idle
        case .starting:
            return .starting
        case .recording:
            return .recording(durationText: recorder.elapsedText)
        case .paused:
            return .paused(durationText: recorder.elapsedText)
        case .stopping:
            return .stopping
        case .failed:
            return .failed(message: recorder.lastErrorMessage ?? "Recording failed")
        }
    }
}

/// Immutable public overlay snapshot.
///
/// This intentionally contains accepted display values only. It does not carry
/// OCR candidates, OCR confidence, camera/session objects, calibration geometry,
/// scheduler state or raw diagnostics.
struct BroadcastOverlaySnapshot: Equatable {
    var viewerScoreboard: RinkLensViewerScoreboardSnapshot
    var scoreboardState: ScoreboardState
    var clock: BroadcastClockDisplayState
    var score: BroadcastScoreDisplayState
    var period: BroadcastPeriodDisplayState
    var penalties: [PenaltyClock]
    var strengthState: StrengthState
    var activeBroadcastBanner: BroadcastEvent?
    var activeIntermissionReel: BroadcastIntermissionReelState?
    var isOCRMode: Bool
    var modeStatusText: String
    var recordingBadge: RecordingBadgeState
    var homeLogo: UIImage?
    var awayLogo: UIImage?
    var livePreviewRotationOffsetDegrees: CGFloat
    /// Source chosen by the viewer-snapshot resolver for each visible field.
    /// Metadata candidates are intentionally excluded from this map.
    var fieldSources: [String: String]

    static let empty = BroadcastOverlaySnapshot(
        viewerScoreboard: .empty,
        scoreboardState: ScoreboardState(),
        clock: .empty,
        score: .empty,
        period: .empty,
        penalties: [],
        strengthState: .evenStrength,
        activeBroadcastBanner: nil,
        activeIntermissionReel: nil,
        isOCRMode: false,
        modeStatusText: "Manual",
        recordingBadge: .idle,
        homeLogo: nil,
        awayLogo: nil,
        livePreviewRotationOffsetDegrees: 0,
        fieldSources: [:]
    )

    init(
        viewerScoreboard: RinkLensViewerScoreboardSnapshot,
        scoreboardState: ScoreboardState,
        isOCRMode: Bool,
        modeStatusText: String,
        strengthState: StrengthState,
        penalties: [PenaltyClock],
        activeBroadcastBanner: BroadcastEvent?,
        activeIntermissionReel: BroadcastIntermissionReelState? = nil,
        homeLogo: UIImage?,
        awayLogo: UIImage?,
        recordingBadge: RecordingBadgeState,
        livePreviewRotationOffsetDegrees: CGFloat,
        fieldSources: [String: String] = [:]
    ) {
        self.viewerScoreboard = viewerScoreboard
        self.scoreboardState = scoreboardState
        self.clock = BroadcastClockDisplayState(
            clockText: scoreboardState.clock ?? "--:--",
            isManual: false,
            isStale: false
        )
        self.score = BroadcastScoreDisplayState(
            homeScoreText: scoreboardState.homeScore.map { String($0) } ?? "-",
            awayScoreText: scoreboardState.awayScore.map { String($0) } ?? "-"
        )
        self.period = BroadcastPeriodDisplayState(
            periodText: scoreboardState.periodLabel ?? scoreboardState.period.map { String($0) } ?? "-",
            isManual: false
        )
        self.penalties = penalties
        self.strengthState = strengthState
        self.activeBroadcastBanner = activeBroadcastBanner
        self.activeIntermissionReel = activeIntermissionReel
        self.isOCRMode = isOCRMode
        self.modeStatusText = modeStatusText
        self.recordingBadge = recordingBadge
        self.homeLogo = homeLogo
        self.awayLogo = awayLogo
        self.livePreviewRotationOffsetDegrees = livePreviewRotationOffsetDegrees
        self.fieldSources = fieldSources
    }

    private init(
        viewerScoreboard: RinkLensViewerScoreboardSnapshot,
        scoreboardState: ScoreboardState,
        clock: BroadcastClockDisplayState,
        score: BroadcastScoreDisplayState,
        period: BroadcastPeriodDisplayState,
        penalties: [PenaltyClock],
        strengthState: StrengthState,
        activeBroadcastBanner: BroadcastEvent?,
        activeIntermissionReel: BroadcastIntermissionReelState?,
        isOCRMode: Bool,
        modeStatusText: String,
        recordingBadge: RecordingBadgeState,
        homeLogo: UIImage?,
        awayLogo: UIImage?,
        livePreviewRotationOffsetDegrees: CGFloat,
        fieldSources: [String: String]
    ) {
        self.viewerScoreboard = viewerScoreboard
        self.scoreboardState = scoreboardState
        self.clock = clock
        self.score = score
        self.period = period
        self.penalties = penalties
        self.strengthState = strengthState
        self.activeBroadcastBanner = activeBroadcastBanner
        self.activeIntermissionReel = activeIntermissionReel
        self.isOCRMode = isOCRMode
        self.modeStatusText = modeStatusText
        self.recordingBadge = recordingBadge
        self.homeLogo = homeLogo
        self.awayLogo = awayLogo
        self.livePreviewRotationOffsetDegrees = livePreviewRotationOffsetDegrees
        self.fieldSources = fieldSources
    }

    static func == (lhs: BroadcastOverlaySnapshot, rhs: BroadcastOverlaySnapshot) -> Bool {
        lhs.viewerScoreboard.isMateriallyEqual(to: rhs.viewerScoreboard) &&
        lhs.scoreboardState == rhs.scoreboardState &&
        lhs.clock == rhs.clock &&
        lhs.score == rhs.score &&
        lhs.period == rhs.period &&
        lhs.penalties == rhs.penalties &&
        lhs.strengthState == rhs.strengthState &&
        lhs.activeBroadcastBanner == rhs.activeBroadcastBanner &&
        lhs.activeIntermissionReel == rhs.activeIntermissionReel &&
        lhs.isOCRMode == rhs.isOCRMode &&
        lhs.modeStatusText == rhs.modeStatusText &&
        lhs.recordingBadge == rhs.recordingBadge &&
        lhs.livePreviewRotationOffsetDegrees == rhs.livePreviewRotationOffsetDegrees &&
        lhs.fieldSources == rhs.fieldSources &&
        sameBroadcastOverlayImage(lhs.homeLogo, rhs.homeLogo) &&
        sameBroadcastOverlayImage(lhs.awayLogo, rhs.awayLogo)
    }
}

/// Small Broadcast-only observable state.
///
/// The ViewModel coordinates accepted values into this object. Broadcast can then
/// consume this stable snapshot instead of observing OCR, camera, calibration,
/// diagnostics and media browser state directly.
@MainActor
final class BroadcastOverlayState: ObservableObject {
    @Published private(set) var snapshot: BroadcastOverlaySnapshot = .empty
    private(set) var lastDisplayChangeAt: Date?

    var clockText: String { snapshot.clock.clockText }
    var homeScoreText: String { snapshot.score.homeScoreText }
    var awayScoreText: String { snapshot.score.awayScoreText }
    var periodText: String { snapshot.period.periodText }
    var penalties: [PenaltyClock] { snapshot.penalties }
    var recordingBadge: RecordingBadgeState { snapshot.recordingBadge }
    var activeIntermissionReel: BroadcastIntermissionReelState? { snapshot.activeIntermissionReel }

    func apply(_ next: BroadcastOverlaySnapshot) {
        guard next != snapshot else { return }
        let previous = snapshot
        if RinkLensRiskFeaturePolicy.isEnabled(.visibleFieldSourceLoggingV2) {
            logVisibleFieldTransitions(from: previous, to: next)
        }
        snapshot = next
        lastDisplayChangeAt = Date()
    }

    private func logVisibleFieldTransitions(
        from previous: BroadcastOverlaySnapshot,
        to next: BroadcastOverlaySnapshot
    ) {
        let keys = [
            "homeTeam", "awayTeam", "clock", "homeScore", "awayScore", "period",
            "homePenalty1", "homePenalty2", "awayPenalty1", "awayPenalty2", "strength"
        ]
        for key in keys {
            let previousValue = previous.viewerScoreboard.visibleDescriptor(for: key)
            let nextValue = next.viewerScoreboard.visibleDescriptor(for: key)
            let previousSource = previous.viewerScoreboard.source(for: key)
            let nextSource = next.viewerScoreboard.source(for: key)
            guard previousValue != nextValue || previousSource != nextSource else { continue }
            RinkLensStructuredEventLogger.shared.record(
                domain: .scoreboardPresentation,
                event: "visible_field_transition",
                entityID: key,
                previous: [
                    "value": previousValue,
                    "source": previousSource,
                    "viewerIdentity": previous.viewerScoreboard.renderIdentity,
                    "relayRevision": String(previous.viewerScoreboard.relayRevision)
                ],
                next: [
                    "value": nextValue,
                    "source": nextSource,
                    "viewerIdentity": next.viewerScoreboard.renderIdentity,
                    "relayRevision": String(next.viewerScoreboard.relayRevision)
                ],
                source: "BroadcastOverlayState",
                reason: "Authoritative viewer scoreboard snapshot applied",
                captureGeneration: next.viewerScoreboard.relay.captureGeneration
            )
        }
    }

    private static func visibleFieldValues(_ snapshot: BroadcastOverlaySnapshot) -> [String: String] {
        let state = snapshot.scoreboardState
        return [
            "homeTeam": state.homeTeam ?? "none",
            "awayTeam": state.awayTeam ?? "none",
            "clock": state.clock ?? "none",
            "homeScore": state.homeScore.map { String($0) } ?? "none",
            "awayScore": state.awayScore.map { String($0) } ?? "none",
            "period": state.period.map { String($0) } ?? "none",
            "homePenalty1": penaltyText(player: state.homePenalty1Player, clock: state.homePenalty1Clock),
            "homePenalty2": penaltyText(player: state.homePenalty2Player, clock: state.homePenalty2Clock),
            "awayPenalty1": penaltyText(player: state.awayPenalty1Player, clock: state.awayPenalty1Clock),
            "awayPenalty2": penaltyText(player: state.awayPenalty2Player, clock: state.awayPenalty2Clock)
        ]
    }

    private static func penaltyText(player: Int?, clock: String?) -> String {
        "player=\(player.map { String($0) } ?? "none"),clock=\(clock ?? "none")"
    }

    func reset() {
        apply(.empty)
    }
}

private func sameBroadcastOverlayImage(_ lhs: UIImage?, _ rhs: UIImage?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
        return true
    case let (left?, right?):
        return left === right
    default:
        return false
    }
}

#endif
