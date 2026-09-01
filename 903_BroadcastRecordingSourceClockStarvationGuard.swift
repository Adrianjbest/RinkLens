// BUILD 738 STATE CONTRACT: BroadcastRecordingManager owns recording state; this guard owns only one bounded transient latest-frame continuity cache.
#if canImport(SwiftUI)
import Foundation
import CoreImage
import CoreVideo

// MARK: - Build 738 SourceClock starvation guard

/// Capacity-one transient cache for the most recent valid direct Broadcast
/// PixelBuffer. RecordingWriter may consume it for a bounded callback gap; it
/// never changes camera state, recording state, output cadence or MatchState.
final class BroadcastRecordingSourceClockStarvationGuard: @unchecked Sendable {
    static let shared = BroadcastRecordingSourceClockStarvationGuard()

    private let lock = NSLock()
    private var lastFreshFrame: BroadcastRecordingPixelBufferFrame?
    private var heldFrameReuseCount = 0
    private var staleHoldDropCount = 0
    private var missingFreshCount = 0
    private var lastHeldFrameAgeMS: Double = 0
    private var lastDecisionText = "idle"
    private var lastTraceAt: Date = .distantPast
    private var holdoverActive = false
    private var holdoverExpiredLogged = false

    private init() {}

    private var maxHoldAgeSeconds: TimeInterval {
        RinkLensRiskFeaturePolicy.isEnabled(.recordingBoundedSourceHoldoverV20) ? 0.500 : 0.150
    }

    func reset(reason: String) {
        lock.lock()
        let wasActive = holdoverActive
        let previousReuse = heldFrameReuseCount
        lastFreshFrame = nil
        heldFrameReuseCount = 0
        staleHoldDropCount = 0
        missingFreshCount = 0
        lastHeldFrameAgeMS = 0
        lastDecisionText = "reset: \(reason)"
        holdoverActive = false
        holdoverExpiredLogged = false
        lock.unlock()
        if wasActive {
            recordTransition(
                event: "recording_source_holdover_reset",
                previous: ["active": "true", "reuseCount": String(previousReuse)],
                next: ["active": "false", "reuseCount": "0"],
                reason: reason
            )
        }
        trace("source starvation guard reset: \(reason)", force: true)
    }

    func noteFreshFrame(_ frame: BroadcastRecordingPixelBufferFrame) -> BroadcastRecordingPixelBufferFrame {
        lock.lock()
        let recovered = holdoverActive
        let previousReuse = heldFrameReuseCount
        let previousAge = lastHeldFrameAgeMS
        lastFreshFrame = frame
        lastDecisionText = "fresh direct pixelBuffer #\(frame.sequence) \(frame.sizeText)"
        holdoverActive = false
        holdoverExpiredLogged = false
        lock.unlock()
        if recovered {
            recordTransition(
                event: "recording_source_holdover_recovered",
                previous: [
                    "active": "true",
                    "reuseCount": String(previousReuse),
                    "lastAgeMs": String(format: "%.0f", previousAge)
                ],
                next: [
                    "active": "false",
                    "freshSequence": String(frame.sequence),
                    "source": frame.sourceDescription
                ],
                reason: "Fresh current-generation Broadcast frame received"
            )
        }
        return frame
    }

