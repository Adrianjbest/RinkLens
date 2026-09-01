// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import AVFoundation
import Foundation

/// v0.8.3b: Focused adapter for the OCR camera settings sheet.
///
/// The camera settings sheet used to observe the full HockeyScoreboardViewModel,
/// which meant high-frequency OCR state publishes could invalidate the camera
/// settings form while the operator was changing hardware settings. This small
/// view model exposes only the camera controls required by the sheet and
/// delegates the real camera operations back to the root ViewModel so existing
/// OCR start/stop, template persistence and guard-rail behaviour stays intact.
@MainActor
final class OCRCameraSettingsViewModel: ObservableObject {
    private weak var rootViewModel: HockeyScoreboardViewModel?

    let ocrCameraService: HockeyCameraService

    var cameraZoomFactor: CGFloat {
        rootViewModel?.cameraZoomFactor ?? ocrCameraService.currentZoomFactor
    }

    var ocrPreviewRotationOffsetDegrees: CGFloat {
        rootViewModel?.ocrPreviewRotationOffsetDegrees ?? 0
    }

    init(viewModel: HockeyScoreboardViewModel) {
        self.rootViewModel = viewModel
        self.ocrCameraService = viewModel.ocrCameraService
    }

    func beginCameraSettingsInteraction() {
        rootViewModel?.beginCameraSettingsInteraction()
        syncFromRoot()
    }

    func endCameraSettingsInteraction() {
        rootViewModel?.endCameraSettingsInteraction()
        syncFromRoot()
    }


    var hasExternalOCRCamera: Bool {
        ocrCameraService.availableCameras.contains { $0.isExternal && $0.isAvailable }
    }

    var ocrExternalCameraStatusText: String {
        if let selected = ocrCameraService.availableCameras.first(where: { $0.id == ocrCameraService.selectedCameraID }), selected.isExternal {
            return selected.isAvailable
                ? "External OCR camera active"
                : "External Camera selected — waiting for USB connection"
        }
        if ocrCameraService.availableCameras.contains(where: { $0.isExternal && $0.isAvailable }) {
            return "External camera detected. Tap Use External or select it from the picker."
        }
        return "External Camera remains selectable but is not currently connected."
    }

    func selectFirstExternalOCRCamera() {
        if ocrCameraService.availableCameras.isEmpty {
            refreshAvailableCameras()
        }
        guard let externalID = ocrCameraService.availableCameras.first(where: { $0.isExternal && $0.isAvailable })?.id else {
            syncFromRoot()
            return
        }
        rootViewModel?.selectOCRCamera(id: externalID)
        syncFromRoot()
    }

    func refreshAvailableCameras() {
        ocrCameraService.refreshAvailableCameras()
        syncFromRoot()
    }

    func selectOCRCamera(id: String?) {
        rootViewModel?.selectOCRCamera(id: id)
        syncFromRoot()
    }

    func selectOCRCapabilityProfile(id: String) {
        rootViewModel?.selectOCRCapabilityProfile(id: id)
        syncFromRoot()
    }

    func applyOCRRoleDefaultProfile() {
        rootViewModel?.applyOCRDefaultCameraProfile()
        syncFromRoot()
    }

    func setAutomaticLensControls(_ enabled: Bool) {
        rootViewModel?.setOCRCameraAppleStyleAutoQuality(enabled)
        syncFromRoot()
    }

    func recoverPreview() {
        rootViewModel?.requestCameraPreviewRecovery(
            for: ocrCameraService,
            reason: "operator recover from OCR camera settings"
        )
        syncFromRoot()
    }

    func setOCRCameraZoom(_ zoom: CGFloat) {
        rootViewModel?.setOCRCameraZoom(zoom)
        syncFromRoot()
    }

    func rotateOCRPreviewClockwise() {
        rootViewModel?.rotateOCRPreviewClockwise()
        syncFromRoot()
    }

    func rotateOCRPreviewCounterClockwise() {
        rootViewModel?.rotateOCRPreviewCounterClockwise()
        syncFromRoot()
    }

    func resetOCRPreviewRotation() {
        rootViewModel?.resetOCRPreviewRotation()
        syncFromRoot()
    }

    private func syncFromRoot() {
        objectWillChange.send()
    }
}

#endif
