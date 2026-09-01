// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI

// STYLE2 central design system migration: operator chrome/fonts use RinkLensDesignSystem where safe.
import UIKit

// MARK: - RinkLens NextGen Stage 6A Scoreboard Setup Module

/// Dedicated scoreboard setup route for the NextGen shell.
///
/// This view deliberately reuses the existing CalibrationScreen and OCR engine
/// rather than creating a second camera/OCR owner. The existing calibration UI
/// remains responsible for region setup, camera selection, OCR test controls,
/// template/profile management and pixel-hash diagnostics. Stage 6A only moves
/// that workflow out of Broadcast routing and surrounds it with a lightweight
/// NextGen module shell.
struct OCRSetupRouteShellView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var appContainer: AppContainer

    var body: some View {
        OCRSetupView(
            viewModel: appContainer.scoreboardViewModel,
            onReturnToCommandCentre: {
                MainThreadStallMonitor.shared.markContext("RNG-S6A route change requested: Scoreboard Setup -> Command Centre")
                coordinator.navigate(to: .commandCentre)
            }
        )

    }
}

struct OCRSetupView: View {
    @ObservedObject private var viewModel: HockeyScoreboardViewModel
    let onReturnToCommandCentre: () -> Void

    init(viewModel: HockeyScoreboardViewModel, onReturnToCommandCentre: @escaping () -> Void) {
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self.onReturnToCommandCentre = onReturnToCommandCentre
    }

    var body: some View {
        GeometryReader { proxy in
            CalibrationScreen(
                viewModel: viewModel,
                onReturnToCommandCentre: onReturnToCommandCentre
            )
            .onAppear {
                CameraOwnershipTraceStore.record(.route, owner: .calibration, reason: "Scoreboard Setup nested Calibration view appeared | \(viewModel.diagnosticIdentityText)")
                // UX16c17: The route shell owns camera startup ordering. Keep this
                // nested onAppear UI-only so it cannot race a second camera start.
                viewModel.setOCRDiagnosticsVisible(true)
                viewModel.ocrCameraService.setDiagnosticsPublishingVisible(true)
                MainThreadStallMonitor.shared.markContext("Build 621 Scoreboard Setup mounted - route already committed; CalibrationScreen owns all OCR chrome")
                AppContainer.shared.runtimeStatus.markOCRSetupVisible(
                    templateName: viewModel.activeTemplateName,
                    operationalStatus: viewModel.ocrOperationalStatus
                )
            }
            .onChange(of: proxy.size) { _, newSize in
                MainThreadStallMonitor.shared.traceRenderPreviewToggle(String(format: "OCRSetupView outer size %.0fx%.0f; CalibrationScreen owns OCR crop viewport", newSize.width, newSize.height))
            }
            .onChange(of: viewModel.activeTemplateID) { _, _ in
                AppContainer.shared.runtimeStatus.markOCRSetupVisible(
                    templateName: viewModel.activeTemplateName,
                    operationalStatus: viewModel.ocrOperationalStatus
                )
            }
            .onDisappear {
                CameraOwnershipTraceStore.record(.route, owner: .calibration, reason: "Scoreboard Setup nested Calibration view disappeared | \(viewModel.diagnosticIdentityText)")
                MainThreadStallMonitor.shared.markContext("Build 621 Scoreboard Setup module disappeared without stopping OCR camera services")
            }
        }
        .rinkLensOperatorChrome("Scoreboard Setup")
        .preferredColorScheme(.dark)
    }

}

#endif
