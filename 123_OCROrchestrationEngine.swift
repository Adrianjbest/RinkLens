// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation
import SwiftUI
import AVFoundation
import CoreMedia
import CoreVideo
import CoreGraphics
import UIKit

// MARK: - UX16d4 core OCR execution boundary

nonisolated struct RinkLensOCRPassToken: Sendable, Equatable, Hashable {
    let id: UInt64
    let orchestrationGeneration: Int

    var diagnosticText: String { "pass-\(id)@gen-\(orchestrationGeneration)" }
}

/// Copies a capture-owned pixel buffer before asynchronous OCR begins.
/// No OCR operation may retain a FrameHub/AVFoundation buffer.
nonisolated enum RinkLensOCRFrameOwnership {
    static func makeOwnedCopy(of source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let pixelFormat = CVPixelBufferGetPixelFormatType(source)
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]

        var destination: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attributes as CFDictionary,
            &destination
        )
        guard status == kCVReturnSuccess, let destination else { return nil }

        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }

        let sourcePlaneCount = CVPixelBufferGetPlaneCount(source)
        let destinationPlaneCount = CVPixelBufferGetPlaneCount(destination)
        if sourcePlaneCount > 0 || destinationPlaneCount > 0 {
            guard sourcePlaneCount == destinationPlaneCount else { return nil }
            for plane in 0..<sourcePlaneCount {
                guard let sourceBase = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let destinationBase = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else {
                    return nil
                }
                let rows = min(
                    CVPixelBufferGetHeightOfPlane(source, plane),
                    CVPixelBufferGetHeightOfPlane(destination, plane)
                )
                let sourceBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                let destinationBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
                let bytesToCopy = min(sourceBytesPerRow, destinationBytesPerRow)
                for row in 0..<rows {
                    destinationBase
                        .advanced(by: row * destinationBytesPerRow)
                        .copyMemory(
                            from: sourceBase.advanced(by: row * sourceBytesPerRow),
                            byteCount: bytesToCopy
                        )
                }
            }
        } else {
            guard let sourceBase = CVPixelBufferGetBaseAddress(source),
                  let destinationBase = CVPixelBufferGetBaseAddress(destination) else {
                return nil
            }
            let rows = min(CVPixelBufferGetHeight(source), CVPixelBufferGetHeight(destination))
            let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(source)
            let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(destination)
            let bytesToCopy = min(sourceBytesPerRow, destinationBytesPerRow)
            for row in 0..<rows {
                destinationBase
                    .advanced(by: row * destinationBytesPerRow)
                    .copyMemory(
                        from: sourceBase.advanced(by: row * sourceBytesPerRow),
                        byteCount: bytesToCopy
                    )
            }
        }
        return destination
    }
}

struct RinkLensOCRFrameLease: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let generation: Int
    let submittedAt: CFAbsoluteTime
    let sourceSequence: Int?
    let captureGeneration: Int
    let sourceDescription: String
    let passToken: RinkLensOCRPassToken
    let orchestrationGeneration: Int
}

struct RinkLensOCRFrameAnalysis: @unchecked Sendable {
    let frame: RinkLensOCRFrameLease
    let hashes: [OCRRegionKey: UInt64]
    let motionHashes: [OCRRegionKey: UInt64]
    let elapsedSeconds: CFTimeInterval
}

struct RinkLensOCRRecognitionOutput: @unchecked Sendable {
    let state: ScoreboardState
    let rawText: String?
    let fieldDebug: [ScoreboardOCRProcessor.OCRFieldDebug]
}

struct RinkLensOCRRecognitionResult: @unchecked Sendable {
    let generation: Int
    let passToken: RinkLensOCRPassToken
    let output: RinkLensOCRRecognitionOutput?
    let elapsedSeconds: CFTimeInterval
    let requestedKeys: Set<OCRRegionKey>
    let purpose: String
}

nonisolated enum RinkLensOCRRuntimeTruthPolicy {
    static func isStalled(
        executorWorkInFlight: Bool,
        activePassID: UInt64?,
        stalledPassID: UInt64?
    ) -> Bool {
        executorWorkInFlight
            && activePassID != nil
            && stalledPassID == activePassID
    }

    static func stalledStatusText(
        passAgeSeconds: TimeInterval?,
        stage: String,
        stageAgeSeconds: TimeInterval?
    ) -> String {
        let passAge = passAgeSeconds.map { String(format: "%.1fs", $0) } ?? "unknown"
        let stageAge = stageAgeSeconds.map { String(format: "%.1fs", $0) } ?? "unknown"
        return "OCR Stalled — pass \(passAge); current \(stage) \(stageAge)"
    }
}

