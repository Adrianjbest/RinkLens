// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import Foundation

// STYLE2 central design system migration: operator chrome/fonts use RinkLensDesignSystem where safe.

// MARK: - RinkLens NextGen Camera Setup Module

/// Dedicated Command Centre camera setup workspace.
///
/// UX12w keeps Settings -> Camera flat with Broadcast / Scoreboard sub-tabs, then
/// moves advanced recognition tuning into the Scoreboard tab and hides manual camera controls
/// when automatic focus, exposure and white-balance controls are enabled.
private enum CameraSettingsSubTab: String, CaseIterable, Identifiable {
    case broadcast
    case ocr

    var id: String { rawValue }

    var title: String {
        switch self {
        case .broadcast: return "Broadcast"
        case .ocr: return "Scoreboard"
        }
    }

    var systemImage: String {
        switch self {
        case .broadcast: return "video.fill"
        case .ocr: return "rectangle.on.rectangle"
        }
    }

    var summary: String {
        switch self {
        case .broadcast: return "Live view, recording, clips and future stream output."
        case .ocr: return "Scoreboard source, relay zones and internal recognition stability."
        }
    }
}

struct CameraSetupRouteShellView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var runtimeStatus: AppRuntimeStatus
    @ObservedObject var viewModel: HockeyScoreboardViewModel
    @ObservedObject private var recorder = BroadcastRecordingManager.shared
    @State private var selectedCameraTab: CameraSettingsSubTab = .broadcast

    let embeddedInSettings: Bool

    init(viewModel: HockeyScoreboardViewModel, embeddedInSettings: Bool = false) {
        self.viewModel = viewModel
        self.embeddedInSettings = embeddedInSettings
    }

    @ViewBuilder
    var body: some View {
        if embeddedInSettings {
            cameraContent
                .preferredColorScheme(.dark)
                .onAppear(perform: handleAppear)
        } else {
            NavigationStack {
                cameraContent
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("Camera Setup -> Command Centre"))
                                coordinator.navigate(to: .commandCentre)
                            } label: {
                                Label("Command Centre", systemImage: "chevron.left")
                            }
                        }
                    }
            }
            .background(RinkLensDesignSystem.screenBackground)
            .rinkLensOperatorChrome("Camera Setup")
            .preferredColorScheme(.dark)
            .onAppear(perform: handleAppear)
        }
    }

    @ViewBuilder
    private var cameraContent: some View {
        if RinkLensRiskFeaturePolicy.isEnabled(.settingsCameraSelectionOnlyV10) {
            if embeddedInSettings {
                CameraSetupSettingsEmbeddedView(viewModel: viewModel)
                    .frame(maxWidth: 1060, alignment: .center)
                    .frame(maxWidth: .infinity)
            } else {
                ZStack {
                    BroadcastMenuBackgroundView()

                    ScrollView {
                        CameraSetupSettingsEmbeddedView(viewModel: viewModel)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 22)
                            .frame(maxWidth: 1060, alignment: .center)
                            .frame(maxWidth: .infinity)
                    }
                    .rinkLensScrollPerformance("CameraSelection")
                }
            }
        } else if embeddedInSettings {
            LazyVStack(alignment: .leading, spacing: 16) {
                cameraHeader
                statusOverviewCard
                cameraSubTabsCard
                if recorder.canStop { recordingLockCard }
                selectedCameraTabContent
            }
            .frame(maxWidth: 1060, alignment: .center)
            .frame(maxWidth: .infinity)
        } else {
            ZStack {
                BroadcastMenuBackgroundView()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        cameraHeader
                        statusOverviewCard
                        cameraSubTabsCard
                        if recorder.canStop { recordingLockCard }
                        selectedCameraTabContent
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 22)
                    .frame(maxWidth: 1060, alignment: .center)
                    .frame(maxWidth: .infinity)
                }
                .rinkLensScrollPerformance("CameraSetupLegacy")
            }
        }
    }

    private func handleAppear() {
        runtimeStatus.markCameraSetupVisible(viewModel: viewModel)
        // R16: appearance is presentation-only. Device notifications, startup
        // preload and explicit Refresh own topology/capability invalidation.
        MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("Camera selection appeared - cached snapshot only"))
    }

    private var cameraHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            if !embeddedInSettings {
                Button {
                    MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("Camera Setup -> Command Centre"))
                    coordinator.navigate(to: .commandCentre)
                } label: {
                    Label("Command Centre", systemImage: "chevron.left")
                        .font(RinkLensDesignSystem.font(.caption))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                }
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
            }

            Image(systemName: "camera.viewfinder")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("Camera")
                    .font(embeddedInSettings ? RinkLensDesignSystem.font(.cardTitle) : RinkLensDesignSystem.font(.screenTitle))
                    .foregroundStyle(RinkLensDesignSystem.primaryText)
                Text("Broadcast and Scoreboard are separated into simple sub-tabs so each camera setup stays short and clear.")
                    .font(embeddedInSettings ? RinkLensDesignSystem.font(.caption) : RinkLensDesignSystem.font(.bodyStrong))
                    .foregroundStyle(embeddedInSettings ? RinkLensDesignSystem.mutedText : RinkLensDesignSystem.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(embeddedInSettings ? 18 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if embeddedInSettings {
                RoundedRectangle(cornerRadius: RinkLensDesignSystem.cardCornerRadius, style: .continuous)
                    .fill(RinkLensDesignSystem.cardBackground)
            }
        }
        .overlay {
            if embeddedInSettings {
                RoundedRectangle(cornerRadius: RinkLensDesignSystem.cardCornerRadius, style: .continuous)
                    .stroke(RinkLensDesignSystem.border, lineWidth: 1)
            }
        }
    }

    private var statusOverviewCard: some View {
        CameraSettingsCard(title: "Current setup", subtitle: "Quick check before changing camera controls.", systemImage: "checkmark.circle.fill") {
            VStack(alignment: .leading, spacing: 8) {
                CameraSetupRow(title: "Broadcast Camera", value: broadcastCameraStatusText)
                CameraSetupRow(title: "Scoreboard Camera", value: ocrCameraStatusText)

                if camerasAppearToMatch {
                    cameraConflictWarning
                } else {
                    Label("Camera roles are separated or one role is intentionally disabled", systemImage: "checkmark.seal.fill")
                        .font(RinkLensDesignSystem.font(.caption))
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private var recordingLockCard: some View {
        CameraSettingsCard(title: "Recording active", subtitle: "Stop recording before changing Broadcast camera source or format.", systemImage: "lock.fill") {
            Label("Broadcast camera controls are locked while recording is active.", systemImage: "exclamationmark.triangle.fill")
                .font(RinkLensDesignSystem.font(.caption))
                .foregroundStyle(.orange)
        }
    }

    private var cameraSubTabsCard: some View {
        CameraSettingsCard(title: "Camera area", subtitle: "Use the sub-tabs to keep Broadcast and Scoreboard settings separate without opening a nested screen.", systemImage: "rectangle.split.2x1") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Camera area", selection: $selectedCameraTab) {
                    ForEach(CameraSettingsSubTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.systemImage).tag(tab)
                    }
                }
                .pickerStyle(.segmented)

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: selectedCameraTab.systemImage)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(RinkLensDesignSystem.accent)
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(selectedCameraTab.title) Camera")
                            .font(RinkLensDesignSystem.font(.bodyStrong))
                            .foregroundStyle(RinkLensDesignSystem.primaryText)
                        Text(selectedCameraTab.summary)
                            .font(RinkLensDesignSystem.font(.caption))
                            .foregroundStyle(RinkLensDesignSystem.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private var selectedCameraTabContent: some View {
        switch selectedCameraTab {
        case .broadcast:
            broadcastCameraCards
        case .ocr:
            ocrCameraCards
        }
    }

    private var broadcastCameraCards: some View {
        VStack(alignment: .leading, spacing: 12) {
            CameraSettingsSectionHeader(title: "Broadcast Camera", subtitle: "Used for live view, full-game recording, clips and future streaming.", systemImage: "video.fill")

            CameraSourceSettingsCard(
                title: "Source",
                subtitle: "Choose the broadcast picture source used for live view, recording and clips.",
                systemImage: "camera.fill",
                pickerTitle: "Broadcast source",
                service: viewModel.liveCameraService,
                recoveryInProgress: viewModel.cameraRecoveryInProgress,
                framesReceivedText: "Frames received from Broadcast camera",
                noFramesText: "No Broadcast camera frames received yet",
                onSelect: { viewModel.selectLiveCamera(id: $0) },
                onRecover: { viewModel.requestCameraPreviewRecovery(for: viewModel.liveCameraService, reason: "operator recover from flat camera settings") }
            )
            .disabled(recorder.canStop)

            CameraSettingsCard(title: "Resolution & FPS", subtitle: viewModel.liveCameraService.selectedCameraIsExternal ? "External cameras use manual resolution and FPS selection." : "Operational resolution and frame rate belong on the Broadcast screen.", systemImage: "slider.horizontal.3") {
                VStack(alignment: .leading, spacing: 12) {
                    if viewModel.liveCameraService.selectedCameraIsExternal {
                        CameraExternalManualModeNote(role: "Broadcast")
                    } else {
                        Toggle("Automatic focus, exposure and white balance", isOn: Binding(
                            get: { viewModel.liveCameraService.appleStyleAutoQualityEnabled },
                            set: { viewModel.setLiveCameraAppleStyleAutoQuality($0) }
                        ))
                        .disabled(recorder.canStop)
                    }


                    if viewModel.liveCameraService.appleStyleAutoQualityEnabled && !viewModel.liveCameraService.selectedCameraIsExternal {
                        CameraAutoModeNote(role: "Broadcast")
                    }

                    CameraQualitySettingsMenu(
                        service: viewModel.liveCameraService,
                        onSelectProfile: { viewModel.selectLiveCapabilityProfile(id: $0) }
                    )
                    .disabled(recorder.canStop)
                }
            }

            CameraLensSettingsCard(
                title: "Manual lens controls",
                subtitle: "Focus, exposure and white balance controls.",
                systemImage: "camera.aperture",
                role: "Broadcast",
                service: viewModel.liveCameraService
            )
            .disabled(recorder.canStop)

            CameraRotationSettingsCard(
                title: "Rotation",
                subtitle: "Only affects the Broadcast/live camera.",
                systemImage: "rotate.right.fill",
                currentDegrees: viewModel.livePreviewRotationOffsetDegrees,
                rotateLeft: { viewModel.rotateLivePreviewCounterClockwise() },
                rotateRight: { viewModel.rotateLivePreviewClockwise() },
                reset: { viewModel.resetLivePreviewRotation() }
            )
            .disabled(recorder.canStop)
        }
    }

    private var ocrCameraCards: some View {
        VStack(alignment: .leading, spacing: 12) {
            CameraSettingsSectionHeader(title: "Scoreboard Camera", subtitle: "Used for Image Relay, scoreboard zones and internal Period recognition.", systemImage: "text.viewfinder")

            CameraSourceSettingsCard(
                title: "Source",
                subtitle: "Choose the scoreboard camera. An external camera is normally best for rink setup.",
                systemImage: "viewfinder",
                pickerTitle: "Scoreboard source",
                service: viewModel.ocrCameraService,
                recoveryInProgress: viewModel.cameraRecoveryInProgress,
                framesReceivedText: "Frames received from scoreboard camera",
                noFramesText: "No scoreboard camera frames received yet",
                onSelect: { viewModel.selectOCRCamera(id: $0) },
                onRecover: { viewModel.requestCameraPreviewRecovery(for: viewModel.ocrCameraService, reason: "operator recover from flat camera settings") }
            )

            CameraSettingsCard(title: "scoreboard camera settings", subtitle: "Legacy camera workspace. Camera selection now belongs in Settings; operational resolution, frame rate and image controls belong on Broadcast or Scoreboard Setup.", systemImage: "wand.and.stars") {
                VStack(alignment: .leading, spacing: 12) {
                    if viewModel.ocrCameraService.selectedCameraIsExternal {
                        CameraExternalManualModeNote(role: "OCR")
                    } else {
                        Toggle("Automatic focus, exposure and white balance", isOn: Binding(
                            get: { viewModel.ocrCameraService.appleStyleAutoQualityEnabled },
                            set: { viewModel.setOCRCameraAppleStyleAutoQuality($0) }
                        ))
                    }

                    if viewModel.ocrCameraService.appleStyleAutoQualityEnabled && !viewModel.ocrCameraService.selectedCameraIsExternal {
                        CameraAutoModeNote(role: "OCR")
                    }

                    CameraQualitySettingsMenu(
                        service: viewModel.ocrCameraService,
                        onSelectProfile: { viewModel.selectOCRCapabilityProfile(id: $0) }
                    )

                    Picker("Game clock direction", selection: Binding(
                        get: { viewModel.gameClockDirection },
                        set: { viewModel.setGameClockDirection($0) }
                    )) {
                        ForEach(GameClockDirection.allCases) { direction in
                            Text(direction.title).tag(direction)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            CameraLensSettingsCard(
                title: "Scoreboard camera controls and locks",
                subtitle: "Focus, exposure, white balance and stationary-camera lock controls.",
                systemImage: "viewfinder",
                role: "OCR",
                service: viewModel.ocrCameraService,
                showStationaryLockControls: true
            )

            CameraAdvancedOCRSettingsMenu(viewModel: viewModel)

            CameraRotationSettingsCard(
                title: "Rotation",
                subtitle: "Only affects the Scoreboard Setup camera.",
                systemImage: "rotate.right",
                currentDegrees: viewModel.ocrPreviewRotationOffsetDegrees,
                rotateLeft: { viewModel.rotateOCRPreviewCounterClockwise() },
                rotateRight: { viewModel.rotateOCRPreviewClockwise() },
                reset: { viewModel.resetOCRPreviewRotation() }
            )
        }
    }

    private var cameraConflictWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Broadcast and Scoreboard Setup are using the same camera", systemImage: "exclamationmark.triangle.fill")
                .font(RinkLensDesignSystem.font(.caption))
                .foregroundStyle(.orange)
            Text("For game-day, use separate cameras where possible. Same-camera setup is allowed for testing but can cause preview handoff delays.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Set Scoreboard Camera to None") {
                    viewModel.selectOCRCamera(id: iceCastExplicitNoCameraSelectionID)
                }
                .buttonStyle(.bordered)
                .disabled(recorder.canStop)

                Button("Set Broadcast Camera to None") {
                    viewModel.selectLiveCamera(id: iceCastExplicitNoCameraSelectionID)
                }
                .buttonStyle(.bordered)
                .disabled(recorder.canStop)
            }
        }
    }

    private var broadcastCameraStatusText: String {
        viewModel.liveCameraService.hasConfiguredCameraSelection
            ? viewModel.liveCameraService.effectiveCameraLabel
            : "None selected"
    }

    private var ocrCameraStatusText: String {
        viewModel.ocrCameraService.hasConfiguredCameraSelection
            ? viewModel.ocrCameraService.effectiveCameraLabel
            : "None selected"
    }

    private var camerasAppearToMatch: Bool {
        guard let liveID = viewModel.liveCameraService.selectedCameraID,
              let ocrID = viewModel.ocrCameraService.selectedCameraID else { return false }
        return liveID == ocrID
    }
}

private struct CameraSettingsSectionHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: systemImage)
                .font(.headline.weight(.bold))
                .foregroundStyle(RinkLensDesignSystem.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(RinkLensDesignSystem.font(.cardTitle))
                    .foregroundStyle(RinkLensDesignSystem.primaryText)
                Text(subtitle)
                    .font(RinkLensDesignSystem.font(.caption))
                    .foregroundStyle(RinkLensDesignSystem.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }
}

private struct CameraSettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    private let content: () -> Content

    init(title: String, subtitle: String, systemImage: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(RinkLensDesignSystem.font(.cardTitle))
                        .foregroundStyle(RinkLensDesignSystem.primaryText)
                    Text(subtitle)
                        .font(RinkLensDesignSystem.font(.caption))
                        .foregroundStyle(RinkLensDesignSystem.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .background(RinkLensDesignSystem.cardBackground, in: RoundedRectangle(cornerRadius: RinkLensDesignSystem.cardCornerRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: RinkLensDesignSystem.cardCornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: RinkLensDesignSystem.cardCornerRadius, style: .continuous).stroke(RinkLensDesignSystem.border, lineWidth: 1))
    }
}

struct CameraSourceSettingsCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let pickerTitle: String
    @ObservedObject var service: HockeyCameraService
    let recoveryInProgress: Bool
    let framesReceivedText: String
    let noFramesText: String
    let onSelect: (String?) -> Void
    let onRecover: () -> Void

    var body: some View {
        CameraSettingsCard(title: title, subtitle: subtitle, systemImage: systemImage) {
            VStack(alignment: .leading, spacing: 12) {
                CameraSourcePickerView(
                    title: pickerTitle,
                    service: service,
                    framesReceivedText: framesReceivedText,
                    noFramesText: noFramesText,
                    onSelect: onSelect
                )
                .pickerStyle(.menu)

                HStack(spacing: 10) {
                    Button {
                        CameraOwnershipTraceStore.record(.recovery, owner: .diagnostics, reason: "Camera Settings Recover Preview tapped service=\(service.diagnosticInstanceID) selected=\(service.selectedCameraID ?? "none")")
                        onRecover()
                    } label: {
                        Label(recoveryInProgress ? "Recovering…" : "Recover Preview", systemImage: recoveryInProgress ? "hourglass" : "wrench.and.screwdriver")
                    }
                    .buttonStyle(.bordered)
                    .disabled(service.isReconfiguring || recoveryInProgress)
                }

                if service.isReconfiguring {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(service.cameraStatusText)
                            .font(RinkLensDesignSystem.font(.caption))
                            .foregroundStyle(RinkLensDesignSystem.secondaryText)
                    }
                }
            }
        }
    }
}

