// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation
import Dispatch
import AVFoundation

// MARK: - UX16c38 latest-intent capture lifecycle control plane

nonisolated enum RinkLensBroadcastPreviewContinuityAdmission {
    /// A held raster is eligible only when its immutable evidence proves it was
    /// captured after the outgoing lens physically settled, by the exact graph
    /// generation and device that still own Broadcast immediately before the
    /// visible display pass.
    static func admits(
        evidence: RinkLensFrameHubEvidence,
        afterSequence: Int,
        afterUptimeNanoseconds: UInt64,
        requiredCaptureGeneration: Int,
        requiredPhysicalDeviceID: String,
        currentCaptureGeneration: Int,
        currentPhysicalDeviceID: String?
    ) -> Bool {
        evidence.role == .broadcast
            && evidence.sequence > afterSequence
            && evidence.capturedUptimeNanoseconds >= afterUptimeNanoseconds
            && evidence.captureGeneration == requiredCaptureGeneration
            && evidence.physicalDeviceID == requiredPhysicalDeviceID
            && currentCaptureGeneration == requiredCaptureGeneration
            && currentPhysicalDeviceID == requiredPhysicalDeviceID
    }
}

/// Operator/application intent for the single process-wide capture engine.
/// These modes no longer select between separate AVCaptureSession owners.

/// Exact rational frame cadence used by CaptureEngine. Storing the frame duration
/// rather than a rounded integer preserves NTSC rates such as 29.97 and 59.94.
nonisolated struct RinkLensCaptureCadence: Sendable, Equatable, Hashable {
    let durationValue: Int64
    let durationTimescale: Int32

    init(durationValue: Int64, durationTimescale: Int32) {
        let safeValue = max(1, durationValue)
        let safeTimescale = max(1, durationTimescale)
        let divisor = Self.greatestCommonDivisor(safeValue, Int64(safeTimescale))
        self.durationValue = safeValue / divisor
        self.durationTimescale = Int32(Int64(safeTimescale) / divisor)
    }

    init(duration: CMTime) {
        self.init(
            durationValue: duration.isValid && duration.value > 0 ? duration.value : 1,
            durationTimescale: duration.isValid && duration.timescale > 0 ? duration.timescale : 30
        )
    }

    init(integerFPS: Int) {
        self.init(durationValue: 1, durationTimescale: Int32(max(1, integerFPS)))
    }

    init(frameRate: Double) {
        if abs(frameRate - 23.976) < 0.02 || abs(frameRate - (24_000.0 / 1_001.0)) < 0.02 {
            self.init(durationValue: 1_001, durationTimescale: 24_000)
        } else if abs(frameRate - 29.97) < 0.02 || abs(frameRate - (30_000.0 / 1_001.0)) < 0.02 {
            self.init(durationValue: 1_001, durationTimescale: 30_000)
        } else if abs(frameRate - 59.94) < 0.03 || abs(frameRate - (60_000.0 / 1_001.0)) < 0.03 {
            self.init(durationValue: 1_001, durationTimescale: 60_000)
        } else if abs(frameRate.rounded() - frameRate) < 0.0005 {
            self.init(integerFPS: Int(frameRate.rounded()))
        } else {
            let timescale: Int32 = 1_000_000
            let value = Int64(max(1, (Double(timescale) / max(0.001, frameRate)).rounded()))
            self.init(durationValue: value, durationTimescale: timescale)
        }
    }

    var duration: CMTime {
        CMTime(value: durationValue, timescale: durationTimescale)
    }

    var framesPerSecond: Double {
        Double(durationTimescale) / Double(durationValue)
    }

    var nominalFPS: Int { max(1, Int(framesPerSecond.rounded())) }

    var displayText: String {
        if durationValue == 1_001 && durationTimescale == 24_000 { return "23.976" }
        if durationValue == 1_001 && durationTimescale == 30_000 { return "29.97" }
        if durationValue == 1_001 && durationTimescale == 60_000 { return "59.94" }
        let value = framesPerSecond
        if abs(value.rounded() - value) < 0.0005 {
            return "\(Int(value.rounded()))"
        }
        let decimals = abs(value * 100 - (value * 100).rounded()) < 0.005 ? 2 : 3
        return String(format: "%.*f", decimals, value)
    }

    var idComponent: String { "\(durationValue)-\(durationTimescale)" }

    var isCommonRate: Bool {
        Self.commonRates.contains(self)
    }

    static let commonRates: [RinkLensCaptureCadence] = [
        .init(integerFPS: 15),
        .init(durationValue: 1_001, durationTimescale: 24_000),
        .init(integerFPS: 24),
        .init(integerFPS: 25),
        .init(durationValue: 1_001, durationTimescale: 30_000),
        .init(integerFPS: 30),
        .init(integerFPS: 50),
        .init(durationValue: 1_001, durationTimescale: 60_000),
        .init(integerFPS: 60),
        .init(integerFPS: 120)
    ]

    private static func greatestCommonDivisor(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        var a = abs(lhs)
        var b = abs(rhs)
        while b != 0 {
            let remainder = a % b
            a = b
            b = remainder
        }
        return max(1, a)
    }
}

/// Exact CaptureEngine format requested by the operator. Resolution and cadence
/// are kept separate from AVCaptureDevice.Format identity so a freshly reconnected
/// camera can resolve the same visible mode against its new device instance.
nonisolated struct RinkLensCaptureFormatPreference: Sendable, Equatable, Hashable {
    let width: Int32
    let height: Int32
    let cadence: RinkLensCaptureCadence

    init(width: Int32, height: Int32, cadence: RinkLensCaptureCadence) {
        self.width = width
        self.height = height
        self.cadence = cadence
    }

    init(width: Int32, height: Int32, fps: Int) {
        self.init(width: width, height: height, cadence: .init(integerFPS: fps))
    }

    var fps: Double { cadence.framesPerSecond }
    var nominalFPS: Int { cadence.nominalFPS }
    var diagnosticText: String { "\(width)x\(height) @ \(cadence.displayText)fps" }
}

nonisolated enum RinkLensCaptureLifecycleMode: String, Sendable, Equatable {
    case stopped
    case dualCamera
    case broadcastOnly
    case ocrOnly

    var requiresBroadcast: Bool {
        self == .dualCamera || self == .broadcastOnly
    }

    var requiresOCR: Bool {
        self == .dualCamera || self == .ocrOnly
    }
}


// MARK: - UX16d2 presentation-only route policy

/// Route presentation is not camera lifecycle. This small value contract lets
/// the UI ask which operational contract should be ensured without ever issuing
/// a route-driven stop. Explicit operator stop, app background, interruption and
/// fatal-error paths remain the only capture teardown boundaries.
nonisolated enum RinkLensCapturePresentationRoute: String, Sendable, Equatable {
    case commandCentre
    case broadcast
    case ocrSetup
    case recording
    case nonCamera
}

nonisolated struct RinkLensCapturePresentationContext: Sendable, Equatable {
    let route: RinkLensCapturePresentationRoute
    let captureIsActive: Bool
    let captureIsTransitioning: Bool
    let activeMode: RinkLensCaptureLifecycleMode
    let recordingSessionOpen: Bool
    let wantsScoreboardCameraGraph: Bool
    let hasBroadcastSelection: Bool
    let hasOCRSelection: Bool
}

nonisolated enum RinkLensCapturePresentationAction: Sendable, Equatable {
    case preserveCurrent
    case ensure(RinkLensCaptureLifecycleMode)
}

nonisolated enum RinkLensCapturePresentationPolicy {
    static func action(
        for context: RinkLensCapturePresentationContext
    ) -> RinkLensCapturePresentationAction {
        let canOwnStableDualGraph = context.wantsScoreboardCameraGraph
            && context.hasBroadcastSelection
            && context.hasOCRSelection

        switch context.route {
        case .commandCentre:
            // Recovery AP / RL-092: Command Centre is a configuration/thermal-idle
            // presentation boundary. It may preserve a graph that an operational
            // route already started, but it can never create the live match graph.
            return .preserveCurrent

        case .broadcast, .recording:
            // Operational video routes may establish the match-session graph.
            if context.recordingSessionOpen { return .preserveCurrent }
            guard context.hasBroadcastSelection else { return .preserveCurrent }
            if canOwnStableDualGraph {
                if (context.captureIsActive || context.captureIsTransitioning),
                   context.activeMode == .dualCamera {
                    return .preserveCurrent
                }
                return .ensure(.dualCamera)
            }
            if (context.captureIsActive || context.captureIsTransitioning),
               context.activeMode == .broadcastOnly {
                return .preserveCurrent
            }
            return .ensure(.broadcastOnly)

        case .ocrSetup:
            // With both selected cameras, OCR Setup mounts the OCR preview on the
            // same match-session dual graph instead of downgrading to OCR-only and
            // forcing another rebuild when Broadcast is selected next.
            if canOwnStableDualGraph {
                if (context.captureIsActive || context.captureIsTransitioning),
                   context.activeMode == .dualCamera {
                    return .preserveCurrent
                }
                return .ensure(.dualCamera)
            }
            guard context.hasOCRSelection else { return .preserveCurrent }
            if (context.captureIsActive || context.captureIsTransitioning),
               context.activeMode == .ocrOnly {
                return .preserveCurrent
            }
            return .ensure(.ocrOnly)

        case .nonCamera:
            return .preserveCurrent
        }
    }
}

/// Stable operator intent owned exclusively by CaptureLifecycleController.
/// Logical source identity is distinct from the preferred physical device and
/// from the effective physical constituent selected by CaptureEngine.
nonisolated struct RinkLensDesiredCaptureContract: Sendable, Equatable {
    let mode: RinkLensCaptureLifecycleMode
    let liveLogicalSourceID: String?
    let ocrLogicalSourceID: String?
    let livePreferredDeviceID: String?
    let ocrPreferredDeviceID: String?
    let liveFormat: RinkLensCaptureFormatPreference?
    let ocrFormat: RinkLensCaptureFormatPreference?

    var diagnosticText: String {
        "mode=\(mode.rawValue) liveLogical=\(liveLogicalSourceID ?? "none") livePreferred=\(livePreferredDeviceID ?? "none") ocrLogical=\(ocrLogicalSourceID ?? "none") ocrPreferred=\(ocrPreferredDeviceID ?? "none") liveFormat=\(liveFormat?.diagnosticText ?? "auto") ocrFormat=\(ocrFormat?.diagnosticText ?? "auto")"
    }
}

/// Effective graph contract returned by CaptureEngine after Apple resolves the
/// supported physical device set. A logical rear source may therefore be active
/// through a constituent wide camera rather than its virtual-device identifier.
nonisolated struct RinkLensEffectiveCaptureContract: Sendable, Equatable {
    let desired: RinkLensDesiredCaptureContract
    let liveActiveDeviceID: String?
    let ocrActiveDeviceID: String?
    let liveFormat: RinkLensCaptureFormatPreference?
    let ocrFormat: RinkLensCaptureFormatPreference?

    var diagnosticText: String {
        "desired={\(desired.diagnosticText)} effectiveLive=\(liveActiveDeviceID ?? "none") effectiveOCR=\(ocrActiveDeviceID ?? "none") effectiveFormats=\(liveFormat?.diagnosticText ?? "none")/\(ocrFormat?.diagnosticText ?? "none")"
    }
}



// MARK: - UX16c45 recording capture lease

/// Explicit exceptions which may release the camera graph while a recording
/// lease is active. Ordinary route, preview and health assertions have no
/// override and therefore cannot remove the Broadcast branch.
nonisolated enum RinkLensRecordingLeaseOverride: String, Sendable, Equatable {
    case none
    case operatorStop
    case appBackground
    case avFoundationInterruption
    case fatalRuntimeError
}

nonisolated struct RinkLensRecordingCaptureLeaseSnapshot: Sendable, Equatable {
    let token: UUID?
    let acquiredAt: Date?
    let desiredContract: RinkLensDesiredCaptureContract?
    let effectiveContract: RinkLensEffectiveCaptureContract?
    let captureGeneration: Int
    let broadcastDeviceID: String?
    let sourceMaximumAge: TimeInterval
    let sourceLossTimeout: TimeInterval
    let reason: String

    var isActive: Bool { token != nil }

    var diagnosticText: String {
        guard isActive else { return "inactive" }
        let tokenText = token.map { String($0.uuidString.prefix(8)) } ?? "none"
        return "active token=\(tokenText) generation=\(captureGeneration) broadcastDevice=\(broadcastDeviceID ?? "none") maxAge=\(String(format: "%.2f", sourceMaximumAge))s lossTimeout=\(String(format: "%.2f", sourceLossTimeout))s desired={\(desiredContract?.diagnosticText ?? "none")} effective={\(effectiveContract?.diagnosticText ?? "none")} reason=\(reason)"
    }

    static let inactive = Self(
        token: nil,
        acquiredAt: nil,
        desiredContract: nil,
        effectiveContract: nil,
        captureGeneration: 0,
        broadcastDeviceID: nil,
        sourceMaximumAge: 0.35,
        sourceLossTimeout: 0.75,
        reason: "none"
    )
}

/// Process-wide lease held by the recording writer. Ordinary lifecycle requests
/// cannot mutate the Broadcast branch while the file is open. Recovery B permits
/// only the explicit CaptureLifecycleController lens transaction, which first
/// holds the writer and releases this lease, then rebinds the same file to the
/// physically verified replacement generation.
nonisolated final class RinkLensRecordingCaptureLease: @unchecked Sendable {
    static let shared = RinkLensRecordingCaptureLease()

    private let lock = NSLock()
    private var value = RinkLensRecordingCaptureLeaseSnapshot.inactive
    private var blockedRequestCount = 0
    private var lastBlockedRequest = "none"

    // UX16d2: recording activity and camera-mutation policy now live beside the
    // authoritative Broadcast capture lease. This replaces the separate
    // former standalone mutation-gate singleton and prevents two recording/capture
    // protection sources from drifting apart.
    private var recordingActive = false
    // Build 738: a controlled projection of the authoritative RecordingEngine
    // writer lifetime. It protects camera hardware mutation while the same file
    // remains open, but it is not a second recording state and never controls UI.
    private var writerContractOpen = false
    private var writerSourceContract = "none"
    private var protectionModeActive = false
    private var blockedMutationCount = 0
    private var lastBlockedMutation = "none"
    private var lastMutationLogByKey: [String: Date] = [:]
    private let duplicateMutationLogInterval: TimeInterval = 0.75

    private init() {}

    func setRecordingActive(_ active: Bool, reason: String) {
        lock.lock()
        let changed = recordingActive != active
        let wasProtected = protectionModeActive
        recordingActive = active
        if !active {
            protectionModeActive = false
            blockedMutationCount = 0
            lastBlockedMutation = "none"
        }
        lock.unlock()

        if changed {
            logMutation("recording capture policy active=\(active): \(reason)", key: "recording-\(active)")
        }
        if wasProtected, !active {
            logMutation("recording capture protection exited: \(reason)", key: "protection-exited")
        }
    }

    func isRecordingActive() -> Bool {
        lock.lock()
        let active = recordingActive || value.isActive
        lock.unlock()
        return active
    }

    func setWriterContractOpen(_ open: Bool, sourceContract: String, reason: String) {
        lock.lock()
        let previousOpen = writerContractOpen
        let previousContract = writerSourceContract
        let normalizedContract = open ? sourceContract : "none"
        let changed = previousOpen != open || previousContract != normalizedContract
        writerContractOpen = open
        writerSourceContract = normalizedContract
        lock.unlock()
        guard changed else { return }

        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: open ? "recording_writer_contract_opened" : "recording_writer_contract_closed",
            entityID: "broadcast-writer-source-contract",
            previous: [
                "open": String(previousOpen),
                "sourceContract": previousContract
            ],
            next: [
                "open": String(open),
                "sourceContract": normalizedContract
            ],
            source: "BroadcastRecordingManager",
            reason: reason,
            authoritativeOwner: "RinkLensRecordingCaptureLease"
        )
        logMutation(
            "recording writer contract open=\(open) source=\(normalizedContract): \(reason)",
            key: "writer-contract-\(open)-\(normalizedContract)"
        )
        // Recovery B: the capture-lease release can replay while the writer is
        // still open. Re-read the authoritative camera-control intent once the
        // writer actually closes; no duplicate pending-quality state is stored.
        if previousOpen && !open {
            Task { @MainActor in
                RinkLensRecordingLeaseReplayHub.shared.notifyLeaseReleased(
                    reason: "writer contract closed: \(reason)"
                )
            }
        }
    }

    func isWriterContractOpen() -> Bool {
        lock.lock()
        let open = writerContractOpen
        lock.unlock()
        return open
    }

    func writerContractDiagnostic() -> String {
        lock.lock()
        let text = "open=\(writerContractOpen) source=\(writerSourceContract)"
        lock.unlock()
        return text
    }

    /// The open writer contract protects ordinary camera mutations for the file.
    /// It is not a second desired capture contract. Recovery B's explicit lens
    /// transaction temporarily holds RecordingWriter, releases the capture lease,
    /// replaces only the Broadcast branch, then rebinds the same writer/file.
    func isProtectionModeActive() -> Bool {
        lock.lock()
        let active = protectionModeActive
        lock.unlock()
        return active
    }

    func blockedMutationCountValue() -> Int {
        lock.lock()
        let count = blockedMutationCount
        lock.unlock()
        return count
    }

    func lastBlockedMutationDiagnostic() -> String {
        lock.lock()
        let diagnostic = lastBlockedMutation
        lock.unlock()
        return diagnostic
    }

    /// Returns whether a requested camera mutation may execute while recording.
    /// Capture lifecycle requests still pass through `allows(_:)`, which checks
    /// the exact leased contract. This method protects remaining compatibility
    /// controls and passive preview adapters until they are removed in later stages.
    func allowMutation(
        action: String,
        requester: String,
        owner: String,
        recordingSafe: Bool = false
    ) -> Bool {
        lock.lock()
        let writerProtected = writerContractOpen
        let active = recordingActive || value.isActive || writerProtected
        if active && !recordingSafe {
            protectionModeActive = true
            blockedMutationCount &+= 1
            lastBlockedMutation = "action=\(action) requester=\(requester) owner=\(owner)"
        }
        lock.unlock()

        guard active && !recordingSafe else { return true }
        logMutation(
            "recording capture mutation blocked action=\(action) requester=\(requester) owner=\(owner)",
            key: "block-\(action)-\(requester)-\(owner)"
        )
        return false
    }

    func notePassiveIssue(_ text: String, key: String) {
        logMutation(text, key: key)
    }

    private func logMutation(_ text: String, key: String) {
        let now = Date()
        lock.lock()
        let last = lastMutationLogByKey[key]
        if let last, now.timeIntervalSince(last) < duplicateMutationLogInterval {
            lock.unlock()
            return
        }
        lastMutationLogByKey[key] = now
        lock.unlock()

        Task { @MainActor in
            MainThreadStallMonitor.shared.trace(text)
        }
    }

    @discardableResult
    func acquire(
        desiredContract: RinkLensDesiredCaptureContract,
        effectiveContract: RinkLensEffectiveCaptureContract?,
        captureGeneration: Int,
        broadcastDeviceID: String?,
        sourceMaximumAge: TimeInterval = 0.35,
        sourceLossTimeout: TimeInterval = 0.75,
        reason: String
    ) -> UUID? {
        guard desiredContract.mode.requiresBroadcast, broadcastDeviceID != nil else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard value.token == nil else { return nil }
        let token = UUID()
        value = .init(
            token: token,
            acquiredAt: Date(),
            desiredContract: desiredContract,
            effectiveContract: effectiveContract,
            captureGeneration: captureGeneration,
            broadcastDeviceID: broadcastDeviceID,
            sourceMaximumAge: sourceMaximumAge,
            sourceLossTimeout: sourceLossTimeout,
            reason: reason
        )
        blockedRequestCount = 0
        lastBlockedRequest = "none"
        return token
    }

    func release(token: UUID?, reason: String, replayRouteAfterRelease: Bool = true) {
        lock.lock()
        guard value.token != nil, token == nil || value.token == token else {
            lock.unlock()
            return
        }
        value = .inactive
        lock.unlock()
        Task { @MainActor in
            MainThreadStallMonitor.shared.trace("UX16c53 recording capture lease released: \(reason)")
            if replayRouteAfterRelease {
                RinkLensRecordingLeaseReplayHub.shared.notifyLeaseReleased(reason: reason)
            } else {
                MainThreadStallMonitor.shared.trace(
                    "Build 771 controlled camera transaction retained lifecycle intent; route replay not requested"
                )
            }
        }
    }

    func snapshot() -> RinkLensRecordingCaptureLeaseSnapshot {
        lock.lock()
        let snapshot = value
        lock.unlock()
        return snapshot
    }

    func noteBlocked(_ request: RinkLensCaptureLifecycleRequest) {
        lock.lock()
        blockedRequestCount &+= 1
        lastBlockedRequest = "mode=\(request.mode.rawValue) reason=\(request.reason)"
        lock.unlock()
    }

    func diagnostics() -> (count: Int, last: String) {
        lock.lock()
        let result = (blockedRequestCount, lastBlockedRequest)
        lock.unlock()
        return result
    }

    /// Returns true only when the request is harmless to the leased Broadcast
    /// graph. All explicit teardown overrides are allowed. Ordinary requests may
    /// proceed only when they preserve the exact leased desired contract.
    func allows(_ request: RinkLensCaptureLifecycleRequest) -> Bool {
        if request.recordingLeaseOverride != .none { return true }
        lock.lock()
        let leaseDesired = value.isActive ? value.desiredContract : nil
        let writerProtectedWithoutLease = writerContractOpen && !value.isActive
        lock.unlock()
        if writerProtectedWithoutLease { return false }
        guard let desired = leaseDesired else { return true }
        let requestDesired = RinkLensDesiredCaptureContract(
            mode: request.mode,
            liveLogicalSourceID: request.mode.requiresBroadcast ? request.liveLogicalSourceID : nil,
            ocrLogicalSourceID: request.mode.requiresOCR ? request.ocrLogicalSourceID : nil,
            livePreferredDeviceID: request.mode.requiresBroadcast ? request.liveDeviceID : nil,
            ocrPreferredDeviceID: request.mode.requiresOCR ? request.ocrDeviceID : nil,
            liveFormat: request.mode.requiresBroadcast ? request.liveFormat : nil,
            ocrFormat: request.mode.requiresOCR ? request.ocrFormat : nil
        )
        return preservesWriterBroadcastContract(candidate: requestDesired, frozen: desired)
    }

    private func preservesWriterBroadcastContract(
        candidate: RinkLensDesiredCaptureContract,
        frozen: RinkLensDesiredCaptureContract
    ) -> Bool {
        // R18: RecordingWriter owns the output contract, not one physical rear
        // camera forever. A Wide <-> Ultra-Wide branch migration is harmless to
        // the open writer when the logical Broadcast role, dimensions and cadence
        // remain unchanged. CaptureLifecycleController still owns the physical
        // branch transaction and RecordingEngine rebinds its capacity-one source.
        candidate.mode.requiresBroadcast
            && frozen.mode.requiresBroadcast
            && candidate.liveLogicalSourceID == frozen.liveLogicalSourceID
            && candidate.liveFormat == frozen.liveFormat
    }
}

/// Programme streaming owns no AVCaptureSession, but while requested it is an
/// authoritative Broadcast capture consumer. Scoreboard-input transitions may
/// suspend OCR processing; they must not infer permission to stop the Broadcast
/// graph underneath the live programme publisher.
nonisolated final class RinkLensProgrammeStreamCaptureRequirement: @unchecked Sendable {
    static let shared = RinkLensProgrammeStreamCaptureRequirement()

    private let lock = NSLock()
    private var requested = false

    private init() {}

    func setRequested(_ value: Bool) {
        lock.lock()
        requested = value
        lock.unlock()
    }

    func isRequested() -> Bool {
        lock.lock()
        let value = requested
        lock.unlock()
        return value
    }
}

@MainActor
final class RinkLensRecordingLeaseReplayHub {
    static let shared = RinkLensRecordingLeaseReplayHub()
    private var handler: ((String) -> Void)?

    private init() {}

    func install(_ handler: @escaping (String) -> Void) {
        self.handler = handler
    }

    func notifyLeaseReleased(reason: String) {
        handler?(reason)
    }
}