struct RinkLensOCROrchestrationSnapshot: Sendable, Equatable {
    let isBusy: Bool
    let submittedPasses: Int
    let completedPasses: Int
    let droppedPasses: Int
    let hashPasses: Int
    let recognitionPasses: Int
    let selectedZonePasses: Int
    let lastPurpose: String
    let lastPhase: String
    let lastDurationSeconds: CFTimeInterval
    let lastRequestedKeys: [String]
    let lastResetReason: String
    let activePassID: UInt64?
    let activePassAgeSeconds: TimeInterval?
    let lastFinishAgeSeconds: TimeInterval?
    let lastFinishReason: String
    let cancelledPasses: Int
    let ignoredLateFinishes: Int
    let stallRecoveries: Int
    let activeWorkerID: Int
    let workerRotations: Int
    let ownedFrameCopies: Int
    let ownedFrameCopyFailures: Int
    let deadlineExceededPasses: Int
    let executorWorkInFlight: Bool
    let activeProcessorStage: String
    let activeProcessorStageAgeSeconds: TimeInterval?
    let lastCompletedProcessorStage: String
    let lastProcessorStageDurationSeconds: TimeInterval
    let stalledProcessorStage: String?
    let isStalled: Bool

    var diagnosticText: String {
        let keys = lastRequestedKeys.isEmpty ? "none" : lastRequestedKeys.joined(separator: ",")
        let active = activePassID.map { String($0) } ?? "none"
        let activeAge = activePassAgeSeconds.map { String(format: "%.2fs", $0) } ?? "--"
        let finishAge = lastFinishAgeSeconds.map { String(format: "%.2fs", $0) } ?? "--"
        let stageAge = activeProcessorStageAgeSeconds.map { String(format: "%.2fs", $0) } ?? "--"
        let stalled = stalledProcessorStage ?? "none"
        return "busy=\(isBusy) activePass=\(active) activeAge=\(activeAge) submitted=\(submittedPasses) completed=\(completedPasses) "
            + "dropped=\(droppedPasses) cancelled=\(cancelledPasses) deadlineExceeded=\(deadlineExceededPasses) lateFinish=\(ignoredLateFinishes) "
            + "worker=\(activeWorkerID) rotations=\(workerRotations) executorInFlight=\(executorWorkInFlight) "
            + "stage=\(activeProcessorStage) stageAge=\(stageAge) lastStage=\(lastCompletedProcessorStage)/\(String(format: "%.3fs", lastProcessorStageDurationSeconds)) stalled=\(isStalled ? stalled : "no") "
            + "ownedCopies=\(ownedFrameCopies) copyFailures=\(ownedFrameCopyFailures) "
            + "hash=\(hashPasses) recognise=\(recognitionPasses) test=\(selectedZonePasses) "
            + "phase=\(lastPhase) purpose=\(lastPurpose) finishAge=\(finishAge) finish=\(lastFinishReason) "
            + String(format: "duration=%.3fs", lastDurationSeconds)
            + " keys=[\(keys)] reset=\(lastResetReason)"
    }
}

