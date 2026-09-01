// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import Foundation

// MARK: - Build 653 operator logging hub

/// The operator-facing Diagnostics route is now deliberately logs-only.
/// Camera, OCR and Recording diagnostics continue to collect evidence for the
/// exported support bundle, but they are no longer separate operator pages.
struct DiagnosticsHubView: View {
    let viewModel: HockeyScoreboardViewModel
    let cameraService: HockeyCameraService

    @ObservedObject private var monitor = MainThreadStallMonitor.shared
    @State private var advancedExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DebugLoggingPanel(
                monitor: monitor,
                viewModel: viewModel,
                cameraService: cameraService
            )

            if monitor.diagnosticsMode == .engineering {
                DisclosureGroup(isExpanded: $advancedExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        RecoveryActionsPanel(viewModel: viewModel, cameraService: cameraService)

                        if !RinkLensRiskFeaturePolicy.isEnabled(.minimalOperatorCameraRecordingV12) {
                            PhysicalValidationPanel(controller: .shared)
                        }
                    }
                    .padding(.top, 10)
                } label: {
                    Label(
                        RinkLensRiskFeaturePolicy.isEnabled(.minimalOperatorCameraRecordingV12) ? "Recovery" : "Engineering Recovery & Validation",
                        systemImage: "wrench.and.screwdriver"
                    )
                    .font(RinkLensDesignSystem.font(.caption))
                    .foregroundStyle(RinkLensDesignSystem.secondaryText)
                }
                .padding(12)
                .background(.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .onAppear {
            stopLiveDiagnosticPublishing()
            normaliseOperatorLoggingMode()
        }
        .onDisappear {
            stopLiveDiagnosticPublishing()
        }
        .onChange(of: monitor.diagnosticsMode) { _, newMode in
            if newMode != .engineering {
                advancedExpanded = false
            }
        }
    }

    /// Production is the existing low-overhead operational mode. Build 653
    /// presents it to the operator as Match Day rather than exposing the older
    /// Production/Rink Test/Match Day Safe implementation choices.
    private func normaliseOperatorLoggingMode() {
        guard monitor.diagnosticsMode != .production,
              monitor.diagnosticsMode != .engineering else { return }
        monitor.setDiagnosticsMode(.production, reason: "Build 653 two-mode operator logging")
    }

    /// Opening Logs must not turn on per-frame Camera or OCR diagnostics. Their
    /// evidence journals and critical errors remain part of Support Logs.
    private func stopLiveDiagnosticPublishing() {
        cameraService.setDiagnosticsPublishingVisible(false)
        viewModel.liveCameraService.setDiagnosticsPublishingVisible(false)
        viewModel.ocrCameraService.setDiagnosticsPublishingVisible(false)
        viewModel.setOCRDiagnosticsVisible(false)
        MainThreadStallMonitor.shared.trace("Build 653 logs-only diagnostics view active")
    }
}
#endif
