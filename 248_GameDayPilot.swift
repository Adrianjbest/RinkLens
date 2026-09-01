// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import Foundation
@preconcurrency import AVFoundation

// MARK: - UX16c49 game-day pilot

/// A passive game-day validation layer: observer, workflow gate, and evidence ledger only.
/// It never owns capture, OCR, recording,
/// routing, clips, or recovery. The operator uses the production screens; this
/// controller records evidence and applies the promotion gates across fixtures.
@MainActor
final class RinkLensGameDayPilotController: ObservableObject {
    static let shared = RinkLensGameDayPilotController()

    enum Phase: String, Sendable {
        case idle = "Not started"
        case preflight = "Pre-face-off checks"
        case liveFixture = "Monitored fixture"
        case completed = "Fixture completed"
    }

    enum PreflightCheckpoint: String, CaseIterable, Identifiable, Sendable {
        case knownGoodProfile = "Known-good saved camera and rink profile confirmed"
        case manualFallbackPrepared = "Manual scoreboard fallback prepared"
        case broadcastFallbackTested = "Broadcast-only fallback tested and dual-camera restored"
        case noExperimentalRecovery = "No experimental auto-recovery change enabled"

        var id: String { rawValue }
    }

    enum FixtureCheckpoint: String, CaseIterable, Identifiable, Sendable {
        case fullFixtureCompleted = "Complete fixture and recording finished"
        case manualClipSaved = "At least one manual clip saved"

        var id: String { rawValue }
    }

    enum LogMilestone: String, CaseIterable, Identifiable, Hashable, Sendable {
        case periodOne = "Period 1 break"
        case periodTwo = "Period 2 break"
        case postMatch = "After match"

        var id: String { rawValue }
        var shortLabel: String {
            switch self {
            case .periodOne: return "Export P1 Logs"
            case .periodTwo: return "Export P2 Logs"
            case .postMatch: return "Export Post-Match Logs"
            }
        }
    }

    struct FixtureResult: Codable, Identifiable, Sendable {
        let id: UUID
        let completedAt: Date
        let passed: Bool
        let durationSeconds: TimeInterval
        let minimumCadencePercent: Double?
        let automaticScoreEvents: Int
        let failureReasons: [String]
    }

    @Published private(set) var uiRevision: UInt64 = 0
    private(set) var phase: Phase = .idle
    private(set) var statusText = "No game-day pilot running"
    private(set) var elapsedText = "00:00"
    private(set) var prerequisiteText = "UX16c48 controlled-rink pass not recorded"
    private(set) var profileText = "Saved profile not sampled"
    private(set) var captureText = "Capture not sampled"
    private(set) var recordingText = "Recording not sampled"
    private(set) var ocrText = "OCR not sampled"
    private(set) var lifecycleText = "Lifecycle not sampled"
    private(set) var buffersText = "Dropped frames not sampled"
    private(set) var pressureText = "System pressure not sampled"
    private(set) var automaticScoreText = "No automatic score event observed"
    private(set) var logsText = "Period-break and post-match logs not exported"
    private(set) var promotionText = "Promotion evidence not available"
    private(set) var acceptanceLines: [String] = ["Complete UX16c48 before starting a monitored fixture."]
    private(set) var recentEvents: [String] = []
    private(set) var completedPreflightCheckpoints: Set<PreflightCheckpoint> = []
    private(set) var completedFixtureCheckpoints: Set<FixtureCheckpoint> = []
    private(set) var completedLogMilestones: Set<LogMilestone> = []
    private(set) var lastLogURL: URL?
    private(set) var logExportInProgress = false
    private(set) var fixtureResults: [FixtureResult] = []
    private(set) var requiredCleanFixtures = 3

    private var sampleTask: Task<Void, Never>?
    private var startedAt: Date?
    private var faceOffAt: Date?
    private var stoppedAt: Date?
    private var initialDiagnosticsMode: RuntimeDiagnosticsMode = .production
    private var fixtureResultRecorded = false

    private var initialCaptureGeneration = 0
    private var initialLiveDeviceID: String?
    private var initialOCRDeviceID: String?
    private var initialLiveCapabilityProfileID: String?
    private var initialOCRCapabilityProfileID: String?
    private var initialRinkTemplateID: UUID?
    private var initialSavedRecordings = 0
    private var initialSavedManualHighlights = 0
    private var initialLiveOutOfBuffers = 0
    private var initialOCROutOfBuffers = 0
    private var initialLiveDroppedFrames = 0
    private var initialOCRDroppedFrames = 0
    private var initialDesiredRevision: UInt64 = 0
    private var initialReconciliationCount = 0
    private var initialRouteActivationCount = 0

    private var lastDesiredRevision: UInt64 = 0
    private var lastReconciliationCount = 0
    private var lastRouteActivationCount = 0
    private var lifecycleRequestTimes: [Date] = []
    private var peakLifecycleRequestsPerMinute = 0
    private let requestStormLimitPerMinute = 6

    private var lastCapturePhase = RinkLensCaptureEnginePhase.stopped
    private var captureUnhealthyLatched = false
    private var captureLossCount = 0
    private var captureRecoveryTimes: [Date] = []
    private var blackFrameRecoveryLoopDetected = false
    private var maximumConsecutiveBlackFrames = 0
    private var cameraOrProfileChangeCount = 0
    private var matchDayModeDeviationCount = 0
    private var unexpectedSceneInterruptions = 0
    private var routeChanges = 0
    private var operatorRecoveryActionCount = 0

    private var lastRecordingState = BroadcastRecordingManager.RecordingState.idle
    private var recordingObserved = false
    private var recordingStartedAt: Date?
    private var recordingStoppedNormally = false
    private var recordingFailureCount = 0
    private var recordingPauseCount = 0
    private var savedRecordingDelta = 0
    private var manualClipDelta = 0
    private var minimumRecordingCadencePercent: Double?

    private var lastOCRCompletedPasses = 0
    private var lastOCRProgressAt: Date?
    private var ocrFreezeLatched = false
    private var ocrFreezeCount = 0
    private var consecutiveOCRNotRunningSamples = 0
    private var ocrInterruptionCount = 0
    private var ocrRunningObserved = false

    private var lastHomeScore: Int?
    private var lastAwayScore: Int?
    private var automaticScoreEventCount = 0
    private var reviewedAutomaticScoreEventCount = 0
    private var incorrectAutomaticScoreEventCount = 0
    private var latestIncorrectMarkedEventIndex = 0

    private var seriousPressureSamples = 0
    private var criticalPressureSamples = 0
    private var sampleSequence: UInt64 = 0

    private let defaults = UserDefaults.standard
    private let historyKey = "RinkLens.UX16c49.fixtureResults"
    private let requiredFixturesKey = "RinkLens.UX16c49.requiredCleanFixtures"

    private init() {
        requiredCleanFixtures = [2, 3].contains(defaults.integer(forKey: requiredFixturesKey))
            ? defaults.integer(forKey: requiredFixturesKey)
            : 3
        fixtureResults = Self.loadFixtureResults(defaults: defaults, key: historyKey)
        updatePromotionText()
    }

    var isRunning: Bool {
        phase == .preflight || phase == .liveFixture
    }

    var cleanFixtureCount: Int {
        fixtureResults.filter(\.passed).count
    }

    var promotionEligible: Bool {
        cleanFixtureCount >= requiredCleanFixtures
    }

    var controlledRinkPilotPassed: Bool {
        RinkLensControlledPilotController.shared.promotionGatePassed
    }

