// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import AVFoundation

// MARK: - v0.9.1w10f Safe startup camera state reset

/// Keeps the Calibration screen out of the stranded white-preview state seen in
/// the w10e startup/crash screenshots: controls and preview should not be shown
/// until camera discovery has completed and a real OCR camera is selected.
///
/// This file intentionally contains only small Calibration-facing guards. It does
/// not change the recording renderer, OCR scheduler, media export, or camera
/// selection sheets.
@MainActor
struct CalibrationSafeStartupStateReset {
    static func discoveryIsLoading(service: HockeyCameraService) -> Bool {
        service.availableCameras.isEmpty && !service.hasConfiguredCameraSelection
    }

    static func previewMayMount(service: HockeyCameraService) -> Bool {
        guard service.hasConfiguredCameraSelection else { return false }
        guard !service.isCameraSelectionDisabled else { return false }
        // Mounting a preview against a stopped session is what produced the
        // white startup screen. Wait for the AVCaptureSession to report running.
        return service.isSessionRunning
    }

    static func controlsMayShow(service: HockeyCameraService) -> Bool {
        previewMayMount(service: service) && service.previewLayerReadyForDisplay
    }
}

extension HockeyScoreboardViewModel {
    private var multiCamOCRPreviewPlannedW10F: Bool {
        externalOCRMultiCamRequired
            || externalOCRMultiCamCoordinator.isCaptureActiveSnapshot
            || externalOCRMultiCamCoordinator.isTransitioningSnapshot
    }

    var calibrationCameraStartupLoadingW10F: Bool {
        if multiCamOCRPreviewPlannedW10F {
            let snapshot = externalOCRMultiCamCoordinator.snapshot
            return !snapshot.isActive && !snapshot.sessionConfigured
        }
        return CalibrationSafeStartupStateReset.discoveryIsLoading(service: ocrCameraService)
    }

    var calibrationCameraStartupBlockedW10F: Bool {
        if multiCamOCRPreviewPlannedW10F { return false }
        guard !calibrationCameraStartupLoadingW10F else { return false }
        guard !ocrCameraService.hasConfiguredCameraSelection else { return false }
        return !ocrCameraService.availableCameras.isEmpty || ocrCameraService.isCameraSelectionDisabled
    }

    var calibrationPreviewMountAllowedW10F: Bool {
        if multiCamOCRPreviewPlannedW10F {
            let snapshot = externalOCRMultiCamCoordinator.snapshot
            return snapshot.sessionConfigured || snapshot.isActive || snapshot.isTransitioning
        }
        return CalibrationSafeStartupStateReset.previewMayMount(service: ocrCameraService)
    }

    var calibrationCameraControlsVisibleW10F: Bool {
        if multiCamOCRPreviewPlannedW10F {
            let snapshot = externalOCRMultiCamCoordinator.snapshot
            return snapshot.isActive && snapshot.ocrFramesReceived > 0
        }
        return CalibrationSafeStartupStateReset.controlsMayShow(service: ocrCameraService)
    }

    /// One safe entry-point for Calibration startup. The screen is allowed to
    /// render immediately, but camera UI stays in a loading/recovery state until
    /// discovery has completed and the OCR session is actually running.
    func prepareSafeCalibrationStartupStateW10F(reason: String) {
        if multiCamOCRPreviewPlannedW10F {
            let snapshot = externalOCRMultiCamCoordinator.snapshot
            if snapshot.isActive && snapshot.ocrFramesReceived > 0 {
                statusMessage = nil
                MainThreadStallMonitor.shared.trace("UX16c30 safe startup: persistent MultiCam OCR endpoint ready reason=\(reason)")
            } else {
                statusMessage = "Starting MultiCam OCR / Calibration preview…"
                MainThreadStallMonitor.shared.trace("UX16c30 safe startup: waiting for persistent MultiCam OCR endpoint reason=\(reason) phase=\(snapshot.phase.rawValue)")
            }
            return
        }

        if ocrCameraService.availableCameras.isEmpty {
            statusMessage = "Refreshing OCR / Calibration camera list…"
            ocrCameraService.refreshAvailableCameras()
            liveCameraService.refreshAvailableCameras()
            MainThreadStallMonitor.shared.trace("safe startup: camera discovery requested reason=\(reason)")
            return
        }

        enforceCalibrationCameraDefaultAvoidingBroadcast(reason: "safe startup state reset - \(reason)")

        if !ocrCameraService.hasConfiguredCameraSelection {
            statusMessage = "Camera list not ready — tap Refresh Cameras"
            MainThreadStallMonitor.shared.trace("safe startup: OCR camera unresolved after discovery reason=\(reason)")
            return
        }

        if !ocrCameraService.isSessionRunning {
            statusMessage = "Starting OCR / Calibration camera…"
            MainThreadStallMonitor.shared.trace("safe startup: OCR camera selected but session not running reason=\(reason)")
            return
        }

        MainThreadStallMonitor.shared.trace("safe startup: OCR camera ready reason=\(reason)")
    }
}

#endif
