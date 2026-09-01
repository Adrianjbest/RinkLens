// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation
import SwiftUI



// MARK: - Recovery AT real-time execution hierarchy

/// One process-wide QoS contract for media work. Queue ownership remains with
/// each subsystem, but priority class is no longer chosen ad-hoc at each call
/// site. Capture is the protected physical ingress path. Recording and viewer
/// rendering are latency-sensitive but must yield CPU scheduling to MainActor
/// operator input; semantic/image-analysis work is utility and opaque offline
/// media remains background.
nonisolated enum RinkLensExecutionQoSHierarchy {
    static let capture = DispatchQoS.userInitiated
    static let recording = DispatchQoS.default
    static let viewer = DispatchQoS.default
    static let semantic = DispatchQoS.utility
    static let offline = DispatchQoS.background

    static let diagnosticText =
        "capture=userInitiated recording=default viewer=default semantic=utility offline=background"
}

// MARK: - Recovery AF execution ownership

/// One admission authority for expensive non-real-time work.
///
/// CaptureEngine callbacks, FrameHub ingress and RecordingWriter remain outside
/// this coordinator: they are the protected real-time path. The coordinator only
/// answers whether lower-priority work may start/continue while the operator is
/// waiting for a route transition or while the one final RecordingWriter is
/// acquiring codec resources. It owns no camera, recording, route or scoreboard
/// state and introduces no timer/retry/debounce policy.
nonisolated enum RinkLensOperatorInteractionKind: String, Sendable {
    case routeTransition
    case cameraZoomGesture
}

nonisolated enum RinkLensMatchSemanticAdmissionPolicy {
    static func admits(
        operatorInteractionActive: Bool,
        operatorInteractionKind: RinkLensOperatorInteractionKind,
        criticalPreparationCount: Int
    ) -> Bool {
        let routePresentationOwnsForeground = operatorInteractionActive
            && operatorInteractionKind == .routeTransition
        return criticalPreparationCount == 0 && !routePresentationOwnsForeground
    }
}

