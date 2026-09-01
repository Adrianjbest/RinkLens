// BUILD 707 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import UIKit
@preconcurrency import AVFoundation
import Foundation
import Combine
import CoreVideo
import CoreImage
#if canImport(VideoToolbox)
import VideoToolbox
#endif

// MARK: - v0.8.8h Broadcast Recording / Live Clips


// MARK: - UX16d3 recording contracts

nonisolated enum RecordingStopReason: String, Codable, Sendable {
    case operatorRequested = "operator"
    case appBackground = "app background"
    case sourceLoss = "camera source loss"
    case severeCadenceCollapse = "severe cadence collapse"
    case writerFailure = "writer failure"
    case startFailure = "start failure"
    case unknown = "unknown"

    nonisolated init(legacyText: String) {
        self = Self(rawValue: legacyText) ?? .unknown
    }
}

private enum RecordingCaptureLeaseFailureDisposition: Equatable {
    case terminalRecordingStart
    case retryableCameraHandoff
}

@MainActor
final class RecordingEngine: ObservableObject {
    nonisolated static let minimumCustomVideoBitrateMbps = 2
    nonisolated static let maximumCustomVideoBitrateMbps = 50

    /// Temporary source-compatibility bridge for call sites outside UX16d3.
    /// UX16d3a installs the AppContainer-owned authority before constructing the
    /// scoreboard ViewModel. This deliberately does not call AppContainer.shared:
    /// doing so during ViewModel bootstrap recursively entered the container's
    /// static initialiser and trapped from RinkLensLaunchGateView.task.
    private static var installedShared: RecordingEngine?

    static var shared: RecordingEngine {
        guard let engine = installedShared else {
            preconditionFailure("RecordingEngine.shared accessed before AppContainer recording bootstrap")
        }
        return engine
    }

    static func installShared(_ engine: RecordingEngine) {
        if let current = installedShared {
            precondition(current === engine, "A second RecordingEngine authority was installed")
            return
        }
        installedShared = engine
    }

    enum RecordingState: String, Codable {
        case idle = "Idle"
        case starting = "Starting"
        case recording = "Recording"
        case paused = "Paused"
        case stopping = "Stopping"
        case failed = "Failed"
    }

    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var elapsedText: String = "00:00"
    @Published private(set) var currentRecordingURL: URL?
    @Published private(set) var currentSessionFolder: URL?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var lastDebugMessage: String = "Recording idle"
    private(set) var framesWritten: Int = 0
    private(set) var framesDropped: Int = 0
    private(set) var cameraSourceDrops: Int = 0
    private(set) var sourceSamplingMisses: Int = 0
    private(set) var writerDrops: Int = 0
    private(set) var renderDrops: Int = 0
    @Published private(set) var recordingHealthText: String = "Recording idle"
    @Published private(set) var recordingCaptureLeaseText: String = "Recording capture lease inactive"
    @Published private(set) var recordingStopOriginText: String = "none"
    // Build 771: controlled camera/lens handoff is separate from explicit operator pause. The
    // public Recording state and output file remain authoritative while the
    // writer internally holds appends and adopts the verified capture cadence.
    // RecordingEngine owns the recording-side handoff transaction boundary.
    // An explicit operator pause arriving while the writer is held is applied
    // only after that exact handoff completes or aborts.
    private var activeCameraContractHandoffID: UUID?
    private var operatorPausePendingAfterCameraHandoff = false
    // Build 785 R2: RecordingEngine is the sole owner of recording-start admission.
    // A start request remains single-flight until source validation completes.
    private var recordingStartPreflightID: UUID?
    var recordingStartPreflightActive: Bool { recordingStartPreflightID != nil }
    private var pendingRecordingStopReason: RecordingStopReason = .unknown
    private(set) var lastFrameAgeText: String = "--"
    @Published var snapshotClipSeconds: Int = 20
    var recordingSourceText: String = "broadcast composite"
    var recordingRotationText: String = "0°"
    private(set) var recordingBlackFrameCount: Int = 0
    private(set) var recordingBlackFrameDetectedCount: Int = 0
    private(set) var recordingBlackFrameContinuityAcceptedCount: Int = 0
    private(set) var recordingFirstValidFrameText: String = "waiting"
    private(set) var recordingLastWrittenFrameText: String = "--"
    var recordingFrameValidationText: String = "not started"
    @Published var recordingMirrorCorrectionEnabled: Bool = false
    @Published var recordingBroadcastTransformCorrectionDegrees: Int = 0
    var recordingTransformSourceText: String = "broadcast transform follows visible Broadcast rotation"
    var recordingRawFrameCorrectionText: String = "camera source correction: 0°; final buffer preserves broadcast composite"
    private(set) var renderLoopModeText: String = "persistent render loop idle"
    @Published private(set) var recordingProfile = BroadcastRecordingProfile()
    @Published private(set) var customVideoSettingsEnabled: Bool = false
    @Published private(set) var customVideoOutputMode: BroadcastRecordingProfile.OutputMode = .fullHD1080p30
    @Published private(set) var customVideoCodec: BroadcastRecordingProfile.Codec = .h264
    @Published private(set) var customVideoBitrateMbps: Int = 8
    @Published private(set) var customVideoSettingsStatusText: String = "Managed recording defaults active"
    @Published private(set) var recordingCameraSourceText: String = "Waiting for active Broadcast camera"
    @Published private(set) var recordingTargetFPSText: String = "Source"
    @Published private(set) var recordingTargetResolutionText: String = "Source pending"
    @Published private(set) var recordingActualFPSText: String = "--"
    @Published private(set) var recordingSourceActualFPSText: String = "--"
    @Published private(set) var recordingFPSWarningText: String = RecordingEngine.recordingFPSPendingText
    @Published private(set) var recordingCadenceRatioText: String = "--"
    @Published private(set) var recordingPollingFPSText: String = "--"
    @Published private(set) var recordingIngressText: String = "inactive"
    @Published private(set) var recordingFormatWarningText: String?
    @Published private(set) var recordingEncoderBacklogText: String = "0"
    @Published private(set) var manualClipFeedbackText: String = "Clip ready"
    @Published private(set) var manualClipExportStateText: String = "Idle"


    var lastSavedAlbumName: String { mediaRepository.lastSavedAlbumName }
    var lastSavedMediaName: String { mediaRepository.lastSavedMediaName }
    var photoLibraryStatusText: String { mediaRepository.photoLibraryStatusText }
    var photoLibraryAccessDetailText: String { mediaRepository.photoLibraryAccessDetailText }
    var photoPersistenceActivityText: String { mediaRepository.photoPersistenceActivityText }
    var photosOpenHelpText: String { mediaRepository.photosOpenHelpText }
    var savedRecordingsCount: Int { mediaRepository.savedRecordingsCount }
    var savedManualHighlightsCount: Int { mediaRepository.savedManualHighlightsCount }
    var savedAutoHighlightsCount: Int { mediaRepository.savedAutoHighlightsCount }

    // v0.8.8c: Shorter operator-facing album/folder names.
    // Spaces are used so the names look natural in Photos; the app root folder remains unchanged.
    nonisolated static let recordingsAlbumName = MediaRepository.recordingsAlbumName
    nonisolated static let autoHighlightsAlbumName = MediaRepository.autoHighlightsAlbumName
    nonisolated static let manualHighlightsAlbumName = MediaRepository.manualHighlightsAlbumName
    nonisolated static let logsFolderName = MediaRepository.logsFolderName
    private nonisolated static let recordingFPSHealthyText = "FPS healthy"
    private nonisolated static let recordingFPSPendingText = "FPS not sampled yet"
    private nonisolated static let sessionLogPersistenceQueue = DispatchQueue(
        label: "rinklens.recording.session-log",
        qos: .utility
    )

    // Legacy names are retained only for the local in-app browser/search path so older files remain visible.
    nonisolated static let legacyRecordingsAlbumName = MediaRepository.legacyRecordingsAlbumName
    nonisolated static let legacyAutoHighlightsAlbumName = MediaRepository.legacyAutoHighlightsAlbumName
    nonisolated static let legacyManualHighlightsAlbumName = MediaRepository.legacyManualHighlightsAlbumName

    private var recordingStartedAt: Date?
    private var lastFrameAt: Date?
    private var elapsedTimer: Timer?
    private var nominalFPS: Int32 = 30
    private var recordingCadence = RinkLensCaptureCadence(integerFPS: 30)
    private var outputSize = CGSize(width: 1920, height: 1080)
    private var cameraSourceProfile: RecordingCameraSourceProfile?
    private var activeRecordingSourceProfile: RecordingCameraSourceProfile?
    // UX16d3: one authoritative RecordingWriter owns AVAssetWriter and the
    // render/composite/append hot path for the entire recording lifetime.
    // Recovery AP / RL-091: RecordingEngine owns one compression authority;
    // RecordingWriter owns only the current file/mux contract.
    private let recordingCompressionEngine = RecordingCompressionEngine()
    private var recordingWriter: RecordingWriter?
    private enum RecordingWriterCompletionDisposition: Equatable {
        case final
        case ocrRecoveryBoundary(UUID)
    }
    private var recordingWriterCompletionDisposition: RecordingWriterCompletionDisposition = .final
    private struct LogicalWriterContract: @unchecked Sendable {
        let outputSize: CGSize
        let cadence: RinkLensCaptureCadence
        let codec: AVVideoCodecType
        let bitrate: Int
        let frameSource: BroadcastRecordingPixelBufferFrameSourceContext
        let sourceProfile: RecordingCameraSourceProfile
    }
    private var logicalRecordingManifest: RinkLensLogicalRecordingManifest?
    private var logicalRecordingManifestFileURL: URL?
    private var logicalRecordingWriterContract: LogicalWriterContract?
    private var activeRecordingWriterURL: URL?
    private var discardedContinuationWriterURL: URL?
    private var logicalRecordingID: UUID? { logicalRecordingManifest?.logicalRecordingID }
    private var logicalRecordingSegmentURLs: [URL] { logicalRecordingManifest?.segments ?? [] }
    private var ocrRecoveryContinuation: RinkLensOCRRecoveryContinuationMachine?
    private var ocrRecoverySettleTask: Task<Void, Never>?
    private var lastCompletedOCRRecoveryTopologyRevision: UInt64?
    private var lastClosedOCRRecoveryResult: RecordingWriterResult?
    private var ocrRecoveryConvergenceHandler: (@Sendable (RinkLensOCRRecoveryRequirement) async -> RinkLensOCRBranchRecoveryResult)?
    // Recovery AQ / RL-094: RecordingEngine owns the lifetime token for the one
    // CaptureEngine -> RecordingWriter direct physical-frame sink.
    private var recordingCaptureSinkToken: UUID?

    /// Read-only projection of the authoritative recording owner. A route may
    /// hide Broadcast and the writer may be Paused, but as long as this exact
    /// writer/file session remains open presentation code must not treat it as
    /// an idle app and tear down its capture contract.
    var hasRetainedRecordingSession: Bool {
        currentRecordingURL != nil
            && recordingWriter != nil
            && (state == .recording || state == .paused)
    }
    private var backgroundFrameSource: BroadcastRecordingPixelBufferFrameSourceContext?
    private var recordingCaptureLeaseToken: UUID?

    // R15: there is no secondary writer-preparation state. RecordingEngine owns
    // one direct RecordingWriter admission path; encoder priming is a utility
    // cache and never owns a recording file or source contract.
    // Build 738: one RecordingEngine-owned source freshness policy is passed
    // into both the capture lease diagnostic and RecordingWriter configuration.
    private var recordingSourceMaximumAge: TimeInterval { 0.35 }
    private var recordingSourceLossTimeout: TimeInterval {
        RinkLensRiskFeaturePolicy.isEnabled(.recordingBoundedSourceHoldoverV20) ? 2.00 : 0.75
    }
    private var overlaySnapshotProvider: (@MainActor () -> CIImage?)?
    private var overlayRefreshTimer: Timer?
    private var sessionLog: [String] = []
    private var waitingForFirstValidFrame = false
    private var firstValidFrameAt: Date?
    private let clipEngine: ClipEngine
    private let mediaRepository: MediaRepository
    private var mediaChangeCancellable: AnyCancellable?
    private var stoppedClockClipAnchor: Date?
    private var pendingStoppedClockClipTags: Set<String> = []
    private var pendingStoppedClockClipPeriod: Int?
    private var pendingStoppedClockGameClock: String?
    private var lastFrameRenderDurationMS: Double = 0
    private var preparedSessionFolders: SessionFolders?

    /// R17 file/name reservation only. RecordingWriter owns the one prepared
    /// AVAssetWriter contract (URL/size/codec/bitrate) and validates it at REC.
    /// RecordingEngine retains only the operator-facing team identity needed to
    /// decide whether the reserved final filename can still be reused.
    private struct PendingManualPostRollClip {
        let id: UUID
        let pressedAt: Date
        let homeTeam: String
        let awayTeam: String
        let preRollSeconds: Int
        let postRollSeconds: TimeInterval
    }

    private var pendingManualPostRollClips: [UUID: PendingManualPostRollClip] = [:]
    private var lastManualClipButtonPressedAt: Date?
    private let manualClipButtonDebounceSeconds: TimeInterval = 2.5
    private static let recordingCodecDefaultsKey = "rinklens.recording.codec"
    private static let recordingBitrateDefaultsKey = "rinklens.recording.bitrate"
    private static let customVideoSettingsEnabledDefaultsKey = "rinklens.recording.custom.enabled"
    private static let customVideoOutputModeDefaultsKey = "rinklens.recording.custom.outputMode"
    private static let customVideoCodecDefaultsKey = "rinklens.recording.custom.codec"
    private static let customVideoBitrateMbpsDefaultsKey = "rinklens.recording.custom.bitrateMbps"


    init(clipEngine: ClipEngine, mediaRepository: MediaRepository) {
        self.clipEngine = clipEngine
        self.mediaRepository = mediaRepository
        self.mediaChangeCancellable = mediaRepository.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        if let rawCodec = UserDefaults.standard.string(forKey: Self.recordingCodecDefaultsKey),
           let codec = BroadcastRecordingProfile.Codec(rawValue: rawCodec) {
            recordingProfile.codec = codec
        }
        if let rawBitrate = UserDefaults.standard.string(forKey: Self.recordingBitrateDefaultsKey),
           let bitrate = BroadcastRecordingProfile.Bitrate(rawValue: rawBitrate) {
            recordingProfile.bitrate = bitrate
        }
        if RinkLensRiskFeaturePolicy.isEnabled(.customRecordingOutputProfileV15) {
            customVideoSettingsEnabled = UserDefaults.standard.bool(forKey: Self.customVideoSettingsEnabledDefaultsKey)
            if let rawMode = UserDefaults.standard.string(forKey: Self.customVideoOutputModeDefaultsKey),
               let mode = BroadcastRecordingProfile.OutputMode(rawValue: rawMode) {
                customVideoOutputMode = mode
            } else if UserDefaults.standard.string(forKey: Self.customVideoOutputModeDefaultsKey) != nil {
                // Recovery CY / RL-163: retired or unknown high-resolution modes
                // normalize to 1080p30 before the recording owner projects policy.
                customVideoOutputMode = .fullHD1080p30
                UserDefaults.standard.set(customVideoOutputMode.rawValue, forKey: Self.customVideoOutputModeDefaultsKey)
            }
            let preferredDefaultCodec: BroadcastRecordingProfile.Codec = supportsHEVCRecording ? .h265 : .h264
            if let rawCodec = UserDefaults.standard.string(forKey: Self.customVideoCodecDefaultsKey),
               let codec = BroadcastRecordingProfile.Codec(rawValue: rawCodec) {
                customVideoCodec = codec == .h265 && !supportsHEVCRecording ? .h264 : codec
            } else {
                customVideoCodec = preferredDefaultCodec
            }
            if UserDefaults.standard.object(forKey: Self.customVideoBitrateMbpsDefaultsKey) != nil {
                let storedBitrate = UserDefaults.standard.integer(forKey: Self.customVideoBitrateMbpsDefaultsKey)
                customVideoBitrateMbps = min(max(storedBitrate, Self.minimumCustomVideoBitrateMbps), Self.maximumCustomVideoBitrateMbps)
                if customVideoBitrateMbps != storedBitrate {
                    UserDefaults.standard.set(customVideoBitrateMbps, forKey: Self.customVideoBitrateMbpsDefaultsKey)
                }
            }
            applyCustomVideoPolicyProjection(reason: "recording owner startup")
        }
        applyRecordingProfile()
        clipEngine.performRecoveryCleanup()
        // Prepare recording directories off-main during normal app startup so
        // the first REC press does not perform directory discovery/creation on
        // the UI actor.
        Task { [weak self] in
            guard let self else { return }
            if let folders = try? await Self.prepareSessionFoldersOffMain() {
                self.preparedSessionFolders = folders
                MainThreadStallMonitor.shared.traceRecordingWriterEvent("Build 659 recording folders prewarmed off-main")
            }
        }
        Task { [weak self] in
            guard let self else { return }
            let recovered = await Self.discoverInterruptedLogicalRecordingsOffMain()
            guard !recovered.isEmpty else { return }
            var segmentCount = 0
            for entry in recovered {
                for segment in entry.existingSegments {
                    segmentCount += 1
                    self.mediaRepository.noteLocalMediaSaved(
                        url: segment,
                        albumName: Self.recordingsAlbumName
                    )
                }
            }
            if segmentCount > 0, self.state == .idle {
                self.recordingHealthText = "Recovered \(segmentCount) recording segment\(segmentCount == 1 ? "" : "s") in RinkLens Files"
                MainThreadStallMonitor.shared.traceRecordingWriterEvent(
                    "Build 136 discovered \(recovered.count) interrupted logical recording manifest(s) with \(segmentCount) segment(s)"
                )
            }
        }
    }

