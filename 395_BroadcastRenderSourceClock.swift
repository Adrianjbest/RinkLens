// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation
import SwiftUI
import UIKit
@preconcurrency import AVFoundation
import CoreVideo
import CoreImage
#if canImport(VideoToolbox)
import VideoToolbox
#endif

// MARK: - UX16d3 authoritative recording writer

nonisolated private struct RecordingAPUncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

struct RecordingWriterProgress: @unchecked Sendable {
    let framesWritten: Int
    let framesDropped: Int
    let cameraSourceDrops: Int
    let sourceSamplingMisses: Int
    let writerDrops: Int
    let renderDrops: Int
    let ingressDiagnosticsText: String
    let blackFramesRejected: Int
    let blackFramesDetected: Int
    let blackFramesContinuityAccepted: Int
    let actualFPS: Double
    let sourceFPS: Double
    let cadenceRatio: Double
    let activeDurationSeconds: TimeInterval
    let pollingFPS: Double
    let renderDurationMS: Double
    let sourceDescription: String
    let frameValidationText: String
    let lastWrittenAt: Date?
    let writerBacklog: Int
    let lastDecision: String
    let healthText: String
}

nonisolated enum RecordingForcedFailureKind: String, Sendable {
    case sourceLoss
    case severeCadenceCollapse
    case encoderFailure
}

/// Pure terminal-transition policy used by the writer and its regression tests.
nonisolated enum RecordingWriterTerminalPolicy {
    static func mustTerminateAfterAppend(appendSucceeded: Bool, writerStatus: AVAssetWriter.Status) -> Bool {
        if appendSucceeded { return false }
        switch writerStatus {
        case .failed, .cancelled:
            return true
        case .unknown, .writing, .completed:
            // A passthrough AVAssetWriterInput append returning false is not a
            // backpressure signal. isReadyForMoreMediaData was checked before
            // append, therefore the failed append is terminal for this session.
            return true
        @unknown default:
            return true
        }
    }
}

nonisolated enum RecordingCadenceTruthDisposition: Equatable, Sendable {
    case healthy
    case warning
    case terminal
}

nonisolated struct RecordingCadenceTruthDecision: Equatable, Sendable {
    let disposition: RecordingCadenceTruthDisposition
    let requiredDuration: TimeInterval
    let diagnostic: String
}

/// Pure cadence truth policy. Callback cadence is one signal; a recording is
/// terminal only when fresh-frame continuity and encoded output also collapse.
nonisolated enum RecordingCadenceTruthPolicy {
    static func evaluate(
        targetFPS: Double,
        sourceFPS: Double,
        outputFPS: Double,
        sourceAgeSeconds: TimeInterval,
        sourceMaximumAge: TimeInterval,
        severeDuration: TimeInterval
    ) -> RecordingCadenceTruthDecision {
        let sourceFresh = sourceAgeSeconds <= max(sourceMaximumAge * 2.0, 0.35)
        let outputHealthy = outputFPS >= targetFPS * 0.92
        let outputCollapsed = outputFPS < targetFPS * 0.85
        // A fresh camera frame at a reduced cadence is still valid recording
        // content. The previous policy treated a sustained 25-30 fps delivery
        // while 60 fps was requested as physical source loss, stopped a usable
        // recording and created a recovery file. Availability is established by
        // freshness; cadence shortfall remains warning telemetry. Only an
        // actually stale source plus collapsed output may terminate the file.
        let sourceOperationallyLost = !sourceFresh

        if sourceFresh && outputHealthy {
            return RecordingCadenceTruthDecision(
                disposition: .healthy,
                requiredDuration: 0,
                diagnostic: String(
                    format: "transient callback slowdown %.1ffps; output %.1ffps freshAge %.3fs remains healthy",
                    sourceFPS,
                    outputFPS,
                    sourceAgeSeconds
                )
            )
        }

        let requiredDuration: TimeInterval = sourceOperationallyLost && outputCollapsed ? 6 : 15
        if severeDuration < requiredDuration || !outputCollapsed || !sourceOperationallyLost {
            return RecordingCadenceTruthDecision(
                disposition: .warning,
                requiredDuration: requiredDuration,
                diagnostic: String(
                    format: "source/output warning source=%.1ffps output=%.1ffps freshAge=%.3fs for %.1fs/%.1fs",
                    sourceFPS,
                    outputFPS,
                    sourceAgeSeconds,
                    severeDuration,
                    requiredDuration
                )
            )
        }

        return RecordingCadenceTruthDecision(
            disposition: .terminal,
            requiredDuration: requiredDuration,
            diagnostic: String(
                format: "source and output collapsed source=%.1ffps output=%.1ffps freshAge=%.3fs for %.1fs",
                sourceFPS,
                outputFPS,
                sourceAgeSeconds,
                severeDuration
            )
        )
    }
}

struct RecordingWriterResult: @unchecked Sendable {
    let framesWritten: Int
    let framesDropped: Int
    let cameraSourceDrops: Int
    let sourceSamplingMisses: Int
    let writerDrops: Int
    let renderDrops: Int
    let ingressDiagnosticsText: String
    let blackFramesRejected: Int
    let blackFramesDetected: Int
    let blackFramesContinuityAccepted: Int
    let actualFPS: Double
    let sourceFPS: Double
    let cadenceRatio: Double
    let activeDurationSeconds: TimeInterval
    let pollingFPS: Double
    let writerStatus: AVAssetWriter.Status
    let errorDescription: String?
    let forcedFailureKind: RecordingForcedFailureKind?
    let forcedFailureReason: String?
    let partialFilePreserved: Bool
}

struct RecordingWriterConfiguration: @unchecked Sendable {
    let outputURL: URL
    let outputSize: CGSize
    let cadence: RinkLensCaptureCadence
    let codec: AVVideoCodecType
    let bitrate: Int
    let frameSource: BroadcastRecordingPixelBufferFrameSourceContext
    let clipEngine: ClipEngine
    let sourceMaximumAge: TimeInterval
    let minimumHealthyFrameRatio: Double

    var fps: Int32 { Int32(cadence.nominalFPS) }
    var exactFPS: Double { cadence.framesPerSecond }
}

nonisolated struct RecordingWriterCadenceSnapshot: Sendable, Equatable {
    let cadence: RinkLensCaptureCadence
    let captureGeneration: Int
    let physicalDeviceID: String
    let transactionID: UUID
    let appliedAtUptimeNanoseconds: UInt64
}

nonisolated struct RecordingCadenceTransitionOutcome: Sendable {
    let succeeded: Bool
    let previousCadence: RinkLensCaptureCadence
    let appliedSnapshot: RecordingWriterCadenceSnapshot?
    let errorText: String?
}

struct RecordingWriterCallbacks: @unchecked Sendable {
    let onStarted: @MainActor @Sendable () -> Void
    let onProgress: @MainActor @Sendable (RecordingWriterProgress) -> Void
    let onFinished: @MainActor @Sendable (RecordingWriterResult) -> Void
    let onFailure: @MainActor @Sendable (String) -> Void
}

// MARK: - Recovery AP dedicated compression authority