nonisolated final class RinkLensExecutionCoordinator: @unchecked Sendable {
    static let shared = RinkLensExecutionCoordinator()

    struct DeferredMediaCaptureAdmission: Sendable {
        let captureActive: Bool
        let sessionRunning: Bool
        let mode: String
        let livePressureLevel: String
        let ocrPressureLevel: String
        let liveDroppedFrames: Int
        let ocrDroppedFrames: Int
        let liveCallbackAgeSeconds: TimeInterval?
        let ocrCallbackAgeSeconds: TimeInterval?
        let broadcastRequired: Bool
        let ocrRequired: Bool

        // Recovery AU / RL-100: offline/opaque media work is a mutually
        // exclusive lifetime domain with live AVCaptureSession ownership. The
        // old Recovery AN headroom heuristic was invalid: nominal pressure and
        // zero drops before an AVAssetExportSession starts do not prove that the
        // opaque export will leave capture resources available afterwards.
        var liveCaptureMediaLeaseActive: Bool {
            captureActive && sessionRunning && mode != RinkLensCaptureLifecycleMode.stopped.rawValue
        }

        var admitsOfflineMedia: Bool {
            !liveCaptureMediaLeaseActive
        }

        var diagnosticText: String {
            let liveAge = liveCallbackAgeSeconds.map { String(format: "%.2fs", $0) } ?? "--"
            let ocrAge = ocrCallbackAgeSeconds.map { String(format: "%.2fs", $0) } ?? "--"
            let reason = liveCaptureMediaLeaseActive ? "blocked-live-capture-media-lease" : "capture-media-lease-free"
            return "admit=\(admitsOfflineMedia) reason=\(reason) active=\(captureActive) running=\(sessionRunning) mode=\(mode) pressure=\(livePressureLevel)/\(ocrPressureLevel) drops=\(liveDroppedFrames)/\(ocrDroppedFrames) callbackAge=\(liveAge)/\(ocrAge)"
        }
    }

    struct Snapshot: Sendable {
        let operatorInteractionActive: Bool
        let operatorRoute: String
        let operatorGeneration: UInt64
        let criticalPreparationCount: Int
        let criticalPreparationLabels: [String]
        let auxiliaryYieldCount: Int
        let scoreboardRealtimeYieldCount: Int
        let deferredMediaYieldCount: Int
        let realtimeMediaCriticalCount: Int
        let realtimeMediaCriticalPeak: Int
        let realtimeMediaCriticalEntries: UInt64
        let applicationExecutionActive: Bool
        let deferredMediaCaptureAdmissionText: String

        var diagnosticText: String {
            let operatorText = operatorInteractionActive ? operatorRoute : "idle"
            let joinedCritical = criticalPreparationLabels.joined(separator: ",")
            let criticalText = joinedCritical.isEmpty ? "none" : joinedCritical
            return "operator=\(operatorText) generation=\(operatorGeneration) critical=\(criticalText) realtimeFrames=\(realtimeMediaCriticalCount)/peak:\(realtimeMediaCriticalPeak)/entries:\(realtimeMediaCriticalEntries) appActive=\(applicationExecutionActive) auxYields=\(auxiliaryYieldCount) scoreboardYields=\(scoreboardRealtimeYieldCount) mediaYields=\(deferredMediaYieldCount) qos={\(RinkLensExecutionQoSHierarchy.diagnosticText)} mediaCapture={\(deferredMediaCaptureAdmissionText)}"
        }
    }

    private let lock = NSLock()
    private var operatorInteractionActive = false
    private var operatorRoute = "none"
    private var operatorInteractionKind: RinkLensOperatorInteractionKind = .routeTransition
    private var operatorGeneration: UInt64 = 0
    private var criticalPreparations: [UUID: String] = [:]
    private var auxiliaryYieldCount = 0
    private var scoreboardRealtimeYieldCount = 0
    private var deferredMediaYieldCount = 0
    private var realtimeMediaCriticalCount = 0
    private var realtimeMediaCriticalPeak = 0
    private var realtimeMediaCriticalEntries: UInt64 = 0
    private var deferredMediaCaptureProbe: (@Sendable () -> DeferredMediaCaptureAdmission)?
    private var deferredMediaEligibilityHandler: (@Sendable (String) -> Void)?
    private var applicationExecutionActive = true

    private init() {}

    /// Recovery AN / RL-083: execution admission reads CaptureEngine truth
    /// directly at the instant offline work asks to start. The coordinator does
    /// not mirror camera pressure, callback or drop state; CaptureEngine remains
    /// the sole authority for those values.
    func installDeferredMediaCaptureProbe(
        _ probe: @escaping @Sendable () -> DeferredMediaCaptureAdmission
    ) {
        lock.lock()
        deferredMediaCaptureProbe = probe
        lock.unlock()
    }


    /// Recovery AU / RL-100: MediaRepository owns its deferred queue; the
    /// execution coordinator only tells that owner when the live capture media
    /// lease may have become free. Screens/routes never resume the queue.
    func installDeferredMediaEligibilityHandler(
        _ handler: @escaping @Sendable (String) -> Void
    ) {
        lock.lock()
        deferredMediaEligibilityHandler = handler
        lock.unlock()
    }

    func setApplicationExecutionActive(_ active: Bool, source: String) {
        lock.lock()
        applicationExecutionActive = active
        lock.unlock()
        MainThreadStallMonitor.traceFromAnyQueue(
            "Recovery AU media-resource owner appActive=\(active) source=\(source)"
        )
        if active {
            notifyDeferredMediaEligibilityMayHaveChanged(reason: "application became active: \(source)")
        }
    }

    func notifyDeferredMediaEligibilityMayHaveChanged(reason: String) {
        guard admitsDeferredMediaWork() else { return }
        lock.lock()
        let handler = deferredMediaEligibilityHandler
        lock.unlock()
        handler?(reason)
    }

    @discardableResult
    func beginOperatorInteraction(
        route: String,
        source: String,
        kind: RinkLensOperatorInteractionKind = .routeTransition
    ) -> UInt64 {
        lock.lock()
        operatorGeneration &+= 1
        operatorInteractionActive = true
        operatorRoute = route
        operatorInteractionKind = kind
        let generation = operatorGeneration
        lock.unlock()
        MainThreadStallMonitor.traceFromAnyQueue(
            "Recovery DB execution owner operator interaction began route=\(route) kind=\(kind.rawValue) generation=\(generation) source=\(source)"
        )
        return generation
    }

    func endOperatorInteraction(route: String, source: String) {
        lock.lock()
        let matched = operatorInteractionActive && operatorRoute == route
        if matched {
            operatorInteractionActive = false
            operatorRoute = "none"
            operatorInteractionKind = .routeTransition
        }
        let generation = operatorGeneration
        lock.unlock()
        guard matched else { return }
        MainThreadStallMonitor.traceFromAnyQueue(
            "Recovery DB execution owner operator interaction ended route=\(route) generation=\(generation) source=\(source)"
        )
    }

    func beginCriticalPreparation(id: UUID, label: String, source: String) {
        lock.lock()
        criticalPreparations[id] = label
        lock.unlock()
        MainThreadStallMonitor.traceFromAnyQueue(
            "Recovery AF execution owner critical preparation began label=\(label) id=\(id.uuidString) source=\(source)"
        )
    }

    func endCriticalPreparation(id: UUID, source: String) {
        lock.lock()
        let label = criticalPreparations.removeValue(forKey: id)
        lock.unlock()
        guard let label else { return }
        MainThreadStallMonitor.traceFromAnyQueue(
            "Recovery AF execution owner critical preparation ended label=\(label) id=\(id.uuidString) source=\(source)"
        )
    }

    /// Recovery AT / RL-099: semantic/auxiliary work may not start while the
    /// recording compositor/VideoToolbox admission path owns its short critical
    /// frame boundary. The caller remains capacity-one/latest-only, so a denied
    /// attempt is coalesced by the next physical frame rather than queued/retried.
    func admitsAuxiliaryWork() -> Bool {
        lock.lock()
        let allowed = !operatorInteractionActive
            && criticalPreparations.isEmpty
            && realtimeMediaCriticalCount == 0
        lock.unlock()
        return allowed
    }

    /// Recovery DU: Score is semantic game state and must remain observable while
    /// RecordingWriter owns its short per-frame compositor/VideoToolbox boundary.
    /// Genuine resource/codec preparations and foreground route transitions still
    /// deny Score work. Camera zoom gestures and short recording-frame critical
    /// sections do not. This coordinator owns execution admission only; MatchState
    /// remains the sole score authority.
    func admitsScoreSemanticWork() -> Bool {
        lock.lock()
        let allowed = RinkLensMatchSemanticAdmissionPolicy.admits(
            operatorInteractionActive: operatorInteractionActive,
            operatorInteractionKind: operatorInteractionKind,
            criticalPreparationCount: criticalPreparations.count
        )
        lock.unlock()
        return allowed
    }

    /// Recovery DV: penalty-player occupancy and lifecycle evidence is semantic
    /// match state, just like Score. It remains capacity-one/latest-only and may
    /// cross a short RecordingWriter frame critical section, while codec/resource
    /// preparation and foreground route transitions continue to deny it. Without
    /// this boundary the timer presentation could remain live while MatchState saw
    /// zero penalties for the entire recording.
    func admitsPenaltySemanticWork() -> Bool {
        lock.lock()
        let allowed = RinkLensMatchSemanticAdmissionPolicy.admits(
            operatorInteractionActive: operatorInteractionActive,
            operatorInteractionKind: operatorInteractionKind,
            criticalPreparationCount: criticalPreparations.count
        )
        lock.unlock()
        return allowed
    }

    /// Recovery DB / RL-013: the direct viewer Clock is latest-only. It yields
    /// while a route transition owns foreground presentation, then resumes from
    /// newest physical evidence. Camera zoom gestures remain live and do not pause
    /// Clock. As before, short per-frame recording critical sections do not deny
    /// this lane; auxiliary semantic work keeps the stricter admission policy.
    func admitsViewerClockWork() -> Bool {
        lock.lock()
        let routePresentationOwnsForeground = operatorInteractionActive
            && operatorInteractionKind == .routeTransition
        let allowed = criticalPreparations.isEmpty && !routePresentationOwnsForeground
        lock.unlock()
        return allowed
    }

    /// Short execution boundary only; this is not recording state. RecordingWriter
    /// remains the sole recording owner. The counter exists so lower-priority
    /// media workers can avoid beginning expensive work during a live frame render.
    func beginRecordingFrameCritical() {
        lock.lock()
        realtimeMediaCriticalCount &+= 1
        realtimeMediaCriticalEntries &+= 1
        realtimeMediaCriticalPeak = max(realtimeMediaCriticalPeak, realtimeMediaCriticalCount)
        lock.unlock()
    }

    func endRecordingFrameCritical() {
        lock.lock()
        realtimeMediaCriticalCount = max(0, realtimeMediaCriticalCount - 1)
        lock.unlock()
    }

    func admitsDeferredMediaWork() -> Bool {
        lock.lock()
        let baseAllowed = applicationExecutionActive
            && !operatorInteractionActive
            && criticalPreparations.isEmpty
            && realtimeMediaCriticalCount == 0
        let captureProbe = deferredMediaCaptureProbe
        lock.unlock()
        guard baseAllowed else { return false }
        // Recovery AU / RL-100: fail closed until CaptureEngine truth is
        // installed, then require the live capture media lease to be physically
        // free. Pressure/drop "headroom" is diagnostic-only and can no longer
        // authorise opaque AVFoundation/Photos media work.
        guard let captureProbe else { return false }
        return captureProbe().admitsOfflineMedia
    }

    /// RL-238: the live manual clip mux is a bounded compressed-sample
    /// container copy. It owns no camera graph, encoder, compositor or UI route,
    /// so route presentation is not an execution boundary for this work.
    func admitsLiveManualClipMux() -> Bool {
        lock.lock()
        let allowed = applicationExecutionActive
        lock.unlock()
        return allowed
    }

    func noteAuxiliaryYield() {
        lock.lock(); auxiliaryYieldCount &+= 1; lock.unlock()
    }

    func noteScoreboardRealtimeYield() {
        lock.lock(); scoreboardRealtimeYieldCount &+= 1; lock.unlock()
    }

    func noteDeferredMediaYield() {
        lock.lock(); deferredMediaYieldCount &+= 1; lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let captureProbe = deferredMediaCaptureProbe
        let operatorActive = operatorInteractionActive
        let route = operatorRoute
        let generation = operatorGeneration
        let criticalLabels = criticalPreparations.values.sorted()
        let auxiliaryYields = auxiliaryYieldCount
        let scoreboardYields = scoreboardRealtimeYieldCount
        let mediaYields = deferredMediaYieldCount
        let realtimeCount = realtimeMediaCriticalCount
        let realtimePeak = realtimeMediaCriticalPeak
        let realtimeEntries = realtimeMediaCriticalEntries
        let appActive = applicationExecutionActive
        lock.unlock()
        let captureText = captureProbe?().diagnosticText ?? "probe-not-installed"
        return Snapshot(
            operatorInteractionActive: operatorActive,
            operatorRoute: route,
            operatorGeneration: generation,
            criticalPreparationCount: criticalLabels.count,
            criticalPreparationLabels: criticalLabels,
            auxiliaryYieldCount: auxiliaryYields,
            scoreboardRealtimeYieldCount: scoreboardYields,
            deferredMediaYieldCount: mediaYields,
            realtimeMediaCriticalCount: realtimeCount,
            realtimeMediaCriticalPeak: realtimePeak,
            realtimeMediaCriticalEntries: realtimeEntries,
            applicationExecutionActive: appActive,
            deferredMediaCaptureAdmissionText: captureText
        )
    }
}

