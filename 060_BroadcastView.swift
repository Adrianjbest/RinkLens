// BUILD 700 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import AVFoundation
import AVKit
import UIKit
import PhotosUI
import CoreMotion

// MARK: - Phase 2 Public Broadcast Output

private enum BroadcastManualQuickAction: String, Identifiable {
    case homeMinus
    case homePlus
    case periodMinus
    case periodPlus
    case guestMinus
    case guestPlus

    var id: String { rawValue }

    var manualConfirmationLabel: String {
        switch self {
        case .homeMinus:
            return "home score -1"
        case .homePlus:
            return "home goal"
        case .periodMinus:
            return "period -1"
        case .periodPlus:
            return "period +1"
        case .guestMinus:
            return "guest score -1"
        case .guestPlus:
            return "guest goal"
        }
    }
}

/// Stage 5A presentation mode for the Broadcast route.
///
/// `.legacy` preserves the previous full operator app behaviour for existing
/// internal navigation. `.nextGenOperational` is used by Command Centre and
/// keeps the live view calm: full-screen video, transparent operational controls,
/// manual goals/period, recording start/stop, stream status, and a game-event
/// timeline only. It deliberately hides calibration, camera configuration, deep
/// diagnostics, recording configuration, sponsor setup, clip/media clutter, and
/// penalty controls.
enum BroadcastPresentationMode: Equatable {
    case legacy
    case nextGenOperational
}

/// Route-owned admission for the persistent Broadcast presentation. Capture
/// readiness is separate physical evidence and must never hide a scorebug that
/// has already completed layout for the visible Broadcast route.
nonisolated struct BroadcastPresentationAdmission: Equatable, Sendable {
    let routeIsVisible: Bool

    var scorebugIsVisible: Bool { routeIsVisible }
}

/// Broadcast Mode screen.
///
/// v0.7.1 keeps Broadcast Safe Mode and stream-health placeholders, but the
/// large Broadcast Stream dialogue is hidden by default. It is opened from a
/// small operator-only Stream button so it does not cover the broadcast preview
/// or clash with the Exit Broadcast Preview button.
struct BroadcastView: View, Equatable {
    let viewModel: HockeyScoreboardViewModel
    let presentationMode: BroadcastPresentationMode
    let isOperationallyVisible: Bool
    @StateObject private var broadcastRuntime: BroadcastRuntimeViewModel
    @State private var showingStreamSettings = false
    @State private var showingStreamPanel = false
    @State private var showingOperatorControls = false
    @State private var cameraLockFeedbackText: String?
    @State private var showingScoreboardLayoutSettings = false
    private let streamDestinationStore = StreamDestinationStore.shared
    // Recovery AG / RL-069: action owners remain reachable for explicit operator
    // mutations and sheets, but they are no longer observed by the live root.
    // BroadcastRuntimeViewModel publishes one immutable presentation projection.
    private let streamControlStore = StreamControlStore.shared
    private let scoreboardLayoutSettings = BroadcastScoreboardLayoutSettings.shared
    private let sponsorStore = SponsorCatalogueStore.shared
    @State private var pendingManualQuickAction: BroadcastManualQuickAction?
    @State private var showManualOverrideConfirmation = false
    private var liveCameraService: HockeyCameraService { viewModel.liveCameraService }
    private let externalOCRMultiCamCoordinator: ExternalOCRMultiCamCoordinator

    init(
        viewModel: HockeyScoreboardViewModel,
        presentationMode: BroadcastPresentationMode = .legacy,
        isOperationallyVisible: Bool = true
    ) {
        self.viewModel = viewModel
        self.presentationMode = presentationMode
        self.isOperationallyVisible = isOperationallyVisible
        _broadcastRuntime = StateObject(wrappedValue: BroadcastRuntimeViewModel())
        self.externalOCRMultiCamCoordinator = viewModel.externalOCRMultiCamCoordinator
        RinkLensRoutePerformanceProbe.shared.mark(.broadcastViewInitialised, route: .broadcast, source: "BroadcastView.init")
    }

    static func == (lhs: BroadcastView, rhs: BroadcastView) -> Bool {
        lhs.viewModel === rhs.viewModel
            && lhs.presentationMode == rhs.presentationMode
            && lhs.isOperationallyVisible == rhs.isOperationallyVisible
    }

    private var broadcastSnapshot: BroadcastRuntimeSnapshot { broadcastRuntime.snapshot }
    private var broadcastPreviewCameraService: HockeyCameraService { viewModel.broadcastPreviewCameraService }
    private var isNextGenOperationalMode: Bool { presentationMode == .nextGenOperational }
    private var streamIsStarting: Bool {
        switch broadcastSnapshot.streamRuntimeState {
        case .openingPicker, .connecting, .connected: return true
        default: return false
        }
    }
    private var streamIsPublishing: Bool { broadcastSnapshot.streamRuntimeState == .publishing }
    private var streamIsStopping: Bool { broadcastSnapshot.streamRuntimeState == .stopRequested }
    private var streamActionIsLocked: Bool { streamIsStarting || streamIsStopping }
    private var streamActionTitle: String {
        if streamIsStarting { return "Starting Live…" }
        if streamIsStopping { return "Stopping…" }
        return streamIsPublishing ? "Stop Live" : "Go Live"
    }
    private var streamActionSystemImage: String {
        streamIsPublishing ? "stop.fill" : "dot.radiowaves.left.and.right"
    }
    private var streamStatusTitle: String {
        if streamIsStarting { return "STARTING LIVE" }
        if streamIsPublishing { return "LIVE" }
        if streamIsStopping { return "STOPPING" }
        if broadcastSnapshot.streamRuntimeState == .failed { return "STREAM FAILED" }
        return "STREAM READY"
    }
    private var streamStatusColour: Color {
        if streamIsPublishing { return .green }
        if streamIsStarting { return .cyan }
        if streamIsStopping { return .yellow }
        if broadcastSnapshot.streamRuntimeState == .failed { return .orange }
        return .gray.opacity(0.75)
    }
    private var routePresentationIsVisible: Bool {
        BroadcastPresentationAdmission(routeIsVisible: isOperationallyVisible).scorebugIsVisible
    }

    private func performPrimaryStreamAction() {
        switch broadcastSnapshot.streamRuntimeState {
        case .publishing:
            streamControlStore.requestStopPublishing(origin: .operatorBroadcastButton)
        case .idle, .stopped, .failed:
            streamControlStore.startInAppPublisher(destination: streamDestinationStore, viewModel: viewModel)
        case .openingPicker, .connecting, .connected, .stopRequested:
            break
        }
    }

    private var broadcastPreviewGameSponsor: SponsorCatalogueSponsor? {
        let configuration = broadcastSnapshot.sponsorConfiguration
        guard configuration.overlay.showOverlayOnBroadcastScreen else { return nil }
        guard let sponsorID = configuration.placements.gameSponsorID else { return nil }
        return configuration.sponsors.first(where: { $0.id == sponsorID && $0.isActive })
    }

    private var broadcastPreviewGameSponsorName: String {
        broadcastPreviewGameSponsor?.displayName ?? ""
    }

