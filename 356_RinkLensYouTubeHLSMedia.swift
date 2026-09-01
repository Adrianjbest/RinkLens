// BUILD 785: YouTube HLS MPEG-2 TS muxing and acknowledged HTTPS upload.
#if canImport(SwiftUI)
import AVFoundation
import CoreMedia
import Foundation

nonisolated struct RinkLensHLSSegment: Sendable {
    let sequence: Int
    let duration: TimeInterval
    let filename: String
    let data: Data
    let videoFrameCount: Int
    let audioPacketCount: Int
    let videoPayloadBytes: Int
    let audioPayloadBytes: Int
    let maximumVideoGapMilliseconds: Double
    let observedAudioPacketDuration: TimeInterval?
    let videoTimelineDuration: TimeInterval
    let audioTimelineDuration: TimeInterval
    let audioVideoTimelineDriftMilliseconds: Double
    let createdUptime: TimeInterval
}

nonisolated enum RinkLensHLSContinuityWarningReason: String, Sendable, Hashable {
    case insufficientVideoFrames
    case insufficientAudioPackets
    case excessiveVideoGap
    case audioVideoTimelineDrift
}

nonisolated struct RinkLensHLSContinuityEvaluation: Sendable, Equatable {
    let minimumExpectedVideoFrames: Int
    let minimumExpectedAudioPackets: Int
    let reasons: Set<RinkLensHLSContinuityWarningReason>

    var shouldWarn: Bool { !reasons.isEmpty }
}

/// Build 134 evaluates each accepted segment against its resolved video rate
/// and the encoded AAC access-unit timing observed by the muxer.
nonisolated enum RinkLensHLSContinuityPolicy {
    static func evaluate(
        duration: TimeInterval,
        videoFrameCount: Int,
        audioPacketCount: Int,
        maximumVideoGapMilliseconds: Double,
        targetVideoFPS: Int,
        observedAudioPacketDuration: TimeInterval?,
        audioVideoTimelineDriftMilliseconds: Double = 0
    ) -> RinkLensHLSContinuityEvaluation {
        let minimumVideo = Int((duration * Double(targetVideoFPS) * 0.75).rounded(.down))
        let minimumAudio: Int
        if let observedAudioPacketDuration, observedAudioPacketDuration > 0 {
            minimumAudio = Int((duration / observedAudioPacketDuration * 0.75).rounded(.down))
        } else {
            minimumAudio = duration >= 1 ? 1 : 0
        }
        var reasons = Set<RinkLensHLSContinuityWarningReason>()
        if duration >= 1, videoFrameCount < minimumVideo { reasons.insert(.insufficientVideoFrames) }
        if duration >= 1, audioPacketCount < minimumAudio { reasons.insert(.insufficientAudioPackets) }
        if maximumVideoGapMilliseconds > 100 { reasons.insert(.excessiveVideoGap) }
        if audioVideoTimelineDriftMilliseconds > 250 { reasons.insert(.audioVideoTimelineDrift) }
        return .init(
            minimumExpectedVideoFrames: minimumVideo,
            minimumExpectedAudioPackets: minimumAudio,
            reasons: reasons
        )
    }
}