// MARK: - UX16d1 Application Composition

/// Observer boundary for validation tooling that records scene transitions.
/// It must remain passive and may not start, stop or recover production engines.
@MainActor
protocol AppScenePhaseObserving: AnyObject {
    func appScenePhaseDidChange(_ phase: ScenePhase)
}

@MainActor
final class LiveAppScenePhaseObserver: AppScenePhaseObserving {
    func appScenePhaseDidChange(_ phase: ScenePhase) {
        RinkLensPhysicalValidationController.shared.noteScenePhase(phase)
        RinkLensControlledPilotController.shared.noteScenePhase(phase)
        RinkLensGameDayPilotController.shared.noteScenePhase(phase)
    }
}

@MainActor
final class NoOpAppScenePhaseObserver: AppScenePhaseObserving {
    func appScenePhaseDidChange(_ phase: ScenePhase) {}
}

/// Application composition root. UX16d1 makes dependencies explicit while
/// preserving the existing long-lived runtime and operator behaviour.
@MainActor
final class AppContainer: ObservableObject {
    static let shared = AppContainer()

    let coordinator: AppCoordinator
    let runtimeStatus: AppRuntimeStatus
    let diagnosticsService: DiagnosticsService
    let scoreboardViewModel: HockeyScoreboardViewModel
    let frameHub: RinkLensFrameHub
    let telemetry: any RinkLensTelemetryClient
    let clipEngine: ClipEngine
    let mediaRepository: MediaRepository
    let recordingEngine: RecordingEngine
    let ocrEngine: RinkLensOCREngine
    let scoreboardFramePipeline: ScoreboardFramePipeline

