// BUILD 706 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
@preconcurrency import Combine
@preconcurrency import AVFoundation
import Vision
@preconcurrency import CoreMedia
import CoreGraphics
@preconcurrency import CoreVideo
import UIKit
import CoreImage
import PhotosUI
import Foundation

#if canImport(MLKitVision) && canImport(MLKitTextRecognition) && canImport(MLKitTextRecognitionLatin)
import MLKitVision
import MLKitTextRecognition
import MLKitTextRecognitionLatin
#endif

struct RecordingCameraFrameSnapshot {
    let image: UIImage
    let capturedAt: Date
    let sequence: Int
    let width: Int
    let height: Int

    var ageSeconds: TimeInterval { Date().timeIntervalSince(capturedAt) }
    var sizeText: String { "\(width)x\(height)" }
}


/// v0.9.1w10: lightweight 60fps recording source snapshot.
///
/// The older recording frame cache converted camera samples to UIImage before the
/// recorder could use them. On iPad8,9 that conversion path topped out around
/// 32–38 unique frames/sec, so the writer produced a 60fps file by duplicating
/// frames. This snapshot retains the latest CVPixelBuffer directly from the
/// AVCaptureVideoDataOutput delegate. The recorder can then render from the
/// real camera sample cadence instead of the slower preview/UIImage cache.
struct RecordingCameraPixelBufferSnapshot {
    let pixelBuffer: CVPixelBuffer
    let capturedAt: Date
    let sequence: Int
    let width: Int
    let height: Int

    var ageSeconds: TimeInterval { Date().timeIntervalSince(capturedAt) }
    var sizeText: String { "\(width)x\(height)" }
}

/// Inert source-compatibility shell retained while camera settings are still
/// exposed through `HockeyCameraService`. It is deliberately not an
/// `AVCaptureSession`; therefore two service instances cannot allocate capture
/// inputs, produce session notifications or compete with CaptureEngine.
nonisolated private final class RinkLensDisabledLegacyCaptureSession {
    var isRunning: Bool { false }
    var inputs: [AVCaptureInput] { [] }
    var outputs: [AVCaptureOutput] { [] }

    func stopRunning() {}
    func beginConfiguration() {}
    func commitConfiguration() {}
    func removeInput(_ input: AVCaptureInput) {}
    func canAddOutput(_ output: AVCaptureOutput) -> Bool { false }
    func addOutput(_ output: AVCaptureOutput) {}
    func removeOutput(_ output: AVCaptureOutput) {}
}

// UX16d2: recording/capture mutation policy moved to
// RinkLensRecordingCaptureLease in 121_CaptureLifecycleController.swift.

// MARK: - Camera


