// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation
import CoreGraphics

// MARK: - Build 732 Broadcast image-quality policy

/// Operator-owned policy for the Broadcast camera. The camera controller applies
/// the requested policy; views only display or edit it.
nonisolated enum BroadcastImageQualityPolicy: String, CaseIterable, Identifiable, Codable, Sendable {
    case motionPriority = "Motion Priority"
    case balanced = "Balanced"
    case imageQualityPriority = "Image Quality Priority"

    var id: String { rawValue }

    var detailText: String {
        switch self {
        case .motionPriority:
            return "Fixed 60 fps. Continuous exposure/focus/white balance remain active, but light-driven frame-rate changes and low-light boost stay off to protect hockey motion."
        case .balanced:
            return "Fixed 60 fps. Continuous exposure/focus/white balance adapt while cadence stays deterministic."
        case .imageQualityPriority:
            return "30 fps ceiling. When the active format supports it, AVFoundation may adapt 30→24 fps in low light and engage automatic low-light boost."
        }
    }

    var preferredWideFPS: Int {
        switch self {
        case .motionPriority, .balanced: return 60
        case .imageQualityPriority: return 30
        }
    }

    /// Requested imaging behaviour. RinkLensCameraControlStore remains the
    /// operator authority; CaptureEngine holds only the physically-applied truth.
    var allowsAutomaticFrameRate: Bool {
        self == .imageQualityPriority
    }

    var requestsAutomaticLowLightBoost: Bool {
        self == .imageQualityPriority
    }

}

/// Recovery CG / RL-196: the one operator-owned Broadcast production choice.
/// Camera exposure/cadence and stream output are resolved from this value; they
/// are not independently selectable in Camera Control and Stream Setup.
nonisolated enum BroadcastProductionProfile: String, CaseIterable, Identifiable, Codable, Sendable {
    case smoothMotion = "Smooth Motion"
    case balanced = "Balanced"
    case lowLight = "Low Light"
    case reducedData = "Reduced Data"

    var id: String { rawValue }

    var cameraPolicy: BroadcastImageQualityPolicy {
        switch self {
        case .smoothMotion: return .motionPriority
        case .balanced, .reducedData: return .balanced
        case .lowLight: return .imageQualityPriority
        }
    }

    var framesPerSecond: Int {
        cameraPolicy.preferredWideFPS
    }

    var operatorDetailText: String {
        switch self {
        case .smoothMotion:
            return "1080p60 • clearest hockey movement • recommended for a well-lit rink"
        case .balanced:
            return "1080p60 • balanced exposure and motion for normal rink lighting"
        case .lowLight:
            return "1080p30 ceiling • automatic low-light boost and 30→24 fps adaptation when the active format supports it"
        case .reducedData:
            return "720p60 • smooth movement with lower upload and encoder demand"
        }
    }

    var compactSummary: String {
        switch self {
        case .smoothMotion: return "1080p60 · Motion"
        case .balanced: return "1080p60 · Balanced"
        case .lowLight: return "1080p30 · Low Light"
        case .reducedData: return "720p60 · Balanced"
        }
    }

    /// Build 134: the master production profile owns the one recommended
    /// recording-compression starting point. RecordingEngine remains the sole
    /// mutable bitrate owner and decides whether it can adopt this projection.
    var recommendedCustomRecordingBitrateMbps: Int {
        switch self {
        case .smoothMotion, .balanced: return 16
        case .lowLight, .reducedData: return 8
        }
    }
}

nonisolated enum RinkLensCustomRecordingBitratePolicy {
    static func shouldAdoptRecommendation(
        customSettingsEnabled: Bool,
        recordingStateAllowsConfiguration: Bool
    ) -> Bool {
        customSettingsEnabled && recordingStateAllowsConfiguration
    }
}

nonisolated enum RinkLensStartupRinkHydrationPolicy {
    enum Phase: Sendable {
        case bootstrap
        case operationalStart
    }

    static func shouldHydrate(
        phase: Phase,
        alreadyHydrated: Bool,
        hasSavedTemplate: Bool
    ) -> Bool {
        phase == .bootstrap && !alreadyHydrated && hasSavedTemplate
    }
}


// MARK: - SAFE1 Operational Policy, Performance Budgets and Diagnostics Schema

/// SAFE1 operational capability policy. These are product/runtime choices, not rollout flags.
/// The current build keeps the live behaviour aligned with TEST1, but exposes a
/// single source of truth for diagnostics, regression checks and future UI
/// controls. Match Day Safe can derive a more conservative view without deleting
/// feature code.
struct RinkLensOperationalPolicy: Equatable, Codable {
    var playerPenaltySponsorsEnabled: Bool = true
    var goalSponsorOverlaysEnabled: Bool = true
    var intermissionReelEnabled: Bool = true
    var ocrIntermissionCountdownEnabled: Bool = true
    var unifiedOverlayQueueEnabled: Bool = true
    var diagTraceChannelsEnabled: Bool = true
    var regressionHarnessEnabled: Bool = true
    var recordingOverlayParityEnabled: Bool = true
    var broadcastCompositeStandardEnabled: Bool = true
    var performanceBudgetsEnabled: Bool = true
    var diagnosticsSchemaEnabled: Bool = true
    var matchDaySafeModeEnabled: Bool = false
    var sponsorTestPopupsEnabled: Bool = false
    var verboseDebugPanelsEnabled: Bool = true
    var heavyOCRFallbackEnabled: Bool = false

    static let standard = RinkLensOperationalPolicy()