    /// Recovery AF: read-only access to the one process execution-admission owner.
    var executionCoordinator: RinkLensExecutionCoordinator { .shared }

    private let scenePhaseObserver: any AppScenePhaseObserving

    var captureEngine: RinkLensCaptureEngine {
        scoreboardViewModel.externalOCRMultiCamCoordinator
    }

    var captureUIState: ExternalOCRMultiCamUIState {
        captureEngine.uiState
    }

    private convenience init() {
        // UX16d3a: construct and publish the recording authorities before the
        // scoreboard ViewModel. ViewModel bootstrap refreshes the public overlay,
        // which still reaches the temporary BroadcastRecordingManager.shared
        // compatibility bridge. Point that bridge at these exact instances first
        // so it cannot recursively re-enter AppContainer.shared while the static
        // container is still being initialised.
        let clipEngine = ClipEngine()
        let mediaRepository = MediaRepository.shared
        let recordingEngine = RecordingEngine(
            clipEngine: clipEngine,
            mediaRepository: mediaRepository
        )
        ClipEngine.installShared(clipEngine)
        RecordingEngine.installShared(recordingEngine)
        let ocrEngine = RinkLensOCREngine()
        let scoreboardFramePipeline = ScoreboardFramePipeline()

        self.init(
            coordinator: AppCoordinator(),
            runtimeStatus: AppRuntimeStatus(),
            diagnosticsService: DiagnosticsService(),
            scoreboardViewModel: HockeyScoreboardViewModel(ocrEngine: ocrEngine, scoreboardFramePipeline: scoreboardFramePipeline),
            frameHub: .shared,
            telemetry: MainThreadStallMonitor.shared,
            clipEngine: clipEngine,
            mediaRepository: mediaRepository,
            recordingEngine: recordingEngine,
            ocrEngine: ocrEngine,
            scoreboardFramePipeline: scoreboardFramePipeline,
            scenePhaseObserver: LiveAppScenePhaseObserver()
        )
    }

