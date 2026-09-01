// BUILD 699 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation
import CoreImage
import CoreVideo
import CoreMedia
import UIKit

// MARK: - v0.9.2 Stage 8 production PixelBuffer frame provider

// MARK: - Recovery AV direct recording ingress

/// Short-lived recording offer created inside CaptureEngine's AVCapture callback.
/// The originating CVPixelBuffer is valid only for the synchronous sink call.
/// RecordingWriter must copy it into its own bounded ingress pool before returning;
/// the callback buffer may never be retained or dispatched asynchronously.
nonisolated struct BroadcastRecordingCaptureFrame: @unchecked Sendable {
    let role: RinkLensFrameRole
    let pixelBuffer: CVPixelBuffer
    let capturedAt: Date
    let capturedUptimeNanoseconds: UInt64
    let sequence: Int
    let width: Int
    let height: Int
    let pixelFormat: OSType
    let source: String
    let physicalDeviceID: String?
    let captureGeneration: Int

    init(pixelBuffer: CVPixelBuffer, evidence: RinkLensFrameHubEvidence) {
        self.role = evidence.role
        self.pixelBuffer = pixelBuffer
        self.capturedAt = evidence.capturedAt
        self.capturedUptimeNanoseconds = evidence.capturedUptimeNanoseconds
        self.sequence = evidence.sequence
        self.width = evidence.width
        self.height = evidence.height
        self.pixelFormat = evidence.pixelFormat
        self.source = evidence.source
        self.physicalDeviceID = evidence.physicalDeviceID
        self.captureGeneration = evidence.captureGeneration
    }

    var sizeText: String { "\(width)x\(height)" }
}

// MARK: - Recording-owned frame

/// Payload passed from the camera sample-buffer tap to the recording writer.
/// It intentionally carries a CVPixelBuffer plus a cached overlay CIImage so the
/// 60fps recording path does not render SwiftUI to UIImage per frame.
nonisolated struct BroadcastRecordingPixelBufferFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let capturedAt: Date
    let capturedUptimeNanoseconds: UInt64
    let sequence: Int
    let sizeText: String
    let sourceDescription: String
    let cameraRotationDegrees: Double
    let compositeRotationDegrees: Double
    let mirrorCorrectionEnabled: Bool
    let overlayCIImage: CIImage?

    init(
        pixelBuffer: CVPixelBuffer,
        capturedAt: Date = Date(),
        capturedUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
        sequence: Int = 0,
        sizeText: String? = nil,
        sourceDescription: String = "direct pixelBuffer",
        cameraRotationDegrees: Double = 0,
        compositeRotationDegrees: Double = 0,
        mirrorCorrectionEnabled: Bool = false,
        overlayCIImage: CIImage? = nil
    ) {
        self.pixelBuffer = pixelBuffer
        self.capturedAt = capturedAt
        self.capturedUptimeNanoseconds = capturedUptimeNanoseconds
        self.sequence = sequence
        self.sizeText = sizeText ?? "\(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))"
        self.sourceDescription = sourceDescription
        self.cameraRotationDegrees = cameraRotationDegrees
        self.compositeRotationDegrees = compositeRotationDegrees
        self.mirrorCorrectionEnabled = mirrorCorrectionEnabled
        self.overlayCIImage = overlayCIImage
    }

    var ageSeconds: TimeInterval { Date().timeIntervalSince(capturedAt) }
}


/// Immutable camera-role binding plus a lock-protected overlay mailbox used by
/// the background recording worker. Recovery AQ no longer reads FrameHub pixels
/// at recording cadence: CaptureEngine delivers physical callback events directly
/// and this context validates generation/device identity plus the cached overlay.
nonisolated struct BroadcastRecordingFrameSourceEvidence: Sendable {
    let sourceRole: RinkLensFrameRole
    let boundGeneration: Int
    let boundPhysicalDeviceID: String?
    let lastAcceptedGeneration: Int?
    let lastAcceptedPhysicalDeviceID: String?
    let lastAcceptedSequence: Int?
    let lastAcceptedUptimeNanoseconds: UInt64?
    let rejectedGenerationCount: Int
    let rejectedDeviceCount: Int

    var lastAcceptedFrameAgeSeconds: TimeInterval? {
        guard let accepted = lastAcceptedUptimeNanoseconds else { return nil }
        let now = DispatchTime.now().uptimeNanoseconds
        return now >= accepted ? Double(now - accepted) / 1_000_000_000 : 0
    }
}