nonisolated struct RinkLensCaptureLifecycleRequest: Sendable, Equatable {
    var mode: RinkLensCaptureLifecycleMode
    var liveLogicalSourceID: String? = nil
    var ocrLogicalSourceID: String? = nil
    var liveDeviceID: String?
    var ocrDeviceID: String?
    var liveFormat: RinkLensCaptureFormatPreference?
    var ocrFormat: RinkLensCaptureFormatPreference?
    var allowBroadcastFallback: Bool
    var recordingLeaseOverride: RinkLensRecordingLeaseOverride = .none
    var reason: String

    static func dualCamera(
        liveLogicalSourceID: String? = nil,
        ocrLogicalSourceID: String? = nil,
        liveDeviceID: String?,
        ocrDeviceID: String?,
        liveFormat: RinkLensCaptureFormatPreference? = nil,
        ocrFormat: RinkLensCaptureFormatPreference? = nil,
        allowBroadcastFallback: Bool = true,
        recordingLeaseOverride: RinkLensRecordingLeaseOverride = .none,
        reason: String
    ) -> Self {
        .init(
            mode: .dualCamera,
            liveLogicalSourceID: liveLogicalSourceID,
            ocrLogicalSourceID: ocrLogicalSourceID,
            liveDeviceID: liveDeviceID,
            ocrDeviceID: ocrDeviceID,
            liveFormat: liveFormat,
            ocrFormat: ocrFormat,
            allowBroadcastFallback: allowBroadcastFallback,
            recordingLeaseOverride: recordingLeaseOverride,
            reason: reason
        )
    }

    static func broadcastOnly(
        liveLogicalSourceID: String? = nil,
        liveDeviceID: String? = nil,
        liveFormat: RinkLensCaptureFormatPreference? = nil,
        recordingLeaseOverride: RinkLensRecordingLeaseOverride = .none,
        reason: String
    ) -> Self {
        .init(
            mode: .broadcastOnly,
            liveLogicalSourceID: liveLogicalSourceID,
            ocrLogicalSourceID: nil,
            liveDeviceID: liveDeviceID,
            ocrDeviceID: nil,
            liveFormat: liveFormat,
            ocrFormat: nil,
            allowBroadcastFallback: false,
            recordingLeaseOverride: recordingLeaseOverride,
            reason: reason
        )
    }

    static func ocrOnly(
        ocrLogicalSourceID: String? = nil,
        ocrDeviceID: String? = nil,
        ocrFormat: RinkLensCaptureFormatPreference? = nil,
        recordingLeaseOverride: RinkLensRecordingLeaseOverride = .none,
        reason: String
    ) -> Self {
        .init(
            mode: .ocrOnly,
            liveLogicalSourceID: nil,
            ocrLogicalSourceID: ocrLogicalSourceID,
            liveDeviceID: nil,
            ocrDeviceID: ocrDeviceID,
            liveFormat: nil,
            ocrFormat: ocrFormat,
            allowBroadcastFallback: false,
            recordingLeaseOverride: recordingLeaseOverride,
            reason: reason
        )
    }

    static func stopped(
        reason: String,
        recordingLeaseOverride: RinkLensRecordingLeaseOverride = .none
    ) -> Self {
        .init(
            mode: .stopped,
            liveLogicalSourceID: nil,
            ocrLogicalSourceID: nil,
            liveDeviceID: nil,
            ocrDeviceID: nil,
            liveFormat: nil,
            ocrFormat: nil,
            allowBroadcastFallback: false,
            recordingLeaseOverride: recordingLeaseOverride,
            reason: reason
        )
    }
}


/// Stable identity for one requested camera graph. Reasons and UI metadata are
/// deliberately excluded so recurring route assertions compare the actual
/// camera/format contract rather than the caller that requested it.
nonisolated struct RinkLensCaptureContractKey: Sendable, Equatable {
    let mode: RinkLensCaptureLifecycleMode
    let liveDeviceID: String?
    let ocrDeviceID: String?
    let liveFormat: RinkLensCaptureFormatPreference?
    let ocrFormat: RinkLensCaptureFormatPreference?

    init(
        mode: RinkLensCaptureLifecycleMode,
        liveDeviceID: String?,
        ocrDeviceID: String?,
        liveFormat: RinkLensCaptureFormatPreference?,
        ocrFormat: RinkLensCaptureFormatPreference?
    ) {
        self.mode = mode
        self.liveDeviceID = mode.requiresBroadcast ? liveDeviceID : nil
        self.ocrDeviceID = mode.requiresOCR ? ocrDeviceID : nil
        self.liveFormat = mode.requiresBroadcast ? liveFormat : nil
        self.ocrFormat = mode.requiresOCR ? ocrFormat : nil
    }

    init(request: RinkLensCaptureLifecycleRequest) {
        self.init(
            mode: request.mode,
            liveDeviceID: request.liveDeviceID,
            ocrDeviceID: request.ocrDeviceID,
            liveFormat: request.liveFormat,
            ocrFormat: request.ocrFormat
        )
    }

    var diagnosticText: String {
        "mode=\(mode.rawValue) live=\(liveDeviceID ?? "none") ocr=\(ocrDeviceID ?? "none") liveFormat=\(liveFormat?.diagnosticText ?? "auto") ocrFormat=\(ocrFormat?.diagnosticText ?? "auto")"
    }

    func request(
        allowBroadcastFallback: Bool,
        reason: String
    ) -> RinkLensCaptureLifecycleRequest {
        RinkLensCaptureLifecycleRequest(
            mode: mode,
            liveDeviceID: liveDeviceID,
            ocrDeviceID: ocrDeviceID,
            liveFormat: liveFormat,
            ocrFormat: ocrFormat,
            allowBroadcastFallback: allowBroadcastFallback,
            recordingLeaseOverride: .none,
            reason: reason
        )
    }
}

/// Persistent in-memory record of a failed contract that has been safely
/// degraded to a fallback graph. It survives successful Broadcast-only startup
/// so ordinary route assertions cannot immediately retry and destabilise video.
nonisolated struct RinkLensCaptureDegradedRecord: Sendable, Equatable {
    let failedContract: RinkLensCaptureContractKey
    let fallbackMode: RinkLensCaptureLifecycleMode
    let failureText: String
    let recordedAt: Date
    let cooldownUntilUptimeNanoseconds: UInt64
    let failureCount: Int

    var cooldownRemainingSeconds: TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        guard cooldownUntilUptimeNanoseconds > now else { return 0 }
        return Double(cooldownUntilUptimeNanoseconds - now) / 1_000_000_000
    }

    var isCooldownActive: Bool { cooldownRemainingSeconds > 0 }

    var diagnosticText: String {
        "failed={\(failedContract.diagnosticText)} fallback=\(fallbackMode.rawValue) failures=\(failureCount) cooldown=\(String(format: "%.1f", cooldownRemainingSeconds))s error=\(failureText)"
    }
}


nonisolated struct RinkLensCaptureReconfigurationPlan: Sendable, Equatable {
    var request: RinkLensCaptureLifecycleRequest?
    var stagedSuccessfully: Bool
    var failureStatus: String?

    static func staged(_ request: RinkLensCaptureLifecycleRequest?) -> Self {
        .init(request: request, stagedSuccessfully: true, failureStatus: nil)
    }

    static func failed(
        resume request: RinkLensCaptureLifecycleRequest?,
        status: String
    ) -> Self {
        .init(request: request, stagedSuccessfully: false, failureStatus: status)
    }
}

// MARK: - UX16c41 graph mutation classification and audit

nonisolated enum RinkLensCaptureGraphMutationPath: String, Sendable, Equatable {
    case liveDeviceControl = "live-device-control"
    case liveCadence = "live-cadence"
    case noGraphChange = "no-graph-change"
    case fullGraphRebuild = "full-graph-rebuild"
}

nonisolated struct RinkLensCaptureGraphMutationAuditSnapshot: Sendable, Equatable {
    var liveDeviceControlCount: Int
    var liveCadenceCount: Int
    var noGraphChangeCount: Int
    var fullGraphRebuildCount: Int
    var lastMutationText: String

    static let idle = Self(
        liveDeviceControlCount: 0,
        liveCadenceCount: 0,
        noGraphChangeCount: 0,
        fullGraphRebuildCount: 0,
        lastMutationText: "No graph mutation recorded"
    )
}

/// Process-wide, lock-protected evidence that operator controls used the least
/// disruptive path. This deliberately stores values only; AVFoundation objects
/// remain confined to CaptureEngine/service queues.
nonisolated final class RinkLensCaptureGraphMutationAudit: @unchecked Sendable {
    static let shared = RinkLensCaptureGraphMutationAudit()

    private let lock = NSLock()
    private var value = RinkLensCaptureGraphMutationAuditSnapshot.idle

    private init() {}

    func record(_ path: RinkLensCaptureGraphMutationPath, detail: String) {
        lock.lock()
        switch path {
        case .liveDeviceControl: value.liveDeviceControlCount &+= 1
        case .liveCadence: value.liveCadenceCount &+= 1
        case .noGraphChange: value.noGraphChangeCount &+= 1
        case .fullGraphRebuild: value.fullGraphRebuildCount &+= 1
        }
        value.lastMutationText = "\(path.rawValue): \(detail)"
        lock.unlock()
        let traceText = "UX16c41 graph mutation \(path.rawValue): \(detail)"
        Task { @MainActor in
            MainThreadStallMonitor.shared.trace(traceText)
        }
    }

    func snapshot() -> RinkLensCaptureGraphMutationAuditSnapshot {
        lock.lock()
        let snapshot = value
        lock.unlock()
        return snapshot
    }
}

nonisolated enum RinkLensCaptureReconfigurationDecision: Sendable, Equatable {
    case noGraphChange
    case liveCadence
    case fullGraphRebuild(String)
}

/// Only a cadence change on the same running mode, devices and resolutions is
/// eligible for live graph mutation. Source, mode and resolution changes remain
/// full stop-reconfigure-resume transactions. A nil requested format means
/// "retain the active automatic format" and does not itself force a rebuild.
nonisolated enum RinkLensCaptureGraphMutationPolicy {
    static func decision(
        active: RinkLensCaptureEngineSnapshot,
        requested: RinkLensCaptureLifecycleRequest
    ) -> RinkLensCaptureReconfigurationDecision {
        guard active.isActive, active.sessionRunning, !active.isTransitioning else {
            return .fullGraphRebuild("capture graph is not stably running")
        }
        guard active.activeMode == requested.mode else {
            return .fullGraphRebuild("capture mode changed")
        }
        if requested.mode.requiresBroadcast {
            let desiredMatches = active.effectiveContract?.desired.livePreferredDeviceID == requested.liveDeviceID
                && active.effectiveContract?.desired.liveLogicalSourceID == requested.liveLogicalSourceID
            if active.liveDeviceID != requested.liveDeviceID && !desiredMatches {
                return .fullGraphRebuild("Broadcast camera changed")
            }
        }
        if requested.mode.requiresOCR {
            let desiredMatches = active.effectiveContract?.desired.ocrPreferredDeviceID == requested.ocrDeviceID
                && active.effectiveContract?.desired.ocrLogicalSourceID == requested.ocrLogicalSourceID
            if active.ocrDeviceID != requested.ocrDeviceID && !desiredMatches {
                return .fullGraphRebuild("OCR camera changed")
            }
        }

        var cadenceChanged = false
        if requested.mode.requiresBroadcast, let requestedFormat = requested.liveFormat {
            guard let activeFormat = active.liveFormat else {
                return .fullGraphRebuild("Broadcast active format is unavailable")
            }
            guard activeFormat.width == requestedFormat.width,
                  activeFormat.height == requestedFormat.height else {
                return .fullGraphRebuild("Broadcast resolution changed")
            }
            cadenceChanged = cadenceChanged || activeFormat.cadence != requestedFormat.cadence
        }
        if requested.mode.requiresOCR, let requestedFormat = requested.ocrFormat {
            guard let activeFormat = active.ocrFormat else {
                return .fullGraphRebuild("OCR active format is unavailable")
            }
            guard activeFormat.width == requestedFormat.width,
                  activeFormat.height == requestedFormat.height else {
                return .fullGraphRebuild("OCR resolution changed")
            }
            cadenceChanged = cadenceChanged || activeFormat.cadence != requestedFormat.cadence
        }
        return cadenceChanged ? .liveCadence : .noGraphChange
    }
}

nonisolated struct RinkLensCaptureLifecycleOutcome: Sendable, Equatable {
    var requestedMode: RinkLensCaptureLifecycleMode
    var resolvedMode: RinkLensCaptureLifecycleMode
    var succeeded: Bool
    var changedOwnership: Bool
    var usedFallback: Bool
    var selectionRolledBack: Bool
    var wasSuperseded: Bool
    var statusText: String
    var liveZoom: Double?
    var ocrZoom: Double?

    static func blocked(_ request: RinkLensCaptureLifecycleRequest, status: String) -> Self {
        .init(
            requestedMode: request.mode,
            resolvedMode: .stopped,
            succeeded: false,
            changedOwnership: false,
            usedFallback: false,
            selectionRolledBack: false,
            wasSuperseded: false,
            statusText: status,
            liveZoom: nil,
            ocrZoom: nil
        )
    }
}

/// Main-actor command serializer for the single queue-confined capture engine.
///
/// Stage 7 removes all lifecycle calls into the two compatibility
/// `HockeyCameraService` instances. Those objects remain as camera-selection,
/// settings, diagnostics and frame-consumer facades only. Every start, stop,
/// reconfiguration, wake recovery and degraded-mode decision is executed by
/// `ExternalOCRMultiCamCoordinator`.
/// UX16d2c resolves recording-lease release from current intent only. Deferred
/// intent is retained for diagnostics/rollback evidence but can never win.
nonisolated enum RinkLensRecordingLeaseReleasePolicy {
    static func resolvedRequest(
        currentRouteRequest: RinkLensCaptureLifecycleRequest,
        discardedDeferredRequest: RinkLensCaptureLifecycleRequest?
    ) -> RinkLensCaptureLifecycleRequest {
        _ = discardedDeferredRequest
        return currentRouteRequest
    }
}

// MARK: - UX16d2d dead-branch recovery policy

nonisolated enum RinkLensCaptureDeadBranchRecoveryAction: String, Sendable, Equatable {
    case none
    case reconnectOCR
    case rebuildGraph
    case preserveBroadcastRecording
    case suppress
}

nonisolated struct RinkLensCaptureDeadBranchRecoveryContext: Sendable, Equatable {
    let mode: RinkLensCaptureLifecycleMode
    let liveHealthy: Bool
    let ocrHealthy: Bool
    let ocrStructurallyReady: Bool
    let recordingActive: Bool
    let ocrReconnectAttempted: Bool
    let graphRebuildAttempted: Bool
}

nonisolated enum RinkLensCaptureDeadBranchRecoveryPolicy {
    static func action(for context: RinkLensCaptureDeadBranchRecoveryContext) -> RinkLensCaptureDeadBranchRecoveryAction {
        let liveRequiredAndUnhealthy = context.mode.requiresBroadcast && !context.liveHealthy
        let ocrRequiredAndUnhealthy = context.mode.requiresOCR && !context.ocrHealthy
        guard liveRequiredAndUnhealthy || ocrRequiredAndUnhealthy else { return .none }

        if liveRequiredAndUnhealthy {
            return context.recordingActive
                ? .preserveBroadcastRecording
                : (context.graphRebuildAttempted ? .suppress : .rebuildGraph)
        }

        if ocrRequiredAndUnhealthy,
           context.recordingActive,
           context.liveHealthy {
            // Recovery O restores the proven Build 744 defer-only policy. An open
            // writer contract is a hard boundary: no OCR output reconnect, branch
            // attach, or graph rebuild may mutate the shared capture session.
            return .preserveBroadcastRecording
        }
        if ocrRequiredAndUnhealthy, context.ocrStructurallyReady, !context.ocrReconnectAttempted {
            return .reconnectOCR
        }
        if context.recordingActive { return .preserveBroadcastRecording }
        if !context.graphRebuildAttempted { return .rebuildGraph }
        return .suppress
    }
}



/// One operator lens intent submitted to the applied-capture owner. Requested zoom
/// remains in RinkLensCameraControlStore; this value carries no independently
/// mutable copy and exists only for the duration of one controller transaction.
nonisolated struct RinkLensBroadcastLensContractIntent: Sendable, Equatable {
    let transactionID: UUID
    let target: RinkLensCameraLensTarget
    let requestedZoom: Double
    let previousRequestedZoom: Double
    let mode: RinkLensCaptureLifecycleMode
    let source: String
    let animated: Bool
    let duration: TimeInterval

    var isHalfX: Bool { target == .halfX }
}

/// Immutable result returned to the presentation layer. It reports the controller
/// decision but does not own camera, zoom, recording or writer state.
nonisolated struct RinkLensBroadcastLensContractResult: Sendable, Equatable {
    let transactionID: UUID
    let succeeded: Bool
    let statusText: String
    let appliedDeviceID: String?
    let appliedCaptureGeneration: Int
    let appliedCadence: RinkLensCaptureCadence?
    let recordingRestored: Bool
}

/// The operator production profile owns capture cadence across the complete
/// rear-camera zoom range. Optical framing may choose a different physical
/// constituent, but it cannot silently replace a requested 60fps cadence with
/// 30fps. CaptureEngine capability resolution remains the sole boundary that
/// may acknowledge a hardware-limited fallback.
nonisolated enum RinkLensBroadcastOpticalFormatPolicy {
    static func preferredFPS(wantsHalfX _: Bool, productionFPS: Int) -> Int {
        productionFPS
    }

    static func preferredFormat(
        wantsHalfX: Bool,
        currentFormat: RinkLensCaptureFormatPreference,
        productionFPS: Int
    ) -> RinkLensCaptureFormatPreference {
        RinkLensCaptureFormatPreference(
            width: wantsHalfX ? 1920 : currentFormat.width,
            height: wantsHalfX ? 1080 : currentFormat.height,
            cadence: .init(integerFPS: preferredFPS(
                wantsHalfX: wantsHalfX,
                productionFPS: productionFPS
            ))
        )
    }
}

/// One monotonic budget shared by every physical acknowledgement in a lens
/// replacement. Later stages receive only the time left; no stage restarts the
/// transaction timeout.
nonisolated struct RinkLensBroadcastOpticalAdmissionDeadline: Sendable, Equatable {
    let uptimeNanoseconds: UInt64

    init(startUptimeNanoseconds: UInt64, timeout: TimeInterval) {
        let duration = UInt64(max(0, timeout) * 1_000_000_000)
        uptimeNanoseconds = startUptimeNanoseconds &+ duration
    }

    func remainingSeconds(at uptimeNanosecondsNow: UInt64) -> TimeInterval {
        guard uptimeNanosecondsNow < uptimeNanoseconds else { return 0 }
        return TimeInterval(uptimeNanoseconds - uptimeNanosecondsNow) / 1_000_000_000
    }
}

/// Immutable physical exposure evidence sampled only after a frame from the
/// exact installed camera generation has reached FrameHub. It contains no pixel
/// ownership and does not classify a dark scene as a failure.
nonisolated struct RinkLensBroadcastExposureSample: Sendable, Equatable {
    let sequence: Int
    let captureGeneration: Int
    let physicalDeviceID: String
    let iso: Float
    let exposureDurationSeconds: Double
    let isAdjustingExposure: Bool
}

/// Pure admission state for releasing the optical continuity frame. Two
/// consecutive non-adjusting samples from the exact device/generation must be
/// physically stable; source mismatch, duplicate evidence or continued exposure
/// movement resets admission.
nonisolated struct RinkLensBroadcastExposureConvergenceState: Sendable {
    let minimumSequenceExclusive: Int
    let requiredCaptureGeneration: Int
    let requiredPhysicalDeviceID: String

    private var previousSample: RinkLensBroadcastExposureSample?

    init(
        minimumSequenceExclusive: Int,
        requiredCaptureGeneration: Int,
        requiredPhysicalDeviceID: String
    ) {
        self.minimumSequenceExclusive = minimumSequenceExclusive
        self.requiredCaptureGeneration = requiredCaptureGeneration
        self.requiredPhysicalDeviceID = requiredPhysicalDeviceID
        previousSample = nil
    }

    mutating func observe(_ sample: RinkLensBroadcastExposureSample) -> Bool {
        guard sample.sequence > minimumSequenceExclusive,
              sample.captureGeneration == requiredCaptureGeneration,
              sample.physicalDeviceID == requiredPhysicalDeviceID,
              sample.iso.isFinite,
              sample.iso > 0,
              sample.exposureDurationSeconds.isFinite,
              sample.exposureDurationSeconds > 0,
              !sample.isAdjustingExposure else {
            previousSample = nil
            return false
        }

        guard let previousSample,
              sample.sequence > previousSample.sequence else {
            self.previousSample = sample
            return false
        }

        let isoStable = Self.relativeDifference(
            Double(sample.iso),
            Double(previousSample.iso)
        ) <= 0.08
        let durationStable = Self.relativeDifference(
            sample.exposureDurationSeconds,
            previousSample.exposureDurationSeconds
        ) <= 0.08
        self.previousSample = sample
        return isoStable && durationStable
    }

    private static func relativeDifference(_ lhs: Double, _ rhs: Double) -> Double {
        abs(lhs - rhs) / max(abs(lhs), abs(rhs), 0.000_001)
    }
}

/// Pure visual plan for one zoom request. It describes the shared field-of-view
/// boundary but owns no timer, device, frame or mutable zoom state.
nonisolated struct RinkLensBroadcastLensTransitionPlan: Sendable, Equatable {
    let outgoingTargetZoom: Double
    let rollbackTargetZoom: Double
    let incomingStartZoom: Double?
    let finalTargetZoom: Double
    let holdsLastCompleteFrame: Bool
    let totalMotionDuration: TimeInterval
    let outgoingMotionDuration: TimeInterval
    let incomingMotionDuration: TimeInterval

    static func resolve(
        appliedZoom: Double,
        requestedZoom: Double,
        fullRangeDuration: TimeInterval,
        requiresBranchReplacement: Bool
    ) -> Self {
        let applied = min(max(appliedZoom, 0.5), 5.0)
        let requested = min(max(requestedZoom, 0.5), 5.0)
        let total = RinkLensBroadcastZoomMotion.duration(
            fullRangeDuration: fullRangeDuration,
            from: CGFloat(applied),
            to: CGFloat(requested)
        )
        guard requiresBranchReplacement else {
            return .init(
                outgoingTargetZoom: requested,
                rollbackTargetZoom: applied,
                incomingStartZoom: nil,
                finalTargetZoom: requested,
                holdsLastCompleteFrame: false,
                totalMotionDuration: total,
                outgoingMotionDuration: total,
                incomingMotionDuration: 0
            )
        }
        let outgoing = RinkLensBroadcastZoomMotion.duration(
            fullRangeDuration: fullRangeDuration,
            from: CGFloat(applied),
            to: 1.0
        )
        let incoming = RinkLensBroadcastZoomMotion.duration(
            fullRangeDuration: fullRangeDuration,
            from: 1.0,
            to: CGFloat(requested)
        )
        return .init(
            outgoingTargetZoom: 1.0,
            rollbackTargetZoom: applied,
            incomingStartZoom: 1.0,
            finalTargetZoom: requested,
            holdsLastCompleteFrame: true,
            totalMotionDuration: total,
            outgoingMotionDuration: outgoing,
            incomingMotionDuration: incoming
        )
    }
}

@MainActor
final class RinkLensCaptureLifecycleController {
    private let liveService: HockeyCameraService
    private let ocrService: HockeyCameraService
    private let captureEngine: ExternalOCRMultiCamCoordinator
    /// Reads the single requested camera-quality owner on MainActor. The
    /// controller derives a capture cadence from this value but never stores a
    /// second editable policy.
    private let broadcastImageQualityPolicyProvider: () -> BroadcastImageQualityPolicy
    // Recovery BC: the physical iPad8,9 lens handoff produced its first exact-
    // generation frame at 1.517s, six milliseconds after the old rollback had
    // already started. Use the same 1.75s first-frame acceptance envelope as
    // CaptureEngine startup for Broadcast branch/cadence transactions. This is
    // the terminal physical acknowledgement boundary, not a retry or UI delay.
    private let broadcastFirstFrameAcceptanceTimeout: TimeInterval = 1.75
    private enum BroadcastCameraMutationOwner: String {
        case opticalHandoff
        case imageQuality
    }
    private var broadcastCameraMutationOwner: BroadcastCameraMutationOwner?

    private func preferredBroadcastFPS(
        policy: BroadcastImageQualityPolicy,
        physicalDeviceID: String
    ) -> Int {
        let wantsHalfX = liveService.broadcastPhysicalDeviceID(
            physicalDeviceID,
            satisfiesHalfXTarget: true
        )
        return RinkLensBroadcastOpticalFormatPolicy.preferredFPS(
            wantsHalfX: wantsHalfX,
            productionFPS: policy.preferredWideFPS
        )
    }

    private var intentRevision: UInt64 = 0
    private var latestIntentRevision: UInt64 = 0
    private var latestIntentRequest: RinkLensCaptureLifecycleRequest?
    private var authoritativeDesiredContract: RinkLensDesiredCaptureContract?
    private var deferredRecordingLeaseRequest: RinkLensCaptureLifecycleRequest?
    private(set) var recordingLeaseDeferredRequestCount: Int = 0
    private(set) var recordingLeaseReplayCount: Int = 0
    private var lastReconciliationAttemptUptimeNanoseconds: UInt64 = 0
    private let minimumIdenticalContractRetryIntervalNanoseconds: UInt64 = 1_000_000_000
    private var healthDivergenceContract: RinkLensDesiredCaptureContract?
    private var healthDivergenceStartedAtUptimeNanoseconds: UInt64 = 0
    private var lastHealthObservationUptimeNanoseconds: UInt64 = 0
    private let minimumHealthObservationIntervalNanoseconds: UInt64 = 1_000_000_000
    private let sustainedHealthDivergenceIntervalNanoseconds: UInt64 = 2_000_000_000
    private struct LifecycleWaiter {
        let revision: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var lifecycleOperationInFlight = false
    private var lifecycleWaiters: [LifecycleWaiter] = []

    // Recovery T / RL-053: scene suspension and wake are one controller-owned
    // ordered transaction stream. A foreground request is deliberately not
    // materialised or registered until the preceding background stop has
    // physically completed, preventing latest-intent registration from
    // superseding an in-flight stop while AVFoundation is still stopping.
    private var sceneLifecycleTask: Task<Void, Never>?
    private var sceneLifecycleSequence: UInt64 = 0
    private var lastSatisfiedRequest: RinkLensCaptureLifecycleRequest?
    private var lastSatisfiedOutcome: RinkLensCaptureLifecycleOutcome?
    private(set) var coalescedRequestCount: Int = 0
    private(set) var identicalContractSuppressionCount: Int = 0
    private(set) var abandonedRequestCount: Int = 0
    private(set) var atomicReconfigurationCount: Int = 0
    private(set) var reconciliationExecutionCount: Int = 0
    private(set) var healthObservationCount: Int = 0
    private(set) var healthObservationSuppressionCount: Int = 0
    private(set) var sustainedHealthReconciliationCount: Int = 0
    private(set) var deadBranchOCRReconnectCount: Int = 0
    private(set) var deadBranchGraphRebuildCount: Int = 0
    private(set) var deadBranchRecoverySuppressionCount: Int = 0
    private(set) var lastDeadBranchRecoveryText: String = "none"
    private var deadBranchEpisodeActive = false
    private var deadBranchOCRReconnectAttempted = false
    private var deadBranchGraphRebuildAttempted = false
    private var deadBranchRecoveryInFlight = false
    private var deadBranchRecordingDeferralPublished = false

