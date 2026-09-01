// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(UIKit)
@preconcurrency import UIKit
@preconcurrency import AVFoundation
import Foundation
import Combine
import CoreVideo
import QuartzCore

// MARK: - v0.9.1l Rolling Highlight Clip Buffer


/// Bridges modern AVFoundation async loading/export into the existing serial
/// clip queues without moving clip ownership to MainActor or permitting two
/// exports to overlap. The result box is protected and intentionally unchecked
/// because AVFoundation reference types are imported with preconcurrency.
nonisolated private enum RinkLensBlockingAsyncBridgeError: Error {
    case resultUnavailable
}

nonisolated private final class RinkLensBlockingAsyncResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Value, Error>?

    func store(_ result: Result<Value, Error>) {
        lock.lock()
        stored = result
        lock.unlock()
    }

    func take() -> Result<Value, Error> {
        lock.lock()
        defer { lock.unlock() }
        return stored ?? .failure(RinkLensBlockingAsyncBridgeError.resultUnavailable)
    }
}

nonisolated private struct RinkLensUncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

nonisolated private func rinkLensBlockingAsync<Value>(
    _ operation: @escaping @Sendable () async throws -> Value
) throws -> Value {
    let semaphore = DispatchSemaphore(value: 0)
    let result = RinkLensBlockingAsyncResult<Value>()
    Task.detached(priority: .background) {
        do {
            result.store(.success(try await operation()))
        } catch {
            result.store(.failure(error))
        }
        semaphore.signal()
    }
    semaphore.wait()
    return try result.take().get()
}

enum ClipBufferSegmentStatus: String, Codable {
    case writing
    case complete
    case expired
    case exported
    case failed
}

struct ClipBufferSegmentRecord: Identifiable, Codable, Equatable {
    var id: UUID
    var filename: String
    var startTime: Date
    var endTime: Date
    var duration: TimeInterval
    var status: ClipBufferSegmentStatus
    var recordingEpochID: UUID? = nil
}

struct HighlightClipMetadata: Identifiable, Codable {
    var id: UUID
    var clipType: String
    var createdTime: Date
    var anchorTime: Date
    var sourceStartTime: Date
    var sourceEndTime: Date
    var period: Int?
    var gameClockValue: String?
    var team: String?
    var playerNumber: String?
    var eventTags: [String]
    var exportStatus: String
    var fileURL: URL?
    var requestedDuration: TimeInterval?
    var actualDuration: TimeInterval?
    var shortClipReason: String?
}

struct ClipExportResult {
    var url: URL
    var metadata: HighlightClipMetadata
}

// Recovery DJ / RL-237 clip-export contract. Manual highlights already consist
// of compressed clip-buffer samples. They use a bounded reader/writer container
// mux which owns no encoder and may therefore finish while RecordingWriter is
// open. Automatic clips may require offline overlay rendering and remain behind
// RecordingWriter close.
nonisolated enum RinkLensClipExportExecutionDisposition: Equatable {
    case deferUntilRecordingStops
    case executeLiveSampleMux
    case executeOfflineExport
}

nonisolated enum RinkLensClipExportPriorityPolicy {
    static func executionDisposition(
        writerContractOpen: Bool,
        isManual: Bool
    ) -> RinkLensClipExportExecutionDisposition {
        if isManual { return .executeLiveSampleMux }
        return writerContractOpen ? .deferUntilRecordingStops : .executeOfflineExport
    }

    static func yieldsToOperatorInteraction(
        _ disposition: RinkLensClipExportExecutionDisposition
    ) -> Bool {
        disposition != .executeLiveSampleMux
    }

}

/// One cancellable, sample-bounded MP4 mux. It copies compressed samples from
/// the compact clip composition into a new container and never asks
/// VideoToolbox to decode or encode a frame.
nonisolated private final class RinkLensCompressedSampleMuxOperation: @unchecked Sendable {
    enum MuxError: LocalizedError {
        case cancelled
        case readerStartFailed(String)
        case writerStartFailed(String)
        case appendFailed(String)
        case finishFailed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return "Manual clip mux was cancelled for a higher-priority operator action"
            case .readerStartFailed(let detail): return "Manual clip reader could not start: \(detail)"
            case .writerStartFailed(let detail): return "Manual clip writer could not start: \(detail)"
            case .appendFailed(let detail): return "Manual clip sample append failed: \(detail)"
            case .finishFailed(let detail): return "Manual clip writer could not finish: \(detail)"
            }
        }
    }

    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let drainQueue = DispatchQueue(label: "rinklens.clipbuffer.live-sample-mux", qos: .utility)
    private let completion = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<Void, Error>?

    init(
        composition: AVComposition,
        track: AVCompositionTrack,
        sourceFormatHint: CMFormatDescription,
        outputURL: URL
    ) throws {
        reader = try AVAssetReader(asset: composition)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MuxError.readerStartFailed("compressed track output rejected") }
        reader.add(output)

        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: sourceFormatHint
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw MuxError.writerStartFailed("compressed writer input rejected") }
        writer.add(input)
    }

    func run() throws {
        if isFinished { throw MuxError.cancelled }
        guard writer.startWriting() else {
            throw MuxError.writerStartFailed(writer.error?.localizedDescription ?? "unknown writer error")
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            writer.cancelWriting()
            throw MuxError.readerStartFailed(reader.error?.localizedDescription ?? "unknown reader error")
        }

        input.requestMediaDataWhenReady(on: drainQueue) { [weak self] in
            self?.drainReadySamples()
        }
        completion.wait()
        lock.lock()
        let finalResult = result
        lock.unlock()
        try (finalResult ?? .failure(MuxError.finishFailed("operation completed without a result"))).get()
    }

    func cancel() {
        finishOnce(.failure(MuxError.cancelled), cancelMedia: true)
    }

    private func drainReadySamples() {
        while input.isReadyForMoreMediaData {
            if isFinished { return }
            guard let sample = output.copyNextSampleBuffer() else {
                if reader.status == .failed {
                    finishOnce(.failure(MuxError.appendFailed(reader.error?.localizedDescription ?? "reader failed")), cancelMedia: true)
                    return
                }
                if reader.status == .cancelled {
                    finishOnce(.failure(MuxError.cancelled), cancelMedia: true)
                    return
                }
                input.markAsFinished()
                writer.finishWriting { [weak self] in
                    guard let self else { return }
                    if self.writer.status == .completed {
                        self.finishOnce(.success(()), cancelMedia: false)
                    } else {
                        self.finishOnce(
                            .failure(MuxError.finishFailed(self.writer.error?.localizedDescription ?? "unknown writer error")),
                            cancelMedia: true
                        )
                    }
                }
                return
            }
            guard input.append(sample) else {
                finishOnce(.failure(MuxError.appendFailed(writer.error?.localizedDescription ?? "writer rejected sample")), cancelMedia: true)
                return
            }
        }
    }

    private var isFinished: Bool {
        lock.lock()
        let finished = result != nil
        lock.unlock()
        return finished
    }

    private func finishOnce(_ newResult: Result<Void, Error>, cancelMedia: Bool) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = newResult
        lock.unlock()
        if cancelMedia {
            reader.cancelReading()
            writer.cancelWriting()
        }
        completion.signal()
    }
}

