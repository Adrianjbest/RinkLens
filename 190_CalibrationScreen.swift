// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import AVFoundation
import Vision
import CoreMedia
import CoreGraphics
import CoreImage
import ImageIO
import UIKit
import Foundation
#if canImport(MLKitVision) && canImport(MLKitTextRecognition) && canImport(MLKitTextRecognitionLatin)
import MLKitVision
import MLKitTextRecognition
import MLKitTextRecognitionLatin
#endif


final class OCRChromeGeometryDiagnosticsStore: @unchecked Sendable {
    static let shared = OCRChromeGeometryDiagnosticsStore()

    private let lock = NSLock()
    private var topLine: String = "top geometry not captured yet"
    private var panelLine: String = "test panel geometry not captured yet"
    private var zoomLine: String = "zoom geometry not captured yet"
    private var updatedAt: Date?

    private init() {}

    func noteTop(_ line: String) {
        update(kind: "top", line: line)
    }

    func notePanel(_ line: String) {
        update(kind: "panel", line: line)
    }

    func noteZoom(_ line: String) {
        update(kind: "zoom", line: line)
    }

    private func update(kind: String, line: String) {
        lock.lock()
        updatedAt = Date()
        switch kind {
        case "top": topLine = line
        case "panel": panelLine = line
        case "zoom": zoomLine = line
        default: break
        }
        lock.unlock()
    }

    func exportLines() -> [String] {
        lock.lock()
        let updated = updatedAt.map { "Last update: \($0.formatted(date: .omitted, time: .standard))" } ?? "Last update: never"
        let lines = [updated, topLine, panelLine, zoomLine]
        lock.unlock()
        return lines
    }
}


// MARK: - Recovery AO FrameHub-backed OCR preview

/// RL-076/RL-084/RL-085: the operator OCR image must acknowledge the same
/// application-owned frame stream used by OCR/Image Relay. CaptureEngine remains
/// the hardware owner; FrameHub remains the bounded pixel owner; this store is
/// diagnostics only and owns no camera or pixel state.
nonisolated final class OCRFrameHubPreviewDiagnosticsStore: @unchecked Sendable {
    static let shared = OCRFrameHubPreviewDiagnosticsStore()

    private let lock = NSLock()
    private var active = false
    private var expectedGeneration = 0
    private var expectedDeviceID: String?
    private var latestEvidenceSequence = 0
    private var renderedSequence = 0
    private var displayedSequence = 0
    private var renderedCount = 0
    private var staleEvidenceCount = 0
    private var mismatchEvidenceCount = 0
    private var noFrameCount = 0
    private var lastRenderMilliseconds = 0.0
    private var maxRenderMilliseconds = 0.0
    private var lastDisplayAgeMilliseconds = 0.0
    private var renderedAverageLuma = -1.0
    private var renderedAverageAlpha = -1.0
    private var lastDecision = "inactive"

    private init() {}

    func noteActivation(generation: Int, deviceID: String?) {
        lock.lock()
        active = true
        expectedGeneration = generation
        expectedDeviceID = deviceID
        lastDecision = "FrameHub OCR preview active"
        lock.unlock()
    }

    func noteDeactivation(reason: String) {
        lock.lock()
        active = false
        lastDecision = reason
        lock.unlock()
    }

    func noteEvidence(_ evidence: RinkLensFrameHubEvidence) {
        lock.lock()
        latestEvidenceSequence = max(latestEvidenceSequence, evidence.sequence)
        lock.unlock()
    }

    func noteStaleEvidence() {
        lock.lock(); staleEvidenceCount &+= 1; lastDecision = "stale OCR evidence skipped"; lock.unlock()
    }

    func noteMismatchEvidence() {
        lock.lock(); mismatchEvidenceCount &+= 1; lastDecision = "generation/device mismatch skipped"; lock.unlock()
    }

    func noteNoFrame() {
        lock.lock(); noFrameCount &+= 1; lastDecision = "latest OCR frame unavailable at render"; lock.unlock()
    }

    func noteRendered(sequence: Int, milliseconds: Double, averageLuma: Double? = nil, averageAlpha: Double? = nil) {
        lock.lock()
        renderedSequence = sequence
        renderedCount &+= 1
        lastRenderMilliseconds = milliseconds
        maxRenderMilliseconds = max(maxRenderMilliseconds, milliseconds)
        if let averageLuma { renderedAverageLuma = averageLuma }
        if let averageAlpha { renderedAverageAlpha = averageAlpha }
        lastDecision = "FrameHub OCR frame rendered"
        lock.unlock()
    }

    func noteDisplayed(sequence: Int, ageMilliseconds: Double) {
        lock.lock()
        displayedSequence = sequence
        lastDisplayAgeMilliseconds = ageMilliseconds
        lastDecision = "FrameHub OCR frame committed to visible layer"
        lock.unlock()
    }

    func exportText() -> String {
        lock.lock()
        let text = String(
            format: "active=%@ expectedGen=%d expectedDevice=%@ evidenceSeq=%d renderedSeq=%d displayedSeq=%d rendered=%d renderMs=%.1f/max:%.1f renderedLuma=%.1f renderedAlpha=%.1f displayAgeMs=%.1f stale=%d mismatch=%d noFrame=%d decision=%@",
            active ? "true" : "false",
            expectedGeneration,
            expectedDeviceID ?? "none",
            latestEvidenceSequence,
            renderedSequence,
            displayedSequence,
            renderedCount,
            lastRenderMilliseconds,
            maxRenderMilliseconds,
            renderedAverageLuma,
            renderedAverageAlpha,
            lastDisplayAgeMilliseconds,
            staleEvidenceCount,
            mismatchEvidenceCount,
            noFrameCount,
            lastDecision
        )
        lock.unlock()
        return text
    }
}

nonisolated private final class OCRPreviewCGImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

nonisolated private final class OCRPreviewDisplayPayload: @unchecked Sendable {
    let box: OCRPreviewCGImageBox
    let sequence: Int
    let sourceUptime: UInt64
    let renderMilliseconds: Double
    let epoch: UInt64

    init(box: OCRPreviewCGImageBox, sequence: Int, sourceUptime: UInt64, renderMilliseconds: Double, epoch: UInt64) {
        self.box = box
        self.sequence = sequence
        self.sourceUptime = sourceUptime
        self.renderMilliseconds = renderMilliseconds
        self.epoch = epoch
    }
}

/// Event-driven, capacity-one renderer. FrameHub sends value-only evidence; the
/// renderer then reads only the newest OCR frame and releases that lease as soon
/// as the independent CGImage has been produced. No camera buffer queue is built.
nonisolated private final class OCRFrameHubPreviewRenderer: @unchecked Sendable {
    private let lock = NSLock()
    private let renderQueue = DispatchQueue(label: "com.rinklens.ocr.framehub-preview", qos: RinkLensExecutionQoSHierarchy.viewer)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let display: @MainActor @Sendable (OCRPreviewCGImageBox, Int, UInt64, Double) -> Void
    private var evidenceToken: UUID?
    private var renderBusy = false
    private var pendingSequence = 0
    // Recovery AW / RL-109: rendering was capacity-one but every CGImage created
    // an independent MainActor Task. A blocked UI could therefore retain an
    // unbounded queue of preview images. Display is now active+latest-pending only.
    private var displayBusy = false
    private var pendingDisplay: OCRPreviewDisplayPayload?
    private var displayEpoch: UInt64 = 0
    private var expectedGeneration = 0
    private var expectedDeviceID: String?
    private var rotationDegrees: CGFloat = 0
    private var isActive = false
    private var didSampleRenderedPixelTruth = false

    init(display: @escaping @MainActor @Sendable (OCRPreviewCGImageBox, Int, UInt64, Double) -> Void) {
        self.display = display
    }

    func update(expectedGeneration: Int, expectedDeviceID: String?, rotationDegrees: CGFloat) {
        lock.lock()
        self.expectedGeneration = expectedGeneration
        self.expectedDeviceID = expectedDeviceID
        self.rotationDegrees = rotationDegrees
        let active = isActive
        lock.unlock()
        if active {
            OCRFrameHubPreviewDiagnosticsStore.shared.noteActivation(
                generation: expectedGeneration,
                deviceID: expectedDeviceID
            )
        }
    }

    func start() {
        lock.lock()
        guard !isActive else { lock.unlock(); return }
        isActive = true
        didSampleRenderedPixelTruth = false
        displayEpoch &+= 1
        displayBusy = false
        pendingDisplay = nil
        let generation = expectedGeneration
        let deviceID = expectedDeviceID
        lock.unlock()
        OCRFrameHubPreviewDiagnosticsStore.shared.noteActivation(
            generation: generation,
            deviceID: deviceID
        )

        let token = RinkLensFrameHub.shared.installLatestEvidenceConsumer(
            for: .ocr,
            minimumInterval: 1.0 / 15.0
        ) { [weak self] evidence in
            self?.submit(evidence)
        }
        lock.lock()
        if isActive {
            evidenceToken = token
            lock.unlock()
        } else {
            lock.unlock()
            RinkLensFrameHub.shared.removeLatestEvidenceConsumer(for: .ocr, token: token)
        }
    }

    func stop(reason: String) {
        lock.lock()
        isActive = false
        displayEpoch &+= 1
        let token = evidenceToken
        evidenceToken = nil
        pendingSequence = 0
        pendingDisplay = nil
        displayBusy = false
        lock.unlock()
        if let token {
            RinkLensFrameHub.shared.removeLatestEvidenceConsumer(for: .ocr, token: token)
        }
        OCRFrameHubPreviewDiagnosticsStore.shared.noteDeactivation(reason: reason)
    }

    private func submit(_ evidence: RinkLensFrameHubEvidence) {
        lock.lock()
        guard isActive else { lock.unlock(); return }
        var expectedGeneration = self.expectedGeneration
        let expectedDeviceID = self.expectedDeviceID

        // Recovery EC: CaptureEngine's presentation snapshot can lag a branch-only
        // OCR reattach even though FrameHub is already receiving healthy frames
        // from the same physical OCR camera. In that case the old generation
        // fence made Calibration permanently black (for example expected 12 while
        // FrameHub was current at 15). A newer frame from the expected device is
        // authoritative pixel evidence, so advance only the preview fence. This
        // never starts/reconfigures capture and never accepts another device.
        if evidence.captureGeneration > expectedGeneration,
           expectedDeviceID == nil || evidence.physicalDeviceID == expectedDeviceID {
            expectedGeneration = evidence.captureGeneration
            self.expectedGeneration = expectedGeneration
        }

        guard evidence.captureGeneration == expectedGeneration,
              expectedDeviceID == nil || evidence.physicalDeviceID == expectedDeviceID else {
            lock.unlock()
            OCRFrameHubPreviewDiagnosticsStore.shared.noteMismatchEvidence()
            return
        }
        guard evidence.ageSeconds <= 0.50 else {
            lock.unlock()
            OCRFrameHubPreviewDiagnosticsStore.shared.noteStaleEvidence()
            return
        }
        OCRFrameHubPreviewDiagnosticsStore.shared.noteEvidence(evidence)
        pendingSequence = max(pendingSequence, evidence.sequence)
        guard !renderBusy else { lock.unlock(); return }
        renderBusy = true
        lock.unlock()
        renderQueue.async { [weak self] in self?.drainLatest() }
    }

    private func drainLatest() {
        while true {
            lock.lock()
            guard isActive else {
                renderBusy = false
                pendingSequence = 0
                lock.unlock()
                return
            }
            let requestedSequence = pendingSequence
            pendingSequence = 0
            let expectedGeneration = self.expectedGeneration
            let expectedDeviceID = self.expectedDeviceID
            let rotation = rotationDegrees
            lock.unlock()

            guard requestedSequence > 0,
                  let frame = RinkLensFrameHub.shared.latestFrame(
                    for: .ocr,
                    maxAge: 0.50,
                    requiredCaptureGeneration: expectedGeneration,
                    requiredPhysicalDeviceID: expectedDeviceID,
                    consumer: "OCRFrameHubPreviewSurface"
                  ) else {
                OCRFrameHubPreviewDiagnosticsStore.shared.noteNoFrame()
                lock.lock()
                if pendingSequence == 0 {
                    renderBusy = false
                    lock.unlock()
                    return
                }
                lock.unlock()
                continue
            }

            let renderStarted = DispatchTime.now().uptimeNanoseconds
            let sourceCaptured = frame.capturedUptimeNanoseconds
            let sequence = frame.sequence
            var image = CIImage(cvPixelBuffer: frame.pixelBuffer)
            image = rotated(image, degrees: rotation)
            image = downscaledForPreview(image, maximumDimension: 1280)
            let extent = image.extent.integral
            let cgImage = context.createCGImage(image, from: extent)
            let renderFinished = DispatchTime.now().uptimeNanoseconds
            let renderMilliseconds = Double(renderFinished - renderStarted) / 1_000_000.0

            if let cgImage {
                let pixelTruth: (luma: Double, alpha: Double)?
                if !didSampleRenderedPixelTruth {
                    didSampleRenderedPixelTruth = true
                    pixelTruth = averageRenderedPixelTruth(image)
                } else {
                    pixelTruth = nil
                }
                OCRFrameHubPreviewDiagnosticsStore.shared.noteRendered(
                    sequence: sequence,
                    milliseconds: renderMilliseconds,
                    averageLuma: pixelTruth?.luma,
                    averageAlpha: pixelTruth?.alpha
                )
                let box = OCRPreviewCGImageBox(cgImage)
                enqueueDisplay(
                    box: box,
                    sequence: sequence,
                    sourceUptime: sourceCaptured,
                    renderMilliseconds: renderMilliseconds
                )
            }

            lock.lock()
            if pendingSequence == 0 {
                renderBusy = false
                lock.unlock()
                return
            }
            lock.unlock()
        }
    }

    private func enqueueDisplay(
        box: OCRPreviewCGImageBox,
        sequence: Int,
        sourceUptime: UInt64,
        renderMilliseconds: Double
    ) {
        lock.lock()
        guard isActive else { lock.unlock(); return }
        let payload = OCRPreviewDisplayPayload(
            box: box,
            sequence: sequence,
            sourceUptime: sourceUptime,
            renderMilliseconds: renderMilliseconds,
            epoch: displayEpoch
        )
        if displayBusy {
            pendingDisplay = payload
            lock.unlock()
            return
        }
        displayBusy = true
        lock.unlock()
        dispatchDisplay(payload)
    }

    private func dispatchDisplay(_ payload: OCRPreviewDisplayPayload) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.displayPayloadIsCurrent(payload) else {
                self.completeDisplayDelivery(epoch: payload.epoch)
                return
            }
            self.display(
                payload.box,
                payload.sequence,
                payload.sourceUptime,
                payload.renderMilliseconds
            )
            self.completeDisplayDelivery(epoch: payload.epoch)
        }
    }

    private func displayPayloadIsCurrent(_ payload: OCRPreviewDisplayPayload) -> Bool {
        lock.lock()
        let current = isActive && payload.epoch == displayEpoch
        lock.unlock()
        return current
    }

    private func completeDisplayDelivery(epoch: UInt64) {
        lock.lock()
        guard epoch == displayEpoch else {
            lock.unlock()
            return
        }
        guard isActive else {
            pendingDisplay = nil
            displayBusy = false
            lock.unlock()
            return
        }
        let next = pendingDisplay
        pendingDisplay = nil
        if next == nil { displayBusy = false }
        lock.unlock()
        if let next { dispatchDisplay(next) }
    }

    private func rotated(_ image: CIImage, degrees: CGFloat) -> CIImage {
        var value = Int(degrees.rounded()) % 360
        if value < 0 { value += 360 }
        let oriented: CIImage
        switch value {
        case 90: oriented = image.oriented(.right)
        case 180: oriented = image.oriented(.down)
        case 270: oriented = image.oriented(.left)
        default: oriented = image
        }
        let extent = oriented.extent
        return oriented.transformed(
            by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        )
    }

    private func averageRenderedPixelTruth(_ image: CIImage) -> (luma: Double, alpha: Double) {
        let average = image.applyingFilter(
            "CIAreaAverage",
            parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)]
        )
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            average,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        let r = Double(pixel[0])
        let g = Double(pixel[1])
        let b = Double(pixel[2])
        let luma = (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
        return (luma, Double(pixel[3]))
    }

    private func downscaledForPreview(_ image: CIImage, maximumDimension: CGFloat) -> CIImage {
        let extent = image.extent
        let largest = max(extent.width, extent.height)
        guard largest > maximumDimension, largest > 0 else { return image }
        let scale = maximumDimension / largest
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
}