    func setRequiredCleanFixtures(_ count: Int) {
        guard !isRunning, [2, 3].contains(count) else { return }
        requiredCleanFixtures = count
        defaults.set(count, forKey: requiredFixturesKey)
        updatePromotionText()
        publishUI()
    }

    func startPreflight() {
        guard !isRunning else { return }
        guard controlledRinkPilotPassed else {
            statusText = "Blocked — UX16c48 controlled-rink pilot must pass first"
            prerequisiteText = "FAIL — no UX16c48 pass recorded"
            acceptanceLines = ["FAIL — complete and pass UX16c48 before game-day use."]
            appendEvent("start blocked because UX16c48 pass was not recorded")
            publishUI()
            return
        }
        if phase == .completed {
            MainThreadStallMonitor.shared.setDiagnosticsMode(initialDiagnosticsMode, reason: "UX16c49 fixture restarted")
        }

        resetCurrentFixture(restoreDiagnosticsMode: false)
        let container = AppContainer.shared
        let viewModel = container.scoreboardViewModel
        let capture = container.captureEngine.snapshot
        let recorder = BroadcastRecordingManager.shared
        let lifecycle = viewModel.captureLifecycleController

        startedAt = Date()
        phase = .preflight
        initialDiagnosticsMode = MainThreadStallMonitor.shared.diagnosticsMode
        MainThreadStallMonitor.shared.setDiagnosticsMode(.matchDaySafe, reason: "UX16c49 monitored fixture preflight")

        initialCaptureGeneration = capture.transitionGeneration
        initialLiveDeviceID = viewModel.liveCameraService.selectedCameraID
        initialOCRDeviceID = viewModel.ocrCameraService.selectedCameraID
        initialLiveCapabilityProfileID = viewModel.liveCameraService.selectedCapabilityProfileID
        initialOCRCapabilityProfileID = viewModel.ocrCameraService.selectedCapabilityProfileID
        initialRinkTemplateID = viewModel.templateStore.activeTemplateID
        initialSavedRecordings = recorder.savedRecordingsCount
        initialSavedManualHighlights = recorder.savedManualHighlightsCount
        initialLiveOutOfBuffers = capture.liveDroppedOutOfBuffersLifetime
        initialOCROutOfBuffers = capture.ocrDroppedOutOfBuffersLifetime
        initialLiveDroppedFrames = capture.liveDroppedFramesLifetime
        initialOCRDroppedFrames = capture.ocrDroppedFramesLifetime
        initialDesiredRevision = lifecycle.desiredContractRevision
        initialReconciliationCount = lifecycle.reconciliationExecutionCount
        initialRouteActivationCount = viewModel.routeLifecycleActivationCount
        lastDesiredRevision = lifecycle.desiredContractRevision
        lastReconciliationCount = lifecycle.reconciliationExecutionCount
        lastRouteActivationCount = viewModel.routeLifecycleActivationCount
        lastCapturePhase = capture.phase
        lastRecordingState = recorder.state
        lastOCRCompletedPasses = viewModel.ocrOrchestrationSnapshot.completedPasses
        lastOCRProgressAt = Date()
        lastHomeScore = viewModel.state.homeScore
        lastAwayScore = viewModel.state.awayScore

        statusText = "Pre-face-off: complete all controls, then begin the monitored fixture"
        prerequisiteText = "PASS — UX16c48 controlled-rink pilot recorded"
        appendEvent("game-day preflight started; Match Day Safe enabled")
        sampleNow(forcePublish: true)

        sampleTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.isRunning {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
                guard self.isRunning, !Task.isCancelled else { return }
                self.sampleNow(forcePublish: false)
            }
        }
    }

    func beginFixture() {
        guard phase == .preflight else { return }
        sampleNow(forcePublish: true)
        let missing = PreflightCheckpoint.allCases.filter { !completedPreflightCheckpoints.contains($0) }
        guard missing.isEmpty else {
            statusText = "Complete all pre-face-off controls before beginning the fixture"
            appendEvent("face-off blocked; missing controls: \(missing.map(\.rawValue).joined(separator: ", "))")
            updatePublishedSummary()
            return
        }
        guard automaticPreflightReady else {
            statusText = "Correct the saved profile, camera roles, graph, or Match Day Safe mode before face-off"
            appendEvent("face-off blocked by automatic preflight")
            updatePublishedSummary()
            return
        }

        faceOffAt = Date()
        establishLiveFixtureBaseline()
        phase = .liveFixture
        lastOCRProgressAt = Date()
        statusText = "Monitored fixture active — remain in Match Day Safe mode"
        appendEvent("face-off marked; fixture monitoring active")
        sampleNow(forcePublish: true)
    }

    func finishFixture() {
        guard phase == .liveFixture else { return }
        let recorder = BroadcastRecordingManager.shared
        guard recorder.state == .idle || recorder.state == .failed else {
            statusText = "Stop and finalise the full-match recording before finishing"
            appendEvent("finish blocked while recording state=\(recorder.state.rawValue)")
            updatePublishedSummary()
            return
        }
        guard completedFixtureCheckpoints.contains(.fullFixtureCompleted) else {
            statusText = "Confirm that the complete fixture and recording are finished"
            appendEvent("finish blocked because complete fixture checkpoint is not confirmed")
            updatePublishedSummary()
            return
        }
        guard completedLogMilestones.contains(.postMatch) else {
            statusText = "Export the post-match All Logs file before finishing"
            appendEvent("finish blocked because post-match logs were not exported")
            updatePublishedSummary()
            return
        }

        sampleNow(forcePublish: true)
        stoppedAt = Date()
        sampleTask?.cancel()
        sampleTask = nil
        phase = .completed
        let failures = currentFailureReasons()
        let passed = failures.isEmpty
        statusText = passed ? "Fixture passed all UX16c49 gates" : "Fixture completed with \(failures.count) promotion blocker(s)"

        if !fixtureResultRecorded {
            let duration = stoppedAt.map { end in faceOffAt.map { end.timeIntervalSince($0) } ?? 0 } ?? 0
            let result = FixtureResult(
                id: UUID(),
                completedAt: stoppedAt ?? Date(),
                passed: passed,
                durationSeconds: duration,
                minimumCadencePercent: minimumRecordingCadencePercent,
                automaticScoreEvents: automaticScoreEventCount,
                failureReasons: failures
            )
            fixtureResults.append(result)
            fixtureResults = Array(fixtureResults.suffix(12))
            persistFixtureResults()
            fixtureResultRecorded = true
        }
        appendEvent(passed ? "fixture recorded as clean" : "fixture recorded with blockers: \(failures.joined(separator: "; "))")
        updatePublishedSummary()
    }

    func reset() {
        guard !isRunning else { return }
        resetCurrentFixture(restoreDiagnosticsMode: true)
        phase = .idle
        statusText = "Game-day pilot reset; promotion history retained"
        updatePromotionText()
        publishUI()
    }

    func clearPromotionHistory() {
        guard !isRunning else { return }
        fixtureResults.removeAll()
        defaults.removeObject(forKey: historyKey)
        updatePromotionText()
        appendEvent("promotion fixture history cleared")
        publishUI()
    }

    func togglePreflightCheckpoint(_ checkpoint: PreflightCheckpoint) {
        guard phase == .preflight else { return }
        if completedPreflightCheckpoints.contains(checkpoint) {
            completedPreflightCheckpoints.remove(checkpoint)
            appendEvent("preflight control cleared: \(checkpoint.rawValue)")
        } else {
            completedPreflightCheckpoints.insert(checkpoint)
            appendEvent("preflight control confirmed: \(checkpoint.rawValue)")
        }
        updatePublishedSummary()
    }

    func preflightCheckpointIsComplete(_ checkpoint: PreflightCheckpoint) -> Bool {
        completedPreflightCheckpoints.contains(checkpoint)
    }

    func toggleFixtureCheckpoint(_ checkpoint: FixtureCheckpoint) {
        guard phase == .liveFixture else { return }
        if completedFixtureCheckpoints.contains(checkpoint) {
            completedFixtureCheckpoints.remove(checkpoint)
            appendEvent("fixture checkpoint cleared: \(checkpoint.rawValue)")
        } else {
            completedFixtureCheckpoints.insert(checkpoint)
            appendEvent("fixture checkpoint confirmed: \(checkpoint.rawValue)")
        }
        updatePublishedSummary()
    }

    func fixtureCheckpointIsComplete(_ checkpoint: FixtureCheckpoint) -> Bool {
        completedFixtureCheckpoints.contains(checkpoint)
    }

    func confirmAutomaticScoreEventsCorrect() {
        guard phase == .liveFixture else { return }
        reviewedAutomaticScoreEventCount = automaticScoreEventCount
        appendEvent("automatic score events reviewed as correct through event \(automaticScoreEventCount)")
        updatePublishedSummary()
    }

    func markLatestAutomaticScoreEventIncorrect() {
        guard phase == .liveFixture, automaticScoreEventCount > latestIncorrectMarkedEventIndex else { return }
        incorrectAutomaticScoreEventCount &+= 1
        latestIncorrectMarkedEventIndex = automaticScoreEventCount
        reviewedAutomaticScoreEventCount = max(reviewedAutomaticScoreEventCount, automaticScoreEventCount)
        appendEvent("FAIL automatic score event \(automaticScoreEventCount) marked incorrect")
        updatePublishedSummary()
    }

    func noteScenePhase(_ scenePhase: ScenePhase) {
        guard phase == .liveFixture else { return }
        switch scenePhase {
        case .inactive, .background:
            unexpectedSceneInterruptions &+= 1
            appendEvent("fixture scene interruption: \(scenePhase == .inactive ? "inactive" : "background")")
        case .active:
            break
        @unknown default:
            break
        }
        updatePublishedSummary()
    }

    func noteRouteChange(_ route: AppRoute) {
        guard isRunning else { return }
        routeChanges &+= 1
        appendEvent("route changed to \(route.title)")
        updatePublishedSummary()
    }

    func noteOperatorRecoveryAction(_ action: String) {
        guard isRunning else { return }
        operatorRecoveryActionCount &+= 1
        appendEvent("operator recovery action: \(action)")
        updatePublishedSummary()
    }

    func exportLogs(
        milestone: LogMilestone,
        viewModel: HockeyScoreboardViewModel,
        cameraService: HockeyCameraService
    ) async {
        guard isRunning, !logExportInProgress else { return }
        guard !completedLogMilestones.contains(milestone) else {
            logsText = "\(milestone.rawValue) export already completed"
            publishUI()
            return
        }
        if milestone == .postMatch {
            guard BroadcastRecordingManager.shared.state == .idle || BroadcastRecordingManager.shared.state == .failed else {
                logsText = "Stop and finalise recording before the post-match export"
                publishUI()
                return
            }
        } else {
            guard phase == .liveFixture, BroadcastRecordingManager.shared.state == .recording else {
                logsText = "Period-break exports require the monitored full-match recording to remain active"
                publishUI()
                return
            }
        }

        let recorder = BroadcastRecordingManager.shared
        let before = AppContainer.shared.captureEngine.snapshot
        let framesBefore = recorder.framesWritten
        logExportInProgress = true
        logsText = "Exporting \(milestone.rawValue) All Logs…"
        appendEvent("\(milestone.rawValue) All Logs export started")
        publishUI()

        let url = await DiagnosticsLogExporter.shared.exportAllLogs(
            viewModel: viewModel,
            cameraService: cameraService
        )
        do {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        } catch {
            // The evidence check below is authoritative.
        }

        let after = AppContainer.shared.captureEngine.snapshot
        let freshBroadcastFrame = RinkLensFrameHub.shared.latestEvidence(
            for: .broadcast,
            maxAge: 1.5,
            requiredCaptureGeneration: after.transitionGeneration,
            requiredPhysicalDeviceID: after.liveDeviceID
        ) != nil
        let generationUnchanged = before.transitionGeneration == after.transitionGeneration
        let graphHealthy = after.phase == .running && after.sessionRunning && after.activeMode.requiresBroadcast
        let periodRecordingHealthy = milestone == .postMatch
            || (recorder.state == .recording && recorder.framesWritten > framesBefore)
        let passed = url != nil && generationUnchanged && graphHealthy && freshBroadcastFrame && periodRecordingHealthy

        if passed {
            completedLogMilestones.insert(milestone)
            lastLogURL = url
            logsText = "PASS — \(milestone.rawValue) logs saved without capture interruption"
            appendEvent("\(milestone.rawValue) All Logs export passed")
        } else {
            let reasons = [
                url == nil ? "file not created" : nil,
                !generationUnchanged ? "capture generation changed" : nil,
                !graphHealthy ? "Broadcast graph not healthy" : nil,
                !freshBroadcastFrame ? "no fresh Broadcast frame" : nil,
                !periodRecordingHealthy ? "recording did not remain active/advance" : nil
            ].compactMap { $0 }
            logsText = "FAIL — \(milestone.rawValue): \(reasons.joined(separator: ", "))"
            appendEvent(logsText)
        }
        logExportInProgress = false
        sampleNow(forcePublish: true)
    }

    func exportLines() -> [String] {
        let fixtureLines = fixtureResults.suffix(5).reversed().map { result in
            let outcome = result.passed ? "PASS" : "FAIL"
            let failures = result.failureReasons.isEmpty ? "none" : result.failureReasons.joined(separator: "; ")
            return "\(outcome) \(Self.timestampFormatter.string(from: result.completedAt)) duration=\(Self.durationText(result.durationSeconds)) cadence=\(result.minimumCadencePercent.map { String(format: "%.1f%%", $0) } ?? "--") autoScores=\(result.automaticScoreEvents) blockers={\(failures)}"
        }
        return [
            "Phase: \(phase.rawValue)",
            "Status: \(statusText)",
            "Controlled-rink prerequisite: \(controlledRinkPilotPassed ? "PASS" : "FAIL")",
            "Started: \(startedAt.map { Self.timestampFormatter.string(from: $0) } ?? "--")",
            "Face-off: \(faceOffAt.map { Self.timestampFormatter.string(from: $0) } ?? "--")",
            "Stopped: \(stoppedAt.map { Self.timestampFormatter.string(from: $0) } ?? "--")",
            "Elapsed: \(elapsedText)",
            "Profile: \(profileText)",
            "Capture: \(captureText)",
            "Recording: \(recordingText)",
            "OCR: \(ocrText)",
            "Lifecycle: \(lifecycleText)",
            "Buffers: \(buffersText)",
            "Pressure: \(pressureText)",
            "Automatic score audit: \(automaticScoreText)",
            "Logs: \(logsText)",
            "Promotion: \(promotionText)",
            "Acceptance:"
        ] + acceptanceLines + ["Fixture history:"] + fixtureLines + ["Recent events:"] + recentEvents
    }


    /// Rebase all promotion counters after the pre-face-off fallback test and
    /// restored dual-camera validation. Preflight transitions are evidence but
    /// are not misclassified as live-fixture request storms or capture drops.
    private func establishLiveFixtureBaseline() {
        let container = AppContainer.shared
        let viewModel = container.scoreboardViewModel
        let capture = container.captureEngine.snapshot
        let recorder = BroadcastRecordingManager.shared
        let lifecycle = viewModel.captureLifecycleController

        initialCaptureGeneration = capture.transitionGeneration
        initialLiveDeviceID = viewModel.liveCameraService.selectedCameraID
        initialOCRDeviceID = viewModel.ocrCameraService.selectedCameraID
        initialLiveCapabilityProfileID = viewModel.liveCameraService.selectedCapabilityProfileID
        initialOCRCapabilityProfileID = viewModel.ocrCameraService.selectedCapabilityProfileID
        initialRinkTemplateID = viewModel.templateStore.activeTemplateID
        initialSavedRecordings = recorder.savedRecordingsCount
        initialSavedManualHighlights = recorder.savedManualHighlightsCount
        initialLiveOutOfBuffers = capture.liveDroppedOutOfBuffersLifetime
        initialOCROutOfBuffers = capture.ocrDroppedOutOfBuffersLifetime
        initialLiveDroppedFrames = capture.liveDroppedFramesLifetime
        initialOCRDroppedFrames = capture.ocrDroppedFramesLifetime
        initialDesiredRevision = lifecycle.desiredContractRevision
        initialReconciliationCount = lifecycle.reconciliationExecutionCount
        initialRouteActivationCount = viewModel.routeLifecycleActivationCount
        lastDesiredRevision = lifecycle.desiredContractRevision
        lastReconciliationCount = lifecycle.reconciliationExecutionCount
        lastRouteActivationCount = viewModel.routeLifecycleActivationCount
        lifecycleRequestTimes.removeAll()
        peakLifecycleRequestsPerMinute = 0

        lastCapturePhase = capture.phase
        captureUnhealthyLatched = false
        captureLossCount = 0
        captureRecoveryTimes.removeAll()
        blackFrameRecoveryLoopDetected = false
        maximumConsecutiveBlackFrames = Int(BlackFrameRejectionTraceStore.shared.consecutiveRejectedText) ?? 0
        cameraOrProfileChangeCount = 0
        matchDayModeDeviationCount = 0
        unexpectedSceneInterruptions = 0
        routeChanges = 0
        operatorRecoveryActionCount = 0

        lastRecordingState = recorder.state
        recordingObserved = false
        recordingStartedAt = nil
        recordingStoppedNormally = false
        recordingFailureCount = 0
        recordingPauseCount = 0
        savedRecordingDelta = 0
        manualClipDelta = 0
        minimumRecordingCadencePercent = nil

        lastOCRCompletedPasses = viewModel.ocrOrchestrationSnapshot.completedPasses
        lastOCRProgressAt = Date()
        ocrFreezeLatched = false
        ocrFreezeCount = 0
        consecutiveOCRNotRunningSamples = 0
        ocrInterruptionCount = 0
        ocrRunningObserved = false

        lastHomeScore = viewModel.state.homeScore
        lastAwayScore = viewModel.state.awayScore
        automaticScoreEventCount = 0
        reviewedAutomaticScoreEventCount = 0
        incorrectAutomaticScoreEventCount = 0
        latestIncorrectMarkedEventIndex = 0
        seriousPressureSamples = 0
        criticalPressureSamples = 0
        completedFixtureCheckpoints.removeAll()
        completedLogMilestones.removeAll()
        lastLogURL = nil
        logsText = "Period-break and post-match logs not exported"
        appendEvent("live-fixture counters rebased after fallback test and dual-camera restore")
    }

    private var automaticPreflightReady: Bool {
        let viewModel = AppContainer.shared.scoreboardViewModel
        let capture = AppContainer.shared.captureEngine.snapshot
        let broadcastBuiltInBack = !viewModel.liveCameraService.selectedCameraIsExternal
            && viewModel.liveCameraService.selectedCameraPosition == .back
        let ocrExternal = viewModel.ocrCameraService.selectedCameraIsExternal
        let savedProfile = viewModel.templateStore.activeTemplate != nil && !viewModel.hasUnsavedTemplateChanges
        let selectedIDs = viewModel.liveCameraService.selectedCameraID != nil
            && viewModel.ocrCameraService.selectedCameraID != nil
        let healthyDual = capture.activeMode == .dualCamera
            && capture.phase == .running
            && capture.sessionRunning
            && capture.liveDeviceID != nil
            && capture.ocrDeviceID != nil
        return controlledRinkPilotPassed
            && MainThreadStallMonitor.shared.diagnosticsMode == .matchDaySafe
            && savedProfile
            && selectedIDs
            && broadcastBuiltInBack
            && ocrExternal
            && healthyDual
    }

    private func sampleNow(forcePublish: Bool) {
        guard startedAt != nil else { return }
        sampleSequence &+= 1
        let now = Date()
        let container = AppContainer.shared
        let viewModel = container.scoreboardViewModel
        let capture = container.captureEngine.snapshot
        let recorder = BroadcastRecordingManager.shared
        let lifecycle = viewModel.captureLifecycleController
        let ocrSnapshot = viewModel.ocrOrchestrationSnapshot
        let frameHub = RinkLensFrameHub.shared.diagnosticSnapshot()

        if MainThreadStallMonitor.shared.diagnosticsMode != .matchDaySafe {
            matchDayModeDeviationCount &+= 1
        }

        observeLifecycleRequests(now: now, lifecycle: lifecycle, routeActivations: viewModel.routeLifecycleActivationCount)
        observeCapture(now: now, capture: capture)
        observeRecording(now: now, recorder: recorder, capture: capture)
        observeOCR(now: now, viewModel: viewModel, completedPasses: ocrSnapshot.completedPasses, frameHub: frameHub)
        observeAutomaticScoreChanges(viewModel: viewModel)
        observeConfiguration(viewModel: viewModel, capture: capture)

        savedRecordingDelta = max(0, recorder.savedRecordingsCount - initialSavedRecordings)
        manualClipDelta = max(0, recorder.savedManualHighlightsCount - initialSavedManualHighlights)

        let liveBuffers = max(0, capture.liveDroppedOutOfBuffersLifetime - initialLiveOutOfBuffers)
        let ocrBuffers = max(0, capture.ocrDroppedOutOfBuffersLifetime - initialOCROutOfBuffers)
        let liveDrops = max(0, capture.liveDroppedFramesLifetime - initialLiveDroppedFrames)
        let ocrDrops = max(0, capture.ocrDroppedFramesLifetime - initialOCRDroppedFrames)
        buffersText = "OutOfBuffers B/OCR \(liveBuffers)/\(ocrBuffers); all drops B/OCR \(liveDrops)/\(ocrDrops); last \(capture.lastDroppedFrameText)"

        let pressure = "Broadcast \(capture.liveSystemPressureLevel), OCR \(capture.ocrSystemPressureLevel)"
        if capture.liveSystemPressureLevel.lowercased().contains("critical") || capture.ocrSystemPressureLevel.lowercased().contains("critical") {
            criticalPressureSamples &+= 1
        } else if capture.liveSystemPressureLevel.lowercased().contains("serious") || capture.ocrSystemPressureLevel.lowercased().contains("serious") {
            seriousPressureSamples &+= 1
        }
        pressureText = "\(pressure); serious samples \(seriousPressureSamples), critical samples \(criticalPressureSamples)"

        updateEvidenceText(viewModel: viewModel, capture: capture, recorder: recorder, frameHub: frameHub)
        if forcePublish || sampleSequence % 2 == 0 {
            updatePublishedSummary()
        }
    }

    private func observeLifecycleRequests(
        now: Date,
        lifecycle: RinkLensCaptureLifecycleController,
        routeActivations: Int
    ) {
        let revisionDelta = lifecycle.desiredContractRevision >= lastDesiredRevision
            ? lifecycle.desiredContractRevision - lastDesiredRevision
            : 0
        let reconciliationDelta = max(0, lifecycle.reconciliationExecutionCount - lastReconciliationCount)
        let routeDelta = max(0, routeActivations - lastRouteActivationCount)
        let eventCount = min(100, Int(revisionDelta) + reconciliationDelta + routeDelta)
        if eventCount > 0 {
            lifecycleRequestTimes.append(contentsOf: Array(repeating: now, count: eventCount))
        }
        lifecycleRequestTimes.removeAll { now.timeIntervalSince($0) > 60 }
        peakLifecycleRequestsPerMinute = max(peakLifecycleRequestsPerMinute, lifecycleRequestTimes.count)
        lastDesiredRevision = lifecycle.desiredContractRevision
        lastReconciliationCount = lifecycle.reconciliationExecutionCount
        lastRouteActivationCount = routeActivations
    }

    private func observeCapture(now: Date, capture: RinkLensCaptureEngineSnapshot) {
        let unhealthy = phase == .liveFixture
            && (!capture.sessionRunning || capture.phase == .stopped || capture.phase == .failed)
        if unhealthy && !captureUnhealthyLatched {
            captureUnhealthyLatched = true
            captureLossCount &+= 1
            appendEvent("FAIL capture loss episode phase=\(capture.phase.rawValue) running=\(capture.sessionRunning) reason=\(capture.lastInterruptionText)")
        } else if !unhealthy {
            captureUnhealthyLatched = false
        }

        if capture.phase != lastCapturePhase {
            if capture.phase == .recovering {
                captureRecoveryTimes.append(now)
                captureRecoveryTimes.removeAll { now.timeIntervalSince($0) > 60 }
                let blackCount = Int(BlackFrameRejectionTraceStore.shared.consecutiveRejectedText) ?? 0
                if captureRecoveryTimes.count >= 3 && blackCount > 0 {
                    blackFrameRecoveryLoopDetected = true
                    appendEvent("FAIL black-frame recovery-loop signature detected")
                }
            }
            appendEvent("capture phase \(lastCapturePhase.rawValue) -> \(capture.phase.rawValue)")
            lastCapturePhase = capture.phase
        }
        let blackCount = Int(BlackFrameRejectionTraceStore.shared.consecutiveRejectedText) ?? 0
        maximumConsecutiveBlackFrames = max(maximumConsecutiveBlackFrames, blackCount)
    }

    private func observeRecording(
        now: Date,
        recorder: BroadcastRecordingManager,
        capture: RinkLensCaptureEngineSnapshot
    ) {
        if recorder.state == .recording {
            if !recordingObserved {
                recordingObserved = true
                recordingStartedAt = now
                appendEvent("full-match recording observed")
            }
            let recordingAge = recordingStartedAt.map { now.timeIntervalSince($0) } ?? 0
            if recordingAge >= 10,
               let actual = Self.firstDouble(in: recorder.recordingActualFPSText),
               let target = Self.firstDouble(in: recorder.recordingTargetFPSText),
               target > 0 {
                let cadence = actual / target * 100
                minimumRecordingCadencePercent = min(minimumRecordingCadencePercent ?? cadence, cadence)
            }
        }

        if recorder.state == .failed && lastRecordingState != .failed {
            recordingFailureCount &+= 1
            appendEvent("FAIL recording entered Failed")
        }
        if recorder.state == .paused && lastRecordingState != .paused {
            recordingPauseCount &+= 1
            appendEvent("FAIL recording entered Paused")
        }
        if recordingObserved,
           (lastRecordingState == .recording || lastRecordingState == .stopping),
           recorder.state == .idle {
            recordingStoppedNormally = recorder.lastErrorMessage == nil
            appendEvent(recordingStoppedNormally ? "recording finalised without error" : "recording stopped with error: \(recorder.lastErrorMessage ?? "unknown")")
        }
        lastRecordingState = recorder.state
    }

    private func observeOCR(
        now: Date,
        viewModel: HockeyScoreboardViewModel,
        completedPasses: Int,
        frameHub: RinkLensFrameHubSnapshot
    ) {
        guard phase == .liveFixture, recordingObserved, !recordingStoppedNormally else {
            lastOCRCompletedPasses = completedPasses
            lastOCRProgressAt = now
            return
        }

        if completedPasses > lastOCRCompletedPasses {
            lastOCRCompletedPasses = completedPasses
            lastOCRProgressAt = now
            ocrFreezeLatched = false
        }

        if viewModel.isOCREffectiveRunning {
            ocrRunningObserved = true
            consecutiveOCRNotRunningSamples = 0
            if let lastOCRProgressAt,
               now.timeIntervalSince(lastOCRProgressAt) > 20,
               !ocrFreezeLatched {
                ocrFreezeLatched = true
                ocrFreezeCount &+= 1
                appendEvent("FAIL OCR state freeze: no completed OCR pass for more than 20 seconds")
            }
        } else if viewModel.isOCRRequested && ocrRunningObserved {
            consecutiveOCRNotRunningSamples &+= 1
            if consecutiveOCRNotRunningSamples == 4 {
                ocrInterruptionCount &+= 1
                appendEvent("FAIL OCR not effectively running for more than three seconds")
            }
        }
    }

    private func observeAutomaticScoreChanges(viewModel: HockeyScoreboardViewModel) {
        guard phase == .liveFixture else {
            lastHomeScore = viewModel.state.homeScore
            lastAwayScore = viewModel.state.awayScore
            return
        }
        let home = viewModel.state.homeScore
        let away = viewModel.state.awayScore
        let changed = home != lastHomeScore || away != lastAwayScore
        if changed,
           viewModel.lastMatchStateActionText.contains("origin=ocr"),
           (viewModel.lastMatchStateActionText.contains("homeScore") || viewModel.lastMatchStateActionText.contains("awayScore")) {
            automaticScoreEventCount &+= 1
            appendEvent("automatic OCR score event \(automaticScoreEventCount): \(lastHomeScore.map { String($0) } ?? "--")-\(lastAwayScore.map { String($0) } ?? "--") -> \(home.map { String($0) } ?? "--")-\(away.map { String($0) } ?? "--")")
        }
        lastHomeScore = home
        lastAwayScore = away
    }

    private func observeConfiguration(
        viewModel: HockeyScoreboardViewModel,
        capture: RinkLensCaptureEngineSnapshot
    ) {
        guard phase == .liveFixture else { return }
        let currentLiveID = viewModel.liveCameraService.selectedCameraID
        let currentOCRID = viewModel.ocrCameraService.selectedCameraID
        let currentLiveProfileID = viewModel.liveCameraService.selectedCapabilityProfileID
        let currentOCRProfileID = viewModel.ocrCameraService.selectedCapabilityProfileID
        let currentTemplateID = viewModel.templateStore.activeTemplateID
        if currentLiveID != initialLiveDeviceID
            || currentOCRID != initialOCRDeviceID
            || currentLiveProfileID != initialLiveCapabilityProfileID
            || currentOCRProfileID != initialOCRCapabilityProfileID
            || currentTemplateID != initialRinkTemplateID
            || capture.transitionGeneration != initialCaptureGeneration
            || viewModel.hasUnsavedTemplateChanges {
            cameraOrProfileChangeCount = 1
        }
    }

    private func updateEvidenceText(
        viewModel: HockeyScoreboardViewModel,
        capture: RinkLensCaptureEngineSnapshot,
        recorder: BroadcastRecordingManager,
        frameHub: RinkLensFrameHubSnapshot
    ) {
        let activeTemplate = viewModel.templateStore.activeTemplate
        let profileSaved = activeTemplate != nil && !viewModel.hasUnsavedTemplateChanges
        profileText = "rink=\(activeTemplate?.name ?? "none") [\(profileSaved ? "saved" : "CHECK")]; Broadcast=\(viewModel.liveCameraService.selectedCameraName) id=\(viewModel.liveCameraService.selectedCameraID ?? "none"); OCR=\(viewModel.ocrCameraService.selectedCameraName) id=\(viewModel.ocrCameraService.selectedCameraID ?? "none")"
        captureText = "mode=\(capture.activeMode.rawValue); phase=\(capture.phase.rawValue); running=\(capture.sessionRunning); generation=\(capture.transitionGeneration); loss episodes=\(captureLossCount); black max=\(maximumConsecutiveBlackFrames)"
        let cadence = minimumRecordingCadencePercent.map { String(format: "%.1f%% min", $0) } ?? "pending"
        recordingText = "state=\(recorder.state.rawValue); duration=\(recorder.elapsedText); frames=\(recorder.framesWritten); cadence=\(cadence); saved +\(savedRecordingDelta); clips +\(manualClipDelta); failures/pauses \(recordingFailureCount)/\(recordingPauseCount)"
        let freshOCR = frameHub.ocr.ageSeconds.map { $0 <= 1.5 } ?? false
        ocrText = "\(viewModel.ocrOperationalStatusText); fresh=\(freshOCR); completed=\(viewModel.ocrOrchestrationSnapshot.completedPasses); freezes=\(ocrFreezeCount); interruptions=\(ocrInterruptionCount)"
        let lifecycle = viewModel.captureLifecycleController
        let revisionDelta = lifecycle.desiredContractRevision >= initialDesiredRevision
            ? lifecycle.desiredContractRevision - initialDesiredRevision
            : 0
        let reconciliationDelta = max(0, lifecycle.reconciliationExecutionCount - initialReconciliationCount)
        let routeDelta = max(0, viewModel.routeLifecycleActivationCount - initialRouteActivationCount)
        lifecycleText = "revisions +\(revisionDelta); reconciliations +\(reconciliationDelta); route activations +\(routeDelta); routes \(routeChanges); peak \(peakLifecycleRequestsPerMinute)/min; scene interruptions \(unexpectedSceneInterruptions)"
        automaticScoreText = "detected=\(automaticScoreEventCount); reviewed correct through=\(reviewedAutomaticScoreEventCount); incorrect=\(incorrectAutomaticScoreEventCount)"
        logsText = completedLogMilestones.isEmpty
            ? logsText
            : "completed \(completedLogMilestones.map(\.rawValue).sorted().joined(separator: ", "))"
    }

    private func updatePublishedSummary() {
        let referenceStart = faceOffAt ?? startedAt
        elapsedText = referenceStart.map { Self.durationText(Date().timeIntervalSince($0)) } ?? "00:00"
        prerequisiteText = controlledRinkPilotPassed
            ? "PASS — UX16c48 controlled-rink pilot recorded"
            : "FAIL — UX16c48 controlled-rink pilot not passed"

        let liveBuffers = max(0, AppContainer.shared.captureEngine.snapshot.liveDroppedOutOfBuffersLifetime - initialLiveOutOfBuffers)
        let ocrBuffers = max(0, AppContainer.shared.captureEngine.snapshot.ocrDroppedOutOfBuffersLifetime - initialOCROutOfBuffers)
        let automaticScoresReviewed = reviewedAutomaticScoreEventCount >= automaticScoreEventCount
        let cadencePass = minimumRecordingCadencePercent.map { $0 >= 95 } ?? false
        let completeLogs = Set(LogMilestone.allCases).isSubset(of: completedLogMilestones)
        let recordingComplete = recordingObserved && recordingStoppedNormally && savedRecordingDelta > 0
        let manualClipComplete = manualClipDelta > 0 && completedFixtureCheckpoints.contains(.manualClipSaved)

        acceptanceLines = [
            "\(controlledRinkPilotPassed ? "PASS" : "FAIL") — UX16c48 controlled-rink pilot passed before game-day use",
            "\(MainThreadStallMonitor.shared.diagnosticsMode == .matchDaySafe && matchDayModeDeviationCount == 0 ? "PASS" : "FAIL") — Match Day Safe mode remains active",
            "\(automaticPreflightReady || phase == .completed ? "PASS" : "CHECK") — known-good saved cameras/rink profile and healthy dual-camera graph",
            "\(captureLossCount == 0 ? "PASS" : "FAIL") — capture loss episodes \(captureLossCount)",
            "\(recordingComplete && recordingFailureCount == 0 && recordingPauseCount == 0 ? "PASS" : "CHECK") — full-match recording completes continuously",
            "\(cadencePass ? "PASS" : "CHECK") — minimum recording cadence \(minimumRecordingCadencePercent.map { String(format: "%.1f%%", $0) } ?? "not measured") against 95% gate",
            "\(ocrFreezeCount == 0 && ocrInterruptionCount == 0 && ocrRunningObserved ? "PASS" : "FAIL") — OCR freeze/interruption \(ocrFreezeCount)/\(ocrInterruptionCount)",
            "\(peakLifecycleRequestsPerMinute <= requestStormLimitPerMinute ? "PASS" : "FAIL") — lifecycle request peak \(peakLifecycleRequestsPerMinute)/min, limit \(requestStormLimitPerMinute)/min",
            "\(liveBuffers + ocrBuffers == 0 ? "PASS" : "FAIL") — OutOfBuffers delta \(liveBuffers + ocrBuffers)",
            "\(!blackFrameRecoveryLoopDetected ? "PASS" : "FAIL") — black-frame recovery loop \(blackFrameRecoveryLoopDetected ? "detected" : "not detected")",
            "\(incorrectAutomaticScoreEventCount == 0 && automaticScoresReviewed ? "PASS" : "FAIL") — automatic score events detected/reviewed/incorrect \(automaticScoreEventCount)/\(reviewedAutomaticScoreEventCount)/\(incorrectAutomaticScoreEventCount)",
            "\(manualClipComplete ? "PASS" : "CHECK") — manual clip workflow completed",
            "\(completeLogs ? "PASS" : "CHECK") — All Logs exported at both period breaks and after the match",
            "\(cameraOrProfileChangeCount == 0 ? "PASS" : "FAIL") — saved camera and rink profile remain unchanged after face-off",
            "\(operatorRecoveryActionCount == 0 ? "PASS" : "FAIL") — operator recovery actions \(operatorRecoveryActionCount)",
            "\(unexpectedSceneInterruptions == 0 ? "PASS" : "FAIL") — unexpected scene interruptions \(unexpectedSceneInterruptions)",
            "INFO — system pressure serious/critical samples \(seriousPressureSamples)/\(criticalPressureSamples); rink temperature is contextual and pressure alone does not fail a fixture. Any actual cadence, OCR, capture or buffer effect is gated above."
        ]
        updatePromotionText()
        publishUI()
    }

    private func currentFailureReasons() -> [String] {
        let capture = AppContainer.shared.captureEngine.snapshot
        let liveBuffers = max(0, capture.liveDroppedOutOfBuffersLifetime - initialLiveOutOfBuffers)
        let ocrBuffers = max(0, capture.ocrDroppedOutOfBuffersLifetime - initialOCROutOfBuffers)
        var failures: [String] = []
        if !controlledRinkPilotPassed { failures.append("UX16c48 prerequisite not passed") }
        if matchDayModeDeviationCount > 0 || MainThreadStallMonitor.shared.diagnosticsMode != .matchDaySafe { failures.append("Match Day Safe mode deviation") }
        if !PreflightCheckpoint.allCases.allSatisfy({ completedPreflightCheckpoints.contains($0) }) { failures.append("pre-face-off controls incomplete") }
        if captureLossCount > 0 { failures.append("capture loss") }
        if !recordingObserved || !recordingStoppedNormally || savedRecordingDelta == 0 || recordingFailureCount > 0 || recordingPauseCount > 0 { failures.append("recording continuity/finalisation failure") }
        if minimumRecordingCadencePercent.map({ $0 < 95 }) ?? true { failures.append("recording cadence below 95% or not measured") }
        if ocrFreezeCount > 0 || ocrInterruptionCount > 0 || !ocrRunningObserved { failures.append("OCR state freeze/interruption") }
        if peakLifecycleRequestsPerMinute > requestStormLimitPerMinute { failures.append("lifecycle request storm") }
        if liveBuffers + ocrBuffers > 0 { failures.append("OutOfBuffers drop") }
        if blackFrameRecoveryLoopDetected { failures.append("black-frame recovery loop") }
        if incorrectAutomaticScoreEventCount > 0 || reviewedAutomaticScoreEventCount < automaticScoreEventCount { failures.append("automatic score event incorrect or unreviewed") }
        if manualClipDelta == 0 || !completedFixtureCheckpoints.contains(.manualClipSaved) { failures.append("manual clip workflow not completed") }
        if !Set(LogMilestone.allCases).isSubset(of: completedLogMilestones) { failures.append("required logs missing") }
        if cameraOrProfileChangeCount > 0 { failures.append("camera/rink profile changed after face-off") }
        if operatorRecoveryActionCount > 0 { failures.append("operator recovery action required") }
        if unexpectedSceneInterruptions > 0 { failures.append("unexpected scene interruption") }
        return failures
    }

    private func updatePromotionText() {
        let clean = cleanFixtureCount
        promotionText = promotionEligible
            ? "PROMOTE — \(clean) clean fixtures meet the \(requiredCleanFixtures)-fixture gate"
            : "HOLD — \(clean)/\(requiredCleanFixtures) clean fixtures completed"
    }

    private func resetCurrentFixture(restoreDiagnosticsMode: Bool) {
        sampleTask?.cancel()
        sampleTask = nil
        if restoreDiagnosticsMode, phase != .idle {
            MainThreadStallMonitor.shared.setDiagnosticsMode(initialDiagnosticsMode, reason: "UX16c49 game-day pilot reset")
        }
        startedAt = nil
        faceOffAt = nil
        stoppedAt = nil
        fixtureResultRecorded = false
        initialCaptureGeneration = 0
        initialLiveDeviceID = nil
        initialOCRDeviceID = nil
        initialLiveCapabilityProfileID = nil
        initialOCRCapabilityProfileID = nil
        initialRinkTemplateID = nil
        initialSavedRecordings = 0
        initialSavedManualHighlights = 0
        initialLiveOutOfBuffers = 0
        initialOCROutOfBuffers = 0
        initialLiveDroppedFrames = 0
        initialOCRDroppedFrames = 0
        initialDesiredRevision = 0
        initialReconciliationCount = 0
        initialRouteActivationCount = 0
        lastDesiredRevision = 0
        lastReconciliationCount = 0
        lastRouteActivationCount = 0
        lifecycleRequestTimes.removeAll()
        peakLifecycleRequestsPerMinute = 0
        lastCapturePhase = .stopped
        captureUnhealthyLatched = false
        captureLossCount = 0
        captureRecoveryTimes.removeAll()
        blackFrameRecoveryLoopDetected = false
        maximumConsecutiveBlackFrames = 0
        cameraOrProfileChangeCount = 0
        matchDayModeDeviationCount = 0
        unexpectedSceneInterruptions = 0
        routeChanges = 0
        operatorRecoveryActionCount = 0
        lastRecordingState = .idle
        recordingObserved = false
        recordingStartedAt = nil
        recordingStoppedNormally = false
        recordingFailureCount = 0
        recordingPauseCount = 0
        savedRecordingDelta = 0
        manualClipDelta = 0
        minimumRecordingCadencePercent = nil
        lastOCRCompletedPasses = 0
        lastOCRProgressAt = nil
        ocrFreezeLatched = false
        ocrFreezeCount = 0
        consecutiveOCRNotRunningSamples = 0
        ocrInterruptionCount = 0
        ocrRunningObserved = false
        lastHomeScore = nil
        lastAwayScore = nil
        automaticScoreEventCount = 0
        reviewedAutomaticScoreEventCount = 0
        incorrectAutomaticScoreEventCount = 0
        latestIncorrectMarkedEventIndex = 0
        seriousPressureSamples = 0
        criticalPressureSamples = 0
        sampleSequence = 0
        completedPreflightCheckpoints.removeAll()
        completedFixtureCheckpoints.removeAll()
        completedLogMilestones.removeAll()
        lastLogURL = nil
        logExportInProgress = false
        recentEvents.removeAll()
        elapsedText = "00:00"
        profileText = "Saved profile not sampled"
        captureText = "Capture not sampled"
        recordingText = "Recording not sampled"
        ocrText = "OCR not sampled"
        lifecycleText = "Lifecycle not sampled"
        buffersText = "Dropped frames not sampled"
        pressureText = "System pressure not sampled"
        automaticScoreText = "No automatic score event observed"
        logsText = "Period-break and post-match logs not exported"
        acceptanceLines = ["Start preflight to collect fixture evidence."]
    }

    private func persistFixtureResults() {
        guard let data = try? JSONEncoder().encode(fixtureResults) else { return }
        defaults.set(data, forKey: historyKey)
    }

    private static func loadFixtureResults(defaults: UserDefaults, key: String) -> [FixtureResult] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([FixtureResult].self, from: data) else { return [] }
        return decoded
    }

    private func appendEvent(_ text: String) {
        let row = "\(Self.eventTimeFormatter.string(from: Date()))  \(text)"
        recentEvents.insert(row, at: 0)
        if recentEvents.count > 60 {
            recentEvents.removeLast(recentEvents.count - 60)
        }
        MainThreadStallMonitor.shared.trace("UX16c49 game-day pilot: \(text)")
    }

    private func publishUI() {
        uiRevision &+= 1
        MainThreadStallMonitor.shared.notePublish(source: "GameDayPilot", count: 1)
    }

    private static func firstDouble(in text: String) -> Double? {
        var buffer = ""
        var decimalUsed = false
        for character in text {
            if character.isNumber {
                buffer.append(character)
            } else if character == "." && !decimalUsed && !buffer.isEmpty {
                decimalUsed = true
                buffer.append(character)
            } else if !buffer.isEmpty {
                break
            }
        }
        return Double(buffer)
    }

    private static func durationText(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%02d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private static let eventTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZ"
        return formatter
    }()
}

