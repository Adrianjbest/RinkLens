// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation

// MARK: - v0.9.8 Stage 8c overlay async redraw sendability shims

/// These app-owned value types are copied into the Stage 8c background overlay
/// redraw queue. The conformance is isolated here so the async redraw fix does
/// not require broad model-file refactors.
extension Team: @unchecked Sendable {}
extension BroadcastEventType: @unchecked Sendable {}
extension BroadcastEventSource: @unchecked Sendable {}
extension StrengthState: @unchecked Sendable {}
extension PenaltyClock: @unchecked Sendable {}
extension BroadcastEvent: @unchecked Sendable {}
extension ScoreboardState: @unchecked Sendable {}
extension BroadcastRecordingRenderOverlayMode: @unchecked Sendable {}
#endif