    static let matchDaySafe = RinkLensOperationalPolicy(
        playerPenaltySponsorsEnabled: true,
        goalSponsorOverlaysEnabled: true,
        intermissionReelEnabled: true,
        ocrIntermissionCountdownEnabled: true,
        unifiedOverlayQueueEnabled: true,
        diagTraceChannelsEnabled: true,
        regressionHarnessEnabled: true,
        recordingOverlayParityEnabled: true,
        broadcastCompositeStandardEnabled: true,
        performanceBudgetsEnabled: true,
        diagnosticsSchemaEnabled: true,
        matchDaySafeModeEnabled: true,
        sponsorTestPopupsEnabled: false,
        verboseDebugPanelsEnabled: false,
        heavyOCRFallbackEnabled: false
    )

    var diagnosticSummary: String {
        [
            "playerPenaltySponsors=\(onOff(playerPenaltySponsorsEnabled))",
            "goalSponsorOverlays=\(onOff(goalSponsorOverlaysEnabled))",
            "intermissionReel=\(onOff(intermissionReelEnabled))",
            "ocrIntermissionCountdown=\(onOff(ocrIntermissionCountdownEnabled))",
            "overlayQueue=\(onOff(unifiedOverlayQueueEnabled))",
            "traceChannels=\(onOff(diagTraceChannelsEnabled))",
            "regressionHarness=\(onOff(regressionHarnessEnabled))",
            "recordingOverlayParity=\(onOff(recordingOverlayParityEnabled))",
            "compositeStandard=\(onOff(broadcastCompositeStandardEnabled))",
            "performanceBudgets=\(onOff(performanceBudgetsEnabled))",
            "schemaExport=\(onOff(diagnosticsSchemaEnabled))",
            "matchDaySafe=\(onOff(matchDaySafeModeEnabled))",
            "sponsorTestPopups=\(onOff(sponsorTestPopupsEnabled))",
            "verboseDebugPanels=\(onOff(verboseDebugPanelsEnabled))",
            "heavyOCRFallback=\(onOff(heavyOCRFallbackEnabled))"
        ].joined(separator: "; ")
    }

    private func onOff(_ value: Bool) -> String { value ? "on" : "off" }
}

/// BUDGET1: formal operational budgets for 1080p/60fps live broadcast testing.
/// Budgets are intentionally conservative and diagnostic-only in SAFE1. They
/// warn through exports/regression lines without changing the recording engine.
struct RinkLensPerformanceBudgets: Equatable, Codable {
    var previewUIUpdateMilliseconds: Double = 16.0
    var recordingFrameAppendMilliseconds: Double = 16.7
    var overlayRenderMilliseconds: Double = 4.0
    var ocrCycleSeconds: Double = 0.70
    var diagnosticsPublishUpdatesPerSecond: Int = 6
    var encoderBacklogMaximum: Int = 0
    var droppedFramesWarningThreshold: Int = 5
    var mainThreadStallMaximum: Int = 0
    var appMemoryWarningMegabytes: Double = 150.0
    var batteryWarningPercent: Int = 25

    static let matchDay = RinkLensPerformanceBudgets()

    var diagnosticSummary: String {
        [
            "previewUI<=\(format(previewUIUpdateMilliseconds))ms",
            "frameAppend<=\(format(recordingFrameAppendMilliseconds))ms",
            "overlayRender<=\(format(overlayRenderMilliseconds))ms",
            "ocrCycle<=\(format(ocrCycleSeconds))s",
            "diagnosticPublish<=\(diagnosticsPublishUpdatesPerSecond)/sec",
            "encoderBacklog<=\(encoderBacklogMaximum)",
            "droppedFrames<=\(droppedFramesWarningThreshold)",
            "uiStalls<=\(mainThreadStallMaximum)",
            "memoryWarn>=\(format(appMemoryWarningMegabytes))MB",
            "batteryWarn<\(batteryWarningPercent)%"
        ].joined(separator: "; ")
    }

    private func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

/// SCHEMA1: versioned diagnostics export contract. Keep these versions stable
/// unless the corresponding export section changes shape.
struct RinkLensDiagnosticsExportSchema: Equatable, Codable {
    var diagnosticsSchemaVersion: Int = 7
    var appStateVersion: Int = 3
    var cameraStateVersion: Int = 5
    var recordingStateVersion: Int = 2
    var sponsorStateVersion: Int = 1
    var ocrStateVersion: Int = 7
    var overlayQueueStateVersion: Int = 2
    var broadcastPhaseStateVersion: Int = 1
    var broadcastCompositeStateVersion: Int = 1
    var regressionSchemaVersion: Int = 7
    var stateOwnershipVersion: Int = 3
    var structuredEventLogVersion: Int = 3

    static let current = RinkLensDiagnosticsExportSchema()