nonisolated final class BroadcastRecordingPixelBufferFrameSourceContext: @unchecked Sendable {
    let sourceDescription: String

    let sourceRole: RinkLensFrameRole
    private let bindingLock = NSLock()
    private var requiredCaptureGenerationStorage: Int
    private var requiredPhysicalDeviceIDStorage: String?
    private var lastAcceptedGenerationStorage: Int?
    private var lastAcceptedPhysicalDeviceIDStorage: String?
    private var lastAcceptedSequenceStorage: Int?
    private var lastAcceptedUptimeNanosecondsStorage: UInt64?
    private var rejectedGenerationCountStorage = 0
    private var rejectedDeviceCountStorage = 0
    private let cameraRotationDegrees: Double
    private let compositeRotationDegrees: Double
    private let mirrorCorrectionEnabled: Bool
    private let overlayLock = NSLock()
    private var overlayCIImage: CIImage?

    init(
        sourceRole: RinkLensFrameRole,
        sourceDescription: String,
        requiredCaptureGeneration: Int,
        requiredPhysicalDeviceID: String?,
        cameraRotationDegrees: Double,
        compositeRotationDegrees: Double,
        mirrorCorrectionEnabled: Bool,
        overlayCIImage: CIImage?
    ) {
        self.sourceRole = sourceRole
        self.sourceDescription = sourceDescription
        self.requiredCaptureGenerationStorage = requiredCaptureGeneration
        self.requiredPhysicalDeviceIDStorage = requiredPhysicalDeviceID
        self.cameraRotationDegrees = cameraRotationDegrees
        self.compositeRotationDegrees = compositeRotationDegrees
        self.mirrorCorrectionEnabled = mirrorCorrectionEnabled
        self.overlayCIImage = overlayCIImage
    }

    var requiredCaptureGeneration: Int {
        bindingLock.lock()
        let value = requiredCaptureGenerationStorage
        bindingLock.unlock()
        return value
    }

    var requiredPhysicalDeviceID: String? {
        bindingLock.lock()
        let value = requiredPhysicalDeviceIDStorage
        bindingLock.unlock()
        return value
    }

    /// Build 581: a paused recording may release the camera graph while Command
    /// Centre is visible. Rebind the writer source mailbox to the fresh
    /// CaptureEngine generation before the writer is resumed.
    @discardableResult
    func rebindCapture(generation: Int, physicalDeviceID: String?) -> Bool {
        bindingLock.lock()
        let changed = requiredCaptureGenerationStorage != generation
            || requiredPhysicalDeviceIDStorage != physicalDeviceID
        requiredCaptureGenerationStorage = generation
        requiredPhysicalDeviceIDStorage = physicalDeviceID
        bindingLock.unlock()
        return changed
    }

    func captureEvidence() -> BroadcastRecordingFrameSourceEvidence {
        bindingLock.lock()
        let evidence = BroadcastRecordingFrameSourceEvidence(
            sourceRole: sourceRole,
            boundGeneration: requiredCaptureGenerationStorage,
            boundPhysicalDeviceID: requiredPhysicalDeviceIDStorage,
            lastAcceptedGeneration: lastAcceptedGenerationStorage,
            lastAcceptedPhysicalDeviceID: lastAcceptedPhysicalDeviceIDStorage,
            lastAcceptedSequence: lastAcceptedSequenceStorage,
            lastAcceptedUptimeNanoseconds: lastAcceptedUptimeNanosecondsStorage,
            rejectedGenerationCount: rejectedGenerationCountStorage,
            rejectedDeviceCount: rejectedDeviceCountStorage
        )
        bindingLock.unlock()
        return evidence
    }

    func updateOverlay(_ overlay: CIImage?) {
        overlayLock.lock()
        overlayCIImage = overlay
        overlayLock.unlock()
    }

    private func captureBinding() -> (generation: Int, deviceID: String?) {
        bindingLock.lock()
        let value = (requiredCaptureGenerationStorage, requiredPhysicalDeviceIDStorage)
        bindingLock.unlock()
        return value
    }

    /// Recovery AV: validate the physical callback against the immutable recording
    /// binding before RecordingWriter makes its one recording-owned pixel copy.
    /// FrameHub supplies only sequence/generation/device evidence on Broadcast.
    func recordingFrame(from captureFrame: BroadcastRecordingCaptureFrame) -> BroadcastRecordingPixelBufferFrame? {
        guard captureFrame.role == sourceRole else { return nil }
        bindingLock.lock()
        guard captureFrame.captureGeneration == requiredCaptureGenerationStorage else {
            rejectedGenerationCountStorage &+= 1
            bindingLock.unlock()
            return nil
        }
        if let requiredDevice = requiredPhysicalDeviceIDStorage,
           captureFrame.physicalDeviceID != requiredDevice {
            rejectedDeviceCountStorage &+= 1
            bindingLock.unlock()
            return nil
        }
        lastAcceptedGenerationStorage = captureFrame.captureGeneration
        lastAcceptedPhysicalDeviceIDStorage = captureFrame.physicalDeviceID
        lastAcceptedSequenceStorage = captureFrame.sequence
        lastAcceptedUptimeNanosecondsStorage = captureFrame.capturedUptimeNanoseconds
        bindingLock.unlock()

        overlayLock.lock()
        let overlay = overlayCIImage
        overlayLock.unlock()
        return BroadcastRecordingPixelBufferFrame(
            pixelBuffer: captureFrame.pixelBuffer,
            capturedAt: captureFrame.capturedAt,
            capturedUptimeNanoseconds: captureFrame.capturedUptimeNanoseconds,
            sequence: captureFrame.sequence,
            sizeText: captureFrame.sizeText,
            sourceDescription: "CaptureEngine callback \(sourceDescription) #\(captureFrame.sequence) \(captureFrame.sizeText)",
            cameraRotationDegrees: cameraRotationDegrees,
            compositeRotationDegrees: compositeRotationDegrees,
            mirrorCorrectionEnabled: mirrorCorrectionEnabled,
            overlayCIImage: overlay
        )
    }

    func hasFreshFrame(maxAge: TimeInterval) -> Bool {
        let binding = captureBinding()
        return RinkLensFrameHub.shared.hasFreshFrame(
            for: sourceRole,
            maxAge: maxAge,
            requiredCaptureGeneration: binding.generation,
            requiredPhysicalDeviceID: binding.deviceID
        )
    }


}