private struct CameraAutoModeNote: View {
    let role: String

    var body: some View {
        Label("Automatic focus, exposure and white balance are enabled for the \(role) camera. Resolution and frame rate are owned by the active operational screen. Disable automatic lens controls only when the selected camera reports manual control support.", systemImage: "wand.and.stars")
            .font(RinkLensDesignSystem.font(.caption))
            .foregroundStyle(RinkLensDesignSystem.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct CameraExternalManualModeNote: View {
    let role: String

    var body: some View {
        Label("External \(role) camera detected. Supported Resolution / FPS choices load automatically for this camera.", systemImage: "slider.horizontal.3")
            .font(RinkLensDesignSystem.font(.caption))
            .foregroundStyle(RinkLensDesignSystem.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct CameraQualitySettingsMenu: View {
    @ObservedObject var service: HockeyCameraService
    let onSelectProfile: (String) -> Void

    var body: some View {
        CameraMiniMenu(title: "Resolution / FPS", subtitle: "Supported 720p, 1080p, and 1440p modes at 30 or 60 fps load automatically for the selected camera.", systemImage: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 12) {
                CameraSetupRow(title: "Selected", value: service.selectedResolutionFPS)
                CameraSetupRow(title: "Format cache", value: service.videoFormatsLoaded ? "Loaded" : "Not loaded")
                Text(service.videoFormatLoadStatusText)
                    .font(RinkLensDesignSystem.font(.caption))
                    .foregroundStyle(RinkLensDesignSystem.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)


                if service.isLoadingVideoFormats {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading camera-supported formats…")
                            .font(RinkLensDesignSystem.font(.caption))
                            .foregroundStyle(RinkLensDesignSystem.secondaryText)
                    }
                }

                Picker("Video format", selection: Binding(
                    get: { service.selectedCompressionProfile },
                    set: { service.selectCompressionProfile($0) }
                )) {
                    ForEach(HockeyCameraService.VideoCompressionProfile.allCases, id: \.self) { profile in
                        Text(profile.rawValue).tag(profile)
                    }
                }
                .pickerStyle(.menu)
                .disabled(service.isReconfiguring)

                Picker("Manual resolution / FPS", selection: Binding<String>(
                    get: { service.selectedCapabilityProfileID ?? "" },
                    set: { newID in
                        guard !newID.isEmpty else { return }
                        onSelectProfile(newID)
                    }
                )) {
                    Text(service.capabilityProfiles.isEmpty ? (service.isLoadingVideoFormats ? "Loading formats…" : "No supported 720p/1080p/1440p 30/60 mode") : "Current: \(service.selectedResolutionLabel)")
                        .tag("")
                    ForEach(service.capabilityProfiles) { profile in
                        Text(profile.displayLabel)
                            .tag(profile.id)
                    }
                }
                .pickerStyle(.menu)
                .disabled(service.isReconfiguring || service.isLoadingVideoFormats || service.capabilityProfiles.isEmpty)
            }
        }
    }
}

private struct CameraLensSettingsCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let role: String
    @ObservedObject var service: HockeyCameraService
    var showStationaryLockControls: Bool = false

    var hideManualControlsForAppleAuto: Bool {
        service.appleStyleAutoQualityEnabled && !service.selectedCameraIsExternal
    }

    var body: some View {
        CameraSettingsCard(title: title, subtitle: subtitle, systemImage: systemImage) {
            VStack(alignment: .leading, spacing: 12) {
                if hideManualControlsForAppleAuto {
                    CameraAutoModeNote(role: role)
                } else {
                    CameraFocusMenu(service: service)
                    CameraExposureMenu(service: service)
                    CameraWhiteBalanceMenu(service: service)
                }

                if showStationaryLockControls && !hideManualControlsForAppleAuto {
                    CameraMiniMenu(title: "Stationary scoreboard lock", subtitle: "Lock focus, exposure and white balance after calibration.", systemImage: "lock.fill") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(service.stationaryHardwareLockText)
                                .font(RinkLensDesignSystem.font(.caption))
                                .foregroundStyle(service.stationaryHardwareLockActive ? .green : RinkLensDesignSystem.secondaryText)
                            Text("Apply this after calibration when the external scoreboard camera is fixed. It stops the scoreboard camera hunting while the iPad/Broadcast camera moves.")
                                .font(RinkLensDesignSystem.font(.caption))
                                .foregroundStyle(RinkLensDesignSystem.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button("Lock") {
                                    service.lockForStationaryRole(label: "scoreboard camera")
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(service.isReconfiguring)

                                Button("Unlock") {
                                    service.unlockStationaryRole(label: "scoreboard camera")
                                }
                                .buttonStyle(.bordered)
                                .disabled(service.isReconfiguring)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct CameraFocusMenu: View {
    @ObservedObject var service: HockeyCameraService

    var body: some View {
        CameraMiniMenu(title: "Focus", subtitle: service.focusModeText, systemImage: "viewfinder") {
            VStack(alignment: .leading, spacing: 10) {
                if service.supportsManualFocus {
                    Slider(
                        value: Binding(
                            get: { Double(service.focusPosition) },
                            set: { service.setManualFocus(position: Float($0)) }
                        ),
                        in: 0...1
                    )
                    .disabled(service.isReconfiguring)

                    Button("Use Continuous Auto Focus") {
                        service.setContinuousAutoFocus()
                    }
                    .buttonStyle(.bordered)
                    .disabled(service.isReconfiguring)
                } else {
                    Text("Manual focus unavailable on connected camera.")
                        .font(RinkLensDesignSystem.font(.caption))
                        .foregroundStyle(RinkLensDesignSystem.secondaryText)
                }
            }
        }
    }
}

private struct CameraExposureMenu: View {
    @ObservedObject var service: HockeyCameraService

    var body: some View {
        CameraMiniMenu(title: "Exposure", subtitle: service.exposureModeText, systemImage: "sun.max.fill") {
            VStack(alignment: .leading, spacing: 12) {
                if service.supportsManualISO {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ISO / Gain: \(Int(service.isoValue))")
                            .font(RinkLensDesignSystem.font(.caption))
                        Slider(
                            value: Binding(
                                get: { Double(service.isoValue) },
                                set: { service.setManualISO(Float($0)) }
                            ),
                            in: Double(service.minISO)...Double(service.maxISO)
                        )
                        .disabled(service.isReconfiguring)
                        HStack {
                            Button("Lock Exposure") {
                                service.lockCurrentExposure()
                            }
                            .buttonStyle(.bordered)
                            .disabled(service.isReconfiguring)

                            Button("Auto Exposure") {
                                service.setAutoExposure()
                            }
                            .buttonStyle(.bordered)
                            .disabled(service.isReconfiguring)
                        }
                    }
                } else {
                    Text("Manual ISO unavailable on connected camera.")
                        .font(RinkLensDesignSystem.font(.caption))
                        .foregroundStyle(RinkLensDesignSystem.secondaryText)
                }

                if service.supportsManualExposureDuration,
                   service.minExposureDurationSeconds.isFinite,
                   service.maxExposureDurationSeconds.isFinite,
                   service.maxExposureDurationSeconds > service.minExposureDurationSeconds {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Shutter: \(service.shutterSpeedText)")
                            .font(RinkLensDesignSystem.font(.caption))
                        Slider(
                            value: Binding(
                                get: { min(max(service.exposureDurationSeconds, service.minExposureDurationSeconds), service.maxExposureDurationSeconds) },
                                set: { service.setManualExposureDuration(seconds: $0) }
                            ),
                            in: service.minExposureDurationSeconds...service.maxExposureDurationSeconds
                        )
                        .disabled(service.isReconfiguring)
                    }
                }

                if service.supportsExposureBias,
                   service.maxExposureTargetBias > service.minExposureTargetBias {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(format: "Exposure bias: %.1f", Double(service.exposureTargetBiasValue)))
                            .font(RinkLensDesignSystem.font(.caption))
                        Slider(
                            value: Binding(
                                get: { Double(service.exposureTargetBiasValue) },
                                set: { service.setExposureTargetBias(Float($0)) }
                            ),
                            in: Double(service.minExposureTargetBias)...Double(service.maxExposureTargetBias)
                        )
                        .disabled(service.isReconfiguring)
                    }
                }
            }
        }
    }
}

private struct CameraWhiteBalanceMenu: View {
    @ObservedObject var service: HockeyCameraService

    var body: some View {
        CameraMiniMenu(title: "White balance", subtitle: service.whiteBalanceModeText, systemImage: "thermometer.sun.fill") {
            VStack(alignment: .leading, spacing: 12) {
                if service.supportsManualWhiteBalanceGains {
                    Text("Temperature \(Int(service.whiteBalanceTemperature))K · Tint \(Int(service.whiteBalanceTint))")
                        .font(RinkLensDesignSystem.font(.caption))
                        .foregroundStyle(RinkLensDesignSystem.secondaryText)
                    Slider(
                        value: Binding(
                            get: { Double(service.whiteBalanceTemperature) },
                            set: { service.setManualWhiteBalance(temperature: Float($0), tint: service.whiteBalanceTint) }
                        ),
                        in: 2500...8000
                    )
                    .disabled(service.isReconfiguring)
                    Slider(
                        value: Binding(
                            get: { Double(service.whiteBalanceTint) },
                            set: { service.setManualWhiteBalance(temperature: service.whiteBalanceTemperature, tint: Float($0)) }
                        ),
                        in: -50...50
                    )
                    .disabled(service.isReconfiguring)
                    HStack {
                        Button("Lock White Balance") {
                            service.lockCurrentWhiteBalance()
                        }
                        .buttonStyle(.bordered)
                        .disabled(service.isReconfiguring)

                        Button("Auto White Balance") {
                            service.setAutoWhiteBalance()
                        }
                        .buttonStyle(.bordered)
                        .disabled(service.isReconfiguring)
                    }
                } else {
                    Text("Manual white balance unavailable on connected camera.")
                        .font(RinkLensDesignSystem.font(.caption))
                        .foregroundStyle(RinkLensDesignSystem.secondaryText)
                }
            }
        }
    }
}

private struct CameraAdvancedOCRSettingsMenu: View {
    @ObservedObject var viewModel: HockeyScoreboardViewModel

    var body: some View {
        CameraSettingsCard(
            title: "Internal Recognition",
            subtitle: "Image Relay owns the live scorebug. Recognition is limited to Period and a frozen Home penalty-player crop for roster-name enhancement.",
            systemImage: "text.viewfinder"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                CameraMiniMenu(
                    title: "Recognition scope",
                    subtitle: "No separate recognition mode or live-scorebug switch.",
                    systemImage: "checkmark.shield"
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Period — automatic every 5 seconds in Image Relay", systemImage: "number.square")
                        Label("Home penalty popup — stable frozen crop, maximum 3 attempts in 2.5 seconds", systemImage: "person.text.rectangle")
                        Label("Guest penalty popup — Image Relay crop only", systemImage: "rectangle.on.rectangle")
                        Text("Goals and period corrections remain Manual-only. Player recognition can add a Home roster name to a popup but cannot replace a live scorebug image.")
                            .font(.caption2)
                            .foregroundStyle(RinkLensDesignSystem.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption)
                }

                CameraMiniMenu(
                    title: "Thresholds",
                    subtitle: "Only the two retained recognition services are adjustable.",
                    systemImage: "checkmark.seal"
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        thresholdRow(title: "Period", value: $viewModel.ocrThresholds.period)
                        thresholdRow(title: "Frozen Home player", value: $viewModel.ocrThresholds.penaltyPlayer)
                    }
                }

                CameraMiniMenu(
                    title: "Diagnostics display",
                    subtitle: "Optional evidence shown on the Scoreboard Setup preview.",
                    systemImage: "eye"
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Show Recognition Boxes", isOn: $viewModel.ocrDiagnosticDisplayOptions.showOCRBoxes)
                        Toggle("Show Raw Recognition Values", isOn: $viewModel.ocrDiagnosticDisplayOptions.showOCRRawValues)
                        Toggle("Show Recognition Confidence", isOn: $viewModel.ocrDiagnosticDisplayOptions.showOCRConfidence)
                        Toggle("Show Recogniser Colours", isOn: $viewModel.ocrDiagnosticDisplayOptions.showRecogniserColours)
                        Toggle("Show Accepted Recognition Values", isOn: $viewModel.ocrDiagnosticDisplayOptions.showAcceptedValues)
                    }
                }

                CameraMiniMenu(
                    title: "Recognition snapshot",
                    subtitle: "Current retained-service cadence and confidence.",
                    systemImage: "timer"
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        tuningRow("Period", viewModel.ocrTuningSnapshot.period)
                        tuningRow("Frozen Home player", viewModel.ocrTuningSnapshot.penaltyPlayer)
                    }
                }

                CameraMiniMenu(
                    title: "Maintenance",
                    subtitle: "Reset recognition evidence without changing relay zones.",
                    systemImage: "wrench.and.screwdriver"
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Button {
                                viewModel.resetOCRTrustState()
                            } label: {
                                Label("Reset Recognition Evidence", systemImage: "arrow.counterclockwise")
                            }
                            .buttonStyle(.bordered)

                            Button {
                                viewModel.clearDebugHistory()
                            } label: {
                                Label("Clear Recognition History", systemImage: "trash")
                            }
                            .buttonStyle(.bordered)
                        }

                        Text("These actions do not load, save or alter Image Relay zone profiles.")
                            .font(.caption2)
                            .foregroundStyle(RinkLensDesignSystem.secondaryText)
                    }
                }
            }
        }
    }

