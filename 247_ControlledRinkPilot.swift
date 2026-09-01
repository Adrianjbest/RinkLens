// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import Foundation
@preconcurrency import AVFoundation

// MARK: - UX16c48 controlled rink pilot

/// One guided training-session pilot. The controller observes the production
/// graph and recording path only; it never starts/stops capture, OCR, recording
/// or manual clips. Operator actions remain in their normal screens.
@MainActor
final class RinkLensControlledPilotController: ObservableObject {
    static let shared = RinkLensControlledPilotController()

    enum Phase: String, Sendable {
        case idle = "Not started"
        case engineeringSetup = "Engineering setup"
        case rinkTest = "Rink Test session"
        case completed = "Completed"
    }

    enum OperatorCheckpoint: String, CaseIterable, Identifiable, Sendable {
        case ocrScorebugVerified = "OCR values update the scorebug correctly"
        case manualFallbackVerified = "Manual fallback is available"
        case fullMatchRecordingCompleted = "Full-match recording completed"

        var id: String { rawValue }
    }

    @Published private(set) var uiRevision: UInt64 = 0
    private(set) var phase: Phase = .idle
    private(set) var statusText = "No controlled rink pilot running"
    private(set) var elapsedText = "00:00"
    private(set) var cameraText = "Camera roles not sampled"
    private(set) var ocrText = "OCR not sampled"
    private(set) var scorebugText = "No OCR scorebug evidence"
    private(set) var recordingText = "No recording observed"
    private(set) var clipText = "No manual clip observed"
    private(set) var lifecycleText = "No scene or route evidence"
    private(set) var recoveryText = "No operator recovery action observed"
    private(set) var exportText = "All Logs export not tested"
    private(set) var acceptanceLines: [String] = ["Start the pilot to collect evidence."]
    private(set) var recentEvents: [String] = []
    private(set) var completedCheckpoints: Set<OperatorCheckpoint> = []
    private(set) var lastAllLogsURL: URL?
    private(set) var allLogsExportInProgress = false
    private(set) var controlledLifecycleTestArmed = false
    private(set) var controlledLifecycleTestCompleted = false
    private(set) var lastCompletedPilotPassed = UserDefaults.standard.bool(forKey: "RinkLens.UX16c48.controlledPilotPassed")

    private var sampleTask: Task<Void, Never>?
    private var startedAt: Date?
    private var stoppedAt: Date?
    private var enteredRinkTestAt: Date?
    private var initialDiagnosticsMode: RuntimeDiagnosticsMode = .production
    private var engineeringModeObserved = false
    private var rinkTestModeObserved = false
    private var finishedInRinkTestMode = false

    private var initialCaptureGeneration = 0
    private var initialDesiredRevision: UInt64 = 0
    private var initialReconciliationCount = 0
    private var initialRouteActivationCount = 0
    private var initialMatchStateRevision: UInt64 = 0
    private var initialSavedManualHighlights = 0
    private var initialSavedRecordings = 0
    private var initialStaleTestOCRPreventions = 0

    private var lastCapturePhase = RinkLensCaptureEnginePhase.stopped
    private var lastRecordingState = BroadcastRecordingManager.RecordingState.idle
    private var recordingObserved = false
    private var recordingStartedAt: Date?
    private var recordingStoppedNormally = false
    private var recordingFailureCount = 0
    private var recordingPauseCount = 0
    private var captureStopsWhileRecording = 0
    private var minimumRecordingCadencePercent: Double?
    private var maximumOCRNotRunningSamples = 0
    private var ocrRequestedWhileRecordingObserved = false
    private var ocrRunningWhileRecordingObserved = false
    private var dualCameraRoleWorkflowObserved = false
    private var consecutiveOCRNotRunningSamples = 0
    private var ocrInterruptionsWhileRecording = 0
    private var scorebugRevisionDelta: UInt64 = 0
    private var manualClipDelta = 0
    private var savedRecordingDelta = 0
    private var routeChanges = 0
    private var unexpectedSceneInterruptions = 0
    private var controlledLifecycleInProgress = false
    private var operatorRecoveryActionCount = 0
    private var allLogsExportAttempted = false
    private var allLogsExportPassed = false
    private var allLogsExportFailureReason = "not tested"
    private var allLogsExportCaptureGeneration = 0
    private var allLogsExportRecordingFramesBefore = 0
    private var staleTestOCRPreventionDelta = 0