@MainActor
enum BroadcastRecordingStage8PixelBufferFrameProvider {
    static func makeSourceContext(
        viewModel: HockeyScoreboardViewModel,
        prewarmedOverlay: CIImage? = nil
    ) -> BroadcastRecordingPixelBufferFrameSourceContext {
        let sourceService = viewModel.broadcastRecordingCameraService
        let usingOCRPrimary = sourceService === viewModel.ocrCameraService
        let visibleBroadcastRotation = Double(viewModel.livePreviewRotationOffsetDegrees)
        let cameraRotation = AppContainer.shared.recordingEngine.recordingDisplayRotation(
            liveRotationDegrees: visibleBroadcastRotation,
            usingOCRFallback: false
        )
        let compositeRotation = AppContainer.shared.recordingEngine.recordingCompositeCorrectionDegrees()
        let sourceDescription = usingOCRPrimary
            ? "UX16c27 native single-camera OCR/Broadcast source"
            : "UX16c27 native Broadcast camera source"
        let capture = viewModel.externalOCRMultiCamCoordinator.snapshot
        let sourceRole: RinkLensFrameRole = usingOCRPrimary ? .ocr : .broadcast
        let requiredDeviceID = usingOCRPrimary ? capture.ocrDeviceID : capture.liveDeviceID
        return BroadcastRecordingPixelBufferFrameSourceContext(
            sourceRole: sourceRole,
            sourceDescription: sourceDescription,
            requiredCaptureGeneration: capture.transitionGeneration,
            requiredPhysicalDeviceID: requiredDeviceID,
            cameraRotationDegrees: cameraRotation,
            compositeRotationDegrees: compositeRotation,
            mirrorCorrectionEnabled: AppContainer.shared.recordingEngine.recordingMirrorCorrectionEnabled,
            // Build 574 receives a complete overlay that was rendered on the
            // dedicated overlay queue before the recording lease starts.
            overlayCIImage: prewarmedOverlay
        )
    }