struct GameDayPilotPanel: View {
    @ObservedObject var controller: RinkLensGameDayPilotController
    let viewModel: HockeyScoreboardViewModel
    let cameraService: HockeyCameraService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DiagnosticsCard(title: "Game-Day Pilot", systemImage: "sportscourt") {
                Text("Use one monitored fixture only after UX16c48 passes. This page observes the production workflow and never starts, stops, recovers, or reconfigures capture, OCR, recording, or clips.")
                    .font(RinkLensDesignSystem.font(.caption))
                    .foregroundStyle(RinkLensDesignSystem.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Promotion gate", selection: Binding(
                    get: { controller.requiredCleanFixtures },
                    set: { controller.setRequiredCleanFixtures($0) }
                )) {
                    Text("2 clean fixtures").tag(2)
                    Text("3 clean fixtures").tag(3)
                }
                .pickerStyle(.segmented)
                .disabled(controller.isRunning)

                HStack {
                    Button {
                        controller.startPreflight()
                    } label: {
                        Label("Start Preflight", systemImage: "checklist")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.isRunning)

                    Button {
                        controller.beginFixture()
                    } label: {
                        Label("Begin Fixture", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(controller.phase != .preflight)

                    Button {
                        controller.finishFixture()
                    } label: {
                        Label("Finish Fixture", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(controller.phase != .liveFixture)

                    Button("Reset") {
                        controller.reset()
                    }
                    .buttonStyle(.bordered)
                    .disabled(controller.isRunning)
                }

                DiagnosticsRow(title: "Phase", value: controller.phase.rawValue)
                DiagnosticsRow(title: "Status", value: controller.statusText)
                DiagnosticsRow(title: "Prerequisite", value: controller.prerequisiteText)
                DiagnosticsRow(title: "Elapsed", value: controller.elapsedText)
                DiagnosticsRow(title: "Profile", value: controller.profileText)
                DiagnosticsRow(title: "Capture", value: controller.captureText)
                DiagnosticsRow(title: "Recording", value: controller.recordingText)
                DiagnosticsRow(title: "OCR", value: controller.ocrText)
                DiagnosticsRow(title: "Lifecycle", value: controller.lifecycleText)
                DiagnosticsRow(title: "Buffers", value: controller.buffersText)
                DiagnosticsRow(title: "Pressure", value: controller.pressureText)
            }

            DiagnosticsCard(title: "Pre-Face-Off Controls", systemImage: "shield.checkered") {
                ForEach(RinkLensGameDayPilotController.PreflightCheckpoint.allCases) { checkpoint in
                    Button {
                        controller.togglePreflightCheckpoint(checkpoint)
                    } label: {
                        HStack {
                            Image(systemName: controller.preflightCheckpointIsComplete(checkpoint) ? "checkmark.circle.fill" : "circle")
                            Text(checkpoint.rawValue)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(controller.preflightCheckpointIsComplete(checkpoint) ? Color.green : RinkLensDesignSystem.primaryText)
                    .disabled(controller.phase != .preflight)
                }
            }

            DiagnosticsCard(title: "Fixture Workflow", systemImage: "figure.hockey") {
                ForEach(RinkLensGameDayPilotController.FixtureCheckpoint.allCases) { checkpoint in
                    Button {
                        controller.toggleFixtureCheckpoint(checkpoint)
                    } label: {
                        HStack {
                            Image(systemName: controller.fixtureCheckpointIsComplete(checkpoint) ? "checkmark.circle.fill" : "circle")
                            Text(checkpoint.rawValue)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(controller.fixtureCheckpointIsComplete(checkpoint) ? Color.green : RinkLensDesignSystem.primaryText)
                    .disabled(controller.phase != .liveFixture)
                }
            }

            DiagnosticsCard(title: "Automatic Score Audit", systemImage: "checkmark.bubble") {
                DiagnosticsRow(title: "Evidence", value: controller.automaticScoreText)
                HStack {
                    Button("Confirm Events Correct") {
                        controller.confirmAutomaticScoreEventsCorrect()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.phase != .liveFixture)

                    Button("Mark Latest Incorrect") {
                        controller.markLatestAutomaticScoreEventIncorrect()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(controller.phase != .liveFixture)
                }
            }

            DiagnosticsCard(title: "Required All Logs Exports", systemImage: "doc.badge.gearshape") {
                Text("Export during each period break while recording continues, then export once more after the match and recording finalisation. No share sheet is opened automatically.")
                    .font(RinkLensDesignSystem.font(.caption))
                    .foregroundStyle(RinkLensDesignSystem.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(RinkLensGameDayPilotController.LogMilestone.allCases) { milestone in
                    Button {
                        Task { @MainActor in
                            await controller.exportLogs(
                                milestone: milestone,
                                viewModel: viewModel,
                                cameraService: cameraService
                            )
                        }
                    } label: {
                        HStack {
                            Image(systemName: controller.completedLogMilestones.contains(milestone) ? "checkmark.circle.fill" : "square.and.arrow.down")
                            Text(milestone.shortLabel)
                            Spacer()
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!controller.isRunning || controller.logExportInProgress || controller.completedLogMilestones.contains(milestone))
                }
                DiagnosticsRow(title: "Logs", value: controller.logsText)
                if let url = controller.lastLogURL {
                    ShareLink(item: url) {
                        Label("Share Latest Completed Export", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }
            }

            DiagnosticsCard(title: "Fixture Acceptance", systemImage: "checkmark.seal") {
                ForEach(Array(controller.acceptanceLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(RinkLensDesignSystem.font(.monoCaption))
                        .foregroundStyle(line.hasPrefix("FAIL") ? Color.red : (line.hasPrefix("PASS") ? Color.green : RinkLensDesignSystem.secondaryText))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            DiagnosticsCard(title: "Promotion Gate", systemImage: "flag.checkered") {
                DiagnosticsRow(title: "Result", value: controller.promotionText)
                ForEach(Array(controller.fixtureResults.suffix(5).reversed())) { result in
                    Text("\(result.passed ? "PASS" : "FAIL") • \(result.completedAt.formatted(date: .abbreviated, time: .shortened)) • \(result.failureReasons.isEmpty ? "clean fixture" : result.failureReasons.joined(separator: ", "))")
                        .font(RinkLensDesignSystem.font(.monoCaption))
                        .foregroundStyle(result.passed ? Color.green : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Clear Promotion History", role: .destructive) {
                    controller.clearPromotionHistory()
                }
                .buttonStyle(.bordered)
                .disabled(controller.isRunning || controller.fixtureResults.isEmpty)
            }

            DiagnosticsCard(title: "Recent Game-Day Events", systemImage: "list.bullet.rectangle") {
                if controller.recentEvents.isEmpty {
                    Text("No game-day events captured")
                        .font(RinkLensDesignSystem.font(.caption))
                        .foregroundStyle(RinkLensDesignSystem.secondaryText)
                } else {
                    ForEach(Array(controller.recentEvents.prefix(16).enumerated()), id: \.offset) { _, event in
                        Text(event)
                            .font(RinkLensDesignSystem.font(.monoCaption))
                            .foregroundStyle(RinkLensDesignSystem.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
#endif
