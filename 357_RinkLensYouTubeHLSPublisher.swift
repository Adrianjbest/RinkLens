// BUILD 785: YouTube HLS HEVC/H.264 programme publisher.
#if canImport(SwiftUI)
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

nonisolated protocol RinkLensProgrammePublisher: AnyObject, Sendable {
    func updateOverlay(_ overlay: CIImage?)
    func rebindCapture(generation: Int, physicalDeviceID: String?, reason: String)
    func holdCaptureHandoff(transactionID: UUID, targetCadence: RinkLensCaptureCadence) -> Bool
    func rebindCaptureHandoff(transactionID: UUID, generation: Int, physicalDeviceID: String?, cadence: RinkLensCaptureCadence) -> Bool
    func abortCaptureHandoff(transactionID: UUID)
    func videoSourceEvidence() -> BroadcastRecordingFrameSourceEvidence?
    func stop()
    func cancel()
}

extension RinkLensDirectStreamPublisher: RinkLensProgrammePublisher {}

/// One explicit execution boundary for cold HLS resource acquisition. The UI
/// actor submits intent; the publisher's serial queue owns every physical
/// preparation stage that follows.
nonisolated enum RinkLensHLSStartupExecutor {
    static func submit(
        on queue: DispatchQueue,
        operation: @escaping @Sendable () -> Void
    ) {
        queue.async(execute: operation)
    }
}