    var diagnosticSummary: String {
        [
            "diagnostics=\(diagnosticsSchemaVersion)",
            "app=\(appStateVersion)",
            "camera=\(cameraStateVersion)",
            "recording=\(recordingStateVersion)",
            "sponsor=\(sponsorStateVersion)",
            "ocr=\(ocrStateVersion)",
            "overlayQueue=\(overlayQueueStateVersion)",
            "broadcastPhase=\(broadcastPhaseStateVersion)",
            "composite=\(broadcastCompositeStateVersion)",
            "regression=\(regressionSchemaVersion)",
            "stateOwnership=\(stateOwnershipVersion)",
            "structuredEvents=\(structuredEventLogVersion)"
        ].joined(separator: "; ")
    }
}

/// MATCHSAFE1: hard match-day policy. SAFE1 exposes the policy and enforces it
/// in diagnostics mode by heavily reducing logging/debug pressure. Feature flags
/// remain visible so future UI can toggle the policy explicitly.
struct RinkLensMatchDaySafeModePolicy: Equatable, Codable {
    var disableVerboseDiagnostics: Bool = true
    var disableExperimentalOverlays: Bool = true
    var hideDebugPanels: Bool = true
    var disableHeavyOCRFallback: Bool = true
    var suppressSponsorTestPopups: Bool = true
    var reduceDiagnosticPublishPressure: Bool = true
    var preserveCamera: Bool = true
    var preserveRecording: Bool = true
    var preserveManualScoreboard: Bool = true
    var preserveBasicOCR: Bool = true
    var preserveGoalPenaltyOverlays: Bool = true
    var preserveClipBuffer: Bool = true

    static let standard = RinkLensMatchDaySafeModePolicy()

    var diagnosticSummary: String {
        [
            "verboseDiagnostics=\(disableVerboseDiagnostics ? "off" : "on")",
            "experimentalOverlays=\(disableExperimentalOverlays ? "off" : "on")",
            "debugPanels=\(hideDebugPanels ? "hidden" : "visible")",
            "heavyOCRFallback=\(disableHeavyOCRFallback ? "off" : "on")",
            "sponsorTestPopups=\(suppressSponsorTestPopups ? "off" : "on")",
            "diagnosticPublish=\(reduceDiagnosticPublishPressure ? "reduced" : "normal")",
            "camera=\(preserveCamera ? "preserved" : "restricted")",
            "recording=\(preserveRecording ? "preserved" : "restricted")",
            "manualScoreboard=\(preserveManualScoreboard ? "preserved" : "restricted")",
            "basicOCR=\(preserveBasicOCR ? "preserved" : "restricted")",
            "goalPenaltyOverlays=\(preserveGoalPenaltyOverlays ? "preserved" : "restricted")",
            "clipBuffer=\(preserveClipBuffer ? "preserved" : "restricted")"
        ].joined(separator: "; ")
    }
}


// MARK: - UX1 Shared Broadcast Composite Standard

/// UX1: one raised 16:9 broadcast-composite stage used by iPad preview,
/// full-match recording, manual clips and future stream output. Team logos,
/// event popups and sponsor badges are rendered by the shared cached overlay so
/// preview and recording remain visually aligned.
struct BroadcastCompositeStandard: Equatable, Codable {
    static let version = "UX12"
    static let canonicalCanvas = CGSize(width: 1920, height: 1080)
    static let topHugInset: CGFloat = 6
    static let sideInset: CGFloat = 14
    static let topRowBadgeHeight: CGFloat = 64
    static let topRowBadgeWidth: CGFloat = 460
    static let topRowGap: CGFloat = 18
    static let compactScorebugWidth: CGFloat = 540
    static let fullScorebugWidth: CGFloat = 720
    static let fullScorebugWithSponsorWidth: CGFloat = 760
    static let compactScorebugHeight: CGFloat = 76
    static let fullScorebugHeight: CGFloat = 222
    static let fullScorebugWithSponsorHeight: CGFloat = 242

    static var diagnosticSummary: String {
        "version=\(version); canvas=1920x1080; origin=top-left; topHug=\(Int(topHugInset))px; previewVideo=recordVideo=clipVideo=streamVideo; previewOverlay=recordOverlay=clipOverlay=streamOverlay; previewStage=16:9 lowered letterbox; teamLogos=scorebug+eventPopups; eventPopups=shared-renderer; sponsorPreviewToggle=screen-only; timeline=removed; bottomControls=ultra-thin; setupRoutes=Settings-owned; scorebugTemplate=UX12-subtle-truthful-ocr-integrated-penalty-manpower; settingsPreview=broadcastRenderer; nameAwareSizing=true; settingsSetupTabs=embedded; profileLogos=asset-safe; logoBg=home+away; opacity=all-colours; fullTeamNames=preserved; centredLogos=larger+centred; sponsorPill=tighter; sponsorBadges=dynamic image+text fit; logos=aspect-fit/upright; textFit=uniform; scoreColumns=safe; wysiwyg=true; operatorControls=thin outside-letterbox-where-possible"
    }

    static func scale(for outputSize: CGSize) -> CGFloat {
        guard canonicalCanvas.width > 0, canonicalCanvas.height > 0 else { return 1 }
        return min(outputSize.width / canonicalCanvas.width, outputSize.height / canonicalCanvas.height)
    }

    static func point(_ value: CGFloat, for outputSize: CGSize) -> CGFloat {
        value * scale(for: outputSize)
    }

    static func rect(_ logicalRect: CGRect, for outputSize: CGSize) -> CGRect {
        let s = scale(for: outputSize)
        return pixelAligned(
            CGRect(
                x: logicalRect.minX * s,
                y: logicalRect.minY * s,
                width: logicalRect.width * s,
                height: logicalRect.height * s
            )
        )
    }

    static func pixelAligned(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x.rounded(.toNearestOrAwayFromZero),
            y: rect.origin.y.rounded(.toNearestOrAwayFromZero),
            width: rect.size.width.rounded(.toNearestOrAwayFromZero),
            height: rect.size.height.rounded(.toNearestOrAwayFromZero)
        )
    }

    static func topInset(for outputSize: CGSize) -> CGFloat {
        max(0, point(topHugInset, for: outputSize))
    }

