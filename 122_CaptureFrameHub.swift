// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation
@preconcurrency import CoreVideo

// MARK: - UX16c43 bounded pixel-buffer FrameHub

/// Stable camera-stream roles used by frame consumers. Capture owns production;
/// consumers ask for the newest frame for a role and never retain a queue of
/// historical capture callbacks.
nonisolated enum RinkLensFrameRole: String, Sendable, Hashable, CaseIterable {
    case broadcast
    case ocr

    var displayName: String {
        switch self {
        case .broadcast: return "Broadcast"
        case .ocr: return "OCR"
        }
    }
}

/// Capacity-one application-owned pixel-buffer payload retained by `RinkLensFrameHub`.
///
/// Recovery AR / RL-095 restores the physical ownership contract: CaptureEngine
/// invokes `publish(...)` synchronously from the AVFoundation callback, which copies
/// the camera buffer exactly once into this prewarmed application-owned pool before
/// any consumer receives pixels. Recording, OCR, preview and diagnostics may share
/// the resulting owned lease; the originating AVFoundation buffer may not escape.
nonisolated final class RinkLensFrameHubOwnedLease: @unchecked Sendable {
    let id: UInt64
    let pixelBuffer: CVPixelBuffer
    let createdUptimeNanoseconds: UInt64
    private let onReader: @Sendable (UInt64, String) -> Void
    private let onRelease: @Sendable (UInt64, UInt64) -> Void

    init(
        id: UInt64,
        pixelBuffer: CVPixelBuffer,
        createdUptimeNanoseconds: UInt64,
        onReader: @escaping @Sendable (UInt64, String) -> Void,
        onRelease: @escaping @Sendable (UInt64, UInt64) -> Void
    ) {
        self.id = id
        self.pixelBuffer = pixelBuffer
        self.createdUptimeNanoseconds = createdUptimeNanoseconds
        self.onReader = onReader
        self.onRelease = onRelease
    }

    func noteReader(_ consumer: String) {
        onReader(id, consumer)
    }

    deinit {
        onRelease(id, DispatchTime.now().uptimeNanoseconds)
    }
}

nonisolated struct RinkLensFrameHubFrame: @unchecked Sendable {
    let role: RinkLensFrameRole
    private let ownedLease: RinkLensFrameHubOwnedLease
    var pixelBuffer: CVPixelBuffer { ownedLease.pixelBuffer }
    let capturedAt: Date
    let capturedUptimeNanoseconds: UInt64
    let sequence: Int
    let width: Int
    let height: Int
    let pixelFormat: OSType
    let source: String
    let physicalDeviceID: String?
    let captureGeneration: Int

    init(
        role: RinkLensFrameRole,
        ownedLease: RinkLensFrameHubOwnedLease,
        capturedAt: Date,
        capturedUptimeNanoseconds: UInt64,
        sequence: Int,
        width: Int,
        height: Int,
        pixelFormat: OSType,
        source: String,
        physicalDeviceID: String?,
        captureGeneration: Int
    ) {
        self.role = role
        self.ownedLease = ownedLease
        self.capturedAt = capturedAt
        self.capturedUptimeNanoseconds = capturedUptimeNanoseconds
        self.sequence = sequence
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.source = source
        self.physicalDeviceID = physicalDeviceID
        self.captureGeneration = captureGeneration
    }

    var ageSeconds: TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= capturedUptimeNanoseconds else { return 0 }
        return Double(now - capturedUptimeNanoseconds) / 1_000_000_000
    }

    var sizeText: String { "\(width)x\(height)" }

    /// Recovery AC / RL-061: control-plane callers must not retain an owned
    /// CVPixelBuffer merely to prove sequence/generation/device freshness.
    /// This projection contains only immutable value evidence and therefore
    /// cannot extend the lifetime of the six-surface FrameHub pool.
    var evidence: RinkLensFrameHubEvidence {
        RinkLensFrameHubEvidence(
            role: role,
            capturedAt: capturedAt,
            capturedUptimeNanoseconds: capturedUptimeNanoseconds,
            sequence: sequence,
            width: width,
            height: height,
            pixelFormat: pixelFormat,
            source: source,
            physicalDeviceID: physicalDeviceID,
            captureGeneration: captureGeneration
        )
    }

    func noteReader(_ consumer: String) {
        ownedLease.noteReader(consumer)
    }

    var recordingSnapshot: RecordingCameraPixelBufferSnapshot {
        RecordingCameraPixelBufferSnapshot(
            pixelBuffer: pixelBuffer,
            capturedAt: capturedAt,
            sequence: sequence,
            width: width,
            height: height
        )
    }
}

/// Immutable non-pixel proof of one FrameHub publication.
///
/// Recovery AC / RL-061 separates control-plane freshness acknowledgement from
/// pixel ownership. Sequence, generation, device and monotonic capture time may
/// cross async suspension boundaries; the owned CVPixelBuffer may not.
nonisolated struct RinkLensFrameHubEvidence: Sendable, Equatable {
    let role: RinkLensFrameRole
    let capturedAt: Date
    let capturedUptimeNanoseconds: UInt64
    let sequence: Int
    let width: Int
    let height: Int
    let pixelFormat: OSType
    let source: String
    let physicalDeviceID: String?
    let captureGeneration: Int

    var ageSeconds: TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= capturedUptimeNanoseconds else { return 0 }
        return Double(now - capturedUptimeNanoseconds) / 1_000_000_000
    }

    var sizeText: String { "\(width)x\(height)" }
}

nonisolated struct RinkLensFrameHubRoleSnapshot: Sendable, Equatable {
    let role: RinkLensFrameRole
    let sequence: Int
    let publishedCount: Int
    let replacementCount: Int
    let ownedCopyCount: Int
    let ownedCopyDropCount: Int
    let ownedPoolRebuildCount: Int
    let ownedCopyLastMilliseconds: Double
    let ownedCopyMaxMilliseconds: Double
    let ownedPoolAcquireLastMilliseconds: Double
    let ownedPoolAcquireMaxMilliseconds: Double
    let ownedPixelCopyLastMilliseconds: Double
    let ownedPixelCopyMaxMilliseconds: Double
    let ownedAttachmentPropagationLastMilliseconds: Double
    let ownedAttachmentPropagationMaxMilliseconds: Double
    let ownedSlowCopyCount: Int
    let ownedCopyMaxBreakdown: String
    let activeOwnedLeaseCount: Int
    let ownedLeaseReleaseCount: Int
    let ownedLeaseMaxLifetimeMilliseconds: Double
    let ownedLeaseMaxLifetimeSummary: String
    let activeOwnedLeaseSummary: String
    let ownedCopyDropLastLeaseSummary: String
    let ownedPrewarmBufferCount: Int
    let ownedPrewarmLastMilliseconds: Double
    let ownedPrewarmMaxMilliseconds: Double
    let readCount: Int
    let staleRejectCount: Int
    let generationRejectCount: Int
    let deviceRejectCount: Int
    let waiterCount: Int
    let waiterSuccessCount: Int
    let waiterTimeoutCount: Int
    let ageSeconds: TimeInterval?
    let sizeText: String
    let source: String
    let physicalDeviceID: String?
    let captureGeneration: Int
    let lastClearReason: String

    var diagnosticText: String {
        let ageText = ageSeconds.map { String(format: "%.2fs", $0) } ?? "--"
        return "role=\(role.rawValue) latest=#\(sequence) \(sizeText) age=\(ageText) "
            + "published=\(publishedCount) replaced=\(replacementCount) ownedCopies=\(ownedCopyCount) "
            + "ownedCopyDrops=\(ownedCopyDropCount) poolRebuilds=\(ownedPoolRebuildCount) "
            + "copyMs=\(String(format: "%.3f", ownedCopyLastMilliseconds))/max:\(String(format: "%.3f", ownedCopyMaxMilliseconds)) "
            + "poolAcquireMs=\(String(format: "%.3f", ownedPoolAcquireLastMilliseconds))/max:\(String(format: "%.3f", ownedPoolAcquireMaxMilliseconds)) "
            + "pixelCopyMs=\(String(format: "%.3f", ownedPixelCopyLastMilliseconds))/max:\(String(format: "%.3f", ownedPixelCopyMaxMilliseconds)) "
            + "metadataMs=\(String(format: "%.3f", ownedAttachmentPropagationLastMilliseconds))/max:\(String(format: "%.3f", ownedAttachmentPropagationMaxMilliseconds)) "
            + "slowCopies=\(ownedSlowCopyCount) maxBreakdown={\(ownedCopyMaxBreakdown)} "
            + "captureBoundary=\(role == .broadcast ? "value-only-evidence" : "synchronous-app-owned-copy") "
            + "ownedLeases=\(activeOwnedLeaseCount) released=\(ownedLeaseReleaseCount) maxLeaseMs=\(String(format: "%.1f", ownedLeaseMaxLifetimeMilliseconds)) maxLease={\(ownedLeaseMaxLifetimeSummary)} activeLease={\(activeOwnedLeaseSummary)} saturation={\(ownedCopyDropLastLeaseSummary)} "
            + "prewarm=\(ownedPrewarmBufferCount)@\(String(format: "%.3f", ownedPrewarmLastMilliseconds))ms/max:\(String(format: "%.3f", ownedPrewarmMaxMilliseconds)) reads=\(readCount) "
            + "staleRejects=\(staleRejectCount) generationRejects=\(generationRejectCount) "
            + "deviceRejects=\(deviceRejectCount) waiters=\(waiterCount) "
            + "waitSuccess=\(waiterSuccessCount) waitTimeout=\(waiterTimeoutCount) "
            + "generation=\(captureGeneration) device=\(physicalDeviceID ?? "none") "
            + "source=\(source) clear=\(lastClearReason)"
    }
}


