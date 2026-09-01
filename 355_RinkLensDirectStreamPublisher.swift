// BUILD 785: in-app programme-output RTMPS publisher.
#if canImport(SwiftUI)
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import HaishinKit
import RTMPHaishinKit
import VideoToolbox

nonisolated struct RinkLensDirectStreamCallbacks: Sendable {
    let onConnecting: @MainActor @Sendable () -> Void
    let onConnected: @MainActor @Sendable () -> Void
    let onStopped: @MainActor @Sendable () -> Void
    let onFailure: @MainActor @Sendable (String) -> Void
    let onFirstProgrammeFrame: @MainActor @Sendable (Bool, String) -> Void
    let onVideoFrames: @MainActor @Sendable (Int) -> Void
    let onMicAudioBuffers: @MainActor @Sendable (Int) -> Void
    let onAppliedBitrate: @MainActor @Sendable (Int) -> Void
    let onCodecConfigured: @MainActor @Sendable (String) -> Void
    let onTransportBytesOut: @MainActor @Sendable (Int) -> Void
    let onMediaContinuity: @MainActor @Sendable (Bool, String) -> Void
}

nonisolated private struct RinkLensStreamUncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

/// Sole owner of the in-process RTMPS session and its bounded programme-frame
/// ingress. It consumes the same cached-overlay compositor contract as recording
/// but owns a separate pool/encoder/network lifetime, so reconnect/stop cannot
/// mutate RecordingWriter or CaptureEngine.
nonisolated final class RinkLensDirectStreamPublisher: @unchecked Sendable {
    private struct PendingFrame: @unchecked Sendable {
        let frame: BroadcastRecordingPixelBufferFrame
    }

    private let queue = DispatchQueue(label: "rinklens.streaming.publisher", qos: .userInitiated)
    private let stateLock = NSLock()
    private let ingressPool = RinkLensFrameHubOwnedBufferPool(minimumBufferCount: 2, allocationThreshold: 3)
    private var outputPool: CVPixelBufferPool?
    private var outputSize = CGSize(width: 1280, height: 720)
    private var outputFrameRate = 60
    private var captureEngine: RinkLensCaptureEngine?
    private var frameSource: BroadcastRecordingPixelBufferFrameSourceContext?
    private var callbacks: RinkLensDirectStreamCallbacks?
    private var session: (any Session)?
    private var stream: (any StreamConvertible)?
    private var captureSinkToken: UUID?
    private var active = false
    private var ingressBusy = false
    private var pendingFrame: PendingFrame?
    private var frameIndex: Int64 = 0
    private var encodedVideoFrameCount = 0
    private var firstSubmittedFrameIncludedOverlay = false
    private var firstPTS: CMTime?
    private var audioEngine: AVAudioEngine?
    private var audioContinuation: AsyncStream<(AVAudioPCMBuffer, AVAudioTime)>.Continuation?
    private var audioDrainTask: Task<Void, Never>?
    private var audioBufferCount = 0
    private var activeCaptureHandoffID: UUID?
    private var captureHandoffAwaitingFreshFrame = false
    private var continuityFrame: CVPixelBuffer?
    private var continuitySequencer = RinkLensOutputContinuitySequencer(lastPTS: .zero)
    private var continuityCadence = RinkLensCaptureCadence(integerFPS: 60)
    private var frameCadenceAdmission = RinkLensStreamFrameCadenceAdmission(targetFramesPerSecond: 60)

    @MainActor
    func start(
        publishURL: URL,
        profile: StreamDestinationStore.QualityProfile,
        codec: StreamDestinationStore.VideoCodec,
        adaptiveBitrate: Bool,
        frameSource: BroadcastRecordingPixelBufferFrameSourceContext,
        callbacks: RinkLensDirectStreamCallbacks
    ) {
        stop(notify: false)
        self.frameSource = frameSource
        self.callbacks = callbacks
        let captureEngine = AppContainer.shared.captureEngine
        self.captureEngine = captureEngine
        outputSize = profile.outputSize
        outputFrameRate = profile.framesPerSecond
        active = true
        frameIndex = 0
        encodedVideoFrameCount = 0
        firstSubmittedFrameIncludedOverlay = false
        audioBufferCount = 0
        firstPTS = nil
        activeCaptureHandoffID = nil
        captureHandoffAwaitingFreshFrame = false
        continuityFrame = nil
        continuitySequencer = .init(lastPTS: .zero)
        continuityCadence = .init(integerFPS: profile.framesPerSecond)
        frameCadenceAdmission.reset(targetFramesPerSecond: profile.framesPerSecond)
        let captureFormat = frameSource.sourceRole == .broadcast
            ? captureEngine.snapshot.liveFormat
            : captureEngine.snapshot.ocrFormat
        _ = ingressPool.prepare(
            width: max(1, Int(captureFormat?.width ?? Int32(profile.outputSize.width.rounded()))),
            height: max(1, Int(captureFormat?.height ?? Int32(profile.outputSize.height.rounded()))),
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        )
        outputPool = Self.makeOutputPool(size: profile.outputSize)
        Task { @MainActor in callbacks.onConnecting() }
        Task { [weak self] in
            await self?.connect(publishURL: publishURL, profile: profile, codec: codec, adaptiveBitrate: adaptiveBitrate)
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
            entityID: "rtmps",
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
            source: "RinkLensDirectStreamPublisher",
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
        // Capture cadence is physical camera truth, not permission to rewrite
        // the stream profile. Keep the publisher's resolved output cadence.
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

    /// Cancels preparation without projecting an operator-visible stop when a
    /// newer start generation replaces this publisher.
    func cancel() {
        stop(notify: false)
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
        let installedCaptureSinkToken = captureSinkToken
        captureSinkToken = nil
        stateLock.unlock()
        if let token = installedCaptureSinkToken {
            captureEngine?.removeProgramStreamCaptureSink(token: token)
        }
        stopAudio()
        let closingSession = session
        let closingStream = stream
        session = nil
        stream = nil
        frameSource = nil
        captureEngine = nil
        outputPool = nil
        let closingCallbacks = callbacks
        self.callbacks = nil
        guard notify, wasActive else {
            if let closingSession {
                Task {
                    if let closingStream { await closingStream.removeOutput(self) }
                    try? await closingSession.close()
                }
            }
            return
        }
        if let closingSession {
            Task {
                do {
                    if let closingStream { await closingStream.removeOutput(self) }
                    try await closingSession.close()
                    if let closingCallbacks { await closingCallbacks.onStopped() }
                } catch {
                    if let closingCallbacks {
                        await closingCallbacks.onFailure("RTMPS close failed: \(error.localizedDescription)")
                    }
                }
            }
        } else if let closingCallbacks {
            Task { @MainActor in closingCallbacks.onStopped() }
        }
    }

    private func connect(
        publishURL: URL,
        profile: StreamDestinationStore.QualityProfile,
        codec: StreamDestinationStore.VideoCodec,
        adaptiveBitrate: Bool
    ) async {
        do {
            await SessionBuilderFactory.shared.register(RTMPSessionFactory())
            guard let built = try await SessionBuilderFactory.shared.make(publishURL).build() else {
                throw NSError(domain: "RinkLens.DirectStream", code: 1, userInfo: [NSLocalizedDescriptionKey: "RTMPS session could not be created."])
            }
            guard isActive else { try? await built.close(); return }
            session = built
            let output = await built.stream
            await output.addOutput(self)
            let maximumBitrate = codec.maximumBitrate(for: profile)
            try await output.setVideoSettings(VideoCodecSettings(
                videoSize: profile.outputSize,
                bitRate: maximumBitrate,
                profileLevel: codec.videoToolboxProfileLevel,
                scalingMode: .letterbox,
                bitRateMode: .constant,
                maxKeyFrameIntervalDuration: 2,
                allowFrameReordering: false,
                dataRateLimits: nil,
                isLowLatencyRateControlEnabled: true,
                expectedFrameRate: Double(profile.framesPerSecond)
            ))
            if let callbacks {
                await callbacks.onCodecConfigured(codec.encoderName)
            }
            try await output.setAudioSettings(AudioCodecSettings(
                bitRate: 128_000,
                downmix: true,
                sampleRate: 48_000,
                format: .aac
            ))
            await output.setVideoInputBufferCounts(5)
            if let callbacks {
                await output.setBitRateStrategy(RinkLensQualityFloorBitRateStrategy(
                    maximumVideoBitRate: maximumBitrate,
                    minimumVideoBitRate: codec.minimumBitrate(for: profile),
                    adaptiveBitrateEnabled: adaptiveBitrate,
                    onAppliedBitrate: { bitrate in
                        Task { @MainActor in callbacks.onAppliedBitrate(bitrate) }
                    },
                    onTransportBytesOut: { bytesPerSecond in
                        Task { @MainActor in callbacks.onTransportBytesOut(bytesPerSecond) }
                    }
                ))
            }
            try await built.connect { [weak self] in self?.connectionClosed() }
            guard isActive else { try? await built.close(); return }
            // Do not let HaishinKit accept and internally queue programme frames
            // before the RTMPS socket is physically connected. The prior order
            // acknowledged frame one 4.74s before connect in b84.
            stream = output
            installCaptureSinkAfterPhysicalConnect()
            startAudio()
            if let callbacks { Task { @MainActor in callbacks.onConnected() } }
        } catch {
            fail(error.localizedDescription)
        }
    }

    private var isActive: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return active
    }

    /// Capture ingress starts only after RTMPS connect. This removes the b84
    /// pre-connect wave of synchronous 1080p copies that produced AVFoundation
    /// late/out-of-buffer drops while recording was already active.
    private func installCaptureSinkAfterPhysicalConnect() {
        guard let captureEngine, let frameSource else { return }
        let token = captureEngine.installProgramStreamCaptureSink(role: frameSource.sourceRole) { [weak self] frame in
            self?.submitCaptureFrame(frame)
        }
        stateLock.lock()
        let accepted = active
        if accepted { captureSinkToken = token }
        stateLock.unlock()
        if !accepted {
            captureEngine.removeProgramStreamCaptureSink(token: token)
        }
    }

    private func connectionClosed() {
        guard isActive else { return }
        fail("The RTMPS publisher connection closed.")
    }

    private func fail(_ message: String) {
        guard isActive else { return }
        let callback = callbacks
        stop(notify: false)
        if let callback { Task { @MainActor in callback.onFailure(message) } }
    }

    /// Called synchronously from CaptureEngine. Copy into the publisher-owned
    /// three-surface pool before returning; active+latest pending bounds all work.
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
            sourceDescription: "Streaming-owned " + source.sourceDescription,
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
        guard isActive, let stream, let outputPool else { finishIngress(); return }
        let sourcePTS = CMTime(value: Int64(frame.capturedUptimeNanoseconds), timescale: 1_000_000_000)
        let originPTS = firstPTS ?? sourcePTS
        if firstPTS == nil { firstPTS = originPTS }
        let candidatePTS = CMTimeSubtract(sourcePTS, originPTS)
        stateLock.lock()
        let programmePTS: CMTime
        if candidatePTS > continuitySequencer.lastPTS {
            programmePTS = candidatePTS
            continuitySequencer = .init(lastPTS: candidatePTS)
        } else {
            programmePTS = continuitySequencer.next(cadence: continuityCadence)
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
        ), let sample = Self.makeVideoSample(
            pixelBuffer: composite,
            presentationTimeStamp: programmePTS,
            framesPerSecond: outputFrameRate
        ) else { finishIngress(); return }
        stateLock.lock()
        continuityFrame = composite
        if captureHandoffAwaitingFreshFrame {
            activeCaptureHandoffID = nil
            captureHandoffAwaitingFreshFrame = false
        }
        stateLock.unlock()
        frameIndex &+= 1
        let publishedFrameCount = Int(frameIndex)
        if publishedFrameCount == 1 {
            stateLock.lock()
            firstSubmittedFrameIncludedOverlay = frame.overlayCIImage != nil
            stateLock.unlock()
        }
        let sampleBox = RinkLensStreamUncheckedSendable(value: sample)
        Task { [weak self] in
            await stream.append(sampleBox.value)
            self?.queue.async { [weak self] in self?.finishIngress() }
        }
    }

    private func emitContinuityFrame(transactionID: UUID) {
        stateLock.lock()
        guard active,
              activeCaptureHandoffID == transactionID,
              let frame = continuityFrame,
              let stream else {
            stateLock.unlock()
            return
        }
        let cadence = continuityCadence
        let pts = continuitySequencer.next(cadence: cadence)
        stateLock.unlock()
        guard let sample = Self.makeVideoSample(
            pixelBuffer: frame,
            presentationTimeStamp: pts,
            framesPerSecond: cadence.nominalFPS
        ) else { return }
        let sampleBox = RinkLensStreamUncheckedSendable(value: sample)
        Task { [weak self] in
            await stream.append(sampleBox.value)
            guard let self else { return }
            self.queue.asyncAfter(deadline: .now() + cadence.duration.seconds) { [weak self] in
                self?.emitContinuityFrame(transactionID: transactionID)
            }
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

    private func startAudio() {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        var sink: AsyncStream<(AVAudioPCMBuffer, AVAudioTime)>.Continuation?
        let audioStream = AsyncStream<(AVAudioPCMBuffer, AVAudioTime)>(bufferingPolicy: .bufferingNewest(4)) { sink = $0 }
        audioContinuation = sink
        audioDrainTask = Task { [weak self] in
            guard let self else { return }
            for await (buffer, time) in audioStream where !Task.isCancelled {
                guard let stream = self.stream else { continue }
                await stream.append(buffer, when: time)
                self.audioBufferCount &+= 1
                let count = self.audioBufferCount
                if count == 1 || count.isMultiple(of: 50), let callbacks = self.callbacks {
                    await callbacks.onMicAudioBuffers(count)
                }
            }
        }
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, time in
            guard let copy = Self.copyAudioBuffer(buffer) else { return }
            self?.audioContinuation?.yield((copy, time))
        }
        do {
            try engine.start()
            audioEngine = engine
        } catch {
            input.removeTap(onBus: 0)
            audioContinuation?.finish()
            audioContinuation = nil
        }
    }

    private func stopAudio() {
        audioContinuation?.finish()
        audioContinuation = nil
        audioDrainTask?.cancel()
        audioDrainTask = nil
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
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

    private static func makeVideoSample(
        pixelBuffer: CVPixelBuffer,
        presentationTimeStamp: CMTime,
        framesPerSecond: Int
    ) -> CMSampleBuffer? {
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &description) == noErr,
              let description else { return nil }
        let duration = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: description,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr else { return nil }
        return sample
    }
}

extension RinkLensDirectStreamPublisher: StreamOutput {
    nonisolated func stream(_ stream: some StreamConvertible, didOutput audio: AVAudioBuffer, when: AVAudioTime) {
        // Microphone input acknowledgement is tracked at the bounded audio
        // ingress. Video requires the stronger encoded-output boundary below.
    }

    nonisolated func stream(_ stream: some StreamConvertible, didOutput video: CMSampleBuffer) {
        guard let format = video.formatDescription else { return }
        let mediaSubtype = CMFormatDescriptionGetMediaSubType(format)
        guard mediaSubtype == kCMVideoCodecType_H264 || mediaSubtype == kCMVideoCodecType_HEVC else { return }
        stateLock.lock()
        guard active else { stateLock.unlock(); return }
        encodedVideoFrameCount &+= 1
        let count = encodedVideoFrameCount
        let includedOverlay = firstSubmittedFrameIncludedOverlay
        let callback = callbacks
        let size = outputSize
        stateLock.unlock()
        guard count == 1 || count.isMultiple(of: 30), let callback else { return }
        Task { @MainActor in
            if count == 1 {
                callback.onFirstProgrammeFrame(
                    includedOverlay,
                    "\(Int(size.width))x\(Int(size.height))"
                )
            }
            callback.onVideoFrames(count)
        }
    }
}

extension StreamDestinationStore.QualityProfile {
    nonisolated var outputSize: CGSize {
        switch self {
        case .hd720p60: return CGSize(width: 1280, height: 720)
        case .fullHD1080p60, .fullHD1080p30: return CGSize(width: 1920, height: 1080)
        }
    }

}

extension StreamDestinationStore.VideoCodec {
    nonisolated var videoToolboxProfileLevel: String {
        switch self {
        case .h264: return kVTProfileLevel_H264_High_AutoLevel as String
        case .hevc: return kVTProfileLevel_HEVC_Main_AutoLevel as String
        }
    }
}

/// Network adaptation may protect delivery but must not silently reduce an
/// information-dense sports programme to an illegible 10% bitrate. This owner
/// keeps the selected resolution/FPS and enforces a legibility floor.
private actor RinkLensQualityFloorBitRateStrategy: StreamBitRateStrategy {
    let mamimumVideoBitRate: Int
    let mamimumAudioBitRate = 0
    private let minimumVideoBitRate: Int
    private let adaptiveBitrateEnabled: Bool
    private let onAppliedBitrate: @Sendable (Int) -> Void
    private let onTransportBytesOut: @Sendable (Int) -> Void
    private var sufficientReports = 0

    init(
        maximumVideoBitRate: Int,
        minimumVideoBitRate: Int,
        adaptiveBitrateEnabled: Bool,
        onAppliedBitrate: @escaping @Sendable (Int) -> Void,
        onTransportBytesOut: @escaping @Sendable (Int) -> Void
    ) {
        self.mamimumVideoBitRate = maximumVideoBitRate
        self.minimumVideoBitRate = min(maximumVideoBitRate, minimumVideoBitRate)
        self.adaptiveBitrateEnabled = adaptiveBitrateEnabled
        self.onAppliedBitrate = onAppliedBitrate
        self.onTransportBytesOut = onTransportBytesOut
    }

    func adjustBitrate(_ event: NetworkMonitorEvent, stream: some StreamConvertible) async {
        switch event {
        case .publishInsufficientBWOccured(let report), .status(let report):
            onTransportBytesOut(report.currentBytesOutPerSecond)
        case .reset:
            onTransportBytesOut(0)
        }
        guard adaptiveBitrateEnabled else { return }
        var settings = await stream.videoSettings
        switch event {
        case .publishInsufficientBWOccured(let report):
            sufficientReports = 0
            let audioBitrate = await stream.audioSettings.bitRate
            let measured = max(0, Int(report.currentBytesOutPerSecond * 8) - audioBitrate)
            settings.bitRate = max(minimumVideoBitRate, min(mamimumVideoBitRate, measured))
        case .status:
            sufficientReports += 1
            guard sufficientReports >= 5, settings.bitRate < mamimumVideoBitRate else { return }
            settings.bitRate = min(mamimumVideoBitRate, settings.bitRate + mamimumVideoBitRate / 10)
            sufficientReports = 0
        case .reset:
            sufficientReports = 0
            settings.bitRate = mamimumVideoBitRate
        }
        settings.frameInterval = 0
        try? await stream.setVideoSettings(settings)
        onAppliedBitrate(settings.bitRate)
    }
}
#endif