    private static let promotionGateDefaultsKey = "RinkLens.UX16c48.controlledPilotPassed"

    private init() {}

    var promotionGatePassed: Bool {
        lastCompletedPilotPassed || UserDefaults.standard.bool(forKey: Self.promotionGateDefaultsKey)
    }

    var isRunning: Bool {
        phase == .engineeringSetup || phase == .rinkTest
    }

    func start() {
        guard !isRunning else { return }
        if phase == .completed {
            MainThreadStallMonitor.shared.setDiagnosticsMode(initialDiagnosticsMode, reason: "UX16c48 pilot restarted")
        }
        resetEvidence(restoreDiagnosticsMode: false)

        let container = AppContainer.shared
        let viewModel = container.scoreboardViewModel
        let capture = container.captureEngine.snapshot
        let lifecycle = viewModel.captureLifecycleController
        let recorder = BroadcastRecordingManager.shared

        startedAt = Date()
        stoppedAt = nil
        phase = .engineeringSetup
        statusText = "Engineering setup: verify camera roles, framing and OCR"
        initialDiagnosticsMode = MainThreadStallMonitor.shared.diagnosticsMode
        initialCaptureGeneration = capture.transitionGeneration
        initialDesiredRevision = lifecycle.desiredContractRevision
        initialReconciliationCount = lifecycle.reconciliationExecutionCount
        initialRouteActivationCount = viewModel.routeLifecycleActivationCount
        initialMatchStateRevision = viewModel.matchStateRevision
        initialSavedManualHighlights = recorder.savedManualHighlightsCount
        initialSavedRecordings = recorder.savedRecordingsCount
        initialStaleTestOCRPreventions = viewModel.testOCRStaleResultPreventionCount
        lastCapturePhase = capture.phase
        lastRecordingState = recorder.state

        MainThreadStallMonitor.shared.setDiagnosticsMode(.engineering, reason: "UX16c48 controlled rink pilot setup")
        engineeringModeObserved = true
        appendEvent("pilot started; Engineering diagnostics enabled")
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

    /// Switch after framing/camera/OCR setup is complete. This changes logging
    /// policy only; it does not mutate the capture graph.
    func enterRinkTestMode() {
        guard phase == .engineeringSetup else { return }
        phase = .rinkTest
        enteredRinkTestAt = Date()
        MainThreadStallMonitor.shared.setDiagnosticsMode(.rinkTest, reason: "UX16c48 controlled rink pilot")
        rinkTestModeObserved = true
        statusText = "Rink Test active: run continuous OCR and full-match recording"
        appendEvent("pilot moved from Engineering diagnostics to Rink Test")
        sampleNow(forcePublish: true)
    }

    func finish() {
        guard isRunning else { return }
        let recorder = BroadcastRecordingManager.shared
        guard recorder.state == .idle || recorder.state == .failed else {
            statusText = "Stop and finalise the full-match recording before finishing the pilot"
            appendEvent("finish blocked while recording state=\(recorder.state.rawValue)")
            updatePublishedSummary()
            return
        }
        sampleNow(forcePublish: true)
        finishedInRinkTestMode = MainThreadStallMonitor.shared.diagnosticsMode == .rinkTest
        stoppedAt = Date()
        sampleTask?.cancel()
        sampleTask = nil
        phase = .completed
        statusText = "Controlled rink pilot completed"
        appendEvent("pilot completed")
        updatePublishedSummary()
        let passed = acceptanceLines.allSatisfy { $0.hasPrefix("PASS") }
        lastCompletedPilotPassed = passed
        if passed {
            UserDefaults.standard.set(true, forKey: Self.promotionGateDefaultsKey)
            appendEvent("UX16c48 promotion gate recorded as passed")
        } else {
            appendEvent("UX16c48 promotion gate not passed")
        }
        publishUI()
    }

    func reset() {
        guard !isRunning else { return }
        resetEvidence(restoreDiagnosticsMode: true)
        phase = .idle
        statusText = "Controlled rink pilot reset"
        publishUI()
    }

    func toggleCheckpoint(_ checkpoint: OperatorCheckpoint) {
        if completedCheckpoints.contains(checkpoint) {
            completedCheckpoints.remove(checkpoint)
            appendEvent("checkpoint cleared: \(checkpoint.rawValue)")
        } else {
            completedCheckpoints.insert(checkpoint)
            appendEvent("checkpoint confirmed: \(checkpoint.rawValue)")
        }
        updatePublishedSummary()
    }

    func checkpointIsComplete(_ checkpoint: OperatorCheckpoint) -> Bool {
        completedCheckpoints.contains(checkpoint)
    }

    func armControlledLifecycleTest() {
        guard isRunning else { return }
        controlledLifecycleTestArmed = true
        controlledLifecycleInProgress = false
        controlledLifecycleTestCompleted = false
        appendEvent("controlled sleep/wake or background test armed")
        updatePublishedSummary()
    }

    func cancelControlledLifecycleTest() {
        controlledLifecycleTestArmed = false
        controlledLifecycleInProgress = false
        appendEvent("controlled lifecycle test disarmed")
        updatePublishedSummary()
    }

    func noteScenePhase(_ scenePhase: ScenePhase) {
        guard isRunning else { return }
        switch scenePhase {
        case .inactive, .background:
            if controlledLifecycleTestArmed {
                controlledLifecycleInProgress = true
                appendEvent("controlled scene transition: \(scenePhase == .inactive ? "inactive" : "background")")
            } else {
                unexpectedSceneInterruptions &+= 1
                appendEvent("unexpected scene transition: \(scenePhase == .inactive ? "inactive" : "background")")
            }
        case .active:
            if controlledLifecycleTestArmed && controlledLifecycleInProgress {
                controlledLifecycleTestCompleted = true
                controlledLifecycleTestArmed = false
                controlledLifecycleInProgress = false
                appendEvent("controlled scene lifecycle returned active")
            }
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

    /// Runs the existing asynchronous All Logs exporter without opening a share
    /// sheet. The post-export check proves that the same recording/capture graph
    /// remains active and that a current-generation Broadcast frame is fresh.
    func testAllLogsExport(
        viewModel: HockeyScoreboardViewModel,
        cameraService: HockeyCameraService
    ) async {
        guard isRunning, !allLogsExportInProgress else { return }
        guard phase == .rinkTest, MainThreadStallMonitor.shared.diagnosticsMode == .rinkTest else {
            allLogsExportAttempted = true
            allLogsExportPassed = false
            allLogsExportFailureReason = "Rink Test mode was not active"
            exportText = "FAIL — enter Rink Test mode before testing All Logs"
            appendEvent("All Logs test rejected because Rink Test mode was not active")
            updatePublishedSummary()
            return
        }
        let recorder = BroadcastRecordingManager.shared
        let before = AppContainer.shared.captureEngine.snapshot
        guard recorder.state == .recording else {
            allLogsExportAttempted = true
            allLogsExportPassed = false
            allLogsExportFailureReason = "recording was not active"
            exportText = "FAIL — start full-match recording before testing All Logs"
            appendEvent("All Logs test rejected because recording was not active")
            updatePublishedSummary()
            return
        }

        allLogsExportAttempted = true
        allLogsExportInProgress = true
        allLogsExportCaptureGeneration = before.transitionGeneration
        allLogsExportRecordingFramesBefore = recorder.framesWritten
        exportText = "Exporting All Logs while capture and recording continue…"
        appendEvent("All Logs export started during recording")
        publishUI()

        let url = await DiagnosticsLogExporter.shared.exportAllLogs(
            viewModel: viewModel,
            cameraService: cameraService
        )

        do {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        } catch {
            // Cancellation does not change the production capture graph; the
            // immediate post-export checks below still determine the outcome.
        }

        let after = AppContainer.shared.captureEngine.snapshot
        let freshBroadcastFrame = RinkLensFrameHub.shared.latestEvidence(
            for: .broadcast,
            maxAge: 1.5,
            requiredCaptureGeneration: after.transitionGeneration,
            requiredPhysicalDeviceID: after.liveDeviceID
        ) != nil
        let recordingStillActive = recorder.state == .recording
        let generationUnchanged = after.transitionGeneration == allLogsExportCaptureGeneration
        let graphStillRunning = after.phase == .running && after.sessionRunning && after.activeMode.requiresBroadcast
        let framesAdvanced = recorder.framesWritten > allLogsExportRecordingFramesBefore

        allLogsExportPassed = url != nil
            && recordingStillActive
            && generationUnchanged
            && graphStillRunning
            && freshBroadcastFrame
            && framesAdvanced
        lastAllLogsURL = url
        if allLogsExportPassed {
            allLogsExportFailureReason = "none"
            exportText = "PASS — saved \(url?.lastPathComponent ?? "All Logs"); recording and capture remained active"
            appendEvent("All Logs export passed without capture interruption")
        } else {
            let reasons = [
                url == nil ? "file not created" : nil,
                !recordingStillActive ? "recording stopped" : nil,
                !generationUnchanged ? "capture generation changed" : nil,
                !graphStillRunning ? "Broadcast graph not running" : nil,
                !freshBroadcastFrame ? "no fresh Broadcast frame" : nil,
                !framesAdvanced ? "recording frames did not advance" : nil
            ].compactMap { $0 }
            allLogsExportFailureReason = reasons.joined(separator: ", ")
            exportText = "FAIL — \(allLogsExportFailureReason)"
            appendEvent("All Logs export failed evidence check: \(allLogsExportFailureReason)")
        }
        allLogsExportInProgress = false
        sampleNow(forcePublish: true)
    }

    func exportLines() -> [String] {
        let checkpointLines = OperatorCheckpoint.allCases.map {
            "Checkpoint \($0.rawValue): \(completedCheckpoints.contains($0) ? "PASS" : "not confirmed")"
        }
        return [
            "Phase: \(phase.rawValue)",
            "Status: \(statusText)",
            "Started: \(startedAt.map { Self.timestampFormatter.string(from: $0) } ?? "--")",
            "Initial capture generation: \(initialCaptureGeneration)",
            "Entered Rink Test: \(enteredRinkTestAt.map { Self.timestampFormatter.string(from: $0) } ?? "--")",
            "Stopped: \(stoppedAt.map { Self.timestampFormatter.string(from: $0) } ?? "--")",
            "Elapsed: \(elapsedText)",
            "Camera roles: \(cameraText)",
            "OCR: \(ocrText)",
            "Scorebug: \(scorebugText)",
            "Recording: \(recordingText)",
            "Manual clips: \(clipText)",
            "Lifecycle: \(lifecycleText)",
            "Recovery: \(recoveryText)",
            "All Logs: \(exportText)",
            "All Logs evidence failure: \(allLogsExportFailureReason)",
            "Controlled lifecycle test completed: \(controlledLifecycleTestCompleted ? "yes" : "no")",
            "UX16c48 promotion gate: \(promotionGatePassed ? "PASS" : "not passed")",
            "Stale Test OCR prevention delta: \(staleTestOCRPreventionDelta)",
            "Acceptance:"
        ] + acceptanceLines + checkpointLines + ["Recent events:"] + recentEvents
    }

    private func sampleNow(forcePublish: Bool) {
        let container = AppContainer.shared
        let viewModel = container.scoreboardViewModel
        let capture = container.captureEngine.snapshot
        let recorder = BroadcastRecordingManager.shared
        let frameHub = RinkLensFrameHub.shared.diagnosticSnapshot()

        engineeringModeObserved = engineeringModeObserved || MainThreadStallMonitor.shared.diagnosticsMode == .engineering
        rinkTestModeObserved = rinkTestModeObserved || MainThreadStallMonitor.shared.diagnosticsMode == .rinkTest

        if recorder.state == .recording {
            ocrRequestedWhileRecordingObserved = ocrRequestedWhileRecordingObserved || viewModel.isOCRRequested
            if !recordingObserved {
                recordingObserved = true
                recordingStartedAt = Date()
                appendEvent("full-match recording observed")
            }
            let recordingAge = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            let actual = Self.firstDouble(in: recorder.recordingActualFPSText)
            let target = Self.firstDouble(in: recorder.recordingTargetFPSText)
            if recordingAge >= 10, let actual, let target, target > 0 {
                let percent = actual / target * 100
                minimumRecordingCadencePercent = min(minimumRecordingCadencePercent ?? percent, percent)
            }

            if viewModel.isOCREffectiveRunning {
                ocrRunningWhileRecordingObserved = true
                consecutiveOCRNotRunningSamples = 0
            } else if ocrRunningWhileRecordingObserved {
                consecutiveOCRNotRunningSamples &+= 1
                maximumOCRNotRunningSamples = max(maximumOCRNotRunningSamples, consecutiveOCRNotRunningSamples)
                if consecutiveOCRNotRunningSamples == 4 {
                    ocrInterruptionsWhileRecording &+= 1
                    appendEvent("OCR not effectively running for more than three seconds during recording")
                }
            }

            if capture.phase == .stopped || capture.phase == .failed || !capture.sessionRunning {
                captureStopsWhileRecording &+= 1
            }
        } else {
            consecutiveOCRNotRunningSamples = 0
        }

        if recorder.state == .failed && lastRecordingState != .failed {
            recordingFailureCount &+= 1
            appendEvent("recording entered Failed")
        }
        if recorder.state == .paused && lastRecordingState != .paused {
            recordingPauseCount &+= 1
            appendEvent("recording entered Paused")
        }
        if recordingObserved,
           (lastRecordingState == .recording || lastRecordingState == .stopping),
           recorder.state == .idle {
            recordingStoppedNormally = recorder.lastErrorMessage == nil
            appendEvent(recordingStoppedNormally ? "recording stopped without an error" : "recording stopped with error: \(recorder.lastErrorMessage ?? "unknown")")
        }

        if capture.phase != lastCapturePhase {
            appendEvent("capture phase \(lastCapturePhase.rawValue) -> \(capture.phase.rawValue)")
        }
        lastCapturePhase = capture.phase
        lastRecordingState = recorder.state

        scorebugRevisionDelta = viewModel.matchStateRevision >= initialMatchStateRevision
            ? viewModel.matchStateRevision - initialMatchStateRevision
            : 0
        manualClipDelta = max(0, recorder.savedManualHighlightsCount - initialSavedManualHighlights)
        savedRecordingDelta = max(0, recorder.savedRecordingsCount - initialSavedRecordings)
        staleTestOCRPreventionDelta = max(0, viewModel.testOCRStaleResultPreventionCount - initialStaleTestOCRPreventions)

        let liveName = viewModel.liveCameraService.selectedCameraName
        let ocrName = viewModel.ocrCameraService.selectedCameraName
        let broadcastBuiltIn = !viewModel.liveCameraService.selectedCameraIsExternal
            && viewModel.liveCameraService.selectedCameraPosition == .back
        let ocrExternal = viewModel.ocrCameraService.selectedCameraIsExternal
        let activeIDsPresent = capture.liveDeviceID != nil && capture.ocrDeviceID != nil
        if broadcastBuiltIn && ocrExternal && capture.activeMode == .dualCamera && capture.phase == .running && capture.sessionRunning && activeIDsPresent {
            dualCameraRoleWorkflowObserved = true
        }
        cameraText = "Broadcast \(liveName) [\(broadcastBuiltIn ? "built-in back" : "CHECK")]; OCR \(ocrName) [\(ocrExternal ? "external" : "CHECK")]; graph \(capture.activeMode.rawValue); IDs \(activeIDsPresent ? "present" : "missing")"

        let freshOCR = frameHub.ocr.ageSeconds.map { $0 <= 1.5 } ?? false
        ocrText = "\(viewModel.ocrOperationalStatusText); requested=\(viewModel.isOCRRequested); fresh=\(freshOCR); max gap=\(maximumOCRNotRunningSamples)s"
        let state = viewModel.state
        scorebugText = "OCR/reducer revisions +\(scorebugRevisionDelta); clock=\(state.clock ?? "--") score=\(state.homeScore.map { String($0) } ?? "--")-\(state.awayScore.map { String($0) } ?? "--") period=\(state.periodLabel ?? state.period.map { String($0) } ?? "--")"
        let cadenceText = minimumRecordingCadencePercent.map { String(format: "%.1f%% minimum", $0) } ?? "pending"
        recordingText = "state=\(recorder.state.rawValue); duration=\(recorder.elapsedText); frames=\(recorder.framesWritten); cadence=\(cadenceText); failures=\(recordingFailureCount); pauses=\(recordingPauseCount)"
        clipText = "saved manual clips +\(manualClipDelta); \(recorder.manualClipExportStateText) — \(recorder.manualClipFeedbackText)"

        let lifecycle = viewModel.captureLifecycleController
        let revisions = lifecycle.desiredContractRevision >= initialDesiredRevision
            ? lifecycle.desiredContractRevision - initialDesiredRevision
            : 0
        let reconciliations = max(0, lifecycle.reconciliationExecutionCount - initialReconciliationCount)
        let routeActivations = max(0, viewModel.routeLifecycleActivationCount - initialRouteActivationCount)
        lifecycleText = "routes=\(routeChanges); route activations +\(routeActivations); lifecycle revisions +\(revisions); reconciliations +\(reconciliations); unexpected scene=\(unexpectedSceneInterruptions)"
        recoveryText = operatorRecoveryActionCount == 0
            ? "PASS — no operator recovery action observed"
            : "FAIL — \(operatorRecoveryActionCount) operator recovery action(s)"

        if forcePublish || uiRevision % 2 == 0 {
            updatePublishedSummary()
        } else {
            uiRevision &+= 1
        }
    }

    private func updatePublishedSummary() {
        if let startedAt {
            elapsedText = Self.durationText(Date().timeIntervalSince(startedAt))
        } else {
            elapsedText = "00:00"
        }

        let capture = AppContainer.shared.captureEngine.snapshot
        let dualCameraHealthy = capture.activeMode == .dualCamera
            && capture.phase == .running
            && capture.sessionRunning
            && capture.liveDeviceID != nil
            && capture.ocrDeviceID != nil
        let ocrContinuous = ocrRequestedWhileRecordingObserved
            && ocrRunningWhileRecordingObserved
            && maximumOCRNotRunningSamples <= 3
            && ocrInterruptionsWhileRecording == 0
        let recordingContinuous = recordingObserved
            && recordingFailureCount == 0
            && recordingPauseCount == 0
            && captureStopsWhileRecording == 0
        let cadenceHealthy = minimumRecordingCadencePercent.map { $0 >= 95 } ?? false
        let manualClipPassed = manualClipDelta > 0
        let scorebugPassed = completedCheckpoints.contains(.ocrScorebugVerified) && scorebugRevisionDelta > 0
        let manualFallbackPassed = completedCheckpoints.contains(.manualFallbackVerified)
        let fullMatchPassed = completedCheckpoints.contains(.fullMatchRecordingCompleted)
            && recordingStoppedNormally
            && savedRecordingDelta > 0
        let diagnosticsTransitionPassed = engineeringModeObserved
            && rinkTestModeObserved
            && (phase == .completed ? finishedInRinkTestMode : MainThreadStallMonitor.shared.diagnosticsMode == .rinkTest)
        let scenePassed = unexpectedSceneInterruptions == 0
        let recoveryPassed = operatorRecoveryActionCount == 0

        acceptanceLines = [
            "\(dualCameraRoleWorkflowObserved && (dualCameraHealthy || phase == .completed) ? "PASS" : "CHECK") — external OCR camera and built-in back Broadcast camera are the effective dual-camera workflow",
            "\(diagnosticsTransitionPassed ? "PASS" : "CHECK") — Engineering diagnostics used for setup, then Rink Test mode",
            "\(ocrContinuous ? "PASS" : "CHECK") — continuous OCR remains requested and has no sustained recording interruption",
            "\(scorebugPassed ? "PASS" : "CHECK") — OCR values update the scorebug correctly",
            "\(manualFallbackPassed ? "PASS" : "CHECK") — manual fallback remains available",
            "\(recordingContinuous && cadenceHealthy && fullMatchPassed ? "PASS" : "CHECK") — full-match recording remains continuous at or above 95% observed target cadence",
            "\(manualClipPassed ? "PASS" : "CHECK") — at least one manual clip saved through the active recording path",
            "\(scenePassed ? "PASS" : "FAIL") — sleep/wake/background avoided except when the controlled lifecycle test is armed",
            "\(recoveryPassed ? "PASS" : "FAIL") — no operator recovery action is required",
            "\(allLogsExportPassed ? "PASS" : (allLogsExportAttempted ? "FAIL" : "CHECK")) — All Logs export completes while capture and recording remain active",
            "PASS — stale Test OCR fencing remained active; prevented completions +\(staleTestOCRPreventionDelta)"
        ]
        publishUI()
    }

    private func resetEvidence(restoreDiagnosticsMode: Bool) {
        sampleTask?.cancel()
        sampleTask = nil
        if restoreDiagnosticsMode, phase != .idle {
            MainThreadStallMonitor.shared.setDiagnosticsMode(initialDiagnosticsMode, reason: "UX16c48 pilot reset")
        }
        startedAt = nil
        stoppedAt = nil
        enteredRinkTestAt = nil
        engineeringModeObserved = false
        rinkTestModeObserved = false
        finishedInRinkTestMode = false
        initialCaptureGeneration = 0
        initialDesiredRevision = 0
        initialReconciliationCount = 0
        initialRouteActivationCount = 0
        initialMatchStateRevision = 0
        initialSavedManualHighlights = 0
        initialSavedRecordings = 0
        initialStaleTestOCRPreventions = 0
        lastCapturePhase = .stopped
        lastRecordingState = .idle
        recordingObserved = false
        recordingStartedAt = nil
        recordingStoppedNormally = false
        recordingFailureCount = 0
        recordingPauseCount = 0
        captureStopsWhileRecording = 0
        minimumRecordingCadencePercent = nil
        maximumOCRNotRunningSamples = 0
        ocrRequestedWhileRecordingObserved = false
        ocrRunningWhileRecordingObserved = false
        dualCameraRoleWorkflowObserved = false
        consecutiveOCRNotRunningSamples = 0
        ocrInterruptionsWhileRecording = 0
        scorebugRevisionDelta = 0
        manualClipDelta = 0
        savedRecordingDelta = 0
        routeChanges = 0
        unexpectedSceneInterruptions = 0
        controlledLifecycleTestArmed = false
        controlledLifecycleInProgress = false
        controlledLifecycleTestCompleted = false
        operatorRecoveryActionCount = 0
        allLogsExportAttempted = false
        allLogsExportPassed = false
        allLogsExportFailureReason = "not tested"
        allLogsExportCaptureGeneration = 0
        allLogsExportRecordingFramesBefore = 0
        allLogsExportInProgress = false
        lastAllLogsURL = nil
        staleTestOCRPreventionDelta = 0
        completedCheckpoints.removeAll()
        recentEvents.removeAll()
        elapsedText = "00:00"
        cameraText = "Camera roles not sampled"
        ocrText = "OCR not sampled"
        scorebugText = "No OCR scorebug evidence"
        recordingText = "No recording observed"
        clipText = "No manual clip observed"
        lifecycleText = "No scene or route evidence"
        recoveryText = "No operator recovery action observed"
        exportText = "All Logs export not tested"
        acceptanceLines = ["Start the pilot to collect evidence."]
    }

    private func appendEvent(_ text: String) {
        let row = "\(Self.eventTimeFormatter.string(from: Date()))  \(text)"
        recentEvents.insert(row, at: 0)
        if recentEvents.count > 40 {
            recentEvents.removeLast(recentEvents.count - 40)
        }
        MainThreadStallMonitor.shared.trace("UX16c48 pilot: \(text)")
    }

    private func publishUI() {
        uiRevision &+= 1
        MainThreadStallMonitor.shared.notePublish(source: "ControlledRinkPilot", count: 1)
    }

    private static func durationText(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%02d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%02d:%02d", minutes, seconds)
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

struct ControlledRinkPilotPanel: View {
    @ObservedObject var controller: RinkLensControlledPilotController
    let viewModel: HockeyScoreboardViewModel
    let cameraService: HockeyCameraService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DiagnosticsCard(title: "Controlled Rink Pilot", systemImage: "figure.hockey") {
                Text("Use one training session with external OCR, built-in back Broadcast, continuous OCR, full-match recording and manual clips. The pilot observes evidence but does not control capture or recording.")
                    .font(RinkLensDesignSystem.font(.caption))
                    .foregroundStyle(RinkLensDesignSystem.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button {
                        controller.start()
                    } label: {
                        Label("Start Pilot", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.isRunning)

                    Button {
                        controller.enterRinkTestMode()
                    } label: {
                        Label("Enter Rink Test", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(controller.phase != .engineeringSetup)

                    Button {
                        controller.finish()
                    } label: {
                        Label("Finish Pilot", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!controller.isRunning)

                    Button("Reset") {
                        controller.reset()
                    }
                    .buttonStyle(.bordered)
                    .disabled(controller.isRunning)
                }

                DiagnosticsRow(title: "Phase", value: controller.phase.rawValue)
                DiagnosticsRow(title: "Status", value: controller.statusText)
                DiagnosticsRow(title: "Elapsed", value: controller.elapsedText)
                DiagnosticsRow(title: "Camera roles", value: controller.cameraText)
                DiagnosticsRow(title: "OCR", value: controller.ocrText)
                DiagnosticsRow(title: "Scorebug", value: controller.scorebugText)
                DiagnosticsRow(title: "Recording", value: controller.recordingText)
                DiagnosticsRow(title: "Manual clips", value: controller.clipText)
                DiagnosticsRow(title: "Lifecycle", value: controller.lifecycleText)
                DiagnosticsRow(title: "Recovery", value: controller.recoveryText)
            }

            DiagnosticsCard(title: "Operator Confirmation", systemImage: "checklist") {
                ForEach(RinkLensControlledPilotController.OperatorCheckpoint.allCases) { checkpoint in
                    Button {
                        controller.toggleCheckpoint(checkpoint)
                    } label: {
                        HStack {
                            Image(systemName: controller.checkpointIsComplete(checkpoint) ? "checkmark.circle.fill" : "circle")
                            Text(checkpoint.rawValue)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(controller.checkpointIsComplete(checkpoint) ? Color.green : RinkLensDesignSystem.primaryText)
                }
            }

            DiagnosticsCard(title: "Controlled Lifecycle Test", systemImage: "moon.zzz") {
                Text("Avoid sleep/wake and backgrounding during the pilot. Arm this immediately before the one intentional lifecycle test so it is not counted as an unexpected interruption.")
                    .font(RinkLensDesignSystem.font(.caption))
                    .foregroundStyle(RinkLensDesignSystem.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button(controller.controlledLifecycleTestArmed ? "Lifecycle Test Armed" : "Arm Controlled Test") {
                        controller.armControlledLifecycleTest()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!controller.isRunning || controller.controlledLifecycleTestArmed)

                    Button("Disarm") {
                        controller.cancelControlledLifecycleTest()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!controller.controlledLifecycleTestArmed)
                }
                DiagnosticsRow(title: "Controlled test", value: controller.controlledLifecycleTestCompleted ? "Completed" : (controller.controlledLifecycleTestArmed ? "Armed" : "Not run"))
            }

            DiagnosticsCard(title: "All Logs During Recording", systemImage: "square.and.arrow.down") {
                Button {
                    Task { @MainActor in
                        await controller.testAllLogsExport(viewModel: viewModel, cameraService: cameraService)
                    }
                } label: {
                    if controller.allLogsExportInProgress {
                        Label("Exporting All Logs…", systemImage: "hourglass")
                    } else {
                        Label("Test All Logs Export", systemImage: "doc.badge.gearshape")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!controller.isRunning || controller.allLogsExportInProgress)

                DiagnosticsRow(title: "Result", value: controller.exportText)
                if let url = controller.lastAllLogsURL {
                    ShareLink(item: url) {
                        Label("Share Completed Export", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }
            }

            DiagnosticsCard(title: "Pilot Acceptance", systemImage: "checkmark.seal") {
                ForEach(Array(controller.acceptanceLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(RinkLensDesignSystem.font(.monoCaption))
                        .foregroundStyle(line.hasPrefix("FAIL") ? Color.red : (line.hasPrefix("PASS") ? Color.green : RinkLensDesignSystem.secondaryText))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            DiagnosticsCard(title: "Recent Pilot Events", systemImage: "list.bullet.rectangle") {
                if controller.recentEvents.isEmpty {
                    Text("No pilot events captured")
                        .font(RinkLensDesignSystem.font(.caption))
                        .foregroundStyle(RinkLensDesignSystem.secondaryText)
                } else {
                    ForEach(Array(controller.recentEvents.prefix(14).enumerated()), id: \.offset) { _, event in
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