@MainActor
private final class OCRFrameHubPreviewHostView: UIView {
    private let imageLayer = CALayer()
    private lazy var renderer = OCRFrameHubPreviewRenderer { [weak self] box, sequence, sourceUptime, renderMilliseconds in
        guard let self, self.window != nil else { return }
        self.imageLayer.contents = box.image
        let now = DispatchTime.now().uptimeNanoseconds
        let ageMilliseconds = now >= sourceUptime
            ? Double(now - sourceUptime) / 1_000_000.0
            : 0
        OCRFrameHubPreviewDiagnosticsStore.shared.noteDisplayed(
            sequence: sequence,
            ageMilliseconds: ageMilliseconds
        )
        if sequence != self.lastDisplayedSequence {
            self.lastDisplayedSequence = sequence
            MainThreadStallMonitor.shared.traceRenderPreviewToggle(
                String(format: "Recovery AO OCR FrameHub preview displayed seq=%d age=%.1fms render=%.1fms", sequence, ageMilliseconds, renderMilliseconds)
            )
        }
    }
    private var expectedGeneration = 0
    private var expectedDeviceID: String?
    private var rotationDegrees: CGFloat = 0
    private var lastDisplayedSequence = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        imageLayer.backgroundColor = UIColor.black.cgColor
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.masksToBounds = true
        layer.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageLayer.frame = bounds
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            renderer.update(
                expectedGeneration: expectedGeneration,
                expectedDeviceID: expectedDeviceID,
                rotationDegrees: rotationDegrees
            )
            renderer.start()
        } else {
            renderer.stop(reason: "OCR FrameHub preview host left window")
            imageLayer.contents = nil
        }
    }

    func configure(expectedGeneration: Int, expectedDeviceID: String?, rotationDegrees: CGFloat) {
        self.expectedGeneration = expectedGeneration
        self.expectedDeviceID = expectedDeviceID
        self.rotationDegrees = rotationDegrees
        renderer.update(
            expectedGeneration: expectedGeneration,
            expectedDeviceID: expectedDeviceID,
            rotationDegrees: rotationDegrees
        )
    }
}

private struct OCRFrameHubPreviewView: UIViewRepresentable {
    let expectedGeneration: Int
    let expectedDeviceID: String?
    let rotationDegrees: CGFloat

    func makeUIView(context: Context) -> OCRFrameHubPreviewHostView {
        let view = OCRFrameHubPreviewHostView(frame: .zero)
        view.configure(
            expectedGeneration: expectedGeneration,
            expectedDeviceID: expectedDeviceID,
            rotationDegrees: rotationDegrees
        )
        return view
    }

    func updateUIView(_ uiView: OCRFrameHubPreviewHostView, context: Context) {
        uiView.configure(
            expectedGeneration: expectedGeneration,
            expectedDeviceID: expectedDeviceID,
            rotationDegrees: rotationDegrees
        )
    }

    static func dismantleUIView(_ uiView: OCRFrameHubPreviewHostView, coordinator: ()) {
        uiView.removeFromSuperview()
    }
}

// MARK: - v0.9.1l Calibration Camera Menu Refactor + Locked Manual Settings

private struct CalibrationWorkflowToolbarButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .background(.black.opacity(0.72), in: Capsule())
        .foregroundStyle(.white)
    }
}

struct CalibrationScreen: View {
    @ObservedObject var viewModel: HockeyScoreboardViewModel
    @ObservedObject private var ocrCameraService: HockeyCameraService
    @ObservedObject private var ocrDiagnostics: OCRDiagnosticsStore
    @ObservedObject private var externalOCRMultiCamState: ExternalOCRMultiCamUIState
    @StateObject private var calibrationRuntime: CalibrationRuntimeViewModel
    @StateObject private var ocrCameraSettingsViewModel: OCRCameraSettingsViewModel
    @State private var orientation: UIDeviceOrientation = .landscapeLeft
    @State private var showingSettings = false
    @State private var showingTemplateSettings = false
    @State private var showingTestOCRPanel = false
    @State private var showingCalibrationHub = false
    @State private var calibrationHubInitialPage: CalibrationControlHubPage = .zones
    @State private var calibrationToolsVisible = true
    @State private var calibrationToolsMounted = true
    @State private var screenAlignmentEditorVisible = false
    @State private var selectedAlignmentCorner: BoardAlignmentCorner = .topLeft
    @State private var diagnosticsPanelEnabled = false
    @State private var zoneEditMode: CalibrationZoneEditMode = .single
    @State private var selectedPenaltyGroup: PenaltyZoneGroupID = .homePenalty1
    @State private var lastLayoutBreadcrumbAt: CFAbsoluteTime = 0
    @State private var zoneInteractionSuppressedUntil: CFAbsoluteTime = 0
    @State private var zoneInteractionSuppressionTick = 0
    @State private var zoneInteractionEpoch = 0
    private let onReturnToCommandCentre: (() -> Void)?

    init(viewModel: HockeyScoreboardViewModel, onReturnToCommandCentre: (() -> Void)? = nil) {
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._ocrCameraService = ObservedObject(wrappedValue: viewModel.ocrCameraService)
        self._ocrDiagnostics = ObservedObject(wrappedValue: viewModel.ocrDiagnostics)
        self._externalOCRMultiCamState = ObservedObject(wrappedValue: viewModel.externalOCRMultiCamCoordinator.uiState)
        self._calibrationRuntime = StateObject(wrappedValue: CalibrationRuntimeViewModel())
        self._ocrCameraSettingsViewModel = StateObject(wrappedValue: OCRCameraSettingsViewModel(viewModel: viewModel))
        self.onReturnToCommandCentre = onReturnToCommandCentre
    }