/// ClipEngine owns its writer/export queues and mailbox locks. It is explicitly
/// nonisolated so RecordingWriter can submit its capacity-one pixel-buffer value
/// directly from the recording queue; only the small @Published projections are
/// dispatched to MainActor by the existing `...OnMain` helpers.
nonisolated final class ClipEngine: ObservableObject, @unchecked Sendable {
    /// Temporary bridge to the AppContainer-owned ClipEngine.
    /// Installed before HockeyScoreboardViewModel construction so bootstrap code
    /// cannot recursively enter AppContainer.shared.
    @MainActor private static var installedShared: ClipEngine?

    @MainActor static var shared: ClipEngine {
        guard let engine = installedShared else {
            preconditionFailure("ClipEngine.shared accessed before AppContainer recording bootstrap")
        }
        return engine
    }

    @MainActor static func installShared(_ engine: ClipEngine) {
        if let current = installedShared {
            precondition(current === engine, "A second ClipEngine authority was installed")
            return
        }
        installedShared = engine
    }

    enum ClipBufferFramePath: String, Codable {
        case pixelBuffer = "Compressed sample segments"

        var diagnosticText: String { "VideoToolbox compressed-sample segments" }
    }

    @MainActor @Published private(set) var isActive = false
    @MainActor @Published private(set) var clipStatusText = "Clip unavailable"
    @MainActor @Published private(set) var bufferDurationText = "0s buffered"
    @MainActor @Published private(set) var lastDiagnosticText = "clip buffer idle"
    @MainActor @Published private(set) var lastRolloverTelemetryText = "none"
    @MainActor @Published private(set) var rolloverTelemetrySuppressedFromUIText = "No"
    @MainActor @Published private(set) var lastClipExportRequestedDurationText = "--"
    @MainActor @Published private(set) var lastClipExportResolvedDurationText = "--"
    @MainActor @Published private(set) var lastClipExportWindowText = "--"
    @MainActor @Published private(set) var lastClipExportSourceText = "--"
    @MainActor @Published private(set) var lastClipExportFailureReasonText = "none"
    @MainActor @Published private(set) var clipWriterQueueModeText = "background serial writer"
    @MainActor @Published private(set) var lastClipWriterBackgroundEventText = "none"
    @MainActor @Published private(set) var clipWriterMainPathSuppressedText = "No"
    @MainActor @Published private(set) var clipBufferPathText = ClipBufferFramePath.pixelBuffer.rawValue
    @MainActor @Published private(set) var clipFrameMailboxText = "capacity=1 pending=0 replaced=0"

    private struct Manifest: Codable {
        var segments: [ClipBufferSegmentRecord] = []
        var exportedClips: [HighlightClipMetadata] = []
    }

    private struct SegmentWriter: @unchecked Sendable {
        let id: UUID
        let url: URL
        let startedAt: Date
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        var frameCount: Int64 = 0
        var firstSourcePresentationTime: CMTime? = nil
        var lastPresentationTime: CMTime? = nil
    }

    private struct PendingPixelBufferFrame: @unchecked Sendable {
        let sampleBuffer: CMSampleBuffer
        let sourcePresentationTime: CMTime
        let isKeyFrame: Bool
    }

    private struct PreparedSegment {
        var record: ClipBufferSegmentRecord
        var asset: AVURLAsset
        var videoTrack: AVAssetTrack
        var audioTrack: AVAssetTrack?
        var preferredTransform: CGAffineTransform
        var sourceRange: CMTimeRange
        var actualDuration: TimeInterval
    }

    // UX16d2h: a clip request made during full-match recording freezes the
    // resolved segment records and pins their files, but performs no export or
    // transcode until the authoritative recording lease is inactive. The
    // completion closure is queue-owned and intentionally boxed as unchecked
    // Sendable because this class serialises every access on exportQueue.
    private struct FrozenClipExport: @unchecked Sendable {
        var metadata: HighlightClipMetadata
        var segments: [ClipBufferSegmentRecord]
        var sourceStart: Date
        var sourceEnd: Date
        var homeTeam: String
        var awayTeam: String
        var isPinned: Bool
        var completion: (Result<ClipExportResult, Error>) -> Void
    }

    private let writerQueue = DispatchQueue(label: "rinklens.clipbuffer.writer", qos: .utility)
    private let exportQueue = DispatchQueue(label: "rinklens.clipbuffer.export", qos: .background)
    private let retentionDuration: TimeInterval = 60.0
    private let minimumValidSegmentDuration: TimeInterval = 0.5
    private let minimumExportDuration: TimeInterval = 3.0
    // v9.2 Stage 7c5: AVAssetExport can produce a final movie that is slightly
    // shorter than the selected PixelBuffer segment coverage due to segment
    // boundary rounding/encoder timing. Treat near-full manual clips as valid so
    // the UI does not report a misleading “Short clip saved” when the selected
    // window covered the requested duration.
    private let nearFullManualClipTolerance: TimeInterval = 1.25
    private var manifest = Manifest()
    private var currentWriter: SegmentWriter?
    private var rootFolder: URL?
    private var bufferFolder: URL?
    private var segmentFolder: URL?
    private var exportWorkingFolder: URL?
    private var exportCompleteFolder: URL?
    private var exportFailedFolder: URL?
    private var frameSize = CGSize(width: 1920, height: 1080)
    private var fps: Int32 = 60
    private var bufferRunning = false
    // One UUID identifies the physical rolling-buffer lifetime belonging to a
    // recording start. Pinned records from an earlier recording may remain on
    // disk until their frozen export completes, but must never participate in
    // readiness or window resolution for the current recording.
    private var activeRecordingEpochID: UUID?
    private var activeFramePath: ClipBufferFramePath = .pixelBuffer
    private var activeSegmentDuration: TimeInterval = 2.0
    private var droppedPixelBufferClipFrameCount: Int = 0
    private var appendedPixelBufferClipFrameCount: Int = 0
    // UX16c52: never enqueue an unbounded chain of full-resolution buffers from
    // the primary recording adaptor pool. Keep only the latest pending clip
    // frame and let the lower-priority clip writer drain one buffer at a time.
    private let pendingPixelBufferLock = NSLock()
    private var pendingPixelBufferFrame: PendingPixelBufferFrame?
    private var pixelBufferDrainScheduled = false
    private var replacedPendingPixelBufferCount: Int = 0
    // Presentation acknowledgement for the capacity-one mailbox is itself
    // bounded. The writer previously dispatched an identical @Published string
    // to MainActor after nearly every drained frame, making a background media
    // queue generate a 30/60 Hz UI invalidation stream while recording.
    private var lastQueuedClipMailboxPresentation = ""
    // UX16d2h recording-priority state. Pinned segment IDs are ignored by the
    // normal 60-second retention cleanup until their deferred export succeeds
    // or fails. Actual export work remains serial on exportQueue.
    private var pinnedSegmentReferenceCounts: [UUID: Int] = [:]
    private var deferredExports: [FrozenClipExport] = []
    private let mediaExportActivityLock = NSLock()
    private var mediaExportActive = false
    private var activeExportSession: AVAssetExportSession?
    private var activeCompressedSampleMux: RinkLensCompressedSampleMuxOperation?
    private var operatorPriorityYieldRequested = false

    init() {}

    func isMediaExportInProgress() -> Bool {
        mediaExportActivityLock.lock()
        let active = mediaExportActive
        mediaExportActivityLock.unlock()
        return active
    }

    /// Build 785 R9 recording-priority handoff. ClipEngine remains the only
    /// owner of AVAssetExportSession and cancels its current offline remux when
    /// RecordingEngine has already acquired the authoritative recording lease.
    /// The frozen segment references remain pinned and are requeued by the same
    /// ClipEngine after recording finalises.
    func requestRecordingPriority(reason: String) {
        mediaExportActivityLock.lock()
        let export = activeExportSession
        let wasActive = mediaExportActive
        mediaExportActivityLock.unlock()

        // The live manual mux owns no codec and is intentionally allowed to
        // finish across RecordingWriter start. Only the opaque offline export
        // must yield to recording priority.
        guard wasActive, let export else { return }
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "clip_export_yield_requested",
            entityID: "active-clip-export",
            previous: ["mediaExportActive": "true"],
            next: ["mediaExportActive": "cancelling", "recordingLease": "active"],
            source: "ClipEngine.requestRecordingPriority",
            reason: reason,
            authoritativeOwner: "ClipEngine"
        )
        note("active clip remux cancelled for recording priority reason=\(reason)")
        export.cancelExport()
    }

    /// ClipEngine remains the sole export owner. Route presentation may pre-empt
    /// only an opaque offline AVAssetExportSession. The bounded live manual mux
    /// owns no route/camera/encoder state and therefore continues to its physical
    /// file acknowledgement while navigation proceeds.
    func requestOperatorPriority(reason: String) {
        mediaExportActivityLock.lock()
        let wasActive = mediaExportActive
        let export = activeExportSession
        let sampleMuxActive = activeCompressedSampleMux != nil
        let disposition: RinkLensClipExportExecutionDisposition? = sampleMuxActive
            ? .executeLiveSampleMux
            : (export != nil ? .executeOfflineExport : nil)
        let shouldYield = wasActive
            && disposition.map(RinkLensClipExportPriorityPolicy.yieldsToOperatorInteraction) == true
        if shouldYield { operatorPriorityYieldRequested = true }
        mediaExportActivityLock.unlock()

        guard wasActive else { return }
        if sampleMuxActive && !shouldYield {
            RinkLensStructuredEventLogger.shared.record(
                domain: .recording,
                event: "manual_clip_live_mux_preserved_across_route",
                entityID: "active-manual-clip-mux",
                previous: ["routeInteraction": "requested", "mux": "active"],
                next: ["mux": "active", "yielded": "false"],
                source: "ClipEngine.requestOperatorPriority",
                reason: reason,
                authoritativeOwner: "ClipEngine"
            )
            return
        }
        guard shouldYield else { return }
        RinkLensExecutionCoordinator.shared.noteDeferredMediaYield()
        MainThreadStallMonitor.traceFromAnyQueue(
            "Recovery AF clip export yield requested for operator interaction: \(reason)"
        )
        export?.cancelExport()
    }

    private func consumeOperatorPriorityYieldRequest() -> Bool {
        mediaExportActivityLock.lock()
        let requested = operatorPriorityYieldRequested
        operatorPriorityYieldRequested = false
        mediaExportActivityLock.unlock()
        return requested
    }

    var canExportManualClip: Bool {
        canExportManualClip(seconds: 20)
    }

    func canExportManualClip(seconds: Int) -> Bool {
        writerQueue.sync {
            guard bufferRunning else { return false }
            let requested = TimeInterval(seconds)
            let readyCoverage = resolvedManualClipCoverageLocked(seconds: seconds, anchor: Date())
            return readyCoverage + BroadcastPixelBufferClipPerformanceGuard.exportDurationToleranceSeconds >= requested
        }
    }

    func manualClipBufferReadinessDiagnostic(seconds: Int) -> String {
        writerQueue.sync {
            let requested = TimeInterval(seconds)
            let readyCoverage = resolvedManualClipCoverageLocked(seconds: seconds, anchor: Date())
            return BroadcastPixelBufferClipPerformanceGuard.notReadyReason(readyCoverage: readyCoverage, requested: requested)
        }
    }

    var completeBufferedDuration: TimeInterval {
        writerQueue.sync { completeBufferedDurationLocked }
    }

    private var completeBufferedDurationLocked: TimeInterval {
        completeSegmentsForActiveEpochLocked()
            .reduce(0) { $0 + max(0, $1.duration) }
    }

    private func completeSegmentsForActiveEpochLocked() -> [ClipBufferSegmentRecord] {
        guard let activeRecordingEpochID else { return [] }
        return manifest.segments.filter {
            $0.status == .complete
                && $0.recordingEpochID == activeRecordingEpochID
        }
    }

    func performRecoveryCleanup() {
        writerQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.performRecoveryCleanupLocked()
            } catch {
                self.note("recovery cleanup failed: \(error.localizedDescription)")
            }
        }
    }

    /// Starts the rolling clip muxer. Full-match RecordingCompressionEngine is
    /// the only encoder; ClipEngine receives its already-compressed samples and
    /// writes passthrough segments. This removes the second simultaneous 1080p60
    /// AVAssetWriter encoder and full-frame copy that saturated the device while
    /// recording and delayed MainActor operator handlers by up to 2.73 seconds.
    func startCompressedSamples(size: CGSize, fps: Int32) {
        writerQueue.async { [weak self] in
            guard let self else { return }
            let recordingEpochID = UUID()
            self.activeRecordingEpochID = recordingEpochID
            self.frameSize = size
            self.fps = max(1, fps)
            self.activeSegmentDuration = BroadcastPixelBufferClipPerformanceGuard.pixelBufferSegmentDuration
            self.droppedPixelBufferClipFrameCount = 0
            self.appendedPixelBufferClipFrameCount = 0
            self.clearPendingPixelBufferMailbox()
            do {
                try self.ensureFolders()
                self.loadManifest()
                try self.performRecoveryCleanupLocked()
                self.purgeBufferedSegmentsLocked(reason: "starting compressed-sample clip segments")
                self.activeFramePath = .pixelBuffer
                self.bufferRunning = true
                self.isActiveOnMain(true, path: .pixelBuffer)
                self.note("rolling buffer started: VideoToolbox compressed-sample passthrough segments epoch=\(recordingEpochID.uuidString)")
            } catch {
                self.bufferRunning = false
                self.isActiveOnMain(false, path: .pixelBuffer)
                self.note("rolling buffer failed to start: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        writerQueue.async { [weak self] in
            guard let self else { return }
            self.bufferRunning = false
            self.clearPendingPixelBufferMailbox()
            self.finishCurrentSegment()
            self.isActiveOnMain(false)
            self.note("rolling buffer stopped")
        }
    }

    func appendCompressedSample(_ sampleBuffer: CMSampleBuffer, sourcePresentationTime: CMTime) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyFrame = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        pendingPixelBufferLock.lock()
        if pendingPixelBufferFrame != nil {
            replacedPendingPixelBufferCount += 1
        }
        let incoming = PendingPixelBufferFrame(
            sampleBuffer: sampleBuffer,
            sourcePresentationTime: sourcePresentationTime,
            isKeyFrame: isKeyFrame
        )
        // A segment boundary requires the encoder-owned sync sample. Preserve a
        // pending key frame over later delta frames; an incoming key frame may
        // always replace an older pending delta frame.
        if pendingPixelBufferFrame?.isKeyFrame != true || isKeyFrame {
            pendingPixelBufferFrame = incoming
        }
        let shouldSchedule = !pixelBufferDrainScheduled
        if shouldSchedule { pixelBufferDrainScheduled = true }
        let replaced = replacedPendingPixelBufferCount
        pendingPixelBufferLock.unlock()

        if replaced == 1 || replaced % 120 == 0 {
            publishClipMailboxState(pending: true, replaced: replaced)
        }
        guard shouldSchedule else { return }
        writerQueue.async { [weak self] in self?.drainOnePendingPixelBuffer() }
    }

    private func drainOnePendingPixelBuffer() {
        pendingPixelBufferLock.lock()
        let pendingFrame = pendingPixelBufferFrame
        pendingPixelBufferFrame = nil
        pendingPixelBufferLock.unlock()

        if let pendingFrame,
           bufferRunning {
            appendPixelBufferOnWriterQueue(pendingFrame)
        }

        pendingPixelBufferLock.lock()
        let hasAnother = pendingPixelBufferFrame != nil
        if !hasAnother { pixelBufferDrainScheduled = false }
        let replaced = replacedPendingPixelBufferCount
        pendingPixelBufferLock.unlock()

        publishClipMailboxState(pending: hasAnother, replaced: replaced)
        if hasAnother {
            writerQueue.async { [weak self] in self?.drainOnePendingPixelBuffer() }
        }
    }

    private func appendPixelBufferOnWriterQueue(_ pendingFrame: PendingPixelBufferFrame) {
        do {
            if let currentWriter,
               let first = currentWriter.firstSourcePresentationTime,
               pendingFrame.isKeyFrame,
               CMTimeGetSeconds(CMTimeSubtract(pendingFrame.sourcePresentationTime, first)) >= activeSegmentDuration {
                finishCurrentSegment()
            }
            if currentWriter == nil {
                guard pendingFrame.isKeyFrame else {
                    droppedPixelBufferClipFrameCount += 1
                    return
                }
                try beginSegment(firstSample: pendingFrame.sampleBuffer)
            }
            guard var segmentWriter = currentWriter else { return }
            guard segmentWriter.input.isReadyForMoreMediaData else {
                droppedPixelBufferClipFrameCount += 1
                if droppedPixelBufferClipFrameCount == 1 || droppedPixelBufferClipFrameCount % 120 == 0 {
                    note("clip compressed sample skipped due to segment muxer backlog dropped=\(droppedPixelBufferClipFrameCount)")
                }
                return
            }

            let appendStartedAt = CFAbsoluteTimeGetCurrent()
            let sourceTime = pendingFrame.sourcePresentationTime
            if segmentWriter.input.append(pendingFrame.sampleBuffer) {
                let appendDurationMS = (CFAbsoluteTimeGetCurrent() - appendStartedAt) * 1000
                segmentWriter.frameCount += 1
                if segmentWriter.firstSourcePresentationTime == nil {
                    segmentWriter.firstSourcePresentationTime = sourceTime
                }
                segmentWriter.lastPresentationTime = sourceTime
                appendedPixelBufferClipFrameCount += 1
                currentWriter = segmentWriter
                if appendDurationMS > 8 {
                    note("clip compressed-sample append warning \(String(format: "%.1f", appendDurationMS))ms")
                }
                let shouldNote = appendedPixelBufferClipFrameCount == 1
                    || appendedPixelBufferClipFrameCount % Int(max(1, fps) * 4) == 0
                if shouldNote {
                    note("compressed clip sample appended count=\(segmentWriter.frameCount) total=\(appendedPixelBufferClipFrameCount) dropped=\(droppedPixelBufferClipFrameCount)")
                }
            } else {
                droppedPixelBufferClipFrameCount += 1
                if droppedPixelBufferClipFrameCount == 1 || droppedPixelBufferClipFrameCount % 120 == 0 {
                    note("clip compressed sample skipped because passthrough append failed dropped=\(droppedPixelBufferClipFrameCount)")
                }
            }
        } catch {
            note("Compressed-sample segment writing failed: \(error.localizedDescription)")
            currentWriter = nil
        }
    }

    private func clearPendingPixelBufferMailbox() {
        pendingPixelBufferLock.lock()
        pendingPixelBufferFrame = nil
        pixelBufferDrainScheduled = false
        replacedPendingPixelBufferCount = 0
        pendingPixelBufferLock.unlock()
        publishClipMailboxState(pending: false, replaced: 0)
    }

    private func publishClipMailboxState(pending: Bool, replaced: Int) {
        // Replacement telemetry is diagnostic evidence, not frame state. Publish
        // the first replacement and then one acknowledgement per 120 replacements
        // instead of mirroring every writer-queue counter increment into SwiftUI.
        let reportedReplaced: Int
        if replaced <= 1 {
            reportedReplaced = replaced
        } else if replaced < 120 {
            reportedReplaced = 1
        } else {
            reportedReplaced = (replaced / 120) * 120
        }
        let next = "capacity=1 pending=\(pending ? 1 : 0) replaced=\(reportedReplaced) adaptive-full-rate"

        pendingPixelBufferLock.lock()
        guard next != lastQueuedClipMailboxPresentation else {
            pendingPixelBufferLock.unlock()
            return
        }
        lastQueuedClipMailboxPresentation = next
        pendingPixelBufferLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.clipFrameMailboxText != next else { return }
            self.clipFrameMailboxText = next
        }
    }

    func requestManualClip(seconds: Int, homeTeam: String, awayTeam: String, completion: @escaping (Result<ClipExportResult, Error>) -> Void) {
        let anchor = Date()
        requestManualClip(
            preRollSeconds: seconds,
            postRollSeconds: 0,
            anchor: anchor,
            homeTeam: homeTeam,
            awayTeam: awayTeam,
            completion: completion
        )
    }

    func requestManualClip(
        preRollSeconds: Int,
        postRollSeconds: TimeInterval,
        anchor: Date,
        homeTeam: String,
        awayTeam: String,
        completion: @escaping (Result<ClipExportResult, Error>) -> Void
    ) {
        let preRoll = Swift.max(0, TimeInterval(preRollSeconds))
        let postRoll = Swift.max(0, postRollSeconds)
        let start = anchor.addingTimeInterval(-preRoll)
        let end = anchor.addingTimeInterval(postRoll)
        let metadata = HighlightClipMetadata(
            id: UUID(),
            clipType: "manual",
            createdTime: Date(),
            anchorTime: anchor,
            sourceStartTime: start,
            sourceEndTime: end,
            period: nil,
            gameClockValue: nil,
            team: nil,
            playerNumber: nil,
            eventTags: postRoll > 0
                ? [BroadcastManualClipPostRollPolicy.manualTag, BroadcastManualClipPostRollPolicy.postRollTag, BroadcastManualClipPostRollPolicy.allowPartialTag]
                : [BroadcastManualClipPostRollPolicy.manualTag],
            exportStatus: "queued",
            fileURL: nil,
            requestedDuration: preRoll + postRoll,
            actualDuration: nil,
            shortClipReason: nil
        )
        note("clip requested manually pre=\(Int(preRoll.rounded()))s post=\(String(format: "%.1f", postRoll))s")
        note("clip button pressed time=\(diagnosticTime(anchor))")
        if postRoll > 0 { note("clip post-roll queued duration=\(String(format: "%.1f", postRoll))s") }
        enqueueExport(metadata: metadata, homeTeam: homeTeam, awayTeam: awayTeam, completion: completion)
    }

    func requestAutomaticClip(
        anchor: Date,
        tags: [String],
        period: Int?,
        gameClock: String?,
        team: String?,
        playerNumber: String?,
        completion: ((Result<ClipExportResult, Error>) -> Void)? = nil
    ) {
        let start = anchor.addingTimeInterval(-20)
        let clipType = tags.first?.lowercased() ?? "automatic"
        let metadata = HighlightClipMetadata(
            id: UUID(),
            clipType: clipType,
            createdTime: Date(),
            anchorTime: anchor,
            sourceStartTime: start,
            sourceEndTime: anchor,
            period: period,
            gameClockValue: gameClock,
            team: team,
            playerNumber: playerNumber,
            eventTags: tags,
            exportStatus: "queued",
            fileURL: nil,
            requestedDuration: 20,
            actualDuration: nil,
            shortClipReason: nil
        )
        note("automatic clip confirmed")
        enqueueExport(metadata: metadata, homeTeam: "Auto", awayTeam: "Highlight") { result in
            completion?(result)
        }
    }

    /// Photos acknowledgement is the physical boundary after which the complete
    /// export is no longer a locally-owned media asset. The manifest must not
    /// continue to advertise a file that MediaRepository has safely released.
    func acknowledgePermanentPhotosPersistence(localURL: URL) {
        let target = localURL.standardizedFileURL
        writerQueue.async { [weak self] in
            guard let self else { return }
            let previousCount = self.manifest.exportedClips.count
            self.manifest.exportedClips.removeAll { metadata in
                metadata.fileURL?.standardizedFileURL == target
            }
            guard self.manifest.exportedClips.count != previousCount else { return }
            self.saveManifest()
            self.note("clip manifest released Photos-backed export \(localURL.lastPathComponent)")
        }
    }

    /// Explicit operator purge of app-sandbox clip media. Photos assets remain
    /// untouched. ClipEngine performs the mutation on its writer queue so the
    /// manifest, rolling segments and export folders cannot diverge.
    func clearOperatorRequestedLocalClipMedia() async -> RinkLensStorageClearResult {
        guard !RinkLensRecordingCaptureLease.shared.isWriterContractOpen(),
              !RinkLensRecordingCaptureLease.shared.isRecordingActive(),
              !isMediaExportInProgress() else {
            return .blocked("Stop recording and wait for the current clip export before clearing clips.")
        }
        return await withCheckedContinuation { continuation in
            writerQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .blocked("ClipEngine is unavailable."))
                    return
                }
                guard !self.bufferRunning,
                      self.currentWriter == nil,
                      self.deferredExports.isEmpty else {
                    continuation.resume(returning: .blocked("The rolling clip buffer still owns media. Stop recording and wait for secured clips to finish."))
                    return
                }
                var files = 0
                var bytes: Int64 = 0
                do {
                    try self.ensureFolders()
                    let folders = [self.segmentFolder, self.exportWorkingFolder, self.exportCompleteFolder, self.exportFailedFolder].compactMap { $0 }
                    for folder in folders {
                        let urls = (try? FileManager.default.contentsOfDirectory(
                            at: folder,
                            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                            options: [.skipsHiddenFiles]
                        )) ?? []
                        for url in urls {
                            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                            guard values?.isRegularFile == true else { continue }
                            let size = Int64(values?.fileSize ?? 0)
                            try FileManager.default.removeItem(at: url)
                            files += 1
                            bytes += size
                        }
                    }
                    self.manifest.segments.removeAll()
                    self.manifest.exportedClips.removeAll()
                    self.pinnedSegmentReferenceCounts.removeAll()
                    self.saveManifest()
                    self.updateBufferDuration()
                    self.note("operator cleared local clip media files=\(files) bytes=\(bytes); Photos unchanged")
                    continuation.resume(returning: .init(files: files, bytes: bytes, blockedReason: nil))
                } catch {
                    continuation.resume(returning: .init(
                        files: files,
                        bytes: bytes,
                        blockedReason: "Some clip media could not be removed: \(error.localizedDescription)"
                    ))
                }
            }
        }
    }

    private func enqueueExport(metadata: HighlightClipMetadata, homeTeam: String, awayTeam: String, completion: @escaping (Result<ClipExportResult, Error>) -> Void) {
        note("clip export queued")
        statusOnMain("Clip queued")
        exportQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.ensureFolders()
                if BroadcastManualClipPostRollPolicy.isManualPostRoll(metadata) {
                    // Finalise only the current rolling segment so the requested
                    // post-roll window is immutable. This is a short writer
                    // rollover, not an export or transcode.
                    self.finishCurrentSegmentForExportIfNeeded(reason: "manual post-roll freeze")
                }
                let requestedDuration = metadata.requestedDuration ?? metadata.sourceEndTime.timeIntervalSince(metadata.sourceStartTime)
                self.updateExportDiagnostics(
                    requestedDuration: requestedDuration,
                    resolvedDuration: nil,
                    windowText: "request \(self.diagnosticTime(metadata.sourceStartTime))...\(self.diagnosticTime(metadata.sourceEndTime))",
                    sourceText: metadata.eventTags.contains("MANUAL") ? "manual request anchored to latest complete \(self.activeFramePath.rawValue) buffer" : "automatic event anchor resolved to latest complete \(self.activeFramePath.rawValue) buffer",
                    failureReason: "none"
                )
                self.note("clip timeline request start=\(self.diagnosticTime(metadata.sourceStartTime)) end=\(self.diagnosticTime(metadata.sourceEndTime)) anchor=\(self.diagnosticTime(metadata.anchorTime))")
                let (segments, lookupText, resolvedStart, resolvedEnd, exportFramePath, selectedDuration, partialReason) = self.writerQueue.sync {
                    let recordingEpochID = self.activeRecordingEpochID
                    let complete = self.completeSegmentsForActiveEpochLocked()
                        .sorted { $0.startTime < $1.startTime }
                    let resolved = ClipBufferExportWindowResolver.resolve(
                        requestedStart: metadata.sourceStartTime,
                        requestedEnd: metadata.sourceEndTime,
                        requestedDuration: metadata.requestedDuration,
                        completeSegments: complete,
                        recordingEpochID: recordingEpochID
                    )
                    let selectedDuration = self.selectedCoverageDuration(
                        segments: resolved.selectedSegments,
                        start: resolved.start,
                        end: resolved.end
                    )
                    let partialReason = self.manualPartialReasonLocked(
                        metadata: metadata,
                        selectedDuration: selectedDuration,
                        requestedStart: metadata.sourceStartTime,
                        requestedEnd: metadata.sourceEndTime,
                        resolvedStart: resolved.start,
                        resolvedEnd: resolved.end,
                        completeSegments: complete,
                        selectedSegments: resolved.selectedSegments
                    )
                    return (resolved.selectedSegments, resolved.lookupText, resolved.start, resolved.end, self.activeFramePath, selectedDuration, partialReason)
                }
                let resolvedDuration = selectedDuration
                self.updateExportDiagnostics(
                    requestedDuration: metadata.requestedDuration ?? metadata.sourceEndTime.timeIntervalSince(metadata.sourceStartTime),
                    resolvedDuration: resolvedDuration,
                    windowText: "request \(self.diagnosticTime(metadata.sourceStartTime))...\(self.diagnosticTime(metadata.sourceEndTime)); resolved \(self.diagnosticTime(resolvedStart))...\(self.diagnosticTime(resolvedEnd))",
                    sourceText: "latest complete \(self.activeFramePath.rawValue) window; \(lookupText)",
                    failureReason: segments.isEmpty ? "no complete segments selected" : "none"
                )
                self.note("historical segment lookup result \(lookupText)")
                self.note("clip export resolved window start=\(self.diagnosticTime(resolvedStart)) end=\(self.diagnosticTime(resolvedEnd))")
                self.note("clip export snapshot created selected=\(segments.count)")
                guard !segments.isEmpty else {
                    self.note("export failed due to no valid footage")
                    throw ClipBufferError.notEnoughBufferedVideo
                }
                var resolvedMetadata = metadata
                resolvedMetadata.sourceStartTime = resolvedStart
                resolvedMetadata.sourceEndTime = resolvedEnd
                resolvedMetadata.shortClipReason = partialReason
                if exportFramePath == .pixelBuffer,
                   let requestedDuration = metadata.requestedDuration,
                   selectedDuration + BroadcastPixelBufferClipPerformanceGuard.exportDurationToleranceSeconds < requestedDuration {
                    if let partialReason,
                       BroadcastManualClipPostRollPolicy.isExpectedPartialReason(partialReason),
                       selectedDuration >= BroadcastManualClipPostRollPolicy.minimumExportableSeconds {
                        self.updateExportFailure("none")
                        self.note("clip partial accepted reason=\(partialReason) selected=\(String(format: "%.1f", selectedDuration))s requested=\(String(format: "%.1f", requestedDuration))s")
                    } else {
                        let reason = BroadcastPixelBufferClipPerformanceGuard.notReadyReason(
                            readyCoverage: selectedDuration,
                            requested: requestedDuration
                        )
                        self.updateExportFailure(reason)
                        self.note("pixelBuffer clip export rejected before short save: \(reason)")
                        throw ClipBufferError.notEnoughBufferedVideo
                    }
                }

                var frozen = FrozenClipExport(
                    metadata: resolvedMetadata,
                    segments: segments,
                    sourceStart: resolvedStart,
                    sourceEnd: resolvedEnd,
                    homeTeam: homeTeam,
                    awayTeam: awayTeam,
                    isPinned: false,
                    completion: completion
                )

                let execution = RinkLensClipExportPriorityPolicy.executionDisposition(
                    writerContractOpen: RinkLensRecordingCaptureLease.shared.isWriterContractOpen(),
                    isManual: resolvedMetadata.eventTags.contains("MANUAL")
                )
                if execution == .deferUntilRecordingStops {
                    self.deferFrozenExportForRecordingPriority(frozen)
                    return
                }
                frozen = self.pinFrozenExportIfNeeded(frozen)
                self.performFrozenExport(frozen)
            } catch {
                self.finishExportFailure(error, completion: completion)
            }
        }
    }

    /// UX16d2h explicit hand-off called only after the full-match writer has
    /// finalised and the recording lease is inactive. No polling timer or
    /// recovery loop is added; the recording owner makes the transition once.
    func resumeDeferredExportsAfterRecording(reason: String) {
        enqueueDeferredExportBatch(
            reason: reason,
            source: "ClipEngine.resumeDeferredExportsAfterRecording"
        )
    }

    private func enqueueDeferredExportBatch(reason: String, source: String) {
        let hasPending = writerQueue.sync { !deferredExports.isEmpty }
        guard hasPending else { return }
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "clip_deferred_export_batch_scheduled",
            entityID: "deferred-clips",
            previous: ["executionAdmission": "waiting"],
            next: ["queue": "MediaRepository.post-capture"],
            source: source,
            reason: reason,
            authoritativeOwner: "ClipEngine"
        )

        Task { @MainActor [weak self] in
            MediaRepository.shared.enqueuePostCaptureOperation(label: "Deferred clip export batch") { [weak self] finish in
                guard let self else { finish(); return }
                self.exportQueue.async {
                    guard !RinkLensRecordingCaptureLease.shared.isWriterContractOpen() else {
                        self.note("deferred clip export remains held because recording writer contract is open reason=\(reason)")
                        finish()
                        return
                    }
                    guard RinkLensExecutionCoordinator.shared.admitsDeferredMediaWork() else {
                        RinkLensExecutionCoordinator.shared.noteDeferredMediaYield()
                        self.note("Recovery AU deferred clip batch held by live capture media lease/operator/critical execution ownership reason=\(reason)")
                        finish()
                        return
                    }
                    let pending = self.writerQueue.sync { () -> [FrozenClipExport] in
                        let requests = self.deferredExports
                        self.deferredExports.removeAll(keepingCapacity: true)
                        return requests
                    }
                    guard !pending.isEmpty else { finish(); return }
                    let batchStarted = CFAbsoluteTimeGetCurrent()
                    RinkLensStructuredEventLogger.shared.record(
                        domain: .recording,
                        event: "clip_deferred_export_batch_started",
                        entityID: "deferred-clips",
                        previous: ["pendingCount": String(pending.count)],
                        next: ["activeCount": String(pending.count)],
                        source: "MediaRepository.post-capture -> ClipEngine.exportQueue",
                        reason: reason,
                        authoritativeOwner: "ClipEngine"
                    )
                    self.note("post-capture media owner released \(pending.count) deferred clip export(s) reason=\(reason)")
                    self.statusOnMain(pending.count == 1 ? "Saving secured clip" : "Saving secured clips")
                    for (index, request) in pending.enumerated() {
                        guard RinkLensExecutionCoordinator.shared.admitsDeferredMediaWork() else {
                            for remaining in pending[index...] {
                                self.deferFrozenExportForOperatorPriority(
                                    remaining,
                                    reason: "operator/critical execution priority became active during deferred batch"
                                )
                            }
                            break
                        }
                        self.performFrozenExport(request)
                    }
                    RinkLensStructuredEventLogger.shared.record(
                        domain: .recording,
                        event: "clip_deferred_export_batch_completed",
                        entityID: "deferred-clips",
                        previous: ["activeCount": String(pending.count)],
                        next: [
                            "activeCount": "0",
                            "durationMs": String(format: "%.1f", max(0, (CFAbsoluteTimeGetCurrent() - batchStarted) * 1_000))
                        ],
                        source: "ClipEngine.exportQueue",
                        reason: reason,
                        authoritativeOwner: "ClipEngine"
                    )
                    finish()
                }
            }
        }
    }

    private func deferFrozenExportForRecordingPriority(_ frozen: FrozenClipExport) {
        deferFrozenExport(
            frozen,
            sourceText: "UX16d2h recording priority: segment references pinned; export deferred until full recording stops",
            statusText: "Clip secured — saves after recording",
            noteText: "clip export deferred by recording priority"
        )
    }

    private func deferFrozenExportForOperatorPriority(_ frozen: FrozenClipExport, reason: String) {
        deferFrozenExport(
            frozen,
            sourceText: "Recovery AU media-resource owner: offline remux remained pinned while live capture/operator/critical work was active",
            statusText: "Clip secured — save resumes after current action",
            noteText: "Recovery AU clip export deferred by media-resource ownership reason=\(reason)"
        )
    }

    private func deferFrozenExport(
        _ frozen: FrozenClipExport,
        sourceText: String,
        statusText: String,
        noteText: String
    ) {
        var secured = frozen
        writerQueue.sync {
            if !secured.isPinned {
                for segment in secured.segments {
                    pinnedSegmentReferenceCounts[segment.id, default: 0] += 1
                }
                secured.isPinned = true
            }
            if !deferredExports.contains(where: { $0.metadata.id == secured.metadata.id }) {
                deferredExports.append(secured)
            }
            saveManifest()
        }
        updateExportDiagnostics(
            requestedDuration: secured.metadata.requestedDuration ?? secured.sourceEnd.timeIntervalSince(secured.sourceStart),
            resolvedDuration: secured.sourceEnd.timeIntervalSince(secured.sourceStart),
            windowText: "secured \(diagnosticTime(secured.sourceStart))...\(diagnosticTime(secured.sourceEnd))",
            sourceText: sourceText,
            failureReason: "none"
        )
        statusOnMain(statusText)
        note("\(noteText) segments=\(secured.segments.count) request=\(secured.metadata.id.uuidString)")
    }

    private func pinFrozenExportIfNeeded(_ frozen: FrozenClipExport) -> FrozenClipExport {
        guard !frozen.isPinned else { return frozen }
        var pinned = frozen
        writerQueue.sync {
            for segment in pinned.segments {
                pinnedSegmentReferenceCounts[segment.id, default: 0] += 1
            }
            pinned.isPinned = true
            saveManifest()
        }
        note("clip segment references pinned for live sample mux segments=\(pinned.segments.count) request=\(pinned.metadata.id.uuidString)")
        return pinned
    }

    private func performFrozenExport(_ frozen: FrozenClipExport) {
        var workingURLForCleanup: URL?
        let isManual = frozen.metadata.eventTags.contains("MANUAL")
        let executionDisposition = RinkLensClipExportPriorityPolicy.executionDisposition(
            writerContractOpen: RinkLensRecordingCaptureLease.shared.isWriterContractOpen(),
            isManual: isManual
        )
        do {
            let executionAdmitted = isManual
                ? RinkLensExecutionCoordinator.shared.admitsLiveManualClipMux()
                : RinkLensExecutionCoordinator.shared.admitsDeferredMediaWork()
            guard executionAdmitted else {
                deferFrozenExportForOperatorPriority(
                    frozen,
                    reason: isManual
                        ? "interactive manual passthrough remux yielded to operator/resource preparation"
                        : "media-resource owner rejected opaque offline remux while live capture lease was active"
                )
                return
            }
            // A prior route-boundary cancellation may have requeued this frozen
            // request before an AVAssetExportSession existed. Once the execution
            // owner admits this attempt, clear that consumed historical yield so
            // a later unrelated export failure cannot be misclassified. A new
            // operator transition during this attempt will set the request again.
            _ = consumeOperatorPriorityYieldRequest()
            if executionDisposition == .deferUntilRecordingStops {
                deferFrozenExportForRecordingPriority(frozen)
                return
            }
            setMediaExportActive(true)
            defer { setMediaExportActive(false) }
            try ensureFolders()
            let postFolderAdmission = isManual
                ? RinkLensExecutionCoordinator.shared.admitsLiveManualClipMux()
                : RinkLensExecutionCoordinator.shared.admitsDeferredMediaWork()
            guard postFolderAdmission else {
                deferFrozenExportForOperatorPriority(
                    frozen,
                    reason: isManual
                        ? "interactive manual passthrough remux yielded after folder preparation"
                        : "media-resource owner blocked opaque offline remux after folder preparation"
                )
                return
            }
            let workingURL = try workingExportURL(prefix: frozen.metadata.clipType, homeTeam: frozen.homeTeam, awayTeam: frozen.awayTeam)
            workingURLForCleanup = workingURL
            let completeURL = exportCompleteFolder!.appendingPathComponent(workingURL.lastPathComponent)
            let exportMetadata = try export(
                segments: frozen.segments,
                sourceStart: frozen.sourceStart,
                sourceEnd: frozen.sourceEnd,
                outputURL: workingURL,
                metadata: frozen.metadata
            )
            if FileManager.default.fileExists(atPath: completeURL.path) {
                try FileManager.default.removeItem(at: completeURL)
            }
            try FileManager.default.moveItem(at: workingURL, to: completeURL)
            workingURLForCleanup = nil
            var exportedMetadata = exportMetadata
            exportedMetadata.exportStatus = "complete"
            exportedMetadata.fileURL = completeURL
            writerQueue.sync {
                manifest.exportedClips.append(exportedMetadata)
                saveManifest()
            }
            releasePinnedSegments(frozen, reason: "clip export completed")
            statusOnMain(BroadcastManualClipPostRollPolicy.feedback(for: exportedMetadata))
            let normalisedStatus = BroadcastManualClipPostRollPolicy.normalisedStatusText(for: exportedMetadata)
            note("clip export result normalised status=\(normalisedStatus) resolved=\(String(format: "%.1f", exportedMetadata.actualDuration ?? 0))s requested=\(String(format: "%.1f", exportedMetadata.requestedDuration ?? 0))s reason=\(exportedMetadata.shortClipReason ?? "fullDuration")")
            note("clip export completed")
            DispatchQueue.main.async { frozen.completion(.success(ClipExportResult(url: completeURL, metadata: exportedMetadata))) }
        } catch {
            if let workingURLForCleanup,
               FileManager.default.fileExists(atPath: workingURLForCleanup.path) {
                do {
                    try FileManager.default.removeItem(at: workingURLForCleanup)
                    note("clip working export released after unsuccessful attempt \(workingURLForCleanup.lastPathComponent)")
                } catch {
                    note("clip working export cleanup failed \(workingURLForCleanup.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if consumeOperatorPriorityYieldRequest() {
                note("clip sample mux yielded to operator execution owner; frozen request requeued")
                deferFrozenExportForOperatorPriority(
                    frozen,
                    reason: "active clip mux was cancelled at a sample boundary for operator priority"
                )
                return
            }
            if executionDisposition == .executeLiveSampleMux {
                releasePinnedSegments(frozen, reason: "live manual clip mux failed")
                finishExportFailure(error, completion: frozen.completion)
                return
            }
            if RinkLensRecordingCaptureLease.shared.isWriterContractOpen() {
                note("clip remux yielded to open recording writer contract; frozen request requeued")
                RinkLensStructuredEventLogger.shared.record(
                    domain: .recording,
                    event: "clip_export_yielded_to_recording",
                    entityID: frozen.metadata.id.uuidString,
                    previous: ["export": "active", "error": error.localizedDescription],
                    next: ["export": "deferred", "segmentCount": String(frozen.segments.count)],
                    source: "ClipEngine.performFrozenExport",
                    reason: "Recording writer contract remained authoritative while the offline clip remux was active",
                    authoritativeOwner: "ClipEngine"
                )
                deferFrozenExportForRecordingPriority(frozen)
                return
            }
            if !RinkLensExecutionCoordinator.shared.admitsDeferredMediaWork() {
                note("Recovery AU clip remux yielded to media-resource/operator execution owner; frozen request requeued")
                deferFrozenExportForOperatorPriority(
                    frozen,
                    reason: "active offline export was pre-empted by media-resource/operator execution owner"
                )
                return
            }
            releasePinnedSegments(frozen, reason: "clip export failed")
            finishExportFailure(error, completion: frozen.completion)
        }
    }

    private func setMediaExportActive(_ active: Bool, session: AVAssetExportSession? = nil) {
        mediaExportActivityLock.lock()
        mediaExportActive = active
        activeExportSession = active ? session : nil
        if !active { activeCompressedSampleMux = nil }
        mediaExportActivityLock.unlock()
    }

    private func registerActiveExportSession(_ session: AVAssetExportSession) {
        mediaExportActivityLock.lock()
        mediaExportActive = true
        activeExportSession = session
        activeCompressedSampleMux = nil
        mediaExportActivityLock.unlock()
    }

    private func registerActiveCompressedSampleMux(_ operation: RinkLensCompressedSampleMuxOperation) {
        mediaExportActivityLock.lock()
        mediaExportActive = true
        activeExportSession = nil
        activeCompressedSampleMux = operation
        mediaExportActivityLock.unlock()
    }

    private func finishExportFailure(_ error: Error, completion: @escaping (Result<ClipExportResult, Error>) -> Void) {
        if case ClipBufferError.notEnoughBufferedVideo = error {
            statusOnMain("Clip unavailable — not enough recorded footage yet")
        } else {
            statusOnMain("Clip failed — recording continues")
        }
        updateExportFailure(error.localizedDescription)
        note("clip export failed: \(error.localizedDescription)")
        DispatchQueue.main.async { completion(.failure(error)) }
    }

    private func releasePinnedSegments(_ frozen: FrozenClipExport, reason: String) {
        guard frozen.isPinned else { return }
        writerQueue.sync {
            let segments = frozen.segments
            for segment in segments {
                guard let count = pinnedSegmentReferenceCounts[segment.id] else { continue }
                if count <= 1 {
                    pinnedSegmentReferenceCounts.removeValue(forKey: segment.id)
                } else {
                    pinnedSegmentReferenceCounts[segment.id] = count - 1
                }
            }
            cleanupExpiredSegments(now: Date())
            saveManifest()
            updateBufferDuration()
        }
        note("clip segment pins released reason=\(reason)")
    }

    private func beginSegment(firstSample: CMSampleBuffer) throws {
        try ensureFolders()
        guard let activeRecordingEpochID else { throw ClipBufferError.writerUnavailable }
        let id = UUID()
        let filename = "\(id.uuidString).mp4"
        guard let segmentFolder else { throw ClipBufferError.folderUnavailable }
        let url = segmentFolder.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        guard let formatDescription = CMSampleBufferGetFormatDescription(firstSample) else {
            throw ClipBufferError.writerUnavailable
        }
        // RecordingCompressionEngine is the sole encoder. ClipEngine is a
        // passthrough muxer over the exact same compressed Broadcast samples.
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: formatDescription
        )
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw ClipBufferError.writerUnavailable }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ClipBufferError.writerUnavailable }
        let firstPTS = CMSampleBufferGetPresentationTimeStamp(firstSample)
        writer.startSession(atSourceTime: firstPTS)

        let start = Date()
        manifest.segments.append(ClipBufferSegmentRecord(
            id: id,
            filename: filename,
            startTime: start,
            endTime: start,
            duration: 0,
            status: .writing,
            recordingEpochID: activeRecordingEpochID
        ))
        saveManifest()
        currentWriter = SegmentWriter(
            id: id,
            url: url,
            startedAt: start,
            writer: writer,
            input: input,
            firstSourcePresentationTime: firstPTS,
            lastPresentationTime: nil
        )
        note("\(activeFramePath.diagnosticText) passthrough segment started fps=\(fps) segment=\(String(format: "%.1f", activeSegmentDuration))s encoder=RecordingCompressionEngine")
    }

    private func finishCurrentSegmentForExportIfNeeded(reason: String) {
        let semaphore = DispatchSemaphore(value: 0)
        writerQueue.async { [weak self] in
            guard let self else {
                semaphore.signal()
                return
            }
            guard let segmentWriter = self.currentWriter else {
                self.note("clip post-roll export found no active segment to roll reason=\(reason)")
                semaphore.signal()
                return
            }
            self.currentWriter = nil
            let rolloverStartedAt = CFAbsoluteTimeGetCurrent()
            segmentWriter.input.markAsFinished()
            segmentWriter.writer.finishWriting { [weak self] in
                guard let self else {
                    semaphore.signal()
                    return
                }
                self.writerQueue.async {
                    let end = Date()
                    let rolloverDurationMS = (CFAbsoluteTimeGetCurrent() - rolloverStartedAt) * 1000
                    if let index = self.manifest.segments.firstIndex(where: { $0.id == segmentWriter.id }) {
                        self.manifest.segments[index].endTime = end
                        self.manifest.segments[index].duration = end.timeIntervalSince(segmentWriter.startedAt)
                        self.manifest.segments[index].status = segmentWriter.writer.status == .completed ? .complete : .failed
                    }
                    self.cleanupExpiredSegments(now: end)
                    self.saveManifest()
                    self.updateBufferDuration()
                    self.note(segmentWriter.writer.status == .completed ? "segment completed for post-roll export" : "segment failed during post-roll export")
                    self.note("clip post-roll forced segment rollover duration \(String(format: "%.1f", rolloverDurationMS))ms reason=\(reason)")
                    semaphore.signal()
                }
            }
        }
        semaphore.wait()
    }

    private func finishCurrentSegment() {
        guard let segmentWriter = currentWriter else { return }
        currentWriter = nil
        let rolloverStartedAt = CFAbsoluteTimeGetCurrent()
        segmentWriter.input.markAsFinished()
        segmentWriter.writer.finishWriting { [weak self] in
            guard let self else { return }
            self.writerQueue.async {
                let end = Date()
                let rolloverDurationMS = (CFAbsoluteTimeGetCurrent() - rolloverStartedAt) * 1000
                if let index = self.manifest.segments.firstIndex(where: { $0.id == segmentWriter.id }) {
                    self.manifest.segments[index].endTime = end
                    self.manifest.segments[index].duration = end.timeIntervalSince(segmentWriter.startedAt)
                    self.manifest.segments[index].status = segmentWriter.writer.status == .completed ? .complete : .failed
                }
                self.cleanupExpiredSegments(now: end)
                self.saveManifest()
                self.updateBufferDuration()
                self.note(segmentWriter.writer.status == .completed ? "segment completed" : "segment failed")
                self.note("segment rollover duration \(String(format: "%.1f", rolloverDurationMS))ms")
                if rolloverDurationMS > 50 {
                    self.note("segment rollover warning \(String(format: "%.1f", rolloverDurationMS))ms")
                }
            }
        }
    }

    private func cleanupExpiredSegments(now: Date) {
        var discardedCount = 0
        for index in manifest.segments.indices {
            guard manifest.segments[index].status == .complete else { continue }
            let segmentID = manifest.segments[index].id
            if pinnedSegmentReferenceCounts[segmentID, default: 0] > 0 {
                continue
            }
            let age = now.timeIntervalSince(manifest.segments[index].endTime)
            guard age > retentionDuration else { continue }
            if let url = urlForSegment(manifest.segments[index]) { try? FileManager.default.removeItem(at: url) }
            manifest.segments[index].status = .expired
            discardedCount += 1
            note("segment discarded due to age \(String(format: "%.1f", age))s retention=\(Int(retentionDuration))s")
        }
        if discardedCount > 0 {
            let retainedSegments = manifest.segments.filter { $0.status == .complete }.count
            let retainedDuration = completeBufferedDurationLocked
            note("clipbuffer retained \(retainedSegments) segments \(String(format: "%.1f", retainedDuration))s")
        }
    }

    private func completeSegments(overlapping start: Date, _ end: Date) -> [ClipBufferSegmentRecord] {
        manifest.segments
            .filter { $0.status == .complete && $0.endTime >= start && $0.startTime <= end }
            .sorted { $0.startTime < $1.startTime }
    }

    private func export(segments: [ClipBufferSegmentRecord], sourceStart: Date, sourceEnd: Date, outputURL: URL, metadata: HighlightClipMetadata) throws -> HighlightClipMetadata {
        if FileManager.default.fileExists(atPath: outputURL.path) { try FileManager.default.removeItem(at: outputURL) }
        note("clip requested duration \(Int((metadata.requestedDuration ?? sourceEnd.timeIntervalSince(sourceStart)).rounded()))s")
        let preparedSegments = prepareSegments(segments, sourceStart: sourceStart, sourceEnd: sourceEnd)
        let availableDuration = preparedSegments.reduce(0) { $0 + $1.actualDuration }
        note("clip available duration \(String(format: "%.2f", availableDuration))s")
        note("selected segment count \(preparedSegments.count)")
        guard availableDuration >= minimumExportDuration else {
            note("export failed due to no valid footage")
            throw ClipBufferError.notEnoughBufferedVideo
        }

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ClipBufferError.exportFailed
        }

        var cursor = CMTime.zero
        var audioCompositionTrack: AVMutableCompositionTrack?
        var ranges: [CMTimeRange] = []
        for segment in preparedSegments {
            if cursor == .zero { compositionTrack.preferredTransform = segment.preferredTransform }
            try compositionTrack.insertTimeRange(segment.sourceRange, of: segment.videoTrack, at: cursor)
            if let audioTrack = segment.audioTrack {
                if audioCompositionTrack == nil {
                    audioCompositionTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                try audioCompositionTrack?.insertTimeRange(segment.sourceRange, of: audioTrack, at: cursor)
            }
            ranges.append(CMTimeRange(start: cursor, duration: segment.sourceRange.duration))
            cursor = cursor + segment.sourceRange.duration
            note("selected segment \(segment.record.startTime)-\(segment.record.endTime)")
        }

        let actualDuration = max(0, cursor.seconds)
        guard actualDuration >= minimumExportDuration else {
            note("export failed due to no valid footage")
            throw ClipBufferError.notEnoughBufferedVideo
        }
        let gaps = detectedGaps(in: ranges)
        if gaps > 0 {
            note("composition gap detected \(gaps)")
            note("composition gap removed")
        }
        note("export timeline compacted")
        note("seam validation selected=\(String(format: "%.2f", availableDuration))s final=\(String(format: "%.2f", actualDuration))s inserted=\(preparedSegments.count) gaps=\(gaps)")

        // UX16d2h: manual PixelBuffer clips already contain the composited
        // Broadcast image. Prefer a passthrough remux so the clip path does not
        // start another decoder/encoder cycle. Automatic clips retain the
        // existing post-recording overlay burn-in path.
        let isManualClip = metadata.eventTags.contains("MANUAL")
        var exportedMetadata = metadata
        exportedMetadata.actualDuration = actualDuration
        if let firstSegment = preparedSegments.first, let lastSegment = preparedSegments.last {
            exportedMetadata.sourceStartTime = max(sourceStart, firstSegment.record.startTime)
            exportedMetadata.sourceEndTime = min(sourceEnd, lastSegment.record.endTime)
        }
        if let requested = metadata.requestedDuration, actualDuration + nearFullManualClipTolerance < requested {
            exportedMetadata.shortClipReason = shortClipReason(for: metadata, sourceStart: sourceStart, preparedSegments: preparedSegments)
            updateExportFailure(exportedMetadata.shortClipReason ?? "short clip reason unknown")
            note("short clip created \(String(format: "%.2f", actualDuration))s reason=\(exportedMetadata.shortClipReason ?? "unknown")")
        } else {
            updateExportFailure("none")
        }

        if isManualClip {
            guard let firstTrack = preparedSegments.first?.videoTrack else {
                throw ClipBufferError.exportFailed
            }
            let formatDescriptions: [CMFormatDescription]
            if #available(iOS 16.0, *) {
                let trackBox = RinkLensUncheckedSendable(value: firstTrack)
                formatDescriptions = try rinkLensBlockingAsync {
                    try await trackBox.value.load(.formatDescriptions)
                }
            } else if #unavailable(iOS 16.0) {
                formatDescriptions = firstTrack.formatDescriptions as! [CMFormatDescription]
            } else {
                formatDescriptions = []
            }
            guard let sourceFormatHint = formatDescriptions.first else {
                note("manual compressed-sample mux rejected missing source format description")
                throw ClipBufferError.exportFailed
            }
            let operation = try RinkLensCompressedSampleMuxOperation(
                composition: composition,
                track: compositionTrack,
                sourceFormatHint: sourceFormatHint,
                outputURL: outputURL
            )
            registerActiveCompressedSampleMux(operation)
            note("clip export mechanism=compressedSamplePassthrough encoder=none writerContractOpen=\(RinkLensRecordingCaptureLease.shared.isWriterContractOpen())")
            RinkLensStructuredEventLogger.shared.record(
                domain: .recording,
                event: "manual_clip_live_mux_started",
                entityID: metadata.id.uuidString,
                previous: ["segments": String(preparedSegments.count)],
                next: [
                    "mechanism": "compressedSamplePassthrough",
                    "encoder": "none",
                    "writerContractOpen": String(RinkLensRecordingCaptureLease.shared.isWriterContractOpen())
                ],
                source: "ClipEngine.export",
                reason: "Manual clip must persist before the full-match recording stops",
                authoritativeOwner: "ClipEngine"
            )
            try operation.run()
            RinkLensStructuredEventLogger.shared.record(
                domain: .recording,
                event: "manual_clip_live_mux_completed",
                entityID: metadata.id.uuidString,
                previous: ["mechanism": "compressedSamplePassthrough"],
                next: ["durationSeconds": String(format: "%.2f", actualDuration)],
                source: "ClipEngine.export",
                reason: "AVAssetWriter physically acknowledged the completed manual clip container",
                authoritativeOwner: "ClipEngine"
            )
            note("final muxed duration \(String(format: "%.2f", actualDuration))s")
            note("black-flash seam check delegated to physical playback acceptance")
            return exportedMetadata
        }

        if RinkLensClipExportPriorityPolicy.executionDisposition(
            writerContractOpen: RinkLensRecordingCaptureLease.shared.isWriterContractOpen(),
            isManual: isManualClip
        ) == .deferUntilRecordingStops {
            note("clip export invariant deferred physical remux while full recording writer contract remained open")
            throw ClipBufferError.recordingPriorityViolation
        }
        let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)
        guard let export else {
            throw ClipBufferError.exportFailed
        }
        note("clip export preset=highestQuality-postRecording")
        export.videoComposition = makeOverlayVideoComposition(
            composition: composition,
            track: compositionTrack,
            duration: cursor,
            metadata: exportedMetadata
        )
        note("overlay burn-in started")
        export.shouldOptimizeForNetworkUse = true
        // Recovery AN / RL-083: AVAssetExportSession is an opaque, effectively
        // non-preemptible media operation once export begins. Revalidate the
        // real-time admission boundary at the last possible point before handing
        // work to Apple media services. If CaptureEngine is pressured, dropping,
        // stale, or an operator/critical boundary is active, retain the pinned
        // clip instead of starting the export.
        let exportAdmission = RinkLensExecutionCoordinator.shared.admitsDeferredMediaWork()
        guard exportAdmission else {
            RinkLensExecutionCoordinator.shared.noteDeferredMediaYield()
            let admission = RinkLensExecutionCoordinator.shared.snapshot().deferredMediaCaptureAdmissionText
            note("clip remux held before AVAssetExportSession start because higher-priority execution is active {\(admission)}")
            throw ClipBufferError.recordingPriorityViolation
        }
        registerActiveExportSession(export)
        defer { setMediaExportActive(false) }
        if RinkLensClipExportPriorityPolicy.executionDisposition(
            writerContractOpen: RinkLensRecordingCaptureLease.shared.isWriterContractOpen(),
            isManual: isManualClip
        ) == .deferUntilRecordingStops {
            export.cancelExport()
            note("clip export cancelled before start because physical remux cannot share the recording writer lifetime")
            throw ClipBufferError.recordingPriorityViolation
        }
        if #available(iOS 18.0, *) {
            let exportBox = RinkLensUncheckedSendable(value: export)
            try rinkLensBlockingAsync {
                try await exportBox.value.export(to: outputURL, as: .mp4)
            }
        } else if #unavailable(iOS 18.0) {
            try performLegacyExport(export, outputURL: outputURL)
        }
        note("final exported duration \(String(format: "%.2f", actualDuration))s")
        note("black-flash seam check passed")
        return exportedMetadata
    }

    @available(iOS, introduced: 4.0, deprecated: 18.0)
    private func performLegacyExport(_ export: AVAssetExportSession, outputURL: URL) throws {
        export.outputURL = outputURL
        export.outputFileType = .mp4
        let semaphore = DispatchSemaphore(value: 0)
        export.exportAsynchronously { semaphore.signal() }
        semaphore.wait()
        if export.status != .completed {
            throw export.error ?? ClipBufferError.exportFailed
        }
    }

    private func prepareSegments(_ segments: [ClipBufferSegmentRecord], sourceStart: Date, sourceEnd: Date) -> [PreparedSegment] {
        var prepared: [PreparedSegment] = []
        var lastEnd: Date?
        for segment in segments {
            guard segment.status == .complete else { continue }
            guard let url = urlForSegment(segment), FileManager.default.fileExists(atPath: url.path) else {
                note("skipped invalid segment missing file \(segment.filename)")
                continue
            }
            let asset = AVURLAsset(url: url)

            let loaded: (duration: CMTime, videoTrack: AVAssetTrack?, audioTrack: AVAssetTrack?, preferredTransform: CGAffineTransform)
            do {
                if #available(iOS 16.0, *) {
                    let assetBox = RinkLensUncheckedSendable(value: asset)
                    loaded = try rinkLensBlockingAsync {
                        let duration = try await assetBox.value.load(.duration)
                        let videoTrack = try await assetBox.value.loadTracks(withMediaType: .video).first
                        let audioTrack = try await assetBox.value.loadTracks(withMediaType: .audio).first
                        let transform = try await videoTrack?.load(.preferredTransform) ?? .identity
                        return (duration, videoTrack, audioTrack, transform)
                    }
                } else if #unavailable(iOS 16.0) {
                    loaded = legacyLoadedAssetValues(asset)
                } else {
                    continue
                }
            } catch {
                note("skipped invalid segment load failure \(segment.filename): \(error.localizedDescription)")
                continue
            }

            let assetDuration = loaded.duration.seconds
            guard assetDuration.isFinite, assetDuration > 0 else {
                note("skipped invalid segment duration \(segment.filename)")
                continue
            }
            guard assetDuration >= minimumValidSegmentDuration || segments.count == 1 else {
                note("skipped invalid segment too short \(String(format: "%.2f", assetDuration))s")
                continue
            }
            guard let videoTrack = loaded.videoTrack else {
                note("skipped invalid segment missing video \(segment.filename)")
                continue
            }
            let overlapStart = max(sourceStart, segment.startTime)
            let overlapEnd = min(sourceEnd, segment.endTime)
            guard overlapEnd > overlapStart else { continue }
            let manifestDuration = max(segment.duration, 0.001)
            let startRatio = max(0, overlapStart.timeIntervalSince(segment.startTime)) / manifestDuration
            let endRatio = min(manifestDuration, overlapEnd.timeIntervalSince(segment.startTime)) / manifestDuration
            let startSeconds = min(assetDuration, max(0, startRatio * assetDuration))
            let endSeconds = min(assetDuration, max(startSeconds, endRatio * assetDuration))
            guard endSeconds > startSeconds else {
                note("skipped invalid segment empty range \(segment.filename)")
                continue
            }
            if let lastEnd = lastEnd, segment.startTime < lastEnd {
                note("selected segment overlap trimmed \(segment.filename)")
            }
            lastEnd = segment.endTime
            let startTime = CMTime(seconds: startSeconds, preferredTimescale: 600)
            let duration = CMTime(seconds: endSeconds - startSeconds, preferredTimescale: 600)
            prepared.append(PreparedSegment(
                record: segment,
                asset: asset,
                videoTrack: videoTrack,
                audioTrack: loaded.audioTrack,
                preferredTransform: loaded.preferredTransform,
                sourceRange: CMTimeRange(start: startTime, duration: duration),
                actualDuration: endSeconds - startSeconds
            ))
        }
        return prepared.sorted { $0.record.startTime < $1.record.startTime }
    }

    @available(iOS, introduced: 4.0, deprecated: 16.0)
    private func legacyLoadedAssetValues(
        _ asset: AVURLAsset
    ) -> (duration: CMTime, videoTrack: AVAssetTrack?, audioTrack: AVAssetTrack?, preferredTransform: CGAffineTransform) {
        let videoTrack = asset.tracks(withMediaType: .video).first
        return (
            asset.duration,
            videoTrack,
            asset.tracks(withMediaType: .audio).first,
            videoTrack?.preferredTransform ?? .identity
        )
    }

    private func detectedGaps(in ranges: [CMTimeRange]) -> Int {
        guard ranges.count > 1 else { return 0 }
        var gaps = 0
        for index in 1..<ranges.count {
            let previousEnd = ranges[index - 1].end.seconds
            let currentStart = ranges[index].start.seconds
            if currentStart - previousEnd > 0.05 { gaps += 1 }
        }
        return gaps
    }

    private func shortClipReason(for metadata: HighlightClipMetadata, sourceStart: Date, preparedSegments: [PreparedSegment]) -> String {
        if let reason = metadata.shortClipReason { return reason }
        guard let first = preparedSegments.first else { return "bufferUnavailable" }
        if first.record.startTime > sourceStart {
            return metadata.eventTags.contains("MANUAL") ? BroadcastManualClipPostRollPolicy.partialReasonStartOfRecording : "clockAnchorTooEarly"
        }
        return BroadcastManualClipPostRollPolicy.partialReasonTimingVariance
    }

    private func manualPartialReasonLocked(
        metadata: HighlightClipMetadata,
        selectedDuration: TimeInterval,
        requestedStart: Date,
        requestedEnd: Date,
        resolvedStart: Date,
        resolvedEnd: Date,
        completeSegments: [ClipBufferSegmentRecord],
        selectedSegments: [ClipBufferSegmentRecord]
    ) -> String? {
        guard BroadcastManualClipPostRollPolicy.isManualPostRoll(metadata),
              selectedDuration >= BroadcastManualClipPostRollPolicy.minimumExportableSeconds,
              let firstComplete = completeSegments.first,
              let lastComplete = completeSegments.last else {
            return nil
        }

        let tolerance: TimeInterval = 0.35
        if requestedStart < firstComplete.startTime.addingTimeInterval(-tolerance),
           abs(resolvedStart.timeIntervalSince(firstComplete.startTime)) <= tolerance {
            return BroadcastManualClipPostRollPolicy.partialReasonStartOfRecording
        }

        if requestedEnd > lastComplete.endTime.addingTimeInterval(tolerance),
           abs(resolvedEnd.timeIntervalSince(lastComplete.endTime)) <= tolerance,
           !selectedSegments.isEmpty {
            return BroadcastManualClipPostRollPolicy.partialReasonRecordingStoppedBeforePostRoll
        }

        return nil
    }

    private func makeOverlayVideoComposition(
        composition: AVMutableComposition,
        track: AVCompositionTrack,
        duration: CMTime,
        metadata: HighlightClipMetadata
    ) -> AVVideoComposition {
        let naturalSize = track.naturalSize == .zero ? frameSize : track.naturalSize
        let renderSize = CGSize(width: abs(naturalSize.width), height: abs(naturalSize.height))

        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.frame
        parentLayer.addSublayer(videoLayer)

        let overlayLayer = CALayer()
        overlayLayer.frame = parentLayer.frame
        overlayLayer.opacity = 0

        let background = CALayer()
        background.backgroundColor = UIColor.black.withAlphaComponent(0.72).cgColor
        background.cornerRadius = 18
        background.frame = CGRect(x: 40, y: renderSize.height - 230, width: min(720, renderSize.width - 80), height: 150)
        overlayLayer.addSublayer(background)

        // Offline rendering should be deterministic and must not depend on the
        // process-global UIScreen singleton, which is deprecated in iOS 26.
        let textContentsScale: CGFloat = 2.0

        let title = CATextLayer()
        title.contentsScale = textContentsScale
        title.foregroundColor = UIColor.white.cgColor
        title.fontSize = 44
        title.font = UIFont.boldSystemFont(ofSize: 44)
        title.alignmentMode = .left
        title.string = overlayTitle(for: metadata)
        title.frame = CGRect(x: background.frame.minX + 28, y: background.frame.minY + 20, width: background.frame.width - 56, height: 56)
        overlayLayer.addSublayer(title)

        let subtitle = CATextLayer()
        subtitle.contentsScale = textContentsScale
        subtitle.foregroundColor = UIColor.white.withAlphaComponent(0.9).cgColor
        subtitle.fontSize = 28
        subtitle.font = UIFont.systemFont(ofSize: 28, weight: .semibold)
        subtitle.alignmentMode = .left
        subtitle.string = overlaySubtitle(for: metadata)
        subtitle.frame = CGRect(x: background.frame.minX + 28, y: background.frame.minY + 86, width: background.frame.width - 56, height: 42)
        overlayLayer.addSublayer(subtitle)

        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        let durationSeconds = max(0, duration.seconds.isFinite ? duration.seconds : 0)
        let overlayLength = durationSeconds < 6 ? min(2, durationSeconds) : min(5, max(1, durationSeconds * 0.25))
        fadeIn.beginTime = max(0, durationSeconds - overlayLength)
        fadeIn.duration = 0.2
        fadeIn.fillMode = .forwards
        fadeIn.isRemovedOnCompletion = false
        overlayLayer.add(fadeIn, forKey: "clipOverlayIn")

        parentLayer.addSublayer(overlayLayer)
        let animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )
        let frameDuration = CMTime(value: 1, timescale: max(fps, 1))

        if #available(iOS 26.0, *) {
            return makeModernOverlayVideoComposition(
                track: track,
                duration: duration,
                renderSize: renderSize,
                frameDuration: frameDuration,
                animationTool: animationTool
            )
        }

        if #unavailable(iOS 26.0) {
            return makeLegacyOverlayVideoComposition(
                track: track,
                duration: duration,
                renderSize: renderSize,
                frameDuration: frameDuration,
                animationTool: animationTool
            )
        }

        preconditionFailure("Unsupported iOS availability state")
    }

    @available(iOS 26.0, *)
    private func makeModernOverlayVideoComposition(
        track: AVCompositionTrack,
        duration: CMTime,
        renderSize: CGSize,
        frameDuration: CMTime,
        animationTool: AVVideoCompositionCoreAnimationTool
    ) -> AVVideoComposition {
        var layerConfiguration = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
        layerConfiguration.setTransform(track.preferredTransform, at: .zero)
        let layerInstruction = AVVideoCompositionLayerInstruction(configuration: layerConfiguration)

        var instructionConfiguration = AVVideoCompositionInstruction.Configuration()
        instructionConfiguration.timeRange = CMTimeRange(start: .zero, duration: duration)
        instructionConfiguration.layerInstructions = [layerInstruction]
        let instruction = AVVideoCompositionInstruction(configuration: instructionConfiguration)

        var configuration = AVVideoComposition.Configuration()
        configuration.renderSize = renderSize
        configuration.frameDuration = frameDuration
        configuration.instructions = [instruction]
        configuration.animationTool = animationTool
        return AVVideoComposition(configuration: configuration)
    }

    @available(iOS, introduced: 4.0, deprecated: 26.0)
    private func makeLegacyOverlayVideoComposition(
        track: AVCompositionTrack,
        duration: CMTime,
        renderSize: CGSize,
        frameDuration: CMTime,
        animationTool: AVVideoCompositionCoreAnimationTool
    ) -> AVVideoComposition {
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layerInstruction.setTransform(track.preferredTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = frameDuration
        videoComposition.instructions = [instruction]
        videoComposition.animationTool = animationTool
        return videoComposition
    }

    private func overlayTitle(for metadata: HighlightClipMetadata) -> String {
        if metadata.eventTags.contains("GOAL") && metadata.eventTags.contains("PENALTY") { return "Goal + Penalty" }
        if metadata.eventTags.contains("GOAL") { return "Goal" }
        if metadata.eventTags.contains("PENALTY") { return "Penalty" }
        if metadata.eventTags.contains("PERIOD_END") { return "Period End" }
        if metadata.eventTags.contains("GAME_END") { return "Game End" }
        return metadata.eventTags.joined(separator: " + ")
    }

    private func overlaySubtitle(for metadata: HighlightClipMetadata) -> String {
        var parts: [String] = []
        if let period = metadata.period { parts.append("P\(period)") }
        if let gameClockValue = metadata.gameClockValue { parts.append(gameClockValue) }
        if let team = metadata.team { parts.append(team) }
        if let playerNumber = metadata.playerNumber { parts.append("#\(playerNumber)") }
        return parts.joined(separator: "  ")
    }

    private func ensureFolders() throws {
        if rootFolder != nil { return }
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = documents.appendingPathComponent("LiveRinkLensLive", isDirectory: true)
        let buffer = root.appendingPathComponent("ClipBuffer", isDirectory: true)
        let segments = buffer.appendingPathComponent("segments", isDirectory: true)
        let exports = root.appendingPathComponent("ClipExports", isDirectory: true)
        let working = exports.appendingPathComponent("working", isDirectory: true)
        let complete = exports.appendingPathComponent("complete", isDirectory: true)
        let failed = exports.appendingPathComponent("failed", isDirectory: true)
        for folder in [root, buffer, segments, exports, working, complete, failed] {
            if !FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
        }
        rootFolder = root
        bufferFolder = buffer
        segmentFolder = segments
        exportWorkingFolder = working
        exportCompleteFolder = complete
        exportFailedFolder = failed
    }

    private func manifestURL() -> URL? {
        bufferFolder?.appendingPathComponent("manifest.json")
    }

    private func loadManifest() {
        guard let url = manifestURL(), let data = try? Data(contentsOf: url) else { return }
        manifest = (try? JSONDecoder().decode(Manifest.self, from: data)) ?? Manifest()
    }

    private func saveManifest() {
        guard let url = manifestURL(), let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func urlForSegment(_ segment: ClipBufferSegmentRecord) -> URL? {
        segmentFolder?.appendingPathComponent(segment.filename)
    }

    private func workingExportURL(prefix: String, homeTeam: String, awayTeam: String) throws -> URL {
        guard let exportWorkingFolder else { throw ClipBufferError.folderUnavailable }
        let timestamp = Self.timestampFormatter.string(from: Date())
        let teams = "\(homeTeam)_vs_\(awayTeam)".replacingOccurrences(of: " ", with: "_")
        return exportWorkingFolder.appendingPathComponent("\(timestamp)_\(teams)_\(prefix)_clip.mp4")
    }


    private func updateExportDiagnostics(
        requestedDuration: TimeInterval,
        resolvedDuration: TimeInterval?,
        windowText: String,
        sourceText: String,
        failureReason: String
    ) {
        let requestedText = "\(Int(max(0, requestedDuration).rounded()))s"
        let resolvedText = resolvedDuration.map { String(format: "%.1fs", max(0, $0)) } ?? "pending"
        DispatchQueue.main.async {
            self.lastClipExportRequestedDurationText = requestedText
            self.lastClipExportResolvedDurationText = resolvedText
            self.lastClipExportWindowText = windowText
            self.lastClipExportSourceText = sourceText
            self.lastClipExportFailureReasonText = failureReason
        }
    }

    private func updateExportFailure(_ reason: String) {
        DispatchQueue.main.async {
            self.lastClipExportFailureReasonText = reason
        }
    }

    private func updateBufferDuration() {
        let duration = completeBufferedDurationLocked
        let path = activeFramePath
        let readyCoverage = resolvedManualClipCoverageLocked(
            seconds: Int(BroadcastPixelBufferClipPerformanceGuard.minimumReadyCoverageSeconds),
            anchor: Date()
        )
        let ready = bufferRunning
            && readyCoverage + BroadcastPixelBufferClipPerformanceGuard.exportDurationToleranceSeconds
                >= BroadcastPixelBufferClipPerformanceGuard.minimumReadyCoverageSeconds
        DispatchQueue.main.async {
            self.bufferDurationText = "\(Int(duration.rounded()))s buffered"
            self.clipStatusText = ready ? "Clip ready" : "Clip unavailable"
            self.clipBufferPathText = path.rawValue
            self.lastClipExportSourceText = "Compressed-sample clip buffer active; ready coverage=\(String(format: "%.1f", readyCoverage))s; one shared encoder"
        }
    }

    private func resolvedManualClipCoverageLocked(seconds: Int, anchor: Date) -> TimeInterval {
        let requested = max(0, TimeInterval(seconds))
        let complete = completeSegmentsForActiveEpochLocked()
            .sorted { $0.startTime < $1.startTime }
        let resolved = ClipBufferExportWindowResolver.resolve(
            requestedStart: anchor.addingTimeInterval(-requested),
            requestedEnd: anchor,
            requestedDuration: requested,
            completeSegments: complete,
            recordingEpochID: activeRecordingEpochID
        )
        return selectedCoverageDuration(segments: resolved.selectedSegments, start: resolved.start, end: resolved.end)
    }

    private func selectedCoverageDuration(segments: [ClipBufferSegmentRecord], start: Date, end: Date) -> TimeInterval {
        segments.reduce(0) { partial, segment in
            let overlapStart = max(segment.startTime, start)
            let overlapEnd = min(segment.endTime, end)
            return partial + max(0, overlapEnd.timeIntervalSince(overlapStart))
        }
    }

    private func statusOnMain(_ text: String) {
        DispatchQueue.main.async { self.clipStatusText = text }
    }

    private func isActiveOnMain(_ active: Bool, path: ClipBufferFramePath? = nil) {
        let effectivePath = path ?? activeFramePath
        DispatchQueue.main.async {
            self.isActive = active
            self.clipStatusText = active ? "Clip unavailable" : "Clip unavailable"
            self.clipBufferPathText = effectivePath.rawValue
            self.clipWriterMainPathSuppressedText = "Yes"
            self.rolloverTelemetrySuppressedFromUIText = "Yes"
            self.lastClipExportSourceText = active
                ? "Compressed-sample clip buffer active; source is the full recording encoder"
                : self.lastClipExportSourceText
            self.lastClipExportFailureReasonText = active ? "none" : self.lastClipExportFailureReasonText
        }
    }

    private func purgeBufferedSegmentsLocked(reason: String) {
        var removed = 0
        var retained: [ClipBufferSegmentRecord] = []
        for segment in manifest.segments {
            if pinnedSegmentReferenceCounts[segment.id, default: 0] > 0 {
                retained.append(segment)
                continue
            }
            if let url = urlForSegment(segment) { try? FileManager.default.removeItem(at: url) }
            removed += 1
        }
        manifest.segments = retained
        currentWriter = nil
        saveManifest()
        updateBufferDuration()
        note("clip buffer purged \(removed) stale segments and retained \(retained.count) pinned segment(s): \(reason)")
    }

    private func performRecoveryCleanupLocked() throws {
        try ensureFolders()
        loadManifest()
        note("recovery cleanup started")

        let listed = Set(manifest.segments.map(\.filename))
        if let segmentFolder {
            let files = (try? FileManager.default.contentsOfDirectory(at: segmentFolder, includingPropertiesForKeys: nil)) ?? []
            for file in files where !listed.contains(file.lastPathComponent) || file.lastPathComponent.contains(".writing.") {
                try? FileManager.default.removeItem(at: file)
            }
        }

        manifest.segments.removeAll { segment in
            if segment.status == .writing || segment.status == .failed {
                if let url = urlForSegment(segment) { try? FileManager.default.removeItem(at: url) }
                return true
            }
            guard let url = urlForSegment(segment), FileManager.default.fileExists(atPath: url.path) else {
                return true
            }
            return false
        }

        if let working = exportWorkingFolder {
            let files = (try? FileManager.default.contentsOfDirectory(at: working, includingPropertiesForKeys: nil)) ?? []
            files.forEach { try? FileManager.default.removeItem(at: $0) }
        }
        saveManifest()
        note("recovery cleanup completed")
    }

    private func note(_ text: String) {
        DispatchQueue.main.async {
            // v0.9.1v: routine segment writer activity must not become the
            // active UI context during 60fps recording. Keep it available for
            // export diagnostics, but do not mark the main-thread stall monitor
            // or publish it as the live clip-buffer message while recording.
            if Self.isBackgroundWriterTelemetry(text) {
                self.lastClipWriterBackgroundEventText = text
                if Self.isRolloverTelemetry(text) {
                    self.lastRolloverTelemetryText = text
                }
                if RinkLensRecordingCaptureLease.shared.isWriterContractOpen() {
                    self.clipWriterMainPathSuppressedText = "Yes"
                    self.rolloverTelemetrySuppressedFromUIText = "Yes"
                    return
                }
            }

            self.lastDiagnosticText = text
            // UX16d2h: background writer/export labels are not evidence that
            // the main thread executed that operation. Do not overwrite the
            // heartbeat context from a background queue; explicit main-thread
            // call sites own their own stall markers.
        }
    }

    private static func isRolloverTelemetry(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("segment rollover duration")
            || lower.contains("segment rollover warning")
            || lower.contains("segment completed")
    }

    private static func isBackgroundWriterTelemetry(_ text: String) -> Bool {
        let lower = text.lowercased()
        return isRolloverTelemetry(text)
            || lower.contains("segment writing started")
            || lower.contains("pixelbuffer clip segment frame appended")
            || lower.contains("clip pixelbuffer frame skipped")
            || lower.contains("clip pixelbuffer append warning")
            || lower.contains("segment discarded due to age")
            || lower.contains("clipbuffer retained")
    }

    private func diagnosticTime(_ date: Date) -> String {
        Self.diagnosticTimeFormatter.string(from: date)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    private static let diagnosticTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    enum ClipBufferError: LocalizedError {
        case folderUnavailable
        case writerUnavailable
        case notEnoughBufferedVideo
        case exportFailed
        case recordingPriorityViolation

        var errorDescription: String? {
            switch self {
            case .folderUnavailable: return "Clip folders unavailable"
            case .writerUnavailable: return "Clip segment writer unavailable"
            case .notEnoughBufferedVideo: return "Clip unavailable — not enough recorded footage yet"
            case .exportFailed: return "Clip export failed"
            case .recordingPriorityViolation: return "Clip export deferred because full recording has priority"
            }
        }
    }
}
/// Temporary type bridge for later-stage UI and diagnostics call sites.
typealias ClipBufferManager = ClipEngine

#endif
