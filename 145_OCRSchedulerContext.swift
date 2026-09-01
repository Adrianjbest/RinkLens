// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation
import CoreFoundation

// MARK: - v0.8.8m7 Central OCR Scheduler Context

/// Lightweight game/screen state passed into OCRScheduler.
///
/// This type is intentionally value-only. It must not own camera sessions,
/// preview layers, OCR processors, SwiftUI views or recording objects.
struct OCRGameState: Equatable {
    var activeScreen: AppScreen
    var clockIsRunning: Bool
    var clockIsConfirmedStopped: Bool
    var manualModeEnabled: Bool
    var debugModeEnabled: Bool
    var diagnosticsVisible: Bool
    var calibrationVisible: Bool
    var performanceSafeModeEnabled: Bool
    var motionProtectionActive: Bool
    var hasActivePenaltyOCRWork: Bool
    var regionChangeState: OCRRegionChangeState

    init(
        activeScreen: AppScreen,
        clockIsRunning: Bool,
        clockIsConfirmedStopped: Bool,
        manualModeEnabled: Bool,
        debugModeEnabled: Bool,
        diagnosticsVisible: Bool,
        calibrationVisible: Bool,
        performanceSafeModeEnabled: Bool,
        motionProtectionActive: Bool,
        hasActivePenaltyOCRWork: Bool,
        regionChangeState: OCRRegionChangeState = .unknown
    ) {
        self.activeScreen = activeScreen
        self.clockIsRunning = clockIsRunning
        self.clockIsConfirmedStopped = clockIsConfirmedStopped
        self.manualModeEnabled = manualModeEnabled
        self.debugModeEnabled = debugModeEnabled
        self.diagnosticsVisible = diagnosticsVisible
        self.calibrationVisible = calibrationVisible
        self.performanceSafeModeEnabled = performanceSafeModeEnabled
        self.motionProtectionActive = motionProtectionActive
        self.hasActivePenaltyOCRWork = hasActivePenaltyOCRWork
        self.regionChangeState = regionChangeState
    }
}

/// Explicit scheduler mode for debug breadcrumbs and diagnostics.
enum OCRSchedulerMode: String, Equatable {
    case idle
    case runningClock
    case stoppedClockEventWindow
    case longStoppage
    case calibration
    case debug
    case manual

    var title: String { rawValue }
}

/// Penalty-specific state passed to the scheduler when deciding if one slot
/// should be sampled. The scheduler does not parse or validate penalty values.
struct PenaltySlotState: Equatable {
    var isVisible: Bool
    var isLockedOrAccepted: Bool
    var regionChanged: Bool
    var lastRunAt: CFTimeInterval?
    var safetyInterval: CFTimeInterval

    init(
        isVisible: Bool,
        isLockedOrAccepted: Bool,
        regionChanged: Bool,
        lastRunAt: CFTimeInterval?,
        safetyInterval: CFTimeInterval
    ) {
        self.isVisible = isVisible
        self.isLockedOrAccepted = isLockedOrAccepted
        self.regionChanged = regionChanged
        self.lastRunAt = lastRunAt
        self.safetyInterval = safetyInterval
    }
}
#endif
