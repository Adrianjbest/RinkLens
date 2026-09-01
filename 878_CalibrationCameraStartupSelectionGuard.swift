// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
#if canImport(AVFoundation)
import AVFoundation
#endif

// MARK: - v0.9.1w10a Calibration camera startup selection guard

/// Keeps Calibration/OCR from defaulting onto the same physical camera used by
/// Broadcast at startup.
///
/// v0.9.1w10a correction:
/// - If Broadcast has no selected camera yet, Calibration is allowed to choose a
///   normal camera. Do not show the same-camera warning with "Broadcast is using
///   No camera".
/// - If camera discovery has not populated yet, wait for discovery instead of
///   setting OCR to None.
/// - Only set OCR to None when Broadcast already owns the only available camera.
@MainActor
struct CalibrationCameraStartupSelectionGuard {
    static func preferredCalibrationCameraID(
        liveCameraID: String?,
        options: [HockeyCameraService.CameraOption]
    ) -> String? {
        // Preserve a separate external source when available, but do not force
        // built-in Broadcast and OCR onto different logical source IDs. UX16c10+
        // releases the inactive built-in session during route hand-off, so Back or
        // Front may be selected for both roles without simultaneous ownership.
        if let external = options.first(where: { option in
            option.isExternal && option.isAvailable && (liveCameraID == nil || option.id != liveCameraID)
        }) {
            return external.id
        }
        if let back = options.first(where: { $0.position == .back && $0.isAvailable }) {
            return back.id
        }
        if let front = options.first(where: { $0.position == .front && $0.isAvailable }) {
            return front.id
        }
        return options.first(where: { $0.isAvailable })?.id
    }

    static func conflictMessage(liveLabel: String, liveCameraID: String?) -> String {
        guard liveCameraID != nil else {
            return "Select an OCR / Calibration camera. Broadcast has no camera selected yet, so Calibration may use an available built-in or external camera."
        }
        return "Calibration/OCR cannot use the same camera as Broadcast. Broadcast is using \(liveLabel). Select an external calibration camera, or choose another built-in camera for Calibration."
    }
}

extension HockeyScoreboardViewModel {
    var calibrationCameraSharingConflictActive: Bool {
        guard let liveID = liveCameraService.selectedCameraID,
              let ocrID = ocrCameraService.selectedCameraID,
              liveID == ocrID else { return false }
        return liveID == HockeyCameraService.externalCameraSourceID
    }

    var calibrationCameraUnavailableBecauseSharedWithBroadcast: Bool {
        guard liveCameraService.selectedCameraID != nil else { return false }
        guard ocrCameraService.selectedCameraID == nil else { return false }
        return ocrCameraService.isCameraSelectionDisabled
    }

    var calibrationCameraConflictTitle: String {
        if calibrationCameraSharingConflictActive { return "Select another Calibration camera" }
        if calibrationCameraUnavailableBecauseSharedWithBroadcast { return "Calibration camera unavailable" }
        return "OCR camera not selected"
    }

    var calibrationCameraConflictMessage: String {
        CalibrationCameraStartupSelectionGuard.conflictMessage(
            liveLabel: liveCameraService.selectedCameraLabel,
            liveCameraID: liveCameraService.selectedCameraID
        )
    }