    static func sideInset(for outputSize: CGSize) -> CGFloat {
        max(4, point(sideInset, for: outputSize))
    }

    static func scorebugRect(outputSize: CGSize, includesGameSponsor: Bool, compact: Bool = false) -> CGRect {
        let logicalWidth: CGFloat
        let logicalHeight: CGFloat
        if compact {
            logicalWidth = compactScorebugWidth
            logicalHeight = compactScorebugHeight
        } else {
            logicalWidth = includesGameSponsor ? fullScorebugWithSponsorWidth : fullScorebugWidth
            logicalHeight = includesGameSponsor ? fullScorebugWithSponsorHeight : fullScorebugHeight
        }
        let logicalX = (canonicalCanvas.width - logicalWidth) / 2
        return rect(
            CGRect(x: logicalX, y: topHugInset, width: logicalWidth, height: logicalHeight),
            for: outputSize
        )
    }

    static func scorebugRect(outputSize: CGSize, layout: BroadcastScoreboardLayoutSnapshot, includesGameSponsor: Bool) -> CGRect {
        scorebugRect(outputSize: outputSize, layout: layout, includesGameSponsor: includesGameSponsor, homeTeamName: nil, awayTeamName: nil)
    }

    static func scorebugRect(outputSize: CGSize, layout: BroadcastScoreboardLayoutSnapshot, includesGameSponsor: Bool, homeTeamName: String?, awayTeamName: String?) -> CGRect {
        let logicalSize = BroadcastScorebugTemplateMetrics.scorebugLogicalSize(for: layout, includesGameSponsor: includesGameSponsor, homeTeamName: homeTeamName, awayTeamName: awayTeamName)
        let centre = scorebugPosition(in: canonicalCanvas, overlaySize: logicalSize, layout: layout)
        return rect(CGRect(
            x: centre.x - logicalSize.width / 2,
            y: centre.y - logicalSize.height / 2,
            width: logicalSize.width,
            height: logicalSize.height
        ), for: outputSize)
    }

    /// One geometry authority for the live Broadcast projection and every
    /// raster programme output. Layout offsets are expressed in canonical
    /// 1920x1080 points and are scaled only when the final output is resolved.
    static func scorebugPosition(
        in canvasSize: CGSize,
        overlaySize: CGSize,
        layout: BroadcastScoreboardLayoutSnapshot
    ) -> CGPoint {
        let margin = max(previewSideInset(in: canvasSize), layout.safeMargin)
        let safeLeft = margin
        let safeRight = max(safeLeft, canvasSize.width - margin)
        let safeTop = previewTopInset(in: canvasSize)
        let safeBottom = max(safeTop, canvasSize.height - margin)
        let safeWidth = max(1, safeRight - safeLeft)
        let safeHeight = max(1, safeBottom - safeTop)
        let halfWidth = min(max(overlaySize.width / 2, 1), max(safeWidth / 2, 1))
        let halfHeight = min(max(overlaySize.height / 2, 1), max(safeHeight / 2, 1))
        let topY = safeTop + halfHeight
        let midX = safeLeft + safeWidth / 2

        let preset: CGPoint
        switch layout.positionPreset {
        case .topMiddle:
            preset = CGPoint(x: midX, y: topY)
        case .leftDefault:
            preset = CGPoint(x: safeLeft + halfWidth, y: topY)
        case .topRight:
            preset = CGPoint(x: safeRight - halfWidth, y: topY)
        }

        let minX = safeLeft + halfWidth
        let maxX = max(minX, safeRight - halfWidth)
        let minY = safeTop + halfHeight
        let maxY = max(minY, safeBottom - halfHeight)
        return CGPoint(
            x: min(max(preset.x + layout.horizontalOffset, minX), maxX),
            y: min(max(preset.y + layout.verticalOffset, minY), maxY)
        )
    }

    static func leagueBadgeRect(outputSize: CGSize) -> CGRect {
        rect(
            CGRect(x: sideInset, y: topHugInset, width: topRowBadgeWidth, height: topRowBadgeHeight),
            for: outputSize
        )
    }

    static func seasonSponsorBadgeRect(outputSize: CGSize) -> CGRect {
        rect(
            CGRect(
                x: canonicalCanvas.width - sideInset - topRowBadgeWidth,
                y: topHugInset,
                width: topRowBadgeWidth,
                height: topRowBadgeHeight
            ),
            for: outputSize
        )
    }


    static var aspectRatio: CGFloat {
        canonicalCanvas.width / canonicalCanvas.height
    }

    static var wysiwygPreviewDescription: String {
        "Preview displays live video and the cached 1920x1080 overlay inside the same 16:9 letterboxed frame used by recording/clips/stream; UX9 renders Settings preview through the same cached Broadcast/recording compositor and uses name-aware scorebug sizing"
    }

    static func previewCompositeFrame(in visibleSize: CGSize) -> CGRect {
        guard visibleSize.width > 0, visibleSize.height > 0 else {
            return CGRect(origin: .zero, size: visibleSize)
        }
        let scale = min(visibleSize.width / canonicalCanvas.width, visibleSize.height / canonicalCanvas.height)
        let width = canonicalCanvas.width * scale
        let height = canonicalCanvas.height * scale
        let verticalGap = max(0, visibleSize.height - height)
        // UX4: keep the WYSIWYG stage lowered so
        // the top admin/system buttons have a clean letterbox band and do not
        // overlap the 1920x1080 broadcast canvas. Bottom controls are now thinner
        // so they need less lower letterbox space.
        let raisedY = verticalGap <= 1 ? 0 : max(0, min(verticalGap * 0.62, max(0, verticalGap - 58)))
        return pixelAligned(CGRect(
            x: (visibleSize.width - width) / 2,
            y: raisedY,
            width: width,
            height: height
        ))
    }