    var body: some View {
        ZStack(alignment: .top) {
            calibrationPreviewHostLayer
            calibrationCameraWarningLayer

            CalibrationVideoAlignedLayer(
                    aspectRatio: calibrationVideoAspectRatio,
                    onViewportChange: { size in
                        if viewModel.previewViewportSize != size {
                            viewModel.setCalibrationPreviewViewportSize(size, reason: "CalibrationScreen.videoAlignedLayer")
                            MainThreadStallMonitor.shared.traceRenderPreviewToggle(
                                String(format: "Calibration video-aligned OCR viewport %.0fx%.0f", size.width, size.height)
                            )
                        }
                    }
                ) {
                    Group {
                        if viewModel.boardCalibration.zonesFollowPerspective {
                            PerspectiveCalibrationZonesOverlay(
                                layout: Binding(
                                    get: { viewModel.ocrLayout },
                                    set: { newValue in
                                        guard zoneEditorHitTestingEnabled else {
                                            MainThreadStallMonitor.shared.markContext("perspective OCR layout write blocked: \(zoneEditorStateText())")
                                            return
                                        }
                                        viewModel.ocrLayout = newValue
                                        viewModel.hasUnsavedTemplateChanges = true
                                    }
                                ),
                                selectedKey: Binding(
                                    get: { viewModel.selectedRegionKey },
                                    set: { viewModel.selectOCRRegion($0) }
                                ),
                                zoneEditMode: $zoneEditMode,
                                selectedPenaltyGroup: $selectedPenaltyGroup,
                                boardCalibration: viewModel.boardCalibration,
                                displayOptions: ocrDiagnostics.ocrDiagnosticDisplayOptions,
                                isEditable: zoneEditorHitTestingEnabled,
                                lockedKeys: calibrationRuntime.lockedRegionKeys
                            )
                        } else {
                            EditableRegionOverlay(
                                layout: Binding(
                                    get: { viewModel.ocrLayout },
                                    set: { newValue in
                                        guard zoneEditorHitTestingEnabled else {
                                            MainThreadStallMonitor.shared.markContext("ocr layout write blocked: \(zoneEditorStateText())")
                                            return
                                        }
                                        MainThreadStallMonitor.shared.markContext("ocr layout write accepted: \(zoneEditorStateText())")
                                        viewModel.ocrLayout = newValue
                                        if !viewModel.hasUnsavedTemplateChanges {
                                            viewModel.hasUnsavedTemplateChanges = true
                                        }
                                    }
                                ),
                                selectedKey: Binding(
                                    get: { viewModel.selectedRegionKey },
                                    set: { newValue in
                                        viewModel.selectOCRRegion(newValue)
                                        MainThreadStallMonitor.shared.markContext("zone selected: \(newValue.rawValue)")
                                    }
                                ),
                                zoneEditMode: $zoneEditMode,
                                selectedPenaltyGroup: $selectedPenaltyGroup,
                                previewText: ocrDiagnostics.regionOCRPreview,
                                recognizerByRegion: ocrDiagnostics.regionOCRRecognizer,
                                fieldConfidence: ocrDiagnostics.ocrFieldConfidence,
                                displayOptions: ocrDiagnostics.ocrDiagnosticDisplayOptions,
                                detectionStates: ocrDiagnostics.regionDetectionStates,
                                interactionEpoch: zoneInteractionEpoch,
                                isEditable: zoneEditorHitTestingEnabled,
                                lockedKeys: calibrationRuntime.lockedRegionKeys,
                                onReassign: { _, _ in }
                            )
                        }
                    }
                    .clipShape(Rectangle())
                }
                .opacity(calibrationToolsVisible && viewModel.operatingMode != .manual && !screenAlignmentEditorVisible ? 1 : 0)
                .allowsHitTesting(zoneEditorHitTestingEnabled && viewModel.operatingMode != .manual && !screenAlignmentEditorVisible)
                .animation(nil, value: calibrationToolsVisible)
                .onAppear {
                    MainThreadStallMonitor.shared.traceRenderPreviewToggle("Calibration OCR zone overlay appeared in shared video viewport")
                    MainThreadStallMonitor.shared.markContext("zone editor shown")
                }
                .onDisappear {
                    MainThreadStallMonitor.shared.traceRenderPreviewToggle("Calibration OCR zone overlay disappeared")
                    MainThreadStallMonitor.shared.markContext("zone editor hidden")
                }
                .zIndex(90)

            CalibrationVideoAlignedLayer(aspectRatio: calibrationVideoAspectRatio) {
                Rectangle()
                    .fill(Color.clear)
            }
            .allowsHitTesting(false)
            .zIndex(12)

            if screenAlignmentEditorVisible {
                CalibrationVideoAlignedLayer(aspectRatio: calibrationVideoAspectRatio) {
                    BoardAlignmentEditorOverlay(
                        boardCalibration: Binding(
                            get: { viewModel.boardCalibration },
                            set: { newValue in
                                viewModel.boardCalibration = newValue
                                viewModel.hasUnsavedTemplateChanges = true
                            }
                        ),
                        selectedCorner: $selectedAlignmentCorner
                    )
                }
                .allowsHitTesting(true)
                .zIndex(1_000)

                VStack {
                    BoardAlignmentControlBar(
                        selectedCorner: $selectedAlignmentCorner,
                        onReset: resetScreenAlignmentFrame,
                        onDone: {
                            screenAlignmentEditorVisible = false
                            calibrationRuntime.setGuidedAssistantVisible(true)
                            MainThreadStallMonitor.shared.markContext("screen alignment editor completed from detached control bar")
                        }
                    )
                    .padding(.horizontal, 190)
                    .padding(.top, 34)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(true)
                .zIndex(1_100)
            }

            if calibrationToolsVisible && viewModel.operatingMode != .manual && !screenAlignmentEditorVisible {
                VStack(alignment: .trailing, spacing: 8) {
                    if calibrationRuntime.guidedAssistantVisible {
                        GuidedCalibrationAssistantPanel(
                            viewModel: viewModel,
                            runtime: calibrationRuntime,
                            onNudge: { horizontalPixels, verticalPixels in
                                nudgeSelectedCalibrationZone(horizontalPixels: horizontalPixels, verticalPixels: verticalPixels)
                            },
                            onResize: { widthPixels, heightPixels in
                                resizeSelectedCalibrationZone(widthPixels: widthPixels, heightPixels: heightPixels)
                            },
                            onApplySuggestedOrientation: applySuggestedCalibrationOrientation,
                            onResetLocalZoneAngle: resetSelectedCalibrationZoneAngle
                        )
                    } else {
                        GuidedCalibrationAssistantRestoreButton(runtime: calibrationRuntime)
                    }

                    CalibrationScreenAlignmentToggleButton(
                        isActive: false,
                        action: toggleScreenAlignmentEditor
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 76)
                .padding(.trailing, 18)
                .zIndex(740)
            }


            if viewModel.operatingMode != .manual && viewModel.calibrationCameraControlsVisibleW10F && !screenAlignmentEditorVisible {
                HStack {
                    Spacer()
                    CalibrationZoomSlider(
                        zoom: Binding(
                            get: { calibrationRuntime.cameraZoomFactor },
                            set: { newZoom in
                                calibrationRuntime.setCameraZoomDraft(newZoom)
                                viewModel.setOCRCameraZoom(newZoom)
                            }
                        ),
                        minZoom: calibrationRuntime.minZoomFactor,
                        maxZoom: calibrationRuntime.maxZoomFactor
                    )
                    .padding(.trailing, 10)
                    .padding(.bottom, 52)
                    .background(
                        GeometryReader { zoomProxy in
                            Color.clear
                                .onAppear {
                                    let frame = zoomProxy.frame(in: .global)
                                    let line = String(
                                        format: "UX14s geometry zoom appear frame=%.0f,%.0f %.0fx%.0f zonesVisible=%@ zIndex=700",
                                        frame.minX,
                                        frame.minY,
                                        frame.width,
                                        frame.height,
                                        calibrationToolsVisible ? "true" : "false"
                                    )
                                    OCRChromeGeometryDiagnosticsStore.shared.noteZoom(line)
                                    MainThreadStallMonitor.shared.markContext(line)
                                }
                                .onChange(of: zoomProxy.size) { _, _ in
                                    let frame = zoomProxy.frame(in: .global)
                                    let line = String(
                                        format: "UX14s geometry zoom size-change frame=%.0f,%.0f %.0fx%.0f zonesVisible=%@ zIndex=700",
                                        frame.minX,
                                        frame.minY,
                                        frame.width,
                                        frame.height,
                                        calibrationToolsVisible ? "true" : "false"
                                    )
                                    OCRChromeGeometryDiagnosticsStore.shared.noteZoom(line)
                                    MainThreadStallMonitor.shared.markContext(line)
                                }
                        }
                    )
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
                .zIndex(700)
            }

            CalibrationTopOCRChromeOverlay(
                viewModel: viewModel,
                runtime: calibrationRuntime,
                ocrDiagnostics: ocrDiagnostics,
                aspectRatio: calibrationChromeAspectRatio,
                showingTestOCRPanel: showingTestOCRPanel,
                onReturnToCommandCentre: commandCentreReturnAction,
                onRunTestOCR: { runSelectedZoneTestOCR(source: "top letterbox calibration chrome strip") },
                onCloseTestOCRPanel: {
                    showingTestOCRPanel = false
                    diagnosticsPanelEnabled = true
                    viewModel.setOCRDiagnosticsVisible(true)
                    calibrationRuntime.setDiagnosticsVisible(true)
                    MainThreadStallMonitor.shared.markContext("top letterbox Test OCR image panel closed; live OCR diagnostics remain visible")
                },
                zonesVisible: calibrationToolsVisible,
                onOpenZones: { openCalibrationHub(.zones) },
                onOpenOCR: { openCalibrationHub(.ocr) },
                onOpenColour: { openCalibrationHub(.colour) },
                onOpenCameraControls: { showingSettings = true },
                onSaveZonesToDefault: {
                    viewModel.saveCurrentZonesToDefaultTemplate()
                    return viewModel.statusMessage ?? "Zone save completed."
                },
                onShowZones: showZoneEditorFromCameraMenu,
                onHideZones: hideZoneEditorFromInlinePicker
            )
            .allowsHitTesting(!screenAlignmentEditorVisible)
            .zIndex(260)

            CalibrationLetterboxBandLayer(
                aspectRatio: calibrationChromeAspectRatio,
                band: .bottom,
                minimumHeight: 124
            ) { bandHeight in
                let diagnosticsNudgeDown: CGFloat = 9
                let bottomInset = Swift.max(6, Swift.min(10, bandHeight * 0.07))
                let rowReserve: CGFloat = 44
                let rowSpacing = Swift.max(3, Swift.min(5, bandHeight * 0.05))

                VStack(alignment: .leading, spacing: rowSpacing) {
                    if viewModel.operatingMode != .manual {
                        CalibrationLiveOCRDiagnosticsPill(
                            viewModel: viewModel,
                            ocrDiagnostics: ocrDiagnostics,
                            availableHeight: Swift.max(50, bandHeight - rowReserve - bottomInset - rowSpacing - diagnosticsNudgeDown)
                        )
                        .padding(.horizontal, 8)
                        .allowsHitTesting(false)
                    } else {
                        Text("Manual scoreboard input — Image Relay calibration is retained but hidden")
                            .font(.caption.bold())
                            .foregroundStyle(.white.opacity(0.82))
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, maxHeight: Swift.max(50, bandHeight - rowReserve), alignment: .leading)
                    }

                    HStack(alignment: .bottom, spacing: 8) {
                        if calibrationToolsVisible && viewModel.operatingMode != .manual {
                            CalibrationZoneQuickPicker(
                                selectedKey: Binding(
                                    get: { viewModel.selectedRegionKey },
                                    set: { newValue in
                                        viewModel.selectOCRRegion(newValue)
                                        MainThreadStallMonitor.shared.markContext("zone selected: \(newValue.rawValue)")
                                    }
                                ),
                                editMode: $zoneEditMode,
                                selectedPenaltyGroup: $selectedPenaltyGroup,
                                calibratedColourKeys: Set(OCRRegionKey.calibrationCases.filter {
                                    viewModel.ocrColourProfiles.profile(for: $0).isColourCalibrated
                                }),
                                onHideZones: hideZoneEditorFromInlinePicker,
                                onOpenTestOCR: { runSelectedZoneTestOCR(source: "inline picker") }
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .layoutPriority(1)
                             .padding(.leading, 8)
                        } else {
                            Spacer(minLength: 12)
                        }

                        CalibrationOCRRunControlStrip(viewModel: viewModel, runtime: calibrationRuntime)
                             .padding(.trailing, 8)
                            .layoutPriority(0)
                    }
                }
                .padding(.top, diagnosticsNudgeDown)
                .padding(.bottom, bottomInset)
                .frame(maxWidth: .infinity, minHeight: bandHeight, maxHeight: bandHeight, alignment: .bottomLeading)
                .clipped()
                .onAppear {
                    MainThreadStallMonitor.shared.markContext("UX14z bottom OCR chrome stable height: diagnostics pill nudged down and no longer clips before zones are shown")
                }
            }
            .allowsHitTesting(!screenAlignmentEditorVisible)
            .zIndex(130)
        }
        .onAppear {
            viewModel.setCalibrationPhaseOverrideVisible(calibrationToolsVisible && viewModel.calibrationPreviewMountAllowedW10F)
            let started = MainThreadStallMonitor.shared.beginTimedOperation("CalibrationScreen.onAppear")
            MainThreadStallMonitor.shared.markContext("CalibrationScreen onAppear enter")
            if RinkLensRiskFeaturePolicy.isEnabled(.persistentCalibrationOverlayV22) {
                MainThreadStallMonitor.shared.trace("Build 741 Calibration preserves owner-held rotation and persistent overlay mount")
            }
            viewModel.prepareSafeCalibrationStartupStateW10F(reason: "CalibrationScreen.onAppear")
            calibrationRuntime.start(source: viewModel)
            enterFastCalibrationMode()
            MainThreadStallMonitor.shared.trace(
                usesFrameHubOCRPreview
                    ? "Recovery AO OCR FrameHub preview authority mounted"
                    : "Recovery AO OCR FrameHub preview waiting for configured OCR branch"
            )
            MainThreadStallMonitor.shared.endTimedOperation("CalibrationScreen.onAppear", startedAt: started)
        }
        // v0.9.1l: keep full session recovery manual, but allow lightweight stale
        // preview reattach health checks so calibration does not require repeated
        // manual recover taps after hub/sheet transitions.
        .onChange(of: viewModel.ocrOperationalStatus) { _, newStatus in
            AppContainer.shared.runtimeStatus.markOCRSetupVisible(
                templateName: viewModel.activeTemplateName,
                operationalStatus: newStatus
            )
        }
        .onDisappear {
            viewModel.setCalibrationPhaseOverrideVisible(false)
            let started = MainThreadStallMonitor.shared.beginTimedOperation("CalibrationScreen.onDisappear")
            leaveFastCalibrationMode()
            calibrationRuntime.stop()
            MainThreadStallMonitor.shared.endTimedOperation("CalibrationScreen.onDisappear", startedAt: started)
        }
        .onChange(of: viewModel.ocrLayout) { oldLayout, newLayout in
            viewModel.hasUnsavedTemplateChanges = true
            viewModel.invalidateOCRFieldsAfterLayoutChange(from: oldLayout, to: newLayout)
            traceLayoutChangeIfUseful(from: oldLayout, to: newLayout)
        }
        .onChange(of: viewModel.boardCalibration) { _, newCalibration in
            viewModel.hasUnsavedTemplateChanges = true
            MainThreadStallMonitor.shared.markContext(
                "screen alignment changed perspective=\(newCalibration.zonesFollowPerspective)"
            )
        }
        .onChange(of: calibrationToolsVisible) { _, isVisible in
            if isVisible {
                diagnosticsPanelEnabled = true
                calibrationRuntime.setDiagnosticsVisible(true)
                viewModel.setOCRDiagnosticsVisible(true)
                MainThreadStallMonitor.shared.markContext("zone editor shown")
                MainThreadStallMonitor.shared.markContext("overlay hit testing enabled")
                MainThreadStallMonitor.shared.markContext("calibration zones visible: live OCR diagnostics pill enabled")
                MainThreadStallMonitor.shared.markContext("calibration phase active: match-day OCR gating ignored while zones are visible")
                viewModel.setCalibrationPhaseOverrideVisible(viewModel.calibrationPreviewMountAllowedW10F)
                viewModel.updateFrameDeliveryPolicy(force: true)
            } else {
                diagnosticsPanelEnabled = true
                calibrationRuntime.setDiagnosticsVisible(true)
                viewModel.setOCRDiagnosticsVisible(true)
                MainThreadStallMonitor.shared.markContext("zone editor hidden")
                MainThreadStallMonitor.shared.markContext("overlay hit testing disabled")
                MainThreadStallMonitor.shared.markContext("UX14a zones hidden: live OCR diagnostics and Start/Stop remain visible")
                viewModel.setCalibrationPhaseOverrideVisible(false)
            }
        }
        .onChange(of: showingCalibrationHub) { _, isPresented in
            if !isPresented {
                diagnosticsPanelEnabled = true
                calibrationRuntime.setDiagnosticsVisible(true)
                viewModel.setOCRDiagnosticsVisible(true)
                MainThreadStallMonitor.shared.markContext("UX14a calibration hub dismissed: live OCR diagnostics pill and Start/Stop remain enabled")
                MainThreadStallMonitor.shared.traceRenderPreviewToggle("Recovery AO calibration hub dismissed: FrameHub preview remains event-driven; no preview recovery mutation")
                MainThreadStallMonitor.shared.markContext("zone interaction resumed: calibration hub dismissed")
            } else {
                MainThreadStallMonitor.shared.markContext("zone interaction paused: calibration hub presented")
            }
        }
        .sheet(isPresented: $showingSettings) {
            OCRCameraSettingsSheet(settingsViewModel: ocrCameraSettingsViewModel)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingTemplateSettings) {
            TemplateSettingsPanel(
                templates: viewModel.templateStore.templates,
                activeTemplateID: viewModel.activeTemplateID,
                activeTemplateName: viewModel.activeTemplateName,
                defaultTemplateID: viewModel.templateStore.defaultTemplateID,
                hasUnsavedChanges: viewModel.hasUnsavedTemplateChanges,
                onApplyTemplate: { template in
                    applyOCRTemplateForEditingWithoutPreviewMutation(template)
                    showZoneEditorAfterTemplateApply()
                },
                onSaveActiveTemplate: { venue, notes, image in
                    viewModel.saveActiveTemplate(venueName: venue ?? "", notes: notes ?? "", imageData: image)
                },
                onSaveAsNewTemplate: { name, venue, notes, image in
                    viewModel.saveAsNewTemplate(name: name, venueName: venue ?? "", notes: notes ?? "", imageData: image)
                },
                onRenameTemplate: { template, newName in viewModel.renameTemplate(template, newName: newName) },
                onDuplicateTemplate: { template, newName in viewModel.duplicateTemplate(template, newName: newName) },
                onDeleteTemplate: { viewModel.deleteTemplate($0) },
                onSetDefaultTemplate: { viewModel.setDefaultTemplate($0) }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingCalibrationHub) {
            CalibrationControlHubSheet(
                viewModel: viewModel,
                initialPage: calibrationHubInitialPage,
                calibrationToolsVisible: $calibrationToolsVisible,
                calibrationToolsMounted: $calibrationToolsMounted,
                diagnosticsPanelEnabled: $diagnosticsPanelEnabled,
                showingTestOCRPanel: $showingTestOCRPanel,
                onRunTestOCR: { source in
                    // UX13w: the working image tiles are inside this controls sheet,
                    // but the operator asked for the Raw / Proc / Thresh images to sit
                    // on the camera top strip. Dismiss the sheet before arming Test OCR
                    // so the camera-top panel is actually visible, not hidden behind the
                    // modal controls UI.
                    showingCalibrationHub = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                        runSelectedZoneTestOCR(source: "\(source) - hub dismissed to reveal camera top image strip")
                    }
                },
                onOpenTemplateSettings: { showingTemplateSettings = true }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.scrolls)
        }
    }

    private var multiCamSnapshot: RinkLensCaptureEngineSnapshot {
        externalOCRMultiCamState.snapshot
    }

    private var usesFrameHubOCRPreview: Bool {
        let mode = multiCamSnapshot.captureModeText
        let includesOCR = mode == RinkLensCaptureLifecycleMode.dualCamera.rawValue
            || mode == RinkLensCaptureLifecycleMode.ocrOnly.rawValue
        return includesOCR
            && (multiCamSnapshot.isActive
                || multiCamSnapshot.isTransitioning
                || multiCamSnapshot.sessionConfigured)
    }

    @ViewBuilder
    private var calibrationPreviewHostLayer: some View {
        if viewModel.calibrationPreviewMountAllowedW10F
            && usesFrameHubOCRPreview {
            CalibrationVideoAlignedLayer(aspectRatio: calibrationVideoAspectRatio) {
                OCRFrameHubPreviewView(
                    expectedGeneration: multiCamSnapshot.transitionGeneration,
                    expectedDeviceID: multiCamSnapshot.ocrDeviceID,
                    rotationDegrees: calibrationRuntime.ocrPreviewRotationOffsetDegrees
                )
                .clipped()
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        } else {
            Color.black
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var calibrationCameraWarningLayer: some View {
        if viewModel.calibrationCameraStartupLoadingW10F {
            CameraNotSelectedOverlay(
                title: "Preparing Calibration camera",
                message: "Refreshing OCR / Calibration camera list. The preview and zoom controls will appear once a valid camera is selected and running."
            )
            .allowsHitTesting(false)
            .zIndex(10)
        } else if viewModel.calibrationCameraStartupBlockedW10F {
            CameraNotSelectedOverlay(
                title: "Camera list not ready",
                message: "Camera list not ready — tap Refresh Cameras, then select an external or separate built-in Calibration camera."
            )
            .allowsHitTesting(false)
            .zIndex(10)
        } else if viewModel.calibrationCameraSharingConflictActive || viewModel.calibrationCameraUnavailableBecauseSharedWithBroadcast {
            CameraNotSelectedOverlay(
                title: viewModel.calibrationCameraConflictTitle,
                message: viewModel.calibrationCameraConflictMessage
            )
            .allowsHitTesting(false)
            .zIndex(10)
        } else if !usesFrameHubOCRPreview {
            CameraNotSelectedOverlay(
                title: "Scoreboard capture branch unavailable",
                message: "The single CaptureEngine has no OCR branch. Open Camera, refresh cameras, choose the OCR camera, then use Recover Camera."
            )
            .allowsHitTesting(false)
            .zIndex(10)
        }
    }


    private var calibrationVideoAspectRatio: CGFloat {
        let formatText = usesFrameHubOCRPreview
            ? multiCamSnapshot.ocrFormatText
            : ocrCameraService.activeCameraFormatDetailsText
        return Self.videoAspectRatio(from: formatText)
    }

    private var calibrationChromeAspectRatio: CGFloat {
        // UX14l/UX14p: keep the taller visual OCR chrome for the top and bottom pills.
        // UX14q correction: this aspect ratio must NOT drive zone/crop calibration.
        // Zones and Test OCR crops now use calibrationVideoAspectRatio so the green box
        // and Raw/Proc/Thresh preview are mapped to the same real camera image.
        calibrationVideoAspectRatio
    }

    private static func videoAspectRatio(from details: String) -> CGFloat {
        let pattern = #"(\d+)x(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: details, range: NSRange(details.startIndex..., in: details)),
              match.numberOfRanges >= 3,
              let widthRange = Range(match.range(at: 1), in: details),
              let heightRange = Range(match.range(at: 2), in: details),
              let width = Double(details[widthRange]),
              let height = Double(details[heightRange]),
              width > 0,
              height > 0 else {
            return 16.0 / 9.0
        }

        // Calibration is a landscape camera screen. Some iPad/external-camera
        // formats are reported as 1080x1920 even though the preview is rotated
        // landscape. Using width/height directly collapses the top/bottom
        // letterbox to zero and lets OCR chrome drift into the camera image.
        // Normalize to the landscape ratio so the top Test OCR image pill and
        // bottom diagnostics/selector always use the real black letterbox bands.
        let longEdge = Swift.max(width, height)
        let shortEdge = Swift.min(width, height)
        return CGFloat(longEdge / shortEdge)
    }

    private func showZoneEditorFromCameraMenu() {
        calibrationToolsMounted = true
        calibrationToolsVisible = true
        diagnosticsPanelEnabled = true
        calibrationRuntime.setDiagnosticsVisible(true)
        viewModel.setOCRDiagnosticsVisible(true)
        MainThreadStallMonitor.shared.markContext("zone editor shown")
        MainThreadStallMonitor.shared.markContext("overlay hit testing enabled")
        MainThreadStallMonitor.shared.markContext("camera menu: zones shown - live OCR diagnostics pill enabled")
        MainThreadStallMonitor.shared.markContext("camera menu: zones shown - calibration phase override active")
        viewModel.updateFrameDeliveryPolicy(force: true)
    }

    private func hideZoneEditorFromInlinePicker() {
        calibrationToolsVisible = false
        diagnosticsPanelEnabled = true
        calibrationRuntime.setDiagnosticsVisible(true)
        viewModel.setOCRDiagnosticsVisible(true)
        MainThreadStallMonitor.shared.markContext("zone editor hidden")
        MainThreadStallMonitor.shared.markContext("overlay hit testing disabled")
        MainThreadStallMonitor.shared.markContext("calibration inline picker: zones hidden; OCR diagnostics and Start/Stop stay visible")
    }

    private func runSelectedZoneTestOCR(source: String) {
        // UX16d15j Build 525: Verify Zone reads one current FrameHub OCR frame
        // with the same bounded decoder as continuous OCR. Recognition is diagnostics-
        // only; the separate Apply Manual button is the only correction path.
        MainThreadStallMonitor.shared.markContext("test OCR requested: \(source) \(selectedRegionLayoutText())")
        MainThreadStallMonitor.shared.markContext("test OCR transition state: \(zoneEditorStateText())")
        suppressZoneInteraction(for: 0.10, reason: "test OCR button pressed: \(source)")
        diagnosticsPanelEnabled = true
        showingTestOCRPanel = true
        calibrationRuntime.setDiagnosticsVisible(true)
        viewModel.setOCRDiagnosticsVisible(true)
        viewModel.selectedRegionPreviewStatus = "Opening Test OCR image panel for selected crop..."
        MainThreadStallMonitor.shared.markContext("UX14a test OCR panel opened immediately; crop processing deferred one tick: \(source)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            viewModel.requestCalibrationOCRTest(source: source)
            viewModel.updateFrameDeliveryPolicy(force: true)
            MainThreadStallMonitor.shared.markContext("UX14a test OCR armed after UI redraw: \(source) \(selectedRegionLayoutText())")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            MainThreadStallMonitor.shared.markContext("test OCR 0.35s check: \(source) \(selectedRegionLayoutText())")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.1) {
            MainThreadStallMonitor.shared.markContext("test OCR finished: \(source)")
        }
    }

    private func traceLayoutChangeIfUseful(from oldLayout: ScoreboardOCRLayout, to newLayout: ScoreboardOCRLayout) {
        let changed = OCRRegionKey.calibrationCases.compactMap { key -> String? in
            let old = oldLayout[key]
            let new = newLayout[key]
            guard old != new else { return nil }
            return String(
                format: "%@ %.4f,%.4f -> %.4f,%.4f",
                key.rawValue,
                Double(old.x),
                Double(old.y),
                Double(new.x),
                Double(new.y)
            )
        }
        guard !changed.isEmpty else { return }

        let now = CFAbsoluteTimeGetCurrent()
        let shouldLog = now - lastLayoutBreadcrumbAt > 0.25 || changed.count > 1
        guard shouldLog else { return }
        lastLayoutBreadcrumbAt = now
        MainThreadStallMonitor.shared.markContext("ocr layout changed: \(changed.prefix(3).joined(separator: " | ")) \(zoneEditorStateText())")
    }

    private func selectedRegionLayoutText() -> String {
        let key = viewModel.selectedRegionKey
        let region = viewModel.ocrLayout[key]
        return String(
            format: "selected=%@ x=%.4f y=%.4f w=%.4f h=%.4f",
            key.rawValue,
            Double(region.x),
            Double(region.y),
            Double(region.width),
            Double(region.height)
        )
    }

    private var zoneEditorHitTestingEnabled: Bool {
        _ = zoneInteractionSuppressionTick
        return calibrationToolsVisible &&
        !screenAlignmentEditorVisible &&
        !showingCalibrationHub &&
        CFAbsoluteTimeGetCurrent() >= zoneInteractionSuppressedUntil &&
        ocrDiagnostics.ocrDiagnosticDisplayOptions.showOCRBoxes
    }

    private func zoneEditorStateText() -> String {
        let suppressionRemaining = max(0, zoneInteractionSuppressedUntil - CFAbsoluteTimeGetCurrent())
        return String(
            format: "selected=%@ mode=%@ visible=%@ hub=%@ testPanel=%@ boxes=%@ suppress=%.2fs epoch=%d",
            viewModel.selectedRegionKey.rawValue,
            zoneEditMode.rawValue,
            String(calibrationToolsVisible),
            String(showingCalibrationHub),
            String(showingTestOCRPanel),
            String(ocrDiagnostics.ocrDiagnosticDisplayOptions.showOCRBoxes),
            Double(suppressionRemaining),
            zoneInteractionEpoch
        )
    }

    private func suppressZoneInteraction(for seconds: TimeInterval, reason: String) {
        zoneInteractionSuppressedUntil = CFAbsoluteTimeGetCurrent() + seconds
        invalidateZoneInteraction(reason: reason)
        MainThreadStallMonitor.shared.markContext("zone interaction suppressed: \(reason)")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            zoneInteractionSuppressionTick += 1
            MainThreadStallMonitor.shared.markContext("zone interaction suppression expired: \(reason)")
        }
    }

    private func openCalibrationHub(_ page: CalibrationControlHubPage) {
        MainThreadStallMonitor.shared.markContext("Calibration hub open requested: \(page.rawValue) \(selectedRegionLayoutText())")
        calibrationHubInitialPage = page
        showingCalibrationHub = true
        MainThreadStallMonitor.shared.markContext("Calibration hub opening gate armed: \(page.rawValue)")

        if showingTestOCRPanel {
            suppressZoneInteraction(for: 0.90, reason: "opening \(page.rawValue) controls")
            showingTestOCRPanel = false
        }
        diagnosticsPanelEnabled = true
        calibrationRuntime.setDiagnosticsVisible(true)
        viewModel.setOCRDiagnosticsVisible(true)

        MainThreadStallMonitor.shared.markContext("Calibration hub opened: \(page.rawValue)")
    }

    private func invalidateZoneInteraction(reason: String) {
        zoneInteractionEpoch += 1
        zoneInteractionSuppressionTick += 1
        MainThreadStallMonitor.shared.markContext("zone interaction invalidated: \(reason)")
    }


    private func toggleScreenAlignmentEditor() {
        if screenAlignmentEditorVisible {
            screenAlignmentEditorVisible = false
            calibrationRuntime.setGuidedAssistantVisible(true)
            MainThreadStallMonitor.shared.markContext("screen alignment editor hidden; perspective mapping remains active")
            return
        }

        migrateZonesToPerspectiveIfNeeded()
        selectedAlignmentCorner = .topLeft
        calibrationToolsMounted = true
        calibrationToolsVisible = true
        calibrationRuntime.setGuidedAssistantVisible(false)
        screenAlignmentEditorVisible = true
        MainThreadStallMonitor.shared.markContext("screen alignment editor shown; OCR and Image Relay zones follow board quad")
    }

    private func migrateZonesToPerspectiveIfNeeded() {
        guard !viewModel.boardCalibration.zonesFollowPerspective else { return }

        var quad = viewModel.boardCalibration
        if !BoardPerspectiveMapper.isUsable(quad) {
            quad = BoardCalibrationQuad()
        }

        var migrated = viewModel.ocrLayout
        for key in OCRRegionKey.calibrationCases {
            let existing = migrated[key]
            guard let boardRect = BoardPerspectiveMapper.inverseBoundingRect(of: existing.rect, through: quad) else {
                continue
            }
            migrated[key] = OCRRegion(
                x: boardRect.minX,
                y: boardRect.minY,
                width: boardRect.width,
                height: boardRect.height,
                rotationDegrees: existing.rotationDegrees
            )
        }

        quad.zonesFollowPerspective = true
        viewModel.ocrLayout = migrated
        viewModel.boardCalibration = quad
        viewModel.hasUnsavedTemplateChanges = true
        viewModel.statusMessage = "Screen alignment enabled. Existing Build 663 zones were migrated into the scoreboard frame."
        MainThreadStallMonitor.shared.markContext("Build 665 one-time zone migration: preview coordinates -> rectified board coordinates")
    }

    private func resetScreenAlignmentFrame() {
        viewModel.boardCalibration = BoardCalibrationQuad(zonesFollowPerspective: true)
        selectedAlignmentCorner = .topLeft
        viewModel.hasUnsavedTemplateChanges = true
        viewModel.statusMessage = "Screen alignment frame reset. Drag its four corners around the scoreboard display."
        MainThreadStallMonitor.shared.markContext("screen alignment frame reset")
    }

    private func nudgeSelectedCalibrationZone(horizontalPixels: CGFloat, verticalPixels: CGFloat) {
        let key = viewModel.selectedRegionKey
        guard !calibrationRuntime.isRegionLocked(key) else {
            MainThreadStallMonitor.shared.markContext("guided calibration nudge blocked: locked zone \(key.rawValue)")
            return
        }
        let frameWidth = max(1, calibrationRuntime.calibrationQuality.frameWidth)
        let frameHeight = max(1, calibrationRuntime.calibrationQuality.frameHeight)
        var layout = viewModel.ocrLayout
        var region = layout[key]
        let before = region
        region.x = clamp(region.x + horizontalPixels / CGFloat(frameWidth), min: 0, max: 1 - region.width)
        region.y = clamp(region.y + verticalPixels / CGFloat(frameHeight), min: 0, max: 1 - region.height)
        guard region != before else { return }
        layout[key] = region
        viewModel.ocrLayout = layout
        MainThreadStallMonitor.shared.markContext("guided calibration nudge: \(key.rawValue) dx=\(Int(horizontalPixels))px dy=\(Int(verticalPixels))px")
    }

    private func resizeSelectedCalibrationZone(widthPixels: CGFloat, heightPixels: CGFloat) {
        let key = viewModel.selectedRegionKey
        guard !calibrationRuntime.isRegionLocked(key) else {
            MainThreadStallMonitor.shared.markContext("guided calibration resize blocked: locked zone \(key.rawValue)")
            return
        }
        let frameWidth = max(1, calibrationRuntime.calibrationQuality.frameWidth)
        let frameHeight = max(1, calibrationRuntime.calibrationQuality.frameHeight)
        var layout = viewModel.ocrLayout
        var region = layout[key]
        let before = region
        let centreX = region.x + region.width / 2
        let centreY = region.y + region.height / 2
        let minimumWidth = max(0.0025, 2 / CGFloat(frameWidth))
        let minimumHeight = max(0.0025, 2 / CGFloat(frameHeight))
        let newWidth = clamp(region.width + widthPixels / CGFloat(frameWidth), min: minimumWidth, max: min(1, centreX * 2, (1 - centreX) * 2))
        let newHeight = clamp(region.height + heightPixels / CGFloat(frameHeight), min: minimumHeight, max: min(1, centreY * 2, (1 - centreY) * 2))
        region.width = newWidth
        region.height = newHeight
        region.x = clamp(centreX - newWidth / 2, min: 0, max: 1 - newWidth)
        region.y = clamp(centreY - newHeight / 2, min: 0, max: 1 - newHeight)
        guard region != before else { return }
        layout[key] = region
        viewModel.ocrLayout = layout
        MainThreadStallMonitor.shared.markContext("guided calibration resize: \(key.rawValue) dw=\(Int(widthPixels))px dh=\(Int(heightPixels))px")
    }

    private func resetSelectedCalibrationZoneAngle() {
        let key = viewModel.selectedRegionKey
        guard !calibrationRuntime.isRegionLocked(key) else { return }
        var layout = viewModel.ocrLayout
        var region = layout[key]
        guard abs(region.rotationDegrees) > 0.01 else { return }
        region.rotationDegrees = 0
        layout[key] = region
        viewModel.ocrLayout = layout
        viewModel.hasUnsavedTemplateChanges = true
        calibrationRuntime.publishSnapshot(force: true)
        MainThreadStallMonitor.shared.markContext("selected zone local angle reset; Screen Align deskew remains authoritative: \(key.rawValue)")
    }

    private func applySuggestedCalibrationOrientation() {
        guard let suggested = calibrationRuntime.calibrationQuality.suggestedRotationDegrees else { return }
        viewModel.setOCRPreviewRotationDegrees(suggested)
        viewModel.setCameraRotationLockEnabled(true)
        calibrationRuntime.publishSnapshot(force: true)
        MainThreadStallMonitor.shared.markContext("guided calibration orientation applied and locked: \(Int(suggested)) degrees")
    }

    private func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        Swift.max(minValue, Swift.min(maxValue, value))
    }

    /// Loading an OCR/zone template from Calibration must only update the editable
    /// OCR layout and template metadata. It must not change preview orientation,
    /// camera ownership, camera lifecycle or preview session.
    private func applyOCRTemplateForEditingWithoutPreviewMutation(_ template: RinkTemplate) {
        let existingCalibrationRotation = viewModel.calibrationRotationDegrees
        let existingOCRPreviewRotation = viewModel.ocrPreviewRotationOffsetDegrees
        let existingLivePreviewRotation = viewModel.livePreviewRotationOffsetDegrees

        MainThreadStallMonitor.shared.markContext("zone template reloaded: editor only, preserve preview rotation")

        viewModel.applyTemplate(template)

        viewModel.calibrationRotationDegrees = existingCalibrationRotation
        viewModel.ocrPreviewRotationOffsetDegrees = existingOCRPreviewRotation
        viewModel.livePreviewRotationOffsetDegrees = existingLivePreviewRotation

        MainThreadStallMonitor.shared.trace(
            "OCR template loaded without preview rotation mutation | restored calibration=\(Int(existingCalibrationRotation)) ocr=\(Int(existingOCRPreviewRotation)) live=\(Int(existingLivePreviewRotation))"
        )
    }

    private func showZoneEditorAfterTemplateApply() {
        calibrationToolsMounted = true
        calibrationToolsVisible = true
        diagnosticsPanelEnabled = true
        calibrationRuntime.setDiagnosticsVisible(true)
        viewModel.setOCRDiagnosticsVisible(true)
        MainThreadStallMonitor.shared.notePublish(source: "zone template load auto-show editor")
        MainThreadStallMonitor.shared.markContext("zone editor shown")
        MainThreadStallMonitor.shared.markContext("overlay hit testing enabled")
        MainThreadStallMonitor.shared.markContext("zone template loaded - editor shown while OCR kept running")
        MainThreadStallMonitor.shared.markContext("zone template loaded - live OCR diagnostics pill enabled")
        viewModel.updateFrameDeliveryPolicy(force: true)
    }

    /// Calibration opens with the saved zones visible so the camera alignment is
    /// immediately reviewable. Operators may still hide them from the inline
    /// picker or Menu without stopping OCR or Image Relay.
    private func enterFastCalibrationMode() {
        calibrationToolsMounted = true
        calibrationToolsVisible = true
        diagnosticsPanelEnabled = true
        showingTestOCRPanel = false
        calibrationRuntime.setDiagnosticsVisible(true)
        viewModel.setOCRDiagnosticsVisible(true)
        MainThreadStallMonitor.shared.markContext("Build 613 Calibration opened with saved zones visible")
        MainThreadStallMonitor.shared.markContext("overlay hit testing enabled")
    }

    private var commandCentreReturnAction: (() -> Void)? {
        guard onReturnToCommandCentre != nil else { return nil }
        return { returnToCommandCentreAfterQuiescingEditor() }
    }

    private func returnToCommandCentreAfterQuiescingEditor() {
        // Build 715 removes the zone overlay and its hit-testing synchronously
        // before changing route. Camera/runtime shutdown remains in onDisappear,
        // so navigation is never blocked by a capture stop on the button tap.
        zoneInteractionSuppressedUntil = .greatestFiniteMagnitude
        calibrationToolsVisible = false
        calibrationToolsMounted = RinkLensRiskFeaturePolicy.isEnabled(.persistentCalibrationOverlayV22)
        screenAlignmentEditorVisible = false
        showingCalibrationHub = false
        showingTestOCRPanel = false
        diagnosticsPanelEnabled = false
        invalidateZoneInteraction(reason: "Scoreboard Setup route exit")
        MainThreadStallMonitor.shared.markContext("Build 715 OCR editor quiesced before route exit")
        onReturnToCommandCentre?()
    }

    private func leaveFastCalibrationMode() {
        calibrationToolsVisible = false
        calibrationToolsMounted = RinkLensRiskFeaturePolicy.isEnabled(.persistentCalibrationOverlayV22)
        screenAlignmentEditorVisible = false
        diagnosticsPanelEnabled = false
        showingTestOCRPanel = false
        calibrationRuntime.setDiagnosticsVisible(false)
        viewModel.setOCRDiagnosticsVisible(false)
        MainThreadStallMonitor.shared.markContext("calibration fast mode exited")
        MainThreadStallMonitor.shared.markContext("zone editor hidden")
        MainThreadStallMonitor.shared.markContext("overlay hit testing disabled")
    }

    private func checkPreviewAfterZoneToggle(delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let service = viewModel.ocrCameraService
            MainThreadStallMonitor.shared.traceRenderPreviewToggle(
                String(
                    format: "Preview check %.1fs after zone toggle | attached=%@ ready=%@ running=%@ frame=%@",
                    delay,
                    service.previewLayerAttached ? "Y" : "N",
                    service.previewLayerReadyForDisplay ? "Y" : "N",
                    service.isSessionRunning ? "Y" : "N",
                    service.previewLayerFrameText
                )
            )
        }
    }
}


private enum CalibrationLetterboxBand: Equatable {
    case top
    case bottom
}

private struct CalibrationLetterboxBandLayer<Content: View>: View {
    let aspectRatio: CGFloat
    let band: CalibrationLetterboxBand
    var minimumHeight: CGFloat = 0
    @ViewBuilder var content: (CGFloat) -> Content

    var body: some View {
        GeometryReader { proxy in
            let videoSize = Self.videoSize(container: proxy.size, aspectRatio: aspectRatio)
            let verticalBandHeight = Swift.max(0, (proxy.size.height - videoSize.height) / 2)
            let safeMinimum = Swift.min(Swift.max(0, minimumHeight), proxy.size.height * 0.24)
            // UX13w: when a chrome height is requested, honour that fixed visible band.
            // Earlier builds used the natural camera letterbox height and could still
            // leave the Test OCR image strip effectively hidden on iPad layouts or
            // behind the controls sheet. The black band is now the visible outside-camera
            // chrome area; camera/zone layers remain below it in z-order.
            let bandHeight = minimumHeight > 0 ? safeMinimum : verticalBandHeight
            let yPosition = band == .top ? bandHeight / 2 : proxy.size.height - (bandHeight / 2)

            content(bandHeight)
                .frame(
                    width: proxy.size.width,
                    height: bandHeight,
                    alignment: band == .top ? .topLeading : .bottomLeading
                )
                .background(Color.black.opacity(0.94))
                .clipped()
                .position(x: proxy.size.width / 2, y: yPosition)
        }
        .ignoresSafeArea()
    }

    private static func videoSize(container: CGSize, aspectRatio: CGFloat) -> CGSize {
        let safeAspect = Swift.max(0.2, Swift.min(5.0, aspectRatio))
        guard container.width > 1, container.height > 1 else { return .zero }
        let containerAspect = container.width / container.height
        if containerAspect > safeAspect {
            let height = container.height
            return CGSize(width: height * safeAspect, height: height)
        } else {
            let width = container.width
            return CGSize(width: width, height: width / safeAspect)
        }
    }
}

private struct CalibrationVideoAlignedLayer<Content: View>: View {
    let aspectRatio: CGFloat
    var onViewportChange: ((CGSize) -> Void)? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            let size = Self.videoSize(container: proxy.size, aspectRatio: aspectRatio)
            content()
                .frame(width: size.width, height: size.height)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                .onAppear { onViewportChange?(size) }
                .onChange(of: size) { _, newSize in
                    onViewportChange?(newSize)
                }
        }
        .ignoresSafeArea()
    }

    private static func videoSize(container: CGSize, aspectRatio: CGFloat) -> CGSize {
        let safeAspect = max(0.2, min(5.0, aspectRatio))
        guard container.width > 1, container.height > 1 else { return .zero }
        let containerAspect = container.width / container.height
        if containerAspect > safeAspect {
            let height = container.height
            return CGSize(width: height * safeAspect, height: height)
        } else {
            let width = container.width
            return CGSize(width: width, height: width / safeAspect)
        }
    }
}


private struct CalibrationTopOCRChromeOverlay: View {
    let viewModel: HockeyScoreboardViewModel
    @ObservedObject var runtime: CalibrationRuntimeViewModel
    @ObservedObject var ocrDiagnostics: OCRDiagnosticsStore
    let aspectRatio: CGFloat
    let showingTestOCRPanel: Bool
    let onReturnToCommandCentre: (() -> Void)?
    let onRunTestOCR: () -> Void
    let onCloseTestOCRPanel: () -> Void
    let zonesVisible: Bool
    let onOpenZones: () -> Void
    let onOpenOCR: () -> Void
    let onOpenColour: () -> Void
    let onOpenCameraControls: () -> Void
    let onSaveZonesToDefault: () -> String
    let onShowZones: () -> Void
    let onHideZones: () -> Void
    @State private var lastTopGeometryTraceAt: CFAbsoluteTime = 0
    @State private var zoneSaveConfirmation: String?
    @State private var zoneSaveConfirmationTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            let contentWidth = Swift.max(620, Swift.min(
                proxy.size.width - (RinkLensCommandCentreChrome.leadingInset * 2),
                RinkLensCommandCentreChrome.maximumOCRTopContentWidth
            ))
            let bandHeight = topLetterboxHeight(container: proxy.size, aspectRatio: aspectRatio)
            let safeTop = Swift.max(0, proxy.safeAreaInsets.top)
            let controlsHeight: CGFloat = 32
            let controlsWidth: CGFloat = 440
            let panelTop = Swift.max(RinkLensCommandCentreChrome.topInset, safeTop + 1)
            let controlsBottom: CGFloat = 2
            let availablePanelHeight = Swift.max(0, bandHeight - panelTop - controlsBottom)

