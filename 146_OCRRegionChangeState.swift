// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation

// MARK: - v0.8.8m7 OCR Region Change State

/// Pixel/hash change hints consumed by OCRScheduler.
///
/// The scheduler does not calculate hashes. It only consumes changed/not changed
/// hints so cadence decisions can be centralised without changing OCR recognition.
struct OCRRegionChangeState: Equatable, Sendable {
    var clockChanged: Bool
    var scoreChanged: Bool
    var periodChanged: Bool
    var penaltyChanged: Bool
    var playerNumberChanged: Bool

    nonisolated static let unknown = OCRRegionChangeState(
        clockChanged: true,
        scoreChanged: true,
        periodChanged: true,
        penaltyChanged: true,
        playerNumberChanged: true
    )

    nonisolated static let unchanged = OCRRegionChangeState(
        clockChanged: false,
        scoreChanged: false,
        periodChanged: false,
        penaltyChanged: false,
        playerNumberChanged: false
    )
}
#endif
