// BUILD 714 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation
import SwiftUI
import CoreGraphics
import CoreMedia
import UIKit

// MARK: - Build 692 state ownership contract

nonisolated enum RinkLensStateDomain: String, Codable, CaseIterable {
    case match
    case clock
    case penalty
    case gameEvent
    case popup
    case popupConfiguration
    case camera
    case cameraControl
    case manualScore
    case scoreboardDefaults
    case teamIdentity
    case sponsorRoster
    case scorebug
    case scoreboardPresentation
    case scoreboardInput
    case calibration
    case rinkProfile
    case recording
    case ocr
    case ocrConfiguration
    case navigation
    case capture
    case broadcastPhase
    case timeline
    case streaming
    case season
    case gameConfiguration
    case youtubePublishing
}

nonisolated enum RinkLensStateValueRole: String, Codable {
    case authority
    case candidate
    case projection
    case snapshot
    case draft
    case cache
}

/// Documents the single writable owner for a domain. Screens and adapters may
/// expose projections or drafts, but they must not become independent owners.
nonisolated struct RinkLensStateOwnershipRecord: Codable, Equatable {
    let domain: RinkLensStateDomain
    let owner: String
    let valueRole: RinkLensStateValueRole
    let notes: String
}

nonisolated enum RinkLensStateOwnershipRegistry {
    /// Build 706 hard rule: every domain names exactly one writable owner.
    /// Evidence stores, hardware acknowledgements, snapshots and view projections
    /// are deliberately described in notes rather than added as co-owners.
    static let records: [RinkLensStateOwnershipRecord] = [
        .init(domain: .match, owner: "RinkLensMatchStateReducer", valueRole: .authority, notes: "Accepted score, clock, period and displayed penalty values"),
        .init(domain: .clock, owner: "RinkLensMatchStateReducer", valueRole: .authority, notes: "The accepted Clock value is MatchState; RinkLensGameClockAuthority stores evidence and presentation projections only"),
        .init(domain: .penalty, owner: "RinkLensMatchStateReducer", valueRole: .authority, notes: "Displayed penalty player/timer values are reducer-owned; lifecycle and relay stores retain candidate evidence only"),
        .init(domain: .gameEvent, owner: "RinkLensGameEventLifecycleStore", valueRole: .authority, notes: "Canonical event identity, stoppage evidence and lifecycle"),
        .init(domain: .popup, owner: "RinkLensOverlayEventStateMachine", valueRole: .authority, notes: "Pending, active, dismissed and history popup states"),
        .init(domain: .popupConfiguration, owner: "BroadcastEventPopupSettings", valueRole: .authority, notes: "Popup policy; eligible events freeze an immutable policy snapshot"),
        .init(domain: .camera, owner: "CaptureEngine", valueRole: .authority, notes: "Applied Broadcast capture truth: active graph, physical device, format, cadence, zoom acknowledgement and verified generation. HockeyCameraService is the logical-source/capability and explicit focus/exposure/white-balance/torch hardware adapter; requested controls remain in RinkLensCameraControlStore and CaptureLifecycleController is orchestration only."),
        .init(domain: .cameraControl, owner: "RinkLensCameraControlStore", valueRole: .authority, notes: "Requested image profile, rotation, Broadcast stabilisation and zoom policy; logical camera source selection is not stored here and remains HockeyCameraService-owned"),
        .init(domain: .manualScore, owner: "ManualScoreController", valueRole: .authority, notes: "Manual drafts, protection flags and values"),
        .init(domain: .scoreboardDefaults, owner: "RinkLensScoreboardDefaultsStore", valueRole: .authority, notes: "New-game defaults only"),
        .init(domain: .teamIdentity, owner: "RinkLensTeamIdentityStore", valueRole: .authority, notes: "Team names, active logos and identity profiles"),
        .init(domain: .sponsorRoster, owner: "SponsorCatalogueStore", valueRole: .authority, notes: "Sponsor catalogue, placements and roster"),
        .init(domain: .scorebug, owner: "BroadcastScoreboardLayoutSettings", valueRole: .authority, notes: "Scorebug appearance values"),
        .init(domain: .scoreboardPresentation, owner: "BroadcastOverlayState", valueRole: .authority, notes: "Immutable viewer snapshot assembled from validated candidates"),
        .init(domain: .scoreboardInput, owner: "RinkLensScoreboardInputLifecycleStore", valueRole: .authority, notes: "Selected input mode plus operator start/stop and route suspension lifecycle"),
        .init(domain: .calibration, owner: "RinkLensCalibrationStore", valueRole: .authority, notes: "OCR layout, perspective, colour calibration and saved revision; camera controls are referenced, not copied as live state"),
        .init(domain: .rinkProfile, owner: "RinkTemplateStore", valueRole: .authority, notes: "Persistent rink template catalogue; the calibration store holds the active edit projection"),
        .init(domain: .recording, owner: "BroadcastRecordingManager", valueRole: .authority, notes: "Recording lifecycle, codec/bitrate policy and immutable source-derived session snapshots; dimensions and cadence remain camera-owned"),
        .init(domain: .ocr, owner: "RinkLensOCREngine", valueRole: .candidate, notes: "Raw OCR evidence only; accepted public values must pass through the MatchState reducer"),
        .init(domain: .ocrConfiguration, owner: "RinkLensOCRConfigurationStore", valueRole: .authority, notes: "Operator OCR configuration"),
        .init(domain: .navigation, owner: "AppCoordinator", valueRole: .authority, notes: "Sole writable owner of the visible NextGen route; route shells render that route directly and retain no pending/switching state"),
        .init(domain: .capture, owner: "CaptureLifecycleController", valueRole: .authority, notes: "Applied Broadcast/OCR graph; external OCR reconciliation cannot mutate AppCoordinator route, Broadcast zoom intent or recording state"),
        .init(domain: .broadcastPhase, owner: "RinkLensMatchEventJournal", valueRole: .authority, notes: "Broadcast phase and bounded transition history"),
        .init(domain: .timeline, owner: "RinkLensMatchEventJournal", valueRole: .authority, notes: "Canonical internal event journal for popup sequencing, audit and undo; not viewer UI"),
        .init(domain: .streaming, owner: "StreamControlStore", valueRole: .authority, notes: "Connection lifecycle; destination configuration is an input snapshot"),
        .init(domain: .season, owner: "RinkLensSeasonStore", valueRole: .authority, notes: "Reusable season, team, venue, fixture and publishing defaults; never live game state"),
        .init(domain: .gameConfiguration, owner: "RinkLensGameConfigurationStore", valueRole: .authority, notes: "Immutable resolved configuration for the loaded fixture"),
        .init(domain: .youtubePublishing, owner: "RinkLensSeasonStore", valueRole: .authority, notes: "Fixture publication identity and state; the network actor retains no production state")
    ]

    static func owner(for domain: RinkLensStateDomain) -> String {
        records.first(where: { $0.domain == domain })?.owner ?? "UnregisteredOwner"
    }

    static var hasExactlyOneWritableOwnerPerDomain: Bool {
        let grouped = Dictionary(grouping: records, by: \.domain)
        return Set(grouped.keys) == Set(RinkLensStateDomain.allCases)
            && grouped.values.allSatisfy { $0.count == 1 }
            && records.allSatisfy { !$0.owner.contains("+") && !$0.owner.contains("/") && !$0.owner.isEmpty }
    }

    static var diagnosticSummary: String {
        records.map { "\($0.domain.rawValue)=\($0.owner)[\($0.valueRole.rawValue)]" }.joined(separator: "; ")
    }
}

// MARK: - Build 698 temporary feature flags

nonisolated enum RinkLensRiskFeature: String, CaseIterable, Codable, Sendable {
    case penaltyStablePlayerSingleTimer
    case penaltyPhysicalTransitionAdmissionV2
    case guidedCalibrationFixed8x
    case teamIdentityAuthorityV2
    case scorebugStructuredMutationsV2
    case gameClockAuthorityV2
    case gameEventLifecycleV2
    case calibrationProfileAuthorityV2
    case ocrConfigurationAuthorityV2
    case sponsorRosterAuthorityV2
    case operationalStateAuthorityV2
    case matchJournalAuthorityV2
    case popupPolicySnapshotV2
    case streamingStructuredTransitionsV2
    case scoreboardInputLifecycleV2
    case compactPenaltyPanelV2
    case penaltyEdgeFilledTimerAdmissionV2
    case penaltyPhysicalIdentityRebindV2
    case penaltyTimerVisibleHeightParityV2
    case verifiedClockRestartForPopupsV2
    case scoreGoalEventAtAcceptedTransitionV2
    case stablePenaltyTimerCanvasScaleV2
    case largerPeriodStrengthTextV2
    case penaltyConfirmedPairImmediateLifecycleV2
    case penaltyConfirmedPairLateRestartAttributionV2
    case viewerScoreboardSnapshotV2
    case scoreboardInputLifecycleProjectionV2
    case visibleFieldSourceLoggingV2
    case featureFlagGovernanceV2
    case atomicOwnerTransactionsV3
    case eventSemanticDedupeV2
    case runningScoreStoppageBaselineV2
    case penaltyBlankTransitionFastAdmissionV2
    case powerPlayCancellationReconciliationV2
    case eventLatencyLoggingV2
    case penaltyTimerFastLaneV3
    case penaltyTimerFixedGlyphHeightV3
    case stoppageClockEvidenceAuthorityV3
    case penaltyTimerLatencyLoggingV3
    case penaltyStopCandidateAttributionV3
    case screenEntryReadOnlyV4
    case atomicPenaltyCompactionV4
    case popupStateMachineExclusiveV4
    case cameraSourceRecordingProfileV5
    case tapOCRPreviewEntersManualModeV7
    case largerPeriodGlyphV9
    case powerPlayGoalRequiresVisiblePenaltyV9
    case routeIndependentImageRelayV9
    case builtInAutoClearsExactProfileV9
    case roleOwnedCameraDefaultsV10
    case settingsCameraSelectionOnlyV10
    case operationalCameraOverridesV10
    case completedEventSemanticDedupeV11
    case powerPlayGoalUsesPhysicalRemovalV11
    case broadcastCameraControlEntryV11
    case simplifiedEngineeringToolsV11
    case latePhysicalPenaltyPopupRecoveryV11
    case minimalOperatorCameraRecordingV12
    case operatorControlsSettingsStyleV13
    case broadcastVideoStabilisationAuthorityV13
    case customRecordingOutputProfileV15
    case broadcastAdaptiveCameraQualityV17
    case matchEventBaselineAlignmentV18
    case recordingSourceTruthfulStartV19
    case stoppedBoardScoreAdmissionV19
    case latePowerPlayRemovalBindingV19
    case recordingBoundedSourceHoldoverV20
    case squadSettingsTabV21
    case sponsorAsyncLogoCacheV21
    case penaltyRepeatedEdgeTimerRecoveryV22
    case recordingProtectedOCRDegradationV22
    case persistentCalibrationOverlayV22
    case asyncMediaIndexV22
    case boundedDerivedRenderingV22
    case changeDrivenPenaltySchedulerV22
    case recordingSafeDiagnosticsV22
    case transactionalImageRelayControlV23
    case orientationSafeOverlayCompositionV23
    case typedRecordingStopOriginV23
    case reducedClockRectificationV24
    case atomicPowerPlayCompactionSnapshotV24
    case recordingStableBroadcastGenerationV24
    case recordingHiddenPresentationSuspensionV25
    case materialOverlayChangeOnlyV25
    case sharedRelayFieldWorkV25
    case semanticPenaltyEndAndTimeoutEventsV26
    case deduplicatedBroadcastSystemSettingsV27
    case sharedSettingsPreviewGeometryV28
}

nonisolated struct RinkLensRiskFeatureDefinition: Codable, Equatable, Sendable {
    let feature: RinkLensRiskFeature
    let owner: String
    let introducedBuild: Int
    let plannedRemovalBuild: Int
    let defaultEnabled: Bool
    let purpose: String

    var removalPlan: String {
        "Physically verify: \(purpose). On acceptance, delete this flag and its disabled branch in the same build; do not extend beyond Build \(plannedRemovalBuild)."
    }
}

// MARK: - Build 776 temporary rollout review

nonisolated enum RinkLensRiskFeatureReviewDisposition: String, Codable, Sendable {
    case retainedPendingPhysicalAcceptance
    case retired
}

nonisolated struct RinkLensRiskFeatureReviewRecord: Codable, Equatable, Sendable {
    let feature: RinkLensRiskFeature
    let reviewBuild: Int
    let disposition: RinkLensRiskFeatureReviewDisposition
    let nextReviewBuild: Int?
    let evidence: String
}

/// Build 776 removes the former permanently locked flag category. Every
/// remaining entry is a temporary rollout only, expires no later than Build
/// 785, and must be deleted together with its disabled branch in the same
/// physical-acceptance session. Build 785 R12 adds exactly one temporary
/// RecordingEngine rollout for direct writer admission; it shares the same
/// hard Build 785 removal boundary and must not survive physical acceptance.
nonisolated enum RinkLensBuild776FeatureReview {
    static let removalBuild = 785

    static let records: [RinkLensRiskFeatureReviewRecord] = RinkLensRiskFeature.allCases.map { feature in
        let reviewBuild = 776
        return .init(
            feature: feature,
            reviewBuild: reviewBuild,
            disposition: .retainedPendingPhysicalAcceptance,
            nextReviewBuild: removalBuild,
            evidence: "Temporary rollout retained only for physical comparison. On acceptance, delete the flag and disabled branch together; do not extend beyond Build \(removalBuild)."
        )
    }

    static let recordByFeature: [RinkLensRiskFeature: RinkLensRiskFeatureReviewRecord] =
        Dictionary(uniqueKeysWithValues: records.map { ($0.feature, $0) })

    static var hasCompleteCoverage: Bool {
        Set(recordByFeature.keys) == Set(RinkLensRiskFeature.allCases)
            && recordByFeature.count == records.count
    }

    static var diagnosticSummary: String {
        records.map { record in
            let next = record.nextReviewBuild.map { String($0) } ?? "none"
            return "\(record.feature.rawValue)=\(record.disposition.rawValue)[review=\(record.reviewBuild);remove<=\(next)]"
        }.joined(separator: "; ")
    }
}

nonisolated final class RinkLensRiskFeatureRuntime: @unchecked Sendable {
    static let shared = RinkLensRiskFeatureRuntime()
    private let lock = NSLock()
    private var values: [RinkLensRiskFeature: Bool]

    private init() {
        let persisted = UserDefaults.standard.dictionaryRepresentation()
        var loaded: [RinkLensRiskFeature: Bool] = [:]
        for feature in RinkLensRiskFeature.allCases {
            let key = RinkLensRiskFeaturePolicy.defaultsKey(feature)
            loaded[feature] = (persisted[key] as? Bool) ?? RinkLensRiskFeaturePolicy.defaultEnabled(feature)
        }
        values = loaded
    }

    func value(for feature: RinkLensRiskFeature) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return values[feature] ?? true
    }


    func snapshot() -> [RinkLensRiskFeature: Bool] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

nonisolated enum RinkLensRiskFeaturePolicy {
    static func defaultsKey(_ feature: RinkLensRiskFeature) -> String {
        "rinklens.feature.\(feature.rawValue)"
    }

    static func defaultEnabled(_ feature: RinkLensRiskFeature) -> Bool {
        _ = feature
        return true
    }

    static func isEnabled(_ feature: RinkLensRiskFeature) -> Bool {
        precondition(
            RinkLensBuildInfo.buildNumber <= RinkLensBuild776FeatureReview.removalBuild,
            "Temporary feature-flag registry expired at Build \(RinkLensBuild776FeatureReview.removalBuild). Delete each accepted flag and disabled branch before increasing the build number."
        )
        return RinkLensRiskFeatureRuntime.shared.value(for: feature)
    }

    static var diagnosticSummary: String {
        let snapshot = RinkLensRiskFeatureRuntime.shared.snapshot()
        return RinkLensRiskFeatureCatalog.definitions.map { definition in
            let enabled = (snapshot[definition.feature] ?? definition.defaultEnabled) ? "on" : "off"
            let review = RinkLensBuild776FeatureReview.recordByFeature[definition.feature]
            return "\(definition.feature.rawValue)=\(enabled)[review<=\(definition.plannedRemovalBuild);temporary;\(review?.disposition.rawValue ?? "missing-review")]"
        }.joined(separator: "; ")
    }
}

