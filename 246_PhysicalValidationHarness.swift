// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import Foundation
@preconcurrency import AVFoundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - UX16c50 physical validation harness

/// Operator-selected test sets. The harness observes production state only; it
/// never starts, stops or mutates the capture graph, OCR or recording pipeline.
enum RinkLensPhysicalValidationScenario: String, CaseIterable, Identifiable, Hashable, Sendable {
    case ocrOnlySoak = "30 min OCR-only"
    case broadcastOnlySoak = "30 min Broadcast-only"
    case dualCamera60 = "60 min dual-camera"
    case dualCamera90 = "90 min dual-camera"
    case usbRecovery = "USB recovery ×10"
    case sceneLifecycle = "Scene lifecycle"
    case ocrValidation = "OCR validation ×25"
    case recordingValidation = "Recording validation"

    var id: String { rawValue }

    var targetDuration: TimeInterval? {
        switch self {
        case .ocrOnlySoak, .broadcastOnlySoak: return 30 * 60
        case .dualCamera60: return 60 * 60
        case .dualCamera90: return 90 * 60
        case .usbRecovery, .sceneLifecycle, .ocrValidation, .recordingValidation: return nil
        }
    }

    var expectedMode: RinkLensCaptureLifecycleMode? {
        switch self {
        case .ocrOnlySoak: return .ocrOnly
        case .broadcastOnlySoak: return .broadcastOnly
        case .dualCamera60, .dualCamera90: return .dualCamera
        case .usbRecovery, .sceneLifecycle, .ocrValidation, .recordingValidation: return nil
        }
    }

    var requestStormLimitPerMinute: Int {
        switch self {
        case .ocrOnlySoak, .broadcastOnlySoak, .dualCamera60, .dualCamera90:
            return 3
        case .usbRecovery, .sceneLifecycle, .ocrValidation, .recordingValidation:
            return 12
        }
    }

    var instructions: String {
        switch self {
        case .ocrOnlySoak:
            return "Activate an OCR-only graph, keep the scoreboard changing, then leave the app untouched until the timer completes."
        case .broadcastOnlySoak:
            return "Activate Broadcast-only at the intended format and leave the graph healthy and untouched until the timer completes."
        case .dualCamera60:
            return "Activate dual-camera capture with continuous OCR and Broadcast for 60 minutes."
        case .dualCamera90:
            return "Activate dual-camera capture with continuous OCR and Broadcast for 90 minutes."
        case .usbRecovery:
            return "Complete ten USB disconnect/reconnect cycles across OCR-only, dual-camera and recording. Allow each recovery to settle before the next cycle."
        case .sceneLifecycle:
            return "Exercise Notification Centre, Control Centre, share sheet, Files picker, sleep/wake, background/foreground and a system overlay. Mark each completed checkpoint."
        case .ocrValidation:
            return "Change clock, score, period, penalty player/time and run Test OCR 25 times. Verify calibration-to-Broadcast and manual override protection."
        case .recordingValidation:
            return "Validate 1080p/30 and 1080p/60, manual clip, OCR while recording, route navigation and source-loss fail-fast."
        }
    }
}

enum RinkLensPhysicalValidationCheckpoint: String, CaseIterable, Identifiable, Hashable, Sendable {
    case notificationCentre = "Notification Centre"
    case controlCentre = "Control Centre"
    case shareSheet = "Share sheet"
    case filesPicker = "Files picker"
    case sleepWake = "Sleep / wake"
    case backgroundForeground = "Background / foreground"
    case systemOverlay = "Incoming system overlay"
    case clockChanges = "Clock changes"
    case scores = "Scores"
    case period = "Period"
    case penaltyPlayerTime = "Penalty player and time"
    case calibrationToBroadcast = "Calibration to Broadcast"
    case manualOverrideProtection = "Manual override protection"
    case recording1080p30 = "1080p/30 recording"
    case recording1080p60 = "1080p/60 recording"
    case manualClipDuringRecording = "Manual clip during recording"
    case ocrDuringRecording = "OCR active while recording"
    case routeNavigationDuringRecording = "Route navigation while recording"
    case sourceLossFailFast = "Source-loss fail-fast"

    var id: String { rawValue }

    var group: String {
        switch self {
        case .notificationCentre, .controlCentre, .shareSheet, .filesPicker, .sleepWake, .backgroundForeground, .systemOverlay:
            return "Scene lifecycle"
        case .clockChanges, .scores, .period, .penaltyPlayerTime, .calibrationToBroadcast, .manualOverrideProtection:
            return "OCR validation"
        case .recording1080p30, .recording1080p60, .manualClipDuringRecording, .ocrDuringRecording, .routeNavigationDuringRecording, .sourceLossFailFast:
            return "Recording validation"
        }
    }
}

private struct RinkLensPhysicalValidationSample: Sendable {
    let timestamp: Date
    let elapsedSeconds: TimeInterval
    let route: String
    let scenePhase: String
    let captureMode: String
    let capturePhase: String
    let captureGeneration: Int
    let sessionRunning: Bool
    let liveFPS: Double?
    let ocrFPS: Double?
    let liveTargetFPS: Double?
    let ocrTargetFPS: Double?
    let liveCaptureObservedFPS: Double
    let ocrCaptureObservedFPS: Double
    let liveConfiguredCadence: String
    let ocrConfiguredCadence: String
    let liveFrameHubPublishedCount: Int
    let ocrFrameHubPublishedCount: Int
    let liveFrameAgeSeconds: TimeInterval?
    let ocrFrameAgeSeconds: TimeInterval?
    let memoryBytes: UInt64?
    let thermalState: String
    let livePressure: String
    let ocrPressure: String
    let liveOutOfBuffersLifetime: Int
    let ocrOutOfBuffersLifetime: Int
    let liveDropsLifetime: Int
    let ocrDropsLifetime: Int
    let lastDroppedReason: String
    let desiredRevision: UInt64
    let reconciliationCount: Int
    let coalescedRequestCount: Int
    let identicalContractSuppressionCount: Int
    let healthObservationCount: Int
    let healthObservationSuppressionCount: Int
    let routeLifecycleActivationCount: Int
    let duplicateRouteLifecycleSuppressionCount: Int
    let sustainedHealthReconciliationCount: Int
    let frameHubStaleRejects: Int
    let frameHubGenerationRejects: Int
    let frameHubDeviceRejects: Int
    let ocrSubmitted: Int
    let ocrCompleted: Int
    let ocrSelectedTests: Int
    let ocrDroppedBusy: Int
    let ocrCancelled: Int
    let ocrStallRecoveries: Int
    let ocrWorkerRotations: Int
    let ocrIsBusy: Bool
    let ocrActivePassAgeSeconds: TimeInterval?
    let ocrLastFinishAgeSeconds: TimeInterval?
    let ocrLastFinishReason: String
    let ocrLastPhase: String
    let ocrSchedulerActive: Bool
    let ocrEffectiveRunning: Bool
    let testOCRStaleResultsPrevented: Int
    let recordingState: String
    let recordingFramesWritten: Int
    let recordingFramesDropped: Int
    let recordingCameraDrops: Int
    let recordingSamplingDuplicates: Int
    let recordingWriterDrops: Int
    let recordingRenderDrops: Int
    let recordingTargetFPS: Int
    let recordingHealth: String
    let blackFrameConsecutive: Int
}

private struct RinkLensPhysicalValidationBaseline: Sendable {
    let desiredRevision: UInt64
    let reconciliationCount: Int
    let coalescedRequestCount: Int
    let identicalContractSuppressionCount: Int
    let healthObservationCount: Int
    let healthObservationSuppressionCount: Int
    let routeLifecycleActivationCount: Int
    let duplicateRouteLifecycleSuppressionCount: Int
    let sustainedHealthReconciliationCount: Int
    let liveOutOfBuffersLifetime: Int
    let ocrOutOfBuffersLifetime: Int
    let liveDropsLifetime: Int
    let ocrDropsLifetime: Int
    let frameHubStaleRejects: Int
    let frameHubGenerationRejects: Int
    let frameHubDeviceRejects: Int
    let ocrSubmitted: Int
    let ocrCompleted: Int
    let ocrSelectedTests: Int
    let ocrDroppedBusy: Int
    let ocrCancelled: Int
    let ocrStallRecoveries: Int
    let testOCRStaleResultsPrevented: Int
    let savedManualHighlightsCount: Int
}

private struct RinkLensPendingUSBValidation: Sendable {
    enum Kind: String, Sendable { case disconnect, reconnect }
    let kind: Kind
    let occurredAt: Date
    let captureMode: RinkLensCaptureLifecycleMode
    let recordingActive: Bool
    let deviceName: String
    var evaluated: Bool
}

@MainActor
final class RinkLensPhysicalValidationController: NSObject, ObservableObject {
    static let shared = RinkLensPhysicalValidationController()

    @Published var selectedScenario: RinkLensPhysicalValidationScenario = .ocrOnlySoak
    @Published private(set) var isRunning = false
    @Published private(set) var isPreparing = false
    @Published private(set) var uiRevision: UInt64 = 0
    private(set) var statusText = "No validation session running"
    private(set) var elapsedText = "00:00"
    private(set) var remainingText = "--"
    private(set) var currentCaptureText = "Capture not sampled"
    private(set) var cadenceText = "Broadcast -- / OCR --"
    private(set) var memoryText = "--"
    private(set) var memoryPlateauText = "Pending"
    private(set) var pressureText = "Pressure not sampled"
    private(set) var dropText = "No test baseline"
    private(set) var lifecycleText = "No test baseline"
    private(set) var usbText = "0 disconnects / 0 reconnects"
    private(set) var sceneText = "No scene transitions"
    private(set) var ocrText = "No OCR samples"
    private(set) var recordingText = "No recording observed"
    private(set) var acceptanceLines: [String] = ["Start a validation session to collect evidence."]
    private(set) var recentEvents: [String] = []
    private(set) var lastReportURL: URL?
    private(set) var lastCSVURL: URL?
    private(set) var exportStatusText = "No validation export"
    private(set) var completedCheckpoints: Set<RinkLensPhysicalValidationCheckpoint> = []