    private func thresholdRow(title: String, value: Binding<Float>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(title): \(String(format: "%.2f", value.wrappedValue))")
                    .font(RinkLensDesignSystem.font(.caption))
                    .foregroundStyle(RinkLensDesignSystem.primaryText)
                Spacer()
                Button("−") { value.wrappedValue = max(0.30, value.wrappedValue - 0.02) }
                    .buttonStyle(.bordered)
                Button("+") { value.wrappedValue = min(0.95, value.wrappedValue + 0.02) }
                    .buttonStyle(.bordered)
            }
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Float($0) }
                ),
                in: 0.30...0.95,
                step: 0.01
            )
        }
    }

    private func tuningRow(_ title: String, _ tuning: OCRZoneTuning) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(RinkLensDesignSystem.font(.caption))
                .foregroundStyle(RinkLensDesignSystem.secondaryText)
            Spacer(minLength: 12)
            Text("cadence \(String(format: "%.1fs", tuning.cadenceSeconds)) / confidence \(String(format: "%.2f", tuning.confidence)) / trust \(tuning.trust)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(RinkLensDesignSystem.primaryText)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct CameraRotationSettingsCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let currentDegrees: CGFloat
    let rotateLeft: () -> Void
    let rotateRight: () -> Void
    let reset: () -> Void

    var body: some View {
        CameraSettingsCard(title: title, subtitle: subtitle, systemImage: systemImage) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button { rotateLeft() } label: {
                        Label("Left", systemImage: "rotate.left")
                    }
                    .buttonStyle(.bordered)

                    Button { rotateRight() } label: {
                        Label("Right", systemImage: "rotate.right")
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Reset") { reset() }
                        .buttonStyle(.bordered)
                }

                Text("Current rotation: \(Int(currentDegrees))°")
                    .font(RinkLensDesignSystem.font(.caption))
                    .foregroundStyle(RinkLensDesignSystem.secondaryText)
                    .monospacedDigit()
            }
        }
    }
}

