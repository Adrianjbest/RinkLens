// BUILD 699 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import UIKit
import AVFoundation
import Vision
import CoreMedia
import CoreGraphics
import CoreFoundation
import CoreImage
import PhotosUI
import Foundation
import Combine
#if canImport(MLKitVision) && canImport(MLKitTextRecognition) && canImport(MLKitTextRecognitionLatin)
import MLKitVision
import MLKitTextRecognition
import MLKitTextRecognitionLatin
#endif

enum RinkLensPowerPlayGoalAdmission {
    static func shouldClassifyAsPowerPlay(
        scoringTeam: Team,
        physicalAdvantagedTeam: Team?,
        visibleOpposingPenaltyCount: Int
    ) -> Bool {
        physicalAdvantagedTeam == scoringTeam
            && visibleOpposingPenaltyCount > 0
    }
}

enum OCRRegionDetectionState: String {
    case none
    case hashingActive
    case ocrScheduled
    case safetyResync
    case failed

    var label: String {
        switch self {
        case .none: return "No detection"
        case .hashingActive: return "Hashing"
        case .ocrScheduled: return "OCR"
        case .safetyResync: return "Safety resync"
        case .failed: return "OCR failed"
        }
    }
}



enum BroadcastZoomTransitionSpeed: String, CaseIterable, Identifiable {
    case instant
    case fast
    case normal
    case slow

    var id: String { rawValue }

    var label: String {
        switch self {
        case .instant: return "Instant"
        case .fast: return "Fast"
        case .normal: return "Normal"
        case .slow: return "Slow"
        }
    }

    var durationSeconds: TimeInterval {
        switch self {
        case .instant: return 0.0
        case .fast: return 0.45
        case .normal: return 1.5
        case .slow: return 4.0
        }
    }

    var next: BroadcastZoomTransitionSpeed {
        switch self {
        case .instant: return .fast
        case .fast: return .normal
        case .normal: return .slow
        case .slow: return .instant
        }
    }
}

enum RinkLensTestOCROutcome: String {
    case idle
    case waitingForFrame
    case recognised
    case rejected
    case noFreshFrame
    case cropInvalid
    case noCandidate

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .waitingForFrame: return "Waiting for fresh frame"
        case .recognised: return "Recognised"
        case .rejected: return "Rejected"
        case .noFreshFrame: return "No fresh frame"
        case .cropInvalid: return "Crop invalid"
        case .noCandidate: return "No candidate"
        }
    }
}

private struct RinkLensPendingTestOCRResult {
    let key: OCRRegionKey
    let value: String
    let raw: String
    let cleaned: String
    let validation: String
    let confidence: Float
    let recognizer: RecognitionStrategy
    let captureGeneration: Int
    let frameSequence: Int
}

private struct RinkLensClockContinuityCorrection {
    let value: String
    let confidence: Float
    let diagnostic: String
}

private enum RinkLensFullBoardResetObservationResult {
    case inactive
    case holding
    case committed(RinkLensMatchStateReduction)
}

private struct RinkLensFullBoardResetRecoveryState {
    var startedAt: CFAbsoluteTime = 0
    var expiresAt: CFAbsoluteTime = 0
    var originalClockSeconds: Int?
    var originalHomeScore: Int?
    var originalAwayScore: Int?
    var clockCandidateSeconds: Int?
    var clockEvidenceCount = 0
    var clockLastObservedAt: CFAbsoluteTime = 0
    var homeCandidate: Int?
    var homeEvidenceCount = 0
    var awayCandidate: Int?
    var awayEvidenceCount = 0
    var periodCandidate: Int?
    var periodEvidenceCount = 0

    var isActive: Bool { startedAt > 0 && expiresAt > startedAt }

    mutating func reset() {
        self = RinkLensFullBoardResetRecoveryState()
    }
}

private struct RinkLensTrustedClockDecision {
    let clockForPublication: String?
    let acceptedObservation: Bool
    let publicClockChanged: Bool
    let runningStateChanged: Bool
    let isRunning: Bool
    let confirmedStopped: Bool
    let reason: String

    static func rejected(_ reason: String, running: Bool, stopped: Bool) -> Self {
        Self(
            clockForPublication: nil,
            acceptedObservation: false,
            publicClockChanged: false,
            runningStateChanged: false,
            isRunning: running,
            confirmedStopped: stopped,
            reason: reason
        )
    }
}

enum OCRRuntimeState: String {
    case disabled
    case paused
    case calibration
    case runningClockOnly
    case runningClockPenaltyWatch
    case stoppedClockHashing
    case safetyResync

    var label: String {
        switch self {
        case .disabled: return "OCR disabled"
        case .paused: return "OCR paused"
        case .calibration: return "Calibration diagnostics"
        case .runningClockOnly: return "Clock-only OCR"
        case .runningClockPenaltyWatch: return "Running clock + penalty watch"
        case .stoppedClockHashing: return "Stopped-clock hashing"
        case .safetyResync: return "Safety resync"
        }
    }
}

struct RinkLensPendingScoreConfirmation: Identifiable, Equatable {
    let id: UUID
    let team: Team
    let previous: Int
    let proposed: Int
    let observedAt: CFAbsoluteTime

    init(team: Team, previous: Int, proposed: Int, observedAt: CFAbsoluteTime) {
        self.id = UUID()
        self.team = team
        self.previous = previous
        self.proposed = proposed
        self.observedAt = observedAt
    }

    var message: String {
        "\(team.displayName) score changed from \(previous) to \(proposed). Accept this manual physical-scoreboard intervention? No goal popups will be created."
    }
}

@MainActor
final class HockeyScoreboardViewModel: ObservableObject {
    let diagnosticInstanceID = String(UUID().uuidString.prefix(8))
    private var architectureCancellables: Set<AnyCancellable> = []

    /// Recovery AJ / RL-077: legacy screens may still consume ViewModel
    /// projections, but authoritative owner changes are no longer rebroadcast as
    /// one unconditional application-wide invalidation stream. Only the active
    /// presentation domain is forwarded while migration to direct owner
    /// observation continues.
    private enum ArchitecturePresentationDomain: Equatable {
        case match
        case camera
        case calibration
        case ocr
        case operational
    }
    private var architectureInvalidationForwardedCount = 0
    private var architectureInvalidationSuppressedCount = 0

    var diagnosticIdentityText: String {
        "viewModel=\(diagnosticInstanceID) live={\(liveCameraService.diagnosticIdentityText)} ocr={\(ocrCameraService.diagnosticIdentityText)}"
    }

    private func cameraForensicBreadcrumb(_ action: CameraTraceAction, phase: String, extra: String = "") {
        let owner: CameraTraceOwner = currentScreen == .calibration ? .calibration : (currentScreen == .broadcast ? .broadcast : .diagnostics)
        let suffix = extra.isEmpty ? "" : " | \(extra)"
        CameraOwnershipTraceStore.record(
            action,
            owner: owner,
            reason: "vm=\(diagnosticInstanceID) phase=\(phase) screen=\(currentScreen.rawValue) mode=\(operatingMode.rawValue) transitioning=\(isScreenTransitioning) paused=\(isOCRPaused) wantsOCR=\(userWantsOCRRunning) liveSelected=\(liveCameraService.selectedCameraID ?? "none") ocrSelected=\(ocrCameraService.selectedCameraID ?? "none") liveRunning=\(liveCameraService.isSessionRunning) ocrRunning=\(ocrCameraService.isSessionRunning) liveSvc=\(liveCameraService.diagnosticInstanceID) ocrSvc=\(ocrCameraService.diagnosticInstanceID)\(suffix)"
        )
    }

    @Published private(set) var state = ScoreboardState()
    @Published private(set) var matchStateRevision: UInt64 = 0
    @Published private(set) var lastMatchStateActionText = "Match reducer awaiting first action"
    @Published private(set) var testOCROutcome: RinkLensTestOCROutcome = .idle
    @Published private(set) var testOCROutcomeText = "Test OCR has not run."
    @Published private(set) var pendingTestOCRApplyDescription: String?
    /// UX16c47 counts stale or superseded Test OCR completions that were fenced
    /// before any Calibration UI or accepted-value publication could occur.
    private(set) var testOCRStaleResultPreventionCount: Int = 0
    private(set) var testOCRCurrentResultPublicationCount: Int = 0
    private var pendingTestOCRResult: RinkLensPendingTestOCRResult?

    var canApplyTestOCRResult: Bool { pendingTestOCRResult != nil }

    var matchStateReducerDiagnosticText: String {
        let clock = state.clock ?? "--"
        let period = state.periodLabel ?? state.period.map { String($0) } ?? "--"
        let score = "\(state.homeScore.map { String($0) } ?? "--")-\(state.awayScore.map { String($0) } ?? "--")"
        return "revision=\(matchStateRevision) clock=\(clock) period=\(period) score=\(score) last={\(lastMatchStateActionText)}"
    }
    let ocrDiagnostics = OCRDiagnosticsStore()
    let calibrationStore = RinkLensCalibrationStore()
    let ocrConfigurationStore = RinkLensOCRConfigurationStore()
    let cameraControlStore = RinkLensCameraControlStore()
    let operationalStateStore = RinkLensOperationalStateStore()
    let gameEventLifecycleStore = RinkLensGameEventLifecycleStore.shared
    let matchEventJournal = RinkLensMatchEventJournal()
    @Published var lastRawOCRText: String?
    @Published var statusMessage: String?
    var ocrLayout: ScoreboardOCRLayout {
        get { calibrationStore.layout }
        set { calibrationStore.setLayout(newValue, source: "HockeyScoreboardViewModel", reason: "OCR layout projection changed") }
    }
    var boardCalibration: BoardCalibrationQuad {
        get { calibrationStore.boardCalibration }
        set { calibrationStore.setBoardCalibration(newValue, source: "HockeyScoreboardViewModel", reason: "Perspective calibration projection changed") }
    }
    @Published var selectedRegionKey: OCRRegionKey = .clock
    /// Build 691: names, logos and saved profiles have one transactional owner.
    /// Existing screen call sites use projections that route every write through
    /// RinkLensTeamIdentityStore rather than retaining independent ViewModel state.
    let teamIdentityStore = RinkLensTeamIdentityStore()
    var homeTeamName: String {
        get { teamIdentityStore.homeTeamName }
        set { setTeamIdentityNames(home: newValue, away: nil, source: "HockeyScoreboardViewModel", reason: "Home team-name projection edited") }
    }
    var awayTeamName: String {
        get { teamIdentityStore.awayTeamName }
        set { setTeamIdentityNames(home: nil, away: newValue, source: "HockeyScoreboardViewModel", reason: "Away team-name projection edited") }
    }
    var homeLogoImage: UIImage? {
        get { teamIdentityStore.homeLogoImage }
        set { teamIdentityStore.setHomeLogo(image: newValue, fileName: teamIdentityStore.homeLogoFileName, source: "HockeyScoreboardViewModel", reason: "Home logo image projection changed") }
    }
    var awayLogoImage: UIImage? {
        get { teamIdentityStore.awayLogoImage }
        set { teamIdentityStore.setAwayLogo(image: newValue, fileName: teamIdentityStore.awayLogoFileName, source: "HockeyScoreboardViewModel", reason: "Away logo image projection changed") }
    }
    var teamIdentityTemplates: [TeamIdentityTemplate] {
        get { teamIdentityStore.templates }
        set { teamIdentityStore.replaceTemplates(newValue, source: "HockeyScoreboardViewModel", reason: "Saved team identity profiles changed") }
    }
    var selectedTeamIdentityTemplateID: UUID? {
        get { teamIdentityStore.selectedTemplateID }
        set { teamIdentityStore.selectTemplate(newValue, source: "HockeyScoreboardViewModel", reason: "Active team identity profile changed") }
    }
    var defaultTeamIdentityTemplateID: UUID? {
        get { teamIdentityStore.defaultTemplateID }
        set { teamIdentityStore.setDefaultTemplate(newValue, source: "HockeyScoreboardViewModel", reason: "Default team identity profile changed") }
    }
    /// Build 698: Image Relay selection/enabled state is a read-only projection
    /// of the scoreboard-input lifecycle owner. No second ViewModel boolean is
    /// retained. The legacy comparison path reads the presentation store only.
    var imageRelayEnabled: Bool {
        if RinkLensRiskFeaturePolicy.isEnabled(.scoreboardInputLifecycleProjectionV2) {
            let lifecycle = scoreboardInputLifecycleStore.snapshot
            return lifecycle.mode == OperatingMode.imageRelay.rawValue
                && lifecycle.state != .stoppedByOperator
                && lifecycle.state != .stopping
                && lifecycle.state != .failed
        }
        return ScoreboardImageRelayStore.shared.snapshot().enabled
    }
    /// Read-only compatibility projection. Start history belongs to the
    /// scoreboard-input lifecycle owner; no view or ViewModel boolean can reset it.
    var imageRelayHasBeenStartedThisAppSession: Bool {
        scoreboardInputLifecycleStore.snapshot.hasStartedThisSession
    }

    var scoreboardInputControlIsTransitioning: Bool {
        RinkLensRiskFeaturePolicy.isEnabled(.transactionalImageRelayControlV23)
            && scoreboardInputLifecycleStore.snapshot.isTransitioning
    }

    var scoreboardInputControlIsPaused: Bool {
        guard RinkLensRiskFeaturePolicy.isEnabled(.transactionalImageRelayControlV23) else {
            return isOCRPausedByUser
        }
        let lifecycle = scoreboardInputLifecycleStore.snapshot
        if lifecycle.processingPaused { return true }
        switch lifecycle.state {
        case .running:
            return false
        case .starting:
            return false
        case .stopping, .stoppedByOperator, .armed, .waitingForCapture, .suspendedByRoute, .failed:
            return true
        }
    }

    /// Operator intent projection. Route suspension may pause processing but
    /// must not make an enabled Relay appear disabled or transfer ownership to UI.
    var scoreboardInputControlIsRequestedOn: Bool {
        let lifecycle = scoreboardInputLifecycleStore.snapshot
        return lifecycle.mode == OperatingMode.imageRelay.rawValue
            && lifecycle.operatorRequestedRunning
            && lifecycle.state != .stopping
            && lifecycle.state != .stoppedByOperator
            && lifecycle.state != .failed
    }

    var scoreboardInputControlIsPhysicallyRunning: Bool {
        let lifecycle = scoreboardInputLifecycleStore.snapshot
        return lifecycle.state == .running && !lifecycle.processingPaused
    }

    var scoreboardInputControlTitle: String {
        switch scoreboardInputLifecycleStore.snapshot.state {
        case .starting: return "Starting Relay"
        case .stopping: return "Stopping Relay"
        case .running: return "Stop Relay"
        case .waitingForCapture: return "Waiting for Camera"
        case .stoppedByOperator, .armed, .suspendedByRoute, .failed:
            return imageRelayHasBeenStartedThisAppSession ? "Resume Relay" : "Start Relay"
        }
    }

    var scoreboardInputControlSystemImage: String {
        // Keep one Image Relay glyph across Start/Starting/Running/Stopping.
        // State is conveyed by the authoritative title, colour and disabled
        // transition state rather than swapping between SF Symbol variants.
        "rectangle.on.rectangle"
    }

    /// Compatibility command boundary. It changes the lifecycle authority and
    /// never stores an independent Image Relay enabled value.
    func setImageRelayEnabled(_ enabled: Bool) {
        if enabled {
            let lifecycle = scoreboardInputLifecycleStore.snapshot
            if lifecycle.mode != OperatingMode.imageRelay.rawValue
                || lifecycle.state == .stoppedByOperator
                || lifecycle.state == .failed {
                scoreboardInputLifecycleStore.arm(
                    mode: OperatingMode.imageRelay.rawValue,
                    source: "HockeyScoreboardViewModel.setImageRelayEnabled",
                    reason: "Compatibility request selected Image Relay"
                )
            }
        } else {
            scoreboardInputLifecycleStore.operatorStop(
                source: "HockeyScoreboardViewModel.setImageRelayEnabled",
                reason: "Compatibility request stopped Image Relay"
            )
            scoreboardInputLifecycleStore.markStopped(
                source: "HockeyScoreboardViewModel.setImageRelayEnabled",
                reason: "Compatibility stop committed"
            )
        }
    }
    /// Build 690: ManualScoreController is the sole writable owner. These
    /// properties are projections/draft accessors retained for existing views.
    let manualScoreController = ManualScoreController()
    var manualScoreState: ManualScoreState { manualScoreController.state }
    var manualOverrideEnabled: Bool {
        let value = manualScoreController.state
        return value.globalManualModeEnabled
            || value.homeScoreOverrideActive
            || value.awayScoreOverrideActive
            || value.clockOverrideActive
            || value.periodOverrideActive
    }
    var overrideHomeScore: Int {
        get { manualScoreController.state.homeScoreDraft }
        set { manualScoreController.setHomeScoreDraft(newValue, source: "HockeyScoreboardViewModel", reason: "Manual score draft projection") }
    }
    var overrideAwayScore: Int {
        get { manualScoreController.state.awayScoreDraft }
        set { manualScoreController.setAwayScoreDraft(newValue, source: "HockeyScoreboardViewModel", reason: "Manual score draft projection") }
    }
    var overridePeriod: Int {
        get { manualScoreController.state.periodDraft }
        set { manualScoreController.setPeriodDraft(newValue, source: "HockeyScoreboardViewModel", reason: "Manual period draft projection") }
    }
    var activeTemplateID: UUID? {
        get { calibrationStore.activeTemplateID }
        set { calibrationStore.setActiveTemplateID(newValue, source: "HockeyScoreboardViewModel", reason: "Active rink profile projection changed") }
    }
    var hasUnsavedTemplateChanges: Bool {
        get { calibrationStore.isDirty }
        set { calibrationStore.setDirty(newValue, source: "HockeyScoreboardViewModel", reason: "Calibration dirty-state projection changed") }
    }
    private var lastAppliedRinkTemplateSignature: String?
    var ocrThresholds: OCRThresholds {
        get { ocrConfigurationStore.snapshot.thresholds }
        set { ocrConfigurationStore.update(source: "HockeyScoreboardViewModel", reason: "OCR thresholds changed") { $0.thresholds = newValue } }
    }
    var ocrColourProfiles: OCRColourProfileSet {
        get { calibrationStore.colourProfiles }
        set {
            calibrationStore.setColourProfiles(newValue, source: "HockeyScoreboardViewModel", reason: "OCR colour profiles changed")
            appendSchedulerDiagnostic("UX14t OCR colour profiles changed: \(newValue.compactSummary)")
            selectedRegionPreviewStatus = "Colour profile updated. Press Test OCR to render Raw / Processed / Threshold previews."
            RinkLensStructuredEventLogger.shared.record(
                domain: .ocrConfiguration,
                event: "ocr_decorative_preview_deferred",
                entityID: selectedRegionKey.rawValue,
                previous: ["trigger": "automatic-colour-profile-render"],
                next: ["trigger": "explicit-test-ocr"],
                source: "HockeyScoreboardViewModel.ocrColourProfiles",
                reason: "Avoid blocking operator taps with perspective correction and UIImage generation on the MainActor",
                authoritativeOwner: "RinkLensOCRConfigurationStore"
            )
        }
    }
    var ocrScoreboardType: OCRScoreboardType {
        get { ocrConfigurationStore.snapshot.scoreboardType }
        set { ocrConfigurationStore.update(source: "HockeyScoreboardViewModel", reason: "Scoreboard Type changed") { $0.scoreboardType = newValue }; applyOperatorOCRSettings(reason: "Scoreboard Type changed") }
    }
    var ocrOperatorMode: OCROperatorMode {
        get { ocrConfigurationStore.snapshot.operatorMode }
        set { ocrConfigurationStore.update(source: "HockeyScoreboardViewModel", reason: "OCR Mode changed") { $0.operatorMode = newValue }; applyOperatorOCRSettings(reason: "OCR Mode changed") }
    }
    var autoOCRAssistEnabled: Bool {
        get { ocrConfigurationStore.snapshot.autoAssistEnabled }
        set { ocrConfigurationStore.update(source: "HockeyScoreboardViewModel", reason: "Auto OCR Assist changed") { $0.autoAssistEnabled = newValue }; applyOperatorOCRSettings(reason: "Auto OCR Assist changed") }
    }
    var smartChangeDetectionEnabled: Bool {
        get { ocrConfigurationStore.snapshot.smartChangeDetectionEnabled }
        set { ocrConfigurationStore.update(source: "HockeyScoreboardViewModel", reason: "Smart Change Detection changed") { $0.smartChangeDetectionEnabled = newValue }; updatePixelHashingStatus(false, detail: newValue ? "Smart Change Detection ready." : "Smart Change Detection disabled by operator.", force: true) }
    }
    var clockReadingPreset: OCRZoneReadingPreset {
        get { ocrConfigurationStore.snapshot.clockPreset }
        set { ocrConfigurationStore.update(source: "HockeyScoreboardViewModel", reason: "Clock preset changed") { $0.clockPreset = newValue }; applyOperatorOCRSettings(reason: "Clock preset changed") }
    }
    var scoreReadingPreset: OCRZoneReadingPreset {
        get { ocrConfigurationStore.snapshot.scorePreset }
        set { ocrConfigurationStore.update(source: "HockeyScoreboardViewModel", reason: "Score preset changed") { $0.scorePreset = newValue }; applyOperatorOCRSettings(reason: "Score preset changed") }
    }
    var penaltyReadingPreset: OCRZoneReadingPreset {
        get { ocrConfigurationStore.snapshot.penaltyPreset }
        set { ocrConfigurationStore.update(source: "HockeyScoreboardViewModel", reason: "Penalty preset changed") { $0.penaltyPreset = newValue }; applyOperatorOCRSettings(reason: "Penalty preset changed") }
    }
    @Published private(set) var ocrTuningSnapshot = OCROperatorTuningSnapshot(
        clock: OCRZoneTuning(cadenceSeconds: 0.7, confidence: 0.65, trust: 1),
        score: OCRZoneTuning(cadenceSeconds: 1.5, confidence: 0.80, trust: 3),
        period: OCRZoneTuning(cadenceSeconds: 3.0, confidence: 0.75, trust: 1),
        penaltyTime: OCRZoneTuning(cadenceSeconds: 0.8, confidence: 0.70, trust: 1),
        penaltyPlayer: OCRZoneTuning(cadenceSeconds: 0.8, confidence: 0.70, trust: 2)
    )
    @Published private(set) var ocrAssistStatusText = "OCR Assist ready"
    var calibrationRotationDegrees: Double {
        get { calibrationStore.calibrationRotationDegrees }
        set { calibrationStore.setCalibrationRotation(newValue, source: "HockeyScoreboardViewModel", reason: "Calibration rotation changed") }
    }
    @Published var debugHistory: [String] = []
    @Published var isDebugVisible = false
    @Published var freezeDebugSnapshot = false
    var ocrIntervalSeconds: Double {
        get { ocrConfigurationStore.snapshot.intervalSeconds }
        set { ocrConfigurationStore.update(source: "HockeyScoreboardViewModel", reason: "OCR interval changed") { $0.intervalSeconds = newValue } }
    }
    @Published var performanceSafeModeEnabled = false
    @Published private(set) var ocrMotionProtectionActive = false
    @Published private(set) var ocrMotionProtectionStatusText = "OCR camera movement protection idle"
    var cameraRotationLockEnabled: Bool {
        get { cameraControlStore.snapshot.rotationLockEnabled }
        set { cameraControlStore.setRotationLockEnabled(newValue, source: "HockeyScoreboardViewModel", reason: "Camera rotation lock edited"); persistCameraRotationSettingsIfReady() }
    }
    var enableSegmentedFallback: Bool {
        get { ocrConfigurationStore.snapshot.segmentedFallbackEnabled }
        set { ocrConfigurationStore.update(source: "HockeyScoreboardViewModel", reason: "Segmented fallback changed") { $0.segmentedFallbackEnabled = newValue } }
    }
    var isPostOCRSmoothingEnabled: Bool {
        get { ocrConfigurationStore.snapshot.smoothingEnabled }
        set { ocrConfigurationStore.update(source: "HockeyScoreboardViewModel", reason: "OCR smoothing changed") { $0.smoothingEnabled = newValue }; persistOCRSmoothingSettingsIfReady() }
    }
    var gameClockDirection: GameClockDirection {
        get { ocrConfigurationStore.snapshot.clockDirection }
        set { ocrConfigurationStore.update(source: "HockeyScoreboardViewModel", reason: "Game clock direction changed") { $0.clockDirection = newValue } }
    }
    var liveClockDirectionStatusText: String {
        switch gameClockDirection {
        case .countUp:
            return "Count Up"
        case .countDown:
            return "Count Down"
        case .auto:
            return autoClockDirectionIsLocked
                ? "Auto detected: \(localClockDirection.title)"
                : "Auto determining from complete OCR readings"
        }
    }

    /// Build 527 exposes the single trusted Clock authority to the Broadcast-only
    /// presentation bridge. The bridge may interpolate this direction, but it may
    /// not infer or reverse direction independently.
    var trustedPresentationClockDirection: GameClockDirection? {
        switch gameClockDirection {
        case .countUp, .countDown:
            return gameClockDirection
        case .auto:
            return autoClockDirectionIsLocked ? localClockDirection : nil
        }
    }

    /// A stopped physical board, an accepted reset or explicit manual mode is a
    /// running-epoch boundary where the presentation may safely rebase to the
    /// latest trusted anchor. OCR lateness alone never enables a rebase.
    var trustedClockMayRebasePresentation: Bool {
        trustedClockConfirmedStopped || !localClockIsRunning
    }

    var trustedClockAuthorityStatusText: String {
        let anchor = trustedClockAnchorSeconds.map { formatClock(seconds: $0) } ?? "none"
        let age: String
        if trustedClockLastAcceptedAt > 0 {
            age = String(format: "%.2fs", max(0, CFAbsoluteTimeGetCurrent() - trustedClockLastAcceptedAt))
        } else {
            age = "--"
        }
        let pending = "single=\(trustedClockEvidenceState.provisionalCount) reanchor=\(trustedClockEvidenceState.reanchorCount) seq=\(trustedClockEvidenceState.observationSequence)"
        let movementState = trustedClockEvidenceIsStale
            ? "stale-unknown"
            : (trustedClockConfirmedStopped ? "stopped" : (localClockIsRunning ? "running" : "unknown"))
        return "anchor=\(anchor) age=\(age) movement=\(movementState) running=\(localClockIsRunning) stopped=\(trustedClockConfirmedStopped) direction=\(liveClockDirectionStatusText) pending={\(pending)} resetRecovery={\(fullBoardResetRecoveryDiagnosticText)} decision={\(trustedClockLastDecision)}"
    }
    let scoreboardDefaultsStore = RinkLensScoreboardDefaultsStore()
    var defaultClock: String { get { scoreboardDefaultsStore.snapshot.clock } set { scoreboardDefaultsStore.mutate(source: "HockeyScoreboardViewModel", reason: "Default Clock edited") { $0.clock = newValue }; persistDefaultScoreboardValuesIfReady() } }
    var defaultHomeGoals: Int { get { scoreboardDefaultsStore.snapshot.homeGoals } set { scoreboardDefaultsStore.mutate(source: "HockeyScoreboardViewModel", reason: "Default Home score edited") { $0.homeGoals = newValue }; persistDefaultScoreboardValuesIfReady() } }
    var defaultAwayGoals: Int { get { scoreboardDefaultsStore.snapshot.awayGoals } set { scoreboardDefaultsStore.mutate(source: "HockeyScoreboardViewModel", reason: "Default Away score edited") { $0.awayGoals = newValue }; persistDefaultScoreboardValuesIfReady() } }
    var defaultPeriodOption: String { get { scoreboardDefaultsStore.snapshot.periodOption } set { scoreboardDefaultsStore.mutate(source: "HockeyScoreboardViewModel", reason: "Default period option edited") { $0.periodOption = newValue }; persistDefaultScoreboardValuesIfReady() } }
    var defaultPeriod: Int { get { scoreboardDefaultsStore.snapshot.period } set { scoreboardDefaultsStore.mutate(source: "HockeyScoreboardViewModel", reason: "Default period edited") { $0.period = newValue }; persistDefaultScoreboardValuesIfReady() } }
    var defaultHomePenalty1Player: Int { get { scoreboardDefaultsStore.snapshot.homePenalty1Player } set { scoreboardDefaultsStore.mutate(source: "HockeyScoreboardViewModel", reason: "Default Home penalty 1 player edited") { $0.homePenalty1Player = newValue }; persistDefaultScoreboardValuesIfReady() } }
    var defaultHomePenalty1Clock: String { get { scoreboardDefaultsStore.snapshot.homePenalty1Clock } set { scoreboardDefaultsStore.mutate(source: "HockeyScoreboardViewModel", reason: "Default Home penalty 1 Clock edited") { $0.homePenalty1Clock = newValue }; persistDefaultScoreboardValuesIfReady() } }
    var defaultHomePenalty2Player: Int { get { scoreboardDefaultsStore.snapshot.homePenalty2Player } set { scoreboardDefaultsStore.mutate(source: "HockeyScoreboardViewModel", reason: "Default Home penalty 2 player edited") { $0.homePenalty2Player = newValue }; persistDefaultScoreboardValuesIfReady() } }
    var defaultHomePenalty2Clock: String { get { scoreboardDefaultsStore.snapshot.homePenalty2Clock } set { scoreboardDefaultsStore.mutate(source: "HockeyScoreboardViewModel", reason: "Default Home penalty 2 Clock edited") { $0.homePenalty2Clock = newValue }; persistDefaultScoreboardValuesIfReady() } }
    var defaultAwayPenalty1Player: Int { get { scoreboardDefaultsStore.snapshot.awayPenalty1Player } set { scoreboardDefaultsStore.mutate(source: "HockeyScoreboardViewModel", reason: "Default Away penalty 1 player edited") { $0.awayPenalty1Player = newValue }; persistDefaultScoreboardValuesIfReady() } }
    var defaultAwayPenalty1Clock: String { get { scoreboardDefaultsStore.snapshot.awayPenalty1Clock } set { scoreboardDefaultsStore.mutate(source: "HockeyScoreboardViewModel", reason: "Default Away penalty 1 Clock edited") { $0.awayPenalty1Clock = newValue }; persistDefaultScoreboardValuesIfReady() } }
    var defaultAwayPenalty2Player: Int { get { scoreboardDefaultsStore.snapshot.awayPenalty2Player } set { scoreboardDefaultsStore.mutate(source: "HockeyScoreboardViewModel", reason: "Default Away penalty 2 player edited") { $0.awayPenalty2Player = newValue }; persistDefaultScoreboardValuesIfReady() } }
    var defaultAwayPenalty2Clock: String { get { scoreboardDefaultsStore.snapshot.awayPenalty2Clock } set { scoreboardDefaultsStore.mutate(source: "HockeyScoreboardViewModel", reason: "Default Away penalty 2 Clock edited") { $0.awayPenalty2Clock = newValue }; persistDefaultScoreboardValuesIfReady() } }
    /// Build 706: the camera-control owner contains the requested zoom store.
    /// Hardware outcomes are acknowledgements/projections; HockeyCameraService
    /// remains the sole applied hardware owner.
    var cameraZoomStore: RinkLensCameraZoomStore { cameraControlStore.zoomStore }
    var cameraZoomFactor: CGFloat {
        get { cameraZoomStore.requested(for: .ocr) }
        set { cameraZoomStore.request(newValue, for: .ocr, deviceID: ocrCameraService.selectedCameraID, source: "HockeyScoreboardViewModel", reason: "OCR zoom projection changed") }
    }
    /// v0.9.1l: Calibration camera source/profile/lock settings.
    var calibrationCameraProfile: CalibrationCameraProfile {
        get { cameraControlStore.snapshot.calibrationProfile }
        set {
            cameraControlStore.setCalibrationProfile(newValue, source: "HockeyScoreboardViewModel", reason: "Calibration camera profile changed")
            calibrationStore.setDirty(true, source: "HockeyScoreboardViewModel", reason: "Camera preference changed for active rink profile")
            persistCalibrationCameraProfileIfReady()
        }
    }
    @Published private(set) var calibrationCameraProfileStatusText = "Manual calibration profile ready"
    @Published private(set) var calibrationCameraWarningText: String?
    /// Live/broadcast camera zoom remains independent, but shares the same
    /// requested/applied authority contract.
    var liveCameraZoomFactor: CGFloat {
        get { cameraZoomStore.requested(for: .live) }
        set { cameraZoomStore.request(newValue, for: .live, deviceID: liveCameraService.selectedCameraID, source: "HockeyScoreboardViewModel", reason: "Live zoom projection changed") }
    }
    /// Recovery B UI capability projection. Operator intent remains 0.5x...5x
    /// whenever Broadcast is available. The physical-source decision is made by
    /// CaptureLifecycleController only when a committed request crosses the optical
    /// domain; an open recording is held/rebound in the same file instead of hiding 0.5x.
    var effectiveBroadcastZoomRange: ClosedRange<CGFloat> {
        0.5...5.0
    }

    var verifiedBroadcastZoomFactor: CGFloat {
        cameraZoomStore.applied(for: .live)
    }
    /// When enabled, broadcast digital zoom presets ramp smoothly instead of jumping instantly.
    var smoothBroadcastZoomTransitionsEnabled: Bool {
        get { cameraControlStore.snapshot.smoothBroadcastZoomTransitionsEnabled }
        set { cameraControlStore.setSmoothBroadcastZoomTransitionsEnabled(newValue, source: "HockeyScoreboardViewModel", reason: "Smooth Broadcast zoom edited") }
    }
    /// Operator-selected ramp duration for broadcast digital zoom changes.
    var broadcastZoomTransitionSpeed: BroadcastZoomTransitionSpeed {
        get { cameraControlStore.snapshot.broadcastZoomTransitionSpeed }
        set { cameraControlStore.setBroadcastZoomTransitionSpeed(newValue, source: "HockeyScoreboardViewModel", reason: "Broadcast zoom transition speed edited") }
    }
    var broadcastVideoStabilisationEnabled: Bool {
        cameraControlStore.snapshot.broadcastVideoStabilisationEnabled
    }

    var broadcastImageQualityPolicy: BroadcastImageQualityPolicy {
        cameraControlStore.snapshot.broadcastImageQualityPolicy
    }

    var broadcastProductionProfile: BroadcastProductionProfile {
        cameraControlStore.snapshot.broadcastProductionProfile
    }

    func setBroadcastProductionProfile(_ profile: BroadcastProductionProfile, source: String, reason: String) {
        let previousProfile = cameraControlStore.snapshot.broadcastProductionProfile
        let policy = profile.cameraPolicy
        let previousPolicy = cameraControlStore.snapshot.broadcastImageQualityPolicy
        let capture = externalOCRMultiCamCoordinator.snapshot
        let targetCadence = RinkLensCaptureCadence(integerFPS: policy.preferredWideFPS)
        let appliedCadenceMatches = capture.liveFormat?.cadence == targetCadence

        if previousProfile != profile {
            cameraControlStore.setBroadcastProductionProfile(profile, source: source, reason: reason)
            _ = RecordingEngine.shared.adoptRecommendedCustomVideoBitrate(
                profile.recommendedCustomRecordingBitrateMbps,
                source: source,
                reason: "Master Video Quality changed to \(profile.rawValue); RecordingEngine adopted its recommended custom-compression starting point"
            )
        }

        if previousPolicy == policy && appliedCadenceMatches {
            RinkLensStructuredEventLogger.shared.record(
                domain: .cameraControl,
                event: "broadcast_production_profile_camera_intent_coalesced",
                entityID: "broadcast-connection",
                previous: [
                    "profile": previousProfile.rawValue,
                    "cameraPolicy": previousPolicy.rawValue,
                    "fps": capture.liveFormat?.cadence.displayText ?? "unknown"
                ],
                next: [
                    "profile": profile.rawValue,
                    "cameraPolicy": policy.rawValue,
                    "streamProfile": profile.streamQualityProfile.rawValue,
                    "fixedTargetFPS": targetCadence.displayText,
                    "duplicateSuppressed": "true"
                ],
                source: source,
                reason: reason,
                captureGeneration: capture.transitionGeneration,
                authoritativeOwner: "RinkLensCameraControlStore"
            )
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.captureLifecycleController.applyBroadcastImageQualityPolicyFromOwner(
                policy,
                previousPolicy: previousPolicy,
                source: source,
                reason: reason
            )
        }
    }

    /// Requested, resolved and physically applied camera quality remain
    /// separate. The menu uses this projection instead of implying that a stored
    /// Motion/Image request changed cadence while the recording contract froze it.
    var broadcastImageQualityPhysicalStatusText: String {
        let capture = externalOCRMultiCamCoordinator.snapshot
        let appliedFPS = capture.liveFormat?.cadence.displayText ?? "unknown"
        let requestedFPS = RinkLensCaptureCadence(integerFPS: broadcastImageQualityPolicy.preferredWideFPS).displayText
        let requestedPreference = RinkLensCaptureFormatPreference(
            width: capture.liveFormat?.width ?? 1920,
            height: capture.liveFormat?.height ?? 1080,
            fps: broadcastImageQualityPolicy.preferredWideFPS
        )
        let requestedCadenceSupported = capture.liveDeviceID.map {
            liveCameraService.supportsCapturePreference(requestedPreference, physicalDeviceID: $0)
        } ?? false
        let resolvedFPS = requestedCadenceSupported
            ? requestedFPS
            : RinkLensCaptureCadence(integerFPS: 30).displayText

        if RinkLensRecordingCaptureLease.shared.isWriterContractOpen(), appliedFPS != resolvedFPS {
            return "Requested: \(broadcastImageQualityPolicy.rawValue) (\(resolvedFPS)). Applied: \(appliedFPS). The current recording keeps its physical source fixed; this request applies after Stop."
        }
        if appliedFPS == resolvedFPS {
            let limitation = requestedFPS != resolvedFPS ? " (format-limited from \(requestedFPS))" : ""
            if broadcastImageQualityPolicy.allowsAutomaticFrameRate {
                return "Physically applied: \(broadcastImageQualityPolicy.rawValue) with a \(appliedFPS) ceiling\(limitation); AVFoundation may reduce actual cadence to 24fps in low light."
            }
            return "Physically applied: \(broadcastImageQualityPolicy.rawValue) at \(appliedFPS)\(limitation)."
        }
        return "Requested: \(broadcastImageQualityPolicy.rawValue) at \(resolvedFPS). Physically applied: \(appliedFPS); camera transaction in progress."
    }

    func setBroadcastVideoStabilisationEnabled(_ enabled: Bool, source: String, reason: String) {
        cameraControlStore.setBroadcastVideoStabilisationEnabled(enabled, source: source, reason: reason)
        externalOCRMultiCamCoordinator.setBroadcastVideoStabilisation(enabled: enabled, reason: reason)
    }
    private var lastAppliedFramePolicyEnabled: Bool?
    private var lastAppliedFramePolicyInterval: CFTimeInterval?
    private var transitionPublishFreezeDepth = 0
    private var pendingFramePolicyRefreshAfterFreeze = false

    /// Preview-only rotation offsets. Live/Broadcast and OCR/Calibration must stay independent
    /// because UVC/external cameras can present with different physical orientations.
    var livePreviewRotationOffsetDegrees: CGFloat {
        get { cameraControlStore.snapshot.livePreviewRotationOffsetDegrees }
        set {
            cameraControlStore.setLivePreviewRotation(newValue, source: "HockeyScoreboardViewModel", reason: "Live preview rotation changed")
            persistCameraRotationSettingsIfReady()
        }
    }
    var ocrPreviewRotationOffsetDegrees: CGFloat {
        get { cameraControlStore.snapshot.ocrPreviewRotationOffsetDegrees }
        set {
            cameraControlStore.setOCRPreviewRotation(newValue, source: "HockeyScoreboardViewModel", reason: "OCR preview rotation changed")
            calibrationStore.setDirty(true, source: "HockeyScoreboardViewModel", reason: "OCR rotation changed for active rink profile")
            persistCameraRotationSettingsIfReady()
        }
    }
    @Published var previewViewportSize: CGSize = .zero
    // UX16d7: OCR zones are authored on Calibration's video-aligned 16:9 layer.
    // Broadcast/Command Centre container sizes must not remap those saved zones.
    // Retain the last authoritative Calibration video viewport and use a canonical
    // 1920x1080 fallback before Calibration has reported its geometry.
    private var ocrGeometryViewportSize = CGSize(width: 1920, height: 1080)

    private var authoritativeOCRGeometryViewportSize: CGSize {
        guard ocrGeometryViewportSize.width > 10, ocrGeometryViewportSize.height > 10 else {
            return CGSize(width: 1920, height: 1080)
        }
        return ocrGeometryViewportSize
    }

    // UX16c17: Camera sample buffers arrive on camera.ocr.output.queue. This
    // status confirms that no ObservableObject mutation occurs until the frame
    // has crossed onto DispatchQueue.main.
    @Published private(set) var ocrFrameHandoffStatusText = "OCR frame handoff awaiting first frame"
    private var hasConfirmedMainThreadFrameHandoff = false

    func setCalibrationPreviewViewportSize(_ size: CGSize, reason: String) {
        guard currentScreen == .calibration else {
            MainThreadStallMonitor.shared.traceRenderPreviewToggle(
                String(format: "ignored calibration viewport %.0fx%.0f because screen=%@ reason=%@", size.width, size.height, String(describing: currentScreen), reason)
            )
            return
        }
        guard size.width > 10, size.height > 10 else {
            MainThreadStallMonitor.shared.traceRenderPreviewToggle(
                String(format: "ignored invalid calibration viewport %.0fx%.0f reason=%@", size.width, size.height, reason)
            )
            return
        }
        previewViewportSize = size
        ocrGeometryViewportSize = size
        MainThreadStallMonitor.shared.traceRenderPreviewToggle(
            String(format: "UX16d7 calibration OCR geometry locked %.0fx%.0f reason=%@", size.width, size.height, reason)
        )
    }

    // v0.8.8m7b: high-frequency OCR/debug diagnostics live in OCRDiagnosticsStore.
    // These computed shims preserve existing ViewModel call sites without making
    // the full ViewModel publish every OCR diagnostic/crop/hash update.
    var regionOCRPreview: [OCRRegionKey: String] {
        get { ocrDiagnostics.regionOCRPreview }
        set { ocrDiagnostics.regionOCRPreview = newValue }
    }
    var regionOCRRecognizer: [OCRRegionKey: RecognitionStrategy] {
        get { ocrDiagnostics.regionOCRRecognizer }
        set { ocrDiagnostics.regionOCRRecognizer = newValue }
    }
    var ocrDiagnosticDisplayOptions: OCRDiagnosticDisplayOptions {
        get { ocrDiagnostics.ocrDiagnosticDisplayOptions }
        set { ocrDiagnostics.ocrDiagnosticDisplayOptions = newValue }
    }
    var selectedRegionRawPreviewImage: UIImage? {
        get { ocrDiagnostics.selectedRegionRawPreviewImage }
        set { ocrDiagnostics.selectedRegionRawPreviewImage = newValue }
    }
    var selectedRegionProcessedPreviewImage: UIImage? {
        get { ocrDiagnostics.selectedRegionProcessedPreviewImage }
        set { ocrDiagnostics.selectedRegionProcessedPreviewImage = newValue }
    }
    var selectedRegionThresholdedPreviewImage: UIImage? {
        get { ocrDiagnostics.selectedRegionThresholdedPreviewImage }
        set { ocrDiagnostics.selectedRegionThresholdedPreviewImage = newValue }
    }

    var selectedRegionSegmentPreviewImage: UIImage? {
        get { ocrDiagnostics.selectedRegionSegmentPreviewImage }
        set { ocrDiagnostics.selectedRegionSegmentPreviewImage = newValue }
    }
    var selectedRegionPreviewStatus: String {
        get { ocrDiagnostics.selectedRegionPreviewStatus }
        set { ocrDiagnostics.selectedRegionPreviewStatus = newValue }
    }
    var regionLikelyLabels: [OCRRegionKey: String] {
        get { ocrDiagnostics.regionLikelyLabels }
        set { ocrDiagnostics.regionLikelyLabels = newValue }
    }
    var ocrFieldConfidence: [OCRRegionKey: OCRFieldConfidence] {
        get { ocrDiagnostics.ocrFieldConfidence }
        set { ocrDiagnostics.ocrFieldConfidence = newValue }
    }
    var ocrTrustSummary: OCRTrustSummary {
        get { ocrDiagnostics.ocrTrustSummary }
        set { ocrDiagnostics.ocrTrustSummary = newValue }
    }
    var latestOCRCandidateState: ScoreboardState {
        get { ocrDiagnostics.latestOCRCandidateState }
        set { ocrDiagnostics.latestOCRCandidateState = newValue }
    }
    var isPixelHashingActive: Bool {
        get { ocrDiagnostics.isPixelHashingActive }
        set { ocrDiagnostics.isPixelHashingActive = newValue }
    }
    var ocrPixelHashingStatusText: String {
        get { ocrDiagnostics.ocrPixelHashingStatusText }
        set { ocrDiagnostics.ocrPixelHashingStatusText = newValue }
    }
    var ocrPixelHashingDetailText: String {
        get { ocrDiagnostics.ocrPixelHashingDetailText }
        set { ocrDiagnostics.ocrPixelHashingDetailText = newValue }
    }
    var regionDetectionStates: [OCRRegionKey: OCRRegionDetectionState] {
        get { ocrDiagnostics.regionDetectionStates }
        set { ocrDiagnostics.regionDetectionStates = newValue }
    }

    var matchTimeline: [BroadcastEvent] { matchEventJournal.timeline }
    /// Build 690 popup authority. The public values are read-only projections.
    let overlayEventStateMachine = RinkLensOverlayEventStateMachine()
    var activeBroadcastBanner: BroadcastEvent? { overlayEventStateMachine.activeBroadcastBanner }
    var activeIntermissionReel: BroadcastIntermissionReelState? { overlayEventStateMachine.activeIntermissionReel }
    var broadcastPhase: BroadcastPhase { matchEventJournal.phase }
    var broadcastPhaseState: BroadcastPhaseState { matchEventJournal.phaseState }
    var broadcastPhaseTransitionHistory: [BroadcastPhaseTransition] { matchEventJournal.phaseHistory }
    private var broadcastPhaseStateMachine = BroadcastPhaseStateMachine(initial: .inPlay(period: 1, trigger: .appLaunch, reason: "Initial broadcast phase"))
    @Published private(set) var lastIntermissionDiagnostic: String = "Intermission inactive"
    /// Build 691 clock authority owns relay/trusted/presentation projections.
    /// The accepted Clock itself remains owned by ScoreboardState through the reducer.
    let gameClockAuthority = RinkLensGameClockAuthority()

    /// Accepted penalties are owned by ScoreboardState via the match reducer.
    /// The lifecycle store owns confirmation and Image Relay candidates only.
    let penaltyLifecycleStore = RinkLensPenaltyLifecycleStore()
    var activePenaltyClocks: [PenaltyClock] { StrengthStateCalculator.activePenaltyClocks(from: state) }
    var currentStrengthState: StrengthState { StrengthStateCalculator.strengthState(from: activePenaltyClocks) }

    // Image Relay metadata carries score, Period, penalty and physical Clock
    // movement evidence. Build 708 removes textual Clock OCR/event-time metadata.
    @Published private(set) var imageRelayMetadataPeriod: Int?
    @Published private(set) var imageRelayMetadataHomeScore: Int?
    @Published private(set) var imageRelayMetadataAwayScore: Int?
    @Published private(set) var pendingImageRelayScoreConfirmation: RinkLensPendingScoreConfirmation?
    var imageRelayMetadataPenaltyClocks: [PenaltyClock] { penaltyLifecycleStore.relayClocks }
    var imageRelayMetadataStrengthState: StrengthState { penaltyLifecycleStore.relayStrength }
    @Published private(set) var imageRelayMetadataDiagnostic = "Metadata relay awaiting first observation"
    private var imageRelayMetadataClockRunning: Bool?
    private var imageRelayTimeoutActive = false
    private var imageRelayTimeoutStartedAt: CFAbsoluteTime?
    /// Build 703 legacy rollback storage. While the V3 authority flag is enabled,
    /// stoppage identity and immutable Clock evidence are projections of the game
    /// event lifecycle owner and these values remain unused.
    private var legacyImageRelayFrozenClockImagePNGData: Data?
    private var legacyImageRelayCurrentStoppageID: UUID?
    private var imageRelayFrozenClockImagePNGData: Data? {
        if RinkLensRiskFeaturePolicy.isEnabled(.stoppageClockEvidenceAuthorityV3) {
            return gameEventLifecycleStore.activeStoppedClockEvidence?.imagePNGData
        }
        return legacyImageRelayFrozenClockImagePNGData
    }
    private var imageRelayCurrentStoppageID: UUID? {
        if RinkLensRiskFeaturePolicy.isEnabled(.stoppageClockEvidenceAuthorityV3) {
            return gameEventLifecycleStore.activeStoppageID
        }
        return legacyImageRelayCurrentStoppageID
    }
    /// Live-play penalty-removal popups wait two seconds and revalidate before
    /// entering the unified overlay queue.
    private var imageRelayLiveStrengthPopupTasks: [String: Task<Void, Never>] = [:]
    private var imageRelayRestartReleaseDue: CFAbsoluteTime?
    private var imageRelayRestartReleaseStoppageID: UUID?
    /// Retained after an empty release so a goal/penalty recognised slightly late
    /// can still publish immediately once restart+5s has already elapsed.
    private var imageRelayLastCredibleRestartReleaseDeadline: CFAbsoluteTime?
    private var imageRelayLastCredibleRestartStoppageID: UUID?
    /// A contradictory stop must persist before it can invalidate an established
    /// restart+5s popup deadline. One noisy movement observation is ignored.
    private var imageRelayStableStopCancellationTask: Task<Void, Never>?
    private var imageRelayStableStopToken = UUID()
    private var imageRelayStopCandidateInProgress = false
    private var imageRelayStopCandidateObservedAt: CFAbsoluteTime?
    private var imageRelayStopCandidateFrozenClockImagePNGData: Data?
    private var imageRelayStopCandidateHomeScoreBaseline: Int?
    private var imageRelayStopCandidateAwayScoreBaseline: Int?
    private var imageRelayStopCandidateHomeScoreObservedAt: CFAbsoluteTime?
    private var imageRelayStopCandidateAwayScoreObservedAt: CFAbsoluteTime?
    private let imageRelayStableStopConfirmationSeconds: CFAbsoluteTime = 2.1
    private let imageRelayLateEventGraceSeconds: CFAbsoluteTime = 12.0
    /// Baseline for automatic Image Relay goal detection. Build 671 seeds each
    /// side independently from a recognised value or the current MatchState, so
    /// one unreadable zero cannot block the other team's first goal.
    private var imageRelayScoreBaselineReady = false
    /// Build 631 goal authority: one immutable score baseline per physical
    /// stoppage. Intermediate +1 observations never create goal events.
    private var imageRelayStoppageHomeScoreBaseline: Int?
    private var imageRelayStoppageAwayScoreBaseline: Int?
    private var imageRelayStoppageHomeScoreObservedAt: CFAbsoluteTime?
    private var imageRelayStoppageAwayScoreObservedAt: CFAbsoluteTime?
    private var imageRelayCancelledGoalCount = 0
    private var imageRelayPenaltyBaselineReady = false
    private var imageRelayPenaltyBaselineStartedAt: CFAbsoluteTime?
    private let imageRelayPenaltyStartupBaselineSeconds: CFAbsoluteTime = 2.0
    private var imageRelayActivePenaltyByIdentity: [String: PenaltyClock] = [:]
    private var imageRelayPendingEvents: [RinkLensRelayPendingEvent] {
        get { gameEventLifecycleStore.relayPendingEvents }
        _modify {
            var draft = gameEventLifecycleStore.relayPendingEvents
            defer {
                gameEventLifecycleStore.replaceRelayPendingEvents(
                    draft,
                    source: "HockeyScoreboardViewModel",
                    reason: "Image Relay pending-event transaction"
                )
            }
            yield &draft
        }
    }
    private var imageRelayPopupReleaseTask: Task<Void, Never>?
    // Build 614 fences stale/cancelled relay work and protects player lifecycles
    // through capture-generation and route hand-offs.
    private var imageRelayLastAcceptedCaptureGeneration = 0
    private var imageRelayLastAcceptedSourceSequence: Int?
    // Build 677 prevents the typed score-candidate observation and the
    // following merged visual observation from counting the same camera frame
    // twice toward score confirmation.
    private var imageRelayLastDirectScoreGeneration = 0
    private var imageRelayLastDirectScoreSequence: Int?
    private var imageRelayMinimumSourceSequenceAfterResume: Int?
    private var imageRelayPenaltyResumeProtectionUntil: CFAbsoluteTime = 0
    private var imageRelayPenaltyResumeKnownIdentities: Set<String> = []
    private var imageRelayBulkEmptyPenaltyCycleCount = 0
    /// Build 617 keeps per-team penalty snapshot evidence across intermittent
    /// unresolved crops. A contradictory complete snapshot resets the candidate;
    /// an unresolved crop pauses it. Two matching complete snapshots support the
    /// arrangement and three prove absence from both physical slots.
    private var imageRelayTeamPenaltySnapshotSignature: [Team: String] = [:]
    private var imageRelayTeamPenaltySnapshotCount: [Team: Int] = [:]
    private var imageRelayTeamPenaltySnapshotFirstObservedAt: [Team: CFAbsoluteTime] = [:]
    private var imageRelayTeamPenaltySnapshotLastObservedAt: [Team: CFAbsoluteTime] = [:]
    private let imageRelayTeamPenaltyEvidenceWindow: CFAbsoluteTime = 20.0
    /// Build 635: a player lifecycle survives hash/extractor variation while the
    /// same physical slot remains occupied. OCR may enrich this identity later.
    private var imageRelayPenaltyLifecycleIDBySlot: [OCRRegionKey: String] = [:]
    /// Build 718 tracks the viewer-authority occupancy projection independently
    /// from OCR/blank-baseline evidence. A newly visible confirmed player/timer
    /// pair can therefore start the lifecycle even when earlier zone misalignment
    /// prevented the player lane from proving a clean blank.
    private var imageRelayLastConfirmedPenaltyVisibilityKeys: Set<OCRRegionKey> = []
    // Build 658: individual physical slots clear on the same five-frame
    // sustained absence contract used by the paired timer lane. Fourteen frames
    // retained expired penalties long after the scoreboard had cleared them.
    private let imageRelayPenaltyBlankRemovalFrames = 5
    /// Two agreeing observations are required before a large score intervention
    /// reaches the operator. A rejected candidate stays suppressed until a normal
    /// score transition or a different candidate proves the physical board changed.
    private var imageRelayLargeScoreCandidateEvidence: [Team: (previous: Int, proposed: Int, count: Int, lastObservedAt: CFAbsoluteTime)] = [:]
    private var imageRelayRejectedLargeScoreCandidate: [Team: (previous: Int, proposed: Int)] = [:]
    /// Equivalent strength outcomes are deduplicated even if a noisy player crop
    /// briefly disappears and returns.
    private var imageRelayLastStrengthPopupSignature: String?
    private var imageRelayLastStrengthPopupObservedAt: CFAbsoluteTime = 0
    // v0.8.8m14: accepted public broadcast display state lives in a small
    // dedicated object so Broadcast can avoid observing OCR/camera/debug churn.
    let broadcastOverlayState = BroadcastOverlayState()
    var broadcastOverlayQueueState: BroadcastOverlayQueueState { overlayEventStateMachine.state }

    // v0.8.8m15a1: BannerQueue is a value type and its setter is private to this file.
    // Extension files cannot call mutating methods on it directly because Swift needs
    // writeback access to the property setter. Keep the mutation in this source file
    // and expose a narrow helper for extracted action methods.
    func clearBroadcastBannerQueue() {
        overlayEventStateMachine.clear(source: "HockeyScoreboardViewModel", reason: "clear broadcast overlay queue")
        publishUnifiedOverlayQueueState(reason: "clear broadcast overlay queue")
    }

    // v0.8.8m15b1: stopped-clock broadcast-event internals now live inside
    // GameEventDetector. Extension files must not reach back into the old
    // removed ViewModel properties, so expose one narrow reset helper for
    // timeline clearing.
    func clearStoppedClockBroadcastEventState() {
        gameEventDetector.clearPendingStoppedClockBroadcastEvents()
    }

    /// Camera used for the public live/broadcast output. This must not drive OCR.
    /// It is preview-only: no sample-buffer output is attached, so fast iPad motion
    /// cannot feed OCR, hash, motion-protection or frame-processing callbacks.
    let liveCameraService = HockeyCameraService(
        defaultCameraPreference: .builtInBackFirst,
        sampleBufferOutputEnabled: false,
        queueQoS: .userInteractive
    )
    /// Camera used for OCR, calibration and the overlay PIP preview. Prefer an external camera when one is available.
    let ocrCameraService = HockeyCameraService(
        defaultCameraPreference: .externalFirst,
        sampleBufferOutputEnabled: true,
        queueQoS: .utility
    )
    /// UX16c23: one process-wide owner for simultaneous built-in Broadcast and
    /// external USB OCR capture. It is lazy so both camera-setting facades are
    /// fully initialised before the coordinator receives them.
    lazy var externalOCRMultiCamCoordinator = ExternalOCRMultiCamCoordinator(
        liveService: liveCameraService,
        ocrService: ocrCameraService
    )
    /// UX16c31 Stage 3: the ViewModel expresses desired capture mode but never
    /// starts, stops or releases an AVCaptureSession directly.
    lazy var captureLifecycleController = RinkLensCaptureLifecycleController(
        liveService: liveCameraService,
        ocrService: ocrCameraService,
        multiCamEngine: externalOCRMultiCamCoordinator,
        broadcastImageQualityPolicyProvider: { [unowned self] in
            self.cameraControlStore.snapshot.broadcastImageQualityPolicy
        }
    )
    /// Compatibility alias for older OCR/calibration code paths. New public views should use liveCameraService.
    var cameraService: HockeyCameraService { ocrCameraService }
    let templateStore = RinkTemplateStore()

    /// UX16c33 Stage 5: queue/processor ownership moved out of the ViewModel.
    /// Existing recognisers remain unchanged inside ScoreboardOCRProcessor.
    private let ocrOrchestrationEngine: RinkLensOCREngine
    private let scoreboardFramePipeline: ScoreboardFramePipeline
    /// Recovery AJ immutable read projection for the camera callback. Authoritative
    /// state remains in the existing stores; this store contains no writable app
    /// policy and is replaced only when those owners change.
    private let scoreboardFrameExecutionPlanStore = ScoreboardFrameExecutionPlanStore()
    let imageRelayEngine = ScoreboardImageRelayEngine()
    /// Queue-only worker reset lane. It owns no user-visible state; the
    /// RinkLensScoreboardInputLifecycleStore remains the sole run-state authority.
    private let imageRelayLifecycleWorkQueue = DispatchQueue(
        label: "rinklens.image-relay.lifecycle-work",
        qos: RinkLensExecutionQoSHierarchy.semantic
    )
    private let selectedZoneSevenSegmentRecognizer = SevenSegmentTimerRecognizer()
    let ocrSmoothingEngine = OCRSmoothingEngine()
    // v0.8.8m7: Centralised OCR cadence/scheduling policy.
    // This object decides WHEN regions may run. OCR parsing, validation, smoothing,
    // camera ownership and recording remain unchanged.
    private let ocrScheduler = OCRScheduler()
    // Build 547: the sole production Broadcast field-selection authority.
    // Legacy OCRScheduler is Calibration compatibility only and cannot select,
    // reorder or complete production work.
    private let ocrControlPlane = OCRWorkScheduler()
    private var activeProductionOCRPlan: OCRWorkScheduler.Plan?
    private var lastOCRSchedulerMode: OCRSchedulerMode = .idle
    // v0.8.8m13: Game event detection is isolated from OCR parsing, camera,
    // recording and Broadcast rendering. It reports transition candidates only;
    // existing smoothing/manual protection still controls accepted values.
    private let gameEventDetector = RinkLensGameEventCoordinator()
    private var lastGameEventMode: GameEventMode = .unknown
    private var selectedRegionPreviewContext: CIContext { ScoreboardImageProcessingResources.shared.ciContext }
    /// UX16d2g2 uses the processor's authoritative board/field geometry for the
    /// Calibration Raw/Proc/Thresh evidence. Continuous recognition remains
    /// owned by the orchestration engine.
    private let selectedRegionCropProcessor = ScoreboardOCRProcessor()
    /// Compatibility UI flag. The orchestration engine is the authoritative
    /// capacity-one processing gate; this value remains for existing diagnostics.
    var isProcessing = false
    private var droppedOCRFrameCount = 0
    private var previousMotionHashes: [OCRRegionKey: UInt64] = [:]
    private var ocrMotionProtectionUntil: CFAbsoluteTime = 0
    private var ignoreOCRMotionProtectionUntil: CFAbsoluteTime = 0
    private var isLoadingCameraRotationSettings = false
    private var isLoadingCalibrationCameraProfile = false
    private var isLoadingOCRSmoothingSettings = false
    private var lastOCRMotionProtectionPublishAt: CFAbsoluteTime = 0
    var ocrProcessingGeneration = 0
    private var lastAppliedCaptureGeneration = 0
    let scoreboardInputLifecycleStore = RinkLensScoreboardInputLifecycleStore()

    var isOCRPaused: Bool {
        get { scoreboardInputLifecycleStore.snapshot.processingPaused }
        set {
            scoreboardInputLifecycleStore.setProcessingPaused(
                newValue,
                source: "HockeyScoreboardViewModel.isOCRPaused",
                reason: "Processing-pause command projected through scoreboard-input owner"
            )
        }
    }
    var isScreenTransitioning: Bool {
        get { operationalStateStore.snapshot.isScreenTransitioning }
        set { operationalStateStore.update(source: "HockeyScoreboardViewModel", reason: "Screen transition projection changed") { $0.isScreenTransitioning = newValue } }
    }
    /// UX16c41c coalesces repeated Recover Preview taps so one operator action
    /// cannot launch overlapping stop/start transactions or duplicate share-like
    /// system activities while the first recovery is still completing.
    @Published private(set) var cameraRecoveryInProgress = false
    var userWantsOCRRunning: Bool {
        get { scoreboardInputLifecycleStore.snapshot.operatorRequestedRunning }
        set {
            scoreboardInputLifecycleStore.setOperatorRequestedRunning(
                newValue,
                source: "HockeyScoreboardViewModel.userWantsOCRRunning",
                reason: "Run-intent command projected through scoreboard-input owner"
            )
        }
    }
    var currentScreen: AppScreen {
        get { operationalStateStore.snapshot.currentScreen }
        set { operationalStateStore.update(source: "HockeyScoreboardViewModel", reason: "Legacy screen projection changed") { $0.currentScreen = newValue } }
    }
    private var ocrStartupClockBootstrapActive = false
    private var hasStartedAppServices = false
    private var startupRinkConfigurationHydrated = false
    /// Camera discovery is configuration data, not capture-session ownership.
    /// Preload it once from the initial Command Centre lifetime so Camera Setup
    /// never has to manufacture an "unavailable" answer before discovery has
    /// produced its first physical topology snapshot.
    private var hasRequestedConfigurationCameraDiscovery = false
    private var appSuspendedWithOCRWanted = false
    private var appSuspendedScreen: AppScreen?
    /// Build 677 blocks every capture-start reconciliation between the real
    /// background boundary and the subsequent active recovery. Recording lease
    /// release used to restart dual-camera while iOS still reported the camera as
    /// unavailable in background, permanently latching a false capture failure.
    private var appBackgroundCaptureSuspended = false
    private var appTemporarilyInactive = false
    private var deferredCameraStartupTask: Task<Void, Never>?
    private var deferredOCRPromotionTask: Task<Void, Never>?
    private var deferredBroadcastPreviewRecoveryTask: Task<Void, Never>?
    private var deferredOCRPromotionGeneration = 0
    // v0.8.4x: Broadcast OCR promotion is a separate lifecycle state.
    // Until this flips true, Broadcast must remain preview-only and frame delivery
    // must stay disabled. This prevents OCR/session activation from happening in
    // the same transaction as the screen switch or Operator Controls sheets.
    private var broadcastOCRPromotionActive = false
    private var broadcastOCRPromotionBlockedUntil: CFAbsoluteTime = 0
    private var lastOCRAt = CFAbsoluteTimeGetCurrent()
    private var lastSelectedRegionPreviewAt = CFAbsoluteTimeGetCurrent()
    private var calibrationCropPreviewArmedUntil: CFAbsoluteTime = 0
    // UX16d16: selected-zone Test OCR is owned only by the explicit one-shot
    // request state below. Continuous Calibration and Broadcast scheduling cannot
    // derive priority from the currently selected editor zone.
    // UX15j: direct selected-zone Test OCR has its own one-shot sequence so
    // asynchronous results/failures can be published even if the operator leaves
    // OCR Setup for Diagnostics immediately after pressing Test OCR.
    private var selectedZoneOneShotSequence = 0
    private var selectedZoneLastOneShotAt: CFAbsoluteTime = 0
    private var selectedZoneLastOneShotKey: OCRRegionKey?
    // UX16c5: Test OCR is a strict one-shot. Zone selection can refresh preview
    // images, but only a button press may start OCR parsing. Results are owned by
    // the selected key/generation so stale zone-change completions cannot publish.
    private var selectedZoneTestOCRInFlight = false
    private var selectedZoneTestOCRRequestPending = false
    private var selectedZoneTestOCRRequestSequence = 0
    private var selectedZoneTestOCRTask: Task<Void, Never>?
    private var selectedZoneTestOCRGeneration = 0
    private var selectedZoneActiveOneShotID = 0
    private var selectedZoneActiveOneShotKey: OCRRegionKey?
    // UX16d2g1 rotates baseline and live-event fields through a bounded pass.
    // Clock remains first when scheduled; other fields cannot create an unbounded
    // seven-field pass or monopolise the single Test OCR executor.
    private var ocrBoundedFieldCursor = 0
    // UX16d16: sequence is diagnostics-only. Field choice, fairness and deadlines
    // are owned exclusively by OCRWorkScheduler.
    private var liveOCRPassSequence: UInt64 = 0
    // UX16d15e Build 520: once the publication policy has one credible score,
    // period or paired-penalty observation, verify those exact fields on the
    // next admitted pass instead of waiting for the normal Clock/static cycle.
    private var liveOCRPriorityVerificationUntil: [OCRRegionKey: CFAbsoluteTime] = [:]
    private let liveOCRPriorityVerificationWindow: CFTimeInterval = 8.0
    // UX16d15g Build 522: a complete provisional Clock result must receive the
    // next admitted OCR pass. Build 521 unconditionally switched from
    // clockConfirmation to staticVerification before the result was known,
    // allowing a valid 17:57 observation to expire without a sequential read.
    private var liveOCRClockConfirmationUntil: CFAbsoluteTime = 0
    private var liveOCRClockConfirmationPassesRemaining = 0
    private var liveOCRClockConfirmationCandidateSeconds: Int?
    private let liveOCRClockConfirmationWindow: CFTimeInterval = 3.0
    private let liveOCRClockConfirmationMaximumPasses = 2
    private var trustedClockLiveContinuationCount = 0
    private var ux16d14LivePassEvidenceRing: [String] = []
    private let ux16d14LivePassEvidenceLimit = 12

    var ux16d14PersistentLivePassDiagnosticText: String {
        ux16d14LivePassEvidenceRing.isEmpty
            ? "No Build 514 live-pass evidence recorded"
            : ux16d14LivePassEvidenceRing.joined(separator: " || ")
    }
    // Bounded cross-path evidence lets an All Logs export prove whether Test OCR
    // and continuous OCR saw the same accepted value from the same saved zone.
    private var lastTestOCRAcceptedValue: [OCRRegionKey: String] = [:]
    private var lastTestOCRFrameSequence: [OCRRegionKey: Int] = [:]
    // UX16d15: retain only operator-confirmed static-field baselines. These are
    // restored after a capture-generation change when the visible value still
    // matches, mirroring Build 514's retained operator-confirmed Clock authority.
    private var operatorConfirmedTestOCRBaselines: [OCRRegionKey: String] = [:]

    var ux16d15OperatorConfirmedBaselineDiagnosticText: String {
        let entries = operatorConfirmedTestOCRBaselines
            .map { "\($0.key.rawValue)=\($0.value)" }
            .sorted()
        return entries.isEmpty ? "none" : entries.joined(separator: ",")
    }
    // UX16c: selected Test OCR now uses active-colour OCR as the primary reader.
    // Keep a tiny per-field candidate buffer so a single bad frame cannot publish
    // a confident but implausible value during Calibration.
    private var selectedZoneStableCandidates: [OCRRegionKey: SelectedZoneStableCandidate] = [:]
    private var activeOCRInterval: CFTimeInterval {
        // v0.8.8m7: frame-attempt cadence is now delegated to OCRScheduler.
        // Keep the existing tuning snapshot as the base cadence and keep the
        // calibration crop-preview boost because that is editor-only UI support,
        // not OCR recognition behaviour.
        let now = CFAbsoluteTimeGetCurrent()
        let baseInterval = CFTimeInterval(ocrTuningSnapshot.clock.cadenceSeconds)

        if currentScreen == .calibration && calibrationCropPreviewArmedUntil > now {
            return max(baseInterval, 0.25)
        }

        return ocrScheduler.frameAttemptInterval(
            now: now,
            state: schedulerGameState(now: now),
            baseClockCadence: baseInterval
        )
    }

    // v0.9.1w2: Broadcast OCR can run as a background scheduler even when the
    // broadcast overlay is in Manual Override mode. Manual Override protects the
    // public scoreboard values, but it must not shut down OCR frame delivery or
    // the OCR camera path while Broadcast is on air.
    var isBroadcastOCRKeepaliveExpected: Bool {
        currentScreen == .broadcast && userWantsOCRRunning
    }

    var isBroadcastOCRSchedulerRunning: Bool {
        isBroadcastOCRKeepaliveExpected && isOCRSchedulerActive
    }

    enum OCROperationalStatus: String, Equatable {
        case off = "OCR Off"
        case starting = "OCR Starting"
        case deferredByRecording = "OCR Deferred by Recording"
        case running = "OCR Running"
        case waitingForFrame = "OCR Waiting for Frame"
        case stalled = "OCR Stalled"
        case interrupted = "OCR Interrupted"
        case failed = "OCR Failed"
    }

    var usesScoreboardCameraInput: Bool {
        operatingMode == .imageRelay
    }

    /// OCR is no longer a live operating mode. Internal recognition is limited to
    /// the Image Relay period lane and frozen Home penalty-player popup crops.
    var usesOCRRecognition: Bool { false }

    var isOCRRequested: Bool {
        userWantsOCRRunning && (usesScoreboardCameraInput || isBroadcastOCRKeepaliveExpected)
    }

    var isOCRSchedulerActive: Bool {
        guard isOCRRequested,
              !isOCRPaused,
              !isScreenTransitioning,
              !externalOCRMultiCamCoordinator.snapshot.ocrPressureSuspended else { return false }
        switch currentScreen {
        case .broadcast, .live, .calibration:
            return true
        case .overlay:
            return false
        }
    }

    private var hasFreshOCRFrameForEffectiveCapture: Bool {
        let capture = externalOCRMultiCamCoordinator.snapshot
        guard capture.isActive,
              capture.sessionRunning,
              RinkLensCaptureLifecycleMode(rawValue: capture.captureModeText)?.requiresOCR == true,
              let deviceID = capture.ocrDeviceID else { return false }
        let frame = RinkLensFrameHub.shared.diagnosticSnapshot().ocr
        return frame.sequence > 0
            && (frame.ageSeconds ?? .greatestFiniteMagnitude) <= 1.5
            && frame.captureGeneration == capture.transitionGeneration
            && frame.physicalDeviceID == deviceID
    }

    var ocrOperationalStatus: OCROperationalStatus {
        guard isOCRRequested else { return .off }
        let capture = externalOCRMultiCamCoordinator.snapshot
        if capture.failureLatched || capture.phase == .failed { return .failed }
        if RinkLensRecordingCaptureLease.shared.snapshot().isActive,
           captureLifecycleController.hasDeferredRecordingOCRRequest,
           !capture.activeMode.requiresOCR {
            return .deferredByRecording
        }
        if ocrOrchestrationEngine.snapshot().isStalled { return .stalled }
        if isOCRPaused { return .interrupted }
        if isScreenTransitioning || capture.isTransitioning || capture.phase.isTransitioning {
            return .starting
        }
        if capture.phase == .interrupted || capture.phase == .degraded {
            return .interrupted
        }
        guard capture.isActive, capture.sessionRunning else {
            return capture.phase == .stopped ? .interrupted : .starting
        }
        guard RinkLensCaptureLifecycleMode(rawValue: capture.captureModeText)?.requiresOCR == true else {
            // OCR was requested but the authoritative graph is Broadcast-only,
            // usually because both roles resolve to the same physical camera.
            // This is an interruption/fallback, not an endless startup state.
            return .interrupted
        }
        guard isOCRSchedulerActive else { return .interrupted }
        guard hasFreshOCRFrameForEffectiveCapture else { return .waitingForFrame }
        return .running
    }

    var broadcastOCRPausedReason: String {
        guard currentScreen == .broadcast else { return "not on Broadcast" }
        guard userWantsOCRRunning else { return "OCR not requested" }
        if isScreenTransitioning { return "screen transition" }
        if isOCRPaused { return "paused flag still set" }
        let orchestration = ocrOrchestrationEngine.snapshot()
        if orchestration.isStalled {
            return "processor stalled at \(orchestration.stalledProcessorStage ?? orchestration.activeProcessorStage)"
        }
        let capture = externalOCRMultiCamCoordinator.snapshot
        if RinkLensCaptureLifecycleMode(rawValue: capture.captureModeText)?.requiresOCR != true {
            return "Broadcast-only fallback: OCR camera is not distinct or unavailable"
        }
        return "not paused"
    }

    var isOCREffectiveRunning: Bool {
        ocrOperationalStatus == .running
    }

    var ocrOperationalStatusText: String {
        if operatingMode == .imageRelay {
            return imageRelayStatusText
        }
        let status = ocrOperationalStatus
        if status == .running {
            let unresolvedStaticBaseline = ocrPublicationSafetyState.pendingBaselineKeys
                .intersection([.homeScore, .awayScore, .period])
            if !unresolvedStaticBaseline.isEmpty {
                return "OCR Acquiring Scoreboard"
            }
            if !ocrPublicationSafetyState.isPenaltyBaselineEstablished {
                return "OCR Arming Penalties"
            }
            return status.rawValue
        }
        guard status == .stalled else { return status.rawValue }
        let snapshot = ocrOrchestrationEngine.snapshot()
        return RinkLensOCRRuntimeTruthPolicy.stalledStatusText(
            passAgeSeconds: snapshot.activePassAgeSeconds,
            stage: snapshot.stalledProcessorStage ?? snapshot.activeProcessorStage,
            stageAgeSeconds: snapshot.activeProcessorStageAgeSeconds
        )
    }

    var ocrRuntimeState: OCRRuntimeState {
        guard operatingMode == .ocr || isBroadcastOCRKeepaliveExpected else { return .disabled }
        guard isOCREffectiveRunning else { return .paused }
        if currentScreen == .calibration { return .calibration }
        guard currentScreen == .live || currentScreen == .broadcast else { return .paused }
        if localClockIsRunning {
            return hasActivePenaltyOCRWork ? .runningClockPenaltyWatch : .runningClockOnly
        }
        return .stoppedClockHashing
    }

    var ocrRuntimeStateText: String {
        switch ocrRuntimeState {
        case .disabled:
            return "Manual Mode: OCR, hashing and OCR camera processing are disabled."
        case .paused:
            return "OCR is paused during screen changes, camera settings or explicit freeze."
        case .calibration:
            return "Calibration: full OCR diagnostics are available for setup and testing."
        case .runningClockOnly:
            return "Running clock: lightweight mode checks the clock only."
        case .runningClockPenaltyWatch:
            return "Running clock: clock OCR continues, and locked penalties continue with penalty-time OCR plus removal checks."
        case .stoppedClockHashing:
            return "Stopped clock: pixel hashing watches changed regions before OCR runs."
        case .safetyResync:
            return "Safety resync: periodic OCR verifies the current values."
        }
    }
    private var canProcessOCRFrame: Bool {
        isOCREffectiveRunning
    }
    private var shouldGenerateSelectedRegionPreview: Bool {
        // Crop preview generation is expensive. From v0.5.3 it is disabled by
        // default and only runs briefly after Calibration > Test OCR is pressed.
        // v0.8.4j phase 2: also wait until Calibration's heavy layers are mounted
        // so crop image publishing cannot compete with the initial camera preview.
        currentScreen == .calibration && isOCRDiagnosticsVisible && CFAbsoluteTimeGetCurrent() < calibrationCropPreviewArmedUntil && !performanceSafeModeEnabled
    }
    private var shouldPublishOCRDiagnostics: Bool {
        // Keep OCR diagnostics Calibration-only. Publishing candidate values,
        // OCR live/stable text, confidence summaries or crop/debug state while
        // the Live screen is open causes the full Live view model to emit
        // frequent SwiftUI updates. That can make the live camera preview lag,
        // jump or briefly go black even though the camera session is healthy.
        // v0.8.4j phase 2: CalibrationScreen explicitly enables this after its
        // deferred overlay/gesture/crop layers have mounted.
        currentScreen == .calibration && isOCRDiagnosticsVisible
    }

    var ocrOrchestrationDiagnosticText: String {
        ocrOrchestrationEngine.snapshot().diagnosticText
    }

    var ocrOrchestrationSnapshot: RinkLensOCROrchestrationSnapshot {
        ocrOrchestrationEngine.snapshot()
    }

    func resetOCROrchestration(reason: String) {
        ocrOrchestrationEngine.reset(reason: reason)
        ocrPublicationSafetyState.reset()
        operatorConfirmedTestOCRBaselines.removeAll()
        recentClearedStrengthState = nil
        recentClearedPenaltyClocks.removeAll()
        recentPenaltyClearObservedAt = 0
        resetOCRBaselineReservationSchedule()
    }

    // UX15f: this drives the bottom Calibration diagnostics values. It must be
    // Published because selected-zone/Test OCR may accept a value without changing
    // the public scoreboard state or other visible diagnostics. Without a publish,
    // the logs can show accepted Clock/Penalty values while the UI still displays
    // stale -- values until another unrelated published property changes.
    let acceptedOCREvidenceStore = RinkLensAcceptedOCREvidenceStore()
    var acceptedFieldState: [OCRRegionKey: AcceptedOCRValueState] { acceptedOCREvidenceStore.values }
    private var mutableAcceptedFieldState: [OCRRegionKey: AcceptedOCRValueState] {
        get { acceptedOCREvidenceStore.values }
        _modify {
            var draft = acceptedOCREvidenceStore.values
            defer {
                acceptedOCREvidenceStore.replace(
                    draft,
                    source: "HockeyScoreboardViewModel",
                    reason: "Accepted OCR evidence transaction"
                )
            }
            yield &draft
        }
    }
    func setAcceptedOCREvidence(_ value: AcceptedOCRValueState, for key: OCRRegionKey, source: String, reason: String) {
        var draft = acceptedOCREvidenceStore.values
        draft[key] = value
        acceptedOCREvidenceStore.replace(draft, source: source, reason: reason)
    }
    var bannerDismissTask: Task<Void, Never>?
    private var lastPenaltySignature = ""
    private var homeLogoFileName: String? {
        get { teamIdentityStore.homeLogoFileName }
        set { teamIdentityStore.setHomeLogoFileName(newValue, source: "HockeyScoreboardViewModel", reason: "Home logo file reference changed") }
    }
    private var awayLogoFileName: String? {
        get { teamIdentityStore.awayLogoFileName }
        set { teamIdentityStore.setAwayLogoFileName(newValue, source: "HockeyScoreboardViewModel", reason: "Away logo file reference changed") }
    }
    private var isLoadingDefaultValues = false
    private var pausedOCRForCameraSettings = false
    private var isOCRDiagnosticsVisible = false
    private var calibrationPhaseOverrideActive = false

    // Performance throttles. These stop inexpensive-but-frequent OCR/hash status
    // changes from publishing to SwiftUI every OCR pass. SwiftUI redraws are kept
    // to human-visible rates while the OCR queue continues doing the background work.
    private let detectionStatePublishInterval: CFTimeInterval = 0.35
    private let pixelHashStatusPublishInterval: CFTimeInterval = 0.75
    private let selectedRegionPreviewInterval: CFTimeInterval = 1.25
    private let selectedRegionSelectionDebounceNanoseconds: UInt64 = 300_000_000
    private let selectedRegionImagePublishInterval: CFTimeInterval = 0.90
    private var selectedRegionPreviewRequestGeneration = 0
    private var deferredSelectedRegionPreviewTask: Task<Void, Never>?
    private var lastSelectedRegionImagePublishAt: CFAbsoluteTime = 0
    private var lastSelectedRegionSegmentImagePublishAt: CFAbsoluteTime = 0
    private var lastDetectionStatePublishAt: CFAbsoluteTime = 0
    private var lastPixelHashStatusPublishAt: CFAbsoluteTime = 0
    private var lastSchedulerMetricsDiagnosticAt: CFAbsoluteTime = 0
    private var lastRawDebugPublishAt: CFAbsoluteTime = 0
    private let rawDebugPublishInterval: CFTimeInterval = 1.0
    private var lastPublishedRegionDetectionStates: [OCRRegionKey: OCRRegionDetectionState] = [:]

    // Field-specific OCR scheduling keeps Live/Broadcast lightweight.
    // Calibration still runs the full diagnostic OCR set, but production screens
    // read only the fields that are due.
    var lastOCRFieldCheckAt: [OCRRegionKey: CFAbsoluteTime] = [:]
    var scoreFastCheckUntil: CFAbsoluteTime = 0
    private var liveScoreEventWatchUntil: CFAbsoluteTime = 0
    // UX16d8: keep a confirmation window per score field. A home-score change
    // must not spend half of its bounded OCR budget repeatedly checking an
    // unchanged away score, and vice versa.
    private var liveScoreFieldFastCheckUntil: [OCRRegionKey: CFAbsoluteTime] = [:]
    private var livePeriodEventWatchUntil: CFAbsoluteTime = 0
    private var livePenaltyPairFastCheckUntil: [OCRRegionKey: CFAbsoluteTime] = [:]
    // Build 531: malformed empty penalty zones receive a short cooldown after
    // their bounded verification window expires, preventing permanent urgent
    // work while still allowing a later real hash change to reopen the pair.
    private var livePenaltyPairRetryCooldownUntil: [OCRRegionKey: CFAbsoluteTime] = [:]
    // UX16d19 Build 541: count unusable passes only while a penalty pair is
    // promoted by a pending visual hash. Two failed full-pair attempts consume
    // that hash and cool the noisy pair, allowing the other unresolved slots to
    // receive their guaranteed baseline audits.
    private var livePenaltyVisualUnusableAttempts: [OCRRegionKey: Int] = [:]
    private let livePenaltyMalformedCooldownSeconds: CFTimeInterval = 4.0
    // Build 532: OCR may observe the board clearing a power-play penalty before
    // the slower score field confirms the corresponding goal. Retain the last
    // verified pre-clear strength snapshot briefly so the delayed goal is still
    // classified from the physical state that existed when it was scored.
    private var recentClearedStrengthState: StrengthState?
    private var recentClearedPenaltyClocks: [PenaltyClock] = []
    private var recentPenaltyClearObservedAt: CFAbsoluteTime = 0
    private let recentPenaltyClearGoalCorrelationWindow: CFTimeInterval = 45.0
    private let liveScoreFollowUpSeconds: CFTimeInterval = 10.0
    private let livePenaltyFollowUpSeconds: CFTimeInterval = 8.0
    private let livePeriodFollowUpSeconds: CFTimeInterval = 6.0
    var periodFastCheckUntil: CFAbsoluteTime = 0
    var lastObservedClockOCRSeconds: Int?
    var repeatedClockOCRReadCount = 0
    private var lastClockOCRConfirmationAt: CFAbsoluteTime = 0
    // v0.8.1.7e: a visually running clock can produce the same OCR value twice
    // when OCR samples within the same scoreboard second. Do not treat that as a
    // stoppage. A stopped-clock event window only opens after the same clock value
    // has been observed for a minimum duration and no recent movement was seen.
    var clockStopCandidateStartedAt: CFAbsoluteTime?
    var lastClockMovementObservedAt: CFAbsoluteTime = 0
    private let stoppedClockMinimumRepeatCount = 3
    private let stoppedClockMinimumConfirmationDuration: CFTimeInterval = 2.25
    private let stoppedClockMovementCooldown: CFTimeInterval = 3.0
    // UX16d9: the physical scoreboard remains the clock authority. RinkLens may
    // infer running/stopped state for event handling, but it never free-runs the
    // public game clock after OCR stops producing trusted values.
    var localClockIsRunning = false
    var localClockDirection: GameClockDirection = .countDown
    // Build 524: non-authoritative Clock text shared with the Broadcast renderer
    // and PixelBuffer overlay only. It is never read by MatchState, OCR validation,
    // event detection or penalty timing.
    private(set) var broadcastPresentationClockText: String? {
        get { gameClockAuthority.presentationClockText }
        set { gameClockAuthority.setPresentationClockText(newValue, source: "HockeyScoreboardViewModel", reason: "Broadcast presentation clock changed") }
    }

    func setBroadcastPresentationClockText(_ text: String?) {
        gameClockAuthority.setPresentationClockText(text, source: "HockeyScoreboardViewModel", reason: "Broadcast renderer presentation projection")
    }

    // Auto direction is diagnostic/event evidence only. It must not manufacture
    // or reverse the public clock. Two trusted OCR values are sufficient to infer
    // the initial direction; a later reversal requires two consistent observations.
    private var autoClockDirectionIsLocked = false

    // UX16d9: one physical-board-first clock authority owns every public OCR clock
    // transition. The public value changes only when a complete, high-trust OCR
    // reading is accepted. A short monotonic estimate is retained only for drift
    // validation and penalty timing; it is never published as the game clock.
    private var trustedClockAnchorSeconds: Int? {
        get { gameClockAuthority.trustedAnchorSeconds }
        set { gameClockAuthority.setTrustedAnchorSeconds(newValue, source: "HockeyScoreboardViewModel", reason: "Trusted clock anchor changed") }
    }
    private var trustedClockLastObservationSeconds: Int?
    private var trustedClockLastObservationAt: CFAbsoluteTime = 0
    private var trustedClockLastAcceptedAt: CFAbsoluteTime = 0
    private var trustedClockSameValueStartedAt: CFAbsoluteTime?
    private var trustedClockObservedPeriod: Int?
    private var trustedClockDirectionCandidate: GameClockDirection?
    private var trustedClockDirectionEvidenceCount = 0
    private var trustedClockDirectionCandidateStartedAt: CFAbsoluteTime = 0
    private var trustedClockDirectionCandidateLastSeconds: Int?
    private var trustedClockDirectionCandidateLastAt: CFAbsoluteTime = 0
    private var trustedClockEvidenceState = RinkLensBoundedClockEvidenceState()
    private var trustedClockEvidenceProcessingGeneration: Int?
    private var trustedClockConfirmedStopped: Bool {
        get { gameClockAuthority.confirmedStopped }
        set { gameClockAuthority.setConfirmedStopped(newValue, source: "HockeyScoreboardViewModel", reason: "Trusted clock stopped state changed") }
    }
    // Build 523: repaired/inferred values can move the public Clock when continuity
    // uniquely resolves one unknown token, but they are never evidence that the
    // physical board has stopped. Stop confirmation requires consecutive direct,
    // stop-eligible complete observations of the same value.
    private var trustedClockLastAcceptedWasDirect = false
    private var trustedClockLastAcceptedWasStopEligible = false
    private var trustedClockDirectSameValueCount = 0
    private var trustedClockLastDecision = "Clock authority not initialised"
    private let trustedClockEvidenceMaximumAge: CFTimeInterval = 3.5
    private let trustedClockEvidenceMaximumCycles = 4
    private let trustedClockInitialDirectionConfirmationCount = 3
    private let trustedClockDirectionChangeConfirmationCount = 3
    private let trustedClockDirectionChangeMinimumDuration: CFTimeInterval = 2.0
    private let localClockFreshOCRWindow: CFTimeInterval = 4.5
    private var fullBoardResetRecovery = RinkLensFullBoardResetRecoveryState()
    private let fullBoardResetRecoveryWindow: CFTimeInterval = 18.0
    private let fullBoardResetNearPeriodStartTolerance = 45
    private let fullBoardResetMinimumUpwardJump = 30

    private var trustedClockEvidenceIsStale: Bool {
        guard trustedClockAnchorSeconds != nil, trustedClockLastAcceptedAt > 0 else { return false }
        return CFAbsoluteTimeGetCurrent() - trustedClockLastAcceptedAt > localClockFreshOCRWindow
    }

    private var fullBoardResetRecoveryDiagnosticText: String {
        guard fullBoardResetRecovery.isActive else { return "inactive" }
        let clock = fullBoardResetRecovery.clockCandidateSeconds.map(formatClock) ?? "--"
        return "clock=\(clock)/\(fullBoardResetRecovery.clockEvidenceCount) home=\(fullBoardResetRecovery.homeCandidate.map { String($0) } ?? "--")/\(fullBoardResetRecovery.homeEvidenceCount) away=\(fullBoardResetRecovery.awayCandidate.map { String($0) } ?? "--")/\(fullBoardResetRecovery.awayEvidenceCount)"
    }

    private var clockTickTask: Task<Void, Never>?
    private var ocrPublicationSafetyState = OCREvidenceStore()
    var penaltyPlayerVisualHash: [OCRRegionKey: UInt64] = [:]
    private var penaltyPlayerPendingVisualHash: [OCRRegionKey: UInt64] = [:]
    var penaltyPlayerLastSafetyOCRAt: [OCRRegionKey: CFAbsoluteTime] = [:]
    private let penaltyPlayerHashChangeThreshold = 4
    private let stoppedClockSafetyOCRInterval: CFTimeInterval = 1.5
    private let stoppedScoreSafetyOCRInterval: CFTimeInterval = 2.0
    var scoreVisualHash: [OCRRegionKey: UInt64] = [:]
    private var scorePendingVisualHash: [OCRRegionKey: UInt64] = [:]
    private var scoreLastSafetyOCRAt: [OCRRegionKey: CFAbsoluteTime] = [:]
    // Build 550: a bounded stopped-window safety transaction may wake a score or
    // player zone when the active-foreground hash misses a material board change.
    // It remains subject to repeated high-trust OCR evidence and confirmed stopped
    // Clock authority before any public goal or penalty commit.
    private var stoppedWindowSafetyTransactionUntil: [OCRRegionKey: CFAbsoluteTime] = [:]
    private var stoppedHashWatchWasActive = false
    private var stoppedScoreSafetyCursor = 0
    private var stoppedPenaltySafetyCursor = 0
    private let stoppedSafetyTransactionLifetime: CFTimeInterval = 10.0
    private let stoppedPenaltyPlayerSafetySweepInterval: CFTimeInterval = 4.0
    private var visualHashDiagnosticLastAt: [OCRRegionKey: CFAbsoluteTime] = [:]
    var periodVisualHash: UInt64?
    private var periodPendingVisualHash: UInt64?
    var periodLastSafetyOCRAt: CFAbsoluteTime = 0
    private let stoppedPeriodSafetyOCRInterval: CFTimeInterval = 0.7
    var smartChangeSkippedOCRFrames: Int {
        get { ocrDiagnostics.smartChangeSkippedOCRFrames }
        set { ocrDiagnostics.smartChangeSkippedOCRFrames = newValue }
    }
    var smartChangeLastDecisionText: String {
        get { ocrDiagnostics.smartChangeLastDecisionText }
        set { ocrDiagnostics.smartChangeLastDecisionText = newValue }
    }
    var clockVisualHash: UInt64?
    private var clockLastSafetyOCRAt: CFAbsoluteTime = 0
    var penaltyTimeVisualHash: [OCRRegionKey: UInt64] = [:]
    private var penaltyTimePendingVisualHash: [OCRRegionKey: UInt64] = [:]
    private var penaltyTimeLastSafetyOCRAt: [OCRRegionKey: CFAbsoluteTime] = [:]
    private let penaltyTimeHashChangeThreshold = 3
    private let stoppedPenaltyTimeSafetyOCRInterval: CFTimeInterval = 0.7
    private let runningPenaltyTimeSafetyOCRInterval: CFTimeInterval = 2.0
    private let runningPenaltyPlayerSafetyOCRInterval: CFTimeInterval = 15.0

    private var hasActivePenaltyOCRWork: Bool {
        !activeConfirmedPenaltyTimeRegionKeys.isEmpty || !activePenaltyPlayerRegionKeys.isEmpty
    }

    var isUsingPixelHashing: Bool {
        isOCREffectiveRunning &&
        smartChangeDetectionEnabled &&
        (currentScreen == .live || currentScreen == .broadcast || currentScreen == .calibration) &&
        hasConfirmedStoppedClock(now: CFAbsoluteTimeGetCurrent())
    }

    var pixelHashingStatusText: String {
        guard isOCREffectiveRunning else {
            return "Pixel hashing inactive because OCR is paused or Manual Mode is active."
        }

        guard smartChangeDetectionEnabled else {
            return "Pixel hashing inactive because Smart Change Detection is disabled."
        }

        guard currentScreen == .live || currentScreen == .broadcast else {
            return "Pixel hashing is only used in lightweight Live/Broadcast OCR. Calibration uses full OCR diagnostics."
        }

        if !hasConfirmedStoppedClock(now: CFAbsoluteTimeGetCurrent()) {
            if hasActivePenaltyOCRWork {
                return "Smart Change Detection active. Clock OCR continues while perspective-corrected active-foreground hashes watch score and penalty changes; only changed event zones enter bounded OCR."
            }
            return "Smart Change Detection active. Clock OCR continues while perspective-corrected active-foreground hashes watch score, period and penalty changes."
        }

        return "Smart Change Detection active. Clock is confirmed stopped, so perspective-corrected active-foreground hashes gate score, period and penalty OCR."
    }


    init(ocrEngine: RinkLensOCREngine, scoreboardFramePipeline: ScoreboardFramePipeline) {
        self.ocrOrchestrationEngine = ocrEngine
        self.scoreboardFramePipeline = scoreboardFramePipeline
        isLoadingDefaultValues = true
        activeTemplateID = templateStore.activeTemplateID
        regionLikelyLabels = Dictionary(uniqueKeysWithValues: OCRRegionKey.allCases.map { ($0, "Likely \($0.likelyTitle)") })
        regionOCRPreview = Dictionary(uniqueKeysWithValues: OCRRegionKey.allCases.map { ($0, "--") })
        regionOCRRecognizer = Dictionary(uniqueKeysWithValues: OCRRegionKey.allCases.map { ($0, .vision) })
        loadDefaultScoreboardValues()
        loadCameraRotationSettings()
        // Recovery AA / RL-059: the saved rink profile is the startup camera
        // authority when one is explicitly active/default/calibrated. Do not
        // publish the generic calibration-camera UserDefaults first and then
        // overwrite it a few hundred milliseconds later from the rink profile.
        // If there is no authoritative startup rink, retain the legacy generic
        // calibration-camera profile as the fallback source.
        if let startupRink = preferredStartupRinkTemplate() {
            isLoadingCalibrationCameraProfile = true
            cameraControlStore.setCalibrationProfile(
                startupRink.calibrationCameraProfile,
                source: "HockeyScoreboardViewModel.init",
                reason: "Recovery AA startup rink camera authority seeded before generic camera profile"
            )
            calibrationCameraProfileStatusText = "Saved rink camera profile loaded."
            isLoadingCalibrationCameraProfile = false
        } else {
            loadCalibrationCameraProfileSettings()
        }
        externalOCRMultiCamCoordinator.setBroadcastVideoStabilisation(
            enabled: cameraControlStore.snapshot.broadcastVideoStabilisationEnabled,
            reason: "Camera-control owner startup sync"
        )
        loadOCRSmoothingSettings()

        // Recovery AV: hydrate persistent team/profile/logo authority before the
        // first MatchState/overlay publication. Startup no longer emits an
        // intermediate HOME/GUEST viewer snapshot which can flash on Broadcast.
        loadLastWorkingTeamNames()
        loadTeamIdentityTemplates()
        loadSelectedTeamIdentityTemplateID()
        loadDefaultTeamIdentityTemplateID()
        restoreTeamIdentityAtOwnerStartup(projectToMatchState: false)
        hydrateStartupRinkConfigurationIfNeeded()

        reduceMatchState(
            .replace(
                scoreStateFromDefaults(),
                context: RinkLensMatchStateContext(
                    origin: .bootstrap,
                    reason: "Recovery AV atomic hydrated scoreboard bootstrap"
                )
            )
        )
        bindArchitectureOwners()
        // Build 766 / RL-011: CaptureEngine publishes OCR frames into FrameHub,
        // and FrameHub now delivers that exact installed frame to the one
        // continuous-processing endpoint. Do not depend on HockeyCameraService's
        // retired compatibility callback; its facade correctly reported zero
        // delivered frames while the authoritative FrameHub was fresh.
        // Build 785 R16a: resolve the coordinator while already on MainActor.
        // The coordinator itself is a nonisolated @unchecked Sendable capture
        // owner, so the FrameHub's @Sendable closure never reaches back through
        // the MainActor-isolated ViewModel property.
        let continuousOCRCaptureCoordinator = externalOCRMultiCamCoordinator
        let scoreboardExecutionPlanStore = scoreboardFrameExecutionPlanStore
        RinkLensFrameHub.shared.setLatestFrameConsumer(
            for: .ocr,
            minimumInterval: 0.30
        ) { [weak self, continuousOCRCaptureCoordinator, scoreboardFramePipeline, scoreboardExecutionPlanStore] frame in
            // Recovery AI / RL-073: generation/device truth is validated before
            // ingress, then the full FrameHub lease enters the capacity-one lane
            // before any MainActor hop. The MainActor receives only immutable
            // frame identity and returns a worker closure containing configuration.
            let capture = continuousOCRCaptureCoordinator.snapshot
            guard let deviceID = capture.ocrDeviceID,
                  frame.captureGeneration == capture.transitionGeneration,
                  frame.physicalDeviceID == deviceID else { return }
            let executionPlan = scoreboardExecutionPlanStore.snapshot()
            switch executionPlan.mode {
            case .imageRelayDirect:
                guard let directWorker = executionPlan.worker else { return }
                scoreboardFramePipeline.submitFrame(frame, preparedWork: directWorker)
            case .ocrCompatibility:
                // OCR compatibility remains bounded and asynchronous, but only an
                // explicit OCR execution state may enter it. Suspension/transition
                // is terminal and can no longer fall through to MainActor work.
                scoreboardFramePipeline.submitFrameViaMainActorPreparation(frame) { @MainActor [weak self] identity in
                    self?.prepareScoreboardFrameWork(identity: identity)
                }
            case .inactive:
                return
            }
        }
        RinkLensStructuredEventLogger.shared.record(
            domain: .ocr,
            event: "ocr_frame_consumer_bound",
            entityID: "ocr",
            previous: ["deliverySource": "HockeyCameraService.onFrame compatibility callback"],
            next: [
                "deliverySource": "RinkLensFrameHub OCR latest-frame consumer",
                "minimumDeliveryInterval": "0.30"
            ],
            source: "HockeyScoreboardViewModel.init",
            reason: "RL-011: authoritative FrameHub contained fresh OCR frames while the compatibility callback delivered zero"
        )
        // Broadcast recording and continuous OCR/Image Relay now consume the
        // authoritative FrameHub paths directly.
        updateFrameDeliveryPolicy()
        applyOperatorOCRSettings(reason: "Initial OCR profile")
        refreshScoreboardFrameExecutionPlan(reason: "view model initialisation completed")
        isLoadingDefaultValues = false
        persistDefaultScoreboardValues()
        startLocalClockTicker()
        RinkLensRecordingLeaseReplayHub.shared.install { [weak self] reason in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.reconcileCaptureAfterRecordingLeaseRelease(reason: reason)
            }
        }
        imageRelayEngine.setMetadataObserver { [weak self] observation in
            DispatchQueue.main.async { [weak self] in
                self?.handleImageRelayMetadataObservation(observation)
            }
        }
        cameraForensicBreadcrumb(.lifecycle, phase: "view model init completed", extra: diagnosticIdentityText)
    }

    private func forwardArchitectureInvalidation(_ domain: ArchitecturePresentationDomain) {
        // AppCoordinator is the visible-route authority. The old `currentScreen`
        // projection defaults to Calibration before the NextGen route is mounted,
        // which previously caused startup profile/camera mutations to invalidate a
        // Calibration tree that was not even visible. No visible route means no
        // compatibility invalidation is required.
        let shouldForward: Bool
        if let route = activeNextGenLifecycleRoute {
            switch route {
            case .broadcast:
                shouldForward = domain == .match || domain == .camera || domain == .operational
            case .ocrSetup:
                shouldForward = domain == .camera || domain == .calibration || domain == .ocr || domain == .operational
            case .recording, .cameraSetup:
                shouldForward = domain == .camera || domain == .operational
            case .settings:
                // Settings already observes its authoritative stores directly.
                shouldForward = domain == .operational
            case .commandCentre, .diagnostics, .sponsors, .media, .streamSetup:
                shouldForward = domain == .operational
            }
        } else {
            shouldForward = false
        }

        if shouldForward {
            architectureInvalidationForwardedCount &+= 1
            objectWillChange.send()
        } else {
            architectureInvalidationSuppressedCount &+= 1
        }
    }

    /// Recovery AK / RL-078: derive a typed frame execution state only when
    /// authoritative state changes. Inactive presentation/capture states are a
    /// terminal drop boundary and can never fall through to legacy MainActor OCR.
    /// Value-only projection of the authoritative Home roster. It is captured
    /// when the execution plan changes and carried with bounded frame work; the
    /// background Image Relay service never reaches back into MainActor state.
    private var homeRosterNumberProjection: Set<Int> {
        Set(SponsorCatalogueStore.shared.configuration.homeRoster.compactMap { player in
            let trimmed = player.number.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let number = Int(trimmed), (1...99).contains(number) else { return nil }
            return number
        })
    }

    private func refreshScoreboardFrameExecutionPlan(
        reason: String,
        homeRosterNumbersOverride: Set<Int>? = nil
    ) {
        let executionAvailable = usesScoreboardCameraInput
            && !isScreenTransitioning
        guard operatingMode == .imageRelay, executionAvailable else {
            let mode: ScoreboardFrameExecutionPlanStore.Mode =
                (operatingMode == .ocr && executionAvailable) ? .ocrCompatibility : .inactive
            scoreboardFrameExecutionPlanStore.update(mode: mode, worker: nil)
            return
        }

        var acceptedPenaltyPlayers: Set<OCRRegionKey> = []
        if (state.homePenalty1Player ?? 0) > 0 || Self.isActivePenaltyClock(state.homePenalty1Clock) {
            acceptedPenaltyPlayers.insert(.homePenalty1Player)
        }
        if (state.homePenalty2Player ?? 0) > 0 || Self.isActivePenaltyClock(state.homePenalty2Clock) {
            acceptedPenaltyPlayers.insert(.homePenalty2Player)
        }
        if (state.awayPenalty1Player ?? 0) > 0 || Self.isActivePenaltyClock(state.awayPenalty1Clock) {
            acceptedPenaltyPlayers.insert(.awayPenalty1Player)
        }
        if (state.awayPenalty2Player ?? 0) > 0 || Self.isActivePenaltyClock(state.awayPenalty2Clock) {
            acceptedPenaltyPlayers.insert(.awayPenalty2Player)
        }

        let rosterProjection = homeRosterNumbersOverride ?? homeRosterNumberProjection
        let configuration = ScoreboardFrameRelayConfiguration(
            layout: ocrLayout,
            colourProfiles: ocrColourProfiles,
            boardCalibration: boardCalibration,
            previewSize: authoritativeOCRGeometryViewportSize,
            previewRotationDegrees: ocrPreviewRotationOffsetDegrees,
            viewerAcceptedPenaltyPlayers: acceptedPenaltyPlayers,
            homeRosterNumbers: rosterProjection,
            sourceObservedAt: .distantPast,
            sourceMonotonicTime: 0
        )
        let relayEngine = imageRelayEngine
        let worker: ScoreboardFramePipeline.PreparedFrameWork = { frame in
            let currentSourceAge = max(0, Date().timeIntervalSince(frame.identity.capturedAt))
            let sourceMonotonicTime = CFAbsoluteTimeGetCurrent() - currentSourceAge
            relayEngine.submitOwnedFromPipeline(
                pixelBuffer: frame.pixelBuffer,
                sourceSequence: frame.sequence,
                captureGeneration: frame.captureGeneration,
                layout: configuration.layout,
                colourProfiles: configuration.colourProfiles,
                boardCalibration: configuration.boardCalibration,
                previewSize: configuration.previewSize,
                previewRotationDegrees: configuration.previewRotationDegrees,
                viewerAcceptedPenaltyPlayers: configuration.viewerAcceptedPenaltyPlayers,
                homeRosterNumbers: configuration.homeRosterNumbers,
                sourceObservedAt: frame.identity.capturedAt,
                sourceMonotonicTime: sourceMonotonicTime
            )
        }
        scoreboardFrameExecutionPlanStore.update(mode: .imageRelayDirect, worker: worker)

        if scoreboardFrameExecutionPlanStore.snapshot().revision <= 2 {
            RinkLensStructuredEventLogger.shared.record(
                domain: .scoreboardPresentation,
                event: "scoreboard_frame_execution_projection_updated",
                entityID: "image-relay",
                previous: ["execution": "per-frame MainActor preparation"],
                next: ["execution": "immutable non-main worker projection"],
                source: "HockeyScoreboardViewModel",
                reason: "Recovery AJ RL-078: \(reason)",
                authoritativeOwner: "existing calibration/match/input stores; projection is read-only"
            )
        }
    }

    private func bindArchitectureOwners() {
        // Recovery AJ / RL-077: preserve compatibility only for the currently
        // visible legacy presentation domain. Do not turn every independent
        // authoritative owner mutation into one application-wide SwiftUI pulse.
        manualScoreController.objectWillChange
            .sink { [weak self] _ in self?.forwardArchitectureInvalidation(.match) }
            .store(in: &architectureCancellables)
        penaltyLifecycleStore.objectWillChange
            .sink { [weak self] _ in self?.forwardArchitectureInvalidation(.match) }
            .store(in: &architectureCancellables)
        overlayEventStateMachine.objectWillChange
            .sink { [weak self] _ in self?.forwardArchitectureInvalidation(.match) }
            .store(in: &architectureCancellables)
        cameraZoomStore.objectWillChange
            .sink { [weak self] _ in self?.forwardArchitectureInvalidation(.camera) }
            .store(in: &architectureCancellables)
        teamIdentityStore.objectWillChange
            .sink { [weak self] _ in self?.forwardArchitectureInvalidation(.match) }
            .store(in: &architectureCancellables)
        gameClockAuthority.objectWillChange
            .sink { [weak self] _ in self?.forwardArchitectureInvalidation(.match) }
            .store(in: &architectureCancellables)
        calibrationStore.objectWillChange
            .sink { [weak self] _ in self?.forwardArchitectureInvalidation(.calibration) }
            .store(in: &architectureCancellables)
        ocrConfigurationStore.objectWillChange
            .sink { [weak self] _ in self?.forwardArchitectureInvalidation(.ocr) }
            .store(in: &architectureCancellables)
        acceptedOCREvidenceStore.objectWillChange
            .sink { [weak self] _ in self?.forwardArchitectureInvalidation(.ocr) }
            .store(in: &architectureCancellables)
        cameraControlStore.objectWillChange
            .sink { [weak self] _ in self?.forwardArchitectureInvalidation(.camera) }
            .store(in: &architectureCancellables)
        scoreboardDefaultsStore.objectWillChange
            .sink { [weak self] _ in self?.forwardArchitectureInvalidation(.match) }
            .store(in: &architectureCancellables)
        operationalStateStore.objectWillChange
            .sink { [weak self] _ in self?.forwardArchitectureInvalidation(.operational) }
            .store(in: &architectureCancellables)
        gameEventLifecycleStore.objectWillChange
            .sink { [weak self] _ in self?.forwardArchitectureInvalidation(.match) }
            .store(in: &architectureCancellables)
        matchEventJournal.objectWillChange
            .sink { [weak self] _ in self?.forwardArchitectureInvalidation(.match) }
            .store(in: &architectureCancellables)
        scoreboardInputLifecycleStore.objectWillChange
            .sink { [weak self] _ in self?.forwardArchitectureInvalidation(.ocr) }
            .store(in: &architectureCancellables)

        // Build the non-main production processing projection from post-change
        // values. `$snapshot`/`$state` publish the new value, unlike
        // `objectWillChange`, which is intentionally pre-change.
        calibrationStore.$snapshot
            .dropFirst()
            .sink { [weak self] _ in self?.refreshScoreboardFrameExecutionPlan(reason: "calibration owner changed") }
            .store(in: &architectureCancellables)
        cameraControlStore.$snapshot
            .dropFirst()
            .sink { [weak self] _ in self?.refreshScoreboardFrameExecutionPlan(reason: "camera-control owner changed") }
            .store(in: &architectureCancellables)
        scoreboardInputLifecycleStore.$snapshot
            .dropFirst()
            .sink { [weak self] _ in self?.refreshScoreboardFrameExecutionPlan(reason: "scoreboard-input owner changed") }
            .store(in: &architectureCancellables)
        operationalStateStore.$snapshot
            .dropFirst()
            .sink { [weak self] _ in self?.refreshScoreboardFrameExecutionPlan(reason: "operational owner changed") }
            .store(in: &architectureCancellables)
        SponsorCatalogueStore.shared.$configuration
            .map { configuration in
                Set(configuration.homeRoster.compactMap { player -> Int? in
                    let trimmed = player.number.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let number = Int(trimmed), (1...99).contains(number) else { return nil }
                    return number
                })
            }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] rosterNumbers in
                self?.refreshScoreboardFrameExecutionPlan(
                    reason: "authoritative Home roster changed",
                    homeRosterNumbersOverride: rosterNumbers
                )
            }
            .store(in: &architectureCancellables)
        $state
            .dropFirst()
            .sink { [weak self] _ in self?.refreshScoreboardFrameExecutionPlan(reason: "accepted match state changed") }
            .store(in: &architectureCancellables)
        $previewViewportSize
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.refreshScoreboardFrameExecutionPlan(reason: "calibration viewport changed") }
            .store(in: &architectureCancellables)

        // Build 784: capture-generation zoom reconciliation is submitted to
        // CaptureLifecycleController. The ViewModel observes generation changes
        // but cannot inspect or mutate the physical Broadcast camera directly.
        externalOCRMultiCamCoordinator.uiState.$snapshot
            .map(\.transitionGeneration)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] generation in
                guard let self else { return }
                self.captureLifecycleController.reapplyBroadcastZoomAfterCaptureGeneration(
                    reason: "capture-generation-\(generation)",
                    zoomStore: self.cameraZoomStore
                )
            }
            .store(in: &architectureCancellables)

        RinkLensStructuredEventLogger.shared.record(
            domain: .match,
            event: "state_owners_bound",
            next: ["ownership": RinkLensStateOwnershipRegistry.diagnosticSummary],
            source: "HockeyScoreboardViewModel",
            reason: "Build 706 single-owner domains initialised"
        )
    }

    @discardableResult
    func reduceMatchState(_ action: RinkLensMatchStateAction) -> RinkLensMatchStateReduction {
        let revisionBefore = matchStateRevision
        let reduction = RinkLensMatchStateReducer.reduce(current: state, action: action)
        lastMatchStateActionText = reduction.diagnosticSummary
        RinkLensOCRReplayGateController.shared.recordReduction(
            reduction,
            revision: revisionBefore + (reduction.changed ? 1 : 0)
        )

        if reduction.changed, RinkLensRiskFeaturePolicy.isEnabled(.gameClockAuthorityV2) {
            gameClockAuthority.recordAcceptedTransition(
                previous: reduction.previous.clock,
                next: reduction.next.clock,
                source: reduction.context.origin.rawValue,
                reason: reduction.context.reason
            )
        }

        if reduction.changed {
            RinkLensStructuredEventLogger.shared.record(
                domain: .match,
                event: "match_state_transition",
                entityID: String(revisionBefore + 1),
                previous: RinkLensStructuredStateSummary.scoreboard(reduction.previous),
                next: RinkLensStructuredStateSummary.scoreboard(reduction.next),
                source: reduction.context.origin.rawValue,
                reason: reduction.context.reason
            )
        }

        if action.isScoreRelevant {
            RinkLensOCREvidenceJournal.shared.recordScoreTransition(
                actionName: reduction.actionName,
                origin: reduction.context.origin.rawValue,
                diagnosticsOnly: reduction.context.diagnosticsOnly,
                reason: reduction.context.reason,
                previousHome: reduction.previous.homeScore,
                previousAway: reduction.previous.awayScore,
                nextHome: reduction.next.homeScore,
                nextAway: reduction.next.awayScore,
                changedFields: reduction.changedFields.map(\.rawValue).sorted(),
                reductionChanged: reduction.changed,
                committed: reduction.changed,
                revisionBefore: revisionBefore,
                revisionAfter: revisionBefore + (reduction.changed ? 1 : 0)
            )
        }

        guard reduction.changed else { return reduction }

        state = reduction.next
        matchStateRevision &+= 1

        if reduction.changedFields.contains(.homeScore)
            || reduction.changedFields.contains(.awayScore)
            || reduction.changedFields.contains(where: \.isPenaltyField) {
            reconcilePendingBroadcastEventsWithAcceptedState(
                reduction.next,
                reason: reduction.context.reason
            )
        }

        if reduction.changedFields.contains(where: \.isPenaltyField) {
            rememberRecentPenaltyClear(
                previousClocks: StrengthStateCalculator.activePenaltyClocks(from: reduction.previous),
                nextClocks: StrengthStateCalculator.activePenaltyClocks(from: reduction.next)
            )
        }

        if let source = reduction.context.origin.broadcastEventSource {
            if reduction.shouldEvaluateScoreEvents {
                handleAcceptedScoreChange(
                    from: reduction.previous,
                    to: reduction.next,
                    source: source,
                    operatorConfirmed: reduction.context.origin.operatorConfirmed
                )
            }

            if reduction.shouldEvaluatePenaltyEvents {
                handleAcceptedPenaltyChange(
                    from: reduction.previous,
                    to: reduction.next,
                    source: source,
                    operatorConfirmed: reduction.context.origin.operatorConfirmed
                )
            } else if reduction.changedFields.contains(where: \.isPenaltyField) {
                updatePenaltyState(from: reduction.next)
            }

            if reduction.shouldEvaluatePeriodEvents {
                handleAcceptedPeriodTransition(
                    from: reduction.previous,
                    to: reduction.next,
                    source: source,
                    operatorConfirmed: reduction.context.origin.operatorConfirmed
                )
            }
        } else if reduction.changedFields.contains(where: \.isPenaltyField) {
            updatePenaltyState(from: reduction.next)
        }

        refreshBroadcastOverlayState()
        MainThreadStallMonitor.shared.traceOCRPhase("UX16c34 match reducer \(reduction.diagnosticSummary)")
        return reduction
    }

    func applyCaptureLifecycleOutcome(_ outcome: RinkLensCaptureLifecycleOutcome) {
        cameraZoomStore.commitLifecycleOutcome(
            outcome,
            liveDeviceID: liveCameraService.selectedCameraID,
            ocrDeviceID: ocrCameraService.selectedCameraID
        )

        if outcome.wasSuperseded {
            // Latest-intent-wins requests are control-plane cancellations, not
            // operator-visible camera failures. The winning request will publish
            // the final status when its contract settles.
        } else if outcome.succeeded {
            if outcome.usedFallback {
                statusMessage = outcome.statusText
            } else if statusMessage?.hasPrefix("Live camera failed") == true
                        || statusMessage?.hasPrefix("OCR camera failed") == true
                        || statusMessage?.hasPrefix("Camera lifecycle") == true {
                statusMessage = nil
            }
        } else {
            statusMessage = outcome.statusText
        }

        let captureSnapshot = externalOCRMultiCamCoordinator.snapshot
        if outcome.changedOwnership || captureSnapshot.transitionGeneration != lastAppliedCaptureGeneration {
            lastAppliedCaptureGeneration = captureSnapshot.transitionGeneration
            invalidateOCRCaptureGeneration(
                reason: "capture lifecycle \(outcome.resolvedMode.rawValue) generation=\(captureSnapshot.transitionGeneration)"
            )
        }

        cameraForensicBreadcrumb(
            .lifecycle,
            phase: "capture lifecycle outcome",
            extra: "requested=\(outcome.requestedMode.rawValue) resolved=\(outcome.resolvedMode.rawValue) success=\(outcome.succeeded) superseded=\(outcome.wasSuperseded) fallback=\(outcome.usedFallback) rollback=\(outcome.selectionRolledBack) status=\(outcome.statusText) generation=\(captureSnapshot.transitionGeneration)"
        )
        updateFrameDeliveryPolicy(force: true)
    }

    private func invalidateOCRCaptureGeneration(reason: String) {
        ocrProcessingGeneration &+= 1
        selectedZoneTestOCRGeneration &+= 1
        selectedRegionPreviewRequestGeneration &+= 1
        deferredSelectedRegionPreviewTask?.cancel()
        deferredSelectedRegionPreviewTask = nil
        selectedZoneTestOCRInFlight = false
        pendingTestOCRResult = nil
        pendingTestOCRApplyDescription = nil
        testOCROutcome = .idle
        testOCROutcomeText = "Test OCR reset after camera graph change."
        selectedZoneActiveOneShotID = 0
        selectedZoneActiveOneShotKey = nil
        selectedZoneStableCandidates.removeAll()
        isProcessing = false
        ocrPublicationSafetyState.reset()
        restoreOperatorConfirmedTestOCRBaselines(reason: reason)
        resetOCRBaselineReservationSchedule()
        ocrOrchestrationEngine.cancelAll(reason: reason)
        calibrationCropPreviewArmedUntil = 0
        mutableAcceptedFieldState.removeAll()
        ocrDiagnostics.resetLiveDiagnostics(
            reason: "Waiting for a fresh OCR frame after camera graph change."
        )
        MainThreadStallMonitor.shared.traceOCRPhase("UX16c36 OCR generation invalidated: \(reason)")
    }


    func requestCameraPreviewRecovery(
        for service: HockeyCameraService,
        reason: String
    ) {
        guard !cameraRecoveryInProgress else {
            cameraForensicBreadcrumb(.recovery, phase: "camera recovery coalesced", extra: "reason=\(reason)")
            statusMessage = "Camera recovery is already running."
            return
        }

        cameraRecoveryInProgress = true
        let role: CameraRole = service === liveCameraService ? .live : .ocr
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.cameraRecoveryInProgress = false }
            let previewRole: RinkLensCapturePreviewRole = role == .live ? .broadcast : .ocr

            // Recovery AO / RL-076: OCR preview no longer has an independent
            // AVCaptureVideoPreviewLayer health domain. The visible Calibration
            // surface consumes the same FrameHub OCR pixels as processing. A
            // fresh current-generation frame is therefore the physical preview
            // source acknowledgement; no preview-layer reconnect is permitted.
            if role == .ocr {
                let capture = self.externalOCRMultiCamCoordinator.snapshot
                if let evidence = RinkLensFrameHub.shared.latestEvidence(
                    for: .ocr,
                    maxAge: 0.75,
                    requiredCaptureGeneration: capture.transitionGeneration,
                    requiredPhysicalDeviceID: capture.ocrDeviceID
                ) {
                    self.statusMessage = "OCR FrameHub preview source is healthy."
                    self.cameraForensicBreadcrumb(
                        .recovery,
                        phase: "Recovery AO OCR preview source acknowledged",
                        extra: "sequence=\(evidence.sequence) ageMs=\(String(format: "%.1f", evidence.ageSeconds * 1000)) reason=\(reason)"
                    )
                    return
                }
            } else if await self.captureLifecycleController.recoverPreviewEndpointIfPhysicalBranchHealthy(
                role: previewRole,
                reason: reason
            ) {
                self.statusMessage = "Broadcast preview endpoint reattached; live capture graph preserved."
                self.cameraForensicBreadcrumb(
                    .recovery,
                    phase: "Recovery AI preview-only repair completed",
                    extra: "role=\(previewRole.displayName) reason=\(reason)"
                )
                return
            }

            let mode = self.desiredCaptureMode(for: role)
            let outcome = await self.captureLifecycleController.recover(
                mode: mode,
                liveDeviceID: self.liveCameraService.resolvedCameraDeviceID,
                ocrDeviceID: self.ocrCameraService.resolvedCameraDeviceID,
                reason: "preview-only repair unavailable; \(reason)"
            )
            self.applyCaptureLifecycleOutcome(outcome)
        }
    }

    func start(priorityScreen: AppScreen? = nil) async {
        guard !hasStartedAppServices else {
            cameraForensicBreadcrumb(.lifecycle, phase: "app services start ignored", extra: "already started")
            return
        }
        let startupScreen = priorityScreen ?? currentScreen
        cameraForensicBreadcrumb(.lifecycle, phase: "app services start requested", extra: "authorization=\(String(describing: AVCaptureDevice.authorizationStatus(for: .video))) priorityScreen=\(startupScreen.rawValue) \(diagnosticIdentityText)")
        hasStartedAppServices = true

        // UX16c15: Restore the proven UX16c7a startup contract. Later camera
        // improvements remain in HockeyCameraService, but initial OCR ownership
        // again follows one deterministic path:
        // discover -> reconcile saved source -> request permission -> select/start.
        cameraForensicBreadcrumb(.discovery, phase: "startup discovery requested")
        preloadConfigurationCameraDiscoveryIfNeeded(reason: "UX16c15 operational startup")

        // Recovery BC: logical selections are already hydrated from their owners,
        // while CaptureEngine resolves the physical devices on its serial session
        // transaction. Do not impose a fixed MainActor delay waiting for a UI-facing
        // discovery projection; configuration routes preload it independently and
        // a late projection may not become a second capture-admission boundary.
        cameraForensicBreadcrumb(.discovery, phase: "startup discovery snapshot consumed without fixed settle delay", extra: "generation=\(liveCameraService.cameraDiscoveryGeneration)/\(ocrCameraService.cameraDiscoveryGeneration) liveOptions=\(liveCameraService.availableCameras.map { $0.id }.joined(separator: ",")) ocrOptions=\(ocrCameraService.availableCameras.map { $0.id }.joined(separator: ",")) profileSource=\(calibrationCameraProfile.selectedCameraSourceID ?? "none")")
        validateSavedCalibrationCameraSource()
        enforceCalibrationCameraDefaultAvoidingBroadcast(reason: "UX16c15 known-good startup")
        cameraForensicBreadcrumb(.selection, phase: "startup source reconciliation completed", extra: "profileSource=\(calibrationCameraProfile.selectedCameraSourceID ?? "none")")

        let startupAuthorization = AVCaptureDevice.authorizationStatus(for: .video)
        liveCameraService.publishCurrentCameraAuthorizationStatus(reason: "UX16c36 startup authorization check")
        ocrCameraService.publishCurrentCameraAuthorizationStatus(reason: "UX16c36 startup authorization check")
        cameraForensicBreadcrumb(.permission, phase: "startup authorization checked", extra: "status=\(String(describing: startupAuthorization))")
        switch startupAuthorization {
        case .authorized:
            MainThreadStallMonitor.shared.traceCameraStartupTimeline(
                RinkLensBuildInfo.traceContext("known-good startup entering startCameraSession screen=\(startupScreen.rawValue)")
            )
            await startCameraSession(priorityScreen: startupScreen)
            cameraForensicBreadcrumb(.lifecycle, phase: "authorized startup camera session returned")

        case .notDetermined:
            cameraForensicBreadcrumb(.permission, phase: "camera permission prompt requested")
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            liveCameraService.publishCurrentCameraAuthorizationStatus(reason: "UX16c36 permission prompt completed")
            ocrCameraService.publishCurrentCameraAuthorizationStatus(reason: "UX16c36 permission prompt completed")
            cameraForensicBreadcrumb(.permission, phase: "camera permission prompt completed", extra: "granted=\(granted)")
            if granted {
                MainThreadStallMonitor.shared.traceCameraStartupTimeline(
                    RinkLensBuildInfo.traceContext("camera permission granted; known-good startup entering startCameraSession screen=\(startupScreen.rawValue)")
                )
                await startCameraSession(priorityScreen: startupScreen)
            } else {
                statusMessage = "Camera access denied."
            }

        default:
            statusMessage = "Camera unavailable."
            cameraForensicBreadcrumb(.permission, phase: "startup blocked by authorization", extra: "status=\(String(describing: startupAuthorization))")
        }
        cameraForensicBreadcrumb(.lifecycle, phase: "app services start completed")
    }

    func stop() {
        deferredCameraStartupTask?.cancel()
        deferredCameraStartupTask = nil
        deferredBroadcastPreviewRecoveryTask?.cancel()
        deferredBroadcastPreviewRecoveryTask = nil
        clockTickTask?.cancel()
        clockTickTask = nil
        hasStartedAppServices = false
        Task { @MainActor in
            let outcome = await self.captureLifecycleController.ensure(
                .stopped(reason: "application services stopped")
            )
            self.applyCaptureLifecycleOutcome(outcome)
        }
    }

    private func blockCameraMutationDuringRecording(action: String, owner: String) -> Bool {
        guard RinkLensRecordingCaptureLease.shared.isRecordingActive() else { return false }
        _ = RinkLensRecordingCaptureLease.shared.allowMutation(
            action: action,
            requester: "HockeyScoreboardViewModel",
            owner: owner
        )
        statusMessage = "Camera changes are locked while recording. Stop recording before changing camera settings."
        MainThreadStallMonitor.shared.trace("camera mutation blocked during recording: \(action)")
        return true
    }

    @MainActor
    private func applyCameraSelectionAfterMultiCamRelease(role: CameraRole, id: String) async {
        let roleText = role == .live ? "Broadcast" : "OCR"
        let before = externalOCRMultiCamCoordinator.snapshot
        let previousLiveID = before.liveDeviceID ?? liveCameraService.resolvedCameraDeviceID
        let previousOCRID = before.ocrDeviceID ?? ocrCameraService.resolvedCameraDeviceID
        var selectionSucceeded = true
        invalidateOCRCaptureGeneration(reason: "\(roleText) camera selection transaction")
        statusMessage = "Changing \(roleText) camera…"

        let outcome = await captureLifecycleController.reconfigureActiveCapture(
            reason: "\(roleText) camera selection changed"
        ) { [self] in
            var liveID = previousLiveID
            var ocrID = previousOCRID

            switch role {
            case .live:
                if id == iceCastExplicitNoCameraSelectionID {
                    _ = liveCameraService.stageNoCamera(reason: "operator selected None")
                    liveID = nil
                } else if let stagedID = liveCameraService.stageLogicalCameraSource(
                    id,
                    reason: "atomic CaptureEngine Broadcast selection"
                ) {
                    liveID = stagedID
                } else {
                    selectionSucceeded = false
                }
            case .ocr:
                if id == iceCastExplicitNoCameraSelectionID {
                    _ = ocrCameraService.stageNoCamera(reason: "operator selected None")
                    ocrID = nil
                } else if let stagedID = ocrCameraService.stageLogicalCameraSource(
                    id,
                    reason: "atomic CaptureEngine OCR selection"
                ) {
                    ocrID = stagedID
                } else {
                    selectionSucceeded = false
                }
            }

            let mode = authoritativeDesiredCaptureMode(
                liveIdentity: liveCameraService.captureIdentitySnapshot(),
                ocrIdentity: ocrCameraService.captureIdentitySnapshot()
            )
            let request = captureRequest(
                for: mode,
                reason: selectionSucceeded
                    ? "atomic \(roleText) camera selection resume"
                    : "atomic \(roleText) selection failed",
                liveDeviceIDOverride: liveID,
                ocrDeviceIDOverride: ocrID
            )
            return selectionSucceeded
                ? .staged(request)
                : .failed(
                    resume: request,
                    status: "The selected \(roleText) camera could not be staged"
                )
        }
        applyCaptureLifecycleOutcome(outcome)

        if outcome.selectionRolledBack {
            statusMessage = outcome.statusText
        } else if !selectionSucceeded {
            statusMessage = "The selected \(roleText) camera is unavailable. The previous camera and format selection was restored."
        } else if outcome.succeeded {
            if role == .live, id == iceCastExplicitNoCameraSelectionID {
                liveCameraZoomFactor = 1.0
            } else if role == .ocr {
                if id == iceCastExplicitNoCameraSelectionID {
                    cameraZoomFactor = 1.0
                    calibrationCameraProfile.selectedCameraSourceID = nil
                } else {
                    calibrationCameraProfile.selectedCameraSourceID = id
                }
            }
            statusMessage = outcome.resolvedMode == RinkLensCaptureLifecycleMode.stopped
                ? "\(roleText) camera selection stored. Capture remains stopped."
                : "\(roleText) camera selected; CaptureEngine resumed in \(outcome.resolvedMode.rawValue) mode."
        }
    }

    @MainActor
    private func applyOCRCameraAndFormatSelection(
        sourceID: String,
        formatPreference: RinkLensCaptureFormatPreference?,
        reason: String
    ) async {
        let before = externalOCRMultiCamCoordinator.snapshot
        let previousLiveID = before.liveDeviceID ?? liveCameraService.resolvedCameraDeviceID
        let previousOCRID = before.ocrDeviceID ?? ocrCameraService.resolvedCameraDeviceID
        var stagedOCRID = previousOCRID
        var selectionSucceeded = true

        invalidateOCRCaptureGeneration(reason: "combined OCR camera/format transaction: \(reason)")
        statusMessage = "Applying OCR camera and exact size/frame rate…"

        let outcome = await captureLifecycleController.reconfigureActiveCapture(
            reason: "combined OCR camera/format selection: \(reason)"
        ) { [self] in
            if let resolved = ocrCameraService.stageLogicalCameraSource(
                sourceID,
                reason: "atomic combined OCR camera selection"
            ) {
                stagedOCRID = resolved
            } else {
                selectionSucceeded = false
            }

            if selectionSucceeded, let formatPreference {
                selectionSucceeded = ocrCameraService.stageCaptureFormatPreference(
                    formatPreference,
                    reason: "atomic combined OCR exact size/FPS"
                )
            }

            let mode = authoritativeDesiredCaptureMode(
                liveIdentity: liveCameraService.captureIdentitySnapshot(),
                ocrIdentity: ocrCameraService.captureIdentitySnapshot()
            )
            let request = captureRequest(
                for: mode,
                reason: selectionSucceeded
                    ? "combined OCR camera/format resume"
                    : "combined OCR camera/format staging failed",
                liveDeviceIDOverride: previousLiveID,
                ocrDeviceIDOverride: selectionSucceeded ? stagedOCRID : previousOCRID
            )
            return selectionSucceeded
                ? .staged(request)
                : .failed(
                    resume: request,
                    status: "OCR camera or exact format could not be staged"
                )
        }
        applyCaptureLifecycleOutcome(outcome)

        if outcome.selectionRolledBack {
            statusMessage = outcome.statusText
        } else if selectionSucceeded, outcome.succeeded {
            calibrationCameraProfile.selectedCameraSourceID = sourceID
            statusMessage = outcome.resolvedMode == RinkLensCaptureLifecycleMode.stopped
                ? "OCR camera and exact size/frame rate stored. Capture remains stopped."
                : "OCR camera and exact size/frame rate applied; CaptureEngine resumed in \(outcome.resolvedMode.rawValue) mode."
        } else {
            statusMessage = "OCR camera/format change failed. The previous camera, format and CaptureEngine graph were restored."
        }
    }

    @MainActor
    private func applyCaptureFormatSelection(role: CameraRole, id: String) async {
        let roleText = role == .live ? "Broadcast" : "OCR"
        let service = role == .live ? liveCameraService : ocrCameraService
        let before = externalOCRMultiCamCoordinator.snapshot
        let previousLiveID = before.liveDeviceID ?? liveCameraService.resolvedCameraDeviceID
        let previousOCRID = before.ocrDeviceID ?? ocrCameraService.resolvedCameraDeviceID
        var formatStaged = false
        invalidateOCRCaptureGeneration(reason: "\(roleText) exact format selection transaction")
        statusMessage = "Changing \(roleText) resolution/frame rate…"

        let outcome = await captureLifecycleController.reconfigureActiveCapture(
            reason: "\(roleText) exact format changed"
        ) { [self] in
            formatStaged = service.stageCapabilityProfile(
                id: id,
                reason: "atomic CaptureEngine \(roleText) format selection"
            )
            let mode = authoritativeDesiredCaptureMode(
                liveIdentity: liveCameraService.captureIdentitySnapshot(),
                ocrIdentity: ocrCameraService.captureIdentitySnapshot()
            )
            let request = captureRequest(
                for: mode,
                reason: formatStaged
                    ? "atomic \(roleText) exact format resume"
                    : "exact format staging failed",
                liveDeviceIDOverride: previousLiveID,
                ocrDeviceIDOverride: previousOCRID
            )
            return formatStaged
                ? .staged(request)
                : .failed(
                    resume: request,
                    status: "The selected \(roleText) resolution/frame-rate profile is unavailable"
                )
        }
        applyCaptureLifecycleOutcome(outcome)
        if outcome.selectionRolledBack {
            statusMessage = outcome.statusText
        } else if !formatStaged {
            statusMessage = "That \(roleText) resolution/frame-rate profile is no longer available. The previous selection was restored."
        } else {
            statusMessage = outcome.succeeded
                ? "\(roleText) resolution/frame rate applied to CaptureEngine."
                : outcome.statusText
        }
    }

    func selectLiveCapabilityProfile(id: String) {
        guard !blockCameraMutationDuringRecording(action: "select Broadcast resolution/FPS", owner: "Live Camera") else { return }
        Task { @MainActor in
            await self.applyCaptureFormatSelection(role: .live, id: id)
        }
    }

    func selectOCRCapabilityProfile(id: String) {
        guard !blockCameraMutationDuringRecording(action: "select OCR resolution/FPS", owner: "OCR Camera") else { return }
        Task { @MainActor in
            await self.applyCaptureFormatSelection(role: .ocr, id: id)
        }
    }

    func selectLiveCamera(id: String?) {
        cameraForensicBreadcrumb(.picker, phase: "Broadcast picker callback", extra: "incoming=\(id ?? "nil")")
        guard !blockCameraMutationDuringRecording(action: "select live camera", owner: "Live Camera") else { return }
        guard let id else {
            MainThreadStallMonitor.shared.trace("UX16c19 ignored transient nil Broadcast camera selection")
            return
        }
        if id == iceCastExplicitNoCameraSelectionID {
            cameraForensicBreadcrumb(.selection, phase: "Broadcast explicit None accepted")
            Task { @MainActor in
                await self.applyCameraSelectionAfterMultiCamRelease(role: .live, id: id)
            }
            return
        }
        if id == ocrCameraService.selectedCameraID,
           id == HockeyCameraService.externalCameraSourceID {
            statusMessage = "The same external camera cannot be assigned to both active roles. Choose a built-in Broadcast source or another OCR source."
            return
        }
        if id == ocrCameraService.selectedCameraID {
            MainThreadStallMonitor.shared.trace("UX16c13 same built-in source retained for Broadcast/OCR; visible route owns the single active session")
        }
        cameraForensicBreadcrumb(.selection, phase: "Broadcast selection forwarded", extra: "id=\(id)")
        Task { @MainActor in
            await self.applyCameraSelectionAfterMultiCamRelease(role: .live, id: id)
        }
    }

    func selectLiveCamera(id: String) {
        selectLiveCamera(id: Optional(id))
    }

    func selectOCRCamera(id: String?) {
        cameraForensicBreadcrumb(.picker, phase: "OCR picker callback", extra: "incoming=\(id ?? "nil") profile=\(calibrationCameraProfile.selectedCameraSourceID ?? "none")")
        guard !blockCameraMutationDuringRecording(action: "select OCR camera", owner: "OCR Camera") else { return }
        guard let id else {
            MainThreadStallMonitor.shared.trace("UX16c19 ignored transient nil OCR camera selection")
            return
        }
        if id == iceCastExplicitNoCameraSelectionID {
            cameraForensicBreadcrumb(.selection, phase: "OCR explicit None accepted")
            Task { @MainActor in
                await self.applyCameraSelectionAfterMultiCamRelease(role: .ocr, id: id)
            }
            return
        }
        if id == liveCameraService.selectedCameraID,
           id == HockeyCameraService.externalCameraSourceID {
            statusMessage = "The same external camera cannot be assigned to both active roles. Choose a built-in Broadcast source or another OCR source."
            return
        }
        if id == liveCameraService.selectedCameraID {
            MainThreadStallMonitor.shared.trace("UX16c19 same built-in source retained for Broadcast/OCR; route ownership stops only the competing running session and retains configured graphs")
        }
        cameraForensicBreadcrumb(.selection, phase: "OCR selection forwarded", extra: "id=\(id)")
        Task { @MainActor in
            await self.applyCameraSelectionAfterMultiCamRelease(role: .ocr, id: id)
        }
    }

    func selectOCRCamera(id: String) {
        selectOCRCamera(id: Optional(id))
    }

    var hasExternalOCRCameraForCalibration: Bool {
        ocrCameraService.availableCameras.contains { $0.isExternal && $0.isAvailable }
    }

    var calibrationExternalCameraStatusText: String {
        if let selected = ocrCameraService.availableCameras.first(where: { $0.id == ocrCameraService.selectedCameraID }), selected.isExternal {
            return selected.isAvailable
                ? "External calibration camera active: External Camera"
                : "External Camera selected — waiting for USB connection"
        }
        if ocrCameraService.availableCameras.contains(where: { $0.isExternal && $0.isAvailable }) {
            return "External camera detected. Select it in Camera > Source."
        }
        return "External Camera is available as a saved logical choice but is not currently connected."
    }

    func selectFirstExternalOCRCameraForCalibration() {
        guard !blockCameraMutationDuringRecording(action: "select external calibration camera", owner: "OCR Camera") else { return }
        if ocrCameraService.availableCameras.isEmpty {
            ocrCameraService.refreshAvailableCameras()
        }
        guard let externalID = ocrCameraService.availableCameras.first(where: { $0.isExternal && $0.isAvailable })?.id else {
            statusMessage = "External Camera is not connected. The existing logical selection has not been changed."
            return
        }
        selectOCRCamera(id: externalID)
    }

    func refreshCameraLists() {
        cameraForensicBreadcrumb(.discovery, phase: "operator refresh requested")
        liveCameraService.refreshAvailableCameras(reason: "operator refresh")
        ocrCameraService.refreshAvailableCameras(reason: "operator refresh")

        // UX16c8: discovery runs on each camera service queue. Reconcile only after
        // both published lists have had time to arrive; the previous immediate
        // checks read stale arrays and could clear or auto-change the Picker value.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self else { return }
            self.validateSavedCalibrationCameraSource()
            // UX16c13: discovery refresh must not silently clear a role merely
            // because both logical selections currently point at the same built-in
            // source. RinkLens activates only the visible built-in capture session.
            // A same-external conflict remains blocked by the explicit Picker setter.
            self.enforceCalibrationCameraDefaultAvoidingBroadcast(reason: "refresh camera lists completed")
            self.cameraForensicBreadcrumb(.discovery, phase: "operator refresh reconciliation completed", extra: "liveOptions=\(self.liveCameraService.availableCameras.map { $0.id }.joined(separator: ",")) ocrOptions=\(self.ocrCameraService.availableCameras.map { $0.id }.joined(separator: ","))")
        }
    }

    var calibrationCameraProfileMode: CalibrationCameraProfileMode {
        .manual
    }

    var isCalibrationManualCameraEditable: Bool {
        true
    }

    var calibrationBroadcastMatchStatusText: String {
        "Manual calibration profile. Broadcast settings can be copied once, but calibration no longer live-follows Broadcast."
    }

    var calibrationCameraLockSummaryText: String {
        calibrationCameraProfile.lockSummary
    }

    func calibrationSourceKind(for option: HockeyCameraService.CameraOption) -> CalibrationCameraSourceKind {
        if option.isExternal { return .external }
        switch option.position {
        case .back: return .builtInBack
        case .front: return .builtInFront
        default: return .unknown
        }
    }

    // Recovery Z1 compile correction: warning text remains owned by this
    // ViewModel. Cross-file calibration helpers request a projection update
    // through this API instead of widening the private(set) mutation boundary.
    func projectCalibrationCameraWarning(_ warning: String?, reason: String) {
        calibrationCameraWarningText = warning
        MainThreadStallMonitor.shared.trace(
            RinkLensBuildInfo.traceContext("calibration camera warning projected reason=\(reason) warning=\(warning ?? "none")")
        )
    }

    func setCalibrationCameraProfileMode(_ mode: CalibrationCameraProfileMode) {
        // v0.9.1p: Calibration now has one stable manual profile.
        // Keep this method only for backwards-compatible call sites and saved templates.
        calibrationCameraProfile.profileMode = .manual
        calibrationCameraProfile.manualCalibrationModeEnabled = true
        calibrationCameraProfileStatusText = "Manual calibration profile enabled. Profile switching has been removed to avoid live camera reconfiguration crashes."
        MainThreadStallMonitor.shared.markContext("calibration camera profile forced manual")
    }

    func selectCalibrationCameraSource(id: String?) {
        guard !blockCameraMutationDuringRecording(action: "select calibration camera source", owner: "OCR Camera") else { return }
        calibrationCameraProfile.profileMode = .manual
        calibrationCameraProfile.manualCalibrationModeEnabled = true
        let previousLayout = ocrLayout
        let requestedOption = id.flatMap { requestedID in
            ocrCameraService.availableCameras.first(where: { $0.id == requestedID })
        }
        selectOCRCamera(id: id)
        ocrLayout = previousLayout

        // HockeyCameraService applies the source asynchronously on its capture
        // queue. Persist the validated logical source request here instead of
        // immediately comparing against the old published selection.
        if let id, let option = requestedOption {
            calibrationCameraProfile.selectedCameraSourceID = id
            calibrationCameraProfile.selectedCameraSourceKind = calibrationSourceKind(for: option)
            calibrationCameraWarningText = nil
            calibrationCameraProfileStatusText = "Calibration source set to \(option.name)."
        } else if id == nil {
            calibrationCameraProfile.selectedCameraSourceID = nil
            calibrationCameraProfile.selectedCameraSourceKind = .unknown
            calibrationCameraProfileStatusText = "Calibration camera set to None."
        } else {
            calibrationCameraProfileStatusText = "Calibration source is no longer available. Refresh Cameras and select again."
            return
        }
        applyCalibrationManualLocks(reason: "calibration source changed")
        requestCameraPreviewRecovery(for: ocrCameraService, reason: "calibration source changed")
    }

    func setCalibrationZoomLock(_ locked: Bool) {
        calibrationCameraProfile.zoomLocked = locked
        if locked { calibrationCameraProfile.lockedZoomValue = Double(cameraZoomFactor) }
        calibrationCameraProfileStatusText = locked ? "Zoom locked for OCR stability." : "Zoom unlocked."
    }

    func setCalibrationFocusLock(_ locked: Bool) {
        calibrationCameraProfile.focusLocked = locked
        if locked { calibrationCameraProfile.focusValue = Double(ocrCameraService.focusPosition) }
        if locked { ocrCameraService.setManualFocus(position: Float(calibrationCameraProfile.focusValue)) } else { ocrCameraService.setContinuousAutoFocus() }
        calibrationCameraProfileStatusText = locked ? "Focus locked for OCR stability." : "Focus returned to auto."
    }

    func setCalibrationExposureAuto() {
        calibrationCameraProfile.exposureLocked = false
        calibrationCameraProfile.isoLocked = false
        calibrationCameraProfile.shutterSpeedLocked = false
        ocrCameraService.setAutoExposure()
        calibrationCameraProfileStatusText = "Auto exposure applied to the calibration camera."
    }

    func setCalibrationExposureLock(_ locked: Bool) {
        calibrationCameraProfile.exposureLocked = locked
        if locked {
            calibrationCameraProfile.exposureISOValue = Double(ocrCameraService.isoValue)
            calibrationCameraProfile.exposureDurationSeconds = ocrCameraService.exposureDurationSeconds
            calibrationCameraProfile.exposureBiasValue = Double(ocrCameraService.exposureTargetBiasValue)
            ocrCameraService.lockCurrentExposure()
        } else {
            calibrationCameraProfile.isoLocked = false
            calibrationCameraProfile.shutterSpeedLocked = false
            ocrCameraService.setAutoExposure()
        }
        calibrationCameraProfileStatusText = locked ? "Exposure locked for OCR stability." : "Exposure returned to auto."
    }

    func setCalibrationWhiteBalanceLock(_ locked: Bool) {
        calibrationCameraProfile.whiteBalanceLocked = locked
        if locked {
            calibrationCameraProfile.whiteBalanceTemperatureValue = Double(ocrCameraService.whiteBalanceTemperature)
            calibrationCameraProfile.whiteBalanceTintValue = Double(ocrCameraService.whiteBalanceTint)
            ocrCameraService.lockCurrentWhiteBalance()
        } else {
            ocrCameraService.setAutoWhiteBalance()
        }
        calibrationCameraProfileStatusText = locked ? "White balance locked for OCR stability." : "White balance returned to auto."
    }

    func setCalibrationISOLock(_ locked: Bool) {
        calibrationCameraProfile.isoLocked = locked
        if locked { calibrationCameraProfile.exposureISOValue = Double(ocrCameraService.isoValue) }
        calibrationCameraProfileStatusText = locked ? "ISO locked." : "ISO unlocked."
    }

    func setCalibrationShutterLock(_ locked: Bool) {
        calibrationCameraProfile.shutterSpeedLocked = locked
        if locked { calibrationCameraProfile.exposureDurationSeconds = ocrCameraService.exposureDurationSeconds }
        calibrationCameraProfileStatusText = locked ? "Shutter speed locked." : "Shutter speed unlocked."
    }

    func setCalibrationManualFocus(_ value: Float) {
        guard isCalibrationManualCameraEditable else { return }
        let clamped = min(max(value, 0), 1)
        calibrationCameraProfile.focusValue = Double(clamped)
        ocrCameraService.setManualFocus(position: clamped)
    }

    func setCalibrationManualISO(_ value: Float) {
        guard isCalibrationManualCameraEditable else { return }
        calibrationCameraProfile.exposureISOValue = Double(value)
        calibrationCameraProfile.exposureLocked = true
        calibrationCameraProfile.isoLocked = true
        ocrCameraService.setManualISO(value)
        calibrationCameraProfileStatusText = "Manual ISO applied to calibration camera."
    }

    func setCalibrationManualShutter(seconds: Double) {
        guard isCalibrationManualCameraEditable else { return }
        calibrationCameraProfile.exposureDurationSeconds = seconds
        calibrationCameraProfile.exposureLocked = true
        calibrationCameraProfile.shutterSpeedLocked = true
        ocrCameraService.setManualExposureDuration(seconds: seconds)
        calibrationCameraProfileStatusText = "Manual shutter speed applied to calibration camera."
    }

    func setCalibrationExposureBias(_ value: Float) {
        guard isCalibrationManualCameraEditable else { return }
        calibrationCameraProfile.exposureBiasValue = Double(value)
        ocrCameraService.setExposureTargetBias(value)
    }

    func setCalibrationManualWhiteBalance(temperature: Float, tint: Float) {
        guard isCalibrationManualCameraEditable else { return }
        calibrationCameraProfile.whiteBalanceTemperatureValue = Double(temperature)
        calibrationCameraProfile.whiteBalanceTintValue = Double(tint)
        calibrationCameraProfile.whiteBalanceLocked = true
        ocrCameraService.setManualWhiteBalance(temperature: temperature, tint: tint)
    }

    func selectCalibrationVideoFormat(id: String) {
        guard isCalibrationManualCameraEditable else { return }
        guard let profile = ocrCameraService.capabilityProfiles.first(where: { $0.formatID == id }) else {
            calibrationCameraProfileStatusText = "Select an exact resolution/frame-rate mode from the refreshed camera list."
            return
        }
        selectCalibrationCapabilityProfile(id: profile.id)
    }

    func selectCalibrationCapabilityProfile(id: String) {
        guard isCalibrationManualCameraEditable else { return }
        if let profile = ocrCameraService.capabilityProfiles.first(where: { $0.id == id }),
           let formatID = profile.formatID {
            calibrationCameraProfile.resolutionFormatID = formatID
            calibrationCameraProfile.setExactCaptureCadence(profile.cadence)
            calibrationCameraProfileStatusText = "Applying \(profile.displayLabel) to the OCR CaptureEngine…"
        } else {
            calibrationCameraProfile.resolutionFormatID = nil
            calibrationCameraProfile.setExactCaptureCadence(nil)
        }
        selectOCRCapabilityProfile(id: id)
    }

    func copyBroadcastSettingsToCalibration(reason: String = "manual request") {
        syncCalibrationCameraWithBroadcastSettings(reason: reason)
    }

    func syncCalibrationCameraWithBroadcastSettings(reason: String = "manual request") {
        let previousLayout = ocrLayout
        let liveService = liveCameraService
        guard let liveCameraID = liveService.selectedCameraID else {
            calibrationCameraWarningText = "Broadcast camera is not selected. Calibration cannot match Broadcast View yet."
            calibrationCameraProfileStatusText = "Select a Broadcast camera first, or use Manual Calibration Settings."
            return
        }

        if ocrCameraService.availableCameras.isEmpty {
            ocrCameraService.refreshAvailableCameras()
        }

        let liveFormatPreference = liveService.captureFormatPreferenceSnapshot()
        ocrCameraService.selectCompressionProfile(liveService.selectedCompressionProfile)
        setOCRCameraZoom(liveCameraZoomFactor)

        calibrationCameraProfile.profileMode = .manual
        calibrationCameraProfile.manualCalibrationModeEnabled = true
        calibrationCameraProfile.selectedCameraSourceID = liveCameraID
        if let option = ocrCameraService.availableCameras.first(where: { $0.id == liveCameraID })
            ?? liveService.availableCameras.first(where: { $0.id == liveCameraID }) {
            calibrationCameraProfile.selectedCameraSourceKind = calibrationSourceKind(for: option)
        }
        calibrationCameraProfile.lockedZoomValue = Double(cameraZoomFactor)
        calibrationCameraProfile.resolutionFormatID = liveService.selectedVideoFormatID
        calibrationCameraProfile.setExactCaptureCadence(liveFormatPreference?.cadence)
        ocrLayout = previousLayout
        calibrationCameraWarningText = nil
        calibrationCameraProfileStatusText = "Broadcast camera settings copied into Manual Calibration (\(reason))."
        MainThreadStallMonitor.shared.markContext("broadcast camera settings copied to calibration: \(reason)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.applyOCRCameraAndFormatSelection(
                sourceID: liveCameraID,
                formatPreference: liveFormatPreference,
                reason: "copy Broadcast settings to Calibration: \(reason)"
            )
        }
    }

    func applyCalibrationManualLocks(reason: String = "manual lock apply") {
        var profile = calibrationCameraProfile
        if profile.profileMode != .manual || !profile.manualCalibrationModeEnabled {
            profile.profileMode = .manual
            profile.manualCalibrationModeEnabled = true
            calibrationCameraProfile = profile
        }
        applyCalibrationHardwareLocksFromCurrentProfile(reason: reason)
    }

    /// Recovery AE / RL-065: physical application is a projection of the saved
    /// camera profile, not a profile edit. This boundary may request hardware
    /// controls but cannot mutate CalibrationStore dirty state.
    private func applyCalibrationHardwareLocksFromCurrentProfile(reason: String) {
        let profile = calibrationCameraProfile
        let service = ocrCameraService
        let external = service.activeCaptureDeviceIsExternal || service.selectedCameraIsExternal
        var projected: [String] = []
        var skipped: [String] = []

        if profile.zoomLocked {
            let clamped = clampedOCRZoomValue(CGFloat(profile.lockedZoomValue))
            cameraZoomStore.request(
                clamped,
                for: .ocr,
                deviceID: service.selectedCameraID,
                source: "HockeyScoreboardViewModel.applyCalibrationHardwareLocksFromCurrentProfile",
                reason: "Recovery AE saved OCR zoom applied after physical staging"
            )
            service.setOCRZoomFactor(
                clamped,
                reason: "Recovery AE saved OCR zoom applied after physical staging"
            )
            projected.append("Zoom")
        }

        if profile.focusLocked {
            if service.supportsManualFocus {
                service.setManualFocus(position: Float(profile.focusValue))
                projected.append("Focus")
            } else {
                skipped.append("Focus")
            }
        }

        // Recovery AH / RL-071: external UVC devices can expose placeholder
        // exposure modes while reporting ISO/shutter ranges that are not usable.
        // A saved generic camera profile must not turn those placeholders into an
        // applied hardware contract. HockeyCameraService capability truth is the
        // gate; unsupported UVC controls remain firmware/device-owned.
        if profile.exposureLocked {
            if service.supportsExposureLockOrCustom {
                service.lockCurrentExposure()
                projected.append("Exposure")
            } else {
                skipped.append("Exposure")
            }
        }
        if let bias = profile.exposureBiasValue {
            if service.supportsExposureBias {
                service.setExposureTargetBias(Float(bias))
                projected.append("Exposure bias")
            } else if external {
                skipped.append("Exposure bias")
            }
        }
        if profile.whiteBalanceLocked {
            if let temperature = profile.whiteBalanceTemperatureValue,
               let tint = profile.whiteBalanceTintValue,
               service.supportsManualWhiteBalanceGains {
                service.setManualWhiteBalance(temperature: Float(temperature), tint: Float(tint))
                projected.append("White balance")
            } else if service.supportsWhiteBalanceLock {
                service.lockCurrentWhiteBalance()
                projected.append("White balance")
            } else {
                skipped.append("White balance")
            }
        }
        if profile.isoLocked, let iso = profile.exposureISOValue {
            if service.supportsManualISO {
                service.setManualISO(Float(iso))
                projected.append("ISO")
            } else {
                skipped.append("ISO")
            }
        }
        if profile.shutterSpeedLocked, let seconds = profile.exposureDurationSeconds {
            if service.supportsManualExposureDuration {
                service.setManualExposureDuration(seconds: seconds)
                projected.append("Shutter")
            } else {
                skipped.append("Shutter")
            }
        }

        let projectedText = projected.isEmpty ? "none" : projected.joined(separator: ", ")
        let skippedText = skipped.isEmpty ? "none" : skipped.joined(separator: ", ")
        calibrationCameraProfileStatusText = external
            ? "External camera controls projected by capability: \(projectedText); device-owned/unsupported: \(skippedText)."
            : "Calibration camera controls projected: \(projectedText); unsupported: \(skippedText)."
        RinkLensStructuredEventLogger.shared.record(
            domain: .cameraControl,
            event: "ocr_saved_profile_capability_projection",
            entityID: service.activeCaptureDeviceID ?? service.resolvedCameraDeviceID ?? service.selectedCameraID,
            previous: ["requestedLocks": profile.lockSummary],
            next: [
                "external": String(external),
                "projected": projectedText,
                "deviceOwnedOrUnsupported": skippedText,
                "hardwareAcknowledgement": service.appliedCameraControlAcknowledgementText
            ],
            source: "HockeyScoreboardViewModel.applyCalibrationHardwareLocksFromCurrentProfile",
            reason: reason,
            authoritativeOwner: "RinkLensCameraControlStore -> HockeyCameraService"
        )
        MainThreadStallMonitor.shared.markContext("Recovery AH capability-specific calibration control projection: \(reason)")
    }

    private func validateSavedCalibrationCameraSource() {
        guard let savedID = calibrationCameraProfile.selectedCameraSourceID else { return }
        let options = ocrCameraService.availableCameras
        guard !options.isEmpty else { return }

        if let option = options.first(where: { $0.id == savedID }) {
            if option.isExternal && !option.isAvailable {
                calibrationCameraWarningText = "Saved External Camera selection retained — USB camera is not connected."
            } else {
                calibrationCameraWarningText = nil
            }
            return
        }

        // UX16c8 migration: older templates stored AVCaptureDevice unique IDs.
        // Convert them to a stable logical source. RL-014 deliberately permits
        // migration to the permanent External row even while it is disconnected.
        if let migrated = options.first(where: {
            calibrationSourceKind(for: $0) == calibrationCameraProfile.selectedCameraSourceKind
        }) {
            calibrationCameraProfile.selectedCameraSourceID = migrated.id
            calibrationCameraWarningText = migrated.isExternal && !migrated.isAvailable
                ? "Saved External Camera selection retained — USB camera is not connected."
                : nil
            MainThreadStallMonitor.shared.trace(
                RinkLensBuildInfo.traceContext("migrated calibration camera source id old=\(savedID) new=\(migrated.id)")
            )
            return
        }

        calibrationCameraWarningText = "Saved camera source is unavailable. Its logical selection has been retained for a later discovery refresh."
    }

    private func frameRateFromResolutionText(_ value: String) -> Int? {
        guard let fpsRange = value.range(of: "fps") else { return nil }
        let prefix = value[..<fpsRange.lowerBound]
        let digits = prefix.reversed().prefix { $0.isNumber }.reversed()
        return Int(String(digits))
    }

    var liveCameraConflictID: String? { ocrCameraService.selectedCameraID }
    var ocrCameraConflictID: String? { liveCameraService.selectedCameraID }

    var cameraGuardRailStatus: String {
        if liveCameraService.selectedCameraID == nil || ocrCameraService.selectedCameraID == nil {
            return "Guard rail active: a camera can be set to None so the other role can use the available device."
        }
        if !liveCameraService.selectedCameraIsExternal && !ocrCameraService.selectedCameraIsExternal {
            return "Built-in camera safety: only one capture session is activated at a time. Connect an external OCR camera for simultaneous two-camera operation."
        }
        if let liveID = liveCameraService.selectedCameraID,
           let ocrID = ocrCameraService.selectedCameraID,
           liveID == ocrID {
            return "Guard rail active: the same external camera cannot be assigned to both capture sessions."
        }
        return "Two-camera mode ready: Broadcast and OCR use separate hardware sources."
    }

    private func alternativeCameraID(from service: HockeyCameraService, excluding excludedID: String) -> String? {
        service.availableCameras.first { $0.id != excludedID }?.id
    }

    private func enforceDistinctCameraSelection() {
        guard let liveID = liveCameraService.selectedCameraID,
              let ocrID = ocrCameraService.selectedCameraID,
              liveID == ocrID else { return }

        // UX16c13: built-in Back/Front may be selected for both roles because only
        // the visible route owns camera hardware. Never auto-call selectNoCamera();
        // that API is reserved for an explicit operator action. The one unsupported
        // case is one physical external source assigned to both simultaneously.
        guard liveID == HockeyCameraService.externalCameraSourceID else {
            MainThreadStallMonitor.shared.trace("UX16c13 same built-in logical source allowed across roles")
            return
        }

        statusMessage = "The same external camera is assigned to Broadcast and OCR. Select a built-in source for one role before simultaneous operation."
        MainThreadStallMonitor.shared.trace("UX16c13 external source conflict retained for operator correction; no role was cleared")
    }

    func beginCameraSettingsInteraction() {
        MainThreadStallMonitor.shared.markContext("opening camera settings")
        MainThreadStallMonitor.shared.trace("camera settings open requested - quarantined, no camera/session/preview action")

        // v0.8.4u: Camera Settings is now quarantined from the preview pipeline.
        // Opening the sheet must not call requestCaptureForRoleIfNeeded, apply camera
        // priority, reattach preview layers, pause OCR, or mutate frame policy.
        // The previous ensureVisiblePreviewSessionRunning() call was causing a
        // preview detach/attach cycle while the sheet was being presented, which
        // matched the freeze/crash breadcrumbs. Device discovery is safe here and
        // keeps the Picker current even when no external camera event has occurred.
        // UX16c11: Do not release both sessions merely because Camera Settings
        // opened. Picker changes already stage/release the service being edited,
        // and the destination route performs a deterministic ownership hand-off.
        // Eagerly releasing both inputs was leaving OCR Setup black when its
        // activation callback was skipped or delayed.
        // Camera lists are already maintained by startup discovery and device
        // connect/disconnect notifications. Re-running both discovery pipelines
        // when the Settings camera page first appears caused a multi-second first
        // entry delay. Operator Refresh remains available for an explicit rescan.
        liveCameraService.noteLifecycleEvent("Camera Settings opened: retained discovered camera list")
        ocrCameraService.noteLifecycleEvent("Camera Settings opened: retained discovered camera list")
        pausedOCRForCameraSettings = false
    }

    func endCameraSettingsInteraction() {
        MainThreadStallMonitor.shared.markContext("closing camera settings")
        MainThreadStallMonitor.shared.trace("camera settings closed - quarantined, no camera/session/preview action")
        pausedOCRForCameraSettings = false
    }


    func beginOperatorControlsInteraction() {
        MainThreadStallMonitor.shared.markContext("opening operator controls")
        MainThreadStallMonitor.shared.trace("operator controls opened - safe mode, no camera/session mutation")

        // v0.8.4z: Broadcast controls must be read/write UI only. Opening the
        // operator controls sheet previously called camera-settings and preview
        // recovery hooks. That could start/stop or revalidate preview policy while
        // the sheet was being built, which matched the remaining hangs on the
        // Broadcast controls Camera page.
        pausedOCRForCameraSettings = false
        liveCameraService.noteLifecycleEvent("Operator controls opened: safe mode, no camera action")
        ocrCameraService.noteLifecycleEvent("Operator controls opened: safe mode, no OCR/session action")
    }

    func endOperatorControlsInteraction() {
        MainThreadStallMonitor.shared.markContext("closing operator controls")
        MainThreadStallMonitor.shared.trace("operator controls closed - safe mode, no camera/session mutation")
        pausedOCRForCameraSettings = false
        liveCameraService.noteLifecycleEvent("Operator controls closed: safe mode, no camera action")
        ocrCameraService.noteLifecycleEvent("Operator controls closed: safe mode, no OCR/session action")
    }

    func noteOperatorControlsPageChanged(to page: String) {
        MainThreadStallMonitor.shared.markContext("operator controls page: \(page)")
        MainThreadStallMonitor.shared.trace("operator controls page changed - safe mode: \(page)")
        // v0.8.4z: Page changes are diagnostics only. Do not call
        // ensureBroadcastPreviewSessionRunning() from a segmented control change.
        // Preview recovery is explicit via Recover Camera Preview.
        liveCameraService.noteLifecycleEvent("Operator controls page: \(page)")
    }

    func setOCRDiagnosticsVisible(_ visible: Bool) {
        // Diagnostics are intentionally Calibration-only. The Live OCR popup is
        // a lightweight controls panel and must not turn on OCR diagnostic
        // publishing, as those values update frequently and can cause preview lag.
        isOCRDiagnosticsVisible = visible && currentScreen == .calibration
    }

    func setCalibrationPhaseOverrideVisible(_ visible: Bool) {
        let active = visible && currentScreen == .calibration && calibrationPreviewMountAllowedW10F
        calibrationPhaseOverrideActive = active
        if active {
            let detail = "Calibration phase active: match-day clock, intermission and pixel-hash gating are ignored while zones are visible. Test OCR and selected-zone crops use the Calibration path only."
            updatePixelHashingStatus(false, detail: detail, force: true)
            smartChangeLastDecisionText = detail
            MainThreadStallMonitor.shared.traceOCRPhase("UX15e calibration override guard active selected=\(selectedRegionKey.rawValue); broadcast/intermission gating ignored")
        }
    }

    func requestCalibrationOCRTest(source: String = "calibration") {
        guard currentScreen == .calibration else { return }
        guard !selectedZoneTestOCRRequestPending, !selectedZoneTestOCRInFlight else {
            let detail = "UX16c43 Test OCR ignored: one Test OCR request is already pending or active"
            selectedRegionPreviewStatus = "Test OCR already running for \(selectedRegionKey.likelyTitle)."
            testOCROutcomeText = detail
            MainThreadStallMonitor.shared.traceOCRPhase(detail)
            return
        }

        pendingTestOCRResult = nil
        pendingTestOCRApplyDescription = nil
        selectedZoneTestOCRRequestSequence &+= 1
        let requestID = selectedZoneTestOCRRequestSequence
        let key = selectedRegionKey

        if !userWantsOCRRunning || isOCRPaused {
            resumeOCRProcessing()
        }
        calibrationCropPreviewArmedUntil = CFAbsoluteTimeGetCurrent() + 4.0
        // UX16d15j Build 525: Verify Zone owns exactly one explicit Test pass.
        // Do not leave the selected-zone scheduler priority armed for five seconds;
        // that previously suppressed normal hash/audit admission after the result.
        updateFrameDeliveryPolicy(force: true)

        selectedZoneTestOCRRequestPending = true
        testOCROutcome = .waitingForFrame
        testOCROutcomeText = "Preparing the latest current-generation OCR frame."
        selectedRegionPreviewStatus = "Test OCR preparing current \(key.likelyTitle) frame..."
        MainThreadStallMonitor.shared.markContext("UX16c43 Test OCR request accepted id=\(requestID) source=\(source) key=\(key.rawValue)")

        selectedZoneTestOCRTask?.cancel()
        selectedZoneTestOCRTask = Task { @MainActor [weak self] in
            await self?.prepareAndRunBoundedCalibrationOCRTest(
                source: source,
                key: key,
                requestID: requestID
            )
        }
    }

    private func prepareAndRunBoundedCalibrationOCRTest(
        source: String,
        key: OCRRegionKey,
        requestID: Int
    ) async {
        defer {
            if selectedZoneTestOCRRequestSequence == requestID {
                selectedZoneTestOCRTask = nil
            }
        }

        // UX16d4 Build 501 core path: Test OCR consumes the fresh OCR frame
        // already owned by FrameHub. It must never request ocrOnly, stop/start the
        // CaptureEngine, or change capture generation merely to read one field.
        guard !Task.isCancelled,
              selectedZoneTestOCRRequestSequence == requestID,
              selectedRegionKey == key,
              currentScreen == .calibration else {
            selectedZoneTestOCRRequestPending = false
            return
        }

        // Operator Test OCR pre-empts the current logical pass. The core engine
        // releases admission synchronously; stale work is token-fenced and cannot
        // publish or keep executorWorkInFlight set.
        if ocrOrchestrationEngine.snapshot().isBusy {
            ocrOrchestrationEngine.cancelAll(reason: "operator Test OCR preemption")
            ocrControlPlane.cancelInFlight(reason: "operator Test OCR owns the exclusive diagnostic lane")
            activeProductionOCRPlan = nil
            isProcessing = false
        }
        guard let passToken = ocrOrchestrationEngine.tryBeginTestPass(requestedKeys: [key]) else {
            selectedZoneTestOCRRequestPending = false
            testOCROutcome = .rejected
            testOCROutcomeText = "Rejected: another current OCR pass still owns admission."
            selectedRegionPreviewStatus = "Test OCR could not reserve the OCR processor."
            MainThreadStallMonitor.shared.traceOCRPhase("UX16d4 core Test OCR token rejected after synchronous preemption key=\(key.rawValue)")
            return
        }

        selectedZoneTestOCRRequestPending = false
        selectedZoneTestOCRInFlight = true
        selectedZoneTestOCRGeneration &+= 1
        selectedZoneOneShotSequence &+= 1
        let testGeneration = selectedZoneTestOCRGeneration
        let oneShotID = selectedZoneOneShotSequence
        selectedZoneActiveOneShotID = oneShotID
        selectedZoneActiveOneShotKey = key
        testOCROutcome = .waitingForFrame
        testOCROutcomeText = "Waiting for a current-generation frame from the selected OCR camera."
        selectedRegionPreviewStatus = "Test OCR waiting for a fresh \(key.likelyTitle) frame..."
        MainThreadStallMonitor.shared.traceOCRPhase(
            "UX16c43 Test OCR token acquired id=\(requestID) \(passToken.diagnosticText) key=\(key.rawValue)"
        )

        let capture = externalOCRMultiCamCoordinator.snapshot
        guard capture.isActive,
              capture.sessionRunning,
              RinkLensCaptureLifecycleMode(rawValue: capture.captureModeText)?.requiresOCR == true,
              let deviceID = capture.ocrDeviceID else {
            publishTestOCROutcome(
                .noFreshFrame,
                detail: "No active OCR capture contract is available.",
                key: key
            )
            _ = ocrOrchestrationEngine.finishPass(
                token: passToken,
                reason: "selected-zone-no-active-ocr-contract"
            )
            selectedZoneTestOCRInFlight = false
            return
        }

        let frame = await RinkLensFrameHub.shared.waitForFreshFrame(
            for: .ocr,
            maxAge: 0.30,
            requiredCaptureGeneration: capture.transitionGeneration,
            requiredPhysicalDeviceID: deviceID,
            timeout: 0.85
        )

        guard !Task.isCancelled,
              selectedZoneTestOCRRequestSequence == requestID,
              selectedZoneTestOCRGeneration == testGeneration,
              selectedRegionKey == key,
              selectedZoneActiveOneShotID == oneShotID,
              ocrOrchestrationEngine.isPassCurrent(passToken) else {
            _ = ocrOrchestrationEngine.finishPass(
                token: passToken,
                reason: "selected-zone-cancelled-after-frame-wait"
            )
            selectedZoneTestOCRInFlight = false
            return
        }

        guard let frame else {
            publishTestOCROutcome(
                .noFreshFrame,
                detail: "No matching OCR frame arrived within 0.85 seconds.",
                key: key
            )
            _ = ocrOrchestrationEngine.finishPass(
                token: passToken,
                reason: "selected-zone-fresh-frame-timeout"
            )
            selectedZoneTestOCRInFlight = false
            MainThreadStallMonitor.shared.traceOCRPhase(
                "UX16c43 Test OCR timeout source=\(source) key=\(key.rawValue) generation=\(capture.transitionGeneration) device=\(deviceID)"
            )
            return
        }

        guard updateSelectedRegionPreview(from: frame.pixelBuffer, force: true) else {
            publishTestOCROutcome(
                .cropInvalid,
                detail: "The selected OCR crop is unavailable or too small.",
                key: key
            )
            _ = ocrOrchestrationEngine.finishPass(
                token: passToken,
                reason: "selected-zone-invalid-crop"
            )
            selectedZoneTestOCRInFlight = false
            return
        }

        publishSelectedRegionTestOCR(
            from: frame,
            key: key,
            previewSize: authoritativeOCRGeometryViewportSize,
            previewRotationDegrees: ocrPreviewRotationOffsetDegrees,
            passToken: passToken,
            oneShotID: oneShotID,
            selectedTestGeneration: testGeneration
        )
    }

    private func selectedOCRRegionLayoutText() -> String {
        let key = selectedRegionKey
        let region = ocrLayout[key]
        return String(
            format: "selected=%@ x=%.4f y=%.4f w=%.4f h=%.4f",
            key.rawValue,
            Double(region.x),
            Double(region.y),
            Double(region.width),
            Double(region.height)
        )
    }

    func setPerformanceSafeMode(_ enabled: Bool) {
        guard performanceSafeModeEnabled != enabled else { return }
        performanceSafeModeEnabled = enabled
        if enabled {
            calibrationCropPreviewArmedUntil = 0
            selectedRegionRawPreviewImage = nil
            selectedRegionProcessedPreviewImage = nil
            selectedRegionThresholdedPreviewImage = nil
            selectedRegionSegmentPreviewImage = nil
            selectedRegionPreviewStatus = "Safe Mode: crop previews and diagnostics disabled"
            scoreFastCheckUntil = 0
            liveScoreEventWatchUntil = 0
            livePeriodEventWatchUntil = 0
            livePenaltyPairFastCheckUntil.removeAll()
            livePenaltyPairRetryCooldownUntil.removeAll()
            livePenaltyVisualUnusableAttempts.removeAll()
            periodFastCheckUntil = 0
        }
        updateFrameDeliveryPolicy()
    }

    /// Backwards-compatible OCR zoom setter.
    func setCameraZoom(_ zoom: CGFloat) {
        setOCRCameraZoom(zoom)
    }

    private func clampedOCRZoomValue(_ zoom: CGFloat) -> CGFloat {
        let lowerBound = max(CGFloat(1.0), ocrCameraService.minZoomFactor)
        let upperBound = min(CGFloat(5.0), max(lowerBound, ocrCameraService.maxZoomFactor))
        return min(max(zoom, lowerBound), upperBound)
    }

    func setOCRCameraZoom(_ zoom: CGFloat) {
        // UX12w: OCR zoom is intentionally capped to 1x–5x. Some internal
        // cameras report a much larger hardware maximum, but that makes the
        // scoreboard calibration slider too sensitive and easy to mis-set.
        let clamped = clampedOCRZoomValue(zoom)
        cameraZoomFactor = clamped
        if calibrationCameraProfile.profileMode == .manual && calibrationCameraProfile.zoomLocked {
            calibrationCameraProfile.lockedZoomValue = Double(clamped)
        }
        ocrCameraService.setOCRZoomFactor(clamped, reason: "OCR camera zoom requested through calibration owner")
    }

    func setLiveCameraZoom(_ zoom: CGFloat) {
        applyLiveCameraZoom(zoom, source: "button")
    }

    /// Presentation-draft path for real-time slider response. It deliberately
    /// does not mutate requested/applied zoom truth and never starts an optical
    /// handoff. Samples that remain in the active physical lens domain enter the
    /// CaptureEngine capacity-one mailbox; a cross-domain value stays UI-local
    /// until the operator releases the slider and commits one transaction.
    func previewLiveCameraZoomFromSlider(_ zoom: CGFloat) {
        let draft = min(max(zoom, 0.5), 5.0)
        let capture = externalOCRMultiCamCoordinator.snapshot
        guard capture.sessionRunning,
              capture.activeMode.requiresBroadcast,
              capture.liveDeviceID != nil,
              !capture.isTransitioning,
              cameraZoomStore.liveLensTransaction == nil else { return }

        let activeDeviceCanApplyInPlace = liveCameraService.broadcastPhysicalDeviceID(
            capture.liveDeviceID,
            satisfiesHalfXTarget: draft < 1.0
        )
        guard activeDeviceCanApplyInPlace else { return }

        externalOCRMultiCamCoordinator.submitLatestBroadcastZoomPreview(
            logicalZoom: draft,
            source: "Recovery AX real-time same-domain slider draft"
        )
    }

    func commitLiveCameraZoomFromSlider(_ zoom: CGFloat) {
        applyLiveCameraZoom(zoom, source: "slider-commit")
    }

    private func applyLiveCameraZoom(_ zoom: CGFloat, source: String) {
        let requested = min(max(zoom, 0.5), 5.0)
        let requestedText = String(format: "%.1fx", Double(requested))
        MainThreadStallMonitor.shared.traceZoomMovement("request source=\(source) value=\(requestedText) captureMode=\(externalOCRMultiCamCoordinator.activeModeSnapshot.rawValue)")

        let appliedZoom = cameraZoomStore.applied(for: .live)
        let previouslyRequestedZoom = cameraZoomStore.requested(for: .live)
        if cameraZoomStore.liveLensTransaction == nil,
           abs(appliedZoom - requested) < 0.01, abs(previouslyRequestedZoom - requested) < 0.01 {
            return
        }

        // An optical handoff is immutable until CaptureLifecycleController has
        // verified the replacement lens, its first frame and any same-file
        // writer rebind. While that boundary is open, later taps update only the
        // authoritative desired zoom. The controller performs one smooth
        // convergence pass after the handoff terminates; no in-place hardware
        // ramp may race the branch transaction.
        if let pending = cameraZoomStore.liveLensTransaction {
            liveCameraZoomFactor = requested
            RinkLensStructuredEventLogger.shared.record(
                domain: .cameraControl,
                event: "camera_zoom_desired_retained_during_immutable_handoff",
                entityID: pending.target.rawValue,
                previous: [
                    "transactionID": pending.transactionID.uuidString,
                    "immutableZoom": String(pending.requestedZoom)
                ],
                next: [
                    "desiredZoom": String(Double(requested)),
                    "physicalMutation": "deferred-until-handoff-acknowledged"
                ],
                source: "HockeyScoreboardViewModel.applyLiveCameraZoom",
                reason: "Operator input updated desired framing while an optical transaction owned hardware",
                captureGeneration: externalOCRMultiCamCoordinator.snapshot.transitionGeneration,
                authoritativeOwner: "RinkLensCameraZoomStore"
            )
            return
        }

        let capture = externalOCRMultiCamCoordinator.snapshot
        guard capture.sessionRunning,
              capture.activeMode.requiresBroadcast,
              capture.liveDeviceID != nil else {
            // A committed operator request remains authoritative even when the
            // camera is temporarily unavailable.
            liveCameraZoomFactor = requested
            return
        }

        // Ask the physical-device authority. A virtual rear camera can own both
        // optical domains through constituent switching. A physical Ultra Wide
        // owns only sub-1x framing; committing 1x or above must hand capture back
        // to Wide so the selected image-quality cadence can be restored.
        let activeDeviceCanApplyInPlace = liveCameraService.broadcastPhysicalDeviceID(
            capture.liveDeviceID,
            satisfiesHalfXTarget: requested < 1.0
        )

        // Slider motion is presentation-local in its owning view. Only this
        // committed slider/preset request enters requested-zoom authority;
        // hardware acknowledgement remains separate.
        liveCameraZoomFactor = requested

        let rampDuration = broadcastZoomTransitionSpeed.durationSeconds

        if activeDeviceCanApplyInPlace {
            let animated = smoothBroadcastZoomTransitionsEnabled
            externalOCRMultiCamCoordinator.submitBroadcastZoomInPlace(
                logicalZoom: requested,
                animated: animated,
                duration: rampDuration,
                source: "Recovery AA session-queue committed zoom: \(source)",
                waitForSettlement: true
            ) { [weak self] result in
                guard let self else { return }
                guard result.succeeded else {
                    self.statusMessage = result.statusText
                    return
                }
                let latestDesired = self.cameraZoomStore.requested(for: .live)
                guard abs(latestDesired - requested) < 0.01 else { return }
                self.cameraZoomStore.commitBroadcastDigitalZoom(
                    requested,
                    deviceID: result.physicalDeviceID,
                    captureGeneration: result.captureGeneration,
                    source: "CaptureEngine.sessionQueue",
                    reason: "Recovery AA verified physical zoom settlement"
                )
            }
            return
        }

        // Crossing an optical domain is one discrete lifecycle transaction.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let applied = await self.captureLifecycleController.requestBroadcastOpticalHandoff(
                logicalZoom: requested,
                animated: self.smoothBroadcastZoomTransitionsEnabled,
                duration: rampDuration,
                source: "Recovery AA optical commit: \(source)",
                zoomStore: self.cameraZoomStore
            )
            _ = applied
        }
    }

    func setSmoothBroadcastZoomTransitionsEnabled(_ enabled: Bool) {
        smoothBroadcastZoomTransitionsEnabled = enabled
        MainThreadStallMonitor.shared.traceZoomMovement("smooth transitions set: \(enabled ? "on" : "off")")
        statusMessage = enabled
            ? "Smooth Broadcast zoom enabled. Digital zoom ramps within the active lens; 0.5x/1x optical handoffs preserve the same recording file."
            : "Smooth broadcast zoom transitions disabled."
    }

    func setBroadcastZoomTransitionSpeed(_ speed: BroadcastZoomTransitionSpeed) {
        broadcastZoomTransitionSpeed = speed
        MainThreadStallMonitor.shared.traceZoomMovement("fade selector set: \(speed.label)")
        statusMessage = "Broadcast 1x-5x zoom transition speed: \(speed.label)."
    }

    func cycleBroadcastZoomTransitionSpeed() {
        setBroadcastZoomTransitionSpeed(broadcastZoomTransitionSpeed.next)
    }

    /// v0.9.0n3d: 0.5x preset. Prefer zooming the active virtual rear camera rather than
    /// switching physical inputs, because input switching causes a brief black preview flicker.
    func setLiveCameraHalfXWidePreset() {
        setLiveCameraZoom(0.5)
    }

    /// Backwards-compatible name used by earlier n2 packages.
    func setLiveCameraWideAnglePreset() {
        setLiveCameraHalfXWidePreset()
    }

    /// v0.9.0n3d: 1x preset. Prefer changing zoom on the active virtual rear camera
    /// rather than rebuilding the capture session.
    func setLiveCameraOneXPreset() {
        setLiveCameraZoom(1.0)
    }

    func setLiveCameraAppleStyleAutoQuality(_ enabled: Bool) {
        liveCameraService.setAppleStyleAutoQualityEnabled(enabled)
        statusMessage = enabled ? "Broadcast automatic focus, exposure and white balance enabled." : "Broadcast manual lens overrides enabled."
    }

    func setOCRCameraAppleStyleAutoQuality(_ enabled: Bool) {
        ocrCameraService.setAppleStyleAutoQualityEnabled(enabled)
        statusMessage = enabled ? "OCR automatic focus, exposure and white balance enabled." : "OCR manual lens overrides enabled."
    }

    func applyBroadcastDefaultCameraProfile() {
        applyRoleDefaultCameraProfile(role: .live)
    }

    func applyOCRDefaultCameraProfile() {
        applyRoleDefaultCameraProfile(role: .ocr)
    }

    private func applyRoleDefaultCameraProfile(role: CameraRole) {
        guard !blockCameraMutationDuringRecording(action: "apply role camera default", owner: role == .live ? "Live Camera" : "OCR Camera") else { return }
        Task { @MainActor in
            let roleText = role == .live ? "Broadcast" : "OCR"
            let service = role == .live ? liveCameraService : ocrCameraService
            let before = externalOCRMultiCamCoordinator.snapshot
            let previousLiveID = before.liveDeviceID ?? liveCameraService.resolvedCameraDeviceID
            let previousOCRID = before.ocrDeviceID ?? ocrCameraService.resolvedCameraDeviceID
            var staged = false
            let outcome = await captureLifecycleController.reconfigureActiveCapture(reason: "\(roleText) role default profile requested") { [self] in
                staged = service.stageRoleDefaultProfile(reason: "operator requested \(roleText) default \(service.roleDefaultProfileText)")
                let mode = authoritativeDesiredCaptureMode(
                    liveIdentity: liveCameraService.captureIdentitySnapshot(),
                    ocrIdentity: ocrCameraService.captureIdentitySnapshot()
                )
                let request = captureRequest(
                    for: mode,
                    reason: staged ? "\(roleText) role default resume" : "\(roleText) role default staging failed",
                    liveDeviceIDOverride: previousLiveID,
                    ocrDeviceIDOverride: previousOCRID
                )
                return staged ? .staged(request) : .failed(resume: request, status: "\(roleText) default profile is unavailable on the selected camera")
            }
            applyCaptureLifecycleOutcome(outcome)
            statusMessage = staged && outcome.succeeded
                ? "\(roleText) default applied: \(service.roleDefaultProfileText)."
                : outcome.statusText
        }
    }

    func setLiveCameraMatchViewToRecording(_ enabled: Bool) {
        liveCameraService.setMatchViewToRecordingEnabled(enabled)
        statusMessage = enabled ? "View and recording matched." : "View and recording matching disabled."
    }

    func rotateLivePreviewClockwise() {
        livePreviewRotationOffsetDegrees = normalizedPreviewRotation(livePreviewRotationOffsetDegrees + 90)
        suppressMotionProtectionAfterCameraTransformChange()
    }

    func rotateLivePreviewCounterClockwise() {
        livePreviewRotationOffsetDegrees = normalizedPreviewRotation(livePreviewRotationOffsetDegrees - 90)
        suppressMotionProtectionAfterCameraTransformChange()
    }

    func resetLivePreviewRotation() {
        livePreviewRotationOffsetDegrees = 0
        suppressMotionProtectionAfterCameraTransformChange()
    }

    func rotateOCRPreviewClockwise() {
        ocrPreviewRotationOffsetDegrees = normalizedPreviewRotation(ocrPreviewRotationOffsetDegrees + 90)
        suppressMotionProtectionAfterCameraTransformChange()
    }

    func rotateOCRPreviewCounterClockwise() {
        ocrPreviewRotationOffsetDegrees = normalizedPreviewRotation(ocrPreviewRotationOffsetDegrees - 90)
        suppressMotionProtectionAfterCameraTransformChange()
    }

    func resetOCRPreviewRotation() {
        setOCRPreviewRotationDegrees(0)
    }

    func setOCRPreviewRotationDegrees(_ degrees: CGFloat) {
        ocrPreviewRotationOffsetDegrees = normalizedPreviewRotation(degrees)
        suppressMotionProtectionAfterCameraTransformChange()
        MainThreadStallMonitor.shared.markContext("calibration image orientation set: \(Int(ocrPreviewRotationOffsetDegrees))°")
    }

    func setCameraRotationLockEnabled(_ enabled: Bool) {
        cameraRotationLockEnabled = enabled
        suppressMotionProtectionAfterCameraTransformChange()
    }

    private func suppressMotionProtectionAfterCameraTransformChange() {
        ignoreOCRMotionProtectionUntil = CFAbsoluteTimeGetCurrent() + 1.5
        previousMotionHashes.removeAll()
        ocrMotionProtectionUntil = 0
        updateOCRMotionProtection(active: false, force: true)
    }

    private func normalizedPreviewRotation(_ degrees: CGFloat) -> CGFloat {
        let value = degrees.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }


    private func loadCameraRotationSettings() {
        isLoadingCameraRotationSettings = true
        let defaults = UserDefaults.standard

        // Recovery AE / RL-065: startup hydration writes directly to the
        // authoritative CameraControlStore. The public ViewModel setters mean
        // operator edit and may persist/dirty calibration; loading saved values
        // must not impersonate an edit.
        let rotationLock = defaults.object(forKey: "IceCast.cameraRotationLockEnabled") as? Bool ?? true
        let savedLiveRotation = defaults.object(forKey: "IceCast.livePreviewRotationOffsetDegrees") != nil
            ? CGFloat(defaults.double(forKey: "IceCast.livePreviewRotationOffsetDegrees"))
            : cameraControlStore.snapshot.livePreviewRotationOffsetDegrees
        let savedOCRRotation = defaults.object(forKey: "IceCast.ocrPreviewRotationOffsetDegrees") != nil
            ? CGFloat(defaults.double(forKey: "IceCast.ocrPreviewRotationOffsetDegrees"))
            : cameraControlStore.snapshot.ocrPreviewRotationOffsetDegrees

        cameraControlStore.setRotationLockEnabled(
            rotationLock,
            source: "HockeyScoreboardViewModel.loadCameraRotationSettings",
            reason: "Recovery AE saved camera rotation hydration"
        )
        cameraControlStore.setLivePreviewRotation(
            savedLiveRotation,
            source: "HockeyScoreboardViewModel.loadCameraRotationSettings",
            reason: "Recovery AE saved live rotation hydration"
        )
        cameraControlStore.setOCRPreviewRotation(
            savedOCRRotation,
            source: "HockeyScoreboardViewModel.loadCameraRotationSettings",
            reason: "Recovery AE saved OCR rotation hydration"
        )

        if !defaults.bool(forKey: "IceCast.UX12yLandscapeUprightRotationMigrationApplied") {
            if Int(cameraControlStore.snapshot.livePreviewRotationOffsetDegrees.rounded()) == 180 {
                cameraControlStore.setLivePreviewRotation(
                    0,
                    source: "HockeyScoreboardViewModel.loadCameraRotationSettings",
                    reason: "Recovery AE legacy landscape rotation migration"
                )
            }
            if Int(cameraControlStore.snapshot.ocrPreviewRotationOffsetDegrees.rounded()) == 180 {
                cameraControlStore.setOCRPreviewRotation(
                    0,
                    source: "HockeyScoreboardViewModel.loadCameraRotationSettings",
                    reason: "Recovery AE legacy OCR landscape rotation migration"
                )
            }
            defaults.set(true, forKey: "IceCast.UX12yLandscapeUprightRotationMigrationApplied")
        }
        isLoadingCameraRotationSettings = false
        // Persist only the final authoritative hydration result. This is not an
        // operator edit and deliberately does not touch CalibrationStore dirty state.
        persistCameraRotationSettingsIfReady()
    }

    private func persistCameraRotationSettingsIfReady() {
        guard !isLoadingCameraRotationSettings else { return }
        let defaults = UserDefaults.standard
        defaults.set(cameraRotationLockEnabled, forKey: "IceCast.cameraRotationLockEnabled")
        defaults.set(Double(livePreviewRotationOffsetDegrees), forKey: "IceCast.livePreviewRotationOffsetDegrees")
        defaults.set(Double(ocrPreviewRotationOffsetDegrees), forKey: "IceCast.ocrPreviewRotationOffsetDegrees")
    }

    private func loadCalibrationCameraProfileSettings() {
        isLoadingCalibrationCameraProfile = true
        defer { isLoadingCalibrationCameraProfile = false }
        guard let data = UserDefaults.standard.data(forKey: "IceCast.calibrationCameraProfile") else { return }
        if var decoded = try? JSONDecoder().decode(CalibrationCameraProfile.self, from: data) {
            decoded.profileMode = .manual
            decoded.manualCalibrationModeEnabled = true
            cameraControlStore.setCalibrationProfile(
                decoded,
                source: "HockeyScoreboardViewModel.loadCalibrationCameraProfileSettings",
                reason: "Recovery AE generic calibration camera profile hydration"
            )
            calibrationCameraProfileStatusText = "Manual calibration profile loaded."
        }
    }

    private func persistCalibrationCameraProfileIfReady() {
        guard !isLoadingCalibrationCameraProfile else { return }
        guard let data = try? JSONEncoder().encode(calibrationCameraProfile) else { return }
        UserDefaults.standard.set(data, forKey: "IceCast.calibrationCameraProfile")
    }

    private func loadOCRSmoothingSettings() {
        isLoadingOCRSmoothingSettings = true
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "IceCast.isPostOCRSmoothingEnabled") != nil {
            isPostOCRSmoothingEnabled = defaults.bool(forKey: "IceCast.isPostOCRSmoothingEnabled")
        }
        isLoadingOCRSmoothingSettings = false
    }

    private func persistOCRSmoothingSettingsIfReady() {
        guard !isLoadingOCRSmoothingSettings else { return }
        UserDefaults.standard.set(isPostOCRSmoothingEnabled, forKey: "IceCast.isPostOCRSmoothingEnabled")
    }

    func setPostOCRSmoothingEnabled(_ enabled: Bool) {
        guard isPostOCRSmoothingEnabled != enabled else { return }
        isPostOCRSmoothingEnabled = enabled
        ocrSmoothingEngine.reset()
        statusMessage = enabled
            ? "OCR smoothing enabled. Stable score/time changes will be protected."
            : "OCR smoothing disabled. Raw accepted OCR values will update immediately."
    }


    private func markImageRelayMetadataSuspended(reason: String) {
        if let last = imageRelayLastAcceptedSourceSequence {
            imageRelayMinimumSourceSequenceAfterResume = last + 1
        }
        imageRelayPenaltyResumeKnownIdentities = Set(imageRelayActivePenaltyByIdentity.keys)
        imageRelayPenaltyResumeProtectionUntil = CFAbsoluteTimeGetCurrent() + 8.0
        imageRelayBulkEmptyPenaltyCycleCount = 0
        RinkLensOCREvidenceJournal.shared.recordEventAudit(
            stage: "image_relay_metadata_suspended",
            eventKind: "capture",
            source: BroadcastEventSource.ocr.rawValue,
            detail: "reason=\(reason) identities=\(imageRelayPenaltyResumeKnownIdentities.sorted().joined(separator: ",")) minimumSequence=\(imageRelayMinimumSourceSequenceAfterResume.map { String($0) } ?? "none")"
        )
    }

    func beginImageRelayResumeProtection(reason: String) {
        imageRelayPenaltyResumeKnownIdentities = Set(imageRelayActivePenaltyByIdentity.keys)
        imageRelayPenaltyResumeProtectionUntil = CFAbsoluteTimeGetCurrent() + 8.0
        imageRelayBulkEmptyPenaltyCycleCount = 0
        RinkLensOCREvidenceJournal.shared.recordEventAudit(
            stage: "image_relay_resume_protection_started",
            eventKind: "capture",
            source: BroadcastEventSource.ocr.rawValue,
            detail: "reason=\(reason) retained=\(imageRelayPenaltyResumeKnownIdentities.sorted().joined(separator: ","))"
        )
    }

    func pauseOCRProcessing() {
        if RinkLensRiskFeaturePolicy.isEnabled(.transactionalImageRelayControlV23),
           operatingMode == .imageRelay {
            guard scoreboardInputLifecycleStore.operatorStop(
                source: "HockeyScoreboardViewModel.pauseOCRProcessing",
                reason: "Operator requested Image Relay stop"
            ) else { return }

            deferredOCRPromotionTask?.cancel()
            deferredOCRPromotionTask = nil
            deferredBroadcastPreviewRecoveryTask?.cancel()
            deferredBroadcastPreviewRecoveryTask = nil
            userWantsOCRRunning = false
            isOCRPaused = true
            stopSyntheticClock(reason: "Image Relay stopped")
            clearBoundedClockEvidence(reason: "Image Relay stopped")
            markImageRelayMetadataSuspended(reason: "Image Relay stopped")

            // Presentation is retained immediately. The potentially contended
            // processor reset waits off MainActor, so tapping Stop cannot block
            // SwiftUI behind an in-flight image-processing lock.
            ScoreboardImageRelayStore.shared.pauseProcessingPreservingPresentation(
                reason: "Image Relay stopped by operator; retained last valid physical presentation"
            )
            scoreboardInputLifecycleStore.markStopped(
                source: "HockeyScoreboardViewModel.pauseOCRProcessing",
                reason: "Presentation paused and operator stop committed"
            )
            statusMessage = "Image Relay stopped. Camera preview remains available."
            updateFrameDeliveryPolicy(force: true)

            let engine = imageRelayEngine
            imageRelayLifecycleWorkQueue.async {
                engine.suspendPreservingPenaltyState(reason: "Image Relay operator stop — asynchronous worker reset")
                RinkLensStructuredEventLogger.shared.record(
                    domain: .scoreboardInput,
                    event: "scoreboard_input_worker_reset_completed",
                    entityID: OperatingMode.imageRelay.rawValue,
                    previous: ["processing": "in-flight-or-idle"],
                    next: ["processing": "reset", "presentationRetained": "true"],
                    source: "ScoreboardImageRelayEngine",
                    reason: "Operator stop completed without blocking MainActor"
                )
            }
            return
        }

        scoreboardInputLifecycleStore.operatorStop(
            source: "HockeyScoreboardViewModel.pauseOCRProcessing",
            reason: "Operator stopped scoreboard input"
        )
        scoreboardInputLifecycleStore.markStopped(
            source: "HockeyScoreboardViewModel.pauseOCRProcessing",
            reason: "Legacy scoreboard input stop committed"
        )
        deferredOCRPromotionTask?.cancel()
        deferredOCRPromotionTask = nil
        deferredBroadcastPreviewRecoveryTask?.cancel()
        deferredBroadcastPreviewRecoveryTask = nil
        userWantsOCRRunning = false
        isOCRPaused = true
        stopSyntheticClock(reason: "OCR paused")
        clearBoundedClockEvidence(reason: "OCR paused")
        if operatingMode == .imageRelay {
            markImageRelayMetadataSuspended(reason: "Image Relay paused")
            imageRelayEngine.suspendPreservingPenaltyState(reason: "Image Relay paused")
            ScoreboardImageRelayStore.shared.pauseProcessingPreservingPresentation(reason: "Image Relay stopped by operator; retained last valid physical presentation")
            statusMessage = "Image Relay stopped."
        } else {
            statusMessage = "OCR stopped."
        }
        updateFrameDeliveryPolicy()
        // Recovery AH / RL-070: stopping Image Relay/OCR stops only consumer
        // processing. The physical OCR branch and FrameHub truth remain alive.
    }

    func resumeOCRProcessing() {
        if RinkLensRiskFeaturePolicy.isEnabled(.transactionalImageRelayControlV23),
           operatingMode == .imageRelay {
            guard scoreboardInputLifecycleStore.operatorStart(
                mode: operatingMode.rawValue,
                source: "HockeyScoreboardViewModel.resumeOCRProcessing",
                reason: "Operator requested Image Relay start"
            ) else { return }

            deferredOCRPromotionTask?.cancel()
            deferredOCRPromotionTask = nil
            userWantsOCRRunning = true
            isOCRPaused = false
            beginImageRelayResumeProtection(reason: "Image Relay start transaction")
            selectedRegionPreviewStatus = "Image Relay extracts the selected scoreboard field as an image; no characters are recognised."
            statusMessage = "Image Relay starting…"
            updateRegionDetectionStates(watchedByHashing: [], ocrScheduled: [], force: true)
            updateFrameDeliveryPolicy(force: true)

            let requestedRevision = scoreboardInputLifecycleStore.snapshot.revision
            let engine = imageRelayEngine
            imageRelayLifecycleWorkQueue.async { [weak self] in
                engine.suspendPreservingPenaltyState(reason: "Image Relay start — fresh-frame worker boundary")
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let lifecycle = self.scoreboardInputLifecycleStore.snapshot
                    guard lifecycle.revision == requestedRevision,
                          lifecycle.state == .starting,
                          lifecycle.operatorRequestedRunning else {
                        RinkLensStructuredEventLogger.shared.record(
                            domain: .scoreboardInput,
                            event: "scoreboard_input_start_abandoned",
                            entityID: OperatingMode.imageRelay.rawValue,
                            previous: ["requestedRevision": String(requestedRevision)],
                            next: ["currentRevision": String(lifecycle.revision), "state": lifecycle.state.rawValue],
                            source: "HockeyScoreboardViewModel",
                            reason: "A newer operator command superseded the pending start"
                        )
                        return
                    }
                    ScoreboardImageRelayStore.shared.activateProcessing(
                        reason: "Image Relay transactional start after fresh-frame boundary"
                    )
                    await self.ensureImageRelayCaptureActive(
                        reason: "Image Relay transactional start from OCR screen"
                    )
                }
            }
            return
        }

        scoreboardInputLifecycleStore.operatorStart(
            mode: operatingMode.rawValue,
            source: "HockeyScoreboardViewModel.resumeOCRProcessing",
            reason: "Operator started scoreboard input"
        )
        deferredOCRPromotionTask?.cancel()
        deferredOCRPromotionTask = nil
        userWantsOCRRunning = true
        isOCRPaused = false

        if operatingMode == .imageRelay {
            beginImageRelayResumeProtection(reason: "Image Relay resumed")
            ScoreboardImageRelayStore.shared.activateProcessing(reason: "Image Relay resumed")
            imageRelayEngine.suspendPreservingPenaltyState(reason: "Image Relay resumed with fresh-frame boundary")
            ScoreboardImageRelayStore.shared.activateProcessing(reason: "Image Relay waiting for fresh frame")
            selectedRegionPreviewStatus = "Image Relay extracts the selected scoreboard field as an image; no characters are recognised."
            statusMessage = "Image Relay starting scoreboard camera."
            updateRegionDetectionStates(watchedByHashing: [], ocrScheduled: [], force: true)
            updateFrameDeliveryPolicy(force: true)
            Task { @MainActor [weak self] in
                await self?.ensureImageRelayCaptureActive(
                    reason: "Image Relay resumed independently of OCR screen"
                )
            }
            return
        }

        RinkLensPhysicalAcceptanceMonitor.shared.beginSession(
            reason: "OCR resumed on \(currentScreen.rawValue)"
        )

        // Restart OCR in clock-bootstrap mode without discarding the live-event
        // hash baselines. Clock recognition establishes cadence immediately;
        // score, period and penalty zones remain cheap hash watches until an exact
        // changed region is admitted to bounded recognition.
        let now = CFAbsoluteTimeGetCurrent()
        lastOCRAt = now - max(activeOCRInterval, 1.0)
        lastClockOCRConfirmationAt = 0
        lastObservedClockOCRSeconds = nil
        repeatedClockOCRReadCount = 0
        clockStopCandidateStartedAt = nil
        lastClockMovementObservedAt = 0
        localClockIsRunning = false
        stoppedHashWatchWasActive = false
        stoppedWindowSafetyTransactionUntil.removeAll(keepingCapacity: true)
        scoreLastSafetyOCRAt.removeAll(keepingCapacity: true)
        penaltyPlayerLastSafetyOCRAt.removeAll(keepingCapacity: true)
        resetAutoClockDirectionTracking()
        if currentScreen == .calibration {
            // Build 556: opening the OCR screen is presentation-only. The exact
            // Build 551 production scheduler and event transactions continue.
            // Only an explicit Test OCR request is diagnostics-only.
            ocrStartupClockBootstrapActive = false
            gameEventDetector.reset()
            lastGameEventMode = .unknown
            statusMessage = "OCR running. Broadcast publication remains active while configuring zones."
            selectedRegionPreviewStatus = "Production OCR continues to update Broadcast; Test OCR reads the selected zone once without committing."
            updateRegionDetectionStates(watchedByHashing: [], ocrScheduled: Set(OCRRegionKey.productionOCRCases), force: true)
        } else {
            ocrStartupClockBootstrapActive = false
            gameEventDetector.reset()
            lastGameEventMode = .unknown
            selectedRegionPreviewStatus = "OCR started. Reading scores, period and penalty player numbers only."
            statusMessage = "OCR running. Reading scores, period and penalty player numbers only."
            updateRegionDetectionStates(watchedByHashing: [], ocrScheduled: Set(OCRRegionKey.productionOCRCases), force: true)
        }
        updateFrameDeliveryPolicy()
        if currentScreen == .broadcast, ocrCameraService.selectedCameraIsExternal {
            Task { @MainActor in
                _ = await self.activateExternalOCRMultiCamIfNeeded(reason: "OCR resumed on Broadcast")
            }
        }
    }

    func startOCRFromCalibration() {
        // Build 534: selected-zone recognition is reserved for the explicit Test
        // OCR action. Continuous Calibration OCR starts with fair all-field rotation.
        resumeOCRProcessing()
    }

    // v0.9.1w1: Broadcast is a valid OCR operating screen.
    // The calibration *editor* should not be visible on Broadcast, but the OCR
    // capture path must stay alive so the broadcast overlay can continue to be
    // driven by the physical scoreboard. This intentionally restores the
    // pre-suspension behaviour while keeping the live preview owned by Broadcast.
    func keepBroadcastOCRRunning(reason: String) {
        guard currentScreen == .broadcast else { return }
        guard userWantsOCRRunning else {
            MainThreadStallMonitor.shared.trace("Broadcast OCR keepalive skipped: OCR not requested reason=\(reason)")
            return
        }

        deferredOCRPromotionTask?.cancel()
        deferredOCRPromotionTask = nil
        broadcastOCRPromotionActive = true
        broadcastOCRPromotionBlockedUntil = 0
        isScreenTransitioning = false
        isOCRPaused = false
        ocrStartupClockBootstrapActive = false
        lastOCRAt = CFAbsoluteTimeGetCurrent() - max(activeOCRInterval, 0.75)
        updateFrameDeliveryPolicy(force: true)

        deferredCameraStartupTask?.cancel()
        deferredCameraStartupTask = Task { [weak self] in
            await self?.requestOCRCaptureForLiveIfStillNeeded()
        }

        MainThreadStallMonitor.shared.trace("Broadcast OCR keepalive active: \(reason)")
    }

// MARK: - UX16c23 MultiCam ownership state

    func prepareForExternalMultiCamActivation(reason: String) {
        deferredCameraStartupTask?.cancel()
        deferredCameraStartupTask = nil
        deferredBroadcastPreviewRecoveryTask?.cancel()
        deferredBroadcastPreviewRecoveryTask = nil
        broadcastOCRPromotionActive = false
        broadcastOCRPromotionBlockedUntil = 0
        isScreenTransitioning = false
        MainThreadStallMonitor.shared.traceCameraStartupTimeline("UX16c23 ViewModel preparing MultiCam: \(reason)")
    }

    func completeExternalMultiCamActivation(started: Bool, status: String) {
        if started {
            broadcastOCRPromotionActive = true
            broadcastOCRPromotionBlockedUntil = 0
            isScreenTransitioning = false
            isOCRPaused = false
            resetOCRMotionProtectionAfterCameraOwnershipChange(reason: "UX16c23 MultiCam activated")
            lastOCRAt = CFAbsoluteTimeGetCurrent() - max(activeOCRInterval, 0.75)
            updateFrameDeliveryPolicy(force: true)
            statusMessage = nil
        } else {
            broadcastOCRPromotionActive = false
            broadcastOCRPromotionBlockedUntil = CFAbsoluteTimeGetCurrent() + 3.0
            isOCRPaused = true
            statusMessage = status.isEmpty ? "OCR unavailable; Broadcast camera retained." : status
            updateFrameDeliveryPolicy(force: true)
        }
    }

    func startBroadcastLiveCameraAfterExternalMultiCamRelease() async {
        guard currentScreen == .broadcast else { return }
        let mode = desiredCaptureMode(for: .live)
        let outcome = await captureLifecycleController.ensure(
            captureRequest(
                for: mode,
                reason: "CaptureEngine authoritative Broadcast recovery after graph release"
            )
        )
        applyCaptureLifecycleOutcome(outcome)
    }

    func resetOCRMotionProtectionAfterCameraOwnershipChange(reason: String) {
        ocrMotionProtectionUntil = 0
        ignoreOCRMotionProtectionUntil = CFAbsoluteTimeGetCurrent() + 3.0
        previousMotionHashes.removeAll()
        ocrMotionProtectionActive = false
        ocrMotionProtectionStatusText = "OCR camera ownership changed; motion protection reset: \(reason)"
        lastOCRMotionProtectionPublishAt = CFAbsoluteTimeGetCurrent()
        MainThreadStallMonitor.shared.traceOCRPhase("UX16c23 OCR motion protection reset: \(reason)")
    }

    func stopOCRFromCalibration() {
        pauseOCRProcessing()
    }

    func resetOCRFromCalibration() {
        pauseOCRProcessing()
        ocrProcessingGeneration += 1
        isProcessing = false
        ocrOrchestrationEngine.reset(reason: "Calibration OCR reset")
        droppedOCRFrameCount = 0
        lastRawOCRText = nil
        debugHistory.removeAll()
        latestOCRCandidateState = ScoreboardState()
        regionOCRPreview.removeAll()
        regionOCRRecognizer.removeAll()
        regionLikelyLabels.removeAll()
        selectedRegionRawPreviewImage = nil
        selectedRegionProcessedPreviewImage = nil
        selectedRegionThresholdedPreviewImage = nil
            selectedRegionSegmentPreviewImage = nil
        selectedRegionPreviewStatus = "OCR reset. Press Start OCR to resume."
        ocrFieldConfidence.removeAll()
        ocrTrustSummary = OCRTrustSummary()
        ocrSmoothingEngine.reset()
        gameEventDetector.reset()
        lastGameEventMode = .unknown
        previousMotionHashes.removeAll()
        regionDetectionStates = Dictionary(uniqueKeysWithValues: OCRRegionKey.calibrationCases.map { ($0, .none) })
        isPixelHashingActive = false
        ocrPixelHashingStatusText = "Pixel hashing inactive"
        stopSyntheticClock(reason: "OCR reset")
        clearPublishedScoreboardForOCRReset()
        statusMessage = "OCR reset, stopped and public scoreboard cleared."
        updateFrameDeliveryPolicy()
    }

    // v0.7.7.7: OCR Reset must clear the public scoreboard values too.
    // Earlier reset only cleared OCR buffers/trust/history, so Live, Overlay and
    // Broadcast could continue showing the last published clock/score/period.
    private func clearPublishedScoreboardForOCRReset() {
        let preservedHomeTeam = state.homeTeam
        let preservedAwayTeam = state.awayTeam

        reduceMatchState(
            .replace(
                ScoreboardState(
                    homeTeam: preservedHomeTeam,
                    awayTeam: preservedAwayTeam,
                    homeScore: 0,
                    awayScore: 0,
                    clock: nil,
                    period: 1,
                    periodLabel: "1",
                    homeShots: nil,
                    awayShots: nil,
                    homePenalty1Player: nil,
                    homePenalty1Clock: nil,
                    homePenalty2Player: nil,
                    homePenalty2Clock: nil,
                    awayPenalty1Player: nil,
                    awayPenalty1Clock: nil,
                    awayPenalty2Player: nil,
                    awayPenalty2Clock: nil
                ),
                context: RinkLensMatchStateContext(
                    origin: .reset,
                    reason: "OCR reset cleared published scoreboard"
                )
            )
        )

        // Keep Manual Mode and OCR Mode visually consistent after reset.
        // OverlayState uses these override values whenever Manual Mode is active.
        overrideHomeScore = 0
        overrideAwayScore = 0
        overridePeriod = 1
        defaultPeriodOption = "1"
        defaultPeriod = 1

        clearBroadcastTimeline()
    }

    var operatingMode: OperatingMode {
        get { OperatingMode(rawValue: scoreboardInputLifecycleStore.snapshot.mode) ?? .imageRelay }
        set { setOperatingMode(newValue) }
    }

    var controlMode: OverlayControlMode {
        get { operatingMode }
        set { setOperatingMode(newValue) }
    }

    /// Compatibility name retained by Broadcast views. Image Relay also needs
    /// the full clock/score/period/penalty scorebug rather than Manual's pruned UI.
    var isOCRMode: Bool { operatingMode != .manual }
    var isImageRelayMode: Bool { operatingMode == .imageRelay }
    var isManualMode: Bool { operatingMode == .manual }
    var operatingModeStatusText: String {
        switch operatingMode {
        case .ocr, .imageRelay:
            return imageRelayStatusText
        case .manual:
            return operatingMode.broadcastStatusText
        }
    }

    var isOCRPausedByUser: Bool {
        get { isOCRPaused }
        set { newValue ? pauseOCRProcessing() : resumeOCRProcessing() }
    }


    func beginTransitionPublishFreeze(reason: String) {
        transitionPublishFreezeDepth += 1
        pendingFramePolicyRefreshAfterFreeze = false
        MainThreadStallMonitor.shared.trace("transition publish freeze begin: \(reason)")
    }

    func endTransitionPublishFreeze(reason: String) {
        transitionPublishFreezeDepth = max(0, transitionPublishFreezeDepth - 1)
        MainThreadStallMonitor.shared.trace("transition publish freeze end: \(reason)")
        guard transitionPublishFreezeDepth == 0 else { return }
        if pendingFramePolicyRefreshAfterFreeze {
            pendingFramePolicyRefreshAfterFreeze = false
            MainThreadStallMonitor.shared.trace("swiftui invalidation suppressed: applying coalesced frame policy")
            updateFrameDeliveryPolicy(force: true)
        }
    }

    private var isTransitionPublishFrozen: Bool { transitionPublishFreezeDepth > 0 }

    private var activeNextGenLifecycleRoute: AppRoute?
    private(set) var routeLifecycleActivationCount: Int = 0
    private(set) var duplicateRouteLifecycleSuppressionCount: Int = 0
    private(set) var routeHealthObservationCount: Int = 0

    private var nextGenBroadcastPreviewRequiredForActiveRoute = false
    private var broadcastPreviewRecoveryTaskInFlight = false
    private var broadcastPreviewRecoveryLastAttemptAt: CFAbsoluteTime = 0
    private var broadcastPreviewRecoveryBlockedUntil: CFAbsoluteTime = 0
    private var broadcastPreviewRecoveryConsecutiveFailures = 0
    private var broadcastPreviewRecoveryLastSuppressedLogAt: CFAbsoluteTime = 0

    private func recordNonCameraPresentation(reason: String) {
        // Route is presentation state, not scoreboard-input authority. The prior
        // branch changed an operator-requested running Relay into suspendedByRoute
        // merely because Command Centre/Settings became visible. That produced the
        // exported "Waiting for Frame — Non-camera thermal idle" contradiction and
        // forced a cold processing restart on every return to Broadcast.
        //
        // Keep capture and Relay processing exactly as their owners requested. The
        // hidden Broadcast compositor is independently unmounted by BroadcastView,
        // so preserving Relay truth does not retain hidden SwiftUI/render work.
        cancelDeferredBroadcastPreviewWork(reason: "Broadcast presentation hidden")
        RinkLensStructuredEventLogger.shared.record(
            domain: .scoreboardInput,
            event: "scoreboard_input_preserved_across_route",
            entityID: operatingMode.rawValue,
            previous: [
                "route": "operational",
                "operatorRequestedRunning": String(scoreboardInputLifecycleStore.snapshot.operatorRequestedRunning),
                "processingPaused": String(scoreboardInputLifecycleStore.snapshot.processingPaused)
            ],
            next: [
                "route": activeNextGenLifecycleRoute?.title ?? "non-camera",
                "captureMutation": "none",
                "processingMutation": "none"
            ],
            source: "HockeyScoreboardViewModel.recordNonCameraPresentation",
            reason: reason,
            authoritativeOwner: "RinkLensScoreboardInputLifecycleStore"
        )
        MainThreadStallMonitor.shared.traceCameraStartupTimeline(
            RinkLensBuildInfo.traceContext("non-camera route changed presentation only; Image Relay ownership preserved: \(reason)")
        )
    }

    /// UX16c46 authoritative route entry. Shell views no longer assert capture
    /// independently; this method is invoked once by RootRouterView's route task.
    func presentNextGenRoute(_ route: AppRoute, reason: String) async {
        // Discovery is read-only topology projection. It belongs to the camera
        // services and is safe during configuration-only routes; CaptureEngine
        // remains stopped until an operational route requests a graph.
        if route == .commandCentre || route == .cameraSetup || route == .settings {
            preloadConfigurationCameraDiscoveryIfNeeded(reason: "configuration route: \(route.title)")
        }
        guard activeNextGenLifecycleRoute != route else {
            duplicateRouteLifecycleSuppressionCount &+= 1
            return
        }
        let previousRoute = activeNextGenLifecycleRoute
        activeNextGenLifecycleRoute = route
        routeLifecycleActivationCount &+= 1
        if previousRoute == .broadcast, route != .broadcast {
            pauseUnifiedOverlayForHiddenBroadcastRoute(reason: "route changed to \(route.title)")
        }
        setNextGenPreviewRouteGate(activeRoute: route, reason: reason)

        // Build 716: AppCoordinator owns visible route and the one recording
        // route-loss decision. This ViewModel owns only scoreboard capture/OCR
        // presentation for the already-authorised route.

        switch route {
        case .commandCentre:
            recordNonCameraPresentation(reason: reason)
            // Recovery AP / RL-092: initial Command Centre is a configuration
            // lifetime, not an implicit live-match lifetime. CaptureEngine starts
            // only when an operational camera route (Broadcast/OCR Setup) asks for
            // it. Once started, later route changes may preserve that match graph.
            if !hasStartedAppServices {
                MainThreadStallMonitor.shared.traceCameraStartupTimeline(
                    RinkLensBuildInfo.traceContext("Recovery AP Command Centre configuration idle — live capture not started")
                )
            }
        case .broadcast:
            // R20 preview-first: release route ownership without starting Image Relay
            // processing. Capture/preview gets the first usable frame before the
            // scoreboard GPU/CPU lane is admitted.
            prepareNextGenBroadcastRoute(reason: reason)
            resumeUnifiedOverlayForVisibleBroadcastRoute(reason: reason)
            await start()
        case .ocrSetup:
            prepareNextGenOCRSetupRoute(reason: reason)
            await start()
        case .recording:
            break
        case .sponsors, .media, .streamSetup, .diagnostics, .cameraSetup, .settings:
            // Recovery AW / RL-108: direct navigation to any non-camera surface
            // must establish processing idle even when the preceding Command Centre
            // callback was skipped/coalesced. Capture graph retention is independent.
            recordNonCameraPresentation(reason: "non-camera route \(route.title): \(reason)")
        }

        let capture = externalOCRMultiCamCoordinator.snapshot
        let routeKind: RinkLensCapturePresentationRoute
        switch route {
        case .commandCentre: routeKind = .commandCentre
        case .broadcast: routeKind = .broadcast
        case .ocrSetup: routeKind = .ocrSetup
        case .recording: routeKind = .recording
        default: routeKind = .nonCamera
        }
        let liveIdentity = liveCameraService.captureIdentitySnapshot()
        let ocrIdentity = ocrCameraService.captureIdentitySnapshot()
        // Recovery AH / RL-070: visible route is presentation-only. It may
        // change consumer admission through updateFrameDeliveryPolicy(), but it
        // cannot enable/disable an AVCaptureConnection or clear physical OCR truth.

        let action = RinkLensCapturePresentationPolicy.action(
            for: .init(
                route: routeKind,
                captureIsActive: capture.isActive,
                captureIsTransitioning: capture.isTransitioning,
                activeMode: capture.activeMode,
                recordingSessionOpen: BroadcastRecordingManager.shared.hasRetainedRecordingSession,
                wantsScoreboardCameraGraph: usesScoreboardCameraInput,
                hasBroadcastSelection: liveIdentity.preferredResolvedPhysicalDeviceID != nil,
                hasOCRSelection: ocrIdentity.preferredResolvedPhysicalDeviceID != nil
            )
        )

        switch action {
        case .preserveCurrent:
            captureLifecycleController.notePresentationOnlyRouteChange(
                "route=\(route.title) active=\(capture.activeMode.rawValue) recording=\(RinkLensRecordingCaptureLease.shared.isRecordingActive())"
            )
            RinkLensStructuredEventLogger.shared.record(
                domain: .capture,
                event: "route_capture_contract_preserved",
                entityID: route.rawValue,
                previous: [
                    "activeMode": capture.activeMode.rawValue,
                    "generation": String(capture.transitionGeneration),
                    "sessionRunning": String(capture.sessionRunning)
                ],
                next: [
                    "activeMode": capture.activeMode.rawValue,
                    "generation": String(capture.transitionGeneration),
                    "mutation": "none"
                ],
                source: "HockeyScoreboardViewModel.presentNextGenRoute",
                reason: reason,
                captureGeneration: capture.transitionGeneration
            )
        case .ensure(let mode):
            let request = captureRequest(
                for: mode,
                reason: "UX16d2 operational route presentation: \(route.title)"
            )
            RinkLensStructuredEventLogger.shared.record(
                domain: .capture,
                event: "route_capture_reconciliation_requested",
                entityID: route.rawValue,
                previous: [
                    "activeMode": capture.activeMode.rawValue,
                    "generation": String(capture.transitionGeneration),
                    "sessionRunning": String(capture.sessionRunning)
                ],
                next: [
                    "requestedMode": mode.rawValue,
                    "broadcastDevice": request.liveDeviceID ?? "none",
                    "ocrDevice": request.ocrDeviceID ?? "none"
                ],
                source: "HockeyScoreboardViewModel.presentNextGenRoute",
                reason: request.reason,
                captureGeneration: capture.transitionGeneration
            )
            let outcome = await captureLifecycleController.ensure(request)
            applyCaptureLifecycleOutcome(outcome)
            let resolvedCapture = externalOCRMultiCamCoordinator.snapshot
            RinkLensStructuredEventLogger.shared.record(
                domain: .capture,
                event: "route_capture_reconciliation_completed",
                entityID: route.rawValue,
                previous: [
                    "requestedMode": mode.rawValue,
                    "generation": String(capture.transitionGeneration)
                ],
                next: [
                    "resolvedMode": outcome.resolvedMode.rawValue,
                    "succeeded": String(outcome.succeeded),
                    "usedFallback": String(outcome.usedFallback),
                    "generation": String(resolvedCapture.transitionGeneration),
                    "broadcastDevice": resolvedCapture.liveDeviceID ?? "none",
                    "ocrDevice": resolvedCapture.ocrDeviceID ?? "none"
                ],
                source: "HockeyScoreboardViewModel.presentNextGenRoute",
                reason: outcome.statusText,
                captureGeneration: resolvedCapture.transitionGeneration
            )
        }

        if route == .broadcast, operatingMode == .imageRelay,
           scoreboardInputLifecycleStore.snapshot.operatorRequestedRunning,
           activeNextGenLifecycleRoute == .broadcast {
            let previewCapture = externalOCRMultiCamCoordinator.snapshot
            if previewCapture.sessionRunning,
               let deviceID = previewCapture.liveDeviceID,
               let frame = await RinkLensFrameHub.shared.waitForFreshFrameEvidence(
                    for: .broadcast,
                    maxAge: 0.35,
                    requiredCaptureGeneration: previewCapture.transitionGeneration,
                    requiredPhysicalDeviceID: deviceID,
                    timeout: 1.0
               ), frame.captureGeneration == previewCapture.transitionGeneration {
                beginImageRelayResumeProtection(reason: "R20 Broadcast preview-first frame verified")
                imageRelayEngine.suspendPreservingPenaltyState(reason: "R20 Broadcast preview-first handoff")
                ScoreboardImageRelayStore.shared.activateProcessing(reason: "R20 Broadcast preview-first frame verified")
                updateFrameDeliveryPolicy(force: true)
                RinkLensStructuredEventLogger.shared.record(
                    domain: .scoreboardPresentation,
                    event: "broadcast_preview_first_scoreboard_processing_admitted",
                    entityID: deviceID,
                    previous: ["processing": "deferred", "frame": "none"],
                    next: ["processing": "active", "frame": String(frame.sequence)],
                    source: "HockeyScoreboardViewModel.presentNextGenRoute",
                    reason: "R20 admits Image Relay only after a current-generation Broadcast frame is usable",
                    captureGeneration: frame.captureGeneration,
                    authoritativeOwner: "ScoreboardImageRelayEngine"
                )
            }
        }

        if route == .broadcast, operatingMode == .imageRelay,
           scoreboardInputLifecycleStore.snapshot.operatorRequestedRunning {
            let resolvedCapture = externalOCRMultiCamCoordinator.snapshot
            let scoreboardBranchActive = resolvedCapture.isActive
                && resolvedCapture.sessionRunning
                && resolvedCapture.activeMode.requiresOCR
            if scoreboardBranchActive {
                scoreboardInputLifecycleStore.markRunning(
                    source: "HockeyScoreboardViewModel.presentNextGenRoute",
                    reason: "Build 774 single Broadcast route capture ensure completed"
                )
            } else {
                if RinkLensRecordingCaptureLease.shared.isWriterContractOpen() {
                    scoreboardInputLifecycleStore.waitForCapture(
                        source: "HockeyScoreboardViewModel.presentNextGenRoute",
                        reason: "OCR restoration is physically deferred until the RecordingWriter contract closes"
                    )
                } else {
                    scoreboardInputLifecycleStore.fail(
                        "scoreboard camera branch not configured",
                        source: "HockeyScoreboardViewModel.presentNextGenRoute",
                        reason: "Build 774 Broadcast route capture ensure did not produce OCR branch"
                    )
                }
            }
        }
    }

    /// UX16d2c recording-lease release always recomputes the current route's
    /// authoritative contract. A deferred OCR Setup request is historical intent
    /// and must never be replayed after the operator has returned to Broadcast.
    private func reconcileCaptureAfterRecordingLeaseRelease(reason: String) async {
        guard !appBackgroundCaptureSuspended else {
            _ = captureLifecycleController.discardDeferredRecordingLeaseRequest(
                reason: "Build 677 background-suspended recording lease release: \(reason)"
            )
            MainThreadStallMonitor.shared.traceCameraStartupTimeline(
                RinkLensBuildInfo.traceContext("capture restart deferred while app backgrounded after recording lease release")
            )
            return
        }
        let discarded = captureLifecycleController.discardDeferredRecordingLeaseRequest(
            reason: "recording lease released: \(reason)"
        )
        let mode: RinkLensCaptureLifecycleMode
        switch activeNextGenLifecycleRoute {
        case .some(.broadcast):
            mode = desiredCaptureMode(for: .live)
        case .some(.ocrSetup):
            mode = desiredCaptureMode(for: .ocr)
        case .some(.commandCentre):
            mode = desiredCaptureMode(for: .live)
        case .some(.recording):
            mode = desiredCaptureMode(for: .live)
        case .some(.sponsors), .some(.media), .some(.streamSetup), .some(.diagnostics),
             .some(.cameraSetup), .some(.settings):
            let active = externalOCRMultiCamCoordinator.activeModeSnapshot
            mode = active == .stopped ? desiredCaptureMode(for: cameraRole(for: currentScreen)) : active
        case .none:
            mode = desiredCaptureMode(for: cameraRole(for: currentScreen))
        }
        let currentRouteRequest = captureRequest(
            for: mode,
            reason: "UX16d2c current-route recompute after recording lease release: screen=\(currentScreen.rawValue) route=\(activeNextGenLifecycleRoute?.title ?? "legacy") reason=\(reason)"
        )
        let request = RinkLensRecordingLeaseReleasePolicy.resolvedRequest(
            currentRouteRequest: currentRouteRequest,
            discardedDeferredRequest: discarded
        )
        MainThreadStallMonitor.shared.traceCameraStartupTimeline(
            RinkLensBuildInfo.traceContext("UX16d2c lease release recomputed current route mode=\(mode.rawValue) screen=\(currentScreen.rawValue)")
        )
        let outcome = await captureLifecycleController.ensure(request)
        applyCaptureLifecycleOutcome(outcome)

        // Recovery B: the earlier lease-release replay can occur while the writer
        // contract is still open. On the actual writer-close notification, re-read
        // CameraControlStore's authoritative quality policy and reconcile it once.
        // No deferred FPS mirror or compatibility setting is retained.
        if reason.hasPrefix("writer contract closed:"), mode.requiresBroadcast {
            let policy = cameraControlStore.snapshot.broadcastImageQualityPolicy
            _ = await captureLifecycleController.applyBroadcastImageQualityPolicyFromOwner(
                policy,
                previousPolicy: policy,
                source: "Recovery B writer-close policy replay",
                reason: reason
            )
        }
    }

    /// Periodic route health sampling. This is observational while the graph is
    /// healthy and requests reconciliation only after sustained divergence.
    func observeNextGenRouteHealth(_ route: AppRoute, reason: String) async {
        guard !appBackgroundCaptureSuspended else {
            MainThreadStallMonitor.shared.traceCameraStartupTimeline(
                RinkLensBuildInfo.traceContext("route health capture reconciliation deferred while backgrounded route=\(route.title)")
            )
            return
        }
        guard activeNextGenLifecycleRoute == route else { return }
        let mode: RinkLensCaptureLifecycleMode
        switch route {
        case .broadcast:
            mode = desiredCaptureMode(for: .live)
        case .ocrSetup:
            mode = RinkLensRecordingCaptureLease.shared.isRecordingActive()
                ? (captureLifecycleController.desiredModeSnapshot ?? externalOCRMultiCamCoordinator.activeModeSnapshot)
                : desiredCaptureMode(for: .ocr)
        case .recording:
            mode = desiredCaptureMode(for: .live)
        case .commandCentre:
            return
        default:
            guard let preserved = captureLifecycleController.desiredModeSnapshot,
                  preserved != .stopped else { return }
            mode = preserved
        }
        routeHealthObservationCount &+= 1
        let request = captureRequest(for: mode, reason: reason)
        let health = await externalOCRMultiCamCoordinator.captureHealthSnapshot(maximumFrameAge: 1.5)
        if let outcome = await captureLifecycleController.reconcileAfterSustainedHealthDivergence(
            request,
            health: health
        ) {
            applyCaptureLifecycleOutcome(outcome)
            if outcome.statusText.localizedCaseInsensitiveContains("OCR") {
                resetOCRMotionProtectionAfterCameraOwnershipChange(
                    reason: "UX16d2d branch-health reconciliation: \(outcome.statusText)"
                )
            }
        }
    }

    /// RNG-S11H: Command Centre route gate for Broadcast preview recovery.
    ///
    /// `currentScreen` can intentionally remain `.broadcast` so the operator state is
    /// preserved when leaving the Broadcast tile. Therefore background preview recovery
    /// must be controlled by the active NextGen route, not by `currentScreen` alone.
    func setNextGenPreviewRouteGate(activeRoute: AppRoute, reason: String) {
        let broadcastRequired = activeRoute == .broadcast
        let ocrSetupRequired = activeRoute == .ocrSetup
        let multiCamPresent = externalOCRMultiCamCoordinator.isCaptureActiveSnapshot
            || externalOCRMultiCamCoordinator.isTransitioningSnapshot
        let multiCamPlanned = multiCamPresent
            || ((broadcastRequired || ocrSetupRequired)
                && externalOCRMultiCamPairEligible
                && !externalOCRMultiCamCoordinator.isFailureLatchedSnapshot)
        nextGenBroadcastPreviewRequiredForActiveRoute = broadcastRequired

        // UX16c46: presentation state only. Capture start/stop/reconciliation is
        // owned by presentNextGenRoute and its single presentation task.
        liveCameraService.setPreviewRequiredForActiveRoute(
            broadcastRequired && !multiCamPlanned,
            reason: "\(reason) live preview route gate"
        )
        ocrCameraService.setPreviewRequiredForActiveRoute(
            (ocrSetupRequired && !multiCamPlanned)
                || (broadcastRequired && broadcastOnlyCaptureActive && !multiCamPlanned),
            reason: "\(reason) OCR preview route gate"
        )

        if !broadcastRequired {
            cancelDeferredBroadcastPreviewWork(reason: "route presentation changed to \(activeRoute.title)")
        }
        if ocrSetupRequired {
            broadcastOCRPromotionActive = multiCamPresent
            broadcastOCRPromotionBlockedUntil = 0
        } else if !broadcastRequired && !(usesScoreboardCameraInput && userWantsOCRRunning) {
            broadcastOCRPromotionActive = false
            broadcastOCRPromotionBlockedUntil = CFAbsoluteTimeGetCurrent() + 3.0
        }
        broadcastPreviewRecoveryTaskInFlight = false
        broadcastPreviewRecoveryBlockedUntil = 0
        broadcastPreviewRecoveryConsecutiveFailures = 0
        isScreenTransitioning = false
        updateFrameDeliveryPolicy(force: true)
    }

    private var isBroadcastPreviewRecoveryAllowedForActiveRoute: Bool {
        nextGenBroadcastPreviewRequiredForActiveRoute
    }

    private func cancelDeferredBroadcastPreviewWork(reason: String) {
        deferredOCRPromotionTask?.cancel()
        deferredOCRPromotionTask = nil
        deferredBroadcastPreviewRecoveryTask?.cancel()
        deferredBroadcastPreviewRecoveryTask = nil
        deferredOCRPromotionGeneration += 1
        MainThreadStallMonitor.shared.trace(RinkLensBuildInfo.traceContext("deferred Broadcast preview/OCR work cancelled: \(reason)"))
    }

    func beginScreenTransition() {
        isScreenTransitioning = true
        stopSyntheticClock(reason: "screen transition")
        updateFrameDeliveryPolicy()
    }

    func endScreenTransition() {
        isScreenTransitioning = false
        updateFrameDeliveryPolicy()
    }

    /// RNG-S11H: lightweight Command Centre -> Broadcast entry path.
    ///
    /// The older `setScreen(.broadcast)` path schedules a 120ms delayed resume
    /// that can promote OCR and camera priority while SwiftUI is still mounting
    /// the live preview. Device logs showed this could produce a long MainActor
    /// stall on Broadcast entry. The NextGen Broadcast route only needs to mark
    /// Broadcast as visible, keep the live preview pinned, and defer OCR promotion
    /// until after the preview has settled.
    func prepareNextGenBroadcastRoute(reason: String) {
        let monitor = MainThreadStallMonitor.shared
        let started = monitor.beginTimedOperation("ViewModel.prepareNextGenBroadcastRoute")
        monitor.markContext("ViewModel.prepareNextGenBroadcastRoute enter: reason=\(reason)")

        cancelDeferredBroadcastPreviewWork(reason: "UX16c46 Broadcast route state commit")
        broadcastOCRPromotionActive = usesScoreboardCameraInput && userWantsOCRRunning
        broadcastOCRPromotionBlockedUntil = 0
        isOCRDiagnosticsVisible = false
        isScreenTransitioning = false
        isOCRPaused = !(usesScoreboardCameraInput && userWantsOCRRunning)

        if currentScreen != .broadcast {
            currentScreen = .broadcast
            lastOCRFieldCheckAt.removeAll()
            monitor.trace(RinkLensBuildInfo.traceContext("route-scoped state assigned: Broadcast"))
        }
        updateFrameDeliveryPolicy(force: true)
        monitor.endTimedOperation("ViewModel.prepareNextGenBroadcastRoute", startedAt: started)
    }

    private func prepareNextGenOCRSetupRoute(reason: String) {
        let monitor = MainThreadStallMonitor.shared
        let started = monitor.beginTimedOperation("ViewModel.prepareNextGenOCRSetupRoute")
        monitor.markContext("ViewModel.prepareNextGenOCRSetupRoute enter: reason=\(reason)")

        cancelDeferredBroadcastPreviewWork(reason: "UX16c46 OCR route state commit")
        currentScreen = .calibration
        isScreenTransitioning = false
        isOCRPaused = !(usesScoreboardCameraInput && userWantsOCRRunning)
        isOCRDiagnosticsVisible = true
        ocrCameraService.setDiagnosticsPublishingVisible(true)
        lastOCRFieldCheckAt.removeAll()
        updateFrameDeliveryPolicy(force: true)
        monitor.endTimedOperation("ViewModel.prepareNextGenOCRSetupRoute", startedAt: started)
    }

    private func scheduleDeferredBroadcastPreviewRecovery(reason: String) {
        deferredBroadcastPreviewRecoveryTask?.cancel()
        deferredBroadcastPreviewRecoveryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            await MainActor.run {
                guard let self else { return }
                guard self.currentScreen == .broadcast || self.currentScreen == .live else {
                    MainThreadStallMonitor.shared.traceCameraStartupTimeline("deferred broadcast preview recovery cancelled: left Broadcast reason=\(reason)")
                    return
                }
                guard self.isBroadcastPreviewRecoveryAllowedForActiveRoute else {
                    MainThreadStallMonitor.shared.traceCameraStartupTimeline("deferred broadcast preview recovery cancelled: active route no longer requires Broadcast reason=\(reason)")
                    return
                }
                MainThreadStallMonitor.shared.traceCameraStartupTimeline("deferred broadcast preview health observation reason=\(reason)")
                self.keepBroadcastPreviewAlive(reason: "deferred \(reason)")
            }
        }
    }


    /// SwiftUI `.inactive` is a temporary foreground UI pause (for example a
    /// share sheet or system overlay). It must not tear down the camera graph or
    /// clear the retained capture contract. AVFoundation interruption callbacks
    /// remain the authority for actual camera interruption.
    func handleAppBecameInactive(reason: String) {
        appTemporarilyInactive = true
        deferredCameraStartupTask?.cancel()
        deferredCameraStartupTask = nil
        deferredOCRPromotionTask?.cancel()
        deferredOCRPromotionTask = nil
        deferredBroadcastPreviewRecoveryTask?.cancel()
        deferredBroadcastPreviewRecoveryTask = nil
        MainThreadStallMonitor.shared.trace(
            "app lifecycle temporary inactive retained CaptureEngine reason=\(reason) mode=\(externalOCRMultiCamCoordinator.activeModeSnapshot.rawValue)"
        )
    }

    /// Background is a real application suspension boundary. Preserve selected
    /// logical/preferred camera identity, but stop runtime capture cleanly.
    func handleAppWillSuspend(reason: String) {
        appTemporarilyInactive = false
        appBackgroundCaptureSuspended = true
        MainThreadStallMonitor.shared.trace("app lifecycle background suspend requested: \(reason) screen=\(currentScreen.rawValue) ocrWanted=\(userWantsOCRRunning) paused=\(isOCRPaused)")
        appSuspendedWithOCRWanted = userWantsOCRRunning && !isOCRPaused
        appSuspendedScreen = currentScreen
        deferredCameraStartupTask?.cancel()
        deferredCameraStartupTask = nil
        deferredOCRPromotionTask?.cancel()
        deferredOCRPromotionTask = nil
        deferredBroadcastPreviewRecoveryTask?.cancel()
        deferredBroadcastPreviewRecoveryTask = nil
        isScreenTransitioning = false
        isOCRPaused = true
        if BroadcastRecordingManager.shared.isRecording || BroadcastRecordingManager.shared.isPaused {
            MainThreadStallMonitor.shared.trace("UX16c45 background boundary stopping active recording before capture teardown")
            if RinkLensRiskFeaturePolicy.isEnabled(.typedRecordingStopOriginV23) {
                BroadcastRecordingManager.shared.stopRecording(reason: .appBackground)
            } else {
                BroadcastRecordingManager.shared.stopRecording(origin: "app background")
            }
        }
        updateFrameDeliveryPolicy(force: true)
        captureLifecycleController.enqueueAppBackgroundSuspend(
            reason: reason
        ) { [weak self] outcome in
            self?.applyCaptureLifecycleOutcome(outcome)
        }
    }

    func handleAppDidBecomeActive(reason: String) {
        if appTemporarilyInactive, appSuspendedScreen == nil {
            appTemporarilyInactive = false
            MainThreadStallMonitor.shared.trace(
                "app lifecycle active after temporary inactive; CaptureEngine retained reason=\(reason) mode=\(externalOCRMultiCamCoordinator.activeModeSnapshot.rawValue)"
            )
            updateFrameDeliveryPolicy(force: true)
            return
        }

        appTemporarilyInactive = false
        let hadAppSuspend = appSuspendedScreen != nil || appSuspendedWithOCRWanted
        // Recovery T keeps the background-suspended gate closed until the
        // controller-owned wake transaction completes. Route/health work cannot
        // overtake the ordered stop -> wake camera boundary.
        MainThreadStallMonitor.shared.trace("app lifecycle active recovery requested: \(reason) screen=\(currentScreen.rawValue) previous=\(appSuspendedScreen?.rawValue ?? "none") ocrWanted=\(userWantsOCRRunning) resume=\(appSuspendedWithOCRWanted)")
        guard hadAppSuspend else {
            MainThreadStallMonitor.shared.trace("app lifecycle active recovery no-op: no prior background suspend state")
            return
        }

        isScreenTransitioning = false
        let shouldResumeOCR = usesScoreboardCameraInput && (userWantsOCRRunning || appSuspendedWithOCRWanted)
        appSuspendedWithOCRWanted = false
        if shouldResumeOCR {
            userWantsOCRRunning = true
            isOCRPaused = false
            ocrStartupClockBootstrapActive = false
            lastOCRAt = CFAbsoluteTimeGetCurrent() - max(activeOCRInterval, 0.75)
            updateRegionDetectionStates(watchedByHashing: [], ocrScheduled: Set(OCRRegionKey.productionOCRCases), force: true)
        }

        captureLifecycleController.enqueueAppBackgroundWake(
            reason: "app background wake CaptureEngine recovery: \(reason)",
            requestProvider: { [weak self] in
                guard let self else {
                    return .stopped(reason: "Recovery T wake owner released")
                }
                // This closure is intentionally evaluated only after the queued
                // background stop completes, so it reads the latest route,
                // selected devices and exact format preferences once.
                let role = self.cameraRole(for: self.currentScreen)
                let mode = self.desiredCaptureMode(for: role)
                return self.captureRequest(
                    for: mode,
                    reason: "Recovery T ordered wake current-state reconciliation"
                )
            },
            completion: { [weak self] outcome in
                guard let self else { return }
                self.applyCaptureLifecycleOutcome(outcome)
                self.appBackgroundCaptureSuspended = false
                self.appSuspendedScreen = nil
                self.updateFrameDeliveryPolicy(force: true)
                self.checkVisibleCameraHealthAfterScreenSwitch(for: self.currentScreen)
                MainThreadStallMonitor.shared.trace(
                    "app lifecycle background wake recovery completed mode=\(self.externalOCRMultiCamCoordinator.activeModeSnapshot.rawValue) screen=\(self.currentScreen.rawValue) ocrPaused=\(self.isOCRPaused) outcome=\(outcome.succeeded)/\(outcome.resolvedMode.rawValue)"
                )
            }
        )
    }

    func setScreen(_ screen: AppScreen, reason: String = "unspecified") {
        cameraForensicBreadcrumb(.route, phase: "setScreen requested", extra: "target=\(screen.rawValue) reason=\(reason)")
        let monitor = MainThreadStallMonitor.shared
        let whole = monitor.beginTimedOperation("ViewModel.setScreen \(screen.rawValue)")
        monitor.markContext("ViewModel.setScreen enter: \(screen.rawValue) reason=\(reason)")

        if screen != .broadcast {
            deferredOCRPromotionTask?.cancel()
            deferredOCRPromotionTask = nil
            broadcastOCRPromotionActive = false
            broadcastOCRPromotionBlockedUntil = 0
        } else {
            // Entering Broadcast is preview-only first. Never carry an old OCR
            // promotion flag into a new Broadcast transition.
            broadcastOCRPromotionActive = false
            broadcastOCRPromotionBlockedUntil = CFAbsoluteTimeGetCurrent() + 3.0
        }

        // v0.8.4q: Broadcast -> Calibration was still producing a white preview window.
        // The diagnostics showed the Calibration preview layer attached correctly, but
        // the normal transition path was still toggling frame policy to disabled and
        // reapplying camera priority while SwiftUI was mounting the preview. For this
        // specific route, use a preview-first handshake: switch state immediately, do
        // not pause OCR/frame delivery, and then re-assert OCR camera priority on the
        // next run-loop ticks after the preview view has had time to attach.
        if currentScreen == .broadcast && screen == .calibration {
            setScreenBroadcastToCalibrationPreviewFirst(startedAt: whole)
            return
        }

        guard currentScreen != screen else {
            cameraForensicBreadcrumb(.route, phase: "setScreen same-screen", extra: "target=\(screen.rawValue)")
            let same = monitor.beginTimedOperation("same-screen applyCameraPriority \(screen.rawValue)")
            applyCameraPriority(for: screen)
            monitor.endTimedOperation("same-screen applyCameraPriority \(screen.rawValue)", startedAt: same)
            monitor.endTimedOperation("ViewModel.setScreen no-op \(screen.rawValue)", startedAt: whole)
            return
        }

        print("screen switch started")
        let shouldResumeAfterTransition = userWantsOCRRunning
        isScreenTransitioning = true
        isOCRDiagnosticsVisible = false
        // v0.8.4a: pause processing during the UI transition only. Do not stop or
        // rebuild either camera session as part of a screen switch.
        isOCRPaused = true
        print("OCR processing paused for screen transition; camera sessions retained")
        let policy1 = monitor.beginTimedOperation("updateFrameDeliveryPolicy transition-on")
        updateFrameDeliveryPolicy()
        monitor.endTimedOperation("updateFrameDeliveryPolicy transition-on", startedAt: policy1)
        currentScreen = screen
        cameraForensicBreadcrumb(.route, phase: "currentScreen committed", extra: "target=\(screen.rawValue) reason=\(reason)")
        monitor.trace("currentScreen assigned: \(screen.rawValue)")
        lastOCRFieldCheckAt.removeAll()
        monitor.trace("lastOCRFieldCheckAt cleared")

        // v0.8.4x: do not reprioritise/reconfigure camera while entering Broadcast.
        // Broadcast must draw first, then OCR promotion happens later if still needed.
        if screen == .broadcast {
            monitor.trace("Broadcast entry: live preview pinned immediately; OCR remains deferred")
            ensureBroadcastPreviewSessionRunning(reason: "Broadcast entry immediate live preview pin")
        } else {
            // Make the visible camera the hardware priority immediately. The previous
            // background secondary-camera start could leave the Calibration preview and
            // Overlay PIP black because the live camera was still holding the capture
            // hardware while those screens needed the OCR camera.
            let priority1 = monitor.beginTimedOperation("applyCameraPriority immediate \(screen.rawValue)")
            applyCameraPriority(for: screen)
            monitor.endTimedOperation("applyCameraPriority immediate \(screen.rawValue)", startedAt: priority1)
        }
        monitor.endTimedOperation("ViewModel.setScreen immediate path \(screen.rawValue)", startedAt: whole)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard self.currentScreen == screen else {
                self.cameraForensicBreadcrumb(.route, phase: "delayed resume cancelled", extra: "expected=\(screen.rawValue) actual=\(self.currentScreen.rawValue)")
                return
            }

            self.cameraForensicBreadcrumb(.route, phase: "delayed resume entered", extra: "screen=\(screen.rawValue)")
            let resumeStarted = MainThreadStallMonitor.shared.beginTimedOperation("ViewModel.setScreen delayed resume \(screen.rawValue)")
            MainThreadStallMonitor.shared.markContext("ViewModel.setScreen delayed resume enter: \(screen.rawValue)")
            self.isScreenTransitioning = false
            if screen == .broadcast && self.usesScoreboardCameraInput && shouldResumeAfterTransition {
                // v0.9.1w1: OCR is expected to run while Broadcast is visible.
                // Keep the visible live preview pinned, but immediately re-enable the
                // OCR capture path instead of leaving Broadcast preview-only.
                self.keepBroadcastPreviewAlive(reason: "Broadcast settled before OCR keepalive")
                self.keepBroadcastOCRRunning(reason: "screen transition settled")
                print("OCR running on Broadcast")
            } else if self.usesScoreboardCameraInput && shouldResumeAfterTransition {
                self.isOCRPaused = false
                print("OCR resumed")
            } else {
                self.isOCRPaused = true
            }
            if screen == .broadcast {
                MainThreadStallMonitor.shared.trace("Broadcast settled: policy/priority held for deferred OCR promotion")
            } else {
                let policy2 = MainThreadStallMonitor.shared.beginTimedOperation("updateFrameDeliveryPolicy transition-off")
                self.updateFrameDeliveryPolicy(force: false)
                MainThreadStallMonitor.shared.endTimedOperation("updateFrameDeliveryPolicy transition-off", startedAt: policy2)
                let priority2 = MainThreadStallMonitor.shared.beginTimedOperation("applyCameraPriority delayed \(screen.rawValue)")
                self.applyCameraPriority(for: screen)
                MainThreadStallMonitor.shared.endTimedOperation("applyCameraPriority delayed \(screen.rawValue)", startedAt: priority2)
                let health = MainThreadStallMonitor.shared.beginTimedOperation("checkVisibleCameraHealthAfterScreenSwitch \(screen.rawValue)")
                self.checkVisibleCameraHealthAfterScreenSwitch(for: screen)
                MainThreadStallMonitor.shared.endTimedOperation("checkVisibleCameraHealthAfterScreenSwitch \(screen.rawValue)", startedAt: health)
            }
            self.cameraForensicBreadcrumb(.route, phase: "delayed resume completed", extra: "screen=\(screen.rawValue)")
            MainThreadStallMonitor.shared.endTimedOperation("ViewModel.setScreen delayed resume \(screen.rawValue)", startedAt: resumeStarted)

            // v0.8.4l: avoid reapplying camera priority during the first seconds after a
            // tap. Manual recover remains available for black preview cases.
        }
    }


    private func setScreenBroadcastToCalibrationPreviewFirst(startedAt whole: Date) {
        cameraForensicBreadcrumb(.route, phase: "B2C preview-first enter")
        let monitor = MainThreadStallMonitor.shared
        monitor.trace("B2C preview-first handshake begin")
        monitor.markContext("broadcast to calibration preview-first handshake")

        let shouldResumeAfterTransition = userWantsOCRRunning
        currentScreen = .calibration
        cameraForensicBreadcrumb(.route, phase: "B2C currentScreen committed")
        isScreenTransitioning = false
        isOCRDiagnosticsVisible = false
        if usesScoreboardCameraInput && shouldResumeAfterTransition {
            isOCRPaused = false
        }
        lastOCRFieldCheckAt.removeAll()

        // Recovery AO: CaptureEngine stays running and FrameHub owns the OCR
        // pixel stream. Route assignment therefore does not wait for or mutate a
        // second preview-layer session before the presentation surface can mount.
        ensureVisiblePreviewSessionRunning(reason: "B2C state assigned")
        monitor.trace("B2C state assigned without transition pause or policy change")
        monitor.endTimedOperation("ViewModel.setScreen B2C preview-first immediate", startedAt: whole)

        Task { @MainActor in
            await Task.yield()
            guard self.currentScreen == .calibration else { return }
            MainThreadStallMonitor.shared.trace("Recovery AO B2C yield returned - FrameHub OCR preview owns presentation")
            self.ensureVisiblePreviewSessionRunning(reason: "Recovery AO broadcast to calibration FrameHub preview")
            self.updateFrameDeliveryPolicy(force: true)
            self.checkVisibleCameraHealthAfterScreenSwitch(for: .calibration)
            self.cameraForensicBreadcrumb(
                .route,
                phase: "Recovery AO B2C FrameHub preview admission complete",
                extra: "no delayed preview reconnect tasks"
            )
        }
    }

    private func checkVisibleCameraHealthAfterScreenSwitch(for screen: AppScreen) {
        switch screen {
        case .live, .broadcast:
            liveCameraService.checkVisibleCameraHealthAfterScreenSwitch(isScreenSwitching: isScreenTransitioning)
        case .calibration, .overlay:
            // UX16c15: keep health checking observational here. Camera startup is
            // owned by start()/applyCameraPriority, matching UX16c7a. Do not launch
            // a second activation task from the watchdog.
            ocrCameraService.checkVisibleCameraHealthAfterScreenSwitch(isScreenSwitching: isScreenTransitioning)
        }
    }

    private func preferredStartupRinkTemplate() -> RinkTemplate? {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "IceCast.lastCalibratedRinkTemplateID"),
            let id = UUID(uuidString: raw),
            let calibrated = templateStore.templates.first(where: { $0.id == id })
        {
            return calibrated
        }

        // Build 628 never guesses that the newest modified profile is the
        // physically calibrated one. Prefer the explicitly persisted active
        // profile, then the designated default. Calibration SAVE ZONES writes
        // lastCalibratedRinkTemplateID, which remains the strongest authority.
        if let activeID = templateStore.activeTemplateID,
            let active = templateStore.templates.first(where: { $0.id == activeID })
        {
            return active
        }
        if let defaultID = templateStore.defaultTemplateID,
            let fallback = templateStore.templates.first(where: { $0.id == defaultID })
        {
            return fallback
        }
        // No silent newest-profile fallback: an unconfirmed rectangle set is
        // worse than requiring the operator to select/save the correct rink.
        return nil
    }

    /// Build 134: persisted configuration is a bootstrap transaction, never a
    /// Broadcast route-entry side effect. Presentation bindings are installed
    /// only after this transaction completes.
    private func hydrateStartupRinkConfigurationIfNeeded() {
        let template = preferredStartupRinkTemplate()
        guard RinkLensStartupRinkHydrationPolicy.shouldHydrate(
            phase: .bootstrap,
            alreadyHydrated: startupRinkConfigurationHydrated,
            hasSavedTemplate: template != nil
        ), let template else { return }
        startupRinkConfigurationHydrated = true
        applyTemplate(template, showStatus: false, applyCameraHardware: false)
        RinkLensStructuredEventLogger.shared.record(
            domain: .rinkProfile,
            event: "startup_rink_configuration_hydrated",
            entityID: template.id.uuidString,
            previous: ["phase": "bootstrap", "hydrated": "false"],
            next: ["phase": "bootstrap", "hydrated": "true"],
            source: "HockeyScoreboardViewModel.init",
            reason: "Build 134 hydrates persisted rink/OCR owners before any operational route mounts",
            authoritativeOwner: "existing rink/calibration/OCR stores"
        )
    }

    private func persistLastCalibratedRinkTemplateID(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: "IceCast.lastCalibratedRinkTemplateID")
        UserDefaults.standard.set(true, forKey: "IceCast.zoneProfileSelectionMigratedBuild628")
    }

    func applyTemplate(_ template: RinkTemplate, showStatus: Bool = true, applyCameraHardware: Bool = true) {
        let signature = "\(template.id.uuidString)|\(template.zoneRevision)|\(template.modifiedAt.timeIntervalSinceReferenceDate)"
        if lastAppliedRinkTemplateSignature == signature, !hasUnsavedTemplateChanges {
            MainThreadStallMonitor.shared.trace(
                RinkLensBuildInfo.traceContext("duplicate zone-profile application suppressed id=\(template.id.uuidString) revision=\(template.zoneRevision)")
            )
            return
        }
        lastAppliedRinkTemplateSignature = signature
        MainThreadStallMonitor.shared.markContext("ocr layout write accepted: apply template \(template.name)")
        let previousLayout = ocrLayout
        calibrationStore.applyProfile(
            layout: template.layout,
            boardCalibration: template.boardCalibration,
            colourProfiles: template.ocrColourProfiles,
            calibrationRotationDegrees: template.calibrationRotationDegrees,
            activeTemplateID: template.id,
            source: "HockeyScoreboardViewModel.applyTemplate",
            reason: "Atomic rink profile application"
        )
        cameraControlStore.setCalibrationProfile(template.calibrationCameraProfile, source: "HockeyScoreboardViewModel.applyTemplate", reason: "Rink profile camera preference loaded")
        cameraControlStore.setOCRPreviewRotation(CGFloat(template.ocrPreviewRotationOffsetDegrees), source: "HockeyScoreboardViewModel.applyTemplate", reason: "Rink profile OCR rotation loaded")
        recordZoneLayoutAudit(
            before: previousLayout,
            after: template.layout,
            operation: "template-load",
            detail:
                "Loaded zone profile \(template.name) id=\(template.id.uuidString) revision=\(template.zoneRevision) modified=\(ISO8601DateFormatter().string(from: template.modifiedAt))"
        )
        appendSchedulerDiagnostic("UX14t OCR colour profiles changed: \(ocrColourProfiles.compactSummary)")
        scheduleSelectedRegionPreviewRefresh(reason: "template-colour-profile-load")
        persistCameraRotationSettingsIfReady()
        gameClockDirection = template.gameClockDirection
        localClockDirection = template.gameClockDirection == .auto ? .countDown : template.gameClockDirection
        lastObservedClockOCRSeconds = nil
        repeatedClockOCRReadCount = 0
        clockStopCandidateStartedAt = nil
        lastClockMovementObservedAt = 0
        resetAutoClockDirectionTracking()
        ocrSmoothingEngine.reset(key: .clock)
        // Rink calibration and match identity are separate profiles. A restored
        // selected match profile owns names, logos and scorebug settings atomically.
        // Rink defaults are used only when no valid match profile exists.
        if selectedTeamIdentityTemplateID == nil {
            homeTeamName = template.defaultHomeTeamName ?? homeTeamName
            awayTeamName = template.defaultAwayTeamName ?? awayTeamName
            homeLogoFileName = template.defaultHomeLogoFileName
            awayLogoFileName = template.defaultAwayLogoFileName
            homeLogoImage = loadTemplateAssetImage(fileName: homeLogoFileName)
            awayLogoImage = loadTemplateAssetImage(fileName: awayLogoFileName)
        }
        applyCalibrationCameraProfileFromTemplate(
            template.calibrationCameraProfile,
            fallbackZoom: template.cameraZoomFactor,
            applyHardware: applyCameraHardware
        )
        if let scoreboardTemplate = template.scoreboardTemplate {
            ocrDiagnostics.updateSmartChange(decisionText: "UX16b template loaded rink=\(template.name) \(scoreboardTemplate.summary)")
        } else {
            ocrDiagnostics.updateSmartChange(decisionText: "UX16b template loaded rink=\(template.name) scoreboardTemplate=missing generated-on-next-save")
        }
        activeTemplateID = template.id
        try? templateStore.setActiveTemplate(id: template.id)
        hasUnsavedTemplateChanges = false
        statusMessage = "Loaded: \(template.name) · zone revision \(template.zoneRevision)"
    }

    private func applyCalibrationCameraProfileFromTemplate(
        _ templateProfile: CalibrationCameraProfile,
        fallbackZoom: Double,
        applyHardware: Bool
    ) {
        var merged = templateProfile
        let current = calibrationCameraProfile

        if current.zoomLocked {
            merged.zoomLocked = true
            merged.lockedZoomValue = current.lockedZoomValue
        }
        if current.focusLocked {
            merged.focusLocked = true
            merged.focusValue = current.focusValue
        }
        if current.exposureLocked {
            merged.exposureLocked = true
            merged.exposureISOValue = current.exposureISOValue
            merged.exposureDurationSeconds = current.exposureDurationSeconds
            merged.exposureBiasValue = current.exposureBiasValue
        }
        if current.whiteBalanceLocked {
            merged.whiteBalanceLocked = true
            merged.whiteBalanceTemperatureValue = current.whiteBalanceTemperatureValue
            merged.whiteBalanceTintValue = current.whiteBalanceTintValue
        }
        if current.isoLocked {
            merged.isoLocked = true
            merged.exposureISOValue = current.exposureISOValue
        }
        if current.shutterSpeedLocked {
            merged.shutterSpeedLocked = true
            merged.exposureDurationSeconds = current.exposureDurationSeconds
        }

        merged.profileMode = .manual
        merged.manualCalibrationModeEnabled = true

        // RL-014: a rink profile is persisted setup data, not a second live
        // camera-selection owner. Preserve the already selected logical source;
        // use the template source only when no owner selection exists yet.
        let authoritativeSourceID = ocrCameraService.selectedCameraID
            ?? current.selectedCameraSourceID
            ?? merged.selectedCameraSourceID
        merged.selectedCameraSourceID = authoritativeSourceID
        if let authoritativeSourceID,
           let option = ocrCameraService.availableCameras.first(where: { $0.id == authoritativeSourceID }) {
            merged.selectedCameraSourceKind = calibrationSourceKind(for: option)
        }

        cameraControlStore.setCalibrationProfile(
            merged,
            source: "HockeyScoreboardViewModel.applyCalibrationCameraProfileFromTemplate",
            reason: applyHardware
                ? "Rink profile camera preference projected before hardware application"
                : "Recovery AE startup rink camera profile hydrated without hardware mutation"
        )

        guard applyHardware else {
            calibrationCameraProfileStatusText = "Saved rink camera profile hydrated; hardware application deferred to CaptureEngine startup."
            return
        }

        // For an unlocked profile the saved fallback zoom is an operator-facing
        // preference and may be applied immediately. A locked zoom is applied once
        // with the rest of the hardware locks below; do not issue it twice.
        if !merged.zoomLocked {
            setOCRCameraZoom(CGFloat(fallbackZoom))
        }
        if let sourceID = authoritativeSourceID {
            selectOCRCamera(id: sourceID)
        }
        if let formatID = merged.resolutionFormatID {
            _ = ocrCameraService.stageVideoFormat(
                id: formatID,
                requestedCadence: merged.exactCaptureCadence,
                reason: "apply saved Calibration camera profile"
            )
        }
        applyCalibrationManualLocks(reason: "template loaded")
    }


    func bindingForOCRColourProfile(_ key: OCRRegionKey) -> Binding<OCRZoneColourProfile> {
        Binding(
            get: { self.ocrColourProfiles[key] },
            set: { newValue in
                var updated = self.ocrColourProfiles
                updated[key] = newValue
                self.ocrColourProfiles = updated
                self.statusMessage = "OCR colour profile updated for \(key.likelyTitle): \(newValue.summaryText)"
            }
        )
    }

    /// Build 665 Guided Calibration loupe. This is generated by the same
    /// rectified-board crop processor used by live and Test OCR.
    func guidedCalibrationSelectedZoneLoupe(
        from pixelBuffer: CVPixelBuffer,
        magnification: CGFloat
    ) -> ScoreboardOCRProcessor.TemplateFieldLoupeEvidence? {
        let previewSize = authoritativeOCRGeometryViewportSize
        guard previewSize.width > 10, previewSize.height > 10 else { return nil }
        let key = selectedRegionKey
        let region = ocrLayout[key]
        return selectedRegionCropProcessor.templateFieldLoupeEvidence(
            from: pixelBuffer,
            uiRegion: region.rect,
            boardCalibration: boardCalibration,
            deviceOrientation: .landscapeLeft,
            previewSize: previewSize,
            previewRotationDegrees: ocrPreviewRotationOffsetDegrees,
            regionRotationDegrees: region.rotationDegrees,
            key: key,
            magnification: magnification,
            maximumBoardDimension: 640
        )
    }

    /// Build 665 samples the perspective-corrected selected-zone crop using the
    /// same geometry consumed by OCR and Image Relay. A confidently visible character sets this zone's saved
    /// character/background evidence and enables automatic pipeline selection; an
    /// ambiguous or blank crop restores the established default for that field.
    @discardableResult
    func autoDetectSelectedZoneCharacterColour() -> String {
        let key = selectedRegionKey
        guard let frame = RinkLensFrameHub.shared.latestFrame(for: .ocr, maxAge: 1.25) else {
            let message = "No current OCR frame is available. Zone colour was not changed."
            statusMessage = message
            selectedRegionPreviewStatus = message
            return message
        }

        let previewSize = authoritativeOCRGeometryViewportSize
        guard previewSize.width > 10, previewSize.height > 10 else {
            let message = "The calibrated camera viewport is not ready. Zone colour was not changed."
            statusMessage = message
            selectedRegionPreviewStatus = message
            return message
        }

        let region = ocrLayout[key]
        guard let evidence = selectedRegionCropProcessor.templateFieldCropEvidence(
            from: frame.pixelBuffer,
            uiRegion: region.rect,
            boardCalibration: boardCalibration,
            deviceOrientation: .landscapeLeft,
            previewSize: previewSize,
            previewRotationDegrees: ocrPreviewRotationOffsetDegrees,
            regionRotationDegrees: region.rotationDegrees,
            key: key,
            maximumBoardDimension: 960
        ) else {
            let message = "The selected zone could not be mapped into the scoreboard screen. Colour was not changed."
            statusMessage = message
            selectedRegionPreviewStatus = message
            return message
        }

        let profile: OCRZoneColourProfile
        let message: String
        if let detection = OCRZoneCharacterColourSampler.detect(in: evidence.image) {
            var detected = ocrColourProfiles.profile(for: key)
            detected.characterColour = detection.characterColour
            detected.backgroundColour = detection.backgroundColour
            detected.pipeline = .auto
            detected.allowAutoDetect = true
            detected.sampledCharacterColour = detection.sampledColour
            detected.calibrationSource = .automatic
            profile = detected
            message = "Auto detected \(detection.characterColour.title) characters on \(detection.backgroundColour.title) for \(key.likelyTitle). Pipeline: \(detected.pipelineSelectionStatus(for: key))."
            MainThreadStallMonitor.shared.markContext(
                String(format: "zone colour detected key=%@ foreground=%.3f character=%@ background=%@ mode=auto resolvedPipeline=%@", key.rawValue, detection.foregroundFraction, detection.characterColour.rawValue, detection.backgroundColour.rawValue, detected.resolvedPipeline(for: key).rawValue)
            )
        } else {
            let defaults = OCRZoneColourProfile.defaultProfile(for: key)
            var fallback = ocrColourProfiles.profile(for: key)
            fallback.characterColour = defaults.characterColour
            fallback.backgroundColour = defaults.backgroundColour
            fallback.pipeline = .auto
            fallback.allowAutoDetect = true
            fallback.sampledCharacterColour = nil
            fallback.calibrationSource = nil
            // Colour detection must not silently change an operator-tuned crop margin.
            profile = fallback
            message = "No reliable character was visible in \(key.likelyTitle); its default colours were applied with \(fallback.pipelineSelectionStatus(for: key))."
            MainThreadStallMonitor.shared.markContext("zone colour fallback to default colours: \(key.rawValue)")
        }

        var updatedProfiles = ocrColourProfiles
        updatedProfiles[key] = profile
        ocrColourProfiles = updatedProfiles
        hasUnsavedTemplateChanges = true
        statusMessage = message
        selectedRegionPreviewStatus = message
        _ = updateSelectedRegionPreview(from: frame.pixelBuffer, force: true)
        return message
    }

    /// Manual Guided Calibration eyedropper. The supplied image is the same
    /// upright, perspective-corrected loupe consumed by OCR and Image Relay.
    @discardableResult
    func manuallySampleSelectedZoneCharacterColour(
        from image: UIImage,
        normalizedPoint: CGPoint
    ) -> String {
        let key = selectedRegionKey
        guard let cgImage = image.cgImage,
              let detection = OCRZoneCharacterColourSampler.sample(
                in: cgImage,
                normalizedPoint: normalizedPoint
              ) else {
            let message = "No illuminated character colour was found under the pointer. Tap the centre of a lit stroke."
            statusMessage = message
            selectedRegionPreviewStatus = message
            return message
        }

        var profile = ocrColourProfiles.profile(for: key)
        profile.characterColour = detection.characterColour
        profile.backgroundColour = detection.backgroundColour
        profile.pipeline = detection.pipeline
        profile.allowAutoDetect = false
        profile.sampledCharacterColour = detection.sampledColour
        profile.calibrationSource = .manual

        var updatedProfiles = ocrColourProfiles
        updatedProfiles[key] = profile
        ocrColourProfiles = updatedProfiles
        hasUnsavedTemplateChanges = true
        let message = "Selected \(detection.characterColour.title) on \(detection.backgroundColour.title) for \(key.likelyTitle). Pipeline locked to \(profile.resolvedPipeline(for: key).title); tap Auto to resume automatic pipeline choice."
        statusMessage = message
        selectedRegionPreviewStatus = message
        MainThreadStallMonitor.shared.markContext(
            "manual zone colour sampled key=\(key.rawValue) colour=\(detection.sampledColour.hexText) mode=fixed pipeline=\(profile.resolvedPipeline(for: key).rawValue)"
        )
        return message
    }

    func applyOCRColourProfileDefaults() {
        ocrColourProfiles = .defaults
        statusMessage = "OCR colour profiles reset to rink defaults."
    }

    func selectOCRRegion(_ key: OCRRegionKey) {
        guard !key.isShotRegion else {
            selectedRegionKey = .clock
            selectedRegionRawPreviewImage = nil
            selectedRegionProcessedPreviewImage = nil
            selectedRegionThresholdedPreviewImage = nil
            selectedRegionSegmentPreviewImage = nil
            selectedRegionPreviewStatus = "Shots OCR zones have been removed."
            return
        }

        let changed = selectedRegionKey != key
        selectedRegionKey = key
        if changed {
            selectedZoneTestOCRRequestSequence &+= 1
            selectedZoneTestOCRRequestPending = false
            selectedZoneTestOCRTask?.cancel()
            selectedZoneTestOCRTask = nil
            selectedZoneTestOCRGeneration += 1
            selectedZoneActiveOneShotKey = nil
            pendingTestOCRResult = nil
            pendingTestOCRApplyDescription = nil
            testOCROutcome = .idle
            testOCROutcomeText = "Test OCR has not run for \(key.likelyTitle)."
            selectedRegionRawPreviewImage = nil
            selectedRegionProcessedPreviewImage = nil
            selectedRegionThresholdedPreviewImage = nil
            selectedRegionSegmentPreviewImage = nil
            if operatingMode == .imageRelay {
                selectedRegionPreviewStatus = "Selected \(key.likelyTitle). Raw and Published images come from the background Image Relay pass."
                MainThreadStallMonitor.shared.markContext("selected Image Relay region changed without MainActor OCR preview work: \(key.rawValue)")
            } else {
                selectedRegionPreviewStatus = "Selected \(key.likelyTitle). Preview refresh queued."
                MainThreadStallMonitor.shared.markContext("selected OCR region changed: \(key.rawValue)")
                scheduleSelectedRegionPreviewRefresh(reason: "zone-selection")
            }
        } else if operatingMode != .imageRelay {
            scheduleSelectedRegionPreviewRefresh(reason: "zone-reselect")
        }
    }

    private func scheduleSelectedRegionPreviewRefresh(reason: String) {
        selectedRegionPreviewRequestGeneration += 1
        let generation = selectedRegionPreviewRequestGeneration
        let refreshReason = reason
        let debounceNanoseconds = self.selectedRegionSelectionDebounceNanoseconds
        deferredSelectedRegionPreviewTask?.cancel()
        deferredSelectedRegionPreviewTask = Task { @MainActor [weak self, refreshReason, debounceNanoseconds] in
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard let self, !Task.isCancelled, generation == self.selectedRegionPreviewRequestGeneration else { return }

            // Recovery AI / RL-075: zone movement, perspective alignment and
            // selection changes are UI geometry operations only. They no longer
            // pull a 1080p FrameHub lease and run perspective correction / Core
            // Image / UIImage generation on MainActor. Explicit Test OCR or a
            // colour-calibration action owns those diagnostic images instead.
            self.selectedRegionPreviewStatus = "Zone geometry updated. Live camera remains active; press Test OCR to refresh Raw / Processed / Threshold images."
            MainThreadStallMonitor.shared.traceRenderPreviewToggle(
                "Recovery AI decorative selected-zone preview deferred reason=\(refreshReason) key=\(self.selectedRegionKey.rawValue)"
            )
        }
    }

    func reassignRegion(from: OCRRegionKey, to: OCRRegionKey) {
        guard from != to else { return }
        MainThreadStallMonitor.shared.markContext("ocr layout write accepted: reassign \(from.rawValue)<->\(to.rawValue)")
        let fromRegion = ocrLayout[from]
        let toRegion = ocrLayout[to]
        ocrLayout[from] = toRegion
        ocrLayout[to] = fromRegion
        RinkLensOCREvidenceJournal.shared.recordZoneSwap(
            firstField: from.rawValue,
            firstBefore: .init(fromRegion),
            firstAfter: .init(toRegion),
            secondField: to.rawValue,
            secondBefore: .init(toRegion),
            secondAfter: .init(fromRegion),
            detail: "Logical OCR zone reassignment \(from.rawValue)<->\(to.rawValue)"
        )

        let fromLabel = regionLikelyLabels[from]
        regionLikelyLabels[from] = regionLikelyLabels[to]
        regionLikelyLabels[to] = fromLabel
    }

    /// Build 517 audit entry point for non-gesture layout changes such as profile
    /// load and reset. Only fields whose committed geometry changed are recorded.
    func recordZoneLayoutAudit(
        before: ScoreboardOCRLayout,
        after: ScoreboardOCRLayout,
        operation: String,
        detail: String
    ) {
        let correlationID = UUID().uuidString
        for key in OCRRegionKey.calibrationCases {
            let oldRegion = before[key]
            let newRegion = after[key]
            guard oldRegion != newRegion else { continue }
            RinkLensOCREvidenceJournal.shared.recordZoneEdit(
                field: key.rawValue,
                operation: operation,
                before: .init(oldRegion),
                after: .init(newRegion),
                correlationID: correlationID,
                detail: detail
            )
        }
    }

    /// UX16d15j Build 525: changing score/period/clock geometry invalidates the
    /// matching recognition evidence immediately. A stale hash or operator-seeded
    /// baseline must not make a newly moved zone appear healthy until it has been
    /// reacquired through the continuous path.
    func invalidateOCRFieldsAfterLayoutChange(
        from oldLayout: ScoreboardOCRLayout,
        to newLayout: ScoreboardOCRLayout
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        let changedKeys = Set(OCRRegionKey.calibrationCases.filter {
            oldLayout[$0] != newLayout[$0]
        })
        guard !changedKeys.isEmpty else { return }

        for key in changedKeys {
            lastOCRFieldCheckAt.removeValue(forKey: key)
            mutableAcceptedFieldState.removeValue(forKey: key)
            stoppedWindowSafetyTransactionUntil.removeValue(forKey: key)
            liveOCRPriorityVerificationUntil.removeValue(forKey: key)
            if pendingTestOCRResult?.key == key {
                pendingTestOCRResult = nil
                pendingTestOCRApplyDescription = nil
            }

            switch key {
            case .clock:
                clockVisualHash = nil
                clockLastSafetyOCRAt = 0
                clearBoundedClockEvidence(reason: "Clock zone geometry changed")
                clearImmediateClockConfirmation(reason: "Clock zone geometry changed", resumeStatic: true)
                resetAutoClockDirectionTracking()
            case .homeScore, .awayScore:
                scoreVisualHash.removeValue(forKey: key)
                scorePendingVisualHash.removeValue(forKey: key)
                scoreLastSafetyOCRAt.removeValue(forKey: key)
                liveScoreFieldFastCheckUntil.removeValue(forKey: key)
                ocrPublicationSafetyState.invalidateBaseline(for: key)
                operatorConfirmedTestOCRBaselines.removeValue(forKey: key)
            case .period:
                periodVisualHash = nil
                periodPendingVisualHash = nil
                periodLastSafetyOCRAt = 0
                livePeriodEventWatchUntil = 0
                ocrPublicationSafetyState.invalidateBaseline(for: key)
                operatorConfirmedTestOCRBaselines.removeValue(forKey: key)
            default:
                penaltyPlayerVisualHash.removeValue(forKey: key)
                penaltyPlayerPendingVisualHash.removeValue(forKey: key)
                penaltyTimeVisualHash.removeValue(forKey: key)
                penaltyTimePendingVisualHash.removeValue(forKey: key)
            }
        }

        fullBoardResetRecovery.reset()
        ocrControlPlane.invalidate(keys: changedKeys, now: now, reason: "OCR zone geometry changed")
        appendSchedulerDiagnostic(
            "Build 525 zone geometry invalidated fields=[\(schedulerKeyList(changedKeys))]; independent reacquisition due immediately"
        )
    }

    var activeTemplateName: String? {
        guard let activeTemplateID else { return nil }
        return templateStore.templates.first(where: { $0.id == activeTemplateID })?.name
    }

    /// Build 612 exposes the target of the always-visible Calibration Save Zones
    /// control without loading or mutating the profile.
    var defaultZoneTemplateName: String? {
        guard let defaultID = templateStore.defaultTemplateID else { return nil }
        return templateStore.templates.first(where: { $0.id == defaultID })?.name
    }

    /// UX16d2g always supplies a template geometry contract to Test and live OCR.
    /// Existing generated v1 templates are migrated in memory by
    /// `effectiveCharacterSlots`; unsaved layouts receive a v2 generated template.
    private var activeOCRScoreboardTemplate: RinkScoreboardTemplate {
        if let activeTemplateID,
           let stored = templateStore.templates.first(where: { $0.id == activeTemplateID })?.scoreboardTemplate,
           stored.enabled {
            return stored
        }
        return RinkScoreboardTemplate(layout: ocrLayout, colourProfiles: ocrColourProfiles)
    }

    func saveActiveTemplate(venueName: String, notes: String, imageData: Data?) {
        guard let activeID = activeTemplateID,
              let active = templateStore.templates.first(where: { $0.id == activeID }) else {
            statusMessage = "No active template loaded. Use Save As New Template."
            return
        }

        do {
            let draft = RinkTemplate(
                id: activeID,
                name: active.name,
                createdAt: active.createdAt,
                modifiedAt: .now,
                venueName: venueName,
                notes: notes,
                layout: ocrLayout,
                calibrationRotationDegrees: calibrationRotationDegrees,
                ocrPreviewRotationOffsetDegrees: Double(ocrPreviewRotationOffsetDegrees),
                scoreboardType: "Standard",
                defaultHomeTeamName: homeTeamName,
                defaultAwayTeamName: awayTeamName,
                isDefault: active.isDefault,
                isFavorite: active.isFavorite,
                imageFileName: active.imageFileName,
                cameraZoomFactor: Double(cameraZoomFactor),
                boardCalibration: boardCalibration,
                profileName: active.profileName,
                gameClockDirection: gameClockDirection,
                defaultHomeLogoFileName: homeLogoFileName,
                defaultAwayLogoFileName: awayLogoFileName,
                calibrationCameraProfile: calibrationCameraProfile,
                ocrColourProfiles: ocrColourProfiles,
                scoreboardTemplate: RinkScoreboardTemplate(
                    layout: ocrLayout,
                    colourProfiles: ocrColourProfiles,
                    existingCreatedAt: active.scoreboardTemplate?.createdAt
                )
            )
            let template = try templateStore.updateTemplate(id: activeID, template: draft, imageData: imageData)
            activeTemplateID = template.id
            try? templateStore.setActiveTemplate(id: template.id)
            persistLastCalibratedRinkTemplateID(template.id)
            calibrationStore.markSaved(activeTemplateID: template.id, source: "HockeyScoreboardViewModel", reason: "Active rink profile saved")
            ocrDiagnostics.updateSmartChange(decisionText: "UX16b template saved rink=\(template.name) \(template.scoreboardTemplate?.summary ?? "scoreboardTemplate=missing")")
            RinkLensOCREvidenceJournal.shared.recordMarker(
                "zone_profile_save",
                detail:
                    "Updated active zone profile \(template.name) id=\(template.id.uuidString) revision=\(template.zoneRevision)"
            )
            statusMessage = "Template updated with scoreboard reader slots."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Calibration shortcut. Saves current zone geometry, screen alignment and
    /// per-zone colour calibration into the template already marked as default.
    /// Camera, team and logo settings remain preserved from that default profile.
    /// Build 675 specifically persists both manual and automatic colour samples so
    /// Save Zones is the single operator save action for the complete calibration.
    func saveCurrentZonesToDefaultTemplate() {
        guard let defaultID = templateStore.defaultTemplateID,
              var defaultTemplate = templateStore.templates.first(where: { $0.id == defaultID }) else {
            statusMessage = "No default zone profile is set. Set a default profile first."
            return
        }

        do {
            defaultTemplate.layout = ocrLayout
            defaultTemplate.boardCalibration = boardCalibration
            defaultTemplate.calibrationRotationDegrees = calibrationRotationDegrees
            defaultTemplate.ocrPreviewRotationOffsetDegrees = Double(ocrPreviewRotationOffsetDegrees)
            defaultTemplate.ocrColourProfiles = ocrColourProfiles
            defaultTemplate.scoreboardTemplate = RinkScoreboardTemplate(
                layout: ocrLayout,
                colourProfiles: ocrColourProfiles,
                existingCreatedAt: defaultTemplate.scoreboardTemplate?.createdAt
            )
            let saved = try templateStore.updateTemplate(
                id: defaultID,
                template: defaultTemplate,
                imageData: nil
            )
            activeTemplateID = saved.id
            try? templateStore.setActiveTemplate(id: saved.id)
            persistLastCalibratedRinkTemplateID(saved.id)
            calibrationStore.markSaved(activeTemplateID: saved.id, source: "HockeyScoreboardViewModel", reason: "Default rink profile zones saved")
            let automaticColourCount = OCRRegionKey.allCases.filter {
                ocrColourProfiles.profile(for: $0).calibrationSource == .automatic
            }.count
            let manualColourCount = OCRRegionKey.allCases.filter {
                ocrColourProfiles.profile(for: $0).calibrationSource == .manual
            }.count
            ocrDiagnostics.updateSmartChange(
                decisionText: "Build 675 zones/alignment/colours saved profile=\(saved.name) auto=\(automaticColourCount) manual=\(manualColourCount)"
            )
            RinkLensOCREvidenceJournal.shared.recordMarker(
                "zone_profile_save_default",
                detail:
                    "Saved current zone geometry, screen alignment and colour profiles to default profile \(saved.name) id=\(saved.id.uuidString) revision=\(saved.zoneRevision) autoColours=\(automaticColourCount) manualColours=\(manualColourCount)"
            )
            statusMessage = "Zones, alignment and calibrated colours saved to default profile “\(saved.name)”."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func saveAsNewTemplate(name: String, venueName: String, notes: String, imageData: Data?) {
        do {
            let draft = RinkTemplate(
                name: name,
                venueName: venueName,
                notes: notes,
                layout: ocrLayout,
                calibrationRotationDegrees: calibrationRotationDegrees,
                ocrPreviewRotationOffsetDegrees: Double(ocrPreviewRotationOffsetDegrees),
                scoreboardType: "Standard",
                defaultHomeTeamName: homeTeamName,
                defaultAwayTeamName: awayTeamName,
                cameraZoomFactor: Double(cameraZoomFactor),
                boardCalibration: boardCalibration,
                gameClockDirection: gameClockDirection,
                defaultHomeLogoFileName: homeLogoFileName,
                defaultAwayLogoFileName: awayLogoFileName,
                calibrationCameraProfile: calibrationCameraProfile,
                ocrColourProfiles: ocrColourProfiles,
                scoreboardTemplate: RinkScoreboardTemplate(layout: ocrLayout, colourProfiles: ocrColourProfiles)
            )
            let template = try templateStore.saveNewTemplate(template: draft, imageData: imageData)
            activeTemplateID = template.id
            try? templateStore.setActiveTemplate(id: template.id)
            persistLastCalibratedRinkTemplateID(template.id)
            calibrationStore.markSaved(activeTemplateID: template.id, source: "HockeyScoreboardViewModel", reason: "New rink profile saved")
            ocrDiagnostics.updateSmartChange(decisionText: "UX16b template saved rink=\(template.name) \(template.scoreboardTemplate?.summary ?? "scoreboardTemplate=missing")")
            RinkLensOCREvidenceJournal.shared.recordMarker(
                "zone_profile_save_as_new",
                detail:
                    "Saved new zone profile \(template.name) id=\(template.id.uuidString) revision=\(template.zoneRevision)"
            )
            statusMessage = "Template saved with scoreboard reader slots."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func duplicateTemplate(_ template: RinkTemplate, newName: String) {
        do {
            let copy = try templateStore.duplicateTemplate(id: template.id, newName: newName)
            activeTemplateID = copy.id
            statusMessage = "Template duplicated."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func renameTemplate(_ template: RinkTemplate, newName: String) {
        do {
            try templateStore.renameTemplate(id: template.id, newName: newName)
            statusMessage = "Template renamed."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func deleteTemplate(_ template: RinkTemplate) {
        do {
            try templateStore.deleteTemplate(id: template.id)
            if activeTemplateID == template.id {
                activeTemplateID = nil
                hasUnsavedTemplateChanges = true
            }
            statusMessage = "Template deleted."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func setDefaultTemplate(_ template: RinkTemplate) {
        do {
            try templateStore.setDefaultTemplate(id: template.id)
            statusMessage = "Default template set."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func setGameClockDirection(_ direction: GameClockDirection) {
        guard gameClockDirection != direction else { return }
        gameClockDirection = direction
        localClockDirection = direction == .auto ? .countDown : direction
        lastObservedClockOCRSeconds = nil
        repeatedClockOCRReadCount = 0
        clockStopCandidateStartedAt = nil
        lastClockMovementObservedAt = 0
        resetAutoClockDirectionTracking()
        ocrSmoothingEngine.reset(key: .clock)
        hasUnsavedTemplateChanges = true
        switch direction {
        case .auto:
            statusMessage = "Game clock smoothing set to Auto."
        case .countUp:
            statusMessage = "Game clock smoothing set to Count Up."
        case .countDown:
            statusMessage = "Game clock smoothing set to Count Down."
        }
    }


    func clearDebugHistory() {
        debugHistory.removeAll()
    }

    func resetOCRTrustState() {
        ocrSmoothingEngine.reset()
        ocrPublicationSafetyState.reset()
        operatorConfirmedTestOCRBaselines.removeAll()
        resetOCRBaselineReservationSchedule()
        ocrFieldConfidence.removeAll()
        ocrTrustSummary = OCRTrustSummary()
        mutableAcceptedFieldState.removeAll()
        clearBoundedClockEvidence(reason: "OCR trust reset")
        statusMessage = "OCR trust state reset."
    }


    func resyncClockToCurrentOCR() {
        guard operatingMode == .ocr else {
            statusMessage = "OCR is disabled in Manual Mode."
            return
        }

        guard let candidate = latestOCRCandidateState.clock, isValidTimer(candidate) else {
            statusMessage = "No valid OCR clock available to resync."
            return
        }
        reduceMatchState(
            .setClock(
                candidate,
                context: RinkLensMatchStateContext(
                    origin: .manual,
                    reason: "Operator resynchronised clock to current OCR"
                )
            )
        )
        seedTrustedClockAuthorityFromManualCorrection(
            clock: candidate,
            reason: "Operator resynchronised Clock to current OCR"
        )
        ocrSmoothingEngine.reset(key: .clock)
        mutableAcceptedFieldState[.clock] = AcceptedOCRValueState(
            acceptedText: candidate,
            lastConfidence: ocrFieldConfidence[.clock]?.confidence ?? 1.0,
            recognizerUsed: regionOCRRecognizer[.clock] ?? .segmented,
            lastUpdated: .now
        )
        statusMessage = "Clock resynced to \(candidate)."
    }

    func acceptCurrentOCRField() {
        guard operatingMode == .ocr else {
            statusMessage = "OCR is disabled in Manual Mode."
            return
        }

        guard applyLatestOCRCandidate(for: selectedRegionKey) else {
            statusMessage = "No valid OCR value available for \(selectedRegionKey.likelyTitle)."
            return
        }
        statusMessage = "Accepted current OCR for \(selectedRegionKey.likelyTitle)."
    }

    func resetSelectedOCRTrustState() {
        ocrSmoothingEngine.reset(key: selectedRegionKey)
        ocrFieldConfidence.removeValue(forKey: selectedRegionKey)
        mutableAcceptedFieldState.removeValue(forKey: selectedRegionKey)
        operatorConfirmedTestOCRBaselines.removeValue(forKey: selectedRegionKey)
        if selectedRegionKey == .clock {
            clearBoundedClockEvidence(reason: "selected Clock trust reset")
        }
        statusMessage = "Reset trust for \(selectedRegionKey.likelyTitle)."
    }


    func resetOverlayState() {
        resetToDefaults()
    }

    func resetToDefaults() {
        let baseline = DefaultScoreboardValues()
        defaultClock = baseline.clock
        defaultHomeGoals = baseline.homeGoals
        defaultAwayGoals = baseline.awayGoals
        defaultPeriodOption = baseline.periodOption
        defaultPeriod = baseline.period
        defaultHomePenalty1Player = baseline.homePenalty1Player
        defaultHomePenalty1Clock = baseline.homePenalty1Clock
        defaultHomePenalty2Player = baseline.homePenalty2Player
        defaultHomePenalty2Clock = baseline.homePenalty2Clock
        defaultAwayPenalty1Player = baseline.awayPenalty1Player
        defaultAwayPenalty1Clock = baseline.awayPenalty1Clock
        defaultAwayPenalty2Player = baseline.awayPenalty2Player
        defaultAwayPenalty2Clock = baseline.awayPenalty2Clock

        reduceMatchState(
            .replace(
                scoreStateFromDefaults(),
                context: RinkLensMatchStateContext(
                    origin: .reset,
                    reason: "Factory scoreboard defaults restored"
                )
            )
        )
        lastRawOCRText = nil
        regionOCRPreview = Dictionary(uniqueKeysWithValues: OCRRegionKey.allCases.map { ($0, "--") })
        regionOCRRecognizer = Dictionary(uniqueKeysWithValues: OCRRegionKey.allCases.map { ($0, .vision) })
        mutableAcceptedFieldState.removeAll()
        ocrSmoothingEngine.reset()
        lastOCRFieldCheckAt.removeAll()
        scoreFastCheckUntil = 0
        liveScoreEventWatchUntil = 0
        liveScoreFieldFastCheckUntil.removeAll()
        livePeriodEventWatchUntil = 0
        livePenaltyPairFastCheckUntil.removeAll()
        livePenaltyPairRetryCooldownUntil.removeAll()
        livePenaltyVisualUnusableAttempts.removeAll()
        periodFastCheckUntil = 0
        lastObservedClockOCRSeconds = nil
        repeatedClockOCRReadCount = 0
        clockStopCandidateStartedAt = nil
        lastClockMovementObservedAt = 0
        localClockIsRunning = false
        localClockDirection = gameClockDirection == .auto ? .countDown : gameClockDirection
        resetAutoClockDirectionTracking()
        penaltyLifecycleStore.resetAllPenaltyConfirmationState(source: "HockeyScoreboardViewModel", reason: "scoreboard reset")
        ocrPublicationSafetyState.reset()
        operatorConfirmedTestOCRBaselines.removeAll()
        resetOCRBaselineReservationSchedule()
        penaltyPlayerVisualHash.removeAll()
        penaltyPlayerLastSafetyOCRAt.removeAll()
        ocrFieldConfidence.removeAll()
        ocrTrustSummary = OCRTrustSummary()
        clearBroadcastTimeline()
        overrideHomeScore = defaultHomeGoals
        overrideAwayScore = defaultAwayGoals
        overridePeriod = defaultPeriod
        manualScoreController.clearAllManualOverrides()
        setManualOverride(false)
        statusMessage = "Overlay reset to factory defaults."
    }


    /// Recovers persisted team logos only when the in-memory presentation is
    /// genuinely missing. Route presentation must not replace an already visible
    /// UIImage because that briefly invalidates the retained scorebug overlay.
    func ensureTeamLogosLoadedForBroadcast() {
        // Never recover a logo from a different profile. Cross-profile fallback
        // produced HOME/GUEST names with ACES/BULLDOGS assets in earlier builds.
        let selected = selectedTeamIdentityTemplateID.flatMap { id in
            teamIdentityTemplates.first(where: { $0.id == id })
        }
        if homeLogoFileName == nil { homeLogoFileName = selected?.homeLogoFileName }
        if awayLogoFileName == nil { awayLogoFileName = selected?.awayLogoFileName }

        var homeAction = "retained"
        var awayAction = "retained"
        if homeLogoImage == nil {
            if let recovered = loadTemplateAssetImage(fileName: homeLogoFileName) {
                homeLogoImage = recovered
                homeAction = "recovered"
            } else {
                homeAction = "unavailable"
            }
        }
        if awayLogoImage == nil {
            if let recovered = loadTemplateAssetImage(fileName: awayLogoFileName) {
                awayLogoImage = recovered
                awayAction = "recovered"
            } else {
                awayAction = "unavailable"
            }
        }

        let homeSize = homeLogoImage.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "none"
        let awaySize = awayLogoImage.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "none"
        RinkLensOCREvidenceJournal.shared.recordEventAudit(
            stage: "team_identity_broadcast_retained",
            eventKind: "profile",
            source: BroadcastEventSource.manual.rawValue,
            detail:
                "profile=\(selectedTeamIdentityTemplateID?.uuidString ?? "none") homeFile=\(homeLogoFileName ?? "none") homeAction=\(homeAction) homeSize=\(homeSize) awayFile=\(awayLogoFileName ?? "none") awayAction=\(awayAction) awaySize=\(awaySize)"
        )
    }

    private func setTeamIdentityNames(home: String?, away: String?, source: String, reason: String) {
        if let home { teamIdentityStore.setHomeTeamName(home, source: source, reason: reason) }
        if let away { teamIdentityStore.setAwayTeamName(away, source: source, reason: reason) }
        reduceMatchState(
            .setTeams(
                home: teamIdentityStore.homeTeamName,
                away: teamIdentityStore.awayTeamName,
                context: RinkLensMatchStateContext(
                    origin: .manual,
                    diagnosticsOnly: true,
                    reason: "Team identity projection synchronised: \(reason)"
                )
            )
        )
    }

    /// Applies one already-resolved fixture snapshot to existing configuration
    /// owners. This transaction contains no capture, recording or stream intent.
    func applyGameConfigurationSnapshot(_ snapshot: RinkLensGameConfigurationSnapshot) {
        let homeImage = loadTemplateAssetImage(fileName: snapshot.homeTeam.primaryLogoFileName)
        let awayImage = loadTemplateAssetImage(fileName: snapshot.awayTeam.primaryLogoFileName)
        teamIdentityStore.applyProfile(
            homeTeamName: snapshot.homeTeam.fullName,
            awayTeamName: snapshot.awayTeam.fullName,
            homeLogoImage: homeImage,
            awayLogoImage: awayImage,
            homeLogoFileName: snapshot.homeTeam.primaryLogoFileName,
            awayLogoFileName: snapshot.awayTeam.primaryLogoFileName,
            selectedTemplateID: selectedTeamIdentityTemplateID,
            source: "HockeyScoreboardViewModel.applyGameConfigurationSnapshot",
            reason: "Loaded immutable fixture \(snapshot.fixtureID.uuidString)"
        )
        reduceMatchState(
            .setTeams(
                home: snapshot.homeTeam.fullName,
                away: snapshot.awayTeam.fullName,
                context: RinkLensMatchStateContext(
                    origin: .manual,
                    diagnosticsOnly: true,
                    reason: "Fixture configuration projected into MatchState team identity"
                )
            )
        )
        SponsorCatalogueStore.shared.replaceHomeRoster(
            snapshot.homeTeam.roster.map { SponsorPlayerAssignment(number: $0.number, name: $0.name, sponsorID: nil) },
            source: "HockeyScoreboardViewModel.applyGameConfigurationSnapshot",
            reason: "Active Home roster resolved from immutable fixture configuration"
        )
        if let settingsData = snapshot.scorebugSettingsData,
           let settings = try? JSONDecoder().decode(BroadcastScoreboardTemplateSettings.self, from: settingsData) {
            BroadcastScoreboardLayoutSettings.shared.applyTemplateSettings(
                settings,
                source: "HockeyScoreboardViewModel.applyGameConfigurationSnapshot",
                reason: "Season scorebug profile resolved into the authoritative scorebug owner"
            )
        }
        persistWorkingTeamNames()
        statusMessage = "Loaded \(snapshot.homeTeam.shortName) v \(snapshot.awayTeam.shortName). Production has not started."
        RinkLensStructuredEventLogger.shared.record(
            domain: .gameConfiguration,
            event: "snapshot_applied_to_configuration_owners",
            entityID: snapshot.fixtureID.uuidString,
            next: [
                "home": snapshot.homeTeam.fullName,
                "away": snapshot.awayTeam.fullName,
                "homeRoster": String(snapshot.homeTeam.roster.count),
                "captureIntent": "unchanged"
            ],
            source: "HockeyScoreboardViewModel.applyGameConfigurationSnapshot",
            reason: "Operator loaded fixture without starting production",
            authoritativeOwner: "RinkLensGameConfigurationStore"
        )
    }

    func resetTeamsAndLogos() {
        if RinkLensRiskFeaturePolicy.isEnabled(.atomicOwnerTransactionsV3) {
            teamIdentityStore.resetTeamsAndLogos(
                source: "HockeyScoreboardViewModel",
                reason: "Operator reset current teams and logos atomically"
            )
        } else {
            teamIdentityStore.setHomeTeamName("HOME", source: "HockeyScoreboardViewModel", reason: "Legacy reset comparison")
            teamIdentityStore.setAwayTeamName("GUEST", source: "HockeyScoreboardViewModel", reason: "Legacy reset comparison")
            teamIdentityStore.setHomeLogo(image: nil, fileName: nil, source: "HockeyScoreboardViewModel", reason: "Legacy reset comparison")
            teamIdentityStore.setAwayLogo(image: nil, fileName: nil, source: "HockeyScoreboardViewModel", reason: "Legacy reset comparison")
        }
        syncActiveTeamIdentityTemplateLogo(home: nil, away: nil)
        reduceMatchState(
            .setTeams(
                home: "HOME",
                away: "GUEST",
                context: RinkLensMatchStateContext(
                    origin: .manual,
                    diagnosticsOnly: true,
                    reason: "Atomic team identity reset projected into MatchState"
                )
            )
        )
    }

    func setHomeLogo(data: Data?) {
        guard let data else {
            teamIdentityStore.setHomeLogo(image: nil, fileName: nil, source: "HockeyScoreboardViewModel", reason: "Operator cleared Home logo")
            syncActiveTeamIdentityTemplateLogo(home: nil, away: awayLogoFileName)
            return
        }
        guard let image = UIImage(data: data) else { return }
        let fileName = persistTeamLogo(data: data, existing: homeLogoFileName)
        teamIdentityStore.setHomeLogo(image: image, fileName: fileName, source: "HockeyScoreboardViewModel", reason: "Operator selected Home logo")
        syncActiveTeamIdentityTemplateLogo(home: fileName, away: awayLogoFileName)
    }

    func setAwayLogo(data: Data?) {
        guard let data else {
            teamIdentityStore.setAwayLogo(image: nil, fileName: nil, source: "HockeyScoreboardViewModel", reason: "Operator cleared Away logo")
            syncActiveTeamIdentityTemplateLogo(home: homeLogoFileName, away: nil)
            return
        }
        guard let image = UIImage(data: data) else { return }
        let fileName = persistTeamLogo(data: data, existing: awayLogoFileName)
        teamIdentityStore.setAwayLogo(image: image, fileName: fileName, source: "HockeyScoreboardViewModel", reason: "Operator selected Away logo")
        syncActiveTeamIdentityTemplateLogo(home: homeLogoFileName, away: fileName)
    }

    private func loadLastWorkingTeamNames() {
        let defaults = UserDefaults.standard
        let storedHome = defaults.string(forKey: "IceCast.lastWorkingHomeTeamName")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let storedAway = defaults.string(forKey: "IceCast.lastWorkingAwayTeamName")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let home = (storedHome?.isEmpty == false) ? storedHome! : teamIdentityStore.homeTeamName
        let away = (storedAway?.isEmpty == false) ? storedAway! : teamIdentityStore.awayTeamName
        teamIdentityStore.setTeamNames(
            home: home,
            away: away,
            source: "HockeyScoreboardViewModel.init",
            reason: "Recovery AV persisted team names hydrated before first MatchState publication"
        )
    }

    func persistWorkingTeamNames() {
        let defaults = UserDefaults.standard
        defaults.set(homeTeamName, forKey: "IceCast.lastWorkingHomeTeamName")
        defaults.set(awayTeamName, forKey: "IceCast.lastWorkingAwayTeamName")
    }

    func saveCurrentTeamIdentityTemplate(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let template = TeamIdentityTemplate(
            name: trimmed,
            homeTeamName: homeTeamName,
            awayTeamName: awayTeamName,
            homeLogoFileName: homeLogoFileName,
            awayLogoFileName: awayLogoFileName,
            scoreboardSettings: BroadcastScoreboardLayoutSettings.shared.templateSettings
        )
        teamIdentityTemplates.append(template)
        selectedTeamIdentityTemplateID = template.id
        persistSelectedTeamIdentityTemplateID()
        persistWorkingTeamNames()
        persistTeamIdentityTemplates()
    }

    func updateActiveTeamIdentityTemplateWithCurrentScoreboardStyle(title: String? = nil) {
        guard let selectedTeamIdentityTemplateID else { return }
        teamIdentityStore.updateTemplate(
            id: selectedTeamIdentityTemplateID,
            source: "HockeyScoreboardViewModel",
            reason: "Save profile title, current team identity and scorebug style as one owner transaction"
        ) { template in
            template = template.updatingCurrentProfile(
                title: title ?? template.name,
                homeTeamName: homeTeamName,
                awayTeamName: awayTeamName,
                homeLogoFileName: homeLogoFileName,
                awayLogoFileName: awayLogoFileName,
                scoreboardSettings: BroadcastScoreboardLayoutSettings.shared.templateSettings
            )
        }
        persistWorkingTeamNames()
        persistTeamIdentityTemplates()
    }

    func applyTeamIdentityTemplate(
        _ template: TeamIdentityTemplate,
        persistSelection: Bool = true,
        projectToMatchState: Bool = true
    ) {
        // Build 691: names, logos, file references and active profile commit as
        // one owner transaction. Scorebug appearance is a separate declared
        // owner and applies its own structured transaction immediately after.
        let homeImage = loadTemplateAssetImage(fileName: template.homeLogoFileName)
        let awayImage = loadTemplateAssetImage(fileName: template.awayLogoFileName)
        if RinkLensRiskFeaturePolicy.isEnabled(.teamIdentityAuthorityV2) {
            teamIdentityStore.applyProfile(
                homeTeamName: template.homeTeamName,
                awayTeamName: template.awayTeamName,
                homeLogoImage: homeImage,
                awayLogoImage: awayImage,
                homeLogoFileName: template.homeLogoFileName,
                awayLogoFileName: template.awayLogoFileName,
                selectedTemplateID: template.id,
                source: "HockeyScoreboardViewModel",
                reason: "Apply saved team identity profile \(template.name) atomically"
            )
        } else {
            // Rollback comparison path: retain the pre-Build-691 stepwise profile
            // application while all values still remain owned by the same store.
            teamIdentityStore.setHomeTeamName(template.homeTeamName, source: "TeamIdentityRollback", reason: "Stepwise profile apply")
            teamIdentityStore.setAwayTeamName(template.awayTeamName, source: "TeamIdentityRollback", reason: "Stepwise profile apply")
            teamIdentityStore.setHomeLogo(image: homeImage, fileName: template.homeLogoFileName, source: "TeamIdentityRollback", reason: "Stepwise profile apply")
            teamIdentityStore.setAwayLogo(image: awayImage, fileName: template.awayLogoFileName, source: "TeamIdentityRollback", reason: "Stepwise profile apply")
            teamIdentityStore.selectTemplate(template.id, source: "TeamIdentityRollback", reason: "Stepwise profile apply")
        }
        if projectToMatchState {
            reduceMatchState(
                .setTeams(
                    home: teamIdentityStore.homeTeamName,
                    away: teamIdentityStore.awayTeamName,
                    context: RinkLensMatchStateContext(
                        origin: .manual,
                        diagnosticsOnly: true,
                        reason: "Saved team identity profile projected into match state"
                    )
                )
            )
        }
        BroadcastScoreboardLayoutSettings.shared.applyTemplateSettings(
            template.scoreboardSettings,
            source: "TeamIdentityProfile",
            reason: "Apply scorebug settings from profile \(template.name)"
        )
        persistWorkingTeamNames()
        if persistSelection { persistSelectedTeamIdentityTemplateID() }
        RinkLensOCREvidenceJournal.shared.recordEventAudit(
            stage: "team_identity_profile_applied",
            eventKind: "profile",
            source: BroadcastEventSource.manual.rawValue,
            detail:
                "id=\(template.id.uuidString) name=\(template.name) home=\(template.homeTeamName) away=\(template.awayTeamName) persisted=\(persistSelection)"
        )
    }

    /// Build 706 screen-entry contract. Broadcast and recording may validate the
    /// owner projection, but they do not restore profiles, reload logos or reset
    /// any live state. Persistence recovery remains an owner-controlled startup
    /// responsibility in `init`.
    @discardableResult
    func validateActiveTeamIdentityForBroadcastPresentation(source: String) -> Bool {
        // This method is deliberately read-only with respect to live team identity.
        // It may emit diagnostic evidence, but it never restores a profile, reloads
        // a logo, rewrites match state or changes a presentation value.
        teamIdentityStore.validateForPresentation(
            source: source,
            reason: "Broadcast/recording requested a read-only team identity projection"
        )
    }

    /// Owner-controlled startup policy. The feature flag compares strict and
    /// legacy recovery without allowing any screen lifecycle callback to become
    /// a second writer. Both branches execute before presentation binds to state.
    private func restoreTeamIdentityAtOwnerStartup(projectToMatchState: Bool = true) {
        if RinkLensRiskFeaturePolicy.isEnabled(.screenEntryReadOnlyV4) {
            restorePreferredTeamIdentityTemplateIfAvailable(
                reason: "strict owner-controlled view-model initialisation",
                projectToMatchState: projectToMatchState
            )
            ensureTeamLogosLoadedForBroadcast()
            return
        }
        legacyRestoreTeamIdentityAtOwnerStartup(projectToMatchState: projectToMatchState)
    }

    private func legacyRestoreTeamIdentityAtOwnerStartup(projectToMatchState: Bool = true) {
        let selected = selectedTeamIdentityTemplateID.flatMap { id in
            teamIdentityTemplates.first(where: { $0.id == id })
        }
        if selected == nil || homeTeamName == "HOME" || awayTeamName == "GUEST" {
            restorePreferredTeamIdentityTemplateIfAvailable(reason: "legacy owner-controlled view-model initialisation", projectToMatchState: projectToMatchState)
        }
        ensureTeamLogosLoadedForBroadcast()
    }

    func duplicateTeamIdentityTemplate(_ template: TeamIdentityTemplate, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var duplicate = template
        duplicate.id = UUID()
        duplicate.name = trimmed
        duplicate.createdAt = .now
        teamIdentityTemplates.append(duplicate)
        selectedTeamIdentityTemplateID = duplicate.id
        persistSelectedTeamIdentityTemplateID()
        persistTeamIdentityTemplates()
    }

    func setDefaultTeamIdentityTemplate(_ template: TeamIdentityTemplate?) {
        defaultTeamIdentityTemplateID = template?.id
        persistDefaultTeamIdentityTemplateID()
    }

    func applyDefaultTeamIdentityTemplateIfAvailable() {
        guard let defaultTeamIdentityTemplateID,
              let template = teamIdentityTemplates.first(where: { $0.id == defaultTeamIdentityTemplateID }) else { return }
        applyTeamIdentityTemplate(template)
    }

    private func restorePreferredTeamIdentityTemplateIfAvailable(
        reason: String,
        projectToMatchState: Bool = true
    ) {
        let selected = selectedTeamIdentityTemplateID.flatMap { id in
            teamIdentityTemplates.first(where: { $0.id == id })
        }
        let designatedDefault = defaultTeamIdentityTemplateID.flatMap { id in
            teamIdentityTemplates.first(where: { $0.id == id })
        }
        guard
            let template = selected ?? designatedDefault
                ?? teamIdentityTemplates.sorted(by: { $0.createdAt > $1.createdAt }).first
        else {
            return
        }
        applyTeamIdentityTemplate(template, projectToMatchState: projectToMatchState)
        RinkLensOCREvidenceJournal.shared.recordEventAudit(
            stage: "team_identity_profile_restored",
            eventKind: "profile",
            source: BroadcastEventSource.manual.rawValue,
            detail:
                "reason=\(reason) selected=\(selected?.id.uuidString ?? "none") default=\(designatedDefault?.id.uuidString ?? "none") applied=\(template.id.uuidString)"
        )
    }

    func deleteTeamIdentityTemplate(_ template: TeamIdentityTemplate) {
        guard let index = teamIdentityTemplates.firstIndex(where: { $0.id == template.id }) else { return }

        let removed = teamIdentityTemplates.remove(at: index)
        let removedWasSelected = selectedTeamIdentityTemplateID == removed.id
        if removedWasSelected {
            selectedTeamIdentityTemplateID = nil
            persistSelectedTeamIdentityTemplateID()
        }
        if defaultTeamIdentityTemplateID == removed.id {
            defaultTeamIdentityTemplateID = nil
            persistDefaultTeamIdentityTemplateID()
        }
        persistTeamIdentityTemplates()
        removeTeamLogoIfUnused(named: removed.homeLogoFileName)
        removeTeamLogoIfUnused(named: removed.awayLogoFileName)
        if removedWasSelected {
            restorePreferredTeamIdentityTemplateIfAvailable(reason: "selected profile deleted")
        }
    }

    private func startCameraSession(priorityScreen: AppScreen) async {
        cameraForensicBreadcrumb(.lifecycle, phase: "startCameraSession enter", extra: "priorityScreen=\(priorityScreen.rawValue) profileSource=\(calibrationCameraProfile.selectedCameraSourceID ?? "none")")

        validateSavedCalibrationCameraSource()
        enforceCalibrationCameraDefaultAvoidingBroadcast(reason: "UX16c35 CaptureEngine pre-stage startup")

        let savedLiveSource = liveCameraService.selectedCameraID
        let liveID = savedLiveSource.flatMap {
            liveCameraService.stageLogicalCameraSource($0, reason: "CaptureEngine Broadcast startup")
        } ?? liveCameraService.preparePreferredCamera(excluding: [], preferExternal: false)

        let savedOCRSource = calibrationCameraProfile.selectedCameraSourceID
            ?? ocrCameraService.selectedCameraID
        let ocrID: String?
        if let savedOCRSource {
            // Recovery Z / RL-059: an existing logical source is authoritative.
            // If it is temporarily unavailable, keep the source selected and let
            // CaptureEngine run the valid fallback contract; do not silently
            // allocate and persist a different OCR camera.
            ocrID = ocrCameraService.stageLogicalCameraSource(
                savedOCRSource,
                reason: "Recovery Z CaptureEngine OCR startup authoritative source"
            )
            if ocrID == nil {
                cameraForensicBreadcrumb(
                    .selection,
                    phase: "Recovery Z OCR source retained while unavailable",
                    extra: "logical=\(savedOCRSource)"
                )
            }
        } else {
            ocrID = ocrCameraService.preparePreferredCamera(
                excluding: liveID.map { [$0] } ?? [],
                preferExternal: true
            )
        }

        cameraForensicBreadcrumb(
            .lifecycle,
            phase: "CaptureEngine cameras staged",
            extra: "live=\(liveID ?? "none") ocr=\(ocrID ?? "none")"
        )

        // Recovery AE: saved format preference belongs to the same startup
        // transaction as physical source staging. Do not stage it while the
        // profile is merely being hydrated.
        if ocrID != nil, let formatID = calibrationCameraProfile.resolutionFormatID {
            _ = ocrCameraService.stageVideoFormat(
                id: formatID,
                requestedCadence: calibrationCameraProfile.exactCaptureCadence,
                reason: "Recovery AE startup saved Calibration format after OCR source staging"
            )
        }

        let role = cameraRole(for: priorityScreen)
        let request = captureRequest(for: desiredCaptureMode(for: role), reason: "UX16c35 startup screen=\(priorityScreen.rawValue)")
        let outcome = await captureLifecycleController.ensure(request)
        applyCaptureLifecycleOutcome(outcome)
        updateFrameDeliveryPolicy(force: true)
        if outcome.succeeded, ocrID != nil {
            applyCalibrationHardwareLocksFromCurrentProfile(
                reason: "Recovery AE startup after CaptureEngine physical OCR staging"
            )
        }
        cameraForensicBreadcrumb(
            .lifecycle,
            phase: "startCameraSession completed",
            extra: "mode=\(outcome.resolvedMode.rawValue) success=\(outcome.succeeded)"
        )
    }

    /// Build 571: Image Relay owns its scoreboard-camera request. It must not
    /// depend on the Calibration/OCR screen mounting a preview before frames
    /// enter FrameHub. This method stages the saved camera selections and starts
    /// the required capture graph from any route.
    @MainActor
    func ensureImageRelayCaptureActive(reason: String) async {
        let lifecycleAllowsRun = RinkLensRiskFeaturePolicy.isEnabled(.scoreboardInputLifecycleV2)
            ? scoreboardInputLifecycleStore.snapshot.shouldRun
            : (userWantsOCRRunning && !isOCRPaused)
        guard operatingMode == .imageRelay,
              lifecycleAllowsRun else {
            cameraForensicBreadcrumb(
                .lifecycle,
                phase: "Image Relay capture request ignored",
                extra: "reason=\(reason) mode=\(operatingMode.rawValue) wanted=\(userWantsOCRRunning) paused=\(isOCRPaused)"
            )
            return
        }

        cameraForensicBreadcrumb(
            .lifecycle,
            phase: "Image Relay route-independent capture requested",
            extra: "screen=\(currentScreen.rawValue) reason=\(reason)"
        )

        if hasStartedAppServices {
            // Recovery D / RL-013 + RL-032: camera discovery and source staging are
            // startup/device-change responsibilities. Image Relay is a consumer of
            // the existing DesiredCaptureContract, not a second trigger for camera
            // discovery. requestCaptureForRoleIfNeeded() is edge-triggered through
            // CaptureLifecycleController.shouldSubmitReconciliation, so repeated
            // SwiftUI/relay requests become a no-op while the graph already matches.
            await requestCaptureForRoleIfNeeded(
                cameraRole(for: currentScreen),
                reason: "Recovery D edge-triggered Image Relay capture contract: \(reason)"
            )
        } else {
            // First application bootstrap still owns the one discovery/staging pass.
            await start()
        }

        let lifecycleStillAllowsRun = RinkLensRiskFeaturePolicy.isEnabled(.scoreboardInputLifecycleV2)
            ? scoreboardInputLifecycleStore.snapshot.shouldRun
            : (userWantsOCRRunning && !isOCRPaused)
        guard operatingMode == .imageRelay,
              lifecycleStillAllowsRun else { return }

        if currentScreen == .broadcast {
            broadcastOCRPromotionActive = true
            broadcastOCRPromotionBlockedUntil = 0
            isScreenTransitioning = false
        }

        // Recovery AH / RL-070: Image Relay requests processing from the
        // already-running physical OCR stream; it does not switch that stream on.
        updateFrameDeliveryPolicy(force: true)
        let capture = externalOCRMultiCamCoordinator.snapshot
        let scoreboardBranchActive = capture.isActive
            && capture.sessionRunning
            && externalOCRMultiCamCoordinator.activeModeSnapshot.requiresOCR
        if scoreboardBranchActive {
            scoreboardInputLifecycleStore.markRunning(
                source: "HockeyScoreboardViewModel.ensureImageRelayCaptureActive",
                reason: reason
            )
        } else {
            if RinkLensRecordingCaptureLease.shared.isWriterContractOpen() {
                scoreboardInputLifecycleStore.waitForCapture(
                    source: "HockeyScoreboardViewModel.ensureImageRelayCaptureActive",
                    reason: "OCR restoration is physically deferred until the RecordingWriter contract closes — \(reason)"
                )
            } else {
                scoreboardInputLifecycleStore.fail(
                    "scoreboard camera branch not configured",
                    source: "HockeyScoreboardViewModel.ensureImageRelayCaptureActive",
                    reason: reason
                )
            }
        }
        statusMessage = scoreboardBranchActive
            ? "Image Relay running. Scoreboard camera active without opening OCR screen."
            : "Image Relay waiting for scoreboard camera."
        cameraForensicBreadcrumb(
            .lifecycle,
            phase: "Image Relay route-independent capture completed",
            extra: "mode=\(capture.captureModeText) running=\(capture.sessionRunning) ocrDevice=\(capture.ocrDeviceID ?? "none") reason=\(reason)"
        )
    }

    private enum CameraRole {
        case live
        case ocr
    }

    private func authoritativeDesiredCaptureMode(
        liveIdentity: HockeyCameraService.CaptureIdentitySnapshot,
        ocrIdentity: HockeyCameraService.CaptureIdentitySnapshot
    ) -> RinkLensCaptureLifecycleMode {
        // R17 match-session graph ownership is selection/mode driven, not route
        // driven. When scoreboard-camera input is configured, keep both physical
        // branches in one CaptureEngine graph even while frame delivery is paused.
        let hasLive = liveIdentity.preferredResolvedPhysicalDeviceID != nil
        let hasOCR = ocrIdentity.preferredResolvedPhysicalDeviceID != nil
        let canOwnStableDualGraph = usesScoreboardCameraInput
            && hasLive
            && hasOCR
            && liveIdentity.selectedLogicalSourceID != ocrIdentity.selectedLogicalSourceID
        if canOwnStableDualGraph { return .dualCamera }

        switch currentScreen {
        case .live, .broadcast:
            return hasLive ? .broadcastOnly : .stopped
        case .calibration, .overlay:
            return hasOCR ? .ocrOnly : (hasLive ? .broadcastOnly : .stopped)
        }
    }

    private func desiredCaptureMode(for role: CameraRole) -> RinkLensCaptureLifecycleMode {
        // `role` identifies the caller only. The authoritative contract is built
        // from retained selection identities, never transient active ownership.
        _ = role
        return authoritativeDesiredCaptureMode(
            liveIdentity: liveCameraService.captureIdentitySnapshot(),
            ocrIdentity: ocrCameraService.captureIdentitySnapshot()
        )
    }

    private func captureRequest(
        for mode: RinkLensCaptureLifecycleMode,
        reason: String,
        liveDeviceIDOverride: String? = nil,
        ocrDeviceIDOverride: String? = nil
    ) -> RinkLensCaptureLifecycleRequest {
        let liveIdentity = liveCameraService.captureIdentitySnapshot()
        let ocrIdentity = ocrCameraService.captureIdentitySnapshot()
        let liveID = liveDeviceIDOverride ?? liveIdentity.preferredResolvedPhysicalDeviceID
        let ocrID = ocrDeviceIDOverride ?? ocrIdentity.preferredResolvedPhysicalDeviceID
        let liveFormat = liveCameraService.captureFormatPreferenceSnapshot()
        let ocrFormat = ocrCameraService.captureFormatPreferenceSnapshot()
        switch mode {
        case .dualCamera:
            return .dualCamera(
                liveLogicalSourceID: liveIdentity.selectedLogicalSourceID,
                ocrLogicalSourceID: ocrIdentity.selectedLogicalSourceID,
                liveDeviceID: liveID,
                ocrDeviceID: ocrID,
                liveFormat: liveFormat,
                ocrFormat: ocrFormat,
                allowBroadcastFallback: true,
                reason: reason
            )
        case .broadcastOnly:
            return .broadcastOnly(
                liveLogicalSourceID: liveIdentity.selectedLogicalSourceID,
                liveDeviceID: liveID,
                liveFormat: liveFormat,
                reason: reason
            )
        case .ocrOnly:
            return .ocrOnly(
                ocrLogicalSourceID: ocrIdentity.selectedLogicalSourceID,
                ocrDeviceID: ocrID,
                ocrFormat: ocrFormat,
                reason: reason
            )
        case .stopped:
            return .stopped(reason: reason)
        }
    }

    /// A recording start submits intent through CaptureLifecycleController and
    /// uses the same authoritative desired graph as the visible Broadcast route.
    /// RecordingEngine remains the sole owner of the pending writer transaction.
    func recordingCaptureReadinessRequest(reason: String) -> RinkLensCaptureLifecycleRequest {
        captureRequest(for: desiredCaptureMode(for: .live), reason: reason)
    }

    private func ensureVisiblePreviewSessionRunning(reason: String) {
        let role = cameraRole(for: currentScreen)
        Task { @MainActor in
            await self.requestCaptureForRoleIfNeeded(role, reason: reason)
        }
    }

    func keepBroadcastPreviewAlive(reason: String) {
        guard currentScreen == .broadcast || currentScreen == .live else { return }
        guard isBroadcastPreviewRecoveryAllowedForActiveRoute else { return }

        // UX16c46: legacy callers may still ask for a keepalive, but the request
        // now becomes a rate-limited observation. Only sustained divergence may
        // submit a lifecycle reconciliation through the route owner.
        Task { @MainActor in
            await self.observeNextGenRouteHealth(
                .broadcast,
                reason: "legacy Broadcast health observation: \(reason)"
            )
        }
    }

    private func ensureBroadcastPreviewSessionRunning(reason: String) {
        guard currentScreen == .broadcast || currentScreen == .live else { return }
        guard isBroadcastPreviewRecoveryAllowedForActiveRoute else { return }
        Task { @MainActor in
            await self.requestCaptureForRoleIfNeeded(.live, reason: "Broadcast preview assertion: \(reason)")
        }
    }

    private func cameraRole(for screen: AppScreen) -> CameraRole {
        switch screen {
        case .calibration, .overlay:
            return .ocr
        case .live, .broadcast:
            return .live
        }
    }

    private func ensureCameraServiceStarted(for screen: AppScreen) {
        let role = cameraRole(for: screen)
        Task { @MainActor in
            await self.requestCaptureForRoleIfNeeded(role, reason: "route camera assertion: \(screen.rawValue)")
        }
    }

    func applyCameraPriority(for screen: AppScreen) {
        cameraForensicBreadcrumb(
            .route,
            phase: "CaptureEngine route priority",
            extra: "target=\(screen.rawValue)"
        )
        let role = cameraRole(for: screen)
        Task { @MainActor in
            await self.requestCaptureForRoleIfNeeded(role, reason: "route priority \(screen.rawValue)")
        }
    }

    private func scheduleDeferredOCRPromotionIfStillOnBroadcast(reason: String) {
        guard isBroadcastPreviewRecoveryAllowedForActiveRoute else {
            cancelDeferredBroadcastPreviewWork(reason: "OCR promotion suppressed outside Broadcast: \(reason)")
            return
        }
        deferredOCRPromotionTask?.cancel()
        deferredOCRPromotionGeneration += 1
        let generation = deferredOCRPromotionGeneration
        deferredOCRPromotionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self else { return }
            await MainActor.run {
                guard generation == self.deferredOCRPromotionGeneration,
                      self.currentScreen == .broadcast,
                      self.usesScoreboardCameraInput,
                      self.userWantsOCRRunning else { return }
                self.broadcastOCRPromotionActive = true
                self.broadcastOCRPromotionBlockedUntil = 0
                self.isScreenTransitioning = false
                self.isOCRPaused = false
                self.lastOCRAt = CFAbsoluteTimeGetCurrent()
                self.lastOCRFieldCheckAt.removeAll()
                self.ocrStartupClockBootstrapActive = false
                self.updateRegionDetectionStates(watchedByHashing: [], ocrScheduled: Set(OCRRegionKey.productionOCRCases), force: true)
                self.updateFrameDeliveryPolicy(force: true)
            }
            await self.requestCaptureForRoleIfNeeded(.ocr, reason: "deferred OCR promotion: \(reason)")
        }
    }

    private func requestOCRCaptureForLiveIfStillNeeded() async {
        guard currentScreen == .live || currentScreen == .broadcast else { return }
        guard (usesScoreboardCameraInput || isBroadcastOCRKeepaliveExpected),
              userWantsOCRRunning,
              !isOCRPaused else { return }
        await requestCaptureForRoleIfNeeded(.ocr, reason: "live OCR assertion")
        updateFrameDeliveryPolicy(force: true)
    }

    private func requestDeferredSecondaryCapture(after primaryRole: CameraRole) async {
        let secondaryRole: CameraRole
        switch primaryRole {
        case .live: secondaryRole = .ocr
        case .ocr: secondaryRole = .live
        }
        await requestCaptureForRoleIfNeeded(secondaryRole, reason: "deferred secondary CaptureEngine assertion")
    }

    private func requestCaptureForRoleIfNeeded(
        _ role: CameraRole,
        reason: String? = nil
    ) async {
        let roleText = role == .live ? "Broadcast" : "OCR"
        let mode = desiredCaptureMode(for: role)
        let request = captureRequest(
            for: mode,
            reason: reason ?? "UX16c42 ensure \(roleText) screen=\(currentScreen.rawValue)"
        )
        let requiresSubmission = captureLifecycleController.shouldSubmitReconciliation(for: request)
        if requiresSubmission {
            cameraForensicBreadcrumb(
                .lifecycle,
                phase: "CaptureEngine desired contract changed",
                extra: "role=\(roleText) mode=\(mode.rawValue)"
            )
        } else {
            cameraForensicBreadcrumb(
                .lifecycle,
                phase: "CaptureEngine desired contract acknowledgement joined",
                extra: "role=\(roleText) mode=\(mode.rawValue)"
            )
        }
        // `ensure` is also the physical acknowledgement boundary. An identical
        // request may join the route-owned transaction, but it must not return to
        // Image Relay as though a still-reconciling graph were a terminal failure.
        let outcome = await captureLifecycleController.ensure(request)
        applyCaptureLifecycleOutcome(outcome)
    }

    private func preloadConfigurationCameraDiscoveryIfNeeded(reason: String) {
        guard !hasRequestedConfigurationCameraDiscovery else { return }
        hasRequestedConfigurationCameraDiscovery = true
        liveCameraService.refreshAvailableCameras(reason: "configuration preload: \(reason)")
        ocrCameraService.refreshAvailableCameras(reason: "configuration preload: \(reason)")
    }

    // MARK: - v0.8.0.0 Operator OCR Tuning

    private func applyOperatorOCRSettings(reason: String) {
        let snapshot = makeOperatorTuningSnapshot()
        ocrTuningSnapshot = snapshot

        // Keep legacy threshold values populated for the existing OCR processor.
        // Operators no longer tune these directly during normal use.
        ocrThresholds.clock = snapshot.clock.confidence
        ocrThresholds.score = snapshot.score.confidence
        ocrThresholds.period = snapshot.period.confidence
        ocrThresholds.penaltyPlayer = snapshot.penaltyPlayer.confidence
        ocrThresholds.penaltyTime = snapshot.penaltyTime.confidence

        // Legacy global cadence remains for debug export/backwards-compatible UI, but
        // actual scheduling uses the per-zone snapshot and the clock-state scheduler.
        ocrIntervalSeconds = snapshot.clock.cadenceSeconds
        ocrAssistStatusText = "\(reason): \(ocrOperatorMode.title), \(ocrScoreboardType.title). Scheduler remains clock-state gated."
    }

    private func makeOperatorTuningSnapshot() -> OCROperatorTuningSnapshot {
        func tuned(_ base: OCRZoneTuning, preset: OCRZoneReadingPreset) -> OCRZoneTuning {
            var cadence = base.cadenceSeconds
            var confidence = base.confidence

            switch preset {
            case .responsive:
                cadence *= 0.75
                confidence -= 0.05
            case .balanced:
                break
            case .stable:
                cadence *= 1.35
                confidence += 0.05
            }

            cadence *= ocrOperatorMode.cadenceMultiplier
            cadence *= ocrScoreboardType.cadenceMultiplier
            confidence += ocrOperatorMode.confidenceAdjustment
            confidence += ocrScoreboardType.confidenceAdjustment

            if autoOCRAssistEnabled {
                // v0.8.0.0 initial safe-bounds assist. Future versions can feed this
                // from measured brightness/contrast and invalid-read rates.
                confidence = min(max(confidence, 0.55), 0.90)
                cadence = min(max(cadence, 0.35), 5.0)
            } else {
                confidence = min(max(confidence, 0.50), 0.95)
                cadence = min(max(cadence, 0.30), 6.0)
            }

            return OCRZoneTuning(cadenceSeconds: cadence, confidence: confidence, trust: base.trust)
        }

        return OCROperatorTuningSnapshot(
            clock: tuned(OCRZoneTuning(cadenceSeconds: 0.7, confidence: 0.65, trust: 1), preset: clockReadingPreset),
            score: tuned(OCRZoneTuning(cadenceSeconds: 1.5, confidence: 0.80, trust: 3), preset: scoreReadingPreset),
            period: tuned(OCRZoneTuning(cadenceSeconds: 3.0, confidence: 0.75, trust: 1), preset: .balanced),
            penaltyTime: tuned(OCRZoneTuning(cadenceSeconds: 0.8, confidence: 0.70, trust: 1), preset: penaltyReadingPreset),
            penaltyPlayer: tuned(OCRZoneTuning(cadenceSeconds: 0.8, confidence: 0.70, trust: 2), preset: penaltyReadingPreset)
        )
    }

    private var motionProtectionHashKeys: Set<OCRRegionKey> {
        var keys: Set<OCRRegionKey> = [.clock, .homeScore, .awayScore]
        keys.formUnion(penaltyPlayerRegionKeys)
        return keys
    }

    private func movementScore(from hashes: [OCRRegionKey: UInt64]) -> Int {
        var total = 0
        var compared = 0
        for (key, hash) in hashes {
            if let previous = previousMotionHashes[key] {
                total += hammingDistance(previous, hash)
                compared += 1
            }
            previousMotionHashes[key] = hash
        }
        guard compared > 0 else { return 0 }
        return total / compared
    }

    private func updateOCRMotionProtection(active: Bool, score: Int = 0, force: Bool = false) {
        // Motion protection state is operationally useful, but publishing it while
        // Broadcast is on air creates extra view-model invalidations. The OCR gate
        // itself still runs; only the diagnostic UI text is suppressed off Calibration.
        guard shouldPublishOCRDiagnostics else { return }

        let now = CFAbsoluteTimeGetCurrent()
        guard force || active != ocrMotionProtectionActive || now - lastOCRMotionProtectionPublishAt >= 1.0 else { return }
        lastOCRMotionProtectionPublishAt = now
        ocrMotionProtectionActive = active
        ocrMotionProtectionStatusText = active
            ? "OCR camera movement protection active: OCR camera movement detected, OCR backed off to keep Live smooth."
            : "OCR camera movement protection idle"
        if active {
            statusMessage = "OCR movement protection active (score \(score))."
        }
    }


    // MARK: - v0.8.8m7 Central OCR Scheduler Bridge

    private func schedulerGameState(
        now: CFAbsoluteTime,
        regionChangeState: OCRRegionChangeState = .unknown
    ) -> OCRGameState {
        OCRGameState(
            activeScreen: currentScreen,
            clockIsRunning: localClockIsRunning,
            clockIsConfirmedStopped: hasConfirmedStoppedClock(now: now),
            manualModeEnabled: operatingMode == .manual || manualOverrideEnabled,
            debugModeEnabled: isDebugVisible,
            diagnosticsVisible: shouldPublishOCRDiagnostics,
            calibrationVisible: currentScreen == .calibration,
            performanceSafeModeEnabled: performanceSafeModeEnabled,
            motionProtectionActive: now < ocrMotionProtectionUntil,
            hasActivePenaltyOCRWork: hasActivePenaltyOCRWork,
            regionChangeState: regionChangeState
        )
    }

    private func schedulerRegionChangeState(from hashes: [OCRRegionKey: UInt64]) -> OCRRegionChangeState {
        // Hashes are only present for watched regions. Treat presence of a hash as a
        // lightweight changed/interesting hint; the existing visual hash functions
        // still decide exact score/period/penalty scheduling below. This keeps m7
        // as a scheduling layer, not a hashing rewrite.
        guard !hashes.isEmpty else { return .unknown }
        return OCRRegionChangeState(
            clockChanged: hashes[.clock] != nil,
            scoreChanged: hashes[.homeScore] != nil || hashes[.awayScore] != nil,
            periodChanged: hashes[.period] != nil,
            penaltyChanged: hashes[.homePenalty1Time] != nil || hashes[.homePenalty2Time] != nil || hashes[.awayPenalty1Time] != nil || hashes[.awayPenalty2Time] != nil,
            playerNumberChanged: hashes[.homePenalty1Player] != nil || hashes[.homePenalty2Player] != nil || hashes[.awayPenalty1Player] != nil || hashes[.awayPenalty2Player] != nil
        )
    }

    private func centralSchedulerAllowedKeys(now: CFAbsoluteTime, hashes: [OCRRegionKey: UInt64]) -> Set<OCRRegionKey> {
        let schedulerState = schedulerGameState(
            now: now,
            regionChangeState: schedulerRegionChangeState(from: hashes)
        )
        let allowed = ocrScheduler.allowedKeys(
            now: now,
            state: schedulerState,
            activePenaltyTimeKeys: Set(activeConfirmedPenaltyTimeRegionKeys),
            allPenaltyTimeKeys: Set(allPenaltyTimeRegionKeys),
            penaltyPlayerKeys: Set(penaltyPlayerRegionKeys)
        )
        let mode = ocrScheduler.mode
        if mode != lastOCRSchedulerMode {
            lastOCRSchedulerMode = mode
            appendSchedulerDiagnostic("mode -> \(mode.rawValue)")
            MainThreadStallMonitor.shared.traceOCRPhase("scheduler mode -> \(mode.rawValue) screen=\(currentScreen.rawValue) clockRunning=\(localClockIsRunning) manual=\(operatingMode == .manual || manualOverrideEnabled)")
        }
        return allowed
    }

    // Running/unknown clock-mode indicator retained for scheduler decisions.
    // UX16d2e no longer uses this as a blanket field gate: live score, period and
    // penalty hashes continue watching for exact changed zones while it is true.
    private func shouldRunClockOnlyOCR(now: CFAbsoluteTime) -> Bool {
        if calibrationPhaseOverrideActive && currentScreen == .calibration && calibrationPreviewMountAllowedW10F {
            return false
        }
        if ocrStartupClockBootstrapActive { return true }

        // The central scheduler owns mode calculation. A true result means
        // running/unknown play; it no longer means that event-zone hashing is off.
        _ = ocrScheduler.updateMode(now: now, state: schedulerGameState(now: now))
        return !hasConfirmedStoppedClock(now: now)
    }

    private func hasConfirmedStoppedClock(now: CFAbsoluteTime) -> Bool {
        if trustedClockAnchorSeconds != nil {
            return trustedClockConfirmedStopped
        }
        return gameEventDetector.hasConfirmedStoppedClock(
            lastObservedClockOCRSeconds: lastObservedClockOCRSeconds,
            repeatedClockOCRReadCount: repeatedClockOCRReadCount,
            candidateStartedAt: clockStopCandidateStartedAt,
            lastClockMovementObservedAt: lastClockMovementObservedAt,
            lastClockOCRConfirmationAt: lastClockOCRConfirmationAt,
            now: now,
            minimumRepeatCount: stoppedClockMinimumRepeatCount,
            minimumConfirmationDuration: stoppedClockMinimumConfirmationDuration,
            movementCooldown: stoppedClockMovementCooldown,
            safetyOCRInterval: stoppedClockSafetyOCRInterval
        )
    }

    private func processorAllowedOCRKeys(scheduledKeys: Set<OCRRegionKey>) -> Set<OCRRegionKey> {
        // UX16d2e: the processor receives exactly the keys admitted by the live
        // scheduler. This keeps the processor gate authoritative without restoring
        // the obsolete blanket clock-only rule.
        scheduledKeys.intersection(Set(OCRRegionKey.productionOCRCases))
    }

    private func appendSchedulerDiagnostic(_ message: String) {
        guard isDebugVisible, !freezeDebugSnapshot else { return }
        let stamped = "[\(Date().formatted(date: .omitted, time: .standard))]\nscheduler: \(message)"
        debugHistory.append(stamped)
        if debugHistory.count > 40 {
            debugHistory.removeFirst(debugHistory.count - 40)
        }
    }

    private func appendSchedulerMetricsDiagnostic(_ message: String, now: CFAbsoluteTime, force: Bool = false) {
        guard force || now - lastSchedulerMetricsDiagnosticAt >= 1.0 else { return }
        lastSchedulerMetricsDiagnosticAt = now
        appendSchedulerDiagnostic(message)
    }

    private func schedulerKeyList(_ keys: Set<OCRRegionKey>) -> String {
        let ordered: [OCRRegionKey] = [
            .clock,
            .homeScore, .awayScore,
            .period,
            .homePenalty1Player, .homePenalty1Time,
            .homePenalty2Player, .homePenalty2Time,
            .awayPenalty1Player, .awayPenalty1Time,
            .awayPenalty2Player, .awayPenalty2Time
        ]
        let names = ordered.filter { keys.contains($0) }.map { $0.rawValue }
        return names.isEmpty ? "none" : names.joined(separator: ",")
    }

    private func orderedPendingPhysicalBaselineKeys(
        from pending: Set<OCRRegionKey>
    ) -> [OCRRegionKey] {
        // Clock publication has its own physical-board authority. The baseline
        // reservation is exclusively for the static fields that can otherwise
        // remain stuck behind Smart Change Detection after startup/reconfiguration.
        let order: [OCRRegionKey] = [.homeScore, .awayScore, .period]
        return order.filter { pending.contains($0) }
    }

    private func resetOCRBaselineReservationSchedule() {
        ocrBoundedFieldCursor = 0
        liveOCRPriorityVerificationUntil.removeAll()
        clearImmediateClockConfirmation(reason: "OCR control-plane reset", resumeStatic: false)
        liveOCRPassSequence = 0
        trustedClockLiveContinuationCount = 0
        fullBoardResetRecovery.reset()
        lastTestOCRAcceptedValue.removeAll()
        lastTestOCRFrameSequence.removeAll()
        let now = CFAbsoluteTimeGetCurrent()
        ocrControlPlane.reset(
            generation: externalOCRMultiCamCoordinator.snapshot.transitionGeneration,
            now: now,
            reason: "OCR baseline/control state reset"
        )
        activeProductionOCRPlan = nil
    }

    private func requestImmediateClockConfirmation(seconds: Int, now: CFAbsoluteTime) {
        let withinExistingWindow = liveOCRClockConfirmationCandidateSeconds != nil
            && now <= liveOCRClockConfirmationUntil
        if !withinExistingWindow {
            liveOCRClockConfirmationUntil = now + liveOCRClockConfirmationWindow
            liveOCRClockConfirmationPassesRemaining = liveOCRClockConfirmationMaximumPasses
        }
        liveOCRClockConfirmationCandidateSeconds = seconds
        appendSchedulerDiagnostic(
            "Build 522 sticky Clock confirmation requested candidate=\(formatClock(seconds: seconds)) remaining=\(liveOCRClockConfirmationPassesRemaining) until=\(String(format: "%.2f", liveOCRClockConfirmationUntil))"
        )
    }

    private func hasImmediateClockConfirmation(now: CFAbsoluteTime) -> Bool {
        guard liveOCRClockConfirmationPassesRemaining > 0,
              now <= liveOCRClockConfirmationUntil else {
            if liveOCRClockConfirmationPassesRemaining > 0 || liveOCRClockConfirmationCandidateSeconds != nil {
                clearImmediateClockConfirmation(reason: "bounded confirmation expired", resumeStatic: true)
            }
            return false
        }
        return true
    }

    private func consumeImmediateClockConfirmationPass(now: CFAbsoluteTime) {
        guard hasImmediateClockConfirmation(now: now) else { return }
        liveOCRClockConfirmationPassesRemaining = max(0, liveOCRClockConfirmationPassesRemaining - 1)
        appendSchedulerDiagnostic(
            "Build 522 sticky Clock confirmation pass admitted candidate=\(liveOCRClockConfirmationCandidateSeconds.map(formatClock) ?? "unknown") remaining=\(liveOCRClockConfirmationPassesRemaining)"
        )
    }

    private func clearImmediateClockConfirmation(reason: String, resumeStatic: Bool) {
        let hadPending = liveOCRClockConfirmationPassesRemaining > 0
            || liveOCRClockConfirmationCandidateSeconds != nil
        liveOCRClockConfirmationUntil = 0
        liveOCRClockConfirmationPassesRemaining = 0
        liveOCRClockConfirmationCandidateSeconds = nil
        _ = resumeStatic
        if hadPending {
            appendSchedulerDiagnostic("Build 522 sticky Clock confirmation cleared reason=\(reason)")
        }
    }

    private func activeLiveOCRPriorityVerificationKeys(
        now: CFAbsoluteTime
    ) -> Set<OCRRegionKey> {
        liveOCRPriorityVerificationUntil = liveOCRPriorityVerificationUntil.filter { $0.value > now }
        // Build 533: the reducer confirmation memory is authoritative. A field
        // remains priority work until that memory actually resolves or expires;
        // admitting one OCR job must not consume the only retry opportunity.
        return Set(liveOCRPriorityVerificationUntil.keys)
            .union(ocrPublicationSafetyState.pendingPriorityVerificationKeys)
    }

    private func updateLiveOCRPriorityVerification(
        newlyPending: Set<OCRRegionKey>,
        resolved: Set<OCRRegionKey>,
        now: CFAbsoluteTime
    ) {
        for key in resolved {
            liveOCRPriorityVerificationUntil.removeValue(forKey: key)
        }
        for key in newlyPending {
            liveOCRPriorityVerificationUntil[key] = now + liveOCRPriorityVerificationWindow
        }
    }

    private func boundedOCRKeysForPass(
        _ requested: Set<OCRRegionKey>,
        maximumFields: Int
    ) -> Set<OCRRegionKey> {
        let maximumFields = max(1, maximumFields)
        guard requested.count > maximumFields else { return requested }

        var selected: [OCRRegionKey] = []
        if requested.contains(.clock) {
            selected.append(.clock)
        }
        let rotatingOrder: [OCRRegionKey] = [
            .homeScore, .awayScore, .period,
            .homePenalty1Player, .homePenalty1Time,
            .awayPenalty1Player, .awayPenalty1Time,
            .homePenalty2Player, .homePenalty2Time,
            .awayPenalty2Player, .awayPenalty2Time
        ]
        let available = rotatingOrder.filter { requested.contains($0) }
        guard !available.isEmpty else { return Set(selected.prefix(maximumFields)) }
        let start = ocrBoundedFieldCursor % available.count
        var offset = 0
        while selected.count < maximumFields && offset < available.count {
            selected.append(available[(start + offset) % available.count])
            offset += 1
        }
        ocrBoundedFieldCursor = (start + max(1, offset)) % available.count
        return Set(selected)
    }

    private func schedulerHashList(_ hashes: [OCRRegionKey: UInt64]) -> String {
        guard !hashes.isEmpty else { return "none" }
        return hashes.keys.map { $0.rawValue }.sorted().joined(separator: ",")
    }

    private func verifiedSchedulerKeys(_ keys: Set<OCRRegionKey>, now: CFAbsoluteTime) -> Set<OCRRegionKey> {
        // UX16d2e: running play is clock-first, not clock-only. Exact live event
        // keys have already passed hash-change and cadence policy before arriving
        // here; retain them and let the processor enforce this exact set.
        _ = now
        return keys.intersection(Set(OCRRegionKey.productionOCRCases))
    }

    private func rawClockShowsMovement(_ rawClock: String?) -> Bool {
        guard let rawClock,
              let rawSeconds = seconds(from: rawClock),
              let previousSeconds = lastObservedClockOCRSeconds,
              rawSeconds != previousSeconds else { return false }

        let delta = rawSeconds - previousSeconds
        // Plausible countdown/count-up movement means the current frame is during
        // running play. Larger jumps are treated as resets/corrections and do not
        // automatically discard the stopped-clock window.
        return abs(delta) <= 8
    }

    private func discardNonClockValuesBecauseClockMoved(rawClock: String?, previous: ScoreboardState, candidate: inout ScoreboardState) {
        guard rawClockShowsMovement(rawClock) else { return }
        _ = previous
        _ = candidate
        // UX16d2e: a moving clock no longer destroys hash-triggered score or
        // penalty observations. Those observations still cannot become public
        // until the field-specific publication safety policy confirms them.
        appendSchedulerDiagnostic("merge -> raw clock moved; exact hash-triggered live event observations retained for publication safety")
    }

    nonisolated private static func isActivePenaltyClock(_ value: String?) -> Bool {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "--:--" && trimmed != "0:00" && trimmed != "00:00"
    }

    private struct PreparedContinuousOCRFrame: @unchecked Sendable {
        let passToken: RinkLensOCRPassToken
        let processingGeneration: Int
        let layout: ScoreboardOCRLayout
        let boardCalibration: BoardCalibrationQuad
        let motionKeys: Set<OCRRegionKey>
        let hashKeys: Set<OCRRegionKey>
        let thresholds: OCRThresholds
        let enableSegmentedFallback: Bool
        let previewSize: CGSize
        let scoreboardTemplate: RinkScoreboardTemplate
        let orientation: UIDeviceOrientation
        let previewRotationDegrees: CGFloat
        let admittedAt: CFAbsoluteTime
    }

    /// Recovery AI / RL-073: MainActor frame admission is value-only. It decides
    /// whether the current frame should do Image Relay or OCR work and captures
    /// immutable configuration, but it never receives the FrameHub CVPixelBuffer.
    /// The returned worker runs on ScoreboardFramePipeline's capacity-one queue.
    private func prepareScoreboardFrameWork(
        identity: ScoreboardFrameIdentity
    ) -> ScoreboardFramePipeline.PreparedFrameWork? {
        if !hasConfirmedMainThreadFrameHandoff {
            hasConfirmedMainThreadFrameHandoff = true
            ocrFrameHandoffStatusText = "OCR FrameHub ingress confirmed; full-frame admission bounded before MainActor"
            RinkLensStructuredEventLogger.shared.record(
                domain: .ocr,
                event: "ocr_frame_delivery_started",
                entityID: "ocr",
                previous: ["delivery": "awaiting", "sequence": "0"],
                next: [
                    "delivery": "active",
                    "sequence": String(identity.sequence),
                    "captureGeneration": String(identity.captureGeneration),
                    "physicalDeviceID": identity.physicalDeviceID ?? "none",
                    "size": identity.sizeText,
                    "frameOwnershipBoundary": "ScoreboardFramePipeline-before-MainActor"
                ],
                source: "RinkLensFrameHub OCR latest-frame consumer",
                reason: "Recovery AI moved capacity-one frame admission ahead of MainActor"
            )
            MainThreadStallMonitor.shared.traceCameraStartupTimeline(
                RinkLensBuildInfo.traceContext("Recovery AI first OCR FrameHub frame admitted before MainActor")
            )
        }

        guard usesScoreboardCameraInput else { return nil }
        guard !isScreenTransitioning else { return nil }

        // Recovery AI / RL-075: decorative Calibration Raw/Proc/Thresh generation
        // is no longer driven by every continuous camera frame. The live preview
        // layer and zones remain mounted; explicit Test OCR/colour actions own the
        // expensive crop/image work.

        if operatingMode == .imageRelay {
            let sourceMonotonicTime = CFAbsoluteTimeGetCurrent() - identity.ageSeconds
            var acceptedPenaltyPlayers: Set<OCRRegionKey> = []
            if (state.homePenalty1Player ?? 0) > 0 || Self.isActivePenaltyClock(state.homePenalty1Clock) {
                acceptedPenaltyPlayers.insert(.homePenalty1Player)
            }
            if (state.homePenalty2Player ?? 0) > 0 || Self.isActivePenaltyClock(state.homePenalty2Clock) {
                acceptedPenaltyPlayers.insert(.homePenalty2Player)
            }
            if (state.awayPenalty1Player ?? 0) > 0 || Self.isActivePenaltyClock(state.awayPenalty1Clock) {
                acceptedPenaltyPlayers.insert(.awayPenalty1Player)
            }
            if (state.awayPenalty2Player ?? 0) > 0 || Self.isActivePenaltyClock(state.awayPenalty2Clock) {
                acceptedPenaltyPlayers.insert(.awayPenalty2Player)
            }

            let configuration = ScoreboardFrameRelayConfiguration(
                layout: ocrLayout,
                colourProfiles: ocrColourProfiles,
                boardCalibration: boardCalibration,
                previewSize: authoritativeOCRGeometryViewportSize,
                previewRotationDegrees: ocrPreviewRotationOffsetDegrees,
                viewerAcceptedPenaltyPlayers: acceptedPenaltyPlayers,
                homeRosterNumbers: homeRosterNumberProjection,
                sourceObservedAt: identity.capturedAt,
                sourceMonotonicTime: sourceMonotonicTime
            )
            let relayEngine = imageRelayEngine
            return { frame in
                relayEngine.submitOwnedFromPipeline(
                    pixelBuffer: frame.pixelBuffer,
                    sourceSequence: frame.sequence,
                    captureGeneration: frame.captureGeneration,
                    layout: configuration.layout,
                    colourProfiles: configuration.colourProfiles,
                    boardCalibration: configuration.boardCalibration,
                    previewSize: configuration.previewSize,
                    previewRotationDegrees: configuration.previewRotationDegrees,
                    viewerAcceptedPenaltyPlayers: configuration.viewerAcceptedPenaltyPlayers,
                    homeRosterNumbers: configuration.homeRosterNumbers,
                    sourceObservedAt: configuration.sourceObservedAt,
                    sourceMonotonicTime: configuration.sourceMonotonicTime
                )
            }
        }

        // OCR recognition path. All policy/state decisions happen here using
        // value-only frame identity. Pixel ownership copy begins only after this
        // method returns to the non-main frame pipeline.
        guard operatingMode == .ocr else { return nil }
        guard canProcessOCRFrame else { return nil }
        guard !selectedZoneTestOCRRequestPending, !selectedZoneTestOCRInFlight else { return nil }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastOCRAt >= activeOCRInterval else { return nil }

        let orchestration = ocrOrchestrationEngine.snapshot()
        let stallLimit = max(1.20, activeOCRInterval * 2.5)
        if orchestration.isBusy {
            if let age = orchestration.activePassAgeSeconds,
               age >= stallLimit,
               ocrOrchestrationEngine.recoverStalledPass(
                maximumAge: stallLimit,
                reason: String(format: "continuous OCR pass exceeded %.1fs", stallLimit)
               ) {
                let blockedText = String(
                    format: "UX16d4 core OCR recovered stage=%@ after %.2fs; stale work fenced and new admission released.",
                    orchestration.activeProcessorStage,
                    age
                )
                appendSchedulerDiagnostic(blockedText)
                smartChangeLastDecisionText = blockedText
                ocrDiagnostics.recordPublicationSummary(flow: .continuousBroadcast, summary: blockedText)
                MainThreadStallMonitor.shared.traceOCRPhase(blockedText)
            }
            droppedOCRFrameCount += 1
            return nil
        } else if isProcessing {
            isProcessing = false
            appendSchedulerDiagnostic("UX16d2a repaired stale ViewModel OCR busy flag; the single executor is idle.")
            MainThreadStallMonitor.shared.traceOCRPhase("UX16d2a repaired busy flag without active token")
        }

        guard let passToken = ocrOrchestrationEngine.tryBeginPass(purpose: "continuous-frame") else {
            droppedOCRFrameCount += 1
            return nil
        }

        lastOCRAt = now
        isProcessing = true
        if ocrDiagnostics.lastPublicationSummary.contains("Waiting for a fresh OCR frame") {
            let acceptedText = "Fresh OCR frame #\(identity.sequence) accepted by worker \(ocrOrchestrationEngine.snapshot().activeWorkerID); processing started."
            ocrDiagnostics.recordPublicationSummary(flow: .continuousBroadcast, summary: acceptedText)
            smartChangeLastDecisionText = acceptedText
        }

        let currentLayout = ocrLayout
        let clockOnlySchedulerActive = shouldRunClockOnlyOCR(now: now)
        let usesSchedulerHashing = smartChangeDetectionEnabled
            && (currentScreen == .live || currentScreen == .broadcast)
            && !calibrationPhaseOverrideActive
        var hashedKeys = Set<OCRRegionKey>()
        if usesSchedulerHashing {
            hashedKeys.insert(.clock)
            hashedKeys.formUnion([.homeScore, .awayScore, .period])
            hashedKeys.formUnion(penaltyPlayerRegionKeys)
            hashedKeys.formUnion(activeConfirmedPenaltyTimeRegionKeys)
        }

        appendSchedulerMetricsDiagnostic(
            "frame -> gate: clockOnly=\(clockOnlySchedulerActive) localClockRunning=\(localClockIsRunning) startupBootstrap=\(ocrStartupClockBootstrapActive) smartHash=\(usesSchedulerHashing) hashWatch=[\(schedulerKeyList(hashedKeys))]",
            now: now
        )

        let prepared = PreparedContinuousOCRFrame(
            passToken: passToken,
            processingGeneration: ocrProcessingGeneration,
            layout: currentLayout,
            boardCalibration: boardCalibration,
            motionKeys: motionProtectionHashKeys,
            hashKeys: usesSchedulerHashing ? hashedKeys : [],
            thresholds: ocrThresholds,
            enableSegmentedFallback: enableSegmentedFallback,
            previewSize: authoritativeOCRGeometryViewportSize,
            scoreboardTemplate: activeOCRScoreboardTemplate,
            orientation: .landscapeLeft,
            previewRotationDegrees: ocrPreviewRotationOffsetDegrees,
            admittedAt: now
        )
        let orchestrationEngine = ocrOrchestrationEngine

        return { [weak self, orchestrationEngine, prepared] frame in
            guard let frameLease = orchestrationEngine.makeFrameLeaseAdoptingOwnedBuffer(
                pixelBuffer: frame.pixelBuffer,
                generation: prepared.processingGeneration,
                passToken: prepared.passToken,
                sourceSequence: frame.sequence,
                captureGeneration: frame.captureGeneration,
                sourceDescription: "Recovery AI continuous OCR post-ingress source"
            ) else {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.isProcessing = false
                        self.droppedOCRFrameCount += 1
                        let copyFailure = "Recovery AI ingress-owned OCR frame was rejected after bounded admission; FrameHub lease was not queued on MainActor."
                        self.appendSchedulerDiagnostic(copyFailure)
                        self.smartChangeLastDecisionText = copyFailure
                        self.ocrDiagnostics.recordPublicationSummary(flow: .continuousBroadcast, summary: copyFailure)
                    }
                }
                return
            }

            orchestrationEngine.analyzeFrame(
                frame: frameLease,
                layout: prepared.layout,
                boardCalibration: prepared.boardCalibration,
                motionKeys: prepared.motionKeys,
                hashKeys: prepared.hashKeys,
                deviceOrientation: prepared.orientation,
                previewSize: prepared.previewSize,
                previewRotationDegrees: prepared.previewRotationDegrees
            ) { [weak self, prepared] analysis in
                DispatchQueue.main.async { [weak self, prepared] in
                    MainActor.assumeIsolated {
                        self?.continueProcessingAfterHash(
                            frameLease: analysis.frame,
                            layout: prepared.layout,
                            hashes: analysis.hashes,
                            motionHashes: analysis.motionHashes,
                            now: prepared.admittedAt,
                            thresholds: prepared.thresholds,
                            enableSegmentedFallback: prepared.enableSegmentedFallback,
                            previewSize: prepared.previewSize,
                            boardCalibration: prepared.boardCalibration,
                            scoreboardTemplate: prepared.scoreboardTemplate,
                            orientation: prepared.orientation,
                            previewRotationDegrees: prepared.previewRotationDegrees,
                            generation: prepared.processingGeneration
                        )
                    }
                }
            }
        }
    }

    private func continueProcessingAfterHash(
        frameLease: RinkLensOCRFrameLease,
        layout: ScoreboardOCRLayout,
        hashes: [OCRRegionKey: UInt64],
        motionHashes: [OCRRegionKey: UInt64],
        now: CFAbsoluteTime,
        thresholds: OCRThresholds,
        enableSegmentedFallback: Bool,
        previewSize: CGSize,
        boardCalibration: BoardCalibrationQuad,
        scoreboardTemplate: RinkScoreboardTemplate,
        orientation: UIDeviceOrientation,
        previewRotationDegrees: CGFloat,
        generation: Int
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.continueProcessingAfterHash(
                    frameLease: frameLease,
                    layout: layout,
                    hashes: hashes,
                    motionHashes: motionHashes,
                    now: now,
                    thresholds: thresholds,
                    enableSegmentedFallback: enableSegmentedFallback,
                    previewSize: previewSize,
                    boardCalibration: boardCalibration,
                    scoreboardTemplate: scoreboardTemplate,
                    orientation: orientation,
                    previewRotationDegrees: previewRotationDegrees,
                    generation: generation
                )
            }
            return
        }
        guard ocrOrchestrationEngine.isPassCurrent(frameLease.passToken) else { return }
        guard generation == ocrProcessingGeneration else {
            if ocrOrchestrationEngine.finishPass(token: frameLease.passToken, reason: "stale-generation") {
                isProcessing = false
            }
            return
        }
        let broadcastBackgroundOCRAllowed = currentScreen == .broadcast && userWantsOCRRunning
        guard (operatingMode == .ocr || broadcastBackgroundOCRAllowed), canProcessOCRFrame else {
            if ocrOrchestrationEngine.finishPass(token: frameLease.passToken, reason: "processing-no-longer-allowed") {
                isProcessing = false
            }
            return
        }

        let movement = movementScore(from: motionHashes)
        // This movement check is based only on the stationary OCR camera frame.
        // Live/Broadcast iPad movement must not feed OCR motion protection.
        let motionThreshold = currentScreen == .broadcast ? 12 : 18
        let motionProtectionHold: CFTimeInterval = currentScreen == .broadcast ? 3.0 : 2.5
        if now < ignoreOCRMotionProtectionUntil {
            updateOCRMotionProtection(active: false, score: movement)
        } else if movement >= motionThreshold {
            // v0.8.3e: Broadcast uses a more sensitive OCR-camera motion gate.
            // Because Broadcast OCR is sampled less often, even a small tripod bump
            // should pause OCR before Vision/hash work tries to read a blurred frame.
            ocrMotionProtectionUntil = now + motionProtectionHold
            updateOCRMotionProtection(active: true, score: movement)
            updateRegionDetectionStates(watchedByHashing: [], ocrScheduled: [], force: true)
            if ocrOrchestrationEngine.finishPass(token: frameLease.passToken, reason: "motion-protection") {
                isProcessing = false
            }
            return
        } else if now >= ocrMotionProtectionUntil {
            updateOCRMotionProtection(active: false, score: movement)
        }

        appendSchedulerMetricsDiagnostic(
            "hash -> complete: motionHash=[\(schedulerHashList(motionHashes))] stoppedHash=[\(schedulerHashList(hashes))] clockOnly=\(shouldRunClockOnlyOCR(now: now))",
            now: now
        )

        // Build 556: the Build 551 production control plane follows OCR intent,
        // not the visible route. Explicit Test OCR remains a separate one-shot flow.
        let runningEventWatch = operatingMode == .ocr && userWantsOCRRunning && !isOCRPaused

        var scheduledKeys: Set<OCRRegionKey>
        var keysToProcess: Set<OCRRegionKey>
        var baselineReservationPass = false
        var priorityVerificationPass = false

        if runningEventWatch {
            let visualChangeKeys = productionOCRVisualSignalKeys(now: now, hashes: hashes)
            let pendingBaselineKeys = Set(
                orderedPendingPhysicalBaselineKeys(
                    from: ocrPublicationSafetyState.pendingBaselineKeys
                )
            )
            let pendingPenaltyBaselineKeys = ocrPublicationSafetyState.pendingPenaltyBaselineKeys
            let publicationPriorityKeys = activeLiveOCRPriorityVerificationKeys(now: now)
            let resetRecoveryKeys = fullBoardResetRecoveryPriorityKeys(now: now)
            let activePenaltyKeys = productionActivePenaltyKeys()
            let clockConfirmationRequired = hasImmediateClockConfirmation(now: now)
            let plan = ocrControlPlane.nextPlan(
                signals: OCRWorkScheduler.Signals(
                    generation: frameLease.captureGeneration,
                    now: now,
                    performanceSafeMode: performanceSafeModeEnabled,
                    startupClockBootstrap: ocrStartupClockBootstrapActive,
                    clockConfirmationRequired: clockConfirmationRequired,
                    trustedClockRunning: localClockIsRunning && !trustedClockConfirmedStopped,
                    confirmedStoppedClock: trustedClockConfirmedStopped,
                    pendingBaselineKeys: pendingBaselineKeys,
                    pendingPenaltyBaselineKeys: pendingPenaltyBaselineKeys,
                    publicationPriorityKeys: publicationPriorityKeys,
                    resetRecoveryKeys: resetRecoveryKeys,
                    visualChangeKeys: visualChangeKeys,
                    activePenaltyKeys: activePenaltyKeys
                )
            )
            activeProductionOCRPlan = plan
            RinkLensOCRReplayGateController.shared.recordPlan(
                plan,
                frameID: frameLease.sourceSequence,
                captureGeneration: frameLease.captureGeneration,
                pendingBaseline: pendingBaselineKeys,
                pendingPenaltyBaseline: pendingPenaltyBaselineKeys,
                visualChanges: visualChangeKeys,
                publicationPriority: publicationPriorityKeys,
                resetRecovery: resetRecoveryKeys,
                activePenalty: activePenaltyKeys,
                visibleState: state
            )
            if plan.keys.contains(.clock), clockConfirmationRequired {
                consumeImmediateClockConfirmationPass(now: now)
            }
            scheduledKeys = plan.keys
            keysToProcess = plan.keys
            baselineReservationPass = !plan.keys.contains(.clock)
            priorityVerificationPass = plan.priority >= .publicationConfirmation

            updateRegionDetectionStates(
                watchedByHashing: Set([OCRRegionKey.homeScore, .awayScore, .period])
                    .union(penaltyPlayerRegionKeys)
                    .union(activeConfirmedPenaltyTimeRegionKeys),
                ocrScheduled: keysToProcess
            )
            updatePixelHashingStatus(
                true,
                detail: "UX16d16 single control plane selected \(plan.unit.diagnosticName): \(plan.reason)."
            )
            liveOCRPassSequence &+= 1
            let sourceFrame = frameLease.sourceSequence.map { String($0) } ?? "unknown"
            MainThreadStallMonitor.shared.traceOCRPhase(
                "UX16d16 control-plane admitted pass#\(liveOCRPassSequence) frame=#\(sourceFrame) captureGeneration=\(frameLease.captureGeneration) \(plan.diagnosticText) pendingBaseline=[\(schedulerKeyList(pendingBaselineKeys))] pendingPenaltyBaseline=[\(schedulerKeyList(pendingPenaltyBaselineKeys))] visual=[\(schedulerKeyList(visualChangeKeys))] publicationPriority=[\(schedulerKeyList(publicationPriorityKeys))] reset=[\(schedulerKeyList(resetRecoveryKeys))] activePenalty=[\(schedulerKeyList(activePenaltyKeys))]"
            )
            appendUX16d14PersistentLiveEvidence(
                "control#\(plan.sequence) selected=[\(schedulerKeyList(plan.keys))] reason=\(plan.reason) priority=\(plan.priority.rawValue) controlState={\(ocrControlPlane.diagnosticText)}"
            )
        } else {
            activeProductionOCRPlan = nil
            scheduledKeys = scheduledOCRKeysToProcess(now: now, stoppedWindowHashes: hashes)
            keysToProcess = verifiedSchedulerKeys(scheduledKeys, now: now)
            let recordingPriorityActive = RinkLensRecordingCaptureLease.shared.isRecordingActive()
            let maximumFields = recordingPriorityActive ? 2 : 3
            let beforeBound = keysToProcess
            keysToProcess = boundedOCRKeysForPass(keysToProcess, maximumFields: maximumFields)
            if keysToProcess != beforeBound {
                appendSchedulerMetricsDiagnostic(
                    "UX16d2g1 non-production pass bounded to \(maximumFields) fields selected=[\(schedulerKeyList(keysToProcess))] deferred=[\(schedulerKeyList(beforeBound.subtracting(keysToProcess)))] recording=\(recordingPriorityActive)",
                    now: now,
                    force: true
                )
            }
        }
        let processorAllowedKeys = processorAllowedOCRKeys(scheduledKeys: keysToProcess)
        appendSchedulerMetricsDiagnostic(
            "schedule -> OCR candidates: scheduled=[\(schedulerKeyList(scheduledKeys))] verified=[\(schedulerKeyList(keysToProcess))]",
            now: now,
            force: keysToProcess.contains(.period) || scheduledKeys.contains(.period) || runningEventWatch
        )
        MainThreadStallMonitor.shared.traceOCRPhase("candidates scheduled=[\(schedulerKeyList(scheduledKeys))] verified=[\(schedulerKeyList(keysToProcess))] runningEventWatch=\(runningEventWatch) screen=\(currentScreen.rawValue)")
        guard !keysToProcess.isEmpty else {
            if smartChangeDetectionEnabled && shouldPublishOCRDiagnostics {
                smartChangeSkippedOCRFrames += 1
                smartChangeLastDecisionText = "No changed allowed zones detected; OCR skipped."
            }
            if ocrOrchestrationEngine.finishPass(token: frameLease.passToken, reason: "no-scheduled-keys") {
                isProcessing = false
            }
            return
        }

        appendSchedulerMetricsDiagnostic(
            "OCR -> running fields: [\(schedulerKeyList(keysToProcess))] recogniser=bounded deterministic for continuous; diagnostics may use framework fallback",
            now: now,
            force: keysToProcess.contains(.period)
        )

        let colourProfiles = self.ocrColourProfiles
        let includePipelineDiagnostics = shouldPublishOCRDiagnostics && currentScreen == .calibration
        let publicationFlow: RinkLensOCRPublicationFlow = runningEventWatch
            ? .continuousBroadcast
            : .calibrationSelectedZone
        // Build 508's continuous clock stopped at 0.55s with one token still
        // unclassified, while the same crop completed in the 0.65s Test OCR path.
        // Give clock-bearing passes the same bounded completion window without
        // enabling framework fallback or queueing another OCR worker.
        let includesClock = keysToProcess.contains(.clock)
        let isAtomicPenaltyPairPass: Bool
        if let plan = activeProductionOCRPlan {
            if case .penaltyPair = plan.unit {
                isAtomicPenaltyPairPass = true
            } else {
                isAtomicPenaltyPairPass = false
            }
        } else {
            isAtomicPenaltyPairPass = false
        }
        let maximumLiveProcessingSeconds: TimeInterval
        if isAtomicPenaltyPairPass {
            // Build 549: timer and player belong to one transaction. Reserve enough
            // bounded time for the red timer contrast mask instead of allowing a
            // preceding colour pass to consume the complete pair deadline.
            maximumLiveProcessingSeconds = min(0.82, max(0.76, activeOCRInterval * 1.10))
        } else if includesClock {
            // UX16d13: Test and continuous Clock use the same bounded decoder and
            // the same 0.66s pass allowance. The parser preserves its local 80ms
            // recovery tail and now exports the attempted recovery vote summary.
            maximumLiveProcessingSeconds = min(0.66, max(0.62, activeOCRInterval * 0.94))
        } else if priorityVerificationPass {
            // Build 520: the second score/penalty observation must complete before
            // the normal rotation returns several seconds later.
            maximumLiveProcessingSeconds = min(0.66, max(0.62, activeOCRInterval * 0.94))
        } else if baselineReservationPass {
            // Home, Away and Period are verified every alternate live pass even
            // after an early baseline was marked established. The 0.65s allowance
            // matches selected-zone Test OCR closely enough to process all three.
            maximumLiveProcessingSeconds = min(0.65, max(0.60, activeOCRInterval * 0.93))
        } else if RinkLensRecordingCaptureLease.shared.isRecordingActive() {
            maximumLiveProcessingSeconds = min(0.42, max(0.28, activeOCRInterval * 0.60))
        } else {
            maximumLiveProcessingSeconds = min(0.55, max(0.35, activeOCRInterval * 0.75))
        }
        ocrOrchestrationEngine.recognize(
            frame: frameLease,
            layout: layout,
            boardCalibration: boardCalibration,
            scoreboardTemplate: scoreboardTemplate,
            thresholds: thresholds,
            colourProfiles: colourProfiles,
            previewSize: previewSize,
            previewRotationDegrees: previewRotationDegrees,
            enableSegmentedFallback: enableSegmentedFallback,
            keysToProcess: keysToProcess,
            processorAllowedKeys: processorAllowedKeys,
            includePipelineDiagnostics: includePipelineDiagnostics,
            // UX16d5: any pass that can reach Test/Calibration/continuous publication
            // stays on the token-first bounded decoder. Legacy seven-segment and
            // framework OCR remain available only to explicit non-publication diagnostics.
            executionPolicy: .liveBounded,
            maximumProcessingSeconds: maximumLiveProcessingSeconds,
            purpose: publicationFlow.rawValue
        ) { [weak self] recognition in
            let result = recognition.output.map { output in
                (state: output.state, rawText: output.rawText, fieldDebug: output.fieldDebug)
            }
            self?.finishProcessing(
                with: result,
                generation: recognition.generation,
                passToken: recognition.passToken,
                publicationFlow: publicationFlow,
                requestedKeys: recognition.requestedKeys,
                elapsedSeconds: recognition.elapsedSeconds
            )
        }
    }

    private var penaltyPlayerRegionKeys: [OCRRegionKey] {
        [
            .homePenalty1Player, .homePenalty2Player,
            .awayPenalty1Player, .awayPenalty2Player
        ]
    }

    private var activeConfirmedPenaltyTimeRegionKeys: [OCRRegionKey] {
        var keys: [OCRRegionKey] = []
        if penaltyLifecycleStore.lockedPlayer(for: .homePenalty1Player) != nil || state.homePenalty1Player != nil { keys.append(.homePenalty1Time) }
        if penaltyLifecycleStore.lockedPlayer(for: .homePenalty2Player) != nil || state.homePenalty2Player != nil { keys.append(.homePenalty2Time) }
        if penaltyLifecycleStore.lockedPlayer(for: .awayPenalty1Player) != nil || state.awayPenalty1Player != nil { keys.append(.awayPenalty1Time) }
        if penaltyLifecycleStore.lockedPlayer(for: .awayPenalty2Player) != nil || state.awayPenalty2Player != nil { keys.append(.awayPenalty2Time) }
        return keys
    }

    private var allPenaltyTimeRegionKeys: [OCRRegionKey] {
        [.homePenalty1Time, .homePenalty2Time, .awayPenalty1Time, .awayPenalty2Time]
    }


    private var penaltyRegionPairs: [(player: OCRRegionKey, time: OCRRegionKey)] {
        [
            (.homePenalty1Player, .homePenalty1Time),
            (.homePenalty2Player, .homePenalty2Time),
            (.awayPenalty1Player, .awayPenalty1Time),
            (.awayPenalty2Player, .awayPenalty2Time)
        ]
    }

    // UX16d16 Build 535: perspective-corrected hashes provide evidence only.
    // They may make a typed work item immediately due, but they cannot choose the
    // next field or advance a successful-service timestamp.
    private func productionOCRVisualSignalKeys(
        now: CFAbsoluteTime,
        hashes: [OCRRegionKey: UInt64]
    ) -> Set<OCRRegionKey> {
        var signalled = Set<OCRRegionKey>()

        let stoppedHashWatchActive = trustedClockConfirmedStopped
            || !localClockIsRunning
        if stoppedHashWatchActive && !stoppedHashWatchWasActive {
            scoreLastSafetyOCRAt = [.homeScore: now, .awayScore: now]
            penaltyPlayerLastSafetyOCRAt = Dictionary(
                uniqueKeysWithValues: penaltyPlayerRegionKeys.map { ($0, now) }
            )
            stoppedWindowSafetyTransactionUntil.removeAll(keepingCapacity: true)
            stoppedScoreSafetyCursor = 0
            stoppedPenaltySafetyCursor = 0
            appendSchedulerDiagnostic("Build 551 stopped-window hash watch opened; bounded score/player safety sweep timers armed")
        } else if !stoppedHashWatchActive && stoppedHashWatchWasActive {
            stoppedWindowSafetyTransactionUntil.removeAll(keepingCapacity: true)
            appendSchedulerDiagnostic("Build 551 stopped-window hash watch closed; incomplete safety transactions cleared")
        }
        stoppedHashWatchWasActive = stoppedHashWatchActive
        stoppedWindowSafetyTransactionUntil = stoppedWindowSafetyTransactionUntil.filter { $0.value > now }

        let scoreKeys = [OCRRegionKey.homeScore, .awayScore]
        for key in scoreKeys {
            if scoreHashChanged(for: key, newHash: hashes[key]) {
                stoppedWindowSafetyTransactionUntil.removeValue(forKey: key)
                appendSchedulerDiagnostic("Build 550 active-foreground visual signal opened for \(key.rawValue)")
            }
        }

        // If foreground hashing does not open a score transaction, rotate one
        // score through a bounded safety verification after two seconds. Only one
        // safety score is active at a time so Clock and penalty work retain capacity.
        if stoppedHashWatchActive,
           !scoreKeys.contains(where: { (stoppedWindowSafetyTransactionUntil[$0] ?? 0) > now }),
           !scoreKeys.contains(where: { scorePendingVisualHash[$0] != nil }) {
            for offset in 0..<scoreKeys.count {
                let index = (stoppedScoreSafetyCursor + offset) % scoreKeys.count
                let key = scoreKeys[index]
                let lastSafety = scoreLastSafetyOCRAt[key] ?? now
                guard now - lastSafety >= stoppedScoreSafetyOCRInterval else { continue }
                scoreLastSafetyOCRAt[key] = now
                stoppedWindowSafetyTransactionUntil[key] = now + stoppedSafetyTransactionLifetime
                stoppedScoreSafetyCursor = (index + 1) % scoreKeys.count
                appendSchedulerDiagnostic(
                    "Build 550 stopped-window safety transaction opened for \(key.rawValue) after \(String(format: "%.1f", stoppedScoreSafetyOCRInterval))s without a foreground-hash trigger"
                )
                break
            }
        }

        for key in scoreKeys where scorePendingVisualHash[key] != nil
            || (stoppedWindowSafetyTransactionUntil[key] ?? 0) > now {
            signalled.insert(key)
        }

        if periodHashChanged(newHash: hashes[.period]) {
            appendSchedulerDiagnostic("Build 550 active-foreground visual signal opened for Period")
        }
        if periodPendingVisualHash != nil {
            signalled.insert(.period)
        }

        // Hash changes remain immediate. In addition, rotate one inactive player
        // zone through a stopped-window safety transaction at a time so a narrow
        // player number cannot remain invisible for the whole stoppage.
        if stoppedHashWatchActive,
           !penaltyPlayerRegionKeys.contains(where: { (stoppedWindowSafetyTransactionUntil[$0] ?? 0) > now }) {
            let ordered = penaltyPlayerRegionKeys
            for offset in 0..<ordered.count {
                let index = (stoppedPenaltySafetyCursor + offset) % ordered.count
                let key = ordered[index]
                let lastSafety = penaltyPlayerLastSafetyOCRAt[key] ?? -Double.greatestFiniteMagnitude
                guard now - lastSafety >= stoppedPenaltyPlayerSafetySweepInterval else { continue }
                penaltyPlayerLastSafetyOCRAt[key] = now
                stoppedWindowSafetyTransactionUntil[key] = now + stoppedSafetyTransactionLifetime
                stoppedPenaltySafetyCursor = (index + 1) % ordered.count
                appendSchedulerDiagnostic("Build 550 stopped-window player safety transaction opened for \(key.rawValue)")
                break
            }
        }

        for pair in penaltyRegionPairs {
            if now < (livePenaltyPairRetryCooldownUntil[pair.player] ?? 0) {
                continue
            }
            let playerActive = penaltyLifecycleStore.lockedPlayer(for: pair.player) != nil
                || PenaltyStateMachine.penaltyPlayerValue(for: pair.player, in: state) != nil
            let playerChanged = penaltyPlayerHashChanged(for: pair.player, newHash: hashes[pair.player])
            let timeChanged = playerActive
                ? penaltyTimeHashChanged(for: pair.time, newHash: hashes[pair.time])
                : false

            if playerChanged {
                stoppedWindowSafetyTransactionUntil.removeValue(forKey: pair.player)
                appendSchedulerDiagnostic(
                    "Build 550 active-foreground player transaction opened for \(pair.player.rawValue)"
                )
            }
            if timeChanged {
                appendSchedulerDiagnostic(
                    "Build 550 active player-owned timer transaction opened for \(pair.time.rawValue)"
                )
            }

            if penaltyPlayerPendingVisualHash[pair.player] != nil
                || (stoppedWindowSafetyTransactionUntil[pair.player] ?? 0) > now {
                signalled.insert(pair.player)
            }
            if playerActive, penaltyTimePendingVisualHash[pair.time] != nil {
                signalled.formUnion([pair.player, pair.time])
            }
        }

        return signalled
    }

    private func productionActivePenaltyKeys() -> Set<OCRRegionKey> {
        var keys = Set<OCRRegionKey>()
        for pair in penaltyRegionPairs {
            let playerActive = penaltyLifecycleStore.lockedPlayer(for: pair.player) != nil
                || PenaltyStateMachine.penaltyPlayerValue(for: pair.player, in: state) != nil
            let timeActive: Bool
            switch pair.time {
            case .homePenalty1Time: timeActive = state.homePenalty1Clock != nil
            case .homePenalty2Time: timeActive = state.homePenalty2Clock != nil
            case .awayPenalty1Time: timeActive = state.awayPenalty1Clock != nil
            case .awayPenalty2Time: timeActive = state.awayPenalty2Clock != nil
            default: timeActive = false
            }
            if playerActive {
                keys.formUnion([pair.player, pair.time])
            } else if timeActive {
                appendSchedulerDiagnostic("Build 547 ignored orphan penalty timer for \(pair.time.rawValue); no player authority exists")
            }
        }
        return keys
    }

    private var activePenaltyPlayerRegionKeys: [OCRRegionKey] {
        penaltyPlayerRegionKeys.filter { key in
            penaltyLifecycleStore.lockedPlayer(for: key) != nil || PenaltyStateMachine.penaltyPlayerValue(for: key, in: state) != nil
        }
    }

    func updatePixelHashingStatus(_ active: Bool, detail: String, force: Bool = false) {
        // Do not publish diagnostic-only OCR/hash status while Broadcast is on air.
        // BroadcastView observes the main view model, so frequent @Published status
        // changes here can force periodic SwiftUI redraws and make the public camera
        // preview look as if it has frozen. Calibration keeps the full diagnostics.
        guard shouldPublishOCRDiagnostics else { return }

        let now = CFAbsoluteTimeGetCurrent()
        guard force
                || active != isPixelHashingActive
                || now - lastPixelHashStatusPublishAt >= pixelHashStatusPublishInterval else { return }

        lastPixelHashStatusPublishAt = now
        let statusText = active ? "Pixel hashing active" : "Pixel hashing inactive"
        if isPixelHashingActive != active { isPixelHashingActive = active }
        if ocrPixelHashingStatusText != statusText { ocrPixelHashingStatusText = statusText }
        if ocrPixelHashingDetailText != detail { ocrPixelHashingDetailText = detail }
        smartChangeLastDecisionText = detail
    }

    private func recordPixelHashDecision(field: String, changed: Bool, safetyOCRDue: Bool) {
        guard changed || safetyOCRDue else { return }
        let reason = changed ? "visual change detected" : "safety recheck due"
        let context = localClockIsRunning ? "Active penalty watch" : "Stopped-clock event window"
        updatePixelHashingStatus(true, detail: "\(context): \(field) OCR triggered because \(reason).")
    }

    private func scheduledOCRKeysToProcess(
        now: CFAbsoluteTime,
        stoppedWindowHashes: [OCRRegionKey: UInt64]
    ) -> Set<OCRRegionKey> {
        // Never OCR shots. They are intentionally removed from the OCR workload and
        // scoreboard display because they add OCR cost without being required for the
        // current operating model.
        if performanceSafeModeEnabled {
            let safeKeys: Set<OCRRegionKey> = [.homeScore, .awayScore, .period]
            markOCRKeysChecked(safeKeys, at: now)
            updatePixelHashingStatus(false, detail: "Safe Mode active: scores and Period only; Clock and penalty timers remain Image Relay-only.")
            updateRegionDetectionStates(watchedByHashing: [], ocrScheduled: safeKeys)
            return safeKeys
        }

        guard currentScreen == .live || currentScreen == .broadcast || currentScreen == .calibration else {
            updatePixelHashingStatus(false, detail: "Pixel hashing is inactive because OCR is not on Live, Broadcast or Calibration.")
            updateRegionDetectionStates(watchedByHashing: [], ocrScheduled: [])
            return []
        }

        if calibrationPhaseOverrideActive && currentScreen == .calibration && calibrationPreviewMountAllowedW10F {
            var keys = Set<OCRRegionKey>()
            addScheduledKeys([.homeScore, .awayScore], interval: ocrTuningSnapshot.score.cadenceSeconds, now: now, into: &keys)
            addScheduledKeys([.period], interval: ocrTuningSnapshot.period.cadenceSeconds, now: now, into: &keys)
            addScheduledKeys(penaltyPlayerRegionKeys, interval: ocrTuningSnapshot.penaltyPlayer.cadenceSeconds, now: now, into: &keys)
            keys.formIntersection(Set(OCRRegionKey.productionOCRCases))
            ocrScheduler.markRun(keys: keys, at: now)
            updatePixelHashingStatus(
                false,
                detail: "Calibration phase active: OCR is limited to scores, Period and penalty-player numbers. Clock and penalty timers remain Image Relay-only.",
                force: true
            )
            updateRegionDetectionStates(watchedByHashing: [], ocrScheduled: keys, force: true)
            appendSchedulerMetricsDiagnostic("schedule -> calibration authorised fields only; scheduled=[\(schedulerKeyList(keys))]", now: now, force: true)
            return keys
        }

        if ocrStartupClockBootstrapActive {
            let keys: Set<OCRRegionKey> = [.homeScore, .awayScore, .period]
            markOCRKeysChecked(keys, at: now)
            updatePixelHashingStatus(false, detail: "OCR restart baseline: reading Home score, Away score and Period. Clock and penalty timers are never OCR'd.")
            updateRegionDetectionStates(watchedByHashing: [], ocrScheduled: keys)
            return keys
        }

        var keys = Set<OCRRegionKey>()
        var watchedByHashing = Set<OCRRegionKey>()
        let runningPlay = shouldRunClockOnlyOCR(now: now)
        appendSchedulerMetricsDiagnostic(
            "schedule -> start: runningPlay=\(runningPlay) clockRunning=\(localClockIsRunning) hashesAvailable=[\(schedulerHashList(stoppedWindowHashes))] authorised=[\(schedulerKeyList(Set(OCRRegionKey.productionOCRCases)))]",
            now: now
        )

        // Build 631: the Clock crop remains a visual movement watch only. Scores,
        // Period and penalty-player regions are the complete production OCR scope.
        watchedByHashing.formUnion([.clock, .homeScore, .awayScore, .period])
        watchedByHashing.formUnion(penaltyPlayerRegionKeys)
        scheduleStoppedScoreKeys(now: now, hashes: stoppedWindowHashes, into: &keys)
        if runningPlay {
            scheduleRunningPeriodKey(now: now, hashes: stoppedWindowHashes, into: &keys)
            updatePixelHashingStatus(true, detail: "Clock running: visual movement owns clock state; changed score and Period regions may run authorised OCR.")
        } else {
            scheduleStoppedPeriodKey(now: now, hashes: stoppedWindowHashes, into: &keys)
            schedulePenaltyPlayerKeys(now: now, hashes: stoppedWindowHashes, allowNewPenaltyDetection: true, into: &keys)
        }

        // Final hard boundary: no legacy helper or Calibration route may admit
        // Clock or penalty-timer OCR. The central scheduler applies cadence within
        // the explicitly authorised field set.
        let authorisedKeys = Set(OCRRegionKey.productionOCRCases)
        let centralAllowedKeys = centralSchedulerAllowedKeys(now: now, hashes: stoppedWindowHashes)
        let filteredKeys = keys.intersection(centralAllowedKeys).intersection(authorisedKeys)
        if filteredKeys != keys {
            let removed = keys.subtracting(filteredKeys).map { $0.rawValue }.sorted().joined(separator: ", ")
            appendSchedulerMetricsDiagnostic("central scheduler filtered OCR fields: \(removed)", now: now, force: true)
        }
        ocrScheduler.markRun(keys: filteredKeys, at: now)
        updateRegionDetectionStates(watchedByHashing: watchedByHashing, ocrScheduled: filteredKeys)
        return filteredKeys
    }

    private func scheduleRunningPeriodKey(
        now: CFAbsoluteTime,
        hashes: [OCRRegionKey: UInt64],
        into keys: inout Set<OCRRegionKey>
    ) {
        let changed = periodHashChanged(newHash: hashes[.period])
        if changed {
            livePeriodEventWatchUntil = max(livePeriodEventWatchUntil, now + livePeriodFollowUpSeconds)
            appendSchedulerDiagnostic("live period hash changed; bounded verification window opened")
        }
        guard changed || now < livePeriodEventWatchUntil else {
            finaliseUnverifiedPendingVisualHash(
                for: .period,
                reason: "Period verification window expired; independent five-second audit remains active"
            )
            return
        }
        addScheduledKeys(
            [.period],
            interval: max(0.75, ocrTuningSnapshot.period.cadenceSeconds),
            now: now,
            into: &keys
        )
    }

    private func scheduleStoppedClockKey(
        now: CFAbsoluteTime,
        hashes: [OCRRegionKey: UInt64],
        into keys: inout Set<OCRRegionKey>
    ) {
        let key: OCRRegionKey = .clock
        let hashChanged = clockHashChanged(newHash: hashes[key])
        let safetyOCRDue = now - clockLastSafetyOCRAt >= stoppedClockSafetyOCRInterval
        if hashChanged || safetyOCRDue {
            recordPixelHashDecision(field: "game clock", changed: hashChanged, safetyOCRDue: safetyOCRDue)
            keys.insert(key)
            lastOCRFieldCheckAt[key] = now
            clockLastSafetyOCRAt = now
        } else {
            updatePixelHashingStatus(true, detail: "Stopped-clock event window: perspective-corrected active-foreground hashes are watching clock, score and penalty-player regions. No changed region required OCR on this pass.")
        }
    }

    private func scheduleStoppedScoreKeys(
        now: CFAbsoluteTime,
        hashes: [OCRRegionKey: UInt64],
        into keys: inout Set<OCRRegionKey>
    ) {
        for key in [OCRRegionKey.homeScore, .awayScore] {
            let hashChanged = scoreHashChanged(for: key, newHash: hashes[key])
            guard hashChanged else { continue }
            recordPixelHashDecision(field: key.likelyTitle, changed: true, safetyOCRDue: false)
            keys.insert(key)
            lastOCRFieldCheckAt[key] = now
            scoreLastSafetyOCRAt[key] = now
        }
    }

    private func scheduleStoppedPeriodKey(
        now: CFAbsoluteTime,
        hashes: [OCRRegionKey: UInt64],
        into keys: inout Set<OCRRegionKey>
    ) {
        let key: OCRRegionKey = .period
        let hashChanged = periodHashChanged(newHash: hashes[key])
        let interval: CFTimeInterval = now < periodFastCheckUntil ? ocrTuningSnapshot.period.cadenceSeconds : stoppedPeriodSafetyOCRInterval
        let safetyOCRDue = now - periodLastSafetyOCRAt >= interval

        if hashChanged || safetyOCRDue {
            recordPixelHashDecision(field: "period", changed: hashChanged, safetyOCRDue: safetyOCRDue)
            appendSchedulerDiagnostic("period -> scheduled: hashChanged=\(hashChanged) safetyDue=\(safetyOCRDue) interval=\(String(format: "%.1f", interval))s hashPresent=\(hashes[key] != nil)")
            keys.insert(key)
            lastOCRFieldCheckAt[key] = now
            periodLastSafetyOCRAt = now
        } else {
            appendSchedulerMetricsDiagnostic("period -> skipped: no hash change and safety not due. interval=\(String(format: "%.1f", interval))s hashPresent=\(hashes[key] != nil)", now: now)
        }
    }

    private func schedulePenaltyPlayerKeys(
        now: CFAbsoluteTime,
        hashes: [OCRRegionKey: UInt64],
        allowNewPenaltyDetection: Bool,
        into keys: inout Set<OCRRegionKey>
    ) {
        guard allowNewPenaltyDetection, !localClockIsRunning else { return }
        for key in penaltyPlayerRegionKeys {
            let hashChanged = penaltyPlayerHashChanged(for: key, newHash: hashes[key])
            guard hashChanged else { continue }
            recordPixelHashDecision(field: key.likelyTitle, changed: true, safetyOCRDue: false)
            keys.insert(key)
            lastOCRFieldCheckAt[key] = now
        }
    }

    private func scheduleConfirmedPenaltyTimeKeys(
        now: CFAbsoluteTime,
        hashes: [OCRRegionKey: UInt64],
        safetyInterval: CFTimeInterval,
        into keys: inout Set<OCRRegionKey>
    ) {
        for key in activeConfirmedPenaltyTimeRegionKeys {
            let hashChanged = penaltyTimeHashChanged(for: key, newHash: hashes[key])
            let lastSafetyOCR = penaltyTimeLastSafetyOCRAt[key] ?? -Double.greatestFiniteMagnitude
            let safetyOCRDue = now - lastSafetyOCR >= safetyInterval

            if hashChanged || safetyOCRDue {
                recordPixelHashDecision(field: key.likelyTitle, changed: hashChanged, safetyOCRDue: safetyOCRDue)
                keys.insert(key)
                lastOCRFieldCheckAt[key] = now
                penaltyTimeLastSafetyOCRAt[key] = now
            }
        }
    }

    private func penaltyTimeHashChanged(for key: OCRRegionKey, newHash: UInt64?) -> Bool {
        pendingAwareVisualHashChanged(
            for: key,
            newHash: newHash,
            baseline: &penaltyTimeVisualHash,
            pending: &penaltyTimePendingVisualHash,
            threshold: penaltyTimeHashChangeThreshold
        )
    }

    func updateRegionDetectionStates(watchedByHashing: Set<OCRRegionKey>, ocrScheduled: Set<OCRRegionKey>, force: Bool = false) {
        var states = Dictionary(uniqueKeysWithValues: OCRRegionKey.calibrationCases.map { ($0, OCRRegionDetectionState.none) })

        guard isOCREffectiveRunning else {
            publishRegionDetectionStatesIfNeeded(states, force: force)
            return
        }

        // Central rule for the UI: every OCR box always has one visible state.
        // Clock state is visual-only. Scores, Period and penalty-player regions turn green only when authorised OCR is scheduled.
        for key in watchedByHashing { states[key] = .hashingActive }
        for key in ocrScheduled { states[key] = .ocrScheduled }

        if currentScreen == .calibration, ocrScheduled.isEmpty, watchedByHashing.isEmpty {
            states[selectedRegionKey] = .safetyResync
        }

        publishRegionDetectionStatesIfNeeded(states, force: force)
    }

    private func publishRegionDetectionStatesIfNeeded(_ states: [OCRRegionKey: OCRRegionDetectionState], force: Bool = false) {
        // Detection-state colours are a Calibration overlay feature. Publishing them
        // during Broadcast gives no public value and causes avoidable view-model
        // invalidations while the camera preview is live.
        guard shouldPublishOCRDiagnostics else { return }

        let now = CFAbsoluteTimeGetCurrent()
        guard force
                || states != lastPublishedRegionDetectionStates
                || now - lastDetectionStatePublishAt >= detectionStatePublishInterval else { return }

        lastDetectionStatePublishAt = now
        lastPublishedRegionDetectionStates = states
        if regionDetectionStates != states {
            regionDetectionStates = states
        }
    }

    private func clockHashChanged(newHash: UInt64?) -> Bool {
        guard let newHash else { return false }
        guard let previousHash = clockVisualHash else {
            clockVisualHash = newHash
            return false
        }

        guard hammingDistance(previousHash, newHash) >= 3 else { return false }
        clockVisualHash = newHash
        return true
    }

    private func scoreHashChanged(for key: OCRRegionKey, newHash: UInt64?) -> Bool {
        pendingAwareVisualHashChanged(
            for: key,
            newHash: newHash,
            baseline: &scoreVisualHash,
            pending: &scorePendingVisualHash,
            threshold: 4
        )
    }

    private func periodHashChanged(newHash: UInt64?) -> Bool {
        guard let newHash else { return false }
        guard let previousHash = periodVisualHash else {
            periodVisualHash = newHash
            periodPendingVisualHash = nil
            return false
        }
        if periodPendingVisualHash != nil { return false }
        guard hammingDistance(previousHash, newHash) >= 2 else { return false }
        periodPendingVisualHash = newHash
        return true
    }

    private func penaltyPlayerHashChanged(for key: OCRRegionKey, newHash: UInt64?) -> Bool {
        pendingAwareVisualHashChanged(
            for: key,
            newHash: newHash,
            baseline: &penaltyPlayerVisualHash,
            pending: &penaltyPlayerPendingVisualHash,
            threshold: penaltyPlayerHashChangeThreshold
        )
    }

    private func pendingAwareVisualHashChanged(
        for key: OCRRegionKey,
        newHash: UInt64?,
        baseline: inout [OCRRegionKey: UInt64],
        pending: inout [OCRRegionKey: UInt64],
        threshold: Int
    ) -> Bool {
        guard let newHash else { return false }
        guard let previousHash = baseline[key] else {
            baseline[key] = newHash
            pending.removeValue(forKey: key)
            return false
        }
        // A changed image remains pending until OCR accepts it or the bounded
        // retry window expires. Repeated frames must not overwrite the trusted
        // baseline or endlessly extend urgency after one failed recognition.
        if pending[key] != nil { return false }
        let distance = hammingDistance(previousHash, newHash)
        recordVisualHashEvidence(
            key: key,
            previousHash: previousHash,
            newHash: newHash,
            distance: distance,
            threshold: threshold,
            triggered: distance >= threshold
        )
        guard distance >= threshold else { return false }
        pending[key] = newHash
        return true
    }

    private func commitPendingVisualHashAfterAcceptedRecognition(for key: OCRRegionKey) {
        switch key {
        case .homeScore, .awayScore:
            if let value = scorePendingVisualHash.removeValue(forKey: key) {
                scoreVisualHash[key] = value
            }
        case .period:
            if let value = periodPendingVisualHash {
                periodVisualHash = value
                periodPendingVisualHash = nil
            }
        case .homePenalty1Player, .homePenalty2Player, .awayPenalty1Player, .awayPenalty2Player:
            if let value = penaltyPlayerPendingVisualHash.removeValue(forKey: key) {
                penaltyPlayerVisualHash[key] = value
            }
        case .homePenalty1Time, .homePenalty2Time, .awayPenalty1Time, .awayPenalty2Time:
            if let value = penaltyTimePendingVisualHash.removeValue(forKey: key) {
                penaltyTimeVisualHash[key] = value
            }
        default:
            break
        }
    }

    private func finaliseUnverifiedPendingVisualHash(for key: OCRRegionKey, reason: String) {
        switch key {
        case .homeScore, .awayScore:
            if let value = scorePendingVisualHash.removeValue(forKey: key) {
                scoreVisualHash[key] = value
                appendSchedulerDiagnostic("Build 529 consumed unresolved \(key.rawValue) hash only after bounded retries; \(reason)")
            }
        case .period:
            if let value = periodPendingVisualHash {
                periodVisualHash = value
                periodPendingVisualHash = nil
                appendSchedulerDiagnostic("Build 529 consumed unresolved Period hash only after bounded retries; \(reason)")
            }
        case .homePenalty1Player, .homePenalty2Player, .awayPenalty1Player, .awayPenalty2Player:
            if let value = penaltyPlayerPendingVisualHash.removeValue(forKey: key) {
                penaltyPlayerVisualHash[key] = value
                appendSchedulerDiagnostic("Build 529 expired malformed penalty-player urgency for \(key.rawValue); \(reason)")
            }
        case .homePenalty1Time, .homePenalty2Time, .awayPenalty1Time, .awayPenalty2Time:
            if let value = penaltyTimePendingVisualHash.removeValue(forKey: key) {
                penaltyTimeVisualHash[key] = value
                appendSchedulerDiagnostic("Build 529 expired malformed penalty-time urgency for \(key.rawValue); \(reason)")
            }
        default:
            break
        }
    }

    private func currentPendingVisualTransactionKeys() -> Set<OCRRegionKey> {
        let now = CFAbsoluteTimeGetCurrent()
        stoppedWindowSafetyTransactionUntil = stoppedWindowSafetyTransactionUntil.filter { $0.value > now }
        var keys = Set(scorePendingVisualHash.keys)
        keys.formUnion(stoppedWindowSafetyTransactionUntil.keys)
        if periodPendingVisualHash != nil { keys.insert(.period) }
        keys.formUnion(penaltyPlayerPendingVisualHash.keys)
        // Timer hashes exist only for active player-owned slots.
        keys.formUnion(penaltyTimePendingVisualHash.keys.filter { timeKey in
            let playerKey: OCRRegionKey
            switch timeKey {
            case .homePenalty1Time: playerKey = .homePenalty1Player
            case .homePenalty2Time: playerKey = .homePenalty2Player
            case .awayPenalty1Time: playerKey = .awayPenalty1Player
            case .awayPenalty2Time: playerKey = .awayPenalty2Player
            default: return false
            }
            return penaltyLifecycleStore.lockedPlayer(for: playerKey) != nil
                || PenaltyStateMachine.penaltyPlayerValue(for: playerKey, in: state) != nil
        })
        return keys
    }

    private func commitPendingVisualHashesAfterPublication(
        _ fields: [ScoreboardOCRProcessor.OCRFieldDebug],
        evidence: RinkLensOCRPublicationEvidence,
        remainingPriorityKeys: Set<OCRRegionKey>,
        publishedState: ScoreboardState
    ) {
        for field in fields {
            guard !remainingPriorityKeys.contains(field.key) else { continue }
            let hasAcceptedValue = !field.accepted
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            let isConfirmedBlank = evidence.field(field.key)?.confirmedBlank == true
            guard hasAcceptedValue || isConfirmedBlank else { continue }

            switch field.key {
            case .homeScore:
                guard let accepted = Int(field.accepted), publishedState.homeScore == accepted else { continue }
            case .awayScore:
                guard let accepted = Int(field.accepted), publishedState.awayScore == accepted else { continue }
            case .homePenalty1Player:
                if isConfirmedBlank {
                    guard publishedState.homePenalty1Player == nil else { continue }
                } else {
                    guard let accepted = Int(field.accepted.filter(\.isNumber)),
                          publishedState.homePenalty1Player == accepted else { continue }
                }
            case .homePenalty2Player:
                if isConfirmedBlank {
                    guard publishedState.homePenalty2Player == nil else { continue }
                } else {
                    guard let accepted = Int(field.accepted.filter(\.isNumber)),
                          publishedState.homePenalty2Player == accepted else { continue }
                }
            case .awayPenalty1Player:
                if isConfirmedBlank {
                    guard publishedState.awayPenalty1Player == nil else { continue }
                } else {
                    guard let accepted = Int(field.accepted.filter(\.isNumber)),
                          publishedState.awayPenalty1Player == accepted else { continue }
                }
            case .awayPenalty2Player:
                if isConfirmedBlank {
                    guard publishedState.awayPenalty2Player == nil else { continue }
                } else {
                    guard let accepted = Int(field.accepted.filter(\.isNumber)),
                          publishedState.awayPenalty2Player == accepted else { continue }
                }
            case .homePenalty1Time:
                guard publishedState.homePenalty1Player != nil,
                      publishedState.homePenalty1Clock == field.accepted else { continue }
            case .homePenalty2Time:
                guard publishedState.homePenalty2Player != nil,
                      publishedState.homePenalty2Clock == field.accepted else { continue }
            case .awayPenalty1Time:
                guard publishedState.awayPenalty1Player != nil,
                      publishedState.awayPenalty1Clock == field.accepted else { continue }
            case .awayPenalty2Time:
                guard publishedState.awayPenalty2Player != nil,
                      publishedState.awayPenalty2Clock == field.accepted else { continue }
            case .period:
                guard let accepted = Int(field.accepted), publishedState.period == accepted else { continue }
            default:
                break
            }
            commitPendingVisualHashAfterAcceptedRecognition(for: field.key)
            stoppedWindowSafetyTransactionUntil.removeValue(forKey: field.key)
        }
    }

    private func hammingDistance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        var value = lhs ^ rhs
        var count = 0
        while value != 0 {
            count += 1
            value &= value - 1
        }
        return count
    }

    private func recordVisualHashEvidence(
        key: OCRRegionKey,
        previousHash: UInt64,
        newHash: UInt64,
        distance: Int,
        threshold: Int,
        triggered: Bool
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        let last = visualHashDiagnosticLastAt[key] ?? 0
        guard triggered || (distance > 0 && now - last >= 5.0) else { return }
        visualHashDiagnosticLastAt[key] = now
        let decision = triggered ? "trigger" : "below-threshold"
        let detail = "Build 550 hash key=\(key.rawValue) baseline=\(String(format: "%016llX", previousHash)) current=\(String(format: "%016llX", newHash)) distance=\(distance) threshold=\(threshold) decision=\(decision)"
        appendSchedulerDiagnostic(detail)
        if triggered {
            MainThreadStallMonitor.shared.traceOCRPhase(detail)
        }
    }

    private func addScheduledKeys(
        _ fieldKeys: [OCRRegionKey],
        interval: CFTimeInterval,
        now: CFAbsoluteTime,
        into keys: inout Set<OCRRegionKey>
    ) {
        for key in fieldKeys {
            let last = lastOCRFieldCheckAt[key] ?? -Double.greatestFiniteMagnitude
            guard now - last >= interval else { continue }
            keys.insert(key)
            lastOCRFieldCheckAt[key] = now
        }
    }

    private func markOCRKeysChecked(_ keys: Set<OCRRegionKey>, at now: CFAbsoluteTime) {
        for key in keys {
            lastOCRFieldCheckAt[key] = now
        }
    }

    private func smoothingClockDirectionForMerge(rawOCRClock: String?) -> GameClockDirection {
        switch gameClockDirection {
        case .countUp, .countDown:
            return gameClockDirection
        case .auto:
            // UX16d8: before direction is locked, let the smoother validate the
            // raw timer without forcing either direction. Once locked, use the
            // evidence-backed direction; never infer it from one raw delta here.
            return autoClockDirectionIsLocked ? localClockDirection : .auto
        }
    }

    private func updateLiveClockSchedulingStability(_ decision: RinkLensTrustedClockDecision) {
        if decision.acceptedObservation {
            trustedClockLiveContinuationCount = min(12, trustedClockLiveContinuationCount + 1)
        } else {
            trustedClockLiveContinuationCount = 0
        }
    }

    private func canAcceptSingleSourceClockContinuation(
        seconds: Int,
        now: CFAbsoluteTime
    ) -> Bool {
        guard trustedClockAnchorSeconds != nil,
              let lastSeconds = trustedClockLastObservationSeconds,
              trustedClockLastObservationAt > 0 else { return false }
        let elapsed = max(0.05, now - trustedClockLastObservationAt)
        let delta = seconds - lastSeconds
        let maximumOrdinaryDelta = max(2, Int(ceil(elapsed)) + 2)
        guard abs(delta) <= maximumOrdinaryDelta else { return false }
        guard delta != 0 else { return true }

        let observedDirection: GameClockDirection = delta > 0 ? .countUp : .countDown
        if gameClockDirection != .auto {
            return observedDirection == gameClockDirection
        }
        if autoClockDirectionIsLocked {
            return observedDirection == localClockDirection
        }
        return true
    }

    private func seedTrustedClockAuthorityFromOperatorConfirmedTest(
        clock: String,
        frameSequence: Int,
        captureGeneration: Int
    ) {
        guard let seconds = seconds(from: clock) else { return }
        let now = CFAbsoluteTimeGetCurrent()
        trustedClockAnchorSeconds = seconds
        trustedClockLastObservationSeconds = seconds
        trustedClockLastObservationAt = now
        trustedClockLastAcceptedAt = now
        trustedClockSameValueStartedAt = now
        trustedClockObservedPeriod = state.period
        trustedClockDirectionCandidate = nil
        trustedClockDirectionEvidenceCount = 0
        trustedClockDirectionCandidateStartedAt = 0
        trustedClockDirectionCandidateLastSeconds = nil
        trustedClockDirectionCandidateLastAt = 0
        trustedClockEvidenceState.reset()
        trustedClockEvidenceProcessingGeneration = ocrProcessingGeneration
        trustedClockConfirmedStopped = false
        trustedClockLastAcceptedWasDirect = true
        trustedClockLastAcceptedWasStopEligible = true
        trustedClockDirectSameValueCount = 1
        localClockIsRunning = false
        if gameClockDirection == .auto {
            autoClockDirectionIsLocked = false
            localClockDirection = .countDown
        } else {
            autoClockDirectionIsLocked = true
            localClockDirection = gameClockDirection
        }
        trustedClockLiveContinuationCount = 0
        ocrControlPlane.invalidate(keys: [.clock], now: CFAbsoluteTimeGetCurrent(), reason: "Clock authority changed")
        trustedClockLastDecision = "Operator-confirmed Test OCR seeded physical-board anchor from frame #\(frameSequence) captureGeneration=\(captureGeneration)"
        appendSchedulerDiagnostic("clock authority seeded \(clock) from operator-confirmed Test OCR frame=#\(frameSequence) captureGeneration=\(captureGeneration)")
        appendUX16d14PersistentLiveEvidence("test-seed clock=\(clock) frame=#\(frameSequence) captureGeneration=\(captureGeneration) anchor=\(clock)")
    }

    private func seedTrustedClockAuthorityFromManualCorrection(
        clock: String,
        reason: String
    ) {
        guard let seconds = seconds(from: clock) else { return }
        let now = CFAbsoluteTimeGetCurrent()
        trustedClockAnchorSeconds = seconds
        trustedClockLastObservationSeconds = seconds
        trustedClockLastObservationAt = now
        trustedClockLastAcceptedAt = now
        trustedClockSameValueStartedAt = now
        trustedClockObservedPeriod = state.period
        clearTrustedClockDirectionCandidate()
        trustedClockEvidenceState.reset()
        trustedClockEvidenceProcessingGeneration = ocrProcessingGeneration
        trustedClockConfirmedStopped = false
        trustedClockLastAcceptedWasDirect = true
        trustedClockLastAcceptedWasStopEligible = true
        trustedClockDirectSameValueCount = 1
        localClockIsRunning = false
        if gameClockDirection != .auto {
            localClockDirection = gameClockDirection
            autoClockDirectionIsLocked = true
        }
        trustedClockLiveContinuationCount = 0
        ocrControlPlane.invalidate(keys: [.clock], now: CFAbsoluteTimeGetCurrent(), reason: "Clock authority changed")
        trustedClockLastDecision = "Manual Clock correction reseeded trusted authority: \(reason)"
        appendSchedulerDiagnostic("clock authority manual reseed clock=\(clock) reason=\(reason)")
    }

    private func restoreOperatorConfirmedTestOCRBaselines(reason: String) {
        guard !operatorConfirmedTestOCRBaselines.isEmpty else { return }

        var retained: [OCRRegionKey: String] = [:]
        for (key, value) in operatorConfirmedTestOCRBaselines {
            let visible: String?
            switch key {
            case .homeScore:
                visible = state.homeScore.map { String($0) }
            case .awayScore:
                visible = state.awayScore.map { String($0) }
            case .period:
                visible = state.period.map { String($0) }
            default:
                visible = nil
            }
            guard visible == value else { continue }
            retained[key] = value
            ocrPublicationSafetyState.seedOperatorConfirmedBaseline(for: key)
        }
        operatorConfirmedTestOCRBaselines = retained

        let retainedText = retained
            .map { "\($0.key.rawValue)=\($0.value)" }
            .sorted()
            .joined(separator: ",")
        if !retainedText.isEmpty {
            appendSchedulerDiagnostic(
                "UX16d15 restored operator-confirmed baselines after capture change [\(retainedText)] reason=\(reason)"
            )
        }
    }

    private func resetAutoClockDirectionTracking() {
        autoClockDirectionIsLocked = gameClockDirection != .auto
        localClockDirection = gameClockDirection == .auto ? .countDown : gameClockDirection

        trustedClockAnchorSeconds = nil
        trustedClockLastObservationSeconds = nil
        trustedClockLastObservationAt = 0
        trustedClockLastAcceptedAt = 0
        trustedClockSameValueStartedAt = nil
        trustedClockObservedPeriod = nil
        trustedClockDirectionCandidate = nil
        trustedClockDirectionEvidenceCount = 0
        trustedClockDirectionCandidateStartedAt = 0
        trustedClockDirectionCandidateLastSeconds = nil
        trustedClockDirectionCandidateLastAt = 0
        trustedClockEvidenceState.reset()
        trustedClockEvidenceProcessingGeneration = nil
        trustedClockConfirmedStopped = false
        trustedClockLastAcceptedWasDirect = false
        trustedClockLastAcceptedWasStopEligible = false
        trustedClockDirectSameValueCount = 0
        trustedClockLiveContinuationCount = 0
        fullBoardResetRecovery.reset()
        clearImmediateClockConfirmation(reason: "Clock authority reset", resumeStatic: false)
        ocrControlPlane.invalidate(keys: [.clock], now: CFAbsoluteTimeGetCurrent(), reason: "Clock authority changed")
        trustedClockLastDecision = "Clock authority reset"
    }

    private func clearTrustedClockReanchorEvidence() {
        trustedClockEvidenceState.clearReanchor()
    }

    private func clearBoundedClockEvidence(reason: String) {
        trustedClockEvidenceState.clearPending()
        appendSchedulerDiagnostic("clock authority cleared bounded evidence reason=\(reason)")
    }

    private func clearTrustedClockDirectionCandidate() {
        trustedClockDirectionCandidate = nil
        trustedClockDirectionEvidenceCount = 0
        trustedClockDirectionCandidateStartedAt = 0
        trustedClockDirectionCandidateLastSeconds = nil
        trustedClockDirectionCandidateLastAt = 0
    }

    /// Tracks direction only from sequential trusted physical-board observations.
    /// The accepted Clock may move while Auto is initially determining direction,
    /// but a conflicting second direction is held rather than displayed. A later
    /// direction change can be confirmed only after a physical stop/reset boundary.
    private func observeTrustedClockDirectionCandidate(
        direction: GameClockDirection,
        seconds: Int,
        now: CFAbsoluteTime,
        requiredCount: Int,
        minimumDuration: CFTimeInterval
    ) -> Bool {
        let continuesCandidate: Bool
        if trustedClockDirectionCandidate == direction,
           let previousSeconds = trustedClockDirectionCandidateLastSeconds,
           trustedClockDirectionCandidateLastAt > 0,
           now - trustedClockDirectionCandidateLastAt <= trustedClockEvidenceMaximumAge {
            let delta = seconds - previousSeconds
            let followsDirection: Bool
            switch direction {
            case .countDown: followsDirection = delta < 0
            case .countUp: followsDirection = delta > 0
            case .auto: followsDirection = false
            }
            let elapsed = max(0.05, now - trustedClockDirectionCandidateLastAt)
            let maximumDelta = max(2, Int(ceil(elapsed)) + 2)
            continuesCandidate = followsDirection && abs(delta) <= maximumDelta
        } else {
            continuesCandidate = false
        }

        if continuesCandidate {
            trustedClockDirectionEvidenceCount += 1
        } else {
            trustedClockDirectionCandidate = direction
            trustedClockDirectionEvidenceCount = 1
            trustedClockDirectionCandidateStartedAt = now
        }
        trustedClockDirectionCandidateLastSeconds = seconds
        trustedClockDirectionCandidateLastAt = now

        let stableDuration = trustedClockDirectionCandidateStartedAt > 0
            ? now - trustedClockDirectionCandidateStartedAt
            : 0
        return trustedClockDirectionEvidenceCount >= requiredCount
            && stableDuration >= minimumDuration
    }

    private var trustedClockInitialDirectionRequiredCount: Int {
        isPostOCRSmoothingEnabled ? trustedClockInitialDirectionConfirmationCount : 2
    }

    private var trustedClockDirectionChangeRequiredCount: Int {
        isPostOCRSmoothingEnabled ? trustedClockDirectionChangeConfirmationCount : 2
    }

    private var trustedClockDirectionChangeRequiredDuration: CFTimeInterval {
        isPostOCRSmoothingEnabled ? trustedClockDirectionChangeMinimumDuration : 0.75
    }

    private var trustedClockLargeCorrectionRequiredCount: Int {
        isPostOCRSmoothingEnabled ? 3 : 2
    }

    private var lockedOrConfiguredClockDirection: GameClockDirection? {
        switch gameClockDirection {
        case .countDown, .countUp:
            return gameClockDirection
        case .auto:
            return autoClockDirectionIsLocked ? localClockDirection : nil
        }
    }

    private func fullBoardResetRecoveryPriorityKeys(now: CFAbsoluteTime) -> Set<OCRRegionKey> {
        guard fullBoardResetRecovery.isActive else { return [] }
        guard now <= fullBoardResetRecovery.expiresAt else {
            appendSchedulerDiagnostic("Build 529 full-board reset recovery expired without sufficient evidence")
            fullBoardResetRecovery.reset()
            return []
        }
        guard fullBoardResetRecovery.clockEvidenceCount >= 2 else { return [] }
        if fullBoardResetRecovery.homeEvidenceCount < 2 { return [.homeScore] }
        if fullBoardResetRecovery.awayEvidenceCount < 2 { return [.awayScore] }
        if ocrPublicationSafetyState.pendingBaselineKeys.contains(.period),
           fullBoardResetRecovery.periodEvidenceCount < 2 {
            return [.period]
        }
        return []
    }

    private func commonPeriodStart(near seconds: Int) -> Int? {
        [5 * 60, 10 * 60, 15 * 60, 20 * 60]
            .filter { seconds <= $0 && $0 - seconds <= fullBoardResetNearPeriodStartTolerance }
            .min()
    }

    private func observedFullBoardResetValue(
        _ value: Int,
        currentCandidate: Int?,
        currentCount: Int
    ) -> (candidate: Int, count: Int) {
        currentCandidate == value
            ? (value, currentCount + 1)
            : (value, 1)
    }

    private func observeFullBoardResetRecovery(
        rawState: ScoreboardState,
        evidence: RinkLensOCRPublicationEvidence,
        previous: ScoreboardState,
        now: CFAbsoluteTime
    ) -> RinkLensFullBoardResetObservationResult {
        if fullBoardResetRecovery.isActive, now > fullBoardResetRecovery.expiresAt {
            appendSchedulerDiagnostic("Build 529 full-board reset recovery expired; ordinary trusted Clock rules retained")
            fullBoardResetRecovery.reset()
        }

        if let rawClock = rawState.clock,
           let rawSeconds = seconds(from: rawClock),
           let anchorSeconds = trustedClockAnchorSeconds,
           anchorSeconds > 15,
           let periodStart = commonPeriodStart(near: rawSeconds),
           rawSeconds - anchorSeconds >= fullBoardResetMinimumUpwardJump,
           (lockedOrConfiguredClockDirection ?? .countDown) == .countDown {
            if !fullBoardResetRecovery.isActive {
                fullBoardResetRecovery.startedAt = now
                fullBoardResetRecovery.expiresAt = now + fullBoardResetRecoveryWindow
                fullBoardResetRecovery.originalClockSeconds = anchorSeconds
                fullBoardResetRecovery.originalHomeScore = previous.homeScore
                fullBoardResetRecovery.originalAwayScore = previous.awayScore
                if previous.homeScore == 0 {
                    fullBoardResetRecovery.homeCandidate = 0
                    fullBoardResetRecovery.homeEvidenceCount = 2
                }
                if previous.awayScore == 0 {
                    fullBoardResetRecovery.awayCandidate = 0
                    fullBoardResetRecovery.awayEvidenceCount = 2
                }
                appendSchedulerDiagnostic("Build 529 armed full-board reset recovery anchor=\(formatClock(seconds: anchorSeconds)) candidate=\(rawClock) periodStart=\(formatClock(seconds: periodStart)) score=\(previous.homeScore ?? -1)-\(previous.awayScore ?? -1)")
            }

            let continuesCountdown: Bool
            if let last = fullBoardResetRecovery.clockCandidateSeconds,
               fullBoardResetRecovery.clockLastObservedAt > 0 {
                let elapsed = max(0.05, now - fullBoardResetRecovery.clockLastObservedAt)
                let delta = rawSeconds - last
                continuesCountdown = delta <= 0 && abs(delta) <= max(4, Int(ceil(elapsed)) + 4)
            } else {
                continuesCountdown = true
            }
            if continuesCountdown {
                fullBoardResetRecovery.clockEvidenceCount += 1
            } else {
                fullBoardResetRecovery.clockEvidenceCount = 1
            }
            fullBoardResetRecovery.clockCandidateSeconds = rawSeconds
            fullBoardResetRecovery.clockLastObservedAt = now
            fullBoardResetRecovery.expiresAt = now + fullBoardResetRecoveryWindow
        }

        // A single false upward read must not suppress legitimate score updates for
        // the whole recovery window. If a freshly recognised Clock returns to an
        // ordinary countdown continuation at or below the original anchor, abandon
        // the reset candidate immediately. Static-only passes cannot trigger this
        // cancellation because they contain no Clock publication evidence.
        if fullBoardResetRecovery.isActive,
           let rawClock = rawState.clock,
           let rawSeconds = seconds(from: rawClock),
           let originalSeconds = fullBoardResetRecovery.originalClockSeconds,
           evidence.clockTrust(matching: rawClock) != .none,
           rawSeconds <= originalSeconds,
           originalSeconds - rawSeconds <= 20 {
            appendSchedulerDiagnostic("Build 529 cancelled false full-board reset recovery after ordinary countdown resumed at \(rawClock)")
            fullBoardResetRecovery.reset()
            return .inactive
        }

        guard fullBoardResetRecovery.isActive else { return .inactive }

        if let value = rawState.homeScore,
           evidence.staticBaselineTrust(.homeScore, matching: String(value)) != .none {
            let observed = observedFullBoardResetValue(
                value,
                currentCandidate: fullBoardResetRecovery.homeCandidate,
                currentCount: fullBoardResetRecovery.homeEvidenceCount
            )
            fullBoardResetRecovery.homeCandidate = observed.candidate
            fullBoardResetRecovery.homeEvidenceCount = observed.count
        }
        if let value = rawState.awayScore,
           evidence.staticBaselineTrust(.awayScore, matching: String(value)) != .none {
            let observed = observedFullBoardResetValue(
                value,
                currentCandidate: fullBoardResetRecovery.awayCandidate,
                currentCount: fullBoardResetRecovery.awayEvidenceCount
            )
            fullBoardResetRecovery.awayCandidate = observed.candidate
            fullBoardResetRecovery.awayEvidenceCount = observed.count
        }
        if let value = rawState.period,
           evidence.staticBaselineTrust(.period, matching: String(value)) != .none {
            let observed = observedFullBoardResetValue(
                value,
                currentCandidate: fullBoardResetRecovery.periodCandidate,
                currentCount: fullBoardResetRecovery.periodEvidenceCount
            )
            fullBoardResetRecovery.periodCandidate = observed.candidate
            fullBoardResetRecovery.periodEvidenceCount = observed.count
        }

        guard fullBoardResetRecovery.clockEvidenceCount >= 2,
              let clockSeconds = fullBoardResetRecovery.clockCandidateSeconds,
              let home = fullBoardResetRecovery.homeCandidate,
              let away = fullBoardResetRecovery.awayCandidate,
              fullBoardResetRecovery.homeEvidenceCount >= 2,
              fullBoardResetRecovery.awayEvidenceCount >= 2,
              home == 0, away == 0,
              (fullBoardResetRecovery.originalHomeScore ?? 0) > 0
                || (fullBoardResetRecovery.originalAwayScore ?? 0) > 0 else {
            return .holding
        }

        var replacement = previous
        replacement.clock = formatClock(seconds: clockSeconds)
        replacement.homeScore = home
        replacement.awayScore = away
        if fullBoardResetRecovery.periodEvidenceCount >= 2,
           let period = fullBoardResetRecovery.periodCandidate {
            replacement.period = period
            replacement.periodLabel = String(period)
        }

        let diagnostic = "Build 529 atomic full-board reset recovery clock=\(replacement.clock ?? "--") score=\(home)-\(away) from=\(formatClock(seconds: fullBoardResetRecovery.originalClockSeconds ?? 0))"
        let reduction = reduceMatchState(
            .replace(
                replacement,
                context: RinkLensMatchStateContext(
                    origin: .recovery,
                    eventPolicy: [],
                    diagnosticsOnly: false,
                    reason: diagnostic
                )
            )
        )
        seedTrustedClockAuthorityFromManualCorrection(clock: replacement.clock ?? formatClock(seconds: clockSeconds), reason: diagnostic)
        localClockIsRunning = true
        trustedClockConfirmedStopped = false
        lastClockMovementObservedAt = now
        trustedClockLastDecision = diagnostic
        if gameClockDirection == .auto {
            localClockDirection = .countDown
            autoClockDirectionIsLocked = true
        }
        ocrPublicationSafetyState.seedOperatorConfirmedBaseline(for: .homeScore)
        ocrPublicationSafetyState.seedOperatorConfirmedBaseline(for: .awayScore)
        if replacement.period != nil {
            ocrPublicationSafetyState.seedOperatorConfirmedBaseline(for: .period)
        }
        gameEventDetector.clearPendingStoppedClockBroadcastEvents()
        clearImmediateClockConfirmation(reason: "full-board reset recovered", resumeStatic: true)
        liveOCRPriorityVerificationUntil.removeAll()
        fullBoardResetRecovery.reset()
        appendSchedulerDiagnostic(diagnostic)
        RinkLensOCREvidenceJournal.shared.recordEventAudit(
            stage: "full_board_reset_recovered",
            eventKind: "reset",
            source: "ocr",
            detail: diagnostic
        )
        return .committed(reduction)
    }

    private func trustedClockResetIsPlausible(
        previousSeconds: Int,
        nextSeconds: Int,
        direction: GameClockDirection
    ) -> Bool {
        let commonPeriodStarts: Set<Int> = [5 * 60, 10 * 60, 15 * 60, 20 * 60]
        let countdownReset = previousSeconds <= 15 && commonPeriodStarts.contains(nextSeconds)
        let countupReset = commonPeriodStarts.contains(previousSeconds) && nextSeconds <= 15
        switch direction {
        case .countDown:
            return countdownReset
        case .countUp:
            return countupReset
        case .auto:
            return countdownReset || countupReset
        }
    }

    private func observeTrustedClockReanchor(
        seconds: Int,
        direction: GameClockDirection,
        now: CFAbsoluteTime
    ) -> Bool {
        trustedClockEvidenceState.observeReanchor(
            seconds: seconds,
            direction: direction,
            now: now,
            maximumAge: trustedClockEvidenceMaximumAge,
            maximumCycles: trustedClockEvidenceMaximumCycles
        )
    }

    private func acceptTrustedClockAnchor(
        seconds: Int,
        previousPublicClockSeconds: Int?,
        now: CFAbsoluteTime,
        running: Bool,
        stopped: Bool,
        directEvidence: Bool,
        stopEligibleEvidence: Bool,
        reason: String
    ) -> RinkLensTrustedClockDecision {
        let previousRunning = localClockIsRunning
        let previousStopped = trustedClockConfirmedStopped

        trustedClockAnchorSeconds = seconds
        trustedClockLastObservationSeconds = seconds
        trustedClockLastObservationAt = now
        trustedClockLastAcceptedAt = now
        trustedClockSameValueStartedAt = stopEligibleEvidence ? now : nil
        trustedClockConfirmedStopped = stopped
        trustedClockLastAcceptedWasDirect = directEvidence
        trustedClockLastAcceptedWasStopEligible = stopEligibleEvidence
        trustedClockDirectSameValueCount = stopEligibleEvidence ? 1 : 0
        localClockIsRunning = running
        lastClockOCRConfirmationAt = now
        lastObservedClockOCRSeconds = seconds
        repeatedClockOCRReadCount = 1
        clockStopCandidateStartedAt = stopped ? now : nil
        if running {
            lastClockMovementObservedAt = now
        }
        ocrStartupClockBootstrapActive = false
        clearTrustedClockReanchorEvidence()
        clearImmediateClockConfirmation(reason: "trusted Clock anchor accepted", resumeStatic: true)
        trustedClockLastDecision = reason
        appendSchedulerDiagnostic("clock authority accepted \(formatClock(seconds: seconds)) running=\(running) stopped=\(stopped) reason=\(reason)")
        return RinkLensTrustedClockDecision(
            clockForPublication: formatClock(seconds: seconds),
            acceptedObservation: true,
            publicClockChanged: previousPublicClockSeconds != seconds,
            runningStateChanged: previousRunning != running || previousStopped != stopped,
            isRunning: running,
            confirmedStopped: stopped,
            reason: reason
        )
    }

    private func anchorConsistentClosedLoopClockRepair(
        rawClock: String,
        rawSeconds: Int,
        now: CFAbsoluteTime
    ) -> String? {
        guard let anchorSeconds = trustedClockAnchorSeconds,
              let direction = lockedOrConfiguredClockDirection,
              direction != .auto else { return nil }

        let opposesDirection: Bool
        switch direction {
        case .countDown: opposesDirection = rawSeconds > anchorSeconds
        case .countUp: opposesDirection = rawSeconds < anchorSeconds
        case .auto: opposesDirection = false
        }
        guard opposesDirection else { return nil }

        let characters = Array(rawClock)
        let replaceable = characters.indices.filter { index in
            index > characters.startIndex && characters[index] == "8"
        }
        guard !replaceable.isEmpty, replaceable.count <= 4 else { return nil }

        let elapsed = trustedClockLastObservationAt > 0
            ? max(0.05, now - trustedClockLastObservationAt)
            : 0.70
        let maximumDelta = max(3, min(10, Int(ceil(elapsed)) + 3))
        var candidates: [(value: String, seconds: Int, replacements: Int, distance: Int)] = []
        let combinationCount = 1 << replaceable.count
        for mask in 1..<combinationCount {
            var candidateCharacters = characters
            var replacements = 0
            for (bit, index) in replaceable.enumerated() where (mask & (1 << bit)) != 0 {
                candidateCharacters[index] = "0"
                replacements += 1
            }
            let candidate = String(candidateCharacters)
            guard let candidateSeconds = seconds(from: candidate) else { continue }
            let delta = candidateSeconds - anchorSeconds
            let followsDirection: Bool
            switch direction {
            case .countDown: followsDirection = delta <= 0
            case .countUp: followsDirection = delta >= 0
            case .auto: followsDirection = false
            }
            guard followsDirection, abs(delta) <= maximumDelta else { continue }
            candidates.append((candidate, candidateSeconds, replacements, abs(delta)))
        }

        guard let minimumReplacementCount = candidates.map(\.replacements).min() else { return nil }
        let smallest = candidates.filter { $0.replacements == minimumReplacementCount }
        guard let minimumDistance = smallest.map(\.distance).min() else { return nil }
        let nearest = smallest.filter { $0.distance == minimumDistance }
        guard nearest.count == 1, let repair = nearest.first else { return nil }
        return repair.value
    }

    private func evaluateTrustedClockObservation(
        rawOCRClock: String?,
        evidence: RinkLensOCRPublicationEvidence,
        previous: ScoreboardState,
        now: CFAbsoluteTime,
        continuityCorrected: Bool
    ) -> RinkLensTrustedClockDecision {
        trustedClockEvidenceState.beginObservation(
            now: now,
            maximumAge: trustedClockEvidenceMaximumAge,
            maximumCycles: trustedClockEvidenceMaximumCycles
        )

        if let observedPeriod = trustedClockObservedPeriod,
           let publicPeriod = previous.period,
           publicPeriod != observedPeriod {
            // A committed period change is a clean lifecycle boundary. Pending
            // single-source, reversal and jump evidence cannot cross periods.
            trustedClockAnchorSeconds = nil
            trustedClockLastObservationSeconds = nil
            trustedClockLastObservationAt = 0
            trustedClockSameValueStartedAt = nil
            trustedClockDirectionCandidate = nil
            trustedClockDirectionEvidenceCount = 0
            trustedClockDirectionCandidateStartedAt = 0
            trustedClockDirectionCandidateLastSeconds = nil
            trustedClockDirectionCandidateLastAt = 0
            trustedClockConfirmedStopped = false
            trustedClockLastAcceptedWasDirect = false
            trustedClockLastAcceptedWasStopEligible = false
            trustedClockDirectSameValueCount = 0
            localClockIsRunning = false
            // A committed period boundary clears pending Clock evidence but does
            // not derive a new direction from the reset jump. Auto keeps its
            // previously locked direction; an unlocked Auto clock will establish
            // direction again from post-reset sequential movement.
            trustedClockEvidenceState.reset()
            trustedClockEvidenceState.beginObservation(
                now: now,
                maximumAge: trustedClockEvidenceMaximumAge,
                maximumCycles: trustedClockEvidenceMaximumCycles
            )
        }
        trustedClockObservedPeriod = previous.period

        guard let rawOCRClock,
              let originalRawSeconds = seconds(from: rawOCRClock) else {
            trustedClockLastDecision = "Held last board clock: current OCR reading was incomplete"
            return .rejected(
                trustedClockLastDecision,
                running: localClockIsRunning,
                stopped: trustedClockConfirmedStopped
            )
        }

        let clockTrust = evidence.clockTrust(matching: rawOCRClock)
        guard clockTrust != .none else {
            trustedClockLastDecision = "Held last board clock: current OCR reading lacked trusted decoder evidence"
            return .rejected(
                trustedClockLastDecision,
                running: localClockIsRunning,
                stopped: trustedClockConfirmedStopped
            )
        }

        var evaluatedClock = rawOCRClock
        var rawSeconds = originalRawSeconds
        var anchorCorrectedClosedLoopDigit = false
        if let repaired = anchorConsistentClosedLoopClockRepair(
            rawClock: rawOCRClock,
            rawSeconds: originalRawSeconds,
            now: now
        ), let repairedSeconds = seconds(from: repaired) {
            evaluatedClock = repaired
            rawSeconds = repairedSeconds
            anchorCorrectedClosedLoopDigit = true
            let diagnostic = "Build 531 anchor-consistent closed-loop repair \(rawOCRClock) -> \(repaired)"
            appendSchedulerDiagnostic(diagnostic)
            appendUX16d14PersistentLiveEvidence(diagnostic)
        }

        let evidenceLabel: String
        switch clockTrust {
        case .confirmedAgreement:
            trustedClockEvidenceState.clearProvisional()
            evidenceLabel = "dual-mask agreement"
        case .provisionalSingleSource:
            if canAcceptSingleSourceClockContinuation(seconds: rawSeconds, now: now) {
                trustedClockEvidenceState.clearProvisional()
                evidenceLabel = "single-source sequential continuation of trusted anchor"
            } else {
                guard trustedClockEvidenceState.observeProvisional(
                    seconds: rawSeconds,
                    now: now,
                    maximumAge: trustedClockEvidenceMaximumAge,
                    maximumCycles: trustedClockEvidenceMaximumCycles
                ) else {
                    requestImmediateClockConfirmation(seconds: rawSeconds, now: now)
                    trustedClockLastDecision = "Held single-source board clock pending a second bounded matching/sequential read; immediate confirmation scheduled"
                    appendSchedulerDiagnostic("clock authority \(trustedClockLastDecision) candidate=\(formatClock(seconds: rawSeconds))")
                    return .rejected(
                        trustedClockLastDecision,
                        running: localClockIsRunning,
                        stopped: trustedClockConfirmedStopped
                    )
                }
                trustedClockEvidenceState.clearProvisional()
                evidenceLabel = "repeated strong-colour evidence"
            }
        case .none:
            // Guarded above; retained for exhaustive-switch safety.
            return .rejected(
                "Held last board clock: no trusted evidence",
                running: localClockIsRunning,
                stopped: trustedClockConfirmedStopped
            )
        }

        let directObservation = !continuityCorrected && !anchorCorrectedClosedLoopDigit
        let directClockConfidence = evidence.field(.clock)?.confidence ?? 0
        let stopEligibleObservation = directObservation
            && clockTrust != .none
            && directClockConfidence >= 0.62

        let previousPublicClockSeconds = previous.clock.flatMap { seconds(from: $0) }
        guard let lastSeconds = trustedClockLastObservationSeconds,
              trustedClockLastObservationAt > 0,
              trustedClockAnchorSeconds != nil else {
            if gameClockDirection != .auto {
                localClockDirection = gameClockDirection
                autoClockDirectionIsLocked = true
            }
            return acceptTrustedClockAnchor(
                seconds: rawSeconds,
                previousPublicClockSeconds: previousPublicClockSeconds,
                now: now,
                running: false,
                stopped: false,
                directEvidence: directObservation,
                stopEligibleEvidence: stopEligibleObservation,
                reason: "first complete scoreboard clock from \(evidenceLabel)"
            )
        }

        let elapsed = max(0.05, now - trustedClockLastObservationAt)
        let delta = rawSeconds - lastSeconds

        if delta == 0 {
            let previousRunning = localClockIsRunning
            let previousStopped = trustedClockConfirmedStopped
            let priorStopEligible = trustedClockLastAcceptedWasStopEligible

            trustedClockLastObservationSeconds = rawSeconds
            trustedClockLastObservationAt = now
            trustedClockLastAcceptedAt = now
            lastClockOCRConfirmationAt = now
            lastObservedClockOCRSeconds = rawSeconds
            repeatedClockOCRReadCount += 1
            trustedClockAnchorSeconds = rawSeconds
            trustedClockLastAcceptedWasDirect = directObservation
            trustedClockLastAcceptedWasStopEligible = stopEligibleObservation

            if stopEligibleObservation && priorStopEligible {
                if trustedClockSameValueStartedAt == nil {
                    trustedClockSameValueStartedAt = now
                }
                trustedClockDirectSameValueCount += 1
            } else if stopEligibleObservation {
                trustedClockSameValueStartedAt = now
                trustedClockDirectSameValueCount = 1
            } else {
                trustedClockSameValueStartedAt = nil
                trustedClockDirectSameValueCount = 0
            }
            clockStopCandidateStartedAt = trustedClockSameValueStartedAt

            let stopped = stopEligibleObservation
                && priorStopEligible
                && trustedClockDirectSameValueCount >= stoppedClockMinimumRepeatCount
                && (trustedClockSameValueStartedAt.map {
                    now - $0 >= stoppedClockMinimumConfirmationDuration
                } ?? false)
            trustedClockConfirmedStopped = stopped
            if stopped {
                localClockIsRunning = false
            } else if previousStopped && directObservation {
                // A fresh direct observation clears a stale stop only when movement
                // is subsequently observed. Repeated same-value frames alone remain
                // in the stopped-confirmation path.
                localClockIsRunning = false
            }
            trustedClockLastDecision = stopped
                ? "accepted three fresh direct board reads and confirmed stopped"
                : (stopEligibleObservation
                    ? "accepted direct unchanged board clock; awaiting three-read stopped confirmation"
                    : "accepted unchanged board clock; stop confirmation suppressed for repaired/provisional evidence")
            return RinkLensTrustedClockDecision(
                clockForPublication: formatClock(seconds: rawSeconds),
                acceptedObservation: true,
                publicClockChanged: previousPublicClockSeconds != rawSeconds,
                runningStateChanged: previousRunning != localClockIsRunning || previousStopped != stopped,
                isRunning: localClockIsRunning,
                confirmedStopped: stopped,
                reason: trustedClockLastDecision
            )
        }

        let previousWasRunning = localClockIsRunning
        let previousWasStopped = trustedClockConfirmedStopped

        // Period-style resets are lifecycle boundaries, not movement evidence.
        // Detect them before deriving observed direction so 0:00 -> 20:00 cannot
        // flip a countdown Clock to Count Up.
        let resetDirection = lockedOrConfiguredClockDirection ?? .auto
        let isPlausibleReset = trustedClockResetIsPlausible(
            previousSeconds: lastSeconds,
            nextSeconds: rawSeconds,
            direction: resetDirection
        )
        if isPlausibleReset {
            let evidenceDirection = lockedOrConfiguredClockDirection ?? localClockDirection
            let resetObserved = observeTrustedClockReanchor(
                seconds: rawSeconds,
                direction: evidenceDirection,
                now: now
            )
            guard resetObserved,
                  trustedClockEvidenceState.reanchorCount >= trustedClockLargeCorrectionRequiredCount else {
                trustedClockLastDecision = "held period-style board reset pending bounded stable confirmation"
                return .rejected(
                    trustedClockLastDecision,
                    running: previousWasRunning,
                    stopped: previousWasStopped
                )
            }
            clearTrustedClockDirectionCandidate()
            // Preserve explicit or previously locked Auto direction. An unlocked
            // Auto direction is established only by movement after the reset.
            if gameClockDirection != .auto {
                localClockDirection = gameClockDirection
                autoClockDirectionIsLocked = true
            }
            return acceptTrustedClockAnchor(
                seconds: rawSeconds,
                previousPublicClockSeconds: previousPublicClockSeconds,
                now: now,
                running: false,
                stopped: false,
                directEvidence: directObservation,
                stopEligibleEvidence: stopEligibleObservation,
                reason: "published confirmed period-style scoreboard reset without changing direction"
            )
        }

        let observedDirection: GameClockDirection = delta > 0 ? .countUp : .countDown
        let maxOrdinaryDelta = max(2, Int(ceil(elapsed)) + 2)
        let ordinarySequence = abs(delta) <= maxOrdinaryDelta

        func directionPolicyAllowsObservation() -> Bool {
            switch gameClockDirection {
            case .countDown, .countUp:
                localClockDirection = gameClockDirection
                autoClockDirectionIsLocked = true
                guard observedDirection == gameClockDirection else {
                    clearTrustedClockDirectionCandidate()
                    trustedClockLastDecision = "held board Clock movement opposite explicit \(gameClockDirection.title) direction"
                    return false
                }
                clearTrustedClockDirectionCandidate()
                return true

            case .auto:
                if !autoClockDirectionIsLocked {
                    let previousCandidate = trustedClockDirectionCandidate
                    let confirmed = observeTrustedClockDirectionCandidate(
                        direction: observedDirection,
                        seconds: rawSeconds,
                        now: now,
                        requiredCount: trustedClockInitialDirectionRequiredCount,
                        minimumDuration: 0
                    )
                    if let previousCandidate, previousCandidate != observedDirection {
                        trustedClockLastDecision = "held conflicting Auto direction observation while establishing Clock direction"
                        return false
                    }
                    if confirmed {
                        localClockDirection = observedDirection
                        autoClockDirectionIsLocked = true
                        clearTrustedClockDirectionCandidate()
                    }
                    return true
                }

                guard observedDirection != localClockDirection else {
                    clearTrustedClockDirectionCandidate()
                    return true
                }

                // Direction may change only across a confirmed physical stop/reset
                // boundary. Repeated reverse OCR while the board is running is held.
                guard previousWasStopped || !previousWasRunning else {
                    clearTrustedClockDirectionCandidate()
                    trustedClockLastDecision = "held opposite-direction board reads while physical Clock remained running"
                    return false
                }

                if trustedClockDirectionCandidate == observedDirection,
                   trustedClockDirectionCandidateLastSeconds == rawSeconds {
                    trustedClockLastDecision = "held repeated identical opposite-direction Clock value; direction change requires distinct movement"
                    return false
                }

                let confirmedChange = observeTrustedClockDirectionCandidate(
                    direction: observedDirection,
                    seconds: rawSeconds,
                    now: now,
                    requiredCount: trustedClockDirectionChangeRequiredCount,
                    minimumDuration: trustedClockDirectionChangeRequiredDuration
                )
                guard confirmedChange else {
                    trustedClockLastDecision = "held opposite-direction board reads pending stopped-boundary confirmation"
                    return false
                }
                localClockDirection = observedDirection
                autoClockDirectionIsLocked = true
                clearTrustedClockDirectionCandidate()
                return true
            }
        }

        guard directionPolicyAllowsObservation() else {
            appendSchedulerDiagnostic("clock authority \(trustedClockLastDecision) candidate=\(evaluatedClock)")
            return .rejected(
                trustedClockLastDecision,
                running: previousWasRunning,
                stopped: previousWasStopped
            )
        }

        // Only an observation that passes direction/reset policy may clear a
        // confirmed stop. Rejected opposite-direction values must not mutate the
        // trusted movement state and open a later false re-anchor path.
        trustedClockSameValueStartedAt = nil
        repeatedClockOCRReadCount = 1
        clockStopCandidateStartedAt = nil
        trustedClockConfirmedStopped = false
        trustedClockDirectSameValueCount = 0

        if ordinarySequence {
            return acceptTrustedClockAnchor(
                seconds: rawSeconds,
                previousPublicClockSeconds: previousPublicClockSeconds,
                now: now,
                running: true,
                stopped: false,
                directEvidence: directObservation,
                stopEligibleEvidence: stopEligibleObservation,
                reason: "published monotonic sequential scoreboard Clock from \(evidenceLabel)"
            )
        }

        // Large non-reset corrections remain direction-locked and require a stable
        // bounded sequence. Smoothing ON requires three observations; diagnostics
        // mode with smoothing OFF remains faster but still monotonic.
        let reanchorObserved = observeTrustedClockReanchor(
            seconds: rawSeconds,
            direction: observedDirection,
            now: now
        )
        guard reanchorObserved,
              trustedClockEvidenceState.reanchorCount >= trustedClockLargeCorrectionRequiredCount else {
            trustedClockLastDecision = "held large direction-consistent board-clock correction pending bounded confirmation"
            appendSchedulerDiagnostic("clock authority \(trustedClockLastDecision) from=\(formatClock(seconds: lastSeconds)) candidate=\(evaluatedClock)")
            return .rejected(
                trustedClockLastDecision,
                running: previousWasRunning,
                stopped: previousWasStopped
            )
        }

        return acceptTrustedClockAnchor(
            seconds: rawSeconds,
            previousPublicClockSeconds: previousPublicClockSeconds,
            now: now,
            running: true,
            stopped: false,
            directEvidence: directObservation,
            stopEligibleEvidence: stopEligibleObservation,
            reason: "published bounded monotonic large scoreboard correction"
        )
    }

    private func publishTrustedClockObservationSideEffects(
        _ decision: RinkLensTrustedClockDecision,
        now: CFAbsoluteTime
    ) {
        guard decision.acceptedObservation else { return }

        // Build 527 refreshes the post-restart dwell with every trusted running
        // observation, including a same-second read that does not change MatchState.
        if decision.isRunning {
            if decision.runningStateChanged {
                // Build 551: do not discard a real score/player transaction merely
                // because the physical board restarted before the second OCR read.
                // Confirmation remains bounded by its own evidence window.
                appendSchedulerDiagnostic("Build 551 retained bounded goal/new-penalty transactions across Clock restart")
            }
            gameEventDetector.notePhysicalClockRunning(now: Date())
            flushNormalizedStoppedClockBroadcastEvents(now: Date())
        } else if decision.confirmedStopped {
            gameEventDetector.notePhysicalClockStopped(
                clockText: decision.clockForPublication ?? state.clock
            )
        }

        guard decision.publicClockChanged || decision.runningStateChanged else { return }

        if decision.confirmedStopped {
            BroadcastRecordingManager.shared.noteBroadcastClockRunningChanged(
                isRunning: false,
                period: state.period,
                gameClock: state.clock
            )
        } else if decision.isRunning {
            BroadcastRecordingManager.shared.noteBroadcastClockRunningChanged(
                isRunning: true,
                period: state.period,
                gameClock: state.clock
            )
        }

        guard let clockText = decision.clockForPublication ?? state.clock,
              let clockSeconds = seconds(from: clockText) else { return }
        let eventResult = gameEventDetector.processClockState(
            current: GameClockState(
                clockText: clockText,
                secondsRemaining: clockSeconds,
                isRunning: decision.isRunning,
                observedAt: Date()
            ),
            scoreSnapshot: GameScoreSnapshot(
                homeScore: state.homeScore,
                awayScore: state.awayScore,
                periodText: state.periodLabel ?? state.period.map { String($0) }
            ),
            penaltyRegionChanged: hasActivePenaltyOCRWork,
            now: Date()
        )
        applyGameEventDetectorResult(eventResult, now: now)
    }

    // UX16d10 retains the UX16d9 removal of legacy clock-direction, large-anchor and local-clock
    // mutation paths. Continuous OCR now reaches public MatchState only through
    // evaluateTrustedClockObservation(_:evidence:previous:now:).

    private func applyGameEventDetectorResult(_ result: GameEventDetectionResult, now: CFAbsoluteTime) {
        if result.mode != lastGameEventMode {
            lastGameEventMode = result.mode
            appendSchedulerDiagnostic("event -> mode \(result.mode.rawValue)")
        }

        guard !result.events.isEmpty else { return }
        let eventText = result.events.map { $0.diagnosticText }.joined(separator: ", ")
        appendSchedulerMetricsDiagnostic("event -> \(eventText)", now: now, force: true)
    }

    private func startLocalClockTicker() {
        clockTickTask?.cancel()
        clockTickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run {
                    self?.tickLocalClockIfNeeded()
                }
            }
        }
    }

    func stopSyntheticClock(reason: String) {
        // Legacy call-site name retained for compatibility. Build 509 has no
        // synthetic public game clock; this only clears running-state inference.
        localClockIsRunning = false
        if reason.isEmpty {
            statusMessage = "Clock hold active."
        }
    }

    private func tickLocalClockIfNeeded() {
        guard operatingMode == .ocr else { return }

        // Build 547: this one-second task evaluates event-release windows only.
        // It must never mutate game or penalty clocks. Penalty presentation is
        // projected from trusted physical game-clock movement by OCREvidenceStore.
        flushNormalizedStoppedClockBroadcastEvents(now: Date())
        flushStableGoalFallbackBroadcastEvents(now: Date())
    }

    private func clearPenaltyHashState(for playerKeys: [OCRRegionKey]) {
        for key in playerKeys {
            penaltyPlayerVisualHash.removeValue(forKey: key)
            penaltyTimeVisualHash.removeValue(forKey: PenaltyStateMachine.penaltyTimeKey(forPlayerKey: key))
        }
    }

    @discardableResult
    private func updateSelectedRegionPreview(from pixelBuffer: CVPixelBuffer, force: Bool = false) -> Bool {
        guard currentScreen == .calibration else { return false }
        let now = CFAbsoluteTimeGetCurrent()
        guard force || now - lastSelectedRegionPreviewAt >= selectedRegionPreviewInterval else { return false }
        lastSelectedRegionPreviewAt = now

        let selectedRegion = ocrLayout[selectedRegionKey]
        let cropPreviewSize = authoritativeOCRGeometryViewportSize
        guard cropPreviewSize.width > 10, cropPreviewSize.height > 10 else {
            selectedRegionPreviewStatus = "Waiting for calibrated camera viewport"
            MainThreadStallMonitor.shared.traceRenderPreviewToggle("UX14s crop blocked: preview viewport not ready")
            return false
        }

        // UX16d2g2: Raw/Proc/Thresh now come from the same rectified board crop
        // consumed by live and Test OCR. UX16d2g1 displayed a full-frame crop while
        // the decoder sampled a board-only image with incompatible coordinates.
        guard let evidence = selectedRegionCropProcessor.templateFieldCropEvidence(
            from: pixelBuffer,
            uiRegion: selectedRegion.rect,
            boardCalibration: boardCalibration,
            deviceOrientation: .landscapeLeft,
            previewSize: cropPreviewSize,
            previewRotationDegrees: ocrPreviewRotationOffsetDegrees,
            regionRotationDegrees: selectedRegion.rotationDegrees,
            key: selectedRegionKey,
            maximumBoardDimension: 960
        ) else {
            selectedRegionRawPreviewImage = nil
            selectedRegionProcessedPreviewImage = nil
            selectedRegionThresholdedPreviewImage = nil
            selectedRegionSegmentPreviewImage = nil
            selectedRegionPreviewStatus = "Unable to map selected zone into the rectified scoreboard"
            MainThreadStallMonitor.shared.traceRenderPreviewToggle(
                "UX16d2g2 decoder crop unavailable key=\(selectedRegionKey.rawValue)"
            )
            return false
        }

        let colourProfile = ocrColourProfiles.profile(for: selectedRegionKey)
        let resolvedPipeline = colourProfile.resolvedPipeline(for: selectedRegionKey)
        let preparedRaw = CIImage(cgImage: evidence.image)
        let preparedProcessed = preprocessPreviewCrop(preparedRaw, pipeline: resolvedPipeline)
        let preparedThresholded = preprocessThresholdedPreviewCrop(preparedRaw, pipeline: resolvedPipeline)

        let source = evidence.sourceNormalizedRect
        let board = evidence.boardNormalizedRect
        let previewStatus = String(
            format: "%@ decoder crop • %dx%d px • source %.3f,%.3f %.3fx%.3f • board %.3f,%.3f %.3fx%.3f • %@ • OCR rotation %d°",
            selectedRegionKey.rawValue,
            evidence.image.width,
            evidence.image.height,
            Double(source.minX),
            Double(source.minY),
            Double(source.width),
            Double(source.height),
            Double(board.minX),
            Double(board.minY),
            Double(board.width),
            Double(board.height),
            resolvedPipeline.title,
            Int(ocrPreviewRotationOffsetDegrees.rounded())
        )
        publishSelectedRegionPreviewImages(
            raw: makeUIImage(from: preparedRaw),
            processed: makeUIImage(from: preparedProcessed),
            thresholded: makeThresholdedUIImage(from: preparedThresholded),
            status: previewStatus,
            force: force,
            reason: "UX16d2g2-authoritative-decoder-crop"
        )
        MainThreadStallMonitor.shared.traceRenderPreviewToggle(
            String(
                format: "UX16d2g2 crop map selected=%@ source=%.4f,%.4f %.4fx%.4f board=%.4f,%.4f %.4fx%.4f crop=%dx%d",
                selectedRegionKey.rawValue,
                Double(source.minX),
                Double(source.minY),
                Double(source.width),
                Double(source.height),
                Double(board.minX),
                Double(board.minY),
                Double(board.width),
                Double(board.height),
                evidence.image.width,
                evidence.image.height
            )
        )
        return true
    }

    private func publishSelectedRegionPreviewImages(
        raw: UIImage?,
        processed: UIImage?,
        thresholded: UIImage?,
        status: String,
        force: Bool,
        reason: String
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        let canPublishImages = force || now - lastSelectedRegionImagePublishAt >= selectedRegionImagePublishInterval
        if canPublishImages {
            lastSelectedRegionImagePublishAt = now
            selectedRegionRawPreviewImage = raw
            selectedRegionProcessedPreviewImage = processed
            selectedRegionThresholdedPreviewImage = thresholded
            selectedRegionPreviewStatus = status
            MainThreadStallMonitor.shared.traceRenderPreviewToggle("UX16c3 preview images published reason=\(reason) force=\(force) key=\(selectedRegionKey.rawValue)")
        } else {
            selectedRegionPreviewStatus = status + " • preview image publish throttled"
            MainThreadStallMonitor.shared.traceRenderPreviewToggle(String(format: "UX16c3 preview images throttled reason=%@ key=%@ age=%.2fs", reason, selectedRegionKey.rawValue, now - lastSelectedRegionImagePublishAt))
        }
    }

    private func publishSelectedRegionSegmentPreview(_ image: UIImage?, force: Bool = false, reason: String) {
        let now = CFAbsoluteTimeGetCurrent()
        guard force || now - lastSelectedRegionSegmentImagePublishAt >= selectedRegionImagePublishInterval else {
            MainThreadStallMonitor.shared.traceRenderPreviewToggle(String(format: "UX16c3 segment preview throttled reason=%@ key=%@ age=%.2fs", reason, selectedRegionKey.rawValue, now - lastSelectedRegionSegmentImagePublishAt))
            return
        }
        lastSelectedRegionSegmentImagePublishAt = now
        selectedRegionSegmentPreviewImage = image
        MainThreadStallMonitor.shared.traceRenderPreviewToggle("UX16c3 segment preview published reason=\(reason) key=\(selectedRegionKey.rawValue)")
    }

    private func publishSelectedRegionTestOCR(
        from frame: RinkLensFrameHubFrame,
        key: OCRRegionKey,
        previewSize: CGSize,
        previewRotationDegrees: CGFloat,
        passToken: RinkLensOCRPassToken,
        oneShotID: Int,
        selectedTestGeneration: Int
    ) {
        guard currentScreen == .calibration,
              previewSize.width > 10,
              previewSize.height > 10 else {
            publishTestOCROutcome(
                .cropInvalid,
                detail: "The calibrated camera viewport is not ready.",
                key: key
            )
            _ = ocrOrchestrationEngine.finishPass(
                token: passToken,
                reason: "selected-zone-invalid-preview"
            )
            selectedZoneTestOCRInFlight = false
            return
        }

        selectedZoneLastOneShotAt = CFAbsoluteTimeGetCurrent()
        selectedZoneLastOneShotKey = key
        let layout = ocrLayout
        let thresholds = ocrThresholds
        let colourProfiles = ocrColourProfiles
        let calibration = boardCalibration
        let scoreboardTemplate = activeOCRScoreboardTemplate
        let segmentedFallback = enableSegmentedFallback
        let processingGeneration = ocrProcessingGeneration
        let selectedKey = key
        guard let frameLease = ocrOrchestrationEngine.makeFrameLease(
            pixelBuffer: frame.pixelBuffer,
            generation: processingGeneration,
            passToken: passToken,
            sourceSequence: frame.sequence,
            captureGeneration: frame.captureGeneration,
            sourceDescription: "UX16d2a selected-zone Test OCR FrameHub source"
        ) else {
            publishTestOCROutcome(
                .noCandidate,
                detail: "The camera frame could not be copied into OCR-owned memory. Capture ownership was preserved.",
                key: selectedKey
            )
            selectedZoneTestOCRInFlight = false
            return
        }
        let layoutText = selectedOCRRegionLayoutText()

        let start = "UX16c43 Test OCR recognition start id=\(oneShotID) token=\(passToken.diagnosticText) key=\(selectedKey.rawValue) frame=#\(frame.sequence) captureGeneration=\(frame.captureGeneration) device=\(frame.physicalDeviceID ?? "none") age=\(String(format: "%.3f", frame.ageSeconds))s \(layoutText)"
        smartChangeLastDecisionText = start
        selectedRegionPreviewStatus = "Test OCR recognising \(selectedKey.likelyTitle)..."
        MainThreadStallMonitor.shared.traceOCRPhase(start)

        ocrOrchestrationEngine.recognize(
            frame: frameLease,
            layout: layout,
            boardCalibration: calibration,
            scoreboardTemplate: scoreboardTemplate,
            thresholds: thresholds,
            colourProfiles: colourProfiles,
            previewSize: previewSize,
            previewRotationDegrees: previewRotationDegrees,
            enableSegmentedFallback: segmentedFallback,
            keysToProcess: [selectedKey],
            processorAllowedKeys: [selectedKey],
            includePipelineDiagnostics: true,
            // UX16d5: Test OCR uses the same dynamic token decoder as continuous
            // Broadcast OCR. Preview images may remain richer, but accepted values
            // cannot come from legacy fixed-cell, seven-segment or framework fallbacks.
            executionPolicy: .liveBounded,
            maximumProcessingSeconds: 0.66,
            purpose: "selected-zone-test-dynamic-token"
        ) { [weak self] recognition in
            guard let self else { return }
            defer {
                _ = self.ocrOrchestrationEngine.finishPass(
                    token: recognition.passToken,
                    reason: "selected-zone-complete",
                    elapsedSeconds: recognition.elapsedSeconds
                )
                if self.selectedZoneActiveOneShotID == oneShotID {
                    self.selectedZoneTestOCRInFlight = false
                }
            }

            guard self.ocrOrchestrationEngine.isPassCurrent(recognition.passToken) else {
                self.testOCRStaleResultPreventionCount &+= 1
                MainThreadStallMonitor.shared.traceOCRPhase("UX16c47 stale Test OCR pass token fenced id=\(oneShotID) key=\(selectedKey.rawValue)")
                return
            }
            guard self.selectedZoneTestOCRGeneration == selectedTestGeneration,
                  self.selectedRegionKey == selectedKey,
                  self.selectedZoneActiveOneShotID == oneShotID else {
                self.testOCRStaleResultPreventionCount &+= 1
                let detail = "Result rejected because the selected zone or Test OCR generation changed."
                self.publishTestOCROutcome(.rejected, detail: detail, key: selectedKey)
                MainThreadStallMonitor.shared.traceOCRPhase(
                    "UX16c43 stale Test OCR result id=\(oneShotID) key=\(selectedKey.rawValue)"
                )
                return
            }
            guard self.ocrProcessingGeneration == processingGeneration else {
                self.testOCRStaleResultPreventionCount &+= 1
                self.publishTestOCROutcome(
                    .rejected,
                    detail: "Result belongs to an earlier capture generation.",
                    key: selectedKey
                )
                return
            }

            self.testOCRCurrentResultPublicationCount &+= 1

            guard let result = recognition.output else {
                self.recordTestOCRFailureDiagnostic(
                    key: selectedKey,
                    reason: "The recogniser returned no candidate."
                )
                self.publishTestOCROutcome(
                    .noCandidate,
                    detail: "The recogniser returned no candidate.",
                    key: selectedKey
                )
                return
            }

            self.updateRegionPreviewText(from: result.rawText)
            self.updateRegionRecognizers(from: result.fieldDebug)
            self.ocrFieldConfidence = self.ocrSmoothingEngine.updateConfidence(from: result.fieldDebug)
            self.ocrTrustSummary = self.ocrSmoothingEngine.trustSummary()

            guard let field = result.fieldDebug.first(where: { $0.key == selectedKey }) else {
                self.recordTestOCRFailureDiagnostic(
                    key: selectedKey,
                    reason: "The recogniser returned fields, but none for the selected zone."
                )
                self.publishTestOCROutcome(
                    .noCandidate,
                    detail: "The recogniser returned fields, but none for the selected zone.",
                    key: selectedKey
                )
                return
            }

            let diagnosticText = self.diagnosticDisplayText(for: field)
            self.mutableAcceptedFieldState[field.key] = AcceptedOCRValueState(
                acceptedText: diagnosticText,
                lastConfidence: field.confidence,
                recognizerUsed: field.recognizer,
                lastUpdated: .now
            )

            let accepted = field.accepted.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = field.cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = field.raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let pipeline = field.pipelineDiagnostic

            if !accepted.isEmpty {
                self.lastTestOCRAcceptedValue[selectedKey] = accepted
                self.lastTestOCRFrameSequence[selectedKey] = frame.sequence
                MainThreadStallMonitor.shared.traceOCRPhase(
                    "UX16d13 test-reference key=\(selectedKey.rawValue) accepted=\(accepted) frame=#\(frame.sequence) captureGeneration=\(frame.captureGeneration) validation=\(field.validation) \(field.pipelineDiagnostic)"
                )
                self.pendingTestOCRResult = RinkLensPendingTestOCRResult(
                    key: selectedKey,
                    value: accepted,
                    raw: field.raw,
                    cleaned: field.cleaned,
                    validation: field.validation,
                    confidence: field.confidence,
                    recognizer: field.recognizer,
                    captureGeneration: frame.captureGeneration,
                    frameSequence: frame.sequence
                )
                let manualApplyDecision = RinkLensTestOCRAutoApplyPolicy.evaluate(
                    key: selectedKey,
                    candidateText: accepted,
                    visibleState: self.state
                )
                self.pendingTestOCRApplyDescription = "Apply Manual: \(selectedKey.likelyTitle) \(accepted)"
                self.publishTestOCROutcome(
                    .recognised,
                    detail: "Verified \(accepted) • diagnostics only • \(field.recognizer.rawValue) • confidence \(Int((field.confidence * 100).rounded()))% • manual correction available (\(manualApplyDecision.reason))",
                    key: selectedKey
                )
                self.statusMessage = "Verify Zone read \(selectedKey.likelyTitle) as \(accepted). Broadcast was not changed."
                MainThreadStallMonitor.shared.traceOCRPhase(
                    "UX16d15j Verify Zone diagnostics-only key=\(selectedKey.rawValue) value=\(accepted) manualCorrectionAvailable=true reason=\(manualApplyDecision.reason)"
                )
            } else {
                self.pendingTestOCRResult = nil
                self.pendingTestOCRApplyDescription = nil
                let shown = candidate.isEmpty ? (raw.isEmpty ? "no candidate" : raw) : candidate
                self.publishTestOCROutcome(
                    .rejected,
                    detail: "Candidate \(shown) was rejected: \(field.validation).",
                    key: selectedKey
                )
            }

            self.recordOCRFieldPublicationDiagnostics(
                flow: .testOCR,
                fields: [field],
                reduction: nil,
                visibleState: self.state
            )

            self.smartChangeLastDecisionText = "UX16d15j Verify Zone key=\(selectedKey.rawValue) raw=\(field.raw) cleaned=\(field.cleaned) accepted=\(field.accepted.isEmpty ? "--" : field.accepted) diagnosticsOnly=true manualAvailable=\(!accepted.isEmpty) visible=\(self.visibleScorebugValue(for: selectedKey, in: self.state)) validation=\(field.validation) frame=#\(frame.sequence) \(pipeline)"
            MainThreadStallMonitor.shared.traceOCRPhase(self.smartChangeLastDecisionText)
        }
    }

    private func recordTestOCRFailureDiagnostic(key: OCRRegionKey, reason: String) {
        ocrDiagnostics.recordFieldPublication(
            RinkLensOCRFieldPublicationDiagnostic(
                key: key,
                flow: .testOCR,
                rawCandidate: "",
                cleanedCandidate: "",
                confidence: 0,
                acceptanceReason: "Rejected: \(reason)",
                reducerOutcome: "Reducer bypassed — no accepted Test OCR result",
                visibleScorebugValue: visibleScorebugValue(for: key, in: state),
                updatedAt: .now
            )
        )
    }

    private func publishTestOCROutcome(
        _ outcome: RinkLensTestOCROutcome,
        detail: String,
        key: OCRRegionKey
    ) {
        testOCROutcome = outcome
        testOCROutcomeText = "\(outcome.label): \(detail)"
        selectedRegionPreviewStatus = "Test OCR \(key.likelyTitle): \(outcome.label) • \(detail)"
        if outcome != .recognised {
            pendingTestOCRResult = nil
            pendingTestOCRApplyDescription = nil
        }
        MainThreadStallMonitor.shared.traceOCRPhase(
            "UX16c43 Test OCR outcome=\(outcome.rawValue) key=\(key.rawValue) detail=\(detail)"
        )
    }

    func applySelectedTestOCRResult() {
        guard let pending = pendingTestOCRResult else {
            statusMessage = "There is no verified zone result available for manual correction."
            return
        }

        let context = RinkLensMatchStateContext(
            origin: .manual,
            eventPolicy: [],
            diagnosticsOnly: false,
            reason: "Operator applied manual OCR correction for \(pending.key.rawValue) from verified frame #\(pending.frameSequence) generation \(pending.captureGeneration)"
        )

        let reduction: RinkLensMatchStateReduction
        switch pending.key {
        case .clock:
            reduction = reduceMatchState(.setClock(pending.value, context: context))
            seedTrustedClockAuthorityFromOperatorConfirmedTest(
                clock: pending.value,
                frameSequence: pending.frameSequence,
                captureGeneration: pending.captureGeneration
            )
        case .homeScore:
            reduction = reduceMatchState(.setScores(home: Int(pending.value), away: state.awayScore, context: context))
        case .awayScore:
            reduction = reduceMatchState(.setScores(home: state.homeScore, away: Int(pending.value), context: context))
        case .period:
            reduction = reduceMatchState(.setPeriod(Int(pending.value), label: pending.value, context: context))
        case .homePenalty1Player:
            reduction = reduceMatchState(.setPenalty(slot: .home1, player: Int(pending.value), clock: state.homePenalty1Clock, context: context))
        case .homePenalty1Time:
            reduction = reduceMatchState(.setPenalty(slot: .home1, player: state.homePenalty1Player, clock: pending.value, context: context))
        case .homePenalty2Player:
            reduction = reduceMatchState(.setPenalty(slot: .home2, player: Int(pending.value), clock: state.homePenalty2Clock, context: context))
        case .homePenalty2Time:
            reduction = reduceMatchState(.setPenalty(slot: .home2, player: state.homePenalty2Player, clock: pending.value, context: context))
        case .awayPenalty1Player:
            reduction = reduceMatchState(.setPenalty(slot: .away1, player: Int(pending.value), clock: state.awayPenalty1Clock, context: context))
        case .awayPenalty1Time:
            reduction = reduceMatchState(.setPenalty(slot: .away1, player: state.awayPenalty1Player, clock: pending.value, context: context))
        case .awayPenalty2Player:
            reduction = reduceMatchState(.setPenalty(slot: .away2, player: Int(pending.value), clock: state.awayPenalty2Clock, context: context))
        case .awayPenalty2Time:
            reduction = reduceMatchState(.setPenalty(slot: .away2, player: state.awayPenalty2Player, clock: pending.value, context: context))
        case .homeShots, .awayShots:
            statusMessage = "Shots OCR has been removed and cannot be applied."
            return
        }

        if pending.key == .homeScore || pending.key == .awayScore || pending.key == .period {
            ocrPublicationSafetyState.seedOperatorConfirmedBaseline(for: pending.key)
            operatorConfirmedTestOCRBaselines[pending.key] = pending.value
            appendSchedulerDiagnostic(
                "UX16d15 operator-confirmed static baseline key=\(pending.key.rawValue) value=\(pending.value) captureGeneration=\(pending.captureGeneration)"
            )
        }

        ocrDiagnostics.recordFieldPublication(
            RinkLensOCRFieldPublicationDiagnostic(
                key: pending.key,
                flow: .testOCR,
                rawCandidate: pending.raw,
                cleanedCandidate: pending.cleaned,
                confidence: pending.confidence,
                acceptanceReason: "Operator applied verified value as a manual correction: \(pending.validation)",
                reducerOutcome: reduction.changed
                    ? "Manual correction applied through unified MatchState reducer"
                    : "Manual correction matched the existing visible value",
                visibleScorebugValue: visibleScorebugValue(for: pending.key, in: state),
                updatedAt: .now
            )
        )

        let liveValue = visibleScorebugValue(for: pending.key, in: state)
        let commitLabel = reduction.changed ? "Manual correction committed" : "Manual correction confirmed"
        testOCROutcome = .recognised
        testOCROutcomeText = "\(commitLabel): \(pending.key.likelyTitle) \(liveValue)"
        selectedRegionPreviewStatus = "Manual correction \(pending.key.likelyTitle): \(commitLabel) • verified \(pending.value) • live \(liveValue)"
        statusMessage = "\(commitLabel) — \(pending.key.likelyTitle): \(liveValue)"
        pendingTestOCRResult = nil
        pendingTestOCRApplyDescription = nil
        MainThreadStallMonitor.shared.traceOCRPhase(
            "UX16d15j manual correction committed key=\(pending.key.rawValue) verified=\(pending.value) live=\(liveValue) reducerChanged=\(reduction.changed)"
        )
    }

    private struct SelectedZoneStableCandidate {
        var value: String
        var count: Int
        var firstSeen: CFAbsoluteTime
        var lastSeen: CFAbsoluteTime
        var source: String
    }

    private struct ActiveClusterOCRCandidate {
        let text: String
        let confidence: Float
    }

    private struct ActiveClusterParsedValue {
        let value: String
        let rawText: String
        let confidence: Float
    }

    private struct ActiveColourClusterImage {
        let cleanImage: CGImage
        let activeBounds: CGRect
        let activeFraction: Double
        let diagnostic: String
    }

    private func makeActiveColourClusterImage(from image: CGImage, pipeline: OCRColourPipeline, key: OCRRegionKey) -> ActiveColourClusterImage? {
        let width = image.width
        let height = image.height
        guard width > 4, height > 4 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let drew = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }

        var minX = width
        var minY = height
        var maxX = 0
        var maxY = 0
        var activeCount = 0
        var activeMask = [Bool](repeating: false, count: width * height)
        var leftActive = 0
        var rightActive = 0
        let leftBand = max(1, width / 5)
        let rightBandStart = max(0, width - leftBand)

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let r = Int(pixels[offset])
                let g = Int(pixels[offset + 1])
                let b = Int(pixels[offset + 2])
                let active = isExpectedActivePixel(r: r, g: g, b: b, pipeline: pipeline, key: key)
                if active {
                    activeMask[y * width + x] = true
                    activeCount += 1
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                    if x < leftBand { leftActive += 1 }
                    if x >= rightBandStart { rightActive += 1 }
                }
            }
        }

        let total = max(1, width * height)
        let activeFraction = Double(activeCount) / Double(total)
        guard activeCount >= 18, activeFraction >= 0.0015, minX < maxX, minY < maxY else {
            return nil
        }

        let padX = max(4, Int(Double(maxX - minX + 1) * 0.08))
        let padY = max(3, Int(Double(maxY - minY + 1) * 0.12))
        let cropMinX = max(0, minX - padX)
        let cropMinY = max(0, minY - padY)
        let cropMaxX = min(width - 1, maxX + padX)
        let cropMaxY = min(height - 1, maxY + padY)
        let cropW = cropMaxX - cropMinX + 1
        let cropH = cropMaxY - cropMinY + 1
        guard cropW > 4, cropH > 4 else { return nil }

        let scale = cropH < 72 ? 4 : 3
        let outW = max(16, cropW * scale)
        let outH = max(16, cropH * scale)
        var output = [UInt8](repeating: 0, count: outW * outH * 4)

        for y in 0..<outH {
            let srcY = cropMinY + min(cropH - 1, y / scale)
            for x in 0..<outW {
                let srcX = cropMinX + min(cropW - 1, x / scale)
                let srcIndex = srcY * width + srcX
                let dst = (y * outW + x) * 4
                if activeMask[srcIndex] {
                    output[dst] = 255
                    output[dst + 1] = 255
                    output[dst + 2] = 255
                    output[dst + 3] = 255
                } else {
                    output[dst] = 0
                    output[dst + 1] = 0
                    output[dst + 2] = 0
                    output[dst + 3] = 255
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(output) as CFData),
              let clean = CGImage(
                width: outW,
                height: outH,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: outW * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              )
        else { return nil }

        let bounds = CGRect(
            x: CGFloat(cropMinX) / CGFloat(width),
            y: CGFloat(cropMinY) / CGFloat(height),
            width: CGFloat(cropW) / CGFloat(width),
            height: CGFloat(cropH) / CGFloat(height)
        )
        let diagnostic = String(
            format: "active=%.1f%% bounds=%.2f-%.2fx%.2f-%.2f px=%dx%d scaled=%dx%d edgeL=%d edgeR=%d",
            activeFraction * 100,
            bounds.minX, bounds.maxX, bounds.minY, bounds.maxY,
            cropW, cropH, outW, outH, leftActive, rightActive
        )
        return ActiveColourClusterImage(cleanImage: clean, activeBounds: bounds, activeFraction: activeFraction, diagnostic: diagnostic)
    }

    private func isExpectedActivePixel(r: Int, g: Int, b: Int, pipeline: OCRColourPipeline, key: OCRRegionKey) -> Bool {
        let maxChannel = max(r, max(g, b))
        let minChannel = min(r, min(g, b))
        let brightness = (r + g + b) / 3
        switch pipeline {
        case .redOnBlack:
            return r >= 70 && r > g + 18 && r > b + 18 && r >= Int(Double(max(g, b)) * 1.20)
        case .yellowWhiteOnBlack, .amberOrangeOnBlack:
            let yellow = r >= 80 && g >= 65 && b <= max(120, min(r, g) - 8)
            let white = brightness >= 150 && maxChannel - minChannel <= 70
            return yellow || white
        case .greenOnBlack:
            return g >= 70 && g > r + 12 && g > b + 12
        case .blueCyanOnBlack:
            return b >= 70 && b > r + 12
        case .darkOnLight:
            return brightness <= 110 && maxChannel - minChannel <= 95
        case .lightOnDark, .auto, .greyscale:
            return brightness >= 145 && maxChannel - minChannel <= 140
        }
    }

    private func recogniseTextCandidates(from image: CGImage, key: OCRRegionKey) -> [ActiveClusterOCRCandidate] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.01
        if #available(iOS 16.0, *) {
            request.automaticallyDetectsLanguage = false
        }
        request.recognitionLanguages = ["en-US"]

        do {
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
            try handler.perform([request])
            let observations = request.results ?? []
            let candidates = observations.flatMap { observation in
                observation.topCandidates(3).map { candidate in
                    ActiveClusterOCRCandidate(text: candidate.string, confidence: candidate.confidence)
                }
            }
            return candidates.sorted { $0.confidence > $1.confidence }
        } catch {
            MainThreadStallMonitor.shared.traceOCRPhase("UX16c Vision OCR error key=\(key.rawValue) error=\(error.localizedDescription)")
            return []
        }
    }

    private func parseSelectedZoneCandidates(_ candidates: [ActiveClusterOCRCandidate], key: OCRRegionKey) -> ActiveClusterParsedValue? {
        for candidate in candidates {
            if let value = parseSelectedZoneText(candidate.text, key: key) {
                return ActiveClusterParsedValue(value: value, rawText: candidate.text, confidence: max(0.30, candidate.confidence))
            }
        }
        // Vision sometimes returns each character separately. Join candidates and try once more.
        let joined = candidates.prefix(4).map { $0.text }.joined()
        if !joined.isEmpty, let value = parseSelectedZoneText(joined, key: key) {
            let confidence = candidates.prefix(4).map(\.confidence).max() ?? 0.35
            return ActiveClusterParsedValue(value: value, rawText: joined, confidence: confidence)
        }
        return nil
    }

    private func parseSelectedZoneText(_ text: String, key: OCRRegionKey) -> String? {
        let normalised = normaliseSevenSegmentLikeText(text)
        if isOCRTimerDiagnosticsKey(key) {
            guard let timer = parseTimerText(normalised) else { return nil }
            return key == .clock ? (isValidTimer(timer) ? timer : nil) : (isValidPenaltyTimer(timer) ? timer : nil)
        }

        let digits = normalised.filter { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        switch key {
        case .period:
            guard let digit = digits.first, ["1", "2", "3", "4", "5"].contains(String(digit)) else { return nil }
            return String(digit)
        case .homeScore, .awayScore, .homePenalty1Player, .homePenalty2Player, .awayPenalty1Player, .awayPenalty2Player:
            let clipped = String(digits.prefix(2))
            guard let number = Int(clipped), (0...99).contains(number) else { return nil }
            return String(number)
        default:
            return nil
        }
    }

    private func normaliseSevenSegmentLikeText(_ text: String) -> String {
        var output = ""
        for char in text.uppercased() {
            switch char {
            case "0"..."9": output.append(char)
            case "O", "D", "Q": output.append("0")
            case "I", "L", "|", "!": output.append("1")
            case "Z": output.append("2")
            case "A": output.append("4")
            case "S", "$": output.append("5")
            case "G": output.append("6")
            case "T": output.append("7")
            case "B": output.append("8")
            case ":", ";", ".", ",", "-": output.append(":")
            default: continue
            }
        }
        return output
    }

    private func parseTimerText(_ text: String) -> String? {
        let cleaned = text.filter { $0.isNumber || $0 == ":" }
        guard !cleaned.isEmpty else { return nil }
        if cleaned.contains(":") {
            let parts = cleaned.split(separator: ":", omittingEmptySubsequences: true).map { String($0) }
            guard parts.count >= 2 else { return nil }
            let minuteDigits = parts[0].filter { $0.isNumber }
            let secondDigits = parts[1...].joined().filter { $0.isNumber }
            guard !minuteDigits.isEmpty, secondDigits.count >= 1 else { return nil }
            let minutesText = String(minuteDigits.suffix(2))
            let secondsText = String(secondDigits.suffix(2))
            guard let minutes = Int(minutesText), let seconds = Int(secondsText), seconds < 60 else { return nil }
            return String(format: "%d:%02d", minutes, seconds)
        }

        let digits = cleaned.filter { $0.isNumber }
        guard digits.count >= 3 else { return nil }
        let secondsText = String(digits.suffix(2))
        let minutesText = String(digits.dropLast(2).suffix(2))
        guard let minutes = Int(minutesText), let seconds = Int(secondsText), seconds < 60 else { return nil }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func stableDecision(for key: OCRRegionKey, value: String, confidence: Float, source: String) -> (accepted: Bool, reason: String, stableCount: Int) {
        let now = CFAbsoluteTimeGetCurrent()
        var candidate = selectedZoneStableCandidates[key]
        if candidate?.value == value {
            candidate?.count += 1
            candidate?.lastSeen = now
            candidate?.source = source
        } else {
            candidate = SelectedZoneStableCandidate(value: value, count: 1, firstSeen: now, lastSeen: now, source: source)
        }
        selectedZoneStableCandidates[key] = candidate
        let stableCount = candidate?.count ?? 1

        let lastAccepted = acceptedFieldState[key]?.acceptedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let temporallyPlausible = isTemporallyPlausible(key: key, previous: lastAccepted, candidate: value)
        let strongSingleRead = confidence >= 0.86 && temporallyPlausible
        let lightweightSingleRead = source == "lightweight" && confidence >= 0.70 && temporallyPlausible
        let repeatedRead = stableCount >= 2 && temporallyPlausible
        let noPriorValue = (lastAccepted == nil || lastAccepted == "" || lastAccepted == "--")
        let acceptableNewValue = noPriorValue && stableCount >= 2

        if strongSingleRead || lightweightSingleRead || repeatedRead || acceptableNewValue {
            return (true, "accepted temporal=pass source=\(source) conf=\(String(format: "%.2f", confidence))", stableCount)
        }

        // UX16c1: selected Calibration/Test OCR should be allowed to establish a
        // new baseline when the clean active-cluster OCR read is strong. The
        // previous accepted value can be stale after zone movement, zoom change,
        // profile changes, or earlier bad reads. Keep this override OCR-only so
        // seven-segment/template fallback cannot confidently overwrite a good
        // state with a bad split.
        let calibrationOCRBaselineReset = ((source == "ocr" && confidence >= 0.90) || (source == "lightweight" && confidence >= 0.78)) && stableCount >= 1
        if !temporallyPlausible, calibrationOCRBaselineReset {
            return (true, "accepted calibration-ocr-baseline-reset previous=\(lastAccepted ?? "--") source=\(source) conf=\(String(format: "%.2f", confidence))", stableCount)
        }

        if !temporallyPlausible {
            return (false, "held temporal=reject previous=\(lastAccepted ?? "--") source=\(source) conf=\(String(format: "%.2f", confidence))", stableCount)
        }
        return (false, "pending repeat source=\(source) conf=\(String(format: "%.2f", confidence))", stableCount)
    }

    private func isTemporallyPlausible(key: OCRRegionKey, previous: String?, candidate: String) -> Bool {
        guard let previous, !previous.isEmpty, previous != "--" else { return true }
        if isOCRTimerDiagnosticsKey(key) {
            guard let previousSeconds = timerSeconds(previous), let candidateSeconds = timerSeconds(candidate) else { return true }
            return abs(candidateSeconds - previousSeconds) <= 8 || previousSeconds == 0
        }
        guard let previousNumber = Int(previous), let candidateNumber = Int(candidate) else { return true }
        switch key {
        case .homeScore, .awayScore:
            return abs(candidateNumber - previousNumber) <= 1
        case .period:
            return candidateNumber >= previousNumber && candidateNumber - previousNumber <= 1
        case .homePenalty1Player, .homePenalty2Player, .awayPenalty1Player, .awayPenalty2Player:
            return candidateNumber == previousNumber
        default:
            return true
        }
    }

    private func timerSeconds(_ value: String) -> Int? {
        let parts = value.split(separator: ":").map { String($0) }
        guard parts.count == 2, let minutes = Int(parts[0]), let seconds = Int(parts[1]), seconds < 60 else { return nil }
        return minutes * 60 + seconds
    }

    private func publishSelectedZoneNoFrameFailure(source: String) {
        selectedRegionRawPreviewImage = nil
        selectedRegionProcessedPreviewImage = nil
        selectedRegionThresholdedPreviewImage = nil
        selectedRegionSegmentPreviewImage = nil
        mutableAcceptedFieldState[selectedRegionKey] = AcceptedOCRValueState(
            acceptedText: nil,
            lastConfidence: 0,
            recognizerUsed: .segmented,
            lastUpdated: .now
        )
        let detail = "UX16b1 testOCR failed reason=no-frame-available source=\(source) key=\(selectedRegionKey.rawValue) \(selectedOCRRegionLayoutText())"
        selectedRegionPreviewStatus = "Test OCR \(selectedRegionKey.likelyTitle): no frame available — keep OCR Setup open and wait for preview to update."
        smartChangeLastDecisionText = detail
        MainThreadStallMonitor.shared.traceOCRPhase(detail)
        MainThreadStallMonitor.shared.traceRenderPreviewToggle(detail)
    }

    private func publishSelectedZoneSegmentationSuccess(
        oneShotID: Int,
        key: OCRRegionKey,
        value: String,
        confidence: Float,
        recognizer: RecognitionStrategy,
        validation: String,
        diagnostic: String
    ) {
        guard selectedRegionKey == key, selectedZoneActiveOneShotID == oneShotID else {
            testOCRStaleResultPreventionCount &+= 1
            MainThreadStallMonitor.shared.traceOCRPhase("UX16c5 selected publish ignored stale id=\(oneShotID) key=\(key.rawValue) selected=\(selectedRegionKey.rawValue) activeID=\(selectedZoneActiveOneShotID)")
            return
        }
        mutableAcceptedFieldState[key] = AcceptedOCRValueState(
            acceptedText: value,
            lastConfidence: confidence,
            recognizerUsed: recognizer,
            lastUpdated: .now
        )
        selectedRegionPreviewStatus = "Test OCR \(key.likelyTitle): \(value) • \(validation) • conf \(Int((confidence * 100).rounded()))%"
        smartChangeLastDecisionText = "UX16c5 selected-zone primary OCR accepted id=\(oneShotID) key=\(key.rawValue) value=\(value) validation=\(validation) \(diagnostic)"
        MainThreadStallMonitor.shared.traceOCRPhase("UX16c5 selected publish id=\(oneShotID) key=\(key.rawValue) value=\(value) conf=\(String(format: "%.2f", confidence)) \(diagnostic)")
        MainThreadStallMonitor.shared.traceRenderPreviewToggle("UX16c5 selected publish id=\(oneShotID) key=\(key.rawValue) value=\(value)")
    }

    private func publishSelectedZoneActiveOCRFailure(
        oneShotID: Int,
        key: OCRRegionKey,
        reason: String,
        diagnostic: String
    ) {
        guard selectedRegionKey == key, selectedZoneActiveOneShotID == oneShotID else {
            testOCRStaleResultPreventionCount &+= 1
            MainThreadStallMonitor.shared.traceOCRPhase("UX16c5 selected failure ignored stale id=\(oneShotID) key=\(key.rawValue) selected=\(selectedRegionKey.rawValue) activeID=\(selectedZoneActiveOneShotID)")
            return
        }
        // UX16c2: a held/failed selected Test OCR read must not leave a stale
        // accepted value in the bottom diagnostics pill. This is Calibration/Test
        // only and does not change production live OCR state.
        mutableAcceptedFieldState[key] = AcceptedOCRValueState(
            acceptedText: nil,
            lastConfidence: 0,
            recognizerUsed: .none,
            lastUpdated: .now
        )
        selectedRegionPreviewStatus = "Test OCR \(key.likelyTitle): OCR not accepted • \(reason)"
        smartChangeLastDecisionText = "UX16c2 selected-zone active OCR not accepted id=\(oneShotID) key=\(key.rawValue) reason=\(reason) \(diagnostic)"
        MainThreadStallMonitor.shared.traceOCRPhase("UX16c2 active OCR not accepted id=\(oneShotID) key=\(key.rawValue) reason=\(reason) \(diagnostic)")
        MainThreadStallMonitor.shared.traceRenderPreviewToggle("UX16c2 active OCR not accepted id=\(oneShotID) key=\(key.rawValue) reason=\(reason)")
    }

    private func publishSelectedZoneSegmentationFailure(
        oneShotID: Int,
        key: OCRRegionKey,
        reason: String,
        diagnostic: String
    ) {
        selectedRegionPreviewStatus = "Test OCR \(key.likelyTitle): segmentation failed • \(reason)"
        smartChangeLastDecisionText = "UX15k selected-zone segmentation failed id=\(oneShotID) key=\(key.rawValue) reason=\(reason) \(diagnostic)"
        MainThreadStallMonitor.shared.traceOCRPhase("UX15k segmentation failure id=\(oneShotID) key=\(key.rawValue) reason=\(reason) \(diagnostic)")
        MainThreadStallMonitor.shared.traceRenderPreviewToggle("UX15k segmentation failure id=\(oneShotID) key=\(key.rawValue) reason=\(reason)")
    }

    private func resolvedLocalClockDirection() -> GameClockDirection {
        switch gameClockDirection {
        case .countUp, .countDown:
            return gameClockDirection
        case .auto:
            return localClockDirection
        }
    }

    private func formatClock(seconds: Int) -> String {
        let clamped = max(0, min(20 * 60, seconds))
        return String(format: "%d:%02d", clamped / 60, clamped % 60)
    }

    private func normalizedOCRCrop(from uiRect: CGRect, imageSize: CGSize, previewSize: CGSize, previewRotationDegrees: CGFloat = 0) -> CGRect {
        guard previewSize.width > 1, previewSize.height > 1, imageSize.width > 1, imageSize.height > 1 else {
            return CGRect(
                x: uiRect.minX,
                y: 1.0 - uiRect.minY - uiRect.height,
                width: uiRect.width,
                height: uiRect.height
            )
        }

        let mappedUIRect = rotatedNormalizedRect(uiRect, by: previewRotationDegrees)

        let scale = min(previewSize.width / imageSize.width, previewSize.height / imageSize.height)
        let displayedWidth = imageSize.width * scale
        let displayedHeight = imageSize.height * scale
        let offsetX = (previewSize.width - displayedWidth) * 0.5
        let offsetY = (previewSize.height - displayedHeight) * 0.5

        let uiAbsolute = CGRect(
            x: mappedUIRect.minX * previewSize.width,
            y: mappedUIRect.minY * previewSize.height,
            width: mappedUIRect.width * previewSize.width,
            height: mappedUIRect.height * previewSize.height
        )

        var normalized = CGRect(
            x: (uiAbsolute.minX - offsetX) / displayedWidth,
            y: (uiAbsolute.minY - offsetY) / displayedHeight,
            width: uiAbsolute.width / displayedWidth,
            height: uiAbsolute.height / displayedHeight
        )
        normalized.origin.x = max(0, min(1, normalized.origin.x))
        normalized.origin.y = max(0, min(1, normalized.origin.y))
        normalized.size.width = max(0.001, min(1 - normalized.origin.x, normalized.size.width))
        normalized.size.height = max(0.001, min(1 - normalized.origin.y, normalized.size.height))

        return CGRect(
            x: normalized.minX,
            y: 1.0 - normalized.minY - normalized.height,
            width: normalized.width,
            height: normalized.height
        )
    }


    private func rotatedNormalizedRect(_ rect: CGRect, by degrees: CGFloat) -> CGRect {
        let normalized = Int((degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360))
        switch normalized {
        case 90:
            return CGRect(x: rect.minY, y: 1.0 - rect.minX - rect.width, width: rect.height, height: rect.width)
        case 180:
            return CGRect(x: 1.0 - rect.minX - rect.width, y: 1.0 - rect.minY - rect.height, width: rect.width, height: rect.height)
        case 270:
            return CGRect(x: 1.0 - rect.minY - rect.height, y: rect.minX, width: rect.height, height: rect.width)
        default:
            return rect
        }
    }

    private func applyPreviewRotation(_ image: CIImage, degrees: CGFloat) -> CIImage {
        let outputExtent = CGRect(origin: .zero, size: image.extent.size)
        guard abs(degrees) > 0.05 else {
            return image.cropped(to: outputExtent)
        }

        let radians = degrees * .pi / 180
        let centre = CGPoint(x: outputExtent.midX, y: outputExtent.midY)
        let transform = CGAffineTransform(translationX: centre.x, y: centre.y)
            .rotated(by: radians)
            .translatedBy(x: -centre.x, y: -centre.y)

        return image.transformed(by: transform).cropped(to: outputExtent)
    }

    private func preprocessPreviewCrop(_ image: CIImage, pipeline: OCRColourPipeline) -> CIImage {
        colourPipelinePreviewImage(image, pipeline: pipeline)
            .applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: 0.72
            ])
    }

    private func preprocessThresholdedPreviewCrop(_ image: CIImage, pipeline: OCRColourPipeline) -> CIImage {
        colourPipelinePreviewImage(image, pipeline: pipeline)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.25,
                kCIInputBrightnessKey: 0.02
            ])
            .applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: 0.82
            ])
    }

    private func colourPipelinePreviewImage(_ image: CIImage, pipeline: OCRColourPipeline) -> CIImage {
        switch pipeline {
        case .redOnBlack:
            return image
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1.8, y: -0.75, z: -0.75, w: 0),
                    "inputGVector": CIVector(x: 1.8, y: -0.75, z: -0.75, w: 0),
                    "inputBVector": CIVector(x: 1.8, y: -0.75, z: -0.75, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputBiasVector": CIVector(x: 0.05, y: 0.05, z: 0.05, w: 0)
                ])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0, kCIInputContrastKey: 4.0, kCIInputBrightnessKey: 0.10])
        case .yellowWhiteOnBlack:
            return image
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.60, y: 0.60, z: -0.35, w: 0),
                    "inputGVector": CIVector(x: 0.60, y: 0.60, z: -0.35, w: 0),
                    "inputBVector": CIVector(x: 0.60, y: 0.60, z: -0.35, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
                ])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0, kCIInputContrastKey: 3.4, kCIInputBrightnessKey: 0.08])
        case .amberOrangeOnBlack:
            return image
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1.10, y: 0.45, z: -0.50, w: 0),
                    "inputGVector": CIVector(x: 1.10, y: 0.45, z: -0.50, w: 0),
                    "inputBVector": CIVector(x: 1.10, y: 0.45, z: -0.50, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
                ])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0, kCIInputContrastKey: 3.7, kCIInputBrightnessKey: 0.08])
        case .greenOnBlack:
            return image
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: -0.55, y: 1.70, z: -0.55, w: 0),
                    "inputGVector": CIVector(x: -0.55, y: 1.70, z: -0.55, w: 0),
                    "inputBVector": CIVector(x: -0.55, y: 1.70, z: -0.55, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
                ])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0, kCIInputContrastKey: 3.5, kCIInputBrightnessKey: 0.08])
        case .blueCyanOnBlack:
            return image
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: -0.45, y: -0.25, z: 1.65, w: 0),
                    "inputGVector": CIVector(x: -0.45, y: -0.25, z: 1.65, w: 0),
                    "inputBVector": CIVector(x: -0.45, y: -0.25, z: 1.65, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
                ])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0, kCIInputContrastKey: 3.4, kCIInputBrightnessKey: 0.08])
        case .darkOnLight:
            return image
                .applyingFilter("CIPhotoEffectMono")
                .applyingFilter("CIColorInvert")
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 3.0, kCIInputBrightnessKey: 0.02])
        case .lightOnDark, .auto, .greyscale:
            return image
                .applyingFilter("CIPhotoEffectMono")
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 2.8, kCIInputBrightnessKey: 0.06])
        }
    }

    private func normalizedSegmentText(_ rect: CGRect) -> String {
        String(format: "%.2f-%.2fx%.2f-%.2f", rect.minX, rect.maxX, rect.minY, rect.maxY)
    }

    private func makeSegmentPreviewImage(from image: CGImage, rects: [CGRect]) -> UIImage? {
        let validRects = rects.filter { !$0.isNull && !$0.isEmpty && $0.width > 0.01 && $0.height > 0.05 }
        guard !validRects.isEmpty else { return nil }

        let tileHeight: CGFloat = 58
        let spacing: CGFloat = 6
        let tileWidths = validRects.map { rect in
            let aspect = max(0.35, min(1.45, rect.width * CGFloat(image.width) / max(rect.height * CGFloat(image.height), 1)))
            return max(30, min(84, tileHeight * aspect))
        }
        let totalWidth = tileWidths.reduce(0, +) + spacing * CGFloat(max(0, tileWidths.count - 1))
        let outputSize = CGSize(width: max(36, totalWidth), height: tileHeight)

        let renderer = UIGraphicsImageRenderer(size: outputSize)
        return renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: outputSize))
            var x: CGFloat = 0
            for (index, rect) in validRects.enumerated() {
                let pixelRect = CGRect(
                    x: rect.minX * CGFloat(image.width),
                    y: rect.minY * CGFloat(image.height),
                    width: rect.width * CGFloat(image.width),
                    height: rect.height * CGFloat(image.height)
                ).integral
                if let segment = image.cropping(to: pixelRect) {
                    UIImage(cgImage: segment).draw(in: CGRect(x: x, y: 0, width: tileWidths[index], height: tileHeight))
                }
                UIColor.white.withAlphaComponent(0.24).setStroke()
                context.cgContext.setLineWidth(1)
                context.cgContext.stroke(CGRect(x: x + 0.5, y: 0.5, width: tileWidths[index] - 1, height: tileHeight - 1))
                x += tileWidths[index] + spacing
            }
        }
    }

    private func makeUIImage(from image: CIImage) -> UIImage? {
        let extent = CGRect(origin: .zero, size: image.extent.size)
        guard let cgImage = selectedRegionPreviewContext.createCGImage(image, from: extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func makeThresholdedUIImage(from image: CIImage) -> UIImage? {
        let extent = CGRect(origin: .zero, size: image.extent.size)
        guard let cgImage = selectedRegionPreviewContext.createCGImage(image, from: extent),
              let thresholded = thresholdedCGImage(from: cgImage, threshold: 150)
        else { return nil }
        return UIImage(cgImage: thresholded)
    }

    private func thresholdedCGImage(from image: CGImage, threshold: UInt8) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let drewImage = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  )
            else {
                return false
            }

            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drewImage else { return nil }

        for index in pixels.indices {
            pixels[index] = pixels[index] >= threshold ? 255 : 0
        }

        let providerData = pixels.withUnsafeBufferPointer { buffer -> CFData? in
            guard let baseAddress = buffer.baseAddress else { return nil }
            return CFDataCreate(kCFAllocatorDefault, baseAddress, pixels.count)
        }
        guard let providerData,
              let provider = CGDataProvider(data: providerData)
        else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func visionOrientation(for deviceOrientation: UIDeviceOrientation) -> CGImagePropertyOrientation {
        switch deviceOrientation {
        case .portrait: return .right
        case .portraitUpsideDown: return .left
        case .landscapeLeft: return .up
        case .landscapeRight: return .down
        default: return .right
        }
    }

    private func applyLatestOCRCandidate(for key: OCRRegionKey) -> Bool {
        guard let value = candidateValue(for: key, from: latestOCRCandidateState) else { return false }
        var updated = state

        switch key {
        case .clock:
            guard isValidTimer(value) else { return false }
            updated.clock = value
        case .period:
            guard let period = Int(value), (1...5).contains(period) else { return false }
            updated.period = period
            updated.periodLabel = normalizedPeriodOption(value)
        case .homeScore:
            guard let score = Int(value), (0...99).contains(score) else { return false }
            updated.homeScore = score
        case .awayScore:
            guard let score = Int(value), (0...99).contains(score) else { return false }
            updated.awayScore = score
        case .homeShots:
            guard let shots = Int(value), (0...99).contains(shots) else { return false }
            updated.homeShots = shots
        case .awayShots:
            guard let shots = Int(value), (0...99).contains(shots) else { return false }
            updated.awayShots = shots
        case .homePenalty1Player:
            guard let player = Int(value), (1...99).contains(player) else { return false }
            updated.homePenalty1Player = player
        case .homePenalty2Player:
            guard let player = Int(value), (1...99).contains(player) else { return false }
            updated.homePenalty2Player = player
        case .awayPenalty1Player:
            guard let player = Int(value), (1...99).contains(player) else { return false }
            updated.awayPenalty1Player = player
        case .awayPenalty2Player:
            guard let player = Int(value), (1...99).contains(player) else { return false }
            updated.awayPenalty2Player = player
        case .homePenalty1Time:
            guard isValidPenaltyTimer(value) else { return false }
            updated.homePenalty1Clock = value
        case .homePenalty2Time:
            guard isValidPenaltyTimer(value) else { return false }
            updated.homePenalty2Clock = value
        case .awayPenalty1Time:
            guard isValidPenaltyTimer(value) else { return false }
            updated.awayPenalty1Clock = value
        case .awayPenalty2Time:
            guard isValidPenaltyTimer(value) else { return false }
            updated.awayPenalty2Clock = value
        }

        reduceMatchState(
            .replace(
                updated,
                context: RinkLensMatchStateContext(
                    origin: .manual,
                    eventPolicy: .all,
                    reason: "Operator accepted current OCR field \(key.rawValue)"
                )
            )
        )
        if key == .clock {
            seedTrustedClockAuthorityFromManualCorrection(
                clock: value,
                reason: "Operator accepted current OCR Clock field"
            )
        }
        ocrSmoothingEngine.reset(key: key)
        mutableAcceptedFieldState[key] = AcceptedOCRValueState(
            acceptedText: value,
            lastConfidence: ocrFieldConfidence[key]?.confidence ?? 1.0,
            recognizerUsed: regionOCRRecognizer[key] ?? .vision,
            lastUpdated: .now
        )
        return true
    }

    private func candidateValue(for key: OCRRegionKey, from state: ScoreboardState) -> String? {
        switch key {
        case .clock:
            return state.clock
        case .period:
            return state.period.map { String($0) }
        case .homeScore:
            return state.homeScore.map { String($0) }
        case .awayScore:
            return state.awayScore.map { String($0) }
        case .homeShots:
            return state.homeShots.map { String($0) }
        case .awayShots:
            return state.awayShots.map { String($0) }
        case .homePenalty1Player:
            return state.homePenalty1Player.map { String($0) }
        case .homePenalty2Player:
            return state.homePenalty2Player.map { String($0) }
        case .awayPenalty1Player:
            return state.awayPenalty1Player.map { String($0) }
        case .awayPenalty2Player:
            return state.awayPenalty2Player.map { String($0) }
        case .homePenalty1Time:
            return state.homePenalty1Clock
        case .homePenalty2Time:
            return state.homePenalty2Clock
        case .awayPenalty1Time:
            return state.awayPenalty1Clock
        case .awayPenalty2Time:
            return state.awayPenalty2Clock
        }
    }

    func isValidTimer(_ value: String) -> Bool {
        OCRValidationEngine.isValidGameClock(value)
    }

    private func isValidPenaltyTimer(_ value: String) -> Bool {
        OCRValidationEngine.isValidPenaltyTime(value)
    }

    private func isOCRTimerDiagnosticsKey(_ key: OCRRegionKey) -> Bool {
        switch key {
        case .clock, .homePenalty1Time, .homePenalty2Time, .awayPenalty1Time, .awayPenalty2Time:
            return true
        default:
            return false
        }
    }

    private func isAcceptedOCRTimerValue(_ value: String, for key: OCRRegionKey) -> Bool {
        switch key {
        case .clock:
            return isValidTimer(value)
        case .homePenalty1Time, .homePenalty2Time, .awayPenalty1Time, .awayPenalty2Time:
            return isValidPenaltyTimer(value)
        default:
            return true
        }
    }

    private func diagnosticDisplayText(for field: ScoreboardOCRProcessor.OCRFieldDebug) -> String? {
        let accepted = field.accepted.trimmingCharacters(in: .whitespacesAndNewlines)
        if !accepted.isEmpty { return accepted }

        // UX15g: timer diagnostics must not publish partial fragments such as "2",
        // ":2" or "43" as if they were the clock. That made the bottom OCR tile
        // show CLOCK 2 while the selected Raw crop clearly showed 2:43. For timers,
        // only a valid accepted M:SS/MM:SS value can refresh the diagnostics tile;
        // otherwise the previous trusted value is retained or the tile remains waiting.
        if isOCRTimerDiagnosticsKey(field.key) {
            return nil
        }

        let fallback = (field.cleaned.isEmpty ? field.raw : field.cleaned)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? nil : fallback
    }


    private func appendUX16d14PersistentLiveEvidence(_ message: String) {
        ux16d14LivePassEvidenceRing.append(message)
        if ux16d14LivePassEvidenceRing.count > ux16d14LivePassEvidenceLimit {
            ux16d14LivePassEvidenceRing.removeFirst(ux16d14LivePassEvidenceRing.count - ux16d14LivePassEvidenceLimit)
        }
    }

    private func ux16d13StateSummary(_ value: ScoreboardState) -> String {
        let clock = value.clock ?? "--"
        let home = value.homeScore.map { String($0) } ?? "--"
        let away = value.awayScore.map { String($0) } ?? "--"
        let period = value.period.map { String($0) } ?? "--"
        return "clock=\(clock) score=\(home)-\(away) period=\(period)"
    }

    private func ux16d13FieldSummary(
        _ fields: [ScoreboardOCRProcessor.OCRFieldDebug]
    ) -> String {
        fields.map { field in
            let accepted = field.accepted.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleaned = field.cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = field.raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = !accepted.isEmpty ? accepted : (!cleaned.isEmpty ? cleaned : (!raw.isEmpty ? raw : "--"))
            let status = accepted.isEmpty ? "rejected" : "accepted"
            return "\(field.key.rawValue)=\(value)/\(status)/\(String(format: "%.2f", field.confidence))/\(field.pipelineDiagnostic)"
        }.joined(separator: ";")
    }

    private func ux16d13TestComparison(
        _ fields: [ScoreboardOCRProcessor.OCRFieldDebug]
    ) -> String {
        let comparisons = fields.compactMap { field -> String? in
            guard let testValue = lastTestOCRAcceptedValue[field.key] else { return nil }
            let liveValue = field.accepted.trimmingCharacters(in: .whitespacesAndNewlines)
            let testFrame = lastTestOCRFrameSequence[field.key].map { String($0) } ?? "unknown"
            let displayLive = liveValue.isEmpty ? "--" : liveValue
            return "\(field.key.rawValue){test=\(testValue)@#\(testFrame),live=\(displayLive),match=\(liveValue == testValue)}"
        }
        return comparisons.isEmpty ? "none" : comparisons.joined(separator: ",")
    }

    // v0.7.7.5: Live OCR publish bridge.
    // Test OCR and continuous Live OCR use different paths. In v0.7.7.4 the crop could
    // be visibly correct, but the processor debug candidate still showed RETAIN and the
    // smoother kept the public scoreboard at No detection. These helpers rescue valid
    // timer/score text from the debug candidate and allow safe first-publication/near-step
    // publication of the clock.
    private func rescueClockCandidateFromDebugIfNeeded(
        fieldDebug: [ScoreboardOCRProcessor.OCRFieldDebug],
        into rawState: inout ScoreboardState,
        previous: ScoreboardState,
        now: CFAbsoluteTime
    ) -> RinkLensClockContinuityCorrection? {
        guard rawState.clock == nil else { return nil }
        guard let debug = fieldDebug.first(where: { $0.key == .clock }) else { return nil }

        let candidates = [debug.accepted, debug.cleaned, debug.raw]
        for candidate in candidates {
            if let clock = firstValidClock(in: candidate) {
                rawState.clock = clock
                return nil
            }
        }

        guard let rawSequence = firstClockLikeSequence(in: debug.raw),
              let anchorSeconds = trustedClockLastObservationSeconds
                ?? trustedClockAnchorSeconds
                ?? previous.clock.flatMap({ seconds(from: $0) }) else { return nil }

        let diagnostics = debug.validation + " " + debug.pipelineDiagnostic
        let alternatives = clockTokenAlternatives(from: diagnostics)
        guard !alternatives.isEmpty else { return nil }

        let elapsedReference = trustedClockLastObservationAt > 0
            ? trustedClockLastObservationAt
            : trustedClockLastAcceptedAt
        let elapsed = elapsedReference > 0 ? max(0.05, now - elapsedReference) : 0.70
        let continuityDirection: GameClockDirection?
        if gameClockDirection != .auto {
            continuityDirection = gameClockDirection
        } else if autoClockDirectionIsLocked {
            continuityDirection = localClockDirection
        } else {
            continuityDirection = nil
        }

        guard let resolution = RinkLensClockContinuityResolver.resolve(
            raw: rawSequence,
            alternativesByToken: alternatives,
            anchorSeconds: anchorSeconds,
            elapsedSeconds: elapsed,
            direction: continuityDirection
        ) else { return nil }

        rawState.clock = resolution.value
        let diagnostic = "UX16d14 continuity-corrected \(resolution.diagnostic) alternatives=\(alternatives)"
        appendSchedulerDiagnostic(diagnostic)
        appendUX16d14PersistentLiveEvidence(diagnostic)
        return RinkLensClockContinuityCorrection(
            value: resolution.value,
            confidence: max(0.58, debug.confidence),
            diagnostic: diagnostic
        )
    }

    private func firstClockLikeSequence(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"([0-9?]{1,2})\s*[:;]\s*([0-9?]{2})"#) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges >= 3,
              let leftRange = Range(match.range(at: 1), in: text),
              let rightRange = Range(match.range(at: 2), in: text) else { return nil }
        return "\(text[leftRange]):\(text[rightRange])"
    }

    private func clockTokenAlternatives(from diagnostic: String) -> [Int: [Int]] {
        // Build 520 keeps both ranked template alternatives and morphology vote
        // candidates. Recovery diagnostics such as votes=8:1[dilate],2:1[neutral]
        // previously returned no usable alternatives, so a complete physical-clock
        // sequence could be withheld even though continuity identified one answer.
        let tokenIndexRegex = try? NSRegularExpression(pattern: #"token=(\d+)"#)
        let alternativesRegex = try? NSRegularExpression(pattern: #"alts=([0-9,]+|none)"#)
        let votesRegex = try? NSRegularExpression(pattern: #"([0-9]):([0-9]+)\["#)
        guard let tokenIndexRegex, let alternativesRegex, let votesRegex else { return [:] }

        var result: [Int: [Int]] = [:]
        for segment in diagnostic.components(separatedBy: " ; ") where segment.contains("token=") {
            let segmentRange = NSRange(segment.startIndex..<segment.endIndex, in: segment)
            guard let tokenMatch = tokenIndexRegex.firstMatch(in: segment, range: segmentRange),
                  let tokenRange = Range(tokenMatch.range(at: 1), in: segment),
                  let tokenIndex = Int(segment[tokenRange]) else { continue }

            var ranked: [Int] = []
            if let alternativesMatch = alternativesRegex.firstMatch(in: segment, range: segmentRange),
               let alternativesRange = Range(alternativesMatch.range(at: 1), in: segment) {
                let alternativesText = String(segment[alternativesRange])
                if alternativesText != "none" {
                    ranked.append(contentsOf: alternativesText.split(separator: ",").compactMap { Int($0) })
                }
            }

            if let votesStart = segment.range(of: "votes=") {
                let votesText = String(segment[votesStart.upperBound...])
                let votesRange = NSRange(votesText.startIndex..<votesText.endIndex, in: votesText)
                let votes: [(digit: Int, count: Int)] = votesRegex.matches(in: votesText, range: votesRange).compactMap { match in
                    guard let digitRange = Range(match.range(at: 1), in: votesText),
                          let countRange = Range(match.range(at: 2), in: votesText),
                          let digit = Int(votesText[digitRange]),
                          let count = Int(votesText[countRange]) else { return nil }
                    return (digit, count)
                }
                ranked.append(contentsOf: votes.sorted { lhs, rhs in
                    lhs.count == rhs.count ? lhs.digit < rhs.digit : lhs.count > rhs.count
                }.map(\.digit))
            }

            var seen: Set<Int> = []
            let unique = ranked.filter { seen.insert($0).inserted }
            if !unique.isEmpty {
                result[tokenIndex] = unique
            }
        }
        return result
    }

    private func rescueScoreCandidatesFromDebugIfNeeded(
        fieldDebug: [ScoreboardOCRProcessor.OCRFieldDebug],
        into rawState: inout ScoreboardState
    ) {
        if rawState.homeScore == nil, let value = firstValidScore(from: fieldDebug, key: .homeScore) {
            rawState.homeScore = value
        }
        if rawState.awayScore == nil, let value = firstValidScore(from: fieldDebug, key: .awayScore) {
            rawState.awayScore = value
        }
    }

    private func firstValidScore(from fieldDebug: [ScoreboardOCRProcessor.OCRFieldDebug], key: OCRRegionKey) -> Int? {
        guard let debug = fieldDebug.first(where: { $0.key == key }) else { return nil }
        for candidate in [debug.accepted, debug.cleaned, debug.raw] {
            let digits = candidate.filter { $0.isNumber }
            guard !digits.isEmpty, digits.count <= 2, let value = Int(digits), (0...30).contains(value) else { continue }
            return value
        }
        return nil
    }

    private func firstValidClock(in text: String) -> String? {
        let patterns = [#"([0-2]?\d)\s*[:;]\s*([0-5]\d)"#, #"([0-5]?\d)\s*[.]\s*(\d)"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, range: range), match.numberOfRanges >= 3,
               let leftRange = Range(match.range(at: 1), in: text),
               let rightRange = Range(match.range(at: 2), in: text) {
                let separator = pattern.contains("[:;]") ? ":" : "."
                let candidate = "\(Int(text[leftRange]) ?? 0)\(separator)\(text[rightRange])"
                if OCRValidationEngine.isValidGameClock(candidate) { return candidate }
            }
        }
        return nil
    }


    // UX16d9 deleted the legacy clock/score force-publish bridges. The
    // physical-board clock authority and publication safety policy are now the
    // only production paths allowed to change these fields.

    private func finishProcessing(
        with result: (state: ScoreboardState, rawText: String?, fieldDebug: [ScoreboardOCRProcessor.OCRFieldDebug])?,
        generation: Int,
        passToken: RinkLensOCRPassToken,
        publicationFlow: RinkLensOCRPublicationFlow,
        requestedKeys: Set<OCRRegionKey>,
        elapsedSeconds: CFTimeInterval
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.finishProcessing(
                    with: result,
                    generation: generation,
                    passToken: passToken,
                    publicationFlow: publicationFlow,
                    requestedKeys: requestedKeys,
                    elapsedSeconds: elapsedSeconds
                )
            }
            return
        }
        guard ocrOrchestrationEngine.isPassCurrent(passToken) else {
            if publicationFlow == .continuousBroadcast {
                ocrControlPlane.cancelInFlight(reason: "orchestration token no longer current")
                activeProductionOCRPlan = nil
            }
            return
        }
        defer {
            if publicationFlow == .continuousBroadcast {
                let completedPlan = activeProductionOCRPlan
                let fields = result?.fieldDebug ?? []
                let completionEvidence = makeOCRPublicationEvidence(from: fields)
                let completedKeys = Set(fields.map(\.key))
                let confirmedBlankKeys = Set(fields.compactMap { field -> OCRRegionKey? in
                    completionEvidence.field(field.key)?.confirmedBlank == true ? field.key : nil
                })
                let usableKeys = Set(fields.compactMap { field -> OCRRegionKey? in
                    let hasAcceptedValue = !field.accepted
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                    let isConfirmedBlank = confirmedBlankKeys.contains(field.key)
                    return (hasAcceptedValue || isConfirmedBlank) ? field.key : nil
                })

                var controlPlaneUsableKeys = usableKeys

                // UX16d20 Build 542: penalty work is usable only at pair level.
                // One accepted player artefact beside a blank timer previously
                // reset the control-plane retry state and kept publication urgency
                // alive forever. A pair is complete when both fresh components are
                // present, when fresh evidence completes adjacent-pass memory, when
                // an already-active penalty receives a fresh timer, or when both
                // cells are confirmed blank.
                if let completedPlan,
                   case .penaltyPair(let playerKey, let timeKey) = completedPlan.unit {
                    let playerUsable = usableKeys.contains(playerKey)
                    let timeUsable = usableKeys.contains(timeKey)
                    let playerConfirmedBlank = confirmedBlankKeys.contains(playerKey)
                    let activePlayer = penaltyLifecycleStore.lockedPlayer(for: playerKey) != nil
                        || PenaltyStateMachine.penaltyPlayerValue(for: playerKey, in: state) != nil
                    let freshComponent = playerUsable || timeUsable || playerConfirmedBlank
                    let completesStoredPair = freshComponent
                        && ocrPublicationSafetyState.hasCompletePendingPenaltyPair(for: playerKey)
                    let pairLevelUsable = (activePlayer && playerConfirmedBlank)
                        || (playerUsable && timeUsable)
                        || (activePlayer && timeUsable)
                        || completesStoredPair

                    if !pairLevelUsable {
                        controlPlaneUsableKeys.subtract([playerKey, timeKey])
                    }

                    // Count incomplete event/confirmation passes even when one
                    // component produced text. After two attempts, terminate the
                    // partial transaction, consume that visual generation and cool
                    // the slot. This enforces the invariant that pending penalty
                    // evidence always completes or expires in bounded steps.
                    if !pairLevelUsable,
                       completedPlan.priority >= .visualChange {
                        let attempts = (livePenaltyVisualUnusableAttempts[playerKey] ?? 0) + 1
                        if attempts >= 2 {
                            finaliseUnverifiedPendingVisualHash(
                                for: playerKey,
                                reason: "Build 542 expired incomplete penalty pair after two event passes"
                            )
                            finaliseUnverifiedPendingVisualHash(
                                for: timeKey,
                                reason: "Build 542 expired incomplete penalty pair after two event passes"
                            )
                            ocrPublicationSafetyState.expirePendingPenaltyEvidence(for: playerKey)
                            liveOCRPriorityVerificationUntil.removeValue(forKey: playerKey)
                            liveOCRPriorityVerificationUntil.removeValue(forKey: timeKey)
                            livePenaltyVisualUnusableAttempts.removeValue(forKey: playerKey)
                            livePenaltyPairFastCheckUntil.removeValue(forKey: playerKey)
                            livePenaltyPairRetryCooldownUntil[playerKey] = CFAbsoluteTimeGetCurrent()
                                + livePenaltyMalformedCooldownSeconds
                            appendSchedulerDiagnostic(
                                "Build 542 terminated incomplete penalty transaction for \(playerKey.rawValue)+\(timeKey.rawValue); hash watch remains armed"
                            )
                        } else {
                            livePenaltyVisualUnusableAttempts[playerKey] = attempts
                        }
                    } else if pairLevelUsable {
                        livePenaltyVisualUnusableAttempts.removeValue(forKey: playerKey)
                    }
                }

                RinkLensOCRReplayGateController.shared.recordRecognition(
                    plan: completedPlan,
                    passID: passToken.id,
                    fields: fields,
                    visibleState: state
                )
                RinkLensOCRReplayGateController.shared.recordControlPlaneCompletion(
                    plan: completedPlan,
                    usableKeys: controlPlaneUsableKeys,
                    completedKeys: completedKeys,
                    confirmedBlankKeys: confirmedBlankKeys,
                    reason: result == nil ? "recogniser returned no result" : "bounded recogniser completed"
                )
                let completionDiagnostic = ocrControlPlane.complete(
                    OCRWorkScheduler.Completion(
                        usableKeys: controlPlaneUsableKeys,
                        completedKeys: completedKeys,
                        confirmedBlankKeys: confirmedBlankKeys,
                        now: CFAbsoluteTimeGetCurrent(),
                        reason: result == nil ? "recogniser returned no result" : "bounded recogniser completed"
                    )
                )
                activeProductionOCRPlan = nil
                MainThreadStallMonitor.shared.traceOCRPhase("UX16d16 \(completionDiagnostic)")
            }
            if ocrOrchestrationEngine.finishPass(token: passToken, reason: "\(publicationFlow.rawValue)-complete") {
                isProcessing = false
            }
        }
        guard generation == ocrProcessingGeneration else { return }
        let broadcastBackgroundOCRAllowed = currentScreen == .broadcast && userWantsOCRRunning
        guard operatingMode == .ocr || broadcastBackgroundOCRAllowed else { return }
        guard let result else {
            ocrDiagnostics.recordPublicationSummary(flow: publicationFlow, summary: "\(publicationFlow.title): recogniser returned no result.")
            return
        }
        if isScreenTransitioning { return }

        // UX16c44: Calibration is a selected-zone diagnostic flow. It can update
        // crop/field diagnostics, but it cannot mutate MatchState, smoothing/event
        // state or the visible Broadcast scorebug.
        if publicationFlow == .calibrationSelectedZone {
            finishCalibrationSelectedZoneProcessing(result)
            return
        }

        // Only the continuous Broadcast flow reaches this production publication
        // boundary. Every accepted value is committed through reduceMatchState.
        let diagnosticsVisible = shouldPublishOCRDiagnostics
        if diagnosticsVisible {
            latestOCRCandidateState = result.state
        }
        let previousState = state
        let clockObservationNow = CFAbsoluteTimeGetCurrent()
        var rawOCRState = result.state
        let clockContinuityCorrection = rescueClockCandidateFromDebugIfNeeded(
            fieldDebug: result.fieldDebug,
            into: &rawOCRState,
            previous: previousState,
            now: clockObservationNow
        )
        rescueScoreCandidatesFromDebugIfNeeded(fieldDebug: result.fieldDebug, into: &rawOCRState)
        rawOCRState = OCRValidationEngine.validateCandidateState(rawOCRState)

        var publicationEvidence = makeOCRPublicationEvidence(from: result.fieldDebug)
        // Build 547: accepted recognition is not a terminal visual transaction.
        // Keep score/player hashes pending through publication confirmation and
        // commit them only after the evidence store reaches a terminal state.
        let hashTriggeredKeys = currentPendingVisualTransactionKeys()
        let resetObservation = observeFullBoardResetRecovery(
            rawState: rawOCRState,
            evidence: publicationEvidence,
            previous: previousState,
            now: clockObservationNow
        )
        switch resetObservation {
        case .committed(let resetReduction):
            recordOCRFieldPublicationDiagnostics(
                flow: .continuousBroadcast,
                fields: result.fieldDebug,
                reduction: resetReduction,
                visibleState: state
            )
            let recoveredDecision = RinkLensTrustedClockDecision(
                clockForPublication: state.clock,
                acceptedObservation: true,
                publicClockChanged: resetReduction.changedFields.contains(.clock),
                runningStateChanged: true,
                isRunning: true,
                confirmedStopped: false,
                reason: "atomic full-board reset recovery"
            )
            publishTrustedClockObservationSideEffects(recoveredDecision, now: clockObservationNow)
            publishStandardOCRDiagnostics(result: result, diagnosticsVisible: diagnosticsVisible)
            return
        case .holding:
            // Keep the public board coherent while Clock and both zero scores are
            // independently confirmed. Static recovery passes are consumed here so
            // their evidence cannot leak into the ordinary score-event policy.
            if rawOCRState.clock == nil {
                recordOCRFieldPublicationDiagnostics(
                    flow: .continuousBroadcast,
                    fields: result.fieldDebug,
                    reduction: nil,
                    visibleState: state
                )
                MainThreadStallMonitor.shared.traceOCRPhase(
                    "Build 529 full-board reset recovery held static evidence requested=[\(schedulerKeyList(requestedKeys))] state={\(fullBoardResetRecoveryDiagnosticText)}"
                )
                publishStandardOCRDiagnostics(result: result, diagnosticsVisible: diagnosticsVisible)
                return
            }
            rawOCRState.homeScore = previousState.homeScore
            rawOCRState.awayScore = previousState.awayScore
            rawOCRState.period = previousState.period
            rawOCRState.periodLabel = previousState.periodLabel
        case .inactive:
            break
        }
        if let correction = clockContinuityCorrection {
            publicationEvidence.fields[.clock] = RinkLensOCRFieldEvidence(
                acceptedText: correction.value,
                rawText: correction.value,
                confidence: correction.confidence,
                segmentationBacked: true,
                deterministicAgreement: false,
                strongSingleSource: true
            )
        }
        if trustedClockEvidenceProcessingGeneration != generation {
            clearBoundedClockEvidence(reason: "OCR processing generation changed")
            trustedClockEvidenceProcessingGeneration = generation
        }
        let clockDecision = evaluateTrustedClockObservation(
            rawOCRClock: rawOCRState.clock,
            evidence: publicationEvidence,
            previous: previousState,
            now: clockObservationNow,
            continuityCorrected: clockContinuityCorrection != nil
        )
        updateLiveClockSchedulingStability(clockDecision)
        // UX16d9: only the sequence-aware clock authority may put a new OCR clock
        // into the publication candidate. Invalid, opposite-direction and stale
        // same-second reads retain the existing public clock.
        rawOCRState.clock = clockDecision.clockForPublication ?? previousState.clock
        discardNonClockValuesBecauseClockMoved(rawClock: rawOCRState.clock, previous: previousState, candidate: &rawOCRState)

        let trustedClockPublicationValue = rawOCRState.clock
        var nonClockSmoothingCandidate = rawOCRState
        // Build 527 consolidates game-Clock smoothing, direction, reset and stop
        // handling inside evaluateTrustedClockObservation. The general OCR
        // smoothing engine remains responsible for non-Clock fields only.
        nonClockSmoothingCandidate.clock = previousState.clock
        let smoothingClockDirection = smoothingClockDirectionForMerge(rawOCRClock: trustedClockPublicationValue)
        var merged = isPostOCRSmoothingEnabled
            ? ocrSmoothingEngine.merge(
                previous: state,
                next: nonClockSmoothingCandidate,
                gameClockDirection: smoothingClockDirection
            )
            : nonClockSmoothingCandidate

        // The trusted Clock authority is the sole public game-Clock writer. This
        // is not the raw decoder candidate: rejected reversals, stale evidence and
        // unconfirmed resets have already been replaced by the previous anchor.
        merged.clock = trustedClockPublicationValue

        // UX16d8: publication safety already owns score confirmation. Surface each
        // accepted raw score observation to that policy instead of making it pass
        // a second independent smoothing cycle first. No value is public here.
        let processedOCRKeys = Set(result.fieldDebug.map(\.key))
        if processedOCRKeys.contains(.homeScore), let value = rawOCRState.homeScore {
            merged.homeScore = value
        }
        if processedOCRKeys.contains(.awayScore), let value = rawOCRState.awayScore {
            merged.awayScore = value
        }

        merged.homeShots = nil
        merged.awayShots = nil

        // UX16d2c removes the pre-publication PenaltyStateMachine mutation from
        // continuous OCR. Raw player/time observations must pass the paired
        // publication policy before either public MatchState or hidden lock state
        // can change. Manual and local-clock penalty operations keep their existing
        // typed paths.

        // UX16d2c: OCR observations are not public state. Apply manual protection,
        // then pass the candidate through the field-specific live publication gate.
        // Only confirmed score steps and paired penalties receive event permission;
        // OCR period observations can never launch intermission/sponsor side effects.
        let protectedPreview = RinkLensMatchStateReducer.reduce(
            current: previousState,
            action: .applyAcceptedOCR(
                merged,
                manualProtection: manualScoreController.state,
                context: RinkLensMatchStateContext(
                    origin: .ocr,
                    diagnosticsOnly: true,
                    reason: "Preview manual protection before OCR publication safety"
                )
            )
        )
        let publicationMemoryBefore = ocrPublicationSafetyState.liveConfirmationDiagnostic
        let priorityVerificationBefore = ocrPublicationSafetyState.pendingPriorityVerificationKeys
        let publicationNow = CFAbsoluteTimeGetCurrent()
        let confirmedStoppedClock = hasConfirmedStoppedClock(now: publicationNow)
        let safetyDecision = RinkLensOCRPublicationSafetyPolicy.evaluateContinuous(
            previous: previousState,
            candidate: protectedPreview.next,
            evidence: publicationEvidence,
            confirmedStoppedClock: confirmedStoppedClock,
            hashTriggeredKeys: hashTriggeredKeys,
            localClockIsRunning: localClockIsRunning,
            memory: &ocrPublicationSafetyState,
            now: publicationNow
        )
        let publicationMemoryAfter = ocrPublicationSafetyState.liveConfirmationDiagnostic
        let priorityVerificationAfter = ocrPublicationSafetyState.pendingPriorityVerificationKeys
        updateLiveOCRPriorityVerification(
            newlyPending: priorityVerificationAfter.subtracting(priorityVerificationBefore),
            resolved: priorityVerificationBefore.subtracting(priorityVerificationAfter),
            now: publicationNow
        )
        merged = safetyDecision.state
        commitPendingVisualHashesAfterPublication(
            result.fieldDebug,
            evidence: publicationEvidence,
            remainingPriorityKeys: priorityVerificationAfter,
            publishedState: merged
        )
        appendSchedulerDiagnostic("UX16d2c publication safety: \(safetyDecision.diagnosticText)")

        let confirmedScoreObservationTeams = Set(result.fieldDebug.compactMap { field -> Team? in
            let accepted = field.accepted.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = Int(accepted) else { return nil }
            switch field.key {
            case .homeScore where merged.homeScore == value:
                return .home
            case .awayScore where merged.awayScore == value:
                return .away
            default:
                return nil
            }
        })
        gameEventDetector.noteConfirmedGoalScoreObservation(
            currentState: merged,
            observedScoreTeams: confirmedScoreObservationTeams,
            observationID: passToken.id
        )

        armScoreBurstWindowAfterAcceptedOCRScoreChangeIfNeeded(
            from: previousState,
            to: merged,
            rawClock: rawOCRState.clock
        )

        let reduction = reduceMatchState(
            .applyAcceptedOCR(
                merged,
                manualProtection: manualScoreController.state,
                context: RinkLensMatchStateContext(
                    origin: .ocr,
                    eventPolicy: safetyDecision.eventPolicy,
                    diagnosticsOnly: false,
                    reason: "Continuous Broadcast OCR confirmed publication: \(safetyDecision.diagnosticText)"
                )
            )
        )
        // Evaluate the fallback only after any accepted correction has reached
        // MatchState and reconciled pending events. This prevents a correction
        // pass from racing a ten-second fallback release.
        flushStableGoalFallbackBroadcastEvents(now: Date())

        recordOCRFieldPublicationDiagnostics(
            flow: .continuousBroadcast,
            fields: result.fieldDebug,
            reduction: reduction,
            visibleState: state
        )

        let requestedText = schedulerKeyList(requestedKeys)
        let processedText = schedulerKeyList(Set(result.fieldDebug.map(\.key)))
        let changedText = reduction.changedFields.map(\.rawValue).sorted().joined(separator: ",")
        MainThreadStallMonitor.shared.traceOCRPhase(
            "UX16d13 live-result pass=\(passToken.diagnosticText) requested=[\(requestedText)] processed=[\(processedText)] elapsed=\(String(format: "%.3f", elapsedSeconds))s fields={\(ux16d13FieldSummary(result.fieldDebug))} testCompare={\(ux16d13TestComparison(result.fieldDebug))} memoryBefore={\(publicationMemoryBefore)} memoryAfter={\(publicationMemoryAfter)} safety={\(safetyDecision.diagnosticText)} reducerChanged=\(reduction.changed) changed=[\(changedText.isEmpty ? "none" : changedText)] before={\(ux16d13StateSummary(previousState))} after={\(ux16d13StateSummary(state))}"
        )
        appendUX16d14PersistentLiveEvidence(
            "result requested=[\(requestedText)] processed=[\(processedText)] rawClock=\(result.fieldDebug.first(where: { $0.key == .clock })?.raw ?? "--") candidate=\(rawOCRState.clock ?? "--") decision=\(clockDecision.reason) anchor=\(trustedClockAnchorSeconds.map(formatClock) ?? "none") changed=[\(changedText.isEmpty ? "none" : changedText)] visible={\(ux16d13StateSummary(state))}"
        )

        if reduction.changed {
            let changedFieldText = reduction.changedFields.map(\.rawValue).sorted().joined(separator: ",")
            let committedClock = state.clock ?? "--"
            let committedPeriod = state.period.map { String($0) } ?? "--"
            let committedHome = state.homeScore.map { String($0) } ?? "--"
            let committedAway = state.awayScore.map { String($0) } ?? "--"
            MainThreadStallMonitor.shared.traceOCRPhase(
                "UX16c44 continuous reducer committed fields=\(changedFieldText) clock=\(committedClock) period=\(committedPeriod) score=\(committedHome)-\(committedAway)"
            )
        }
        publishTrustedClockObservationSideEffects(clockDecision, now: clockObservationNow)
        publishStandardOCRDiagnostics(result: result, diagnosticsVisible: diagnosticsVisible)
    }

    /// Calibration selected-zone OCR is intentionally unable to alter MatchState.
    /// It publishes recogniser evidence only, using the current scorebug state as
    /// the visible-value comparison in diagnostics.
    private func finishCalibrationSelectedZoneProcessing(
        _ result: (state: ScoreboardState, rawText: String?, fieldDebug: [ScoreboardOCRProcessor.OCRFieldDebug])
    ) {
        let validated = OCRValidationEngine.validateCandidateState(result.state)
        latestOCRCandidateState = validated
        updateRegionPreviewText(from: result.rawText)
        updateRegionRecognizers(from: result.fieldDebug)
        ocrFieldConfidence = ocrSmoothingEngine.updateConfidence(from: result.fieldDebug)
        ocrTrustSummary = ocrSmoothingEngine.trustSummary()

        for field in result.fieldDebug {
            let diagnosticText = diagnosticDisplayText(for: field)
            mutableAcceptedFieldState[field.key] = AcceptedOCRValueState(
                acceptedText: diagnosticText,
                lastConfidence: field.confidence,
                recognizerUsed: field.recognizer,
                lastUpdated: .now
            )
        }

        recordOCRFieldPublicationDiagnostics(
            flow: .calibrationSelectedZone,
            fields: result.fieldDebug,
            reduction: nil,
            visibleState: state
        )
        MainThreadStallMonitor.shared.traceOCRPhase(
            "UX16c44 calibration selected-zone diagnostics-only key=\(selectedRegionKey.rawValue); MatchState revision retained=\(matchStateRevision)"
        )
    }

    private func publishStandardOCRDiagnostics(
        result: (state: ScoreboardState, rawText: String?, fieldDebug: [ScoreboardOCRProcessor.OCRFieldDebug]),
        diagnosticsVisible: Bool
    ) {
        guard diagnosticsVisible else { return }
        updateRegionPreviewText(from: result.rawText)
        updateRegionRecognizers(from: result.fieldDebug)
        if isDebugVisible, !freezeDebugSnapshot, lastRawOCRText != result.rawText {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastRawDebugPublishAt >= rawDebugPublishInterval {
                lastRawDebugPublishAt = now
                let enrichedRaw = enrichDebugTextWithStability(result.rawText)
                lastRawOCRText = enrichedRaw
                if let raw = enrichedRaw, !raw.isEmpty {
                    let stamped = "[\(Date().formatted(date: .omitted, time: .standard))]\n\(raw)"
                    debugHistory.append(stamped)
                    if debugHistory.count > 40 {
                        debugHistory.removeFirst(debugHistory.count - 40)
                    }
                }
            }
        }
        ocrFieldConfidence = ocrSmoothingEngine.updateConfidence(from: result.fieldDebug)
        ocrTrustSummary = ocrSmoothingEngine.trustSummary()

        for field in result.fieldDebug {
            let diagnosticText = diagnosticDisplayText(for: field)
            if diagnosticText != nil || !isOCRTimerDiagnosticsKey(field.key) {
                mutableAcceptedFieldState[field.key] = AcceptedOCRValueState(
                    acceptedText: diagnosticText,
                    lastConfidence: field.confidence,
                    recognizerUsed: field.recognizer,
                    lastUpdated: .now
                )
            }
        }
    }

    private func makeOCRPublicationEvidence(
        from fields: [ScoreboardOCRProcessor.OCRFieldDebug]
    ) -> RinkLensOCRPublicationEvidence {
        let values = fields.map { field in
            let validation = field.validation.lowercased()
            let segmentationBacked = field.recognizer == .segmented
                || field.recognizer == .templateDigits
                || validation.contains("segment")
                || validation.contains("template")
            let deterministicAgreement = validation.contains("agreed=true")
                || validation.contains("source=colour+contrast")
                || validation.contains("sources agree")
            let acceptedText = field.accepted.trimmingCharacters(in: .whitespacesAndNewlines)
            let explicitStrongSingleSource = validation.contains("shortcircuit=strong-colour")
                || validation.contains("shortcircuit=score-reacquisition-strong")
            let sourceBacked = validation.contains("source=colour")
                || validation.contains("source=contrast")
            let implicitStrongSingleSource = !acceptedText.isEmpty
                && segmentationBacked
                && sourceBacked
                && !deterministicAgreement
                && field.confidence >= (field.key == .clock ? 0.62 : 0.68)
            let strongSingleSource = explicitStrongSingleSource || implicitStrongSingleSource
            let rawText = field.raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let blankDiagnostic = (field.validation + " " + field.pipelineDiagnostic).lowercased()
            let colourBlank = blankDiagnostic.contains("colour raw=<blank>")
                && blankDiagnostic.contains("colour raw=<blank> conf=0.00 no character-height components")
            let contrastBlank = blankDiagnostic.contains("contrast raw=<blank>")
                && blankDiagnostic.contains("contrast raw=<blank> conf=0.00 no character-height components")
            let confirmedBlank = acceptedText.isEmpty
                && rawText.isEmpty
                && field.confidence <= 0.01
                && !blankDiagnostic.contains("deadline")
                && !blankDiagnostic.contains("camera")
                && colourBlank
                && contrastBlank
            return (
                field.key,
                RinkLensOCRFieldEvidence(
                    acceptedText: field.accepted,
                    rawText: field.raw,
                    confidence: field.confidence,
                    segmentationBacked: segmentationBacked,
                    deterministicAgreement: deterministicAgreement,
                    strongSingleSource: strongSingleSource,
                    confirmedBlank: confirmedBlank
                )
            )
        }
        return RinkLensOCRPublicationEvidence(fields: Dictionary(uniqueKeysWithValues: values))
    }

    private func recordOCRFieldPublicationDiagnostics(
        flow: RinkLensOCRPublicationFlow,
        fields: [ScoreboardOCRProcessor.OCRFieldDebug],
        reduction: RinkLensMatchStateReduction?,
        visibleState: ScoreboardState
    ) {
        for field in fields {
            let accepted = !field.accepted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let protected = flow == .continuousBroadcast && isOCRFieldManuallyProtected(field.key)
            let changedFields = matchStateFields(for: field.key)
            let reducerChanged = reduction.map { !$0.changedFields.isDisjoint(with: changedFields) } ?? false

            let reducerOutcome: String
            if flow == .calibrationSelectedZone {
                reducerOutcome = "Reducer bypassed — Calibration is diagnostics-only"
            } else if flow == .testOCR {
                reducerOutcome = "Verify Zone is diagnostics-only; no Broadcast commit occurred"
            } else if !accepted {
                reducerOutcome = "No commit — recogniser rejected candidate"
            } else if protected {
                reducerOutcome = "Manual protection retained visible value"
            } else if reducerChanged {
                reducerOutcome = "Committed through unified MatchState reducer"
            } else {
                reducerOutcome = "Reducer retained existing visible value"
            }

            let acceptanceReason = accepted
                ? "Accepted: \(field.validation)"
                : "Rejected: \(field.validation.isEmpty ? "no accepted candidate" : field.validation)"

            let visibleValue = visibleScorebugValue(for: field.key, in: visibleState)
            ocrDiagnostics.recordFieldPublication(
                RinkLensOCRFieldPublicationDiagnostic(
                    key: field.key,
                    flow: flow,
                    rawCandidate: field.raw,
                    cleanedCandidate: field.cleaned,
                    confidence: field.confidence,
                    acceptanceReason: acceptanceReason,
                    reducerOutcome: reducerOutcome,
                    visibleScorebugValue: visibleValue,
                    updatedAt: .now
                )
            )
            RinkLensPhysicalAcceptanceMonitor.shared.recordFieldPublication(
                field: field.key.rawValue,
                recognisedValue: accepted ? field.accepted : nil,
                visibleValue: visibleValue,
                flow: flow.rawValue,
                reducerOutcome: reducerOutcome,
                route: currentScreen.rawValue,
                continuousOCRRequested: usesOCRRecognition && userWantsOCRRunning && !isOCRPaused
            )
        }
    }

    private func matchStateFields(for key: OCRRegionKey) -> Set<RinkLensMatchStateField> {
        switch key {
        case .clock: return [.clock]
        case .homeScore: return [.homeScore]
        case .awayScore: return [.awayScore]
        case .period: return [.period, .periodLabel]
        case .homePenalty1Player: return [.homePenalty1Player]
        case .homePenalty1Time: return [.homePenalty1Clock]
        case .homePenalty2Player: return [.homePenalty2Player]
        case .homePenalty2Time: return [.homePenalty2Clock]
        case .awayPenalty1Player: return [.awayPenalty1Player]
        case .awayPenalty1Time: return [.awayPenalty1Clock]
        case .awayPenalty2Player: return [.awayPenalty2Player]
        case .awayPenalty2Time: return [.awayPenalty2Clock]
        case .homeShots: return [.homeShots]
        case .awayShots: return [.awayShots]
        }
    }

    private func isOCRFieldManuallyProtected(_ key: OCRRegionKey) -> Bool {
        let protection = manualScoreController.state
        if protection.globalManualModeEnabled {
            switch key {
            case .clock, .homeScore, .awayScore, .period:
                return true
            default:
                break
            }
        }
        switch key {
        case .clock: return protection.clockOverrideActive
        case .homeScore: return protection.homeScoreOverrideActive
        case .awayScore: return protection.awayScoreOverrideActive
        case .period: return protection.periodOverrideActive
        default: return false
        }
    }

    private func visibleScorebugValue(for key: OCRRegionKey, in visibleState: ScoreboardState) -> String {
        switch key {
        case .clock: return visibleState.clock ?? "--"
        case .homeScore: return visibleState.homeScore.map { String($0) } ?? "--"
        case .awayScore: return visibleState.awayScore.map { String($0) } ?? "--"
        case .period: return visibleState.periodLabel ?? visibleState.period.map { String($0) } ?? "--"
        case .homePenalty1Player: return visibleState.homePenalty1Player.map { String($0) } ?? "--"
        case .homePenalty1Time: return visibleState.homePenalty1Clock ?? "--:--"
        case .homePenalty2Player: return visibleState.homePenalty2Player.map { String($0) } ?? "--"
        case .homePenalty2Time: return visibleState.homePenalty2Clock ?? "--:--"
        case .awayPenalty1Player: return visibleState.awayPenalty1Player.map { String($0) } ?? "--"
        case .awayPenalty1Time: return visibleState.awayPenalty1Clock ?? "--:--"
        case .awayPenalty2Player: return visibleState.awayPenalty2Player.map { String($0) } ?? "--"
        case .awayPenalty2Time: return visibleState.awayPenalty2Clock ?? "--:--"
        case .homeShots: return visibleState.homeShots.map { String($0) } ?? "--"
        case .awayShots: return visibleState.awayShots.map { String($0) } ?? "--"
        }
    }

    private func armScoreBurstWindowAfterAcceptedOCRScoreChangeIfNeeded(
        from previous: ScoreboardState,
        to next: ScoreboardState,
        rawClock: String?
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        guard gameEventDetector.shouldArmScoreBurstWindow(
            previous: previous,
            next: next,
            rawClockShowsMovement: rawClockShowsMovement(rawClock),
            hasConfirmedStoppedClock: hasConfirmedStoppedClock(now: now),
            localClockIsRunning: localClockIsRunning
        ) else { return }

        scoreFastCheckUntil = max(scoreFastCheckUntil, now + 3.0)
        appendSchedulerDiagnostic("score burst -> accepted OCR score change during stopped-clock window; fast score OCR armed for 3s")
    }

    private func reconcilePendingBroadcastEventsWithAcceptedState(
        _ acceptedState: ScoreboardState,
        reason: String
    ) {
        let cancelled = gameEventDetector.reconcilePendingStoppedClockBroadcastEvents(
            currentState: acceptedState
        )
        guard !cancelled.isEmpty else { return }

        for event in cancelled {
            RinkLensOCREvidenceJournal.shared.recordEventAudit(
                stage: "event_normalization_cancelled",
                eventKind: event.type.title,
                source: event.source.rawValue,
                detail: "Accepted board state no longer matched pending popup during five-second normalisation; reason=\(reason)"
            )
        }
        statusMessage = cancelled.count == 1
            ? "Pending \(cancelled[0].type.title.lowercased()) popup cancelled after board correction."
            : "Pending event popups cancelled after board correction."
    }

    private func scoringTeam(from previous: ScoreboardState, to next: ScoreboardState) -> Team? {
        let homeDelta = (next.homeScore ?? 0) - (previous.homeScore ?? 0)
        let awayDelta = (next.awayScore ?? 0) - (previous.awayScore ?? 0)
        if homeDelta == 1, awayDelta == 0 { return .home }
        if awayDelta == 1, homeDelta == 0 { return .away }
        return nil
    }

    private func rememberRecentPenaltyClear(
        previousClocks: [PenaltyClock],
        nextClocks: [PenaltyClock],
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        guard nextClocks.count < previousClocks.count else { return }
        let scoreVerificationPending = !scorePendingVisualHash.isEmpty
            || liveScoreEventWatchUntil > now
            || liveOCRPriorityVerificationUntil.keys.contains(.homeScore)
            || liveOCRPriorityVerificationUntil.keys.contains(.awayScore)
        guard scoreVerificationPending else {
            appendSchedulerDiagnostic("Build 532 penalty clear had no simultaneous score evidence; recent goal correlation not armed")
            return
        }
        let nextIDs = Set(nextClocks.map { $0.id })
        let removed = previousClocks.filter { !nextIDs.contains($0.id) }
        guard removed.contains(where: { ($0.remainingSeconds ?? 0) > 15 }) else { return }
        let strength = StrengthStateCalculator.strengthState(from: previousClocks)
        guard strength.isPowerPlay else { return }
        recentClearedStrengthState = strength
        recentClearedPenaltyClocks = previousClocks
        recentPenaltyClearObservedAt = now
        appendSchedulerDiagnostic(
            "Build 532 retained pre-clear strength context \(strength.description) for delayed goal correlation"
        )
    }

    private func goalStrengthContext(
        from previous: ScoreboardState,
        to next: ScoreboardState,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> (strength: StrengthState, clocks: [PenaltyClock], usedRecentClear: Bool) {
        let currentClocks = StrengthStateCalculator.activePenaltyClocks(from: next)
        let currentStrength = StrengthStateCalculator.strengthState(from: currentClocks)
        if recentPenaltyClearObservedAt > 0,
           now - recentPenaltyClearObservedAt > recentPenaltyClearGoalCorrelationWindow {
            recentClearedStrengthState = nil
            recentClearedPenaltyClocks.removeAll()
            recentPenaltyClearObservedAt = 0
        }
        guard let scoringTeam = scoringTeam(from: previous, to: next),
              let recentStrength = recentClearedStrengthState,
              recentPenaltyClearObservedAt > 0,
              recentStrength.advantagedTeam == scoringTeam else {
            return (currentStrength, currentClocks, false)
        }
        return (recentStrength, recentClearedPenaltyClocks, true)
    }

    private func penaltyRegionPair(team: Team, slot: Int) -> (player: OCRRegionKey, time: OCRRegionKey)? {
        switch (team, slot) {
        case (.home, 1): return (.homePenalty1Player, .homePenalty1Time)
        case (.home, 2): return (.homePenalty2Player, .homePenalty2Time)
        case (.away, 1): return (.awayPenalty1Player, .awayPenalty1Time)
        case (.away, 2): return (.awayPenalty2Player, .awayPenalty2Time)
        default: return nil
        }
    }

    private func armPenaltyClearVerificationAfterPowerPlayGoal(
        _ event: BroadcastEvent,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        guard event.type == .powerPlayGoal,
              let scoringTeam = event.team else { return }
        let penalisedClocks = event.penaltyClockSnapshot.filter {
            $0.isActive && $0.team != scoringTeam
        }
        guard !penalisedClocks.isEmpty else { return }

        for clock in penalisedClocks {
            guard let pair = penaltyRegionPair(team: clock.team, slot: clock.slot) else { continue }
            livePenaltyPairRetryCooldownUntil.removeValue(forKey: pair.player)
            livePenaltyPairFastCheckUntil[pair.player] = now + 6.0
            liveOCRPriorityVerificationUntil[pair.player] = now + 6.0
            liveOCRPriorityVerificationUntil[pair.time] = now + 6.0
        }
        appendSchedulerDiagnostic(
            "Build 532 power-play goal armed immediate paired blank-clear verification for \(penalisedClocks.map(\.id).joined(separator: ","))"
        )
    }

    func handleAcceptedScoreChange(
        from previous: ScoreboardState,
        to next: ScoreboardState,
        source: BroadcastEventSource,
        operatorConfirmed: Bool
    ) {
        let transitionDetail = "score \(previous.homeScore.map { String($0) } ?? "--")-\(previous.awayScore.map { String($0) } ?? "--") -> \(next.homeScore.map { String($0) } ?? "--")-\(next.awayScore.map { String($0) } ?? "--") operatorConfirmed=\(operatorConfirmed)"
        RinkLensOCREvidenceJournal.shared.recordEventAudit(
            stage: "matchstate_transition",
            eventKind: "goal",
            source: source.rawValue,
            detail: transitionDetail
        )
        let clockText: String? = source == .manual ? nil : gameEventDetector.eventClock(
            acceptedClock: next.clock,
            source: source,
            operatorConfirmed: operatorConfirmed,
            localClockIsRunning: localClockIsRunning
        )
        let strengthContext = goalStrengthContext(from: previous, to: next)
        guard let event = gameEventDetector.makeGoalEvent(
            from: previous,
            to: next,
            source: source,
            operatorConfirmed: operatorConfirmed,
            eventClock: clockText,
            currentStrengthState: strengthContext.strength,
            activePenaltyClocks: strengthContext.clocks
        ) else {
            RinkLensOCREvidenceJournal.shared.recordEventAudit(
                stage: "event_suppressed",
                eventKind: "goal",
                source: source.rawValue,
                detail: "No goal event created for \(transitionDetail); clock=\(clockText ?? "none")"
            )
            return
        }
        if strengthContext.usedRecentClear {
            RinkLensOCREvidenceJournal.shared.recordEventAudit(
                stage: "goal_strength_correlated",
                eventKind: event.type.title,
                source: source.rawValue,
                detail: "Build 532 used recent pre-clear strength context for delayed score OCR"
            )
            recentClearedStrengthState = nil
            recentClearedPenaltyClocks.removeAll()
            recentPenaltyClearObservedAt = 0
        }
        RinkLensOCREvidenceJournal.shared.recordEventAudit(
            stage: "event_created",
            eventKind: event.type.title,
            source: source.rawValue,
            detail: transitionDetail
        )
        armPenaltyClearVerificationAfterPowerPlayGoal(event)
        enqueueBanner(event)
    }

    func handleAcceptedPenaltyChange(
        from previous: ScoreboardState,
        to next: ScoreboardState,
        source: BroadcastEventSource,
        operatorConfirmed: Bool
    ) {
        let previousPenaltyClocks = StrengthStateCalculator.activePenaltyClocks(from: previous)
        let nextPenaltyClocks = StrengthStateCalculator.activePenaltyClocks(from: next)
        RinkLensOCREvidenceJournal.shared.recordEventAudit(
            stage: "matchstate_transition",
            eventKind: "penalty",
            source: source.rawValue,
            detail: "penalty fields changed operatorConfirmed=\(operatorConfirmed) before=\(StrengthStateCalculator.signature(for: previousPenaltyClocks)) after=\(StrengthStateCalculator.signature(for: nextPenaltyClocks))"
        )
        let update = gameEventDetector.makePenaltyBroadcastEventUpdate(
            from: previous,
            to: next,
            source: source,
            operatorConfirmed: operatorConfirmed,
            eventClock: source == .manual ? nil : gameEventDetector.eventClock(
                acceptedClock: next.clock,
                source: source,
                operatorConfirmed: operatorConfirmed,
                localClockIsRunning: localClockIsRunning
            )
        )

        penaltyLifecycleStore.recordAcceptedTransition(
            previous: previousPenaltyClocks,
            next: nextPenaltyClocks,
            source: source.rawValue,
            reason: "accepted penalty change"
        )
        guard update.signatureChanged else {
            RinkLensOCREvidenceJournal.shared.recordEventAudit(
                stage: "event_suppressed",
                eventKind: "penalty",
                source: source.rawValue,
                detail: "Penalty signature unchanged"
            )
            return
        }
        lastPenaltySignature = update.nextSignature
        guard let event = update.event else {
            RinkLensOCREvidenceJournal.shared.recordEventAudit(
                stage: "event_suppressed",
                eventKind: "penalty",
                source: source.rawValue,
                detail: "Penalty state changed but detector returned no popup event; signature=\(update.nextSignature)"
            )
            return
        }
        RinkLensOCREvidenceJournal.shared.recordEventAudit(
            stage: "event_created",
            eventKind: event.type.title,
            source: source.rawValue,
            detail: "Penalty event created signature=\(update.nextSignature)"
        )
        enqueueBanner(event)
    }

    func updatePenaltyState(from state: ScoreboardState) {
        let clocks = StrengthStateCalculator.activePenaltyClocks(from: state)
        lastPenaltySignature = StrengthStateCalculator.signature(for: clocks)
    }

    // MARK: - STATE1 Broadcast Phase State Machine / ADS Intermission Sponsor Reel

    private func broadcastPhaseTrigger(for source: BroadcastEventSource) -> BroadcastPhaseTransitionTrigger {
        switch source {
        case .manual: return .manual
        case .ocr: return .ocr
        }
    }

    private func transitionBroadcastPhase(
        to nextState: BroadcastPhaseState,
        trigger: BroadcastPhaseTransitionTrigger,
        reason: String
    ) {
        guard let transition = broadcastPhaseStateMachine.transition(to: nextState, trigger: trigger, reason: reason) else { return }
        let nextState = broadcastPhaseStateMachine.state
        matchEventJournal.setPhase(
            nextState.phase,
            state: nextState,
            transition: transition,
            source: "HockeyScoreboardViewModel",
            reason: reason
        )
        MainThreadStallMonitor.shared.traceIntermissionTrigger("[broadcast-phase] \(transition.diagnosticSummary)")
    }

    func handleManualPeriodTransition(from previousPeriod: Int?, to nextPeriod: Int) {
        handleAcceptedPeriodTransition(
            fromPeriod: previousPeriod,
            toPeriod: nextPeriod,
            source: .manual,
            operatorConfirmed: true
        )
    }

    private func handleAcceptedPeriodTransition(
        from previous: ScoreboardState,
        to next: ScoreboardState,
        source: BroadcastEventSource,
        operatorConfirmed: Bool
    ) {
        handleAcceptedPeriodTransition(
            fromPeriod: previous.period,
            toPeriod: next.period,
            source: source,
            operatorConfirmed: operatorConfirmed
        )
    }

    private func handleAcceptedPeriodTransition(
        fromPeriod previousPeriod: Int?,
        toPeriod nextPeriod: Int?,
        source: BroadcastEventSource,
        operatorConfirmed: Bool
    ) {
        guard let previousPeriod, let nextPeriod else { return }
        guard nextPeriod > previousPeriod else { return }
        if source == .ocr && !operatorConfirmed {
            lastIntermissionDiagnostic = "UX16d2c OCR period observation fenced: P\(previousPeriod) -> P\(nextPeriod) requires operator confirmation"
            MainThreadStallMonitor.shared.traceIntermissionTrigger(RinkLensBuildInfo.traceContext(lastIntermissionDiagnostic))
            return
        }

        if previousPeriod == 1 || previousPeriod == 2 {
            enterSponsorIntermission(completedPeriod: previousPeriod, nextPeriod: nextPeriod, source: source, operatorConfirmed: operatorConfirmed)
        } else {
            transitionBroadcastPhase(
                to: .final(period: previousPeriod, trigger: broadcastPhaseTrigger(for: source), eventSource: source, reason: "Period advanced P\(previousPeriod) -> P\(nextPeriod); final phase"),
                trigger: broadcastPhaseTrigger(for: source),
                reason: "Period advanced beyond regulation"
            )
        }
    }

    func enterSponsorIntermission(
        completedPeriod: Int,
        nextPeriod: Int? = nil,
        source: BroadcastEventSource,
        operatorConfirmed: Bool
    ) {
        let resolvedNextPeriod = nextPeriod ?? min(3, completedPeriod + 1)
        guard resolvedNextPeriod <= 3 else { return }

        let trigger = broadcastPhaseTrigger(for: source)
        guard SponsorCatalogueStore.shared.shouldShowIntermission(afterCompletedPeriod: completedPeriod) else {
            lastIntermissionDiagnostic = "Intermission skipped after P\(completedPeriod): disabled for this period"
            transitionBroadcastPhase(
                to: .inPlay(period: resolvedNextPeriod, trigger: trigger, eventSource: source, reason: lastIntermissionDiagnostic),
                trigger: trigger,
                reason: lastIntermissionDiagnostic
            )
            MainThreadStallMonitor.shared.traceIntermissionTrigger(RinkLensBuildInfo.traceContext(lastIntermissionDiagnostic))
            return
        }

        if let active = activeIntermissionReel, active.completedPeriod == completedPeriod {
            lastIntermissionDiagnostic = "Intermission already active after P\(completedPeriod)"
            MainThreadStallMonitor.shared.traceIntermissionTrigger(RinkLensBuildInfo.traceContext(lastIntermissionDiagnostic))
            return
        }

        let slides = SponsorCatalogueStore.shared.resolvedIntermissionSlides()
        let intermissionReel = BroadcastIntermissionReelState(
            completedPeriod: completedPeriod,
            nextPeriod: resolvedNextPeriod,
            triggeredBy: source,
            sponsorSlides: slides
        )
        lastIntermissionDiagnostic = "Intermission active after P\(completedPeriod); source=\(source.rawValue); slides=\(slides.count); OCR countdown enabled"
        enqueueUnifiedOverlay(
            .intermission(intermissionReel, reason: lastIntermissionDiagnostic),
            preemptLowerPriority: true,
            traceReason: "enter intermission"
        )
        transitionBroadcastPhase(
            to: .intermission(completedPeriod: completedPeriod, nextPeriod: resolvedNextPeriod, trigger: trigger, eventSource: source, reason: lastIntermissionDiagnostic),
            trigger: trigger,
            reason: lastIntermissionDiagnostic
        )

        // Keep OCR sample delivery alive during intermission so the clock zone can
        // continue to update the countdown. This does not change camera ownership,
        // route gates, recording, renderer or clip-buffer behaviour.
        userWantsOCRRunning = true
        isOCRPaused = false
        periodFastCheckUntil = max(periodFastCheckUntil, CFAbsoluteTimeGetCurrent() + 20)
        updatePixelHashingStatus(false, detail: "OVERLAY1 intermission phase: OCR clock countdown active; game clock direction unchanged.", force: true)
        updateFrameDeliveryPolicy(force: true)

        let periodEndEvent = BroadcastEvent(
            type: .periodEnd,
            team: nil,
            period: completedPeriod,
            gameClock: state.clock,
            homeScoreAfter: state.homeScore ?? overrideHomeScore,
            awayScoreAfter: state.awayScore ?? overrideAwayScore,
            strengthState: currentStrengthState,
            source: source,
            operatorConfirmed: operatorConfirmed,
            penaltyClockSnapshot: activePenaltyClocks,
            sponsor: slides.first
        )
        _ = periodEndEvent
        MainThreadStallMonitor.shared.traceIntermissionTrigger(RinkLensBuildInfo.traceContext(lastIntermissionDiagnostic))
    }

    func dismissSponsorIntermission(reason: String) {
        guard let active = activeIntermissionReel else { return }
        let dismissed = overlayEventStateMachine.dismissActive(source: "HockeyScoreboardViewModel", reason: "dismiss intermission: \(reason)")
        publishUnifiedOverlayQueueState(reason: "dismiss intermission: \(reason)")
        lastIntermissionDiagnostic = "Intermission dismissed: \(reason)"
        transitionBroadcastPhase(
            to: .inPlay(period: active.nextPeriod, trigger: .operatorDismiss, eventSource: active.triggeredBy, reason: lastIntermissionDiagnostic),
            trigger: .operatorDismiss,
            reason: lastIntermissionDiagnostic
        )
        MainThreadStallMonitor.shared.traceIntermissionTrigger(RinkLensBuildInfo.traceContext(lastIntermissionDiagnostic))
        MainThreadStallMonitor.shared.traceSponsorOverlay("[overlay-queue] dismissed intermission item=\(dismissed?.diagnosticSummary ?? "none")")
        showNextOverlayIfNeeded()
        updateFrameDeliveryPolicy(force: true)
    }

    var intermissionCountdownText: String {
        state.clock ?? overlayState.clock ?? "--:--"
    }

    private func recordTimelineEventIfNeeded(
        _ event: BroadcastEvent,
        lifecycleState: String,
        popupState: String
    ) {
        var recorded = event
        recorded.timelineLifecycleState = lifecycleState
        recorded.popupLifecycleState = popupState
        matchEventJournal.upsertTimeline(
            recorded,
            source: "HockeyScoreboardViewModel",
            reason: "lifecycle=\(lifecycleState) popup=\(popupState)"
        )
    }

    private func removeTimelineEvent(id: UUID, reason: String) {
        matchEventJournal.removeTimeline(id: id, source: "HockeyScoreboardViewModel", reason: reason)
        RinkLensOCREvidenceJournal.shared.recordEventAudit(
            stage: "image_relay_timeline_event_removed",
            eventKind: "timeline",
            source: BroadcastEventSource.ocr.rawValue,
            detail: "id=\(id.uuidString) reason=\(reason)"
        )
    }

    private func enqueueBanner(
        _ event: BroadcastEvent,
        releaseReason: String? = nil
    ) {
        RinkLensOCRReplayGateController.shared.recordEvent(
            stage: "event_received",
            event: event,
            detail: "accepted MatchState event reached popup lifecycle"
        )
        var displayEvent = event
        if RinkLensRiskFeaturePolicy.isEnabled(.popupPolicySnapshotV2), displayEvent.popupPolicySnapshot == nil {
            displayEvent.popupPolicySnapshot = BroadcastEventPopupSettings.shared.snapshot
        }
        gameEventLifecycleStore.transition(displayEvent, to: .validated, source: "HockeyScoreboardViewModel.enqueueBanner", reason: "Accepted MatchState event reached popup lifecycle")
        if displayEvent.sponsor == nil {
            let unresolvedHomePenaltyIdentity = displayEvent.team == .home
                && (displayEvent.type == .penalty
                    || displayEvent.type == .penalties
                    || displayEvent.type == .powerPlayStart || displayEvent.type == .penaltyEnd || displayEvent.type == .timeoutStart || displayEvent.type == .timeoutEnd)
                && displayEvent.recognisedPenaltyPlayerNumber == nil
            if !unresolvedHomePenaltyIdentity {
                displayEvent.sponsor = SponsorCatalogueStore.shared.resolvedPenaltySponsor(for: displayEvent)
            }
        }
        MainThreadStallMonitor.shared.traceSponsorOverlay("event=\(displayEvent.type.title) team=\(displayEvent.team?.displayName ?? "none") clock=\(displayEvent.gameClock ?? "none") sponsor=\(displayEvent.sponsor?.displayTitle ?? "none") source=\(displayEvent.source.rawValue)")

        if releaseReason == nil,
           gameEventDetector.shouldHoldBroadcastEventUntilClockRestart(
            displayEvent,
            operatingModeIsOCR: operatingMode == .ocr,
            localClockIsRunning: localClockIsRunning
        ) {
            recordTimelineEventIfNeeded(
                displayEvent,
                lifecycleState: "confirmed",
                popupState: "held-for-restart"
            )
            gameEventLifecycleStore.transition(displayEvent, to: .heldForRestart, source: "HockeyScoreboardViewModel.enqueueBanner", reason: "Preferred physical-clock proof pending")
            gameEventDetector.upsertPendingStoppedClockBroadcastEvent(displayEvent)
            RinkLensOCRReplayGateController.shared.recordEvent(
                stage: "event_held",
                event: displayEvent,
                detail: "preferred physical-clock proof or bounded goal fallback pending"
            )
            BroadcastRecordingManager.shared.noteBroadcastEventConfirmed(displayEvent)
            RinkLensOCREvidenceJournal.shared.recordEventAudit(
                stage: "event_held",
                eventKind: displayEvent.type.title,
                source: displayEvent.source.rawValue,
                detail: "Held for preferred physical-clock proof; confirmed goals have a ten-second score-stability fallback"
            )
            statusMessage = "Event held while the board normalises; goal popup follows Clock proof or the bounded score-stability fallback."
            return
        }
        BroadcastRecordingManager.shared.noteBroadcastEventConfirmed(displayEvent)
        let eligiblePopupState = releaseReason == nil
            ? "eligible-immediate"
            : "released-after-verified-restart"
        recordTimelineEventIfNeeded(
            displayEvent,
            lifecycleState: "confirmed",
            popupState: eligiblePopupState
        )

        guard (displayEvent.popupPolicySnapshot?.isEnabled(for: displayEvent.type) ?? BroadcastEventPopupSettings.shared.isEnabled(for: displayEvent.type)) else {
            gameEventLifecycleStore.transition(displayEvent, to: .suppressed, source: "HockeyScoreboardViewModel.enqueueBanner", reason: "Popup disabled in settings")
            RinkLensOCREvidenceJournal.shared.recordEventAudit(
                stage: "overlay_suppressed",
                eventKind: displayEvent.type.title,
                source: displayEvent.source.rawValue,
                detail: "Popup disabled in Broadcast Event Popup settings"
            )
            statusMessage = "Event logged; popup disabled for \(displayEvent.type.title.lowercased())."
            return
        }

        gameEventLifecycleStore.transition(
            displayEvent,
            to: .eligible,
            source: "HockeyScoreboardViewModel.enqueueBanner",
            reason: releaseReason ?? "Event eligible for overlay queue"
        )
        let item = BroadcastOverlayQueueItem.event(
            displayEvent,
            durationSeconds: displayEvent.popupPolicySnapshot?.clampedDurationSeconds ?? clampedBroadcastPopupDurationSeconds,
            reason: "confirmed broadcast event"
        )
        enqueueUnifiedOverlay(item, traceReason: "enqueue broadcast event")
        RinkLensOCRReplayGateController.shared.recordEvent(
            stage: "overlay_enqueued",
            event: displayEvent,
            detail: "confirmed event entered unified overlay queue"
        )
    }

    // Build 626: Image Relay has no operator OCR mode, but automatic goal and
    // penalty popups remain active. Manual controls are corrections/overrides,
    // not the sole source of goal events.

    private func handleImageRelayMetadataObservation(
        _ observation: ScoreboardImageRelayMetadataObservation
    ) {
        let relayEnabled = ScoreboardImageRelayStore.shared.snapshot().enabled
        guard isImageRelayMode,
              userWantsOCRRunning,
              !isOCRPaused,
              relayEnabled else {
            RinkLensOCREvidenceJournal.shared.recordEventAudit(
                stage: "image_relay_metadata_observation_discarded",
                eventKind: "capture",
                source: BroadcastEventSource.ocr.rawValue,
                detail: "mode=\(operatingMode.rawValue) wanted=\(userWantsOCRRunning) paused=\(isOCRPaused) relayEnabled=\(relayEnabled) generation=\(observation.captureGeneration) sequence=\(observation.sourceSequence.map { String($0) } ?? "none")"
            )
            return
        }
        if observation.captureGeneration < imageRelayLastAcceptedCaptureGeneration {
            RinkLensOCREvidenceJournal.shared.recordEventAudit(
                stage: "image_relay_metadata_stale_generation_discarded",
                eventKind: "capture",
                source: BroadcastEventSource.ocr.rawValue,
                detail: "observation=\(observation.captureGeneration) accepted=\(imageRelayLastAcceptedCaptureGeneration)"
            )
            return
        }
        if observation.captureGeneration > imageRelayLastAcceptedCaptureGeneration {
            if imageRelayLastAcceptedCaptureGeneration > 0 {
                beginImageRelayResumeProtection(
                    reason: "capture generation \(imageRelayLastAcceptedCaptureGeneration)->\(observation.captureGeneration)"
                )
            }
            imageRelayLastAcceptedCaptureGeneration = observation.captureGeneration
            imageRelayLastAcceptedSourceSequence = nil
            // Frame sequences may restart when the capture generation changes.
            // Generation is the stronger fence, so do not compare the new stream
            // against the previous generation's sequence number.
            imageRelayMinimumSourceSequenceAfterResume = nil
        } else if let minimum = imageRelayMinimumSourceSequenceAfterResume,
                  let sequence = observation.sourceSequence,
                  sequence < minimum {
            RinkLensOCREvidenceJournal.shared.recordEventAudit(
                stage: "image_relay_metadata_pre_resume_frame_discarded",
                eventKind: "capture",
                source: BroadcastEventSource.ocr.rawValue,
                detail: "sequence=\(sequence) minimum=\(minimum) generation=\(observation.captureGeneration)"
            )
            return
        }
        if let sequence = observation.sourceSequence {
            imageRelayLastAcceptedSourceSequence = max(imageRelayLastAcceptedSourceSequence ?? sequence, sequence)
            if let minimum = imageRelayMinimumSourceSequenceAfterResume, sequence >= minimum {
                imageRelayMinimumSourceSequenceAfterResume = nil
            }
        }

        let semanticRoute = RinkLensImageRelaySemanticRouting.route(for: observation.kind)
        RinkLensStructuredEventLogger.shared.record(
            domain: .scoreboardPresentation,
            event: "image_relay_semantic_observation_routed",
            entityID: observation.sourceSequence.map(String.init) ?? "unsequenced",
            previous: ["route": "unresolved"],
            next: ["route": String(describing: semanticRoute)],
            source: "HockeyScoreboardViewModel.handleImageRelayMetadataObservation",
            reason: observation.diagnostic,
            captureGeneration: observation.captureGeneration,
            authoritativeOwner: "RinkLensMatchStateReducer"
        )
        switch semanticRoute {
        case .clock:
            handleImageRelayClockMetadata(observation)
        case .directScore:
            handleImageRelayDirectScoreCandidate(observation)
        case .visual:
            handleImageRelayVisualMetadata(observation)
        }
        imageRelayMetadataDiagnostic = observation.diagnostic
        refreshBroadcastOverlayState()
    }

    private func handleImageRelayClockMetadata(
        _ observation: ScoreboardImageRelayMetadataObservation
    ) {
        // Build 785 R8 removes automatic timeout semantics. Timeout-shaped
        // physical imagery remains engineering evidence only and can never create
        // a journal event or popup.
        if let transition = observation.timeoutTransition {
            RinkLensStructuredEventLogger.shared.record(
                domain: .gameEvent,
                event: "timeout_shape_observed_diagnostics_only",
                entityID: "image-relay-timeout-shape",
                previous: ["semanticEvent": "none"],
                next: ["shapeTransition": transition.rawValue, "semanticEvent": "none"],
                source: "HockeyScoreboardViewModel.handleImageRelayClockMetadata",
                reason: observation.diagnostic,
                captureGeneration: observation.captureGeneration,
                authoritativeOwner: "RinkLensGameEventLifecycleStore"
            )
        }
        guard observation.movementTransitioned,
              let running = observation.clockRunning else { return }
        let previousClockRunning = imageRelayMetadataClockRunning
        imageRelayMetadataClockRunning = running
        if running {
            imageRelayStableStopCancellationTask?.cancel()
            imageRelayStableStopCancellationTask = nil

            // Build 650 cumulative goal fix: a real goal can occur while the 2.1-second physical-stop
            // confirmation is still running. If the score changed by exactly one
            // during that candidate, commit the stoppage before processing restart;
            // otherwise discard the candidate as movement noise.
            if imageRelayStopCandidateInProgress, imageRelayStopCandidateHasSingleGoalDelta {
                commitImageRelayStoppageContext(
                    frozenClockImagePNGData: imageRelayStopCandidateFrozenClockImagePNGData,
                    observedAt: imageRelayStopCandidateObservedAt ?? observation.monotonicTime,
                    reason: "score-backed stop candidate completed by restart"
                )
            } else {
                clearImageRelayStopCandidateContext()
            }
            // The first credible restart owns an immutable five-second deadline
            // for this exact stoppage. A later penalty must never inherit an
            // expired deadline from an earlier stoppage.
            if let stoppageID = imageRelayCurrentStoppageID {
                if imageRelayLastCredibleRestartStoppageID != stoppageID
                    || imageRelayLastCredibleRestartReleaseDeadline == nil {
                    imageRelayLastCredibleRestartStoppageID = stoppageID
                    imageRelayLastCredibleRestartReleaseDeadline = observation.monotonicTime + 5.0
                }
                if imageRelayRestartReleaseStoppageID != stoppageID
                    || imageRelayRestartReleaseDue == nil {
                    imageRelayRestartReleaseStoppageID = stoppageID
                    imageRelayRestartReleaseDue = imageRelayLastCredibleRestartReleaseDeadline
                }
                evaluateImageRelayGoalCandidates(observedAt: observation.monotonicTime)
                if !imageRelayPendingEvents.isEmpty {
                    scheduleImageRelayPopupRelease()
                }
            }
            if RinkLensRiskFeaturePolicy.isEnabled(.stoppedBoardScoreAdmissionV19) {
                gameEventLifecycleStore.discardStoppedBoardScoreAdmissions(
                    source: "HockeyScoreboardViewModel.handleImageRelayClockMetadata",
                    reason: "Physical Clock restarted; any score candidate not admitted during the stoppage is stale"
                )
            }
            if RinkLensRiskFeaturePolicy.isEnabled(.runningScoreStoppageBaselineV2) {
                gameEventLifecycleStore.captureRunningScoreBaseline(
                    home: imageRelayMetadataHomeScore ?? state.homeScore,
                    away: imageRelayMetadataAwayScore ?? state.awayScore,
                    observedAt: observation.monotonicTime,
                    captureGeneration: observation.captureGeneration,
                    source: "HockeyScoreboardViewModel.handleImageRelayClockMetadata",
                    reason: "Physical Clock restart verified; freeze immutable score boundary for the next stoppage"
                )
            }
        } else {
            // Capture-generation and route recovery can replay a stopped transition
            // without the physical Clock ever restarting. Keep the existing
            // stoppage/frozen image in that case instead of fragmenting one long
            // stoppage into several unrelated popup transactions.
            if previousClockRunning == false, imageRelayCurrentStoppageID != nil {
                RinkLensOCREvidenceJournal.shared.recordEventAudit(
                    stage: "image_relay_duplicate_stopped_transition_ignored",
                    eventKind: "clock",
                    source: BroadcastEventSource.ocr.rawValue,
                    detail: "stoppage=\(imageRelayCurrentStoppageID?.uuidString ?? "none") generation=\(observation.captureGeneration)"
                )
                return
            }
            let frozenData = observation.frozenClockImage.flatMap {
                UIImage(cgImage: $0).pngData()
            }
            // Textual event time is intentionally absent. The immutable Clock
            // image captured by the movement authority remains popup evidence.
            if imageRelayLastCredibleRestartReleaseDeadline != nil
                || imageRelayRestartReleaseDue != nil
            {
                // During/after a restart window, one stop transition is only a candidate.
                // It cannot replace the previous stoppage image or reset its deadline.
                scheduleStableImageRelayStopCancellation(
                    observedAt: observation.monotonicTime,
                    frozenClockImagePNGData: frozenData
                )
            } else {
                commitImageRelayStoppageContext(
                    frozenClockImagePNGData: frozenData,
                    observedAt: observation.monotonicTime,
                    reason: "first stop without active restart window"
                )
            }
        }
    }

    // Build 708 removed the stopped-Clock OCR anchor, projected event-time model,
    // timeline estimate and next-anchor helpers. Physical movement and frozen Clock
    // image evidence remain owned by the event lifecycle path.

    private func handleImageRelayDirectScoreCandidate(
        _ observation: ScoreboardImageRelayMetadataObservation
    ) {
        let scores = observation.candidateValues.filter {
            $0.key == .homeScore || $0.key == .awayScore
        }
        guard !scores.isEmpty else { return }
        imageRelayLastDirectScoreGeneration = observation.captureGeneration
        imageRelayLastDirectScoreSequence = observation.sourceSequence
        RinkLensOCREvidenceJournal.shared.recordEventAudit(
            stage: "image_relay_score_lane_candidate_received",
            eventKind: "score",
            source: BroadcastEventSource.ocr.rawValue,
            detail: "sequence=\(observation.sourceSequence.map { String($0) } ?? "none") generation=\(observation.captureGeneration) values=\(scores.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: ","))"
        )
        updateImageRelayScoreMetadata(
            scores,
            candidateHashes: observation.candidateHashes,
            observedAt: observation.monotonicTime,
            sourceSequence: observation.sourceSequence,
            captureGeneration: observation.captureGeneration
        )
    }

    private func handleImageRelayVisualMetadata(
        _ observation: ScoreboardImageRelayMetadataObservation
    ) {
        let values = observation.visualValues
        if observation.attemptedKeys.contains(.period),
           let raw = values[.period],
           let period = Int(raw), (1...3).contains(period) {
            imageRelayMetadataPeriod = period
        }

        // Automatic goal popups remain part of Image Relay. The scorebug itself
        // stays Image Relay-first; recognised score values confirm the physical
        // transition while the stoppage/restart state machine still owns event release.
        // Build 674 must not discard a goal simply because the physical Clock is in
        // its expected stopped-candidate window. Penalty lifecycle mutation remains
        // gated below until that stop is committed or cancelled.
        if observation.attemptedKeys.contains(.homeScore)
            || observation.attemptedKeys.contains(.awayScore) {
            let duplicatesTypedScoreFrame =
                observation.captureGeneration == imageRelayLastDirectScoreGeneration
                && observation.sourceSequence != nil
                && observation.sourceSequence == imageRelayLastDirectScoreSequence
            if !duplicatesTypedScoreFrame {
                var scoreValues = values
                observation.candidateValues.forEach { scoreValues[$0.key] = $0.value }
                updateImageRelayScoreMetadata(
                    scoreValues,
                    candidateHashes: observation.candidateHashes,
                    observedAt: observation.monotonicTime,
                    sourceSequence: observation.sourceSequence,
                    captureGeneration: observation.captureGeneration
                )
            }
        }

        if imageRelayStopCandidateInProgress { return }
        if !observation.attemptedKeys.isDisjoint(with: [
            .homePenalty1Player, .homePenalty2Player,
            .awayPenalty1Player, .awayPenalty2Player
        ]) {
            updateImageRelayPenaltyMetadata(
                values,
                observedAt: observation.monotonicTime,
                captureGeneration: observation.captureGeneration,
                completeCycle: observation.completePenaltyPlayerCycle,
                slotEvidence: observation.penaltySlotEvidence
            )
        }
    }

    private func updateImageRelayScoreMetadata(
        _ values: [OCRRegionKey: String],
        candidateHashes: [OCRRegionKey: UInt64],
        observedAt: CFAbsoluteTime,
        sourceSequence: Int?,
        captureGeneration: Int
    ) {
        let home = values[.homeScore].flatMap { Int($0) }
        let away = values[.awayScore].flatMap { Int($0) }

        // Build 650: a physical 0-0 at the start of Period 1 is a new-game
        // baseline, not a large negative score intervention. The latest run had
        // stale metadata at 8-8, so the real 0-0 and subsequent 1-0 goal were
        // suppressed before the popup pipeline. Reset only while stopped, with no
        // active penalties or queued events, so mid-game score glitches cannot use
        // this path.
        if home == 0, away == 0,
           imageRelayScoreBaselineReady,
           (imageRelayMetadataHomeScore != 0 || imageRelayMetadataAwayScore != 0),
           imageRelayMetadataClockRunning != true,
           imageRelayMetadataPeriod == nil || imageRelayMetadataPeriod == 1,
           imageRelayActivePenaltyByIdentity.isEmpty,
           imageRelayPendingEvents.isEmpty {
            imageRelayMetadataHomeScore = 0
            imageRelayMetadataAwayScore = 0
            imageRelayStoppageHomeScoreBaseline = 0
            imageRelayStoppageAwayScoreBaseline = 0
            imageRelayLargeScoreCandidateEvidence.removeAll(keepingCapacity: true)
            imageRelayRejectedLargeScoreCandidate.removeAll(keepingCapacity: true)
            pendingImageRelayScoreConfirmation = nil
            ScoreboardImageRelayStore.shared.publishAcceptedScoreValue(
                0,
                for: .homeScore,
                reason: "Build 650 new-game 0-0 baseline reset"
            )
            ScoreboardImageRelayStore.shared.publishAcceptedScoreValue(
                0,
                for: .awayScore,
                reason: "Build 650 new-game 0-0 baseline reset"
            )
            RinkLensOCREvidenceJournal.shared.recordEventAudit(
                stage: "image_relay_new_game_score_baseline_reset",
                eventKind: "score",
                source: BroadcastEventSource.ocr.rawValue,
                detail: "stale metadata replaced by physical 0-0 before Period 1 play"
            )
            return
        }

        if !imageRelayScoreBaselineReady {
            // MatchState is the sole accepted score owner. Image Relay may have
            // started while the external board still displays a previous game;
            // that presentation observation must never replace the canonical
            // event baseline. Seed the recogniser projection from MatchState and
            // only evaluate an observed value immediately when physical Clock
            // evidence already establishes that play has begun.
            let canonicalHome = state.homeScore ?? 0
            let canonicalAway = state.awayScore ?? 0
            let clockEvidenceExists = imageRelayMetadataClockRunning != nil
            imageRelayMetadataHomeScore = canonicalHome
            imageRelayMetadataAwayScore = canonicalAway
            imageRelayScoreBaselineReady = true
            ScoreboardImageRelayStore.shared.publishAcceptedScoreValue(
                canonicalHome,
                for: .homeScore,
                reason: "Build 142 canonical Home event baseline"
            )
            ScoreboardImageRelayStore.shared.publishAcceptedScoreValue(
                canonicalAway,
                for: .awayScore,
                reason: "Build 142 canonical Away event baseline"
            )
            RinkLensOCREvidenceJournal.shared.recordEventAudit(
                stage: "image_relay_canonical_score_baseline_seeded",
                eventKind: "score",
                source: BroadcastEventSource.ocr.rawValue,
                detail: "home=\(canonicalHome) observed=\(home.map { String($0) } ?? "missing") away=\(canonicalAway) observed=\(away.map { String($0) } ?? "missing") clockEvidence=\(clockEvidenceExists)"
            )
            if clockEvidenceExists {
                if let home {
                    processImageRelayScore(home, team: .home, candidateHash: candidateHashes[.homeScore], observedAt: observedAt, sourceSequence: sourceSequence, captureGeneration: captureGeneration)
                }
                if let away {
                    processImageRelayScore(away, team: .away, candidateHash: candidateHashes[.awayScore], observedAt: observedAt, sourceSequence: sourceSequence, captureGeneration: captureGeneration)
                }
            }
            return
        }
        if let home {
            processImageRelayScore(home, team: .home, candidateHash: candidateHashes[.homeScore], observedAt: observedAt, sourceSequence: sourceSequence, captureGeneration: captureGeneration)
        }
        if let away {
            processImageRelayScore(away, team: .away, candidateHash: candidateHashes[.awayScore], observedAt: observedAt, sourceSequence: sourceSequence, captureGeneration: captureGeneration)
        }
    }

    private func processImageRelayScore(
        _ score: Int,
        team: Team,
        candidateHash: UInt64?,
        observedAt: CFAbsoluteTime,
        sourceSequence: Int?,
        captureGeneration: Int
    ) {
        guard (0...99).contains(score) else {
            RinkLensOCREvidenceJournal.shared.recordEventAudit(
                stage: "image_relay_score_transition_rejected",
                eventKind: "score",
                source: BroadcastEventSource.ocr.rawValue,
                detail: "team=\(team.rawValue) candidate=\(score) reason=score-out-of-range"
            )
            return
        }

        let metadataPrevious = team == .home ? imageRelayMetadataHomeScore : imageRelayMetadataAwayScore
        let canonicalPrevious = team == .home ? state.homeScore : state.awayScore
        let previous = metadataPrevious ?? canonicalPrevious ?? 0
        if metadataPrevious == nil {
            if team == .home { imageRelayMetadataHomeScore = previous }
            else { imageRelayMetadataAwayScore = previous }
            RinkLensOCREvidenceJournal.shared.recordEventAudit(
                stage: "image_relay_score_missing_side_baseline_recovered",
                eventKind: "score",
                source: BroadcastEventSource.ocr.rawValue,
                detail: "team=\(team.rawValue) recovered=\(previous) candidate=\(score) source=MatchState"
            )
        }

        let delta = score - previous
        // Build 674: a live hockey score cannot reduce automatically. The observed
        // Guest 7 repeatedly decoded as 1; allowing that negative jump into the
        // confirmation flow made a shape error look like a plausible correction.
        // The dedicated paired 0-0 new-game reset above is the sole automatic
        // decrease path. Any real mid-game correction remains an operator action.
        if delta < 0 {
            // Automatic decreases remain forbidden, but a stable physical lower
            // score must be offered as one explicit final-result correction. The
            // previous path silently rejected 5 -> 3 forever.
            let prior = imageRelayLargeScoreCandidateEvidence[team]
            let stillFresh = prior.map { observedAt - $0.lastObservedAt <= 3.0 } ?? false
            let count: Int
            if let prior, prior.previous == previous, prior.proposed == score, stillFresh {
                count = prior.count + 1
            } else {
                count = 1
            }
            imageRelayLargeScoreCandidateEvidence[team] = (previous, score, count, observedAt)
            guard count >= 2 else {
                RinkLensOCREvidenceJournal.shared.recordEventAudit(
                    stage: "image_relay_score_downward_correction_held_for_repeat",
                    eventKind: "score",
                    source: BroadcastEventSource.ocr.rawValue,
                    detail: "team=\(team.rawValue) current=\(previous) candidate=\(score) evidence=1/2 noAutomaticChange=true"
                )
                return
            }
            if pendingImageRelayScoreConfirmation?.team != team
                || pendingImageRelayScoreConfirmation?.proposed != score
                || pendingImageRelayScoreConfirmation?.previous != previous {
                pendingImageRelayScoreConfirmation = RinkLensPendingScoreConfirmation(
                    team: team,
                    previous: previous,
                    proposed: score,
                    observedAt: observedAt
                )
                statusMessage = "\(team.displayName) score correction requires confirmation: \(previous) → \(score)."
                RinkLensOCREvidenceJournal.shared.recordEventAudit(
                    stage: "image_relay_score_downward_manual_confirmation_requested",
                    eventKind: "score",
                    source: BroadcastEventSource.ocr.rawValue,
                    detail: "team=\(team.rawValue) current=\(previous) proposed=\(score) repeatedEvidence=\(count) final-result-only=true"
                )
            }
            return
        }
        if delta > 1 {
            if let rejected = imageRelayRejectedLargeScoreCandidate[team],
               rejected.previous == previous, rejected.proposed == score {
                RinkLensOCREvidenceJournal.shared.recordEventAudit(
                    stage: "image_relay_score_rejected_candidate_suppressed",
                    eventKind: "score",
                    source: BroadcastEventSource.ocr.rawValue,
                    detail: "team=\(team.rawValue) current=\(previous) suppressed=\(score) until-physical-score-changes"
                )
                return
            }
            let prior = imageRelayLargeScoreCandidateEvidence[team]
            let stillFresh = prior.map { observedAt - $0.lastObservedAt <= 3.0 } ?? false
            let count: Int
            if let prior, prior.previous == previous, prior.proposed == score, stillFresh {
                count = prior.count + 1
            } else {
                count = 1
            }
            imageRelayLargeScoreCandidateEvidence[team] = (previous, score, count, observedAt)
            guard count >= 2 else {
                RinkLensOCREvidenceJournal.shared.recordEventAudit(
                    stage: "image_relay_score_large_jump_held_for_repeat",
                    eventKind: "score",
                    source: BroadcastEventSource.ocr.rawValue,
                    detail: "team=\(team.rawValue) current=\(previous) candidate=\(score) evidence=1/2"
                )
                return
            }
            if pendingImageRelayScoreConfirmation?.team != team
                || pendingImageRelayScoreConfirmation?.proposed != score
                || pendingImageRelayScoreConfirmation?.previous != previous {
                pendingImageRelayScoreConfirmation = RinkLensPendingScoreConfirmation(
                    team: team,
                    previous: previous,
                    proposed: score,
                    observedAt: observedAt
                )
                statusMessage = "\(team.displayName) score requires confirmation: \(previous) → \(score)."
                RinkLensOCREvidenceJournal.shared.recordEventAudit(
                    stage: "image_relay_score_manual_confirmation_requested",
                    eventKind: "score",
                    source: BroadcastEventSource.ocr.rawValue,
                    detail: "team=\(team.rawValue) current=\(previous) proposed=\(score) delta=\(delta) repeatedEvidence=\(count) noAutomaticPopups=true"
                )
            }
            return
        }
        imageRelayLargeScoreCandidateEvidence[team] = nil
        imageRelayRejectedLargeScoreCandidate[team] = nil

        let transition = RinkLensUnattendedScoreTransitionPolicy.evaluate(
            current: previous,
            candidate: score
        )
        guard transition.isAllowed else { return }

        if RinkLensRiskFeaturePolicy.isEnabled(.stoppedBoardScoreAdmissionV19), delta == 1 {
            if imageRelayMetadataClockRunning == true {
                guard let candidateHash else {
                    RinkLensStructuredEventLogger.shared.record(
                        domain: .gameEvent,
                        event: "running_score_candidate_rejected_without_physical_hash",
                        entityID: team.rawValue,
                        previous: ["score": String(previous)],
                        next: ["candidate": String(score), "admitted": "false"],
                        source: "HockeyScoreboardViewModel.processImageRelayScore",
                        reason: "Running score candidates require physical glyph identity before event admission",
                        captureGeneration: captureGeneration,
                        authoritativeOwner: "RinkLensGameEventLifecycleStore"
                    )
                    return
                }
                gameEventLifecycleStore.holdRunningScoreCandidate(
                    team: team,
                    baseline: previous,
                    proposed: score,
                    glyphHash: candidateHash,
                    observedAt: observedAt,
                    captureGeneration: captureGeneration,
                    source: "HockeyScoreboardViewModel.processImageRelayScore",
                    reason: "Sequential score first observed while physical Clock was running; hold outside MatchState and viewer presentation"
                )
                RinkLensOCREvidenceJournal.shared.recordEventAudit(
                    stage: "image_relay_running_score_candidate_held",
                    eventKind: "score",
                    source: BroadcastEventSource.ocr.rawValue,
                    detail: "team=\(team.rawValue) current=\(previous) candidate=\(score) hash=\(candidateHash) sequence=\(sourceSequence.map { String($0) } ?? "none")"
                )
                return
            }
            if let candidateHash {
                let admitted = gameEventLifecycleStore.observeStoppedBoardScoreCandidate(
                    team: team,
                    baseline: previous,
                    proposed: score,
                    glyphHash: candidateHash,
                    observedAt: observedAt,
                    captureGeneration: captureGeneration,
                    source: "HockeyScoreboardViewModel.processImageRelayScore",
                    reason: "Stopped-board score observation must differ materially from the running glyph and repeat before score mutation"
                )
                guard admitted else { return }
            }
        }

        _ = reconcileImageRelayPendingGoals(
            team: team,
            confirmedScore: score,
            reason: "confirmed score observation"
        )
        guard score != previous else { return }

        // Recovery DT: a normal accepted Image Relay score is semantic match state,
        // not presentation-only metadata. Commit it through the single MatchState
        // owner before viewer refresh or goal-event evaluation. Keep eventPolicy
        // empty here because the stopped-board Image Relay lifecycle below owns the
        // goal/popup transaction and must not be duplicated by the generic reducer.
        let scoreCommitContext = RinkLensMatchStateContext(
            origin: .ocr,
            eventPolicy: [],
            diagnosticsOnly: false,
            reason: "Recovery DT accepted Image Relay score transition \(previous)->\(score)"
        )
        let scoreReduction = reduceMatchState(
            .setScores(
                home: team == .home ? score : state.homeScore,
                away: team == .away ? score : state.awayScore,
                context: scoreCommitContext
            )
        )

        if team == .home {
            imageRelayMetadataHomeScore = score
            if imageRelayStopCandidateInProgress {
                imageRelayStopCandidateHomeScoreObservedAt = observedAt
            }
            if imageRelayCurrentStoppageID != nil { imageRelayStoppageHomeScoreObservedAt = observedAt }
        } else {
            imageRelayMetadataAwayScore = score
            if imageRelayStopCandidateInProgress {
                imageRelayStopCandidateAwayScoreObservedAt = observedAt
            }
            if imageRelayCurrentStoppageID != nil { imageRelayStoppageAwayScoreObservedAt = observedAt }
        }

        RinkLensOCREvidenceJournal.shared.recordEventAudit(
            stage: "image_relay_score_display_updated",
            eventKind: "score",
            source: BroadcastEventSource.ocr.rawValue,
            detail: "team=\(team.rawValue) previous=\(previous) accepted=\(score) delta=\(delta) reducerChanged=\(scoreReduction.changed) reason=\(transition.reason) popupDecision=deferred-to-stoppage-net-change"
        )

        // Build 696: an accepted +1 score inside a physical stop transaction is
        // itself strong evidence that the stoppage must be retained. Previously
        // the event was deferred until a Clock-running transition; one false
        // movement followed by a replacement stop could therefore leave the score
        // visible at 1 while never creating a goal event or popup.
        if RinkLensRiskFeaturePolicy.isEnabled(.scoreGoalEventAtAcceptedTransitionV2) {
            if delta == 1,
               imageRelayStopCandidateInProgress,
               imageRelayCurrentStoppageID == nil {
                commitImageRelayStoppageContext(
                    frozenClockImagePNGData: imageRelayStopCandidateFrozenClockImagePNGData,
                    observedAt: imageRelayStopCandidateObservedAt ?? observedAt,
                    reason: "accepted plus-one score proved stopped-board transaction"
                )
                RinkLensStructuredEventLogger.shared.record(
                    domain: .gameEvent,
                    event: "goal_stoppage_committed_from_score",
                    entityID: imageRelayCurrentStoppageID?.uuidString,
                    previous: ["score": String(previous), "stoppage": "candidate"],
                    next: ["score": String(score), "stoppage": imageRelayCurrentStoppageID?.uuidString ?? "none"],
                    source: "HockeyScoreboardViewModel.handleImageRelayDirectScoreCandidate",
                    reason: "Accepted sequential plus-one score inside stopped-board candidate",
                    captureGeneration: imageRelayLastAcceptedCaptureGeneration,
                    stoppageID: imageRelayCurrentStoppageID
                )
            }
            if imageRelayEventWindowIsOpen {
                evaluateImageRelayGoalCandidates(observedAt: observedAt)
            }
        } else if imageRelayMetadataClockRunning == true, imageRelayEventWindowIsOpen {
            // Legacy path retained for comparison.
            evaluateImageRelayGoalCandidates(observedAt: observedAt)
        }
    }

    func acceptPendingImageRelayScoreConfirmation() {
        guard let pending = pendingImageRelayScoreConfirmation else { return }
        pendingImageRelayScoreConfirmation = nil
        imageRelayLargeScoreCandidateEvidence[pending.team] = nil
        imageRelayRejectedLargeScoreCandidate[pending.team] = nil

        // Build 676 commits one final, event-free score correction through the
        // authoritative MatchState reducer. This keeps the unchanged team score
        // intact and updates the visible scorebug immediately without generating
        // intermediate goal events or popups.
        let context = RinkLensMatchStateContext(
            origin: .manual,
            eventPolicy: [],
            diagnosticsOnly: false,
            reason: "Operator accepted final Image Relay score correction"
        )
        let correctedHome = pending.team == .home
            ? pending.proposed
            : (imageRelayMetadataHomeScore ?? ScoreboardImageRelayStore.shared.snapshot().visualFieldValues[.homeScore].flatMap { Int($0) } ?? state.homeScore ?? 0)
        let correctedAway = pending.team == .away
            ? pending.proposed
            : (imageRelayMetadataAwayScore ?? ScoreboardImageRelayStore.shared.snapshot().visualFieldValues[.awayScore].flatMap { Int($0) } ?? state.awayScore ?? 0)
        let reduction = reduceMatchState(
            .setScores(home: correctedHome, away: correctedAway, context: context)
        )

        if pending.team == .home {
            imageRelayMetadataHomeScore = pending.proposed
            imageRelayStoppageHomeScoreBaseline = pending.proposed
        } else {
            imageRelayMetadataAwayScore = pending.proposed
            imageRelayStoppageAwayScoreBaseline = pending.proposed
        }
        ScoreboardImageRelayStore.shared.publishAcceptedScoreValue(
            pending.proposed,
            for: pending.team == .home ? .homeScore : .awayScore,
            reason: "operator accepted final score correction"
        )
        _ = reconcileImageRelayPendingGoals(
            team: pending.team,
            confirmedScore: pending.proposed,
            reason: "operator accepted manual score intervention"
        )
        statusMessage = "\(pending.team.displayName) score accepted at \(pending.proposed). No goal popups created."
        RinkLensOCREvidenceJournal.shared.recordEventAudit(
            stage: "image_relay_score_manual_confirmation_accepted",
            eventKind: "score",
            source: BroadcastEventSource.manual.rawValue,
            detail: "team=\(pending.team.rawValue) previous=\(pending.previous) accepted=\(pending.proposed) reducerChanged=\(reduction.changed) finalVisible=\(state.homeScore ?? 0)-\(state.awayScore ?? 0) noAutomaticPopups=true"
        )
    }

    func rejectPendingImageRelayScoreConfirmation() {
        guard let pending = pendingImageRelayScoreConfirmation else { return }
        pendingImageRelayScoreConfirmation = nil
        imageRelayLargeScoreCandidateEvidence[pending.team] = nil
        imageRelayRejectedLargeScoreCandidate[pending.team] = (pending.previous, pending.proposed)
        statusMessage = "\(pending.team.displayName) score change to \(pending.proposed) rejected; physical Image Relay fallback retained until the board is corrected or OCR resolves."
        RinkLensOCREvidenceJournal.shared.recordEventAudit(
            stage: "image_relay_score_manual_confirmation_rejected",
            eventKind: "score",
            source: BroadcastEventSource.manual.rawValue,
            detail: "team=\(pending.team.rawValue) retained=\(pending.previous) rejected=\(pending.proposed)"
        )
    }

    private func evaluateImageRelayGoalCandidates(observedAt: CFAbsoluteTime) {
        guard let stoppageID = imageRelayCurrentStoppageID else { return }

        func evaluate(
            team: Team,
            baseline: Int?,
            current: Int?,
            changeObservedAt: CFAbsoluteTime?
        ) {
            guard let baseline, let current else { return }
            let delta = current - baseline
            if delta != 1 {
                _ = reconcileImageRelayPendingGoals(
                    team: team,
                    confirmedScore: current,
                    reason: "stoppage net score delta \(delta)"
                )
                return
            }
            let goalKey = "score-goal|team=\(team.rawValue)|home=\(imageRelayMetadataHomeScore.map { String($0) } ?? "none")|away=\(imageRelayMetadataAwayScore.map { String($0) } ?? "none")"
            let alreadyQueued = imageRelayPendingEvents.contains {
                $0.scoreTeam == team
                    && $0.scoreExpected == current
                    && $0.event.homeScoreAfter == imageRelayMetadataHomeScore
                    && $0.event.awayScoreAfter == imageRelayMetadataAwayScore
            }
            guard !alreadyQueued else {
                RinkLensOCREvidenceJournal.shared.recordEventAudit(
                    stage: "image_relay_duplicate_stoppage_goal_suppressed",
                    eventKind: "goal",
                    source: BroadcastEventSource.ocr.rawValue,
                    detail: "team=\(team.rawValue) stoppage=\(stoppageID.uuidString) key=\(goalKey)"
                )
                return
            }

            let strengthBeforeGoal = imageRelayMetadataStrengthState
            let metadataPowerPlayGoal = strengthBeforeGoal.advantagedTeam == team
            let relaySnapshotAtScoreChange = ScoreboardImageRelayStore.shared.snapshot()
            let visibleOpposingPenaltyKeys: [OCRRegionKey] = team == .home
                ? [.awayPenalty1Player, .awayPenalty2Player]
                : [.homePenalty1Player, .homePenalty2Player]
            let visibleOpposingPenaltyCount = visibleOpposingPenaltyKeys.filter {
                relaySnapshotAtScoreChange.penaltySlotIsConfirmedOccupied($0)
            }.count
            let physicallyVerifiedPowerPlayGoal = RinkLensPowerPlayGoalAdmission.shouldClassifyAsPowerPlay(
                scoringTeam: team,
                physicalAdvantagedTeam: relaySnapshotAtScoreChange.visualAdvantagedTeam,
                visibleOpposingPenaltyCount: visibleOpposingPenaltyCount
            )
            let isPowerPlayGoal = RinkLensRiskFeaturePolicy.isEnabled(.powerPlayGoalRequiresVisiblePenaltyV9)
                ? physicallyVerifiedPowerPlayGoal
                : metadataPowerPlayGoal
            if metadataPowerPlayGoal && !physicallyVerifiedPowerPlayGoal {
                RinkLensStructuredEventLogger.shared.record(
                    domain: .gameEvent,
                    event: "power_play_goal_downgraded_stale_penalty",
                    entityID: goalKey,
                    previous: [
                        "metadataAdvantagedTeam": strengthBeforeGoal.advantagedTeam?.rawValue ?? "none",
                        "activePenaltyLifecycleCount": String(imageRelayActivePenaltyByIdentity.values.filter(\.isActive).count)
                    ],
                    next: [
                        "eventType": "goal",
                        "physicalAdvantagedTeam": relaySnapshotAtScoreChange.visualAdvantagedTeam?.rawValue ?? "none",
                        "visibleOpposingPenaltyCount": String(visibleOpposingPenaltyCount)
                    ],
                    source: "HockeyScoreboardViewModel.evaluateImageRelayGoalCandidates",
                    reason: "Build 719 requires current physical opposing-penalty visibility before power-play classification"
                )
            }
            var endedPenaltyIdentity: String?
            var endedPenaltyClock: PenaltyClock?
            if isPowerPlayGoal,
               RinkLensRiskFeaturePolicy.isEnabled(.powerPlayGoalUsesPhysicalRemovalV11) {
                // Build 723: the physical scoreboard is the penalty-lifecycle
                // authority. At 5v3 -> goal -> 5v4, the board may already have
                // removed/compacted the served penalty before score OCR confirms
                // the goal. Deleting the remaining visible penalty here caused
                // #45 to disappear and then re-enter as a random new popup.
                if let removal = penaltyLifecycleStore.recentPhysicalRemoval(
                    opposing: team,
                    stoppageID: stoppageID,
                    observedAt: changeObservedAt ?? observedAt
                ) {
                    // Build 736: on a standard two-minor 5v3, the oldest penalty
                    // (physical Slot 1) is served by the goal. The scoreboard then
                    // compacts Slot 2 into Slot 1, so the disappearing physical
                    // Slot 2 must not be interpreted as the penalty that ended.
                    var compactionServedIdentity: String?
                    var compactionServedClock: PenaltyClock?
                    if RinkLensRiskFeaturePolicy.isEnabled(.atomicPowerPlayCompactionSnapshotV24) {
                        let preRemovalOpposing = removal.activeTeamClocksBeforeRemoval
                            .filter { $0.value.isActive && $0.value.team != team }
                            .sorted { lhs, rhs in
                                if lhs.value.slot != rhs.value.slot { return lhs.value.slot < rhs.value.slot }
                                return lhs.key < rhs.key
                            }
                        if preRemovalOpposing.count >= 2,
                           removal.clock.slot > 1,
                           let served = preRemovalOpposing.first {
                            compactionServedIdentity = served.key
                            compactionServedClock = served.value
                        }
                    } else {
                        var activeOpposingBeforeGoal = imageRelayActivePenaltyByIdentity.values
                            .filter { $0.isActive && $0.team != team }
                        if !activeOpposingBeforeGoal.contains(where: {
                            $0.team == removal.clock.team
                                && $0.slot == removal.clock.slot
                                && $0.playerNumber == removal.clock.playerNumber
                        }) {
                            // Build 743 rollback: infer the pre-compaction state
                            // from the already-mutated active dictionary.
                            activeOpposingBeforeGoal.append(removal.clock)
                        }
                        activeOpposingBeforeGoal.sort { $0.slot < $1.slot }
                        compactionServedClock = activeOpposingBeforeGoal.count >= 2 && removal.clock.slot > 1
                            ? activeOpposingBeforeGoal.first
                            : nil
                        compactionServedIdentity = compactionServedClock.flatMap { servedClock in
                            imageRelayActivePenaltyByIdentity.first(where: { element in
                                element.value.team == servedClock.team
                                    && element.value.slot == servedClock.slot
                                    && element.value.playerNumber == servedClock.playerNumber
                            })?.key
                        }
                    }
                    let resolvedIdentity = compactionServedIdentity ?? removal.identity
                    let resolvedClock = compactionServedClock ?? removal.clock

                    endedPenaltyIdentity = resolvedIdentity
                    endedPenaltyClock = resolvedClock
                    penaltyLifecycleStore.recordPowerPlayCancellation(
                        identity: resolvedIdentity,
                        stoppageID: stoppageID,
                        observedAt: changeObservedAt ?? observedAt,
                        source: "HockeyScoreboardViewModel.evaluateImageRelayGoalCandidates",
                        reason: compactionServedIdentity == nil
                            ? "Power-play goal associated with the already-confirmed physical penalty removal; remaining visible penalties are untouched"
                            : "Two-penalty physical compaction: cancel oldest Slot 1 lifecycle and retain the Slot 2 player moving into Slot 1"
                    )
                    if RinkLensRiskFeaturePolicy.isEnabled(.atomicPowerPlayCompactionSnapshotV24),
                       let compactionServedIdentity,
                       compactionServedIdentity != removal.identity {
                        let beforeState = imageRelayActivePenaltyByIdentity
                            .filter { $0.value.team == removal.clock.team }
                            .map { "\($0.key)@slot\($0.value.slot)" }
                            .sorted()
                            .joined(separator: ",")
                        imageRelayActivePenaltyByIdentity[compactionServedIdentity] = nil
                        var continuingClock = removal.clock
                        continuingClock.slot = 1
                        imageRelayActivePenaltyByIdentity[removal.identity] = continuingClock
                        if let destination = penaltyRegionPair(team: continuingClock.team, slot: 1) {
                            imageRelayPenaltyLifecycleIDBySlot[destination.player] = removal.identity
                        }
                        if let sourcePair = penaltyRegionPair(team: continuingClock.team, slot: 2) {
                            imageRelayPenaltyLifecycleIDBySlot[sourcePair.player] = nil
                        }
                        ScoreboardImageRelayStore.shared.compactConfirmedPenaltySlot2ToSlot1(
                            team: continuingClock.team,
                            sourceSequence: imageRelayLastAcceptedSourceSequence,
                            captureGeneration: imageRelayLastAcceptedCaptureGeneration,
                            reason: "Power-play goal served oldest Slot 1 lifecycle \(compactionServedIdentity); continuing \(removal.identity) moved from physical Slot 2"
                        )
                        publishImageRelayPenaltyMetadata()
                        let afterState = imageRelayActivePenaltyByIdentity
                            .filter { $0.value.team == continuingClock.team }
                            .map { "\($0.key)@slot\($0.value.slot)" }
                            .sorted()
                            .joined(separator: ",")
                        RinkLensStructuredEventLogger.shared.record(
                            domain: .penalty,
                            event: "power_play_penalty_compaction_committed",
                            entityID: removal.identity,
                            previous: [
                                "teamState": beforeState,
                                "servedIdentity": compactionServedIdentity,
                                "disappearedPhysicalIdentity": removal.identity
                            ],
                            next: [
                                "teamState": afterState,
                                "continuingIdentity": removal.identity,
                                "continuingSlot": "1"
                            ],
                            source: "HockeyScoreboardViewModel.evaluateImageRelayGoalCandidates",
                            reason: "Immutable pre-removal two-slot evidence proves the oldest Slot 1 minor ended and the Slot 2 lifecycle continues in Slot 1",
                            captureGeneration: imageRelayLastAcceptedCaptureGeneration,
                            stoppageID: stoppageID,
                            authoritativeOwner: "RinkLensPenaltyLifecycleStore"
                        )
                    }
                    if let compactionServedIdentity, compactionServedIdentity != removal.identity {
                        RinkLensStructuredEventLogger.shared.record(
                            domain: .penalty,
                            event: "power_play_compaction_removal_reinterpreted",
                            entityID: compactionServedIdentity,
                            previous: [
                                "disappearedPhysicalIdentity": removal.identity,
                                "disappearedPhysicalSlot": String(removal.clock.slot)
                            ],
                            next: [
                                "servedLifecycle": compactionServedIdentity,
                                "servedSlot": String(resolvedClock.slot),
                                "continuingPhysicalIdentity": removal.identity
                            ],
                            source: "HockeyScoreboardViewModel.evaluateImageRelayGoalCandidates",
                            reason: "The board compacted the continuing Slot 2 penalty after the oldest Slot 1 minor was served by the goal",
                            captureGeneration: imageRelayLastAcceptedCaptureGeneration,
                            stoppageID: stoppageID
                        )
                    }
                    RinkLensStructuredEventLogger.shared.record(
                        domain: .gameEvent,
                        event: "power_play_goal_bound_to_physical_penalty_removal",
                        entityID: goalKey,
                        previous: [
                            "endedPenalty": "none",
                            "activeOpposingPenalties": String(imageRelayActivePenaltyByIdentity.values.filter { $0.team != team && $0.isActive }.count)
                        ],
                        next: [
                            "endedPenalty": resolvedIdentity,
                            "remainingOpposingPenalties": String(imageRelayActivePenaltyByIdentity.values.filter { $0.team != team && $0.isActive }.count)
                        ],
                        source: "HockeyScoreboardViewModel.evaluateImageRelayGoalCandidates",
                        reason: "Use recent physical removal evidence instead of mutating the currently visible penalty state",
                        captureGeneration: imageRelayLastAcceptedCaptureGeneration,
                        stoppageID: stoppageID
                    )
                } else {
                    RinkLensStructuredEventLogger.shared.record(
                        domain: .gameEvent,
                        event: "power_play_goal_without_physical_removal_yet",
                        entityID: goalKey,
                        previous: ["endedPenalty": "none"],
                        next: [
                            "eventType": "powerPlayGoal",
                            "visibleOpposingPenaltyCount": String(visibleOpposingPenaltyCount),
                            "activePenaltyStateMutated": "false"
                        ],
                        source: "HockeyScoreboardViewModel.evaluateImageRelayGoalCandidates",
                        reason: "The visible advantage proves classification, but no physical removal has yet identified which penalty ended",
                        captureGeneration: imageRelayLastAcceptedCaptureGeneration,
                        stoppageID: stoppageID
                    )
                }
            } else if isPowerPlayGoal {
                let opposing = imageRelayActivePenaltyByIdentity
                    .filter { $0.value.team != team && $0.value.isActive }
                    .sorted { lhs, rhs in
                        if lhs.value.slot != rhs.value.slot { return lhs.value.slot < rhs.value.slot }
                        return lhs.key < rhs.key
                    }
                    .first
                if let opposing {
                    endedPenaltyIdentity = opposing.key
                    endedPenaltyClock = opposing.value
                    penaltyLifecycleStore.recordPowerPlayCancellation(
                        identity: opposing.key,
                        stoppageID: stoppageID,
                        observedAt: changeObservedAt ?? observedAt,
                        source: "HockeyScoreboardViewModel.evaluateImageRelayGoalCandidates",
                        reason: "Legacy transactional power-play cancellation rollback path"
                    )
                    imageRelayActivePenaltyByIdentity[opposing.key] = nil
                    if let pair = penaltyRegionPair(team: opposing.value.team, slot: opposing.value.slot) {
                        imageRelayPenaltyLifecycleIDBySlot[pair.player] = nil
                        ScoreboardImageRelayStore.shared.reconcileConfirmedPenaltyVisibility(
                            occupiedKeys: [], blankKeys: [pair.player],
                            sourceSequence: imageRelayLastAcceptedSourceSequence,
                            captureGeneration: imageRelayLastAcceptedCaptureGeneration,
                            reason: "Legacy power-play goal transactional penalty clear"
                        )
                    }
                    imageRelayPendingEvents.removeAll {
                        $0.event.penaltyLifecycleID == opposing.key
                            && ($0.event.type == .penalty || $0.event.type == .penalties)
                    }
                    publishImageRelayPenaltyMetadata()
                }
            }

            var event = BroadcastEvent(
                type: isPowerPlayGoal ? .powerPlayGoal : .goal,
                team: team,
                period: imageRelayMetadataPeriod,
                gameClock: nil,
                homeScoreAfter: imageRelayMetadataHomeScore,
                awayScoreAfter: imageRelayMetadataAwayScore,
                strengthState: imageRelayMetadataStrengthState,
                source: .ocr,
                operatorConfirmed: false,
                penaltyClockSnapshot: imageRelayMetadataPenaltyClocks,
                endedPenaltyClockSnapshot: endedPenaltyClock.map { [$0] } ?? [],
                penaltyLifecycleID: endedPenaltyIdentity,
                captureGeneration: imageRelayLastAcceptedCaptureGeneration
            )
            attachImageRelayStoppageContext(
                to: &event,
                observedAt: changeObservedAt ?? observedAt
            )
            queueImageRelayMetadataEvent(
                event,
                priority: 0,
                observedAt: changeObservedAt ?? observedAt,
                scoreTeam: team,
                scoreBaseline: baseline,
                scoreExpected: current
            )
            RinkLensOCREvidenceJournal.shared.recordEventAudit(
                stage: "image_relay_stoppage_goal_qualified",
                eventKind: "goal",
                source: BroadcastEventSource.ocr.rawValue,
                detail: "team=\(team.rawValue) stoppage=\(stoppageID.uuidString) baseline=\(baseline) final=\(current) netDelta=1"
            )
        }

        evaluate(
            team: .home,
            baseline: imageRelayStoppageHomeScoreBaseline,
            current: imageRelayMetadataHomeScore,
            changeObservedAt: imageRelayStoppageHomeScoreObservedAt
        )
        evaluate(
            team: .away,
            baseline: imageRelayStoppageAwayScoreBaseline,
            current: imageRelayMetadataAwayScore,
            changeObservedAt: imageRelayStoppageAwayScoreObservedAt
        )
    }

    private enum ImageRelayPenaltySlotResolution {
        /// Stable physical relay identity is the lifecycle authority. `player` is
        /// optional Home-only roster metadata and never drives the live scorebug.
        case occupied(
            identity: String,
            player: String?,
            physicalSlot: Int,
            startAuthorised: Bool,
            physicalTransitionProof: Bool,
            visiblePairTransitionProof: Bool
        )
        case confirmedBlank
        case unresolved

        var signatureValue: String {
            switch self {
            case .occupied(let identity, _, _, _, _, _): return identity
            case .confirmedBlank: return "-"
            case .unresolved: return "?"
            }
        }

        var isResolved: Bool {
            if case .unresolved = self { return false }
            return true
        }
    }

    private func updateImageRelayPenaltyMetadata(
        _ values: [OCRRegionKey: String],
        observedAt: CFAbsoluteTime,
        captureGeneration: Int,
        completeCycle: Bool,
        slotEvidence: [OCRRegionKey: ScoreboardImageRelayPenaltySlotEvidence]
    ) {
        let previous = imageRelayActivePenaltyByIdentity
        let previousStrengthText = imageRelayMetadataStrengthState.scorebugManpowerText
        let now = CFAbsoluteTimeGetCurrent()
        let observationAge = max(0, now - observedAt)
        // Build 641 fail-closed rule. A delayed OCR task must not apply an old
        // player/hash snapshot to the current stoppage. Image Relay presentation
        // remains live; only stale metadata/event mutation is rejected.
        guard observationAge <= 3.0 else {
            RinkLensOCREvidenceJournal.shared.recordEventAudit(
                stage: "image_relay_stale_penalty_observation_rejected",
                eventKind: "penalty",
                source: BroadcastEventSource.ocr.rawValue,
                detail: "age=\(String(format: "%.2f", observationAge))s generation=\(captureGeneration) complete=\(completeCycle)"
            )
            return
        }
        let resumeProtected = now <= imageRelayPenaltyResumeProtectionUntil
        let relaySnapshotAtObservation = ScoreboardImageRelayStore.shared.snapshot()
        let confirmedVisibilityKeys = relaySnapshotAtObservation.confirmedPenaltyPlayerKeys
        let newlyConfirmedVisibilityKeys = confirmedVisibilityKeys.subtracting(
            imageRelayLastConfirmedPenaltyVisibilityKeys
        )
        defer {
            imageRelayLastConfirmedPenaltyVisibilityKeys = confirmedVisibilityKeys
        }

        func keys(for team: Team) -> [(OCRRegionKey, Int)] {
            switch team {
            case .home: return [(.homePenalty1Player, 1), (.homePenalty2Player, 2)]
            case .away: return [(.awayPenalty1Player, 1), (.awayPenalty2Player, 2)]
            }
        }

        var claimedPreviousPenaltyIdentities: Set<String> = []

        func resolution(
            team: Team,
            key: OCRRegionKey,
            physicalSlot: Int
        ) -> ImageRelayPenaltySlotResolution {
            guard let evidence = slotEvidence[key] else {
                // Compatibility fallback for older diagnostic observations only.
                if let text = values[key], Int(text) != nil {
                    return .occupied(
                        identity: "\(team.rawValue)-legacy-\(text)",
                        player: team == .home ? text : nil,
                        physicalSlot: physicalSlot,
                        startAuthorised: false,
                        physicalTransitionProof: false,
                        visiblePairTransitionProof: false
                    )
                }
                return .unresolved
            }
            switch evidence.occupancy {
            case .confirmedBlank:
                return .confirmedBlank
            case .unresolved:
                return .unresolved
            case .confirmedOccupied:
                guard evidence.stableOccupiedCount >= 2,
                      evidence.physicalIdentityHash != nil else {
                    return .unresolved
                }
                let playerText: String? = {
                    // Build 636: a strong, repeated current read must outrank stale
                    // retained identity. This fixes the physical #56 -> #34 slot
                    // shift where the old player remained in the popup despite
                    // fresh OCR repeatedly reading the new player.
                    let strongRaw: String? = {
                        guard evidence.confidence >= 0.78,
                              evidence.stableOccupiedCount >= 2,
                              let raw = evidence.rawCandidate,
                              let number = Int(raw),
                              (0...99).contains(number) else { return nil }
                        return String(number)
                    }()
                    let candidate = strongRaw
                        ?? evidence.resolvedPlayer
                        ?? evidence.retainedPlayer
                        ?? (evidence.confidence >= 0.62 ? evidence.rawCandidate : nil)
                    guard let candidate,
                          let number = Int(candidate),
                          (0...99).contains(number) else { return nil }
                    return String(number)
                }()
                let existingBySlot = previous.first(where: { item in
                    item.value.team == team && item.value.slot == physicalSlot
                })
                let matchingPlayerIdentities: [String] = playerText.map { playerText in
                    previous.compactMap { identity, clock in
                        guard clock.team == team,
                              clock.playerNumber.map({ String($0) }) == playerText,
                              !claimedPreviousPenaltyIdentities.contains(identity)
                        else { return nil }
                        return identity
                    }
                } ?? []
                let matchingPhysicalIdentities: [String] = evidence.physicalIdentityHash.map { physicalHash in
                    let suffix = "-physical-\(String(physicalHash, radix: 16))"
                    return previous.compactMap { identity, clock in
                        guard clock.team == team,
                              identity.hasSuffix(suffix),
                              !claimedPreviousPenaltyIdentities.contains(identity)
                        else { return nil }
                        return identity
                    }
                } ?? []
                let slotKey = key
                // Build 650: a confirmed physical player in a calibrated slot
                // starts the lifecycle after two occupied observations. Blank
                // baseline history, OCR, timing windows and perceptual-hash
                // identity cannot block the display, timeline event or popup.
                let physicalTransitionProof = evidence.startedFromStableBlank
                    && evidence.stableOccupiedCount >= 2
                    && evidence.physicalIdentityHash != nil
                // Build 689 fixes an unreachable non-OCR admission path. The pair
                // lane caps positive evidence at three, so the former >=5 test
                // could never succeed. The already-gated physical transition is
                // identity-specific proof and allows Image Relay penalties to
                // display without waiting for player-number OCR.
                let physicalAdmissionEnabled = RinkLensRiskFeaturePolicy.isEnabled(.penaltyPhysicalTransitionAdmissionV2)
                // Recovery DV deletes the unsafe no-baseline rollout. The 16:20
                // physical log proved that timer/player geometry can form a false
                // pair before the scoreboard has a real penalty. Only a recognised
                // player or a stable blank-to-occupied transition may now create a
                // semantic lifecycle; viewer imagery remains presentation evidence.
                let visiblePairTransitionProof = newlyConfirmedVisibilityKeys.contains(key)
                    && evidence.startedFromStableBlank
                    && relaySnapshotAtObservation.penaltySlotIsConfirmedOccupied(key)
                    && evidence.pairConfirmedAt != nil
                let identitySpecificStartProof = playerText != nil
                    || (physicalAdmissionEnabled && physicalTransitionProof)
                    || visiblePairTransitionProof
                let startAuthorised = evidence.stableOccupiedCount >= 2
                    && evidence.lifecycleAuthorised
                    && identitySpecificStartProof
                let identity: String
                let repeatedResolvedPlayerMatch =
                    evidence.resolvedPlayer == playerText
                    && evidence.retainedEvidenceCycles >= 2
                let strongPlayerMatch = evidence.stableOccupiedCount >= 2
                    && (evidence.confidence >= 0.78 || repeatedResolvedPlayerMatch)
                let physicalRebindEnabled = RinkLensRiskFeaturePolicy.isEnabled(.penaltyPhysicalIdentityRebindV2)
                if physicalRebindEnabled,
                   matchingPhysicalIdentities.count == 1,
                   let uniquePhysicalIdentity = matchingPhysicalIdentities.first,
                   previous[uniquePhysicalIdentity]?.slot != physicalSlot {
                    // Build 695: the calibrated player crop itself is the continuing
                    // identity authority during Slot 2 -> Slot 1 compaction. It must
                    // outrank the stale identity previously attached to Slot 1, even
                    // before OCR has resolved the player number in the new box.
                    identity = uniquePhysicalIdentity
                } else if strongPlayerMatch,
                   matchingPlayerIdentities.count == 1,
                   let uniquePlayerIdentity = matchingPlayerIdentities.first,
                   let existingBySlot,
                   uniquePlayerIdentity != existingBySlot.key {
                    // Build 676 restores atomic scoreboard compaction. When a
                    // strongly recognised player from Slot 2 appears in Slot 1,
                    // preserve that player's lifecycle instead of pinning the old
                    // Slot 1 identity to the physical box. This is the normal
                    // [45,87] -> [87,-] cancellation pattern after a power-play goal.
                    identity = uniquePlayerIdentity
                } else if let existingBySlot,
                          !claimedPreviousPenaltyIdentities.contains(existingBySlot.key) {
                    // Ordinary occupied physical-slot continuity still outranks a
                    // weak changed OCR number, preventing transient 45 -> 89 splits.
                    identity = existingBySlot.key
                } else if matchingPlayerIdentities.count == 1,
                          let uniquePlayerIdentity = matchingPlayerIdentities.first {
                    // Preserve a genuine Slot 2 -> Slot 1 handoff where the same
                    // player is observed in only one unclaimed previous lifecycle.
                    identity = uniquePlayerIdentity
                } else if let retained = imageRelayPenaltyLifecycleIDBySlot[slotKey],
                          previous[retained] != nil,
                          !claimedPreviousPenaltyIdentities.contains(retained) {
                    identity = retained
                } else if let physicalHash = evidence.physicalIdentityHash {
                    // Deterministic candidate identity avoids generating a new UUID
                    // on every un-authorised occupied observation after camera move.
                    identity = "\(team.rawValue)-slot\(physicalSlot)-physical-\(String(physicalHash, radix: 16))"
                } else {
                    identity = "\(team.rawValue)-slot\(physicalSlot)-candidate"
                }

                let lifecyclePlayer: String? = {
                    guard let oldPlayer = previous[identity]?.playerNumber else {
                        return playerText
                    }
                    guard let playerText else { return String(oldPlayer) }
                    if playerText == String(oldPlayer) { return playerText }
                    // Without a proven blank -> occupied transition, keep the
                    // lifecycle's established player. This prevents stale OCR from
                    // turning #45 into #89 while the same physical slot is active.
                    return evidence.startedFromStableBlank ? playerText : String(oldPlayer)
                }()

                claimedPreviousPenaltyIdentities.insert(identity)
                if previous[identity] != nil || startAuthorised || !imageRelayPenaltyBaselineReady {
                    imageRelayPenaltyLifecycleIDBySlot[slotKey] = identity
                }
                return .occupied(
                    identity: identity,
                    player: lifecyclePlayer,
                    physicalSlot: physicalSlot,
                    startAuthorised: startAuthorised,
                    physicalTransitionProof: physicalTransitionProof,
                    visiblePairTransitionProof: visiblePairTransitionProof
                )
            }
        }

        var current = previous
        var teamDiagnostics: [String] = []
        var observedIdentityByTeamSlot: [String: String] = [:]

        for team in Team.allCases {
            let slotPairs = keys(for: team)
            let slot1 = resolution(team: team, key: slotPairs[0].0, physicalSlot: 1)
            let slot2 = resolution(team: team, key: slotPairs[1].0, physicalSlot: 2)
            // Build 617 evaluates Home and Away independently. A team snapshot is
            // complete when both of that team's physical slots resolve as either a
            // player or a confirmed blank. Availability of the other team's crops,
            // represented by completeCycle, must not gate this team's lifecycle.
            let completeTeamSnapshot = slot1.isResolved && slot2.isResolved
            let signature = "s1=\(slot1.signatureValue)|s2=\(slot2.signatureValue)"
            let previousCandidate = imageRelayTeamPenaltySnapshotSignature[team]
            let previousLastObservedAt = imageRelayTeamPenaltySnapshotLastObservedAt[team]
            var evidenceAction: String

            if completeTeamSnapshot {
                let candidateStillFresh = previousLastObservedAt.map {
                    now - $0 <= imageRelayTeamPenaltyEvidenceWindow
                } ?? false
                if previousCandidate == signature && candidateStillFresh {
                    imageRelayTeamPenaltySnapshotCount[team, default: 0] += 1
                    evidenceAction = "advance-matching-complete"
                } else {
                    imageRelayTeamPenaltySnapshotSignature[team] = signature
                    imageRelayTeamPenaltySnapshotCount[team] = 1
                    imageRelayTeamPenaltySnapshotFirstObservedAt[team] = now
                    if previousCandidate == nil {
                        evidenceAction = "start-complete-candidate"
                    } else if previousCandidate == signature {
                        evidenceAction = "restart-expired-candidate"
                    } else {
                        evidenceAction = "reset-contradictory-complete"
                    }
                }
                imageRelayTeamPenaltySnapshotLastObservedAt[team] = now
            } else if let lastObservedAt = previousLastObservedAt,
                      now - lastObservedAt > imageRelayTeamPenaltyEvidenceWindow {
                // Unresolved observations do not contradict a candidate, but a very
                // old candidate must not accumulate evidence across unrelated play.
                imageRelayTeamPenaltySnapshotSignature[team] = nil
                imageRelayTeamPenaltySnapshotCount[team] = 0
                imageRelayTeamPenaltySnapshotFirstObservedAt[team] = nil
                imageRelayTeamPenaltySnapshotLastObservedAt[team] = nil
                evidenceAction = "expire-stale-candidate-during-unresolved"
            } else {
                // The important Build 617 rule: an unreadable crop pauses evidence.
                // It neither increments nor resets the matching complete count.
                evidenceAction = previousCandidate == nil
                    ? "unresolved-no-candidate"
                    : "pause-unresolved-retain-candidate"
            }
            let matchingCount = imageRelayTeamPenaltySnapshotCount[team] ?? 0
            let candidateAge = imageRelayTeamPenaltySnapshotFirstObservedAt[team].map {
                max(0, now - $0)
            }

            var observedByIdentity: [String: PenaltyClock] = [:]
            var startAuthorityByIdentity: [String: Bool] = [:]
            var physicalTransitionProofByIdentity: [String: Bool] = [:]
            var visiblePairTransitionProofByIdentity: [String: Bool] = [:]
            for resolved in [slot1, slot2] {
                guard case .occupied(
                    let identity,
                    let playerText,
                    let physicalSlot,
                    let startAuthorised,
                    let physicalTransitionProof,
                    let visiblePairTransitionProof
                ) = resolved
                else { continue }
                observedByIdentity[identity] = PenaltyClock(
                    team: team,
                    slot: physicalSlot,
                    playerNumber: playerText.flatMap { Int($0) },
                    rawClock: nil,
                    remainingSeconds: nil,
                    metadataPlayerPresent: true
                )
                observedIdentityByTeamSlot["\(team.rawValue)-\(physicalSlot)"] = identity
                startAuthorityByIdentity[identity] = startAuthorised
                physicalTransitionProofByIdentity[identity] = physicalTransitionProof
                visiblePairTransitionProofByIdentity[identity] = visiblePairTransitionProof
            }

            // Build 705: scoreboard compaction is a two-to-one physical transaction.
            // In the observed failure [slot1 #45, slot2 #21] became [slot1 #21,
            // slot2 blank], but ordinary slot continuity pinned #45 to slot1 before
            // the cross-slot matcher could act. Override that stale continuity only
            // when the new slot1 crop proves it is the prior slot2 identity by player
            // number or by the immutable physical crop hash.
            if RinkLensRiskFeaturePolicy.isEnabled(.atomicPenaltyCompactionV4),
               completeTeamSnapshot,
               case .occupied = slot1,
               case .confirmedBlank = slot2,
               let priorSlot1 = previous.first(where: {
                   $0.value.team == team && $0.value.slot == 1
               }),
               let priorSlot2 = previous.first(where: {
                   $0.value.team == team && $0.value.slot == 2
               }),
               let slot1Evidence = slotEvidence[slotPairs[0].0] {
                let candidatePlayer: Int? = {
                    let candidates: [String?] = [
                        slot1Evidence.confidence >= 0.62 ? slot1Evidence.rawCandidate : nil,
                        slot1Evidence.resolvedPlayer,
                        slot1Evidence.retainedPlayer
                    ]
                    for candidate in candidates {
                        if let candidate, let number = Int(candidate), (0...99).contains(number) {
                            return number
                        }
                    }
                    return nil
                }()
                let playerProvesMove = candidatePlayer != nil
                    && candidatePlayer == priorSlot2.value.playerNumber
                let physicalProvesMove: Bool = {
                    guard let hash = slot1Evidence.physicalIdentityHash else { return false }
                    return priorSlot2.key.hasSuffix("-physical-\(String(hash, radix: 16))")
                }()
                if playerProvesMove || physicalProvesMove {
                    let compactionTransactionID = UUID()
                    let staleSlot1ObservedIdentity = observedIdentityByTeamSlot["\(team.rawValue)-1"]
                    if let staleSlot1ObservedIdentity {
                        observedByIdentity.removeValue(forKey: staleSlot1ObservedIdentity)
                        startAuthorityByIdentity.removeValue(forKey: staleSlot1ObservedIdentity)
                        physicalTransitionProofByIdentity.removeValue(forKey: staleSlot1ObservedIdentity)
                        visiblePairTransitionProofByIdentity.removeValue(forKey: staleSlot1ObservedIdentity)
                    }
                    let movedClock = PenaltyClock(
                        team: team,
                        slot: 1,
                        playerNumber: candidatePlayer ?? priorSlot2.value.playerNumber,
                        rawClock: priorSlot2.value.rawClock,
                        remainingSeconds: priorSlot2.value.remainingSeconds,
                        metadataPlayerPresent: true
                    )
                    observedByIdentity[priorSlot2.key] = movedClock
                    observedIdentityByTeamSlot["\(team.rawValue)-1"] = priorSlot2.key
                    startAuthorityByIdentity[priorSlot2.key] = true
                    physicalTransitionProofByIdentity[priorSlot2.key] = true
                    visiblePairTransitionProofByIdentity[priorSlot2.key] = true
                    evidenceAction += "+verified-two-to-one-evidence-resolved-\(priorSlot1.key)-to-\(priorSlot2.key)-2to1"
                    RinkLensStructuredEventLogger.shared.record(
                        domain: .penalty,
                        event: "penalty_two_to_one_evidence_resolved",
                        entityID: priorSlot2.key,
                        previous: [
                            "slot1": priorSlot1.key,
                            "slot2": priorSlot2.key
                        ],
                        next: [
                            "slot1": priorSlot2.key,
                            "slot2": "blank",
                            "proof": playerProvesMove ? "player-number" : "physical-hash"
                        ],
                        source: "HockeyScoreboardViewModel.imageRelayPenaltyReconciliation",
                        reason: "Current Slot 1 resolves to the former Slot 2 identity; the atomic owner transaction commits below",
                        captureGeneration: captureGeneration,
                        transactionID: compactionTransactionID,
                        authoritativeOwner: "RinkLensMatchStateReducer"
                    )
                }
            }

            let newLifecycleStartWindowOpen = imageRelayEventWindowIsOpen
                || imageRelayMetadataClockRunning != true
            func mayEnterLifecycle(_ identity: String) -> Bool {
                if penaltyLifecycleStore.shouldSuppressPowerPlayCancelledReentry(
                    identity: identity,
                    stoppageID: imageRelayCurrentStoppageID,
                    captureGeneration: captureGeneration,
                    source: "HockeyScoreboardViewModel.imageRelayPenaltyReconciliation"
                ) {
                    return false
                }
                if previous[identity] != nil || !imageRelayPenaltyBaselineReady { return true }
                // Build 687 combines the Build 681 transaction guard with the older
                // physical blank->occupied authority. A new lifecycle still needs a
                // complete repeated player+timer snapshot, but a proven physical
                // transition may admit it when Clock movement evidence is unavailable/stale.
                // One-off artefacts, startup occupancy and unresolved slots remain blocked.
                let physicalFallback = physicalTransitionProofByIdentity[identity] == true
                let visiblePairFallback = visiblePairTransitionProofByIdentity[identity] == true
                let startAuthorised = startAuthorityByIdentity[identity] == true
                if RinkLensRiskFeaturePolicy.isEnabled(.penaltyConfirmedPairImmediateLifecycleV2),
                   startAuthorised,
                   (physicalFallback || visiblePairFallback) {
                    // A confirmed player/timer pair plus either blank-to-occupied
                    // proof or a viewer-authority hidden-to-visible transition is
                    // already one atomic physical proof. OCR and an unresolved
                    // sibling slot must not delay this lifecycle.
                    return true
                }
                return startAuthorised
                    && completeTeamSnapshot
                    && matchingCount >= 3
                    && (newLifecycleStartWindowOpen || physicalFallback)
            }

            // Positive identities are safe to merge even when the other slot is
            // unresolved. Slot 2 is a first-class physical lane and never waits for
            // Slot 1 OCR/identity resolution.
            for (identity, clock) in observedByIdentity {
                let lifecycleMayStart = mayEnterLifecycle(identity)
                if lifecycleMayStart {
                    current[identity] = clock
                } else {
                    evidenceAction += "+new-identity-awaiting-transactional-or-physical-proof"
                }
            }

            // Build 627 independent clear/expiry proof. Three consecutive physical
            // blank observations end the identity previously bound to that slot even
            // when the team's other slot is unresolved. A continuing identity seen in
            // the other slot is preserved as a rebind rather than falsely removed.
            if !resumeProtected {
                let observedKeys = Set(observedByIdentity.keys)
                for (key, physicalSlot) in slotPairs {
                    guard let evidence = slotEvidence[key],
                        case .confirmedBlank = evidence.occupancy,
                        evidence.stableBlankCount >= imageRelayPenaltyBlankRemovalFrames
                    else { continue }
                    for (identity, clock) in previous
                    where clock.team == team && clock.slot == physicalSlot
                        && !observedKeys.contains(identity)
                    {
                        current[identity] = nil
                        imageRelayPenaltyLifecycleIDBySlot[key] = nil
                        evidenceAction += "+slot\(physicalSlot)-stable-blank-clear"
                    }
                }
            }

            if RinkLensRiskFeaturePolicy.isEnabled(.atomicPenaltyCompactionV4),
               completeTeamSnapshot {
                // Build 706 single default compaction path. The candidate identity,
                // displaced identity and physical slot binding are changed together
                // before any metadata, MatchState or popup projection is published.
                for (identity, newClock) in observedByIdentity {
                    guard let oldClock = previous[identity],
                          oldClock.team == team,
                          oldClock.slot != newClock.slot else { continue }
                    let displaced = previous.first { candidate in
                        candidate.value.team == team
                            && candidate.value.slot == newClock.slot
                            && candidate.key != identity
                    }
                    let displacedStillObserved = displaced.map { observedByIdentity[$0.key] != nil } ?? false
                    guard !displacedStillObserved else { continue }

                    let transactionID = UUID()
                    let before = current
                        .filter { $0.value.team == team }
                        .map { "\($0.key)@\($0.value.slot)" }
                        .sorted()
                        .joined(separator: ",")
                    if let displaced { current[displaced.key] = nil }
                    current[identity] = newClock
                    imageRelayPenaltyLifecycleIDBySlot[slotPairs[newClock.slot - 1].0] = identity
                    let vacatedSlot = oldClock.slot
                    if (1...slotPairs.count).contains(vacatedSlot),
                       imageRelayPenaltyLifecycleIDBySlot[slotPairs[vacatedSlot - 1].0] == identity {
                        imageRelayPenaltyLifecycleIDBySlot[slotPairs[vacatedSlot - 1].0] = nil
                    }
                    evidenceAction += "+build706-owner-transaction-\(identity)-\(oldClock.slot)to\(newClock.slot)"
                    let after = current
                        .filter { $0.value.team == team }
                        .map { "\($0.key)@\($0.value.slot)" }
                        .sorted()
                        .joined(separator: ",")
                    RinkLensStructuredEventLogger.shared.record(
                        domain: .penalty,
                        event: "penalty_atomic_owner_transaction",
                        entityID: identity,
                        previous: [
                            "teamState": before,
                            "slot": String(oldClock.slot),
                            "displaced": displaced?.key ?? "none"
                        ],
                        next: [
                            "teamState": after,
                            "slot": String(newClock.slot),
                            "displaced": "removed",
                            "publication": "deferred-until-transaction-complete"
                        ],
                        source: "HockeyScoreboardViewModel.imageRelayPenaltyReconciliation",
                        reason: "One verified continuing physical identity moved slots and atomically displaced the expired occupant",
                        captureGeneration: captureGeneration,
                        transactionID: transactionID,
                        authoritativeOwner: "RinkLensMatchStateReducer"
                    )
                }
            }

            if !RinkLensRiskFeaturePolicy.isEnabled(.atomicPenaltyCompactionV4),
               RinkLensRiskFeaturePolicy.isEnabled(.penaltyPhysicalIdentityRebindV2),
               completeTeamSnapshot {
                // Build 695 performs the physical handoff as one transaction. A
                // continuing identity moves to its newly observed slot and the
                // displaced, no-longer-observed identity is removed before metadata,
                // manpower, events or popup state are published.
                for (identity, newClock) in observedByIdentity {
                    guard let oldClock = previous[identity],
                          oldClock.team == team,
                          oldClock.slot != newClock.slot else { continue }
                    let displaced = previous.first { candidate in
                        candidate.value.team == team
                            && candidate.value.slot == newClock.slot
                            && candidate.key != identity
                    }
                    let displacedStillObserved = displaced.map { observedByIdentity[$0.key] != nil } ?? false
                    guard !displacedStillObserved else { continue }

                    let before = current
                        .filter { $0.value.team == team }
                        .map { "\($0.key)@\($0.value.slot)" }
                        .sorted()
                        .joined(separator: ",")
                    if let displaced { current[displaced.key] = nil }
                    current[identity] = newClock
                    imageRelayPenaltyLifecycleIDBySlot[slotPairs[newClock.slot - 1].0] = identity
                    evidenceAction += "+physical-identity-atomic-rebind-\(identity)-\(oldClock.slot)to\(newClock.slot)"
                    let after = current
                        .filter { $0.value.team == team }
                        .map { "\($0.key)@\($0.value.slot)" }
                        .sorted()
                        .joined(separator: ",")
                    RinkLensStructuredEventLogger.shared.record(
                        domain: .penalty,
                        event: "penalty_physical_identity_rebound",
                        entityID: identity,
                        previous: [
                            "teamState": before,
                            "slot": String(oldClock.slot),
                            "displaced": displaced?.key ?? "none"
                        ],
                        next: [
                            "teamState": after,
                            "slot": String(newClock.slot),
                            "displaced": "removed"
                        ],
                        source: "HockeyScoreboardViewModel.imageRelayPenaltyReconciliation",
                        reason: "Unique stable physical hash moved across calibrated slots in a complete team snapshot",
                        captureGeneration: captureGeneration
                    )
                }
            }

            if !RinkLensRiskFeaturePolicy.isEnabled(.atomicPenaltyCompactionV4),
               completeTeamSnapshot {
                // Legacy Build 704 comparison path retained only while the Build 706
                // atomic compaction feature is deliberately disabled.
                // A continuing player observed in the other slot must move atomically
                // even when only one strong identity match remains after the old slot
                // becomes blank. This covers slot2 player 21 replacing expired slot1
                // player 45 without publishing a transient duplicate or stale owner.
                for (identity, newClock) in observedByIdentity {
                    guard let oldClock = previous[identity],
                          oldClock.team == team,
                          oldClock.slot != newClock.slot else { continue }
                    let displaced = previous.first { candidate in
                        candidate.value.team == team
                            && candidate.value.slot == newClock.slot
                            && candidate.key != identity
                    }
                    let displacedStillObserved = displaced.map { observedByIdentity[$0.key] != nil } ?? false
                    guard !displacedStillObserved else { continue }
                    if let displaced { current[displaced.key] = nil }
                    current[identity] = newClock
                    imageRelayPenaltyLifecycleIDBySlot[slotPairs[newClock.slot - 1].0] = identity
                    evidenceAction += "+build704-single-match-atomic-compaction-\(identity)-\(oldClock.slot)to\(newClock.slot)"
                }

                // Rebind continuing identities to their observed physical slots and
                // allow new identities. Missing players remain until a third complete
                // snapshot proves absence from both slots.
                for (identity, clock) in observedByIdentity {
                    if mayEnterLifecycle(identity) { current[identity] = clock }
                }
                // Build 676 permits only one occupied-to-occupied replacement:
                // a strongly matched existing lifecycle compacting from the other
                // physical slot. The displaced earlier-slot identity is then the
                // penalty that actually ended. All other number changes remain held.
                for (newIdentity, newClock) in observedByIdentity {
                    guard let old = previous.first(where: {
                        $0.value.team == team && $0.value.slot == newClock.slot
                    }), old.key != newIdentity else { continue }
                    let isExistingCrossSlotIdentity = previous[newIdentity]?.team == team
                        && previous[newIdentity]?.slot != newClock.slot
                    let displacedIdentityStillObserved = observedByIdentity[old.key] != nil
                    if isExistingCrossSlotIdentity && !displacedIdentityStillObserved {
                        current[old.key] = nil
                        current[newIdentity] = newClock
                        evidenceAction += "+atomic-slot-compaction-removed-\(old.key)-kept-\(newIdentity)"
                    } else {
                        evidenceAction += "+slot\(newClock.slot)-occupied-change-retained-no-split"
                    }
                }
            }

            let candidateAgeText = candidateAge.map { String(format: "%.1fs", $0) } ?? "--"
            teamDiagnostics.append(
                "\(team.rawValue){\(signature) teamComplete=\(completeTeamSnapshot) sourceComplete=\(completeCycle) matches=\(matchingCount) action=\(evidenceAction) candidate=\(imageRelayTeamPenaltySnapshotSignature[team] ?? "none") age=\(candidateAgeText) observed=\(observedByIdentity.keys.sorted().joined(separator: ","))}"
            )
        }

        // Build 681 enforces one logical owner for each physical visual slot.
        // Compaction can temporarily leave the prior Slot 1 identity and the
        // continuing Slot 2 identity both mapped to Slot 1. Prefer the identity
        // observed in the current complete crop, then the canonical slot binding,
        // and remove every other logical occupant before events/manpower publish.
        var duplicateSlotSuppressions: [String] = []
        for team in Team.allCases {
            for physicalSlot in [1, 2] {
                let occupants = current.filter {
                    $0.value.team == team && $0.value.slot == physicalSlot
                }
                guard occupants.count > 1 else { continue }
                let slotMapKey = "\(team.rawValue)-\(physicalSlot)"
                let regionKey: OCRRegionKey = {
                    switch (team, physicalSlot) {
                    case (.home, 1): return .homePenalty1Player
                    case (.home, _): return .homePenalty2Player
                    case (.away, 1): return .awayPenalty1Player
                    case (.away, _): return .awayPenalty2Player
                    }
                }()
                let preferredIdentity = observedIdentityByTeamSlot[slotMapKey].flatMap {
                    current[$0] == nil ? nil : $0
                } ?? imageRelayPenaltyLifecycleIDBySlot[regionKey].flatMap {
                    current[$0] == nil ? nil : $0
                }
                    ?? occupants.keys.sorted().first
                guard let preferredIdentity else { continue }
                for identity in occupants.keys where identity != preferredIdentity {
                    current[identity] = nil
                    duplicateSlotSuppressions.append(
                        "\(team.rawValue)-slot\(physicalSlot):removed=\(identity):kept=\(preferredIdentity)"
                    )
                }
                imageRelayPenaltyLifecycleIDBySlot[regionKey] = preferredIdentity
            }
        }
        if !duplicateSlotSuppressions.isEmpty {
            RinkLensOCREvidenceJournal.shared.recordEventAudit(
                stage: "image_relay_duplicate_visual_slot_owner_suppressed",
                eventKind: "penalty_state",
                source: "image-relay",
                detail: duplicateSlotSuppressions.joined(separator: ";")
            )
        }

        if !imageRelayPenaltyBaselineReady {
            if imageRelayPenaltyBaselineStartedAt == nil {
                imageRelayPenaltyBaselineStartedAt = observedAt
            }
            imageRelayActivePenaltyByIdentity = current
            imageRelayPenaltyResumeKnownIdentities = Set(current.keys)
            publishImageRelayPenaltyMetadata()
            let baselineAge = observedAt - (imageRelayPenaltyBaselineStartedAt ?? observedAt)
            if baselineAge >= imageRelayPenaltyStartupBaselineSeconds {
                imageRelayPenaltyBaselineReady = true
            }
            recordImageRelayPenaltyReconciliation(
                slotValues: values,
                slotEvidence: slotEvidence,
                previous: [:],
                current: current,
                added: [],
                removed: [],
                popupDecision:
                    "startup-baseline-no-events age=\(String(format: "%.2f", baselineAge)) ready=\(imageRelayPenaltyBaselineReady) generation=\(captureGeneration) complete=\(completeCycle) teams=[\(teamDiagnostics.joined(separator: ";"))]"
            )
            return
        }

        // Route/generation recovery cannot close a pre-existing lifecycle. Fresh
        // positive evidence may still rebind or add players without duplicate starts.
        if resumeProtected {
            for identity in imageRelayPenaltyResumeKnownIdentities {
                if current[identity] == nil, let retained = previous[identity] {
                    current[identity] = retained
                }
            }
        }

        let addedPairs = current.filter { previous[$0.key] == nil }
        let removedPairs = previous.filter { current[$0.key] == nil }
        let added = Array(addedPairs.values)
        let removed = Array(removedPairs.values)

        for (identity, clock) in removedPairs {
            penaltyLifecycleStore.recordPhysicalRemoval(
                identity: identity,
                clock: clock,
                activeTeamClocksBeforeRemoval: previous.filter { $0.value.team == clock.team },
                stoppageID: imageRelayCurrentStoppageID,
                observedAt: observedAt,
                source: "HockeyScoreboardViewModel.imageRelayPenaltyReconciliation",
                reason: "Complete physical player/timer evidence removed this lifecycle before score-event classification"
            )
            if RinkLensRiskFeaturePolicy.isEnabled(.latePowerPlayRemovalBindingV19) {
                var cancellationIdentity = identity
                var cancellationClock = clock
                var continuingCompactionClock: PenaltyClock?
                if RinkLensRiskFeaturePolicy.isEnabled(.atomicPowerPlayCompactionSnapshotV24),
                   clock.slot > 1 {
                    let preRemovalTeam = previous
                        .filter { $0.value.team == clock.team && $0.value.isActive }
                        .sorted { lhs, rhs in
                            if lhs.value.slot != rhs.value.slot { return lhs.value.slot < rhs.value.slot }
                            return lhs.key < rhs.key
                        }
                    if preRemovalTeam.count >= 2,
                       let oldest = preRemovalTeam.first,
                       oldest.key != identity {
                        cancellationIdentity = oldest.key
                        cancellationClock = oldest.value
                        var continuing = clock
                        continuing.slot = 1
                        continuingCompactionClock = continuing
                    }
                }

                let boundGoalID = matchEventJournal.bindLatePhysicalPenaltyRemovalToPowerPlayGoal(
                    identity: cancellationIdentity,
                    clock: cancellationClock,
                    observedAt: observedAt,
                    source: "HockeyScoreboardViewModel.imageRelayPenaltyReconciliation",
                    reason: continuingCompactionClock == nil
                        ? "Physical removal arrived immediately after the power-play goal; bind it to the canonical existing event"
                        : "Late two-penalty compaction proves the oldest Slot 1 minor ended while the disappearing Slot 2 lifecycle continues in Slot 1"
                )
                if boundGoalID != nil, let stoppageID = imageRelayCurrentStoppageID {
                    penaltyLifecycleStore.recordPowerPlayCancellation(
                        identity: cancellationIdentity,
                        stoppageID: stoppageID,
                        observedAt: observedAt,
                        source: "HockeyScoreboardViewModel.imageRelayPenaltyReconciliation",
                        reason: continuingCompactionClock == nil
                            ? "Late physical removal was correlated to the canonical power-play goal"
                            : "Late physical Slot 2 disappearance reinterpreted from immutable pre-removal evidence as oldest Slot 1 cancellation"
                    )
                    if let continuingCompactionClock {
                        current[cancellationIdentity] = nil
                        current[identity] = continuingCompactionClock
                        if let destination = penaltyRegionPair(team: continuingCompactionClock.team, slot: 1) {
                            imageRelayPenaltyLifecycleIDBySlot[destination.player] = identity
                        }
                        if let sourcePair = penaltyRegionPair(team: continuingCompactionClock.team, slot: 2) {
                            imageRelayPenaltyLifecycleIDBySlot[sourcePair.player] = nil
                        }
                        ScoreboardImageRelayStore.shared.compactConfirmedPenaltySlot2ToSlot1(
                            team: continuingCompactionClock.team,
                            sourceSequence: imageRelayLastAcceptedSourceSequence,
                            captureGeneration: captureGeneration,
                            reason: "Late power-play removal served \(cancellationIdentity); continuing \(identity) moved from Slot 2 to Slot 1"
                        )
                        RinkLensStructuredEventLogger.shared.record(
                            domain: .penalty,
                            event: "late_power_play_penalty_compaction_committed",
                            entityID: identity,
                            previous: [
                                "removedPhysicalIdentity": identity,
                                "removedPhysicalSlot": String(clock.slot),
                                "servedIdentity": cancellationIdentity,
                                "servedSlot": String(cancellationClock.slot)
                            ],
                            next: [
                                "continuingIdentity": identity,
                                "continuingSlot": "1",
                                "boundGoalID": boundGoalID?.uuidString ?? "none"
                            ],
                            source: "HockeyScoreboardViewModel.imageRelayPenaltyReconciliation",
                            reason: "The physical clear arrived after the goal event, so the penalty lifecycle owner used the pre-removal two-slot snapshot instead of cancelling the disappearing Slot 2 player",
                            captureGeneration: captureGeneration,
                            stoppageID: stoppageID,
                            authoritativeOwner: "RinkLensPenaltyLifecycleStore"
                        )
                    }
                }
            }
        }

        imageRelayActivePenaltyByIdentity = current
        publishImageRelayPenaltyMetadata()

        // The popup is queued from physical occupancy first. OCR runs afterwards
        // and may enrich the pending event with a player number and, for Home, a
        // roster name. It never delays or suppresses the live Image Relay player.
        for (identity, clock) in current {
            let player = clock.playerNumber
            let rosterName: String? = {
                guard clock.team == .home,
                      let player,
                      let rosterPlayer = SponsorCatalogueStore.shared.homeRosterPlayer(number: player) else {
                    return nil
                }
                let clean = rosterPlayer.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return clean.isEmpty ? nil : clean
            }()
            for index in imageRelayPendingEvents.indices
            where imageRelayPendingEvents[index].event.penaltyLifecycleID == identity {
                let previousPlayer = imageRelayPendingEvents[index].event.recognisedPenaltyPlayerNumber
                let previousPopupSource = imageRelayPendingEvents[index].event.penaltyPopupPlayerSource
                if let player {
                    imageRelayPendingEvents[index].event.recognisedPenaltyPlayerNumber = player
                    for clockIndex in imageRelayPendingEvents[index].event.penaltyClockSnapshot.indices
                    where imageRelayPendingEvents[index].event.penaltyClockSnapshot[clockIndex].team == clock.team
                        && imageRelayPendingEvents[index].event.penaltyClockSnapshot[clockIndex].slot == clock.slot {
                        imageRelayPendingEvents[index].event.penaltyClockSnapshot[clockIndex].playerNumber = player
                    }
                }
                imageRelayPendingEvents[index].event.recognisedHomePlayerName = rosterName
                imageRelayPendingEvents[index].event.penaltyPopupPlayerSource = {
                    if clock.team == .away { return "guest-image-relay" }
                    if rosterName != nil { return "home-roster-match" }
                    return player == nil ? "home-image-relay-fallback" : "penalty-player-ocr"
                }()
                imageRelayPendingEvents[index].event.headlineOverride = "PLAYER"
                if player != nil || clock.team == .away {
                    var enrichedEvent = imageRelayPendingEvents[index].event
                    enrichedEvent.sponsor = SponsorCatalogueStore.shared.resolvedPenaltySponsor(for: enrichedEvent)
                    imageRelayPendingEvents[index].event = enrichedEvent
                }
                if previousPlayer == nil, let player {
                    RinkLensStructuredEventLogger.shared.record(
                        domain: .penalty,
                        event: "penalty_identity_enriched_after_physical_lifecycle",
                        entityID: identity,
                        previous: [
                            "playerNumber": "none",
                            "popupSource": previousPopupSource ?? "none"
                        ],
                        next: [
                            "playerNumber": String(player),
                            "rosterName": rosterName ?? "none",
                            "popupSource": imageRelayPendingEvents[index].event.penaltyPopupPlayerSource ?? "none"
                        ],
                        source: "HockeyScoreboardViewModel.imageRelayPenaltyReconciliation",
                        reason: "OCR enriched an already-created physical penalty lifecycle; identity recognition did not control event admission",
                        captureGeneration: captureGeneration,
                        stoppageID: imageRelayPendingEvents[index].event.stoppageID
                    )
                }
            }
        }

        let eventBaselineReady = imageRelayScoreBaselineReady && imageRelayMetadataPeriod != nil
        if RinkLensRiskFeaturePolicy.isEnabled(.matchEventBaselineAlignmentV18),
           !eventBaselineReady,
           !addedPairs.isEmpty {
            RinkLensStructuredEventLogger.shared.record(
                domain: .gameEvent,
                event: "penalty_popup_admission_suppressed_before_match_baseline",
                entityID: "generation-\(captureGeneration)",
                previous: [
                    "period": imageRelayMetadataPeriod.map { String($0) } ?? "unknown",
                    "scoreBaselineReady": String(imageRelayScoreBaselineReady),
                    "activePenaltyCount": String(previous.count)
                ],
                next: [
                    "physicalPenaltyCount": String(current.count),
                    "newPhysicalPairs": addedPairs.keys.sorted().joined(separator: ","),
                    "popupEventsCreated": "0"
                ],
                source: "HockeyScoreboardViewModel.imageRelayPenaltyReconciliation",
                reason: "Physical penalty presentation remains visible, but no timeline/popup lifecycle is admitted until Period and score baselines are authoritative",
                captureGeneration: captureGeneration,
                stoppageID: imageRelayCurrentStoppageID,
                authoritativeOwner: "RinkLensGameEventLifecycleStore"
            )
            recordImageRelayPenaltyReconciliation(
                slotValues: values,
                slotEvidence: slotEvidence,
                previous: previous,
                current: current,
                added: added,
                removed: removed,
                popupDecision: "baseline-gate-suppressed-period-or-score-unready"
            )
            return
        }

        var popupDecisions: [String] = []

        for (identity, clock) in addedPairs.sorted(by: {
            if $0.value.team != $1.value.team { return $0.value.team.rawValue < $1.value.team.rawValue }
            return $0.value.slot < $1.value.slot
        }) {
            let player = clock.playerNumber
            let playerRegion: OCRRegionKey = {
                switch (clock.team, clock.slot) {
                case (.home, 1): return .homePenalty1Player
                case (.home, _): return .homePenalty2Player
                case (.away, 1): return .awayPenalty1Player
                case (.away, _): return .awayPenalty2Player
                }
            }()
            let relaySnapshot = ScoreboardImageRelayStore.shared.snapshot()
            let frozenPlayerImageData: Data? = {
                guard relaySnapshot.penaltySlotIsConfirmedOccupied(playerRegion),
                      let image = relaySnapshot.image(for: playerRegion) else { return nil }
                return UIImage(cgImage: image).pngData()
            }()
            let rosterPlayer = clock.team == .home
                ? player.flatMap { SponsorCatalogueStore.shared.homeRosterPlayer(number: $0) }
                : nil
            let rosterName = rosterPlayer?.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let validRosterName = (rosterName?.isEmpty == false) ? rosterName : nil
            let popupPlayerSource: String = {
                if clock.team == .away { return "guest-image-relay" }
                if clock.team == .home, rosterPlayer != nil { return "home-roster-match" }
                return player == nil ? "home-image-relay-fallback" : "penalty-player-ocr"
            }()
            if RinkLensRiskFeaturePolicy.isEnabled(.eventLatencyLoggingV2),
               let evidence = slotEvidence[playerRegion] {
                let candidateToMetadataMS = evidence.pairCandidateStartedAt.map {
                    max(0, (observedAt - $0) * 1_000)
                }
                let confirmationToMetadataMS = evidence.pairConfirmedAt.map {
                    max(0, (observedAt - $0) * 1_000)
                }
                RinkLensStructuredEventLogger.shared.record(
                    domain: .penalty,
                    event: "penalty_event_latency_checkpoint",
                    entityID: identity,
                    previous: [
                        "candidateStartedAt": evidence.pairCandidateStartedAt.map { String(format: "%.3f", $0) } ?? "unknown",
                        "pairConfirmedAt": evidence.pairConfirmedAt.map { String(format: "%.3f", $0) } ?? "unknown"
                    ],
                    next: [
                        "metadataObservedAt": String(format: "%.3f", observedAt),
                        "candidateToMetadataMs": candidateToMetadataMS.map { String(format: "%.1f", $0) } ?? "unknown",
                        "confirmationToMetadataMs": confirmationToMetadataMS.map { String(format: "%.1f", $0) } ?? "unknown"
                    ],
                    source: "HockeyScoreboardViewModel.imageRelayPenaltyReconciliation",
                    reason: "Physical pair evidence reached the single penalty lifecycle owner",
                    captureGeneration: captureGeneration,
                    stoppageID: imageRelayCurrentStoppageID
                )
            }
            if player == nil, newlyConfirmedVisibilityKeys.contains(playerRegion) {
                RinkLensStructuredEventLogger.shared.record(
                    domain: .penalty,
                    event: "penalty_lifecycle_created_from_visible_physical_pair",
                    entityID: identity,
                    previous: [
                        "visiblePenalty": "false",
                        "playerIdentity": "unresolved",
                        "blankBaselineProof": slotEvidence[playerRegion]?.startedFromStableBlank == true ? "true" : "false"
                    ],
                    next: [
                        "visiblePenalty": "true",
                        "playerIdentity": "pending-ocr-enrichment",
                        "slot": String(clock.slot),
                        "team": clock.team.rawValue
                    ],
                    source: "HockeyScoreboardViewModel.imageRelayPenaltyReconciliation",
                    reason: "Viewer-authority hidden-to-visible player/timer transition created the lifecycle before player-number OCR",
                    captureGeneration: captureGeneration,
                    stoppageID: imageRelayCurrentStoppageID
                )
            }
            var event = BroadcastEvent(
                type: .penalty,
                team: clock.team,
                period: imageRelayMetadataPeriod,
                gameClock: nil,
                homeScoreAfter: imageRelayMetadataHomeScore,
                awayScoreAfter: imageRelayMetadataAwayScore,
                strengthState: imageRelayMetadataStrengthState,
                source: .ocr,
                operatorConfirmed: false,
                penaltyClockSnapshot: imageRelayMetadataPenaltyClocks,
                headlineOverride: "PLAYER",
                detailOverride: imageRelayMetadataStrengthState.scorebugManpowerText,
                penaltyLifecycleID: identity,
                captureGeneration: captureGeneration
            )
            // Build 643 freezes the stable physical player glyph at lifecycle
            // creation. Guest popups intentionally use this image; Home can enrich
            // it with OCR/roster metadata without delaying popup creation.
            event.frozenPenaltyPlayerImagePNGData = frozenPlayerImageData
            event.recognisedPenaltyPlayerNumber = player
            event.recognisedHomePlayerName = validRosterName
            event.penaltyPopupPlayerSource = popupPlayerSource
            // Build 676 freezes the resolved sponsor alongside the physical
            // player identity. A later team-profile/roster change cannot make a
            // #21 event display another player's sponsor or name.
            event.sponsor = (player != nil || clock.team == .away)
                ? SponsorCatalogueStore.shared.resolvedPenaltySponsor(for: event)
                : nil
            RinkLensOCREvidenceJournal.shared.recordEventAudit(
                stage: "penalty_popup_player_image_frozen",
                eventKind: "penalty",
                source: "imageRelay",
                detail: "identity=\(identity) region=\(playerRegion.rawValue) image=\(frozenPlayerImageData == nil ? "missing" : "saved") popupSource=\(popupPlayerSource) rosterName=\(rosterPlayer?.name ?? "none")"
            )
            if imageRelayEventWindowIsOpen {
                attachImageRelayStoppageContext(to: &event, observedAt: observedAt)
                event.popupLifecycleState = "pending-restart-delay"
                queueImageRelayMetadataEvent(event, priority: 1, observedAt: observedAt)
                popupDecisions.append("\(identity)-event-recorded-popup-queued")
            } else if imageRelayMetadataClockRunning != true
                        || (RinkLensRiskFeaturePolicy.isEnabled(.penaltyStopCandidateAttributionV3)
                            && imageRelayStopCandidateInProgress) {
                // Physical penalties often stabilise during the 2.1-second Clock
                // stop-confirmation interval. Build 703 also trusts the physical
                // stop candidate over late "running" metadata, retaining the event
                // for atomic binding when the stoppage owner commits its identity.
                attachImageRelayObservationContext(
                    to: &event,
                    observedAt: observedAt,
                    captureGeneration: captureGeneration,
                    popupState: "awaiting-stoppage-confirmation"
                )
                queueImageRelayMetadataEvent(event, priority: 1, observedAt: observedAt)
                popupDecisions.append("\(identity)-event-deferred-awaiting-stoppage")
                if RinkLensRiskFeaturePolicy.isEnabled(.penaltyStopCandidateAttributionV3) {
                    RinkLensStructuredEventLogger.shared.record(
                        domain: .gameEvent,
                        event: "penalty_bound_to_pending_physical_stop",
                        entityID: identity,
                        previous: [
                            "clockMetadataRunning": imageRelayMetadataClockRunning.map { String($0) } ?? "unknown",
                            "stoppageID": "none",
                            "popupState": "ineligible-clock-running"
                        ],
                        next: [
                            "stopCandidate": imageRelayStopCandidateInProgress ? "true" : "false",
                            "popupState": "awaiting-stoppage-confirmation"
                        ],
                        source: "HockeyScoreboardViewModel.imageRelayPenaltyReconciliation",
                        reason: "Physical player/timer pair was confirmed while the Clock stop candidate was active; late metadata cannot discard the event",
                        captureGeneration: captureGeneration
                    )
                }
            } else if RinkLensRiskFeaturePolicy.isEnabled(.penaltyConfirmedPairLateRestartAttributionV2),
                      let restartStoppageID = imageRelayLastCredibleRestartStoppageID,
                      let restartDeadline = imageRelayLastCredibleRestartReleaseDeadline,
                      observedAt <= restartDeadline + imageRelayLateEventGraceSeconds {
                attachImageRelayObservationContext(
                    to: &event,
                    observedAt: observedAt,
                    captureGeneration: captureGeneration,
                    popupState: "late-pair-bound-to-verified-restart"
                )
                event.stoppageID = restartStoppageID
                event.popupLifecycleState = "pending-restart-delay"
                queueImageRelayMetadataEvent(event, priority: 1, observedAt: observedAt)
                popupDecisions.append("\(identity)-late-pair-bound-to-last-restart")
                RinkLensStructuredEventLogger.shared.record(
                    domain: .gameEvent,
                    event: "penalty_late_pair_attributed_to_verified_restart",
                    entityID: identity,
                    previous: [
                        "stoppageID": "none",
                        "popupState": "ineligible-clock-running"
                    ],
                    next: [
                        "stoppageID": restartStoppageID.uuidString,
                        "popupState": "pending-restart-delay"
                    ],
                    source: "HockeyScoreboardViewModel.imageRelayPenaltyReconciliation",
                    reason: "Strong physical penalty pair confirmed within bounded grace after verified restart",
                    captureGeneration: captureGeneration,
                    stoppageID: restartStoppageID
                )
            } else if RinkLensRiskFeaturePolicy.isEnabled(.latePhysicalPenaltyPopupRecoveryV11),
                      let evidence = slotEvidence[playerRegion],
                      evidence.startedFromStableBlank,
                      let pairConfirmedAt = evidence.pairConfirmedAt,
                      observedAt >= pairConfirmedAt,
                      observedAt - pairConfirmedAt <= 20.0,
                      relaySnapshot.penaltySlotIsConfirmedOccupied(playerRegion) {
                // Build 723: the physical pair existed before identity enrichment,
                // but the Clock had already restarted by the time the player number
                // reached the lifecycle owner. A clean blank-to-occupied transition
                // plus a recent confirmed pair is sufficient to release exactly this
                // one lifecycle now. The event is not attached to a fabricated stop,
                // and addedPairs guarantees it cannot repeat on unchanged frames.
                attachImageRelayObservationContext(
                    to: &event,
                    observedAt: observedAt,
                    captureGeneration: captureGeneration,
                    popupState: "late-physical-pair-recovered"
                )
                recordTimelineEventIfNeeded(
                    event,
                    lifecycleState: "penalty-start-confirmed",
                    popupState: "late-physical-pair-recovered"
                )
                enqueueBanner(
                    event,
                    releaseReason: "late physical penalty pair recovered after identity enrichment"
                )
                popupDecisions.append("\(identity)-late-physical-pair-popup-recovered")
                RinkLensStructuredEventLogger.shared.record(
                    domain: .gameEvent,
                    event: "penalty_popup_recovered_from_recent_physical_pair",
                    entityID: identity,
                    previous: [
                        "popupState": "ineligible-clock-running",
                        "pairConfirmedAt": String(format: "%.3f", pairConfirmedAt)
                    ],
                    next: [
                        "popupState": "late-physical-pair-recovered",
                        "latencyMs": String(format: "%.1f", (observedAt - pairConfirmedAt) * 1_000)
                    ],
                    source: "HockeyScoreboardViewModel.imageRelayPenaltyReconciliation",
                    reason: "The physical pair started from a clean blank and remained visible; identity enrichment was late but no second lifecycle was created",
                    captureGeneration: captureGeneration
                )
            } else {
                attachImageRelayObservationContext(
                    to: &event,
                    observedAt: observedAt,
                    captureGeneration: captureGeneration,
                    popupState: "ineligible-clock-running"
                )
                recordTimelineEventIfNeeded(
                    event,
                    lifecycleState: "penalty-start-confirmed",
                    popupState: "ineligible-clock-running"
                )
                popupDecisions.append("\(identity)-event-recorded-no-popup-clock-running")
            }
        }

        if !removed.isEmpty {
            let resultingStrengthText = imageRelayMetadataStrengthState.scorebugManpowerText
            guard resultingStrengthText != previousStrengthText else {
                popupDecisions.append("strength-unchanged-no-popup")
                recordImageRelayPenaltyReconciliation(
                    slotValues: values,
                    slotEvidence: slotEvidence,
                    previous: previous,
                    current: current,
                    added: added,
                    removed: removed,
                    popupDecision: popupDecisions.joined(separator: ",")
                        + " generation=\(captureGeneration) complete=\(completeCycle) resumeProtected=\(resumeProtected) teams=[\(teamDiagnostics.joined(separator: ";"))]"
                )
                return
            }
            let presentation = imageRelayStrengthPresentation(
                previous: Array(previous.values),
                active: imageRelayMetadataPenaltyClocks,
                removed: removed
            )
            // Build 645: the permanent scorebug already reports every live
            // advantage (5v4, 4v3, etc.). A separate removal popup for those
            // intermediate states is noisy and, when two penalties expire close
            // together, can advertise a transient state. Popup only balanced
            // strength milestones such as 4v4 and full strength.
            let strengthPopupEligible = ["5v5", "4v4", "3v3"].contains(
                resultingStrengthText.replacingOccurrences(of: " ", with: "").lowercased()
            )
            let endedIdentities = removedPairs.keys.sorted()
            let strengthSignature = "\(presentation.headline)|\(presentation.detail)|\(imageRelayMetadataStrengthState.scorebugManpowerText)"
            if imageRelayLastStrengthPopupSignature == strengthSignature,
               now - imageRelayLastStrengthPopupObservedAt < 8.0 {
                popupDecisions.append("duplicate-strength-popup-suppressed")
                RinkLensOCREvidenceJournal.shared.recordEventAudit(
                    stage: "image_relay_duplicate_strength_popup_suppressed",
                    eventKind: "strength",
                    source: BroadcastEventSource.ocr.rawValue,
                    detail: "signature=\(strengthSignature) age=\(String(format: "%.2f", now - imageRelayLastStrengthPopupObservedAt))s"
                )
                recordImageRelayPenaltyReconciliation(
                    slotValues: values, slotEvidence: slotEvidence, previous: previous,
                    current: current, added: added, removed: removed,
                    popupDecision: popupDecisions.joined(separator: ",")
                )
                return
            }
            imageRelayLastStrengthPopupSignature = strengthSignature
            imageRelayLastStrengthPopupObservedAt = now
            var event = BroadcastEvent(
                type: RinkLensRiskFeaturePolicy.isEnabled(.semanticPenaltyEndAndTimeoutEventsV26) ? .penaltyEnd : .powerPlayStart,
                team: presentation.team,
                period: imageRelayMetadataPeriod,
                gameClock: nil,
                homeScoreAfter: imageRelayMetadataHomeScore,
                awayScoreAfter: imageRelayMetadataAwayScore,
                strengthState: imageRelayMetadataStrengthState,
                source: .ocr,
                operatorConfirmed: false,
                penaltyClockSnapshot: imageRelayMetadataPenaltyClocks,
                titleOverride: RinkLensRiskFeaturePolicy.isEnabled(.semanticPenaltyEndAndTimeoutEventsV26) ? (resultingStrengthText.replacingOccurrences(of: " ", with: "").lowercased() == "5v5" ? "FULL STRENGTH" : "PENALTY ENDED") : "STRENGTH",
                headlineOverride: presentation.headline,
                detailOverride: presentation.detail,
                endedPenaltyClockSnapshot: removed,
                penaltyLifecycleID: endedIdentities.joined(separator: ","),
                captureGeneration: captureGeneration
            )
            if !strengthPopupEligible {
                if imageRelayEventWindowIsOpen {
                    attachImageRelayStoppageContext(to: &event, observedAt: observedAt)
                } else {
                    attachImageRelayObservationContext(
                        to: &event,
                        observedAt: observedAt,
                        captureGeneration: captureGeneration,
                        popupState: "scorebug-only-intermediate-strength"
                    )
                }
                event.popupLifecycleState = "scorebug-only-intermediate-strength"
                recordTimelineEventIfNeeded(
                    event,
                    lifecycleState: "penalty-end-confirmed",
                    popupState: "scorebug-only-intermediate-strength"
                )
                popupDecisions.append("intermediate-strength-scorebug-only")
                RinkLensOCREvidenceJournal.shared.recordEventAudit(
                    stage: "image_relay_intermediate_strength_popup_suppressed",
                    eventKind: "strength",
                    source: BroadcastEventSource.ocr.rawValue,
                    detail: "resulting=\(resultingStrengthText) scorebug remains authoritative"
                )
            } else if imageRelayEventWindowIsOpen {
                attachImageRelayStoppageContext(to: &event, observedAt: observedAt)
                queueImageRelayMetadataEvent(event, priority: 2, observedAt: observedAt)
                popupDecisions.append("strength-event-recorded-popup-queued")
            } else if imageRelayMetadataClockRunning == true {
                attachImageRelayObservationContext(
                    to: &event,
                    observedAt: observedAt,
                    captureGeneration: captureGeneration,
                    popupState: "live-two-second-revalidation"
                )
                recordTimelineEventIfNeeded(
                    event,
                    lifecycleState: "penalty-end-confirmed",
                    popupState: "live-two-second-revalidation"
                )
                scheduleLiveImageRelayStrengthEvent(event, removed: removed)
                popupDecisions.append("strength-event-recorded-live-revalidation")
            } else {
                attachImageRelayObservationContext(
                    to: &event,
                    observedAt: observedAt,
                    captureGeneration: captureGeneration,
                    popupState: "ineligible-no-release-window"
                )
                recordTimelineEventIfNeeded(
                    event,
                    lifecycleState: "penalty-end-confirmed",
                    popupState: "ineligible-no-release-window"
                )
                popupDecisions.append("strength-event-recorded-no-popup-window")
            }
        }

        if popupDecisions.isEmpty { popupDecisions.append("no-lifecycle-change") }
        recordImageRelayPenaltyReconciliation(
            slotValues: values,
            slotEvidence: slotEvidence,
            previous: previous,
            current: current,
            added: added,
            removed: removed,
            popupDecision: popupDecisions.joined(separator: ",")
                + " generation=\(captureGeneration) complete=\(completeCycle) resumeProtected=\(resumeProtected) teams=[\(teamDiagnostics.joined(separator: ";"))]"
        )
    }

    private func recordImageRelayPenaltyReconciliation(
        slotValues: [OCRRegionKey: String],
        slotEvidence: [OCRRegionKey: ScoreboardImageRelayPenaltySlotEvidence] = [:],
        previous: [String: PenaltyClock],
        current: [String: PenaltyClock],
        added: [PenaltyClock],
        removed: [PenaltyClock],
        popupDecision: String
    ) {
        func identities(_ clocks: [String: PenaltyClock]) -> String {
            clocks.keys.sorted().map { key in
                let slot = clocks[key]?.slot ?? 0
                return "\(key)@slot\(slot)"
            }.joined(separator: ",")
        }
        func clockIdentities(_ clocks: [PenaltyClock]) -> String {
            clocks.compactMap { clock -> String? in
                guard let player = clock.playerNumber else { return nil }
                return "\(clock.team.rawValue)-\(player)@slot\(clock.slot)"
            }.sorted().joined(separator: ",")
        }
        let continued = Set(previous.keys).intersection(current.keys).sorted()
        let rebindings = continued.compactMap { identity -> String? in
            guard let before = previous[identity], let after = current[identity], before.slot != after.slot else {
                return nil
            }
            return "\(identity):\(before.slot)->\(after.slot)"
        }
        let slotState = [
            "home1=\(slotValues[.homePenalty1Player] ?? "blank")",
            "home2=\(slotValues[.homePenalty2Player] ?? "blank")",
            "away1=\(slotValues[.awayPenalty1Player] ?? "blank")",
            "away2=\(slotValues[.awayPenalty2Player] ?? "blank")"
        ].joined(separator: ",")
        let evidenceState = [
            OCRRegionKey.homePenalty1Player, .homePenalty2Player,
            .awayPenalty1Player, .awayPenalty2Player
        ].map { key -> String in
            guard let evidence = slotEvidence[key] else { return "\(key.rawValue)=missing" }
            let physicalIdentity = evidence.physicalIdentityHash.map { String($0, radix: 16) } ?? "none"
            return "\(key.rawValue){raw=\(evidence.rawCandidate ?? "none") resolved=\(evidence.resolvedPlayer ?? "none") retained=\(evidence.retainedPlayer ?? "none") occupancy=\(evidence.occupancy.rawValue) physical=\(physicalIdentity) stableOccupied=\(evidence.stableOccupiedCount) stableBlank=\(evidence.stableBlankCount) startedFromBlank=\(evidence.startedFromStableBlank) authorised=\(evidence.lifecycleAuthorised) cycles=\(evidence.retainedEvidenceCycles)}"
        }.joined(separator: ",")
        RinkLensOCREvidenceJournal.shared.recordEventAudit(
            stage: "image_relay_penalty_state_reconciled",
            eventKind: "penalty_state",
            source: BroadcastEventSource.ocr.rawValue,
            detail: "slots=[\(slotState)] evidence=[\(evidenceState)] previous=[\(identities(previous))] current=[\(identities(current))] continued=[\(continued.joined(separator: ","))] rebindings=[\(rebindings.joined(separator: ","))] added=[\(clockIdentities(added))] removed=[\(clockIdentities(removed))] strength=\(imageRelayMetadataStrengthState.scorebugManpowerText) popup=\(popupDecision)"
        )
    }

    private func imageRelayPlayerIdentities(
        from values: [OCRRegionKey: String]
    ) -> [String: PenaltyClock] {
        let source: [(Team, OCRRegionKey, Int)] = [
            (.home, .homePenalty1Player, 1), (.home, .homePenalty2Player, 2),
            (.away, .awayPenalty1Player, 1), (.away, .awayPenalty2Player, 2)
        ]
        var byIdentity: [String: PenaltyClock] = [:]
        for (team, key, physicalSlot) in source {
            guard let text = values[key], let player = Int(text) else { continue }
            let identity = "\(team.rawValue)-\(player)"
            guard byIdentity[identity] == nil else { continue }
            byIdentity[identity] = PenaltyClock(
                team: team,
                slot: physicalSlot,
                playerNumber: player,
                rawClock: nil,
                remainingSeconds: nil,
                metadataPlayerPresent: true
            )
        }
        return byIdentity
    }

    private func publishImageRelayPenaltyMetadata() {
        let acceptedPenalties = imageRelayActivePenaltyByIdentity.values.sorted {
                if $0.team != $1.team { return $0.team.rawValue < $1.team.rawValue }
                return $0.slot < $1.slot
            }
        penaltyLifecycleStore.replaceRelay(
            acceptedPenalties,
            source: "image-relay",
            reason: "publish Image Relay penalty metadata"
        )

        // Recovery EB / RL-269: the physical pair reconciler is the semantic
        // acceptance boundary, but MatchState remains the sole viewer authority.
        // Build 143 updated only the lifecycle/popup owner, leaving the scorebug
        // projection at zero accepted penalties. Commit the complete four-slot
        // player snapshot atomically through MatchState; timer pixels remain
        // Image Relay-owned and are never copied into semantic state.
        func player(_ team: Team, _ slot: Int) -> Int? {
            acceptedPenalties.first { $0.team == team && $0.slot == slot }?.playerNumber
        }
        var acceptedState = state
        acceptedState.homePenalty1Player = player(.home, 1)
        acceptedState.homePenalty1Clock = nil
        acceptedState.homePenalty2Player = player(.home, 2)
        acceptedState.homePenalty2Clock = nil
        acceptedState.awayPenalty1Player = player(.away, 1)
        acceptedState.awayPenalty1Clock = nil
        acceptedState.awayPenalty2Player = player(.away, 2)
        acceptedState.awayPenalty2Clock = nil
        let reduction = reduceMatchState(
            .replace(
                acceptedState,
                context: RinkLensMatchStateContext(
                    origin: .ocr,
                    eventPolicy: [],
                    diagnosticsOnly: false,
                    reason: "Recovery EB accepted Image Relay physical penalty-pair snapshot"
                )
            )
        )
        RinkLensStructuredEventLogger.shared.record(
            domain: .penalty,
            event: "image_relay_penalty_match_state_committed",
            previous: ["matchStateRevision": String(matchStateRevision - (reduction.changed ? 1 : 0))],
            next: [
                "matchStateRevision": String(matchStateRevision),
                "acceptedPlayers": acceptedPenalties.compactMap(\.playerNumber).map(String.init).joined(separator: ",")
            ],
            source: "HockeyScoreboardViewModel.publishImageRelayPenaltyMetadata",
            reason: "Viewer authorisation now shares the physical pair acceptance boundary",
            captureGeneration: imageRelayLastAcceptedCaptureGeneration,
            authoritativeOwner: "MatchState reducer"
        )
    }

    private func imageRelayStrengthPresentation(
        previous: [PenaltyClock],
        active: [PenaltyClock],
        removed: [PenaltyClock]
    ) -> (team: Team?, headline: String, detail: String) {
        func skaters(_ team: Team, in clocks: [PenaltyClock]) -> Int {
            max(3, 5 - clocks.filter { $0.team == team && $0.isActive }.count)
        }
        let homeBefore = skaters(.home, in: previous)
        let awayBefore = skaters(.away, in: previous)
        let homeAfter = skaters(.home, in: active)
        let awayAfter = skaters(.away, in: active)
        let stateText = "\(homeAfter) v \(awayAfter)"
        let removedTeams = Set(removed.map(\.team))

        if homeAfter == 5, awayAfter == 5 {
            return (nil, "FULL STRENGTH — 5 v 5", "5 v 5")
        }
        if homeAfter == awayAfter {
            return (nil, stateText, homeAfter == 4 ? "4 v 4" : "3 v 3")
        }
        if removedTeams == [.home], homeAfter > homeBefore, homeAfter < awayAfter {
            return (.home, "HOME BACK TO \(homeAfter)", "AWAY POWER PLAY — \(awayAfter) v \(homeAfter)")
        }
        if removedTeams == [.away], awayAfter > awayBefore, awayAfter < homeAfter {
            return (.away, "AWAY BACK TO \(awayAfter)", "HOME POWER PLAY — \(homeAfter) v \(awayAfter)")
        }
        if homeAfter > awayAfter {
            return (.home, "HOME POWER PLAY — \(homeAfter) v \(awayAfter)", stateText)
        }
        return (.away, "AWAY POWER PLAY — \(awayAfter) v \(homeAfter)", "\(awayAfter) v \(homeAfter)")
    }

    private func scheduleLiveImageRelayStrengthEvent(
        _ event: BroadcastEvent,
        removed: [PenaltyClock]
    ) {
        let removedIdentityKeys = event.penaltyLifecycleID?
            .split(separator: ",")
            .map { String($0) }
            .sorted() ?? []
        let taskKey = (removedIdentityKeys + [event.detailOverride ?? event.strengthState.scorebugManpowerText])
            .joined(separator: "|")
        imageRelayLiveStrengthPopupTasks[taskKey]?.cancel()
        imageRelayLiveStrengthPopupTasks[taskKey] = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled,
                  self.isImageRelayMode,
                  self.imageRelayMetadataClockRunning == true,
                  event.strengthState == self.imageRelayMetadataStrengthState,
                  removedIdentityKeys.allSatisfy({ self.imageRelayActivePenaltyByIdentity[$0] == nil }) else {
                self.imageRelayLiveStrengthPopupTasks.removeValue(forKey: taskKey)
                return
            }
            self.imageRelayLiveStrengthPopupTasks.removeValue(forKey: taskKey)
            RinkLensOCREvidenceJournal.shared.recordEventAudit(
                stage: "image_relay_live_strength_event",
                eventKind: event.type.title,
                source: event.source.rawValue,
                detail: "two-second revalidation passed removed=\(removedIdentityKeys.joined(separator: ",")) resulting=\(event.detailOverride ?? "unknown")"
            )
            self.enqueueBanner(event)
        }
    }

    private var imageRelayStopCandidateHasSingleGoalDelta: Bool {
        guard imageRelayStopCandidateInProgress else { return false }
        let homeDelta = (imageRelayMetadataHomeScore ?? imageRelayStopCandidateHomeScoreBaseline ?? 0)
            - (imageRelayStopCandidateHomeScoreBaseline ?? imageRelayMetadataHomeScore ?? 0)
        let awayDelta = (imageRelayMetadataAwayScore ?? imageRelayStopCandidateAwayScoreBaseline ?? 0)
            - (imageRelayStopCandidateAwayScoreBaseline ?? imageRelayMetadataAwayScore ?? 0)
        return (homeDelta == 1 && awayDelta == 0)
            || (awayDelta == 1 && homeDelta == 0)
    }

    private func clearImageRelayStopCandidateContext() {
        imageRelayStopCandidateInProgress = false
        imageRelayStopCandidateObservedAt = nil
        imageRelayStopCandidateFrozenClockImagePNGData = nil
        imageRelayStopCandidateHomeScoreBaseline = nil
        imageRelayStopCandidateAwayScoreBaseline = nil
        imageRelayStopCandidateHomeScoreObservedAt = nil
        imageRelayStopCandidateAwayScoreObservedAt = nil
    }

    private var imageRelayEventWindowIsOpen: Bool {
        guard imageRelayCurrentStoppageID != nil else { return false }
        if imageRelayMetadataClockRunning == false { return true }
        let deadline =
            imageRelayRestartReleaseDue
            ?? imageRelayLastCredibleRestartReleaseDeadline
        return deadline.map {
            CFAbsoluteTimeGetCurrent() <= $0 + imageRelayLateEventGraceSeconds
        } ?? false
    }

    private func attachImageRelayStoppageContext(
        to event: inout BroadcastEvent,
        observedAt: CFAbsoluteTime
    ) {
        event.stoppageID = imageRelayCurrentStoppageID
        if RinkLensRiskFeaturePolicy.isEnabled(.stoppageClockEvidenceAuthorityV3) {
            let evidence = gameEventLifecycleStore.stoppedClockEvidence(for: event.stoppageID)
            event.frozenClockImagePNGData = evidence?.imagePNGData
            RinkLensStructuredEventLogger.shared.record(
                domain: .gameEvent,
                event: "event_stoppage_clock_evidence_bound",
                entityID: event.id.uuidString,
                previous: ["imageHash": "none", "stoppageID": "none"],
                next: [
                    "imageHash": evidence?.imageHash.map { String($0) } ?? "none",
                    "stoppageID": evidence?.stoppageID.uuidString ?? "none",
                    "evidenceObservedAt": evidence.map { String(format: "%.3f", $0.observedAt) } ?? "none"
                ],
                source: "HockeyScoreboardViewModel.attachImageRelayStoppageContext",
                reason: evidence == nil
                    ? "No fresh immutable Clock evidence was available for this stoppage; do not reuse an earlier image"
                    : "Bind only the Clock evidence owned by the event's exact stoppage",
                captureGeneration: evidence?.captureGeneration ?? imageRelayLastAcceptedCaptureGeneration,
                stoppageID: event.stoppageID
            )
        } else {
            event.frozenClockImagePNGData = legacyImageRelayFrozenClockImagePNGData
        }
        event.actualObservedAt = Date(timeIntervalSinceReferenceDate: observedAt)
        event.captureGeneration = imageRelayLastAcceptedCaptureGeneration
        event.gameClock = nil
    }

    private func attachImageRelayObservationContext(
        to event: inout BroadcastEvent,
        observedAt: CFAbsoluteTime,
        captureGeneration: Int,
        popupState: String
    ) {
        event.actualObservedAt = Date(timeIntervalSinceReferenceDate: observedAt)
        event.captureGeneration = captureGeneration
        event.popupLifecycleState = popupState
        event.gameClock = nil
    }

    private func queueImageRelayMetadataEvent(
        _ event: BroadcastEvent,
        priority: Int,
        observedAt: CFAbsoluteTime,
        scoreTeam: Team? = nil,
        scoreBaseline: Int? = nil,
        scoreExpected: Int? = nil
    ) {
        var recordedEvent = event
        recordedEvent.timelineLifecycleState = scoreTeam == nil ? "confirmed" : "provisional-confirmed"
        recordedEvent.popupLifecycleState = "pending-restart-delay"
        let candidate = RinkLensRelayPendingEvent(
            event: recordedEvent,
            priority: priority,
            observedAt: observedAt,
            scoreTeam: scoreTeam,
            scoreBaseline: scoreBaseline,
            scoreExpected: scoreExpected
        )
        let admission = gameEventLifecycleStore.admitRelayPendingEvent(
            candidate,
            source: "HockeyScoreboardViewModel.queueImageRelayMetadataEvent",
            reason: "Validated Image Relay event requested lifecycle admission"
        )
        guard admission.admitted else {
            RinkLensOCREvidenceJournal.shared.recordEventAudit(
                stage: "image_relay_duplicate_popup_suppressed",
                eventKind: event.type.title,
                source: event.source.rawValue,
                detail: "fingerprint=\(admission.fingerprint) existing=\(admission.existingEventID?.uuidString ?? "none") candidate=\(event.id.uuidString)"
            )
            return
        }
        recordTimelineEventIfNeeded(
            recordedEvent,
            lifecycleState: recordedEvent.timelineLifecycleState ?? "confirmed",
            popupState: recordedEvent.popupLifecycleState ?? "pending-restart-delay"
        )
        RinkLensOCREvidenceJournal.shared.recordEventAudit(
            stage: "image_relay_metadata_event_queued",
            eventKind: event.type.title,
            source: event.source.rawValue,
            detail: "fingerprint=\(admission.fingerprint) clockImage=\(event.frozenClockImagePNGData == nil ? "missing" : "bound") priority=\(priority) running=\(imageRelayMetadataClockRunning.map { String($0) } ?? "unknown")"
        )
        if imageRelayMetadataClockRunning == true {
            guard let eventStoppageID = event.stoppageID,
                  imageRelayLastCredibleRestartStoppageID == eventStoppageID,
                  let eventDeadline = imageRelayLastCredibleRestartReleaseDeadline else {
                RinkLensOCREvidenceJournal.shared.recordEventAudit(
                    stage: "image_relay_popup_held_without_matching_restart",
                    eventKind: event.type.title,
                    source: event.source.rawValue,
                    detail: "eventStoppage=\(event.stoppageID?.uuidString ?? "none") restartStoppage=\(imageRelayLastCredibleRestartStoppageID?.uuidString ?? "none")"
                )
                return
            }
            let isAutomaticPenaltyStart = event.source == .ocr
                && !event.operatorConfirmed
                && (event.type == .penalty || event.type == .penalties)
            let resolvedDeadline = isAutomaticPenaltyStart
                ? max(eventDeadline, observedAt + 5.0)
                : eventDeadline
            if imageRelayRestartReleaseDue == nil {
                imageRelayRestartReleaseDue = resolvedDeadline
                imageRelayRestartReleaseStoppageID = eventStoppageID
            } else if isAutomaticPenaltyStart,
                      imageRelayRestartReleaseStoppageID == eventStoppageID,
                      let existing = imageRelayRestartReleaseDue {
                // A player number recognised after the physical restart must not
                // flash a penalty banner immediately merely because the original
                // restart deadline is almost elapsed. Preserve the established
                // restart policy while guaranteeing a full five-second stable
                // evidence window for that newly identified penalty.
                imageRelayRestartReleaseDue = max(existing, resolvedDeadline)
            }
            guard imageRelayRestartReleaseStoppageID == eventStoppageID else { return }
            scheduleImageRelayPopupRelease()
        }
    }

    @discardableResult
    private func reconcileImageRelayPendingGoals(
        team: Team,
        confirmedScore: Int,
        reason: String
    ) -> Int {
        var cancelled: [RinkLensRelayPendingEvent] = []
        imageRelayPendingEvents.removeAll { item in
            guard item.scoreTeam == team,
                  let expected = item.scoreExpected else { return false }
            guard confirmedScore != expected else { return false }
            cancelled.append(item)
            return true
        }
        let totalCancelled = cancelled.count
        guard totalCancelled > 0 else { return 0 }

        imageRelayCancelledGoalCount += totalCancelled
        statusMessage = totalCancelled == 1
            ? "Pending \(team.displayName) goal cancelled after the score was corrected."
            : "Pending \(team.displayName) goals cancelled after the score was corrected."
        for item in cancelled {
            gameEventLifecycleStore.releaseCanonicalIdentity(
                for: item.event,
                source: "HockeyScoreboardViewModel.reconcileImageRelayPendingGoals",
                reason: "Provisional score was corrected before popup release"
            )
            removeTimelineEvent(
                id: item.event.id,
                reason: "provisional goal corrected before popup release: \(reason)"
            )
            RinkLensOCREvidenceJournal.shared.recordEventAudit(
                stage: "image_relay_pending_goal_cancelled",
                eventKind: item.event.type.title,
                source: item.event.source.rawValue,
                detail: "Score correction before popup release; team=\(team.rawValue) baseline=\(item.scoreBaseline.map { String($0) } ?? "--") expected=\(item.scoreExpected.map { String($0) } ?? "--") actual=\(confirmedScore) reason=\(reason)"
            )
        }
        return totalCancelled
    }

    private func imageRelayPendingEventIsStillValid(
        _ item: RinkLensRelayPendingEvent
    ) -> Bool {
        if item.isProvisionalGoal,
           let team = item.scoreTeam,
           let expected = item.scoreExpected {
            let currentScore = team == .home
                ? imageRelayMetadataHomeScore
                : imageRelayMetadataAwayScore
            return currentScore == expected
        }

        switch item.event.type {
        case .penalty, .penalties:
            guard let identity = item.event.penaltyLifecycleID else { return false }
            // A transient/incorrect lifecycle that disappears before restart+5
            // must never produce a late popup.
            return imageRelayActivePenaltyByIdentity[identity] != nil
        case .powerPlayStart, .penaltyEnd:
            let ended = item.event.penaltyLifecycleID?
                .split(separator: ",")
                .map { String($0) } ?? []
            return item.event.strengthState == imageRelayMetadataStrengthState
                && ended.allSatisfy { imageRelayActivePenaltyByIdentity[$0] == nil }
        default:
            return true
        }
    }

    private func scheduleImageRelayPopupRelease() {
        imageRelayPopupReleaseTask?.cancel()
        guard let due = imageRelayRestartReleaseDue else { return }
        let delay = max(0, due - CFAbsoluteTimeGetCurrent())
        imageRelayPopupReleaseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled,
                  self.isImageRelayMode,
                self.imageRelayRestartReleaseDue == due
            else { return }
            self.releaseImageRelayMetadataEvents()
        }
    }

    private static func fnv1a64Data(_ data: Data) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private func authoritativeStoppedClockEvidencePNG(
        candidatePNGData: Data?,
        observedAt: CFAbsoluteTime
    ) -> (data: Data?, source: String, ageMilliseconds: Double?) {
        guard RinkLensRiskFeaturePolicy.isEnabled(.stoppageClockEvidenceAuthorityV3) else {
            return (candidatePNGData, "legacy-stop-candidate", nil)
        }
        let relay = ScoreboardImageRelayStore.shared.snapshot()
        let observedDate = Date(timeIntervalSinceReferenceDate: observedAt)
        if let image = relay.image(for: .clock),
           let updatedAt = relay.fieldUpdatedAt[.clock] {
            let age = abs(observedDate.timeIntervalSince(updatedAt))
            if age <= 1.50, let png = UIImage(cgImage: image).pngData() {
                return (png, "fresh-scoreboard-presentation", age * 1_000)
            }
        }
        // Build 705: candidatePNGData is captured by the exact physical stop
        // transition and is carried only inside that stop-candidate transaction.
        // It must not be discarded merely because the 2.1-second stable-stop proof
        // completes after the previous 1.5-second freshness threshold. Reusing an
        // older stoppage is still prevented by clearImageRelayStopCandidateContext().
        if let candidatePNGData {
            return (candidatePNGData, "same-stoppage-stop-candidate", nil)
        }
        return (nil, "no-stop-owned-clock-evidence", nil)
    }

    private func commitImageRelayStoppageContext(
        frozenClockImagePNGData: Data?,
        observedAt: CFAbsoluteTime,
        reason: String
    ) {
        let candidateHomeBaseline = imageRelayStopCandidateHomeScoreBaseline
        let candidateAwayBaseline = imageRelayStopCandidateAwayScoreBaseline
        let candidateHomeObservedAt = imageRelayStopCandidateHomeScoreObservedAt
        let candidateAwayObservedAt = imageRelayStopCandidateAwayScoreObservedAt
        let candidateFrozenClock = imageRelayStopCandidateFrozenClockImagePNGData

        let newStoppageID = UUID()
        let stoppedClockEvidence = authoritativeStoppedClockEvidencePNG(
            candidatePNGData: frozenClockImagePNGData ?? candidateFrozenClock,
            observedAt: observedAt
        )
        if RinkLensRiskFeaturePolicy.isEnabled(.stoppageClockEvidenceAuthorityV3) {
            let relay = ScoreboardImageRelayStore.shared.snapshot()
            _ = gameEventLifecycleStore.commitStoppedClockEvidence(
                stoppageID: newStoppageID,
                imagePNGData: stoppedClockEvidence.data,
                observedAt: observedAt,
                captureGeneration: imageRelayLastAcceptedCaptureGeneration,
                sourceSequence: relay.sourceSequence,
                source: stoppedClockEvidence.source,
                reason: "\(reason); ageMs=\(stoppedClockEvidence.ageMilliseconds.map { String(format: "%.1f", $0) } ?? "none")"
            )
        } else {
            legacyImageRelayCurrentStoppageID = newStoppageID
            legacyImageRelayFrozenClockImagePNGData = frozenClockImagePNGData ?? candidateFrozenClock
        }
        let ownerBaseline = gameEventLifecycleStore.preferredStoppageScoreBaseline(
            fallbackHome: imageRelayMetadataHomeScore,
            fallbackAway: imageRelayMetadataAwayScore
        )
        imageRelayStoppageHomeScoreBaseline = candidateHomeBaseline ?? ownerBaseline.home
        imageRelayStoppageAwayScoreBaseline = candidateAwayBaseline ?? ownerBaseline.away
        imageRelayStoppageHomeScoreObservedAt = candidateHomeObservedAt
        imageRelayStoppageAwayScoreObservedAt = candidateAwayObservedAt
        clearImageRelayStopCandidateContext()
        if let stoppageID = imageRelayCurrentStoppageID {
            penaltyLifecycleStore.advanceCancellationReconciliation(
                to: stoppageID,
                source: "HockeyScoreboardViewModel.commitImageRelayStoppageContext",
                reason: "A newly committed physical stoppage is the boundary for prior power-play cancellation tombstones"
            )
            RinkLensStructuredEventLogger.shared.record(
                domain: .gameEvent,
                event: "stoppage_score_baseline_committed",
                entityID: stoppageID.uuidString,
                previous: [
                    "candidateHome": candidateHomeBaseline.map { String($0) } ?? "none",
                    "candidateAway": candidateAwayBaseline.map { String($0) } ?? "none"
                ],
                next: [
                    "home": imageRelayStoppageHomeScoreBaseline.map { String($0) } ?? "none",
                    "away": imageRelayStoppageAwayScoreBaseline.map { String($0) } ?? "none",
                    "source": candidateHomeBaseline != nil || candidateAwayBaseline != nil ? "stop-candidate" : ownerBaseline.source
                ],
                source: "HockeyScoreboardViewModel.commitImageRelayStoppageContext",
                reason: reason,
                captureGeneration: imageRelayLastAcceptedCaptureGeneration,
                stoppageID: stoppageID
            )
        }

        // Bind penalty lifecycles that stabilised just before the Clock stop was
        // formally committed. This closes the former "outside popup window" gap.
        if let stoppageID = imageRelayCurrentStoppageID {
            let earliestEligible = observedAt - 8.0
            var reboundCount = 0
            for index in imageRelayPendingEvents.indices {
                guard imageRelayPendingEvents[index].event.stoppageID == nil,
                      imageRelayPendingEvents[index].event.type == .penalty
                        || imageRelayPendingEvents[index].event.type == .penalties,
                      imageRelayPendingEvents[index].observedAt >= earliestEligible else { continue }
                let eventID = imageRelayPendingEvents[index].event.id
                let previousClockHash = imageRelayPendingEvents[index].event.frozenClockImagePNGData.map(Self.fnv1a64Data)
                imageRelayPendingEvents[index].event.stoppageID = stoppageID
                imageRelayPendingEvents[index].event.frozenClockImagePNGData = imageRelayFrozenClockImagePNGData
                imageRelayPendingEvents[index].event.popupLifecycleState = "pending-restart-delay"
                let reboundEvent = imageRelayPendingEvents[index].event
                matchEventJournal.updateTimeline(
                    id: eventID,
                    source: "HockeyScoreboardViewModel.commitImageRelayStoppageContext",
                    reason: "Bind penalty confirmed during physical stop candidate to the committed stoppage"
                ) { timelineEvent in
                    timelineEvent.stoppageID = stoppageID
                    timelineEvent.frozenClockImagePNGData = reboundEvent.frozenClockImagePNGData
                    timelineEvent.popupLifecycleState = reboundEvent.popupLifecycleState
                }
                RinkLensStructuredEventLogger.shared.record(
                    domain: .gameEvent,
                    event: "pending_penalty_stoppage_evidence_bound",
                    entityID: eventID.uuidString,
                    previous: [
                        "stoppageID": "none",
                        "clockImageHash": previousClockHash.map { String($0) } ?? "none",
                        "popupState": "awaiting-stoppage-confirmation"
                    ],
                    next: [
                        "stoppageID": stoppageID.uuidString,
                        "clockImageHash": reboundEvent.frozenClockImagePNGData.map(Self.fnv1a64Data).map { String($0) } ?? "none",
                        "popupState": reboundEvent.popupLifecycleState ?? "none"
                    ],
                    source: "HockeyScoreboardViewModel.commitImageRelayStoppageContext",
                    reason: "Physical stop committed; update the lifecycle event, canonical fingerprint and timeline in one owner transaction",
                    captureGeneration: reboundEvent.captureGeneration,
                    stoppageID: stoppageID
                )
                reboundCount += 1
            }
            if reboundCount > 0 {
                RinkLensOCREvidenceJournal.shared.recordEventAudit(
                    stage: "image_relay_pre_stoppage_penalties_bound",
                    eventKind: "penalty",
                    source: BroadcastEventSource.ocr.rawValue,
                    detail: "stoppage=\(stoppageID.uuidString) rebound=\(reboundCount) window=8.0s"
                )
            }
        }
        // Expire any unbound false/transient candidates rather than allowing them
        // to attach to a much later stoppage.
        imageRelayPendingEvents.removeAll { pending in
            pending.event.stoppageID == nil && observedAt - pending.observedAt > 12.0
        }

        // A score accepted during stop confirmation must not become the new
        // baseline. Qualify it immediately against the preserved pre-change score.
        evaluateImageRelayGoalCandidates(observedAt: observedAt)

        RinkLensOCREvidenceJournal.shared.recordEventAudit(
            stage: "image_relay_clock_image_frozen",
            eventKind: "clock",
            source: BroadcastEventSource.ocr.rawValue,
            detail:
                "reason=\(reason) stoppage=\(imageRelayCurrentStoppageID?.uuidString ?? "none") frozenImage=\(imageRelayFrozenClockImagePNGData == nil ? "no" : "yes") evidenceSource=\(stoppedClockEvidence.source) evidenceAgeMs=\(stoppedClockEvidence.ageMilliseconds.map { String(format: "%.1f", $0) } ?? "none") observedAt=\(observedAt)"
        )
    }

    private func scheduleStableImageRelayStopCancellation(
        observedAt: CFAbsoluteTime,
        frozenClockImagePNGData: Data?
    ) {
        guard
            imageRelayRestartReleaseDue != nil
                || imageRelayLastCredibleRestartReleaseDeadline != nil
        else { return }
        imageRelayStableStopCancellationTask?.cancel()
        if !imageRelayStopCandidateInProgress {
            imageRelayStopCandidateObservedAt = observedAt
            imageRelayStopCandidateFrozenClockImagePNGData = frozenClockImagePNGData
            let ownerBaseline = gameEventLifecycleStore.preferredStoppageScoreBaseline(
                fallbackHome: imageRelayMetadataHomeScore,
                fallbackAway: imageRelayMetadataAwayScore
            )
            imageRelayStopCandidateHomeScoreBaseline = ownerBaseline.home
            imageRelayStopCandidateAwayScoreBaseline = ownerBaseline.away
            imageRelayStopCandidateHomeScoreObservedAt = nil
            imageRelayStopCandidateAwayScoreObservedAt = nil
        }
        imageRelayStopCandidateInProgress = true
        let token = UUID()
        imageRelayStableStopToken = token
        imageRelayStableStopCancellationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(
                nanoseconds: UInt64(self.imageRelayStableStopConfirmationSeconds * 1_000_000_000))
            guard !Task.isCancelled,
                self.imageRelayStableStopToken == token,
                self.imageRelayMetadataClockRunning == false,
                self.imageRelayRestartReleaseDue != nil
                    || self.imageRelayLastCredibleRestartReleaseDeadline != nil
            else { return }
            // Build 684: a stop that becomes stable before restart+5 proves the
            // supposed restart was not five seconds of continuous play. Cancel the
            // stale deadline so events from this/new stoppage cannot inherit it.
            let interruptedStoppageID = self.imageRelayRestartReleaseStoppageID
            self.imageRelayPopupReleaseTask?.cancel()
            self.imageRelayPopupReleaseTask = nil
            self.imageRelayRestartReleaseDue = nil
            self.imageRelayRestartReleaseStoppageID = nil
            self.imageRelayLastCredibleRestartReleaseDeadline = nil
            self.imageRelayLastCredibleRestartStoppageID = nil
            self.imageRelayStableStopCancellationTask = nil
            self.commitImageRelayStoppageContext(
                frozenClockImagePNGData: frozenClockImagePNGData,
                observedAt: observedAt,
                reason: "stable stop cancelled incomplete restart window"
            )

            var carriedForward = 0
            if let interruptedStoppageID,
               let newStoppageID = self.imageRelayCurrentStoppageID,
               interruptedStoppageID != newStoppageID {
                for index in self.imageRelayPendingEvents.indices
                where self.imageRelayPendingEvents[index].event.stoppageID == interruptedStoppageID {
                    let eventID = self.imageRelayPendingEvents[index].event.id
                    let previousStoppageID = self.imageRelayPendingEvents[index].event.stoppageID
                    let previousClockHash = self.imageRelayPendingEvents[index].event.frozenClockImagePNGData
                        .map { data -> UInt64 in
                            var hash: UInt64 = 14_695_981_039_346_656_037
                            for byte in data { hash ^= UInt64(byte); hash &*= 1_099_511_628_211 }
                            return hash
                        }
                    let replacementEvidence = self.gameEventLifecycleStore.stoppedClockEvidence(
                        for: newStoppageID
                    )
                    self.imageRelayPendingEvents[index].event.stoppageID = newStoppageID
                    if RinkLensRiskFeaturePolicy.isEnabled(.stoppageClockEvidenceAuthorityV3) {
                        self.imageRelayPendingEvents[index].event.frozenClockImagePNGData =
                            replacementEvidence?.imagePNGData
                    }
                    self.imageRelayPendingEvents[index].event.popupLifecycleState =
                        "pending-next-genuine-restart-after-short-run"
                    self.matchEventJournal.updateTimeline(
                        id: eventID,
                        source: "HockeyScoreboardViewModel.scheduleStableImageRelayStopCancellation",
                        reason: "Carry pending event into replacement stoppage after incomplete restart"
                    ) { event in
                        event.stoppageID = newStoppageID
                        if RinkLensRiskFeaturePolicy.isEnabled(.stoppageClockEvidenceAuthorityV3) {
                            event.frozenClockImagePNGData = replacementEvidence?.imagePNGData
                        }
                        event.popupLifecycleState =
                            "pending-next-genuine-restart-after-short-run"
                    }
                    if RinkLensRiskFeaturePolicy.isEnabled(.stoppageClockEvidenceAuthorityV3) {
                        RinkLensStructuredEventLogger.shared.record(
                            domain: .gameEvent,
                            event: "event_stoppage_clock_evidence_rebound",
                            entityID: eventID.uuidString,
                            previous: [
                                "stoppageID": previousStoppageID?.uuidString ?? "none",
                                "imageHash": previousClockHash.map { String($0) } ?? "none"
                            ],
                            next: [
                                "stoppageID": newStoppageID.uuidString,
                                "imageHash": replacementEvidence?.imageHash.map { String($0) } ?? "none"
                            ],
                            source: "HockeyScoreboardViewModel.scheduleStableImageRelayStopCancellation",
                            reason: "Replacement physical stoppage atomically changed both event identity and immutable Clock evidence",
                            captureGeneration: replacementEvidence?.captureGeneration
                                ?? self.imageRelayLastAcceptedCaptureGeneration,
                            stoppageID: newStoppageID
                        )
                    }
                    carriedForward += 1
                }
            }
            RinkLensOCREvidenceJournal.shared.recordEventAudit(
                stage: "image_relay_popup_deadline_cancelled_stable_stop",
                eventKind: "clock",
                source: BroadcastEventSource.ocr.rawValue,
                detail:
                    "stop persisted for \(self.imageRelayStableStopConfirmationSeconds)s; incomplete restart cancelled observedAt=\(observedAt) carriedForward=\(carriedForward)"
            )
        }
    }

    private func releaseImageRelayMetadataEvents() {
        let releasedAt = CFAbsoluteTimeGetCurrent()
        let scheduledDeadline = imageRelayRestartReleaseDue
        let releaseStoppageID = imageRelayRestartReleaseStoppageID
        let sortedPending = imageRelayPendingEvents.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.observedAt < $1.observedAt
        }
        let orphanedGoals = sortedPending.filter { item in
            guard item.event.stoppageID != nil,
                  item.event.stoppageID != releaseStoppageID,
                  releasedAt - item.observedAt >= 5.0 else { return false }
            switch item.event.type {
            case .goal, .powerPlayGoal, .shortHandedGoal:
                return true
            default:
                return false
            }
        }
        let orphanedGoalIDs = Set(orphanedGoals.map { $0.event.id })
        let pending = sortedPending.filter { item in
            guard let releaseStoppageID else { return false }
            return item.event.stoppageID == releaseStoppageID
                || orphanedGoalIDs.contains(item.event.id)
        }
        let releasedEventIDs = Set(pending.map { $0.event.id })
        imageRelayPendingEvents = sortedPending.filter { item in
            !releasedEventIDs.contains(item.event.id)
        }
        imageRelayRestartReleaseDue = nil
        imageRelayRestartReleaseStoppageID = nil
        imageRelayPopupReleaseTask = nil
        imageRelayStableStopCancellationTask?.cancel()
        imageRelayStableStopCancellationTask = nil

        let releaseLatenessMS: Double = scheduledDeadline.map { deadline in
            max(0, (releasedAt - deadline) * 1_000)
        } ?? 0
        let scheduledDeadlineText: String
        if let scheduledDeadline {
            scheduledDeadlineText = String(describing: scheduledDeadline)
        } else {
            scheduledDeadlineText = "none"
        }
        let releasedAtText = String(describing: releasedAt)
        let releaseLatenessText = String(format: "%.1f", releaseLatenessMS)
        let releaseBatchDetail =
            "count=\(pending.count) rescuedOrphanGoals=\(orphanedGoals.count) retainedOtherStoppages=\(imageRelayPendingEvents.count) "
            + "stoppage=\(releaseStoppageID?.uuidString ?? "none") scheduled=\(scheduledDeadlineText) "
            + "released=\(releasedAtText) latenessMs=\(releaseLatenessText)"
        RinkLensOCREvidenceJournal.shared.recordEventAudit(
            stage: "image_relay_popup_release_batch",
            eventKind: "popup",
            source: BroadcastEventSource.ocr.rawValue,
            detail: releaseBatchDetail
        )

        var cancelledAtRelease = 0
        // Build 655: every independently confirmed event is released to the one
        // unified overlay queue. The queue owns presentation sequencing, so a
        // second penalty or a goal/penalty combination waits until the active
        // popup completes instead of being coalesced or displayed concurrently.
        for item in pending {
            guard imageRelayPendingEventIsStillValid(item) else {
                cancelledAtRelease += 1
                imageRelayCancelledGoalCount += 1
                gameEventLifecycleStore.releaseCanonicalIdentity(
                    for: item.event,
                    source: "HockeyScoreboardViewModel.releaseImageRelayMetadataEvents",
                    reason: "Provisional event failed final validity at popup release"
                )
                gameEventLifecycleStore.transition(
                    item.event,
                    to: .cancelled,
                    source: "HockeyScoreboardViewModel.releaseImageRelayMetadataEvents",
                    reason: "Provisional event failed final validity at popup release"
                )
                removeTimelineEvent(
                    id: item.event.id,
                    reason: "provisional goal invalid at popup release"
                )
                RinkLensOCREvidenceJournal.shared.recordEventAudit(
                    stage: "image_relay_pending_goal_cancelled_at_release",
                    eventKind: item.event.type.title,
                    source: item.event.source.rawValue,
                    detail: "Final score no longer equals provisional expected score; popup suppressed"
                )
                continue
            }
            RinkLensOCREvidenceJournal.shared.recordEventAudit(
                stage: "image_relay_event_forwarded_to_unified_popup_queue",
                eventKind: item.event.type.title,
                source: item.event.source.rawValue,
                detail: "stoppage=\(item.event.stoppageID?.uuidString ?? "none") team=\(item.event.team?.rawValue ?? "none") lifecycle=\(item.event.penaltyLifecycleID ?? "none"); every valid event retains its own popup"
            )

            let physicalToReleaseMS = max(0, (releasedAt - item.observedAt) * 1_000)
            let physicalToReleaseText = String(format: "%.1f", physicalToReleaseMS)
            let stoppageText = item.event.stoppageID?.uuidString ?? "none"
            let eventReleaseDetail =
                "physicalToReleaseMs=\(physicalToReleaseText) "
                + "deadlineLatenessMs=\(releaseLatenessText) stoppage=\(stoppageText)"
            RinkLensOCREvidenceJournal.shared.recordEventAudit(
                stage: "image_relay_popup_event_released",
                eventKind: item.event.type.title,
                source: item.event.source.rawValue,
                detail: eventReleaseDetail
            )
            enqueueBanner(
                item.event,
                releaseReason: "Verified physical Clock restart plus five seconds"
            )
        }
        if cancelledAtRelease > 0 {
            statusMessage = cancelledAtRelease == 1
                ? "Corrected pending goal discarded before popup release."
                : "Corrected pending goals discarded before popup release."
        }
        // Retain the stoppage context through the short late-recognition grace.
        // A stable next stop replaces it. This lets a score/penalty recognised just
        // after restart+5s publish immediately with the correct frozen Clock image.
    }

    func resetImageRelayMetadata(reason: String) {
        imageRelayPopupReleaseTask?.cancel()
        imageRelayPopupReleaseTask = nil
        imageRelayStableStopCancellationTask?.cancel()
        imageRelayStableStopCancellationTask = nil
        imageRelayStableStopToken = UUID()
        clearImageRelayStopCandidateContext()
        for task in imageRelayLiveStrengthPopupTasks.values { task.cancel() }
        imageRelayLiveStrengthPopupTasks.removeAll(keepingCapacity: false)
        imageRelayMetadataPeriod = nil
        imageRelayMetadataHomeScore = nil
        imageRelayMetadataAwayScore = nil
        penaltyLifecycleStore.replaceRelay([], source: "image-relay", reason: reason)
        imageRelayMetadataClockRunning = nil
        if RinkLensRiskFeaturePolicy.isEnabled(.stoppageClockEvidenceAuthorityV3) {
            gameEventLifecycleStore.clearStoppedClockEvidence(
                source: "HockeyScoreboardViewModel.resetImageRelayMetadata",
                reason: reason
            )
        } else {
            legacyImageRelayFrozenClockImagePNGData = nil
            legacyImageRelayCurrentStoppageID = nil
        }
        imageRelayRestartReleaseDue = nil
        imageRelayRestartReleaseStoppageID = nil
        imageRelayLastCredibleRestartReleaseDeadline = nil
        imageRelayLastCredibleRestartStoppageID = nil
        imageRelayScoreBaselineReady = false
        imageRelayStoppageHomeScoreBaseline = nil
        imageRelayStoppageAwayScoreBaseline = nil
        imageRelayStoppageHomeScoreObservedAt = nil
        imageRelayStoppageAwayScoreObservedAt = nil
        pendingImageRelayScoreConfirmation = nil
        imageRelayPenaltyBaselineReady = false
        imageRelayPenaltyBaselineStartedAt = nil
        imageRelayActivePenaltyByIdentity.removeAll(keepingCapacity: true)
        imageRelayPendingEvents.removeAll(keepingCapacity: true)
        imageRelayCancelledGoalCount = 0
        imageRelayLastAcceptedCaptureGeneration = 0
        imageRelayLastAcceptedSourceSequence = nil
        imageRelayLastDirectScoreGeneration = 0
        imageRelayLastDirectScoreSequence = nil
        imageRelayMinimumSourceSequenceAfterResume = nil
        imageRelayPenaltyResumeProtectionUntil = 0
        imageRelayPenaltyResumeKnownIdentities.removeAll(keepingCapacity: true)
        imageRelayBulkEmptyPenaltyCycleCount = 0
        imageRelayTeamPenaltySnapshotSignature.removeAll(keepingCapacity: true)
        imageRelayTeamPenaltySnapshotCount.removeAll(keepingCapacity: true)
        imageRelayTeamPenaltySnapshotFirstObservedAt.removeAll(keepingCapacity: true)
        imageRelayTeamPenaltySnapshotLastObservedAt.removeAll(keepingCapacity: true)
        imageRelayPenaltyLifecycleIDBySlot.removeAll(keepingCapacity: true)
        imageRelayLargeScoreCandidateEvidence.removeAll(keepingCapacity: true)
        imageRelayRejectedLargeScoreCandidate.removeAll(keepingCapacity: true)
        imageRelayLastStrengthPopupSignature = nil
        imageRelayLastStrengthPopupObservedAt = 0
        imageRelayMetadataDiagnostic = "Metadata relay reset — \(reason)"
        refreshBroadcastOverlayState()
    }

    func previewBroadcastEventPopup(type: BroadcastEventType, team: Team?) {
        guard BroadcastEventPopupSettings.shared.isEnabled(for: type) else {
            statusMessage = "Popup disabled for \(type.title.lowercased()). Enable it in Settings first."
            return
        }

        let nextHome = max(state.homeScore ?? overrideHomeScore, overrideHomeScore)
        let nextAway = max(state.awayScore ?? overrideAwayScore, overrideAwayScore)
        let scoringEvent = type == .goal || type == .powerPlayGoal || type == .shortHandedGoal
        let penaltyEvent = [.penalty, .penalties, .powerPlayStart, .penaltyEnd, .timeoutStart, .timeoutEnd].contains(type)
        let homeScore = team == .home && scoringEvent ? nextHome + 1 : nextHome
        let awayScore = team == .away && scoringEvent ? nextAway + 1 : nextAway
        let previewPenaltyClock = PenaltyClock(team: team ?? .away, slot: 1, playerNumber: 12, rawClock: "2:00", remainingSeconds: 120)
        let previewStrength: StrengthState
        if penaltyEvent {
            switch team {
            case .home:
                previewStrength = .awayPowerPlay(seconds: 120, advantage: "5-on-4")
            case .away:
                previewStrength = .homePowerPlay(seconds: 120, advantage: "5-on-4")
            case .none:
                previewStrength = .unknown
            }
        } else {
            previewStrength = currentStrengthState
        }
        let event = BroadcastEvent(
            type: type,
            team: team,
            period: state.period ?? overridePeriod,
            gameClock: state.clock ?? "12:34",
            homeScoreAfter: homeScore,
            awayScoreAfter: awayScore,
            strengthState: previewStrength,
            source: .manual,
            operatorConfirmed: true,
            penaltyClockSnapshot: penaltyEvent ? [previewPenaltyClock] : activePenaltyClocks
        )
        var displayEvent = event
        if RinkLensRiskFeaturePolicy.isEnabled(.popupPolicySnapshotV2) {
            displayEvent.popupPolicySnapshot = BroadcastEventPopupSettings.shared.snapshot
        }
        if displayEvent.sponsor == nil {
            displayEvent.sponsor = SponsorCatalogueStore.shared.resolvedPenaltySponsor(for: displayEvent)
        }
        MainThreadStallMonitor.shared.traceSponsorOverlay("preview event=\(displayEvent.type.title) team=\(displayEvent.team?.displayName ?? "none") sponsor=\(displayEvent.sponsor?.displayTitle ?? "none")")
        overlayEventStateMachine.clear(source: "HockeyScoreboardViewModel", reason: "manual preview popup")
        let item = BroadcastOverlayQueueItem.event(
            displayEvent,
            durationSeconds: displayEvent.popupPolicySnapshot?.clampedDurationSeconds ?? clampedBroadcastPopupDurationSeconds,
            reason: "manual preview popup"
        )
        enqueueUnifiedOverlay(item, preemptLowerPriority: true, traceReason: "preview popup")
        statusMessage = "Test popup shown: \(displayEvent.type.title)."
    }

    private func flushNormalizedStoppedClockBroadcastEvents(now: Date) {
        releaseStoppedClockBroadcastEvents(
            gameEventDetector.flushNormalizedStoppedClockBroadcastEvents(
                now: now,
                currentState: state
            ),
            reason: "event released after five seconds of continuous physical-clock movement",
            traceReason: "post-restart five-second normalization release",
            auditStage: "event_post_restart_normalized_release"
        )
    }

    private func flushStableGoalFallbackBroadcastEvents(now: Date) {
        releaseStoppedClockBroadcastEvents(
            gameEventDetector.flushStableGoalFallbackEvents(
                now: now,
                currentState: state
            ),
            reason: "goal released after ten seconds of stable, repeatedly confirmed score evidence because trusted Clock proof was unavailable",
            traceReason: "bounded no-Clock goal score-stability fallback",
            auditStage: "event_score_stability_fallback_release"
        )
    }

    private func releaseStoppedClockBroadcastEvents(
        _ eventsToShow: [BroadcastEvent],
        reason: String,
        traceReason: String,
        auditStage: String
    ) {
        guard !eventsToShow.isEmpty else { return }
        for event in eventsToShow {
            gameEventLifecycleStore.transition(event, to: .eligible, source: "HockeyScoreboardViewModel.releaseStoppedClockBroadcastEvents", reason: reason)
            recordTimelineEventIfNeeded(
                event,
                lifecycleState: "confirmed",
                popupState: "released-after-restart"
            )
            RinkLensOCRReplayGateController.shared.recordEvent(
                stage: auditStage,
                event: event,
                detail: reason
            )
            RinkLensOCREvidenceJournal.shared.recordEventAudit(
                stage: auditStage,
                eventKind: event.type.title,
                source: event.source.rawValue,
                detail: reason
            )
            guard (event.popupPolicySnapshot?.isEnabled(for: event.type) ?? BroadcastEventPopupSettings.shared.isEnabled(for: event.type)) else {
                gameEventLifecycleStore.transition(event, to: .suppressed, source: "HockeyScoreboardViewModel.releaseStoppedClockBroadcastEvents", reason: "Popup disabled when held event released")
                RinkLensOCREvidenceJournal.shared.recordEventAudit(
                    stage: "overlay_suppressed",
                    eventKind: event.type.title,
                    source: event.source.rawValue,
                    detail: "Popup disabled when held event was released"
                )
                continue
            }
            let item = BroadcastOverlayQueueItem.event(
                event,
                durationSeconds: event.popupPolicySnapshot?.clampedDurationSeconds ?? clampedBroadcastPopupDurationSeconds,
                reason: reason
            )
            enqueueUnifiedOverlay(item, traceReason: traceReason)
        }
        showNextOverlayIfNeeded()
    }

    private var clampedBroadcastPopupDurationSeconds: TimeInterval {
        min(max(BroadcastEventPopupSettings.shared.popupDurationSeconds, 2.0), 12.0)
    }

    private func enqueueUnifiedOverlay(
        _ item: BroadcastOverlayQueueItem,
        preemptLowerPriority: Bool = false,
        traceReason: String
    ) {
        overlayEventStateMachine.enqueue(item, preemptLowerPriority: preemptLowerPriority, source: "overlay-queue", reason: traceReason)
        if let event = item.event {
            gameEventLifecycleStore.transition(event, to: .queued, source: "overlay-queue", reason: traceReason)
        }
        RinkLensOCREvidenceJournal.shared.recordEventAudit(
            stage: "overlay_enqueued",
            eventKind: item.kind.rawValue,
            source: "overlay-queue",
            queueItemID: String(describing: item.id),
            detail: "\(item.diagnosticSummary); reason=\(traceReason); preempt=\(preemptLowerPriority)"
        )
        MainThreadStallMonitor.shared.traceSponsorOverlay("[overlay-queue] enqueue \(item.diagnosticSummary); reason=\(traceReason)")
        showNextOverlayIfNeeded()
    }

    private var isOperatorBroadcastRouteVisible: Bool {
        activeNextGenLifecycleRoute == .broadcast
            || (activeNextGenLifecycleRoute == nil && currentScreen == .broadcast)
    }

    private func pauseUnifiedOverlayForHiddenBroadcastRoute(reason: String) {
        guard let active = broadcastOverlayQueueState.activeItem,
              active.durationSeconds != nil else { return }
        bannerDismissTask?.cancel()
        bannerDismissTask = nil
        RinkLensOCREvidenceJournal.shared.recordEventAudit(
            stage: "overlay_display_paused_hidden_route",
            eventKind: active.kind.rawValue,
            source: "overlay-queue",
            queueItemID: String(describing: active.id),
            detail: "\(active.diagnosticSummary); reason=\(reason)"
        )
        publishUnifiedOverlayQueueState(reason: "hidden route paused active popup")
    }

    private func resumeUnifiedOverlayForVisibleBroadcastRoute(reason: String) {
        guard isOperatorBroadcastRouteVisible else { return }
        if let active = broadcastOverlayQueueState.activeItem {
            publishUnifiedOverlayQueueState(reason: "Broadcast route resumed active popup")
            if active.durationSeconds != nil {
                scheduleOverlayDismissal(for: active)
            }
            RinkLensOCREvidenceJournal.shared.recordEventAudit(
                stage: "overlay_display_resumed_visible_route",
                eventKind: active.kind.rawValue,
                source: "overlay-queue",
                queueItemID: String(describing: active.id),
                detail: "\(active.diagnosticSummary); reason=\(reason)"
            )
        } else {
            showNextOverlayIfNeeded()
        }
    }

    private func showNextOverlayIfNeeded() {
        guard isOperatorBroadcastRouteVisible else {
            publishUnifiedOverlayQueueState(reason: "operator popup held until Broadcast is visible")
            return
        }
        guard broadcastOverlayQueueState.activeItem == nil else {
            publishUnifiedOverlayQueueState(reason: "overlay already active")
            return
        }
        guard let active = overlayEventStateMachine.promoteNextIfNeeded(source: "overlay-queue", reason: "show next overlay") else {
            publishUnifiedOverlayQueueState(reason: "overlay queue empty")
            return
        }
        publishUnifiedOverlayQueueState(reason: "promoted overlay")
        RinkLensOCREvidenceJournal.shared.recordEventAudit(
            stage: "overlay_display_started",
            eventKind: active.kind.rawValue,
            source: "overlay-queue",
            queueItemID: String(describing: active.id),
            detail: active.diagnosticSummary
        )
        if let event = active.event {
            gameEventLifecycleStore.transition(event, to: .displayed, source: "overlay-queue", reason: "Promoted to active overlay")
        }
        MainThreadStallMonitor.shared.traceSponsorOverlay("[overlay-queue] active \(active.diagnosticSummary)")
        if active.durationSeconds != nil {
            scheduleOverlayDismissal(for: active)
        }
    }

    private func publishUnifiedOverlayQueueState(reason: String) {
        MainThreadStallMonitor.shared.traceSponsorOverlay("[overlay-queue] state \(broadcastOverlayQueueState.diagnosticSummary); reason=\(reason)")
        refreshBroadcastOverlayState()
    }

    private func scheduleOverlayDismissal(for item: BroadcastOverlayQueueItem) {
        bannerDismissTask?.cancel()
        guard isOperatorBroadcastRouteVisible else {
            bannerDismissTask = nil
            return
        }
        guard let duration = item.durationSeconds else { return }
        let nanoseconds = UInt64(duration * 1_000_000_000)
        bannerDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            await MainActor.run {
                guard let self else { return }
                guard self.isOperatorBroadcastRouteVisible else {
                    self.bannerDismissTask = nil
                    self.publishUnifiedOverlayQueueState(reason: "popup duration paused because Broadcast is hidden")
                    return
                }
                let dismissed = self.overlayEventStateMachine.dismissActive(matching: item.id, source: "overlay-queue", reason: "automatic popup duration completed")
                if let dismissed {
                    if let event = dismissed.event {
                        self.gameEventLifecycleStore.transition(event, to: .completed, source: "overlay-queue", reason: "Automatic popup duration completed")
                    }
                    RinkLensOCREvidenceJournal.shared.recordEventAudit(
                        stage: "overlay_display_completed",
                        eventKind: dismissed.kind.rawValue,
                        source: "overlay-queue",
                        queueItemID: String(describing: dismissed.id),
                        detail: dismissed.diagnosticSummary
                    )
                }
                self.publishUnifiedOverlayQueueState(reason: "auto dismiss \(dismissed?.kind.rawValue ?? "none")")
                self.showNextOverlayIfNeeded()
            }
        }
    }

    func updateFrameDeliveryPolicy(force: Bool = false) {
        // v0.8.4t: screen transitions must not become a camera-session stop signal.
        // This controls OCR sample delivery only; preview/session lifetime is kept alive separately.
        let recordingActive = RinkLensRecordingCaptureLease.shared.isRecordingActive()
        let transitionBlocksDelivery = isScreenTransitioning && currentScreen != .calibration
        let captureSnapshot = externalOCRMultiCamCoordinator.snapshot
        let captureMode = externalOCRMultiCamCoordinator.activeModeSnapshot
        let captureOwnsBroadcast = captureSnapshot.isActive && captureMode.requiresBroadcast
        let captureOwnsOCR = captureSnapshot.isActive && captureMode.requiresOCR
        // Stage 7 uses frame freshness from the single CaptureEngine. Preview
        // presentation state is no longer part of OCR gating.
        let freshBroadcastFrame = RinkLensFrameHub.shared.latestEvidence(
            for: .broadcast,
            maxAge: recordingActive ? 2.0 : 1.0
        ) != nil
        let broadcastLivePreviewBlocked = currentScreen == .broadcast
            && !recordingActive
            && (!captureOwnsBroadcast || !freshBroadcastFrame)
        let broadcastPromotionBlocked = currentScreen == .broadcast && (!broadcastOCRPromotionActive || CFAbsoluteTimeGetCurrent() < broadcastOCRPromotionBlockedUntil || broadcastLivePreviewBlocked)
        let broadcastBackgroundOCRAllowed = currentScreen == .broadcast && userWantsOCRRunning
        let enabled = (usesScoreboardCameraInput || broadcastBackgroundOCRAllowed) && userWantsOCRRunning && !isOCRPaused && !transitionBlocksDelivery && !broadcastPromotionBlocked
        let interval: CFTimeInterval
        if performanceSafeModeEnabled {
            interval = currentScreen == .calibration ? 0.75 : 2.0
        } else if currentScreen == .calibration {
            interval = calibrationCropPreviewArmedUntil > CFAbsoluteTimeGetCurrent() ? 0.25 : 0.75
        } else if currentScreen == .live {
            interval = localClockIsRunning ? 1.50 : 0.75
        } else if currentScreen == .broadcast {
            // UX16c28: the previous 2.0/1.25-second gate made the production
            // scorebug visibly lag the scoreboard. MultiCam already bounds its
            // output queues to the newest frame, so process one OCR sample at the
            // standard scheduler cadence while keeping recognition serialised.
            interval = 0.70
        } else {
            interval = 1.50
        }

        let intervalChanged: Bool
        if let last = lastAppliedFramePolicyInterval {
            intervalChanged = abs(last - interval) > 0.001
        } else {
            intervalChanged = true
        }
        let policyChanged = lastAppliedFramePolicyEnabled != enabled || intervalChanged

        if isTransitionPublishFrozen && !force {
            pendingFramePolicyRefreshAfterFreeze = true
            MainThreadStallMonitor.shared.trace("swiftui invalidation suppressed: frame policy coalesced enabled=\(enabled) min=\(String(format: "%.2f", interval))")
            return
        }

        guard force || policyChanged else {
            MainThreadStallMonitor.shared.trace("swiftui invalidation suppressed: duplicate frame policy ignored")
            return
        }

        if broadcastLivePreviewBlocked {
            MainThreadStallMonitor.shared.trace("Broadcast OCR hard gate: CaptureEngine Broadcast branch/frame not ready")
            keepBroadcastPreviewAlive(reason: "frame policy found broadcast preview not ready")
        } else if broadcastPromotionBlocked {
            MainThreadStallMonitor.shared.trace("Broadcast OCR hard gate: frame delivery held preview-only")
        }

        if captureOwnsBroadcast && captureOwnsOCR && enabled {
            MainThreadStallMonitor.shared.trace("UX16c35 Broadcast OCR gate open: CaptureEngine dual frames flowing")
        }

        lastAppliedFramePolicyEnabled = enabled
        lastAppliedFramePolicyInterval = interval

        // Build 766 / RL-011: FrameHub owns the only continuous frame-delivery
        // binding. This method retains operator processing policy and diagnostics,
        // but it no longer mutates a second camera-facade callback gate.
        _ = recordingActive
        _ = captureOwnsOCR
    }

    private func enrichDebugTextWithStability(_ text: String?) -> String? {
        guard let text else { return nil }
        return text
            .split(separator: "\n")
            .map { line in
                let l = String(line)
                guard let keyToken = l.split(separator: ":").first else { return l }
                let key = String(keyToken)
                let stability = ocrSmoothingEngine.stabilityCount(for: key)
                return "\(l) stability=\(stability)"
            }
            .joined(separator: "\n")
    }

    private func updateRegionPreviewText(from rawText: String?) {
        guard let rawText else {
            regionOCRPreview = Dictionary(uniqueKeysWithValues: OCRRegionKey.allCases.map { ($0, "--") })
            regionOCRRecognizer = Dictionary(uniqueKeysWithValues: OCRRegionKey.allCases.map { ($0, .vision) })
            return
        }
        var next = regionOCRPreview
        for line in rawText.split(separator: "\n") {
            let textLine = String(line)
            guard let separator = textLine.firstIndex(of: ":") else { continue }
            let keyToken = String(textLine[..<separator])
            guard let key = OCRRegionKey(rawValue: keyToken) else { continue }

            let accepted = tokenValue("accepted=", in: textLine)
            let cleaned = tokenValue("cleaned=", in: textLine)
            let raw = tokenValue("raw=", in: textLine)
            let validation = tokenValue("validation=", in: textLine)

            if !accepted.isEmpty && accepted != "RETAIN" {
                next[key] = accepted
            } else if !cleaned.isEmpty {
                next[key] = cleaned
            } else if !raw.isEmpty {
                next[key] = raw
            } else if !validation.isEmpty {
                next[key] = "-- (\(validation))"
            } else {
                next[key] = "No text"
            }
        }
        regionOCRPreview = next
    }

    private func tokenValue(_ token: String, in line: String) -> String {
        guard let range = line.range(of: token) else { return "" }
        let after = line[range.upperBound...]
        return after.split(separator: " ").first.map { String($0) } ?? ""
    }

    private func updateRegionRecognizers(from fieldDebug: [ScoreboardOCRProcessor.OCRFieldDebug]) {
        var next = regionOCRRecognizer
        for field in fieldDebug {
            next[field.key] = field.recognizer
        }
        regionOCRRecognizer = next
    }

    func isActivePenaltyClock(_ clock: String?) -> Bool {
        guard let clock, let seconds = seconds(from: clock) else { return false }
        return seconds > 0
    }

    func formatPenaltyClock(seconds: Int) -> String {
        let clamped = max(0, min(seconds, 600))
        return String(format: "%d:%02d", clamped / 60, clamped % 60)
    }

    private func seconds(from clock: String) -> Int? {
        OCRValidationEngine.seconds(fromGameClock: clock)
    }

    private static let teamIdentityLogoImageCache = NSCache<NSString, UIImage>()

    private func loadTemplateAssetImage(fileName: String?) -> UIImage? {
        guard let fileName else { return nil }
        let cacheKey = fileName as NSString
        if let cached = Self.teamIdentityLogoImageCache.object(forKey: cacheKey) {
            return cached
        }
        let url = templateStore.assetURL(for: fileName)
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil }
        // Recovery AX / RL-013: this is a derived decode cache, not profile truth.
        // Stable UIImage identity also lets RinkLensTeamIdentityStore's existing
        // no-op summary suppress repeated taps on an already-applied saved profile.
        Self.teamIdentityLogoImageCache.setObject(image, forKey: cacheKey)
        return image
    }

    private func persistTeamLogo(data: Data, existing: String?) -> String? {
        // UX7: do not overwrite a logo file that is referenced by another
        // saved profile. Earlier builds reused the same filename when a profile
        // was duplicated or reconfigured, so changing the current logo could
        // unexpectedly change older saved profiles. Fork the asset when shared.
        let shouldForkSharedAsset = existing.map { logoFileIsReferencedByAnotherProfile($0) } ?? false
        let fileName = shouldForkSharedAsset ? "team_logo_\(UUID().uuidString).png" : (existing ?? "team_logo_\(UUID().uuidString).png")
        let url = templateStore.assetURL(for: fileName)
        try? data.write(to: url, options: .atomic)
        return fileName
    }

    private func logoFileIsReferencedByAnotherProfile(_ fileName: String) -> Bool {
        guard !fileName.isEmpty else { return false }
        return teamIdentityTemplates.contains { template in
            template.id != selectedTeamIdentityTemplateID &&
            (template.homeLogoFileName == fileName || template.awayLogoFileName == fileName)
        }
    }

    private func syncActiveTeamIdentityTemplateLogo(home: String?, away: String?) {
        guard let selectedTeamIdentityTemplateID,
              teamIdentityTemplates.contains(where: { $0.id == selectedTeamIdentityTemplateID }) else { return }
        teamIdentityStore.updateTemplate(
            id: selectedTeamIdentityTemplateID,
            source: "HockeyScoreboardViewModel",
            reason: "Synchronise active profile logo references"
        ) { template in
            template.homeLogoFileName = home
            template.awayLogoFileName = away
            template.scoreboardSettings = BroadcastScoreboardLayoutSettings.shared.templateSettings
        }
        persistTeamIdentityTemplates()
    }

    private func removeTeamLogoIfUnused(named fileName: String?) {
        guard let fileName, !fileName.isEmpty else { return }

        if homeLogoFileName == fileName || awayLogoFileName == fileName { return }
        let stillReferenced = teamIdentityTemplates.contains { template in
            template.homeLogoFileName == fileName || template.awayLogoFileName == fileName
        }
        guard !stillReferenced else { return }

        let url = templateStore.assetURL(for: fileName)
        try? FileManager.default.removeItem(at: url)
    }

    private func loadTeamIdentityTemplates() {
        guard let data = try? Data(contentsOf: teamTemplatesURL),
              let decoded = try? JSONDecoder().decode([TeamIdentityTemplate].self, from: data) else { return }
        teamIdentityTemplates = decoded
    }

    private func persistTeamIdentityTemplates() {
        guard let data = try? JSONEncoder().encode(teamIdentityTemplates) else { return }
        try? data.write(to: teamTemplatesURL, options: .atomic)
    }

    private func loadSelectedTeamIdentityTemplateID() {
        guard
            let raw = UserDefaults.standard.string(forKey: "IceCast.selectedTeamIdentityTemplateID"),
            let id = UUID(uuidString: raw),
            teamIdentityTemplates.contains(where: { $0.id == id })
        else {
            selectedTeamIdentityTemplateID = nil
            return
        }
        selectedTeamIdentityTemplateID = id
    }

    private func persistSelectedTeamIdentityTemplateID() {
        if let selectedTeamIdentityTemplateID {
            UserDefaults.standard.set(
                selectedTeamIdentityTemplateID.uuidString,
                forKey: "IceCast.selectedTeamIdentityTemplateID")
        } else {
            UserDefaults.standard.removeObject(forKey: "IceCast.selectedTeamIdentityTemplateID")
        }
    }

    private func loadDefaultTeamIdentityTemplateID() {
        guard let raw = UserDefaults.standard.string(forKey: "IceCast.defaultTeamIdentityTemplateID"),
              let id = UUID(uuidString: raw),
              teamIdentityTemplates.contains(where: { $0.id == id }) else {
            defaultTeamIdentityTemplateID = nil
            return
        }
        defaultTeamIdentityTemplateID = id
    }

    private func persistDefaultTeamIdentityTemplateID() {
        if let defaultTeamIdentityTemplateID {
            UserDefaults.standard.set(defaultTeamIdentityTemplateID.uuidString, forKey: "IceCast.defaultTeamIdentityTemplateID")
        } else {
            UserDefaults.standard.removeObject(forKey: "IceCast.defaultTeamIdentityTemplateID")
        }
    }

    private var teamTemplatesURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("RinkTemplates", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("team_identity_templates.json")
    }

    private func scoreStateFromDefaults() -> ScoreboardState {
        ScoreboardState(
            homeTeam: teamIdentityStore.homeTeamName,
            awayTeam: teamIdentityStore.awayTeamName,
            homeScore: defaultHomeGoals,
            awayScore: defaultAwayGoals,
            clock: normalizedClock(defaultClock),
            period: periodValue(from: defaultPeriodOption),
            homeShots: nil,
            awayShots: nil,
            homePenalty1Player: clampedPlayer(defaultHomePenalty1Player),
            homePenalty1Clock: normalizedPenaltyClock(defaultHomePenalty1Clock),
            homePenalty2Player: clampedPlayer(defaultHomePenalty2Player),
            homePenalty2Clock: normalizedPenaltyClock(defaultHomePenalty2Clock),
            awayPenalty1Player: clampedPlayer(defaultAwayPenalty1Player),
            awayPenalty1Clock: normalizedPenaltyClock(defaultAwayPenalty1Clock),
            awayPenalty2Player: clampedPlayer(defaultAwayPenalty2Player),
            awayPenalty2Clock: normalizedPenaltyClock(defaultAwayPenalty2Clock)
        )
    }

    private func persistDefaultScoreboardValuesIfReady() {
        guard !isLoadingDefaultValues else { return }
        persistDefaultScoreboardValues()
    }

    private func loadDefaultScoreboardValues() {
        guard let data = try? Data(contentsOf: defaultScoreboardValuesURL),
              let decoded = try? JSONDecoder().decode(DefaultScoreboardValues.self, from: data) else { return }

        defaultClock = normalizedClock(decoded.clock)
        defaultHomeGoals = clampedScore(decoded.homeGoals)
        defaultAwayGoals = clampedScore(decoded.awayGoals)
        defaultPeriodOption = normalizedPeriodOption(decoded.periodOption)
        defaultPeriod = periodValue(from: defaultPeriodOption)
        defaultHomePenalty1Player = clampedPlayer(decoded.homePenalty1Player)
        defaultHomePenalty1Clock = normalizedPenaltyClock(decoded.homePenalty1Clock)
        defaultHomePenalty2Player = clampedPlayer(decoded.homePenalty2Player)
        defaultHomePenalty2Clock = normalizedPenaltyClock(decoded.homePenalty2Clock)
        defaultAwayPenalty1Player = clampedPlayer(decoded.awayPenalty1Player)
        defaultAwayPenalty1Clock = normalizedPenaltyClock(decoded.awayPenalty1Clock)
        defaultAwayPenalty2Player = clampedPlayer(decoded.awayPenalty2Player)
        defaultAwayPenalty2Clock = normalizedPenaltyClock(decoded.awayPenalty2Clock)
    }

    private func persistDefaultScoreboardValues() {
        let payload = DefaultScoreboardValues(
            clock: normalizedClock(defaultClock),
            homeGoals: clampedScore(defaultHomeGoals),
            awayGoals: clampedScore(defaultAwayGoals),
            period: periodValue(from: defaultPeriodOption),
            periodOption: normalizedPeriodOption(defaultPeriodOption),
            homePenalty1Player: clampedPlayer(defaultHomePenalty1Player),
            homePenalty1Clock: normalizedPenaltyClock(defaultHomePenalty1Clock),
            homePenalty2Player: clampedPlayer(defaultHomePenalty2Player),
            homePenalty2Clock: normalizedPenaltyClock(defaultHomePenalty2Clock),
            awayPenalty1Player: clampedPlayer(defaultAwayPenalty1Player),
            awayPenalty1Clock: normalizedPenaltyClock(defaultAwayPenalty1Clock),
            awayPenalty2Player: clampedPlayer(defaultAwayPenalty2Player),
            awayPenalty2Clock: normalizedPenaltyClock(defaultAwayPenalty2Clock)
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: defaultScoreboardValuesURL, options: .atomic)
    }

    private func clampedScore(_ value: Int) -> Int {
        max(0, min(99, value))
    }

    func clampedPeriod(_ value: Int) -> Int {
        max(1, min(5, value))
    }

    func normalizedPeriodOption(_ value: String) -> String {
        let upper = value.uppercased()
        let allowed = ["1", "2", "3", "4", "5", "OT", "SO"]
        return allowed.contains(upper) ? upper : "1"
    }

    private func periodValue(from option: String) -> Int {
        switch normalizedPeriodOption(option) {
        case "OT": return 4
        case "SO": return 5
        default: return Int(option) ?? 1
        }
    }

    private func clampedPlayer(_ value: Int) -> Int {
        max(0, min(99, value))
    }

    private func normalizedClock(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "--:--" {
            return "--:--"
        }
        let parts = trimmed.split(separator: ":")
        guard parts.count == 2,
              let minutes = Int(parts[0]),
              let seconds = Int(parts[1]),
              (0...59).contains(seconds),
              (0...20).contains(minutes) else {
            return "20:00"
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func normalizedPenaltyClock(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "--:--" {
            return "--:--"
        }
        let parts = trimmed.split(separator: ":")
        guard parts.count == 2,
              let minutes = Int(parts[0]),
              let seconds = Int(parts[1]),
              (0...59).contains(seconds),
              (0...10).contains(minutes) else {
            return "--:--"
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var defaultScoreboardValuesURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("RinkTemplates", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("default_scoreboard_values.json")
    }
}

// MARK: - Image Relay diagnostics compatibility
//
// Keep these shared diagnostics as an explicit type extension. This prevents
// Swift batch-compilation from treating the properties as unavailable to the
// recovery and diagnostics panels when the target uses MainActor-by-default.
extension HockeyScoreboardViewModel {
    var imageRelayStatusText: String {
        let snapshot = ScoreboardImageRelayStore.shared.snapshot()
        if snapshot.isFresh { return "Image Relay Live" }
        if snapshot.enabled { return "Image Relay Waiting for Frame" }
        return "Image Relay Off"
    }

    var imageRelayDiagnosticText: String {
        let snapshot = ScoreboardImageRelayStore.shared.snapshot()
        let pipeline = scoreboardFramePipeline.snapshot()
        let executionPlan = scoreboardFrameExecutionPlanStore.snapshot()
        return "\(snapshot.diagnosticText); framePipeline={\(pipeline.diagnosticText)}; executionPlan={mode=\(executionPlan.mode.rawValue) revision=\(executionPlan.revision)}; uiInvalidation={forwarded=\(architectureInvalidationForwardedCount) suppressed=\(architectureInvalidationSuppressedCount)}; engine={\(imageRelayEngine.diagnosticText)}"
    }
}

#endif
