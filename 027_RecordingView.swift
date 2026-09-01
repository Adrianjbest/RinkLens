// BUILD 707 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI

// MARK: - RinkLens NextGen Production Setup Module

/// Production Setup workspace for NextGen.
///
/// Camera source selection is presented here for both roles. Recording actions
/// remain exclusively on Broadcast. Production Setup presents the one Video
/// Quality workspace, while each mutable value remains owned by its existing
/// camera, stream-destination or recording authority.
struct RecordingRouteShellView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var runtimeStatus: AppRuntimeStatus
    let viewModel: HockeyScoreboardViewModel

    @ObservedObject private var liveCamera: HockeyCameraService
    @ObservedObject private var ocrCamera: HockeyCameraService

    init(viewModel: HockeyScoreboardViewModel) {
        self.viewModel = viewModel
        _liveCamera = ObservedObject(wrappedValue: viewModel.liveCameraService)
        _ocrCamera = ObservedObject(wrappedValue: viewModel.ocrCameraService)
    }
    var body: some View {
        ZStack {
            BroadcastMenuBackgroundView()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    header
                    broadcastCameraCard
                    scoreboardCameraCard
                    VideoQualitySettingsCard(viewModel: viewModel)
                    StreamPublishingSettingsView(viewModel: viewModel)
                    ProductionSetupSummaryCard(viewModel: viewModel)
                }
                .rinkLensHeavyScreenContent(maxWidth: 1160, horizontal: 24, vertical: 22)
                .padding(.top, RinkLensCommandCentreChrome.scrollContentTopClearance)
            }
            .rinkLensScrollPerformance("Production Setup")
        }
        .broadcastMenuText()
        .rinkLensCommandCentreReturnButton(
            accessibilityHint: "Returns to Command Centre and leaves camera selection with the camera owner"
        ) {
            MainThreadStallMonitor.shared.markContext("RNG-S7A route change requested: Recording -> Command Centre")
            coordinator.navigate(to: .commandCentre)
        }
        .onAppear {
            MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("Production Setup module appeared"))
            runtimeStatus.markCameraSetupVisible(viewModel: viewModel)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Production Setup")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)

                Text("Cameras, video quality and streaming")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.68))
            }

            Spacer()

            statusBadge
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(cameraSelectionReady ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
            Text(cameraSelectionReady ? "Cameras selected" : "Camera selection needed")
                .font(.caption.bold())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }

    private var cameraSelectionReady: Bool {
        liveCamera.selectedCameraID != nil && ocrCamera.selectedCameraID != nil
    }

    private var broadcastCameraCard: some View {
        CameraSourceSettingsCard(
            title: "1. Broadcast camera",
            subtitle: "Main video",
            systemImage: "video.fill",
            pickerTitle: "Broadcast camera",
            service: liveCamera,
            recoveryInProgress: viewModel.cameraRecoveryInProgress,
            framesReceivedText: "Broadcast camera selected",
            noFramesText: "No Broadcast camera selected",
            onSelect: { viewModel.selectLiveCamera(id: $0) },
            onRecover: { viewModel.requestCameraPreviewRecovery(for: liveCamera, reason: "Production Setup Broadcast recovery") }
        )
    }

    private var scoreboardCameraCard: some View {
        CameraSourceSettingsCard(
            title: "2. Scoreboard camera",
            subtitle: "Reads the scoreboard",
            systemImage: "text.viewfinder",
            pickerTitle: "Scoreboard camera",
            service: ocrCamera,
            recoveryInProgress: viewModel.cameraRecoveryInProgress,
            framesReceivedText: "Scoreboard camera selected",
            noFramesText: "No Scoreboard camera selected",
            onSelect: { viewModel.selectOCRCamera(id: $0) },
            onRecover: { viewModel.requestCameraPreviewRecovery(for: ocrCamera, reason: "Production Setup scoreboard recovery") }
        )
    }

}

/// Recovery CK / RL-203: one operator surface for all video-quality intent.
/// This view owns no mutable truth; it submits directly to the existing camera,
/// stream-destination and recording authorities.
private struct VideoQualitySettingsCard: View {
    let viewModel: HockeyScoreboardViewModel

    @ObservedObject private var productionStore: RinkLensCameraControlStore
    @ObservedObject private var destinationStore = StreamDestinationStore.shared
    @ObservedObject private var controlStore = StreamControlStore.shared
    @ObservedObject private var recorder = AppContainer.shared.recordingEngine