    // v0.8.8l: unified recording transform. The frame renderer now treats the
    // cached camera frame as the source image and applies only the same visible
    // Broadcast rotation used by the operator preview. The old fixed 180° source
    // correction was removed because it made the rink/video layer upside down
    // while the scoreboard layer stayed correct.
    private nonisolated static let rawRecordingFrameToBroadcastDegrees: Double = 0.0

    var isRecording: Bool { state == .recording }
    var isPaused: Bool { state == .paused }
    var canStart: Bool {
        (state == .idle || state == .failed) && recordingStartPreflightID == nil
    }
    var canPause: Bool { state == .recording }
    var canResume: Bool { state == .paused }
    var canStop: Bool {
        recordingStartPreflightID != nil
            || state == .starting
            || state == .recording
            || state == .paused
    }

    /// Cached writer-level capability probe. This uses the same AVAssetWriter
    /// boundary as the production recorder instead of relying on a VideoToolbox
    /// symbol that is not imported by every Apple SDK configuration.
    private static let cachedSupportsHEVCRecording: Bool = {
        guard #available(iOS 11.0, *) else { return false }

        let probeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rinklens_hevc_probe_\(UUID().uuidString)")
            .appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: probeURL) }

        guard let writer = try? AVAssetWriter(outputURL: probeURL, fileType: .mov) else {
            return false
        }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: 1280,
            AVVideoHeightKey: 720,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000
            ]
        ]
        return writer.canApply(outputSettings: settings, forMediaType: .video)
    }()

    var supportsHEVCRecording: Bool {
        Self.cachedSupportsHEVCRecording
    }

    var availableCustomVideoCodecs: [BroadcastRecordingProfile.Codec] {
        supportsHEVCRecording ? [.h265, .h264] : [.h264]
    }

    var activeRecordingOutputMode: BroadcastRecordingProfile.OutputMode {
        customVideoSettingsEnabled ? customVideoOutputMode : .fullHD1080p30
    }

    var activeRecordingCodec: BroadcastRecordingProfile.Codec {
        guard customVideoSettingsEnabled else { return .h264 }
        return customVideoCodec == .h265 && !supportsHEVCRecording ? .h264 : customVideoCodec
    }

    var activeVideoBitrateMbps: Int {
        customVideoSettingsEnabled ? customVideoBitrateMbps : 8
    }

    var activeVideoBitrateBitsPerSecond: Int {
        activeVideoBitrateMbps * 1_000_000
    }

    var estimatedRecordingMegabytesPerMinute: Int {
        Int((Double(activeVideoBitrateMbps) * 60.0 / 8.0).rounded())
    }

    var recordingOutputPolicySummaryText: String {
        if customVideoSettingsEnabled {
            return "Master picture dimensions and cadence / \(activeRecordingCodec.rawValue) / \(activeVideoBitrateMbps) Mbps"
        }
        return "Current camera native format / H.264 / 8 Mbps"
    }
    var shouldShowRecordingFPSWarning: Bool {
        recordingFPSWarningText != Self.recordingFPSHealthyText && recordingFPSWarningText != Self.recordingFPSPendingText
    }
    var currentTargetFPSValue: Int { Int(nominalFPS) }
    var recordingOutputSize: CGSize { outputSize }

    @discardableResult
    func beginRecordingStartPreflight(source: String) -> UUID? {
        guard canStart else {
            RinkLensStructuredEventLogger.shared.record(
                domain: .recording,
                event: "recording_start_request_suppressed",
                entityID: recordingStartPreflightID?.uuidString,
                previous: ["state": state.rawValue],
                next: ["accepted": "false"],
                source: source,
                reason: recordingStartPreflightID == nil
                    ? "Recording state does not admit another start"
                    : "Recording start preflight is already in flight",
                authoritativeOwner: "RecordingEngine"
            )
            return nil
        }
        let transactionID = UUID()
        recordingStartPreflightID = transactionID
        lastErrorMessage = nil
        recordingHealthText = "Starting — waiting for Broadcast camera"
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "recording_start_preflight_began",
            entityID: transactionID.uuidString,
            previous: ["state": state.rawValue, "preflight": "none"],
            next: ["state": state.rawValue, "preflight": "active"],
            source: source,
            reason: "Operator requested one authoritative asynchronous recording start",
            authoritativeOwner: "RecordingEngine"
        )
        return transactionID
    }

    func ownsRecordingStartPreflight(_ transactionID: UUID) -> Bool {
        recordingStartPreflightID == transactionID
    }

    @discardableResult
    func cancelRecordingStartPreflight(source: String) -> Bool {
        guard let transactionID = recordingStartPreflightID else { return false }
        recordingStartPreflightID = nil
        recordingHealthText = "Ready"
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "recording_start_preflight_cancelled",
            entityID: transactionID.uuidString,
            previous: ["preflight": "active", "state": state.rawValue],
            next: ["preflight": "none", "state": state.rawValue],
            source: source,
            reason: "Operator cancelled the pending recording intent; capture route ownership is unchanged",
            authoritativeOwner: "RecordingEngine"
        )
        return true
    }

    @discardableResult
    func completeRecordingStartPreflight(
        transactionID: UUID,
        accepted: Bool,
        reason: String
    ) -> Bool {
        guard recordingStartPreflightID == transactionID else {
            RinkLensStructuredEventLogger.shared.record(
                domain: .recording,
                event: "recording_start_preflight_stale_completion",
                entityID: transactionID.uuidString,
                previous: ["activeTransaction": recordingStartPreflightID?.uuidString ?? "none"],
                next: ["accepted": "false"],
                source: "RecordingEngine.completeRecordingStartPreflight",
                reason: reason,
                authoritativeOwner: "RecordingEngine"
            )
            return false
        }
        recordingStartPreflightID = nil
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "recording_start_preflight_completed",
            entityID: transactionID.uuidString,
            previous: ["preflight": "active"],
            next: ["preflight": "none", "accepted": String(accepted)],
            source: "RecordingEngine.completeRecordingStartPreflight",
            reason: reason,
            authoritativeOwner: "RecordingEngine"
        )
        return true
    }


    private func transition(to next: RecordingState, reason: String) {
        guard state != next else { return }
        let allowed: Set<RecordingState>
        switch state {
        case .idle: allowed = [.starting, .failed]
        case .starting: allowed = [.recording, .stopping, .failed]
        case .recording: allowed = [.paused, .stopping, .failed]
        case .paused: allowed = [.recording, .stopping, .failed]
        case .stopping: allowed = [.idle, .failed]
        case .failed: allowed = [.starting, .idle]
        }
        guard allowed.contains(next) else {
            let message = "Rejected recording transition \(state.rawValue) -> \(next.rawValue): \(reason)"
            lastErrorMessage = message
            MainThreadStallMonitor.shared.traceRecordingWriterEvent(message)
            return
        }
        let previous = state
        MainThreadStallMonitor.shared.traceRecordingWriterEvent(
            "RecordingEngine transition \(previous.rawValue) -> \(next.rawValue): \(reason)"
        )
        state = next
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "recording_state_transition",
            entityID: currentRecordingURL?.lastPathComponent,
            previous: ["state": previous.rawValue],
            next: ["state": next.rawValue],
            source: "BroadcastRecordingManager",
            reason: reason
        )
    }

    private func prepareWriterAndStart(
        homeTeam: String,
        awayTeam: String,
        resolvedRecordingBaseName: String?,
        frameSource: BroadcastRecordingPixelBufferFrameSourceContext,
        overlaySnapshotProvider: (@MainActor () -> CIImage?)?
    ) {
        guard let source = activeRecordingSourceProfile else {
            blockRecordingStartForCameraFormat(.invalid(
                requested: "Active Broadcast camera source",
                active: "unresolved",
                reason: "Recording blocked because the immutable camera source was unavailable before writer admission."
            ))
            return
        }

        if state != .starting {
            transition(to: .starting, reason: "direct background writer admission requested")
        }
        recordingHealthText = "Starting — opening dedicated VideoToolbox encoder and passthrough file muxer"
        renderLoopModeText = "Recovery AP VideoToolbox compression + AVAssetWriter passthrough muxer"
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "recording_writer_start_path_selected",
            entityID: source.physicalDeviceID,
            previous: ["path": "R11/R12 comparison path removed"],
            next: [
                "path": "Recovery AP dedicated RecordingCompressionEngine + passthrough RecordingWriter",
                "speculativeWriterPrearm": "removed",
                "fileWriterCompression": "none"
            ],
            source: "RecordingEngine.prepareWriterAndStart",
            reason: "Recovery AP removes AVAssetWriter encoder ownership after physical writer-start stalls reached 12.76s",
            captureGeneration: source.captureGeneration,
            authoritativeOwner: "RecordingEngine"
        )
        admitRecordingWriterStart(
            homeTeam: homeTeam,
            awayTeam: awayTeam,
            resolvedRecordingBaseName: resolvedRecordingBaseName,
            frameSource: frameSource,
            overlaySnapshotProvider: overlaySnapshotProvider,
            reason: "R17 single final writer admission"
        )
    }

    /// One RecordingEngine-owned admission boundary. It validates the immutable
    /// source contract, acquires the capture lease and starts the sole
    /// RecordingWriter. No throwaway writer or rollback preparation path exists.
    private func admitRecordingWriterStart(
        homeTeam: String,
        awayTeam: String,
        resolvedRecordingBaseName: String?,
        frameSource: BroadcastRecordingPixelBufferFrameSourceContext,
        overlaySnapshotProvider: (@MainActor () -> CIImage?)?,
        reason: String
    ) {
        guard state == .starting else { return }
        guard let source = activeRecordingSourceProfile,
              source.captureGeneration == frameSource.requiredCaptureGeneration,
              source.physicalDeviceID == frameSource.requiredPhysicalDeviceID else {
            lastErrorMessage = "Recording source changed before authoritative writer admission."
            recordingHealthText = "Failed — Broadcast source changed during recording start"
            transition(to: .failed, reason: "recording source changed before writer admission")
            return
        }
        guard acquireRecordingCaptureLease(frameSource: frameSource) else { return }
        clipEngine.requestRecordingPriority(
            reason: "RecordingEngine acquired the recording capture lease for direct writer admission"
        )
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "recording_writer_direct_start_admitted",
            entityID: currentRecordingURL?.lastPathComponent,
            previous: [
                "state": state.rawValue,
                "preparedKey": "removed"
            ],
            next: [
                "writerStart": "queued",
                "captureLease": "active",
                "path": "R15 unconditional direct RecordingWriter serial start"
            ],
            source: "RecordingEngine.admitRecordingWriterStart",
            reason: reason,
            captureGeneration: source.captureGeneration,
            authoritativeOwner: "RecordingEngine"
        )
        startBackgroundRecording(
            homeTeam: homeTeam,
            awayTeam: awayTeam,
            resolvedRecordingBaseName: resolvedRecordingBaseName,
            frameSource: frameSource,
            overlaySnapshotProvider: overlaySnapshotProvider
        )
    }

    func startRecording(
        homeTeam: String,
        awayTeam: String,
        resolvedRecordingBaseName: String? = nil,
        pixelBufferFrameSource: BroadcastRecordingPixelBufferFrameSourceContext,
        overlaySnapshotProvider: (@MainActor () -> CIImage?)? = nil
    ) {
        guard canStart else {
            recordDebug("Start ignored; current state=\(state.rawValue)")
            return
        }

        guard let resolvedSource = cameraSourceProfile else {
            blockRecordingStartForCameraFormat(.invalid(
                requested: "Active Broadcast camera source",
                active: "unresolved",
                reason: "Recording blocked because no verified current-generation Broadcast camera source has been supplied."
            ))
            return
        }
        guard resolvedSource.captureGeneration == pixelBufferFrameSource.requiredCaptureGeneration,
              resolvedSource.physicalDeviceID == pixelBufferFrameSource.requiredPhysicalDeviceID else {
            blockRecordingStartForCameraFormat(.invalid(
                requested: resolvedSource.displayText,
                active: "frame-source generation=\(pixelBufferFrameSource.requiredCaptureGeneration) device=\(pixelBufferFrameSource.requiredPhysicalDeviceID ?? "none")",
                reason: "Recording blocked because the frozen camera-source profile does not match the Broadcast frame mailbox."
            ))
            return
        }
        activeRecordingSourceProfile = resolvedSource
        applyRecordingProfile(from: resolvedSource)

        // Build 677 never discovers or creates recording directories on the UI
        // actor. If startup prewarming has not completed, show Starting
        // immediately, finish the folder work on a utility task, then continue
        // through the same authoritative capture-lease/writer path.
        if preparedSessionFolders == nil {
            transition(to: .starting, reason: "recording folder prewarm finishing off-main")
            recordingHealthText = "Starting — preparing recording writer"
            renderLoopModeText = "Build 677 off-main recording preparation"
            Task { [weak self] in
                guard let self else { return }
                do {
                    let folders = try await Self.prepareSessionFoldersOffMain()
                    self.preparedSessionFolders = folders
                    guard self.state == .starting else { return }
                    self.prepareWriterAndStart(
                        homeTeam: homeTeam,
                        awayTeam: awayTeam,
                        resolvedRecordingBaseName: resolvedRecordingBaseName,
                        frameSource: pixelBufferFrameSource,
                        overlaySnapshotProvider: overlaySnapshotProvider
                    )
                } catch {
                    self.lastErrorMessage = error.localizedDescription
                    self.recordingHealthText = "Failed — recording folder preparation"
                    self.transition(to: .failed, reason: "off-main recording folder preparation failed")
                }
            }
            return
        }

        prepareWriterAndStart(
            homeTeam: homeTeam,
            awayTeam: awayTeam,
            resolvedRecordingBaseName: resolvedRecordingBaseName,
            frameSource: pixelBufferFrameSource,
            overlaySnapshotProvider: overlaySnapshotProvider
        )
    }


    // MARK: - UX16c45 recording source lease

    private func acquireRecordingCaptureLease(
        frameSource: BroadcastRecordingPixelBufferFrameSourceContext?,
        failureDisposition: RecordingCaptureLeaseFailureDisposition = .terminalRecordingStart
    ) -> Bool {
        let capture = AppContainer.shared.captureEngine.snapshot
        let sourceRole = frameSource?.sourceRole ?? .broadcast
        let sourceDeviceID = sourceRole == .broadcast ? capture.liveDeviceID : capture.ocrDeviceID
        let expectedGeneration = frameSource?.requiredCaptureGeneration ?? capture.transitionGeneration
        let expectedDeviceID = frameSource?.requiredPhysicalDeviceID ?? sourceDeviceID
        let hasFreshSource: Bool
        if let frameSource {
            hasFreshSource = frameSource.hasFreshFrame(maxAge: recordingSourceMaximumAge)
        } else {
            hasFreshSource = RinkLensFrameHub.shared.hasFreshFrame(
                for: sourceRole,
                maxAge: recordingSourceMaximumAge,
                requiredCaptureGeneration: expectedGeneration,
                requiredPhysicalDeviceID: expectedDeviceID
            )
        }

        guard capture.sessionRunning,
              capture.activeMode.requiresBroadcast,
              capture.transitionGeneration == expectedGeneration,
              sourceDeviceID == expectedDeviceID,
              hasFreshSource,
              let desired = capture.effectiveContract?.desired else {
            let message = "Recording capture lease is waiting for a current-generation fresh Broadcast source."
            if failureDisposition == .terminalRecordingStart {
                lastErrorMessage = message
                transition(to: .failed, reason: "recording completion failed")
                recordingHealthText = "Failed preflight — no fresh Broadcast source"
                recordingCaptureLeaseText = "Recording capture lease not acquired"
            } else {
                recordingHealthText = state == .recording
                    ? "Recording — waiting for the new Broadcast source"
                    : "Paused — waiting for the new Broadcast source"
                recordingCaptureLeaseText = "Recording capture lease handoff waiting"
            }
            recordDebug(message)
            return false
        }

        guard let token = RinkLensRecordingCaptureLease.shared.acquire(
            desiredContract: desired,
            effectiveContract: capture.effectiveContract,
            captureGeneration: capture.transitionGeneration,
            broadcastDeviceID: sourceDeviceID,
            sourceMaximumAge: recordingSourceMaximumAge,
            sourceLossTimeout: recordingSourceLossTimeout,
            reason: failureDisposition == .terminalRecordingStart
                ? "recording start preflight"
                : "recording camera-contract handoff"
        ) else {
            let message = "Recording capture lease could not yet adopt the verified Broadcast contract."
            if failureDisposition == .terminalRecordingStart {
                lastErrorMessage = message
                transition(to: .failed, reason: "recording completion failed")
                recordingHealthText = "Failed preflight — capture lease unavailable"
            } else {
                recordingHealthText = state == .recording
                    ? "Recording — completing camera handoff"
                    : "Paused — completing camera handoff"
            }
            recordingCaptureLeaseText = RinkLensRecordingCaptureLease.shared.snapshot().diagnosticText
            recordDebug(message)
            return false
        }

        recordingCaptureLeaseToken = token
        recordingCaptureLeaseText = RinkLensRecordingCaptureLease.shared.snapshot().diagnosticText
        return true
    }

    private func releaseRecordingCaptureLease(
        reason: String,
        replayRouteAfterRelease: Bool = true
    ) {
        RinkLensRecordingCaptureLease.shared.release(
            token: recordingCaptureLeaseToken,
            reason: reason,
            replayRouteAfterRelease: replayRouteAfterRelease
        )
        recordingCaptureLeaseToken = nil
        recordingCaptureLeaseText = "Recording capture lease inactive — \(reason)"
    }

    /// Recovery B same-file camera contract boundary. RecordingEngine remains the
    /// sole recording owner: the public Recording/Paused state and output URL do
    /// not change. The writer stops append ticks before CaptureEngine replaces
    /// the Broadcast branch, and the capture lease is released without replaying
    /// an older route contract over the operator's zoom request.
    @discardableResult
    func suspendRecordingForCameraContractChange(
        transactionID: UUID,
        targetCadence: RinkLensCaptureCadence,
        reason: String
    ) -> Bool {
        // Recovery Y: an optical writer/capture handoff may begin only from the
        // actively Recording state. A route/operator Paused writer is an immutable
        // boundary until explicit Resume, so stale post-handoff convergence cannot
        // start a second writer/camera transaction while Paused.
        guard state == .recording,
              activeCameraContractHandoffID == nil,
              !operatorPausePendingAfterCameraHandoff,
              let writer = recordingWriter,
              backgroundFrameSource != nil,
              RinkLensRecordingCaptureLease.shared.isWriterContractOpen() else {
            recordDebug("Recovery Y camera-contract handoff rejected: recording writer is not in a handoff-capable state or another handoff/pause owns the boundary")
            return false
        }

        activeCameraContractHandoffID = transactionID
        let previousLease = RinkLensRecordingCaptureLease.shared.snapshot()
        writer.setCameraTransitionHeld(true, transactionID: transactionID)
        RinkLensRecordingCaptureLease.shared.setRecordingActive(
            false,
            reason: "Recovery B controlled camera cadence transaction"
        )
        releaseRecordingCaptureLease(
            reason: "Recovery B camera-contract handoff: \(reason)",
            replayRouteAfterRelease: false
        )
        MainThreadStallMonitor.shared.setRecordingDiagnosticsActive(
            false,
            reason: "Recovery B camera-contract handoff"
        )
        recordingHealthText = state == .recording
            ? "Recording — changing camera at \(targetCadence.displayText)fps"
            : "Paused — changing camera at \(targetCadence.displayText)fps"

        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "recording_camera_contract_handoff_started",
            entityID: transactionID.uuidString,
            previous: [
                "state": state.rawValue,
                "lease": previousLease.diagnosticText,
                "source": activeRecordingSourceProfile?.displayText ?? "none"
            ],
            next: [
                "state": state.rawValue,
                "sameFile": "true",
                "writerHeld": "true",
                "targetFPS": targetCadence.displayText
            ],
            source: "BroadcastRecordingManager",
            reason: reason,
            authoritativeOwner: "BroadcastRecordingManager"
        )
        writeSessionLog(
            event: "recording_camera_contract_handoff_started",
            details: "transaction=\(transactionID.uuidString) targetFPS=\(targetCadence.displayText) state=\(state.rawValue)"
        )
        return true
    }

    /// Rebinds the capacity-one frame source to the physically verified capture
    /// generation, reacquires the capture lease, retargets only the writer pacer,
    /// and then releases the internal append hold. AVAssetWriter and the file stay open.
    @discardableResult
    func restoreRecordingAfterCameraContractChange(
        transactionID: UUID,
        verifiedCadence: RinkLensCaptureCadence,
        captureGeneration: Int,
        physicalDeviceID: String,
        reason: String
    ) async -> Bool {
        guard activeCameraContractHandoffID == transactionID,
              state == .recording,
              let writer = recordingWriter,
              let frameSource = backgroundFrameSource else { return false }

        let capture = AppContainer.shared.captureEngine.snapshot
        guard capture.sessionRunning,
              capture.activeMode.requiresBroadcast,
              capture.transitionGeneration == captureGeneration,
              capture.liveDeviceID == physicalDeviceID,
              let liveFormat = capture.liveFormat else {
            recordingHealthText = state == .recording
                ? "Recording — waiting for verified camera handoff"
                : "Paused — waiting for verified camera handoff"
            return false
        }

        frameSource.rebindCapture(
            generation: captureGeneration,
            physicalDeviceID: physicalDeviceID
        )
        guard frameSource.hasFreshFrame(maxAge: recordingSourceMaximumAge) else {
            recordingHealthText = state == .recording
                ? "Recording — waiting for first frame from new camera"
                : "Paused — waiting for first frame from new camera"
            return false
        }

        if recordingCaptureLeaseToken == nil,
           !acquireRecordingCaptureLease(
                frameSource: frameSource,
                failureDisposition: .retryableCameraHandoff
           ) {
            return false
        }

        let outcome: RecordingCadenceTransitionOutcome = await withCheckedContinuation { continuation in
            writer.applyVerifiedCadenceTransition(
                cadence: verifiedCadence,
                captureGeneration: captureGeneration,
                physicalDeviceID: physicalDeviceID,
                transactionID: transactionID
            ) { outcome in
                continuation.resume(returning: outcome)
            }
        }
        guard outcome.succeeded else {
            recordingHealthText = "Recording camera handoff failed — \(outcome.errorText ?? "writer cadence transition failed")"
            return false
        }

        let verifiedProfile = RecordingCameraSourceProfile(
            width: Int(liveFormat.width),
            height: Int(liveFormat.height),
            cadence: verifiedCadence,
            formatText: liveFormat.diagnosticText,
            physicalDeviceID: physicalDeviceID,
            captureGeneration: captureGeneration
        )
        activeRecordingSourceProfile = verifiedProfile
        cameraSourceProfile = verifiedProfile
        applyRecordingProfile(from: verifiedProfile)
        BroadcastRenderPacerDiagnostics.shared.configure(
            targetFPS: verifiedCadence.nominalFPS,
            source: "UX16d3 RecordingWriter"
        )
        PersistentBroadcastRendererDiagnostics.shared.configure(
            targetFPS: verifiedCadence.nominalFPS,
            mode: "Recovery B same-file camera cadence handoff"
        )
        RinkLensRecordingCaptureLease.shared.setWriterContractOpen(
            true,
            sourceContract: verifiedProfile.displayText,
            reason: "Recovery B verified same-file camera source rebound"
        )
        writer.setCameraTransitionHeld(false, transactionID: transactionID)
        RinkLensRecordingCaptureLease.shared.setRecordingActive(
            state == .recording,
            reason: "Recovery B camera-contract handoff completed"
        )
        MainThreadStallMonitor.shared.setRecordingDiagnosticsActive(
            state == .recording,
            reason: "Recovery B camera-contract handoff completed"
        )
        recordingCaptureLeaseText = RinkLensRecordingCaptureLease.shared.snapshot().diagnosticText
        recordingHealthText = state == .recording
            ? "Recording — camera handoff complete at \(verifiedCadence.displayText)fps"
            : "Paused — camera handoff complete at \(verifiedCadence.displayText)fps"

        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "recording_camera_contract_handoff_completed",
            entityID: physicalDeviceID,
            previous: [
                "transactionID": transactionID.uuidString,
                "sameFile": "true"
            ],
            next: [
                "generation": String(captureGeneration),
                "fps": verifiedCadence.displayText,
                "source": verifiedProfile.displayText,
                "writerHeld": "false",
                "leaseReacquired": String(recordingCaptureLeaseToken != nil)
            ],
            source: "BroadcastRecordingManager",
            reason: reason,
            captureGeneration: captureGeneration,
            authoritativeOwner: "BroadcastRecordingManager"
        )
        writeSessionLog(
            event: "recording_camera_contract_handoff_completed",
            details: "transaction=\(transactionID.uuidString) fps=\(verifiedCadence.displayText) generation=\(captureGeneration) source=\(physicalDeviceID)"
        )
        resolveCameraContractHandoffBoundary(
            transactionID: transactionID,
            outcome: "verified-completion"
        )
        return true
    }

    /// Fail-safe for a CaptureEngine branch transaction that could not be proven.
    /// It never invents a replacement source; it simply releases the matching writer
    /// hold so existing source-loss health logic can remain authoritative.
    func abortRecordingCameraContractChange(transactionID: UUID, reason: String) {
        recordingWriter?.setCameraTransitionHeld(false, transactionID: transactionID)
        RinkLensRecordingCaptureLease.shared.setRecordingActive(
            state == .recording,
            reason: "Recovery B camera-contract handoff aborted: \(reason)"
        )
        MainThreadStallMonitor.shared.setRecordingDiagnosticsActive(
            state == .recording,
            reason: "Recovery B camera-contract handoff aborted"
        )
        recordDebug("Recovery B camera-contract handoff aborted transaction=\(transactionID.uuidString): \(reason)")
        resolveCameraContractHandoffBoundary(
            transactionID: transactionID,
            outcome: "aborted: \(reason)"
        )
    }

    /// Serialises an explicit operator Pause behind an active optical handoff.
    /// Route changes never submit recording lifecycle intent.
    private func deferOperatorPauseIfCameraHandoffActive(source: String) -> Bool {
        guard let transactionID = activeCameraContractHandoffID else { return false }
        operatorPausePendingAfterCameraHandoff = true
        recordingHealthText = "Recording — finishing camera handoff before pause"
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "recording_pause_deferred_for_camera_handoff",
            entityID: transactionID.uuidString,
            previous: [
                "state": state.rawValue,
                "activeHandoff": transactionID.uuidString
            ],
            next: [
                "pendingPause": "operator",
                "writerMutation": "deferred"
            ],
            source: source,
            reason: "Recovery Y serialises pause behind the active recording camera-contract handoff",
            authoritativeOwner: "BroadcastRecordingManager"
        )
        recordDebug("Recovery Y deferred operator pause until camera handoff \(transactionID.uuidString) resolves")
        return true
    }

    private func resolveCameraContractHandoffBoundary(
        transactionID: UUID,
        outcome: String
    ) {
        guard activeCameraContractHandoffID == transactionID else {
            RinkLensStructuredEventLogger.shared.record(
                domain: .recording,
                event: "recording_camera_handoff_stale_boundary_ignored",
                entityID: transactionID.uuidString,
                previous: ["activeHandoff": activeCameraContractHandoffID?.uuidString ?? "none"],
                next: ["outcome": outcome],
                source: "BroadcastRecordingManager.resolveCameraContractHandoffBoundary",
                reason: "Only the active recording camera handoff may release its transaction boundary",
                authoritativeOwner: "BroadcastRecordingManager"
            )
            return
        }

        activeCameraContractHandoffID = nil
        let operatorPausePending = operatorPausePendingAfterCameraHandoff
        operatorPausePendingAfterCameraHandoff = false

        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "recording_camera_handoff_boundary_resolved",
            entityID: transactionID.uuidString,
            previous: [
                "state": state.rawValue,
                "pendingPause": operatorPausePending ? "operator" : "none"
            ],
            next: [
                "activeHandoff": "none",
                "outcome": outcome
            ],
            source: "BroadcastRecordingManager.resolveCameraContractHandoffBoundary",
            reason: "Recovery Y recording-side camera transaction reached one immutable boundary",
            authoritativeOwner: "BroadcastRecordingManager"
        )

        guard operatorPausePending else { return }
        applyOperatorPauseAfterCameraHandoff()
    }

    private func applyOperatorPauseAfterCameraHandoff() {
        guard state == .recording else { return }
        recordingWriter?.setPaused(true, reason: "deferred operator pause after camera handoff")
        transition(to: .paused, reason: "operator pause after camera handoff")
        recordDebug("Recording paused after camera handoff")
        writeSessionLog(event: "recording_paused", details: elapsedText)
        writeDeferredPauseAppliedEvent("operator")
    }

    private func writeDeferredPauseAppliedEvent(_ pause: String) {
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "recording_deferred_pause_applied",
            entityID: currentRecordingURL?.lastPathComponent ?? "active-recording",
            previous: ["cameraHandoff": "resolved"],
            next: ["state": state.rawValue, "pause": pause],
            source: "BroadcastRecordingManager",
            reason: "Recovery Y applies explicit operator pause only after recording camera handoff boundary",
            authoritativeOwner: "BroadcastRecordingManager"
        )
    }

    // MARK: - UX16d3 authoritative recording path

    private func installRecordingCaptureSink(writer: RecordingWriter, role: RinkLensFrameRole) {
        removeRecordingCaptureSink(reason: "replacing recording capture sink")
        let token = AppContainer.shared.captureEngine.installRecordingCaptureSink(role: role) { [weak writer] frame in
            writer?.submitCaptureFrame(frame)
        }
        recordingCaptureSinkToken = token
        recordingPollingFPSText = "capture-driven / recording-owned"
        recordingIngressText = "starting — direct callback copied once into recording-owned pool"
        recordDebug("Recovery AV direct recording callback sink installed role=\(role.rawValue) token=\(token.uuidString.prefix(8))")
    }

    private func removeRecordingCaptureSink(reason: String) {
        guard let token = recordingCaptureSinkToken else { return }
        recordingCaptureSinkToken = nil
        AppContainer.shared.captureEngine.removeRecordingCaptureSink(token: token, reason: reason)
    }

    private func startBackgroundRecording(
        homeTeam: String,
        awayTeam: String,
        resolvedRecordingBaseName: String?,
        frameSource: BroadcastRecordingPixelBufferFrameSourceContext,
        overlaySnapshotProvider: (@MainActor () -> CIImage?)?
    ) {
        let trace = MainThreadStallMonitor.shared.beginTimedOperation("RecordingEngine.start")
        let recordingStartRequestedAt = CFAbsoluteTimeGetCurrent()
        guard let frozenSource = activeRecordingSourceProfile else {
            releaseRecordingCaptureLease(reason: "camera-source profile missing before writer start")
            blockRecordingStartForCameraFormat(.invalid(
                requested: "Active Broadcast camera source",
                active: "unresolved",
                reason: "Recording blocked because the immutable camera-source snapshot was lost before writer start."
            ))
            return
        }
        applyRecordingProfile(from: frozenSource)
        RinkLensRecordingCaptureLease.shared.setWriterContractOpen(
            true,
            sourceContract: frozenSource.displayText,
            reason: "Build 738 immutable writer source contract established before writer start"
        )
        BroadcastRenderPacerDiagnostics.shared.configure(
            targetFPS: Int(nominalFPS),
            source: "UX16d3 RecordingWriter"
        )
        MainThreadStallMonitor.shared.traceRecordingWriterEvent(
            "UX16d3 recording start requested source=\(activeRecordingSourceProfile?.displayText ?? "none") outputSize=\(Int(outputSize.width))x\(Int(outputSize.height)) nativeTargetFPS=\(nominalFPS) codec=\(activeRecordingCodec.rawValue) bitrate=\(activeVideoBitrateMbps)Mbps"
        )

        transition(to: .starting, reason: "recording start requested")
        pendingRecordingStopReason = .unknown
        recordingStopOriginText = "none"
        lastErrorMessage = nil
        framesWritten = 0
        framesDropped = 0
        cameraSourceDrops = 0
        sourceSamplingMisses = 0
        writerDrops = 0
        renderDrops = 0
        recordingHealthText = "Starting — validating fresh Broadcast source"
        recordingBlackFrameCount = 0
        recordingBlackFrameDetectedCount = 0
        recordingBlackFrameContinuityAcceptedCount = 0
        BlackFrameRejectionTraceStore.shared.reset()
        recordingFirstValidFrameText = "waiting for first background-worker frame"
        recordingLastWrittenFrameText = "--"
        recordingFrameValidationText = "background worker preflight"
        recordingStartedAt = nil
        lastFrameAt = nil
        renderLoopModeText = "UX16d3 recording writer configuring"
        recordingActualFPSText = "--"
        recordingSourceActualFPSText = "--"
        recordingCadenceRatioText = "--"
        recordingPollingFPSText = "--"
        recordingIngressText = "inactive"
        recordingEncoderBacklogText = "0"
        BroadcastRecordingSourceCadenceMonitor.shared.reset()
        BroadcastRecordingSourceClockStarvationGuard.shared.reset(reason: "UX16d3 recording start")
        BroadcastRecordingRenderBudgetGuard.shared.reset(reason: "UX16d3 recording start")
        BroadcastRecordingOverlayCache.shared.beginRecordingWithPrewarmedOverlay(reason: "Build 631 retained Broadcast overlay fast start")
        // Keep the already-warm CI overlay. Clearing it here forced the Record
        // button to trigger a full redraw before the first writer frame.
        PersistentBroadcastRendererDiagnostics.shared.configure(
            targetFPS: Int(nominalFPS),
            mode: "UX16d3 recording worker configuring"
        )

        do {
            let folders = try ensureSessionFolders()
            currentSessionFolder = folders.baseFolder
            // Recovery AP / RL-091: there is no speculative file-writer reservation.
            // REC creates one file muxer while the dedicated compression owner handles
            let filename = RinkLensRecordingFilenameResolver.filename(
                resolvedBaseName: resolvedRecordingBaseName,
                fallbackPrefix: "full_game",
                homeTeam: homeTeam,
                awayTeam: awayTeam,
                ext: "mp4"
            )
            let outputURL = folders.staging.appendingPathComponent(filename)
            let worker = RecordingWriter(compressionEngine: recordingCompressionEngine)
            recordingWriter = worker
            currentRecordingURL = outputURL
            activeRecordingWriterURL = outputURL
            logicalRecordingManifestFileURL = outputURL.deletingPathExtension()
                .appendingPathExtension("recording.json")
            let frozenWriterContract = LogicalWriterContract(
                outputSize: outputSize,
                cadence: recordingCadence,
                codec: activeRecordingCodec.avCodec,
                bitrate: activeVideoBitrateBitsPerSecond,
                frameSource: frameSource,
                sourceProfile: frozenSource
            )
            logicalRecordingWriterContract = frozenWriterContract
            logicalRecordingManifest = RinkLensLogicalRecordingManifest(
                logicalRecordingID: UUID(),
                segments: [],
                state: .recording,
                mediaContract: .init(
                    codec: frozenWriterContract.codec.rawValue,
                    width: Int(frozenWriterContract.outputSize.width),
                    height: Int(frozenWriterContract.outputSize.height),
                    cadenceValue: frozenWriterContract.cadence.durationValue,
                    cadenceTimescale: frozenWriterContract.cadence.durationTimescale,
                    bitrate: frozenWriterContract.bitrate,
                    sourceDescription: frozenWriterContract.sourceProfile.displayText,
                    physicalDeviceID: frozenWriterContract.sourceProfile.physicalDeviceID,
                    captureGeneration: frozenWriterContract.sourceProfile.captureGeneration
                )
            )
            persistLogicalRecordingManifest()
            recordingWriterCompletionDisposition = .final
            discardedContinuationWriterURL = nil
            ocrRecoveryContinuation = nil
            ocrRecoverySettleTask?.cancel()
            ocrRecoverySettleTask = nil
            lastCompletedOCRRecoveryTopologyRevision = nil
            lastClosedOCRRecoveryResult = nil

            let guardedClipFPS = BroadcastPixelBufferClipPerformanceGuard.clipFPS(for: nominalFPS)

            backgroundFrameSource = frameSource
            self.overlaySnapshotProvider = overlaySnapshotProvider
            startOverlayRefreshTimer()

            let configuration = RecordingWriterConfiguration(
                outputURL: outputURL,
                outputSize: frozenWriterContract.outputSize,
                cadence: frozenWriterContract.cadence,
                codec: frozenWriterContract.codec,
                bitrate: frozenWriterContract.bitrate,
                frameSource: frozenWriterContract.frameSource,
                clipEngine: clipEngine,
                sourceMaximumAge: recordingSourceMaximumAge,
                minimumHealthyFrameRatio: 0.95
            )
            clipEngine.startCompressedSamples(size: outputSize, fps: guardedClipFPS)
            let callbacks = RecordingWriterCallbacks(
                onStarted: { [weak self] in
                    guard let self else { return }
                    guard self.state == .starting else {
                        let message = "RecordingWriter produced a first frame while RecordingEngine state was \(self.state.rawValue); writer stopped to preserve single-source recording state."
                        self.lastErrorMessage = message
                        self.recordingHealthText = "Failed — writer/state transaction mismatch"
                        self.recordDebug(message)
                        self.recordingWriter?.stop()
                        return
                    }
                    self.recordingStartedAt = Date()
                    let startupMS = max(0, (CFAbsoluteTimeGetCurrent() - recordingStartRequestedAt) * 1_000)
                    self.transition(to: .recording, reason: "RecordingWriter appended first frame")
                    MainThreadStallMonitor.shared.traceRecordingWriterEvent(
                        String(format: "Build 631 recording first frame after %.1fms", startupMS)
                    )
                    RinkLensStructuredEventLogger.shared.record(
                        domain: .recording,
                        event: "recording_first_frame_appended",
                        entityID: outputURL.lastPathComponent,
                        previous: ["state": RecordingState.starting.rawValue, "compression": "VideoToolbox"],
                        next: ["state": RecordingState.recording.rawValue, "startupMs": String(format: "%.1f", startupMS)],
                        source: "RecordingWriter.onStarted",
                        reason: "First VideoToolbox-compressed frame committed by the passthrough file muxer",
                        captureGeneration: frozenSource.captureGeneration,
                        authoritativeOwner: "RecordingEngine"
                    )
                    self.renderLoopModeText = "UX16d3 recording render/writer running at \(self.nominalFPS)fps"
                    self.recordingHealthText = "Healthy startup — monitoring Broadcast source freshness"
                    self.recordingCaptureLeaseText = RinkLensRecordingCaptureLease.shared.snapshot().diagnosticText
                    self.recordingSourceText = frameSource.sourceDescription
                    self.recordingRawFrameCorrectionText = "UX16d3 recording worker; direct CVPixelBuffer + cached overlay"
                    RinkLensRecordingCaptureLease.shared.setRecordingActive(true, reason: "UX16d3 recording started")
                    MainThreadStallMonitor.shared.setRecordingDiagnosticsActive(true, reason: "UX16d3 recording started")
                    self.manualClipExportStateText = "Idle"
                    self.manualClipFeedbackText = "Compressed-sample clip buffer warming up"
                    self.startElapsedTimer()
                    CameraOwnershipTraceStore.record(.recordingStarted, owner: .recording, reason: outputURL.lastPathComponent)
                    self.recordDebug("UX16d3 recording started without MainActor frame ticks")
                    self.writeSessionLog(event: "recording_started_background_worker", details: outputURL.lastPathComponent)
                },
                onProgress: { [weak self] progress in
                    self?.applyBackgroundWorkerProgress(progress)
                },
                onFinished: { [weak self] result in
                    self?.completeWriterSegment(result)
                },
                onFailure: { [weak self] message in
                    guard let self else { return }
                    self.stopTimers()
                    self.clipEngine.stop()
                    self.removeRecordingCaptureSink(reason: "RecordingWriter start/runtime failure")
                    self.recordingWriter = nil
                    self.backgroundFrameSource = nil
                    self.overlaySnapshotProvider = nil
                    self.releaseRecordingCaptureLease(reason: "background writer start/runtime failure")
                    RinkLensRecordingCaptureLease.shared.setRecordingActive(false, reason: "UX16d3 recording failed")
                    RinkLensRecordingCaptureLease.shared.setWriterContractOpen(
                        false,
                        sourceContract: "none",
                        reason: "RecordingWriter start/runtime failure finalised the open writer contract"
                    )
                    MainThreadStallMonitor.shared.setRecordingDiagnosticsActive(false, reason: "UX16d3 recording failed")
                    self.clipEngine.resumeDeferredExportsAfterRecording(reason: "background recording failure finalised")
                    self.lastErrorMessage = message
                    self.transition(to: .failed, reason: "RecordingWriter runtime failure")
                    self.recordingHealthText = "Failed — \(message)"
                    self.renderLoopModeText = "UX16d3 recording writer failed"
                    self.recordDebug("UX16d3 recording failed: \(message)")
                    MainThreadStallMonitor.shared.traceRecordingWriterEvent("UX16d3 start failed error=\(message)")
                }
            )
            worker.start(configuration: configuration, callbacks: callbacks)
            installRecordingCaptureSink(writer: worker, role: frameSource.sourceRole)
        } catch {
            removeRecordingCaptureSink(reason: "recording failed before writer admission")
            recordingWriter = nil
            backgroundFrameSource = nil
            self.overlaySnapshotProvider = nil
            releaseRecordingCaptureLease(reason: "background recording failed to queue")
            RinkLensRecordingCaptureLease.shared.setWriterContractOpen(
                false,
                sourceContract: "none",
                reason: "Recording failed to queue"
            )
            overlayRefreshTimer?.invalidate()
            overlayRefreshTimer = nil
            lastErrorMessage = error.localizedDescription
            transition(to: .failed, reason: "recording completion failed")
            recordDebug("UX16d3 recording failed to queue: \(error.localizedDescription)")
        }

        MainThreadStallMonitor.shared.endTimedOperation("RecordingEngine.start", startedAt: trace)
    }

    private func startOverlayRefreshTimer() {
        overlayRefreshTimer?.invalidate()
        guard backgroundFrameSource != nil, overlaySnapshotProvider != nil else { return }
        // The first complete overlay is already prewarmed. Give the writer and
        // capture queues one second to settle before periodic MainActor snapshot
        // refreshes, then refresh at 2Hz rather than 3.3Hz. This removes the REC
        // button startup hitch without changing event/score update ownership.
        let timer = Timer(fire: Date().addingTimeInterval(1.0), interval: 0.50, repeats: true) { [weak self] _ in
            guard let manager = self else { return }
            Task { @MainActor [manager] in
                guard manager.state == .recording,
                      let frameSource = manager.backgroundFrameSource,
                      let provider = manager.overlaySnapshotProvider else { return }
                frameSource.updateOverlay(provider())
            }
        }
        overlayRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func applyBackgroundWorkerProgress(_ progress: RecordingWriterProgress) {
        framesWritten = progress.framesWritten
        framesDropped = progress.framesDropped
        cameraSourceDrops = progress.cameraSourceDrops
        sourceSamplingMisses = progress.sourceSamplingMisses
        writerDrops = progress.writerDrops
        renderDrops = progress.renderDrops
        recordingHealthText = progress.healthText
        recordingBlackFrameCount = progress.blackFramesRejected
        recordingBlackFrameDetectedCount = progress.blackFramesDetected
        recordingBlackFrameContinuityAcceptedCount = progress.blackFramesContinuityAccepted
        recordingSourceText = progress.sourceDescription
        recordingFrameValidationText = progress.frameValidationText
        BlackFrameRejectionTraceStore.shared.synchroniseBackgroundWorker(
            totalRejected: progress.blackFramesRejected,
            darkObserved: progress.blackFramesDetected,
            darkEncoded: progress.blackFramesContinuityAccepted,
            firstValidFrameSeen: progress.framesWritten > 0,
            lastSummary: progress.frameValidationText,
            source: progress.sourceDescription
        )
        recordingActualFPSText = String(format: "%.1ffps", progress.actualFPS)
        recordingSourceActualFPSText = String(format: "%.1ffps", progress.sourceFPS)
        recordingCadenceRatioText = String(format: "%.1f%%", progress.cadenceRatio * 100)
        recordingPollingFPSText = "capture-driven / recording-owned"
        recordingIngressText = progress.ingressDiagnosticsText
        recordingEncoderBacklogText = "\(progress.writerBacklog)"
        lastFrameRenderDurationMS = progress.renderDurationMS
        renderLoopModeText = "UX16d3 recording worker: \(progress.lastDecision)"
        if let writtenAt = progress.lastWrittenAt {
            lastFrameAt = writtenAt
            recordingLastWrittenFrameText = Self.isoFormatter.string(from: writtenAt)
            if recordingFirstValidFrameText.contains("waiting") {
                firstValidFrameAt = writtenAt
                recordingFirstValidFrameText = Self.isoFormatter.string(from: writtenAt)
            }
        }
        PersistentBroadcastRendererDiagnostics.shared.noteBackgroundWorkerProgress(
            actualFPS: progress.actualFPS,
            renderDurationMS: progress.renderDurationMS,
            source: progress.sourceDescription,
            size: outputSize,
            backlog: progress.writerBacklog,
            decision: progress.lastDecision
        )
        updateRecordingFPSWarning()
    }

    // MARK: - Build 136 recording-safe OCR continuation

    func considerOCRRecovery(_ requirement: RinkLensOCRRecoveryRequirement) {
        if let active = ocrRecoveryContinuation {
            switch active.replacementDisposition(for: requirement.topologyRevision) {
            case .replaceSettlingTransaction:
                ocrRecoverySettleTask?.cancel()
                ocrRecoverySettleTask = nil
                ocrRecoveryContinuation = nil
            case .retainCurrentTransaction, .ignoreDuplicate:
                return
            }
        }
        guard state == .recording,
              recordingWriter != nil,
              RinkLensRecordingCaptureLease.shared.isWriterContractOpen(),
              activeCameraContractHandoffID == nil,
              lastCompletedOCRRecoveryTopologyRevision != requirement.topologyRevision,
              let logicalRecordingID else { return }

        let capture = AppContainer.shared.captureEngine.snapshot
        guard capture.ocrRecoveryRequirement == requirement,
              capture.externalOCRTopology.revision == requirement.topologyRevision,
              capture.externalOCRTopology.deviceID == requirement.deviceID,
              capture.externalOCRTopology.isDiscoverable,
              capture.sessionRunning,
              capture.activeMode.requiresBroadcast else { return }

        let transactionID = UUID()
        ocrRecoveryContinuation = RinkLensOCRRecoveryContinuationMachine(
            transactionID: transactionID,
            logicalRecordingID: logicalRecordingID,
            deviceID: requirement.deviceID,
            topologyRevision: requirement.topologyRevision,
            captureGeneration: requirement.captureGeneration
        )
        recordingHealthText = "Recording — preparing OCR camera recovery"
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "ocr_recovery_rollover_requested",
            entityID: transactionID.uuidString,
            previous: [
                "writerContract": RinkLensRecordingCaptureLease.shared.writerContractDiagnostic(),
                "segmentCount": String(logicalRecordingSegmentURLs.count)
            ],
            next: [
                "logicalRecordingID": logicalRecordingID.uuidString,
                "deviceID": requirement.deviceID,
                "topologyRevision": String(requirement.topologyRevision),
                "settleSeconds": "1.0"
            ],
            source: "RecordingEngine.considerOCRRecovery",
            reason: "External OCR returned while the final writer contract was open",
            captureGeneration: requirement.captureGeneration,
            authoritativeOwner: "RecordingEngine"
        )

        ocrRecoverySettleTask?.cancel()
        ocrRecoverySettleTask = Task.detached { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.completeOCRRecoveryTopologySettle(requirement)
        }
    }

    private func completeOCRRecoveryTopologySettle(_ requirement: RinkLensOCRRecoveryRequirement) {
        ocrRecoverySettleTask = nil
        guard var transaction = ocrRecoveryContinuation,
              transaction.topologyRevision == requirement.topologyRevision else { return }
        let capture = AppContainer.shared.captureEngine.snapshot
        let remainsCurrent = capture.ocrRecoveryRequirement == requirement
            && capture.externalOCRTopology.revision == requirement.topologyRevision
            && capture.externalOCRTopology.deviceID == requirement.deviceID
            && capture.externalOCRTopology.isDiscoverable
            && capture.sessionRunning
            && capture.activeMode.requiresBroadcast
        let commands = remainsCurrent
            ? transaction.handle(.topologySettled(revision: requirement.topologyRevision))
            : transaction.handle(.topologyChanged(revision: capture.externalOCRTopology.revision))
        ocrRecoveryContinuation = transaction
        if remainsCurrent {
            RinkLensStructuredEventLogger.shared.record(
                domain: .recording,
                event: "ocr_recovery_topology_settled",
                entityID: transaction.transactionID.uuidString,
                previous: ["phase": "settling"],
                next: ["topologyRevision": String(requirement.topologyRevision)],
                source: "RecordingEngine.completeOCRRecoveryTopologySettle",
                reason: "External OCR topology remained physically stable for the admission interval",
                captureGeneration: requirement.captureGeneration,
                authoritativeOwner: "RecordingEngine"
            )
        }
        executeOCRRecoveryCommands(commands, requirement: requirement)
    }

    private func executeOCRRecoveryCommands(
        _ commands: [RinkLensOCRRecoveryContinuationMachine.Command],
        requirement: RinkLensOCRRecoveryRequirement
    ) {
        for command in commands {
            switch command {
            case .closeCurrentSegment:
                guard let transaction = ocrRecoveryContinuation,
                      recordingWriter != nil else { continue }
                recordingWriterCompletionDisposition = .ocrRecoveryBoundary(transaction.transactionID)
                recordingHealthText = "Recording — reconnecting OCR camera"
                removeRecordingCaptureSink(reason: "OCR recovery internal segment boundary")
                recordingWriter?.stop()

            case .convergeOCRBranch:
                guard let handler = ocrRecoveryConvergenceHandler else {
                    handleOCRRecoveryConvergence(.init(
                        requestedDeviceID: requirement.deviceID,
                        topologyRevision: requirement.topologyRevision,
                        captureGeneration: requirement.captureGeneration,
                        structurallyAttached: false,
                        freshFrameVerified: false,
                        broadcastPreserved: true,
                        statusText: "CaptureLifecycleController convergence handler unavailable"
                    ), requirement: requirement)
                    continue
                }
                Task { [weak self] in
                    let result = await handler(requirement)
                    self?.handleOCRRecoveryConvergence(result, requirement: requirement)
                }

            case .openContinuationSegment:
                startOCRRecoveryContinuationWriter(requirement: requirement)

            case .reportRecordingResumed:
                finishOCRRecoveryTransaction(requirement: requirement, degraded: false)

            case .reportRecordingContinuedOCRDegraded:
                finishOCRRecoveryTransaction(requirement: requirement, degraded: true)

            case .cancelWithoutWriterMutation:
                ocrRecoverySettleTask?.cancel()
                ocrRecoverySettleTask = nil
                ocrRecoveryContinuation = nil
                recordingHealthText = "Recording — OCR reconnect was not stable"

            case .stopContinuationAndCompleteOperatorStop:
                recordingWriterCompletionDisposition = .final
                if recordingWriter != nil {
                    discardedContinuationWriterURL = activeRecordingWriterURL
                    activeRecordingWriterURL = nil
                    stopBackgroundRecording(
                        reason: pendingRecordingStopReason == .unknown
                            ? .operatorRequested
                            : pendingRecordingStopReason
                    )
                } else if let result = lastClosedOCRRecoveryResult {
                    ocrRecoveryContinuation = nil
                    completeBackgroundRecordingStop(result)
                }

            case .completeOperatorStop:
                if recordingWriter != nil {
                    recordingWriterCompletionDisposition = .final
                    stopBackgroundRecording(reason: pendingRecordingStopReason == .unknown ? .operatorRequested : pendingRecordingStopReason)
                } else if let result = lastClosedOCRRecoveryResult {
                    recordingWriterCompletionDisposition = .final
                    ocrRecoveryContinuation = nil
                    completeBackgroundRecordingStop(result)
                }
            }
        }
    }

    private func handleOCRRecoveryConvergence(
        _ result: RinkLensOCRBranchRecoveryResult,
        requirement: RinkLensOCRRecoveryRequirement
    ) {
        guard var transaction = ocrRecoveryContinuation,
              transaction.topologyRevision == requirement.topologyRevision else { return }
        guard result.broadcastPreserved else {
            failOCRRecoveryAfterBroadcastLoss(result.statusText)
            return
        }
        let commands = transaction.handle(.ocrConverged(freshFrameVerified: result.freshFrameVerified))
        ocrRecoveryContinuation = transaction
        executeOCRRecoveryCommands(commands, requirement: requirement)
    }

    private func failOCRRecoveryAfterBroadcastLoss(_ detail: String) {
        stopTimers()
        clipEngine.stop()
        removeRecordingCaptureSink(reason: "OCR recovery detected Broadcast source loss")
        recordingWriter = nil
        activeRecordingWriterURL = nil
        backgroundFrameSource = nil
        overlaySnapshotProvider = nil
        releaseRecordingCaptureLease(reason: "Broadcast source was not preserved during OCR recovery")
        RinkLensRecordingCaptureLease.shared.setRecordingActive(false, reason: "OCR recovery Broadcast loss")
        RinkLensRecordingCaptureLease.shared.setWriterContractOpen(
            false,
            sourceContract: "none",
            reason: "OCR recovery Broadcast loss"
        )
        ocrRecoveryContinuation = nil
        logicalRecordingWriterContract = nil
        if let manifest = logicalRecordingManifest?.transitioning(to: .preserved) {
            logicalRecordingManifest = manifest
            persistLogicalRecordingManifest()
            for url in manifest.segments {
                mediaRepository.noteLocalMediaSaved(url: url, albumName: Self.recordingsAlbumName)
            }
        }
        lastErrorMessage = detail
        transition(to: .failed, reason: "Broadcast source lost during OCR recovery")
        recordingHealthText = "Failed — Broadcast camera was not preserved; completed segment retained"
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "ocr_recovery_aborted_broadcast_lost",
            previous: ["writerContract": "closed"],
            next: ["recording": "failed", "segments": String(logicalRecordingSegmentURLs.count)],
            source: "RecordingEngine.handleOCRRecoveryConvergence",
            reason: detail,
            authoritativeOwner: "RecordingEngine"
        )
    }

    private func startOCRRecoveryContinuationWriter(requirement: RinkLensOCRRecoveryRequirement) {
        guard let transaction = ocrRecoveryContinuation,
              transaction.phase == .openingContinuation,
              let frozenContract = logicalRecordingWriterContract,
              let firstURL = currentRecordingURL else { return }

        let segmentNumber = logicalRecordingSegmentURLs.count + 1
        let base = firstURL.deletingPathExtension().lastPathComponent
        let outputURL = firstURL.deletingLastPathComponent()
            .appendingPathComponent(String(format: "%@_part%02d", base, segmentNumber))
            .appendingPathExtension(firstURL.pathExtension)
        let worker = RecordingWriter(compressionEngine: recordingCompressionEngine)
        recordingWriter = worker
        activeRecordingWriterURL = outputURL
        recordingWriterCompletionDisposition = .final
        RinkLensRecordingCaptureLease.shared.setWriterContractOpen(
            true,
            sourceContract: frozenContract.sourceProfile.displayText,
            reason: "Build 136 OCR recovery continuation writer opening"
        )

        let configuration = RecordingWriterConfiguration(
            outputURL: outputURL,
            outputSize: frozenContract.outputSize,
            cadence: frozenContract.cadence,
            codec: frozenContract.codec,
            bitrate: frozenContract.bitrate,
            frameSource: frozenContract.frameSource,
            clipEngine: clipEngine,
            sourceMaximumAge: recordingSourceMaximumAge,
            minimumHealthyFrameRatio: 0.95
        )
        let callbacks = RecordingWriterCallbacks(
            onStarted: { [weak self] in
                guard let self,
                      var active = self.ocrRecoveryContinuation,
                      active.transactionID == transaction.transactionID else { return }
                let commands = active.handle(.continuationFirstFrameAppended)
                self.ocrRecoveryContinuation = active
                self.recordingHealthText = active.freshOCRFrameVerified
                    ? "Recording — OCR camera restored"
                    : "Recording — OCR recovery failed; recording continued"
                RinkLensStructuredEventLogger.shared.record(
                    domain: .recording,
                    event: "recording_continuation_segment_started",
                    entityID: transaction.transactionID.uuidString,
                    previous: ["writerContract": "closed", "segments": String(segmentNumber - 1)],
                    next: ["writerContract": "open", "segment": outputURL.lastPathComponent],
                    source: "RecordingWriter.onStarted",
                    reason: "First compressed continuation frame was physically appended",
                    captureGeneration: requirement.captureGeneration,
                    authoritativeOwner: "RecordingEngine"
                )
                self.executeOCRRecoveryCommands(commands, requirement: requirement)
            },
            onProgress: { [weak self] progress in
                self?.applyBackgroundWorkerProgress(progress)
            },
            onFinished: { [weak self] result in
                self?.completeWriterSegment(result)
            },
            onFailure: { [weak self] message in
                self?.failOCRRecoveryContinuationWriter(message)
            }
        )
        worker.start(configuration: configuration, callbacks: callbacks)
        installRecordingCaptureSink(writer: worker, role: frozenContract.frameSource.sourceRole)
    }

    private func finishOCRRecoveryTransaction(
        requirement: RinkLensOCRRecoveryRequirement,
        degraded: Bool
    ) {
        guard let transaction = ocrRecoveryContinuation else { return }
        lastCompletedOCRRecoveryTopologyRevision = requirement.topologyRevision
        ocrRecoveryContinuation = nil
        lastClosedOCRRecoveryResult = nil
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: degraded ? "ocr_recovery_failed_recording_continued" : "ocr_recovery_recording_resumed",
            entityID: transaction.transactionID.uuidString,
            previous: ["segmentCount": String(max(1, logicalRecordingSegmentURLs.count - 1))],
            next: [
                "segmentCount": String(logicalRecordingSegmentURLs.count),
                "freshOCRFrameVerified": String(!degraded),
                "writerContractOpen": String(RinkLensRecordingCaptureLease.shared.isWriterContractOpen())
            ],
            source: "RecordingEngine.finishOCRRecoveryTransaction",
            reason: degraded ? "Recording continuity resumed without verified OCR" : "OCR and continuation writer were physically acknowledged",
            captureGeneration: requirement.captureGeneration,
            authoritativeOwner: "RecordingEngine"
        )
    }

    private func failOCRRecoveryContinuationWriter(_ message: String) {
        stopTimers()
        clipEngine.stop()
        removeRecordingCaptureSink(reason: "OCR recovery continuation writer failure")
        recordingWriter = nil
        backgroundFrameSource = nil
        overlaySnapshotProvider = nil
        releaseRecordingCaptureLease(reason: "OCR recovery continuation writer failed")
        RinkLensRecordingCaptureLease.shared.setRecordingActive(false, reason: "OCR recovery continuation writer failed")
        RinkLensRecordingCaptureLease.shared.setWriterContractOpen(
            false,
            sourceContract: "none",
            reason: "OCR recovery continuation writer failed"
        )
        ocrRecoveryContinuation = nil
        lastErrorMessage = message
        transition(to: .failed, reason: "OCR recovery continuation writer failed")
        recordingHealthText = "Failed — continuation writer: \(message)"
    }

    private func completeWriterSegment(_ result: RecordingWriterResult) {
        if let discardedURL = discardedContinuationWriterURL {
            discardedContinuationWriterURL = nil
            Self.logicalRecordingManifestQueue.async {
                try? FileManager.default.removeItem(at: discardedURL)
            }
        }
        if let completedURL = activeRecordingWriterURL {
            logicalRecordingManifest = logicalRecordingManifest?.appending(completedURL)
            activeRecordingWriterURL = nil
            persistLogicalRecordingManifest()
        }
        let disposition = recordingWriterCompletionDisposition
        recordingWriterCompletionDisposition = .final
        switch disposition {
        case .final:
            completeBackgroundRecordingStop(result)
        case .ocrRecoveryBoundary(let transactionID):
            completeOCRRecoverySegment(result, transactionID: transactionID)
        }
    }

    private func completeOCRRecoverySegment(_ result: RecordingWriterResult, transactionID: UUID) {
        guard var transaction = ocrRecoveryContinuation,
              transaction.transactionID == transactionID else {
            completeBackgroundRecordingStop(result)
            return
        }
        recordingWriter = nil
        lastClosedOCRRecoveryResult = result
        RinkLensRecordingCaptureLease.shared.setWriterContractOpen(
            false,
            sourceContract: "none",
            reason: "Build 136 OCR recovery internal segment physically closed"
        )
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "recording_internal_segment_closed",
            entityID: transactionID.uuidString,
            previous: ["writerContract": "open", "frames": String(result.framesWritten)],
            next: ["writerContract": "closed", "segments": String(logicalRecordingSegmentURLs.count)],
            source: "RecordingWriter.onFinished",
            reason: "Physical writer completion acknowledged before OCR branch convergence",
            captureGeneration: transaction.captureGeneration,
            authoritativeOwner: "RecordingEngine"
        )
        let commands = transaction.handle(.writerClosed)
        ocrRecoveryContinuation = transaction
        let requirement = RinkLensOCRRecoveryRequirement(
            deviceID: transaction.deviceID,
            topologyRevision: transaction.topologyRevision,
            captureGeneration: transaction.captureGeneration
        )
        executeOCRRecoveryCommands(commands, requirement: requirement)
    }

    private func stopBackgroundRecording(reason: RecordingStopReason) {
        let trace = MainThreadStallMonitor.shared.beginTimedOperation("RecordingEngine.stop")
        pendingRecordingStopReason = reason
        recordingStopOriginText = reason.rawValue
        transition(to: .stopping, reason: "recording stop requested")
        stopTimers()
        clipEngine.stop()
        MainThreadStallMonitor.shared.traceRecordingWriterEvent(
            "UX16d3 RecordingWriter stop requested reason=\(reason.rawValue) frames=\(framesWritten) dropped=\(framesDropped)"
        )
        removeRecordingCaptureSink(reason: "recording stop requested: \(reason.rawValue)")
        recordingWriter?.stop()
        MainThreadStallMonitor.shared.endTimedOperation("RecordingEngine.stop", startedAt: trace)
    }

    private func completeBackgroundRecordingStop(_ result: RecordingWriterResult) {
        removeRecordingCaptureSink(reason: "recording writer finalised")
        stopTimers()
        clipEngine.stop()
        framesWritten = result.framesWritten
        framesDropped = result.framesDropped
        cameraSourceDrops = result.cameraSourceDrops
        sourceSamplingMisses = result.sourceSamplingMisses
        writerDrops = result.writerDrops
        renderDrops = result.renderDrops
        recordingBlackFrameCount = result.blackFramesRejected
        recordingBlackFrameDetectedCount = result.blackFramesDetected
        recordingBlackFrameContinuityAcceptedCount = result.blackFramesContinuityAccepted
        BlackFrameRejectionTraceStore.shared.synchroniseBackgroundWorker(
            totalRejected: result.blackFramesRejected,
            darkObserved: result.blackFramesDetected,
            darkEncoded: result.blackFramesContinuityAccepted,
            firstValidFrameSeen: result.framesWritten > 0,
            lastSummary: recordingFrameValidationText,
            source: recordingSourceText
        )
        recordingActualFPSText = String(format: "%.1ffps", result.actualFPS)
        recordingSourceActualFPSText = String(format: "%.1ffps", result.sourceFPS)
        recordingCadenceRatioText = String(format: "%.1f%%", result.cadenceRatio * 100)
        recordingPollingFPSText = "capture-driven / recording-owned"
        recordingIngressText = result.ingressDiagnosticsText
        recordingWriter = nil
        logicalRecordingWriterContract = nil
        backgroundFrameSource = nil
        overlaySnapshotProvider = nil
        let stopReason: RecordingStopReason
        if let failureKind = result.forcedFailureKind {
            switch failureKind {
            case .sourceLoss: stopReason = .sourceLoss
            case .severeCadenceCollapse: stopReason = .severeCadenceCollapse
            case .encoderFailure: stopReason = .writerFailure
            }
        } else if result.writerStatus == .failed {
            stopReason = .writerFailure
        } else if pendingRecordingStopReason == .unknown {
            stopReason = .unknown
        } else {
            stopReason = pendingRecordingStopReason
        }
        let stopOrigin = stopReason.rawValue
        recordingStopOriginText = stopOrigin
        releaseRecordingCaptureLease(reason: "\(stopOrigin); recording finalised")
        RinkLensRecordingCaptureLease.shared.setRecordingActive(false, reason: "UX16d3 recording stopped")
        RinkLensRecordingCaptureLease.shared.setWriterContractOpen(
            false,
            sourceContract: "none",
            reason: "Recording finalised origin=\(stopOrigin)"
        )
        MainThreadStallMonitor.shared.setRecordingDiagnosticsActive(false, reason: "UX16d3 recording stopped")
        PersistentBroadcastRendererDiagnostics.shared.setBacklog(0)

        if let forcedFailureReason = result.forcedFailureReason {
            let partialPreserved = preservePartialRecordingFile() || result.partialFilePreserved
            lastErrorMessage = forcedFailureReason
            transition(to: .failed, reason: "recording completion failed")

            let failureKind = result.forcedFailureKind ?? .sourceLoss
            switch failureKind {
            case .sourceLoss:
                recordingHealthText = "Failed — Broadcast camera source lost; partial file \(partialPreserved ? "preserved" : "not available")"
                renderLoopModeText = "UX16c50 fail-fast source-loss protection"
            case .severeCadenceCollapse:
                recordingHealthText = "Failed — Broadcast source cadence collapsed; partial file \(partialPreserved ? "preserved" : "not available")"
                renderLoopModeText = "UX16c50 severe-cadence fail-fast protection"
            case .encoderFailure:
                recordingHealthText = "Failed — VideoToolbox encoder session invalid; next recording will create a fresh session"
                renderLoopModeText = "VideoToolbox terminal-session protection"
            }

            CameraOwnershipTraceStore.record(
                .recordingStopped,
                owner: .recording,
                reason: "origin=\(stopOrigin) fail-fast kind=\(failureKind.rawValue) frames=\(framesWritten) sourceUnavailable=\(cameraSourceDrops) samplingMisses=\(sourceSamplingMisses) writerDrops=\(writerDrops) partial=\(partialPreserved)"
            )
            recordDebug("UX16c50 recording failed fast kind=\(failureKind.rawValue): \(forcedFailureReason) partialFilePreserved=\(partialPreserved)")
            writeSessionLog(
                event: failureKind == .sourceLoss ? "recording_failed_source_loss" : "recording_failed_cadence_collapse",
                details: "\(forcedFailureReason) partialFilePreserved=\(partialPreserved)"
            )
            flushSessionLog()
            clipEngine.resumeDeferredExportsAfterRecording(reason: "failed recording finalised origin=\(stopOrigin)")
            return
        }

        if result.writerStatus == .failed {
            lastErrorMessage = result.errorDescription ?? "Unknown background recording writer failure"
            transition(to: .failed, reason: "recording completion failed")
            recordingHealthText = "Failed — terminal writer error; append loop stopped immediately"
            renderLoopModeText = "UX16d2a terminal writer failure; partial file preserved where available"
            recordingFrameValidationText = lastErrorMessage ?? "terminal writer failure"
            CameraOwnershipTraceStore.record(
                .recordingStopped,
                owner: .recording,
                reason: "origin=\(stopOrigin) writerFailure=\(lastErrorMessage ?? "unknown") frames=\(framesWritten) writerDrops=\(writerDrops)"
            )
            recordDebug("UX16d2a recording stopped at first terminal writer failure origin=\(stopOrigin): \(lastErrorMessage ?? "unknown")")
            writeSessionLog(event: "recording_failed_writer", details: lastErrorMessage ?? "unknown")
            flushSessionLog()
            clipEngine.resumeDeferredExportsAfterRecording(reason: "writer failure finalised origin=\(stopOrigin)")
            return
        }

        let cadencePercent = result.cadenceRatio * 100
        if result.cadenceRatio >= 0.95 {
            recordingHealthText = String(format: "Completed — %.1f%% cadence; source and writer healthy", cadencePercent)
        } else {
            recordingHealthText = String(format: "Completed with cadence warning — %.1f%% of target; file preserved", cadencePercent)
        }
        updateRecordingFPSWarning()
        CameraOwnershipTraceStore.record(
            .recordingStopped,
            owner: .recording,
            reason: String(format: "UX16c53 origin=%@ frames=%d cadence=%.1f%% sourceFPS=%.1f unavailable=%d samplingMisses=%d writer=%d render=%d blackHeld=%d blackDetected=%d blackAccepted=%d ingress={%@}", stopOrigin, framesWritten, cadencePercent, result.sourceFPS, cameraSourceDrops, sourceSamplingMisses, writerDrops, renderDrops, recordingBlackFrameCount, recordingBlackFrameDetectedCount, recordingBlackFrameContinuityAcceptedCount, result.ingressDiagnosticsText)
        )
        recordDebug(String(format: "UX16c53 recording stopped origin=%@: %d frames, %.1f%% cadence, sourceFPS=%.1f unavailable=%d samplingMisses=%d writer=%d render=%d blackHeld=%d blackDetected=%d blackAccepted=%d ingress={%@}", stopOrigin, framesWritten, cadencePercent, result.sourceFPS, cameraSourceDrops, sourceSamplingMisses, writerDrops, renderDrops, recordingBlackFrameCount, recordingBlackFrameDetectedCount, recordingBlackFrameContinuityAcceptedCount, result.ingressDiagnosticsText))
        writeSessionLog(event: result.cadenceRatio >= 0.95 ? "recording_stopped_healthy" : "recording_stopped_cadence_warning", details: "\(elapsedText) cadence=\(recordingCadenceRatioText)")
        flushSessionLog()
        transition(to: .idle, reason: "recording finalised; UI released before offline media work")
        finalizeLogicalRecordingAfterWriterClose(stopOrigin: stopOrigin)
    }

    /// Final media work runs strictly after writer closure. A recording that
    /// crossed an internal OCR-recovery boundary is joined once, in order, and
    /// Photos sees one logical game rather than independent implementation
    /// segments. Originals remain untouched until PhotoKit verifies the joined
    /// asset, so a failed join or save remains recoverable from app storage.
    private func finalizeLogicalRecordingAfterWriterClose(stopOrigin: String) {
        guard var manifest = logicalRecordingManifest else {
            if let url = currentRecordingURL {
                queueVideoToPhotosAlbum(url: url, albumName: Self.recordingsAlbumName, mediaKind: "recording") { [weak self] success in
                    guard let self else { return }
                    if success { self.currentRecordingURL = nil }
                    self.clipEngine.resumeDeferredExportsAfterRecording(reason: "recording persistence completed origin=\(stopOrigin) success=\(success)")
                }
            } else {
                clipEngine.resumeDeferredExportsAfterRecording(reason: "recording finalised without media persistence origin=\(stopOrigin)")
            }
            return
        }

        switch manifest.finalizationAction {
        case .persistDirectly:
            guard let url = manifest.segments.first else {
                preserveLogicalRecordingSegments(manifest, error: "Logical recording contained no completed segment", stopOrigin: stopOrigin)
                return
            }
            queueVideoToPhotosAlbum(url: url, albumName: Self.recordingsAlbumName, mediaKind: "recording") { [weak self] success in
                guard let self else { return }
                if success {
                    self.removeLogicalRecordingManifestFile(manifest)
                    self.logicalRecordingManifest = nil
                    self.currentRecordingURL = nil
                } else {
                    self.logicalRecordingManifest = manifest.transitioning(to: .preserved)
                    self.persistLogicalRecordingManifest()
                }
                self.clipEngine.resumeDeferredExportsAfterRecording(reason: "recording persistence completed origin=\(stopOrigin) success=\(success)")
            }

        case .joinOrderedSegments:
            manifest = manifest.transitioning(to: .awaitingJoin)
            logicalRecordingManifest = manifest
            persistLogicalRecordingManifest()
            let firstURL = manifest.segments[0]
            let outputURL = firstURL.deletingPathExtension()
                .appendingPathExtension("complete.mp4")
            recordingHealthText = "Completed — preparing one game recording"
            RinkLensStructuredEventLogger.shared.record(
                domain: .recording,
                event: "recording_segments_join_scheduled",
                entityID: manifest.logicalRecordingID.uuidString,
                previous: ["segments": String(manifest.segments.count)],
                next: ["output": outputURL.lastPathComponent, "queue": "post-capture"],
                source: "RecordingEngine.finalizeLogicalRecordingAfterWriterClose",
                reason: "Internal OCR recovery writer boundaries must persist as one ordered game recording",
                authoritativeOwner: "RecordingEngine"
            )
            mediaRepository.enqueuePostCaptureOperation(label: "Join logical game recording") { [weak self] finish in
                do {
                    try manifest.writeAtomically(to: Self.logicalRecordingManifestURL(for: manifest))
                    try RinkLensLogicalRecordingJoiner.join(segments: manifest.segments, outputURL: outputURL)
                    Task { @MainActor [weak self] in
                        guard let self else { finish(); return }
                        self.currentRecordingURL = outputURL
                        self.queueVideoToPhotosAlbum(
                            url: outputURL,
                            albumName: Self.recordingsAlbumName,
                            mediaKind: "recording"
                        ) { [weak self] success in
                            guard let self else { finish(); return }
                            if success {
                                self.removeLogicalRecordingSegments(manifest.segments)
                                self.removeLogicalRecordingManifestFile(manifest)
                                self.logicalRecordingManifest = nil
                                self.currentRecordingURL = nil
                                self.recordingHealthText = "Completed — game recording saved"
                            } else {
                                self.logicalRecordingManifest = manifest.transitioning(to: .preserved)
                                self.persistLogicalRecordingManifest()
                                self.recordingHealthText = "Completed — game recording retained in RinkLens Files"
                            }
                            self.clipEngine.resumeDeferredExportsAfterRecording(reason: "logical recording persistence completed origin=\(stopOrigin) success=\(success)")
                            finish()
                        }
                    }
                } catch {
                    Task { @MainActor [weak self] in
                        guard let self else { finish(); return }
                        self.preserveLogicalRecordingSegments(manifest, error: error.localizedDescription, stopOrigin: stopOrigin)
                        finish()
                    }
                }
            }

        case .preserveSegments:
            preserveLogicalRecordingSegments(manifest, error: "Logical recording requires recovery", stopOrigin: stopOrigin)
        }
    }

    private func preserveLogicalRecordingSegments(
        _ manifest: RinkLensLogicalRecordingManifest,
        error: String,
        stopOrigin: String
    ) {
        logicalRecordingManifest = manifest.transitioning(to: .preserved)
        persistLogicalRecordingManifest()
        for url in manifest.segments where FileManager.default.fileExists(atPath: url.path) {
            mediaRepository.noteLocalMediaSaved(url: url, albumName: Self.recordingsAlbumName)
        }
        currentRecordingURL = manifest.segments.first
        lastErrorMessage = error
        recordingHealthText = "Completed — recording segments retained for recovery"
        recordDebug("Build 136 logical recording preserved: \(error)")
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "recording_segments_preserved_after_join_failure",
            entityID: manifest.logicalRecordingID.uuidString,
            previous: ["segments": String(manifest.segments.count)],
            next: ["state": "preserved", "error": error],
            source: "RecordingEngine.preserveLogicalRecordingSegments",
            reason: "A join or persistence boundary failed; source segments were retained without deletion",
            authoritativeOwner: "RecordingEngine"
        )
        clipEngine.resumeDeferredExportsAfterRecording(reason: "logical recording segments preserved origin=\(stopOrigin)")
    }

    private func persistLogicalRecordingManifest() {
        guard let manifest = logicalRecordingManifest else { return }
        let url = logicalRecordingManifestFileURL ?? Self.logicalRecordingManifestURL(for: manifest)
        Self.logicalRecordingManifestQueue.async { [weak self] in
            do {
                try manifest.writeAtomically(to: url)
            } catch {
                Task { @MainActor [weak self] in
                    self?.lastErrorMessage = "Recording recovery manifest could not be saved: \(error.localizedDescription)"
                    self?.recordDebug("Build 136 manifest durability failure; media files retained: \(error.localizedDescription)")
                }
            }
        }
    }

    private nonisolated static let logicalRecordingManifestQueue = DispatchQueue(
        label: "rinklens.recording.logical-manifest",
        qos: .utility
    )

    private nonisolated static func logicalRecordingManifestURL(
        for manifest: RinkLensLogicalRecordingManifest
    ) -> URL {
        let first = manifest.segments.first
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(manifest.logicalRecordingID.uuidString)
        return first.deletingPathExtension().appendingPathExtension("recording.json")
    }

    private func removeLogicalRecordingManifestFile(_ manifest: RinkLensLogicalRecordingManifest) {
        let url = logicalRecordingManifestFileURL ?? Self.logicalRecordingManifestURL(for: manifest)
        Self.logicalRecordingManifestQueue.async {
            try? FileManager.default.removeItem(at: url)
        }
        logicalRecordingManifestFileURL = nil
    }

    private func removeLogicalRecordingSegments(_ segments: [URL]) {
        Self.logicalRecordingManifestQueue.async {
            for url in segments where FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // R22 freezes one physical Broadcast source and cadence for the complete
    // recording file. The former writer-hold/camera-rebind/cadence-transition
    // APIs were deleted; an open writer is no longer a participant in camera
    // device replacement. Unexpected source loss remains a real failure signal.

    func pauseRecording() {
        guard canPause else { return }
        if state == .recording,
           deferOperatorPauseIfCameraHandoffActive(source: "BroadcastRecordingManager.pauseRecording") {
            return
        }
        recordingWriter?.setPaused(true, reason: "operator pause")
        transition(to: .paused, reason: "operator pause")
        recordDebug("Recording paused")
        writeSessionLog(event: "recording_paused", details: elapsedText)
    }

    func resumeRecording() {
        guard canResume else { return }
        recordingWriter?.setPaused(false, reason: "operator resume after verified Broadcast source")
        transition(to: .recording, reason: "operator resume")
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "recording_resume_boundary_committed",
            entityID: currentRecordingURL?.lastPathComponent,
            previous: [
                "state": RecordingState.paused.rawValue
            ],
            next: [
                "state": RecordingState.recording.rawValue,
                "sameFile": "true",
                "cadenceHealth": "fresh-window"
            ],
            source: "BroadcastRecordingManager.resumeRecording",
            reason: "Operator resumed the same route-independent writer and capture lease",
            authoritativeOwner: "BroadcastRecordingManager"
        )
        RinkLensRecordingCaptureLease.shared.setRecordingActive(true, reason: "recording resumed by operator")
        MainThreadStallMonitor.shared.setRecordingDiagnosticsActive(true, reason: "recording resumed by operator")
        recordingHealthText = "Recording — resumed by operator"
        recordDebug("Recording resumed by explicit operator action")
        writeSessionLog(event: "recording_resumed", details: elapsedText)
    }

    func stopRecording(reason: RecordingStopReason = .operatorRequested) {
        guard canStop else { return }
        pendingRecordingStopReason = reason
        recordingStopOriginText = reason.rawValue
        if var transaction = ocrRecoveryContinuation {
            let commands = transaction.handle(.operatorStopRequested)
            ocrRecoveryContinuation = transaction
            let requirement = RinkLensOCRRecoveryRequirement(
                deviceID: transaction.deviceID,
                topologyRevision: transaction.topologyRevision,
                captureGeneration: transaction.captureGeneration
            )
            executeOCRRecoveryCommands(commands, requirement: requirement)
            return
        }
        if state == .starting, recordingWriter == nil {
            transition(to: .stopping, reason: "operator cancelled recording start before writer creation")
            recordingHealthText = "Recording start cancelled"
            transition(to: .idle, reason: "recording start cancelled before writer creation")
            RinkLensStructuredEventLogger.shared.record(
                domain: .recording,
                event: "recording_start_cancelled_before_writer_creation",
                previous: ["state": RecordingState.starting.rawValue],
                next: ["state": RecordingState.idle.rawValue],
                source: "RecordingEngine.stopRecording",
                reason: reason.rawValue,
                authoritativeOwner: "RecordingEngine"
            )
            return
        }
        stopBackgroundRecording(reason: reason)
    }

    /// Temporary compatibility overload for call sites governed by later stages.
    func stopRecording(origin: String) {
        stopRecording(reason: RecordingStopReason(legacyText: origin))
    }

    func saveSnapshotClip(homeTeam: String, awayTeam: String) {
        let trace = MainThreadStallMonitor.shared.beginTimedOperation("RecordingEngine.snapshotClip.queue")
        guard isRecording else {
            manualClipExportStateText = "Unavailable"
            manualClipFeedbackText = "Start recording first — clips use the active PixelBuffer recording buffer"
            recordDebug("manual clip blocked: recording inactive; compressed-sample clip buffer starts with recording")
            MainThreadStallMonitor.shared.endTimedOperation("RecordingEngine.snapshotClip.queue", startedAt: trace)
            return
        }

        let pressedAt = Date()
        if let lastManualClipButtonPressedAt,
           pressedAt.timeIntervalSince(lastManualClipButtonPressedAt) < manualClipButtonDebounceSeconds {
            manualClipExportStateText = pendingManualPostRollClips.isEmpty ? "Cooling down" : "Queued"
            manualClipFeedbackText = pendingManualPostRollClips.isEmpty ? "Clip saved — wait a moment before taking another" : "Clip already queued — waiting for post-roll"
            recordDebug("manual clip ignored: debounce active")
            CameraOwnershipTraceStore.record(.clipFailed, owner: .recording, reason: "manual clip ignored: debounce active")
            MainThreadStallMonitor.shared.endTimedOperation("RecordingEngine.snapshotClip.queue", startedAt: trace)
            return
        }

        if !pendingManualPostRollClips.isEmpty {
            manualClipExportStateText = "Queued"
            manualClipFeedbackText = "Clip already queued — waiting for post-roll"
            recordDebug("manual clip ignored: post-roll clip already queued")
            CameraOwnershipTraceStore.record(.clipFailed, owner: .recording, reason: "manual clip ignored: post-roll already queued")
            MainThreadStallMonitor.shared.endTimedOperation("RecordingEngine.snapshotClip.queue", startedAt: trace)
            return
        }

        lastManualClipButtonPressedAt = pressedAt
        let requestID = UUID()
        let postRollSeconds = BroadcastManualClipPostRollPolicy.postRollSeconds
        pendingManualPostRollClips[requestID] = PendingManualPostRollClip(
            id: requestID,
            pressedAt: pressedAt,
            homeTeam: homeTeam,
            awayTeam: awayTeam,
            preRollSeconds: snapshotClipSeconds,
            postRollSeconds: postRollSeconds
        )

        manualClipExportStateText = "Queued"
        manualClipFeedbackText = "Clip queued — saving \(Int(postRollSeconds.rounded()))s post-roll"
        recordDebug("clip button pressed time=\(diagnosticTime(pressedAt)) preRoll=\(snapshotClipSeconds)s postRoll=\(String(format: "%.1f", postRollSeconds))s")
        writeSessionLog(event: "clip_export_postroll_queued", details: "pre=\(snapshotClipSeconds)s post=\(String(format: "%.1f", postRollSeconds))s")
        CameraOwnershipTraceStore.record(.clipQueued, owner: .recording, reason: "manual clip button pressed; post-roll queued")

        DispatchQueue.main.asyncAfter(deadline: .now() + postRollSeconds) { [weak self] in
            self?.completeManualPostRollClip(requestID: requestID, completionReason: "postRollComplete")
        }

        MainThreadStallMonitor.shared.endTimedOperation("RecordingEngine.snapshotClip.queue", startedAt: trace)
    }

    private func diagnosticTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    private func completeManualPostRollClip(requestID: UUID, completionReason: String) {
        guard let request = pendingManualPostRollClips.removeValue(forKey: requestID) else {
            recordDebug("clip post-roll ignored request=\(requestID.uuidString)")
            return
        }

        manualClipExportStateText = "Saving"
        manualClipFeedbackText = isRecording
            ? "Saving clip — recording continues"
            : "Saving clip"
        let end = request.pressedAt.addingTimeInterval(request.postRollSeconds)
        recordDebug("clip post-roll complete reason=\(completionReason) request=\(requestID.uuidString) pressed=\(diagnosticTime(request.pressedAt)) targetEnd=\(diagnosticTime(end))")
        recordDebug("clip export requested requestedDuration=\(String(format: "%.1f", BroadcastManualClipPostRollPolicy.requestedDuration(preRollSeconds: request.preRollSeconds, postRollSeconds: request.postRollSeconds)))s requestedWindow=\(diagnosticTime(request.pressedAt.addingTimeInterval(-TimeInterval(request.preRollSeconds))))...\(diagnosticTime(end))")
        writeSessionLog(
            event: "clip_export_postroll_started",
            details: "pre=\(request.preRollSeconds)s post=\(String(format: "%.1f", request.postRollSeconds))s reason=\(completionReason)"
        )

        clipEngine.requestManualClip(
            preRollSeconds: request.preRollSeconds,
            postRollSeconds: request.postRollSeconds,
            anchor: request.pressedAt,
            homeTeam: request.homeTeam,
            awayTeam: request.awayTeam
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let exportResult):
                let exportedURL = exportResult.url
                self.manualClipExportStateText = "Saved"
                self.manualClipFeedbackText = BroadcastManualClipPostRollPolicy.feedback(for: exportResult.metadata)
                let status = BroadcastManualClipPostRollPolicy.normalisedStatusText(for: exportResult.metadata)
                let actual = exportResult.metadata.actualDuration ?? 0
                let requested = exportResult.metadata.requestedDuration ?? 0
                self.recordDebug("clip feedback normalised status=\(status) actual=\(String(format: "%.1f", actual))s requested=\(String(format: "%.1f", requested))s reason=\(exportResult.metadata.shortClipReason ?? "fullDuration")")
                self.recordDebug("clip export completed: \(exportedURL.lastPathComponent)")
                self.writeSessionLog(event: "clip_export_completed", details: exportedURL.lastPathComponent)
                self.queueVideoToPhotosAlbum(url: exportedURL, albumName: Self.manualHighlightsAlbumName, mediaKind: "manual highlight") { [weak self] success in
                    if success { self?.clipEngine.acknowledgePermanentPhotosPersistence(localURL: exportedURL) }
                }
                CameraOwnershipTraceStore.record(.clipExported, owner: .recording, reason: exportedURL.lastPathComponent)
            case .failure(let error):
                self.lastErrorMessage = error.localizedDescription
                self.manualClipExportStateText = "Failed"
                if error.localizedDescription.contains("not enough recorded footage") {
                    self.manualClipFeedbackText = "Clip unavailable — not enough recorded footage yet"
                } else {
                    self.manualClipFeedbackText = "Clip failed — recording continues"
                }
                self.recordDebug("clip export failed: \(error.localizedDescription)")
                self.writeSessionLog(event: "clip_export_failed", details: error.localizedDescription)
                CameraOwnershipTraceStore.record(.clipFailed, owner: .recording, reason: error.localizedDescription)
            }
        }
    }

    func noteBroadcastClockRunningChanged(isRunning: Bool, period: Int?, gameClock: String?) {
        if isRunning {
            guard let anchor = stoppedClockClipAnchor, !pendingStoppedClockClipTags.isEmpty else { return }
            recordDebug("clock restarted Time B captured: \(gameClock ?? "--")")
            clipEngine.requestAutomaticClip(
                anchor: anchor,
                tags: Array(pendingStoppedClockClipTags).sorted(),
                period: pendingStoppedClockClipPeriod ?? period,
                gameClock: pendingStoppedClockGameClock ?? gameClock,
                team: nil,
                playerNumber: nil,
                completion: automaticClipPersistenceCompletion()
            )
            recordDebug("automatic clip confirmed: \(pendingStoppedClockClipTags.sorted().joined(separator: "+"))")
            stoppedClockClipAnchor = nil
            pendingStoppedClockClipTags.removeAll()
            pendingStoppedClockClipPeriod = nil
            pendingStoppedClockGameClock = nil
        } else if stoppedClockClipAnchor == nil {
            stoppedClockClipAnchor = Date()
            pendingStoppedClockClipPeriod = period
            pendingStoppedClockGameClock = gameClock
            recordDebug("clock stopped Time A captured: \(gameClock ?? "--")")
        }
    }

    func noteBroadcastEventConfirmed(_ event: BroadcastEvent) {
        switch event.type {
        case .goal, .powerPlayGoal, .shortHandedGoal:
            guard stoppedClockClipAnchor != nil else { return }
            pendingStoppedClockClipTags.insert("GOAL")
            pendingStoppedClockClipPeriod = event.period
            pendingStoppedClockGameClock = event.gameClock
            recordDebug("goal pending in stopped-clock window")
        case .penalty, .penalties, .powerPlayStart, .penaltyEnd, .timeoutStart, .timeoutEnd:
            guard stoppedClockClipAnchor != nil else { return }
            pendingStoppedClockClipTags.insert("PENALTY")
            pendingStoppedClockClipPeriod = event.period
            pendingStoppedClockGameClock = event.gameClock
            recordDebug("penalty pending in stopped-clock window")
        case .periodEnd:
            clipEngine.requestAutomaticClip(anchor: Date(), tags: ["PERIOD_END"], period: event.period, gameClock: event.gameClock, team: event.team?.rawValue, playerNumber: nil, completion: automaticClipPersistenceCompletion())
            recordDebug("automatic clip confirmed: period end")
        case .gameFinal:
            clipEngine.requestAutomaticClip(anchor: Date(), tags: ["GAME_END"], period: event.period, gameClock: event.gameClock, team: event.team?.rawValue, playerNumber: nil, completion: automaticClipPersistenceCompletion())
            recordDebug("automatic clip confirmed: game end")
        }
    }

    func clearRecordingDiagnostics() {
        lastErrorMessage = nil
        lastDebugMessage = "Recording diagnostics cleared"
        framesWritten = 0
        framesDropped = 0
        lastFrameAgeText = "--"
        recordingBlackFrameCount = 0
        recordingBlackFrameDetectedCount = 0
        recordingBlackFrameContinuityAcceptedCount = 0
        recordingFirstValidFrameText = "waiting"
        recordingLastWrittenFrameText = "--"
        recordingFrameValidationText = "cleared"
        recordingActualFPSText = "--"
        recordingSourceActualFPSText = "--"
        recordingCadenceRatioText = "--"
        recordingPollingFPSText = "--"
        recordingIngressText = "inactive"
        recordingEncoderBacklogText = "0"
        manualClipFeedbackText = "Clip ready"
        manualClipExportStateText = "Idle"
        recordingTransformSourceText = broadcastTransformSummary(liveRotationDegrees: 0, usingOCRFallback: false)
        recordingRawFrameCorrectionText = "raw camera frame correction: 180°"
        sessionLog.removeAll()
    }

    func applyRecordingProfile() {
        if let source = cameraSourceProfile {
            applyRecordingProfile(from: source)
            return
        }
        if RinkLensRiskFeaturePolicy.isEnabled(.customRecordingOutputProfileV15) {
            applyCustomVideoPolicyProjection(reason: "recording profile refresh")
            let outputMode = activeRecordingOutputMode
            recordingCadence = .init(integerFPS: outputMode.frameRate.rawValue)
            nominalFPS = Int32(recordingCadence.nominalFPS)
            outputSize = outputMode.resolution.size
            recordingTargetFPSText = "\(outputMode.frameRate.label) (output)"
            recordingTargetResolutionText = "\(Int(outputSize.width))x\(Int(outputSize.height)) (output)"
            recordingCameraSourceText = "Waiting for active Broadcast camera"
            recordingSourceText = "recording output policy ready; camera source pending"
            renderLoopModeText = "recording output policy: \(recordingOutputPolicySummaryText); source pending"
            return
        }
        if !RinkLensRiskFeaturePolicy.isEnabled(.cameraSourceRecordingProfileV5) {
            recordingCadence = .init(integerFPS: recordingProfile.frameRate.rawValue)
            nominalFPS = Int32(recordingCadence.nominalFPS)
            outputSize = recordingProfile.resolution.size
        }
        recordingTargetFPSText = "Source pending"
        recordingTargetResolutionText = "Source pending"
        recordingCameraSourceText = "Waiting for active Broadcast camera"
        recordingSourceText = "waiting for Broadcast camera source"
        renderLoopModeText = "camera-source profile pending"
    }

    private func applyRecordingProfile(from source: RecordingCameraSourceProfile) {
        if RinkLensRiskFeaturePolicy.isEnabled(.recordingSourceTruthfulStartV19) {
            // The verified Broadcast source is the sole effective size/cadence
            // authority. Custom recording settings remain codec/bitrate requests;
            // they cannot demand frames that the active camera graph does not own.
            applyCustomVideoPolicyProjection(reason: "verified source truth reconciled")
            let requestedMode = activeRecordingOutputMode
            recordingCadence = source.cadence
            nominalFPS = Int32(source.framesPerSecond)
            outputSize = source.outputSize
            recordingTargetFPSText = "\(source.cadence.displayText)fps effective (requested \(requestedMode.frameRate.label))"
            recordingTargetResolutionText = "\(source.width)x\(source.height) effective"
            recordingCameraSourceText = source.displayText
            recordingSourceText = "Verified Broadcast camera source"
            renderLoopModeText = "source-truth writer: \(source.displayText) / \(activeRecordingCodec.rawValue) / \(activeVideoBitrateMbps) Mbps"
            let requestedSize = requestedMode.resolution.size
            let policyDiffers = requestedMode.frameRate.rawValue != source.framesPerSecond
                || Int(max(requestedSize.width, requestedSize.height)) != max(source.width, source.height)
                || Int(min(requestedSize.width, requestedSize.height)) != min(source.width, source.height)
            if policyDiffers {
                RinkLensStructuredEventLogger.shared.record(
                    domain: .recording,
                    event: "recording_output_policy_reconciled_to_source",
                    entityID: source.physicalDeviceID,
                    previous: ["requested": recordingOutputPolicySummaryText],
                    next: [
                        "effectiveSize": "\(source.width)x\(source.height)",
                        "effectiveFPS": source.cadence.displayText,
                        "codec": activeRecordingCodec.rawValue,
                        "bitrateMbps": String(activeVideoBitrateMbps)
                    ],
                    source: "BroadcastRecordingManager",
                    reason: "Camera source is authoritative; never fabricate or reject unavailable source frames",
                    captureGeneration: source.captureGeneration,
                    authoritativeOwner: "BroadcastRecordingManager"
                )
            }
            return
        }
        if RinkLensRiskFeaturePolicy.isEnabled(.customRecordingOutputProfileV15) {
            applyCustomVideoPolicyProjection(reason: "verified camera source applied")
            let outputMode = activeRecordingOutputMode
            recordingCadence = .init(integerFPS: outputMode.frameRate.rawValue)
            nominalFPS = Int32(recordingCadence.nominalFPS)
            outputSize = outputMode.resolution.size
            recordingTargetFPSText = "\(outputMode.frameRate.label) output from \(source.cadence.displayText)fps source"
            recordingTargetResolutionText = "\(Int(outputSize.width))x\(Int(outputSize.height)) output"
            recordingCameraSourceText = source.displayText
            recordingSourceText = "Broadcast camera source encoded through recording output policy"
            renderLoopModeText = "camera source \(source.displayText) -> \(recordingOutputPolicySummaryText)"
            return
        }
        recordingCadence = source.cadence
        nominalFPS = Int32(source.framesPerSecond)
        outputSize = source.outputSize
        // Compatibility projections only. They are not independently writable
        // while cameraSourceRecordingProfileV5 is enabled.
        recordingProfile.resolution = source.resolutionProjection
        recordingProfile.frameRate = source.frameRateProjection
        recordingTargetFPSText = "\(source.cadence.displayText)fps"
        recordingTargetResolutionText = "\(source.width)x\(source.height)"
        recordingCameraSourceText = source.displayText
        recordingSourceText = "Broadcast camera source"
        renderLoopModeText = "camera-source profile: \(source.displayText) / \(recordingProfile.codec.rawValue) / \(recordingProfile.bitrate.rawValue)"
    }

    func applyAuthoritativeCameraSource(
        _ source: RecordingCameraSourceProfile,
        reason: String
    ) {
        guard state == .idle || state == .failed else {
            recordDebug("Camera source update deferred while recording: \(source.displayText)")
            return
        }
        let previous = cameraSourceProfile
        cameraSourceProfile = source
        recordingFormatWarningText = nil
        manualClipExportStateText = "Idle"
        manualClipFeedbackText = "Clip ready"
        applyRecordingProfile()
        updateRecordingFPSWarning()
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "recording_profile_derived_from_camera_source",
            entityID: source.physicalDeviceID,
            previous: [
                "source": previous?.displayText ?? "none",
                "generation": previous.map { String($0.captureGeneration) } ?? "none"
            ],
            next: [
                "source": source.displayText,
                "generation": String(source.captureGeneration),
                "outputSize": "\(source.width)x\(source.height)",
                "writerFPS": source.cadence.displayText
            ],
            source: "BroadcastRecordingManager",
            reason: reason
        )
        recordDebug("Recording source/profile unified for \(reason): \(source.displayText)")
    }

    func applyCameraSourceValidation(_ validation: RecordingCameraFormatValidationResult, reason: String) -> Bool {
        guard validation.isValid, let source = validation.sourceProfile else {
            blockRecordingStartForCameraFormat(validation)
            return false
        }
        if RinkLensRiskFeaturePolicy.isEnabled(.customRecordingOutputProfileV15),
           !RinkLensRiskFeaturePolicy.isEnabled(.recordingSourceTruthfulStartV19),
           let failure = recordingOutputPolicyFailure(for: source) {
            let rejected = RecordingCameraFormatValidationResult.invalid(
                requested: recordingOutputPolicySummaryText,
                active: source.displayText,
                reason: failure
            )
            blockRecordingStartForCameraFormat(rejected)
            return false
        }
        if RinkLensRiskFeaturePolicy.isEnabled(.recordingSourceTruthfulStartV19),
           activeRecordingCodec == .h265,
           !supportsHEVCRecording {
            let rejected = RecordingCameraFormatValidationResult.invalid(
                requested: recordingOutputPolicySummaryText,
                active: source.displayText,
                reason: "HEVC recording is unavailable on this device. Choose Compatible (H.264)."
            )
            blockRecordingStartForCameraFormat(rejected)
            return false
        }
        applyAuthoritativeCameraSource(source, reason: reason)
        return true
    }

    private func recordingOutputPolicyFailure(for source: RecordingCameraSourceProfile) -> String? {
        let mode = activeRecordingOutputMode
        let required = mode.resolution.size
        let sourceWidth = max(source.width, source.height)
        let sourceHeight = min(source.width, source.height)
        let requiredWidth = Int(max(required.width, required.height))
        let requiredHeight = Int(min(required.width, required.height))
        if sourceWidth < requiredWidth || sourceHeight < requiredHeight {
            return "Recording is set to \(mode.compactLabel), but the verified Broadcast source is only \(sourceWidth)x\(sourceHeight). Choose a lower recording mode or a camera format that supplies the requested dimensions."
        }
        if source.framesPerSecond + 1 < mode.frameRate.rawValue {
            return "Recording is set to \(mode.compactLabel), but the verified Broadcast source supplies \(source.framesPerSecond)fps. Choose a lower output cadence or a camera format that supports \(mode.frameRate.rawValue)fps."
        }
        if activeRecordingCodec == .h265 && !supportsHEVCRecording {
            return "HEVC recording is unavailable on this device. Choose Compatible (H.264)."
        }
        return nil
    }

    func blockRecordingStartForCameraFormat(_ validation: RecordingCameraFormatValidationResult) {
        if let transactionID = recordingStartPreflightID {
            _ = completeRecordingStartPreflight(
                transactionID: transactionID,
                accepted: false,
                reason: validation.failureReason ?? "camera source validation rejected"
            )
        }
        releaseRecordingCaptureLease(
            reason: "recording preflight rejected",
            replayRouteAfterRelease: false
        )
        RinkLensRecordingCaptureLease.shared.setWriterContractOpen(
            false,
            sourceContract: "none",
            reason: "Recording preflight rejected before writer start"
        )
        lastErrorMessage = validation.operatorMessage
        recordingFormatWarningText = validation.operatorMessage
        recordingFPSWarningText = validation.operatorMessage
        manualClipFeedbackText = "Recording blocked — active Broadcast camera source is unavailable"
        manualClipExportStateText = "Unavailable"
        renderLoopModeText = "recording blocked by camera-source guard"
        transition(to: .failed, reason: "recording start blocked")
        CameraOwnershipTraceStore.record(.recordingStopped, owner: .recording, reason: "preflight blocked: \(validation.activeFormatText)")
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "recording_preflight_rejected",
            entityID: nil,
            previous: ["state": "requested"],
            next: ["state": "blocked", "active": validation.activeFormatText],
            source: "BroadcastRecordingManager",
            reason: validation.failureReason ?? "camera source unresolved"
        )
        recordDebug("Recording blocked by camera-source guard: \(validation.operatorMessage)")
    }

    /// Rollback-only compatibility helper. Enabled Build 707 code must obtain a
    /// typed profile from CaptureEngine through `prepareBroadcastRecordingStart`.
    func syncRecordingProfileWithCameraFormatText(_ text: String, reason: String) {
        guard !RinkLensRiskFeaturePolicy.isEnabled(.cameraSourceRecordingProfileV5) else {
            recordDebug("Ignored text-derived camera profile for \(reason); typed CaptureEngine source is authoritative")
            return
        }
        guard let source = RecordingCameraSourceProfile.parseLegacyText(
            formatText: text,
            physicalDeviceID: nil,
            captureGeneration: 0
        ) else {
            recordDebug("Rollback camera source profile not resolved for \(reason): \(text)")
            return
        }
        applyAuthoritativeCameraSource(source, reason: "rollback: \(reason)")
    }

    private func applyCustomVideoPolicyProjection(reason: String) {
        guard RinkLensRiskFeaturePolicy.isEnabled(.customRecordingOutputProfileV15) else { return }
        let mode = activeRecordingOutputMode
        recordingProfile.resolution = mode.resolution
        recordingProfile.frameRate = mode.frameRate
        recordingProfile.codec = activeRecordingCodec
        recordingProfile.bitrate = .medium
        customVideoSettingsStatusText = customVideoSettingsEnabled
            ? "Custom output: \(recordingOutputPolicySummaryText)"
            : "Managed output: verified Broadcast camera dimensions and native cadence / H.264 / 8 Mbps"
        recordDebug("Build 729 recording output policy refreshed for \(reason): \(recordingOutputPolicySummaryText)")
    }

    func setCustomVideoSettingsEnabled(_ enabled: Bool, source: String, reason: String) {
        guard state == .idle || state == .failed else {
            recordDebug("Custom video settings toggle ignored while recording")
            return
        }
        let previous = customVideoSettingsEnabled
        guard previous != enabled else { return }
        customVideoSettingsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.customVideoSettingsEnabledDefaultsKey)
        applyCustomVideoPolicyProjection(reason: reason)
        applyRecordingProfile()
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "recording_custom_video_settings_changed",
            entityID: "recording-output-policy",
            previous: ["enabled": String(previous), "profile": previous ? customVideoOutputMode.compactLabel : "verified active Broadcast camera source"],
            next: ["enabled": String(enabled), "profile": recordingOutputPolicySummaryText],
            source: source,
            reason: reason
        )
    }

    func setCustomVideoOutputMode(_ mode: BroadcastRecordingProfile.OutputMode, source: String, reason: String) {
        guard state == .idle || state == .failed else {
            recordDebug("Custom recording mode change ignored while recording")
            return
        }
        let previous = customVideoOutputMode
        guard previous != mode else { return }
        customVideoOutputMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.customVideoOutputModeDefaultsKey)
        applyCustomVideoPolicyProjection(reason: reason)
        applyRecordingProfile()
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "recording_output_mode_changed",
            entityID: "recording-output-policy",
            previous: ["mode": previous.rawValue],
            next: ["mode": mode.rawValue, "minimumRecommendedMbps": String(mode.recommendedMinimumBitrateMbps)],
            source: source,
            reason: reason
        )
    }

    func setCustomVideoCodec(_ codec: BroadcastRecordingProfile.Codec, source: String, reason: String) {
        guard state == .idle || state == .failed else {
            recordDebug("Custom recording codec change ignored while recording")
            return
        }
        let applied: BroadcastRecordingProfile.Codec = codec == .h265 && !supportsHEVCRecording ? .h264 : codec
        let previous = customVideoCodec
        guard previous != applied else { return }
        customVideoCodec = applied
        UserDefaults.standard.set(applied.rawValue, forKey: Self.customVideoCodecDefaultsKey)
        applyCustomVideoPolicyProjection(reason: reason)
        applyRecordingProfile()
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "recording_custom_codec_changed",
            entityID: "recording-output-policy",
            previous: ["codec": previous.rawValue],
            next: ["requested": codec.rawValue, "applied": applied.rawValue],
            source: source,
            reason: codec == applied ? reason : "HEVC unsupported; H.264 fallback applied"
        )
    }

    func setCustomVideoBitrateMbps(_ value: Int, source: String, reason: String) {
        guard state == .idle || state == .failed else {
            recordDebug("Custom recording bitrate change ignored while recording")
            return
        }
        let clamped = min(max(value, Self.minimumCustomVideoBitrateMbps), Self.maximumCustomVideoBitrateMbps)
        let previous = customVideoBitrateMbps
        guard previous != clamped else { return }
        customVideoBitrateMbps = clamped
        UserDefaults.standard.set(clamped, forKey: Self.customVideoBitrateMbpsDefaultsKey)
        applyCustomVideoPolicyProjection(reason: reason)
        applyRecordingProfile()
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "recording_average_bitrate_changed",
            entityID: "recording-output-policy",
            previous: ["mbps": String(previous)],
            next: ["mbps": String(clamped)],
            source: source,
            reason: reason
        )
    }

    /// Build 134: RecordingEngine accepts or rejects a master-quality bitrate
    /// recommendation at its existing writer boundary.
    @discardableResult
    func adoptRecommendedCustomVideoBitrate(_ value: Int, source: String, reason: String) -> Bool {
        let stateAllowsConfiguration = state == .idle || state == .failed
        let accepted = RinkLensCustomRecordingBitratePolicy.shouldAdoptRecommendation(
            customSettingsEnabled: customVideoSettingsEnabled,
            recordingStateAllowsConfiguration: stateAllowsConfiguration
        )
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "recording_recommended_bitrate_resolved",
            entityID: "recording-output-policy",
            previous: [
                "mbps": String(customVideoBitrateMbps),
                "state": state.rawValue,
                "customCompression": String(customVideoSettingsEnabled)
            ],
            next: [
                "requestedMbps": String(value),
                "accepted": String(accepted)
            ],
            source: source,
            reason: accepted
                ? reason
                : "Recommendation retained as guidance because RecordingEngine did not admit a mutable custom-compression transaction",
            authoritativeOwner: "RecordingEngine"
        )
        guard accepted else { return false }
        setCustomVideoBitrateMbps(value, source: source, reason: reason)
        return true
    }

    @available(*, deprecated, message: "Resolution is owned by the active Broadcast camera source in Build 707")
    func setRecordingResolution(_ resolution: BroadcastRecordingProfile.Resolution) {
        guard !RinkLensRiskFeaturePolicy.isEnabled(.cameraSourceRecordingProfileV5) else {
            recordDebug("Recording resolution request ignored; camera source owns output dimensions")
            return
        }
        recordingProfile.resolution = resolution
        applyRecordingProfile()
    }

    func installOCRRecoveryConvergenceHandler(
        _ handler: @escaping @Sendable (RinkLensOCRRecoveryRequirement) async -> RinkLensOCRBranchRecoveryResult
    ) {
        ocrRecoveryConvergenceHandler = handler
    }

    @available(*, deprecated, message: "Frame rate is owned by the active Broadcast camera source in Build 707")
    func setRecordingFrameRate(_ frameRate: BroadcastRecordingProfile.FrameRate) {
        guard !RinkLensRiskFeaturePolicy.isEnabled(.cameraSourceRecordingProfileV5) else {
            recordDebug("Recording FPS request ignored; camera source owns writer cadence")
            return
        }
        recordingProfile.frameRate = frameRate
        applyRecordingProfile()
    }

    func setRecordingCodec(_ codec: BroadcastRecordingProfile.Codec) {
        if RinkLensRiskFeaturePolicy.isEnabled(.customRecordingOutputProfileV15) {
            setCustomVideoCodec(codec, source: "Legacy recording codec control", reason: "Compatibility control forwarded to recording output owner")
            return
        }
        guard state == .idle || state == .failed else {
            recordDebug("Recording codec change ignored while recording")
            return
        }
        let previous = recordingProfile.codec
        guard previous != codec else { return }
        recordingProfile.codec = codec
        UserDefaults.standard.set(codec.rawValue, forKey: Self.recordingCodecDefaultsKey)
        applyRecordingProfile()
        updateRecordingFPSWarning()
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "recording_codec_changed",
            entityID: "encoder-policy",
            previous: ["codec": previous.rawValue],
            next: ["codec": codec.rawValue],
            source: "BroadcastRecordingManager",
            reason: "Operator changed recording codec"
        )
    }

    func setRecordingBitrate(_ bitrate: BroadcastRecordingProfile.Bitrate) {
        if RinkLensRiskFeaturePolicy.isEnabled(.customRecordingOutputProfileV15) {
            let mbps: Int
            switch bitrate {
            case .safe: mbps = 4
            case .medium: mbps = 8
            case .high: mbps = 14
            }
            setCustomVideoBitrateMbps(mbps, source: "Legacy recording bitrate control", reason: "Compatibility control forwarded to recording output owner")
            return
        }
        guard state == .idle || state == .failed else {
            recordDebug("Recording bitrate change ignored while recording")
            return
        }
        let previous = recordingProfile.bitrate
        guard previous != bitrate else { return }
        recordingProfile.bitrate = bitrate
        UserDefaults.standard.set(bitrate.rawValue, forKey: Self.recordingBitrateDefaultsKey)
        applyRecordingProfile()
        updateRecordingFPSWarning()
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "recording_bitrate_changed",
            entityID: "encoder-policy",
            previous: ["bitrate": previous.rawValue],
            next: ["bitrate": bitrate.rawValue],
            source: "BroadcastRecordingManager",
            reason: "Operator changed recording bitrate"
        )
    }

    @available(*, deprecated, message: "Broadcast stabilisation is owned by RinkLensCameraControlStore in Build 726")
    func setRecordingStabilisation(_ stabilisation: BroadcastRecordingProfile.Stabilisation) {
        guard !RinkLensRiskFeaturePolicy.isEnabled(.broadcastVideoStabilisationAuthorityV13) else {
            recordDebug("Legacy recording stabilisation request ignored; camera-control owner is authoritative")
            return
        }
        let previous = recordingProfile.stabilisation
        recordingProfile.stabilisation = stabilisation
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "legacy_recording_stabilisation_changed",
            entityID: "legacy-encoder-policy",
            previous: ["stabilisation": previous.rawValue],
            next: ["stabilisation": stabilisation.rawValue],
            source: "BroadcastRecordingManager",
            reason: "Build 725 rollback path"
        )
    }

    private func updateRecordingFPSWarning() {
        let actualText = recordingActualFPSText.replacingOccurrences(of: "fps", with: "")
        let ratioText = recordingCadenceRatioText.replacingOccurrences(of: "%", with: "")
        guard let actual = Double(actualText), actual > 0,
              let cadencePercent = Double(ratioText), cadencePercent > 0 else {
            recordingFPSWarningText = Self.recordingFPSPendingText
            return
        }
        // Recovery D / RL-039: a file that deliberately switches 60->30->60
        // cannot be judged by comparing whole-file average FPS with the final
        // segment's current target. RecordingWriter.cadenceRatio is the weighted
        // expected-frame budget across every verified segment. actualFPS remains
        // visible as the truthful whole-file average.
        if cadencePercent < 95.0 {
            recordingFPSWarningText = String(
                format: "Cadence warning: %.1f%% of the verified lens-segment budget; file average %.1ffps.",
                cadencePercent,
                actual
            )
        } else {
            recordingFPSWarningText = String(
                format: "Cadence healthy — %.1f%% of verified lens-segment budget; file average %.1ffps.",
                cadencePercent,
                actual
            )
        }
    }

    func setRecordingBroadcastTransformCorrection(_ degrees: Int) {
        let allowed = [0, 90, 180, 270]
        guard allowed.contains(degrees) else { return }
        recordingBroadcastTransformCorrectionDegrees = degrees
        recordingTransformSourceText = broadcastTransformSummary(liveRotationDegrees: 0, usingOCRFallback: false)
        recordDebug("Recording whole-export orientation correction set to \(degrees)°")
    }

    func recordingDisplayRotation(liveRotationDegrees: Double, usingOCRFallback: Bool) -> Double {
        // v0.8.8l: camera layer rotation only. Do not add a fixed 180° raw-frame
        // correction here. The cached recording frame is rendered into the final
        // broadcast composite and should follow the same visible Broadcast camera
        // rotation. Manual correction remains a final whole-export transform.
        let baseRotation = usingOCRFallback ? 0.0 : liveRotationDegrees
        return Self.normalizedDegrees(baseRotation + Self.rawRecordingFrameToBroadcastDegrees)
    }

    func recordingCompositeCorrectionDegrees() -> Double {
        Double(recordingBroadcastTransformCorrectionDegrees)
    }

    func broadcastTransformSummary(liveRotationDegrees: Double, usingOCRFallback: Bool) -> String {
        let cameraRotation = recordingDisplayRotation(liveRotationDegrees: liveRotationDegrees, usingOCRFallback: usingOCRFallback)
        let source = usingOCRFallback ? "OCR fallback" : "Broadcast live preview"
        let finalCorrection = recordingBroadcastTransformCorrectionDegrees
        recordingRawFrameCorrectionText = "camera source correction: \(Int(Self.rawRecordingFrameToBroadcastDegrees))°; final buffer preserves broadcast composite"
        if finalCorrection == 0 {
            return "\(source): visible \(Int(liveRotationDegrees.rounded()))° + source 0° = camera \(Int(cameraRotation.rounded()))°; whole export 0°"
        }
        return "\(source): visible \(Int(liveRotationDegrees.rounded()))° + source 0° = camera \(Int(cameraRotation.rounded()))°; whole export correction \(finalCorrection)°"
    }

    private nonisolated static func normalizedDegrees(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        return value
    }


    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let manager = self else { return }
            Task { @MainActor [manager] in
                manager.updateElapsed()
            }
        }
    }

    private func stopTimers() {
        elapsedTimer?.invalidate()
        overlayRefreshTimer?.invalidate()
        elapsedTimer = nil
        overlayRefreshTimer = nil
        renderLoopModeText = "RecordingWriter stopped"
    }

    private func updateElapsed() {
        guard let recordingStartedAt else {
            elapsedText = "00:00"
            return
        }
        let seconds = max(0, Int(Date().timeIntervalSince(recordingStartedAt)))
        elapsedText = String(format: "%02d:%02d", seconds / 60, seconds % 60)
        if let lastFrameAt {
            lastFrameAgeText = String(format: "%.1fs", Date().timeIntervalSince(lastFrameAt))
        }
    }