            ZStack(alignment: .top) {
                HStack(alignment: .center, spacing: 10) {
                    if let onReturnToCommandCentre {
                        RinkLensCommandCentreReturnButton(action: onReturnToCommandCentre)
                            .frame(width: RinkLensCommandCentreChrome.buttonSlotWidth, alignment: .leading)
                    }

                    if showingTestOCRPanel, availablePanelHeight > 12 {
                        CalibrationSelectedOCRStatusPanel(
                            viewModel: viewModel,
                            ocrDiagnostics: ocrDiagnostics,
                            availableHeight: availablePanelHeight,
                            isVisible: showingTestOCRPanel,
                            onClose: onCloseTestOCRPanel,
                            onRequestManualMode: {
                                guard RinkLensRiskFeaturePolicy.isEnabled(.tapOCRPreviewEntersManualModeV7) else { return }
                                guard viewModel.operatingMode != .manual else { return }
                                viewModel.setOperatingMode(.manual)
                                runtime.publishSnapshot(force: true)
                                onCloseTestOCRPanel()
                                MainThreadStallMonitor.shared.markContext(
                                    "Build 722 OCR preview tapped: requested Manual mode through HockeyScoreboardViewModel and refreshed the injected calibration runtime"
                                )
                            }
                        )
                        .frame(
                            width: Swift.max(220, contentWidth - RinkLensCommandCentreChrome.buttonSlotWidth - controlsWidth - 20),
                            height: availablePanelHeight,
                            alignment: .center
                        )
                        .transition(.opacity)
                        .zIndex(322)
                    } else {
                        Spacer(minLength: 12)
                    }

                    if viewModel.operatingMode != .manual {
                        VStack(alignment: .trailing, spacing: 2) {
                            HStack(spacing: 8) {
                                CalibrationTopTestOCRButton(
                                isActive: showingTestOCRPanel,
                                action: onRunTestOCR
                            )

                            if viewModel.canApplyTestOCRResult {
                                CalibrationApplyTestOCRButton(
                                    title: viewModel.pendingTestOCRApplyDescription ?? "Apply",
                                    action: viewModel.applySelectedTestOCRResult
                                )
                            }

                            CalibrationSaveZonesButton(
                                isEnabled: viewModel.defaultZoneTemplateName != nil,
                                action: saveZonesAndConfirm
                            )

                            CalibrationCameraMenuButton(
                                zonesVisible: zonesVisible,
                                onOpenZones: onOpenZones,
                                onOpenOCR: onOpenOCR,
                                onOpenColour: onOpenColour,
                                onOpenCameraControls: onOpenCameraControls,
                                onSaveZonesToDefault: { _ = onSaveZonesToDefault() },
                                onShowZones: onShowZones,
                                onHideZones: onHideZones,
                                onRunTestOCR: onRunTestOCR
                            )
                        }

                        Text(zoneSaveConfirmation ?? defaultZoneStatusText)
                            .font(.system(size: 8.5, weight: zoneSaveConfirmation == nil ? .regular : .semibold))
                            .foregroundStyle(zoneSaveConfirmation == nil ? Color.white.opacity(0.54) : Color.green.opacity(0.92))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .frame(maxWidth: controlsWidth, alignment: .trailing)
                    }
                        .frame(width: controlsWidth, alignment: .trailing)
                    } else {
                        Spacer(minLength: controlsWidth)
                    }
                }
                .frame(width: contentWidth, height: availablePanelHeight, alignment: .center)
                .padding(.top, panelTop)
                .frame(width: proxy.size.width, height: bandHeight, alignment: .top)
                .zIndex(323)
            }
            .frame(width: proxy.size.width, height: bandHeight, alignment: .top)
            .background(Color.black.opacity(0.96))
            .clipped()
            .allowsHitTesting(true)
            .onAppear {
                traceTopOCRGeometry(
                    container: proxy.size,
                    safeTop: safeTop,
                    bandHeight: bandHeight,
                    contentWidth: contentWidth,
                    panelTop: panelTop,
                    controlsHeight: controlsHeight,
                    controlsBottom: controlsBottom,
                    availablePanelHeight: availablePanelHeight,
                    isShowing: showingTestOCRPanel,
                    reason: "appear"
                )
            }
            .onChange(of: showingTestOCRPanel) { _, isShowing in
                traceTopOCRGeometry(
                    container: proxy.size,
                    safeTop: safeTop,
                    bandHeight: bandHeight,
                    contentWidth: contentWidth,
                    panelTop: panelTop,
                    controlsHeight: controlsHeight,
                    controlsBottom: controlsBottom,
                    availablePanelHeight: availablePanelHeight,
                    isShowing: isShowing,
                    reason: isShowing ? "test-open" : "test-close"
                )
            }
            .onChange(of: proxy.size) { _, newSize in
                let newBandHeight = topLetterboxHeight(container: newSize, aspectRatio: aspectRatio)
                traceTopOCRGeometry(
                    container: newSize,
                    safeTop: safeTop,
                    bandHeight: newBandHeight,
                    contentWidth: Swift.max(620, Swift.min(
                        newSize.width - (RinkLensCommandCentreChrome.leadingInset * 2),
                        RinkLensCommandCentreChrome.maximumOCRTopContentWidth
                    )),
                    panelTop: panelTop,
                    controlsHeight: controlsHeight,
                    controlsBottom: controlsBottom,
                    availablePanelHeight: Swift.max(0, newBandHeight - panelTop - controlsBottom),
                    isShowing: showingTestOCRPanel,
                    reason: "size-change"
                )
            }
        }
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(true)
    }

    private func topLetterboxHeight(container: CGSize, aspectRatio: CGFloat) -> CGFloat {
        let safeAspect = Swift.max(0.2, Swift.min(5.0, aspectRatio))
        guard container.width > 1, container.height > 1 else { return 0 }
        let containerAspect = container.width / container.height
        let videoHeight: CGFloat
        if containerAspect > safeAspect {
            videoHeight = container.height
        } else {
            videoHeight = container.width / safeAspect
        }
        return Swift.max(0, (container.height - videoHeight) / 2)
    }

    private var defaultZoneStatusText: String {
        if let name = viewModel.defaultZoneTemplateName {
            return "Zone save target: \(name)"
        }
        return "No default zone profile — set one in Zone controls"
    }

    private func saveZonesAndConfirm() {
        zoneSaveConfirmationTask?.cancel()
        let result = onSaveZonesToDefault()
        zoneSaveConfirmation = result
        zoneSaveConfirmationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            zoneSaveConfirmation = nil
        }
    }

    private func traceTopOCRGeometry(
        container: CGSize,
        safeTop: CGFloat,
        bandHeight: CGFloat,
        contentWidth: CGFloat,
        panelTop: CGFloat,
        controlsHeight: CGFloat,
        controlsBottom: CGFloat,
        availablePanelHeight: CGFloat,
        isShowing: Bool,
        reason: String
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        guard reason != "size-change" || now - lastTopGeometryTraceAt > 0.75 else { return }
        lastTopGeometryTraceAt = now
        let line = String(
            format: "UX14q geometry top reason=%@ showing=%@ container=%.0fx%.0f topBand=%.1f safeTop=%.1f panelTop=%.1f panel=%.0fx%.1f controlsH=%.1f controlsBottom=%.1f stableRow=true",
            reason,
            isShowing ? "true" : "false",
            container.width,
            container.height,
            bandHeight,
            safeTop,
            panelTop,
            contentWidth,
            availablePanelHeight,
            controlsHeight,
            controlsBottom
        )
        OCRChromeGeometryDiagnosticsStore.shared.noteTop(line)
        MainThreadStallMonitor.shared.markContext(line)
    }
}

