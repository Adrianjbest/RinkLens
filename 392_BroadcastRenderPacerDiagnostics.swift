// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import Foundation

// MARK: - v0.9.1u Diagnostics Export Completion

/// Low-publish render pacer telemetry for the recording loop.
///
/// The recording loop can run at up to 60Hz. This object keeps the hot-path
/// samples internal and publishes only a compact recording/export snapshot.
/// v0.9.1u adds source-clock visibility so exports can prove whether rendering
/// is driven by the old main-run-loop Timer or the new SourceClock path.
@MainActor
final class BroadcastRenderPacerDiagnostics: ObservableObject {
    static let shared = BroadcastRenderPacerDiagnostics()

    @Published private(set) var renderPacerSourceText: String = "Unknown"
    @Published private(set) var targetTickIntervalText: String = "16.7ms"
    @Published private(set) var actualTickIntervalText: String = "--"
    @Published private(set) var sourceClockDriftText: String = "--"
    @Published private(set) var skippedTickReasonText: String = "none"
    @Published private(set) var lateTickReasonText: String = "none"
    @Published private(set) var mainActorWaitText: String = "--"
    @Published private(set) var frameInputWaitText: String = "--"
    @Published private(set) var writerWaitText: String = "--"
    @Published private(set) var starvationCount: Int = 0
    @Published private(set) var starvationCountText: String = "0"
    @Published private(set) var lateTickCountText: String = "0"
    @Published private(set) var droppedOrMergedRenderTicksText: String = "0"
    @Published private(set) var lastTickSummaryText: String = "pacer idle"

    private var targetFPS: Int = 60
    private var targetTickIntervalMS: Double = 16.6667
    private var lastTickStartedAt: Date?
    private var lastPublishAt: Date = .distantPast
    private var lateTickCount: Int = 0
    private var droppedOrMergedRenderTicks: Int = 0

    private var pendingRenderPacerSourceText: String = "Unknown"
    private var pendingTargetTickIntervalText: String = "16.7ms"
    private var pendingActualTickIntervalText: String = "--"
    private var pendingSourceClockDriftText: String = "--"
    private var pendingSkippedTickReasonText: String = "none"
    private var pendingLateTickReasonText: String = "none"
    private var pendingMainActorWaitText: String = "--"
    private var pendingFrameInputWaitText: String = "--"
    private var pendingWriterWaitText: String = "--"
    private var pendingLastTickSummaryText: String = "pacer idle"

    private init() {}

    func configure(targetFPS: Int, source: String = "Timer") {
        self.targetFPS = max(1, targetFPS)
        targetTickIntervalMS = 1000.0 / Double(self.targetFPS)
        pendingRenderPacerSourceText = source
        pendingTargetTickIntervalText = String(format: "%.1fms", targetTickIntervalMS)
        starvationCount = 0
        starvationCountText = "0"
        lateTickCount = 0
        lateTickCountText = "0"
        droppedOrMergedRenderTicks = 0
        droppedOrMergedRenderTicksText = "0"
        lastTickStartedAt = nil
        lastPublishAt = .distantPast
        pendingActualTickIntervalText = "--"
        pendingSourceClockDriftText = "--"
        pendingSkippedTickReasonText = "none"
        pendingLateTickReasonText = "none"
        pendingMainActorWaitText = "--"
        pendingFrameInputWaitText = "--"
        pendingWriterWaitText = "--"
        pendingLastTickSummaryText = "pacer armed at \(self.targetFPS)fps using \(source)"
        publish(force: true)
    }

    func setPacerSource(_ source: String) {
        pendingRenderPacerSourceText = source
        publish(force: true)
    }

    func noteTickStarted(timerFiredAt: Date?, tickStartedAt: Date = Date()) {
        if let lastTickStartedAt {
            let intervalMs = tickStartedAt.timeIntervalSince(lastTickStartedAt) * 1000.0
            pendingActualTickIntervalText = String(format: "%.1fms", intervalMs)
            pendingSourceClockDriftText = String(format: "%+.1fms", intervalMs - targetTickIntervalMS)
        } else {
            pendingActualTickIntervalText = "first tick"
            pendingSourceClockDriftText = "--"
        }
        lastTickStartedAt = tickStartedAt

        if let timerFiredAt {
            let waitMs = max(0, tickStartedAt.timeIntervalSince(timerFiredAt) * 1000.0)
            pendingMainActorWaitText = String(format: "%.1fms", waitMs)
        } else {
            pendingMainActorWaitText = "--"
        }
        pendingSkippedTickReasonText = "none"
        pendingLastTickSummaryText = "tick accepted at \(targetFPS)fps using \(pendingRenderPacerSourceText)"
        publish(force: false)
    }

