// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
import Foundation

// MARK: - v0.9.1w10g Manual OCR Disable Confirmation Restore
//
// Keeps the manual-score OCR-disable confirmation isolated from the camera,
// recording and OCR scheduler fixes. BroadcastView owns the SwiftUI dialog;
// this extension owns the policy/breadcrumbs so every manual entry point can
// reuse the same wording without touching the large ViewModel body.
@MainActor
extension HockeyScoreboardViewModel {

    var requiresManualOCRDisableConfirmation: Bool {
        guard !manualOverrideEnabled else { return false }

        // Prompt whenever OCR is actively running, has been requested for
        // Broadcast keepalive, or the app is still in OCR operating mode.
        // This restores the pre-regression behaviour where manual controls
        // never silently disabled OCR.
        return isOCREffectiveRunning || userWantsOCRRunning || isOCRMode
    }

    func manualOCRDisableConfirmationMessage(for action: String) -> String {
        "Manual \(action) will switch the scoreboard to Manual Mode and disable OCR updates until OCR is re-enabled."
    }

    func noteManualOCRDisableConfirmationRequested(action: String) {
        MainThreadStallMonitor.shared.trace("manual override confirmation requested: \(action)")
        statusMessage = "Manual control will disable OCR. Confirm to continue."
    }

    func acceptManualOCRDisableConfirmation(action: String) {
        MainThreadStallMonitor.shared.trace("manual override confirmation accepted: \(action)")
        setOperatingMode(.manual)
        MainThreadStallMonitor.shared.trace("manual override disabled OCR: \(action)")
        statusMessage = "Manual Mode enabled. OCR updates are disabled."
    }

    func cancelManualOCRDisableConfirmation(action: String) {
        MainThreadStallMonitor.shared.trace("manual override confirmation cancelled: \(action)")
        statusMessage = "Manual change cancelled. OCR remains enabled."
    }
}