    private var broadcastPreviewGameSponsorLogo: UIImage? {
        #if canImport(UIKit)
        return sponsorStore.logoImage(for: broadcastPreviewGameSponsor?.id)
        #else
        return nil
        #endif
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
                .ignoresSafeArea()

            // Recovery AV: keep only the AVCapture preview host mounted for the
            // RootRouter lifetime. This removes Broadcast's cold preview-layer mount
            // from route entry without keeping the compositor/operator subtree alive
            // on Command Centre, Diagnostics or Settings.
            BroadcastPersistentCameraPreviewStage(
                externalOCRMultiCamCoordinator: externalOCRMultiCamCoordinator,
                rotationOffsetDegrees: broadcastSnapshot.livePreviewRotationOffsetDegrees
            )
            .ignoresSafeArea()
            .opacity(isOperationallyVisible ? 1 : 0)
            .allowsHitTesting(false)
            .zIndex(0)

            // Recovery BH / RL-145: keep the value-only scorebug layer mounted
            // for the persistent Broadcast-host lifetime. BroadcastRuntime already
            // keeps its immutable values warm while hidden; conditionally removing
            // this view discarded that work and forced the first scorebug layout to
            // compete with Image Relay resume on every first Broadcast entry.
            // Route state still owns visibility, hit-testing, sponsors and banners.
            BroadcastLetterboxedCompositeStage(
                isOperationallyVisible: isOperationallyVisible,
                showCompositeOverlay: broadcastSnapshot.layout.isVisible,
                snapshot: broadcastSnapshot,
                sponsorConfiguration: broadcastSnapshot.sponsorConfiguration,
                layout: broadcastSnapshot.layout,
                homeTeamName: broadcastSnapshot.homeTeamName,
                awayTeamName: broadcastSnapshot.awayTeamName,
                gameSponsorName: broadcastPreviewGameSponsorName,
                gameSponsorLogo: broadcastPreviewGameSponsorLogo
            )
            .ignoresSafeArea()
            .opacity(routePresentationIsVisible ? 1 : 0)
            .allowsHitTesting(routePresentationIsVisible)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.65) {
                guard viewModel.holdToLockBroadcastCamera else { return }
                viewModel.toggleSelectedBroadcastCameraParameters(reason: "Operator held Broadcast preview") { result in
                    switch result {
                    case .locked(let controls):
                        cameraLockFeedbackText = "Camera locked: \(controls.joined(separator: ", "))"
                    case .automatic:
                        cameraLockFeedbackText = "Camera returned to Auto"
                    case .unavailable(let detail):
                        cameraLockFeedbackText = "Camera lock unavailable: \(detail)"
                    case .failed(let detail):
                        cameraLockFeedbackText = "Camera lock failed: \(detail)"
                    }
                    let expectedFeedback = cameraLockFeedbackText
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                        if cameraLockFeedbackText == expectedFeedback { cameraLockFeedbackText = nil }
                    }
                }
            }
            .zIndex(0)

            if routePresentationIsVisible && viewModel.showBroadcastCompositionGrid {
                BroadcastCompositionGridOverlay().ignoresSafeArea().zIndex(20)
            }

            if routePresentationIsVisible && viewModel.showBroadcastLevelGuide {
                BroadcastHorizonGuideOverlay().ignoresSafeArea().zIndex(21)
            }

            if routePresentationIsVisible, let cameraLockFeedbackText {
                Label(cameraLockFeedbackText, systemImage: "lock.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.68), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .allowsHitTesting(false)
                    .zIndex(23)
            }

            if routePresentationIsVisible, case .paused = broadcastSnapshot.recordingBadge {
                ZStack {
                    Color.white.opacity(0.80)
                    VStack(spacing: 8) {
                        Image(systemName: "pause.circle.fill")
                            .font(.system(size: 46, weight: .bold))
                        Text("RECORDING PAUSED")
                            .font(.system(size: 22, weight: .black, design: .rounded))
                        Text("Press Resume to continue the same recording")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(Color.black.opacity(0.82))
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .zIndex(56)
            }

            if routePresentationIsVisible, let intermissionReel = broadcastSnapshot.activeIntermissionReel {
                IntermissionSponsorReelOverlayView(
                    reel: intermissionReel,
                    countdownText: broadcastSnapshot.overlayState.clock ?? viewModel.intermissionCountdownText,
                    slideDurationSeconds: broadcastSnapshot.sponsorConfiguration.intermission.slideDurationSeconds,
                    onDismiss: { viewModel.dismissSponsorIntermission(reason: "operator dismissed from Broadcast") }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(70)
            }
            // Recovery BJ / RL-148: retain the value-only operator shell beside
            // the persistent scorebug. The 21:28 run mounted this entire subtree
            // after route acknowledgement and then recorded a 3.065-second main-
            // actor gap. Route state owns only visibility, interaction and modal
            // admission; camera/recording mutations remain with their controllers.
            Group {
            if isNextGenOperationalMode {
                BroadcastLetterboxedTopTrailingControls(rowOffset: 0) {
                    broadcastOperationalStatusBar
                }
                .allowsHitTesting(true)
                .zIndex(100)

                BroadcastLetterboxedTopTrailingControls(rowOffset: 46) {
                    // Recovery EB / RL-267: the full verified zoom surface is a
                    // permanent Broadcast control. Build 143 accidentally hid
                    // the continuous bar behind a compact replacement.
                    BroadcastZoomPresetControls(viewModel: viewModel)
                }
                .allowsHitTesting(true)
                .zIndex(101)
            } else {
                // v0.7.1 Broadcast stream access:
                // A compact operator-only button strip replaces the always-open
                // stream dialogue. Stream sits to the left of Settings as requested.
                BroadcastLetterboxedTopTrailingControls(rowOffset: 0) {
                    broadcastStreamButtonStrip
                        // v0.8.4k: keep operator buttons above every broadcast graphic.
                        // This fixes slow/missed taps when banners/overlays are animating.
                        .zIndex(60)
                }
                .allowsHitTesting(true)
                .zIndex(100)
            }


            BroadcastLetterboxedBottomControls(
                horizontalPadding: isNextGenOperationalMode ? 0 : 18,
                fallbackBottomPadding: isNextGenOperationalMode ? 22 : 24
            ) {
                HStack {
                    if isNextGenOperationalMode { Spacer(minLength: 0) }
                    BroadcastRecordingQuickControls(
                        viewModel: viewModel,
                        manualControls: broadcastManualControls,
                        showsClipAndMediaControls: !isNextGenOperationalMode,
                        showsManualClipControl: true,
                        showsMediaControl: !isNextGenOperationalMode,
                        showsClipFeedback: false
                    )
                    Spacer(minLength: 0)
                }
            }
            .allowsHitTesting(true)
            .zIndex(98)

            if !isNextGenOperationalMode {
                HStack {
                    Spacer(minLength: 0)
                    BroadcastZoomPresetControls(
                        viewModel: viewModel
                    )
                        .padding(.trailing, 14)
                        .padding(.top, 90)
                        .padding(.bottom, 150)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .allowsHitTesting(true)
                .zIndex(99)
            }



            if showingStreamPanel && !broadcastSnapshot.streamBroadcastSafeModeActive && !isNextGenOperationalMode {
                VStack {
                    HStack {
                        Spacer(minLength: 0)
                        BroadcastStreamingControlsView(
                            destinationStore: streamDestinationStore,
                            controlStore: streamControlStore,
                            onOpenSettings: {
                                showingStreamSettings = true
                            },
                            onStartInApp: {
                                streamControlStore.startInAppPublisher(destination: streamDestinationStore, viewModel: viewModel)
                            }
                        )
                        .padding(Edge.Set.top, 66)
                        .padding(Edge.Set.trailing, 18)
                    }
                    Spacer(minLength: 0)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(10)
            }

            }
            .opacity(isOperationallyVisible ? 1 : 0)
            .allowsHitTesting(isOperationallyVisible)
            .accessibilityHidden(!isOperationallyVisible)
        }
        .background(BroadcastTheme.background)
        .sheet(isPresented: $showingStreamSettings) {
            StreamDestinationSettingsView(store: streamDestinationStore)
                .presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $showingOperatorControls) {
            OperatorControlHubSheet(
                viewModel: viewModel,
                initialPage: .ocr,
                showDisplayPage: false,
                showCameraPage: false,
                cameraPageMode: .broadcastSafe
            )
        }
        .sheet(isPresented: $showingScoreboardLayoutSettings) {
            BroadcastScoreboardLayoutSettingsSheet(settings: scoreboardLayoutSettings, viewModel: viewModel)
                .presentationDetents([.medium, .large])
        }
        .alert(
            "Disable OCR?",
            isPresented: $showManualOverrideConfirmation,
            actions: {
                Button("Cancel", role: .cancel) {
                    cancelManualQuickAction()
                }

                Button("Continue", role: .destructive) {
                    acceptPendingManualQuickAction()
                }
            },
            message: {
                Text(manualOCRDisableConfirmationMessage)
            }
        )
        .alert(
            "Confirm score change",
            isPresented: Binding(
                get: { viewModel.pendingImageRelayScoreConfirmation != nil },
                set: { if !$0 { viewModel.rejectPendingImageRelayScoreConfirmation() } }
            ),
            presenting: viewModel.pendingImageRelayScoreConfirmation,
            actions: { _ in
                Button("Reject", role: .cancel) {
                    viewModel.rejectPendingImageRelayScoreConfirmation()
                }
                Button("Accept score") {
                    viewModel.acceptPendingImageRelayScoreConfirmation()
                }
            },
            message: { pending in
                Text(pending.message)
            }
        )
        .onAppear {
            MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("Recovery DX warm persistent BroadcastView host mounted"))
            // Binding is presentation-only. It keeps the latest immutable value
            // ready while hidden and does not acquire capture or writer work.
            broadcastRuntime.bind(source: viewModel)
            // Route visibility is enforced by BroadcastRouteShellView. Keeping
            // this presentation bridge active prevents a first-entry tree rebuild;
            // it remains a read-only projection and owns no capture lifecycle.
            activateBroadcastPresentation(reason: "app-session presentation host mounted")
        }
        .onDisappear {
            // RootRouter lifetime ended. Ordinary route changes no longer destroy
            // this view, so this is teardown rather than navigation policy.
            broadcastRuntime.stop()
            MainThreadStallMonitor.shared.trace("Recovery AV persistent Broadcast host dismantled")
        }
        .onChange(of: broadcastSnapshot.streamBroadcastSafeModeActive) { _, isActive in
            if isActive {
                showingStreamSettings = false
                showingStreamPanel = false
            }
        }
        // v0.8.4k: do not animate the whole BroadcastView tree for a small operator panel.
        // Whole-tree animation competes with camera preview/scorebug updates and delays taps.
    }


    private var broadcastManualControls: AnyView {
        if viewModel.isImageRelayMode {
            return AnyView(
                BroadcastImageRelayEventControls(
                    onManual: { viewModel.setOperatingMode(.manual) }
                )
            )
        }

        if viewModel.manualOverrideEnabled {
            return AnyView(
                BroadcastManualScoreQuickControls(
                    viewModel: viewModel,
                    requestAction: requestManualQuickAction,
                    reenableOCR: { viewModel.resumeImageRelayFromBroadcastManualMode(reason: "Broadcast manual controls Relay button") },
                    showsPeriodControls: true
                )
            )
        }

        return AnyView(
            BroadcastManualModeEntryButton {
                viewModel.setOperatingMode(.manual)
                MainThreadStallMonitor.shared.trace("Broadcast manual mode enabled from NextGen controls")
            }
        )
    }

    private var manualOCRDisableConfirmationMessage: String {
        guard let action = pendingManualQuickAction else {
            return "Manual control will pause Image Relay updates. Continue?"
        }
        return "Manual \(action.manualConfirmationLabel) will switch the scoreboard to Manual Mode and pause Image Relay until Relay is resumed."
    }

    private var requiresManualOCRDisableConfirmation: Bool {
        guard !viewModel.manualOverrideEnabled else { return false }
        return viewModel.isOCREffectiveRunning || viewModel.userWantsOCRRunning || viewModel.isOCRMode
    }

    private func requestManualQuickAction(_ action: BroadcastManualQuickAction) {
        if requiresManualOCRDisableConfirmation {
            pendingManualQuickAction = action
            showManualOverrideConfirmation = true
            MainThreadStallMonitor.shared.trace("manual override confirmation requested: \(action.manualConfirmationLabel)")
            return
        }

        performManualQuickAction(action)
    }

    private func acceptPendingManualQuickAction() {
        guard let action = pendingManualQuickAction else {
            showManualOverrideConfirmation = false
            return
        }

        pendingManualQuickAction = nil
        showManualOverrideConfirmation = false
        MainThreadStallMonitor.shared.trace("manual override confirmation accepted: \(action.manualConfirmationLabel)")
        // The action enters Manual Mode itself after capturing the current visible
        // Home, Guest and Period values. Pre-switching erased the untouched score.
        performManualQuickAction(action)
        MainThreadStallMonitor.shared.trace("manual override captured final visible result: \(action.manualConfirmationLabel)")
    }

    private func cancelManualQuickAction() {
        let action = pendingManualQuickAction
        pendingManualQuickAction = nil
        showManualOverrideConfirmation = false
        if let action {
            MainThreadStallMonitor.shared.trace("manual override confirmation cancelled: \(action.manualConfirmationLabel)")
        }
    }

    private func performManualQuickAction(_ action: BroadcastManualQuickAction) {
        switch action {
        case .homeMinus:
            viewModel.adjustHomeScore(by: -1)
        case .homePlus:
            viewModel.adjustHomeScore(by: 1)
        case .periodMinus:
            viewModel.adjustPeriod(by: -1)
        case .periodPlus:
            viewModel.adjustPeriod(by: 1)
        case .guestMinus:
            viewModel.adjustAwayScore(by: -1)
        case .guestPlus:
            viewModel.adjustAwayScore(by: 1)
        }
    }


    private func activateBroadcastPresentation(reason: String) {
        RinkLensRoutePerformanceProbe.shared.mark(.broadcastViewAppeared, route: .broadcast, source: "BroadcastView.persistentHostVisible")
        let started = MainThreadStallMonitor.shared.beginTimedOperation("BroadcastView.activatePersistentPresentation")
        MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("Recovery DG retained Broadcast operator presentation activating: \(reason)"))
        viewModel.validateActiveTeamIdentityForBroadcastPresentation(source: "060_BroadcastView.swift")
        broadcastRuntime.start(source: viewModel)
        if externalOCRMultiCamCoordinator.snapshot.broadcastPreviewAttached {
            RinkLensRoutePerformanceProbe.shared.mark(.previewAttached, route: .broadcast, source: "BroadcastView.persistentPreviewAlreadyAttached")
        }
        RinkLensRoutePerformanceProbe.shared.mark(.runtimeBridgeStarted, route: .broadcast, source: "BroadcastView.activatePersistentPresentation")
        MainThreadStallMonitor.shared.endTimedOperation("BroadcastView.activatePersistentPresentation", startedAt: started)
        RinkLensRoutePerformanceProbe.shared.mark(.operatorChromeReady, route: .broadcast, source: "BroadcastView.retainedOperatorChrome")
    }

    private func recordControlHandlerReceived(_ control: String) {
        RinkLensStructuredEventLogger.shared.record(
            domain: .navigation,
            event: "broadcast_control_handler_received",
            entityID: control,
            previous: ["handler": "waiting"],
            next: ["handler": "received", "scorebugHost": "persistent"],
            source: "BroadcastView",
            reason: "Physical operator handler boundary for first-tap latency",
            authoritativeOwner: "AppCoordinator"
        )
    }



    private var broadcastSourceFPS: Double {
        let snapshot = externalOCRMultiCamCoordinator.snapshot
        guard snapshot.sessionRunning, snapshot.activeMode.requiresBroadcast else { return 0 }
        return snapshot.liveObservedFPS
    }

    private var broadcastSourceFPSLabel: String {
        guard broadcastSourceFPS >= 1 else { return "-- FPS" }
        return "\(Int(broadcastSourceFPS.rounded())) FPS"
    }

    private var broadcastOperationalStatusBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(streamStatusColour)
                    .frame(width: 8, height: 8)
                Text(streamStatusTitle)
                    .font(.caption2.weight(.black))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.black.opacity(0.48), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))

            Text(broadcastSnapshot.modeStatusText)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.76))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.38), in: Capsule())

            Text(broadcastSourceFPSLabel)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.68))
                .monospacedDigit()
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.32), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 1))
                .accessibilityLabel(
                    broadcastSourceFPS >= 1
                        ? "Broadcast source frame rate \(Int(broadcastSourceFPS.rounded())) frames per second"
                        : "Broadcast source frame rate unavailable"
                )

            Text(broadcastSnapshot.productionProfile.compactSummary)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.72))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.32), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 1))
                .accessibilityLabel("Broadcast quality \(broadcastSnapshot.productionProfile.rawValue), \(broadcastSnapshot.productionProfile.compactSummary)")

            if RinkLensRiskFeaturePolicy.isEnabled(.broadcastCameraControlEntryV11) {
                BroadcastCameraControlLauncher(viewModel: viewModel)
            }

            Button {
                sponsorStore.setBroadcastPreviewOverlayVisible(!broadcastSnapshot.sponsorConfiguration.overlay.showOverlayOnBroadcastScreen)
            } label: {
                Label(
                    broadcastSnapshot.sponsorConfiguration.overlay.showOverlayOnBroadcastScreen ? "Hide sponsors" : "Show sponsors",
                    systemImage: broadcastSnapshot.sponsorConfiguration.overlay.showOverlayOnBroadcastScreen ? "eye.slash.fill" : "eye.fill"
                )
                .font(.caption.weight(.black))
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
            }
            .background(Color.white.opacity(0.14), in: Capsule())
            .foregroundStyle(.white)
            .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
            .disabled(!broadcastSnapshot.sponsorConfiguration.overlay.isOutputOverlayEnabled)
            .opacity(broadcastSnapshot.sponsorConfiguration.overlay.isOutputOverlayEnabled ? 1.0 : 0.45)
            .accessibilityLabel("Show or hide sponsor overlay on the Broadcast screen")

            Button {
                performPrimaryStreamAction()
            } label: {
                HStack(spacing: 6) {
                    if streamActionIsLocked {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.white)
                    } else {
                        Image(systemName: streamActionSystemImage)
                    }
                    Text(streamActionTitle)
                }
                .font(.caption.weight(.black))
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
            }
            .background(
                streamIsPublishing
                    ? Color.red.opacity(0.82)
                    : (streamIsStarting ? Color.cyan.opacity(0.72) : Color.white.opacity(0.16)),
                in: Capsule()
            )
            .foregroundStyle(.white)
            .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
            .disabled(streamActionIsLocked)
            .accessibilityLabel(
                streamIsStarting
                    ? "Go Live pressed. Stream startup is in progress"
                    : (streamIsStopping ? "Stream stop is in progress" : streamActionTitle)
            )
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .contain)
    }

    private var broadcastStreamButtonStrip: some View {
        HStack(spacing: 8) {

            Button {
                showingScoreboardLayoutSettings = true
            } label: {
                Label("Scoreboard", systemImage: "rectangle.3.group.fill")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            .background(Color.black.opacity(0.58))
            .foregroundStyle(.white)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))
            .accessibilityLabel("Open scoreboard layout settings")

            Button {
                showingOperatorControls = true
            } label: {
                Label("Controls", systemImage: "slider.horizontal.3")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            .background(Color.black.opacity(0.58))
            .foregroundStyle(.white)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))
            .accessibilityLabel("Open operator controls")

            Button {
                if streamIsPublishing {
                    performPrimaryStreamAction()
                } else {
                    showingStreamPanel.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    if streamActionIsLocked {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.white)
                    } else {
                        Image(systemName: streamIsPublishing ? "stop.fill" : "dot.radiowaves.left.and.right")
                    }
                    Text(streamIsStarting ? "Starting…" : (streamIsStopping ? "Stopping…" : (streamIsPublishing ? "Stop" : "Stream")))
                }
                .font(.caption.weight(.bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .background(streamIsPublishing ? Color.red.opacity(0.82) : (streamIsStarting ? Color.cyan.opacity(0.72) : Color.black.opacity(0.58)))
            .foregroundStyle(.white)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))
            .disabled(streamActionIsLocked)
            .accessibilityLabel(streamIsStarting ? "Stream startup is in progress" : (streamIsPublishing ? "Stop broadcast stream" : "Open broadcast stream controls"))

            Button {
                showingStreamSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape.fill")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            .background(Color.black.opacity(0.58))
            .foregroundStyle(.white)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))
            .disabled(streamIsStarting || streamIsPublishing || streamIsStopping)
            .opacity((streamIsStarting || streamIsPublishing || streamIsStopping) ? 0.45 : 1.0)
            .accessibilityLabel("Open stream settings")
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
    }

}