private struct CalibrationOCRRunControlStrip: View {
    @ObservedObject var viewModel: HockeyScoreboardViewModel
    @ObservedObject var runtime: CalibrationRuntimeViewModel

    var body: some View {
        HStack(spacing: 8) {
            modeControl

            Circle()
                .fill(statusColour)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(.white.opacity(0.65), lineWidth: 1))
                .accessibilityHidden(true)

            Text(statusText)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Button {
                guard viewModel.operatingMode != .manual else { return }
                guard !automaticInputIsPaused || viewModel.calibrationPreviewMountAllowedW10F else {
                    MainThreadStallMonitor.shared.trace("safe startup: automatic scoreboard input ignored until Calibration camera is selected and running")
                    return
                }
                if automaticInputIsPaused {
                    viewModel.startOCRFromCalibration()
                } else {
                    viewModel.stopOCRFromCalibration()
                }
                runtime.publishSnapshot(force: true)
            } label: {
                Label(
                    runButtonTitle,
                    systemImage: viewModel.scoreboardInputControlSystemImage
                )
                .symbolRenderingMode(.monochrome)
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
            }
            .disabled(runButtonDisabled)
            .background(runButtonBackground, in: Capsule())
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.black.opacity(0.72), in: Capsule())
    }


    private var modeControl: some View {
        Button(action: toggleInputMode) {
            Label(compactModeTitle, systemImage: compactModeIcon)
                .font(.caption.bold())
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(modeTint.opacity(0.86), in: Capsule())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            viewModel.operatingMode == .manual
                ? "Switch scoreboard input to Image Relay"
                : "Switch scoreboard input to Manual"
        )
        .accessibilityValue(viewModel.operatingMode.title)
    }

    private func toggleInputMode() {
        let previousMode = viewModel.operatingMode
        let nextMode: OperatingMode = previousMode == .manual ? .imageRelay : .manual
        selectMode(nextMode)
        MainThreadStallMonitor.shared.markContext(
            "Build 754 OCR input direct toggle previous=\(previousMode.rawValue) next=\(nextMode.rawValue) source=CalibrationOCRRunControlStrip reason=operator tapped compact mode control"
        )
    }

    private func selectMode(_ mode: OperatingMode) {
        guard viewModel.operatingMode != mode else { return }
        if mode == .manual {
            viewModel.setOperatingMode(mode)
        } else {
            viewModel.setOperatingMode(mode, autoStart: false)
        }
        runtime.publishSnapshot(force: true)
        MainThreadStallMonitor.shared.markContext("Calibration bottom control selected \(mode.rawValue) mode; automatic input remains stopped until operator start")
    }

    private var compactModeTitle: String {
        switch viewModel.operatingMode {
        case .ocr: return "IMAGE"
        case .imageRelay: return "IMAGE"
        case .manual: return "MANUAL"
        }
    }

    private var compactModeIcon: String {
        switch viewModel.operatingMode {
        case .ocr: return "rectangle.on.rectangle"
        case .imageRelay: return "rectangle.on.rectangle"
        case .manual: return "hand.tap"
        }
    }

    private var modeTint: Color {
        switch viewModel.operatingMode {
        case .ocr: return .cyan
        case .imageRelay: return .cyan
        case .manual: return .orange
        }
    }

    private var automaticInputIsPaused: Bool {
        // Read the authoritative ViewModel state directly. The previous control
        // used the 0.5-second Calibration snapshot, which could leave a stopped
        // Image Relay button visually red until a later refresh.
        viewModel.scoreboardInputControlIsPaused
    }

    private var runButtonTitle: String {
        viewModel.operatingMode == .manual ? "Manual" : viewModel.scoreboardInputControlTitle
    }

    private var runButtonDisabled: Bool {
        viewModel.operatingMode == .manual
            || viewModel.scoreboardInputControlIsTransitioning
    }

    private var runButtonBackground: Color {
        if viewModel.operatingMode == .manual { return Color.gray.opacity(0.70) }
        if viewModel.scoreboardInputControlIsPhysicallyRunning {
            return Color.green.opacity(0.88)
        }
        if viewModel.scoreboardInputControlIsRequestedOn {
            return Color.orange.opacity(0.82)
        }
        return Color.gray.opacity(0.70)
    }

    private var statusText: String {
        switch viewModel.operatingMode {
        case .ocr:
            return relayStatusText
        case .imageRelay:
            return relayStatusText
        case .manual:
            return "Automatic Input Off"
        }
    }

    private var statusColour: Color {
        switch viewModel.operatingMode {
        case .imageRelay:
            return relayStatusColour
        case .manual:
            return .orange
        case .ocr:
            return relayStatusColour
        }
    }

    private var relayStatusColour: Color {
        if viewModel.scoreboardInputControlIsPhysicallyRunning { return .green }
        if viewModel.scoreboardInputControlIsRequestedOn { return .orange }
        return .secondary
    }

    private var relayStatusText: String {
        if viewModel.scoreboardInputControlIsPhysicallyRunning {
            return "Image Relay On — processing"
        }
        if viewModel.scoreboardInputControlIsTransitioning,
           viewModel.scoreboardInputControlIsRequestedOn {
            return "Image Relay starting…"
        }
        if viewModel.scoreboardInputControlIsRequestedOn {
            return "Image Relay On — processing temporarily suspended on this route"
        }
        return "Image Relay Off"
    }
}