    static func previewTopInset(in canvasSize: CGSize) -> CGFloat {
        topInset(for: canvasSize)
    }

    static func previewSideInset(in canvasSize: CGSize) -> CGFloat {
        sideInset(for: canvasSize)
    }
}

// MARK: - Phase 2 Broadcast Event Models

enum Team: String, Codable, CaseIterable, Identifiable, Hashable {
    case home
    case away

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .home: return "HOME"
        case .away: return "AWAY"
        }
    }
}

enum BroadcastEventType: String, Codable, CaseIterable, Identifiable {
    case goal
    case powerPlayGoal
    case shortHandedGoal
    case penalty
    case penalties
    case powerPlayStart
    case penaltyEnd
    case timeoutStart
    case timeoutEnd
    case periodEnd
    case gameFinal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .goal: return "GOAL"
        case .powerPlayGoal: return "POWER PLAY GOAL"
        case .shortHandedGoal: return "SHORT-HANDED GOAL"
        case .penalty: return "PENALTY"
        case .penalties: return "PENALTIES"
        case .powerPlayStart: return "POWER PLAY"
        case .penaltyEnd: return "PENALTY ENDED"
        case .timeoutStart: return "TIMEOUT"
        case .timeoutEnd: return "TIMEOUT ENDED"
        case .periodEnd: return "END OF PERIOD"
        case .gameFinal: return "FINAL"
        }
    }
}

enum StrengthState: Equatable, Codable {
    case evenStrength
    case homePowerPlay(seconds: Int, advantage: String)
    case awayPowerPlay(seconds: Int, advantage: String)
    case fourOnFour
    case threeOnThree
    case fiveOnThree(team: Team, secondsOne: Int, secondsTwo: Int)
    case unknown

    var description: String {
        switch self {
        case .evenStrength: return "Even Strength"
        case .homePowerPlay(_, let advantage): return "Home Power Play \(advantage)"
        case .awayPowerPlay(_, let advantage): return "Away Power Play \(advantage)"
        case .fourOnFour: return "4-on-4"
        case .threeOnThree: return "3-on-3"
        case .fiveOnThree(let team, _, _): return "\(team.displayName) Power Play 5-on-3"
        case .unknown: return "Unknown"
        }
    }
}

enum BroadcastEventSource: String, Codable {
    case ocr
    case manual
}

// Build 708: numeric game-time timeline metadata was retired. Broadcast events
// retain optional `gameClock` only for manual/test compatibility and popup fallback;
// Image Relay events use the immutable frozen Clock image instead.

/// Immutable popup-policy snapshot frozen when an event enters the eligible lifecycle.
/// Later Settings edits affect future events only, never a queued or active popup.
struct BroadcastEventPopupPolicySnapshot: Equatable, Codable {
    var goalPopupsEnabled: Bool
    var penaltyPopupsEnabled: Bool
    var goalTeamLogosEnabled: Bool
    var penaltyTeamLogosEnabled: Bool
    var useActualTeamNames: Bool
    var popupDurationSeconds: Double

    var clampedDurationSeconds: TimeInterval { min(max(popupDurationSeconds, 2.0), 12.0) }

    func isEnabled(for eventType: BroadcastEventType) -> Bool {
        switch eventType {
        case .goal, .powerPlayGoal, .shortHandedGoal: return goalPopupsEnabled
        case .penalty, .penalties, .powerPlayStart, .penaltyEnd: return penaltyPopupsEnabled
        case .timeoutStart, .timeoutEnd: return false
        case .periodEnd, .gameFinal: return true
        }
    }

    func teamLogosEnabled(for eventType: BroadcastEventType) -> Bool {
        switch eventType {
        case .goal, .powerPlayGoal, .shortHandedGoal: return goalTeamLogosEnabled
        case .penalty, .penalties, .powerPlayStart, .penaltyEnd: return penaltyTeamLogosEnabled
        case .timeoutStart, .timeoutEnd: return false
        case .periodEnd, .gameFinal: return goalTeamLogosEnabled || penaltyTeamLogosEnabled
        }
    }
}

// MARK: - ADS1 Sponsor / Intermission Broadcast Models

/// Sponsor payload resolved at event time so popups and recording diagnostics show
/// the sponsor that was active when the event was created. Keep this lightweight:
/// only display text and logo data are carried into the Broadcast event.
struct SponsorResolvedBroadcastSponsor: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    var sponsorID: UUID?
    var title: String
    var subtitle: String
    var playerLabel: String?
    var logoData: Data?

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Sponsor" : trimmed
    }
}

enum BroadcastPhase: String, Codable, Equatable {
    case preGame
    case inPlay
    case intermission
    case final

    var displayName: String {
        switch self {
        case .preGame: return "Pre-game"
        case .inPlay: return "In play"
        case .intermission: return "Intermission"
        case .final: return "Final"
        }
    }
}

enum BroadcastPhaseTransitionTrigger: String, Codable, Equatable {
    case appLaunch
    case manual
    case ocr
    case clock
    case operatorDismiss
    case routeChange
    case recording
    case recovery
    case unknown

    var displayName: String {
        switch self {
        case .appLaunch: return "App launch"
        case .manual: return "Manual"
        case .ocr: return "Recognition"
        case .clock: return "Clock"
        case .operatorDismiss: return "Operator dismiss"
        case .routeChange: return "Route change"
        case .recording: return "Recording"
        case .recovery: return "Recovery"
        case .unknown: return "Unknown"
        }
    }
}

