// BUILD 785: direct RinkLens programme-output streaming state owner.
#if canImport(SwiftUI)
import SwiftUI
import Foundation
import Combine
import UIKit
import CoreImage

nonisolated struct RinkLensStreamOverlayStructuralRevision: Sendable, Equatable {
    let layoutIdentity: String
    let homeLogoIdentity: String
    let awayLogoIdentity: String
    let sponsorIdentity: String
    let isVisible: Bool
}

nonisolated enum RinkLensStreamOverlayInvalidationPolicy {
    static func structureChanged(
        previous: RinkLensStreamOverlayStructuralRevision?,
        next: RinkLensStreamOverlayStructuralRevision
    ) -> Bool {
        previous != next
    }
}

nonisolated enum RinkLensStreamOverlayCommitPolicy {
    /// Dynamic Clock/score material may advance while one complete render is in
    /// flight. That completed image remains safe to display when its structural
    /// identity still matches; only a layout/logo/sponsor/visibility change can
    /// invalidate its geometry.
    static func admitsCompletedRender(
        renderedStructure: RinkLensStreamOverlayStructuralRevision,
        currentStructure: RinkLensStreamOverlayStructuralRevision
    ) -> Bool {
        renderedStructure == currentStructure
    }
}

nonisolated enum RinkLensStreamOverlaySchedulerPolicy {
    /// An asynchronous completion may mutate the capacity-one scheduler only
    /// while it still owns both the active render slot and the live stream.
    static func completionOwnsScheduler(
        renderGeneration: UUID,
        activeRenderGeneration: UUID?,
        streamGeneration: UUID
    ) -> Bool {
        renderGeneration == activeRenderGeneration
            && renderGeneration == streamGeneration
    }
}

nonisolated struct RinkLensElapsedRuntimeState: Sendable, Equatable {
    private(set) var requestedUptime: TimeInterval?
    private(set) var acknowledgedRunningUptime: TimeInterval?

    mutating func request(atUptime uptime: TimeInterval) {
        requestedUptime = uptime
        acknowledgedRunningUptime = nil
    }

    mutating func acknowledgeRunning(atUptime uptime: TimeInterval) {
        acknowledgedRunningUptime = uptime
    }

    mutating func acknowledgeStopped() {
        requestedUptime = nil
        acknowledgedRunningUptime = nil
    }

    func elapsedSeconds(atUptime uptime: TimeInterval) -> Int? {
        guard let acknowledgedRunningUptime else { return nil }
        return max(0, Int(uptime - acknowledgedRunningUptime))
    }
}

nonisolated enum RinkLensElapsedRuntimeFormatter {
    static func text(seconds: Int) -> String {
        let safe = max(0, seconds)
        let hours = safe / 3_600
        let minutes = (safe % 3_600) / 60
        let remainder = safe % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%02d:%02d", minutes, remainder)
    }
}

/// Pure admission decision owned by the stream control boundary. It resolves
/// only stream work; camera and recording cadence remain under their existing
/// physical owners.
nonisolated struct RinkLensConcurrentOutputAdmission: Sendable, Equatable {
    let requested: StreamDestinationStore.QualityProfile
    let resolved: StreamDestinationStore.QualityProfile
    let reason: String

    var wasConstrained: Bool { requested != resolved }
}

nonisolated enum RinkLensConcurrentOutputAdmissionPolicy {
    static func resolve(
        requested: StreamDestinationStore.QualityProfile,
        ingestProtocol: StreamDestinationStore.IngestProtocol,
        recordingActive: Bool
    ) -> RinkLensConcurrentOutputAdmission {
        guard ingestProtocol == .hls,
              recordingActive,
              requested == .fullHD1080p60 else {
            return .init(
                requested: requested,
                resolved: requested,
                reason: "Requested stream profile admitted without a concurrent-output constraint"
            )
        }
        return .init(
            requested: requested,
            resolved: .fullHD1080p30,
            reason: "Recording is physically active; the HLS leg is limited to 1080p30 to protect recording and camera cadence"
        )
    }
}

/// MainActor owner of operator intent and the acknowledged state of the one
/// in-process programme publisher. CaptureEngine continues to own camera
/// hardware; RinkLensDirectStreamPublisher owns RTMPS/encoder lifetime.
final class StreamControlStore: ObservableObject {
    static let shared = StreamControlStore()
    static let publisherTargetLinked = true

    enum RuntimeState: String, Equatable {
        case idle
        case openingPicker // decode-only compatibility for older diagnostics
        case connecting
        case connected
        case publishing
        case stopRequested
        case stopped
        case failed
    }

    enum HealthLevel: String { case info, good, warning, failed }

    enum StopOrigin: String {
        case operatorBroadcastButton
        case operatorStreamPanel
        case lifecycle
        case failure
        case configurationReset

        var isOperator: Bool {
            self == .operatorBroadcastButton || self == .operatorStreamPanel
        }
    }

    @Published private(set) var runtimeState: RuntimeState = .idle
    @Published private(set) var healthLevel: HealthLevel = .info
    @Published private(set) var reconnectAvailable = false
    @Published private(set) var lastActionText = "Ready. Configure an RTMPS destination, then publish the RinkLens programme output."
    @Published private(set) var broadcastStatusText = "Not broadcasting."
    @Published private(set) var connectionStatusText = "Disconnected"
    @Published private(set) var healthMessageText = "No stream flow active."
    @Published private(set) var lastErrorText = ""
    @Published private(set) var lastRecoveryText = ""
    @Published private(set) var lastVideoBufferCount = 0
    @Published private(set) var lastAppAudioBufferCount = 0
    @Published private(set) var lastMicAudioBufferCount = 0
    @Published private(set) var appliedVideoBitrate = 0
    @Published private(set) var requestedVideoCodec = "No request"
    @Published private(set) var resolvedVideoCodec = "Not resolved"
    @Published private(set) var appliedVideoCodec = "Not configured"
    @Published private(set) var requestedStreamQualityProfile = "No request"
    @Published private(set) var resolvedStreamQualityProfile = "Not resolved"
    @Published private(set) var appliedStreamQualityProfile = "Not configured"
    @Published private(set) var lastTransportBytesOutPerSecond = 0
    @Published private(set) var activeIngestProtocol: StreamDestinationStore.IngestProtocol = .rtmps
    @Published private(set) var reconnectCount = 0
    @Published private(set) var missingConfigurationWarnings: [String] = []