private struct CalibrationTopTestOCRButton: View {
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 10, weight: .semibold))
                Text("Verify Zone")
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isActive ? Color.cyan.opacity(0.88) : Color.black.opacity(0.76), in: Capsule())
        .foregroundStyle(isActive ? Color.black : Color.white)
        .overlay(Capsule().stroke(isActive ? Color.cyan.opacity(0.82) : Color.white.opacity(0.22), lineWidth: 1))
        .accessibilityLabel("Verify selected scoreboard zone without changing Broadcast")
    }
}

private struct CalibrationApplyTestOCRButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("Apply Manual")
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.orange.opacity(0.92), in: Capsule())
        .foregroundStyle(Color.black)
        .overlay(Capsule().stroke(Color.orange, lineWidth: 1))
        .accessibilityLabel(title)
    }
}

private struct CalibrationSaveZonesButton: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                Text("SAVE ZONES")
                    .font(.system(size: 10.5, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isEnabled ? Color.cyan.opacity(0.90) : Color.gray.opacity(0.52), in: Capsule())
        .foregroundStyle(isEnabled ? Color.black : Color.white.opacity(0.66))
        .overlay(Capsule().stroke(isEnabled ? Color.cyan : Color.white.opacity(0.16), lineWidth: 1))
        .disabled(!isEnabled)
        .accessibilityLabel("Save current calibration zones to the default profile")
    }
}

private struct CalibrationCameraMenuButton: View {
    let zonesVisible: Bool
    let onOpenZones: () -> Void
    let onOpenOCR: () -> Void
    let onOpenColour: () -> Void
    let onOpenCameraControls: () -> Void
    let onSaveZonesToDefault: () -> Void
    let onShowZones: () -> Void
    let onHideZones: () -> Void
    let onRunTestOCR: () -> Void
    @State private var showingMenu = false

    var body: some View {
        Button {
            showingMenu.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 10, weight: .semibold))
                Text("Menu")
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 28)
            .background(.black.opacity(0.76), in: Capsule())
            .foregroundStyle(.white)
            .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingMenu, arrowEdge: .top) {
            CalibrationCameraActionsPopover(
                zonesVisible: zonesVisible,
                onAction: runAfterClosing,
                onOpenZones: onOpenZones,
                onOpenOCR: onOpenOCR,
                onOpenColour: onOpenColour,
                onOpenCameraControls: onOpenCameraControls,
                onSaveZonesToDefault: onSaveZonesToDefault,
                onShowZones: onShowZones,
                onHideZones: onHideZones,
                onRunTestOCR: onRunTestOCR
            )
        }
        .accessibilityLabel("Open calibration camera menu")
    }

    private func runAfterClosing(_ action: @escaping () -> Void) {
        showingMenu = false
        // Do not ask SwiftUI to dismiss a system Menu and present a sheet in the
        // same render transaction. That overlap caused the visible camera flash.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            action()
        }
    }
}

private struct CalibrationCameraActionsPopover: View {
    let zonesVisible: Bool
    let onAction: (@escaping () -> Void) -> Void
    let onOpenZones: () -> Void
    let onOpenOCR: () -> Void
    let onOpenColour: () -> Void
    let onOpenCameraControls: () -> Void
    let onSaveZonesToDefault: () -> Void
    let onShowZones: () -> Void
    let onHideZones: () -> Void
    let onRunTestOCR: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Calibration Menu")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.bottom, 3)

            actionRow("Camera controls", systemImage: "camera.aperture", action: onOpenCameraControls)
            actionRow("Zone controls", systemImage: "square.dashed", action: onOpenZones)
            actionRow("Save Zones to Default Profile", systemImage: "square.and.arrow.down", action: onSaveZonesToDefault)
            actionRow("Zone Colour Profiles", systemImage: "paintpalette", action: onOpenColour)
            actionRow("Recognition diagnostics and thresholds", systemImage: "slider.horizontal.3", action: onOpenOCR)

            Divider().overlay(.white.opacity(0.18))

            actionRow(zonesVisible ? "Hide zones" : "Show zones", systemImage: zonesVisible ? "eye.slash" : "eye", action: zonesVisible ? onHideZones : onShowZones)
            actionRow("Verify selected scoreboard zone", systemImage: "text.viewfinder", action: onRunTestOCR)
        }
        .padding(12)
        .frame(width: 390, alignment: .leading)
        .background(Color.black.opacity(0.96))
        .foregroundStyle(.white)
    }

    private func actionRow(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            onAction(action)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 22, alignment: .center)
                    .foregroundStyle(.cyan)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .contentShape(Rectangle())
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}