    private(set) var presentationPreservationCount: Int = 0

    var desiredContractRevision: UInt64 { latestIntentRevision }

    var desiredModeSnapshot: RinkLensCaptureLifecycleMode? {
        authoritativeDesiredContract?.mode
    }

    func notePresentationOnlyRouteChange(_ reason: String) {
        presentationPreservationCount &+= 1
        trace("UX16d2 presentation-only route preserved capture #\(presentationPreservationCount): \(reason)")
    }

    // Recovery AH / RL-070: route/presentation code has no physical OCR
    // connection-delivery API. Consumer processing is admitted above FrameHub;
    // CaptureEngine alone owns the continuously configured physical branch.

    var desiredContractDiagnosticText: String {
        authoritativeDesiredContract?.diagnosticText ?? "none"
    }

    var effectiveContractDiagnosticText: String {
        captureEngine.snapshot.effectiveContract?.diagnosticText ?? "none"
    }

    var deferredRecordingLeaseRequestDiagnosticText: String {
        deferredRecordingLeaseRequest.map { "mode=\($0.mode.rawValue) reason=\($0.reason)" } ?? "none"
    }

    var hasDeferredRecordingOCRRequest: Bool {
        deferredRecordingLeaseRequest?.mode.requiresOCR == true
    }

    init(
        liveService: HockeyCameraService,
        ocrService: HockeyCameraService,
        multiCamEngine: ExternalOCRMultiCamCoordinator,
        broadcastImageQualityPolicyProvider: @escaping () -> BroadcastImageQualityPolicy
    ) {
        self.liveService = liveService
        self.ocrService = ocrService
        self.captureEngine = multiCamEngine
        self.broadcastImageQualityPolicyProvider = broadcastImageQualityPolicyProvider
    }

    /// R13 applies an operator camera-quality request through the capture owner.
    /// If a recording is open, RecordingEngine holds appends and keeps the same
    /// file while CaptureEngine changes cadence; the writer then adopts only the
    /// verified physical cadence. No route/view owns or replays the policy.
    @discardableResult
    func applyBroadcastImageQualityPolicyFromOwner(
        _ policy: BroadcastImageQualityPolicy,
        previousPolicy: BroadcastImageQualityPolicy,
        source: String,
        reason: String
    ) async -> Bool {
        guard broadcastCameraMutationOwner == nil else {
            RinkLensStructuredEventLogger.shared.record(
                domain: .cameraControl,
                event: "camera_image_quality_deferred_by_camera_transaction",
                entityID: "broadcast-connection",
                previous: [
                    "mutationOwner": broadcastCameraMutationOwner?.rawValue ?? "unknown"
                ],
                next: ["savedOwnerPolicy": policy.rawValue],
                source: source,
                reason: "CaptureLifecycleController serializes camera-quality and optical mutations; the current transaction replays the latest saved owner policy before it releases ownership. \(reason)",
                captureGeneration: captureEngine.snapshot.transitionGeneration,
                authoritativeOwner: "CaptureLifecycleController"
            )
            return true
        }

        var requestedPolicy = policy
        var priorPolicy = previousPolicy
        var requestSource = source
        var requestReason = reason
        var applied = false
        while true {
            broadcastCameraMutationOwner = .imageQuality
            applied = await performBroadcastImageQualityPolicyFromOwner(
                requestedPolicy,
                previousPolicy: priorPolicy,
                source: requestSource,
                reason: requestReason
            )
            broadcastCameraMutationOwner = nil

            let latestPolicy = broadcastImageQualityPolicyProvider()
            guard latestPolicy != requestedPolicy else { return applied }
            priorPolicy = requestedPolicy
            requestedPolicy = latestPolicy
            requestSource = "CaptureLifecycleController.applyBroadcastImageQualityPolicyFromOwner"
            requestReason = "Replay latest saved camera-quality owner after serialized camera mutation"
        }
    }

    private func performBroadcastImageQualityPolicyFromOwner(
        _ policy: BroadcastImageQualityPolicy,
        previousPolicy: BroadcastImageQualityPolicy,
        source: String,
        reason: String
    ) async -> Bool {
        let ownerPolicy = broadcastImageQualityPolicyProvider()
        guard ownerPolicy == policy else {
            RinkLensStructuredEventLogger.shared.record(
                domain: .cameraControl,
                event: "camera_image_quality_transaction_superseded",
                entityID: "broadcast-connection",
                previous: ["requestedPolicy": policy.rawValue],
                next: ["ownerPolicy": ownerPolicy.rawValue],
                source: "CaptureLifecycleController.applyBroadcastImageQualityPolicyFromOwner",
                reason: "A newer CameraControlStore policy request replaced this transaction before physical application. \(reason)",
                authoritativeOwner: "RinkLensCameraControlStore"
            )
            return false
        }

        let before = captureEngine.snapshot
        let productionCadence = RinkLensCaptureCadence(integerFPS: policy.preferredWideFPS)

        guard before.sessionRunning,
              before.activeMode.requiresBroadcast,
              let beforeDeviceID = before.liveDeviceID,
              let beforeCadence = before.liveFormat?.cadence else {
            RinkLensStructuredEventLogger.shared.record(
                domain: .cameraControl,
                event: "camera_image_quality_policy_stored_for_next_capture",
                entityID: "broadcast-connection",
                previous: [
                    "captureMode": before.activeMode.rawValue,
                    "sessionRunning": String(before.sessionRunning)
                ],
                next: [
                    "policy": policy.rawValue,
                    "targetFPS": productionCadence.displayText
                ],
                source: source,
                reason: reason,
                captureGeneration: before.transitionGeneration,
                authoritativeOwner: "RinkLensCameraControlStore"
            )
            return true
        }

        // Resolve every quality-policy write through the same optical-domain
        // cadence law as lens replacement. Ultra Wide remains 1080p30 even when
        // the production policy prefers 60fps; Wide restores that preference.
        let requestedPreference = RinkLensBroadcastOpticalFormatPolicy.preferredFormat(
            wantsHalfX: liveService.broadcastPhysicalDeviceID(
                beforeDeviceID,
                satisfiesHalfXTarget: true
            ),
            currentFormat: before.liveFormat
                ?? RinkLensCaptureFormatPreference(width: 1920, height: 1080, cadence: beforeCadence),
            productionFPS: policy.preferredWideFPS
        )
        let requestedCadence = requestedPreference.cadence
        let requestedCadenceSupported = liveService.supportsCapturePreference(
            requestedPreference,
            physicalDeviceID: beforeDeviceID
        )
        let targetCadence = requestedCadenceSupported
            ? requestedCadence
            : RinkLensCaptureCadence(integerFPS: 30)
        let cadenceHardwareLimited = targetCadence != requestedCadence

        if cadenceHardwareLimited {
            RinkLensStructuredEventLogger.shared.record(
                domain: .cameraControl,
                event: "camera_image_quality_effective_cadence_hardware_limited",
                entityID: beforeDeviceID,
                previous: [
                    "policy": previousPolicy.rawValue,
                    "physicalFPS": beforeCadence.displayText
                ],
                next: [
                    "policy": policy.rawValue,
                    "requestedFPS": requestedCadence.displayText,
                    "effectiveFPS": targetCadence.displayText,
                    "physicalLens": before.liveDeviceName,
                    "capabilityBoundary": "exact-format-level-MultiCam"
                ],
                source: "CaptureLifecycleController.applyBroadcastImageQualityPolicyFromOwner",
                reason: "Exact physical MultiCam format does not advertise the requested cadence. \(reason)",
                captureGeneration: before.transitionGeneration,
                authoritativeOwner: "CaptureLifecycleController"
            )
        }

        if beforeCadence == targetCadence, previousPolicy == policy {
            commitBroadcastCadenceToDesiredContract(
                beforeCadence,
                physicalDeviceID: beforeDeviceID,
                policy: policy,
                reason: reason
            )
            RinkLensStructuredEventLogger.shared.record(
                domain: .cameraControl,
                event: "camera_image_quality_cadence_noop_coalesced",
                entityID: beforeDeviceID,
                previous: [
                    "policy": previousPolicy.rawValue,
                    "fps": beforeCadence.displayText
                ],
                next: [
                    "policy": policy.rawValue,
                    "requestedFPS": requestedCadence.displayText,
                    "effectiveFPS": targetCadence.displayText,
                    "hardwareLimited": String(cadenceHardwareLimited),
                    "writerHold": "false",
                    "captureMutation": "none"
                ],
                source: "CaptureLifecycleController.applyBroadcastImageQualityPolicyFromOwner",
                reason: "Verified hardware already matches the fixed target cadence. \(source): \(reason)",
                captureGeneration: before.transitionGeneration,
                authoritativeOwner: "RinkLensCameraControlStore"
            )
            return true
        }

        let writerOpen = RinkLensRecordingCaptureLease.shared.isWriterContractOpen()
        if writerOpen {
            RinkLensStructuredEventLogger.shared.record(
                domain: .cameraControl,
                event: "camera_image_quality_deferred_recording_source_frozen",
                entityID: beforeDeviceID,
                previous: [
                    "policy": previousPolicy.rawValue,
                    "fps": beforeCadence.displayText,
                    "writerContractOpen": "true"
                ],
                next: [
                    "policy": policy.rawValue,
                    "requestedFPS": requestedCadence.displayText,
                    "effectiveFPS": targetCadence.displayText,
                    "hardwareLimited": String(cadenceHardwareLimited),
                    "physicalMutation": "deferred-until-writer-closes"
                ],
                source: "CaptureLifecycleController.applyBroadcastImageQualityPolicyFromOwner",
                reason: "Image-quality cadence changes remain deferred while the writer is open; Recovery B only permits an explicit lens handoff transaction. \(reason)",
                captureGeneration: before.transitionGeneration,
                authoritativeOwner: "RinkLensCameraControlStore"
            )
            return true
        }

        let firstFrameSequence = RinkLensFrameHub.shared.diagnosticSnapshot().broadcast.sequence
        let appliedCadence = await captureEngine.applyBroadcastImageQualityPolicy(
            policy,
            effectiveTargetCadence: targetCadence,
            reason: reason,
            recordingTransitionAuthorised: false
        )

        let afterApply = captureEngine.snapshot
        let appliedDeviceID = afterApply.liveDeviceID ?? beforeDeviceID
        let actualCadence = appliedCadence ?? afterApply.liveFormat?.cadence ?? beforeCadence

        var freshFrameVerified = false
        if appliedCadence != nil {
            freshFrameVerified = await waitForBroadcastFrame(
                afterSequence: firstFrameSequence,
                captureGeneration: afterApply.transitionGeneration,
                physicalDeviceID: appliedDeviceID,
                timeout: broadcastFirstFrameAcceptanceTimeout
            ) != nil
        }

        let recordingRestored = true

        if appliedCadence != nil {
            commitBroadcastCadenceToDesiredContract(
                actualCadence,
                physicalDeviceID: appliedDeviceID,
                policy: policy,
                reason: reason
            )
        }

        let succeeded = appliedCadence != nil
            && freshFrameVerified
            && recordingRestored

        RinkLensStructuredEventLogger.shared.record(
            domain: .cameraControl,
            event: "camera_image_quality_transaction_completed",
            entityID: appliedDeviceID,
            previous: [
                "policy": previousPolicy.rawValue,
                "fps": beforeCadence.displayText,
                "recordingState": "writer-closed",
                "writerContractOpen": "false"
            ],
            next: [
                "policy": policy.rawValue,
                "requestedFPS": requestedCadence.displayText,
                "effectiveFPS": actualCadence.displayText,
                "hardwareLimited": String(cadenceHardwareLimited),
                "freshFrameVerified": String(freshFrameVerified),
                "sameFileWriterRestored": String(recordingRestored),
                "succeeded": String(succeeded)
            ],
            source: "CaptureLifecycleController.applyBroadcastImageQualityPolicyFromOwner",
            reason: "\(source): \(reason)",
            captureGeneration: afterApply.transitionGeneration,
            authoritativeOwner: "CaptureLifecycleController"
        )
        return succeeded
    }

    // Recovery CY / RL-163: the automatic zoom-driven resolution migration
    // is deleted. CaptureLifecycleController still owns the 0.5x optical handoff
    // and 1080 cadence changes, but 1x–5x zoom cannot mutate source resolution.

    private func commitBroadcastCadenceToDesiredContract(
        _ cadence: RinkLensCaptureCadence,
        physicalDeviceID: String,
        policy: BroadcastImageQualityPolicy,
        reason: String
    ) {
        guard let desired = authoritativeDesiredContract,
              desired.mode.requiresBroadcast else { return }
        let width = desired.liveFormat?.width ?? captureEngine.snapshot.liveFormat?.width ?? 1920
        let height = desired.liveFormat?.height ?? captureEngine.snapshot.liveFormat?.height ?? 1080
        let previousFormat = desired.liveFormat?.diagnosticText ?? "auto"
        let updatedFormat = RinkLensCaptureFormatPreference(
            width: width,
            height: height,
            cadence: cadence
        )
        authoritativeDesiredContract = RinkLensDesiredCaptureContract(
            mode: desired.mode,
            liveLogicalSourceID: desired.liveLogicalSourceID,
            ocrLogicalSourceID: desired.ocrLogicalSourceID,
            livePreferredDeviceID: physicalDeviceID,
            ocrPreferredDeviceID: desired.ocrPreferredDeviceID,
            liveFormat: updatedFormat,
            ocrFormat: desired.ocrFormat
        )
        RinkLensStructuredEventLogger.shared.record(
            domain: .capture,
            event: "capture_desired_cadence_derived_from_camera_quality_owner",
            entityID: physicalDeviceID,
            previous: ["format": previousFormat],
            next: [
                "format": updatedFormat.diagnosticText,
                "policy": policy.rawValue
            ],
            source: "CaptureLifecycleController.commitBroadcastCadenceToDesiredContract",
            reason: reason,
            captureGeneration: captureEngine.snapshot.transitionGeneration,
            authoritativeOwner: "CaptureLifecycleController"
        )
    }


