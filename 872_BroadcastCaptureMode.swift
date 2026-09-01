// BUILD 707 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import AVFoundation
import Foundation

// MARK: - RL-243 first-press recording admission

nonisolated enum RinkLensRecordingStartCaptureAdmissionAction: Sendable, Equatable {
    case awaitLifecycleAcknowledgement
    case validateActiveBroadcast
}

/// Recording may validate immediately only when CaptureEngine has physically
/// acknowledged a stable Broadcast branch. A route transaction that is still
/// installing that branch is pending readiness, not a recording-start failure.
nonisolated enum RinkLensRecordingStartCaptureAdmissionPolicy {
    static func action(
        captureIsActive: Bool,
        captureIsTransitioning: Bool,
        mode: RinkLensCaptureLifecycleMode
    ) -> RinkLensRecordingStartCaptureAdmissionAction {
        guard captureIsActive, !captureIsTransitioning, mode.requiresBroadcast else {
            return .awaitLifecycleAcknowledgement
        }
        return .validateActiveBroadcast
    }
}

// MARK: - UX16c35 CaptureEngine ownership policy

extension HockeyScoreboardViewModel {
    /// Read-only projection of the authoritative CaptureEngine mode.
    var broadcastOnlyCaptureActive: Bool {
        currentScreen == .broadcast
            && externalOCRMultiCamCoordinator.activeModeSnapshot != .dualCamera
    }

    /// Device/intent eligibility independent of the currently committed screen.
    var externalOCRMultiCamPairEligible: Bool {
        guard usesScoreboardCameraInput, userWantsOCRRunning else { return false }
        let liveIdentity = liveCameraService.captureIdentitySnapshot()
        let ocrIdentity = ocrCameraService.captureIdentitySnapshot()
        guard liveCameraService.hasConfiguredCameraSelection,
              ocrCameraService.hasConfiguredCameraSelection,
              liveIdentity.preferredResolvedPhysicalDeviceID != nil,
              ocrIdentity.preferredResolvedPhysicalDeviceID != nil,
              liveIdentity.selectedLogicalSourceID != ocrIdentity.selectedLogicalSourceID else { return false }
        // Built-in Back + Front, built-in + external, and other AVFoundation-
        // supported pairs are all valid. CaptureEngine performs the definitive
        // supportedMultiCamDeviceSets check before committing the graph.
        return true
    }

    /// Routes select presentation only. The engine may remain dual-camera across
    /// Broadcast, OCR Setup, Command Centre, Settings and Diagnostics.
    var externalOCRMultiCamRequested: Bool {
        externalOCRMultiCamPairEligible
    }

    var externalOCRMultiCamRequired: Bool {
        externalOCRMultiCamRequested
    }

    var externalOCRMultiCamActive: Bool {
        externalOCRMultiCamCoordinator.isCaptureActiveSnapshot
            && externalOCRMultiCamCoordinator.activeModeSnapshot == .dualCamera
    }

    /// These facades provide camera settings and zoom state only. They no longer
    /// expose or own the runtime preview session.
    var broadcastPreviewCameraService: HockeyCameraService { liveCameraService }
    var broadcastRecordingCameraService: HockeyCameraService { liveCameraService }

    var broadcastCameraOwnershipModeText: String {
        let mode = externalOCRMultiCamCoordinator.activeModeSnapshot
        return "CaptureEngine mode: \(mode.rawValue); one AVCaptureMultiCamSession owner"
    }

    func traceBroadcastCameraOwnershipMode(reason: String) {
        MainThreadStallMonitor.shared.trace("\(broadcastCameraOwnershipModeText) reason=\(reason)")
    }

    @MainActor
    @discardableResult
    func activateExternalOCRMultiCamIfNeeded(reason: String) async -> Bool {
        guard externalOCRMultiCamRequired else { return false }

        prepareForExternalMultiCamActivation(reason: reason)
        let liveIdentity = liveCameraService.captureIdentitySnapshot()
        let ocrIdentity = ocrCameraService.captureIdentitySnapshot()
        let outcome = await captureLifecycleController.ensure(.dualCamera(
            liveLogicalSourceID: liveIdentity.selectedLogicalSourceID,
            ocrLogicalSourceID: ocrIdentity.selectedLogicalSourceID,
            liveDeviceID: liveIdentity.preferredResolvedPhysicalDeviceID,
            ocrDeviceID: ocrIdentity.preferredResolvedPhysicalDeviceID,
            allowBroadcastFallback: true,
            reason: reason
        ))

        let started = outcome.resolvedMode == .dualCamera && outcome.succeeded
        completeExternalMultiCamActivation(started: started, status: outcome.statusText)
        applyCaptureLifecycleOutcome(outcome)
        return started
    }

