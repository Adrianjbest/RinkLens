// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI

// MARK: - Shared Command Centre Return Chrome

/// One navigation control and one screen-edge placement contract for all
/// primary operator modules. Keeping the control independent of each module's
/// title row prevents it moving when title/subtitle content changes.
enum RinkLensCommandCentreChrome {
    static let leadingInset: CGFloat = 16
    static let topInset: CGFloat = 16
    static let buttonSlotWidth: CGFloat = 166
    static let scrollContentTopClearance: CGFloat = 54
    static let maximumOCRTopContentWidth: CGFloat = 1_334
}

struct RinkLensCommandCentreReturnButton: View {
    let action: () -> Void
    var accessibilityHintText: String = "Returns to Command Centre"

    var body: some View {
        Button(action: action) {
            Label("Command Centre", systemImage: "rectangle.grid.2x2")
                .font(.caption.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial)
        .foregroundStyle(.white)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 6, x: 0, y: 2)
        .accessibilityLabel("Command Centre")
        .accessibilityHint(Text(accessibilityHintText))
        .accessibilityIdentifier("rinklens-command-centre-return")
    }
}

private struct RinkLensCommandCentreReturnOverlay: ViewModifier {
    let action: () -> Void
    let accessibilityHintText: String

    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            RinkLensCommandCentreReturnButton(
                action: action,
                accessibilityHintText: accessibilityHintText
            )
            .frame(width: RinkLensCommandCentreChrome.buttonSlotWidth, alignment: .leading)
            .padding(.leading, RinkLensCommandCentreChrome.leadingInset)
            .padding(.top, RinkLensCommandCentreChrome.topInset)
            .zIndex(1_000)
        }
    }
}

extension View {
    func rinkLensCommandCentreReturnButton(
        accessibilityHint: String = "Returns to Command Centre",
        action: @escaping () -> Void
    ) -> some View {
        modifier(
            RinkLensCommandCentreReturnOverlay(
                action: action,
                accessibilityHintText: accessibilityHint
            )
        )
    }
}

// MARK: - RinkLens NextGen Stage 11A Root Router