    func heldFrameIfFreshEnough(now: Date, missingReason: String) -> BroadcastRecordingPixelBufferFrame? {
        let maximumAge = maxHoldAgeSeconds
        lock.lock()
        guard let frame = lastFreshFrame else {
            missingFreshCount &+= 1
            lastDecisionText = "no hold frame available after missing source: \(missingReason)"
            let decision = lastDecisionText
            lock.unlock()
            trace("source starvation guard miss: \(decision)", force: false)
            return nil
        }

        let age = max(0, now.timeIntervalSince(frame.capturedAt))
        guard age <= maximumAge else {
            missingFreshCount &+= 1
            staleHoldDropCount &+= 1
            lastHeldFrameAgeMS = age * 1000.0
            lastDecisionText = String(format: "hold expired %.0fms > %.0fms; %@", lastHeldFrameAgeMS, maximumAge * 1000.0, missingReason)
            let shouldLog = !holdoverExpiredLogged
            let previousActive = holdoverActive
            holdoverActive = false
            holdoverExpiredLogged = true
            let previousReuse = heldFrameReuseCount
            let ageMS = lastHeldFrameAgeMS
            let decision = lastDecisionText
            lock.unlock()
            if shouldLog {
                recordTransition(
                    event: "recording_source_holdover_expired",
                    previous: [
                        "active": String(previousActive),
                        "reuseCount": String(previousReuse),
                        "lastAgeMs": String(format: "%.0f", ageMS)
                    ],
                    next: [
                        "active": "false",
                        "maximumAgeMs": String(format: "%.0f", maximumAge * 1000.0)
                    ],
                    reason: missingReason
                )
            }
            trace("source starvation guard expired: \(decision)", force: false)
            return nil
        }

        let starting = !holdoverActive
        holdoverActive = true
        holdoverExpiredLogged = false
        heldFrameReuseCount &+= 1
        lastHeldFrameAgeMS = age * 1000.0
        let reuseCount = heldFrameReuseCount
        lastDecisionText = String(format: "held direct pixelBuffer #\(frame.sequence) for %.0fms reuse=%d", lastHeldFrameAgeMS, reuseCount)
        let sourceDescription = frame.sourceDescription + String(format: "; Build 738 held direct pixelBuffer %.0fms reuse=%d", lastHeldFrameAgeMS, reuseCount)
        let ageMS = lastHeldFrameAgeMS
        lock.unlock()

        if starting {
            recordTransition(
                event: "recording_source_holdover_started",
                previous: ["active": "false", "reuseCount": String(max(0, reuseCount - 1))],
                next: [
                    "active": "true",
                    "reuseCount": String(reuseCount),
                    "frameSequence": String(frame.sequence),
                    "ageMs": String(format: "%.0f", ageMS),
                    "maximumAgeMs": String(format: "%.0f", maximumAge * 1000.0)
                ],
                reason: missingReason
            )
        }
        trace("source starvation guard reused last direct pixelBuffer age=\(Int(ageMS.rounded()))ms reuse=\(reuseCount)", force: false)
        return BroadcastRecordingPixelBufferFrame(
            pixelBuffer: frame.pixelBuffer,
            capturedAt: frame.capturedAt,
            sequence: frame.sequence,
            sizeText: frame.sizeText,
            sourceDescription: sourceDescription,
            cameraRotationDegrees: frame.cameraRotationDegrees,
            compositeRotationDegrees: frame.compositeRotationDegrees,
            mirrorCorrectionEnabled: frame.mirrorCorrectionEnabled,
            overlayCIImage: frame.overlayCIImage
        )
    }

    func diagnosticSummaryText() -> String {
        lock.lock()
        let text = String(
            format: "active=%@ reuse=%d staleDrops=%d missing=%d lastAge=%.0fms decision=%@",
            String(holdoverActive),
            heldFrameReuseCount,
            staleHoldDropCount,
            missingFreshCount,
            lastHeldFrameAgeMS,
            lastDecisionText
        )
        lock.unlock()
        return text
    }

    private func recordTransition(
        event: String,
        previous: [String: String],
        next: [String: String],
        reason: String
    ) {
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: event,
            entityID: "recording-source-holdover",
            previous: previous,
            next: next,
            source: "RecordingWriter",
            reason: reason,
            authoritativeOwner: "BroadcastRecordingSourceClockStarvationGuard"
        )
    }

    private func trace(_ text: String, force: Bool) {
        let now = Date()
        lock.lock()
        let shouldTrace = force || now.timeIntervalSince(lastTraceAt) >= 2.0
        if shouldTrace { lastTraceAt = now }
        lock.unlock()
        guard shouldTrace else { return }
        DispatchQueue.main.async {
            MainThreadStallMonitor.shared.trace("recording \(text)")
        }
    }
}
#endif