    static func prewarmOverlay(
        viewModel: HockeyScoreboardViewModel,
        outputSize requestedOutputSize: CGSize? = nil,
        completion: @escaping @MainActor (CIImage?) -> Void
    ) {
        let outputSize = requestedOutputSize ?? AppContainer.shared.recordingEngine.recordingOutputSize
        BroadcastRecordingOverlayCache.shared.prewarmOverlayImage(
            outputSize: outputSize,
            modeStatusText: viewModel.operatingModeStatusText,
            strengthState: viewModel.currentStrengthState,
            banner: viewModel.activeBroadcastBanner,
            homeLogo: viewModel.homeLogoImage,
            awayLogo: viewModel.awayLogoImage,
            overlayMode: BroadcastRecordingRenderBudgetGuard.shared.currentMode(),
            layout: BroadcastScoreboardLayoutSettings.shared.snapshot,
            timelineEvents: [],
            viewerScoreboard: viewModel.broadcastOverlaySnapshot.viewerScoreboard
        ) { image in
            guard let image else {
                completion(nil)
                return
            }
            completion(CIImage(cgImage: image).cropped(to: CGRect(origin: .zero, size: outputSize)))
        }
    }

    /// Compatibility-only SwiftUI raster path retained for diagnostics. Live
    /// streaming uses `prewarmOverlay`, whose layered Core Graphics renderer is
    /// checked against ScorebugView by BroadcastScorebugSnapshotParityHarness
    /// and does not block MainActor during score/clock updates.
    @MainActor
    static func prewarmCanonicalStreamOverlay(
        viewModel: HockeyScoreboardViewModel,
        outputSize: CGSize,
        completion: @escaping @MainActor (CIImage?) -> Void
    ) {
        BroadcastRecordingOverlayCache.shared.prewarmCanonicalScorebugViewOverlayImage(
            outputSize: outputSize,
            modeStatusText: viewModel.operatingModeStatusText,
            strengthState: viewModel.currentStrengthState,
            banner: viewModel.activeBroadcastBanner,
            homeLogo: viewModel.homeLogoImage,
            awayLogo: viewModel.awayLogoImage,
            layout: BroadcastScoreboardLayoutSettings.shared.snapshot,
            timelineEvents: [],
            viewerScoreboard: viewModel.broadcastOverlaySnapshot.viewerScoreboard
        ) { image in
            guard let image else {
                completion(nil)
                return
            }
            completion(CIImage(cgImage: image).cropped(to: CGRect(origin: .zero, size: outputSize)))
        }
    }

    static func makeOverlayCIImage(
        viewModel: HockeyScoreboardViewModel,
        outputSize requestedOutputSize: CGSize? = nil
    ) -> CIImage? {
        let outputSize = requestedOutputSize ?? AppContainer.shared.recordingEngine.recordingOutputSize
        return BroadcastOverlayCIImageCache.shared.overlayCIImage(
            outputSize: outputSize,
            modeStatusText: viewModel.operatingModeStatusText,
            strengthState: viewModel.currentStrengthState,
            banner: viewModel.activeBroadcastBanner,
            homeLogo: viewModel.homeLogoImage,
            awayLogo: viewModel.awayLogoImage,
            overlayMode: BroadcastRecordingRenderBudgetGuard.shared.currentMode(),
            layout: BroadcastScoreboardLayoutSettings.shared.snapshot,
            timelineEvents: [],
            viewerScoreboard: viewModel.broadcastOverlaySnapshot.viewerScoreboard
        )
    }