    /// Applies one bounded Broadcast zoom transaction. Logical zoom selects an
    /// optical domain; the controller derives that domain's exact capture contract
    /// while RecordingWriter and the publisher retain their own lifecycle authority.
    func applyBroadcastLensContract(
        _ intent: RinkLensBroadcastLensContractIntent,
        zoomStore: RinkLensCameraZoomStore
    ) async -> RinkLensBroadcastLensContractResult {
        let entrySnapshot = captureEngine.snapshot
        var streamHandoffStarted = false
        var streamHandoffCompleted = false
        defer {
            if streamHandoffStarted && !streamHandoffCompleted {
                StreamControlStore.shared.abortCaptureHandoff(transactionID: intent.transactionID)
            }
        }
        // R20: the pending physical-lens transaction exists only in
        // RinkLensCameraZoomStore. The ViewModel submits one executor for a new
        // transaction and later taps mutate the desired target in that same
        // store; this controller is orchestration only and keeps no mirror ID.
        guard zoomStore.liveLensTransaction?.transactionID == intent.transactionID else {
            return .init(
                transactionID: intent.transactionID,
                succeeded: false,
                statusText: "The camera request is no longer active.",
                appliedDeviceID: entrySnapshot.liveDeviceID,
                appliedCaptureGeneration: entrySnapshot.transitionGeneration,
                appliedCadence: entrySnapshot.liveFormat?.cadence,
                recordingRestored: true
            )
        }

        guard let pending = zoomStore.liveLensTransaction,
              pending.transactionID == intent.transactionID else {
            let actual = captureEngine.snapshot
            return .init(
                transactionID: intent.transactionID,
                succeeded: false,
                statusText: "The camera request was superseded.",
                appliedDeviceID: actual.liveDeviceID,
                appliedCaptureGeneration: actual.transitionGeneration,
                appliedCadence: actual.liveFormat?.cadence,
                recordingRestored: true
            )
        }

        let target = pending.target
        let requestedZoom = CGFloat(pending.requestedZoom)
        let halfX = target == .halfX
        let before = captureEngine.snapshot
        guard before.sessionRunning,
              before.activeMode.requiresBroadcast,
              let activeDeviceID = before.liveDeviceID,
              let activeFormat = before.liveFormat else {
            zoomStore.cancelLiveLensTransaction(
                transactionID: intent.transactionID,
                deviceID: before.liveDeviceID,
                captureGeneration: before.transitionGeneration,
                source: "CaptureLifecycleController.applyBroadcastLensContract",
                reason: "The verified Broadcast branch is not ready"
            )
            return .init(
                transactionID: intent.transactionID,
                succeeded: false,
                statusText: "The Broadcast camera is not ready.",
                appliedDeviceID: before.liveDeviceID,
                appliedCaptureGeneration: before.transitionGeneration,
                appliedCadence: before.liveFormat?.cadence,
                recordingRestored: true
            )
        }

        let activeDeviceSupportsTarget = liveService.broadcastPhysicalDeviceID(
            activeDeviceID,
            satisfiesHalfXTarget: halfX
        )
        let targetDeviceID = activeDeviceSupportsTarget
            ? activeDeviceID
            : liveService.preferredBroadcastPhysicalDeviceID(forHalfX: halfX, pairedOCRDeviceID: before.ocrDeviceID)

        guard let targetDeviceID else {
            zoomStore.cancelLiveLensTransaction(
                transactionID: intent.transactionID,
                deviceID: activeDeviceID,
                captureGeneration: before.transitionGeneration,
                source: "CaptureLifecycleController.applyBroadcastLensContract",
                reason: "No compatible virtual or physical rear camera is available"
            )
            return .init(
                transactionID: intent.transactionID,
                succeeded: false,
                statusText: "The requested framing is unavailable.",
                appliedDeviceID: activeDeviceID,
                appliedCaptureGeneration: before.transitionGeneration,
                appliedCadence: activeFormat.cadence,
                recordingRestored: true
            )
        }

        // Recovery DA / RL-174 revalidates optical-domain truth at the lifecycle
        // acknowledgement boundary. Camera discovery/fallback ordering cannot make
        // a physical Ultra Wide authoritative for logical 1x–5x again.
        guard liveService.broadcastPhysicalDeviceID(
            targetDeviceID,
            satisfiesHalfXTarget: halfX
        ) else {
            zoomStore.cancelLiveLensTransaction(
                transactionID: intent.transactionID,
                deviceID: activeDeviceID,
                captureGeneration: before.transitionGeneration,
                source: "CaptureLifecycleController.applyBroadcastLensContract",
                reason: "Resolved rear input violates the requested optical quality domain"
            )
            return .init(
                transactionID: intent.transactionID,
                succeeded: false,
                statusText: halfX
                    ? "Ultra Wide camera is unavailable for 0.5x."
                    : "Wide camera is unavailable for normal Broadcast zoom.",
                appliedDeviceID: activeDeviceID,
                appliedCaptureGeneration: before.transitionGeneration,
                appliedCadence: activeFormat.cadence,
                recordingRestored: true
            )
        }

        // Resolve format and cadence from the exact optical-domain policy and
        // physical MultiCam capability. Ultra Wide requests 1080p30; Wide
        // restores the selected production cadence when supported.
        let productionFPS = broadcastImageQualityPolicyProvider().preferredWideFPS
        // A 0.5x request uses the explicit virtual/Ultra-Wide handoff. Carrying a
        // higher-resolution Wide format into that handoff would ask the replacement
        // device for the wrong contract and reject an
        // otherwise valid 0.5x transition.
        let preferredTargetPreference = RinkLensBroadcastOpticalFormatPolicy.preferredFormat(
            wantsHalfX: halfX,
            currentFormat: activeFormat,
            productionFPS: productionFPS
        )
        let targetWidth = preferredTargetPreference.width
        let targetHeight = preferredTargetPreference.height
        let targetPreference = liveService.supportsCapturePreference(
            preferredTargetPreference,
            physicalDeviceID: targetDeviceID
        ) ? preferredTargetPreference : RinkLensCaptureFormatPreference(
            width: targetWidth,
            height: targetHeight,
            cadence: .init(integerFPS: 30)
        )
        let requiresBranchMigration = targetDeviceID != activeDeviceID
        let appliedZoomBeforeTransition = zoomStore.applied(for: .live)
        let desiredZoomAtPlanCreation = zoomStore.requested(for: .live)
        let transitionPlan = RinkLensBroadcastLensTransitionPlan.resolve(
            appliedZoom: Double(appliedZoomBeforeTransition),
            requestedZoom: Double(desiredZoomAtPlanCreation),
            fullRangeDuration: intent.duration,
            requiresBranchReplacement: requiresBranchMigration
        )

        if requiresBranchMigration,
           !liveService.supportsCapturePreference(targetPreference, physicalDeviceID: targetDeviceID) {
            zoomStore.cancelLiveLensTransaction(
                transactionID: intent.transactionID,
                deviceID: activeDeviceID,
                captureGeneration: before.transitionGeneration,
                source: "CaptureLifecycleController.applyBroadcastLensContract",
                reason: "The fallback rear input cannot preserve the active capture profile"
            )
            return .init(
                transactionID: intent.transactionID,
                succeeded: false,
                statusText: "The active capture profile is unavailable on the fallback camera.",
                appliedDeviceID: activeDeviceID,
                appliedCaptureGeneration: before.transitionGeneration,
                appliedCadence: activeFormat.cadence,
                recordingRestored: true
            )
        }

        let writerOpen = RinkLensRecordingCaptureLease.shared.isWriterContractOpen()
        let recordingHandoffStarted: Bool
        if requiresBranchMigration && writerOpen {
            recordingHandoffStarted = BroadcastRecordingManager.shared.suspendRecordingForCameraContractChange(
                transactionID: intent.transactionID,
                targetCadence: targetPreference.cadence,
                reason: pending.reason
            )
            guard recordingHandoffStarted else {
                let compensated = await compensateOutgoingZoomAfterRejectedHandoff(
                    transactionID: intent.transactionID,
                    requestedAppliedZoom: appliedZoomBeforeTransition,
                    animated: intent.animated,
                    duration: intent.duration,
                    source: "Restore outgoing zoom after recording handoff rejection",
                    zoomStore: zoomStore
                )
                if compensated {
                    zoomStore.cancelLiveLensTransaction(
                        transactionID: intent.transactionID,
                        deviceID: activeDeviceID,
                        captureGeneration: before.transitionGeneration,
                        source: "CaptureLifecycleController.applyBroadcastLensContract",
                        reason: "Recording writer was not ready for a controlled same-file camera handoff"
                    )
                }
                return .init(
                    transactionID: intent.transactionID,
                    succeeded: false,
                    statusText: "The recording is not ready for a camera handoff yet.",
                    appliedDeviceID: activeDeviceID,
                    appliedCaptureGeneration: before.transitionGeneration,
                    appliedCadence: activeFormat.cadence,
                    recordingRestored: true
                )
            }
        } else {
            recordingHandoffStarted = false
        }

        if requiresBranchMigration {
            streamHandoffStarted = StreamControlStore.shared.holdForCaptureHandoff(
                transactionID: intent.transactionID,
                targetCadence: targetPreference.cadence
            )
            guard streamHandoffStarted else {
                if recordingHandoffStarted {
                    _ = await BroadcastRecordingManager.shared.restoreRecordingAfterCameraContractChange(
                        transactionID: intent.transactionID,
                        verifiedCadence: activeFormat.cadence,
                        captureGeneration: before.transitionGeneration,
                        physicalDeviceID: activeDeviceID,
                        reason: "Streaming publisher could not hold before optical handoff"
                    )
                }
                let compensated = await compensateOutgoingZoomAfterRejectedHandoff(
                    transactionID: intent.transactionID,
                    requestedAppliedZoom: appliedZoomBeforeTransition,
                    animated: intent.animated,
                    duration: intent.duration,
                    source: "Restore outgoing zoom after stream handoff rejection",
                    zoomStore: zoomStore
                )
                if compensated {
                    zoomStore.cancelLiveLensTransaction(
                        transactionID: intent.transactionID,
                        deviceID: activeDeviceID,
                        captureGeneration: before.transitionGeneration,
                        source: "CaptureLifecycleController.applyBroadcastLensContract",
                        reason: "Streaming publisher was not ready for a continuous optical handoff"
                    )
                }
                return .init(
                    transactionID: intent.transactionID,
                    succeeded: false,
                    statusText: "The live stream is not ready for a camera handoff yet.",
                    appliedDeviceID: activeDeviceID,
                    appliedCaptureGeneration: before.transitionGeneration,
                    appliedCadence: activeFormat.cadence,
                    recordingRestored: true
                )
            }
        }

        // Recovery B: branch replacement remains one CaptureLifecycleController
        // transaction. If a writer is open, RecordingEngine has already held appends
        // and released only its capture lease; the same AVAssetWriter/file stays open.

        RinkLensStructuredEventLogger.shared.record(
            domain: .capture,
            event: "capture_broadcast_zoom_reconciliation_started",
            entityID: targetDeviceID,
            previous: [
                "device": activeDeviceID,
                "format": activeFormat.diagnosticText,
                "appliedZoom": String(Double(zoomStore.applied(for: .live)))
            ],
            next: [
                "device": targetDeviceID,
                "format": targetPreference.diagnosticText,
                "requestedZoom": String(Double(requestedZoom)),
                "transactionID": intent.transactionID.uuidString,
                "cadenceMutation": String(requiresBranchMigration),
                "recordingHandoff": String(recordingHandoffStarted),
                "reconciliationPass": "1"
            ],
            source: "CaptureLifecycleController.applyBroadcastLensContract",
            reason: pending.reason,
            captureGeneration: before.transitionGeneration,
            authoritativeOwner: "CaptureLifecycleController"
        )

        let firstFrameSequence = RinkLensFrameHub.shared.diagnosticSnapshot().broadcast.sequence
        let result: RinkLensBroadcastInPlaceZoomResult
        if requiresBranchMigration {
            result = await captureEngine.replaceBroadcastBranchInPlace(
                physicalDeviceID: targetDeviceID,
                formatPreference: targetPreference,
                logicalZoom: CGFloat(transitionPlan.incomingStartZoom ?? Double(requestedZoom)),
                source: "Recovery C shared-boundary optical source selection \(pending.reason)"
            )
        } else {
            result = await captureEngine.applyBroadcastZoomInPlace(
                logicalZoom: requestedZoom,
                animated: intent.animated,
                duration: intent.duration,
                source: "Recovery C persistent rear-device zoom \(pending.reason)"
            )
        }

        let admissionDeadline = RinkLensBroadcastOpticalAdmissionDeadline(
            startUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            timeout: broadcastFirstFrameAcceptanceTimeout
        )

        let freshFrame: RinkLensFrameHubEvidence?
        if result.succeeded, let deviceID = result.physicalDeviceID {
            freshFrame = await waitForBroadcastFrame(
                afterSequence: firstFrameSequence,
                captureGeneration: result.captureGeneration,
                physicalDeviceID: deviceID,
                timeout: admissionDeadline.remainingSeconds(
                    at: DispatchTime.now().uptimeNanoseconds
                )
            )
        } else {
            freshFrame = nil
        }

        let exposureSample: RinkLensBroadcastExposureSample?
        if requiresBranchMigration,
           result.succeeded,
           let deviceID = result.physicalDeviceID,
           let freshFrame {
            RinkLensStructuredEventLogger.shared.record(
                domain: .cameraControl,
                event: "camera_lens_incoming_exposure_convergence_started",
                entityID: deviceID,
                previous: ["heldFrameSequence": String(firstFrameSequence)],
                next: [
                    "firstIncomingFrameSequence": String(freshFrame.sequence),
                    "targetCadence": (result.appliedCadence ?? targetPreference.cadence).displayText,
                    "darknessRejectionEnabled": "false"
                ],
                source: "CaptureLifecycleController.applyBroadcastLensContract",
                reason: "Continuity remains held until the exact incoming lens stops changing ISO and shutter",
                captureGeneration: result.captureGeneration,
                authoritativeOwner: "CaptureLifecycleController"
            )
            exposureSample = await captureEngine.waitForBroadcastExposureConvergence(
                afterSequence: freshFrame.sequence,
                captureGeneration: result.captureGeneration,
                physicalDeviceID: deviceID,
                timeout: admissionDeadline.remainingSeconds(
                    at: DispatchTime.now().uptimeNanoseconds
                )
            )
            if let exposureSample {
                RinkLensStructuredEventLogger.shared.record(
                    domain: .cameraControl,
                    event: "camera_lens_incoming_exposure_convergence_acknowledged",
                    entityID: deviceID,
                    next: [
                        "frameSequence": String(exposureSample.sequence),
                        "iso": String(exposureSample.iso),
                        "exposureDurationSeconds": String(exposureSample.exposureDurationSeconds),
                        "adjustingExposure": String(exposureSample.isAdjustingExposure)
                    ],
                    source: "CaptureLifecycleController.applyBroadcastLensContract",
                    reason: "Two consecutive exact-source exposure samples were physically stable",
                    captureGeneration: result.captureGeneration,
                    authoritativeOwner: "CaptureLifecycleController"
                )
            } else {
                RinkLensStructuredEventLogger.shared.record(
                    domain: .cameraControl,
                    event: "camera_lens_incoming_exposure_convergence_rejected",
                    entityID: deviceID,
                    next: [
                        "firstIncomingFrameSequence": String(freshFrame.sequence),
                        "darknessWasFailureCriterion": "false"
                    ],
                    source: "CaptureLifecycleController.applyBroadcastLensContract",
                    reason: "Incoming lens exposure did not physically settle inside the existing acknowledgement boundary",
                    captureGeneration: result.captureGeneration,
                    authoritativeOwner: "CaptureLifecycleController"
                )
            }
        } else {
            exposureSample = nil
        }

        let targetSnapshot = captureEngine.snapshot
        let targetContractVerified = !requiresBranchMigration || (
            targetSnapshot.transitionGeneration == result.captureGeneration
                && targetSnapshot.liveDeviceID == result.physicalDeviceID
                && targetSnapshot.liveFormat?.width == targetPreference.width
                && targetSnapshot.liveFormat?.height == targetPreference.height
                && targetSnapshot.liveFormat?.cadence == targetPreference.cadence
                && broadcastImageQualityPolicyProvider().preferredWideFPS == productionFPS
        )

        guard result.succeeded,
              let deviceID = result.physicalDeviceID,
              let freshFrame,
              !requiresBranchMigration || exposureSample != nil,
              targetContractVerified else {
            let failedSnapshot = captureEngine.snapshot
            let failureReason: String
            if !result.succeeded {
                failureReason = result.statusText
            } else if freshFrame == nil {
                failureReason = "Fresh frame for the requested Broadcast zoom was not verified"
            } else if !targetContractVerified {
                failureReason = "The requested physical Broadcast lens contract changed before acknowledgement"
            } else {
                failureReason = "Exposure for the requested physical Broadcast lens did not settle"
            }
            let previousAppliedZoom = CGFloat(transitionPlan.rollbackTargetZoom)

            if requiresBranchMigration, !result.succeeded {
                _ = await compensateOutgoingZoomAfterRejectedHandoff(
                    transactionID: intent.transactionID,
                    requestedAppliedZoom: appliedZoomBeforeTransition,
                    animated: intent.animated,
                    duration: intent.duration,
                    source: "Restore outgoing zoom after branch replacement rejection",
                    zoomStore: zoomStore
                )
            }

            // Recovery I: once CaptureEngine has physically replaced the rear input,
            // logical cancellation is not a rollback. Compensate through the same
            // single hardware owner, restore the exact previous device/format/cadence,
            // and require a fresh frame from that rollback generation before claiming
            // the previous applied zoom again. Apple configuration changes remain on
            // CaptureEngine's serial session queue; no UI owner mutates AVFoundation.
            if requiresBranchMigration, result.succeeded {
                let rollbackStartSequence = RinkLensFrameHub.shared.diagnosticSnapshot().broadcast.sequence
                RinkLensStructuredEventLogger.shared.record(
                    domain: .capture,
                    event: "capture_broadcast_zoom_physical_rollback_started",
                    entityID: activeDeviceID,
                    previous: [
                        "failedTargetDevice": failedSnapshot.liveDeviceID ?? "none",
                        "failedTargetFormat": failedSnapshot.liveFormat?.diagnosticText ?? "none",
                        "failedRequestedZoom": String(Double(requestedZoom))
                    ],
                    next: [
                        "rollbackDevice": activeDeviceID,
                        "rollbackFormat": activeFormat.diagnosticText,
                        "rollbackLogicalZoom": String(Double(previousAppliedZoom))
                    ],
                    source: "CaptureLifecycleController.applyBroadcastLensContract",
                    reason: failureReason,
                    captureGeneration: failedSnapshot.transitionGeneration,
                    authoritativeOwner: "CaptureLifecycleController"
                )

                let rollbackResult = await captureEngine.replaceBroadcastBranchInPlace(
                    physicalDeviceID: activeDeviceID,
                    formatPreference: activeFormat,
                    logicalZoom: previousAppliedZoom,
                    source: "Recovery I physical compensation after unverified optical target"
                )
                let rollbackFrame: RinkLensFrameHubEvidence?
                if rollbackResult.succeeded, let rollbackDeviceID = rollbackResult.physicalDeviceID {
                    rollbackFrame = await waitForBroadcastFrame(
                        afterSequence: rollbackStartSequence,
                        captureGeneration: rollbackResult.captureGeneration,
                        physicalDeviceID: rollbackDeviceID,
                        timeout: broadcastFirstFrameAcceptanceTimeout
                    )
                } else {
                    rollbackFrame = nil
                }

                let rollbackSnapshot = captureEngine.snapshot
                let physicalRollbackRestored = rollbackResult.succeeded
                    && rollbackSnapshot.liveDeviceID == activeDeviceID
                    && rollbackSnapshot.liveFormat?.width == activeFormat.width
                    && rollbackSnapshot.liveFormat?.height == activeFormat.height
                    && rollbackSnapshot.liveFormat?.cadence == activeFormat.cadence
                let rollbackFreshFrameVerified = rollbackFrame != nil

                if physicalRollbackRestored {
                    var recordingRestoredAfterRollback = !recordingHandoffStarted
                    if recordingHandoffStarted {
                        if rollbackFreshFrameVerified,
                           let rollbackCadence = rollbackSnapshot.liveFormat?.cadence {
                            recordingRestoredAfterRollback = await BroadcastRecordingManager.shared.restoreRecordingAfterCameraContractChange(
                                transactionID: intent.transactionID,
                                verifiedCadence: rollbackCadence,
                                captureGeneration: rollbackSnapshot.transitionGeneration,
                                physicalDeviceID: activeDeviceID,
                                reason: "Recovery I verified physical rollback after: \(failureReason)"
                            )
                        } else {
                            recordingRestoredAfterRollback = false
                        }
                        if !recordingRestoredAfterRollback {
                            BroadcastRecordingManager.shared.abortRecordingCameraContractChange(
                                transactionID: intent.transactionID,
                                reason: "Physical rollback restored the previous camera but a fresh rollback frame/writer rebind was not verified: \(failureReason)"
                            )
                        }
                    }

                    zoomStore.cancelLiveLensTransaction(
                        transactionID: intent.transactionID,
                        deviceID: activeDeviceID,
                        captureGeneration: rollbackSnapshot.transitionGeneration,
                        source: "CaptureLifecycleController.applyBroadcastLensContract",
                        reason: "Recovery I physical rollback restored previous hardware after: \(failureReason)"
                    )
                    RinkLensStructuredEventLogger.shared.record(
                        domain: .capture,
                        event: "capture_broadcast_zoom_physical_rollback_completed",
                        entityID: activeDeviceID,
                        previous: [
                            "failedTargetDevice": failedSnapshot.liveDeviceID ?? "none",
                            "failedRequestedZoom": String(Double(requestedZoom))
                        ],
                        next: [
                            "device": rollbackSnapshot.liveDeviceID ?? "none",
                            "format": rollbackSnapshot.liveFormat?.diagnosticText ?? "none",
                            "appliedZoom": String(Double(zoomStore.applied(for: .live))),
                            "freshFrameVerified": String(rollbackFreshFrameVerified),
                            "recordingRestored": String(recordingRestoredAfterRollback)
                        ],
                        source: "CaptureLifecycleController.applyBroadcastLensContract",
                        reason: failureReason,
                        captureGeneration: rollbackSnapshot.transitionGeneration,
                        authoritativeOwner: "CaptureLifecycleController"
                    )
                    return .init(
                        transactionID: intent.transactionID,
                        succeeded: false,
                        statusText: rollbackFreshFrameVerified
                            ? "The requested framing was not verified; the previous physical camera was restored."
                            : "The requested framing was not verified; the previous physical camera was restored but its fresh frame was not verified.",
                        appliedDeviceID: rollbackSnapshot.liveDeviceID,
                        appliedCaptureGeneration: rollbackSnapshot.transitionGeneration,
                        appliedCadence: rollbackSnapshot.liveFormat?.cadence,
                        recordingRestored: recordingRestoredAfterRollback
                    )
                }

                // The compensation transaction itself failed. Never publish the old
                // logical acknowledgement against a different physical camera. End
                // the zoom transaction at CaptureEngine's actual hardware state and
                // leave visual verification explicitly false. Recording source-health
                // policy remains authoritative if a fresh frame cannot be recovered.
                let terminalSnapshot = captureEngine.snapshot
                let terminalAppliedZoom: CGFloat
                let hardwareTruthResolved: Bool
                if terminalSnapshot.liveDeviceID == activeDeviceID {
                    terminalAppliedZoom = previousAppliedZoom
                    hardwareTruthResolved = true
                } else if terminalSnapshot.liveDeviceID == targetDeviceID {
                    terminalAppliedZoom = requestedZoom
                    hardwareTruthResolved = true
                } else {
                    terminalAppliedZoom = zoomStore.applied(for: .live)
                    hardwareTruthResolved = false
                }

                if recordingHandoffStarted {
                    BroadcastRecordingManager.shared.abortRecordingCameraContractChange(
                        transactionID: intent.transactionID,
                        reason: "Recovery I physical rollback could not restore a fresh verified source: \(failureReason)"
                    )
                }
                zoomStore.terminateLiveLensTransactionAtHardwareTruth(
                    transactionID: intent.transactionID,
                    appliedZoom: terminalAppliedZoom,
                    deviceID: terminalSnapshot.liveDeviceID,
                    captureGeneration: terminalSnapshot.transitionGeneration,
                    hardwareTruthResolved: hardwareTruthResolved,
                    source: "CaptureLifecycleController.applyBroadcastLensContract",
                    reason: "Recovery I compensation failed; applied state follows CaptureEngine hardware truth after: \(failureReason)"
                )
                RinkLensStructuredEventLogger.shared.record(
                    domain: .capture,
                    event: "capture_broadcast_zoom_physical_rollback_failed",
                    entityID: terminalSnapshot.liveDeviceID,
                    previous: [
                        "rollbackDevice": activeDeviceID,
                        "rollbackFormat": activeFormat.diagnosticText
                    ],
                    next: [
                        "actualDevice": terminalSnapshot.liveDeviceID ?? "none",
                        "actualFormat": terminalSnapshot.liveFormat?.diagnosticText ?? "none",
                        "appliedZoom": String(Double(terminalAppliedZoom)),
                        "hardwareTruthResolved": String(hardwareTruthResolved),
                        "visualVerified": "false"
                    ],
                    source: "CaptureLifecycleController.applyBroadcastLensContract",
                    reason: rollbackResult.statusText,
                    captureGeneration: terminalSnapshot.transitionGeneration,
                    authoritativeOwner: "CaptureLifecycleController"
                )
                return .init(
                    transactionID: intent.transactionID,
                    succeeded: false,
                    statusText: "The camera rollback could not be verified; applied state now follows the actual physical camera.",
                    appliedDeviceID: terminalSnapshot.liveDeviceID,
                    appliedCaptureGeneration: terminalSnapshot.transitionGeneration,
                    appliedCadence: terminalSnapshot.liveFormat?.cadence,
                    recordingRestored: false
                )
            }

            // No physical branch replacement completed. CaptureEngine either never
            // changed hardware or rolled its own configuration attempt back, so the
            // previous logical acknowledgement may be retained after restoring the
            // writer against the actual current branch.
            let actual = captureEngine.snapshot
            var recordingRestoredAfterFailure = true
            if recordingHandoffStarted {
                if let rollbackDeviceID = actual.liveDeviceID,
                   let rollbackCadence = actual.liveFormat?.cadence {
                    _ = await waitForBroadcastFrame(
                        afterSequence: firstFrameSequence,
                        captureGeneration: actual.transitionGeneration,
                        physicalDeviceID: rollbackDeviceID,
                        timeout: broadcastFirstFrameAcceptanceTimeout
                    )
                    recordingRestoredAfterFailure = await BroadcastRecordingManager.shared.restoreRecordingAfterCameraContractChange(
                        transactionID: intent.transactionID,
                        verifiedCadence: rollbackCadence,
                        captureGeneration: actual.transitionGeneration,
                        physicalDeviceID: rollbackDeviceID,
                        reason: "Recovery I pre-mutation optical transaction failure: \(failureReason)"
                    )
                } else {
                    recordingRestoredAfterFailure = false
                }
                if !recordingRestoredAfterFailure {
                    BroadcastRecordingManager.shared.abortRecordingCameraContractChange(
                        transactionID: intent.transactionID,
                        reason: failureReason
                    )
                }
            }
            zoomStore.cancelLiveLensTransaction(
                transactionID: intent.transactionID,
                deviceID: actual.liveDeviceID,
                captureGeneration: actual.transitionGeneration,
                source: "CaptureLifecycleController.applyBroadcastLensContract",
                reason: failureReason
            )
            RinkLensStructuredEventLogger.shared.record(
                domain: .capture,
                event: "capture_broadcast_zoom_retained_previous",
                entityID: actual.liveDeviceID,
                previous: [
                    "requestedDevice": targetDeviceID,
                    "requestedFormat": targetPreference.diagnosticText,
                    "requestedZoom": String(Double(requestedZoom))
                ],
                next: [
                    "retainedDevice": actual.liveDeviceID ?? "none",
                    "retainedFormat": actual.liveFormat?.diagnosticText ?? "none",
                    "retainedAppliedZoom": String(Double(zoomStore.applied(for: .live))),
                    "physicalBranchReplacementCompleted": "false"
                ],
                source: "CaptureLifecycleController.applyBroadcastLensContract",
                reason: failureReason,
                captureGeneration: actual.transitionGeneration,
                authoritativeOwner: "CaptureLifecycleController"
            )
            return .init(
                transactionID: intent.transactionID,
                succeeded: false,
                statusText: "The verified camera source was retained.",
                appliedDeviceID: actual.liveDeviceID,
                appliedCaptureGeneration: actual.transitionGeneration,
                appliedCadence: actual.liveFormat?.cadence,
                recordingRestored: recordingRestoredAfterFailure
            )
        }

        // The exact target generation has produced a complete frame and, after
        // physical branch replacement, its auto exposure has settled. Only this
        // acknowledgement releases the bounded outgoing presentation image.
        let continuityReleasePlan = RinkLensBroadcastPreviewContinuityReleasePlan.resolve(
            incomingMotionDuration: transitionPlan.incomingMotionDuration
        )
        let continuityReleaseStarted = RinkLensBroadcastPreviewContinuityStore.shared.releaseHold(
            transactionID: intent.transactionID,
            duration: continuityReleasePlan.duration
        )
        RinkLensStructuredEventLogger.shared.record(
            domain: .cameraControl,
            event: "camera_lens_continuity_release_started",
            entityID: intent.transactionID.uuidString,
            next: [
                "durationSeconds": String(continuityReleasePlan.duration),
                "incomingMotionDurationSeconds": String(transitionPlan.incomingMotionDuration),
                "releaseAccepted": String(continuityReleaseStarted)
            ],
            source: "CaptureLifecycleController.applyBroadcastLensContract",
            reason: "Exact incoming exposure acknowledgement starts a bounded sensor-image dissolve before the visible incoming zoom motion",
            captureGeneration: result.captureGeneration,
            authoritativeOwner: "CaptureLifecycleController"
        )

        // Once CaptureEngine has replaced the branch and produced a fresh frame,
        // camera zoom and RecordingWriter cadence rebind are independent owners.
        // Start the incoming-lens ramp immediately instead of holding the image
        // at 1x until the writer finishes its same-file transition. Both must be
        // physically acknowledged before this lifecycle transaction completes.
        let desiredAtBranchAcknowledgement = min(max(zoomStore.requested(for: .live), 0.5), 5.0)
        let desiredUsesInstalledOpticalDomain = liveService.broadcastPhysicalDeviceID(
            deviceID,
            satisfiesHalfXTarget: desiredAtBranchAcknowledgement < 1.0
        )
        let installedBoundaryZoom = CGFloat(transitionPlan.incomingStartZoom ?? Double(requestedZoom))
        let shouldConvergeInstalledLens = desiredUsesInstalledOpticalDomain
            && abs(desiredAtBranchAcknowledgement - installedBoundaryZoom) >= 0.01
        if shouldConvergeInstalledLens {
            RinkLensStructuredEventLogger.shared.record(
                domain: .cameraControl,
                event: "camera_zoom_incoming_lens_convergence_started_at_branch_ack",
                entityID: deviceID,
                previous: ["boundaryZoom": String(Double(installedBoundaryZoom))],
                next: [
                    "desiredZoom": String(Double(desiredAtBranchAcknowledgement)),
                    "fullRangeDurationSeconds": String(intent.duration),
                    "recordingRebindParallel": String(recordingHandoffStarted)
                ],
                source: intent.source,
                reason: "Fresh installed-lens frame permits zoom motion while RecordingWriter independently rebinds cadence",
                captureGeneration: result.captureGeneration,
                authoritativeOwner: "CaptureLifecycleController"
            )
        }
        async let installedLensConvergence: RinkLensBroadcastInPlaceZoomResult? = {
            guard shouldConvergeInstalledLens else { return nil }
            return await captureEngine.applyBroadcastZoomInPlace(
                logicalZoom: desiredAtBranchAcknowledgement,
                animated: intent.animated,
                duration: intent.duration,
                source: "Recovery BC6 incoming optical ramp at branch acknowledgement"
            )
        }()

        let recordingRestored: Bool
        if recordingHandoffStarted {
            recordingRestored = await BroadcastRecordingManager.shared.restoreRecordingAfterCameraContractChange(
                transactionID: intent.transactionID,
                verifiedCadence: result.appliedCadence ?? targetPreference.cadence,
                captureGeneration: result.captureGeneration,
                physicalDeviceID: deviceID,
                reason: halfX ? "0.5x Ultra Wide active" : "Wide camera active"
            )
        } else {
            recordingRestored = true
        }

        let streamRestored = !streamHandoffStarted || StreamControlStore.shared.rebindAfterCaptureHandoff(
            transactionID: intent.transactionID,
            captureGeneration: result.captureGeneration,
            physicalDeviceID: deviceID,
            cadence: result.appliedCadence ?? targetPreference.cadence
        )
        streamHandoffCompleted = streamRestored

        let installedLensResult = await installedLensConvergence
        let completedZoom: CGFloat
        if let installedLensResult, installedLensResult.succeeded {
            completedZoom = desiredAtBranchAcknowledgement
        } else {
            completedZoom = installedBoundaryZoom
        }

        guard recordingRestored && streamRestored else {
            if recordingHandoffStarted {
                BroadcastRecordingManager.shared.abortRecordingCameraContractChange(
                    transactionID: intent.transactionID,
                    reason: recordingRestored
                        ? "Verified camera source could not be rebound to the active publisher"
                        : "Verified camera source could not be rebound to the open writer"
                )
            }
            zoomStore.terminateLiveLensTransactionAtHardwareTruth(
                transactionID: intent.transactionID,
                appliedZoom: completedZoom,
                deviceID: deviceID,
                captureGeneration: result.captureGeneration,
                hardwareTruthResolved: true,
                source: "CaptureLifecycleController.applyBroadcastLensContract",
                reason: "Recording rebind failed after the installed lens physically reached its acknowledged zoom"
            )
            return .init(
                transactionID: intent.transactionID,
                succeeded: false,
                statusText: recordingRestored
                    ? "The camera changed but the live stream source could not be verified."
                    : "The camera changed but the recording source could not be verified.",
                appliedDeviceID: deviceID,
                appliedCaptureGeneration: result.captureGeneration,
                appliedCadence: result.appliedCadence,
                recordingRestored: false
            )
        }

        _ = zoomStore.acknowledgeLiveLensVisualApplied(
            transactionID: intent.transactionID,
            target: target,
            appliedZoom: completedZoom,
            deviceID: deviceID,
            captureGeneration: result.captureGeneration,
            frameSequence: freshFrame.sequence,
            source: "CaptureLifecycleController.applyBroadcastLensContract",
            reason: recordingHandoffStarted
                ? "Broadcast lens, cadence, first fresh frame and same-file writer rebind verified"
                : "Broadcast zoom and first fresh frame verified"
        )

        let committedFormat = RinkLensCaptureFormatPreference(
            width: targetPreference.width,
            height: targetPreference.height,
            cadence: result.appliedCadence ?? targetPreference.cadence
        )
        let committedRequest = RinkLensCaptureLifecycleRequest(
            mode: intent.mode,
            liveLogicalSourceID: liveService.captureIdentitySnapshot().selectedLogicalSourceID,
            ocrLogicalSourceID: intent.mode.requiresOCR ? ocrService.captureIdentitySnapshot().selectedLogicalSourceID : nil,
            liveDeviceID: result.physicalDeviceID,
            ocrDeviceID: intent.mode.requiresOCR ? captureEngine.snapshot.ocrDeviceID : nil,
            liveFormat: committedFormat,
            ocrFormat: intent.mode.requiresOCR ? captureEngine.snapshot.ocrFormat : nil,
            allowBroadcastFallback: false,
            recordingLeaseOverride: .none,
            reason: "R19 verified convergent Broadcast zoom contract"
        )
        let registered = registerIntent(committedRequest)
        lastSatisfiedRequest = committedRequest
        lastSatisfiedOutcome = successOutcome(
            request: committedRequest,
            resolvedMode: intent.mode,
            changed: registered.changed,
            usedFallback: requiresBranchMigration,
            status: "Camera framing ready"
        )
        _ = zoomStore.completeLiveLensTransaction(
            transactionID: intent.transactionID,
            appliedZoom: completedZoom,
            deviceID: result.physicalDeviceID,
            captureGeneration: result.captureGeneration,
            source: "CaptureLifecycleController.applyBroadcastLensContract",
            reason: recordingHandoffStarted
                ? "Latest Broadcast optical source and same-file recording cadence verified"
                : "Latest Broadcast zoom verified"
        )
        RinkLensStructuredEventLogger.shared.record(
            domain: .capture,
            event: "capture_broadcast_zoom_reconciliation_applied",
            entityID: result.physicalDeviceID,
            previous: [
                "device": entrySnapshot.liveDeviceID ?? "none",
                "format": entrySnapshot.liveFormat?.diagnosticText ?? "none"
            ],
            next: [
                "device": result.physicalDeviceID ?? "none",
                "format": committedFormat.diagnosticText,
                "transactionID": intent.transactionID.uuidString,
                "boundaryZoom": String(Double(requestedZoom)),
                "appliedZoom": String(Double(completedZoom)),
                "firstFreshFrameSequence": String(freshFrame.sequence),
                "strategy": result.strategy,
                "cadenceMutation": String(requiresBranchMigration),
                "recordingSameFileHandoff": String(recordingHandoffStarted),
                "recordingRestored": String(recordingRestored),
                "reconciliationPass": "1"
            ],
            source: "CaptureLifecycleController.applyBroadcastLensContract",
            reason: pending.reason,
            captureGeneration: result.captureGeneration,
            authoritativeOwner: "CaptureLifecycleController"
        )

        await convergeLatestBroadcastZoomAfterOpticalTransaction(
            completedZoom: completedZoom,
            animated: intent.animated,
            duration: intent.duration,
            source: intent.source,
            zoomStore: zoomStore
        )

        return .init(
            transactionID: intent.transactionID,
            succeeded: true,
            statusText: "Camera framing ready.",
            appliedDeviceID: result.physicalDeviceID,
            appliedCaptureGeneration: result.captureGeneration,
            appliedCadence: result.appliedCadence,
            recordingRestored: recordingRestored
        )
    }