/// Queue-owned camera compatibility service.
///
/// The service remains nonisolated because AVFoundation callbacks and the
/// compatibility queues are not MainActor-owned. ObservableObject publication
/// is emitted manually on the main queue; stored properties are deliberately
/// plain Swift properties so Swift 6 does not infer unsupported nonisolated
/// property-wrapper storage.
@preconcurrency nonisolated final class HockeyCameraService: NSObject, ObservableObject, @unchecked Sendable {
    nonisolated enum BroadcastCameraParameterToggleResult: Sendable {
        case locked([String])
        case automatic
        case unavailable(String)
        case failed(String)
    }

    let objectWillChange = ObservableObjectPublisher()

    private let objectWillChangeLock = NSLock()
    private var objectWillChangePending = false

    /// Coalesces queue-originated compatibility-state changes into one main-queue
    /// ObservableObject notification. Capture ownership remains with CaptureEngine;
    /// this publisher exists only for legacy settings/diagnostics UI state.
    private func publishObjectWillChange() {
        objectWillChangeLock.lock()
        guard !objectWillChangePending else {
            objectWillChangeLock.unlock()
            return
        }
        objectWillChangePending = true
        objectWillChangeLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.objectWillChangeLock.lock()
            self.objectWillChangePending = false
            self.objectWillChangeLock.unlock()
            self.objectWillChange.send()
        }
    }
    enum DefaultCameraPreference {
        case externalFirst
        case builtInBackFirst
        /// v0.9.0n2f: Broadcast should start on the widest rear lens when available.
        /// On iPads with an ultra-wide rear camera this gives the operator the true wide view
        /// before applying digital zoom.
        case builtInUltraWideBackFirst
    }

    nonisolated enum OperationalRole: String, Sendable {
        case broadcast = "Broadcast"
        case ocr = "OCR"

        var defaultFPS: Int { self == .broadcast ? 60 : 30 }
        var defaultProfileText: String { "1920x1080 @ \(defaultFPS)fps Auto" }
    }

    struct CameraOption: Identifiable, Hashable {
        let id: String
        let name: String
        let isExternal: Bool
        /// Physical discovery truth for this logical source. Logical rows remain
        /// stable while this value changes; availability must never rewrite the
        /// operator-owned selectedCameraID.
        let isAvailable: Bool
        let position: AVCaptureDevice.Position
    }

    // UX16c8: Picker identity is a logical camera source, not a transient
    // AVCaptureDevice uniqueID. iPad rear virtual/constituent cameras can expose
    // different physical IDs depending on whether an external device is present.
    // Stable source IDs stop the SwiftUI Picker selection disappearing after a
    // discovery refresh or rear-lens resolution change.
    static let builtInBackCameraSourceID = "__RINKLENS_CAMERA_BUILTIN_BACK__"
    static let builtInFrontCameraSourceID = "__RINKLENS_CAMERA_BUILTIN_FRONT__"
    static let externalCameraSourceID = "__RINKLENS_CAMERA_EXTERNAL__"

    struct VideoFormatOption: Identifiable, Hashable {
        let id: String
        let label: String
    }

    struct CapabilityProfileOption: Identifiable, Hashable {
        let id: String
        let tierLabel: String
        let cadence: RinkLensCaptureCadence
        let width: Int32
        let height: Int32
        let formatID: String?
        let resolutionLabel: String?
        let isCommonRate: Bool

        var fps: Double { cadence.framesPerSecond }
        var nominalFPS: Int { cadence.nominalFPS }
        var isAvailable: Bool { formatID != nil }
        var displayLabel: String {
            resolutionLabel ?? "\(width)x\(height) at \(cadence.displayText) fps"
        }

        var capturePreference: RinkLensCaptureFormatPreference {
            RinkLensCaptureFormatPreference(width: width, height: height, cadence: cadence)
        }
    }


    /// Complete operator selection snapshot used by CaptureLifecycleController
    /// to roll back a failed stop-reconfigure-resume transaction. Runtime
    /// AVCaptureDevice/Input objects are deliberately not retained; restore resolves
    /// a fresh device by physical/logical identity and leaves the legacy private
    /// session unconfigured.
    /// UX16c42 separates the operator's stable logical choice, its preferred
    /// resolved physical device, and the physical device currently owned by
    /// CaptureEngine. Runtime release may clear only `activePhysicalDeviceID`.
    nonisolated struct CaptureIdentitySnapshot: Sendable, Equatable {
        let selectedLogicalSourceID: String?
        let preferredResolvedPhysicalDeviceID: String?
        let activePhysicalDeviceID: String?

        var diagnosticText: String {
            "logical=\(selectedLogicalSourceID ?? "none") preferred=\(preferredResolvedPhysicalDeviceID ?? "none") active=\(activePhysicalDeviceID ?? "none")"
        }
    }

    struct CaptureSelectionSnapshot {
        let preferredCameraID: String?
        let cameraSelectionDisabledByUser: Bool
        let preferredVideoFormatID: String?
        let preferredVideoFormatIDByCameraID: [String: String]
        let preferredVideoFrameRate: Int?
        let preferredVideoFrameRateByCameraID: [String: Int]
        let captureFormatPreferenceOverride: RinkLensCaptureFormatPreference?
        let captureFormatPreferenceByCameraID: [String: RinkLensCaptureFormatPreference]
        let appleStyleAutoQualityCaptureEnabled: Bool

        let selectedCameraID: String?
        let resolvedCameraDeviceID: String?
        let isCameraSelectionDisabled: Bool
        let selectedCameraName: String
        let selectedCameraIsExternal: Bool
        let selectedCameraPosition: AVCaptureDevice.Position
        let availableVideoFormats: [VideoFormatOption]
        let selectedVideoFormatID: String?
        let videoFormatsLoaded: Bool
        let videoFormatLoadStatusText: String
        let capabilityProfiles: [CapabilityProfileOption]
        let selectedCapabilityProfileID: String?
        let selectedResolutionFPS: String
        let appleStyleAutoQualityEnabled: Bool
        let cameraStatusText: String
        let sessionResourceStateText: String
        let captureGraphStatusText: String
    }

    enum VideoCompressionProfile: String, CaseIterable {
        case highEfficiency = "High Efficiency"
        case mostCompatible = "Most Compatible"

        var detailText: String {
            switch self {
            case .highEfficiency:
                return "High Efficiency format (HEVC) allows for same quality with much smaller file sizes."
            case .mostCompatible:
                return "Most Compatible uses H.264 and should play on the widest range of platforms."
            }
        }
    }

    enum CameraError: LocalizedError {
        case noCameraSelected
        case noCameraDevice
        case cannotCreateInput
        case cannotAddInput
        case cannotAddOutput
        case incompleteSessionGraph

        var errorDescription: String? {
            switch self {
            case .noCameraSelected:
                return "No camera selected"
            case .noCameraDevice:
                return "No camera device available"
            case .cannotCreateInput:
                return "Could not create camera input"
            case .cannotAddInput:
                return "Could not add camera input"
            case .cannotAddOutput:
                return "Could not add camera output"
            case .incompleteSessionGraph:
                return "Camera session has no usable input/output graph"
            }
        }
    }

    private let session = RinkLensDisabledLegacyCaptureSession()
    private let legacyPrivateCaptureDisabled = true
    private let defaultCameraPreference: DefaultCameraPreference
    /// When false this service is preview-layer only for OCR purposes.
    /// v0.8.6e adds an optional low-rate recording frame tap so the recorder
    /// can capture real camera frames without enabling OCR delivery.
    private let sampleBufferOutputEnabled: Bool
    private var recordingFrameCaptureEnabled: Bool = false
    var isPreviewOnlySession: Bool { !sampleBufferOutputEnabled }
    private let videoOutput = AVCaptureVideoDataOutput()
    // Dedicated queue for all AVCaptureSession start/stop/reconfigure work.
    // Never call startRunning/stopRunning from SwiftUI body/onAppear/onChange.
    private let outputQueue: DispatchQueue
    private var isConfigured = false
    private var isRestartingCamera = false
    private var isStartRunningInProgress = false
    private var lastStartRunningAcceptedAt: Date = .distantPast
    private var lastStartRunningFailedAt: Date = .distantPast
    private let minimumStartRunningRequestInterval: TimeInterval = 0.75
    private let minimumFailedStartRetryInterval: TimeInterval = 2.0
    private var lastCameraRestartTime: Date = .distantPast
    private let minimumRestartInterval: TimeInterval = 5.0
    private let unhealthyFrameThreshold: TimeInterval = 2.5
    private var lastFrameReceivedForHealth: Date = Date()
    // Keep internal health updated on every frame, but publish SwiftUI updates
    // at a low rate. Publishing observed UI state for every frame from two
    // cameras can make the UI unresponsive and destabilise preview layers.
    private var lastHealthUIPublishAt: CFAbsoluteTime = 0
    private let healthUIPublishInterval: CFTimeInterval = 3.0
    private var hasPublishedFirstFrameToUI = false
    private var lastPreviewLayerHeartbeatAt: Date = .distantPast
    private var lastPreviewLayerReattachAt: Date = .distantPast
    private let previewLayerReattachCooldown: TimeInterval = 3.0
    private var lastPreviewLayerUIPublishAt: CFAbsoluteTime = 0
    private var diagnosticsPublishingVisible: Bool = false
    private let previewLayerUIPublishInterval: CFTimeInterval = 2.0
    private let previewLayerHiddenUIPublishInterval: CFTimeInterval = 4.0
    private let previewLayerDiagnosticsUIPublishInterval: CFTimeInterval = 1.0
    // Automatic no-frame watchdog/recovery is intentionally disabled.
    // Camera recovery must only happen after an explicit operator action.
    private var cameraDevice: AVCaptureDevice?
    private var currentInput: AVCaptureDeviceInput?
    private var preferredCameraID: String?
    private var cameraSelectionDisabledByUser = false
    /// Queue-owned epoch fencing delayed MainActor selection publications. A
    /// transactional rollback increments this value so stale staging callbacks
    /// cannot overwrite the restored UI selection after an await.
    private var captureSelectionPublicationEpoch: UInt64 = 0

    // UX16c21: External USB cameras can briefly disappear and return with the
    // same uniqueID but a different AVCaptureDevice object. Treat that as a
    // mandatory input rebind rather than trusting the stale cached input.
    private var externalReconnectGeneration: Int = 0
    private var externalReconnectPending: Bool = false
    private var lastDisconnectedExternalDeviceID: String?
    private let externalReconnectDebounce: TimeInterval = 0.65

    // UX16c23: When Broadcast and external OCR run together, one
    // AVCaptureMultiCamSession owns both physical devices. These fields let the
    // existing camera services continue to provide settings, health, OCR delivery
    // and recording caches without starting a second competing capture session.
    private let externalCaptureOwnerLock = NSLock()
    private var externalCaptureOwnerActive = false
    private var externalCaptureOwnerReserved = false
    private weak var externalCaptureOwnerDevice: AVCaptureDevice?
    private var externalCaptureOwnerName = "none"

    // UX16c20 forensic identity. These IDs prove whether Settings, the active
    // AVCaptureSession, the preview layer and exported diagnostics refer to the
    // same service/session instance.
    let diagnosticInstanceID = String(UUID().uuidString.prefix(8))
    private var firstFrameBreadcrumbRecorded = false
    private var lastPreviewReadyBreadcrumbState: Bool?
    private var lastPreviewSessionAssignedBreadcrumbState: Bool?

    var diagnosticIdentityText: String {
        "service=\(diagnosticInstanceID) role=\(sampleBufferOutputEnabled ? "OCR" : "Broadcast") session=\(String(ObjectIdentifier(session).hashValue, radix: 16))"
    }

    private var diagnosticTraceOwner: CameraTraceOwner {
        sampleBufferOutputEnabled ? .ocrCamera : .liveCamera
    }

    private func cameraBreadcrumb(_ action: CameraTraceAction, phase: String, extra: String = "") {
        let graph = captureGraphSnapshot()
        let sessionID = String(ObjectIdentifier(session).hashValue, radix: 16)
        let inputID = currentInput?.device.uniqueID ?? "none"
        let deviceID = cameraDevice?.uniqueID ?? "none"
        let selected = selectedCameraID ?? "none"
        let preferred = preferredCameraID ?? "none"
        let suffix = extra.isEmpty ? "" : " | \(extra)"
        let text = "svc=\(diagnosticInstanceID) sess=\(sessionID) role=\(sampleBufferOutputEnabled ? "OCR" : "Broadcast") phase=\(phase) selected=\(selected) preferred=\(preferred) device=\(deviceID) input=\(inputID) disabled=\(cameraSelectionDisabledByUser) reconfig=\(isRestartingCamera) previewRequired=\(previewRequiredForActiveRoute) frames=\(framesReceivedTotal) graph={\(graph.detail)}\(suffix)"
        CameraOwnershipTraceStore.record(action, owner: diagnosticTraceOwner, reason: text)
    }

    private var preferredVideoFormatID: String?
    private var preferredVideoFormatIDByCameraID: [String: String] = [:]
    // UX13e: manual resolution/FPS selection stores the requested cadence separately
    // from the AVFoundation format ID because one format can support several FPS values.
    private var preferredVideoFrameRate: Int?
    private var preferredVideoFrameRateByCameraID: [String: Int] = [:]
    /// Exact size/FPS requested by the operator or a copied Calibration profile.
    /// CaptureEngine validates this against the resolved physical device. Keeping
    /// it independently from AVFoundation format object identity avoids carrying
    /// a stale format ID between logical camera sources.
    private var captureFormatPreferenceOverride: RinkLensCaptureFormatPreference?
    /// Exact cadence/size is retained per physical camera so switching away and
    /// back cannot silently round 29.97/59.94 to the legacy nominal integer.
    private var captureFormatPreferenceByCameraID: [String: RinkLensCaptureFormatPreference] = [:]
    private var compressionProfile: VideoCompressionProfile = .highEfficiency
    private var videoFormatMap: [String: AVCaptureDevice.Format] = [:]
    /// Build 705 keeps the format selected by AVFoundation when each internal
    /// camera is first attached. Auto mode restores this native device choice
    /// instead of forcing a recording-oriented 1080p/60 format.
    private var nativeAutomaticFormatByCameraID: [String: AVCaptureDevice.Format] = [:]
    private(set) var minZoomFactor: CGFloat = 1.0
    private(set) var maxZoomFactor: CGFloat = 5.0
    private var zoomFactorByCameraID: [String: CGFloat] = [:]
    private enum BroadcastZoomLensTarget: String {
        case ultraWide = "UltraWide"
        case wide = "Wide"
    }
    // v0.9.0n3l: hard guard to stop rapid live-slider lens switches from
    // repeatedly stopping/starting the capture session. The slider can still
    // update immediately, but a physical lens/session rebuild is throttled.
    // v0.9.0n3m: after a physical lens switch the new sensor needs a short
    // settle window. Suppress preview recovery/reset during this window so a
    // successful switch is not immediately followed by a manual recovery rebuild.
    private var suppressPreviewRecoveryUntil: Date = .distantPast
    private(set) var currentZoomFactor: CGFloat = 1.0 { willSet { publishObjectWillChange() } }
    /// v0.9.0n3: What the operator sees should be what gets recorded.
    /// Keep enabled by default; recording should use the active live/broadcast camera frame.
    var matchViewToRecordingEnabled: Bool = true { willSet { publishObjectWillChange() } }
    /// Automatic lens-control mode. This cannot copy the hidden
    /// Apple Camera app profile, but it keeps AVFoundation in automatic focus/exposure/white balance,
    /// picks a strong default format, and hides advanced controls in the UI.
    /// Build 720 compatibility name: this now means automatic focus, exposure and
    /// white balance only. It no longer claims to inherit Apple Camera app settings.
    var appleStyleAutoQualityEnabled: Bool = true { willSet { publishObjectWillChange() } }
    private(set) var roleDefaultProfileEnabled: Bool = true { willSet { publishObjectWillChange() } }
    // Queue-owned runtime copies. Camera format and lens automation are separate.
    private var appleStyleAutoQualityCaptureEnabled: Bool = true
    private var roleDefaultProfileCaptureEnabled: Bool = true

    var operationalRole: OperationalRole { sampleBufferOutputEnabled ? .ocr : .broadcast }
    var roleDefaultFPS: Int { operationalRole.defaultFPS }
    var roleDefaultProfileText: String { operationalRole.defaultProfileText }

    var hasAnyAutomaticLensControl: Bool {
        supportsAutoFocus || supportsAutoExposure || supportsAutoWhiteBalance
    }

    var automaticLensCapabilityText: String {
        var available: [String] = []
        if supportsAutoFocus { available.append("focus") }
        if supportsAutoExposure { available.append("exposure") }
        if supportsAutoWhiteBalance { available.append("white balance") }
        guard !available.isEmpty else { return "Automatic focus, exposure and white balance are unavailable on this camera." }
        return "Automatic controls available: " + available.joined(separator: ", ") + "."
    }
    private(set) var hasReceivedFrames: Bool = false { willSet { publishObjectWillChange() } }
    private(set) var lastFrameReceivedAt: Date? = nil { willSet { publishObjectWillChange() } }
    private(set) var visibleCameraHealthy: Bool = true { willSet { publishObjectWillChange() } }
    private(set) var previewResetToken: Int = 0 { willSet { publishObjectWillChange() } }
    private(set) var isReconfiguring: Bool = false { willSet { publishObjectWillChange() } }
    private(set) var availableCameras: [CameraOption] = [] { willSet { publishObjectWillChange() } }
    private(set) var isCameraSelectionDisabled: Bool = false { willSet { publishObjectWillChange() } }
    /// Sole logical camera-source selection. Discovery and applied-device updates
    /// may resolve or acknowledge this value, but they must not maintain a second
    /// requested/published copy or replace it from the active physical device.
    private(set) var selectedCameraID: String? = nil { willSet { publishObjectWillChange() } }
    private(set) var selectedCameraName: String = "No camera" { willSet { publishObjectWillChange() } }
    private(set) var selectedCameraIsExternal: Bool = false { willSet { publishObjectWillChange() } }
    private(set) var selectedCameraPosition: AVCaptureDevice.Position = .unspecified { willSet { publishObjectWillChange() } }
    /// Preferred/resolved physical identity for the selected logical source.
    /// This persists while CaptureEngine releases runtime ownership.
    private(set) var resolvedCameraDeviceID: String? = nil { willSet { publishObjectWillChange() } }
    /// Physical device currently active in the process-wide CaptureEngine.
    /// This is runtime truth and is cleared when that engine releases the role.
    private(set) var activeCaptureDeviceID: String? = nil { willSet { publishObjectWillChange() } }
    private(set) var activeCaptureDeviceName: String? = nil { willSet { publishObjectWillChange() } }
    private(set) var activeCaptureDeviceIsExternal: Bool = false { willSet { publishObjectWillChange() } }
    private(set) var activeCaptureDevicePosition: AVCaptureDevice.Position = .unspecified { willSet { publishObjectWillChange() } }
    private(set) var cameraDiscoveryGeneration: Int = 0 { willSet { publishObjectWillChange() } }
    private(set) var cameraDiscoverySummaryText: String = "Camera discovery not run" { willSet { publishObjectWillChange() } }
    private(set) var externalReconnectStatusText: String = "External camera stable" { willSet { publishObjectWillChange() } }
    private(set) var lastFrameLumaText: String = "No frame luminance sample" { willSet { publishObjectWillChange() } }
    // UX16c12: Preserve the real AVFoundation reason when camera input creation
    // fails. Previous builds collapsed permission, device-in-use, disconnect and
    // virtual-device failures into the same generic message.
    private(set) var cameraAuthorizationStatusText: String = "Camera authorization not checked" { willSet { publishObjectWillChange() } }
    private(set) var lastInputCreationErrorText: String = "none" { willSet { publishObjectWillChange() } }
    private(set) var inputCandidateTraceText: String = "none" { willSet { publishObjectWillChange() } }
    // UX16c16: Every ObservableObject publication that can invalidate SwiftUI must
    // occur on the main thread. The camera/session queue remains responsible for
    // AVFoundation work; this diagnostic records when a UI snapshot was rerouted.
    private(set) var cameraUIPublicationThreadText: String = "Main-thread confinement enabled" { willSet { publishObjectWillChange() } }
    // UX16c18: A running AVCaptureSession is not healthy unless it contains the
    // selected input and the required video output. This catches the black-screen
    // state where startRunning succeeded on an empty/stale session graph.
    private(set) var captureGraphStatusText: String = "Capture graph not validated" { willSet { publishObjectWillChange() } }

    /// Display label used by Operator Hub.
    /// Keep this as the operator source, not the physical lens currently used by
    /// AVFoundation. The rear source remains "Built-in Back Camera" even when
    /// a 0.5x zoom request uses the ultra-wide constituent lens internally.
    var selectedCameraLabel: String {
        // RL-034: Pair the active logical label with the sole logical source ID.
        // The cached physical metadata below is an acknowledgement/projection and
        // must never be allowed to rename the operator-owned source selection.
        switch selectedCameraID {
        case Self.builtInBackCameraSourceID:
            return "Built-in Back Camera"
        case Self.builtInFrontCameraSourceID:
            return "Built-in Front Camera"
        case Self.externalCameraSourceID:
            return "External Camera"
        case nil:
            return "No camera"
        default:
            if let option = availableCameras.first(where: { $0.id == selectedCameraID }) {
                return option.name
            }
            return selectedCameraName.isEmpty ? "Unknown Camera" : selectedCameraName
        }
    }

    /// RL-034 derived physical acknowledgement. This is presentation-only and
    /// carries no writable state: HockeyCameraService remains the sole owner of
    /// the applied device controls while the calibration profile remains request
    /// intent only.
    var appliedCameraControlAcknowledgementText: String {
        let deviceID = activeCaptureDeviceID ?? resolvedCameraDeviceID ?? "none"
        let acknowledgement = activeCaptureDeviceID == nil ? "lastAcknowledged" : "active"
        let exposureOwner = (activeCaptureDeviceIsExternal || selectedCameraIsExternal) && !supportsExposureLockOrCustom && !supportsAutoExposure
            ? "uvc-device"
            : "avfoundation"
        return "\(acknowledgement) device=\(deviceID); focus=\(focusModeText); exposure=\(exposureModeText); exposureOwner=\(exposureOwner); whiteBalance=\(whiteBalanceModeText); zoom=\(String(format: "%.4f", Double(currentZoomFactor))); exposureLockSupported=\(supportsExposureLockOrCustom); autoExposureSupported=\(supportsAutoExposure)"
    }

    /// UX16c46 label paired with runtime physical identity. When CaptureEngine
    /// owns the role, UI and diagnostics must describe that active device rather
    /// than a stale logical selection label.
    var effectiveCameraLabel: String {
        guard activeCaptureDeviceID != nil else { return selectedCameraLabel }
        if activeCaptureDeviceIsExternal { return "External Camera" }
        switch activeCaptureDevicePosition {
        case .back: return "Built-in Back Camera"
        case .front: return "Built-in Front Camera"
        default: return activeCaptureDeviceName?.isEmpty == false ? activeCaptureDeviceName! : "Active Camera"
        }
    }

    var effectiveCameraIdentityText: String {
        let identifier = activeCaptureDeviceID ?? resolvedCameraDeviceID ?? selectedCameraID ?? "none"
        return "\(effectiveCameraLabel) [\(identifier)]"
    }

    /// A logical camera remains configured independently of the runtime graph.
    /// CaptureEngine resolves the selected source; the settings facade never
    /// treats the absence of a private input as an operator None choice.
    var hasConfiguredCameraSelection: Bool {
        guard !isCameraSelectionDisabled else { return false }
        if selectedCameraID != nil || resolvedCameraDeviceID != nil { return true }
        return isExternallyManagedCaptureReserved
    }

    /// Compatibility diagnostic only. Runtime lifecycle decisions use the
    /// CaptureEngine snapshot and required first-frame readiness instead.
    var captureGraphHasUsableInput: Bool {
        captureGraphSnapshot().valid
    }

    /// Fresh-frame truth used by operator status. A requested/running flag alone is
    /// insufficient because route handoff can leave OCR logically enabled while no
    /// sample buffers are arriving.
    var hasFreshFrameSnapshot: Bool {
        guard let lastFrameReceivedAt else { return false }
        return Date().timeIntervalSince(lastFrameReceivedAt) <= 3.0
    }
    private(set) var availableVideoFormats: [VideoFormatOption] = [] { willSet { publishObjectWillChange() } }
    private(set) var selectedVideoFormatID: String? = nil { willSet { publishObjectWillChange() } }
    // v0.8.4h: camera format enumeration can be expensive on iPad/USB cameras.
    // Keep it cached and refresh only on explicit operator request rather than
    // every time the camera settings UI appears or the screen changes.
    private(set) var videoFormatsLoaded: Bool = false { willSet { publishObjectWillChange() } }
    private(set) var isLoadingVideoFormats: Bool = false { willSet { publishObjectWillChange() } }
    private(set) var videoFormatLoadStatusText: String = "Formats cached from active camera" { willSet { publishObjectWillChange() } }
    private(set) var capabilityProfiles: [CapabilityProfileOption] = [] { willSet { publishObjectWillChange() } }
    private(set) var selectedCapabilityProfileID: String? = nil { willSet { publishObjectWillChange() } }
    private(set) var selectedCompressionProfile: VideoCompressionProfile = .highEfficiency { willSet { publishObjectWillChange() } }
    private(set) var cameraStatusText: String = "Camera ready" { willSet { publishObjectWillChange() } }
    // UX16c10: Distinguish a saved logical source from hardware that is actively
    // configured into this service's AVCaptureSession. Settings may stage a
    // source while the route is inactive; the visible route activates it later.
    private(set) var sessionResourceStateText: String = "No camera input configured" { willSet { publishObjectWillChange() } }
    private(set) var selectedResolutionFPS: String = "--" { willSet { publishObjectWillChange() } }
    private(set) var focusModeText: String = "Auto Focus" { willSet { publishObjectWillChange() } }
    private(set) var exposureModeText: String = "Auto Exposure" { willSet { publishObjectWillChange() } }
    private(set) var whiteBalanceModeText: String = "Auto White Balance" { willSet { publishObjectWillChange() } }
    private(set) var supportsWhiteBalanceLock: Bool = false { willSet { publishObjectWillChange() } }
    private(set) var supportsAutoWhiteBalance: Bool = false { willSet { publishObjectWillChange() } }
    private(set) var stationaryHardwareLockActive: Bool = false { willSet { publishObjectWillChange() } }
    private(set) var stationaryHardwareLockText: String = "Stationary lock off" { willSet { publishObjectWillChange() } }
    // v0.8.4a: Lightweight lifecycle diagnostics. These are operator-visible
    // so screen/mode changes can be checked without guessing whether a camera
    // session was restarted.
    private(set) var lifecycleRestartCount: Int = 0 { willSet { publishObjectWillChange() } }
    private(set) var lastLifecycleEventText: String = "No camera lifecycle events yet" { willSet { publishObjectWillChange() } }
    private(set) var lastRestartReasonText: String = "No restart yet" { willSet { publishObjectWillChange() } }
    private(set) var lastRestartedAtText: String = "--" { willSet { publishObjectWillChange() } }
    // v0.8.4c: Preview-layer diagnostics and recovery. A preview-only
    // AVCaptureSession can remain running while the SwiftUI/UIView preview layer
    // stops presenting. These fields track and recover the layer only, without
    // rebuilding the camera session, source, format, zoom or OCR camera.
    private(set) var previewLayerAttached: Bool = false { willSet { publishObjectWillChange() } }
    private(set) var previewLayerReadyForDisplay: Bool = false { willSet { publishObjectWillChange() } }
    private(set) var previewLayerReattachCount: Int = 0 { willSet { publishObjectWillChange() } }
    private(set) var previewLayerStaleCount: Int = 0 { willSet { publishObjectWillChange() } }
    private(set) var lastPreviewLayerEventText: String = "Preview layer not attached yet" { willSet { publishObjectWillChange() } }
    private(set) var previewLayerFrameText: String = "layer size unknown" { willSet { publishObjectWillChange() } }
    private(set) var previewSessionAssignedText: String = "session not assigned yet" { willSet { publishObjectWillChange() } }
    // v0.8.8m8: explicit camera ownership/lifecycle diagnostics.
    // These are low-rate operator-visible fields only; they do not change the
    // OCR, recording, media browser or visual layout pipelines.
    private(set) var cameraSessionState: CameraSessionState = .idle { willSet { publishObjectWillChange() } }
    private(set) var cameraDisplayOrientation: CameraDisplayOrientation = .unknown { willSet { publishObjectWillChange() } }
    private(set) var previewMirrored: Bool = false { willSet { publishObjectWillChange() } }
    private(set) var currentPreviewHostID: String = "none" { willSet { publishObjectWillChange() } }
    private(set) var lastPreviewAttachReasonText: String = "No preview host attached yet" { willSet { publishObjectWillChange() } }
    private var lastPreviewAttachmentSignature: CameraPreviewAttachmentSignature?
    private(set) var framePipelineText: String = "no frame pipeline samples yet" { willSet { publishObjectWillChange() } }
    private(set) var whiteScreenDetectorText: String = "no white-screen symptoms detected" { willSet { publishObjectWillChange() } }
    private(set) var previewRequiredForActiveRoute: Bool = true { willSet { publishObjectWillChange() } }
    private(set) var previewExpectationText: String = "Broadcast preview expected" { willSet { publishObjectWillChange() } }
    private var framesReceivedTotal: Int = 0
    private var lastFramePipelinePublishAt: CFAbsoluteTime = 0

    // MARK: - UX16c43 FrameHub-backed recording snapshots
    // Capture owns exactly one CVPixelBuffer slot per role in RinkLensFrameHub.
    // Legacy UIImage/pixel-buffer caches have been removed so the compatibility
    // facade cannot retain a second asynchronous frame queue.
    private let recordingFrameCIContext = CIContext(options: [.cacheIntermediates: false])
    private(set) var recordingFrameSourceText: String = "No recording camera frame cached" { willSet { publishObjectWillChange() } }
    private(set) var recordingFrameSizeText: String = "--" { willSet { publishObjectWillChange() } }
    private(set) var recordingFrameCaptureStatusText: String = "Recording frame tap off" { willSet { publishObjectWillChange() } }
    private(set) var supportsManualFocus: Bool = false { willSet { publishObjectWillChange() } }
    private(set) var supportsAutoFocus: Bool = false { willSet { publishObjectWillChange() } }
    private(set) var supportsManualISO: Bool = false { willSet { publishObjectWillChange() } }
    private(set) var focusPosition: Float = 0.5 { willSet { publishObjectWillChange() } }
    private(set) var isoValue: Float = 0 { willSet { publishObjectWillChange() } }
    private(set) var minISO: Float = 50 { willSet { publishObjectWillChange() } }
    private(set) var maxISO: Float = 800 { willSet { publishObjectWillChange() } }
    private(set) var supportsManualExposureDuration: Bool = false { willSet { publishObjectWillChange() } }
    private(set) var supportsAutoExposure: Bool = false { willSet { publishObjectWillChange() } }
    private(set) var supportsExposureLockOrCustom: Bool = false { willSet { publishObjectWillChange() } }
    private(set) var exposureDurationSeconds: Double = 0 { willSet { publishObjectWillChange() } }
    private(set) var minExposureDurationSeconds: Double = 0 { willSet { publishObjectWillChange() } }
    private(set) var maxExposureDurationSeconds: Double = 0 { willSet { publishObjectWillChange() } }
    private(set) var shutterSpeedText: String = "Auto shutter" { willSet { publishObjectWillChange() } }
    private(set) var supportsExposureBias: Bool = false { willSet { publishObjectWillChange() } }
    private(set) var exposureTargetBiasValue: Float = 0 { willSet { publishObjectWillChange() } }
    private(set) var minExposureTargetBias: Float = 0 { willSet { publishObjectWillChange() } }
    private(set) var maxExposureTargetBias: Float = 0 { willSet { publishObjectWillChange() } }
    private(set) var supportsManualWhiteBalanceGains: Bool = false { willSet { publishObjectWillChange() } }
    private(set) var whiteBalanceTemperature: Float = 5_000 { willSet { publishObjectWillChange() } }
    private(set) var whiteBalanceTint: Float = 0 { willSet { publishObjectWillChange() } }
    private(set) var activeCameraDeviceDetailsText: String = "No active camera" { willSet { publishObjectWillChange() } }
    private(set) var activeCameraFormatDetailsText: String = "No active format" { willSet { publishObjectWillChange() } }
    private(set) var stabilisationStatusText: String = "Requested: Automatic • Supported: Unknown • Applied: Unknown" { willSet { publishObjectWillChange() } }
    private(set) var broadcastImageQualityStatusText: String = "IMAGE QUALITY: WAITING FOR CAMERA" { willSet { publishObjectWillChange() } }
    private(set) var broadcastImageQualityRecommendationText: String = "Camera exposure evidence is not available yet." { willSet { publishObjectWillChange() } }
    private(set) var broadcastActiveLensText: String = "Lens: not resolved" { willSet { publishObjectWillChange() } }
    private(set) var broadcastAppliedCadenceText: String = "Source cadence: not resolved" { willSet { publishObjectWillChange() } }
    private(set) var lowLightBoostStatusText: String = "Low-light boost: unknown" { willSet { publishObjectWillChange() } }
    private(set) var automaticFrameRateStatusText: String = "Auto frame rate: unknown" { willSet { publishObjectWillChange() } }
    private(set) var broadcastImagingCapabilitiesText: String = "Imaging capabilities: awaiting active Broadcast format" { willSet { publishObjectWillChange() } }
    private(set) var supportsTorchControl: Bool = false { willSet { publishObjectWillChange() } }
    private(set) var torchActive: Bool = false { willSet { publishObjectWillChange() } }
    private(set) var torchStatusText: String = "Torch unavailable" { willSet { publishObjectWillChange() } }

    init(
        defaultCameraPreference: DefaultCameraPreference = .externalFirst,
        sampleBufferOutputEnabled: Bool = true,
        queueQoS: DispatchQoS = .userInitiated
    ) {
        self.defaultCameraPreference = defaultCameraPreference
        self.sampleBufferOutputEnabled = sampleBufferOutputEnabled
        self.outputQueue = DispatchQueue(
            label: sampleBufferOutputEnabled ? "camera.ocr.output.queue" : "camera.live.preview.queue",
            qos: queueQoS
        )
        super.init()
        registerDeviceObservers()
        cameraBreadcrumb(.lifecycle, phase: "service init", extra: "queue=\(sampleBufferOutputEnabled ? "camera.ocr.output.queue" : "camera.live.preview.queue")")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func registerDeviceObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(captureDeviceWasConnected(_:)),
            name: AVCaptureDevice.wasConnectedNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(captureDeviceWasDisconnected(_:)),
            name: AVCaptureDevice.wasDisconnectedNotification,
            object: nil
        )
    }

    @objc private func captureDeviceWasConnected(_ notification: Notification) {
        guard let device = notification.object as? AVCaptureDevice,
              device.hasMediaType(.video) else { return }
        // Recovery CY / RL-168: device notifications can be delivered on the
        // main thread. Capture graph diagnostics/discovery are not presentation
        // work, so snapshot only immutable identity here and return immediately.
        let deviceName = device.localizedName
        let deviceID = device.uniqueID
        let deviceType = device.deviceType
        outputQueue.async { [weak self, deviceName, deviceID, deviceType] in
            guard let self else { return }
            self.cameraBreadcrumb(
                .sessionNotification,
                phase: "video device connected; CaptureEngine owns reconnect",
                extra: "name=\(deviceName) id=\(deviceID) type=\(deviceType.rawValue)"
            )
            // Device availability is presentation truth shared by both facades.
            // CaptureEngine still owns every physical graph mutation.
            self.refreshAvailableCameras(reason: "video device connected: \(deviceName)")
            guard deviceType == .external else { return }
            if self.frameHubRole == .broadcast {
                self.cameraBreadcrumb(
                    .sessionNotification,
                    phase: "external OCR device discovery refreshed by Broadcast facade; graph mutation remains CaptureEngine-owned",
                    extra: "name=\(deviceName) id=\(deviceID)"
                )
                return
            }
            DispatchQueue.main.async {
                self.externalReconnectStatusText = "External camera connected; CaptureEngine will reconcile the active mode"
            }
        }
    }

    @objc private func captureDeviceWasDisconnected(_ notification: Notification) {
        guard let device = notification.object as? AVCaptureDevice,
              device.hasMediaType(.video) else { return }
        let deviceName = device.localizedName
        let deviceID = device.uniqueID
        let deviceType = device.deviceType
        outputQueue.async { [weak self, deviceName, deviceID, deviceType] in
            guard let self else { return }
            self.cameraBreadcrumb(
                .sessionNotification,
                phase: "video device disconnected; CaptureEngine owns degradation",
                extra: "name=\(deviceName) id=\(deviceID) type=\(deviceType.rawValue)"
            )
            self.refreshAvailableCameras(reason: "video device disconnected: \(deviceName)")
            guard deviceType == .external else { return }
            if self.frameHubRole == .broadcast {
                self.cameraBreadcrumb(
                    .sessionNotification,
                    phase: "external OCR device discovery refreshed by Broadcast facade; graph mutation remains CaptureEngine-owned",
                    extra: "name=\(deviceName) id=\(deviceID)"
                )
                return
            }
            let selectedDeviceDisconnected = self.preferredCameraID == deviceID
            if selectedDeviceDisconnected {
                self.cameraDevice = nil
            }
            DispatchQueue.main.async {
                if selectedDeviceDisconnected {
                    self.resolvedCameraDeviceID = nil
                }
                self.externalReconnectStatusText = "External camera disconnected; CaptureEngine owns fallback and recovery"
            }
        }
    }

    // Build 766 / RL-011: continuous OCR/Image Relay delivery is bound directly
    // to RinkLensFrameHub. HockeyCameraService remains a camera-control and
    // diagnostics facade and no longer exposes a second frame callback path.
    private let externalFrameSignalLock = NSLock()
    private var externalFrameDrainScheduled = false
    private var lastExternallyProcessedSequence = 0

    private var frameHubRole: RinkLensFrameRole {
        sampleBufferOutputEnabled ? .ocr : .broadcast
    }

    var isExternallyManagedCaptureActive: Bool {
        externalCaptureOwnerLock.lock()
        let active = externalCaptureOwnerActive
        externalCaptureOwnerLock.unlock()
        return active
    }

    var isExternallyManagedCaptureReserved: Bool {
        externalCaptureOwnerLock.lock()
        let reserved = externalCaptureOwnerReserved
        externalCaptureOwnerLock.unlock()
        return reserved
    }

    /// Stage 7 runtime truth. The compatibility AVCaptureSession is never an
    /// application capture owner; only the process-wide CaptureEngine can make
    /// this facade operational.
    var isSessionRunning: Bool {
        isExternallyManagedCaptureActive
    }

    func setExternallyManagedCaptureActive(
        _ active: Bool,
        device: AVCaptureDevice?,
        owner: String,
        retainReservation: Bool = false
    ) {
        let reserved = active || retainReservation
        let nextDevice = reserved ? device : nil
        let nextOwner = reserved ? owner : "none"

        externalCaptureOwnerLock.lock()
        let unchanged = externalCaptureOwnerActive == active
            && externalCaptureOwnerReserved == reserved
            && externalCaptureOwnerDevice?.uniqueID == nextDevice?.uniqueID
            && externalCaptureOwnerName == nextOwner
        externalCaptureOwnerActive = active
        externalCaptureOwnerReserved = reserved
        externalCaptureOwnerDevice = nextDevice
        externalCaptureOwnerName = nextOwner
        externalCaptureOwnerLock.unlock()
        guard !unchanged else { return }

        if !reserved {
            RinkLensFrameHub.shared.clear(
                role: frameHubRole,
                reason: "external capture owner released: \(owner)"
            )
        }

        outputQueue.async { [weak self] in
            guard let self else { return }

            // UX16c42 identity rule:
            // - selectedCameraID is the sole selected logical source;
            // - preferredCameraID is the stable preferred/resolved physical ID;
            // - cameraDevice/activeCaptureDeviceID represent only current runtime ownership.
            // Releasing CaptureEngine must never erase the first two identities.
            if active {
                self.cameraDevice = device
                if self.selectedCameraID == nil, let device {
                    self.selectedCameraID = self.logicalCameraSourceID(for: device)
                }
                if self.preferredCameraID == nil, let device {
                    self.preferredCameraID = device.uniqueID
                }
                self.lastFrameReceivedForHealth = Date()
                self.resetFrameHealthForExplicitReconfigure()
                if let device, device.deviceType == .external {
                    self.restoreAutomaticExposureWhenCurrentStateIsInvalid(
                        on: device,
                        source: "CaptureEngine external OCR owner activation",
                        requestedOperation: "activate external OCR camera"
                    )
                }
            } else {
                self.cameraDevice = nil
                self.currentInput = nil
                self.isConfigured = false
            }

            let selectedLogicalID = self.selectedCameraID
            let preferredResolvedID = self.preferredCameraID
            let activeDeviceID = active ? device?.uniqueID : nil
            let activeDeviceName = active ? device?.localizedName : nil
            let activeDeviceIsExternal = active ? (device?.deviceType == .external) : false
            let activeDevicePosition = active ? (device?.position ?? .unspecified) : .unspecified
            let resourceText = active
                ? "Capture supplied by \(owner): \(device?.localizedName ?? "camera")"
                : "CaptureEngine role released; selected camera retained"
            let statusText = active
                ? (self.sampleBufferOutputEnabled ? "OCR camera connected through MultiCam" : "Broadcast camera connected through MultiCam")
                : (self.sampleBufferOutputEnabled ? "OCR camera selection retained; runtime capture released" : "Broadcast camera selection retained; runtime capture released")

            DispatchQueue.main.async {
                if self.sessionResourceStateText != resourceText { self.sessionResourceStateText = resourceText }
                if self.cameraStatusText != statusText { self.cameraStatusText = statusText }
                if self.selectedCameraID != selectedLogicalID { self.selectedCameraID = selectedLogicalID }
                if self.resolvedCameraDeviceID != preferredResolvedID { self.resolvedCameraDeviceID = preferredResolvedID }
                if self.activeCaptureDeviceID != activeDeviceID { self.activeCaptureDeviceID = activeDeviceID }
                if self.activeCaptureDeviceName != activeDeviceName { self.activeCaptureDeviceName = activeDeviceName }
                if self.activeCaptureDeviceIsExternal != activeDeviceIsExternal { self.activeCaptureDeviceIsExternal = activeDeviceIsExternal }
                if self.activeCaptureDevicePosition != activeDevicePosition { self.activeCaptureDevicePosition = activeDevicePosition }
                if self.visibleCameraHealthy != active { self.visibleCameraHealthy = active }
                self.refreshCameraSettingState(source: active ? "MultiCam owner active" : "MultiCam owner released")
                self.cameraBreadcrumb(
                    .lifecycle,
                    phase: active ? "external capture owner active" : "external capture owner released",
                    extra: "owner=\(owner) selected=\(selectedLogicalID ?? "none") preferred=\(preferredResolvedID ?? "none") active=\(activeDeviceID ?? "none")"
                )
            }
        }
    }

    /// Coalesces CaptureEngine frame notifications without capturing a camera
    /// buffer in a queued closure. The output queue drains the newest FrameHub
    /// slot only; additional callbacks merely replace that capacity-one slot.
    func notifyExternallyManagedFrameAvailable() {
        externalFrameSignalLock.lock()
        guard !externalFrameDrainScheduled else {
            externalFrameSignalLock.unlock()
            return
        }
        externalFrameDrainScheduled = true
        externalFrameSignalLock.unlock()

        outputQueue.async { [weak self] in
            self?.drainLatestExternallyManagedFrame()
        }
    }

    private func drainLatestExternallyManagedFrame() {
        // Recovery AD / RL-064: this facade does not own capture while CaptureEngine
        // is active. It only needs sequence/freshness/size evidence to project
        // compatibility health. Opening the pixel-bearing latestFrame lease here
        // allowed an output-queue suspension to pin one of FrameHub's six owned
        // surfaces even though no image processing occurred.
        let evidence = RinkLensFrameHub.shared.latestEvidence(for: frameHubRole, maxAge: 0.75)
        if let evidence, evidence.sequence != lastExternallyProcessedSequence {
            lastExternallyProcessedSequence = evidence.sequence
            processFrameHubEvidence(evidence, connectionEnabled: true)
        }

        externalFrameSignalLock.lock()
        externalFrameDrainScheduled = false
        externalFrameSignalLock.unlock()

        // A newer frame may have replaced the slot while this drain was running.
        // Recheck with immutable evidence only; never reacquire a pixel lease.
        if let latest = RinkLensFrameHub.shared.latestEvidence(for: frameHubRole, maxAge: 0.75),
           latest.sequence != lastExternallyProcessedSequence {
            notifyExternallyManagedFrameAvailable()
        }
    }

    func stopAndWait(reason: String) async {
        cameraBreadcrumb(.lifecycle, phase: "legacy stop ignored", extra: "CaptureEngine owns runtime reason=\(reason)")
    }

    private func captureGraphSnapshot() -> (valid: Bool, detail: String) {
        if isExternallyManagedCaptureReserved {
            externalCaptureOwnerLock.lock()
            let active = externalCaptureOwnerActive
            let deviceName = externalCaptureOwnerDevice?.localizedName ?? "camera"
            let ownerName = externalCaptureOwnerName
            externalCaptureOwnerLock.unlock()
            return (
                active,
                "valid=\(active) runtimeOwner=\(ownerName) reserved=true device=\(deviceName) privateSessionRemoved=true"
            )
        }

        let selected = hasConfiguredCameraSelection
        return (
            selected,
            "facadeSelection=\(selected) privateSessionRemoved=true source=\(selectedCameraID ?? "none") device=\(resolvedCameraDeviceID ?? cameraDevice?.uniqueID ?? "none")"
        )
    }

    private func publishCaptureGraphStatus(_ snapshot: (valid: Bool, detail: String), source: String) {
        cameraBreadcrumb(.graph, phase: source, extra: snapshot.detail)
        DispatchQueue.main.async {
            self.captureGraphStatusText = "\(source): \(snapshot.detail)"
            if !snapshot.valid {
                MainThreadStallMonitor.shared.trace(
                    RinkLensBuildInfo.traceContext("capture graph invalid source=\(source) \(snapshot.detail)")
                )
            }
        }
    }

    private func ensureCaptureGraphReady(reason: String) throws {
        cameraBreadcrumb(.graph, phase: "ensure graph enter", extra: "reason=\(reason)")
        let before = captureGraphSnapshot()
        if isConfigured && before.valid {
            publishCaptureGraphStatus(before, source: "validated before start")
            cameraBreadcrumb(.graph, phase: "ensure graph already valid", extra: "reason=\(reason)")
            return
        }

        if session.isRunning {
            CameraOwnershipTraceStore.record(
                .stopRunning,
                owner: sampleBufferOutputEnabled ? .ocrCamera : .liveCamera,
                reason: "UX16c18 rebuild incomplete capture graph: \(reason)"
            )
            session.stopRunning()
        }

        isConfigured = false
        currentInput = nil
        publishCaptureGraphStatus(before, source: "rebuild requested")
        try configureSession(forceReconfigure: true)

        let after = captureGraphSnapshot()
        publishCaptureGraphStatus(after, source: "after forced configure")
        guard after.valid else {
            isConfigured = false
            cameraBreadcrumb(.graph, phase: "ensure graph failed", extra: "reason=\(reason)")
            throw CameraError.incompleteSessionGraph
        }
        cameraBreadcrumb(.graph, phase: "ensure graph success", extra: "reason=\(reason)")
    }

    /// UX16c35: the compatibility camera facade must never start its private
    /// AVCaptureSession. All callers are intentionally absorbed here so stale
    /// reconnect/watchdog/settings paths cannot recreate a competing owner.
    @discardableResult
    private func startSessionIfNeeded(reason: String, force: Bool = false) -> Bool {
        cameraBreadcrumb(
            .lifecycle,
            phase: "legacy session start suppressed",
            extra: "CaptureEngine owns runtime reason=\(reason) force=\(force)"
        )
        recordLifecycleEvent("Legacy AVCaptureSession start suppressed: \(reason)")
        return false
    }

    func start() async throws {
        cameraBreadcrumb(.lifecycle, phase: "legacy start ignored", extra: "CaptureEngine owns runtime")
        recordLifecycleEvent("Legacy HockeyCameraService.start ignored; CaptureEngine owns runtime")
    }

    func lastFrameAgeText(now: Date = Date()) -> String {
        guard let lastFrameReceivedAt else {
            return isPreviewOnlySession ? "preview-only heartbeat not published yet" : "no frame yet"
        }
        let age = max(0, now.timeIntervalSince(lastFrameReceivedAt))
        if age < 1.0 {
            return String(format: "%.1fs ago", age)
        }
        return String(format: "%.0fs ago", age)
    }


    func setPreviewRequiredForActiveRoute(_ required: Bool, reason: String) {
        let apply: @MainActor @Sendable () -> Void = {
            guard self.previewRequiredForActiveRoute != required else { return }
            self.previewRequiredForActiveRoute = required
            self.cameraBreadcrumb(.route, phase: "preview requirement changed", extra: "required=\(required) reason=\(reason)")
            self.previewExpectationText = required ? "Preview expected for active route" : "Preview inactive for current route"
            self.updateWhiteScreenDetector()
            MainThreadStallMonitor.shared.trace(RinkLensBuildInfo.traceContext("preview expectation changed required=\(required) reason=\(reason)"))
        }

        // Apply route expectations immediately on the main thread. Camera selection
        // is independently configured and retained; this flag controls preview/UI
        // expectations only and never stages or releases an input.
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                apply()
            }
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }


    func setDiagnosticsPublishingVisible(_ visible: Bool) {
        DispatchQueue.main.async {
            guard self.diagnosticsPublishingVisible != visible else { return }
            self.diagnosticsPublishingVisible = visible
            self.lastPreviewLayerUIPublishAt = 0
            MainThreadStallMonitor.shared.trace("camera diagnostics publishing \(visible ? "visible" : "hidden")")
        }
    }

    func diagnosticsUpdatingText(now: Date = Date()) -> String {
        guard isSessionRunning else { return "No - session stopped" }
        guard let lastFrameReceivedAt else {
            return isPreviewOnlySession ? "Yes - preview-only session running" : "No - no frame seen yet"
        }
        let age = now.timeIntervalSince(lastFrameReceivedAt)
        if isPreviewOnlySession {
            if !previewRequiredForActiveRoute && !previewLayerAttached {
                return "Preview inactive for current route"
            }
            return age < 3.0 ? "Yes - preview heartbeat recent" : "View updating, but preview heartbeat is stale"
        }
        return age < 3.0 ? "Yes - frame counter updating" : "No - frame counter stale"
    }

    func previewLayerAgeText(now: Date = Date()) -> String {
        guard previewLayerAttached else { return "not attached" }
        guard lastPreviewLayerHeartbeatAt > .distantPast else { return "no heartbeat yet" }
        let age = max(0, now.timeIntervalSince(lastPreviewLayerHeartbeatAt))
        if age < 1.0 { return String(format: "%.1fs ago", age) }
        return String(format: "%.0fs ago", age)
    }

    private func previewFrameDescriptionHasZeroBounds(_ frameDescription: String) -> Bool {
        frameDescription.contains("layer=0x")
            || frameDescription.contains("view=0x")
            || frameDescription.contains("x0 view=")
            || frameDescription.hasSuffix("x0")
    }

    func notePreviewLayerAttached(
        hostID: String = "unknown",
        frameDescription: String = "layer frame unknown",
        sessionAssigned: Bool = true
    ) {
        cameraBreadcrumb(.previewConfigure, phase: "preview attach callback", extra: "host=\(hostID) assigned=\(sessionAssigned) frame=\(frameDescription)")
        // v0.8.4o: track preview-layer attachment for both preview-only and
        // frame-processing sessions. Calibration uses frame-processing, so the
        // old preview-only guard made diagnostics report "not attached" even
        // when the AVCapture preview existed.
        // v0.8.8m8: preview attach is idempotent. Layout refreshes with the
        // same host/bounds update the heartbeat but do not publish a full
        // attach event or reset orientation/ownership diagnostics.
        let hasZeroSizedLayer = previewFrameDescriptionHasZeroBounds(frameDescription)
        if RinkLensRecordingCaptureLease.shared.isRecordingActive(), !sessionAssigned || hasZeroSizedLayer {
            RinkLensRecordingCaptureLease.shared.notePassiveIssue(
                "preview attach rejected during recording host=\(hostID) reason=\(sessionAssigned ? "zero bounds" : "session missing") \(frameDescription)",
                key: "attach-invalid-recording-\(hostID)"
            )
            return
        }
        guard sessionAssigned, !hasZeroSizedLayer else {
            DispatchQueue.main.async {
                self.previewLayerAttached = false
                self.previewLayerReadyForDisplay = false
                self.previewLayerFrameText = frameDescription
                self.previewSessionAssignedText = sessionAssigned ? "session assigned" : "session missing"
                self.currentPreviewHostID = hostID
                self.lastPreviewLayerEventText = "Preview attach waiting for layout"
                self.updateWhiteScreenDetector()
                MainThreadStallMonitor.shared.traceRenderPreviewToggle("preview_attach_rejected_zero_bounds | host=\(hostID) \(frameDescription)")
            }
            return
        }

        let now = Date()
        lastPreviewLayerHeartbeatAt = now
        let signature = CameraPreviewAttachmentSignature(hostID: hostID, frameDescription: frameDescription, sessionAssigned: sessionAssigned)
        let previousSignature = lastPreviewAttachmentSignature
        let isDuplicateAttach = previousSignature == signature
        if RinkLensRecordingCaptureLease.shared.isRecordingActive(), !isDuplicateAttach {
            RinkLensRecordingCaptureLease.shared.notePassiveIssue(
                "preview attach request ignored during recording host=\(hostID) \(signature.description)",
                key: "attach-during-recording-\(hostID)"
            )
            return
        }
        lastPreviewAttachmentSignature = signature
        DispatchQueue.main.async {
            self.previewLayerAttached = true
            self.previewLayerFrameText = frameDescription
            self.previewSessionAssignedText = sessionAssigned ? "session assigned" : "session missing"
            self.currentPreviewHostID = hostID
            self.lastPreviewAttachReasonText = signature.description
            self.lastPreviewLayerEventText = isDuplicateAttach ? "Preview layer heartbeat" : "Preview layer attached"
            if !isDuplicateAttach {
                CameraOwnershipTraceStore.record(.attachPreview, owner: self.sampleBufferOutputEnabled ? .ocrCamera : .broadcast, reason: signature.description)
                MainThreadStallMonitor.shared.traceRenderPreviewToggle("Preview layer attached | \(signature.description)")
                MainThreadStallMonitor.shared.notePublish(source: "preview layer")
            }
            self.updateWhiteScreenDetector()
        }
    }

    func notePreviewLayerDetached() {
        cameraBreadcrumb(.previewConfigure, phase: "preview detach callback", extra: "host=\(currentPreviewHostID)")
        guard RinkLensRecordingCaptureLease.shared.allowMutation(
            action: "detach preview",
            requester: "CapturePreviewEndpoint.didMoveToWindow",
            owner: sampleBufferOutputEnabled ? "OCR Camera" : "Live Camera"
        ) else {
            DispatchQueue.main.async {
                self.lastPreviewLayerEventText = "Preview detach deferred during recording"
                self.updateWhiteScreenDetector()
            }
            return
        }
        DispatchQueue.main.async {
            self.previewLayerAttached = false
            self.previewLayerReadyForDisplay = false
            self.lastPreviewLayerEventText = "Preview layer detached"
            self.currentPreviewHostID = "none"
            self.lastPreviewAttachmentSignature = nil
            CameraOwnershipTraceStore.record(.detachPreview, owner: self.sampleBufferOutputEnabled ? .ocrCamera : .broadcast, reason: "preview layer detached")
            self.updateWhiteScreenDetector()
            MainThreadStallMonitor.shared.traceRenderPreviewToggle("Preview layer detached")
            MainThreadStallMonitor.shared.notePublish(source: "preview layer")
        }
    }

    func notePreviewLayerHeartbeat(hostID: String = "unknown", isReadyForDisplay: Bool, frameDescription: String = "layer frame unknown", sessionAssigned: Bool = true) {
        if lastPreviewReadyBreadcrumbState != isReadyForDisplay || lastPreviewSessionAssignedBreadcrumbState != sessionAssigned {
            lastPreviewReadyBreadcrumbState = isReadyForDisplay
            lastPreviewSessionAssignedBreadcrumbState = sessionAssigned
            cameraBreadcrumb(.previewReady, phase: "preview readiness changed", extra: "host=\(hostID) ready=\(isReadyForDisplay) assigned=\(sessionAssigned) frame=\(frameDescription)")
        }
        let now = Date()
        lastPreviewLayerHeartbeatAt = now
        let nowAbsolute = CFAbsoluteTimeGetCurrent()
        let publishInterval = diagnosticsPublishingVisible ? previewLayerDiagnosticsUIPublishInterval : previewLayerHiddenUIPublishInterval
        guard nowAbsolute - lastPreviewLayerUIPublishAt >= publishInterval else { return }
        lastPreviewLayerUIPublishAt = nowAbsolute
        let hasZeroSizedLayer = previewFrameDescriptionHasZeroBounds(frameDescription)
        if RinkLensRecordingCaptureLease.shared.isRecordingActive(), !sessionAssigned || hasZeroSizedLayer {
            RinkLensRecordingCaptureLease.shared.notePassiveIssue(
                "preview heartbeat ignored during recording host=\(hostID) reason=\(sessionAssigned ? "zero bounds" : "session missing") \(frameDescription)",
                key: "heartbeat-invalid-recording-\(hostID)"
            )
            return
        }
        DispatchQueue.main.async {
            self.previewLayerAttached = sessionAssigned && !hasZeroSizedLayer
            self.previewLayerReadyForDisplay = isReadyForDisplay
            self.previewLayerFrameText = frameDescription
            self.previewSessionAssignedText = sessionAssigned ? "session assigned" : "session missing"
            self.currentPreviewHostID = hostID
            // UX16c19: Preview-layer attachment is not proof that the camera delivered
            // a sample buffer. Real frame health is published only by captureOutput.
            self.lastPreviewLayerEventText = isReadyForDisplay ? "Preview layer presenting" : "Preview layer attached, waiting for display"
            self.updateWhiteScreenDetector()
            if self.diagnosticsPublishingVisible {
                MainThreadStallMonitor.shared.notePublish(source: "preview heartbeat")
            }
        }
    }

    private func updateWhiteScreenDetector() {
        let previous = whiteScreenDetectorText
        if !previewRequiredForActiveRoute && !previewLayerAttached {
            whiteScreenDetectorText = "inactive: preview layer detached because current route does not display Broadcast"
        } else if isSessionRunning && hasReceivedFrames && !previewLayerAttached {
            whiteScreenDetectorText = "ALERT: session running + frames updating, but preview layer is not attached"
        } else if isSessionRunning && previewLayerAttached && previewLayerFrameText.contains("0x") {
            whiteScreenDetectorText = "ALERT: preview layer attached but has zero size"
        } else if isSessionRunning && previewLayerAttached && !previewLayerReadyForDisplay {
            whiteScreenDetectorText = "Watch: layer attached but not yet presenting"
        } else {
            whiteScreenDetectorText = "no white-screen symptoms detected"
        }

        if previous != whiteScreenDetectorText && (whiteScreenDetectorText.hasPrefix("ALERT") || whiteScreenDetectorText.hasPrefix("Watch")) {
            let message = "UX15n preview-black breadcrumb status=\(whiteScreenDetectorText) running=\(isSessionRunning) attached=\(previewLayerAttached) ready=\(previewLayerReadyForDisplay) frame=\(previewLayerFrameText) session=\(previewSessionAssignedText)"
            DispatchQueue.main.async {
                MainThreadStallMonitor.shared.traceRenderPreviewToggle(message)
            }
        }
    }

    func reattachPreviewLayerIfStale(staleAfter: TimeInterval = 2.0, reason: String) {
        outputQueue.async { [weak self] in
            guard let self else { return }
            let ownerName = self.sampleBufferOutputEnabled ? "OCR Camera" : "Live Camera"
            guard RinkLensRecordingCaptureLease.shared.allowMutation(
                action: "reattach preview layer",
                requester: reason,
                owner: ownerName
            ) else {
                RinkLensRecordingCaptureLease.shared.notePassiveIssue(
                    "preview reattach blocked during recording: \(reason)",
                    key: "preview-reattach-blocked-\(ownerName)"
                )
                DispatchQueue.main.async {
                    self.lastPreviewLayerEventText = "Preview reattach deferred during recording"
                    self.lastLifecycleEventText = "Preview reattach blocked; recording protected"
                    MainThreadStallMonitor.shared.traceRenderPreviewToggle("preview reattach blocked during recording: \(reason)")
                }
                return
            }
            guard self.session.isRunning else { return }
            guard !self.isRestartingCamera else { return }
            let now = Date()
            let staleFor = now.timeIntervalSince(self.lastPreviewLayerHeartbeatAt)
            guard staleFor >= staleAfter else { return }
            guard now.timeIntervalSince(self.lastPreviewLayerReattachAt) >= self.previewLayerReattachCooldown else { return }
            self.lastPreviewLayerReattachAt = now
            DispatchQueue.main.async {
                self.previewLayerStaleCount += 1
                self.previewLayerReattachCount += 1
                self.previewResetToken += 1
                self.lastPreviewLayerEventText = "Preview layer reattached: \(reason)"
                self.lastLifecycleEventText = "Preview layer reattached only; session kept alive"
            }
        }
    }

    func stop() {
        cameraBreadcrumb(.lifecycle, phase: "legacy stop ignored", extra: "CaptureEngine owns runtime")
    }

    func noteLifecycleEvent(_ text: String) {
        outputQueue.async { [weak self] in
            self?.recordLifecycleEvent(text)
        }
    }


    private func markPreviewOnlySessionHealthy(status: String? = nil) {
        guard !sampleBufferOutputEnabled else { return }
        let now = Date()
        lastFrameReceivedForHealth = now
        DispatchQueue.main.async {
            self.hasReceivedFrames = true
            self.lastFrameReceivedAt = now
            self.visibleCameraHealthy = true
            if let status {
                self.cameraStatusText = status
            }
        }
    }





    func cameraOwnershipDiagnosticSnapshot() -> CameraOwnershipDiagnosticSnapshot {
        CameraOwnershipDiagnosticSnapshot(
            owner: sampleBufferOutputEnabled ? "OCR Camera" : "Live Camera",
            previewHost: currentPreviewHostID,
            sessionState: cameraSessionState,
            displayOrientation: cameraDisplayOrientation,
            previewMirrored: previewMirrored,
            lastAttachReason: lastPreviewAttachReasonText,
            sessionRunning: session.isRunning
        )
    }

    func requestBroadcastWatchdogRecoveryIfNeeded(staleAfter: TimeInterval = 2.0, cooldown: TimeInterval = 10.0, reason: String) {
        outputQueue.async { [weak self] in
            guard let self else { return }
            guard !self.isExternallyManagedCaptureReserved else {
                self.recordLifecycleEvent("Legacy watchdog recovery delegated to MultiCam owner: \(reason)")
                return
            }
            guard self.session.isRunning else { return }
            guard !self.isRestartingCamera else { return }
            guard RinkLensRecordingCaptureLease.shared.allowMutation(
                action: "broadcast watchdog recovery",
                requester: reason,
                owner: self.sampleBufferOutputEnabled ? "OCR Camera" : "Live Camera"
            ) else {
                self.recordLifecycleEvent("Broadcast watchdog recovery deferred during recording")
                return
            }

            // Preview-only live cameras intentionally have no AVCaptureVideoDataOutput.
            // Do not restart them based on frame counters that only exist for OCR/frame-processing cameras.
            // Session interruptions/runtime errors are handled independently by AVCapture notifications.
            guard self.sampleBufferOutputEnabled else {
                self.markPreviewOnlySessionHealthy()
                return
            }

            let staleFor = Date().timeIntervalSince(self.lastFrameReceivedForHealth)
            guard staleFor >= staleAfter else {
                DispatchQueue.main.async {
                    if !self.visibleCameraHealthy { self.visibleCameraHealthy = true }
                }
                return
            }

            let now = Date()
            guard now.timeIntervalSince(self.lastCameraRestartTime) >= cooldown else {
                print("broadcast camera watchdog skipped due to cooldown")
                return
            }

            guard self.beginExplicitReconfiguration(status: "Recovering broadcast camera preview") else { return }
            self.lastCameraRestartTime = now
            print("broadcast camera watchdog recovery started: \(reason); stale=\(String(format: "%.1f", staleFor))s")

            if self.session.isRunning {
                self.session.stopRunning()
            }

            Thread.sleep(forTimeInterval: 0.15)
            self.resetFrameHealthForExplicitReconfigure()

            if !self.session.isRunning {
                self.startSessionIfNeeded(reason: "broadcast watchdog recovery", force: true)
            }

            self.requestPreviewLayerReset(reason: reason)
            self.recordSessionRestart(reason: "watchdog recovery")
            self.endExplicitReconfiguration(status: "Broadcast camera preview recovered")
        }
    }

    func checkVisibleCameraHealthAfterScreenSwitch(isScreenSwitching: Bool) {
        outputQueue.async { [weak self] in
            guard let self else { return }

            guard !isScreenSwitching else {
                print("camera health check skipped because screen switching")
                return
            }

            guard self.sampleBufferOutputEnabled else {
                self.markPreviewOnlySessionHealthy()
                return
            }

            let secondsSinceLastFrame = Date().timeIntervalSince(self.lastFrameReceivedForHealth)
            guard secondsSinceLastFrame >= self.unhealthyFrameThreshold else {
                DispatchQueue.main.async {
                    self.visibleCameraHealthy = true
                }
                return
            }

            print("camera unhealthy detected")
            DispatchQueue.main.async {
                self.visibleCameraHealthy = false
                self.cameraStatusText = "Camera unhealthy: no frames for \(String(format: "%.1f", secondsSinceLastFrame))s. Use Live > Cameras > Recover Camera Preview."
            }

            // Do not automatically restart/rebuild the camera here.
            // Earlier automatic recovery could create a black/flash/restart loop on UVC cameras.
            // Recovery is now manual only via Live > Cameras > Recover Camera Preview.
        }
    }


    /// UX13n: wake/route recovery for the black external-camera preview case.
    ///
    /// Earlier builds deliberately stopped automatic rebuild storms, but that made
    /// USB/external preview recovery too passive after iPad sleep, route changes or
    /// AVFoundation interruption recovery. This method is intentionally narrow:
    /// it reasserts the already-selected device format/FPS and asks the persistent
    /// preview host to reconnect once. It does not change camera source selection.
    func reassertPreviewAfterWake(reason: String) {
        cameraBreadcrumb(.lifecycle, phase: "legacy wake reassert ignored", extra: "CaptureEngine owns runtime reason=\(reason)")
    }

    private func restartVisibleCameraIfSafe(isScreenSwitching: Bool) {
        // Automatic camera restart is intentionally disabled.
        // Use manual Recover Camera Preview from Live > Cameras instead.
        print("automatic camera restart skipped: manual recovery only")
    }

    private func startFrameWatchdogIfNeeded() {
        // No-op by design. Do not automatically rebuild camera sessions.
    }

    private func stopFrameWatchdog() {
        // No-op by design. There is no automatic watchdog timer.
    }

    private func requestPreviewLayerReset(reason: String) {
        guard previewRequiredForActiveRoute else {
            DispatchQueue.main.async {
                MainThreadStallMonitor.shared.traceRenderPreviewToggle("Persistent preview reset suppressed; preview inactive for current route: \(reason)")
            }
            return
        }
        if Date() < suppressPreviewRecoveryUntil {
            traceBroadcastZoom("preview reset suppressed reason=post-lens-switch request=\(reason)")
            return
        }
        guard RinkLensRecordingCaptureLease.shared.allowMutation(
            action: "persistent preview reset",
            requester: reason,
            owner: sampleBufferOutputEnabled ? "OCR Camera" : "Live Camera"
        ) else {
            DispatchQueue.main.async {
                MainThreadStallMonitor.shared.traceRenderPreviewToggle("Persistent preview reset deferred during recording: \(reason)")
            }
            return
        }
        DispatchQueue.main.async {
            self.previewResetToken += 1
            print("camera preview layer reset requested: \(reason)")
        }
    }

    private func beginExplicitReconfiguration(status: String) -> Bool {
        guard RinkLensRecordingCaptureLease.shared.allowMutation(
            action: "explicit camera reconfiguration",
            requester: status,
            owner: sampleBufferOutputEnabled ? "OCR Camera" : "Live Camera"
        ) else {
            recordLifecycleEvent("Camera reconfiguration deferred during recording")
            return false
        }
        guard !isRestartingCamera else {
            print("camera reconfiguration skipped: already in progress")
            return false
        }
        isRestartingCamera = true
        DispatchQueue.main.async {
            self.isReconfiguring = true
            self.cameraStatusText = status
        }
        return true
    }

    private func endExplicitReconfiguration(status: String? = nil) {
        isRestartingCamera = false
        DispatchQueue.main.async {
            self.isReconfiguring = false
            if let status {
                self.cameraStatusText = status
                self.lastLifecycleEventText = status
            }
        }
    }

    private func publishCameraSessionState(_ state: CameraSessionState, event: String? = nil) {
        DispatchQueue.main.async {
            self.cameraSessionState = state
            if let event {
                self.lastLifecycleEventText = event
            }
        }
    }

    private func recordLifecycleEvent(_ text: String) {
        DispatchQueue.main.async {
            self.lastLifecycleEventText = text
            if self.session.isRunning && self.cameraSessionState != .running {
                self.cameraSessionState = .running
            }
        }
    }

    private func recordSessionRestart(reason: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let stamp = formatter.string(from: Date())
        DispatchQueue.main.async {
            self.lifecycleRestartCount += 1
            self.lastRestartReasonText = reason
            self.lastRestartedAtText = stamp
            self.lastLifecycleEventText = "Restarted: \(reason)"
        }
    }

    private func resetFrameHealthForExplicitReconfigure(preservePreviewAttachment: Bool = false) {
        lastFrameReceivedForHealth = Date()
        hasPublishedFirstFrameToUI = false
        firstFrameBreadcrumbRecorded = false
        lastHealthUIPublishAt = 0
        DispatchQueue.main.async {
            self.hasReceivedFrames = false
            self.lastFrameReceivedAt = nil
            self.visibleCameraHealthy = true
            self.lastFrameLumaText = "Awaiting first frame after camera reconfiguration"
            if self.isPreviewOnlySession && !preservePreviewAttachment {
                self.previewLayerAttached = false
                self.previewLayerReadyForDisplay = false
                self.lastPreviewLayerEventText = "Preview layer waiting for reattach"
            } else if preservePreviewAttachment {
                self.lastPreviewLayerEventText = "Preview attachment preserved during lens switch"
            }
        }
    }

    private func recoverBlackCameraPipelineIfSafe(reason: String, isScreenSwitching: Bool) {
        guard previewRequiredForActiveRoute else {
            DispatchQueue.main.async {
                MainThreadStallMonitor.shared.trace("camera recovery suppressed; preview inactive for current route: \(reason)")
                self.lastPreviewLayerEventText = "Preview recovery suppressed; inactive route"
                self.updateWhiteScreenDetector()
            }
            return
        }
        guard !isScreenSwitching else {
            print("camera recovery skipped because screen switching")
            return
        }

        let now = Date()
        if now < suppressPreviewRecoveryUntil {
            traceBroadcastZoom("preview recovery suppressed reason=post-lens-switch request=\(reason)")
            return
        }
        guard now.timeIntervalSince(lastCameraRestartTime) >= minimumRestartInterval else {
            print("camera recovery skipped due to debounce")
            return
        }

        guard beginExplicitReconfiguration(status: "Recovering camera preview") else { return }
        lastCameraRestartTime = now

        print("camera recovery started: \(reason)")
        do {
            if session.isRunning {
                session.stopRunning()
            }

            Thread.sleep(forTimeInterval: 0.15)
            resetFrameHealthForExplicitReconfigure()
            try configureSession(forceReconfigure: true)

            Thread.sleep(forTimeInterval: 0.10)
            if !session.isRunning {
                startSessionIfNeeded(reason: "manual preview recovery", force: true)
            }

            endExplicitReconfiguration(status: "Camera preview recovery requested")
            requestPreviewLayerReset(reason: reason)
            print("camera recovery completed")
        } catch {
            endExplicitReconfiguration()
            DispatchQueue.main.async {
                self.visibleCameraHealthy = false
                self.cameraStatusText = "Camera recovery failed: \(error.localizedDescription)"
            }
        }
    }

    func recoverPreviewIfNeeded(reason: String = "manual visible preview recovery") {
        cameraBreadcrumb(.lifecycle, phase: "legacy preview recovery ignored", extra: "CaptureEngine owns runtime reason=\(reason)")
    }

    func refreshAvailableCameras(reason: String = "manual refresh") {
        cameraBreadcrumb(.discovery, phase: "refresh requested", extra: "reason=\(reason)")
        outputQueue.async {
            self.cameraBreadcrumb(.discovery, phase: "refresh entered output queue", extra: "reason=\(reason)")
            let devices = self.discoveredVideoDevices()

            let activeDevice = self.cameraDevice.flatMap { active in
                devices.first(where: { $0.uniqueID == active.uniqueID })
            }
            let preferredDevice = self.preferredCameraID.flatMap { preferredID in
                devices.first(where: { $0.uniqueID == preferredID })
            }
            let activeSourceID = activeDevice.map { self.logicalCameraSourceID(for: $0) }
            let preferredSourceID = preferredDevice.map { self.logicalCameraSourceID(for: $0) }
            let requestedSourceID = self.cameraSelectionDisabledByUser
                ? nil
                : (self.selectedCameraID ?? activeSourceID ?? preferredSourceID)

            // RL-014: Camera rows are logical choices. Physical discovery may
            // update availability, but it must never remove the External tag from
            // SwiftUI or force selectedCameraID onto a built-in fallback.
            let options = self.simplifiedCameraSourceOptions(from: devices)
            let optionIDs = Set(options.map(\.id))

            let retainedSourceID: String?
            if requestedSourceID == Self.externalCameraSourceID {
                retainedSourceID = Self.externalCameraSourceID
            } else {
                retainedSourceID = requestedSourceID.flatMap { optionIDs.contains($0) ? $0 : nil }
            }
            let resolvedDevice = retainedSourceID.flatMap { self.resolveCameraDevice(sourceID: $0, from: devices) }
            let sourceOption = retainedSourceID.flatMap { id in options.first(where: { $0.id == id }) }

            let backAvailable = self.preferredOperatorBuiltInBackCamera(from: devices) != nil
            let frontAvailable = devices.contains(where: { $0.position == .front && $0.deviceType != .external })
            let externalAvailable = devices.contains(where: { $0.deviceType == .external })
            let summary = "generation=next reason=\(reason); back=\(backAvailable); front=\(frontAvailable); external=\(externalAvailable); devices=\(devices.count)"
            self.cameraBreadcrumb(.discovery, phase: "refresh resolved", extra: "reason=\(reason) requested=\(requestedSourceID ?? "none") retained=\(retainedSourceID ?? "none") resolved=\(resolvedDevice?.uniqueID ?? "none") reconnectPending=\(self.externalReconnectPending) options=\(options.map { $0.id }.joined(separator: ",")) physical=\(devices.map { "\($0.localizedName){\($0.uniqueID)}" }.joined(separator: ","))")

            DispatchQueue.main.async {
                let previousOptions = Dictionary(uniqueKeysWithValues: self.availableCameras.map { ($0.id, $0) })
                self.cameraDiscoveryGeneration += 1
                self.cameraDiscoverySummaryText = summary.replacingOccurrences(
                    of: "generation=next",
                    with: "generation=\(self.cameraDiscoveryGeneration)"
                )
                for option in options {
                    self.recordCameraSourceAvailabilityTransition(
                        previous: previousOptions[option.id],
                        next: option,
                        reason: reason
                    )
                }
                self.availableCameras = options
                self.externalReconnectStatusText = externalAvailable
                    ? "External camera connected"
                    : "External camera not connected"
                self.selectedCameraID = retainedSourceID
                self.resolvedCameraDeviceID = resolvedDevice?.uniqueID
                self.isCameraSelectionDisabled = self.cameraSelectionDisabledByUser

                if self.cameraSelectionDisabledByUser {
                    self.cameraStatusText = "No camera selected"
                    self.selectedCameraName = "None"
                    self.selectedCameraIsExternal = false
                    self.selectedCameraPosition = .unspecified
                } else if let selected = sourceOption {
                    self.selectedCameraName = resolvedDevice?.localizedName ?? selected.name
                    self.selectedCameraIsExternal = selected.isExternal
                    self.selectedCameraPosition = selected.position
                    if selected.id == Self.externalCameraSourceID && resolvedDevice == nil {
                        self.cameraStatusText = self.externalReconnectPending
                            ? "External camera reconnect pending"
                            : "External camera is not connected"
                    } else {
                        self.cameraStatusText = resolvedDevice != nil
                            ? "Camera sources refreshed - selected: \(selected.name)"
                            : "Selected camera source is unavailable"
                    }
                } else {
                    self.cameraStatusText = "Camera sources refreshed - choose a camera"
                    self.resolvedCameraDeviceID = nil
                    self.selectedCameraName = "No camera"
                    self.selectedCameraIsExternal = false
                    self.selectedCameraPosition = .unspecified
                }

                MainThreadStallMonitor.shared.trace(
                    RinkLensBuildInfo.traceContext("camera discovery \(self.cameraDiscoverySummaryText); requestedSource=\(requestedSourceID ?? "none"); selectedSource=\(self.selectedCameraID ?? "none"); resolved=\(self.resolvedCameraDeviceID ?? "none"); externalReconnect=\(self.externalReconnectStatusText)")
                )
            }
        }
    }

    /// UX16c8: Operator-facing camera choices use stable logical source IDs.
    /// The physical rear device can change between a virtual dual-wide device and
    /// a constituent wide camera; the Picker must still remain on one Back row.
    private func simplifiedCameraSourceOptions(from devices: [AVCaptureDevice]) -> [CameraOption] {
        var options: [CameraOption] = []

        if preferredOperatorBuiltInBackCamera(from: devices) != nil {
            options.append(CameraOption(
                id: Self.builtInBackCameraSourceID,
                name: "Built-in Back Camera",
                isExternal: false,
                isAvailable: true,
                position: .back
            ))
        }

        if devices.contains(where: { $0.position == .front && $0.deviceType != .external }) {
            options.append(CameraOption(
                id: Self.builtInFrontCameraSourceID,
                name: "Built-in Front Camera",
                isExternal: false,
                isAvailable: true,
                position: .front
            ))
        }

        let externalAvailable = devices.contains(where: { $0.deviceType == .external })
        options.append(CameraOption(
            id: Self.externalCameraSourceID,
            name: externalAvailable ? "External Camera" : "External Camera — Not Connected",
            isExternal: true,
            isAvailable: externalAvailable,
            position: .unspecified
        ))

        return options
    }

    private func logicalCameraSourceID(for device: AVCaptureDevice) -> String {
        if device.deviceType == .external {
            return Self.externalCameraSourceID
        }
        switch device.position {
        case .back:
            return Self.builtInBackCameraSourceID
        case .front:
            return Self.builtInFrontCameraSourceID
        default:
            return device.uniqueID
        }
    }

    private func resolveCameraDevice(sourceID: String, from devices: [AVCaptureDevice]) -> AVCaptureDevice? {
        switch sourceID {
        case Self.builtInBackCameraSourceID:
            return preferredBuiltInBackCameraForCurrentRole(from: devices)
        case Self.builtInFrontCameraSourceID:
            return devices.first(where: { $0.position == .front && $0.deviceType != .external })
        case Self.externalCameraSourceID:
            return devices.first(where: { $0.deviceType == .external })
        default:
            // Backwards compatibility for templates/settings saved before UX16c8,
            // when picker values were physical AVCaptureDevice unique IDs.
            return devices.first(where: { $0.uniqueID == sourceID })
        }
    }

    private func devicesByExcludingLogicalSources(
        _ devices: [AVCaptureDevice],
        excludedIDs: Set<String>
    ) -> [AVCaptureDevice] {
        guard !excludedIDs.isEmpty else { return devices }

        let excludedSourceIDs = Set(excludedIDs.compactMap { id -> String? in
            if id == Self.builtInBackCameraSourceID ||
                id == Self.builtInFrontCameraSourceID ||
                id == Self.externalCameraSourceID {
                return id
            }
            return devices.first(where: { $0.uniqueID == id }).map { logicalCameraSourceID(for: $0) }
        })

        return devices.filter { device in
            !excludedSourceIDs.contains(logicalCameraSourceID(for: device))
        }
    }



    private func captureSelectionPublicationIsCurrent(_ epoch: UInt64) -> Bool {
        outputQueue.sync { captureSelectionPublicationEpoch == epoch }
    }

    /// Stable identity used by UX16c42 capture reconciliation. The selected
    /// logical and preferred physical identities survive CaptureEngine teardown;
    /// only the active physical identity follows runtime ownership.
    @MainActor
    func captureIdentitySnapshot() -> CaptureIdentitySnapshot {
        let queueIdentity = outputQueue.sync {
            (selectedCameraID, preferredCameraID)
        }
        return CaptureIdentitySnapshot(
            selectedLogicalSourceID: queueIdentity.0 ?? selectedCameraID,
            preferredResolvedPhysicalDeviceID: queueIdentity.1 ?? resolvedCameraDeviceID,
            activePhysicalDeviceID: activeCaptureDeviceID
        )
    }

    /// Returns true when an effective physical camera is a valid constituent of
    /// the operator's logical Back/Front/External source. MultiCam may replace a
    /// virtual rear camera with a supported constituent wide camera.
    func physicalDeviceID(
        _ physicalDeviceID: String?,
        satisfiesLogicalSourceID logicalSourceID: String?
    ) -> Bool {
        guard let physicalDeviceID else { return false }
        guard let logicalSourceID else { return true }
        let devices = discoveredVideoDevices()
        guard let device = devices.first(where: { $0.uniqueID == physicalDeviceID }) else {
            return false
        }
        return logicalCameraSourceID(for: device) == logicalSourceID
    }

    /// Recovery AB / RL-060 capability query. This is read-only hardware truth,
    /// not camera-selection state: it answers whether two currently discoverable
    /// physical devices can coexist in one AVCaptureMultiCamSession. The lifecycle
    /// owner uses it to distinguish a safe OCR-branch-only recovery from a full
    /// graph rebuild that remains subject to failed-contract cooldown.
    func supportsSimultaneousCapturePair(
        livePhysicalDeviceID: String,
        ocrPhysicalDeviceID: String
    ) -> Bool {
        outputQueue.sync {
            let discovery = videoDiscoverySession()
            guard discovery.devices.contains(where: { $0.uniqueID == livePhysicalDeviceID }),
                  discovery.devices.contains(where: { $0.uniqueID == ocrPhysicalDeviceID }) else {
                return false
            }
            return discovery.supportedMultiCamDeviceSets.contains { set in
                set.contains(where: { $0.uniqueID == livePhysicalDeviceID })
                    && set.contains(where: { $0.uniqueID == ocrPhysicalDeviceID })
            }
        }
    }

    /// Build 732 resolves the requested Broadcast framing to a physical device
    /// before CaptureLifecycleController rebuilds the graph. A true 0.5x request
    /// must use Ultra Wide; it is never represented by a clamped value on Wide.
    func preferredBroadcastPhysicalDeviceID(
        forHalfX wantsHalfX: Bool,
        pairedOCRDeviceID: String? = nil,
        sourceQualityDomain: RinkLensBroadcastSourceQualityDomain = .base,
        requiredPreference: RinkLensCaptureFormatPreference? = nil
    ) -> String? {
        outputQueue.sync {
            let discovery = videoDiscoverySession()
            let devices = discovery.devices

            func canUse(_ candidate: AVCaptureDevice) -> Bool {
                if let requiredPreference {
                    let exactFormatExists = candidate.formats.contains { format in
                        guard format.isMultiCamSupported else { return false }
                        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                        guard dimensions.width == requiredPreference.width,
                              dimensions.height == requiredPreference.height else { return false }
                        return format.videoSupportedFrameRateRanges.contains { range in
                            requiredPreference.cadence.framesPerSecond + 0.005 >= range.minFrameRate
                                && requiredPreference.cadence.framesPerSecond - 0.005 <= range.maxFrameRate
                        }
                    }
                    guard exactFormatExists else { return false }
                }
                if let pairedOCRDeviceID {
                    guard let ocr = devices.first(where: { $0.uniqueID == pairedOCRDeviceID }) else {
                        return false
                    }
                    return discovery.supportedMultiCamDeviceSets.contains { set in
                        set.contains(where: { $0.uniqueID == candidate.uniqueID })
                            && set.contains(where: { $0.uniqueID == ocr.uniqueID })
                    }
                }
                return true
            }

            var candidates: [AVCaptureDevice] = []
            func appendUnique(_ candidate: AVCaptureDevice?) {
                guard let candidate,
                      !candidates.contains(where: { $0.uniqueID == candidate.uniqueID }) else { return }
                candidates.append(candidate)
            }
            for kind in RinkLensBroadcastRearLensPolicy.orderedCandidates(
                wantsHalfX: wantsHalfX,
                requiresPairCompatibility: pairedOCRDeviceID != nil,
                sourceQualityDomain: sourceQualityDomain
            ) {
                switch kind {
                case .virtualRear:
                    appendUnique(preferredVirtualBackZoomCamera(from: devices))
                case .wide:
                    appendUnique(preferredPhysicalWideBuiltInBackCamera(from: devices))
                case .ultraWide:
                    appendUnique(preferredUltraWideBuiltInBackCamera(from: devices))
                }
            }
            appendUnique(preferredStandardBuiltInBackCamera(from: devices))
            appendUnique(preferredBuiltInBackCamera(from: devices))
            return candidates.first(where: canUse)?.uniqueID
        }
    }


    /// Stateless camera-capability classification used by discovery and
    /// contract validation. This does not select a camera, mutate zoom state or
    /// execute a capture transaction.
    private func isVirtualBackZoomCamera(_ device: AVCaptureDevice) -> Bool {
        guard device.position == .back else { return false }
        return device.deviceType == .builtInDualWideCamera
            || device.deviceType == .builtInTripleCamera
            || device.deviceType == .builtInDualCamera
    }

    func broadcastDeviceIDIsVirtualRearZoomCamera(_ deviceID: String) -> Bool {
        outputQueue.sync {
            guard let device = discoveredVideoDevices().first(where: { $0.uniqueID == deviceID }) else { return false }
            return isVirtualBackZoomCamera(device)
        }
    }

    func broadcastDeviceIDIsUltraWide(_ deviceID: String) -> Bool {
        outputQueue.sync {
            guard let device = discoveredVideoDevices().first(where: { $0.uniqueID == deviceID }) else { return false }
            return device.deviceType == .builtInUltraWideCamera
                || device.localizedName.localizedCaseInsensitiveContains("ultra")
        }
    }

    /// Validates the framing class without requiring AVFoundation to replace one
    /// rear input. A virtual Dual/Triple rear camera can satisfy either optical
    /// domain because its constituent switch remains inside that one source.
    func broadcastPhysicalDeviceID(
        _ deviceID: String?,
        satisfiesHalfXTarget halfX: Bool
    ) -> Bool {
        guard let deviceID else { return false }
        return outputQueue.sync {
            guard let device = discoveredVideoDevices().first(where: { $0.uniqueID == deviceID }),
                  device.position == .back,
                  device.deviceType != .external else { return false }
            let ultraWide = device.deviceType == .builtInUltraWideCamera
                || device.localizedName.localizedCaseInsensitiveContains("ultra")
            if halfX {
                return ultraWide || isVirtualBackZoomCamera(device)
            }
            guard !ultraWide, device.deviceType != .builtInTelephotoCamera else { return false }
            return device.deviceType == .builtInWideAngleCamera
                || isVirtualBackZoomCamera(device)
        }
    }

    /// Stages device identity and exact native cadence in one queue-confined
    /// transaction. It deliberately does not refresh the operator capability
    /// menu, so the camera transaction cannot consume a stale format identifier.
    @discardableResult
    func stageExactBroadcastCaptureContract(
        physicalDeviceID: String,
        preference: RinkLensCaptureFormatPreference,
        reason: String
    ) -> Bool {
        let previousRequest = requestedCameraControlSummary()
        let stagedDevice: AVCaptureDevice? = outputQueue.sync {
            let devices = discoveredVideoDevices()
            guard let device = devices.first(where: {
                $0.uniqueID == physicalDeviceID
                    && $0.position == .back
                    && $0.deviceType != .external
            }) else { return nil }
            let cadence = preference.cadence.framesPerSecond
            let exactFormatExists = device.formats.contains { format in
                guard format.isMultiCamSupported else { return false }
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard dimensions.width == preference.width,
                      dimensions.height == preference.height else { return false }
                return format.videoSupportedFrameRateRanges.contains { range in
                    cadence + 0.005 >= range.minFrameRate
                        && cadence - 0.005 <= range.maxFrameRate
                }
            }
            guard exactFormatExists else { return nil }

            captureSelectionPublicationEpoch &+= 1
            selectedCameraID = Self.builtInBackCameraSourceID
            preferredCameraID = device.uniqueID
            cameraDevice = device
            currentInput = nil
            isConfigured = false
            cameraSelectionDisabledByUser = false
            preferredVideoFormatID = nil
            preferredVideoFrameRate = preference.nominalFPS
            captureFormatPreferenceOverride = preference
            preferredVideoFormatIDByCameraID.removeValue(forKey: device.uniqueID)
            preferredVideoFrameRateByCameraID[device.uniqueID] = preference.nominalFPS
            captureFormatPreferenceByCameraID[device.uniqueID] = preference
            roleDefaultProfileCaptureEnabled = false
            appleStyleAutoQualityCaptureEnabled = false
            cameraBreadcrumb(
                .selection,
                phase: "Build 773 exact Broadcast contract staged",
                extra: "device=\(device.localizedName){\(device.uniqueID)} format=\(preference.diagnosticText) reason=\(reason)"
            )
            return device
        }
        guard let stagedDevice else { return false }

        selectedCapabilityProfileID = nil
        selectedVideoFormatID = nil
        selectedResolutionFPS = preference.diagnosticText
        roleDefaultProfileEnabled = false
        appleStyleAutoQualityEnabled = false
        videoFormatLoadStatusText = "Exact CaptureEngine contract staged: \(preference.diagnosticText)"
        DispatchQueue.main.async {
            self.selectedCameraID = Self.builtInBackCameraSourceID
            self.resolvedCameraDeviceID = stagedDevice.uniqueID
            self.selectedCameraName = stagedDevice.localizedName
            self.selectedCameraIsExternal = false
            self.selectedCameraPosition = .back
            self.isCameraSelectionDisabled = false
            self.cameraStatusText = "Broadcast framing staged: \(stagedDevice.localizedName)"
            self.captureGraphStatusText = "Exact Broadcast device/cadence staged atomically — \(reason)"
        }
        recordRequestedCameraTransition(
            event: "camera_exact_broadcast_contract_requested",
            previous: previousRequest,
            next: requestedCameraControlSummary(),
            reason: reason
        )
        return true
    }

    /// Stage a resolved physical constituent while preserving the one logical
    /// Built-in Back camera selection. This is requested state, not applied truth.
    @discardableResult
    func stagePreferredBroadcastPhysicalDeviceID(_ physicalDeviceID: String, reason: String) -> Bool {
        let staged: AVCaptureDevice? = outputQueue.sync {
            let devices = discoveredVideoDevices()
            guard let device = devices.first(where: {
                $0.uniqueID == physicalDeviceID
                    && $0.position == .back
                    && $0.deviceType != .external
            }) else { return nil }
            captureSelectionPublicationEpoch &+= 1
            selectedCameraID = Self.builtInBackCameraSourceID
            preferredCameraID = device.uniqueID
            cameraDevice = device
            currentInput = nil
            isConfigured = false
            cameraSelectionDisabledByUser = false
            captureFormatPreferenceOverride = captureFormatPreferenceByCameraID[device.uniqueID]
            cameraBreadcrumb(
                .selection,
                phase: "Build 732 physical Broadcast constituent staged",
                extra: "device=\(device.localizedName){\(device.uniqueID)} reason=\(reason)"
            )
            return device
        }
        guard let staged else { return false }
        DispatchQueue.main.async {
            self.selectedCameraID = Self.builtInBackCameraSourceID
            self.resolvedCameraDeviceID = staged.uniqueID
            self.selectedCameraName = staged.localizedName
            self.selectedCameraIsExternal = false
            self.selectedCameraPosition = .back
            self.isCameraSelectionDisabled = false
            self.cameraStatusText = "Broadcast lens staged: \(staged.localizedName)"
            self.captureGraphStatusText = "Physical Broadcast constituent staged for rebuild — \(reason)"
        }
        refreshVideoFormats(force: true, reason: "Build 732 physical Broadcast constituent selected")
        return true
    }

    func supportsCapturePreference(_ preference: RinkLensCaptureFormatPreference, physicalDeviceID: String) -> Bool {
        let devices = discoveredVideoDevices()
        guard let device = devices.first(where: { $0.uniqueID == physicalDeviceID }) else { return false }
        return device.formats.contains { format in
            // CaptureLifecycleController uses this answer to stage a format on
            // AVCaptureMultiCamSession. A format that exists for single-camera
            // capture is not evidence that the live Broadcast + OCR graph can
            // apply it.
            guard format.isMultiCamSupported else { return false }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width == preference.width, dimensions.height == preference.height else { return false }
            return format.videoSupportedFrameRateRanges.contains { range in
                preference.cadence.framesPerSecond + 0.005 >= range.minFrameRate
                    && preference.cadence.framesPerSecond - 0.005 <= range.maxFrameRate
            }
        }
    }

    /// CaptureEngine publishes the hardware result through the camera controller.
    /// Views read this projection; they never infer stabilisation, lens or quality
    /// from the operator request alone.
    func publishBroadcastAppliedTruth(
        deviceName: String,
        deviceTypeRawValue: String,
        iso: Float,
        exposureDurationSeconds: Double,
        sourceFPS: Double,
        logicalZoom: CGFloat,
        lowLightBoostSupported: Bool,
        lowLightBoostRequested: Bool,
        automaticFrameRateSupported: Bool,
        automaticFrameRateEnabled: Bool,
        imagingCapabilitiesText: String,
        stabilisationRequested: Bool,
        stabilisationSupported: Bool,
        stabilisationAppliedRawValue: Int
    ) {
        DispatchQueue.main.async {
            self.isoValue = iso
            self.exposureDurationSeconds = exposureDurationSeconds
            self.shutterSpeedText = Self.shutterSpeedDisplayText(seconds: exposureDurationSeconds)
            let lens: String
            if deviceTypeRawValue.localizedCaseInsensitiveContains("UltraWide") || deviceName.localizedCaseInsensitiveContains("ultra") {
                lens = "Ultra Wide"
            } else if deviceTypeRawValue.localizedCaseInsensitiveContains("Dual") || deviceTypeRawValue.localizedCaseInsensitiveContains("Triple") {
                lens = logicalZoom < 1.0 ? "Ultra Wide constituent" : "Wide constituent"
            } else {
                lens = "Wide"
            }
            self.broadcastActiveLensText = "Lens: \(lens) • \(String(format: "%.1fx", Double(logicalZoom)))"
            self.broadcastAppliedCadenceText = sourceFPS > 0
                ? "Source cadence: \(String(format: "%.1f", sourceFPS)) fps"
                : "Source cadence: waiting for frames"

            let appliedLabel: String
            switch stabilisationAppliedRawValue {
            case AVCaptureVideoStabilizationMode.off.rawValue: appliedLabel = "Off"
            case AVCaptureVideoStabilizationMode.standard.rawValue: appliedLabel = "Standard"
            case AVCaptureVideoStabilizationMode.cinematic.rawValue: appliedLabel = "Cinematic"
            case AVCaptureVideoStabilizationMode.lowLatency.rawValue: appliedLabel = "Low Latency"
            case AVCaptureVideoStabilizationMode.auto.rawValue: appliedLabel = "Automatic"
            default: appliedLabel = stabilisationAppliedRawValue < 0 ? "Unavailable" : "Mode \(stabilisationAppliedRawValue)"
            }
            self.stabilisationStatusText =
                "Requested: \(stabilisationRequested ? "Enabled" : "Off") • "
                + "Supported: \(stabilisationSupported ? "Yes" : "No") • Applied: \(appliedLabel)"

            self.lowLightBoostStatusText = lowLightBoostSupported
                ? "Low-light boost: supported • requested \(lowLightBoostRequested ? "automatic" : "off")"
                : "Low-light boost: unavailable on this format"
            self.automaticFrameRateStatusText = automaticFrameRateSupported
                ? "Auto frame rate: supported • applied \(automaticFrameRateEnabled ? "on" : "off")"
                : "Auto frame rate: unavailable on this format"
            self.broadcastImagingCapabilitiesText = imagingCapabilitiesText

            if iso >= 900 {
                self.broadcastImageQualityStatusText = "IMAGE QUALITY: POOR • ISO \(Int(iso)) • \(self.shutterSpeedText)"
                self.broadcastImageQualityRecommendationText =
                    sourceFPS > 35
                    ? "High sensor gain is adding grain. Use Image Quality / Low Light so AVFoundation can trade cadence for exposure."
                    : (automaticFrameRateEnabled
                        ? "Adaptive low-light cadence is active. Allow continuous exposure to settle before judging noise and detail."
                        : "30 fps is active. Low-light boost can improve the scene when the format supports it.")
            } else if iso >= 600 {
                self.broadcastImageQualityStatusText = "IMAGE QUALITY: FAIR • ISO \(Int(iso)) • \(self.shutterSpeedText)"
                self.broadcastImageQualityRecommendationText = "Light is marginal. Keep exposure automatic until the rink view settles."
            } else {
                self.broadcastImageQualityStatusText = "IMAGE QUALITY: GOOD • ISO \(Int(iso)) • \(self.shutterSpeedText)"
                self.broadcastImageQualityRecommendationText = "Sensor gain is within the preferred range."
            }
        }
    }

    @MainActor
    func captureSelectionSnapshot() -> CaptureSelectionSnapshot {
        let queueState = outputQueue.sync {
            (
                selectedCameraID,
                preferredCameraID,
                cameraSelectionDisabledByUser,
                preferredVideoFormatID,
                preferredVideoFormatIDByCameraID,
                preferredVideoFrameRate,
                preferredVideoFrameRateByCameraID,
                captureFormatPreferenceOverride,
                captureFormatPreferenceByCameraID,
                appleStyleAutoQualityCaptureEnabled
            )
        }
        return CaptureSelectionSnapshot(
            preferredCameraID: queueState.1,
            cameraSelectionDisabledByUser: queueState.2,
            preferredVideoFormatID: queueState.3,
            preferredVideoFormatIDByCameraID: queueState.4,
            preferredVideoFrameRate: queueState.5,
            preferredVideoFrameRateByCameraID: queueState.6,
            captureFormatPreferenceOverride: queueState.7,
            captureFormatPreferenceByCameraID: queueState.8,
            appleStyleAutoQualityCaptureEnabled: queueState.9,
            selectedCameraID: queueState.0,
            resolvedCameraDeviceID: resolvedCameraDeviceID,
            isCameraSelectionDisabled: isCameraSelectionDisabled,
            selectedCameraName: selectedCameraName,
            selectedCameraIsExternal: selectedCameraIsExternal,
            selectedCameraPosition: selectedCameraPosition,
            availableVideoFormats: availableVideoFormats,
            selectedVideoFormatID: selectedVideoFormatID,
            videoFormatsLoaded: videoFormatsLoaded,
            videoFormatLoadStatusText: videoFormatLoadStatusText,
            capabilityProfiles: capabilityProfiles,
            selectedCapabilityProfileID: selectedCapabilityProfileID,
            selectedResolutionFPS: selectedResolutionFPS,
            appleStyleAutoQualityEnabled: appleStyleAutoQualityEnabled,
            cameraStatusText: cameraStatusText,
            sessionResourceStateText: sessionResourceStateText,
            captureGraphStatusText: captureGraphStatusText
        )
    }

    @MainActor
    func restoreCaptureSelectionSnapshot(
        _ snapshot: CaptureSelectionSnapshot,
        reason: String
    ) {
        let retainedLogicalSourceID: String? = outputQueue.sync {
            let currentLogicalSourceID = selectedCameraID
            let currentIsStableLogicalSource = currentLogicalSourceID == Self.builtInBackCameraSourceID
                || currentLogicalSourceID == Self.builtInFrontCameraSourceID
                || currentLogicalSourceID == Self.externalCameraSourceID
            // Recovery AA / RL-059: a staging rollback owns physical graph/format
            // state, not the operator/profile logical source. If a valid logical
            // source has just been staged but is physically unresolved, preserve
            // that source across rollback rather than replaying an older nil or
            // fallback source from the pre-staging snapshot. Explicit None is
            // still represented by cameraSelectionDisabledByUser and is not kept.
            let preserveUnresolvedLogicalSource = currentIsStableLogicalSource
                && preferredCameraID == nil
                && !cameraSelectionDisabledByUser
            let logicalSourceToRestore = preserveUnresolvedLogicalSource
                ? currentLogicalSourceID
                : snapshot.selectedCameraID

            let previousSourceID = selectedCameraID
            selectedCameraID = logicalSourceToRestore
            recordSelectedCameraSourceTransition(
                previous: previousSourceID,
                next: logicalSourceToRestore,
                source: "HockeyCameraService.restoreCaptureSelectionSnapshot",
                reason: preserveUnresolvedLogicalSource
                    ? "Recovery AA retained unresolved logical source while restoring physical selection snapshot: \(reason)"
                    : reason
            )
            preferredCameraID = snapshot.preferredCameraID
            cameraSelectionDisabledByUser = preserveUnresolvedLogicalSource
                ? false
                : snapshot.cameraSelectionDisabledByUser
            preferredVideoFormatID = snapshot.preferredVideoFormatID
            preferredVideoFormatIDByCameraID = snapshot.preferredVideoFormatIDByCameraID
            preferredVideoFrameRate = snapshot.preferredVideoFrameRate
            preferredVideoFrameRateByCameraID = snapshot.preferredVideoFrameRateByCameraID
            captureFormatPreferenceOverride = snapshot.captureFormatPreferenceOverride
            captureFormatPreferenceByCameraID = snapshot.captureFormatPreferenceByCameraID
            appleStyleAutoQualityCaptureEnabled = snapshot.appleStyleAutoQualityCaptureEnabled
            captureSelectionPublicationEpoch &+= 1

            if cameraSelectionDisabledByUser {
                cameraDevice = nil
            } else {
                let devices = discoveredVideoDevices()
                cameraDevice = snapshot.preferredCameraID.flatMap { physicalID in
                    devices.first(where: { $0.uniqueID == physicalID })
                } ?? logicalSourceToRestore.flatMap { logicalID in
                    resolveCameraDevice(sourceID: logicalID, from: devices)
                }
            }
            currentInput = nil
            isConfigured = false
            cameraBreadcrumb(
                .selection,
                phase: preserveUnresolvedLogicalSource
                    ? "Recovery AA physical rollback retained logical source"
                    : "UX16c37 selection rollback restored",
                extra: "reason=\(reason) logical=\(logicalSourceToRestore ?? "none") physical=\(snapshot.preferredCameraID ?? "none") format=\(snapshot.captureFormatPreferenceOverride?.diagnosticText ?? "auto")"
            )
            return preserveUnresolvedLogicalSource ? currentLogicalSourceID : nil
        }

        if let retainedLogicalSourceID {
            // The physical graph/format rollback completed, but the logical source
            // remains authoritative and unresolved until discovery can resolve it.
            resolvedCameraDeviceID = nil
            activeCaptureDeviceID = nil
            activeCaptureDeviceName = nil
            activeCaptureDeviceIsExternal = false
            activeCaptureDevicePosition = .unspecified
            isCameraSelectionDisabled = false
            selectedCameraName = retainedLogicalSourceID == Self.externalCameraSourceID
                ? "External Camera"
                : "Unavailable camera"
            selectedCameraIsExternal = retainedLogicalSourceID == Self.externalCameraSourceID
            selectedCameraPosition = retainedLogicalSourceID == Self.builtInBackCameraSourceID
                ? .back
                : (retainedLogicalSourceID == Self.builtInFrontCameraSourceID ? .front : .unspecified)
            availableVideoFormats = snapshot.availableVideoFormats
            selectedVideoFormatID = snapshot.selectedVideoFormatID
            videoFormatsLoaded = snapshot.videoFormatsLoaded
            isLoadingVideoFormats = false
            videoFormatLoadStatusText = snapshot.videoFormatLoadStatusText
            capabilityProfiles = snapshot.capabilityProfiles
            selectedCapabilityProfileID = snapshot.selectedCapabilityProfileID
            selectedResolutionFPS = snapshot.selectedResolutionFPS
            appleStyleAutoQualityEnabled = snapshot.appleStyleAutoQualityEnabled
            cameraStatusText = retainedLogicalSourceID == Self.externalCameraSourceID
                ? "External camera is not connected — selection retained"
                : "Selected camera source is unavailable — selection retained"
            sessionResourceStateText = "Recovery AA physical selection rollback completed; logical camera source retained"
            captureGraphStatusText = "Recovery AA unresolved logical source retained after physical rollback: \(retainedLogicalSourceID) — \(reason)"
            return
        }

        resolvedCameraDeviceID = snapshot.resolvedCameraDeviceID
        activeCaptureDeviceID = nil
        activeCaptureDeviceName = nil
        activeCaptureDeviceIsExternal = false
        activeCaptureDevicePosition = .unspecified
        isCameraSelectionDisabled = snapshot.isCameraSelectionDisabled
        selectedCameraName = snapshot.selectedCameraName
        selectedCameraIsExternal = snapshot.selectedCameraIsExternal
        selectedCameraPosition = snapshot.selectedCameraPosition
        availableVideoFormats = snapshot.availableVideoFormats
        selectedVideoFormatID = snapshot.selectedVideoFormatID
        videoFormatsLoaded = snapshot.videoFormatsLoaded
        isLoadingVideoFormats = false
        videoFormatLoadStatusText = snapshot.videoFormatLoadStatusText
        capabilityProfiles = snapshot.capabilityProfiles
        selectedCapabilityProfileID = snapshot.selectedCapabilityProfileID
        selectedResolutionFPS = snapshot.selectedResolutionFPS
        appleStyleAutoQualityEnabled = snapshot.appleStyleAutoQualityEnabled
        cameraStatusText = snapshot.cameraStatusText
        sessionResourceStateText = snapshot.sessionResourceStateText
        captureGraphStatusText = "\(snapshot.captureGraphStatusText) • rolled back: \(reason)"
    }

    /// UX16c18: Stage an explicit logical Back/Front/External source on the
    /// camera queue before startup. This avoids the saved OCR source being visible
    /// in Settings while preparePreferredCamera starts a different physical device.
    @discardableResult
    func stageLogicalCameraSource(_ sourceID: String, reason: String) -> String? {
        cameraBreadcrumb(.selection, phase: "stage logical source requested", extra: "source=\(sourceID) reason=\(reason)")
        let resolvedID: String? = outputQueue.sync {
            self.cameraBreadcrumb(.selection, phase: "stage logical source entered queue", extra: "source=\(sourceID) reason=\(reason)")
            captureSelectionPublicationEpoch &+= 1
            let publicationEpoch = captureSelectionPublicationEpoch
            let devices = discoveredVideoDevices()
            guard let resolved = resolveCameraDevice(sourceID: sourceID, from: devices) else {
                // Recovery Z / RL-059: logical selection and physical availability
                // are separate state. An explicit saved/operator source remains the
                // selected source even when discovery cannot currently resolve a
                // device. Do not let a later automatic allocator reinterpret
                // temporary absence as permission to choose a different camera.
                let previousSourceID = selectedCameraID
                selectedCameraID = sourceID
                preferredCameraID = nil
                cameraDevice = nil
                currentInput = nil
                isConfigured = false
                cameraSelectionDisabledByUser = false
                recordSelectedCameraSourceTransition(
                    previous: previousSourceID,
                    next: sourceID,
                    source: "HockeyCameraService.stageLogicalCameraSource",
                    reason: "Recovery Z retained unresolved logical source: \(reason)"
                )
                self.cameraBreadcrumb(.selection, phase: "Recovery Z logical source retained unresolved", extra: "source=\(sourceID) reason=\(reason) discovered=\(devices.map { "\($0.localizedName){\($0.uniqueID)}" }.joined(separator: ","))")
                DispatchQueue.main.async {
                    guard self.captureSelectionPublicationIsCurrent(publicationEpoch) else { return }
                    self.selectedCameraID = sourceID
                    self.resolvedCameraDeviceID = nil
                    self.isCameraSelectionDisabled = false
                    self.selectedCameraIsExternal = sourceID == Self.externalCameraSourceID
                    self.selectedCameraPosition = sourceID == Self.builtInBackCameraSourceID
                        ? .back
                        : (sourceID == Self.builtInFrontCameraSourceID ? .front : .unspecified)
                    self.selectedCameraName = sourceID == Self.externalCameraSourceID
                        ? "External Camera"
                        : "Unavailable camera"
                    self.cameraStatusText = sourceID == Self.externalCameraSourceID
                        ? "External camera is not connected — selection retained"
                        : "Selected camera source is unavailable — selection retained"
                    self.sessionResourceStateText = "Recovery Z logical camera selection retained; awaiting physical availability"
                    self.captureGraphStatusText = "Recovery Z source unresolved but retained: \(sourceID) — \(reason)"
                }
                return nil
            }

            selectedCameraID = sourceID
            preferredCameraID = resolved.uniqueID
            captureFormatPreferenceOverride = captureFormatPreferenceByCameraID[resolved.uniqueID]
            cameraDevice = resolved
            currentInput = nil
            isConfigured = false
            cameraSelectionDisabledByUser = false

            let configuredSource = cameraDevice.map { logicalCameraSourceID(for: $0) }
            if configuredSource != sourceID || currentInput == nil {
                isConfigured = false
            }

            self.cameraBreadcrumb(.selection, phase: "stage logical source completed", extra: "source=\(sourceID) resolved=\(resolved.localizedName){\(resolved.uniqueID)} reason=\(reason)")
            DispatchQueue.main.async {
                guard self.captureSelectionPublicationIsCurrent(publicationEpoch) else { return }
                self.selectedCameraID = sourceID
                self.resolvedCameraDeviceID = resolved.uniqueID
                self.isCameraSelectionDisabled = false
                self.selectedCameraName = resolved.localizedName
                self.selectedCameraIsExternal = resolved.deviceType == .external
                self.selectedCameraPosition = resolved.position
                self.cameraStatusText = "Camera source staged: \(self.selectedCameraLabel)"
                self.captureGraphStatusText = "Source staged for rebuild: \(sourceID) — \(reason)"
            }
            return resolved.uniqueID
        }
        if resolvedID != nil {
            refreshVideoFormats(force: true, reason: "logical source selected: \(reason)")
        }
        return resolvedID
    }

    @discardableResult
    func preparePreferredCamera(excluding excludedIDs: Set<String> = [], preferExternal: Bool? = nil) -> String? {
        cameraBreadcrumb(.selection, phase: "prepare preferred requested", extra: "excluded=\(excludedIDs.sorted().joined(separator: ",")) preferExternal=\(String(describing: preferExternal))")
        return outputQueue.sync {
            guard !cameraSelectionDisabledByUser else {
                self.cameraBreadcrumb(.selection, phase: "prepare preferred blocked", extra: "operator disabled")
                return nil
            }
            let discovered = discoveredVideoDevices()

            // Recovery Z / RL-059: this helper is an automatic allocator only.
            // It must never replace an already-selected logical source. Resolve
            // that source if possible; otherwise leave it selected and wait for
            // discovery/reconnect to make a physical device available.
            if let selectedLogicalSourceID = selectedCameraID {
                if let resolved = resolveCameraDevice(sourceID: selectedLogicalSourceID, from: discovered) {
                    preferredCameraID = resolved.uniqueID
                    cameraDevice = resolved
                    currentInput = nil
                    isConfigured = false
                    self.cameraBreadcrumb(
                        .selection,
                        phase: "Recovery Z prepare preferred preserved selected source",
                        extra: "logical=\(selectedLogicalSourceID) device=\(resolved.localizedName){\(resolved.uniqueID)}"
                    )
                    DispatchQueue.main.async {
                        self.selectedCameraID = selectedLogicalSourceID
                        self.resolvedCameraDeviceID = resolved.uniqueID
                        self.isCameraSelectionDisabled = false
                        self.selectedCameraName = resolved.localizedName
                        self.selectedCameraIsExternal = resolved.deviceType == .external
                        self.selectedCameraPosition = resolved.position
                        self.cameraStatusText = "Selected camera source prepared: \(self.selectedCameraLabel)"
                    }
                    return resolved.uniqueID
                }

                preferredCameraID = nil
                cameraDevice = nil
                currentInput = nil
                isConfigured = false
                self.cameraBreadcrumb(
                    .selection,
                    phase: "Recovery Z prepare preferred retained unavailable source",
                    extra: "logical=\(selectedLogicalSourceID)"
                )
                DispatchQueue.main.async {
                    self.selectedCameraID = selectedLogicalSourceID
                    self.resolvedCameraDeviceID = nil
                    self.isCameraSelectionDisabled = false
                    self.selectedCameraIsExternal = selectedLogicalSourceID == Self.externalCameraSourceID
                    self.selectedCameraName = selectedLogicalSourceID == Self.externalCameraSourceID
                        ? "External Camera"
                        : "Unavailable camera"
                    self.cameraStatusText = "Selected camera source unavailable — waiting for reconnect"
                }
                return nil
            }

            let devices = devicesByExcludingLogicalSources(discovered, excludedIDs: excludedIDs)
            let selected = preferredDevice(from: devices, preferExternal: preferExternal)
            preferredCameraID = selected?.uniqueID
            cameraDevice = selected
            currentInput = nil
            isConfigured = false

            if let selected {
                let sourceID = logicalCameraSourceID(for: selected)
                selectedCameraID = sourceID
                DispatchQueue.main.async {
                    self.selectedCameraID = sourceID
                    self.resolvedCameraDeviceID = selected.uniqueID
                    self.isCameraSelectionDisabled = false
                    self.selectedCameraName = selected.localizedName
                    self.selectedCameraIsExternal = selected.deviceType == .external
                    self.selectedCameraPosition = selected.position
                    self.cameraStatusText = "Camera source prepared: \(self.selectedCameraLabel)"
                }
            } else if !excludedIDs.isEmpty {
                // UX16c13: an automatic startup/exclusion pass must never masquerade
                // as the operator pressing "Set this role to None". A transient
                // one-source discovery snapshot was permanently setting
                // cameraSelectionDisabledByUser, so later built-in/external refreshes
                // could not restore the logical source and OCR Setup never reached
                // permission checking or AVCaptureDeviceInput creation.
                DispatchQueue.main.async {
                    self.resolvedCameraDeviceID = nil
                    self.isCameraSelectionDisabled = self.cameraSelectionDisabledByUser
                    if !self.cameraSelectionDisabledByUser {
                        self.cameraStatusText = "No separate camera available yet — selection retained for route activation"
                        self.sessionResourceStateText = "Automatic source allocation deferred; operator selection not cleared"
                    }
                }
            }
            return selected?.uniqueID
        }
    }




    // Build 780: Broadcast zoom and lens-family mutations are owned by
    // CaptureLifecycleController/CaptureEngine. HockeyCameraService retains camera
    // discovery, selection and non-zoom control APIs only.

    private func cameraBreadcrumbDescription(_ device: AVCaptureDevice?) -> String {
        guard let device else { return "nil" }
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { String(format: "%.2f", $0.doubleValue) }.joined(separator: ",")
        return "\(device.localizedName) type=\(device.deviceType.rawValue) min=\(String(format: "%.2f", Double(device.minAvailableVideoZoomFactor))) max=\(String(format: "%.2f", Double(device.maxAvailableVideoZoomFactor))) current=\(String(format: "%.2f", Double(device.videoZoomFactor))) displayMultiplier=\(String(format: "%.2f", Double(device.displayVideoZoomFactorMultiplier))) switchOvers=\(switchOvers)"
    }

    private func traceBroadcastZoom(_ message: String) {
        DispatchQueue.main.async {
            MainThreadStallMonitor.shared.traceZoomMovement("broadcast zoom: \(message)")
        }
    }

    // Build 780: retired the unreferenced HockeyCameraService lens-switch,
    // exposure-settle and focus-reapply implementation. CaptureEngine owns the
    // complete Broadcast camera transaction.

    /// Build 782: OCR-only camera zoom application. Broadcast logical zoom and
    /// lens-family changes remain exclusively owned by CaptureLifecycleController.
    /// This method mutates only the already-resolved OCR AVCaptureDevice and
    /// publishes the verified applied projection; it cannot execute on the
    /// Broadcast camera facade.
    func setOCRZoomFactor(_ factor: CGFloat, reason: String) {
        outputQueue.async { [weak self] in
            guard let self else { return }
            guard self.operationalRole == .ocr else {
                RinkLensStructuredEventLogger.shared.record(
                    domain: .cameraControl,
                    event: "camera_ocr_zoom_rejected",
                    entityID: "broadcast-facade",
                    previous: ["appliedZoom": String(Double(self.currentZoomFactor))],
                    next: ["requestedZoom": String(Double(factor)), "applied": "false"],
                    source: "HockeyCameraService.setOCRZoomFactor",
                    reason: "Rejected OCR-only zoom request on Broadcast facade: \(reason)",
                    authoritativeOwner: "HockeyCameraService"
                )
                return
            }

            self.externalCaptureOwnerLock.lock()
            let externallyManagedDevice = self.externalCaptureOwnerDevice
            self.externalCaptureOwnerLock.unlock()
            guard let device = externallyManagedDevice ?? self.cameraDevice else {
                RinkLensStructuredEventLogger.shared.record(
                    domain: .cameraControl,
                    event: "camera_ocr_zoom_rejected",
                    entityID: self.selectedCameraID ?? "ocr-camera",
                    previous: ["device": "none", "appliedZoom": String(Double(self.currentZoomFactor))],
                    next: ["requestedZoom": String(Double(factor)), "applied": "false"],
                    source: "HockeyCameraService.setOCRZoomFactor",
                    reason: "OCR camera device unavailable: \(reason)",
                    authoritativeOwner: "HockeyCameraService"
                )
                DispatchQueue.main.async {
                    self.cameraStatusText = "OCR zoom unavailable — camera is still starting"
                }
                return
            }

            let minimum = max(CGFloat(1.0), device.minAvailableVideoZoomFactor)
            let maximum = min(CGFloat(5.0), max(minimum, device.maxAvailableVideoZoomFactor))
            let requested = factor.isFinite ? factor : minimum
            let applied = min(max(requested, minimum), maximum)
            let previous = device.videoZoomFactor

            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = applied
                device.unlockForConfiguration()
                self.zoomFactorByCameraID[device.uniqueID] = applied
                RinkLensCaptureGraphMutationAudit.shared.record(
                    .liveDeviceControl,
                    detail: "OCR zoom applied; device=\(device.uniqueID); previous=\(String(format: "%.2f", Double(previous))); next=\(String(format: "%.2f", Double(applied))); sessionRestarted=false"
                )
                RinkLensStructuredEventLogger.shared.record(
                    domain: .cameraControl,
                    event: "camera_ocr_zoom_applied",
                    entityID: device.uniqueID,
                    previous: ["appliedZoom": String(Double(previous))],
                    next: ["requestedZoom": String(Double(factor)), "appliedZoom": String(Double(applied))],
                    source: "HockeyCameraService.setOCRZoomFactor",
                    reason: reason,
                    authoritativeOwner: "HockeyCameraService"
                )
                DispatchQueue.main.async {
                    self.currentZoomFactor = applied
                    self.cameraStatusText = String(format: "OCR zoom %.1fx", Double(applied))
                }
            } catch {
                RinkLensStructuredEventLogger.shared.record(
                    domain: .cameraControl,
                    event: "camera_ocr_zoom_failed",
                    entityID: device.uniqueID,
                    previous: ["appliedZoom": String(Double(previous))],
                    next: ["requestedZoom": String(Double(factor)), "applied": "false", "error": error.localizedDescription],
                    source: "HockeyCameraService.setOCRZoomFactor",
                    reason: reason,
                    authoritativeOwner: "HockeyCameraService"
                )
                DispatchQueue.main.async {
                    self.cameraStatusText = "OCR zoom failed"
                }
            }
        }
    }

    private func releaseSessionResourcesOnOutputQueue(reason: String) {
        cameraBreadcrumb(.release, phase: "facade resources cleared", extra: "reason=\(reason)")
        currentInput = nil
        isConfigured = false
        RinkLensFrameHub.shared.clear(
            role: frameHubRole,
            reason: "camera facade cleared: \(reason)"
        )
        resetFrameHealthForExplicitReconfigure()
        let role = sampleBufferOutputEnabled ? "OCR" : "Broadcast"
        DispatchQueue.main.async {
            self.sessionResourceStateText = "\(role) facade cleared: \(reason); CaptureEngine ownership unchanged"
            self.previewLayerAttached = false
            self.previewLayerReadyForDisplay = false
            self.previewSessionAssignedText = "CaptureEngine preview endpoint"
            self.lastPreviewLayerEventText = "Compatibility facade cleared"
            self.publishCameraSessionState(.idle, event: "Compatibility camera facade cleared")
        }
    }

    func releaseSessionResources(reason: String) {
        cameraBreadcrumb(.release, phase: "release resources requested", extra: "reason=\(reason)")
        outputQueue.async { [weak self] in
            guard let self else { return }
            guard RinkLensRecordingCaptureLease.shared.allowMutation(
                action: "release inactive camera input",
                requester: reason,
                owner: self.sampleBufferOutputEnabled ? "OCR Camera" : "Live Camera"
            ) else { return }
            self.releaseSessionResourcesOnOutputQueue(reason: reason)
        }
    }

    /// UX16c11: Route hand-off needs a completion point. The earlier fire-and-forget
    /// release could still be queued on the inactive service while OCR attempted to
    /// reclaim the camera, leaving the selected source staged but the session stopped.
    func releaseSessionResourcesAndWait(reason: String) async {
        cameraBreadcrumb(.release, phase: "legacy resource release ignored", extra: "CaptureEngine owns runtime reason=\(reason)")
    }

    func activateSelectedCameraForVisibleRoute(reason: String) async -> Bool {
        cameraBreadcrumb(.lifecycle, phase: "visible route activation requested", extra: "reason=\(reason)")
        return await withCheckedContinuation { continuation in
            outputQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }
                DispatchQueue.main.async {
                    MainThreadStallMonitor.shared.traceCameraStartupTimeline(
                        RinkLensBuildInfo.traceContext(
                            "visible route activation entered role=\(self.sampleBufferOutputEnabled ? "OCR" : "Broadcast") selected=\(self.selectedCameraID ?? "none") disabled=\(self.cameraSelectionDisabledByUser) reason=\(reason)"
                        )
                    )
                }
                guard RinkLensRecordingCaptureLease.shared.allowMutation(
                    action: "activate selected camera for visible route",
                    requester: reason,
                    owner: self.sampleBufferOutputEnabled ? "OCR Camera" : "Live Camera"
                ) else {
                    continuation.resume(returning: false)
                    return
                }
                guard !self.cameraSelectionDisabledByUser else {
                    DispatchQueue.main.async {
                        self.cameraStatusText = "No camera selected"
                        self.sessionResourceStateText = "Activation blocked: no logical camera selected"
                    }
                    continuation.resume(returning: false)
                    return
                }

                let devices = self.discoveredVideoDevices()
                let requestedSource = self.selectedCameraID
                if let requestedSource,
                   let resolved = self.resolveCameraDevice(sourceID: requestedSource, from: devices) {
                    self.preferredCameraID = resolved.uniqueID
                }

                guard self.beginExplicitReconfiguration(status: self.sampleBufferOutputEnabled ? "Starting OCR camera" : "Starting live camera") else {
                    continuation.resume(returning: self.session.isRunning)
                    return
                }

                do {
                    if self.session.isRunning {
                        self.session.stopRunning()
                    }
                    self.resetFrameHealthForExplicitReconfigure()
                    try self.configureSession(forceReconfigure: true)
                    _ = self.startSessionIfNeeded(
                        reason: "UX16c12 visible-route activation: \(reason)",
                        force: true
                    )
                    let running = self.session.isRunning
                    if running {
                        self.markPreviewOnlySessionHealthy(status: self.sampleBufferOutputEnabled ? "OCR camera active" : "Live camera active")
                        self.recordSessionRestart(reason: "visible route activation")
                        self.endExplicitReconfiguration(status: self.sampleBufferOutputEnabled ? "OCR camera active" : "Live camera active")
                        self.requestPreviewLayerReset(reason: "visible route camera activated")
                    } else {
                        self.endExplicitReconfiguration(status: "Camera configured but session did not start")
                        DispatchQueue.main.async {
                            self.sessionResourceStateText = "Input configured; AVCaptureSession remained stopped"
                        }
                    }
                    DispatchQueue.main.async {
                        MainThreadStallMonitor.shared.trace(
                            RinkLensBuildInfo.traceContext("visible route activation role=\(self.sampleBufferOutputEnabled ? "OCR" : "Broadcast") requested=\(requestedSource ?? "none") resolved=\(self.resolvedCameraDeviceID ?? "none") running=\(running) reason=\(reason)")
                        )
                    }
                    continuation.resume(returning: running)
                } catch {
                    self.endExplicitReconfiguration()
                    DispatchQueue.main.async {
                        self.cameraStatusText = "Camera activation failed: \(error.localizedDescription)"
                        self.sessionResourceStateText = "Visible route activation failed: \(error.localizedDescription)"
                        MainThreadStallMonitor.shared.trace(
                            RinkLensBuildInfo.traceContext("visible route activation failed role=\(self.sampleBufferOutputEnabled ? "OCR" : "Broadcast") error=\(error.localizedDescription) reason=\(reason)")
                        )
                    }
                    continuation.resume(returning: false)
                }
            }
        }
    }


    /// UX16c14: Stage one authoritative logical source and wait until both the
    /// capture queue and published Picker state agree. This replaces fixed sleeps
    /// between source selection and activation.
    @discardableResult
    func stagePreferredCameraForVisibleRoute(
        preferredSourceID: String?,
        preferExternalWhenNoPreference: Bool = false,
        reason: String
    ) async -> String? {
        await withCheckedContinuation { continuation in
            outputQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }

                let devices = self.discoveredVideoDevices()
                let resolvedPreferred = preferredSourceID.flatMap {
                    self.resolveCameraDevice(sourceID: $0, from: devices)
                }
                let selectedDevice = resolvedPreferred
                    ?? self.preferredDevice(from: devices, preferExternal: preferExternalWhenNoPreference)

                guard let selectedDevice else {
                    DispatchQueue.main.async {
                        self.cameraStatusText = "No camera source is currently available"
                        self.sessionResourceStateText = "Logical source staging failed: no discovered device"
                        MainThreadStallMonitor.shared.traceCameraStartupTimeline(
                            RinkLensBuildInfo.traceContext(
                                "logical source staging failed preferred=\(preferredSourceID ?? "none") reason=\(reason)"
                            )
                        )
                        continuation.resume(returning: nil)
                    }
                    return
                }

                let sourceID = self.logicalCameraSourceID(for: selectedDevice)
                self.cameraSelectionDisabledByUser = false
                self.selectedCameraID = sourceID
                self.preferredCameraID = selectedDevice.uniqueID
                self.preferredVideoFormatID = self.preferredVideoFormatIDByCameraID[selectedDevice.uniqueID]
                self.preferredVideoFrameRate = self.preferredVideoFrameRateByCameraID[selectedDevice.uniqueID]
                self.captureFormatPreferenceOverride = self.captureFormatPreferenceByCameraID[selectedDevice.uniqueID]

                DispatchQueue.main.async {
                    self.selectedCameraID = sourceID
                    self.resolvedCameraDeviceID = selectedDevice.uniqueID
                    self.isCameraSelectionDisabled = false
                    self.selectedCameraName = selectedDevice.localizedName
                    self.selectedCameraIsExternal = selectedDevice.deviceType == .external
                    self.selectedCameraPosition = selectedDevice.position
                    self.cameraStatusText = "Camera source staged: \(self.selectedCameraLabel)"
                    self.sessionResourceStateText = "Logical source staged for visible-route activation"
                    MainThreadStallMonitor.shared.traceCameraStartupTimeline(
                        RinkLensBuildInfo.traceContext(
                            "logical source staged source=\(sourceID) device=\(selectedDevice.uniqueID) reason=\(reason)"
                        )
                    )
                    continuation.resume(returning: sourceID)
                }
            }
        }
    }


    func selectBestAvailableCamera(excluding excludedIDs: Set<String> = [], preferExternal: Bool? = nil) {
        outputQueue.async {
            let discovered = self.discoveredVideoDevices()
            let devices = self.devicesByExcludingLogicalSources(discovered, excludedIDs: excludedIDs)
            guard let selected = self.preferredDevice(from: devices, preferExternal: preferExternal) else { return }
            let sourceID = self.logicalCameraSourceID(for: selected)
            self.cameraSelectionDisabledByUser = false
            self.selectedCameraID = sourceID
            self.preferredCameraID = selected.uniqueID
            self.preferredVideoFormatID = self.preferredVideoFormatIDByCameraID[selected.uniqueID]
            self.preferredVideoFrameRate = self.preferredVideoFrameRateByCameraID[selected.uniqueID]
            self.captureFormatPreferenceOverride = self.captureFormatPreferenceByCameraID[selected.uniqueID]
            self.cameraDevice = selected
            self.currentInput = nil
            self.isConfigured = false
            self.cameraBreadcrumb(
                .selection,
                phase: "best camera staged for CaptureEngine",
                extra: "logical=\(sourceID) device=\(selected.localizedName){\(selected.uniqueID)}"
            )
            DispatchQueue.main.async {
                self.selectedCapabilityProfileID = nil
                self.selectedCameraID = sourceID
                self.resolvedCameraDeviceID = selected.uniqueID
                self.isCameraSelectionDisabled = false
                self.selectedCameraName = selected.localizedName
                self.selectedCameraIsExternal = selected.deviceType == .external
                self.selectedCameraPosition = selected.position
                self.cameraStatusText = "Camera source staged for CaptureEngine: \(selected.localizedName)"
                self.sessionResourceStateText = "Private AVCaptureSession disabled; CaptureEngine owns the selected device"
                self.captureGraphStatusText = "CaptureEngine selection staged: \(sourceID)"
            }
        }
    }

    func selectCamera(id: String) {
        cameraBreadcrumb(.selection, phase: "selectCamera requested", extra: "id=\(id)")
        outputQueue.async {
            let previousSourceID = self.selectedCameraID
            self.cameraSelectionDisabledByUser = false
            self.selectedCameraID = id
            self.recordSelectedCameraSourceTransition(
                previous: previousSourceID,
                next: id,
                source: "HockeyCameraService.selectCamera",
                reason: "Operator selected a logical camera source"
            )

            let devices = self.discoveredVideoDevices()
            guard let resolvedDevice = self.resolveCameraDevice(sourceID: id, from: devices) else {
                self.cameraDevice = nil
                self.currentInput = nil
                self.isConfigured = false
                self.cameraBreadcrumb(
                    .selection,
                    phase: "CaptureEngine source unresolved",
                    extra: "id=\(id) discovered=\(devices.map { "\($0.localizedName){\($0.uniqueID)}" }.joined(separator: ","))"
                )
                DispatchQueue.main.async {
                    self.selectedCameraID = id
                    self.resolvedCameraDeviceID = nil
                    self.isCameraSelectionDisabled = false
                    self.selectedCameraIsExternal = id == Self.externalCameraSourceID
                    self.selectedCameraPosition = id == Self.builtInBackCameraSourceID
                        ? .back
                        : (id == Self.builtInFrontCameraSourceID ? .front : .unspecified)
                    self.selectedCameraName = id == Self.externalCameraSourceID ? "External Camera" : "Unavailable camera"
                    self.cameraStatusText = id == Self.externalCameraSourceID
                        ? "External camera is not connected"
                        : "Selected camera source is unavailable"
                    self.sessionResourceStateText = "CaptureEngine logical source retained; no physical device available"
                    self.captureGraphStatusText = "CaptureEngine source unresolved: \(id)"
                }
                return
            }

            let resolvedID = resolvedDevice.uniqueID
            self.preferredCameraID = resolvedID
            self.preferredVideoFormatID = self.preferredVideoFormatIDByCameraID[resolvedID]
            self.preferredVideoFrameRate = self.preferredVideoFrameRateByCameraID[resolvedID]
            self.captureFormatPreferenceOverride = self.captureFormatPreferenceByCameraID[resolvedID]
            self.cameraDevice = resolvedDevice
            self.currentInput = nil
            self.isConfigured = false
            self.externalReconnectPending = false
            self.lastDisconnectedExternalDeviceID = nil
            self.cameraBreadcrumb(
                .selection,
                phase: "source staged for CaptureEngine",
                extra: "logical=\(id) device=\(resolvedDevice.localizedName){\(resolvedID)}"
            )
            DispatchQueue.main.async {
                self.selectedCapabilityProfileID = nil
                self.selectedCameraID = id
                self.resolvedCameraDeviceID = resolvedID
                self.isCameraSelectionDisabled = false
                self.selectedCameraName = resolvedDevice.localizedName
                self.selectedCameraIsExternal = resolvedDevice.deviceType == .external
                self.selectedCameraPosition = resolvedDevice.position
                self.cameraStatusText = "Selected for CaptureEngine: \(resolvedDevice.localizedName)"
                self.sessionResourceStateText = "Private AVCaptureSession disabled; CaptureEngine owns runtime capture"
                self.captureGraphStatusText = "CaptureEngine selection staged: \(id) -> \(resolvedID)"
                if id == Self.externalCameraSourceID {
                    self.externalReconnectStatusText = "External camera staged for CaptureEngine"
                }
            }
        }
    }

    @discardableResult
    func stageNoCamera(reason: String) -> Bool {
        outputQueue.sync {
            let previousSourceID = selectedCameraID
            captureSelectionPublicationEpoch &+= 1
            cameraSelectionDisabledByUser = true
            selectedCameraID = nil
            recordSelectedCameraSourceTransition(
                previous: previousSourceID,
                next: nil,
                source: "HockeyCameraService.stageNoCamera",
                reason: reason
            )
            preferredCameraID = nil
            preferredVideoFormatID = nil
            preferredVideoFrameRate = nil
            captureFormatPreferenceOverride = nil
            cameraDevice = nil
            currentInput = nil
            isConfigured = false
            cameraBreadcrumb(.selection, phase: "CaptureEngine no-camera staged", extra: reason)
        }
        selectedCameraID = nil
        resolvedCameraDeviceID = nil
        isCameraSelectionDisabled = true
        selectedCameraName = "None"
        selectedCameraIsExternal = false
        selectedCameraPosition = .unspecified
        availableVideoFormats = []
        selectedVideoFormatID = nil
        capabilityProfiles = []
        selectedCapabilityProfileID = nil
        selectedResolutionFPS = "No camera"
        cameraStatusText = "No camera selected"
        captureGraphStatusText = "No camera staged — \(reason)"
        return true
    }

    func selectNoCamera() {
        cameraBreadcrumb(.selection, phase: "EXPLICIT selectNoCamera requested")
        outputQueue.async {
            self.cameraBreadcrumb(.selection, phase: "EXPLICIT selectNoCamera entered output queue")
            guard self.beginExplicitReconfiguration(status: "Clearing camera selection") else { return }
            let previousSourceID = self.selectedCameraID
            self.cameraSelectionDisabledByUser = true
            self.selectedCameraID = nil
            self.recordSelectedCameraSourceTransition(
                previous: previousSourceID,
                next: nil,
                source: "HockeyCameraService.selectNoCamera",
                reason: "Operator explicitly disabled this camera role"
            )
            self.preferredCameraID = nil
            self.preferredVideoFormatID = nil
            self.preferredVideoFrameRate = nil

            self.currentInput = nil
            self.cameraDevice = nil
            self.isConfigured = false
            self.resetFrameHealthForExplicitReconfigure()

            DispatchQueue.main.async {
                self.selectedCameraID = nil
                self.resolvedCameraDeviceID = nil
                self.isCameraSelectionDisabled = true
                self.selectedCameraName = "None"
                self.selectedCameraIsExternal = false
                self.selectedCameraPosition = .unspecified
                self.availableVideoFormats = []
                self.selectedVideoFormatID = nil
                self.capabilityProfiles = []
                self.selectedCapabilityProfileID = nil
                self.selectedResolutionFPS = "No camera"
                self.currentZoomFactor = 1.0
                self.minZoomFactor = 1.0
                self.maxZoomFactor = 5.0
                self.cameraStatusText = "No camera selected"
                self.visibleCameraHealthy = true
            }
            self.recordSessionRestart(reason: "camera selection cleared")
                self.endExplicitReconfiguration(status: "No camera selected")
            self.requestPreviewLayerReset(reason: "camera selection cleared by operator")
        }
    }

    /// Compatibility entry point for older settings/template code. Stage the
    /// requested exact format for CaptureEngine; never start, stop or rebuild a
    /// private AVCaptureSession.
    func selectVideoFormat(id: String, force: Bool = false) {
        _ = stageVideoFormat(
            id: id,
            requestedFPS: nil,
            reason: force ? "forced compatibility format selection" : "compatibility format selection"
        )
    }

    @discardableResult
    func stageVideoFormat(
        id: String,
        requestedFPS: Int?,
        reason: String
    ) -> Bool {
        stageVideoFormat(
            id: id,
            requestedCadence: requestedFPS.map { RinkLensCaptureCadence(integerFPS: $0) },
            reason: reason
        )
    }

    @discardableResult
    func stageVideoFormat(
        id: String,
        requestedCadence: RinkLensCaptureCadence?,
        reason: String
    ) -> Bool {
        let previousRequest = requestedCameraControlSummary()
        let staged: (formatID: String, cadence: RinkLensCaptureCadence, width: Int32, height: Int32, label: String)? = outputQueue.sync {
            guard let format = videoFormatMap[id], format.isMultiCamSupported else { return nil }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width > 0, dimensions.height > 0 else { return nil }

            let supported = supportedCaptureCadences(for: format, includeAdvanced: true)
            guard !supported.isEmpty else { return nil }

            let preferredCadence = captureFormatPreferenceOverride?.cadence
            let preferredCandidates = [
                requestedCadence,
                preferredCadence,
                RinkLensCaptureCadence(integerFPS: 30),
                RinkLensCaptureCadence(durationValue: 1_001, durationTimescale: 30_000),
                RinkLensCaptureCadence(integerFPS: 25),
                RinkLensCaptureCadence(integerFPS: 15)
            ].compactMap { $0 }
            let cadence = preferredCandidates.first(where: { supported.contains($0) })
                ?? supported.last(where: { $0.framesPerSecond <= 60.01 })
                ?? supported.last!

            preferredVideoFormatID = id
            preferredVideoFrameRate = cadence.nominalFPS
            captureFormatPreferenceOverride = RinkLensCaptureFormatPreference(
                width: dimensions.width,
                height: dimensions.height,
                cadence: cadence
            )
            roleDefaultProfileCaptureEnabled = false
            if !RinkLensRiskFeaturePolicy.isEnabled(.operationalCameraOverridesV10) {
                appleStyleAutoQualityCaptureEnabled = false
            }
            if let cameraID = preferredCameraID ?? cameraDevice?.uniqueID {
                preferredVideoFormatIDByCameraID[cameraID] = id
                preferredVideoFrameRateByCameraID[cameraID] = cadence.nominalFPS
                captureFormatPreferenceByCameraID[cameraID] = RinkLensCaptureFormatPreference(
                    width: dimensions.width,
                    height: dimensions.height,
                    cadence: cadence
                )
            }
            cameraBreadcrumb(
                .selection,
                phase: "exact CaptureEngine format staged by format ID",
                extra: "mode=\(dimensions.width)x\(dimensions.height)@\(cadence.displayText) reason=\(reason)"
            )
            return (
                formatID: id,
                cadence: cadence,
                width: dimensions.width,
                height: dimensions.height,
                label: capabilityProfileLabel(for: format, cadence: cadence)
            )
        }

        guard let staged else { return false }
        selectedVideoFormatID = staged.formatID
        selectedCapabilityProfileID = capabilityProfiles.first(where: {
            $0.formatID == staged.formatID && $0.cadence == staged.cadence
        })?.id
        selectedResolutionFPS = staged.label
        roleDefaultProfileEnabled = false
        if !RinkLensRiskFeaturePolicy.isEnabled(.operationalCameraOverridesV10) {
            appleStyleAutoQualityEnabled = false
        }
        videoFormatLoadStatusText = "Exact CaptureEngine mode staged: \(staged.label)"
        recordRequestedCameraTransition(
            event: "camera_exact_profile_requested",
            previous: previousRequest,
            next: requestedCameraControlSummary(),
            reason: reason
        )
        return true
    }

    @discardableResult
    func stageCaptureFormatPreference(
        _ preference: RinkLensCaptureFormatPreference,
        reason: String
    ) -> Bool {
        let previousRequest = requestedCameraControlSummary()
        let matchingProfile = capabilityProfiles.first(where: {
            $0.width == preference.width && $0.height == preference.height && $0.cadence == preference.cadence
        })
        if let matchingProfile {
            return stageCapabilityProfile(id: matchingProfile.id, reason: reason)
        }

        // A copied profile can be staged before the newly selected camera's format
        // list has finished refreshing. Preserve the operator's exact size/cadence
        // intent; CaptureEngine will either apply it to that physical device or
        // return a truthful requestedFormatUnavailable failure.
        outputQueue.sync {
            captureFormatPreferenceOverride = preference
            preferredVideoFrameRate = preference.nominalFPS
            if let cameraID = preferredCameraID ?? cameraDevice?.uniqueID {
                captureFormatPreferenceByCameraID[cameraID] = preference
            }
            cameraBreadcrumb(
                .selection,
                phase: "exact CaptureEngine format preference staged",
                extra: "mode=\(preference.diagnosticText) reason=\(reason) localProfile=pending"
            )
        }
        selectedCapabilityProfileID = nil
        selectedVideoFormatID = nil
        selectedResolutionFPS = preference.diagnosticText
        roleDefaultProfileEnabled = false
        if !RinkLensRiskFeaturePolicy.isEnabled(.operationalCameraOverridesV10) {
            appleStyleAutoQualityEnabled = false
        }
        videoFormatLoadStatusText = "Exact CaptureEngine mode staged pending device validation: \(preference.diagnosticText)"
        recordRequestedCameraTransition(
            event: "camera_exact_profile_requested",
            previous: previousRequest,
            next: requestedCameraControlSummary(),
            reason: reason
        )
        return true
    }

    @discardableResult
    func stageCapabilityProfile(id: String, reason: String) -> Bool {
        let previousRequest = requestedCameraControlSummary()
        guard let profile = capabilityProfiles.first(where: { $0.id == id }),
              let formatID = profile.formatID else { return false }
        let staged = outputQueue.sync { () -> Bool in
            guard videoFormatMap[formatID] != nil else { return false }
            preferredVideoFormatID = formatID
            preferredVideoFrameRate = profile.nominalFPS
            captureFormatPreferenceOverride = profile.capturePreference
            roleDefaultProfileCaptureEnabled = false
            if !RinkLensRiskFeaturePolicy.isEnabled(.operationalCameraOverridesV10) {
                appleStyleAutoQualityCaptureEnabled = false
            }
            if let cameraID = preferredCameraID ?? cameraDevice?.uniqueID {
                preferredVideoFormatIDByCameraID[cameraID] = formatID
                preferredVideoFrameRateByCameraID[cameraID] = profile.nominalFPS
                captureFormatPreferenceByCameraID[cameraID] = profile.capturePreference
            }
            cameraBreadcrumb(
                .selection,
                phase: "exact CaptureEngine format staged",
                extra: "mode=\(profile.capturePreference.diagnosticText) reason=\(reason)"
            )
            return true
        }
        guard staged else { return false }
        selectedCapabilityProfileID = id
        selectedVideoFormatID = formatID
        selectedResolutionFPS = profile.displayLabel
        roleDefaultProfileEnabled = false
        if !RinkLensRiskFeaturePolicy.isEnabled(.operationalCameraOverridesV10) {
            appleStyleAutoQualityEnabled = false
        }
        videoFormatLoadStatusText = "Exact CaptureEngine mode staged: \(profile.displayLabel)"
        recordRequestedCameraTransition(
            event: "camera_exact_profile_requested",
            previous: previousRequest,
            next: requestedCameraControlSummary(),
            reason: reason
        )
        return true
    }

    @discardableResult
    func stageRoleDefaultProfile(reason: String) -> Bool {
        let target = RinkLensCaptureFormatPreference(
            width: 1920,
            height: 1080,
            cadence: RinkLensCaptureCadence(integerFPS: roleDefaultFPS)
        )
        let previous = requestedCameraControlSummary()
        let staged = stageCaptureFormatPreference(target, reason: reason)
        guard staged else { return false }
        outputQueue.sync {
            roleDefaultProfileCaptureEnabled = true
            appleStyleAutoQualityCaptureEnabled = true
        }
        roleDefaultProfileEnabled = true
        appleStyleAutoQualityEnabled = true
        selectedResolutionFPS = "Requested default — \(roleDefaultProfileText)"
        recordRequestedCameraTransition(
            event: "camera_role_default_requested",
            previous: previous,
            next: [
                "role": operationalRole.rawValue,
                "roleDefault": "true",
                "requestedFormat": roleDefaultProfileText,
                "automaticLens": "true"
            ],
            reason: reason
        )
        return true
    }

    func selectCapabilityProfile(id: String) {
        _ = stageCapabilityProfile(id: id, reason: "direct compatibility selection")
    }

    func captureFormatPreferenceSnapshot() -> RinkLensCaptureFormatPreference? {
        outputQueue.sync {
            if let captureFormatPreferenceOverride {
                return captureFormatPreferenceOverride
            }
            guard let fps = preferredVideoFrameRate,
                  let formatID = preferredVideoFormatID,
                  let format = videoFormatMap[formatID] else { return nil }
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width > 0, dims.height > 0 else { return nil }
            return RinkLensCaptureFormatPreference(
                width: dims.width,
                height: dims.height,
                cadence: .init(integerFPS: fps)
            )
        }
    }

    func selectCompressionProfile(_ profile: VideoCompressionProfile) {
        outputQueue.async {
            guard self.compressionProfile != profile else { return }
            guard self.beginExplicitReconfiguration(status: "Changing video format profile") else { return }
            self.compressionProfile = profile
            do {
                let wasRunning = self.session.isRunning
                if wasRunning { self.session.stopRunning() }
                self.resetFrameHealthForExplicitReconfigure()
                try self.configureSession(forceReconfigure: true)
                if wasRunning || !self.session.isRunning {
                    self.startSessionIfNeeded(reason: "video profile changed", force: true)
                }
                self.markPreviewOnlySessionHealthy(status: "Live preview format profile changed")
                DispatchQueue.main.async {
                    self.selectedCompressionProfile = profile
                }
                self.recordSessionRestart(reason: "video profile changed")
                self.endExplicitReconfiguration(status: "Video format profile changed")
                self.requestPreviewLayerReset(reason: "camera pipeline rebuilt after explicit compression profile change")
            } catch {
                self.endExplicitReconfiguration()
                DispatchQueue.main.async {
                    self.cameraStatusText = "Video format profile switch failed"
                }
            }
        }
    }

    var selectedResolutionLabel: String {
        capabilityProfiles.first(where: { $0.id == selectedCapabilityProfileID })?.displayLabel ?? selectedResolutionFPS
    }

    // MARK: - UX16c12 camera input creation

    private func authorizationStatusDescription(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .notDetermined: return "not determined"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    func publishCurrentCameraAuthorizationStatus(reason: String) {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        DispatchQueue.main.async {
            self.cameraAuthorizationStatusText = "\(self.authorizationStatusDescription(status)) — \(reason)"
        }
    }

    /// Compatibility facade configuration. Stage 7 intentionally does not
    /// create an AVCaptureDeviceInput or mutate an AVCaptureSession graph.
    /// It only resolves the operator's logical source so CaptureEngine and the
    /// camera-setting controls share the same physical AVCaptureDevice object.
    private func configureSession(forceReconfigure: Bool = false) throws {
        guard legacyPrivateCaptureDisabled else {
            preconditionFailure("Legacy private capture execution was deleted in UX16c35")
        }

        let devices = discoveredVideoDevices()
        let sourceID = selectedCameraID ?? preferredCameraID
        let selected = sourceID.flatMap {
            resolveCameraDevice(sourceID: $0, from: devices)
        } ?? preferredDefaultDevice(from: devices)

        guard let selected else {
            cameraDevice = nil
            currentInput = nil
            isConfigured = false
            DispatchQueue.main.async {
                self.resolvedCameraDeviceID = nil
                self.sessionResourceStateText = "Private AVCaptureSession removed; no CaptureEngine device staged"
                self.captureGraphStatusText = "CaptureEngine selection unavailable"
            }
            cameraBreadcrumb(
                .configure,
                phase: "CaptureEngine source staging failed",
                extra: "force=\(forceReconfigure) source=\(sourceID ?? "none")"
            )
            throw CameraError.noCameraDevice
        }

        cameraDevice = selected
        preferredCameraID = selected.uniqueID
        selectedCameraID = sourceID ?? logicalCameraSourceID(for: selected)
        currentInput = nil
        isConfigured = false
        let logicalSourceID = logicalCameraSourceID(for: selected)
        cameraBreadcrumb(
            .configure,
            phase: "CaptureEngine source staged; legacy graph deleted",
            extra: "force=\(forceReconfigure) logical=\(logicalSourceID) device=\(selected.localizedName){\(selected.uniqueID)}"
        )
        DispatchQueue.main.async {
            self.selectedCameraID = logicalSourceID
            self.resolvedCameraDeviceID = selected.uniqueID
            self.isCameraSelectionDisabled = false
            self.selectedCameraName = selected.localizedName
            self.selectedCameraIsExternal = selected.deviceType == .external
            self.selectedCameraPosition = selected.position
            self.cameraStatusText = "Selected for CaptureEngine: \(selected.localizedName)"
            self.sessionResourceStateText = "Private AVCaptureSession removed; CaptureEngine owns runtime capture"
            self.captureGraphStatusText = "CaptureEngine selection staged: \(logicalSourceID) -> \(selected.uniqueID)"
            if self.availableCameras.isEmpty {
                self.availableCameras = self.simplifiedCameraSourceOptions(from: devices)
            }
        }
    }

    private func preferredDefaultDevice(from devices: [AVCaptureDevice]) -> AVCaptureDevice? {
        switch defaultCameraPreference {
        case .externalFirst:
            return preferredDevice(from: devices, preferExternal: true)
        case .builtInBackFirst, .builtInUltraWideBackFirst:
            // UX12s: default back camera is the operator rear source. On devices
            // with virtual rear zoom cameras, 0.5x ultra-wide is reached through
            // zoom, not by exposing Ultra Wide as a separate camera option.
            return preferredOperatorBuiltInBackCamera(from: devices)
                ?? preferredBuiltInBackCamera(from: devices)
                ?? devices.first
        }
    }

    private func preferredBuiltInBackCamera(from devices: [AVCaptureDevice]) -> AVCaptureDevice? {
        preferredOperatorBuiltInBackCamera(from: devices)
            ?? preferredUltraWideBuiltInBackCamera(from: devices)
            ?? devices.first(where: { $0.position == .back && $0.deviceType != .external })
    }

    /// Logical Built-in Back starts on the virtual rear zoom camera where the
    /// hardware exposes it, matching the physically smooth b114 configuration.
    private func preferredBuiltInBackCameraForCurrentRole(from devices: [AVCaptureDevice]) -> AVCaptureDevice? {
        preferredOperatorBuiltInBackCamera(from: devices)
            ?? preferredStandardBuiltInBackCamera(from: devices)
    }

    private func preferredOperatorBuiltInBackCamera(from devices: [AVCaptureDevice]) -> AVCaptureDevice? {
        preferredVirtualBackZoomCamera(from: devices)
            ?? preferredPhysicalWideBuiltInBackCamera(from: devices)
            ?? preferredStandardBuiltInBackCamera(from: devices)
    }

    /// Fallback normal rear camera source. Prefer the physical 1x wide camera where available.
    private func preferredStandardBuiltInBackCamera(from devices: [AVCaptureDevice]) -> AVCaptureDevice? {
        let builtInBack = devices.filter { $0.position == .back && $0.deviceType != .external }

        if let wide = preferredPhysicalWideBuiltInBackCamera(from: devices) {
            return wide
        }

        if let nonUltraWide = builtInBack.first(where: { $0.deviceType != .builtInUltraWideCamera && !$0.localizedName.localizedCaseInsensitiveContains("ultra") }) {
            return nonUltraWide
        }

        if let virtual = preferredVirtualBackZoomCamera(from: devices) {
            return virtual
        }

        return builtInBack.first
    }

    private func preferredPhysicalWideBuiltInBackCamera(from devices: [AVCaptureDevice]) -> AVCaptureDevice? {
        devices.first(where: { $0.position == .back && $0.deviceType == .builtInWideAngleCamera })
    }

    private func preferredVirtualBackZoomCamera(from devices: [AVCaptureDevice]) -> AVCaptureDevice? {
        let builtInBack = devices.filter { $0.position == .back && $0.deviceType != .external }
        if let triple = builtInBack.first(where: { $0.deviceType == .builtInTripleCamera }) {
            return triple
        }
        if let dualWide = builtInBack.first(where: { $0.deviceType == .builtInDualWideCamera }) {
            return dualWide
        }
        if let dual = builtInBack.first(where: { $0.deviceType == .builtInDualCamera }) {
            return dual
        }
        return nil
    }

    /// 0.5x rear camera. Prefer the physical Ultra Wide camera where available.
    private func preferredUltraWideBuiltInBackCamera(from devices: [AVCaptureDevice]) -> AVCaptureDevice? {
        let builtInBack = devices.filter { $0.position == .back && $0.deviceType != .external }
        if let ultraWide = builtInBack.first(where: { $0.deviceType == .builtInUltraWideCamera }) {
            return ultraWide
        }
        if let namedUltraWide = builtInBack.first(where: { $0.localizedName.localizedCaseInsensitiveContains("ultra") }) {
            return namedUltraWide
        }
        return nil
    }


    private func preferredDevice(from devices: [AVCaptureDevice], preferExternal: Bool?) -> AVCaptureDevice? {
        if let preferExternal {
            if preferExternal {
                return devices.first(where: { $0.deviceType == .external })
                    ?? preferredBuiltInBackCameraForCurrentRole(from: devices)
                    ?? devices.first
            }
            return preferredBuiltInBackCameraForCurrentRole(from: devices)
                ?? devices.first(where: { $0.deviceType != .external })
                ?? devices.first(where: { $0.deviceType == .external })
                ?? devices.first
        }

        switch defaultCameraPreference {
        case .externalFirst:
            return devices.first(where: { $0.deviceType == .external })
                ?? preferredBuiltInBackCameraForCurrentRole(from: devices)
                ?? devices.first
        case .builtInBackFirst, .builtInUltraWideBackFirst:
            return preferredBuiltInBackCameraForCurrentRole(from: devices)
                ?? devices.first(where: { $0.deviceType != .external })
                ?? devices.first(where: { $0.deviceType == .external })
                ?? devices.first
        }
    }


    private func videoDiscoverySession() -> AVCaptureDevice.DiscoverySession {
        var types: [AVCaptureDevice.DeviceType] = [
            .builtInDualWideCamera,
            .builtInTripleCamera,
            .builtInDualCamera,
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera
        ]
        if #available(iOS 17.0, *) { types.insert(.external, at: 0) }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
    }

    private func discoveredVideoDevices() -> [AVCaptureDevice] {
        videoDiscoverySession().devices
    }

    private func requestedPreviewFrameRate(for camera: AVCaptureDevice, selectedFormat: AVCaptureDevice.Format) -> Int {
        if RinkLensRiskFeaturePolicy.isEnabled(.roleOwnedCameraDefaultsV10), roleDefaultProfileCaptureEnabled {
            return roleDefaultFPS
        }
        if let preferredVideoFrameRate { return preferredVideoFrameRate }
        if let id = selectedCapabilityProfileID,
           let profile = capabilityProfiles.first(where: { $0.id == id }) {
            return profile.nominalFPS
        }
        return roleDefaultFPS
    }

    private func configurePreferredFormatAndDefaults(for camera: AVCaptureDevice) throws {
        // UX13i: external USB/capture-card cameras should not be treated as
        // Built-in automatic lens controls are not assumed for external cameras. Keep controls manual so
        // the operator can explicitly choose Resolution / FPS from the formats
        // the external device reports.
        if camera.deviceType == .external,
           !RinkLensRiskFeaturePolicy.isEnabled(.operationalCameraOverridesV10) {
            appleStyleAutoQualityCaptureEnabled = false
        }
        let useAppleStyleAutoQuality = appleStyleAutoQualityCaptureEnabled

        do {
            try camera.lockForConfiguration()
            let (formatOptions, formatMap) = availableFormats(for: camera)
            videoFormatMap = formatMap

            if nativeAutomaticFormatByCameraID[camera.uniqueID] == nil {
                nativeAutomaticFormatByCameraID[camera.uniqueID] = camera.activeFormat
            }
            let fallbackFormat = preferredPreviewFormat(for: camera)
            if let preferredVideoFormatID, formatMap[preferredVideoFormatID] == nil {
                self.preferredVideoFormatID = nil
            }
            let roleDefaultActive = RinkLensRiskFeaturePolicy.isEnabled(.roleOwnedCameraDefaultsV10)
                && roleDefaultProfileCaptureEnabled
            let roleDefaultFormat = roleDefaultFPS >= 60
                ? preferredFormat1080p60(for: camera)
                : preferredFormat1080p30(for: camera)
            let selectedFormat = roleDefaultActive
                ? (roleDefaultFormat ?? fallbackFormat ?? nativeAutomaticFormatByCameraID[camera.uniqueID])
                : (self.preferredVideoFormatID.flatMap { formatMap[$0] } ?? fallbackFormat)
            if let selectedFormat {
                camera.activeFormat = selectedFormat
                preferredVideoFormatID = formatMap.first(where: { $0.value === selectedFormat })?.key
                if let preferredVideoFormatID {
                    preferredVideoFormatIDByCameraID[camera.uniqueID] = preferredVideoFormatID
                }
                let requestedFPS = self.requestedPreviewFrameRate(for: camera, selectedFormat: selectedFormat)
                let cadenceApplied = self.applySafeFrameDuration(requestedFPS, to: camera, selectedFormat: selectedFormat)
                if roleDefaultActive {
                    let dimensions = CMVideoFormatDescriptionGetDimensions(selectedFormat.formatDescription)
                    let supported = supportsFrameRate(requestedFPS, for: selectedFormat)
                    let preference = RinkLensCaptureFormatPreference(
                        width: dimensions.width,
                        height: dimensions.height,
                        cadence: RinkLensCaptureCadence(integerFPS: supported ? requestedFPS : Int(maxSupportedFPS(for: selectedFormat).rounded()))
                    )
                    preferredVideoFrameRate = supported ? requestedFPS : preference.nominalFPS
                    captureFormatPreferenceOverride = preference
                    preferredVideoFrameRateByCameraID[camera.uniqueID] = preferredVideoFrameRate
                    captureFormatPreferenceByCameraID[camera.uniqueID] = preference
                    cameraBreadcrumb(
                        .selection,
                        phase: "Build 720 role default camera profile resolved",
                        extra: "role=\(operationalRole.rawValue) requested=\(roleDefaultProfileText) applied=\(preference.diagnosticText) exactFPS=\(supported && cadenceApplied == requestedFPS) autoLens=\(useAppleStyleAutoQuality) recording=\(operationalRole == .broadcast ? "inherits-source" : "n/a")"
                    )
                }
            }
            // Build 784: this facade may restore a remembered physical zoom only
            // for the independent OCR camera. Broadcast physical lens/framing is
            // exclusively applied by CaptureLifecycleController -> CaptureEngine.
            let cleanMinZoom = minZoomFactor.isFinite ? minZoomFactor : 1.0
            let cleanMaxZoom = (maxZoomFactor.isFinite && maxZoomFactor >= cleanMinZoom) ? maxZoomFactor : cleanMinZoom
            let observedZoom: CGFloat
            if operationalRole == .ocr {
                let defaultZoom = Swift.min(Swift.max(1.0, cleanMinZoom), cleanMaxZoom)
                let rememberedZoom = zoomFactorByCameraID[camera.uniqueID] ?? defaultZoom
                let cleanRememberedZoom = rememberedZoom.isFinite ? rememberedZoom : defaultZoom
                let clampedZoom = Swift.min(Swift.max(cleanRememberedZoom, cleanMinZoom), cleanMaxZoom)
                camera.videoZoomFactor = clampedZoom
                zoomFactorByCameraID[camera.uniqueID] = clampedZoom
                observedZoom = clampedZoom
            } else {
                observedZoom = camera.videoZoomFactor
                RinkLensStructuredEventLogger.shared.record(
                    domain: .cameraControl,
                    event: "camera_broadcast_zoom_configuration_deferred",
                    entityID: camera.uniqueID,
                    previous: ["observedPhysicalZoom": String(Double(observedZoom))],
                    next: ["hardwareMutation": "false"],
                    source: "HockeyCameraService.configurePreferredFormatAndDefaults",
                    reason: "CaptureLifecycleController exclusively owns Broadcast physical framing",
                    authoritativeOwner: "CaptureLifecycleController"
                )
            }
            if camera.isFocusModeSupported(.continuousAutoFocus) {
                camera.focusMode = .continuousAutoFocus
            }
            if useAppleStyleAutoQuality {
                if camera.isFocusModeSupported(.continuousAutoFocus) {
                    camera.focusMode = .continuousAutoFocus
                }
                if camera.isExposureModeSupported(.continuousAutoExposure) {
                    camera.exposureMode = .continuousAutoExposure
                }
                if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    camera.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                // HDR/stabilisation are handled by the selected AVFoundation format/connection where supported.
            }
            camera.unlockForConfiguration()
            let capabilityProfiles = self.buildCapabilityProfiles(using: formatMap)
            let selectedFormatID = self.preferredVideoFormatID
            let selectedCadence = self.captureFormatPreferenceOverride?.cadence
                ?? RinkLensCaptureCadence(duration: camera.activeVideoMinFrameDuration)
            let activeDimensions = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
            let selectedCapabilityProfileID = capabilityProfiles.first(where: {
                if let selectedFormatID {
                    return $0.formatID == selectedFormatID && $0.cadence == selectedCadence
                }
                return $0.width == activeDimensions.width
                    && $0.height == activeDimensions.height
                    && $0.cadence == selectedCadence
            })?.id
            DispatchQueue.main.async {
                self.availableVideoFormats = formatOptions
                self.selectedVideoFormatID = selectedFormatID
                self.capabilityProfiles = capabilityProfiles
                self.selectedCapabilityProfileID = selectedCapabilityProfileID
                self.videoFormatsLoaded = true
                self.isLoadingVideoFormats = false
                self.videoFormatLoadStatusText = capabilityProfiles.isEmpty
                    ? "No supported 720p, 1080p, or 1440p modes at 30/60 fps"
                    : "Formats cached for active camera"
                self.currentZoomFactor = observedZoom
            }
            } catch {
            throw error
        }
    }

    private func availableFormats(for device: AVCaptureDevice) -> ([VideoFormatOption], [String: AVCaptureDevice.Format]) {
        // CaptureEngine retains every exact MultiCam-compatible device format
        // internally so it can resolve the best physical variant. The operator-facing
        // capability list is filtered separately to 720p/1080p/1440p at 30/60 fps.
        var map: [String: AVCaptureDevice.Format] = [:]
        var options: [VideoFormatOption] = []
        for (index, format) in device.formats.enumerated() where format.isMultiCamSupported {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width > 0, dims.height > 0 else { continue }
            let minFPS = format.videoSupportedFrameRateRanges.map(\.minFrameRate).min() ?? 0
            let maxFPS = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let id = "fmt-\(index)-\(dims.width)x\(dims.height)"
            map[id] = format
            let minText = RinkLensCaptureCadence(frameRate: minFPS).displayText
            let maxText = RinkLensCaptureCadence(frameRate: maxFPS).displayText
            options.append(
                VideoFormatOption(
                    id: id,
                    label: "\(dims.width)x\(dims.height) • \(minText)–\(maxText) fps"
                        + (format.isVideoBinned ? " • binned" : "")
                )
            )
        }
        options.sort { lhs, rhs in lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending }
        return (options, map)
    }

    private func preferredFormat1080p60(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let formats = device.formats
        let candidates = formats.filter { format in
            let desc = format.formatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            guard dims.width == 1920, dims.height == 1080 else { return false }
            guard format.isMultiCamSupported, !format.isVideoBinned else { return false }
            return supportsFrameRate(60, for: format)
        }
        return candidates.min { lhs, rhs in
            let lDims = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let rDims = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            let lArea = Int(lDims.width) * Int(lDims.height)
            let rArea = Int(rDims.width) * Int(rDims.height)
            if lArea == rArea {
                return lhs.videoFieldOfView < rhs.videoFieldOfView
            }
            return lArea < rArea
        }
    }

    private func preferredFormat1080p30(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let formats = device.formats
        let candidates = formats.filter { format in
            let desc = format.formatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            guard dims.width >= 1920, dims.height >= 1080 else { return false }
            return supportsFrameRate(30, for: format)
        }
        return candidates.min { lhs, rhs in
            let lDims = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let rDims = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            let lArea = Int(lDims.width) * Int(lDims.height)
            let rArea = Int(rDims.width) * Int(rDims.height)
            if lArea == rArea {
                return lhs.videoFieldOfView < rhs.videoFieldOfView
            }
            return lArea < rArea
        }
    }

    private func preferredPreviewFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        // UX13d: External USB/capture-card cameras often advertise 720p/60 and
        // 1080p/30. The old automatic path asked for 60fps first, so preview/OCR
        // could choose the lower-resolution 720p/60 mode and look pixelated.
        // For preview and OCR setup, favour HD resolution first; recording preflight
        // still validates the exact requested recording profile separately.
        if device.deviceType == .external {
            return preferredExternalHDPreviewFormat(for: device)
                ?? preferredFormat1080p30(for: device)
                ?? preferredRecordingFormat(for: device, targetFPS: 30)
        }

        return preferredRecordingFormat(for: device, targetFPS: 60)
            ?? preferredFormat1080p30(for: device)
            ?? preferredRecordingFormat(for: device, targetFPS: 30)
    }

    private func preferredExternalHDPreviewFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        func dimensions(_ format: AVCaptureDevice.Format) -> CMVideoDimensions {
            CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        }

        func area(_ format: AVCaptureDevice.Format) -> Int {
            let dims = dimensions(format)
            return Int(dims.width) * Int(dims.height)
        }

        func maxFPS(_ format: AVCaptureDevice.Format) -> Double {
            maxSupportedFPS(for: format)
        }

        func supportsAtLeast30FPS(_ format: AVCaptureDevice.Format) -> Bool {
            supportsFrameRate(30, for: format)
        }

        func isAtLeast1080p(_ format: AVCaptureDevice.Format) -> Bool {
            let dims = dimensions(format)
            return dims.width >= 1920 && dims.height >= 1080
        }

        func isAtLeast720p(_ format: AVCaptureDevice.Format) -> Bool {
            let dims = dimensions(format)
            return dims.width >= 1280 && dims.height >= 720
        }

        func bestHD(_ formats: [AVCaptureDevice.Format]) -> AVCaptureDevice.Format? {
            formats.min { lhs, rhs in
                let lhsArea = area(lhs)
                let rhsArea = area(rhs)
                if lhsArea != rhsArea {
                    // Pick the smallest HD-or-better mode. This prefers 1080p over unsupported higher-resolution modes
                    // for preview/OCR so the iPad does not do unnecessary scaling work.
                    return lhsArea < rhsArea
                }
                return maxFPS(lhs) > maxFPS(rhs)
            }
        }

        let hdCandidates = device.formats.filter { isAtLeast1080p($0) && supportsAtLeast30FPS($0) }
        if let hd = bestHD(hdCandidates) {
            return hd
        }

        let usableCandidates = device.formats.filter { isAtLeast720p($0) && supportsAtLeast30FPS($0) }
        return usableCandidates.max { lhs, rhs in
            let lhsArea = area(lhs)
            let rhsArea = area(rhs)
            if lhsArea != rhsArea {
                return lhsArea < rhsArea
            }
            return maxFPS(lhs) < maxFPS(rhs)
        }
    }

    func prepareForBroadcastRecording(targetFPS: Int, completion: @escaping (String) -> Void) {
        if RinkLensRiskFeaturePolicy.isEnabled(.cameraSourceRecordingProfileV5) {
            let formatText = selectedResolutionFPS
            MainThreadStallMonitor.traceFromAnyQueue("Build 711 ignored legacy recording FPS request=\(targetFPS); camera source remains authoritative at \(formatText)")
            completion(formatText)
            return
        }
        outputQueue.async { [weak self] in
            guard let self else { return }
            let formatText = self.applyRecordingFormatLock(targetFPS: targetFPS)
            DispatchQueue.main.async {
                self.selectedResolutionFPS = formatText
                self.cameraStatusText = "Rollback recording camera format locked: \(formatText)"
                completion(formatText)
            }
        }
    }

    func prepareForBroadcastRecording(profile: BroadcastRecordingProfile, completion: @escaping (RecordingCameraFormatValidationResult) -> Void) {
        if RinkLensRiskFeaturePolicy.isEnabled(.cameraSourceRecordingProfileV5) {
            let validation = RecordingCameraFormatValidationResult.invalid(
                requested: "Active Broadcast camera source",
                active: selectedResolutionFPS,
                reason: "This legacy camera-service preflight is disabled. Use the current-generation CaptureEngine Broadcast-frame preflight."
            )
            RecordingCameraFormatValidationDiagnostics.noteFromAnyQueue(validation)
            completion(validation)
            return
        }
        outputQueue.async { [weak self] in
            guard let self else { return }
            let formatText = self.applyRecordingFormatLock(targetFPS: profile.frameRate.rawValue)
            let validation = self.validateActiveRecordingFormat(profile: profile, activeFormatText: formatText)
            DispatchQueue.main.async {
                RecordingCameraFormatValidationDiagnostics.shared.note(validation)
                self.selectedResolutionFPS = validation.activeFormatText
                self.cameraStatusText = validation.isValid
                    ? "Rollback recording camera format verified: \(validation.activeFormatText)"
                    : "Recording blocked: \(validation.operatorMessage)"
                completion(validation)
            }
        }
    }

    private func validateActiveRecordingFormat(profile: BroadcastRecordingProfile, activeFormatText: String) -> RecordingCameraFormatValidationResult {
        let requestedText = "\(profile.resolution.rawValue) / \(profile.frameRate.label)"
        guard let device = effectiveCaptureDeviceForRecording() else {
            return .invalid(requested: requestedText, active: "No camera", reason: "Recording blocked because no active camera is available for \(requestedText).")
        }

        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let requiredSize = profile.resolution.size
        let activeWidth = Int(dims.width)
        let activeHeight = Int(dims.height)
        let requiredWidth = Int(requiredSize.width.rounded())
        let requiredHeight = Int(requiredSize.height.rounded())
        let duration = device.activeVideoMaxFrameDuration
        let activeFPS: Double = duration.value > 0
            ? Double(duration.timescale) / Double(duration.value)
            : maxSupportedFPS(for: device.activeFormat)
        let requiredFPS = Double(profile.frameRate.rawValue)

        var failures: [String] = []
        if activeWidth < requiredWidth || activeHeight < requiredHeight {
            failures.append("active camera resolution is \(activeWidth)x\(activeHeight), but \(requestedText) requires at least \(requiredWidth)x\(requiredHeight)")
        }
        if activeFPS + 0.5 < requiredFPS {
            failures.append("active camera frame rate is \(Int(round(activeFPS)))fps, but \(requestedText) requires \(Int(requiredFPS))fps")
        }

        guard failures.isEmpty else {
            return .invalid(
                requested: requestedText,
                active: activeFormatText,
                reason: "Recording blocked because \(failures.joined(separator: "; ")). Select a lower recording profile or a camera format that supports \(requestedText)."
            )
        }

        guard let source = RecordingCameraSourceProfile.parseLegacyText(
            formatText: activeFormatText,
            physicalDeviceID: device.uniqueID,
            captureGeneration: 0
        ) else {
            return .invalid(requested: requestedText, active: activeFormatText, reason: "Recording camera format could not be parsed after rollback lock.")
        }
        return .valid(requested: requestedText, active: activeFormatText, sourceProfile: source)
    }

    private func applyRecordingFormatLock(targetFPS: Int) -> String {
        guard let device = effectiveCaptureDeviceForRecording() else { return "No camera" }
        let clampedTarget = min(max(targetFPS, 15), 60)
        let selectedFormat = preferredRecordingFormat(for: device, targetFPS: clampedTarget)
        var appliedFPS = clampedTarget

        do {
            try device.lockForConfiguration()

            if let selectedFormat {
                device.activeFormat = selectedFormat
                if let formatID = videoFormatMap.first(where: { $0.value === selectedFormat })?.key {
                    preferredVideoFormatID = formatID
                    preferredVideoFormatIDByCameraID[device.uniqueID] = formatID
                }
            }

            let fps = applySafeFrameDuration(clampedTarget, to: device, selectedFormat: device.activeFormat) ?? clampedTarget
            appliedFPS = fps
            let frameDuration = CMTime(value: 1, timescale: Int32(max(1, fps)))
            enforceExposureForRecordingFPS(device: device, frameDuration: frameDuration, fps: fps)
            device.unlockForConfiguration()
        } catch {
            DispatchQueue.main.async {
                self.cameraStatusText = "Recording camera format lock failed"
                MainThreadStallMonitor.shared.trace("recording camera format lock failed: \(error.localizedDescription)")
            }
        }

        let label = activeFormatLabel(for: device)
        if appliedFPS < clampedTarget {
            DispatchQueue.main.async {
                MainThreadStallMonitor.shared.trace("recording camera fps downgraded: requested \(clampedTarget)fps active \(label)")
            }
        }
        return label
    }

    private func enforceExposureForRecordingFPS(device: AVCaptureDevice, frameDuration: CMTime, fps: Int) {
        // A camera can advertise 1080p/60 and still deliver fewer unique frames if
        // it is left in a locked/custom exposure longer than 1/60s. Recording owns
        // the live camera while this method runs, so prefer continuous exposure;
        // if that is unavailable, clamp the custom exposure duration to the frame
        // interval. OCR uses its own camera or sampled copies and should not force
        // the broadcast recording camera below 60fps.
        let currentExposure = device.exposureDuration
        let exposureTooLong = currentExposure.isValid && CMTimeCompare(currentExposure, frameDuration) > 0
        guard exposureTooLong else { return }

        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
            DispatchQueue.main.async {
                MainThreadStallMonitor.shared.trace("recording exposure unlocked for \(fps)fps: continuous auto exposure")
            }
        } else if device.isExposureModeSupported(.custom) {
            let clampedISO = min(max(device.iso, device.activeFormat.minISO), device.activeFormat.maxISO)
            device.setExposureModeCustom(duration: frameDuration, iso: clampedISO, completionHandler: nil)
            DispatchQueue.main.async {
                MainThreadStallMonitor.shared.trace("recording exposure clamped for \(fps)fps: max shutter 1/\(fps)s")
            }
        } else if device.isExposureModeSupported(.autoExpose) {
            device.exposureMode = .autoExpose
            DispatchQueue.main.async {
                MainThreadStallMonitor.shared.trace("recording exposure unlocked for \(fps)fps: auto expose")
            }
        }
    }

    private func preferredRecordingFormat(for device: AVCaptureDevice, targetFPS: Int) -> AVCaptureDevice.Format? {
        if targetFPS >= 60, let format = preferredFormat1080p60(for: device) {
            return format
        }
        if targetFPS >= 30 && targetFPS < 60, let format = preferredFormat1080p30(for: device) {
            return format
        }

        let target = Double(min(max(targetFPS, 15), 60))

        func dimensions(_ format: AVCaptureDevice.Format) -> CMVideoDimensions {
            CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        }

        func area(_ format: AVCaptureDevice.Format) -> Int {
            let dims = dimensions(format)
            return Int(dims.width) * Int(dims.height)
        }

        func isUsable(_ format: AVCaptureDevice.Format) -> Bool {
            let dims = dimensions(format)
            return dims.width >= 1280 && dims.height >= 720
        }

        func ranked(_ formats: [AVCaptureDevice.Format]) -> AVCaptureDevice.Format? {
            formats.min { lhs, rhs in
                let lhsDims = dimensions(lhs)
                let rhsDims = dimensions(rhs)
                let lhsIs1080 = lhsDims.width >= 1920 && lhsDims.height >= 1080
                let rhsIs1080 = rhsDims.width >= 1920 && rhsDims.height >= 1080

                if lhsIs1080 != rhsIs1080 {
                    return lhsIs1080 && !rhsIs1080
                }

                let lhsArea = area(lhs)
                let rhsArea = area(rhs)
                if lhsArea != rhsArea {
                    return lhsArea > rhsArea
                }

                return maxSupportedFPS(for: lhs) > maxSupportedFPS(for: rhs)
            }
        }

        let matchingFPS = device.formats.filter { format in
            isUsable(format) && maxSupportedFPS(for: format) >= target
        }
        if let match = ranked(matchingFPS) {
            return match
        }

        let fallback = device.formats.filter { format in
            isUsable(format) && maxSupportedFPS(for: format) >= 24
        }
        return ranked(fallback)
    }

    private func maxSupportedFPS(for format: AVCaptureDevice.Format) -> Double {
        format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
    }

    private func supportsFrameRate(_ fps: Int, for format: AVCaptureDevice.Format) -> Bool {
        let target = Double(fps)
        return format.videoSupportedFrameRateRanges.contains { range in
            target + 0.01 >= range.minFrameRate && target - 0.01 <= range.maxFrameRate
        }
    }

    private func safeFrameRateForFormat(_ requestedFPS: Int, format: AVCaptureDevice.Format) -> Int? {
        let clamped = min(max(requestedFPS, 1), 120)
        if supportsFrameRate(clamped, for: format) {
            return clamped
        }

        let commonRates = [60, 50, 30, 25, 24, 15]
        if let fallback = commonRates
            .filter({ supportsFrameRate($0, for: format) })
            .min(by: { abs($0 - clamped) < abs($1 - clamped) }) {
            return fallback
        }

        guard let bestRange = format.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else {
            return nil
        }
        let fallback = Int(max(1, min(bestRange.maxFrameRate, Double(clamped))).rounded())
        return supportsFrameRate(fallback, for: format) ? fallback : Int(max(1, bestRange.maxFrameRate.rounded(.down)))
    }

    private func applySafeFrameDuration(_ requestedFPS: Int, to camera: AVCaptureDevice, selectedFormat: AVCaptureDevice.Format) -> Int? {
        guard let safeFPS = safeFrameRateForFormat(requestedFPS, format: selectedFormat), safeFPS > 0 else {
            return nil
        }
        let frameDuration = CMTime(value: 1, timescale: Int32(safeFPS))
        camera.activeVideoMinFrameDuration = frameDuration
        camera.activeVideoMaxFrameDuration = frameDuration
        return safeFPS
    }

    private func activeFormatLabel(for device: AVCaptureDevice) -> String {
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let duration = device.activeVideoMaxFrameDuration
        let fps: Double

        if duration.value > 0 {
            fps = Double(duration.timescale) / Double(duration.value)
        } else {
            fps = maxSupportedFPS(for: device.activeFormat)
        }

        let cadence = duration.value > 0
            ? RinkLensCaptureCadence(duration: duration)
            : RinkLensCaptureCadence(frameRate: fps)
        return "\(dims.width)x\(dims.height) @ \(cadence.displayText)fps"
    }

    private struct ExposureControlSample {
        let iso: Float
        let durationSeconds: Double
        let minISO: Float
        let maxISO: Float
        let minDurationSeconds: Double
        let maxDurationSeconds: Double

        var isoRangeIsUsable: Bool {
            minISO.isFinite && maxISO.isFinite && maxISO > 0 && maxISO >= minISO
        }

        var durationRangeIsUsable: Bool {
            minDurationSeconds.isFinite
                && maxDurationSeconds.isFinite
                && minDurationSeconds > 0
                && maxDurationSeconds >= minDurationSeconds
        }

        var isoIsUsable: Bool {
            guard isoRangeIsUsable, iso.isFinite, iso > 0 else { return false }
            return iso >= minISO - 0.01 && iso <= maxISO + 0.01
        }

        var durationIsUsable: Bool {
            guard durationRangeIsUsable, durationSeconds.isFinite, durationSeconds > 0 else { return false }
            return durationSeconds >= minDurationSeconds - 0.000_001
                && durationSeconds <= maxDurationSeconds + 0.000_001
        }

        var isUsable: Bool { isoIsUsable && durationIsUsable }

        var diagnosticText: String {
            "iso=\(iso) range=\(minISO)...\(maxISO) duration=\(durationSeconds) range=\(minDurationSeconds)...\(maxDurationSeconds)"
        }
    }

    private func exposureControlSample(for device: AVCaptureDevice) -> ExposureControlSample {
        ExposureControlSample(
            iso: device.iso,
            durationSeconds: CMTimeGetSeconds(device.exposureDuration),
            minISO: device.activeFormat.minISO,
            maxISO: device.activeFormat.maxISO,
            minDurationSeconds: CMTimeGetSeconds(device.activeFormat.minExposureDuration),
            maxDurationSeconds: CMTimeGetSeconds(device.activeFormat.maxExposureDuration)
        )
    }

    private func automaticExposureMode(for device: AVCaptureDevice) -> AVCaptureDevice.ExposureMode? {
        if device.isExposureModeSupported(.continuousAutoExposure) {
            return .continuousAutoExposure
        }
        if device.isExposureModeSupported(.autoExpose) {
            return .autoExpose
        }
        return nil
    }

    @discardableResult
    private func applySupportedAutomaticExposure(
        on device: AVCaptureDevice,
        source: String,
        requestedOperation: String,
        rejectionReason: String
    ) -> Bool {
        let previousMode = device.exposureMode
        let previous = exposureControlSample(for: device)
        guard let mode = automaticExposureMode(for: device) else {
            RinkLensStructuredEventLogger.shared.record(
                domain: .camera,
                event: "camera_exposure_request_rejected",
                entityID: device.uniqueID,
                previous: [
                    "mode": String(previousMode.rawValue),
                    "sample": previous.diagnosticText
                ],
                next: [
                    "requestedOperation": requestedOperation,
                    "automaticExposureAvailable": "false",
                    "applied": "false"
                ],
                source: source,
                reason: rejectionReason,
                authoritativeOwner: "HockeyCameraService"
            )
            DispatchQueue.main.async {
                self.cameraStatusText = "\(requestedOperation) rejected: valid exposure controls are unavailable on this camera"
            }
            return false
        }

        do {
            try device.lockForConfiguration()
            device.exposureMode = mode
            device.unlockForConfiguration()
            RinkLensCaptureGraphMutationAudit.shared.record(
                .liveDeviceControl,
                detail: "invalid external exposure restored to automatic; sessionRestarted=false"
            )
            RinkLensStructuredEventLogger.shared.record(
                domain: .camera,
                event: "camera_exposure_request_rejected",
                entityID: device.uniqueID,
                previous: [
                    "mode": String(previousMode.rawValue),
                    "sample": previous.diagnosticText
                ],
                next: [
                    "requestedOperation": requestedOperation,
                    "automaticExposureAvailable": "true",
                    "applied": "automatic",
                    "mode": String(mode.rawValue)
                ],
                source: source,
                reason: rejectionReason,
                authoritativeOwner: "HockeyCameraService"
            )
            DispatchQueue.main.async {
                self.exposureModeText = "Auto Exposure"
                self.cameraStatusText = "Invalid saved exposure ignored; automatic exposure retained"
                self.refreshCameraSettingState(source: "\(source) automatic exposure recovery")
            }
            return true
        } catch {
            RinkLensStructuredEventLogger.shared.record(
                domain: .camera,
                event: "camera_exposure_request_rejected",
                entityID: device.uniqueID,
                previous: [
                    "mode": String(previousMode.rawValue),
                    "sample": previous.diagnosticText
                ],
                next: [
                    "requestedOperation": requestedOperation,
                    "automaticExposureAvailable": "true",
                    "applied": "false",
                    "error": error.localizedDescription
                ],
                source: source,
                reason: rejectionReason,
                authoritativeOwner: "HockeyCameraService"
            )
            DispatchQueue.main.async {
                self.cameraStatusText = "Automatic exposure recovery failed: \(error.localizedDescription)"
            }
            return false
        }
    }

    private func restoreAutomaticExposureWhenCurrentStateIsInvalid(
        on device: AVCaptureDevice,
        source: String,
        requestedOperation: String
    ) {
        let sample = exposureControlSample(for: device)
        guard !sample.isUsable else { return }
        _ = applySupportedAutomaticExposure(
            on: device,
            source: source,
            requestedOperation: requestedOperation,
            rejectionReason: "Current physical exposure sample is invalid; \(sample.diagnosticText)"
        )
    }

    func setManualFocus(position: Float) {
        outputQueue.async {
            guard let device = self.cameraDevice else { return }
            guard device.isFocusModeSupported(.locked), device.isLockingFocusWithCustomLensPositionSupported else {
                DispatchQueue.main.async { self.cameraStatusText = "Manual focus unavailable on this camera" }
                return
            }
            do {
                try device.lockForConfiguration()
                let clamped = min(max(position, 0), 1)
                device.setFocusModeLocked(lensPosition: clamped, completionHandler: nil)
                device.unlockForConfiguration()
                RinkLensCaptureGraphMutationAudit.shared.record(.liveDeviceControl, detail: "manual focus; sessionRestarted=false")
                DispatchQueue.main.async {
                    self.focusPosition = clamped
                    self.focusModeText = "Manual Focus (Locked)"
                }
            } catch {
                DispatchQueue.main.async { self.cameraStatusText = "Manual focus failed" }
            }
        }
    }

    func setContinuousAutoFocus() {
        outputQueue.async {
            guard let device = self.cameraDevice else { return }
            guard device.isFocusModeSupported(.continuousAutoFocus) else {
                DispatchQueue.main.async { self.cameraStatusText = "Auto focus unavailable on this camera" }
                return
            }
            do {
                try device.lockForConfiguration()
                device.focusMode = .continuousAutoFocus
                device.unlockForConfiguration()
                RinkLensCaptureGraphMutationAudit.shared.record(.liveDeviceControl, detail: "continuous autofocus; sessionRestarted=false")
                DispatchQueue.main.async { self.focusModeText = "Auto Focus" }
            } catch {
                DispatchQueue.main.async { self.cameraStatusText = "Auto focus failed" }
            }
        }
    }

    func setManualISO(_ iso: Float) {
        outputQueue.async {
            guard let device = self.cameraDevice else { return }
            guard device.isExposureModeSupported(.custom) else {
                DispatchQueue.main.async { self.cameraStatusText = "Manual ISO unavailable on this camera" }
                return
            }
            let current = self.exposureControlSample(for: device)
            guard iso.isFinite,
                  iso > 0,
                  current.isoRangeIsUsable,
                  current.durationIsUsable else {
                _ = self.applySupportedAutomaticExposure(
                    on: device,
                    source: "HockeyCameraService.setManualISO",
                    requestedOperation: "manual ISO \(iso)",
                    rejectionReason: "Requested ISO or current shutter state is invalid; \(current.diagnosticText)"
                )
                return
            }
            let clampedISO = min(max(iso, device.activeFormat.minISO), device.activeFormat.maxISO)
            do {
                try device.lockForConfiguration()
                let duration = device.exposureDuration
                device.setExposureModeCustom(duration: duration, iso: clampedISO, completionHandler: nil)
                device.unlockForConfiguration()
                RinkLensCaptureGraphMutationAudit.shared.record(.liveDeviceControl, detail: "manual ISO; sessionRestarted=false")
                DispatchQueue.main.async {
                    self.isoValue = clampedISO
                    self.exposureModeText = "Manual Exposure"
                    self.cameraStatusText = "Manual ISO applied"
                    self.refreshCameraSettingState()
                }
            } catch {
                DispatchQueue.main.async { self.cameraStatusText = "Manual ISO failed" }
            }
        }
    }

    func setManualExposureDuration(seconds: Double) {
        outputQueue.async {
            guard let device = self.cameraDevice else { return }
            guard device.isExposureModeSupported(.custom) else {
                DispatchQueue.main.async { self.cameraStatusText = "Manual shutter speed unavailable on this camera" }
                return
            }
            let current = self.exposureControlSample(for: device)
            guard seconds.isFinite,
                  seconds > 0,
                  current.durationRangeIsUsable,
                  current.isoIsUsable else {
                _ = self.applySupportedAutomaticExposure(
                    on: device,
                    source: "HockeyCameraService.setManualExposureDuration",
                    requestedOperation: "manual shutter \(seconds)",
                    rejectionReason: "Requested shutter or current ISO state is invalid; \(current.diagnosticText)"
                )
                return
            }
            let minSeconds = CMTimeGetSeconds(device.activeFormat.minExposureDuration)
            let maxSeconds = CMTimeGetSeconds(device.activeFormat.maxExposureDuration)
            let safeMin = minSeconds.isFinite && minSeconds > 0 ? minSeconds : 1.0 / 10_000.0
            let safeMax = maxSeconds.isFinite && maxSeconds > safeMin ? maxSeconds : 1.0 / 2.0
            let clamped = min(max(seconds, safeMin), safeMax)
            let duration = CMTime(seconds: clamped, preferredTimescale: 1_000_000)
            do {
                try device.lockForConfiguration()
                let iso = min(max(device.iso, device.activeFormat.minISO), device.activeFormat.maxISO)
                device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
                device.unlockForConfiguration()
                RinkLensCaptureGraphMutationAudit.shared.record(.liveDeviceControl, detail: "manual exposure duration; sessionRestarted=false")
                DispatchQueue.main.async {
                    self.exposureDurationSeconds = clamped
                    self.shutterSpeedText = Self.shutterSpeedDisplayText(seconds: clamped)
                    self.exposureModeText = "Manual Exposure"
                    self.cameraStatusText = "Manual shutter speed set"
                    self.refreshCameraSettingState()
                }
            } catch {
                DispatchQueue.main.async { self.cameraStatusText = "Manual shutter speed failed" }
            }
        }
    }

    func setExposureTargetBias(_ value: Float) {
        outputQueue.async {
            guard let device = self.cameraDevice else { return }
            let minBias = device.minExposureTargetBias
            let maxBias = device.maxExposureTargetBias
            guard minBias < maxBias else {
                DispatchQueue.main.async { self.cameraStatusText = "Exposure bias unavailable on this camera" }
                return
            }
            let clamped = min(max(value, minBias), maxBias)
            do {
                try device.lockForConfiguration()
                device.setExposureTargetBias(clamped, completionHandler: nil)
                device.unlockForConfiguration()
                RinkLensCaptureGraphMutationAudit.shared.record(.liveDeviceControl, detail: "exposure bias; sessionRestarted=false")
                DispatchQueue.main.async {
                    self.exposureTargetBiasValue = clamped
                    self.cameraStatusText = "Exposure bias set"
                    self.refreshCameraSettingState()
                }
            } catch {
                DispatchQueue.main.async { self.cameraStatusText = "Exposure bias failed" }
            }
        }
    }

    func setManualWhiteBalance(temperature: Float, tint: Float) {
        outputQueue.async {
            guard let device = self.cameraDevice else { return }
            guard device.isWhiteBalanceModeSupported(.locked) else {
                DispatchQueue.main.async { self.cameraStatusText = "Manual white balance unavailable on this camera" }
                return
            }
            do {
                guard self.session.isRunning || self.isExternallyManagedCaptureActive else {
                    DispatchQueue.main.async {
                        self.cameraStatusText = "Manual white balance skipped - camera is still starting"
                        MainThreadStallMonitor.shared.trace("white balance set skipped: session not running")
                    }
                    return
                }
                try device.lockForConfiguration()
                let clampedTemperature = min(max(temperature.isFinite ? temperature : 5_000, 2_500), 8_000)
                let clampedTint = min(max(tint.isFinite ? tint : 0, -50), 50)
                let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: clampedTemperature, tint: clampedTint)
                let gains = device.deviceWhiteBalanceGains(for: values)
                let normalised = self.normalisedWhiteBalanceGains(gains, maxGain: device.maxWhiteBalanceGain)
                device.setWhiteBalanceModeLocked(with: normalised, completionHandler: nil)
                device.unlockForConfiguration()
                RinkLensCaptureGraphMutationAudit.shared.record(.liveDeviceControl, detail: "manual white balance; sessionRestarted=false")
                DispatchQueue.main.async {
                    self.whiteBalanceTemperature = clampedTemperature
                    self.whiteBalanceTint = clampedTint
                    self.whiteBalanceModeText = "Manual White Balance"
                    self.cameraStatusText = "Manual white balance set"
                    self.refreshCameraSettingState()
                }
            } catch {
                DispatchQueue.main.async { self.cameraStatusText = "Manual white balance failed" }
            }
        }
    }

    private func normalisedWhiteBalanceGains(_ gains: AVCaptureDevice.WhiteBalanceGains, maxGain: Float) -> AVCaptureDevice.WhiteBalanceGains {
        let safeMaxGain = (maxGain.isFinite && maxGain >= 1.0) ? maxGain : 1.0
        func clamp(_ value: Float) -> Float {
            guard value.isFinite else { return 1.0 }
            return min(max(value, 1.0), safeMaxGain)
        }
        return AVCaptureDevice.WhiteBalanceGains(
            redGain: clamp(gains.redGain),
            greenGain: clamp(gains.greenGain),
            blueGain: clamp(gains.blueGain)
        )
    }

    // v0.9.1w10f: Do not let AVFoundation white-balance conversion crash startup.
    // On iPad8,9 the crash log showed an Obj-C exception inside
    // AVCaptureFigVideoDevice when refreshCameraSettingState() read/converted
    // white-balance values during camera/lens startup. Swift cannot catch that
    // exception safely, so this refresh path only validates gains and avoids
    // temperature/tint conversion while the device/session may be settling.
    private func refreshWhiteBalanceStateSafely(for device: AVCaptureDevice) {
        guard supportsManualWhiteBalanceGains else { return }

        let maxGain = device.maxWhiteBalanceGain
        let gains = device.deviceWhiteBalanceGains
        let gainsAreValid = maxGain.isFinite
            && maxGain >= 1.0
            && gains.redGain.isFinite
            && gains.greenGain.isFinite
            && gains.blueGain.isFinite
            && gains.redGain >= 1.0
            && gains.greenGain >= 1.0
            && gains.blueGain >= 1.0
            && gains.redGain <= maxGain
            && gains.greenGain <= maxGain
            && gains.blueGain <= maxGain

        guard gainsAreValid else {
            let message = "white balance state skipped: invalid gains max=\(maxGain) r=\(gains.redGain) g=\(gains.greenGain) b=\(gains.blueGain)"
            DispatchQueue.main.async { MainThreadStallMonitor.shared.trace(message) }
            return
        }

        guard session.isRunning else {
            DispatchQueue.main.async { MainThreadStallMonitor.shared.trace("white balance state skipped: session not running") }
            return
        }

        // Keep the last operator-facing temperature/tint values. The exact
        // conversion is not worth risking a startup abort; manual white-balance
        // setting still stores the user-requested values when applied.
        DispatchQueue.main.async {
            MainThreadStallMonitor.shared.trace("white balance state safe: gains valid; temperature/tint conversion skipped during camera refresh")
        }
    }

    func lockCurrentExposure() {
        outputQueue.async {
            guard let device = self.cameraDevice else { return }
            guard device.isExposureModeSupported(.locked) || device.isExposureModeSupported(.custom) else {
                DispatchQueue.main.async { self.cameraStatusText = "Exposure lock unavailable on this camera" }
                return
            }
            let current = self.exposureControlSample(for: device)
            guard current.isUsable else {
                _ = self.applySupportedAutomaticExposure(
                    on: device,
                    source: "HockeyCameraService.lockCurrentExposure",
                    requestedOperation: "lock current exposure",
                    rejectionReason: "Current exposure cannot be locked safely; \(current.diagnosticText)"
                )
                return
            }
            do {
                try device.lockForConfiguration()
                if device.isExposureModeSupported(.locked) {
                    device.exposureMode = .locked
                } else {
                    device.setExposureModeCustom(duration: device.exposureDuration, iso: device.iso, completionHandler: nil)
                }
                device.unlockForConfiguration()
                RinkLensCaptureGraphMutationAudit.shared.record(.liveDeviceControl, detail: "exposure lock; sessionRestarted=false")
                DispatchQueue.main.async { self.exposureModeText = "Exposure Locked" }
            } catch {
                DispatchQueue.main.async { self.cameraStatusText = "Exposure lock failed" }
            }
        }
    }

    func setAutoExposure() {
        outputQueue.async {
            guard let device = self.cameraDevice else { return }
            guard device.isExposureModeSupported(.continuousAutoExposure) || device.isExposureModeSupported(.autoExpose) else {
                DispatchQueue.main.async { self.cameraStatusText = "Auto exposure unavailable on this camera" }
                return
            }
            do {
                try device.lockForConfiguration()
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                } else {
                    device.exposureMode = .autoExpose
                }
                device.unlockForConfiguration()
                RinkLensCaptureGraphMutationAudit.shared.record(.liveDeviceControl, detail: "auto exposure; sessionRestarted=false")
                DispatchQueue.main.async {
                    self.exposureModeText = "Auto Exposure"
                    self.cameraStatusText = "Auto exposure applied"
                    self.stationaryHardwareLockActive = false
                    self.stationaryHardwareLockText = "Stationary lock off"
                    self.refreshCameraSettingState()
                }
            } catch {
                DispatchQueue.main.async { self.cameraStatusText = "Auto exposure failed" }
            }
        }
    }

    func lockCurrentWhiteBalance() {
        outputQueue.async {
            guard let device = self.cameraDevice else { return }
            guard device.isWhiteBalanceModeSupported(.locked) else {
                DispatchQueue.main.async { self.cameraStatusText = "White balance lock unavailable on this camera" }
                return
            }
            do {
                try device.lockForConfiguration()
                device.whiteBalanceMode = .locked
                device.unlockForConfiguration()
                RinkLensCaptureGraphMutationAudit.shared.record(.liveDeviceControl, detail: "white balance lock; sessionRestarted=false")
                DispatchQueue.main.async {
                    self.whiteBalanceModeText = "White Balance Locked"
                    self.cameraStatusText = "White balance locked"
                    self.refreshCameraSettingState()
                }
            } catch {
                DispatchQueue.main.async { self.cameraStatusText = "White balance lock failed" }
            }
        }
    }

    func setAutoWhiteBalance() {
        outputQueue.async {
            guard let device = self.cameraDevice else { return }
            guard device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) || device.isWhiteBalanceModeSupported(.autoWhiteBalance) else {
                DispatchQueue.main.async { self.cameraStatusText = "Auto white balance unavailable on this camera" }
                return
            }
            do {
                try device.lockForConfiguration()
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                } else if device.isWhiteBalanceModeSupported(.autoWhiteBalance) {
                    device.whiteBalanceMode = .autoWhiteBalance
                }
                device.unlockForConfiguration()
                RinkLensCaptureGraphMutationAudit.shared.record(.liveDeviceControl, detail: "auto white balance; sessionRestarted=false")
                DispatchQueue.main.async {
                    self.whiteBalanceModeText = "Auto White Balance"
                    self.cameraStatusText = "Auto white balance enabled"
                    self.refreshCameraSettingState()
                }
            } catch {
                DispatchQueue.main.async { self.cameraStatusText = "Auto white balance failed" }
            }
        }
    }

    /// HockeyCameraService is the sole applied Broadcast-device owner. CaptureEngine
    /// may own the session graph, but it supplies its active AVCaptureDevice to this
    /// service instead of mutating focus, exposure, white balance or torch itself.
    func setTorchEnabled(_ enabled: Bool, label: String = "Broadcast camera", reason: String) {
        outputQueue.async {
            guard let device = self.effectiveCaptureDeviceForRecording() else {
                RinkLensStructuredEventLogger.shared.record(
                    domain: .camera,
                    event: "camera_broadcast_torch_unavailable",
                    entityID: "broadcast-camera",
                    previous: ["device": "none"],
                    next: ["requested": String(enabled), "applied": "false"],
                    source: "HockeyCameraService",
                    reason: reason,
                    authoritativeOwner: "HockeyCameraService"
                )
                DispatchQueue.main.async { self.cameraStatusText = "No camera available for torch control" }
                return
            }
            let previous = device.isTorchActive
            guard device.hasTorch, device.isTorchAvailable else {
                RinkLensStructuredEventLogger.shared.record(
                    domain: .camera,
                    event: "camera_broadcast_torch_applied",
                    entityID: device.uniqueID,
                    previous: ["active": String(previous)],
                    next: ["requested": String(enabled), "supported": "false", "active": String(previous)],
                    source: "HockeyCameraService",
                    reason: reason,
                    authoritativeOwner: "HockeyCameraService"
                )
                DispatchQueue.main.async {
                    self.supportsTorchControl = false
                    self.torchActive = false
                    self.torchStatusText = "Torch unavailable on this camera"
                }
                return
            }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if enabled {
                    try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
                } else {
                    device.torchMode = .off
                }
                let active = device.isTorchActive
                RinkLensStructuredEventLogger.shared.record(
                    domain: .camera,
                    event: "camera_broadcast_torch_applied",
                    entityID: device.uniqueID,
                    previous: ["active": String(previous)],
                    next: ["requested": String(enabled), "supported": "true", "active": String(active)],
                    source: "HockeyCameraService",
                    reason: reason,
                    authoritativeOwner: "HockeyCameraService"
                )
                DispatchQueue.main.async {
                    self.supportsTorchControl = true
                    self.torchActive = active
                    self.torchStatusText = active ? "Torch on" : "Torch off"
                    self.cameraStatusText = "\(label) torch \(active ? "enabled" : "disabled")"
                }
            } catch {
                RinkLensStructuredEventLogger.shared.record(
                    domain: .camera,
                    event: "camera_broadcast_torch_failed",
                    entityID: device.uniqueID,
                    previous: ["active": String(previous)],
                    next: ["requested": String(enabled), "error": error.localizedDescription],
                    source: "HockeyCameraService",
                    reason: reason,
                    authoritativeOwner: "HockeyCameraService"
                )
                DispatchQueue.main.async { self.cameraStatusText = "Torch change failed: \(error.localizedDescription)" }
            }
        }
    }

    /// Toggles only the operator-selected Broadcast parameters by reading the
    /// physical AVCaptureDevice modes. No screen, ViewModel or CaptureEngine lock
    /// mirror exists. A second hold returns to Auto only when every selected
    /// parameter was already locked; a partial lock completes the remaining locks.
    func toggleCameraParameters(
        focus: Bool,
        exposure: Bool,
        whiteBalance: Bool,
        label: String = "Broadcast camera",
        reason: String,
        completion: @escaping @MainActor @Sendable (BroadcastCameraParameterToggleResult) -> Void
    ) {
        outputQueue.async {
            let requestedControls = [
                focus ? "focus" : nil,
                exposure ? "exposure" : nil,
                whiteBalance ? "white balance" : nil
            ].compactMap { $0 }

            guard !requestedControls.isEmpty else {
                RinkLensStructuredEventLogger.shared.record(
                    domain: .camera,
                    event: "camera_broadcast_hold_unavailable",
                    entityID: "broadcast-camera",
                    previous: ["selection": "none"],
                    next: ["result": "no selected controls"],
                    source: "HockeyCameraService",
                    reason: reason,
                    authoritativeOwner: "HockeyCameraService"
                )
                Task { @MainActor in completion(.unavailable("select at least one behaviour")) }
                return
            }

            guard let device = self.effectiveCaptureDeviceForRecording() else {
                RinkLensStructuredEventLogger.shared.record(
                    domain: .camera,
                    event: "camera_broadcast_hold_unavailable",
                    entityID: "broadcast-camera",
                    previous: ["device": "none"],
                    next: ["selection": requestedControls.joined(separator: ","), "result": "no active device"],
                    source: "HockeyCameraService",
                    reason: reason,
                    authoritativeOwner: "HockeyCameraService"
                )
                DispatchQueue.main.async { self.cameraStatusText = "No Broadcast camera available to lock" }
                Task { @MainActor in completion(.unavailable("no active Broadcast camera")) }
                return
            }

            let exposureSample = self.exposureControlSample(for: device)

            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                let previous: [String: String] = [
                    "focus": String(describing: device.focusMode),
                    "exposure": String(describing: device.exposureMode),
                    "exposureSample": exposureSample.diagnosticText,
                    "whiteBalance": String(describing: device.whiteBalanceMode),
                    "selection": requestedControls.joined(separator: ",")
                ]
                let focusLocked = !focus || device.focusMode == .locked
                let exposureLocked = !exposure || device.exposureMode == .locked || device.exposureMode == .custom
                let whiteBalanceLocked = !whiteBalance || device.whiteBalanceMode == .locked
                let everySelectedControlLocked = focusLocked && exposureLocked && whiteBalanceLocked

                var result: BroadcastCameraParameterToggleResult
                var resultText: String
                var lockedControls: [String] = []

                if everySelectedControlLocked {
                    var unavailableAutoControls: [String] = []
                    if focus, !device.isFocusModeSupported(.continuousAutoFocus) { unavailableAutoControls.append("focus") }
                    if exposure, !device.isExposureModeSupported(.continuousAutoExposure) { unavailableAutoControls.append("exposure") }
                    if whiteBalance, !device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { unavailableAutoControls.append("white balance") }

                    if unavailableAutoControls.isEmpty {
                        if focus { device.focusMode = .continuousAutoFocus }
                        if exposure { device.exposureMode = .continuousAutoExposure }
                        if whiteBalance { device.whiteBalanceMode = .continuousAutoWhiteBalance }
                        if focus, device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = true }
                        result = .automatic
                        resultText = "automatic"
                    } else {
                        result = .unavailable("Auto unsupported for \(unavailableAutoControls.joined(separator: ", "))")
                        resultText = "auto unavailable"
                    }
                } else {
                    var unavailableLockControls: [String] = []
                    if focus, device.focusMode != .locked, !device.isFocusModeSupported(.locked) {
                        unavailableLockControls.append("focus")
                    }
                    if exposure,
                       device.exposureMode != .locked,
                       device.exposureMode != .custom,
                       !device.isExposureModeSupported(.locked),
                       !device.isExposureModeSupported(.custom) {
                        unavailableLockControls.append("exposure")
                    } else if exposure,
                              device.exposureMode != .locked,
                              device.exposureMode != .custom,
                              !exposureSample.isUsable {
                        unavailableLockControls.append("exposure (invalid ISO/shutter)")
                    }
                    if whiteBalance, device.whiteBalanceMode != .locked, !device.isWhiteBalanceModeSupported(.locked) {
                        unavailableLockControls.append("white balance")
                    }

                    if unavailableLockControls.isEmpty {
                        if focus {
                            if device.focusMode != .locked {
                                if device.isLockingFocusWithCustomLensPositionSupported {
                                    device.setFocusModeLocked(lensPosition: device.lensPosition, completionHandler: nil)
                                } else {
                                    device.focusMode = .locked
                                }
                            }
                            lockedControls.append("focus")
                        }
                        if exposure {
                            if device.exposureMode != .locked && device.exposureMode != .custom {
                                if device.isExposureModeSupported(.locked) {
                                    device.exposureMode = .locked
                                } else {
                                    device.setExposureModeCustom(duration: device.exposureDuration, iso: device.iso, completionHandler: nil)
                                }
                            }
                            lockedControls.append("exposure")
                        }
                        if whiteBalance {
                            if device.whiteBalanceMode != .locked { device.whiteBalanceMode = .locked }
                            lockedControls.append("white balance")
                        }
                        if focus, device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = false }
                        result = .locked(lockedControls)
                        resultText = "locked"
                    } else {
                        result = .unavailable("Lock unsupported for \(unavailableLockControls.joined(separator: ", "))")
                        resultText = "lock unavailable"
                    }
                }

                let next: [String: String] = [
                    "focus": String(describing: device.focusMode),
                    "exposure": String(describing: device.exposureMode),
                    "whiteBalance": String(describing: device.whiteBalanceMode),
                    "result": resultText,
                    "applied": lockedControls.joined(separator: ",")
                ]
                RinkLensStructuredEventLogger.shared.record(
                    domain: .camera,
                    event: "camera_broadcast_hold_toggled",
                    entityID: device.uniqueID,
                    previous: previous,
                    next: next,
                    source: "HockeyCameraService",
                    reason: reason,
                    authoritativeOwner: "HockeyCameraService"
                )
                let completionResult = result
                Task { @MainActor in
                    switch completionResult {
                    case .locked(let controls):
                        self.stationaryHardwareLockActive = true
                        self.stationaryHardwareLockText = "Locked: \(controls.joined(separator: ", "))"
                        self.cameraStatusText = "\(label) lock applied"
                    case .automatic:
                        self.stationaryHardwareLockActive = false
                        self.stationaryHardwareLockText = "Stationary lock off"
                        self.cameraStatusText = "\(label) returned to automatic controls"
                    case .unavailable(let detail):
                        self.cameraStatusText = "Camera lock unavailable: \(detail)"
                    case .failed(let detail):
                        self.cameraStatusText = "Camera lock failed: \(detail)"
                    }
                    self.refreshCameraSettingState()
                    completion(completionResult)
                }
            } catch {
                let errorDescription = error.localizedDescription
                RinkLensStructuredEventLogger.shared.record(
                    domain: .camera,
                    event: "camera_broadcast_hold_failed",
                    entityID: device.uniqueID,
                    previous: ["selection": requestedControls.joined(separator: ",")],
                    next: ["result": "failed", "error": errorDescription],
                    source: "HockeyCameraService",
                    reason: reason,
                    authoritativeOwner: "HockeyCameraService"
                )
                Task { @MainActor in
                    self.cameraStatusText = "Camera lock toggle failed: \(errorDescription)"
                    completion(.failed(errorDescription))
                }
            }
        }
    }

    /// v0.8.4: Locks the selected camera for a fixed/stationary OCR role.
    /// This is intended for the external OCR camera after calibration. It avoids
    /// focus/exposure/white-balance hunting that can create OCR and capture hitches.
    func lockForStationaryRole(label: String = "OCR camera") {
        outputQueue.async {
            guard let device = self.cameraDevice else {
                DispatchQueue.main.async { self.cameraStatusText = "No camera selected to lock" }
                return
            }

            let exposureSample = self.exposureControlSample(for: device)
            let exposureNeedsAutomaticRecovery = !exposureSample.isUsable

            do {
                try device.lockForConfiguration()

                var lockedParts: [String] = []
                if device.isFocusModeSupported(.locked) {
                    if device.isLockingFocusWithCustomLensPositionSupported {
                        device.setFocusModeLocked(lensPosition: device.lensPosition, completionHandler: nil)
                    } else {
                        device.focusMode = .locked
                    }
                    lockedParts.append("focus")
                }

                if !exposureNeedsAutomaticRecovery, device.isExposureModeSupported(.locked) {
                    device.exposureMode = .locked
                    lockedParts.append("exposure")
                } else if !exposureNeedsAutomaticRecovery, device.isExposureModeSupported(.custom) {
                    device.setExposureModeCustom(duration: device.exposureDuration, iso: device.iso, completionHandler: nil)
                    lockedParts.append("exposure")
                }

                if device.isWhiteBalanceModeSupported(.locked) {
                    device.whiteBalanceMode = .locked
                    lockedParts.append("white balance")
                }

                if device.isSmoothAutoFocusSupported {
                    device.isSmoothAutoFocusEnabled = false
                }

                device.unlockForConfiguration()

                if exposureNeedsAutomaticRecovery {
                    _ = self.applySupportedAutomaticExposure(
                        on: device,
                        source: "HockeyCameraService.lockForStationaryRole",
                        requestedOperation: "stationary OCR exposure lock",
                        rejectionReason: "Current exposure cannot be locked safely; \(exposureSample.diagnosticText)"
                    )
                }

                let summary = lockedParts.isEmpty ? "No lockable controls" : lockedParts.joined(separator: ", ")
                DispatchQueue.main.async {
                    self.stationaryHardwareLockActive = !lockedParts.isEmpty
                    self.stationaryHardwareLockText = !lockedParts.isEmpty ? "Stationary lock on: \(summary)" : "Stationary lock unavailable"
                    self.focusModeText = device.focusMode == .locked ? "Focus Locked" : self.focusModeText
                    self.exposureModeText = (device.exposureMode == .locked || device.exposureMode == .custom) ? "Exposure Locked" : self.exposureModeText
                    self.whiteBalanceModeText = device.whiteBalanceMode == .locked ? "White Balance Locked" : self.whiteBalanceModeText
                    self.cameraStatusText = "\(label) stationary hardware lock applied"
                    self.refreshCameraSettingState()
                }
            } catch {
                DispatchQueue.main.async { self.cameraStatusText = "Stationary camera lock failed" }
            }
        }
    }

    /// v0.8.4: Releases the stationary lock and returns supported controls to continuous auto.
    func unlockStationaryRole(label: String = "OCR camera", reason: String? = nil) {
        outputQueue.async {
            guard let device = self.effectiveCaptureDeviceForRecording() else {
                RinkLensStructuredEventLogger.shared.record(
                    domain: .camera,
                    event: "camera_parameters_unlock_unavailable",
                    entityID: "camera",
                    previous: ["device": "none"],
                    next: ["result": "not applied"],
                    source: "HockeyCameraService",
                    reason: reason ?? "\(label) returned to automatic controls",
                    authoritativeOwner: "HockeyCameraService"
                )
                return
            }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                if device.isSmoothAutoFocusSupported {
                    device.isSmoothAutoFocusEnabled = true
                }
                let next: [String: String] = [
                    "focus": String(describing: device.focusMode),
                    "exposure": String(describing: device.exposureMode),
                    "whiteBalance": String(describing: device.whiteBalanceMode)
                ]
                RinkLensStructuredEventLogger.shared.record(
                    domain: .camera,
                    event: "camera_parameters_unlocked",
                    entityID: device.uniqueID,
                    previous: ["mode": "locked"],
                    next: next,
                    source: "HockeyCameraService",
                    reason: reason ?? "\(label) returned to automatic controls",
                    authoritativeOwner: "HockeyCameraService"
                )

                DispatchQueue.main.async {
                    self.stationaryHardwareLockActive = false
                    self.stationaryHardwareLockText = "Stationary lock off"
                    self.focusModeText = "Auto Focus"
                    self.exposureModeText = "Auto Exposure"
                    self.whiteBalanceModeText = "Auto White Balance"
                    self.cameraStatusText = "\(label) stationary hardware lock released"
                    self.refreshCameraSettingState()
                }
            } catch {
                RinkLensStructuredEventLogger.shared.record(
                    domain: .camera,
                    event: "camera_parameters_unlock_failed",
                    entityID: device.uniqueID,
                    previous: ["mode": "locked"],
                    next: ["result": "failed", "error": error.localizedDescription],
                    source: "HockeyCameraService",
                    reason: reason ?? "\(label) returned to automatic controls",
                    authoritativeOwner: "HockeyCameraService"
                )
                DispatchQueue.main.async { self.cameraStatusText = "Stationary camera unlock failed: \(error.localizedDescription)" }
            }
        }
    }

    private static func shutterSpeedDisplayText(seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "Auto shutter" }
        if seconds < 1.0 {
            let denominator = max(1, Int(round(1.0 / seconds)))
            return "1/\(denominator)s"
        }
        return String(format: "%.2fs", seconds)
    }

    private func refreshCameraSettingState(source: String = "camera settings refresh") {
        // UX16c16: HockeyCameraService is observed directly by SwiftUI. Publishing
        // from the AVCapture output queue caused updateUIView/configure to execute on
        // camera.ocr.output.queue, where reading UIView.layer is illegal. That left
        // the preview black and, under Main Thread Checker, terminated the debug run.
        // Keep AVFoundation configuration on outputQueue, but always publish the
        // resulting UI snapshot on the main thread.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.cameraUIPublicationThreadText = "Rerouted to main: \(source)"
                MainThreadStallMonitor.shared.trace(
                    RinkLensBuildInfo.traceContext("camera UI publication rerouted to main source=\(source)")
                )
                self.refreshCameraSettingState(source: source)
            }
            return
        }

        if cameraUIPublicationThreadText != "Main-thread confined: \(source)" {
            cameraUIPublicationThreadText = "Main-thread confined: \(source)"
        }
        let previousAppliedState = appliedCameraStateSummary()
        guard let device = cameraDevice else { return }
        resolvedCameraDeviceID = device.uniqueID
        isCameraSelectionDisabled = false
        selectedCameraName = device.localizedName
        selectedCameraIsExternal = device.deviceType == .external
        selectedCameraPosition = device.position
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let activeCadence = RinkLensCaptureCadence(duration: device.activeVideoMaxFrameDuration)
        selectedResolutionFPS = "\(dims.width)x\(dims.height) @ \(activeCadence.displayText)fps"
        supportsManualFocus = device.isLockingFocusWithCustomLensPositionSupported && device.isFocusModeSupported(.locked)
        supportsAutoFocus = device.isFocusModeSupported(.continuousAutoFocus) || device.isFocusModeSupported(.autoFocus)
        let exposureSample = exposureControlSample(for: device)
        let customExposureSupported = device.isExposureModeSupported(.custom)
            && exposureSample.isoRangeIsUsable
            && exposureSample.durationRangeIsUsable
        supportsManualISO = customExposureSupported
        supportsManualExposureDuration = customExposureSupported
        supportsAutoExposure = device.isExposureModeSupported(.continuousAutoExposure) || device.isExposureModeSupported(.autoExpose)
        supportsExposureLockOrCustom = (device.isExposureModeSupported(.locked) || customExposureSupported)
            && exposureSample.isUsable
        supportsWhiteBalanceLock = device.isWhiteBalanceModeSupported(.locked)
        supportsManualWhiteBalanceGains = device.isWhiteBalanceModeSupported(.locked)
        supportsAutoWhiteBalance = device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) || device.isWhiteBalanceModeSupported(.autoWhiteBalance)
        supportsExposureBias = device.minExposureTargetBias < device.maxExposureTargetBias
        minISO = device.activeFormat.minISO
        maxISO = device.activeFormat.maxISO
        minExposureTargetBias = device.minExposureTargetBias
        maxExposureTargetBias = device.maxExposureTargetBias
        exposureTargetBiasValue = device.exposureTargetBias
        minExposureDurationSeconds = CMTimeGetSeconds(device.activeFormat.minExposureDuration)
        maxExposureDurationSeconds = CMTimeGetSeconds(device.activeFormat.maxExposureDuration)
        focusPosition = device.lensPosition
        isoValue = device.iso
        exposureDurationSeconds = CMTimeGetSeconds(device.exposureDuration)
        shutterSpeedText = Self.shutterSpeedDisplayText(seconds: exposureDurationSeconds)
        if supportsManualWhiteBalanceGains {
            refreshWhiteBalanceStateSafely(for: device)
        }
        currentZoomFactor = device.videoZoomFactor
        if device.deviceType == .external && !supportsAutoFocus && !supportsManualFocus {
            focusModeText = "UVC / camera-managed focus"
        } else {
            focusModeText = (device.focusMode == .locked) ? "Manual Focus (Locked)" : "Auto Focus"
        }
        if device.deviceType == .external && !supportsAutoExposure && !supportsExposureLockOrCustom {
            exposureModeText = "UVC / camera-managed exposure"
        } else {
            exposureModeText = (device.exposureMode == .custom || device.exposureMode == .locked) ? "Manual/Locked Exposure" : "Auto Exposure"
        }
        if device.deviceType == .external && !supportsAutoWhiteBalance && !supportsWhiteBalanceLock {
            whiteBalanceModeText = "UVC / camera-managed white balance"
        } else {
            whiteBalanceModeText = (device.whiteBalanceMode == .locked) ? "White Balance Locked" : "Auto White Balance"
        }
        stationaryHardwareLockActive = (supportsManualFocus && device.focusMode == .locked)
            || (supportsExposureLockOrCustom && (device.exposureMode == .locked || device.exposureMode == .custom))
            || (supportsWhiteBalanceLock && device.whiteBalanceMode == .locked)
        stationaryHardwareLockText = stationaryHardwareLockActive ? "Stationary lock on" : "Stationary lock off"
        let positionText: String
        switch device.position {
        case .front: positionText = "front"
        case .back: positionText = "back"
        default: positionText = "unspecified"
        }
        activeCameraDeviceDetailsText = "\(device.localizedName) | \(device.deviceType.rawValue) | \(positionText)"
        activeCameraFormatDetailsText = "\(dims.width)x\(dims.height) @ \(activeCadence.displayText)fps | ISO \(Int(minISO))-\(Int(maxISO)) | shutter \(Self.shutterSpeedDisplayText(seconds: minExposureDurationSeconds))-\(Self.shutterSpeedDisplayText(seconds: maxExposureDurationSeconds))"
        broadcastActiveLensText = "Lens: \(device.deviceType == .builtInUltraWideCamera ? "Ultra Wide" : "Wide/virtual rear")"
        broadcastAppliedCadenceText = "Source cadence: \(activeCadence.displayText) fps"
        lowLightBoostStatusText = device.isLowLightBoostSupported
            ? "Low-light boost: supported • requested \(device.automaticallyEnablesLowLightBoostWhenAvailable ? "automatic" : "off")"
            : "Low-light boost: unavailable on this format"
        supportsTorchControl = device.hasTorch && device.isTorchAvailable
        torchActive = device.isTorchActive
        torchStatusText = supportsTorchControl ? (torchActive ? "Torch on" : "Torch off") : "Torch unavailable"
        // v0.8.4h: Do not enumerate device.formats here. This method is called
        // from UI-visible lifecycle paths and format enumeration can block the
        // main thread for several seconds on some iPad/USB-camera combinations.
        // The format list is populated during camera configuration on the
        // camera queue and is refreshed automatically when Manual mode or a source is selected.
        if let selectedID = videoFormatMap.first(where: { $0.value === device.activeFormat })?.key {
            selectedVideoFormatID = selectedID
        }
        recordAppliedCameraTransition(
            event: "camera_hardware_state_refreshed",
            previous: previousAppliedState,
            next: appliedCameraStateSummary(),
            reason: source
        )
    }

    private func appliedCameraStateSummary() -> [String: String] {
        [
            "selectedLogicalSource": selectedCameraID ?? "none",
            "resolvedPhysicalDevice": resolvedCameraDeviceID ?? "none",
            "deviceName": selectedCameraName,
            "position": String(selectedCameraPosition.rawValue),
            "format": selectedResolutionFPS,
            "focusMode": focusModeText,
            "focusPosition": String(focusPosition),
            "exposureMode": exposureModeText,
            "iso": String(isoValue),
            "shutter": String(exposureDurationSeconds),
            "whiteBalanceMode": whiteBalanceModeText,
            "whiteBalanceTemperature": String(whiteBalanceTemperature),
            "whiteBalanceTint": String(whiteBalanceTint),
            "zoom": String(Double(currentZoomFactor))
        ]
    }

    private func recordCameraSourceAvailabilityTransition(
        previous: CameraOption?,
        next: CameraOption,
        reason: String
    ) {
        guard previous?.isAvailable != next.isAvailable else { return }
        RinkLensStructuredEventLogger.shared.record(
            domain: .camera,
            event: "camera_logical_source_availability_changed",
            entityID: next.id,
            previous: [
                "available": previous.map { String($0.isAvailable) } ?? "unknown",
                "label": previous?.name ?? "none"
            ],
            next: [
                "available": String(next.isAvailable),
                "label": next.name
            ],
            source: "HockeyCameraService.refreshAvailableCameras",
            reason: reason,
            authoritativeOwner: "HockeyCameraService"
        )
    }

    private func recordSelectedCameraSourceTransition(
        previous: String?,
        next: String?,
        source: String,
        reason: String,
        transactionID: UUID? = nil
    ) {
        guard previous != next else { return }
        RinkLensStructuredEventLogger.shared.record(
            domain: .camera,
            event: "camera_logical_source_changed",
            entityID: operationalRole.rawValue.lowercased(),
            previous: ["selectedLogicalSource": previous ?? "none"],
            next: ["selectedLogicalSource": next ?? "none"],
            source: source,
            reason: reason,
            transactionID: transactionID,
            authoritativeOwner: "HockeyCameraService"
        )
    }

    private func requestedCameraControlSummary() -> [String: String] {
        [
            "role": operationalRole.rawValue,
            "roleDefault": String(roleDefaultProfileEnabled),
            "requestedFormat": selectedResolutionFPS,
            "automaticLens": String(appleStyleAutoQualityEnabled)
        ]
    }

    private func recordRequestedCameraTransition(
        event: String,
        previous: [String: String],
        next: [String: String],
        reason: String
    ) {
        guard previous != next else { return }
        RinkLensStructuredEventLogger.shared.record(
            domain: .camera,
            event: event,
            entityID: selectedCameraID,
            previous: previous,
            next: next,
            source: "HockeyCameraService",
            reason: reason,
            authoritativeOwner: "HockeyCameraService"
        )
    }

    private func recordAppliedCameraTransition(
        event: String,
        previous: [String: String],
        next: [String: String],
        reason: String,
        transactionID: UUID? = nil
    ) {
        guard previous != next else { return }
        RinkLensStructuredEventLogger.shared.record(
            domain: .camera,
            event: event,
            entityID: resolvedCameraDeviceID ?? selectedCameraID,
            previous: previous,
            next: next,
            source: "HockeyCameraService",
            reason: reason,
            transactionID: transactionID,
            authoritativeOwner: "HockeyCameraService"
        )
    }

    /// UX16c41c: Automatic, role-independent camera format discovery.
    ///
    /// The settings facade can release its runtime `cameraDevice` while the
    /// other CaptureEngine branch is active. Resolve the selected source again
    /// so Broadcast and OCR manual menus remain available independently.
    func refreshVideoFormats(force: Bool = false, reason: String = "automatic format discovery") {
        outputQueue.async { [weak self] in
            guard let self else { return }

            let devices = self.discoveredVideoDevices()
            let device = self.cameraDevice
                ?? self.preferredCameraID.flatMap { preferredID in
                    devices.first(where: { $0.uniqueID == preferredID })
                }
                ?? self.selectedCameraID.flatMap { sourceID in
                    self.resolveCameraDevice(sourceID: sourceID, from: devices)
                }

            guard let device else {
                DispatchQueue.main.async {
                    self.videoFormatsLoaded = false
                    self.isLoadingVideoFormats = false
                    self.videoFormatLoadStatusText = self.cameraSelectionDisabledByUser
                        ? "No camera selected"
                        : "Waiting for selected camera discovery"
                }
                self.cameraBreadcrumb(.discovery, phase: "automatic format discovery deferred", extra: "reason=\(reason)")
                return
            }

            self.cameraDevice = device
            self.preferredCameraID = device.uniqueID

            if !force && self.videoFormatsLoaded && !self.availableVideoFormats.isEmpty {
                DispatchQueue.main.async {
                    self.videoFormatLoadStatusText = "Using cached formats for \(device.localizedName)"
                }
                return
            }

            DispatchQueue.main.async {
                self.isLoadingVideoFormats = true
                self.videoFormatLoadStatusText = "Loading cached camera capabilities…"
            }

            let discoveryStarted = CFAbsoluteTimeGetCurrent()
            let (formats, formatMap) = self.availableFormats(for: device)
            let profiles = self.buildCapabilityProfiles(using: formatMap)
            let selectedID = formatMap.first(where: { $0.value === device.activeFormat })?.key
            let selectedCadence = self.captureFormatPreferenceOverride?.cadence
                ?? RinkLensCaptureCadence(duration: device.activeVideoMinFrameDuration)
            let activeDimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            let selectedCapabilityProfileID = profiles.first(where: {
                if let selectedID {
                    return $0.formatID == selectedID && $0.cadence == selectedCadence
                }
                return $0.width == activeDimensions.width
                    && $0.height == activeDimensions.height
                    && $0.cadence == selectedCadence
            })?.id
            self.videoFormatMap = formatMap
            let discoveryMS = max(0, (CFAbsoluteTimeGetCurrent() - discoveryStarted) * 1_000)

            DispatchQueue.main.async {
                self.availableVideoFormats = formats
                self.selectedVideoFormatID = selectedID
                self.capabilityProfiles = profiles
                self.selectedCapabilityProfileID = selectedCapabilityProfileID
                self.videoFormatsLoaded = true
                self.isLoadingVideoFormats = false
                self.videoFormatLoadStatusText = profiles.isEmpty
                    ? "No supported 720p, 1080p, or 1440p modes at 30/60 fps"
                    : "Cached capabilities ready: \(profiles.count) operator modes"
            }
            RinkLensStructuredEventLogger.shared.record(
                domain: .cameraControl,
                event: "camera_capability_snapshot_rebuilt_off_main",
                entityID: device.uniqueID,
                previous: ["capabilitySource": "screen-triggered/MainActor profile build"],
                next: ["formats": String(formats.count), "profiles": String(profiles.count), "durationMs": String(format: "%.1f", discoveryMS)],
                source: "HockeyCameraService.outputQueue",
                reason: reason,
                authoritativeOwner: "HockeyCameraService"
            )
            self.cameraBreadcrumb(
                .discovery,
                phase: "automatic format discovery completed",
                extra: "device=\(device.localizedName){\(device.uniqueID)} formats=\(formats.count) reason=\(reason)"
            )
        }
    }

    func ensureManualFormatOptionsLoaded(reason: String) {
        // R16: views only consume the cached capability snapshot. Physical-device
        // selection/connect/disconnect paths own invalidation and rebuilding.
        if capabilityProfiles.isEmpty {
            refreshVideoFormats(force: true, reason: "capability cache miss: \(reason)")
        } else {
            videoFormatLoadStatusText = "Using cached camera capabilities"
        }
    }

    private func buildCapabilityProfiles(using formatMap: [String: AVCaptureDevice.Format]) -> [CapabilityProfileOption] {
        // UX16c41a: keep the operator list intentionally small and predictable.
        // Each camera only exposes combinations it truly supports from:
        // 720p / 1080p / 1440p at the operator-facing 30 or 60 fps families.
        // NTSC 29.97/59.94 devices are represented as 30/60 in the UI while the
        // exact rational CMTime cadence remains in the capture contract.
        let supportedResolutions: [(label: String, width: Int32, height: Int32)] = [
            ("720p HD", 1280, 720),
            ("1080p HD", 1920, 1080),
            ("1440p QHD", 2560, 1440)
        ]
        let operatorFrameRates = [30, 60]

        var byVisibleMode: [String: CapabilityProfileOption] = [:]
        for (formatID, format) in formatMap {
            guard format.isMultiCamSupported else { continue }
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let landscapeWidth = max(dims.width, dims.height)
            let landscapeHeight = min(dims.width, dims.height)
            guard let resolution = supportedResolutions.first(where: {
                $0.width == landscapeWidth && $0.height == landscapeHeight
            }) else { continue }

            for operatorFPS in operatorFrameRates {
                guard let cadence = preferredOperatorCadence(operatorFPS, for: format) else { continue }
                let visibleKey = "\(resolution.width)x\(resolution.height)-\(operatorFPS)"
                let id = "Operator-\(resolution.width)x\(resolution.height)-\(operatorFPS)-\(formatID)"
                let option = CapabilityProfileOption(
                    id: id,
                    tierLabel: "Standard",
                    cadence: cadence,
                    width: dims.width,
                    height: dims.height,
                    formatID: formatID,
                    resolutionLabel: "\(resolution.label) at \(operatorFPS) fps",
                    isCommonRate: true
                )

                guard let existing = byVisibleMode[visibleKey],
                      let existingID = existing.formatID,
                      let existingFormat = formatMap[existingID] else {
                    byVisibleMode[visibleKey] = option
                    continue
                }

                let candidateIsExactInteger = cadence.durationValue == 1 && cadence.durationTimescale == Int32(operatorFPS)
                let existingIsExactInteger = existing.cadence.durationValue == 1 && existing.cadence.durationTimescale == Int32(operatorFPS)
                if candidateIsExactInteger != existingIsExactInteger {
                    if candidateIsExactInteger { byVisibleMode[visibleKey] = option }
                    continue
                }

                // Recovery CY / RL-166: picture quality outranks the old
                // lower-cost binned preference for the Broadcast source.
                if format.isVideoBinned != existingFormat.isVideoBinned {
                    if !format.isVideoBinned { byVisibleMode[visibleKey] = option }
                    continue
                }

                if formatID < existingID {
                    byVisibleMode[visibleKey] = option
                }
            }
        }

        let profiles = byVisibleMode.values.sorted {
            let lhsArea = Int64($0.width) * Int64($0.height)
            let rhsArea = Int64($1.width) * Int64($1.height)
            if lhsArea != rhsArea { return lhsArea < rhsArea }
            return $0.nominalFPS < $1.nominalFPS
        }
        return profiles
    }

    private func preferredOperatorCadence(
        _ operatorFPS: Int,
        for format: AVCaptureDevice.Format
    ) -> RinkLensCaptureCadence? {
        let candidates: [RinkLensCaptureCadence]
        switch operatorFPS {
        case 30:
            candidates = [
                .init(integerFPS: 30),
                .init(durationValue: 1_001, durationTimescale: 30_000)
            ]
        case 60:
            candidates = [
                .init(integerFPS: 60),
                .init(durationValue: 1_001, durationTimescale: 60_000)
            ]
        default:
            return nil
        }
        return candidates.first(where: { supportsCadence($0, for: format) })
    }

    private func supportedCaptureCadences(
        for format: AVCaptureDevice.Format,
        includeAdvanced: Bool
    ) -> [RinkLensCaptureCadence] {
        var cadences = Set<RinkLensCaptureCadence>()

        for cadence in RinkLensCaptureCadence.commonRates where supportsCadence(cadence, for: format) {
            cadences.insert(cadence)
        }

        guard includeAdvanced else {
            return cadences.sorted { $0.framesPerSecond < $1.framesPerSecond }
        }

        for range in format.videoSupportedFrameRateRanges {
            let lower = max(1, Int(ceil(range.minFrameRate)))
            let upper = min(240, Int(floor(range.maxFrameRate)))
            if lower <= upper {
                for fps in lower...upper {
                    let cadence = RinkLensCaptureCadence(integerFPS: fps)
                    if supportsCadence(cadence, for: format) { cadences.insert(cadence) }
                }
            }

            let minCadence = RinkLensCaptureCadence(duration: range.maxFrameDuration)
            let maxCadence = RinkLensCaptureCadence(duration: range.minFrameDuration)
            if supportsCadence(minCadence, for: format) { cadences.insert(minCadence) }
            if supportsCadence(maxCadence, for: format) { cadences.insert(maxCadence) }
        }

        return cadences.sorted { $0.framesPerSecond < $1.framesPerSecond }
    }

    private func supportsCadence(
        _ cadence: RinkLensCaptureCadence,
        for format: AVCaptureDevice.Format
    ) -> Bool {
        let target = cadence.framesPerSecond
        return format.videoSupportedFrameRateRanges.contains { range in
            target + 0.005 >= range.minFrameRate && target - 0.005 <= range.maxFrameRate
        }
    }

    private func capabilityProfileLabel(
        for format: AVCaptureDevice.Format,
        cadence: RinkLensCaptureCadence
    ) -> String {
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let resolutionText: String
        if dims.width > 2560 || dims.height > 1440 {
            resolutionText = "Unsupported high resolution"
        } else if dims.width == 2560 && dims.height == 1440 {
            resolutionText = "1440p QHD"
        } else if dims.width == 1920 && dims.height == 1080 {
            resolutionText = "1080p HD"
        } else if dims.width == 1280 && dims.height == 720 {
            resolutionText = "720p HD"
        } else {
            resolutionText = "\(dims.width)x\(dims.height)"
        }
        return "\(resolutionText) at \(cadence.displayText) fps"
    }

    func latestRecordingFrameImage() -> UIImage? {
        latestRecordingFrameSnapshot(maxAge: nil)?.image
    }

    func latestRecordingFrameSnapshot(maxAge: TimeInterval? = 1.25) -> RecordingCameraFrameSnapshot? {
        guard let frame = RinkLensFrameHub.shared.latestFrame(
            for: frameHubRole,
            maxAge: maxAge
        ) else { return nil }
        let ciImage = CIImage(cvPixelBuffer: frame.pixelBuffer)
        guard let cgImage = recordingFrameCIContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return RecordingCameraFrameSnapshot(
            image: UIImage(cgImage: cgImage, scale: 1, orientation: .up),
            capturedAt: frame.capturedAt,
            sequence: frame.sequence,
            width: frame.width,
            height: frame.height
        )
    }

    func latestRecordingFrameAgeText() -> String {
        let roleSnapshot = frameHubRole == .broadcast
            ? RinkLensFrameHub.shared.diagnosticSnapshot().broadcast
            : RinkLensFrameHub.shared.diagnosticSnapshot().ocr
        guard let age = roleSnapshot.ageSeconds else { return "--" }
        return String(format: "%.1fs", age)
    }

    func latestRecordingPixelBufferSnapshot(maxAge: TimeInterval? = 0.35) -> RecordingCameraPixelBufferSnapshot? {
        RinkLensFrameHub.shared.latestPixelBufferSnapshot(
            for: frameHubRole,
            maxAge: maxAge
        )
    }

    private func effectiveCaptureDeviceForRecording() -> AVCaptureDevice? {
        externalCaptureOwnerLock.lock()
        let externalDevice = externalCaptureOwnerDevice
        externalCaptureOwnerLock.unlock()
        return externalDevice ?? cameraDevice
    }

    func setRecordingFrameCaptureTargetFPS(_ fps: Int) {
        let clamped = min(max(fps, 15), 60)
        DispatchQueue.main.async { [weak self] in
            self?.recordingFrameCaptureStatusText = "FrameHub recording target: \(clamped)fps"
        }
    }

    func enableRecordingFrameCapture(reason: String) {
        setRecordingFrameCaptureEnabled(true, reason: reason)
    }

    func disableRecordingFrameCapture(reason: String) {
        setRecordingFrameCaptureEnabled(false, reason: reason)
    }

    private func setRecordingFrameCaptureEnabled(_ enabled: Bool, reason: String) {
        outputQueue.async { [weak self] in
            guard let self else { return }
            guard self.recordingFrameCaptureEnabled != enabled else {
                DispatchQueue.main.async {
                    self.recordingFrameCaptureStatusText = enabled
                        ? "CaptureEngine recording source already enabled"
                        : "CaptureEngine recording source already disabled"
                }
                return
            }

            self.recordingFrameCaptureEnabled = enabled
            let active = self.isExternallyManagedCaptureActive
            DispatchQueue.main.async {
                self.recordingFrameCaptureStatusText = enabled
                    ? (active
                        ? "Recording frames supplied by CaptureEngine FrameHub: \(reason)"
                        : "Recording frame request waiting for CaptureEngine: \(reason)")
                    : "CaptureEngine recording frame request off: \(reason)"
                CameraOwnershipTraceStore.record(
                    enabled ? .frameTapOn : .frameTapOff,
                    owner: .recording,
                    reason: "UX16c35 CaptureEngine FrameHub \(reason)"
                )
            }
            self.cameraBreadcrumb(
                .lifecycle,
                phase: "recording frame request delegated to CaptureEngine FrameHub",
                extra: "enabled=\(enabled) active=\(active) reason=\(reason)"
            )
        }
    }

    func setAppleStyleAutoQualityEnabled(_ enabled: Bool) {
        let previousRequest = requestedCameraControlSummary()
        // Publish the bound value on the first tap. The previous main-queue hop
        // allowed SwiftUI to read back the old value and made the switch appear
        // to require two taps.
        if Thread.isMainThread {
            self.appleStyleAutoQualityEnabled = enabled
            if enabled, !RinkLensRiskFeaturePolicy.isEnabled(.operationalCameraOverridesV10), RinkLensRiskFeaturePolicy.isEnabled(.builtInAutoClearsExactProfileV9) {
                self.selectedCapabilityProfileID = nil
                self.selectedVideoFormatID = nil
                self.selectedResolutionFPS = "Auto — resolving verified camera source"
            }
        } else {
            DispatchQueue.main.async {
                self.appleStyleAutoQualityEnabled = enabled
                if enabled, !RinkLensRiskFeaturePolicy.isEnabled(.operationalCameraOverridesV10), RinkLensRiskFeaturePolicy.isEnabled(.builtInAutoClearsExactProfileV9) {
                    self.selectedCapabilityProfileID = nil
                    self.selectedVideoFormatID = nil
                    self.selectedResolutionFPS = "Auto — resolving verified camera source"
                }
            }
        }

        if Thread.isMainThread {
            recordRequestedCameraTransition(
                event: "camera_automatic_lens_requested",
                previous: previousRequest,
                next: requestedCameraControlSummary(),
                reason: "operator changed automatic focus/exposure/white-balance mode"
            )
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.recordRequestedCameraTransition(
                    event: "camera_automatic_lens_requested",
                    previous: previousRequest,
                    next: self.requestedCameraControlSummary(),
                    reason: "operator changed automatic focus/exposure/white-balance mode"
                )
            }
        }

        outputQueue.async {
            self.appleStyleAutoQualityCaptureEnabled = enabled
            if let device = self.cameraDevice {
                do {
                    try device.lockForConfiguration()
                    if enabled {
                        let cameraID = self.preferredCameraID ?? self.cameraDevice?.uniqueID
                        let previousExactFormat = self.preferredVideoFormatID ?? "none"
                        let previousExactCadence = self.preferredVideoFrameRate.map { String($0) } ?? "none"
                        self.preferredVideoFrameRate = nil
                        if !RinkLensRiskFeaturePolicy.isEnabled(.operationalCameraOverridesV10), RinkLensRiskFeaturePolicy.isEnabled(.builtInAutoClearsExactProfileV9) {
                            self.preferredVideoFormatID = nil
                            self.captureFormatPreferenceOverride = nil
                        }
                        if let cameraID {
                            self.preferredVideoFrameRateByCameraID.removeValue(forKey: cameraID)
                            if !RinkLensRiskFeaturePolicy.isEnabled(.operationalCameraOverridesV10), RinkLensRiskFeaturePolicy.isEnabled(.builtInAutoClearsExactProfileV9) {
                                self.preferredVideoFormatIDByCameraID.removeValue(forKey: cameraID)
                                self.captureFormatPreferenceByCameraID.removeValue(forKey: cameraID)
                            }
                        }
                        if RinkLensRiskFeaturePolicy.isEnabled(.builtInAutoClearsExactProfileV9) {
                            self.cameraBreadcrumb(
                                .selection,
                                phase: "Build 719 built-in Auto cleared stale exact profile",
                                extra: "previousFormat=\(previousExactFormat) previousFPS=\(previousExactCadence) camera=\(cameraID ?? "none")"
                            )
                        }
                        if RinkLensRiskFeaturePolicy.isEnabled(.roleOwnedCameraDefaultsV10), self.roleDefaultProfileCaptureEnabled {
                            let autoFormat = self.roleDefaultFPS >= 60
                                ? self.preferredFormat1080p60(for: device)
                                : self.preferredFormat1080p30(for: device)
                            if let autoFormat {
                                device.activeFormat = autoFormat
                                _ = self.applySafeFrameDuration(self.roleDefaultFPS, to: device, selectedFormat: autoFormat)
                            }
                        }
                        if device.isFocusModeSupported(.continuousAutoFocus) {
                            device.focusMode = .continuousAutoFocus
                        }
                        if device.isExposureModeSupported(.continuousAutoExposure) {
                            device.exposureMode = .continuousAutoExposure
                        }
                        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                            device.whiteBalanceMode = .continuousAutoWhiteBalance
                        }
                        if device.isSmoothAutoFocusSupported {
                            device.isSmoothAutoFocusEnabled = true
                        }
                        // Recovery CZ: low-light boost and adaptive frame-rate
                        // policy are CaptureEngine-owned. The camera facade may
                        // request focus/exposure/white-balance behaviour, but it
                        // cannot mutate the Broadcast low-light imaging policy.
                    }
                    device.unlockForConfiguration()
                } catch {
                    DispatchQueue.main.async { self.cameraStatusText = "Auto quality update failed" }
                }
            }
            DispatchQueue.main.async {
                self.cameraStatusText = enabled ? "Automatic focus, exposure and white balance enabled" : "Manual lens controls enabled"
                self.whiteBalanceModeText = enabled ? "Auto White Balance" : self.whiteBalanceModeText
                self.refreshCameraSettingState()
            }

            if !enabled {
                self.refreshAvailableCameras(reason: "Automatic lens controls disabled")
                self.refreshVideoFormats(force: true, reason: "Automatic lens controls disabled")
            }
        }
    }

    func setMatchViewToRecordingEnabled(_ enabled: Bool) {
        if Thread.isMainThread {
            self.matchViewToRecordingEnabled = enabled
            self.cameraStatusText = enabled ? "Match view to recording on" : "Match view to recording off"
        } else {
            DispatchQueue.main.async {
                self.matchViewToRecordingEnabled = enabled
                self.cameraStatusText = enabled ? "Match view to recording on" : "Match view to recording off"
            }
        }
    }

    private func sampledLumaDescription(from pixelBuffer: CVPixelBuffer) -> String {
        guard CVPixelBufferIsPlanar(pixelBuffer) else {
            return "non-planar pixel buffer"
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pixelBuffer) > 0,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            return "luma plane unavailable"
        }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        guard width > 0, height > 0, bytesPerRow > 0 else { return "invalid luma plane" }

        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let samplesX = 12
        let samplesY = 8
        var total = 0
        var minimum = 255
        var maximum = 0
        var count = 0
        for yIndex in 0..<samplesY {
            let y = min(height - 1, max(0, (yIndex * height + height / (samplesY * 2)) / samplesY))
            for xIndex in 0..<samplesX {
                let x = min(width - 1, max(0, (xIndex * width + width / (samplesX * 2)) / samplesX))
                let value = Int(bytes[y * bytesPerRow + x])
                total += value
                minimum = min(minimum, value)
                maximum = max(maximum, value)
                count += 1
            }
        }
        guard count > 0 else { return "no luma samples" }
        let average = Double(total) / Double(count)
        return String(format: "avg=%.1f min=%d max=%d samples=%d", average, minimum, maximum, count)
    }
}