nonisolated enum RinkLensRiskFeatureCatalog {
    static let definitions: [RinkLensRiskFeatureDefinition] = [
        .init(feature: .penaltyStablePlayerSingleTimer, owner: "Penalty", introducedBuild: 689, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Stable player plus one strict timer sample"),
        .init(feature: .penaltyPhysicalTransitionAdmissionV2, owner: "Penalty", introducedBuild: 689, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Reachable non-OCR lifecycle admission"),
        .init(feature: .guidedCalibrationFixed8x, owner: "Calibration", introducedBuild: 689, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Fixed 8x guide with legacy behaviour retained for comparison"),
        .init(feature: .teamIdentityAuthorityV2, owner: "TeamIdentity", introducedBuild: 691, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Single transactional owner for team names, logos and saved identity profiles"),
        .init(feature: .scorebugStructuredMutationsV2, owner: "Scorebug", introducedBuild: 691, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Structured previous/new logging for every scorebug appearance mutation"),
        .init(feature: .gameClockAuthorityV2, owner: "Clock", introducedBuild: 691, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Separate accepted clock from relay metadata, trusted anchor and presentation projection"),
        .init(feature: .gameEventLifecycleV2, owner: "GameEvent", introducedBuild: 692, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Canonical event lifecycle record across candidate, held, queued, displayed and completed states"),
        .init(feature: .calibrationProfileAuthorityV2, owner: "Calibration", introducedBuild: 692, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Atomic active rink calibration snapshot with explicit dirty/saved revision"),
        .init(feature: .ocrConfigurationAuthorityV2, owner: "OCR", introducedBuild: 692, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Single owner for operator OCR configuration"),
        .init(feature: .sponsorRosterAuthorityV2, owner: "Sponsors", introducedBuild: 692, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Controlled sponsor, placement and roster mutations with frozen event resolution"),
        .init(feature: .operationalStateAuthorityV2, owner: "NavigationCapture", introducedBuild: 692, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Transactional screen, OCR intent, pause and transition state"),
        .init(feature: .matchJournalAuthorityV2, owner: "MatchJournal", introducedBuild: 692, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "One owner for broadcast phase, phase history and match timeline"),
        .init(feature: .popupPolicySnapshotV2, owner: "PopupConfiguration", introducedBuild: 692, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Freeze event popup policy when an event becomes eligible"),
        .init(feature: .streamingStructuredTransitionsV2, owner: "Streaming", introducedBuild: 692, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Structured destination and connection lifecycle transitions"),
        .init(feature: .scoreboardInputLifecycleV2, owner: "ScoreboardInput", introducedBuild: 694, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Distinguish operator stop, armed, route suspension, starting, running and failed states"),
        .init(feature: .compactPenaltyPanelV2, owner: "Scorebug", introducedBuild: 695, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Reduce penalty player/timer panel width while retaining full measured timer characters"),
        .init(feature: .penaltyEdgeFilledTimerAdmissionV2, owner: "Penalty", introducedBuild: 695, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Admit strong measured 10:00/2:00 timer groups when overwide or border-contact are the only geometry warnings"),
        .init(feature: .penaltyPhysicalIdentityRebindV2, owner: "Penalty", introducedBuild: 695, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Move one continuing physical penalty identity atomically across slots without transient duplicate players"),
        .init(feature: .penaltyTimerVisibleHeightParityV2, owner: "Scorebug", introducedBuild: 696, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Crop transparent relay safety canvas at the shared live/recording boundary so timer and player illuminated heights match"),
        .init(feature: .verifiedClockRestartForPopupsV2, owner: "Clock", introducedBuild: 696, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Require two material Clock digit changes before the restart plus five-second popup deadline begins"),
        .init(feature: .scoreGoalEventAtAcceptedTransitionV2, owner: "GameEvent", introducedBuild: 696, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Create the provisional goal event when an accepted plus-one score occurs inside a stopped-board transaction"),
        .init(feature: .stablePenaltyTimerCanvasScaleV2, owner: "Scorebug", introducedBuild: 697, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Use the producer-owned fixed penalty timer canvas and one constant 1.08 display scale instead of per-frame alpha cropping"),
        .init(feature: .largerPeriodStrengthTextV2, owner: "Scorebug", introducedBuild: 697, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Increase Period/strength typography and widen the Clock source/display safety envelope while retaining the established centre height and rollback path"),
        .init(feature: .penaltyConfirmedPairImmediateLifecycleV2, owner: "Penalty", introducedBuild: 697, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Admit a proven blank-to-occupied player plus strong timer pair without waiting for unrelated sibling-slot completeness"),
        .init(feature: .penaltyConfirmedPairLateRestartAttributionV2, owner: "GameEvent", introducedBuild: 697, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Bind a late-confirmed physical penalty pair to the immediately preceding verified restart within the bounded grace window"),
        .init(feature: .viewerScoreboardSnapshotV2, owner: "ScoreboardPresentation", introducedBuild: 698, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Resolve clock, score, period, teams and penalty presentation through one immutable BroadcastOverlayState snapshot"),
        .init(feature: .scoreboardInputLifecycleProjectionV2, owner: "ScoreboardInput", introducedBuild: 698, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Derive Image Relay selected/enabled state from RinkLensScoreboardInputLifecycleStore instead of retaining a second ViewModel boolean"),
        .init(feature: .visibleFieldSourceLoggingV2, owner: "Diagnostics", introducedBuild: 698, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Record every visible scoreboard field value or source change with previous/new/source/reason evidence"),
        .init(feature: .featureFlagGovernanceV2, owner: "Governance", introducedBuild: 698, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Report rollback flags past their planned removal build while retaining them until physical acceptance"),
        .init(feature: .atomicOwnerTransactionsV3, owner: "StateOwnership", introducedBuild: 699, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Apply team identity and settings resets as one owner transaction while retaining a temporary legacy comparison path"),
        .init(feature: .eventSemanticDedupeV2, owner: "GameEvent", introducedBuild: 702, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Admit one canonical score event for each team and resulting score, even if stoppage confirmation is replaced"),
        .init(feature: .runningScoreStoppageBaselineV2, owner: "GameEvent", introducedBuild: 702, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Freeze the last verified running score as event-boundary evidence so a late stop cannot absorb a goal into its baseline"),
        .init(feature: .penaltyBlankTransitionFastAdmissionV2, owner: "Penalty", introducedBuild: 702, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Admit a strong timer after two stable player observations only when the same slot proved a blank-to-occupied transition"),
        .init(feature: .powerPlayCancellationReconciliationV2, owner: "Penalty", introducedBuild: 702, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Tombstone a served physical penalty for the scoring stoppage so stale relay evidence cannot recreate it"),
        .init(feature: .eventLatencyLoggingV2, owner: "Diagnostics", introducedBuild: 702, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Record candidate, confirmation, metadata, lifecycle and release checkpoints with elapsed milliseconds"),
        .init(feature: .penaltyTimerFastLaneV3, owner: "ScoreboardImageRelay", introducedBuild: 703, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Crop only four timer zones in the 0.30-second timer lane and consume player identity/evidence from the player-lane owner"),
        .init(feature: .penaltyTimerFixedGlyphHeightV3, owner: "BroadcastScoreboardLayoutSettings/ScoreboardImageRelay", introducedBuild: 703, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Render every active penalty timer at one fixed illuminated height and activation-owned centre inside the unchanged timer canvas"),
        .init(feature: .stoppageClockEvidenceAuthorityV3, owner: "RinkLensGameEventLifecycleStore", introducedBuild: 703, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Bind one fresh immutable Clock image/hash to each stoppage so penalty popups cannot inherit a stale 20:00 image"),
        .init(feature: .penaltyTimerLatencyLoggingV3, owner: "Diagnostics", introducedBuild: 703, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Record timer frame age, processing duration, prior/new image hash, source sequence, generation and publication interval"),
        .init(feature: .penaltyStopCandidateAttributionV3, owner: "RinkLensGameEventLifecycleStore", introducedBuild: 703, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Hold a confirmed penalty during physical stop confirmation and bind it to that stoppage instead of permanently marking it ineligible while Clock stoppage evidence is late"),
        .init(feature: .screenEntryReadOnlyV4, owner: "StateOwnership", introducedBuild: 706, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Keep Broadcast and recording screen entry read-only; owner startup performs any persistence recovery"),
        .init(feature: .atomicPenaltyCompactionV4, owner: "RinkLensMatchStateReducer", introducedBuild: 706, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Use one verified two-to-one penalty compaction path and suppress legacy competing reconciliation paths"),
        .init(feature: .popupStateMachineExclusiveV4, owner: "Popup", introducedBuild: 706, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Require all popup queue decisions to pass through RinkLensOverlayEventStateMachine"),
        .init(feature: .cameraSourceRecordingProfileV5, owner: "Camera/Recording boundary", introducedBuild: 707, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Derive recording dimensions and cadence from the verified Broadcast camera source; keep the former independent selectors only as a disabled rollback path"),
        .init(feature: .tapOCRPreviewEntersManualModeV7, owner: "HockeyScoreboardViewModel", introducedBuild: 717, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Restore direct tap on OCR preview imagery to request Manual scoreboard input through the authoritative mode owner"),
        .init(feature: .largerPeriodGlyphV9, owner: "Scorebug", introducedBuild: 719, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Increase only the Period glyph inside the unchanged centre cell without resizing the scorebug canvas"),
        .init(feature: .powerPlayGoalRequiresVisiblePenaltyV9, owner: "GameEvent", introducedBuild: 719, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Require current physical opposing-penalty visibility as well as metadata strength before classifying a goal as power-play"),
        .init(feature: .routeIndependentImageRelayV9, owner: "ScoreboardInput/Capture", introducedBuild: 719, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Keep operator-requested Image Relay processing and its OCR capture branch alive when Broadcast is hidden or Command Centre is shown"),
        .init(feature: .builtInAutoClearsExactProfileV9, owner: "Camera", introducedBuild: 719, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Clear stale exact manual format and cadence preferences when built-in Auto is enabled so supported 1080p60 can become the verified source"),
        .init(feature: .roleOwnedCameraDefaultsV10, owner: "HockeyCameraService", introducedBuild: 720, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Give Broadcast one requested 1080p60 automatic default and OCR one requested 1080p30 automatic default without reading Apple Camera app settings"),
        .init(feature: .settingsCameraSelectionOnlyV10, owner: "Settings/Camera", introducedBuild: 720, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Keep global Settings limited to authoritative Broadcast and OCR camera assignment"),
        .init(feature: .operationalCameraOverridesV10, owner: "Broadcast/OCR camera controls", introducedBuild: 720, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Allow exact format and supported lens overrides only on the operational screen that consumes the camera"),
        .init(feature: .completedEventSemanticDedupeV11, owner: "RinkLensGameEventLifecycleStore", introducedBuild: 723, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Retain canonical semantic identities after popup completion so the same resulting score cannot be replayed later"),
        .init(feature: .powerPlayGoalUsesPhysicalRemovalV11, owner: "RinkLensPenaltyLifecycleStore", introducedBuild: 723, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Use recent confirmed physical penalty removal as goal cancellation evidence and never delete a still-visible penalty during classification"),
        .init(feature: .broadcastCameraControlEntryV11, owner: "BroadcastView", introducedBuild: 723, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Expose the role-owned Broadcast camera controls directly from the NextGen Broadcast screen"),
        .init(feature: .simplifiedEngineeringToolsV11, owner: "DiagnosticsHubView", introducedBuild: 723, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Keep operator Diagnostics focused on logging, recovery and physical validation while retaining deep evidence in exports"),
        .init(feature: .latePhysicalPenaltyPopupRecoveryV11, owner: "RinkLensGameEventLifecycleStore", introducedBuild: 723, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Recover one popup for a recently confirmed blank-to-occupied physical penalty pair whose identity enrichment completed after the Clock restart"),
        .init(feature: .minimalOperatorCameraRecordingV12, owner: "OperatorControlHubSheet", introducedBuild: 725, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Combine Broadcast camera and recording controls, minimise OCR camera chrome, and keep engineering validation evidence in exports rather than the operator UI"),
        .init(feature: .operatorControlsSettingsStyleV13, owner: "OperatorControlHubSheet", introducedBuild: 726, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Remove Camera and Recording from active Operator Controls and use the Broadcast Setup capsule navigation style while retaining Build 725 as rollback"),
        .init(feature: .broadcastVideoStabilisationAuthorityV13, owner: "RinkLensCameraControlStore", introducedBuild: 726, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Make requested Broadcast video stabilisation authoritative, apply it to the Broadcast capture connection only, and keep OCR geometry unstabilised"),
        .init(feature: .customRecordingOutputProfileV15, owner: "BroadcastRecordingManager", introducedBuild: 728, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Add one authoritative managed/custom encoded-output profile, exact bitrate, device capability filtering and camera-source preflight while retaining Build 727 behind the flag"),
        .init(feature: .broadcastAdaptiveCameraQualityV17, owner: "RinkLensCameraControlStore/CaptureLifecycleController", introducedBuild: 732, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Temporary RL-016 rollout only: despite the historic feature name, R14 removes all light/ISO-driven cadence adaptation. Motion and Balanced are fixed 1080p60; Image Quality is fixed 1080p30. RinkLensCameraControlStore is the sole requested-mode owner, CaptureLifecycleController coordinates operator-only same-file cadence changes, and CaptureEngine retains only applied hardware truth. After RL-016 physically passes before/during recording, delete this rollout flag and any superseded disabled quality path in the same accepted revision; do not stack another camera-quality flag"),
        .init(feature: .matchEventBaselineAlignmentV18, owner: "RinkLensGameEventLifecycleStore", introducedBuild: 732, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Preserve the canonical 0-0 score as the event baseline after Clock evidence begins and reject pre-Period penalty popup admission while retaining Build 731 behind the flag"),
        .init(feature: .recordingSourceTruthfulStartV19, owner: "BroadcastRecordingManager", introducedBuild: 733, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Use the verified Broadcast camera source as the effective writer size/cadence while custom recording settings remain codec/bitrate preferences; retain Build 732 source-vs-output rejection behind the flag"),
        .init(feature: .stoppedBoardScoreAdmissionV19, owner: "RinkLensGameEventLifecycleStore", introducedBuild: 733, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Hold sequential score candidates observed while the Clock is running and admit them only after a materially changed physical score glyph is repeatedly confirmed during the committed stoppage"),
        .init(feature: .latePowerPlayRemovalBindingV19, owner: "RinkLensMatchEventJournal", introducedBuild: 733, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Bind a physical penalty removal confirmed just after a power-play goal to the existing canonical goal timeline event without creating a second goal or mutating popup ownership"),
        .init(feature: .recordingBoundedSourceHoldoverV20, owner: "BroadcastRecordingSourceClockStarvationGuard", introducedBuild: 738, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Allow RecordingWriter to reuse one latest valid source PixelBuffer for a bounded 0.50-second callback gap and use a 2.00-second confirmed-loss window while retaining Build 737 immediate missing-tick handling as rollback"),
        .init(feature: .squadSettingsTabV21, owner: "SettingsView.NavigationProjection", introducedBuild: 739, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Move the existing SponsorCatalogueStore-owned home roster into a dedicated Squad tab beside Event Popups while retaining the nested Sponsors section as rollback"),
        .init(feature: .sponsorAsyncLogoCacheV21, owner: "SponsorCatalogueStore", introducedBuild: 739, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Decode bounded sponsor thumbnails off the MainActor and cache them as derived presentation data while retaining raw logo Data as the sole source of truth and synchronous decoding as rollback"),
        .init(feature: .penaltyRepeatedEdgeTimerRecoveryV22, owner: "ScoreboardImageRelay", introducedBuild: 741, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Admit repeated strong calibrated-edge timer evidence while physical player occupancy and pair confirmation remain authoritative"),
        .init(feature: .recordingProtectedOCRDegradationV22, owner: "CaptureEngine", introducedBuild: 741, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Pause only the OCR branch on USB loss while an open writer contract protects uninterrupted Broadcast callbacks"),
        .init(feature: .persistentCalibrationOverlayV22, owner: "RinkLensCalibrationStore", introducedBuild: 741, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Keep the OCR zone overlay structurally mounted and stop screens resetting authoritative calibration rotation"),
        .init(feature: .asyncMediaIndexV22, owner: "LocalRecordingMediaIndex/LocalRecordingMediaAssetRegistry", introducedBuild: 741, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Enumerate media and publish one immutable library snapshot off-main instead of scanning during view appearance"),
        .init(feature: .boundedDerivedRenderingV22, owner: "BroadcastRecordingOverlayCache", introducedBuild: 741, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Cache one final layered composite, avoid UIImage composition churn and purge derived images on memory pressure"),
        .init(feature: .changeDrivenPenaltySchedulerV22, owner: "ScoreboardImageRelay", introducedBuild: 741, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Reduce player-lane cadence and rectification size while retaining capacity-one latest-frame confirmation for changed penalty slots"),
        .init(feature: .recordingSafeDiagnosticsV22, owner: "DiagnosticsEventStore", introducedBuild: 741, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Retain essential structured transitions while Engineering UI breadcrumbs adopt Match Day Safe cadence during recording"),
        .init(feature: .transactionalImageRelayControlV23, owner: "RinkLensScoreboardInputLifecycleStore", introducedBuild: 743, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Serialise operator Start/Stop through one lifecycle owner, coalesce duplicate taps and keep camera capture independent from relay processing while retaining Build 742 control flow as rollback"),
        .init(feature: .orientationSafeOverlayCompositionV23, owner: "BroadcastRecordingOverlayCache", introducedBuild: 743, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Compose cached static and scorebug layers in UIKit top-left coordinates so live Broadcast, recording and clips share one upright overlay while retaining the Build 742 direct Core Graphics composer as rollback"),
        .init(feature: .typedRecordingStopOriginV23, owner: "RecordingEngine", introducedBuild: 743, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Carry a typed operator/background/failure stop reason through the recording owner instead of parsing arbitrary UI source labels while retaining the legacy string overload as rollback"),
        .init(feature: .reducedClockRectificationV24, owner: "ScoreboardImageRelay", introducedBuild: 744, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Rectify the calibrated Clock lane at 480 pixels instead of 640 to reduce processing latency without changing the saved zone or published canvas; retain Build 743 dimensions as rollback"),
        .init(feature: .atomicPowerPlayCompactionSnapshotV24, owner: "RinkLensPenaltyLifecycleStore", introducedBuild: 744, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Capture the immutable two-slot team state before a physical removal, cancel the oldest Slot 1 minor on a power-play goal and atomically transfer the continuing Slot 2 presentation into Slot 1; retain Build 743 inference as rollback"),
        .init(feature: .recordingStableBroadcastGenerationV24, owner: "CaptureEngine", introducedBuild: 744, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Prevent OCR-only external-camera notifications from advancing the Broadcast capture generation while an open writer contract consumes the unchanged rear-camera branch; retain Build 743 global-generation behaviour as rollback"),
        .init(feature: .recordingHiddenPresentationSuspensionV25, owner: "RecordingEngine presentation policy", introducedBuild: 745, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Suspend Settings preview rendering, Media scans and other nonessential route presentation while the authoritative recording owner has an open session; retain Build 744 presentation work as rollback"),
        .init(feature: .materialOverlayChangeOnlyV25, owner: "BroadcastOverlayState/BroadcastRecordingOverlayCache", introducedBuild: 745, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Key live and recorded overlay work from material visible pixels rather than raw relay revisions so unchanged pixels reuse the existing completed overlay; retain Build 744 revision-driven invalidation as rollback"),
        .init(feature: .sharedRelayFieldWorkV25, owner: "ScoreboardImageRelayEngine", introducedBuild: 745, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Rectify one shared board image for simultaneously due penalty player/timer lanes while preserving each lane cadence and output geometry; retain Build 744 independent rectification as rollback"),
        .init(feature: .semanticPenaltyEndAndTimeoutEventsV26, owner: "RinkLensGameEventLifecycleStore", introducedBuild: 747, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Publish penalty-ended/full-strength and geometry-confirmed timeout start/end events through the canonical event lifecycle instead of mislabelling them as power-play starts; retain Build 746 event categories as rollback"),
        .init(feature: .deduplicatedBroadcastSystemSettingsV27, owner: "SettingsView.NavigationProjection", introducedBuild: 748, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Keep Broadcast Setup System limited to build and operating information, with camera and recording configuration shown only on their authoritative operational screens; retain Build 747 duplicated cards as rollback"),
        .init(feature: .sharedSettingsPreviewGeometryV28, owner: "SettingsView.PreviewGeometryProjection", introducedBuild: 749, plannedRemovalBuild: 785, defaultEnabled: true, purpose: "Make Teams & Logos and Scorebug consume the same canonical Live Broadcast Preview width and visible-height fraction while retaining Build 748 section-specific geometry as rollback"),
    ]

    static var expiredDefinitions: [RinkLensRiskFeatureDefinition] {
        definitions.filter { RinkLensBuildInfo.buildNumber > $0.plannedRemovalBuild }
    }

    static var hasCompleteDefinitionCoverage: Bool {
        let grouped = Dictionary(grouping: definitions, by: \.feature)
        return Set(grouped.keys) == Set(RinkLensRiskFeature.allCases)
            && grouped.values.allSatisfy { $0.count == 1 }
    }
}

// MARK: - Build 692 essential structured event logging

nonisolated struct RinkLensStructuredEvent: Codable, Sendable {
    let timestamp: String
    let sessionID: String
    let sequence: UInt64
    let transactionID: String
    let authoritativeOwner: String
    let buildNumber: Int
    let releaseCode: String
    let domain: String
    let event: String
    let entityID: String?
    let previous: [String: String]
    let next: [String: String]
    let source: String
    let reason: String
    let captureGeneration: Int?
    let stoppageID: String?
}

/// Small always-on JSONL journal for essential state changes. High-volume OCR
/// masks remain Engineering-only; ownership, penalty, popup, camera and feature
/// transitions are retained in Match Day Safe so real failures stay diagnosable.
nonisolated final class RinkLensStructuredEventLogger: @unchecked Sendable {
    static let shared = RinkLensStructuredEventLogger()
    static let essentialLoggingAlwaysOn = true

    private let queue = DispatchQueue(label: "rinklens.structured.events", qos: .utility)
    private let sessionID = UUID().uuidString
    private let sequenceLock = NSLock()
    private var sequence: UInt64 = 0
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private var fileURL: URL?
    private let healthLock = NSLock()
    private var writeFailureCount = 0
    private var lastWriteFailureText = "none"
    private var suppressedNoOpCount = 0

    private init() {}

    func record(
        domain: RinkLensStateDomain,
        event: String,
        entityID: String? = nil,
        previous: [String: String] = [:],
        next: [String: String] = [:],
        source: String,
        reason: String,
        captureGeneration: Int? = nil,
        stoppageID: UUID? = nil,
        transactionID: UUID? = nil,
        authoritativeOwner: String? = nil
    ) {
        if previous == next, !previous.isEmpty {
            healthLock.lock()
            suppressedNoOpCount &+= 1
            healthLock.unlock()
            return
        }
        let payload = RinkLensStructuredEvent(
            timestamp: Self.timestamp(Date()),
            sessionID: sessionID,
            sequence: nextSequence(),
            transactionID: (transactionID ?? UUID()).uuidString,
            authoritativeOwner: authoritativeOwner ?? RinkLensStateOwnershipRegistry.owner(for: domain),
            buildNumber: RinkLensBuildInfo.buildNumber,
            releaseCode: RinkLensBuildInfo.releaseCode,
            domain: domain.rawValue,
            event: event,
            entityID: entityID,
            previous: previous,
            next: next,
            source: source,
            reason: reason,
            captureGeneration: captureGeneration,
            stoppageID: stoppageID?.uuidString
        )
        queue.async { [weak self] in self?.append(payload) }
    }

    private func nextSequence() -> UInt64 {
        sequenceLock.lock()
        defer { sequenceLock.unlock() }
        sequence &+= 1
        return sequence
    }

    func exportLines(maxRows: Int = 5_000) -> [String] {
        queue.sync {
            healthLock.lock()
            let failures = writeFailureCount
            let failureText = lastWriteFailureText
            let suppressed = suppressedNoOpCount
            healthLock.unlock()
            guard let fileURL,
                  let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
                return [
                    "No essential structured state transitions recorded yet",
                    "Logging health: writeFailures=\(failures); noOpTransitionsSuppressed=\(suppressed); lastFailure=\(failureText)"
                ]
            }
            let rows = text.split(separator: "\n", omittingEmptySubsequences: true).map { String($0) }
            let retained = rows.suffix(max(1, maxRows))
            return [
                "Session ID: \(sessionID)",
                "File: \(fileURL.lastPathComponent)",
                "Rows: \(rows.count); exported: \(retained.count)",
                "Logging health: writeFailures=\(failures); noOpTransitionsSuppressed=\(suppressed); lastFailure=\(failureText)"
            ] + retained
        }
    }

    /// Operator-requested diagnostics purge. The serial logger queue is the
    /// acknowledgement boundary, so no append can race deletion. The next event
    /// creates a fresh current-session file.
    func clearStoredEvents() async -> RinkLensStorageClearResult {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                    ?? FileManager.default.temporaryDirectory
                let directory = base.appendingPathComponent("RinkLens/Diagnostics", isDirectory: true)
                let urls = (try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                var files = 0
                var bytes: Int64 = 0
                var failure: String?
                for url in urls {
                    let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    do {
                        try FileManager.default.removeItem(at: url)
                        files += 1
                        bytes += size
                    } catch {
                        failure = error.localizedDescription
                    }
                }
                fileURL = nil
                continuation.resume(returning: .init(files: files, bytes: bytes, blockedReason: failure))
            }
        }
    }

    private func append(_ event: RinkLensStructuredEvent) {
        do {
            let target = try resolveFileURL()
            var data = try encoder.encode(event)
            data.append(0x0A)
            if !FileManager.default.fileExists(atPath: target.path) {
                try data.write(to: target, options: .atomic)
            } else {
                let handle = try FileHandle(forWritingTo: target)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            }
        } catch {
            // Essential logging must never interrupt match operation, but the
            // failure remains visible in the next diagnostics export.
            healthLock.lock()
            writeFailureCount &+= 1
            lastWriteFailureText = error.localizedDescription
            healthLock.unlock()
        }
    }

    private func resolveFileURL() throws -> URL {
        if let fileURL { return fileURL }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("RinkLens/Diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeSession = sessionID.replacingOccurrences(of: "-", with: "")
        let url = directory.appendingPathComponent("state_events_build\(RinkLensBuildInfo.buildNumber)_\(safeSession).jsonl")
        fileURL = url
        return url
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

enum RinkLensStructuredStateSummary {
    static func scoreboard(_ state: ScoreboardState) -> [String: String] {
        [
            "homeTeam": state.homeTeam ?? "none",
            "awayTeam": state.awayTeam ?? "none",
            "clock": state.clock ?? "none",
            "homeScore": state.homeScore.map { String($0) } ?? "none",
            "awayScore": state.awayScore.map { String($0) } ?? "none",
            "period": state.period.map { String($0) } ?? "none",
            "homePenalty1": penalty(player: state.homePenalty1Player, clock: state.homePenalty1Clock),
            "homePenalty2": penalty(player: state.homePenalty2Player, clock: state.homePenalty2Clock),
            "awayPenalty1": penalty(player: state.awayPenalty1Player, clock: state.awayPenalty1Clock),
            "awayPenalty2": penalty(player: state.awayPenalty2Player, clock: state.awayPenalty2Clock)
        ]
    }

    private static func penalty(player: Int?, clock: String?) -> String {
        "player=\(player.map { String($0) } ?? "none"),clock=\(clock ?? "none")"
    }
}


// MARK: - Build 692 team identity authority

struct RinkLensTeamIdentitySnapshot {
    var homeTeamName: String = "HOME"
    var awayTeamName: String = "GUEST"
    var homeLogoImage: UIImage?
    var awayLogoImage: UIImage?
    var homeLogoFileName: String?
    var awayLogoFileName: String?
    var templates: [TeamIdentityTemplate] = []
    var selectedTemplateID: UUID?
    var defaultTemplateID: UUID?
}

@MainActor
final class RinkLensTeamIdentityStore: ObservableObject {
    @Published private(set) var snapshot = RinkLensTeamIdentitySnapshot()

    var homeTeamName: String { snapshot.homeTeamName }
    var awayTeamName: String { snapshot.awayTeamName }
    var homeLogoImage: UIImage? { snapshot.homeLogoImage }
    var awayLogoImage: UIImage? { snapshot.awayLogoImage }
    var homeLogoFileName: String? { snapshot.homeLogoFileName }
    var awayLogoFileName: String? { snapshot.awayLogoFileName }
    var templates: [TeamIdentityTemplate] { snapshot.templates }
    var selectedTemplateID: UUID? { snapshot.selectedTemplateID }
    var defaultTemplateID: UUID? { snapshot.defaultTemplateID }

    func setHomeTeamName(_ value: String, source: String, reason: String) {
        mutate(event: "team_name_changed", entityID: "home", source: source, reason: reason) { $0.homeTeamName = value }
    }

    func setAwayTeamName(_ value: String, source: String, reason: String) {
        mutate(event: "team_name_changed", entityID: "away", source: source, reason: reason) { $0.awayTeamName = value }
    }

    /// Recovery AV startup hydration boundary. Persisted Home/Guest names are
    /// committed as one owner transaction before MatchState is first published,
    /// so Broadcast cannot observe a half-hydrated team identity.
    func setTeamNames(home: String, away: String, source: String, reason: String) {
        mutate(event: "team_names_hydrated", entityID: "current-match", source: source, reason: reason) { state in
            state.homeTeamName = home
            state.awayTeamName = away
        }
    }

    func setHomeLogo(image: UIImage?, fileName: String?, source: String, reason: String) {
        mutate(event: "team_logo_changed", entityID: "home", source: source, reason: reason) { state in
            state.homeLogoImage = image
            state.homeLogoFileName = fileName
        }
    }

    func setAwayLogo(image: UIImage?, fileName: String?, source: String, reason: String) {
        mutate(event: "team_logo_changed", entityID: "away", source: source, reason: reason) { state in
            state.awayLogoImage = image
            state.awayLogoFileName = fileName
        }
    }

    func setHomeLogoFileName(_ fileName: String?, source: String, reason: String) {
        mutate(event: "team_logo_reference_changed", entityID: "home", source: source, reason: reason) { $0.homeLogoFileName = fileName }
    }

    func setAwayLogoFileName(_ fileName: String?, source: String, reason: String) {
        mutate(event: "team_logo_reference_changed", entityID: "away", source: source, reason: reason) { $0.awayLogoFileName = fileName }
    }

    func replaceTemplates(_ templates: [TeamIdentityTemplate], source: String, reason: String) {
        mutate(event: "team_identity_templates_changed", entityID: "profiles", source: source, reason: reason) { $0.templates = templates }
    }

    func updateTemplate(id: UUID, source: String, reason: String, _ update: (inout TeamIdentityTemplate) -> Void) {
        mutate(event: "team_identity_template_updated", entityID: id.uuidString, source: source, reason: reason) { state in
            guard let index = state.templates.firstIndex(where: { $0.id == id }) else { return }
            update(&state.templates[index])
        }
    }

    func selectTemplate(_ id: UUID?, source: String, reason: String) {
        mutate(event: "team_identity_selection_changed", entityID: "selected", source: source, reason: reason) { $0.selectedTemplateID = id }
    }

    func setDefaultTemplate(_ id: UUID?, source: String, reason: String) {
        mutate(event: "team_identity_selection_changed", entityID: "default", source: source, reason: reason) { $0.defaultTemplateID = id }
    }

    func resetTeamsAndLogos(source: String, reason: String) {
        mutate(event: "team_identity_reset", entityID: "current-match", source: source, reason: reason) { state in
            state.homeTeamName = "HOME"
            state.awayTeamName = "GUEST"
            state.homeLogoImage = nil
            state.awayLogoImage = nil
            state.homeLogoFileName = nil
            state.awayLogoFileName = nil
        }
    }

    func applyProfile(
        homeTeamName: String,
        awayTeamName: String,
        homeLogoImage: UIImage?,
        awayLogoImage: UIImage?,
        homeLogoFileName: String?,
        awayLogoFileName: String?,
        selectedTemplateID: UUID?,
        source: String,
        reason: String
    ) {
        mutate(event: "team_identity_profile_applied", entityID: selectedTemplateID?.uuidString, source: source, reason: reason) { state in
            state.homeTeamName = homeTeamName
            state.awayTeamName = awayTeamName
            state.homeLogoImage = homeLogoImage
            state.awayLogoImage = awayLogoImage
            state.homeLogoFileName = homeLogoFileName
            state.awayLogoFileName = awayLogoFileName
            state.selectedTemplateID = selectedTemplateID
        }
    }

    @discardableResult
    func validateForPresentation(source: String, reason: String) -> Bool {
        let namesValid = !snapshot.homeTeamName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !snapshot.awayTeamName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let selectionValid = snapshot.selectedTemplateID == nil
            || snapshot.templates.contains(where: { $0.id == snapshot.selectedTemplateID })
        let valid = namesValid && selectionValid
        RinkLensStructuredEventLogger.shared.record(
            domain: .teamIdentity,
            event: "team_identity_presentation_validated",
            entityID: snapshot.selectedTemplateID?.uuidString,
            previous: Self.summary(snapshot),
            next: Self.summary(snapshot).merging(["validation": valid ? "pass" : "fail"]) { _, new in new },
            source: source,
            reason: reason
        )
        return valid
    }

    private func mutate(
        event: String,
        entityID: String?,
        source: String,
        reason: String,
        _ change: (inout RinkLensTeamIdentitySnapshot) -> Void
    ) {
        let previous = snapshot
        var next = previous
        change(&next)
        guard Self.summary(previous) != Self.summary(next) else { return }
        snapshot = next
        guard RinkLensRiskFeaturePolicy.isEnabled(.teamIdentityAuthorityV2) else { return }
        RinkLensStructuredEventLogger.shared.record(
            domain: .teamIdentity,
            event: event,
            entityID: entityID,
            previous: Self.summary(previous),
            next: Self.summary(next),
            source: source,
            reason: reason
        )
    }

    private static func summary(_ state: RinkLensTeamIdentitySnapshot) -> [String: String] {
        [
            "homeTeamName": state.homeTeamName,
            "awayTeamName": state.awayTeamName,
            "homeLogoFile": state.homeLogoFileName ?? "none",
            "awayLogoFile": state.awayLogoFileName ?? "none",
            "homeLogoSize": imageSize(state.homeLogoImage),
            "awayLogoSize": imageSize(state.awayLogoImage),
            "homeLogoIdentity": imageIdentity(state.homeLogoImage),
            "awayLogoIdentity": imageIdentity(state.awayLogoImage),
            "templateCount": String(state.templates.count),
            "selectedTemplateID": state.selectedTemplateID?.uuidString ?? "none",
            "defaultTemplateID": state.defaultTemplateID?.uuidString ?? "none"
        ]
    }

    private static func imageSize(_ image: UIImage?) -> String {
        guard let image else { return "none" }
        return "\(Int(image.size.width))x\(Int(image.size.height))"
    }

    private static func imageIdentity(_ image: UIImage?) -> String {
        guard let image else { return "none" }
        return String(ObjectIdentifier(image).hashValue)
    }
}

// MARK: - Build 692 game clock authority

struct RinkLensGameClockAuthoritySnapshot: Equatable, Codable {
    var relayMetadataClock: String?
    var presentationClockText: String?
    var trustedAnchorSeconds: Int?
    var confirmedStopped: Bool = false
}

@MainActor
final class RinkLensGameClockAuthority: ObservableObject {
    @Published private(set) var snapshot = RinkLensGameClockAuthoritySnapshot()

    var relayMetadataClock: String? { snapshot.relayMetadataClock }
    var presentationClockText: String? { snapshot.presentationClockText }
    var trustedAnchorSeconds: Int? { snapshot.trustedAnchorSeconds }
    var confirmedStopped: Bool { snapshot.confirmedStopped }

    func setRelayMetadataClock(_ value: String?, source: String, reason: String) {
        mutate(event: "clock_relay_metadata_changed", source: source, reason: reason) { $0.relayMetadataClock = value }
    }

    func setPresentationClockText(_ value: String?, source: String, reason: String) {
        mutate(event: "clock_presentation_changed", source: source, reason: reason) { $0.presentationClockText = value }
    }

    func setTrustedAnchorSeconds(_ value: Int?, source: String, reason: String) {
        mutate(event: "clock_trusted_anchor_changed", source: source, reason: reason) { $0.trustedAnchorSeconds = value }
    }

    func setConfirmedStopped(_ value: Bool, source: String, reason: String) {
        mutate(event: "clock_stopped_state_changed", source: source, reason: reason) { $0.confirmedStopped = value }
    }

    func recordAcceptedTransition(previous: String?, next: String?, source: String, reason: String) {
        guard previous != next else { return }
        RinkLensStructuredEventLogger.shared.record(
            domain: .clock,
            event: "accepted_clock_transition",
            entityID: "scoreboard-state",
            previous: ["clock": previous ?? "none"],
            next: ["clock": next ?? "none"],
            source: source,
            reason: reason
        )
    }

    private func mutate(
        event: String,
        source: String,
        reason: String,
        _ change: (inout RinkLensGameClockAuthoritySnapshot) -> Void
    ) {
        let previous = snapshot
        var next = previous
        change(&next)
        guard previous != next else { return }
        snapshot = next
        guard RinkLensRiskFeaturePolicy.isEnabled(.gameClockAuthorityV2) else { return }
        RinkLensStructuredEventLogger.shared.record(
            domain: .clock,
            event: event,
            entityID: "game-clock",
            previous: Self.summary(previous),
            next: Self.summary(next),
            source: source,
            reason: reason
        )
    }

    private static func summary(_ state: RinkLensGameClockAuthoritySnapshot) -> [String: String] {
        [
            "relayMetadataClock": state.relayMetadataClock ?? "none",
            "presentationClockText": state.presentationClockText ?? "none",
            "trustedAnchorSeconds": state.trustedAnchorSeconds.map { String($0) } ?? "none",
            "confirmedStopped": String(state.confirmedStopped)
        ]
    }
}


// MARK: - Build 692 remaining domain owners

struct RinkLensCalibrationSnapshot: Equatable {
    var layout = ScoreboardOCRLayout()
    var boardCalibration = BoardCalibrationQuad()
    var colourProfiles: OCRColourProfileSet = .defaults
    var calibrationRotationDegrees: Double = 0
    var activeTemplateID: UUID?
    var isDirty = false
    var revision: UInt64 = 0
    var savedRevision: UInt64 = 0
}

@MainActor
final class RinkLensCalibrationStore: ObservableObject {
    @Published private(set) var snapshot = RinkLensCalibrationSnapshot()

    var layout: ScoreboardOCRLayout { snapshot.layout }
    var boardCalibration: BoardCalibrationQuad { snapshot.boardCalibration }
    var colourProfiles: OCRColourProfileSet { snapshot.colourProfiles }
    var calibrationRotationDegrees: Double { snapshot.calibrationRotationDegrees }
    var activeTemplateID: UUID? { snapshot.activeTemplateID }
    var isDirty: Bool { snapshot.isDirty }

    func setLayout(_ value: ScoreboardOCRLayout, source: String, reason: String) {
        if RinkLensRiskFeaturePolicy.isEnabled(.calibrationProfileAuthorityV2),
           snapshot.layout.isApproximatelyEqual(to: value) {
            return
        }
        mutate(event: "calibration_layout_changed", source: source, reason: reason) { $0.layout = value; $0.isDirty = true }
    }
    func setBoardCalibration(_ value: BoardCalibrationQuad, source: String, reason: String) {
        mutate(event: "calibration_perspective_changed", source: source, reason: reason) { $0.boardCalibration = value; $0.isDirty = true }
    }
    func setColourProfiles(_ value: OCRColourProfileSet, source: String, reason: String) {
        mutate(event: "calibration_colours_changed", source: source, reason: reason) { $0.colourProfiles = value; $0.isDirty = true }
    }
    func setCalibrationRotation(_ value: Double, source: String, reason: String) {
        mutate(event: "calibration_rotation_changed", source: source, reason: reason) { $0.calibrationRotationDegrees = value; $0.isDirty = true }
    }
    func setActiveTemplateID(_ id: UUID?, source: String, reason: String) {
        mutate(event: "rink_profile_selection_changed", source: source, reason: reason, markRevision: false) { $0.activeTemplateID = id }
    }
    func setDirty(_ dirty: Bool, source: String, reason: String) {
        mutate(event: dirty ? "calibration_marked_dirty" : "calibration_marked_clean", source: source, reason: reason, markRevision: false) { $0.isDirty = dirty }
    }
    func applyProfile(
        layout: ScoreboardOCRLayout,
        boardCalibration: BoardCalibrationQuad,
        colourProfiles: OCRColourProfileSet,
        calibrationRotationDegrees: Double,
        activeTemplateID: UUID?,
        source: String,
        reason: String
    ) {
        mutate(event: "rink_profile_applied", source: source, reason: reason) { state in
            state.layout = layout
            state.boardCalibration = boardCalibration
            state.colourProfiles = colourProfiles
            state.calibrationRotationDegrees = calibrationRotationDegrees
            state.activeTemplateID = activeTemplateID
            state.isDirty = false
            state.savedRevision = state.revision + 1
        }
    }
    func markSaved(activeTemplateID: UUID?, source: String, reason: String) {
        mutate(event: "rink_profile_saved", source: source, reason: reason, markRevision: false) { state in
            state.activeTemplateID = activeTemplateID
            state.isDirty = false
            state.savedRevision = state.revision
        }
    }

    private func mutate(event: String, source: String, reason: String, markRevision: Bool = true, _ change: (inout RinkLensCalibrationSnapshot) -> Void) {
        let previous = snapshot
        var next = previous
        change(&next)
        guard previous != next else { return }
        if markRevision { next.revision &+= 1 }
        snapshot = next
        guard RinkLensRiskFeaturePolicy.isEnabled(.calibrationProfileAuthorityV2) else { return }
        RinkLensStructuredEventLogger.shared.record(
            domain: event.hasPrefix("rink_profile") ? .rinkProfile : .calibration,
            event: event,
            entityID: next.activeTemplateID?.uuidString,
            previous: Self.summary(previous),
            next: Self.summary(next),
            source: source,
            reason: reason
        )
    }

    private static func summary(_ state: RinkLensCalibrationSnapshot) -> [String: String] {
        [
            "activeTemplateID": state.activeTemplateID?.uuidString ?? "none",
            "layoutHash": String(state.layout.hashValue),
            "perspectiveHash": String(state.boardCalibration.hashValue),
            "colourHash": String(state.colourProfiles.hashValue),
            "calibrationRotation": String(state.calibrationRotationDegrees),
            "dirty": String(state.isDirty),
            "revision": String(state.revision),
            "savedRevision": String(state.savedRevision)
        ]
    }
}

struct RinkLensOCRConfigurationSnapshot: Equatable {
    var thresholds = OCRThresholds()
    var scoreboardType: OCRScoreboardType = .standardIndoor
    var operatorMode: OCROperatorMode = .match
    var autoAssistEnabled = true
    var smartChangeDetectionEnabled = true
    var clockPreset: OCRZoneReadingPreset = .balanced
    var scorePreset: OCRZoneReadingPreset = .balanced
    var penaltyPreset: OCRZoneReadingPreset = .balanced
    var intervalSeconds: Double = 0.20
    var segmentedFallbackEnabled = false
    var smoothingEnabled = true
    var clockDirection: GameClockDirection = .auto
}

@MainActor
final class RinkLensOCRConfigurationStore: ObservableObject {
    @Published private(set) var snapshot = RinkLensOCRConfigurationSnapshot()

    func update(source: String, reason: String, _ change: (inout RinkLensOCRConfigurationSnapshot) -> Void) {
        let previous = snapshot
        var next = previous
        change(&next)
        guard previous != next else { return }
        snapshot = next
        guard RinkLensRiskFeaturePolicy.isEnabled(.ocrConfigurationAuthorityV2) else { return }
        RinkLensStructuredEventLogger.shared.record(
            domain: .ocrConfiguration,
            event: "ocr_configuration_changed",
            entityID: "operator-settings",
            previous: Self.summary(previous),
            next: Self.summary(next),
            source: source,
            reason: reason
        )
    }

    private static func summary(_ state: RinkLensOCRConfigurationSnapshot) -> [String: String] {
        [
            "scoreboardType": state.scoreboardType.rawValue,
            "operatorMode": state.operatorMode.rawValue,
            "autoAssist": String(state.autoAssistEnabled),
            "smartChange": String(state.smartChangeDetectionEnabled),
            "clockPreset": state.clockPreset.rawValue,
            "scorePreset": state.scorePreset.rawValue,
            "penaltyPreset": state.penaltyPreset.rawValue,
            "intervalSeconds": String(state.intervalSeconds),
            "segmentedFallback": String(state.segmentedFallbackEnabled),
            "smoothing": String(state.smoothingEnabled),
            "clockDirection": state.clockDirection.rawValue
        ]
    }
}


@MainActor
final class RinkLensAcceptedOCREvidenceStore: ObservableObject {
    @Published private(set) var values: [OCRRegionKey: AcceptedOCRValueState] = [:]

    func replace(_ next: [OCRRegionKey: AcceptedOCRValueState], source: String, reason: String) {
        let previous = values
        guard previous != next else { return }
        values = next
        let changedKeys = Set(previous.keys).union(next.keys).filter { previous[$0] != next[$0] }
        for key in changedKeys.sorted(by: { $0.rawValue < $1.rawValue }) {
            RinkLensStructuredEventLogger.shared.record(
                domain: .ocr,
                event: "accepted_ocr_evidence_changed",
                entityID: key.rawValue,
                previous: Self.summary(previous[key]),
                next: Self.summary(next[key]),
                source: source,
                reason: reason
            )
        }
    }

    func clear(source: String, reason: String) {
        replace([:], source: source, reason: reason)
    }

    private static func summary(_ state: AcceptedOCRValueState?) -> [String: String] {
        guard let state else { return ["value": "none", "confidence": "0", "recognizer": "none", "updatedAt": "none"] }
        return [
            "value": state.acceptedText ?? "none",
            "confidence": String(state.lastConfidence),
            "recognizer": state.recognizerUsed.rawValue,
            "updatedAt": state.lastUpdated.map { ISO8601DateFormatter().string(from: $0) } ?? "none"
        ]
    }
}

struct RinkLensCameraControlSnapshot: Equatable {
    var calibrationProfile = CalibrationCameraProfile()
    var livePreviewRotationOffsetDegrees: CGFloat = 0
    var ocrPreviewRotationOffsetDegrees: CGFloat = 0
    var rotationLockEnabled = true
    var smoothBroadcastZoomTransitionsEnabled = true
    var broadcastZoomTransitionSpeed: BroadcastZoomTransitionSpeed = .normal
    var broadcastVideoStabilisationEnabled = true
    var broadcastProductionProfile: BroadcastProductionProfile = .smoothMotion
    var broadcastImageQualityPolicy: BroadcastImageQualityPolicy {
        broadcastProductionProfile.cameraPolicy
    }
    var confirmRecordingStop = true
    var broadcastZoomPresetFactors: [Double] = [0.5, 1.0, 2.0, 3.0]
    var broadcastTorchEnabled = false
    var showBroadcastCompositionGrid = false
    var showBroadcastLevelGuide = false
    var holdToLockBroadcastCamera = true
    var lockFocusOnHold = true
    var lockExposureOnHold = true
    var lockWhiteBalanceOnHold = false
}

@MainActor
final class RinkLensCameraControlStore: ObservableObject {
    /// Requested zoom and the one pending lens intent belong to the camera-control owner.
    /// This nested state component is the owner's implementation, not a mirrored copy.
    let zoomStore = RinkLensCameraZoomStore()
    @Published private(set) var snapshot: RinkLensCameraControlSnapshot
    private enum DefaultsKey {
        static let stabilisation = "rinklens.camera.broadcastVideoStabilisationEnabled"
        static let productionProfile = "rinklens.camera.broadcastProductionProfile"
        static let retiredImageQualityPolicy = "rinklens.camera.broadcastImageQualityPolicy"
        static let retiredStreamQualityProfile = "rinklens.streaming.qualityProfile"
        static let confirmStop = "rinklens.camera.confirmRecordingStop"
        static let zoomPresets = "rinklens.camera.broadcastZoomPresetFactors"
        static let torch = "rinklens.camera.broadcastTorchEnabled"
        static let grid = "rinklens.camera.showBroadcastCompositionGrid"
        static let level = "rinklens.camera.showBroadcastLevelGuide"
        static let holdToLock = "rinklens.camera.holdToLockBroadcastCamera"
        static let lockFocus = "rinklens.camera.lockFocusOnHold"
        static let lockExposure = "rinklens.camera.lockExposureOnHold"
        static let lockWhiteBalance = "rinklens.camera.lockWhiteBalanceOnHold"
    }

    init() {
        let defaults = UserDefaults.standard
        var initial = RinkLensCameraControlSnapshot()
        if defaults.object(forKey: DefaultsKey.stabilisation) != nil { initial.broadcastVideoStabilisationEnabled = defaults.bool(forKey: DefaultsKey.stabilisation) }
        if let raw = defaults.string(forKey: DefaultsKey.productionProfile),
           let profile = BroadcastProductionProfile(rawValue: raw) {
            initial.broadcastProductionProfile = profile
        } else {
            // RL-196 one-time migration: resolve the two retired independent
            // selections into one production profile, then delete both keys.
            let previousPolicy = defaults.string(forKey: DefaultsKey.retiredImageQualityPolicy)
                .flatMap(BroadcastImageQualityPolicy.init(rawValue:)) ?? .balanced
            let previousStreamProfile = defaults.string(forKey: DefaultsKey.retiredStreamQualityProfile) ?? ""
            if previousPolicy == .imageQualityPriority {
                initial.broadcastProductionProfile = .lowLight
            } else if previousStreamProfile == "720p60" {
                initial.broadcastProductionProfile = .reducedData
            } else if previousPolicy == .motionPriority {
                initial.broadcastProductionProfile = .smoothMotion
            } else {
                initial.broadcastProductionProfile = .balanced
            }
            defaults.set(initial.broadcastProductionProfile.rawValue, forKey: DefaultsKey.productionProfile)
        }
        defaults.removeObject(forKey: DefaultsKey.retiredImageQualityPolicy)
        defaults.removeObject(forKey: DefaultsKey.retiredStreamQualityProfile)
        if defaults.object(forKey: DefaultsKey.confirmStop) != nil { initial.confirmRecordingStop = defaults.bool(forKey: DefaultsKey.confirmStop) }
        if let values = defaults.array(forKey: DefaultsKey.zoomPresets) as? [Double], values.count == 4 { initial.broadcastZoomPresetFactors = Self.normalisedZoomPresets(values) }
        if defaults.object(forKey: DefaultsKey.torch) != nil { initial.broadcastTorchEnabled = defaults.bool(forKey: DefaultsKey.torch) }
        if defaults.object(forKey: DefaultsKey.grid) != nil { initial.showBroadcastCompositionGrid = defaults.bool(forKey: DefaultsKey.grid) }
        if defaults.object(forKey: DefaultsKey.level) != nil { initial.showBroadcastLevelGuide = defaults.bool(forKey: DefaultsKey.level) }
        if defaults.object(forKey: DefaultsKey.holdToLock) != nil { initial.holdToLockBroadcastCamera = defaults.bool(forKey: DefaultsKey.holdToLock) }
        if defaults.object(forKey: DefaultsKey.lockFocus) != nil { initial.lockFocusOnHold = defaults.bool(forKey: DefaultsKey.lockFocus) }
        if defaults.object(forKey: DefaultsKey.lockExposure) != nil { initial.lockExposureOnHold = defaults.bool(forKey: DefaultsKey.lockExposure) }
        if defaults.object(forKey: DefaultsKey.lockWhiteBalance) != nil { initial.lockWhiteBalanceOnHold = defaults.bool(forKey: DefaultsKey.lockWhiteBalance) }
        let retiredZoomIndicatorKey = "rinklens.camera.showBroadcastZoomIndicator"
        let retiredZoomIndicatorValue = defaults.object(forKey: retiredZoomIndicatorKey)
        defaults.removeObject(forKey: retiredZoomIndicatorKey)
        snapshot = initial
        if let retiredZoomIndicatorValue {
            RinkLensStructuredEventLogger.shared.record(
                domain: .cameraControl,
                event: "camera_zoom_indicator_state_retired",
                entityID: "broadcast-zoom-indicator",
                previous: ["persistedValue": String(describing: retiredZoomIndicatorValue)],
                next: ["state": "deleted", "overlay": "deleted", "operatorControl": "deleted"],
                source: "RinkLensCameraControlStore.init",
                reason: "Build 765 permanently removes the top-centre zoom indicator and its saved setting",
                authoritativeOwner: "RinkLensCameraControlStore"
            )
        }
    }

    func setCalibrationProfile(_ value: CalibrationCameraProfile, source: String, reason: String) {
        mutate(event: "camera_profile_requested", source: source, reason: reason) { $0.calibrationProfile = value }
    }
    func setLivePreviewRotation(_ value: CGFloat, source: String, reason: String) {
        mutate(event: "camera_live_rotation_requested", source: source, reason: reason) { $0.livePreviewRotationOffsetDegrees = value }
    }
    func setOCRPreviewRotation(_ value: CGFloat, source: String, reason: String) {
        mutate(event: "camera_ocr_rotation_requested", source: source, reason: reason) { $0.ocrPreviewRotationOffsetDegrees = value }
    }
    func setRotationLockEnabled(_ value: Bool, source: String, reason: String) {
        mutate(event: "camera_rotation_lock_changed", source: source, reason: reason) { $0.rotationLockEnabled = value }
    }
    func setSmoothBroadcastZoomTransitionsEnabled(_ value: Bool, source: String, reason: String) {
        mutate(event: "camera_smooth_zoom_changed", source: source, reason: reason) { $0.smoothBroadcastZoomTransitionsEnabled = value }
    }
    func setBroadcastZoomTransitionSpeed(_ value: BroadcastZoomTransitionSpeed, source: String, reason: String) {
        mutate(event: "camera_zoom_transition_speed_changed", source: source, reason: reason) { $0.broadcastZoomTransitionSpeed = value }
    }
    func setBroadcastVideoStabilisationEnabled(_ value: Bool, source: String, reason: String) {
        mutate(event: "camera_broadcast_stabilisation_requested", source: source, reason: reason) { $0.broadcastVideoStabilisationEnabled = value }
        UserDefaults.standard.set(value, forKey: DefaultsKey.stabilisation)
    }

    func setBroadcastProductionProfile(_ value: BroadcastProductionProfile, source: String, reason: String) {
        mutate(event: "broadcast_production_profile_changed", source: source, reason: reason) { $0.broadcastProductionProfile = value }
        UserDefaults.standard.set(value.rawValue, forKey: DefaultsKey.productionProfile)
    }

    func setConfirmRecordingStop(_ value: Bool, source: String, reason: String) { persist(value, key: DefaultsKey.confirmStop, event: "recording_stop_confirmation_changed", source: source, reason: reason) { $0.confirmRecordingStop = value } }
    func setBroadcastZoomPreset(_ value: Double, at index: Int, source: String, reason: String) {
        guard snapshot.broadcastZoomPresetFactors.indices.contains(index) else { return }
        mutate(event: "camera_zoom_preset_changed", source: source, reason: reason) { state in
            state.broadcastZoomPresetFactors[index] = min(max(value, 0.5), 5.0)
            state.broadcastZoomPresetFactors = Self.normalisedZoomPresets(state.broadcastZoomPresetFactors)
        }
        UserDefaults.standard.set(snapshot.broadcastZoomPresetFactors, forKey: DefaultsKey.zoomPresets)
    }
    func setBroadcastTorchEnabled(_ value: Bool, source: String, reason: String) { persist(value, key: DefaultsKey.torch, event: "camera_broadcast_torch_requested", source: source, reason: reason) { $0.broadcastTorchEnabled = value } }
    func setShowBroadcastCompositionGrid(_ value: Bool, source: String, reason: String) { persist(value, key: DefaultsKey.grid, event: "camera_composition_grid_changed", source: source, reason: reason) { $0.showBroadcastCompositionGrid = value } }
    func setShowBroadcastLevelGuide(_ value: Bool, source: String, reason: String) { persist(value, key: DefaultsKey.level, event: "camera_level_guide_changed", source: source, reason: reason) { $0.showBroadcastLevelGuide = value } }
    func setHoldToLockBroadcastCamera(_ value: Bool, source: String, reason: String) { persist(value, key: DefaultsKey.holdToLock, event: "camera_hold_to_lock_changed", source: source, reason: reason) { $0.holdToLockBroadcastCamera = value } }
    func setLockFocusOnHold(_ value: Bool, source: String, reason: String) { persist(value, key: DefaultsKey.lockFocus, event: "camera_hold_focus_policy_changed", source: source, reason: reason) { $0.lockFocusOnHold = value } }
    func setLockExposureOnHold(_ value: Bool, source: String, reason: String) { persist(value, key: DefaultsKey.lockExposure, event: "camera_hold_exposure_policy_changed", source: source, reason: reason) { $0.lockExposureOnHold = value } }
    func setLockWhiteBalanceOnHold(_ value: Bool, source: String, reason: String) { persist(value, key: DefaultsKey.lockWhiteBalance, event: "camera_hold_white_balance_policy_changed", source: source, reason: reason) { $0.lockWhiteBalanceOnHold = value } }

    private func persist(_ value: Bool, key: String, event: String, source: String, reason: String, change: (inout RinkLensCameraControlSnapshot) -> Void) {
        mutate(event: event, source: source, reason: reason, change)
        UserDefaults.standard.set(value, forKey: key)
    }

    private static func normalisedZoomPresets(_ values: [Double]) -> [Double] {
        let defaults = [0.5, 1.0, 2.0, 3.0]
        return (0..<4).map { index in min(max(index < values.count ? values[index] : defaults[index], 0.5), 5.0) }
    }

    private func mutate(event: String, source: String, reason: String, _ change: (inout RinkLensCameraControlSnapshot) -> Void) {
        let previous = snapshot
        var next = previous
        change(&next)
        guard previous != next else { return }
        snapshot = next
        RinkLensStructuredEventLogger.shared.record(
            domain: .cameraControl,
            event: event,
            entityID: "requested-camera-controls",
            previous: Self.summary(previous),
            next: Self.summary(next),
            source: source,
            reason: reason
        )
    }

    private static func summary(_ state: RinkLensCameraControlSnapshot) -> [String: String] {
        [
            "profileHash": String(state.calibrationProfile.hashValue),
            "selectedDevice": state.calibrationProfile.selectedCameraSourceID ?? "none",
            "liveRotation": String(Double(state.livePreviewRotationOffsetDegrees)),
            "ocrRotation": String(Double(state.ocrPreviewRotationOffsetDegrees)),
            "rotationLock": String(state.rotationLockEnabled),
            "smoothZoom": String(state.smoothBroadcastZoomTransitionsEnabled),
            "zoomSpeed": state.broadcastZoomTransitionSpeed.rawValue,
            "broadcastStabilisation": String(state.broadcastVideoStabilisationEnabled),
            "productionProfile": state.broadcastProductionProfile.rawValue,
            "imageQualityPolicy": state.broadcastImageQualityPolicy.rawValue,
            "confirmRecordingStop": String(state.confirmRecordingStop),
            "zoomPresets": state.broadcastZoomPresetFactors.map { String(format: "%.1f", $0) }.joined(separator: ","),
            "torch": String(state.broadcastTorchEnabled),
            "grid": String(state.showBroadcastCompositionGrid),
            "level": String(state.showBroadcastLevelGuide),
            "holdToLock": String(state.holdToLockBroadcastCamera),
            "lockFocus": String(state.lockFocusOnHold),
            "lockExposure": String(state.lockExposureOnHold),
            "lockWhiteBalance": String(state.lockWhiteBalanceOnHold)
        ]
    }
}


struct RinkLensScoreboardDefaultsSnapshot: Equatable {
    var clock: String = "20:00"
    var homeGoals: Int = 0
    var awayGoals: Int = 0
    var periodOption: String = "1"
    var period: Int = 1
    var homePenalty1Player: Int = 0
    var homePenalty1Clock: String = "--:--"
    var homePenalty2Player: Int = 0
    var homePenalty2Clock: String = "--:--"
    var awayPenalty1Player: Int = 0
    var awayPenalty1Clock: String = "--:--"
    var awayPenalty2Player: Int = 0
    var awayPenalty2Clock: String = "--:--"
}

@MainActor
final class RinkLensScoreboardDefaultsStore: ObservableObject {
    @Published private(set) var snapshot = RinkLensScoreboardDefaultsSnapshot()

    func mutate(source: String, reason: String, _ change: (inout RinkLensScoreboardDefaultsSnapshot) -> Void) {
        let previous = snapshot
        var next = previous
        change(&next)
        guard previous != next else { return }
        snapshot = next
        RinkLensStructuredEventLogger.shared.record(
            domain: .match,
            event: "scoreboard_defaults_changed",
            entityID: "new-game-defaults",
            previous: Self.summary(previous),
            next: Self.summary(next),
            source: source,
            reason: reason
        )
    }

    private static func summary(_ state: RinkLensScoreboardDefaultsSnapshot) -> [String: String] {
        [
            "clock": state.clock,
            "score": "\(state.homeGoals)-\(state.awayGoals)",
            "period": state.periodOption,
            "homeP1": "\(state.homePenalty1Player)@\(state.homePenalty1Clock)",
            "homeP2": "\(state.homePenalty2Player)@\(state.homePenalty2Clock)",
            "awayP1": "\(state.awayPenalty1Player)@\(state.awayPenalty1Clock)",
            "awayP2": "\(state.awayPenalty2Player)@\(state.awayPenalty2Clock)"
        ]
    }
}

enum RinkLensScoreboardInputLifecycleState: String, Codable, Equatable {
    case stoppedByOperator
    case armed
    case starting
    case stopping
    case running
    case waitingForCapture
    case suspendedByRoute
    case failed
}

struct RinkLensScoreboardInputLifecycleSnapshot: Equatable {
    var state: RinkLensScoreboardInputLifecycleState = .armed
    var operatorRequestedRunning = false
    var processingPaused = true
    var resumeAfterRouteSuspension = false
    var mode = "imageRelay"
    var failureReason: String?
    var hasStartedThisSession = false
    var revision: UInt64 = 0

    var shouldRun: Bool {
        operatorRequestedRunning
            && (state == .waitingForCapture || (!processingPaused && [.starting, .running].contains(state)))
    }

    var isTransitioning: Bool {
        state == .starting || state == .stopping
    }
}

@MainActor
final class RinkLensScoreboardInputLifecycleStore: ObservableObject {
    @Published private(set) var snapshot = RinkLensScoreboardInputLifecycleSnapshot()

    /// Build 753: selected input mode and run state commit as one authoritative
    /// transaction. Screens request a mode; they never infer it from manual-score
    /// protection or keep a separate "was running" flag.
    @discardableResult
    func selectMode(_ mode: String, source: String, reason: String) -> Bool {
        guard mode == "imageRelay" || mode == "manual" else {
            RinkLensStructuredEventLogger.shared.record(
                domain: .scoreboardInput,
                event: "scoreboard_input_mode_rejected",
                entityID: mode,
                previous: Self.summary(snapshot),
                next: Self.summary(snapshot),
                source: source,
                reason: "Unsupported scoreboard input mode — \(reason)"
            )
            return false
        }
        let previous = snapshot
        mutate(event: "scoreboard_input_mode_transition", source: source, reason: reason) { state in
            state.mode = mode
            state.state = mode == "manual" ? .stoppedByOperator : .armed
            state.operatorRequestedRunning = false
            state.processingPaused = true
            state.resumeAfterRouteSuspension = false
            state.failureReason = nil
        }
        return previous != snapshot
    }

    func arm(mode: String, source: String, reason: String) {
        mutate(event: "scoreboard_input_armed", source: source, reason: reason) { state in
            state.state = .armed
            state.mode = mode
            state.operatorRequestedRunning = false
            state.processingPaused = true
            state.resumeAfterRouteSuspension = false
            state.failureReason = nil
        }
    }

    @discardableResult
    func operatorStart(mode: String, source: String, reason: String) -> Bool {
        guard !(snapshot.operatorRequestedRunning && [.starting, .running, .waitingForCapture].contains(snapshot.state)) else {
            RinkLensStructuredEventLogger.shared.record(
                domain: .scoreboardInput,
                event: "scoreboard_input_command_coalesced",
                entityID: snapshot.mode,
                previous: Self.summary(snapshot),
                next: Self.summary(snapshot),
                source: source,
                reason: "Duplicate Start ignored — \(reason)"
            )
            return false
        }
        mutate(event: "scoreboard_input_start_requested", source: source, reason: reason) { state in
            state.state = .starting
            state.mode = mode
            state.operatorRequestedRunning = true
            state.processingPaused = false
            state.resumeAfterRouteSuspension = false
            state.failureReason = nil
            state.hasStartedThisSession = true
        }
        return true
    }

    func markRunning(source: String, reason: String) {
        mutate(event: "scoreboard_input_running", source: source, reason: reason) { state in
            guard state.operatorRequestedRunning else { return }
            state.state = .running
            state.processingPaused = false
            state.failureReason = nil
        }
    }

    /// The operator's run intent remains authoritative while CaptureEngine is
    /// physically unable to provide the OCR branch. In particular, an open
    /// RecordingWriter contract forbids hot graph mutation; writer-close
    /// reconciliation can still observe `shouldRun` and restore the branch.
    func waitForCapture(source: String, reason: String) {
        mutate(event: "scoreboard_input_waiting_for_capture", source: source, reason: reason) { state in
            guard state.mode == "imageRelay", state.operatorRequestedRunning else { return }
            state.state = .waitingForCapture
            state.processingPaused = true
            state.failureReason = nil
        }
    }

    @discardableResult
    func operatorStop(source: String, reason: String) -> Bool {
        guard snapshot.state != .stoppedByOperator && snapshot.state != .stopping else {
            RinkLensStructuredEventLogger.shared.record(
                domain: .scoreboardInput,
                event: "scoreboard_input_command_coalesced",
                entityID: snapshot.mode,
                previous: Self.summary(snapshot),
                next: Self.summary(snapshot),
                source: source,
                reason: "Duplicate Stop ignored — \(reason)"
            )
            return false
        }
        mutate(event: "scoreboard_input_stop_requested", source: source, reason: reason) { state in
            state.state = .stopping
            state.operatorRequestedRunning = false
            state.processingPaused = true
            state.resumeAfterRouteSuspension = false
            state.failureReason = nil
        }
        return true
    }

    func markStopped(source: String, reason: String) {
        mutate(event: "scoreboard_input_stopped_by_operator", source: source, reason: reason) { state in
            state.state = .stoppedByOperator
            state.operatorRequestedRunning = false
            state.processingPaused = true
            state.resumeAfterRouteSuspension = false
            state.failureReason = nil
        }
    }

    func suspendForRoute(source: String, reason: String) {
        let wasRequested = snapshot.operatorRequestedRunning
            || snapshot.state == .running
            || snapshot.state == .starting
        guard wasRequested else { return }
        mutate(event: "scoreboard_input_suspended_by_route", source: source, reason: reason) { state in
            state.state = .suspendedByRoute
            state.processingPaused = true
            state.resumeAfterRouteSuspension = true
            state.operatorRequestedRunning = true
            state.failureReason = nil
        }
    }

    @discardableResult
    func resumeFromRoute(source: String, reason: String) -> Bool {
        let shouldResume = snapshot.state == .suspendedByRoute && snapshot.resumeAfterRouteSuspension
        mutate(event: "scoreboard_input_route_resume_decided", source: source, reason: reason) { state in
            if shouldResume {
                state.state = .starting
                state.operatorRequestedRunning = true
                state.processingPaused = false
            } else if state.state == .suspendedByRoute {
                state.state = .armed
                state.operatorRequestedRunning = false
                state.processingPaused = true
            }
            state.resumeAfterRouteSuspension = false
        }
        return shouldResume
    }

    /// Build 753 compatibility command boundary. Existing internal call sites
    /// still assign the historical projections, but the enabled path commits the
    /// intent into this lifecycle owner rather than a second operational store.
    func setOperatorRequestedRunning(_ requested: Bool, source: String, reason: String) {
        mutate(event: "scoreboard_input_run_intent_changed", source: source, reason: reason) { state in
            if requested {
                guard state.mode == "imageRelay" else { return }
                state.operatorRequestedRunning = true
                if [.armed, .stoppedByOperator, .failed].contains(state.state) {
                    state.state = .starting
                    state.failureReason = nil
                }
            } else {
                state.operatorRequestedRunning = false
                state.processingPaused = true
                state.resumeAfterRouteSuspension = false
                if state.state != .suspendedByRoute && state.state != .stopping {
                    state.state = .stoppedByOperator
                }
            }
        }
    }

    func setProcessingPaused(_ paused: Bool, source: String, reason: String) {
        mutate(event: "scoreboard_input_processing_pause_changed", source: source, reason: reason) { state in
            if !paused {
                guard state.mode == "imageRelay", state.operatorRequestedRunning else { return }
            }
            state.processingPaused = paused
            if !paused,
               [.armed, .stoppedByOperator, .waitingForCapture, .failed].contains(state.state) {
                state.state = .starting
                state.failureReason = nil
            }
        }
    }

    func fail(_ failure: String, source: String, reason: String) {
        mutate(event: "scoreboard_input_failed", source: source, reason: reason) { state in
            state.state = .failed
            state.processingPaused = true
            state.failureReason = failure
        }
    }

    private func mutate(event: String, source: String, reason: String, _ change: (inout RinkLensScoreboardInputLifecycleSnapshot) -> Void) {
        let previous = snapshot
        var next = previous
        change(&next)
        guard previous != next else { return }
        next.revision = previous.revision &+ 1
        snapshot = next
        guard RinkLensRiskFeaturePolicy.isEnabled(.scoreboardInputLifecycleV2) else { return }
        RinkLensStructuredEventLogger.shared.record(
            domain: .scoreboardInput,
            event: event,
            entityID: next.mode,
            previous: Self.summary(previous),
            next: Self.summary(next),
            source: source,
            reason: reason
        )
    }

    private static func summary(_ state: RinkLensScoreboardInputLifecycleSnapshot) -> [String: String] {
        [
            "state": state.state.rawValue,
            "operatorRequestedRunning": String(state.operatorRequestedRunning),
            "processingPaused": String(state.processingPaused),
            "resumeAfterRouteSuspension": String(state.resumeAfterRouteSuspension),
            "mode": state.mode,
            "failure": state.failureReason ?? "none",
            "hasStartedThisSession": String(state.hasStartedThisSession),
            "transitioning": String(state.isTransitioning),
            "revision": String(state.revision)
        ]
    }
}

/// Legacy scoreboard capture/OCR projection. This is deliberately not the
/// visible NextGen route authority; AppCoordinator owns navigation.
struct RinkLensOperationalStateSnapshot: Equatable {
    var currentScreen: AppScreen = .calibration
    var isScreenTransitioning = false
}

@MainActor
final class RinkLensOperationalStateStore: ObservableObject {
    @Published private(set) var snapshot = RinkLensOperationalStateSnapshot()

    func update(source: String, reason: String, _ change: (inout RinkLensOperationalStateSnapshot) -> Void) {
        let previous = snapshot
        var next = previous
        change(&next)
        guard previous != next else { return }
        snapshot = next
        guard RinkLensRiskFeaturePolicy.isEnabled(.operationalStateAuthorityV2) else { return }
        RinkLensStructuredEventLogger.shared.record(
            domain: .capture,
            event: "operational_state_changed",
            entityID: next.currentScreen.rawValue,
            previous: Self.summary(previous),
            next: Self.summary(next),
            source: source,
            reason: reason
        )
    }

    private static func summary(_ state: RinkLensOperationalStateSnapshot) -> [String: String] {
        [
            "screen": state.currentScreen.rawValue,
            "transitioning": String(state.isScreenTransitioning)
        ]
    }
}

enum RinkLensGameEventLifecycleStage: String, Codable {
    case detected
    case validated
    case heldForRestart
    case eligible
    case queued
    case displayed
    case completed
    case cancelled
    case suppressed
}


struct RinkLensRelayPendingEvent {
    var event: BroadcastEvent
    var priority: Int
    var observedAt: CFAbsoluteTime
    var scoreTeam: Team?
    var scoreBaseline: Int?
    var scoreExpected: Int?

    init(
        event: BroadcastEvent,
        priority: Int,
        observedAt: CFAbsoluteTime,
        scoreTeam: Team? = nil,
        scoreBaseline: Int? = nil,
        scoreExpected: Int? = nil
    ) {
        self.event = event
        self.priority = priority
        self.observedAt = observedAt
        self.scoreTeam = scoreTeam
        self.scoreBaseline = scoreBaseline
        self.scoreExpected = scoreExpected
    }

    var isProvisionalGoal: Bool {
        scoreTeam != nil && scoreBaseline != nil && scoreExpected != nil
    }
}

struct RinkLensGameEventLifecycleRecord: Equatable {
    var event: BroadcastEvent
    var stage: RinkLensGameEventLifecycleStage
    var updatedAt: Date
    var reason: String
}

/// Immutable event-boundary evidence captured only when the physical Clock is
/// verified running. It is not a live score mirror and never renders directly.
struct RinkLensRunningScoreBaseline: Equatable {
    let home: Int?
    let away: Int?
    let capturedAt: CFAbsoluteTime
    let captureGeneration: Int
}

/// Event-lifecycle-owned evidence for a sequential score value first seen while
/// the physical Clock was running. It is not a score mirror and cannot render.
/// A stopped-board candidate must prove a materially different glyph before the
/// lifecycle owner releases it to the score metadata reducer.
struct RinkLensStoppedBoardScoreAdmission: Equatable {
    let team: Team
    let baseline: Int
    let proposed: Int
    let runningGlyphHash: UInt64
    let runningObservedAt: CFAbsoluteTime
    let captureGeneration: Int
    var stoppedGlyphHash: UInt64?
    var stoppedConfirmationCount: Int
    var stoppedFirstObservedAt: CFAbsoluteTime?
    var lastObservedAt: CFAbsoluteTime
    var unchangedGlyphHoldLogged: Bool
}

struct RinkLensRelayPendingEventAdmission {
    let admitted: Bool
    let existingEventID: UUID?
    let fingerprint: String
}

/// Immutable Clock presentation evidence bound to exactly one physical stoppage.
/// It is owned by the event lifecycle, never by a screen or popup view.
struct RinkLensStoppedClockEvidence: Equatable {
    let stoppageID: UUID
    let imagePNGData: Data?
    let imageHash: UInt64?
    let observedAt: CFAbsoluteTime
    let captureGeneration: Int
    let sourceSequence: Int?
    let source: String
}

@MainActor
final class RinkLensGameEventLifecycleStore: ObservableObject {
    static let shared = RinkLensGameEventLifecycleStore()

    @Published private(set) var records: [UUID: RinkLensGameEventLifecycleRecord] = [:]
    @Published private(set) var relayPendingEvents: [RinkLensRelayPendingEvent] = []
    @Published private(set) var stoppedClockPendingEvents: [BroadcastEvent] = []
    private(set) var stoppedClockEligibleAt: [UUID: Date] = [:]
    private(set) var goalScoreConfirmationCount: [UUID: Int] = [:]
    private(set) var goalLastObservationID: [UUID: UInt64] = [:]
    @Published private(set) var runningScoreBaseline: RinkLensRunningScoreBaseline?
    @Published private(set) var stoppedBoardScoreAdmissions: [Team: RinkLensStoppedBoardScoreAdmission] = [:]
    @Published private(set) var activeStoppageID: UUID?
    @Published private(set) var stoppedClockEvidenceByStoppageID: [UUID: RinkLensStoppedClockEvidence] = [:]
    private var canonicalEventIDByFingerprint: [String: UUID] = [:]
    private let retainedLimit = 160

    var activeStoppedClockEvidence: RinkLensStoppedClockEvidence? {
        guard let activeStoppageID else { return nil }
        return stoppedClockEvidenceByStoppageID[activeStoppageID]
    }

    @discardableResult
    func commitStoppedClockEvidence(
        stoppageID: UUID,
        imagePNGData: Data?,
        observedAt: CFAbsoluteTime,
        captureGeneration: Int,
        sourceSequence: Int?,
        source: String,
        reason: String
    ) -> RinkLensStoppedClockEvidence {
        let previousActive = activeStoppedClockEvidence
        let next = RinkLensStoppedClockEvidence(
            stoppageID: stoppageID,
            imagePNGData: imagePNGData,
            imageHash: imagePNGData.map(Self.fnv1a64),
            observedAt: observedAt,
            captureGeneration: captureGeneration,
            sourceSequence: sourceSequence,
            source: source
        )
        activeStoppageID = stoppageID
        stoppedClockEvidenceByStoppageID[stoppageID] = next
        if stoppedClockEvidenceByStoppageID.count > 24 {
            let retained = stoppedClockEvidenceByStoppageID.values
                .sorted { $0.observedAt > $1.observedAt }
                .prefix(24)
            stoppedClockEvidenceByStoppageID = Dictionary(
                uniqueKeysWithValues: retained.map { ($0.stoppageID, $0) }
            )
        }
        RinkLensStructuredEventLogger.shared.record(
            domain: .gameEvent,
            event: "stoppage_clock_evidence_committed",
            entityID: stoppageID.uuidString,
            previous: [
                "stoppageID": previousActive?.stoppageID.uuidString ?? "none",
                "imageHash": previousActive?.imageHash.map { String($0) } ?? "none",
                "observedAt": previousActive.map { String(format: "%.3f", $0.observedAt) } ?? "none",
                "source": previousActive?.source ?? "none"
            ],
            next: [
                "stoppageID": stoppageID.uuidString,
                "imageHash": next.imageHash.map { String($0) } ?? "none",
                "observedAt": String(format: "%.3f", observedAt),
                "source": source,
                "sourceSequence": sourceSequence.map { String($0) } ?? "none"
            ],
            source: "RinkLensGameEventLifecycleStore",
            reason: reason,
            captureGeneration: captureGeneration,
            stoppageID: stoppageID
        )
        return next
    }

    func stoppedClockEvidence(for stoppageID: UUID?) -> RinkLensStoppedClockEvidence? {
        guard let stoppageID else { return nil }
        return stoppedClockEvidenceByStoppageID[stoppageID]
    }

    func clearStoppedClockEvidence(source: String, reason: String) {
        let previous = activeStoppedClockEvidence
        activeStoppageID = nil
        stoppedClockEvidenceByStoppageID.removeAll(keepingCapacity: true)
        guard previous != nil else { return }
        RinkLensStructuredEventLogger.shared.record(
            domain: .gameEvent,
            event: "stoppage_clock_evidence_cleared",
            entityID: previous?.stoppageID.uuidString,
            previous: [
                "stoppageID": previous?.stoppageID.uuidString ?? "none",
                "imageHash": previous?.imageHash.map { String($0) } ?? "none"
            ],
            next: ["stoppageID": "none", "imageHash": "none"],
            source: source,
            reason: reason,
            captureGeneration: previous?.captureGeneration,
            stoppageID: previous?.stoppageID
        )
    }

    private static func fnv1a64(_ data: Data) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    func captureRunningScoreBaseline(
        home: Int?,
        away: Int?,
        observedAt: CFAbsoluteTime,
        captureGeneration: Int,
        source: String,
        reason: String
    ) {
        let previous = runningScoreBaseline
        let next = RinkLensRunningScoreBaseline(
            home: home,
            away: away,
            capturedAt: observedAt,
            captureGeneration: captureGeneration
        )
        runningScoreBaseline = next
        guard previous?.home != next.home || previous?.away != next.away else { return }
        RinkLensStructuredEventLogger.shared.record(
            domain: .gameEvent,
            event: "running_score_event_boundary_changed",
            entityID: "verified-running-score",
            previous: [
                "home": previous?.home.map { String($0) } ?? "none",
                "away": previous?.away.map { String($0) } ?? "none",
                "capturedAt": previous.map { String(format: "%.3f", $0.capturedAt) } ?? "none"
            ],
            next: [
                "home": next.home.map { String($0) } ?? "none",
                "away": next.away.map { String($0) } ?? "none",
                "capturedAt": String(format: "%.3f", next.capturedAt)
            ],
            source: source,
            reason: reason,
            captureGeneration: captureGeneration
        )
    }

    func holdRunningScoreCandidate(
        team: Team,
        baseline: Int,
        proposed: Int,
        glyphHash: UInt64,
        observedAt: CFAbsoluteTime,
        captureGeneration: Int,
        source: String,
        reason: String
    ) {
        let previous = stoppedBoardScoreAdmissions[team]
        let next = RinkLensStoppedBoardScoreAdmission(
            team: team,
            baseline: baseline,
            proposed: proposed,
            runningGlyphHash: glyphHash,
            runningObservedAt: observedAt,
            captureGeneration: captureGeneration,
            stoppedGlyphHash: nil,
            stoppedConfirmationCount: 0,
            stoppedFirstObservedAt: nil,
            lastObservedAt: observedAt,
            unchangedGlyphHoldLogged: false
        )
        guard previous?.baseline != baseline
                || previous?.proposed != proposed
                || previous?.runningGlyphHash != glyphHash
                || previous?.captureGeneration != captureGeneration else { return }
        stoppedBoardScoreAdmissions[team] = next
        RinkLensStructuredEventLogger.shared.record(
            domain: .gameEvent,
            event: "running_score_candidate_held",
            entityID: team.rawValue,
            previous: [
                "baseline": previous.map { String($0.baseline) } ?? "none",
                "proposed": previous.map { String($0.proposed) } ?? "none",
                "runningGlyphHash": previous.map { String($0.runningGlyphHash) } ?? "none"
            ],
            next: [
                "baseline": String(baseline),
                "proposed": String(proposed),
                "runningGlyphHash": String(glyphHash),
                "admitted": "false"
            ],
            source: source,
            reason: reason,
            captureGeneration: captureGeneration,
            authoritativeOwner: "RinkLensGameEventLifecycleStore"
        )
    }

    /// Returns true only after two stopped-board observations agree and their
    /// physical glyph is materially different from the running candidate glyph.
    func observeStoppedBoardScoreCandidate(
        team: Team,
        baseline: Int,
        proposed: Int,
        glyphHash: UInt64,
        observedAt: CFAbsoluteTime,
        captureGeneration: Int,
        source: String,
        reason: String
    ) -> Bool {
        guard var admission = stoppedBoardScoreAdmissions[team] else {
            return true // Candidate first appeared while stopped; existing stopped policy applies.
        }
        guard admission.baseline == baseline,
              admission.proposed == proposed,
              admission.captureGeneration == captureGeneration else {
            stoppedBoardScoreAdmissions[team] = nil
            RinkLensStructuredEventLogger.shared.record(
                domain: .gameEvent,
                event: "stopped_score_candidate_invalidated",
                entityID: team.rawValue,
                previous: [
                    "baseline": String(admission.baseline),
                    "proposed": String(admission.proposed),
                    "generation": String(admission.captureGeneration)
                ],
                next: [
                    "baseline": String(baseline),
                    "proposed": String(proposed),
                    "generation": String(captureGeneration),
                    "admitted": "false"
                ],
                source: source,
                reason: "Running score candidate no longer belongs to the same score/generation transaction",
                captureGeneration: captureGeneration,
                authoritativeOwner: "RinkLensGameEventLifecycleStore"
            )
            return false
        }
        let physicalDistance = (admission.runningGlyphHash ^ glyphHash).nonzeroBitCount
        guard physicalDistance >= 3 else {
            if !admission.unchangedGlyphHoldLogged {
                admission.unchangedGlyphHoldLogged = true
                admission.lastObservedAt = observedAt
                stoppedBoardScoreAdmissions[team] = admission
                RinkLensStructuredEventLogger.shared.record(
                    domain: .gameEvent,
                    event: "stopped_score_candidate_held_unchanged_glyph",
                    entityID: team.rawValue,
                    previous: ["runningGlyphHash": String(admission.runningGlyphHash)],
                    next: ["stoppedGlyphHash": String(glyphHash), "distance": String(physicalDistance), "admitted": "false"],
                    source: source,
                    reason: reason,
                    captureGeneration: captureGeneration,
                    authoritativeOwner: "RinkLensGameEventLifecycleStore"
                )
            }
            return false
        }
        admission.unchangedGlyphHoldLogged = false
        if let priorHash = admission.stoppedGlyphHash,
           (priorHash ^ glyphHash).nonzeroBitCount <= 4,
           observedAt - admission.lastObservedAt <= 3.0 {
            admission.stoppedConfirmationCount += 1
        } else {
            admission.stoppedGlyphHash = glyphHash
            admission.stoppedConfirmationCount = 1
            admission.stoppedFirstObservedAt = observedAt
        }
        admission.lastObservedAt = observedAt
        stoppedBoardScoreAdmissions[team] = admission
        let admitted = admission.stoppedConfirmationCount >= 2
        RinkLensStructuredEventLogger.shared.record(
            domain: .gameEvent,
            event: admitted ? "stopped_score_candidate_admitted" : "stopped_score_candidate_confirmation_held",
            entityID: team.rawValue,
            previous: [
                "baseline": String(baseline),
                "proposed": String(proposed),
                "confirmations": String(max(0, admission.stoppedConfirmationCount - 1))
            ],
            next: [
                "baseline": String(baseline),
                "proposed": String(proposed),
                "confirmations": String(admission.stoppedConfirmationCount),
                "glyphDistance": String(physicalDistance),
                "admitted": String(admitted)
            ],
            source: source,
            reason: reason,
            captureGeneration: captureGeneration,
            authoritativeOwner: "RinkLensGameEventLifecycleStore"
        )
        if admitted { stoppedBoardScoreAdmissions[team] = nil }
        return admitted
    }

    func discardStoppedBoardScoreAdmissions(source: String, reason: String) {
        guard !stoppedBoardScoreAdmissions.isEmpty else { return }
        let previous = stoppedBoardScoreAdmissions.map { "\($0.key.rawValue)=\($0.value.baseline)->\($0.value.proposed)" }.sorted().joined(separator: ",")
        stoppedBoardScoreAdmissions.removeAll(keepingCapacity: true)
        RinkLensStructuredEventLogger.shared.record(
            domain: .gameEvent,
            event: "stopped_score_admission_state_cleared",
            previous: ["candidates": previous],
            next: ["candidates": "none"],
            source: source,
            reason: reason,
            authoritativeOwner: "RinkLensGameEventLifecycleStore"
        )
    }

    func preferredStoppageScoreBaseline(
        fallbackHome: Int?,
        fallbackAway: Int?
    ) -> (home: Int?, away: Int?, source: String) {
        guard RinkLensRiskFeaturePolicy.isEnabled(.runningScoreStoppageBaselineV2),
              let runningScoreBaseline else {
            return (fallbackHome, fallbackAway, "current-metadata-fallback")
        }
        return (
            runningScoreBaseline.home ?? fallbackHome,
            runningScoreBaseline.away ?? fallbackAway,
            "last-verified-running-score"
        )
    }

    func admitRelayPendingEvent(
        _ candidate: RinkLensRelayPendingEvent,
        source: String,
        reason: String
    ) -> RinkLensRelayPendingEventAdmission {
        let fingerprint = Self.canonicalFingerprint(for: candidate.event)
        let currentPendingID = relayPendingEvents.first {
            Self.canonicalFingerprint(for: $0.event) == fingerprint
        }?.event.id
        if RinkLensRiskFeaturePolicy.isEnabled(.eventSemanticDedupeV2),
           let existingID = currentPendingID ?? canonicalEventIDByFingerprint[fingerprint] {
            RinkLensStructuredEventLogger.shared.record(
                domain: .gameEvent,
                event: "semantic_event_duplicate_suppressed",
                entityID: candidate.event.id.uuidString,
                previous: ["canonicalEventID": existingID.uuidString, "fingerprint": fingerprint],
                next: ["candidateSuppressed": "true", "candidateEventID": candidate.event.id.uuidString],
                source: source,
                reason: reason,
                captureGeneration: candidate.event.captureGeneration,
                stoppageID: candidate.event.stoppageID
            )
            transition(candidate.event, to: .suppressed, source: source, reason: "Duplicate canonical semantic event: \(fingerprint)")
            return RinkLensRelayPendingEventAdmission(admitted: false, existingEventID: existingID, fingerprint: fingerprint)
        }
        let previousCount = relayPendingEvents.count
        relayPendingEvents.append(candidate)
        canonicalEventIDByFingerprint[fingerprint] = candidate.event.id
        transition(candidate.event, to: .detected, source: source, reason: reason)
        RinkLensStructuredEventLogger.shared.record(
            domain: .gameEvent,
            event: "relay_pending_event_admitted",
            entityID: candidate.event.id.uuidString,
            previous: ["count": String(previousCount), "fingerprint": "none"],
            next: ["count": String(relayPendingEvents.count), "fingerprint": fingerprint],
            source: source,
            reason: reason,
            captureGeneration: candidate.event.captureGeneration,
            stoppageID: candidate.event.stoppageID
        )
        return RinkLensRelayPendingEventAdmission(admitted: true, existingEventID: nil, fingerprint: fingerprint)
    }

    func releaseCanonicalIdentity(for event: BroadcastEvent, source: String, reason: String) {
        let fingerprint = Self.canonicalFingerprint(for: event)
        guard canonicalEventIDByFingerprint[fingerprint] == event.id else { return }
        canonicalEventIDByFingerprint.removeValue(forKey: fingerprint)
        RinkLensStructuredEventLogger.shared.record(
            domain: .gameEvent,
            event: "canonical_event_identity_released",
            entityID: event.id.uuidString,
            previous: ["fingerprint": fingerprint, "registered": "true"],
            next: ["fingerprint": fingerprint, "registered": "false"],
            source: source,
            reason: reason,
            captureGeneration: event.captureGeneration,
            stoppageID: event.stoppageID
        )
    }

    private static func canonicalFingerprint(for event: BroadcastEvent) -> String {
        switch event.type {
        case .goal, .powerPlayGoal, .shortHandedGoal:
            return "score-goal|team=\(event.team?.rawValue ?? "none")|home=\(event.homeScoreAfter.map { String($0) } ?? "none")|away=\(event.awayScoreAfter.map { String($0) } ?? "none")"
        case .penalty, .penalties:
            return "penalty|stoppage=\(event.stoppageID?.uuidString ?? "none")|identity=\(event.penaltyLifecycleID ?? "none")"
        case .powerPlayStart:
            return "strength|stoppage=\(event.stoppageID?.uuidString ?? "none")|ended=\(event.penaltyLifecycleID ?? "none")|state=\(event.strengthState.description)"
        case .penaltyEnd:
            return "penalty-end|stoppage=\(event.stoppageID?.uuidString ?? "none")|ended=\(event.penaltyLifecycleID ?? "none")|state=\(event.strengthState.description)"
        case .timeoutStart, .timeoutEnd:
            return "\(event.type.rawValue)|generation=\(event.captureGeneration.map { String($0) } ?? "none")|observed=\(event.actualObservedAt.timeIntervalSince1970)"
        case .periodEnd, .gameFinal:
            return "\(event.type.rawValue)|period=\(event.period.map { String($0) } ?? "none")|home=\(event.homeScoreAfter.map { String($0) } ?? "none")|away=\(event.awayScoreAfter.map { String($0) } ?? "none")"
        }
    }

    func replaceRelayPendingEvents(_ next: [RinkLensRelayPendingEvent], source: String, reason: String) {
        let previous = relayPendingEvents
        let previousSignatures = previous.map(Self.pendingEventStateSignature)
        let nextSignatures = next.map(Self.pendingEventStateSignature)
        guard previousSignatures != nextSignatures else {
            relayPendingEvents = next
            return
        }
        if RinkLensRiskFeaturePolicy.isEnabled(.completedEventSemanticDedupeV11) {
            // Build 723: removing an event from the pending queue means it was
            // released to the popup lifecycle, not that its semantic identity
            // ceased to exist. Only an explicit correction/cancellation calls
            // releaseCanonicalIdentity. This prevents the same 1-0 goal from
            // being admitted again when a later field change re-evaluates the
            // same stopped-window score delta.
            for item in next {
                canonicalEventIDByFingerprint[Self.canonicalFingerprint(for: item.event)] = item.event.id
            }
        } else {
            let affectedIDs = Set(previous.map { $0.event.id } + next.map { $0.event.id })
            canonicalEventIDByFingerprint = canonicalEventIDByFingerprint.filter {
                !affectedIDs.contains($0.value)
            }
            for item in next {
                canonicalEventIDByFingerprint[Self.canonicalFingerprint(for: item.event)] = item.event.id
            }
        }
        relayPendingEvents = next
        RinkLensStructuredEventLogger.shared.record(
            domain: .gameEvent,
            event: "relay_pending_events_changed",
            previous: [
                "count": String(previous.count),
                "ids": previous.map { $0.event.id.uuidString }.joined(separator: ","),
                "states": previousSignatures.joined(separator: ";")
            ],
            next: [
                "count": String(next.count),
                "ids": next.map { $0.event.id.uuidString }.joined(separator: ","),
                "states": nextSignatures.joined(separator: ";")
            ],
            source: source,
            reason: reason
        )
    }

    private static func pendingEventStateSignature(_ item: RinkLensRelayPendingEvent) -> String {
        let event = item.event
        let clockHash = event.frozenClockImagePNGData.map(Self.fnv1a64)
        return [
            event.id.uuidString,
            canonicalFingerprint(for: event),
            "stoppage=\(event.stoppageID?.uuidString ?? "none")",
            "clockHash=\(clockHash.map { String($0) } ?? "none")",
            "timeline=\(event.timelineLifecycleState ?? "none")",
            "popup=\(event.popupLifecycleState ?? "none")",
            "priority=\(item.priority)"
        ].joined(separator: "|")
    }

    func replaceStoppedClockPendingEvents(_ next: [BroadcastEvent], source: String, reason: String) {
        let previous = stoppedClockPendingEvents
        guard previous.map(\.id) != next.map(\.id) || previous.count != next.count else {
            stoppedClockPendingEvents = next
            return
        }
        stoppedClockPendingEvents = next
        RinkLensStructuredEventLogger.shared.record(
            domain: .gameEvent,
            event: "stopped_clock_pending_events_changed",
            previous: ["count": String(previous.count), "ids": previous.map { $0.id.uuidString }.joined(separator: ",")],
            next: ["count": String(next.count), "ids": next.map { $0.id.uuidString }.joined(separator: ",")],
            source: source,
            reason: reason
        )
    }

    func replaceStoppedClockEligibleAt(_ next: [UUID: Date]) { stoppedClockEligibleAt = next }
    func replaceGoalScoreConfirmationCount(_ next: [UUID: Int]) { goalScoreConfirmationCount = next }
    func replaceGoalLastObservationID(_ next: [UUID: UInt64]) { goalLastObservationID = next }

    func clearPending(source: String, reason: String) {
        let relayCount = relayPendingEvents.count
        let stoppedCount = stoppedClockPendingEvents.count
        relayPendingEvents.removeAll(keepingCapacity: true)
        stoppedClockPendingEvents.removeAll(keepingCapacity: true)
        stoppedClockEligibleAt.removeAll(keepingCapacity: true)
        goalScoreConfirmationCount.removeAll(keepingCapacity: true)
        goalLastObservationID.removeAll(keepingCapacity: true)
        RinkLensStructuredEventLogger.shared.record(
            domain: .gameEvent,
            event: "pending_event_state_cleared",
            previous: ["relay": String(relayCount), "stoppedClock": String(stoppedCount)],
            next: ["relay": "0", "stoppedClock": "0"],
            source: source,
            reason: reason
        )
    }

    func transition(_ event: BroadcastEvent, to stage: RinkLensGameEventLifecycleStage, source: String, reason: String) {
        let previousStage = records[event.id]?.stage
        records[event.id] = RinkLensGameEventLifecycleRecord(event: event, stage: stage, updatedAt: .now, reason: reason)
        trimIfNeeded()
        guard RinkLensRiskFeaturePolicy.isEnabled(.gameEventLifecycleV2) else { return }
        RinkLensStructuredEventLogger.shared.record(
            domain: .gameEvent,
            event: "game_event_\(stage.rawValue)",
            entityID: event.id.uuidString,
            previous: ["stage": previousStage?.rawValue ?? "none"],
            next: Self.summary(event, stage: stage),
            source: source,
            reason: reason,
            captureGeneration: event.captureGeneration,
            stoppageID: event.stoppageID
        )
    }

    func clear(source: String, reason: String) {
        let count = records.count
        records.removeAll(keepingCapacity: true)
        canonicalEventIDByFingerprint.removeAll(keepingCapacity: true)
        runningScoreBaseline = nil
        stoppedBoardScoreAdmissions.removeAll(keepingCapacity: true)
        RinkLensStructuredEventLogger.shared.record(domain: .gameEvent, event: "game_event_lifecycle_cleared", previous: ["count": String(count)], next: ["count": "0"], source: source, reason: reason)
    }

    private func trimIfNeeded() {
        guard records.count > retainedLimit else { return }
        let removeCount = records.count - retainedLimit
        let oldest = records.values.sorted { $0.updatedAt < $1.updatedAt }.prefix(removeCount).map { $0.event.id }
        for id in oldest { records.removeValue(forKey: id) }
        let retainedIDs = Set(records.keys).union(relayPendingEvents.map { $0.event.id })
        canonicalEventIDByFingerprint = canonicalEventIDByFingerprint.filter { retainedIDs.contains($0.value) }
    }

    private static func summary(_ event: BroadcastEvent, stage: RinkLensGameEventLifecycleStage) -> [String: String] {
        [
            "stage": stage.rawValue,
            "type": event.type.rawValue,
            "team": event.team?.rawValue ?? "none",
            "clock": event.gameClock ?? "none",
            "period": event.period.map { String($0) } ?? "none",
            "homeScore": event.homeScoreAfter.map { String($0) } ?? "none",
            "awayScore": event.awayScoreAfter.map { String($0) } ?? "none",
            "source": event.source.rawValue,
            "stoppageID": event.stoppageID?.uuidString ?? "none",
            "penaltyLifecycleID": event.penaltyLifecycleID ?? "none"
        ]
    }
}

@MainActor
final class RinkLensMatchEventJournal: ObservableObject {
    @Published private(set) var timeline: [BroadcastEvent] = []
    @Published private(set) var phase: BroadcastPhase = .inPlay
    @Published private(set) var phaseState: BroadcastPhaseState = .inPlay(period: 1, trigger: .appLaunch, reason: "Initial broadcast phase")
    @Published private(set) var phaseHistory: [BroadcastPhaseTransition] = []

    func upsertTimeline(_ event: BroadcastEvent, source: String, reason: String) {
        let previousCount = timeline.count
        if let index = timeline.firstIndex(where: { $0.id == event.id }) { timeline[index] = event } else { timeline.append(event) }
        if timeline.count > 48 { timeline.removeFirst(timeline.count - 48) }
        record(domain: .timeline, event: "timeline_upserted", entityID: event.id.uuidString, previous: ["count": String(previousCount)], next: ["count": String(timeline.count), "lifecycle": event.timelineLifecycleState ?? "none", "popup": event.popupLifecycleState ?? "none"], source: source, reason: reason)
    }
    func removeTimeline(id: UUID, source: String, reason: String) {
        let previousCount = timeline.count
        timeline.removeAll { $0.id == id }
        record(domain: .timeline, event: "timeline_removed", entityID: id.uuidString, previous: ["count": String(previousCount)], next: ["count": String(timeline.count)], source: source, reason: reason)
    }
    func clearTimeline(source: String, reason: String) {
        let previousCount = timeline.count
        timeline.removeAll(keepingCapacity: true)
        record(domain: .timeline, event: "timeline_cleared", previous: ["count": String(previousCount)], next: ["count": "0"], source: source, reason: reason)
    }

    /// Applies an in-place change through the journal authority. Callers receive
    /// a read-only timeline projection and cannot mutate its copied array value.
    @discardableResult
    func updateTimeline(
        matching predicate: (BroadcastEvent) -> Bool,
        source: String,
        reason: String,
        mutate: (inout BroadcastEvent) -> Void
    ) -> Int {
        var changedCount = 0
        for index in timeline.indices where predicate(timeline[index]) {
            let previousEvent = timeline[index]
            mutate(&timeline[index])
            guard timeline[index] != previousEvent else { continue }
            changedCount += 1
            record(
                domain: .timeline,
                event: "timeline_updated",
                entityID: timeline[index].id.uuidString,
                previous: timelineSummary(previousEvent),
                next: timelineSummary(timeline[index]),
                source: source,
                reason: reason
            )
        }
        return changedCount
    }

    @discardableResult
    func updateTimeline(
        id: UUID,
        source: String,
        reason: String,
        mutate: (inout BroadcastEvent) -> Void
    ) -> Bool {
        updateTimeline(
            matching: { $0.id == id },
            source: source,
            reason: reason,
            mutate: mutate
        ) > 0
    }

    /// Correlates late physical removal evidence with the already-created
    /// canonical power-play goal. The journal is the sole timeline owner; popup
    /// presentation remains unchanged and no second event is created.
    @discardableResult
    func bindLatePhysicalPenaltyRemovalToPowerPlayGoal(
        identity: String,
        clock: PenaltyClock,
        observedAt: CFAbsoluteTime,
        maximumAge: TimeInterval = 4.0,
        source: String,
        reason: String
    ) -> UUID? {
        let observedDate = Date(timeIntervalSinceReferenceDate: observedAt)
        guard let index = timeline.indices.reversed().first(where: { index in
            let event = timeline[index]
            guard event.type == .powerPlayGoal,
                  event.team != clock.team else { return false }
            let age = observedDate.timeIntervalSince(event.actualObservedAt)
            return age >= 0 && age <= maximumAge
                && (event.endedPenaltyClockSnapshot?.isEmpty ?? true)
        }) else { return nil }
        let previousEvent = timeline[index]
        timeline[index].endedPenaltyClockSnapshot = [clock]
        timeline[index].penaltyLifecycleID = identity
        timeline[index].timelineLifecycleState = "confirmed-late-physical-removal-bound"
        let updated = timeline[index]
        record(
            domain: .timeline,
            event: "power_play_goal_late_penalty_removal_bound",
            entityID: updated.id.uuidString,
            previous: timelineSummary(previousEvent),
            next: timelineSummary(updated).merging([
                "endedPenalty": identity,
                "removalObservedAt": ISO8601DateFormatter().string(from: observedDate)
            ]) { current, _ in current },
            source: source,
            reason: reason
        )
        return updated.id
    }

    @discardableResult
    func popLastTimeline(source: String, reason: String) -> BroadcastEvent? {
        guard let removed = timeline.popLast() else { return nil }
        record(
            domain: .timeline,
            event: "timeline_last_removed",
            entityID: removed.id.uuidString,
            previous: timelineSummary(removed).merging(["count": String(timeline.count + 1)]) { current, _ in current },
            next: ["count": String(timeline.count)],
            source: source,
            reason: reason
        )
        return removed
    }

    private func timelineSummary(_ event: BroadcastEvent) -> [String: String] {
        [
            "type": event.type.rawValue,
            "team": event.team?.rawValue ?? "none",
            "clock": event.gameClock ?? "none",
            "stoppageID": event.stoppageID?.uuidString ?? "none",
            "timelineLifecycle": event.timelineLifecycleState ?? "none",
            "popupLifecycle": event.popupLifecycleState ?? "none"
        ]
    }
    func setPhase(_ nextPhase: BroadcastPhase, state nextState: BroadcastPhaseState, transition: BroadcastPhaseTransition?, source: String, reason: String) {
        let previousPhase = phase
        phase = nextPhase
        phaseState = nextState
        if let transition { phaseHistory.append(transition); if phaseHistory.count > 40 { phaseHistory.removeFirst(phaseHistory.count - 40) } }
        record(domain: .broadcastPhase, event: "broadcast_phase_changed", previous: ["phase": previousPhase.rawValue], next: ["phase": nextPhase.rawValue, "state": nextState.diagnosticSummary], source: source, reason: reason)
    }

    private func record(domain: RinkLensStateDomain, event: String, entityID: String? = nil, previous: [String: String] = [:], next: [String: String] = [:], source: String, reason: String) {
        guard RinkLensRiskFeaturePolicy.isEnabled(.matchJournalAuthorityV2) else { return }
        RinkLensStructuredEventLogger.shared.record(domain: domain, event: event, entityID: entityID, previous: previous, next: next, source: source, reason: reason)
    }
}

// MARK: - Build 692 penalty lifecycle authority

struct RinkLensRecentPhysicalPenaltyRemoval {
    let identity: String
    let clock: PenaltyClock
    /// Immutable team-state evidence captured before the physical removal mutated
    /// the active lifecycle dictionary. This is transition evidence owned by the
    /// penalty lifecycle store, not a second active-penalty source of truth.
    let activeTeamClocksBeforeRemoval: [String: PenaltyClock]
    let stoppageID: UUID?
    let observedAt: CFAbsoluteTime
}

@MainActor
final class RinkLensPenaltyLifecycleStore: ObservableObject {
    private struct PowerPlayCancellationTombstone {
        let stoppageID: UUID
        let cancelledAt: CFAbsoluteTime
        var suppressionLogged: Bool
    }

    private let confirmationStateMachine = PenaltyStateMachine()
    private var powerPlayCancellationTombstones: [String: PowerPlayCancellationTombstone] = [:]
    private var recentPhysicalRemovals: [String: RinkLensRecentPhysicalPenaltyRemoval] = [:]

    @Published private(set) var relayCandidates: [PenaltyClock] = []

    /// Read-only candidate projection. The displayed penalty remains owned by MatchState.
    var relayClocks: [PenaltyClock] { relayCandidates }
    var relayStrength: StrengthState { StrengthStateCalculator.strengthState(from: relayCandidates) }


    func recordPhysicalRemoval(
        identity: String,
        clock: PenaltyClock,
        activeTeamClocksBeforeRemoval: [String: PenaltyClock],
        stoppageID: UUID?,
        observedAt: CFAbsoluteTime,
        source: String,
        reason: String
    ) {
        recentPhysicalRemovals = recentPhysicalRemovals.filter { observedAt - $0.value.observedAt <= 20.0 }
        let previous = recentPhysicalRemovals[identity]
        recentPhysicalRemovals[identity] = .init(
            identity: identity,
            clock: clock,
            activeTeamClocksBeforeRemoval: activeTeamClocksBeforeRemoval,
            stoppageID: stoppageID,
            observedAt: observedAt
        )
        RinkLensStructuredEventLogger.shared.record(
            domain: .penalty,
            event: "physical_penalty_removal_recorded",
            entityID: identity,
            previous: [
                "stoppageID": previous?.stoppageID?.uuidString ?? "none",
                "observedAt": previous.map { String(format: "%.3f", $0.observedAt) } ?? "none"
            ],
            next: [
                "team": clock.team.rawValue,
                "slot": String(clock.slot),
                "player": clock.playerNumber.map { String($0) } ?? "none",
                "teamStateBeforeRemoval": activeTeamClocksBeforeRemoval
                    .sorted { lhs, rhs in
                        if lhs.value.slot != rhs.value.slot { return lhs.value.slot < rhs.value.slot }
                        return lhs.key < rhs.key
                    }
                    .map { "\($0.key)@slot\($0.value.slot)#\($0.value.playerNumber.map({ String($0) }) ?? "none")" }
                    .joined(separator: ","),
                "stoppageID": stoppageID?.uuidString ?? "none",
                "observedAt": String(format: "%.3f", observedAt)
            ],
            source: source,
            reason: reason,
            stoppageID: stoppageID
        )
    }

    func recentPhysicalRemoval(
        opposing scoringTeam: Team,
        stoppageID: UUID,
        observedAt: CFAbsoluteTime,
        maximumAge: CFAbsoluteTime = 8.0
    ) -> RinkLensRecentPhysicalPenaltyRemoval? {
        recentPhysicalRemovals.values
            .filter { removal in
                removal.clock.team != scoringTeam
                    && removal.stoppageID == stoppageID
                    && observedAt >= removal.observedAt
                    && observedAt - removal.observedAt <= maximumAge
            }
            .sorted { $0.observedAt > $1.observedAt }
            .first
    }

    func recordPowerPlayCancellation(
        identity: String,
        stoppageID: UUID,
        observedAt: CFAbsoluteTime,
        source: String,
        reason: String
    ) {
        let previous = powerPlayCancellationTombstones[identity]
        powerPlayCancellationTombstones[identity] = PowerPlayCancellationTombstone(
            stoppageID: stoppageID,
            cancelledAt: observedAt,
            suppressionLogged: false
        )
        RinkLensStructuredEventLogger.shared.record(
            domain: .penalty,
            event: "power_play_penalty_cancellation_tombstoned",
            entityID: identity,
            previous: [
                "stoppageID": previous?.stoppageID.uuidString ?? "none",
                "active": previous == nil ? "false" : "true"
            ],
            next: ["stoppageID": stoppageID.uuidString, "active": "true"],
            source: source,
            reason: reason,
            stoppageID: stoppageID
        )
    }

    func shouldSuppressPowerPlayCancelledReentry(
        identity: String,
        stoppageID: UUID?,
        captureGeneration: Int,
        source: String
    ) -> Bool {
        guard RinkLensRiskFeaturePolicy.isEnabled(.powerPlayCancellationReconciliationV2),
              let stoppageID,
              var tombstone = powerPlayCancellationTombstones[identity],
              tombstone.stoppageID == stoppageID else { return false }
        if !tombstone.suppressionLogged {
            tombstone.suppressionLogged = true
            powerPlayCancellationTombstones[identity] = tombstone
            RinkLensStructuredEventLogger.shared.record(
                domain: .penalty,
                event: "power_play_cancelled_penalty_reentry_suppressed",
                entityID: identity,
                previous: ["physicalEvidence": "occupied", "logicalLifecycle": "cancelled"],
                next: ["physicalEvidence": "ignored-until-next-stoppage", "logicalLifecycle": "cancelled"],
                source: source,
                reason: "Same physical identity reappeared during the scoring stoppage after transactional power-play cancellation",
                captureGeneration: captureGeneration,
                stoppageID: stoppageID
            )
        }
        return true
    }

    func advanceCancellationReconciliation(
        to stoppageID: UUID,
        source: String,
        reason: String
    ) {
        let removed = powerPlayCancellationTombstones.filter { $0.value.stoppageID != stoppageID }
        guard !removed.isEmpty else { return }
        for identity in removed.keys { powerPlayCancellationTombstones.removeValue(forKey: identity) }
        RinkLensStructuredEventLogger.shared.record(
            domain: .penalty,
            event: "power_play_cancellation_tombstones_advanced",
            entityID: stoppageID.uuidString,
            previous: ["count": String(removed.count), "identities": removed.keys.sorted().joined(separator: ",")],
            next: ["count": "0", "newStoppageID": stoppageID.uuidString],
            source: source,
            reason: reason,
            stoppageID: stoppageID
        )
    }

    func lockedPlayer(for key: OCRRegionKey) -> Int? {
        confirmationStateMachine.lockedPlayer(for: key)
    }

    func resetAllPenaltyConfirmationState(source: String = "view-model", reason: String = "reset") {
        confirmationStateMachine.resetAllPenaltyConfirmationState()
        recentPhysicalRemovals.removeAll(keepingCapacity: true)
        RinkLensStructuredEventLogger.shared.record(
            domain: .penalty,
            event: "confirmation_state_reset",
            source: source,
            reason: reason
        )
    }

    /// Accepted penalties remain owned by ScoreboardState. This method records
    /// the reducer transition without retaining a second writable copy.
    func recordAcceptedTransition(previous: [PenaltyClock], next: [PenaltyClock], source: String, reason: String) {
        let previousNormalised = Self.normalised(previous)
        let nextNormalised = Self.normalised(next)
        guard previousNormalised != nextNormalised else { return }
        RinkLensStructuredEventLogger.shared.record(
            domain: .penalty,
            event: "accepted_penalty_transition",
            entityID: "scoreboard-state",
            previous: Self.summary(previousNormalised),
            next: Self.summary(nextNormalised),
            source: source,
            reason: reason
        )
    }

    func replaceRelay(_ next: [PenaltyClock], source: String, reason: String) {
        replace(&relayCandidates, with: next, channel: "image-relay-candidate", source: source, reason: reason)
    }

    func clearAll(source: String, reason: String) {
        replaceRelay([], source: source, reason: reason)
        resetAllPenaltyConfirmationState(source: source, reason: reason)
    }

    private func replace(
        _ current: inout [PenaltyClock],
        with next: [PenaltyClock],
        channel: String,
        source: String,
        reason: String
    ) {
        let normalised = Self.normalised(next)
        guard current != normalised else { return }
        let previous = current
        current = normalised
        RinkLensStructuredEventLogger.shared.record(
            domain: .penalty,
            event: "penalty_candidate_transition",
            entityID: channel,
            previous: Self.summary(previous),
            next: Self.summary(normalised),
            source: source,
            reason: reason
        )
    }

    private static func normalised(_ clocks: [PenaltyClock]) -> [PenaltyClock] {
        clocks.sorted { lhs, rhs in
            if lhs.team != rhs.team { return lhs.team.rawValue < rhs.team.rawValue }
            return lhs.slot < rhs.slot
        }
    }

    private static func summary(_ clocks: [PenaltyClock]) -> [String: String] {
        var output: [String: String] = [
            "count": String(clocks.count),
            "strength": StrengthStateCalculator.strengthState(from: clocks).scorebugManpowerText
        ]
        for clock in clocks {
            output[clock.id] = "player=\(clock.playerNumber.map { String($0) } ?? "none"),timer=\(clock.rawClock ?? clock.displayClock),active=\(clock.isActive)"
        }
        return output
    }
}

// MARK: - Build 692 popup state machine authority

@MainActor
final class RinkLensOverlayEventStateMachine: ObservableObject {
    @Published private(set) var state = BroadcastOverlayQueueState()

    var activeBroadcastBanner: BroadcastEvent? { state.activeBroadcastBanner }
    var activeIntermissionReel: BroadcastIntermissionReelState? { state.activeIntermissionReel }

    func enqueue(_ item: BroadcastOverlayQueueItem, preemptLowerPriority: Bool, source: String, reason: String) {
        let previous = state.diagnosticSummary
        state.enqueue(item, preemptLowerPriority: preemptLowerPriority)
        record(event: "popup_enqueued", entityID: item.id.uuidString, previous: previous, source: source, reason: reason)
    }

    @discardableResult
    func promoteNextIfNeeded(source: String, reason: String) -> BroadcastOverlayQueueItem? {
        let previous = state.diagnosticSummary
        let item = state.promoteNextIfNeeded()
        if let item {
            record(event: "popup_display_started", entityID: item.id.uuidString, previous: previous, source: source, reason: reason)
        }
        return item
    }

    @discardableResult
    func dismissActive(matching id: UUID? = nil, source: String, reason: String) -> BroadcastOverlayQueueItem? {
        let previous = state.diagnosticSummary
        let item = state.dismissActive(matching: id)
        if let item {
            record(event: "popup_display_completed", entityID: item.id.uuidString, previous: previous, source: source, reason: reason)
        }
        return item
    }

    func clear(source: String, reason: String) {
        let previous = state.diagnosticSummary
        state.clear()
        record(event: "popup_queue_cleared", entityID: nil, previous: previous, source: source, reason: reason)
    }

    private func record(event: String, entityID: String?, previous: String, source: String, reason: String) {
        RinkLensStructuredEventLogger.shared.record(
            domain: .popup,
            event: event,
            entityID: entityID,
            previous: ["queue": previous],
            next: ["queue": state.diagnosticSummary],
            source: source,
            reason: reason
        )
    }
}

// MARK: - Build 692 camera zoom authority

enum RinkLensCameraZoomRole: String, Codable {
    case live
    case ocr
}

nonisolated enum RinkLensCameraLensTarget: String, Codable, Equatable, Sendable {
    case halfX
    case wide
}

struct RinkLensCameraLensTransactionSnapshot: Equatable, Codable {
    let transactionID: UUID
    let target: RinkLensCameraLensTarget
    let requestedZoom: Double
    let startedCaptureGeneration: Int
    let source: String
    let reason: String
}

struct RinkLensCameraZoomSnapshot: Equatable, Codable {
    var requested: Double
    var lastAppliedAcknowledgement: Double
    var deviceID: String?
    var source: String
    var reason: String

    init(requested: Double = 1, lastAppliedAcknowledgement: Double = 1, deviceID: String? = nil, source: String = "bootstrap", reason: String = "initial") {
        self.requested = requested
        self.lastAppliedAcknowledgement = lastAppliedAcknowledgement
        self.deviceID = deviceID
        self.source = source
        self.reason = reason
    }
}

/// The source-resolution domain applied by the capture owner. This is physical
/// capture intent only: recording and streaming keep the 1920x1080 programme
/// canvas while a close-up may use a higher-resolution camera source.
nonisolated enum RinkLensBroadcastSourceQualityDomain: String, Sendable, Equatable {
    case base
}

/// Immutable format intent derived from the one operator production policy and
/// logical zoom. CaptureEngine still resolves whether hardware can apply it.
nonisolated struct RinkLensBroadcastCaptureQualityIntent: Sendable, Equatable {
    let domain: RinkLensBroadcastSourceQualityDomain
    let width: Int32
    let height: Int32
    let cadence: RinkLensCaptureCadence

    var formatPreference: RinkLensCaptureFormatPreference {
        .init(width: width, height: height, cadence: cadence)
    }
}

/// Recovery CY / RL-163: logical zoom never requests a higher-resolution
/// source domain. Broadcast remains on the operator 1080 capture policy; only
/// cadence may change between fixed 30/60 modes.
nonisolated enum RinkLensBroadcastCaptureQualityResolver {
    static func resolve(
        requestedZoom _: Double,
        basePolicy: BroadcastImageQualityPolicy,
        previousDomain _: RinkLensBroadcastSourceQualityDomain
    ) -> RinkLensBroadcastCaptureQualityIntent {
        .init(
            domain: .base,
            width: 1920,
            height: 1080,
            cadence: .init(integerFPS: basePolicy.preferredWideFPS)
        )
    }
}

/// Capability order for the one logical rear-camera source. Concrete devices
/// are still filtered by CaptureEngine against the active MultiCam device set.
nonisolated enum RinkLensBroadcastRearLensKind: String, Sendable, Equatable {
    case virtualRear
    case wide
    case ultraWide
}

nonisolated enum RinkLensBroadcastRearLensPolicy {
    static func orderedCandidates(
        wantsHalfX: Bool,
        requiresPairCompatibility _: Bool,
        sourceQualityDomain: RinkLensBroadcastSourceQualityDomain = .base
    ) -> [RinkLensBroadcastRearLensKind] {
        // Recovery DG restores the physically proven b114 base-camera contract:
        // one AVFoundation virtual rear source owns 0.5x through 5x and performs
        // constituent switching in place. Pair compatibility is still verified
        // against the concrete MultiCam device set before a candidate is admitted;
        // physical lenses remain ordered fallbacks when the virtual source cannot
        // coexist with the selected OCR camera.
        _ = sourceQualityDomain
        return wantsHalfX
            ? [.virtualRear, .ultraWide, .wide]
            : [.virtualRear, .wide, .ultraWide]
    }
}

/// Exact capability identity for coalescing a rejected close-up request. A
/// changed device, OCR pair, production policy or zoom domain permits one new
/// physical attempt; repeated slider samples in the same domain do not.
nonisolated struct RinkLensBroadcastCaptureQualityCapabilityKey: Sendable, Equatable {
    let liveDeviceID: String
    let ocrDeviceID: String?
    let basePolicy: BroadcastImageQualityPolicy
    let domain: RinkLensBroadcastSourceQualityDomain
}

nonisolated struct RinkLensBroadcastCaptureQualityRejectionGate: Sendable, Equatable {
    private(set) var rejectedKey: RinkLensBroadcastCaptureQualityCapabilityKey?

    mutating func reject(_ key: RinkLensBroadcastCaptureQualityCapabilityKey) {
        rejectedKey = key
    }

    mutating func clear() {
        rejectedKey = nil
    }

    func shouldAttempt(_ key: RinkLensBroadcastCaptureQualityCapabilityKey) -> Bool {
        rejectedKey != key
    }
}

/// Immutable requested-versus-physical capture evidence. It belongs in the
/// CaptureEngine snapshot; it does not create another mutable quality owner.
nonisolated struct RinkLensAppliedBroadcastCaptureQuality: Sendable, Equatable {
    let requested: RinkLensBroadcastCaptureQualityIntent
    let appliedFormat: RinkLensCaptureFormatPreference
    let physicalDeviceID: String
    let physicalDeviceType: String
    let activeConstituentID: String?
    let isVideoBinned: Bool
    let captureGeneration: Int
    let acceptedFrameSequence: Int
    let hardwareLimitedReason: String?

    var isHardwareLimited: Bool {
        requested.formatPreference != appliedFormat || hardwareLimitedReason != nil
    }
}

/// Monotonic media-time authority used only while an output owner is supplying
/// its one retained, fully composed continuity frame during a camera handoff.
nonisolated struct RinkLensOutputContinuitySequencer: Sendable, Equatable {
    private(set) var lastPTS: CMTime

    init(lastPTS: CMTime) {
        self.lastPTS = lastPTS.isValid ? lastPTS : .zero
    }

    mutating func next(cadence: RinkLensCaptureCadence) -> CMTime {
        lastPTS = CMTimeAdd(lastPTS, cadence.duration)
        return lastPTS
    }
}

@MainActor
final class RinkLensCameraZoomStore: ObservableObject {
    @Published private(set) var live = RinkLensCameraZoomSnapshot()
    @Published private(set) var ocr = RinkLensCameraZoomSnapshot()
    @Published private(set) var liveLensTransaction: RinkLensCameraLensTransactionSnapshot?

    func requested(for role: RinkLensCameraZoomRole) -> CGFloat {
        CGFloat(snapshot(for: role).requested)
    }

    func applied(for role: RinkLensCameraZoomRole) -> CGFloat {
        CGFloat(snapshot(for: role).lastAppliedAcknowledgement)
    }

    func request(_ zoom: CGFloat, for role: RinkLensCameraZoomRole, deviceID: String?, source: String, reason: String) {
        update(role: role, requested: zoom, applied: nil, deviceID: deviceID, source: source, reason: reason, event: "camera_zoom_requested")
    }

    private func acknowledgeApplied(_ zoom: CGFloat, for role: RinkLensCameraZoomRole, deviceID: String?, source: String, reason: String) {
        update(role: role, requested: nil, applied: zoom, deviceID: deviceID, source: source, reason: reason, event: "camera_zoom_applied")
    }

    /// The store is the only writer of applied zoom. Callers may submit immutable
    /// hardware evidence, but cannot set `lastAppliedAcknowledgement` directly.
    func commitLifecycleOutcome(
        _ outcome: RinkLensCaptureLifecycleOutcome,
        liveDeviceID: String?,
        ocrDeviceID: String?
    ) {
        guard outcome.succeeded, !outcome.wasSuperseded else { return }
        // Broadcast logical zoom is acknowledged only by the dedicated lens or
        // digital-zoom transaction after the physical source and a fresh frame are
        // verified. Generic lifecycle outcomes expose physical device factors and
        // must not reinterpret Ultra Wide physical 1.0x as logical Broadcast 1.0x.
        if let ocrZoom = outcome.ocrZoom {
            acknowledgeApplied(
                CGFloat(ocrZoom),
                for: .ocr,
                deviceID: ocrDeviceID,
                source: "RinkLensCameraZoomStore.commitLifecycleOutcome",
                reason: outcome.statusText
            )
        }
    }

    func commitBroadcastDigitalZoom(
        _ zoom: CGFloat,
        deviceID: String?,
        captureGeneration: Int,
        source: String,
        reason: String
    ) {
        let latestRequested = requested(for: .live)
        guard abs(latestRequested - zoom) < 0.01 else {
            RinkLensStructuredEventLogger.shared.record(
                domain: .cameraControl,
                event: "camera_zoom_acknowledgement_superseded",
                entityID: "live",
                previous: ["completedZoom": String(Double(zoom))],
                next: ["latestRequestedZoom": String(Double(latestRequested)), "acknowledged": "false"],
                source: source,
                reason: "A newer operator zoom request owns the visible framing",
                captureGeneration: captureGeneration,
                authoritativeOwner: "RinkLensCameraZoomStore"
            )
            return
        }
        acknowledgeApplied(
            zoom,
            for: .live,
            deviceID: deviceID,
            source: source,
            reason: reason
        )
    }

    /// Starts the one authoritative physical-lens transaction. The requested zoom
    /// changes immediately so capture-generation reconciliation cannot reapply the
    /// previous lens while the graph transaction is pending.
    func beginLiveLensTransaction(
        target: RinkLensCameraLensTarget,
        requestedZoom: CGFloat,
        deviceID: String?,
        captureGeneration: Int,
        source: String,
        reason: String
    ) -> UUID? {
        // R21: an in-flight physical operation is immutable. New operator input
        // changes only desired zoom; it never rewrites the target of hardware work
        // that has already begun. The current transaction must reach one terminal
        // success/cancel outcome before the latest desired state is reconciled.
        if let existing = liveLensTransaction {
            request(
                requestedZoom,
                for: .live,
                deviceID: deviceID,
                source: source,
                reason: "Desired zoom updated while immutable optical handoff is in flight"
            )
            RinkLensStructuredEventLogger.shared.record(
                domain: .cameraControl,
                event: "camera_zoom_desired_updated_during_immutable_handoff",
                entityID: existing.target.rawValue,
                previous: [
                    "transactionID": existing.transactionID.uuidString,
                    "immutableTarget": existing.target.rawValue,
                    "immutableRequestedZoom": String(existing.requestedZoom)
                ],
                next: [
                    "transactionID": existing.transactionID.uuidString,
                    "desiredTarget": target.rawValue,
                    "desiredZoom": String(Double(requestedZoom)),
                    "hardwareTransactionMutated": "false"
                ],
                source: source,
                reason: reason,
                captureGeneration: captureGeneration,
                authoritativeOwner: "RinkLensCameraZoomStore"
            )
            return existing.transactionID
        }

        let transactionID = UUID()
        liveLensTransaction = .init(
            transactionID: transactionID,
            target: target,
            requestedZoom: Double(requestedZoom),
            startedCaptureGeneration: captureGeneration,
            source: source,
            reason: reason
        )
        request(
            requestedZoom,
            for: .live,
            deviceID: deviceID,
            source: source,
            reason: "Immutable lens transaction requested: \(reason)"
        )
        RinkLensStructuredEventLogger.shared.record(
            domain: .cameraControl,
            event: "camera_lens_transaction_started",
            entityID: target.rawValue,
            previous: ["pending": "none"],
            next: [
                "transactionID": transactionID.uuidString,
                "requestedZoom": String(Double(requestedZoom)),
                "captureGeneration": String(captureGeneration),
                "immutable": "true"
            ],
            source: source,
            reason: reason,
            captureGeneration: captureGeneration,
            authoritativeOwner: "RinkLensCameraZoomStore"
        )
        return transactionID
    }

    @discardableResult
    func acknowledgeLiveLensVisualApplied(
        transactionID: UUID,
        target: RinkLensCameraLensTarget,
        appliedZoom: CGFloat,
        deviceID: String?,
        captureGeneration: Int,
        frameSequence: Int,
        source: String,
        reason: String
    ) -> Bool {
        guard let pending = liveLensTransaction,
              pending.transactionID == transactionID,
              pending.target == target,
              abs(pending.requestedZoom - Double(appliedZoom)) < 0.01 else {
            return false
        }
        let previousApplied = applied(for: .live)
        acknowledgeApplied(
            appliedZoom,
            for: .live,
            deviceID: deviceID,
            source: source,
            reason: reason
        )
        RinkLensStructuredEventLogger.shared.record(
            domain: .cameraControl,
            event: "camera_lens_visual_applied",
            entityID: target.rawValue,
            previous: [
                "appliedZoom": String(Double(previousApplied)),
                "transactionID": transactionID.uuidString
            ],
            next: [
                "appliedZoom": String(Double(appliedZoom)),
                "device": deviceID ?? "none",
                "frameSequence": String(frameSequence),
                "writerHandoffPending": "true"
            ],
            source: source,
            reason: reason,
            captureGeneration: captureGeneration,
            authoritativeOwner: "RinkLensCameraControlStore"
        )
        return true
    }

    func completeLiveLensTransaction(
        transactionID: UUID,
        appliedZoom: CGFloat,
        deviceID: String?,
        captureGeneration: Int,
        source: String,
        reason: String
    ) -> Bool {
        guard let pending = liveLensTransaction,
              pending.transactionID == transactionID else {
            return false
        }
        acknowledgeApplied(
            appliedZoom,
            for: .live,
            deviceID: deviceID,
            source: source,
            reason: reason
        )
        reconcileRequestedZoomAfterTerminalLensTransaction(
            pending: pending,
            appliedZoom: appliedZoom,
            deviceID: deviceID,
            source: source,
            reason: reason
        )
        liveLensTransaction = nil
        RinkLensStructuredEventLogger.shared.record(
            domain: .cameraControl,
            event: "camera_lens_transaction_completed",
            entityID: pending.target.rawValue,
            previous: [
                "transactionID": transactionID.uuidString,
                "pending": "true"
            ],
            next: [
                "pending": "false",
                "appliedZoom": String(Double(appliedZoom)),
                "device": deviceID ?? "none"
            ],
            source: source,
            reason: reason,
            captureGeneration: captureGeneration,
            authoritativeOwner: "RinkLensCameraControlStore"
        )
        return true
    }

    /// Recovery I terminal fail-safe. CaptureLifecycleController calls this only
    /// when a compensation transaction cannot restore the previous physical rear
    /// branch. The CaptureEngine snapshot remains the hardware authority, so the
    /// applied-zoom owner must end the pending transaction at that actual physical
    /// state rather than publish the previous logical zoom against different hardware.
    /// `visualVerified` is deliberately false: this is hardware truth, not fresh-frame
    /// acceptance, and the caller still returns a failed transaction to the UI.
    func terminateLiveLensTransactionAtHardwareTruth(
        transactionID: UUID,
        appliedZoom: CGFloat,
        deviceID: String?,
        captureGeneration: Int,
        hardwareTruthResolved: Bool,
        source: String,
        reason: String
    ) {
        guard let pending = liveLensTransaction,
              pending.transactionID == transactionID else { return }
        let previousApplied = applied(for: .live)
        acknowledgeApplied(
            appliedZoom,
            for: .live,
            deviceID: deviceID,
            source: source,
            reason: reason
        )
        reconcileRequestedZoomAfterTerminalLensTransaction(
            pending: pending,
            appliedZoom: appliedZoom,
            deviceID: deviceID,
            source: source,
            reason: reason
        )
        liveLensTransaction = nil
        RinkLensStructuredEventLogger.shared.record(
            domain: .cameraControl,
            event: "camera_lens_transaction_terminated_at_hardware_truth",
            entityID: pending.target.rawValue,
            previous: [
                "transactionID": transactionID.uuidString,
                "pending": "true",
                "previousAppliedZoom": String(Double(previousApplied))
            ],
            next: [
                "pending": "false",
                "appliedZoom": String(Double(appliedZoom)),
                "device": deviceID ?? "none",
                "hardwareTruthResolved": String(hardwareTruthResolved),
                "visualVerified": "false"
            ],
            source: source,
            reason: reason,
            captureGeneration: captureGeneration,
            authoritativeOwner: "RinkLensCameraZoomStore"
        )
    }

    /// Cancels a failed physical transaction. If that transaction still owns the
    /// latest operator request, requested zoom is reconciled to verified applied
    /// hardware truth. A newer operator request is preserved for the next
    /// convergence pass and is never overwritten by the failed older transaction.
    func cancelLiveLensTransaction(
        transactionID: UUID,
        deviceID: String?,
        captureGeneration: Int,
        source: String,
        reason: String
    ) {
        guard let pending = liveLensTransaction,
              pending.transactionID == transactionID else { return }
        let requestedBeforeTerminalReconciliation = requested(for: .live)
        let retainedAppliedZoom = applied(for: .live)
        reconcileRequestedZoomAfterTerminalLensTransaction(
            pending: pending,
            appliedZoom: retainedAppliedZoom,
            deviceID: deviceID,
            source: source,
            reason: reason
        )
        let retainedRequestedZoom = requested(for: .live)
        liveLensTransaction = nil
        RinkLensStructuredEventLogger.shared.record(
            domain: .cameraControl,
            event: "camera_lens_transaction_cancelled",
            entityID: pending.target.rawValue,
            previous: [
                "transactionID": transactionID.uuidString,
                "requestedZoom": String(pending.requestedZoom),
                "latestRequestedBeforeTerminalReconciliation": String(Double(requestedBeforeTerminalReconciliation)),
                "pending": "true"
            ],
            next: [
                "pending": "false",
                "retainedRequestedZoom": String(Double(retainedRequestedZoom)),
                "appliedAcknowledgement": String(Double(retainedAppliedZoom)),
                "device": deviceID ?? "none"
            ],
            source: source,
            reason: reason,
            captureGeneration: captureGeneration,
            authoritativeOwner: "RinkLensCameraControlStore"
        )
    }

    /// Recovery AV terminal convergence rule. A failed/rolled-back optical
    /// transaction may not leave the operator-visible requested value contradicting
    /// verified hardware. Only the request owned by that exact immutable transaction
    /// is reconciled; a newer desired zoom remains untouched.
    private func reconcileRequestedZoomAfterTerminalLensTransaction(
        pending: RinkLensCameraLensTransactionSnapshot,
        appliedZoom: CGFloat,
        deviceID: String?,
        source: String,
        reason: String
    ) {
        let latestRequested = requested(for: .live)
        guard abs(latestRequested - CGFloat(pending.requestedZoom)) < 0.01,
              abs(latestRequested - appliedZoom) >= 0.01 else { return }
        update(
            role: .live,
            requested: appliedZoom,
            applied: nil,
            deviceID: deviceID,
            source: source,
            reason: "Recovery AV terminal lens reconciliation: \(reason)",
            event: "camera_zoom_requested_reconciled_to_hardware"
        )
    }

    private func snapshot(for role: RinkLensCameraZoomRole) -> RinkLensCameraZoomSnapshot {
        role == .live ? live : ocr
    }

    private func update(
        role: RinkLensCameraZoomRole,
        requested: CGFloat?,
        applied: CGFloat?,
        deviceID: String?,
        source: String,
        reason: String,
        event: String
    ) {
        var next = snapshot(for: role)
        let previous = next
        if let requested {
            next.requested = requested.isFinite ? max(0.1, Double(requested)) : previous.requested
        }
        if let applied {
            next.lastAppliedAcknowledgement = applied.isFinite ? max(0.1, Double(applied)) : previous.lastAppliedAcknowledgement
        }
        next.deviceID = deviceID
        next.source = source
        next.reason = reason
        guard next != previous else { return }
        if role == .live { live = next } else { ocr = next }
        let isRequest = requested != nil
        RinkLensStructuredEventLogger.shared.record(
            domain: isRequest ? .cameraControl : .camera,
            event: event,
            entityID: role.rawValue,
            previous: ["requested": String(previous.requested), "appliedAcknowledgement": String(previous.lastAppliedAcknowledgement), "device": previous.deviceID ?? "none"],
            next: ["requested": String(next.requested), "appliedAcknowledgement": String(next.lastAppliedAcknowledgement), "device": next.deviceID ?? "none"],
            source: source,
            reason: reason,
            authoritativeOwner: "RinkLensCameraControlStore"
        )
    }
}

#endif

// Build 785 R16 performance execution ownership:
// - HockeyCameraService owns cached camera capabilities; views do not discover formats on appear.
// - ScoreboardFramePipeline owns capacity-one execution admission only; it never owns scoreboard state.
// - ScoreboardImageRelayEngine remains Image Relay processing authority and receives heavy frame work off MainActor.
// - RecordingWriter remains the only AVAssetWriter; the R15 encoder primer is removed.
// - RecordingEngine orders recording persistence before ClipEngine deferred remux release.


// Build 785 R17 measured-latency ownership refinements:
// - CaptureEngine remains the one AVCaptureSession/connection owner. Match-session camera inputs remain configured; route presentation toggles OCR frame delivery instead of changing graph ownership.
// - CaptureLifecycleController remains the desired-capture owner. A late first frame is presentation readiness, not a structural capture failure while the session is running.
// - ScoreboardImageRelayEngine remains penalty-processing authority. The cheap player occupancy path admits timer work; timer work no longer establishes blank penalty slots.
// - RecordingWriter remains the one final AVAssetWriter. Its exact final staging writer may be armed before REC; REC consumes that same writer/file and starts only the media timeline.
// - RinkLensRecordingCaptureLease's existing writerContractOpen projection owns clip-export exclusion for Starting/Recording/Paused/Stopping; ClipEngine does not infer safety from UI recording activity.