    /// Recovery C uses FrameHub's existing event-driven capacity-one waiter rather
    /// than polling MainActor every 40ms. Proof remains strict: the accepted frame
    /// must be newer than the pre-transaction sequence, fresh, from the exact
    /// capture generation and from the verified physical device.
    private func waitForBroadcastFrame(
        afterSequence sequence: Int,
        captureGeneration: Int,
        physicalDeviceID: String,
        timeout: TimeInterval
    ) async -> RinkLensFrameHubEvidence? {
        await RinkLensFrameHub.shared.waitForFreshFrameEvidence(
            for: .broadcast,
            maxAge: 0.35,
            afterSequence: sequence,
            requiredCaptureGeneration: captureGeneration,
            requiredPhysicalDeviceID: physicalDeviceID,
            timeout: timeout
        )
    }

    /// One post-handoff convergence pass closes the gap observed physically in
    /// Recovery B when the operator moved the slider while an immutable optical
    /// transaction was still completing. Requested state stays exclusively in the
    /// zoom store; this controller reads that latest desired value only after the
    /// prior transaction has terminated and submits the minimum required hardware
    /// mutation. No compatibility zoom state or second transaction owner is added.
    private func convergeLatestBroadcastZoomAfterOpticalTransaction(
        completedZoom: CGFloat,
        animated: Bool,
        duration: TimeInterval,
        source: String,
        zoomStore: RinkLensCameraZoomStore
    ) async {
        let latestDesired = min(max(zoomStore.requested(for: .live), 0.5), 5.0)
        guard abs(latestDesired - completedZoom) >= 0.01 else { return }

        let snapshot = captureEngine.snapshot
        guard snapshot.sessionRunning,
              snapshot.activeMode.requiresBroadcast,
              let deviceID = snapshot.liveDeviceID else { return }

        let desiredHalfX = latestDesired < 1.0
        RinkLensStructuredEventLogger.shared.record(
            domain: .cameraControl,
            event: "camera_zoom_post_handoff_convergence_started",
            entityID: deviceID,
            previous: [
                "completedZoom": String(Double(completedZoom)),
                "appliedZoom": String(Double(zoomStore.applied(for: .live)))
            ],
            next: [
                "latestDesiredZoom": String(Double(latestDesired)),
                "sameOpticalDomain": String(liveService.broadcastPhysicalDeviceID(deviceID, satisfiesHalfXTarget: desiredHalfX))
            ],
            source: source,
            reason: "Recovery C converges the latest desired zoom after immutable optical handoff completion",
            captureGeneration: snapshot.transitionGeneration,
            authoritativeOwner: "CaptureLifecycleController"
        )

        if liveService.broadcastPhysicalDeviceID(deviceID, satisfiesHalfXTarget: desiredHalfX) {
            let result = await captureEngine.applyBroadcastZoomInPlace(
                logicalZoom: latestDesired,
                animated: animated,
                duration: duration,
                source: "Recovery C post-handoff latest desired zoom"
            )
            guard result.succeeded else {
                RinkLensStructuredEventLogger.shared.record(
                    domain: .cameraControl,
                    event: "camera_zoom_post_handoff_convergence_not_applied",
                    entityID: result.physicalDeviceID,
                    previous: ["latestDesiredZoom": String(Double(latestDesired))],
                    next: ["status": result.statusText],
                    source: source,
                    reason: "CaptureEngine did not verify the latest same-domain desired zoom",
                    captureGeneration: result.captureGeneration,
                    authoritativeOwner: "CaptureLifecycleController"
                )
                return
            }
            zoomStore.commitBroadcastDigitalZoom(
                latestDesired,
                deviceID: result.physicalDeviceID,
                captureGeneration: result.captureGeneration,
                source: "CaptureLifecycleController.postHandoffConvergence",
                reason: "Recovery C latest requested zoom physically settled after optical handoff"
            )
            return
        }

        _ = await requestBroadcastOpticalHandoff(
            logicalZoom: latestDesired,
            animated: animated,
            duration: duration,
            source: "Recovery C post-handoff latest desired optical convergence",
            zoomStore: zoomStore
        )
    }

    /// Build 784 capture-generation reconciliation boundary. The ViewModel may
    /// observe a new generation, but only this controller can inspect the active
    /// graph and ask CaptureEngine to restore the requested logical framing.
    /// Requested state remains exclusively in RinkLensCameraZoomStore.
    func reapplyBroadcastZoomAfterCaptureGeneration(
        reason: String,
        zoomStore: RinkLensCameraZoomStore
    ) {
        let snapshot = captureEngine.snapshot
        guard snapshot.sessionRunning,
              snapshot.activeMode.requiresBroadcast,
              snapshot.liveDeviceID != nil else {
            RinkLensStructuredEventLogger.shared.record(
                domain: .cameraControl,
                event: "camera_zoom_generation_reapply_deferred",
                entityID: "live",
                previous: [
                    "captureGeneration": String(snapshot.transitionGeneration),
                    "captureMode": snapshot.activeMode.rawValue,
                    "sessionRunning": String(snapshot.sessionRunning)
                ],
                next: ["reapplySubmitted": "false"],
                source: "CaptureLifecycleController.reapplyBroadcastZoomAfterCaptureGeneration",
                reason: reason,
                captureGeneration: snapshot.transitionGeneration,
                authoritativeOwner: "CaptureLifecycleController"
            )
            return
        }

        if let pending = zoomStore.liveLensTransaction {
            RinkLensStructuredEventLogger.shared.record(
                domain: .cameraControl,
                event: "camera_zoom_generation_reapply_coalesced",
                entityID: pending.target.rawValue,
                previous: [
                    "captureGeneration": String(snapshot.transitionGeneration),
                    "pendingTransactionID": pending.transactionID.uuidString
                ],
                next: [
                    "logicalZoom": String(pending.requestedZoom),
                    "reapplySubmitted": "false"
                ],
                source: "CaptureLifecycleController.reapplyBroadcastZoomAfterCaptureGeneration",
                reason: reason,
                captureGeneration: snapshot.transitionGeneration,
                authoritativeOwner: "CaptureLifecycleController"
            )
            return
        }

        let requested = zoomStore.requested(for: .live)
        RinkLensStructuredEventLogger.shared.record(
            domain: .cameraControl,
            event: "camera_zoom_generation_reapply_requested",
            entityID: "live",
            previous: [
                "captureGeneration": String(snapshot.transitionGeneration),
                "device": snapshot.liveDeviceID ?? "none"
            ],
            next: [
                "logicalZoom": String(Double(requested)),
                "reapplySubmitted": "true"
            ],
            source: "CaptureLifecycleController.reapplyBroadcastZoomAfterCaptureGeneration",
            reason: reason,
            captureGeneration: snapshot.transitionGeneration,
            authoritativeOwner: "CaptureLifecycleController"
        )
        captureEngine.applyBroadcastZoom(
            logicalZoom: requested,
            animated: false,
            duration: 0,
            source: "controller-generation-reapply-\(reason)"
        )
    }

    /// Returns the outgoing camera to the last applied acknowledgement after a
    /// handoff admission failure. If CaptureEngine cannot acknowledge that
    /// compensation, end the transaction at measured hardware truth instead of
    /// cancelling back to a value the device may no longer hold.
    private func compensateOutgoingZoomAfterRejectedHandoff(
        transactionID: UUID,
        requestedAppliedZoom: CGFloat,
        animated: Bool,
        duration: TimeInterval,
        source: String,
        zoomStore: RinkLensCameraZoomStore
    ) async -> Bool {
        let compensation = await captureEngine.applyBroadcastZoomInPlace(
            logicalZoom: requestedAppliedZoom,
            animated: animated,
            duration: duration,
            source: source
        )
        guard compensation.succeeded else {
            let actualDeviceID = compensation.physicalDeviceID ?? captureEngine.snapshot.liveDeviceID
            let physical = CGFloat(compensation.appliedPhysicalZoom ?? Double(requestedAppliedZoom))
            let measuredLogical = actualDeviceID.map(liveService.broadcastDeviceIDIsUltraWide) == true
                ? physical / 2.0
                : physical
            zoomStore.terminateLiveLensTransactionAtHardwareTruth(
                transactionID: transactionID,
                appliedZoom: min(max(measuredLogical, 0.5), 5.0),
                deviceID: actualDeviceID,
                captureGeneration: compensation.captureGeneration,
                hardwareTruthResolved: compensation.appliedPhysicalZoom != nil,
                source: "CaptureLifecycleController.compensateOutgoingZoomAfterRejectedHandoff",
                reason: "Outgoing zoom compensation was not acknowledged: \(compensation.statusText)"
            )
            return false
        }
        return true
    }

    /// Recovery C optical handoff entry point. Ordinary same-device zoom never enters
    /// this lifecycle transaction: it is submitted directly to CaptureEngine's serial
    /// session executor. This method exists only when 0.5x/1x genuinely requires
    /// replacing the Broadcast rear input; an open writer is held and rebound in place.
    @discardableResult
    func requestBroadcastOpticalHandoff(
        logicalZoom: CGFloat,
        animated: Bool,
        duration: TimeInterval,
        source: String,
        zoomStore: RinkLensCameraZoomStore
    ) async -> Bool {
        guard broadcastCameraMutationOwner == nil else {
            RinkLensStructuredEventLogger.shared.record(
                domain: .cameraControl,
                event: "camera_lens_handoff_deferred_by_camera_quality_transaction",
                entityID: "broadcast-connection",
                source: source,
                reason: "CaptureLifecycleController already owns an in-flight camera-quality mutation",
                captureGeneration: captureEngine.snapshot.transitionGeneration,
                authoritativeOwner: "CaptureLifecycleController"
            )
            return false
        }
        let policyAtStart = broadcastImageQualityPolicyProvider()
        broadcastCameraMutationOwner = .opticalHandoff
        let succeeded = await performBroadcastOpticalHandoff(
            logicalZoom: logicalZoom,
            animated: animated,
            duration: duration,
            source: source,
            zoomStore: zoomStore
        )
        broadcastCameraMutationOwner = nil

        let latestPolicy = broadcastImageQualityPolicyProvider()
        if latestPolicy != policyAtStart {
            _ = await applyBroadcastImageQualityPolicyFromOwner(
                latestPolicy,
                previousPolicy: policyAtStart,
                source: "CaptureLifecycleController.requestBroadcastOpticalHandoff",
                reason: "Replay latest saved camera-quality owner after serialized optical transaction"
            )
        }
        return succeeded
    }

    private func performBroadcastOpticalHandoff(
        logicalZoom: CGFloat,
        animated: Bool,
        duration: TimeInterval,
        source: String,
        zoomStore: RinkLensCameraZoomStore
    ) async -> Bool {
        let requested = min(max(logicalZoom, 0.5), 5.0)
        let snapshot = captureEngine.snapshot
        guard snapshot.sessionRunning,
              snapshot.activeMode.requiresBroadcast,
              let deviceID = snapshot.liveDeviceID else { return false }

        let wantsHalfX = requested < 1.0
        if liveService.broadcastPhysicalDeviceID(deviceID, satisfiesHalfXTarget: wantsHalfX) {
            return false
        }

        if let pending = zoomStore.liveLensTransaction {
            RinkLensStructuredEventLogger.shared.record(
                domain: .cameraControl,
                event: "camera_zoom_desired_retained_during_immutable_handoff",
                entityID: pending.target.rawValue,
                previous: [
                    "transactionID": pending.transactionID.uuidString,
                    "immutableZoom": String(pending.requestedZoom)
                ],
                next: [
                    "desiredZoom": String(Double(requested)),
                    "newExecutorStarted": "false"
                ],
                source: source,
                reason: "Existing optical handoff must terminate before a later desired state can be reconciled",
                captureGeneration: snapshot.transitionGeneration,
                authoritativeOwner: "CaptureLifecycleController"
            )
            return false
        }

        let target: RinkLensCameraLensTarget = wantsHalfX ? .halfX : .wide
        // Recovery DB keeps logical 1x as a transient visual boundary only.
        // CaptureEngine has a typed internal boundary operation for the outgoing
        // Ultra Wide lens; that operation cannot be invoked by ordinary zoom UI.
        // Wide becomes authoritative before logical 1x or above is acknowledged.
        let opticalBoundaryZoom: CGFloat = 1.0
        guard let transactionID = zoomStore.beginLiveLensTransaction(
            target: target,
            requestedZoom: opticalBoundaryZoom,
            deviceID: deviceID,
            captureGeneration: snapshot.transitionGeneration,
            source: source,
            reason: "Recovery C discrete optical-domain handoff"
        ) else { return false }

        if abs(requested - opticalBoundaryZoom) >= 0.01 {
            zoomStore.request(
                requested,
                for: .live,
                deviceID: deviceID,
                source: source,
                reason: "Latest desired zoom retained beyond the immutable optical boundary"
            )
        }

        let outgoingAppliedZoom = zoomStore.applied(for: .live)
        // Always ask CaptureEngine to settle the actual physical lens at 1x.
        // The requested/applied store can legitimately trail an interrupted
        // ramp; only CaptureEngine may translate current hardware truth and
        // derive the remaining duration at the selected logical velocity.
        RinkLensStructuredEventLogger.shared.record(
            domain: .cameraControl,
            event: "camera_zoom_outgoing_lens_boundary_ramp_started",
            entityID: deviceID,
            previous: ["lastAppliedAcknowledgement": String(Double(outgoingAppliedZoom))],
            next: [
                "boundaryZoom": String(Double(opticalBoundaryZoom)),
                "desiredZoom": String(Double(requested)),
                "fullRangeDurationSeconds": String(duration),
                "durationOwner": "CaptureEngine current physical factor"
            ],
            source: source,
            reason: "Outgoing physical lens must reach the shared visual boundary before branch replacement",
            captureGeneration: snapshot.transitionGeneration,
            authoritativeOwner: "CaptureLifecycleController"
        )
        let boundaryResult = await captureEngine.applyBroadcastOpticalHandoffBoundaryInPlace(
            animated: animated,
            duration: duration,
            source: "Recovery DB outgoing optical-boundary transit"
        )
        guard boundaryResult.succeeded else {
            let compensated = await compensateOutgoingZoomAfterRejectedHandoff(
                transactionID: transactionID,
                requestedAppliedZoom: outgoingAppliedZoom,
                animated: animated,
                duration: duration,
                source: "Restore outgoing zoom after optical-boundary rejection",
                zoomStore: zoomStore
            )
            if compensated {
                zoomStore.cancelLiveLensTransaction(
                    transactionID: transactionID,
                    deviceID: boundaryResult.physicalDeviceID ?? deviceID,
                    captureGeneration: boundaryResult.captureGeneration,
                    source: "CaptureLifecycleController.requestBroadcastOpticalHandoff",
                    reason: "Outgoing lens did not physically settle at the shared 1x boundary: \(boundaryResult.statusText)"
                )
            }
            return false
        }
        let boundaryPhysicalZoomText: String
        if let appliedPhysicalZoom = boundaryResult.appliedPhysicalZoom {
            boundaryPhysicalZoomText = String(appliedPhysicalZoom)
        } else {
            boundaryPhysicalZoomText = "unknown"
        }
        RinkLensStructuredEventLogger.shared.record(
            domain: .cameraControl,
            event: "camera_zoom_outgoing_lens_boundary_ramp_settled",
            entityID: boundaryResult.physicalDeviceID ?? deviceID,
            previous: ["lastAppliedAcknowledgement": String(Double(outgoingAppliedZoom))],
            next: [
                "boundaryZoom": String(Double(opticalBoundaryZoom)),
                "desiredZoom": String(Double(requested)),
                "physicalZoom": boundaryPhysicalZoomText
            ],
            source: source,
            reason: "Outgoing lens physically acknowledged at the shared visual boundary",
            captureGeneration: boundaryResult.captureGeneration,
            authoritativeOwner: "CaptureLifecycleController"
        )

        let continuityBoundarySequence = RinkLensFrameHub.shared.diagnosticSnapshot().broadcast.sequence
        let continuityBoundaryUptime = DispatchTime.now().uptimeNanoseconds
        let continuityDeviceID = boundaryResult.physicalDeviceID ?? deviceID
        let continuityFrame = await captureEngine.captureBroadcastPreviewContinuityImage()
        let continuityPresented: Bool
        if let continuityFrame,
           RinkLensBroadcastPreviewContinuityAdmission.admits(
                evidence: continuityFrame.evidence,
                afterSequence: continuityBoundarySequence,
                afterUptimeNanoseconds: continuityBoundaryUptime,
                requiredCaptureGeneration: boundaryResult.captureGeneration,
                requiredPhysicalDeviceID: continuityDeviceID,
                currentCaptureGeneration: captureEngine.snapshot.transitionGeneration,
                currentPhysicalDeviceID: captureEngine.snapshot.liveDeviceID
           ) {
            let displayPassCommitted = await RinkLensBroadcastPreviewContinuityStore.shared.beginHold(
                transactionID: transactionID,
                image: continuityFrame.image
            )
            let afterPresentation = captureEngine.snapshot
            continuityPresented = displayPassCommitted
                && afterPresentation.transitionGeneration == boundaryResult.captureGeneration
                && afterPresentation.liveDeviceID == continuityDeviceID
            if displayPassCommitted && !continuityPresented {
                RinkLensBroadcastPreviewContinuityStore.shared.endHold(transactionID: transactionID)
            }
        } else {
            continuityPresented = false
        }
        guard continuityPresented else {
            let compensated = await compensateOutgoingZoomAfterRejectedHandoff(
                transactionID: transactionID,
                requestedAppliedZoom: outgoingAppliedZoom,
                animated: animated,
                duration: duration,
                source: "Restore outgoing zoom after preview continuity rejection",
                zoomStore: zoomStore
            )
            if compensated {
                zoomStore.cancelLiveLensTransaction(
                    transactionID: transactionID,
                    deviceID: boundaryResult.physicalDeviceID ?? deviceID,
                    captureGeneration: boundaryResult.captureGeneration,
                    source: "CaptureLifecycleController.requestBroadcastOpticalHandoff",
                    reason: "Persistent Broadcast preview did not acknowledge the transaction-owned continuity frame"
                )
            }
            RinkLensStructuredEventLogger.shared.record(
                domain: .cameraControl,
                event: "camera_lens_continuity_presentation_rejected",
                entityID: transactionID.uuidString,
                source: "CaptureLifecycleController.requestBroadcastOpticalHandoff",
                reason: "Lens replacement was blocked because exact post-boundary frame evidence and a visible preview display pass were not both acknowledged",
                authoritativeOwner: "CaptureLifecycleController"
            )
            return false
        }
        RinkLensStructuredEventLogger.shared.record(
            domain: .cameraControl,
            event: "camera_lens_continuity_display_pass_acknowledged",
            entityID: transactionID.uuidString,
            source: "ExternalOCRMultiCamPreviewHostView",
            reason: "Persistent preview CALayer completed a transaction-matched visible display pass before branch replacement; physical scanout remains an iPad acceptance boundary",
            authoritativeOwner: "CaptureLifecycleController"
        )
        defer {
            RinkLensBroadcastPreviewContinuityStore.shared.endHold(
                transactionID: transactionID
            )
        }

        let intent = RinkLensBroadcastLensContractIntent(
            transactionID: transactionID,
            target: target,
            requestedZoom: Double(opticalBoundaryZoom),
            previousRequestedZoom: Double(outgoingAppliedZoom),
            mode: snapshot.activeMode,
            source: source,
            animated: animated,
            duration: duration
        )
        return await applyBroadcastLensContract(intent, zoomStore: zoomStore).succeeded
    }

    func shouldSubmitReconciliation(for request: RinkLensCaptureLifecycleRequest) -> Bool {
        let enriched = enrichedRequest(request)
        if RinkLensRecordingCaptureLease.shared.snapshot().isActive,
           !RinkLensRecordingCaptureLease.shared.allows(enriched) {
            deferRequestDuringRecordingLease(enriched, source: "reconciliation gate")
            return false
        }
        let desired = desiredContract(for: enriched)
        guard authoritativeDesiredContract == desired else { return true }
        if satisfiedOutcome(for: enriched) != nil { return false }
        if retainedDegradedFallbackOutcome(for: enriched) != nil { return false }
        if lifecycleOperationInFlight || captureEngine.isTransitioningSnapshot { return false }
        let now = DispatchTime.now().uptimeNanoseconds
        return now &- lastReconciliationAttemptUptimeNanoseconds >= minimumIdenticalContractRetryIntervalNanoseconds
    }


    /// UX16c46 health observations are deliberately separate from lifecycle
    /// intent. A healthy graph clears divergence without registering a request;
    /// an unhealthy graph must remain divergent for the sustained window before
    /// the unchanged desired contract is reconciled.
    func reconcileAfterSustainedHealthDivergence(
        _ request: RinkLensCaptureLifecycleRequest,
        health: RinkLensCaptureHealthSnapshot
    ) async -> RinkLensCaptureLifecycleOutcome? {
        let enriched = enrichedRequest(request)
        let desired = desiredContract(for: enriched)
        let now = DispatchTime.now().uptimeNanoseconds

        guard now &- lastHealthObservationUptimeNanoseconds >= minimumHealthObservationIntervalNanoseconds else {
            healthObservationSuppressionCount &+= 1
            return nil
        }
        lastHealthObservationUptimeNanoseconds = now
        healthObservationCount &+= 1

        guard authoritativeDesiredContract == desired else {
            clearHealthDivergence()
            clearDeadBranchRecoveryEpisode(reason: "desired contract changed")
            return nil
        }
        if health.isHealthy || retainedDegradedFallbackOutcome(for: enriched) != nil {
            clearHealthDivergence()
            clearDeadBranchRecoveryEpisode(reason: "fresh branch frames restored")
            return nil
        }
        guard !lifecycleOperationInFlight, !captureEngine.isTransitioningSnapshot, !deadBranchRecoveryInFlight else {
            healthObservationSuppressionCount &+= 1
            return nil
        }

        if healthDivergenceContract != desired {
            healthDivergenceContract = desired
            healthDivergenceStartedAtUptimeNanoseconds = now
            if !deadBranchEpisodeActive {
                deadBranchEpisodeActive = true
                deadBranchOCRReconnectAttempted = false
                deadBranchGraphRebuildAttempted = false
                lastDeadBranchRecoveryText = "observing silent branch: \(health.diagnosticText)"
                trace("UX16d2d \(lastDeadBranchRecoveryText)")
            }
            return nil
        }
        let recordingActive = RinkLensRecordingCaptureLease.shared.isRecordingActive()
            || RinkLensRecordingCaptureLease.shared.isWriterContractOpen()
        let requiredDivergenceInterval = sustainedHealthDivergenceIntervalNanoseconds
        guard now &- healthDivergenceStartedAtUptimeNanoseconds >= requiredDivergenceInterval else {
            return nil
        }

        let action = RinkLensCaptureDeadBranchRecoveryPolicy.action(for: .init(
            mode: enriched.mode,
            liveHealthy: health.live.isHealthy,
            ocrHealthy: health.ocr.isHealthy,
            ocrStructurallyReady: health.ocr.isStructurallyReady,
            recordingActive: recordingActive,
            ocrReconnectAttempted: deadBranchOCRReconnectAttempted,
            graphRebuildAttempted: deadBranchGraphRebuildAttempted
        ))

        switch action {
        case .none:
            clearHealthDivergence()
            clearDeadBranchRecoveryEpisode(reason: "policy healthy")
            return nil

        case .reconnectOCR:
            deadBranchRecoveryInFlight = true
            deadBranchOCRReconnectAttempted = true
            deadBranchOCRReconnectCount &+= 1
            sustainedHealthReconciliationCount &+= 1
            let result = await captureEngine.recoverSilentOCRBranch(
                reason: "sustained stale OCR frame health={\(health.ocr.diagnosticText)}",
                freshFrameTimeout: 1.75
            )
            deadBranchRecoveryInFlight = false
            lastDeadBranchRecoveryText = "OCR reconnect #\(deadBranchOCRReconnectCount): \(result.disposition.rawValue) \(result.diagnosticText)"
            trace("UX16d2d \(lastDeadBranchRecoveryText)")
            if result.recovered {
                clearHealthDivergence()
                return successOutcome(
                    request: enriched, resolvedMode: health.mode, changed: false, usedFallback: false,
                    status: "OCR frame delivery recovered without rebuilding Broadcast"
                )
            }
            healthDivergenceStartedAtUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
            return nil

        case .rebuildGraph:
            guard !recordingActive else {
                deadBranchRecoverySuppressionCount &+= 1
                captureEngine.markOCRBranchRecoveryDeferredDuringRecording(reason: "full graph recovery blocked by recording lease")
                return nil
            }
            deadBranchRecoveryInFlight = true
            deadBranchGraphRebuildAttempted = true
            deadBranchGraphRebuildCount &+= 1
            sustainedHealthReconciliationCount &+= 1
            let revision = latestIntentRevision
            let acquired = await acquireLifecycleOperation(revision: revision)
            guard acquired else {
                deadBranchRecoveryInFlight = false
                deadBranchRecoverySuppressionCount &+= 1
                return nil
            }
            lastSatisfiedRequest = nil
            lastSatisfiedOutcome = nil
            _ = await execute(
                .stopped(reason: "UX16d2d one-shot dead-branch graph rebuild stop"),
                revision: revision, enforceLatestIntent: false
            )
            RinkLensFrameHub.shared.clearAll(reason: "UX16d2d dead-branch graph rebuild")
            captureEngine.resetFailureLatch(reason: "UX16d2d dead-branch graph rebuild")
            let outcome = await execute(
                RinkLensCaptureLifecycleRequest(
                    mode: enriched.mode,
                    liveLogicalSourceID: enriched.liveLogicalSourceID,
                    ocrLogicalSourceID: enriched.ocrLogicalSourceID,
                    liveDeviceID: enriched.liveDeviceID,
                    ocrDeviceID: enriched.ocrDeviceID,
                    liveFormat: enriched.liveFormat,
                    ocrFormat: enriched.ocrFormat,
                    allowBroadcastFallback: enriched.allowBroadcastFallback,
                            recordingLeaseOverride: .none,
                    reason: "UX16d2d one-shot dead-branch graph rebuild start"
                ),
                revision: revision
            )
            releaseLifecycleOperation()
            deadBranchRecoveryInFlight = false
            lastDeadBranchRecoveryText = "graph rebuild #\(deadBranchGraphRebuildCount): success=\(outcome.succeeded) resolved=\(outcome.resolvedMode.rawValue)"
            trace("UX16d2d \(lastDeadBranchRecoveryText)")
            if outcome.succeeded { clearHealthDivergence() }
            return outcome

        case .preserveBroadcastRecording:
            if deadBranchRecordingDeferralPublished {
                healthObservationSuppressionCount &+= 1
                return nil
            }
            deadBranchRecordingDeferralPublished = true
            deadBranchRecoverySuppressionCount &+= 1
            lastDeadBranchRecoveryText = "silent branch recovery deferred while recording; Broadcast lease preserved"
            captureEngine.markOCRBranchRecoveryDeferredDuringRecording(reason: lastDeadBranchRecoveryText)
            RinkLensStructuredEventLogger.shared.record(
                domain: .capture,
                event: "ocr_recovery_deferred_for_recording",
                entityID: "ocr-branch",
                previous: [
                    "recordingActive": "true",
                    "liveHealthy": String(health.live.isHealthy),
                    "ocrHealthy": String(health.ocr.isHealthy)
                ],
                next: [
                    "captureMutation": "none",
                    "broadcastLease": "preserved",
                    "recovery": "deferred"
                ],
                source: "RinkLensCaptureLifecycleController",
                reason: lastDeadBranchRecoveryText,
                captureGeneration: captureEngine.snapshot.transitionGeneration
            )
            trace("UX16d2d \(lastDeadBranchRecoveryText)")
            return nil

        case .suppress:
            deadBranchRecoverySuppressionCount &+= 1
            lastDeadBranchRecoveryText = "dead-branch recovery suppressed after bounded attempts health={\(health.diagnosticText)}"
            return nil
        }
    }