nonisolated extension HockeyCameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let frameDate = Date()
        guard let frame = RinkLensFrameHub.shared.publish(
            pixelBuffer: pixelBuffer,
            role: frameHubRole,
            capturedAt: frameDate,
            source: "HockeyCameraService AVCaptureVideoDataOutput",
            physicalDeviceID: effectiveCaptureDeviceForRecording()?.uniqueID,
            captureGeneration: 0
        ) else {
            cameraBreadcrumb(
                .frameDelivery,
                phase: "owned FrameHub pool saturated",
                extra: "role=\(frameHubRole.rawValue); newest application frame dropped without retaining AVFoundation buffer"
            )
            return
        }
        processFrameHubFrame(frame, connectionEnabled: connection.isEnabled)
    }

    fileprivate func processFrameHubFrame(
        _ frame: RinkLensFrameHubFrame,
        connectionEnabled: Bool
    ) {
        // Legacy self-owned capture genuinely receives image pixels, so retain
        // first-frame luminance sampling here. Runtime CaptureEngine-owned paths
        // use processFrameHubEvidence and never acquire this lease.
        if !firstFrameBreadcrumbRecorded {
            firstFrameBreadcrumbRecorded = true
            let luma = sampledLumaDescription(from: frame.pixelBuffer)
            DispatchQueue.main.async {
                self.lastFrameLumaText = luma
            }
            cameraBreadcrumb(
                .firstFrame,
                phase: "first pixel buffer",
                extra: "source=\(frame.source) size=\(frame.width)x\(frame.height) pixelFormat=0x\(String(frame.pixelFormat, radix: 16)) connectionEnabled=\(connectionEnabled) luma={\(luma)}"
            )
        }
        processFrameHubEvidence(frame.evidence, connectionEnabled: connectionEnabled)
    }

    private func processFrameHubEvidence(
        _ evidence: RinkLensFrameHubEvidence,
        connectionEnabled: Bool
    ) {
        let frameDate = evidence.capturedAt
        lastFrameReceivedForHealth = frameDate
        framesReceivedTotal += 1

        if !firstFrameBreadcrumbRecorded {
            firstFrameBreadcrumbRecorded = true
            DispatchQueue.main.async {
                self.lastFrameLumaText = "CaptureEngine-owned; see CaptureEngine first-frame luminance"
            }
            cameraBreadcrumb(
                .firstFrame,
                phase: "first frame evidence",
                extra: "source=\(evidence.source) size=\(evidence.width)x\(evidence.height) pixelFormat=0x\(String(evidence.pixelFormat, radix: 16)) connectionEnabled=\(connectionEnabled) recoveryAD=metadata-only"
            )
        }

        let now = CFAbsoluteTimeGetCurrent()
        if !hasPublishedFirstFrameToUI || now - lastHealthUIPublishAt >= healthUIPublishInterval {
            hasPublishedFirstFrameToUI = true
            lastHealthUIPublishAt = now
            DispatchQueue.main.async {
                self.hasReceivedFrames = true
                self.lastFrameReceivedAt = frameDate
                self.visibleCameraHealthy = true
                self.updateWhiteScreenDetector()
                MainThreadStallMonitor.shared.notePublish(source: "frame health")
            }
        }

        if now - lastFramePipelinePublishAt >= 5.0 {
            lastFramePipelinePublishAt = now
            let reason = sampleBufferOutputEnabled
                ? "authoritative FrameHub owns OCR/Image Relay delivery"
                : "preview-only camera; Broadcast consumers read FrameHub directly"
            let text = "received=\(framesReceivedTotal) reason=\(reason) hub=\(evidence.role.rawValue)#\(evidence.sequence) \(evidence.sizeText)"
            DispatchQueue.main.async {
                self.framePipelineText = text
                MainThreadStallMonitor.shared.notePublish(source: "frame pipeline")
            }
        }
    }
}

