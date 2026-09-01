// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import Foundation

// S11C compile fix: this engine reads @MainActor-owned runtime, camera, OCR,
// diagnostics and recording state. Evaluation is main-actor isolated so Swift 6
// does not flag service properties as nonisolated access.

// MARK: - RinkLens NextGen Stage 11B Operational Health Engine

/// Route-aware operational health snapshot for Command Centre presentation.
///
/// This is intentionally read-only against existing engines. It samples the
/// camera, OCR, recording, storage, diagnostics and thermal states and returns
/// a lightweight appliance-style health summary for the shell.
struct OperationalHealthSnapshot: Equatable {
    var overall: RuntimeHealthLevel
    var camera: RuntimeHealthLevel
    var ocr: RuntimeHealthLevel
    var recording: RuntimeHealthLevel
    var stream: RuntimeHealthLevel
    var storage: RuntimeHealthLevel
    var thermal: RuntimeHealthLevel
    var diagnostics: RuntimeHealthLevel
    var preview: RuntimeHealthLevel

    var cameraState: String
    var ocrState: String
    var recordingState: String
    var streamState: String
    var storageState: String
    var thermalState: String
    var previewState: String
    var summary: String
}

@MainActor
enum OperationalHealthEngine {
    static func evaluate(
        route: AppRoute,
        viewModel: HockeyScoreboardViewModel,
        recorder: BroadcastRecordingManager,
        clipBuffer: ClipBufferManager,
        diagnosticsService: DiagnosticsService
    ) -> OperationalHealthSnapshot {
        let camera = viewModel.liveCameraService
        let thermalText = DiagnosticsService.thermalStateText(ProcessInfo.processInfo.thermalState)
        let thermalHealth = DiagnosticsService.health(for: ProcessInfo.processInfo.thermalState)
        let cameraHealth = evaluateCamera(camera, route: route)
        let previewHealth = evaluatePreview(camera, route: route)
        let ocrHealth = evaluateOCR(viewModel, route: route)
        let recordingHealth = evaluateRecording(recorder: recorder, clipBuffer: clipBuffer, route: route)
        let storageHealth = evaluateStorage(recorder.photoLibraryStatusText)
        let destination = StreamDestinationStore.shared
        let streamControl = StreamControlStore.shared
        let streamHealth = evaluateStream(destination: destination, control: streamControl)
        let diagnosticsHealth = diagnosticsService.diagnosticsHealth == .unknown ? .ready : diagnosticsService.diagnosticsHealth
        let stallHealth = evaluateMainActorStalls(MainThreadStallMonitor.shared)

        let overall = [cameraHealth, previewHealth, ocrHealth, recordingHealth, storageHealth, thermalHealth, diagnosticsHealth, stallHealth]
            .reduce(.ready) { worst($0, $1) }

        let summary = buildSummary(
            overall: overall,
            route: route,
            camera: camera,
            recorder: recorder,
            diagnosticsService: diagnosticsService,
            cameraHealth: cameraHealth,
            previewHealth: previewHealth,
            ocrHealth: ocrHealth,
            storageHealth: storageHealth,
            thermalHealth: thermalHealth
        )

        return OperationalHealthSnapshot(
            overall: overall,
            camera: cameraHealth,
            ocr: ocrHealth,
            recording: recordingHealth,
            stream: streamHealth,
            storage: storageHealth,
            thermal: thermalHealth,
            diagnostics: worst(diagnosticsHealth, stallHealth),
            preview: previewHealth,
            cameraState: camera.isSessionRunning ? "running" : "stopped",
            ocrState: viewModel.ocrOperationalStatusText,
            recordingState: recorder.state.rawValue,
            streamState: streamStateText(destination: destination, control: streamControl),
            storageState: recorder.photoLibraryStatusText,
            thermalState: thermalText,
            previewState: previewStateText(camera, route: route),
            summary: summary
        )
    }

    private static func evaluateCamera(_ camera: HockeyCameraService, route: AppRoute) -> RuntimeHealthLevel {
        if camera.selectedResolutionFPS.lowercased().contains("no camera") { return .failed }
        guard camera.isSessionRunning else { return route == .broadcast ? .failed : .idle }
        guard camera.hasReceivedFrames else { return .degraded }
        return .ready
    }

    private static func evaluatePreview(_ camera: HockeyCameraService, route: AppRoute) -> RuntimeHealthLevel {
        guard route == .broadcast else { return .idle }
        guard camera.previewLayerAttached else { return .warning }
        guard camera.previewLayerReadyForDisplay else { return .warning }
        return .ready
    }

    private static func evaluateOCR(_ viewModel: HockeyScoreboardViewModel, route: AppRoute) -> RuntimeHealthLevel {
        if route == .commandCentre { return .idle }
        switch viewModel.ocrOperationalStatus {
        case .off:
            return .idle
        case .starting:
            return .degraded
        case .deferredByRecording:
            // UX16c53a: recording owns a temporary source-preservation lease;
            // the OCR request remains valid and will be replayed on release.
            return .warning
        case .waitingForFrame:
            return .warning
        case .stalled:
            return .failed
        case .interrupted:
            return .degraded
        case .failed:
            return .failed
        case .running:
            let summary = viewModel.ocrDiagnostics.ocrTrustSummary
            if summary.verifyCount > 0 || summary.lowConfidenceCount > 0 { return .warning }
            return .ready
        }
    }