    /// Startup/default selection rule:
    /// 1. external Calibration camera if available and not used by Broadcast;
    /// 2. if Broadcast has no camera yet, choose a normal Calibration camera;
    /// 3. otherwise choose any camera that Broadcast is not using;
    /// 4. only set Calibration/OCR to None if Broadcast already owns the sole source.
    func enforceCalibrationCameraDefaultAvoidingBroadcast(reason: String) {
        if ocrCameraService.availableCameras.isEmpty {
            ocrCameraService.refreshAvailableCameras()
            statusMessage = "Refreshing OCR / Calibration camera list…"
            MainThreadStallMonitor.shared.trace("calibration camera startup guard waiting for OCR camera discovery: reason=\(reason)")
            return
        }

        if liveCameraService.availableCameras.isEmpty {
            liveCameraService.refreshAvailableCameras()
        }

        let liveID = liveCameraService.isCameraSelectionDisabled ? nil : liveCameraService.selectedCameraID
        let currentOCRID = ocrCameraService.isCameraSelectionDisabled ? nil : ocrCameraService.selectedCameraID

        // Recovery Z / RL-059: the persisted Calibration/OCR logical source is
        // setup intent, while discovery only reports availability. If a saved
        // source exists, re-project that exact source into the runtime service and
        // never replace it merely because another camera is currently available.
        if let savedOCRID = calibrationCameraProfile.selectedCameraSourceID {
            if currentOCRID != savedOCRID || ocrCameraService.isCameraSelectionDisabled {
                _ = ocrCameraService.stageLogicalCameraSource(
                    savedOCRID,
                    reason: "Recovery Z authoritative saved OCR source projection: \(reason)"
                )
            }
            let savedOption = ocrCameraService.availableCameras.first(where: { $0.id == savedOCRID })
            if savedOCRID == HockeyCameraService.externalCameraSourceID,
               savedOption?.isAvailable != true {
                projectCalibrationCameraWarning(
                    "Saved External Camera selection retained — USB camera is not connected.",
                    reason: "Recovery Z1 authoritative saved OCR source unavailable: \(reason)"
                )
                statusMessage = "External OCR camera is not connected. The saved External Camera selection is retained."
            } else {
                projectCalibrationCameraWarning(
                    nil,
                    reason: "Recovery Z1 authoritative saved OCR source available: \(reason)"
                )
            }
            MainThreadStallMonitor.shared.trace(
                "Recovery Z calibration startup guard retained authoritative saved OCR source=\(savedOCRID) reason=\(reason)"
            )
            return
        }

        // If Broadcast has no selected camera, do not treat the current OCR camera
        // as a conflict. This is the startup case that previously produced the bad
        // "Broadcast is using No camera" banner and left Calibration disabled.
        if liveID == nil, currentOCRID != nil {
            MainThreadStallMonitor.shared.trace("calibration camera startup guard kept OCR camera because Broadcast has no camera: reason=\(reason)")
            return
        }

        if let currentOCRID {
            let sameExternalConflict =
                currentOCRID == liveID &&
                currentOCRID == HockeyCameraService.externalCameraSourceID
            if !sameExternalConflict {
                MainThreadStallMonitor.shared.trace("UX16c13 calibration startup guard kept existing logical source (same built-in is allowed): reason=\(reason)")
                return
            }
        }

        let preferredID = CalibrationCameraStartupSelectionGuard.preferredCalibrationCameraID(
            liveCameraID: liveID,
            options: ocrCameraService.availableCameras
        )

        guard let preferredID else {
            // UX16c13: never turn a transient discovery/allocation result into an
            // explicit user-disabled None state. Keep the existing request and let
            // the next connect/discovery event resolve it.
            statusMessage = "No OCR / Calibration camera is currently available. The saved selection has been retained."
            MainThreadStallMonitor.shared.trace("UX16c13 calibration startup guard found no camera; selection retained reason=\(reason)")
            return
        }

        guard preferredID != currentOCRID else { return }
        selectCalibrationCameraSource(id: preferredID)

        let selectedName = ocrCameraService.availableCameras.first(where: { $0.id == preferredID })?.name ?? "separate camera"
        if liveID == nil {
            statusMessage = "Calibration camera set to \(selectedName). Broadcast has no selected camera yet."
        } else {
            statusMessage = "Calibration camera set to \(selectedName) so Broadcast and Calibration do not share the same camera."
        }
        MainThreadStallMonitor.shared.trace("calibration camera startup guard selected \(selectedName): reason=\(reason)")
    }
}

#endif