func currentInterfaceDeviceOrientation() -> UIDeviceOrientation {
    let windows = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)

    if let keyWindow = windows.first(where: \.isKeyWindow),
       let windowScene = keyWindow.windowScene {
        let interfaceOrientation: UIInterfaceOrientation?

        if #available(iOS 26.0, *) {
            interfaceOrientation = windowScene.effectiveGeometry.interfaceOrientation
        } else {
            interfaceOrientation = windowScene.interfaceOrientation
        }

        if let interfaceOrientation {
            switch interfaceOrientation {
            case .landscapeLeft:
                return .landscapeLeft
            case .landscapeRight:
                return .landscapeRight
            case .portraitUpsideDown:
                return .portraitUpsideDown
            case .portrait:
                return .portrait
            default:
                break
            }
        }
    }

    let deviceOrientation = UIDevice.current.orientation
    if deviceOrientation.isLandscape || deviceOrientation.isPortrait {
        return deviceOrientation
    }

    if let keyWindow = windows.first(where: \.isKeyWindow) {
        return keyWindow.bounds.width >= keyWindow.bounds.height ? .landscapeRight : .portrait
    }
    return .portrait
}


// MARK: - UX16c35 legacy preview removal

// Compatibility preview hosts were deleted in Stage 7. Broadcast and OCR Setup
// now mount only the preview endpoints owned by ExternalOCRMultiCamCoordinator.

#endif