    static func makeCameraOnlyFrame(viewModel: HockeyScoreboardViewModel) -> BroadcastRecordingPixelBufferFrame? {
        let primaryService = viewModel.broadcastRecordingCameraService
        let fallbackService = primaryService === viewModel.liveCameraService ? viewModel.ocrCameraService : viewModel.liveCameraService
        let primaryLabel = primaryService === viewModel.ocrCameraService ? "OCR primary" : "Live primary"
        let fallbackLabel = fallbackService === viewModel.ocrCameraService ? "OCR fallback" : "Live fallback"
        let livePhysicalID = viewModel.liveCameraService.resolvedCameraDeviceID
            ?? viewModel.liveCameraService.selectedCameraID
        let ocrPhysicalID = viewModel.ocrCameraService.resolvedCameraDeviceID
            ?? viewModel.ocrCameraService.selectedCameraID
        let cameraRolesAreDistinct = livePhysicalID != nil
            && ocrPhysicalID != nil
            && livePhysicalID != ocrPhysicalID

        let primaryRole: RinkLensFrameRole = primaryService === viewModel.ocrCameraService ? .ocr : .broadcast
        let fallbackRole: RinkLensFrameRole = fallbackService === viewModel.ocrCameraService ? .ocr : .broadcast
        let primaryPixelSnapshot = RinkLensFrameHub.shared.latestPixelBufferSnapshot(
            for: primaryRole,
            maxAge: 0.35
        )
        // UX16c26: compare resolved physical devices where available and never
        // silently record the scoreboard/OCR camera when the roles are distinct.
        let fallbackPixelSnapshot = cameraRolesAreDistinct
            ? nil
            : RinkLensFrameHub.shared.latestPixelBufferSnapshot(for: fallbackRole, maxAge: 0.35)

        guard let pixelSelection = BroadcastRecordingPixelBufferFrameSourceSelector.select(
            primary: primaryPixelSnapshot,
            primaryLabel: primaryLabel,
            fallback: fallbackPixelSnapshot,
            fallbackLabel: fallbackLabel
        ) else {
            BroadcastRecordingRendererPathDiagnostics.shared.notePixelBufferFallback(
                reason: cameraRolesAreDistinct
                    ? "No fresh Broadcast camera pixelBuffer; OCR-camera substitution blocked by UX16c26 physical-source integrity guard"
                    : "Stage 8 production PixelBuffer path active but no fresh non-black direct pixelBuffer was available"
            )
            return nil
        }

        let selectedService = pixelSelection.role == .primary ? primaryService : fallbackService
        let usingOCRFallback = pixelSelection.role == .fallback && selectedService === viewModel.ocrCameraService
        let usingSingleCameraOCRPrimary = pixelSelection.role == .primary && selectedService === viewModel.ocrCameraService
        let visibleBroadcastRotation = Double(viewModel.livePreviewRotationOffsetDegrees)
        let cameraRotation = AppContainer.shared.recordingEngine.recordingDisplayRotation(
            liveRotationDegrees: visibleBroadcastRotation,
            usingOCRFallback: usingOCRFallback
        )
        let compositeRotation = AppContainer.shared.recordingEngine.recordingCompositeCorrectionDegrees()

        let sourcePrefix = usingSingleCameraOCRPrimary
            ? "production PixelBuffer writer + single-camera OCR/broadcast frame"
            : (usingOCRFallback ? "production PixelBuffer writer + OCR fallback frame" : "production PixelBuffer writer + live camera frame")
        let sourceReason = pixelSelection.usedFallbackBecausePrimaryWasBlank
            ? " | \(pixelSelection.rejectedPrimarySummary ?? "primary rejected")"
            : ""
        let cadenceSummary = BroadcastRecordingSourceCadenceMonitor.shared.noteSelectedSource(
            label: pixelSelection.sourceLabel,
            sequence: pixelSelection.snapshot.sequence,
            targetFPS: AppContainer.shared.recordingEngine.currentTargetFPSValue,
            sizeText: pixelSelection.snapshot.sizeText
        )
        let sourceDescription = "\(sourcePrefix) #\(pixelSelection.snapshot.sequence) \(pixelSelection.qualitySummary); \(cadenceSummary)\(sourceReason)"

        let overlayMode = BroadcastRecordingRenderBudgetGuard.shared.currentMode()
        let overlayCIImage = BroadcastOverlayCIImageCache.shared.overlayCIImage(
            outputSize: AppContainer.shared.recordingEngine.recordingOutputSize,
            modeStatusText: viewModel.operatingModeStatusText,
            strengthState: viewModel.currentStrengthState,
            banner: viewModel.activeBroadcastBanner,
            homeLogo: viewModel.homeLogoImage,
            awayLogo: viewModel.awayLogoImage,
            overlayMode: overlayMode,
            layout: BroadcastScoreboardLayoutSettings.shared.snapshot,
            viewerScoreboard: viewModel.broadcastOverlaySnapshot.viewerScoreboard
        )
        let overlayText = overlayCIImage == nil ? "no cached overlay" : "cached overlay CIImage"

        AppContainer.shared.recordingEngine.recordingSourceText = sourceDescription
        AppContainer.shared.recordingEngine.recordingRotationText = "camera \(Int(cameraRotation.rounded()))° / export \(Int(compositeRotation.rounded()))°" + (AppContainer.shared.recordingEngine.recordingMirrorCorrectionEnabled ? " + mirror fix" : "")
        AppContainer.shared.recordingEngine.recordingTransformSourceText = AppContainer.shared.recordingEngine.broadcastTransformSummary(
            liveRotationDegrees: visibleBroadcastRotation,
            usingOCRFallback: usingOCRFallback
        )
        AppContainer.shared.recordingEngine.updateRecordingRawFrameCorrectionText(
            "Stage 8 production PixelBuffer path; \(overlayText); source \(pixelSelection.snapshot.sizeText)"
        )

        return BroadcastRecordingPixelBufferFrame(
            pixelBuffer: pixelSelection.snapshot.pixelBuffer,
            capturedAt: pixelSelection.snapshot.capturedAt,
            sequence: pixelSelection.snapshot.sequence,
            sizeText: pixelSelection.snapshot.sizeText,
            sourceDescription: sourceDescription,
            cameraRotationDegrees: cameraRotation,
            compositeRotationDegrees: compositeRotation,
            mirrorCorrectionEnabled: AppContainer.shared.recordingEngine.recordingMirrorCorrectionEnabled,
            overlayCIImage: overlayCIImage
        )
    }
}

