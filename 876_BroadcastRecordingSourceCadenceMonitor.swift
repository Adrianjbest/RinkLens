// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation

// MARK: - v0.9.1w7 Recording source cadence monitor

/// Tracks the real camera-source cadence feeding the recorder, separate from the
/// AVAssetWriter/output cadence. This catches the case where the app writes a valid
/// 60fps MP4 but repeats a 30fps source frame, which feels like it is not true 60fps.
@MainActor
final class BroadcastRecordingSourceCadenceMonitor {
    static let shared = BroadcastRecordingSourceCadenceMonitor()

    private var windowStartedAt = Date()
    private var lastSequenceBySource: [String: Int] = [:]
    private var renderTicks = 0
    private var uniqueSourceFrames = 0
    private var duplicateSourceFrames = 0
    private var lastSummary = "source cadence warming up"
    private var lastTraceAt = Date.distantPast

    private init() {}

    func reset() {
        windowStartedAt = Date()
        lastSequenceBySource.removeAll()
        renderTicks = 0
        uniqueSourceFrames = 0
        duplicateSourceFrames = 0
        lastSummary = "source cadence warming up"
        lastTraceAt = .distantPast
    }

    /// Records the selected source frame and returns the latest low-rate summary.
    func noteSelectedSource(label: String, sequence: Int, targetFPS: Int, sizeText: String) -> String {
        let now = Date()
        renderTicks += 1

        if lastSequenceBySource[label] == sequence {
            duplicateSourceFrames += 1
        } else {
            uniqueSourceFrames += 1
            lastSequenceBySource[label] = sequence
        }

        let elapsed = now.timeIntervalSince(windowStartedAt)
        guard elapsed >= 1.0 else { return lastSummary }

        let sourceFPS = Double(uniqueSourceFrames) / max(0.001, elapsed)
        let renderFPS = Double(renderTicks) / max(0.001, elapsed)
        let duplicatePercent = Double(duplicateSourceFrames) / Double(max(1, renderTicks)) * 100.0
        let target = max(1, targetFPS)
        let status: String
        if sourceFPS + 1.0 < Double(target) * 0.92 {
            status = "source below target"
        } else {
            status = "source healthy"
        }

        lastSummary = String(
            format: "%@ %.1ffps render %.1ffps dup %.0f%% %@ %@",
            label,
            sourceFPS,
            renderFPS,
            duplicatePercent,
            sizeText,
            status
        )

        if now.timeIntervalSince(lastTraceAt) >= 2.0 || status == "source below target" {
            lastTraceAt = now
            MainThreadStallMonitor.shared.trace("recording source cadence: \(lastSummary)")
        }

        windowStartedAt = now
        renderTicks = 0
        uniqueSourceFrames = 0
        duplicateSourceFrames = 0
        return lastSummary
    }
}

#endif