private struct CalibrationLiveOCRDiagnosticsPill: View {
    @ObservedObject var viewModel: HockeyScoreboardViewModel
    @ObservedObject var ocrDiagnostics: OCRDiagnosticsStore
    let availableHeight: CGFloat

    private let primaryKeys: [OCRRegionKey] = [.clock, .homeScore, .awayScore, .period]

    var body: some View {
        let clampedHeight = Swift.max(40, availableHeight)
        let tileHeight = Swift.max(34, clampedHeight - 12)
        let titleFont = Swift.max(8, Swift.min(11, clampedHeight * 0.16))
        let mainFont = Swift.max(11, Swift.min(17, clampedHeight * 0.28))
        let detailFont = Swift.max(7, Swift.min(10, clampedHeight * 0.14))
        let tileWidth = Swift.max(96, Swift.min(124, clampedHeight * 1.68))
        let penaltyWidth = Swift.max(162, Swift.min(220, clampedHeight * 2.76))
        let hashWidth = Swift.max(112, Swift.min(148, clampedHeight * 1.92))

        return HStack(spacing: 6) {
            ForEach(primaryKeys) { key in
                CalibrationLiveOCRDiagnosticField(
                    key: key,
                    rawValue: ocrDiagnostics.regionOCRPreview[key] ?? "--",
                    confidence: ocrDiagnostics.ocrFieldConfidence[key],
                    accepted: viewModel.acceptedFieldState[key],
                    displayedValue: displayedValue(for: key),
                    broadcastValue: broadcastValue(for: key),
                    tileWidth: tileWidth,
                    tileHeight: tileHeight,
                    titleFontSize: titleFont,
                    mainFontSize: mainFont,
                    detailFontSize: detailFont
                )
            }

            CalibrationLivePenaltyDiagnosticField(
                title: "Home Penalty",
                sideCode: "HP",
                slot1Player: displayedValue(for: .homePenalty1Player),
                slot1Time: displayedValue(for: .homePenalty1Time),
                slot2Player: displayedValue(for: .homePenalty2Player),
                slot2Time: displayedValue(for: .homePenalty2Time),
                slot1PlayerRaw: ocrDiagnostics.regionOCRPreview[.homePenalty1Player] ?? "--",
                slot1TimeRaw: ocrDiagnostics.regionOCRPreview[.homePenalty1Time] ?? "--",
                slot2PlayerRaw: ocrDiagnostics.regionOCRPreview[.homePenalty2Player] ?? "--",
                slot2TimeRaw: ocrDiagnostics.regionOCRPreview[.homePenalty2Time] ?? "--",
                confidence: combinedConfidence(for: [.homePenalty1Player, .homePenalty1Time, .homePenalty2Player, .homePenalty2Time]),
                tileWidth: penaltyWidth,
                tileHeight: tileHeight,
                titleFontSize: titleFont,
                mainFontSize: mainFont,
                detailFontSize: detailFont
            )

            CalibrationLivePenaltyDiagnosticField(
                title: "Away Penalty",
                sideCode: "AP",
                slot1Player: displayedValue(for: .awayPenalty1Player),
                slot1Time: displayedValue(for: .awayPenalty1Time),
                slot2Player: displayedValue(for: .awayPenalty2Player),
                slot2Time: displayedValue(for: .awayPenalty2Time),
                slot1PlayerRaw: ocrDiagnostics.regionOCRPreview[.awayPenalty1Player] ?? "--",
                slot1TimeRaw: ocrDiagnostics.regionOCRPreview[.awayPenalty1Time] ?? "--",
                slot2PlayerRaw: ocrDiagnostics.regionOCRPreview[.awayPenalty2Player] ?? "--",
                slot2TimeRaw: ocrDiagnostics.regionOCRPreview[.awayPenalty2Time] ?? "--",
                confidence: combinedConfidence(for: [.awayPenalty1Player, .awayPenalty1Time, .awayPenalty2Player, .awayPenalty2Time]),
                tileWidth: penaltyWidth,
                tileHeight: tileHeight,
                titleFontSize: titleFont,
                mainFontSize: mainFont,
                detailFontSize: detailFont
            )

            CalibrationLivePixelHashField(
                isActive: ocrDiagnostics.isPixelHashingActive,
                status: ocrDiagnostics.ocrPixelHashingStatusText,
                detail: ocrDiagnostics.smartChangeLastDecisionText,
                tileWidth: hashWidth,
                tileHeight: tileHeight,
                titleFontSize: titleFont,
                mainFontSize: mainFont,
                detailFontSize: detailFont
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: 1180, minHeight: clampedHeight, maxHeight: clampedHeight, alignment: .leading)
        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 3)
        .accessibilityLabel("Live recognition diagnostics for Period and frozen Home popup crops, plus physical relay and hash evidence.")
    }

    private func displayedValue(for key: OCRRegionKey) -> String {
        // UX15a: this is a calibration diagnostics bar, so prefer the latest
        // accepted OCR/test value for the exact zone when available. The public
        // scoreboard state may intentionally retain an older value while smoothing,
        // penalty locking or clock-gating waits for more proof. During OCR setup the
        // operator needs to see whether the selected zone itself is being read.
        if let accepted = viewModel.acceptedFieldState[key]?.acceptedText,
           !accepted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return accepted
        }

        if let preview = ocrDiagnostics.regionOCRPreview[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !preview.isEmpty,
           preview != "--",
           preview != "No text" {
            return preview
        }

        switch key {
        case .clock:
            return viewModel.state.clock ?? viewModel.manualScoreState.manualClockText ?? "--"
        case .homeScore:
            return String(viewModel.state.homeScore ?? viewModel.overrideHomeScore)
        case .awayScore:
            return String(viewModel.state.awayScore ?? viewModel.overrideAwayScore)
        case .period:
            return String(viewModel.state.period ?? viewModel.overridePeriod)
        case .homeShots:
            return viewModel.state.homeShots.map { String($0) } ?? "--"
        case .awayShots:
            return viewModel.state.awayShots.map { String($0) } ?? "--"
        case .homePenalty1Player:
            return viewModel.state.homePenalty1Player.map { String($0) } ?? "--"
        case .homePenalty1Time:
            return viewModel.state.homePenalty1Clock ?? "--"
        case .homePenalty2Player:
            return viewModel.state.homePenalty2Player.map { String($0) } ?? "--"
        case .homePenalty2Time:
            return viewModel.state.homePenalty2Clock ?? "--"
        case .awayPenalty1Player:
            return viewModel.state.awayPenalty1Player.map { String($0) } ?? "--"
        case .awayPenalty1Time:
            return viewModel.state.awayPenalty1Clock ?? "--"
        case .awayPenalty2Player:
            return viewModel.state.awayPenalty2Player.map { String($0) } ?? "--"
        case .awayPenalty2Time:
            return viewModel.state.awayPenalty2Clock ?? "--"
        }
    }

    // UX16d15c: the large value in each primary tile is the latest OCR
    // recognition. Show the actual committed Broadcast value separately so a
    // correct recognition waiting for confirmation is not mistaken for a live
    // scorebug update.
    private func broadcastValue(for key: OCRRegionKey) -> String {
        switch key {
        case .clock:
            return viewModel.state.clock ?? viewModel.manualScoreState.manualClockText ?? "--"
        case .homeScore:
            return String(viewModel.state.homeScore ?? viewModel.overrideHomeScore)
        case .awayScore:
            return String(viewModel.state.awayScore ?? viewModel.overrideAwayScore)
        case .period:
            return String(viewModel.state.period ?? viewModel.overridePeriod)
        case .homeShots:
            return viewModel.state.homeShots.map { String($0) } ?? "--"
        case .awayShots:
            return viewModel.state.awayShots.map { String($0) } ?? "--"
        case .homePenalty1Player:
            return viewModel.state.homePenalty1Player.map { String($0) } ?? "--"
        case .homePenalty1Time:
            return viewModel.state.homePenalty1Clock ?? "--"
        case .homePenalty2Player:
            return viewModel.state.homePenalty2Player.map { String($0) } ?? "--"
        case .homePenalty2Time:
            return viewModel.state.homePenalty2Clock ?? "--"
        case .awayPenalty1Player:
            return viewModel.state.awayPenalty1Player.map { String($0) } ?? "--"
        case .awayPenalty1Time:
            return viewModel.state.awayPenalty1Clock ?? "--"
        case .awayPenalty2Player:
            return viewModel.state.awayPenalty2Player.map { String($0) } ?? "--"
        case .awayPenalty2Time:
            return viewModel.state.awayPenalty2Clock ?? "--"
        }
    }

    private func combinedConfidence(for keys: [OCRRegionKey]) -> Float? {
        let acceptedConfidences = keys.compactMap { key -> Float? in
            guard let confidence = ocrDiagnostics.ocrFieldConfidence[key], confidence.isAccepted else { return nil }
            return confidence.confidence
        }
        if !acceptedConfidences.isEmpty {
            return acceptedConfidences.reduce(0, +) / Float(acceptedConfidences.count)
        }

        let availableConfidences = keys.compactMap { ocrDiagnostics.ocrFieldConfidence[$0]?.confidence }
        guard !availableConfidences.isEmpty else { return nil }
        return availableConfidences.reduce(0, +) / Float(availableConfidences.count)
    }
}

private struct CalibrationLivePenaltyDiagnosticField: View {
    let title: String
    let sideCode: String
    let slot1Player: String
    let slot1Time: String
    let slot2Player: String
    let slot2Time: String
    let slot1PlayerRaw: String
    let slot1TimeRaw: String
    let slot2PlayerRaw: String
    let slot2TimeRaw: String
    let confidence: Float?
    let tileWidth: CGFloat
    let tileHeight: CGFloat
    let titleFontSize: CGFloat
    let mainFontSize: CGFloat
    let detailFontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColour)
                    .frame(width: 6, height: 6)
                Text(title)
                    .font(.system(size: titleFontSize, weight: .bold))
                    .foregroundStyle(.white.opacity(0.58))
                    .textCase(.uppercase)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(confidenceText)
                    .font(.system(size: Swift.max(7, detailFontSize), weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.54))
                    .lineLimit(1)
            }

            Text("\(sideCode)1 \(safe(slot1Player))/\(safe(slot1Time))")
                .font(.system(size: mainFontSize, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.62)

            Text("\(sideCode)2 \(safe(slot2Player))/\(safe(slot2Time)) · raw \(safe(slot1PlayerRaw))/\(safe(slot1TimeRaw)) \(safe(slot2PlayerRaw))/\(safe(slot2TimeRaw))")
                .font(.system(size: detailFontSize, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.50))
                .lineLimit(1)
                .minimumScaleFactor(0.52)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: tileWidth, height: tileHeight, alignment: .leading)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private var confidenceText: String {
        guard let confidence else { return "wait" }
        return "\(Int(confidence * 100))%"
    }

    private var statusColour: Color {
        guard let confidence else { return .white.opacity(0.44) }
        if confidence >= 0.75 { return .green }
        if confidence >= 0.55 { return .yellow }
        return .orange
    }

    private func safe(_ value: String?) -> String {
        guard let value else { return "--" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "--:--" else { return "--" }
        return trimmed
    }
}

private struct CalibrationLiveOCRDiagnosticField: View {
    let key: OCRRegionKey
    let rawValue: String
    let confidence: OCRFieldConfidence?
    let accepted: AcceptedOCRValueState?
    let displayedValue: String
    let broadcastValue: String
    let tileWidth: CGFloat
    let tileHeight: CGFloat
    let titleFontSize: CGFloat
    let mainFontSize: CGFloat
    let detailFontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColour)
                    .frame(width: 6, height: 6)
                Text(shortTitle)
                    .font(.system(size: titleFontSize, weight: .bold))
                    .foregroundStyle(.white.opacity(0.58))
                    .textCase(.uppercase)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(trustText)
                    .font(.system(size: Swift.max(7, detailFontSize), weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.54))
                    .lineLimit(1)
            }

            Text(displayedValue.isEmpty ? "--" : displayedValue)
                .font(.system(size: mainFontSize, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.70)

            HStack(spacing: 3) {
                Text("raw \(safe(rawValue))")
                Text("live \(safe(broadcastValue))")
            }
            .font(.system(size: detailFontSize, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.50))
            .lineLimit(1)
            .minimumScaleFactor(0.68)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: tileWidth, height: tileHeight, alignment: .leading)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private var shortTitle: String {
        switch key {
        case .clock: return "Clock"
        case .homeScore: return "Home"
        case .awayScore: return "Away"
        case .period: return "Period"
        default: return key.likelyTitle
        }
    }

    private var trustText: String {
        if let confidence, isCurrent(confidence.lastUpdated) {
            let publication = recognisedMatchesBroadcast ? "live" : "wait"
            return "\(Int(confidence.confidence * 100))% \(publication)"
        }
        if confidence != nil || accepted?.acceptedText != nil { return "stale" }
        return "wait"
    }

    private var statusColour: Color {
        guard let confidence, isCurrent(confidence.lastUpdated) else {
            return .white.opacity(0.44)
        }
        if !confidence.isAccepted { return .orange }
        if !recognisedMatchesBroadcast { return .orange }
        if confidence.confidence >= 0.75 { return .green }
        if confidence.confidence >= 0.55 { return .yellow }
        return .red
    }

    private var recognisedMatchesBroadcast: Bool {
        guard let currentAcceptedText else { return false }
        return canonical(currentAcceptedText) == canonical(broadcastValue)
    }

    private func canonical(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".", with: ":")
    }

    private var currentAcceptedText: String? {
        guard let accepted,
              let lastUpdated = accepted.lastUpdated,
              isCurrent(lastUpdated) else { return nil }
        return accepted.acceptedText
    }

    private func isCurrent(_ date: Date) -> Bool {
        // UX16d12: old accepted/confidence values may remain useful as the visible
        // scorebug value, but after three seconds they are not evidence that the
        // physical board currently confirms that value.
        Date().timeIntervalSince(date) <= 3.0
    }

    private func safe(_ value: String?) -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "--" }
        return value
    }
}