/// One authoritative OCR pass state machine.
///
/// Build 501 intentionally does not reuse the Build 499/500 worker-drain chain.
/// Cancellation invalidates a pass and releases admission synchronously. A stale
/// CPU task may finish later, but it cannot keep `executorWorkInFlight` true and
/// cannot publish. Every pass owns a fresh deterministic processor instance, so a
/// cancelled task can never wedge the next pass behind a serial queue.
nonisolated final class RinkLensOCROrchestrationEngine: @unchecked Sendable {

    private struct HashWork: @unchecked Sendable {
        let frame: RinkLensOCRFrameLease
        let layout: ScoreboardOCRLayout
        let boardCalibration: BoardCalibrationQuad
        let motionKeys: Set<OCRRegionKey>
        let hashKeys: Set<OCRRegionKey>
        let deviceOrientation: UIDeviceOrientation
        let previewSize: CGSize
        let previewRotationDegrees: CGFloat
    }

    private struct RecognitionWork: @unchecked Sendable {
        let frame: RinkLensOCRFrameLease
        let layout: ScoreboardOCRLayout
        let boardCalibration: BoardCalibrationQuad
        let scoreboardTemplate: RinkScoreboardTemplate?
        let thresholds: OCRThresholds
        let colourProfiles: OCRColourProfileSet
        let previewSize: CGSize
        let previewRotationDegrees: CGFloat
        let enableSegmentedFallback: Bool
        let keysToProcess: Set<OCRRegionKey>
        let processorAllowedKeys: Set<OCRRegionKey>
        let includePipelineDiagnostics: Bool
        let executionPolicy: RinkLensOCRExecutionPolicy
        let maximumProcessingSeconds: TimeInterval
        let purpose: String
    }

    private struct MutableDiagnostics {
        var isBusy = false
        var submittedPasses = 0
        var completedPasses = 0
        var droppedPasses = 0
        var hashPasses = 0
        var recognitionPasses = 0
        var selectedZonePasses = 0
        var lastPurpose = "idle"
        var lastPhase = "idle"
        var lastDurationSeconds: CFTimeInterval = 0
        var lastRequestedKeys: [String] = []
        var lastResetReason = "never reset"
        var activePassID: UInt64?
        var activePassStartedUptimeNanoseconds: UInt64?
        var lastFinishUptimeNanoseconds: UInt64?
        var lastFinishReason = "none"
        var cancelledPasses = 0
        var ignoredLateFinishes = 0
        var stallRecoveries = 0
        var activeWorkerID = 0
        var workerRotations = 0
        var ownedFrameCopies = 0
        var ownedFrameCopyFailures = 0
        var deadlineExceededPasses = 0
        var executorWorkInFlight = false
        var activeProcessorStage = RinkLensOCRProcessingStage.idle.rawValue
        var activeProcessorStageStartedUptimeNanoseconds: UInt64?
        var lastCompletedProcessorStage = RinkLensOCRProcessingStage.idle.rawValue
        var lastProcessorStageDurationSeconds: TimeInterval = 0
        var stalledPassID: UInt64?
        var stalledProcessorStage: String?
    }

    private let lock = NSLock()
    private var diagnostics = MutableDiagnostics()
    private var cancellationGeneration = 0
    private var nextPassID: UInt64 = 0
    private var activePassToken: RinkLensOCRPassToken?
    private var executorPassToken: RinkLensOCRPassToken?

    func makeFrameLease(
        pixelBuffer: CVPixelBuffer,
        generation: Int,
        passToken: RinkLensOCRPassToken,
        sourceSequence: Int? = nil,
        captureGeneration: Int = 0,
        sourceDescription: String = "camera callback"
    ) -> RinkLensOCRFrameLease? {
        guard isPassCurrent(passToken) else { return nil }
        guard let ownedBuffer = RinkLensOCRFrameOwnership.makeOwnedCopy(of: pixelBuffer) else {
            lock.lock()
            diagnostics.ownedFrameCopyFailures &+= 1
            diagnostics.lastPhase = "owned-frame-copy-failed \(passToken.diagnosticText)"
            diagnostics.lastFinishReason = "owned-frame-copy-failed"
            lock.unlock()
            _ = finishPass(token: passToken, reason: "owned-frame-copy-failed")
            return nil
        }
        lock.lock()
        diagnostics.ownedFrameCopies &+= 1
        diagnostics.lastPhase = "owned-frame-copy-created \(passToken.diagnosticText)"
        lock.unlock()
        return RinkLensOCRFrameLease(
            pixelBuffer: ownedBuffer,
            generation: generation,
            submittedAt: CFAbsoluteTimeGetCurrent(),
            sourceSequence: sourceSequence,
            captureGeneration: captureGeneration,
            sourceDescription: "\(sourceDescription); OCR-owned deep copy",
            passToken: passToken,
            orchestrationGeneration: passToken.orchestrationGeneration
        )
    }

    // Recovery AI: continuous scoreboard ingress has already moved the frame into
    // one processing-owned buffer before any MainActor scheduling. Adopt that
    // buffer directly so the OCR engine does not perform a second 1080p copy.
    func makeFrameLeaseAdoptingOwnedBuffer(
        pixelBuffer: CVPixelBuffer,
        generation: Int,
        passToken: RinkLensOCRPassToken,
        sourceSequence: Int? = nil,
        captureGeneration: Int = 0,
        sourceDescription: String = "bounded scoreboard ingress"
    ) -> RinkLensOCRFrameLease? {
        guard isPassCurrent(passToken) else { return nil }
        lock.lock()
        diagnostics.lastPhase = "ingress-owned-frame-adopted \(passToken.diagnosticText)"
        lock.unlock()
        return RinkLensOCRFrameLease(
            pixelBuffer: pixelBuffer,
            generation: generation,
            submittedAt: CFAbsoluteTimeGetCurrent(),
            sourceSequence: sourceSequence,
            captureGeneration: captureGeneration,
            sourceDescription: "\(sourceDescription); ingress-owned buffer adopted without recopy",
            passToken: passToken,
            orchestrationGeneration: passToken.orchestrationGeneration
        )
    }

    func tryBeginPass(
        purpose: String,
        requestedKeys: Set<OCRRegionKey> = []
    ) -> RinkLensOCRPassToken? {
        beginPass(purpose: purpose, requestedKeys: requestedKeys, isTestPass: false)
    }

    func tryBeginTestPass(
        requestedKeys: Set<OCRRegionKey>
    ) -> RinkLensOCRPassToken? {
        beginPass(purpose: "selected-zone-test", requestedKeys: requestedKeys, isTestPass: true)
    }

    private func beginPass(
        purpose: String,
        requestedKeys: Set<OCRRegionKey>,
        isTestPass: Bool
    ) -> RinkLensOCRPassToken? {
        lock.lock()
        defer { lock.unlock() }
        repairInvariantLocked(reason: "begin-pass")
        guard activePassToken == nil, executorPassToken == nil else {
            diagnostics.droppedPasses &+= 1
            diagnostics.lastPhase = isTestPass ? "test-dropped-current-pass-busy" : "dropped-current-pass-busy"
            diagnostics.lastPurpose = purpose
            return nil
        }

        nextPassID &+= 1
        let token = RinkLensOCRPassToken(id: nextPassID, orchestrationGeneration: cancellationGeneration)
        activePassToken = token
        diagnostics.isBusy = true
        diagnostics.activePassID = token.id
        diagnostics.activePassStartedUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        diagnostics.submittedPasses &+= 1
        if isTestPass { diagnostics.selectedZonePasses &+= 1 }
        diagnostics.lastPurpose = purpose
        diagnostics.lastPhase = isTestPass ? "test-token-acquired \(token.diagnosticText)" : "accepted \(token.diagnosticText)"
        diagnostics.lastRequestedKeys = requestedKeys.map(\.rawValue).sorted()
        diagnostics.activeProcessorStage = RinkLensOCRProcessingStage.fieldSetup.rawValue
        diagnostics.activeProcessorStageStartedUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        diagnostics.stalledPassID = nil
        diagnostics.stalledProcessorStage = nil
        diagnostics.activeWorkerID = Int(token.id & 0x7FFF_FFFF)
        return token
    }

    func isPassCurrent(_ token: RinkLensOCRPassToken) -> Bool {
        lock.lock()
        let current = activePassToken == token && token.orchestrationGeneration == cancellationGeneration
        lock.unlock()
        return current
    }

    @discardableResult
    func finishPass(
        token: RinkLensOCRPassToken,
        reason: String,
        elapsedSeconds: CFTimeInterval? = nil
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard activePassToken == token else {
            // A cancelled pass may finish after a newer pass has started. Record
            // the late finish without touching the newer pass or its executor.
            if executorPassToken == token {
                executorPassToken = nil
            }
            diagnostics.ignoredLateFinishes &+= 1
            diagnostics.lastFinishReason = "ignored-late: \(reason)"
            diagnostics.lastFinishUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
            repairInvariantLocked(reason: "late-finish")
            return false
        }

        activePassToken = nil
        if executorPassToken == token { executorPassToken = nil }
        diagnostics.completedPasses &+= 1
        diagnostics.lastPhase = reason
        diagnostics.lastFinishReason = reason
        diagnostics.lastFinishUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        if let elapsedSeconds { diagnostics.lastDurationSeconds = elapsedSeconds }
        clearActiveDiagnosticsLocked()
        return true
    }

    /// Logical cancellation is synchronous. It never waits for a worker to drain.
    /// A stale task is fenced by generation/token checks and cannot mutate state.
    func cancelAll(reason: String) {
        lock.lock()
        let hadWork = activePassToken != nil || executorPassToken != nil
        cancellationGeneration &+= 1
        if hadWork { diagnostics.cancelledPasses &+= 1 }
        activePassToken = nil
        executorPassToken = nil
        diagnostics.lastPurpose = "cancelled"
        diagnostics.lastPhase = "cancelled-released"
        diagnostics.lastFinishReason = "cancelled: \(reason)"
        diagnostics.lastFinishUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        diagnostics.lastResetReason = reason
        clearActiveDiagnosticsLocked()
        lock.unlock()
    }

    /// Cancels a current pass once its real pass age exceeds the budget. Unlike
    /// Build 498/499 this is a state repair, not a diagnostic-only report.
    @discardableResult
    func recoverStalledPass(maximumAge: TimeInterval, reason: String) -> Bool {
        let maximumNanoseconds = UInt64(max(0.1, maximumAge) * 1_000_000_000)
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        guard let token = activePassToken,
              let started = diagnostics.activePassStartedUptimeNanoseconds,
              now >= started,
              now - started >= maximumNanoseconds else {
            lock.unlock()
            return false
        }
        diagnostics.deadlineExceededPasses &+= 1
        diagnostics.stallRecoveries &+= 1
        diagnostics.stalledPassID = token.id
        diagnostics.stalledProcessorStage = diagnostics.activeProcessorStage
        cancellationGeneration &+= 1
        activePassToken = nil
        executorPassToken = nil
        diagnostics.lastPurpose = "deadline-recovered"
        diagnostics.lastPhase = "deadline-recovered-released \(token.diagnosticText)"
        diagnostics.lastFinishReason = reason
        diagnostics.lastFinishUptimeNanoseconds = now
        diagnostics.lastResetReason = reason
        clearActiveDiagnosticsLocked(preserveStallEvidence: true)
        lock.unlock()
        return true
    }

    func reset(reason: String) {
        cancelAll(reason: reason)
    }

    private func markExecutorSubmitted(for token: RinkLensOCRPassToken) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        repairInvariantLocked(reason: "submit")
        guard activePassToken == token,
              token.orchestrationGeneration == cancellationGeneration,
              executorPassToken == nil else { return false }
        executorPassToken = token
        diagnostics.executorWorkInFlight = true
        diagnostics.isBusy = true
        return true
    }

    func analyzeFrame(
        frame: RinkLensOCRFrameLease,
        layout: ScoreboardOCRLayout,
        boardCalibration: BoardCalibrationQuad,
        motionKeys: Set<OCRRegionKey>,
        hashKeys: Set<OCRRegionKey>,
        deviceOrientation: UIDeviceOrientation,
        previewSize: CGSize,
        previewRotationDegrees: CGFloat,
        completion: @escaping @MainActor @Sendable (RinkLensOCRFrameAnalysis) -> Void
    ) {
        guard markExecutorSubmitted(for: frame.passToken) else {
            recordRejectedSubmission(token: frame.passToken, phase: "hash-submit-rejected", purpose: "continuous")
            return
        }
        let work = HashWork(
            frame: frame,
            layout: layout,
            boardCalibration: boardCalibration,
            motionKeys: motionKeys,
            hashKeys: hashKeys,
            deviceOrientation: deviceOrientation,
            previewSize: previewSize,
            previewRotationDegrees: previewRotationDegrees
        )

        DispatchQueue.global(qos: .utility).async {
            guard self.isLeaseCurrent(work.frame) else {
                self.releaseStaleExecutor(token: work.frame.passToken, phase: "hash-cancelled-before-start")
                return
            }
            let processor = ScoreboardOCRProcessor()
            let startedAt = CFAbsoluteTimeGetCurrent()
            // UX16d7 rectifies the scoreboard once for the union of motion and
            // scheduler-watch fields, then splits the returned signatures. The
            // previous two-pass call duplicated perspective correction work.
            let allKeys = work.motionKeys.union(work.hashKeys)
            let allHashes = processor.regionVisualHashes(
                from: work.frame.pixelBuffer,
                layout: work.layout,
                boardCalibration: work.boardCalibration,
                keys: allKeys,
                deviceOrientation: work.deviceOrientation,
                previewSize: work.previewSize,
                previewRotationDegrees: work.previewRotationDegrees
            )
            let motionHashes = allHashes.filter { work.motionKeys.contains($0.key) }
            let hashes = allHashes.filter { work.hashKeys.contains($0.key) }
            let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
            guard self.isLeaseCurrent(work.frame) else {
                self.releaseStaleExecutor(token: work.frame.passToken, phase: "hash-cancelled-after-work")
                return
            }
            self.recordPhase(
                token: work.frame.passToken,
                phase: "hash-complete",
                purpose: "continuous",
                elapsed: elapsed,
                keys: work.hashKeys.union(work.motionKeys),
                incrementHash: true,
                incrementRecognition: false
            )
            self.releaseExecutorForCompletion(token: work.frame.passToken)
            let result = RinkLensOCRFrameAnalysis(
                frame: work.frame,
                hashes: hashes,
                motionHashes: motionHashes,
                elapsedSeconds: elapsed
            )
            Task { @MainActor in completion(result) }
        }
    }

    func recognize(
        frame: RinkLensOCRFrameLease,
        layout: ScoreboardOCRLayout,
        boardCalibration: BoardCalibrationQuad,
        scoreboardTemplate: RinkScoreboardTemplate?,
        thresholds: OCRThresholds,
        colourProfiles: OCRColourProfileSet,
        previewSize: CGSize,
        previewRotationDegrees: CGFloat,
        enableSegmentedFallback: Bool,
        keysToProcess: Set<OCRRegionKey>,
        processorAllowedKeys: Set<OCRRegionKey>,
        includePipelineDiagnostics: Bool,
        executionPolicy: RinkLensOCRExecutionPolicy,
        maximumProcessingSeconds: TimeInterval,
        purpose: String,
        completion: @escaping @MainActor @Sendable (RinkLensOCRRecognitionResult) -> Void
    ) {
        guard markExecutorSubmitted(for: frame.passToken) else {
            recordRejectedSubmission(token: frame.passToken, phase: "recognition-submit-rejected", purpose: purpose)
            return
        }
        let work = RecognitionWork(
            frame: frame,
            layout: layout,
            boardCalibration: boardCalibration,
            scoreboardTemplate: scoreboardTemplate,
            thresholds: thresholds,
            colourProfiles: colourProfiles,
            previewSize: previewSize,
            previewRotationDegrees: previewRotationDegrees,
            enableSegmentedFallback: enableSegmentedFallback,
            keysToProcess: keysToProcess,
            processorAllowedKeys: processorAllowedKeys,
            includePipelineDiagnostics: includePipelineDiagnostics,
            executionPolicy: executionPolicy,
            maximumProcessingSeconds: maximumProcessingSeconds,
            purpose: purpose
        )

        DispatchQueue.global(qos: .utility).async {
            guard self.isLeaseCurrent(work.frame) else {
                self.releaseStaleExecutor(token: work.frame.passToken, phase: "recognition-cancelled-before-start")
                return
            }
            let processor = ScoreboardOCRProcessor()
            let startedAt = CFAbsoluteTimeGetCurrent()
            let parsed = processor.parseScoreboard(
                from: work.frame.pixelBuffer,
                layout: work.layout,
                boardCalibration: work.boardCalibration,
                scoreboardTemplate: work.scoreboardTemplate,
                thresholds: work.thresholds,
                colourProfiles: work.colourProfiles,
                deviceOrientation: .landscapeLeft,
                previewSize: work.previewSize,
                previewRotationDegrees: work.previewRotationDegrees,
                enableSegmentedFallback: work.enableSegmentedFallback,
                keysToProcess: work.keysToProcess,
                processorAllowedKeys: work.processorAllowedKeys,
                includePipelineDiagnostics: work.includePipelineDiagnostics,
                executionPolicy: work.executionPolicy,
                maximumProcessingSeconds: work.maximumProcessingSeconds,
                sourceFrameID: work.frame.sourceSequence,
                captureGeneration: work.frame.captureGeneration,
                stageObserver: { stage, key in
                    self.recordProcessorStage(token: work.frame.passToken, stage: stage, key: key)
                }
            )
            let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
            guard self.isLeaseCurrent(work.frame) else {
                self.releaseStaleExecutor(token: work.frame.passToken, phase: "recognition-cancelled-after-work")
                return
            }
            let output = parsed.map {
                RinkLensOCRRecognitionOutput(state: $0.state, rawText: $0.rawText, fieldDebug: $0.fieldDebug)
            }
            self.recordPhase(
                token: work.frame.passToken,
                phase: output == nil ? "recognition-empty" : "recognition-complete",
                purpose: work.purpose,
                elapsed: elapsed,
                keys: work.keysToProcess,
                incrementHash: false,
                incrementRecognition: true
            )
            self.releaseExecutorForCompletion(token: work.frame.passToken)
            let result = RinkLensOCRRecognitionResult(
                generation: work.frame.generation,
                passToken: work.frame.passToken,
                output: output,
                elapsedSeconds: elapsed,
                requestedKeys: work.keysToProcess,
                purpose: work.purpose
            )
            Task { @MainActor in completion(result) }
        }
    }

    func snapshot() -> RinkLensOCROrchestrationSnapshot {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        repairInvariantLocked(reason: "snapshot")
        let value = diagnostics
        lock.unlock()

        let activeAge = value.activePassStartedUptimeNanoseconds.map {
            now >= $0 ? Double(now - $0) / 1_000_000_000 : 0
        }
        let finishAge = value.lastFinishUptimeNanoseconds.map {
            now >= $0 ? Double(now - $0) / 1_000_000_000 : 0
        }
        let stageAge = value.activeProcessorStageStartedUptimeNanoseconds.map {
            now >= $0 ? Double(now - $0) / 1_000_000_000 : 0
        }
        return RinkLensOCROrchestrationSnapshot(
            isBusy: value.isBusy,
            submittedPasses: value.submittedPasses,
            completedPasses: value.completedPasses,
            droppedPasses: value.droppedPasses,
            hashPasses: value.hashPasses,
            recognitionPasses: value.recognitionPasses,
            selectedZonePasses: value.selectedZonePasses,
            lastPurpose: value.lastPurpose,
            lastPhase: value.lastPhase,
            lastDurationSeconds: value.lastDurationSeconds,
            lastRequestedKeys: value.lastRequestedKeys,
            lastResetReason: value.lastResetReason,
            activePassID: value.activePassID,
            activePassAgeSeconds: activeAge,
            lastFinishAgeSeconds: finishAge,
            lastFinishReason: value.lastFinishReason,
            cancelledPasses: value.cancelledPasses,
            ignoredLateFinishes: value.ignoredLateFinishes,
            stallRecoveries: value.stallRecoveries,
            activeWorkerID: value.activeWorkerID,
            workerRotations: value.workerRotations,
            ownedFrameCopies: value.ownedFrameCopies,
            ownedFrameCopyFailures: value.ownedFrameCopyFailures,
            deadlineExceededPasses: value.deadlineExceededPasses,
            executorWorkInFlight: value.executorWorkInFlight,
            activeProcessorStage: value.activeProcessorStage,
            activeProcessorStageAgeSeconds: stageAge,
            lastCompletedProcessorStage: value.lastCompletedProcessorStage,
            lastProcessorStageDurationSeconds: value.lastProcessorStageDurationSeconds,
            stalledProcessorStage: value.stalledProcessorStage,
            isStalled: RinkLensOCRRuntimeTruthPolicy.isStalled(
                executorWorkInFlight: value.executorWorkInFlight,
                activePassID: value.activePassID,
                stalledPassID: value.stalledPassID
            )
        )
    }

    private func isLeaseCurrent(_ frame: RinkLensOCRFrameLease) -> Bool {
        lock.lock()
        let current = frame.orchestrationGeneration == cancellationGeneration
            && activePassToken == frame.passToken
        lock.unlock()
        return current
    }

    private func releaseExecutorForCompletion(token: RinkLensOCRPassToken) {
        lock.lock()
        if executorPassToken == token {
            executorPassToken = nil
            diagnostics.executorWorkInFlight = false
        }
        diagnostics.isBusy = activePassToken != nil
        lock.unlock()
    }

    private func releaseStaleExecutor(token: RinkLensOCRPassToken, phase: String) {
        lock.lock()
        if executorPassToken == token {
            executorPassToken = nil
        }
        diagnostics.ignoredLateFinishes &+= 1
        diagnostics.lastFinishReason = phase
        diagnostics.lastFinishUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        repairInvariantLocked(reason: "stale-executor-finish")
        lock.unlock()
    }

    private func recordRejectedSubmission(
        token: RinkLensOCRPassToken,
        phase: String,
        purpose: String
    ) {
        lock.lock()
        guard activePassToken == token else {
            if executorPassToken == token { executorPassToken = nil }
            diagnostics.ignoredLateFinishes &+= 1
            diagnostics.lastFinishReason = "ignored-stale-submission: \(phase)"
            diagnostics.lastFinishUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
            repairInvariantLocked(reason: "stale-submission")
            lock.unlock()
            return
        }
        activePassToken = nil
        if executorPassToken == token { executorPassToken = nil }
        diagnostics.cancelledPasses &+= 1
        diagnostics.lastPhase = phase
        diagnostics.lastPurpose = purpose
        diagnostics.lastFinishReason = phase
        diagnostics.lastFinishUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        clearActiveDiagnosticsLocked()
        lock.unlock()
    }

    private func recordProcessorStage(
        token: RinkLensOCRPassToken,
        stage: RinkLensOCRProcessingStage,
        key: OCRRegionKey?
    ) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        defer { lock.unlock() }
        guard activePassToken == token else { return }
        if let started = diagnostics.activeProcessorStageStartedUptimeNanoseconds, now >= started {
            diagnostics.lastCompletedProcessorStage = diagnostics.activeProcessorStage
            diagnostics.lastProcessorStageDurationSeconds = Double(now - started) / 1_000_000_000
        }
        diagnostics.activeProcessorStage = key.map { "\(stage.rawValue):\($0.rawValue)" } ?? stage.rawValue
        diagnostics.activeProcessorStageStartedUptimeNanoseconds = now
        diagnostics.lastPhase = "processor-stage \(diagnostics.activeProcessorStage) \(token.diagnosticText)"
    }

    private func recordPhase(
        token: RinkLensOCRPassToken,
        phase: String,
        purpose: String,
        elapsed: CFTimeInterval,
        keys: Set<OCRRegionKey>,
        incrementHash: Bool,
        incrementRecognition: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard activePassToken == token else {
            diagnostics.ignoredLateFinishes &+= 1
            return
        }
        diagnostics.lastPhase = phase
        diagnostics.lastPurpose = purpose
        diagnostics.lastDurationSeconds = elapsed
        diagnostics.lastRequestedKeys = keys.map(\.rawValue).sorted()
        if incrementHash { diagnostics.hashPasses &+= 1 }
        if incrementRecognition { diagnostics.recognitionPasses &+= 1 }
    }

    private func clearActiveDiagnosticsLocked(preserveStallEvidence: Bool = false) {
        diagnostics.isBusy = false
        diagnostics.executorWorkInFlight = false
        diagnostics.activePassID = nil
        diagnostics.activePassStartedUptimeNanoseconds = nil
        diagnostics.activeProcessorStage = RinkLensOCRProcessingStage.idle.rawValue
        diagnostics.activeProcessorStageStartedUptimeNanoseconds = nil
        diagnostics.activeWorkerID = 0
        if !preserveStallEvidence {
            diagnostics.stalledPassID = nil
            diagnostics.stalledProcessorStage = nil
        }
    }

    /// Enforces the core invariant that no executor can remain owned when there is
    /// no active pass. This is the exact invalid state observed in Build 500.
    private func repairInvariantLocked(reason: String) {
        guard let active = activePassToken else {
            if executorPassToken != nil || diagnostics.executorWorkInFlight || diagnostics.isBusy {
                executorPassToken = nil
                diagnostics.executorWorkInFlight = false
                diagnostics.isBusy = false
                diagnostics.activePassID = nil
                diagnostics.activePassStartedUptimeNanoseconds = nil
                diagnostics.activeProcessorStage = RinkLensOCRProcessingStage.idle.rawValue
                diagnostics.activeProcessorStageStartedUptimeNanoseconds = nil
                diagnostics.lastPhase = "invariant-repaired-no-active-pass"
                diagnostics.lastResetReason = reason
                diagnostics.stallRecoveries &+= 1
            }
            return
        }

        // A late task from a cancelled generation must never own the executor of
        // the current pass. Clear only the mismatched executor token.
        if let executor = executorPassToken, executor != active {
            executorPassToken = nil
            diagnostics.lastFinishReason = "invariant-cleared-stale-executor"
            diagnostics.lastFinishUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
            diagnostics.stallRecoveries &+= 1
        }
        diagnostics.isBusy = true
        diagnostics.activePassID = active.id
        diagnostics.executorWorkInFlight = executorPassToken == active
    }
}

/// Public UX16d4 authority name. This is an alias, not a second owner.
typealias RinkLensOCREngine = RinkLensOCROrchestrationEngine

#endif