/// One publisher-owned cadence gate. CaptureEngine may continue delivering its
/// physically applied 60 fps while a concurrent YouTube profile is resolved to
/// 30 fps; the stream publisher admits only the frames belonging to its own
/// output timeline before allocating/copying pixel memory. Source timestamps are
/// never rewritten to manufacture the requested cadence.
nonisolated struct RinkLensStreamFrameCadenceAdmission: Sendable, Equatable {
    private(set) var targetFramesPerSecond: Int
    private(set) var nextEligibleUptimeNanoseconds: UInt64?
    private(set) var admittedFrameCount = 0
    private(set) var rejectedFrameCount = 0

    init(targetFramesPerSecond: Int) {
        self.targetFramesPerSecond = max(1, targetFramesPerSecond)
    }

    mutating func reset(targetFramesPerSecond: Int) {
        self.targetFramesPerSecond = max(1, targetFramesPerSecond)
        nextEligibleUptimeNanoseconds = nil
        admittedFrameCount = 0
        rejectedFrameCount = 0
    }

    mutating func admit(capturedUptimeNanoseconds: UInt64) -> Bool {
        let interval = max(1, UInt64(1_000_000_000 / targetFramesPerSecond))
        guard let nextEligible = nextEligibleUptimeNanoseconds else {
            admittedFrameCount += 1
            nextEligibleUptimeNanoseconds = capturedUptimeNanoseconds &+ interval
            return true
        }
        guard capturedUptimeNanoseconds >= nextEligible else {
            rejectedFrameCount += 1
            return false
        }
        admittedFrameCount += 1
        var following = nextEligible
        repeat { following = following &+ interval }
        while following <= capturedUptimeNanoseconds
        nextEligibleUptimeNanoseconds = following
        return true
    }
}

/// Publisher-owned admission for the common HLS media timeline. Microphone
/// capture may be physically ready before the camera/compositor/VideoToolbox
/// path produces its first packet. Those early samples cannot belong to the
/// programme timeline: admitting them gives the first segment an audio lead
/// and prevents the continuity owner from acknowledging active publishing.
nonisolated struct RinkLensHLSMediaTimelineAdmission: Sendable, Equatable {
    private(set) var videoPacketAccepted = false
    private(set) var audioStartRequested = false

    var admitsAudioPacket: Bool { videoPacketAccepted }

    /// Returns true exactly once, at the physical video-origin boundary, so
    /// microphone acquisition can begin without racing publisher prepare or
    /// blocking the serial video path.
    @discardableResult
    mutating func acceptVideoPacket() -> Bool {
        videoPacketAccepted = true
        guard !audioStartRequested else { return false }
        audioStartRequested = true
        return true
    }

    mutating func reset() {
        videoPacketAccepted = false
        audioStartRequested = false
    }
}