/// Recovery B capture-ingress ownership pool. AVFoundation callback buffers never enter
/// application state. Each role copies once into a small CVPixelBufferPool and
/// every downstream consumer shares that app-owned buffer. Allocation is bounded;
/// if consumers retain all owned buffers, the newest application frame is dropped
/// instead of blocking the capture callback or retaining AVFoundation pool memory.
nonisolated struct RinkLensFrameHubPixelCopyStageMetrics: Sendable, Equatable {
    let totalMilliseconds: Double
    let sourceLockMilliseconds: Double
    let destinationLockMilliseconds: Double
    let memoryCopyMilliseconds: Double
    let destinationUnlockMilliseconds: Double
    let sourceUnlockMilliseconds: Double
}

nonisolated struct RinkLensFrameHubOwnedCopyResult: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let totalMilliseconds: Double
    let poolAcquireMilliseconds: Double
    let pixelCopyMilliseconds: Double
    let sourceLockMilliseconds: Double
    let destinationLockMilliseconds: Double
    let memoryCopyMilliseconds: Double
    let destinationUnlockMilliseconds: Double
    let sourceUnlockMilliseconds: Double
    let attachmentPropagationMilliseconds: Double
    let residualMilliseconds: Double

    func breakdown(totalOverrideMilliseconds: Double? = nil) -> String {
        let total = totalOverrideMilliseconds ?? totalMilliseconds
        let stages: [(String, Double)] = [
            ("poolAcquire", poolAcquireMilliseconds),
            ("sourceLock", sourceLockMilliseconds),
            ("destinationLock", destinationLockMilliseconds),
            ("memoryCopy", memoryCopyMilliseconds),
            ("destinationUnlock", destinationUnlockMilliseconds),
            ("sourceUnlock", sourceUnlockMilliseconds),
            ("metadata", attachmentPropagationMilliseconds),
            ("residual", residualMilliseconds)
        ]
        let dominant = stages.max(by: { $0.1 < $1.1 }) ?? ("none", 0)
        return "total=\(String(format: "%.3f", total)) "
            + stages.map { "\($0.0)=\(String(format: "%.3f", $0.1))" }.joined(separator: " ")
            + " dominant=\(dominant.0):\(String(format: "%.3f", dominant.1))"
    }
}

nonisolated struct RinkLensFrameHubOwnedPoolMetrics: Sendable, Equatable {
    let rebuildCount: Int
    let prewarmBufferCount: Int
    let prewarmLastMilliseconds: Double
    let prewarmMaxMilliseconds: Double
}

nonisolated struct RinkLensFrameHubOwnedPoolPreparation: Sendable, Equatable {
    let preparedBufferCount: Int
    let elapsedMilliseconds: Double
    let rebuilt: Bool

    var diagnosticText: String {
        "prepared=\(preparedBufferCount) elapsedMs=\(String(format: "%.3f", elapsedMilliseconds)) rebuilt=\(rebuilt)"
    }
}