    init(viewModel: HockeyScoreboardViewModel) {
        self.viewModel = viewModel
        _productionStore = ObservedObject(wrappedValue: viewModel.cameraControlStore)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BroadcastMenuHeaderLabel(
                title: "3. Video quality",
                subtitle: "One picture setting for Broadcast, streaming and recording",
                systemImage: "camera.aperture"
            )

            Picker("Camera and programme quality", selection: Binding(
                get: { productionStore.snapshot.broadcastProductionProfile },
                set: {
                    viewModel.setBroadcastProductionProfile(
                        $0,
                        source: "ProductionSetup.VideoQuality",
                        reason: "Operator selected the authoritative Video Quality master profile"
                    )
                }
            )) {
                ForEach(BroadcastProductionProfile.allCases) { profile in
                    Text(profile.rawValue).tag(profile)
                }
            }
            .pickerStyle(.segmented)
            .disabled(controlStore.requestedStateActive || (recorder.state != .idle && recorder.state != .failed))

            Divider().overlay(.white.opacity(0.14))

            Text("Streaming")
                .font(.subheadline.weight(.semibold))

            Picker("Live stream codec", selection: $destinationStore.videoCodec) {
                ForEach(StreamDestinationStore.VideoCodec.allCases) { codec in
                    Text(codec.displayName).tag(codec)
                }
            }
            .pickerStyle(.segmented)
            .disabled(controlStore.requestedStateActive)

            if destinationStore.videoCodec != destinationStore.resolvedVideoCodec {
                Label(destinationStore.videoCodecResolutionText, systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.cyan)
            }

            if destinationStore.ingestProtocol == .rtmps {
                Toggle("Automatic stream bitrate adaptation", isOn: $destinationStore.adaptiveBitrate)
                    .tint(.cyan)
                    .disabled(controlStore.requestedStateActive)
            }

            Divider().overlay(.white.opacity(0.14))

            recordingCompressionControls
                .disabled(recorder.state != .idle && recorder.state != .failed)
        }
        .padding(14)
        .broadcastMenuCard(cornerRadius: 18)
    }

    @ViewBuilder
    private var recordingCompressionControls: some View {
        Text("Recording")
            .font(.subheadline.weight(.semibold))

        Toggle("Custom recording compression", isOn: Binding(
            get: { recorder.customVideoSettingsEnabled },
            set: { viewModel.setCustomRecordingVideoSettingsEnabled($0) }
        ))

        if recorder.customVideoSettingsEnabled {
            Picker("Recording codec", selection: Binding<BroadcastRecordingProfile.Codec>(
                get: { recorder.customVideoCodec },
                set: {
                    recorder.setCustomVideoCodec(
                        $0,
                        source: "ProductionSetup.VideoQuality",
                        reason: "Operator selected the recording encoder in the sole Video Quality workspace"
                    )
                }
            )) {
                ForEach(recorder.availableCustomVideoCodecs) { codec in
                    Text(codec.settingsTitle).tag(codec)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Recording bitrate").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(recorder.customVideoBitrateMbps) Mbps")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            }

            Slider(value: Binding(
                get: { Double(recorder.customVideoBitrateMbps) },
                set: {
                    recorder.setCustomVideoBitrateMbps(
                        Int($0.rounded()),
                        source: "ProductionSetup.VideoQuality",
                        reason: "Operator adjusted recording bitrate in the sole Video Quality workspace"
                    )
                }
            ), in: Double(RecordingEngine.minimumCustomVideoBitrateMbps)...Double(RecordingEngine.maximumCustomVideoBitrateMbps), step: 1)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("About \(recorder.estimatedRecordingMegabytesPerMinute) MB/min")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(recorder.customVideoBitrateMbps < recordingRecommendedBitrateMbps ? .orange : .white.opacity(0.72))

                Spacer(minLength: 12)

                Text(recordingQualityGuideTitle)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.54))
            }

            HStack(spacing: 8) {
                recordingQualityGuideChip("Compact", bitrateMbps: recordingCompactBitrateMbps)
                recordingQualityGuideChip("Recommended", bitrateMbps: recordingRecommendedBitrateMbps)
                recordingQualityGuideChip("High", bitrateMbps: recordingHighBitrateMbps)
            }

            if recorder.customVideoBitrateMbps < recordingRecommendedBitrateMbps {
                Text("Below the recommended sports starting point for the selected picture profile; fast movement may lose detail.")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        } else {
            Label("H.264 · 8 Mbps", systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.76))
        }

        if recorder.state != .idle && recorder.state != .failed {
            Label("End the recording before changing Video Quality.", systemImage: "lock.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
        }
    }

    private var recordingRecommendedBitrateMbps: Int {
        productionStore.snapshot.broadcastProductionProfile.recommendedCustomRecordingBitrateMbps
    }

    private var recordingCompactBitrateMbps: Int {
        max(2, Int((Double(recordingRecommendedBitrateMbps) * 0.75).rounded()))
    }

    private var recordingHighBitrateMbps: Int {
        min(RecordingEngine.maximumCustomVideoBitrateMbps, Int((Double(recordingRecommendedBitrateMbps) * 1.5).rounded()))
    }

    private var recordingQualityGuideTitle: String {
        switch productionStore.snapshot.broadcastProductionProfile {
        case .smoothMotion, .balanced:
            return "1080p60 sports size guide"
        case .lowLight:
            return "1080p30 size guide"
        case .reducedData:
            return "720p60 size guide"
        }
    }

    private func estimatedMegabytesPerMinute(for bitrateMbps: Int) -> Int {
        Int((Double(bitrateMbps) * 60.0 / 8.0).rounded())
    }

    private func recordingQualityGuideChip(_ title: String, bitrateMbps: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(title == "Recommended" ? .cyan : .white.opacity(0.72))
            Text("\(bitrateMbps) Mbps · ~\(estimatedMegabytesPerMinute(for: bitrateMbps)) MB/min")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.60))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct ProductionSetupSummaryCard: View {
    @ObservedObject private var liveCamera: HockeyCameraService
    @ObservedObject private var ocrCamera: HockeyCameraService
    @ObservedObject private var productionStore: RinkLensCameraControlStore
    @ObservedObject private var destinationStore = StreamDestinationStore.shared
    @ObservedObject private var controlStore = StreamControlStore.shared
    @ObservedObject private var recorder = AppContainer.shared.recordingEngine

    init(viewModel: HockeyScoreboardViewModel) {
        _liveCamera = ObservedObject(wrappedValue: viewModel.liveCameraService)
        _ocrCamera = ObservedObject(wrappedValue: viewModel.ocrCameraService)
        _productionStore = ObservedObject(wrappedValue: viewModel.cameraControlStore)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BroadcastMenuHeaderLabel(title: "Setup summary & stream status", subtitle: "", systemImage: "checkmark.circle.fill")
                .padding(.bottom, 8)
            summaryRow("Broadcast", liveCamera.selectedCameraLabel)
            summaryRow("Scoreboard", ocrCamera.selectedCameraLabel)
            summaryRow("Picture", productionStore.snapshot.broadcastProductionProfile.compactSummary)
            summaryRow("Streaming", "\(destinationStore.resolvedVideoCodec.displayName) · \(destinationStore.protocolLabel)")
            summaryRow("Recording", recordingSummary)
            summaryRow("YouTube", youtubeSummary, divider: false)

            Divider().overlay(.white.opacity(0.12))
                .padding(.vertical, 8)

            streamRuntimeSummary
        }
        .padding(14)
        .broadcastMenuCard(cornerRadius: 18)
    }

    private var recordingSummary: String {
        recorder.customVideoSettingsEnabled
            ? "\(recorder.customVideoCodec.settingsTitle) · \(recorder.customVideoBitrateMbps) Mbps"
            : "H.264 · 8 Mbps"
    }

    private var youtubeSummary: String {
        if destinationStore.isYouTubeLiveDestination {
            return destinationStore.isConfigured ? "Destination configured" : "Destination selected · setup required"
        }
        return "Not selected"
    }

    private var streamRuntimeSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Stream runtime")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Label(controlStore.statusTitle, systemImage: controlStore.statusSystemImage)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(controlStore.activelyPublishingStateActive ? .green : .white.opacity(0.72))
            }

            HStack(spacing: 8) {
                runtimeBadge("REQUESTED", active: controlStore.requestedStateActive)
                runtimeBadge("CONNECTED", active: controlStore.connectedStateActive)
                runtimeBadge("PUBLISHING", active: controlStore.activelyPublishingStateActive)
            }

            Text(controlStore.connectionStatusText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.68))

            if !controlStore.lastErrorText.isEmpty {
                Label(controlStore.lastErrorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }

            Text("Start and stop the live stream from Broadcast.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.52))
        }
        .padding(.top, 2)
    }

    private func runtimeBadge(_ title: String, active: Bool) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(active ? Color.green : Color.white.opacity(0.20))
                .frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(active ? .white : .white.opacity(0.42))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(.white.opacity(0.045), in: Capsule())
    }

    private func summaryRow(_ title: String, _ value: String, divider: Bool = true) -> some View {
        HStack(spacing: 12) {
            Text(title).foregroundStyle(.white.opacity(0.64))
            Spacer()
            Text(value).font(.body.weight(.semibold)).multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            if divider { Divider().overlay(.white.opacity(0.12)) }
        }
    }
}

#endif
