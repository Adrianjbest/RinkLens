// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(AVFoundation)
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

/// v0.9.1w10b: Captures and restores the requested focus / exposure / white-balance controls
/// as one step inside the authoritative camera transaction.
///
/// AVFoundation may re-settle focus when a virtual back camera crosses its
/// switch-over point, or when the app rebuilds the capture input for a physical
/// lens switch. CaptureLifecycleController/CaptureEngine owns when this operation runs. The type
/// is an operation, not a separate state owner or a failure-catching guard.
nonisolated struct BroadcastCameraControlState {
    let deviceID: String
    let deviceName: String
    let deviceType: String
    let focusMode: AVCaptureDevice.FocusMode
    let exposureMode: AVCaptureDevice.ExposureMode
    let whiteBalanceMode: AVCaptureDevice.WhiteBalanceMode
    let focusPoint: CGPoint
    let lensPosition: Float
    let isAdjustingFocus: Bool
    let exposureDurationSeconds: Double
    let iso: Float
    let minFrameDurationSeconds: Double
    let maxFrameDurationSeconds: Double
    let formatSummary: String
    let smoothAutoFocusEnabled: Bool?
}

nonisolated enum BroadcastCameraControlTransaction {

    static func captureRequestedControls(
        device: AVCaptureDevice?,
        label: String,
        trace: (String) -> Void
    ) -> BroadcastCameraControlState? {
        guard let device else {
            trace("focus snapshot label=\(label) skipped reason=no-active-device")
            return nil
        }

        let state = BroadcastCameraControlState(
            deviceID: device.uniqueID,
            deviceName: device.localizedName,
            deviceType: device.deviceType.rawValue,
            focusMode: device.focusMode,
            exposureMode: device.exposureMode,
            whiteBalanceMode: device.whiteBalanceMode,
            focusPoint: device.focusPointOfInterest,
            lensPosition: device.lensPosition,
            isAdjustingFocus: device.isAdjustingFocus,
            exposureDurationSeconds: CMTimeGetSeconds(device.exposureDuration),
            iso: device.iso,
            minFrameDurationSeconds: CMTimeGetSeconds(device.activeVideoMinFrameDuration),
            maxFrameDurationSeconds: CMTimeGetSeconds(device.activeVideoMaxFrameDuration),
            formatSummary: formatSummary(for: device),
            smoothAutoFocusEnabled: device.isSmoothAutoFocusSupported ? device.isSmoothAutoFocusEnabled : nil
        )

        trace("focus snapshot label=\(label) \(summary(state))")
        return state
    }

    @discardableResult
    static func restoreRequestedControls(
        to device: AVCaptureDevice,
        previous: BroadcastCameraControlState?,
        reason: String,
        trace: (String) -> Void
    ) -> Bool {
        let before = captureRequestedControls(device: device, label: "before restore \(reason)", trace: trace)
        guard let previous else {
            trace("camera controls restore skipped reason=\(reason) cause=no-previous-state active=\(device.localizedName) format=\(formatSummary(for: device))")
            return false
        }

        do {
            try device.lockForConfiguration()

            if device.isFocusPointOfInterestSupported {
                let point = CGPoint(
                    x: min(max(previous.focusPoint.x, 0.0), 1.0),
                    y: min(max(previous.focusPoint.y, 0.0), 1.0)
                )
                device.focusPointOfInterest = point
            }

            if previous.focusMode == .locked {
                if device.isFocusModeSupported(.locked) {
                    if device.isLockingFocusWithCustomLensPositionSupported {
                        let lensPosition = min(max(previous.lensPosition, 0.0), 1.0)
                        device.setFocusModeLocked(lensPosition: lensPosition, completionHandler: nil)
                    } else {
                        device.focusMode = .locked
                    }
                    if device.isSmoothAutoFocusSupported {
                        device.isSmoothAutoFocusEnabled = false
                    }
                } else if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                } else if device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus
                }
            } else if device.isFocusModeSupported(previous.focusMode) {
                device.focusMode = previous.focusMode
                if let smooth = previous.smoothAutoFocusEnabled, device.isSmoothAutoFocusSupported {
                    device.isSmoothAutoFocusEnabled = smooth
                }
            } else if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            } else if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            }

            if previous.exposureMode == .locked, device.isExposureModeSupported(.locked) {
                device.exposureMode = .locked
            } else if previous.exposureMode == .custom, device.isExposureModeSupported(.custom) {
                let duration = CMTime(seconds: max(previous.exposureDurationSeconds, 0.0), preferredTimescale: 1_000_000_000)
                let clampedISO = min(max(previous.iso, device.activeFormat.minISO), device.activeFormat.maxISO)
                device.setExposureModeCustom(duration: duration, iso: clampedISO, completionHandler: nil)
            } else if device.isExposureModeSupported(previous.exposureMode) {
                device.exposureMode = previous.exposureMode
            } else if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            } else if device.isExposureModeSupported(.autoExpose) {
                device.exposureMode = .autoExpose
            }

            if previous.whiteBalanceMode == .locked, device.isWhiteBalanceModeSupported(.locked) {
                device.whiteBalanceMode = .locked
            } else if device.isWhiteBalanceModeSupported(previous.whiteBalanceMode) {
                device.whiteBalanceMode = previous.whiteBalanceMode
            } else if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            } else if device.isWhiteBalanceModeSupported(.autoWhiteBalance) {
                device.whiteBalanceMode = .autoWhiteBalance
            }

            let minDurationBefore = device.activeVideoMinFrameDuration
            let maxDurationBefore = device.activeVideoMaxFrameDuration
            if minDurationBefore.isValid && maxDurationBefore.isValid {
                // Preserve the current capture cadence. This guard must not silently
                // relax a 60fps format while fixing focus after zoom.
                device.activeVideoMinFrameDuration = minDurationBefore
                device.activeVideoMaxFrameDuration = maxDurationBefore
            }

            device.unlockForConfiguration()
        } catch {
            trace("camera controls restore failed reason=\(reason) active=\(device.localizedName) error=\(error.localizedDescription)")
            return false
        }

        let after = captureRequestedControls(device: device, label: "after restore \(reason)", trace: trace)
        trace("camera controls restore applied reason=\(reason) previous=\(summary(previous)) before=\(before.map(summary) ?? "none") after=\(after.map(summary) ?? "none")")
        return true
    }

    private static func summary(_ state: BroadcastCameraControlState) -> String {
        let smooth = state.smoothAutoFocusEnabled.map { $0 ? "true" : "false" } ?? "unsupported"
        return "device=\(state.deviceName) type=\(state.deviceType) focus=\(state.focusMode.rawValue) point=\(String(format: "%.3f", Double(state.focusPoint.x))),\(String(format: "%.3f", Double(state.focusPoint.y))) lens=\(String(format: "%.3f", Double(state.lensPosition))) adjusting=\(state.isAdjustingFocus) exposure=\(state.exposureMode.rawValue) iso=\(String(format: "%.1f", Double(state.iso))) wb=\(state.whiteBalanceMode.rawValue) smoothAF=\(smooth) format=\(state.formatSummary)"
    }

    private static func formatSummary(for device: AVCaptureDevice) -> String {
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let minFPS = fps(from: device.activeVideoMinFrameDuration)
        let maxFPS = fps(from: device.activeVideoMaxFrameDuration)
        let supportedMax = device.activeFormat.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        return "\(dims.width)x\(dims.height) minFPS=\(String(format: "%.1f", minFPS)) maxFPS=\(String(format: "%.1f", maxFPS)) supportedMax=\(String(format: "%.1f", supportedMax)) zoom=\(String(format: "%.2f", Double(device.videoZoomFactor)))"
    }

    private static func fps(from duration: CMTime) -> Double {
        guard duration.isValid, duration.value > 0 else { return 0 }
        return Double(duration.timescale) / Double(duration.value)
    }
}
#endif