/// Recovery J/K/AR / RL-034/RL-095 real-time ingress pool.
///
/// `kCVPixelBufferPoolMinimumBufferCountKey` is a pool policy, not a guarantee that
/// all backing IOSurface pages have already been faulted in, so Recovery J prewarms
/// the existing six-buffer ceiling. Recovery K decomposes copy cost. Recovery AR
/// removes Recovery L's asynchronous raw-camera transfer owner: the copy is again
/// synchronous at CaptureEngine's callback boundary so no AVFoundation-owned pixel
/// buffer can outlive `captureOutput(...)`. The copy is performed only once and the
/// resulting application-owned lease is fanned out to all consumers.
nonisolated final class RinkLensFrameHubOwnedBufferPool: @unchecked Sendable {
    private let lock = NSLock()
    private let minimumBufferCount: Int
    private let allocationThreshold: Int
    private var pool: CVPixelBufferPool?
    private var width = 0
    private var height = 0
    private var pixelFormat: OSType = 0
    private var prewarmedForCurrentPool = false
    private var prewarmBufferCount = 0
    private var prewarmLastMilliseconds: Double = 0
    private var prewarmMaxMilliseconds: Double = 0
    private(set) var rebuildCount = 0

    init(minimumBufferCount: Int = 3, allocationThreshold: Int = 6) {
        self.minimumBufferCount = max(1, minimumBufferCount)
        self.allocationThreshold = max(self.minimumBufferCount, allocationThreshold)
    }

    func prepare(width: Int, height: Int, pixelFormat: OSType) -> RinkLensFrameHubOwnedPoolPreparation {
        let started = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let rebuildBefore = rebuildCount
        if pool == nil || self.width != width || self.height != height || self.pixelFormat != pixelFormat {
            rebuildPoolLocked(width: width, height: height, pixelFormat: pixelFormat)
        }
        guard let pool else {
            lock.unlock()
            return RinkLensFrameHubOwnedPoolPreparation(preparedBufferCount: 0, elapsedMilliseconds: 0, rebuilt: rebuildCount != rebuildBefore)
        }
        if prewarmedForCurrentPool {
            let elapsed = Self.elapsedMilliseconds(since: started)
            let count = prewarmBufferCount
            lock.unlock()
            return RinkLensFrameHubOwnedPoolPreparation(preparedBufferCount: count, elapsedMilliseconds: elapsed, rebuilt: rebuildCount != rebuildBefore)
        }

        let auxiliary: [CFString: Any] = [
            kCVPixelBufferPoolAllocationThresholdKey: allocationThreshold
        ]
        var warmBuffers: [CVPixelBuffer] = []
        warmBuffers.reserveCapacity(allocationThreshold)
        for _ in 0..<allocationThreshold {
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                kCFAllocatorDefault,
                pool,
                auxiliary as CFDictionary,
                &buffer
            )
            guard status == kCVReturnSuccess, let buffer else { break }
            Self.touchAllPages(of: buffer)
            warmBuffers.append(buffer)
        }
        // Keep every buffer retained until the complete bounded set has been
        // touched. Releasing the local array then returns those already-resident
        // surfaces to the CVPixelBufferPool for normal runtime reuse.
        let prepared = warmBuffers.count
        let elapsed = Self.elapsedMilliseconds(since: started)
        prewarmedForCurrentPool = prepared == allocationThreshold
        prewarmBufferCount = prepared
        prewarmLastMilliseconds = elapsed
        prewarmMaxMilliseconds = max(prewarmMaxMilliseconds, elapsed)
        lock.unlock()
        return RinkLensFrameHubOwnedPoolPreparation(
            preparedBufferCount: prepared,
            elapsedMilliseconds: elapsed,
            rebuilt: rebuildCount != rebuildBefore
        )
    }

    func makeOwnedCopy(of source: CVPixelBuffer) -> RinkLensFrameHubOwnedCopyResult? {
        let totalStarted = DispatchTime.now().uptimeNanoseconds
        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        let sourcePixelFormat = CVPixelBufferGetPixelFormatType(source)

        let acquireStarted = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        if pool == nil || width != sourceWidth || height != sourceHeight || pixelFormat != sourcePixelFormat {
            rebuildPoolLocked(width: sourceWidth, height: sourceHeight, pixelFormat: sourcePixelFormat)
        }
        guard let pool else {
            lock.unlock()
            return nil
        }
        let auxiliary: [CFString: Any] = [
            kCVPixelBufferPoolAllocationThresholdKey: allocationThreshold
        ]
        var destination: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            pool,
            auxiliary as CFDictionary,
            &destination
        )
        lock.unlock()
        let poolAcquireMilliseconds = Self.elapsedMilliseconds(since: acquireStarted)
        guard status == kCVReturnSuccess, let destination else { return nil }

        guard let pixelStages = Self.copyPixels(from: source, to: destination) else { return nil }
        let attachmentStarted = DispatchTime.now().uptimeNanoseconds
        // Recovery AG / RL-068: the FrameHub boundary must not inherit every
        // opaque Core Video attachment from an AVFoundation-owned source buffer.
        // The app consumes pixels plus explicit capture metadata; only the small
        // colour-description set required to interpret YUV consistently crosses
        // into the app-owned pool. Pool surfaces are reused, so absent keys are
        // actively removed to prevent stale colour metadata crossing devices.
        Self.copyRequiredImageMetadata(from: source, to: destination)
        let attachmentPropagationMilliseconds = Self.elapsedMilliseconds(since: attachmentStarted)
        let totalMilliseconds = Self.elapsedMilliseconds(since: totalStarted)
        let accountedMilliseconds = poolAcquireMilliseconds
            + pixelStages.totalMilliseconds
            + attachmentPropagationMilliseconds
        let residualMilliseconds = max(0, totalMilliseconds - accountedMilliseconds)
        return RinkLensFrameHubOwnedCopyResult(
            pixelBuffer: destination,
            totalMilliseconds: totalMilliseconds,
            poolAcquireMilliseconds: poolAcquireMilliseconds,
            pixelCopyMilliseconds: pixelStages.totalMilliseconds,
            sourceLockMilliseconds: pixelStages.sourceLockMilliseconds,
            destinationLockMilliseconds: pixelStages.destinationLockMilliseconds,
            memoryCopyMilliseconds: pixelStages.memoryCopyMilliseconds,
            destinationUnlockMilliseconds: pixelStages.destinationUnlockMilliseconds,
            sourceUnlockMilliseconds: pixelStages.sourceUnlockMilliseconds,
            attachmentPropagationMilliseconds: attachmentPropagationMilliseconds,
            residualMilliseconds: residualMilliseconds
        )
    }

    func currentMetrics() -> RinkLensFrameHubOwnedPoolMetrics {
        lock.lock(); defer { lock.unlock() }
        return RinkLensFrameHubOwnedPoolMetrics(
            rebuildCount: rebuildCount,
            prewarmBufferCount: prewarmBufferCount,
            prewarmLastMilliseconds: prewarmLastMilliseconds,
            prewarmMaxMilliseconds: prewarmMaxMilliseconds
        )
    }

    private func rebuildPoolLocked(width: Int, height: Int, pixelFormat: OSType) {
        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: minimumBufferCount
        ]
        let pixelAttributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var nextPool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            pixelAttributes as CFDictionary,
            &nextPool
        )
        guard status == kCVReturnSuccess, let nextPool else {
            pool = nil
            self.width = 0
            self.height = 0
            self.pixelFormat = 0
            prewarmedForCurrentPool = false
            prewarmBufferCount = 0
            return
        }
        pool = nextPool
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        prewarmedForCurrentPool = false
        prewarmBufferCount = 0
        rebuildCount &+= 1
    }

    private static func touchAllPages(of buffer: CVPixelBuffer) {
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let planeCount = CVPixelBufferGetPlaneCount(buffer)
        if planeCount > 0 {
            for plane in 0..<planeCount {
                guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
                let byteCount = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)
                base.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
            }
        } else if let base = CVPixelBufferGetBaseAddress(buffer) {
            let byteCount = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
            base.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        }
    }


    /// Recovery AG / RL-068 explicit AVFoundation -> application metadata boundary.
    /// Apple documents these image-buffer keys as the colour description needed
    /// for YUV/RGB interpretation. Everything else remains source-buffer owned.
    private static let requiredImageMetadataKeys: [CFString] = [
        kCVImageBufferYCbCrMatrixKey,
        kCVImageBufferColorPrimariesKey,
        kCVImageBufferTransferFunctionKey,
        kCVImageBufferICCProfileKey,
        kCVImageBufferChromaLocationTopFieldKey,
        kCVImageBufferChromaLocationBottomFieldKey
    ]

    private static func copyRequiredImageMetadata(
        from source: CVPixelBuffer,
        to destination: CVPixelBuffer
    ) {
        for key in requiredImageMetadataKeys {
            if let value = CVBufferCopyAttachment(source, key, nil) {
                CVBufferSetAttachment(destination, key, value, .shouldPropagate)
            } else {
                CVBufferRemoveAttachment(destination, key)
            }
        }
    }

    private static func copyPixels(
        from source: CVPixelBuffer,
        to destination: CVPixelBuffer
    ) -> RinkLensFrameHubPixelCopyStageMetrics? {
        let totalStarted = DispatchTime.now().uptimeNanoseconds

        let sourceLockStarted = DispatchTime.now().uptimeNanoseconds
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return nil }
        let sourceLockMilliseconds = elapsedMilliseconds(since: sourceLockStarted)

        let destinationLockStarted = DispatchTime.now().uptimeNanoseconds
        guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            return nil
        }
        let destinationLockMilliseconds = elapsedMilliseconds(since: destinationLockStarted)

        let memoryCopyStarted = DispatchTime.now().uptimeNanoseconds
        var success = true
        let sourcePlaneCount = CVPixelBufferGetPlaneCount(source)
        let destinationPlaneCount = CVPixelBufferGetPlaneCount(destination)
        if sourcePlaneCount > 0 || destinationPlaneCount > 0 {
            if sourcePlaneCount != destinationPlaneCount {
                success = false
            } else {
                for plane in 0..<sourcePlaneCount where success {
                    guard let sourceBase = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                          let destinationBase = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else {
                        success = false
                        break
                    }
                    let rows = min(CVPixelBufferGetHeightOfPlane(source, plane), CVPixelBufferGetHeightOfPlane(destination, plane))
                    let sourceBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                    let destinationBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
                    let bytesToCopy = min(sourceBytesPerRow, destinationBytesPerRow)
                    if sourceBytesPerRow == destinationBytesPerRow {
                        destinationBase.copyMemory(from: sourceBase, byteCount: sourceBytesPerRow * rows)
                    } else {
                        for row in 0..<rows {
                            destinationBase.advanced(by: row * destinationBytesPerRow).copyMemory(
                                from: sourceBase.advanced(by: row * sourceBytesPerRow),
                                byteCount: bytesToCopy
                            )
                        }
                    }
                }
            }
        } else if let sourceBase = CVPixelBufferGetBaseAddress(source),
                  let destinationBase = CVPixelBufferGetBaseAddress(destination) {
            let rows = min(CVPixelBufferGetHeight(source), CVPixelBufferGetHeight(destination))
            let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(source)
            let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(destination)
            let bytesToCopy = min(sourceBytesPerRow, destinationBytesPerRow)
            if sourceBytesPerRow == destinationBytesPerRow {
                destinationBase.copyMemory(from: sourceBase, byteCount: sourceBytesPerRow * rows)
            } else {
                for row in 0..<rows {
                    destinationBase.advanced(by: row * destinationBytesPerRow).copyMemory(
                        from: sourceBase.advanced(by: row * sourceBytesPerRow),
                        byteCount: bytesToCopy
                    )
                }
            }
        } else {
            success = false
        }
        let memoryCopyMilliseconds = elapsedMilliseconds(since: memoryCopyStarted)

        let destinationUnlockStarted = DispatchTime.now().uptimeNanoseconds
        CVPixelBufferUnlockBaseAddress(destination, [])
        let destinationUnlockMilliseconds = elapsedMilliseconds(since: destinationUnlockStarted)

        let sourceUnlockStarted = DispatchTime.now().uptimeNanoseconds
        CVPixelBufferUnlockBaseAddress(source, .readOnly)
        let sourceUnlockMilliseconds = elapsedMilliseconds(since: sourceUnlockStarted)

        guard success else { return nil }
        return RinkLensFrameHubPixelCopyStageMetrics(
            totalMilliseconds: elapsedMilliseconds(since: totalStarted),
            sourceLockMilliseconds: sourceLockMilliseconds,
            destinationLockMilliseconds: destinationLockMilliseconds,
            memoryCopyMilliseconds: memoryCopyMilliseconds,
            destinationUnlockMilliseconds: destinationUnlockMilliseconds,
            sourceUnlockMilliseconds: sourceUnlockMilliseconds
        )
    }

    private static func elapsedMilliseconds(since started: UInt64) -> Double {
        let completed = DispatchTime.now().uptimeNanoseconds
        guard completed >= started else { return 0 }
        return Double(completed - started) / 1_000_000.0
    }
}

