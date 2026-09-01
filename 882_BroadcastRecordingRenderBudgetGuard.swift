// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(Foundation)
import Foundation

// MARK: - v0.9.1w10c 60fps render budget guard

/// Overlay mode used by the CoreGraphics recording renderer.
/// Full mode keeps the normal export overlay. Compact mode keeps the essential
/// score/time bug but removes optional export-only drawing when the 16.7ms 60fps
/// budget is being missed.
enum BroadcastRecordingRenderOverlayMode: String {
    case full = "full"
    case compact = "compact"

    var diagnosticText: String {
        switch self {
        case .full: return "full overlay"
        case .compact: return "compact 60fps overlay"
        }
    }
}

final class BroadcastRecordingRenderBudgetGuard: @unchecked Sendable {
    static let shared = BroadcastRecordingRenderBudgetGuard()

    private let lock = NSLock()
    private var mode: BroadcastRecordingRenderOverlayMode = .full
    private var overBudgetStreak = 0
    private var recoveryStreak = 0
    private var lastTraceAt: Date = .distantPast

    private init() {}

    func reset(reason: String) {
        lock.lock()
        mode = .full
        overBudgetStreak = 0
        recoveryStreak = 0
        lock.unlock()
        trace("recording render budget reset: \(reason)", force: true)
    }

    @discardableResult
    func update(targetFPS: Int32, lastRenderDurationMS: Double, pendingTicks: Int, mainActorWaitMS: Double) -> BroadcastRecordingRenderOverlayMode {
        let safeFPS = max(1, Int(targetFPS))
        let budgetMS = 1000.0 / Double(safeFPS)
        let overBudget = safeFPS >= 50 && (lastRenderDurationMS > budgetMS * 1.03 || pendingTicks > 1 || mainActorWaitMS > budgetMS * 1.5)
        let comfortablyInsideBudget = lastRenderDurationMS > 0 && lastRenderDurationMS < budgetMS * 0.82 && pendingTicks == 0 && mainActorWaitMS < budgetMS * 0.75

        lock.lock()
        let oldMode = mode
        if overBudget {
            overBudgetStreak += 1
            recoveryStreak = 0
        } else if comfortablyInsideBudget {
            recoveryStreak += 1
            overBudgetStreak = max(0, overBudgetStreak - 1)
        }

        if overBudgetStreak >= 3 {
            mode = .compact
        } else if recoveryStreak >= 90 {
            mode = .full
            overBudgetStreak = 0
        }
        let newMode = mode
        lock.unlock()

        if oldMode != newMode {
            trace("recording render budget mode: \(newMode.diagnosticText) last=\(format(lastRenderDurationMS))ms budget=\(format(budgetMS))ms pending=\(pendingTicks) mainWait=\(format(mainActorWaitMS))ms", force: true)
        } else if newMode == .compact {
            trace("recording render budget active: \(newMode.diagnosticText) last=\(format(lastRenderDurationMS))ms budget=\(format(budgetMS))ms", force: false)
        }
        return newMode
    }

    func currentMode() -> BroadcastRecordingRenderOverlayMode {
        lock.lock()
        let current = mode
        lock.unlock()
        return current
    }

    private func trace(_ text: String, force: Bool) {
        let now = Date()
        lock.lock()
        let shouldTrace = force || now.timeIntervalSince(lastTraceAt) >= 2.0
        if shouldTrace { lastTraceAt = now }
        lock.unlock()
        guard shouldTrace else { return }
        DispatchQueue.main.async {
            MainThreadStallMonitor.shared.trace(text)
        }
    }

    private func format(_ value: Double) -> String {
        String(format: "%.1f", max(0, value))
    }
}
#endif
