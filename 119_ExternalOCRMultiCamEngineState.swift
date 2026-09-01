// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import CoreImage
import UIKit

nonisolated private final class RinkLensWeakPreviewLayerBox: @unchecked Sendable {
    weak var value: AVCaptureVideoPreviewLayer?

    init(_ value: AVCaptureVideoPreviewLayer?) {
        self.value = value
    }
}
import Foundation
import Dispatch

/// One bounded application-owned continuity raster plus immutable proof of the
/// exact camera callback that supplied it. The pixel-buffer lease is released
/// before this value crosses the asynchronous presentation boundary.
nonisolated struct RinkLensBroadcastPreviewContinuityFrame: @unchecked Sendable {
    let image: CGImage
    let evidence: RinkLensFrameHubEvidence
}

// MARK: - UX16c38 Capture-engine state contract

/// Authoritative lifecycle phase for the process-wide Broadcast + external OCR
/// capture graph. `AVCaptureSession.isRunning` is deliberately not used as the
/// application state because a session can report running while its graph has no
/// usable input or while one branch has not delivered a frame.

/// Stable preview endpoint roles exposed by the single MultiCam graph. Routes
/// mount or hide these endpoints; they do not start, stop or rebuild capture.
nonisolated enum RinkLensCapturePreviewRole: String, Sendable, Equatable, CaseIterable {
    case broadcast
    case ocr

    var displayName: String {
        switch self {
        case .broadcast: return "Broadcast"
        case .ocr: return "OCR"
        }
    }

    var stableHostKey: String {
        switch self {
        case .broadcast: return "broadcast-multicam-preview"
        case .ocr: return "ocr-multicam-preview"
        }
    }
}

// MARK: - UX16d2d authoritative branch freshness

nonisolated struct RinkLensCaptureBranchHealthSnapshot: Sendable, Equatable {
    let role: RinkLensFrameRole
    let required: Bool
    let sessionRunning: Bool
    let inputPresent: Bool
    let outputPresent: Bool
    let connectionPresent: Bool
    let connectionEnabled: Bool
    let connectionActive: Bool
    let delegateInstalled: Bool
    let intentionallySuspended: Bool
    let frameCount: Int
    let lastCallbackAgeSeconds: TimeInterval?
    let frameHubFresh: Bool
    let frameHubSequence: Int
    let observedFPS: Double
    let maximumFreshAgeSeconds: TimeInterval

    var isStructurallyReady: Bool {
        !required || (sessionRunning
            && inputPresent
            && outputPresent
            && connectionPresent
            && (connectionEnabled || intentionallySuspended)
            && (connectionActive || intentionallySuspended)
            && delegateInstalled)
    }

    var hasFreshFrame: Bool {
        guard required else { return true }
        guard !intentionallySuspended else { return true }
        guard let age = lastCallbackAgeSeconds else { return false }
        return age <= maximumFreshAgeSeconds && frameHubFresh
    }

    var isHealthy: Bool { isStructurallyReady && hasFreshFrame }

    var diagnosticText: String {
        let age = lastCallbackAgeSeconds.map { String(format: "%.2fs", $0) } ?? "--"
        return "role=\(role.rawValue) required=\(required) structural=\(isStructurallyReady) fresh=\(hasFreshFrame) age=\(age) frames=\(frameCount) hubFresh=\(frameHubFresh) hubSequence=\(frameHubSequence) fps=\(String(format: "%.1f", observedFPS)) input=\(inputPresent) output=\(outputPresent) connection=\(connectionPresent)/enabled=\(connectionEnabled)/active=\(connectionActive) delegate=\(delegateInstalled) suspended=\(intentionallySuspended)"
    }
}

nonisolated struct RinkLensCaptureHealthSnapshot: Sendable, Equatable {
    let mode: RinkLensCaptureLifecycleMode
    let generation: Int
    let live: RinkLensCaptureBranchHealthSnapshot
    let ocr: RinkLensCaptureBranchHealthSnapshot
    let sampledAtUptimeNanoseconds: UInt64

    var isHealthy: Bool { live.isHealthy && ocr.isHealthy }
    var diagnosticText: String {
        "mode=\(mode.rawValue) generation=\(generation) healthy=\(isHealthy) live={\(live.diagnosticText)} ocr={\(ocr.diagnosticText)}"
    }
}

nonisolated enum RinkLensOCRDeadBranchRecoveryDisposition: String, Sendable, Equatable {
    case recovered
    case alreadyFresh
    case notRequired
    case intentionallySuspended
    case structurallyUnavailable
    case reconnectRejected
    case timedOut
}

nonisolated struct RinkLensOCRDeadBranchRecoveryResult: Sendable, Equatable {
    let disposition: RinkLensOCRDeadBranchRecoveryDisposition
    let generation: Int
    let frameCountBefore: Int
    let frameCountAfter: Int
    let diagnosticText: String

    var recovered: Bool { disposition == .recovered || disposition == .alreadyFresh }
}

nonisolated enum RinkLensCaptureEnginePhase: String, Sendable, Equatable, CaseIterable {
    case stopped
    case discoveringDevices
    case configuring
    case starting
    case waitingForFrames
    case running
    case stopping
    case interrupted
    case recovering
    case degraded
    case failed

    var isOperational: Bool { self == .running }

    var isTransitioning: Bool {
        switch self {
        case .discoveringDevices, .configuring, .starting, .waitingForFrames, .stopping, .recovering:
            return true
        case .stopped, .running, .interrupted, .degraded, .failed:
            return false
        }
    }
}

/// Immutable, Sendable snapshot emitted by the queue-confined capture engine.
/// SwiftUI observes this value through `ExternalOCRMultiCamUIState`; it never
/// observes or mutates the AVFoundation owner directly.
nonisolated struct RinkLensCaptureEngineSnapshot: Sendable, Equatable {
    var phase: RinkLensCaptureEnginePhase
    var captureModeText: String
    var isActive: Bool
    var isTransitioning: Bool
    var previewAttached: Bool
    var broadcastPreviewAttached: Bool
    var ocrPreviewAttached: Bool
    var statusText: String
    var devicePairText: String
    var graphText: String
    var lastInterruptionText: String
    var liveFramesReceived: Int
    var ocrFramesReceived: Int
    var liveDeviceID: String?
    var ocrDeviceID: String?
    var liveDeviceName: String
    var liveDevicePositionText: String
    var liveDeviceTypeText: String
    var ocrDeviceName: String
    var ocrDevicePositionText: String
    var ocrDeviceTypeText: String
    var liveFormat: RinkLensCaptureFormatPreference?
    var ocrFormat: RinkLensCaptureFormatPreference?
    var effectiveContract: RinkLensEffectiveCaptureContract?
    var appliedBroadcastQuality: RinkLensAppliedBroadcastCaptureQuality?
    var liveFormatText: String
    var ocrFormatText: String
    var liveConfiguredCadenceText: String
    var ocrConfiguredCadenceText: String
    var liveObservedFPS: Double
    var ocrObservedFPS: Double
    var failureLatched: Bool
    var failureText: String
    var sessionConfigured: Bool
    var sessionRunning: Bool
    var hardwareCost: Double
    var systemPressureCost: Double
    var degradedRecord: RinkLensCaptureDegradedRecord?
    var liveSystemPressureLevel: String
    var liveSystemPressureFactors: String
    var ocrSystemPressureLevel: String
    var ocrSystemPressureFactors: String
    var ocrPressurePolicyState: String
    var ocrPressureDeliveryFPS: Double
    var ocrPressureSuspended: Bool
    var broadcastPreservationActive: Bool
    var liveDroppedFrames: Int
    var liveDroppedLateFrames: Int
    var liveDroppedOutOfBuffers: Int
    var liveDroppedDiscontinuityFrames: Int
    var ocrDroppedFrames: Int
    var ocrDroppedLateFrames: Int
    var ocrDroppedOutOfBuffers: Int
    var ocrDroppedDiscontinuityFrames: Int
    var liveDroppedFramesLifetime: Int
    var liveDroppedLateFramesLifetime: Int
    var liveDroppedOutOfBuffersLifetime: Int
    var liveDroppedDiscontinuityFramesLifetime: Int
    var ocrDroppedFramesLifetime: Int
    var ocrDroppedLateFramesLifetime: Int
    var ocrDroppedOutOfBuffersLifetime: Int
    var ocrDroppedDiscontinuityFramesLifetime: Int
    var lastDroppedFrameText: String
    var liveFirstFrameLumaText: String
    var ocrFirstFrameLumaText: String
    var liveLastCallbackAgeSeconds: TimeInterval?
    var ocrLastCallbackAgeSeconds: TimeInterval?
    var liveCallbackLastMilliseconds: Double
    var liveCallbackMaxMilliseconds: Double
    var liveCallbackOverBudgetCount: Int
    var ocrCallbackLastMilliseconds: Double
    var ocrCallbackMaxMilliseconds: Double
    var ocrCallbackOverBudgetCount: Int
    var liveOutputConnectionText: String
    var ocrOutputConnectionText: String
    var ocrDeadBranchRecoveryCount: Int
    var ocrDeadBranchRecoveryFailureCount: Int
    var lastDeadBranchRecoveryText: String
    var externalOCRTopology: RinkLensExternalOCRTopology
    var ocrRecoveryRequirement: RinkLensOCRRecoveryRequirement?
    var transitionGeneration: Int
    var revision: UInt64

    static let idle = RinkLensCaptureEngineSnapshot(
        phase: .stopped,
        captureModeText: RinkLensCaptureLifecycleMode.stopped.rawValue,
        isActive: false,
        isTransitioning: false,
        previewAttached: false,
        broadcastPreviewAttached: false,
        ocrPreviewAttached: false,
        statusText: "MultiCam idle",
        devicePairText: "No MultiCam device pair selected",
        graphText: "MultiCam graph not configured",
        lastInterruptionText: "No MultiCam interruption",
        liveFramesReceived: 0,
        ocrFramesReceived: 0,
        liveDeviceID: nil,
        ocrDeviceID: nil,
        liveDeviceName: "none",
        liveDevicePositionText: "unavailable",
        liveDeviceTypeText: "unavailable",
        ocrDeviceName: "none",
        ocrDevicePositionText: "unavailable",
        ocrDeviceTypeText: "unavailable",
        liveFormat: nil,
        ocrFormat: nil,
        effectiveContract: nil,
        appliedBroadcastQuality: nil,
        liveFormatText: "MultiCam live format not configured",
        ocrFormatText: "MultiCam OCR format not configured",
        liveConfiguredCadenceText: "not configured",
        ocrConfiguredCadenceText: "not configured",
        liveObservedFPS: 0,
        ocrObservedFPS: 0,
        failureLatched: false,
        failureText: "none",
        sessionConfigured: false,
        sessionRunning: false,
        hardwareCost: 0,
        systemPressureCost: 0,
        degradedRecord: nil,
        liveSystemPressureLevel: "unavailable",
        liveSystemPressureFactors: "none",
        ocrSystemPressureLevel: "unavailable",
        ocrSystemPressureFactors: "none",
        ocrPressurePolicyState: "normal",
        ocrPressureDeliveryFPS: 0,
        ocrPressureSuspended: false,
        broadcastPreservationActive: false,
        liveDroppedFrames: 0,
        liveDroppedLateFrames: 0,
        liveDroppedOutOfBuffers: 0,
        liveDroppedDiscontinuityFrames: 0,
        ocrDroppedFrames: 0,
        ocrDroppedLateFrames: 0,
        ocrDroppedOutOfBuffers: 0,
        ocrDroppedDiscontinuityFrames: 0,
        liveDroppedFramesLifetime: 0,
        liveDroppedLateFramesLifetime: 0,
        liveDroppedOutOfBuffersLifetime: 0,
        liveDroppedDiscontinuityFramesLifetime: 0,
        ocrDroppedFramesLifetime: 0,
        ocrDroppedLateFramesLifetime: 0,
        ocrDroppedOutOfBuffersLifetime: 0,
        ocrDroppedDiscontinuityFramesLifetime: 0,
        lastDroppedFrameText: "none",
        liveFirstFrameLumaText: "no Broadcast frame sampled",
        ocrFirstFrameLumaText: "no OCR frame sampled",
        liveLastCallbackAgeSeconds: nil,
        ocrLastCallbackAgeSeconds: nil,
        liveCallbackLastMilliseconds: 0,
        liveCallbackMaxMilliseconds: 0,
        liveCallbackOverBudgetCount: 0,
        ocrCallbackLastMilliseconds: 0,
        ocrCallbackMaxMilliseconds: 0,
        ocrCallbackOverBudgetCount: 0,
        liveOutputConnectionText: "Broadcast output not configured",
        ocrOutputConnectionText: "OCR output not configured",
        ocrDeadBranchRecoveryCount: 0,
        ocrDeadBranchRecoveryFailureCount: 0,
        lastDeadBranchRecoveryText: "none",
        externalOCRTopology: .unavailable,
        ocrRecoveryRequirement: nil,
        transitionGeneration: 0,
        revision: 0
    )

    var activeMode: RinkLensCaptureLifecycleMode {
        RinkLensCaptureLifecycleMode(rawValue: captureModeText) ?? .stopped
    }

    var hasBothFirstFrames: Bool {
        liveFramesReceived > 0 && ocrFramesReceived > 0
    }

    /// First-frame readiness for the graph that is actually requested. Stage 7
    /// supports dual-camera and single-branch graphs in the same engine, so a
    /// Broadcast-only graph must not fail an invariant merely because no OCR
    /// branch was configured (and vice versa).
    var hasRequiredFirstFrames: Bool {
        switch RinkLensCaptureLifecycleMode(rawValue: captureModeText) {
        case .dualCamera:
            return hasBothFirstFrames
        case .broadcastOnly:
            return liveFramesReceived > 0
        case .ocrOnly:
            return ocrFramesReceived > 0
        case .stopped, .none:
            return false
        }
    }

    var healthSummary: String {
        "phase=\(phase.rawValue) mode=\(captureModeText) active=\(isActive) transitioning=\(isTransitioning) "
        + "configured=\(sessionConfigured) running=\(sessionRunning) "
        + "previews=broadcast:\(broadcastPreviewAttached)/ocr:\(ocrPreviewAttached) "
        + "formats=\(liveFormat?.diagnosticText ?? "none")/\(ocrFormat?.diagnosticText ?? "none") "
        + String(format: "observedFPS=%.1f/%.1f configured=%@/%@ ", liveObservedFPS, ocrObservedFPS, liveConfiguredCadenceText, ocrConfiguredCadenceText)
        + "effective={\(effectiveContract?.diagnosticText ?? "none")} "
        + "frames=\(liveFramesReceived)/\(ocrFramesReceived) callbackAge=\(liveLastCallbackAgeSeconds.map { String(format: "%.2fs", $0) } ?? "--")/\(ocrLastCallbackAgeSeconds.map { String(format: "%.2fs", $0) } ?? "--") "
        + String(format: "callbackMs=%.2f/max:%.2f over:%d / %.2f/max:%.2f over:%d ", liveCallbackLastMilliseconds, liveCallbackMaxMilliseconds, liveCallbackOverBudgetCount, ocrCallbackLastMilliseconds, ocrCallbackMaxMilliseconds, ocrCallbackOverBudgetCount)
        + "connections={\(liveOutputConnectionText)}/{\(ocrOutputConnectionText)} recoveries=\(ocrDeadBranchRecoveryCount)/failures=\(ocrDeadBranchRecoveryFailureCount) drops=\(liveDroppedFrames)/\(ocrDroppedFrames) "
        + "usb=disconnects:\(externalOCRTopology.disconnectCount)/reconnects:\(externalOCRTopology.reconnectCount)/revision:\(externalOCRTopology.revision) "
        + "pressure=\(liveSystemPressureLevel)/\(ocrSystemPressureLevel) policy=\(ocrPressurePolicyState) "
        + "broadcastPreserved=\(broadcastPreservationActive) degraded=\(degradedRecord?.diagnosticText ?? "none") revision=\(revision)"
    }
}

/// Main-actor-only projection used by SwiftUI. The capture engine emits complete
/// snapshots at a throttled rate; no `@Published` property exists on the engine.
@MainActor
final class ExternalOCRMultiCamUIState: ObservableObject {
    @Published private(set) var snapshot: RinkLensCaptureEngineSnapshot

    init(snapshot: RinkLensCaptureEngineSnapshot = .idle) {
        self.snapshot = snapshot
    }

    func apply(_ newSnapshot: RinkLensCaptureEngineSnapshot) {
        // Multiple engine queues may enqueue MainActor delivery close together.
        // Never allow an older snapshot to overwrite a newer lifecycle state.
        guard newSnapshot.revision >= snapshot.revision,
              newSnapshot != snapshot else { return }
        snapshot = newSnapshot
    }
}

// MARK: - Build 773 in-place rear framing mutation

/// Queue-confined hardware result returned to CaptureLifecycleController. It is
/// not application state; the authoritative applied camera state remains the
/// CaptureEngine snapshot and FrameHub generation/device evidence.
nonisolated struct RinkLensBroadcastInPlaceZoomResult: Sendable, Equatable {
    let succeeded: Bool
    let requiresStableGraph: Bool
    let statusText: String
    let physicalDeviceID: String?
    let physicalDeviceName: String
    let captureGeneration: Int
    let appliedCadence: RinkLensCaptureCadence?
    let appliedPhysicalZoom: Double?
    let strategy: String
}

/// One motion law shared by every Broadcast zoom command. The speed selector's
/// duration is the reference time for the complete logical 0.5x...5x range;
/// each physical command derives its duration from current hardware truth.
nonisolated enum RinkLensBroadcastZoomMotion {
    static let logicalRange: ClosedRange<CGFloat> = 0.5...5.0
    private static let fullRangeLogDistance = log(
        Double(logicalRange.upperBound / logicalRange.lowerBound)
    )

    static func duration(
        fullRangeDuration: TimeInterval,
        from currentLogicalZoom: CGFloat,
        to requestedLogicalZoom: CGFloat
    ) -> TimeInterval {
        let current = min(max(currentLogicalZoom, logicalRange.lowerBound), logicalRange.upperBound)
        let requested = min(max(requestedLogicalZoom, logicalRange.lowerBound), logicalRange.upperBound)
        guard fullRangeDuration > 0,
              fullRangeLogDistance > 0,
              current > 0,
              requested > 0 else { return 0 }
        // Constant linear-factor motion visibly changes speed at the 0.5x/1x
        // optical boundary. Human-visible magnification is multiplicative: a
        // doubling from 0.5x to 1x must take the same time as 1x to 2x.
        let perceptualDistance = abs(log(Double(requested / current)))
        return fullRangeDuration * (perceptualDistance / fullRangeLogDistance)
    }

    static func interpolatedLogicalZoom(
        from startLogicalZoom: CGFloat,
        to endLogicalZoom: CGFloat,
        progress: CGFloat
    ) -> CGFloat {
        let start = min(max(startLogicalZoom, logicalRange.lowerBound), logicalRange.upperBound)
        let end = min(max(endLogicalZoom, logicalRange.lowerBound), logicalRange.upperBound)
        let unitProgress = min(max(progress, 0), 1)
        guard start > 0, end > 0 else { return end }
        let startLog = log(Double(start))
        let endLog = log(Double(end))
        return CGFloat(exp(startLog + ((endLog - startLog) * Double(unitProgress))))
    }
}

// MARK: - UX16c38 concrete CaptureEngine implementation
// The concrete engine is compiled with its state contract so target membership
// cannot separate the type declaration from its lifecycle clients.

// MARK: - UX16c35 sole process-wide CaptureEngine

/// Owns the only active capture session while Broadcast uses a built-in camera
/// and OCR uses an external USB camera. Two independent AVCaptureSession objects
/// repeatedly interrupt one another on iPadOS; AVCaptureMultiCamSession is the
/// supported capture graph for simultaneous camera inputs.
nonisolated enum RinkLensOCRBranchConvergenceResult: Sendable, Equatable {
    case attached
    case alreadyAttached
    case unavailablePreservingBroadcast(String)

    var succeeded: Bool {
        switch self {
        case .attached, .alreadyAttached: return true
        case .unavailablePreservingBroadcast: return false
        }
    }

    var statusText: String {
        switch self {
        case .attached: return "OCR branch attached; Broadcast preserved"
        case .alreadyAttached: return "OCR branch already attached; Broadcast preserved"
        case .unavailablePreservingBroadcast(let detail): return "OCR branch unavailable; Broadcast preserved — \(detail)"
        }
    }
}

nonisolated final class ExternalOCRMultiCamCoordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// AVFoundation owner. SwiftUI must observe `uiState`, not this engine.
    let session = AVCaptureMultiCamSession()
    let uiState: ExternalOCRMultiCamUIState

    // Compatibility read-only projections. These values come from one immutable,
    // lock-protected engine snapshot rather than independently published properties.
    var snapshot: RinkLensCaptureEngineSnapshot { captureSnapshot() }
    var isActive: Bool { captureSnapshot().isActive }
    var isTransitioning: Bool { captureSnapshot().isTransitioning }
    var previewAttached: Bool { captureSnapshot().previewAttached }
    var statusText: String { captureSnapshot().statusText }
    var devicePairText: String { captureSnapshot().devicePairText }
    var graphText: String { captureSnapshot().graphText }
    var lastInterruptionText: String { captureSnapshot().lastInterruptionText }
    var liveFramesReceived: Int { captureSnapshot().liveFramesReceived }
    var ocrFramesReceived: Int { captureSnapshot().ocrFramesReceived }

    func installOCRRecoveryRequirementHandler(
        _ handler: @escaping @Sendable (RinkLensOCRRecoveryRequirement) -> Void
    ) {
        stateLock.lock()
        ocrRecoveryRequirementHandlerLocked = handler
        stateLock.unlock()
    }

    func acknowledgeOCRRecoveryRequirement(_ requirement: RinkLensOCRRecoveryRequirement) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            guard self.ocrRecoveryRequirementLocked == requirement else {
                self.stateLock.unlock()
                return
            }
            self.ocrRecoveryRequirementLocked = nil
            self.stateLock.unlock()
            self.publishSnapshot(phase: self.activeGraphModeLocked == .dualCamera ? .running : .degraded)
        }
    }

    private weak var liveService: HockeyCameraService?
    private weak var ocrService: HockeyCameraService?

    // Recovery AR / RL-095: CaptureEngine owns the only AVFoundation-to-app pixel
    // ownership boundary. The camera buffer is synchronously copied once into the
    // prewarmed application-owned FrameHub pool before any consumer sees pixels.
    // RecordingEngine owns the sink token/lifetime and receives only that owned
    // frame; no AVFoundation-owned CVPixelBuffer may escape captureOutput(...).
    private struct RecordingCaptureSink: @unchecked Sendable {
        let token: UUID
        let role: RinkLensFrameRole
        let handler: @Sendable (BroadcastRecordingCaptureFrame) -> Void
    }
    private let recordingCaptureSinkLock = NSLock()
    private var recordingCaptureSink: RecordingCaptureSink?
    private let programStreamCaptureSinkLock = NSLock()
    private var programStreamCaptureSink: RecordingCaptureSink?
    private struct BroadcastPreviewContinuityRequest: @unchecked Sendable {
        let id: UUID
        let completion: @Sendable (RinkLensFrameHubFrame?) -> Void
    }
    private let broadcastPreviewContinuityLock = NSLock()
    private var broadcastPreviewContinuityRequest: BroadcastPreviewContinuityRequest?
    private let broadcastPreviewContinuityRenderQueue = DispatchQueue(
        label: "camera.broadcast.preview-continuity.render",
        qos: .userInitiated
    )
    private let broadcastPreviewContinuityCIContext = CIContext(options: [.cacheIntermediates: false])

    private let sessionQueue = DispatchQueue(label: "camera.multicam.session.queue", qos: RinkLensExecutionQoSHierarchy.capture)
    private let sessionQueueKey = DispatchSpecificKey<UInt8>()
    private let sessionQueueIdentity: UInt8 = 1
    // Recovery D: sustained video callback work is not UI animation/event handling.
    // Use userInitiated for both real-time branches so Broadcast does not compete
    // with MainActor at userInteractive QoS and OCR is not starved at utility QoS.
    private let liveOutputQueue = DispatchQueue(label: "camera.multicam.live.output.queue", qos: RinkLensExecutionQoSHierarchy.capture)
    private let ocrOutputQueue = DispatchQueue(label: "camera.multicam.ocr.output.queue", qos: RinkLensExecutionQoSHierarchy.capture)
    private let stateLock = NSLock()
    // Build 774: one monotonic Broadcast zoom intent revision. It is not zoom
    // state; it only invalidates queued camera mutations superseded by a newer
    // slider/preset request before they reach the serial session queue.
    private let broadcastZoomIntentLock = NSLock()
    private var broadcastZoomIntentRevisionLocked: UInt64 = 0
    private struct PendingBroadcastZoomPreview {
        let logicalZoom: CGFloat
        let source: String
        let intentRevision: UInt64
    }
    // Capacity-one mailbox. Slider samples replace the pending value instead of
    // appending work to the AVFoundation session queue.
    private var pendingBroadcastZoomPreviewLocked: PendingBroadcastZoomPreview?
    private var broadcastZoomPreviewDrainScheduledLocked = false
    private var lastBroadcastZoomPreviewAppliedUptimeLocked: UInt64 = 0
    private var lastBroadcastZoomPreviewAppliedLogicalLocked: CGFloat = 1.0
    /// RL-111: one session-queue-owned zoom trajectory replaces
    /// AVCaptureDevice.ramp(...). Physical iPad evidence showed that identical
    /// requested rates complete at materially different speeds on different
    /// portions of the same lens. This timer is the actuator clock, not a retry:
    /// it evaluates one linear logical trajectory from monotonic elapsed time and
    /// writes only the newest sample to the physical camera.
    private var broadcastZoomTrajectoryTimer: DispatchSourceTimer?
    private var uiSnapshotLocked = RinkLensCaptureEngineSnapshot.idle
    private var sessionConfiguredSnapshotLocked = false
    private var sessionRunningSnapshotLocked = false
    private var hardwareCostSnapshotLocked: Double = 0
    private var pressureCostSnapshotLocked: Double = 0
    private var transitionGenerationSnapshotLocked = 0
    private var degradedRecordLocked: RinkLensCaptureDegradedRecord?
    private var degradedFailureCountLocked = 0
    private let failedContractCooldown: TimeInterval = 30.0

    private var liveSystemPressureLevelLocked = "unavailable"
    private var liveSystemPressureFactorsLocked = "none"
    private var ocrSystemPressureLevelLocked = "unavailable"
    private var ocrSystemPressureFactorsLocked = "none"
    private var livePressureObservation: NSKeyValueObservation?
    private var ocrPressureObservation: NSKeyValueObservation?

    private enum OCRPressurePolicyLevel: Int {
        case normal = 0
        case limited10FPS = 1
        case limited5FPS = 2
        case suspended = 3
    }
    private var ocrPressurePolicyLevelLocked: OCRPressurePolicyLevel = .normal
    private var ocrPressurePolicyStateLocked = "normal"
    private var ocrPressureDeliveryIntervalNanosecondsLocked: UInt64 = 0
    private var ocrPressureDeliveryFPSLocked: Double = 0
    private var ocrPressureSuspendedLocked = false
    private var broadcastPreservationActiveLocked = false
    // Applied cache only. Requested state is authoritative in RinkLensCameraControlStore.
    private var broadcastVideoStabilisationEnabledLocked = true
    private var lastOCRPressureDeliveryUptimeNanosecondsLocked: UInt64 = 0
    private var pressurePolicyGenerationLocked: UInt64 = 0
    private let pressureRecoveryHold: TimeInterval = 10.0

    private var liveDroppedFramesLocked = 0
    private var liveDroppedLateFramesLocked = 0
    private var liveDroppedOutOfBuffersLocked = 0
    private var liveDroppedDiscontinuityFramesLocked = 0
    private var ocrDroppedFramesLocked = 0
    private var ocrDroppedLateFramesLocked = 0
    private var ocrDroppedOutOfBuffersLocked = 0
    private var ocrDroppedDiscontinuityFramesLocked = 0
    private var liveDroppedFramesLifetimeLocked = 0
    private var liveDroppedLateFramesLifetimeLocked = 0
    private var liveDroppedOutOfBuffersLifetimeLocked = 0
    private var liveDroppedDiscontinuityFramesLifetimeLocked = 0
    private var ocrDroppedFramesLifetimeLocked = 0
    private var ocrDroppedLateFramesLifetimeLocked = 0
    private var ocrDroppedOutOfBuffersLifetimeLocked = 0
    private var ocrDroppedDiscontinuityFramesLifetimeLocked = 0
    private var dropCounterGenerationLocked = -1
    private var lastDroppedFrameTextLocked = "none"
    private var lastDropTelemetryPublishAtLocked: CFAbsoluteTime = 0
    private var dropTelemetryFlushScheduledLocked = false
    private var lastPublishedLiveDropTotalLocked = 0
    private var lastPublishedLiveLateTotalLocked = 0
    private var lastPublishedLiveOutOfBuffersTotalLocked = 0
    private var lastPublishedLiveDiscontinuityTotalLocked = 0
    private var lastPublishedOCRDropTotalLocked = 0
    private var lastPublishedOCRLateTotalLocked = 0
    private var lastPublishedOCROutOfBuffersTotalLocked = 0
    private var lastPublishedOCRDiscontinuityTotalLocked = 0
    private var lastHealthObservationPublishAtLocked: CFAbsoluteTime = 0
    private var liveLastCallbackUptimeNanosecondsLocked: UInt64?
    private var ocrLastCallbackUptimeNanosecondsLocked: UInt64?
    // Recovery D: full delegate residence, measured from callback entry through
    // owned-buffer publication and signal scheduling. These are owner-held
    // diagnostics only and never trigger capture policy.
    private var liveCallbackLastMillisecondsLocked: Double = 0
    private var liveCallbackMaxMillisecondsLocked: Double = 0
    private var liveCallbackOverBudgetCountLocked: Int = 0
    private var ocrCallbackLastMillisecondsLocked: Double = 0
    private var ocrCallbackMaxMillisecondsLocked: Double = 0
    private var ocrCallbackOverBudgetCountLocked: Int = 0
    private var outputDelegatesInstalledLocked = false
    private var liveOutputConnectionTextLocked = "Broadcast output not configured"
    private var ocrOutputConnectionTextLocked = "OCR output not configured"
    private var ocrDeadBranchRecoveryCountLocked = 0
    private var ocrDeadBranchRecoveryFailureCountLocked = 0
    private var lastDeadBranchRecoveryTextLocked = "none"
    private var externalOCRTopologyLocked = RinkLensExternalOCRTopology.unavailable
    private var ocrRecoveryRequirementLocked: RinkLensOCRRecoveryRequirement?
    private var ocrRecoveryRequirementHandlerLocked: (@Sendable (RinkLensOCRRecoveryRequirement) -> Void)?

    private let liveOutput = AVCaptureVideoDataOutput()
    private let ocrOutput = AVCaptureVideoDataOutput()
    private var liveInput: AVCaptureDeviceInput?
    private var ocrInput: AVCaptureDeviceInput?
    private var liveVideoPort: AVCaptureInput.Port?
    private var ocrVideoPort: AVCaptureInput.Port?
    private var liveOutputConnection: AVCaptureConnection?
    private var ocrOutputConnection: AVCaptureConnection?
    private var broadcastPreviewConnection: AVCaptureConnection?
    private var ocrPreviewConnection: AVCaptureConnection?
    private weak var attachedBroadcastPreviewLayer: AVCaptureVideoPreviewLayer?
    private weak var attachedOCRPreviewLayer: AVCaptureVideoPreviewLayer?
    private var broadcastPreviewRotationAngle: CGFloat = 0
    private var ocrPreviewRotationAngle: CGFloat = 0

    private var activeLiveDeviceID: String?
    private var activeOCRDeviceID: String?
    private var activeLiveDeviceNameLocked = "none"
    private var activeLiveDevicePositionTextLocked = "unavailable"
    private var activeLiveDeviceTypeTextLocked = "unavailable"
    private var activeOCRDeviceNameLocked = "none"
    private var activeOCRDevicePositionTextLocked = "unavailable"
    private var activeOCRDeviceTypeTextLocked = "unavailable"
    private var liveFirstFrameLumaTextLocked = "no Broadcast frame sampled"
    private var ocrFirstFrameLumaTextLocked = "no OCR frame sampled"
    // Recovery AI / RL-072: pixel-health is generation-scoped physical truth.
    // Lifetime frame counts do not identify the first frame after a graph rebuild.
    private var liveLumaSampledGenerationLocked = -1
    private var ocrLumaSampledGenerationLocked = -1
    private var activeGraphModeLocked: RinkLensCaptureLifecycleMode = .stopped
    private var transitionGeneration = 0
    private var configured = false
    private var activeLocked = false
    private var transitioningLocked = false
    private var previewAttachedLocked = false
    private var broadcastPreviewAttachedLocked = false
    private var ocrPreviewAttachedLocked = false
    private var liveFramesLocked = 0
    private var ocrFramesLocked = 0

    // Recovery R / RL-053 diagnostics only. Scene phase is a lifecycle observation,
    // not camera state and never drives CaptureEngine mutation. The session queue
    // samples AVFoundation truth after each scene transition so a future wake
    // failure can be ordered against isRunning/isInterrupted, device discovery,
    // callback freshness and FrameHub lease ownership.
    private var appScenePhaseLocked = "unknown"
    private var appScenePhaseChangedUptimeNanosecondsLocked: UInt64 = DispatchTime.now().uptimeNanoseconds
    private var lastFramePublishAt: CFAbsoluteTime = 0
    private var lastRequestedLiveLogicalSourceID: String?
    private var lastRequestedOCRLogicalSourceID: String?
    private var lastRequestedLiveDeviceID: String?
    private var lastRequestedOCRDeviceID: String?
    private var lastRequestedLiveFormat: RinkLensCaptureFormatPreference?
    private var lastRequestedOCRFormat: RinkLensCaptureFormatPreference?
    /// Requested preferences are retained for graph reuse decisions. Resolved
    /// formats are the typed AVFoundation truth published to lifecycle clients.
    private var activeLiveFormatPreference: RinkLensCaptureFormatPreference?
    private var activeOCRFormatPreference: RinkLensCaptureFormatPreference?
    private var activeLiveResolvedFormat: RinkLensCaptureFormatPreference?
    private var activeOCRResolvedFormat: RinkLensCaptureFormatPreference?
    private var activeEffectiveContract: RinkLensEffectiveCaptureContract?
    private var appliedBroadcastQualityLocked: RinkLensAppliedBroadcastCaptureQuality?
    private var broadcastQualityRejectionGateLocked = RinkLensBroadcastCaptureQualityRejectionGate()
    private var lastRequestedMode: RinkLensCaptureLifecycleMode = .stopped
    private var shouldAutoReconnect = false
    private var reconnectGeneration = 0
    private var lastStartFailureAt: CFAbsoluteTime = 0
    private var lastStartFailureText = "none"
    private var failureLatchedLocked = false
    private var liveFormatTextLocked = "MultiCam live format not configured"
    private var ocrFormatTextLocked = "MultiCam OCR format not configured"
    private var liveConfiguredCadenceTextLocked = "not configured"
    private var ocrConfiguredCadenceTextLocked = "not configured"
    private var configuredLiveCadenceLocked: RinkLensCaptureCadence?
    private var configuredOCRCadenceLocked: RinkLensCaptureCadence?

    // Requested camera-quality policy belongs only to RinkLensCameraControlStore.
    // CaptureEngine retains applied hardware truth only: framing, cadence and telemetry.
    // This enum is the last physically-applied policy projection so graph restarts can
    // reassert the same hardware behaviour without creating a second requested owner.
    private var appliedBroadcastImageQualityPolicyLocked: BroadcastImageQualityPolicy = .balanced
    private var broadcastHardwareTargetLogicalZoomLocked: CGFloat = 1.0
    private var lastDeferredBroadcastCadenceKeyLocked: String?
    private var lastBroadcastQualityTelemetryUptimeLocked: UInt64 = 0

    private var liveObservedFPSLocked: Double = 0
    private var ocrObservedFPSLocked: Double = 0
    private var liveObservedFrameUptimesLocked: [UInt64] = []
    private var ocrObservedFrameUptimesLocked: [UInt64] = []
    private let failedStartCooldown: CFTimeInterval = 30.0
    private let firstFrameReadinessTimeout: TimeInterval = 1.75

    /// A single event-driven readiness lease. Output callbacks satisfy this lease
    /// when every branch required by the requested graph has delivered a frame.
    /// DispatchTime provides a monotonic timeout unaffected by wall-clock changes.
    private struct FirstFrameReadinessWaiter: @unchecked Sendable {
        let token: UInt64
        let mode: RinkLensCaptureLifecycleMode
        let transitionGeneration: Int
        let startedUptimeNanoseconds: UInt64
        let completion: (Bool) -> Void
    }
    private var firstFrameReadinessTokenLocked: UInt64 = 0
    private var firstFrameReadinessWaiterLocked: FirstFrameReadinessWaiter?

    @MainActor
    init(liveService: HockeyCameraService, ocrService: HockeyCameraService) {
        self.liveService = liveService
        self.ocrService = ocrService
        self.uiState = ExternalOCRMultiCamUIState(snapshot: .idle)
        super.init()
        sessionQueue.setSpecific(key: sessionQueueKey, value: sessionQueueIdentity)
        configureOutputs()
        registerSessionObservers()
        trace("coordinator initialised session=\(sessionIdentifier)")
    }


    /// R13 controlled camera-quality transaction. Requested policy remains owned
    /// exclusively by RinkLensCameraControlStore. CaptureEngine receives the
    /// immutable request and returns only the verified physical cadence it applied.
    /// A live recording may authorise this mutation only after RecordingEngine has
    /// internally held appends for the same-file cadence handoff.
    func applyBroadcastImageQualityPolicy(
        _ policy: BroadcastImageQualityPolicy,
        effectiveTargetCadence: RinkLensCaptureCadence,
        reason: String,
        recordingTransitionAuthorised: Bool
    ) async -> RinkLensCaptureCadence? {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(
                    returning: self.applyBroadcastImageQualityPolicyOnSessionQueue(
                        policy,
                        effectiveTargetCadence: effectiveTargetCadence,
                        reason: reason,
                        recordingTransitionAuthorised: recordingTransitionAuthorised
                    )
                )
            }
        }
    }

    @discardableResult
    private func applyBroadcastImageQualityPolicyOnSessionQueue(
        _ policy: BroadcastImageQualityPolicy,
        effectiveTargetCadence: RinkLensCaptureCadence,
        reason: String,
        recordingTransitionAuthorised: Bool
    ) -> RinkLensCaptureCadence? {
        assertSessionQueue()
        let targetFPS = effectiveTargetCadence.framesPerSecond <= 30.25 ? 30 : 60
        let beforeCadence = activeLiveResolvedFormat?.cadence
        let writerContractOpen = RinkLensRecordingCaptureLease.shared.isWriterContractOpen()
        let canApply = !writerContractOpen || recordingTransitionAuthorised
        let currentDimensions = activeLiveResolvedFormat
            ?? RinkLensCaptureFormatPreference(width: 1920, height: 1080, fps: targetFPS)
        let appliedNow = canApply
            ? applyBroadcastFormatOnSessionQueue(
                targetPreference: .init(
                    width: currentDimensions.width,
                    height: currentDimensions.height,
                    cadence: .init(integerFPS: targetFPS)
                ),
                policy: policy,
                reason: "camera imaging profile \(policy.rawValue): \(reason)",
                allowOpenWriterContract: recordingTransitionAuthorised
            )
            : false

        RinkLensStructuredEventLogger.shared.record(
            domain: .cameraControl,
            event: canApply ? "camera_image_quality_fixed_mode_applied" : "camera_image_quality_policy_deferred_by_recording",
            entityID: "broadcast-connection",
            previous: [
                "fps": beforeCadence?.displayText ?? "unknown"
            ],
            next: [
                "policy": policy.rawValue,
                "requestedPolicyFPS": String(policy.preferredWideFPS),
                "effectiveTargetFPS": String(targetFPS),
                "appliedNow": String(appliedNow),
                "writerContractOpen": String(writerContractOpen),
                "recordingTransitionAuthorised": String(recordingTransitionAuthorised),
                "lightDrivenCadenceChanges": String(policy.allowsAutomaticFrameRate),
                "lowLightBoostRequested": String(policy.requestsAutomaticLowLightBoost)
            ],
            source: "ExternalOCRMultiCamCoordinator",
            reason: canApply
                ? reason
                : "Recording writer contract is open and no controlled same-file cadence transaction was authorised. \(reason)",
            captureGeneration: transitionGeneration,
            authoritativeOwner: "CaptureEngine"
        )

        guard appliedNow else { return nil }
        appliedBroadcastImageQualityPolicyLocked = policy
        return activeLiveResolvedFormat?.cadence
            ?? RinkLensCaptureCadence(integerFPS: targetFPS)
    }

    /// Applies one exact source-quality request and publishes requested versus
    /// physical truth. The caller owns lifecycle/writer/publisher coordination;
    /// this method owns only the serial AVFoundation format mutation.
    func applyBroadcastCaptureQuality(
        _ intent: RinkLensBroadcastCaptureQualityIntent,
        basePolicy: BroadcastImageQualityPolicy,
        reason: String,
        outputTransitionAuthorised: Bool
    ) async -> RinkLensAppliedBroadcastCaptureQuality? {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self,
                      let device = self.liveInput?.device,
                      let current = self.activeLiveResolvedFormat else {
                    continuation.resume(returning: nil)
                    return
                }
                let key = RinkLensBroadcastCaptureQualityCapabilityKey(
                    liveDeviceID: device.uniqueID,
                    ocrDeviceID: self.activeOCRDeviceID,
                    basePolicy: basePolicy,
                    domain: intent.domain
                )
                guard self.broadcastQualityRejectionGateLocked.shouldAttempt(key) else {
                    continuation.resume(returning: self.appliedBroadcastQualityLocked)
                    return
                }

                let activePolicyAllowsFormat = intent.width <= 2560 && intent.height <= 1440
                let applied = activePolicyAllowsFormat && self.applyBroadcastFormatOnSessionQueue(
                    targetPreference: intent.formatPreference,
                    policy: basePolicy,
                    reason: reason,
                    allowOpenWriterContract: outputTransitionAuthorised
                )
                if applied {
                    self.transitionGeneration += 1
                }
                let resolved = self.activeLiveResolvedFormat ?? current
                let limitation = applied ? nil : "\(intent.formatPreference.diagnosticText) is unavailable for the active camera/MultiCam contract"
                if applied {
                    self.broadcastQualityRejectionGateLocked.clear()
                } else {
                    self.broadcastQualityRejectionGateLocked.reject(key)
                }
                guard let evidence = self.broadcastCaptureQualityEvidenceOnSessionQueue(
                    requested: intent,
                    resolved: resolved,
                    hardwareLimitedReason: limitation
                ) else {
                    continuation.resume(returning: nil)
                    return
                }
                self.appliedBroadcastQualityLocked = evidence
                self.publishSnapshot { snapshot in
                    snapshot.appliedBroadcastQuality = evidence
                    snapshot.statusText = applied
                        ? "Base camera source active"
                        : "Requested source format unavailable; retained \(resolved.diagnosticText)"
                }
                continuation.resume(returning: evidence)
            }
        }
    }

    /// Publishes applied truth after a lifecycle-authorised branch replacement.
    /// This read/acknowledgement boundary never mutates the camera or advances a
    /// capture generation; the replacement transaction already owns both.
    func acknowledgeBroadcastCaptureQuality(
        _ intent: RinkLensBroadcastCaptureQualityIntent,
        hardwareLimitedReason: String? = nil
    ) async -> RinkLensAppliedBroadcastCaptureQuality? {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self,
                      let resolved = self.activeLiveResolvedFormat,
                      let evidence = self.broadcastCaptureQualityEvidenceOnSessionQueue(
                        requested: intent,
                        resolved: resolved,
                        hardwareLimitedReason: hardwareLimitedReason
                      ) else {
                    continuation.resume(returning: nil)
                    return
                }
                self.appliedBroadcastQualityLocked = evidence
                self.broadcastQualityRejectionGateLocked.clear()
                self.publishSnapshot { snapshot in
                    snapshot.appliedBroadcastQuality = evidence
                    snapshot.statusText = "Base camera source active"
                }
                continuation.resume(returning: evidence)
            }
        }
    }

    /// Waits on FrameHub's capacity-one evidence stream and samples exposure on
    /// the serial AVFoundation queue. This is a physical acknowledgement
    /// boundary, not a delay or brightness heuristic: a dark but settled image is
    /// valid, while a newly installed lens that is still changing ISO/shutter is
    /// not yet safe to reveal.
    func waitForBroadcastExposureConvergence(
        afterSequence minimumSequenceExclusive: Int,
        captureGeneration requiredCaptureGeneration: Int,
        physicalDeviceID requiredPhysicalDeviceID: String,
        timeout: TimeInterval
    ) async -> RinkLensBroadcastExposureSample? {
        var state = RinkLensBroadcastExposureConvergenceState(
            minimumSequenceExclusive: minimumSequenceExclusive,
            requiredCaptureGeneration: requiredCaptureGeneration,
            requiredPhysicalDeviceID: requiredPhysicalDeviceID
        )
        var latestSequence = minimumSequenceExclusive
        let timeoutNanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
        let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds

        while !Task.isCancelled {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return nil }
            let remaining = TimeInterval(deadline - now) / 1_000_000_000
            guard let evidence = await RinkLensFrameHub.shared.waitForFreshFrameEvidence(
                for: .broadcast,
                maxAge: 0.35,
                afterSequence: latestSequence,
                requiredCaptureGeneration: requiredCaptureGeneration,
                requiredPhysicalDeviceID: requiredPhysicalDeviceID,
                timeout: remaining
            ) else { return nil }
            latestSequence = evidence.sequence

            let sample: RinkLensBroadcastExposureSample? = await withCheckedContinuation { continuation in
                sessionQueue.async { [weak self] in
                    guard let self,
                          self.transitionGeneration == requiredCaptureGeneration,
                          let device = self.liveInput?.device,
                          device.uniqueID == requiredPhysicalDeviceID else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: .init(
                        sequence: evidence.sequence,
                        captureGeneration: requiredCaptureGeneration,
                        physicalDeviceID: requiredPhysicalDeviceID,
                        iso: device.iso,
                        exposureDurationSeconds: CMTimeGetSeconds(device.exposureDuration),
                        isAdjustingExposure: device.isAdjustingExposure
                    ))
                }
            }
            guard let sample else { return nil }
            if state.observe(sample) { return sample }
        }
        return nil
    }

    private func broadcastCaptureQualityEvidenceOnSessionQueue(
        requested intent: RinkLensBroadcastCaptureQualityIntent,
        resolved: RinkLensCaptureFormatPreference,
        hardwareLimitedReason: String?
    ) -> RinkLensAppliedBroadcastCaptureQuality? {
        assertSessionQueue()
        guard let device = liveInput?.device else { return nil }
        let constituentID: String? = {
            if #available(iOS 15.0, *) {
                return device.activePrimaryConstituent?.uniqueID
            }
            return nil
        }()
        return RinkLensAppliedBroadcastCaptureQuality(
            requested: intent,
            appliedFormat: resolved,
            physicalDeviceID: device.uniqueID,
            physicalDeviceType: device.deviceType.rawValue,
            activeConstituentID: constituentID,
            isVideoBinned: device.activeFormat.isVideoBinned,
            captureGeneration: transitionGeneration,
            acceptedFrameSequence: liveFramesLocked,
            hardwareLimitedReason: hardwareLimitedReason
        )
    }

    private func registerBroadcastZoomIntent() -> UInt64 {
        broadcastZoomIntentLock.lock()
        broadcastZoomIntentRevisionLocked &+= 1
        let revision = broadcastZoomIntentRevisionLocked
        broadcastZoomIntentLock.unlock()
        return revision
    }

    private func isLatestBroadcastZoomIntent(_ revision: UInt64) -> Bool {
        broadcastZoomIntentLock.lock()
        let isLatest = revision == broadcastZoomIntentRevisionLocked
        broadcastZoomIntentLock.unlock()
        return isLatest
    }

    /// R21 single Broadcast zoom actuator. Buttons, slider and post-handoff
    /// reconciliation all converge here. The session queue owns the one mutable
    /// AVCaptureDevice zoom state; queued stale desired targets are discarded.
    func applyBroadcastZoom(
        logicalZoom: CGFloat,
        animated: Bool,
        duration: TimeInterval,
        source: String
    ) {
        let intentRevision = registerBroadcastZoomIntent()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.isLatestBroadcastZoomIntent(intentRevision) else {
                traceZoomMovement(
                    "CaptureEngine zoom superseded source=\(source) logical=\(String(format: "%.2f", Double(logicalZoom))) revision=\(intentRevision)"
                )
                return
            }
            _ = self.applyBroadcastZoomOnSessionQueue(
                logicalZoom: logicalZoom,
                animated: animated,
                duration: duration,
                source: source,
                intentRevision: intentRevision,
                mutationPurpose: .operatorRequested
            )
        }
    }

    /// Applies the latest same-optical-domain slider sample without creating an
    /// unbounded queue. The caller owns optical-domain policy; CaptureEngine
    /// remains the sole writer of AVCaptureDevice.videoZoomFactor.
    func submitLatestBroadcastZoomPreview(logicalZoom: CGFloat, source: String) {
        let requested = min(max(logicalZoom.isFinite ? logicalZoom : 1.0, 0.5), 5.0)
        broadcastZoomIntentLock.lock()
        let comparison = pendingBroadcastZoomPreviewLocked?.logicalZoom
            ?? lastBroadcastZoomPreviewAppliedLogicalLocked
        guard abs(comparison - requested) >= BroadcastZoomGranularity.cameraUpdateMinimumDelta else {
            broadcastZoomIntentLock.unlock()
            return
        }
        broadcastZoomIntentRevisionLocked &+= 1
        let revision = broadcastZoomIntentRevisionLocked
        pendingBroadcastZoomPreviewLocked = PendingBroadcastZoomPreview(
            logicalZoom: requested,
            source: source,
            intentRevision: revision
        )
        let shouldSchedule = !broadcastZoomPreviewDrainScheduledLocked
        if shouldSchedule { broadcastZoomPreviewDrainScheduledLocked = true }
        broadcastZoomIntentLock.unlock()

        guard shouldSchedule else { return }
        sessionQueue.async { [weak self] in self?.drainLatestBroadcastZoomPreview() }
    }

    private func drainLatestBroadcastZoomPreview() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        let now = DispatchTime.now().uptimeNanoseconds
        let minimumInterval = UInt64(BroadcastZoomGranularity.cameraUpdateMinimumInterval * 1_000_000_000)

        broadcastZoomIntentLock.lock()
        guard let pending = pendingBroadcastZoomPreviewLocked else {
            broadcastZoomPreviewDrainScheduledLocked = false
            broadcastZoomIntentLock.unlock()
            return
        }
        if lastBroadcastZoomPreviewAppliedUptimeLocked > 0 {
            let earliest = lastBroadcastZoomPreviewAppliedUptimeLocked &+ minimumInterval
            if now < earliest {
                let remaining = earliest - now
                broadcastZoomIntentLock.unlock()
                sessionQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(min(remaining, UInt64(Int.max))))) { [weak self] in
                    self?.drainLatestBroadcastZoomPreview()
                }
                return
            }
        }
        pendingBroadcastZoomPreviewLocked = nil
        broadcastZoomIntentLock.unlock()

        if isLatestBroadcastZoomIntent(pending.intentRevision) {
            _ = applyBroadcastZoomOnSessionQueue(
                logicalZoom: pending.logicalZoom,
                animated: false,
                duration: 0,
                source: pending.source,
                intentRevision: pending.intentRevision,
                mutationPurpose: .operatorRequested
            )
            broadcastZoomIntentLock.lock()
            lastBroadcastZoomPreviewAppliedUptimeLocked = DispatchTime.now().uptimeNanoseconds
            lastBroadcastZoomPreviewAppliedLogicalLocked = pending.logicalZoom
            broadcastZoomIntentLock.unlock()
        }

        sessionQueue.async { [weak self] in self?.drainLatestBroadcastZoomPreview() }
    }

    /// Recovery A non-MainActor zoom executor. Button/slider intent is immutable input;
    /// the CaptureEngine session queue owns ramp submission, latest-request-wins
    /// coalescing and optional physical-settlement verification. Ordinary slider
    /// samples need no MainActor callback; a preset/slider commit receives only the
    /// final immutable result after physical settlement.
    func submitBroadcastZoomInPlace(
        logicalZoom: CGFloat,
        animated: Bool,
        duration: TimeInterval,
        source: String,
        waitForSettlement: Bool,
        completion: (@MainActor @Sendable (RinkLensBroadcastInPlaceZoomResult) -> Void)? = nil
    ) {
        let requested = min(max(logicalZoom.isFinite ? logicalZoom : 1.0, 0.5), 5.0)
        let intentRevision = registerBroadcastZoomIntent()
        sessionQueue.async { [weak self] in
            guard let self else {
                Self.deliverBroadcastZoomCompletion(
                    .init(
                        succeeded: false,
                        requiresStableGraph: false,
                        statusText: "CaptureEngine is unavailable.",
                        physicalDeviceID: nil,
                        physicalDeviceName: "none",
                        captureGeneration: 0,
                        appliedCadence: nil,
                        appliedPhysicalZoom: nil,
                        strategy: "engine-unavailable"
                    ),
                    completion: completion
                )
                return
            }
            guard self.isLatestBroadcastZoomIntent(intentRevision) else {
                Self.deliverBroadcastZoomCompletion(
                    .init(
                        succeeded: false,
                        requiresStableGraph: false,
                        statusText: "A newer Broadcast zoom request superseded this one.",
                        physicalDeviceID: self.liveInput?.device.uniqueID,
                        physicalDeviceName: self.liveInput?.device.localizedName ?? "none",
                        captureGeneration: self.transitionGeneration,
                        appliedCadence: self.activeLiveResolvedFormat?.cadence,
                        appliedPhysicalZoom: self.liveInput.map { Double($0.device.videoZoomFactor) },
                        strategy: "superseded-by-newer-intent"
                    ),
                    completion: completion
                )
                return
            }
            let initial = self.applyBroadcastZoomOnSessionQueue(
                logicalZoom: requested,
                animated: animated,
                duration: duration,
                source: source,
                intentRevision: intentRevision,
                mutationPurpose: .operatorRequested
            )
            guard initial.succeeded,
                  waitForSettlement,
                  animated,
                  duration > 0,
                  let expected = initial.appliedPhysicalZoom else {
                Self.deliverBroadcastZoomCompletion(initial, completion: completion)
                return
            }
            let deadline = DispatchTime.now().uptimeNanoseconds
                &+ UInt64(max(0.35, duration + 0.75) * 1_000_000_000)
            self.verifyBroadcastZoomSettlementOnSessionQueue(
                requestedLogicalZoom: requested,
                expectedPhysicalZoom: expected,
                intentRevision: intentRevision,
                initial: initial,
                deadlineUptimeNanoseconds: deadline,
                source: source,
                completion: completion
            )
        }
    }

    nonisolated private static func deliverBroadcastZoomCompletion(
        _ result: RinkLensBroadcastInPlaceZoomResult,
        completion: (@MainActor @Sendable (RinkLensBroadcastInPlaceZoomResult) -> Void)?
    ) {
        guard let completion else { return }
        Task { @MainActor in
            completion(result)
        }
    }

    private func verifyBroadcastZoomSettlementOnSessionQueue(
        requestedLogicalZoom: CGFloat,
        expectedPhysicalZoom: Double,
        intentRevision: UInt64,
        initial: RinkLensBroadcastInPlaceZoomResult,
        deadlineUptimeNanoseconds: UInt64,
        source: String,
        completion: (@MainActor @Sendable (RinkLensBroadcastInPlaceZoomResult) -> Void)?
    ) {
        assertSessionQueue()
        guard isLatestBroadcastZoomIntent(intentRevision) else {
            Self.deliverBroadcastZoomCompletion(
                .init(
                    succeeded: false,
                    requiresStableGraph: false,
                    statusText: "A newer Broadcast zoom request superseded this ramp.",
                    physicalDeviceID: initial.physicalDeviceID,
                    physicalDeviceName: initial.physicalDeviceName,
                    captureGeneration: initial.captureGeneration,
                    appliedCadence: initial.appliedCadence,
                    appliedPhysicalZoom: liveInput.map { Double($0.device.videoZoomFactor) },
                    strategy: "superseded-during-ramp"
                ),
                completion: completion
            )
            return
        }
        guard let device = liveInput?.device,
              device.uniqueID == initial.physicalDeviceID else {
            Self.deliverBroadcastZoomCompletion(
                .init(
                    succeeded: false,
                    requiresStableGraph: true,
                    statusText: "The Broadcast source changed before zoom settlement.",
                    physicalDeviceID: liveInput?.device.uniqueID,
                    physicalDeviceName: liveInput?.device.localizedName ?? initial.physicalDeviceName,
                    captureGeneration: transitionGeneration,
                    appliedCadence: activeLiveResolvedFormat?.cadence,
                    appliedPhysicalZoom: liveInput.map { Double($0.device.videoZoomFactor) },
                    strategy: "source-changed-during-ramp"
                ),
                completion: completion
            )
            return
        }
        let current = Double(device.videoZoomFactor)
        if !device.isRampingVideoZoom, abs(current - expectedPhysicalZoom) <= 0.02 {
            Self.deliverBroadcastZoomCompletion(initial, completion: completion)
            return
        }
        guard DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds else {
            Self.deliverBroadcastZoomCompletion(
                .init(
                    succeeded: false,
                    requiresStableGraph: false,
                    statusText: "The Broadcast zoom ramp did not settle at the requested factor.",
                    physicalDeviceID: device.uniqueID,
                    physicalDeviceName: device.localizedName,
                    captureGeneration: transitionGeneration,
                    appliedCadence: activeLiveResolvedFormat?.cadence,
                    appliedPhysicalZoom: current,
                    strategy: "zoom-ramp-timeout"
                ),
                completion: completion
            )
            return
        }
        sessionQueue.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in
            self?.verifyBroadcastZoomSettlementOnSessionQueue(
                requestedLogicalZoom: requestedLogicalZoom,
                expectedPhysicalZoom: expectedPhysicalZoom,
                intentRevision: intentRevision,
                initial: initial,
                deadlineUptimeNanoseconds: deadlineUptimeNanoseconds,
                source: source,
                completion: completion
            )
        }
    }

    private enum BroadcastZoomMutationPurpose: Sendable {
        case operatorRequested
        case opticalHandoffBoundary
    }

    /// Performs one operator-requested in-place virtual-camera zoom mutation and
    /// returns only after AVFoundation accepts the device configuration. Ultra
    /// Wide normal-domain requests remain rejected; only the separate lifecycle
    /// boundary API may transit Ultra Wide through logical 1x.
    func applyBroadcastZoomInPlace(
        logicalZoom: CGFloat,
        animated: Bool,
        duration: TimeInterval,
        source: String,
        waitForSettlement: Bool = true
    ) async -> RinkLensBroadcastInPlaceZoomResult {
        await applyBroadcastZoomInPlaceWithPurpose(
            logicalZoom: logicalZoom,
            animated: animated,
            duration: duration,
            source: source,
            waitForSettlement: waitForSettlement,
            mutationPurpose: .operatorRequested
        )
    }

    private func applyBroadcastZoomInPlaceWithPurpose(
        logicalZoom: CGFloat,
        animated: Bool,
        duration: TimeInterval,
        source: String,
        waitForSettlement: Bool,
        mutationPurpose: BroadcastZoomMutationPurpose
    ) async -> RinkLensBroadcastInPlaceZoomResult {
        let intentRevision = registerBroadcastZoomIntent()
        let initial: RinkLensBroadcastInPlaceZoomResult = await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .init(
                        succeeded: false,
                        requiresStableGraph: false,
                        statusText: "CaptureEngine is unavailable.",
                        physicalDeviceID: nil,
                        physicalDeviceName: "none",
                        captureGeneration: 0,
                        appliedCadence: nil,
                        appliedPhysicalZoom: nil,
                        strategy: "engine-unavailable"
                    ))
                    return
                }
                guard self.isLatestBroadcastZoomIntent(intentRevision) else {
                    continuation.resume(returning: .init(
                        succeeded: false,
                        requiresStableGraph: false,
                        statusText: "A newer Broadcast zoom request superseded this one.",
                        physicalDeviceID: self.liveInput?.device.uniqueID,
                        physicalDeviceName: self.liveInput?.device.localizedName ?? "none",
                        captureGeneration: self.transitionGeneration,
                        appliedCadence: self.activeLiveResolvedFormat?.cadence,
                        appliedPhysicalZoom: self.liveInput.map { Double($0.device.videoZoomFactor) },
                        strategy: "superseded-by-newer-intent"
                    ))
                    return
                }
                continuation.resume(returning: self.applyBroadcastZoomOnSessionQueue(
                    logicalZoom: logicalZoom,
                    animated: animated,
                    duration: duration,
                    source: source,
                    intentRevision: intentRevision,
                    mutationPurpose: mutationPurpose
                ))
            }
        }

        guard initial.succeeded else { return initial }
        if !waitForSettlement {
            return initial
        }
        guard animated,
              duration > 0.0,
              let expectedPhysicalZoom = initial.appliedPhysicalZoom else {
            return initial
        }

        // The device accepts ramp() synchronously but completes it over time. Do
        // not acknowledge the applied lens state until AVFoundation reports the
        // target factor and the ramp has stopped. Polling uses short queue reads;
        // the session queue is never slept or blocked.
        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ UInt64(max(0.35, duration + 0.75) * 1_000_000_000)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            guard isLatestBroadcastZoomIntent(intentRevision) else {
                return .init(
                    succeeded: false,
                    requiresStableGraph: false,
                    statusText: "A newer Broadcast zoom request superseded this ramp.",
                    physicalDeviceID: initial.physicalDeviceID,
                    physicalDeviceName: initial.physicalDeviceName,
                    captureGeneration: initial.captureGeneration,
                    appliedCadence: initial.appliedCadence,
                    appliedPhysicalZoom: initial.appliedPhysicalZoom,
                    strategy: "superseded-during-ramp"
                )
            }
            let settled: (current: Double, ramping: Bool, deviceID: String?) = await withCheckedContinuation { continuation in
                sessionQueue.async { [weak self] in
                    guard let self else {
                        continuation.resume(returning: (0.0, false, nil))
                        return
                    }
                    guard let device = self.liveInput?.device else {
                        continuation.resume(returning: (0.0, false, nil))
                        return
                    }
                    let current = Double(device.videoZoomFactor)
                    // Some physical devices leave isRampingVideoZoom asserted
                    // after the requested terminal factor has been reached. At
                    // that point the factor itself is the physical boundary
                    // acknowledgement. Stop the completed ramp on the same
                    // serial hardware queue so a stale flag cannot turn success
                    // into a timeout and leave applied zoom mirrored behind.
                    if abs(current - expectedPhysicalZoom) <= 0.02,
                       device.isRampingVideoZoom,
                       (try? device.lockForConfiguration()) != nil {
                        device.cancelVideoZoomRamp()
                        device.unlockForConfiguration()
                    }
                    continuation.resume(returning: (
                        Double(device.videoZoomFactor),
                        device.isRampingVideoZoom,
                        device.uniqueID
                    ))
                }
            }
            if settled.deviceID == initial.physicalDeviceID,
               abs(settled.current - expectedPhysicalZoom) <= 0.02 {
                return initial
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        let current: (zoom: Double, deviceID: String?) = await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                continuation.resume(returning: (
                    Double(self?.liveInput?.device.videoZoomFactor ?? 0.0),
                    self?.liveInput?.device.uniqueID
                ))
            }
        }
        return .init(
            succeeded: false,
            requiresStableGraph: false,
            statusText: "The virtual-camera zoom ramp did not settle at the requested factor.",
            physicalDeviceID: current.deviceID ?? initial.physicalDeviceID,
            physicalDeviceName: initial.physicalDeviceName,
            captureGeneration: initial.captureGeneration,
            appliedCadence: initial.appliedCadence,
            appliedPhysicalZoom: current.zoom,
            strategy: "virtual-rear-ramp-timeout"
        )
    }


    /// Build 777 replaces only the Broadcast input branch while the MultiCam
    /// session and OCR branch remain running. CaptureEngine remains the sole
    /// physical graph owner; the view and ViewModel receive only the immutable
    /// result and fresh FrameHub evidence.
    func replaceBroadcastBranchInPlace(
        physicalDeviceID: String,
        formatPreference: RinkLensCaptureFormatPreference,
        logicalZoom: CGFloat,
        source: String
    ) async -> RinkLensBroadcastInPlaceZoomResult {
        let intentRevision = registerBroadcastZoomIntent()
        return await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .init(
                        succeeded: false,
                        requiresStableGraph: true,
                        statusText: "CaptureEngine is unavailable.",
                        physicalDeviceID: nil,
                        physicalDeviceName: "none",
                        captureGeneration: 0,
                        appliedCadence: nil,
                        appliedPhysicalZoom: nil,
                        strategy: "engine-unavailable"
                    ))
                    return
                }
                self.assertSessionQueue()
                guard self.isLatestBroadcastZoomIntent(intentRevision) else {
                    continuation.resume(returning: .init(
                        succeeded: false,
                        requiresStableGraph: false,
                        statusText: "A newer Broadcast zoom request superseded this one.",
                        physicalDeviceID: self.liveInput?.device.uniqueID,
                        physicalDeviceName: self.liveInput?.device.localizedName ?? "none",
                        captureGeneration: self.transitionGeneration,
                        appliedCadence: self.activeLiveResolvedFormat?.cadence,
                        appliedPhysicalZoom: self.liveInput.map { Double($0.device.videoZoomFactor) },
                        strategy: "superseded-by-newer-intent"
                    ))
                    return
                }

                let requested = min(max(logicalZoom.isFinite ? logicalZoom : 1.0, 0.5), 5.0)
                guard self.configured,
                      self.session.isRunning,
                      self.activeGraphModeLocked.requiresBroadcast,
                      let oldInput = self.liveInput,
                      let oldPort = self.liveVideoPort else {
                    continuation.resume(returning: .init(
                        succeeded: false,
                        requiresStableGraph: true,
                        statusText: "The active Broadcast branch is not ready for replacement.",
                        physicalDeviceID: self.liveInput?.device.uniqueID,
                        physicalDeviceName: self.liveInput?.device.localizedName ?? "none",
                        captureGeneration: self.transitionGeneration,
                        appliedCadence: self.activeLiveResolvedFormat?.cadence,
                        appliedPhysicalZoom: self.liveInput.map { Double($0.device.videoZoomFactor) },
                        strategy: "branch-not-ready"
                    ))
                    return
                }

                if oldInput.device.uniqueID == physicalDeviceID {
                    continuation.resume(returning: self.applyBroadcastZoomOnSessionQueue(
                        logicalZoom: requested,
                        animated: false,
                        duration: 0,
                        source: source,
                        intentRevision: intentRevision,
                        mutationPurpose: .operatorRequested
                    ))
                    return
                }

                self.cancelBroadcastZoomTrajectoryOnSessionQueue(
                    reason: "Broadcast physical input replacement"
                )

                let discovery = AVCaptureDevice.DiscoverySession(
                    deviceTypes: [
                        .builtInDualWideCamera,
                        .builtInTripleCamera,
                        .builtInDualCamera,
                        .builtInWideAngleCamera,
                        .builtInUltraWideCamera,
                        .builtInTelephotoCamera
                    ],
                    mediaType: .video,
                    position: .back
                )
                guard let targetDevice = discovery.devices.first(where: { $0.uniqueID == physicalDeviceID }) else {
                    continuation.resume(returning: .init(
                        succeeded: false,
                        requiresStableGraph: true,
                        statusText: "The requested rear camera is no longer available.",
                        physicalDeviceID: oldInput.device.uniqueID,
                        physicalDeviceName: oldInput.device.localizedName,
                        captureGeneration: self.transitionGeneration,
                        appliedCadence: self.activeLiveResolvedFormat?.cadence,
                        appliedPhysicalZoom: Double(oldInput.device.videoZoomFactor),
                        strategy: "target-device-missing"
                    ))
                    return
                }

                self.setTransitioningLocked(true)
                self.publishSnapshot(phase: .configuring)

                let oldDataConnection = self.liveOutputConnection
                let oldPreviewConnection = self.broadcastPreviewConnection
                var newInput: AVCaptureDeviceInput?
                var newDataConnection: AVCaptureConnection?
                var newPreviewConnection: AVCaptureConnection?
                var targetCadence: RinkLensCaptureCadence?
                var configurationBegan = false

                do {
                    // R22 follows AVFoundation's predictable device lifecycle:
                    // attach the new AVCaptureDeviceInput first, then configure the
                    // device format/frame-duration/zoom while it belongs to the
                    // session transaction. Adding an input may reset device state.
                    let candidateInput = try AVCaptureDeviceInput(device: targetDevice)
                    newInput = candidateInput

                    self.session.beginConfiguration()
                    configurationBegan = true
                    if let oldPreviewConnection,
                       self.session.connections.contains(where: { $0 === oldPreviewConnection }) {
                        self.session.removeConnection(oldPreviewConnection)
                    }
                    if let oldDataConnection,
                       self.session.connections.contains(where: { $0 === oldDataConnection }) {
                        self.session.removeConnection(oldDataConnection)
                    }
                    if self.session.inputs.contains(where: { $0 === oldInput }) {
                        self.session.removeInput(oldInput)
                    }

                    guard self.session.canAddInput(candidateInput) else {
                        throw MultiCamError.cannotAddLiveInput
                    }
                    self.session.addInputWithNoConnections(candidateInput)

                    let cadence = try self.applyConservativeMultiCamFormat(
                        to: targetDevice,
                        preference: formatPreference,
                        fallbackWidth: 1920,
                        fallbackHeight: 1080,
                        fallbackFPS: Double(formatPreference.nominalFPS),
                        requireExactFallbackDimensions: true
                    )
                    targetCadence = cadence
                    candidateInput.videoMinFrameDurationOverride = cadence.duration
                    try self.applyRequestedBroadcastFramingBeforeGraphStart(
                        to: targetDevice,
                        logicalZoom: requested,
                        reason: "R22 configure attached Broadcast input after session admission"
                    )

                    guard let candidatePort = candidateInput.ports.first(where: { $0.mediaType == .video }) else {
                        throw MultiCamError.liveVideoPortMissing
                    }

                    let dataConnection = AVCaptureConnection(inputPorts: [candidatePort], output: self.liveOutput)
                    guard self.session.canAddConnection(dataConnection) else {
                        throw MultiCamError.cannotConnectLiveOutput
                    }
                    self.session.addConnection(dataConnection)
                    self.applyDataConnectionSettings(dataConnection, role: .broadcast, mirrored: false)
                    newDataConnection = dataConnection

                    if let previewLayer = self.attachedBroadcastPreviewLayer {
                        let previewConnection = AVCaptureConnection(
                            inputPort: candidatePort,
                            videoPreviewLayer: previewLayer
                        )
                        guard self.session.canAddConnection(previewConnection) else {
                            throw MultiCamError.cannotConnectLiveOutput
                        }
                        self.session.addConnection(previewConnection)
                        self.applyPreviewConnectionSettings(
                            previewConnection,
                            rotationAngle: self.broadcastPreviewRotationAngle
                        )
                        newPreviewConnection = previewConnection
                    }

                    let hardwareCost = Double(self.session.hardwareCost)
                    guard hardwareCost < 1.0 else {
                        throw MultiCamError.hardwareCostExceeded(hardwareCost)
                    }
                    let pressureCost = Double(self.session.systemPressureCost)
                    guard pressureCost < 1.0 else {
                        throw MultiCamError.systemPressureCostTooHigh(pressureCost)
                    }
                    self.session.commitConfiguration()
                    configurationBegan = false

                    self.transitionGeneration += 1
                    self.liveInput = candidateInput
                    self.liveVideoPort = candidatePort
                    self.liveOutputConnection = dataConnection
                    self.setPreviewConnection(
                        newPreviewConnection,
                        layer: self.attachedBroadcastPreviewLayer,
                        for: .broadcast
                    )
                    self.setPreviewAttachedLocked(
                        role: .broadcast,
                        attached: newPreviewConnection != nil
                    )

                    let dimensions = CMVideoFormatDescriptionGetDimensions(targetDevice.activeFormat.formatDescription)
                    let resolved = RinkLensCaptureFormatPreference(
                        width: dimensions.width,
                        height: dimensions.height,
                        cadence: RinkLensCaptureCadence(duration: targetDevice.activeVideoMinFrameDuration)
                    )

                    self.stateLock.lock()
                    self.configuredLiveCadenceLocked = cadence
                    self.liveConfiguredCadenceTextLocked =
                        "Build 777 branch replacement requested \(cadence.displayText)fps; awaiting callback verification"
                    self.activeLiveDeviceID = targetDevice.uniqueID
                    self.activeLiveDeviceNameLocked = targetDevice.localizedName
                    self.activeLiveDevicePositionTextLocked = Self.positionText(targetDevice.position)
                    self.activeLiveDeviceTypeTextLocked = targetDevice.deviceType.rawValue
                    self.activeLiveFormatPreference = formatPreference
                    self.activeLiveResolvedFormat = resolved
                    self.liveFormatTextLocked = "CaptureEngine Broadcast source \(resolved.diagnosticText) branch-replacement verified"
                    self.liveFramesLocked = 0
                    self.liveObservedFPSLocked = 0
                    self.liveLastCallbackUptimeNanosecondsLocked = nil
                    self.liveObservedFrameUptimesLocked.removeAll(keepingCapacity: true)
                    self.liveFirstFrameLumaTextLocked =
                        "awaiting Broadcast frame for generation \(self.transitionGeneration)"
                    if let current = self.activeEffectiveContract {
                        let previousDesired = current.desired
                        let desired = RinkLensDesiredCaptureContract(
                            mode: previousDesired.mode,
                            liveLogicalSourceID: previousDesired.liveLogicalSourceID,
                            ocrLogicalSourceID: previousDesired.ocrLogicalSourceID,
                            livePreferredDeviceID: targetDevice.uniqueID,
                            ocrPreferredDeviceID: previousDesired.ocrPreferredDeviceID,
                            liveFormat: formatPreference,
                            ocrFormat: previousDesired.ocrFormat
                        )
                        self.activeEffectiveContract = RinkLensEffectiveCaptureContract(
                            desired: desired,
                            liveActiveDeviceID: targetDevice.uniqueID,
                            ocrActiveDeviceID: current.ocrActiveDeviceID,
                            liveFormat: resolved,
                            ocrFormat: current.ocrFormat
                        )
                    }
                    self.stateLock.unlock()

                    RinkLensFrameHub.shared.clear(
                        role: .broadcast,
                        reason: "Build 777 Broadcast branch replaced generation=\(self.transitionGeneration)"
                    )
                    self.installSystemPressureObserversOnSessionQueue(
                        liveDevice: targetDevice,
                        ocrDevice: self.ocrInput?.device
                    )
                    self.liveService?.setExternallyManagedCaptureActive(
                        true,
                        device: targetDevice,
                        owner: "Build 777 CaptureEngine Broadcast branch replacement"
                    )
                    self.updateBroadcastHardwareTargetLogicalZoom(
                        requested,
                        device: targetDevice,
                        source: source,
                        reason: "Broadcast branch hardware target accepted; verified applied state is acknowledged by the zoom store"
                    )
                    self.refreshOutputConnectionTruthOnSessionQueue(reason: "Build 777 Broadcast branch replaced")
                    self.setTransitioningLocked(false)
                    self.publishSnapshot(phase: .running) { snapshot in
                        snapshot.statusText = String(format: "Broadcast framing %.1fx", Double(requested))
                        snapshot.devicePairText = self.deviceDescription(
                            mode: self.activeGraphModeLocked,
                            live: targetDevice,
                            ocr: self.ocrInput?.device
                        )
                        snapshot.graphText = self.graphDescription() + " branchReplacement=true"
                    }
                    self.trace(
                        "Build 777 Broadcast branch replaced \(oldInput.device.localizedName){\(oldInput.device.uniqueID)} "
                        + "-> \(targetDevice.localizedName){\(targetDevice.uniqueID)} "
                        + "format=\(resolved.diagnosticText) logical=\(String(format: "%.1f", Double(requested))) "
                        + "sessionRestarted=false reason=\(source)"
                    )
                    continuation.resume(returning: .init(
                        succeeded: true,
                        requiresStableGraph: false,
                        statusText: "Camera framing ready.",
                        physicalDeviceID: targetDevice.uniqueID,
                        physicalDeviceName: targetDevice.localizedName,
                        captureGeneration: self.transitionGeneration,
                        appliedCadence: resolved.cadence,
                        appliedPhysicalZoom: Double(targetDevice.videoZoomFactor),
                        strategy: "live-branch-replaced"
                    ))
                } catch {
                    if configurationBegan {
                        if let newPreviewConnection,
                           self.session.connections.contains(where: { $0 === newPreviewConnection }) {
                            self.session.removeConnection(newPreviewConnection)
                        }
                        if let newDataConnection,
                           self.session.connections.contains(where: { $0 === newDataConnection }) {
                            self.session.removeConnection(newDataConnection)
                        }
                        if let newInput,
                           self.session.inputs.contains(where: { $0 === newInput }) {
                            self.session.removeInput(newInput)
                        }

                        var restoredDataConnection: AVCaptureConnection?
                        var restoredPreviewConnection: AVCaptureConnection?
                        if !self.session.inputs.contains(where: { $0 === oldInput }),
                           self.session.canAddInput(oldInput) {
                            self.session.addInputWithNoConnections(oldInput)
                        }
                        if self.session.inputs.contains(where: { $0 === oldInput }) {
                            let dataConnection = AVCaptureConnection(inputPorts: [oldPort], output: self.liveOutput)
                            if self.session.canAddConnection(dataConnection) {
                                self.session.addConnection(dataConnection)
                                self.applyDataConnectionSettings(dataConnection, role: .broadcast, mirrored: false)
                                restoredDataConnection = dataConnection
                            }
                            if let previewLayer = self.attachedBroadcastPreviewLayer {
                                let previewConnection = AVCaptureConnection(
                                    inputPort: oldPort,
                                    videoPreviewLayer: previewLayer
                                )
                                if self.session.canAddConnection(previewConnection) {
                                    self.session.addConnection(previewConnection)
                                    self.applyPreviewConnectionSettings(
                                        previewConnection,
                                        rotationAngle: self.broadcastPreviewRotationAngle
                                    )
                                    restoredPreviewConnection = previewConnection
                                }
                            }
                        }
                        self.session.commitConfiguration()
                        configurationBegan = false
                        self.liveOutputConnection = restoredDataConnection
                        self.setPreviewConnection(
                            restoredPreviewConnection,
                            layer: self.attachedBroadcastPreviewLayer,
                            for: .broadcast
                        )
                        self.setPreviewAttachedLocked(
                            role: .broadcast,
                            attached: restoredPreviewConnection != nil
                        )
                    }
                    self.refreshOutputConnectionTruthOnSessionQueue(reason: "Build 779 branch replacement rollback")
                    self.setTransitioningLocked(false)
                    self.publishSnapshot(phase: .running) { snapshot in
                        snapshot.graphText = self.graphDescription() + " branchReplacementRollback=true"
                    }
                    self.trace(
                        "Build 777 Broadcast branch replacement failed target=\(targetDevice.localizedName) "
                        + "cadence=\(targetCadence?.displayText ?? "none") error=\(error.localizedDescription)"
                    )
                    continuation.resume(returning: .init(
                        succeeded: false,
                        requiresStableGraph: true,
                        statusText: "The requested Broadcast framing could not be applied; the verified source was retained.",
                        physicalDeviceID: oldInput.device.uniqueID,
                        physicalDeviceName: oldInput.device.localizedName,
                        captureGeneration: self.transitionGeneration,
                        appliedCadence: self.activeLiveResolvedFormat?.cadence,
                        appliedPhysicalZoom: Double(oldInput.device.videoZoomFactor),
                        strategy: "branch-replacement-rolled-back"
                    ))
                }
            }
        }
    }

    private func cancelBroadcastZoomTrajectoryOnSessionQueue(reason: String) {
        assertSessionQueue()
        guard let timer = broadcastZoomTrajectoryTimer else { return }
        broadcastZoomTrajectoryTimer = nil
        timer.setEventHandler {}
        timer.cancel()
        traceZoomMovement("CaptureEngine zoom trajectory cancelled reason=\(reason)")
    }

    /// Executes one logarithmic logical-zoom trajectory from monotonic time. A new
    /// intent supersedes the prior trajectory by revision; there is never more
    /// than one timer or queued path of intermediate camera writes.
    private func startBroadcastZoomTrajectoryOnSessionQueue(
        device: AVCaptureDevice,
        fromLogicalZoom: CGFloat,
        toLogicalZoom: CGFloat,
        duration: TimeInterval,
        intentRevision: UInt64,
        source: String
    ) {
        assertSessionQueue()
        cancelBroadcastZoomTrajectoryOnSessionQueue(reason: "superseded by revision \(intentRevision)")

        let startedUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        let durationNanoseconds = max(UInt64(duration * 1_000_000_000), 1)
        let deviceID = device.uniqueID
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        broadcastZoomTrajectoryTimer = timer
        timer.schedule(
            deadline: .now(),
            repeating: .milliseconds(16),
            leeway: .milliseconds(2)
        )
        timer.setEventHandler { [weak self, weak device] in
            guard let self, let device else { return }
            self.assertSessionQueue()
            guard self.broadcastZoomTrajectoryTimer === timer else { return }
            guard self.isLatestBroadcastZoomIntent(intentRevision),
                  self.session.isRunning,
                  self.liveInput?.device.uniqueID == deviceID else {
                self.cancelBroadcastZoomTrajectoryOnSessionQueue(
                    reason: "revision/source no longer authoritative"
                )
                return
            }

            let elapsed = DispatchTime.now().uptimeNanoseconds &- startedUptimeNanoseconds
            let progress = min(max(CGFloat(elapsed) / CGFloat(durationNanoseconds), 0), 1)
            let logical = RinkLensBroadcastZoomMotion.interpolatedLogicalZoom(
                from: fromLogicalZoom,
                to: toLogicalZoom,
                progress: progress
            )
            let physical = self.physicalBroadcastZoomFactor(for: logical, device: device)

            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = physical
                device.unlockForConfiguration()
            } catch {
                self.traceZoomMovement(
                    "CaptureEngine zoom trajectory failed source=\(source) revision=\(intentRevision) error=\(error.localizedDescription)"
                )
                self.cancelBroadcastZoomTrajectoryOnSessionQueue(reason: "device configuration failed")
                return
            }

            guard progress >= 1 else { return }
            self.traceZoomMovement(
                "CaptureEngine zoom trajectory completed source=\(source) revision=\(intentRevision) "
                + "logical=\(String(format: "%.2f", Double(toLogicalZoom))) "
                + "duration=\(String(format: "%.3f", duration))s"
            )
            RinkLensStructuredEventLogger.shared.record(
                domain: .camera,
                event: "camera_broadcast_zoom_trajectory_completed",
                entityID: deviceID,
                next: [
                    "logicalZoom": String(Double(toLogicalZoom)),
                    "physicalZoom": String(Double(device.videoZoomFactor)),
                    "durationSeconds": String(duration),
                    "intentRevision": String(intentRevision)
                ],
                source: "ExternalOCRMultiCamCoordinator",
                reason: source,
                captureGeneration: self.transitionGeneration,
                authoritativeOwner: "CaptureEngine"
            )
            self.cancelBroadcastZoomTrajectoryOnSessionQueue(reason: "trajectory completed")
        }
        timer.resume()
        traceZoomMovement(
            "CaptureEngine zoom trajectory started source=\(source) revision=\(intentRevision) "
            + "logical=\(String(format: "%.2f", Double(fromLogicalZoom)))->\(String(format: "%.2f", Double(toLogicalZoom))) "
            + "duration=\(String(format: "%.3f", duration))s"
        )
    }

    /// Recovery DB / RL-174: the only sanctioned Ultra-Wide >=1x mutation is
    /// the transient shared-field-of-view boundary used inside an immutable
    /// CaptureLifecycleController optical handoff. It is never an operator-applied
    /// state and cannot be used for 3x/5x or normal-domain acknowledgement.
    func applyBroadcastOpticalHandoffBoundaryInPlace(
        animated: Bool,
        duration: TimeInterval,
        source: String
    ) async -> RinkLensBroadcastInPlaceZoomResult {
        await applyBroadcastZoomInPlaceWithPurpose(
            logicalZoom: 1.0,
            animated: animated,
            duration: duration,
            source: source,
            waitForSettlement: true,
            mutationPurpose: .opticalHandoffBoundary
        )
    }

    private func applyBroadcastZoomOnSessionQueue(
        logicalZoom: CGFloat,
        animated: Bool,
        duration: TimeInterval,
        source: String,
        intentRevision: UInt64,
        mutationPurpose: BroadcastZoomMutationPurpose
    ) -> RinkLensBroadcastInPlaceZoomResult {
        assertSessionQueue()
        let requested = min(max(logicalZoom.isFinite ? logicalZoom : 1.0, 0.5), 5.0)
        guard let device = liveInput?.device,
              activeGraphModeLocked.requiresBroadcast,
              session.isRunning else {
            traceZoomMovement(
                "CaptureEngine zoom deferred source=\(source) logical=\(String(format: "%.2f", Double(requested))) reason=live-input-not-ready"
            )
            return .init(
                succeeded: false,
                requiresStableGraph: false,
                statusText: "The Broadcast input is not ready.",
                physicalDeviceID: liveInput?.device.uniqueID,
                physicalDeviceName: liveInput?.device.localizedName ?? "none",
                captureGeneration: transitionGeneration,
                appliedCadence: activeLiveResolvedFormat?.cadence,
                appliedPhysicalZoom: liveInput.map { Double($0.device.videoZoomFactor) },
                strategy: "input-not-ready"
            )
        }

        let multiplier = max(CGFloat(device.displayVideoZoomFactorMultiplier), 0.01)
        let isVirtualRear = device.position == .back
            && (device.deviceType == .builtInDualWideCamera
                || device.deviceType == .builtInTripleCamera
                || device.deviceType == .builtInDualCamera)
        let isPhysicalUltraWide = device.position == .back
            && (device.deviceType == .builtInUltraWideCamera
                || device.localizedName.localizedCaseInsensitiveContains("ultra"))
        if requested < 1.0, !isVirtualRear, !isPhysicalUltraWide {
            return .init(
                succeeded: false,
                requiresStableGraph: true,
                statusText: "The active Wide input cannot expose 0.5x without one stable rear-input migration.",
                physicalDeviceID: device.uniqueID,
                physicalDeviceName: device.localizedName,
                captureGeneration: transitionGeneration,
                appliedCadence: activeLiveResolvedFormat?.cadence,
                appliedPhysicalZoom: Double(device.videoZoomFactor),
                strategy: "stable-graph-required"
            )
        }
        if requested >= 1.0, isPhysicalUltraWide, mutationPurpose != .opticalHandoffBoundary {
            // Recovery DA / RL-174 hard physical invariant. Field-of-view parity is
            // not image-quality parity: 1x implemented as 2x crop on the physical
            // Ultra Wide is forbidden. The lifecycle owner must migrate to Wide
            // before this logical zoom can be acknowledged. Recovery DB permits
            // only the typed internal shared-boundary transit used to perform that
            // migration; ordinary operator commands remain rejected.
            RinkLensStructuredEventLogger.shared.record(
                domain: .cameraControl,
                event: "camera_zoom_normal_domain_rejected_on_ultra_wide",
                entityID: device.uniqueID,
                previous: [
                    "physicalDevice": device.localizedName,
                    "physicalZoom": String(Double(device.videoZoomFactor))
                ],
                next: [
                    "logicalZoom": String(Double(requested)),
                    "requiredDomain": "Wide-or-eligible-virtual-rear"
                ],
                source: "ExternalOCRMultiCamCoordinator.applyBroadcastZoomOnSessionQueue",
                reason: "Recovery DA quality invariant prevents Ultra Wide 2x crop from representing logical 1x-5x",
                captureGeneration: transitionGeneration,
                authoritativeOwner: "CaptureEngine"
            )
            return .init(
                succeeded: false,
                requiresStableGraph: true,
                statusText: "Wide camera handoff required for normal Broadcast zoom.",
                physicalDeviceID: device.uniqueID,
                physicalDeviceName: device.localizedName,
                captureGeneration: transitionGeneration,
                appliedCadence: activeLiveResolvedFormat?.cadence,
                appliedPhysicalZoom: Double(device.videoZoomFactor),
                strategy: "normal-domain-requires-wide"
            )
        }

        if isPhysicalUltraWide, mutationPurpose == .opticalHandoffBoundary {
            guard abs(requested - 1.0) < 0.01 else {
                return .init(
                    succeeded: false,
                    requiresStableGraph: true,
                    statusText: "Invalid Ultra Wide optical-boundary request.",
                    physicalDeviceID: device.uniqueID,
                    physicalDeviceName: device.localizedName,
                    captureGeneration: transitionGeneration,
                    appliedCadence: activeLiveResolvedFormat?.cadence,
                    appliedPhysicalZoom: Double(device.videoZoomFactor),
                    strategy: "invalid-optical-boundary"
                )
            }
            RinkLensStructuredEventLogger.shared.record(
                domain: .cameraControl,
                event: "camera_zoom_ultra_wide_boundary_transit_admitted",
                entityID: device.uniqueID,
                previous: [
                    "physicalDevice": device.localizedName,
                    "physicalZoom": String(Double(device.videoZoomFactor))
                ],
                next: [
                    "logicalBoundary": "1.0",
                    "finalOperatorState": "false",
                    "nextRequiredDomain": "Wide-or-eligible-virtual-rear"
                ],
                source: "ExternalOCRMultiCamCoordinator.applyBroadcastOpticalHandoffBoundaryInPlace",
                reason: "Recovery DB permits Ultra Wide to traverse the shared visual boundary only inside the immutable optical handoff",
                captureGeneration: transitionGeneration,
                authoritativeOwner: "CaptureEngine"
            )
        }

        // Build 785 R3: the active capture/recording profile owns cadence. Crossing
        // a virtual rear switch-over factor changes only videoZoomFactor; AVFoundation
        // selects the constituent camera without a frame-duration mutation.
        let previousCadence = RinkLensCaptureCadence(duration: device.activeVideoMinFrameDuration)
        let physical = physicalBroadcastZoomFactor(
            for: requested,
            device: device,
            multiplier: multiplier,
            isVirtualRear: isVirtualRear,
            isPhysicalUltraWide: isPhysicalUltraWide
        )
        let before = device.videoZoomFactor
        let beforeLogical = logicalBroadcastZoomFactor(
            forPhysicalZoom: before,
            device: device,
            multiplier: multiplier,
            isVirtualRear: isVirtualRear,
            isPhysicalUltraWide: isPhysicalUltraWide
        )
        let phaseDuration = RinkLensBroadcastZoomMotion.duration(
            fullRangeDuration: duration,
            from: beforeLogical,
            to: requested
        )
        // R19: digital/virtual zoom does not mutate focus, exposure or white
        // balance ownership. Do not queue delayed camera-control restores after
        // ordinary zoom ramps; those historical delayed jobs could fire during a
        // later preset and fight the current desired camera state. Physical
        // device changes remain separate CaptureEngine branch transactions.
        do {
            try device.lockForConfiguration()
            device.cancelVideoZoomRamp()
            if isVirtualRear {
                if #available(iOS 15.0, *) {
                    device.setPrimaryConstituentDeviceSwitchingBehavior(
                        .auto,
                        restrictedSwitchingBehaviorConditions: []
                    )
                }
            }
            if !animated || phaseDuration <= 0.0 || abs(before - physical) <= 0.01 {
                device.videoZoomFactor = physical
            }
            device.unlockForConfiguration()

            if animated, phaseDuration > 0.0, abs(before - physical) > 0.01 {
                startBroadcastZoomTrajectoryOnSessionQueue(
                    device: device,
                    fromLogicalZoom: beforeLogical,
                    toLogicalZoom: requested,
                    duration: phaseDuration,
                    intentRevision: intentRevision,
                    source: source
                )
            } else {
                cancelBroadcastZoomTrajectoryOnSessionQueue(reason: "exact/non-animated zoom application")
            }

            let appliedCadence = RinkLensCaptureCadence(duration: device.activeVideoMinFrameDuration)
            activeLiveResolvedFormat = activeLiveResolvedFormat.map {
                RinkLensCaptureFormatPreference(width: $0.width, height: $0.height, cadence: appliedCadence)
            }
            if let contract = activeEffectiveContract,
               let resolved = activeLiveResolvedFormat {
                activeEffectiveContract = RinkLensEffectiveCaptureContract(
                    desired: contract.desired,
                    liveActiveDeviceID: contract.liveActiveDeviceID,
                    ocrActiveDeviceID: contract.ocrActiveDeviceID,
                    liveFormat: resolved,
                    ocrFormat: contract.ocrFormat
                )
            }
            liveFormatTextLocked = "CaptureEngine Broadcast source \(activeLiveResolvedFormat?.diagnosticText ?? "unknown") virtual zoom fixed-cadence verified"

            updateBroadcastHardwareTargetLogicalZoom(
                requested,
                device: device,
                source: source,
                reason: "In-place hardware target accepted; verified applied state is acknowledged only after settlement"
            )

            let constituentName: String = {
                if #available(iOS 15.0, *) {
                    return device.activePrimaryConstituent?.localizedName ?? "none"
                }
                return "unavailable"
            }()
            traceZoomMovement(
                "CaptureEngine zoom applied source=\(source) logical=\(String(format: "%.2f", Double(requested))) physical=\(String(format: "%.2f", Double(physical))) device=\(device.localizedName) constituent=\(constituentName) cadence=\(appliedCadence.displayText) generation=\(transitionGeneration) graphRebuilt=false"
            )
            RinkLensStructuredEventLogger.shared.record(
                domain: .camera,
                event: "camera_virtual_rear_zoom_applied",
                entityID: device.uniqueID,
                previous: [
                    "physicalZoom": String(Double(before)),
                    "cadence": previousCadence.displayText
                ],
                next: [
                    "logicalZoom": String(Double(requested)),
                    "physicalZoom": String(Double(physical)),
                    "currentLogicalZoom": String(Double(beforeLogical)),
                    "fullRangeDurationSeconds": String(duration),
                    "phaseDurationSeconds": String(phaseDuration),
                    "cadence": appliedCadence.displayText,
                    "cadenceMutation": "false",
                    "activeConstituent": constituentName,
                    "ramping": "false",
                    "trajectoryOwner": "CaptureEngine elapsed-time sampler",
                    "trajectoryRevision": String(intentRevision)
                ],
                source: "ExternalOCRMultiCamCoordinator",
                reason: source,
                captureGeneration: transitionGeneration,
                authoritativeOwner: "CaptureEngine"
            )
            publishSnapshot { snapshot in
                snapshot.statusText = "Broadcast framing \(String(format: "%.1fx", Double(requested)))"
            }

            let strategy = isVirtualRear
                ? "virtual-rear-constituent"
                : (isPhysicalUltraWide ? "ultra-wide-native-crop" : "wide-digital-zoom")
            return .init(
                succeeded: true,
                requiresStableGraph: false,
                statusText: "In-place \(String(format: "%.1fx", Double(requested))) framing applied without rebuilding capture.",
                physicalDeviceID: device.uniqueID,
                physicalDeviceName: device.localizedName,
                captureGeneration: transitionGeneration,
                appliedCadence: appliedCadence,
                appliedPhysicalZoom: Double(physical),
                strategy: strategy
            )
        } catch {
            traceZoomMovement(
                "CaptureEngine zoom failed source=\(source) logical=\(String(format: "%.2f", Double(requested))) error=\(error.localizedDescription)"
            )
            return .init(
                succeeded: false,
                requiresStableGraph: false,
                statusText: "The active camera rejected the in-place framing change: \(error.localizedDescription)",
                physicalDeviceID: device.uniqueID,
                physicalDeviceName: device.localizedName,
                captureGeneration: transitionGeneration,
                appliedCadence: RinkLensCaptureCadence(duration: device.activeVideoMinFrameDuration),
                appliedPhysicalZoom: Double(device.videoZoomFactor),
                strategy: "device-configuration-failed"
            )
        }
    }

    private func updateBroadcastHardwareTargetLogicalZoom(
        _ logicalZoom: CGFloat,
        device: AVCaptureDevice,
        source: String,
        reason: String
    ) {
        assertSessionQueue()
        let next = min(max(logicalZoom.isFinite ? logicalZoom : 1.0, 0.5), 5.0)
        let previous = broadcastHardwareTargetLogicalZoomLocked
        guard abs(previous - next) >= 0.001 else { return }
        broadcastHardwareTargetLogicalZoomLocked = next
        RinkLensStructuredEventLogger.shared.record(
            domain: .camera,
            event: "camera_hardware_zoom_target_changed",
            entityID: device.uniqueID,
            previous: ["logicalZoom": String(Double(previous))],
            next: [
                "logicalZoom": String(Double(next)),
                "physicalZoom": String(Double(device.videoZoomFactor)),
                "device": device.localizedName
            ],
            source: source,
            reason: reason,
            captureGeneration: transitionGeneration,
            authoritativeOwner: "CaptureEngine"
        )
    }

    private func physicalBroadcastZoomFactor(
        for logicalZoom: CGFloat,
        device: AVCaptureDevice,
        multiplier: CGFloat? = nil,
        isVirtualRear: Bool? = nil,
        isPhysicalUltraWide: Bool? = nil
    ) -> CGFloat {
        let resolvedMultiplier = multiplier
            ?? max(CGFloat(device.displayVideoZoomFactorMultiplier), 0.01)
        let resolvedVirtual = isVirtualRear
            ?? (device.position == .back
                && (device.deviceType == .builtInDualWideCamera
                    || device.deviceType == .builtInTripleCamera
                    || device.deviceType == .builtInDualCamera))
        let resolvedUltraWide = isPhysicalUltraWide
            ?? (device.position == .back
                && (device.deviceType == .builtInUltraWideCamera
                    || device.localizedName.localizedCaseInsensitiveContains("ultra")))
        let translated: CGFloat
        if resolvedVirtual {
            translated = logicalZoom / resolvedMultiplier
        } else if resolvedUltraWide {
            translated = logicalZoom * 2.0
        } else {
            translated = logicalZoom
        }
        let upper = min(device.maxAvailableVideoZoomFactor, 10.0)
        return min(max(translated, device.minAvailableVideoZoomFactor), upper)
    }

    private func logicalBroadcastZoomFactor(
        forPhysicalZoom physicalZoom: CGFloat,
        device: AVCaptureDevice,
        multiplier: CGFloat? = nil,
        isVirtualRear: Bool? = nil,
        isPhysicalUltraWide: Bool? = nil
    ) -> CGFloat {
        let resolvedMultiplier = multiplier
            ?? max(CGFloat(device.displayVideoZoomFactorMultiplier), 0.01)
        let resolvedVirtual = isVirtualRear
            ?? (device.position == .back
                && (device.deviceType == .builtInDualWideCamera
                    || device.deviceType == .builtInTripleCamera
                    || device.deviceType == .builtInDualCamera))
        let resolvedUltraWide = isPhysicalUltraWide
            ?? (device.position == .back
                && (device.deviceType == .builtInUltraWideCamera
                    || device.localizedName.localizedCaseInsensitiveContains("ultra")))
        let translated: CGFloat
        if resolvedVirtual {
            translated = physicalZoom * resolvedMultiplier
        } else if resolvedUltraWide {
            translated = physicalZoom / 2.0
        } else {
            translated = physicalZoom
        }
        return min(
            max(translated, RinkLensBroadcastZoomMotion.logicalRange.lowerBound),
            RinkLensBroadcastZoomMotion.logicalRange.upperBound
        )
    }

    private func applyRequestedBroadcastFramingBeforeGraphStart(
        to device: AVCaptureDevice,
        logicalZoom: CGFloat,
        reason: String
    ) throws {
        assertSessionQueue()
        let requested = min(max(logicalZoom, 0.5), 5.0)
        let physical = physicalBroadcastZoomFactor(for: requested, device: device)
        try device.lockForConfiguration()
        device.cancelVideoZoomRamp()
        device.videoZoomFactor = physical
        device.unlockForConfiguration()
        trace(
            "Build 773 initial rear framing logical=\(String(format: "%.2f", Double(requested))) "
            + "physical=\(String(format: "%.2f", Double(physical))) device=\(device.localizedName) reason=\(reason)"
        )
    }

    /// iOS 18 automatic frame-rate support belongs to AVCaptureDevice.Format,
    /// not AVCaptureDevice. Xcode 26 Swift overlays have varied across SDK seeds,
    /// so keep this one compatibility read at the Objective-C runtime boundary.
    private func formatSupportsAutomaticFrameRate(_ format: AVCaptureDevice.Format) -> Bool {
        let selector = NSSelectorFromString("isAutoVideoFrameRateSupported")
        guard format.responds(to: selector) else { return false }
        return (format.value(forKey: "autoVideoFrameRateSupported") as? Bool) == true
    }

    private func deviceSupportsAutomaticFrameRate(_ device: AVCaptureDevice) -> Bool {
        formatSupportsAutomaticFrameRate(device.activeFormat)
    }

    private func deviceAutomaticFrameRateEnabled(_ device: AVCaptureDevice) -> Bool {
        let selector = NSSelectorFromString("isAutoVideoFrameRateEnabled")
        guard device.responds(to: selector) else { return false }
        return (device.value(forKey: "autoVideoFrameRateEnabled") as? Bool) == true
    }

    private func setDeviceAutomaticFrameRate(_ enabled: Bool, on device: AVCaptureDevice) {
        let selector = NSSelectorFromString("setAutoVideoFrameRateEnabled:")
        guard device.responds(to: selector) else { return }
        device.setValue(enabled, forKey: "autoVideoFrameRateEnabled")
    }

    @discardableResult
    private func applyBroadcastFormatOnSessionQueue(
        targetPreference: RinkLensCaptureFormatPreference,
        policy: BroadcastImageQualityPolicy? = nil,
        reason: String,
        allowOpenWriterContract: Bool = false
    ) -> Bool {
        assertSessionQueue()
        guard let device = liveInput?.device,
              activeGraphModeLocked.requiresBroadcast,
              session.isRunning else { return false }

        let clampedFPS = targetPreference.nominalFPS <= 30 ? 30 : 60
        let target = targetPreference.cadence
        let currentDimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let resolvedWidth = targetPreference.width
        let resolvedHeight = targetPreference.height
        let requestedPolicy = policy ?? appliedBroadcastImageQualityPolicyLocked

        func supportsTarget(_ format: AVCaptureDevice.Format) -> Bool {
            format.videoSupportedFrameRateRanges.contains { range in
                Double(clampedFPS) + 0.005 >= range.minFrameRate
                    && Double(clampedFPS) - 0.005 <= range.maxFrameRate
            }
        }

        let compatibleFormats = device.formats
            .filter { format in
                guard format.isMultiCamSupported, supportsTarget(format) else { return false }
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return dimensions.width == resolvedWidth && dimensions.height == resolvedHeight
            }
            .sorted { lhs, rhs in
                if requestedPolicy.allowsAutomaticFrameRate {
                    let lhsAuto = formatSupportsAutomaticFrameRate(lhs)
                    let rhsAuto = formatSupportsAutomaticFrameRate(rhs)
                    if lhsAuto != rhsAuto { return lhsAuto && !rhsAuto }
                }
                if lhs.isVideoBinned != rhs.isVideoBinned { return !lhs.isVideoBinned && rhs.isVideoBinned }
                if requestedPolicy == .imageQualityPriority {
                    let lhsExposure = CMTimeGetSeconds(lhs.maxExposureDuration)
                    let rhsExposure = CMTimeGetSeconds(rhs.maxExposureDuration)
                    if abs(lhsExposure - rhsExposure) > 0.000_001 { return lhsExposure > rhsExposure }
                }
                let lhsMax = lhs.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
                let rhsMax = rhs.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
                return abs(lhsMax - Double(clampedFPS)) < abs(rhsMax - Double(clampedFPS))
            }

        guard let preferredFormat = compatibleFormats.first else {
            trace(
                "R14 camera-quality cadence unavailable device=\(device.localizedName) "
                + "requested=\(clampedFPS) resolution=\(resolvedWidth)x\(resolvedHeight) reason=\(reason)"
            )
            return false
        }
        let currentFormatSupportsTarget = currentDimensions.width == resolvedWidth
            && currentDimensions.height == resolvedHeight
            && supportsTarget(device.activeFormat)
        let currentFormatAlreadyPreferred = currentFormatSupportsTarget && preferredFormat === device.activeFormat
        let replacementFormat: AVCaptureDevice.Format? = currentFormatAlreadyPreferred ? nil : preferredFormat

        guard currentFormatSupportsTarget || replacementFormat != nil else {
            trace(
                "R14 fixed camera-quality cadence unavailable device=\(device.localizedName) "
                + "requested=\(clampedFPS) resolution=\(resolvedWidth)x\(resolvedHeight) reason=\(reason)"
            )
            return false
        }

        let previous = RinkLensCaptureCadence(duration: device.activeVideoMinFrameDuration)
        let requiresFormatChange = replacementFormat != nil
        let desiredAutomaticFrameRate = requestedPolicy.allowsAutomaticFrameRate
        let desiredLowLightBoost = requestedPolicy.requestsAutomaticLowLightBoost
        let currentAutomaticFrameRate = deviceAutomaticFrameRateEnabled(device)
        let currentLowLightBoost = device.isLowLightBoostSupported
            && device.automaticallyEnablesLowLightBoostWhenAvailable
        let currentAutoRateCapability = deviceSupportsAutomaticFrameRate(device)
        let effectiveAutomaticFrameRate = desiredAutomaticFrameRate && currentAutoRateCapability
        let fixedCadenceMatches = abs(previous.framesPerSecond - Double(clampedFPS)) <= 0.25
        let imagingPolicyAlreadyApplied = effectiveAutomaticFrameRate
            ? (currentAutomaticFrameRate
                && (!device.isLowLightBoostSupported || currentLowLightBoost == desiredLowLightBoost))
            : (!currentAutomaticFrameRate && fixedCadenceMatches
                && (!device.isLowLightBoostSupported || currentLowLightBoost == desiredLowLightBoost))

        guard requiresFormatChange || !imagingPolicyAlreadyApplied else {
            configuredLiveCadenceLocked = target
            appliedBroadcastImageQualityPolicyLocked = requestedPolicy
            lastDeferredBroadcastCadenceKeyLocked = nil
            return true
        }

        let writerContractProtected = RinkLensRecordingCaptureLease.shared.isWriterContractOpen()
        if writerContractProtected && !allowOpenWriterContract {
            let key = "\(previous.displayText)->\(clampedFPS)|\(reason)"
            if lastDeferredBroadcastCadenceKeyLocked != key {
                lastDeferredBroadcastCadenceKeyLocked = key
                RinkLensStructuredEventLogger.shared.record(
                    domain: .camera,
                    event: "camera_broadcast_cadence_deferred_by_writer_contract",
                    entityID: device.uniqueID,
                    previous: [
                        "fps": previous.displayText,
                        "writerContract": RinkLensRecordingCaptureLease.shared.writerContractDiagnostic()
                    ],
                    next: [
                        "fps": previous.displayText,
                        "requestedFPS": String(clampedFPS),
                        "deferred": "true"
                    ],
                    source: "ExternalOCRMultiCamCoordinator",
                    reason: reason,
                    captureGeneration: transitionGeneration,
                    authoritativeOwner: "HockeyCameraService"
                )
                trace("Build 738 Broadcast cadence held at \(previous.displayText)fps while writer contract is open; requested=\(clampedFPS) reason=\(reason)")
            }
            return false
        }
        lastDeferredBroadcastCadenceKeyLocked = nil

        let previousFormat = device.activeFormat
        let previousMin = device.activeVideoMinFrameDuration
        let previousMax = device.activeVideoMaxFrameDuration
        let previousAutoFrameRate = deviceAutomaticFrameRateEnabled(device)
        let previousAutomaticLowLight = device.isLowLightBoostSupported
            ? device.automaticallyEnablesLowLightBoostWhenAvailable
            : false
        do {
            try device.lockForConfiguration()
            if let replacementFormat {
                device.activeFormat = replacementFormat
            }
            guard supportsTarget(device.activeFormat) else {
                device.unlockForConfiguration()
                trace("R14 camera-quality target format rejected after selection requested=\(clampedFPS) reason=\(reason)")
                return false
            }

            let autoFrameRateSupported = deviceSupportsAutomaticFrameRate(device)
            let automaticFrameRateEnabled = desiredAutomaticFrameRate && autoFrameRateSupported
            if autoFrameRateSupported {
                // Apple requires frame-duration setters to stop before enabling
                // automatic frame-rate adaptation. Clear previous fixed limits first.
                setDeviceAutomaticFrameRate(false, on: device)
            }
            if automaticFrameRateEnabled {
                device.activeVideoMinFrameDuration = .invalid
                device.activeVideoMaxFrameDuration = .invalid
            } else {
                device.activeVideoMinFrameDuration = target.duration
                device.activeVideoMaxFrameDuration = target.duration
            }
            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = desiredLowLightBoost
            }
            if automaticFrameRateEnabled {
                setDeviceAutomaticFrameRate(true, on: device)
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
                if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = true }
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            device.unlockForConfiguration()
            liveInput?.videoMinFrameDurationOverride = automaticFrameRateEnabled ? .invalid : target.duration

            let appliedDimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            let resolved = RinkLensCaptureFormatPreference(
                width: appliedDimensions.width,
                height: appliedDimensions.height,
                cadence: target
            )
            configuredLiveCadenceLocked = target
            appliedBroadcastImageQualityPolicyLocked = requestedPolicy
            lastRequestedLiveFormat = resolved
            activeLiveFormatPreference = resolved
            activeLiveResolvedFormat = resolved
            let automaticFrameRateApplied = deviceAutomaticFrameRateEnabled(device)
            liveConfiguredCadenceTextLocked = automaticFrameRateApplied
                ? "adaptive low-light ceiling \(target.displayText)fps; AVFoundation may reduce to 24fps; formatChanged=\(requiresFormatChange); reason=\(reason)"
                : "fixed quality mode applied \(target.displayText)fps; previous \(previous.displayText)fps; formatChanged=\(requiresFormatChange); reason=\(reason)"
            liveFormatTextLocked = automaticFrameRateApplied
                ? "CaptureEngine Broadcast source \(resolved.diagnosticText) adaptive-low-light verified"
                : "CaptureEngine Broadcast source \(resolved.diagnosticText) fixed-quality verified"

            if let existing = activeEffectiveContract {
                activeEffectiveContract = RinkLensEffectiveCaptureContract(
                    desired: RinkLensDesiredCaptureContract(
                        mode: existing.desired.mode,
                        liveLogicalSourceID: existing.desired.liveLogicalSourceID,
                        ocrLogicalSourceID: existing.desired.ocrLogicalSourceID,
                        livePreferredDeviceID: existing.desired.livePreferredDeviceID,
                        ocrPreferredDeviceID: existing.desired.ocrPreferredDeviceID,
                        liveFormat: resolved,
                        ocrFormat: existing.desired.ocrFormat
                    ),
                    liveActiveDeviceID: existing.liveActiveDeviceID,
                    ocrActiveDeviceID: existing.ocrActiveDeviceID,
                    liveFormat: resolved,
                    ocrFormat: existing.ocrFormat
                )
            }

            RinkLensStructuredEventLogger.shared.record(
                domain: .camera,
                event: "camera_broadcast_imaging_profile_applied",
                entityID: device.uniqueID,
                previous: [
                    "fps": previous.displayText,
                    "formatChanged": "false"
                ],
                next: [
                    "fps": target.displayText,
                    "formatChanged": String(requiresFormatChange),
                    "resolution": "\(resolved.width)x\(resolved.height)",
                    "logicalZoom": String(Double(broadcastHardwareTargetLogicalZoomLocked)),
                    "automaticFrameRateSupported": String(deviceSupportsAutomaticFrameRate(device)),
                    "automaticFrameRate": String(deviceAutomaticFrameRateEnabled(device)),
                    "automaticLowLightBoost": String(device.isLowLightBoostSupported && device.automaticallyEnablesLowLightBoostWhenAvailable)
                ],
                source: "ExternalOCRMultiCamCoordinator",
                reason: reason,
                captureGeneration: transitionGeneration,
                authoritativeOwner: "CaptureEngine"
            )
            RinkLensStructuredEventLogger.shared.record(
                domain: .camera,
                event: "camera_broadcast_imaging_capability_snapshot",
                entityID: device.uniqueID,
                previous: [:],
                next: ["matrix": broadcastImagingCapabilitySummary(device: device, connection: liveOutputConnection)],
                source: "ExternalOCRMultiCamCoordinator",
                reason: "Recovery CZ physical format capability snapshot after imaging-profile application",
                captureGeneration: transitionGeneration,
                authoritativeOwner: "CaptureEngine"
            )
            trace(
                "Recovery CZ Broadcast imaging profile=\(requestedPolicy.rawValue) nominal=\(target.displayText)fps "
                + "autoFrameRate=\(deviceAutomaticFrameRateEnabled(device)) lowLightBoost=\(device.isLowLightBoostSupported && device.automaticallyEnablesLowLightBoostWhenAvailable) "
                + "formatChanged=\(requiresFormatChange) device=\(device.localizedName) reason=\(reason)"
            )
            return true
        } catch {
            do {
                try device.lockForConfiguration()
                device.activeFormat = previousFormat
                if deviceSupportsAutomaticFrameRate(device) {
                    setDeviceAutomaticFrameRate(false, on: device)
                }
                if previousAutoFrameRate && deviceSupportsAutomaticFrameRate(device) {
                    device.activeVideoMinFrameDuration = .invalid
                    device.activeVideoMaxFrameDuration = .invalid
                } else {
                    device.activeVideoMinFrameDuration = previousMin
                    device.activeVideoMaxFrameDuration = previousMax
                }
                if device.isLowLightBoostSupported {
                    device.automaticallyEnablesLowLightBoostWhenAvailable = previousAutomaticLowLight
                }
                if previousAutoFrameRate && deviceSupportsAutomaticFrameRate(device) {
                    setDeviceAutomaticFrameRate(true, on: device)
                }
                device.unlockForConfiguration()
                liveInput?.videoMinFrameDurationOverride = previousAutoFrameRate ? .invalid : previousMin
            } catch {
                trace("R14 fixed camera-quality cadence rollback failed device=\(device.localizedName) error=\(error.localizedDescription)")
            }
            trace("R14 fixed camera-quality cadence apply failed target=\(clampedFPS) device=\(device.localizedName) error=\(error.localizedDescription)")
            return false
        }
    }

    private func scheduleBroadcastQualityTelemetryIfNeeded(_ uptime: UInt64) {
        stateLock.lock()
        let interval: UInt64 = 500_000_000
        guard uptime &- lastBroadcastQualityTelemetryUptimeLocked >= interval else {
            stateLock.unlock()
            return
        }
        lastBroadcastQualityTelemetryUptimeLocked = uptime
        stateLock.unlock()
        sessionQueue.async { [weak self] in
            self?.publishBroadcastQualityTelemetryOnSessionQueue()
        }
    }

    private func broadcastImagingCapabilitySummary(device: AVCaptureDevice, connection: AVCaptureConnection?) -> String {
        let format = device.activeFormat
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let ranges = format.videoSupportedFrameRateRanges
            .map { String(format: "%.0f-%.0f", $0.minFrameRate, $0.maxFrameRate) }
            .joined(separator: ",")
        let colours = format.supportedColorSpaces.map { String(describing: $0) }.joined(separator: ",")
        let stabilisation: [String] = [
            format.isVideoStabilizationModeSupported(.lowLatency) ? "lowLatency" : nil,
            format.isVideoStabilizationModeSupported(.standard) ? "standard" : nil,
            format.isVideoStabilizationModeSupported(.cinematic) ? "cinematic" : nil
        ].compactMap { $0 }
        let minExposure = CMTimeGetSeconds(format.minExposureDuration)
        let maxExposure = CMTimeGetSeconds(format.maxExposureDuration)
        let upscale = Double(format.videoZoomFactorUpscaleThreshold)
        let autoRateSupported = deviceSupportsAutomaticFrameRate(device)
        let autoRateEnabled = deviceAutomaticFrameRateEnabled(device)
        return "\(dimensions.width)x\(dimensions.height) multiCam=\(format.isMultiCamSupported) binned=\(format.isVideoBinned) fps={\(ranges)} autoFPS=\(autoRateSupported)/\(autoRateEnabled) lowLight=\(device.isLowLightBoostSupported)/\(device.isLowLightBoostSupported && device.automaticallyEnablesLowLightBoostWhenAvailable) HDR=\(format.isVideoHDRSupported) colours={\(colours.isEmpty ? "default" : colours)} stabilisation={\(stabilisation.isEmpty ? "none" : stabilisation.joined(separator: ","))} activeStab=\(connection?.activeVideoStabilizationMode.rawValue ?? -1) zoomUpscale=\(String(format: "%.2fx", upscale)) ISO=\(Int(format.minISO))-\(Int(format.maxISO)) exposure=\(String(format: "%.6f", minExposure))-\(String(format: "%.4f", maxExposure))s"
    }

    /// Camera quality telemetry is observational. Policy changes only occur in
    /// the explicit camera-imaging transaction above.
    /// Periodic physical exposure/ISO/cadence truth only. It has no authority
    /// to change imaging behaviour; CameraControlStore requests policy and the
    /// CaptureEngine transaction above applies it.
    private func publishBroadcastQualityTelemetryOnSessionQueue() {
        assertSessionQueue()
        guard let device = liveInput?.device,
              activeGraphModeLocked.requiresBroadcast,
              session.isRunning else { return }

        let iso = device.iso
        let exposure = CMTimeGetSeconds(device.exposureDuration)
        let observedFPS: Double = {
            stateLock.lock()
            defer { stateLock.unlock() }
            return liveObservedFPSLocked
        }()
        let connection = liveOutputConnection
        let stabilisationSupported = connection?.isVideoStabilizationSupported == true
        let appliedStabilisation = connection?.activeVideoStabilizationMode.rawValue ?? -1
        stateLock.lock()
        let requestedStabilisation = broadcastVideoStabilisationEnabledLocked
        stateLock.unlock()

        liveService?.publishBroadcastAppliedTruth(
            deviceName: device.localizedName,
            deviceTypeRawValue: device.deviceType.rawValue,
            iso: iso,
            exposureDurationSeconds: exposure,
            sourceFPS: observedFPS,
            logicalZoom: broadcastHardwareTargetLogicalZoomLocked,
            lowLightBoostSupported: device.isLowLightBoostSupported,
            lowLightBoostRequested: device.isLowLightBoostSupported
                && device.automaticallyEnablesLowLightBoostWhenAvailable,
            automaticFrameRateSupported: deviceSupportsAutomaticFrameRate(device),
            automaticFrameRateEnabled: deviceAutomaticFrameRateEnabled(device),
            imagingCapabilitiesText: broadcastImagingCapabilitySummary(device: device, connection: connection),
            stabilisationRequested: requestedStabilisation,
            stabilisationSupported: stabilisationSupported,
            stabilisationAppliedRawValue: appliedStabilisation
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var sessionIdentifier: String {
        String(ObjectIdentifier(session).hashValue, radix: 16)
    }

    private func assertSessionQueue(_ function: StaticString = #function) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
    }

    private func captureSnapshot() -> RinkLensCaptureEngineSnapshot {
        stateLock.lock()
        let value = uiSnapshotLocked
        stateLock.unlock()
        return value
    }

    /// Emits one coherent capture snapshot. AVFoundation remains confined to the
    /// engine queues; only the immutable value crosses to the MainActor UI store.
    private func publishSnapshot(
        phase: RinkLensCaptureEnginePhase? = nil,
        advancesRevision: Bool = true,
        _ mutate: ((inout RinkLensCaptureEngineSnapshot) -> Void)? = nil
    ) {
        // Only the session queue reads AVFoundation graph/runtime properties.
        // Output and MainActor callers reuse the last mirrored values.
        let onSessionQueue = DispatchQueue.getSpecific(key: sessionQueueKey) == sessionQueueIdentity
        let configuredValue = onSessionQueue ? configured : false
        let runningValue = onSessionQueue ? session.isRunning : false
        let hardwareCostValue = onSessionQueue ? Double(session.hardwareCost) : 0
        let pressureCostValue = onSessionQueue ? Double(session.systemPressureCost) : 0
        let generationValue = onSessionQueue ? transitionGeneration : 0

        stateLock.lock()
        if onSessionQueue {
            sessionConfiguredSnapshotLocked = configuredValue
            sessionRunningSnapshotLocked = runningValue
            hardwareCostSnapshotLocked = hardwareCostValue
            pressureCostSnapshotLocked = pressureCostValue
            transitionGenerationSnapshotLocked = generationValue
            if dropCounterGenerationLocked != generationValue {
                liveDroppedFramesLocked = 0
                liveDroppedLateFramesLocked = 0
                liveDroppedOutOfBuffersLocked = 0
                liveDroppedDiscontinuityFramesLocked = 0
                ocrDroppedFramesLocked = 0
                ocrDroppedLateFramesLocked = 0
                ocrDroppedOutOfBuffersLocked = 0
                ocrDroppedDiscontinuityFramesLocked = 0
                dropCounterGenerationLocked = generationValue
                lastDropTelemetryPublishAtLocked = 0
                dropTelemetryFlushScheduledLocked = false
                lastPublishedLiveDropTotalLocked = 0
                lastPublishedLiveLateTotalLocked = 0
                lastPublishedLiveOutOfBuffersTotalLocked = 0
                lastPublishedLiveDiscontinuityTotalLocked = 0
                lastPublishedOCRDropTotalLocked = 0
                lastPublishedOCRLateTotalLocked = 0
                lastPublishedOCROutOfBuffersTotalLocked = 0
                lastPublishedOCRDiscontinuityTotalLocked = 0
                liveFirstFrameLumaTextLocked = "awaiting Broadcast frame for generation \(generationValue)"
                ocrFirstFrameLumaTextLocked = "awaiting OCR frame for generation \(generationValue)"
                liveCallbackLastMillisecondsLocked = 0
                liveCallbackMaxMillisecondsLocked = 0
                liveCallbackOverBudgetCountLocked = 0
                ocrCallbackLastMillisecondsLocked = 0
                ocrCallbackMaxMillisecondsLocked = 0
                ocrCallbackOverBudgetCountLocked = 0
                lastDroppedFrameTextLocked = "No drops in capture generation \(generationValue)"
            }
        }
        uiSnapshotLocked.isActive = activeLocked
        uiSnapshotLocked.captureModeText = activeGraphModeLocked.rawValue
        uiSnapshotLocked.isTransitioning = transitioningLocked
        uiSnapshotLocked.previewAttached = previewAttachedLocked
        uiSnapshotLocked.broadcastPreviewAttached = broadcastPreviewAttachedLocked
        uiSnapshotLocked.ocrPreviewAttached = ocrPreviewAttachedLocked
        uiSnapshotLocked.liveFramesReceived = liveFramesLocked
        uiSnapshotLocked.ocrFramesReceived = ocrFramesLocked
        uiSnapshotLocked.liveDeviceID = activeLiveDeviceID
        uiSnapshotLocked.ocrDeviceID = activeOCRDeviceID
        uiSnapshotLocked.liveDeviceName = activeLiveDeviceNameLocked
        uiSnapshotLocked.liveDevicePositionText = activeLiveDevicePositionTextLocked
        uiSnapshotLocked.liveDeviceTypeText = activeLiveDeviceTypeTextLocked
        uiSnapshotLocked.ocrDeviceName = activeOCRDeviceNameLocked
        uiSnapshotLocked.ocrDevicePositionText = activeOCRDevicePositionTextLocked
        uiSnapshotLocked.ocrDeviceTypeText = activeOCRDeviceTypeTextLocked
        uiSnapshotLocked.liveFormat = activeLiveResolvedFormat
        uiSnapshotLocked.ocrFormat = activeOCRResolvedFormat
        uiSnapshotLocked.effectiveContract = activeEffectiveContract
        uiSnapshotLocked.appliedBroadcastQuality = appliedBroadcastQualityLocked
        uiSnapshotLocked.liveFormatText = liveFormatTextLocked
        uiSnapshotLocked.ocrFormatText = ocrFormatTextLocked
        uiSnapshotLocked.liveConfiguredCadenceText = liveConfiguredCadenceTextLocked
        uiSnapshotLocked.ocrConfiguredCadenceText = ocrConfiguredCadenceTextLocked
        uiSnapshotLocked.liveObservedFPS = liveObservedFPSLocked
        uiSnapshotLocked.ocrObservedFPS = ocrObservedFPSLocked
        uiSnapshotLocked.failureLatched = failureLatchedLocked
        uiSnapshotLocked.failureText = lastStartFailureText
        uiSnapshotLocked.sessionConfigured = sessionConfiguredSnapshotLocked
        uiSnapshotLocked.sessionRunning = sessionRunningSnapshotLocked
        uiSnapshotLocked.hardwareCost = hardwareCostSnapshotLocked
        uiSnapshotLocked.systemPressureCost = pressureCostSnapshotLocked
        uiSnapshotLocked.degradedRecord = degradedRecordLocked
        uiSnapshotLocked.liveSystemPressureLevel = liveSystemPressureLevelLocked
        uiSnapshotLocked.liveSystemPressureFactors = liveSystemPressureFactorsLocked
        uiSnapshotLocked.ocrSystemPressureLevel = ocrSystemPressureLevelLocked
        uiSnapshotLocked.ocrSystemPressureFactors = ocrSystemPressureFactorsLocked
        uiSnapshotLocked.ocrPressurePolicyState = ocrPressurePolicyStateLocked
        uiSnapshotLocked.ocrPressureDeliveryFPS = ocrPressureDeliveryFPSLocked
        uiSnapshotLocked.ocrPressureSuspended = ocrPressureSuspendedLocked
        uiSnapshotLocked.broadcastPreservationActive = broadcastPreservationActiveLocked
        uiSnapshotLocked.liveDroppedFrames = liveDroppedFramesLocked
        uiSnapshotLocked.liveDroppedLateFrames = liveDroppedLateFramesLocked
        uiSnapshotLocked.liveDroppedOutOfBuffers = liveDroppedOutOfBuffersLocked
        uiSnapshotLocked.liveDroppedDiscontinuityFrames = liveDroppedDiscontinuityFramesLocked
        uiSnapshotLocked.ocrDroppedFrames = ocrDroppedFramesLocked
        uiSnapshotLocked.ocrDroppedLateFrames = ocrDroppedLateFramesLocked
        uiSnapshotLocked.ocrDroppedOutOfBuffers = ocrDroppedOutOfBuffersLocked
        uiSnapshotLocked.ocrDroppedDiscontinuityFrames = ocrDroppedDiscontinuityFramesLocked
        uiSnapshotLocked.liveDroppedFramesLifetime = liveDroppedFramesLifetimeLocked
        uiSnapshotLocked.liveDroppedLateFramesLifetime = liveDroppedLateFramesLifetimeLocked
        uiSnapshotLocked.liveDroppedOutOfBuffersLifetime = liveDroppedOutOfBuffersLifetimeLocked
        uiSnapshotLocked.liveDroppedDiscontinuityFramesLifetime = liveDroppedDiscontinuityFramesLifetimeLocked
        uiSnapshotLocked.ocrDroppedFramesLifetime = ocrDroppedFramesLifetimeLocked
        uiSnapshotLocked.ocrDroppedLateFramesLifetime = ocrDroppedLateFramesLifetimeLocked
        uiSnapshotLocked.ocrDroppedOutOfBuffersLifetime = ocrDroppedOutOfBuffersLifetimeLocked
        uiSnapshotLocked.ocrDroppedDiscontinuityFramesLifetime = ocrDroppedDiscontinuityFramesLifetimeLocked
        uiSnapshotLocked.lastDroppedFrameText = lastDroppedFrameTextLocked
        uiSnapshotLocked.liveFirstFrameLumaText = liveFirstFrameLumaTextLocked
        uiSnapshotLocked.ocrFirstFrameLumaText = ocrFirstFrameLumaTextLocked
        let callbackNow = DispatchTime.now().uptimeNanoseconds
        uiSnapshotLocked.liveLastCallbackAgeSeconds = liveLastCallbackUptimeNanosecondsLocked.map { callbackNow >= $0 ? Double(callbackNow - $0) / 1_000_000_000 : 0 }
        uiSnapshotLocked.ocrLastCallbackAgeSeconds = ocrLastCallbackUptimeNanosecondsLocked.map { callbackNow >= $0 ? Double(callbackNow - $0) / 1_000_000_000 : 0 }
        uiSnapshotLocked.liveCallbackLastMilliseconds = liveCallbackLastMillisecondsLocked
        uiSnapshotLocked.liveCallbackMaxMilliseconds = liveCallbackMaxMillisecondsLocked
        uiSnapshotLocked.liveCallbackOverBudgetCount = liveCallbackOverBudgetCountLocked
        uiSnapshotLocked.ocrCallbackLastMilliseconds = ocrCallbackLastMillisecondsLocked
        uiSnapshotLocked.ocrCallbackMaxMilliseconds = ocrCallbackMaxMillisecondsLocked
        uiSnapshotLocked.ocrCallbackOverBudgetCount = ocrCallbackOverBudgetCountLocked
        uiSnapshotLocked.liveOutputConnectionText = liveOutputConnectionTextLocked
        uiSnapshotLocked.ocrOutputConnectionText = ocrOutputConnectionTextLocked
        uiSnapshotLocked.ocrDeadBranchRecoveryCount = ocrDeadBranchRecoveryCountLocked
        uiSnapshotLocked.ocrDeadBranchRecoveryFailureCount = ocrDeadBranchRecoveryFailureCountLocked
        uiSnapshotLocked.lastDeadBranchRecoveryText = lastDeadBranchRecoveryTextLocked
        uiSnapshotLocked.externalOCRTopology = externalOCRTopologyLocked
        uiSnapshotLocked.ocrRecoveryRequirement = ocrRecoveryRequirementLocked
        uiSnapshotLocked.transitionGeneration = transitionGenerationSnapshotLocked
        if let phase { uiSnapshotLocked.phase = phase }
        mutate?(&uiSnapshotLocked)
        if advancesRevision { uiSnapshotLocked.revision &+= 1 }
        let emitted = uiSnapshotLocked
        stateLock.unlock()

        let stateStore = uiState
        Task { @MainActor in
            stateStore.apply(emitted)
        }
    }

    var isCaptureActiveSnapshot: Bool {
        stateLock.lock()
        let value = activeLocked
        stateLock.unlock()
        return value
    }

    var isTransitioningSnapshot: Bool {
        stateLock.lock()
        let value = transitioningLocked
        stateLock.unlock()
        return value
    }

    var previewAttachedSnapshot: Bool {
        stateLock.lock()
        let value = previewAttachedLocked
        stateLock.unlock()
        return value
    }

    func previewAttachedSnapshot(for role: RinkLensCapturePreviewRole) -> Bool {
        stateLock.lock()
        let value: Bool
        switch role {
        case .broadcast: value = broadcastPreviewAttachedLocked
        case .ocr: value = ocrPreviewAttachedLocked
        }
        stateLock.unlock()
        return value
    }

    var activeModeSnapshot: RinkLensCaptureLifecycleMode {
        stateLock.lock()
        let value = activeGraphModeLocked
        stateLock.unlock()
        return value
    }

    var hasLiveFrameSnapshot: Bool {
        stateLock.lock()
        let value = liveFramesLocked > 0
        stateLock.unlock()
        return value
    }

    var hasOCRFrameSnapshot: Bool {
        stateLock.lock()
        let value = ocrFramesLocked > 0
        stateLock.unlock()
        return value
    }

    var hasRequiredFramesSnapshot: Bool {
        stateLock.lock()
        let mode = activeGraphModeLocked
        let liveReady = liveFramesLocked > 0
        let ocrReady = ocrFramesLocked > 0
        stateLock.unlock()
        switch mode {
        case .dualCamera: return liveReady && ocrReady
        case .broadcastOnly: return liveReady
        case .ocrOnly: return ocrReady
        case .stopped: return false
        }
    }

    var hasLiveAndOCRFramesSnapshot: Bool {
        stateLock.lock()
        let value = liveFramesLocked > 0 && ocrFramesLocked > 0
        stateLock.unlock()
        return value
    }

    var liveDeviceIDSnapshot: String? {
        stateLock.lock()
        let value = activeLiveDeviceID
        stateLock.unlock()
        return value
    }

    var ocrDeviceIDSnapshot: String? {
        stateLock.lock()
        let value = activeOCRDeviceID
        stateLock.unlock()
        return value
    }

    var liveFormatTextSnapshot: String {
        stateLock.lock()
        let value = liveFormatTextLocked
        stateLock.unlock()
        return value
    }

    var ocrFormatTextSnapshot: String {
        stateLock.lock()
        let value = ocrFormatTextLocked
        stateLock.unlock()
        return value
    }

    var retryDelaySnapshot: CFTimeInterval {
        stateLock.lock()
        let failureAt = lastStartFailureAt
        stateLock.unlock()
        guard failureAt > 0 else { return 0 }
        return max(0, failedStartCooldown - (CFAbsoluteTimeGetCurrent() - failureAt))
    }

    var isFailureLatchedSnapshot: Bool {
        stateLock.lock()
        let value = failureLatchedLocked
        stateLock.unlock()
        return value
    }

    var failureTextSnapshot: String {
        stateLock.lock()
        let value = lastStartFailureText
        stateLock.unlock()
        return value
    }

    var degradedRecordSnapshot: RinkLensCaptureDegradedRecord? {
        stateLock.lock()
        let value = degradedRecordLocked
        stateLock.unlock()
        return value
    }

    func degradedRecord(matching contract: RinkLensCaptureContractKey) -> RinkLensCaptureDegradedRecord? {
        stateLock.lock()
        let value = degradedRecordLocked?.failedContract == contract ? degradedRecordLocked : nil
        stateLock.unlock()
        return value
    }

    func recordDegradedContract(
        _ contract: RinkLensCaptureContractKey,
        fallbackMode: RinkLensCaptureLifecycleMode,
        failureText: String
    ) {
        let nowUptime = DispatchTime.now().uptimeNanoseconds
        let cooldownNanoseconds = UInt64(failedContractCooldown * 1_000_000_000)
        stateLock.lock()
        degradedFailureCountLocked &+= 1
        let record = RinkLensCaptureDegradedRecord(
            failedContract: contract,
            fallbackMode: fallbackMode,
            failureText: failureText == "none" ? "CaptureEngine activation failed" : failureText,
            recordedAt: Date(),
            cooldownUntilUptimeNanoseconds: nowUptime &+ cooldownNanoseconds,
            failureCount: degradedFailureCountLocked
        )
        degradedRecordLocked = record
        stateLock.unlock()
        trace("persistent degraded contract recorded {\(record.diagnosticText)}")
        publishSnapshot(phase: .degraded) { snapshot in
            snapshot.statusText = "Capture degraded — failed contract cooling down"
        }
    }

    func clearDegradedRecord(reason: String) {
        stateLock.lock()
        let previous = degradedRecordLocked
        degradedRecordLocked = nil
        stateLock.unlock()
        guard let previous else { return }
        trace("persistent degraded contract cleared reason=\(reason) prior={\(previous.diagnosticText)}")
        publishSnapshot { _ in }
    }

    func markDegradedFallbackActive(status: String) {
        publishSnapshot(phase: .degraded) { snapshot in
            snapshot.statusText = status
        }
    }

    /// UX16c25: A failed MultiCam graph must not continuously reclaim the cameras.
    /// Only a real camera-selection/reconnect event clears the circuit breaker.
    func resetFailureLatch(reason: String) {
        stateLock.lock()
        failureLatchedLocked = false
        lastStartFailureAt = 0
        lastStartFailureText = "none"
        stateLock.unlock()
        trace("failure latch reset reason=\(reason)")
        publishSnapshot { snapshot in
            if !snapshot.isActive && !snapshot.isTransitioning {
                snapshot.statusText = "MultiCam ready"
                snapshot.phase = .stopped
            }
        }
    }

    private func configureOutputs() {
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        ]
        liveOutput.videoSettings = settings
        ocrOutput.videoSettings = settings
        // Both branches feed latest-frame caches rather than appending every callback
        // directly to AVAssetWriter. Keep queue depth at one so a slow consumer cannot
        // build latency or starve the preview/other output branch.
        liveOutput.alwaysDiscardsLateVideoFrames = true
        ocrOutput.alwaysDiscardsLateVideoFrames = true
        liveOutput.setSampleBufferDelegate(self, queue: liveOutputQueue)
        ocrOutput.setSampleBufferDelegate(self, queue: ocrOutputQueue)
        stateLock.lock()
        outputDelegatesInstalledLocked = true
        stateLock.unlock()
    }

    func noteAppScenePhase(_ phase: String, reason: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        stateLock.lock()
        let previous = appScenePhaseLocked
        appScenePhaseLocked = phase
        appScenePhaseChangedUptimeNanosecondsLocked = now
        stateLock.unlock()

        sessionQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.captureSnapshot()
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: Self.videoDeviceTypes,
                mediaType: .video,
                position: .unspecified
            )
            let discoveredIDs = Set(discovery.devices.map(\.uniqueID))
            let liveID = self.liveInput?.device.uniqueID
            let ocrID = self.ocrInput?.device.uniqueID
            let hub = RinkLensFrameHub.shared.diagnosticSnapshot()
            RinkLensStructuredEventLogger.shared.record(
                domain: .capture,
                event: "capture_scene_phase_checkpoint",
                entityID: phase,
                previous: [
                    "scenePhase": previous
                ],
                next: [
                    "scenePhase": phase,
                    "sessionRunning": String(self.session.isRunning),
                    "sessionInterrupted": String(self.session.isInterrupted),
                    "configured": String(self.configured),
                    "mode": self.activeGraphModeLocked.rawValue,
                    "generation": String(self.transitionGeneration),
                    "liveDevice": liveID ?? "none",
                    "liveDeviceDiscoverable": String(liveID.map(discoveredIDs.contains) ?? false),
                    "ocrDevice": ocrID ?? "none",
                    "ocrDeviceDiscoverable": String(ocrID.map(discoveredIDs.contains) ?? false),
                    "liveCallbackAgeSeconds": snapshot.liveLastCallbackAgeSeconds.map { String(format: "%.3f", $0) } ?? "none",
                    "ocrCallbackAgeSeconds": snapshot.ocrLastCallbackAgeSeconds.map { String(format: "%.3f", $0) } ?? "none",
                    "broadcastFrameAgeSeconds": hub.broadcast.ageSeconds.map { String(format: "%.3f", $0) } ?? "none",
                    "ocrFrameAgeSeconds": hub.ocr.ageSeconds.map { String(format: "%.3f", $0) } ?? "none",
                    "broadcastActiveLease": hub.broadcast.activeOwnedLeaseSummary,
                    "broadcastMaxLease": hub.broadcast.ownedLeaseMaxLifetimeSummary,
                    "graph": self.graphDescription()
                ],
                source: "ExternalOCRMultiCamCoordinator.noteAppScenePhase",
                reason: reason,
                captureGeneration: self.transitionGeneration,
                authoritativeOwner: "CaptureEngine"
            )
        }
    }

    private func appScenePhaseContext(nowUptimeNanoseconds: UInt64) -> (phase: String, ageMilliseconds: Double) {
        stateLock.lock()
        let phase = appScenePhaseLocked
        let changed = appScenePhaseChangedUptimeNanosecondsLocked
        stateLock.unlock()
        let age = nowUptimeNanoseconds >= changed
            ? Double(nowUptimeNanoseconds - changed) / 1_000_000.0
            : 0
        return (phase, age)
    }

    private func registerSessionObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionWasInterrupted(_:)),
            name: AVCaptureSession.wasInterruptedNotification,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionInterruptionEnded(_:)),
            name: AVCaptureSession.interruptionEndedNotification,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionRuntimeError(_:)),
            name: AVCaptureSession.runtimeErrorNotification,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(videoDeviceWasDisconnected(_:)),
            name: AVCaptureDevice.wasDisconnectedNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(videoDeviceWasConnected(_:)),
            name: AVCaptureDevice.wasConnectedNotification,
            object: nil
        )
    }

    @objc private func sessionWasInterrupted(_ notification: Notification) {
        let reasonText = Self.interruptionReasonText(notification.userInfo?[AVCaptureSessionInterruptionReasonKey])
        trace("session interrupted reason=\(reasonText)")
        publishSnapshot(phase: .interrupted) { snapshot in
            snapshot.lastInterruptionText = "MultiCam interrupted: \(reasonText)"
            snapshot.statusText = "MultiCam interrupted"
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.transitionGeneration += 1
            self.cancelFirstFrameReadinessOnSessionQueue(reason: "session interrupted: \(reasonText)")
            self.setTransitioningLocked(false)
        }
    }

    @objc private func sessionInterruptionEnded(_ notification: Notification) {
        trace("session interruption ended")
        let endedPhase: RinkLensCaptureEnginePhase = session.isRunning ? .running : .recovering
        publishSnapshot(phase: endedPhase) { snapshot in
            snapshot.lastInterruptionText = "MultiCam interruption ended"
            snapshot.statusText = self.session.isRunning ? "MultiCam running" : "MultiCam ready to restart"
        }
        sessionQueue.async { [weak self] in
            guard let self, self.configured, !self.session.isRunning, !self.isFailureLatchedSnapshot else { return }
            self.publishSnapshot(phase: .recovering) { snapshot in
                snapshot.statusText = "Restarting MultiCam after interruption"
            }
            self.transitionGeneration += 1
            let generation = self.transitionGeneration
            self.resetFirstFrameCountersOnSessionQueue()
            self.session.startRunning()
            let running = self.session.isRunning
            let mode = self.activeGraphModeLocked
            guard running else {
                self.completeStart(
                    ready: false,
                    running: false,
                    mode: mode,
                    liveDevice: self.liveInput?.device,
                    ocrDevice: self.ocrInput?.device,
                    failurePrefix: "Capture interruption restart"
                )
                return
            }
            self.publishSnapshot(phase: .waitingForFrames) { snapshot in
                snapshot.statusText = self.waitingStatus(for: mode)
            }
            self.beginFirstFrameReadinessOnSessionQueue(mode: mode, transitionGeneration: generation) { [weak self] ready in
                guard let self, generation == self.transitionGeneration else { return }
                self.completeStart(
                    ready: ready,
                    running: self.session.isRunning,
                    mode: mode,
                    liveDevice: self.liveInput?.device,
                    ocrDevice: self.ocrInput?.device,
                    failurePrefix: "Capture interruption restart"
                )
            }
        }
    }

    @objc private func sessionRuntimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
        let userInfoText = error?.userInfo.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ") ?? "none"
        let detail = "domain=\(error?.domain ?? "none") code=\(error?.code ?? 0) description=\(error?.localizedDescription ?? "none") userInfo={\(userInfoText)}"
        trace("runtime error \(detail)")
        publishSnapshot(phase: .interrupted) { snapshot in
            snapshot.lastInterruptionText = "MultiCam runtime error: \(detail)"
        }

        sessionQueue.async { [weak self] in
            guard let self else { return }

            let now = DispatchTime.now().uptimeNanoseconds
            let scene = self.appScenePhaseContext(nowUptimeNanoseconds: now)
            let snapshot = self.captureSnapshot()
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: Self.videoDeviceTypes,
                mediaType: .video,
                position: .unspecified
            )
            let discoveredIDs = Set(discovery.devices.map(\.uniqueID))
            let liveID = self.liveInput?.device.uniqueID
            let ocrID = self.ocrInput?.device.uniqueID
            let hub = RinkLensFrameHub.shared.diagnosticSnapshot()
            RinkLensStructuredEventLogger.shared.record(
                domain: .capture,
                event: "capture_runtime_error_lifecycle_context",
                entityID: String(error?.code ?? 0),
                previous: [
                    "scenePhase": scene.phase,
                    "scenePhaseAgeMs": String(format: "%.1f", scene.ageMilliseconds),
                    "phase": snapshot.phase.rawValue,
                    "mode": snapshot.activeMode.rawValue
                ],
                next: [
                    "error": detail,
                    "sessionRunning": String(self.session.isRunning),
                    "sessionInterrupted": String(self.session.isInterrupted),
                    "configured": String(self.configured),
                    "generation": String(self.transitionGeneration),
                    "liveDevice": liveID ?? "none",
                    "liveDeviceDiscoverable": String(liveID.map(discoveredIDs.contains) ?? false),
                    "ocrDevice": ocrID ?? "none",
                    "ocrDeviceDiscoverable": String(ocrID.map(discoveredIDs.contains) ?? false),
                    "liveCallbackAgeSeconds": snapshot.liveLastCallbackAgeSeconds.map { String(format: "%.3f", $0) } ?? "none",
                    "ocrCallbackAgeSeconds": snapshot.ocrLastCallbackAgeSeconds.map { String(format: "%.3f", $0) } ?? "none",
                    "broadcastFrameAgeSeconds": hub.broadcast.ageSeconds.map { String(format: "%.3f", $0) } ?? "none",
                    "ocrFrameAgeSeconds": hub.ocr.ageSeconds.map { String(format: "%.3f", $0) } ?? "none",
                    "broadcastActiveLease": hub.broadcast.activeOwnedLeaseSummary,
                    "broadcastMaxLease": hub.broadcast.ownedLeaseMaxLifetimeSummary,
                    "graph": self.graphDescription()
                ],
                source: "ExternalOCRMultiCamCoordinator.sessionRuntimeError",
                reason: "Recovery R RL-053 runtime-error ordering evidence",
                captureGeneration: self.transitionGeneration,
                authoritativeOwner: "CaptureEngine"
            )

            // A media-services reset is recoverable and Apple camera samples attempt
            // one bounded restart of the existing graph. Capability/configuration
            // failures such as Cannot Record remain permanently latched for this pair.
            let isMediaServicesReset = error?.domain == AVFoundationErrorDomain
                && error?.code == AVError.Code.mediaServicesWereReset.rawValue
            if isMediaServicesReset,
               self.configured,
               !self.isFailureLatchedSnapshot {
                self.publishSnapshot(phase: .recovering) { snapshot in
                    snapshot.statusText = "Recovering MultiCam after media-services reset"
                }
                self.transitionGeneration += 1
                let generation = self.transitionGeneration
                self.resetFirstFrameCountersOnSessionQueue()
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                let running = self.session.isRunning
                let mode = self.activeGraphModeLocked
                guard running else {
                    self.completeStart(
                        ready: false,
                        running: false,
                        mode: mode,
                        liveDevice: self.liveInput?.device,
                        ocrDevice: self.ocrInput?.device,
                        failurePrefix: "Media-services reset recovery"
                    )
                    return
                }
                self.publishSnapshot(phase: .waitingForFrames) { snapshot in
                    snapshot.statusText = self.waitingStatus(for: mode)
                }
                self.beginFirstFrameReadinessOnSessionQueue(mode: mode, transitionGeneration: generation) { [weak self] ready in
                    guard let self, generation == self.transitionGeneration else { return }
                    self.completeStart(
                        ready: ready,
                        running: self.session.isRunning,
                        mode: mode,
                        liveDevice: self.liveInput?.device,
                        ocrDevice: self.ocrInput?.device,
                        failurePrefix: "Media-services reset recovery"
                    )
                    if ready {
                        self.trace("bounded media-services reset recovery succeeded mode=\(mode.rawValue)")
                    }
                }
                return
            }

            self.latchStartFailureOnSessionQueue(
                detail: detail,
                retainedLiveDevice: self.liveInput?.device,
                retainedOCRDevice: self.ocrInput?.device
            )
        }
    }

    /// Recovery G controller entry point for an OCR-only convergence.
    /// The caller has already proved that the running Broadcast device/format
    /// satisfies the desired contract. CaptureEngine therefore mutates only the
    /// OCR constituent on its existing serial session queue. A missing/failed OCR
    /// branch is reported while Broadcast remains untouched; this method never
    /// falls back to `start`, never calls `stopRunning`, and never advances the
    /// Broadcast capture generation.
    func convergeOCRBranchPreservingBroadcast(
        requestedOCRDeviceID: String,
        desiredContract: RinkLensDesiredCaptureContract,
        reason: String
    ) async -> RinkLensOCRBranchConvergenceResult {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .unavailablePreservingBroadcast("CaptureEngine released"))
                    return
                }
                guard self.configured,
                      self.session.isRunning,
                      self.liveInput != nil else {
                    continuation.resume(returning: .unavailablePreservingBroadcast("No stable Broadcast branch to preserve"))
                    return
                }

                if let existing = self.ocrInput,
                   existing.device.uniqueID == requestedOCRDeviceID {
                    self.stateLock.lock()
                    if let current = self.activeEffectiveContract {
                        self.activeEffectiveContract = RinkLensEffectiveCaptureContract(
                            desired: desiredContract,
                            liveActiveDeviceID: current.liveActiveDeviceID,
                            ocrActiveDeviceID: current.ocrActiveDeviceID,
                            liveFormat: current.liveFormat,
                            ocrFormat: current.ocrFormat
                        )
                    }
                    let hasFreshProof = self.firstFrameRequirementsSatisfiedLocked(mode: .dualCamera)
                    self.stateLock.unlock()
                    if hasFreshProof && self.requiredBranchesStructurallyAvailableOnSessionQueue(mode: .dualCamera) {
                        self.publishSnapshot(phase: .running, advancesRevision: false)
                        continuation.resume(returning: .alreadyAttached)
                    } else {
                        self.verifyAttachedOCRBranchOnSessionQueue(reason: "Recovery G existing OCR branch requires fresh-frame proof: \(reason)") { ready in
                            continuation.resume(returning: ready
                                ? .attached
                                : .unavailablePreservingBroadcast("OCR branch present but fresh current-generation frame was not verified"))
                        }
                    }
                    return
                }

                do {
                    let discovery = AVCaptureDevice.DiscoverySession(
                        deviceTypes: Self.videoDeviceTypes,
                        mediaType: .video,
                        position: .unspecified
                    )
                    let connectedName = discovery.devices.first(where: { $0.uniqueID == requestedOCRDeviceID })?.localizedName
                        ?? "External Camera"
                    try self.addOCRBranchPreservingBroadcastOnSessionQueue(
                        connectedDeviceID: requestedOCRDeviceID,
                        connectedDeviceName: connectedName
                    )
                    self.stateLock.lock()
                    if let current = self.activeEffectiveContract {
                        self.activeEffectiveContract = RinkLensEffectiveCaptureContract(
                            desired: desiredContract,
                            liveActiveDeviceID: current.liveActiveDeviceID,
                            ocrActiveDeviceID: current.ocrActiveDeviceID,
                            liveFormat: current.liveFormat,
                            ocrFormat: current.ocrFormat
                        )
                    }
                    self.stateLock.unlock()
                    self.verifyAttachedOCRBranchOnSessionQueue(reason: "Recovery G OCR branch-only convergence: \(reason)") { ready in
                        if ready {
                            self.trace("Recovery X OCR branch-only convergence verified id=\(requestedOCRDeviceID) generation=\(self.transitionGeneration) reason=\(reason)")
                            continuation.resume(returning: .attached)
                        } else {
                            continuation.resume(returning: .unavailablePreservingBroadcast("OCR branch attached but no fresh current-generation OCR frame was verified"))
                        }
                    }
                } catch {
                    self.shouldAutoReconnect = true
                    self.trace("Recovery G OCR branch-only convergence unavailable id=\(requestedOCRDeviceID) generation=\(self.transitionGeneration) error=\(error.localizedDescription) reason=\(reason)")
                    self.publishSnapshot(phase: .degraded) { snapshot in
                        snapshot.statusText = "OCR unavailable — Broadcast remains active"
                        snapshot.lastInterruptionText = "Recovery G OCR-only convergence: \(error.localizedDescription)"
                        snapshot.graphText = self.graphDescription() + " ocrBranchConvergenceFailed=true broadcastPreserved=true"
                    }
                    continuation.resume(returning: .unavailablePreservingBroadcast(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Recovery E OCR branch isolation

    /// Recovery E: an external scoreboard-camera availability change is an OCR
    /// branch mutation, not a new capture-session ownership decision. The healthy
    /// Broadcast branch remains attached to the running AVCaptureMultiCamSession.
    /// This is intentionally the same serial hardware-control domain as every
    /// other CaptureEngine mutation; no view, MainActor task or second recovery
    /// controller participates.
    @objc private func videoDeviceWasDisconnected(_ notification: Notification) {
        guard let device = notification.object as? AVCaptureDevice,
              device.hasMediaType(.video),
              device.deviceType == .external else { return }

        let disconnectedDeviceID = device.uniqueID
        let disconnectedDeviceName = device.localizedName
        sessionQueue.async { [weak self, disconnectedDeviceID, disconnectedDeviceName] in
            guard let self else { return }
            guard self.activeGraphModeLocked.requiresOCR || self.lastRequestedMode.requiresOCR else { return }
            let selectedExternalID = self.activeOCRDeviceID ?? self.lastRequestedOCRDeviceID
            guard selectedExternalID == nil || selectedExternalID == disconnectedDeviceID else { return }
            self.stateLock.lock()
            if !self.externalOCRTopologyLocked.isDiscoverable,
               self.externalOCRTopologyLocked.deviceID == nil,
               self.externalOCRTopologyLocked.disconnectCount > 0 {
                self.stateLock.unlock()
                return
            }
            self.externalOCRTopologyLocked = RinkLensExternalOCRTopology(
                revision: self.externalOCRTopologyLocked.revision &+ 1,
                deviceID: nil,
                isDiscoverable: false,
                disconnectCount: self.externalOCRTopologyLocked.disconnectCount + 1,
                reconnectCount: self.externalOCRTopologyLocked.reconnectCount
            )
            self.ocrRecoveryRequirementLocked = nil
            self.stateLock.unlock()
            self.cancelFirstFrameReadinessOnSessionQueue(
                reason: "Recovery X required OCR device disconnected: \(disconnectedDeviceName)"
            )

            guard self.configured,
                  self.session.isRunning,
                  self.activeGraphModeLocked.requiresBroadcast,
                  let retainedLiveDevice = self.liveInput?.device else {
                // There is no verified Broadcast branch to protect. Do not create
                // another fallback owner here; leave the existing lifecycle owner
                // to reconcile the next explicit operator/route request.
                self.shouldAutoReconnect = true
                self.trace("Recovery E external OCR disconnect observed without a healthy Broadcast branch id=\(disconnectedDeviceID)")
                self.publishSnapshot(phase: .degraded) { snapshot in
                    snapshot.statusText = "OCR camera disconnected — waiting for authoritative capture reconciliation"
                    snapshot.lastInterruptionText = "External OCR disconnected: \(disconnectedDeviceName)"
                }
                return
            }

            let retainedOCRDevice = self.ocrInput?.device
            let retainedLiveFormatPreference = self.activeLiveResolvedFormat
                ?? self.activeLiveFormatPreference
                ?? self.lastRequestedLiveFormat
            let disconnectedContract = RinkLensCaptureContractKey(
                mode: .dualCamera,
                liveDeviceID: retainedLiveDevice.uniqueID,
                ocrDeviceID: selectedExternalID ?? disconnectedDeviceID,
                liveFormat: retainedLiveFormatPreference,
                ocrFormat: self.activeOCRResolvedFormat ?? self.activeOCRFormatPreference ?? self.lastRequestedOCRFormat
            )
            self.recordDegradedContract(
                disconnectedContract,
                fallbackMode: .broadcastOnly,
                failureText: "External OCR camera disconnected: \(disconnectedDeviceName)"
            )

            self.removeOCRBranchPreservingBroadcastOnSessionQueue(
                retainedOCRDevice: retainedOCRDevice,
                disconnectedDeviceID: disconnectedDeviceID,
                disconnectedDeviceName: disconnectedDeviceName
            )
        }
    }

    @objc private func videoDeviceWasConnected(_ notification: Notification) {
        guard let device = notification.object as? AVCaptureDevice,
              device.hasMediaType(.video),
              device.deviceType == .external else { return }

        let connectedDeviceID = device.uniqueID
        let connectedDeviceName = device.localizedName
        sessionQueue.async { [weak self, connectedDeviceID, connectedDeviceName] in
            guard let self else { return }
            guard self.shouldAutoReconnect || self.lastRequestedMode.requiresOCR else { return }
            let desiredExternalID = self.lastRequestedOCRDeviceID ?? self.activeOCRDeviceID
            guard desiredExternalID == nil || desiredExternalID == connectedDeviceID else { return }
            self.stateLock.lock()
            if self.externalOCRTopologyLocked.isDiscoverable,
               self.externalOCRTopologyLocked.deviceID == connectedDeviceID {
                self.stateLock.unlock()
                return
            }
            self.externalOCRTopologyLocked = RinkLensExternalOCRTopology(
                revision: self.externalOCRTopologyLocked.revision &+ 1,
                deviceID: connectedDeviceID,
                isDiscoverable: true,
                disconnectCount: self.externalOCRTopologyLocked.disconnectCount,
                reconnectCount: self.externalOCRTopologyLocked.reconnectCount + 1
            )
            let connectedTopology = self.externalOCRTopologyLocked
            self.stateLock.unlock()

            self.lastRequestedOCRDeviceID = connectedDeviceID

            // Recovery O: a USB-connect notification is availability evidence, not
            // permission to mutate the shared MultiCam graph while the final writer
            // contract is open. Recovery N physical testing proved that immediate
            // OCR branch reattachment during a recording can raise a global
            // AVFoundation -11800/-12785 runtime failure and terminate Broadcast.
            // Keep desire/availability current and let the existing writer-close
            // lifecycle replay perform one authoritative OCR restoration.
            if RinkLensRecordingCaptureLease.shared.isWriterContractOpen() {
                self.shouldAutoReconnect = true
                let writerContract = RinkLensRecordingCaptureLease.shared.writerContractDiagnostic()
                let requirement = RinkLensOCRRecoveryRequirement.make(
                    topology: connectedTopology,
                    captureGeneration: self.transitionGeneration,
                    ocrIsDesired: self.shouldAutoReconnect || self.lastRequestedMode.requiresOCR,
                    broadcastIsHealthy: self.configured
                        && self.session.isRunning
                        && self.activeGraphModeLocked.requiresBroadcast
                        && self.liveInput != nil,
                    writerContractIsOpen: true
                )
                self.stateLock.lock()
                self.ocrRecoveryRequirementLocked = requirement
                self.lastDeadBranchRecoveryTextLocked = "External OCR connected; recording-safe continuation recovery requested"
                let requirementHandler = self.ocrRecoveryRequirementHandlerLocked
                self.stateLock.unlock()
                self.publishSnapshot(phase: .running) { snapshot in
                    snapshot.statusText = requirement == nil
                        ? "OCR camera connected — Broadcast recovery unavailable"
                        : "OCR camera connected — preparing recording-safe recovery"
                    snapshot.lastInterruptionText = "External OCR connected: \(connectedDeviceName); writer contract protected"
                    snapshot.graphText = self.graphDescription() + " ocrRecoveryContinuationRequested=\(requirement != nil)"
                }
                RinkLensStructuredEventLogger.shared.record(
                    domain: .capture,
                    event: "ocr_recovery_continuation_requested",
                    entityID: connectedDeviceID,
                    previous: [
                        "mode": self.activeGraphModeLocked.rawValue,
                        "broadcastGeneration": String(self.transitionGeneration),
                        "sessionRunning": String(self.session.isRunning),
                        "writerContract": writerContract
                    ],
                    next: [
                        "broadcastGraph": "retained",
                        "ocrAvailability": "connected",
                        "ocrBranchMutation": "none",
                        "restoreTrigger": "RecordingEngine continuation transaction",
                        "topologyRevision": String(connectedTopology.revision)
                    ],
                    source: "CaptureEngine.videoDeviceWasConnected",
                    reason: "Recovery O protects an open RecordingWriter contract from hot USB OCR reattachment",
                    captureGeneration: self.transitionGeneration,
                    authoritativeOwner: "CaptureEngine"
                )
                if let requirement {
                    requirementHandler?(requirement)
                }
                self.trace("Recovery O external OCR continuation requested while writer contract open id=\(connectedDeviceID) generation=\(self.transitionGeneration) topology=\(connectedTopology.revision)")
                return
            }

            self.stateLock.lock()
            self.ocrRecoveryRequirementLocked = nil
            self.stateLock.unlock()

            guard self.configured,
                  self.session.isRunning,
                  self.activeGraphModeLocked.requiresBroadcast,
                  self.liveInput != nil else {
                self.trace("Recovery E external OCR reconnect observed without retained Broadcast branch id=\(connectedDeviceID)")
                self.publishSnapshot(phase: .recovering) { snapshot in
                    snapshot.statusText = "OCR camera connected — waiting for authoritative capture reconciliation"
                    snapshot.lastInterruptionText = "External OCR connected: \(connectedDeviceName)"
                }
                return
            }

            do {
                try self.addOCRBranchPreservingBroadcastOnSessionQueue(
                    connectedDeviceID: connectedDeviceID,
                    connectedDeviceName: connectedDeviceName
                )
                self.verifyAttachedOCRBranchOnSessionQueue(reason: "Recovery X external OCR reconnect: \(connectedDeviceName)") { ready in
                    if !ready {
                        self.shouldAutoReconnect = true
                        self.trace("Recovery X OCR reconnect remained degraded; fresh OCR frame not verified id=\(connectedDeviceID)")
                    }
                }
            } catch {
                // One physical connect event receives one deterministic branch
                // transaction. Do not spin retry waves or reconstruct Broadcast.
                self.shouldAutoReconnect = true
                self.trace("Recovery E OCR branch attach failed id=\(connectedDeviceID) error=\(error.localizedDescription); Broadcast retained")
                self.publishSnapshot(phase: .degraded) { snapshot in
                    snapshot.statusText = "OCR camera connected but branch attach failed — Broadcast remains active"
                    snapshot.lastInterruptionText = "External OCR reconnect failed: \(error.localizedDescription)"
                    snapshot.graphText = self.graphDescription() + " ocrBranchAttachFailed=true"
                }
                RinkLensStructuredEventLogger.shared.record(
                    domain: .capture,
                    event: "ocr_branch_attach_failed_broadcast_preserved",
                    entityID: connectedDeviceID,
                    previous: [
                        "mode": self.activeGraphModeLocked.rawValue,
                        "broadcastGeneration": String(self.transitionGeneration),
                        "sessionRunning": String(self.session.isRunning)
                    ],
                    next: [
                        "broadcastGraph": "retained",
                        "ocrBranch": "disconnected",
                        "sessionRestarted": "false"
                    ],
                    source: "CaptureEngine.videoDeviceWasConnected",
                    reason: error.localizedDescription,
                    captureGeneration: self.transitionGeneration,
                    authoritativeOwner: "CaptureEngine"
                )
            }
        }
    }

    /// Removes only the external OCR constituent from the already-running
    /// MultiCam graph. The Broadcast input/output/preview and generation are
    /// deliberately untouched. `beginConfiguration` / `commitConfiguration`
    /// form the single AVFoundation transaction; `stopRunning` is never called.
    private func removeOCRBranchPreservingBroadcastOnSessionQueue(
        retainedOCRDevice: AVCaptureDevice?,
        disconnectedDeviceID: String,
        disconnectedDeviceName: String
    ) {
        assertSessionQueue()
        guard configured, session.isRunning, liveInput != nil else { return }

        let retainedOCRPreviewLayer = attachedOCRPreviewLayer
        let oldPreviewConnection = ocrPreviewConnection
        let oldOutputConnection = ocrOutputConnection
        let oldInput = ocrInput
        let broadcastGeneration = transitionGeneration

        session.beginConfiguration()
        if let oldPreviewConnection,
           session.connections.contains(where: { $0 === oldPreviewConnection }) {
            session.removeConnection(oldPreviewConnection)
        }
        if let oldOutputConnection,
           session.connections.contains(where: { $0 === oldOutputConnection }) {
            session.removeConnection(oldOutputConnection)
        }
        if session.outputs.contains(where: { $0 === ocrOutput }) {
            session.removeOutput(ocrOutput)
        }
        if let oldInput,
           session.inputs.contains(where: { $0 === oldInput }) {
            session.removeInput(oldInput)
        }
        session.commitConfiguration()

        ocrInput = nil
        ocrVideoPort = nil
        ocrOutputConnection = nil
        setPreviewConnection(nil, layer: retainedOCRPreviewLayer, for: .ocr)
        setPreviewAttachedLocked(role: .ocr, attached: false)

        stateLock.lock()
        activeGraphModeLocked = .broadcastOnly
        activeOCRDeviceID = nil
        activeOCRDeviceNameLocked = "none"
        activeOCRDevicePositionTextLocked = "unavailable"
        activeOCRDeviceTypeTextLocked = "unavailable"
        activeOCRFormatPreference = nil
        activeOCRResolvedFormat = nil
        configuredOCRCadenceLocked = nil
        ocrConfiguredCadenceTextLocked = "not configured — external OCR disconnected"
        ocrFormatTextLocked = "OCR branch detached; Broadcast branch retained"
        ocrFirstFrameLumaTextLocked = "OCR branch disconnected"
        ocrFramesLocked = 0
        ocrObservedFPSLocked = 0
        ocrLastCallbackUptimeNanosecondsLocked = nil
        ocrObservedFrameUptimesLocked.removeAll(keepingCapacity: true)
        ocrOutputConnectionTextLocked = "OCR output detached; Broadcast preserved"
        if let current = activeEffectiveContract {
            activeEffectiveContract = RinkLensEffectiveCaptureContract(
                desired: current.desired,
                liveActiveDeviceID: current.liveActiveDeviceID,
                ocrActiveDeviceID: nil,
                liveFormat: current.liveFormat,
                ocrFormat: nil
            )
        }
        stateLock.unlock()

        shouldAutoReconnect = true
        RinkLensFrameHub.shared.clear(
            role: .ocr,
            reason: "Recovery E external OCR disconnect; Broadcast generation \(broadcastGeneration) retained"
        )
        ocrService?.setExternallyManagedCaptureActive(
            false,
            device: retainedOCRDevice,
            owner: "Recovery E OCR branch detached; Broadcast retained",
            retainReservation: true
        )
        installSystemPressureObserversOnSessionQueue(
            liveDevice: liveInput?.device,
            ocrDevice: nil
        )
        refreshOutputConnectionTruthOnSessionQueue(reason: "Recovery E OCR branch detached")
        publishSnapshot(phase: .degraded) { snapshot in
            snapshot.captureModeText = RinkLensCaptureLifecycleMode.broadcastOnly.rawValue
            snapshot.statusText = "OCR camera disconnected — Broadcast remains active"
            snapshot.devicePairText = self.deviceDescription(
                mode: .broadcastOnly,
                live: self.liveInput?.device,
                ocr: nil
            )
            snapshot.graphText = self.graphDescription() + " ocrBranchDetached=true sessionRestarted=false"
            snapshot.lastInterruptionText = "External OCR disconnected: \(disconnectedDeviceName); Broadcast generation \(broadcastGeneration) retained"
        }
        trace("Recovery E OCR branch detached id=\(disconnectedDeviceID); Broadcast generation=\(broadcastGeneration) sessionRestarted=false")
        RinkLensStructuredEventLogger.shared.record(
            domain: .capture,
            event: "ocr_branch_detached_broadcast_preserved",
            entityID: disconnectedDeviceID,
            previous: [
                "mode": RinkLensCaptureLifecycleMode.dualCamera.rawValue,
                "broadcastGeneration": String(broadcastGeneration),
                "sessionRunning": "true"
            ],
            next: [
                "mode": RinkLensCaptureLifecycleMode.broadcastOnly.rawValue,
                "broadcastGraph": "retained",
                "ocrBranch": "detached",
                "sessionRestarted": "false",
                "broadcastGeneration": String(broadcastGeneration)
            ],
            source: "CaptureEngine.removeOCRBranchPreservingBroadcastOnSessionQueue",
            reason: "External OCR availability changed; mutation scope is OCR branch only",
            captureGeneration: broadcastGeneration,
            authoritativeOwner: "CaptureEngine"
        )
    }

    private func verifyAttachedOCRBranchOnSessionQueue(
        reason: String,
        completion: @escaping (Bool) -> Void
    ) {
        assertSessionQueue()
        let generation = transitionGeneration
        publishSnapshot(phase: .waitingForFrames) { snapshot in
            snapshot.statusText = "OCR branch attached — waiting for fresh current-generation OCR frame"
            snapshot.lastInterruptionText = "Recovery X OCR restore verification pending"
        }
        beginFirstFrameReadinessOnSessionQueue(mode: .dualCamera, transitionGeneration: generation) { [weak self] ready in
            guard let self, generation == self.transitionGeneration else {
                completion(false)
                return
            }
            if ready {
                self.clearFailureOnSessionQueue()
                self.clearDegradedRecord(reason: "Recovery X OCR branch fresh-frame verified")
                self.publishSnapshot(phase: .running) { snapshot in
                    snapshot.captureModeText = RinkLensCaptureLifecycleMode.dualCamera.rawValue
                    snapshot.statusText = "CaptureEngine running — Broadcast and OCR ready"
                    snapshot.lastInterruptionText = "Recovery X external OCR branch restored and fresh-frame verified"
                    snapshot.graphText = self.graphDescription() + " ocrFreshFrameVerified=true"
                }
                RinkLensStructuredEventLogger.shared.record(
                    domain: .capture,
                    event: "ocr_branch_fresh_frame_verified",
                    entityID: self.activeOCRDeviceID,
                    previous: ["branch": "structurally-attached", "degraded": "true"],
                    next: ["branch": "ready", "degraded": "false", "generation": String(generation)],
                    source: "CaptureEngine.verifyAttachedOCRBranchOnSessionQueue",
                    reason: reason,
                    captureGeneration: generation,
                    authoritativeOwner: "CaptureEngine"
                )
                self.trace("Recovery X OCR branch fresh-frame verified generation=\(generation) reason=\(reason)")
            } else {
                self.publishSnapshot(phase: .degraded) { snapshot in
                    snapshot.statusText = "OCR branch attached but not ready — Broadcast remains active"
                    snapshot.lastInterruptionText = "Recovery X fresh OCR frame verification failed"
                    snapshot.graphText = self.graphDescription() + " ocrFreshFrameVerified=false broadcastPreserved=true"
                }
                RinkLensStructuredEventLogger.shared.record(
                    domain: .capture,
                    event: "ocr_branch_fresh_frame_verification_failed",
                    entityID: self.activeOCRDeviceID,
                    previous: ["branch": "structurally-attached", "generation": String(generation)],
                    next: ["branch": "not-ready", "degraded": "true"],
                    source: "CaptureEngine.verifyAttachedOCRBranchOnSessionQueue",
                    reason: reason,
                    captureGeneration: generation,
                    authoritativeOwner: "CaptureEngine"
                )
                self.trace("Recovery X OCR branch fresh-frame verification failed generation=\(generation) reason=\(reason)")
            }
            completion(ready)
        }
    }

    /// Adds one external OCR input/output/preview branch to the already-running
    /// MultiCam session. The current Broadcast device must remain the exact
    /// physical constituent in an Apple-supported MultiCam set. The method never
    /// changes Broadcast format/zoom, never stops the session and never advances
    /// the Broadcast capture generation.
    private func addOCRBranchPreservingBroadcastOnSessionQueue(
        connectedDeviceID: String,
        connectedDeviceName: String
    ) throws {
        assertSessionQueue()
        guard configured,
              session.isRunning,
              let retainedLiveInput = liveInput else {
            throw MultiCamError.liveCameraUnavailable
        }

        if let existing = ocrInput, existing.device.uniqueID == connectedDeviceID {
            trace("Recovery E OCR branch attach coalesced; device already active id=\(connectedDeviceID)")
            return
        }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: Self.videoDeviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        guard let targetDevice = discovery.devices.first(where: {
            $0.uniqueID == connectedDeviceID && $0.deviceType == .external
        }) else {
            throw MultiCamError.requestedDeviceUnavailable("OCR", connectedDeviceID)
        }
        let retainedLiveDevice = retainedLiveInput.device
        let pairSupported = discovery.supportedMultiCamDeviceSets.contains { set in
            set.contains(where: { $0.uniqueID == retainedLiveDevice.uniqueID })
                && set.contains(where: { $0.uniqueID == targetDevice.uniqueID })
        }
        guard pairSupported else {
            let setText = discovery.supportedMultiCamDeviceSets.map { set in
                set.map { "\($0.localizedName){\($0.uniqueID)}" }.sorted().joined(separator: " + ")
            }.joined(separator: " | ")
            throw MultiCamError.devicePairUnsupported(setText)
        }

        let requestedFormat = lastRequestedOCRFormat
        let cadence = try applyConservativeMultiCamFormat(
            to: targetDevice,
            preference: requestedFormat,
            fallbackWidth: 1920,
            fallbackHeight: 1080,
            fallbackFPS: 30,
            requireExactFallbackDimensions: true
        )
        let candidateInput = try AVCaptureDeviceInput(device: targetDevice)
        candidateInput.videoMinFrameDurationOverride = cadence.duration
        guard let candidatePort = candidateInput.ports.first(where: { $0.mediaType == .video }) else {
            throw MultiCamError.ocrVideoPortMissing
        }

        let retainedOCRPreviewLayer = attachedOCRPreviewLayer
        var newOutputConnection: AVCaptureConnection?
        var newPreviewConnection: AVCaptureConnection?
        var addedOutput = false
        var configurationBegan = false

        do {
            session.beginConfiguration()
            configurationBegan = true

            guard session.canAddInput(candidateInput) else {
                throw MultiCamError.cannotAddOCRInput
            }
            session.addInputWithNoConnections(candidateInput)

            if !session.outputs.contains(where: { $0 === ocrOutput }) {
                guard session.canAddOutput(ocrOutput) else {
                    throw MultiCamError.cannotAddOCROutput
                }
                session.addOutputWithNoConnections(ocrOutput)
                addedOutput = true
            }

            let dataConnection = AVCaptureConnection(inputPorts: [candidatePort], output: ocrOutput)
            guard session.canAddConnection(dataConnection) else {
                throw MultiCamError.cannotConnectOCROutput
            }
            session.addConnection(dataConnection)
            applyDataConnectionSettings(dataConnection, role: .ocr, mirrored: false)
            stateLock.lock()
            let pressureSuspended = ocrPressureSuspendedLocked
            stateLock.unlock()
            dataConnection.isEnabled = !pressureSuspended
            newOutputConnection = dataConnection

            if let retainedOCRPreviewLayer {
                let previewConnection = AVCaptureConnection(
                    inputPort: candidatePort,
                    videoPreviewLayer: retainedOCRPreviewLayer
                )
                guard session.canAddConnection(previewConnection) else {
                    throw MultiCamError.cannotConnectOCROutput
                }
                session.addConnection(previewConnection)
                applyPreviewConnectionSettings(
                    previewConnection,
                    rotationAngle: ocrPreviewRotationAngle
                )
                newPreviewConnection = previewConnection
            }

            let hardwareCost = Double(session.hardwareCost)
            guard hardwareCost < 1.0 else {
                throw MultiCamError.hardwareCostExceeded(hardwareCost)
            }
            let pressureCost = Double(session.systemPressureCost)
            guard pressureCost < 1.0 else {
                throw MultiCamError.systemPressureCostTooHigh(pressureCost)
            }

            session.commitConfiguration()
            configurationBegan = false
        } catch {
            if configurationBegan {
                if let newPreviewConnection,
                   session.connections.contains(where: { $0 === newPreviewConnection }) {
                    session.removeConnection(newPreviewConnection)
                }
                if let newOutputConnection,
                   session.connections.contains(where: { $0 === newOutputConnection }) {
                    session.removeConnection(newOutputConnection)
                }
                if addedOutput,
                   session.outputs.contains(where: { $0 === ocrOutput }) {
                    session.removeOutput(ocrOutput)
                }
                if session.inputs.contains(where: { $0 === candidateInput }) {
                    session.removeInput(candidateInput)
                }
                session.commitConfiguration()
            }
            throw error
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(targetDevice.activeFormat.formatDescription)
        let resolvedFormat = RinkLensCaptureFormatPreference(
            width: dimensions.width,
            height: dimensions.height,
            cadence: RinkLensCaptureCadence(duration: targetDevice.activeVideoMinFrameDuration)
        )
        let broadcastGeneration = transitionGeneration

        ocrInput = candidateInput
        ocrVideoPort = candidatePort
        ocrOutputConnection = newOutputConnection
        setPreviewConnection(newPreviewConnection, layer: retainedOCRPreviewLayer, for: .ocr)
        setPreviewAttachedLocked(role: .ocr, attached: newPreviewConnection != nil)

        stateLock.lock()
        activeGraphModeLocked = .dualCamera
        activeOCRDeviceID = targetDevice.uniqueID
        activeOCRDeviceNameLocked = targetDevice.localizedName
        activeOCRDevicePositionTextLocked = Self.positionText(targetDevice.position)
        activeOCRDeviceTypeTextLocked = targetDevice.deviceType.rawValue
        activeOCRFormatPreference = requestedFormat
        activeOCRResolvedFormat = resolvedFormat
        configuredOCRCadenceLocked = cadence
        ocrConfiguredCadenceTextLocked = "Recovery E branch attach requested \(cadence.displayText)fps; awaiting callback verification"
        ocrFormatTextLocked = "CaptureEngine OCR source \(resolvedFormat.diagnosticText) branch-attached"
        ocrFirstFrameLumaTextLocked = "awaiting OCR frame for retained Broadcast generation \(broadcastGeneration)"
        ocrFramesLocked = 0
        ocrObservedFPSLocked = 0
        ocrLastCallbackUptimeNanosecondsLocked = nil
        ocrObservedFrameUptimesLocked.removeAll(keepingCapacity: true)
        if let current = activeEffectiveContract {
            activeEffectiveContract = RinkLensEffectiveCaptureContract(
                desired: current.desired,
                liveActiveDeviceID: current.liveActiveDeviceID,
                ocrActiveDeviceID: targetDevice.uniqueID,
                liveFormat: current.liveFormat,
                ocrFormat: resolvedFormat
            )
        } else {
            let desired = RinkLensDesiredCaptureContract(
                mode: .dualCamera,
                liveLogicalSourceID: lastRequestedLiveLogicalSourceID,
                ocrLogicalSourceID: lastRequestedOCRLogicalSourceID,
                livePreferredDeviceID: lastRequestedLiveDeviceID,
                ocrPreferredDeviceID: connectedDeviceID,
                liveFormat: lastRequestedLiveFormat,
                ocrFormat: requestedFormat
            )
            activeEffectiveContract = RinkLensEffectiveCaptureContract(
                desired: desired,
                liveActiveDeviceID: retainedLiveDevice.uniqueID,
                ocrActiveDeviceID: targetDevice.uniqueID,
                liveFormat: activeLiveResolvedFormat,
                ocrFormat: resolvedFormat
            )
        }
        stateLock.unlock()

        shouldAutoReconnect = true
        RinkLensFrameHub.shared.clear(
            role: .ocr,
            reason: "Recovery E OCR branch attached; Broadcast generation \(broadcastGeneration) retained"
        )
        installSystemPressureObserversOnSessionQueue(
            liveDevice: retainedLiveDevice,
            ocrDevice: targetDevice
        )
        ocrService?.setExternallyManagedCaptureActive(
            true,
            device: targetDevice,
            owner: "Recovery E CaptureEngine OCR branch attach"
        )
        refreshOutputConnectionTruthOnSessionQueue(reason: "Recovery X OCR branch structurally attached")
        publishSnapshot(phase: .waitingForFrames) { snapshot in
            snapshot.captureModeText = RinkLensCaptureLifecycleMode.dualCamera.rawValue
            snapshot.statusText = "OCR branch attached — verifying fresh current-generation frame"
            snapshot.devicePairText = self.deviceDescription(
                mode: .dualCamera,
                live: retainedLiveDevice,
                ocr: targetDevice
            )
            snapshot.graphText = self.graphDescription() + " ocrBranchAttached=true ocrFreshFrameVerified=false sessionRestarted=false"
            snapshot.lastInterruptionText = "External OCR structurally attached: \(connectedDeviceName); fresh-frame verification pending"
        }
        trace("Recovery X OCR branch structurally attached id=\(connectedDeviceID); Broadcast generation=\(broadcastGeneration) fresh-frame verification pending format=\(resolvedFormat.diagnosticText)")
        RinkLensStructuredEventLogger.shared.record(
            domain: .capture,
            event: "ocr_branch_structurally_attached_broadcast_preserved",
            entityID: connectedDeviceID,
            previous: [
                "mode": RinkLensCaptureLifecycleMode.broadcastOnly.rawValue,
                "broadcastGeneration": String(broadcastGeneration),
                "sessionRunning": "true"
            ],
            next: [
                "mode": RinkLensCaptureLifecycleMode.dualCamera.rawValue,
                "broadcastGraph": "retained",
                "ocrBranch": "structurally-attached",
                "freshFrameVerified": "false",
                "sessionRestarted": "false",
                "broadcastGeneration": String(broadcastGeneration),
                "ocrFormat": resolvedFormat.diagnosticText
            ],
            source: "CaptureEngine.addOCRBranchPreservingBroadcastOnSessionQueue",
            reason: "Recovery X separates structural OCR attachment from fresh-frame readiness",
            captureGeneration: broadcastGeneration,
            authoritativeOwner: "CaptureEngine"
        )
    }

    /// UX16c41 applies an exact cadence change without stopping or rebuilding
    /// the graph when mode, physical devices and active resolutions are unchanged.
    /// Resolution/source/mode changes are deliberately rejected here and remain
    /// CaptureLifecycleController full transactions.
    func applyLiveCadenceMutation(
        mode: RinkLensCaptureLifecycleMode,
        liveRequestedDeviceID: String?,
        ocrRequestedDeviceID: String?,
        liveFormatPreference: RinkLensCaptureFormatPreference?,
        ocrFormatPreference: RinkLensCaptureFormatPreference?,
        reason: String
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }
                self.assertSessionQueue()
                guard self.configured, self.session.isRunning, self.activeLocked, !self.transitioningLocked,
                      self.activeGraphModeLocked == mode else {
                    self.trace("live cadence rejected reason=graph-not-stable requested=\(mode.rawValue) active=\(self.activeGraphModeLocked.rawValue)")
                    continuation.resume(returning: false)
                    return
                }
                if mode.requiresBroadcast, self.activeLiveDeviceID != liveRequestedDeviceID {
                    self.trace("live cadence rejected reason=Broadcast-device-changed")
                    continuation.resume(returning: false)
                    return
                }
                if mode.requiresOCR, self.activeOCRDeviceID != ocrRequestedDeviceID {
                    self.trace("live cadence rejected reason=OCR-device-changed")
                    continuation.resume(returning: false)
                    return
                }

                struct Target {
                    let role: String
                    let device: AVCaptureDevice
                    let input: AVCaptureDeviceInput
                    let requested: RinkLensCaptureFormatPreference
                    let previousMin: CMTime
                    let previousMax: CMTime
                    let previousAutoFrameRate: Bool?
                    let previousAutomaticLowLight: Bool?
                }

                var targets: [Target] = []
                func appendTarget(
                    role: String,
                    device: AVCaptureDevice?,
                    input: AVCaptureDeviceInput?,
                    active: RinkLensCaptureFormatPreference?,
                    requested: RinkLensCaptureFormatPreference?
                ) -> Bool {
                    guard let requested else { return true }
                    guard let device, let input, let active else { return false }
                    guard active.width == requested.width, active.height == requested.height else { return false }
                    if active.cadence == requested.cadence { return true }
                    let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                    guard dimensions.width == requested.width, dimensions.height == requested.height else { return false }
                    let fps = requested.cadence.framesPerSecond
                    guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
                        $0.minFrameRate <= fps + 0.005 && $0.maxFrameRate >= fps - 0.005
                    }) else { return false }
                    targets.append(Target(
                        role: role,
                        device: device,
                        input: input,
                        requested: requested,
                        previousMin: device.activeVideoMinFrameDuration,
                        previousMax: device.activeVideoMaxFrameDuration,
                        previousAutoFrameRate: {
                            if #available(iOS 18.0, *), self.deviceSupportsAutomaticFrameRate(device) {
                                return self.deviceAutomaticFrameRateEnabled(device)
                            }
                            return nil
                        }(),
                        previousAutomaticLowLight: device.isLowLightBoostSupported
                            ? device.automaticallyEnablesLowLightBoostWhenAvailable
                            : nil
                    ))
                    return true
                }

                guard appendTarget(
                    role: "Broadcast",
                    device: mode.requiresBroadcast ? self.liveInput?.device : nil,
                    input: mode.requiresBroadcast ? self.liveInput : nil,
                    active: self.activeLiveResolvedFormat,
                    requested: mode.requiresBroadcast ? liveFormatPreference : nil
                ), appendTarget(
                    role: "OCR",
                    device: mode.requiresOCR ? self.ocrInput?.device : nil,
                    input: mode.requiresOCR ? self.ocrInput : nil,
                    active: self.activeOCRResolvedFormat,
                    requested: mode.requiresOCR ? ocrFormatPreference : nil
                ) else {
                    self.trace("live cadence rejected reason=device-resolution-or-range-mismatch")
                    continuation.resume(returning: false)
                    return
                }

                if targets.isEmpty {
                    self.trace("live cadence coalesced reason=no-cadence-change")
                    continuation.resume(returning: true)
                    return
                }

                var applied: [Target] = []
                do {
                    for target in targets {
                        let device = target.device
                        try device.lockForConfiguration()
                        if target.role == "Broadcast" {
                            let policy = self.appliedBroadcastImageQualityPolicyLocked
                            let autoSupported = self.deviceSupportsAutomaticFrameRate(device)
                            let autoRequested = policy.allowsAutomaticFrameRate && autoSupported
                            if autoSupported { self.setDeviceAutomaticFrameRate(false, on: device) }
                            if autoRequested {
                                device.activeVideoMinFrameDuration = .invalid
                                device.activeVideoMaxFrameDuration = .invalid
                            } else {
                                device.activeVideoMinFrameDuration = target.requested.cadence.duration
                                device.activeVideoMaxFrameDuration = target.requested.cadence.duration
                            }
                            if device.isLowLightBoostSupported {
                                device.automaticallyEnablesLowLightBoostWhenAvailable = policy.requestsAutomaticLowLightBoost
                            }
                            if autoRequested { self.setDeviceAutomaticFrameRate(true, on: device) }
                            device.unlockForConfiguration()
                            target.input.videoMinFrameDurationOverride = autoRequested ? .invalid : target.requested.cadence.duration
                        } else {
                            device.activeVideoMinFrameDuration = target.requested.cadence.duration
                            device.activeVideoMaxFrameDuration = target.requested.cadence.duration
                            device.unlockForConfiguration()
                            target.input.videoMinFrameDurationOverride = target.requested.cadence.duration
                        }
                        applied.append(target)
                    }
                } catch {
                    for target in applied.reversed() {
                        do {
                            try target.device.lockForConfiguration()
                            let canAuto = self.deviceSupportsAutomaticFrameRate(target.device)
                            if canAuto { self.setDeviceAutomaticFrameRate(false, on: target.device) }
                            if target.previousAutoFrameRate == true, canAuto {
                                target.device.activeVideoMinFrameDuration = .invalid
                                target.device.activeVideoMaxFrameDuration = .invalid
                            } else {
                                target.device.activeVideoMinFrameDuration = target.previousMin
                                target.device.activeVideoMaxFrameDuration = target.previousMax
                            }
                            if let previous = target.previousAutomaticLowLight {
                                target.device.automaticallyEnablesLowLightBoostWhenAvailable = previous
                            }
                            if target.previousAutoFrameRate == true, canAuto {
                                self.setDeviceAutomaticFrameRate(true, on: target.device)
                            }
                            target.device.unlockForConfiguration()
                            target.input.videoMinFrameDurationOverride = target.previousAutoFrameRate == true ? .invalid : target.previousMin
                        } catch {
                            self.trace("live cadence rollback failed role=\(target.role) error=\(error.localizedDescription)")
                        }
                    }
                    self.trace("live cadence failed error=\(error.localizedDescription) reason=\(reason)")
                    continuation.resume(returning: false)
                    return
                }

                self.stateLock.lock()
                if mode.requiresBroadcast, let requested = liveFormatPreference {
                    self.lastRequestedLiveFormat = requested
                    self.activeLiveFormatPreference = requested
                    self.activeLiveResolvedFormat = requested
                    self.liveFormatTextLocked = "CaptureEngine Broadcast source \(requested.diagnosticText) live-mutated"
                }
                if mode.requiresOCR, let requested = ocrFormatPreference {
                    self.lastRequestedOCRFormat = requested
                    self.activeOCRFormatPreference = requested
                    self.activeOCRResolvedFormat = requested
                    self.ocrFormatTextLocked = "CaptureEngine OCR source \(requested.diagnosticText) live-mutated"
                }
                if let existing = self.activeEffectiveContract {
                    self.activeEffectiveContract = RinkLensEffectiveCaptureContract(
                        desired: RinkLensDesiredCaptureContract(
                            mode: existing.desired.mode,
                            liveLogicalSourceID: existing.desired.liveLogicalSourceID,
                            ocrLogicalSourceID: existing.desired.ocrLogicalSourceID,
                            livePreferredDeviceID: existing.desired.livePreferredDeviceID,
                            ocrPreferredDeviceID: existing.desired.ocrPreferredDeviceID,
                            liveFormat: mode.requiresBroadcast ? (liveFormatPreference ?? existing.desired.liveFormat) : nil,
                            ocrFormat: mode.requiresOCR ? (ocrFormatPreference ?? existing.desired.ocrFormat) : nil
                        ),
                        liveActiveDeviceID: existing.liveActiveDeviceID,
                        ocrActiveDeviceID: existing.ocrActiveDeviceID,
                        liveFormat: mode.requiresBroadcast ? self.activeLiveResolvedFormat : nil,
                        ocrFormat: mode.requiresOCR ? self.activeOCRResolvedFormat : nil
                    )
                }
                self.stateLock.unlock()

                let detail = targets.map { "\($0.role)=\($0.requested.cadence.displayText)fps" }.joined(separator: " ")
                self.publishSnapshot(phase: .running) { snapshot in
                    snapshot.statusText = "Capture cadence updated live — no graph rebuild"
                    snapshot.graphText = self.graphDescription() + " liveCadence={\(detail)}"
                }
                self.trace("live cadence applied \(detail) reason=\(reason) sessionRestarted=false")
                continuation.resume(returning: true)
            }
        }
    }

    func start(
        mode: RinkLensCaptureLifecycleMode,
        liveLogicalSourceID: String?,
        ocrLogicalSourceID: String?,
        liveRequestedDeviceID: String?,
        ocrRequestedDeviceID: String?,
        liveFormatPreference: RinkLensCaptureFormatPreference? = nil,
        ocrFormatPreference: RinkLensCaptureFormatPreference? = nil,
        recoveryPairedOCRDeviceID: String? = nil,
        reason: String
    ) async -> Bool {
        guard mode != .stopped else {
            await stop(reason: reason)
            return true
        }

        return await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }

                let now = CFAbsoluteTimeGetCurrent()
                let reconnectReason = reason.localizedCaseInsensitiveContains("reconnect")
                let requestedContract = RinkLensCaptureContractKey(
                    mode: mode,
                    liveDeviceID: liveRequestedDeviceID,
                    ocrDeviceID: ocrRequestedDeviceID,
                    liveFormat: liveFormatPreference,
                    ocrFormat: ocrFormatPreference
                )
                if mode == .dualCamera,
                   let degraded = self.degradedRecord(matching: requestedContract),
                   degraded.isCooldownActive,
                   !reconnectReason {
                    self.publishSnapshot(phase: .degraded) { snapshot in
                        snapshot.statusText = "Exact failed camera contract cooling down — operator Retry available"
                    }
                    self.trace("start suppressed by persistent failed-contract cooldown remaining=\(String(format: "%.1f", degraded.cooldownRemainingSeconds))s contract={\(requestedContract.diagnosticText)}")
                    continuation.resume(returning: false)
                    return
                }
                self.stateLock.lock()
                let failureAt = self.lastStartFailureAt
                let failureText = self.lastStartFailureText
                let failureLatched = self.failureLatchedLocked
                self.stateLock.unlock()
                if failureLatched && !reconnectReason {
                    self.publishState(status: "Capture engine unavailable", phase: .degraded)
                    self.trace("start suppressed by failure latch mode=\(mode.rawValue) failure=\(failureText)")
                    continuation.resume(returning: false)
                    return
                }
                if !reconnectReason,
                   failureAt > 0,
                   now - failureAt < self.failedStartCooldown,
                   self.lastRequestedMode == mode,
                   self.lastRequestedLiveLogicalSourceID == liveLogicalSourceID,
                   self.lastRequestedOCRLogicalSourceID == ocrLogicalSourceID,
                   self.lastRequestedLiveDeviceID == liveRequestedDeviceID,
                   self.lastRequestedOCRDeviceID == ocrRequestedDeviceID,
                   self.lastRequestedLiveFormat == liveFormatPreference,
                   self.lastRequestedOCRFormat == ocrFormatPreference {
                    let remaining = self.failedStartCooldown - (now - failureAt)
                    self.publishState(status: "Capture retry cooling down", phase: .recovering)
                    self.trace("start suppressed for \(String(format: "%.1f", max(0, remaining)))s mode=\(mode.rawValue) failure=\(failureText)")
                    continuation.resume(returning: false)
                    return
                }

                self.lastRequestedMode = mode
                self.lastRequestedLiveLogicalSourceID = liveLogicalSourceID
                self.lastRequestedOCRLogicalSourceID = ocrLogicalSourceID
                self.lastRequestedLiveDeviceID = liveRequestedDeviceID
                self.lastRequestedOCRDeviceID = ocrRequestedDeviceID
                self.lastRequestedLiveFormat = liveFormatPreference
                self.lastRequestedOCRFormat = ocrFormatPreference
                self.shouldAutoReconnect = mode.requiresOCR
                self.transitionGeneration += 1
                let generation = self.transitionGeneration
                RinkLensFrameHub.shared.clearAll(
                    reason: "CaptureEngine generation \(generation) starting mode=\(mode.rawValue): \(reason)"
                )
                self.setTransitioningLocked(true)
                self.publishSnapshot(phase: .discoveringDevices) { snapshot in
                    snapshot.captureModeText = mode.rawValue
                    snapshot.statusText = "Discovering cameras for \(mode.rawValue)"
                }
                self.trace("start requested generation=\(generation) mode=\(mode.rawValue) liveLogical=\(liveLogicalSourceID ?? "none") livePreferred=\(liveRequestedDeviceID ?? "none") ocrLogical=\(ocrLogicalSourceID ?? "none") ocrPreferred=\(ocrRequestedDeviceID ?? "none") recoveryPairOCR=\(recoveryPairedOCRDeviceID ?? "none") liveFormat=\(liveFormatPreference?.diagnosticText ?? "auto") ocrFormat=\(ocrFormatPreference?.diagnosticText ?? "auto") reason=\(reason)")

                do {
                    let devices = try self.resolveDevices(
                        mode: mode,
                        liveRequestedDeviceID: liveRequestedDeviceID,
                        ocrRequestedDeviceID: ocrRequestedDeviceID,
                        recoveryPairedOCRDeviceID: recoveryPairedOCRDeviceID
                    )

                    let retainedGraphMatches = self.configured
                        && self.activeGraphModeLocked == mode
                        && self.activeLiveDeviceID == devices.live?.uniqueID
                        && self.activeOCRDeviceID == devices.ocr?.uniqueID
                        && self.activeEffectiveContract?.desired.liveLogicalSourceID == (mode.requiresBroadcast ? liveLogicalSourceID : nil)
                        && self.activeEffectiveContract?.desired.ocrLogicalSourceID == (mode.requiresOCR ? ocrLogicalSourceID : nil)
                        && self.activeLiveFormatPreference == liveFormatPreference
                        && self.activeOCRFormatPreference == ocrFormatPreference

                    if retainedGraphMatches {
                        self.resetFirstFrameCountersOnSessionQueue()
                        if !self.session.isRunning {
                            self.publishSnapshot(phase: .starting) { snapshot in
                                snapshot.captureModeText = mode.rawValue
                                snapshot.statusText = "Starting retained capture graph"
                            }
                            self.session.startRunning()
                        }
                        let running = self.session.isRunning
                        if running {
                            self.publishSnapshot(phase: .waitingForFrames) { snapshot in
                                snapshot.statusText = self.waitingStatus(for: mode)
                            }
                        }
                        guard running else {
                            self.completeStart(
                                ready: false,
                                running: false,
                                mode: mode,
                                liveDevice: devices.live,
                                ocrDevice: devices.ocr,
                                failurePrefix: "Retained capture graph"
                            )
                            continuation.resume(returning: false)
                            return
                        }
                        self.beginFirstFrameReadinessOnSessionQueue(mode: mode, transitionGeneration: generation) { [weak self] ready in
                            guard let self else {
                                continuation.resume(returning: false)
                                return
                            }
                            guard generation == self.transitionGeneration else {
                                self.trace("retained graph readiness abandoned stale generation=\(generation) current=\(self.transitionGeneration)")
                                continuation.resume(returning: false)
                                return
                            }
                            self.completeStart(
                                ready: ready,
                                running: self.session.isRunning,
                                mode: mode,
                                liveDevice: self.liveInput?.device,
                                ocrDevice: self.ocrInput?.device,
                                failurePrefix: "Retained capture graph"
                            )
                            continuation.resume(returning: mode == .dualCamera ? ready : (ready || self.session.isRunning))
                        }
                        return
                    }

                    try self.configureGraph(
                        mode: mode,
                        liveLogicalSourceID: liveLogicalSourceID,
                        ocrLogicalSourceID: ocrLogicalSourceID,
                        livePreferredDeviceID: liveRequestedDeviceID,
                        ocrPreferredDeviceID: ocrRequestedDeviceID,
                        liveDevice: devices.live,
                        ocrDevice: devices.ocr,
                        liveFormatPreference: liveFormatPreference,
                        ocrFormatPreference: ocrFormatPreference
                    )
                    guard generation == self.transitionGeneration else {
                        self.setTransitioningLocked(false)
                        continuation.resume(returning: false)
                        return
                    }

                    if !self.session.isRunning {
                        self.publishSnapshot(phase: .starting) { snapshot in
                            snapshot.statusText = "Starting capture session"
                        }
                        self.trace("calling AVCaptureMultiCamSession.startRunning mode=\(mode.rawValue)")
                        self.session.startRunning()
                    }

                    let running = self.session.isRunning
                    if running {
                        self.publishSnapshot(phase: .waitingForFrames) { snapshot in
                            snapshot.statusText = self.waitingStatus(for: mode)
                        }
                    }
                    guard running else {
                        self.completeStart(
                            ready: false,
                            running: false,
                            mode: mode,
                            liveDevice: devices.live,
                            ocrDevice: devices.ocr,
                            failurePrefix: "Capture graph"
                        )
                        self.trace("start completed mode=\(mode.rawValue) running=false ready=false graph={\(self.graphDescription())}")
                        continuation.resume(returning: false)
                        return
                    }
                    self.beginFirstFrameReadinessOnSessionQueue(mode: mode, transitionGeneration: generation) { [weak self] ready in
                        guard let self else {
                            continuation.resume(returning: false)
                            return
                        }
                        guard generation == self.transitionGeneration else {
                            self.trace("capture graph readiness abandoned stale generation=\(generation) current=\(self.transitionGeneration)")
                            continuation.resume(returning: false)
                            return
                        }
                        self.completeStart(
                            ready: ready,
                            running: self.session.isRunning,
                            mode: mode,
                            liveDevice: self.liveInput?.device,
                            ocrDevice: self.ocrInput?.device,
                            failurePrefix: "Capture graph"
                        )
                        self.trace("start completed mode=\(mode.rawValue) running=\(self.session.isRunning) ready=\(ready) graph={\(self.graphDescription())}")
                        continuation.resume(returning: mode == .dualCamera ? ready : (ready || self.session.isRunning))
                    }
                    return
                } catch {
                    self.latchStartFailureOnSessionQueue(
                        detail: error.localizedDescription,
                        retainedLiveDevice: self.liveInput?.device,
                        retainedOCRDevice: self.ocrInput?.device
                    )
                    self.trace("start failed mode=\(mode.rawValue) error=\(error.localizedDescription)")
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func completeStart(
        ready: Bool,
        running: Bool,
        mode: RinkLensCaptureLifecycleMode,
        liveDevice: AVCaptureDevice?,
        ocrDevice: AVCaptureDevice?,
        failurePrefix: String
    ) {
        assertSessionQueue()
        // R17: a running, structurally configured AVCaptureSession is healthy even
        // when its first sample arrives after the presentation readiness budget.
        // First-frame latency is presentation state, not a reason to tear down the
        // graph, latch failure or poison the next dual-camera request.
        setActiveLocked(running)
        setTransitioningLocked(false)
        liveService?.setExternallyManagedCaptureActive(
            running && mode.requiresBroadcast,
            device: liveDevice,
            owner: "UX16c35 CaptureEngine"
        )
        ocrService?.setExternallyManagedCaptureActive(
            running && mode.requiresOCR,
            device: ocrDevice,
            owner: "UX16c35 CaptureEngine"
        )
        if running {
            enforceConfiguredCadencesOnSessionQueue(reason: "post-start authoritative cadence verification")
            refreshOutputConnectionTruthOnSessionQueue(reason: "post-start running verification")
            if ready {
                clearFailureOnSessionQueue()
                publishState(status: runningStatus(for: mode), phase: .running)
            } else if mode == .dualCamera {
                // Recovery X / RL-057: a running AVCaptureSession is not a
                // successful dual-camera contract until both required physical
                // branches have produced current-generation frames. Keep the
                // graph observable, but report the request as degraded so the
                // lifecycle owner can choose its existing Broadcast fallback.
                publishSnapshot(phase: .degraded) { snapshot in
                    snapshot.statusText = "Dual-camera graph running — required OCR frame not verified"
                    snapshot.lastInterruptionText = "Recovery X rejected dual-camera readiness without both required first frames"
                }
                RinkLensStructuredEventLogger.shared.record(
                    domain: .capture,
                    event: "capture_required_branch_readiness_failed",
                    entityID: mode.rawValue,
                    previous: ["ready": "false", "sessionRunning": "true"],
                    next: ["graphAccepted": "false", "fallbackEligible": "true"],
                    source: "CaptureEngine.completeStart",
                    reason: "Recovery X requires current-generation Broadcast and OCR frames before dual-camera success",
                    captureGeneration: transitionGenerationSnapshotLocked,
                    authoritativeOwner: "CaptureEngine"
                )
                trace("\(failurePrefix) dual-camera readiness rejected; required OCR frame not verified")
            } else {
                clearFailureOnSessionQueue()
                // R18 remains valid for single-branch graphs: a running graph can
                // remain operational while its presentation frame is late.
                publishSnapshot(phase: .running) { snapshot in
                    snapshot.statusText = "Capture graph running — first \(mode.rawValue) frame pending"
                    snapshot.lastInterruptionText = "First-frame readiness budget elapsed; graph remains operational"
                }
                RinkLensStructuredEventLogger.shared.record(
                    domain: .capture,
                    event: "capture_first_frame_pending_graph_retained",
                    entityID: mode.rawValue,
                    previous: ["ready": "false", "sessionRunning": "true"],
                    next: ["graphRetained": "true", "failureLatched": "false"],
                    source: "CaptureEngine.completeStart",
                    reason: "R17 separates single-branch presentation readiness from structural capture health",
                    captureGeneration: transitionGenerationSnapshotLocked,
                    authoritativeOwner: "CaptureEngine"
                )
                trace("\(failurePrefix) first-frame readiness budget elapsed for \(mode.rawValue); running graph retained")
            }
        } else {
            latchStartFailureOnSessionQueue(
                detail: "AVCaptureMultiCamSession.startRunning returned with isRunning=false for \(mode.rawValue)",
                retainedLiveDevice: liveDevice,
                retainedOCRDevice: ocrDevice
            )
        }
    }

    private func waitingStatus(for mode: RinkLensCaptureLifecycleMode) -> String {
        switch mode {
        case .dualCamera: return "Waiting for Broadcast and OCR first frames"
        case .broadcastOnly: return "Waiting for Broadcast first frame"
        case .ocrOnly: return "Waiting for OCR first frame"
        case .stopped: return "Capture stopped"
        }
    }

    private func runningStatus(for mode: RinkLensCaptureLifecycleMode) -> String {
        switch mode {
        case .dualCamera: return "CaptureEngine running — Broadcast and OCR ready"
        case .broadcastOnly: return "CaptureEngine running — Broadcast only"
        case .ocrOnly: return "CaptureEngine running — OCR only"
        case .stopped: return "Capture stopped"
        }
    }

    func stop(reason: String) async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }

                // UX16c24: route teardown can arrive from both the route gate and
                // BroadcastView.onDisappear. Do not publish/release the same owner twice.
                let alreadyStopped = !self.session.isRunning
                    && !self.configured
                    && !self.isCaptureActiveSnapshot
                    && !self.isTransitioningSnapshot
                if alreadyStopped {
                    self.trace("duplicate stop ignored reason=\(reason)")
                    continuation.resume()
                    return
                }

                self.transitionGeneration += 1
                self.cancelFirstFrameReadinessOnSessionQueue(reason: "capture stop: \(reason)")
                self.reconnectGeneration += 1
                self.shouldAutoReconnect = false
                self.setTransitioningLocked(true)
                self.publishSnapshot(phase: .stopping) { snapshot in
                    snapshot.statusText = "Stopping CaptureEngine"
                }
                self.trace("stop requested reason=\(reason)")
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                self.teardownGraph()
                self.setPreviewAttachedLocked(false)
                self.setActiveLocked(false)
                self.setTransitioningLocked(false)
                self.liveService?.setExternallyManagedCaptureActive(false, device: nil, owner: "UX16c38 CaptureEngine stopped")
                self.ocrService?.setExternallyManagedCaptureActive(false, device: nil, owner: "UX16c38 CaptureEngine stopped")
                self.publishSnapshot(phase: .stopped) { snapshot in
                    snapshot.statusText = "CaptureEngine stopped"
                    snapshot.graphText = "CaptureEngine graph released: \(reason)"
                }
                self.trace("stop completed reason=\(reason)")
                continuation.resume()
            }
        }
    }

    /// Backward-compatible Broadcast endpoint. Stage 2 adds the role-aware
    /// overload below so OCR Setup can mount the external camera from the same
    /// persistent MultiCam graph.
    func attachPreviewLayer(_ previewLayer: AVCaptureVideoPreviewLayer, rotationAngle: CGFloat, reason: String) {
        attachPreviewLayer(previewLayer, role: .broadcast, rotationAngle: rotationAngle, reason: reason)
    }

    func attachPreviewLayer(
        _ previewLayer: AVCaptureVideoPreviewLayer,
        role: RinkLensCapturePreviewRole,
        rotationAngle: CGFloat,
        reason: String
    ) {
        let previewLayerBox = RinkLensWeakPreviewLayerBox(previewLayer)
        sessionQueue.async { [weak self, previewLayerBox] in
            guard let self, let previewLayer = previewLayerBox.value else { return }
            self.setRequestedPreviewLayer(previewLayer, role: role, rotationAngle: rotationAngle)
            guard self.configured, let videoPort = self.videoPort(for: role) else {
                self.trace("\(role.displayName) preview request retained; branch not configured reason=\(reason)")
                self.setPreviewAttachedLocked(role: role, attached: false)
                return
            }

            let currentLayer = self.attachedPreviewLayer(for: role)
            let currentConnection = self.previewConnection(for: role)
            if currentLayer === previewLayer,
               let currentConnection,
               self.session.connections.contains(where: { $0 === currentConnection }) {
                self.applyPreviewConnectionSettings(currentConnection, rotationAngle: rotationAngle)
                self.setPreviewAttachedLocked(role: role, attached: true)
                return
            }

            self.session.beginConfiguration()
            if let previous = currentConnection,
               self.session.connections.contains(where: { $0 === previous }) {
                self.session.removeConnection(previous)
            }
            let connection = AVCaptureConnection(inputPort: videoPort, videoPreviewLayer: previewLayer)
            guard self.session.canAddConnection(connection) else {
                self.session.commitConfiguration()
                self.trace("\(role.displayName) preview connection rejected reason=\(reason)")
                self.setPreviewAttachedLocked(role: role, attached: false)
                self.publishSnapshot { snapshot in
                    snapshot.statusText = "\(role.displayName) CaptureEngine preview connection failed"
                }
                return
            }
            self.session.addConnection(connection)
            self.applyPreviewConnectionSettings(connection, rotationAngle: rotationAngle)
            self.setPreviewConnection(connection, layer: previewLayer, for: role)
            self.session.commitConfiguration()
            self.trace("\(role.displayName) preview attached layer=\(String(ObjectIdentifier(previewLayer).hashValue, radix: 16)) rotation=\(Int(rotationAngle)) reason=\(reason)")
            self.setPreviewAttachedLocked(role: role, attached: true)
            self.publishSnapshot { snapshot in
                snapshot.statusText = self.session.isRunning
                    ? "MultiCam running — \(role.displayName) preview attached"
                    : "\(role.displayName) MultiCam preview attached"
            }
        }
    }

    /// Recovery AI / RL-076: repair only the retained preview connection when
    /// the physical data branch is already healthy. A black/stale SwiftUI preview
    /// must not tear down two working camera inputs, reset capture generation or
    /// discard fresh FrameHub evidence.
    func recoverPreviewEndpointIfCaptureHealthy(
        role: RinkLensCapturePreviewRole,
        maximumCallbackAge: TimeInterval = 1.0,
        reason: String
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }
                self.assertSessionQueue()
                guard self.configured,
                      self.session.isRunning,
                      let videoPort = self.videoPort(for: role),
                      let previewLayer = self.attachedPreviewLayer(for: role) else {
                    self.trace("\(role.displayName) preview-only recovery unavailable; graph/layer not ready reason=\(reason)")
                    continuation.resume(returning: false)
                    return
                }

                let now = DispatchTime.now().uptimeNanoseconds
                self.stateLock.lock()
                let lastCallback: UInt64?
                switch role {
                case .broadcast: lastCallback = self.liveLastCallbackUptimeNanosecondsLocked
                case .ocr: lastCallback = self.ocrLastCallbackUptimeNanosecondsLocked
                }
                self.stateLock.unlock()
                let callbackAge = lastCallback.map { callback in
                    now >= callback ? Double(now - callback) / 1_000_000_000.0 : 0
                }
                guard let callbackAge, callbackAge <= maximumCallbackAge else {
                    self.trace("\(role.displayName) preview-only recovery rejected; data callback stale age=\(callbackAge.map { String(format: "%.3f", $0) } ?? "none") reason=\(reason)")
                    continuation.resume(returning: false)
                    return
                }

                let previousConnection = self.previewConnection(for: role)
                self.session.beginConfiguration()
                if let previousConnection,
                   self.session.connections.contains(where: { $0 === previousConnection }) {
                    self.session.removeConnection(previousConnection)
                }

                let replacement = AVCaptureConnection(inputPort: videoPort, videoPreviewLayer: previewLayer)
                guard self.session.canAddConnection(replacement) else {
                    if let previousConnection,
                       self.session.canAddConnection(previousConnection) {
                        self.session.addConnection(previousConnection)
                        self.applyPreviewConnectionSettings(
                            previousConnection,
                            rotationAngle: self.previewRotationAngle(for: role)
                        )
                        self.setPreviewConnection(previousConnection, layer: previewLayer, for: role)
                        self.setPreviewAttachedLocked(role: role, attached: true)
                    }
                    self.session.commitConfiguration()
                    self.trace("\(role.displayName) preview-only replacement rejected; physical graph preserved reason=\(reason)")
                    continuation.resume(returning: false)
                    return
                }

                self.session.addConnection(replacement)
                self.applyPreviewConnectionSettings(
                    replacement,
                    rotationAngle: self.previewRotationAngle(for: role)
                )
                self.setPreviewConnection(replacement, layer: previewLayer, for: role)
                self.setPreviewAttachedLocked(role: role, attached: true)
                self.session.commitConfiguration()
                self.refreshOutputConnectionTruthOnSessionQueue(reason: "Recovery AI preview-only reattach")
                self.publishSnapshot { snapshot in
                    snapshot.statusText = "\(role.displayName) preview endpoint reattached; capture graph preserved"
                }
                self.trace("\(role.displayName) preview-only recovery completed callbackAge=\(String(format: "%.3f", callbackAge))s reason=\(reason)")
                RinkLensStructuredEventLogger.shared.record(
                    domain: .capture,
                    event: "capture_preview_endpoint_recovered_without_graph_rebuild",
                    entityID: role.displayName,
                    previous: [
                        "sessionRunning": "true",
                        "callbackAgeSeconds": String(format: "%.3f", callbackAge),
                        "captureGeneration": String(self.transitionGeneration)
                    ],
                    next: [
                        "previewConnection": "reattached",
                        "captureGraph": "preserved",
                        "captureGeneration": String(self.transitionGeneration)
                    ],
                    source: "ExternalOCRMultiCamCoordinator.recoverPreviewEndpointIfCaptureHealthy",
                    reason: reason,
                    captureGeneration: self.transitionGeneration,
                    authoritativeOwner: "CaptureEngine"
                )
                continuation.resume(returning: true)
            }
        }
    }

    func detachPreviewLayer(_ previewLayer: AVCaptureVideoPreviewLayer, reason: String) {
        detachPreviewLayer(previewLayer, role: .broadcast, reason: reason)
    }

    func detachPreviewLayer(
        _ previewLayer: AVCaptureVideoPreviewLayer,
        role: RinkLensCapturePreviewRole,
        reason: String
    ) {
        let previewLayerBox = RinkLensWeakPreviewLayerBox(previewLayer)
        sessionQueue.async { [weak self, previewLayerBox] in
            guard let self else { return }
            let previewLayer = previewLayerBox.value
            let attachedLayer = self.attachedPreviewLayer(for: role)
            guard previewLayer == nil || attachedLayer === previewLayer else { return }
            if let connection = self.previewConnection(for: role),
               self.session.connections.contains(where: { $0 === connection }) {
                self.session.beginConfiguration()
                self.session.removeConnection(connection)
                self.session.commitConfiguration()
            }
            self.setPreviewConnection(nil, layer: nil, for: role)
            self.trace("\(role.displayName) preview detached reason=\(reason)")
            self.setPreviewAttachedLocked(role: role, attached: false)
        }
    }

    func updatePreviewRotation(_ rotationAngle: CGFloat) {
        updatePreviewRotation(rotationAngle, role: .broadcast)
    }

    func updatePreviewRotation(_ rotationAngle: CGFloat, role: RinkLensCapturePreviewRole) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.setPreviewRotationAngle(rotationAngle, for: role)
            guard let connection = self.previewConnection(for: role) else { return }
            self.applyPreviewConnectionSettings(connection, rotationAngle: rotationAngle)
        }
    }

    private func setRequestedPreviewLayer(
        _ layer: AVCaptureVideoPreviewLayer,
        role: RinkLensCapturePreviewRole,
        rotationAngle: CGFloat
    ) {
        setPreviewRotationAngle(rotationAngle, for: role)
        switch role {
        case .broadcast:
            attachedBroadcastPreviewLayer = layer
        case .ocr:
            attachedOCRPreviewLayer = layer
        }
    }

    private func setPreviewRotationAngle(_ angle: CGFloat, for role: RinkLensCapturePreviewRole) {
        switch role {
        case .broadcast: broadcastPreviewRotationAngle = angle
        case .ocr: ocrPreviewRotationAngle = angle
        }
    }

    private func previewRotationAngle(for role: RinkLensCapturePreviewRole) -> CGFloat {
        switch role {
        case .broadcast: return broadcastPreviewRotationAngle
        case .ocr: return ocrPreviewRotationAngle
        }
    }

    /// Reconnect a still-mounted SwiftUI preview after a graph-mode change.
    /// The layer survives dual/Broadcast-only/OCR-only reconfiguration; only its
    /// AVCaptureConnection is replaced on the session queue.
    private func reconnectRetainedPreviewIfPossible(
        role: RinkLensCapturePreviewRole,
        port: AVCaptureInput.Port?
    ) {
        guard let port, let layer = attachedPreviewLayer(for: role) else {
            setPreviewConnection(nil, layer: attachedPreviewLayer(for: role), for: role)
            setPreviewAttachedLocked(role: role, attached: false)
            return
        }
        let connection = AVCaptureConnection(inputPort: port, videoPreviewLayer: layer)
        guard session.canAddConnection(connection) else {
            setPreviewConnection(nil, layer: layer, for: role)
            setPreviewAttachedLocked(role: role, attached: false)
            trace("\(role.displayName) retained preview connection rejected during graph configure")
            return
        }
        session.addConnection(connection)
        applyPreviewConnectionSettings(
            connection,
            rotationAngle: previewRotationAngle(for: role)
        )
        setPreviewConnection(connection, layer: layer, for: role)
        setPreviewAttachedLocked(role: role, attached: true)
        trace("\(role.displayName) retained preview reconnected during graph configure")
    }

    private func videoPort(for role: RinkLensCapturePreviewRole) -> AVCaptureInput.Port? {
        switch role {
        case .broadcast: return liveVideoPort
        case .ocr: return ocrVideoPort
        }
    }

    private func previewConnection(for role: RinkLensCapturePreviewRole) -> AVCaptureConnection? {
        switch role {
        case .broadcast: return broadcastPreviewConnection
        case .ocr: return ocrPreviewConnection
        }
    }

    private func attachedPreviewLayer(for role: RinkLensCapturePreviewRole) -> AVCaptureVideoPreviewLayer? {
        switch role {
        case .broadcast: return attachedBroadcastPreviewLayer
        case .ocr: return attachedOCRPreviewLayer
        }
    }

    private func setPreviewConnection(
        _ connection: AVCaptureConnection?,
        layer: AVCaptureVideoPreviewLayer?,
        for role: RinkLensCapturePreviewRole
    ) {
        switch role {
        case .broadcast:
            broadcastPreviewConnection = connection
            attachedBroadcastPreviewLayer = layer
        case .ocr:
            ocrPreviewConnection = connection
            attachedOCRPreviewLayer = layer
        }
    }

    private func applyPreviewConnectionSettings(_ connection: AVCaptureConnection, rotationAngle: CGFloat) {
        if !connection.isEnabled { connection.isEnabled = true }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        if #available(iOS 17.0, *), connection.isVideoRotationAngleSupported(rotationAngle) {
            connection.videoRotationAngle = rotationAngle
        }
    }

    private func resolveDevices(
        mode: RinkLensCaptureLifecycleMode,
        liveRequestedDeviceID: String?,
        ocrRequestedDeviceID: String?,
        recoveryPairedOCRDeviceID: String?
    ) throws -> (live: AVCaptureDevice?, ocr: AVCaptureDevice?) {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            throw MultiCamError.notSupported
        }
        switch mode {
        case .dualCamera:
            let pair = try resolveSupportedPair(
                liveRequestedDeviceID: liveRequestedDeviceID,
                ocrRequestedDeviceID: ocrRequestedDeviceID
            )
            return (pair.live, pair.ocr)
        case .broadcastOnly:
            return (
                try resolveLiveDevice(
                    requestedDeviceID: liveRequestedDeviceID,
                    recoveryPairedOCRDeviceID: recoveryPairedOCRDeviceID
                ),
                nil
            )
        case .ocrOnly:
            return (nil, try resolveOCRDevice(requestedDeviceID: ocrRequestedDeviceID))
        case .stopped:
            return (nil, nil)
        }
    }

    private func discoveredVideoDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: Self.videoDeviceTypes,
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    private func resolveLiveDevice(
        requestedDeviceID: String?,
        recoveryPairedOCRDeviceID: String? = nil
    ) throws -> AVCaptureDevice {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: Self.videoDeviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        let devices = discovery.devices
        if let requestedDeviceID {
            guard let requested = devices.first(where: { $0.uniqueID == requestedDeviceID }) else {
                throw MultiCamError.requestedDeviceUnavailable("Broadcast", requestedDeviceID)
            }

            // Recovery AB / RL-060: a Broadcast-only graph created as degradation
            // from a still-desired dual-camera contract must remain recoverable by
            // that OCR camera. Generic Broadcast-only startup may prefer Apple's
            // virtual rear source, but degraded fallback must not silently replace
            // a requested physical Wide/Ultra-Wide constituent with a virtual rear
            // device that cannot coexist with the desired External USB camera.
            // The recovery pair is immutable request metadata, not a second source
            // of capture state.
            if let recoveryPairedOCRDeviceID {
                guard let pairedOCR = devices.first(where: { $0.uniqueID == recoveryPairedOCRDeviceID }) else {
                    trace("Recovery AB fallback pair unavailable; preserving exact Broadcast request live=\(requested.localizedName){\(requested.uniqueID)} desiredOCR={\(recoveryPairedOCRDeviceID)}")
                    return requested
                }

                var candidates: [AVCaptureDevice] = [requested]
                if requested.position == .back, requested.deviceType != .external {
                    let orderedTypes: [AVCaptureDevice.DeviceType] = [
                        .builtInWideAngleCamera,
                        .builtInUltraWideCamera,
                        .builtInDualWideCamera,
                        .builtInTripleCamera,
                        .builtInDualCamera
                    ]
                    for type in orderedTypes {
                        for device in devices where device.position == .back && device.deviceType == type {
                            if !candidates.contains(where: { $0.uniqueID == device.uniqueID }) {
                                candidates.append(device)
                            }
                        }
                    }
                }

                if let compatible = candidates.first(where: { candidate in
                    discovery.supportedMultiCamDeviceSets.contains { set in
                        set.contains(where: { $0.uniqueID == candidate.uniqueID })
                            && set.contains(where: { $0.uniqueID == pairedOCR.uniqueID })
                    }
                }) {
                    trace("Recovery AB pair-compatible Broadcast fallback selected live=\(compatible.localizedName){\(compatible.uniqueID)} desiredOCR=\(pairedOCR.localizedName){\(pairedOCR.uniqueID)} exact=\(compatible.uniqueID == requested.uniqueID)")
                    return compatible
                }

                trace("Recovery AB found no currently pair-compatible rear fallback; preserving exact Broadcast request live=\(requested.localizedName){\(requested.uniqueID)} desiredOCR=\(pairedOCR.localizedName){\(pairedOCR.uniqueID)}")
                return requested
            }

            // Recovery DC convergence rollback: preserve the exact physical rear
            // request. The b115/b773-era Wide->virtual substitution made a healthy
            // physical Wide+USB pair degrade to Broadcast-only because Back Dual
            // Wide is not a supported pair with the selected external OCR camera.
            // Zoom range is owned by the explicit Wide<->Ultra-Wide transaction,
            // not by swapping the requested source for a virtual rear device.
            return requested
        }
        if let wide = devices.first(where: { $0.position == .back && $0.deviceType == .builtInWideAngleCamera }) {
            return wide
        }
        if let back = devices.first(where: { $0.position == .back && $0.deviceType != .external }) {
            return back
        }
        if let anyBuiltIn = devices.first(where: { $0.deviceType != .external }) {
            return anyBuiltIn
        }
        throw MultiCamError.liveCameraUnavailable
    }

    private func resolveOCRDevice(requestedDeviceID: String?) throws -> AVCaptureDevice {
        let devices = discoveredVideoDevices()
        if let requestedDeviceID {
            guard let requested = devices.first(where: { $0.uniqueID == requestedDeviceID }) else {
                throw MultiCamError.requestedDeviceUnavailable("OCR", requestedDeviceID)
            }
            return requested
        }
        if let external = devices.first(where: { $0.deviceType == .external }) {
            return external
        }
        if let front = devices.first(where: { $0.position == .front }) {
            return front
        }
        if let any = devices.first {
            return any
        }
        throw MultiCamError.externalCameraUnavailable
    }

    private func resolveSupportedPair(liveRequestedDeviceID: String?, ocrRequestedDeviceID: String?) throws -> (live: AVCaptureDevice, ocr: AVCaptureDevice) {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            throw MultiCamError.notSupported
        }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: Self.videoDeviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        let devices = discovery.devices
        guard !devices.isEmpty else { throw MultiCamError.liveCameraUnavailable }

        let requestedLive: AVCaptureDevice? = try liveRequestedDeviceID.map { id in
            guard let device = devices.first(where: { $0.uniqueID == id }) else {
                throw MultiCamError.requestedDeviceUnavailable("Broadcast", id)
            }
            return device
        }
        let requestedOCR: AVCaptureDevice? = try ocrRequestedDeviceID.map { id in
            guard let device = devices.first(where: { $0.uniqueID == id }) else {
                throw MultiCamError.requestedDeviceUnavailable("OCR", id)
            }
            return device
        }

        func appendUnique(_ device: AVCaptureDevice?, to values: inout [AVCaptureDevice]) {
            guard let device, !values.contains(where: { $0.uniqueID == device.uniqueID }) else { return }
            values.append(device)
        }

        /// A logical Back/Front/External selection may resolve to a different
        /// constituent device when Apple does not permit the virtual device in a
        /// simultaneous set. Candidates must remain in the same logical source;
        /// CaptureEngine never silently swaps Front for Back or External for built-in.
        func logicalEquivalents(of requested: AVCaptureDevice?, role: RinkLensCapturePreviewRole) -> [AVCaptureDevice] {
            var values: [AVCaptureDevice] = []

            if let requested, requested.position == .back, requested.deviceType != .external {
                // Recovery DC: CaptureLifecycleController chooses the pair-compatible
                // physical optical domain before graph configuration. CaptureEngine
                // must therefore preserve that device class rather than silently
                // changing Wide<->Ultra-Wide or substituting a virtual rear camera.
                appendUnique(requested, to: &values)
                for device in devices where device.position == .back
                    && device.deviceType == requested.deviceType {
                    appendUnique(device, to: &values)
                }
            } else {
                appendUnique(requested, to: &values)
            }

            if let requested {
                if requested.deviceType == .external {
                    for device in devices where device.deviceType == .external { appendUnique(device, to: &values) }
                } else if requested.position == .back {
                    for device in devices where device.position == .back && device.deviceType != .external {
                        appendUnique(device, to: &values)
                    }
                } else if requested.position == .front {
                    for device in devices where device.position == .front && device.deviceType != .external {
                        appendUnique(device, to: &values)
                    }
                }
                return values
            }

            switch role {
            case .broadcast:
                for device in devices where device.position == .back && device.deviceType == .builtInWideAngleCamera {
                    appendUnique(device, to: &values)
                }
                for device in devices where device.position == .back && device.deviceType != .external {
                    appendUnique(device, to: &values)
                }
                for device in devices where device.deviceType != .external { appendUnique(device, to: &values) }
            case .ocr:
                for device in devices where device.deviceType == .external { appendUnique(device, to: &values) }
                for device in devices where device.position == .front && device.deviceType != .external {
                    appendUnique(device, to: &values)
                }
                for device in devices { appendUnique(device, to: &values) }
            }
            return values
        }

        let liveCandidates = logicalEquivalents(of: requestedLive, role: .broadcast)
        let ocrCandidates = logicalEquivalents(of: requestedOCR, role: .ocr)

        for live in liveCandidates {
            for ocr in ocrCandidates where ocr.uniqueID != live.uniqueID {
                let supported = discovery.supportedMultiCamDeviceSets.contains { set in
                    set.contains(where: { $0.uniqueID == live.uniqueID })
                        && set.contains(where: { $0.uniqueID == ocr.uniqueID })
                }
                guard supported else { continue }
                publishSnapshot { snapshot in
                    snapshot.devicePairText = "Broadcast \(live.localizedName) + OCR \(ocr.localizedName)"
                }
                let exact = live.uniqueID == liveRequestedDeviceID && ocr.uniqueID == ocrRequestedDeviceID
                trace("supported pair selected exact=\(exact) live=\(live.localizedName){\(live.uniqueID)} ocr=\(ocr.localizedName){\(ocr.uniqueID)}")
                return (live, ocr)
            }
        }

        let setText = discovery.supportedMultiCamDeviceSets.map { set in
            set.map { "\($0.localizedName){\($0.uniqueID)}" }.sorted().joined(separator: " + ")
        }.joined(separator: " | ")
        trace("requested logical pair unsupported requestedLive=\(liveRequestedDeviceID ?? "none") requestedOCR=\(ocrRequestedDeviceID ?? "none") supportedSets=\(setText)")
        throw MultiCamError.devicePairUnsupported(setText)
    }

    private func configureGraph(
        mode: RinkLensCaptureLifecycleMode,
        liveLogicalSourceID: String?,
        ocrLogicalSourceID: String?,
        livePreferredDeviceID: String?,
        ocrPreferredDeviceID: String?,
        liveDevice: AVCaptureDevice?,
        ocrDevice: AVCaptureDevice?,
        liveFormatPreference: RinkLensCaptureFormatPreference?,
        ocrFormatPreference: RinkLensCaptureFormatPreference?
    ) throws {
        assertSessionQueue()
        guard mode != .stopped else { throw MultiCamError.emptyGraph }
        if mode.requiresBroadcast && liveDevice == nil { throw MultiCamError.liveCameraUnavailable }
        if mode.requiresOCR && ocrDevice == nil { throw MultiCamError.externalCameraUnavailable }

        publishSnapshot(phase: .configuring) { snapshot in
            snapshot.captureModeText = mode.rawValue
            snapshot.statusText = "Configuring capture graph"
        }
        if session.isRunning { session.stopRunning() }

        var newLiveInput: AVCaptureDeviceInput?
        var newOCRInput: AVCaptureDeviceInput?
        var newLivePort: AVCaptureInput.Port?
        var newOCRPort: AVCaptureInput.Port?
        var newLiveOutputConnection: AVCaptureConnection?
        var newOCROutputConnection: AVCaptureConnection?
        var liveOverrideCadence = RinkLensCaptureCadence(integerFPS: 30)
        var ocrOverrideCadence = RinkLensCaptureCadence(integerFPS: 15)

        if let liveDevice {
            liveOverrideCadence = try applyConservativeMultiCamFormat(
                to: liveDevice,
                preference: liveFormatPreference,
                fallbackWidth: 1920,
                fallbackHeight: 1080,
                fallbackFPS: 30,
                requireExactFallbackDimensions: true
            )
            try applyRequestedBroadcastFramingBeforeGraphStart(
                to: liveDevice,
                logicalZoom: broadcastHardwareTargetLogicalZoomLocked,
                reason: "stable rear input graph configuration from applied hardware projection"
            )
            let input = try AVCaptureDeviceInput(device: liveDevice)
            input.videoMinFrameDurationOverride = liveOverrideCadence.duration
            newLiveInput = input
        }

        if let ocrDevice {
            ocrOverrideCadence = try applyConservativeMultiCamFormat(
                to: ocrDevice,
                preference: ocrFormatPreference,
                fallbackWidth: 1920,
                fallbackHeight: 1080,
                fallbackFPS: 30,
                requireExactFallbackDimensions: true
            )
            // FrameHub owns the one bounded OCR pixel copy made synchronously at
            // the AVFoundation callback boundary. Prepare and page-touch that
            // existing six-surface pool on the session queue before callbacks
            // can begin; lazy preparation on the first live frame previously
            // blocked the capture callback for 1.458 seconds.
            let dimensions = CMVideoFormatDescriptionGetDimensions(
                ocrDevice.activeFormat.formatDescription
            )
            if let preparation = RinkLensFrameHub.shared.prepareOwnedPool(
                for: .ocr,
                width: Int(dimensions.width),
                height: Int(dimensions.height),
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ) {
                trace("OCR FrameHub pool prepared before graph start \(preparation.diagnosticText)")
                RinkLensStructuredEventLogger.shared.record(
                    domain: .capture,
                    event: "capture_ocr_framehub_pool_prepared",
                    entityID: ocrDevice.uniqueID,
                    next: [
                        "width": String(dimensions.width),
                        "height": String(dimensions.height),
                        "pixelFormat": String(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
                        "preparedBuffers": String(preparation.preparedBufferCount),
                        "elapsedMilliseconds": String(format: "%.3f", preparation.elapsedMilliseconds),
                        "rebuilt": String(preparation.rebuilt)
                    ],
                    source: "CaptureEngine.configureGraph",
                    reason: "Prepare bounded OCR ownership before real-time capture callbacks"
                )
            }
            let input = try AVCaptureDeviceInput(device: ocrDevice)
            input.videoMinFrameDurationOverride = ocrOverrideCadence.duration
            newOCRInput = input
        }

        session.beginConfiguration()
        teardownGraph(withinConfiguration: true)
        var committed = false
        defer {
            if !committed { session.commitConfiguration() }
        }

        if let input = newLiveInput {
            guard session.canAddInput(input) else { throw MultiCamError.cannotAddLiveInput }
            session.addInputWithNoConnections(input)
            guard let port = input.ports.first(where: { $0.mediaType == .video }) else {
                throw MultiCamError.liveVideoPortMissing
            }
            newLivePort = port
            guard session.canAddOutput(liveOutput) else { throw MultiCamError.cannotAddLiveOutput }
            session.addOutputWithNoConnections(liveOutput)
            let connection = AVCaptureConnection(inputPorts: [port], output: liveOutput)
            guard session.canAddConnection(connection) else { throw MultiCamError.cannotConnectLiveOutput }
            session.addConnection(connection)
            applyDataConnectionSettings(connection, role: .broadcast, mirrored: false)
            newLiveOutputConnection = connection
        }

        if let input = newOCRInput {
            guard session.canAddInput(input) else { throw MultiCamError.cannotAddOCRInput }
            session.addInputWithNoConnections(input)
            guard let port = input.ports.first(where: { $0.mediaType == .video }) else {
                throw MultiCamError.ocrVideoPortMissing
            }
            newOCRPort = port
            guard session.canAddOutput(ocrOutput) else { throw MultiCamError.cannotAddOCROutput }
            session.addOutputWithNoConnections(ocrOutput)
            let connection = AVCaptureConnection(inputPorts: [port], output: ocrOutput)
            guard session.canAddConnection(connection) else { throw MultiCamError.cannotConnectOCROutput }
            session.addConnection(connection)
            applyDataConnectionSettings(connection, role: .ocr, mirrored: false)
            newOCROutputConnection = connection
        }

        reconnectRetainedPreviewIfPossible(role: .broadcast, port: newLivePort)
        reconnectRetainedPreviewIfPossible(role: .ocr, port: newOCRPort)

        guard !session.inputs.isEmpty, !session.outputs.isEmpty else {
            throw MultiCamError.emptyGraph
        }

        let hardwareCost = Double(session.hardwareCost)
        guard hardwareCost < 1.0 else { throw MultiCamError.hardwareCostExceeded(hardwareCost) }
        let pressureCost = Double(session.systemPressureCost)
        guard pressureCost < 1.0 else { throw MultiCamError.systemPressureCostTooHigh(pressureCost) }

        liveInput = newLiveInput
        ocrInput = newOCRInput
        liveVideoPort = newLivePort
        ocrVideoPort = newOCRPort
        liveOutputConnection = newLiveOutputConnection
        ocrOutputConnection = newOCROutputConnection
        stateLock.lock()
        let pressureSuspended = ocrPressureSuspendedLocked
        stateLock.unlock()
        ocrOutputConnection?.isEnabled = !pressureSuspended
        refreshOutputConnectionTruthOnSessionQueue(reason: "graph configured")

        stateLock.lock()
        activeGraphModeLocked = mode
        configuredLiveCadenceLocked = liveDevice == nil ? nil : liveOverrideCadence
        configuredOCRCadenceLocked = ocrDevice == nil ? nil : ocrOverrideCadence
        liveConfiguredCadenceTextLocked = liveDevice == nil ? "not configured" : "requested \(liveOverrideCadence.displayText)fps; awaiting post-start verification"
        ocrConfiguredCadenceTextLocked = ocrDevice == nil ? "not configured" : "requested \(ocrOverrideCadence.displayText)fps; awaiting post-start verification"
        activeLiveDeviceID = liveDevice?.uniqueID
        activeOCRDeviceID = ocrDevice?.uniqueID
        activeLiveDeviceNameLocked = liveDevice?.localizedName ?? "none"
        activeLiveDevicePositionTextLocked = Self.positionText(liveDevice?.position)
        activeLiveDeviceTypeTextLocked = liveDevice?.deviceType.rawValue ?? "unavailable"
        activeOCRDeviceNameLocked = ocrDevice?.localizedName ?? "none"
        activeOCRDevicePositionTextLocked = Self.positionText(ocrDevice?.position)
        activeOCRDeviceTypeTextLocked = ocrDevice?.deviceType.rawValue ?? "unavailable"
        liveFirstFrameLumaTextLocked = liveDevice == nil ? "Broadcast branch not configured" : "awaiting Broadcast frame for generation \(transitionGeneration)"
        ocrFirstFrameLumaTextLocked = ocrDevice == nil ? "OCR branch not configured" : "awaiting OCR frame for generation \(transitionGeneration)"
        activeLiveFormatPreference = liveFormatPreference
        activeOCRFormatPreference = ocrFormatPreference
        liveFramesLocked = 0
        ocrFramesLocked = 0
        liveObservedFPSLocked = 0
        ocrObservedFPSLocked = 0
        liveLastCallbackUptimeNanosecondsLocked = nil
        ocrLastCallbackUptimeNanosecondsLocked = nil
        liveOutputConnectionTextLocked = "Broadcast output not configured"
        ocrOutputConnectionTextLocked = "OCR output not configured"
        liveObservedFrameUptimesLocked.removeAll(keepingCapacity: true)
        ocrObservedFrameUptimesLocked.removeAll(keepingCapacity: true)
        if let liveDevice, !session.isRunning {
            let dimensions = CMVideoFormatDescriptionGetDimensions(liveDevice.activeFormat.formatDescription)
            let resolved = RinkLensCaptureFormatPreference(
                width: dimensions.width,
                height: dimensions.height,
                cadence: RinkLensCaptureCadence(duration: liveDevice.activeVideoMinFrameDuration)
            )
            activeLiveResolvedFormat = resolved
            liveFormatTextLocked = "CaptureEngine Broadcast source \(resolved.diagnosticText) native"
        } else {
            activeLiveResolvedFormat = nil
            liveFormatTextLocked = "Broadcast branch not configured"
        }
        if let ocrDevice {
            let dimensions = CMVideoFormatDescriptionGetDimensions(ocrDevice.activeFormat.formatDescription)
            let resolved = RinkLensCaptureFormatPreference(
                width: dimensions.width,
                height: dimensions.height,
                cadence: RinkLensCaptureCadence(duration: ocrDevice.activeVideoMinFrameDuration)
            )
            activeOCRResolvedFormat = resolved
            ocrFormatTextLocked = "CaptureEngine OCR source \(resolved.diagnosticText) native"
        } else {
            activeOCRResolvedFormat = nil
            ocrFormatTextLocked = "OCR branch not configured"
        }
        let desiredContract = RinkLensDesiredCaptureContract(
            mode: mode,
            liveLogicalSourceID: mode.requiresBroadcast ? liveLogicalSourceID : nil,
            ocrLogicalSourceID: mode.requiresOCR ? ocrLogicalSourceID : nil,
            livePreferredDeviceID: mode.requiresBroadcast ? livePreferredDeviceID : nil,
            ocrPreferredDeviceID: mode.requiresOCR ? ocrPreferredDeviceID : nil,
            liveFormat: mode.requiresBroadcast ? liveFormatPreference : nil,
            ocrFormat: mode.requiresOCR ? ocrFormatPreference : nil
        )
        activeEffectiveContract = RinkLensEffectiveCaptureContract(
            desired: desiredContract,
            liveActiveDeviceID: mode.requiresBroadcast ? liveDevice?.uniqueID : nil,
            ocrActiveDeviceID: mode.requiresOCR ? ocrDevice?.uniqueID : nil,
            liveFormat: mode.requiresBroadcast ? activeLiveResolvedFormat : nil,
            ocrFormat: mode.requiresOCR ? activeOCRResolvedFormat : nil
        )
        stateLock.unlock()

        // Recovery AV: Broadcast callbacks are metadata-only in FrameHub; no
        // producer pixel pool is prewarmed because recording owns the sole
        // Broadcast full-frame copy. OCR retains its pixel FrameHub as a real
        // Image Relay/OCR consumer boundary.

        configured = true
        session.commitConfiguration()
        committed = true
        installSystemPressureObserversOnSessionQueue(liveDevice: liveDevice, ocrDevice: ocrDevice)

        let graph = graphDescription()
        publishSnapshot(phase: .configuring) { snapshot in
            snapshot.captureModeText = mode.rawValue
            snapshot.devicePairText = self.deviceDescription(mode: mode, live: liveDevice, ocr: ocrDevice)
            snapshot.graphText = graph
            snapshot.liveFramesReceived = 0
            snapshot.ocrFramesReceived = 0
        }
        trace("graph configured mode=\(mode.rawValue) \(graph)")
    }

    private func deviceDescription(
        mode: RinkLensCaptureLifecycleMode,
        live: AVCaptureDevice?,
        ocr: AVCaptureDevice?
    ) -> String {
        switch mode {
        case .dualCamera:
            return "Broadcast \(live?.localizedName ?? "none") + OCR \(ocr?.localizedName ?? "none")"
        case .broadcastOnly:
            return "Broadcast \(live?.localizedName ?? "none")"
        case .ocrOnly:
            return "OCR \(ocr?.localizedName ?? "none")"
        case .stopped:
            return "No capture devices"
        }
    }

    private func preferredBroadcastStabilisationMode(for device: AVCaptureDevice?) -> AVCaptureVideoStabilizationMode {
        guard let device else { return .auto }
        let format = device.activeFormat
        if format.isVideoStabilizationModeSupported(.lowLatency) { return .lowLatency }
        if format.isVideoStabilizationModeSupported(.standard) { return .standard }
        return .auto
    }

    private func applyDataConnectionSettings(
        _ connection: AVCaptureConnection,
        role: RinkLensFrameRole,
        mirrored: Bool
    ) {
        if !connection.isEnabled { connection.isEnabled = true }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
        guard connection.isVideoStabilizationSupported else { return }

        if RinkLensRiskFeaturePolicy.isEnabled(.broadcastVideoStabilisationAuthorityV13) {
            if role == .broadcast {
                stateLock.lock()
                let enabled = broadcastVideoStabilisationEnabledLocked
                stateLock.unlock()
                connection.preferredVideoStabilizationMode = enabled
                    ? preferredBroadcastStabilisationMode(for: liveInput?.device)
                    : .off
            } else {
                // OCR zone geometry must not move when the operator changes the
                // Broadcast image stabilisation policy.
                connection.preferredVideoStabilizationMode = .off
            }
        } else {
            // Build 725 rollback behaviour.
            connection.preferredVideoStabilizationMode = .auto
        }
    }

    func setBroadcastVideoStabilisation(enabled: Bool, reason: String) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.assertSessionQueue()
            self.stateLock.lock()
            let previousRequested = self.broadcastVideoStabilisationEnabledLocked
            self.broadcastVideoStabilisationEnabledLocked = enabled
            self.stateLock.unlock()

            let connection = self.liveOutputConnection
            let supported = connection?.isVideoStabilizationSupported == true
            let previousApplied = connection.map { String($0.activeVideoStabilizationMode.rawValue) } ?? "unavailable"
            if supported, let connection {
                connection.preferredVideoStabilizationMode = enabled
                    ? self.preferredBroadcastStabilisationMode(for: self.liveInput?.device)
                    : .off
            }
            let nextApplied = connection.map { String($0.activeVideoStabilizationMode.rawValue) } ?? "unavailable"
            self.refreshOutputConnectionTruthOnSessionQueue(reason: "Broadcast stabilisation changed")
            RinkLensStructuredEventLogger.shared.record(
                domain: .cameraControl,
                event: "camera_broadcast_stabilisation_applied",
                entityID: "broadcast-connection",
                previous: [
                    "requested": String(previousRequested),
                    "appliedMode": previousApplied
                ],
                next: [
                    "requested": String(enabled),
                    "supported": String(supported),
                    "appliedMode": nextApplied
                ],
                source: "ExternalOCRMultiCamCoordinator",
                reason: reason
            )
            self.trace("Broadcast video stabilisation requested=\(enabled) supported=\(supported) applied=\(nextApplied) reason=\(reason)")
            self.publishSnapshot { _ in }
        }
    }

    // Applied Broadcast focus, exposure, white balance and torch mutations are
    // owned exclusively by HockeyCameraService. CaptureEngine supplies the active
    // device through setExternallyManagedCaptureActive and does not mutate those
    // hardware controls directly.

    /// Selects and applies a format that AVFoundation explicitly marks as safe for
    /// MultiCam. The prior implementation filtered only by dimensions/FPS and could
    /// leave an inherited, unsupported active format in place when no candidate matched.
    /// Returns the maximum promised input cadence used by videoMinFrameDurationOverride.
    private func applyConservativeMultiCamFormat(
        to device: AVCaptureDevice,
        preference: RinkLensCaptureFormatPreference?,
        fallbackWidth: Int32,
        fallbackHeight: Int32,
        fallbackFPS: Double,
        requireExactFallbackDimensions: Bool = false
    ) throws -> RinkLensCaptureCadence {
        assertSessionQueue()
        struct Candidate {
            let format: AVCaptureDevice.Format
            let width: Int32
            let height: Int32
            let area: Int64
            let maxFPS: Double
            let isBinned: Bool
        }

        let eligible: [Candidate] = device.formats.compactMap { format in
            guard format.isMultiCamSupported else { return nil }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let maxFPS = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            guard dimensions.width > 0, dimensions.height > 0, maxFPS >= 1 else { return nil }
            return Candidate(
                format: format,
                width: dimensions.width,
                height: dimensions.height,
                area: Int64(dimensions.width) * Int64(dimensions.height),
                maxFPS: maxFPS,
                isBinned: format.isVideoBinned
            )
        }
        guard !eligible.isEmpty else {
            throw MultiCamError.noSupportedMultiCamFormat(device.localizedName)
        }

        let selected: Candidate
        let targetCadence: RinkLensCaptureCadence
        if let preference {
            let targetFPS = preference.cadence.framesPerSecond
            let exact = eligible.filter { candidate in
                candidate.width == preference.width
                    && candidate.height == preference.height
                    && candidate.format.videoSupportedFrameRateRanges.contains(where: {
                        $0.minFrameRate <= targetFPS + 0.005
                            && $0.maxFrameRate >= targetFPS - 0.005
                    })
            }
            guard let candidate = exact.sorted(by: {
                if $0.isBinned != $1.isBinned { return !$0.isBinned && $1.isBinned }
                return $0.maxFPS < $1.maxFPS
            }).first else {
                throw MultiCamError.requestedFormatUnavailable(device.localizedName, preference.diagnosticText)
            }
            selected = candidate
            targetCadence = preference.cadence
        } else {
            // UX16d2g2: automatic capture is an explicit 16:9 Full-HD contract,
            // not a request to silently select the largest format below a loose
            // ceiling. The old OCR fallback was hard-coded to 1280x720 @ 15fps,
            // so a saved "automatic" OCR profile could never reach the intended
            // 1920x1080 landscape source even when the USB camera supported it.
            let exactFallback = eligible.filter {
                $0.width == fallbackWidth && $0.height == fallbackHeight
            }
            if requireExactFallbackDimensions && exactFallback.isEmpty {
                throw MultiCamError.requestedFormatUnavailable(
                    device.localizedName,
                    "\(fallbackWidth)x\(fallbackHeight) @ \(RinkLensCaptureCadence(frameRate: fallbackFPS).displayText)fps automatic Full-HD contract"
                )
            }

            let bounded = eligible.filter { $0.width <= fallbackWidth && $0.height <= fallbackHeight }
            let pool = !exactFallback.isEmpty ? exactFallback : (bounded.isEmpty ? eligible : bounded)
            if exactFallback.isEmpty && bounded.isEmpty {
                selected = pool.min {
                    if $0.area != $1.area { return $0.area < $1.area }
                    // Non-binned must sort before binned for min(by:).
                    if $0.isBinned != $1.isBinned { return !$0.isBinned && $1.isBinned }
                    return $0.maxFPS < $1.maxFPS
                }!
            } else {
                selected = pool.max {
                    // max(by:) treats lhs < rhs when this returns true. The former
                    // comparator accidentally ranked binned as greater, exactly as
                    // recorded in the Build 703 log. Rank binned below non-binned.
                    if $0.isBinned != $1.isBinned { return $0.isBinned && !$1.isBinned }
                    if $0.area != $1.area { return $0.area < $1.area }
                    return $0.maxFPS < $1.maxFPS
                }!
            }
            let ranges = selected.format.videoSupportedFrameRateRanges
            if ranges.contains(where: { $0.minFrameRate <= fallbackFPS && $0.maxFrameRate >= fallbackFPS }) {
                targetCadence = RinkLensCaptureCadence(frameRate: fallbackFPS)
            } else if let nearest = ranges.flatMap({ range in
                [
                    RinkLensCaptureCadence(duration: range.maxFrameDuration),
                    RinkLensCaptureCadence(duration: range.minFrameDuration)
                ]
            }).min(by: {
                abs($0.framesPerSecond - fallbackFPS) < abs($1.framesPerSecond - fallbackFPS)
            }) {
                targetCadence = nearest
            } else {
                targetCadence = RinkLensCaptureCadence(frameRate: max(1, selected.maxFPS))
            }
        }

        let activeFPS = targetCadence.framesPerSecond
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.activeFormat = selected.format
            guard selected.format.videoSupportedFrameRateRanges.contains(where: {
                $0.minFrameRate <= activeFPS + 0.005 && $0.maxFrameRate >= activeFPS - 0.005
            }) else {
                throw MultiCamError.requestedFormatUnavailable(
                    device.localizedName,
                    "\(selected.width)x\(selected.height) @ \(targetCadence.displayText)fps"
                )
            }
            device.activeVideoMinFrameDuration = targetCadence.duration
            device.activeVideoMaxFrameDuration = targetCadence.duration
        } catch let error as MultiCamError {
            throw error
        } catch {
            throw MultiCamError.formatConfigurationFailed(
                "\(device.localizedName): \(error.localizedDescription)"
            )
        }

        trace(
            "verified MultiCam format applied device=\(device.localizedName) "
            + "format=\(selected.width)x\(selected.height) activeFPS=\(targetCadence.displayText) "
            + "duration=\(targetCadence.durationValue)/\(targetCadence.durationTimescale) binned=\(selected.isBinned) "
            + "requested=\(preference?.diagnosticText ?? "auto")"
        )
        return targetCadence
    }

    /// Recovery AW / RL-110: both configured CaptureEngine cadences are
    /// authoritative at the hardware/input boundary. MultiCam may alter active
    /// durations while committing or starting, so each branch is re-applied once
    /// after start from the already-resolved effective graph contract, then read
    /// back. This cannot invent a cadence: 0.5x/quality-mode contracts carry their
    /// own 30fps request, while Motion/Balanced carry the verified 60fps request.
    private func enforceConfiguredCadencesOnSessionQueue(reason: String) {
        assertSessionQueue()

        func apply(
            role: String,
            device: AVCaptureDevice?,
            input: AVCaptureDeviceInput?,
            requested: RinkLensCaptureCadence?,
            enforce: Bool
        ) -> (text: String, resolved: RinkLensCaptureFormatPreference?) {
            guard let device, let input, let requested else {
                return ("not configured", nil)
            }
            if enforce {
                do {
                    try device.lockForConfiguration()
                    if role == "Broadcast" {
                        let policy = appliedBroadcastImageQualityPolicyLocked
                        let autoSupported = deviceSupportsAutomaticFrameRate(device)
                        let autoRequested = policy.allowsAutomaticFrameRate && autoSupported
                        if autoSupported { setDeviceAutomaticFrameRate(false, on: device) }
                        if autoRequested {
                            device.activeVideoMinFrameDuration = .invalid
                            device.activeVideoMaxFrameDuration = .invalid
                        } else {
                            device.activeVideoMinFrameDuration = requested.duration
                            device.activeVideoMaxFrameDuration = requested.duration
                        }
                        if device.isLowLightBoostSupported {
                            device.automaticallyEnablesLowLightBoostWhenAvailable = policy.requestsAutomaticLowLightBoost
                        }
                        if autoRequested { setDeviceAutomaticFrameRate(true, on: device) }
                        device.unlockForConfiguration()
                        input.videoMinFrameDurationOverride = autoRequested ? .invalid : requested.duration
                    } else {
                        device.activeVideoMinFrameDuration = requested.duration
                        device.activeVideoMaxFrameDuration = requested.duration
                        device.unlockForConfiguration()
                        input.videoMinFrameDurationOverride = requested.duration
                    }
                } catch {
                    let text = "requested \(requested.displayText)fps; apply failed: \(error.localizedDescription)"
                    trace("UX16d2a cadence apply failed role=\(role) \(text) reason=\(reason)")
                    return (text, nil)
                }
            }

            let appliedDevice = RinkLensCaptureCadence(duration: device.activeVideoMinFrameDuration)
            let appliedOverride = RinkLensCaptureCadence(duration: input.videoMinFrameDurationOverride)
            let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            let authority = enforce ? "enforced" : "verified-only"
            let text = "graphRequested \(requested.displayText)fps; device \(appliedDevice.displayText)fps; inputOverride \(appliedOverride.displayText)fps; authority=\(authority)"
            trace("UX16d2a cadence verified role=\(role) \(text) reason=\(reason)")
            return (
                text,
                RinkLensCaptureFormatPreference(
                    width: dimensions.width,
                    height: dimensions.height,
                    cadence: appliedDevice
                )
            )
        }

        stateLock.lock()
        let liveRequested = configuredLiveCadenceLocked
        let ocrRequested = configuredOCRCadenceLocked
        stateLock.unlock()

        let live = apply(
            role: "Broadcast",
            device: liveInput?.device,
            input: liveInput,
            requested: liveRequested,
            enforce: true
        )
        let ocr = apply(
            role: "OCR",
            device: ocrInput?.device,
            input: ocrInput,
            requested: ocrRequested,
            enforce: true
        )

        stateLock.lock()
        liveConfiguredCadenceTextLocked = live.text
        ocrConfiguredCadenceTextLocked = ocr.text
        if let resolved = live.resolved {
            activeLiveResolvedFormat = resolved
            liveFormatTextLocked = "CaptureEngine Broadcast source \(resolved.diagnosticText) post-start verified"
        }
        if let resolved = ocr.resolved {
            activeOCRResolvedFormat = resolved
            ocrFormatTextLocked = "CaptureEngine OCR source \(resolved.diagnosticText) post-start verified"
        }
        if let desired = activeEffectiveContract?.desired {
            activeEffectiveContract = RinkLensEffectiveCaptureContract(
                desired: desired,
                liveActiveDeviceID: activeLiveDeviceID,
                ocrActiveDeviceID: activeOCRDeviceID,
                liveFormat: activeLiveResolvedFormat,
                ocrFormat: activeOCRResolvedFormat
            )
        }
        stateLock.unlock()
    }

    private enum PressureRole: String {
        case broadcast
        case ocr
    }

    private func installSystemPressureObserversOnSessionQueue(
        liveDevice: AVCaptureDevice?,
        ocrDevice: AVCaptureDevice?
    ) {
        assertSessionQueue()
        invalidateSystemPressureObserversOnSessionQueue()

        if let liveDevice {
            updateSystemPressureOnSessionQueue(role: .broadcast, state: liveDevice.systemPressureState)
            livePressureObservation = liveDevice.observe(\.systemPressureState, options: [.new]) { [weak self] device, _ in
                let level = Self.systemPressureLevelText(device.systemPressureState.level)
                let factors = String(describing: device.systemPressureState.factors)
                self?.sessionQueue.async { [weak self] in
                    self?.updateSystemPressureOnSessionQueue(role: .broadcast, level: level, factors: factors)
                }
            }
        }

        if let ocrDevice {
            updateSystemPressureOnSessionQueue(role: .ocr, state: ocrDevice.systemPressureState)
            ocrPressureObservation = ocrDevice.observe(\.systemPressureState, options: [.new]) { [weak self] device, _ in
                let level = Self.systemPressureLevelText(device.systemPressureState.level)
                let factors = String(describing: device.systemPressureState.factors)
                self?.sessionQueue.async { [weak self] in
                    self?.updateSystemPressureOnSessionQueue(role: .ocr, level: level, factors: factors)
                }
            }
        }
    }

    private func invalidateSystemPressureObserversOnSessionQueue() {
        assertSessionQueue()
        livePressureObservation?.invalidate()
        ocrPressureObservation?.invalidate()
        livePressureObservation = nil
        ocrPressureObservation = nil
        stateLock.lock()
        liveSystemPressureLevelLocked = "unavailable"
        liveSystemPressureFactorsLocked = "none"
        ocrSystemPressureLevelLocked = "unavailable"
        ocrSystemPressureFactorsLocked = "none"
        ocrPressurePolicyLevelLocked = .normal
        ocrPressurePolicyStateLocked = "normal"
        ocrPressureDeliveryIntervalNanosecondsLocked = 0
        ocrPressureDeliveryFPSLocked = 0
        ocrPressureSuspendedLocked = false
        broadcastPreservationActiveLocked = false
        pressurePolicyGenerationLocked &+= 1
        stateLock.unlock()
    }

    private func updateSystemPressureOnSessionQueue(
        role: PressureRole,
        state: AVCaptureDevice.SystemPressureState
    ) {
        updateSystemPressureOnSessionQueue(
            role: role,
            level: Self.systemPressureLevelText(state.level),
            factors: String(describing: state.factors)
        )
    }

    private func updateSystemPressureOnSessionQueue(
        role: PressureRole,
        level: String,
        factors: String
    ) {
        assertSessionQueue()
        stateLock.lock()
        switch role {
        case .broadcast:
            liveSystemPressureLevelLocked = level
            liveSystemPressureFactorsLocked = factors
        case .ocr:
            ocrSystemPressureLevelLocked = level
            ocrSystemPressureFactorsLocked = factors
        }
        stateLock.unlock()
        trace("system pressure role=\(role.rawValue) level=\(level) factors=\(factors)")
        // The policy evaluation below emits the effective state once. Avoid a
        // separate raw-observation revision/publication immediately beforehand.
        evaluateOCRPressurePolicyOnSessionQueue()
    }

    private func evaluateOCRPressurePolicyOnSessionQueue() {
        assertSessionQueue()
        stateLock.lock()
        let liveLevel = liveSystemPressureLevelLocked
        let ocrLevel = ocrSystemPressureLevelLocked
        let current = ocrPressurePolicyLevelLocked
        let mode = activeGraphModeLocked
        pressurePolicyGenerationLocked &+= 1
        let generation = pressurePolicyGenerationLocked
        stateLock.unlock()

        let worst = max(Self.pressureRank(liveLevel), Self.pressureRank(ocrLevel))
        guard mode.requiresOCR else {
            stateLock.lock()
            ocrPressurePolicyLevelLocked = .normal
            ocrPressureDeliveryIntervalNanosecondsLocked = 0
            ocrPressureDeliveryFPSLocked = 0
            ocrPressureSuspendedLocked = false
            broadcastPreservationActiveLocked = mode.requiresBroadcast && worst >= 2
            ocrPressurePolicyStateLocked = worst >= 2
                ? "Broadcast-only pressure — no automatic Broadcast quality reduction"
                : "normal — no OCR branch active"
            stateLock.unlock()
            trace("pressure policy mode=\(mode.rawValue): Broadcast format/cadence unchanged")
            publishSnapshot { snapshot in
                if worst >= 2 {
                    snapshot.statusText = "Broadcast pressure detected; quality preserved"
                } else if snapshot.statusText.localizedCaseInsensitiveContains("pressure") {
                    snapshot.statusText = snapshot.isActive ? "Capture running" : snapshot.statusText
                }
            }
            return
        }

        let desired: OCRPressurePolicyLevel
        switch worst {
        case 4...: desired = .suspended
        case 3: desired = .limited5FPS
        case 2: desired = .limited10FPS
        default: desired = .normal
        }

        if desired.rawValue >= current.rawValue {
            applyOCRPressurePolicyOnSessionQueue(desired, reason: "pressure \(liveLevel)/\(ocrLevel)")
            return
        }

        // Recover more slowly than we degrade to avoid pressure oscillation.
        stateLock.lock()
        ocrPressurePolicyStateLocked = "recovery hold \(Int(pressureRecoveryHold))s from \(current) to \(desired)"
        stateLock.unlock()
        publishSnapshot { _ in }
        sessionQueue.asyncAfter(deadline: .now() + pressureRecoveryHold) { [weak self] in
            guard let self else { return }
            self.assertSessionQueue()
            self.stateLock.lock()
            let stillCurrent = self.pressurePolicyGenerationLocked == generation
            let latestLive = self.liveSystemPressureLevelLocked
            let latestOCR = self.ocrSystemPressureLevelLocked
            self.stateLock.unlock()
            guard stillCurrent else { return }
            self.applyOCRPressurePolicyOnSessionQueue(
                desired,
                reason: "stable recovery after \(latestLive)/\(latestOCR)"
            )
        }
    }

    /// Recovery AH / RL-070: route presentation no longer has an API that can
    /// enable/disable the OCR data connection. Physical OCR capture remains owned
    /// by CaptureEngine for the lifetime of the desired graph; only physical
    /// pressure policy, device removal, graph replacement or explicit capture stop
    /// may suspend/remove this connection.

    private func applyOCRPressurePolicyOnSessionQueue(
        _ policy: OCRPressurePolicyLevel,
        reason: String
    ) {
        assertSessionQueue()
        let interval: UInt64
        let deliveryFPS: Double
        let suspended: Bool
        let stateText: String
        switch policy {
        case .normal:
            interval = 0
            deliveryFPS = 0
            suspended = false
            stateText = "normal — full OCR cadence"
        case .limited10FPS:
            interval = 100_000_000
            deliveryFPS = 10
            suspended = false
            stateText = "fair pressure — OCR delivery limited to 10 fps"
        case .limited5FPS:
            interval = 200_000_000
            deliveryFPS = 5
            suspended = false
            stateText = "serious pressure — OCR delivery limited to 5 fps"
        case .suspended:
            interval = UInt64.max
            deliveryFPS = 0
            suspended = true
            stateText = "critical pressure — OCR suspended; Broadcast preserved"
        }

        if let connection = ocrOutputConnection {
            connection.isEnabled = !suspended && activeGraphModeLocked.requiresOCR
        }
        refreshOutputConnectionTruthOnSessionQueue(reason: "OCR pressure policy")
        if suspended {
            RinkLensFrameHub.shared.clear(
                role: .ocr,
                reason: "UX16c40 OCR pressure suspension; stale OCR frames rejected"
            )
        }

        stateLock.lock()
        ocrPressurePolicyLevelLocked = policy
        ocrPressurePolicyStateLocked = stateText
        ocrPressureDeliveryIntervalNanosecondsLocked = interval
        ocrPressureDeliveryFPSLocked = deliveryFPS
        ocrPressureSuspendedLocked = suspended
        broadcastPreservationActiveLocked = policy != .normal && activeGraphModeLocked.requiresBroadcast
        if policy == .normal { lastOCRPressureDeliveryUptimeNanosecondsLocked = 0 }
        stateLock.unlock()
        trace("OCR pressure policy=\(stateText) reason=\(reason); Broadcast format/cadence unchanged")
        publishSnapshot { snapshot in
            if policy != .normal {
                snapshot.statusText = stateText
            } else if snapshot.statusText.localizedCaseInsensitiveContains("pressure")
                        || snapshot.statusText.localizedCaseInsensitiveContains("OCR suspended") {
                snapshot.statusText = snapshot.isActive ? "Capture running" : snapshot.statusText
            }
        }
    }

    private func shouldDeliverOCRFrameUnderPressurePolicy() -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !ocrPressureSuspendedLocked else { return false }
        let interval = ocrPressureDeliveryIntervalNanosecondsLocked
        guard interval > 0 else { return true }
        guard now &- lastOCRPressureDeliveryUptimeNanosecondsLocked >= interval else { return false }
        lastOCRPressureDeliveryUptimeNanosecondsLocked = now
        return true
    }

    private static func pressureRank(_ level: String) -> Int {
        switch level {
        case "shutdown": return 5
        case "critical": return 4
        case "serious": return 3
        case "fair": return 2
        case "nominal": return 1
        default: return 0
        }
    }

    private static func systemPressureLevelText(
        _ level: AVCaptureDevice.SystemPressureState.Level
    ) -> String {
        // `Level` is a RawRepresentable struct, not a Swift enum. An
        // `@unknown default` switch is therefore not exhaustive on the iOS
        // 18.5 SDK. Compare the published constants explicitly and preserve
        // any future raw value for diagnostics.
        if level == .nominal { return "nominal" }
        if level == .fair { return "fair" }
        if level == .serious { return "serious" }
        if level == .critical { return "critical" }
        if level == .shutdown { return "shutdown" }

        let rawValue = level.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return rawValue.isEmpty ? "unknown" : rawValue
    }

    private func clearFailureOnSessionQueue() {
        assertSessionQueue()
        stateLock.lock()
        failureLatchedLocked = false
        lastStartFailureAt = 0
        lastStartFailureText = "none"
        stateLock.unlock()
    }

    private func latchStartFailureOnSessionQueue(
        detail: String,
        retainedLiveDevice: AVCaptureDevice?,
        retainedOCRDevice: AVCaptureDevice?
    ) {
        assertSessionQueue()
        if isFailureLatchedSnapshot && !configured && !session.isRunning {
            trace("duplicate failure latch ignored detail=\(detail)")
            return
        }
        reconnectGeneration += 1
        transitionGeneration += 1
        cancelFirstFrameReadinessOnSessionQueue(reason: "capture failure: \(detail)")
        shouldAutoReconnect = false
        if session.isRunning { session.stopRunning() }
        let graphBeforeRelease = graphDescription()
        teardownGraph()
        stateLock.lock()
        failureLatchedLocked = true
        lastStartFailureAt = CFAbsoluteTimeGetCurrent()
        lastStartFailureText = detail
        stateLock.unlock()
        setActiveLocked(false)
        setTransitioningLocked(false)
        setPreviewAttachedLocked(false)
        liveService?.setExternallyManagedCaptureActive(
            false,
            device: retainedLiveDevice,
            owner: "UX16c38 CaptureEngine failure",
            retainReservation: false
        )
        ocrService?.setExternallyManagedCaptureActive(
            false,
            device: retainedOCRDevice,
            owner: "UX16c38 CaptureEngine failure",
            retainReservation: false
        )
        publishSnapshot(phase: .degraded) { snapshot in
            snapshot.statusText = "Capture unavailable — \(self.lastRequestedMode.rawValue) start failed"
            snapshot.graphText = "CaptureEngine graph released after start failure: \(detail); priorGraph={\(graphBeforeRelease)}"
            snapshot.lastInterruptionText = "CaptureEngine failure latched: \(detail)"
        }
        trace("failure latched; automatic retries disabled detail=\(detail) priorGraph={\(graphBeforeRelease)}")
    }

    private func teardownGraph(withinConfiguration: Bool = false) {
        assertSessionQueue()
        cancelBroadcastZoomTrajectoryOnSessionQueue(reason: "capture graph teardown")
        if !withinConfiguration { session.beginConfiguration() }
        let retainedBroadcastLayer = attachedBroadcastPreviewLayer
        let retainedOCRLayer = attachedOCRPreviewLayer
        for previewConnection in [broadcastPreviewConnection, ocrPreviewConnection].compactMap({ $0 })
        where session.connections.contains(where: { $0 === previewConnection }) {
            session.removeConnection(previewConnection)
        }
        setPreviewConnection(nil, layer: retainedBroadcastLayer, for: .broadcast)
        setPreviewConnection(nil, layer: retainedOCRLayer, for: .ocr)
        setPreviewAttachedLocked(false)

        for connection in session.connections {
            session.removeConnection(connection)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }
        for input in session.inputs {
            session.removeInput(input)
        }

        invalidateSystemPressureObserversOnSessionQueue()
        liveInput = nil
        ocrInput = nil
        liveVideoPort = nil
        ocrVideoPort = nil
        liveOutputConnection = nil
        ocrOutputConnection = nil
        stateLock.lock()
        activeGraphModeLocked = .stopped
        activeLiveDeviceID = nil
        activeOCRDeviceID = nil
        activeLiveDeviceNameLocked = "none"
        activeLiveDevicePositionTextLocked = "unavailable"
        activeLiveDeviceTypeTextLocked = "unavailable"
        activeOCRDeviceNameLocked = "none"
        activeOCRDevicePositionTextLocked = "unavailable"
        activeOCRDeviceTypeTextLocked = "unavailable"
        liveFirstFrameLumaTextLocked = "Broadcast branch not configured"
        ocrFirstFrameLumaTextLocked = "OCR branch not configured"
        activeLiveFormatPreference = nil
        activeOCRFormatPreference = nil
        activeLiveResolvedFormat = nil
        activeOCRResolvedFormat = nil
        activeEffectiveContract = nil
        liveFramesLocked = 0
        ocrFramesLocked = 0
        liveFormatTextLocked = "MultiCam live format not configured"
        ocrFormatTextLocked = "MultiCam OCR format not configured"
        liveConfiguredCadenceTextLocked = "not configured"
        ocrConfiguredCadenceTextLocked = "not configured"
        configuredLiveCadenceLocked = nil
        configuredOCRCadenceLocked = nil
        liveObservedFPSLocked = 0
        ocrObservedFPSLocked = 0
        liveLastCallbackUptimeNanosecondsLocked = nil
        ocrLastCallbackUptimeNanosecondsLocked = nil
        liveOutputConnectionTextLocked = "Broadcast output not configured"
        ocrOutputConnectionTextLocked = "OCR output not configured"
        liveObservedFrameUptimesLocked.removeAll(keepingCapacity: false)
        ocrObservedFrameUptimesLocked.removeAll(keepingCapacity: false)
        stateLock.unlock()
        configured = false
        RinkLensFrameHub.shared.clearAll(reason: "CaptureEngine graph torn down generation=\(transitionGeneration)")
        if !withinConfiguration { session.commitConfiguration() }
    }

    private func resetFirstFrameCountersOnSessionQueue() {
        assertSessionQueue()
        stateLock.lock()
        liveFramesLocked = 0
        ocrFramesLocked = 0
        stateLock.unlock()
        publishSnapshot(phase: .waitingForFrames) { snapshot in
            snapshot.liveFramesReceived = 0
            snapshot.ocrFramesReceived = 0
        }
    }

    /// Arms one event-driven first-frame lease. The session queue is released
    /// immediately after configuration/startRunning; sample-buffer callbacks or
    /// the monotonic DispatchTime deadline resolve the lease later.
    private func beginFirstFrameReadinessOnSessionQueue(
        mode: RinkLensCaptureLifecycleMode,
        transitionGeneration: Int,
        completion: @escaping (Bool) -> Void
    ) {
        assertSessionQueue()
        cancelFirstFrameReadinessOnSessionQueue(reason: "new readiness lease")

        // Recovery AH / RL-070: hardware readiness proves the physical OCR
        // branch independently from route presentation. The data connection stays
        // enabled for the desired graph unless physical pressure policy suspends it.
        if mode.requiresOCR {
            stateLock.lock()
            let pressureSuspended = ocrPressureSuspendedLocked
            stateLock.unlock()
            if !pressureSuspended {
                ocrOutputConnection?.isEnabled = true
            }
        }

        let started = DispatchTime.now().uptimeNanoseconds
        stateLock.lock()
        firstFrameReadinessTokenLocked &+= 1
        let token = firstFrameReadinessTokenLocked
        let waiter = FirstFrameReadinessWaiter(
            token: token,
            mode: mode,
            transitionGeneration: transitionGeneration,
            startedUptimeNanoseconds: started,
            completion: completion
        )
        let readyNow = firstFrameRequirementsSatisfiedLocked(mode: mode)
        if readyNow {
            firstFrameReadinessWaiterLocked = nil
        } else {
            firstFrameReadinessWaiterLocked = waiter
        }
        stateLock.unlock()

        if readyNow {
            let structurallyReady = requiredBranchesStructurallyAvailableOnSessionQueue(mode: mode)
            restoreOCRPhysicalDeliveryAfterReadinessOnSessionQueue(reason: "immediate readiness")
            trace("first-frame readiness immediate check token=\(token) generation=\(transitionGeneration) mode=\(mode.rawValue) structural=\(structurallyReady)")
            completion(structurallyReady)
            return
        }

        trace("first-frame readiness armed token=\(token) generation=\(transitionGeneration) mode=\(mode.rawValue) timeout=\(String(format: "%.2f", firstFrameReadinessTimeout))s")
        sessionQueue.asyncAfter(deadline: .now() + firstFrameReadinessTimeout) { [weak self] in
            self?.resolveFirstFrameReadinessTimeoutOnSessionQueue(token: token)
        }
    }

    private func firstFrameRequirementsSatisfiedLocked(mode: RinkLensCaptureLifecycleMode) -> Bool {
        // Recovery X / RL-057: capture readiness is hardware truth, never route/UI
        // presentation policy. A configured OCR branch is not ready until that
        // physical branch has delivered a current-generation frame, even when the
        // current route normally suspends OCR presentation delivery.
        switch mode {
        case .dualCamera:
            return liveFramesLocked > 0 && ocrFramesLocked > 0
        case .broadcastOnly:
            return liveFramesLocked > 0
        case .ocrOnly:
            return ocrFramesLocked > 0
        case .stopped:
            return true
        }
    }

    private func requiredBranchesStructurallyAvailableOnSessionQueue(mode: RinkLensCaptureLifecycleMode) -> Bool {
        assertSessionQueue()
        guard session.isRunning, configured else { return mode == .stopped }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: Self.videoDeviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        let discoveredIDs = Set(discovery.devices.map(\.uniqueID))
        if mode.requiresBroadcast {
            guard let input = liveInput,
                  discoveredIDs.contains(input.device.uniqueID),
                  session.inputs.contains(where: { $0 === input }),
                  session.outputs.contains(where: { $0 === liveOutput }),
                  let connection = liveOutputConnection,
                  session.connections.contains(where: { $0 === connection }) else { return false }
        }
        if mode.requiresOCR {
            guard let input = ocrInput,
                  discoveredIDs.contains(input.device.uniqueID),
                  session.inputs.contains(where: { $0 === input }),
                  session.outputs.contains(where: { $0 === ocrOutput }),
                  let connection = ocrOutputConnection,
                  session.connections.contains(where: { $0 === connection }) else { return false }
        }
        return true
    }

    private func restoreOCRPhysicalDeliveryAfterReadinessOnSessionQueue(reason: String) {
        assertSessionQueue()
        stateLock.lock()
        let pressureSuspended = ocrPressureSuspendedLocked
        let graphRequiresOCR = activeGraphModeLocked.requiresOCR
        stateLock.unlock()
        let effectiveEnabled = !pressureSuspended && graphRequiresOCR && ocrInput != nil
        ocrOutputConnection?.isEnabled = effectiveEnabled
        refreshOutputConnectionTruthOnSessionQueue(reason: "Recovery AH physical OCR delivery restore after readiness: \(reason)")
    }

    /// Called from either video-output queue after incrementing its frame counter.
    /// Only the winning callback removes the waiter. Final success is verified on
    /// the authoritative session queue against current device/graph truth.
    private func signalFirstFrameReadinessIfSatisfied() {
        stateLock.lock()
        guard let waiter = firstFrameReadinessWaiterLocked,
              firstFrameRequirementsSatisfiedLocked(mode: waiter.mode) else {
            stateLock.unlock()
            return
        }
        firstFrameReadinessWaiterLocked = nil
        let liveCount = liveFramesLocked
        let ocrCount = ocrFramesLocked
        stateLock.unlock()

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let tokenStillCurrent = waiter.token == self.firstFrameReadinessTokenLocked
            self.stateLock.unlock()
            let structurallyReady = tokenStillCurrent
                && waiter.transitionGeneration == self.transitionGeneration
                && self.requiredBranchesStructurallyAvailableOnSessionQueue(mode: waiter.mode)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - waiter.startedUptimeNanoseconds) / 1_000_000_000
            self.restoreOCRPhysicalDeliveryAfterReadinessOnSessionQueue(reason: structurallyReady ? "verified" : "rejected")
            if structurallyReady {
                self.trace("first-frame readiness satisfied token=\(waiter.token) generation=\(waiter.transitionGeneration) mode=\(waiter.mode.rawValue) live=\(liveCount) ocr=\(ocrCount) elapsed=\(String(format: "%.3f", elapsed))s structural=true")
            } else {
                self.trace("Recovery X first-frame readiness rejected token=\(waiter.token) generation=\(waiter.transitionGeneration) mode=\(waiter.mode.rawValue) live=\(liveCount) ocr=\(ocrCount) elapsed=\(String(format: "%.3f", elapsed))s reason=required-branch-structure-or-device-unavailable")
                RinkLensStructuredEventLogger.shared.record(
                    domain: .capture,
                    event: "capture_required_branch_readiness_rejected",
                    entityID: waiter.mode.rawValue,
                    previous: ["liveFrames": String(liveCount), "ocrFrames": String(ocrCount)],
                    next: ["ready": "false", "structuralTruth": "failed"],
                    source: "CaptureEngine.signalFirstFrameReadinessIfSatisfied",
                    reason: "Recovery X revalidates required devices and graph structure at readiness commit",
                    captureGeneration: self.transitionGeneration,
                    authoritativeOwner: "CaptureEngine"
                )
            }
            waiter.completion(structurallyReady)
        }
    }

    private func resolveFirstFrameReadinessTimeoutOnSessionQueue(token: UInt64) {
        assertSessionQueue()
        stateLock.lock()
        guard let waiter = firstFrameReadinessWaiterLocked,
              waiter.token == token else {
            stateLock.unlock()
            return
        }
        firstFrameReadinessWaiterLocked = nil
        let liveCount = liveFramesLocked
        let ocrCount = ocrFramesLocked
        stateLock.unlock()

        restoreOCRPhysicalDeliveryAfterReadinessOnSessionQueue(reason: "timeout")
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - waiter.startedUptimeNanoseconds) / 1_000_000_000
        trace("first-frame readiness timed out token=\(token) generation=\(waiter.transitionGeneration) mode=\(waiter.mode.rawValue) live=\(liveCount) ocr=\(ocrCount) elapsed=\(String(format: "%.3f", elapsed))s")
        waiter.completion(false)
    }

    private func cancelFirstFrameReadinessOnSessionQueue(reason: String) {
        assertSessionQueue()
        stateLock.lock()
        let waiter = firstFrameReadinessWaiterLocked
        firstFrameReadinessWaiterLocked = nil
        stateLock.unlock()
        restoreOCRPhysicalDeliveryAfterReadinessOnSessionQueue(reason: "cancelled: \(reason)")
        guard let waiter else { return }
        trace("first-frame readiness cancelled token=\(waiter.token) generation=\(waiter.transitionGeneration) mode=\(waiter.mode.rawValue) reason=\(reason)")
        waiter.completion(false)
    }

    /// Returns the exact runtime health of both output branches. Unlike the
    /// structural lifecycle snapshot, this samples AVCaptureConnection truth on
    /// the session queue and combines it with monotonic callback freshness.
    func captureHealthSnapshot(maximumFrameAge: TimeInterval = 1.5) async -> RinkLensCaptureHealthSnapshot {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    let unavailable = RinkLensCaptureBranchHealthSnapshot(
                        role: .broadcast, required: false, sessionRunning: false,
                        inputPresent: false, outputPresent: false, connectionPresent: false,
                        connectionEnabled: false, connectionActive: false, delegateInstalled: false,
                        intentionallySuspended: false, frameCount: 0, lastCallbackAgeSeconds: nil,
                        frameHubFresh: false, frameHubSequence: 0,
                        observedFPS: 0, maximumFreshAgeSeconds: maximumFrameAge
                    )
                    continuation.resume(returning: .init(
                        mode: .stopped, generation: 0, live: unavailable,
                        ocr: RinkLensCaptureBranchHealthSnapshot(
                            role: .ocr, required: false, sessionRunning: false,
                            inputPresent: false, outputPresent: false, connectionPresent: false,
                            connectionEnabled: false, connectionActive: false, delegateInstalled: false,
                            intentionallySuspended: false, frameCount: 0, lastCallbackAgeSeconds: nil,
                            frameHubFresh: false, frameHubSequence: 0,
                            observedFPS: 0, maximumFreshAgeSeconds: maximumFrameAge
                        ),
                        sampledAtUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
                    ))
                    return
                }
                self.assertSessionQueue()
                let now = DispatchTime.now().uptimeNanoseconds
                self.stateLock.lock()
                let mode = self.activeGraphModeLocked
                let generation = self.transitionGenerationSnapshotLocked
                let liveCount = self.liveFramesLocked
                let ocrCount = self.ocrFramesLocked
                let liveLast = self.liveLastCallbackUptimeNanosecondsLocked
                let ocrLast = self.ocrLastCallbackUptimeNanosecondsLocked
                let liveFPS = self.liveObservedFPSLocked
                let ocrFPS = self.ocrObservedFPSLocked
                let liveDeviceID = self.activeLiveDeviceID
                let ocrDeviceID = self.activeOCRDeviceID
                let delegatesInstalled = self.outputDelegatesInstalledLocked
                let pressureSuspended = self.ocrPressureSuspendedLocked
                self.stateLock.unlock()

                let age: (UInt64?) -> TimeInterval? = { value in
                    value.map { now >= $0 ? Double(now - $0) / 1_000_000_000 : 0 }
                }
                let sessionRunning = self.session.isRunning
                let liveConnection = self.liveOutputConnection
                let ocrConnection = self.ocrOutputConnection
                let liveInputPresent = self.liveInput.map { liveInput in
                    self.session.inputs.contains(where: { $0 === liveInput })
                } ?? false
                let ocrInputPresent = self.ocrInput.map { ocrInput in
                    self.session.inputs.contains(where: { $0 === ocrInput })
                } ?? false
                let liveConnectionPresent = liveConnection.map { connection in
                    self.session.connections.contains(where: { $0 === connection })
                } ?? false
                let ocrConnectionPresent = ocrConnection.map { connection in
                    self.session.connections.contains(where: { $0 === connection })
                } ?? false
                let hub = RinkLensFrameHub.shared.diagnosticSnapshot(nowUptimeNanoseconds: now)
                let liveHubFresh = mode.requiresBroadcast
                    ? (hub.broadcast.ageSeconds.map { $0 <= maximumFrameAge } == true
                        && hub.broadcast.captureGeneration == generation
                        && (liveDeviceID == nil || hub.broadcast.physicalDeviceID == liveDeviceID))
                    : true
                let ocrHubFresh = mode.requiresOCR
                    ? (hub.ocr.ageSeconds.map { $0 <= maximumFrameAge } == true
                        && hub.ocr.captureGeneration == generation
                        && (ocrDeviceID == nil || hub.ocr.physicalDeviceID == ocrDeviceID))
                    : true
                let live = RinkLensCaptureBranchHealthSnapshot(
                    role: .broadcast, required: mode.requiresBroadcast, sessionRunning: sessionRunning,
                    inputPresent: liveInputPresent,
                    outputPresent: self.session.outputs.contains(where: { $0 === self.liveOutput }),
                    connectionPresent: liveConnectionPresent,
                    connectionEnabled: liveConnection?.isEnabled == true,
                    connectionActive: liveConnection?.isActive == true,
                    delegateInstalled: delegatesInstalled, intentionallySuspended: false,
                    frameCount: liveCount, lastCallbackAgeSeconds: age(liveLast),
                    frameHubFresh: liveHubFresh, frameHubSequence: hub.broadcast.sequence,
                    observedFPS: liveFPS,
                    maximumFreshAgeSeconds: maximumFrameAge
                )
                let ocr = RinkLensCaptureBranchHealthSnapshot(
                    role: .ocr, required: mode.requiresOCR, sessionRunning: sessionRunning,
                    inputPresent: ocrInputPresent,
                    outputPresent: self.session.outputs.contains(where: { $0 === self.ocrOutput }),
                    connectionPresent: ocrConnectionPresent,
                    connectionEnabled: ocrConnection?.isEnabled == true,
                    connectionActive: ocrConnection?.isActive == true,
                    delegateInstalled: delegatesInstalled, intentionallySuspended: pressureSuspended,
                    frameCount: ocrCount, lastCallbackAgeSeconds: age(ocrLast),
                    frameHubFresh: ocrHubFresh, frameHubSequence: hub.ocr.sequence,
                    observedFPS: ocrFPS,
                    maximumFreshAgeSeconds: maximumFrameAge
                )
                continuation.resume(returning: .init(
                    mode: mode, generation: generation, live: live, ocr: ocr,
                    sampledAtUptimeNanoseconds: now
                ))
            }
        }
    }

    /// Reconnects only the silent OCR data-output connection. Broadcast input,
    /// output, preview and recording source remain mounted. Success is proven by
    /// a current-generation FrameHub publication, not by connection structure.
    func recoverSilentOCRBranch(
        reason: String,
        freshFrameTimeout: TimeInterval = 1.75
    ) async -> RinkLensOCRDeadBranchRecoveryResult {
        struct ReconnectContext: Sendable {
            let disposition: RinkLensOCRDeadBranchRecoveryDisposition
            let generation: Int
            let deviceID: String?
            let frameCountBefore: Int
            let detail: String
        }

        let context: ReconnectContext = await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .init(
                        disposition: .structurallyUnavailable, generation: 0, deviceID: nil,
                        frameCountBefore: 0, detail: "CaptureEngine unavailable"
                    ))
                    return
                }
                self.assertSessionQueue()
                let mode = self.activeGraphModeLocked
                self.stateLock.lock()
                let generation = self.transitionGenerationSnapshotLocked
                let frameCount = self.ocrFramesLocked
                let deviceID = self.activeOCRDeviceID
                let pressureSuspended = self.ocrPressureSuspendedLocked
                let lastCallback = self.ocrLastCallbackUptimeNanosecondsLocked
                self.stateLock.unlock()

                guard mode.requiresOCR else {
                    continuation.resume(returning: .init(
                        disposition: .notRequired, generation: generation, deviceID: deviceID,
                        frameCountBefore: frameCount, detail: "Current graph does not require OCR"
                    ))
                    return
                }
                if pressureSuspended {
                    continuation.resume(returning: .init(
                        disposition: .intentionallySuspended, generation: generation, deviceID: deviceID,
                        frameCountBefore: frameCount,
                        detail: "OCR intentionally suspended by physical pressure policy"
                    ))
                    return
                }
                let now = DispatchTime.now().uptimeNanoseconds
                if let lastCallback, now >= lastCallback, Double(now - lastCallback) / 1_000_000_000 <= 1.5 {
                    continuation.resume(returning: .init(
                        disposition: .alreadyFresh, generation: generation, deviceID: deviceID,
                        frameCountBefore: frameCount, detail: "OCR callback became fresh before recovery"
                    ))
                    return
                }
                guard self.session.isRunning, self.configured,
                      let port = self.ocrVideoPort, self.ocrInput != nil,
                      self.session.outputs.contains(where: { $0 === self.ocrOutput }) else {
                    continuation.resume(returning: .init(
                        disposition: .structurallyUnavailable, generation: generation, deviceID: deviceID,
                        frameCountBefore: frameCount, detail: "OCR input/output structure unavailable"
                    ))
                    return
                }

                self.stateLock.lock()
                self.ocrDeadBranchRecoveryCountLocked &+= 1
                let attempt = self.ocrDeadBranchRecoveryCountLocked
                self.lastDeadBranchRecoveryTextLocked = "attempt #\(attempt) reconnecting OCR output: \(reason)"
                self.stateLock.unlock()
                self.publishSnapshot(phase: .recovering) { snapshot in
                    snapshot.statusText = "OCR branch silent — reconnecting OCR output; Broadcast preserved"
                }

                let previous = self.ocrOutputConnection
                var replacement: AVCaptureConnection?
                self.session.beginConfiguration()
                if let previous, self.session.connections.contains(where: { $0 === previous }) {
                    self.session.removeConnection(previous)
                }
                self.ocrOutput.setSampleBufferDelegate(nil, queue: nil)
                self.ocrOutput.setSampleBufferDelegate(self, queue: self.ocrOutputQueue)
                self.stateLock.lock()
                self.outputDelegatesInstalledLocked = true
                self.stateLock.unlock()

                let candidate = AVCaptureConnection(inputPorts: [port], output: self.ocrOutput)
                if self.session.canAddConnection(candidate) {
                    self.session.addConnection(candidate)
                    self.applyDataConnectionSettings(candidate, role: .ocr, mirrored: false)
                    candidate.isEnabled = true
                    replacement = candidate
                } else if let previous, self.session.canAddConnection(previous) {
                    self.session.addConnection(previous)
                    self.applyDataConnectionSettings(previous, role: .ocr, mirrored: false)
                    previous.isEnabled = true
                    replacement = previous
                }
                self.ocrOutputConnection = replacement
                self.session.commitConfiguration()
                self.refreshOutputConnectionTruthOnSessionQueue(reason: "dead OCR branch reconnect")

                guard replacement != nil else {
                    self.stateLock.lock()
                    self.ocrDeadBranchRecoveryFailureCountLocked &+= 1
                    self.lastDeadBranchRecoveryTextLocked = "attempt #\(attempt) rejected: no OCR output connection"
                    self.stateLock.unlock()
                    self.publishSnapshot(phase: .running) { snapshot in
                        snapshot.statusText = "OCR branch silent — output reconnection rejected; Broadcast preserved"
                    }
                    continuation.resume(returning: .init(
                        disposition: .reconnectRejected, generation: generation, deviceID: deviceID,
                        frameCountBefore: frameCount, detail: "AVCaptureSession rejected OCR output reconnection"
                    ))
                    return
                }

                self.stateLock.lock()
                self.ocrObservedFrameUptimesLocked.removeAll(keepingCapacity: true)
                self.ocrObservedFPSLocked = 0
                self.ocrLastCallbackUptimeNanosecondsLocked = nil
                self.stateLock.unlock()
                RinkLensFrameHub.shared.clear(role: .ocr, reason: "UX16d2d OCR dead-branch output reconnection")
                self.trace("UX16d2d OCR output reconnected attempt=\(attempt) generation=\(generation) beforeFrames=\(frameCount) reason=\(reason)")
                continuation.resume(returning: .init(
                    disposition: .recovered, generation: generation, deviceID: deviceID,
                    frameCountBefore: frameCount, detail: "OCR output connection replaced; awaiting fresh callback"
                ))
            }
        }

        guard context.disposition == .recovered else {
            return .init(
                disposition: context.disposition, generation: context.generation,
                frameCountBefore: context.frameCountBefore, frameCountAfter: context.frameCountBefore,
                diagnosticText: context.detail
            )
        }

        let frame = await RinkLensFrameHub.shared.waitForFreshFrameEvidence(
            for: .ocr, maxAge: 0.5, requiredCaptureGeneration: context.generation,
            requiredPhysicalDeviceID: context.deviceID, timeout: freshFrameTimeout
        )
        let frameCountAfter = captureSnapshot().ocrFramesReceived
        if let frame {
            await withCheckedContinuation { continuation in
                sessionQueue.async { [weak self] in
                    guard let self else { continuation.resume(); return }
                    self.stateLock.lock()
                    self.lastDeadBranchRecoveryTextLocked = "OCR output recovered generation=\(context.generation) frame=#\(frame.sequence)"
                    self.stateLock.unlock()
                    self.publishSnapshot(phase: .running) { snapshot in
                        snapshot.statusText = "CaptureEngine running — OCR frame delivery recovered"
                    }
                    self.trace("UX16d2d OCR dead branch recovered generation=\(context.generation) frame=#\(frame.sequence)")
                    continuation.resume()
                }
            }
            return .init(
                disposition: .recovered, generation: context.generation,
                frameCountBefore: context.frameCountBefore, frameCountAfter: frameCountAfter,
                diagnosticText: "OCR output reconnection produced fresh frame #\(frame.sequence)"
            )
        }

        await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else { continuation.resume(); return }
                self.stateLock.lock()
                self.ocrDeadBranchRecoveryFailureCountLocked &+= 1
                self.lastDeadBranchRecoveryTextLocked = "OCR output reconnect timed out generation=\(context.generation)"
                self.stateLock.unlock()
                self.publishSnapshot(phase: .running) { snapshot in
                    snapshot.statusText = "OCR branch silent after output reconnection; Broadcast preserved"
                }
                self.trace("UX16d2d OCR output reconnect timed out generation=\(context.generation)")
                continuation.resume()
            }
        }
        return .init(
            disposition: .timedOut, generation: context.generation,
            frameCountBefore: context.frameCountBefore, frameCountAfter: frameCountAfter,
            diagnosticText: "OCR output reconnection did not produce a fresh frame within 1.75s"
        )
    }

    func markOCRBranchRecoveryDeferredDuringRecording(reason: String) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            self.lastDeadBranchRecoveryTextLocked = "OCR branch silent; graph rebuild deferred while recording: \(reason)"
            self.stateLock.unlock()
            self.publishSnapshot(phase: .running) { snapshot in
                snapshot.statusText = "OCR branch silent — Broadcast recording preserved; full recovery deferred"
            }
            self.trace("UX16d2d OCR full graph recovery deferred while recording reason=\(reason)")
        }
    }

    /// Installs the sole capture-driven recording endpoint. A token prevents a
    /// stale file writer from removing a newer recording endpoint.
    @discardableResult
    func installRecordingCaptureSink(
        role: RinkLensFrameRole,
        handler: @escaping @Sendable (BroadcastRecordingCaptureFrame) -> Void
    ) -> UUID {
        let token = UUID()
        recordingCaptureSinkLock.lock()
        recordingCaptureSink = RecordingCaptureSink(token: token, role: role, handler: handler)
        recordingCaptureSinkLock.unlock()
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "recording_capture_sink_installed",
            entityID: token.uuidString,
            previous: ["transport": "Broadcast callback -> FrameHub pixel copy -> RecordingWriter pixel copy"],
            next: ["transport": "Broadcast callback -> synchronous RecordingWriter-owned ingress copy", "role": role.rawValue],
            source: "CaptureEngine.installRecordingCaptureSink",
            reason: "Recovery AV removes the redundant Broadcast FrameHub full-frame copy from the capture callback",
            authoritativeOwner: "RecordingEngine/CaptureEngine boundary"
        )
        return token
    }

    func removeRecordingCaptureSink(token: UUID, reason: String) {
        recordingCaptureSinkLock.lock()
        let removed = recordingCaptureSink?.token == token
        if removed { recordingCaptureSink = nil }
        recordingCaptureSinkLock.unlock()
        if removed {
            RinkLensStructuredEventLogger.shared.record(
                domain: .recording,
                event: "recording_capture_sink_removed",
                entityID: token.uuidString,
                previous: ["installed": "true"],
                next: ["installed": "false"],
                source: "CaptureEngine.removeRecordingCaptureSink",
                reason: reason,
                authoritativeOwner: "RecordingEngine/CaptureEngine boundary"
            )
        }
    }

    /// Independent bounded programme-output endpoint. The in-app RTMPS
    /// publisher must synchronously copy the short-lived camera buffer before
    /// this callback returns, exactly like RecordingWriter, but owns a separate
    /// pool and lifetime so reconnecting cannot restart or mutate recording.
    @discardableResult
    func installProgramStreamCaptureSink(
        role: RinkLensFrameRole,
        handler: @escaping @Sendable (BroadcastRecordingCaptureFrame) -> Void
    ) -> UUID {
        let token = UUID()
        programStreamCaptureSinkLock.lock()
        programStreamCaptureSink = RecordingCaptureSink(token: token, role: role, handler: handler)
        programStreamCaptureSinkLock.unlock()
        return token
    }

    func removeProgramStreamCaptureSink(token: UUID) {
        programStreamCaptureSinkLock.lock()
        if programStreamCaptureSink?.token == token { programStreamCaptureSink = nil }
        programStreamCaptureSinkLock.unlock()
    }

    /// Captures exactly one application-owned Broadcast frame for presentation
    /// continuity. The camera callback performs the existing bounded FrameHub
    /// copy once; Core Image conversion then runs on a dedicated non-main queue.
    /// The request is capacity one and expires at the physical-frame deadline.
    func captureBroadcastPreviewContinuityImage(
        timeout: TimeInterval = 0.75
    ) async -> RinkLensBroadcastPreviewContinuityFrame? {
        await withCheckedContinuation { continuation in
            let id = UUID()
            let completion: @Sendable (RinkLensFrameHubFrame?) -> Void = { [weak self] frame in
                guard let self, let frame else {
                    continuation.resume(returning: nil)
                    return
                }
                self.broadcastPreviewContinuityRenderQueue.async { [weak self] in
                    guard let self else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let image = CIImage(cvPixelBuffer: frame.pixelBuffer)
                    let rendered = self.broadcastPreviewContinuityCIContext.createCGImage(
                        image,
                        from: image.extent
                    )
                    continuation.resume(returning: rendered.map {
                        RinkLensBroadcastPreviewContinuityFrame(
                            image: $0,
                            evidence: frame.evidence
                        )
                    })
                }
            }
            broadcastPreviewContinuityLock.lock()
            let displaced = broadcastPreviewContinuityRequest
            broadcastPreviewContinuityRequest = .init(id: id, completion: completion)
            broadcastPreviewContinuityLock.unlock()
            displaced?.completion(nil)
            broadcastPreviewContinuityRenderQueue.asyncAfter(deadline: .now() + max(0.1, timeout)) { [weak self] in
                self?.completeBroadcastPreviewContinuityRequest(id: id, frame: nil)
            }
        }
    }

    private func broadcastPreviewContinuityRequestPending() -> Bool {
        broadcastPreviewContinuityLock.lock()
        let pending = broadcastPreviewContinuityRequest != nil
        broadcastPreviewContinuityLock.unlock()
        return pending
    }

    private func completeBroadcastPreviewContinuityRequest(
        id: UUID? = nil,
        frame: RinkLensFrameHubFrame?
    ) {
        broadcastPreviewContinuityLock.lock()
        guard let request = broadcastPreviewContinuityRequest,
              id == nil || request.id == id else {
            broadcastPreviewContinuityLock.unlock()
            return
        }
        broadcastPreviewContinuityRequest = nil
        broadcastPreviewContinuityLock.unlock()
        request.completion(frame)
    }

    private func recordingCaptureSinkSnapshot(for role: RinkLensFrameRole) -> (@Sendable (BroadcastRecordingCaptureFrame) -> Void)? {
        recordingCaptureSinkLock.lock()
        let handler = recordingCaptureSink.flatMap { $0.role == role ? $0.handler : nil }
        recordingCaptureSinkLock.unlock()
        return handler
    }

    private func programStreamCaptureSinkSnapshot(for role: RinkLensFrameRole) -> (@Sendable (BroadcastRecordingCaptureFrame) -> Void)? {
        programStreamCaptureSinkLock.lock()
        let handler = programStreamCaptureSink.flatMap { $0.role == role ? $0.handler : nil }
        programStreamCaptureSinkLock.unlock()
        return handler
    }

    private func refreshOutputConnectionTruthOnSessionQueue(reason: String) {
        assertSessionQueue()
        let describe: (String, AVCaptureConnection?, AVCaptureVideoDataOutput) -> String = { label, connection, output in
            let present = connection.map { candidate in self.session.connections.contains(where: { $0 === candidate }) } ?? false
            let outputPresent = self.session.outputs.contains(where: { $0 === output })
            let stabilisation = connection.map { String($0.activeVideoStabilizationMode.rawValue) } ?? "none"
            return "\(label) outputPresent=\(outputPresent) connectionPresent=\(present) enabled=\(connection?.isEnabled == true) active=\(connection?.isActive == true) stabilisation=\(stabilisation) reason=\(reason)"
        }
        let liveText = describe("Broadcast", liveOutputConnection, liveOutput)
        let ocrText = describe("OCR", ocrOutputConnection, ocrOutput)
        stateLock.lock()
        liveOutputConnectionTextLocked = liveText
        ocrOutputConnectionTextLocked = ocrText
        stateLock.unlock()
    }

    private func graphDescription() -> String {
        let liveID = activeLiveDeviceID ?? "none"
        let ocrID = activeOCRDeviceID ?? "none"
        return "mode=\(activeGraphModeLocked.rawValue) session=\(sessionIdentifier) configured=\(configured) running=\(session.isRunning) inputs=\(session.inputs.count) outputs=\(session.outputs.count) connections=\(session.connections.count) live=\(liveID) ocr=\(ocrID) hardwareCost=\(String(format: "%.2f", session.hardwareCost)) pressureCost=\(String(format: "%.2f", session.systemPressureCost))"
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let callbackStartedUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        defer {
            recordCaptureCallbackResidence(
                output: output,
                startedUptimeNanoseconds: callbackStartedUptimeNanoseconds
            )
        }
        // UX16c43: the originating CMSampleBuffer never leaves AVFoundation's
        // callback. Extract the CVPixelBuffer immediately and replace the role's
        // capacity-one FrameHub slot. Service queues receive only a coalesced
        // availability signal, never one retained camera buffer per callback.
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let capturedAt = Date()
        let capturedUptime = DispatchTime.now().uptimeNanoseconds

        if output === liveOutput {
            stateLock.lock()
            liveFramesLocked += 1
            liveLastCallbackUptimeNanosecondsLocked = capturedUptime
            liveObservedFPSLocked = updateObservedCadenceLocked(role: .broadcast, at: capturedUptime)
            let count = liveFramesLocked
            let generation = transitionGenerationSnapshotLocked
            let deviceID = activeLiveDeviceID
            if liveLumaSampledGenerationLocked != generation {
                liveFirstFrameLumaTextLocked = "generation \(generation) device=\(deviceID ?? "none") \(Self.sampledLumaDescription(from: pixelBuffer))"
                liveLumaSampledGenerationLocked = generation
            }
            stateLock.unlock()
            // Recovery AV: Broadcast has no continuous pixel consumer in
            // FrameHub. Publish immutable freshness evidence only, then offer the
            // original callback buffer synchronously to RecordingWriter, which
            // must copy it into its own bounded pool before this callback returns.
            let evidence: RinkLensFrameHubEvidence
            if broadcastPreviewContinuityRequestPending(),
               let continuityFrame = RinkLensFrameHub.shared.publish(
                    pixelBuffer: pixelBuffer,
                    role: .broadcast,
                    capturedAt: capturedAt,
                    capturedUptimeNanoseconds: capturedUptime,
                    source: "Recovery DD one-shot Broadcast preview continuity frame",
                    physicalDeviceID: deviceID,
                    captureGeneration: generation
               ) {
                evidence = continuityFrame.evidence
                completeBroadcastPreviewContinuityRequest(frame: continuityFrame)
            } else {
                evidence = RinkLensFrameHub.shared.publishEvidence(
                    pixelBuffer: pixelBuffer,
                    role: .broadcast,
                    capturedAt: capturedAt,
                    capturedUptimeNanoseconds: capturedUptime,
                    source: "Recovery AV CaptureEngine Broadcast evidence ingress",
                    physicalDeviceID: deviceID,
                    captureGeneration: generation
                )
            }
            if let recordingSink = recordingCaptureSinkSnapshot(for: .broadcast) {
                recordingSink(BroadcastRecordingCaptureFrame(pixelBuffer: pixelBuffer, evidence: evidence))
            }
            if let streamingSink = programStreamCaptureSinkSnapshot(for: .broadcast) {
                streamingSink(BroadcastRecordingCaptureFrame(pixelBuffer: pixelBuffer, evidence: evidence))
            }
            liveService?.notifyExternallyManagedFrameAvailable()
            signalFirstFrameReadinessIfSatisfied()
            scheduleBroadcastQualityTelemetryIfNeeded(capturedUptime)
            publishFrameCountersIfNeeded(live: count, ocr: nil)
        } else if output === ocrOutput {
            stateLock.lock()
            ocrFramesLocked += 1
            ocrLastCallbackUptimeNanosecondsLocked = capturedUptime
            ocrObservedFPSLocked = updateObservedCadenceLocked(role: .ocr, at: capturedUptime)
            let count = ocrFramesLocked
            let generation = transitionGenerationSnapshotLocked
            let deviceID = activeOCRDeviceID
            if ocrLumaSampledGenerationLocked != generation {
                ocrFirstFrameLumaTextLocked = "generation \(generation) device=\(deviceID ?? "none") \(Self.sampledLumaDescription(from: pixelBuffer))"
                ocrLumaSampledGenerationLocked = generation
            }
            stateLock.unlock()
            signalFirstFrameReadinessIfSatisfied()
            let recordingSink = recordingCaptureSinkSnapshot(for: .ocr)
            let streamingSink = programStreamCaptureSinkSnapshot(for: .ocr)
            let shouldDeliverOCR = shouldDeliverOCRFrameUnderPressurePolicy()
            var evidence: RinkLensFrameHubEvidence?
            if shouldDeliverOCR {
                // OCR/Image Relay genuinely consumes pixels, so OCR keeps the
                // bounded app-owned FrameHub copy. Recording no longer consumes
                // that lease; it copies the callback directly into writer memory.
                if let ownedFrame = RinkLensFrameHub.shared.publish(
                    pixelBuffer: pixelBuffer,
                    role: .ocr,
                    capturedAt: capturedAt,
                    capturedUptimeNanoseconds: capturedUptime,
                    source: "Recovery AV CaptureEngine owned OCR ingress",
                    physicalDeviceID: deviceID,
                    captureGeneration: generation
                ) {
                    evidence = ownedFrame.evidence
                    ocrService?.notifyExternallyManagedFrameAvailable()
                }
            }
            if evidence == nil, recordingSink != nil || streamingSink != nil {
                evidence = RinkLensFrameHub.shared.publishEvidence(
                    pixelBuffer: pixelBuffer,
                    role: .ocr,
                    capturedAt: capturedAt,
                    capturedUptimeNanoseconds: capturedUptime,
                    source: "Recovery AV CaptureEngine OCR recording evidence ingress",
                    physicalDeviceID: deviceID,
                    captureGeneration: generation
                )
            }
            if let recordingSink, let evidence {
                recordingSink(BroadcastRecordingCaptureFrame(pixelBuffer: pixelBuffer, evidence: evidence))
            }
            if let streamingSink, let evidence {
                streamingSink(BroadcastRecordingCaptureFrame(pixelBuffer: pixelBuffer, evidence: evidence))
            }
            publishFrameCountersIfNeeded(live: nil, ocr: count)
        }
    }

    private func recordCaptureCallbackResidence(
        output: AVCaptureOutput,
        startedUptimeNanoseconds: UInt64
    ) {
        let completed = DispatchTime.now().uptimeNanoseconds
        let milliseconds = completed >= startedUptimeNanoseconds
            ? Double(completed - startedUptimeNanoseconds) / 1_000_000.0
            : 0
        stateLock.lock()
        if output === liveOutput {
            liveCallbackLastMillisecondsLocked = milliseconds
            liveCallbackMaxMillisecondsLocked = max(liveCallbackMaxMillisecondsLocked, milliseconds)
            let fps = max(1.0, uiSnapshotLocked.liveFormat?.cadence.framesPerSecond ?? 60.0)
            let budgetMilliseconds = 1_000.0 / fps
            // Count only; never log from the callback queue because diagnostics
            // must not worsen the fault we are measuring.
            if milliseconds > budgetMilliseconds { liveCallbackOverBudgetCountLocked &+= 1 }
        } else if output === ocrOutput {
            ocrCallbackLastMillisecondsLocked = milliseconds
            ocrCallbackMaxMillisecondsLocked = max(ocrCallbackMaxMillisecondsLocked, milliseconds)
            let fps = max(1.0, uiSnapshotLocked.ocrFormat?.cadence.framesPerSecond ?? 30.0)
            let budgetMilliseconds = 1_000.0 / fps
            if milliseconds > budgetMilliseconds { ocrCallbackOverBudgetCountLocked &+= 1 }
        }
        stateLock.unlock()
    }

    private func updateObservedCadenceLocked(role: RinkLensFrameRole, at uptime: UInt64) -> Double {
        let windowNanoseconds: UInt64 = 2_000_000_000
        let cutoff = uptime > windowNanoseconds ? uptime - windowNanoseconds : 0
        switch role {
        case .broadcast:
            liveObservedFrameUptimesLocked.append(uptime)
            liveObservedFrameUptimesLocked.removeAll { $0 < cutoff }
            guard let first = liveObservedFrameUptimesLocked.first,
                  let last = liveObservedFrameUptimesLocked.last,
                  last > first else { return 0 }
            return Double(liveObservedFrameUptimesLocked.count - 1) / (Double(last - first) / 1_000_000_000)
        case .ocr:
            ocrObservedFrameUptimesLocked.append(uptime)
            ocrObservedFrameUptimesLocked.removeAll { $0 < cutoff }
            guard let first = ocrObservedFrameUptimesLocked.first,
                  let last = ocrObservedFrameUptimesLocked.last,
                  last > first else { return 0 }
            return Double(ocrObservedFrameUptimesLocked.count - 1) / (Double(last - first) / 1_000_000_000)
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // UX16c53: AVFoundation may deliver a burst of hundreds of didDrop
        // callbacks after clip/export pressure. Count every event on the output
        // queue, but cross to MainActor only once per second with an aggregate.
        let rawReason = CMGetAttachment(
            sampleBuffer,
            key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
            attachmentModeOut: nil
        ) as? String
        let reason = Self.droppedFrameReasonText(rawReason)
        stateLock.lock()
        if dropCounterGenerationLocked != transitionGenerationSnapshotLocked {
            liveDroppedFramesLocked = 0
            liveDroppedLateFramesLocked = 0
            liveDroppedOutOfBuffersLocked = 0
            liveDroppedDiscontinuityFramesLocked = 0
            ocrDroppedFramesLocked = 0
            ocrDroppedLateFramesLocked = 0
            ocrDroppedOutOfBuffersLocked = 0
            ocrDroppedDiscontinuityFramesLocked = 0
            dropCounterGenerationLocked = transitionGenerationSnapshotLocked
            lastDropTelemetryPublishAtLocked = 0
            dropTelemetryFlushScheduledLocked = false
            lastPublishedLiveDropTotalLocked = 0
            lastPublishedLiveLateTotalLocked = 0
            lastPublishedLiveOutOfBuffersTotalLocked = 0
            lastPublishedLiveDiscontinuityTotalLocked = 0
            lastPublishedOCRDropTotalLocked = 0
            lastPublishedOCRLateTotalLocked = 0
            lastPublishedOCROutOfBuffersTotalLocked = 0
            lastPublishedOCRDiscontinuityTotalLocked = 0
        }

        if output === liveOutput {
            liveDroppedFramesLocked &+= 1
            liveDroppedFramesLifetimeLocked &+= 1
            switch reason {
            case "late":
                liveDroppedLateFramesLocked &+= 1
                liveDroppedLateFramesLifetimeLocked &+= 1
            case "outOfBuffers":
                liveDroppedOutOfBuffersLocked &+= 1
                liveDroppedOutOfBuffersLifetimeLocked &+= 1
            case "discontinuity":
                liveDroppedDiscontinuityFramesLocked &+= 1
                liveDroppedDiscontinuityFramesLifetimeLocked &+= 1
            default: break
            }
        } else if output === ocrOutput {
            ocrDroppedFramesLocked &+= 1
            ocrDroppedFramesLifetimeLocked &+= 1
            switch reason {
            case "late":
                ocrDroppedLateFramesLocked &+= 1
                ocrDroppedLateFramesLifetimeLocked &+= 1
            case "outOfBuffers":
                ocrDroppedOutOfBuffersLocked &+= 1
                ocrDroppedOutOfBuffersLifetimeLocked &+= 1
            case "discontinuity":
                ocrDroppedDiscontinuityFramesLocked &+= 1
                ocrDroppedDiscontinuityFramesLifetimeLocked &+= 1
            default: break
            }
        }

        // UX16d40a81 / RL-013: one capacity-one owner flush is the only
        // publication path for drop telemetry. R10 could publish immediately
        // after the one-second threshold while an older delayed flush was
        // already queued. When that delayed flush subsequently ran it emitted
        // another near-zero-window snapshot and MainActor breadcrumb, creating
        // the burst pattern seen in the physical logs.
        //
        // CaptureEngine remains the sole owner of every counter. The first drop
        // in a pending window schedules exactly one flush; further drops only
        // update the owner-held counters until that flush consumes the window.
        let shouldScheduleFlush = !dropTelemetryFlushScheduledLocked
        if shouldScheduleFlush {
            dropTelemetryFlushScheduledLocked = true
        }
        stateLock.unlock()

        if shouldScheduleFlush {
            sessionQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.flushPendingDropTelemetry()
            }
        }
    }

    private func flushPendingDropTelemetry() {
        stateLock.lock()
        dropTelemetryFlushScheduledLocked = false
        let hasPending = liveDroppedFramesLocked != lastPublishedLiveDropTotalLocked
            || ocrDroppedFramesLocked != lastPublishedOCRDropTotalLocked
        let aggregate = hasPending
            ? makeDropTelemetryAggregateLocked(now: CFAbsoluteTimeGetCurrent())
            : nil
        stateLock.unlock()
        guard aggregate != nil else { return }

        // UX16d40a81 / RL-013: the complete aggregate is already retained in
        // lastDroppedFrameTextLocked and emitted in the CaptureEngine snapshot.
        // Do not mirror each aggregate into MainThreadStallMonitor and
        // CameraOwnershipTraceStore on MainActor.
        publishSnapshot(advancesRevision: false) { _ in }
    }

    /// Requires stateLock to be held. Produces exactly one summary for every
    /// accumulated window and advances the published baselines atomically.
    private func makeDropTelemetryAggregateLocked(now: CFAbsoluteTime) -> String {
        let elapsed = lastDropTelemetryPublishAtLocked > 0
            ? max(0.001, now - lastDropTelemetryPublishAtLocked)
            : 0
        let liveDelta = liveDroppedFramesLocked - lastPublishedLiveDropTotalLocked
        let liveLateDelta = liveDroppedLateFramesLocked - lastPublishedLiveLateTotalLocked
        let liveBufferDelta = liveDroppedOutOfBuffersLocked - lastPublishedLiveOutOfBuffersTotalLocked
        let liveDiscontinuityDelta = liveDroppedDiscontinuityFramesLocked - lastPublishedLiveDiscontinuityTotalLocked
        let ocrDelta = ocrDroppedFramesLocked - lastPublishedOCRDropTotalLocked
        let ocrLateDelta = ocrDroppedLateFramesLocked - lastPublishedOCRLateTotalLocked
        let ocrBufferDelta = ocrDroppedOutOfBuffersLocked - lastPublishedOCROutOfBuffersTotalLocked
        let ocrDiscontinuityDelta = ocrDroppedDiscontinuityFramesLocked - lastPublishedOCRDiscontinuityTotalLocked
        let windowText = elapsed > 0 ? String(format: "%.2fs", elapsed) : "initial"
        let summary = "generation \(dropCounterGenerationLocked) drop aggregate window=\(windowText) "
            + "Broadcast +\(liveDelta) late=\(liveLateDelta) outOfBuffers=\(liveBufferDelta) discontinuity=\(liveDiscontinuityDelta) total=\(liveDroppedFramesLocked); "
            + "OCR +\(ocrDelta) late=\(ocrLateDelta) outOfBuffers=\(ocrBufferDelta) discontinuity=\(ocrDiscontinuityDelta) total=\(ocrDroppedFramesLocked)"
        lastDroppedFrameTextLocked = summary
        lastDropTelemetryPublishAtLocked = now
        lastPublishedLiveDropTotalLocked = liveDroppedFramesLocked
        lastPublishedLiveLateTotalLocked = liveDroppedLateFramesLocked
        lastPublishedLiveOutOfBuffersTotalLocked = liveDroppedOutOfBuffersLocked
        lastPublishedLiveDiscontinuityTotalLocked = liveDroppedDiscontinuityFramesLocked
        lastPublishedOCRDropTotalLocked = ocrDroppedFramesLocked
        lastPublishedOCRLateTotalLocked = ocrDroppedLateFramesLocked
        lastPublishedOCROutOfBuffersTotalLocked = ocrDroppedOutOfBuffersLocked
        lastPublishedOCRDiscontinuityTotalLocked = ocrDroppedDiscontinuityFramesLocked
        return summary
    }

    private static func sampledLumaDescription(from pixelBuffer: CVPixelBuffer) -> String {
        guard CVPixelBufferIsPlanar(pixelBuffer) else { return "non-planar" }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pixelBuffer) > 0,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            return "luma unavailable"
        }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        guard width > 0, height > 0, bytesPerRow > 0 else { return "invalid luma plane" }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var total = 0
        var minimum = 255
        var maximum = 0
        var count = 0
        for yIndex in 0..<8 {
            let y = min(height - 1, (yIndex * height + height / 16) / 8)
            for xIndex in 0..<12 {
                let x = min(width - 1, (xIndex * width + width / 24) / 12)
                let value = Int(bytes[y * bytesPerRow + x])
                total += value
                minimum = min(minimum, value)
                maximum = max(maximum, value)
                count += 1
            }
        }
        guard count > 0 else { return "no luma samples" }
        return String(format: "avg=%.1f min=%d max=%d samples=%d", Double(total) / Double(count), minimum, maximum, count)
    }

    private static func positionText(_ position: AVCaptureDevice.Position?) -> String {
        guard let position else { return "unavailable" }
        switch position {
        case .back: return "back"
        case .front: return "front"
        case .unspecified: return "unspecified"
        @unknown default: return "unknown"
        }
    }

    private static func droppedFrameReasonText(_ rawReason: String?) -> String {
        guard let rawReason else { return "unknown" }
        if rawReason == (kCMSampleBufferDroppedFrameReason_FrameWasLate as String) {
            return "late"
        }
        if rawReason == (kCMSampleBufferDroppedFrameReason_OutOfBuffers as String) {
            return "outOfBuffers"
        }
        if rawReason == (kCMSampleBufferDroppedFrameReason_Discontinuity as String) {
            return "discontinuity"
        }
        return rawReason
    }

    private func publishFrameCountersIfNeeded(live: Int?, ocr: Int?) {
        let now = CFAbsoluteTimeGetCurrent()
        stateLock.lock()
        let shouldPublish = now - lastHealthObservationPublishAtLocked >= 2.0 || live == 1 || ocr == 1
        if shouldPublish {
            lastHealthObservationPublishAtLocked = now
            lastFramePublishAt = now
        }
        let currentLive = liveFramesLocked
        let currentOCR = ocrFramesLocked
        stateLock.unlock()
        guard shouldPublish else { return }
        publishSnapshot(advancesRevision: false) { snapshot in
            snapshot.liveFramesReceived = currentLive
            snapshot.ocrFramesReceived = currentOCR
        }
    }

    private func setActiveLocked(_ active: Bool) {
        stateLock.lock()
        let changed = activeLocked != active
        activeLocked = active
        stateLock.unlock()
        guard changed else { return }
        publishSnapshot(phase: active ? .running : nil)
    }

    private func setTransitioningLocked(_ transitioning: Bool) {
        stateLock.lock()
        let changed = transitioningLocked != transitioning
        transitioningLocked = transitioning
        stateLock.unlock()
        guard changed else { return }
        publishSnapshot()
    }

    /// Resets both preview endpoint flags. This overload is used only when the
    /// graph is stopping, failing or being torn down.
    private func setPreviewAttachedLocked(_ attached: Bool) {
        stateLock.lock()
        let changed = previewAttachedLocked != attached
            || broadcastPreviewAttachedLocked != attached
            || ocrPreviewAttachedLocked != attached
        previewAttachedLocked = attached
        broadcastPreviewAttachedLocked = attached
        ocrPreviewAttachedLocked = attached
        stateLock.unlock()
        guard changed else { return }
        publishSnapshot()
    }

    private func setPreviewAttachedLocked(role: RinkLensCapturePreviewRole, attached: Bool) {
        stateLock.lock()
        let oldBroadcast = broadcastPreviewAttachedLocked
        let oldOCR = ocrPreviewAttachedLocked
        switch role {
        case .broadcast:
            broadcastPreviewAttachedLocked = attached
        case .ocr:
            ocrPreviewAttachedLocked = attached
        }
        previewAttachedLocked = broadcastPreviewAttachedLocked || ocrPreviewAttachedLocked
        let changed = oldBroadcast != broadcastPreviewAttachedLocked
            || oldOCR != ocrPreviewAttachedLocked
        stateLock.unlock()
        guard changed else { return }
        publishSnapshot()
    }

    private func publishState(
        status: String,
        phase: RinkLensCaptureEnginePhase? = nil
    ) {
        let graph = graphDescription()
        publishSnapshot(phase: phase) { snapshot in
            snapshot.statusText = status
            snapshot.graphText = graph
        }
    }

    private func traceZoomMovement(_ text: String) {
        DispatchQueue.main.async {
            MainThreadStallMonitor.shared.traceZoomMovement(text)
        }
    }

    private func trace(_ text: String) {
        DispatchQueue.main.async {
            MainThreadStallMonitor.shared.traceCameraStartupTimeline("UX16c38 CaptureEngine: \(text)")
            CameraOwnershipTraceStore.record(.lifecycle, owner: .broadcast, reason: "UX16c38 CaptureEngine \(text)")
        }
    }

    private static func interruptionReasonText(_ rawValue: Any?) -> String {
        let rawInt: Int?
        if let number = rawValue as? NSNumber {
            rawInt = number.intValue
        } else if let value = rawValue as? Int {
            rawInt = value
        } else {
            rawInt = nil
        }
        guard let rawInt, let reason = AVCaptureSession.InterruptionReason(rawValue: rawInt) else {
            return String(describing: rawValue)
        }
        switch reason {
        case .videoDeviceNotAvailableInBackground: return "videoDeviceNotAvailableInBackground(\(rawInt))"
        case .audioDeviceInUseByAnotherClient: return "audioDeviceInUseByAnotherClient(\(rawInt))"
        case .videoDeviceInUseByAnotherClient: return "videoDeviceInUseByAnotherClient(\(rawInt))"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: return "videoDeviceNotAvailableWithMultipleForegroundApps(\(rawInt))"
        case .videoDeviceNotAvailableDueToSystemPressure: return "videoDeviceNotAvailableDueToSystemPressure(\(rawInt))"
        case .sensitiveContentMitigationActivated: return "sensitiveContentMitigationActivated(\(rawInt))"
        @unknown default: return "unknown(\(rawInt))"
        }
    }

    private static var videoDeviceTypes: [AVCaptureDevice.DeviceType] {
        [
            .external,
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera,
            .builtInDualCamera,
            .builtInDualWideCamera,
            .builtInTripleCamera,
            .builtInTrueDepthCamera
        ]
    }

    private enum MultiCamError: LocalizedError {
        case notSupported
        case liveCameraUnavailable
        case externalCameraUnavailable
        case requestedDeviceUnavailable(String, String)
        case emptyGraph
        case devicePairUnsupported(String)
        case cannotAddLiveInput
        case cannotAddOCRInput
        case liveVideoPortMissing
        case ocrVideoPortMissing
        case cannotAddLiveOutput
        case cannotAddOCROutput
        case cannotConnectLiveOutput
        case cannotConnectOCROutput
        case noSupportedMultiCamFormat(String)
        case requestedFormatUnavailable(String, String)
        case formatConfigurationFailed(String)
        case hardwareCostExceeded(Double)
        case systemPressureCostTooHigh(Double)

        var errorDescription: String? {
            switch self {
            case .notSupported:
                return "This iPad does not support AVCaptureMultiCamSession."
            case .liveCameraUnavailable:
                return "No Broadcast camera is currently discoverable."
            case .externalCameraUnavailable:
                return "The selected OCR camera is not currently discoverable."
            case .requestedDeviceUnavailable(let role, let id):
                return "The selected \(role) physical camera is no longer available (\(id)). Refresh camera sources and select it again."
            case .emptyGraph:
                return "The CaptureEngine graph has no configured camera branch."
            case .devicePairUnsupported(let sets):
                return sets.isEmpty
                    ? "The selected Broadcast and OCR cameras are not a supported simultaneous camera pair."
                    : "The selected Broadcast and OCR cameras are not a supported simultaneous pair. Supported sets: \(sets)"
            case .cannotAddLiveInput: return "The Broadcast camera input could not be added to MultiCam."
            case .cannotAddOCRInput: return "The OCR camera input could not be added to MultiCam."
            case .liveVideoPortMissing: return "The Broadcast camera has no video input port."
            case .ocrVideoPortMissing: return "The OCR camera has no video input port."
            case .cannotAddLiveOutput: return "The Broadcast video output could not be added to MultiCam."
            case .cannotAddOCROutput: return "The OCR video output could not be added to MultiCam."
            case .cannotConnectLiveOutput: return "The Broadcast camera could not connect to its MultiCam output."
            case .cannotConnectOCROutput: return "The OCR camera could not connect to its MultiCam output."
            case .noSupportedMultiCamFormat(let device):
                return "No format on \(device) is explicitly marked as MultiCam supported."
            case .requestedFormatUnavailable(let device, let mode):
                return "\(device) does not expose the selected CaptureEngine mode \(mode). Refresh formats and choose another resolution/frame rate."
            case .formatConfigurationFailed(let detail):
                return "MultiCam format configuration failed: \(detail)"
            case .hardwareCostExceeded(let cost):
                return String(format: "MultiCam hardware cost %.2f is not runnable; it must remain below 1.0.", cost)
            case .systemPressureCostTooHigh(let cost):
                return String(format: "MultiCam system pressure cost %.2f is too high for sustained full-game capture.", cost)
            }
        }
    }
}

// MARK: - MultiCam preview host

struct ExternalOCRMultiCamPreviewView: UIViewRepresentable {
    let coordinator: ExternalOCRMultiCamCoordinator
    var role: RinkLensCapturePreviewRole = .broadcast
    var rotationOffsetDegrees: CGFloat = 0
    var onAttached: ((String) -> Void)? = nil
    var onDetached: (() -> Void)? = nil
    var onHeartbeat: ((Bool, String) -> Void)? = nil

    func makeUIView(context: Context) -> ExternalOCRMultiCamPreviewHostView {
        if role == .broadcast {
            RinkLensRoutePerformanceProbe.shared.mark(.previewMakeUIViewStarted, route: .broadcast, source: "ExternalOCRMultiCamPreviewView.makeUIView")
        }
        let view = ExternalOCRMultiCamPreviewHostStore.shared.view(
            for: role.stableHostKey,
            session: coordinator.session
        )
        view.onAttached = onAttached
        view.onDetached = onDetached
        view.onHeartbeat = onHeartbeat
        view.previewLayer.videoGravity = .resizeAspect
        view.attach(
            coordinator: coordinator,
            role: role,
            rotationAngle: normalizedAngle(rotationOffsetDegrees)
        )
        if role == .broadcast {
            RinkLensRoutePerformanceProbe.shared.mark(.previewMakeUIViewCompleted, route: .broadcast, source: "ExternalOCRMultiCamPreviewView.makeUIView")
        }
        return view
    }

    func updateUIView(_ uiView: ExternalOCRMultiCamPreviewHostView, context: Context) {
        uiView.onAttached = onAttached
        uiView.onDetached = onDetached
        uiView.onHeartbeat = onHeartbeat
        uiView.previewLayer.videoGravity = .resizeAspect
        uiView.attach(
            coordinator: coordinator,
            role: role,
            rotationAngle: normalizedAngle(rotationOffsetDegrees)
        )
    }

    static func dismantleUIView(_ uiView: ExternalOCRMultiCamPreviewHostView, coordinator: ()) {
        uiView.noteSwiftUIDismantle()
    }

    private func normalizedAngle(_ angle: CGFloat) -> CGFloat {
        var value = angle.truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        return value
    }
}

@MainActor
final class ExternalOCRMultiCamPreviewHostStore {
    static let shared = ExternalOCRMultiCamPreviewHostStore()
    private var views: [String: ExternalOCRMultiCamPreviewHostView] = [:]

    func view(for key: String, session: AVCaptureMultiCamSession) -> ExternalOCRMultiCamPreviewHostView {
        if let existing = views[key] { return existing }
        let view = ExternalOCRMultiCamPreviewHostView(session: session)
        views[key] = view
        return view
    }

    func existingView(for key: String) -> ExternalOCRMultiCamPreviewHostView? {
        views[key]
    }
}

@MainActor
private final class RinkLensContinuityLayerDisplayDelegate: NSObject, CALayerDelegate {
    var onDisplay: ((CALayer) -> Void)?

    func display(_ layer: CALayer) {
        onDisplay?(layer)
    }
}

final class ExternalOCRMultiCamPreviewHostView: UIView {
    let previewLayer: AVCaptureVideoPreviewLayer
    private let continuityLayer = CALayer()
    private let continuityLayerDisplayDelegate = RinkLensContinuityLayerDisplayDelegate()
    private var continuityTransactionID: UUID?
    private var continuityPendingImage: CGImage?
    private var continuityDisplayPassContinuation: CheckedContinuation<Bool, Never>?
    weak var captureCoordinator: ExternalOCRMultiCamCoordinator?
    var onAttached: ((String) -> Void)?
    var onDetached: (() -> Void)?
    var onHeartbeat: ((Bool, String) -> Void)?
    private var previewRole: RinkLensCapturePreviewRole = .broadcast
    private var lastRotationAngle: CGFloat = -1
    private weak var lastCoordinator: ExternalOCRMultiCamCoordinator?
    private var lastRole: RinkLensCapturePreviewRole?
    private var lastReportedAttached = false
    private var lastReportedReady: Bool?
    private var lastReportedFrameText = ""

    init(session: AVCaptureMultiCamSession) {
        previewLayer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
        super.init(frame: .zero)
        layer.addSublayer(previewLayer)
        continuityLayer.contentsGravity = .resizeAspect
        continuityLayer.backgroundColor = UIColor.black.cgColor
        continuityLayer.isHidden = true
        continuityLayerDisplayDelegate.onDisplay = { [weak self] layer in
            self?.displayContinuityLayer(layer)
        }
        continuityLayer.delegate = continuityLayerDisplayDelegate
        layer.addSublayer(continuityLayer)
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
        continuityLayer.frame = bounds
        reportPreviewStateIfChanged()
    }

    /// Display-pass acknowledgement for an optical handoff. The layer delegate
    /// installs the exact transaction-owned raster during a visible CALayer
    /// display pass before the lifecycle owner may replace the camera branch.
    /// Physical scanout remains an iPad acceptance-test boundary.
    func presentContinuityImage(_ image: CGImage, transactionID: UUID) async -> Bool {
        guard window != nil, !bounds.isEmpty else { return false }
        return await withCheckedContinuation { continuation in
            continuityDisplayPassContinuation?.resume(returning: false)
            continuityDisplayPassContinuation = continuation
            continuityPendingImage = image
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            continuityTransactionID = transactionID
            continuityLayer.frame = bounds
            continuityLayer.isHidden = false
            continuityLayer.setNeedsDisplay()
            continuityLayer.displayIfNeeded()
            CATransaction.commit()
            // displayIfNeeded is synchronous for this attached host. Reject
            // rather than allowing an unacknowledged replacement if UIKit did
            // not ask the transaction-owned layer to display.
            if continuityDisplayPassContinuation != nil {
                completeContinuityDisplayPass(transactionID: transactionID, admitted: false)
            }
        }
    }

    private func displayContinuityLayer(_ layer: CALayer) {
        guard layer === continuityLayer,
              let image = continuityPendingImage,
              let transactionID = continuityTransactionID else { return }
        continuityLayer.contents = image
        let admitted = window != nil
            && !bounds.isEmpty
            && !continuityLayer.isHidden
        completeContinuityDisplayPass(transactionID: transactionID, admitted: admitted)
    }

    private func completeContinuityDisplayPass(transactionID: UUID, admitted: Bool) {
        guard continuityTransactionID == transactionID,
              let continuation = continuityDisplayPassContinuation else { return }
        continuityDisplayPassContinuation = nil
        continuityPendingImage = nil
        continuation.resume(returning: admitted)
    }

    func removeContinuityImage(transactionID: UUID) {
        guard continuityTransactionID == transactionID else { return }
        completeContinuityDisplayPass(transactionID: transactionID, admitted: false)
        continuityLayer.removeAnimation(forKey: "rinklens.optical-continuity-release")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        continuityLayer.opacity = 1
        continuityLayer.isHidden = true
        continuityLayer.contents = nil
        continuityTransactionID = nil
        CATransaction.commit()
    }

    /// Crossfades only the presentation raster. CaptureEngine continues to own
    /// the physical incoming zoom, and the continuity store retains transaction
    /// ownership until Core Animation completes this bounded release.
    func releaseContinuityImage(
        transactionID: UUID,
        duration: TimeInterval,
        completion: @escaping @MainActor () -> Void
    ) {
        guard continuityTransactionID == transactionID else {
            completion()
            return
        }
        completeContinuityDisplayPass(transactionID: transactionID, admitted: false)
        guard duration > 0 else {
            removeContinuityImage(transactionID: transactionID)
            completion()
            return
        }

        continuityLayer.removeAnimation(forKey: "rinklens.optical-continuity-release")
        let release = CABasicAnimation(keyPath: "opacity")
        release.fromValue = continuityLayer.presentation()?.opacity ?? continuityLayer.opacity
        release.toValue = 0
        release.duration = duration
        release.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self else {
                completion()
                return
            }
            if self.continuityTransactionID == transactionID {
                self.removeContinuityImage(transactionID: transactionID)
            }
            completion()
        }
        continuityLayer.opacity = 0
        continuityLayer.add(release, forKey: "rinklens.optical-continuity-release")
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            captureCoordinator?.attachPreviewLayer(
                previewLayer,
                role: previewRole,
                rotationAngle: max(0, lastRotationAngle),
                reason: "\(previewRole.displayName) preview host moved to window"
            )
        }
        reportPreviewStateIfChanged(force: true)
    }

    func attach(
        coordinator: ExternalOCRMultiCamCoordinator,
        role: RinkLensCapturePreviewRole,
        rotationAngle: CGFloat
    ) {
        let coordinatorChanged = lastCoordinator !== coordinator
        let roleChanged = lastRole != role
        let rotationChanged = abs(lastRotationAngle - rotationAngle) > 0.01
        captureCoordinator = coordinator
        previewRole = role
        lastCoordinator = coordinator
        lastRole = role
        lastRotationAngle = rotationAngle

        // Stage 2 keeps one persistent endpoint per camera branch. SwiftUI may
        // refresh this representable frequently, so graph mutation is idempotent.
        if coordinatorChanged
            || roleChanged
            || rotationChanged
            || !coordinator.previewAttachedSnapshot(for: role) {
            coordinator.attachPreviewLayer(
                previewLayer,
                role: role,
                rotationAngle: rotationAngle,
                reason: "SwiftUI \(role.displayName) MultiCam preview configure"
            )
        }
        reportPreviewStateIfChanged()
    }

    func noteSwiftUIDismantle() {
        // Endpoint connections intentionally survive route presentation changes.
        // Capture ownership remains with the MultiCam engine; only visibility changes.
        if window == nil { reportPreviewStateIfChanged(force: true) }
    }

    private func reportPreviewStateIfChanged(force: Bool = false) {
        let attached = window != nil && superlayerAttached
        let ready = attached
            && bounds.width > 1
            && bounds.height > 1
            && previewLayer.bounds.width > 1
            && previewLayer.bounds.height > 1
            && previewLayer.connection?.isEnabled == true
        let text = frameDescription
        let changed = force || attached != lastReportedAttached || ready != lastReportedReady || text != lastReportedFrameText
        guard changed else { return }

        if attached && !lastReportedAttached {
            onAttached?(text)
        } else if !attached && lastReportedAttached {
            onDetached?()
        }
        onHeartbeat?(ready, text)
        lastReportedAttached = attached
        lastReportedReady = ready
        lastReportedFrameText = text
    }

    private var superlayerAttached: Bool {
        previewLayer.superlayer === layer
    }

    private var frameDescription: String {
        "role=\(previewRole.rawValue) layer=\(Int(previewLayer.bounds.width))x\(Int(previewLayer.bounds.height)) view=\(Int(bounds.width))x\(Int(bounds.height)) session=\(previewLayer.session == nil ? "none" : "assigned")"
    }
}

/// Architectural name used by the app composition root. The existing concrete
/// type name is retained to avoid a broad source rename and rebuild.
typealias RinkLensCaptureEngine = ExternalOCRMultiCamCoordinator

#endif