/// STATE1: formal broadcast phase model.
///
/// This keeps the existing BroadcastPhase enum for compatibility, but adds the
/// period/intermission metadata needed to reason safely about period changes,
/// intermission reels, OCR countdown mode and future final-score behaviour.
struct BroadcastPhaseState: Equatable, Codable {
    var phase: BroadcastPhase
    var period: Int?
    var completedPeriod: Int?
    var nextPeriod: Int?
    var trigger: BroadcastPhaseTransitionTrigger
    var eventSource: BroadcastEventSource?
    var startedAt: Date
    var reason: String

    static func preGame(trigger: BroadcastPhaseTransitionTrigger = .appLaunch, reason: String = "Pre-game") -> BroadcastPhaseState {
        BroadcastPhaseState(phase: .preGame, period: nil, completedPeriod: nil, nextPeriod: 1, trigger: trigger, eventSource: nil, startedAt: .now, reason: reason)
    }

    static func inPlay(period: Int, trigger: BroadcastPhaseTransitionTrigger, eventSource: BroadcastEventSource? = nil, reason: String) -> BroadcastPhaseState {
        BroadcastPhaseState(phase: .inPlay, period: max(1, min(3, period)), completedPeriod: nil, nextPeriod: nil, trigger: trigger, eventSource: eventSource, startedAt: .now, reason: reason)
    }

    static func intermission(completedPeriod: Int, nextPeriod: Int, trigger: BroadcastPhaseTransitionTrigger, eventSource: BroadcastEventSource? = nil, reason: String) -> BroadcastPhaseState {
        BroadcastPhaseState(phase: .intermission, period: nil, completedPeriod: max(1, min(3, completedPeriod)), nextPeriod: max(1, min(3, nextPeriod)), trigger: trigger, eventSource: eventSource, startedAt: .now, reason: reason)
    }

    static func final(period: Int? = 3, trigger: BroadcastPhaseTransitionTrigger, eventSource: BroadcastEventSource? = nil, reason: String) -> BroadcastPhaseState {
        BroadcastPhaseState(phase: .final, period: period, completedPeriod: period, nextPeriod: nil, trigger: trigger, eventSource: eventSource, startedAt: .now, reason: reason)
    }

    var isIntermission: Bool { phase == .intermission }
    var shouldForceIntermissionCountdown: Bool { phase == .intermission }

    var displayName: String {
        switch phase {
        case .preGame:
            return "Pre-game"
        case .inPlay:
            return "In play P\(period ?? 1)"
        case .intermission:
            return "Intermission P\(completedPeriod ?? 0)→P\(nextPeriod ?? 0)"
        case .final:
            return "Final"
        }
    }

    var diagnosticSummary: String {
        var parts = [displayName, "trigger=\(trigger.rawValue)"]
        if let eventSource { parts.append("source=\(eventSource.rawValue)") }
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedReason.isEmpty { parts.append("reason=\(trimmedReason)") }
        return parts.joined(separator: "; ")
    }
}

struct BroadcastPhaseTransition: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    var from: BroadcastPhaseState
    var to: BroadcastPhaseState
    var trigger: BroadcastPhaseTransitionTrigger
    var reason: String
    var occurredAt: Date = .now

    var diagnosticSummary: String {
        "\(from.displayName) -> \(to.displayName); trigger=\(trigger.rawValue); reason=\(reason)"
    }
}

struct BroadcastPhaseStateMachine: Equatable {
    private(set) var state: BroadcastPhaseState
    private(set) var transitionHistory: [BroadcastPhaseTransition] = []
    var maxHistoryCount: Int = 20

    init(initial: BroadcastPhaseState) {
        self.state = initial
    }

    @discardableResult
    mutating func transition(to nextState: BroadcastPhaseState, trigger: BroadcastPhaseTransitionTrigger, reason: String) -> BroadcastPhaseTransition? {
        guard state != nextState else { return nil }
        let transition = BroadcastPhaseTransition(from: state, to: nextState, trigger: trigger, reason: reason)
        state = nextState
        transitionHistory.append(transition)
        if transitionHistory.count > maxHistoryCount {
            transitionHistory.removeFirst(transitionHistory.count - maxHistoryCount)
        }
        return transition
    }
}

/// Active intermission reel state. The countdown is intentionally not stored here:
/// Broadcast reads the current accepted clock value so OCR can continue to update
/// the intermission countdown while the sponsor reel is on screen.
struct BroadcastIntermissionReelState: Identifiable, Equatable {
    var id: UUID = UUID()
    var completedPeriod: Int
    var nextPeriod: Int
    var triggeredBy: BroadcastEventSource
    var sponsorSlides: [SponsorResolvedBroadcastSponsor]
    var startedAt: Date = .now

    var title: String { "INTERMISSION" }
    var subtitle: String { "END OF PERIOD \(completedPeriod)" }
    var nextPeriodLabel: String { "NEXT: PERIOD \(nextPeriod)" }
    var hasSponsors: Bool { !sponsorSlides.isEmpty }
}

// MARK: - OVERLAY1 Unified Broadcast Overlay Queue

/// Priority-ordered overlay item type used to keep goals, penalties, sponsor
/// popups and intermission reels from competing for screen space. Existing UI
/// bindings are preserved: the ViewModel projects the active queue item back to
/// `activeBroadcastBanner` and `activeIntermissionReel` for BroadcastView.
enum BroadcastOverlayQueueItemKind: String, Codable, Equatable, CaseIterable {
    case goal
    case penalty
    case sponsor
    case intermission

