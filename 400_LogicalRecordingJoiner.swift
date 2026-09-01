import Foundation
@preconcurrency import AVFoundation

nonisolated enum RinkLensLogicalRecordingJoinError: LocalizedError {
    case missingSegment(URL)
    case missingVideoTrack(URL)
    case cannotCreateCompositionTrack
    case cannotCreateExporter
    case incompatibleSegments(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingSegment(let url):
            return "Recording segment is missing: \(url.lastPathComponent)"
        case .missingVideoTrack(let url):
            return "Recording segment contains no video: \(url.lastPathComponent)"
        case .cannotCreateCompositionTrack:
            return "Could not create the final recording timeline"
        case .cannotCreateExporter:
            return "Could not create the final recording exporter"
        case .incompatibleSegments(let detail):
            return "Recording segments are not passthrough-compatible: \(detail)"
        case .exportFailed(let detail):
            return "Final recording export failed: \(detail)"
        }
    }
}

/// Offline, ordered, passthrough join. It never participates in camera or
/// recording ownership and is admitted only through MediaRepository's
/// post-capture queue after the physical writer contract is closed.
nonisolated enum RinkLensLogicalRecordingJoiner {
    private struct SegmentTracks: @unchecked Sendable {
        let video: AVAssetTrack
        let audio: AVAssetTrack?
        let timeRange: CMTimeRange
        let audioTimeRange: CMTimeRange?
        let preferredTransform: CGAffineTransform
        let signature: MediaSignature
    }

    private struct MediaSignature: Equatable, Sendable {
        let videoSubType: FourCharCode
        let width: Int32
        let height: Int32
        let nominalFrameRate: Float
        let preferredTransform: CGAffineTransform
        let audioSubType: FourCharCode?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.videoSubType == rhs.videoSubType
                && lhs.width == rhs.width
                && lhs.height == rhs.height
                && abs(lhs.nominalFrameRate - rhs.nominalFrameRate) < 0.05
                && lhs.preferredTransform == rhs.preferredTransform
                && lhs.audioSubType == rhs.audioSubType
        }
    }

    private final class ResultBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Value, Error>?

        func store(_ value: Result<Value, Error>) {
            lock.lock()
            result = value
            lock.unlock()
        }

        func take() throws -> Value {
            lock.lock()
            defer { lock.unlock() }
            guard let result else {
                throw RinkLensLogicalRecordingJoinError.exportFailed("asynchronous operation returned no result")
            }
            return try result.get()
        }
    }

    private struct Unchecked<Value>: @unchecked Sendable { let value: Value }

    static func join(segments: [URL], outputURL: URL) throws {
        guard !segments.isEmpty else {
            throw RinkLensLogicalRecordingJoinError.exportFailed("no recording segments")
        }
        let fileManager = FileManager.default
        for url in segments where !fileManager.fileExists(atPath: url.path) {
            throw RinkLensLogicalRecordingJoinError.missingSegment(url)
        }
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }

        let composition = AVMutableComposition()
        guard let videoCompositionTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw RinkLensLogicalRecordingJoinError.cannotCreateCompositionTrack
        }
        var audioCompositionTrack: AVMutableCompositionTrack?
        var cursor = CMTime.zero
        var acceptedSignature: MediaSignature?

        for (index, url) in segments.enumerated() {
            let tracks = try loadTracks(from: url)
            if let acceptedSignature, acceptedSignature != tracks.signature {
                throw RinkLensLogicalRecordingJoinError.incompatibleSegments(url.lastPathComponent)
            }
            acceptedSignature = tracks.signature
            if index == 0 { videoCompositionTrack.preferredTransform = tracks.preferredTransform }
            try videoCompositionTrack.insertTimeRange(tracks.timeRange, of: tracks.video, at: cursor)
            if let audio = tracks.audio, let audioTimeRange = tracks.audioTimeRange {
                if audioCompositionTrack == nil {
                    audioCompositionTrack = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    )
                }
                let intersection = CMTimeRangeGetIntersection(
                    tracks.timeRange,
                    otherRange: audioTimeRange
                )
                if intersection.isValid, intersection.duration.isNumeric, intersection.duration > .zero {
                    let offset = CMTimeSubtract(intersection.start, tracks.timeRange.start)
                    try audioCompositionTrack?.insertTimeRange(
                        intersection,
                        of: audio,
                        at: CMTimeAdd(cursor, offset)
                    )
                }
            }
            cursor = cursor + tracks.timeRange.duration
        }

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw RinkLensLogicalRecordingJoinError.cannotCreateExporter
        }
        exporter.shouldOptimizeForNetworkUse = true
        if #available(iOS 18.0, *) {
            let box = Unchecked(value: exporter)
            try blockingAsync {
                try await box.value.export(to: outputURL, as: .mp4)
            }
        } else if #unavailable(iOS 18.0) {
            try legacyExport(exporter, outputURL: outputURL)
        }
    }

    private static func loadTracks(from url: URL) throws -> SegmentTracks {
        let asset = AVURLAsset(url: url)
        let box = Unchecked(value: asset)
        return try blockingAsync {
            let videoTracks = try await box.value.loadTracks(withMediaType: .video)
            guard let video = videoTracks.first else {
                throw RinkLensLogicalRecordingJoinError.missingVideoTrack(url)
            }
            let audio = try await box.value.loadTracks(withMediaType: .audio).first
            let timeRange = try await video.load(.timeRange)
            let preferredTransform = try await video.load(.preferredTransform)
            let nominalFrameRate = try await video.load(.nominalFrameRate)
            let videoDescriptions = try await video.load(.formatDescriptions)
            guard let videoDescription = videoDescriptions.first else {
                throw RinkLensLogicalRecordingJoinError.missingVideoTrack(url)
            }
            let dimensions = CMVideoFormatDescriptionGetDimensions(videoDescription)
            let audioTimeRange = try await audio?.load(.timeRange)
            let audioDescriptions = try await audio?.load(.formatDescriptions)
            return SegmentTracks(
                video: video,
                audio: audio,
                timeRange: timeRange,
                audioTimeRange: audioTimeRange,
                preferredTransform: preferredTransform,
                signature: MediaSignature(
                    videoSubType: CMFormatDescriptionGetMediaSubType(videoDescription),
                    width: dimensions.width,
                    height: dimensions.height,
                    nominalFrameRate: nominalFrameRate,
                    preferredTransform: preferredTransform,
                    audioSubType: audioDescriptions?.first.map(CMFormatDescriptionGetMediaSubType)
                )
            )
        }
    }

    private static func blockingAsync<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) throws -> Value {
        let semaphore = DispatchSemaphore(value: 0)
        let result = ResultBox<Value>()
        Task.detached(priority: .utility) {
            do { result.store(.success(try await operation())) }
            catch { result.store(.failure(error)) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.take()
    }

    @available(iOS, introduced: 4.0, deprecated: 18.0)
    private static func legacyExport(_ exporter: AVAssetExportSession, outputURL: URL) throws {
        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        let semaphore = DispatchSemaphore(value: 0)
        exporter.exportAsynchronously { semaphore.signal() }
        semaphore.wait()
        guard exporter.status == .completed else {
            throw exporter.error ?? RinkLensLogicalRecordingJoinError.exportFailed("unknown exporter error")
        }
    }
}