/// Sole owner of YouTube HLS encoding, TS muxing and HTTPS upload. CaptureEngine
/// continues to own the camera graph; the publisher owns only bounded copies.
nonisolated final class RinkLensYouTubeHLSPublisher: RinkLensProgrammePublisher, @unchecked Sendable {
    private struct PendingFrame: @unchecked Sendable {
        let frame: BroadcastRecordingPixelBufferFrame
    }

    private final class PreparedAudioCapture: @unchecked Sendable {
        let engine: AVAudioEngine
        let converter: AVAudioConverter
        let outputFormat: AVAudioFormat

        init(engine: AVAudioEngine, converter: AVAudioConverter, outputFormat: AVAudioFormat) {
            self.engine = engine
            self.converter = converter
            self.outputFormat = outputFormat
        }

        func stop() {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    private let queue = DispatchQueue(label: "rinklens.streaming.hls.publisher", qos: .userInitiated)
    private let audioControlQueue = DispatchQueue(label: "rinklens.streaming.hls.audio-control", qos: .userInitiated)
    private let stateLock = NSLock()
    private let ingressPool = RinkLensFrameHubOwnedBufferPool(minimumBufferCount: 2, allocationThreshold: 3)
    private var outputPool: CVPixelBufferPool?
    private var outputSize = CGSize(width: 1280, height: 720)
    private var outputFrameRate = 60
    private var captureEngine: RinkLensCaptureEngine?
    private var frameSource: BroadcastRecordingPixelBufferFrameSourceContext?
    private var callbacks: RinkLensDirectStreamCallbacks?
    private var captureSinkToken: UUID?
    private var compressionSession: VTCompressionSession?
    private var muxer: RinkLensMPEGTSMuxer?
    private var uploader: RinkLensHLSUploader?
    private var active = false
    private var ingressBusy = false
    private var pendingFrame: PendingFrame?
    private var firstPTS: CMTime?
    private var encodedVideoFrames = 0
    private var encodedAudioPackets = 0
    private var inFlightEncodes = 0
    private var firstSubmittedFrameIncludedOverlay = false
    private var audioEngine: AVAudioEngine?
    private var audioConverter: AVAudioConverter?
    private var audioOutputFormat: AVAudioFormat?
    private var audioPTS: CMTime = .zero
    private var mediaTimelineAdmission = RinkLensHLSMediaTimelineAdmission()
    private var publisherLifetimeID = UUID()
    private var activeCaptureHandoffID: UUID?
    private var captureHandoffAwaitingFreshFrame = false
    private var continuityFrame: CVPixelBuffer?
    private var continuitySequencer = RinkLensOutputContinuitySequencer(lastPTS: .zero)
    private var continuityCadence = RinkLensCaptureCadence(integerFPS: 60)
    private var frameCadenceAdmission = RinkLensStreamFrameCadenceAdmission(targetFramesPerSecond: 60)

    @MainActor
    func start(
        uploadBaseURLText: String,
        profile: StreamDestinationStore.QualityProfile,
        codec: StreamDestinationStore.VideoCodec,
        frameSource: BroadcastRecordingPixelBufferFrameSourceContext,
        callbacks: RinkLensDirectStreamCallbacks
    ) {
        self.frameSource = frameSource
        self.callbacks = callbacks
        captureEngine = AppContainer.shared.captureEngine
        outputSize = profile.outputSize
        outputFrameRate = profile.framesPerSecond
        active = true
        firstPTS = nil
        encodedVideoFrames = 0
        encodedAudioPackets = 0
        inFlightEncodes = 0
        firstSubmittedFrameIncludedOverlay = false
        audioPTS = .zero
        mediaTimelineAdmission.reset()
        publisherLifetimeID = UUID()
        activeCaptureHandoffID = nil
        captureHandoffAwaitingFreshFrame = false
        continuityFrame = nil
        continuitySequencer = .init(lastPTS: .zero)
        continuityCadence = .init(integerFPS: profile.framesPerSecond)
        frameCadenceAdmission.reset(targetFramesPerSecond: profile.framesPerSecond)
        let captureFormat = frameSource.sourceRole == .broadcast
            ? captureEngine?.snapshot.liveFormat
            : captureEngine?.snapshot.ocrFormat
        let sourceWidth = max(1, Int(captureFormat?.width ?? Int32(profile.outputSize.width.rounded())))
        let sourceHeight = max(1, Int(captureFormat?.height ?? Int32(profile.outputSize.height.rounded())))
        Task { @MainActor in callbacks.onConnecting() }
        RinkLensHLSStartupExecutor.submit(on: queue) { [weak self] in
            self?.prepare(
                uploadBaseURLText: uploadBaseURLText,
                profile: profile,
                codec: codec,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight
            )
        }
    }

    func updateOverlay(_ overlay: CIImage?) {
        frameSource?.updateOverlay(overlay)
    }

    func rebindCapture(generation: Int, physicalDeviceID: String?, reason: String) {
        guard isActive, let frameSource else { return }
        let before = frameSource.captureEvidence()
        guard frameSource.rebindCapture(generation: generation, physicalDeviceID: physicalDeviceID) else { return }
        RinkLensStructuredEventLogger.shared.record(
            domain: .streaming,
            event: "programme_stream_capture_rebound",
            entityID: "hls",
            previous: [
                "generation": String(before.boundGeneration),
                "device": before.boundPhysicalDeviceID ?? "none",
                "lastAcceptedSequence": before.lastAcceptedSequence.map(String.init) ?? "none",
                "rejectedGeneration": String(before.rejectedGenerationCount),
                "rejectedDevice": String(before.rejectedDeviceCount)
            ],
            next: [
                "generation": String(generation),
                "device": physicalDeviceID ?? "none",
                "publisherSession": "retained",
                "freshFrame": "required"
            ],
            source: "RinkLensYouTubeHLSPublisher",
            reason: reason,
            captureGeneration: generation,
            authoritativeOwner: "CaptureLifecycleController/StreamControlStore"
        )
    }

    func holdCaptureHandoff(transactionID: UUID, targetCadence _: RinkLensCaptureCadence) -> Bool {
        stateLock.lock()
        guard active, activeCaptureHandoffID == nil, continuityFrame != nil else {
            stateLock.unlock()
            return false
        }
        activeCaptureHandoffID = transactionID
        captureHandoffAwaitingFreshFrame = false
        continuityCadence = .init(integerFPS: outputFrameRate)
        stateLock.unlock()
        queue.async { [weak self] in self?.emitContinuityFrame(transactionID: transactionID) }
        return true
    }

    func rebindCaptureHandoff(
        transactionID: UUID,
        generation: Int,
        physicalDeviceID: String?,
        cadence _: RinkLensCaptureCadence
    ) -> Bool {
        stateLock.lock()
        guard activeCaptureHandoffID == transactionID, active else {
            stateLock.unlock()
            return false
        }
        captureHandoffAwaitingFreshFrame = true
        // Capture cadence remains CaptureEngine truth. A camera handoff cannot
        // silently change the already-resolved YouTube output contract.
        continuityCadence = .init(integerFPS: outputFrameRate)
        stateLock.unlock()
        rebindCapture(generation: generation, physicalDeviceID: physicalDeviceID, reason: "Capture handoff \(transactionID) rebound")
        return true
    }

    func abortCaptureHandoff(transactionID: UUID) {
        stateLock.lock()
        guard activeCaptureHandoffID == transactionID else { stateLock.unlock(); return }
        activeCaptureHandoffID = nil
        captureHandoffAwaitingFreshFrame = false
        continuityFrame = nil
        stateLock.unlock()
    }

    func videoSourceEvidence() -> BroadcastRecordingFrameSourceEvidence? {
        frameSource?.captureEvidence()
    }

    func stop() {
        stop(notify: true)
    }

    func cancel() {
        stop(notify: false)
    }

    private func prepare(
        uploadBaseURLText: String,
        profile: StreamDestinationStore.QualityProfile,
        codec: StreamDestinationStore.VideoCodec,
        sourceWidth: Int,
        sourceHeight: Int
    ) {
        guard isActive else { return }
        do {
            let startupBegan = ProcessInfo.processInfo.systemUptime
            let ingressPreparation = ingressPool.prepare(
                width: sourceWidth,
                height: sourceHeight,
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            )
            RinkLensStructuredEventLogger.shared.record(
                domain: .streaming,
                event: "hls_startup_resource_stage",
                entityID: "ingress-pool",
                previous: ["state": "requested"],
                next: [
                    "state": "prepared",
                    "preparedBuffers": String(ingressPreparation.preparedBufferCount),
                    "stageMs": String(format: "%.1f", ingressPreparation.elapsedMilliseconds),
                    "totalMs": String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - startupBegan) * 1_000),
                    "mainThread": String(Thread.isMainThread)
                ],
                source: "RinkLensYouTubeHLSPublisher",
                reason: "Publisher queue acquired bounded HLS ingress surfaces"
            )
            guard isActive else { return }

            outputPool = Self.makeOutputPool(size: profile.outputSize)
            guard outputPool != nil else {
                throw NSError(
                    domain: "RinkLens.YouTubeHLS",
                    code: Int(kCVReturnAllocationFailed),
                    userInfo: [NSLocalizedDescriptionKey: "HLS output pixel-buffer pool allocation failed."]
                )
            }
            RinkLensStructuredEventLogger.shared.record(
                domain: .streaming,
                event: "hls_startup_resource_stage",
                entityID: "output-pool",
                previous: ["state": "requested"],
                next: [
                    "state": "prepared",
                    "totalMs": String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - startupBegan) * 1_000),
                    "mainThread": String(Thread.isMainThread)
                ],
                source: "RinkLensYouTubeHLSPublisher",
                reason: "Publisher queue acquired the HLS compositor output pool"
            )
            guard isActive else { return }

            try createCompressionSession(profile: profile, codec: codec)
            RinkLensStructuredEventLogger.shared.record(
                domain: .streaming,
                event: "hls_startup_resource_stage",
                entityID: "video-encoder",
                previous: ["state": "requested"],
                next: [
                    "state": "prepared",
                    "codec": codec.encoderName,
                    "totalMs": String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - startupBegan) * 1_000),
                    "mainThread": String(Thread.isMainThread)
                ],
                source: "RinkLensYouTubeHLSPublisher",
                reason: "Publisher queue completed VideoToolbox preparation"
            )
            guard isActive else { return }
            let targetVideoFPS = profile.framesPerSecond
            let uploader = RinkLensHLSUploader(
                baseURLText: uploadBaseURLText,
                callbacks: RinkLensHLSUploadCallbacks(
                    onAccepted: { [weak self] segment, status in
                        guard let self else { return }
                        let acknowledgementDelayMs = max(
                            0,
                            (ProcessInfo.processInfo.systemUptime - segment.createdUptime) * 1_000
                        )
                        let observedBitrateKbps = Double(segment.data.count * 8)
                            / max(0.001, segment.duration)
                            / 1_000
                        if let callbacks = self.callbacks {
                            Task { @MainActor in callbacks.onTransportBytesOut(segment.data.count) }
                        }
                        RinkLensStructuredEventLogger.shared.record(
                            domain: .streaming,
                            event: "hls_segment_acknowledged",
                            entityID: String(segment.sequence),
                            previous: ["state": "uploaded"],
                            next: [
                                "httpStatus": String(status),
                                "bytes": String(segment.data.count),
                                "durationMs": String(format: "%.0f", segment.duration * 1_000),
                                "videoFrames": String(segment.videoFrameCount),
                                "audioPackets": String(segment.audioPacketCount),
                                "videoPayloadBytes": String(segment.videoPayloadBytes),
                                "audioPayloadBytes": String(segment.audioPayloadBytes),
                                "maximumVideoGapMs": String(format: "%.1f", segment.maximumVideoGapMilliseconds),
                                "observedAudioPacketDurationMs": segment.observedAudioPacketDuration.map { String(format: "%.2f", $0 * 1_000) } ?? "unknown",
                                "videoTimelineMs": String(format: "%.0f", segment.videoTimelineDuration * 1_000),
                                "audioTimelineMs": String(format: "%.0f", segment.audioTimelineDuration * 1_000),
                                "audioVideoDriftMs": String(format: "%.0f", segment.audioVideoTimelineDriftMilliseconds),
                                "observedBitrateKbps": String(format: "%.0f", observedBitrateKbps),
                                "segmentToAcknowledgementMs": String(format: "%.0f", acknowledgementDelayMs)
                            ],
                            source: "RinkLensHLSUploader",
                            reason: "YouTube acknowledged the MPEG-2 TS media segment"
                        )
                        let continuity = RinkLensHLSContinuityPolicy.evaluate(
                            duration: segment.duration,
                            videoFrameCount: segment.videoFrameCount,
                            audioPacketCount: segment.audioPacketCount,
                            maximumVideoGapMilliseconds: segment.maximumVideoGapMilliseconds,
                            targetVideoFPS: targetVideoFPS,
                            observedAudioPacketDuration: segment.observedAudioPacketDuration,
                            audioVideoTimelineDriftMilliseconds: segment.audioVideoTimelineDriftMilliseconds
                        )
                        if continuity.shouldWarn {
                            RinkLensStructuredEventLogger.shared.record(
                                domain: .streaming,
                                event: "hls_segment_continuity_warning",
                                entityID: String(segment.sequence),
                                previous: [
                                    "targetVideoFPS": String(targetVideoFPS),
                                    "minimumVideoFrames": String(continuity.minimumExpectedVideoFrames),
                                    "minimumAudioPackets": String(continuity.minimumExpectedAudioPackets),
                                    "observedAudioPacketDurationMs": segment.observedAudioPacketDuration.map { String(format: "%.2f", $0 * 1_000) } ?? "unknown"
                                ],
                                next: [
                                    "durationMs": String(format: "%.0f", segment.duration * 1_000),
                                    "videoFrames": String(segment.videoFrameCount),
                                    "audioPackets": String(segment.audioPacketCount),
                                    "maximumVideoGapMs": String(format: "%.1f", segment.maximumVideoGapMilliseconds),
                                    "audioVideoDriftMs": String(format: "%.0f", segment.audioVideoTimelineDriftMilliseconds),
                                    "warningReasons": continuity.reasons.map(\.rawValue).sorted().joined(separator: ","),
                                    "httpStatus": String(status)
                                ],
                                source: "RinkLensMPEGTSMuxer",
                                reason: "Accepted segment contained a measurable media-cadence discontinuity; transport remains active"
                            )
                        }
                        if let callbacks = self.callbacks {
                            let detail = continuity.shouldWarn
                                ? "HLS media continuity failed: " + continuity.reasons.map(\.rawValue).sorted().joined(separator: ", ")
                                : "HLS audio/video timelines are aligned."
                            Task { @MainActor in callbacks.onMediaContinuity(!continuity.shouldWarn, detail) }
                        }
                    },
                    onFailure: { [weak self] message in self?.fail(message) },
                    onFinished: { [weak self] in self?.finishAcknowledged() }
                )
            )
            self.uploader = uploader
            muxer = RinkLensMPEGTSMuxer(
                onSegment: { [weak uploader] segment in uploader?.enqueue(segment) },
                onFailure: { [weak self] message in self?.fail(message) }
            )
            installCaptureSink()
            if let callbacks {
                Task { @MainActor in
                    callbacks.onCodecConfigured(codec.encoderName)
                    callbacks.onConnected()
                }
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func createCompressionSession(
        profile: StreamDestinationStore.QualityProfile,
        codec: StreamDestinationStore.VideoCodec
    ) throws {
        let width = Int32(profile.outputSize.width.rounded())
        let height = Int32(profile.outputSize.height.rounded())
        let codecType: CMVideoCodecType = codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
            kCVPixelBufferWidthKey as String: Int(width),
            kCVPixelBufferHeightKey as String: Int(height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: codecType,
            encoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let created else {
            throw Self.error("HLS VideoToolbox session creation failed", status: status)
        }
        try Self.setProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue, label: "real-time")
        try Self.setProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse, label: "closed GOP frame ordering")
        // MaxFrameDelayCount is explicitly optional in VideoToolbox and the
        // hardware HEVC encoder used by the test iPad returns
        // kVTPropertyNotSupportedErr. Closed-GOP ordering is owned by the
        // acknowledged AllowFrameReordering=false property above; requiring
        // this unrelated optional property prevented the encoder from ever
        // reaching its physical prepare boundary.
        try Self.setProperty(created, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: codec.maximumBitrate(for: profile)), label: "bitrate")
        try Self.setProperty(created, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: profile.framesPerSecond), label: "frame rate")
        try Self.setProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: profile.framesPerSecond * 2), label: "keyframe interval")
        try Self.setProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 2), label: "keyframe duration")
        try Self.setProperty(created, key: kVTCompressionPropertyKey_ProfileLevel, value: codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel, label: "codec profile")
        let prepare = VTCompressionSessionPrepareToEncodeFrames(created)
        guard prepare == noErr else {
            VTCompressionSessionInvalidate(created)
            throw Self.error("HLS VideoToolbox preparation failed", status: prepare)
        }
        compressionSession = created
    }

    private func installCaptureSink() {
        guard let captureEngine, let frameSource else { return }
        let token = captureEngine.installProgramStreamCaptureSink(role: frameSource.sourceRole) { [weak self] frame in
            self?.submitCaptureFrame(frame)
        }
        stateLock.lock()
        let accepted = active
        if accepted { captureSinkToken = token }
        stateLock.unlock()
        if !accepted { captureEngine.removeProgramStreamCaptureSink(token: token) }
    }

    private func submitCaptureFrame(_ captureFrame: BroadcastRecordingCaptureFrame) {
        stateLock.lock()
        let handoffBlocksIngress = activeCaptureHandoffID != nil && !captureHandoffAwaitingFreshFrame
        stateLock.unlock()
        guard !handoffBlocksIngress else { return }
        guard isActive, let frameSource,
              let source = frameSource.recordingFrame(from: captureFrame) else { return }
        stateLock.lock()
        let cadenceAdmitted = frameCadenceAdmission.admit(
            capturedUptimeNanoseconds: source.capturedUptimeNanoseconds
        )
        stateLock.unlock()
        guard cadenceAdmitted,
              let owned = ingressPool.makeOwnedCopy(of: source.pixelBuffer) else { return }
        let frame = BroadcastRecordingPixelBufferFrame(
            pixelBuffer: owned.pixelBuffer,
            capturedAt: source.capturedAt,
            capturedUptimeNanoseconds: source.capturedUptimeNanoseconds,
            sequence: source.sequence,
            sizeText: source.sizeText,
            sourceDescription: "HLS-owned " + source.sourceDescription,
            cameraRotationDegrees: source.cameraRotationDegrees,
            compositeRotationDegrees: source.compositeRotationDegrees,
            mirrorCorrectionEnabled: source.mirrorCorrectionEnabled,
            overlayCIImage: source.overlayCIImage
        )
        stateLock.lock()
        if ingressBusy {
            pendingFrame = PendingFrame(frame: frame)
            stateLock.unlock()
            return
        }
        ingressBusy = true
        stateLock.unlock()
        queue.async { [weak self] in self?.process(frame) }
    }

    private func process(_ frame: BroadcastRecordingPixelBufferFrame) {
        guard isActive, let outputPool, let session = compressionSession else { finishIngress(); return }
        stateLock.lock()
        let capacityAvailable = inFlightEncodes < 3
        if capacityAvailable { inFlightEncodes += 1 }
        stateLock.unlock()
        guard capacityAvailable else { finishIngress(); return }

        let sourcePTS = CMTime(value: Int64(frame.capturedUptimeNanoseconds), timescale: 1_000_000_000)
        let origin = firstPTS ?? sourcePTS
        if firstPTS == nil { firstPTS = origin }
        let candidatePTS = CMTimeSubtract(sourcePTS, origin)
        stateLock.lock()
        let pts: CMTime
        if candidatePTS > continuitySequencer.lastPTS {
            pts = candidatePTS
            continuitySequencer = .init(lastPTS: candidatePTS)
        } else {
            pts = continuitySequencer.next(cadence: continuityCadence)
        }
        stateLock.unlock()
        guard let composite = BroadcastPixelBufferCompositor.shared.render(
            cameraPixelBuffer: frame.pixelBuffer,
            overlayCIImage: frame.overlayCIImage,
            outputSize: outputSize,
            pixelBufferPool: outputPool,
            cameraRotationDegrees: frame.cameraRotationDegrees,
            compositeRotationDegrees: frame.compositeRotationDegrees,
            mirrorCorrectionEnabled: frame.mirrorCorrectionEnabled
        ) else {
            decrementInFlight()
            finishIngress()
            return
        }
        stateLock.lock()
        if encodedVideoFrames == 0 { firstSubmittedFrameIncludedOverlay = frame.overlayCIImage != nil }
        continuityFrame = composite
        if captureHandoffAwaitingFreshFrame {
            activeCaptureHandoffID = nil
            captureHandoffAwaitingFreshFrame = false
        }
        stateLock.unlock()
        var flags = VTEncodeInfoFlags()
        let encodeStatus = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: composite,
            presentationTimeStamp: pts,
            duration: CMTime(value: 1, timescale: CMTimeScale(outputFrameRate)),
            frameProperties: nil,
            infoFlagsOut: &flags
        ) { [weak self] status, _, sampleBuffer in
            guard let self else { return }
            self.queue.async {
                self.decrementInFlight()
                if status == noErr, let sampleBuffer { self.acceptEncodedVideo(sampleBuffer) }
            }
        }
        if encodeStatus != noErr {
            decrementInFlight()
            fail("HLS video encode failed OSStatus=\(encodeStatus).")
        }
        finishIngress()
    }

    private func emitContinuityFrame(transactionID: UUID) {
        stateLock.lock()
        guard active,
              activeCaptureHandoffID == transactionID,
              let frame = continuityFrame,
              let session = compressionSession else {
            stateLock.unlock()
            return
        }
        let cadence = continuityCadence
        let capacityAvailable = inFlightEncodes < 3
        let pts: CMTime?
        if capacityAvailable {
            inFlightEncodes += 1
            pts = continuitySequencer.next(cadence: cadence)
        } else {
            pts = nil
        }
        stateLock.unlock()

        if let pts {
            var flags = VTEncodeInfoFlags()
            let status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: frame,
                presentationTimeStamp: pts,
                duration: cadence.duration,
                frameProperties: nil,
                infoFlagsOut: &flags
            ) { [weak self] status, _, sampleBuffer in
                guard let self else { return }
                self.queue.async {
                    self.decrementInFlight()
                    if status == noErr, let sampleBuffer { self.acceptEncodedVideo(sampleBuffer) }
                }
            }
            if status != noErr { decrementInFlight() }
        }
        // Encoder backpressure skips only this continuity sample. It cannot end
        // the handoff pacer; the next cadence boundary remains scheduled until a
        // fresh rebound frame clears the transaction ID.
        queue.asyncAfter(deadline: .now() + cadence.duration.seconds) { [weak self] in
            self?.emitContinuityFrame(transactionID: transactionID)
        }
    }

    private func acceptEncodedVideo(_ sampleBuffer: CMSampleBuffer) {
        guard isActive else { return }
        muxer?.appendVideo(sampleBuffer)
        // This encoded packet is the physical origin of the programme. Audio
        // captured before this boundary is deliberately discarded rather than
        // being timestamped ahead of video in the first HLS segment.
        let shouldStartAudio = mediaTimelineAdmission.acceptVideoPacket()
        if shouldStartAudio {
            requestAudioStartAfterFirstVideo()
        }
        encodedVideoFrames += 1
        let count = encodedVideoFrames
        guard count == 1 || count.isMultiple(of: 30), let callbacks else { return }
        let overlay = firstSubmittedFrameIncludedOverlay
        let size = outputSize
        Task { @MainActor in
            if count == 1 {
                callbacks.onFirstProgrammeFrame(overlay, "\(Int(size.width))x\(Int(size.height))")
            }
            callbacks.onVideoFrames(count)
        }
    }

    private func finishIngress() {
        stateLock.lock()
        if let next = pendingFrame {
            pendingFrame = nil
            stateLock.unlock()
            queue.async { [weak self] in self?.process(next.frame) }
        } else {
            ingressBusy = false
            stateLock.unlock()
        }
    }

    private func decrementInFlight() {
        stateLock.lock()
        inFlightEncodes = max(0, inFlightEncodes - 1)
        stateLock.unlock()
    }

    private func requestAudioStartAfterFirstVideo() {
        let lifetimeID = publisherLifetimeID
        let began = ProcessInfo.processInfo.systemUptime
        audioControlQueue.async { [weak self] in
            guard let self else { return }
            let prepared = self.prepareAudioCapture()
            self.queue.async { [weak self] in
                guard let self else {
                    prepared?.stop()
                    return
                }
                guard self.isActive, self.publisherLifetimeID == lifetimeID else {
                    prepared?.stop()
                    return
                }
                if let prepared {
                    self.audioEngine = prepared.engine
                    self.audioConverter = prepared.converter
                    self.audioOutputFormat = prepared.outputFormat
                }
                RinkLensStructuredEventLogger.shared.record(
                    domain: .streaming,
                    event: "hls_startup_resource_stage",
                    entityID: "microphone-capture",
                    previous: ["state": "requested-after-first-video"],
                    next: [
                        "state": prepared == nil ? "unavailable" : "prepared",
                        "stageMs": String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - began) * 1_000),
                        "videoFrames": String(self.encodedVideoFrames),
                        "mainThread": String(Thread.isMainThread)
                    ],
                    source: "RinkLensYouTubeHLSPublisher",
                    reason: "Microphone acquisition completed outside the serial programme-video owner"
                )
            }
        }
    }

    private func prepareAudioCapture() -> PreparedAudioCapture? {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { return nil }
        let channels = min(2, Int(inputFormat.channelCount))
        guard let outputFormat = AVAudioFormat(settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 128_000
        ]), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }
        input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            guard let copy = Self.copyAudioBuffer(buffer) else { return }
            self?.queue.async { [weak self] in self?.encodeAudio(copy) }
        }
        do {
            try engine.start()
            return PreparedAudioCapture(engine: engine, converter: converter, outputFormat: outputFormat)
        } catch {
            input.removeTap(onBus: 0)
            return nil
        }
    }

    private func encodeAudio(_ inputBuffer: AVAudioPCMBuffer) {
        guard isActive,
              mediaTimelineAdmission.admitsAudioPacket,
              let converter = audioConverter,
              let outputFormat = audioOutputFormat else { return }
        let packetCapacity: AVAudioPacketCount = 8
        let output = AVAudioCompressedBuffer(
            format: outputFormat,
            packetCapacity: packetCapacity,
            maximumPacketSize: max(1, converter.maximumOutputPacketSize)
        )
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        guard status != .error, conversionError == nil, output.packetCount > 0 else { return }
        let descriptions = output.packetDescriptions
        let packetCount = Int(output.packetCount)
        var runningOffset = 0
        for index in 0..<packetCount {
            let offset: Int
            let size: Int
            if let descriptions {
                offset = Int(descriptions[index].mStartOffset)
                size = Int(descriptions[index].mDataByteSize)
            } else {
                offset = runningOffset
                size = Int(output.byteLength) / packetCount
            }
            guard size > 0, offset >= 0, offset + size <= Int(output.byteLength) else { continue }
            let packet = Data(bytes: output.data.advanced(by: offset), count: size)
            muxer?.appendAACPacket(packet, pts: audioPTS, sampleRate: outputFormat.sampleRate, channelCount: Int(outputFormat.channelCount))
            audioPTS = CMTimeAdd(audioPTS, CMTime(value: 1_024, timescale: CMTimeScale(outputFormat.sampleRate)))
            encodedAudioPackets += 1
            runningOffset += size
        }
        let count = encodedAudioPackets
        if count == 1 || count.isMultiple(of: 50), let callbacks {
            Task { @MainActor in callbacks.onMicAudioBuffers(count) }
        }
    }

    private func stop(notify: Bool) {
        stateLock.lock()
        let wasActive = active
        active = false
        ingressBusy = false
        pendingFrame = nil
        activeCaptureHandoffID = nil
        captureHandoffAwaitingFreshFrame = false
        continuityFrame = nil
        let token = captureSinkToken
        captureSinkToken = nil
        if !notify { callbacks = nil }
        stateLock.unlock()
        if let token { captureEngine?.removeProgramStreamCaptureSink(token: token) }
        queue.async { [weak self] in
            guard let self else { return }
            stopAudio()
            if let session = compressionSession {
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(session)
            }
            compressionSession = nil
            muxer?.finish()
            muxer = nil
            if notify, wasActive {
                uploader?.finish()
            } else {
                uploader?.cancel()
                uploader = nil
            }
            outputPool = nil
            frameSource = nil
            captureEngine = nil
            if notify, wasActive, uploader == nil, let callbacks {
                Task { @MainActor in callbacks.onStopped() }
            }
        }
    }

    private func stopAudio() {
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        audioConverter = nil
        audioOutputFormat = nil
    }

    private func finishAcknowledged() {
        queue.async { [weak self] in
            guard let self else { return }
            uploader = nil
            let callback = callbacks
            callbacks = nil
            if let callback { Task { @MainActor in callback.onStopped() } }
        }
    }

    private func fail(_ message: String) {
        stateLock.lock()
        guard active || callbacks != nil else { stateLock.unlock(); return }
        active = false
        let token = captureSinkToken
        captureSinkToken = nil
        let callback = callbacks
        callbacks = nil
        stateLock.unlock()
        if let token { captureEngine?.removeProgramStreamCaptureSink(token: token) }
        queue.async { [weak self] in
            guard let self else { return }
            stopAudio()
            if let session = compressionSession { VTCompressionSessionInvalidate(session) }
            compressionSession = nil
            muxer = nil
            uploader?.cancel()
            uploader = nil
            if let callback { Task { @MainActor in callback.onFailure(message) } }
        }
    }

    private var isActive: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return active
    }

    private static func makeOutputPool(size: CGSize) -> CVPixelBufferPool? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let poolAttributes = [kCVPixelBufferPoolMinimumBufferCountKey as String: 3]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary, attributes as CFDictionary, &pool)
        return pool
    }

    private static func copyAudioBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        copy.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }
        for index in 0..<sourceBuffers.count {
            guard let sourceData = sourceBuffers[index].mData, let destinationData = destinationBuffers[index].mData else { return nil }
            let byteCount = Int(sourceBuffers[index].mDataByteSize)
            memcpy(destinationData, sourceData, byteCount)
            destinationBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
        }
        return copy
    }

    private static func error(_ message: String, status: OSStatus) -> NSError {
        NSError(domain: "RinkLens.YouTubeHLS", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "\(message) OSStatus=\(status)."])
    }

    private static func setProperty(_ session: VTCompressionSession, key: CFString, value: CFTypeRef, label: String) throws {
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else { throw error("HLS VideoToolbox rejected \(label)", status: status) }
    }
}
#endif