    var displayName: String {
        switch self {
        case .goal: return "Goal"
        case .penalty: return "Penalty"
        case .sponsor: return "Sponsor"
        case .intermission: return "Intermission"
        }
    }
}

struct BroadcastOverlayQueueItem: Identifiable, Equatable {
    var id: UUID = UUID()
    var kind: BroadcastOverlayQueueItemKind
    var priority: Int
    var event: BroadcastEvent?
    var sponsor: SponsorResolvedBroadcastSponsor?
    var intermissionReel: BroadcastIntermissionReelState?
    var durationSeconds: TimeInterval?
    var createdAt: Date = .now
    var source: BroadcastEventSource?
    var reason: String

    static func event(_ event: BroadcastEvent, durationSeconds: TimeInterval, reason: String) -> BroadcastOverlayQueueItem {
        let isPenalty = [.penalty, .penalties, .powerPlayStart, .penaltyEnd, .timeoutStart, .timeoutEnd].contains(event.type)
        let isGoal = event.type == .goal || event.type == .powerPlayGoal || event.type == .shortHandedGoal
        return BroadcastOverlayQueueItem(
            kind: isPenalty ? .penalty : (isGoal ? .goal : .sponsor),
            priority: isPenalty ? 70 : 60,
            event: event,
            sponsor: event.sponsor,
            intermissionReel: nil,
            durationSeconds: durationSeconds,
            source: event.source,
            reason: reason
        )
    }

    static func intermission(_ reel: BroadcastIntermissionReelState, reason: String) -> BroadcastOverlayQueueItem {
        BroadcastOverlayQueueItem(
            kind: .intermission,
            priority: 100,
            event: nil,
            sponsor: reel.sponsorSlides.first,
            intermissionReel: reel,
            durationSeconds: nil,
            source: reel.triggeredBy,
            reason: reason
        )
    }

    var diagnosticSummary: String {
        var parts = ["kind=\(kind.rawValue)", "priority=\(priority)"]
        if let event { parts.append("event=\(event.type.rawValue)") }
        if let sponsor { parts.append("sponsor=\(sponsor.displayTitle)") }
        if let intermissionReel { parts.append("intermission=P\(intermissionReel.completedPeriod)->P\(intermissionReel.nextPeriod)") }
        if let source { parts.append("source=\(source.rawValue)") }
        if !reason.isEmpty { parts.append("reason=\(reason)") }
        return parts.joined(separator: "; ")
    }
}

struct BroadcastOverlayQueueState: Equatable {
    private(set) var activeItem: BroadcastOverlayQueueItem?
    private(set) var pendingItems: [BroadcastOverlayQueueItem] = []
    private(set) var history: [BroadcastOverlayQueueItem] = []
    var maxPendingItems: Int = 12
    var maxHistoryItems: Int = 30

    var activeBroadcastBanner: BroadcastEvent? { activeItem?.event }
    var activeIntermissionReel: BroadcastIntermissionReelState? { activeItem?.intermissionReel }
    var pendingCount: Int { pendingItems.count }

    var diagnosticSummary: String {
        let active = activeItem?.diagnosticSummary ?? "none"
        return "active={\(active)} pending=\(pendingItems.count) history=\(history.count)"
    }

    mutating func enqueue(_ item: BroadcastOverlayQueueItem, preemptLowerPriority: Bool = false) {
        if preemptLowerPriority, let activeItem, item.priority > activeItem.priority {
            pendingItems.append(activeItem)
            self.activeItem = item
        } else {
            pendingItems.append(item)
        }
        pendingItems.sort {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.createdAt < $1.createdAt
        }
        if pendingItems.count > maxPendingItems {
            pendingItems.removeLast(pendingItems.count - maxPendingItems)
        }
    }

    @discardableResult
    mutating func promoteNextIfNeeded() -> BroadcastOverlayQueueItem? {
        guard activeItem == nil, !pendingItems.isEmpty else { return activeItem }
        activeItem = pendingItems.removeFirst()
        return activeItem
    }

    @discardableResult
    mutating func dismissActive(matching id: UUID? = nil) -> BroadcastOverlayQueueItem? {
        guard let activeItem else { return nil }
        if let id, activeItem.id != id { return nil }
        self.activeItem = nil
        history.append(activeItem)
        if history.count > maxHistoryItems {
            history.removeFirst(history.count - maxHistoryItems)
        }
        return activeItem
    }

    mutating func clear() {
        if let activeItem { history.append(activeItem) }
        history.append(contentsOf: pendingItems)
        activeItem = nil
        pendingItems.removeAll()
        if history.count > maxHistoryItems {
            history.removeFirst(history.count - maxHistoryItems)
        }
    }
}



struct PenaltyClock: Identifiable, Equatable, Codable {
    var team: Team
    var slot: Int
    var playerNumber: Int?
    var rawClock: String?
    var remainingSeconds: Int?
    /// Build 602 metadata-only Image Relay penalties stay active while the
    /// confirmed player remains on the physical board. The visible penalty
    /// countdown is still Image Relay and is never converted into MatchState.
    var metadataPlayerPresent: Bool? = nil

    var id: String { "\(team.rawValue)-\(slot)" }
    var isActive: Bool { metadataPlayerPresent == true || (remainingSeconds ?? 0) > 0 }