    private static func evaluateRecording(recorder: BroadcastRecordingManager, clipBuffer: ClipBufferManager, route: AppRoute) -> RuntimeHealthLevel {
        if recorder.state == .failed || recorder.lastErrorMessage != nil { return .failed }
        if recorder.recordingEncoderBacklogText != "0" { return .degraded }
        if recorder.shouldShowRecordingFPSWarning || recorder.recordingFormatWarningText != nil { return .warning }
        if recorder.framesDropped > 30 { return .warning }
        if recorder.state == .recording { return .ready }
        if recorder.state == .paused || recorder.state == .starting || recorder.state == .stopping { return .degraded }
        return .idle
    }

    private static func evaluateStream(destination: StreamDestinationStore, control: StreamControlStore) -> RuntimeHealthLevel {
        if control.runtimeState == .failed { return .failed }
        if control.runtimeState == .publishing || control.runtimeState == .connected || control.runtimeState == .connecting { return .ready }
        if !destination.validationWarnings.isEmpty { return destination.hasAnyValue ? .warning : .idle }
        if destination.isConfigured { return .ready }
        return .idle
    }

    private static func streamStateText(destination: StreamDestinationStore, control: StreamControlStore) -> String {
        if control.runtimeState == .publishing || control.runtimeState == .connected || control.runtimeState == .connecting { return control.connectionStatusText }
        if destination.isConfigured { return "configured: \(destination.displayPlatformName)" }
        return "not configured"
    }

    private static func evaluateStorage(_ text: String) -> RuntimeHealthLevel {
        let lower = text.lowercased()
        if lower.contains("denied") || lower.contains("restricted") { return .failed }
        if lower.contains("limited") || lower.contains("unknown") || lower.contains("not requested") { return .warning }
        return .ready
    }

    private static func previewStateText(_ camera: HockeyCameraService, route: AppRoute) -> String {
        if route != .broadcast { return "inactive outside Broadcast" }
        if camera.previewLayerAttached && camera.previewLayerReadyForDisplay { return "visible" }
        if camera.previewLayerAttached { return "attached, waiting" }
        return "detached while Broadcast visible"
    }

    private static func buildSummary(
        overall: RuntimeHealthLevel,
        route: AppRoute,
        camera: HockeyCameraService,
        recorder: BroadcastRecordingManager,
        diagnosticsService: DiagnosticsService,
        cameraHealth: RuntimeHealthLevel,
        previewHealth: RuntimeHealthLevel,
        ocrHealth: RuntimeHealthLevel,
        storageHealth: RuntimeHealthLevel,
        thermalHealth: RuntimeHealthLevel
    ) -> String {
        var warnings: [String] = []
        if cameraHealth == .failed { warnings.append("Camera unavailable") }
        if route == .broadcast && previewHealth != .ready { warnings.append("Broadcast preview not ready") }
        if recorder.recordingEncoderBacklogText != "0" { warnings.append("Encoder backlog \(recorder.recordingEncoderBacklogText)") }
        if recorder.framesDropped > 30 { warnings.append("Dropped frames \(recorder.framesDropped)") }
        if ocrHealth == .warning { warnings.append("OCR needs review") }
        if storageHealth == .warning || storageHealth == .failed { warnings.append("Storage/photos access \(storageHealth.label.lowercased())") }
        let monitor = MainThreadStallMonitor.shared
        if monitor.longestStallSeconds >= 3.0 { warnings.append("MainActor stall \(monitor.longestStallText())") }
        if thermalHealth == .degraded || thermalHealth == .failed { warnings.append("Thermal state \(thermalHealth.label.lowercased())") }
        if diagnosticsService.warningSummary != "No active Command Centre warnings" && warnings.count < 3 {
            warnings.append(diagnosticsService.warningSummary)
        }
        if warnings.isEmpty { return "Operational health: \(overall.label)" }
        return warnings.prefix(3).joined(separator: " · ")
    }

    private static func evaluateMainActorStalls(_ monitor: MainThreadStallMonitor) -> RuntimeHealthLevel {
        if monitor.longestStallSeconds >= 10.0 { return .failed }
        if monitor.longestStallSeconds >= 3.0 { return .degraded }
        if monitor.stallCount > 0 { return .warning }
        return .ready
    }

    private static func worst(_ lhs: RuntimeHealthLevel, _ rhs: RuntimeHealthLevel) -> RuntimeHealthLevel {
        rank(rhs) > rank(lhs) ? rhs : lhs
    }

    private static func rank(_ level: RuntimeHealthLevel) -> Int {
        switch level {
        case .failed: return 5
        case .degraded: return 4
        case .warning: return 3
        case .unknown: return 2
        case .idle: return 1
        case .ready: return 0
        }
    }
}

#endif
