// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(Foundation)
import Foundation

// MARK: - UX16d1 Passive Telemetry Boundary

/// Small telemetry contract used by application composition and feature shells.
///
/// The contract is intentionally passive: implementations may record context,
/// breadcrumbs, publication pressure and timed operations, but they must never
/// start/stop capture, OCR, recording, clips, navigation or persistence work.
protocol RinkLensTelemetryClient: AnyObject {
    func markContext(_ context: String)
    func trace(_ event: String)
    func trace(_ channel: DiagnosticTraceChannel, _ event: String, toRenderTimeline: Bool?)
    func notePublish(source: String, count: Int)
    func beginTimedOperation(_ name: String) -> Date
    func endTimedOperation(_ name: String, startedAt: Date)
    func noteAppWillSuspend(reason: String)
    func noteAppDidResume(reason: String)
}

extension RinkLensTelemetryClient {
    func trace(_ channel: DiagnosticTraceChannel, _ event: String) {
        trace(channel, event, toRenderTimeline: nil)
    }

    func notePublish(source: String) {
        notePublish(source: source, count: 1)
    }
}

/// Behaviour-neutral telemetry implementation for tests and explicitly quiet
/// runtime configurations. It deliberately performs no engine or UI mutation.
final class NoOpRinkLensTelemetryClient: RinkLensTelemetryClient {
    func markContext(_ context: String) {}
    func trace(_ event: String) {}
    func trace(_ channel: DiagnosticTraceChannel, _ event: String, toRenderTimeline: Bool?) {}
    func notePublish(source: String, count: Int) {}
    func beginTimedOperation(_ name: String) -> Date { Date() }
    func endTimedOperation(_ name: String, startedAt: Date) {}
    func noteAppWillSuspend(reason: String) {}
    func noteAppDidResume(reason: String) {}
}

#endif
