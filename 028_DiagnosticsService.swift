// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import Foundation

// MARK: - RinkLens Diagnostics Snapshot

/// UX16d1 value snapshot for the diagnostics shell. Diagnostics remains
/// read-only against camera, OCR, recording, rendering and clip owners.
struct DiagnosticsSnapshot: Equatable {
    var cameraFPS = "--"
    var sourceFPS = "--"
    var renderFPS = "--"
    var ocrCadence = "--"
    var ocrConfidence = "--"
    var droppedFrames = "0"
    var encoderBacklog = "0"
    var mainActorStalls = "0"
    var storageRunway = "not measured"
    var thermalState = "not measured"
    var cameraOwnership = "No active owner"
    var recordingState = "Idle"
    var diagnosticsHealth: RuntimeHealthLevel = .unknown
    var warningSummary = "Diagnostics warming up"
    var lastRefreshText = "Not refreshed"
    var lastRefreshDate = Date.distantPast
    var lastExportStatus = "No export yet"
    var lastExportPath = "Not exported"
    var lastExportURL: URL?
    var previewState = "not measured"
    var overallHealth: RuntimeHealthLevel = .unknown
    var operationalHealthSummary = "Operational health warming up"
}

@MainActor
final class DiagnosticsService: ObservableObject {
    /// Compatibility access for views not yet moved to AppContainer injection.
    /// UX16d1's live composition root constructs and injects its own instance.
    static let shared = DiagnosticsService()

    @Published private(set) var snapshot: DiagnosticsSnapshot

    init() {
        self.snapshot = DiagnosticsSnapshot()
    }

    init(snapshot: DiagnosticsSnapshot) {
        self.snapshot = snapshot
    }

    var cameraFPS: String { snapshot.cameraFPS }
    var sourceFPS: String { snapshot.sourceFPS }
    var renderFPS: String { snapshot.renderFPS }
    var ocrCadence: String { snapshot.ocrCadence }
    var ocrConfidence: String { snapshot.ocrConfidence }
    var droppedFrames: String { snapshot.droppedFrames }
    var encoderBacklog: String { snapshot.encoderBacklog }
    var mainActorStalls: String { snapshot.mainActorStalls }
    var storageRunway: String { snapshot.storageRunway }
    var thermalState: String { snapshot.thermalState }
    var cameraOwnership: String { snapshot.cameraOwnership }
    var recordingState: String { snapshot.recordingState }
    var diagnosticsHealth: RuntimeHealthLevel { snapshot.diagnosticsHealth }
    var warningSummary: String { snapshot.warningSummary }
    var lastRefreshText: String { snapshot.lastRefreshText }
    var lastRefreshDate: Date { snapshot.lastRefreshDate }
    var lastExportStatus: String { snapshot.lastExportStatus }
    var lastExportPath: String { snapshot.lastExportPath }
    var lastExportURL: URL? { snapshot.lastExportURL }
    var previewState: String { snapshot.previewState }
    var overallHealth: RuntimeHealthLevel { snapshot.overallHealth }
    var operationalHealthSummary: String { snapshot.operationalHealthSummary }

    private func assignSnapshot(_ next: DiagnosticsSnapshot) {
        guard next != snapshot else { return }
        snapshot = next
    }