private struct CameraMiniMenu<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    private let content: () -> Content

    init(title: String, subtitle: String, systemImage: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.content = content
    }

    var body: some View {
        DisclosureGroup {
            content()
                .padding(.top, 10)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(RinkLensDesignSystem.accent)
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(RinkLensDesignSystem.font(.bodyStrong))
                        .foregroundStyle(RinkLensDesignSystem.primaryText)
                    Text(subtitle)
                        .font(RinkLensDesignSystem.font(.caption))
                        .foregroundStyle(RinkLensDesignSystem.mutedText)
                        .lineLimit(2)
                }
            }
        }
        .tint(RinkLensDesignSystem.accent)
        .padding(12)
        .background(RinkLensDesignSystem.controlBackground, in: RoundedRectangle(cornerRadius: RinkLensDesignSystem.controlCornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: RinkLensDesignSystem.controlCornerRadius, style: .continuous).stroke(RinkLensDesignSystem.border, lineWidth: 1))
    }
}

private struct CameraSetupRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(RinkLensDesignSystem.font(.caption))
                .foregroundStyle(RinkLensDesignSystem.secondaryText)
            Spacer(minLength: 12)
            Text(value.isEmpty ? "--" : value)
                .font(RinkLensDesignSystem.font(.caption))
                .foregroundStyle(RinkLensDesignSystem.primaryText)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }
}