/// Recovery AP / RL-091 separates compression from file muxing.
///
/// Ownership contract:
/// - this object is the sole owner of VTCompressionSession;
/// - RecordingWriter owns only the output file / AVAssetWriterInput and appends
///   already-compressed CMSampleBuffers;
/// - CaptureEngine and FrameHub remain completely outside this owner;
/// - there is no speculative encoder acquisition from Command Centre.
nonisolated final class RecordingCompressionEngine: @unchecked Sendable {
    private let stateLock = NSLock()
    private let controlLock = NSLock()
    private let flushQueue = DispatchQueue(label: "rinklens.recording.compression.flush", qos: RinkLensExecutionQoSHierarchy.recording)
    private var session: VTCompressionSession?
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var codecType: CMVideoCodecType = kCMVideoCodecType_H264
    private var bitrate: Int = 0
    private var inFlight = 0
    private var lastEncodedPresentationTime: CMTime?

    var inFlightCount: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return inFlight
    }

    /// Creates and prepares the one match-session compressor, or reuses it when
    /// the immutable dimensions/codec/bitrate contract is unchanged.  Preparation
    /// is deliberately separate from AVAssetWriter file creation.
    func beginSession(
        outputSize: CGSize,
        codec: AVVideoCodecType,
        bitrate: Int,
        expectedFPS: Double
    ) throws -> CVPixelBufferPool? {
        controlLock.lock()
        defer { controlLock.unlock() }

        let requestedWidth = Int32(outputSize.width.rounded())
        let requestedHeight = Int32(outputSize.height.rounded())
        guard requestedWidth > 0, requestedHeight > 0 else {
            throw NSError(
                domain: "RinkLens.RecordingCompressionEngine",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid compression dimensions \(requestedWidth)x\(requestedHeight)."]
            )
        }
        let requestedCodec: CMVideoCodecType = codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264

        stateLock.lock()
        let reusable = session != nil
            && width == requestedWidth
            && height == requestedHeight
            && codecType == requestedCodec
            && self.bitrate == bitrate
        let existing = session
        stateLock.unlock()

        if reusable, let existing {
            // A hardware VideoToolbox session can be invalidated while the app
            // is backgrounded even though our Swift reference remains non-nil.
            // Prepare is the physical acknowledgement boundary; never reuse a
            // reference that the codec no longer accepts.
            let reuseStatus = VTCompressionSessionPrepareToEncodeFrames(existing)
            guard reuseStatus == noErr else {
                RinkLensStructuredEventLogger.shared.record(
                    domain: .recording,
                    event: "recording_compression_session_reuse_rejected",
                    entityID: "\(requestedWidth)x\(requestedHeight)",
                    previous: ["sessionReference": "present", "prepareStatus": String(reuseStatus)],
                    next: ["sessionReference": "recreate"],
                    source: "RecordingCompressionEngine.beginSession",
                    reason: "Physical VideoToolbox acknowledgement rejected the retained session",
                    authoritativeOwner: "RecordingCompressionEngine"
                )
                invalidateLocked(reason: "VideoToolbox rejected retained session OSStatus=\(reuseStatus)")
                return try beginSessionAfterControlLock(
                    requestedWidth: requestedWidth,
                    requestedHeight: requestedHeight,
                    requestedCodec: requestedCodec,
                    codec: codec,
                    bitrate: bitrate,
                    expectedFPS: expectedFPS
                )
            }
            _ = VTSessionSetProperty(
                existing,
                key: kVTCompressionPropertyKey_ExpectedFrameRate,
                value: NSNumber(value: max(1.0, expectedFPS))
            )
            RinkLensStructuredEventLogger.shared.record(
                domain: .recording,
                event: "recording_compression_session_reused",
                entityID: "\(requestedWidth)x\(requestedHeight)",
                previous: ["compressionOwner": "RecordingCompressionEngine/VTCompressionSession"],
                next: [
                    "sessionLifetime": "match",
                    "expectedFPS": String(format: "%.2f", expectedFPS),
                    "fileWriterCompression": "none"
                ],
                source: "RecordingCompressionEngine.beginSession",
                reason: "Recovery AP reuses the prepared match-session encoder across recording files",
                authoritativeOwner: "RecordingCompressionEngine"
            )
            return VTCompressionSessionGetPixelBufferPool(existing)
        }

        invalidateLocked(reason: "Recovery AP compression contract changed")
        return try beginSessionAfterControlLock(
            requestedWidth: requestedWidth,
            requestedHeight: requestedHeight,
            requestedCodec: requestedCodec,
            codec: codec,
            bitrate: bitrate,
            expectedFPS: expectedFPS
        )
    }

    /// Caller holds controlLock. Split out so a rejected retained session can
    /// be replaced in the same owner transaction without recursive locking.
    private func beginSessionAfterControlLock(
        requestedWidth: Int32,
        requestedHeight: Int32,
        requestedCodec: CMVideoCodecType,
        codec: AVVideoCodecType,
        bitrate: Int,
        expectedFPS: Double
    ) throws -> CVPixelBufferPool? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
            kCVPixelBufferWidthKey as String: Int(requestedWidth),
            kCVPixelBufferHeightKey as String: Int(requestedHeight),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var created: VTCompressionSession?
        let createStarted = CFAbsoluteTimeGetCurrent()
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: requestedWidth,
            height: requestedHeight,
            codecType: requestedCodec,
            encoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        let createMS = max(0, (CFAbsoluteTimeGetCurrent() - createStarted) * 1_000)
        guard status == noErr, let created else {
            throw NSError(
                domain: "RinkLens.RecordingCompressionEngine",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "VideoToolbox compression session creation failed OSStatus=\(status)."]
            )
        }

        _ = VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        _ = VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        _ = VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: NSNumber(value: 1))
        _ = VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
        _ = VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: max(1.0, expectedFPS)))

        let prepareStarted = CFAbsoluteTimeGetCurrent()
        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(created)
        let prepareMS = max(0, (CFAbsoluteTimeGetCurrent() - prepareStarted) * 1_000)
        guard prepareStatus == noErr else {
            VTCompressionSessionInvalidate(created)
            throw NSError(
                domain: "RinkLens.RecordingCompressionEngine",
                code: Int(prepareStatus),
                userInfo: [NSLocalizedDescriptionKey: "VideoToolbox encoder preparation failed OSStatus=\(prepareStatus)."]
            )
        }

        stateLock.lock()
        self.session = created
        self.width = requestedWidth
        self.height = requestedHeight
        self.codecType = requestedCodec
        self.bitrate = bitrate
        self.inFlight = 0
        stateLock.unlock()

        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "recording_compression_session_created",
            entityID: "\(requestedWidth)x\(requestedHeight)",
            previous: ["compressionOwner": "AVAssetWriterInput outputSettings"],
            next: [
                "compressionOwner": "RecordingCompressionEngine/VTCompressionSession",
                "sessionLifetime": "match",
                "codec": codec.rawValue,
                "bitrate": String(bitrate),
                "expectedFPS": String(format: "%.2f", expectedFPS),
                "createMs": String(format: "%.1f", createMS),
                "prepareMs": String(format: "%.1f", prepareMS),
                "fileWriterCompression": "none"
            ],
            source: "RecordingCompressionEngine.beginSession",
            reason: "Recovery AP RL-091 separates encoder lifetime from AVAssetWriter file muxing",
            authoritativeOwner: "RecordingCompressionEngine"
        )
        return VTCompressionSessionGetPixelBufferPool(created)
    }

    func updateExpectedFrameRate(_ fps: Double) {
        stateLock.lock()
        let session = self.session
        stateLock.unlock()
        guard let session else { return }
        _ = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: NSNumber(value: max(1.0, fps))
        )
    }

    /// Maintains one monotonic encoder timeline across successive file muxers.
    /// Each AVAssetWriter starts its own session at that file's first compressed
    /// sample, while the persistent VTCompressionSession never sees time move backwards.
    func monotonicPresentationTime(candidate: CMTime, duration: CMTime) -> CMTime {
        stateLock.lock()
        defer { stateLock.unlock() }
        var resolved = candidate
        if let lastEncodedPresentationTime,
           CMTimeCompare(resolved, lastEncodedPresentationTime) <= 0 {
            resolved = CMTimeAdd(lastEncodedPresentationTime, duration)
        }
        self.lastEncodedPresentationTime = resolved
        return resolved
    }

    @discardableResult
    func encode(
        pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime,
        duration: CMTime,
        forceKeyFrame: Bool,
        outputHandler: @escaping @Sendable (OSStatus, VTEncodeInfoFlags, CMSampleBuffer?) -> Void
    ) -> Bool {
        stateLock.lock()
        guard let session = self.session, inFlight < 3 else {
            stateLock.unlock()
            return false
        }
        inFlight += 1
        stateLock.unlock()

        let frameProperties: CFDictionary? = forceKeyFrame
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue as Any] as CFDictionary
            : nil
        var infoFlags = VTEncodeInfoFlags()
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: duration,
            frameProperties: frameProperties,
            infoFlagsOut: &infoFlags
        ) { [weak self] status, flags, sampleBuffer in
            guard let self else { return }
            self.stateLock.lock()
            self.inFlight = max(0, self.inFlight - 1)
            self.stateLock.unlock()
            outputHandler(status, flags, sampleBuffer)
        }
        if status != noErr {
            stateLock.lock()
            inFlight = max(0, inFlight - 1)
            stateLock.unlock()
            outputHandler(status, infoFlags, nil)
            return false
        }
        return true
    }

    func completeFrames(completion: @escaping @Sendable (OSStatus) -> Void) {
        stateLock.lock()
        let session = self.session
        stateLock.unlock()
        guard let session else {
            completion(noErr)
            return
        }
        let sessionBox = RecordingAPUncheckedSendable(value: session)
        flushQueue.async {
            let status = VTCompressionSessionCompleteFrames(sessionBox.value, untilPresentationTimeStamp: .invalid)
            completion(status)
        }
    }

    func invalidate(reason: String) {
        controlLock.lock()
        defer { controlLock.unlock() }
        invalidateLocked(reason: reason)
    }

    private func invalidateLocked(reason: String) {
        stateLock.lock()
        let previous = session
        session = nil
        inFlight = 0
        width = 0
        height = 0
        bitrate = 0
        lastEncodedPresentationTime = nil
        stateLock.unlock()
        if let previous {
            VTCompressionSessionInvalidate(previous)
            MainThreadStallMonitor.traceFromAnyQueue(
                "Recovery AP compression session invalidated: \(reason)"
            )
        }
    }
}


