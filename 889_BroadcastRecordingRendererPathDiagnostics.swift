// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation
import SwiftUI

// MARK: - v9.2 Recording renderer path audit diagnostics

/// Stage 8A audit telemetry for the production recording renderer path.
///
/// This object is intentionally separate from the hot recording loop classes so
/// the migration can report which path is active without changing behaviour.
@MainActor
final class BroadcastRecordingRendererPathDiagnostics: ObservableObject {
    static let shared = BroadcastRecordingRendererPathDiagnostics()

    @Published private(set) var activeStageText: String = BroadcastRecordingStage8Policy.stageName
    @Published private(set) var writerPathText: String = BroadcastRecordingStage8Policy.writerPathText
    @Published private(set) var frameProviderPathText: String = BroadcastRecordingStage8Policy.frameProviderPathText
    @Published private(set) var rendererPathText: String = BroadcastRecordingStage8Policy.rendererPathText
    @Published private(set) var pixelBufferPathText: String = "direct pixelBuffer: waiting for recording"
    @Published private(set) var overlayPathText: String = BroadcastRecordingStage8Policy.overlayPathText
    @Published private(set) var fallbackReasonText: String = "none"
    @Published private(set) var featureFlagText: String = BroadcastRecordingStage8Policy.summaryText
    @Published private(set) var lastAuditEventText: String = "Stage 8 production renderer path idle"

    private var lastPublishAt: Date = .distantPast

    private init() {}

    func configureForRecordingStart(featureFlags: BroadcastPixelBufferRecordingRolloutStore) {
                activeStageText = BroadcastRecordingStage8Policy.stageName
        writerPathText = BroadcastRecordingStage8Policy.writerPathText
        frameProviderPathText = BroadcastRecordingStage8Policy.frameProviderPathText
        rendererPathText = BroadcastRecordingStage8Policy.rendererPathText
        overlayPathText = BroadcastRecordingStage8Policy.overlayPathText
        featureFlagText = featureFlags.summaryText
        fallbackReasonText = "none"
        lastAuditEventText = "recording start path: \(writerPathText); per-frame UIImage writer fallback removed"
        publishTrace(force: true)
    }

    func noteFeatureFlags(_ text: String) {
        activeStageText = BroadcastRecordingStage8Policy.stageName
        featureFlagText = BroadcastProductionDiagnosticLabelsV2.featureFlags(text)
        writerPathText = BroadcastRecordingStage8Policy.writerPathText
        frameProviderPathText = BroadcastRecordingStage8Policy.frameProviderPathText
        rendererPathText = BroadcastRecordingStage8Policy.rendererPathText
        overlayPathText = BroadcastRecordingStage8Policy.overlayPathText
        fallbackReasonText = "none"
        lastAuditEventText = "RNG-S8A policy active: production PixelBuffer path locked"
        publishTrace(force: true)
    }

    func noteUIImageRendererFromDirectPixelBuffer(sequence: Int, sizeText: String, source: String) {
        activeStageText = BroadcastRecordingStage8Policy.stageName
        writerPathText = BroadcastRecordingStage8Policy.writerPathText
        frameProviderPathText = "legacy UIImage renderer outside recording hot path"
        rendererPathText = "UIImage renderer fallback"
        pixelBufferPathText = "direct pixelBuffer audited: #\(sequence) \(sizeText)"
        overlayPathText = "cached overlay UIImage fallback"
        fallbackReasonText = BroadcastRecordingStage8Policy.legacyUIImageScopeText
        lastAuditEventText = "UIImage renderer fallback used outside production recording path: \(source)"
        publishTrace(force: false)
    }

    func noteLegacyUIImagePath(sequence: Int, sizeText: String, source: String, fallbackReason: String?) {
        activeStageText = BroadcastRecordingStage8Policy.stageName
        writerPathText = BroadcastRecordingStage8Policy.writerPathText
        frameProviderPathText = "legacy UIImage renderer outside recording hot path"
        rendererPathText = "UIImage renderer fallback"
        pixelBufferPathText = "direct pixelBuffer unavailable or rejected"
        overlayPathText = "cached overlay UIImage fallback"
        fallbackReasonText = fallbackReason ?? BroadcastRecordingStage8Policy.legacyUIImageScopeText
        lastAuditEventText = "legacy UIImage cache fallback used outside production recording path: #\(sequence) \(sizeText) \(source)"
        publishTrace(force: false)
    }

    func notePixelBufferWriterFrame(sequence: Int, sizeText: String, source: String, overlayPath: String) {
        activeStageText = BroadcastRecordingStage8Policy.stageName
        writerPathText = BroadcastRecordingStage8Policy.writerPathText
        frameProviderPathText = BroadcastRecordingStage8Policy.frameProviderPathText
        rendererPathText = "CoreImage PixelBuffer compositor"
        pixelBufferPathText = "direct pixelBuffer written: #\(sequence) \(sizeText)"
        overlayPathText = overlayPath
        fallbackReasonText = "none"
        lastAuditEventText = "PixelBuffer writer frame: \(source)"
        publishTrace(force: false)
    }

    func notePixelBufferFallback(reason: String) {
        fallbackReasonText = reason
        lastAuditEventText = "PixelBuffer fallback: \(reason)"
        publishTrace(force: true)
    }

    func noteNoFrame(reason: String) {
        fallbackReasonText = reason
        lastAuditEventText = "no recording frame: \(reason)"
        publishTrace(force: true)
    }

    func exportLines() -> [String] {
        [
            "Renderer stage: \(BroadcastProductionDiagnosticLabelsV2.rendererStage(activeStageText))",
            "Writer path: \(BroadcastProductionDiagnosticLabelsV2.writerPath(writerPathText))",
            "Frame provider path: \(BroadcastProductionDiagnosticLabelsV2.frameProviderPath(frameProviderPathText))",
            "Renderer path: \(BroadcastProductionDiagnosticLabelsV2.rendererPath(rendererPathText))",
            "PixelBuffer path: \(BroadcastProductionDiagnosticLabelsV2.pixelBufferPath(pixelBufferPathText))",
            "Overlay path: \(BroadcastProductionDiagnosticLabelsV2.overlayPath(overlayPathText))",
            "Feature flags: \(BroadcastProductionDiagnosticLabelsV2.featureFlags(featureFlagText))",
            "Fallback reason: \(BroadcastProductionDiagnosticLabelsV2.fallbackReason(fallbackReasonText))",
            "Last path event: \(lastAuditEventText)"
        ]
    }

    private func publishTrace(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPublishAt) >= 1.0 else { return }
        lastPublishAt = now
        MainThreadStallMonitor.shared.trace("recording renderer path | \(lastAuditEventText)")
    }
}
#endif