// Build 708: the viewer event timeline was retired. The internal event journal remains
// authoritative for popup sequencing, audit and undo, but it is not rendered.

// MARK: - v0.9.0n2a Scoreboard positioning and settings


private struct BroadcastLetterboxedTopTrailingControls<Content: View>: View {
    let rowOffset: CGFloat
    let trailingPadding: CGFloat
    private let content: () -> Content

    init(rowOffset: CGFloat, trailingPadding: CGFloat = 18, @ViewBuilder content: @escaping () -> Content) {
        self.rowOffset = rowOffset
        self.trailingPadding = trailingPadding
        self.content = content
    }

    var body: some View {
        GeometryReader { geometry in
            let frame = BroadcastCompositeStandard.previewCompositeFrame(in: geometry.size)
            let topBandHeight = max(0, frame.minY)
            let preferredTop = max(8, min(topBandHeight + 8, rowOffset + 8))
            let fallbackTop = max(8, frame.minY + rowOffset + 8)
            let topPadding = topBandHeight >= rowOffset + 36 ? preferredTop : fallbackTop

            VStack {
                HStack {
                    Spacer(minLength: 0)
                    content()
                        .padding(.top, topPadding)
                        .padding(.trailing, trailingPadding)
                }
                Spacer(minLength: 0)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
    }
}

private struct BroadcastLetterboxedBottomControls<Content: View>: View {
    let horizontalPadding: CGFloat
    let fallbackBottomPadding: CGFloat
    private let content: () -> Content

    init(horizontalPadding: CGFloat, fallbackBottomPadding: CGFloat, @ViewBuilder content: @escaping () -> Content) {
        self.horizontalPadding = horizontalPadding
        self.fallbackBottomPadding = fallbackBottomPadding
        self.content = content
    }

    var body: some View {
        GeometryReader { geometry in
            let frame = BroadcastCompositeStandard.previewCompositeFrame(in: geometry.size)
            let bottomBandHeight = max(0, geometry.size.height - frame.maxY)
            let outsideBottomPadding = max(8, min(bottomBandHeight + 8, 14))
            let bottomPadding = bottomBandHeight >= 54 ? outsideBottomPadding : fallbackBottomPadding

            VStack {
                Spacer(minLength: 0)
                content()
                    .padding(.horizontal, horizontalPadding)
                    .padding(.bottom, bottomPadding)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
    }
}

nonisolated struct RinkLensBroadcastPreviewContinuityState: Sendable, Equatable {
    private(set) var transactionID: UUID?
    private(set) var presentedTransactionID: UUID?
    private(set) var releasingTransactionID: UUID?
    var isHolding: Bool { transactionID != nil }
    var isReleasing: Bool { releasingTransactionID != nil }

    mutating func begin(transactionID: UUID) {
        self.transactionID = transactionID
        presentedTransactionID = nil
        releasingTransactionID = nil
    }

    mutating func acknowledgePresentation(transactionID: UUID) {
        guard self.transactionID == transactionID else { return }
        presentedTransactionID = transactionID
    }

    func admitsLensReplacement(transactionID: UUID) -> Bool {
        self.transactionID == transactionID && presentedTransactionID == transactionID
    }

    @discardableResult
    mutating func beginRelease(transactionID: UUID) -> Bool {
        guard self.transactionID == transactionID,
              presentedTransactionID == transactionID,
              releasingTransactionID == nil else { return false }
        releasingTransactionID = transactionID
        return true
    }

    mutating func completeRelease(transactionID: UUID) {
        guard releasingTransactionID == transactionID else { return }
        end(transactionID: transactionID)
    }

    mutating func end(transactionID: UUID) {
        guard self.transactionID == transactionID else { return }
        self.transactionID = nil
        presentedTransactionID = nil
        releasingTransactionID = nil
    }
}

/// A short visual dissolve masks the unavoidable sensor-image discontinuity
/// while the incoming physical lens begins its real zoom motion. It is capped
/// by that motion, so presentation never extends the hardware transaction.
nonisolated struct RinkLensBroadcastPreviewContinuityReleasePlan: Sendable, Equatable {
    let duration: TimeInterval

    static func resolve(incomingMotionDuration: TimeInterval) -> Self {
        .init(duration: min(max(0, incomingMotionDuration), 0.12))
    }
}

@MainActor
final class RinkLensBroadcastPreviewContinuityStore {
    static let shared = RinkLensBroadcastPreviewContinuityStore()

    private var state = RinkLensBroadcastPreviewContinuityState()

    private init() {}

    @discardableResult
    func beginHold(transactionID: UUID, image: CGImage) async -> Bool {
        state.begin(transactionID: transactionID)
        guard let host = ExternalOCRMultiCamPreviewHostStore.shared.existingView(
            for: RinkLensCapturePreviewRole.broadcast.stableHostKey
        ), await host.presentContinuityImage(image, transactionID: transactionID) else {
            state.end(transactionID: transactionID)
            return false
        }
        state.acknowledgePresentation(transactionID: transactionID)
        return state.admitsLensReplacement(transactionID: transactionID)
    }

    func endHold(transactionID: UUID) {
        guard state.transactionID == transactionID else { return }
        ExternalOCRMultiCamPreviewHostStore.shared.existingView(
            for: RinkLensCapturePreviewRole.broadcast.stableHostKey
        )?.removeContinuityImage(transactionID: transactionID)
        state.end(transactionID: transactionID)
    }

    @discardableResult
    func releaseHold(transactionID: UUID, duration: TimeInterval) -> Bool {
        guard state.beginRelease(transactionID: transactionID) else { return false }
        guard let host = ExternalOCRMultiCamPreviewHostStore.shared.existingView(
            for: RinkLensCapturePreviewRole.broadcast.stableHostKey
        ) else {
            state.end(transactionID: transactionID)
            return false
        }
        host.releaseContinuityImage(
            transactionID: transactionID,
            duration: duration
        ) { [weak self] in
            self?.state.completeRelease(transactionID: transactionID)
        }
        return true
    }
}

private struct BroadcastPersistentCameraPreviewStage: View {
    let externalOCRMultiCamCoordinator: ExternalOCRMultiCamCoordinator
    let rotationOffsetDegrees: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let frame = BroadcastCompositeStandard.previewCompositeFrame(in: geometry.size)
            ZStack {
                Color.black
                ExternalOCRMultiCamPreviewView(
                    coordinator: externalOCRMultiCamCoordinator,
                    role: .broadcast,
                    rotationOffsetDegrees: rotationOffsetDegrees,
                    onAttached: { _ in
                        RinkLensRoutePerformanceProbe.shared.mark(
                            .previewAttached,
                            route: .broadcast,
                            source: "RecoveryAV.persistentBroadcastPreview.onAttached"
                        )
                    },
                    onDetached: {},
                    onHeartbeat: { _, _ in }
                )
                .frame(width: frame.width, height: frame.height)
                .clipped()
            }
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .clipped()
            .background(Color.black)
        }
        .background(Color.black)
        .onAppear {
            MainThreadStallMonitor.shared.trace(
                RinkLensBuildInfo.traceContext("Recovery AV persistent Broadcast preview host mounted")
            )
        }
    }
}

/// Visible Broadcast composite host. The camera preview remains persistent, but
/// this value-only presentation subtree exists only on the Broadcast route.
private struct BroadcastLetterboxedCompositeStage: View {
    let isOperationallyVisible: Bool
    let showCompositeOverlay: Bool
    let snapshot: BroadcastRuntimeSnapshot
    let sponsorConfiguration: SponsorCatalogueConfiguration
    let layout: BroadcastScoreboardLayoutSnapshot
    let homeTeamName: String
    let awayTeamName: String
    let gameSponsorName: String
    let gameSponsorLogo: UIImage?

    var body: some View {
        GeometryReader { geometry in
            let frame = BroadcastCompositeStandard.previewCompositeFrame(in: geometry.size)

            ZStack {
                Color.clear

                if showCompositeOverlay {
                    // Live presentation is a value-only SwiftUI projection. The
                    // former path created and composited a transparent 1920x1080
                    // UIKit bitmap when Broadcast became visible; the 18:35 run
                    // measured 3.10s before that image completed and a 3.38s
                    // main-actor heartbeat gap. Recording/clips retain their
                    // canonical raster cache, while the operator scorebug can now
                    // appear in the first committed Broadcast frame.
                    let scorebugScale = frame.width / BroadcastCompositeStandard.canonicalCanvas.width
                    BroadcastScorebugPositionLayer(
                        layout: layout,
                        overlay: BroadcastScorebugOverlay(
                            viewerScoreboard: snapshot.viewerScoreboard,
                            isOCRMode: snapshot.isOCRMode,
                            modeStatusText: snapshot.modeStatusText,
                            strengthState: snapshot.strengthState,
                            activePenaltyClocks: snapshot.activePenaltyClocks,
                            homeLogo: snapshot.homeLogo,
                            awayLogo: snapshot.awayLogo,
                            layout: layout,
                            gameSponsorName: gameSponsorName,
                            gameSponsorLogo: gameSponsorLogo
                        )
                    )
                    .frame(
                        width: BroadcastCompositeStandard.canonicalCanvas.width,
                        height: BroadcastCompositeStandard.canonicalCanvas.height
                    )
                    .scaleEffect(scorebugScale, anchor: .center)
                    .frame(width: frame.width, height: frame.height)
                    .clipped()
                    .allowsHitTesting(false)
                    .background(
                        BroadcastScorebugPresentationAcknowledgement(
                            revision: snapshot.viewerScoreboard.relay.revision,
                            isVisible: isOperationallyVisible
                        )
                    )
                    .zIndex(2)

                    if isOperationallyVisible,
                       sponsorConfiguration.overlay.isOutputOverlayEnabled,
                       sponsorConfiguration.overlay.showOverlayOnBroadcastScreen {
                        SponsorBroadcastOverlayView(configuration: sponsorConfiguration)
                            .frame(width: frame.width, height: frame.height)
                            .clipped()
                            .allowsHitTesting(false)
                            .zIndex(2.5)
                    }

                    let popupScale = frame.width / BroadcastCompositeStandard.canonicalCanvas.width
                    if isOperationallyVisible {
                        BroadcastBannerOverlay(
                            banner: snapshot.activeBroadcastBanner,
                            homeLogo: snapshot.homeLogo,
                            awayLogo: snapshot.awayLogo,
                            homeTeamName: homeTeamName,
                            awayTeamName: awayTeamName,
                            useActualTeamNames: BroadcastEventPopupSettings.shared.useActualTeamNames,
                            goalTeamLogosEnabled: BroadcastEventPopupSettings.shared.goalTeamLogosEnabled,
                            penaltyTeamLogosEnabled: BroadcastEventPopupSettings.shared.penaltyTeamLogosEnabled
                        )
                        .frame(
                            width: BroadcastCompositeStandard.canonicalCanvas.width,
                            height: BroadcastCompositeStandard.canonicalCanvas.height
                        )
                        .scaleEffect(popupScale, anchor: .center)
                        .frame(width: frame.width, height: frame.height)
                        .clipped()
                        .allowsHitTesting(false)
                        .zIndex(3)
                    }
                }
            }
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .contentShape(Rectangle())
            .clipped()
            .background(Color.clear)
            .overlay(
                Rectangle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .accessibilityLabel("Broadcast 16 by 9 preview stage")
        }
        .background(Color.clear)
        .onAppear {
            MainThreadStallMonitor.shared.traceSponsorOverlay(
                "Recovery BH persistent value-only Broadcast scorebug mounted; recording raster compositor remains off the presentation path"
            )
        }
    }
}

/// Presentation-only acknowledgement for the visible operator scorebug.
/// The Image Relay store remains the state owner. SwiftUI submission records the
/// requested boundary, the following main-loop turn records completed layout, and
/// the next display-link callback acknowledges that UIKit reached a display pass.
/// Hidden persistent-host updates are deliberately excluded from visible latency.
private struct BroadcastScorebugPresentationAcknowledgement: UIViewRepresentable {
    let revision: UInt64
    let isVisible: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isHidden = true
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.submit(revision: revision, isVisible: isVisible)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.cancel()
    }

    @MainActor
    final class Coordinator: NSObject {
        private var pendingRevision: UInt64?
        private var lastSubmittedRevision: UInt64?
        private var wasVisible = false
        private var displayLink: CADisplayLink?

        func submit(revision: UInt64, isVisible: Bool) {
            guard isVisible else {
                wasVisible = false
                cancelPending()
                return
            }
            let becameVisible = !wasVisible
            wasVisible = true
            guard becameVisible || lastSubmittedRevision != revision else { return }

            cancelPending()
            pendingRevision = revision
            lastSubmittedRevision = revision
            if revision > 0 {
                ScoreboardImageRelayPresentation.shared.noteBroadcastRenderRequested(revision: revision)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.pendingRevision == revision else { return }
                if revision > 0 {
                    ScoreboardImageRelayPresentation.shared.noteBroadcastRenderCompleted(revision: revision)
                }
                self.armDisplayAcknowledgement()
            }
        }

        private func armDisplayAcknowledgement() {
            displayLink?.invalidate()
            let link = CADisplayLink(target: self, selector: #selector(displayDidAdvance))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }

        @objc private func displayDidAdvance() {
            guard let revision = pendingRevision else {
                cancelPending()
                return
            }
            if revision > 0 {
                ScoreboardImageRelayPresentation.shared.noteBroadcastDisplayed(revision: revision)
            }
            RinkLensRoutePerformanceProbe.shared.mark(
                .overlayAppeared,
                route: .broadcast,
                source: "BroadcastScorebugPresentationAcknowledgement.displayDidAdvance"
            )
            pendingRevision = nil
            displayLink?.invalidate()
            displayLink = nil
        }

        func cancel() {
            wasVisible = false
            lastSubmittedRevision = nil
            cancelPending()
        }

        private func cancelPending() {
            pendingRevision = nil
            displayLink?.invalidate()
            displayLink = nil
        }

        deinit {
            displayLink?.invalidate()
        }
    }
}

private struct BroadcastScorebugPositionLayer<Overlay: View>: View {
    let layout: BroadcastScoreboardLayoutSnapshot
    let overlay: Overlay
    @State private var measuredOverlaySize: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            if layout.isVisible {
                overlay
                    .fixedSize(horizontal: true, vertical: false)
                    .background(
                        GeometryReader { overlayGeometry in
                            Color.clear
                                .preference(key: BroadcastScorebugSizePreferenceKey.self, value: overlayGeometry.size)
                        }
                    )
                    .onPreferenceChange(BroadcastScorebugSizePreferenceKey.self) { newSize in
                        guard newSize.width > 1, newSize.height > 1 else { return }
                        measuredOverlaySize = newSize
                    }
                    .position(position(in: geometry.size, overlaySize: safeOverlaySize))
                    // Scorebug configuration is an authoritative snapshot, not
                    // an animation target. Animating the first persisted layout
                    // application made the overlay visibly trail route entry.
                    .transaction { $0.animation = nil }
            }
        }
        .ignoresSafeArea()
    }

    private var safeOverlaySize: CGSize {
        if measuredOverlaySize.width > 1, measuredOverlaySize.height > 1 {
            return measuredOverlaySize
        }
        return CGSize(width: BroadcastTheme.broadcastScorebugScaledWidth, height: BroadcastTheme.broadcastScorebugScaledHeight + 28)
    }

    private func position(in canvasSize: CGSize, overlaySize: CGSize) -> CGPoint {
        BroadcastCompositeStandard.scorebugPosition(
            in: canvasSize,
            overlaySize: overlaySize,
            layout: layout
        )
    }
}

private struct BroadcastScorebugSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0, next.height > 0 {
            value = next
        }
    }
}