/// Single root routing switch for core RinkLens modules.
///
/// AppCoordinator is the sole visible-route owner. The Broadcast route renders
/// BroadcastView directly; camera reconciliation is an asynchronous consequence
/// of that committed route and never substitutes a progress/switching surface.
struct RootRouterView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var appContainer: AppContainer
    var body: some View {
        let route = coordinator.route
        ZStack {
            routeContent(for: route)

            // Recovery AM / RL-032: Broadcast is a match-session presentation
            // surface, not a route-owned disposable tree. Keep exactly one live
            // host mounted for the RootRouter lifetime and let AppCoordinator own
            // only visibility. CaptureEngine remains the camera/session owner.
            BroadcastRouteShellView(
                isVisible: route == .broadcast
            )
                .opacity(route == .broadcast ? 1 : 0)
                .allowsHitTesting(route == .broadcast)
                .accessibilityHidden(route != .broadcast)
                .zIndex(route == .broadcast ? 10 : -10)
        }
        .task(id: route) { @MainActor in
            await runRoutePresentation(for: route)
        }
    }

    @ViewBuilder
    private func routeContent(for route: AppRoute) -> some View {
        switch route {
        case .commandCentre:
            CommandCentreView()
        case .broadcast:
            // The persistent Broadcast host above owns the visible surface.
            Color.black.ignoresSafeArea()
        case .ocrSetup:
            OCRSetupRouteShellView()
        case .recording:
            RecordingRouteShellView(viewModel: appContainer.scoreboardViewModel)
        case .sponsors:
            SponsorsRouteShellView()
        case .media:
            MediaRouteShellView(viewModel: appContainer.scoreboardViewModel)
        case .streamSetup:
            // Recovery CL: the retired Stream route resolves to the single
            // Production Setup presentation rather than mounting a second writer UI.
            RecordingRouteShellView(viewModel: appContainer.scoreboardViewModel)
        case .diagnostics:
            DiagnosticsRouteShellView(diagnosticsService: appContainer.diagnosticsService)
        case .cameraSetup:
            CameraSetupRouteShellView(viewModel: appContainer.scoreboardViewModel)
        case .settings:
            SettingsRouteShellView(viewModel: appContainer.scoreboardViewModel)
        }
    }

    /// UX16c46: one task owns route lifecycle for the lifetime of the visible
    /// route. SwiftUI cancels it only when the route identity genuinely changes.
    private func runRoutePresentation(for route: AppRoute) async {
        RinkLensRoutePerformanceProbe.shared.mark(.routeTaskStarted, route: route, source: "RootRouterView.runRoutePresentation")
        let reason = RinkLensBuildInfo.traceContext("route presentation: \(route.title)")
        appContainer.runtimeStatus.markRouteVisible(route)
        appContainer.telemetry.markContext(RinkLensBuildInfo.traceContext("active route surface committed: \(route.title)"))

        if route == .broadcast {
            RinkLensStructuredEventLogger.shared.record(
                domain: .navigation,
                event: "broadcast_surface_committed",
                entityID: route.rawValue,
                previous: [
                    "surface": "not-mounted",
                    "captureReconciliation": "not-started"
                ],
                next: [
                    "surface": "BroadcastView",
                    "captureReconciliation": "scheduled"
                ],
                source: "RootRouterView.runRoutePresentation",
                reason: "AppCoordinator route was committed before CaptureLifecycleController reconciliation"
            )
            // Commit the route-owned scorebug and operator intent surface before
            // capture reconciliation. Physical capture acknowledgement is recorded
            // below, but it never gates already-rendered presentation pixels.
            await Task.yield()
            guard !Task.isCancelled, coordinator.route == route else { return }
        }

        await appContainer.scoreboardViewModel.presentNextGenRoute(route, reason: reason)
        guard !Task.isCancelled, coordinator.route == route else { return }
        if route == .broadcast {
            RinkLensStructuredEventLogger.shared.record(
                domain: .navigation,
                event: "broadcast_capture_contract_acknowledged",
                entityID: route.rawValue,
                previous: ["surface": "BroadcastView visible", "captureContract": "pending"],
                next: ["surface": "BroadcastView visible", "captureContract": "acknowledged"],
                source: "RootRouterView.runRoutePresentation",
                reason: "Capture acknowledgement is diagnostic evidence and does not gate route-owned scorebug visibility",
                authoritativeOwner: "CaptureLifecycleController"
            )
        }
        appContainer.telemetry.markContext(RinkLensBuildInfo.traceContext("route lifecycle active: \(route.title)"))

        // Recovery AU / RL-100: route publication may end the operator
        // interaction boundary, but routes/screens may not admit or resume
        // offline media. Deferred media resumes only after CaptureLifecycleController
        // verifies the live capture media lease is physically released.
        RinkLensExecutionCoordinator.shared.endOperatorInteraction(
            route: route.rawValue,
            source: "RootRouterView.runRoutePresentation"
        )

        if route == .broadcast || route == .recording {
            // RL-111: route ownership is presentation/capture intent only. The
            // supplied physical trace measured VTCompressionSessionCreate at
            // 13.196 seconds here, starving scorebug admission and every operator
            // handler despite running on a utility queue. RecordingEngine creates
            // its sole compressor only after an explicit REC transaction.
            RinkLensStructuredEventLogger.shared.record(
                domain: .recording,
                event: "recording_resources_deferred_to_operator_intent",
                entityID: route.rawValue,
                previous: ["matchEncoder": "route-prepared"],
                next: ["resourceOwnership": "recording-intent-owned"],
                source: "RootRouterView.runRoutePresentation",
                reason: "Broadcast route cannot acquire or project the physical state of VideoToolbox or writer resources",
                authoritativeOwner: "RecordingEngine"
            )
        }

        if route == .commandCentre {
            // Recovery AP / RL-092: Command Centre is configuration-only before
            // the first operational camera route. It must not acquire recording
            // encoder/file resources speculatively.
            RinkLensStructuredEventLogger.shared.record(
                domain: .navigation,
                event: "match_session_configuration_idle",
                entityID: route.rawValue,
                previous: ["speculativeWriterPrearm": "enabled"],
                next: ["speculativeWriterPrearm": "removed", "captureStart": "operational-route-owned"],
                source: "RootRouterView.runRoutePresentation",
                reason: "Recovery AP RL-092 establishes an explicit configuration-vs-live resource lifetime"
            )
        }

        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await appContainer.scoreboardViewModel.observeNextGenRouteHealth(
                route,
                reason: RinkLensBuildInfo.traceContext("route health observation: \(route.title)")
            )
        }
    }
}