nonisolated struct BroadcastPixelBufferFrameQuality {
    let isBlack: Bool
    let isIndeterminate: Bool
    let averageLuma: Double
    let brightSampleRatio: Double
    let summary: String

    /// Stable diagnostic classification for callers compiled against either
    /// the pre-UX16c52 or UX16c52 quality contract. Runtime recording logic
    /// must continue to accept indeterminate analysis results.
    var diagnosticDisposition: String {
        if isIndeterminate { return "indeterminate" }
        return isBlack ? "black" : "valid"
    }
}

nonisolated enum BroadcastPixelBufferFrameQualityAnalyser {
    static func analyse(_ pixelBuffer: CVPixelBuffer) -> BroadcastPixelBufferFrameQuality {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        if CVPixelBufferIsPlanar(pixelBuffer), CVPixelBufferGetPlaneCount(pixelBuffer) > 0 {
            return analyseLumaPlane(pixelBuffer, pixelFormat: pixelFormat)
        }
        return analysePacked(pixelBuffer, pixelFormat: pixelFormat)
    }

    private static func analyseLumaPlane(
        _ pixelBuffer: CVPixelBuffer,
        pixelFormat: OSType
    ) -> BroadcastPixelBufferFrameQuality {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            return indeterminate("no luma base", pixelFormat: pixelFormat)
        }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        guard width > 0, height > 0, rowBytes > 0 else {
            return indeterminate("empty luma plane", pixelFormat: pixelFormat)
        }

        let sampleRows = min(18, height)
        let sampleCols = min(32, width)
        let rowStep = max(1, height / sampleRows)
        let colStep = max(1, width / sampleCols)
        let usesSixteenBitStorage = rowBytes >= width * 2
        var total = 0.0
        var bright = 0
        var count = 0
        var y = rowStep / 2

        if usesSixteenBitStorage {
            let wordsPerRow = rowBytes / MemoryLayout<UInt16>.size
            let pointer = base.assumingMemoryBound(to: UInt16.self)
            while y < height {
                var x = colStep / 2
                while x < width {
                    let raw = pointer[y * wordsPerRow + x]
                    // P010/10-bit bi-planar buffers normally store the ten useful
                    // bits in the high bits. Accept lower-bit packing as well.
                    let tenBit = raw > 1023 ? Double(raw >> 6) : Double(raw)
                    let luma = min(1, max(0, tenBit / 1023.0))
                    total += luma
                    if luma > 0.08 { bright += 1 }
                    count += 1
                    x += colStep
                }
                y += rowStep
            }
            return result(
                total: total,
                bright: bright,
                count: count,
                prefix: "luma16",
                pixelFormat: pixelFormat
            )
        }

        let pointer = base.assumingMemoryBound(to: UInt8.self)
        let videoRange = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        while y < height {
            var x = colStep / 2
            while x < width {
                let raw = Double(pointer[y * rowBytes + x])
                let luma = videoRange
                    ? min(1, max(0, (raw - 16.0) / 219.0))
                    : min(1, max(0, raw / 255.0))
                total += luma
                if luma > 0.08 { bright += 1 }
                count += 1
                x += colStep
            }
            y += rowStep
        }
        return result(
            total: total,
            bright: bright,
            count: count,
            prefix: videoRange ? "luma8-video" : "luma8-full",
            pixelFormat: pixelFormat
        )
    }

    private static func analysePacked(
        _ pixelBuffer: CVPixelBuffer,
        pixelFormat: OSType
    ) -> BroadcastPixelBufferFrameQuality {
        guard pixelFormat == kCVPixelFormatType_32BGRA
                || pixelFormat == kCVPixelFormatType_32ARGB
                || pixelFormat == kCVPixelFormatType_32RGBA else {
            return indeterminate("unsupported packed format", pixelFormat: pixelFormat)
        }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return indeterminate("no packed base", pixelFormat: pixelFormat)
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0, rowBytes >= width * 4 else {
            return indeterminate("empty packed image", pixelFormat: pixelFormat)
        }

        let pointer = base.assumingMemoryBound(to: UInt8.self)
        let sampleRows = min(18, height)
        let sampleCols = min(32, width)
        let rowStep = max(1, height / sampleRows)
        let colStep = max(1, width / sampleCols)
        var total = 0.0
        var bright = 0
        var count = 0
        var y = rowStep / 2
        while y < height {
            var x = colStep / 2
            while x < width {
                let offset = y * rowBytes + x * 4
                let r: Double
                let g: Double
                let b: Double
                switch pixelFormat {
                case kCVPixelFormatType_32BGRA:
                    b = Double(pointer[offset]) / 255.0
                    g = Double(pointer[offset + 1]) / 255.0
                    r = Double(pointer[offset + 2]) / 255.0
                case kCVPixelFormatType_32ARGB:
                    r = Double(pointer[offset + 1]) / 255.0
                    g = Double(pointer[offset + 2]) / 255.0
                    b = Double(pointer[offset + 3]) / 255.0
                default:
                    r = Double(pointer[offset]) / 255.0
                    g = Double(pointer[offset + 1]) / 255.0
                    b = Double(pointer[offset + 2]) / 255.0
                }
                let luma = (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
                total += luma
                if luma > 0.08 { bright += 1 }
                count += 1
                x += colStep
            }
            y += rowStep
        }
        return result(total: total, bright: bright, count: count, prefix: "packed", pixelFormat: pixelFormat)
    }

    private static func result(
        total: Double,
        bright: Int,
        count: Int,
        prefix: String,
        pixelFormat: OSType
    ) -> BroadcastPixelBufferFrameQuality {
        guard count > 0 else { return indeterminate("no samples", pixelFormat: pixelFormat) }
        let average = total / Double(count)
        let brightRatio = Double(bright) / Double(count)
        let isBlack = average < 0.018 && brightRatio < 0.015
        let summary = String(
            format: "%@ fmt=%@ avg %.3f bright %.1f%%",
            prefix,
            fourCC(pixelFormat),
            average,
            brightRatio * 100
        )
        return BroadcastPixelBufferFrameQuality(
            isBlack: isBlack,
            isIndeterminate: false,
            averageLuma: average,
            brightSampleRatio: brightRatio,
            summary: summary
        )
    }

    private static func indeterminate(_ reason: String, pixelFormat: OSType) -> BroadcastPixelBufferFrameQuality {
        BroadcastPixelBufferFrameQuality(
            isBlack: false,
            isIndeterminate: true,
            averageLuma: 0,
            brightSampleRatio: 0,
            summary: "indeterminate fmt=\(fourCC(pixelFormat)) \(reason); continuity preserved"
        )
    }

    private static func fourCC(_ value: OSType) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii)
            ?? String(format: "0x%08X", value)
    }
}

#endif
