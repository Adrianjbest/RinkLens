// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI

// MARK: - Legacy screen value contract

/// Internal camera/OCR presentation classification retained for subsystem policy.
/// Visible NextGen navigation is owned exclusively by AppCoordinator/AppRoute.
enum AppScreen: String, CaseIterable, Identifiable {
    case live = "Live"
    case calibration = "Calibration"
    case overlay = "Output"
    case broadcast = "Broadcast"
    var id: String { rawValue }
}

// Build 785 R4 deleted the unused ContentView route host and its view-local
// pending-screen, transition-task and operator "Switching to…" overlay state.

#endif