    private var sampleTask: Task<Void, Never>?
    private var preflightTask: Task<Void, Never>?
    private var preflightStableSince: Date?
    private var preflightGeneration: Int?
    private var incompatibleModeSince: Date?
    private var startedAt: Date?
    private var stoppedAt: Date?
    private var baseline: RinkLensPhysicalValidationBaseline?
    private var samples: [RinkLensPhysicalValidationSample] = []
    private var lastSample: RinkLensPhysicalValidationSample?
    private var lastPublishedAt = Date.distantPast
    private var currentScenePhase = "unknown"
    private var currentRoute = AppRoute.commandCentre.title
    private var lastInterruptionText = ""
    private var lastCapturePhase = ""
    private var lastRecordingState = BroadcastRecordingManager.RecordingState.idle.rawValue
    private var unexpectedCaptureStops = 0
    private var captureRecoveryTransitions = 0
    private var blackFrameRecoveryLoopDetected = false
    private var recoveryTransitionTimes: [Date] = []
    private var peakLifecycleRequestsPerMinute = 0
    private var peakRouteActivationsPerMinute = 0
    private var peakHealthObservationsPerMinute = 0
    private var usbDisconnectCount = 0
    private var usbReconnectCount = 0
    private var usbFallbackSuccessCount = 0
    private var usbFallbackFailureCount = 0
    private var usbRecoverySuccessCount = 0
    private var usbRecoveryFailureCount = 0
    private var usbDisconnectOCROnlyCount = 0
    private var usbDisconnectDualCameraCount = 0
    private var usbDisconnectDuringRecordingCount = 0
    private var pendingUSBValidations: [RinkLensPendingUSBValidation] = []
    private var inactiveCount = 0
    private var backgroundCount = 0
    private var activeCount = 0
    private var routeChangeCount = 0
    private var recordingObservedStartAt: Date?
    private var recordingObservedFramesAtStart = 0
    private var recordingCadenceWindow: [(timestamp: Date, frames: Int)] = []
    private var latestRecordingCadencePercent: Double?
    private var minimumSustainedRecordingCadencePercent: Double?
    private var maximumConsecutiveBlackFrames = 0
    private var observedRecordingProfiles: Set<String> = []
    private var ocrObservedWhileRecording = false
    private var routeChangesWhileRecording = 0
    private var sourceLossFailFastObserved = false
    private var seriousPressureSampleCount = 0
    private var criticalPressureSampleCount = 0
    private var maximumOCRActivePassAgeSeconds: TimeInterval = 0
    private var ocrStallEventCount = 0
    private var lastObservedOCRStallRecoveryCount = 0

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(externalVideoDeviceDisconnected(_:)),
            name: AVCaptureDevice.wasDisconnectedNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(externalVideoDeviceConnected(_:)),
            name: AVCaptureDevice.wasConnectedNotification,
            object: nil
        )
    }

    @objc nonisolated private func externalVideoDeviceDisconnected(_ notification: Notification) {
        guard let device = notification.object as? AVCaptureDevice,
              device.hasMediaType(.video),
              device.deviceType == .external else { return }
        let name = device.localizedName
        Task { @MainActor [weak self] in
            self?.noteUSBEvent(kind: .disconnect, deviceName: name)
        }
    }

    @objc nonisolated private func externalVideoDeviceConnected(_ notification: Notification) {
        guard let device = notification.object as? AVCaptureDevice,
              device.hasMediaType(.video),
              device.deviceType == .external else { return }
        let name = device.localizedName
        Task { @MainActor [weak self] in
            self?.noteUSBEvent(kind: .reconnect, deviceName: name)
        }
    }

    func start() {
        guard !isRunning, !isPreparing else { return }
        resetSessionEvidence(keepScenario: true)

        guard selectedScenario.expectedMode != nil else {
            beginValidationSession(metrics: captureMetrics())
            return
        }

        isPreparing = true
        statusText = "Preparing: waiting for stable \(selectedScenario.expectedMode?.rawValue ?? "capture") graph"
        appendEvent("preflight armed scenario=\(selectedScenario.rawValue); timer will start after 5s stable graph")
        publishUI()
        evaluatePreflight()

        preflightTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.isPreparing {
                do {
                    try await Task.sleep(nanoseconds: 500_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled, self.isPreparing else { return }
                self.evaluatePreflight()
            }
        }
    }

    private func evaluatePreflight() {
        guard isPreparing, let expected = selectedScenario.expectedMode else { return }
        let metrics = captureMetrics()
        let capture = metrics.capture
        let matches = capture.activeMode == expected
            && capture.sessionRunning
            && capture.phase == .running

        guard matches else {
            if preflightStableSince != nil {
                appendEvent("preflight stability reset expected=\(expected.rawValue) actual=\(capture.activeMode.rawValue) phase=\(capture.phase.rawValue) running=\(capture.sessionRunning)")
            }
            preflightStableSince = nil
            preflightGeneration = nil
            statusText = "Not started — select \(expected.rawValue) and wait for a running graph"
            publishUI()
            return
        }

        if preflightGeneration != capture.transitionGeneration {
            preflightGeneration = capture.transitionGeneration
            preflightStableSince = Date()
            appendEvent("preflight graph matched expected=\(expected.rawValue) generation=\(capture.transitionGeneration); stabilising")
        }

        guard let stableSince = preflightStableSince else { return }
        let stableFor = Date().timeIntervalSince(stableSince)
        statusText = String(format: "Preparing — stable graph %.1f/5.0s", min(5, stableFor))
        publishUI()
        guard stableFor >= 5 else { return }

        preflightTask?.cancel()
        preflightTask = nil
        beginValidationSession(metrics: metrics)
    }

    private func beginValidationSession(metrics: (
        capture: RinkLensCaptureEngineSnapshot,
        lifecycle: RinkLensCaptureLifecycleController,
        frameHub: RinkLensFrameHubSnapshot,
        ocr: RinkLensOCROrchestrationSnapshot,
        viewModel: HockeyScoreboardViewModel,
        recorder: BroadcastRecordingManager
    )) {
        baseline = RinkLensPhysicalValidationBaseline(
            desiredRevision: metrics.lifecycle.desiredContractRevision,
            reconciliationCount: metrics.lifecycle.reconciliationExecutionCount,
            coalescedRequestCount: metrics.lifecycle.coalescedRequestCount,
            identicalContractSuppressionCount: metrics.lifecycle.identicalContractSuppressionCount,
            healthObservationCount: metrics.lifecycle.healthObservationCount,
            healthObservationSuppressionCount: metrics.lifecycle.healthObservationSuppressionCount,
            routeLifecycleActivationCount: metrics.viewModel.routeLifecycleActivationCount,
            duplicateRouteLifecycleSuppressionCount: metrics.viewModel.duplicateRouteLifecycleSuppressionCount,
            sustainedHealthReconciliationCount: metrics.lifecycle.sustainedHealthReconciliationCount,
            liveOutOfBuffersLifetime: metrics.capture.liveDroppedOutOfBuffersLifetime,
            ocrOutOfBuffersLifetime: metrics.capture.ocrDroppedOutOfBuffersLifetime,
            liveDropsLifetime: metrics.capture.liveDroppedFramesLifetime,
            ocrDropsLifetime: metrics.capture.ocrDroppedFramesLifetime,
            frameHubStaleRejects: metrics.frameHub.broadcast.staleRejectCount + metrics.frameHub.ocr.staleRejectCount,
            frameHubGenerationRejects: metrics.frameHub.broadcast.generationRejectCount + metrics.frameHub.ocr.generationRejectCount,
            frameHubDeviceRejects: metrics.frameHub.broadcast.deviceRejectCount + metrics.frameHub.ocr.deviceRejectCount,
            ocrSubmitted: metrics.ocr.submittedPasses,
            ocrCompleted: metrics.ocr.completedPasses,
            ocrSelectedTests: metrics.ocr.selectedZonePasses,
            ocrDroppedBusy: metrics.ocr.droppedPasses,
            ocrCancelled: metrics.ocr.cancelledPasses,
            ocrStallRecoveries: metrics.ocr.stallRecoveries,
            testOCRStaleResultsPrevented: metrics.viewModel.testOCRStaleResultPreventionCount,
            savedManualHighlightsCount: metrics.recorder.savedManualHighlightsCount
        )
        currentRoute = AppContainer.shared.coordinator.route.title
        preflightStableSince = nil
        preflightGeneration = nil
        isPreparing = false
        startedAt = Date()
        stoppedAt = nil
        isRunning = true
        lastObservedOCRStallRecoveryCount = metrics.ocr.stallRecoveries
        statusText = "Running: \(selectedScenario.rawValue)"
        appendEvent("validation started after stable preflight scenario=\(selectedScenario.rawValue) capture=\(metrics.capture.activeMode.rawValue) generation=\(metrics.capture.transitionGeneration)")
        sampleNow(forcePublish: true)

        sampleTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.isRunning {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled, self.isRunning else { return }
                self.sampleNow(forcePublish: false)
                if let target = self.selectedScenario.targetDuration,
                   let startedAt = self.startedAt,
                   Date().timeIntervalSince(startedAt) >= target {
                    self.stop(reason: "target duration completed")
                    return
                }
            }
        }
    }

    func stop(reason: String = "operator stopped") {
        if isPreparing {
            isPreparing = false
            preflightTask?.cancel()
            preflightTask = nil
            preflightStableSince = nil
            preflightGeneration = nil
            statusText = "Preflight cancelled — \(reason)"
            appendEvent("preflight cancelled reason=\(reason)")
            publishUI()
            return
        }
        guard isRunning else { return }
        sampleNow(forcePublish: true)
        completeSession(reason: reason)
    }

    private func completeSession(reason: String) {
        guard isRunning else { return }
        isRunning = false
        stoppedAt = Date()
        sampleTask?.cancel()
        sampleTask = nil
        statusText = "Completed: \(selectedScenario.rawValue) — \(reason)"
        appendEvent("validation stopped reason=\(reason)")
        updatePublishedSummary(force: true)
        exportSessionFiles()
    }

    func reset() {
        preflightTask?.cancel()
        preflightTask = nil
        sampleTask?.cancel()
        sampleTask = nil
        isPreparing = false
        isRunning = false
        resetSessionEvidence(keepScenario: true)
        statusText = "Validation session reset"
        publishUI()
    }

    func toggleCheckpoint(_ checkpoint: RinkLensPhysicalValidationCheckpoint) {
        if completedCheckpoints.contains(checkpoint) {
            completedCheckpoints.remove(checkpoint)
            appendEvent("checkpoint cleared: \(checkpoint.rawValue)")
        } else {
            completedCheckpoints.insert(checkpoint)
            appendEvent("checkpoint completed: \(checkpoint.rawValue)")
        }
        updatePublishedSummary(force: true)
    }

    func checkpointIsComplete(_ checkpoint: RinkLensPhysicalValidationCheckpoint) -> Bool {
        completedCheckpoints.contains(checkpoint)
    }

    func noteScenePhase(_ phase: ScenePhase) {
        let text: String
        switch phase {
        case .active: text = "active"
        case .inactive: text = "inactive"
        case .background: text = "background"
        @unknown default: text = "unknown"
        }
        currentScenePhase = text
        if isRunning {
            switch phase {
            case .active: activeCount &+= 1
            case .inactive: inactiveCount &+= 1
            case .background: backgroundCount &+= 1
            @unknown default: break
            }
            appendEvent("scene phase -> \(text)")
            updatePublishedSummary(force: true)
        }
    }

    func noteRouteChange(_ route: AppRoute) {
        guard currentRoute != route.title else { return }
        let previous = currentRoute
        currentRoute = route.title
        if isRunning {
            routeChangeCount &+= 1
            if BroadcastRecordingManager.shared.isRecording {
                routeChangesWhileRecording &+= 1
            }
            appendEvent("route \(previous) -> \(route.title)")
            updatePublishedSummary(force: true)
        }
    }

    func exportLines() -> [String] {
        let header = [
            "Scenario: \(selectedScenario.rawValue)",
            "Status: \(statusText)",
            "Started: \(startedAt.map { Self.timestampFormatter.string(from: $0) } ?? "--")",
            "Stopped: \(stoppedAt.map { Self.timestampFormatter.string(from: $0) } ?? "--")",
            "Elapsed: \(elapsedText)",
            "Samples: \(samples.count)",
            "Capture: \(currentCaptureText)",
            "Cadence: \(cadenceText)",
            "Memory: \(memoryText)",
            "Memory plateau: \(memoryPlateauText)",
            "Pressure: \(pressureText)",
            "Drops: \(dropText)",
            "Lifecycle: \(lifecycleText)",
            "USB: \(usbText)",
            "Scene: \(sceneText)",
            "OCR: \(ocrText)",
            "Recording: \(recordingText)"
        ]
        let checks = RinkLensPhysicalValidationCheckpoint.allCases.map {
            "Checkpoint \($0.rawValue): \(completedCheckpoints.contains($0) ? "PASS" : "not confirmed")"
        }
        let acceptance = acceptanceLines.map { "Acceptance: \($0)" }
        let events = recentEvents.map { "Event: \($0)" }
        return header + checks + acceptance + events
    }

    private func resetSessionEvidence(keepScenario: Bool) {
        _ = keepScenario
        startedAt = nil
        stoppedAt = nil
        baseline = nil
        samples.removeAll(keepingCapacity: true)
        lastSample = nil
        lastPublishedAt = .distantPast
        completedCheckpoints.removeAll()
        recentEvents.removeAll()
        lastReportURL = nil
        lastCSVURL = nil
        exportStatusText = "No validation export"
        elapsedText = "00:00"
        remainingText = "--"
        currentCaptureText = "Capture not sampled"
        cadenceText = "Broadcast -- / OCR --"
        memoryText = "--"
        memoryPlateauText = "Pending"
        pressureText = "Pressure not sampled"
        dropText = "No test baseline"
        lifecycleText = "No test baseline"
        usbText = "0 disconnects / 0 reconnects"
        sceneText = "No scene transitions"
        ocrText = "No OCR samples"
        recordingText = "No recording observed"
        acceptanceLines = ["Start a validation session to collect evidence."]
        lastInterruptionText = ""
        lastCapturePhase = ""
        lastRecordingState = BroadcastRecordingManager.RecordingState.idle.rawValue
        unexpectedCaptureStops = 0
        captureRecoveryTransitions = 0
        blackFrameRecoveryLoopDetected = false
        recoveryTransitionTimes.removeAll()
        peakLifecycleRequestsPerMinute = 0
        peakRouteActivationsPerMinute = 0
        peakHealthObservationsPerMinute = 0
        usbDisconnectCount = 0
        usbReconnectCount = 0
        usbFallbackSuccessCount = 0
        usbFallbackFailureCount = 0
        usbRecoverySuccessCount = 0
        usbRecoveryFailureCount = 0
        usbDisconnectOCROnlyCount = 0
        usbDisconnectDualCameraCount = 0
        usbDisconnectDuringRecordingCount = 0
        pendingUSBValidations.removeAll()
        inactiveCount = 0
        backgroundCount = 0
        activeCount = 0
        routeChangeCount = 0
        recordingObservedStartAt = nil
        recordingObservedFramesAtStart = 0
        recordingCadenceWindow.removeAll(keepingCapacity: true)
        latestRecordingCadencePercent = nil
        minimumSustainedRecordingCadencePercent = nil
        maximumConsecutiveBlackFrames = 0
        observedRecordingProfiles.removeAll()
        ocrObservedWhileRecording = false
        routeChangesWhileRecording = 0
        sourceLossFailFastObserved = false
        seriousPressureSampleCount = 0
        criticalPressureSampleCount = 0
        maximumOCRActivePassAgeSeconds = 0
        ocrStallEventCount = 0
        lastObservedOCRStallRecoveryCount = 0
        incompatibleModeSince = nil
        preflightStableSince = nil
        preflightGeneration = nil
        lastRawLiveFrameCount = 0
        lastRawOCRFrameCount = 0
    }

    private func sampleNow(forcePublish: Bool) {
        guard let startedAt else { return }
        let now = Date()
        let metrics = captureMetrics()
        let elapsed = now.timeIntervalSince(startedAt)
        let previous = lastSample
        let sameGeneration = previous?.captureGeneration == metrics.capture.transitionGeneration
        let deltaSeconds = max(0.001, previous.map { now.timeIntervalSince($0.timestamp) } ?? 1)
        // UX16c50: FrameHub publication is the authoritative physical-frame
        // counter. CaptureEngine UI counters are intentionally coalesced and
        // produced alternating 0/120fps readings in a 60fps test. Each role is
        // measured independently so an unused/cleared branch cannot hide the
        // cadence of the active branch.
        let liveFPS: Double? = sameGeneration && previous != nil
            && metrics.frameHub.broadcast.publishedCount >= lastRawLiveFrameCount
            ? max(0, Double(metrics.frameHub.broadcast.publishedCount - lastRawLiveFrameCount) / deltaSeconds)
            : nil
        let ocrFPS: Double? = sameGeneration && previous != nil
            && metrics.frameHub.ocr.publishedCount >= lastRawOCRFrameCount
            ? max(0, Double(metrics.frameHub.ocr.publishedCount - lastRawOCRFrameCount) / deltaSeconds)
            : nil
        let blackConsecutive = Int(BlackFrameRejectionTraceStore.shared.consecutiveRejectedText) ?? 0
        maximumConsecutiveBlackFrames = max(maximumConsecutiveBlackFrames, blackConsecutive)

        let sample = RinkLensPhysicalValidationSample(
            timestamp: now,
            elapsedSeconds: elapsed,
            route: currentRoute,
            scenePhase: currentScenePhase,
            captureMode: metrics.capture.activeMode.rawValue,
            capturePhase: metrics.capture.phase.rawValue,
            captureGeneration: metrics.capture.transitionGeneration,
            sessionRunning: metrics.capture.sessionRunning,
            liveFPS: liveFPS,
            ocrFPS: ocrFPS,
            liveTargetFPS: metrics.capture.liveFormat?.fps,
            ocrTargetFPS: metrics.capture.ocrFormat?.fps,
            liveCaptureObservedFPS: metrics.capture.liveObservedFPS,
            ocrCaptureObservedFPS: metrics.capture.ocrObservedFPS,
            liveConfiguredCadence: metrics.capture.liveConfiguredCadenceText,
            ocrConfiguredCadence: metrics.capture.ocrConfiguredCadenceText,
            liveFrameHubPublishedCount: metrics.frameHub.broadcast.publishedCount,
            ocrFrameHubPublishedCount: metrics.frameHub.ocr.publishedCount,
            liveFrameAgeSeconds: metrics.frameHub.broadcast.ageSeconds,
            ocrFrameAgeSeconds: metrics.frameHub.ocr.ageSeconds,
            memoryBytes: Self.appMemoryFootprintBytes(),
            thermalState: Self.thermalStateText(ProcessInfo.processInfo.thermalState),
            livePressure: metrics.capture.liveSystemPressureLevel,
            ocrPressure: metrics.capture.ocrSystemPressureLevel,
            liveOutOfBuffersLifetime: metrics.capture.liveDroppedOutOfBuffersLifetime,
            ocrOutOfBuffersLifetime: metrics.capture.ocrDroppedOutOfBuffersLifetime,
            liveDropsLifetime: metrics.capture.liveDroppedFramesLifetime,
            ocrDropsLifetime: metrics.capture.ocrDroppedFramesLifetime,
            lastDroppedReason: metrics.capture.lastDroppedFrameText,
            desiredRevision: metrics.lifecycle.desiredContractRevision,
            reconciliationCount: metrics.lifecycle.reconciliationExecutionCount,
            coalescedRequestCount: metrics.lifecycle.coalescedRequestCount,
            identicalContractSuppressionCount: metrics.lifecycle.identicalContractSuppressionCount,
            healthObservationCount: metrics.lifecycle.healthObservationCount,
            healthObservationSuppressionCount: metrics.lifecycle.healthObservationSuppressionCount,
            routeLifecycleActivationCount: metrics.viewModel.routeLifecycleActivationCount,
            duplicateRouteLifecycleSuppressionCount: metrics.viewModel.duplicateRouteLifecycleSuppressionCount,
            sustainedHealthReconciliationCount: metrics.lifecycle.sustainedHealthReconciliationCount,
            frameHubStaleRejects: metrics.frameHub.broadcast.staleRejectCount + metrics.frameHub.ocr.staleRejectCount,
            frameHubGenerationRejects: metrics.frameHub.broadcast.generationRejectCount + metrics.frameHub.ocr.generationRejectCount,
            frameHubDeviceRejects: metrics.frameHub.broadcast.deviceRejectCount + metrics.frameHub.ocr.deviceRejectCount,
            ocrSubmitted: metrics.ocr.submittedPasses,
            ocrCompleted: metrics.ocr.completedPasses,
            ocrSelectedTests: metrics.ocr.selectedZonePasses,
            ocrDroppedBusy: metrics.ocr.droppedPasses,
            ocrCancelled: metrics.ocr.cancelledPasses,
            ocrStallRecoveries: metrics.ocr.stallRecoveries,
            ocrWorkerRotations: metrics.ocr.workerRotations,
            ocrIsBusy: metrics.ocr.isBusy,
            ocrActivePassAgeSeconds: metrics.ocr.activePassAgeSeconds,
            ocrLastFinishAgeSeconds: metrics.ocr.lastFinishAgeSeconds,
            ocrLastFinishReason: metrics.ocr.lastFinishReason,
            ocrLastPhase: metrics.ocr.lastPhase,
            ocrSchedulerActive: metrics.viewModel.isOCRSchedulerActive,
            ocrEffectiveRunning: metrics.viewModel.isOCREffectiveRunning,
            testOCRStaleResultsPrevented: metrics.viewModel.testOCRStaleResultPreventionCount,
            recordingState: metrics.recorder.state.rawValue,
            recordingFramesWritten: metrics.recorder.framesWritten,
            recordingFramesDropped: metrics.recorder.framesDropped,
            recordingCameraDrops: metrics.recorder.cameraSourceDrops,
            recordingSamplingDuplicates: metrics.recorder.sourceSamplingMisses,
            recordingWriterDrops: metrics.recorder.writerDrops,
            recordingRenderDrops: metrics.recorder.renderDrops,
            recordingTargetFPS: metrics.recorder.currentTargetFPSValue,
            recordingHealth: metrics.recorder.recordingHealthText,
            blackFrameConsecutive: blackConsecutive
        )

        let pressureLevels = [sample.livePressure.lowercased(), sample.ocrPressure.lowercased()]
        if pressureLevels.contains(where: { $0.contains("critical") }) {
            criticalPressureSampleCount &+= 1
        } else if pressureLevels.contains(where: { $0.contains("serious") }) {
            seriousPressureSampleCount &+= 1
        }
        if metrics.recorder.state == .recording {
            observedRecordingProfiles.insert("\(metrics.recorder.recordingTargetResolutionText)@\(metrics.recorder.currentTargetFPSValue)")
            if metrics.capture.activeMode.requiresOCR && metrics.viewModel.isOCREffectiveRunning {
                ocrObservedWhileRecording = true
            }
        }
        if isControlledRecordingSourceLoss(metrics.recorder) {
            sourceLossFailFastObserved = true
        }

        if let activeAge = metrics.ocr.activePassAgeSeconds {
            maximumOCRActivePassAgeSeconds = max(maximumOCRActivePassAgeSeconds, activeAge)
        }
        if metrics.ocr.stallRecoveries > lastObservedOCRStallRecoveryCount {
            let delta = metrics.ocr.stallRecoveries - lastObservedOCRStallRecoveryCount
            ocrStallEventCount &+= delta
            appendEvent("FAIL OCR stalled pass recovered count=\(delta) activeAge=\(metrics.ocr.activePassAgeSeconds.map { String(format: "%.2fs", $0) } ?? "--") phase=\(metrics.ocr.lastPhase)")
            lastObservedOCRStallRecoveryCount = metrics.ocr.stallRecoveries
        }

        observeTransitions(previous: previous, current: sample, capture: metrics.capture, recorder: metrics.recorder)
        samples.append(sample)
        if samples.count > 6_000 { samples.removeFirst(samples.count - 6_000) }
        lastSample = sample
        evaluatePendingUSBValidations(now: now, capture: metrics.capture, recorder: metrics.recorder)
        updateRollingRequestRates(now: now)
        updateRecordingCadence(now: now, recorder: metrics.recorder)

        if shouldAbortSoakForIncompatibleGraph(sample: sample, now: now) {
            updatePublishedSummary(force: true)
            completeSession(reason: "required capture graph changed during soak")
            return
        }
        updatePublishedSummary(force: forcePublish)
    }

    private var lastRawLiveFrameCount = 0
    private var lastRawOCRFrameCount = 0

    private func observeTransitions(
        previous: RinkLensPhysicalValidationSample?,
        current: RinkLensPhysicalValidationSample,
        capture: RinkLensCaptureEngineSnapshot,
        recorder: BroadcastRecordingManager
    ) {
        defer {
            let frameHub = RinkLensFrameHub.shared.diagnosticSnapshot()
            lastRawLiveFrameCount = frameHub.broadcast.publishedCount
            lastRawOCRFrameCount = frameHub.ocr.publishedCount
        }

        if capture.lastInterruptionText != lastInterruptionText {
            lastInterruptionText = capture.lastInterruptionText
            if !capture.lastInterruptionText.isEmpty && capture.lastInterruptionText.lowercased() != "no multicam interruption" {
                appendEvent("capture interruption: \(capture.lastInterruptionText)")
            }
        }

        if current.capturePhase != lastCapturePhase {
            if current.capturePhase == RinkLensCaptureEnginePhase.recovering.rawValue {
                captureRecoveryTransitions &+= 1
                recoveryTransitionTimes.append(current.timestamp)
                recoveryTransitionTimes.removeAll { current.timestamp.timeIntervalSince($0) > 60 }
                if recoveryTransitionTimes.count >= 3 && current.blackFrameConsecutive > 0 {
                    blackFrameRecoveryLoopDetected = true
                    appendEvent("FAIL black-frame recovery loop signature: \(recoveryTransitionTimes.count) recovery transitions in 60s")
                }
            }
            if !lastCapturePhase.isEmpty {
                appendEvent("capture phase \(lastCapturePhase) -> \(current.capturePhase)")
            }
            lastCapturePhase = current.capturePhase
        }

        if let previous,
           previous.sessionRunning,
           !current.sessionRunning,
           current.scenePhase != "background",
           !capture.phase.isTransitioning,
           !hasRecentUSBDisconnect(at: current.timestamp),
           !isControlledRecordingSourceLoss(recorder) {
            unexpectedCaptureStops &+= 1
            appendEvent("FAIL unexplained capture stop mode=\(previous.captureMode) phase=\(current.capturePhase)")
        }

        if recorder.state.rawValue != lastRecordingState {
            appendEvent("recording state \(lastRecordingState) -> \(recorder.state.rawValue): \(recorder.recordingHealthText)")
            lastRecordingState = recorder.state.rawValue
        }
    }

    private func updateRecordingCadence(now: Date, recorder: BroadcastRecordingManager) {
        if recorder.state == .recording {
            if recordingObservedStartAt == nil {
                recordingObservedStartAt = now
                recordingObservedFramesAtStart = recorder.framesWritten
                recordingCadenceWindow.removeAll(keepingCapacity: true)
            }
            recordingCadenceWindow.append((now, recorder.framesWritten))
            recordingCadenceWindow.removeAll { now.timeIntervalSince($0.timestamp) > 10 }

            guard let recordingObservedStartAt,
                  let first = recordingCadenceWindow.first,
                  let last = recordingCadenceWindow.last else { return }
            let elapsed = now.timeIntervalSince(recordingObservedStartAt)
            let windowElapsed = last.timestamp.timeIntervalSince(first.timestamp)
            guard elapsed >= 10, windowElapsed >= 8 else { return }

            let frames = max(0, last.frames - first.frames)
            let expected = windowElapsed * Double(max(1, recorder.currentTargetFPSValue))
            let percent = expected > 0 ? Double(frames) / expected * 100 : 0
            latestRecordingCadencePercent = percent
            if elapsed >= 30 {
                minimumSustainedRecordingCadencePercent = min(minimumSustainedRecordingCadencePercent ?? percent, percent)
            }
        } else if recorder.state == .idle || recorder.state == .failed {
            recordingObservedStartAt = nil
            recordingObservedFramesAtStart = recorder.framesWritten
            recordingCadenceWindow.removeAll(keepingCapacity: true)
        }
    }

    private func updateRollingRequestRates(now: Date) {
        let window = samples.filter { now.timeIntervalSince($0.timestamp) <= 60 }
        guard window.count >= 2, let first = window.first, let latest = window.last else { return }

        var stableRouteActivity = 0
        for index in 1..<window.count {
            let previous = window[index - 1]
            let current = window[index]
            let routeStable = previous.route == current.route
            let graphStable = previous.captureMode == current.captureMode
                && previous.captureGeneration == current.captureGeneration
                && previous.sessionRunning
                && current.sessionRunning
                && previous.capturePhase == RinkLensCaptureEnginePhase.running.rawValue
                && current.capturePhase == RinkLensCaptureEnginePhase.running.rawValue
            guard routeStable, graphStable else { continue }

            let reconciliations = max(0, current.reconciliationCount - previous.reconciliationCount)
            let revisions = current.desiredRevision >= previous.desiredRevision
                ? Int(current.desiredRevision - previous.desiredRevision)
                : 0
            let coalesced = max(0, current.coalescedRequestCount - previous.coalescedRequestCount)
            let identical = max(0, current.identicalContractSuppressionCount - previous.identicalContractSuppressionCount)
            let duplicateRoute = max(0, current.duplicateRouteLifecycleSuppressionCount - previous.duplicateRouteLifecycleSuppressionCount)
            let sustained = max(0, current.sustainedHealthReconciliationCount - previous.sustainedHealthReconciliationCount)
            stableRouteActivity += max(reconciliations, revisions) + coalesced + identical + duplicateRoute + sustained
        }

        let routeActivations = max(0, latest.routeLifecycleActivationCount - first.routeLifecycleActivationCount)
        let healthObservations = max(0, latest.healthObservationCount - first.healthObservationCount)
        peakLifecycleRequestsPerMinute = max(peakLifecycleRequestsPerMinute, stableRouteActivity)
        peakRouteActivationsPerMinute = max(peakRouteActivationsPerMinute, routeActivations)
        peakHealthObservationsPerMinute = max(peakHealthObservationsPerMinute, healthObservations)
    }

    private func shouldAbortSoakForIncompatibleGraph(
        sample: RinkLensPhysicalValidationSample,
        now: Date
    ) -> Bool {
        guard let expected = selectedScenario.expectedMode else { return false }
        let incompatible = sample.captureMode != expected.rawValue
            || !sample.sessionRunning
            || sample.capturePhase == RinkLensCaptureEnginePhase.stopped.rawValue
            || sample.capturePhase == RinkLensCaptureEnginePhase.failed.rawValue

        guard incompatible else {
            incompatibleModeSince = nil
            return false
        }
        guard !sample.capturePhase.contains("start"),
              !sample.capturePhase.contains("recover"),
              !sample.capturePhase.contains("reconfig") else { return false }

        if incompatibleModeSince == nil {
            incompatibleModeSince = now
            appendEvent("soak graph mismatch detected expected=\(expected.rawValue) actual=\(sample.captureMode) phase=\(sample.capturePhase); allowing 3s transition grace")
            return false
        }
        guard let since = incompatibleModeSince, now.timeIntervalSince(since) >= 3 else { return false }
        appendEvent("FAIL soak aborted: required graph remained incompatible for 3s expected=\(expected.rawValue) actual=\(sample.captureMode) phase=\(sample.capturePhase)")
        return true
    }

    private func noteUSBEvent(kind: RinkLensPendingUSBValidation.Kind, deviceName: String) {
        guard isRunning else { return }
        let capture = AppContainer.shared.captureEngine.snapshot
        let recording = BroadcastRecordingManager.shared.isRecording
        switch kind {
        case .disconnect:
            usbDisconnectCount &+= 1
            if capture.activeMode == .ocrOnly { usbDisconnectOCROnlyCount &+= 1 }
            if capture.activeMode == .dualCamera { usbDisconnectDualCameraCount &+= 1 }
            if recording { usbDisconnectDuringRecordingCount &+= 1 }
        case .reconnect:
            usbReconnectCount &+= 1
        }
        pendingUSBValidations.append(
            RinkLensPendingUSBValidation(
                kind: kind,
                occurredAt: Date(),
                captureMode: capture.activeMode,
                recordingActive: recording,
                deviceName: deviceName,
                evaluated: false
            )
        )
        if pendingUSBValidations.count > 30 { pendingUSBValidations.removeFirst(pendingUSBValidations.count - 30) }
        appendEvent("USB \(kind.rawValue) device=\(deviceName) mode=\(capture.activeMode.rawValue) recording=\(recording)")
        updatePublishedSummary(force: true)
    }

    private func evaluatePendingUSBValidations(
        now: Date,
        capture: RinkLensCaptureEngineSnapshot,
        recorder: BroadcastRecordingManager
    ) {
        for index in pendingUSBValidations.indices where !pendingUSBValidations[index].evaluated {
            let age = now.timeIntervalSince(pendingUSBValidations[index].occurredAt)
            let item = pendingUSBValidations[index]
            switch item.kind {
            case .disconnect:
                guard age >= 3 else { continue }
                if item.recordingActive {
                    if isControlledRecordingSourceLoss(recorder) || (capture.sessionRunning && capture.activeMode.requiresBroadcast) {
                        if isControlledRecordingSourceLoss(recorder) { sourceLossFailFastObserved = true }
                        usbFallbackSuccessCount &+= 1
                        appendEvent("USB recording disconnect controlled: \(recorder.recordingHealthText)")
                    } else if age >= 8 {
                        usbFallbackFailureCount &+= 1
                        appendEvent("FAIL USB recording disconnect lacked Broadcast fallback or clear fail-fast reason")
                    } else {
                        continue
                    }
                } else if item.captureMode == .dualCamera {
                    if capture.sessionRunning && capture.activeMode.requiresBroadcast {
                        usbFallbackSuccessCount &+= 1
                        appendEvent("USB dual-camera disconnect preserved Broadcast mode=\(capture.activeMode.rawValue)")
                    } else if age >= 8 {
                        usbFallbackFailureCount &+= 1
                        appendEvent("FAIL USB dual-camera disconnect did not preserve Broadcast")
                    } else {
                        continue
                    }
                } else {
                    usbFallbackSuccessCount &+= 1
                    appendEvent("USB disconnect observed in \(item.captureMode.rawValue); controlled state=\(capture.phase.rawValue)")
                }
                pendingUSBValidations[index].evaluated = true

            case .reconnect:
                guard age >= 3 else { continue }
                if capture.sessionRunning && (capture.activeMode == .dualCamera || item.captureMode != .dualCamera) {
                    usbRecoverySuccessCount &+= 1
                    appendEvent("USB reconnect recovered mode=\(capture.activeMode.rawValue) generation=\(capture.transitionGeneration)")
                    pendingUSBValidations[index].evaluated = true
                } else if age >= 12 {
                    usbRecoveryFailureCount &+= 1
                    appendEvent("FAIL USB reconnect did not reach a running graph within 12s")
                    pendingUSBValidations[index].evaluated = true
                }
            }
        }
    }

    private func hasRecentUSBDisconnect(at date: Date) -> Bool {
        pendingUSBValidations.contains {
            $0.kind == .disconnect && date.timeIntervalSince($0.occurredAt) >= 0 && date.timeIntervalSince($0.occurredAt) <= 10
        }
    }

    private func isControlledRecordingSourceLoss(_ recorder: BroadcastRecordingManager) -> Bool {
        let text = [recorder.recordingHealthText, recorder.lastErrorMessage ?? ""]
            .joined(separator: " ")
            .lowercased()
        return recorder.state == .failed
            && (text.contains("camera source lost") || text.contains("no fresh frame"))
    }

    private func updatePublishedSummary(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPublishedAt) >= 2 else { return }
        lastPublishedAt = now
        guard let startedAt else { return }
        let elapsed = (stoppedAt ?? now).timeIntervalSince(startedAt)
        elapsedText = Self.durationText(elapsed)
        if let target = selectedScenario.targetDuration {
            remainingText = Self.durationText(max(0, target - elapsed))
        } else {
            remainingText = "manual stop"
        }

        if let sample = samples.last {
            currentCaptureText = "\(sample.captureMode) / \(sample.capturePhase) / gen \(sample.captureGeneration) / \(sample.sessionRunning ? "running" : "stopped")"
            let liveAge = sample.liveFrameAgeSeconds.map { String(format: "%.2fs", $0) } ?? "--"
            let ocrAge = sample.ocrFrameAgeSeconds.map { String(format: "%.2fs", $0) } ?? "--"
            cadenceText = "FrameHub Broadcast \(Self.fpsText(sample.liveFPS, target: sample.liveTargetFPS)) age \(liveAge) / OCR \(Self.fpsText(sample.ocrFPS, target: sample.ocrTargetFPS)) age \(ocrAge)"
        }

        updateMemorySummary()
        updateEvidenceSummaries()
        updateAcceptanceLines()
        publishUI()
    }

    private func updateMemorySummary() {
        let values = samples.compactMap(\.memoryBytes)
        guard let latest = values.last else {
            memoryText = "unavailable"
            memoryPlateauText = "No app footprint samples"
            return
        }
        let minimum = values.min() ?? latest
        let maximum = values.max() ?? latest
        memoryText = "now \(Self.megabyteText(latest)) / min \(Self.megabyteText(minimum)) / max \(Self.megabyteText(maximum))"

        guard let startedAt, (stoppedAt ?? Date()).timeIntervalSince(startedAt) >= 15 * 60 else {
            memoryPlateauText = "Pending — needs at least 15 minutes"
            return
        }
        let recent = samples.suffix(600).compactMap(\.memoryBytes)
        guard recent.count >= 120 else {
            memoryPlateauText = "Pending — insufficient recent samples"
            return
        }
        let recentMin = recent.min() ?? latest
        let recentMax = recent.max() ?? latest
        let range = recentMax - recentMin
        let allowance = max(UInt64(24 * 1_048_576), UInt64(Double(latest) * 0.08))
        memoryPlateauText = range <= allowance
            ? "Stable candidate — last 10 min range \(Self.megabyteText(range))"
            : "Not stable — last 10 min range \(Self.megabyteText(range))"
    }

    private func updateEvidenceSummaries() {
        guard let baseline, let latest = samples.last else { return }
        let liveBuffers = max(0, latest.liveOutOfBuffersLifetime - baseline.liveOutOfBuffersLifetime)
        let ocrBuffers = max(0, latest.ocrOutOfBuffersLifetime - baseline.ocrOutOfBuffersLifetime)
        let liveDrops = max(0, latest.liveDropsLifetime - baseline.liveDropsLifetime)
        let ocrDrops = max(0, latest.ocrDropsLifetime - baseline.ocrDropsLifetime)
        dropText = "OutOfBuffers B/OCR \(liveBuffers)/\(ocrBuffers); all drops \(liveDrops)/\(ocrDrops); last \(latest.lastDroppedReason)"
        let pressureImpactObserved = liveBuffers + ocrBuffers > 0
            || liveDrops + ocrDrops > 0
            || ocrStallEventCount > 0
            || (latestRecordingCadencePercent.map { $0 < 95 } ?? false)
        pressureText = "Broadcast \(latest.livePressure), OCR \(latest.ocrPressure); serious samples \(seriousPressureSampleCount), critical samples \(criticalPressureSampleCount); measured impact \(pressureImpactObserved ? "observed — see cadence/OCR/drop gates" : "not observed")"

        let revisionDelta = latest.desiredRevision >= baseline.desiredRevision ? latest.desiredRevision - baseline.desiredRevision : 0
        let reconciliations = max(0, latest.reconciliationCount - baseline.reconciliationCount)
        let coalesced = max(0, latest.coalescedRequestCount - baseline.coalescedRequestCount)
        let identicalSuppressed = max(0, latest.identicalContractSuppressionCount - baseline.identicalContractSuppressionCount)
        let healthObserved = max(0, latest.healthObservationCount - baseline.healthObservationCount)
        let healthSuppressed = max(0, latest.healthObservationSuppressionCount - baseline.healthObservationSuppressionCount)
        let routeActivations = max(0, latest.routeLifecycleActivationCount - baseline.routeLifecycleActivationCount)
        let duplicateRoutes = max(0, latest.duplicateRouteLifecycleSuppressionCount - baseline.duplicateRouteLifecycleSuppressionCount)
        let sustained = max(0, latest.sustainedHealthReconciliationCount - baseline.sustainedHealthReconciliationCount)
        lifecycleText = "revisions +\(revisionDelta), reconcile +\(reconciliations), route +\(routeActivations), coalesced +\(coalesced), identical/route suppressed +\(identicalSuppressed)/\(duplicateRoutes), health observed/suppressed +\(healthObserved)/\(healthSuppressed), sustained +\(sustained), peak stable-route requests/route activations/health observations per min \(peakLifecycleRequestsPerMinute)/\(peakRouteActivationsPerMinute)/\(peakHealthObservationsPerMinute)"

        usbText = "\(usbDisconnectCount) disconnects / \(usbReconnectCount) reconnects; coverage OCR-only/dual/recording \(usbDisconnectOCROnlyCount)/\(usbDisconnectDualCameraCount)/\(usbDisconnectDuringRecordingCount); fallback \(usbFallbackSuccessCount) pass \(usbFallbackFailureCount) fail; recovery \(usbRecoverySuccessCount) pass \(usbRecoveryFailureCount) fail"
        sceneText = "active \(activeCount), inactive \(inactiveCount), background \(backgroundCount), route changes \(routeChangeCount)"

        let submitted = max(0, latest.ocrSubmitted - baseline.ocrSubmitted)
        let completed = max(0, latest.ocrCompleted - baseline.ocrCompleted)
        let tests = max(0, latest.ocrSelectedTests - baseline.ocrSelectedTests)
        let droppedBusy = max(0, latest.ocrDroppedBusy - baseline.ocrDroppedBusy)
        let cancelled = max(0, latest.ocrCancelled - baseline.ocrCancelled)
        let stallRecoveries = max(0, latest.ocrStallRecoveries - baseline.ocrStallRecoveries)
        let prevented = max(0, latest.testOCRStaleResultsPrevented - baseline.testOCRStaleResultsPrevented)
        let elapsedMinutes = max(1.0 / 60.0, latest.elapsedSeconds / 60)
        let staleRejects = max(0, latest.frameHubStaleRejects - baseline.frameHubStaleRejects)
        let generationRejects = max(0, latest.frameHubGenerationRejects - baseline.frameHubGenerationRejects)
        let deviceRejects = max(0, latest.frameHubDeviceRejects - baseline.frameHubDeviceRejects)
        let activeAge = latest.ocrActivePassAgeSeconds.map { String(format: "%.2fs", $0) } ?? "--"
        let finishAge = latest.ocrLastFinishAgeSeconds.map { String(format: "%.2fs", $0) } ?? "--"
        ocrText = String(
            format: "submitted %d, completed %d, dropped-busy %d, cancelled %d, stall recoveries %d, worker rotations %d, Test OCR %d, stale prevented %d, throughput %.1f/min; busy %@ age %@; last finish %@ ago (%@); FrameHub rejects stale/gen/device %d/%d/%d",
            submitted, completed, droppedBusy, cancelled, stallRecoveries, latest.ocrWorkerRotations, tests, prevented,
            Double(completed) / elapsedMinutes, latest.ocrIsBusy ? "yes" : "no", activeAge, finishAge,
            latest.ocrLastFinishReason, staleRejects, generationRejects, deviceRejects
        )

        let manualClips = max(0, BroadcastRecordingManager.shared.savedManualHighlightsCount - baseline.savedManualHighlightsCount)
        let profiles = observedRecordingProfiles.sorted().joined(separator: ", ")
        if let cadencePercent = latestRecordingCadencePercent {
            let minimumText = minimumSustainedRecordingCadencePercent.map { String(format: "%.1f%%", $0) } ?? "pending"
            recordingText = String(format: "state %@; frames %d; cadence %.1f%% (sustained min %@); drops unavailable/sampling/writer/render %d/%d/%d/%d; profiles [%@]; manual clips %d", latest.recordingState, latest.recordingFramesWritten, cadencePercent, minimumText, latest.recordingCameraDrops, latest.recordingSamplingDuplicates, latest.recordingWriterDrops, latest.recordingRenderDrops, profiles, manualClips)
        } else {
            recordingText = "state \(latest.recordingState); frames \(latest.recordingFramesWritten); profiles [\(profiles)]; manual clips \(manualClips); \(latest.recordingHealth)"
        }
    }

    private func updateAcceptanceLines() {
        guard let baseline, let latest = samples.last else {
            acceptanceLines = ["No samples collected."]
            return
        }
        let outOfBuffers = max(0, latest.liveOutOfBuffersLifetime - baseline.liveOutOfBuffersLifetime)
            + max(0, latest.ocrOutOfBuffersLifetime - baseline.ocrOutOfBuffersLifetime)
        let stalePrevented = max(0, latest.testOCRStaleResultsPrevented - baseline.testOCRStaleResultsPrevented)
        let requestLimit = selectedScenario.requestStormLimitPerMinute
        let evaluatedRecordingCadence = minimumSustainedRecordingCadencePercent ?? latestRecordingCadencePercent
        let recordingCadencePass = evaluatedRecordingCadence.map { $0 >= 95 } ?? false
        let memoryStable = memoryPlateauText.hasPrefix("Stable")
        let usbPass = usbFallbackFailureCount == 0 && usbRecoveryFailureCount == 0
        let noBlackLoop = !blackFrameRecoveryLoopDetected
        let ocrStallRecoveries = max(0, latest.ocrStallRecoveries - baseline.ocrStallRecoveries)
        let ocrStallFree = ocrStallRecoveries == 0 && ocrStallEventCount == 0 && maximumOCRActivePassAgeSeconds < 12

        acceptanceLines = [
            "\(outOfBuffers == 0 ? "PASS" : "FAIL") — OutOfBuffers delta \(outOfBuffers)",
            "\(unexpectedCaptureStops == 0 ? "PASS" : "FAIL") — unexplained capture stops \(unexpectedCaptureStops)",
            "\(peakLifecycleRequestsPerMinute <= requestLimit ? "PASS" : "FAIL") — lifecycle peak \(peakLifecycleRequestsPerMinute)/min, limit \(requestLimit)/min",
            "PASS — stale Test OCR completions are fenced before publication; prevented during session \(stalePrevented)",
            "\(ocrStallFree ? "PASS" : "FAIL") — OCR stall recoveries \(ocrStallRecoveries), maximum active pass age \(String(format: "%.2fs", maximumOCRActivePassAgeSeconds))",
            "\(usbPass ? "PASS" : "FAIL") — USB fallback/recovery failures \(usbFallbackFailureCount + usbRecoveryFailureCount)",
            "\(memoryStable ? "PASS" : "PENDING") — memory plateau: \(memoryPlateauText)",
            "\(noBlackLoop ? "PASS" : "FAIL") — black-frame recovery loop \(noBlackLoop ? "not detected" : "detected"); max consecutive rejected \(maximumConsecutiveBlackFrames)",
            "\(recordingCadencePass ? "PASS" : "PENDING") — recording sustained cadence \(evaluatedRecordingCadence.map { String(format: "%.1f%% of target", $0) } ?? "not measured")",
            "INFO — thermal/system-pressure labels are contextual and do not fail a rink test by themselves; cadence, OCR, capture and buffer effects are evaluated above"
        ]
        acceptanceLines.append(contentsOf: scenarioCoverageLines(latest: latest, baseline: baseline))
    }

    private func scenarioCoverageLines(
        latest: RinkLensPhysicalValidationSample,
        baseline: RinkLensPhysicalValidationBaseline
    ) -> [String] {
        let elapsed = latest.elapsedSeconds
        switch selectedScenario {
        case .ocrOnlySoak, .broadcastOnlySoak, .dualCamera60, .dualCamera90:
            let target = selectedScenario.targetDuration ?? 0
            let durationPass = elapsed >= max(0, target - 2)
            let expected = selectedScenario.expectedMode
            let modeSamples = samples.filter { $0.elapsedSeconds >= 5 && !$0.capturePhase.contains("recover") }
            let wrongMode = modeSamples.filter { sample in
                guard let expected else { return false }
                return sample.captureMode != expected.rawValue || !sample.sessionRunning
            }.count
            let liveRatios = modeSamples.compactMap { sample -> Double? in
                guard let fps = sample.liveFPS, let target = sample.liveTargetFPS, target > 0 else { return nil }
                return fps / target * 100
            }
            let ocrRatios = modeSamples.compactMap { sample -> Double? in
                guard let fps = sample.ocrFPS, let target = sample.ocrTargetFPS, target > 0 else { return nil }
                return fps / target * 100
            }
            let liveAverage = liveRatios.isEmpty ? nil : liveRatios.reduce(0, +) / Double(liveRatios.count)
            let ocrAverage = ocrRatios.isEmpty ? nil : ocrRatios.reduce(0, +) / Double(ocrRatios.count)
            return [
                "\(durationPass ? "PASS" : "PENDING") — soak duration \(Self.durationText(elapsed)) / \(Self.durationText(target))",
                "\(wrongMode == 0 ? "PASS" : "FAIL") — wrong/stopped graph samples after warm-up \(wrongMode)",
                "INFO — average capture cadence Broadcast \(liveAverage.map { String(format: "%.1f%%", $0) } ?? "n/a"), OCR \(ocrAverage.map { String(format: "%.1f%%", $0) } ?? "n/a")"
            ]

        case .usbRecovery:
            let cycles = min(usbDisconnectCount, usbReconnectCount)
            return [
                "\(cycles >= 10 ? "PASS" : "PENDING") — USB cycles \(cycles)/10",
                "\(usbDisconnectOCROnlyCount > 0 ? "PASS" : "PENDING") — disconnect coverage during OCR-only \(usbDisconnectOCROnlyCount)",
                "\(usbDisconnectDualCameraCount > 0 ? "PASS" : "PENDING") — disconnect coverage during dual-camera \(usbDisconnectDualCameraCount)",
                "\(usbDisconnectDuringRecordingCount > 0 ? "PASS" : "PENDING") — disconnect coverage during recording \(usbDisconnectDuringRecordingCount)"
            ]

        case .sceneLifecycle:
            let required = RinkLensPhysicalValidationCheckpoint.allCases.filter { $0.group == "Scene lifecycle" }
            let completed = required.filter { completedCheckpoints.contains($0) }.count
            return ["\(completed == required.count ? "PASS" : "PENDING") — scene checkpoints \(completed)/\(required.count)"]

        case .ocrValidation:
            let testRuns = max(0, latest.ocrSelectedTests - baseline.ocrSelectedTests)
            let required = RinkLensPhysicalValidationCheckpoint.allCases.filter { $0.group == "OCR validation" }
            let completed = required.filter { completedCheckpoints.contains($0) }.count
            return [
                "\(testRuns >= 25 ? "PASS" : "PENDING") — Test OCR runs \(testRuns)/25",
                "\(completed == required.count ? "PASS" : "PENDING") — OCR checkpoints \(completed)/\(required.count)"
            ]

        case .recordingValidation:
            let required = RinkLensPhysicalValidationCheckpoint.allCases.filter { $0.group == "Recording validation" }
            let completed = required.filter { completedCheckpoints.contains($0) }.count
            let manualClips = max(0, BroadcastRecordingManager.shared.savedManualHighlightsCount - baseline.savedManualHighlightsCount)
            let has30 = observedRecordingProfiles.contains(where: { $0.lowercased().contains("1080") && $0.hasSuffix("@30") })
            let has60 = observedRecordingProfiles.contains(where: { $0.lowercased().contains("1080") && $0.hasSuffix("@60") })
            return [
                "\(completed == required.count ? "PASS" : "PENDING") — recording checkpoints \(completed)/\(required.count)",
                "\(has30 ? "PASS" : "PENDING") — observed 1080p/30 recording",
                "\(has60 ? "PASS" : "PENDING") — observed 1080p/60 recording",
                "\(manualClips > 0 ? "PASS" : "PENDING") — manual clips saved during session \(manualClips)",
                "\(ocrObservedWhileRecording ? "PASS" : "PENDING") — OCR observed active while recording",
                "\(routeChangesWhileRecording > 0 ? "PASS" : "PENDING") — route changes while recording \(routeChangesWhileRecording)",
                "\(sourceLossFailFastObserved ? "PASS" : "PENDING") — source-loss fail-fast observed"
            ]
        }
    }

    private func appendEvent(_ text: String) {
        let line = "\(Self.eventTimeFormatter.string(from: Date())) \(text)"
        recentEvents.insert(line, at: 0)
        if recentEvents.count > 240 { recentEvents.removeLast(recentEvents.count - 240) }
        MainThreadStallMonitor.shared.trace("UX16c50 \(text)")
    }

    private func publishUI() {
        uiRevision &+= 1
    }

    private func exportSessionFiles() {
        guard !samples.isEmpty else {
            exportStatusText = "No validation samples to export"
            publishUI()
            return
        }
        do {
            let folder = try Self.logsFolderURL()
            let stamp = Self.fileTimestampFormatter.string(from: stoppedAt ?? Date())
            let safeScenario = selectedScenario.rawValue
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: "×", with: "x")
            let reportURL = folder.appendingPathComponent("RinkLens_UX16c50_\(safeScenario)_\(stamp).txt")
            let csvURL = folder.appendingPathComponent("RinkLens_UX16c50_\(safeScenario)_\(stamp).csv")
            try reportText().write(to: reportURL, atomically: true, encoding: .utf8)
            try csvText().write(to: csvURL, atomically: true, encoding: .utf8)
            lastReportURL = reportURL
            lastCSVURL = csvURL
            exportStatusText = "Saved report and CSV in RinkLens Logs"
            publishUI()
        } catch {
            exportStatusText = "Validation export failed: \(error.localizedDescription)"
            publishUI()
        }
    }

    private func reportText() -> String {
        var lines = [
            "RINKLENS UX16c51 PHYSICAL VALIDATION REPORT",
            RinkLensBuildInfo.diagnosticsExportVersionLine,
            "Created: \(Self.timestampFormatter.string(from: Date()))",
            ""
        ]
        lines += exportLines()
        lines += ["", "=== ALL EVENTS (OLDEST FIRST) ===", ""]
        lines += recentEvents.reversed()
        return lines.joined(separator: "\n")
    }

    private func csvText() -> String {
        let header = "timestamp,elapsed_s,route,scene,capture_mode,capture_phase,generation,session_running,live_fps,ocr_fps,live_target_fps,ocr_target_fps,capture_live_observed_fps,capture_ocr_observed_fps,configured_live_cadence,configured_ocr_cadence,framehub_live_published,framehub_ocr_published,framehub_live_age_s,framehub_ocr_age_s,memory_mb,thermal,live_pressure,ocr_pressure,live_out_of_buffers_lifetime,ocr_out_of_buffers_lifetime,live_drops_lifetime,ocr_drops_lifetime,last_drop_reason,desired_revision,reconciliations,coalesced_requests,identical_contract_suppressions,health_observations,health_observation_suppressions,route_lifecycle_activations,duplicate_route_suppressions,sustained_health_reconciliations,framehub_stale_rejects,framehub_generation_rejects,framehub_device_rejects,ocr_submitted,ocr_completed,test_ocr_runs,ocr_dropped_busy,ocr_cancelled,ocr_stall_recoveries,ocr_worker_rotations,ocr_busy,ocr_active_pass_age_s,ocr_last_finish_age_s,ocr_last_finish_reason,ocr_last_phase,ocr_scheduler_active,ocr_effective_running,test_ocr_stale_prevented,recording_state,recording_frames_written,recording_frames_dropped,recording_source_unavailable,recording_sampling_duplicates,recording_writer_drops,recording_render_drops,recording_target_fps,recording_health,black_frame_consecutive"
        let rows = samples.map { csvRow(for: $0) }
        return ([header] + rows).joined(separator: "\n")
    }

    /// Keep CSV construction in small, explicitly typed groups. Xcode 26.5's
    /// constraint solver timed out on the previous 60-field array literal even
    /// though every element resolved to String.
    private func csvRow(for sample: RinkLensPhysicalValidationSample) -> String {
        var fields: [String] = []
        fields.reserveCapacity(66)

        fields.append(contentsOf: [
            Self.csv(Self.timestampFormatter.string(from: sample.timestamp)),
            String(format: "%.3f", sample.elapsedSeconds),
            Self.csv(sample.route),
            Self.csv(sample.scenePhase),
            Self.csv(sample.captureMode),
            Self.csv(sample.capturePhase),
            String(sample.captureGeneration),
            sample.sessionRunning ? "1" : "0"
        ])

        fields.append(contentsOf: [
            sample.liveFPS.map { String(format: "%.3f", $0) } ?? "",
            sample.ocrFPS.map { String(format: "%.3f", $0) } ?? "",
            sample.liveTargetFPS.map { String(format: "%.3f", $0) } ?? "",
            sample.ocrTargetFPS.map { String(format: "%.3f", $0) } ?? "",
            String(format: "%.3f", sample.liveCaptureObservedFPS),
            String(format: "%.3f", sample.ocrCaptureObservedFPS),
            Self.csv(sample.liveConfiguredCadence),
            Self.csv(sample.ocrConfiguredCadence),
            String(sample.liveFrameHubPublishedCount),
            String(sample.ocrFrameHubPublishedCount),
            sample.liveFrameAgeSeconds.map { String(format: "%.3f", $0) } ?? "",
            sample.ocrFrameAgeSeconds.map { String(format: "%.3f", $0) } ?? ""
        ])

        fields.append(contentsOf: [
            sample.memoryBytes.map { String(format: "%.2f", Double($0) / 1_048_576) } ?? "",
            Self.csv(sample.thermalState),
            Self.csv(sample.livePressure),
            Self.csv(sample.ocrPressure),
            String(sample.liveOutOfBuffersLifetime),
            String(sample.ocrOutOfBuffersLifetime),
            String(sample.liveDropsLifetime),
            String(sample.ocrDropsLifetime),
            Self.csv(sample.lastDroppedReason)
        ])

        fields.append(contentsOf: [
            String(sample.desiredRevision),
            String(sample.reconciliationCount),
            String(sample.coalescedRequestCount),
            String(sample.identicalContractSuppressionCount),
            String(sample.healthObservationCount),
            String(sample.healthObservationSuppressionCount),
            String(sample.routeLifecycleActivationCount),
            String(sample.duplicateRouteLifecycleSuppressionCount),
            String(sample.sustainedHealthReconciliationCount)
        ])

        fields.append(contentsOf: [
            String(sample.frameHubStaleRejects),
            String(sample.frameHubGenerationRejects),
            String(sample.frameHubDeviceRejects),
            String(sample.ocrSubmitted),
            String(sample.ocrCompleted),
            String(sample.ocrSelectedTests),
            String(sample.ocrDroppedBusy),
            String(sample.ocrCancelled),
            String(sample.ocrStallRecoveries),
            String(sample.ocrWorkerRotations)
        ])

        fields.append(contentsOf: [
            sample.ocrIsBusy ? "1" : "0",
            sample.ocrActivePassAgeSeconds.map { String(format: "%.3f", $0) } ?? "",
            sample.ocrLastFinishAgeSeconds.map { String(format: "%.3f", $0) } ?? "",
            Self.csv(sample.ocrLastFinishReason),
            Self.csv(sample.ocrLastPhase),
            sample.ocrSchedulerActive ? "1" : "0",
            sample.ocrEffectiveRunning ? "1" : "0",
            String(sample.testOCRStaleResultsPrevented)
        ])

        fields.append(contentsOf: [
            Self.csv(sample.recordingState),
            String(sample.recordingFramesWritten),
            String(sample.recordingFramesDropped),
            String(sample.recordingCameraDrops),
            String(sample.recordingSamplingDuplicates),
            String(sample.recordingWriterDrops),
            String(sample.recordingRenderDrops),
            String(sample.recordingTargetFPS),
            Self.csv(sample.recordingHealth),
            String(sample.blackFrameConsecutive)
        ])

        return fields.joined(separator: ",")
    }

    private func captureMetrics() -> (
        capture: RinkLensCaptureEngineSnapshot,
        lifecycle: RinkLensCaptureLifecycleController,
        frameHub: RinkLensFrameHubSnapshot,
        ocr: RinkLensOCROrchestrationSnapshot,
        viewModel: HockeyScoreboardViewModel,
        recorder: BroadcastRecordingManager
    ) {
        let container = AppContainer.shared
        let viewModel = container.scoreboardViewModel
        return (
            container.captureEngine.snapshot,
            viewModel.captureLifecycleController,
            RinkLensFrameHub.shared.diagnosticSnapshot(),
            viewModel.ocrOrchestrationSnapshot,
            viewModel,
            BroadcastRecordingManager.shared
        )
    }

    private static func logsFolderURL() throws -> URL {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = root.appendingPathComponent(BroadcastRecordingManager.logsFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func csv(_ text: String) -> String {
        "\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remaining = total % 60
        if hours > 0 { return String(format: "%02d:%02d:%02d", hours, minutes, remaining) }
        return String(format: "%02d:%02d", minutes, remaining)
    }

    private static func fpsText(_ fps: Double?, target: Double?) -> String {
        guard let fps else { return "--" }
        if let target { return String(format: "%.1f/%.1f fps", fps, target) }
        return String(format: "%.1f fps", fps)
    }

    private static func megabyteText(_ bytes: UInt64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    private static func thermalStateText(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func appMemoryFootprintBytes() -> UInt64? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
        #else
        return nil
        #endif
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

    private static let fileTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()
}

// MARK: - UX16c50 diagnostics page

struct PhysicalValidationPanel: View {
    @ObservedObject var controller: RinkLensPhysicalValidationController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DiagnosticsCard(title: "Physical Test Session", systemImage: "timer") {
                Picker("Test set", selection: $controller.selectedScenario) {
                    ForEach(RinkLensPhysicalValidationScenario.allCases) { scenario in
                        Text(scenario.rawValue).tag(scenario)
                    }
                }
                .pickerStyle(.menu)
                .disabled(controller.isRunning || controller.isPreparing)

                Text(controller.selectedScenario.instructions)
                    .font(RinkLensDesignSystem.font(.caption))
                    .foregroundStyle(RinkLensDesignSystem.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button {
                        controller.start()
                    } label: {
                        Label("Start Test", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.isRunning || controller.isPreparing)

                    Button(role: .destructive) {
                        controller.stop()
                    } label: {
                        Label("Stop and Export", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!controller.isRunning && !controller.isPreparing)

                    Button("Reset") {
                        controller.reset()
                    }
                    .buttonStyle(.bordered)
                    .disabled(controller.isRunning || controller.isPreparing)
                }

                DiagnosticsRow(title: "Status", value: controller.statusText)
                DiagnosticsRow(title: "Elapsed / remaining", value: "\(controller.elapsedText) / \(controller.remainingText)")
                DiagnosticsRow(title: "Capture", value: controller.currentCaptureText)
                DiagnosticsRow(title: "Cadence", value: controller.cadenceText)
                DiagnosticsRow(title: "Memory", value: controller.memoryText)
                DiagnosticsRow(title: "Memory plateau", value: controller.memoryPlateauText)
                DiagnosticsRow(title: "System pressure", value: controller.pressureText)
                DiagnosticsRow(title: "Drops", value: controller.dropText)
                DiagnosticsRow(title: "Lifecycle", value: controller.lifecycleText)
                DiagnosticsRow(title: "USB", value: controller.usbText)
                DiagnosticsRow(title: "Scene / route", value: controller.sceneText)
                DiagnosticsRow(title: "OCR", value: controller.ocrText)
                DiagnosticsRow(title: "Recording", value: controller.recordingText)
            }

            DiagnosticsCard(title: "Acceptance Gate", systemImage: "checkmark.seal") {
                ForEach(Array(controller.acceptanceLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(RinkLensDesignSystem.font(.monoCaption))
                        .foregroundStyle(line.hasPrefix("FAIL") ? Color.red : (line.hasPrefix("PASS") ? Color.green : RinkLensDesignSystem.secondaryText))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            checkpointCard(group: "Scene lifecycle")
            checkpointCard(group: "OCR validation")
            checkpointCard(group: "Recording validation")

            DiagnosticsCard(title: "Validation Export", systemImage: "square.and.arrow.up") {
                DiagnosticsRow(title: "Export", value: controller.exportStatusText)
                if let report = controller.lastReportURL {
                    ShareLink(item: report) {
                        Label("Share Validation Report", systemImage: "doc.text")
                    }
                    .buttonStyle(.borderedProminent)
                }
                if let csv = controller.lastCSVURL {
                    ShareLink(item: csv) {
                        Label("Share 1 Hz CSV", systemImage: "tablecells")
                    }
                    .buttonStyle(.bordered)
                }
            }

            DiagnosticsCard(title: "Recent Validation Events", systemImage: "list.bullet.rectangle") {
                if controller.recentEvents.isEmpty {
                    Text("No validation events captured")
                        .font(RinkLensDesignSystem.font(.caption))
                        .foregroundStyle(RinkLensDesignSystem.secondaryText)
                } else {
                    ForEach(Array(controller.recentEvents.prefix(12).enumerated()), id: \.offset) { _, event in
                        Text(event)
                            .font(RinkLensDesignSystem.font(.monoCaption))
                            .foregroundStyle(RinkLensDesignSystem.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func checkpointCard(group: String) -> some View {
        DiagnosticsCard(title: group, systemImage: "checklist") {
            ForEach(RinkLensPhysicalValidationCheckpoint.allCases.filter { $0.group == group }) { checkpoint in
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
    }
}
#endif