    /// Internal initializer supports focused `@testable` composition tests
    /// without adding another process-wide service locator.
    init(
        coordinator: AppCoordinator,
        runtimeStatus: AppRuntimeStatus,
        diagnosticsService: DiagnosticsService,
        scoreboardViewModel: HockeyScoreboardViewModel,
        frameHub: RinkLensFrameHub,
        telemetry: any RinkLensTelemetryClient,
        clipEngine: ClipEngine,
        mediaRepository: MediaRepository,
        recordingEngine: RecordingEngine,
        ocrEngine: RinkLensOCREngine,
        scoreboardFramePipeline: ScoreboardFramePipeline,
        scenePhaseObserver: any AppScenePhaseObserving
    ) {
        self.coordinator = coordinator
        self.runtimeStatus = runtimeStatus
        self.diagnosticsService = diagnosticsService
        self.scoreboardViewModel = scoreboardViewModel
        self.frameHub = frameHub
        self.telemetry = telemetry
        self.clipEngine = clipEngine
        self.mediaRepository = mediaRepository
        self.recordingEngine = recordingEngine
        self.ocrEngine = ocrEngine
        self.scoreboardFramePipeline = scoreboardFramePipeline
        self.scenePhaseObserver = scenePhaseObserver

        // Recovery AN / RL-083: the execution coordinator asks the existing
        // CaptureEngine snapshot whether the real-time domain has spare capacity.
        // This is a read-through projection only; no camera state is copied into
        // AppContainer or MediaRepository.
        let captureEngine = scoreboardViewModel.externalOCRMultiCamCoordinator
        let captureLifecycleController = scoreboardViewModel.captureLifecycleController
        recordingEngine.installOCRRecoveryConvergenceHandler { requirement in
            await captureLifecycleController.convergeOCRBranchForRecordingContinuation(requirement)
        }
        captureEngine.installOCRRecoveryRequirementHandler { [weak recordingEngine] requirement in
            Task { @MainActor [weak recordingEngine] in
                recordingEngine?.considerOCRRecovery(requirement)
            }
        }
        RinkLensExecutionCoordinator.shared.installDeferredMediaCaptureProbe {
            let capture = captureEngine.snapshot
            let mode = RinkLensCaptureLifecycleMode(rawValue: capture.captureModeText) ?? .stopped
            return RinkLensExecutionCoordinator.DeferredMediaCaptureAdmission(
                captureActive: capture.isActive,
                sessionRunning: capture.sessionRunning,
                mode: mode.rawValue,
                livePressureLevel: capture.liveSystemPressureLevel,
                ocrPressureLevel: capture.ocrSystemPressureLevel,
                liveDroppedFrames: capture.liveDroppedFrames,
                ocrDroppedFrames: capture.ocrDroppedFrames,
                liveCallbackAgeSeconds: capture.liveLastCallbackAgeSeconds,
                ocrCallbackAgeSeconds: capture.ocrLastCallbackAgeSeconds,
                broadcastRequired: mode.requiresBroadcast,
                ocrRequired: mode.requiresOCR
            )
        }

        RinkLensExecutionCoordinator.shared.installDeferredMediaEligibilityHandler { [weak mediaRepository] reason in
            Task { @MainActor [weak mediaRepository] in
                mediaRepository?.resumePostCaptureOperationsAfterMediaLeaseRelease(reason: reason)
            }
        }

        runtimeStatus.markScoreboardRuntimeContainerOwned()
        telemetry.trace("RNG-S9A AppContainer created persistent HockeyScoreboardViewModel and DiagnosticsService")
    }