    private struct DirectOverlayRevision: Equatable {
        let structural: RinkLensStreamOverlayStructuralRevision
        let scoreboardState: ScoreboardState
        let relayMaterialIdentity: String
        let feedFresh: Bool
        let modeStatusText: String
        let strengthState: StrengthState
        let activeBanner: BroadcastEvent?
        let homeLogo: UIImage?
        let awayLogo: UIImage?
        let layout: BroadcastScoreboardLayoutSnapshot
        let sponsorRevision: UInt64

        static func == (lhs: DirectOverlayRevision, rhs: DirectOverlayRevision) -> Bool {
            lhs.structural == rhs.structural
                && lhs.scoreboardState == rhs.scoreboardState
                && lhs.relayMaterialIdentity == rhs.relayMaterialIdentity
                && lhs.feedFresh == rhs.feedFresh
                && lhs.modeStatusText == rhs.modeStatusText
                && lhs.strengthState == rhs.strengthState
                && lhs.activeBanner == rhs.activeBanner
                && lhs.homeLogo === rhs.homeLogo
                && lhs.awayLogo === rhs.awayLogo
                && lhs.layout == rhs.layout
                && lhs.sponsorRevision == rhs.sponsorRevision
        }
    }

    private var directPublisher: (any RinkLensProgrammePublisher)?
    private var directOverlayObservation: AnyCancellable?
    private var directCaptureObservation: AnyCancellable?
    private var lastDirectOverlayRevision: DirectOverlayRevision?
    private var directOverlayRefreshInFlight = false
    private var directOverlayRefreshPending = false
    private var directOverlayRefreshGeneration: UUID?
    private var streamGeneration = UUID()
    private var directStartRequestedUptime: TimeInterval?
    private var elapsedRuntime = RinkLensElapsedRuntimeState()
    private var recordedStartupMilestones: Set<String> = []
    private var directCaptureBindingChangedUptime: TimeInterval?
    private var directVideoSourceWarningKey: String?
    private var hlsMediaContinuityHealthy = false

    var publisherAvailable: Bool { Self.publisherTargetLinked }
    var broadcastSafeModeActive: Bool { false }
    var transportEvidenceText: String {
        switch activeIngestProtocol {
        case .rtmps: return "\(lastTransportBytesOutPerSecond / 1_000) KB/s"
        case .hls: return lastTransportBytesOutPerSecond > 0
            ? "\(lastTransportBytesOutPerSecond / 1_000) KB segment accepted"
            : "awaiting segment"
        }
    }

    var requestedStateActive: Bool {
        switch runtimeState {
        case .connecting, .connected, .publishing, .stopRequested: return true
        case .idle, .openingPicker, .stopped, .failed: return false
        }
    }

    /// The session callback crosses connect and publish atomically, so these
    /// projections share the same physical acknowledgement boundary.
    var connectedStateActive: Bool { runtimeState == .connected || runtimeState == .publishing }
    var activelyPublishingStateActive: Bool { runtimeState == .publishing }