nonisolated struct RinkLensFrameHubSnapshot: Sendable, Equatable {
    let broadcast: RinkLensFrameHubRoleSnapshot
    let ocr: RinkLensFrameHubRoleSnapshot
    let capturedAt: Date

    var diagnosticText: String {
        "broadcast={\(broadcast.diagnosticText)}; ocr={\(ocr.diagnosticText)}"
    }
}

/// Process-wide, capacity-one latest-frame exchange.
///
/// There is one slot per camera role and no sample-buffer queue. A slow OCR or
/// diagnostics consumer cannot accumulate capture callbacks. Test OCR can wait
/// for a matching fresh frame through a bounded monotonic waiter which is
/// completed by the next qualifying publish or by a DispatchTime deadline.
nonisolated final class RinkLensFrameHub: @unchecked Sendable {
    static let shared = RinkLensFrameHub()

    private struct Slot {
        var frame: RinkLensFrameHubFrame?
        /// Recovery AV: value-only freshness survives even when a role has no
        /// pixel consumer. Broadcast uses this on every camera callback.
        var evidence: RinkLensFrameHubEvidence?
        var nextSequence: Int = 0
        var publishedCount: Int = 0
        var replacementCount: Int = 0
        var ownedCopyCount: Int = 0
        var ownedCopyDropCount: Int = 0
        var ownedPoolRebuildCount: Int = 0
        var ownedCopyLastMilliseconds: Double = 0
        var ownedCopyMaxMilliseconds: Double = 0
        var ownedPoolAcquireLastMilliseconds: Double = 0
        var ownedPoolAcquireMaxMilliseconds: Double = 0
        var ownedPixelCopyLastMilliseconds: Double = 0
        var ownedPixelCopyMaxMilliseconds: Double = 0
        var ownedAttachmentPropagationLastMilliseconds: Double = 0
        var ownedAttachmentPropagationMaxMilliseconds: Double = 0
        var ownedSlowCopyCount: Int = 0
        var ownedCopyMaxBreakdown: String = "none"
        var activeOwnedLeaseCount: Int = 0
        var ownedLeaseReleaseCount: Int = 0
        var ownedLeaseMaxLifetimeMilliseconds: Double = 0
        var ownedLeaseMaxLifetimeSummary: String = "none"
        var ownedCopyDropLastLeaseSummary: String = "none"
        var readCount: Int = 0
        var staleRejectCount: Int = 0
        var generationRejectCount: Int = 0
        var deviceRejectCount: Int = 0
        var waiterSuccessCount: Int = 0
        var waiterTimeoutCount: Int = 0
        var lastClearReason: String = "never cleared"
    }

    private struct FreshFrameWaiter: @unchecked Sendable {
        let id: UInt64
        let role: RinkLensFrameRole
        let maximumAgeNanoseconds: UInt64
        let minimumSequenceExclusive: Int?
        let requiredCaptureGeneration: Int?
        let requiredPhysicalDeviceID: String?
        let completion: @Sendable (RinkLensFrameHubFrame?) -> Void
    }

    /// Recovery AC / RL-061: metadata-only waiters never receive a frame lease.
    private struct FreshFrameEvidenceWaiter: @unchecked Sendable {
        let id: UInt64
        let role: RinkLensFrameRole
        let maximumAgeNanoseconds: UInt64
        let minimumSequenceExclusive: Int?
        let requiredCaptureGeneration: Int?
        let requiredPhysicalDeviceID: String?
        let completion: @Sendable (RinkLensFrameHubEvidence?) -> Void
    }

    private struct ActiveOwnedLeaseRecord {
        let id: UInt64
        let sequence: Int
        let createdUptimeNanoseconds: UInt64
        var readers: [String: Int]
    }

    private let lock = NSLock()
    private let leaseReleaseQueue = DispatchQueue(
        label: "com.rinklens.framehub.lease-release",
        qos: .utility
    )
    private var nextOwnedLeaseID: UInt64 = 0
    private var activeOwnedLeases: [RinkLensFrameRole: [UInt64: ActiveOwnedLeaseRecord]] = [
        .broadcast: [:],
        .ocr: [:]
    ]
    private var slots: [RinkLensFrameRole: Slot] = [
        .broadcast: Slot(),
        .ocr: Slot()
    ]
    private var waiters: [UInt64: FreshFrameWaiter] = [:]
    private var evidenceWaiters: [UInt64: FreshFrameEvidenceWaiter] = [:]
    private var nextWaiterID: UInt64 = 0
    // Build 766 / RL-011: FrameHub remains the sole latest-frame owner. Each
    // camera role may bind one non-retaining delivery endpoint for continuous
    // processing. The endpoint receives the exact frame installed in the
    // capacity-one slot; it does not create a second frame cache or queue.
    private struct LatestFrameConsumer: @unchecked Sendable {
        let minimumIntervalNanoseconds: UInt64
        var lastDeliveredUptimeNanoseconds: UInt64
        let handler: @Sendable (RinkLensFrameHubFrame) -> Void
    }
    private var latestFrameConsumers: [RinkLensFrameRole: LatestFrameConsumer] = [:]

    // Recovery AO / RL-076: presentation learns that a new frame exists through
    // immutable evidence only. This does not export a pixel-buffer lease from the
    // capture publication path and therefore cannot become a second frame queue.
    // A visible presentation surface subsequently asks FrameHub for the newest
    // frame on its own bounded render lane.
    private struct LatestEvidenceConsumer: @unchecked Sendable {
        let token: UUID
        let minimumIntervalNanoseconds: UInt64
        var lastDeliveredUptimeNanoseconds: UInt64
        let handler: @Sendable (RinkLensFrameHubEvidence) -> Void
    }
    private var latestEvidenceConsumers: [RinkLensFrameRole: LatestEvidenceConsumer] = [:]
    private let ownedBufferPools: [RinkLensFrameRole: RinkLensFrameHubOwnedBufferPool] = [
        .broadcast: RinkLensFrameHubOwnedBufferPool(),
        .ocr: RinkLensFrameHubOwnedBufferPool()
    ]

    private init() {}

    /// Recovery J / RL-034: create and page-touch the role's bounded owned
    /// pixel buffers before real-time capture starts. This is intentionally
    /// synchronous on the caller's camera/session isolation domain, never on
    /// MainActor and never deferred until a video-output callback.
    @discardableResult
    func prepareOwnedPool(
        for role: RinkLensFrameRole,
        width: Int,
        height: Int,
        pixelFormat: OSType
    ) -> RinkLensFrameHubOwnedPoolPreparation? {
        guard let pool = ownedBufferPools[role] else { return nil }
        let preparation = pool.prepare(width: width, height: height, pixelFormat: pixelFormat)
        let metrics = pool.currentMetrics()
        lock.lock()
        var slot = slots[role] ?? Slot()
        slot.ownedPoolRebuildCount = metrics.rebuildCount
        slots[role] = slot
        lock.unlock()
        return preparation
    }


    /// Installs the one continuous-processing endpoint for a camera role.
    /// Passing nil removes the endpoint. A later installation replaces the
    /// previous endpoint rather than stacking observers or replaying frames.
    func setLatestFrameConsumer(
        for role: RinkLensFrameRole,
        minimumInterval: TimeInterval,
        _ consumer: (@Sendable (RinkLensFrameHubFrame) -> Void)?
    ) {
        lock.lock()
        if let consumer {
            latestFrameConsumers[role] = LatestFrameConsumer(
                minimumIntervalNanoseconds: Self.nanoseconds(for: max(0, minimumInterval)),
                lastDeliveredUptimeNanoseconds: 0,
                handler: consumer
            )
        } else {
            latestFrameConsumers.removeValue(forKey: role)
        }
        lock.unlock()
    }

    /// Recovery AO / RL-076: installs the single visible-presentation notifier
    /// for a camera role. The notifier receives value-only frame evidence, never
    /// the role's CVPixelBuffer lease. A token prevents a dismantled SwiftUI host
    /// from accidentally removing a newer replacement host.
    @discardableResult
    func installLatestEvidenceConsumer(
        for role: RinkLensFrameRole,
        minimumInterval: TimeInterval,
        _ consumer: @escaping @Sendable (RinkLensFrameHubEvidence) -> Void
    ) -> UUID {
        let token = UUID()
        lock.lock()
        latestEvidenceConsumers[role] = LatestEvidenceConsumer(
            token: token,
            minimumIntervalNanoseconds: Self.nanoseconds(for: max(0, minimumInterval)),
            lastDeliveredUptimeNanoseconds: 0,
            handler: consumer
        )
        lock.unlock()
        return token
    }

    func removeLatestEvidenceConsumer(for role: RinkLensFrameRole, token: UUID) {
        lock.lock()
        if latestEvidenceConsumers[role]?.token == token {
            latestEvidenceConsumers.removeValue(forKey: role)
        }
        lock.unlock()
    }

    /// Recovery AR physical ingress boundary. The camera-owned source is copied
    /// synchronously once into the role's prewarmed application-owned pool; only
    /// the returned owned lease may cross into recording/OCR/preview work. No raw
    /// callback buffer, callback queue or asynchronous source-transfer owner exists.
    @discardableResult
    func publish(
        pixelBuffer: CVPixelBuffer,
        role: RinkLensFrameRole,
        capturedAt: Date,
        capturedUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
        source: String,
        physicalDeviceID: String?,
        captureGeneration: Int = 0
    ) -> RinkLensFrameHubFrame? {
        let copyStartedUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        guard let pool = ownedBufferPools[role],
              let ownedCopy = pool.makeOwnedCopy(of: pixelBuffer) else {
            lock.lock()
            var slot = slots[role] ?? Slot()
            slot.ownedCopyDropCount &+= 1
            slot.ownedPoolRebuildCount = ownedBufferPools[role]?.currentMetrics().rebuildCount ?? slot.ownedPoolRebuildCount
            slot.ownedCopyDropLastLeaseSummary = activeLeaseSummaryLocked(for: role)
            slots[role] = slot
            lock.unlock()
            return nil
        }
        let copyCompletedUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        let copyMilliseconds = copyCompletedUptimeNanoseconds >= copyStartedUptimeNanoseconds
            ? Double(copyCompletedUptimeNanoseconds - copyStartedUptimeNanoseconds) / 1_000_000.0
            : ownedCopy.totalMilliseconds
        let ownedPixelBuffer = ownedCopy.pixelBuffer
        let width = CVPixelBufferGetWidth(ownedPixelBuffer)
        let height = CVPixelBufferGetHeight(ownedPixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(ownedPixelBuffer)

        var completions: [(@Sendable (RinkLensFrameHubFrame?) -> Void)] = []
        var evidenceCompletions: [(@Sendable (RinkLensFrameHubEvidence?) -> Void)] = []
        let frame: RinkLensFrameHubFrame
        let latestFrameConsumer: (@Sendable (RinkLensFrameHubFrame) -> Void)?
        let latestEvidenceConsumer: (@Sendable (RinkLensFrameHubEvidence) -> Void)?

        lock.lock()
        var slot = slots[role] ?? Slot()
        if slot.frame != nil {
            slot.frame = nil
            slot.replacementCount &+= 1
        }
        slot.nextSequence &+= 1
        slot.publishedCount &+= 1
        slot.ownedCopyCount &+= 1
        nextOwnedLeaseID &+= 1
        let ownedLeaseID = nextOwnedLeaseID
        let leaseCreatedAt = DispatchTime.now().uptimeNanoseconds
        activeOwnedLeases[role, default: [:]][ownedLeaseID] = ActiveOwnedLeaseRecord(
            id: ownedLeaseID,
            sequence: slot.nextSequence,
            createdUptimeNanoseconds: leaseCreatedAt,
            readers: [:]
        )
        slot.activeOwnedLeaseCount = activeOwnedLeases[role]?.count ?? 0
        slot.ownedPoolRebuildCount = ownedBufferPools[role]?.currentMetrics().rebuildCount ?? slot.ownedPoolRebuildCount
        slot.ownedCopyLastMilliseconds = copyMilliseconds
        if copyMilliseconds > slot.ownedCopyMaxMilliseconds {
            slot.ownedCopyMaxMilliseconds = copyMilliseconds
            slot.ownedCopyMaxBreakdown = ownedCopy.breakdown(totalOverrideMilliseconds: copyMilliseconds)
        }
        if copyMilliseconds > (1_000.0 / 60.0) {
            slot.ownedSlowCopyCount &+= 1
        }
        slot.ownedPoolAcquireLastMilliseconds = ownedCopy.poolAcquireMilliseconds
        slot.ownedPoolAcquireMaxMilliseconds = max(slot.ownedPoolAcquireMaxMilliseconds, ownedCopy.poolAcquireMilliseconds)
        slot.ownedPixelCopyLastMilliseconds = ownedCopy.pixelCopyMilliseconds
        slot.ownedPixelCopyMaxMilliseconds = max(slot.ownedPixelCopyMaxMilliseconds, ownedCopy.pixelCopyMilliseconds)
        slot.ownedAttachmentPropagationLastMilliseconds = ownedCopy.attachmentPropagationMilliseconds
        slot.ownedAttachmentPropagationMaxMilliseconds = max(
            slot.ownedAttachmentPropagationMaxMilliseconds,
            ownedCopy.attachmentPropagationMilliseconds
        )
        let ownedLease = RinkLensFrameHubOwnedLease(
            id: ownedLeaseID,
            pixelBuffer: ownedPixelBuffer,
            createdUptimeNanoseconds: leaseCreatedAt,
            onReader: { [weak self] leaseID, consumer in
                self?.noteOwnedLeaseReader(role: role, leaseID: leaseID, consumer: consumer)
            },
            onRelease: { [weak self] leaseID, releasedAt in
                self?.enqueueOwnedLeaseRelease(
                    role: role,
                    leaseID: leaseID,
                    releasedAtUptimeNanoseconds: releasedAt
                )
            }
        )
        frame = RinkLensFrameHubFrame(
            role: role,
            ownedLease: ownedLease,
            capturedAt: capturedAt,
            capturedUptimeNanoseconds: capturedUptimeNanoseconds,
            sequence: slot.nextSequence,
            width: width,
            height: height,
            pixelFormat: pixelFormat,
            source: source,
            physicalDeviceID: physicalDeviceID,
            captureGeneration: captureGeneration
        )
        slot.frame = frame
        slot.evidence = frame.evidence

        let matchingIDs = waiters.compactMap { id, waiter -> UInt64? in
            guard waiter.role == role,
                  frameMatches(
                    frame,
                    maximumAgeNanoseconds: waiter.maximumAgeNanoseconds,
                    minimumSequenceExclusive: waiter.minimumSequenceExclusive,
                    requiredCaptureGeneration: waiter.requiredCaptureGeneration,
                    requiredPhysicalDeviceID: waiter.requiredPhysicalDeviceID,
                    nowUptimeNanoseconds: capturedUptimeNanoseconds
                  ) else { return nil }
            return id
        }
        for id in matchingIDs {
            if let waiter = waiters.removeValue(forKey: id) {
                completions.append(waiter.completion)
                slot.waiterSuccessCount &+= 1
            }
        }
        let matchingEvidenceIDs = evidenceWaiters.compactMap { id, waiter -> UInt64? in
            guard waiter.role == role,
                  frameMatches(
                    frame,
                    maximumAgeNanoseconds: waiter.maximumAgeNanoseconds,
                    minimumSequenceExclusive: waiter.minimumSequenceExclusive,
                    requiredCaptureGeneration: waiter.requiredCaptureGeneration,
                    requiredPhysicalDeviceID: waiter.requiredPhysicalDeviceID,
                    nowUptimeNanoseconds: capturedUptimeNanoseconds
                  ) else { return nil }
            return id
        }
        for id in matchingEvidenceIDs {
            if let waiter = evidenceWaiters.removeValue(forKey: id) {
                evidenceCompletions.append(waiter.completion)
                slot.waiterSuccessCount &+= 1
            }
        }
        slots[role] = slot
        if var consumer = latestFrameConsumers[role],
           capturedUptimeNanoseconds >= consumer.lastDeliveredUptimeNanoseconds,
           capturedUptimeNanoseconds - consumer.lastDeliveredUptimeNanoseconds >= consumer.minimumIntervalNanoseconds {
            consumer.lastDeliveredUptimeNanoseconds = capturedUptimeNanoseconds
            latestFrameConsumers[role] = consumer
            latestFrameConsumer = consumer.handler
        } else {
            latestFrameConsumer = nil
        }
        if var evidenceConsumer = latestEvidenceConsumers[role],
           capturedUptimeNanoseconds >= evidenceConsumer.lastDeliveredUptimeNanoseconds,
           capturedUptimeNanoseconds - evidenceConsumer.lastDeliveredUptimeNanoseconds >= evidenceConsumer.minimumIntervalNanoseconds {
            evidenceConsumer.lastDeliveredUptimeNanoseconds = capturedUptimeNanoseconds
            latestEvidenceConsumers[role] = evidenceConsumer
            latestEvidenceConsumer = evidenceConsumer.handler
        } else {
            latestEvidenceConsumer = nil
        }
        lock.unlock()

        if !completions.isEmpty { frame.noteReader("fresh-frame-waiter") }
        for completion in completions {
            completion(frame)
        }
        // Evidence waiters receive value-only proof. They deliberately do not
        // become FrameHub lease readers.
        let evidence = frame.evidence
        for completion in evidenceCompletions {
            completion(evidence)
        }
        latestEvidenceConsumer?(evidence)
        if latestFrameConsumer != nil { frame.noteReader("continuous-\(role.rawValue)-consumer") }
        latestFrameConsumer?(frame)
        return frame
    }

    /// Recovery AV Broadcast hot-path publication. This records sequence, size,
    /// generation, device and monotonic freshness without allocating or copying a
    /// CVPixelBuffer. It is safe for lifecycle/readiness/diagnostics and completes
    /// only evidence waiters/consumers. Pixel-bearing consumers remain OCR-only or
    /// must use the explicit pixel `publish(...)` API.
    @discardableResult
    func publishEvidence(
        pixelBuffer: CVPixelBuffer,
        role: RinkLensFrameRole,
        capturedAt: Date,
        capturedUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
        source: String,
        physicalDeviceID: String?,
        captureGeneration: Int = 0
    ) -> RinkLensFrameHubEvidence {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        var completions: [(@Sendable (RinkLensFrameHubEvidence?) -> Void)] = []
        let evidence: RinkLensFrameHubEvidence
        let latestEvidenceConsumer: (@Sendable (RinkLensFrameHubEvidence) -> Void)?

        lock.lock()
        var slot = slots[role] ?? Slot()
        if slot.evidence != nil { slot.replacementCount &+= 1 }
        // Recovery AV: Broadcast evidence publication must not leave a stale pixel
        // lease looking current after this role has moved to value-only ownership.
        // OCR still uses publish(...), so this only releases an obsolete frame when
        // a role explicitly enters evidence-only publication.
        slot.frame = nil
        slot.nextSequence &+= 1
        slot.publishedCount &+= 1
        evidence = RinkLensFrameHubEvidence(
            role: role,
            capturedAt: capturedAt,
            capturedUptimeNanoseconds: capturedUptimeNanoseconds,
            sequence: slot.nextSequence,
            width: width,
            height: height,
            pixelFormat: pixelFormat,
            source: source,
            physicalDeviceID: physicalDeviceID,
            captureGeneration: captureGeneration
        )
        slot.evidence = evidence

        let matchingEvidenceIDs = evidenceWaiters.compactMap { id, waiter -> UInt64? in
            guard waiter.role == role,
                  evidenceMatches(
                    evidence,
                    maximumAgeNanoseconds: waiter.maximumAgeNanoseconds,
                    minimumSequenceExclusive: waiter.minimumSequenceExclusive,
                    requiredCaptureGeneration: waiter.requiredCaptureGeneration,
                    requiredPhysicalDeviceID: waiter.requiredPhysicalDeviceID,
                    nowUptimeNanoseconds: capturedUptimeNanoseconds
                  ) else { return nil }
            return id
        }
        for id in matchingEvidenceIDs {
            if let waiter = evidenceWaiters.removeValue(forKey: id) {
                completions.append(waiter.completion)
                slot.waiterSuccessCount &+= 1
            }
        }
        slots[role] = slot
        if var consumer = latestEvidenceConsumers[role],
           capturedUptimeNanoseconds >= consumer.lastDeliveredUptimeNanoseconds,
           capturedUptimeNanoseconds - consumer.lastDeliveredUptimeNanoseconds >= consumer.minimumIntervalNanoseconds {
            consumer.lastDeliveredUptimeNanoseconds = capturedUptimeNanoseconds
            latestEvidenceConsumers[role] = consumer
            latestEvidenceConsumer = consumer.handler
        } else {
            latestEvidenceConsumer = nil
        }
        lock.unlock()

        for completion in completions { completion(evidence) }
        latestEvidenceConsumer?(evidence)
        return evidence
    }

    /// Returns the current frame only when it is fresh and matches the requested
    /// graph generation/device. A read never removes the frame.
    func latestFrame(
        for role: RinkLensFrameRole,
        maxAge: TimeInterval? = nil,
        requiredCaptureGeneration: Int? = nil,
        requiredPhysicalDeviceID: String? = nil,
        nowUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
        consumer: String = "latestFrame"
    ) -> RinkLensFrameHubFrame? {
        lock.lock()
        var slot = slots[role] ?? Slot()
        guard let frame = slot.frame else {
            slots[role] = slot
            lock.unlock()
            return nil
        }

        if let maxAge {
            let maximumAgeNanoseconds = Self.nanoseconds(for: maxAge)
            if !Self.isFresh(
                frame,
                maximumAgeNanoseconds: maximumAgeNanoseconds,
                nowUptimeNanoseconds: nowUptimeNanoseconds
            ) {
                slot.staleRejectCount &+= 1
                slots[role] = slot
                lock.unlock()
                return nil
            }
        }

        if let requiredCaptureGeneration,
           frame.captureGeneration != requiredCaptureGeneration {
            slot.generationRejectCount &+= 1
            slots[role] = slot
            lock.unlock()
            return nil
        }

        if let requiredPhysicalDeviceID,
           frame.physicalDeviceID != requiredPhysicalDeviceID {
            slot.deviceRejectCount &+= 1
            slots[role] = slot
            lock.unlock()
            return nil
        }

        slot.readCount &+= 1
        slots[role] = slot
        lock.unlock()
        frame.noteReader(consumer)
        return frame
    }

    /// Recovery AC / RL-061: returns only immutable freshness evidence. Unlike
    /// `latestFrame`, this API cannot export a CVPixelBuffer lease to a control
    /// path or across an async suspension boundary.
    func latestEvidence(
        for role: RinkLensFrameRole,
        maxAge: TimeInterval? = nil,
        requiredCaptureGeneration: Int? = nil,
        requiredPhysicalDeviceID: String? = nil,
        nowUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> RinkLensFrameHubEvidence? {
        lock.lock()
        var slot = slots[role] ?? Slot()
        guard let evidence = slot.evidence else {
            slots[role] = slot
            lock.unlock()
            return nil
        }

        if let maxAge {
            let maximumAgeNanoseconds = Self.nanoseconds(for: maxAge)
            if !Self.isFresh(
                evidence,
                maximumAgeNanoseconds: maximumAgeNanoseconds,
                nowUptimeNanoseconds: nowUptimeNanoseconds
            ) {
                slot.staleRejectCount &+= 1
                slots[role] = slot
                lock.unlock()
                return nil
            }
        }
        if let requiredCaptureGeneration,
           evidence.captureGeneration != requiredCaptureGeneration {
            slot.generationRejectCount &+= 1
            slots[role] = slot
            lock.unlock()
            return nil
        }
        if let requiredPhysicalDeviceID,
           evidence.physicalDeviceID != requiredPhysicalDeviceID {
            slot.deviceRejectCount &+= 1
            slots[role] = slot
            lock.unlock()
            return nil
        }
        slot.readCount &+= 1
        slots[role] = slot
        lock.unlock()
        return evidence
    }

    func hasFreshFrame(
        for role: RinkLensFrameRole,
        maxAge: TimeInterval,
        requiredCaptureGeneration: Int? = nil,
        requiredPhysicalDeviceID: String? = nil
    ) -> Bool {
        latestEvidence(
            for: role,
            maxAge: maxAge,
            requiredCaptureGeneration: requiredCaptureGeneration,
            requiredPhysicalDeviceID: requiredPhysicalDeviceID
        ) != nil
    }

    /// Waits for one current-generation, correct-device, fresh frame. This legacy
    /// pixel-bearing API is reserved for callers that actually need image data.
    func waitForFreshFrame(
        for role: RinkLensFrameRole,
        maxAge: TimeInterval,
        afterSequence minimumSequenceExclusive: Int? = nil,
        requiredCaptureGeneration: Int?,
        requiredPhysicalDeviceID: String?,
        timeout: TimeInterval
    ) async -> RinkLensFrameHubFrame? {
        if let current = latestFrame(
            for: role,
            maxAge: maxAge,
            requiredCaptureGeneration: requiredCaptureGeneration,
            requiredPhysicalDeviceID: requiredPhysicalDeviceID
        ), minimumSequenceExclusive.map({ current.sequence > $0 }) ?? true {
            return current
        }

        let maximumAgeNanoseconds = Self.nanoseconds(for: maxAge)
        let timeoutNanoseconds = Self.nanoseconds(for: timeout)

        return await withCheckedContinuation { continuation in
            let waiterID: UInt64
            var immediateFrame: RinkLensFrameHubFrame?

            lock.lock()
            nextWaiterID &+= 1
            waiterID = nextWaiterID

            let now = DispatchTime.now().uptimeNanoseconds
            if let frame = slots[role]?.frame,
               frameMatches(
                    frame,
                    maximumAgeNanoseconds: maximumAgeNanoseconds,
                    minimumSequenceExclusive: minimumSequenceExclusive,
                    requiredCaptureGeneration: requiredCaptureGeneration,
                    requiredPhysicalDeviceID: requiredPhysicalDeviceID,
                    nowUptimeNanoseconds: now
               ) {
                var slot = slots[role] ?? Slot()
                slot.readCount &+= 1
                slot.waiterSuccessCount &+= 1
                slots[role] = slot
                immediateFrame = frame
            } else {
                waiters[waiterID] = FreshFrameWaiter(
                    id: waiterID,
                    role: role,
                    maximumAgeNanoseconds: maximumAgeNanoseconds,
                    minimumSequenceExclusive: minimumSequenceExclusive,
                    requiredCaptureGeneration: requiredCaptureGeneration,
                    requiredPhysicalDeviceID: requiredPhysicalDeviceID,
                    completion: { frame in continuation.resume(returning: frame) }
                )
            }
            lock.unlock()

            if let immediateFrame {
                immediateFrame.noteReader("fresh-frame-waiter")
                continuation.resume(returning: immediateFrame)
                return
            }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + .nanoseconds(Int(min(timeoutNanoseconds, UInt64(Int.max))))
            ) { [weak self] in
                self?.timeoutWaiter(id: waiterID)
            }
        }
    }

    /// Recovery AC / RL-061: event-driven freshness acknowledgement without
    /// transferring ownership of an app-owned pixel buffer to the awaiting task.
    func waitForFreshFrameEvidence(
        for role: RinkLensFrameRole,
        maxAge: TimeInterval,
        afterSequence minimumSequenceExclusive: Int? = nil,
        requiredCaptureGeneration: Int?,
        requiredPhysicalDeviceID: String?,
        timeout: TimeInterval
    ) async -> RinkLensFrameHubEvidence? {
        if let current = latestEvidence(
            for: role,
            maxAge: maxAge,
            requiredCaptureGeneration: requiredCaptureGeneration,
            requiredPhysicalDeviceID: requiredPhysicalDeviceID
        ), minimumSequenceExclusive.map({ current.sequence > $0 }) ?? true {
            return current
        }

        let maximumAgeNanoseconds = Self.nanoseconds(for: maxAge)
        let timeoutNanoseconds = Self.nanoseconds(for: timeout)

        return await withCheckedContinuation { continuation in
            let waiterID: UInt64
            var immediateEvidence: RinkLensFrameHubEvidence?

            lock.lock()
            nextWaiterID &+= 1
            waiterID = nextWaiterID

            let now = DispatchTime.now().uptimeNanoseconds
            if let evidence = slots[role]?.evidence,
               evidenceMatches(
                    evidence,
                    maximumAgeNanoseconds: maximumAgeNanoseconds,
                    minimumSequenceExclusive: minimumSequenceExclusive,
                    requiredCaptureGeneration: requiredCaptureGeneration,
                    requiredPhysicalDeviceID: requiredPhysicalDeviceID,
                    nowUptimeNanoseconds: now
               ) {
                var slot = slots[role] ?? Slot()
                slot.readCount &+= 1
                slot.waiterSuccessCount &+= 1
                slots[role] = slot
                immediateEvidence = evidence
            } else {
                evidenceWaiters[waiterID] = FreshFrameEvidenceWaiter(
                    id: waiterID,
                    role: role,
                    maximumAgeNanoseconds: maximumAgeNanoseconds,
                    minimumSequenceExclusive: minimumSequenceExclusive,
                    requiredCaptureGeneration: requiredCaptureGeneration,
                    requiredPhysicalDeviceID: requiredPhysicalDeviceID,
                    completion: { evidence in continuation.resume(returning: evidence) }
                )
            }
            lock.unlock()

            if let immediateEvidence {
                continuation.resume(returning: immediateEvidence)
                return
            }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + .nanoseconds(Int(min(timeoutNanoseconds, UInt64(Int.max))))
            ) { [weak self] in
                self?.timeoutEvidenceWaiter(id: waiterID)
            }
        }
    }

    func latestPixelBufferSnapshot(
        for role: RinkLensFrameRole,
        maxAge: TimeInterval? = 0.35
    ) -> RecordingCameraPixelBufferSnapshot? {
        latestFrame(for: role, maxAge: maxAge)?.recordingSnapshot
    }

    func clear(role: RinkLensFrameRole, reason: String) {
        var completions: [(@Sendable (RinkLensFrameHubFrame?) -> Void)] = []
        var evidenceCompletions: [(@Sendable (RinkLensFrameHubEvidence?) -> Void)] = []
        lock.lock()
        var slot = slots[role] ?? Slot()
        slot.frame = nil
        slot.evidence = nil
        slot.lastClearReason = reason
        let matchingIDs = waiters.compactMap { id, waiter in waiter.role == role ? id : nil }
        for id in matchingIDs {
            if let waiter = waiters.removeValue(forKey: id) {
                completions.append(waiter.completion)
                slot.waiterTimeoutCount &+= 1
            }
        }
        let matchingEvidenceIDs = evidenceWaiters.compactMap { id, waiter in waiter.role == role ? id : nil }
        for id in matchingEvidenceIDs {
            if let waiter = evidenceWaiters.removeValue(forKey: id) {
                evidenceCompletions.append(waiter.completion)
                slot.waiterTimeoutCount &+= 1
            }
        }
        slots[role] = slot
        lock.unlock()
        for completion in completions { completion(nil) }
        for completion in evidenceCompletions { completion(nil) }
    }

    func clearAll(reason: String) {
        for role in RinkLensFrameRole.allCases {
            clear(role: role, reason: reason)
        }
    }

    func diagnosticSnapshot(
        nowUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> RinkLensFrameHubSnapshot {
        lock.lock()
        let broadcast = roleSnapshotLocked(for: .broadcast, nowUptimeNanoseconds: nowUptimeNanoseconds)
        let ocr = roleSnapshotLocked(for: .ocr, nowUptimeNanoseconds: nowUptimeNanoseconds)
        lock.unlock()
        return RinkLensFrameHubSnapshot(
            broadcast: broadcast,
            ocr: ocr,
            capturedAt: Date()
        )
    }

    /// Compatibility overload for existing diagnostics call sites. Frame age is
    /// calculated from monotonic uptime; the supplied wall-clock value is ignored.
    func diagnosticSnapshot(now: Date) -> RinkLensFrameHubSnapshot {
        _ = now
        return diagnosticSnapshot()
    }

    func diagnosticText(for role: RinkLensFrameRole, now: Date = Date()) -> String {
        _ = now
        let snapshot = diagnosticSnapshot()
        switch role {
        case .broadcast: return snapshot.broadcast.diagnosticText
        case .ocr: return snapshot.ocr.diagnosticText
        }
    }

    private func noteOwnedLeaseReader(role: RinkLensFrameRole, leaseID: UInt64, consumer: String) {
        lock.lock()
        if var record = activeOwnedLeases[role]?[leaseID] {
            record.readers[consumer, default: 0] &+= 1
            activeOwnedLeases[role]?[leaseID] = record
        }
        lock.unlock()
    }

    private func enqueueOwnedLeaseRelease(
        role: RinkLensFrameRole,
        leaseID: UInt64,
        releasedAtUptimeNanoseconds: UInt64
    ) {
        leaseReleaseQueue.async { [weak self] in
            self?.releaseOwnedLease(
                role: role,
                leaseID: leaseID,
                releasedAtUptimeNanoseconds: releasedAtUptimeNanoseconds
            )
        }
    }

    private func releaseOwnedLease(
        role: RinkLensFrameRole,
        leaseID: UInt64,
        releasedAtUptimeNanoseconds: UInt64
    ) {
        lock.lock()
        guard let record = activeOwnedLeases[role]?.removeValue(forKey: leaseID) else {
            lock.unlock()
            return
        }
        let lifetimeMilliseconds = releasedAtUptimeNanoseconds >= record.createdUptimeNanoseconds
            ? Double(releasedAtUptimeNanoseconds - record.createdUptimeNanoseconds) / 1_000_000.0
            : 0
        var slot = slots[role] ?? Slot()
        slot.activeOwnedLeaseCount = activeOwnedLeases[role]?.count ?? 0
        slot.ownedLeaseReleaseCount &+= 1
        if lifetimeMilliseconds > slot.ownedLeaseMaxLifetimeMilliseconds {
            slot.ownedLeaseMaxLifetimeMilliseconds = lifetimeMilliseconds
            let readers = record.readers.sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ",")
            slot.ownedLeaseMaxLifetimeSummary = "#\(record.sequence) lifetimeMs=\(String(format: "%.1f", lifetimeMilliseconds)) readers=[\(readers.isEmpty ? "none" : readers)]"
        }
        slots[role] = slot
        lock.unlock()
    }

    private func activeLeaseSummaryLocked(for role: RinkLensFrameRole) -> String {
        let records = activeOwnedLeases[role]?.values.sorted { $0.createdUptimeNanoseconds < $1.createdUptimeNanoseconds } ?? []
        guard !records.isEmpty else { return "none" }
        let now = DispatchTime.now().uptimeNanoseconds
        return records.prefix(6).map { record in
            let ageMs = now >= record.createdUptimeNanoseconds
                ? Double(now - record.createdUptimeNanoseconds) / 1_000_000.0
                : 0
            let readers = record.readers.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
            return "#\(record.sequence) ageMs=\(String(format: "%.1f", ageMs)) readers=[\(readers.isEmpty ? "none" : readers)]"
        }.joined(separator: " | ")
    }

    private func timeoutWaiter(id: UInt64) {
        var completion: (@Sendable (RinkLensFrameHubFrame?) -> Void)?
        lock.lock()
        if let waiter = waiters.removeValue(forKey: id) {
            var slot = slots[waiter.role] ?? Slot()
            slot.waiterTimeoutCount &+= 1
            slots[waiter.role] = slot
            completion = waiter.completion
        }
        lock.unlock()
        completion?(nil)
    }

    private func timeoutEvidenceWaiter(id: UInt64) {
        var completion: (@Sendable (RinkLensFrameHubEvidence?) -> Void)?
        lock.lock()
        if let waiter = evidenceWaiters.removeValue(forKey: id) {
            var slot = slots[waiter.role] ?? Slot()
            slot.waiterTimeoutCount &+= 1
            slots[waiter.role] = slot
            completion = waiter.completion
        }
        lock.unlock()
        completion?(nil)
    }

    private func roleSnapshotLocked(
        for role: RinkLensFrameRole,
        nowUptimeNanoseconds: UInt64
    ) -> RinkLensFrameHubRoleSnapshot {
        let slot = slots[role] ?? Slot()
        let evidence = slot.evidence
        let poolMetrics = ownedBufferPools[role]?.currentMetrics() ?? RinkLensFrameHubOwnedPoolMetrics(
            rebuildCount: slot.ownedPoolRebuildCount,
            prewarmBufferCount: 0,
            prewarmLastMilliseconds: 0,
            prewarmMaxMilliseconds: 0
        )
        return RinkLensFrameHubRoleSnapshot(
            role: role,
            sequence: evidence?.sequence ?? 0,
            publishedCount: slot.publishedCount,
            replacementCount: slot.replacementCount,
            ownedCopyCount: slot.ownedCopyCount,
            ownedCopyDropCount: slot.ownedCopyDropCount,
            ownedPoolRebuildCount: slot.ownedPoolRebuildCount,
            ownedCopyLastMilliseconds: slot.ownedCopyLastMilliseconds,
            ownedCopyMaxMilliseconds: slot.ownedCopyMaxMilliseconds,
            ownedPoolAcquireLastMilliseconds: slot.ownedPoolAcquireLastMilliseconds,
            ownedPoolAcquireMaxMilliseconds: slot.ownedPoolAcquireMaxMilliseconds,
            ownedPixelCopyLastMilliseconds: slot.ownedPixelCopyLastMilliseconds,
            ownedPixelCopyMaxMilliseconds: slot.ownedPixelCopyMaxMilliseconds,
            ownedAttachmentPropagationLastMilliseconds: slot.ownedAttachmentPropagationLastMilliseconds,
            ownedAttachmentPropagationMaxMilliseconds: slot.ownedAttachmentPropagationMaxMilliseconds,
            ownedSlowCopyCount: slot.ownedSlowCopyCount,
            ownedCopyMaxBreakdown: slot.ownedCopyMaxBreakdown,
            activeOwnedLeaseCount: activeOwnedLeases[role]?.count ?? 0,
            ownedLeaseReleaseCount: slot.ownedLeaseReleaseCount,
            ownedLeaseMaxLifetimeMilliseconds: slot.ownedLeaseMaxLifetimeMilliseconds,
            ownedLeaseMaxLifetimeSummary: slot.ownedLeaseMaxLifetimeSummary,
            activeOwnedLeaseSummary: activeLeaseSummaryLocked(for: role),
            ownedCopyDropLastLeaseSummary: slot.ownedCopyDropLastLeaseSummary,
            ownedPrewarmBufferCount: poolMetrics.prewarmBufferCount,
            ownedPrewarmLastMilliseconds: poolMetrics.prewarmLastMilliseconds,
            ownedPrewarmMaxMilliseconds: poolMetrics.prewarmMaxMilliseconds,
            readCount: slot.readCount,
            staleRejectCount: slot.staleRejectCount,
            generationRejectCount: slot.generationRejectCount,
            deviceRejectCount: slot.deviceRejectCount,
            waiterCount: waiters.values.filter { $0.role == role }.count
                + evidenceWaiters.values.filter { $0.role == role }.count,
            waiterSuccessCount: slot.waiterSuccessCount,
            waiterTimeoutCount: slot.waiterTimeoutCount,
            ageSeconds: evidence.map {
                guard nowUptimeNanoseconds >= $0.capturedUptimeNanoseconds else { return 0 }
                return Double(nowUptimeNanoseconds - $0.capturedUptimeNanoseconds) / 1_000_000_000
            },
            sizeText: evidence?.sizeText ?? "--",
            source: evidence?.source ?? "no evidence",
            physicalDeviceID: evidence?.physicalDeviceID,
            captureGeneration: evidence?.captureGeneration ?? 0,
            lastClearReason: slot.lastClearReason
        )
    }

    private func frameMatches(
        _ frame: RinkLensFrameHubFrame,
        maximumAgeNanoseconds: UInt64,
        minimumSequenceExclusive: Int?,
        requiredCaptureGeneration: Int?,
        requiredPhysicalDeviceID: String?,
        nowUptimeNanoseconds: UInt64
    ) -> Bool {
        guard Self.isFresh(
            frame,
            maximumAgeNanoseconds: maximumAgeNanoseconds,
            nowUptimeNanoseconds: nowUptimeNanoseconds
        ) else { return false }
        if let minimumSequenceExclusive,
           frame.sequence <= minimumSequenceExclusive { return false }
        if let requiredCaptureGeneration,
           frame.captureGeneration != requiredCaptureGeneration { return false }
        if let requiredPhysicalDeviceID,
           frame.physicalDeviceID != requiredPhysicalDeviceID { return false }
        return true
    }

    private func evidenceMatches(
        _ evidence: RinkLensFrameHubEvidence,
        maximumAgeNanoseconds: UInt64,
        minimumSequenceExclusive: Int?,
        requiredCaptureGeneration: Int?,
        requiredPhysicalDeviceID: String?,
        nowUptimeNanoseconds: UInt64
    ) -> Bool {
        guard Self.isFresh(
            evidence,
            maximumAgeNanoseconds: maximumAgeNanoseconds,
            nowUptimeNanoseconds: nowUptimeNanoseconds
        ) else { return false }
        if let minimumSequenceExclusive, evidence.sequence <= minimumSequenceExclusive { return false }
        if let requiredCaptureGeneration, evidence.captureGeneration != requiredCaptureGeneration { return false }
        if let requiredPhysicalDeviceID, evidence.physicalDeviceID != requiredPhysicalDeviceID { return false }
        return true
    }

    private static func isFresh(
        _ evidence: RinkLensFrameHubEvidence,
        maximumAgeNanoseconds: UInt64,
        nowUptimeNanoseconds: UInt64
    ) -> Bool {
        guard nowUptimeNanoseconds >= evidence.capturedUptimeNanoseconds else { return true }
        return nowUptimeNanoseconds - evidence.capturedUptimeNanoseconds <= maximumAgeNanoseconds
    }

    private static func isFresh(
        _ frame: RinkLensFrameHubFrame,
        maximumAgeNanoseconds: UInt64,
        nowUptimeNanoseconds: UInt64
    ) -> Bool {
        guard nowUptimeNanoseconds >= frame.capturedUptimeNanoseconds else { return true }
        return nowUptimeNanoseconds - frame.capturedUptimeNanoseconds <= maximumAgeNanoseconds
    }

    private static func nanoseconds(for seconds: TimeInterval) -> UInt64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return UInt64(min(seconds * 1_000_000_000, Double(UInt64.max)))
    }
}

#endif