private enum BroadcastScoreboardSettingsTab: String, CaseIterable, Identifiable {
    case layout = "Layout"
    case style = "Text Style & Colour"
    case teams = "Teams"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .layout: return "rectangle.3.group.fill"
        case .style: return "paintpalette.fill"
        case .teams: return "person.2.crop.square.stack"
        }
    }
}

private struct BroadcastScoreboardLayoutSettingsSheet: View {
    @ObservedObject var settings: BroadcastScoreboardLayoutSettings
    let viewModel: HockeyScoreboardViewModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var refreshDriver = OperatorControlsRefreshDriver()

    @State private var selectedTab: BroadcastScoreboardSettingsTab = .layout
    @State private var selectedHomeLogoItem: PhotosPickerItem?
    @State private var selectedAwayLogoItem: PhotosPickerItem?
    @State private var teamTemplateName = ""
    @State private var duplicateTeamTemplate: TeamIdentityTemplate?
    @State private var duplicateTeamTemplateName = ""
    @State private var deleteTeamTemplate: TeamIdentityTemplate?

    var body: some View {
        let _ = refreshDriver.refreshID
        NavigationStack {
            ZStack {
                BroadcastMenuBackgroundView()

                VStack(spacing: 0) {
                    Picker("Scoreboard section", selection: $selectedTab) {
                        ForEach(BroadcastScoreboardSettingsTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.top, 10)
                    .padding(.bottom, 8)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            switch selectedTab {
                            case .layout:
                                layoutPage
                            case .style:
                                styleAndColourPage
                            case .teams:
                                teamsPage
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 14)
                    }
                }
            }
            .navigationTitle("Scoreboard")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Reset") { resetScoreboardToDefaults() }
                }
            }
        }
        .broadcastMenuText()
        .alert("Duplicate team profile", isPresented: Binding(get: { duplicateTeamTemplate != nil }, set: { if !$0 { duplicateTeamTemplate = nil } })) {
            TextField("Profile name", text: $duplicateTeamTemplateName)
            Button("Cancel", role: .cancel) { duplicateTeamTemplate = nil }
            Button("Duplicate") {
                if let duplicateTeamTemplate {
                    viewModel.duplicateTeamIdentityTemplate(duplicateTeamTemplate, newName: duplicateTeamTemplateName)
                    refreshDriver.bump(reason: "team profile duplicated")
                }
                duplicateTeamTemplate = nil
            }
        } message: {
            Text("Create a copy of this team profile.")
        }
        .alert("Delete team profile?", isPresented: Binding(get: { deleteTeamTemplate != nil }, set: { if !$0 { deleteTeamTemplate = nil } })) {
            Button("Cancel", role: .cancel) { deleteTeamTemplate = nil }
            Button("Delete", role: .destructive) {
                if let deleteTeamTemplate {
                    viewModel.deleteTeamIdentityTemplate(deleteTeamTemplate)
                    refreshDriver.bump(reason: "team profile deleted")
                }
                deleteTeamTemplate = nil
            }
        } message: {
            Text("This removes the saved team names and logo references for this profile. Current live teams are not changed unless this profile is active.")
        }
        .onAppear {
            refreshDriver.start()
            MainThreadStallMonitor.shared.markContext("Scoreboard settings opened: \(selectedTab.rawValue)")
        }
        .onDisappear {
            refreshDriver.stop()
            MainThreadStallMonitor.shared.markContext("Scoreboard settings dismissed")
        }
        .onChange(of: selectedTab) { _, tab in
            refreshDriver.bump(reason: "scoreboard settings tab: \(tab.rawValue)")
            MainThreadStallMonitor.shared.markContext("Scoreboard settings tab: \(tab.rawValue)")
        }
        .onChange(of: selectedHomeLogoItem) { _, newItem in
            Task {
                let data = try? await newItem?.loadTransferable(type: Data.self)
                await MainActor.run {
                    viewModel.setHomeLogo(data: data)
                    refreshDriver.bump(reason: "home logo updated")
                }
            }
        }
        .onChange(of: selectedAwayLogoItem) { _, newItem in
            Task {
                let data = try? await newItem?.loadTransferable(type: Data.self)
                await MainActor.run {
                    viewModel.setAwayLogo(data: data)
                    refreshDriver.bump(reason: "away logo updated")
                }
            }
        }
    }

    private func resetScoreboardToDefaults() {
        // Scoreboard reset remains visual-only so it does not unexpectedly
        // erase match team identity. Team reset is available inside Teams.
        settings.resetToDefault()
        refreshDriver.bump(reason: "scoreboard reset to defaults")
    }

    private var layoutPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            BroadcastMenuHeaderLabel(
                title: "Layout",
                subtitle: "Control scoreboard position, logo placement and safe margins.",
                systemImage: "rectangle.3.group.fill"
            )

            VStack(alignment: .leading, spacing: 12) {
                Toggle("Show scoreboard", isOn: $settings.isVisible)

                Text("Scorebug position is locked to Top Middle.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.62))

                Picker("Logo Position", selection: $settings.logoPosition) {
                    ForEach(BroadcastScoreboardLogoPosition.allCases) { position in
                        Text(position.title).tag(position)
                    }
                }

                Divider().overlay(Color.white.opacity(0.18))

                Stepper("Safe margin: \(Int(settings.safeMargin))", value: $settings.safeMargin, in: 12...80, step: 2)
                Stepper("Horizontal offset: \(Int(settings.horizontalOffset))", value: $settings.horizontalOffset, in: -220...220, step: 4)
                Stepper("Vertical offset: \(Int(settings.verticalOffset))", value: $settings.verticalOffset, in: -160...160, step: 4)
            }
            .font(.subheadline.weight(.semibold))
            .padding(12)
            .broadcastMenuCard(cornerRadius: 14)
        }
    }

    private var styleAndColourPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            BroadcastMenuHeaderLabel(
                title: "Text Style & Colour",
                subtitle: "One master size control plus weight, colours, background and live preview.",
                systemImage: "paintpalette.fill"
            )

            VStack(alignment: .leading, spacing: 10) {
                compactStepperRow("Team font", value: $settings.teamNameFontSize, range: 20...48, step: 1, suffix: "pt")

                Text("Team font controls the whole scorebug scale, including scores, Clock, logos, centre readouts, penalties and spacing.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.62))

                Picker("Weight", selection: $settings.teamNameFontWeight) {
                    ForEach(BroadcastScoreboardFontWeight.allCases) { weight in
                        Text(weight.title).tag(weight)
                    }
                }
                .pickerStyle(.menu)

                Divider().overlay(Color.white.opacity(0.18))

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(minimum: 0), spacing: 8),
                        GridItem(.flexible(minimum: 0), spacing: 8)
                    ],
                    alignment: .leading,
                    spacing: 8
                ) {
                    compactColourPicker("Home text", selection: $settings.homeTeamNameColour)
                    compactColourPicker("Away text", selection: $settings.awayTeamNameColour)
                    compactColourPicker("Home bg", selection: $settings.homeTeamBackgroundColour)
                    compactColourPicker("Away bg", selection: $settings.awayTeamBackgroundColour)
                    compactColourPicker("Home score", selection: $settings.homeScoreColour)
                    compactColourPicker("Away score", selection: $settings.awayScoreColour)
                    compactColourPicker("Shared score", selection: $settings.scoreColour)
                    compactColourPicker("Clock", selection: $settings.clockColour)
                    compactColourPicker("Period", selection: $settings.periodColour)
                    compactColourPicker("Accent", selection: $settings.accentColour)
                    compactColourPicker("Bg", selection: $settings.scoreboardBackgroundColour)
                    compactColourPicker("Border", selection: $settings.scoreboardBorderColour)
                    compactColourPicker("Logo bg", selection: $settings.logoContainerBackground)
                }
            }
            .font(.caption2.weight(.semibold))
            .padding(8)
            .broadcastMenuCard(cornerRadius: 14)

            previewCard
        }
    }

    private func compactStepperRow(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, step: CGFloat, suffix: String) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                Text("\(Int(value.wrappedValue))\(suffix)")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(.white.opacity(0.82))
            }
        }
    }

    private func compactColourPicker(_ title: String, selection: Binding<Color>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Spacer(minLength: 2)
            ColorPicker(title, selection: selection, supportsOpacity: true)
                .labelsHidden()
                .frame(width: 28, height: 24)
        }
        .frame(maxWidth: .infinity, minHeight: 34)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var teamsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            BroadcastMenuHeaderLabel(
                title: "Teams",
                subtitle: "Manage team names, logos and scoreboard look-and-feel profiles together.",
                systemImage: "person.2.crop.square.stack"
            )

            VStack(alignment: .leading, spacing: 10) {
                TextField("Home team", text: Binding(get: { viewModel.homeTeamName }, set: { viewModel.homeTeamName = $0; refreshDriver.bump(reason: "home team edited") }))
                    .textInputAutocapitalization(.characters)
                    .textFieldStyle(BroadcastMenuTextFieldStyle())
                TextField("Away / guest team", text: Binding(get: { viewModel.awayTeamName }, set: { viewModel.awayTeamName = $0; refreshDriver.bump(reason: "away team edited") }))
                    .textInputAutocapitalization(.characters)
                    .textFieldStyle(BroadcastMenuTextFieldStyle())
            }
            .padding(12)
            .broadcastMenuCard(cornerRadius: 14)

            HStack(spacing: 12) {
                teamLogoCard(title: "Home logo", image: viewModel.homeLogoImage, picker: $selectedHomeLogoItem, remove: { viewModel.setHomeLogo(data: nil) })
                teamLogoCard(title: "Guest logo", image: viewModel.awayLogoImage, picker: $selectedAwayLogoItem, remove: { viewModel.setAwayLogo(data: nil) })
            }

            savedTeamConfigCard
        }
    }

    private var savedTeamConfigCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Label("Scoreboard profiles", systemImage: "rectangle.3.group.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                Spacer()
                activeTeamProfileBadge
            }

            if viewModel.teamIdentityTemplates.isEmpty {
                Text("No saved scoreboard profiles yet. Enter names, choose logos, set the scoreboard style, then save a profile.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.70))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(viewModel.teamIdentityTemplates) { template in
                            teamProfileButton(template)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            HStack(spacing: 6) {
                TextField("Profile name", text: $teamTemplateName)
                    .textFieldStyle(BroadcastMenuTextFieldStyle())
                Button {
                    viewModel.saveCurrentTeamIdentityTemplate(named: teamTemplateName)
                    teamTemplateName = viewModel.teamIdentityTemplates
                        .first(where: { $0.id == viewModel.selectedTeamIdentityTemplateID })?.name
                        ?? teamTemplateName
                    refreshDriver.bump(reason: "team profile saved")
                } label: {
                    Label("Save profile", systemImage: "square.and.arrow.down")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .disabled(teamTemplateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Button {
                viewModel.updateActiveTeamIdentityTemplateWithCurrentScoreboardStyle(title: teamTemplateName)
                teamTemplateName = viewModel.teamIdentityTemplates
                    .first(where: { $0.id == viewModel.selectedTeamIdentityTemplateID })?.name
                    ?? teamTemplateName
                refreshDriver.bump(reason: "active team profile style updated")
            } label: {
                Label("Save active profile", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.selectedTeamIdentityTemplateID == nil)

            Text("Tap a profile to load names, logos and scoreboard look-and-feel. Use the menu for Load, Set Default, Duplicate and Delete.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.62))

            Button(role: .destructive) {
                viewModel.resetTeamsAndLogos()
                refreshDriver.bump(reason: "teams reset")
            } label: {
                Label("Reset current teams and logos", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .broadcastMenuCard(cornerRadius: 14)
    }

    private var activeTeamProfileBadge: some View {
        let active = viewModel.teamIdentityTemplates.first(where: { $0.id == viewModel.selectedTeamIdentityTemplateID })
        return HStack(spacing: 5) {
            Circle()
                .fill(active == nil ? Color.white.opacity(0.28) : Color.green.opacity(0.85))
                .frame(width: 8, height: 8)
            Text(active?.name ?? "No active profile")
                .font(.caption2.bold())
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.10), in: Capsule(style: .continuous))
    }

    private func teamProfileButton(_ template: TeamIdentityTemplate) -> some View {
        let isActive = viewModel.selectedTeamIdentityTemplateID == template.id
        let isDefault = viewModel.defaultTeamIdentityTemplateID == template.id

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(template.name)
                    .font(.caption.bold())
                    .lineLimit(1)
                Spacer(minLength: 4)
                RinkLensStableActionMenu(
                    title: "Team Profile",
                    width: 390,
                    actions: teamProfileMenuActions(template)
                ) {
                    Image(systemName: "ellipsis.circle")
                        .font(.caption.bold())
                        .foregroundStyle(.white.opacity(0.86))
                        .frame(width: 30, height: 30)
                }
            }

            Text("\(template.homeTeamName) vs \(template.awayTeamName)")
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(.white.opacity(0.72))

            Text(template.scoreboardSettings == nil ? "Teams only" : "Teams + look")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(template.scoreboardSettings == nil ? .white.opacity(0.52) : .cyan.opacity(0.85))

            HStack(spacing: 6) {
                if isActive {
                    Text("ACTIVE")
                        .font(.caption2.bold())
                        .foregroundStyle(.green)
                }
                if isDefault {
                    Text("DEFAULT")
                        .font(.caption2.bold())
                        .foregroundStyle(.yellow)
                }
            }
            .frame(minHeight: 14, alignment: .leading)
        }
        .padding(10)
        .frame(width: 218, alignment: .leading)
        .background(Color.white.opacity(isActive ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isActive ? Color.green.opacity(0.8) : Color.white.opacity(0.14), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.applyTeamIdentityTemplate(template)
            teamTemplateName = template.name
            refreshDriver.bump(reason: "team profile loaded")
        }
    }

    private func teamProfileMenuActions(_ template: TeamIdentityTemplate) -> [RinkLensStableMenuAction] {
        [
            .init(title: "Load names, logos and look", systemImage: "arrow.down.doc") {
                viewModel.applyTeamIdentityTemplate(template)
                teamTemplateName = template.name
                refreshDriver.bump(reason: "team profile menu loaded")
            },
            .init(title: "Set Default", systemImage: "star.fill", isSelected: viewModel.defaultTeamIdentityTemplateID == template.id) {
                viewModel.setDefaultTeamIdentityTemplate(template)
                refreshDriver.bump(reason: "team profile default set")
            },
            .init(title: "Duplicate", systemImage: "plus.square.on.square") {
                duplicateTeamTemplate = template
                duplicateTeamTemplateName = "\(template.name) Copy"
                refreshDriver.bump(reason: "team profile duplicate opened")
            },
            .init(title: "Delete", systemImage: "trash", isDestructive: true) {
                deleteTeamTemplate = template
                refreshDriver.bump(reason: "team profile delete opened")
            }
        ]
    }

    private func teamLogoCard(title: String, image: UIImage?, picker: Binding<PhotosPickerItem?>, remove: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.white)

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.18))
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                } else {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.66))
                }
            }
            .frame(height: 86)

            PhotosPicker(selection: picker, matching: .images) {
                Label("Upload", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button(role: .destructive) {
                remove()
            } label: {
                Label("Remove", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(image == nil)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .broadcastMenuCard(cornerRadius: 14)
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            BroadcastMenuSectionTitle("Live Preview", systemImage: "rectangle.on.rectangle")

            GeometryReader { proxy in
                let previewScale = min(0.50, max(0.34, proxy.size.width / 760.0))
                let previewState = ScoreboardState(
                        homeTeam: viewModel.homeTeamName,
                        awayTeam: viewModel.awayTeamName,
                        homeScore: 3,
                        awayScore: 2,
                        clock: "12:34",
                        period: 2,
                        periodLabel: nil,
                        homeShots: nil,
                        awayShots: nil,
                        homePenalty1Player: nil,
                        homePenalty1Clock: nil,
                        homePenalty2Player: nil,
                        homePenalty2Clock: nil,
                        awayPenalty1Player: nil,
                        awayPenalty1Clock: nil,
                        awayPenalty2Player: nil,
                        awayPenalty2Clock: nil
                    )
                let previewViewer = RinkLensViewerScoreboardSnapshot.acceptedOnly(state: previewState)

                ScorebugView(
                    viewerScoreboard: previewViewer,
                    homeLogo: viewModel.homeLogoImage,
                    awayLogo: viewModel.awayLogoImage,
                    isLive: false,
                    modeStatusText: "Preview",
                    showClockShotsAndPenalties: true,
                    layout: settings.snapshot
                )
                .scaleEffect(previewScale, anchor: .center)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
            }
            .frame(maxWidth: .infinity, minHeight: settings.logoPosition == .centredAboveTeamName ? 150 : 110)
            .clipped()
        }
        .padding(12)
        .broadcastMenuCard(cornerRadius: 14)
    }
}

// MARK: - v0.8.3e Broadcast render isolation


private struct BroadcastScorebugOverlay: View, Equatable {
    let viewerScoreboard: RinkLensViewerScoreboardSnapshot
    let isOCRMode: Bool
    let modeStatusText: String
    let strengthState: StrengthState
    let activePenaltyClocks: [PenaltyClock]
    let homeLogo: UIImage?
    let awayLogo: UIImage?
    let layout: BroadcastScoreboardLayoutSnapshot
    let gameSponsorName: String
    let gameSponsorLogo: UIImage?
    var powerPlayHeight: CGFloat = 42

    static func == (lhs: BroadcastScorebugOverlay, rhs: BroadcastScorebugOverlay) -> Bool {
        lhs.viewerScoreboard.isMateriallyEqual(to: rhs.viewerScoreboard) &&
        lhs.isOCRMode == rhs.isOCRMode &&
        lhs.modeStatusText == rhs.modeStatusText &&
        lhs.strengthState == rhs.strengthState &&
        lhs.activePenaltyClocks == rhs.activePenaltyClocks &&
        lhs.powerPlayHeight == rhs.powerPlayHeight &&
        lhs.layout == rhs.layout &&
        lhs.gameSponsorName == rhs.gameSponsorName &&
        sameImage(lhs.homeLogo, rhs.homeLogo) &&
        sameImage(lhs.awayLogo, rhs.awayLogo) &&
        sameImage(lhs.gameSponsorLogo, rhs.gameSponsorLogo)
    }

    var body: some View {
        ScorebugView(
            viewerScoreboard: viewerScoreboard,
            homeLogo: homeLogo,
            awayLogo: awayLogo,
            isLive: true,
            modeStatusText: modeStatusText,
            showClockShotsAndPenalties: isOCRMode,
            layout: layout,
            gameSponsorName: gameSponsorName,
            gameSponsorLogo: gameSponsorLogo,
            strengthState: strengthState
        )
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct BroadcastZoomPresetControls: View {
    @ObservedObject var viewModel: HockeyScoreboardViewModel

    @State private var isDraggingZoomSlider = false
    @State private var pressedPresetZoom: CGFloat?
    @State private var transientSliderValue: CGFloat = 1.0
    @State private var zoomInteractionOwnsAuxiliaryAdmission = false

    private var minZoom: CGFloat { viewModel.effectiveBroadcastZoomRange.lowerBound }
    private var maxZoom: CGFloat { viewModel.effectiveBroadcastZoomRange.upperBound }
    private var sliderHeight: CGFloat { 420 }

    private var shownZoom: CGFloat {
        // Recovery DB: outside an active finger drag the control displays verified
        // hardware truth, not merely requested intent. A failed optical handoff can
        // therefore never leave the panel claiming 5x while the camera is still 0.5x.
        let raw = isDraggingZoomSlider ? transientSliderValue : viewModel.verifiedBroadcastZoomFactor
        return min(max(raw, minZoom), maxZoom)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            VStack(spacing: 2) {
                Text("Broadcast Zoom")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.96))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Text(BroadcastZoomGranularity.label(for: shownZoom))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.78))
                    .monospacedDigit()

            }
            .frame(width: 128, alignment: .center)

            HStack(alignment: .top, spacing: 8) {
                verticalZoomSlider

                VStack(spacing: 4) {
                    ForEach(Array(viewModel.broadcastZoomPresetFactors.enumerated()), id: \.offset) { _, zoom in
                        zoomButton(BroadcastZoomGranularity.label(for: zoom), zoom: zoom)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: 72, height: sliderHeight + 32, alignment: .center)
                .contentShape(Rectangle())
            }

            HStack(spacing: 6) {
                Button {
                    viewModel.setSmoothBroadcastZoomTransitionsEnabled(!viewModel.smoothBroadcastZoomTransitionsEnabled)
                } label: {
                    Text(viewModel.smoothBroadcastZoomTransitionsEnabled ? "Smooth 1–5 On" : "Smooth 1–5 Off")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(viewModel.smoothBroadcastZoomTransitionsEnabled ? Color.green.opacity(0.34) : Color.white.opacity(0.16))
                        )
                }
                .buttonStyle(.plain)

                RinkLensStableActionMenu(
                    title: "1x–5x Zoom Speed",
                    width: 320,
                    actions: BroadcastZoomTransitionSpeed.allCases.map { speed in
                        .init(
                            title: speed.label,
                            systemImage: "speedometer",
                            isSelected: viewModel.broadcastZoomTransitionSpeed == speed,
                            action: { viewModel.setBroadcastZoomTransitionSpeed(speed) }
                        )
                    }
                ) {
                    Text(viewModel.broadcastZoomTransitionSpeed.label)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(viewModel.smoothBroadcastZoomTransitionsEnabled ? .white : .white.opacity(0.45))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(0.16))
                        )
                }
                .disabled(!viewModel.smoothBroadcastZoomTransitionsEnabled)
            }
            .frame(width: 128, alignment: .trailing)
        }
        .fixedSize(horizontal: true, vertical: true)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 10, x: 0, y: 4)
        .onAppear { transientSliderValue = viewModel.verifiedBroadcastZoomFactor }
        .onDisappear {
            if zoomInteractionOwnsAuxiliaryAdmission {
                zoomInteractionOwnsAuxiliaryAdmission = false
                RinkLensExecutionCoordinator.shared.endOperatorInteraction(
                    route: AppRoute.broadcast.rawValue,
                    source: "BroadcastZoomPresetControls.disappear"
                )
            }
        }
        .onChange(of: viewModel.verifiedBroadcastZoomFactor) { _, newValue in
            if !isDraggingZoomSlider {
                transientSliderValue = newValue
            }
            if let pressedPresetZoom, abs(newValue - pressedPresetZoom) < 0.05 {
                self.pressedPresetZoom = nil
            }
        }
    }

    private var verticalZoomSlider: some View {
        VStack(spacing: 4) {
            Text(BroadcastZoomGranularity.label(for: minZoom))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.78))
                .frame(width: 44, alignment: .center)

            Slider(
                value: Binding(
                    get: { Double(maxZoom + minZoom - shownZoom) },
                    set: { newValue in
                        let range = minZoom...maxZoom
                        let raw = CGFloat(maxZoom + minZoom - newValue)
                        transientSliderValue = BroadcastZoomGestureProjection.displayDraft(raw, range: range)
                        viewModel.previewLiveCameraZoomFromSlider(
                            BroadcastZoomGestureProjection.hardwarePreview(raw, range: range)
                        )
                    }
                ),
                in: Double(minZoom)...Double(maxZoom),
                step: Double(BroadcastZoomGranularity.sliderStep),
                onEditingChanged: { editing in
                    isDraggingZoomSlider = editing
                    if editing {
                        transientSliderValue = viewModel.verifiedBroadcastZoomFactor
                        if !zoomInteractionOwnsAuxiliaryAdmission {
                            zoomInteractionOwnsAuxiliaryAdmission = true
                            RinkLensExecutionCoordinator.shared.beginOperatorInteraction(
                                route: AppRoute.broadcast.rawValue,
                                source: "BroadcastZoomPresetControls.slider",
                                kind: .cameraZoomGesture
                            )
                        }
                    } else {
                        let resolved = BroadcastZoomGestureProjection.committedRequest(
                            transientSliderValue,
                            range: minZoom...maxZoom
                        )
                        transientSliderValue = resolved
                        viewModel.commitLiveCameraZoomFromSlider(resolved)
                        if zoomInteractionOwnsAuxiliaryAdmission {
                            zoomInteractionOwnsAuxiliaryAdmission = false
                            RinkLensExecutionCoordinator.shared.endOperatorInteraction(
                                route: AppRoute.broadcast.rawValue,
                                source: "BroadcastZoomPresetControls.slider"
                            )
                        }
                    }
                }
            )
            .frame(width: sliderHeight)
            .rotationEffect(.degrees(-90))
            .frame(width: 44, height: sliderHeight)

            Text("5x")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.78))
                .frame(width: 44, alignment: .center)
        }
        .frame(width: 48, height: sliderHeight + 32, alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.12))
        )
    }


    private func zoomButton(_ title: String, zoom: CGFloat) -> some View {
        let isAvailable = viewModel.effectiveBroadcastZoomRange.contains(zoom)
        let isApplied = abs(viewModel.verifiedBroadcastZoomFactor - zoom) < 0.05
        let isPressed = isAvailable && (pressedPresetZoom.map { abs($0 - zoom) < 0.05 } ?? false)

        return Button {
            let resolved = BroadcastZoomGranularity.quantize(zoom)
            recordZoomPresetIntent(resolved)
            pressedPresetZoom = resolved
            transientSliderValue = resolved
            isDraggingZoomSlider = false
            viewModel.setLiveCameraZoom(resolved)
        } label: {
            BroadcastZoomPresetLabel(
                title: title,
                isAvailable: isAvailable,
                isApplied: isApplied,
                isPressed: isPressed
            )
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityLabel("Set broadcast zoom to \(title)")
        .accessibilityHint(isAvailable ? "" : "Unavailable while recording on the frozen Wide camera source")
    }

    private func recordZoomPresetIntent(_ zoom: CGFloat) {
        RinkLensStructuredEventLogger.shared.record(
            domain: .camera,
            event: "broadcast_zoom_preset_intent_received",
            entityID: BroadcastZoomGranularity.label(for: zoom),
            previous: ["appliedZoom": BroadcastZoomGranularity.label(for: viewModel.verifiedBroadcastZoomFactor)],
            next: ["requestedZoom": BroadcastZoomGranularity.label(for: zoom)],
            source: "BroadcastZoomPresetControls",
            reason: "Operator zoom intent crossed the Broadcast control boundary",
            authoritativeOwner: "RinkLensCameraControlStore"
        )
    }

}