    @MainActor
    func prepareBroadcastRecordingStart(
        transactionID: UUID,
        completion: @escaping (RecordingCameraFormatValidationResult) -> Void
    ) {
        let recorder = AppContainer.shared.recordingEngine
        let capture = externalOCRMultiCamCoordinator.snapshot
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "recording_verified_broadcast_source_selected",
            entityID: capture.liveDeviceID,
            previous: [
                "state": recorder.state.rawValue,
                "requestedPolicy": recorder.recordingOutputPolicySummaryText
            ],
            next: [
                "activeFormat": capture.liveFormat?.diagnosticText ?? "none",
                "captureGeneration": String(capture.transitionGeneration),
                "transactionID": transactionID.uuidString,
                "scoreboardProcessingRequired": "false"
            ],
            source: "RecordingEngine.startPreflight",
            reason: "Recording consumes the current verified Broadcast source and its native cadence; no exact-output capture mutation or OCR/Image Relay dependency is permitted",
            captureGeneration: capture.transitionGeneration,
            authoritativeOwner: "RecordingEngine"
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.completeBroadcastRecordingSourceValidation(
                transactionID: transactionID,
                requested: "Verified active Broadcast camera source",
                requiredFormat: nil,
                completion: completion
            )
        }
    }

    @MainActor
    private func completeBroadcastRecordingSourceValidation(
        transactionID: UUID,
        requested: String,
        requiredFormat: RinkLensCaptureFormatPreference?,
        completion: @escaping (RecordingCameraFormatValidationResult) -> Void
    ) async {
        let initialCapture = externalOCRMultiCamCoordinator.snapshot
        let admission = RinkLensRecordingStartCaptureAdmissionPolicy.action(
            captureIsActive: initialCapture.isActive,
            captureIsTransitioning: initialCapture.isTransitioning,
            mode: initialCapture.activeMode
        )
        if admission == .awaitLifecycleAcknowledgement {
            RinkLensStructuredEventLogger.shared.record(
                domain: .recording,
                event: "recording_start_awaiting_broadcast_readiness",
                entityID: transactionID.uuidString,
                previous: [
                    "captureActive": String(initialCapture.isActive),
                    "captureTransitioning": String(initialCapture.isTransitioning),
                    "activeMode": initialCapture.activeMode.rawValue,
                    "captureGeneration": String(initialCapture.transitionGeneration)
                ],
                next: ["preflight": "pending-physical-capture-acknowledgement"],
                source: "RecordingEngine.startPreflight",
                reason: "The first operator request joins CaptureLifecycleController's physical Broadcast transaction",
                captureGeneration: initialCapture.transitionGeneration,
                authoritativeOwner: "RecordingEngine"
            )
            let outcome = await captureLifecycleController.ensure(
                recordingCaptureReadinessRequest(
                    reason: "RL-243 first-press recording admission transaction=\(transactionID.uuidString)"
                )
            )
            guard AppContainer.shared.recordingEngine.ownsRecordingStartPreflight(transactionID) else {
                return
            }
            applyCaptureLifecycleOutcome(outcome)
            guard outcome.succeeded, outcome.resolvedMode.requiresBroadcast else {
                rejectBroadcastRecordingStart(
                    requested: requested,
                    active: externalOCRMultiCamCoordinator.liveFormatTextSnapshot,
                    reason: "CaptureLifecycleController could not physically acknowledge a Broadcast branch: \(outcome.statusText)",
                    event: "recording_preflight_broadcast_readiness_failed",
                    entityID: externalOCRMultiCamCoordinator.snapshot.liveDeviceID,
                    completion: completion
                )
                return
            }
        }

        let capture = externalOCRMultiCamCoordinator.snapshot
        guard let frame = await RinkLensFrameHub.shared.waitForFreshFrameEvidence(
            for: .broadcast,
            maxAge: 0.50,
            requiredCaptureGeneration: capture.transitionGeneration,
            requiredPhysicalDeviceID: capture.liveDeviceID,
            timeout: 1.50
        ) else {
            rejectBroadcastRecordingStart(
                requested: requested,
                active: externalOCRMultiCamCoordinator.liveFormatTextSnapshot,
                reason: "No fresh verified Broadcast frame arrived within 1.5 seconds. Image Relay and OCR frames are never substituted.",
                event: "recording_preflight_fresh_frame_timeout",
                entityID: capture.liveDeviceID,
                completion: completion
            )
            return
        }

        let refreshedCapture = externalOCRMultiCamCoordinator.snapshot
        guard refreshedCapture.transitionGeneration == frame.captureGeneration,
              refreshedCapture.liveDeviceID == frame.physicalDeviceID,
              let rawActiveFormat = refreshedCapture.liveFormat else {
            rejectBroadcastRecordingStart(
                requested: requested,
                active: externalOCRMultiCamCoordinator.liveFormatTextSnapshot,
                reason: "The verified Broadcast source changed during preflight.",
                event: "recording_preflight_source_changed",
                entityID: refreshedCapture.liveDeviceID,
                completion: completion
            )
            return
        }


        let activeFormat = rawActiveFormat

        if let requiredFormat {
            let cadenceMatches = abs(activeFormat.fps - requiredFormat.fps) <= 0.25
            guard activeFormat.width == requiredFormat.width,
                  activeFormat.height == requiredFormat.height,
                  cadenceMatches else {
                rejectBroadcastRecordingStart(
                    requested: requiredFormat.diagnosticText,
                    active: activeFormat.diagnosticText,
                    reason: "The temporary exact-output rollback did not resolve the requested dimensions and cadence.",
                    event: "recording_preflight_exact_format_mismatch",
                    entityID: refreshedCapture.liveDeviceID,
                    completion: completion
                )
                return
            }
        }

        let activeText = "\(externalOCRMultiCamCoordinator.liveFormatTextSnapshot); latest=\(frame.sizeText); generation=\(frame.captureGeneration); device=\(frame.physicalDeviceID ?? "none")"
        let sourceProfile = RecordingCameraSourceProfile(
            activeFormat: activeFormat,
            frameWidth: frame.width,
            frameHeight: frame.height,
            physicalDeviceID: frame.physicalDeviceID,
            captureGeneration: frame.captureGeneration
        )
        let validation = RecordingCameraFormatValidationResult.valid(
            requested: requested,
            active: activeText,
            sourceProfile: sourceProfile
        )
        RecordingCameraFormatValidationDiagnostics.shared.note(validation)
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "recording_camera_source_resolved",
            entityID: frame.physicalDeviceID,
            previous: [:],
            next: [
                "width": String(sourceProfile.width),
                "height": String(sourceProfile.height),
                "fps": String(sourceProfile.framesPerSecond),
                "generation": String(sourceProfile.captureGeneration),
                "scoreboardProcessingRequired": "false"
            ],
            source: "CaptureEngine verified Broadcast frame",
            reason: "Recording profile derives from the current physical Broadcast source independently of Image Relay and OCR",
            captureGeneration: frame.captureGeneration,
            authoritativeOwner: "RecordingEngine"
        )
        completion(validation)
    }


    @MainActor
    private func rejectBroadcastRecordingStart(
        requested: String,
        active: String,
        reason: String,
        event: String,
        entityID: String?,
        completion: @escaping (RecordingCameraFormatValidationResult) -> Void
    ) {
        let validation = RecordingCameraFormatValidationResult.invalid(
            requested: requested,
            active: active,
            reason: reason
        )
        RecordingCameraFormatValidationDiagnostics.shared.note(validation)
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: event,
            entityID: entityID,
            previous: [
                "recordingState": AppContainer.shared.recordingEngine.state.rawValue,
                "requested": requested
            ],
            next: [
                "recordingState": "blocked",
                "active": active
            ],
            source: "BroadcastRecordingQuickControls",
            reason: reason,
            captureGeneration: externalOCRMultiCamCoordinator.snapshot.transitionGeneration,
            authoritativeOwner: "RecordingEngine"
        )
        completion(validation)
    }


    @MainActor
    func deactivateExternalOCRMultiCam(reason: String) async {
        let outcome = await captureLifecycleController.stopMultiCam(reason: reason)
        applyCaptureLifecycleOutcome(outcome)
        resetOCRMotionProtectionAfterCameraOwnershipChange(reason: "UX16c35 CaptureEngine stopped: \(reason)")
        MainThreadStallMonitor.shared.traceCameraStartupTimeline("UX16c35 CaptureEngine ownership released: \(reason)")
    }

    // UX16d2: route/view disappearance is presentation-only. CaptureEngine
    // teardown is reserved for explicit stop, background, interruption or fatal error.

}

#endif