    private func clearDeadBranchRecoveryEpisode(reason: String) {
        guard deadBranchEpisodeActive
                || deadBranchOCRReconnectAttempted
                || deadBranchGraphRebuildAttempted else { return }
        deadBranchEpisodeActive = false
        deadBranchOCRReconnectAttempted = false
        deadBranchGraphRebuildAttempted = false
        deadBranchRecoveryInFlight = false
        deadBranchRecordingDeferralPublished = false
        lastDeadBranchRecoveryText = "cleared: \(reason)"
    }

    private func clearHealthDivergence() {
        healthDivergenceContract = nil
        healthDivergenceStartedAtUptimeNanoseconds = 0
    }

    /// Recovery G: when the running Broadcast branch already satisfies the
    /// desired physical device and exact format, an absent OCR constituent is not
    /// a capture-session restart request. The lifecycle owner asks CaptureEngine
    /// for one OCR-branch-only convergence and returns that result directly. This
    /// prevents route assertions from undoing Recovery E's branch isolation.
    private func convergeOCRBranchOnlyIfApplicable(
        _ request: RinkLensCaptureLifecycleRequest
    ) async -> RinkLensCaptureLifecycleOutcome? {
        let active = captureEngine.snapshot
        guard request.mode == .dualCamera,
              active.activeMode == .broadcastOnly,
              active.isActive,
              active.sessionRunning,
              !active.isTransitioning,
              let activeLiveDeviceID = active.liveDeviceID,
              physicalIdentitySatisfied(
                activePhysicalID: activeLiveDeviceID,
                preferredPhysicalID: request.liveDeviceID,
                logicalSourceID: request.liveLogicalSourceID,
                service: liveService
              ),
              request.liveFormat == nil || active.liveFormat == request.liveFormat else {
            return nil
        }

        let generationBefore = active.transitionGeneration
        guard let requestedOCRDeviceID = request.ocrDeviceID else {
            RinkLensStructuredEventLogger.shared.record(
                domain: .capture,
                event: "capture_ocr_branch_convergence_preserved_broadcast",
                entityID: "ocr-unresolved",
                previous: [
                    "mode": active.activeMode.rawValue,
                    "generation": String(generationBefore),
                    "broadcastDevice": activeLiveDeviceID
                ],
                next: [
                    "mode": active.activeMode.rawValue,
                    "broadcastPreserved": "true",
                    "ocrBranch": "unresolved",
                    "sessionRestarted": "false"
                ],
                source: "CaptureLifecycleController.convergeOCRBranchOnlyIfApplicable",
                reason: "Desired OCR branch has no resolved physical device; full graph rebuild is not a valid recovery",
                captureGeneration: generationBefore,
                authoritativeOwner: "CaptureLifecycleController"
            )
            return successOutcome(
                request: request,
                resolvedMode: .broadcastOnly,
                changed: false,
                usedFallback: true,
                status: "OCR unavailable — Broadcast remains active"
            )
        }

        let desired = desiredContract(for: request)
        let beforeSequence = RinkLensFrameHub.shared.diagnosticSnapshot().ocr.sequence
        RinkLensStructuredEventLogger.shared.record(
            domain: .capture,
            event: "capture_ocr_branch_convergence_requested",
            entityID: requestedOCRDeviceID,
            previous: [
                "mode": active.activeMode.rawValue,
                "generation": String(generationBefore),
                "broadcastDevice": activeLiveDeviceID,
                "broadcastFormat": active.liveFormat?.diagnosticText ?? "none"
            ],
            next: [
                "requestedMode": request.mode.rawValue,
                "ocrDevice": requestedOCRDeviceID,
                "mutationScope": "ocr-branch-only"
            ],
            source: "CaptureLifecycleController.convergeOCRBranchOnlyIfApplicable",
            reason: request.reason,
            captureGeneration: generationBefore,
            authoritativeOwner: "CaptureLifecycleController"
        )

        let branchResult = await captureEngine.convergeOCRBranchPreservingBroadcast(
            requestedOCRDeviceID: requestedOCRDeviceID,
            desiredContract: desired,
            reason: request.reason
        )
        let after = captureEngine.snapshot

        guard branchResult.succeeded else {
            RinkLensStructuredEventLogger.shared.record(
                domain: .capture,
                event: "capture_ocr_branch_convergence_preserved_broadcast",
                entityID: requestedOCRDeviceID,
                previous: [
                    "mode": active.activeMode.rawValue,
                    "generation": String(generationBefore)
                ],
                next: [
                    "mode": after.activeMode.rawValue,
                    "generation": String(after.transitionGeneration),
                    "broadcastPreserved": "true",
                    "sessionRestarted": "false",
                    "ocrBranch": "unavailable"
                ],
                source: "CaptureLifecycleController.convergeOCRBranchOnlyIfApplicable",
                reason: branchResult.statusText,
                captureGeneration: after.transitionGeneration,
                authoritativeOwner: "CaptureLifecycleController"
            )
            return successOutcome(
                request: request,
                resolvedMode: .broadcastOnly,
                changed: false,
                usedFallback: true,
                status: branchResult.statusText
            )
        }

        let freshOCR = await RinkLensFrameHub.shared.waitForFreshFrameEvidence(
            for: .ocr,
            maxAge: 0.45,
            afterSequence: beforeSequence,
            requiredCaptureGeneration: after.transitionGeneration,
            requiredPhysicalDeviceID: requestedOCRDeviceID,
            timeout: 1.5
        )
        let verified = freshOCR != nil
        let settled = captureEngine.snapshot
        RinkLensStructuredEventLogger.shared.record(
            domain: .capture,
            event: "capture_ocr_branch_convergence_completed",
            entityID: requestedOCRDeviceID,
            previous: [
                "mode": active.activeMode.rawValue,
                "generation": String(generationBefore)
            ],
            next: [
                "mode": settled.activeMode.rawValue,
                "generation": String(settled.transitionGeneration),
                "broadcastGenerationPreserved": String(settled.transitionGeneration == generationBefore),
                "ocrFreshFrameVerified": String(verified),
                "sessionRestarted": "false"
            ],
            source: "CaptureLifecycleController.convergeOCRBranchOnlyIfApplicable",
            reason: branchResult.statusText,
            captureGeneration: settled.transitionGeneration,
            authoritativeOwner: "CaptureLifecycleController"
        )

        if verified, let satisfied = satisfiedOutcome(for: request) {
            return satisfied
        }
        return .init(
            requestedMode: request.mode,
            resolvedMode: settled.activeMode,
            succeeded: verified && settled.sessionRunning && settled.activeMode == .dualCamera,
            changedOwnership: true,
            usedFallback: !verified,
            selectionRolledBack: false,
            wasSuperseded: false,
            statusText: verified ? "OCR branch attached; Broadcast preserved" : "OCR branch attached; awaiting a fresh OCR frame while Broadcast remains active",
            liveZoom: Double(liveService.currentZoomFactor),
            ocrZoom: settled.activeMode.requiresOCR ? Double(ocrService.currentZoomFactor) : nil
        )
    }

    /// RecordingEngine calls this only after RecordingWriter has physically
    /// closed the current file contract. CaptureLifecycleController remains the
    /// transaction owner; CaptureEngine performs the one OCR-branch mutation.
    func convergeOCRBranchForRecordingContinuation(
        _ requirement: RinkLensOCRRecoveryRequirement
    ) async -> RinkLensOCRBranchRecoveryResult {
        let before = captureEngine.snapshot
        let topology = before.externalOCRTopology
        guard !RinkLensRecordingCaptureLease.shared.isWriterContractOpen() else {
            return .init(
                requestedDeviceID: requirement.deviceID,
                topologyRevision: requirement.topologyRevision,
                captureGeneration: before.transitionGeneration,
                structurallyAttached: false,
                freshFrameVerified: false,
                broadcastPreserved: before.sessionRunning && before.activeMode.requiresBroadcast,
                statusText: "Writer contract remains open; OCR convergence rejected"
            )
        }
        guard topology.revision == requirement.topologyRevision,
              topology.isDiscoverable,
              topology.deviceID == requirement.deviceID,
              before.sessionRunning,
              before.activeMode.requiresBroadcast,
              before.liveDeviceID != nil,
              let desired = before.effectiveContract?.desired else {
            return .init(
                requestedDeviceID: requirement.deviceID,
                topologyRevision: requirement.topologyRevision,
                captureGeneration: before.transitionGeneration,
                structurallyAttached: false,
                freshFrameVerified: false,
                broadcastPreserved: before.sessionRunning && before.activeMode.requiresBroadcast,
                statusText: "OCR recovery requirement is stale or Broadcast is not healthy"
            )
        }

        let sequenceBefore = RinkLensFrameHub.shared.diagnosticSnapshot().ocr.sequence
        let branch = await captureEngine.convergeOCRBranchPreservingBroadcast(
            requestedOCRDeviceID: requirement.deviceID,
            desiredContract: desired,
            reason: "Recording-safe OCR continuation topology=\(requirement.topologyRevision)"
        )
        let attached = captureEngine.snapshot
        let structurallyAttached = branch.succeeded
            && attached.sessionRunning
            && attached.activeMode == .dualCamera
            && attached.ocrDeviceID == requirement.deviceID
            && attached.transitionGeneration == before.transitionGeneration
        let freshEvidence = structurallyAttached
            ? await RinkLensFrameHub.shared.waitForFreshFrameEvidence(
                for: .ocr,
                maxAge: 0.45,
                afterSequence: sequenceBefore,
                requiredCaptureGeneration: attached.transitionGeneration,
                requiredPhysicalDeviceID: requirement.deviceID,
                timeout: 1.5
            )
            : nil
        let verified = freshEvidence != nil
        if verified {
            captureEngine.acknowledgeOCRRecoveryRequirement(requirement)
        }
        let settled = captureEngine.snapshot
        let broadcastPreserved = settled.sessionRunning
            && settled.activeMode.requiresBroadcast
            && settled.liveDeviceID == before.liveDeviceID
            && settled.transitionGeneration == before.transitionGeneration

        RinkLensStructuredEventLogger.shared.record(
            domain: .capture,
            event: verified ? "ocr_recovery_branch_verified" : "ocr_recovery_branch_unverified",
            entityID: requirement.deviceID,
            previous: [
                "topologyRevision": String(requirement.topologyRevision),
                "captureGeneration": String(before.transitionGeneration),
                "writerContractOpen": "false"
            ],
            next: [
                "structurallyAttached": String(structurallyAttached),
                "freshFrameVerified": String(verified),
                "broadcastPreserved": String(broadcastPreserved)
            ],
            source: "CaptureLifecycleController.convergeOCRBranchForRecordingContinuation",
            reason: branch.statusText,
            captureGeneration: settled.transitionGeneration,
            authoritativeOwner: "CaptureLifecycleController"
        )

        return .init(
            requestedDeviceID: requirement.deviceID,
            topologyRevision: requirement.topologyRevision,
            captureGeneration: settled.transitionGeneration,
            structurallyAttached: structurallyAttached,
            freshFrameVerified: verified,
            broadcastPreserved: broadcastPreserved,
            statusText: verified ? "OCR branch verified; Broadcast preserved" : branch.statusText
        )
    }

    func ensure(_ request: RinkLensCaptureLifecycleRequest) async -> RinkLensCaptureLifecycleOutcome {
        let enriched = enrichedRequest(request)
        let recordingProtectionAtEntry = RinkLensRecordingCaptureLease.shared.isRecordingActive()
            || RinkLensRecordingCaptureLease.shared.isWriterContractOpen()
        if recordingProtectionAtEntry,
           enriched.recordingLeaseOverride == .none,
           !RinkLensRecordingCaptureLease.shared.allows(enriched) {
            deferRequestDuringRecordingLease(enriched, source: "ensure-entry")
            RinkLensRecordingCaptureLease.shared.noteBlocked(enriched)
            return recordingLeaseRetainedOutcome(for: enriched)
        }
        let registration = registerIntent(enriched)
        let revision = registration.revision

        if !registration.changed {
            if let satisfied = satisfiedOutcome(for: enriched) {
                coalescedRequestCount &+= 1
                return satisfied
            }
            if let degraded = retainedDegradedFallbackOutcome(for: enriched) {
                coalescedRequestCount &+= 1
                return degraded
            }
            if lifecycleOperationInFlight {
                // An identical caller is asking for the acknowledgement of the
                // transaction already owned by this controller. Join the serial
                // lifecycle boundary below; returning a synthetic failed outcome
                // here made Relay commit `failed` milliseconds before the route
                // transaction physically installed the OCR branch.
            } else if captureEngine.isTransitioningSnapshot {
                identicalContractSuppressionCount &+= 1
                return coalescedInFlightOutcome(for: enriched)
            } else if DispatchTime.now().uptimeNanoseconds &- lastReconciliationAttemptUptimeNanoseconds < minimumIdenticalContractRetryIntervalNanoseconds {
                identicalContractSuppressionCount &+= 1
                return coalescedInFlightOutcome(for: enriched)
            }
        }

        if !lifecycleOperationInFlight,
           !captureEngine.isTransitioningSnapshot,
           let satisfied = satisfiedOutcome(for: enriched),
           isCurrentIntent(revision) {
            coalescedRequestCount &+= 1
            return satisfied
        }

        // Recovery Q / RL-042: once no-op/satisfied projection has been ruled out,
        // an open final writer means this request would require capture mutation.
        // Defer it before lifecycle admission so route changes cannot queue an OCR
        // branch attach behind the writer. The latest desired intent is already
        // registered above and writer-close replay will recompute current truth.
        if RinkLensRecordingCaptureLease.shared.isWriterContractOpen(),
           enriched.recordingLeaseOverride == .none {
            return deferMutationForOpenWriterContract(
                enriched,
                source: "ensure-pre-admission-writer-contract",
                recordingProtectedAtRequest: recordingProtectionAtEntry
            )
        }

        let acquired = await acquireLifecycleOperation(revision: revision)
        guard acquired else {
            return abandonedOutcome(for: enriched, revision: revision, boundary: "superseded lifecycle waiter")
        }
        defer { releaseLifecycleOperation() }

        guard isCurrentIntent(revision) else {
            return abandonedOutcome(for: enriched, revision: revision, boundary: "lifecycle queue")
        }

        // Another identical request may have completed while this caller waited.
        if let satisfied = satisfiedOutcome(for: enriched) {
            coalescedRequestCount &+= 1
            return satisfied
        }

        // Recovery Q / RL-042: the final writer contract is a hard mutation
        // boundary for every ordinary lifecycle requester. Recovery O already
        // defers USB-driven OCR restoration and Recovery P defers manual recovery;
        // route/Image Relay/preview/health reconciliation must not retain a
        // separate OCR-branch convergence exception. Explicit teardown/error
        // overrides remain typed; the optical same-file handoff uses its separate
        // CaptureLifecycleController transaction and does not enter ensure().
        if RinkLensRecordingCaptureLease.shared.isWriterContractOpen(),
           enriched.recordingLeaseOverride == .none {
            return deferMutationForOpenWriterContract(
                enriched,
                source: "ensure-post-wait-writer-contract-revalidation",
                recordingProtectedAtRequest: recordingProtectionAtEntry
            )
        }

        // Recovery H / RL-044 remains the boundary for an active recording lease
        // in the unusual interval where no final writer contract is open. The
        // branch-only convergence path is retained only for that non-writer case;
        // it can no longer mutate OCR while a final writer/file exists.
        let recordingProtectedNow = RinkLensRecordingCaptureLease.shared.isRecordingActive()
        if recordingProtectedNow, enriched.recordingLeaseOverride == .none {
            if RinkLensRecordingCaptureLease.shared.allows(enriched),
               let branchOnly = await convergeOCRBranchOnlyIfApplicable(enriched) {
                if branchOnly.succeeded && branchOnly.resolvedMode == enriched.mode {
                    lastSatisfiedRequest = enriched
                    lastSatisfiedOutcome = branchOnly
                }
                return branchOnly
            }
            deferRequestDuringRecordingLease(enriched, source: "ensure-post-wait-revalidation")
            RinkLensRecordingCaptureLease.shared.noteBlocked(enriched)
            RinkLensStructuredEventLogger.shared.record(
                domain: .capture,
                event: "capture_recording_lease_revalidation_blocked",
                entityID: enriched.mode.rawValue,
                previous: [
                    "recordingProtectedAtRequest": String(recordingProtectionAtEntry),
                    "writerContractOpen": "false"
                ],
                next: [
                    "captureMutation": "none",
                    "requestDeferred": "true",
                    "broadcastPreserved": "true"
                ],
                source: "CaptureLifecycleController.ensure",
                reason: "RL-044 request lost mutation authority while waiting: \(enriched.reason)",
                captureGeneration: captureEngine.snapshot.transitionGeneration,
                authoritativeOwner: "CaptureLifecycleController"
            )
            return recordingLeaseRetainedOutcome(for: enriched)
        }

        if let branchOnly = await convergeOCRBranchOnlyIfApplicable(enriched) {
            if branchOnly.succeeded && branchOnly.resolvedMode == enriched.mode {
                lastSatisfiedRequest = enriched
                lastSatisfiedOutcome = branchOnly
            }
            return branchOnly
        }

        lastReconciliationAttemptUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        reconciliationExecutionCount &+= 1
        let outcome = await execute(enriched, revision: revision)
        guard isCurrentIntent(revision) else {
            return abandonedOutcome(for: enriched, revision: revision, boundary: "command completion")
        }
        if outcome.succeeded {
            lastSatisfiedRequest = enriched
            lastSatisfiedOutcome = outcome
        }
        return outcome
    }

    /// Performs a camera or exact-format change as one serialized transaction.
    /// UX16c41 stages the requested selection before disrupting the active graph,
    /// then chooses the least invasive valid path: no-op, live cadence mutation,
    /// or a full stop-reconfigure-resume transaction.
    func reconfigureActiveCapture(
        reason: String,
        applySelection: @MainActor () -> RinkLensCaptureReconfigurationPlan
    ) async -> RinkLensCaptureLifecycleOutcome {
        let placeholder = RinkLensCaptureLifecycleRequest.stopped(reason: "atomic reconfiguration intent: \(reason)")
        if RinkLensRecordingCaptureLease.shared.isRecordingActive()
            || RinkLensRecordingCaptureLease.shared.isWriterContractOpen() {
            RinkLensRecordingCaptureLease.shared.noteBlocked(placeholder)
            return recordingLeaseRetainedOutcome(for: placeholder)
        }
        let revision = registerMutationIntent(reason: reason)
        let acquired = await acquireLifecycleOperation(revision: revision)
        guard acquired else {
            return abandonedOutcome(for: placeholder, revision: revision, boundary: "superseded atomic waiter")
        }
        defer { releaseLifecycleOperation() }

        guard isCurrentIntent(revision) else {
            return abandonedOutcome(for: placeholder, revision: revision, boundary: "atomic reconfiguration queue")
        }
        if RinkLensRecordingCaptureLease.shared.isRecordingActive()
            || RinkLensRecordingCaptureLease.shared.isWriterContractOpen() {
            RinkLensRecordingCaptureLease.shared.noteBlocked(placeholder)
            RinkLensStructuredEventLogger.shared.record(
                domain: .capture,
                event: "capture_atomic_reconfiguration_recording_revalidation_blocked",
                entityID: "atomic-reconfiguration",
                previous: ["waitedForLifecycleOperation": "true"],
                next: ["captureMutation": "none", "broadcastPreserved": "true"],
                source: "CaptureLifecycleController.reconfigureActiveCapture",
                reason: "Recording ownership changed while the atomic camera transaction was waiting: \(reason)",
                captureGeneration: captureEngine.snapshot.transitionGeneration,
                authoritativeOwner: "CaptureLifecycleController"
            )
            return recordingLeaseRetainedOutcome(for: placeholder)
        }

        atomicReconfigurationCount &+= 1
        let previousEngineSnapshot = captureEngine.snapshot
        let previousLiveSelection = liveService.captureSelectionSnapshot()
        let previousOCRSelection = ocrService.captureSelectionSnapshot()
        let wasActive = previousEngineSnapshot.isActive
            || previousEngineSnapshot.isTransitioning
            || previousEngineSnapshot.sessionConfigured
        let previousMode = previousEngineSnapshot.activeMode
        let rollbackRequest = requestForEngineSnapshot(
            previousEngineSnapshot,
            reason: "rollback previous graph after: \(reason)"
        )
        trace("atomic reconfiguration #\(atomicReconfigurationCount) staged-before-stop mode=\(previousMode.rawValue) reason=\(reason)")

        // Stage first. A rejected picker value must not stop a healthy graph.
        let plan = applySelection()
        guard isCurrentIntent(revision) else {
            restoreSelectionWithoutGraphMutation(
                previousLiveSelection: previousLiveSelection,
                previousOCRSelection: previousOCRSelection,
                reason: "Selection transaction superseded before graph mutation"
            )
            return abandonedOutcome(for: placeholder, revision: revision, boundary: "selection staging")
        }
        guard plan.stagedSuccessfully else {
            restoreSelectionWithoutGraphMutation(
                previousLiveSelection: previousLiveSelection,
                previousOCRSelection: previousOCRSelection,
                reason: plan.failureStatus ?? "Camera or format staging failed"
            )
            return .init(
                requestedMode: plan.request?.mode ?? previousMode,
                resolvedMode: previousMode,
                succeeded: false,
                changedOwnership: false,
                usedFallback: false,
                selectionRolledBack: true,
                wasSuperseded: false,
                statusText: "Camera/format change was rejected before the active graph was changed: \(plan.failureStatus ?? "staging failed")",
                liveZoom: previousMode.requiresBroadcast ? Double(liveService.currentZoomFactor) : nil,
                ocrZoom: previousMode.requiresOCR ? Double(ocrService.currentZoomFactor) : nil
            )
        }

        guard let resumeRequest = plan.request else {
            let stoppedRequest = RinkLensCaptureLifecycleRequest.stopped(reason: "selection requested capture stop: \(reason)")
            latestIntentRequest = stoppedRequest
            authoritativeDesiredContract = desiredContract(for: stoppedRequest)
            if wasActive {
                RinkLensCaptureGraphMutationAudit.shared.record(.fullGraphRebuild, detail: "selection requested capture stop: \(reason)")
                _ = await execute(stoppedRequest, revision: revision)
                RinkLensFrameHub.shared.clearAll(reason: "capture stopped after selection: \(reason)")
            }
            return .init(
                requestedMode: .stopped,
                resolvedMode: .stopped,
                succeeded: true,
                changedOwnership: wasActive,
                usedFallback: false,
                selectionRolledBack: false,
                wasSuperseded: false,
                statusText: "Camera selection staged",
                liveZoom: nil,
                ocrZoom: nil
            )
        }

        let enriched = enrichedRequest(resumeRequest)
        latestIntentRequest = enriched
        authoritativeDesiredContract = desiredContract(for: enriched)

        guard wasActive || previousMode != .stopped else {
            RinkLensCaptureGraphMutationAudit.shared.record(.noGraphChange, detail: "selection stored while capture was stopped: \(reason)")
            trace("atomic reconfiguration selection stored; capture was already stopped")
            return .init(
                requestedMode: enriched.mode,
                resolvedMode: .stopped,
                succeeded: true,
                changedOwnership: false,
                usedFallback: false,
                selectionRolledBack: false,
                wasSuperseded: false,
                statusText: "Camera selection stored; capture remains stopped",
                liveZoom: nil,
                ocrZoom: nil
            )
        }

        switch RinkLensCaptureGraphMutationPolicy.decision(active: previousEngineSnapshot, requested: enriched) {
        case .noGraphChange:
            RinkLensCaptureGraphMutationAudit.shared.record(.noGraphChange, detail: reason)
            if let satisfied = satisfiedOutcome(for: enriched) {
                lastSatisfiedRequest = enriched
                lastSatisfiedOutcome = satisfied
                return satisfied
            }
            // Typed state did not validate despite an apparently identical request;
            // use the full transactional path rather than assuming success.
            RinkLensCaptureGraphMutationAudit.shared.record(.fullGraphRebuild, detail: "typed no-op validation failed: \(reason)")

        case .liveCadence:
            if RinkLensRecordingCaptureLease.shared.isRecordingActive()
                || RinkLensRecordingCaptureLease.shared.isWriterContractOpen() {
                RinkLensRecordingCaptureLease.shared.noteBlocked(enriched)
                return recordingLeaseRetainedOutcome(for: enriched)
            }
            let liveApplied = await captureEngine.applyLiveCadenceMutation(
                mode: enriched.mode,
                liveRequestedDeviceID: enriched.mode.requiresBroadcast ? previousEngineSnapshot.liveDeviceID : nil,
                ocrRequestedDeviceID: enriched.mode.requiresOCR ? previousEngineSnapshot.ocrDeviceID : nil,
                liveFormatPreference: enriched.liveFormat,
                ocrFormatPreference: enriched.ocrFormat,
                reason: reason
            )
            guard isCurrentIntent(revision) else {
                return abandonedOutcome(for: enriched, revision: revision, boundary: "live cadence mutation")
            }
            if liveApplied, let satisfied = satisfiedOutcome(for: enriched) {
                RinkLensCaptureGraphMutationAudit.shared.record(.liveCadence, detail: reason)
                lastSatisfiedRequest = enriched
                lastSatisfiedOutcome = satisfied
                var result = satisfied
                result.statusText = "Frame cadence applied live without rebuilding the capture graph"
                return result
            }
            RinkLensCaptureGraphMutationAudit.shared.record(.fullGraphRebuild, detail: "live cadence unavailable; transactional fallback: \(reason)")

        case .fullGraphRebuild(let rebuildReason):
            RinkLensCaptureGraphMutationAudit.shared.record(.fullGraphRebuild, detail: "\(rebuildReason): \(reason)")
        }

        // Camera, mode or resolution changes—and any failed live cadence attempt—
        // use the existing complete rollback-capable transaction.
        if wasActive {
            _ = await execute(
                .stopped(reason: "atomic reconfiguration stop: \(reason)"),
                revision: revision
            )
            guard isCurrentIntent(revision) else {
                return abandonedOutcome(for: enriched, revision: revision, boundary: "atomic stop")
            }
        }
        RinkLensFrameHub.shared.clearAll(reason: "full capture graph reconfiguration: \(reason)")
        lastSatisfiedRequest = nil
        lastSatisfiedOutcome = nil

        captureEngine.resetFailureLatch(reason: "atomic reconfiguration: \(reason)")
        let outcome = await execute(enriched, revision: revision)
        guard isCurrentIntent(revision) else {
            return await rollbackSelectionTransaction(
                requestedMode: enriched.mode,
                reason: "Capture activation superseded by a newer request",
                previousLiveSelection: previousLiveSelection,
                previousOCRSelection: previousOCRSelection,
                rollbackRequest: rollbackRequest,
                wasActive: wasActive
            )
        }
        let exactTransactionSuccess = outcome.succeeded
            && !outcome.usedFallback
            && outcome.resolvedMode == enriched.mode
            && satisfiedOutcome(for: enriched) != nil
        guard exactTransactionSuccess else {
            return await rollbackSelectionTransaction(
                requestedMode: enriched.mode,
                reason: outcome.statusText.isEmpty
                    ? "New camera/format contract did not become active"
                    : outcome.statusText,
                previousLiveSelection: previousLiveSelection,
                previousOCRSelection: previousOCRSelection,
                rollbackRequest: rollbackRequest,
                wasActive: wasActive
            )
        }

        lastSatisfiedRequest = enriched
        lastSatisfiedOutcome = outcome
        trace("atomic full rebuild committed requested=\(enriched.mode.rawValue) resolved=\(outcome.resolvedMode.rawValue)")
        return outcome
    }