private struct BroadcastZoomPresetLabel: View {
    let title: String
    let isAvailable: Bool
    let isApplied: Bool
    let isPressed: Bool

    private var foregroundColor: Color {
        isAvailable ? .white : Color.white.opacity(0.30)
    }

    private var fillColor: Color {
        if !isAvailable { return Color.white.opacity(0.07) }
        if isApplied { return Color.white.opacity(0.34) }
        if isPressed { return Color.cyan.opacity(0.40) }
        return Color.white.opacity(0.17)
    }

    private var strokeColor: Color {
        if !isAvailable { return Color.white.opacity(0.12) }
        if isPressed { return Color.cyan.opacity(0.86) }
        return Color.white.opacity(0.30)
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.black))
            .foregroundStyle(foregroundColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(strokeColor, lineWidth: 1)
            )
    }
}


private struct BroadcastImageRelayEventControls: View {
    let onManual: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Label("IMAGE LIVE", systemImage: "rectangle.on.rectangle")
                .font(.system(size: 10, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.cyan.opacity(0.28)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.cyan.opacity(0.70), lineWidth: 1))

            Text("Period recognition and automatic goal/penalty popups run internally. Manual controls are for corrections.")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(2)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: 260, alignment: .leading)

            modeButton("MANUAL", systemImage: "hand.tap.fill", action: onManual)
        }
        .accessibilityElement(children: .contain)
    }

    private func modeButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .black))
                Text(title)
                    .font(.system(size: 8, weight: .black, design: .rounded))
            }
            .foregroundStyle(.white)
            .frame(width: 54, height: 36)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.28)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.24), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct BroadcastManualScoreQuickControls: View {
    @ObservedObject var viewModel: HockeyScoreboardViewModel
    let requestAction: (BroadcastManualQuickAction) -> Void
    let reenableOCR: () -> Void
    var showsPeriodControls: Bool = true

    private var homeScore: Int {
        viewModel.manualOverrideEnabled ? viewModel.overrideHomeScore : (viewModel.state.homeScore ?? viewModel.overrideHomeScore)
    }

    private var guestScore: Int {
        viewModel.manualOverrideEnabled ? viewModel.overrideAwayScore : (viewModel.state.awayScore ?? viewModel.overrideAwayScore)
    }

    private var period: Int {
        viewModel.manualOverrideEnabled ? viewModel.overridePeriod : max(1, viewModel.state.period ?? viewModel.overridePeriod)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            teamControl(
                title: "HOME",
                score: homeScore,
                decrement: { requestAction(.homeMinus) },
                increment: { requestAction(.homePlus) }
            )

            if showsPeriodControls {
                VStack(spacing: 3) {
                    Text("PERIOD")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                    HStack(spacing: 6) {
                        quickButton("−") { requestAction(.periodMinus) }
                        Text("P\(period)")
                            .font(.system(size: 15, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(minWidth: 28)
                        quickButton("+") { requestAction(.periodPlus) }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.10)))
            }

            teamControl(
                title: "GUEST",
                score: guestScore,
                decrement: { requestAction(.guestMinus) },
                increment: { requestAction(.guestPlus) }
            )

            ocrReturnButton
        }
        .accessibilityElement(children: .contain)
    }


    private var ocrReturnButton: some View {
        Button(action: reenableOCR) {
            VStack(spacing: 4) {
                Image(systemName: "eye.fill")
                    .font(.caption.weight(.black))
                Text("RELAY")
                    .font(.caption2.weight(.black))
            }
            .foregroundStyle(.white)
            .frame(width: 42, height: 38)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.green.opacity(0.32)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.28), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Resume Image Relay from manual mode")
    }

    private func teamControl(title: String, score: Int, decrement: @escaping () -> Void, increment: @escaping () -> Void) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))
            HStack(spacing: 6) {
                quickButton("−") { decrement() }
                Text("\(score)")
                    .font(.system(size: 17, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(minWidth: 28)
                quickButton("+") { increment() }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.10)))
    }

    private func quickButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 30, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.28), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct BroadcastManualModeEntryButton: View {
    let onEnableManualMode: () -> Void

    var body: some View {
        Button(action: onEnableManualMode) {
            Label("Manual Mode", systemImage: "hand.tap.fill")
                .font(.caption.weight(.black))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.14)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.26), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Enable manual goal and period controls")
    }
}

