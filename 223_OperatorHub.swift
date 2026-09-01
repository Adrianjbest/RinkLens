// BUILD 699 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI

// STYLE2 central design system migration: operator chrome/fonts use RinkLensDesignSystem where safe.
import UIKit
import AVFoundation
import Vision
import CoreMedia
import CoreGraphics
import CoreImage
import Foundation
#if canImport(MLKitVision) && canImport(MLKitTextRecognition) && canImport(MLKitTextRecognitionLatin)
import MLKitVision
import MLKitTextRecognition
import MLKitTextRecognitionLatin
#endif

enum OperatorControlHubPage: String, CaseIterable, Identifiable {
    case camera = "Camera & Record"
    case ocr = "Recognition"
    case recording = "Recording"
    case diagnostics = "Diagnostics"
    case display = "Display"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .camera: return "video.fill"
        case .ocr: return "person.text.rectangle"
        case .recording: return "record.circle"
        case .diagnostics: return "waveform.path.ecg.rectangle"
        case .display: return "rectangle.on.rectangle"
        }
    }
}

enum OperatorCameraPageMode {
    case full
    case broadcastSafe
}



// MARK: - v0.8.4ab2 Controls Typecheck Hard Split

struct OperatorControlHubSheet: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: HockeyScoreboardViewModel
    private let recorder = BroadcastRecordingManager.shared
    @StateObject private var refreshDriver = OperatorControlsRefreshDriver()
    private let availablePages: [OperatorControlHubPage]
    private let cameraPageMode: OperatorCameraPageMode
    @State private var selectedPage: OperatorControlHubPage
    @State private var broadcastZoomDraft: CGFloat
    @State private var isEditingBroadcastZoom = false

    init(
        viewModel: HockeyScoreboardViewModel,
        initialPage: OperatorControlHubPage = .camera,
        showDisplayPage: Bool = true,
        showCameraPage: Bool = false,
        cameraPageMode: OperatorCameraPageMode = .full
    ) {
        self.viewModel = viewModel
        let settingsStyle = RinkLensRiskFeaturePolicy.isEnabled(.operatorControlsSettingsStyleV13)
        let pages = OperatorControlHubPage.allCases.filter { page in
            if settingsStyle && (page == .camera || page == .recording) {
                return false
            }
            switch page {
            case .display:
                return showDisplayPage
            case .camera:
                return showCameraPage
            case .recording:
                return !RinkLensRiskFeaturePolicy.isEnabled(.minimalOperatorCameraRecordingV12)
            default:
                return true
            }
        }
        self.availablePages = pages
        self.cameraPageMode = cameraPageMode
        _broadcastZoomDraft = State(initialValue: viewModel.liveCameraZoomFactor)

        let defaultPage: OperatorControlHubPage
        if pages.contains(initialPage) {
            defaultPage = initialPage
        } else if showCameraPage, pages.contains(.camera) {
            defaultPage = .camera
        } else if pages.contains(.recording) {
            defaultPage = .recording
        } else if let firstPage = pages.first {
            defaultPage = firstPage
        } else {
            defaultPage = .diagnostics
        }

        self._selectedPage = State(initialValue: defaultPage)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                BroadcastMenuBackgroundView()
                VStack(spacing: 0) {
                    if RinkLensRiskFeaturePolicy.isEnabled(.operatorControlsSettingsStyleV13) {
                        operatorSettingsStylePicker
                    } else {
                        legacySegmentedPicker
                    }
                    operatorPageScrollView
                }
            }
            .navigationTitle("Operator Controls")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .broadcastMenuText()
        .onAppear {
            refreshDriver.start()
            viewModel.beginOperatorControlsInteraction()
        }
        .onDisappear {
            refreshDriver.stop()
            viewModel.endOperatorControlsInteraction()
        }
        .onChange(of: selectedPage) { _, page in
            refreshDriver.bump(reason: "operator page changed")
            viewModel.noteOperatorControlsPageChanged(to: page.rawValue)
        }
    }

    private var legacySegmentedPicker: some View {
        Picker("Operator section", selection: $selectedPage) {
            ForEach(availablePages) { page in
                Label(page.rawValue, systemImage: page.systemImage).tag(page)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var operatorSettingsStylePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(availablePages) { page in
                    Button {
                        selectedPage = page
                    } label: {
                        Label(page.rawValue, systemImage: page.systemImage)
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .frame(minWidth: 150)
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
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var operatorPageScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch selectedPage {
                case .camera:
                    if cameraPageMode == .broadcastSafe {
                        broadcastSafeCameraPage
                    } else {
                        broadcastCameraPage
                    }
                case .ocr:
                    ocrRuntimePage
                case .recording:
                    BroadcastRecordingPanel(viewModel: viewModel)
                case .diagnostics:
                    DiagnosticsHubView(viewModel: viewModel, cameraService: viewModel.liveCameraService)
                case .display:
                    displayAndOutputPage
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
    }

    private var broadcastSafeCameraPage: some View {
        broadcastCameraUnifiedQualityPage
    }


    private var broadcastCameraPage: some View {
        broadcastCameraUnifiedQualityPage
    }

    @ViewBuilder
    private var broadcastCameraUnifiedQualityPage: some View {
        if RinkLensRiskFeaturePolicy.isEnabled(.minimalOperatorCameraRecordingV12) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Camera & Recording", systemImage: "video.badge.ellipsis")
                    .font(RinkLensDesignSystem.font(.bodyStrong))

                BroadcastRecordingQuickControls(
                    viewModel: viewModel,
                    showsClipAndMediaControls: false,
                    showsManualClipControl: false,
                    showsMediaControl: false,
                    showsClipFeedback: false
                )

                compactBroadcastCameraCard

                if !viewModel.liveCameraService.appleStyleAutoQualityEnabled {
                    compactBroadcastManualImageControlsCard
                }

                compactBroadcastCameraActionsCard
            }
        } else if RinkLensRiskFeaturePolicy.isEnabled(.operationalCameraOverridesV10) {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("Broadcast camera", systemImage: "video.fill", help: "Settings selects the camera. Broadcast owns its 1080p60 default, exact format override and supported image controls.")
                broadcastCameraQualityCard
                if !viewModel.liveCameraService.appleStyleAutoQualityEnabled {
                    broadcastManualImageControlsCard
                }
                broadcastCameraRecoveryCard
                broadcastCameraRotationCard
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("Broadcast camera", systemImage: "video.fill", help: "Legacy camera controls are active for rollout comparison.")
                Text("Operational camera overrides are disabled by the Build 720 rollout flag. Use Camera Setup while comparing the previous path.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .broadcastMenuCard(cornerRadius: 14)
            }
        }
    }

    private var compactBroadcastCameraCard: some View {
        let service = viewModel.liveCameraService
        let minimumZoom = max(0.5, service.minZoomFactor)
        let maximumZoom = max(minimumZoom, service.maxZoomFactor)

        return VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Camera", value: service.selectedCameraLabel)
            LabeledContent("Format", value: service.selectedResolutionFPS)

            HStack(spacing: 8) {
                Button {
                    viewModel.applyBroadcastDefaultCameraProfile()
                    refreshDriver.bump(reason: "Broadcast 1080p60 automatic default requested")
                } label: {
                    Label("1080p60 Auto", systemImage: "arrow.counterclockwise.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(service.isReconfiguring || recorder.canStop)

                Picker("Format", selection: Binding<String>(
                    get: { service.roleDefaultProfileEnabled ? "" : (service.selectedCapabilityProfileID ?? "") },
                    set: { id in
                        guard !id.isEmpty else { return }
                        viewModel.selectLiveCapabilityProfile(id: id)
                        refreshDriver.bump(reason: "Broadcast exact format override")
                    }
                )) {
                    Text("Default").tag("")
                    ForEach(service.capabilityProfiles) { profile in
                        Text(profile.displayLabel).tag(profile.id)
                    }
                }
                .pickerStyle(.menu)
                .disabled(service.isReconfiguring || recorder.canStop || service.capabilityProfiles.isEmpty)
            }

            Toggle("Automatic image", isOn: Binding(
                get: { service.appleStyleAutoQualityEnabled },
                set: {
                    viewModel.setLiveCameraAppleStyleAutoQuality($0)
                    refreshDriver.bump(reason: "Broadcast automatic lens controls changed")
                }
            ))
            .disabled(service.isReconfiguring || recorder.canStop || !service.hasAnyAutomaticLensControl)

            HStack {
                Text("Zoom")
                Spacer()
                Text(String(format: "%.1fx", Double(viewModel.liveCameraZoomFactor)))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.66))
            }
            Slider(
                value: Binding(
                    get: {
                        let value = isEditingBroadcastZoom ? broadcastZoomDraft : viewModel.liveCameraZoomFactor
                        return Double(min(max(value, minimumZoom), maximumZoom))
                    },
                    set: {
                        broadcastZoomDraft = CGFloat($0)
                        viewModel.previewLiveCameraZoomFromSlider(broadcastZoomDraft)
                    }
                ),
                in: Double(minimumZoom)...Double(maximumZoom),
                onEditingChanged: { editing in
                    if editing {
                        isEditingBroadcastZoom = true
                        broadcastZoomDraft = viewModel.liveCameraZoomFactor
                    } else {
                        isEditingBroadcastZoom = false
                        viewModel.commitLiveCameraZoomFromSlider(broadcastZoomDraft)
                        refreshDriver.bump(reason: "broadcast zoom committed")
                    }
                }
            )
            .disabled(service.isReconfiguring || maximumZoom <= minimumZoom)
        }
        .padding(10)
        .broadcastMenuCard(cornerRadius: 14)
    }

    private var compactBroadcastCameraActionsCard: some View {
        let service = viewModel.liveCameraService

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Refresh Camera") {
                    service.refreshAvailableCameras()
                    refreshDriver.bump(reason: "refresh cameras")
                }
                .buttonStyle(.borderedProminent)
                .disabled(service.isReconfiguring)

                Button("Recover Preview") {
                    viewModel.requestCameraPreviewRecovery(for: service, reason: "operator recover from compact broadcast controls")
                    refreshDriver.bump(reason: "recover preview")
                }
                .buttonStyle(.bordered)
                .disabled(service.isReconfiguring)
            }

            HStack(spacing: 8) {
                Button("Rotate Left") {
                    viewModel.rotateLivePreviewCounterClockwise()
                    refreshDriver.bump(reason: "broadcast rotation left")
                }
                Button("Rotate Right") {
                    viewModel.rotateLivePreviewClockwise()
                    refreshDriver.bump(reason: "broadcast rotation right")
                }
                Button("Reset") {
                    viewModel.resetLivePreviewRotation()
                    refreshDriver.bump(reason: "broadcast rotation reset")
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(10)
        .broadcastMenuCard(cornerRadius: 14)
    }

    private var compactBroadcastManualImageControlsCard: some View {
        let service = viewModel.liveCameraService

        return VStack(alignment: .leading, spacing: 10) {
            if service.supportsManualFocus {
                LabeledContent("Focus", value: String(format: "%.2f", Double(service.focusPosition)))
                Slider(
                    value: Binding(
                        get: { Double(service.focusPosition) },
                        set: { service.setManualFocus(position: Float($0)) }
                    ),
                    in: 0...1
                )
                .disabled(service.isReconfiguring)
            }

            if service.supportsManualISO, service.maxISO > service.minISO {
                LabeledContent("ISO", value: "\(Int(service.isoValue))")
                Slider(
                    value: Binding(
                        get: { Double(service.isoValue) },
                        set: { service.setManualISO(Float($0)) }
                    ),
                    in: Double(service.minISO)...Double(service.maxISO)
                )
                .disabled(service.isReconfiguring)
            }

            HStack(spacing: 8) {
                if service.supportsAutoFocus {
                    Button("Auto Focus") { service.setContinuousAutoFocus() }
                }
                if service.supportsAutoExposure {
                    Button("Auto Exposure") { service.setAutoExposure() }
                }
                if service.supportsAutoWhiteBalance {
                    Button("Auto White Balance") { service.setAutoWhiteBalance() }
                }
            }
            .buttonStyle(.bordered)
            .disabled(service.isReconfiguring)
        }
        .padding(10)
        .broadcastMenuCard(cornerRadius: 14)
    }

    private var broadcastCameraQualityCard: some View {
        let service = viewModel.liveCameraService

        return VStack(alignment: .leading, spacing: 12) {
            Text("Broadcast capture profile")
                .font(RinkLensDesignSystem.font(.bodyStrong))

            Text("Default: 1920×1080 at 60 fps with automatic focus, exposure and white balance. This is a RinkLens request, not a copy of Apple Camera app settings.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Selected camera", value: service.selectedCameraLabel)
            LabeledContent("Requested / applied", value: service.selectedResolutionFPS)
            LabeledContent(
                "Recording",
                value: RinkLensRiskFeaturePolicy.isEnabled(.customRecordingOutputProfileV15)
                    ? recorder.recordingOutputPolicySummaryText
                    : recorder.recordingProfile.label
            )

            Button {
                viewModel.applyBroadcastDefaultCameraProfile()
                refreshDriver.bump(reason: "Broadcast 1080p60 automatic default requested")
            } label: {
                Label("Use Broadcast Default — 1080p60 Auto", systemImage: "arrow.counterclockwise.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(service.isReconfiguring || recorder.canStop)

            Picker("Resolution / FPS override", selection: Binding<String>(
                get: { service.roleDefaultProfileEnabled ? "" : (service.selectedCapabilityProfileID ?? "") },
                set: { id in
                    guard !id.isEmpty else { return }
                    viewModel.selectLiveCapabilityProfile(id: id)
                    refreshDriver.bump(reason: "Broadcast exact format override")
                }
            )) {
                Text("Default — 1080p60 Auto").tag("")
                ForEach(service.capabilityProfiles) { profile in
                    Text(profile.displayLabel).tag(profile.id)
                }
            }
            .pickerStyle(.menu)
            .disabled(service.isReconfiguring || recorder.canStop || service.capabilityProfiles.isEmpty)

            if service.capabilityProfiles.isEmpty {
                Text("No manual resolution/FPS options are available yet for this camera. Refresh formats after selecting the camera in Settings.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Toggle("Automatic focus, exposure and white balance", isOn: Binding(
                get: { service.appleStyleAutoQualityEnabled },
                set: {
                    viewModel.setLiveCameraAppleStyleAutoQuality($0)
                    refreshDriver.bump(reason: "Broadcast automatic lens controls changed")
                }
            ))
            .disabled(service.isReconfiguring || recorder.canStop || !service.hasAnyAutomaticLensControl)

            Text(service.automaticLensCapabilityText)
                .font(.caption2)
                .foregroundStyle(service.hasAnyAutomaticLensControl ? .white.opacity(0.66) : .orange)

            Divider()

            Toggle("Smooth 1x–5x Zoom Transitions", isOn: Binding(
                get: { viewModel.smoothBroadcastZoomTransitionsEnabled },
                set: {
                    viewModel.setSmoothBroadcastZoomTransitionsEnabled($0)
                    refreshDriver.bump(reason: "zoom smoothing changed")
                }
            ))

            Picker("1x–5x Transition Duration", selection: Binding(
                get: { viewModel.broadcastZoomTransitionSpeed },
                set: {
                    viewModel.setBroadcastZoomTransitionSpeed($0)
                    refreshDriver.bump(reason: "zoom transition changed")
                }
            )) {
                ForEach(BroadcastZoomTransitionSpeed.allCases) { speed in
                    Text(speed.label).tag(speed)
                }
            }
            .disabled(!viewModel.smoothBroadcastZoomTransitionsEnabled)
        }
        .padding(10)
        .broadcastMenuCard(cornerRadius: 14)
    }


    private var broadcastManualImageControlsCard: some View {
        let service = viewModel.liveCameraService

        return VStack(alignment: .leading, spacing: 12) {
            Text("Manual Image Controls")
                .font(RinkLensDesignSystem.font(.bodyStrong))

            Text("These controls change the live image only. They do not change recording file resolution, FPS, codec or bitrate.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Zoom")
                    Spacer()
                    Text(String(format: "%.1fx", Double(viewModel.liveCameraZoomFactor)))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.66))
                }
                Slider(
                    value: Binding(
                        get: { Double(isEditingBroadcastZoom ? broadcastZoomDraft : viewModel.liveCameraZoomFactor) },
                        set: {
                            broadcastZoomDraft = CGFloat($0)
                            viewModel.previewLiveCameraZoomFromSlider(broadcastZoomDraft)
                        }
                    ),
                    in: 0.5...5.0,
                    onEditingChanged: { editing in
                        if editing {
                            isEditingBroadcastZoom = true
                            broadcastZoomDraft = viewModel.liveCameraZoomFactor
                        } else {
                            isEditingBroadcastZoom = false
                            viewModel.commitLiveCameraZoomFromSlider(broadcastZoomDraft)
                            refreshDriver.bump(reason: "broadcast zoom committed")
                        }
                    }
                )
                .disabled(service.isReconfiguring)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Exposure", value: service.exposureModeText)
                HStack {
                    Button("Auto Exposure") {
                        service.setAutoExposure()
                        refreshDriver.bump(reason: "auto exposure")
                    }
                        .buttonStyle(.bordered)
                        .disabled(!service.supportsAutoExposure || service.isReconfiguring)
                    Button("Lock Exposure") {
                        service.lockCurrentExposure()
                        refreshDriver.bump(reason: "lock exposure")
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(!service.supportsExposureLockOrCustom || service.isReconfiguring)
                }

                if service.supportsManualISO, service.maxISO > service.minISO {
                    Slider(
                        value: Binding(
                            get: { Double(service.isoValue) },
                            set: { service.setManualISO(Float($0)) }
                        ),
                        in: Double(service.minISO)...Double(service.maxISO)
                    )
                    .disabled(service.isReconfiguring)
                    Text("ISO / Gain: \(Int(service.isoValue))")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.66))
                } else {
                    Text("Manual ISO unavailable on the selected camera.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.66))
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Focus", value: service.focusModeText)
                HStack {
                    Button("Auto Focus") {
                        service.setContinuousAutoFocus()
                        refreshDriver.bump(reason: "auto focus")
                    }
                        .buttonStyle(.bordered)
                        .disabled(!service.supportsAutoFocus || service.isReconfiguring)
                }

                if service.supportsManualFocus {
                    Slider(
                        value: Binding(
                            get: { Double(service.focusPosition) },
                            set: { service.setManualFocus(position: Float($0)) }
                        ),
                        in: 0...1
                    )
                    .disabled(service.isReconfiguring)
                    Text("Manual focus position: \(String(format: "%.2f", Double(service.focusPosition)))")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.66))
                } else {
                    Text("Manual focus unavailable on the selected camera.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.66))
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("White Balance", value: service.whiteBalanceModeText)
                HStack {
                    Button("Auto White Balance") {
                        service.setAutoWhiteBalance()
                        refreshDriver.bump(reason: "auto white balance")
                    }
                        .buttonStyle(.bordered)
                        .disabled(!service.supportsAutoWhiteBalance || service.isReconfiguring)
                    Button("Lock White Balance") {
                        service.lockCurrentWhiteBalance()
                        refreshDriver.bump(reason: "lock white balance")
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(!service.supportsWhiteBalanceLock || service.isReconfiguring)
                }
                if !service.supportsWhiteBalanceLock {
                    Text("White balance lock unavailable on the selected camera.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.66))
                }
            }

            Divider()

            LabeledContent("HDR", value: "Automatic / format controlled")
            LabeledContent("Stabilisation", value: "Automatic / connection controlled")
        }
        .padding(10)
        .broadcastMenuCard(cornerRadius: 14)
    }

    private var broadcastCameraRecoveryCard: some View {
        let service = viewModel.liveCameraService

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button("Refresh Broadcast Camera") {
                    service.refreshAvailableCameras()
                    refreshDriver.bump(reason: "refresh cameras")
                }
                .buttonStyle(.borderedProminent)
                .disabled(service.isReconfiguring)

                Button("Recover Preview") {
                    viewModel.requestCameraPreviewRecovery(for: service, reason: "operator recover from broadcast controls")
                    refreshDriver.bump(reason: "recover preview")
                }
                .buttonStyle(.bordered)
                .disabled(service.isReconfiguring)
            }

            Text("Live/Broadcast camera is independent from the Scoreboard Setup camera. Use this tab to select the iPad/external broadcast camera, set zoom, rotate the preview, and adjust quality.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .broadcastMenuCard(cornerRadius: 14)
    }

    private var broadcastCameraRotationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Manual broadcast preview rotation")
                .font(RinkLensDesignSystem.font(.caption))

            Text("Use this if the Broadcast camera appears upside down or sideways. This does not change the Scoreboard Setup camera rotation.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button {
                    viewModel.rotateLivePreviewCounterClockwise()
                    refreshDriver.bump(reason: "broadcast rotation left")
                } label: {
                    Label("Rotate Left", systemImage: "rotate.left")
                }
                .buttonStyle(.bordered)

                Button {
                    viewModel.rotateLivePreviewClockwise()
                    refreshDriver.bump(reason: "broadcast rotation right")
                } label: {
                    Label("Rotate Right", systemImage: "rotate.right")
                }
                .buttonStyle(.borderedProminent)
            }

            Button("Reset Broadcast Camera Rotation") {
                viewModel.resetLivePreviewRotation()
                refreshDriver.bump(reason: "broadcast rotation reset")
            }
            .buttonStyle(.bordered)

            Text("Current broadcast rotation: \(Int(viewModel.livePreviewRotationOffsetDegrees))°")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.66))
                .monospacedDigit()
        }
        .padding(10)
        .broadcastMenuCard(cornerRadius: 14)
    }

    @ViewBuilder
    private var ocrRuntimePage: some View {
        if RinkLensRiskFeaturePolicy.isEnabled(.minimalOperatorCameraRecordingV12) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Recognition", systemImage: "text.viewfinder")
                    .font(RinkLensDesignSystem.font(.bodyStrong))
                modeSelector
                RecognitionEvidenceControls(viewModel: viewModel) {
                    refreshDriver.bump(reason: "recognition evidence action")
                }
            }
        } else {
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader(
                        "Internal recognition",
                        systemImage: "text.viewfinder",
                        help: "There is no recognition operating mode or live-scorebug switch. Image Relay and Manual are the only operator modes."
                    )
            
                    modeSelector
            
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Period", systemImage: "number.square")
                            .font(RinkLensDesignSystem.font(.caption))
                        Text("Recognised internally every 5 seconds while Image Relay is active. Manual mode can correct the period and recognition cannot overwrite Manual mode.")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.66))
                            .fixedSize(horizontal: false, vertical: true)
            
                        Divider().opacity(0.24)
            
                        Label("Home penalty popup", systemImage: "person.text.rectangle")
                            .font(RinkLensDesignSystem.font(.caption))
                        Text("A three-frame stable frozen player crop receives at most three roster-match attempts in 2.5 seconds. Failure falls back to the frozen Image Relay image. Guest popups never use recognition.")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.66))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .broadcastMenuCard(cornerRadius: 14)
            
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Game Clock Direction")
                            .font(RinkLensDesignSystem.font(.caption))
                        Picker("Game Clock Direction", selection: Binding(
                            get: { viewModel.gameClockDirection },
                            set: {
                                viewModel.setGameClockDirection($0)
                                refreshDriver.bump(reason: "clock direction changed")
                            }
                        )) {
                            ForEach(GameClockDirection.allCases) { direction in
                                Text(direction.title).tag(direction)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text(viewModel.gameClockDirection.helpText)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.66))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .broadcastMenuCard(cornerRadius: 14)
            
                    RecognitionEvidenceControls(viewModel: viewModel) {
                        refreshDriver.bump(reason: "recognition evidence action")
                    }
                }
        }
    }

    private var displayAndOutputPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Calibration display", systemImage: "rectangle.on.rectangle", help: "The crop boxes stay editable and small. Recognition evidence is kept in Verify Zone instead of being printed next to every zone.")

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Show Recognition Boxes", isOn: ocrDisplayOptionBinding(\.showOCRBoxes, reason: "show ocr boxes changed"))
                Toggle("Show Raw Values in Verify Zone", isOn: ocrDisplayOptionBinding(\.showOCRRawValues, reason: "show ocr raw values changed"))
                Toggle("Show Confidence in Verify Zone", isOn: ocrDisplayOptionBinding(\.showOCRConfidence, reason: "show ocr confidence changed"))
                Toggle("Show Recogniser Colours", isOn: ocrDisplayOptionBinding(\.showRecogniserColours, reason: "show recogniser colours changed"))
                Toggle("Show Accepted Values", isOn: ocrDisplayOptionBinding(\.showAcceptedValues, reason: "show accepted values changed"))
            }
            .font(.caption)
            .padding(10)
            .broadcastMenuCard(cornerRadius: 14)

            VStack(alignment: .leading, spacing: 6) {
                Label("Zone label rule", systemImage: "tag.fill")
                    .font(RinkLensDesignSystem.font(.caption))
                Text("Calibration boxes now show only the short zone name and locked/accepted value, for example HP1 12 or HT1 1:42. Recognition confidence and region geometry are listed under Verify Zone diagnostics.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.66))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .broadcastMenuCard(cornerRadius: 14)

            ScorebugView(
                viewerScoreboard: viewModel.broadcastOverlaySnapshot.viewerScoreboard,
                homeLogo: viewModel.homeLogoImage,
                awayLogo: viewModel.awayLogoImage,
                isLive: true,
                modeStatusText: viewModel.operatingModeStatusText,
                showClockShotsAndPenalties: viewModel.isOCRMode
            )
            .scaleEffect(0.82, anchor: .topLeading)
            .frame(height: 110, alignment: .topLeading)
        }
    }

    private var modeSelector: some View {
        HStack(spacing: 8) {
            operatorModeButton(title: "Image Relay", systemImage: "rectangle.on.rectangle", mode: .imageRelay)
            operatorModeButton(title: "Manual", systemImage: "hand.tap.fill", mode: .manual)
        }
    }

    private func operatorModeButton(title: String, systemImage: String, mode: OperatingMode) -> some View {
        let selected = viewModel.operatingMode == mode
        return Button {
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
            withAnimation(.easeInOut(duration: 0.18)) {
                viewModel.setOperatingMode(mode)
                refreshDriver.bump(reason: "operating mode changed")
            }
        } label: {
            Label(title, systemImage: systemImage)
                .font(RinkLensDesignSystem.font(.caption))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(selected ? Color.yellow.opacity(0.9) : Color.black.opacity(0.50), in: Capsule())
                .foregroundStyle(selected ? Color.black : Color.white)
                .overlay(Capsule().stroke(selected ? Color.yellow : Color.white.opacity(0.20), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ title: String, systemImage: String, help: String) -> some View {
        BroadcastMenuHeaderLabel(title: title, subtitle: help, systemImage: systemImage)
    }

    private func ocrDisplayOptionBinding(_ keyPath: WritableKeyPath<OCRDiagnosticDisplayOptions, Bool>, reason: String) -> Binding<Bool> {
        Binding(
            get: { viewModel.ocrDiagnosticDisplayOptions[keyPath: keyPath] },
            set: { newValue in
                var options = viewModel.ocrDiagnosticDisplayOptions
                options[keyPath: keyPath] = newValue
                viewModel.ocrDiagnosticDisplayOptions = options
                refreshDriver.bump(reason: reason)
            }
        )
    }
}

private struct RecognitionEvidenceControls: View {
    let viewModel: HockeyScoreboardViewModel
    var onAction: (() -> Void)? = nil

    @ViewBuilder
    var body: some View {
        if RinkLensRiskFeaturePolicy.isEnabled(.minimalOperatorCameraRecordingV12) {
            HStack(spacing: 8) {
                Button("Reset Recognition") {
                    viewModel.resetOCRTrustState()
                    onAction?()
                }
                .buttonStyle(.borderedProminent)

                Button("Clear History") {
                    viewModel.clearDebugHistory()
                    onAction?()
                }
                .buttonStyle(.bordered)
            }
            .font(RinkLensDesignSystem.font(.caption))
            .padding(10)
            .broadcastMenuCard(cornerRadius: 14)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Recognition Evidence", systemImage: "speedometer")
                    .font(RinkLensDesignSystem.font(.caption))

                Text(viewModel.ocrAssistStatusText)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.66))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("Reset Trust") {
                        viewModel.resetOCRTrustState()
                        onAction?()
                    }
                    .buttonStyle(.bordered)

                    Button("Clear History") {
                        viewModel.clearDebugHistory()
                        onAction?()
                    }
                    .buttonStyle(.bordered)
                }
                .font(RinkLensDesignSystem.font(.caption))

                HStack(alignment: .top, spacing: 8) {
                    DiagnosticsRow(title: "Skipped", value: "\(viewModel.smartChangeSkippedOCRFrames)")
                    DiagnosticsRow(title: "Last", value: viewModel.smartChangeLastDecisionText)
                }
            }
            .padding(10)
            .broadcastMenuCard(cornerRadius: 14)
        }
    }
}

#endif
