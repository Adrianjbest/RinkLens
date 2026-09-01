// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation
import SwiftUI

// MARK: - v0.9.2 Stage 8 production PixelBuffer recording path flags

/// Temporary comparison switches for the recording renderer. The production
/// defaults remain direct CVPixelBuffer plus cached CI overlay, while controlled
/// Engineering runs can compare the retained paths before their final removal.
/// Per-frame UIImage fallback remains disabled in the writer hot loop.
@MainActor
final class BroadcastPixelBufferRecordingRolloutStore: ObservableObject {
    static let shared = BroadcastPixelBufferRecordingRolloutStore()

    private enum Keys {
        static let cameraOnlyPixelBufferTestEnabled = "rinklens.recording.pixelbuffer.cameraOnlyTest.enabled"
        static let cachedCIOverlayCompositeEnabled = "rinklens.recording.pixelbuffer.cachedCIOverlay.enabled"
        static let fullPixelBufferRecordingPathEnabled = "rinklens.recording.pixelbuffer.fullPath.enabled"
    }

    @Published var cameraOnlyPixelBufferTestEnabled: Bool {
        didSet {
            UserDefaults.standard.set(cameraOnlyPixelBufferTestEnabled, forKey: Keys.cameraOnlyPixelBufferTestEnabled)
            recordFlagChange(name: "cameraOnlyPixelBufferTestEnabled", previous: oldValue, next: cameraOnlyPixelBufferTestEnabled)
            BroadcastRecordingRendererPathDiagnostics.shared.noteFeatureFlags(summaryText)
        }
    }

    @Published var cachedCIOverlayCompositeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(cachedCIOverlayCompositeEnabled, forKey: Keys.cachedCIOverlayCompositeEnabled)
            recordFlagChange(name: "cachedCIOverlayCompositeEnabled", previous: oldValue, next: cachedCIOverlayCompositeEnabled)
            BroadcastRecordingRendererPathDiagnostics.shared.noteFeatureFlags(summaryText)
        }
    }

    @Published var fullPixelBufferRecordingPathEnabled: Bool {
        didSet {
            UserDefaults.standard.set(fullPixelBufferRecordingPathEnabled, forKey: Keys.fullPixelBufferRecordingPathEnabled)
            recordFlagChange(name: "fullPixelBufferRecordingPathEnabled", previous: oldValue, next: fullPixelBufferRecordingPathEnabled)
            BroadcastRecordingRendererPathDiagnostics.shared.noteFeatureFlags(summaryText)
        }
    }

    static let plannedRemovalBuild = 785
    static let removalPlan = "After physical recording-path comparison, select one renderer path and delete these rollout switches plus every disabled branch in the same build. Do not extend beyond Build 785."

    private init() {
        precondition(
            RinkLensBuildInfo.buildNumber <= Self.plannedRemovalBuild,
            "PixelBuffer recording rollout expired. \(Self.removalPlan)"
        )
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.cameraOnlyPixelBufferTestEnabled) == nil {
            defaults.set(false, forKey: Keys.cameraOnlyPixelBufferTestEnabled)
        }
        if defaults.object(forKey: Keys.cachedCIOverlayCompositeEnabled) == nil {
            defaults.set(true, forKey: Keys.cachedCIOverlayCompositeEnabled)
        }
        if defaults.object(forKey: Keys.fullPixelBufferRecordingPathEnabled) == nil {
            defaults.set(true, forKey: Keys.fullPixelBufferRecordingPathEnabled)
        }
        cameraOnlyPixelBufferTestEnabled = defaults.bool(forKey: Keys.cameraOnlyPixelBufferTestEnabled)
        cachedCIOverlayCompositeEnabled = defaults.bool(forKey: Keys.cachedCIOverlayCompositeEnabled)
        fullPixelBufferRecordingPathEnabled = defaults.bool(forKey: Keys.fullPixelBufferRecordingPathEnabled)
    }

    private func recordFlagChange(name: String, previous: Bool, next: Bool) {
        guard previous != next else { return }
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "recording_feature_flag_changed",
            entityID: name,
            previous: ["enabled": String(previous)],
            next: ["enabled": String(next)],
            source: "BroadcastPixelBufferRecordingRolloutStore",
            reason: "Controlled renderer comparison"
        )
    }

    var shouldUseFullPixelBufferRecordingPath: Bool {
        fullPixelBufferRecordingPathEnabled
    }

    var shouldUseCameraOnlyPixelBufferRecording: Bool {
        cameraOnlyPixelBufferTestEnabled
    }

    var shouldUsePixelBufferRecording: Bool {
        fullPixelBufferRecordingPathEnabled || cameraOnlyPixelBufferTestEnabled
    }

    var shouldUseCachedCIOverlayComposite: Bool {
        cachedCIOverlayCompositeEnabled
    }

    var summaryText: String {
        [
            BroadcastRecordingStage8Policy.summaryText,
            "fullPath=\(fullPixelBufferRecordingPathEnabled ? "on" : "off")",
            "cameraOnlyComparison=\(cameraOnlyPixelBufferTestEnabled ? "on" : "off")",
            "cachedOverlay=\(cachedCIOverlayCompositeEnabled ? "on" : "off")"
        ].joined(separator: "; ")
    }

    var activeWriterPathText: String {
        BroadcastRecordingStage8Policy.writerPathText
    }

    var activeRendererStageText: String {
        BroadcastRecordingStage8Policy.stageName
    }
}
#endif
