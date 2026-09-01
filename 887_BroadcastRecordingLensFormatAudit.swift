// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
import AVFoundation
import Foundation

// MARK: - v0.9.1w10i 60fps lens format audit

nonisolated enum BroadcastRecordingLensFormatAudit {
    /// Reasserts the active recording cadence after Broadcast zoom/lens changes.
    /// This does not pick a new format; it verifies the active lens/format and locks
    /// min/max frame duration back to the requested cadence when the format supports it.
    @discardableResult
    static func reassertActiveFormatCadence(
        on device: AVCaptureDevice,
        targetFPS: Int,
        reason: String,
        trace: (String) -> Void
    ) -> String {
        reassertActiveFormatCadence(
            on: device,
            targetCadence: RinkLensCaptureCadence(integerFPS: max(1, min(60, targetFPS))),
            reason: reason,
            trace: trace
        )
    }

    /// UX16c41 exact-cadence overload. Live zoom/focus changes must preserve the
    /// active 29.97/59.94 contract rather than silently rounding it to 30/60.
    @discardableResult
    static func reassertActiveFormatCadence(
        on device: AVCaptureDevice,
        targetCadence: RinkLensCaptureCadence,
        reason: String,
        trace: (String) -> Void
    ) -> String {
        let requestedFPS = targetCadence.framesPerSecond
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let beforeMin = fpsText(device.activeVideoMinFrameDuration)
        let beforeMax = fpsText(device.activeVideoMaxFrameDuration)
        let deviceSummary = "\(device.localizedName) \(dims.width)x\(dims.height) beforeMin=\(beforeMin) beforeMax=\(beforeMax)"

        guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
            $0.minFrameRate <= requestedFPS + 0.005 && $0.maxFrameRate >= requestedFPS - 0.005
        }) else {
            let message = "cadence audit failed reason=active format does not support target target=\(targetCadence.displayText)fps \(deviceSummary) source=\(reason)"
            trace(message)
            return message
        }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.activeVideoMinFrameDuration = targetCadence.duration
            device.activeVideoMaxFrameDuration = targetCadence.duration
        } catch {
            let message = "cadence audit failed reason=lock error target=\(targetCadence.displayText)fps error=\(error.localizedDescription) \(deviceSummary) source=\(reason)"
            trace(message)
            return message
        }

        let afterMin = fpsText(device.activeVideoMinFrameDuration)
        let afterMax = fpsText(device.activeVideoMaxFrameDuration)
        let message = "cadence audit reasserted target=\(targetCadence.displayText)fps duration=\(targetCadence.durationValue)/\(targetCadence.durationTimescale) \(deviceSummary) afterMin=\(afterMin) afterMax=\(afterMax) source=\(reason)"
        trace(message)
        return message
    }

    private static func fpsText(_ duration: CMTime) -> String {
        guard duration.value > 0 else { return "unknown" }
        let fps = Double(duration.timescale) / Double(duration.value)
        return String(format: "%.1ffps", fps)
    }
}