    private func restoreSelectionWithoutGraphMutation(
        previousLiveSelection: HockeyCameraService.CaptureSelectionSnapshot,
        previousOCRSelection: HockeyCameraService.CaptureSelectionSnapshot,
        reason: String
    ) {
        liveService.restoreCaptureSelectionSnapshot(previousLiveSelection, reason: reason)
        ocrService.restoreCaptureSelectionSnapshot(previousOCRSelection, reason: reason)
        lastSatisfiedRequest = nil
        lastSatisfiedOutcome = nil
        trace("selection restored without graph mutation reason=\(reason)")
    }

    /// Recovery T / RL-053: enqueue the real background stop behind the prior
    /// scene transaction. The ViewModel may prepare UI state synchronously, but
    /// it no longer creates an independent camera Task.
    func enqueueAppBackgroundSuspend(
        reason: String,
        completion: @escaping @MainActor (RinkLensCaptureLifecycleOutcome) -> Void
    ) {
        sceneLifecycleSequence &+= 1
        let sequence = sceneLifecycleSequence
        let predecessor = sceneLifecycleTask
        sceneLifecycleTask = Task { @MainActor [weak self] in
            if let predecessor {
                await predecessor.value
            }
            guard let self else { return }

            let before = self.captureEngine.snapshot
            self.trace("Recovery T scene transaction #\(sequence) background stop admitted only after predecessor completion phase=\(before.phase.rawValue) running=\(before.sessionRunning)")
            RinkLensStructuredEventLogger.shared.record(
                domain: .capture,
                event: "capture_scene_background_transaction_started",
                entityID: String(sequence),
                previous: [
                    "phase": before.phase.rawValue,
                    "mode": before.activeMode.rawValue,
                    "sessionRunning": String(before.sessionRunning),
                    "generation": String(before.transitionGeneration)
                ],
                next: ["requestedMode": RinkLensCaptureLifecycleMode.stopped.rawValue],
                source: "CaptureLifecycleController.enqueueAppBackgroundSuspend",
                reason: reason,
                captureGeneration: before.transitionGeneration,
                authoritativeOwner: "CaptureLifecycleController"
            )

            let outcome = await self.ensure(
                .stopped(
                    reason: "app backgrounded: \(reason)",
                    recordingLeaseOverride: .appBackground
                )
            )
            let after = self.captureEngine.snapshot
            let physicallyStopped = !after.sessionConfigured
                && !after.sessionRunning
                && !after.isActive
                && !after.isTransitioning
            let publishedOutcome: RinkLensCaptureLifecycleOutcome
            if physicallyStopped {
                publishedOutcome = .init(
                    requestedMode: .stopped,
                    resolvedMode: .stopped,
                    succeeded: true,
                    changedOwnership: outcome.changedOwnership,
                    usedFallback: false,
                    selectionRolledBack: outcome.selectionRolledBack,
                    wasSuperseded: false,
                    statusText: after.statusText,
                    liveZoom: nil,
                    ocrZoom: nil
                )
            } else {
                publishedOutcome = outcome
            }

            RinkLensStructuredEventLogger.shared.record(
                domain: .capture,
                event: "capture_scene_background_transaction_completed",
                entityID: String(sequence),
                previous: [
                    "phase": before.phase.rawValue,
                    "generation": String(before.transitionGeneration)
                ],
                next: [
                    "outcomeSucceeded": String(publishedOutcome.succeeded),
                    "resolvedMode": publishedOutcome.resolvedMode.rawValue,
                    "phase": after.phase.rawValue,
                    "mode": after.activeMode.rawValue,
                    "sessionRunning": String(after.sessionRunning),
                    "generation": String(after.transitionGeneration)
                ],
                source: "CaptureLifecycleController.enqueueAppBackgroundSuspend",
                reason: publishedOutcome.statusText,
                captureGeneration: after.transitionGeneration,
                authoritativeOwner: "CaptureLifecycleController"
            )
            completion(publishedOutcome)
            if self.sceneLifecycleSequence == sequence {
                self.sceneLifecycleTask = nil
            }
        }
    }

    /// Recovery T / RL-053: foreground recovery is chained after the exact
    /// background task above. `requestProvider` is evaluated only after that
    /// stop has finished, so current route, camera identities and formats are
    /// re-read at the transaction boundary rather than captured before it.
    func enqueueAppBackgroundWake(
        reason: String,
        requestProvider: @escaping @MainActor () -> RinkLensCaptureLifecycleRequest,
        completion: @escaping @MainActor (RinkLensCaptureLifecycleOutcome) -> Void
    ) {
        sceneLifecycleSequence &+= 1
        let sequence = sceneLifecycleSequence
        let predecessor = sceneLifecycleTask
        sceneLifecycleTask = Task { @MainActor [weak self] in
            if let predecessor {
                await predecessor.value
            }
            guard let self else { return }

            // Scene-background failure state is transient. It is cleared here,
            // after the ordered stop boundary, not synchronously from the
            // presentation layer while CaptureEngine may still be stopping.
            if self.captureEngine.isFailureLatchedSnapshot
                || self.captureEngine.degradedRecordSnapshot != nil {
                self.captureEngine.resetFailureLatch(
                    reason: "Recovery T ordered foreground recovery cleared scene-suspension failure"
                )
                self.captureEngine.clearDegradedRecord(
                    reason: "Recovery T ordered foreground recovery"
                )
            }

            let request = requestProvider()
            let before = self.captureEngine.snapshot
            self.trace("Recovery T scene transaction #\(sequence) wake admitted after background transaction phase=\(before.phase.rawValue) running=\(before.sessionRunning) requested=\(request.mode.rawValue)")
            let outcome = await self.reassertAfterWake(request, reason: reason)
            completion(outcome)
            if self.sceneLifecycleSequence == sequence {
                self.sceneLifecycleTask = nil
            }
        }
    }

    private func reassertAfterWake(
        _ request: RinkLensCaptureLifecycleRequest,
        reason: String
    ) async -> RinkLensCaptureLifecycleOutcome {
        let before = captureEngine.snapshot
        RinkLensStructuredEventLogger.shared.record(
            domain: .capture,
            event: "capture_wake_reassert_requested",
            entityID: request.mode.rawValue,
            previous: [
                "phase": before.phase.rawValue,
                "mode": before.activeMode.rawValue,
                "sessionRunning": String(before.sessionRunning),
                "generation": String(before.transitionGeneration),
                "liveCallbackAgeSeconds": before.liveLastCallbackAgeSeconds.map { String(format: "%.3f", $0) } ?? "none",
                "ocrCallbackAgeSeconds": before.ocrLastCallbackAgeSeconds.map { String(format: "%.3f", $0) } ?? "none"
            ],
            next: [
                "requestedMode": request.mode.rawValue,
                "liveDevice": request.liveDeviceID ?? "none",
                "ocrDevice": request.ocrDeviceID ?? "none"
            ],
            source: "CaptureLifecycleController.reassertAfterWake",
            reason: reason,
            captureGeneration: before.transitionGeneration,
            authoritativeOwner: "CaptureLifecycleController"
        )
        let ensuredOutcome = await ensure(request)
        // The completion projection must describe physical CaptureEngine truth.
        // If the requested graph is now satisfied, a stale/superseded intermediate
        // outcome cannot report `stopped/false` beside a running verified graph.
        let outcome = satisfiedOutcome(for: request) ?? ensuredOutcome
        let after = captureEngine.snapshot
        RinkLensStructuredEventLogger.shared.record(
            domain: .capture,
            event: "capture_wake_reassert_completed",
            entityID: request.mode.rawValue,
            previous: [
                "phase": before.phase.rawValue,
                "mode": before.activeMode.rawValue,
                "generation": String(before.transitionGeneration)
            ],
            next: [
                "outcomeSucceeded": String(outcome.succeeded),
                "resolvedMode": outcome.resolvedMode.rawValue,
                "phase": after.phase.rawValue,
                "mode": after.activeMode.rawValue,
                "sessionRunning": String(after.sessionRunning),
                "generation": String(after.transitionGeneration),
                "liveCallbackAgeSeconds": after.liveLastCallbackAgeSeconds.map { String(format: "%.3f", $0) } ?? "none",
                "ocrCallbackAgeSeconds": after.ocrLastCallbackAgeSeconds.map { String(format: "%.3f", $0) } ?? "none"
            ],
            source: "CaptureLifecycleController.reassertAfterWake",
            reason: reason,
            captureGeneration: after.transitionGeneration,
            authoritativeOwner: "CaptureLifecycleController"
        )
        return outcome
    }

    /// Recovery AI / RL-076: preview repair remains inside the capture owner.
    /// When current-generation callbacks prove the physical branch is healthy,
    /// only the retained preview AVCaptureConnection is rebuilt. No stop/start,
    /// failure-latch reset or capture-generation mutation is permitted here.
    func recoverPreviewEndpointIfPhysicalBranchHealthy(
        role: RinkLensCapturePreviewRole,
        reason: String
    ) async -> Bool {
        let before = captureEngine.snapshot
        let recovered = await captureEngine.recoverPreviewEndpointIfCaptureHealthy(
            role: role,
            maximumCallbackAge: 1.0,
            reason: reason
        )
        if recovered {
            let after = captureEngine.snapshot
            RinkLensStructuredEventLogger.shared.record(
                domain: .capture,
                event: "capture_preview_only_recovery_committed",
                entityID: role.displayName,
                previous: [
                    "mode": before.activeMode.rawValue,
                    "phase": before.phase.rawValue,
                    "generation": String(before.transitionGeneration)
                ],
                next: [
                    "mode": after.activeMode.rawValue,
                    "phase": after.phase.rawValue,
                    "generation": String(after.transitionGeneration),
                    "graphRestarted": "false"
                ],
                source: "CaptureLifecycleController.recoverPreviewEndpointIfPhysicalBranchHealthy",
                reason: reason,
                captureGeneration: after.transitionGeneration,
                authoritativeOwner: "CaptureLifecycleController"
            )
        }
        return recovered
    }

    func recover(
        mode: RinkLensCaptureLifecycleMode,
        liveDeviceID: String?,
        ocrDeviceID: String?,
        reason: String
    ) async -> RinkLensCaptureLifecycleOutcome {
        let recoveryRequest = RinkLensCaptureLifecycleRequest(
            mode: mode,
            liveDeviceID: liveDeviceID,
            ocrDeviceID: ocrDeviceID,
            liveFormat: liveService.captureFormatPreferenceSnapshot(),
            ocrFormat: ocrService.captureFormatPreferenceSnapshot(),
            allowBroadcastFallback: mode == .dualCamera,
            reason: "controlled recovery start: \(reason)"
        )

        // Recovery P / RL-042: an operator Recover Preview action is not a
        // privileged camera owner. Recovery O already defers automatic USB OCR
        // reconnect while the final writer contract is open; the same hard
        // boundary must apply to manual Camera Control/OCR recovery. Do this
        // before clearing failure state so a blocked recovery has zero capture
        // side effects. Writer-close replay recomputes fresh current-route intent.
        if RinkLensRecordingCaptureLease.shared.isWriterContractOpen() {
            deferRequestDuringRecordingLease(
                recoveryRequest,
                source: "operator-recovery-writer-contract-open"
            )
            RinkLensRecordingCaptureLease.shared.noteBlocked(recoveryRequest)
            let snapshot = captureEngine.snapshot
            RinkLensStructuredEventLogger.shared.record(
                domain: .capture,
                event: "capture_operator_recovery_deferred_writer_contract_open",
                entityID: mode.rawValue,
                previous: [
                    "activeMode": snapshot.activeMode.rawValue,
                    "generation": String(snapshot.transitionGeneration),
                    "writerContractOpen": "true"
                ],
                next: [
                    "captureMutation": "none",
                    "failureLatchMutation": "none",
                    "requestDeferred": "true",
                    "restoreTrigger": "writer-close lifecycle replay"
                ],
                source: "CaptureLifecycleController.recover",
                reason: reason,
                captureGeneration: snapshot.transitionGeneration,
                authoritativeOwner: "CaptureLifecycleController"
            )
            return recordingLeaseRetainedOutcome(for: recoveryRequest)
        }

        captureEngine.resetFailureLatch(reason: "operator recovery: \(reason)")
        let stopOutcome = await ensure(.stopped(reason: "controlled recovery stop: \(reason)"))
        guard stopOutcome.succeeded, stopOutcome.resolvedMode == .stopped else {
            let snapshot = captureEngine.snapshot
            RinkLensStructuredEventLogger.shared.record(
                domain: .capture,
                event: "capture_operator_recovery_stop_not_committed",
                entityID: mode.rawValue,
                previous: [
                    "stopSucceeded": String(stopOutcome.succeeded),
                    "stopResolvedMode": stopOutcome.resolvedMode.rawValue
                ],
                next: [
                    "captureMutation": "none-after-uncommitted-stop",
                    "restartSubmitted": "false"
                ],
                source: "CaptureLifecycleController.recover",
                reason: "A preserved/blocked Broadcast graph is not a physically stopped graph. \(reason)",
                captureGeneration: snapshot.transitionGeneration,
                authoritativeOwner: "CaptureLifecycleController"
            )
            return stopOutcome
        }
        return await ensure(recoveryRequest)
    }

    /// Explicit operator action that clears the failed-contract cooldown and
    /// retries the exact dual-camera contract recorded at degradation time.
    /// A new failure recreates the record and safely returns to Broadcast-only.
    func retryDegradedCapture(reason: String) async -> RinkLensCaptureLifecycleOutcome {
        guard let record = captureEngine.degradedRecordSnapshot else {
            return .blocked(
                .stopped(reason: reason),
                status: "No degraded capture contract is waiting for retry"
            )
        }

        let retryRequest = record.failedContract.request(
            allowBroadcastFallback: record.failedContract.mode == .dualCamera,
            reason: "operator retry: \(reason)"
        )
        guard !RinkLensRecordingCaptureLease.shared.isRecordingActive() else {
            return .blocked(
                retryRequest,
                status: "Failed camera contract retry is blocked while recording"
            )
        }
        captureEngine.clearDegradedRecord(reason: "operator retry requested: \(reason)")
        captureEngine.resetFailureLatch(reason: "operator retry requested: \(reason)")
        lastSatisfiedRequest = nil
        lastSatisfiedOutcome = nil
        trace("operator retry exact failed contract {\(record.failedContract.diagnosticText)}")
        return await ensure(retryRequest)
    }

    func stopMultiCam(reason: String) async -> RinkLensCaptureLifecycleOutcome {
        await ensure(.stopped(reason: reason))
    }

    /// Camera selection changes must stop only the authoritative engine. The
    /// compatibility services keep their logical selections and never release or
    /// rebuild a second AVCaptureSession graph.
    func releaseAllForReconfiguration(reason: String) async -> RinkLensCaptureLifecycleOutcome {
        let outcome = await ensure(.stopped(reason: reason))
        if outcome.succeeded, outcome.resolvedMode == .stopped {
            RinkLensFrameHub.shared.clearAll(reason: "capture engine reconfiguration: \(reason)")
        } else if RinkLensRecordingCaptureLease.shared.snapshot().isActive {
            trace("UX16c45 FrameHub clear suppressed because recording capture lease retained Broadcast: \(reason)")
        }
        return outcome
    }

    // Recovery Q / RL-042: one common writer-open deferral path for every
    // ordinary lifecycle request. This owns no extra pending state; it records the
    // already-existing latest deferred request and relies on writer-close replay.
    private func deferMutationForOpenWriterContract(
        _ request: RinkLensCaptureLifecycleRequest,
        source: String,
        recordingProtectedAtRequest: Bool
    ) -> RinkLensCaptureLifecycleOutcome {
        deferRequestDuringRecordingLease(request, source: source)
        RinkLensRecordingCaptureLease.shared.noteBlocked(request)
        let snapshot = captureEngine.snapshot
        RinkLensStructuredEventLogger.shared.record(
            domain: .capture,
            event: "capture_lifecycle_mutation_deferred_writer_contract_open",
            entityID: request.mode.rawValue,
            previous: [
                "activeMode": snapshot.activeMode.rawValue,
                "generation": String(snapshot.transitionGeneration),
                "recordingProtectedAtRequest": String(recordingProtectedAtRequest),
                "writerContractOpen": "true"
            ],
            next: [
                "captureMutation": "none",
                "ocrBranchMutation": "none",
                "requestDeferred": "true",
                "restoreTrigger": "writer-close lifecycle replay"
            ],
            source: "CaptureLifecycleController.ensure",
            reason: "RL-042 writer contract forbids ordinary capture/OCR convergence: \(request.reason)",
            captureGeneration: snapshot.transitionGeneration,
            authoritativeOwner: "CaptureLifecycleController"
        )
        return recordingLeaseRetainedOutcome(for: request)
    }

    private func deferRequestDuringRecordingLease(
        _ request: RinkLensCaptureLifecycleRequest,
        source: String
    ) {
        if deferredRecordingLeaseRequest == request { return }
        deferredRecordingLeaseRequest = request
        recordingLeaseDeferredRequestCount &+= 1
        trace("UX16c53 deferred latest capture contract while recording lease active source=\(source) mode=\(request.mode.rawValue) reason=\(request.reason)")
    }

    /// UX16d2c discards historical route intent when the recording lease ends.
    /// The ViewModel immediately recomputes a fresh request from the current route,
    /// current camera selections and current OCR preference.
    func discardDeferredRecordingLeaseRequest(reason: String) -> RinkLensCaptureLifecycleRequest? {
        guard !RinkLensRecordingCaptureLease.shared.snapshot().isActive else { return nil }
        let discarded = deferredRecordingLeaseRequest
        deferredRecordingLeaseRequest = nil
        recordingLeaseReplayCount &+= 1
        trace(
            "UX16d2c recording lease release reconciliation #\(recordingLeaseReplayCount): discarded stale deferred={\(discarded.map { "mode=\($0.mode.rawValue) reason=\($0.reason)" } ?? "none")} reason=\(reason)"
        )
        return discarded
    }

    private func recordingLeaseRetainedOutcome(
        for request: RinkLensCaptureLifecycleRequest
    ) -> RinkLensCaptureLifecycleOutcome {
        let snapshot = captureEngine.snapshot
        let lease = RinkLensRecordingCaptureLease.shared.snapshot()
        trace("UX16c45 recording lease retained Broadcast graph; blocked mode=\(request.mode.rawValue) reason=\(request.reason)")
        return .init(
            requestedMode: request.mode,
            resolvedMode: snapshot.activeMode,
            succeeded: snapshot.activeMode.requiresBroadcast && snapshot.sessionRunning,
            changedOwnership: false,
            usedFallback: false,
            selectionRolledBack: false,
            wasSuperseded: false,
            statusText: "Recording capture lease retained the Broadcast source. Request blocked: \(request.reason). Lease: \(lease.diagnosticText)",
            liveZoom: nil,
            ocrZoom: nil
        )
    }

    private func enrichedRequest(_ request: RinkLensCaptureLifecycleRequest) -> RinkLensCaptureLifecycleRequest {
        var value = request

        // Recovery CO / RL-207: route requests already carry the camera-selection
        // owner's resolved logical/physical identities. Do not perform a second
        // AVCaptureDevice discovery/capability scan here: this controller is
        // MainActor-isolated, and the duplicate synchronous discovery produced the
        // measured 18.1s Production Setup stall before CaptureEngine.start().
        // Only fill genuinely missing identity from the camera-service projection;
        // CaptureEngine remains the sole physical graph/capability validator.
        if value.mode.requiresOCR {
            if value.ocrLogicalSourceID == nil || value.ocrDeviceID == nil {
                let identity = ocrService.captureIdentitySnapshot()
                if value.ocrLogicalSourceID == nil { value.ocrLogicalSourceID = identity.selectedLogicalSourceID }
                if value.ocrDeviceID == nil { value.ocrDeviceID = identity.preferredResolvedPhysicalDeviceID }
            }
        } else {
            value.ocrLogicalSourceID = nil
            value.ocrDeviceID = nil
            value.ocrFormat = nil
        }

        if value.mode.requiresBroadcast {
            if value.liveLogicalSourceID == nil || value.liveDeviceID == nil {
                let identity = liveService.captureIdentitySnapshot()
                if value.liveLogicalSourceID == nil { value.liveLogicalSourceID = identity.selectedLogicalSourceID }
                if value.liveDeviceID == nil { value.liveDeviceID = identity.preferredResolvedPhysicalDeviceID }
            }

            // Preserve the controller-owned effective contract across route
            // assertions. No hardware discovery occurs at this boundary.
            if let desired = authoritativeDesiredContract,
               desired.mode.requiresBroadcast,
               desired.liveLogicalSourceID == value.liveLogicalSourceID {
                value.liveDeviceID = desired.livePreferredDeviceID
                value.liveFormat = desired.liveFormat
            } else if value.liveFormat == nil,
                      RinkLensRiskFeaturePolicy.isEnabled(.broadcastAdaptiveCameraQualityV17),
                      value.liveLogicalSourceID == HockeyCameraService.builtInBackCameraSourceID {
                let policy = broadcastImageQualityPolicyProvider()
                let targetFPS = value.liveDeviceID.map {
                    preferredBroadcastFPS(policy: policy, physicalDeviceID: $0)
                } ?? policy.preferredWideFPS
                value.liveFormat = RinkLensCaptureFormatPreference(
                    width: 1920,
                    height: 1080,
                    fps: targetFPS
                )
            }
            if value.liveLogicalSourceID == HockeyCameraService.builtInBackCameraSourceID,
               let physicalDeviceID = value.liveDeviceID,
               let format = value.liveFormat {
                let policy = broadcastImageQualityPolicyProvider()
                value.liveFormat = RinkLensBroadcastOpticalFormatPolicy.preferredFormat(
                    wantsHalfX: liveService.broadcastPhysicalDeviceID(
                        physicalDeviceID,
                        satisfiesHalfXTarget: true
                    ),
                    currentFormat: format,
                    productionFPS: policy.preferredWideFPS
                )
            }
        } else {
            value.liveLogicalSourceID = nil
            value.liveDeviceID = nil
            value.liveFormat = nil
        }
        return value
    }