    func refresh(viewModel: HockeyScoreboardViewModel, runtimeStatus: AppRuntimeStatus? = nil) {
        let refreshStarted = CFAbsoluteTimeGetCurrent()
        defer {
            MainThreadStallMonitor.shared.trace(
                String(format: "R19 diagnostics snapshot refresh completed in %.1fms", max(0, (CFAbsoluteTimeGetCurrent() - refreshStarted) * 1_000))
            )
        }
        let liveCamera = viewModel.liveCameraService
        let recorder = BroadcastRecordingManager.shared
        let renderer = PersistentBroadcastRendererDiagnostics.shared
        let monitor = MainThreadStallMonitor.shared
        let ownership = CameraOwnershipTraceStore.shared
        let ocrDiagnostics = viewModel.ocrDiagnostics
        let refreshDate = Date()
        let health = calculateHealth(recorder: recorder, renderer: renderer, monitor: monitor)
        let warnings = buildWarningSummary(recorder: recorder, renderer: renderer, monitor: monitor)

        var next = snapshot
        next.cameraFPS = liveCamera.selectedResolutionFPS
        next.sourceFPS = recorder.recordingSourceText
        next.renderFPS = renderer.actualFPS
        next.ocrCadence = String(format: "%.2fs / %@", viewModel.ocrIntervalSeconds, viewModel.isOCREffectiveRunning ? "running" : "idle")
        next.ocrConfidence = ocrDiagnostics.ocrTrustSummary.statusText
        next.droppedFrames = "\(recorder.framesDropped)"
        next.encoderBacklog = recorder.recordingEncoderBacklogText
        next.mainActorStalls = "\(monitor.stallCount) stalls · longest \(monitor.longestStallText())"
        next.storageRunway = recorder.photoLibraryStatusText
        next.thermalState = Self.thermalStateText(ProcessInfo.processInfo.thermalState)
        next.cameraOwnership = ownership.displayedOwnerSourceText
        next.recordingState = recorder.state.rawValue
        next.previewState = liveCamera.previewExpectationText + " · " + liveCamera.whiteScreenDetectorText
        next.lastRefreshDate = refreshDate
        next.lastRefreshText = refreshDate.formatted(date: .omitted, time: .standard)
        next.lastExportStatus = DiagnosticsLogExporter.shared.lastExportStatusText
        next.lastExportPath = DiagnosticsLogExporter.shared.lastExportPathText
        next.lastExportURL = DiagnosticsLogExporter.shared.lastExportURL
        next.diagnosticsHealth = health
        next.warningSummary = warnings
        assignSnapshot(next)

        guard let runtimeStatus else { return }

        let route = AppContainer.shared.coordinator.route
        let operational = OperationalHealthEngine.evaluate(
            route: route,
            viewModel: viewModel,
            recorder: recorder,
            clipBuffer: ClipBufferManager.shared,
            diagnosticsService: self
        )

        var completed = snapshot
        completed.overallHealth = operational.overall
        completed.operationalHealthSummary = operational.summary
        assignSnapshot(completed)

        runtimeStatus.markDiagnosticsSnapshot(
            diagnosticsState: health.label,
            warningSummary: warnings,
            lastExportStatus: completed.lastExportStatus,
            uiStallCount: monitor.stallCount,
            thermalState: completed.thermalState,
            thermalHealth: Self.health(for: ProcessInfo.processInfo.thermalState)
        )
        runtimeStatus.applyOperationalHealthSnapshot(operational)
    }

    @discardableResult
    func exportBundle(viewModel: HockeyScoreboardViewModel) async -> URL? {
        let url = await DiagnosticsLogExporter.shared.exportAllLogs(
            viewModel: viewModel,
            cameraService: viewModel.liveCameraService
        )
        var next = snapshot
        next.lastExportURL = url
        next.lastExportStatus = DiagnosticsLogExporter.shared.lastExportStatusText
        next.lastExportPath = DiagnosticsLogExporter.shared.lastExportPathText
        assignSnapshot(next)
        MainThreadStallMonitor.shared.trace(RinkLensBuildInfo.traceContext("diagnostics export requested from first-class Diagnostics module"))
        return url
    }

    private func calculateHealth(
        recorder: BroadcastRecordingManager,
        renderer: PersistentBroadcastRendererDiagnostics,
        monitor: MainThreadStallMonitor
    ) -> RuntimeHealthLevel {
        if recorder.state == .failed || recorder.lastErrorMessage != nil { return .failed }
        if ProcessInfo.processInfo.thermalState == .critical { return .failed }
        if ProcessInfo.processInfo.thermalState == .serious { return .degraded }
        if recorder.recordingEncoderBacklogText != "0" { return .degraded }
        if monitor.longestStallSeconds >= 10.0 { return .failed }
        if monitor.longestStallSeconds >= 3.0 { return .degraded }
        if recorder.framesDropped > 0 { return .warning }
        if renderer.renderDrops > 0 { return .warning }
        if monitor.stallCount > 0 { return .warning }
        return .ready
    }

    private func buildWarningSummary(
        recorder: BroadcastRecordingManager,
        renderer: PersistentBroadcastRendererDiagnostics,
        monitor: MainThreadStallMonitor
    ) -> String {
        var warnings: [String] = []

        if let error = recorder.lastErrorMessage, !error.isEmpty {
            warnings.append("Recording error: \(error)")
        }
        if recorder.recordingEncoderBacklogText != "0" {
            warnings.append("Encoder backlog \(recorder.recordingEncoderBacklogText)")
        }
        if recorder.framesDropped > 0 {
            warnings.append("\(recorder.framesDropped) dropped frames")
        }
        if renderer.renderDrops > 0 {
            warnings.append("\(renderer.renderDrops) renderer drops")
        }
        if monitor.longestStallSeconds >= 3.0 {
            warnings.append("MainActor stall \(monitor.longestStallText())")
        } else if monitor.stallCount > 0 {
            warnings.append("\(monitor.stallCount) MainActor stalls")
        }
        switch ProcessInfo.processInfo.thermalState {
        case .serious: warnings.append("Thermal state serious")
        case .critical: warnings.append("Thermal state critical")
        default: break
        }

        return warnings.isEmpty ? "No active Command Centre warnings" : warnings.prefix(3).joined(separator: " · ")
    }

    static func health(for thermalState: ProcessInfo.ThermalState) -> RuntimeHealthLevel {
        switch thermalState {
        case .nominal: return .ready
        case .fair: return .warning
        case .serious: return .degraded
        case .critical: return .failed
        @unknown default: return .unknown
        }
    }

    static func thermalStateText(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

#endif
