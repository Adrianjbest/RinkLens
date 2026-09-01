// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(Foundation)
import Foundation

// MARK: - v0.9.1u Clip Export Window Resolver

/// Resolves manual/automatic clip requests onto the newest fully-written,
/// contiguous rolling-buffer window.
///
/// This prevents manual clips being anchored to `Date()` when the newest segment
/// is still being written, which can make the exporter report a short clip even
/// though the retained buffer already contains enough complete footage.
nonisolated struct ClipBufferExportWindowResolver {
    struct ResolvedWindow {
        let start: Date
        let end: Date
        let selectedSegments: [ClipBufferSegmentRecord]
        let lookupText: String
    }

    static func resolve(
        requestedStart: Date,
        requestedEnd: Date,
        requestedDuration: TimeInterval?,
        completeSegments: [ClipBufferSegmentRecord],
        recordingEpochID: UUID? = nil
    ) -> ResolvedWindow {
        let complete = completeSegments
            .filter { $0.status == .complete }
            .filter { recordingEpochID == nil || $0.recordingEpochID == recordingEpochID }
            .sorted { $0.startTime < $1.startTime }

        guard let first = complete.first, let last = complete.last else {
            return ResolvedWindow(
                start: requestedStart,
                end: requestedEnd,
                selectedSegments: [],
                lookupText: "complete=0 selected=0 coverage=none resolved=none"
            )
        }

        let requestedLength = max(0, requestedDuration ?? requestedEnd.timeIntervalSince(requestedStart))
        let resolvedEnd = min(requestedEnd, last.endTime)
        let fallbackStart = resolvedEnd.addingTimeInterval(-requestedLength)
        let resolvedStart = max(first.startTime, min(requestedStart, fallbackStart))
        let selected = complete.filter { $0.endTime >= resolvedStart && $0.startTime <= resolvedEnd }
        let coverageDuration = complete.reduce(0) { $0 + max(0, $1.duration) }
        let selectedDuration = selected.reduce(0) { $0 + max(0, min($1.endTime, resolvedEnd).timeIntervalSince(max($1.startTime, resolvedStart))) }
        let lookup = "complete=\(complete.count) selected=\(selected.count) coverage=\(format(first.startTime))...\(format(last.endTime)) \(String(format: "%.1f", coverageDuration))s resolved=\(format(resolvedStart))...\(format(resolvedEnd)) selectedDuration=\(String(format: "%.1f", selectedDuration))s"
        return ResolvedWindow(start: resolvedStart, end: resolvedEnd, selectedSegments: selected, lookupText: lookup)
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
}
#endif
