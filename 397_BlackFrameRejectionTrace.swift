// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation
import SwiftUI

/// Recovery F / RL-041: isolated recording image-quality trace.
/// Very-dark frames are diagnostic content evidence only; they are not source-loss
/// evidence and must not stop a recording. The legacy type name is retained to
/// avoid widening this correction into validation-harness call sites.
@MainActor
final class BlackFrameRejectionTraceStore: ObservableObject {
    static let shared = BlackFrameRejectionTraceStore()

    @Published private(set) var totalRejectedText: String = "0"
    @Published private(set) var darkObservedText: String = "0"
    @Published private(set) var darkEncodedText: String = "0"
    @Published private(set) var lastReasonText: String = "none"
    @Published private(set) var lastFrameQualityText: String = "none"
    @Published private(set) var lastRejectedAtText: String = "--"
    @Published private(set) var firstValidFrameSeenText: String = "No"
    @Published private(set) var consecutiveRejectedText: String = "0"
    @Published private(set) var likelySourceText: String = "none"

    private var totalRejected: Int = 0
    private var darkObserved: Int = 0
    private var darkEncoded: Int = 0
    private var consecutiveRejected: Int = 0

    private init() {}

    func reset() {
        totalRejected = 0
        consecutiveRejected = 0
        totalRejectedText = "0"
        darkObserved = 0
        darkEncoded = 0
        darkObservedText = "0"
        darkEncodedText = "0"
        lastReasonText = "none"
        lastFrameQualityText = "none"
        lastRejectedAtText = "--"
        firstValidFrameSeenText = "No"
        consecutiveRejectedText = "0"
        likelySourceText = "none"
    }

    /// UX16c51 reconciles the background PixelBuffer worker with the shared
    /// diagnostics trace. The worker cannot publish this ObservableObject at
    /// video cadence, so the MainActor recording manager mirrors its throttled
    /// immutable counters here.
    func synchroniseBackgroundWorker(
        totalRejected workerTotal: Int,
        darkObserved workerDarkObserved: Int,
        darkEncoded workerDarkEncoded: Int,
        firstValidFrameSeen: Bool,
        lastSummary: String,
        source: String
    ) {
        guard workerTotal >= totalRejected else { return }
        totalRejected = workerTotal
        darkObserved = max(darkObserved, workerDarkObserved)
        darkEncoded = max(darkEncoded, workerDarkEncoded)
        totalRejectedText = "\(workerTotal)"
        darkObservedText = "\(darkObserved)"
        darkEncodedText = "\(darkEncoded)"
        if workerTotal > 0 {
            lastReasonText = "recording rejected source frame for a non-brightness reason"
            lastRejectedAtText = Self.timeFormatter.string(from: Date())
        } else if darkObserved > 0 {
            lastReasonText = "very-dark image content observed; fresh source frames were encoded"
        }
        if firstValidFrameSeen {
            firstValidFrameSeenText = "Yes"
            consecutiveRejected = 0
            consecutiveRejectedText = "0"
        }
        lastFrameQualityText = lastSummary
        likelySourceText = source
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
#endif
