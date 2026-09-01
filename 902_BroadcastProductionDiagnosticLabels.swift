// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation

// MARK: - v9.2 Stage 8b production recording diagnostic label normaliser

// Build 710 source-hygiene boundary: the helper type carries a V2 suffix so a stale
// Finder/Xcode copy named “902_BroadcastProductionDiagnosticLabels 2.swift” cannot
// create ambiguous overloads when this canonical file is copied over an existing project.

/// Keeps diagnostics aligned with the Stage 8 production policy even when older
/// Stage 4/5/6 migration labels are still held in a runtime object after app
/// startup, view transitions, or post-recording idle state.
///
/// This is label-only diagnostic cleanup. It does not change the recording path,
/// writer path, clip buffer, OCR, camera ownership, or render loop behaviour.
enum BroadcastProductionDiagnosticLabelsV2 {
    static func rendererStage(_ value: String) -> String {
        let lower = value.lowercased()
        if lower.contains("stage 1 audit") || lower.contains("stage 6 full pixelbuffer") || lower.contains("full pixelbuffer recording path") {
            return BroadcastRecordingStage8Policy.stageName
        }
        return value.isEmpty ? BroadcastRecordingStage8Policy.stageName : value
    }

    static func writerPath(_ value: String) -> String {
        let lower = value.lowercased()
        if lower.contains("appendframe(uiimage)") || lower.contains("appendpixelbuffer") || lower.contains("existing fallback") || lower.contains("full recording path") {
            return BroadcastRecordingStage8Policy.writerPathText
        }
        return value.isEmpty ? BroadcastRecordingStage8Policy.writerPathText : value
    }

    static func frameProviderPath(_ value: String) -> String {
        let lower = value.lowercased()
        if lower.contains("frameprovider uiimage") || lower.contains("direct pixelbuffer") || lower.contains("legacy uiimage") {
            return BroadcastRecordingStage8Policy.frameProviderPathText
        }
        return value.isEmpty ? BroadcastRecordingStage8Policy.frameProviderPathText : value
    }

    static func rendererPath(_ value: String) -> String {
        let lower = value.lowercased()
        if lower.contains("uiimage renderer") || lower.contains("coreimage") || lower.contains("pixelbuffer compositor") {
            return BroadcastRecordingStage8Policy.rendererPathText
        }
        return value.isEmpty ? BroadcastRecordingStage8Policy.rendererPathText : value
    }

    static func pixelBufferPath(_ value: String) -> String {
        let lower = value.lowercased()
        if lower.contains("not selected") || lower.contains("unavailable") || lower.contains("waiting") || lower.isEmpty {
            return "direct pixelBuffer: production path idle"
        }
        return value
    }

    static func overlayPath(_ value: String) -> String {
        let lower = value.lowercased()
        if lower.contains("cached overlay uiimage") || lower.contains("cached overlay ciimage") || lower.contains("ciimage") {
            return BroadcastRecordingStage8Policy.overlayPathText
        }
        return value.isEmpty ? BroadcastRecordingStage8Policy.overlayPathText : value
    }

    static func featureFlags(_ value: String) -> String {
        let lower = value.lowercased()
        if lower.contains("stage 8") || lower.contains("pixelbuffer") || lower.contains("camera-only") || lower.contains("cached ci") || lower.contains("full pixelbuffer") {
            return BroadcastRecordingStage8Policy.summaryText
        }
        return value.isEmpty ? BroadcastRecordingStage8Policy.summaryText : value
    }

    static func fallbackReason(_ value: String) -> String {
        let lower = value.lowercased()
        if lower == "none" || lower.contains("preview/export fallback") || lower.contains("legacy uiimage") {
            return "none"
        }
        return value
    }
}
#endif
