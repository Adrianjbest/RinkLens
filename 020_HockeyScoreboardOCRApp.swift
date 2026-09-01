// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import AVFoundation
import Vision
import CoreMedia
import CoreGraphics
import PhotosUI
import Foundation
#if canImport(MLKitVision) && canImport(MLKitTextRecognition) && canImport(MLKitTextRecognitionLatin)
import MLKitVision
import MLKitTextRecognition
import MLKitTextRecognitionLatin
#endif

// MARK: - App Entry

nonisolated enum RinkLensConfigurationResetTransaction {
    private static let pendingKey = "RinkLens.configurationResetPending"

    static func requestForNextLaunch() {
        UserDefaults.standard.set(true, forKey: pendingKey)
    }

    static func applyIfRequested() {
        guard UserDefaults.standard.bool(forKey: pendingKey) else { return }
        if let identifier = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: identifier)
        }
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let profiles = support.appendingPathComponent("RinkTemplates", isDirectory: true)
            try? FileManager.default.removeItem(at: profiles)
        }
    }
}

@main
struct HockeyScoreboardOCRApp: App {
    init() {
        // Apply before AppContainer or any settings owner hydrates. Scheduling
        // the transaction on the previous run prevents live owners from writing
        // their in-memory values back over a reset during Settings dismissal.
        RinkLensConfigurationResetTransaction.applyIfRequested()
        RinkLensStartupMediaCleanup.shared.runOnceAtLaunch(reason: "app launch")
    }

    var body: some Scene {
        WindowGroup {
            RinkLensLaunchGateView()
        }
    }
}

/// UX16c41c renders a real first frame before constructing the large, persistent
/// match/camera model. The model still initializes on MainActor, but the operator
/// sees a branded progress surface instead of an apparently frozen launch.
private struct RinkLensLaunchGateView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var appContainer: AppContainer?
    @State private var launchStatus = "Starting RinkLens…"
    @State private var launchStartedAt = DispatchTime.now().uptimeNanoseconds
    @State private var launchPreparationInFlight = false

    var body: some View {
        ZStack {
            if let appContainer {
                RootRouterView()
                    .environmentObject(appContainer)
                    .environmentObject(appContainer.coordinator)
                    .environmentObject(appContainer.runtimeStatus)
                    .transition(.opacity)
            } else {
                RinkLensStartupSplashView(status: launchStatus)
                    .transition(.opacity)
            }
        }
        .task { await prepareApplication() }
        .onChange(of: scenePhase) { _, newPhase in
            appContainer?.handleScenePhase(newPhase)
        }
    }

    @MainActor
    private func prepareApplication() async {
        guard appContainer == nil, !launchPreparationInFlight else { return }
        launchPreparationInFlight = true
        defer { launchPreparationInFlight = false }
        launchStartedAt = DispatchTime.now().uptimeNanoseconds
        await Task.yield()
        launchStatus = "Loading profiles and camera services…"

        let container = AppContainer.shared
        launchStatus = "Preparing Command Centre…"
        container.runtimeStatus.markRouteVisible(.commandCentre)
        container.diagnosticsService.refresh(
            viewModel: container.scoreboardViewModel,
            runtimeStatus: container.runtimeStatus
        )

        let elapsed = DispatchTime.now().uptimeNanoseconds - launchStartedAt
        let minimumVisible: UInt64 = 180_000_000
        if elapsed < minimumVisible {
            try? await Task.sleep(nanoseconds: minimumVisible - elapsed)
        }

        launchStatus = "Ready"
        withAnimation(.easeOut(duration: 0.20)) {
            appContainer = container
        }
        container.telemetry.markContext(RinkLensBuildInfo.traceContext("startup splash completed"))
    }
}

private struct RinkLensStartupSplashView: View {
    let status: String

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.015, green: 0.025, blue: 0.055), Color(red: 0.02, green: 0.10, blue: 0.22)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                CommandCentreBrandMark()
                    .frame(width: 132, height: 132)

                VStack(spacing: 6) {
                    Text("RinkLens")
                        .font(.system(size: 42, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Broadcast · Image Relay · Game Intelligence")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.62))
                }

                ProgressView()
                    .controlSize(.large)
                    .tint(.white)

                Text(status)
                    .font(.callout.monospaced().weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .padding(36)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("RinkLens starting")
            .accessibilityValue(status)
        }
    }
}

#endif