/// Lightweight wrapper for the existing production operator experience.
///
/// Stage 3B fixes the navigation trap found during device testing: Broadcast
/// opened the original app successfully, but there was no top-level route back
/// to Command Centre. This shell does not own camera, OCR, recording, or
/// renderer lifecycle. It only exposes a route change button.
struct BroadcastRouteShellView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var appContainer: AppContainer
    private let recorder = BroadcastRecordingManager.shared
    let isVisible: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                BroadcastView(
                    viewModel: appContainer.scoreboardViewModel,
                    presentationMode: .nextGenOperational,
                    // Recovery DX: the expensive Broadcast tree is an app-session
                    // presentation host. Route state hides the shell below; it no
                    // longer becomes an input that rebuilds the entire camera,
                    // scorebug and operator hierarchy on first entry.
                    isOperationallyVisible: true
                )
                .equatable()

                if isVisible {
                    RinkLensCommandCentreReturnButton(
                        action: {
                            appContainer.telemetry.markContext(RinkLensBuildInfo.traceContext("route change requested: Broadcast -> Command Centre"))
                            coordinator.navigate(to: .commandCentre)
                        },
                        accessibilityHintText: recorder.canStop
                            ? "Returns to Command Centre while recording and camera processing continue"
                            : "Returns to Command Centre and stops camera processing when no recording is active"
                    )
                    .frame(width: RinkLensCommandCentreChrome.buttonSlotWidth, alignment: .leading)
                    .padding(.leading, RinkLensCommandCentreChrome.leadingInset)
                    .padding(.top, RinkLensCommandCentreChrome.topInset)
                    .zIndex(300)
                }
            }
            .onAppear {
                CameraOwnershipTraceStore.record(
                    .route,
                    owner: .broadcast,
                    reason: "Recovery AN lightweight persistent Broadcast host mounted | \(appContainer.scoreboardViewModel.diagnosticIdentityText) viewport=\(Int(proxy.size.width))x\(Int(proxy.size.height))"
                )
                if isVisible {
                    RinkLensRoutePerformanceProbe.shared.mark(.broadcastShellAppeared, route: .broadcast, source: "BroadcastRouteShellView.persistentHostInitialVisible")
                    appContainer.scoreboardViewModel.previewViewportSize = proxy.size
                }
            }
            .onChange(of: isVisible) { _, visible in
                guard visible else { return }
                RinkLensRoutePerformanceProbe.shared.mark(.broadcastShellAppeared, route: .broadcast, source: "BroadcastRouteShellView.persistentHostVisible")
                appContainer.scoreboardViewModel.previewViewportSize = proxy.size
                appContainer.telemetry.markContext(RinkLensBuildInfo.traceContext("Recovery AN lightweight persistent Broadcast host made visible"))
            }
            .onDisappear {
                CameraOwnershipTraceStore.record(.route, owner: .broadcast, reason: "Recovery AN lightweight persistent Broadcast host dismantled with RootRouter | \(appContainer.scoreboardViewModel.diagnosticIdentityText)")
            }
            .onChange(of: proxy.size) { _, newSize in
                guard isVisible else { return }
                appContainer.scoreboardViewModel.previewViewportSize = newSize
            }
        }
    }
}


/// Legacy Stage 2/3 placeholder retained temporarily for patch safety.
/// Stage 4A routes to CommandCentreView instead.
struct CommandCentrePlaceholderView: View {
    @EnvironmentObject private var coordinator: AppCoordinator

    private let routes: [AppRoute] = [
        .broadcast,
        .ocrSetup,
        .recording,
        .sponsors,
        .media,
        .streamSetup,
        .diagnostics,
        .cameraSetup,
        .settings
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("RinkLens NextGen") {
                    ForEach(routes) { route in
                        Button {
                            coordinator.navigate(to: route)
                        } label: {
                            HStack {
                                Text(route.title)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Stage") {
                    Text(RinkLensBuildInfo.version)
                    Text("Legacy placeholder retained for patch safety. Stage 4A uses CommandCentreView for the live shell.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Command Centre")
        }
    }
}

/// Placeholder for modules that will be extracted in later stages. This keeps
/// top-level routing complete without moving OCR, recording, sponsor, media,
/// diagnostics, or settings behaviour prematurely.
struct NextGenModulePlaceholderView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    let route: AppRoute

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: iconName(for: route))
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(route.title)
                    .font(.title2.bold())

                Text("This module will be migrated in a later NextGen stage. No existing camera, OCR, recording, or diagnostics ownership has been moved by this placeholder route.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 28)

                Button {
                    coordinator.navigate(to: .commandCentre)
                } label: {
                    Label("Back to Command Centre", systemImage: "chevron.left")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(route.title)
        }
    }

    private func iconName(for route: AppRoute) -> String {
        switch route {
        case .commandCentre: return "rectangle.grid.2x2"
        case .broadcast: return "dot.radiowaves.left.and.right"
        case .ocrSetup: return "viewfinder"
        case .recording: return "record.circle"
        case .sponsors: return "star"
        case .media: return "film"
        case .streamSetup: return "dot.radiowaves.left.and.right"
        case .diagnostics: return "waveform.path.ecg"
        case .cameraSetup: return "camera.aperture"
        case .settings: return "gearshape"
        }
    }
}

#endif