private struct CalibrationLivePixelHashField: View {
    let isActive: Bool
    let status: String
    let detail: String
    let tileWidth: CGFloat
    let tileHeight: CGFloat
    let titleFontSize: CGFloat
    let mainFontSize: CGFloat
    let detailFontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle()
                    .fill(isActive ? Color.green : Color.white.opacity(0.44))
                    .frame(width: 6, height: 6)
                Text("Hash")
                    .font(.system(size: titleFontSize, weight: .bold))
                    .foregroundStyle(.white.opacity(0.58))
                    .textCase(.uppercase)
                Spacer(minLength: 0)
            }

            Text(isActive ? "Active" : "Standby")
                .font(.system(size: mainFontSize, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)

            Text(shortDetail)
                .font(.system(size: detailFontSize, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.50))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: tileWidth, height: tileHeight, alignment: .leading)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private var shortDetail: String {
        let text = status.isEmpty ? detail : status
        return text.isEmpty ? "no change data" : text
    }
}

private struct CalibrationSelectedOCRStatusPanel: View {
    @ObservedObject var viewModel: HockeyScoreboardViewModel
    @ObservedObject var ocrDiagnostics: OCRDiagnosticsStore
    @ObservedObject private var imageRelayPresentation = ScoreboardImageRelayPresentation.shared
    let availableHeight: CGFloat
    let isVisible: Bool
    let onClose: () -> Void
    let onRequestManualMode: () -> Void
    @State private var showingOCRColourLegend = false
    @State private var lastPanelGeometryTraceAt: CFAbsoluteTime = 0

    var body: some View {
        GeometryReader { proxy in
            let panelHeight = Swift.max(52, proxy.size.height)
            let panelWidth = Swift.max(240, proxy.size.width)
            let horizontalPadding: CGFloat = 6
            let imageSpacing: CGFloat = 8
            let imageVerticalPadding: CGFloat = 4
            let imageAreaWidth = Swift.max(180, panelWidth - (horizontalPadding * 2))
            let relayMode = viewModel.operatingMode == .imageRelay
            let rawImage = relayMode ? selectedRawRelayImage : viewModel.selectedRegionRawPreviewImage
            let publishedImage = relayMode ? selectedPublishedRelayImage : nil
            let rawAspect = preferredAspect(for: rawImage)
            let procAspect = preferredAspect(for: viewModel.selectedRegionProcessedPreviewImage)
            let threshAspect = preferredAspect(for: viewModel.selectedRegionThresholdedPreviewImage)
            let segmentAspect = preferredAspect(for: viewModel.selectedRegionSegmentPreviewImage)
            let publishedAspect = preferredAspect(for: publishedImage)
            let hasSegments = !relayMode && viewModel.selectedRegionSegmentPreviewImage != nil
            let totalAspect = relayMode
                ? rawAspect + publishedAspect
                : rawAspect + procAspect + threshAspect + (hasSegments ? segmentAspect : 0)
            let availableImageHeight = Swift.max(30, panelHeight - (imageVerticalPadding * 2))
            let spacingCount = relayMode ? 1 : (hasSegments ? 3 : 2)
            let aspectLimitedHeight = (imageAreaWidth - (imageSpacing * CGFloat(spacingCount))) / Swift.max(0.1, totalAspect)
            let imageHeight = Swift.min(availableImageHeight, aspectLimitedHeight)
            let rawWidth = imageHeight * rawAspect
            let procWidth = imageHeight * procAspect
            let threshWidth = imageHeight * threshAspect
            let segmentWidth = imageHeight * segmentAspect
            let publishedWidth = imageHeight * publishedAspect
            let titleFont = Swift.max(8, Swift.min(12, imageHeight * 0.18))

            HStack(spacing: imageSpacing) {
                previewImageTile(
                    title: "Raw",
                    image: rawImage,
                    width: rawWidth,
                    height: imageHeight,
                    titleFont: titleFont
                )

                if relayMode {
                    previewImageTile(
                        title: "Published",
                        image: publishedImage,
                        width: publishedWidth,
                        height: imageHeight,
                        titleFont: titleFont
                    )
                } else {
                    previewImageTile(
                        title: "Proc",
                        image: viewModel.selectedRegionProcessedPreviewImage,
                        width: procWidth,
                        height: imageHeight,
                        titleFont: titleFont
                    )

                    previewImageTile(
                        title: "Thresh",
                        image: viewModel.selectedRegionThresholdedPreviewImage,
                        width: threshWidth,
                        height: imageHeight,
                        titleFont: titleFont
                    )

                    if hasSegments {
                        previewImageTile(
                            title: "Segments",
                            image: viewModel.selectedRegionSegmentPreviewImage,
                            width: segmentWidth,
                            height: imageHeight,
                            titleFont: titleFont
                        )
                    }
                }
            }
            .padding(.horizontal, horizontalPadding)
            .frame(width: panelWidth, height: panelHeight, alignment: .center)
            .background(Color.black.opacity(0.74), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .onAppear {
                tracePanelGeometry(
                    panelWidth: panelWidth,
                    panelHeight: panelHeight,
                    imageAreaWidth: imageAreaWidth,
                    rawWidth: rawWidth,
                    secondWidth: relayMode ? publishedWidth : procWidth,
                    thirdWidth: relayMode ? 0 : threshWidth,
                    imageHeight: imageHeight,
                    relayMode: relayMode,
                    reason: "appear"
                )
            }
            .onChange(of: proxy.size) { _, _ in
                tracePanelGeometry(
                    panelWidth: panelWidth,
                    panelHeight: panelHeight,
                    imageAreaWidth: imageAreaWidth,
                    rawWidth: rawWidth,
                    secondWidth: relayMode ? publishedWidth : procWidth,
                    thirdWidth: relayMode ? 0 : threshWidth,
                    imageHeight: imageHeight,
                    relayMode: relayMode,
                    reason: "size-change"
                )
            }
            .onChange(of: isVisible) { _, visible in
                tracePanelGeometry(
                    panelWidth: panelWidth,
                    panelHeight: panelHeight,
                    imageAreaWidth: imageAreaWidth,
                    rawWidth: rawWidth,
                    secondWidth: relayMode ? publishedWidth : procWidth,
                    thirdWidth: relayMode ? 0 : threshWidth,
                    imageHeight: imageHeight,
                    relayMode: relayMode,
                    reason: visible ? "visible" : "hidden"
                )
            }
        }
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .animation(nil, value: isVisible)
        .alert("Zone colours", isPresented: $showingOCRColourLegend) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("""
Grey = OCR stopped or inactive. No OCR, pixel hashing or segment analysis is running.
Blue = selected OCR zone.
Green = OCR running and stable/accepted.
Cyan = pixel hashing active for the zone.
Orange = safety re-sync or review needed.
Red = OCR failed or invalid.

Calibration phase rule: when zones are shown on the calibration camera, match-day clock gating is ignored. Advanced OCR behaviours, cadences and confidence thresholds still apply; pixel hashing does not block setup reads.
""")
        }
    }

    private var selectedRawRelayImage: UIImage? {
        _ = imageRelayPresentation.revision
        guard viewModel.operatingMode == .imageRelay,
              let image = ScoreboardImageRelayStore.shared.snapshot().rawImage(for: viewModel.selectedRegionKey) else {
            return nil
        }
        return UIImage(cgImage: image)
    }

    private var selectedPublishedRelayImage: UIImage? {
        _ = imageRelayPresentation.revision
        guard viewModel.operatingMode == .imageRelay,
              let image = ScoreboardImageRelayStore.shared.snapshot().image(for: viewModel.selectedRegionKey) else {
            return nil
        }
        return UIImage(cgImage: image)
    }

    private func tracePanelGeometry(
        panelWidth: CGFloat,
        panelHeight: CGFloat,
        imageAreaWidth: CGFloat,
        rawWidth: CGFloat,
        secondWidth: CGFloat,
        thirdWidth: CGFloat,
        imageHeight: CGFloat,
        relayMode: Bool,
        reason: String
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        guard reason != "size-change" || now - lastPanelGeometryTraceAt > 0.75 else { return }
        lastPanelGeometryTraceAt = now

        let spacingWidth: CGFloat = relayMode ? 8 : 16
        let usedImageWidth = rawWidth + secondWidth + thirdWidth + spacingWidth
        let imageWidthGap = max(0, imageAreaWidth - usedImageWidth)
        let heightGap = max(0, panelHeight - imageHeight)
        let line = String(
            format: "UX16d37e geometry testPanel reason=%@ mode=%@ panel=%.0fx%.1f imageArea=%.0f raw=%.0f second=%.0f third=%.0f imageH=%.1f gapH=%.1f imageGapW=%.1f cropAspect raw=%@ second=%@ third=%@ stableRow=true",
            reason,
            relayMode ? "relay-raw-published" : "ocr-raw-proc-thresh",
            panelWidth,
            panelHeight,
            imageAreaWidth,
            rawWidth,
            secondWidth,
            thirdWidth,
            imageHeight,
            heightGap,
            imageWidthGap,
            relayMode ? aspectText(selectedRawRelayImage) : aspectText(viewModel.selectedRegionRawPreviewImage),
            relayMode ? aspectText(selectedPublishedRelayImage) : aspectText(viewModel.selectedRegionProcessedPreviewImage),
            relayMode ? "--" : aspectText(viewModel.selectedRegionThresholdedPreviewImage)
        )
        OCRChromeGeometryDiagnosticsStore.shared.notePanel(line)
        MainThreadStallMonitor.shared.markContext(line)
    }

    private func preferredAspect(for image: UIImage?) -> CGFloat {
        guard let image, image.size.height > 0 else { return 3.0 }
        return Swift.max(0.4, Swift.min(8.0, image.size.width / image.size.height))
    }

    private func aspectText(_ image: UIImage?) -> String {
        guard let image, image.size.height > 0 else { return "--" }
        return String(format: "%.2f", image.size.width / image.size.height)
    }

    @ViewBuilder
    private func previewImageTile(title: String, image: UIImage?, width: CGFloat, height: CGFloat, titleFont: CGFloat) -> some View {
        ZStack(alignment: .top) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: width, height: height)
                    .background(Color.black.opacity(0.25))
            } else {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.black.opacity(0.25))
                    .frame(width: width, height: height)
                    .overlay(
                        Text("Wait")
                            .font(.system(size: Swift.max(8, titleFont), weight: .bold))
                            .foregroundStyle(.white.opacity(0.45))
                    )
            }

            Text(title)
                .font(.system(size: titleFont, weight: .bold))
                .foregroundStyle(.white.opacity(0.90))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.55), in: Capsule())
                .padding(.top, 3)
                .lineLimit(1)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard image != nil else { return }
            onRequestManualMode()
        }
        .accessibilityHidden(image == nil)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Use this scoreboard image in Manual mode")
        .accessibilityHint("Switches scoreboard input to Manual mode and preserves the visible values")
    }
}

private struct CalibrationZoneQuickPicker: View {
    @Binding var selectedKey: OCRRegionKey
    @Binding var editMode: CalibrationZoneEditMode
    @Binding var selectedPenaltyGroup: PenaltyZoneGroupID
    @State private var showingMoreZones = false
    let calibratedColourKeys: Set<OCRRegionKey>
    let onHideZones: () -> Void
    let onOpenTestOCR: () -> Void

    private let primaryZones: [OCRRegionKey] = [.clock, .homeScore, .awayScore, .period]

    var body: some View {
        HStack(spacing: 3) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    modeChip("Single", isSelected: editMode == .single) {
                        editMode = .single
                    }

                    modeChip("Group", isSelected: editMode == .penaltyGroup) {
                        editMode = .penaltyGroup
                        selectedKey = selectedPenaltyGroup.playerKey
                    }

                    ForEach(primaryZones) { key in
                        zoneChip(key.likelyTitle, key: key, isSelected: editMode == .single && selectedKey == key) {
                            editMode = .single
                            selectedKey = key
                        }
                    }

                    Button {
                        showingMoreZones.toggle()
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                            .font(.caption2.bold())
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.38), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showingMoreZones, arrowEdge: .bottom) {
                        CalibrationMoreZonesPopover(
                            calibratedColourKeys: calibratedColourKeys,
                            onSelect: { key in
                                editMode = .single
                                selectedKey = key
                                showingMoreZones = false
                            }
                        )
                    }

                    if editMode == .penaltyGroup {
                        ForEach(PenaltyZoneGroupID.allCases) { group in
                            zoneChip(group.title, key: nil, isSelected: selectedPenaltyGroup == group) {
                                editMode = .penaltyGroup
                                selectedPenaltyGroup = group
                                selectedKey = group.playerKey
                            }
                        }
                    }
                }
                .padding(.vertical, 0)
            }

            Button(action: onHideZones) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .background(Color.cyan.opacity(0.90), in: Capsule())
            .foregroundStyle(.black)
            .overlay(Capsule().stroke(Color.cyan.opacity(0.82), lineWidth: 1))
            .accessibilityLabel("Hide zone controls")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.20), radius: 7, x: 0, y: 4)
    }

    private func zoneChip(_ title: String, key: OCRRegionKey?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let key, calibratedColourKeys.contains(key) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(isSelected ? Color.black : Color.green)
                }
                Text(title)
            }
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(isSelected ? Color.yellow.opacity(0.90) : Color.black.opacity(0.42), in: Capsule())
                .foregroundStyle(isSelected ? Color.black : Color.white)
                .overlay(
                    Capsule().stroke(isSelected ? Color.yellow : Color.white.opacity(0.20), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func modeChip(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(isSelected ? Color.cyan.opacity(0.90) : Color.black.opacity(0.42), in: Capsule())
                .foregroundStyle(isSelected ? Color.black : Color.white)
                .overlay(
                    Capsule().stroke(isSelected ? Color.cyan : Color.white.opacity(0.20), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}


private struct CalibrationMoreZonesPopover: View {
    let calibratedColourKeys: Set<OCRRegionKey>
    let onSelect: (OCRRegionKey) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("All Calibration Zones")
                .font(.headline)
                .foregroundStyle(.white)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(OCRRegionKey.calibrationCases) { key in
                        Button {
                            onSelect(key)
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: calibratedColourKeys.contains(key) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(calibratedColourKeys.contains(key) ? Color.green : Color.white.opacity(0.55))
                                    .frame(width: 18)
                                Text(key.likelyTitle)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                            .contentShape(Rectangle())
                            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 430)
        }
        .padding(12)
        .frame(width: 350, alignment: .leading)
        .background(Color.black.opacity(0.96))
    }
}

private struct CameraNotSelectedOverlay: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.badge.ellipsis")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.white)

            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Text(message)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.86))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: 420)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.20), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

#endif
