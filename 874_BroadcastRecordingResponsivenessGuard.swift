// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(Foundation)
import Foundation

// MARK: - v0.9.1w5 Broadcast recording responsiveness guard

/// Lightweight guard for the full-match recording loop.
///
/// v0.9.1w4 proved that camera ownership was no longer the primary bottleneck:
/// the recorder could hold the main actor for several seconds while trying to
/// compose and append 1080p/60 frames. This guard makes the recorder shed render
/// ticks when the UI is already behind, rather than queueing more heavy work onto
/// the main actor.
enum BroadcastRecordingResponsivenessGuard {
    static func skipReason(
        targetFPS: Int32,
        mainActorWaitMS: Double,
        lastRenderDurationMS: Double,
        throttleFlipFlop: Bool
    ) -> String? {
        let safeFPS = max(1, Int(targetFPS))
        let frameBudgetMS = 1000.0 / Double(safeFPS)

        // If the source-clock tick has waited this long to reach MainActor, the UI
        // is already visibly behind. Drop this render immediately so the run loop
        // can catch up instead of spending another 20–30ms composing a frame.
        if mainActorWaitMS > max(80.0, frameBudgetMS * 4.0) {
            return String(format: "main actor backlog %.1fms", mainActorWaitMS)
        }

        // On older iPads, the full 1080p composite can be slower than the 16.7ms
        // 60fps budget. While it is over budget, shed alternate ticks. The video
        // writer uses wall-clock presentation times, so this protects UI responsiveness
        // without making the exported recording run fast.
        if safeFPS >= 50,
           lastRenderDurationMS > frameBudgetMS * 1.20,
           throttleFlipFlop {
            return String(format: "render budget guard %.1fms > %.1fms", lastRenderDurationMS, frameBudgetMS)
        }

        return nil
    }
}
#endif
