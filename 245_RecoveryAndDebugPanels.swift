// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI

// STYLE2 coverage: \(RinkLensStyle2Coverage.summary)
import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Darwin)
import Darwin
#endif

struct RecoveryActionsPanel: View {
    @ObservedObject var viewModel: HockeyScoreboardViewModel
    let cameraService: HockeyCameraService
    @State private var retryInProgress = false
    @State private var retryStatusText = "No degraded retry requested"
    @ObservedObject private var recorder = BroadcastRecordingManager.shared

    @ViewBuilder
    var body: some View {
        if RinkLensRiskFeaturePolicy.isEnabled(.minimalOperatorCameraRecordingV12) {
            DiagnosticsCard(title: "Recovery", systemImage: "lifepreserver") {
                HStack(spacing: 8) {
                    Button(viewModel.cameraRecoveryInProgress ? "Recovering…" : "Recover Camera") {
                        RinkLensControlledPilotController.shared.noteOperatorRecoveryAction("Recover Camera Preview")
                        RinkLensGameDayPilotController.shared.noteOperatorRecoveryAction("Recover Camera Preview")
                        viewModel.requestCameraPreviewRecovery(for: cameraService, reason: "minimal diagnostics recover camera")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.cameraRecoveryInProgress || cameraService.isReconfiguring)

                    Button("Restart Recognition") {
                        RinkLensControlledPilotController.shared.noteOperatorRecoveryAction("Restart OCR Pipeline")
                        RinkLensGameDayPilotController.shared.noteOperatorRecoveryAction("Restart OCR Pipeline")
                        viewModel.pauseOCRProcessing()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            viewModel.resumeOCRProcessing()
                        }
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 8) {
                    Button("Reset Rotation") {
                        viewModel.resetLivePreviewRotation()
                        viewModel.resetOCRPreviewRotation()
                    }
                    Button("Clear Debug State") {
                        viewModel.clearDebugHistory()
                        viewModel.resetOCRTrustState()
                    }
                }
                .buttonStyle(.bordered)
            }
        } else {
                VStack(alignment: .leading, spacing: 12) {
                    TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                        let degraded = viewModel.externalOCRMultiCamCoordinator.snapshot.degradedRecord
                        DiagnosticsCard(title: "Degraded Capture Retry", systemImage: "arrow.clockwise.circle") {
                            DiagnosticsRow(title: "Failed contract", value: degraded?.failedContract.diagnosticText ?? "none")
                            DiagnosticsRow(title: "Failure", value: degraded?.failureText ?? "none")
                            DiagnosticsRow(title: "Cooldown remaining", value: degraded.map { String(format: "%.1fs", $0.cooldownRemainingSeconds) } ?? "none")
                            DiagnosticsRow(title: "Retry status", value: retryStatusText)
            
                            Button {
                                RinkLensControlledPilotController.shared.noteOperatorRecoveryAction("Retry Failed Camera Contract")
                                RinkLensGameDayPilotController.shared.noteOperatorRecoveryAction("Retry Failed Camera Contract")
                                retryInProgress = true
                                retryStatusText = "Retrying exact failed camera contract…"
                                Task { @MainActor in
                                    let outcome = await viewModel.captureLifecycleController.retryDegradedCapture(
                                        reason: "Diagnostics Recovery operator action"
                                    )
                                    retryStatusText = outcome.statusText
                                    retryInProgress = false
                                }
                            } label: {
                                Label("Retry Failed Camera Contract", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(degraded == nil || retryInProgress || cameraService.isReconfiguring || recorder.isRecording)
                        }
                    }
            
                    DiagnosticsCard(title: "Safe Recovery Actions", systemImage: "lifepreserver") {
                        Button(viewModel.cameraRecoveryInProgress ? "Recovering Camera Preview…" : "Recover Camera Preview") {
                            RinkLensControlledPilotController.shared.noteOperatorRecoveryAction("Recover Camera Preview")
                            RinkLensGameDayPilotController.shared.noteOperatorRecoveryAction("Recover Camera Preview")
                            viewModel.requestCameraPreviewRecovery(for: cameraService, reason: "diagnostics hub recover camera preview")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.cameraRecoveryInProgress)
                        .disabled(cameraService.isReconfiguring)
            
                        Button("Restart OCR Pipeline") {
                            RinkLensControlledPilotController.shared.noteOperatorRecoveryAction("Restart OCR Pipeline")
                            RinkLensGameDayPilotController.shared.noteOperatorRecoveryAction("Restart OCR Pipeline")
                            viewModel.pauseOCRProcessing()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                viewModel.resumeOCRProcessing()
                            }
                        }
                        .buttonStyle(.bordered)
                    }
            
                    DiagnosticsCard(title: "Reset Debug State", systemImage: "trash.circle") {
                        Button("Clear OCR Debug History") {
                            viewModel.clearDebugHistory()
                        }
                        .buttonStyle(.bordered)
            
                        Button("Reset OCR Trust State") {
                            viewModel.resetOCRTrustState()
                        }
                        .buttonStyle(.bordered)
            
                        Button("Reset Camera Rotation") {
                            viewModel.resetLivePreviewRotation()
                            viewModel.resetOCRPreviewRotation()
                        }
                        .buttonStyle(.bordered)
                    }
            
                    DiagnosticsCard(title: "Advanced Recovery Notes", systemImage: "exclamationmark.triangle") {
                        Text("Advanced actions are intentionally manual. Automatic recovery during Broadcast/Calibration transitions has caused preview ownership conflicts in earlier builds.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
        }
    }

}

@MainActor
final class DiagnosticsLogExporter: ObservableObject {
    static let shared = DiagnosticsLogExporter()

    @Published private(set) var lastExportStatusText: String = "No export yet"
    @Published private(set) var lastExportPathText: String = "Not exported"
    @Published private(set) var lastExportURL: URL?
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgressText = "Idle"

    private static let fileTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    private static let displayTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZ"
        return formatter
    }()

    private init() {}

    @discardableResult
    func exportAllLogs(
        viewModel: HockeyScoreboardViewModel,
        cameraService: HockeyCameraService
    ) async -> URL? {
        guard !isExporting else {
            lastExportStatusText = "Export already in progress"
            return nil
        }

        isExporting = true
        exportProgressText = "Collecting diagnostics…"
        defer {
            isExporting = false
            exportProgressText = "Idle"
        }

        let started = MainThreadStallMonitor.shared.beginTimedOperation("Diagnostics.allLogsExport")
        await Task.yield()
        let text = await buildLogSnapshot(viewModel: viewModel, cameraService: cameraService)
        let acceptanceJSON = RinkLensPhysicalAcceptanceMonitor.shared.exportJSON()
        let fileName = "RinkLens_AllLogs_\(Self.fileTimestampFormatter.string(from: Date())).txt"
        exportProgressText = "Writing support file…"
        await Task.yield()

        let result = await Task.detached(priority: .utility) { () -> (URL?, String?) in
            do {
                return (try Self.writeLog(text, acceptanceJSON: acceptanceJSON, fileName: fileName), nil)
            } catch {
                return (nil, error.localizedDescription)
            }
        }.value

        MainThreadStallMonitor.shared.endTimedOperation("Diagnostics.allLogsExport", startedAt: started)
        if let url = result.0 {
            lastExportURL = url
            lastExportStatusText = "Saved \(url.lastPathComponent)"
            lastExportPathText = url.path
            MainThreadStallMonitor.shared.trace("all logs exported asynchronously: \(url.lastPathComponent)")
            return url
        }

        lastExportStatusText = "Export failed"
        lastExportPathText = result.1 ?? "Unknown export error"
        MainThreadStallMonitor.shared.trace("all logs export failed: \(lastExportPathText)")
        return nil
    }

    nonisolated private static func writeLog(_ text: String, acceptanceJSON: String, fileName: String) throws -> URL {
        guard fileName.lowercased().hasSuffix(".txt") else {
            throw NSError(
                domain: "RinkLensDiagnostics",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Diagnostics export filename must end in .txt"]
            )
        }

        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent(BroadcastRecordingManager.logsFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName)

        let encodingMarker = "# encoding=UTF-8; format=plain-text"
        let exportText = text.hasPrefix(encodingMarker) ? text : "\(encodingMarker)\n\(text)"
        let utf8Data = Data(exportText.utf8)
        try utf8Data.write(to: url, options: .atomic)

        // Recovery DU UTF8 patch: the exported support file is an operator-facing
        // diagnostic contract. Verify the exact bytes on disk before exposing the
        // URL to the share sheet so a failed/changed encoding cannot be mistaken
        // for a valid All Logs export.
        let writtenData = try Data(contentsOf: url)
        guard writtenData == utf8Data,
              let decoded = String(data: writtenData, encoding: .utf8),
              decoded == exportText else {
            try? FileManager.default.removeItem(at: url)
            throw NSError(
                domain: "RinkLensDiagnostics",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Diagnostics export failed UTF-8 round-trip verification"]
            )
        }

        let sidecarName = fileName
            .replacingOccurrences(of: "RinkLens_AllLogs_", with: "RinkLens_PhysicalAcceptance_")
            .replacingOccurrences(of: ".txt", with: ".json")
        try acceptanceJSON.write(
            to: folder.appendingPathComponent(sidecarName),
            atomically: true,
            encoding: .utf8
        )
        return url
    }

    /// UX16c41c: validate and share the stable Documents file directly. The
    /// previous temporary copy triggered LaunchServices/FileProvider lookups and
    /// could race a second share activity, producing the errors seen in the
    /// supplied device log.
    func prepareShareURL(for sourceURL: URL) -> URL? {
        do {
            guard sourceURL.pathExtension.lowercased() == "txt" else {
                throw NSError(
                    domain: "RinkLensDiagnostics",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Diagnostics share file must be a .txt file"]
                )
            }
            guard FileManager.default.fileExists(atPath: sourceURL.path),
                  FileManager.default.isReadableFile(atPath: sourceURL.path) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isReadableKey])
            guard values.isReadable == true, (values.fileSize ?? 0) > 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let shareData = try Data(contentsOf: sourceURL)
            guard !shareData.isEmpty,
                  String(data: shareData, encoding: .utf8) != nil else {
                throw NSError(
                    domain: "RinkLensDiagnostics",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Diagnostics share file is not valid UTF-8 plain text"]
                )
            }
            MainThreadStallMonitor.shared.trace("diagnostics stable UTF-8 txt share file ready: \(sourceURL.lastPathComponent) bytes=\(values.fileSize ?? 0)")
            return sourceURL
        } catch {
            lastExportStatusText = "Share preparation failed"
            lastExportPathText = error.localizedDescription
            MainThreadStallMonitor.shared.trace("diagnostics share preparation failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Removes operator-created support exports while leaving the OCR Evidence
    /// subdirectory to its journal owner. No Photos media is affected.
    func clearStoredExports() async -> RinkLensStorageClearResult {
        guard !isExporting else { return .blocked("Wait for the current diagnostics export to finish.") }
        let result = await Task.detached(priority: .utility) {
            let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let folder = base.appendingPathComponent(BroadcastRecordingManager.logsFolderName, isDirectory: true)
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            var files = 0
            var bytes: Int64 = 0
            var failure: String?
            for url in urls where url.lastPathComponent != "OCR Evidence" {
                let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                do {
                    try FileManager.default.removeItem(at: url)
                    files += 1
                    bytes += size
                } catch {
                    failure = error.localizedDescription
                }
            }
            return RinkLensStorageClearResult(files: files, bytes: bytes, blockedReason: failure)
        }.value
        lastExportURL = nil
        lastExportStatusText = "Stored support exports cleared"
        lastExportPathText = "No stored export"
        return result
    }

    private func clipBufferPathDisplayText(_ clipBuffer: ClipBufferManager) -> String {
        if clipBuffer.isActive { return clipBuffer.clipBufferPathText }
        let lower = clipBuffer.clipBufferPathText.lowercased()
        if lower.contains("uiimage") {
            return "inactive; PixelBuffer path when recording"
        }
        return "inactive; \(clipBuffer.clipBufferPathText)"
    }

    private func rendererTargetDisplayText(_ renderer: PersistentBroadcastRendererDiagnostics, recorder: BroadcastRecordingManager) -> String {
        let recordingTarget = recorder.recordingTargetFPSText
        let rendererTarget = "\(renderer.targetFPS)fps"
        if recorder.state == .recording {
            return "recording target \(recordingTarget); renderer target \(rendererTarget); actual \(renderer.actualFPS)"
        }
        return "recording target \(recordingTarget); idle preview renderer target \(rendererTarget); actual \(renderer.actualFPS)"
    }

    private func buildLogSnapshot(viewModel: HockeyScoreboardViewModel, cameraService: HockeyCameraService) async -> String {
        let monitor = MainThreadStallMonitor.shared
        let recorder = BroadcastRecordingManager.shared
        let renderer = PersistentBroadcastRendererDiagnostics.shared
        let pacer = BroadcastRenderPacerDiagnostics.shared
        let formatGuard = RecordingCameraFormatValidationDiagnostics.shared
        let clipBuffer = ClipBufferManager.shared
        let ownership = CameraOwnershipTraceStore.shared
        let activeRoute = AppContainer.shared.coordinator.route
        let now = Date()
        let engineeringOCREvidenceLines = await RinkLensOCREvidenceJournal.shared.exportLines()
        let engineeringZoneEditLines = await RinkLensOCREvidenceJournal.shared.exportZoneEditLines()
        let engineeringScoreTransitionLines = await RinkLensOCREvidenceJournal.shared.exportScoreTransitionLines()
        let engineeringEventAuditLines = await RinkLensOCREvidenceJournal.shared.exportEventAuditLines()
        let structuredStateTransitionLines = RinkLensStructuredEventLogger.shared.exportLines()
        let sandboxStorageLines = await Task.detached(priority: .utility) {
            MediaRepository.storageDiagnosticsLines()
        }.value

        var lines: [String] = [
            "RINKLENS ALL LOGS EXPORT",
            "Created: \(Self.displayTimestampFormatter.string(from: now))",
            RinkLensBuildInfo.diagnosticsExportVersionLine,
            ""
        ]

        lines += section(
            "PHYSICAL ACCEPTANCE SUMMARY",
            RinkLensPhysicalAcceptanceMonitor.shared.exportLines(now: now)
        )
        lines += section("APPLICATION / MAIN THREAD", [
            "Refresh: \(Self.displayTimestampFormatter.string(from: now))",
            "Heartbeat age: \(heartbeatAgeText(monitor: monitor, now: now))",
            "UI stall count: \(monitor.stallCount)",
            "Longest UI stall: \(stallText(monitor.longestStallSeconds))",
            "Active NextGen route: \(activeRoute.title)",
            "Last scoreboard screen snapshot: \(viewModel.currentScreen.rawValue)",
            "Current UI context: \(monitor.currentContext)",
            "Last UI stall: \(monitor.lastStallText)",
            "Last UI stall context: \(monitor.lastStallContext)",
            "Last timed operation: \(monitor.lastTimedOperationText)",
            "Longest timed operation: \(monitor.longestTimedOperationText)",
            "Published updates: \(monitor.publishPressureText)",
            "Largest publish burst: \(monitor.largestPublishBurstText)",
            "Top publish source: \(monitor.topPublishSourceText)",
            "Execution admission: \(RinkLensExecutionCoordinator.shared.snapshot().diagnosticText)",
            "Diagnostics mode: \(monitor.diagnosticsModeText)"
        ])

        lines += section("HARDWARE / PERFORMANCE SNAPSHOT", hardwarePerformanceLines())
        lines += section("SANDBOX STORAGE", [
            "Confirmed duplicate migration: \(MediaRepository.shared.confirmedDuplicateMigrationSummaryText)"
        ] + sandboxStorageLines)
        lines += section(
            "CONFIGURABLE APPLICATION SETTINGS",
            configurableApplicationSettingsLines(
                viewModel: viewModel,
                cameraService: cameraService,
                recorder: recorder,
                renderer: renderer,
                clipBuffer: clipBuffer,
                monitor: monitor
            )
        )
        lines += section("DIAGNOSTICS EXPORT SCHEMA", diagnosticsExportSchemaLines())
        lines += section("CENTRAL FEATURE FLAGS", operationalPolicyLines(monitor: monitor))
        lines += section("APP APPEARANCE / STYLE1", appAppearanceLines())
        lines += section("SCROLL PERFORMANCE / UX2", scrollPerformanceLines())
        lines += section("PERFORMANCE BUDGETS", performanceBudgetLines(viewModel: viewModel, recorder: recorder, renderer: renderer, monitor: monitor))
        lines += section("MATCH DAY SAFE MODE", matchDaySafeModeLines(monitor: monitor))
        lines += section("BROADCAST COMPOSITE STANDARD", broadcastCompositeStandardLines())
        lines += section("BROADCAST VIEW SNAPSHOT", broadcastViewLines(viewModel: viewModel, recorder: recorder, renderer: renderer, activeRoute: activeRoute))
        lines += section("INTERNAL MATCH EVENT JOURNAL", matchTimelineEventLines(viewModel: viewModel))
        lines += section("CALIBRATION VIEW SNAPSHOT", calibrationViewLines(viewModel: viewModel, cameraService: cameraService, activeRoute: activeRoute))
        await Task.yield()
        lines += section("OCR CHROME GEOMETRY", OCRChromeGeometryDiagnosticsStore.shared.exportLines())
        lines += section("SWITCH BREADCRUMBS", monitor.recentEvents.isEmpty ? ["none"] : monitor.recentEvents)
        lines += section(
            "RENDER / PREVIEW / TOGGLE PROFILER",
            monitor.renderPreviewToggleEvents.isEmpty ? ["none"] : monitor.renderPreviewToggleEvents
        )

        lines += section("CAMERA / PREVIEW", cameraLines(viewModel: viewModel, service: cameraService, now: now))
        lines += section("CAPTUREENGINE FALLBACK / DROPS / PRESSURE", captureEngineResilienceLines(viewModel: viewModel))
        lines += section("RECORDING / RENDERER", recordingLines(recorder: recorder, renderer: renderer, pacer: pacer))
        lines += section("RENDER PACER DIAGNOSTICS", renderPacerLines(pacer))
        lines += section("60FPS CAPTURE VALIDATION", captureValidationLines(formatGuard, recorder: recorder))
        lines += section("DIAGNOSTICS SUPPRESSION WHILE RECORDING", diagnosticsSuppressionLines(monitor: monitor, recorder: recorder, cameraService: cameraService, viewModel: viewModel))
        await Task.yield()
        lines += section("CLIP BUFFER", clipBufferLines(clipBuffer))
        lines += section("DARK CONTENT / SOURCE AVAILABILITY TRACE", blackFrameRejectionLines(BlackFrameRejectionTraceStore.shared))
        lines += section("ESSENTIAL STRUCTURED STATE TRANSITIONS", structuredStateTransitionLines)
        lines += section("ENGINEERING OCR EVIDENCE JOURNAL", engineeringOCREvidenceLines)
        lines += section("ENGINEERING ZONE EDIT AUDIT TRAIL", engineeringZoneEditLines)
        lines += section("ENGINEERING SCORE-FIELD TRANSITION HISTORY", engineeringScoreTransitionLines)
        lines += section("ENGINEERING EVENT / OVERLAY LIFECYCLE AUDIT", engineeringEventAuditLines)
        lines += section("OCR DIAGNOSTICS", ocrLines(viewModel: viewModel))
        await Task.yield()
        lines += section("MATCH STATE REDUCER", matchStateReducerLines(viewModel: viewModel))
        lines += section("UX16C47 PHYSICAL VALIDATION", RinkLensPhysicalValidationController.shared.exportLines())
        lines += section("UX16C48 CONTROLLED RINK PILOT", RinkLensControlledPilotController.shared.exportLines())
        lines += section("UX16C49 GAME-DAY PILOT", RinkLensGameDayPilotController.shared.exportLines())
        lines += section("REGRESSION TEST RESULTS", regressionTestLines(viewModel: viewModel, recorder: recorder, renderer: renderer, clipBuffer: clipBuffer, ownership: ownership, monitor: monitor))
        lines += section("CAMERA OWNERSHIP TRACE", ownershipLines(viewModel: viewModel, ownership: ownership, now: now))

        return lines.joined(separator: "\n")
    }

    private func matchTimelineEventLines(viewModel: HockeyScoreboardViewModel) -> [String] {
        let events = viewModel.matchTimeline.sorted {
            if $0.actualObservedAt != $1.actualObservedAt {
                return $0.actualObservedAt < $1.actualObservedAt
            }
            return $0.createdAt < $1.createdAt
        }
        guard !events.isEmpty else { return ["No internal match events recorded"] }
        return events.enumerated().map { offset, event in
            let players = event.penaltyClockSnapshot.compactMap { clock -> String? in
                guard let player = clock.playerNumber else { return nil }
                return "\(clock.team.rawValue)-#\(player)@slot\(clock.slot)"
            }.joined(separator: ",")
            let ended = event.endedPenaltyClockSnapshot?.compactMap { clock -> String? in
                guard let player = clock.playerNumber else { return nil }
                return "\(clock.team.rawValue)-#\(player)@slot\(clock.slot)"
            }.joined(separator: ",") ?? "none"
            return [
                "seq=\(offset + 1)",
                "id=\(event.id.uuidString)",
                "type=\(event.type.rawValue)",
                "team=\(event.team?.rawValue ?? "none")",
                "observed=\(Self.displayTimestampFormatter.string(from: event.actualObservedAt))",
                "period=\(event.period.map { String($0) } ?? "none")",
                "penaltyLifecycle=\(event.penaltyLifecycleID ?? "none")",
                "timelineState=\(event.timelineLifecycleState ?? "legacy")",
                "popupState=\(event.popupLifecycleState ?? "legacy")",
                "generation=\(event.captureGeneration.map { String($0) } ?? "none")",
                "stoppage=\(event.stoppageID?.uuidString ?? "none")",
                "activePenalties=[\(players)]",
                "endedPenalties=[\(ended)]"
            ].joined(separator: " | ")
        }
    }

    private func section(_ title: String, _ body: [String]) -> [String] {
        ["", "=== \(title) ===", ""] + body + [""]
    }

    private func activeOperationalPolicy(monitor: MainThreadStallMonitor) -> RinkLensOperationalPolicy {
        monitor.diagnosticsMode == .matchDaySafe ? .matchDaySafe : .standard
    }

    private func diagnosticsExportSchemaLines() -> [String] {
        let schema = RinkLensDiagnosticsExportSchema.current
        return [
            "Diagnostics schema version: \(schema.diagnosticsSchemaVersion)",
            "App version: \(RinkLensBuildInfo.version)",
            "App state version: \(schema.appStateVersion)",
            "Camera state version: \(schema.cameraStateVersion)",
            "Recording state version: \(schema.recordingStateVersion)",
            "Sponsor state version: \(schema.sponsorStateVersion)",
            "OCR state version: \(schema.ocrStateVersion)",
            "Overlay queue state version: \(schema.overlayQueueStateVersion)",
            "Broadcast phase state version: \(schema.broadcastPhaseStateVersion)",
            "Broadcast composite state version: \(schema.broadcastCompositeStateVersion)",
            "Regression schema version: \(schema.regressionSchemaVersion)",
            "State ownership version: \(schema.stateOwnershipVersion)",
            "Structured event log version: \(schema.structuredEventLogVersion)",
            "Schema summary: \(schema.diagnosticSummary)"
        ]
    }

    private func operationalPolicyLines(monitor: MainThreadStallMonitor) -> [String] {
        let flags = activeOperationalPolicy(monitor: monitor)
        return [
            "Active policy: \(monitor.diagnosticsMode == .matchDaySafe ? "Match Day Safe" : "Standard")",
            "Operational policy: \(flags.diagnosticSummary)",
            "Player penalty sponsors: \(enabledDisabled(flags.playerPenaltySponsorsEnabled))",
            "Goal sponsor overlays: \(enabledDisabled(flags.goalSponsorOverlaysEnabled))",
            "Intermission reel: \(enabledDisabled(flags.intermissionReelEnabled))",
            "OCR intermission countdown: \(enabledDisabled(flags.ocrIntermissionCountdownEnabled))",
            "Unified overlay queue: \(enabledDisabled(flags.unifiedOverlayQueueEnabled))",
            "Broadcast composite standard: \(enabledDisabled(flags.broadcastCompositeStandardEnabled))",
            "Typed diagnostic channels: \(enabledDisabled(flags.diagTraceChannelsEnabled))",
            "Regression harness: \(enabledDisabled(flags.regressionHarnessEnabled))",
            "Sponsor test popups: \(enabledDisabled(flags.sponsorTestPopupsEnabled))",
            "Verbose debug panels: \(enabledDisabled(flags.verboseDebugPanelsEnabled))",
            "Heavy OCR fallback: \(enabledDisabled(flags.heavyOCRFallbackEnabled))",
            "Risk rollout flags: \(RinkLensRiskFeaturePolicy.diagnosticSummary)",
            "State ownership: \(RinkLensStateOwnershipRegistry.diagnosticSummary)"
        ]
    }


    private func appAppearanceLines() -> [String] {
        let appearance = RinkLensAppearanceSettings.shared
        return [
            "Design system: STYLE1 central template",
            "Preset: \(appearance.preset.title)",
            "Summary: \(appearance.summaryText)",
            "Accent colour RGBA: \(appearance.accentRGBA)",
            "Background colour RGBA: \(appearance.backgroundRGBA)",
            "Panel colour RGBA: \(appearance.panelRGBA)",
            "Font scale: \(String(format: "%.2f", appearance.fontScale))",
            "Corner radius: \(Int(appearance.cornerRadius))",
            "High contrast text: \(yesNo(appearance.highContrastText))",
            "Coverage: Settings chrome uses RinkLensDesignSystem; app screens should migrate to these tokens instead of local font/colour constants",
            "Broadcast output: COMPOSITE standard preserved separately from operator-screen appearance"
        ]
    }

    private func scrollPerformanceLines() -> [String] {
        [
            "Policy: shared lazy-scroll and throttled-refresh standard",
            "Summary: \(RinkLensScrollPerformancePolicy.summary)",
            "Status refresh minimum: \(String(format: "%.1fs", RinkLensScrollPerformancePolicy.statusRefreshMinimumInterval))",
            "Diagnostics refresh minimum: \(String(format: "%.2fs", RinkLensScrollPerformancePolicy.diagnosticsRefreshMinimumInterval))",
            "Media refresh minimum: \(String(format: "%.1fs", RinkLensScrollPerformancePolicy.mediaRefreshMinimumInterval))",
            "Pattern: LazyVStack/LazyVGrid, stable row IDs, cached thumbnails, no heavy row-body work, no repeated media scans while scrolling, capped diagnostics/status writes",
            "Scope: operator screens and media/diagnostics lists only; COMPOSITE broadcast overlay and recording renderer are preserved"
        ]
    }

    private func performanceBudgetLines(
        viewModel: HockeyScoreboardViewModel,
        recorder: BroadcastRecordingManager,
        renderer: PersistentBroadcastRendererDiagnostics,
        monitor: MainThreadStallMonitor
    ) -> [String] {
        let budget = RinkLensPerformanceBudgets.matchDay
        let publishPerSecond = firstNumber(from: monitor.publishPressureText) ?? 0
        let backlog = firstNumber(from: recorder.recordingEncoderBacklogText) ?? 0
        let renderMs = firstDouble(from: renderer.lastRenderTimeMs) ?? 0
        let ocrWithinBudget = viewModel.ocrIntervalSeconds <= budget.ocrCycleSeconds + 0.001
        let renderWithinBudget = renderMs <= budget.overlayRenderMilliseconds || renderMs == 0
        let publishWithinBudget = publishPerSecond <= budget.diagnosticsPublishUpdatesPerSecond
        let backlogWithinBudget = backlog <= budget.encoderBacklogMaximum
        let dropsWithinBudget = recorder.framesDropped <= budget.droppedFramesWarningThreshold
        let stallsWithinBudget = monitor.stallCount <= budget.mainThreadStallMaximum

        return [
            "Budget summary: \(budget.diagnosticSummary)",
            "Preview UI update budget: <=\(String(format: "%.1f", budget.previewUIUpdateMilliseconds))ms - observational in SAFE1",
            "Recording frame append budget: <=\(String(format: "%.1f", budget.recordingFrameAppendMilliseconds))ms at 60fps - writer wait should remain below frame interval",
            "Overlay/render budget: \(renderWithinBudget ? "within threshold" : "outside threshold") - render=\(renderer.lastRenderTimeMs) target<=\(String(format: "%.1f", budget.overlayRenderMilliseconds))ms",
            "OCR cycle budget: \(ocrWithinBudget ? "within threshold" : "outside threshold") - interval=\(String(format: "%.2f", viewModel.ocrIntervalSeconds))s target<=\(String(format: "%.2f", budget.ocrCycleSeconds))s",
            "Diagnostics publish budget: \(publishWithinBudget ? "within threshold" : "outside threshold") - publish=\(monitor.publishPressureText) target<=\(budget.diagnosticsPublishUpdatesPerSecond)/sec",
            "Encoder backlog budget: \(backlogWithinBudget ? "within threshold" : "outside threshold") - backlog=\(recorder.recordingEncoderBacklogText) target<=\(budget.encoderBacklogMaximum)",
            "Dropped frames budget: \(dropsWithinBudget ? "within threshold" : "outside threshold") - dropped=\(recorder.framesDropped) target<=\(budget.droppedFramesWarningThreshold)",
            "Main-thread stall budget: \(stallsWithinBudget ? "within threshold" : "outside threshold") - stalls=\(monitor.stallCount) target<=\(budget.mainThreadStallMaximum)",
            "Memory budget: warn above \(String(format: "%.0f", budget.appMemoryWarningMegabytes))MB app footprint",
            "Battery budget: warn below \(budget.batteryWarningPercent)% before match-day use"
        ]
    }

    private func matchDaySafeModeLines(monitor: MainThreadStallMonitor) -> [String] {
        let policy = RinkLensMatchDaySafeModePolicy.standard
        let active = monitor.diagnosticsMode == .matchDaySafe
        return [
            "Active: \(yesNo(active))",
            "Policy summary: \(policy.diagnosticSummary)",
            "Preserved: camera, recording, manual scoreboard, basic OCR, goal/penalty overlays, clip buffer",
            "Restricted: verbose diagnostics, experimental overlays, heavy OCR fallback, sponsor test popups, unnecessary publish pressure",
            "Diagnostics mode effect: \(active ? "critical-only trace capture and reduced diagnostics publish pressure" : "available but not currently active")",
            "Operator guidance: use Match Day Safe for live games; use Rink Test for rink setup; use Engineering for fault-finding only"
        ]
    }

    private func broadcastCompositeStandardLines() -> [String] {
        let canvas = BroadcastCompositeStandard.canonicalCanvas
        let scorebug = BroadcastCompositeStandard.scorebugRect(outputSize: canvas, includesGameSponsor: true)
        let league = BroadcastCompositeStandard.leagueBadgeRect(outputSize: canvas)
        let season = BroadcastCompositeStandard.seasonSponsorBadgeRect(outputSize: canvas)
        return [
            "Composite standard: \(BroadcastCompositeStandard.diagnosticSummary)",
            "Canonical canvas: \(Int(canvas.width))x\(Int(canvas.height)); origin=top-left; coordinates are output-independent",
            "Top row: league logo left, scorebug centre, season sponsor right",
            "Scorebug rect with game sponsor: x=\(Int(scorebug.minX)) y=\(Int(scorebug.minY)) w=\(Int(scorebug.width)) h=\(Int(scorebug.height))",
            "League badge rect: x=\(Int(league.minX)) y=\(Int(league.minY)) w=\(Int(league.width)) h=\(Int(league.height))",
            "Season sponsor rect: x=\(Int(season.minX)) y=\(Int(season.minY)) w=\(Int(season.width)) h=\(Int(season.height))",
            "Logo policy: orientation-aware UIImage draw; aspect-fit; never stretch; pixel-aligned output rects",
            "Text policy: uniform fitted fonts; no horizontal squeezing; safe score columns; pixel-aligned text boxes",
            "UX9 canonical preview: Settings Live Broadcast Preview is rendered through the same cached compositor as Broadcast, recording and clips; name-aware scorebug sizing prevents full team names being squeezed or abbreviated",
            "UX10 operator UI: Camera settings use the shared Settings card template; Media is simplified to reduce scroll judder; manual score update events omit game-clock time",
            "UX11 settings save guard: Teams & Logos and Scorebug changes prompt to save to the active profile, with Profiles guidance when no profile is loaded; Settings scorebug preview is compact while editing colours",
            "UX12 compact match controls: manual clip button flashes green when pressed; Beside Name scorebug metrics are tightened so logo/name/score, LIVE/OCR and game sponsor occupy less camera area",
            "Build 708 retirement: the viewer event timeline and its textual Clock OCR metadata lane are removed; the internal event journal remains for popup sequencing, audit and undo",
            "UX12e Settings polish: Sponsors, Stream and Camera embedded headers use the same Settings card/pill treatment; Event Popup tests are inline-only and do not enqueue a full-screen Settings preview",
            "UX12s Camera source mapping: Built-in Back is the rear zoom source; Ultra Wide is hidden as a selector row and reached through 0.5x zoom; refresh does not silently select defaults; manual controls remain visible",
            "UX12t Settings camera preload: Broadcast/OCR source lists refresh when Settings Camera appears and when each selector is loaded; no camera session is started by the preload",
            "UX12u flat Settings camera cards: Camera no longer opens a nested Settings menu; Broadcast/OCR controls are grouped into source, picture, lens, exposure, white-balance and rotation cards",
            "UX12v Camera sub-tabs: Settings Camera keeps the flat card style but separates controls into Broadcast and OCR sub-tabs to reduce scrolling",
            "WYSIWYG preview: \(BroadcastCompositeStandard.wysiwygPreviewDescription)",
            "Preview frame: 16:9 letterboxed stage; black bars are outside the recorded 1920x1080 canvas",
            "Operator controls: status, quick controls and zoom remain in the raised letterbox/outside area; no event timeline is rendered",
            "Output contract: iPad preview video+overlay, full-match recording, manual clips and future stream use the same 16:9 composite frame"
        ]
    }

    private func hardwarePerformanceLines() -> [String] {
        let processInfo = ProcessInfo.processInfo
        let disk = diskCapacitySnapshot()
        let memory = memorySnapshot(processInfo: processInfo)

        var lines: [String] = [
            "Device: \(deviceNameText())",
            "Make: \(deviceMakeText())",
            "Model identifier: \(hardwareModelIdentifierText())",
            "OS: \(processInfo.operatingSystemVersionString)",
            "Thermal state: \(thermalStateText(processInfo.thermalState))",
            "Low power mode: \(yesNo(processInfo.isLowPowerModeEnabled))",
            "Processor count: \(processInfo.processorCount)",
            "Active processor count: \(processInfo.activeProcessorCount)",
            "System uptime: \(durationText(processInfo.systemUptime))",
            "Physical memory: \(byteText(memory.physicalBytes))",
            "App memory footprint: \(byteText(memory.appFootprintBytes))",
            "Disk total: \(byteText(disk.totalBytes))",
            "Disk free: \(byteText(disk.freeBytes))"
        ]

        lines += batteryLines()
        return lines
    }

    private func configurableApplicationSettingsLines(
        viewModel: HockeyScoreboardViewModel,
        cameraService: HockeyCameraService,
        recorder: BroadcastRecordingManager,
        renderer: PersistentBroadcastRendererDiagnostics,
        clipBuffer: ClipBufferManager,
        monitor: MainThreadStallMonitor
    ) -> [String] {
        let overlay = BroadcastScoreboardLayoutSettings.shared
        let profile = recorder.recordingProfile
        let calibrationProfile = viewModel.calibrationCameraProfile
        let ocrCameraService = viewModel.ocrCameraService
        let multiCam = viewModel.externalOCRMultiCamCoordinator.snapshot
        let calibrationSourceIDText = calibrationProfile.selectedCameraSourceID ?? "system default"
        let calibrationFormatText = calibrationProfile.resolutionFormatID ?? "device default"
        let calibrationFrameRateText = calibrationProfile.frameRate.map { "\($0)fps" } ?? "device default"
        let key = viewModel.selectedRegionKey
        let region = viewModel.ocrLayout[key]
        let selectedZoneText = "\(key.likelyTitle) x=\(format(region.x)) y=\(format(region.y)) w=\(format(region.width)) h=\(format(region.height))"

        var lines: [String] = [
            "Format: Area | Setting | Active at export | Passive/selectable values | Diagnostic note"
        ]

        lines += [
            settingLine(
                area: "Settings source",
                name: "Export coverage",
                active: "Runtime snapshot plus saved app settings",
                passive: "Spreadsheet defaults, saved profiles, runtime controls, hardware state",
                note: "Captures what is active now and the passive choices that could affect diagnostics"
            ),
            settingLine(
                area: "Governance",
                name: "Feature flags",
                active: activeOperationalPolicy(monitor: monitor).diagnosticSummary,
                passive: "Standard, Match Day Safe policy-derived flags",
                note: "Central FLAGS1 switchboard for sponsor, intermission, overlay, diagnostics and safe-mode behaviour"
            ),
            settingLine(
                area: "Appearance",
                name: "STYLE1 central template",
                active: RinkLensAppearanceSettings.shared.summaryText,
                passive: "Broadcast Dark, Ice Blue, High Contrast, Warm Arena plus custom colours/font scale/corners",
                note: "Central place for menus, settings, diagnostics and operator-screen look and feel"
            ),
            settingLine(
                area: "Appearance",
                name: "UX2 scroll performance standard",
                active: RinkLensScrollPerformancePolicy.summary,
                passive: "LazyVStack/LazyVGrid, throttled refresh, stable rows and cached thumbnails for heavy screens",
                note: "Used where screens have long lists, media rows, diagnostics rows, sponsor catalogues or many controls"
            ),
            settingLine(
                area: "Appearance",
                name: "UX12v Settings workflow",
                active: "Profiles-first tabs; Appearance second from end; System last; compact scorebug preview; logo-background preview; active-profile save prompt; Camera Broadcast/OCR sub-tabs",
                passive: "Teams & Logos and Scorebug changes can be saved to the active profile; Camera controls are separated into Broadcast and OCR sub-tabs with small inline menus",
                note: "Keeps match setup in workflow order without adding nested Camera navigation or one long Camera scroll"
            ),
            settingLine(
                area: "Governance",
                name: "Performance budgets",
                active: RinkLensPerformanceBudgets.matchDay.diagnosticSummary,
                passive: "Budget-only warnings in SAFE1; no recording engine behaviour is changed",
                note: "Formal BUDGET1 targets for live-video diagnostics"
            ),
            settingLine(
                area: "Governance",
                name: "Diagnostics schema",
                active: RinkLensDiagnosticsExportSchema.current.diagnosticSummary,
                passive: "Versioned export schema sections",
                note: "SCHEMA1 keeps log review stable as sections evolve"
            ),
            settingLine(
                area: "Governance",
                name: "Match Day Safe policy",
                active: RinkLensMatchDaySafeModePolicy.standard.diagnosticSummary,
                passive: "Available through Match Day Safe diagnostics mode",
                note: "MATCHSAFE1 preserves core broadcast features while reducing risky/debug behaviour"
            ),
            settingLine(
                area: "Broadcast output",
                name: "Composite standard",
                active: BroadcastCompositeStandard.diagnosticSummary,
                passive: "Preview, recording, manual clips and future streaming output",
                note: "UX6 centralises canvas, team-logo scorebug/event popups, dynamic sponsor badges, preview-only sponsor hiding, top-row anchors, scorebug home/away background colours and direct Settings setup routing"
            ),
            settingLine(
                area: "Diagnostics",
                name: "Diagnostics mode",
                active: monitor.diagnosticsModeText,
                passive: optionList(RuntimeDiagnosticsMode.allCases.map(\.rawValue)),
                note: "Controls live log verbosity and runtime overhead"
            ),
            settingLine(
                area: "Diagnostics",
                name: "Breadcrumb detail",
                active: monitor.diagnosticsDetailText,
                passive: "Production critical, Rink Test operational, Engineering verbose",
                note: "Controls trace detail so match-day logging stays lightweight while fault-finding remains useful"
            ),
            settingLine(
                area: "Recording",
                name: "Recording profile",
                active: profile.label,
                passive: "Camera-derived resolution/frame rate plus recording codec and bitrate",
                note: "Primary quality preset used by full-match recording"
            ),
            settingLine(
                area: "Recording",
                name: "Resolution",
                active: profile.resolution.rawValue,
                passive: optionList(BroadcastRecordingProfile.Resolution.allCases.map(\.rawValue)),
                note: "Affects encoder load, clip exports, and storage use"
            ),
            settingLine(
                area: "Recording",
                name: "Frame rate",
                active: profile.frameRate.label,
                passive: optionList(BroadcastRecordingProfile.FrameRate.allCases.map(\.label)),
                note: "Recording target FPS"
            ),
            settingLine(
                area: "Recording",
                name: "Codec",
                active: profile.codec.rawValue,
                passive: optionList(BroadcastRecordingProfile.Codec.allCases.map(\.rawValue)),
                note: "Video encoder format"
            ),
            settingLine(
                area: "Recording",
                name: "Bitrate",
                active: profile.bitrate.rawValue,
                passive: optionList(BroadcastRecordingProfile.Bitrate.allCases.map(\.rawValue)),
                note: "Recording quality and file-size tradeoff"
            ),
            settingLine(
                area: "Camera",
                name: "Broadcast stabilisation",
                active: viewModel.broadcastVideoStabilisationEnabled ? "Enabled (prefers Low Latency)" : "Off",
                passive: "Off, Enabled; CaptureEngine prefers Low Latency when the active format supports it, otherwise Standard/Auto",
                note: "Requested state is CameraControlStore-owned; the applied AVCaptureConnection mode is physical truth"
            ),
            settingLine(
                area: "Recording",
                name: "Renderer target",
                active: rendererTargetDisplayText(renderer, recorder: recorder),
                passive: "Recording target and idle preview renderer target are labelled separately",
                note: "Useful for diagnosing FPS drift without confusing idle preview pacing with recording FPS"
            ),
            settingLine(
                area: "Clip buffer",
                name: "Rolling buffer",
                active: "\(enabledDisabled(clipBuffer.isActive)); \(clipBuffer.bufferDurationText); path=\(clipBufferPathDisplayText(clipBuffer))",
                passive: "Active while recording, inactive while stopped",
                note: "Source for manual and automatic highlight clips"
            ),
            settingLine(
                area: "Clip buffer",
                name: "Manual clip export",
                active: "\(recorder.manualClipExportStateText); \(recorder.manualClipFeedbackText)",
                passive: "Unavailable, ready, queued, saving, saved, failed",
                note: "Shareable state at the moment the log was taken"
            )
        ]

        lines += [
            settingLine(
                area: "Broadcast overlay",
                name: "Scoreboard visibility",
                active: enabledDisabled(overlay.isVisible),
                passive: "Visible, hidden",
                note: "Whether the production scorebug is drawn"
            ),
            settingLine(
                area: "Broadcast overlay",
                name: "Position",
                active: overlay.positionPreset.title,
                passive: optionList(BroadcastScoreboardPositionPreset.allCases.map(\.title)),
                note: "Primary on-screen scorebug placement"
            ),
            settingLine(
                area: "Broadcast overlay",
                name: "Logo position",
                active: overlay.logoPosition.title,
                passive: optionList(BroadcastScoreboardLogoPosition.allCases.map(\.title)),
                note: "Scorebug logo placement"
            ),
            settingLine(
                area: "Broadcast overlay",
                name: "Size authority",
                active: "Team Font \(Int(overlay.teamNameFontSize.rounded()))pt",
                passive: "20pt to 48pt continuous master scale",
                note: "One control scales team names, scores, Clock, logos, centre readouts, penalty presentation, spacing and panel size"
            ),
            settingLine(
                area: "Broadcast overlay",
                name: "Event timeline",
                active: "Retired",
                passive: "No viewer timeline",
                note: "Build 708 removed the viewer timeline and associated textual Clock OCR; internal event journalling remains"
            ),
            settingLine(
                area: "Broadcast overlay",
                name: "Safe margin and offset",
                active: "safe=\(format(overlay.safeMargin)) h=\(format(overlay.horizontalOffset)) v=\(format(overlay.verticalOffset))",
                passive: "Adjustable numeric layout values",
                note: "Helps diagnose clipped or drifting overlays"
            ),
            settingLine(
                area: "Broadcast overlay",
                name: "Team names",
                active: "\(viewModel.homeTeamName) vs \(viewModel.awayTeamName)",
                passive: "Editable match/team labels",
                note: "Used in broadcast overlay, recording filenames, and clips"
            ),
            settingLine(
                area: "Broadcast overlay",
                name: "Team font",
                active: "\(Int(overlay.teamNameFontSize.rounded()))pt \(overlay.teamNameFontWeight.title)",
                passive: optionList(BroadcastScoreboardFontWeight.allCases.map(\.title)),
                note: "Team Font is the master scorebug scale; weight applies to team names"
            ),
            settingLine(
                area: "Broadcast overlay",
                name: "Colours",
                active: "homeText=\(overlay.homeTeamNameColour.rgbaString), awayText=\(overlay.awayTeamNameColour.rgbaString), homeBg=\(overlay.homeTeamBackgroundColour.rgbaString), awayBg=\(overlay.awayTeamBackgroundColour.rgbaString), homeLogoBg=\(overlay.homeLogoContainerBackground.rgbaString), awayLogoBg=\(overlay.awayLogoContainerBackground.rgbaString), bg=\(overlay.scoreboardBackgroundColour.rgbaString)",
                passive: "Editable colour swatches",
                note: "Useful when exported clips or screenshots look wrong"
            ),
            settingLine(
                area: "Broadcast overlay",
                name: "Event popups",
                active: BroadcastEventPopupSettings.shared.summaryText,
                passive: "Goal popups, penalty popups, separate goal/penalty logo toggles, actual team names toggle and popup duration",
                note: "Configured from Settings -> Broadcast Setup -> Event Popups"
            ),
            settingLine(
                area: "Sponsors",
                name: "Catalogue and placements",
                active: SponsorCatalogueStore.shared.diagnosticsSummary,
                passive: "League branding, season sponsor, game sponsor, goal sponsors, penalty sponsors, final score and intermission reel",
                note: "Configured from Settings -> Sponsors / Sponsors module"
            )
        ]

        lines += [
            settingLine(
                area: "Camera",
                name: "Forensic instance identity",
                active: viewModel.diagnosticIdentityText,
                passive: "ViewModel, Broadcast service, OCR service and AVCaptureSession object identities",
                note: "UX16c20 proves whether Settings, preview and exported diagnostics refer to the same service/session instances"
            ),
            settingLine(
                area: "Camera",
                name: "CaptureEngine session state",
                active: "mode=\(multiCam.captureModeText); phase=\(multiCam.phase.rawValue); configured=\(yesNo(multiCam.sessionConfigured)); running=\(yesNo(multiCam.sessionRunning)); active=\(yesNo(multiCam.isActive)); generation=\(multiCam.transitionGeneration)",
                passive: "Stopped, Broadcast-only, OCR-only or dual-camera",
                note: "Authoritative state comes from the single CaptureEngine snapshot, not compatibility camera facades"
            ),
            settingLine(
                area: "Camera",
                name: "CaptureEngine preview endpoints",
                active: "broadcast=\(yesNo(multiCam.broadcastPreviewAttached)); ocr=\(yesNo(multiCam.ocrPreviewAttached)); facadeGeometry=\(cameraService.previewLayerFrameText)",
                passive: "Persistent Broadcast and OCR preview connections on the same graph",
                note: "Route presentation may hide an endpoint without changing capture ownership"
            ),
            settingLine(
                area: "Camera",
                name: "OCR camera requested controls",
                active: "\(viewModel.calibrationCameraProfileStatusText) requestedLocks=\(calibrationProfile.lockSummary); savedSourcePreference=\(calibrationProfile.selectedCameraSourceKind.title) [\(calibrationSourceIDText)]",
                passive: "Saved request intent only; it does not describe applied hardware state",
                note: "RinkLensCameraControlStore/calibration profile owns requested intent; HockeyCameraService acknowledges physical application"
            ),
            settingLine(
                area: "Camera",
                name: "Broadcast camera selection",
                active: "logicalLabel=\(viewModel.liveCameraService.selectedCameraLabel); sourceID=\(viewModel.liveCameraService.selectedCameraID ?? "none"); preferredPhysicalID=\(viewModel.liveCameraService.resolvedCameraDeviceID ?? "none"); activePhysicalID=\(multiCam.liveDeviceID ?? "none"); activeName=\(multiCam.liveDeviceName); activePosition=\(multiCam.liveDevicePositionText); activeType=\(multiCam.liveDeviceTypeText); graphResolvedFormat=\(multiCam.liveFormatText); graphConfiguredCadence=\(multiCam.liveConfiguredCadenceText); observedCallback=\(String(format: "%.1ffps", multiCam.liveObservedFPS)); generation=\(multiCam.transitionGeneration); selectedExactProfile=\(viewModel.liveCameraService.selectedCapabilityProfileID ?? "automatic")",
                passive: "Camera-supported 720p, 1080p, and 1440p modes at 30 or 60 fps only",
                note: "The active physical camera and format are confirmed only by the CaptureEngine snapshot"
            ),
            settingLine(
                area: "Camera",
                name: "Broadcast imaging capability matrix",
                active: viewModel.liveCameraService.broadcastImagingCapabilitiesText,
                passive: "Active 1080 format: MultiCam/binned/FPS, automatic frame-rate, low-light boost, HDR, colour spaces, stabilisation modes, digital-upscale threshold, ISO and exposure range",
                note: "Recovery CZ reads physical AVCaptureDevice.Format capabilities; HDR/colour-space capability is diagnostic-only in this build"
            ),
            settingLine(
                area: "Camera",
                name: "OCR camera selection",
                active: "logicalLabel=\(ocrCameraService.selectedCameraLabel); sourceID=\(ocrCameraService.selectedCameraID ?? "none"); preferredPhysicalID=\(ocrCameraService.resolvedCameraDeviceID ?? "none"); activePhysicalID=\(multiCam.ocrDeviceID ?? "none"); activeName=\(multiCam.ocrDeviceName); activePosition=\(multiCam.ocrDevicePositionText); activeType=\(multiCam.ocrDeviceTypeText); graphResolvedFormat=\(multiCam.ocrFormatText); graphConfiguredCadence=\(multiCam.ocrConfiguredCadenceText); observedCallback=\(String(format: "%.1ffps", multiCam.ocrObservedFPS)); generation=\(multiCam.transitionGeneration); selectedExactProfile=\(ocrCameraService.selectedCapabilityProfileID ?? "automatic")",
                passive: "Camera-supported 720p, 1080p, and 1440p modes at 30 or 60 fps only",
                note: "Logical selection, resolved physical device and active graph format are reported separately to expose stale selection state"
            ),
            settingLine(
                area: "Camera",
                name: "Camera discovery",
                active: "broadcast={\(viewModel.liveCameraService.cameraDiscoverySummaryText)}; ocr={\(ocrCameraService.cameraDiscoverySummaryText)}",
                passive: "Refresh on startup, Camera Settings open, manual refresh, external connect and disconnect",
                note: "Shows whether both camera roles discovered built-in sources without relying on an external-camera event"
            ),
            settingLine(
                area: "Camera",
                name: "Camera authorization / input creation",
                active: "authorization=\(ocrCameraService.cameraAuthorizationStatusText); candidates=\(ocrCameraService.inputCandidateTraceText); lastError=\(ocrCameraService.lastInputCreationErrorText)",
                passive: "Authorized, denied, restricted, device-in-use, disconnected and physical-device fallback states",
                note: "UX16c12 preserves the underlying AVFoundation error instead of reporting only Could not create camera input"
            ),
            settingLine(
                area: "Camera",
                name: "Camera facade / CaptureEngine binding",
                active: "broadcast={\(viewModel.liveCameraService.captureGraphStatusText)}; ocr={\(ocrCameraService.captureGraphStatusText)}",
                passive: "Facades retain logical selection and device controls; CaptureEngine snapshot reports the only runtime graph",
                note: "UX16c35 removes private AVCaptureSession and AVCaptureDeviceInput creation from both camera facades"
            ),
            settingLine(
                area: "Camera",
                name: "Broadcast + External OCR MultiCam owner",
                active: "requested=\(yesNo(viewModel.externalOCRMultiCamRequested)); required=\(yesNo(viewModel.externalOCRMultiCamRequired)); mode=\(multiCam.captureModeText); phase=\(multiCam.phase.rawValue); active=\(yesNo(multiCam.isActive)); transitioning=\(yesNo(multiCam.isTransitioning)); configured=\(yesNo(multiCam.sessionConfigured)); sessionRunning=\(yesNo(multiCam.sessionRunning)); previews=broadcast \(yesNo(multiCam.broadcastPreviewAttached)) / ocr \(yesNo(multiCam.ocrPreviewAttached)); failureLatched=\(yesNo(multiCam.failureLatched)); failure=\(multiCam.failureText); status=\(multiCam.statusText); pair=\(multiCam.devicePairText); graph={\(multiCam.graphText)}; frames=live \(multiCam.liveFramesReceived) / ocr \(multiCam.ocrFramesReceived); callbackAge=live \(multiCam.liveLastCallbackAgeSeconds.map { String(format: "%.2fs", $0) } ?? "--") / ocr \(multiCam.ocrLastCallbackAgeSeconds.map { String(format: "%.2fs", $0) } ?? "--"); connections={\(multiCam.liveOutputConnectionText)} / {\(multiCam.ocrOutputConnectionText)}; deadBranchRecovery=\(multiCam.ocrDeadBranchRecoveryCount)/failures=\(multiCam.ocrDeadBranchRecoveryFailureCount) last={\(multiCam.lastDeadBranchRecoveryText)}; requiredFrames=\(yesNo(multiCam.hasRequiredFirstFrames)); cost=\(String(format: "%.2f", multiCam.hardwareCost))/\(String(format: "%.2f", multiCam.systemPressureCost)); revision=\(multiCam.revision); interruption=\(multiCam.lastInterruptionText)",
                passive: "One queue-confined AVCaptureMultiCamSession owner with persistent Broadcast and OCR preview endpoints",
                note: "UX16c35 is the only runtime capture owner and supports dual-camera, Broadcast-only and OCR-only graphs"
            ),
            settingLine(
                area: "Camera",
                name: "FrameHub latest-frame exchange",
                active: RinkLensFrameHub.shared.diagnosticSnapshot().diagnosticText,
                passive: "Capacity one per role: Broadcast and OCR; newest frame replaces previous frame",
                note: "UX16c32 gives recording, Test OCR and diagnostics one bounded latest-frame source without queueing camera callbacks"
            ),
            settingLine(
                area: "Camera",
                name: "Camera lifecycle policy",
                active: "Single CaptureEngine owner; authoritative mode=\(multiCam.captureModeText); desiredRevision=\(viewModel.captureLifecycleController.desiredContractRevision); reconciliations=\(viewModel.captureLifecycleController.reconciliationExecutionCount); coalesced=\(viewModel.captureLifecycleController.coalescedRequestCount); identicalSuppressed=\(viewModel.captureLifecycleController.identicalContractSuppressionCount); healthObservations=\(viewModel.captureLifecycleController.healthObservationCount); healthSuppressed=\(viewModel.captureLifecycleController.healthObservationSuppressionCount); sustainedHealthReconciliations=\(viewModel.captureLifecycleController.sustainedHealthReconciliationCount); deadBranchOCRReconnects=\(viewModel.captureLifecycleController.deadBranchOCRReconnectCount); deadBranchGraphRebuilds=\(viewModel.captureLifecycleController.deadBranchGraphRebuildCount); deadBranchSuppressed=\(viewModel.captureLifecycleController.deadBranchRecoverySuppressionCount); deadBranchLast={\(viewModel.captureLifecycleController.lastDeadBranchRecoveryText)}; routeActivations=\(viewModel.routeLifecycleActivationCount); duplicateRouteSuppressed=\(viewModel.duplicateRouteLifecycleSuppressionCount); abandoned=\(viewModel.captureLifecycleController.abandonedRequestCount); atomicReconfigurations=\(viewModel.captureLifecycleController.atomicReconfigurationCount); leaseDeferred=\(viewModel.captureLifecycleController.recordingLeaseDeferredRequestCount); leaseReleaseReconciled=\(viewModel.captureLifecycleController.recordingLeaseReplayCount); deferredRequest={\(viewModel.captureLifecycleController.deferredRecordingLeaseRequestDiagnosticText)}; desired={\(viewModel.captureLifecycleController.desiredContractDiagnosticText)}; effective={\(viewModel.captureLifecycleController.effectiveContractDiagnosticText)}",
                passive: "Broadcast+OCR=dual-camera; Broadcast-only; OCR-only; stopped",
                note: "UX16c42 owns one DesiredCaptureContract, suppresses identical reconciliation and validates Apple-resolved physical constituents"
            ),
            settingLine(
                area: "Camera",
                name: "External camera reconnect",
                active: ocrCameraService.externalReconnectStatusText,
                passive: "Stable, disconnected, CaptureEngine degradation, reconnect pending, or recovered",
                note: "UX16c35 delegates external-device disconnect/reconnect and graph degradation exclusively to CaptureEngine"
            ),
            settingLine(
                area: "Camera",
                name: "First-frame luminance",
                active: "broadcast={\(multiCam.liveFirstFrameLumaText)}; ocr={\(multiCam.ocrFirstFrameLumaText)}",
                passive: "Sampled Y-plane average/min/max after each camera reconfiguration",
                note: "Distinguishes a healthy non-black external stream from a structurally running but black camera feed"
            ),
            settingLine(
                area: "Camera",
                name: "SwiftUI publication thread",
                active: ocrCameraService.cameraUIPublicationThreadText,
                passive: "AVFoundation work on serial camera queue; ObservableObject/UI publications on main thread",
                note: "UX16c16 prevents camera queue publications from invoking UIView/SwiftUI updates off-main"
            ),
            settingLine(
                area: "Camera",
                name: "OCR frame handoff thread",
                active: viewModel.ocrFrameHandoffStatusText,
                passive: "AVCapture delegate queue -> DispatchQueue.main -> scoreboard/OCR model",
                note: "UX16c32 commits each OCR sample to the bounded FrameHub before the existing main-thread OCR compatibility callback"
            ),
            settingLine(
                area: "Camera",
                name: "OCR camera manual mode",
                active: enabledDisabled(calibrationProfile.manualCalibrationModeEnabled),
                passive: "Match Broadcast Camera, manual locked OCR profile",
                note: "Manual OCR camera settings are editable only in manual OCR mode"
            ),
            settingLine(
                area: "Camera",
                name: "OCR camera requested locks",
                active: calibrationProfile.lockSummary,
                passive: "Zoom, focus, exposure, white balance, ISO and shutter-speed requests",
                note: "Saved request intent; unsupported controls may be rejected by HockeyCameraService"
            ),
            settingLine(
                area: "Camera",
                name: "Zoom",
                active: "broadcast=\(format(viewModel.liveCameraZoomFactor)) ocr=\(format(viewModel.cameraZoomFactor)) locked=\(yesNo(calibrationProfile.zoomLocked)) value=\(format(CGFloat(calibrationProfile.lockedZoomValue)))",
                passive: "Adjustable where supported",
                note: "Zoom changes can affect zone alignment"
            ),
            settingLine(
                area: "Camera",
                name: "OCR camera hardware acknowledgement",
                active: ocrCameraService.appliedCameraControlAcknowledgementText,
                passive: "Active or last-acknowledged physical focus, exposure, white balance and zoom state",
                note: "Derived only from HockeyCameraService hardware truth; rejected requests are not reported as applied"
            ),
            settingLine(
                area: "Camera",
                name: "OCR camera resolution / frame rate",
                active: "ocrPreviewFormat=\(calibrationFormatText) fps=\(calibrationFrameRateText)",
                passive: "Device-supported formats",
                note: "This is the OCR camera format. Recording format is reported separately under 60FPS CAPTURE VALIDATION"
            ),
            settingLine(
                area: "Camera",
                name: "Preview rotations",
                active: "broadcast=\(Int(viewModel.livePreviewRotationOffsetDegrees.rounded()))deg ocr=\(Int(viewModel.ocrPreviewRotationOffsetDegrees.rounded()))deg lock=\(enabledDisabled(viewModel.cameraRotationLockEnabled))",
                passive: "0, 90, 180, 270 degrees plus rotation lock",
                note: "Important for OCR and exported clip orientation"
            ),
            settingLine(
                area: "Camera",
                name: "Smooth broadcast zoom",
                active: "\(enabledDisabled(viewModel.smoothBroadcastZoomTransitionsEnabled)); speed=\(viewModel.broadcastZoomTransitionSpeed.label)",
                passive: "Enabled, disabled, selectable transition speeds",
                note: "One elapsed-time trajectory covers 0.5x–5x. When the USB MultiCam pair cannot retain a virtual rear camera, one physical Ultra Wide input remains installed and values above 0.5x use digital crop at its verified cadence"
            )
        ]

        lines += [
            settingLine(
                area: "Calibration zones",
                name: "Selected zone",
                active: selectedZoneText,
                passive: "All configured OCR zones and grouped zone templates",
                note: "Current live coordinates at export time"
            ),
            settingLine(
                area: "OCR",
                name: "OCR colour profiles",
                active: viewModel.ocrColourProfiles.compactSummary,
                passive: "Auto, Red on Black, Yellow/White on Black, Amber/Orange, Green, Blue/Cyan, Light on Dark, Dark on Light, Greyscale",
                note: "UX14t per-rink/per-zone colour pipeline settings saved with rink templates"
            ),
            settingLine(
                area: "Scoreboard input",
                name: "Operating mode",
                active: viewModel.operatingMode.title,
                passive: "OCR Mode, Image Relay, Manual Mode",
                note: "Image Relay keeps Clock and penalty timers as fixed physical images. A separate metadata lane validates raw Clock values, Score, Period and penalty-player numbers for popups and timeline entries without changing relay images, timer activation or MatchState; player disappearance, not 0:00, closes penalty spans"
            ),
            settingLine(
                area: "OCR",
                name: "OCR running",
                active: "status=\(viewModel.ocrOperationalStatusText); effective=\(yesNo(viewModel.isOCREffectiveRunning)) paused=\(yesNo(viewModel.isOCRPaused)) interval=\(String(format: "%.2f", viewModel.ocrIntervalSeconds))s",
                passive: "Start, stop, pause, interval tuning",
                note: "Captures whether OCR was active or intentionally paused"
            ),
            settingLine(
                area: "OCR",
                name: "OCR smoothing",
                active: enabledDisabled(viewModel.isPostOCRSmoothingEnabled),
                passive: "Enabled, disabled",
                note: "Can affect accepted values versus raw OCR"
            ),
            settingLine(
                area: "OCR",
                name: "Smart change detection",
                active: enabledDisabled(viewModel.smartChangeDetectionEnabled),
                passive: "Enabled, disabled",
                note: "Controls whether OCR work is skipped when pixels are unchanged"
            ),
            settingLine(
                area: "OCR",
                name: "Pixel hashing",
                active: viewModel.pixelHashingStatusText,
                passive: "Inactive, active during stopped-clock or event windows",
                note: "Shows whether smart-change hashing is currently part of OCR gating"
            ),
            settingLine(
                area: "OCR",
                name: "Segmented fallback",
                active: enabledDisabled(viewModel.enableSegmentedFallback),
                passive: "Enabled, disabled",
                note: "Fallback OCR behaviour for difficult scoreboard regions"
            ),
            settingLine(
                area: "OCR",
                name: "OCR assist",
                active: "\(enabledDisabled(viewModel.autoOCRAssistEnabled)); \(viewModel.ocrAssistStatusText)",
                passive: "Enabled, disabled, profile-dependent assist",
                note: "Shows current assist state and scheduler gating"
            ),
            settingLine(
                area: "OCR",
                name: "Reading presets",
                active: "clock=\(viewModel.clockReadingPreset.title) score=\(viewModel.scoreReadingPreset.title) penalty=\(viewModel.penaltyReadingPreset.title)",
                passive: "Selectable OCR reading presets",
                note: "Useful when a field reads differently under rink lighting"
            ),
            settingLine(
                area: "OCR",
                name: "Motion protection",
                active: viewModel.ocrMotionProtectionStatusText,
                passive: "Runtime protection state",
                note: "OCR may pause after camera movement"
            ),
            settingLine(
                area: "Scoreboard",
                name: "Manual override",
                active: enabledDisabled(viewModel.manualOverrideEnabled),
                passive: "Enabled, disabled",
                note: "Shows whether operator values may override OCR"
            ),
            settingLine(
                area: "Scoreboard",
                name: "Unified MatchState reducer",
                active: viewModel.matchStateReducerDiagnosticText,
                passive: "Typed OCR, manual, reset, period, score, penalty and local-clock actions",
                note: "UX16c34 makes the ViewModel the only commit point for accepted ScoreboardState and preserves existing event, penalty and overlay side effects after reduction"
            ),
            settingLine(
                area: "Scoreboard",
                name: "Game clock direction",
                active: "\(String(describing: viewModel.gameClockDirection)); \(viewModel.trustedClockAuthorityStatusText)",
                passive: "Selectable clock direction",
                note: "UX16d10 reports the physical-board clock authority, bounded single-source/reanchor evidence, last trusted-read age and latest accept/hold decision"
            ),
            settingLine(
                area: "Performance",
                name: "Performance safe mode",
                active: enabledDisabled(viewModel.performanceSafeModeEnabled),
                passive: "Enabled, disabled",
                note: "Reduces optional runtime work under load"
            )
        ]

        return lines
    }

    private func deviceNameText() -> String {
        #if canImport(UIKit)
        let device = UIDevice.current
        return "\(device.name) | \(device.model) | \(device.localizedModel)"
        #else
        return Host.current().localizedName ?? "Unknown device"
        #endif
    }

    private func deviceMakeText() -> String {
        #if canImport(UIKit)
        return "Apple"
        #else
        return "Unknown"
        #endif
    }

    private func hardwareModelIdentifierText() -> String {
        #if canImport(Darwin)
        var systemInfo = utsname()
        uname(&systemInfo)

        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { result, child in
            guard let value = child.value as? Int8, value != 0 else { return }
            result.append(String(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? "unknown" : identifier
        #else
        return "unavailable"
        #endif
    }

    private func batteryLines() -> [String] {
        #if canImport(UIKit)
        let device = UIDevice.current
        let wasMonitoring = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        defer { device.isBatteryMonitoringEnabled = wasMonitoring }

        let levelText = device.batteryLevel >= 0
            ? "\(Int((device.batteryLevel * 100).rounded()))%"
            : "unknown"

        return [
            "Battery level: \(levelText)",
            "Battery state: \(batteryStateText(device.batteryState))"
        ]
        #else
        return [
            "Battery level: unavailable",
            "Battery state: unavailable"
        ]
        #endif
    }

    #if canImport(UIKit)
    private func batteryStateText(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .unknown:
            return "unknown"
        case .unplugged:
            return "unplugged"
        case .charging:
            return "charging"
        case .full:
            return "full"
        @unknown default:
            return "unknown"
        }
    }
    #endif

    private func thermalStateText(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:
            return "nominal"
        case .fair:
            return "fair"
        case .serious:
            return "serious"
        case .critical:
            return "critical"
        @unknown default:
            return "unknown"
        }
    }

    private func memorySnapshot(processInfo: ProcessInfo) -> (physicalBytes: UInt64?, appFootprintBytes: UInt64?) {
        (processInfo.physicalMemory, appMemoryFootprintBytes())
    }

    private func appMemoryFootprintBytes() -> UInt64? {
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

    private func diskCapacitySnapshot() -> (totalBytes: UInt64?, freeBytes: UInt64?) {
        do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            let total = attributes[.systemSize] as? NSNumber
            let free = attributes[.systemFreeSize] as? NSNumber
            return (total?.uint64Value, free?.uint64Value)
        } catch {
            return (nil, nil)
        }
    }

    private func cameraLines(viewModel: HockeyScoreboardViewModel, service: HockeyCameraService, now: Date) -> [String] {
        let capture = viewModel.externalOCRMultiCamCoordinator.snapshot
        let role: RinkLensFrameRole = service === viewModel.liveCameraService ? .broadcast : .ocr
        let roleRequired = role == .broadcast ? capture.activeMode.requiresBroadcast : capture.activeMode.requiresOCR
        let requiredDeviceID = role == .broadcast ? capture.liveDeviceID : capture.ocrDeviceID
        let frame = RinkLensFrameHub.shared.latestFrame(
            for: role,
            maxAge: 1.5,
            requiredCaptureGeneration: capture.transitionGeneration,
            requiredPhysicalDeviceID: requiredDeviceID
        )
        let endpointAttached = role == .broadcast ? capture.broadcastPreviewAttached : capture.ocrPreviewAttached
        let truthfulRunning = capture.isActive && capture.sessionRunning && roleRequired && requiredDeviceID != nil
        let truthfulFrames = truthfulRunning && frame != nil

        return [
            "Diagnostics updating: \(truthfulRunning ? "Yes - CaptureEngine active" : "No - CaptureEngine role inactive")",
            "Capture role: \(role.rawValue)",
            "Capture mode / phase: \(capture.captureModeText) / \(capture.phase.rawValue)",
            "Running: \(yesNo(truthfulRunning))",
            "Frames: \(truthfulFrames ? "fresh / generation and device verified" : "waiting or stale")",
            "Active physical device: \(requiredDeviceID ?? "none")",
            "Capture generation: \(capture.transitionGeneration)",
            "Preview endpoint attached: \(yesNo(endpointAttached))",
            "CaptureEngine graph: \(capture.graphText)",
            "CaptureEngine status: \(capture.statusText)",
            "Facade logical source: \(service.selectedCameraID ?? "none")",
            "Facade staged physical device: \(service.resolvedCameraDeviceID ?? "none")",
            "Facade selected exact profile: \(service.selectedCapabilityProfileID ?? "automatic")",
            "Facade last frame time: \(service.lastFrameReceivedAt.map { Self.displayTimestampFormatter.string(from: $0) } ?? "--")",
            "Facade last frame age: \(service.lastFrameAgeText(now: now))",
            "Frame pipeline: \(service.framePipelineText)",
            "FrameHub latest slot: \(RinkLensFrameHub.shared.diagnosticText(for: role, now: now))",
            "FrameHub all roles: \(RinkLensFrameHub.shared.diagnosticSnapshot(now: now).diagnosticText)",
            "Available exact profiles: \(service.capabilityProfiles.count)",
            "Authorization: \(service.cameraAuthorizationStatusText)",
            "White-screen detector: \(service.whiteScreenDetectorText)"
        ]
    }

    private func renderPacerLines(_ pacer: BroadcastRenderPacerDiagnostics) -> [String] {
        [
            "Render pacer source: \(pacer.renderPacerSourceText)",
            "Target tick interval: \(pacer.targetTickIntervalText)",
            "Actual tick interval: \(pacer.actualTickIntervalText)",
            "Source-clock drift: \(pacer.sourceClockDriftText)",
            "Late tick count: \(pacer.lateTickCountText)",
            "Late tick reason: \(pacer.lateTickReasonText)",
            "Last skipped tick reason: \(pacer.skippedTickReasonText)",
            "Dropped/merged render ticks: \(pacer.droppedOrMergedRenderTicksText)",
            "Main actor wait time: \(pacer.mainActorWaitText)",
            "Frame input wait time: \(pacer.frameInputWaitText)",
            "Writer wait time: \(pacer.writerWaitText)",
            "Pacer starvation count: \(pacer.starvationCountText)",
            "Pacer summary: \(pacer.lastTickSummaryText)",
            "SourceClock starvation guard: \(BroadcastRecordingSourceClockStarvationGuard.shared.diagnosticSummaryText())",
            "Overlay MainActor lockout: \(BroadcastRecordingOverlayCache.shared.recordingLockoutDiagnosticText())"
        ]
    }

    private func captureValidationLines(_ validation: RecordingCameraFormatValidationDiagnostics, recorder: BroadcastRecordingManager) -> [String] {
        [
            "Requested recording profile: \(validation.requestedRecordingProfileText)",
            "Selected recording profile: \(RinkLensRiskFeaturePolicy.isEnabled(.customRecordingOutputProfileV15) ? recorder.recordingOutputPolicySummaryText : recorder.recordingProfile.label)",
            "Recording camera format: \(validation.activeCameraFormatText)",
            "OCR camera format: see CAMERA / PREVIEW section",
            "60fps capable: \(validation.is60FPSCapableText)",
            "Preflight result: \(validation.preflightResultText)",
            "Block reason: \(validation.blockReasonText)",
            "Last checked: \(validation.lastCheckedText)"
        ]
    }

    private func diagnosticsSuppressionLines(
        monitor: MainThreadStallMonitor,
        recorder: BroadcastRecordingManager,
        cameraService: HockeyCameraService,
        viewModel: HockeyScoreboardViewModel
    ) -> [String] {
        let isRecording = recorder.isRecording
        return [
            "Recording active: \(yesNo(isRecording))",
            "Operator diagnostics paused: \(yesNo(isRecording))",
            "Preview heartbeat paused/throttled: \(isRecording ? "Yes - recording-safe throttled" : "No")",
            "Camera diagnostics publishing: \(isRecording ? "Paused/hidden" : "Visible only when page selected")",
            "OCR diagnostics paused: \(yesNo(isRecording || !viewModel.isOCREffectiveRunning))",
            "Export mode: \(isRecording ? "Recording-safe" : "Full engineering available")",
            "Diagnostics mode: \(monitor.diagnosticsModeText)"
        ]
    }

    private func recordingLines(
        recorder: BroadcastRecordingManager,
        renderer: PersistentBroadcastRendererDiagnostics,
        pacer: BroadcastRenderPacerDiagnostics
    ) -> [String] {
        [
            "Writer state: \(recorder.state.rawValue)",
            "Elapsed: \(recorder.elapsedText)",
            "Source: \(recorder.recordingSourceText)",
            "Renderer stage: \(BroadcastProductionDiagnosticLabelsV2.rendererStage(BroadcastRecordingRendererPathDiagnostics.shared.activeStageText))",
            "Writer path: \(BroadcastProductionDiagnosticLabelsV2.writerPath(BroadcastRecordingRendererPathDiagnostics.shared.writerPathText))",
            "Frame provider path: \(BroadcastProductionDiagnosticLabelsV2.frameProviderPath(BroadcastRecordingRendererPathDiagnostics.shared.frameProviderPathText))",
            "Renderer path: \(BroadcastProductionDiagnosticLabelsV2.rendererPath(BroadcastRecordingRendererPathDiagnostics.shared.rendererPathText))",
            "PixelBuffer path: \(BroadcastProductionDiagnosticLabelsV2.pixelBufferPath(BroadcastRecordingRendererPathDiagnostics.shared.pixelBufferPathText))",
            "Overlay path: \(BroadcastProductionDiagnosticLabelsV2.overlayPath(BroadcastRecordingRendererPathDiagnostics.shared.overlayPathText))",
            "PixelBuffer flags: \(BroadcastProductionDiagnosticLabelsV2.featureFlags(BroadcastRecordingRendererPathDiagnostics.shared.featureFlagText))",
            "PixelBuffer fallback: \(BroadcastProductionDiagnosticLabelsV2.fallbackReason(BroadcastRecordingRendererPathDiagnostics.shared.fallbackReasonText))",
            "Render loop: \(recorder.renderLoopModeText)",
            "Current file: \(recorder.currentRecordingURL?.lastPathComponent ?? "--")",
            "Last error: \(recorder.lastErrorMessage ?? "none")",
            "Frames written: \(recorder.framesWritten)",
            "Frames dropped total: \(recorder.framesDropped)",
            "Source unavailable ticks: \(recorder.cameraSourceDrops)",
            "Source sampling duplicates: \(recorder.sourceSamplingMisses)",
            "Writer/encoder drops: \(recorder.writerDrops)",
            "Render/compositor drops: \(recorder.renderDrops)",
            "Black candidates detected: \(recorder.recordingBlackFrameDetectedCount)",
            "Black candidates held: \(recorder.recordingBlackFrameCount)",
            "Black candidates continuity-accepted: \(recorder.recordingBlackFrameContinuityAcceptedCount)",
            "Recording health: \(recorder.recordingHealthText)",
            "Recording capture lease: \(recorder.recordingCaptureLeaseText)",
            "Recording stop origin: \(recorder.recordingStopOriginText)",
            "Recording lease blocked lifecycle requests: \(RinkLensRecordingCaptureLease.shared.diagnostics().count); last=\(RinkLensRecordingCaptureLease.shared.diagnostics().last)",
            "Last frame age: \(recorder.lastFrameAgeText)",
            "Target resolution: \(recorder.recordingTargetResolutionText)",
            "Target FPS: \(recorder.recordingTargetFPSText)",
            "Output FPS: \(recorder.recordingActualFPSText)",
            "Source FPS: \(recorder.recordingSourceActualFPSText)",
            "Cadence ratio: \(recorder.recordingCadenceRatioText)",
            "Recording source delivery: \(recorder.recordingPollingFPSText)",
            "FPS warning: \(recorder.recordingFPSWarningText)",
            "Encoder backlog: \(recorder.recordingEncoderBacklogText)",
            "Renderer mode: \(renderer.renderMode)",
            "Renderer target: \(rendererTargetDisplayText(renderer, recorder: recorder))",
            "Renderer actual: \(renderer.actualFPS)",
            "Render time: \(renderer.lastRenderTimeMs)",
            "Output frames dropped: \(recorder.framesDropped)",
            "Renderer late/merged ticks: \(renderer.renderDrops)",
            "Pacer source: \(pacer.renderPacerSourceText)",
            "Pacer target tick interval: \(pacer.targetTickIntervalText)",
            "Pacer tick interval: \(pacer.actualTickIntervalText)",
            "Pacer source-clock drift: \(pacer.sourceClockDriftText)",
            "Pacer late tick count: \(pacer.lateTickCountText)",
            "Pacer late tick reason: \(pacer.lateTickReasonText)",
            "Pacer skipped tick: \(pacer.skippedTickReasonText)",
            "Pacer dropped/merged ticks: \(pacer.droppedOrMergedRenderTicksText)",
            "Pacer main actor wait: \(pacer.mainActorWaitText)",
            "Pacer frame input wait: \(pacer.frameInputWaitText)",
            "Pacer writer wait: \(pacer.writerWaitText)",
            "Pacer starvation count: \(pacer.starvationCountText)",
            "Pacer summary: \(pacer.lastTickSummaryText)",
            "SourceClock starvation guard: \(BroadcastRecordingSourceClockStarvationGuard.shared.diagnosticSummaryText())",
            "Overlay MainActor lockout: \(BroadcastRecordingOverlayCache.shared.recordingLockoutDiagnosticText())",
            "Manual clip state: \(recorder.manualClipExportStateText)",
            "Manual clip feedback: \(recorder.manualClipFeedbackText)",
            "Rotation: \(recorder.recordingRotationText)",
            "Transform: \(recorder.recordingTransformSourceText)",
            "Raw frame: \(recorder.recordingRawFrameCorrectionText)",
            "Black frames rejected: \(recorder.recordingBlackFrameCount)",
            "First valid frame: \(recorder.recordingFirstValidFrameText)",
            "Last written frame: \(recorder.recordingLastWrittenFrameText)",
            "Frame validation: \(recorder.recordingFrameValidationText)",
            "Last debug message: \(recorder.lastDebugMessage)"
        ]
    }

    private func clipBufferLines(_ clipBuffer: ClipBufferManager) -> [String] {
        [
            "Active: \(yesNo(clipBuffer.isActive))",
            "Status: \(clipBuffer.clipStatusText)",
            "Clip buffer path: \(clipBufferPathDisplayText(clipBuffer))",
            "Buffered duration: \(clipBuffer.bufferDurationText)",
            "Rollover warnings suppressed from UI: \(clipBuffer.rolloverTelemetrySuppressedFromUIText)",
            "Last rollover duration/warning: \(clipBuffer.lastRolloverTelemetryText)",
            "Export-visible warning only: Yes",
            "Writer queue mode: \(clipBuffer.clipWriterQueueModeText)",
            "Writer main-path suppression active: \(clipBuffer.clipWriterMainPathSuppressedText)",
            "Clip frame mailbox: \(clipBuffer.clipFrameMailboxText)",
            "Last background writer event: \(clipBuffer.lastClipWriterBackgroundEventText)",
            "Clip export requested duration: \(clipBuffer.lastClipExportRequestedDurationText)",
            "Clip export resolved duration: \(clipBuffer.lastClipExportResolvedDurationText)",
            "Clip export start/end source: \(clipBuffer.lastClipExportWindowText)",
            "Clip export source detail: \(clipBuffer.lastClipExportSourceText)",
            "Clip export outcome: \(clipExportOutcomeText(clipBuffer.lastClipExportFailureReasonText))",
            "Startup media cleanup: \(RinkLensStartupMediaCleanup.shared.summaryText)",
            "Startup media cleanup detail: \(RinkLensStartupMediaCleanup.shared.detailText)",
            "Last diagnostic: \(clipBuffer.lastDiagnosticText)"
        ]
    }



    private func clipExportOutcomeText(_ reason: String) -> String {
        switch reason {
        case "none":
            return "none"
        case "startOfRecording":
            return "expected partial: saved from recording start because requested pre-roll was not available"
        case "recordingStoppedBeforePostRoll":
            return "expected partial: recording stopped before full post-roll was available"
        default:
            return "condition: \(reason)"
        }
    }

    private func blackFrameRejectionLines(_ trace: BlackFrameRejectionTraceStore) -> [String] {
        [
            "Brightness-caused rejections: \(trace.totalRejectedText) (Recovery F expected 0)",
            "Very-dark frames observed: \(trace.darkObservedText)",
            "Very-dark frames encoded: \(trace.darkEncodedText)",
            "Consecutive source-frame rejections: \(trace.consecutiveRejectedText)",
            "Last decision: \(trace.lastReasonText)",
            "Last frame quality: \(trace.lastFrameQualityText)",
            "Last rejection at: \(trace.lastRejectedAtText)",
            "First fresh source frame seen: \(trace.firstValidFrameSeenText)",
            "Source: \(trace.likelySourceText)"
        ]
    }

    private func ocrLines(viewModel: HockeyScoreboardViewModel) -> [String] {
        let key = viewModel.selectedRegionKey
        let region = viewModel.ocrLayout[key]
        let selectedZoneText = "\(key.likelyTitle) x=\(format(region.x)) y=\(format(region.y)) w=\(format(region.width)) h=\(format(region.height))"

        var lines = [
            "Scoreboard input mode: \(viewModel.operatingMode.title)",
            "Image Relay status: \(viewModel.imageRelayStatusText)",
            "Image Relay detail: \(viewModel.imageRelayDiagnosticText)",
            "OCR runtime status: \(viewModel.ocrOperationalStatusText)",
            "OCR orchestration: \(viewModel.ocrOrchestrationDiagnosticText)",
            "OCR publication flow: \(viewModel.ocrDiagnostics.lastPublicationFlowText)",
            "OCR publication summary: \(viewModel.ocrDiagnostics.lastPublicationSummary)",
            "UX16d14 persistent live-pass ring: \(viewModel.ux16d14PersistentLivePassDiagnosticText)",
            "UX16d15 operator-confirmed static baselines: \(viewModel.ux16d15OperatorConfirmedBaselineDiagnosticText)",
            "Test OCR outcome: \(viewModel.testOCROutcomeText)",
            "Test OCR apply pending: \(viewModel.pendingTestOCRApplyDescription ?? "none")",
            "Selected zone: \(selectedZoneText)",
            "OCR effective running: \(yesNo(viewModel.isOCREffectiveRunning))",
            "OCR paused: \(yesNo(viewModel.isOCRPaused))",
            "OCR interval: \(String(format: "%.2f", viewModel.ocrIntervalSeconds))s",
            "OCR smoothing: \(viewModel.isPostOCRSmoothingEnabled ? "Enabled" : "Disabled")",
            "Smart change detection: \(viewModel.smartChangeDetectionEnabled ? "Enabled" : "Disabled")",
            "Pixel hashing: \(viewModel.ocrDiagnostics.ocrPixelHashingStatusText)",
            "Hashing detail: \(viewModel.ocrDiagnostics.ocrPixelHashingDetailText)",
            "Smart change skips: \(viewModel.smartChangeSkippedOCRFrames)",
            "Last smart decision: \(viewModel.smartChangeLastDecisionText)",
            "Selected crop/Test OCR status: \(viewModel.selectedRegionPreviewStatus)",
            "OCR assist: \(viewModel.ocrAssistStatusText)",
            "Motion protection: \(viewModel.ocrMotionProtectionStatusText)"
        ]
        let fieldLines = viewModel.ocrDiagnostics.orderedFieldPublicationDiagnostics.map {
            "Field \($0.key.rawValue): \($0.compactText)"
        }
        lines.append(contentsOf: fieldLines.isEmpty ? ["Field publication diagnostics: none"] : fieldLines)
        return lines
    }

    private func matchStateReducerLines(viewModel: HockeyScoreboardViewModel) -> [String] {
        let state = viewModel.state
        return [
            "Revision: \(viewModel.matchStateRevision)",
            "Last action: \(viewModel.lastMatchStateActionText)",
            "Accepted clock: \(state.clock ?? "--")",
            "Accepted score: \(state.homeScore.map { String($0) } ?? "--")-\(state.awayScore.map { String($0) } ?? "--")",
            "Accepted period: \(state.periodLabel ?? state.period.map { String($0) } ?? "--")",
            "Manual protection: \(viewModel.manualScoreController.diagnosticsSummary())",
            "Event boundary: score, penalty and period side effects run only after a committed reducer transition",
            "Single writer invariant: HockeyScoreboardViewModel.reduceMatchState is the only accepted ScoreboardState setter"
        ]
    }

    private func broadcastViewLines(
        viewModel: HockeyScoreboardViewModel,
        recorder: BroadcastRecordingManager,
        renderer: PersistentBroadcastRendererDiagnostics,
        activeRoute: AppRoute
    ) -> [String] {
        [
            "Active NextGen route: \(activeRoute.title)",
            "Last scoreboard screen snapshot: \(viewModel.currentScreen.rawValue)",
            "Snapshot note: Broadcast state is retained for diagnostics; active route controls whether preview should be attached.",
            "Recording state: \(recorder.state.rawValue)",
            "Recording file: \(recorder.currentRecordingURL?.lastPathComponent ?? "--")",
            "Recording source: \(recorder.recordingSourceText)",
            "Renderer stage: \(BroadcastProductionDiagnosticLabelsV2.rendererStage(BroadcastRecordingRendererPathDiagnostics.shared.activeStageText))",
            "Writer path: \(BroadcastProductionDiagnosticLabelsV2.writerPath(BroadcastRecordingRendererPathDiagnostics.shared.writerPathText))",
            "Renderer path: \(BroadcastProductionDiagnosticLabelsV2.rendererPath(BroadcastRecordingRendererPathDiagnostics.shared.rendererPathText))",
            "PixelBuffer path: \(BroadcastProductionDiagnosticLabelsV2.pixelBufferPath(BroadcastRecordingRendererPathDiagnostics.shared.pixelBufferPathText))",
            "Target quality: \(recorder.recordingTargetResolutionText) / \(recorder.recordingTargetFPSText)",
            "Output FPS: \(recorder.recordingActualFPSText)",
            "Source FPS: \(recorder.recordingSourceActualFPSText)",
            "Cadence ratio: \(recorder.recordingCadenceRatioText)",
            "Recording source delivery: \(recorder.recordingPollingFPSText)",
            "FPS warning: \(recorder.recordingFPSWarningText)",
            "Encoder backlog: \(recorder.recordingEncoderBacklogText)",
            "Frames written: \(recorder.framesWritten)",
            "Frames dropped total: \(recorder.framesDropped)",
            "Source unavailable ticks: \(recorder.cameraSourceDrops)",
            "Source sampling duplicates: \(recorder.sourceSamplingMisses)",
            "Writer/encoder drops: \(recorder.writerDrops)",
            "Render/compositor drops: \(recorder.renderDrops)",
            "Black candidates detected: \(recorder.recordingBlackFrameDetectedCount)",
            "Black candidates held: \(recorder.recordingBlackFrameCount)",
            "Black candidates continuity-accepted: \(recorder.recordingBlackFrameContinuityAcceptedCount)",
            "Recording health: \(recorder.recordingHealthText)",
            "Recording capture lease: \(recorder.recordingCaptureLeaseText)",
            "Recording stop origin: \(recorder.recordingStopOriginText)",
            "Recording lease blocked lifecycle requests: \(RinkLensRecordingCaptureLease.shared.diagnostics().count); last=\(RinkLensRecordingCaptureLease.shared.diagnostics().last)",
            "Renderer mode: \(renderer.renderMode)",
            "Renderer target: \(rendererTargetDisplayText(renderer, recorder: recorder))",
            "Renderer actual: \(renderer.actualFPS)",
            "Output frames dropped: \(recorder.framesDropped)",
            "Renderer late/merged ticks: \(renderer.renderDrops)",
            "Manual clip state: \(recorder.manualClipExportStateText)",
            "Manual clip feedback: \(recorder.manualClipFeedbackText)",
            "Broadcast preview rotation: \(Int(viewModel.livePreviewRotationOffsetDegrees.rounded())) deg",
            "Active broadcast banner: \(viewModel.activeBroadcastBanner.map { String(describing: $0) } ?? "none")",
            "Unified overlay queue: \(viewModel.broadcastOverlayQueueState.diagnosticSummary)",
            "Broadcast phase: \(viewModel.broadcastPhase.rawValue)",
            "Broadcast phase state: \(viewModel.broadcastPhaseState.diagnosticSummary)",
            "Broadcast phase transitions: \(viewModel.broadcastPhaseTransitionHistory.last?.diagnosticSummary ?? "none")",
            "Active intermission reel: \(viewModel.activeIntermissionReel.map { "P\($0.completedPeriod)->P\($0.nextPeriod) slides=\($0.sponsorSlides.count) source=\($0.triggeredBy.rawValue)" } ?? "none")",
            "Intermission countdown OCR: \(viewModel.broadcastPhaseState.shouldForceIntermissionCountdown ? "active; countdown=\(viewModel.intermissionCountdownText); actual time=iPad system clock" : "inactive")",
            "Intermission diagnostic: \(viewModel.lastIntermissionDiagnostic)"
        ]
    }

    private func calibrationViewLines(viewModel: HockeyScoreboardViewModel, cameraService: HockeyCameraService, activeRoute: AppRoute) -> [String] {
        let key = viewModel.selectedRegionKey
        let region = viewModel.ocrLayout[key]
        let selectedZoneText = "\(key.likelyTitle) x=\(format(region.x)) y=\(format(region.y)) w=\(format(region.width)) h=\(format(region.height))"
        let capture = viewModel.externalOCRMultiCamCoordinator.snapshot
        let freshOCRFrame = capture.activeMode.requiresOCR
            ? RinkLensFrameHub.shared.latestFrame(
                for: .ocr,
                maxAge: 1.5,
                requiredCaptureGeneration: capture.transitionGeneration,
                requiredPhysicalDeviceID: capture.ocrDeviceID
            )
            : nil

        return [
            "Active NextGen route: \(activeRoute.title)",
            "Last scoreboard screen snapshot: \(viewModel.currentScreen.rawValue)",
            "Snapshot note: CaptureEngine owns OCR hardware; FrameHub owns bounded OCR pixels; Calibration preview renders the same latest FrameHub OCR frame rather than an independent AVCapture preview connection.",
            "Selected zone: \(selectedZoneText)",
            "Scoreboard input mode: \(viewModel.operatingMode.title)",
            "Image Relay status: \(viewModel.imageRelayStatusText)",
            "Image Relay detail: \(viewModel.imageRelayDiagnosticText)",
            "OCR effective running: \(yesNo(viewModel.isOCREffectiveRunning))",
            "OCR paused: \(yesNo(viewModel.isOCRPaused))",
            "OCR interval: \(String(format: "%.2f", viewModel.ocrIntervalSeconds))s",
            "CaptureEngine mode / phase: \(capture.captureModeText) / \(capture.phase.rawValue)",
            "OCR branch running: \(yesNo(capture.isActive && capture.sessionRunning && capture.activeMode.requiresOCR))",
            "OCR fresh frame: \(yesNo(freshOCRFrame != nil))",
            "OCR active device: \(capture.ocrDeviceID ?? "none")",
            "OCR active format: \(capture.ocrFormatText)",
            "OCR visible preview authority: FrameHub latest-frame renderer",
            "OCR FrameHub preview: \(OCRFrameHubPreviewDiagnosticsStore.shared.exportText())",
            "Legacy CaptureEngine OCR preview endpoint attached: \(yesNo(capture.ocrPreviewAttached))",
            "Legacy facade preview expectation: \(cameraService.previewExpectationText)",
            "Motion protection: \(viewModel.ocrMotionProtectionStatusText)",
            "OCR assist: \(viewModel.ocrAssistStatusText)"
        ]
    }


    private func captureEngineResilienceLines(viewModel: HockeyScoreboardViewModel) -> [String] {
        let capture = viewModel.externalOCRMultiCamCoordinator.snapshot
        let degraded = capture.degradedRecord
        let mutationAudit = RinkLensCaptureGraphMutationAudit.shared.snapshot()
        return [
            "Mode / phase: \(capture.captureModeText) / \(capture.phase.rawValue)",
            "Persistent degraded record: \(degraded?.diagnosticText ?? "none")",
            "Operator retry available: \(yesNo(degraded != nil))",
            "Broadcast system pressure: level=\(capture.liveSystemPressureLevel) factors=\(capture.liveSystemPressureFactors)",
            "OCR system pressure: level=\(capture.ocrSystemPressureLevel) factors=\(capture.ocrSystemPressureFactors)",
            "OCR pressure policy: \(capture.ocrPressurePolicyState)",
            "OCR pressure delivery: suspended=\(yesNo(capture.ocrPressureSuspended)) maxFPS=\(capture.ocrPressureDeliveryFPS > 0 ? String(format: "%.2f", capture.ocrPressureDeliveryFPS) : "source")",
            "Broadcast preservation active: \(yesNo(capture.broadcastPreservationActive)) — live format and cadence are never automatically reduced",
            "Broadcast dropped frames generation \(capture.transitionGeneration): total=\(capture.liveDroppedFrames) late=\(capture.liveDroppedLateFrames) outOfBuffers=\(capture.liveDroppedOutOfBuffers) discontinuity=\(capture.liveDroppedDiscontinuityFrames); lifetime=\(capture.liveDroppedFramesLifetime)",
            "OCR dropped frames generation \(capture.transitionGeneration): total=\(capture.ocrDroppedFrames) late=\(capture.ocrDroppedLateFrames) outOfBuffers=\(capture.ocrDroppedOutOfBuffers) discontinuity=\(capture.ocrDroppedDiscontinuityFrames); lifetime=\(capture.ocrDroppedFramesLifetime)",
            String(format: "Video-output delegate residence: Broadcast %.2fms max %.2fms overBudget=%d; OCR %.2fms max %.2fms overBudget=%d", capture.liveCallbackLastMilliseconds, capture.liveCallbackMaxMilliseconds, capture.liveCallbackOverBudgetCount, capture.ocrCallbackLastMilliseconds, capture.ocrCallbackMaxMilliseconds, capture.ocrCallbackOverBudgetCount),
            "Last AVFoundation dropped frame: \(capture.lastDroppedFrameText)",
            "Graph mutation audit: liveDevice=\(mutationAudit.liveDeviceControlCount) liveCadence=\(mutationAudit.liveCadenceCount) noGraphChange=\(mutationAudit.noGraphChangeCount) fullRebuild=\(mutationAudit.fullGraphRebuildCount)",
            "Last graph mutation decision: \(mutationAudit.lastMutationText)",
            "Calculated graph cost: hardware=\(String(format: "%.3f", capture.hardwareCost)) pressure=\(String(format: "%.3f", capture.systemPressureCost))"
        ]
    }

    private func regressionTestLines(
        viewModel: HockeyScoreboardViewModel,
        recorder: BroadcastRecordingManager,
        renderer: PersistentBroadcastRendererDiagnostics,
        clipBuffer: ClipBufferManager,
        ownership: CameraOwnershipTraceStore,
        monitor: MainThreadStallMonitor
    ) -> [String] {
        let actualFPS = Double(
            recorder.recordingActualFPSText
                .lowercased()
                .replacingOccurrences(of: "fps", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let targetFPS = recorder.currentTargetFPSValue
        let minimumAcceptableFPS: Double = targetFPS >= 55 ? 55.0 : (targetFPS >= 29 ? 27.0 : Double(targetFPS) * 0.90)
        let fpsHealthy = actualFPS.map { $0 >= minimumAcceptableFPS } ?? false
        let backlogHealthy = recorder.recordingEncoderBacklogText == "0" || recorder.recordingEncoderBacklogText.lowercased().contains("none")
        let droppedFramesAcceptable = recorder.framesDropped <= 5
        let overlayQueueHealthy = !viewModel.broadcastOverlayQueueState.diagnosticSummary.lowercased().contains("stuck")
        let ocrRecoverable = viewModel.isOCREffectiveRunning || viewModel.manualOverrideEnabled
        let formatGuard = RecordingCameraFormatValidationDiagnostics.shared
        let capture = viewModel.externalOCRMultiCamCoordinator.snapshot
        let captureInvariantHealthy: Bool = {
            switch capture.phase {
            case .running:
                return capture.isActive
                    && capture.sessionConfigured
                    && capture.sessionRunning
                    && capture.hasRequiredFirstFrames
            case .stopped:
                return !capture.isActive && !capture.isTransitioning
            case .degraded:
                // A deliberate Broadcast-only degradation can remain active.
                return capture.isActive
                    ? capture.sessionConfigured && capture.sessionRunning && capture.hasRequiredFirstFrames
                    : !capture.isTransitioning
            case .failed:
                return !capture.isActive
            case .discoveringDevices, .configuring, .starting, .waitingForFrames, .stopping, .interrupted, .recovering:
                return true
            }
        }()

        return [
            "Camera ownership observed - authoritative CaptureEngine mode=\(capture.captureModeText) active=\(capture.isActive) transitioning=\(capture.isTransitioning) generation=\(capture.transitionGeneration)",
            "Capture-engine state invariant: \(captureInvariantHealthy ? "observed consistent" : "inconsistent") - \(capture.healthSummary)",
            "Persistent degraded contract: \(capture.degradedRecord == nil ? "none observed" : "present") - \(capture.degradedRecord?.diagnosticText ?? "none")",
            "AVFoundation drop diagnostics observed - Broadcast=\(capture.liveDroppedFrames) OCR=\(capture.ocrDroppedFrames) last=\(capture.lastDroppedFrameText)",
            "Live camera pressure diagnostics observed - Broadcast=\(capture.liveSystemPressureLevel) OCR=\(capture.ocrSystemPressureLevel) policy=\(capture.ocrPressurePolicyState)",
            "Broadcast preservation rule: \(capture.broadcastPreservationActive ? "active" : "not active") - Broadcast format/cadence unchanged; OCR-only degradation=\(capture.ocrPressurePolicyState)",
            "Graph optimisation: CHECK - \(RinkLensCaptureGraphMutationAudit.shared.snapshot().lastMutationText); full rebuilds=\(RinkLensCaptureGraphMutationAudit.shared.snapshot().fullGraphRebuildCount)",
            "Persistent CaptureEngine preview endpoints: \(capture.isActive ? "attached state observed" : "capture inactive") - mode=\(capture.captureModeText) broadcast=\(yesNo(capture.broadcastPreviewAttached)) ocr=\(yesNo(capture.ocrPreviewAttached)); route changes must not start a second session",
            "Legacy capture paths source assertion - private HockeyCameraService starts disabled; legacy Broadcast/OCR preview hosts removed; one AVCaptureMultiCamSession owner",
            "Broadcast preview route/snapshot configured - active route may hide preview without changing capture ownership",
            "OCR/manual recovery: \(ocrRecoverable ? "available" : "unavailable") - manual=\(yesNo(viewModel.manualOverrideEnabled)) ocrEffective=\(yesNo(viewModel.isOCREffectiveRunning))",
            "Unified MatchState reducer: \(viewModel.matchStateRevision > 0 ? "observed" : "not yet observed") - revision=\(viewModel.matchStateRevision) last={\(viewModel.lastMatchStateActionText)}",
            "OCR publication separation configured - continuous Broadcast OCR auto-commits; Calibration/Test OCR are diagnostics-only unless Apply is pressed; lastFlow=\(viewModel.ocrDiagnostics.lastPublicationFlowText)",
            "OCR field publication diagnostics: \(viewModel.ocrDiagnostics.orderedFieldPublicationDiagnostics.isEmpty ? "no observations" : "observed") - fields=\(viewModel.ocrDiagnostics.orderedFieldPublicationDiagnostics.count) last={\(viewModel.ocrDiagnostics.lastPublicationSummary)}",
            "OCR status consistency: \(viewModel.ocrOperationalStatus == .running && viewModel.isOCREffectiveRunning || viewModel.ocrOperationalStatus != .running && !viewModel.isOCREffectiveRunning ? "observed consistent" : "inconsistent") - \(viewModel.ocrOperationalStatusText) requested=\(yesNo(viewModel.isOCRRequested)) branch=\(yesNo(capture.activeMode.requiresOCR)) scheduler=\(yesNo(viewModel.isOCRSchedulerActive))",
            "Recording preflight observation: \(formatGuard.preflightResultText) - result=\(formatGuard.preflightResultText) capable=\(formatGuard.is60FPSCapableText)",
            "Recording capture lease consistency: \((recorder.state == .starting || recorder.isRecording || recorder.isPaused) == RinkLensRecordingCaptureLease.shared.snapshot().isActive ? "observed consistent" : "inconsistent") - \(RinkLensRecordingCaptureLease.shared.snapshot().diagnosticText)",
            "Recording source health observation: \(recorder.recordingHealthText) - \(recorder.recordingHealthText)",
            "Recording drop counters observed - unavailable=\(recorder.cameraSourceDrops) samplingDuplicates=\(recorder.sourceSamplingMisses) writer=\(recorder.writerDrops) render=\(recorder.renderDrops) black=\(recorder.recordingBlackFrameCount) total=\(recorder.framesDropped)",
            "Recording FPS threshold: \(fpsHealthy ? "within configured threshold" : "outside configured threshold") - actual=\(recorder.recordingActualFPSText) warning=\(recorder.recordingFPSWarningText)",
            "Encoder backlog threshold: \(backlogHealthy ? "within configured threshold" : "outside configured threshold") - backlog=\(recorder.recordingEncoderBacklogText)",
            "Dropped frames threshold: \(droppedFramesAcceptable ? "within configured threshold" : "outside configured threshold") - dropped=\(recorder.framesDropped)",
            "Black-frame rejection observation: \(recorder.recordingBlackFrameCount == 0 ? "none rejected" : "frames rejected") - rejected=\(recorder.recordingBlackFrameCount)",
            "PixelBuffer path observation: - \(BroadcastRecordingRendererPathDiagnostics.shared.pixelBufferPathText)",
            "Overlay queue observation: \(overlayQueueHealthy ? "no stuck marker" : "stuck marker present") - \(viewModel.broadcastOverlayQueueState.diagnosticSummary)",
            "BroadcastPhase state observed - \(viewModel.broadcastPhaseState.diagnosticSummary)",
            "Clip buffer observation: - \(clipBuffer.bufferDurationText); \(clipBuffer.clipStatusText)",
            "Diagnostics pressure: \(monitor.stallCount == 0 ? "no stalls observed" : "stalls observed") - stalls=\(monitor.stallCount) publish=\(monitor.publishPressureText)",
            "Operational policy configured - \(activeOperationalPolicy(monitor: monitor).diagnosticSummary)",
            "Performance budget observation: \(performanceBudgetPass(viewModel: viewModel, recorder: recorder, renderer: renderer, monitor: monitor) ? "within configured thresholds" : "outside one or more configured thresholds") - see PERFORMANCE BUDGETS section",
            "Diagnostics schema configured - \(RinkLensDiagnosticsExportSchema.current.diagnosticSummary)",
            "Match Day Safe policy available - available via Match Day Safe diagnostics mode",
            "Broadcast composite standard configured - \(BroadcastCompositeStandard.diagnosticSummary)",
            "Recording overlay parity: UX9 - Settings/Broadcast/recording/clips use the canonical compositor-backed scorebug preview",
            "UX2 scroll standard configured - \(RinkLensScrollPerformancePolicy.summary)",
            "UX10 UI configuration present - Camera settings styled, Media simplified, manual score update time hidden",
            "UX11 settings save behaviour configured - compact preview, logo-background parity and active-profile save prompt available",
            "UX12 compact scorebug/control configuration present - clip press feedback and Beside Name tight template available",
            "UX12c workflow configuration present - bottom-video timeline toggle, workflow-ordered Settings tabs and right-edge scorebug game sponsor available",
            "UX12e Settings configuration present - embedded Sponsors/Stream/Camera headers aligned; Event Popup preview is inline-only and toggle-aware",
            "UX12s Camera source mapping: CHECK - Built-in Back is a single rear zoom source; Ultra Wide is selected by 0.5x zoom rather than a camera row; manual format/FPS/focus/exposure/white-balance controls available",
            "UX12t Settings camera preload: CHECK - Settings Camera preloads Broadcast/OCR source lists without default auto-selection or session start",
            "UX12u Settings camera layout: CHECK - flat Settings cards with source, picture, lens, exposure, white-balance and rotation menus",
            "UX12v Settings camera sub-tabs: CHECK - Broadcast and OCR controls are separated to reduce Settings Camera scrolling"
        ]
    }

    private func performanceBudgetPass(
        viewModel: HockeyScoreboardViewModel,
        recorder: BroadcastRecordingManager,
        renderer: PersistentBroadcastRendererDiagnostics,
        monitor: MainThreadStallMonitor
    ) -> Bool {
        let budget = RinkLensPerformanceBudgets.matchDay
        let publishPerSecond = firstNumber(from: monitor.publishPressureText) ?? 0
        let backlog = firstNumber(from: recorder.recordingEncoderBacklogText) ?? 0
        let renderMs = firstDouble(from: renderer.lastRenderTimeMs) ?? 0
        return (renderMs <= budget.overlayRenderMilliseconds || renderMs == 0)
            && viewModel.ocrIntervalSeconds <= budget.ocrCycleSeconds + 0.001
            && publishPerSecond <= budget.diagnosticsPublishUpdatesPerSecond
            && backlog <= budget.encoderBacklogMaximum
            && recorder.framesDropped <= budget.droppedFramesWarningThreshold
            && monitor.stallCount <= budget.mainThreadStallMaximum
    }

    private func ownershipLines(viewModel: HockeyScoreboardViewModel, ownership: CameraOwnershipTraceStore, now: Date) -> [String] {
        let capture = viewModel.externalOCRMultiCamCoordinator.snapshot
        let hub = RinkLensFrameHub.shared.diagnosticSnapshot(now: now)
        let authoritativeOwner = capture.isActive || capture.isTransitioning || capture.sessionConfigured
            ? "CaptureEngine (\(capture.captureModeText))"
            : "none"
        let previewOwners = [
            capture.broadcastPreviewAttached ? "Broadcast" : nil,
            capture.ocrPreviewAttached ? "OCR" : nil
        ].compactMap { $0 }.joined(separator: ", ")

        var lines = [
            "Authoritative capture owner: \(authoritativeOwner)",
            "Capture phase: \(capture.phase.rawValue)",
            "Capture generation: \(capture.transitionGeneration)",
            "Broadcast active device: \(capture.activeMode.requiresBroadcast ? capture.liveDeviceID ?? "none" : "inactive")",
            "OCR active device: \(capture.activeMode.requiresOCR ? capture.ocrDeviceID ?? "none" : "inactive")",
            "Preview endpoints: \(previewOwners.isEmpty ? "none mounted" : previewOwners)",
            "Current recording owner: \(ownership.currentRecordingOwnerText)",
            "FrameHub Broadcast: \(hub.broadcast.diagnosticText)",
            "FrameHub OCR: \(hub.ocr.diagnosticText)",
            "Historical trace owner (non-authoritative): \(ownership.currentOwner.rawValue)",
            "Displayed owner source: CaptureEngine snapshot + FrameHub; trace store retained for history only",
            "Last session mutation: \(ownership.lastSessionMutation)",
            "Last preview mutation: \(ownership.lastPreviewMutation)",
            "Last recording mutation: \(ownership.lastRecordingMutation)",
            "Last forensic event: \(ownership.lastForensicEvent)",
            "",
            "Recent ownership events:"
        ]

        lines += ownership.events.isEmpty ? ["none"] : ownership.events.map(\.line)
        return lines
    }

    private func heartbeatAgeText(monitor: MainThreadStallMonitor, now: Date) -> String {
        let age = max(0, now.timeIntervalSince(monitor.lastHeartbeatAt))
        return String(format: "%.1fs ago", age)
    }

    private func stallText(_ seconds: TimeInterval) -> String {
        seconds > 0 ? String(format: "%.2fs", seconds) : "none"
    }

    private func firstNumber(from text: String) -> Int? {
        let digits = text.split { !$0.isNumber }.first
        return digits.flatMap { Int($0) }
    }

    private func firstDouble(from text: String) -> Double? {
        let allowed = Set("0123456789.")
        var buffer = ""
        for character in text {
            if allowed.contains(character) {
                buffer.append(character)
            } else if !buffer.isEmpty {
                break
            }
        }
        return buffer.isEmpty ? nil : Double(buffer)
    }

    private func yesNo(_ value: Bool) -> String {
        value ? "Yes" : "No"
    }

    private func enabledDisabled(_ value: Bool) -> String {
        value ? "Enabled" : "Disabled"
    }

    private func optionList(_ values: [String]) -> String {
        values.isEmpty ? "none" : values.joined(separator: ", ")
    }

    private func settingLine(area: String, name: String, active: String, passive: String, note: String) -> String {
        "\(area) | \(name) | Active: \(active) | Passive/selectable: \(passive) | Note: \(note)"
    }

    private func format(_ value: CGFloat) -> String {
        String(format: "%.4f", Double(value))
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return "\(hours)h \(minutes)m \(seconds)s"
    }

    private func byteText(_ bytes: UInt64?) -> String {
        guard let bytes else { return "unavailable" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

private struct DiagnosticsShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

#if canImport(UIKit)
private struct DiagnosticsShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

struct DebugLoggingPanel: View {
    @ObservedObject var monitor: MainThreadStallMonitor
    let viewModel: HockeyScoreboardViewModel
    let cameraService: HockeyCameraService
    @ObservedObject private var exporter = DiagnosticsLogExporter.shared

    @ViewBuilder
    var body: some View {
        if RinkLensRiskFeaturePolicy.isEnabled(.minimalOperatorCameraRecordingV12) {
            Picker("Logging", selection: diagnosticsModeBinding) {
                Text("Match Day").tag(RuntimeDiagnosticsMode.production)
                Text("Engineering").tag(RuntimeDiagnosticsMode.engineering)
            }
            .pickerStyle(.segmented)
            .padding(10)
            .broadcastMenuCard(cornerRadius: 14)
            .onAppear {
                normaliseOperatorMode()
            }
        } else {
                VStack(alignment: .leading, spacing: 12) {
                    DiagnosticsCard(title: "Logging Mode", systemImage: "doc.text.fill") {
                        Picker("Logging Mode", selection: diagnosticsModeBinding) {
                            Text("Match Day").tag(RuntimeDiagnosticsMode.production)
                            Text("Engineering").tag(RuntimeDiagnosticsMode.engineering)
                        }
                        .pickerStyle(.segmented)
            
                        DiagnosticsRow(title: "Active mode", value: activeOperatorModeText)
                        DiagnosticsRow(title: "Log detail", value: operatorDetailText)
            
                        Text("Changing logging mode does not restart or pause the camera, Image Relay, OCR, broadcast or recording.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .onAppear {
                    normaliseOperatorMode()
                }
        }
    }

    private var diagnosticsModeBinding: Binding<RuntimeDiagnosticsMode> {
        Binding(
            get: { monitor.diagnosticsMode == .engineering ? .engineering : .production },
            set: { monitor.setDiagnosticsMode($0, reason: "Build 653 two-mode logging panel") }
        )
    }

    private var activeOperatorModeText: String {
        monitor.diagnosticsMode == .engineering ? "Engineering" : "Match Day"
    }

    private var operatorDetailText: String {
        monitor.diagnosticsMode == .engineering
            ? "Verbose engineering evidence"
            : "Operational match events and critical faults"
    }

    private func normaliseOperatorMode() {
        guard monitor.diagnosticsMode != .production,
              monitor.diagnosticsMode != .engineering else { return }
        monitor.setDiagnosticsMode(.production, reason: "Build 653 operator mode normalisation")
    }
}
#endif
