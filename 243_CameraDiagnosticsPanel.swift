// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI

// STYLE2 central design system migration: operator chrome/fonts use RinkLensDesignSystem where safe.
import Foundation

struct CameraDiagnosticsPanel: View {
    let viewModel: HockeyScoreboardViewModel
    @ObservedObject var service: HockeyCameraService

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.5)) { context in
            let capture = viewModel.externalOCRMultiCamCoordinator.snapshot
            let mutationAudit = RinkLensCaptureGraphMutationAudit.shared.snapshot()
            VStack(alignment: .leading, spacing: 12) {
            DiagnosticsCard(title: "CaptureEngine / MultiCam", systemImage: "camera.fill") {
                DiagnosticsRow(title: "Mode / phase", value: "\(capture.captureModeText) / \(capture.phase.rawValue)")
                DiagnosticsRow(title: "Failed contract", value: capture.degradedRecord?.failedContract.diagnosticText ?? "none")
                DiagnosticsRow(title: "Cooldown", value: capture.degradedRecord.map { String(format: "%.1fs", $0.cooldownRemainingSeconds) } ?? "none")
                DiagnosticsRow(title: "Operator retry", value: capture.degradedRecord == nil ? "Not required" : "Available under Recovery")
                DiagnosticsRow(title: "Broadcast pressure", value: "\(capture.liveSystemPressureLevel) factors=\(capture.liveSystemPressureFactors)")
                DiagnosticsRow(title: "OCR pressure", value: "\(capture.ocrSystemPressureLevel) factors=\(capture.ocrSystemPressureFactors)")
                DiagnosticsRow(title: "OCR pressure policy", value: capture.ocrPressurePolicyState)
                DiagnosticsRow(title: "OCR pressure delivery", value: capture.ocrPressureSuspended ? "Suspended" : (capture.ocrPressureDeliveryFPS > 0 ? String(format: "%.1f fps maximum", capture.ocrPressureDeliveryFPS) : "Full source cadence"))
                DiagnosticsRow(title: "Broadcast preservation", value: capture.broadcastPreservationActive ? "Active — Broadcast format unchanged" : "Standby")
                DiagnosticsRow(title: "Broadcast drops", value: "total=\(capture.liveDroppedFrames) late=\(capture.liveDroppedLateFrames) buffers=\(capture.liveDroppedOutOfBuffers) discontinuity=\(capture.liveDroppedDiscontinuityFrames)")
                DiagnosticsRow(title: "OCR drops", value: "total=\(capture.ocrDroppedFrames) late=\(capture.ocrDroppedLateFrames) buffers=\(capture.ocrDroppedOutOfBuffers) discontinuity=\(capture.ocrDroppedDiscontinuityFrames)")
                DiagnosticsRow(title: "Last AVFoundation drop", value: capture.lastDroppedFrameText)
                DiagnosticsRow(title: "Live-safe controls", value: "device=\(mutationAudit.liveDeviceControlCount) cadence=\(mutationAudit.liveCadenceCount) no-op=\(mutationAudit.noGraphChangeCount)")
                DiagnosticsRow(title: "Full graph rebuilds", value: "\(mutationAudit.fullGraphRebuildCount)")
                DiagnosticsRow(title: "Last graph decision", value: mutationAudit.lastMutationText)
            }

            DiagnosticsCard(title: "Camera / Preview", systemImage: "video.fill") {
                DiagnosticsRow(title: "Diagnostics updating", value: service.diagnosticsUpdatingText(now: context.date))
                DiagnosticsRow(title: "Session type", value: service.isPreviewOnlySession ? "preview-only" : "frame-processing")
                DiagnosticsRow(title: "Running", value: service.isSessionRunning ? "Yes" : "No")
                DiagnosticsRow(title: "Frames", value: service.hasReceivedFrames ? "receiving / preview OK" : "not yet received")
                DiagnosticsRow(title: "Last frame time", value: service.lastFrameReceivedAt?.formatted(date: .omitted, time: .standard) ?? "--")
                DiagnosticsRow(title: "Last frame age", value: service.lastFrameAgeText(now: context.date))
                DiagnosticsRow(title: "Restart count", value: "\(service.lifecycleRestartCount)")
                DiagnosticsRow(title: "Last restart", value: service.lastRestartedAtText)
                DiagnosticsRow(title: "Restart reason", value: service.lastRestartReasonText)
                DiagnosticsRow(title: "Last event", value: service.lastLifecycleEventText)
                DiagnosticsRow(title: "Preview expectation", value: service.previewExpectationText)
                DiagnosticsRow(title: "Preview attached", value: service.previewLayerAttached ? "Yes" : "No")
                DiagnosticsRow(title: "Preview ready", value: service.previewLayerReadyForDisplay ? "Yes" : "No")
                DiagnosticsRow(title: "Preview layer age", value: service.previewLayerAgeText(now: context.date))
                DiagnosticsRow(title: "Preview layer frame", value: service.previewLayerFrameText)
                DiagnosticsRow(title: "Preview session", value: service.previewSessionAssignedText)
                DiagnosticsRow(title: "Preview reattach count", value: "\(service.previewLayerReattachCount)")
                DiagnosticsRow(title: "Preview stale count", value: "\(service.previewLayerStaleCount)")
                DiagnosticsRow(title: "Preview event", value: service.lastPreviewLayerEventText)
                DiagnosticsRow(title: "Frame pipeline", value: service.framePipelineText)
                DiagnosticsRow(
                    title: "FrameHub latest slot",
                    value: RinkLensFrameHub.shared.diagnosticText(
                        for: service.isPreviewOnlySession ? .broadcast : .ocr,
                        now: context.date
                    )
                )
                DiagnosticsRow(title: "White-screen detector", value: service.whiteScreenDetectorText)
            }
            }
        }
    }
}
#endif