    private func desiredContract(for request: RinkLensCaptureLifecycleRequest) -> RinkLensDesiredCaptureContract {
        RinkLensDesiredCaptureContract(
            mode: request.mode,
            liveLogicalSourceID: request.mode.requiresBroadcast ? request.liveLogicalSourceID : nil,
            ocrLogicalSourceID: request.mode.requiresOCR ? request.ocrLogicalSourceID : nil,
            livePreferredDeviceID: request.mode.requiresBroadcast ? request.liveDeviceID : nil,
            ocrPreferredDeviceID: request.mode.requiresOCR ? request.ocrDeviceID : nil,
            liveFormat: request.mode.requiresBroadcast ? request.liveFormat : nil,
            ocrFormat: request.mode.requiresOCR ? request.ocrFormat : nil
        )
    }

    private func requestForEngineSnapshot(
        _ snapshot: RinkLensCaptureEngineSnapshot,
        reason: String
    ) -> RinkLensCaptureLifecycleRequest? {
        let mode = snapshot.activeMode
        guard mode != .stopped, snapshot.sessionConfigured else { return nil }
        return RinkLensCaptureLifecycleRequest(
            mode: mode,
            liveLogicalSourceID: mode.requiresBroadcast ? snapshot.effectiveContract?.desired.liveLogicalSourceID : nil,
            ocrLogicalSourceID: mode.requiresOCR ? snapshot.effectiveContract?.desired.ocrLogicalSourceID : nil,
            liveDeviceID: mode.requiresBroadcast ? (snapshot.effectiveContract?.desired.livePreferredDeviceID ?? snapshot.liveDeviceID) : nil,
            ocrDeviceID: mode.requiresOCR ? (snapshot.effectiveContract?.desired.ocrPreferredDeviceID ?? snapshot.ocrDeviceID) : nil,
            liveFormat: mode.requiresBroadcast ? snapshot.liveFormat : nil,
            ocrFormat: mode.requiresOCR ? snapshot.ocrFormat : nil,
            allowBroadcastFallback: false,
            reason: reason
        )
    }

    private func rollbackSelectionTransaction(
        requestedMode: RinkLensCaptureLifecycleMode,
        reason: String,
        previousLiveSelection: HockeyCameraService.CaptureSelectionSnapshot,
        previousOCRSelection: HockeyCameraService.CaptureSelectionSnapshot,
        rollbackRequest: RinkLensCaptureLifecycleRequest?,
        wasActive: Bool
    ) async -> RinkLensCaptureLifecycleOutcome {
        liveService.restoreCaptureSelectionSnapshot(
            previousLiveSelection,
            reason: reason
        )
        ocrService.restoreCaptureSelectionSnapshot(
            previousOCRSelection,
            reason: reason
        )
        RinkLensFrameHub.shared.clearAll(reason: "UX16c37 selection rollback: \(reason)")
        lastSatisfiedRequest = nil
        lastSatisfiedOutcome = nil

        guard wasActive, let rollbackRequest else {
            trace("selection rollback restored facade state; previous capture was stopped reason=\(reason)")
            return .init(
                requestedMode: requestedMode,
                resolvedMode: .stopped,
                succeeded: false,
                changedOwnership: false,
                usedFallback: false,
                selectionRolledBack: true,
                wasSuperseded: false,
                statusText: "Camera/format change failed and the previous stored selection was restored: \(reason)",
                liveZoom: nil,
                ocrZoom: nil
            )
        }

        captureEngine.resetFailureLatch(reason: "UX16c37 transactional rollback")
        let rollbackOutcome = await execute(
            rollbackRequest,
            revision: latestIntentRevision,
            enforceLatestIntent: false
        )
        if rollbackOutcome.succeeded,
           !rollbackOutcome.usedFallback,
           satisfiedOutcome(for: rollbackRequest) != nil {
            lastSatisfiedRequest = rollbackRequest
            lastSatisfiedOutcome = rollbackOutcome
            trace("selection rollback restored previous graph mode=\(rollbackOutcome.resolvedMode.rawValue) reason=\(reason)")
            return .init(
                requestedMode: requestedMode,
                resolvedMode: rollbackOutcome.resolvedMode,
                succeeded: false,
                changedOwnership: true,
                usedFallback: false,
                selectionRolledBack: true,
                wasSuperseded: false,
                statusText: "Camera/format change failed; the previous CaptureEngine configuration was fully restored. \(reason)",
                liveZoom: rollbackOutcome.liveZoom,
                ocrZoom: rollbackOutcome.ocrZoom
            )
        }

        trace("selection rollback restored facade state but previous graph restart failed reason=\(reason) rollbackStatus=\(rollbackOutcome.statusText)")
        return .init(
            requestedMode: requestedMode,
            resolvedMode: rollbackOutcome.resolvedMode,
            succeeded: false,
            changedOwnership: true,
            usedFallback: rollbackOutcome.usedFallback,
            selectionRolledBack: true,
            wasSuperseded: false,
            statusText: "Camera/format change failed. Stored selections were restored, but the previous capture graph could not be restarted: \(rollbackOutcome.statusText)",
            liveZoom: rollbackOutcome.liveZoom,
            ocrZoom: rollbackOutcome.ocrZoom
        )
    }

    private func satisfiedOutcome(for request: RinkLensCaptureLifecycleRequest) -> RinkLensCaptureLifecycleOutcome? {
        let snapshot = captureEngine.snapshot
        if request.mode == .stopped {
            guard !snapshot.sessionConfigured, !snapshot.sessionRunning, !snapshot.isActive, !snapshot.isTransitioning else { return nil }
        } else {
            guard snapshot.isActive,
                  snapshot.sessionRunning,
                  snapshot.hasRequiredFirstFrames,
                  snapshot.activeMode == request.mode else { return nil }

            // UX16c53: never trust a copied desired contract as proof of the
            // physical input. Validate the actual AVCaptureDeviceInput identity
            // for every satisfied graph, while still accepting Apple-resolved
            // constituents of the same Back/Front/External logical source.
            if request.mode.requiresBroadcast {
                guard physicalIdentitySatisfied(
                    activePhysicalID: snapshot.liveDeviceID,
                    preferredPhysicalID: request.liveDeviceID,
                    logicalSourceID: request.liveLogicalSourceID,
                    service: liveService
                ) else { return nil }
            }
            if request.mode.requiresOCR {
                guard physicalIdentitySatisfied(
                    activePhysicalID: snapshot.ocrDeviceID,
                    preferredPhysicalID: request.ocrDeviceID,
                    logicalSourceID: request.ocrLogicalSourceID,
                    service: ocrService
                ) else { return nil }
            }
            if request.mode.requiresBroadcast, let format = request.liveFormat, snapshot.liveFormat != format { return nil }
            if request.mode.requiresOCR, let format = request.ocrFormat, snapshot.ocrFormat != format { return nil }
        }

        if let lastSatisfiedRequest, let lastSatisfiedOutcome,
           desiredContract(for: lastSatisfiedRequest) == desiredContract(for: request) {
            var result = lastSatisfiedOutcome
            result.changedOwnership = false
            return result
        }
        return successOutcome(
            request: request,
            resolvedMode: request.mode,
            changed: false,
            usedFallback: false,
            status: snapshot.statusText
        )
    }

    private func retainedDegradedFallbackOutcome(
        for request: RinkLensCaptureLifecycleRequest
    ) -> RinkLensCaptureLifecycleOutcome? {
        guard request.mode == .dualCamera, request.allowBroadcastFallback else { return nil }
        let key = RinkLensCaptureContractKey(
            mode: request.mode,
            liveDeviceID: request.liveDeviceID,
            ocrDeviceID: request.ocrDeviceID,
            liveFormat: request.liveFormat,
            ocrFormat: request.ocrFormat
        )
        guard let degraded = captureEngine.degradedRecord(matching: key), degraded.isCooldownActive else { return nil }

        // Recovery AB / RL-060: failed-contract cooldown protects against repeated
        // full MultiCam graph rebuilds. It must not suppress the branch-scoped OCR
        // convergence path when the retained Broadcast constituent can already pair
        // with the still-desired OCR device. Writer-contract protection remains in
        // ensure() before any mutation is admitted.
        let active = captureEngine.snapshot
        if active.activeMode == .broadcastOnly,
           active.sessionRunning,
           let activeLiveDeviceID = active.liveDeviceID,
           let desiredOCRDeviceID = request.ocrDeviceID,
           liveService.supportsSimultaneousCapturePair(
               livePhysicalDeviceID: activeLiveDeviceID,
               ocrPhysicalDeviceID: desiredOCRDeviceID
           ) {
            trace("Recovery AB degraded cooldown retained for full rebuild but branch-only OCR convergence admitted live=\(activeLiveDeviceID) ocr=\(desiredOCRDeviceID)")
            return nil
        }

        let fallback = RinkLensCaptureLifecycleRequest.broadcastOnly(
            liveLogicalSourceID: request.liveLogicalSourceID,
            liveDeviceID: request.liveDeviceID,
            liveFormat: request.liveFormat,
            reason: "retained degraded fallback"
        )
        guard satisfiedOutcome(for: fallback) != nil else { return nil }
        return successOutcome(
            request: request,
            resolvedMode: .broadcastOnly,
            changed: false,
            usedFallback: true,
            status: "OCR retry cooling down — Broadcast remains active"
        )
    }

    private func physicalIdentitySatisfied(
        activePhysicalID: String?,
        preferredPhysicalID: String?,
        logicalSourceID: String?,
        service: HockeyCameraService
    ) -> Bool {
        guard let activePhysicalID else { return false }
        if let preferredPhysicalID, activePhysicalID == preferredPhysicalID { return true }
        return service.physicalDeviceID(
            activePhysicalID,
            satisfiesLogicalSourceID: logicalSourceID
        )
    }

    private func execute(
        _ request: RinkLensCaptureLifecycleRequest,
        revision: UInt64,
        enforceLatestIntent: Bool = true
    ) async -> RinkLensCaptureLifecycleOutcome {
        trace("request #\(revision) mode=\(request.mode.rawValue) reason=\(request.reason)")
        if enforceLatestIntent, !isCurrentIntent(revision) {
            return abandonedOutcome(for: request, revision: revision, boundary: "execution start")
        }

        let recordingProtected = RinkLensRecordingCaptureLease.shared.isRecordingActive()
            || RinkLensRecordingCaptureLease.shared.isWriterContractOpen()
        if recordingProtected, request.recordingLeaseOverride == .none {
            RinkLensRecordingCaptureLease.shared.noteBlocked(request)
            _ = RinkLensRecordingCaptureLease.shared.allowMutation(
                action: "capture lifecycle \(request.mode.rawValue)",
                requester: "RinkLensCaptureLifecycleController.execute",
                owner: currentOwnerText
            )
            return .blocked(
                request,
                status: "Full capture lifecycle mutation blocked by the current recording writer contract: \(request.reason)"
            )
        }

        if enforceLatestIntent, !isCurrentIntent(revision) {
            return abandonedOutcome(for: request, revision: revision, boundary: "recording gate")
        }

        if request.mode == .stopped {
            let changed = captureEngine.isCaptureActiveSnapshot
                || captureEngine.isTransitioningSnapshot
                || captureEngine.snapshot.sessionConfigured
            await captureEngine.stop(reason: request.reason)
            if enforceLatestIntent, !isCurrentIntent(revision) {
                return abandonedOutcome(for: request, revision: revision, boundary: "capture stop")
            }
            trace("capture engine stopped reason=\(request.reason)")
            // Recovery AU / RL-100: only the capture owner can announce that
            // the live media-resource lease is physically free. MediaRepository
            // then decides whether its already-pinned queue can run; no route or
            // screen is allowed to resume opaque media work.
            RinkLensExecutionCoordinator.shared.notifyDeferredMediaEligibilityMayHaveChanged(
                reason: "CaptureLifecycleController verified stopped: \(request.reason)"
            )
            return .init(
                requestedMode: .stopped,
                resolvedMode: .stopped,
                succeeded: true,
                changedOwnership: changed,
                usedFallback: false,
                selectionRolledBack: false,
                wasSuperseded: false,
                statusText: "Capture stopped",
                liveZoom: nil,
                ocrZoom: nil
            )
        }

        if let satisfied = satisfiedOutcome(for: request) {
            return satisfied
        }

        if captureEngine.isTransitioningSnapshot {
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if enforceLatestIntent, !isCurrentIntent(revision) {
                    return abandonedOutcome(for: request, revision: revision, boundary: "in-flight transition wait")
                }
                if let satisfied = satisfiedOutcome(for: request) {
                    trace("in-flight transition satisfied full contract mode=\(request.mode.rawValue)")
                    return satisfied
                }
                if !captureEngine.snapshot.isTransitioning { break }
            }
        }

        if enforceLatestIntent, !isCurrentIntent(revision) {
            return abandonedOutcome(for: request, revision: revision, boundary: "capture start")
        }
        // Recovery CO / RL-207: a complete lifecycle request must not synchronously
        // join either camera-service output queue on MainActor immediately before
        // CaptureEngine.start(). Fall back to a camera-service identity snapshot
        // only for legacy/partial requests that genuinely omitted a device ID.
        let liveID: String?
        if request.mode.requiresBroadcast, request.liveDeviceID == nil {
            liveID = liveService.captureIdentitySnapshot().preferredResolvedPhysicalDeviceID
        } else {
            liveID = request.liveDeviceID
        }
        let ocrID: String?
        if request.mode.requiresOCR, request.ocrDeviceID == nil {
            ocrID = ocrService.captureIdentitySnapshot().preferredResolvedPhysicalDeviceID
        } else {
            ocrID = request.ocrDeviceID
        }
        let requestedContract = RinkLensCaptureContractKey(
            mode: request.mode,
            liveDeviceID: liveID,
            ocrDeviceID: ocrID,
            liveFormat: request.liveFormat,
            ocrFormat: request.ocrFormat
        )

        // A validated Broadcast fallback is already running for this exact
        // failed dual-camera contract. During cooldown, do not stop/rebuild it.
        if request.mode == .dualCamera,
           request.allowBroadcastFallback,
           let degraded = captureEngine.degradedRecord(matching: requestedContract),
           degraded.isCooldownActive {
            let fallbackRequest = RinkLensCaptureLifecycleRequest.broadcastOnly(
                liveLogicalSourceID: request.liveLogicalSourceID,
                liveDeviceID: liveID,
                liveFormat: request.liveFormat,
                reason: "retained degraded fallback during failed-contract cooldown"
            )
            if satisfiedOutcome(for: fallbackRequest) != nil {
                captureEngine.markDegradedFallbackActive(
                    status: "OCR retry cooling down — Broadcast remains active"
                )
                trace("suppressed exact failed contract during cooldown remaining=\(String(format: "%.1f", degraded.cooldownRemainingSeconds))s")
                return successOutcome(
                    request: request,
                    resolvedMode: .broadcastOnly,
                    changed: false,
                    usedFallback: true,
                    status: "OCR retry cooling down for \(String(format: "%.0f", ceil(degraded.cooldownRemainingSeconds)))s — Broadcast remains active"
                )
            }
        }

        let started = await captureEngine.start(
            mode: request.mode,
            liveLogicalSourceID: request.liveLogicalSourceID,
            ocrLogicalSourceID: request.ocrLogicalSourceID,
            liveRequestedDeviceID: liveID,
            ocrRequestedDeviceID: ocrID,
            liveFormatPreference: request.liveFormat,
            ocrFormatPreference: request.ocrFormat,
            reason: request.reason
        )

        if enforceLatestIntent, !isCurrentIntent(revision) {
            return abandonedOutcome(for: request, revision: revision, boundary: "first-frame readiness")
        }

        if started {
            if request.mode.requiresBroadcast {
                let policy = broadcastImageQualityPolicyProvider()
                let startedSnapshot = captureEngine.snapshot
                let nominalCadence: RinkLensCaptureCadence
                if request.liveLogicalSourceID == HockeyCameraService.builtInBackCameraSourceID,
                   let physicalDeviceID = startedSnapshot.liveDeviceID {
                    nominalCadence = .init(integerFPS: preferredBroadcastFPS(
                        policy: policy,
                        physicalDeviceID: physicalDeviceID
                    ))
                } else {
                    nominalCadence = request.liveFormat?.cadence
                        ?? RinkLensCaptureCadence(integerFPS: policy.preferredWideFPS)
                }
                let imagingApplied = await captureEngine.applyBroadcastImageQualityPolicy(
                    policy,
                    effectiveTargetCadence: nominalCadence,
                    reason: "Recovery CZ post-start physical imaging-profile reassertion: \(request.reason)",
                    recordingTransitionAuthorised: false
                )
                if imagingApplied == nil {
                    trace("Recovery CZ imaging profile could not be fully applied after CaptureEngine start policy=\(policy.rawValue) reason=\(request.reason)")
                }
            }
            guard let validated = satisfiedOutcome(for: request) else {
                let snapshot = captureEngine.snapshot
                trace("capture start returned true but contract validation failed requested=\(request.mode.rawValue) active=\(snapshot.healthSummary)")
                return .blocked(
                    request,
                    status: "Capture started but the active camera/format contract did not match the request"
                )
            }
            if request.mode == .dualCamera {
                captureEngine.clearDegradedRecord(reason: "dual-camera contract validated")
            }
            trace("capture engine active and contract validated mode=\(request.mode.rawValue) reason=\(request.reason)")
            var changed = validated
            changed.changedOwnership = true
            return changed
        }

        if enforceLatestIntent, !isCurrentIntent(revision) {
            return abandonedOutcome(for: request, revision: revision, boundary: "fallback decision")
        }

        if request.mode == .dualCamera, request.allowBroadcastFallback {
            let existingDegraded = captureEngine.degradedRecord(matching: requestedContract)
            if existingDegraded == nil || existingDegraded?.isCooldownActive == false {
                captureEngine.recordDegradedContract(
                    requestedContract,
                    fallbackMode: .broadcastOnly,
                    failureText: captureEngine.failureTextSnapshot
                )
            }
            captureEngine.resetFailureLatch(reason: "dual-camera failure; trying engine-owned Broadcast-only degradation")
            let fallbackRequest = RinkLensCaptureLifecycleRequest.broadcastOnly(
                liveLogicalSourceID: request.liveLogicalSourceID,
                liveDeviceID: liveID,
                liveFormat: request.liveFormat,
                reason: request.reason + " — capture-engine Broadcast-only fallback"
            )
            let fallbackStarted = await captureEngine.start(
                mode: .broadcastOnly,
                liveLogicalSourceID: request.liveLogicalSourceID,
                ocrLogicalSourceID: nil,
                liveRequestedDeviceID: liveID,
                ocrRequestedDeviceID: nil,
                liveFormatPreference: request.liveFormat,
                ocrFormatPreference: nil,
                recoveryPairedOCRDeviceID: ocrID,
                reason: fallbackRequest.reason
            )
            if enforceLatestIntent, !isCurrentIntent(revision) {
                return abandonedOutcome(for: request, revision: revision, boundary: "fallback readiness")
            }
            if fallbackStarted {
                let policy = broadcastImageQualityPolicyProvider()
                let fallbackSnapshot = captureEngine.snapshot
                let nominalCadence: RinkLensCaptureCadence
                if fallbackRequest.liveLogicalSourceID == HockeyCameraService.builtInBackCameraSourceID,
                   let physicalDeviceID = fallbackSnapshot.liveDeviceID {
                    nominalCadence = .init(integerFPS: preferredBroadcastFPS(
                        policy: policy,
                        physicalDeviceID: physicalDeviceID
                    ))
                } else {
                    nominalCadence = fallbackRequest.liveFormat?.cadence
                        ?? RinkLensCaptureCadence(integerFPS: policy.preferredWideFPS)
                }
                _ = await captureEngine.applyBroadcastImageQualityPolicy(
                    policy,
                    effectiveTargetCadence: nominalCadence,
                    reason: "Recovery CZ Broadcast-only fallback imaging-profile reassertion: \(fallbackRequest.reason)",
                    recordingTransitionAuthorised: false
                )
            }
            if fallbackStarted, satisfiedOutcome(for: fallbackRequest) != nil {
                captureEngine.markDegradedFallbackActive(
                    status: "OCR unavailable — Broadcast capture remains active"
                )
                trace("capture engine degraded to validated Broadcast-only contract reason=\(request.reason)")
                return successOutcome(
                    request: request,
                    resolvedMode: .broadcastOnly,
                    changed: true,
                    usedFallback: true,
                    status: "OCR unavailable — Broadcast capture remains active"
                )
            }
        }

        return .blocked(
            request,
            status: captureEngine.statusText.isEmpty
                ? "Capture engine activation failed"
                : captureEngine.statusText
        )
    }

    private func successOutcome(
        request: RinkLensCaptureLifecycleRequest,
        resolvedMode: RinkLensCaptureLifecycleMode,
        changed: Bool,
        usedFallback: Bool,
        status: String
    ) -> RinkLensCaptureLifecycleOutcome {
        .init(
            requestedMode: request.mode,
            resolvedMode: resolvedMode,
            succeeded: true,
            changedOwnership: changed,
            usedFallback: usedFallback,
            selectionRolledBack: false,
            wasSuperseded: false,
            statusText: status,
            liveZoom: resolvedMode.requiresBroadcast ? Double(liveService.currentZoomFactor) : nil,
            ocrZoom: resolvedMode.requiresOCR ? Double(ocrService.currentZoomFactor) : nil
        )
    }

    private func registerIntent(
        _ request: RinkLensCaptureLifecycleRequest
    ) -> (revision: UInt64, changed: Bool) {
        let desired = desiredContract(for: request)
        if authoritativeDesiredContract == desired {
            latestIntentRequest = request
            return (latestIntentRevision, false)
        }

        intentRevision &+= 1
        latestIntentRevision = intentRevision
        latestIntentRequest = request
        authoritativeDesiredContract = desired
        clearHealthDivergence()
        trace("desired contract revision #\(intentRevision) {\(desired.diagnosticText)} reason=\(request.reason)")
        return (intentRevision, true)
    }

    /// Atomic selection changes reserve a new reconciliation boundary without
    /// temporarily replacing the desired graph with a synthetic stopped request.
    private func registerMutationIntent(reason: String) -> UInt64 {
        intentRevision &+= 1
        latestIntentRevision = intentRevision
        trace("selection mutation revision #\(intentRevision) reason=\(reason)")
        return intentRevision
    }

    private func coalescedInFlightOutcome(
        for request: RinkLensCaptureLifecycleRequest
    ) -> RinkLensCaptureLifecycleOutcome {
        let activeMode = captureEngine.snapshot.activeMode
        return .init(
            requestedMode: request.mode,
            resolvedMode: activeMode,
            succeeded: false,
            changedOwnership: false,
            usedFallback: false,
            selectionRolledBack: false,
            wasSuperseded: true,
            statusText: "Identical desired capture contract is already active or reconciling",
            liveZoom: activeMode.requiresBroadcast ? Double(liveService.currentZoomFactor) : nil,
            ocrZoom: activeMode.requiresOCR ? Double(ocrService.currentZoomFactor) : nil
        )
    }

    private func isCurrentIntent(_ revision: UInt64) -> Bool {
        revision == latestIntentRevision
    }

    private func abandonedOutcome(
        for request: RinkLensCaptureLifecycleRequest,
        revision: UInt64,
        boundary: String
    ) -> RinkLensCaptureLifecycleOutcome {
        abandonedRequestCount &+= 1
        let activeMode = captureEngine.snapshot.activeMode
        let latestDescription = latestIntentRequest.map {
            "#\(latestIntentRevision) \($0.mode.rawValue)"
        } ?? "none"
        trace("abandoned stale request #\(revision) mode=\(request.mode.rawValue) boundary=\(boundary) latest=\(latestDescription) count=\(abandonedRequestCount)")
        return .init(
            requestedMode: request.mode,
            resolvedMode: activeMode,
            succeeded: false,
            changedOwnership: false,
            usedFallback: false,
            selectionRolledBack: false,
            wasSuperseded: true,
            statusText: "Capture request superseded by newer intent at \(boundary)",
            liveZoom: activeMode.requiresBroadcast ? Double(liveService.currentZoomFactor) : nil,
            ocrZoom: activeMode.requiresOCR ? Double(ocrService.currentZoomFactor) : nil
        )
    }

    private func acquireLifecycleOperation(revision: UInt64) async -> Bool {
        if !lifecycleOperationInFlight {
            lifecycleOperationInFlight = true
            return true
        }
        return await withCheckedContinuation { continuation in
            lifecycleWaiters.append(.init(revision: revision, continuation: continuation))
        }
    }

    /// Promote only the newest queued intent. Older waiters are resumed as
    /// abandoned without ever acquiring lifecycle ownership, avoiding FIFO replay
    /// of obsolete camera modes and format selections.
    private func releaseLifecycleOperation() {
        guard !lifecycleWaiters.isEmpty else {
            lifecycleOperationInFlight = false
            return
        }

        let winnerIndex = lifecycleWaiters.indices.max {
            lifecycleWaiters[$0].revision < lifecycleWaiters[$1].revision
        } ?? lifecycleWaiters.startIndex
        let winner = lifecycleWaiters.remove(at: winnerIndex)
        let stale = lifecycleWaiters
        lifecycleWaiters.removeAll(keepingCapacity: true)
        for waiter in stale {
            waiter.continuation.resume(returning: false)
        }
        winner.continuation.resume(returning: true)
    }

    private var currentOwnerText: String {
        if captureEngine.isCaptureActiveSnapshot || captureEngine.isTransitioningSnapshot {
            return "CaptureEngine"
        }
        return "none"
    }

    private func trace(_ message: String) {
        MainThreadStallMonitor.shared.traceCameraStartupTimeline(
            "UX16c38 CaptureLifecycleController \(message)"
        )
    }
}

#endif
