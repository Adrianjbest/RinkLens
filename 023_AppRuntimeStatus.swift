// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI

// MARK: - RinkLens Operational Runtime Status

enum RuntimeHealth: String, Equatable {
    case ready
    case idle
    case warning
    case degraded
    case failed
    case unknown

    var label: String {
        switch self {
        case .ready: return "Ready"
        case .idle: return "Idle"
        case .warning: return "Warning"
        case .degraded: return "Degraded"
        case .failed: return "Failed"
        case .unknown: return "Unknown"
        }
    }
}

typealias RuntimeHealthLevel = RuntimeHealth

/// UX16d1 single immutable-value runtime snapshot. The shell still exposes the
/// existing property names as read-only compatibility projections, but one
/// published value is now the sole observable source of truth.
struct AppRuntimeSnapshot: Equatable {
    var cameraReady = false
    var ocrReady = false
    var recordingReady = false
    var diagnosticsReady = false
    var streamReady = false

    var cameraState = "unknown"
    var ocrState = "unknown"
    var recordingState = "unknown"
    var streamState = "not configured"
    var storageState = "not measured"
    var thermalState = "not measured"
    var rinkProfile = "Default Rink"
    var uiStallCount = 0

    var diagnosticsState = "unknown"
    var diagnosticsWarningSummary = "Diagnostics warming up"
    var diagnosticsLastExportStatus = "No export yet"

    var sponsorState = "library ready"
    var mediaState = "library ready"

    var activeRouteTitle = "Command Centre"
    var previewVisibilityState = "inactive"
    var previewHealth: RuntimeHealthLevel = .idle
    var overallHealth: RuntimeHealthLevel = .unknown
    var operationalHealthSummary = "Operational health warming up"

    var cameraHealth: RuntimeHealthLevel = .unknown
    var ocrHealth: RuntimeHealthLevel = .unknown
    var recordingHealth: RuntimeHealthLevel = .idle
    var streamHealth: RuntimeHealthLevel = .idle
    var streamSetupState = "not configured"
    var cameraSetupState = "live/ocr cameras managed"
    var storageHealth: RuntimeHealthLevel = .unknown
    var thermalHealth: RuntimeHealthLevel = .unknown
    var diagnosticsHealth: RuntimeHealthLevel = .unknown
    var sponsorHealth: RuntimeHealthLevel = .ready
    var mediaHealth: RuntimeHealthLevel = .idle

    var scoreboardRuntimeOwner = "unknown"
    var cameraLifecyclePolicy = "unknown"
    var contentViewStopsCameraOnDisappear = true
}

@MainActor
final class AppRuntimeStatus: ObservableObject {
    @Published private(set) var snapshot: AppRuntimeSnapshot

    private var lastOperationalHealthSnapshot: OperationalHealthSnapshot?

    init() {
        self.snapshot = AppRuntimeSnapshot()
    }

    init(snapshot: AppRuntimeSnapshot) {
        self.snapshot = snapshot
    }

    // Existing read API retained while all observation is driven by `snapshot`.
    var cameraReady: Bool { snapshot.cameraReady }
    var ocrReady: Bool { snapshot.ocrReady }
    var recordingReady: Bool { snapshot.recordingReady }
    var diagnosticsReady: Bool { snapshot.diagnosticsReady }
    var streamReady: Bool { snapshot.streamReady }
    var cameraState: String { snapshot.cameraState }
    var ocrState: String { snapshot.ocrState }
    var recordingState: String { snapshot.recordingState }
    var streamState: String { snapshot.streamState }
    var storageState: String { snapshot.storageState }
    var thermalState: String { snapshot.thermalState }
    var rinkProfile: String { snapshot.rinkProfile }
    var uiStallCount: Int { snapshot.uiStallCount }
    var diagnosticsState: String { snapshot.diagnosticsState }
    var diagnosticsWarningSummary: String { snapshot.diagnosticsWarningSummary }
    var diagnosticsLastExportStatus: String { snapshot.diagnosticsLastExportStatus }
    var sponsorState: String { snapshot.sponsorState }
    var mediaState: String { snapshot.mediaState }
    var activeRouteTitle: String { snapshot.activeRouteTitle }
    var previewVisibilityState: String { snapshot.previewVisibilityState }
    var previewHealth: RuntimeHealthLevel { snapshot.previewHealth }
    var overallHealth: RuntimeHealthLevel { snapshot.overallHealth }
    var operationalHealthSummary: String { snapshot.operationalHealthSummary }
    var cameraHealth: RuntimeHealthLevel { snapshot.cameraHealth }
    var ocrHealth: RuntimeHealthLevel { snapshot.ocrHealth }
    var recordingHealth: RuntimeHealthLevel { snapshot.recordingHealth }
    var streamHealth: RuntimeHealthLevel { snapshot.streamHealth }
    var streamSetupState: String { snapshot.streamSetupState }
    var cameraSetupState: String { snapshot.cameraSetupState }
    var storageHealth: RuntimeHealthLevel { snapshot.storageHealth }
    var thermalHealth: RuntimeHealthLevel { snapshot.thermalHealth }
    var diagnosticsHealth: RuntimeHealthLevel { snapshot.diagnosticsHealth }
    var sponsorHealth: RuntimeHealthLevel { snapshot.sponsorHealth }
    var mediaHealth: RuntimeHealthLevel { snapshot.mediaHealth }
    var scoreboardRuntimeOwner: String { snapshot.scoreboardRuntimeOwner }
    var cameraLifecyclePolicy: String { snapshot.cameraLifecyclePolicy }
    var contentViewStopsCameraOnDisappear: Bool { snapshot.contentViewStopsCameraOnDisappear }