private struct IntermissionSponsorReelOverlayView: View {
    let reel: BroadcastIntermissionReelState
    let countdownText: String
    let slideDurationSeconds: Double
    let onDismiss: () -> Void

    private var safeSlideDuration: Double { min(max(slideDurationSeconds, 3.0), 20.0) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            let slide = activeSlide(at: context.date)

            ZStack {
                LinearGradient(
                    colors: [Color.black.opacity(0.84), Color.black.opacity(0.52), Color.black.opacity(0.86)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 22) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(reel.title)
                                .font(.system(size: 26, weight: .black, design: .rounded))
                                .tracking(2.4)
                                .foregroundStyle(.white)
                            Text(reel.subtitle)
                                .font(.headline.weight(.heavy))
                                .foregroundStyle(.white.opacity(0.72))
                        }

                        Spacer(minLength: 0)

                        Button(action: onDismiss) {
                            Label("Start next period", systemImage: "play.fill")
                                .font(.caption.weight(.black))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(Color.white.opacity(0.14), in: Capsule())
                                .overlay(Capsule().stroke(Color.white.opacity(0.20), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .accessibilityLabel("Dismiss intermission sponsor reel")
                    }
                    .padding(.horizontal, 34)
                    .padding(.top, 28)

                    Spacer(minLength: 0)

                    VStack(spacing: 16) {
                        HStack(spacing: 16) {
                            IntermissionClockTile(title: "NEXT PERIOD STARTS IN", value: cleanedCountdownText, monospaced: true)
                            IntermissionClockTile(title: "ACTUAL TIME", value: actualTimeText(context.date), monospaced: true)
                        }

                        Text(reel.nextPeriodLabel)
                            .font(.caption.weight(.black))
                            .tracking(1.4)
                            .foregroundStyle(.white.opacity(0.68))
                    }

                    sponsorCard(slide: slide)
                        .padding(.horizontal, 42)

                    Spacer(minLength: 0)

                    HStack(spacing: 6) {
                        ForEach(Array(reel.sponsorSlides.enumerated()), id: \.element.id) { index, _ in
                            Capsule()
                                .fill(index == activeSlideIndex(at: context.date) ? Color.white.opacity(0.82) : Color.white.opacity(0.22))
                                .frame(width: index == activeSlideIndex(at: context.date) ? 26 : 8, height: 6)
                                .animation(.easeInOut(duration: 0.25), value: activeSlideIndex(at: context.date))
                        }
                    }
                    .frame(height: 10)
                    .opacity(reel.sponsorSlides.count > 1 ? 1.0 : 0.0)
                    .padding(.bottom, 28)
                }
            }
        }
        .onAppear {
            MainThreadStallMonitor.shared.traceSponsorOverlay("intermission reel appeared completed=P\(reel.completedPeriod) next=P\(reel.nextPeriod) slides=\(reel.sponsorSlides.count)")
        }
        .onDisappear {
            MainThreadStallMonitor.shared.traceSponsorOverlay("intermission reel disappeared completed=P\(reel.completedPeriod) next=P\(reel.nextPeriod)")
        }
    }

    private var cleanedCountdownText: String {
        let trimmed = countdownText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "--:--" : trimmed
    }

    private func activeSlideIndex(at date: Date) -> Int {
        guard !reel.sponsorSlides.isEmpty else { return 0 }
        let elapsed = max(0, date.timeIntervalSince(reel.startedAt))
        return Int(elapsed / safeSlideDuration) % reel.sponsorSlides.count
    }

    private func activeSlide(at date: Date) -> SponsorResolvedBroadcastSponsor? {
        guard !reel.sponsorSlides.isEmpty else { return nil }
        return reel.sponsorSlides[activeSlideIndex(at: date)]
    }

    private func actualTimeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    @ViewBuilder
    private func sponsorCard(slide: SponsorResolvedBroadcastSponsor?) -> some View {
        HStack(spacing: 22) {
            if let logoData = slide?.logoData, let image = UIImage(data: logoData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 128, height: 82)
                    .padding(16)
                    .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.20), lineWidth: 1))
            } else {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 54, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.82))
                    .frame(width: 128, height: 82)
                    .padding(16)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(slide?.subtitle ?? "INTERMISSION PARTNER")
                    .font(.caption.weight(.black))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.62))
                Text(slide?.displayTitle ?? "Sponsors will appear here")
                    .font(.system(size: 46, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.55)
                if let player = slide?.playerLabel, !player.isEmpty {
                    Text(player)
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(26)
        .frame(maxWidth: 920)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 1.4))
        .shadow(color: Color.black.opacity(0.35), radius: 28, x: 0, y: 14)
    }
}

private struct IntermissionClockTile: View {
    let title: String
    let value: String
    let monospaced: Bool

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2.weight(.black))
                .tracking(1.1)
                .foregroundStyle(.white.opacity(0.58))
            Text(value)
                .font(.system(size: 34, weight: .black, design: monospaced ? .monospaced : .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .frame(minWidth: 230)
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(Color.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1))
    }
}

private struct SponsorBroadcastOverlayView: View {
    let configuration: SponsorCatalogueConfiguration

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    if configuration.league.isEnabled {
                        SponsorBroadcastBadge(
                            title: configuration.league.name,
                            subtitle: "LEAGUE",
                            imageData: configuration.league.logoData,
                            alignment: .leading
                        )
                    }

                    Spacer(minLength: 0)

                    if let season = sponsor(for: configuration.placements.seasonSponsorID) {
                        SponsorBroadcastBadge(
                            title: season.displayName,
                            subtitle: "SEASON SPONSOR",
                            imageData: season.logoData,
                            alignment: .trailing
                        )
                    }
                }
                .padding(.top, BroadcastCompositeStandard.previewTopInset(in: geometry.size))
                .padding(.horizontal, BroadcastCompositeStandard.previewSideInset(in: geometry.size))

                Spacer(minLength: 0)
            }
        }
        .onAppear {
            MainThreadStallMonitor.shared.traceSponsorOverlay("broadcast sponsor overlay appeared activeSponsors=\(configuration.sponsors.filter { $0.isActive }.count) season=\(sponsor(for: configuration.placements.seasonSponsorID)?.displayName ?? "none") league=\(configuration.league.isEnabled ? configuration.league.name : "off") composite=\(BroadcastCompositeStandard.version)")
        }
    }

    private func sponsor(for id: UUID?) -> SponsorCatalogueSponsor? {
        guard let id else { return nil }
        return configuration.sponsors.first(where: { $0.id == id && $0.isActive })
    }
}

private struct SponsorBroadcastBadge: View {
    let title: String
    let subtitle: String
    let imageData: Data?
    let alignment: HorizontalAlignment