#endif


#if canImport(SwiftUI)

@MainActor
struct CameraSetupSettingsEmbeddedView: View {
    @ObservedObject var viewModel: HockeyScoreboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CameraSettingsSectionHeader(
                title: "Camera selection",
                subtitle: "Settings assigns each camera. Resolution, frame rate, focus, exposure and white balance are changed from Broadcast or Scoreboard Setup.",
                systemImage: "camera.fill"
            )

            CameraSourceSettingsCard(
                title: "Broadcast camera",
                subtitle: "Used by Broadcast, recording and clips.",
                systemImage: "video.fill",
                pickerTitle: "Broadcast camera",
                service: viewModel.liveCameraService,
                recoveryInProgress: viewModel.cameraRecoveryInProgress,
                framesReceivedText: "Broadcast camera selected",
                noFramesText: "No Broadcast camera selected",
                onSelect: { viewModel.selectLiveCamera(id: $0) },
                onRecover: { viewModel.requestCameraPreviewRecovery(for: viewModel.liveCameraService, reason: "Settings camera selection recovery") }
            )

            CameraSourceSettingsCard(
                title: "Scoreboard camera",
                subtitle: "Used by Image Relay, OCR zones and Period recognition.",
                systemImage: "text.viewfinder",
                pickerTitle: "Scoreboard camera",
                service: viewModel.ocrCameraService,
                recoveryInProgress: viewModel.cameraRecoveryInProgress,
                framesReceivedText: "Scoreboard camera selected",
                noFramesText: "No Scoreboard camera selected",
                onSelect: { viewModel.selectOCRCamera(id: $0) },
                onRecover: { viewModel.requestCameraPreviewRecovery(for: viewModel.ocrCameraService, reason: "Settings scoreboard camera selection recovery") }
            )
        }
    }
}

#endif