    private func updateSnapshot(_ mutation: (inout AppRuntimeSnapshot) -> Void) {
        var next = snapshot
        mutation(&next)
        guard next != snapshot else { return }
        snapshot = next
    }

    func markScoreboardRuntimeContainerOwned() {
        updateSnapshot { state in
            state.scoreboardRuntimeOwner = "AppContainer.scoreboardViewModel"
            state.cameraLifecyclePolicy = "Persistent HockeyScoreboardViewModel; one CaptureEngine owns AVCaptureMultiCamSession"
            state.contentViewStopsCameraOnDisappear = false
            state.cameraReady = true
            state.ocrReady = true
            state.diagnosticsReady = true
            state.cameraState = "persistent"
            state.ocrState = "standby"
            state.recordingState = "idle"
            state.streamState = "not configured"
            state.storageState = "not measured"
            state.thermalState = "not measured"
            state.rinkProfile = "Default Rink"
            state.cameraHealth = .ready
            state.ocrHealth = .idle
            state.recordingHealth = .idle
            state.streamHealth = .idle
            state.streamSetupState = "not configured"
            state.cameraSetupState = "persistent camera services"
            state.storageHealth = .unknown
            state.thermalHealth = .unknown
            state.diagnosticsHealth = .ready
            state.sponsorHealth = .warning
            state.mediaHealth = .idle
            state.diagnosticsState = "Ready"
            state.diagnosticsWarningSummary = "No active Command Centre warnings"
            state.sponsorState = "setup shell; asset storage pending"
            state.mediaState = "recording library idle"
            state.activeRouteTitle = "Command Centre"
            state.previewVisibilityState = "inactive outside Broadcast"
            state.previewHealth = .idle
            state.overallHealth = .ready
            state.operationalHealthSummary = "Ready"
        }
    }

    func markRouteVisible(_ route: AppRoute) {
        updateSnapshot { state in
            state.activeRouteTitle = route.title
            let isBroadcastVisible = route == .broadcast
            state.previewVisibilityState = isBroadcastVisible ? "visible in Broadcast" : "inactive outside Broadcast"
            state.previewHealth = isBroadcastVisible ? state.cameraHealth : .idle
        }
    }

    func applyOperationalHealthSnapshot(_ health: OperationalHealthSnapshot) {
        guard health != lastOperationalHealthSnapshot else { return }
        lastOperationalHealthSnapshot = health
        updateSnapshot { state in
            state.overallHealth = health.overall
            state.operationalHealthSummary = health.summary
            state.cameraHealth = health.camera
            state.ocrHealth = health.ocr
            state.recordingHealth = health.recording
            state.streamHealth = health.stream
            state.storageHealth = health.storage
            state.thermalHealth = health.thermal
            state.diagnosticsHealth = health.diagnostics
            state.previewHealth = health.preview
            state.cameraState = health.cameraState
            state.ocrState = health.ocrState
            state.recordingState = health.recordingState
            state.streamState = health.streamState
            state.storageState = health.storageState
            state.thermalState = health.thermalState
            state.diagnosticsState = health.diagnostics.label
            state.diagnosticsWarningSummary = health.summary
            state.previewVisibilityState = health.previewState
        }
    }

    func markOCRSetupVisible(
        templateName: String?,
        operationalStatus: HockeyScoreboardViewModel.OCROperationalStatus
    ) {
        updateSnapshot { state in
            state.ocrReady = operationalStatus == .running
            state.diagnosticsReady = true
            state.ocrState = operationalStatus.rawValue
            state.diagnosticsHealth = .ready
            switch operationalStatus {
            case .off: state.ocrHealth = .idle
            case .starting: state.ocrHealth = .degraded
            case .deferredByRecording: state.ocrHealth = .warning
            case .running: state.ocrHealth = .ready
            case .waitingForFrame: state.ocrHealth = .warning
            case .stalled: state.ocrHealth = .failed
            case .interrupted: state.ocrHealth = .degraded
            case .failed: state.ocrHealth = .failed
            }
            if let templateName, !templateName.isEmpty {
                state.rinkProfile = templateName
            }
        }
    }