    func publishingElapsedText(atUptime uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> String {
        guard let seconds = elapsedRuntime.elapsedSeconds(atUptime: uptime) else { return "00:00" }
        return RinkLensElapsedRuntimeFormatter.text(seconds: seconds)
    }

    /// Output-side half of one capture handoff. Idle streaming is already held;
    /// an active publisher must own a complete programme frame before hardware
    /// may change so transport video remains continuous.
    func holdForCaptureHandoff(
        transactionID: UUID,
        targetCadence: RinkLensCaptureCadence
    ) -> Bool {
        guard requestedStateActive else { return true }
        guard runtimeState == .publishing, let directPublisher else { return false }
        return directPublisher.holdCaptureHandoff(
            transactionID: transactionID,
            targetCadence: targetCadence
        )
    }

    func rebindAfterCaptureHandoff(
        transactionID: UUID,
        captureGeneration: Int,
        physicalDeviceID: String?,
        cadence: RinkLensCaptureCadence
    ) -> Bool {
        guard requestedStateActive else { return true }
        guard let directPublisher else { return false }
        return directPublisher.rebindCaptureHandoff(
            transactionID: transactionID,
            generation: captureGeneration,
            physicalDeviceID: physicalDeviceID,
            cadence: cadence
        )
    }

    func abortCaptureHandoff(transactionID: UUID) {
        directPublisher?.abortCaptureHandoff(transactionID: transactionID)
    }

    var statusTitle: String {
        switch runtimeState {
        case .idle: return "Ready"
        case .openingPicker: return "Legacy state"
        case .connecting: return "Connecting"
        case .connected: return "Connected — awaiting media"
        case .publishing: return "Programme Live"
        case .stopRequested: return "Stopping"
        case .stopped: return "Stopped"
        case .failed: return "Failed"
        }
    }

    var statusSystemImage: String {
        switch runtimeState {
        case .publishing: return "dot.radiowaves.left.and.right"
        case .connecting: return "antenna.radiowaves.left.and.right"
        case .connected: return "cable.connector"
        case .openingPicker, .stopRequested: return "stop.circle"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "stop.circle.fill"
        }
    }

    var statusAccessibilityText: String {
        switch runtimeState {
        case .publishing: return "RinkLens programme output is actively publishing. \(healthMessageText)"
        case .connecting: return "RinkLens programme publisher is connecting. \(healthMessageText)"
        case .connected: return "RinkLens is connected and awaiting physical media delivery. \(healthMessageText)"
        case .failed: return "Broadcast failed. \(lastErrorText.isEmpty ? healthMessageText : lastErrorText)"
        default: return "\(broadcastStatusText) \(healthMessageText)"
        }
    }

    func updateConfigurationWarnings(destination: StreamDestinationStore) {
        missingConfigurationWarnings = destination.validationWarnings
        guard !requestedStateActive else { return }
        if missingConfigurationWarnings.isEmpty {
            healthLevel = .good
            connectionStatusText = "Ready"
            healthMessageText = "The direct RinkLens programme publisher is ready."
        } else {
            healthLevel = .warning
            connectionStatusText = "Missing configuration"
            healthMessageText = missingConfigurationWarnings.joined(separator: " ")
        }
    }

    func startInAppPublisher(destination: StreamDestinationStore, viewModel: HockeyScoreboardViewModel) {
        // Build 143 / RL-264: StreamControlStore is the single start-intent owner.
        // A second UI start must not replace a publisher that is connecting/live.
        guard !requestedStateActive else {
            RinkLensStructuredEventLogger.shared.record(
                domain: .streaming,
                event: "direct_start_intent_coalesced",
                entityID: "runtime",
                previous: ["state": runtimeState.rawValue],
                next: ["state": runtimeState.rawValue, "publisherRetained": "true"],
                source: "StreamControlStore",
                reason: "An active start/publish/stop transaction already owns the programme publisher",
                authoritativeOwner: "StreamControlStore"
            )
            return
        }
        updateConfigurationWarnings(destination: destination)
        guard destination.isReadyForBroadcastFlow else {
            setFailed(status: "Stream configuration is incomplete.", error: destination.validationSummaryText, connectionStatus: "Configuration failed")
            return
        }
        let publishURL = destination.ingestProtocol == .rtmps ? URL(string: destination.fullPublishURLText) : nil
        let hlsUploadBase = destination.ingestProtocol == .hls ? destination.hlsUploadBaseURLText : ""
        guard (destination.ingestProtocol == .rtmps && publishURL != nil)
                || (destination.ingestProtocol == .hls && !hlsUploadBase.isEmpty) else {
            setFailed(status: "Stream configuration is incomplete.", error: "The selected ingest protocol could not form a publish URL.", connectionStatus: "Configuration failed")
            return
        }

        let capture = viewModel.externalOCRMultiCamCoordinator.snapshot
        let broadcastEvidence = RinkLensFrameHub.shared.diagnosticSnapshot().broadcast
        let broadcastDeviceID = capture.liveDeviceID
        let broadcastFresh = broadcastEvidence.sequence > 0
            && (broadcastEvidence.ageSeconds ?? .infinity) <= 1.5
            && broadcastEvidence.captureGeneration == capture.transitionGeneration
            && broadcastEvidence.physicalDeviceID == broadcastDeviceID
        guard capture.sessionRunning,
              capture.activeMode.requiresBroadcast,
              broadcastDeviceID != nil,
              broadcastFresh else {
            setFailed(
                status: "Broadcast camera is not ready for streaming.",
                error: "Go Live requires a fresh current-generation Broadcast frame from the acknowledged physical Broadcast device. OCR degradation does not block a healthy Broadcast branch.",
                connectionStatus: "Camera not ready"
            )
            return
        }

        destination.save()
        streamGeneration = UUID()
        let generation = streamGeneration
        directPublisher?.cancel()
        directPublisher = nil
        stopDirectOverlayRefresh()
        stopDirectCaptureObservation()

        let resolvedCodec = destination.resolvedVideoCodec
        // Recovery DC: stream cadence follows verified physical Broadcast truth,
        // not the nominal production-profile request. This prevents a 30/24fps
        // source from unnecessarily creating a 60fps programme encoder.
        let requestedQualityProfile: StreamDestinationStore.QualityProfile = {
            guard let format = capture.liveFormat else {
                return viewModel.broadcastProductionProfile.streamQualityProfile
            }
            if format.width <= 1280 || format.height <= 720 {
                return .hd720p60
            }
            return format.fps <= 30.5 ? .fullHD1080p30 : .fullHD1080p60
        }()
        let recordingActive = RinkLensRecordingCaptureLease.shared.isRecordingActive()
        let outputAdmission = RinkLensConcurrentOutputAdmissionPolicy.resolve(
            requested: requestedQualityProfile,
            ingestProtocol: destination.ingestProtocol,
            recordingActive: recordingActive
        )
        let qualityProfile = outputAdmission.resolved
        activeIngestProtocol = destination.ingestProtocol
        requestedStreamQualityProfile = outputAdmission.requested.rawValue
        resolvedStreamQualityProfile = outputAdmission.resolved.rawValue
        appliedStreamQualityProfile = "Pending encoder"
        requestedVideoCodec = destination.videoCodec.encoderName
        resolvedVideoCodec = resolvedCodec.encoderName
        appliedVideoCodec = "Pending encoder"
        let previous = runtimeState
        runtimeState = .connecting
        directStartRequestedUptime = ProcessInfo.processInfo.systemUptime
        elapsedRuntime.request(atUptime: directStartRequestedUptime ?? 0)
        recordedStartupMilestones = []
        directCaptureBindingChangedUptime = nil
        directVideoSourceWarningKey = nil
        RinkLensProgrammeStreamCaptureRequirement.shared.setRequested(true)
        logRuntimeTransition(from: previous, to: runtimeState, event: "direct_start_requested", reason: "Operator started the in-app RinkLens programme publisher")
        healthLevel = .info
        reconnectAvailable = false
        lastActionText = "Starting the RinkLens programme-output publisher."
        broadcastStatusText = "Preparing RinkLens programme output."
        connectionStatusText = "Connecting"
        healthMessageText = "Only the RinkLens camera, scorebug and enabled overlays will be sent."
        lastErrorText = ""
        lastRecoveryText = ""
        lastVideoBufferCount = 0
        lastAppAudioBufferCount = 0
        lastMicAudioBufferCount = 0
        lastTransportBytesOutPerSecond = 0
        hlsMediaContinuityHealthy = destination.ingestProtocol != .hls
        appliedVideoBitrate = resolvedCodec.maximumBitrate(for: qualityProfile)

        RinkLensStructuredEventLogger.shared.record(
            domain: .streaming,
            event: outputAdmission.wasConstrained
                ? "stream_output_profile_constrained"
                : "stream_output_profile_admitted",
            entityID: "runtime",
            previous: [
                "requestedProfile": outputAdmission.requested.rawValue,
                "recordingActive": String(recordingActive)
            ],
            next: [
                "resolvedProfile": outputAdmission.resolved.rawValue,
                "ingestProtocol": destination.ingestProtocol.rawValue
            ],
            source: "StreamControlStore",
            reason: outputAdmission.reason
        )

        let streamOutputSize = qualityProfile.outputSize
        viewModel.refreshBroadcastOverlayState()
        lastDirectOverlayRevision = directOverlayRevision(viewModel: viewModel)
        BroadcastRecordingStage8PixelBufferFrameProvider.prewarmOverlay(
            viewModel: viewModel,
            outputSize: streamOutputSize
        ) { [weak self, weak viewModel] overlay in
            guard let self, let viewModel,
                  self.streamGeneration == generation,
                  self.runtimeState == .connecting else { return }
            let scorebugRequired = BroadcastScoreboardLayoutSettings.shared.snapshot.isVisible
            guard overlay != nil || !scorebugRequired else {
                self.setFailed(
                    status: "Stream programme overlay could not be prepared.",
                    error: "The scorebug renderer did not acknowledge a complete first overlay; no camera-only stream was started.",
                    connectionStatus: "Overlay preparation failed"
                )
                return
            }
            self.recordStartupMilestone(
                "overlayReady",
                event: "stream_start_overlay_ready",
                generation: generation
            )
            let source = BroadcastRecordingStage8PixelBufferFrameProvider.makeSourceContext(viewModel: viewModel, prewarmedOverlay: overlay)
            let callbacks = RinkLensDirectStreamCallbacks(
                    onConnecting: { [weak self] in
                        guard let self, self.streamGeneration == generation else { return }
                        self.connectionStatusText = self.activeIngestProtocol == .hls ? "Preparing HLS" : "Connecting"
                        self.broadcastStatusText = self.activeIngestProtocol == .hls
                            ? "Preparing encoded HLS programme output for YouTube."
                            : "Connecting RinkLens programme output to YouTube."
                    },
                    onConnected: { [weak self] in self?.acceptDirectConnected(generation: generation) },
                    onStopped: { [weak self] in self?.acceptDirectStopped(generation: generation) },
                    onFailure: { [weak self] message in self?.acceptDirectFailure(message, generation: generation) },
                    onFirstProgrammeFrame: { [weak self] overlayIncluded, outputSize in
                        guard let self, self.streamGeneration == generation else { return }
                        self.recordStartupMilestone(
                            "firstVideoFrameAccepted",
                            event: "stream_start_first_video_frame_accepted",
                            generation: generation,
                            extra: ["outputSize": outputSize]
                        )
                        RinkLensStructuredEventLogger.shared.record(
                            domain: .streaming,
                            event: "direct_first_programme_frame_acknowledged",
                            entityID: "runtime",
                            previous: ["videoFrames": "0"],
                            next: [
                                "videoFrames": "1",
                                "overlayIncluded": overlayIncluded ? "true" : "false",
                                "outputSize": outputSize,
                                "requestedCodec": self.requestedVideoCodec,
                                "appliedCodec": self.appliedVideoCodec
                            ],
                            source: self.activeIngestProtocol == .hls ? "RinkLensYouTubeHLSPublisher" : "RinkLensDirectStreamPublisher",
                            reason: overlayIncluded
                                ? "First encoder sample physically included the prepared parity-harnessed overlay"
                                : "First encoder sample was camera-only because the scorebug is disabled"
                        )
                    },
                    onVideoFrames: { [weak self] count in
                        guard let self, self.streamGeneration == generation else { return }
                        self.lastVideoBufferCount = count
                        self.evaluateProgrammeVideoSource(
                            AppContainer.shared.captureEngine.snapshot,
                            generation: generation
                        )
                        self.evaluateActivePublishingAcknowledgement(generation: generation)
                    },
                    onMicAudioBuffers: { [weak self] count in
                        guard let self, self.streamGeneration == generation else { return }
                        self.lastMicAudioBufferCount = count
                        self.evaluateActivePublishingAcknowledgement(generation: generation)
                    },
                    onAppliedBitrate: { [weak self] bitrate in
                        guard self?.streamGeneration == generation else { return }
                        self?.appliedVideoBitrate = bitrate
                    },
                    onCodecConfigured: { [weak self] codec in
                        guard let self, self.streamGeneration == generation else { return }
                        self.appliedVideoCodec = codec
                        self.appliedStreamQualityProfile = qualityProfile.rawValue
                        self.recordStartupMilestone(
                            "encoderReady",
                            event: "stream_start_encoder_ready",
                            generation: generation,
                            extra: ["codec": codec]
                        )
                        RinkLensStructuredEventLogger.shared.record(
                            domain: .streaming,
                            event: "stream_encoder_codec_configured",
                            entityID: "runtime",
                            previous: ["requestedCodec": self.requestedVideoCodec],
                            next: ["appliedCodec": codec],
                            source: self.activeIngestProtocol == .hls ? "RinkLensYouTubeHLSPublisher" : "RinkLensDirectStreamPublisher",
                            reason: "Publisher accepted the requested VideoToolbox codec settings without fallback"
                        )
                    },
                    onTransportBytesOut: { [weak self] bytesPerSecond in
                        guard let self, self.streamGeneration == generation else { return }
                        let firstTransportAcknowledgement = self.lastTransportBytesOutPerSecond == 0 && bytesPerSecond > 0
                        self.lastTransportBytesOutPerSecond = bytesPerSecond
                        if firstTransportAcknowledgement {
                            self.recordStartupMilestone(
                                "firstSegmentAcknowledged",
                                event: "stream_start_first_segment_acknowledged",
                                generation: generation,
                                extra: ["bytes": String(bytesPerSecond)]
                            )
                        }
                        self.evaluateActivePublishingAcknowledgement(generation: generation)
                    },
                    onMediaContinuity: { [weak self] healthy, detail in
                        self?.acceptMediaContinuity(healthy, detail: detail, generation: generation)
                    }
                )
            let publisher: any RinkLensProgrammePublisher
            switch destination.ingestProtocol {
            case .rtmps:
                guard let publishURL else {
                    self.setFailed(status: "Stream configuration is incomplete.", error: "Invalid RTMPS publish URL.", connectionStatus: "Configuration failed")
                    return
                }
                let rtmpsPublisher = RinkLensDirectStreamPublisher()
                rtmpsPublisher.start(
                    publishURL: publishURL,
                    profile: qualityProfile,
                    codec: resolvedCodec,
                    adaptiveBitrate: destination.adaptiveBitrate,
                    frameSource: source,
                    callbacks: callbacks
                )
                publisher = rtmpsPublisher
            case .hls:
                let hlsPublisher = RinkLensYouTubeHLSPublisher()
                hlsPublisher.start(
                    uploadBaseURLText: hlsUploadBase,
                    profile: qualityProfile,
                    codec: resolvedCodec,
                    frameSource: source,
                    callbacks: callbacks
                )
                publisher = hlsPublisher
            }
            self.directPublisher = publisher
            self.installDirectCaptureObservation(
                generation: generation,
                uiState: viewModel.externalOCRMultiCamCoordinator.uiState
            )
            self.installDirectOverlayObservation(
                generation: generation,
                outputSize: streamOutputSize,
                publisher: publisher,
                viewModel: viewModel
            )
        }
    }

    func requestStopPublishing(origin: StopOrigin) {
        guard let directPublisher,
              runtimeState == .connecting || runtimeState == .connected || runtimeState == .publishing else { return }
        let previous = runtimeState
        runtimeState = .stopRequested
        logRuntimeTransition(
            from: previous,
            to: runtimeState,
            event: "direct_stop_requested",
            reason: origin.isOperator
                ? "Operator stopped the in-app programme publisher from \(origin.rawValue)"
                : "Programme publisher stop requested by \(origin.rawValue)"
        )
        connectionStatusText = "Stopping"
        broadcastStatusText = activeIngestProtocol == .hls ? "Finishing the HLS media playlist…" : "Closing the physical RTMPS connection…"
        healthMessageText = activeIngestProtocol == .hls
            ? "Stopped will appear after the final segment and playlist are acknowledged."
            : "Stopped will appear only after the publisher socket has closed."
        directPublisher.stop()
    }

    func resetLocalStatusOnly() {
        streamGeneration = UUID()
        let publisher = directPublisher
        directPublisher = nil
        publisher?.cancel()
        stopDirectOverlayRefresh()
        stopDirectCaptureObservation()
        RinkLensProgrammeStreamCaptureRequirement.shared.setRequested(false)
        let previous = runtimeState
        runtimeState = .idle
        elapsedRuntime.acknowledgeStopped()
        logRuntimeTransition(from: previous, to: runtimeState, event: "runtime_reset", reason: "Operator reset local stream status")
        healthLevel = .info
        reconnectAvailable = false
        lastActionText = "Ready. Configure an RTMPS destination, then publish the RinkLens programme output."
        broadcastStatusText = "Not broadcasting."
        connectionStatusText = "Disconnected"
        healthMessageText = "No stream flow active."
        lastErrorText = ""
        lastRecoveryText = ""
        lastVideoBufferCount = 0
        lastAppAudioBufferCount = 0
        lastMicAudioBufferCount = 0
        appliedVideoBitrate = 0
        requestedVideoCodec = "No request"
        resolvedVideoCodec = "Not resolved"
        appliedVideoCodec = "Not configured"
        lastTransportBytesOutPerSecond = 0
        hlsMediaContinuityHealthy = false
        activeIngestProtocol = .rtmps
        reconnectCount = 0
        missingConfigurationWarnings = []
    }

    private func acceptDirectConnected(generation: UUID) {
        guard streamGeneration == generation, directPublisher != nil else { return }
        let previous = runtimeState
        runtimeState = .connected
        logRuntimeTransition(
            from: previous,
            to: runtimeState,
            event: activeIngestProtocol == .hls ? "hls_transport_prepared" : "direct_transport_connected",
            reason: activeIngestProtocol == .hls
                ? "HLS encoder, MPEG-2 TS muxer and HTTPS uploader are prepared; no segment is acknowledged yet"
                : "RTMPS server accepted the publisher socket; active media delivery is not yet acknowledged"
        )
        healthLevel = .info
        reconnectAvailable = false
        connectionStatusText = activeIngestProtocol == .hls ? "HLS prepared" : "Connected"
        broadcastStatusText = activeIngestProtocol == .hls ? "HLS prepared; verifying YouTube segment delivery." : "RTMPS connected; verifying programme delivery."
        healthMessageText = activeIngestProtocol == .hls
            ? "Waiting for encoded video, AAC audio and an HTTP-acknowledged MPEG-2 TS segment before reporting Programme Live."
            : "Waiting for encoded video, AAC audio and positive transport bytes before reporting Programme Live."
        lastErrorText = ""
        recordStartupMilestone(
            "transportReady",
            event: "stream_start_transport_ready",
            generation: generation
        )
        evaluateActivePublishingAcknowledgement(generation: generation)
    }

    private func evaluateActivePublishingAcknowledgement(generation: UUID) {
        guard streamGeneration == generation,
              runtimeState == .connected,
              lastVideoBufferCount >= 30,
              lastMicAudioBufferCount > 0,
              lastTransportBytesOutPerSecond > 0,
              activeIngestProtocol != .hls || hlsMediaContinuityHealthy else { return }
        let previous = runtimeState
        runtimeState = .publishing
        elapsedRuntime.acknowledgeRunning(atUptime: ProcessInfo.processInfo.systemUptime)
        logRuntimeTransition(
            from: previous,
            to: runtimeState,
            event: "direct_publish_acknowledged",
            reason: activeIngestProtocol == .hls
                ? "Encoded video, AAC audio and a YouTube-acknowledged HLS media segment were physically observed"
                : "Encoded video, AAC audio and positive RTMPS transport bytes were physically observed"
        )
        recordStartupMilestone(
            "publishingAcknowledged",
            event: "stream_start_publishing_acknowledged",
            generation: generation
        )
        healthLevel = .good
        connectionStatusText = "Publishing"
        broadcastStatusText = "RinkLens programme output is live."
        healthMessageText = "Camera, scorebug, sponsors and match overlays are being published directly by RinkLens."
    }

    private func acceptMediaContinuity(_ healthy: Bool, detail: String, generation: UUID) {
        guard streamGeneration == generation, activeIngestProtocol == .hls else { return }
        hlsMediaContinuityHealthy = healthy
        if healthy {
            evaluateActivePublishingAcknowledgement(generation: generation)
            return
        }
        healthLevel = .warning
        connectionStatusText = "Media timing unstable"
        broadcastStatusText = "YouTube is receiving data, but the programme timeline is not yet stable."
        healthMessageText = detail
        if runtimeState == .publishing {
            let previous = runtimeState
            runtimeState = .connected
            logRuntimeTransition(
                from: previous,
                to: runtimeState,
                event: "hls_media_continuity_lost",
                reason: detail
            )
        }
    }

    private func acceptDirectStopped(generation: UUID) {
        guard streamGeneration == generation else { return }
        let previous = runtimeState
        runtimeState = .stopped
        elapsedRuntime.acknowledgeStopped()
        logRuntimeTransition(from: previous, to: runtimeState, event: "direct_publish_stopped", reason: "In-app publisher closed")
        healthLevel = .info
        reconnectAvailable = true
        connectionStatusText = "Publisher closed"
        broadcastStatusText = "RinkLens programme stream stopped."
        healthMessageText = activeIngestProtocol == .hls
            ? "The final HLS playlist was acknowledged. YouTube may remain visible briefly while finalising the event."
            : "The RTMPS connection is closed. A YouTube event can remain visible briefly while YouTube finalises it."
        directPublisher = nil
        stopDirectOverlayRefresh()
        stopDirectCaptureObservation()
        RinkLensProgrammeStreamCaptureRequirement.shared.setRequested(false)
    }

    private func acceptDirectFailure(_ message: String, generation: UUID) {
        guard streamGeneration == generation else { return }
        directPublisher = nil
        stopDirectOverlayRefresh()
        stopDirectCaptureObservation()
        RinkLensProgrammeStreamCaptureRequirement.shared.setRequested(false)
        setFailed(status: "Live stream failed.", error: message, connectionStatus: "Failed")
    }

    private func setFailed(status: String, error: String, connectionStatus: String) {
        let previous = runtimeState
        runtimeState = .failed
        elapsedRuntime.acknowledgeStopped()
        logRuntimeTransition(from: previous, to: runtimeState, event: "stream_failed", reason: error)
        healthLevel = .failed
        reconnectAvailable = true
        lastActionText = status
        broadcastStatusText = status
        self.connectionStatusText = connectionStatus
        healthMessageText = error
        lastErrorText = error
        stopDirectCaptureObservation()
        RinkLensProgrammeStreamCaptureRequirement.shared.setRequested(false)
    }

    private func recordStartupMilestone(
        _ milestone: String,
        event: String,
        generation: UUID,
        extra: [String: String] = [:]
    ) {
        guard streamGeneration == generation,
              !recordedStartupMilestones.contains(milestone),
              let started = directStartRequestedUptime else { return }
        recordedStartupMilestones.insert(milestone)
        var next = extra
        next["milestone"] = milestone
        next["elapsedMs"] = String(format: "%.0f", max(0, ProcessInfo.processInfo.systemUptime - started) * 1_000)
        RinkLensStructuredEventLogger.shared.record(
            domain: .streaming,
            event: event,
            entityID: "runtime",
            previous: ["state": "startRequested"],
            next: next,
            source: "StreamControlStore",
            reason: "Monotonic programme-stream startup boundary acknowledged"
        )
    }

    private func installDirectCaptureObservation(
        generation: UUID,
        uiState: ExternalOCRMultiCamUIState
    ) {
        directCaptureObservation?.cancel()
        directCaptureObservation = uiState.$snapshot
            .removeDuplicates()
            .sink { [weak self] snapshot in
                self?.evaluateProgrammeVideoSource(snapshot, generation: generation)
            }
    }

    private func stopDirectCaptureObservation() {
        directCaptureObservation?.cancel()
        directCaptureObservation = nil
        directCaptureBindingChangedUptime = nil
        directVideoSourceWarningKey = nil
    }

    /// Follow only a physically acknowledged CaptureEngine running generation.
    /// The publisher session remains alive; only its strict frame admission
    /// binding moves to the verified Broadcast device/generation.
    private func evaluateProgrammeVideoSource(
        _ capture: RinkLensCaptureEngineSnapshot,
        generation: UUID
    ) {
        guard streamGeneration == generation,
              requestedStateActive,
              let publisher = directPublisher,
              let before = publisher.videoSourceEvidence() else { return }

        let modeContainsSource = before.sourceRole == .broadcast
            ? capture.activeMode.requiresBroadcast
            : capture.activeMode.requiresOCR
        let currentDevice = before.sourceRole == .broadcast ? capture.liveDeviceID : capture.ocrDeviceID
        let frameHub = RinkLensFrameHub.shared.diagnosticSnapshot()
        let branchEvidence = before.sourceRole == .broadcast ? frameHub.broadcast : frameHub.ocr
        let branchFresh = branchEvidence.sequence > 0
            && (branchEvidence.ageSeconds ?? .infinity) <= 2.5
            && branchEvidence.captureGeneration == capture.transitionGeneration
            && branchEvidence.physicalDeviceID == currentDevice
        guard capture.sessionRunning,
              modeContainsSource,
              let currentDevice,
              branchFresh else {
            healthLevel = .warning
            connectionStatusText = "Video source unavailable"
            healthMessageText = "The programme publisher is retained while the selected CaptureEngine branch has no fresh verified frame."
            return
        }

        let bindingChanged = before.boundGeneration != capture.transitionGeneration
            || before.boundPhysicalDeviceID != currentDevice
        if bindingChanged {
            directCaptureBindingChangedUptime = ProcessInfo.processInfo.systemUptime
            directVideoSourceWarningKey = nil
            publisher.rebindCapture(
                generation: capture.transitionGeneration,
                physicalDeviceID: currentDevice,
                reason: "CaptureEngine acknowledged running \(capture.activeMode.rawValue) generation \(capture.transitionGeneration)"
            )
            connectionStatusText = "Video source rebinding"
            healthLevel = .info
            healthMessageText = "The existing publisher is waiting for its first verified frame from CaptureEngine generation \(capture.transitionGeneration)."
        }

        guard let evidence = publisher.videoSourceEvidence() else { return }
        let acceptedCurrentBinding = evidence.lastAcceptedGeneration == evidence.boundGeneration
            && evidence.lastAcceptedPhysicalDeviceID == evidence.boundPhysicalDeviceID
        if acceptedCurrentBinding,
           let age = evidence.lastAcceptedFrameAgeSeconds,
           age <= 2.5 {
            directCaptureBindingChangedUptime = nil
            if let warningKey = directVideoSourceWarningKey {
                RinkLensStructuredEventLogger.shared.record(
                    domain: .streaming,
                    event: "programme_stream_video_source_recovered",
                    entityID: evidence.sourceRole.rawValue,
                    previous: ["warning": warningKey],
                    next: [
                        "boundGeneration": String(evidence.boundGeneration),
                        "boundDevice": evidence.boundPhysicalDeviceID ?? "none",
                        "lastAcceptedSequence": evidence.lastAcceptedSequence.map(String.init) ?? "none",
                        "lastFrameAgeMs": String(format: "%.0f", age * 1_000)
                    ],
                    source: "StreamControlStore",
                    reason: "Fresh programme video arrived from the authoritative capture binding"
                )
                directVideoSourceWarningKey = nil
            }
            if runtimeState == .publishing {
                healthLevel = .good
                connectionStatusText = "Publishing"
                healthMessageText = "Camera, scorebug, sponsors and match overlays are being published directly by RinkLens."
            }
            return
        }

        let waitingAge = directCaptureBindingChangedUptime.map {
            max(0, ProcessInfo.processInfo.systemUptime - $0)
        } ?? evidence.lastAcceptedFrameAgeSeconds ?? 0
        guard waitingAge > 2.5,
              lastMicAudioBufferCount > 0 || lastTransportBytesOutPerSecond > 0 else { return }
        let warningKey = "\(evidence.boundGeneration)|\(evidence.boundPhysicalDeviceID ?? "none")|\(evidence.rejectedGenerationCount)|\(evidence.rejectedDeviceCount)"
        guard directVideoSourceWarningKey != warningKey else { return }
        directVideoSourceWarningKey = warningKey
        healthLevel = .warning
        connectionStatusText = "Video source stale"
        healthMessageText = "Audio or transport remains active, but no fresh programme video has been accepted from the verified CaptureEngine binding."
        RinkLensStructuredEventLogger.shared.record(
            domain: .streaming,
            event: "programme_stream_video_source_stale",
            entityID: evidence.sourceRole.rawValue,
            previous: [
                "boundGeneration": String(evidence.boundGeneration),
                "boundDevice": evidence.boundPhysicalDeviceID ?? "none",
                "lastAcceptedGeneration": evidence.lastAcceptedGeneration.map(String.init) ?? "none",
                "lastAcceptedDevice": evidence.lastAcceptedPhysicalDeviceID ?? "none"
            ],
            next: [
                "currentGeneration": String(capture.transitionGeneration),
                "currentDevice": currentDevice,
                "lastAcceptedSequence": evidence.lastAcceptedSequence.map(String.init) ?? "none",
                "lastFrameAgeMs": evidence.lastAcceptedFrameAgeSeconds.map { String(format: "%.0f", $0 * 1_000) } ?? "none",
                "rejectedGeneration": String(evidence.rejectedGenerationCount),
                "rejectedDevice": String(evidence.rejectedDeviceCount),
                "audioBuffers": String(lastMicAudioBufferCount),
                "transportBytes": String(lastTransportBytesOutPerSecond)
            ],
            source: "StreamControlStore",
            reason: "Programme video admission is stale while non-video transport evidence continues"
        )
    }

    private func stopDirectOverlayRefresh() {
        directOverlayObservation?.cancel()
        directOverlayObservation = nil
        lastDirectOverlayRevision = nil
        directOverlayRefreshInFlight = false
        directOverlayRefreshPending = false
        directOverlayRefreshGeneration = nil
    }

    /// Observe only authoritative, physically acknowledged overlay owners. The
    /// stream no longer polls SwiftUI every 250ms when no viewer pixel changed.
    private func installDirectOverlayObservation(
        generation: UUID,
        outputSize: CGSize,
        publisher: any RinkLensProgrammePublisher,
        viewModel: HockeyScoreboardViewModel
    ) {
        directOverlayObservation?.cancel()
        directOverlayObservation = Publishers.CombineLatest3(
            viewModel.broadcastOverlayState.$snapshot.removeDuplicates(),
            BroadcastScoreboardLayoutSettings.shared.$snapshot.removeDuplicates(),
            SponsorCatalogueStore.shared.$recordingOverlayRevision.removeDuplicates()
        )
        .sink { [weak self, weak viewModel] _, _, _ in
            guard let self, let viewModel else { return }
            self.requestDirectOverlayRefresh(
                generation: generation,
                outputSize: outputSize,
                publisher: publisher,
                viewModel: viewModel
            )
        }
    }

    private func directOverlayRevision(viewModel: HockeyScoreboardViewModel) -> DirectOverlayRevision {
        let overlay = viewModel.broadcastOverlayState.snapshot
        let layout = BroadcastScoreboardLayoutSettings.shared.snapshot
        func imageIdentity(_ image: UIImage?) -> String {
            guard let image else { return "nil" }
            return "\(ObjectIdentifier(image).hashValue):\(Int(image.size.width))x\(Int(image.size.height))"
        }
        return DirectOverlayRevision(
            structural: .init(
                layoutIdentity: layout.overlayCacheKey,
                homeLogoIdentity: imageIdentity(viewModel.homeLogoImage),
                awayLogoIdentity: imageIdentity(viewModel.awayLogoImage),
                sponsorIdentity: String(SponsorCatalogueStore.shared.recordingOverlayRevision),
                isVisible: layout.isVisible
            ),
            scoreboardState: overlay.viewerScoreboard.state,
            relayMaterialIdentity: overlay.viewerScoreboard.materialRenderIdentity,
            feedFresh: overlay.viewerScoreboard.relay.isFresh,
            modeStatusText: viewModel.operatingModeStatusText,
            strengthState: viewModel.currentStrengthState,
            activeBanner: viewModel.activeBroadcastBanner,
            homeLogo: viewModel.homeLogoImage,
            awayLogo: viewModel.awayLogoImage,
            layout: layout,
            sponsorRevision: SponsorCatalogueStore.shared.recordingOverlayRevision
        )
    }

    /// One active plus one replaceable pending canonical render. The material
    /// owner revision is acknowledged only after complete pixels are produced.
    private func requestDirectOverlayRefresh(
        generation: UUID,
        outputSize: CGSize,
        publisher: any RinkLensProgrammePublisher,
        viewModel: HockeyScoreboardViewModel
    ) {
        guard streamGeneration == generation,
              runtimeState == .publishing || runtimeState == .connected || runtimeState == .connecting else { return }
        let requestedRevision = directOverlayRevision(viewModel: viewModel)
        guard requestedRevision != lastDirectOverlayRevision else { return }
        if directOverlayRefreshInFlight {
            if directOverlayRefreshGeneration == generation {
                directOverlayRefreshPending = true
            }
            return
        }
        directOverlayRefreshInFlight = true
        directOverlayRefreshGeneration = generation
        let structureChanged = RinkLensStreamOverlayInvalidationPolicy.structureChanged(
            previous: lastDirectOverlayRevision?.structural,
            next: requestedRevision.structural
        )
        let completion: @MainActor (CIImage?) -> Void = { [weak self, weak viewModel] overlay in
            guard let self else { return }
            guard RinkLensStreamOverlaySchedulerPolicy.completionOwnsScheduler(
                renderGeneration: generation,
                activeRenderGeneration: self.directOverlayRefreshGeneration,
                streamGeneration: self.streamGeneration
            ) else { return }
            self.directOverlayRefreshInFlight = false
            self.directOverlayRefreshGeneration = nil
            guard self.streamGeneration == generation,
                  self.runtimeState == .publishing || self.runtimeState == .connected || self.runtimeState == .connecting else {
                self.directOverlayRefreshPending = false
                return
            }
            guard let viewModel else {
                self.directOverlayRefreshPending = false
                return
            }
            let currentRevision = self.directOverlayRevision(viewModel: viewModel)
            guard RinkLensStreamOverlayCommitPolicy.admitsCompletedRender(
                renderedStructure: requestedRevision.structural,
                currentStructure: currentRevision.structural
            ) else {
                // Recovery CS / RL-217: rendering is asynchronous even though
                // the material owner is MainActor. Never replace the current
                // complete programme overlay with pixels for a revision that
                // ceased to be authoritative while ImageRenderer/composition
                // was running. Keep the acknowledged image installed and render
                // only the newest immutable owner snapshot next.
                RinkLensStructuredEventLogger.shared.record(
                    domain: .scoreboardPresentation,
                    event: "programme_overlay_stale_render_discarded",
                    entityID: "stream-scorebug",
                    previous: ["state": "rendered-obsolete"],
                    next: ["state": "previous-complete-retained"],
                    source: "StreamControlStore",
                    reason: "Structural overlay identity changed before background render acknowledgement"
                )
                self.directOverlayRefreshPending = false
                self.requestDirectOverlayRefresh(
                    generation: generation,
                    outputSize: outputSize,
                    publisher: publisher,
                    viewModel: viewModel
                )
                return
            }
            let scorebugRequired = BroadcastScoreboardLayoutSettings.shared.snapshot.isVisible
            if overlay != nil || !scorebugRequired {
                publisher.updateOverlay(overlay)
            }
            // The completed attempt owns this revision even when it retained the
            // previous complete overlay after a nil render. A future material
            // owner change will request fresh pixels; no retry loop is created.
            self.lastDirectOverlayRevision = requestedRevision
            let runPending = self.directOverlayRefreshPending
            self.directOverlayRefreshPending = false
            if runPending || self.directOverlayRevision(viewModel: viewModel) != self.lastDirectOverlayRevision {
                self.requestDirectOverlayRefresh(
                    generation: generation,
                    outputSize: outputSize,
                    publisher: publisher,
                    viewModel: viewModel
                )
            }
        }
        // Recovery DD: startup, structural changes and dynamic ticks use one
        // parity-harnessed layered renderer on its bounded serial queue. The
        // previous SwiftUI ImageRenderer path ran on MainActor, could take 7.5s,
        // and a ticking Clock repeatedly invalidated it before acknowledgement.
        // Structural identity remains explicit for diagnostics/admission, but
        // never chooses a second scorebug implementation.
        if structureChanged {
            RinkLensStructuredEventLogger.shared.record(
                domain: .scoreboardPresentation,
                event: "programme_overlay_structure_changed",
                entityID: "stream-scorebug",
                source: "StreamControlStore",
                reason: "Layout, logo, sponsor or visibility identity changed; one bounded background render admitted"
            )
        }
        BroadcastRecordingStage8PixelBufferFrameProvider.prewarmOverlay(
            viewModel: viewModel,
            outputSize: outputSize,
            completion: completion
        )
    }

    private func logRuntimeTransition(from previous: RuntimeState, to next: RuntimeState, event: String, reason: String) {
        guard previous != next, RinkLensRiskFeaturePolicy.isEnabled(.streamingStructuredTransitionsV2) else { return }
        RinkLensStructuredEventLogger.shared.record(
            domain: .streaming,
            event: event,
            entityID: "runtime",
            previous: ["state": previous.rawValue],
            next: [
                "state": next.rawValue,
                "health": healthLevel.rawValue,
                "requestedCodec": requestedVideoCodec,
                "resolvedCodec": resolvedVideoCodec,
                "appliedCodec": appliedVideoCodec,
                "videoFrames": String(lastVideoBufferCount),
                "audioBuffers": String(lastMicAudioBufferCount),
                "transportBytesOut": String(lastTransportBytesOutPerSecond),
                "ingestProtocol": activeIngestProtocol.rawValue
            ],
            source: "StreamControlStore",
            reason: reason
        )
    }
}
#endif
