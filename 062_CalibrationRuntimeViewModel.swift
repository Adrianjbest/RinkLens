// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import Foundation
import CoreGraphics
import UIKit

// v0.8.8m6 — Calibration Isolation
// Small calibration-facing state object. It samples the large scoreboard view model
// at a controlled cadence so frame/OCR/debug churn does not invalidate the whole
// CalibrationScreen.
@MainActor
final class CalibrationRuntimeViewModel: ObservableObject {
    @Published var statusMessage: String?
    @Published var isOCRPausedByUser: Bool = true
    @Published var isOCROperational: Bool = false
    @Published var ocrCameraSelected: Bool = false
    @Published var ocrPreviewRotationOffsetDegrees: Double = 0
    @Published var cameraRotationLockEnabled: Bool = false
    @Published var cameraZoomFactor: CGFloat = 1
    @Published var minZoomFactor: CGFloat = 1
    @Published var maxZoomFactor: CGFloat = 5
    @Published var guidedAssistantVisible: Bool = true
    @Published var guidedAssistantOffsetX: CGFloat = 0
    @Published var guidedAssistantOffsetY: CGFloat = 0
    /// Build 689 fixes the Guided Calibration loupe at 8×. The operator no
    /// longer needs to manage a separate guide zoom state and legacy 1×/2×/4×
    /// preferences cannot silently reduce character-edge visibility.
    @Published var previewMagnification: CGFloat = 8
    @Published var precisionStepPixels: CGFloat = 1
    @Published var calibrationQuality: CalibrationQualitySnapshot = .waiting
    @Published var selectedZoneLoupeImage: UIImage?
    @Published var selectedZoneLoupeZoneRect: CGRect = .zero
    @Published var selectedZoneLoupeCharacterRect: CGRect?
    @Published private(set) var lockedRegionRawValues: Set<String> = []

    private weak var source: HockeyScoreboardViewModel?
    private var refreshTask: Task<Void, Never>?
    private var isDiagnosticsVisible = false
    private var lastSignature = ""
    private var lastCalibrationAnalysisSignature = ""
    private var lastQualityFingerprint = ""
    private var qualityStableFrames = 0
    private var lastGuidedRegionKey: OCRRegionKey?