    func noteTickSkipped(reason: String, timerFiredAt: Date?, tickStartedAt: Date = Date()) {
        if let timerFiredAt {
            let waitMs = max(0, tickStartedAt.timeIntervalSince(timerFiredAt) * 1000.0)
            pendingMainActorWaitText = String(format: "%.1fms", waitMs)
        }
        pendingSkippedTickReasonText = reason
        starvationCount += 1
        starvationCountText = "\(starvationCount)"
        droppedOrMergedRenderTicks += 1
        droppedOrMergedRenderTicksText = "\(droppedOrMergedRenderTicks)"
        pendingLastTickSummaryText = "tick skipped: \(reason)"
        publish(force: true)
    }

    func noteLateTick(reason: String, timerFiredAt: Date?, tickStartedAt: Date = Date()) {
        if let lastTickStartedAt {
            let intervalMs = tickStartedAt.timeIntervalSince(lastTickStartedAt) * 1000.0
            pendingActualTickIntervalText = String(format: "%.1fms", intervalMs)
            pendingSourceClockDriftText = String(format: "%+.1fms", intervalMs - targetTickIntervalMS)
        }
        if let timerFiredAt {
            let waitMs = max(0, tickStartedAt.timeIntervalSince(timerFiredAt) * 1000.0)
            pendingMainActorWaitText = String(format: "%.1fms", waitMs)
        }
        pendingLateTickReasonText = reason
        lateTickCount += 1
        lateTickCountText = "\(lateTickCount)"
        starvationCount += 1
        starvationCountText = "\(starvationCount)"
        pendingLastTickSummaryText = "late tick: \(reason)"
        publish(force: true)
    }

    func noteFrameInputWait(milliseconds: Double) {
        pendingFrameInputWaitText = String(format: "%.1fms", max(0, milliseconds))
        publish(force: false)
    }

    func noteWriterWait(milliseconds: Double) {
        pendingWriterWaitText = String(format: "%.1fms", max(0, milliseconds))
        publish(force: false)
    }

    func noteFrameCompleted(frameInputWaitMs: Double, writerWaitMs: Double) {
        pendingFrameInputWaitText = String(format: "%.1fms", max(0, frameInputWaitMs))
        pendingWriterWaitText = String(format: "%.1fms", max(0, writerWaitMs))
        pendingLastTickSummaryText = "frame completed input=\(pendingFrameInputWaitText) writer=\(pendingWriterWaitText)"
        publish(force: false)
    }

    private func publish(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPublishAt) >= 1.0 else { return }
        lastPublishAt = now
        if renderPacerSourceText != pendingRenderPacerSourceText { renderPacerSourceText = pendingRenderPacerSourceText }
        if targetTickIntervalText != pendingTargetTickIntervalText { targetTickIntervalText = pendingTargetTickIntervalText }
        if actualTickIntervalText != pendingActualTickIntervalText { actualTickIntervalText = pendingActualTickIntervalText }
        if sourceClockDriftText != pendingSourceClockDriftText { sourceClockDriftText = pendingSourceClockDriftText }
        if skippedTickReasonText != pendingSkippedTickReasonText { skippedTickReasonText = pendingSkippedTickReasonText }
        if lateTickReasonText != pendingLateTickReasonText { lateTickReasonText = pendingLateTickReasonText }
        if mainActorWaitText != pendingMainActorWaitText { mainActorWaitText = pendingMainActorWaitText }
        if frameInputWaitText != pendingFrameInputWaitText { frameInputWaitText = pendingFrameInputWaitText }
        if writerWaitText != pendingWriterWaitText { writerWaitText = pendingWriterWaitText }
        if lastTickSummaryText != pendingLastTickSummaryText { lastTickSummaryText = pendingLastTickSummaryText }
    }
}
#endif