    var displayClock: String {
        if metadataPlayerPresent == true, remainingSeconds == nil { return "" }
        guard let remainingSeconds, remainingSeconds > 0 else { return "--:--" }
        let minutes = remainingSeconds / 60
        let seconds = remainingSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var publicPlayerLabel: String {
        playerNumber.map { "#\($0)" } ?? "#--"
    }
}

struct BroadcastEvent: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    var type: BroadcastEventType
    var team: Team?
    var period: Int?
    var gameClock: String?
    var homeScoreAfter: Int?
    var awayScoreAfter: Int?
    var strengthState: StrengthState = .unknown
    var source: BroadcastEventSource
    var operatorConfirmed: Bool
    var createdAt: Date = .now
    var penaltyClockSnapshot: [PenaltyClock] = []
    var sponsor: SponsorResolvedBroadcastSponsor? = nil
    /// Optional presentation text used by metadata-only strength transitions.
    /// Event type remains one of the established popup categories so operator
    /// settings and the unified overlay queue remain unchanged.
    var titleOverride: String? = nil
    var headlineOverride: String? = nil
    var detailOverride: String? = nil
    /// Player-owned penalties closed by this event. The canonical timeline uses
    /// these identities to end an open span without reading the penalty timer.
    var endedPenaltyClockSnapshot: [PenaltyClock]? = nil
    /// Immutable Image Relay Clock image captured from the first stable crop of
    /// the confirmed stoppage. PNG data keeps BroadcastEvent Codable/Equatable
    /// while preventing a later live relay frame from replacing the popup Clock.
    var frozenClockImagePNGData: Data? = nil
    /// Immutable Image Relay player-number crop selected after stable physical
    /// occupancy. This is the primary number source for penalty popups. OCR text
    /// is metadata-only and can never replace this image on the live scorebug.
    var frozenPenaltyPlayerImagePNGData: Data? = nil
    /// OCR-recognised player number used only by penalty popup presentation and
    /// lifecycle identity. The live scorebug player image remains Image Relay-first.
    var recognisedPenaltyPlayerNumber: Int? = nil
    /// Optional Home roster enhancement. It is populated only when the recognised
    /// number matches a real Home roster jersey number. Sponsor assignment is not required.
    var recognisedHomePlayerName: String? = nil
    /// Diagnostics for the popup source: home-roster-match,
    /// image-relay-fallback or guest-image-relay-required.
    var penaltyPopupPlayerSource: String? = nil
    /// Stable identifier shared by all events created during one physical Clock
    /// stoppage. This is the duplicate-prevention boundary for popup sequencing.
    var stoppageID: UUID? = nil
    /// Actual device time at which the underlying score/player state was observed.
    /// It is used for ordering and next-anchor fallback, never as game time.
    var actualObservedAt: Date = .now
    /// Build 614 keeps timeline recording independent from popup eligibility.
    /// These optional diagnostics do not affect rendering or existing display variables.
    var penaltyLifecycleID: String? = nil
    var timelineLifecycleState: String? = nil
    var popupLifecycleState: String? = nil
    var captureGeneration: Int? = nil
    /// Frozen presentation settings for this event. Nil preserves compatibility
    /// with older saved events and previews, which then use current settings.
    var popupPolicySnapshot: BroadcastEventPopupPolicySnapshot? = nil

    var popupTitle: String { titleOverride ?? type.title }
    var popupHeadline: String { headlineOverride ?? strengthState.headline }
    var popupDetail: String { detailOverride ?? strengthState.detail }

    var scoreLine: String {
        "HOME \(homeScoreAfter.map { String($0) } ?? "-") - AWAY \(awayScoreAfter.map { String($0) } ?? "-")"
    }

    /// Manual visual event used while Image Relay is active. The physical
    /// numbers remain images, so this event intentionally contains no decoded
    /// score, period, clock or penalty-player values.
    var isImageRelayCue: Bool {
        source == .manual
            && homeScoreAfter == nil
            && awayScoreAfter == nil
            && period == nil
            && gameClock == nil
    }

    var periodClockLine: String {
        let periodText = period.map { "P\($0)" } ?? "P-"
        guard let gameClock, !gameClock.isEmpty else { return periodText }
        return "\(periodText) \(gameClock)"
    }

    var penaltyOffendersLine: String {
        let active = penaltyClockSnapshot.filter(\.isActive)
        guard !active.isEmpty else { return "" }
        let home = active.filter { $0.team == .home }.sortedForEventDisplay
        let away = active.filter { $0.team == .away }.sortedForEventDisplay
        let homeLine = offenderLine(label: "HOME", clocks: home)
        let awayLine = offenderLine(label: "AWAY", clocks: away)
        return [homeLine, awayLine].filter { !$0.isEmpty }.joined(separator: "   |   ")
    }

    private func offenderLine(label: String, clocks: [PenaltyClock]) -> String {
        guard !clocks.isEmpty else { return "" }
        let players = clocks.prefix(2).map { clock in
            let timer = clock.displayClock
            return timer.isEmpty ? clock.publicPlayerLabel : "\(clock.publicPlayerLabel) \(timer)"
        }.joined(separator: ", ")
        return "\(label): \(players)"
    }
}

private extension Array where Element == PenaltyClock {
    var sortedForEventDisplay: [PenaltyClock] {
        sorted {
            if $0.team != $1.team { return $0.team.rawValue < $1.team.rawValue }
            if $0.slot != $1.slot { return $0.slot < $1.slot }
            return ($0.remainingSeconds ?? 0) > ($1.remainingSeconds ?? 0)
        }
    }
}

#endif