    var body: some View {
        HStack(spacing: 9) {
            if let image = logoImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 46, height: 30)
                    .padding(5)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            VStack(alignment: alignment, spacing: 1) {
                Text(subtitle)
                    .font(.caption2.weight(.black))
                    .foregroundStyle(.white.opacity(0.58))
                Text(title.isEmpty ? "Sponsor" : title)
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.45), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))
    }

    private var logoImage: UIImage? {
        guard let imageData else { return nil }
        return UIImage(data: imageData)
    }
}

private struct BroadcastBannerOverlay: View, Equatable {
    let banner: BroadcastEvent?
    let homeLogo: UIImage?
    let awayLogo: UIImage?
    let homeTeamName: String
    let awayTeamName: String
    let useActualTeamNames: Bool
    let goalTeamLogosEnabled: Bool
    let penaltyTeamLogosEnabled: Bool

    static func == (lhs: BroadcastBannerOverlay, rhs: BroadcastBannerOverlay) -> Bool {
        lhs.banner == rhs.banner &&
        sameImage(lhs.homeLogo, rhs.homeLogo) &&
        sameImage(lhs.awayLogo, rhs.awayLogo) &&
        lhs.homeTeamName == rhs.homeTeamName &&
        lhs.awayTeamName == rhs.awayTeamName &&
        lhs.useActualTeamNames == rhs.useActualTeamNames &&
        lhs.goalTeamLogosEnabled == rhs.goalTeamLogosEnabled &&
        lhs.penaltyTeamLogosEnabled == rhs.penaltyTeamLogosEnabled
    }

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if let banner {
                bannerView(for: banner)
                    .id(banner.id)
                    .padding(.bottom, 56)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private func bannerView(for event: BroadcastEvent) -> some View {
        switch event.type {
        case .penalty, .penalties, .powerPlayStart, .penaltyEnd, .timeoutStart, .timeoutEnd:
            PenaltyBannerView(
                event: event,
                homeLogo: homeLogo,
                awayLogo: awayLogo,
                homeTeamName: homeTeamName,
                awayTeamName: awayTeamName,
                useActualTeamNames: event.popupPolicySnapshot?.useActualTeamNames ?? useActualTeamNames,
                teamLogosEnabled: event.popupPolicySnapshot?.penaltyTeamLogosEnabled ?? penaltyTeamLogosEnabled
            )
        default:
            GoalBannerView(
                event: event,
                homeLogo: homeLogo,
                awayLogo: awayLogo,
                homeTeamName: homeTeamName,
                awayTeamName: awayTeamName,
                useActualTeamNames: event.popupPolicySnapshot?.useActualTeamNames ?? useActualTeamNames,
                teamLogosEnabled: event.popupPolicySnapshot?.goalTeamLogosEnabled ?? goalTeamLogosEnabled
            )
        }
    }
}

private func sameImage(_ lhs: UIImage?, _ rhs: UIImage?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
        return true
    case let (left?, right?):
        return left === right
    default:
        return false
    }
}


// MARK: - Authoritative Broadcast camera behaviour projection

extension HockeyScoreboardViewModel {
    var confirmBroadcastRecordingStop: Bool { cameraControlStore.snapshot.confirmRecordingStop }
    var broadcastZoomPresetFactors: [CGFloat] { cameraControlStore.snapshot.broadcastZoomPresetFactors.map { value in CGFloat(value) } }
    var broadcastTorchEnabled: Bool { cameraControlStore.snapshot.broadcastTorchEnabled }
    var showBroadcastCompositionGrid: Bool { cameraControlStore.snapshot.showBroadcastCompositionGrid }
    var showBroadcastLevelGuide: Bool { cameraControlStore.snapshot.showBroadcastLevelGuide }
    var holdToLockBroadcastCamera: Bool { cameraControlStore.snapshot.holdToLockBroadcastCamera }
    var lockBroadcastFocusOnHold: Bool { cameraControlStore.snapshot.lockFocusOnHold }
    var lockBroadcastExposureOnHold: Bool { cameraControlStore.snapshot.lockExposureOnHold }
    var lockBroadcastWhiteBalanceOnHold: Bool { cameraControlStore.snapshot.lockWhiteBalanceOnHold }

    func setConfirmBroadcastRecordingStop(_ value: Bool) {
        cameraControlStore.setConfirmRecordingStop(value, source: "BroadcastCameraBehaviourSheet", reason: "Operator changed recording stop safeguard")
    }

    func setBroadcastZoomPreset(_ value: CGFloat, at index: Int) {
        cameraControlStore.setBroadcastZoomPreset(Double(value), at: index, source: "BroadcastCameraBehaviourSheet", reason: "Operator edited Broadcast framing preset")
    }

    func setShowBroadcastCompositionGrid(_ value: Bool) {
        cameraControlStore.setShowBroadcastCompositionGrid(value, source: "BroadcastCameraBehaviourSheet", reason: "Operator changed composition guide visibility")
    }

    func setShowBroadcastLevelGuide(_ value: Bool) {
        cameraControlStore.setShowBroadcastLevelGuide(value, source: "BroadcastCameraBehaviourSheet", reason: "Operator changed horizon guide visibility")
    }

    func setHoldToLockBroadcastCamera(_ value: Bool) {
        cameraControlStore.setHoldToLockBroadcastCamera(value, source: "BroadcastCameraBehaviourSheet", reason: "Operator changed preview hold-to-lock policy")
    }

    func setLockBroadcastFocusOnHold(_ value: Bool) {
        cameraControlStore.setLockFocusOnHold(value, source: "BroadcastCameraBehaviourSheet", reason: "Operator changed focus lock policy")
    }

    func setLockBroadcastExposureOnHold(_ value: Bool) {
        cameraControlStore.setLockExposureOnHold(value, source: "BroadcastCameraBehaviourSheet", reason: "Operator changed exposure lock policy")
    }

    func setLockBroadcastWhiteBalanceOnHold(_ value: Bool) {
        cameraControlStore.setLockWhiteBalanceOnHold(value, source: "BroadcastCameraBehaviourSheet", reason: "Operator changed white-balance lock policy")
    }

    func setBroadcastTorchEnabled(_ enabled: Bool, reason: String) {
        cameraControlStore.setBroadcastTorchEnabled(enabled, source: "BroadcastCameraBehaviourSheet", reason: reason)
        broadcastPreviewCameraService.setTorchEnabled(enabled, label: "Broadcast camera", reason: reason)
    }

    func toggleSelectedBroadcastCameraParameters(
        reason: String,
        completion: @escaping @MainActor @Sendable (HockeyCameraService.BroadcastCameraParameterToggleResult) -> Void
    ) {
        broadcastPreviewCameraService.toggleCameraParameters(
            focus: lockBroadcastFocusOnHold,
            exposure: lockBroadcastExposureOnHold,
            whiteBalance: lockBroadcastWhiteBalanceOnHold,
            label: "Broadcast camera",
            reason: reason,
            completion: completion
        )
    }

    func unlockBroadcastCameraParameters(reason: String) {
        broadcastPreviewCameraService.unlockStationaryRole(label: "Broadcast camera", reason: reason)
    }

    /// One command path is shared by the visible Broadcast recording controls.
    func requestBroadcastRecordingStartOrResume(source: String) {
        let recorder = AppContainer.shared.recordingEngine
        if recorder.canResume {
            recorder.resumeRecording()
            return
        }
        guard let transactionID = recorder.beginRecordingStartPreflight(source: source) else { return }
        prepareBroadcastRecordingStart(transactionID: transactionID) { [weak self] validation in
            guard recorder.completeRecordingStartPreflight(
                transactionID: transactionID,
                accepted: validation.isValid,
                reason: validation.isValid ? "Verified active Broadcast source accepted" : (validation.failureReason ?? "Broadcast source validation rejected")
            ) else { return }
            guard let self, recorder.applyCameraSourceValidation(validation, reason: "\(source) preflight") else { return }
            self.validateActiveTeamIdentityForBroadcastPresentation(source: source)
            SponsorCatalogueStore.shared.refreshRecordingOverlaySnapshot(reason: "recording fast start from \(source)")
            let sourceContext = BroadcastRecordingStage8PixelBufferFrameProvider.makeSourceContext(
                viewModel: self,
                prewarmedOverlay: BroadcastOverlayCIImageCache.shared.currentCachedImage(outputSize: recorder.recordingOutputSize)
            )
            recorder.startRecording(
                homeTeam: self.homeTeamName,
                awayTeam: self.awayTeamName,
                // Recovery CW: hidden Season/Fixture configuration is dormant
                // and cannot silently rename recordings from an old snapshot.
                resolvedRecordingBaseName: nil,
                pixelBufferFrameSource: sourceContext,
                overlaySnapshotProvider: { BroadcastRecordingStage8PixelBufferFrameProvider.makeOverlayCIImage(viewModel: self) }
            )
            BroadcastRecordingStage8PixelBufferFrameProvider.prewarmOverlay(viewModel: self) { overlay in
                sourceContext.updateOverlay(overlay)
            }
        }
    }

    func requestBroadcastRecordingPause(source: String) {
        guard AppContainer.shared.recordingEngine.canPause else { return }
        AppContainer.shared.recordingEngine.pauseRecording()
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "recording_pause_command",
            entityID: nil,
            previous: ["state": "recording"],
            next: ["state": "paused"],
            source: source,
            reason: "Operator requested pause"
        )
    }

    func requestBroadcastRecordingStop(source: String) {
        let recorder = AppContainer.shared.recordingEngine
        guard recorder.canStop else { return }
        if recorder.cancelRecordingStartPreflight(source: source) {
            return
        }
        if RinkLensRiskFeaturePolicy.isEnabled(.typedRecordingStopOriginV23) {
            recorder.stopRecording(reason: .operatorRequested)
            RinkLensStructuredEventLogger.shared.record(
                domain: .recording,
                event: "recording_stop_command",
                entityID: nil,
                previous: ["state": "recording-or-paused"],
                next: ["state": "stopping", "origin": RecordingStopReason.operatorRequested.rawValue],
                source: source,
                reason: "Operator requested Broadcast recording stop"
            )
        } else {
            recorder.stopRecording(origin: source)
        }
        if !externalOCRMultiCamActive {
            broadcastRecordingCameraService.disableRecordingFrameCapture(reason: "recording stopped by \(source)")
        }
    }

}

extension HockeyScoreboardViewModel {
    func setCustomRecordingVideoSettingsEnabled(_ enabled: Bool) {
        let recorder = AppContainer.shared.recordingEngine
        recorder.setCustomVideoSettingsEnabled(
            enabled,
            source: "ProductionSetup.VideoQuality",
            reason: enabled ? "Operator enabled custom recording output" : "Operator restored managed recording defaults"
        )
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "recording_compression_policy_changed",
            entityID: "recording-output-policy",
            previous: ["mode": enabled ? "managed" : "custom-compression"],
            next: [
                "mode": enabled ? "custom-compression" : "managed",
                "dimensionsAndCadence": "verified-master-picture"
            ],
            source: "ProductionSetup.VideoQuality",
            reason: "Recording compression changed without issuing camera intent",
            authoritativeOwner: "BroadcastRecordingManager"
        )
    }

    func setCustomRecordingOutputMode(_ mode: BroadcastRecordingProfile.OutputMode) {
        guard let capability = matchingLiveCapability(for: mode) else {
            statusMessage = "\(mode.compactLabel) is not available from the selected Broadcast camera. Choose another mode or camera."
            RinkLensStructuredEventLogger.shared.record(
                domain: .recording,
                event: "recording_output_mode_rejected",
                entityID: "recording-output-policy",
                previous: ["mode": AppContainer.shared.recordingEngine.customVideoOutputMode.rawValue],
                next: ["requested": mode.rawValue, "applied": "unchanged"],
                source: "ProductionSetup.VideoQuality",
                reason: "Selected Broadcast camera does not expose the requested exact mode"
            )
            return
        }
        AppContainer.shared.recordingEngine.setCustomVideoOutputMode(
            mode,
            source: "ProductionSetup.VideoQuality",
            reason: "Operator selected recording dimensions and cadence"
        )
        selectLiveCapabilityProfile(id: capability.id)
    }

    func recordingModeIsAvailable(_ mode: BroadcastRecordingProfile.OutputMode) -> Bool {
        matchingLiveCapability(for: mode) != nil
    }

    private func requestRecordingCaptureMode(_ mode: BroadcastRecordingProfile.OutputMode, reason: String) {
        guard let capability = matchingLiveCapability(for: mode) else {
            statusMessage = "Recording output is set to \(mode.compactLabel), but this exact camera mode is not currently listed. Recording preflight will verify the active source before starting."
            return
        }
        selectLiveCapabilityProfile(id: capability.id)
    }

    private func matchingLiveCapability(for mode: BroadcastRecordingProfile.OutputMode) -> HockeyCameraService.CapabilityProfileOption? {
        let requested = mode.resolution.size
        let requestedWidth = Int32(max(requested.width, requested.height))
        let requestedHeight = Int32(min(requested.width, requested.height))
        return liveCameraService.capabilityProfiles.first { option in
            let width = max(option.width, option.height)
            let height = min(option.width, option.height)
            return width == requestedWidth
                && height == requestedHeight
                && option.nominalFPS == mode.frameRate.rawValue
                && option.isAvailable
        }
    }
}

// MARK: - Broadcast camera behaviour menu

/// Owns camera-menu presentation independently from BroadcastView. Tapping this
/// control invalidates only this small launcher, not the live preview, scorebug,
/// recording controls, or the rest of the Broadcast render tree.
private struct BroadcastCameraControlLauncher: View {
    let viewModel: HockeyScoreboardViewModel
    @State private var isPresented = false