/// Queue-confined MPEG-2 transport-stream muxer for one HEVC/H.264 + AAC
/// programme. Every segment starts with PAT/PMT and a video random-access point.
nonisolated final class RinkLensMPEGTSMuxer: @unchecked Sendable {
    private static let packetSize = 188
    private static let pmtPID: UInt16 = 0x0100
    private static let videoPID: UInt16 = 0x0101
    private static let audioPID: UInt16 = 0x0102

    private let sessionID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private let onSegment: @Sendable (RinkLensHLSSegment) -> Void
    private let onFailure: @Sendable (String) -> Void
    private var videoStreamType: UInt8 = 0x24
    private var continuity: [UInt16: UInt8] = [:]
    private var current = Data()
    private var currentStartPTS: CMTime?
    private var currentLastPTS: CMTime?
    private var currentHasVideo = false
    private var currentVideoFrameCount = 0
    private var currentAudioPacketCount = 0
    private var currentVideoPayloadBytes = 0
    private var currentAudioPayloadBytes = 0
    private var currentLastVideoPTS: CMTime?
    private var currentFirstVideoPTS: CMTime?
    private var currentMaximumVideoGapMilliseconds: Double = 0
    private var currentLastAudioPTS: CMTime?
    private var currentFirstAudioPTS: CMTime?
    private var currentAudioGapTotalSeconds: TimeInterval = 0
    private var currentAudioGapCount = 0
    private var sequence = 0

    init(
        onSegment: @escaping @Sendable (RinkLensHLSSegment) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.onSegment = onSegment
        self.onFailure = onFailure
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let format = sampleBuffer.formatDescription,
              let block = CMSampleBufferGetDataBuffer(sampleBuffer),
              let encoded = Self.copy(block) else { return }
        let subtype = CMFormatDescriptionGetMediaSubType(format)
        guard subtype == kCMVideoCodecType_HEVC || subtype == kCMVideoCodecType_H264 else { return }
        videoStreamType = subtype == kCMVideoCodecType_HEVC ? 0x24 : 0x1B
        let pts = sampleBuffer.presentationTimeStamp
        let keyFrame = Self.isKeyFrame(sampleBuffer)

        if keyFrame,
           let start = currentStartPTS,
           currentHasVideo,
           CMTimeSubtract(pts, start).seconds >= 1.5 {
            emitCurrentSegment()
        }
        if currentStartPTS == nil {
            guard keyFrame else { return }
            beginSegment(at: pts)
        }

        var elementary = Data()
        if keyFrame {
            for parameterSet in Self.parameterSets(format: format, subtype: subtype) {
                elementary.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                elementary.append(parameterSet)
            }
        }
        elementary.append(Self.annexBPayload(encoded, nalLengthSize: Self.nalLengthSize(format: format, subtype: subtype)))
        guard !elementary.isEmpty else { return }
        if let previousVideoPTS = currentLastVideoPTS {
            currentMaximumVideoGapMilliseconds = max(
                currentMaximumVideoGapMilliseconds,
                max(0, CMTimeSubtract(pts, previousVideoPTS).seconds * 1_000)
            )
        }
        let pes = Self.makePES(streamID: 0xE0, payload: elementary, pts: pts, unboundedLength: true)
        current.append(packetize(pes, pid: Self.videoPID, payloadStart: true, pcr: pts))
        currentHasVideo = true
        if currentFirstVideoPTS == nil { currentFirstVideoPTS = pts }
        currentVideoFrameCount += 1
        currentVideoPayloadBytes += elementary.count
        currentLastVideoPTS = pts
        currentLastPTS = pts
    }

    func appendAACPacket(_ packet: Data, pts: CMTime, sampleRate: Double, channelCount: Int) {
        guard currentStartPTS != nil, !packet.isEmpty,
              let adts = Self.makeADTSHeader(payloadLength: packet.count, sampleRate: sampleRate, channelCount: channelCount) else { return }
        var payload = adts
        payload.append(packet)
        let pes = Self.makePES(streamID: 0xC0, payload: payload, pts: pts, unboundedLength: false)
        current.append(packetize(pes, pid: Self.audioPID, payloadStart: true, pcr: nil))
        currentAudioPacketCount += 1
        currentAudioPayloadBytes += payload.count
        if currentFirstAudioPTS == nil { currentFirstAudioPTS = pts }
        if let previousAudioPTS = currentLastAudioPTS {
            let gap = CMTimeSubtract(pts, previousAudioPTS).seconds
            if gap > 0, gap.isFinite {
                currentAudioGapTotalSeconds += gap
                currentAudioGapCount += 1
            }
        }
        currentLastAudioPTS = pts
        if currentLastPTS == nil || CMTimeCompare(pts, currentLastPTS!) > 0 { currentLastPTS = pts }
    }

    func finish() {
        emitCurrentSegment()
    }

    private func beginSegment(at pts: CMTime) {
        current.removeAll(keepingCapacity: true)
        currentStartPTS = pts
        currentLastPTS = pts
        currentHasVideo = false
        currentVideoFrameCount = 0
        currentAudioPacketCount = 0
        currentVideoPayloadBytes = 0
        currentAudioPayloadBytes = 0
        currentLastVideoPTS = nil
        currentFirstVideoPTS = nil
        currentMaximumVideoGapMilliseconds = 0
        currentLastAudioPTS = nil
        currentFirstAudioPTS = nil
        currentAudioGapTotalSeconds = 0
        currentAudioGapCount = 0
        current.append(psiPacket(pid: 0x0000, section: Self.makePAT()))
        current.append(psiPacket(pid: Self.pmtPID, section: Self.makePMT(videoStreamType: videoStreamType)))
    }

    private func emitCurrentSegment() {
        guard let start = currentStartPTS, currentHasVideo, current.count >= Self.packetSize * 2 else {
            current.removeAll(keepingCapacity: true)
            currentStartPTS = nil
            currentLastPTS = nil
            currentHasVideo = false
            return
        }
        let end = currentLastPTS ?? start
        let duration = max(0.001, CMTimeSubtract(end, start).seconds)
        let packetCount = current.count / Self.packetSize
        let allPacketsAligned = current.count.isMultiple(of: Self.packetSize)
            && (0..<packetCount).allSatisfy { current[$0 * Self.packetSize] == 0x47 }
        let firstPID = current.count >= Self.packetSize ? (UInt16(current[1] & 0x1F) << 8) | UInt16(current[2]) : UInt16.max
        let secondPID = current.count >= Self.packetSize * 2 ? (UInt16(current[Self.packetSize + 1] & 0x1F) << 8) | UInt16(current[Self.packetSize + 2]) : UInt16.max
        guard allPacketsAligned, firstPID == 0x0000, secondPID == Self.pmtPID else {
            current = Data()
            currentStartPTS = nil
            currentLastPTS = nil
            currentHasVideo = false
            onFailure("HLS MPEG-2 TS segment failed packet/PAT/PMT validation before upload.")
            return
        }
        let observedAudioPacketDuration = currentAudioGapCount > 0
            ? currentAudioGapTotalSeconds / Double(currentAudioGapCount)
            : nil
        let videoTimelineDuration: TimeInterval = {
            guard let first = currentFirstVideoPTS, let last = currentLastVideoPTS else { return 0 }
            return max(0, CMTimeSubtract(last, first).seconds)
        }()
        let audioTimelineDuration: TimeInterval = {
            guard let first = currentFirstAudioPTS, let last = currentLastAudioPTS else { return 0 }
            return max(0, CMTimeSubtract(last, first).seconds + (observedAudioPacketDuration ?? 0))
        }()
        let segment = RinkLensHLSSegment(
            sequence: sequence,
            duration: duration,
            filename: String(format: "rinklens_%@_%06d.ts", sessionID, sequence),
            data: current,
            videoFrameCount: currentVideoFrameCount,
            audioPacketCount: currentAudioPacketCount,
            videoPayloadBytes: currentVideoPayloadBytes,
            audioPayloadBytes: currentAudioPayloadBytes,
            maximumVideoGapMilliseconds: currentMaximumVideoGapMilliseconds,
            observedAudioPacketDuration: observedAudioPacketDuration,
            videoTimelineDuration: videoTimelineDuration,
            audioTimelineDuration: audioTimelineDuration,
            audioVideoTimelineDriftMilliseconds: abs(videoTimelineDuration - audioTimelineDuration) * 1_000,
            createdUptime: ProcessInfo.processInfo.systemUptime
        )
        sequence += 1
        current = Data()
        currentStartPTS = nil
        currentLastPTS = nil
        currentHasVideo = false
        onSegment(segment)
    }

    private func psiPacket(pid: UInt16, section: Data) -> Data {
        var payload = Data([0x00])
        payload.append(section)
        let counter = nextContinuity(pid)
        var packet = Data([
            0x47,
            0x40 | UInt8((pid >> 8) & 0x1F),
            UInt8(pid & 0xFF),
            0x10 | counter
        ])
        packet.append(payload.prefix(184))
        if packet.count < Self.packetSize {
            packet.append(Data(repeating: 0xFF, count: Self.packetSize - packet.count))
        }
        return packet
    }

    private func packetize(_ payload: Data, pid: UInt16, payloadStart: Bool, pcr: CMTime?) -> Data {
        var result = Data()
        var offset = 0
        var first = true
        while offset < payload.count {
            let requiresPCR = first && pcr != nil
            let minimumAdaptationBytes = requiresPCR ? 8 : 0
            let maximumPayload = 184 - minimumAdaptationBytes
            var take = min(maximumPayload, payload.count - offset)
            var adaptationBytes = 184 - take
            if adaptationBytes == 0, requiresPCR {
                adaptationBytes = 8
                take = min(176, payload.count - offset)
            }

            let counter = nextContinuity(pid)
            var packet = Data([
                0x47,
                (first && payloadStart ? 0x40 : 0x00) | UInt8((pid >> 8) & 0x1F),
                UInt8(pid & 0xFF),
                (adaptationBytes > 0 ? 0x30 : 0x10) | counter
            ])
            if adaptationBytes > 0 {
                let fieldLength = adaptationBytes - 1
                packet.append(UInt8(fieldLength))
                if fieldLength > 0 {
                    packet.append(requiresPCR ? 0x10 : 0x00)
                    var used = 1
                    if requiresPCR, let pcr {
                        packet.append(Self.encodePCR(pcr))
                        used += 6
                    }
                    if fieldLength > used {
                        packet.append(Data(repeating: 0xFF, count: fieldLength - used))
                    }
                }
            }
            packet.append(payload[offset..<(offset + take)])
            if packet.count < Self.packetSize {
                packet.append(Data(repeating: 0xFF, count: Self.packetSize - packet.count))
            }
            result.append(packet)
            offset += take
            first = false
        }
        return result
    }

    private func nextContinuity(_ pid: UInt16) -> UInt8 {
        let value = continuity[pid] ?? 0
        continuity[pid] = (value + 1) & 0x0F
        return value
    }

    private static func makePAT() -> Data {
        var section = Data([0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01, 0xE1, 0x00])
        appendCRC(to: &section)
        return section
    }

    private static func makePMT(videoStreamType: UInt8) -> Data {
        var section = Data([
            0x02, 0xB0, 0x17, 0x00, 0x01, 0xC1, 0x00, 0x00,
            0xE1, 0x01, 0xF0, 0x00,
            videoStreamType, 0xE1, 0x01, 0xF0, 0x00,
            0x0F, 0xE1, 0x02, 0xF0, 0x00
        ])
        appendCRC(to: &section)
        return section
    }

    private static func appendCRC(to data: inout Data) {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
            }
        }
        data.append(UInt8((crc >> 24) & 0xFF))
        data.append(UInt8((crc >> 16) & 0xFF))
        data.append(UInt8((crc >> 8) & 0xFF))
        data.append(UInt8(crc & 0xFF))
    }

    private static func makePES(streamID: UInt8, payload: Data, pts: CMTime, unboundedLength: Bool) -> Data {
        let optionalLength = 8
        let packetLength = unboundedLength ? 0 : min(0xFFFF, payload.count + optionalLength)
        var data = Data([0x00, 0x00, 0x01, streamID, UInt8((packetLength >> 8) & 0xFF), UInt8(packetLength & 0xFF), 0x80, 0x80, 0x05])
        data.append(encodePTS(pts))
        data.append(payload)
        return data
    }

    private static func encodePTS(_ time: CMTime) -> Data {
        let value = UInt64(max(0, Int64((time.seconds * 90_000).rounded()))) & 0x1_FFFF_FFFF
        return Data([
            0x20 | UInt8((value >> 29) & 0x0E) | 0x01,
            UInt8((value >> 22) & 0xFF),
            UInt8((value >> 14) & 0xFE) | 0x01,
            UInt8((value >> 7) & 0xFF),
            UInt8((value << 1) & 0xFE) | 0x01
        ])
    }

    private static func encodePCR(_ time: CMTime) -> Data {
        let base = UInt64(max(0, Int64((time.seconds * 90_000).rounded()))) & 0x1_FFFF_FFFF
        return Data([
            UInt8((base >> 25) & 0xFF), UInt8((base >> 17) & 0xFF),
            UInt8((base >> 9) & 0xFF), UInt8((base >> 1) & 0xFF),
            UInt8((base & 1) << 7) | 0x7E, 0x00
        ])
    }

    private static func makeADTSHeader(payloadLength: Int, sampleRate: Double, channelCount: Int) -> Data? {
        let rates: [Int] = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350]
        guard let rateIndex = rates.firstIndex(of: Int(sampleRate.rounded())) else { return nil }
        let channels = max(1, min(7, channelCount))
        let frameLength = payloadLength + 7
        guard frameLength < 0x2000 else { return nil }
        return Data([
            0xFF, 0xF1,
            0x40 | UInt8(rateIndex << 2) | UInt8((channels >> 2) & 0x01),
            UInt8((channels & 0x03) << 6) | UInt8((frameLength >> 11) & 0x03),
            UInt8((frameLength >> 3) & 0xFF),
            UInt8((frameLength & 0x07) << 5) | 0x1F,
            0xFC
        ])
    }

    private static func isKeyFrame(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }

    private static func copy(_ block: CMBlockBuffer) -> Data? {
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return kCMBlockBufferBadCustomBlockSourceErr }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        return status == kCMBlockBufferNoErr ? data : nil
    }

    private static func annexBPayload(_ data: Data, nalLengthSize: Int) -> Data {
        guard nalLengthSize > 0 else { return data }
        var output = Data()
        var offset = 0
        while offset + nalLengthSize <= data.count {
            var length = 0
            for index in 0..<nalLengthSize { length = (length << 8) | Int(data[offset + index]) }
            offset += nalLengthSize
            guard length > 0, offset + length <= data.count else { break }
            output.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            output.append(data[offset..<(offset + length)])
            offset += length
        }
        return output
    }

    private static func nalLengthSize(format: CMFormatDescription, subtype: FourCharCode) -> Int {
        var headerLength: Int32 = 4
        if subtype == kCMVideoCodecType_HEVC {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: nil, nalUnitHeaderLengthOut: &headerLength)
        } else {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: nil, nalUnitHeaderLengthOut: &headerLength)
        }
        return Int(headerLength)
    }

    private static func parameterSets(format: CMFormatDescription, subtype: FourCharCode) -> [Data] {
        var result: [Data] = []
        let maximum = subtype == kCMVideoCodecType_HEVC ? 3 : 2
        for index in 0..<maximum {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            var count = 0
            var headerLength: Int32 = 0
            let status: OSStatus
            if subtype == kCMVideoCodecType_HEVC {
                status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
            } else {
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
            }
            if status == noErr, let pointer, size > 0 { result.append(Data(bytes: pointer, count: size)) }
        }
        return result
    }
}