/// Authoritative serial recording writer introduced by UX16d3.
///
/// Ownership contract:
/// - AVAssetWriter passthrough muxing, capture-event rendering, Core Image
///   composition and compressed-sample append remain on `queue`.
/// - the MainActor receives only throttled immutable progress snapshots;
/// - no SwiftUI/ViewModel access occurs from the per-frame hot path;
/// - the output file, codec and dimensions are immutable for the recording;
///   CaptureLifecycleController may rebind the verified Broadcast device/cadence.
nonisolated final class RecordingWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "rinklens.recording.writer", qos: RinkLensExecutionQoSHierarchy.recording)
    private let compressionEngine: RecordingCompressionEngine
    private var compressionPixelBufferPool: CVPixelBufferPool?
    // Recovery AS / RL-096: producer-owned FrameHub leases end at the recording
    // ingress boundary. The writer has its own three-surface pool: one frame may
    // be active, one newest frame may be pending, and one spare permits atomic
    // pending replacement without ever blocking CaptureEngine's six-surface pool.
    private let recordingIngressPool = RinkLensFrameHubOwnedBufferPool(minimumBufferCount: 2, allocationThreshold: 3)
    private let captureIngressLock = NSLock()
    private var captureIngressBusy = false
    private var captureIngressPending: BroadcastRecordingPixelBufferFrame?
    private var captureIngressFrameSource: BroadcastRecordingPixelBufferFrameSourceContext?
    // Recovery AW / RL-107: callback admission is closed before any pixel copy
    // whenever the writer is paused, stopping, or owned by an optical transition.
    // Queue-owned writer state is never read from the AVCapture callback thread.
    private var captureIngressAcceptingFrames = false
    private var captureIngressTransitionBlocked = false
    private var captureIngressSubmittedCount = 0
    private var captureIngressCopiedCount = 0
    private var captureIngressReplacedCount = 0
    private var captureIngressRejectedCount = 0
    private var captureIngressPoolDropCount = 0
    private var captureIngressProcessedCount = 0
    private var captureIngressStateDiscardCount = 0
    private var captureIngressTransitionDiscardCount = 0
    private var captureIngressClearedPendingCount = 0
    private var captureIngressCopyLastMilliseconds: Double = 0
    private var captureIngressCopyMaxMilliseconds: Double = 0
    private var captureIngressPoolAcquireMaxMilliseconds: Double = 0
    private var captureIngressPixelCopyMaxMilliseconds: Double = 0
    private var captureIngressSourceLockMaxMilliseconds: Double = 0
    private var captureIngressDestinationLockMaxMilliseconds: Double = 0
    private var captureIngressMetadataMaxMilliseconds: Double = 0
    private var captureIngressSlowCopyCount = 0
    private var captureIngressMaxCopyBreakdown = "none"
    private var captureIngressMaxAdmissionAgeMilliseconds: Double = 0
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var writerSessionStarted = false
    private var configuration: RecordingWriterConfiguration?
    private var callbacks: RecordingWriterCallbacks?
    private var activeCadence: RinkLensCaptureCadence?
    private var activeCadenceSnapshot: RecordingWriterCadenceSnapshot?
    private var isRunning = false
    private var isPaused = false
    private var isCameraTransitionHeld = false
    private var cameraTransitionTransactionID: UUID?
    private var cameraTransitionBeganAt: Date?
    // One app-owned, fully composed programme surface is retained from the
    // VideoToolbox input pool. It is not an AVCapture buffer and it never owns
    // camera truth. During a physical branch handoff the writer re-encodes this
    // single surface at monotonic timestamps until the new generation is bound.
    private var cameraTransitionContinuityFrame: CVPixelBuffer?
    private var cameraTransitionContinuityTimer: DispatchSourceTimer?
    private var isStopping = false
    private var frameIndex: Int64 = 0
    private var framesWritten = 0
    private var framesDropped = 0
    private var cameraSourceDrops = 0
    private var sourceSamplingMisses = 0
    private var writerDrops = 0
    private var renderDrops = 0
    private var blackFramesRejected = 0
    private var blackFramesDetected = 0
    private var blackFramesContinuityAccepted = 0
    private var startedAt: Date?
    private var pauseBeganAt: Date?
    private var totalPausedDuration: TimeInterval = 0
    private var lastPresentationTime: CMTime?
    private var lastSuccessfulPresentationTime: CMTime?
    private var terminalWriterFailureEvidence: String?
    private var terminalCompletionDelivered = false
    private var lastProgressPublishedAt = Date.distantPast
    private var lastSourceSequence: Int?
    private var lastWrittenAt: Date?
    private var lastDecision = "idle"
    private var cadenceBelowThresholdSinceUptimeNanoseconds: UInt64?
    private var severeCadenceBelowThresholdSinceUptimeNanoseconds: UInt64?
    private var writtenFrameUptimes: [UInt64] = []
    private var sourceFrameUptimes: [UInt64] = []
    private var latestRollingCadenceFPS: Double = 0
    private var latestRollingSourceCadenceFPS: Double = 0
    private var lastUniqueSourceFrameUptimeNanoseconds: UInt64?
    private var pollingFPS: Double = 0
    private var forcedFailureKind: RecordingForcedFailureKind?
    private var hasLoggedFirstCompositor = false
    private var forcedFailureReason: String?
    private var hasSignalledStarted = false
    private var completedExpectedFrameBudget: Double = 0
    private var cadenceSegmentStartedActiveElapsed: TimeInterval = 0

    init(compressionEngine: RecordingCompressionEngine) {
        self.compressionEngine = compressionEngine
    }

    /// Starts the sole authoritative recording writer on its dedicated queue.
    func start(configuration: RecordingWriterConfiguration, callbacks: RecordingWriterCallbacks) {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isRunning, !self.isStopping else {
                self.publishFailure("Background recording worker is already active.", callbacks: callbacks)
                return
            }

            self.configuration = configuration
            self.callbacks = callbacks
            self.activeCadence = configuration.cadence
            self.activeCadenceSnapshot = nil
            self.isCameraTransitionHeld = false
            self.cameraTransitionTransactionID = nil
            self.cameraTransitionBeganAt = nil
            self.cameraTransitionContinuityFrame = nil
            self.stopCameraTransitionContinuityOnQueue()
            self.captureIngressLock.lock()
            self.captureIngressBusy = false
            self.captureIngressPending = nil
            self.captureIngressFrameSource = configuration.frameSource
            self.captureIngressAcceptingFrames = false
            self.captureIngressTransitionBlocked = false
            self.captureIngressSubmittedCount = 0
            self.captureIngressCopiedCount = 0
            self.captureIngressReplacedCount = 0
            self.captureIngressRejectedCount = 0
            self.captureIngressPoolDropCount = 0
            self.captureIngressProcessedCount = 0
            self.captureIngressStateDiscardCount = 0
            self.captureIngressTransitionDiscardCount = 0
            self.captureIngressClearedPendingCount = 0
            self.captureIngressCopyLastMilliseconds = 0
            self.captureIngressCopyMaxMilliseconds = 0
            self.captureIngressPoolAcquireMaxMilliseconds = 0
            self.captureIngressPixelCopyMaxMilliseconds = 0
            self.captureIngressSourceLockMaxMilliseconds = 0
            self.captureIngressDestinationLockMaxMilliseconds = 0
            self.captureIngressMetadataMaxMilliseconds = 0
            self.captureIngressSlowCopyCount = 0
            self.captureIngressMaxCopyBreakdown = "none"
            self.captureIngressMaxAdmissionAgeMilliseconds = 0
            self.captureIngressLock.unlock()
            let recordingIngressPreparation = self.recordingIngressPool.prepare(
                width: max(1, Int(configuration.outputSize.width.rounded())),
                height: max(1, Int(configuration.outputSize.height.rounded())),
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            )
            RinkLensStructuredEventLogger.shared.record(
                domain: .recording,
                event: "recording_ingress_pool_prepared",
                entityID: configuration.outputURL.lastPathComponent,
                previous: ["transport": "FrameHub producer lease retained by RecordingWriter"],
                next: [
                    "transport": "short FrameHub lease -> recording-owned three-surface pool",
                    "prepared": String(recordingIngressPreparation.preparedBufferCount),
                    "elapsedMs": String(format: "%.3f", recordingIngressPreparation.elapsedMilliseconds)
                ],
                source: "RecordingWriter.start",
                reason: "Recovery AS RL-096 separates producer FrameHub lifetime from recording lifetime",
                authoritativeOwner: "RecordingWriter"
            )
            self.completedExpectedFrameBudget = 0
            self.cadenceSegmentStartedActiveElapsed = 0
            self.frameIndex = 0
            self.framesWritten = 0
            self.framesDropped = 0
            self.cameraSourceDrops = 0
            self.sourceSamplingMisses = 0
            self.writerDrops = 0
            self.renderDrops = 0
            self.blackFramesRejected = 0
            self.blackFramesDetected = 0
            self.blackFramesContinuityAccepted = 0
            self.lastSourceSequence = nil
            self.lastWrittenAt = nil
            self.pauseBeganAt = nil
            self.totalPausedDuration = 0
            self.lastPresentationTime = nil
            self.lastSuccessfulPresentationTime = nil
            self.terminalWriterFailureEvidence = nil
            self.terminalCompletionDelivered = false
            self.lastDecision = "configuring background writer"
            self.cadenceBelowThresholdSinceUptimeNanoseconds = nil
            self.severeCadenceBelowThresholdSinceUptimeNanoseconds = nil
            self.writtenFrameUptimes.removeAll(keepingCapacity: true)
            self.sourceFrameUptimes.removeAll(keepingCapacity: true)
            self.latestRollingCadenceFPS = 0
            self.latestRollingSourceCadenceFPS = 0
            self.lastUniqueSourceFrameUptimeNanoseconds = nil
            self.pollingFPS = 0
            self.forcedFailureKind = nil
            self.forcedFailureReason = nil
            self.hasSignalledStarted = false
            self.hasLoggedFirstCompositor = false

            do {
                self.writer = nil
                self.writerInput = nil
                self.writerSessionStarted = false
                self.compressionPixelBufferPool = try self.compressionEngine.beginSession(
                    outputSize: configuration.outputSize,
                    codec: configuration.codec,
                    bitrate: configuration.bitrate,
                    expectedFPS: configuration.cadence.framesPerSecond
                )
                self.isRunning = true
                self.isPaused = false
                self.isStopping = false
                self.openCaptureIngressAdmissionIfEligible()
                self.startedAt = Date()
                self.lastDecision = "Recovery AW capture-driven writer ready; recording-owned ingress copy admitted only while writer is actively recording"
            } catch {
                self.releaseWriterState()
                self.publishFailure(error.localizedDescription, callbacks: callbacks)
            }
        }
    }

    /// An intentional operator/route pause is a media-time boundary, not bad
    /// source evidence. Close the current expected-frame segment when pausing
    /// and begin a fresh cadence-health segment when resuming so time spent with
    /// capture deliberately released can never mature into a fail-fast window.
    func setPaused(_ paused: Bool, reason: String) {
        // Close callback admission synchronously with the pause request so a busy
        // writer queue cannot keep allocating/copying 1080p frames while Paused.
        if paused {
            closeCaptureIngressAdmission(transitionBlocked: false, clearPending: true)
        }
        queue.async { [weak self] in
            guard let self, self.isRunning, !self.isStopping else { return }
            guard self.isPaused != paused else {
                if !paused { self.openCaptureIngressAdmissionIfEligible() }
                return
            }

            let now = Date()
            let nowUptime = DispatchTime.now().uptimeNanoseconds
            let previousSourceFPS = self.latestRollingSourceCadenceFPS
            let previousOutputFPS = self.latestRollingCadenceFPS
            let previousSevereSeconds: Double = self.severeCadenceBelowThresholdSinceUptimeNanoseconds.map {
                Double(nowUptime &- $0) / 1_000_000_000
            } ?? 0

            if paused {
                let activeElapsedBeforePause = self.activeElapsed(at: now)
                if let cadence = self.activeCadence ?? self.configuration?.cadence {
                    self.completedExpectedFrameBudget += max(
                        0,
                        activeElapsedBeforePause - self.cadenceSegmentStartedActiveElapsed
                    ) * cadence.framesPerSecond
                }
                self.cadenceSegmentStartedActiveElapsed = activeElapsedBeforePause
                self.pauseBeganAt = now
            } else {
                if let pauseBeganAt = self.pauseBeganAt {
                    self.totalPausedDuration += now.timeIntervalSince(pauseBeganAt)
                    self.pauseBeganAt = nil
                }
                // activeElapsed excludes the completed pause. Starting the new
                // segment here gives resumed capture the normal warm-up window.
                self.cadenceSegmentStartedActiveElapsed = self.activeElapsed(at: now)
            }

            self.isPaused = paused
            if !paused {
                self.openCaptureIngressAdmissionIfEligible()
            }
            self.cadenceBelowThresholdSinceUptimeNanoseconds = nil
            self.severeCadenceBelowThresholdSinceUptimeNanoseconds = nil
            self.writtenFrameUptimes.removeAll(keepingCapacity: true)
            self.sourceFrameUptimes.removeAll(keepingCapacity: true)
            self.latestRollingCadenceFPS = 0
            self.latestRollingSourceCadenceFPS = 0
            self.lastUniqueSourceFrameUptimeNanoseconds = nil
            self.lastSourceSequence = nil
            self.lastDecision = paused
                ? "paused; cadence-health evidence closed: \(reason)"
                : "resumed; cadence-health evidence rebased: \(reason)"

            RinkLensStructuredEventLogger.shared.record(
                domain: .recording,
                event: "recording_writer_pause_boundary_rebased",
                entityID: self.configuration?.outputURL.lastPathComponent,
                previous: [
                    "paused": String(!paused),
                    "sourceFPS": String(format: "%.1f", previousSourceFPS),
                    "outputFPS": String(format: "%.1f", previousOutputFPS),
                    "severeWindowSeconds": String(format: "%.2f", previousSevereSeconds)
                ],
                next: [
                    "paused": String(paused),
                    "sourceFPS": "0.0",
                    "outputFPS": "0.0",
                    "severeWindowSeconds": "0.00",
                    "cadenceWarmupRestarted": String(!paused)
                ],
                source: "RecordingWriter.setPaused",
                reason: reason,
                authoritativeOwner: "RecordingWriter"
            )
        }
    }

    /// Recovery B camera/lens transition hold. Append ticks are suspended on
    /// the capture-ingress boundary without changing the public Recording state
    /// or output file. The writer's capacity-one composed continuity surface keeps
    /// media flowing until the exact new generation is rebound.
    func setCameraTransitionHeld(_ held: Bool, transactionID: UUID) {
        if held {
            closeCaptureIngressAdmission(transitionBlocked: true, clearPending: true)
        }
        queue.sync { [weak self] in
            guard let self, self.isRunning, !self.isStopping else { return }
            if held {
                self.isCameraTransitionHeld = true
                self.cameraTransitionTransactionID = transactionID
                self.cameraTransitionBeganAt = Date()
                self.startCameraTransitionContinuityOnQueue(transactionID: transactionID)
                self.lastDecision = "capture-driven recording ingress held with capacity-one composed continuity transaction=\(transactionID.uuidString)"
            } else if self.cameraTransitionTransactionID == transactionID {
                self.stopCameraTransitionContinuityOnQueue()
                self.isCameraTransitionHeld = false
                self.cameraTransitionTransactionID = nil
                self.cameraTransitionBeganAt = nil
                self.cadenceSegmentStartedActiveElapsed = self.activeElapsed(at: Date())
                self.openCaptureIngressAdmissionIfEligible()
                self.lastDecision = "capture-driven recording ingress released transaction=\(transactionID.uuidString)"
            }
        }
    }

    /// Retargets only the writer pacer/cadence-health contract after the new
    /// CaptureEngine generation has been physically verified. AVAssetWriter,
    /// codec, dimensions and the current output URL remain unchanged.
    func applyVerifiedCadenceTransition(
        cadence: RinkLensCaptureCadence,
        captureGeneration: Int,
        physicalDeviceID: String,
        transactionID: UUID,
        completion: @escaping @MainActor @Sendable (RecordingCadenceTransitionOutcome) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let previous = self.activeCadence ?? self.configuration?.cadence ?? cadence
            guard self.isRunning, !self.isStopping else {
                let outcome = RecordingCadenceTransitionOutcome(
                    succeeded: false,
                    previousCadence: previous,
                    appliedSnapshot: nil,
                    errorText: "Recording writer is not open for a cadence transition"
                )
                Task { @MainActor in completion(outcome) }
                return
            }
            guard self.isCameraTransitionHeld,
                  self.cameraTransitionTransactionID == transactionID else {
                let outcome = RecordingCadenceTransitionOutcome(
                    succeeded: false,
                    previousCadence: previous,
                    appliedSnapshot: nil,
                    errorText: "Recording writer camera transition is not held by this transaction"
                )
                Task { @MainActor in completion(outcome) }
                return
            }
            if let applied = self.activeCadenceSnapshot,
               applied.transactionID == transactionID {
                let outcome = RecordingCadenceTransitionOutcome(
                    succeeded: true,
                    previousCadence: previous,
                    appliedSnapshot: applied,
                    errorText: nil
                )
                Task { @MainActor in completion(outcome) }
                return
            }

            let activeElapsed = self.activeElapsed(at: Date())
            // Recovery AQ: the optical handoff interval is intentionally excluded
            // from media time. Do not synthesize held frames and do not charge the
            // unavailable camera-switch interval against recording cadence health.
            self.completedExpectedFrameBudget += max(
                0,
                activeElapsed - self.cadenceSegmentStartedActiveElapsed
            ) * previous.framesPerSecond
            self.cadenceSegmentStartedActiveElapsed = activeElapsed
            self.activeCadence = cadence
            self.compressionEngine.updateExpectedFrameRate(cadence.framesPerSecond)
            let snapshot = RecordingWriterCadenceSnapshot(
                cadence: cadence,
                captureGeneration: captureGeneration,
                physicalDeviceID: physicalDeviceID,
                transactionID: transactionID,
                appliedAtUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
            self.activeCadenceSnapshot = snapshot
            self.cadenceBelowThresholdSinceUptimeNanoseconds = nil
            self.severeCadenceBelowThresholdSinceUptimeNanoseconds = nil
            self.writtenFrameUptimes.removeAll(keepingCapacity: true)
            self.sourceFrameUptimes.removeAll(keepingCapacity: true)
            self.latestRollingCadenceFPS = 0
            self.latestRollingSourceCadenceFPS = 0
            self.lastUniqueSourceFrameUptimeNanoseconds = nil
            self.lastSourceSequence = nil
            self.configuration?.frameSource.rebindCapture(
                generation: captureGeneration,
                physicalDeviceID: physicalDeviceID
            )
            self.lastDecision = "verified capture-driven writer binding applied \(previous.displayText)->\(cadence.displayText)fps transaction=\(transactionID.uuidString)"
            RinkLensStructuredEventLogger.shared.record(
                domain: .recording,
                event: "recording_writer_cadence_transition_applied",
                entityID: physicalDeviceID,
                previous: ["fps": previous.displayText],
                next: [
                    "fps": cadence.displayText,
                    "captureGeneration": String(captureGeneration),
                    "transactionID": transactionID.uuidString
                ],
                source: "RecordingWriter",
                reason: "Recovery B verified CaptureEngine lens/cadence transition",
                captureGeneration: captureGeneration,
                authoritativeOwner: "RecordingWriter"
            )
            let outcome = RecordingCadenceTransitionOutcome(
                succeeded: true,
                previousCadence: previous,
                appliedSnapshot: snapshot,
                errorText: nil
            )
            Task { @MainActor in completion(outcome) }
        }
    }

    func stop() {
        closeCaptureIngressAdmission(transitionBlocked: false, clearPending: true)
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isStopping else { return }
            self.isStopping = true
            self.isRunning = false
            self.clearCaptureIngress()
            self.lastDecision = "Recovery AQ flushing VideoToolbox after capture-driven ingress closed"
            self.compressionEngine.completeFrames { [weak self] status in
                guard let self else { return }
                self.queue.async {
                    self.finishFileAfterCompressionFlush(status: status)
                }
            }
        }
    }

    private func finishFileAfterCompressionFlush(status: OSStatus) {
        if status != noErr {
            forcedFailureReason = "VideoToolbox flush failed OSStatus=\(status)"
        }
        guard let writer else {
            let result = RecordingWriterResult(
                framesWritten: framesWritten,
                framesDropped: framesDropped,
                cameraSourceDrops: cameraSourceDrops,
                sourceSamplingMisses: sourceSamplingMisses,
                writerDrops: writerDrops,
                renderDrops: renderDrops,
                ingressDiagnosticsText: captureIngressDiagnosticsText(),
                blackFramesRejected: blackFramesRejected,
                blackFramesDetected: blackFramesDetected,
                blackFramesContinuityAccepted: blackFramesContinuityAccepted,
                actualFPS: finalCadenceMetrics().actualFPS,
                sourceFPS: latestRollingSourceCadenceFPS,
                cadenceRatio: finalCadenceMetrics().ratio,
                activeDurationSeconds: finalCadenceMetrics().duration,
                pollingFPS: pollingFPS,
                writerStatus: .unknown,
                errorDescription: forcedFailureReason,
                forcedFailureKind: forcedFailureKind,
                forcedFailureReason: forcedFailureReason,
                partialFilePreserved: FileManager.default.fileExists(atPath: configuration?.outputURL.path ?? "")
            )
            let callbacks = callbacks
            releaseWriterState()
            if let callbacks { Task { @MainActor in callbacks.onFinished(result) } }
            return
        }

        writerInput?.markAsFinished()
        let framesWritten = framesWritten
        let framesDropped = framesDropped
        let cameraSourceDrops = cameraSourceDrops
        let sourceSamplingMisses = sourceSamplingMisses
        let finalMetrics = finalCadenceMetrics()
        let pollingFPS = pollingFPS
        let writerDrops = writerDrops
        let renderDrops = renderDrops
        let blackFramesRejected = blackFramesRejected
        let blackFramesDetected = blackFramesDetected
        let blackFramesContinuityAccepted = blackFramesContinuityAccepted
        let sourceFPS = latestRollingSourceCadenceFPS
        let forcedFailureKind = forcedFailureKind
        let forcedFailureReason = forcedFailureReason
        let outputURL = configuration?.outputURL
        let callbacks = callbacks
        writer.finishWriting { [weak self] in
            guard let self else { return }
            self.queue.async {
                let result = RecordingWriterResult(
                    framesWritten: framesWritten,
                    framesDropped: framesDropped,
                    cameraSourceDrops: cameraSourceDrops,
                    sourceSamplingMisses: sourceSamplingMisses,
                    writerDrops: writerDrops,
                    renderDrops: renderDrops,
                    ingressDiagnosticsText: self.captureIngressDiagnosticsText(),
                    blackFramesRejected: blackFramesRejected,
                    blackFramesDetected: blackFramesDetected,
                    blackFramesContinuityAccepted: blackFramesContinuityAccepted,
                    actualFPS: finalMetrics.actualFPS,
                    sourceFPS: sourceFPS,
                    cadenceRatio: finalMetrics.ratio,
                    activeDurationSeconds: finalMetrics.duration,
                    pollingFPS: pollingFPS,
                    writerStatus: self.writer?.status ?? .unknown,
                    errorDescription: self.writer?.error?.localizedDescription ?? forcedFailureReason,
                    forcedFailureKind: forcedFailureKind,
                    forcedFailureReason: forcedFailureReason,
                    partialFilePreserved: outputURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                )
                self.releaseWriterState()
                if let callbacks { Task { @MainActor in callbacks.onFinished(result) } }
            }
        }
    }

    private nonisolated static func logStartupStage(
        _ stage: String,
        startedAt: CFAbsoluteTime,
        outputURL: URL,
        detail: String = ""
    ) {
        let durationMS = max(0, (CFAbsoluteTimeGetCurrent() - startedAt) * 1_000)
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "recording_writer_startup_stage",
            entityID: outputURL.lastPathComponent,
            previous: ["stage": "pending"],
            next: ["stage": stage, "durationMs": String(format: "%.1f", durationMS), "detail": detail],
            source: "RecordingWriter",
            reason: "RL-030 Build 785 R16 measures the one real writer instead of warming another encoder path",
            authoritativeOwner: "RecordingWriter"
        )
    }

    /// Recovery AW: the capture callback first consults RecordingWriter-owned
    /// admission state. Paused/stopping/transition-held frames are rejected before
    /// pixel ownership is acquired. Active recording then performs the sole
    /// Broadcast pixel copy directly into the bounded three-surface writer pool.
    func submitCaptureFrame(_ captureFrame: BroadcastRecordingCaptureFrame) {
        let now = DispatchTime.now().uptimeNanoseconds
        let ageMS = now >= captureFrame.capturedUptimeNanoseconds
            ? Double(now - captureFrame.capturedUptimeNanoseconds) / 1_000_000.0
            : 0

        captureIngressLock.lock()
        captureIngressSubmittedCount &+= 1
        captureIngressMaxAdmissionAgeMilliseconds = max(captureIngressMaxAdmissionAgeMilliseconds, ageMS)
        let acceptingFrames = captureIngressAcceptingFrames
        let transitionBlocked = captureIngressTransitionBlocked
        let frameSource = captureIngressFrameSource
        if !acceptingFrames {
            if transitionBlocked {
                captureIngressTransitionDiscardCount &+= 1
            } else {
                captureIngressStateDiscardCount &+= 1
            }
            captureIngressLock.unlock()
            return
        }
        captureIngressLock.unlock()

        guard let frameSource,
              let sourceFrame = frameSource.recordingFrame(from: captureFrame) else {
            captureIngressLock.lock()
            captureIngressRejectedCount &+= 1
            captureIngressLock.unlock()
            return
        }

        // Recovery CU / RL-220: the bounded pool owns one active frame, one
        // latest pending frame and one spare for replacement. Release obsolete
        // pending pixels before acquiring their replacement; allocating first
        // could transiently demand a fourth surface and drop the newest callback.
        captureIngressLock.lock()
        if captureIngressBusy, captureIngressPending != nil {
            captureIngressPending = nil
            captureIngressReplacedCount &+= 1
        }
        captureIngressLock.unlock()

        let copyStarted = DispatchTime.now().uptimeNanoseconds
        guard let ownedCopy = recordingIngressPool.makeOwnedCopy(of: sourceFrame.pixelBuffer) else {
            captureIngressLock.lock()
            captureIngressPoolDropCount &+= 1
            captureIngressLock.unlock()
            return
        }
        let copyCompleted = DispatchTime.now().uptimeNanoseconds
        let copyMS = copyCompleted >= copyStarted
            ? Double(copyCompleted - copyStarted) / 1_000_000.0
            : ownedCopy.totalMilliseconds
        let recordingFrame = BroadcastRecordingPixelBufferFrame(
            pixelBuffer: ownedCopy.pixelBuffer,
            capturedAt: sourceFrame.capturedAt,
            capturedUptimeNanoseconds: sourceFrame.capturedUptimeNanoseconds,
            sequence: sourceFrame.sequence,
            sizeText: sourceFrame.sizeText,
            sourceDescription: "Recording-owned " + sourceFrame.sourceDescription,
            cameraRotationDegrees: sourceFrame.cameraRotationDegrees,
            compositeRotationDegrees: sourceFrame.compositeRotationDegrees,
            mirrorCorrectionEnabled: sourceFrame.mirrorCorrectionEnabled,
            overlayCIImage: sourceFrame.overlayCIImage
        )

        captureIngressLock.lock()
        captureIngressCopiedCount &+= 1
        captureIngressCopyLastMilliseconds = copyMS
        if copyMS >= captureIngressCopyMaxMilliseconds {
            captureIngressCopyMaxMilliseconds = copyMS
            captureIngressMaxCopyBreakdown = ownedCopy.breakdown(totalOverrideMilliseconds: copyMS)
        }
        captureIngressPoolAcquireMaxMilliseconds = max(
            captureIngressPoolAcquireMaxMilliseconds,
            ownedCopy.poolAcquireMilliseconds
        )
        captureIngressPixelCopyMaxMilliseconds = max(
            captureIngressPixelCopyMaxMilliseconds,
            ownedCopy.pixelCopyMilliseconds
        )
        captureIngressSourceLockMaxMilliseconds = max(
            captureIngressSourceLockMaxMilliseconds,
            ownedCopy.sourceLockMilliseconds
        )
        captureIngressDestinationLockMaxMilliseconds = max(
            captureIngressDestinationLockMaxMilliseconds,
            ownedCopy.destinationLockMilliseconds
        )
        captureIngressMetadataMaxMilliseconds = max(
            captureIngressMetadataMaxMilliseconds,
            ownedCopy.attachmentPropagationMilliseconds
        )
        if copyMS > 20.0 {
            captureIngressSlowCopyCount &+= 1
            MainThreadStallMonitor.traceFromAnyQueue(
                "Recovery DB recording ingress slow owned copy total=\(String(format: "%.1f", copyMS))ms breakdown={\(ownedCopy.breakdown(totalOverrideMilliseconds: copyMS))}"
            )
        }
        if captureIngressBusy {
            if captureIngressPending != nil { captureIngressReplacedCount &+= 1 }
            captureIngressPending = recordingFrame
            captureIngressLock.unlock()
            return
        }
        captureIngressBusy = true
        captureIngressLock.unlock()
        queue.async { [weak self] in
            self?.processCaptureFrame(recordingFrame)
            self?.finishCaptureIngressItem()
        }
    }

    private func finishCaptureIngressItem() {
        captureIngressLock.lock()
        if let pending = captureIngressPending {
            captureIngressPending = nil
            captureIngressLock.unlock()
            queue.async { [weak self] in
                self?.processCaptureFrame(pending)
                self?.finishCaptureIngressItem()
            }
        } else {
            captureIngressBusy = false
            captureIngressLock.unlock()
        }
    }

    private func closeCaptureIngressAdmission(transitionBlocked: Bool, clearPending: Bool) {
        captureIngressLock.lock()
        captureIngressAcceptingFrames = false
        captureIngressTransitionBlocked = transitionBlocked
        if clearPending, captureIngressPending != nil {
            captureIngressClearedPendingCount &+= 1
            captureIngressPending = nil
        }
        captureIngressLock.unlock()
    }

    /// Called from the authoritative writer queue after queue-owned state changes.
    private func openCaptureIngressAdmissionIfEligible() {
        let shouldAccept = isRunning && !isPaused && !isStopping && !isCameraTransitionHeld
        captureIngressLock.lock()
        captureIngressAcceptingFrames = shouldAccept && captureIngressFrameSource != nil
        captureIngressTransitionBlocked = isCameraTransitionHeld
        captureIngressLock.unlock()
    }

    private func clearCaptureIngress() {
        captureIngressLock.lock()
        captureIngressAcceptingFrames = false
        captureIngressTransitionBlocked = false
        if captureIngressPending != nil { captureIngressClearedPendingCount &+= 1 }
        captureIngressPending = nil
        captureIngressBusy = false
        captureIngressFrameSource = nil
        captureIngressLock.unlock()
    }

    private func captureIngressDiagnosticsText() -> String {
        captureIngressLock.lock()
        let text = String(
            format: "offered=%d copied=%d processed=%d pendingReplaced=%d bindingRejected=%d poolDrops=%d stateDiscard=%d transitionDiscard=%d clearedPending=%d copyMs=%.3f/max:%.3f poolAcquireMaxMs=%.3f pixelCopyMaxMs=%.3f sourceLockMaxMs=%.3f destinationLockMaxMs=%.3f metadataMaxMs=%.3f slowCopies=%d maxBreakdown={%@} admissionAgeMaxMs=%.1f accepting=%@ transitionBlocked=%@ ownership=recording-pool(3)",
            captureIngressSubmittedCount,
            captureIngressCopiedCount,
            captureIngressProcessedCount,
            captureIngressReplacedCount,
            captureIngressRejectedCount,
            captureIngressPoolDropCount,
            captureIngressStateDiscardCount,
            captureIngressTransitionDiscardCount,
            captureIngressClearedPendingCount,
            captureIngressCopyLastMilliseconds,
            captureIngressCopyMaxMilliseconds,
            captureIngressPoolAcquireMaxMilliseconds,
            captureIngressPixelCopyMaxMilliseconds,
            captureIngressSourceLockMaxMilliseconds,
            captureIngressDestinationLockMaxMilliseconds,
            captureIngressMetadataMaxMilliseconds,
            captureIngressSlowCopyCount,
            captureIngressMaxCopyBreakdown,
            captureIngressMaxAdmissionAgeMilliseconds,
            captureIngressAcceptingFrames ? "true" : "false",
            captureIngressTransitionBlocked ? "true" : "false"
        )
        captureIngressLock.unlock()
        return text
    }

    private func processCaptureFrame(_ frame: BroadcastRecordingPixelBufferFrame) {
        // Recovery AT / RL-099: this is the protected per-frame media section.
        // It never waits for lower-priority work; it only prevents new Clock/aux
        // jobs from beginning while composition and encoder admission are active.
        RinkLensExecutionCoordinator.shared.beginRecordingFrameCritical()
        defer { RinkLensExecutionCoordinator.shared.endRecordingFrameCritical() }

        guard isRunning, !isPaused, !isStopping, let configuration else {
            captureIngressLock.lock()
            captureIngressStateDiscardCount &+= 1
            captureIngressLock.unlock()
            return
        }
        guard !isCameraTransitionHeld else {
            captureIngressLock.lock()
            captureIngressTransitionDiscardCount &+= 1
            captureIngressLock.unlock()
            lastDecision = "capture event ignored while optical handoff owns recording boundary"
            return
        }
        captureIngressLock.lock()
        captureIngressProcessedCount &+= 1
        captureIngressLock.unlock()

        let renderStarted = CFAbsoluteTimeGetCurrent()
        if let writer, let writerInput {
            if writer.status == .failed || writer.status == .cancelled {
                terminateForWriterFailure(
                    evidence: makeWriterFailureEvidence(
                        writer: writer,
                        input: writerInput,
                        attemptedPresentationTime: lastPresentationTime,
                        appendSucceeded: nil,
                        reason: "passthrough writer entered terminal state before compressed append"
                    )
                )
                return
            }
            guard writerInput.isReadyForMoreMediaData else {
                writerDrops &+= 1
                updateTotalDrops()
                lastDecision = "passthrough writer not ready for capture event"
                publishProgressIfNeeded(renderDurationMS: 0, source: frame.sourceDescription, validation: lastDecision, force: false)
                return
            }
        }
        guard compressionEngine.inFlightCount < 3 else {
            writerDrops &+= 1
            updateTotalDrops()
            lastDecision = "VideoToolbox encoder backlog at capture-event capacity"
            publishProgressIfNeeded(renderDurationMS: 0, source: frame.sourceDescription, validation: lastDecision, force: false)
            return
        }

        if lastSourceSequence == frame.sequence {
            // CaptureEngine sequences are monotonic physical callback identities;
            // duplicate delivery is never required in the event-driven path.
            sourceSamplingMisses &+= 1
            lastDecision = "duplicate capture event ignored"
            return
        }
        lastSourceSequence = frame.sequence
        lastUniqueSourceFrameUptimeNanoseconds = frame.capturedUptimeNanoseconds
        sourceFrameUptimes.append(frame.capturedUptimeNanoseconds)

        let firstFrameStartupStage = !hasLoggedFirstCompositor
        let firstCompositorStarted = firstFrameStartupStage ? CFAbsoluteTimeGetCurrent() : 0
        guard let outputBuffer = BroadcastPixelBufferCompositor.shared.render(
            cameraPixelBuffer: frame.pixelBuffer,
            overlayCIImage: frame.overlayCIImage,
            outputSize: configuration.outputSize,
            pixelBufferPool: compressionPixelBufferPool,
            cameraRotationDegrees: frame.cameraRotationDegrees,
            compositeRotationDegrees: frame.compositeRotationDegrees,
            mirrorCorrectionEnabled: frame.mirrorCorrectionEnabled
        ) else {
            renderDrops &+= 1
            updateTotalDrops()
            lastDecision = "Core Image compositor failed for capture event"
            publishProgressIfNeeded(renderDurationMS: 0, source: frame.sourceDescription, validation: lastDecision, force: true)
            return
        }
        // The compositor/encoder output pool already owns this application
        // surface. Retaining only the latest composed buffer avoids another 1080p
        // pixel copy and provides the recording continuity boundary required by
        // a physical camera handoff.
        cameraTransitionContinuityFrame = outputBuffer
        if firstFrameStartupStage {
            hasLoggedFirstCompositor = true
            Self.logStartupStage("first-compositor-render", startedAt: firstCompositorStarted, outputURL: configuration.outputURL)
        }

        let cadence = activeCadence ?? configuration.cadence
        let localPresentationTime = nextPresentationTime(capturedAt: frame.capturedAt, cadence: cadence)
        let presentationTime = compressionEngine.monotonicPresentationTime(
            candidate: localPresentationTime,
            duration: cadence.duration
        )
        let renderDurationMS = (CFAbsoluteTimeGetCurrent() - renderStarted) * 1000.0
        let segmentFrameCount = max(
            Int64(1),
            Int64((cadence.framesPerSecond * BroadcastPixelBufferClipPerformanceGuard.pixelBufferSegmentDuration).rounded())
        )
        let forceKeyFrame = frameIndex == 0 || frameIndex % segmentFrameCount == 0
        let accepted = compressionEngine.encode(
            pixelBuffer: outputBuffer,
            presentationTime: presentationTime,
            duration: cadence.duration,
            forceKeyFrame: forceKeyFrame
        ) { [weak self] status, flags, sampleBuffer in
            guard let self else { return }
            let sampleBufferBox = RecordingAPUncheckedSendable(value: sampleBuffer)
            self.queue.async {
                guard !self.isStopping else { return }
                guard status == noErr, !flags.contains(.frameDropped), let sampleBuffer = sampleBufferBox.value else {
                    self.writerDrops &+= 1
                    self.updateTotalDrops()
                    self.lastDecision = "VideoToolbox encode failed status=\(status) flags=\(flags.rawValue)"
                    if status == kVTInvalidSessionErr {
                        self.compressionEngine.invalidate(reason: self.lastDecision)
                        self.failFast(
                            kind: .encoderFailure,
                            message: "VideoToolbox encoder session became invalid OSStatus=\(status)."
                        )
                        return
                    }
                    self.publishProgressIfNeeded(
                        renderDurationMS: renderDurationMS,
                        source: frame.sourceDescription,
                        validation: self.lastDecision,
                        force: true
                    )
                    return
                }
                self.appendCompressedSample(
                    sampleBuffer,
                    sourcePresentationTime: presentationTime,
                    sourceDescription: frame.sourceDescription,
                    validation: "capture-driven; brightness intentionally unclassified",
                    renderDurationMS: renderDurationMS
                )
            }
        }
        guard accepted else {
            writerDrops &+= 1
            updateTotalDrops()
            lastDecision = "VideoToolbox encode admission rejected for capture event"
            publishProgressIfNeeded(renderDurationMS: renderDurationMS, source: frame.sourceDescription, validation: lastDecision, force: false)
            return
        }

        frameIndex &+= 1
        lastDecision = "recording-owned ingress frame admitted; FrameHub producer lease already released"
    }

    private func startCameraTransitionContinuityOnQueue(transactionID: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        stopCameraTransitionContinuityOnQueue()
        guard cameraTransitionContinuityFrame != nil,
              isRunning,
              !isStopping else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        cameraTransitionContinuityTimer = timer
        let cadence = activeCadence ?? configuration?.cadence ?? .init(integerFPS: 30)
        timer.schedule(deadline: .now(), repeating: cadence.duration.seconds)
        timer.setEventHandler { [weak self] in
            self?.emitCameraTransitionContinuityFrame(transactionID: transactionID)
        }
        timer.resume()
    }

    private func stopCameraTransitionContinuityOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let timer = cameraTransitionContinuityTimer else { return }
        cameraTransitionContinuityTimer = nil
        timer.setEventHandler {}
        timer.cancel()
    }

    private func emitCameraTransitionContinuityFrame(transactionID: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isRunning,
              !isPaused,
              !isStopping,
              isCameraTransitionHeld,
              cameraTransitionTransactionID == transactionID,
              let frame = cameraTransitionContinuityFrame,
              let configuration else { return }
        if let writer, let writerInput,
           (writer.status == .failed || writer.status == .cancelled || !writerInput.isReadyForMoreMediaData) {
            return
        }
        guard compressionEngine.inFlightCount < 3 else { return }

        let cadence = activeCadence ?? configuration.cadence
        let localPTS = CMTimeAdd(lastPresentationTime ?? .zero, cadence.duration)
        lastPresentationTime = localPTS
        let presentationTime = compressionEngine.monotonicPresentationTime(
            candidate: localPTS,
            duration: cadence.duration
        )
        let segmentFrameCount = max(
            Int64(1),
            Int64((cadence.framesPerSecond * BroadcastPixelBufferClipPerformanceGuard.pixelBufferSegmentDuration).rounded())
        )
        let forceKeyFrame = frameIndex == 0 || frameIndex % segmentFrameCount == 0
        let accepted = compressionEngine.encode(
            pixelBuffer: frame,
            presentationTime: presentationTime,
            duration: cadence.duration,
            forceKeyFrame: forceKeyFrame
        ) { [weak self] status, flags, sampleBuffer in
            guard let self else { return }
            let boxed = RecordingAPUncheckedSendable(value: sampleBuffer)
            self.queue.async {
                guard !self.isStopping,
                      status == noErr,
                      !flags.contains(.frameDropped),
                      let sampleBuffer = boxed.value else { return }
                self.appendCompressedSample(
                    sampleBuffer,
                    sourcePresentationTime: presentationTime,
                    sourceDescription: "capacity-one composed camera-handoff continuity",
                    validation: "camera handoff continuity; no capture buffer retained",
                    renderDurationMS: 0
                )
            }
        }
        if accepted {
            frameIndex &+= 1
        }
    }

    private func appendCompressedSample(
        _ sampleBuffer: CMSampleBuffer,
        sourcePresentationTime: CMTime,
        sourceDescription: String,
        validation: String,
        renderDurationMS: Double
    ) {
        guard !isStopping, let configuration else { return }
        do {
            try configurePassthroughWriterIfNeeded(sampleBuffer: sampleBuffer, configuration: configuration)
        } catch {
            publishFailure(error.localizedDescription, callbacks: callbacks ?? RecordingWriterCallbacks(
                onStarted: {}, onProgress: { _ in }, onFinished: { _ in }, onFailure: { _ in }
            ))
            terminateForWriterFailure(evidence: "Recovery AP passthrough writer setup failed: \(error.localizedDescription)")
            return
        }
        guard let writer, let writerInput else { return }
        guard writerInput.isReadyForMoreMediaData else {
            writerDrops &+= 1
            updateTotalDrops()
            lastDecision = "passthrough writer backpressure after compression"
            publishProgressIfNeeded(renderDurationMS: renderDurationMS, source: sourceDescription, validation: lastDecision, force: false)
            return
        }
        let appendStarted = !hasSignalledStarted ? CFAbsoluteTimeGetCurrent() : 0
        let appended = writerInput.append(sampleBuffer)
        guard appended else {
            writerDrops &+= 1
            updateTotalDrops()
            let evidence = makeWriterFailureEvidence(
                writer: writer,
                input: writerInput,
                attemptedPresentationTime: sourcePresentationTime,
                appendSucceeded: false,
                reason: "compressed CMSampleBuffer append returned false"
            )
            if RecordingWriterTerminalPolicy.mustTerminateAfterAppend(appendSucceeded: false, writerStatus: writer.status) {
                terminateForWriterFailure(evidence: evidence)
            }
            return
        }
        if !hasSignalledStarted {
            Self.logStartupStage("first-compressed-sample-append", startedAt: appendStarted, outputURL: configuration.outputURL)
        }
        lastSuccessfulPresentationTime = sourcePresentationTime
        framesWritten &+= 1
        lastWrittenAt = Date()
        // One VideoToolbox encode fans out to two passthrough muxers. ClipEngine
        // no longer copies/composes/encodes a second 1080p frame stream.
        configuration.clipEngine.appendCompressedSample(
            sampleBuffer,
            sourcePresentationTime: sourcePresentationTime
        )
        if !hasSignalledStarted {
            hasSignalledStarted = true
            if let callbacks { Task { @MainActor in callbacks.onStarted() } }
        }
        lastDecision = isCameraTransitionHeld
            ? "compressed camera-transition holdover appended through passthrough muxer"
            : "compressed Broadcast frame appended through passthrough muxer"
        let nowUptime = DispatchTime.now().uptimeNanoseconds
        writtenFrameUptimes.append(nowUptime)
        evaluateCadence(configuration: configuration, nowUptimeNanoseconds: nowUptime)
        guard !isStopping else { return }
        publishProgressIfNeeded(
            renderDurationMS: renderDurationMS,
            source: sourceDescription,
            validation: validation,
            force: framesWritten == 1
        )
    }

    private func configurePassthroughWriterIfNeeded(
        sampleBuffer: CMSampleBuffer,
        configuration: RecordingWriterConfiguration
    ) throws {
        if writer != nil { return }
        guard let formatHint = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw NSError(
                domain: "RinkLens.RecordingWriter",
                code: 40,
                userInfo: [NSLocalizedDescriptionKey: "Compressed sample has no format description."]
            )
        }
        if FileManager.default.fileExists(atPath: configuration.outputURL.path) {
            try FileManager.default.removeItem(at: configuration.outputURL)
        }
        var stageStarted = CFAbsoluteTimeGetCurrent()
        let writer = try AVAssetWriter(outputURL: configuration.outputURL, fileType: .mp4)
        Self.logStartupStage("passthrough-asset-writer-init", startedAt: stageStarted, outputURL: configuration.outputURL)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: formatHint
        )
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw NSError(
                domain: "RinkLens.RecordingWriter",
                code: 41,
                userInfo: [NSLocalizedDescriptionKey: "Passthrough writer could not add compressed video input."]
            )
        }
        writer.add(input)
        stageStarted = CFAbsoluteTimeGetCurrent()
        if #available(iOS 26.0, *) {
            try writer.start()
            Self.logStartupStage("passthrough-writer-start", startedAt: stageStarted, outputURL: configuration.outputURL)
        } else {
            guard writer.startWriting() else {
                throw writer.error ?? NSError(
                    domain: "RinkLens.RecordingWriter",
                    code: 42,
                    userInfo: [NSLocalizedDescriptionKey: "Passthrough writer could not start."]
                )
            }
            Self.logStartupStage("passthrough-writer-start-legacy", startedAt: stageStarted, outputURL: configuration.outputURL)
        }
        let sourceTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        writer.startSession(atSourceTime: sourceTime)
        self.writer = writer
        self.writerInput = input
        self.writerSessionStarted = true
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "recording_passthrough_muxer_started",
            entityID: configuration.outputURL.lastPathComponent,
            previous: ["fileWriter": "encoder+writer"],
            next: ["fileWriter": "compressed-sample muxer", "outputSettings": "nil", "sourceFormatHint": "VideoToolbox sample"],
            source: "RecordingWriter.configurePassthroughWriterIfNeeded",
            reason: "Recovery AP RL-091 file writer no longer owns video compression",
            authoritativeOwner: "RecordingWriter"
        )
    }

    private func terminateForWriterFailure(evidence: String) {
        guard !isStopping else { return }
        terminalWriterFailureEvidence = evidence
        lastDecision = evidence
        isStopping = true
        isRunning = false
        clearCaptureIngress()

        guard let writer else {
            completeTerminalWriterFailure(status: .unknown, evidence: evidence)
            return
        }

        let status = writer.status
        if status == .writing {
            writerInput?.markAsFinished()
            writer.finishWriting { [weak self] in
                guard let self else { return }
                self.queue.async {
                    let finalWriter = self.writer
                    let finalEvidence: String
                    if let finalWriter {
                        finalEvidence = self.makeWriterFailureEvidence(
                            writer: finalWriter,
                            input: self.writerInput,
                            attemptedPresentationTime: self.lastPresentationTime,
                            appendSucceeded: false,
                            reason: "terminal append failure finishWriting returned"
                        )
                    } else {
                        finalEvidence = evidence + "; finishWritingReturned=true; writerReleased=true"
                    }
                    self.completeTerminalWriterFailure(
                        status: finalWriter?.status ?? .unknown,
                        evidence: finalEvidence
                    )
                }
            }
            queue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self else { return }
                let finalWriter = self.writer
                let finalEvidence: String
                if let finalWriter {
                    finalEvidence = self.makeWriterFailureEvidence(
                        writer: finalWriter,
                        input: self.writerInput,
                        attemptedPresentationTime: self.lastPresentationTime,
                        appendSucceeded: false,
                        reason: "terminal append failure finalisation exceeded 3.0s; partial file preserved"
                    )
                } else {
                    finalEvidence = evidence + "; finalisationTimeout=3.0s; writerReleased=true"
                }
                self.completeTerminalWriterFailure(
                    status: finalWriter?.status ?? .unknown,
                    evidence: finalEvidence
                )
            }
        } else {
            completeTerminalWriterFailure(status: status, evidence: evidence)
        }
    }

    private func completeTerminalWriterFailure(status: AVAssetWriter.Status, evidence: String) {
        guard !terminalCompletionDelivered else { return }
        terminalCompletionDelivered = true
        let callbacks = callbacks
        let finalMetrics = finalCadenceMetrics()
        let outputURL = configuration?.outputURL
        let result = RecordingWriterResult(
            framesWritten: framesWritten,
            framesDropped: framesDropped,
            cameraSourceDrops: cameraSourceDrops,
            sourceSamplingMisses: sourceSamplingMisses,
            writerDrops: writerDrops,
            renderDrops: renderDrops,
            ingressDiagnosticsText: captureIngressDiagnosticsText(),
            blackFramesRejected: blackFramesRejected,
            blackFramesDetected: blackFramesDetected,
            blackFramesContinuityAccepted: blackFramesContinuityAccepted,
            actualFPS: finalMetrics.actualFPS,
            sourceFPS: latestRollingSourceCadenceFPS,
            cadenceRatio: finalMetrics.ratio,
            activeDurationSeconds: finalMetrics.duration,
            pollingFPS: pollingFPS,
            writerStatus: .failed,
            errorDescription: evidence,
            forcedFailureKind: nil,
            forcedFailureReason: nil,
            partialFilePreserved: outputURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        )
        releaseWriterState()
        if let callbacks { Task { @MainActor in callbacks.onFinished(result) } }
    }

    private func makeWriterFailureEvidence(
        writer: AVAssetWriter,
        input: AVAssetWriterInput?,
        attemptedPresentationTime: CMTime?,
        appendSucceeded: Bool?,
        reason: String
    ) -> String {
        let error = writer.error as NSError?
        let underlying = error?.userInfo[NSUnderlyingErrorKey] as? NSError
        let attempted = attemptedPresentationTime.map(Self.timeText) ?? "none"
        let successful = lastSuccessfulPresentationTime.map(Self.timeText) ?? "none"
        let outputPath = configuration?.outputURL.path ?? "none"
        let diskFree = Self.availableDiskBytes(for: configuration?.outputURL)
        return "UX16d2a terminal writer failure reason=\(reason); append=\(appendSucceeded.map { String($0) } ?? "not-attempted"); "
            + "writerStatus=\(Self.writerStatusText(writer.status)); inputReady=\(input?.isReadyForMoreMediaData == true); "
            + "errorDomain=\(error?.domain ?? "none"); errorCode=\(error?.code ?? 0); error=\(error?.localizedDescription ?? "none"); "
            + "underlyingDomain=\(underlying?.domain ?? "none"); underlyingCode=\(underlying?.code ?? 0); underlying=\(underlying?.localizedDescription ?? "none"); "
            + "attemptedPTS=\(attempted); lastSuccessfulPTS=\(successful); framesWritten=\(framesWritten); writerDrops=\(writerDrops); "
            + "output=\(outputPath); diskFreeBytes=\(diskFree)"
    }

    private static func writerStatusText(_ status: AVAssetWriter.Status) -> String {
        switch status {
        case .unknown: return "unknown"
        case .writing: return "writing"
        case .completed: return "completed"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        @unknown default: return "future-\(status.rawValue)"
        }
    }

    private nonisolated static func timeText(_ time: CMTime) -> String {
        guard time.isValid, time.isNumeric else { return "invalid" }
        return "\(time.value)/\(time.timescale)=\(String(format: "%.6f", CMTimeGetSeconds(time)))s"
    }

    private static func availableDiskBytes(for outputURL: URL?) -> Int64 {
        guard let outputURL else { return -1 }
        do {
            let values = try outputURL.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values.volumeAvailableCapacityForImportantUsage ?? -1
        } catch {
            return -1
        }
    }

    private func updateTotalDrops() {
        framesDropped = cameraSourceDrops + writerDrops + renderDrops + blackFramesRejected
    }

    private func evaluateCadence(
        configuration: RecordingWriterConfiguration,
        nowUptimeNanoseconds: UInt64
    ) {
        let elapsed = activeElapsed(at: Date())
        let cadenceSegmentElapsed = max(0, elapsed - cadenceSegmentStartedActiveElapsed)
        let warmupSeconds: TimeInterval = 10
        let rollingWindowSeconds: TimeInterval = 10
        let rollingWindowNanoseconds = UInt64(rollingWindowSeconds * 1_000_000_000)
        let cutoff = nowUptimeNanoseconds > rollingWindowNanoseconds
            ? nowUptimeNanoseconds - rollingWindowNanoseconds
            : 0
        writtenFrameUptimes.removeAll { $0 < cutoff }
        sourceFrameUptimes.removeAll { $0 < cutoff }

        let measuredWindow = min(rollingWindowSeconds, max(0.001, cadenceSegmentElapsed))
        latestRollingCadenceFPS = Double(writtenFrameUptimes.count) / measuredWindow
        if let first = sourceFrameUptimes.first,
           let last = sourceFrameUptimes.last,
           last > first,
           sourceFrameUptimes.count > 1 {
            latestRollingSourceCadenceFPS = Double(sourceFrameUptimes.count - 1)
                / (Double(last - first) / 1_000_000_000)
        } else {
            latestRollingSourceCadenceFPS = 0
        }

        guard cadenceSegmentElapsed >= warmupSeconds else {
            cadenceBelowThresholdSinceUptimeNanoseconds = nil
            severeCadenceBelowThresholdSinceUptimeNanoseconds = nil
            return
        }

        let targetFPS = (activeCadence ?? configuration.cadence).framesPerSecond
        let healthyFPS = targetFPS * configuration.minimumHealthyFrameRatio
        let sourceFPS = latestRollingSourceCadenceFPS
        let outputFPS = latestRollingCadenceFPS

        if sourceFPS >= healthyFPS, outputFPS >= targetFPS * 0.92 {
            cadenceBelowThresholdSinceUptimeNanoseconds = nil
            severeCadenceBelowThresholdSinceUptimeNanoseconds = nil
            return
        }

        if cadenceBelowThresholdSinceUptimeNanoseconds == nil {
            cadenceBelowThresholdSinceUptimeNanoseconds = nowUptimeNanoseconds
        }

        // UX16d2f root correction: callback cadence is telemetry, not recording
        // health by itself. The failed UX16d2e run was still writing 59.4fps with
        // fresh frames and no renderer loss when a short OCR Setup UI stall reduced
        // the callback counter to 27fps. A healthy output stream must not be stopped
        // because one rolling callback metric dipped for three seconds.
        let sourceAgeSeconds: TimeInterval = lastUniqueSourceFrameUptimeNanoseconds.map {
            Double(nowUptimeNanoseconds &- $0) / 1_000_000_000
        } ?? .infinity

        if severeCadenceBelowThresholdSinceUptimeNanoseconds == nil {
            severeCadenceBelowThresholdSinceUptimeNanoseconds = nowUptimeNanoseconds
        }
        let severeSince = severeCadenceBelowThresholdSinceUptimeNanoseconds ?? nowUptimeNanoseconds
        let severeDuration = Double(nowUptimeNanoseconds &- severeSince) / 1_000_000_000
        let truth = RecordingCadenceTruthPolicy.evaluate(
            targetFPS: targetFPS,
            sourceFPS: sourceFPS,
            outputFPS: outputFPS,
            sourceAgeSeconds: sourceAgeSeconds,
            sourceMaximumAge: configuration.sourceMaximumAge,
            severeDuration: severeDuration
        )

        switch truth.disposition {
        case .healthy:
            severeCadenceBelowThresholdSinceUptimeNanoseconds = nil
            lastDecision = truth.diagnostic
            return
        case .warning:
            lastDecision = truth.diagnostic
            return
        case .terminal:
            failFast(
                kind: .severeCadenceCollapse,
                message: "Broadcast cadence truth failed: \(truth.diagnostic) against \((activeCadence ?? configuration.cadence).displayText)fps target."
            )
        }
    }

    private func finalCadenceMetrics() -> (duration: TimeInterval, actualFPS: Double, ratio: Double) {
        let duration = activeElapsed(at: Date())
        let actualFPS = Double(framesWritten) / max(0.001, duration)
        let cadence = activeCadence ?? configuration?.cadence ?? .init(integerFPS: 1)
        let expected = completedExpectedFrameBudget
            + max(0, duration - cadenceSegmentStartedActiveElapsed) * cadence.framesPerSecond
        let ratio = expected > 0 ? Double(framesWritten) / expected : 0
        return (duration, actualFPS, ratio)
    }

    private func failFast(kind: RecordingForcedFailureKind, message: String) {
        guard !isStopping else { return }
        forcedFailureKind = kind
        forcedFailureReason = message
        lastDecision = message
        isStopping = true
        isRunning = false
        clearCaptureIngress()

        guard let writer else {
            let callbacks = callbacks
            let finalMetrics = finalCadenceMetrics()
            let result = RecordingWriterResult(
                framesWritten: framesWritten,
                framesDropped: framesDropped,
                cameraSourceDrops: cameraSourceDrops,
                sourceSamplingMisses: sourceSamplingMisses,
                writerDrops: writerDrops,
                renderDrops: renderDrops,
                ingressDiagnosticsText: captureIngressDiagnosticsText(),
                blackFramesRejected: blackFramesRejected,
                blackFramesDetected: blackFramesDetected,
                blackFramesContinuityAccepted: blackFramesContinuityAccepted,
                actualFPS: finalMetrics.actualFPS,
                sourceFPS: latestRollingSourceCadenceFPS,
                cadenceRatio: finalMetrics.ratio,
                activeDurationSeconds: finalMetrics.duration,
                pollingFPS: pollingFPS,
                writerStatus: .unknown,
                errorDescription: nil,
                forcedFailureKind: kind,
                forcedFailureReason: message,
                partialFilePreserved: configuration.map { FileManager.default.fileExists(atPath: $0.outputURL.path) } ?? false
            )
            releaseWriterState()
            if let callbacks { Task { @MainActor in callbacks.onFinished(result) } }
            return
        }

        writerInput?.markAsFinished()
        let framesWritten = framesWritten
        let framesDropped = framesDropped
        let cameraSourceDrops = cameraSourceDrops
        let sourceSamplingMisses = sourceSamplingMisses
        let finalMetrics = finalCadenceMetrics()
        let pollingFPS = pollingFPS
        let writerDrops = writerDrops
        let renderDrops = renderDrops
        let blackFramesRejected = blackFramesRejected
        let blackFramesDetected = blackFramesDetected
        let blackFramesContinuityAccepted = blackFramesContinuityAccepted
        let sourceFPS = latestRollingSourceCadenceFPS
        let outputURL = configuration?.outputURL
        let callbacks = callbacks
        writer.finishWriting { [weak self] in
            guard let self else { return }
            self.queue.async {
                let result = RecordingWriterResult(
                    framesWritten: framesWritten,
                    framesDropped: framesDropped,
                    cameraSourceDrops: cameraSourceDrops,
                    sourceSamplingMisses: sourceSamplingMisses,
                    writerDrops: writerDrops,
                    renderDrops: renderDrops,
                    ingressDiagnosticsText: self.captureIngressDiagnosticsText(),
                    blackFramesRejected: blackFramesRejected,
                    blackFramesDetected: blackFramesDetected,
                    blackFramesContinuityAccepted: blackFramesContinuityAccepted,
                    actualFPS: finalMetrics.actualFPS,
                    sourceFPS: sourceFPS,
                    cadenceRatio: finalMetrics.ratio,
                    activeDurationSeconds: finalMetrics.duration,
                    pollingFPS: pollingFPS,
                    writerStatus: self.writer?.status ?? .unknown,
                    errorDescription: self.writer?.error?.localizedDescription,
                    forcedFailureKind: kind,
                    forcedFailureReason: message,
                    partialFilePreserved: outputURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                )
                self.releaseWriterState()
                if let callbacks { Task { @MainActor in callbacks.onFinished(result) } }
            }
        }
    }


    private func nextPresentationTime(capturedAt: Date, cadence: RinkLensCaptureCadence) -> CMTime {
        let base = startedAt ?? capturedAt
        let currentPause = pauseBeganAt.map { capturedAt.timeIntervalSince($0) } ?? 0
        let activeElapsed = max(0, capturedAt.timeIntervalSince(base) - totalPausedDuration - max(0, currentPause))
        var next = CMTime(seconds: activeElapsed, preferredTimescale: 600)
        if let lastPresentationTime, CMTimeCompare(next, lastPresentationTime) <= 0 {
            next = CMTimeAdd(lastPresentationTime, cadence.duration)
        }
        lastPresentationTime = next
        return next
    }

    private func activeElapsed(at now: Date) -> TimeInterval {
        let base = startedAt ?? now
        let currentPause = pauseBeganAt.map { now.timeIntervalSince($0) } ?? 0
        return max(0.001, now.timeIntervalSince(base) - totalPausedDuration - currentPause)
    }

    private func publishProgressIfNeeded(renderDurationMS: Double, source: String, validation: String, force: Bool) {
        guard let callbacks else { return }
        let now = Date()
        // Recovery AX / RL-013 + RL-110: internal cadence/health accounting stays
        // per-frame, but the operator projection is presentation-only. One update
        // per second is sufficient and removes four MainActor recording snapshots
        // per second from the live-video path.
        guard force || now.timeIntervalSince(lastProgressPublishedAt) >= 1.0 else { return }
        lastProgressPublishedAt = now
        let elapsed = activeElapsed(at: now)
        let progress = RecordingWriterProgress(
            framesWritten: framesWritten,
            framesDropped: framesDropped,
            cameraSourceDrops: cameraSourceDrops,
            sourceSamplingMisses: sourceSamplingMisses,
            writerDrops: writerDrops,
            renderDrops: renderDrops,
            ingressDiagnosticsText: captureIngressDiagnosticsText(),
            blackFramesRejected: blackFramesRejected,
            blackFramesDetected: blackFramesDetected,
            blackFramesContinuityAccepted: blackFramesContinuityAccepted,
            actualFPS: Double(framesWritten) / elapsed,
            sourceFPS: latestRollingSourceCadenceFPS,
            cadenceRatio: {
                let cadence = activeCadence ?? configuration?.cadence ?? .init(integerFPS: 1)
                let expected = completedExpectedFrameBudget
                    + max(0, elapsed - cadenceSegmentStartedActiveElapsed) * cadence.framesPerSecond
                return expected > 0 ? Double(framesWritten) / expected : 0
            }(),
            activeDurationSeconds: elapsed,
            pollingFPS: pollingFPS,
            renderDurationMS: renderDurationMS,
            sourceDescription: source,
            frameValidationText: validation,
            lastWrittenAt: lastWrittenAt,
            writerBacklog: writerInput?.isReadyForMoreMediaData == true ? 0 : 1,
            lastDecision: lastDecision,
            healthText: healthText(elapsed: elapsed)
        )
        Task { @MainActor in callbacks.onProgress(progress) }
    }

    private func healthText(elapsed: TimeInterval) -> String {
        let cadenceSegmentElapsed = max(0, elapsed - cadenceSegmentStartedActiveElapsed)
        let outputFPS = latestRollingCadenceFPS > 0
            ? latestRollingCadenceFPS
            : Double(framesWritten) / max(0.001, elapsed)
        let measuredOutputFPS = cadenceSegmentElapsed >= 10 ? latestRollingCadenceFPS : outputFPS
        let sourceFPS = cadenceSegmentElapsed >= 2 ? latestRollingSourceCadenceFPS : 0
        let target = (activeCadence ?? configuration?.cadence ?? .init(integerFPS: 1)).framesPerSecond
        let sourceRatio = target > 0 ? sourceFPS / target : 0
        let outputRatio = target > 0 ? measuredOutputFPS / target : 0
        if forcedFailureReason != nil { return "Failed — \(forcedFailureReason ?? "unknown")" }
        if sourceRatio < 0.85, cadenceSegmentElapsed >= 10 {
            return "Unhealthy — severe source cadence \(String(format: "%.1f", sourceFPS))fps / \(Int(target))fps"
        }
        if framesWritten == 0, writerInput == nil { return "Starting — VideoToolbox compression / passthrough muxer awaiting first sample" }
        if writerInput?.isReadyForMoreMediaData != true { return "Unhealthy — writer backpressure" }
        if outputRatio < (configuration?.minimumHealthyFrameRatio ?? 0.95), cadenceSegmentElapsed >= 10 {
            return "Warning — output cadence \(String(format: "%.1f", measuredOutputFPS))fps / \(Int(target))fps; source \(String(format: "%.1f", sourceFPS))fps"
        }
        if blackFramesContinuityAccepted > 0 {
            return "Warning — \(blackFramesContinuityAccepted) very-dark source frames encoded; source freshness remained healthy"
        }
        return "Healthy — source \(String(format: "%.1f", sourceFPS))fps and writer ready"
    }

    private func publishFailure(_ message: String, callbacks: RecordingWriterCallbacks) {
        Task { @MainActor in callbacks.onFailure(message) }
    }

    private func releaseWriterState() {
        stopCameraTransitionContinuityOnQueue()
        clearCaptureIngress()
        writer = nil
        writerInput = nil
        writerSessionStarted = false
        configuration = nil
        callbacks = nil
        activeCadence = nil
        activeCadenceSnapshot = nil
        isRunning = false
        isPaused = false
        isCameraTransitionHeld = false
        cameraTransitionTransactionID = nil
        cameraTransitionBeganAt = nil
        cameraTransitionContinuityFrame = nil
        isStopping = false
        startedAt = nil
        pauseBeganAt = nil
        totalPausedDuration = 0
        lastPresentationTime = nil
        lastSuccessfulPresentationTime = nil
        terminalWriterFailureEvidence = nil
        cadenceBelowThresholdSinceUptimeNanoseconds = nil
        severeCadenceBelowThresholdSinceUptimeNanoseconds = nil
        writtenFrameUptimes.removeAll(keepingCapacity: false)
        sourceFrameUptimes.removeAll(keepingCapacity: false)
        latestRollingCadenceFPS = 0
        latestRollingSourceCadenceFPS = 0
        pollingFPS = 0
        sourceSamplingMisses = 0
        forcedFailureKind = nil
        forcedFailureReason = nil
        hasSignalledStarted = false
        hasLoggedFirstCompositor = false
        completedExpectedFrameBudget = 0
        cadenceSegmentStartedActiveElapsed = 0
        blackFramesRejected = 0
        blackFramesDetected = 0
        blackFramesContinuityAccepted = 0
    }

    deinit {
        cameraTransitionContinuityTimer?.setEventHandler {}
        cameraTransitionContinuityTimer?.cancel()
        clearCaptureIngress()
    }
}
#endif