    func markRecordingModuleVisible(recorder: BroadcastRecordingManager, clipBuffer: ClipBufferManager) {
        let photosText = recorder.photoLibraryStatusText.lowercased()
        let totalMediaItems = recorder.savedRecordingsCount + recorder.savedManualHighlightsCount + recorder.savedAutoHighlightsCount

        updateSnapshot { state in
            state.recordingReady = true
            state.storageState = recorder.photoLibraryStatusText
            state.recordingState = recorder.state.rawValue

            if recorder.state == .failed || recorder.lastErrorMessage != nil {
                state.recordingHealth = .failed
            } else if recorder.recordingFormatWarningText != nil || recorder.shouldShowRecordingFPSWarning {
                state.recordingHealth = .warning
            } else if recorder.state == .recording {
                state.recordingHealth = .ready
            } else if recorder.state == .paused || recorder.state == .starting || recorder.state == .stopping {
                state.recordingHealth = .degraded
            } else {
                state.recordingHealth = .idle
            }

            if photosText.contains("denied") || photosText.contains("restricted") {
                state.storageHealth = .failed
            } else if photosText.contains("limited") || photosText.contains("not requested") || photosText.contains("unknown") {
                state.storageHealth = .warning
            } else {
                state.storageHealth = .ready
            }

            if clipBuffer.clipStatusText.lowercased().contains("unavailable"), state.recordingHealth == .ready {
                state.recordingHealth = .warning
            }

            state.mediaState = "\(totalMediaItems) item\(totalMediaItems == 1 ? "" : "s") · \(recorder.photoLibraryStatusText)"
            state.mediaHealth = state.storageHealth
        }
    }

    func markSponsorsModuleVisible() {
        updateSnapshot { state in
            state.sponsorState = "setup shell; data-backed asset storage pending"
            state.sponsorHealth = .warning
            state.diagnosticsReady = true
        }
    }

    func markStreamSetupVisible(destination: StreamDestinationStore, control: StreamControlStore) {
        updateSnapshot { state in
            state.streamReady = destination.isReadyForBroadcastFlow
            state.streamSetupState = destination.isConfigured ? "configured: \(destination.displayPlatformName)" : "not configured"
            state.streamState = control.connectionStatusText

            if control.runtimeState == .failed {
                state.streamHealth = .failed
            } else if control.runtimeState == .publishing || control.runtimeState == .connecting {
                state.streamHealth = .ready
            } else if !destination.validationWarnings.isEmpty {
                state.streamHealth = .warning
            } else if destination.isConfigured {
                state.streamHealth = .ready
            } else {
                state.streamHealth = .idle
            }
        }
    }

    func markCameraSetupVisible(viewModel: HockeyScoreboardViewModel) {
        updateSnapshot { state in
            state.cameraSetupState = "live=\(viewModel.liveCameraService.effectiveCameraLabel) · ocr=\(viewModel.ocrCameraService.effectiveCameraLabel)"
            state.cameraState = viewModel.liveCameraService.isSessionRunning ? "running" : "configured"
            if viewModel.liveCameraService.selectedResolutionFPS.lowercased().contains("no camera") {
                state.cameraHealth = .failed
            } else if viewModel.liveCameraService.isReconfiguring || viewModel.ocrCameraService.isReconfiguring {
                state.cameraHealth = .warning
            } else {
                state.cameraHealth = .ready
            }
        }
    }

    func markMediaModuleVisible(recorder: BroadcastRecordingManager, clipBuffer: ClipBufferManager) {
        markRecordingModuleVisible(recorder: recorder, clipBuffer: clipBuffer)
        let totalMediaItems = recorder.savedRecordingsCount + recorder.savedManualHighlightsCount + recorder.savedAutoHighlightsCount
        updateSnapshot { state in
            state.mediaState = "recordings/highlights/clips: \(totalMediaItems)"
            if state.mediaHealth == .idle || state.mediaHealth == .unknown {
                state.mediaHealth = .ready
            }
        }
    }

    func markDiagnosticsSnapshot(
        diagnosticsState: String,
        warningSummary: String,
        lastExportStatus: String,
        uiStallCount: Int,
        thermalState: String,
        thermalHealth: RuntimeHealthLevel
    ) {
        updateSnapshot { state in
            state.diagnosticsReady = true
            state.diagnosticsState = diagnosticsState
            state.diagnosticsWarningSummary = warningSummary
            state.diagnosticsLastExportStatus = lastExportStatus
            state.uiStallCount = uiStallCount
            state.thermalState = thermalState
            state.thermalHealth = thermalHealth

            if warningSummary == "No active Command Centre warnings" {
                state.diagnosticsHealth = .ready
            } else if diagnosticsState == RuntimeHealthLevel.failed.label {
                state.diagnosticsHealth = .failed
            } else if diagnosticsState == RuntimeHealthLevel.degraded.label {
                state.diagnosticsHealth = .degraded
            } else {
                state.diagnosticsHealth = .warning
            }
        }
    }
}

#endif