nonisolated struct RinkLensHLSUploadCallbacks: Sendable {
    let onAccepted: @Sendable (RinkLensHLSSegment, Int) -> Void
    let onFailure: @Sendable (String) -> Void
    let onFinished: @Sendable () -> Void
}

nonisolated private enum RinkLensHLSUploadResult: Sendable {
    case success(Int)
    case failure(String)
}

/// Owns ordered HLS HTTP requests. One request is active; at most five complete
/// segments may wait, matching YouTube's outstanding-segment ceiling.
nonisolated final class RinkLensHLSUploader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "rinklens.streaming.hls.upload", qos: .utility)
    private let session: URLSession
    private let baseURLText: String
    private let callbacks: RinkLensHLSUploadCallbacks
    private var pending: [RinkLensHLSSegment] = []
    private var acknowledged: [RinkLensHLSSegment] = []
    private var active = false
    private var failed = false
    private var finishRequested = false

    init(baseURLText: String, callbacks: RinkLensHLSUploadCallbacks) {
        self.baseURLText = baseURLText
        self.callbacks = callbacks
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: configuration)
    }

    func enqueue(_ segment: RinkLensHLSSegment) {
        queue.async { [weak self] in
            guard let self, !failed else { return }
            guard pending.count < 5 else {
                fail("HLS upload backlog reached YouTube's five-segment limit.")
                return
            }
            pending.append(segment)
            drainIfNeeded()
        }
    }

    func finish() {
        queue.async { [weak self] in
            guard let self, !failed else { return }
            finishRequested = true
            drainIfNeeded()
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            failed = true
            pending.removeAll()
            session.invalidateAndCancel()
        }
    }

    private func drainIfNeeded() {
        guard !active, !failed else { return }
        guard let next = pending.first else {
            if finishRequested { uploadFinalPlaylist() }
            return
        }
        active = true
        let playlistSegments = Array(acknowledged.suffix(2)) + [next]
        let playlist = Self.playlistData(segments: playlistSegments, endList: false)
        upload(data: playlist, filename: "rinklens.m3u8", contentType: "application/vnd.apple.mpegurl", attempt: 0) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): fail(error)
            case .success:
                upload(data: next.data, filename: next.filename, contentType: "video/MP2T", attempt: 0) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .failure(let error): fail(error)
                    case .success(let status):
                        if pending.first?.sequence == next.sequence { pending.removeFirst() }
                        acknowledged.append(next)
                        if acknowledged.count > 3 { acknowledged.removeFirst(acknowledged.count - 3) }
                        active = false
                        callbacks.onAccepted(next, status)
                        drainIfNeeded()
                    }
                }
            }
        }
    }

    private func uploadFinalPlaylist() {
        guard !active, !failed else { return }
        active = true
        let playlist = Self.playlistData(segments: Array(acknowledged.suffix(3)), endList: true)
        upload(data: playlist, filename: "rinklens.m3u8", contentType: "application/vnd.apple.mpegurl", attempt: 0) { [weak self] result in
            guard let self else { return }
            active = false
            switch result {
            case .success:
                finishRequested = false
                callbacks.onFinished()
                session.finishTasksAndInvalidate()
            case .failure(let error): fail(error)
            }
        }
    }

    private func upload(
        data: Data,
        filename: String,
        contentType: String,
        attempt: Int,
        completion: @escaping @Sendable (RinkLensHLSUploadResult) -> Void
    ) {
        guard let url = URL(string: baseURLText + filename) else {
            completion(.failure("Invalid YouTube HLS upload URL."))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("RinkLens/iPadOS/\(RinkLensBuildInfo.version)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            queue.async {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if error == nil, status == 200 || status == 202 {
                    completion(.success(status))
                    return
                }
                let retryable = error != nil || status == 0 || status >= 500
                if retryable, attempt < 4 {
                    let baseDelay = min(8.0, 0.5 * pow(2.0, Double(attempt)))
                    let jitter = Double.random(in: 0...(baseDelay * 0.25))
                    self.queue.asyncAfter(deadline: .now() + baseDelay + jitter) {
                        self.upload(data: data, filename: filename, contentType: contentType, attempt: attempt + 1, completion: completion)
                    }
                    return
                }
                if status == 401 {
                    completion(.failure("YouTube rejected the HLS stream key (HTTP 401)."))
                } else if status == 400 {
                    completion(.failure("YouTube rejected the HLS playlist or MPEG-2 TS segment (HTTP 400)."))
                } else {
                    completion(.failure("YouTube HLS upload failed (HTTP \(status)): \(error?.localizedDescription ?? "server rejected request")."))
                }
            }
        }.resume()
    }

    private func fail(_ message: String) {
        guard !failed else { return }
        failed = true
        active = false
        pending.removeAll()
        session.invalidateAndCancel()
        callbacks.onFailure(message)
    }

    private static func playlistData(segments: [RinkLensHLSSegment], endList: Bool) -> Data {
        let target = max(2, Int(ceil(segments.map(\.duration).max() ?? 2)))
        let firstSequence = segments.first?.sequence ?? 0
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:\(target)",
            "#EXT-X-MEDIA-SEQUENCE:\(firstSequence)"
        ]
        for segment in segments {
            lines.append(String(format: "#EXTINF:%.3f,", segment.duration))
            lines.append(segment.filename)
        }
        if endList { lines.append("#EXT-X-ENDLIST") }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}
#endif