    private enum PreferenceKey {
        static let guidedAssistantVisible = "IceCast.calibration.guidedAssistantVisible"
        static let guidedAssistantOffsetX = "IceCast.calibration.guidedAssistantOffsetX"
        static let guidedAssistantOffsetY = "IceCast.calibration.guidedAssistantOffsetY"
        static let previewMagnification = "IceCast.calibration.previewMagnification"
        static let lockedRegionRawValues = "IceCast.calibration.lockedRegionRawValues"
    }

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: PreferenceKey.guidedAssistantVisible) != nil {
            guidedAssistantVisible = defaults.bool(forKey: PreferenceKey.guidedAssistantVisible)
        }
        if defaults.object(forKey: PreferenceKey.guidedAssistantOffsetX) != nil {
            guidedAssistantOffsetX = Self.sanitizedPanelOffset(CGFloat(defaults.double(forKey: PreferenceKey.guidedAssistantOffsetX)))
        }
        if defaults.object(forKey: PreferenceKey.guidedAssistantOffsetY) != nil {
            guidedAssistantOffsetY = Self.sanitizedPanelOffset(CGFloat(defaults.double(forKey: PreferenceKey.guidedAssistantOffsetY)))
        }
        if RinkLensRiskFeaturePolicy.isEnabled(.guidedCalibrationFixed8x) {
            previewMagnification = 8
            defaults.set(Double(previewMagnification), forKey: PreferenceKey.previewMagnification)
        } else if defaults.object(forKey: PreferenceKey.previewMagnification) != nil {
            previewMagnification = Self.sanitizedPreviewMagnification(CGFloat(defaults.double(forKey: PreferenceKey.previewMagnification)))
        }
        lockedRegionRawValues = Set(defaults.stringArray(forKey: PreferenceKey.lockedRegionRawValues) ?? [])
    }

    var lockedRegionKeys: Set<OCRRegionKey> {
        Set(lockedRegionRawValues.compactMap(OCRRegionKey.init(rawValue:)))
    }

    func isRegionLocked(_ key: OCRRegionKey) -> Bool {
        lockedRegionRawValues.contains(key.rawValue)
    }

    func toggleRegionLock(_ key: OCRRegionKey) {
        if lockedRegionRawValues.contains(key.rawValue) {
            lockedRegionRawValues.remove(key.rawValue)
            MainThreadStallMonitor.shared.markContext("guided calibration zone unlocked: \(key.rawValue)")
        } else {
            lockedRegionRawValues.insert(key.rawValue)
            MainThreadStallMonitor.shared.markContext("guided calibration zone locked: \(key.rawValue)")
        }
        UserDefaults.standard.set(Array(lockedRegionRawValues).sorted(), forKey: PreferenceKey.lockedRegionRawValues)
    }

    func setGuidedAssistantVisible(_ visible: Bool) {
        guidedAssistantVisible = visible
        UserDefaults.standard.set(visible, forKey: PreferenceKey.guidedAssistantVisible)
        MainThreadStallMonitor.shared.markContext("guided calibration assistant \(visible ? "shown" : "hidden")")
    }

    var guidedAssistantOffset: CGSize {
        CGSize(width: guidedAssistantOffsetX, height: guidedAssistantOffsetY)
    }

    func setGuidedAssistantOffset(_ offset: CGSize, persist: Bool) {
        let x = Self.sanitizedPanelOffset(offset.width)
        let y = Self.sanitizedPanelOffset(offset.height)
        guidedAssistantOffsetX = x
        guidedAssistantOffsetY = y
        if persist {
            UserDefaults.standard.set(Double(x), forKey: PreferenceKey.guidedAssistantOffsetX)
            UserDefaults.standard.set(Double(y), forKey: PreferenceKey.guidedAssistantOffsetY)
            MainThreadStallMonitor.shared.markContext("guided calibration floating position saved x=\(Int(x.rounded())) y=\(Int(y.rounded()))")
        }
    }

    func resetGuidedAssistantOffset() {
        setGuidedAssistantOffset(.zero, persist: true)
    }

    func setPreviewMagnification(_ value: CGFloat) {
        let fixedMagnification = Self.sanitizedPreviewMagnification(value)
        guard abs(previewMagnification - fixedMagnification) > 0.01 else { return }
        previewMagnification = fixedMagnification
        lastCalibrationAnalysisSignature = ""
        UserDefaults.standard.set(Double(fixedMagnification), forKey: PreferenceKey.previewMagnification)
        MainThreadStallMonitor.shared.markContext("guided calibration loupe fixed at \(Int(fixedMagnification))x")
        publishSnapshot(force: true)
    }

    /// Build 675 invalidates the bounded Guide analysis immediately when the
    /// selected zone changes or the panel first appears. Previously the green
    /// character rectangle could remain from the prior zone until the next
    /// scheduled analysis; nudging the zone happened to invalidate it, which made
    /// the rectangle appear to "wake up" only after movement.
    func refreshGuidedCalibrationAnalysis(reason: String) {
        lastCalibrationAnalysisSignature = ""
        lastQualityFingerprint = ""
        qualityStableFrames = 0
        lastGuidedRegionKey = nil
        selectedZoneLoupeCharacterRect = nil
        selectedZoneLoupeZoneRect = .zero
        MainThreadStallMonitor.shared.markContext("guided calibration analysis invalidated: \(reason)")
        publishSnapshot(force: true)
    }

    private static func sanitizedPanelOffset(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return max(-2_000, min(2_000, value))
    }

    private static func sanitizedPreviewMagnification(_ value: CGFloat) -> CGFloat {
        guard !RinkLensRiskFeaturePolicy.isEnabled(.guidedCalibrationFixed8x) else { return 8 }
        let choices: [CGFloat] = [1, 2, 4, 8]
        return choices.min(by: { abs($0 - value) < abs($1 - value) }) ?? 8
    }

    func start(source: HockeyScoreboardViewModel) {
        self.source = source
        publishSnapshot(force: true)
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await MainActor.run { self?.publishSnapshot(force: false) }
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        source = nil
    }

    func setDiagnosticsVisible(_ visible: Bool) {
        isDiagnosticsVisible = visible
        source?.setOCRDiagnosticsVisible(visible)
        source?.ocrCameraService.setDiagnosticsPublishingVisible(visible)
        source?.liveCameraService.setDiagnosticsPublishingVisible(visible)
        publishSnapshot(force: true)
    }

    func setCameraZoomDraft(_ zoom: CGFloat) {
        let bounds = Self.sanitizedZoomBounds(min: minZoomFactor, max: maxZoomFactor)
        guard bounds.isUsable else {
            if abs(cameraZoomFactor - bounds.min) > 0.001 {
                cameraZoomFactor = bounds.min
            }
            MainThreadStallMonitor.shared.markContext("calibration zoom draft ignored: unusable camera zoom range")
            return
        }
        let clamped = Swift.min(Swift.max(zoom, bounds.min), bounds.max)
        guard abs(cameraZoomFactor - clamped) > 0.001 else { return }
        cameraZoomFactor = clamped
    }

    private static func sanitizedZoomBounds(min rawMin: CGFloat, max rawMax: CGFloat) -> (min: CGFloat, max: CGFloat, isUsable: Bool) {
        let fallbackMin = CGFloat(1.0)
        let fallbackMax = CGFloat(5.0)
        let cleanMin = rawMin.isFinite ? Swift.max(fallbackMin, rawMin) : fallbackMin
        let rawCleanMax = rawMax.isFinite ? rawMax : fallbackMax
        let cappedMax = Swift.min(fallbackMax, Swift.max(cleanMin, rawCleanMax))
        let isUsable = cappedMax > cleanMin + 0.01
        return (cleanMin, cappedMax, isUsable)
    }

    func publishSnapshot(force: Bool) {
        guard let source else { return }

        let nextStatus = source.statusMessage
        let nextPaused = source.isOCRPausedByUser
        let captureSnapshot = source.externalOCRMultiCamCoordinator.snapshot
        let multiCamOCRSelected = captureSnapshot.ocrDeviceID != nil
            || source.externalOCRMultiCamRequired
        let multiCamOCROperational = captureSnapshot.isActive
            && captureSnapshot.sessionRunning
            && captureSnapshot.ocrFramesReceived > 0
        let nextSelected = source.ocrCameraService.hasConfiguredCameraSelection
            || multiCamOCRSelected
        let nextOperational = source.isOCREffectiveRunning
            && (multiCamOCROperational
                || (source.ocrCameraService.isSessionRunning
                    && source.ocrCameraService.hasFreshFrameSnapshot))
        let nextRotation = source.ocrPreviewRotationOffsetDegrees
        let nextLock = source.cameraRotationLockEnabled
        let zoomBounds = Self.sanitizedZoomBounds(
            min: source.ocrCameraService.minZoomFactor,
            max: source.ocrCameraService.maxZoomFactor
        )
        let nextMin = zoomBounds.min
        let nextMax = zoomBounds.max
        let nextZoom = zoomBounds.isUsable
            ? Swift.min(Swift.max(source.cameraZoomFactor, nextMin), nextMax)
            : nextMin

        let signature = [
            nextStatus ?? "nil",
            nextPaused ? "paused" : "requested",
            nextOperational ? "operational" : "waiting",
            nextSelected ? "selected" : "none",
            String(format: "%.1f", nextRotation),
            nextLock ? "locked" : "unlocked",
            String(format: "%.2f", Double(nextZoom)),
            String(format: "%.2f", Double(nextMin)),
            String(format: "%.2f", Double(nextMax)),
            zoomBounds.isUsable ? "zoom-ok" : "zoom-fixed",
            isDiagnosticsVisible ? "diag" : "hidden"
        ].joined(separator: "|")

        publishGuidedCalibrationAnalysisIfNeeded(source: source, force: force)

        guard force || signature != lastSignature else { return }
        lastSignature = signature

        statusMessage = nextStatus
        isOCRPausedByUser = nextPaused
        isOCROperational = nextOperational
        ocrCameraSelected = nextSelected
        ocrPreviewRotationOffsetDegrees = nextRotation
        cameraRotationLockEnabled = nextLock
        cameraZoomFactor = nextZoom
        minZoomFactor = nextMin
        maxZoomFactor = nextMax

        if isDiagnosticsVisible {
            MainThreadStallMonitor.shared.notePublish(source: "calibration runtime snapshot")
        }
    }

    private func publishGuidedCalibrationAnalysisIfNeeded(source: HockeyScoreboardViewModel, force: Bool) {
        guard guidedAssistantVisible,
              let frame = RinkLensFrameHub.shared.latestFrame(for: .ocr, maxAge: 0.85) else {
            if force && selectedZoneLoupeImage == nil {
                calibrationQuality = .waiting
            }
            return
        }

        let key = source.selectedRegionKey
        if lastGuidedRegionKey != key {
            lastGuidedRegionKey = key
            lastCalibrationAnalysisSignature = ""
            lastQualityFingerprint = ""
            qualityStableFrames = 0
            selectedZoneLoupeCharacterRect = nil
            selectedZoneLoupeZoneRect = .zero
            MainThreadStallMonitor.shared.markContext("guided calibration selected zone changed: \(key.rawValue); stale character bounds cleared")
        }
        let region = source.ocrLayout[key]
        let analysisSignature = [
            String(frame.sequence),
            key.rawValue,
            String(format: "%.5f", Double(region.x)),
            String(format: "%.5f", Double(region.y)),
            String(format: "%.5f", Double(region.width)),
            String(format: "%.5f", Double(region.height)),
            String(format: "%.0f", Double(previewMagnification)),
            String(format: "%.0f", Double(source.ocrPreviewRotationOffsetDegrees)),
            source.boardCalibration.zonesFollowPerspective ? "perspective" : "legacy",
            String(format: "%.4f,%.4f", Double(source.boardCalibration.topLeft.x), Double(source.boardCalibration.topLeft.y)),
            String(format: "%.4f,%.4f", Double(source.boardCalibration.topRight.x), Double(source.boardCalibration.topRight.y)),
            String(format: "%.4f,%.4f", Double(source.boardCalibration.bottomRight.x), Double(source.boardCalibration.bottomRight.y)),
            String(format: "%.4f,%.4f", Double(source.boardCalibration.bottomLeft.x), Double(source.boardCalibration.bottomLeft.y))
        ].joined(separator: "|")
        guard force || analysisSignature != lastCalibrationAnalysisSignature else { return }
        lastCalibrationAnalysisSignature = analysisSignature

        let exactLoupe = source.guidedCalibrationSelectedZoneLoupe(
            from: frame.pixelBuffer,
            magnification: previewMagnification
        )
        let result = CalibrationQualityAnalyzer.analyse(
            frame: frame,
            region: region,
            boardCalibration: source.boardCalibration,
            previewMagnification: previewMagnification,
            previewRotationDegrees: source.ocrPreviewRotationOffsetDegrees,
            exactLoupe: exactLoupe
        )
        let fingerprint = [
            String(result.quality.focusScore / 5),
            String(result.quality.exposureScore / 5),
            String(result.quality.contrastScore / 5),
            String(result.quality.zoneFitScore / 5)
        ].joined(separator: "|")
        if fingerprint == lastQualityFingerprint {
            qualityStableFrames = min(999, qualityStableFrames + 1)
        } else {
            qualityStableFrames = 1
            lastQualityFingerprint = fingerprint
        }

        var quality = result.quality
        quality.stableFrameCount = qualityStableFrames
        calibrationQuality = quality
        selectedZoneLoupeImage = result.loupeImage
        selectedZoneLoupeZoneRect = result.loupeZoneRect
        selectedZoneLoupeCharacterRect = result.loupeCharacterRect
    }

}
#endif