    var body: some View {
        Button {
            RinkLensStructuredEventLogger.shared.record(
                domain: .navigation,
                event: "broadcast_control_handler_received",
                entityID: "camera-panel-open",
                previous: ["handler": "waiting"],
                next: ["handler": "received", "presentationOwner": "BroadcastCameraControlLauncher"],
                source: "BroadcastCameraControlLauncher",
                reason: "Camera menu presentation is isolated from the Broadcast render tree",
                authoritativeOwner: "BroadcastCameraControlLauncher"
            )
            // This is presentation state only. Suppress the system sheet's
            // launch animation so the acknowledged 71ms content mount is also
            // perceived immediately by the operator.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isPresented = true
            }
        } label: {
            Label("Camera", systemImage: "video.fill")
                .font(.caption.weight(.black))
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
        }
        .background(Color.white.opacity(0.14), in: Capsule())
        .foregroundStyle(.white)
        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
        .accessibilityLabel("Open Broadcast camera controls")
        .sheet(isPresented: $isPresented) {
            BroadcastCameraBehaviourSheet(
                viewModel: viewModel,
                onClose: { isPresented = false }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }
}

enum BroadcastCameraBehaviourPage: String, CaseIterable, Identifiable {
    case image = "Image Behaviour"
    case framing = "Framing Presets"
    case aids = "Viewfinder Aids"
    case safeguards = "Capture Safeguards"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .safeguards: return "checkmark.shield.fill"
        case .framing: return "viewfinder"
        case .image: return "camera.aperture"
        case .aids: return "square.grid.3x3"
        }
    }
}

struct BroadcastCameraBehaviourSheet: View {
    let viewModel: HockeyScoreboardViewModel
    @ObservedObject private var controls: RinkLensCameraControlStore
    @ObservedObject private var camera: HockeyCameraService
    @ObservedObject private var recorder: RecordingEngine
    @State private var selectedPage: BroadcastCameraBehaviourPage = .image
    let onClose: () -> Void

    init(viewModel: HockeyScoreboardViewModel, onClose: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onClose = onClose
        _controls = ObservedObject(wrappedValue: viewModel.cameraControlStore)
        _camera = ObservedObject(wrappedValue: viewModel.broadcastPreviewCameraService)
        _recorder = ObservedObject(wrappedValue: BroadcastRecordingManager.shared)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                BroadcastMenuBackgroundView()
                VStack(spacing: 0) {
                    pagePicker
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            switch selectedPage {
                            case .safeguards: safeguardsPage
                            case .framing: framingPage
                            case .image: imagePage
                            case .aids: aidsPage
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 26)
                    }
                }
            }
            .navigationTitle("Broadcast Camera")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { onClose() }.fontWeight(.semibold)
                }
            }
        }
        .broadcastMenuText()
        .onAppear {
            RinkLensStructuredEventLogger.shared.record(
                domain: .navigation,
                event: "broadcast_camera_sheet_appeared",
                entityID: "camera-panel",
                previous: ["presentation": "requested"],
                next: ["presentation": "visible"],
                source: "BroadcastCameraBehaviourSheet",
                reason: "Physical presentation acknowledgement for Camera button latency",
                authoritativeOwner: "BroadcastCameraControlLauncher"
            )
        }
    }

    private var pagePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(BroadcastCameraBehaviourPage.allCases) { page in
                    Button { selectedPage = page } label: {
                        Label(page.rawValue, systemImage: page.icon)
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .frame(minWidth: 165)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(page == selectedPage ? .black : .white.opacity(0.72))
                    .background(page == selectedPage ? Color.white : Color.white.opacity(0.08))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
                }
            }
            .padding(6)
        }
        .background(Color.black.opacity(0.48))
        .clipShape(Capsule())
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var safeguardsPage: some View {
        VStack(spacing: 14) {
            settingsCard(title: "Recording protection", subtitle: "Keep the live controls fast while reducing accidental recording changes.", icon: "record.circle") {
                Toggle("Confirm before ending a recording", isOn: Binding(
                    get: { controls.snapshot.confirmRecordingStop },
                    set: { viewModel.setConfirmBroadcastRecordingStop($0) }
                ))
            }
        }
    }

    private var framingPage: some View {
        VStack(spacing: 14) {
            settingsCard(title: "Four framing buttons", subtitle: "Set the four zoom positions shown beside the Broadcast preview.", icon: "rectangle.and.hand.point.up.left") {
                ForEach(0..<4, id: \.self) { index in
                    zoomPresetRow(index: index)
                    if index < 3 { Divider().overlay(.white.opacity(0.12)) }
                }
            }
            settingsCard(title: "Zoom response", subtitle: "Choose whether framing changes glide or move immediately.", icon: "arrow.left.and.right") {
                Toggle("Smooth framing changes", isOn: Binding(
                    get: { controls.snapshot.smoothBroadcastZoomTransitionsEnabled },
                    set: { viewModel.setSmoothBroadcastZoomTransitionsEnabled($0) }
                ))
                Divider().overlay(.white.opacity(0.12))
                Picker("Transition pace", selection: Binding(
                    get: { controls.snapshot.broadcastZoomTransitionSpeed },
                    set: { viewModel.setBroadcastZoomTransitionSpeed($0) }
                )) {
                    ForEach(BroadcastZoomTransitionSpeed.allCases) { speed in
                        Text(speed.label).tag(speed)
                    }
                }
                .disabled(!controls.snapshot.smoothBroadcastZoomTransitionsEnabled)
            }
        }
    }

    private var imagePage: some View {
        VStack(spacing: 14) {
            settingsCard(title: "Broadcast quality", subtitle: "Camera cadence and stream output use one profile selected in Stream Setup.", icon: "camera.aperture") {
                HStack(spacing: 10) {
                    Label(controls.snapshot.broadcastProductionProfile.rawValue, systemImage: "checkmark.seal.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.cyan)
                    Spacer()
                    Text(controls.snapshot.broadcastProductionProfile.compactSummary)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white.opacity(0.76))
                }
                Text(controls.snapshot.broadcastProductionProfile.operatorDetailText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.68))
                Text("Change this once in Stream Setup. Camera Control remains for camera selection, zoom, exposure and stabilisation.")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.58))
                Text(viewModel.broadcastImageQualityPhysicalStatusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(recorder.isRecording || recorder.isPaused ? Color.orange : Color.green)
                    .fixedSize(horizontal: false, vertical: true)
                Divider().overlay(.white.opacity(0.12))
                Text(camera.broadcastImageQualityStatusText)
                    .font(.subheadline.weight(.bold))
                Text(camera.broadcastImageQualityRecommendationText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.68))
                HStack(spacing: 10) {
                    Text(camera.broadcastActiveLensText)
                    Spacer()
                    Text(camera.broadcastAppliedCadenceText)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.72))
                Text("ISO: \(Int(camera.isoValue)) • \(camera.shutterSpeedText)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.72))
                Text(camera.lowLightBoostStatusText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
                Text(camera.automaticFrameRateStatusText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
                Text(camera.broadcastImagingCapabilitiesText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.52))
                    .fixedSize(horizontal: false, vertical: true)
            }
            settingsCard(title: "Movement and light", subtitle: camera.selectedCameraLabel, icon: "camera.aperture") {
                Toggle("Broadcast stabilisation", isOn: Binding(
                    get: { controls.snapshot.broadcastVideoStabilisationEnabled },
                    set: { viewModel.setBroadcastVideoStabilisationEnabled($0, source: "BroadcastCameraBehaviourSheet", reason: "Operator changed image behaviour") }
                ))
                Text(camera.stabilisationStatusText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
                Divider().overlay(.white.opacity(0.12))
                Toggle("Torch light", isOn: Binding(
                    get: { controls.snapshot.broadcastTorchEnabled },
                    set: { viewModel.setBroadcastTorchEnabled($0, reason: "Operator changed Broadcast torch") }
                ))
                .disabled(!camera.supportsTorchControl && camera.selectedCameraPosition != .back)
                Text(camera.torchStatusText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
            }
            settingsCard(title: "Preview hold lock / Auto", subtitle: "Hold once to lock the selected behaviours. Hold again to return them to Auto.", icon: "lock.fill") {
                Toggle("Hold preview to lock or unlock", isOn: Binding(
                    get: { controls.snapshot.holdToLockBroadcastCamera },
                    set: { viewModel.setHoldToLockBroadcastCamera($0) }
                ))
                Divider().overlay(.white.opacity(0.12))
                Toggle("Hold locks focus", isOn: Binding(
                    get: { controls.snapshot.lockFocusOnHold },
                    set: { viewModel.setLockBroadcastFocusOnHold($0) }
                )).disabled(!controls.snapshot.holdToLockBroadcastCamera)
                Toggle("Hold locks brightness", isOn: Binding(
                    get: { controls.snapshot.lockExposureOnHold },
                    set: { viewModel.setLockBroadcastExposureOnHold($0) }
                )).disabled(!controls.snapshot.holdToLockBroadcastCamera)
                Toggle("Hold locks colour balance", isOn: Binding(
                    get: { controls.snapshot.lockWhiteBalanceOnHold },
                    set: { viewModel.setLockBroadcastWhiteBalanceOnHold($0) }
                )).disabled(!controls.snapshot.holdToLockBroadcastCamera)
                Divider().overlay(.white.opacity(0.12))
                Button("Return focus, brightness and colour to Auto now") {
                    viewModel.unlockBroadcastCameraParameters(reason: "Operator selected Return to Auto")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var aidsPage: some View {
        VStack(spacing: 14) {
            settingsCard(title: "Preview guides", subtitle: "These guides help frame the rink and are never drawn into the recorded video.", icon: "viewfinder.circle") {
                Toggle("Composition grid", isOn: Binding(
                    get: { controls.snapshot.showBroadcastCompositionGrid },
                    set: { viewModel.setShowBroadcastCompositionGrid($0) }
                ))
                Divider().overlay(.white.opacity(0.12))
                Toggle("Horizon guide", isOn: Binding(
                    get: { controls.snapshot.showBroadcastLevelGuide },
                    set: { viewModel.setShowBroadcastLevelGuide($0) }
                ))
            }
        }
    }

    private func zoomPresetRow(index: Int) -> some View {
        let presets = controls.snapshot.broadcastZoomPresetFactors
        let value = presets.indices.contains(index) ? CGFloat(presets[index]) : CGFloat(index + 1)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Button \(index + 1)").fontWeight(.semibold)
                Spacer()
                Text(String(format: "%.1fx", Double(value))).monospacedDigit().foregroundStyle(.white.opacity(0.72))
            }
            Slider(value: Binding(
                get: { Double(value) },
                set: { viewModel.setBroadcastZoomPreset(CGFloat($0), at: index) }
            ), in: 0.5...5.0, step: 0.1)
        }
    }

    private func settingsCard<Content: View>(title: String, subtitle: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            BroadcastMenuHeaderLabel(title: title, subtitle: subtitle, systemImage: icon)
            content()
        }
        .padding(16)
        .broadcastMenuCard(cornerRadius: 14)
    }
}

// MARK: - Preview-only guides

struct BroadcastCompositionGridOverlay: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                let width = proxy.size.width
                let height = proxy.size.height
                for part in [CGFloat(1.0 / 3.0), CGFloat(2.0 / 3.0)] {
                    path.move(to: CGPoint(x: width * part, y: 0))
                    path.addLine(to: CGPoint(x: width * part, y: height))
                    path.move(to: CGPoint(x: 0, y: height * part))
                    path.addLine(to: CGPoint(x: width, y: height * part))
                }
            }
            .stroke(Color.white.opacity(0.48), lineWidth: 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

@MainActor
final class BroadcastHorizonMotionModel: ObservableObject {
    @Published private(set) var rollDegrees: Double = 0
    @Published private(set) var orientationText = "Landscape guide awaiting motion"
    private let manager = CMMotionManager()

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 20.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let activeWindowScene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first(where: { $0.activationState == .foregroundActive })
            let orientation: UIInterfaceOrientation
            if #available(iOS 26.0, *) {
                orientation = activeWindowScene?.effectiveGeometry.interfaceOrientation ?? .landscapeLeft
            } else {
                orientation = activeWindowScene?.interfaceOrientation ?? .landscapeLeft
            }
            let gravity = motion.gravity
            let screenGravity: (x: Double, y: Double)
            switch orientation {
            case .landscapeLeft:
                screenGravity = (-gravity.y, gravity.x)
            case .landscapeRight:
                screenGravity = (gravity.y, -gravity.x)
            case .portraitUpsideDown:
                screenGravity = (-gravity.x, -gravity.y)
            default:
                screenGravity = (gravity.x, gravity.y)
            }
            // The angle is derived after converting device gravity into the
            // final screen coordinate system. In level landscape this is zero,
            // so the guide starts horizontally rather than vertically.
            self.rollDegrees = atan2(screenGravity.x, -screenGravity.y) * 180.0 / .pi
            self.orientationText = "Landscape horizon • \(Int(self.rollDegrees.rounded()))°"
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }
}

struct BroadcastHorizonGuideOverlay: View {
    @StateObject private var motion = BroadcastHorizonMotionModel()

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                Rectangle().frame(width: 90, height: 2)
                Circle().frame(width: 8, height: 8)
                Rectangle().frame(width: 90, height: 2)
            }
            .foregroundStyle(abs(motion.rollDegrees) < 1.5 ? Color.green : Color.white)
            .rotationEffect(.degrees(-motion.rollDegrees))
            .overlay(alignment: .top) {
                Text(motion.orientationText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.78))
                    .offset(y: -22)
            }
            .padding(.bottom, 54)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { motion.start() }
        .onDisappear { motion.stop() }
    }
}

#endif