    func handleScenePhase(_ phase: ScenePhase) {
        scenePhaseObserver.appScenePhaseDidChange(phase)

        switch phase {
        case .active:
            RinkLensExecutionCoordinator.shared.setApplicationExecutionActive(true, source: "AppContainer.scenePhase active")
            captureEngine.noteAppScenePhase("active", reason: "scenePhase active")
            telemetry.noteAppDidResume(reason: "scenePhase active")
            scoreboardViewModel.handleAppDidBecomeActive(reason: "scenePhase active")
        case .inactive:
            RinkLensExecutionCoordinator.shared.setApplicationExecutionActive(false, source: "AppContainer.scenePhase inactive")
            captureEngine.noteAppScenePhase("inactive", reason: "scenePhase inactive")
            telemetry.trace("scenePhase inactive — retaining CaptureEngine graph")
            scoreboardViewModel.handleAppBecameInactive(reason: "scenePhase inactive")
        case .background:
            // Recovery CO: reset the heartbeat at the first background callback so
            // an OS suspension/snapshot gap cannot be attributed to the last UI context.
            telemetry.noteAppWillSuspend(reason: "scenePhase background")
            RinkLensExecutionCoordinator.shared.setApplicationExecutionActive(false, source: "AppContainer.scenePhase background")
            captureEngine.noteAppScenePhase("background", reason: "scenePhase background")
            scoreboardViewModel.handleAppWillSuspend(reason: "scenePhase background")
        @unknown default:
            telemetry.trace("unknown scenePhase received")
        }
    }
}

#endif
