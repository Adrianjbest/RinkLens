// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - RinkLens NextGen Stage 11A Diagnostics Module

struct DiagnosticsRouteShellView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var appContainer: AppContainer
    @EnvironmentObject private var runtimeStatus: AppRuntimeStatus
    @ObservedObject private var diagnosticsService: DiagnosticsService
    @ObservedObject private var logExporter = DiagnosticsLogExporter.shared
    @State private var shareItem: RinkLensDiagnosticsShareItem?
    @State private var lastDiagnosticsRefresh = Date.distantPast

    private let refreshTimer = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()

    init(diagnosticsService: DiagnosticsService) {
        self._diagnosticsService = ObservedObject(wrappedValue: diagnosticsService)
    }

    var body: some View {
        ZStack {
            DiagnosticsModuleBackground()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    header
                    warningBanner
                    screenScopedDiagnostics
                    exportCard
                }
                .rinkLensHeavyScreenContent(maxWidth: 1180, horizontal: 26, vertical: 22)
                .padding(.top, RinkLensCommandCentreChrome.scrollContentTopClearance)
            }
            .rinkLensScrollPerformance("Diagnostics")
        }
        .preferredColorScheme(.dark)
        .rinkLensCommandCentreReturnButton {
            MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("Diagnostics -> Command Centre"))
            coordinator.navigate(to: .commandCentre)
        }
        .onAppear { refreshDiagnostics(reason: "appear") }
        .onReceive(refreshTimer) { _ in refreshDiagnostics(reason: "timer") }
        #if canImport(UIKit)
        .sheet(item: $shareItem) { item in
            RinkLensDiagnosticsShareSheet(url: item.url)
        }
        #endif
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Logs", systemImage: "doc.text.magnifyingglass")
                    .font(RinkLensDesignSystem.font(.screenTitle))
                    .foregroundStyle(RinkLensDesignSystem.primaryText)

                Text("Choose Match Day or Engineering logging, then export one complete support bundle.")
                    .font(RinkLensDesignSystem.font(.body))
                    .foregroundStyle(RinkLensDesignSystem.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
    }

    private var warningBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: diagnosticsService.diagnosticsHealth == .ready ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                .font(.title3.weight(.bold))
                .foregroundStyle(CommandCentreHealthPalette.color(for: diagnosticsService.diagnosticsHealth))

            VStack(alignment: .leading, spacing: 4) {
                Text("Diagnostics Health: \(diagnosticsService.diagnosticsHealth.label)")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)

                Text(diagnosticsService.warningSummary)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.70))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Text("Updated \(diagnosticsService.lastRefreshText)")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white.opacity(0.54))
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private var exportCard: some View {
        DiagnosticsCard(title: "Support Logs", systemImage: "square.and.arrow.up") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        Task { @MainActor in
                            if let url = await diagnosticsService.exportBundle(viewModel: appContainer.scoreboardViewModel),
                               let shareURL = logExporter.prepareShareURL(for: url) {
                                shareItem = RinkLensDiagnosticsShareItem(url: shareURL)
                            }
                            refreshDiagnostics(reason: "export")
                        }
                    } label: {
                        if logExporter.isExporting {
                            Label(logExporter.exportProgressText, systemImage: "hourglass")
                        } else {
                            Label("Export & Share Logs", systemImage: "square.and.arrow.up")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(shareItem != nil || logExporter.isExporting)

                    if let url = diagnosticsService.lastExportURL ?? logExporter.lastExportURL {
                        Button {
                            if let shareURL = logExporter.prepareShareURL(for: url) {
                                shareItem = RinkLensDiagnosticsShareItem(url: shareURL)
                            }
                        } label: {
                            Label("Share Last", systemImage: "arrowshape.turn.up.right")
                        }
                        .buttonStyle(.bordered)
                        .disabled(shareItem != nil || logExporter.isExporting)
                    }
                }

                DiagnosticsRow(title: "Last export", value: diagnosticsService.lastExportStatus)
                Text("Use this when sending evidence for review.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var screenScopedDiagnostics: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Logging")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.64))
                .textCase(.uppercase)

            DiagnosticsHubView(
                viewModel: appContainer.scoreboardViewModel,
                cameraService: appContainer.scoreboardViewModel.liveCameraService
            )
        }
    }

    private func refreshDiagnostics(reason: String) {
        let now = Date()
        if reason == "timer", now.timeIntervalSince(lastDiagnosticsRefresh) < RinkLensScrollPerformancePolicy.diagnosticsRefreshMinimumInterval {
            return
        }
        lastDiagnosticsRefresh = now
        diagnosticsService.refresh(
            viewModel: appContainer.scoreboardViewModel,
            runtimeStatus: runtimeStatus
        )
        MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("diagnostics refresh throttled by UX2: \(reason)"))
    }
}

private struct DiagnosticsModuleBackground: View {
    @ObservedObject private var appearance = RinkLensAppearanceSettings.shared

    var body: some View {
        ZStack {
            RinkLensDesignSystem.screenBackground
                .ignoresSafeArea()

            Circle()
                .fill(RinkLensDesignSystem.accent.opacity(0.13))
                .frame(width: 520, height: 520)
                .blur(radius: 125)
                .offset(x: 280, y: -260)

            Circle()
                .fill(RinkLensDesignSystem.accent.opacity(0.10))
                .frame(width: 420, height: 420)
                .blur(radius: 105)
                .offset(x: -260, y: 280)
        }
    }
}

private struct RinkLensDiagnosticsShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

#if canImport(UIKit)
private struct RinkLensDiagnosticsShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

#endif