private struct SessionFolders: Sendable {
        let baseFolder: URL
        let staging: URL
        let recordings: URL
        let manualHighlights: URL
        let autoHighlights: URL
        let logs: URL
    }

    private func preservePartialRecordingFile() -> Bool {
        guard let sourceURL = currentRecordingURL,
              FileManager.default.fileExists(atPath: sourceURL.path) else { return false }
        do {
            let folders = try ensureSessionFolders()
            let stem = sourceURL.deletingPathExtension().lastPathComponent
            let ext = sourceURL.pathExtension.isEmpty ? "mp4" : sourceURL.pathExtension
            var destination = folders.recordings.appendingPathComponent("\(stem)_partial.\(ext)")
            var suffix = 1
            while FileManager.default.fileExists(atPath: destination.path) {
                destination = folders.recordings.appendingPathComponent("\(stem)_partial_\(suffix).\(ext)")
                suffix += 1
            }
            if sourceURL.standardizedFileURL != destination.standardizedFileURL {
                try FileManager.default.moveItem(at: sourceURL, to: destination)
            }
            currentRecordingURL = destination
            mediaRepository.noteLocalMediaSaved(url: destination, albumName: Self.recordingsAlbumName)
            recordDebug("Partial recording preserved in app Files: \(destination.lastPathComponent)")
            return true
        } catch {
            recordDebug("Partial recording preservation failed: \(error.localizedDescription)")
            return FileManager.default.fileExists(atPath: sourceURL.path)
        }
    }

    private func ensureSessionFolders() throws -> SessionFolders {
        if let preparedSessionFolders { return preparedSessionFolders }
        let folders = try Self.createSessionFolders()
        preparedSessionFolders = folders
        return folders
    }

    private nonisolated static func prepareSessionFoldersOffMain() async throws -> SessionFolders {
        try await Task.detached(priority: .utility) {
            try Self.createSessionFolders()
        }.value
    }

    private nonisolated static func discoverInterruptedLogicalRecordingsOffMain() async -> [(url: URL, manifest: RinkLensLogicalRecordingManifest, existingSegments: [URL])] {
        await Task.detached(priority: .utility) {
            guard let documents = try? FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            ) else { return [] }
            let root = documents.appendingPathComponent("LiveRinkLensLive", isDirectory: true)
            return RinkLensLogicalRecordingManifest.discover(in: root).map { entry in
                (
                    url: entry.url,
                    manifest: entry.manifest,
                    existingSegments: entry.manifest.segments.filter {
                        FileManager.default.fileExists(atPath: $0.path)
                    }
                )
            }
        }.value
    }

    private nonisolated static func createSessionFolders() throws -> SessionFolders {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let base = documents.appendingPathComponent("LiveRinkLensLive", isDirectory: true)
        let staging = base.appendingPathComponent("Staging", isDirectory: true)
        let recordings = base.appendingPathComponent(Self.recordingsAlbumName, isDirectory: true)
        let manualHighlights = base.appendingPathComponent(Self.manualHighlightsAlbumName, isDirectory: true)
        let autoHighlights = base.appendingPathComponent(Self.autoHighlightsAlbumName, isDirectory: true)
        let logs = base.appendingPathComponent(Self.logsFolderName, isDirectory: true)
        for folder in [base, staging, recordings, manualHighlights, autoHighlights, logs] {
            if !FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
        }
        return SessionFolders(baseFolder: base, staging: staging, recordings: recordings, manualHighlights: manualHighlights, autoHighlights: autoHighlights, logs: logs)
    }

    func requestPhotoLibraryAccessIfNeeded() { mediaRepository.requestPhotoLibraryAccessIfNeeded() }

    func refreshPhotoLibraryStatus() { mediaRepository.refreshPhotoLibraryStatus() }
    func refreshSavedMediaCounts() { mediaRepository.refreshSavedCountsFromDisk() }

    func requestPhotoLibraryAccess() { mediaRepository.requestPhotoLibraryAccess() }

    func ensurePhotoAlbumsExist() { mediaRepository.ensurePhotoAlbumsExist() }

    private func queueVideoToPhotosAlbum(
        url: URL,
        albumName: String,
        mediaKind: String,
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        mediaRepository.noteLocalMediaSaved(url: url, albumName: albumName)
        mediaRepository.saveVideo(url: url, albumName: albumName, mediaKind: mediaKind) { [weak self] success, error in
            Task { @MainActor [weak self] in
                if !success, let error {
                    self?.lastErrorMessage = error.localizedDescription
                    self?.recordDebug("recording photos save failed: \(error.localizedDescription)")
                }
                completion?(success)
            }
        }
    }

    private func automaticClipPersistenceCompletion() -> (Result<ClipExportResult, Error>) -> Void {
        { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let export):
                self.queueVideoToPhotosAlbum(
                    url: export.url,
                    albumName: Self.autoHighlightsAlbumName,
                    mediaKind: "automatic highlight"
                ) { [weak self] success in
                    if success { self?.clipEngine.acknowledgePermanentPhotosPersistence(localURL: export.url) }
                }
            case .failure(let error):
                self.recordDebug("automatic clip export failed: \(error.localizedDescription)")
            }
        }
    }

    func openPhotosApp() { mediaRepository.openPhotosApp() }

    func clearOperatorRequestedLocalMedia() async -> RinkLensStorageClearResult {
        guard state == .idle || state == .failed,
              !RinkLensRecordingCaptureLease.shared.isWriterContractOpen(),
              !RinkLensRecordingCaptureLease.shared.isRecordingActive() else {
            return .blocked("Stop recording before clearing local media.")
        }
        let clips = await clipEngine.clearOperatorRequestedLocalClipMedia()
        if let reason = clips.blockedReason {
            return .init(files: clips.files, bytes: clips.bytes, blockedReason: reason)
        }
        let recordings = await mediaRepository.clearOperatorRequestedLocalRecordings()
        return .init(
            files: clips.files + recordings.files,
            bytes: clips.bytes + recordings.bytes,
            blockedReason: recordings.blockedReason
        )
    }

    func openAppSettings() { mediaRepository.openAppSettings() }


    private func safeFilename(prefix: String, homeTeam: String, awayTeam: String, ext: String) -> String {
        let teams = "\(homeTeam)_vs_\(awayTeam)".replacingOccurrences(of: " ", with: "_")
        let safeTeams = teams.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_- ")).inverted).joined()
        return "\(Self.timestampFormatter.string(from: Date()))_\(safeTeams)_\(prefix).\(ext)"
    }

    private func recordDebug(_ message: String) {
        lastDebugMessage = message
        MainThreadStallMonitor.shared.markContext("Recording: \(message)")
    }

    private func writeSessionLog(event: String, details: String) {
        sessionLog.append("\(Self.isoFormatter.string(from: Date())) | \(event) | \(details)")
        if sessionLog.count > 200 { sessionLog.removeFirst(sessionLog.count - 200) }
    }

    private func flushSessionLog() {
        guard let folder = currentSessionFolder?.appendingPathComponent(Self.logsFolderName, isDirectory: true) else { return }
        let url = folder.appendingPathComponent("recording_session.log")
        let body = sessionLog.joined(separator: "\n")
        let rowCount = sessionLog.count
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "recording_session_log_persist_scheduled",
            entityID: url.lastPathComponent,
            previous: ["persisted": "pending"],
            next: ["rows": String(rowCount), "queue": "recording.session-log"],
            source: "RecordingEngine.flushSessionLog",
            reason: "Recording finalisation must not perform file I/O on MainActor",
            authoritativeOwner: "RecordingEngine"
        )
        Self.sessionLogPersistenceQueue.async {
            do {
                if !FileManager.default.fileExists(atPath: folder.path) {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                }
                try body.write(to: url, atomically: true, encoding: .utf8)
                RinkLensStructuredEventLogger.shared.record(
                    domain: .recording,
                    event: "recording_session_log_persist_completed",
                    entityID: url.lastPathComponent,
                    previous: ["persisted": "pending"],
                    next: ["persisted": "true", "rows": String(rowCount)],
                    source: "RecordingEngine.sessionLogPersistenceQueue",
                    reason: "Background recording session-log write completed",
                    authoritativeOwner: "RecordingEngine"
                )
            } catch {
                RinkLensStructuredEventLogger.shared.record(
                    domain: .recording,
                    event: "recording_session_log_persist_failed",
                    entityID: url.lastPathComponent,
                    previous: ["persisted": "pending"],
                    next: ["persisted": "false", "error": error.localizedDescription],
                    source: "RecordingEngine.sessionLogPersistenceQueue",
                    reason: "Background recording session-log write failed",
                    authoritativeOwner: "RecordingEngine"
                )
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = ISO8601DateFormatter()

}
/// Temporary type bridge for files governed by later UX16d stages.
/// Delete after call sites migrate during UX16d6/UX16d7.
typealias BroadcastRecordingManager = RecordingEngine

#endif
