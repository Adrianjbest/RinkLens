// BUILD 713 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo

// MARK: - Build 785 Recovery AJ UI-independent scoreboard-frame execution

/// Value-only identity captured from a FrameHub frame before any MainActor work.
/// This deliberately contains no CVPixelBuffer reference or FrameHub lease.
nonisolated struct ScoreboardFrameIdentity: Sendable {
    let sequence: Int
    let captureGeneration: Int
    let physicalDeviceID: String?
    let capturedAt: Date
    let ageSeconds: TimeInterval
    let sizeText: String

    init(_ frame: RinkLensFrameHubFrame) {
        sequence = frame.sequence
        captureGeneration = frame.captureGeneration
        physicalDeviceID = frame.physicalDeviceID
        capturedAt = frame.capturedAt
        ageSeconds = frame.ageSeconds
        sizeText = frame.sizeText
    }
}

/// One processing-owned frame produced by the ingress lane. It is no longer
/// backed by the FrameHub six-surface lease, so MainActor delays cannot starve
/// physical capture.
nonisolated struct ScoreboardOwnedFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let identity: ScoreboardFrameIdentity

    var sequence: Int { identity.sequence }
    var captureGeneration: Int { identity.captureGeneration }
}

/// Capacity-one execution lane directly after FrameHub. Recovery AI fixed the
/// FrameHub lease boundary but still synchronously waited for MainActor before
/// live Image Relay work could start. Recovery AJ removes that dependency from
/// the production Image Relay path: the worker is an immutable configuration
/// projection prepared only when authoritative state changes, never per frame.
///
/// This object owns execution admission only. It never owns calibration, camera,
/// OCR, Image Relay or viewer state.
nonisolated final class ScoreboardFramePipeline: @unchecked Sendable {
    typealias PreparedFrameWork = @Sendable (ScoreboardOwnedFrame) -> Void
    typealias MainActorFramePreparation = @MainActor @Sendable (ScoreboardFrameIdentity) -> PreparedFrameWork?

    struct Snapshot: Sendable {
        let submitted: Int
        let executed: Int
        let replacedPending: Int
        let pendingSequence: Int?
        let isExecuting: Bool
        let ingressFrames: Int
        let preparedFrames: Int
        let droppedBeforeWork: Int
        let ingressOwnershipCopyFailures: Int
        let mainPreparationLastMilliseconds: Double
        let mainPreparationMaxMilliseconds: Double

        var diagnosticText: String {
            let pendingText = pendingSequence.map(String.init) ?? "none"
            return "submitted=\(submitted) executed=\(executed) replaced=\(replacedPending) pending=\(pendingText) executing=\(isExecuting) "
                + "ingress=\(ingressFrames) prepared=\(preparedFrames) droppedBeforeWork=\(droppedBeforeWork) copyFailures=\(ingressOwnershipCopyFailures) "
                + String(format: "legacyMainPreparationMs=%.1f/max:%.1f", mainPreparationLastMilliseconds, mainPreparationMaxMilliseconds)
        }
    }

    private struct Job: @unchecked Sendable {
        let sourceSequence: Int?
        let work: @Sendable () -> Void
    }


    private final class FrameLeaseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var frame: RinkLensFrameHubFrame?

        init(_ frame: RinkLensFrameHubFrame) { self.frame = frame }

        func take() -> RinkLensFrameHubFrame? {
            lock.lock(); defer { lock.unlock() }
            let value = frame
            frame = nil
            return value
        }
    }

    private let queue = DispatchQueue(label: "rinklens.scoreboard.frame-pipeline", qos: RinkLensExecutionQoSHierarchy.semantic)
    private let lock = NSLock()
    private let minimumAdmissionInterval: TimeInterval
    private var pending: Job?
    private var executing = false
    private var lastStartedAt: CFAbsoluteTime = 0
    private var submittedCount = 0
    private var executedCount = 0
    private var replacedPendingCount = 0
    private var ingressFrameCount = 0
    private var preparedFrameCount = 0
    private var droppedBeforeWorkCount = 0
    private var ingressOwnershipCopyFailureCount = 0
    private var mainPreparationLastMilliseconds = 0.0
    private var mainPreparationMaxMilliseconds = 0.0
    private var hasLoggedActivation = false

    init(minimumAdmissionInterval: TimeInterval = 0.30) {
        self.minimumAdmissionInterval = max(0.05, minimumAdmissionInterval)
    }

    /// General capacity-one work admission retained for non-frame callers.
    func submit(sourceSequence: Int?, work: @escaping @Sendable () -> Void) {
        var shouldSchedule = false
        var logActivation = false
        lock.lock()
        submittedCount &+= 1
        if pending != nil { replacedPendingCount &+= 1 }
        pending = Job(sourceSequence: sourceSequence, work: work)
        if !executing {
            executing = true
            shouldSchedule = true
        }
        if !hasLoggedActivation {
            hasLoggedActivation = true
            logActivation = true
        }
        lock.unlock()

        if logActivation {
            RinkLensStructuredEventLogger.shared.record(
                domain: .scoreboardPresentation,
                event: "scoreboard_frame_pipeline_activated",
                entityID: "scoreboard-frame-pipeline",
                previous: ["execution": "MainActor before capacity-one admission"],
                next: [
                    "execution": "capacity-one FrameHub ingress with direct immutable worker projection",
                    "minimumAdmissionSeconds": String(format: "%.2f", minimumAdmissionInterval)
                ],
                source: "ScoreboardFramePipeline",
                reason: "Recovery AJ removes the per-frame synchronous MainActor dependency from production Image Relay execution",
                authoritativeOwner: "ScoreboardFramePipeline"
            )
        }
        if shouldSchedule { scheduleNext() }
    }

    /// Recovery AJ / RL-078: production direct-frame path. The caller supplies
    /// an immutable worker projection that was prepared when authoritative state
    /// changed. No MainActor hop occurs between FrameHub admission and Image Relay.
    func submitFrame(
        _ frame: RinkLensFrameHubFrame,
        preparedWork: @escaping PreparedFrameWork
    ) {
        lock.lock()
        ingressFrameCount &+= 1
        lock.unlock()

        let identity = ScoreboardFrameIdentity(frame)
        let leaseBox = FrameLeaseBox(frame)
        submit(sourceSequence: frame.sequence) { [weak self, leaseBox, identity, preparedWork] in
            guard let ownedFrame = Self.makeOwnedFrameAndReleaseFrameHubLease(
                leaseBox,
                identity: identity
            ) else {
                self?.noteIngressOwnershipCopyFailure()
                return
            }
            self?.notePreparationResult(true, elapsedMilliseconds: 0)
            preparedWork(ownedFrame)
        }
    }

    /// Legacy OCR compatibility path. It is intentionally bounded but no longer
    /// blocks the worker with `DispatchQueue.main.sync`. Recovery AJ production
    /// Image Relay never enters this path.
    func submitFrameViaMainActorPreparation(
        _ frame: RinkLensFrameHubFrame,
        prepareOnMainActor: @escaping MainActorFramePreparation
    ) {
        lock.lock()
        ingressFrameCount &+= 1
        lock.unlock()

        let identity = ScoreboardFrameIdentity(frame)
        let leaseBox = FrameLeaseBox(frame)
        submit(sourceSequence: frame.sequence) { [weak self, leaseBox, identity, prepareOnMainActor] in
            guard let ownedFrame = Self.makeOwnedFrameAndReleaseFrameHubLease(
                leaseBox,
                identity: identity
            ) else {
                self?.noteIngressOwnershipCopyFailure()
                return
            }

            let started = CFAbsoluteTimeGetCurrent()
            Task { @MainActor [weak self] in
                let prepared = prepareOnMainActor(identity)
                let elapsedMilliseconds = max(0, (CFAbsoluteTimeGetCurrent() - started) * 1_000)
                self?.notePreparationResult(prepared != nil, elapsedMilliseconds: elapsedMilliseconds)
                guard let prepared else { return }
                self?.queue.async { prepared(ownedFrame) }
            }
        }
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(
            submitted: submittedCount,
            executed: executedCount,
            replacedPending: replacedPendingCount,
            pendingSequence: pending?.sourceSequence,
            isExecuting: executing,
            ingressFrames: ingressFrameCount,
            preparedFrames: preparedFrameCount,
            droppedBeforeWork: droppedBeforeWorkCount,
            ingressOwnershipCopyFailures: ingressOwnershipCopyFailureCount,
            mainPreparationLastMilliseconds: mainPreparationLastMilliseconds,
            mainPreparationMaxMilliseconds: mainPreparationMaxMilliseconds
        )
    }

    private static func makeOwnedFrameAndReleaseFrameHubLease(
        _ leaseBox: FrameLeaseBox,
        identity: ScoreboardFrameIdentity
    ) -> ScoreboardOwnedFrame? {
        // Taking the frame clears the only pending-job reference. The local frame
        // dies before this helper returns, so MainActor preparation never extends
        // the FrameHub lease lifetime.
        guard let frame = leaseBox.take(),
              let owned = RinkLensOCRFrameOwnership.makeOwnedCopy(of: frame.pixelBuffer) else {
            return nil
        }
        return ScoreboardOwnedFrame(pixelBuffer: owned, identity: identity)
    }

    private func noteIngressOwnershipCopyFailure() {
        lock.lock()
        ingressOwnershipCopyFailureCount &+= 1
        droppedBeforeWorkCount &+= 1
        lock.unlock()
    }

    private func notePreparationResult(_ prepared: Bool, elapsedMilliseconds: Double) {
        lock.lock()
        mainPreparationLastMilliseconds = elapsedMilliseconds
        mainPreparationMaxMilliseconds = max(mainPreparationMaxMilliseconds, elapsedMilliseconds)
        if prepared { preparedFrameCount &+= 1 } else { droppedBeforeWorkCount &+= 1 }
        lock.unlock()
    }


    private func scheduleNext() {
        queue.async { [weak self] in self?.drainOne() }
    }

    private func drainOne() {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let wait = lastStartedAt > 0 ? max(0, minimumAdmissionInterval - (now - lastStartedAt)) : 0
        lock.unlock()
        if wait > 0 {
            queue.asyncAfter(deadline: .now() + wait) { [weak self] in self?.drainOne() }
            return
        }

        lock.lock()
        guard let job = pending else {
            executing = false
            lock.unlock()
            return
        }
        pending = nil
        lastStartedAt = CFAbsoluteTimeGetCurrent()
        executedCount &+= 1
        lock.unlock()

        job.work()

        lock.lock()
        let hasPending = pending != nil
        if !hasPending { executing = false }
        lock.unlock()
        if hasPending { scheduleNext() }
    }
}

/// Recovery AK / RL-078 typed execution projection. `inactive` is a terminal
/// drop state, never an alias for legacy OCR/MainActor preparation. This is not
/// a second source of truth: authoritative stores remain writable owners and
/// replace this immutable execution projection only when their state changes.
nonisolated final class ScoreboardFrameExecutionPlanStore: @unchecked Sendable {
    enum Mode: String, Sendable {
        case inactive
        case imageRelayDirect = "imageRelay-direct"
        case ocrCompatibility = "ocr-compatibility"
    }

    struct Snapshot: @unchecked Sendable {
        let revision: UInt64
        let mode: Mode
        let worker: ScoreboardFramePipeline.PreparedFrameWork?
    }

    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var mode: Mode = .inactive
    private var worker: ScoreboardFramePipeline.PreparedFrameWork?

    func update(mode: Mode, worker: ScoreboardFramePipeline.PreparedFrameWork?) {
        lock.lock()
        revision &+= 1
        self.mode = mode
        self.worker = worker
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(revision: revision, mode: mode, worker: worker)
    }
}

/// Recovery AI value-only Image Relay configuration captured on MainActor.
/// It contains no camera pixel memory, so the worker can combine it with the
/// FrameHub frame only after the ingress gate has released UI scheduling pressure.
nonisolated struct ScoreboardFrameRelayConfiguration: @unchecked Sendable {
    let layout: ScoreboardOCRLayout
    let colourProfiles: OCRColourProfileSet
    let boardCalibration: BoardCalibrationQuad
    let previewSize: CGSize
    let previewRotationDegrees: CGFloat
    let viewerAcceptedPenaltyPlayers: Set<OCRRegionKey>
    let homeRosterNumbers: Set<Int>
    let sourceObservedAt: Date
    let sourceMonotonicTime: CFAbsoluteTime
}

/// Immutable request envelope carried by the R16 non-main scoreboard pipeline.
/// It is intentionally an execution value, not a second owner of calibration,
/// camera or viewer state. MainActor snapshots these values once per admitted
/// frame; ScoreboardImageRelayEngine consumes them off-main.
nonisolated struct ScoreboardFrameRelayRequest: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let sourceSequence: Int?
    let captureGeneration: Int
    let layout: ScoreboardOCRLayout
    let colourProfiles: OCRColourProfileSet
    let boardCalibration: BoardCalibrationQuad
    let previewSize: CGSize
    let previewRotationDegrees: CGFloat
    let viewerAcceptedPenaltyPlayers: Set<OCRRegionKey>
    let homeRosterNumbers: Set<Int>
    let sourceObservedAt: Date
    let sourceMonotonicTime: CFAbsoluteTime
}


// MARK: - UX16d39z46 Build 661 stable activation-owned Image Relay geometry

/// A visual scoreboard-input mode whose Clock and active penalty timers remain
/// direct fixed-cell physical-image relays. Build 619 hashes penalty-player zones
/// every 0.30 seconds, runs OCR after material changes and every 2.00 seconds while
/// occupied, invalidates stale player evidence when zone geometry changes, rejects
/// contrast-only/undersized player artefacts and preserves the Penalty 2 anti-ghosting
/// gate through physical Slot 1 occupancy. Active penalty timers continue every 0.30 seconds like the
/// main Clock. No 0:00 detector is used. The isolated metadata observer consumes
/// confirmed score/Period/player evidence for event popups. Build 708 deletes the
/// former textual Clock OCR/timeline lane; Clock movement remains image-only.
/// Build 596 derives a visual-only manpower label
/// from confirmed player-slot presence so live preview, recordings and clips show the skaters
/// actually represented by Image Relay without mutating game state. Build 599 keeps
/// already-authorised second physical slots alive after the first slot clears, compacts
/// surviving penalties into the first visual row and stabilises timer width independently
/// from the tight illuminated vertical digit band.
nonisolated struct ScoreboardImageRelaySnapshot: @unchecked Sendable {
    /// True while Image Relay is the viewer-facing display authority. This may
    /// remain true while processing is route-suspended or explicitly paused.
    let enabled: Bool
    /// True only while new camera frames may mutate the presentation snapshot.
    let processingEnabled: Bool
    let revision: UInt64
    let sourceSequence: Int?
    let captureGeneration: Int
    let updatedAt: Date?
    let fieldUpdatedAt: [OCRRegionKey: Date]
    let rawFieldImages: [OCRRegionKey: CGImage]
    let fieldImages: [OCRRegionKey: CGImage]
    let visualFieldValues: [OCRRegionKey: String]
    let fieldHashes: [OCRRegionKey: UInt64]
    /// Viewer-facing penalty slots are exposed only after stable physical
    /// occupancy. Cached extraction candidates remain available for diagnostics
    /// but blank-board dots, dashes and manufacturer placeholders never reach
    /// the scorebug or alter manpower.
    let confirmedPenaltyPlayerKeys: Set<OCRRegionKey>
    let diagnosticText: String

    static let disabled = ScoreboardImageRelaySnapshot(
        enabled: false,
        processingEnabled: false,
        revision: 0,
        sourceSequence: nil,
        captureGeneration: 0,
        updatedAt: nil,
        fieldUpdatedAt: [:],
        rawFieldImages: [:],
        fieldImages: [:],
        visualFieldValues: [:],
        fieldHashes: [:],
        confirmedPenaltyPlayerKeys: [],
        diagnosticText: "Image Relay off"
    )

    func rawImage(for key: OCRRegionKey) -> CGImage? {
        rawFieldImages[key]
    }

    func fieldAgeSeconds(for key: OCRRegionKey, now: Date = Date()) -> TimeInterval? {
        fieldUpdatedAt[key].map { max(0, now.timeIntervalSince($0)) }
    }

    func image(for key: OCRRegionKey) -> CGImage? {
        if let playerKey = penaltyPlayerKey(controlling: key),
           !confirmedPenaltyPlayerKeys.contains(playerKey) {
            return nil
        }
        return fieldImages[key]
    }

    func penaltySlotIsConfirmedOccupied(_ playerKey: OCRRegionKey) -> Bool {
        confirmedPenaltyPlayerKeys.contains(playerKey)
    }

    private func penaltyPlayerKey(controlling key: OCRRegionKey) -> OCRRegionKey? {
        switch key {
        case .homePenalty1Player, .homePenalty1Time: return .homePenalty1Player
        case .homePenalty2Player, .homePenalty2Time: return .homePenalty2Player
        case .awayPenalty1Player, .awayPenalty1Time: return .awayPenalty1Player
        case .awayPenalty2Player, .awayPenalty2Time: return .awayPenalty2Player
        default: return nil
        }
    }

    func visualValue(for key: OCRRegionKey) -> String? {
        visualFieldValues[key]
    }

    /// Build 599 visual-only manpower counts the compacted active player roster. A
    /// legitimately activated physical Slot 2 survives a Slot 1 clear and therefore still
    /// reduces manpower while it is promoted into visual row 1. Duplicate values during
    /// a physical-board handoff are counted once. Timer visibility and 0:00 are ignored.
    private func confirmedPenaltyCount(for team: Team) -> Int {
        let first: OCRRegionKey = team == .home ? .homePenalty1Player : .awayPenalty1Player
        let second: OCRRegionKey = team == .home ? .homePenalty2Player : .awayPenalty2Player
        // Build 621 derives viewer-facing manpower from physical player images,
        // never from OCR text. Equal hashes are deduplicated during a slot move.
        let hashes = [first, second].compactMap { key -> UInt64? in
            guard confirmedPenaltyPlayerKeys.contains(key), fieldImages[key] != nil else { return nil }
            return fieldHashes[key] ?? UInt64(key.rawValue.hashValue)
        }
        return Set(hashes).count
    }

    var visualHomeSkaters: Int {
        max(3, 5 - confirmedPenaltyCount(for: .home))
    }

    var visualAwaySkaters: Int {
        max(3, 5 - confirmedPenaltyCount(for: .away))
    }

    var visualManpowerText: String {
        "\(visualHomeSkaters)v\(visualAwaySkaters)"
    }

    var visualAdvantagedTeam: Team? {
        if visualHomeSkaters > visualAwaySkaters { return .home }
        if visualAwaySkaters > visualHomeSkaters { return .away }
        return nil
    }

    var ageSeconds: TimeInterval? {
        updatedAt.map { max(0, Date().timeIntervalSince($0)) }
    }

    var isFresh: Bool {
        enabled && processingEnabled && (ageSeconds ?? .greatestFiniteMagnitude) <= 1.5
    }

    var hasRetainedPresentation: Bool {
        !fieldImages.isEmpty || !visualFieldValues.isEmpty || !confirmedPenaltyPlayerKeys.isEmpty
    }

    /// Build 785 R8 viewer boundary. Image Relay owns physical pixels and
    /// recognition evidence only. Scores, Period, penalties and manpower may
    /// reach a viewer only after the MatchState reducer has accepted the same
    /// semantic value. The physical Clock image remains visual-only evidence.
    func viewerProjection(acceptedState: ScoreboardState) -> ScoreboardImageRelaySnapshot {
        guard enabled else { return .disabled }

        func activePenalty(player: Int?, clock: String?) -> Bool {
            if let player, player > 0 { return true }
            let value = (clock ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && value != "--:--" && value != "0:00" && value != "00:00"
        }

        let acceptedPenaltyCandidates: [OCRRegionKey?] = [
            activePenalty(player: acceptedState.homePenalty1Player, clock: acceptedState.homePenalty1Clock) ? .homePenalty1Player : nil,
            activePenalty(player: acceptedState.homePenalty2Player, clock: acceptedState.homePenalty2Clock) ? .homePenalty2Player : nil,
            activePenalty(player: acceptedState.awayPenalty1Player, clock: acceptedState.awayPenalty1Clock) ? .awayPenalty1Player : nil,
            activePenalty(player: acceptedState.awayPenalty2Player, clock: acceptedState.awayPenalty2Clock) ? .awayPenalty2Player : nil
        ]
        let acceptedPenaltyPlayers = Set(acceptedPenaltyCandidates.compactMap { $0 })

        func acceptedValue(for key: OCRRegionKey) -> String? {
            switch key {
            case .clock: return acceptedState.clock
            case .homeScore: return acceptedState.homeScore.map { String($0) }
            case .awayScore: return acceptedState.awayScore.map { String($0) }
            case .period: return acceptedState.period.map { String($0) }
            default: return nil
            }
        }

        func penaltyPlayer(for key: OCRRegionKey) -> OCRRegionKey? {
            switch key {
            case .homePenalty1Player, .homePenalty1Time: return .homePenalty1Player
            case .homePenalty2Player, .homePenalty2Time: return .homePenalty2Player
            case .awayPenalty1Player, .awayPenalty1Time: return .awayPenalty1Player
            case .awayPenalty2Player, .awayPenalty2Time: return .awayPenalty2Player
            default: return nil
            }
        }

        func fieldIsViewerAuthorised(_ key: OCRRegionKey) -> Bool {
            if key == .clock { return true }
            if let playerKey = penaltyPlayer(for: key) {
                return acceptedPenaltyPlayers.contains(playerKey)
            }
            if key == .homeScore || key == .awayScore || key == .period {
                guard let accepted = acceptedValue(for: key),
                      let observed = visualFieldValues[key] else { return false }
                return accepted == observed
            }
            return false
        }

        let viewerRawImages = rawFieldImages.filter { fieldIsViewerAuthorised($0.key) }
        let viewerImages = fieldImages.filter { fieldIsViewerAuthorised($0.key) }
        let viewerValues = visualFieldValues.filter { key, value in
            if key == .clock { return acceptedValue(for: key) == value }
            if let playerKey = penaltyPlayer(for: key) {
                return acceptedPenaltyPlayers.contains(playerKey)
            }
            return acceptedValue(for: key) == value
        }
        let viewerHashes = fieldHashes.filter { fieldIsViewerAuthorised($0.key) }
        let viewerUpdatedAt = fieldUpdatedAt.filter { fieldIsViewerAuthorised($0.key) }
        let viewerConfirmedPenalties = confirmedPenaltyPlayerKeys.intersection(acceptedPenaltyPlayers)

        return ScoreboardImageRelaySnapshot(
            enabled: enabled,
            processingEnabled: processingEnabled,
            revision: revision,
            sourceSequence: sourceSequence,
            captureGeneration: captureGeneration,
            updatedAt: updatedAt,
            fieldUpdatedAt: viewerUpdatedAt,
            rawFieldImages: viewerRawImages,
            fieldImages: viewerImages,
            visualFieldValues: viewerValues,
            fieldHashes: viewerHashes,
            confirmedPenaltyPlayerKeys: viewerConfirmedPenalties,
            diagnosticText: diagnosticText + " | viewer=accepted-match-state-only"
        )
    }
}

/// Thread-safe source of truth used by SwiftUI preview and the background
/// recording overlay renderer.
nonisolated final class ScoreboardImageRelayStore: @unchecked Sendable {
    static let shared = ScoreboardImageRelayStore()

    private let lock = NSLock()
    private var snapshotValue = ScoreboardImageRelaySnapshot.disabled
    private var directClockSampleCount: UInt64 = 0
    /// Build 734 holds a single suspicious Clock transition frame when it almost
    /// completely contains the previous glyph plus extra illuminated segments.
    /// That shape is characteristic of LED multiplex/rolling-shutter overlap and
    /// was visible as two numbers drawn over one another. A repeated candidate is
    /// accepted on the next sample so legitimate superset digit changes add only
    /// one 0.30-second confirmation, never a multi-second delay.
    private var pendingClockTransitionHash: UInt64?
    private var pendingClockTransitionStartedAt: Date?
    private var heldClockTransitionCount: UInt64 = 0

    private init() {}

    func snapshot() -> ScoreboardImageRelaySnapshot {
        lock.lock()
        let value = snapshotValue
        lock.unlock()
        return value
    }

    private func resetRecordingOverlayCache(reason: String) {
        let frozenReason = reason
        Task { @MainActor in
            BroadcastRecordingOverlayCache.shared.reset(reason: frozenReason)
        }
    }

    private func invalidateRecordingOverlayScorebug(reason: String) {
        let frozenReason = reason
        Task { @MainActor in
            BroadcastRecordingOverlayCache.shared.invalidateRelayScorebug(reason: frozenReason)
        }
    }

    func setEnabled(_ enabled: Bool, reason: String) {
        if enabled {
            activateProcessing(reason: reason)
        } else {
            pauseProcessingPreservingPresentation(reason: reason)
        }
    }

    func activateProcessing(reason: String) {
        transitionPresentation(
            displayActive: true,
            processingEnabled: true,
            event: "scoreboard_presentation_processing_started",
            reason: reason
        )
    }

    func activatePresentationWithoutProcessing(reason: String) {
        transitionPresentation(
            displayActive: true,
            processingEnabled: false,
            event: "scoreboard_presentation_armed",
            reason: reason
        )
    }

    func pauseProcessingPreservingPresentation(reason: String) {
        transitionPresentation(
            displayActive: true,
            processingEnabled: false,
            event: "scoreboard_presentation_processing_paused",
            reason: reason
        )
    }

    func deactivatePresentationPreservingSnapshot(reason: String) {
        transitionPresentation(
            displayActive: false,
            processingEnabled: false,
            event: "scoreboard_presentation_deactivated",
            reason: reason
        )
    }

    private func transitionPresentation(
        displayActive: Bool,
        processingEnabled: Bool,
        event: String,
        reason: String
    ) {
        lock.lock()
        let previous = snapshotValue
        guard previous.enabled != displayActive || previous.processingEnabled != processingEnabled else {
            lock.unlock()
            return
        }
        let nextRevision = previous.revision &+ 1
        snapshotValue = ScoreboardImageRelaySnapshot(
            enabled: displayActive,
            processingEnabled: processingEnabled,
            revision: nextRevision,
            sourceSequence: previous.sourceSequence,
            captureGeneration: previous.captureGeneration,
            updatedAt: previous.updatedAt,
            fieldUpdatedAt: previous.fieldUpdatedAt,
            rawFieldImages: previous.rawFieldImages,
            fieldImages: previous.fieldImages,
            visualFieldValues: previous.visualFieldValues,
            fieldHashes: previous.fieldHashes,
            confirmedPenaltyPlayerKeys: previous.confirmedPenaltyPlayerKeys,
            diagnosticText: "Image Relay display=\(displayActive) processing=\(processingEnabled) — \(reason)"
        )
        let next = snapshotValue
        lock.unlock()
        recordPresentationTransition(event: event, previous: previous, next: next, reason: reason)
        notifyPresentation(revision: nextRevision)
        invalidateRecordingOverlayScorebug(reason: "\(event): \(reason)")
    }

    /// Route-only suspension used when leaving OCR/Broadcast for Command Centre or
    /// another setup screen. Processing stops, but the last complete viewer-facing
    /// scorebug images and confirmed penalty slots remain available for the next
    /// mount. Explicit operator Stop still uses setEnabled(false) and clears output.
    func suspendProcessingPreservingPresentation(reason: String) {
        pauseProcessingPreservingPresentation(reason: reason)
    }

    /// Publishes a ViewModel-accepted numeric score without synthesising any goal
    /// events. Automatic ±1 changes and operator-confirmed manual jumps use the
    /// same single display authority.
    func publishAcceptedScoreValue(
        _ value: Int,
        for key: OCRRegionKey,
        reason: String
    ) {
        guard key == .homeScore || key == .awayScore,
              (0...99).contains(value) else { return }
        lock.lock()
        let previous = snapshotValue
        guard previous.enabled, previous.processingEnabled else {
            lock.unlock()
            return
        }
        let now = Date()
        let nextRevision = previous.revision &+ 1
        var images = previous.fieldImages
        var values = previous.visualFieldValues
        var hashes = previous.fieldHashes
        var updated = previous.fieldUpdatedAt
        images.removeValue(forKey: key)
        values[key] = String(value)
        hashes[key] = UInt64(value &+ 1)
        updated[key] = now
        snapshotValue = ScoreboardImageRelaySnapshot(
            enabled: true,
            processingEnabled: previous.processingEnabled,
            revision: nextRevision,
            sourceSequence: previous.sourceSequence,
            captureGeneration: previous.captureGeneration,
            updatedAt: now,
            fieldUpdatedAt: updated,
            rawFieldImages: previous.rawFieldImages,
            fieldImages: images,
            visualFieldValues: values,
            fieldHashes: hashes,
            confirmedPenaltyPlayerKeys: previous.confirmedPenaltyPlayerKeys,
            diagnosticText: "Accepted score \(key.rawValue)=\(value) — \(reason)"
        )
        let next = snapshotValue
        lock.unlock()
        recordFieldPublication(keys: [key], previous: previous, next: next, source: "accepted-score", reason: reason)
        notifyPresentation(revision: nextRevision)
        invalidateRecordingOverlayScorebug(
            reason: "accepted score \(key.rawValue)=\(value)"
        )
    }

    func clear(reason: String) {
        lock.lock()
        let previous = snapshotValue
        let nextRevision = previous.revision &+ 1
        snapshotValue = ScoreboardImageRelaySnapshot(
            enabled: previous.enabled,
            processingEnabled: previous.processingEnabled,
            revision: nextRevision,
            sourceSequence: nil,
            captureGeneration: 0,
            updatedAt: nil,
            fieldUpdatedAt: [:],
            rawFieldImages: [:],
            fieldImages: [:],
            visualFieldValues: [:],
            fieldHashes: [:],
            confirmedPenaltyPlayerKeys: [],
            diagnosticText: previous.enabled ? "Image Relay cleared — \(reason)" : "Image Relay off"
        )
        pendingClockTransitionHash = nil
        pendingClockTransitionStartedAt = nil
        lock.unlock()
        notifyPresentation(revision: nextRevision)
        resetRecordingOverlayCache(reason: "Image Relay cleared: \(reason)")
    }

    /// Build 644 multiplex-safe occupancy gate. Extraction continues on every
    /// fast-lane frame, while two illuminated digit observations expose the pair.
    /// Dark LED scan frames are held; only a sustained repeated blank clears it.
    func reconcileConfirmedPenaltyVisibility(
        occupiedKeys: Set<OCRRegionKey>,
        blankKeys: Set<OCRRegionKey>,
        sourceSequence: Int?,
        captureGeneration: Int,
        reason: String
    ) {
        lock.lock()
        let previous = snapshotValue
        guard previous.enabled,
              previous.processingEnabled,
              previous.captureGeneration == 0 || captureGeneration >= previous.captureGeneration else {
            lock.unlock()
            return
        }
        var confirmed = previous.confirmedPenaltyPlayerKeys
        confirmed.formUnion(occupiedKeys)
        confirmed.subtract(blankKeys)
        guard confirmed != previous.confirmedPenaltyPlayerKeys else {
            lock.unlock()
            return
        }
        let nextRevision = previous.revision &+ 1
        let now = Date()
        snapshotValue = ScoreboardImageRelaySnapshot(
            enabled: true,
            processingEnabled: previous.processingEnabled,
            revision: nextRevision,
            sourceSequence: sourceSequence ?? previous.sourceSequence,
            captureGeneration: max(captureGeneration, previous.captureGeneration),
            updatedAt: now,
            fieldUpdatedAt: previous.fieldUpdatedAt,
            rawFieldImages: previous.rawFieldImages,
            fieldImages: previous.fieldImages,
            visualFieldValues: previous.visualFieldValues,
            fieldHashes: previous.fieldHashes,
            confirmedPenaltyPlayerKeys: confirmed,
            diagnosticText: "Penalty visibility stableOccupied=\(occupiedKeys.map(\.rawValue).sorted()) stableBlank=\(blankKeys.map(\.rawValue).sorted()) — \(reason)"
        )
        let next = snapshotValue
        lock.unlock()
        let changedPenaltyKeys: Set<OCRRegionKey> = occupiedKeys.union(blankKeys)
        recordFieldPublication(
            keys: changedPenaltyKeys,
            previous: previous,
            next: next,
            source: "penalty-occupancy",
            reason: reason
        )
        recordPresentationTransition(
            event: "scoreboard_visible_penalty_occupancy_changed",
            previous: previous,
            next: next,
            reason: reason
        )
        notifyPresentation(revision: nextRevision)
        // Build 785 R9: raw occupancy is evidence owned by the relay store. It
        // cannot invalidate viewer/recording caches directly; BroadcastOverlayState
        // will publish only a materially changed accepted viewer snapshot.
    }


    /// Build 744 presentation-only compaction. The penalty lifecycle owner has
    /// already proven a two-penalty power-play transition from its immutable
    /// pre-removal snapshot. This method atomically transfers the retained Slot 2
    /// derived images into visual Slot 1 and clears visual Slot 2. It does not
    /// create or own a penalty lifecycle; fresh physical Slot 1 frames replace
    /// these derived images normally on the next relay pass.
    func compactConfirmedPenaltySlot2ToSlot1(
        team: Team,
        sourceSequence: Int?,
        captureGeneration: Int,
        reason: String
    ) {
        let destinationPlayer: OCRRegionKey = team == .home ? .homePenalty1Player : .awayPenalty1Player
        let destinationTimer: OCRRegionKey = team == .home ? .homePenalty1Time : .awayPenalty1Time
        let sourcePlayer: OCRRegionKey = team == .home ? .homePenalty2Player : .awayPenalty2Player
        let sourceTimer: OCRRegionKey = team == .home ? .homePenalty2Time : .awayPenalty2Time

        lock.lock()
        let previous = snapshotValue
        guard previous.enabled,
              previous.captureGeneration == 0 || captureGeneration >= previous.captureGeneration,
              previous.fieldImages[sourcePlayer] != nil || previous.confirmedPenaltyPlayerKeys.contains(sourcePlayer) else {
            lock.unlock()
            return
        }

        var rawImages = previous.rawFieldImages
        var images = previous.fieldImages
        var values = previous.visualFieldValues
        var hashes = previous.fieldHashes
        var updated = previous.fieldUpdatedAt
        var confirmed = previous.confirmedPenaltyPlayerKeys
        let now = Date()

        if let value = rawImages[sourcePlayer] { rawImages[destinationPlayer] = value }
        if let value = rawImages[sourceTimer] { rawImages[destinationTimer] = value }
        if let value = images[sourcePlayer] { images[destinationPlayer] = value }
        if let value = images[sourceTimer] { images[destinationTimer] = value }
        if let value = values[sourcePlayer] { values[destinationPlayer] = value }
        if let value = values[sourceTimer] { values[destinationTimer] = value }
        if let value = hashes[sourcePlayer] { hashes[destinationPlayer] = value }
        if let value = hashes[sourceTimer] { hashes[destinationTimer] = value }
        updated[destinationPlayer] = now
        updated[destinationTimer] = now

        rawImages.removeValue(forKey: sourcePlayer)
        rawImages.removeValue(forKey: sourceTimer)
        images.removeValue(forKey: sourcePlayer)
        images.removeValue(forKey: sourceTimer)
        values.removeValue(forKey: sourcePlayer)
        values.removeValue(forKey: sourceTimer)
        hashes.removeValue(forKey: sourcePlayer)
        hashes.removeValue(forKey: sourceTimer)
        updated.removeValue(forKey: sourcePlayer)
        updated.removeValue(forKey: sourceTimer)
        confirmed.remove(sourcePlayer)
        confirmed.insert(destinationPlayer)

        let nextRevision = previous.revision &+ 1
        snapshotValue = ScoreboardImageRelaySnapshot(
            enabled: previous.enabled,
            processingEnabled: previous.processingEnabled,
            revision: nextRevision,
            sourceSequence: sourceSequence ?? previous.sourceSequence,
            captureGeneration: max(captureGeneration, previous.captureGeneration),
            updatedAt: now,
            fieldUpdatedAt: updated,
            rawFieldImages: rawImages,
            fieldImages: images,
            visualFieldValues: values,
            fieldHashes: hashes,
            confirmedPenaltyPlayerKeys: confirmed,
            diagnosticText: "Penalty Slot 2 compacted to Slot 1 — \(reason)"
        )
        let next = snapshotValue
        lock.unlock()

        let changed: Set<OCRRegionKey> = [destinationPlayer, destinationTimer, sourcePlayer, sourceTimer]
        recordFieldPublication(
            keys: changed,
            previous: previous,
            next: next,
            source: "power-play-compaction",
            reason: reason
        )
        RinkLensStructuredEventLogger.shared.record(
            domain: .scoreboardPresentation,
            event: "penalty_visual_slot2_compacted_to_slot1",
            entityID: team.rawValue,
            previous: [
                "slot1PlayerHash": previous.fieldHashes[destinationPlayer].map({ String($0) }) ?? "none",
                "slot2PlayerHash": previous.fieldHashes[sourcePlayer].map({ String($0) }) ?? "none",
                "relayRevision": String(previous.revision)
            ],
            next: [
                "slot1PlayerHash": next.fieldHashes[destinationPlayer].map({ String($0) }) ?? "none",
                "slot2PlayerHash": "none",
                "relayRevision": String(next.revision)
            ],
            source: "ScoreboardImageRelayStore",
            reason: reason,
            captureGeneration: captureGeneration,
            authoritativeOwner: "BroadcastOverlayState"
        )
        notifyPresentation(revision: nextRevision)
        invalidateRecordingOverlayScorebug(
            reason: "Build 744 atomic penalty visual compaction"
        )
    }


    /// Build 661 direct Clock path. Every successful 0.30-second crop still feeds
    /// movement authority, while the viewer overlay is invalidated only when the
    /// stable canonical Clock pixels materially change. OCR never gates the image.
    func publishDirectClock(
        rawImage: CGImage,
        image: CGImage,
        contentHash: UInt64,
        sourceSequence: Int?,
        captureGeneration: Int,
        processingMilliseconds: Double,
        diagnostic: String
    ) {
        lock.lock()
        let previous = snapshotValue
        guard previous.enabled, previous.processingEnabled else {
            lock.unlock()
            return
        }

        directClockSampleCount &+= 1
        let sampleCount = directClockSampleCount
        let now = Date()
        let changed = previous.fieldHashes[.clock] != contentHash
            || previous.captureGeneration != captureGeneration
            || previous.fieldImages[.clock] == nil

        var transitionGate = "stable"
        var mayPublishChangedImage = changed
        if changed,
           previous.captureGeneration == captureGeneration,
           let previousClock = previous.fieldImages[.clock],
           let metrics = Self.clockTransitionMetrics(previous: previousClock, candidate: image),
           metrics.looksLikeTransientOverlay {
            let repeatedCandidate = pendingClockTransitionHash == contentHash
            let pendingAge = pendingClockTransitionStartedAt.map { now.timeIntervalSince($0) } ?? 0
            if repeatedCandidate {
                transitionGate = "confirmed-after-single-frame-hold \(metrics.diagnostic)"
                pendingClockTransitionHash = nil
                pendingClockTransitionStartedAt = nil
            } else {
                heldClockTransitionCount &+= 1
                mayPublishChangedImage = false
                if pendingAge >= 0.65 {
                    // Build 736: rapid timeout tenths can produce a different mixed
                    // LED frame on every sample. Never release one merely because
                    // the hold timer expired; retain the last clean Clock and wait
                    // for either one repeated candidate or a non-overlap frame.
                    pendingClockTransitionHash = nil
                    pendingClockTransitionStartedAt = nil
                    transitionGate = "discarded-unconfirmed-overlap-after-maximum-hold count=\(heldClockTransitionCount) \(metrics.diagnostic)"
                } else {
                    let firstHeldAt = pendingClockTransitionStartedAt ?? now
                    pendingClockTransitionHash = contentHash
                    pendingClockTransitionStartedAt = firstHeldAt
                    transitionGate = "held-transient-overlap count=\(heldClockTransitionCount) \(metrics.diagnostic)"
                }
            }
        } else {
            pendingClockTransitionHash = nil
            pendingClockTransitionStartedAt = nil
        }

        let publishedChange = changed && mayPublishChangedImage
        let nextRevision = publishedChange ? previous.revision &+ 1 : previous.revision
        var rawImages = previous.rawFieldImages
        var images = previous.fieldImages
        var hashes = previous.fieldHashes
        var updated = previous.fieldUpdatedAt

        rawImages[.clock] = rawImage
        updated[.clock] = now
        // Never replace the viewer image with an unconfirmed overlap frame, or
        // with same-hash camera noise. The last complete Clock remains visible
        // until a genuinely changed candidate clears the transition gate.
        if publishedChange || previous.fieldImages[.clock] == nil {
            images[.clock] = image
            hashes[.clock] = contentHash
        }

        snapshotValue = ScoreboardImageRelaySnapshot(
            enabled: true,
            processingEnabled: previous.processingEnabled,
            revision: nextRevision,
            sourceSequence: sourceSequence,
            captureGeneration: captureGeneration,
            updatedAt: now,
            fieldUpdatedAt: updated,
            rawFieldImages: rawImages,
            fieldImages: images,
            visualFieldValues: previous.visualFieldValues,
            fieldHashes: hashes,
            confirmedPenaltyPlayerKeys: previous.confirmedPenaltyPlayerKeys,
            diagnosticText: String(
                format: "Image Relay direct-clock sample=%@ changed=%@ published=%@ frame=%@ generation=%d process=%.1fms gate={%@} %@",
                String(sampleCount),
                changed ? "yes" : "no",
                publishedChange ? "yes" : "no",
                sourceSequence.map { String($0) } ?? "--",
                captureGeneration,
                processingMilliseconds,
                transitionGate,
                diagnostic
            )
        )
        let next = snapshotValue
        lock.unlock()

        if publishedChange {
            recordFieldPublication(keys: [.clock], previous: previous, next: next, source: "direct-clock", reason: "\(diagnostic) gate={\(transitionGate)}")
            notifyPresentation(revision: nextRevision)
            invalidateRecordingOverlayScorebug(
                reason: "Image Relay direct Clock meaningful change sample \(sampleCount) revision \(nextRevision)"
            )
        }
    }

    private struct ClockTransitionMetrics {
        let previousActive: Int
        let candidateActive: Int
        let retainedFraction: Double
        let gainedFraction: Double
        let lostFraction: Double

        var looksLikeTransientOverlay: Bool {
            previousActive >= 24
                && retainedFraction >= 0.92
                && gainedFraction >= 0.10
                && lostFraction <= 0.08
                && candidateActive >= Int((Double(previousActive) * 1.08).rounded(.down))
        }

        var diagnostic: String {
            String(
                format: "active=%d->%d retained=%.2f gained=%.2f lost=%.2f",
                previousActive,
                candidateActive,
                retainedFraction,
                gainedFraction,
                lostFraction
            )
        }
    }

    /// Compares final fixed-canvas Clock alpha on a small deterministic grid.
    /// A rolling-shutter transition commonly preserves nearly every old segment
    /// while also lighting several new ones; a clean next frame either repeats
    /// the new glyph or drops the stale segments.
    private static func clockTransitionMetrics(
        previous: CGImage,
        candidate: CGImage
    ) -> ClockTransitionMetrics? {
        guard let previousMask = clockTransitionMask(previous),
              let candidateMask = clockTransitionMask(candidate),
              previousMask.count == candidateMask.count else { return nil }

        var previousActive = 0
        var candidateActive = 0
        var retained = 0
        var gained = 0
        var lost = 0
        for index in previousMask.indices {
            let wasActive = previousMask[index] != 0
            let isActive = candidateMask[index] != 0
            if wasActive { previousActive += 1 }
            if isActive { candidateActive += 1 }
            if wasActive && isActive { retained += 1 }
            if !wasActive && isActive { gained += 1 }
            if wasActive && !isActive { lost += 1 }
        }
        guard previousActive > 0 else { return nil }
        return ClockTransitionMetrics(
            previousActive: previousActive,
            candidateActive: candidateActive,
            retainedFraction: Double(retained) / Double(previousActive),
            gainedFraction: Double(gained) / Double(previousActive),
            lostFraction: Double(lost) / Double(previousActive)
        )
    }

    private static func clockTransitionMask(_ image: CGImage) -> [UInt8]? {
        let width = 64
        let height = 20
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let base = bytes.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .low
            context.setShouldAntialias(false)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }
        var mask = [UInt8](repeating: 0, count: width * height)
        for index in mask.indices {
            mask[index] = pixels[index * 4 + 3] >= 72 ? 1 : 0
        }
        return mask
    }

    func publish(
        rawImages: [OCRRegionKey: CGImage],
        images: [OCRRegionKey: CGImage],
        visualValues: [OCRRegionKey: String],
        hashes: [OCRRegionKey: UInt64],
        attemptedKeys: Set<OCRRegionKey>,
        lane: String,
        sourceSequence: Int?,
        captureGeneration: Int,
        processingMilliseconds: Double,
        extractionSummary: String
    ) {
        lock.lock()
        let previous = snapshotValue
        guard previous.enabled, previous.processingEnabled else {
            lock.unlock()
            return
        }
        guard previous.captureGeneration == 0 || captureGeneration >= previous.captureGeneration else {
            // Parallel clock/static workers may finish out of order across a
            // camera rebuild. Never let an older generation replace a newer one.
            lock.unlock()
            return
        }

        let now = Date()
        let generationChanged = previous.captureGeneration != captureGeneration
        // Build 574 retains the last complete visual field set across a camera
        // generation hand-off. Each independent lane replaces only the fields it
        // owns, so a 5-second Period cadence cannot make Period disappear while
        // the new camera generation is warming up.
        var mergedRawImages = previous.rawFieldImages
        var mergedImages = previous.fieldImages
        var mergedVisualValues = previous.visualFieldValues
        var mergedHashes = previous.fieldHashes
        var mergedUpdatedAt = previous.fieldUpdatedAt

        for key in attemptedKeys {
            if let raw = rawImages[key] {
                mergedRawImages[key] = raw
            }

            if let visualValue = visualValues[key], let hash = hashes[key] {
                // Build 579: Score, Period and penalty-player fields are values,
                // not relay bitmaps. Remove any legacy glyph image so every output
                // path uses the same normal text renderer as OCR mode.
                mergedVisualValues[key] = visualValue
                mergedImages.removeValue(forKey: key)
                mergedHashes[key] = hash
                mergedUpdatedAt[key] = now
                continue
            }

            if let image = images[key], let hash = hashes[key] {
                mergedImages[key] = image
                mergedVisualValues.removeValue(forKey: key)
                mergedHashes[key] = hash
                mergedUpdatedAt[key] = now
                continue
            }

            switch key {
            case .clock:
                // The direct 0.30-second publisher owns Clock exclusively.
                break

            case .homeScore, .awayScore, .period:
                // Hold the last confirmed visual text value through a parser
                // miss; never fall back to distorted relay-mask line art.
                break

            case .homePenalty1Time, .homePenalty2Time,
                 .awayPenalty1Time, .awayPenalty2Time:
                // Player and timer publication are independent. A timer key is
                // attempted without an image only after the player zone has been
                // physically confirmed blank, so clear this timer only.
                mergedImages.removeValue(forKey: key)
                mergedVisualValues.removeValue(forKey: key)
                mergedHashes.removeValue(forKey: key)
                mergedUpdatedAt.removeValue(forKey: key)

            case .homePenalty1Player, .homePenalty2Player,
                 .awayPenalty1Player, .awayPenalty2Player:
                // OCR/extractor failure never clears a player. A player key is
                // attempted without an image only after repeated physical blank
                // evidence from the calibrated player zone. Clear only this
                // player; the timer is cleared by its own attempted key.
                mergedImages.removeValue(forKey: key)
                mergedVisualValues.removeValue(forKey: key)
                mergedHashes.removeValue(forKey: key)
                mergedUpdatedAt.removeValue(forKey: key)

            default:
                mergedImages.removeValue(forKey: key)
                mergedVisualValues.removeValue(forKey: key)
                mergedHashes.removeValue(forKey: key)
                mergedUpdatedAt.removeValue(forKey: key)
            }
        }

        let changed = mergedHashes != previous.fieldHashes
            || Set(mergedImages.keys) != Set(previous.fieldImages.keys)
            || mergedVisualValues != previous.visualFieldValues
            || generationChanged

        let nextRevision = changed ? previous.revision &+ 1 : previous.revision
        let fields = Set(mergedImages.keys).union(mergedVisualValues.keys)
            .map(\.rawValue).sorted().joined(separator: ",")
        let clockAgeText = mergedUpdatedAt[.clock].map {
            String(format: "%.2fs", max(0, now.timeIntervalSince($0)))
        } ?? "missing"
        snapshotValue = ScoreboardImageRelaySnapshot(
            enabled: true,
            processingEnabled: previous.processingEnabled,
            revision: nextRevision,
            sourceSequence: sourceSequence,
            captureGeneration: captureGeneration,
            updatedAt: now,
            fieldUpdatedAt: mergedUpdatedAt,
            rawFieldImages: mergedRawImages,
            fieldImages: mergedImages,
            visualFieldValues: mergedVisualValues,
            fieldHashes: mergedHashes,
            confirmedPenaltyPlayerKeys: previous.confirmedPenaltyPlayerKeys,
            diagnosticText: String(
                format: "Image Relay %@ fields=%d [%@] frame=%@ generation=%d process=%.1fms clockAge=%@ %@",
                lane,
                Set(mergedImages.keys).union(mergedVisualValues.keys).count,
                fields,
                sourceSequence.map { String($0) } ?? "--",
                captureGeneration,
                processingMilliseconds,
                clockAgeText,
                extractionSummary
            )
        )
        let next = snapshotValue
        lock.unlock()

        if changed {
            recordFieldPublication(keys: attemptedKeys, previous: previous, next: next, source: "image-relay-\(lane)", reason: extractionSummary)
            notifyPresentation(revision: nextRevision)
            // Raw score/period/penalty evidence is not a renderer authority. The
            // accepted viewer snapshot and its material cache key decide whether
            // live/recording composition needs a redraw.
        }
    }

    private func recordPresentationTransition(
        event: String,
        previous: ScoreboardImageRelaySnapshot,
        next: ScoreboardImageRelaySnapshot,
        reason: String
    ) {
        RinkLensStructuredEventLogger.shared.record(
            domain: .scoreboardPresentation,
            event: event,
            entityID: "physical-scoreboard",
            previous: presentationSummary(previous),
            next: presentationSummary(next),
            source: "ScoreboardImageRelayStore",
            reason: reason,
            captureGeneration: next.captureGeneration
        )
    }

    private func recordFieldPublication(
        keys: Set<OCRRegionKey>,
        previous: ScoreboardImageRelaySnapshot,
        next: ScoreboardImageRelaySnapshot,
        source: String,
        reason: String
    ) {
        for key in keys {
            let before = fieldSummary(previous, key: key)
            let after = fieldSummary(next, key: key)
            guard before != after else { continue }
            RinkLensStructuredEventLogger.shared.record(
                domain: .scoreboardPresentation,
                event: "scoreboard_visible_field_changed",
                entityID: key.rawValue,
                previous: before,
                next: after,
                source: source,
                reason: reason,
                captureGeneration: next.captureGeneration
            )
        }
    }

    private func presentationSummary(_ snapshot: ScoreboardImageRelaySnapshot) -> [String: String] {
        [
            "displayActive": String(snapshot.enabled),
            "processingEnabled": String(snapshot.processingEnabled),
            "revision": String(snapshot.revision),
            "generation": String(snapshot.captureGeneration),
            "clock": fieldSummary(snapshot, key: .clock)["value"] ?? "none",
            "homeScore": fieldSummary(snapshot, key: .homeScore)["value"] ?? "none",
            "awayScore": fieldSummary(snapshot, key: .awayScore)["value"] ?? "none",
            "homePenaltyCount": String([OCRRegionKey.homePenalty1Player, .homePenalty2Player].filter(snapshot.confirmedPenaltyPlayerKeys.contains).count),
            "awayPenaltyCount": String([OCRRegionKey.awayPenalty1Player, .awayPenalty2Player].filter(snapshot.confirmedPenaltyPlayerKeys.contains).count)
        ]
    }

    private func fieldSummary(_ snapshot: ScoreboardImageRelaySnapshot, key: OCRRegionKey) -> [String: String] {
        let value: String
        if let text = snapshot.visualFieldValues[key] {
            value = text
        } else if snapshot.fieldImages[key] != nil {
            value = "image"
        } else {
            value = "none"
        }
        return [
            "value": value,
            "hash": snapshot.fieldHashes[key].map { String($0) } ?? "none",
            "updatedAt": snapshot.fieldUpdatedAt[key].map { ISO8601DateFormatter().string(from: $0) } ?? "none",
            "displayActive": String(snapshot.enabled),
            "processingEnabled": String(snapshot.processingEnabled)
        ]
    }

    private func notifyPresentation(revision: UInt64) {
        ScoreboardImageRelayPresentationDiagnostics.shared.notePublished(
            revision: revision,
            at: ProcessInfo.processInfo.systemUptime
        )
        DispatchQueue.main.async {
            ScoreboardImageRelayPresentation.shared.noteRevision(revision)
        }
    }
}

nonisolated final class ScoreboardImageRelayPresentationDiagnostics: @unchecked Sendable {
    static let shared = ScoreboardImageRelayPresentationDiagnostics()

    private let lock = NSLock()
    private var publishedRevision: UInt64 = 0
    private var broadcastRenderRequestedRevision: UInt64 = 0
    private var broadcastRenderCompletedRevision: UInt64 = 0
    private var broadcastDisplayedRevision: UInt64 = 0

    private var publishedAtByRevision: [UInt64: TimeInterval] = [:]
    private var requestedAtByRevision: [UInt64: TimeInterval] = [:]
    private var renderedAtByRevision: [UInt64: TimeInterval] = [:]
    private var latestPublishToRequestMS: Double?
    private var latestRequestToRenderMS: Double?
    private var latestRenderToDisplayMS: Double?
    private var latestPublishToDisplayMS: Double?
    private var maximumPublishToDisplayMS: Double = 0
    private var displayedLatencySampleCount: UInt64 = 0

    private init() {}

    private var monotonicNow: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private func milliseconds(from start: TimeInterval?, to end: TimeInterval) -> Double? {
        start.map { max(0, (end - $0) * 1_000) }
    }

    private func trimRevisionTimings(keeping latestRevision: UInt64) {
        let floorRevision = latestRevision > 120 ? latestRevision - 120 : 0
        publishedAtByRevision = publishedAtByRevision.filter { $0.key >= floorRevision }
        requestedAtByRevision = requestedAtByRevision.filter { $0.key >= floorRevision }
        renderedAtByRevision = renderedAtByRevision.filter { $0.key >= floorRevision }
    }

    func notePublished(revision: UInt64, at timestamp: TimeInterval? = nil) {
        let now = timestamp ?? monotonicNow
        lock.lock()
        publishedRevision = max(publishedRevision, revision)
        publishedAtByRevision[revision] = now
        trimRevisionTimings(keeping: revision)
        lock.unlock()
    }

    func noteBroadcastRenderRequested(revision: UInt64) {
        let now = monotonicNow
        lock.lock()
        broadcastRenderRequestedRevision = max(broadcastRenderRequestedRevision, revision)
        requestedAtByRevision[revision] = now
        latestPublishToRequestMS = milliseconds(
            from: publishedAtByRevision[revision],
            to: now
        )
        trimRevisionTimings(keeping: revision)
        lock.unlock()
    }

    func noteBroadcastRenderCompleted(revision: UInt64) {
        let now = monotonicNow
        lock.lock()
        broadcastRenderCompletedRevision = max(broadcastRenderCompletedRevision, revision)
        renderedAtByRevision[revision] = now
        latestRequestToRenderMS = milliseconds(
            from: requestedAtByRevision[revision],
            to: now
        )
        trimRevisionTimings(keeping: revision)
        lock.unlock()
    }

    func noteBroadcastDisplayed(revision: UInt64) {
        let now = monotonicNow
        lock.lock()
        broadcastDisplayedRevision = max(broadcastDisplayedRevision, revision)
        latestRenderToDisplayMS = milliseconds(
            from: renderedAtByRevision[revision],
            to: now
        )
        latestPublishToDisplayMS = milliseconds(
            from: publishedAtByRevision[revision],
            to: now
        )
        if let latestPublishToDisplayMS {
            maximumPublishToDisplayMS = max(
                maximumPublishToDisplayMS,
                latestPublishToDisplayMS
            )
            displayedLatencySampleCount &+= 1
        }
        trimRevisionTimings(keeping: revision)
        lock.unlock()
    }

    private func formattedMS(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.1f", value)
    }

    var diagnosticText: String {
        lock.lock()
        let value =
            "published=\(publishedRevision) broadcastRequested=\(broadcastRenderRequestedRevision) "
            + "broadcastRendered=\(broadcastRenderCompletedRevision) broadcastDisplayed=\(broadcastDisplayedRevision) "
            + "latencyMs={publishToRequest=\(formattedMS(latestPublishToRequestMS)) "
            + "requestToRender=\(formattedMS(latestRequestToRenderMS)) "
            + "renderToDisplay=\(formattedMS(latestRenderToDisplayMS)) "
            + "publishToDisplay=\(formattedMS(latestPublishToDisplayMS)) "
            + "maxPublishToDisplay=\(String(format: "%.1f", maximumPublishToDisplayMS)) "
            + "samples=\(displayedLatencySampleCount)}"
        lock.unlock()
        return value
    }
}

final class ScoreboardImageRelayPresentation: ObservableObject {
    static let shared = ScoreboardImageRelayPresentation()

    @Published private(set) var revision: UInt64 = 0

    private init() {}

    fileprivate func noteRevision(_ revision: UInt64) {
        if self.revision != revision {
            self.revision = revision
        }
    }

    func noteBroadcastRenderRequested(revision: UInt64) {
        ScoreboardImageRelayPresentationDiagnostics.shared.noteBroadcastRenderRequested(revision: revision)
    }

    func noteBroadcastRenderCompleted(revision: UInt64) {
        ScoreboardImageRelayPresentationDiagnostics.shared.noteBroadcastRenderCompleted(revision: revision)
    }

    func noteBroadcastDisplayed(revision: UInt64) {
        ScoreboardImageRelayPresentationDiagnostics.shared.noteBroadcastDisplayed(revision: revision)
    }
}

/// Build 615 carries physical occupancy separately from recognised/displayed text.
/// This preserves Slot 2 anti-ghosting while allowing the event reconciler to use
/// a complete two-slot evidence snapshot rather than display-authorised values only.
enum ScoreboardImageRelayPenaltySlotOccupancy: String, Sendable {
    case confirmedOccupied
    case confirmedBlank
    case unresolved
}

struct ScoreboardImageRelayPenaltySlotEvidence: Sendable {
    let rawCandidate: String?
    let resolvedPlayer: String?
    let retainedPlayer: String?
    let confidence: Float
    let occupancy: ScoreboardImageRelayPenaltySlotOccupancy
    /// Stable physical identity derived from the frozen relay crop. Lifecycle
    /// tracking uses this rather than OCR text, so Guest penalties require no OCR.
    let physicalIdentityHash: UInt64?
    let stableOccupiedCount: Int
    /// Consecutive physical blank observations for independent clear/expiry proof.
    let stableBlankCount: Int
    /// Latched only when this stable occupied candidate followed at least three
    /// confirmed blank samples in the same physical slot.
    let startedFromStableBlank: Bool
    /// Monotonic latency checkpoints owned by the physical pair detector.
    let pairCandidateStartedAt: CFAbsoluteTime?
    let pairConfirmedAt: CFAbsoluteTime?
    let lifecycleAuthorised: Bool
    let retainedEvidenceCycles: Int
    let decision: String
}

/// Image Relay observations carry physical Clock movement transitions plus validated
/// score, Period and penalty evidence. They never OCR the game Clock for event-time
/// metadata, replace a relayed image, write MatchState, or gate the scorebug.
enum ScoreboardImageRelayTimeoutTransition: String, Sendable {
    case started
    case ended
}

struct ScoreboardImageRelayMetadataObservation: @unchecked Sendable {
    enum Kind: Sendable { case clock, scoreCandidate, visual }
    let kind: Kind
    let clockRunning: Bool?
    let movementTransitioned: Bool
    /// Immutable displayed Clock glyph captured from the first stable crop of a
    /// confirmed stoppage. This is metadata-only and never feeds back into relay.
    let frozenClockImage: CGImage?
    let visualValues: [OCRRegionKey: String]
    /// Raw validated OCR candidates are carried separately from viewer-facing
    /// values. This lets the ViewModel request confirmation for large score jumps
    /// while the scorebug safely remains on the physical Image Relay crop.
    var candidateValues: [OCRRegionKey: String] = [:]
    /// Stable physical glyph hashes paired with candidate values. Event admission
    /// can therefore distinguish a persistent misread from a real board change.
    var candidateHashes: [OCRRegionKey: UInt64] = [:]
    let attemptedKeys: Set<OCRRegionKey>
    let observedAt: Date
    let monotonicTime: CFAbsoluteTime
    let sourceSequence: Int?
    let captureGeneration: Int
    /// True only when all four physical penalty-player crops were available in
    /// the same frame. Partial/cancelled cycles may update diagnostics but cannot
    /// remove active player lifecycles.
    let completePenaltyPlayerCycle: Bool
    var timeoutTransition: ScoreboardImageRelayTimeoutTransition? = nil
    var penaltySlotEvidence: [OCRRegionKey: ScoreboardImageRelayPenaltySlotEvidence] = [:]
    let diagnostic: String
}

nonisolated final class ScoreboardImageRelayEngine: @unchecked Sendable {
    // Recovery AM / RL-082 + Recovery AT / RL-099: ownership, execution and QoS are deliberately separate.
    // One serial rectification authority is the only Core Image board/crop
    // producer. The 0.30-second viewer Clock and slower semantic auxiliary
    // services retain separate execution queues, so recognition/parser work can
    // never head-of-line block Clock scheduling; each service submits only its
    // bounded field crop to this physical Core Image ownership boundary.
    private let scoreboardRectificationQueue = DispatchQueue(
        label: "rinklens.scoreboard.image-relay.rectification",
        qos: RinkLensExecutionQoSHierarchy.viewer
    )
    private let scoreboardClockServiceQueue = DispatchQueue(
        label: "rinklens.scoreboard.image-relay.clock-service",
        qos: RinkLensExecutionQoSHierarchy.viewer
    )
    private let scoreboardAuxiliaryServiceQueue = DispatchQueue(
        label: "rinklens.scoreboard.image-relay.auxiliary-service",
        qos: RinkLensExecutionQoSHierarchy.semantic
    )
    private let lock = NSLock()
    // Recovery BK / RL-149: Clock presentation geometry is independent mutable
    // state. It must not wait behind the engine-wide scheduling/diagnostics lock.
    private let clockGeometryLock = NSLock()
    // One processor means one scoreboard CIContext/kernel cache. Every direct crop
    // is serialized by scoreboardRectificationQueue; recognition/parser work after
    // an auxiliary crop remains on the auxiliary lane.
    private let processor = ScoreboardOCRProcessor(resources: .shared)

    /// Build 579 visual recognition is deliberately local to Image Relay.
    /// It feeds the original rectified Home Score, Away Score, Period and penalty
    /// player crops to the same dynamic-token parser and saved colour profiles used
    /// by OCR mode. Confirmed values are rendered as normal scorebug text and never
    /// publish to OCR state, MatchState, the goal detector or event automation.
    private struct RelayPlayerCandidateEvidence {
        let value: String
        let confidence: Float
        let observedAt: TimeInterval
    }

    private struct RelayVisualRecognitionState {
        var confirmedValue: String?
        var pendingValue: String?
        var pendingCount: Int = 0
        var consecutiveMisses: Int = 0
        var geometrySignature: UInt64 = 0
        var lastPhysicalHash: UInt64?
        var lastConfidence: Float = 0
        var lastDecision: String = "uninitialised"
        // Build 584: bounded trusted observations survive one weak/conflicting
        // frame so physical two-digit players do not need consecutive reads.
        var recentPlayerEvidence: [RelayPlayerCandidateEvidence] = []
        // Build 599: a second physical slot may outlive Slot 1 only after it was
        // genuinely active while Slot 1 was present. This prevents an isolated
        // false Slot 2 read from creating a penalty, while permitting compaction.
        var secondSlotActivationAuthorised: Bool = false
        var retainedEvidenceCycleCount: Int = 0
    }

    private struct RelayVisualRecognitionResult {
        let value: String?
        let confidence: Float
        let diagnostic: String
        let requiresExtendedConfirmation: Bool

        init(
            value: String?,
            confidence: Float,
            diagnostic: String,
            requiresExtendedConfirmation: Bool = false
        ) {
            self.value = value
            self.confidence = confidence
            self.diagnostic = diagnostic
            self.requiresExtendedConfirmation = requiresExtendedConfirmation
        }
    }

    /// Build 607 keeps penalty-player visibility independent from OCR text noise.
    /// The exact calibrated player crop is classified as occupied, blank or unknown
    /// using the existing illuminated-glyph geometry path. Only repeated confirmed
    /// blank crops may clear a player-owned slot.
    private enum RelayPenaltyPlayerOccupancy {
        case occupied(String)
        case blank(String)
        case unknown(String)

        var diagnostic: String {
            switch self {
            case .occupied(let detail): return "occupied {\(detail)}"
            case .blank(let detail): return "blank {\(detail)}"
            case .unknown(let detail): return "unknown {\(detail)}"
            }
        }

        var isConfirmedBlank: Bool {
            if case .blank = self { return true }
            return false
        }

        var isConfirmedOccupied: Bool {
            if case .occupied = self { return true }
            return false
        }

        var metadataState: ScoreboardImageRelayPenaltySlotOccupancy {
            switch self {
            case .occupied: return .confirmedOccupied
            case .blank: return .confirmedBlank
            case .unknown: return .unresolved
            }
        }
    }


    /// One complete physical player-slot observation for the atomic team-level
    /// reconciliation pass. Raw recognition and occupancy are retained separately
    /// so an unreadable crop cannot be mistaken for an empty slot.
    private struct RelayPenaltyPlayerCycleObservation {
        let candidate: String?
        let confidence: Float
        let parserDiagnostic: String
        let occupancy: RelayPenaltyPlayerOccupancy
        let ocrAttempted: Bool
        let perceptualHash: UInt64?
        let hashDiagnostic: String
    }

    /// Build 619 runs a lightweight player-zone hash lane every 0.30 seconds and
    /// keeps OCR as a secondary identity reader. A verified blank baseline is only
    /// learned from repeated physically blank crops, never from the first arbitrary
    /// frame. Previous occupied hashes are retained briefly so a scoreboard handoff
    /// such as [45,56] -> [56,77] can be reconciled atomically even when neither
    /// physical slot is blank between frames.
    private struct RelayPenaltyPlayerHashState {
        var blankBaselineHash: UInt64?
        var blankCandidateHash: UInt64?
        var blankCandidateCount: Int = 0
        var previousHash: UInt64?
        var previousOccupancy: ScoreboardImageRelayPenaltySlotOccupancy = .unresolved
        var lastOccupiedHash: UInt64?
        var lastOccupiedObservedAt: CFAbsoluteTime = 0
        // Build 644 treats penalty-player displays as multiplexed LED sources.
        // Two matching illuminated observations inside a short rolling window
        // establish occupancy; intervening dark scan-phase frames do not reset it.
        var occupiedCandidateHash: UInt64?
        var occupiedCandidateCount: Int = 0
        var occupiedCandidateStartedFromStableBlank = false
        var stableBlankCount: Int = 0
        var blankClearCandidateCount: Int = 0
        var frozenCandidateHash: UInt64?
        var frozenOCRAttemptCount: Int = 0
        var frozenOCRStartedAt: CFAbsoluteTime = 0
        var lastDecision: String = "awaiting-first-hash"
    }

    private struct RelayPenaltyPlayerHashObservation {
        let hash: UInt64?
        let previousOccupiedHash: UInt64?
        /// Stable lifecycle identity that belonged to this physical slot before
        /// the current observation mutated/cleared its hash state. This is the
        /// identity transferred during an atomic Slot 2 -> Slot 1 handoff.
        let previousStableIdentityHash: UInt64?
        let occupancy: RelayPenaltyPlayerOccupancy
        let materialChange: Bool
        let distanceFromPrevious: Int?
        let distanceFromBlank: Int?
        let baselineReady: Bool
        let stableOccupiedCount: Int
        let stableBlankCount: Int
        let startedFromStableBlank: Bool
        let stableIdentityHash: UInt64?
        let frozenCandidateReady: Bool
        let frozenOCRAttempt: Int
        let diagnostic: String
    }

    /// Build 599 separates penalty-timer axes. The horizontal anchor may expand but
    /// never shrink or recenter during one player activation. The vertical band is
    /// controlled independently by trustworthy digit-band measurements. Build 687
    /// removes provisional full-zone publication entirely: no timer becomes visible
    /// until clean geometry has been established and confirmed.
    /// Build 652 makes the two calibrated physical boxes the only activation
    /// authority for a penalty slot. A player-like signal without a live timer
    /// signal is never allowed to create viewer output, manpower or a popup.
    private struct RelayPenaltyPairSignalState {
        var positiveCount = 0
        var captureGeneration: Int?
        var lastPositiveSourceSequence: Int?
        var negativeTimerCount = 0
        /// A confirmed player-zone blank is stronger than a still-lit timer box.
        /// The timer can contain a bezel/reflection after the player has cleared,
        /// so three fresh confirmed player blanks end the retained pair.
        var negativePlayerBlankCount = 0
        var firstPositiveAt: CFAbsoluteTime = 0
        var confirmedAt: CFAbsoluteTime = 0
        var confirmed = false
        var lastDecision = "awaiting-player-and-timer"
    }

    /// Build 598 separates Clock pixel refresh from Clock presentation geometry.
    /// Width may expand to preserve outer digits, while the tightest trustworthy
    /// vertical band is retained so the larger Clock presentation does not pulse.
    private struct RelayClockGeometryState {
        var captureGeneration: Int
        var sourceWidth: Int
        var sourceHeight: Int
        var minX: CGFloat
        var maxX: CGFloat
        var centreY: CGFloat
        var preferredHeight: CGFloat
        var updateCount: Int
        var widthExpansionCount: Int
        var tighterHeightCount: Int
        var heldCount: Int
    }


    /// Build 661 restores the useful Build 596 temporal-stability contract without
    /// restoring the old red-dominance/pinhole timer mask. One state belongs to one
    /// physical penalty slot activation. The player image freezes after paired
    /// physical confirmation; timer pixels refresh inside a locked source envelope.
    private enum RelayPenaltyVisualPhase: String {
        case acquiring
        case locked
        case staleAwaitingReacquisition
    }

    private struct RelayPenaltyVisualState {
        var activationID: UInt64
        var phase: RelayPenaltyVisualPhase
        var captureGeneration: Int
        var calibrationSignature: UInt64
        var pendingCalibrationSignature: UInt64?
        var pendingCalibrationCount: Int
        var physicalIdentityHash: UInt64?
        var frozenPlayerImage: CGImage?
        var frozenPlayerPixelHash: UInt64?
        var frozenPlayerShapeHash: UInt64?
        var pendingPlayerReplacementHash: UInt64?
        var pendingPlayerReplacementCount: Int
        var timerAcquisitionRect: CGRect?
        var timerAcquisitionCount: Int
        var lockedTimerRect: CGRect?
        /// Source-space centre of the complete character group captured during
        /// activation. It is not recomputed from multiplexed live frames.
        var lockedTimerCharacterCentreX: CGFloat?
        var lastTimerImage: CGImage?
        var lastTimerPixelHash: UInt64?
        var geometryRevision: UInt64
        var pendingExpansionRect: CGRect?
        var pendingExpansionCount: Int
        var rejectedShrinkCount: Int
        var acceptedExpansionCount: Int
        var heldWeakFrameCount: Int
        var lastDecision: String
    }

    /// Physical Clock movement state derived from compact image signatures only.
    /// It owns running/stopped transitions and immutable stoppage-image capture.
    /// Build 708 removes the former textual Clock OCR/timeline metadata lane.
    private struct RelayClockTimeoutState {
        var active = false
        var pendingCandidate: Bool?
        var matchingSamples = 0
        var startedAt: CFAbsoluteTime?
    }

    // MARK: - Recovery V RL-055 immutable Image Relay work identity

    /// One immutable identity follows an admitted scoreboard frame from capture
    /// through auxiliary processing to the state-commit boundary. It is execution
    /// evidence only; it does not own scoreboard, penalty or capture state.
    private struct RelayWorkToken: Sendable {
        let sourceSequence: Int?
        let captureGeneration: Int
        let sourceObservedAt: Date
        let sourceMonotonicTime: CFAbsoluteTime
    }

    private struct RelayWorkValidation: Sendable {
        let allowed: Bool
        let reason: String
        let ageSeconds: TimeInterval
        let supersededSeconds: TimeInterval
        let latestGeneration: Int
        let latestSourceSequence: Int?
    }

    /// Recovery BB: one newest admitted frame owns a lane-local crop cache.
    /// Auxiliary work asks only for the fields its current lane will consume;
    /// it never creates a 1920-wide full-board image or eagerly renders every
    /// score/period/penalty crop. The viewer Clock remains an independent direct
    /// field crop and therefore does not wait behind auxiliary GPU work.
    private final class DirectRelayFieldPreparation: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let layout: ScoreboardOCRLayout
        let boardCalibration: BoardCalibrationQuad
        let previewSize: CGSize
        let previewRotationDegrees: CGFloat
        let keys: Set<OCRRegionKey>
        private let rectificationQueue: DispatchQueue
        private var cachedCrops: [OCRRegionKey: CGImage] = [:]
        private let prepared: @Sendable (Int, Double) -> Void

        init(
            pixelBuffer: CVPixelBuffer,
            layout: ScoreboardOCRLayout,
            boardCalibration: BoardCalibrationQuad,
            previewSize: CGSize,
            previewRotationDegrees: CGFloat,
            keys: Set<OCRRegionKey>,
            rectificationQueue: DispatchQueue,
            prepared: @escaping @Sendable (Int, Double) -> Void
        ) {
            self.pixelBuffer = pixelBuffer
            self.layout = layout
            self.boardCalibration = boardCalibration
            self.previewSize = previewSize
            self.previewRotationDegrees = previewRotationDegrees
            self.keys = keys
            self.rectificationQueue = rectificationQueue
            self.prepared = prepared
        }

        func crops(
            for requestedKeys: Set<OCRRegionKey>,
            using processor: ScoreboardOCRProcessor
        ) -> [OCRRegionKey: CGImage] {
            rectificationQueue.sync {
                let admittedKeys = requestedKeys.intersection(keys)
                let missingKeys = admittedKeys.filter { cachedCrops[$0] == nil }
                guard !missingKeys.isEmpty else {
                    return cachedCrops.filter { admittedKeys.contains($0.key) }
                }
                let started = CFAbsoluteTimeGetCurrent()
                let crops = processor.imageRelayDirectFieldCrops(
                    from: pixelBuffer,
                    layout: layout,
                    boardCalibration: boardCalibration,
                    keys: Set(missingKeys),
                    deviceOrientation: .landscapeLeft,
                    previewSize: previewSize,
                    previewRotationDegrees: previewRotationDegrees
                )
                cachedCrops.merge(crops) { _, newest in newest }
                prepared(crops.count, max(0, (CFAbsoluteTimeGetCurrent() - started) * 1_000))
                return cachedCrops.filter { admittedKeys.contains($0.key) }
            }
        }
    }

    private struct ClockRelayRequest: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let sourceSequence: Int?
        let captureGeneration: Int
        let layout: ScoreboardOCRLayout
        let colourProfiles: OCRColourProfileSet
        let boardCalibration: BoardCalibrationQuad
        let previewSize: CGSize
        let previewRotationDegrees: CGFloat
        let sourceObservedAt: Date
        let sourceMonotonicTime: CFAbsoluteTime
        let scheduledDeadline: CFAbsoluteTime
        let enqueuedAt: CFAbsoluteTime
    }

    // MARK: - Recovery W RL-056 latest-only auxiliary execution

    /// One immutable auxiliary request owns only execution intent. When newer
    /// physical scoreboard evidence arrives while auxiliary work is busy, pending
    /// lane intents are merged onto the newest frame rather than queued FIFO.
    /// This is not a second scoreboard-state owner.
    private struct AuxiliaryRelayRequest: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let workToken: RelayWorkToken
        let runScore: Bool
        let runPeriod: Bool
        let runPenaltyPlayer: Bool
        let runPenaltyTimer: Bool
        let penaltyTimerWorkKeys: Set<OCRRegionKey>
        let layout: ScoreboardOCRLayout
        let colourProfiles: OCRColourProfileSet
        let boardCalibration: BoardCalibrationQuad
        let previewSize: CGSize
        let previewRotationDegrees: CGFloat
        let viewerAcceptedPenaltyPlayers: Set<OCRRegionKey>
        let homeRosterNumbers: Set<Int>
        let fieldPreparation: DirectRelayFieldPreparation

        var laneCount: Int {
            [runScore, runPeriod, runPenaltyPlayer, runPenaltyTimer].filter { $0 }.count
        }

        var laneDescription: String {
            [
                runScore ? "score" : nil,
                runPeriod ? "period" : nil,
                runPenaltyPlayer ? "penalty-player" : nil,
                runPenaltyTimer ? "penalty-timer" : nil
            ].compactMap { $0 }.joined(separator: ",")
        }

        func mergingLaneIntents(from older: AuxiliaryRelayRequest) -> AuxiliaryRelayRequest {
            AuxiliaryRelayRequest(
                pixelBuffer: pixelBuffer,
                workToken: workToken,
                runScore: runScore || older.runScore,
                runPeriod: runPeriod || older.runPeriod,
                runPenaltyPlayer: runPenaltyPlayer || older.runPenaltyPlayer,
                runPenaltyTimer: runPenaltyTimer || older.runPenaltyTimer,
                penaltyTimerWorkKeys: penaltyTimerWorkKeys.union(older.penaltyTimerWorkKeys),
                layout: layout,
                colourProfiles: colourProfiles,
                boardCalibration: boardCalibration,
                previewSize: previewSize,
                previewRotationDegrees: previewRotationDegrees,
                viewerAcceptedPenaltyPlayers: viewerAcceptedPenaltyPlayers,
                homeRosterNumbers: homeRosterNumbers,
                fieldPreparation: fieldPreparation
            )
        }

        func addingLaneIntents(
            score: Bool,
            period: Bool,
            penaltyPlayer: Bool,
            penaltyTimer: Bool,
            penaltyTimerKeys: Set<OCRRegionKey>
        ) -> AuxiliaryRelayRequest {
            AuxiliaryRelayRequest(
                pixelBuffer: pixelBuffer,
                workToken: workToken,
                runScore: runScore || score,
                runPeriod: runPeriod || period,
                runPenaltyPlayer: runPenaltyPlayer || penaltyPlayer,
                runPenaltyTimer: runPenaltyTimer || penaltyTimer,
                penaltyTimerWorkKeys: penaltyTimerWorkKeys.union(penaltyTimerKeys),
                layout: layout,
                colourProfiles: colourProfiles,
                boardCalibration: boardCalibration,
                previewSize: previewSize,
                previewRotationDegrees: previewRotationDegrees,
                viewerAcceptedPenaltyPlayers: viewerAcceptedPenaltyPlayers,
                homeRosterNumbers: homeRosterNumbers,
                fieldPreparation: fieldPreparation
            )
        }
    }

    private struct RelayClockMovementState {
        var previousSignature: [UInt8]?
        var stableSamples = 0
        var movingSamples = 0
        var isRunning: Bool?
        var movingRunStartedAt: CFAbsoluteTime?
        var restartCandidateStartedAt: CFAbsoluteTime?
        var restartCandidateLastMovementAt: CFAbsoluteTime?
        var restartCandidateBaselineSignature: [UInt8]?
        var restartCandidateLastDistinctSignature: [UInt8]?
        var restartCandidateChangeCount = 0
        var stableRunStartedAt: CFAbsoluteTime?
        var stableRunObservedAt: Date?
        var stableRunClockImage: CGImage?
        var stableRunSignature: [UInt8]?
        var lastMovementObservedAt: CFAbsoluteTime?
        var lastDecision = "awaiting-first-clock-image"
    }

    private let recognitionLock = NSLock()
    private var recognitionStates: [OCRRegionKey: RelayVisualRecognitionState] = [:]
    private var penaltyPlayerHashStates: [OCRRegionKey: RelayPenaltyPlayerHashState] = [:]
    /// Immutable stable Home player crops used only for bounded popup roster
    /// recognition. They never replace the viewer-facing relay image.
    private var penaltyPlayerFrozenRecognitionCrops: [OCRRegionKey: CGImage] = [:]
    /// Build 624 keeps the live penalty relay independent from player occupancy.
    /// A timer/player pair clears only after three consecutive timer-zone misses.
    private var penaltyTimerConsecutiveMisses: [OCRRegionKey: Int] = [:]
    /// Build 652 pair confirmation is keyed by the calibrated player zone.
    /// The timer key is resolved from the fixed player/timer pairing table.
    private var penaltyPairSignalStates: [OCRRegionKey: RelayPenaltyPairSignalState] = [:]
    /// Build 731 diagnostic-only transition cache. ScoreboardImageRelay remains the
    /// candidate owner; this set only prevents repeated sunlight rejection logs.
    private let penaltyAmbientLightLogLock = NSLock()
    private var penaltyAmbientLightRejectedKeys: Set<OCRRegionKey> = []
    private let penaltyVisualLock = NSLock()
    private var penaltyVisualStates: [OCRRegionKey: RelayPenaltyVisualState] = [:]
    private var nextPenaltyVisualActivationID: UInt64 = 0
    private var clockGeometryState: RelayClockGeometryState?
    private var clockMovementState = RelayClockMovementState()
    private var clockTimeoutState = RelayClockTimeoutState()
    private var metadataObserver: (@Sendable (ScoreboardImageRelayMetadataObservation) -> Void)?

    private var clockBusy = false
    private var scoreBusy = false
    private var periodBusy = false
    private var penaltyPlayerBusy = false
    private var penaltyTimerBusy = false
    // Build 737: each expensive penalty lane owns a capacity-one pending intent.
    // While a pass is running, older callbacks are coalesced. Completion makes
    // the lane immediately due so the next fresh camera frame is processed.
    private var clockRerunPending = false
    private var pendingClockRequest: ClockRelayRequest?
    private var nextClockDeadline: CFAbsoluteTime = 0
    private var clockDeadlineMisses = 0
    private var clockPendingFrameReplacements = 0
    private var maximumClockDeadlineMissMS: Double = 0
    private var penaltyPlayerRerunPending = false
    private var penaltyTimerRerunPending = false

    // Recovery W RL-056: the auxiliary queue owns at most one executing request
    // and one replaceable pending request. A newer frame replaces the pending
    // frame while preserving/merging its due lane intents.
    private var pendingAuxiliaryRequest: AuxiliaryRelayRequest?
    private var auxiliaryDrainScheduled = false
    private var auxiliaryLatestSubmissions = 0
    private var auxiliaryPendingReplacements = 0
    private var auxiliaryMergedLaneIntents = 0
    private var auxiliaryYieldToNewerFrameCount = 0
    private var auxiliaryObsoleteLaneSkips = 0
    private var auxiliaryExecutionOwnerYields = 0
    private var auxiliaryStageCancellationCount = 0

    private var lastClockSubmittedAt: CFAbsoluteTime = 0
    private var lastScoreSubmittedAt: CFAbsoluteTime = 0
    private var lastPeriodSubmittedAt: CFAbsoluteTime = 0
    private var lastPenaltyPlayerSubmittedAt: CFAbsoluteTime = 0
    private var lastPenaltyTimerSubmittedAt: CFAbsoluteTime = 0
    private var unacceptedPenaltyTimerDiscoveryCursor: Int = 0

    private var droppedClockBusyFrames = 0
    private var droppedScoreBusyFrames = 0
    private var droppedPeriodBusyFrames = 0
    private var droppedPenaltyPlayerBusyFrames = 0
    private var droppedPenaltyTimerBusyFrames = 0
    private var coalescedClockBusyRequests = 0
    private var coalescedPenaltyPlayerBusyRequests = 0
    private var coalescedPenaltyTimerBusyRequests = 0
    private var copiedFrames = 0
    private var copyFailures = 0
    private var completedClockPasses = 0
    private var completedScorePasses = 0
    private var completedPeriodPasses = 0
    private var completedPenaltyPlayerPasses = 0
    private var completedPenaltyTimerPasses = 0
    private var auxiliaryDirectFieldBatchPasses = 0
    private var activeClockImageJobs = 0
    private var activeAuxiliaryImageJobs = 0
    private var peakClockImageJobs = 0
    private var peakAuxiliaryImageJobs = 0
    private var directFieldImagesProduced = 0
    private var auxiliaryDirectCropBatches = 0
    private var auxiliaryDirectCropLastMS = 0.0
    private var auxiliaryDirectCropMaxMS = 0.0
    private var auxiliaryDirectCropCount = 0
    private var writerCriticalScoreboardYields = 0
    // Build 582 keeps the last successful timer presentation measurements across
    // Command Centre thermal idle so a post-run All Logs export can prove whether
    // height normalisation actually reached the published image.
    private var lastPenaltyTimerPresentationDiagnostics: [OCRRegionKey: String] = [:]
    private var lastPenaltyTimerLoggedPublicationHash: [OCRRegionKey: UInt64] = [:]
    private var lastPenaltyTimerPublishedAt: [OCRRegionKey: CFAbsoluteTime] = [:]
    private var lastClockPresentationDiagnostic: String = "none"

    // Recovery V RL-055: current frame identity is tracked only to validate work
    // freshness at commit time. It is not a second CaptureEngine or FrameHub owner.
    private var latestRelayCaptureGeneration: Int = 0
    private var latestRelaySourceSequence: Int?
    private var latestRelaySourceMonotonicTime: CFAbsoluteTime = 0
    private var staleAuxiliaryBatchDrops: Int = 0
    private var stalePenaltyPlayerCommitDrops: Int = 0
    private var stalePenaltyTimerCommitDrops: Int = 0

    /// Build 579 field-specific service cadence.
    ///
    /// Clock remains a direct, unconditional image publisher with no semantic
    /// validation. Build 619 gives penalty-player zones a 0.30-second lightweight
    /// hash/occupancy lane. Player recognition is not continuous: it is attempted
    /// only against a three-frame stable frozen Home crop, at most three times in
    /// 2.5 seconds. Period remains 5.00 seconds and active penalty timers retain the Clock's
    /// direct 0.30-second cadence.
    private let minimumClockSubmissionInterval: CFTimeInterval = 0.30
    private let minimumScoreSubmissionInterval: CFTimeInterval = 2.00
    private let minimumPeriodSubmissionInterval: CFTimeInterval = 5.00
    private var minimumPenaltyPlayerSubmissionInterval: CFTimeInterval {
        RinkLensRiskFeaturePolicy.isEnabled(.changeDrivenPenaltySchedulerV22) ? 0.45 : 0.30
    }
    private let minimumPenaltyTimerSubmissionInterval: CFTimeInterval = 0.30
    // Build 641: movement decisions must never consume a frame that was held
    // behind a long OCR/Image Relay pass. A stale frame can describe an earlier
    // running/stopped state and release the wrong event popup against the live game.
    private let maximumClockMovementSampleAge: CFTimeInterval = 2.00
    // A running scoreboard normally changes once per second. Requiring more than
    // two full seconds of one unchanged digit signature prevents a missed tick or
    // one delayed sample from fragmenting the game into false stoppages.
    private let minimumClockStopStableDuration: CFTimeInterval = 2.10

    static let relayedKeys: Set<OCRRegionKey> = [
        .clock, .homeScore, .awayScore, .period,
        .homePenalty1Player, .homePenalty1Time,
        .homePenalty2Player, .homePenalty2Time,
        .awayPenalty1Player, .awayPenalty1Time,
        .awayPenalty2Player, .awayPenalty2Time
    ]

    private static let scoreRelayedKeys: Set<OCRRegionKey> = [.homeScore, .awayScore]
    private static let periodRelayedKeys: Set<OCRRegionKey> = [.period]
    private static let penaltyPlayerRelayedKeys: Set<OCRRegionKey> = [
        .homePenalty1Player, .homePenalty2Player,
        .awayPenalty1Player, .awayPenalty2Player
    ]
    private static let orderedPenaltyPlayerKeys: [OCRRegionKey] = [
        .homePenalty1Player, .homePenalty2Player,
        .awayPenalty1Player, .awayPenalty2Player
    ]
    private static let penaltyTimerRelayedKeys: Set<OCRRegionKey> = [
        .homePenalty1Time, .homePenalty2Time,
        .awayPenalty1Time, .awayPenalty2Time
    ]
    private static let penaltyTimerPairs: [(timer: OCRRegionKey, player: OCRRegionKey)] = [
        (.homePenalty1Time, .homePenalty1Player),
        (.homePenalty2Time, .homePenalty2Player),
        (.awayPenalty1Time, .awayPenalty1Player),
        (.awayPenalty2Time, .awayPenalty2Player)
    ]
    private static let allAuxiliaryRelayCropKeys: Set<OCRRegionKey> =
        scoreRelayedKeys
            .union(periodRelayedKeys)
            .union(penaltyPlayerRelayedKeys)
            .union(penaltyTimerRelayedKeys)


    func setMetadataObserver(
        _ observer: (@Sendable (ScoreboardImageRelayMetadataObservation) -> Void)?
    ) {
        lock.lock()
        metadataObserver = observer
        lock.unlock()
    }

    private func emitMetadata(_ observation: ScoreboardImageRelayMetadataObservation) {
        lock.lock()
        let observer = metadataObserver
        lock.unlock()
        observer?(observation)
    }

    // Recovery V RL-055: register newest admitted frame identity. The capture
    // generation must match at every penalty commit, and old same-generation work
    // is bounded by monotonic age rather than by wall-clock scheduling assumptions.
    private func registerRelayWorkToken(_ token: RelayWorkToken) {
        lock.lock()
        if token.captureGeneration > latestRelayCaptureGeneration {
            latestRelayCaptureGeneration = token.captureGeneration
            latestRelaySourceSequence = token.sourceSequence
            latestRelaySourceMonotonicTime = token.sourceMonotonicTime
        } else if token.captureGeneration == latestRelayCaptureGeneration,
                  token.sourceMonotonicTime >= latestRelaySourceMonotonicTime {
            latestRelaySourceSequence = token.sourceSequence
            latestRelaySourceMonotonicTime = token.sourceMonotonicTime
        }
        lock.unlock()
    }

    private func validateRelayWorkToken(
        _ token: RelayWorkToken,
        maximumAgeSeconds: TimeInterval
    ) -> RelayWorkValidation {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let latestGeneration = latestRelayCaptureGeneration
        let latestSequence = latestRelaySourceSequence
        let latestMonotonic = latestRelaySourceMonotonicTime
        lock.unlock()

        let age = max(0, now - token.sourceMonotonicTime)
        let superseded = max(0, latestMonotonic - token.sourceMonotonicTime)
        let generationMatches = latestGeneration == 0 || latestGeneration == token.captureGeneration
        let ageAllowed = age <= maximumAgeSeconds
        let supersededAllowed = superseded <= maximumAgeSeconds
        let allowed = generationMatches && ageAllowed && supersededAllowed
        let reason: String
        if !generationMatches {
            reason = "capture-generation-superseded token=\(token.captureGeneration) latest=\(latestGeneration)"
        } else if !ageAllowed {
            reason = "source-frame-too-old age=\(String(format: "%.3f", age))s max=\(String(format: "%.3f", maximumAgeSeconds))s"
        } else if !supersededAllowed {
            reason = "newer-frame-superseded tokenLag=\(String(format: "%.3f", superseded))s max=\(String(format: "%.3f", maximumAgeSeconds))s"
        } else {
            reason = "fresh"
        }
        return RelayWorkValidation(
            allowed: allowed,
            reason: reason,
            ageSeconds: age,
            supersededSeconds: superseded,
            latestGeneration: latestGeneration,
            latestSourceSequence: latestSequence
        )
    }

    private func recordStalePenaltyCommitDrop(
        lane: String,
        entityID: String,
        token: RelayWorkToken,
        validation: RelayWorkValidation
    ) {
        lock.lock()
        if lane == "penalty-player" {
            stalePenaltyPlayerCommitDrops &+= 1
        } else {
            stalePenaltyTimerCommitDrops &+= 1
        }
        lock.unlock()
        RinkLensStructuredEventLogger.shared.record(
            domain: .penalty,
            event: "image_relay_stale_penalty_work_discarded",
            entityID: entityID,
            previous: [
                "sourceSequence": token.sourceSequence.map(String.init) ?? "none",
                "captureGeneration": String(token.captureGeneration),
                "sourceObservedAt": token.sourceObservedAt.ISO8601Format()
            ],
            next: [
                "mutation": "discarded-before-state-commit",
                "lane": lane,
                "sourceFrameAgeMs": String(format: "%.1f", validation.ageSeconds * 1_000),
                "supersededByNewerFrameMs": String(format: "%.1f", validation.supersededSeconds * 1_000),
                "latestGeneration": String(validation.latestGeneration),
                "latestSourceSequence": validation.latestSourceSequence.map(String.init) ?? "none"
            ],
            source: "ScoreboardImageRelayEngine",
            reason: validation.reason,
            captureGeneration: token.captureGeneration,
            authoritativeOwner: "ScoreboardImageRelayEngine"
        )
    }

    private func finishStaleAuxiliaryBatch(
        token: RelayWorkToken,
        validation: RelayWorkValidation,
        runScore: Bool,
        runPeriod: Bool,
        runPenaltyPlayer: Bool,
        runPenaltyTimer: Bool
    ) {
        lock.lock()
        staleAuxiliaryBatchDrops &+= 1
        if runScore {
            scoreBusy = false
            lastScoreSubmittedAt = 0
        }
        if runPeriod {
            periodBusy = false
            lastPeriodSubmittedAt = 0
        }
        if runPenaltyPlayer {
            penaltyPlayerBusy = false
            penaltyPlayerRerunPending = false
            lastPenaltyPlayerSubmittedAt = 0
        }
        if runPenaltyTimer {
            penaltyTimerBusy = false
            penaltyTimerRerunPending = false
            lastPenaltyTimerSubmittedAt = 0
        }
        lock.unlock()

        RinkLensStructuredEventLogger.shared.record(
            domain: .scoreboardPresentation,
            event: "image_relay_stale_auxiliary_batch_discarded",
            entityID: "auxiliary-image-relay",
            previous: [
                "sourceSequence": token.sourceSequence.map(String.init) ?? "none",
                "captureGeneration": String(token.captureGeneration),
                "sourceObservedAt": token.sourceObservedAt.ISO8601Format()
            ],
            next: [
                "mutation": "none",
                "expensiveCropWork": "skipped",
                "sourceFrameAgeMs": String(format: "%.1f", validation.ageSeconds * 1_000),
                "supersededByNewerFrameMs": String(format: "%.1f", validation.supersededSeconds * 1_000),
                "lanes": [
                    runScore ? "score" : nil,
                    runPeriod ? "period" : nil,
                    runPenaltyPlayer ? "penalty-player" : nil,
                    runPenaltyTimer ? "penalty-timer" : nil
                ].compactMap { $0 }.joined(separator: ",")
            ],
            source: "ScoreboardImageRelayEngine.auxiliary",
            reason: validation.reason + "; next fresh camera frame is made immediately due",
            captureGeneration: token.captureGeneration,
            authoritativeOwner: "ScoreboardImageRelayEngine"
        )
    }

    private func yieldAuxiliaryBatchToExecutionOwner(
        request: AuxiliaryRelayRequest,
        runScore: Bool,
        runPeriod: Bool,
        runPenaltyPlayer: Bool,
        runPenaltyTimer: Bool,
        checkpoint: String
    ) {
        lock.lock()
        auxiliaryExecutionOwnerYields &+= 1
        if runScore {
            scoreBusy = false
            lastScoreSubmittedAt = 0
        }
        if runPeriod {
            periodBusy = false
            lastPeriodSubmittedAt = 0
        }
        if runPenaltyPlayer {
            penaltyPlayerBusy = false
            penaltyPlayerRerunPending = false
            lastPenaltyPlayerSubmittedAt = 0
        }
        if runPenaltyTimer {
            penaltyTimerBusy = false
            penaltyTimerRerunPending = false
            lastPenaltyTimerSubmittedAt = 0
        }
        lock.unlock()
        RinkLensExecutionCoordinator.shared.noteAuxiliaryYield()
        let sequenceText = request.workToken.sourceSequence.map(String.init) ?? "none"
        MainThreadStallMonitor.traceFromAnyQueue(
            "Recovery AF Image Relay auxiliary yielded checkpoint=\(checkpoint) sequence=\(sequenceText)"
        )
    }

    private enum AuxiliaryStageAdmissionPolicy {
        case standard
        case scoreSemantic
        case penaltySemantic
    }

    /// Recovery AG / RL-056B: expensive auxiliary work must not merely fence
    /// stale results at the final commit boundary. Revalidate both execution
    /// admission and immutable frame identity between processing stages so old
    /// work releases CPU/GPU resources as soon as it becomes obsolete.
    private func auxiliaryStageMayContinue(
        token: RelayWorkToken,
        maximumAgeSeconds: TimeInterval,
        checkpoint: String,
        admissionPolicy: AuxiliaryStageAdmissionPolicy = .standard
    ) -> Bool {
        let executionAdmitted: Bool
        switch admissionPolicy {
        case .standard:
            executionAdmitted = RinkLensExecutionCoordinator.shared.admitsAuxiliaryWork()
        case .scoreSemantic:
            executionAdmitted = RinkLensExecutionCoordinator.shared.admitsScoreSemanticWork()
        case .penaltySemantic:
            executionAdmitted = RinkLensExecutionCoordinator.shared.admitsPenaltySemanticWork()
        }
        guard executionAdmitted else {
            lock.lock()
            auxiliaryStageCancellationCount &+= 1
            lock.unlock()
            RinkLensExecutionCoordinator.shared.noteAuxiliaryYield()
            MainThreadStallMonitor.traceFromAnyQueue(
                "Recovery AG Image Relay stage cancelled by execution owner checkpoint=\(checkpoint) sequence=\(token.sourceSequence.map(String.init) ?? "none")"
            )
            return false
        }

        let validation = validateRelayWorkToken(token, maximumAgeSeconds: maximumAgeSeconds)
        guard validation.allowed else {
            lock.lock()
            auxiliaryStageCancellationCount &+= 1
            auxiliaryObsoleteLaneSkips &+= 1
            lock.unlock()
            RinkLensStructuredEventLogger.shared.record(
                domain: .scoreboardPresentation,
                event: "image_relay_auxiliary_stage_cancelled",
                entityID: checkpoint,
                previous: [
                    "sourceSequence": token.sourceSequence.map(String.init) ?? "none",
                    "captureGeneration": String(token.captureGeneration)
                ],
                next: [
                    "mutation": "none",
                    "sourceFrameAgeMs": String(format: "%.1f", validation.ageSeconds * 1_000),
                    "supersededByNewerFrameMs": String(format: "%.1f", validation.supersededSeconds * 1_000)
                ],
                source: "ScoreboardImageRelayEngine.auxiliaryStageMayContinue",
                reason: validation.reason,
                captureGeneration: token.captureGeneration,
                authoritativeOwner: "ScoreboardImageRelayEngine"
            )
            return false
        }
        return true
    }

    private static func auxiliaryRequestIsNewer(
        _ lhs: AuxiliaryRelayRequest,
        than rhs: AuxiliaryRelayRequest
    ) -> Bool {
        if lhs.workToken.captureGeneration != rhs.workToken.captureGeneration {
            return lhs.workToken.captureGeneration > rhs.workToken.captureGeneration
        }
        return lhs.workToken.sourceMonotonicTime >= rhs.workToken.sourceMonotonicTime
    }

    /// Replaces FIFO auxiliary submission with one latest-only pending slot.
    /// Outstanding lane intents survive replacement, but their pixels/settings are
    /// rebound to the newest immutable physical scoreboard frame.
    private func enqueueLatestAuxiliaryRequest(_ request: AuxiliaryRelayRequest) {
        var shouldSchedule = false
        var didActivate = false
        var replacementLog: (old: AuxiliaryRelayRequest, new: AuxiliaryRelayRequest)?

        lock.lock()
        auxiliaryLatestSubmissions &+= 1
        if let existing = pendingAuxiliaryRequest {
            let freshest: AuxiliaryRelayRequest
            let older: AuxiliaryRelayRequest
            if Self.auxiliaryRequestIsNewer(request, than: existing) {
                freshest = request
                older = existing
            } else {
                freshest = existing
                older = request
            }
            let beforeCount = freshest.laneCount
            let merged = freshest.mergingLaneIntents(from: older)
            auxiliaryPendingReplacements &+= 1
            auxiliaryMergedLaneIntents &+= max(0, merged.laneCount - beforeCount)
            pendingAuxiliaryRequest = merged
            replacementLog = (existing, merged)
        } else {
            pendingAuxiliaryRequest = request
        }
        if !auxiliaryDrainScheduled {
            auxiliaryDrainScheduled = true
            shouldSchedule = true
            didActivate = auxiliaryLatestSubmissions == 1
        }
        lock.unlock()

        if didActivate {
            RinkLensStructuredEventLogger.shared.record(
                domain: .scoreboardPresentation,
                event: "image_relay_latest_auxiliary_owner_activated",
                entityID: "auxiliary-image-relay",
                previous: ["execution": "FIFO DispatchQueue.async batches"],
                next: ["execution": "one active + one replaceable pending latest frame", "mergePolicy": "due lane intents move to newest frame"],
                source: "ScoreboardImageRelayEngine",
                reason: "Recovery W RL-056 removes live-scoreboard history processing and auxiliary head-of-line queue growth",
                captureGeneration: request.workToken.captureGeneration,
                authoritativeOwner: "ScoreboardImageRelayEngine"
            )
        }
        if let replacementLog, auxiliaryPendingReplacements <= 3 {
            RinkLensStructuredEventLogger.shared.record(
                domain: .scoreboardPresentation,
                event: "image_relay_auxiliary_pending_replaced",
                entityID: "auxiliary-image-relay",
                previous: [
                    "sourceSequence": replacementLog.old.workToken.sourceSequence.map(String.init) ?? "none",
                    "generation": String(replacementLog.old.workToken.captureGeneration),
                    "lanes": replacementLog.old.laneDescription
                ],
                next: [
                    "sourceSequence": replacementLog.new.workToken.sourceSequence.map(String.init) ?? "none",
                    "generation": String(replacementLog.new.workToken.captureGeneration),
                    "lanes": replacementLog.new.laneDescription
                ],
                source: "ScoreboardImageRelayEngine",
                reason: "newest physical frame replaced pending auxiliary history while preserving due field intent",
                captureGeneration: replacementLog.new.workToken.captureGeneration,
                authoritativeOwner: "ScoreboardImageRelayEngine"
            )
        }

        if shouldSchedule {
            scoreboardAuxiliaryServiceQueue.async { [weak self] in
                self?.drainLatestAuxiliaryRequests()
            }
        }
    }

    private func drainLatestAuxiliaryRequests() {
        while true {
            let request: AuxiliaryRelayRequest?
            lock.lock()
            request = pendingAuxiliaryRequest
            pendingAuxiliaryRequest = nil
            if request == nil { auxiliaryDrainScheduled = false }
            lock.unlock()

            guard let request else { return }
            autoreleasepool { processLatestAuxiliaryRequest(request) }
        }
    }

    /// After one admitted lane has completed, transfer only its unstarted
    /// remainder onto a newer pending frame. The current lane is never rebound:
    /// doing that under continuous input can starve semantic work forever.
    private func yieldAuxiliaryRemainderToNewerFrame(
        current: AuxiliaryRelayRequest,
        score: Bool,
        period: Bool,
        penaltyPlayer: Bool,
        penaltyTimer: Bool,
        penaltyTimerKeys: Set<OCRRegionKey>,
        checkpoint: String
    ) -> Bool {
        guard score || period || penaltyPlayer || penaltyTimer else { return false }
        var yieldedTo: AuxiliaryRelayRequest?
        lock.lock()
        if let pending = pendingAuxiliaryRequest,
           Self.auxiliaryRequestIsNewer(pending, than: current),
           RinkLensAuxiliaryLaneExecutionPolicy.decision(
                currentFrameIsValid: true,
                laneHasStarted: true,
                hasNewerPendingFrame: true
           ) == .rebindUnstartedRemainder {
            let beforeCount = pending.laneCount
            let merged = pending.addingLaneIntents(
                score: score,
                period: period,
                penaltyPlayer: penaltyPlayer,
                penaltyTimer: penaltyTimer,
                penaltyTimerKeys: penaltyTimerKeys
            )
            pendingAuxiliaryRequest = merged
            auxiliaryMergedLaneIntents &+= max(0, merged.laneCount - beforeCount)
            auxiliaryYieldToNewerFrameCount &+= 1
            yieldedTo = merged
        }
        lock.unlock()

        guard let yieldedTo else { return false }
        if auxiliaryYieldToNewerFrameCount <= 6 {
            RinkLensStructuredEventLogger.shared.record(
                domain: .scoreboardPresentation,
                event: "image_relay_auxiliary_remainder_rebound",
                entityID: "auxiliary-image-relay",
                previous: [
                    "sourceSequence": current.workToken.sourceSequence.map(String.init) ?? "none",
                    "generation": String(current.workToken.captureGeneration),
                    "remainingLanes": [
                        score ? "score" : nil,
                        period ? "period" : nil,
                        penaltyPlayer ? "penalty-player" : nil,
                        penaltyTimer ? "penalty-timer" : nil
                    ].compactMap { $0 }.joined(separator: ",")
                ],
                next: [
                    "sourceSequence": yieldedTo.workToken.sourceSequence.map(String.init) ?? "none",
                    "generation": String(yieldedTo.workToken.captureGeneration),
                    "mergedLanes": yieldedTo.laneDescription
                ],
                source: "ScoreboardImageRelayEngine",
                reason: "Recovery W latest-only checkpoint=\(checkpoint)",
                captureGeneration: yieldedTo.workToken.captureGeneration,
                authoritativeOwner: "ScoreboardImageRelayEngine"
            )
        }
        return true
    }

    private func markAuxiliaryLaneComplete(_ lane: String) {
        lock.lock()
        switch lane {
        case "score":
            scoreBusy = false
            completedScorePasses &+= 1
        case "period":
            periodBusy = false
            completedPeriodPasses &+= 1
        case "penalty-timer":
            let rerunPending = penaltyTimerRerunPending
            penaltyTimerRerunPending = false
            penaltyTimerBusy = false
            if rerunPending { lastPenaltyTimerSubmittedAt = 0 }
            completedPenaltyTimerPasses &+= 1
        case "penalty-player":
            let rerunPending = penaltyPlayerRerunPending
            penaltyPlayerRerunPending = false
            penaltyPlayerBusy = false
            if rerunPending { lastPenaltyPlayerSubmittedAt = 0 }
            completedPenaltyPlayerPasses &+= 1
        default:
            break
        }
        lock.unlock()
    }

    private func auxiliaryCrops(
        for keys: Set<OCRRegionKey>,
        request: AuxiliaryRelayRequest
    ) -> [OCRRegionKey: CGImage] {
        let crops = request.fieldPreparation.crops(for: keys, using: processor)
        lock.lock()
        directFieldImagesProduced &+= crops.count
        lock.unlock()
        return crops
    }

    private func noteAuxiliaryDirectCropBatch(cropCount: Int, elapsedMilliseconds: Double) {
        lock.lock()
        auxiliaryDirectCropBatches &+= 1
        auxiliaryDirectCropCount &+= cropCount
        auxiliaryDirectCropLastMS = elapsedMilliseconds
        auxiliaryDirectCropMaxMS = max(auxiliaryDirectCropMaxMS, elapsedMilliseconds)
        let shouldLog = auxiliaryDirectCropBatches == 1
        lock.unlock()
        if shouldLog {
            RinkLensStructuredEventLogger.shared.record(
                domain: .scoreboardPresentation,
                event: "image_relay_lane_local_crop_authority_activated",
                entityID: "scoreboard-image-processing",
                previous: ["execution": "1920-wide full-board render plus all auxiliary crops"],
                next: ["execution": "serial lane-local direct field crops", "firstBatchCropCount": String(cropCount)],
                source: "ScoreboardImageRelayEngine",
                reason: "Recovery BB removes unused auxiliary GPU work that delayed the independent viewer Clock",
                authoritativeOwner: "ScoreboardImageRelayEngine"
            )
        }
    }

    private func processLatestAuxiliaryRequest(_ request: AuxiliaryRelayRequest) {
        let executionCoordinator = RinkLensExecutionCoordinator.shared
        let standardAuxiliaryAdmitted = executionCoordinator.admitsAuxiliaryWork()
        let scoreSemanticAdmitted = request.runScore && executionCoordinator.admitsScoreSemanticWork()
        let penaltySemanticAdmitted = (request.runPenaltyPlayer || request.runPenaltyTimer)
            && executionCoordinator.admitsPenaltySemanticWork()
        guard standardAuxiliaryAdmitted || scoreSemanticAdmitted || penaltySemanticAdmitted else {
            yieldAuxiliaryBatchToExecutionOwner(
                request: request,
                runScore: request.runScore,
                runPeriod: request.runPeriod,
                runPenaltyPlayer: request.runPenaltyPlayer,
                runPenaltyTimer: request.runPenaltyTimer,
                checkpoint: "entry"
            )
            return
        }
        // Recovery V boundary is retained. Recovery W should normally keep this
        // fresh by construction; the boundary remains fail-closed for suspension
        // or an unexpectedly long single processing operation.
        let entryValidation = validateRelayWorkToken(request.workToken, maximumAgeSeconds: 5.5)
        guard entryValidation.allowed else {
            finishStaleAuxiliaryBatch(
                token: request.workToken,
                validation: entryValidation,
                runScore: request.runScore,
                runPeriod: request.runPeriod,
                runPenaltyPlayer: request.runPenaltyPlayer,
                runPenaltyTimer: request.runPenaltyTimer
            )
            return
        }

        lock.lock()
        activeAuxiliaryImageJobs &+= 1
        peakAuxiliaryImageJobs = max(peakAuxiliaryImageJobs, activeAuxiliaryImageJobs)
        auxiliaryDirectFieldBatchPasses &+= 1
        let sharedPass = auxiliaryDirectFieldBatchPasses
        lock.unlock()
        defer {
            lock.lock(); activeAuxiliaryImageJobs = max(0, activeAuxiliaryImageJobs - 1); lock.unlock()
        }

        if sharedPass == 1 {
            RinkLensStructuredEventLogger.shared.record(
                domain: .scoreboardPresentation,
                event: "relay_direct_field_batch_armed",
                entityID: "score-period-penalty-direct-fields",
                previous: ["execution": "FIFO auxiliary batches with all due crops rendered up front"],
                next: ["execution": "latest-only auxiliary request", "cropPolicy": "lane-local; remaining work rebounds to newest frame", "processor": "single-shared-CI"],
                source: "ScoreboardImageRelayEngine",
                reason: "Recovery W RL-056 removes obsolete auxiliary history and avoids rendering not-yet-needed field crops",
                captureGeneration: request.workToken.captureGeneration,
                authoritativeOwner: "ScoreboardImageRelayEngine"
            )
        }

        var remainingScore = request.runScore
        var remainingPeriod = request.runPeriod
        var remainingPenaltyTimer = request.runPenaltyTimer
        var remainingPenaltyPlayer = request.runPenaltyPlayer

        if remainingPenaltyTimer {
            // Recovery DY: the timer is the time-critical half of the physical
            // penalty acknowledgement. The 17:48 run proved direct cropping
            // was cheap, but Score + player work made its source frame 3.7-3.9s
            // old before timer commit. Execute it first from the newest
            // capacity-one request; player recognition can then attach metadata
            // to the timer-backed pair without delaying its physical evidence.
            guard RinkLensExecutionCoordinator.shared.admitsPenaltySemanticWork() else {
                yieldAuxiliaryBatchToExecutionOwner(
                    request: request,
                    runScore: remainingScore,
                    runPeriod: remainingPeriod,
                    runPenaltyPlayer: remainingPenaltyPlayer,
                    runPenaltyTimer: remainingPenaltyTimer,
                    checkpoint: "before-penalty-timer"
                )
                return
            }
            let timerMaximumAge: TimeInterval = request.viewerAcceptedPenaltyPlayers.isEmpty ? 2.5 : 1.0
            let timerValidation = validateRelayWorkToken(
                request.workToken,
                maximumAgeSeconds: timerMaximumAge
            )
            if timerValidation.allowed {
                let timerCropKeys: Set<OCRRegionKey>
                if RinkLensRiskFeaturePolicy.isEnabled(.penaltyTimerFastLaneV3) {
                    timerCropKeys = request.penaltyTimerWorkKeys
                } else {
                    timerCropKeys = request.penaltyTimerWorkKeys.union(Self.penaltyPlayerRelayedKeys)
                }
                let crops = auxiliaryCrops(for: timerCropKeys, request: request)
                processPenaltyTimerLane(
                    name: "penalty-timer-latest-auxiliary",
                    pixelBuffer: request.pixelBuffer,
                    processor: processor,
                    sourceSequence: request.workToken.sourceSequence,
                    captureGeneration: request.workToken.captureGeneration,
                    layout: request.layout,
                    colourProfiles: request.colourProfiles,
                    boardCalibration: request.boardCalibration,
                    previewSize: request.previewSize,
                    previewRotationDegrees: request.previewRotationDegrees,
                    workToken: request.workToken,
                    viewerAcceptedPenaltyPlayers: request.viewerAcceptedPenaltyPlayers,
                    requestedTimerKeys: request.penaltyTimerWorkKeys,
                    precomputedCrops: crops
                )
            } else {
                lock.lock()
                auxiliaryObsoleteLaneSkips &+= 1
                lastPenaltyTimerSubmittedAt = 0
                lock.unlock()
            }
            markAuxiliaryLaneComplete("penalty-timer")
            remainingPenaltyTimer = false
            // The timer consumed the freshest physical frame first. If capture
            // has already supplied a newer capacity-one request, attach the
            // unstarted player/score/period intents to that frame instead of
            // spending another 1-2 seconds recognising from the timer's now-old
            // pixels. While this timer was busy, incoming requests could not own
            // another timer pass, so the rebound begins with player identity and
            // completes the semantic pair rather than cycling timer-first again.
            if yieldAuxiliaryRemainderToNewerFrame(
                current: request,
                score: remainingScore,
                period: remainingPeriod,
                penaltyPlayer: remainingPenaltyPlayer,
                penaltyTimer: false,
                penaltyTimerKeys: request.penaltyTimerWorkKeys,
                checkpoint: "after-penalty-timer-complete"
            ) { return }
        }

        // Recovery DY: player identity immediately follows timer evidence so
        // the two halves of the physical penalty pair complete before Score or
        // presentation-only Period work. It remains latest-only and
        // freshness-fenced, but a
        // short RecordingWriter frame critical section cannot starve MatchState
        // for the full recording lifetime.
        if remainingPenaltyPlayer {
            guard RinkLensExecutionCoordinator.shared.admitsPenaltySemanticWork() else {
                yieldAuxiliaryBatchToExecutionOwner(
                    request: request,
                    runScore: remainingScore,
                    runPeriod: remainingPeriod,
                    runPenaltyPlayer: remainingPenaltyPlayer,
                    runPenaltyTimer: remainingPenaltyTimer,
                    checkpoint: "before-penalty-player"
                )
                return
            }
            let playerValidation = validateRelayWorkToken(
                request.workToken,
                maximumAgeSeconds: 2.5
            )
            guard playerValidation.allowed else {
                lock.lock()
                auxiliaryObsoleteLaneSkips &+= 1
                lastPenaltyPlayerSubmittedAt = 0
                lock.unlock()
                markAuxiliaryLaneComplete("penalty-player")
                return
            }

            let crops = auxiliaryCrops(for: Self.penaltyPlayerRelayedKeys, request: request)
            processPenaltyPlayerLane(
                name: "penalty-player-latest-auxiliary",
                pixelBuffer: request.pixelBuffer,
                processor: processor,
                sourceSequence: request.workToken.sourceSequence,
                captureGeneration: request.workToken.captureGeneration,
                layout: request.layout,
                colourProfiles: request.colourProfiles,
                boardCalibration: request.boardCalibration,
                previewSize: request.previewSize,
                previewRotationDegrees: request.previewRotationDegrees,
                workToken: request.workToken,
                homeRosterNumbers: request.homeRosterNumbers,
                precomputedCrops: crops
            )
            markAuxiliaryLaneComplete("penalty-player")
            remainingPenaltyPlayer = false
            if !remainingPenaltyTimer && yieldAuxiliaryRemainderToNewerFrame(
                current: request,
                score: remainingScore,
                period: remainingPeriod,
                penaltyPlayer: false,
                penaltyTimer: remainingPenaltyTimer,
                penaltyTimerKeys: request.penaltyTimerWorkKeys,
                checkpoint: "after-penalty-player-complete"
            ) { return }
        }

        if remainingScore {
            guard RinkLensExecutionCoordinator.shared.admitsScoreSemanticWork() else {
                yieldAuxiliaryBatchToExecutionOwner(
                    request: request,
                    runScore: remainingScore,
                    runPeriod: remainingPeriod,
                    runPenaltyPlayer: remainingPenaltyPlayer,
                    runPenaltyTimer: remainingPenaltyTimer,
                    checkpoint: "before-score"
                )
                return
            }
            let validation = validateRelayWorkToken(request.workToken, maximumAgeSeconds: 2.5)
            if validation.allowed {
                let crops = auxiliaryCrops(for: Self.scoreRelayedKeys, request: request)
                processLane(
                    name: "score-2.0s-latest-frame",
                    pixelBuffer: request.pixelBuffer,
                    processor: processor,
                    keys: Self.scoreRelayedKeys,
                    sourceSequence: request.workToken.sourceSequence,
                    captureGeneration: request.workToken.captureGeneration,
                    layout: request.layout,
                    colourProfiles: request.colourProfiles,
                    boardCalibration: request.boardCalibration,
                    previewSize: request.previewSize,
                    previewRotationDegrees: request.previewRotationDegrees,
                    precomputedCrops: crops,
                    workToken: request.workToken,
                    maximumPublicationAgeSeconds: 2.5,
                    admissionPolicy: .scoreSemantic
                )
            } else {
                lock.lock(); auxiliaryObsoleteLaneSkips &+= 1; lastScoreSubmittedAt = 0; lock.unlock()
            }
            markAuxiliaryLaneComplete("score")
            remainingScore = false
            if yieldAuxiliaryRemainderToNewerFrame(
                current: request,
                score: false,
                period: remainingPeriod,
                penaltyPlayer: remainingPenaltyPlayer,
                penaltyTimer: remainingPenaltyTimer,
                penaltyTimerKeys: request.penaltyTimerWorkKeys,
                checkpoint: "after-score-complete"
            ) { return }
        }

        if remainingPeriod {
            guard RinkLensExecutionCoordinator.shared.admitsAuxiliaryWork() else {
                yieldAuxiliaryBatchToExecutionOwner(
                    request: request,
                runScore: remainingScore,
                runPeriod: remainingPeriod,
                runPenaltyPlayer: remainingPenaltyPlayer,
                runPenaltyTimer: remainingPenaltyTimer,
                checkpoint: "before-period"
                )
                return
            }
            let validation = validateRelayWorkToken(request.workToken, maximumAgeSeconds: 5.5)
            if validation.allowed {
                let crops = auxiliaryCrops(for: Self.periodRelayedKeys, request: request)
                processLane(
                    name: "period-5.0s-latest-frame",
                    pixelBuffer: request.pixelBuffer,
                    processor: processor,
                    keys: Self.periodRelayedKeys,
                    sourceSequence: request.workToken.sourceSequence,
                    captureGeneration: request.workToken.captureGeneration,
                    layout: request.layout,
                    colourProfiles: request.colourProfiles,
                    boardCalibration: request.boardCalibration,
                    previewSize: request.previewSize,
                    previewRotationDegrees: request.previewRotationDegrees,
                    precomputedCrops: crops,
                    workToken: request.workToken,
                    maximumPublicationAgeSeconds: 5.5
                )
            } else {
                lock.lock(); auxiliaryObsoleteLaneSkips &+= 1; lastPeriodSubmittedAt = 0; lock.unlock()
            }
            markAuxiliaryLaneComplete("period")
            remainingPeriod = false
            if yieldAuxiliaryRemainderToNewerFrame(
                current: request,
                score: false,
                period: false,
                penaltyPlayer: remainingPenaltyPlayer,
                penaltyTimer: remainingPenaltyTimer,
                penaltyTimerKeys: request.penaltyTimerWorkKeys,
                checkpoint: "after-period-complete"
            ) { return }
        }

    }

    /// Recovery AI ingress-owned entry point. The pipeline has already created
    /// the one processing-owned CVPixelBuffer and released the FrameHub lease, so
    /// Image Relay adopts that buffer directly instead of allocating/copying a
    /// second 1080p surface.
    nonisolated func submitOwnedFromPipeline(
        pixelBuffer: CVPixelBuffer,
        sourceSequence: Int?,
        captureGeneration: Int,
        layout: ScoreboardOCRLayout,
        colourProfiles: OCRColourProfileSet,
        boardCalibration: BoardCalibrationQuad,
        previewSize: CGSize,
        previewRotationDegrees: CGFloat,
        viewerAcceptedPenaltyPlayers: Set<OCRRegionKey> = [],
        homeRosterNumbers: Set<Int> = [],
        sourceObservedAt: Date = Date(),
        sourceMonotonicTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        submitOwnedPipelineFrame(
            pixelBuffer,
            sourceSequence: sourceSequence,
            captureGeneration: captureGeneration,
            layout: layout,
            colourProfiles: colourProfiles,
            boardCalibration: boardCalibration,
            previewSize: previewSize,
            previewRotationDegrees: previewRotationDegrees,
            viewerAcceptedPenaltyPlayers: viewerAcceptedPenaltyPlayers,
            homeRosterNumbers: homeRosterNumbers,
            sourceObservedAt: sourceObservedAt,
            sourceMonotonicTime: sourceMonotonicTime
        )
    }

    /// Build 785 R16a compile boundary for the AppContainer-owned bounded pipeline.
    /// The full 1080p ownership copy remains off MainActor. Only the already-owned
    /// immutable request crosses to the engine's existing admission/state boundary.
    /// This is an execution handoff, not a second Image Relay or viewer-state owner.
    nonisolated func submitFromPipeline(
        pixelBuffer: CVPixelBuffer,
        sourceSequence: Int?,
        captureGeneration: Int,
        layout: ScoreboardOCRLayout,
        colourProfiles: OCRColourProfileSet,
        boardCalibration: BoardCalibrationQuad,
        previewSize: CGSize,
        previewRotationDegrees: CGFloat,
        viewerAcceptedPenaltyPlayers: Set<OCRRegionKey> = [],
        homeRosterNumbers: Set<Int> = [],
        sourceObservedAt: Date = Date(),
        sourceMonotonicTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        guard let owned = RinkLensOCRFrameOwnership.makeOwnedCopy(of: pixelBuffer) else {
            recordPipelineOwnershipCopyFailure()
            return
        }
        submitOwnedPipelineFrame(
            owned,
            sourceSequence: sourceSequence,
            captureGeneration: captureGeneration,
            layout: layout,
            colourProfiles: colourProfiles,
            boardCalibration: boardCalibration,
            previewSize: previewSize,
            previewRotationDegrees: previewRotationDegrees,
            viewerAcceptedPenaltyPlayers: viewerAcceptedPenaltyPlayers,
            homeRosterNumbers: homeRosterNumbers,
            sourceObservedAt: sourceObservedAt,
            sourceMonotonicTime: sourceMonotonicTime
        )
    }

    private func recordPipelineOwnershipCopyFailure() {
        lock.lock()
        copyFailures += 1
        lock.unlock()
    }

    private func submitOwnedPipelineFrame(
        _ owned: CVPixelBuffer,
        sourceSequence: Int?,
        captureGeneration: Int,
        layout: ScoreboardOCRLayout,
        colourProfiles: OCRColourProfileSet,
        boardCalibration: BoardCalibrationQuad,
        previewSize: CGSize,
        previewRotationDegrees: CGFloat,
        viewerAcceptedPenaltyPlayers: Set<OCRRegionKey>,
        homeRosterNumbers: Set<Int>,
        sourceObservedAt: Date,
        sourceMonotonicTime: CFAbsoluteTime
    ) {
        submit(
            pixelBuffer: owned,
            sourceSequence: sourceSequence,
            captureGeneration: captureGeneration,
            layout: layout,
            colourProfiles: colourProfiles,
            boardCalibration: boardCalibration,
            previewSize: previewSize,
            previewRotationDegrees: previewRotationDegrees,
            viewerAcceptedPenaltyPlayers: viewerAcceptedPenaltyPlayers,
            homeRosterNumbers: homeRosterNumbers,
            sourceObservedAt: sourceObservedAt,
            sourceMonotonicTime: sourceMonotonicTime,
            pixelBufferIsAlreadyOwned: true
        )
    }

    func submit(
        pixelBuffer: CVPixelBuffer,
        sourceSequence: Int?,
        captureGeneration: Int,
        layout: ScoreboardOCRLayout,
        colourProfiles: OCRColourProfileSet,
        boardCalibration: BoardCalibrationQuad,
        previewSize: CGSize,
        previewRotationDegrees: CGFloat,
        viewerAcceptedPenaltyPlayers: Set<OCRRegionKey> = [],
        homeRosterNumbers: Set<Int> = [],
        sourceObservedAt: Date = Date(),
        sourceMonotonicTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent(),
        pixelBufferIsAlreadyOwned: Bool = false
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        let workToken = RelayWorkToken(
            sourceSequence: sourceSequence,
            captureGeneration: captureGeneration,
            sourceObservedAt: sourceObservedAt,
            sourceMonotonicTime: sourceMonotonicTime
        )
        registerRelayWorkToken(workToken)

        // Recovery AX / RL-105: only true process-wide codec/resource preparation
        // suppresses the direct Clock. The short recording frame critical section
        // no longer blocks this latest-only viewer lane; auxiliary work still has
        // its own stricter admission checkpoints before expensive rectification.
        guard RinkLensExecutionCoordinator.shared.admitsViewerClockWork() else {
            lock.lock(); writerCriticalScoreboardYields &+= 1; lock.unlock()
            RinkLensExecutionCoordinator.shared.noteScoreboardRealtimeYield()
            return
        }

        var runClock = false
        var runScore = false
        var runPeriod = false
        var runPenaltyPlayer = false
        var runPenaltyTimer = false

        // Recovery AL: Build 747's fixed-deadline scheduler is now the single
        // production Clock policy. The completion-driven and independent-fast-lane
        // rollback branches expired at Build 785 and are deleted from the hot path.
        var queueLatestClockRequest = false
        var clockScheduledDeadline = now
        lock.lock()
        if nextClockDeadline == 0 { nextClockDeadline = now }
        if now >= nextClockDeadline {
            clockScheduledDeadline = nextClockDeadline
            repeat { nextClockDeadline += minimumClockSubmissionInterval }
            while nextClockDeadline <= now
            if clockBusy {
                queueLatestClockRequest = true
                if pendingClockRequest != nil { clockPendingFrameReplacements += 1 }
                if !clockRerunPending { coalescedClockBusyRequests += 1 }
                clockRerunPending = true
            } else {
                clockBusy = true
                clockRerunPending = false
                lastClockSubmittedAt = now
                runClock = true
            }
        }
        if now - lastScoreSubmittedAt >= minimumScoreSubmissionInterval {
            if scoreBusy {
                droppedScoreBusyFrames += 1
            } else {
                scoreBusy = true
                lastScoreSubmittedAt = now
                runScore = true
            }
        }
        if now - lastPeriodSubmittedAt >= minimumPeriodSubmissionInterval {
            if periodBusy {
                droppedPeriodBusyFrames += 1
            } else {
                periodBusy = true
                lastPeriodSubmittedAt = now
                runPeriod = true
            }
        }
        if now - lastPenaltyPlayerSubmittedAt >= minimumPenaltyPlayerSubmissionInterval {
            if penaltyPlayerBusy {
                if !penaltyPlayerRerunPending {
                    coalescedPenaltyPlayerBusyRequests += 1
                }
                penaltyPlayerRerunPending = true
                // Do not count every stale callback. One pending intent is enough;
                // completion resets the due time so the next fresh frame runs.
                lastPenaltyPlayerSubmittedAt = now
            } else {
                penaltyPlayerBusy = true
                penaltyPlayerRerunPending = false
                lastPenaltyPlayerSubmittedAt = now
                runPenaltyPlayer = true
            }
        }
        // Build 785 R9: MatchState is the sole semantic penalty owner. Accepted
        // active penalties retain the 0.30-second viewer timer service. When no
        // penalty is accepted, timer crops are diagnostics only and run at a
        // reduced two-second cadence instead of competing with capture/recording.
        let penaltyTimerSubmissionInterval = viewerAcceptedPenaltyPlayers.isEmpty
            ? max(2.0, minimumPenaltyPlayerSubmissionInterval)
            : minimumPenaltyTimerSubmissionInterval
        if now - lastPenaltyTimerSubmittedAt >= penaltyTimerSubmissionInterval {
            if penaltyTimerBusy {
                if !penaltyTimerRerunPending {
                    coalescedPenaltyTimerBusyRequests += 1
                }
                penaltyTimerRerunPending = true
                lastPenaltyTimerSubmittedAt = now
            } else {
                penaltyTimerBusy = true
                penaltyTimerRerunPending = false
                lastPenaltyTimerSubmittedAt = now
                runPenaltyTimer = true
            }
        }
        lock.unlock()

        // R17: timer processing is never used to establish that an empty penalty
        // slot is blank. The cheap player occupancy/hash lane owns that evidence.
        // Only accepted penalties, player-positive transition evidence or an
        // existing visual pair may admit the expensive timer crop path.
        let penaltyTimerWorkKeys = runPenaltyTimer
            ? eligiblePenaltyTimerWorkKeys(viewerAcceptedPenaltyPlayers: viewerAcceptedPenaltyPlayers)
            : []
        if runPenaltyTimer, penaltyTimerWorkKeys.isEmpty {
            lock.lock()
            penaltyTimerBusy = false
            penaltyTimerRerunPending = false
            lock.unlock()
            runPenaltyTimer = false
        }

        guard runClock || queueLatestClockRequest || runScore || runPeriod || runPenaltyPlayer || runPenaltyTimer else { return }

        let owned: CVPixelBuffer
        if pixelBufferIsAlreadyOwned {
            owned = pixelBuffer
        } else {
            guard let copied = RinkLensOCRFrameOwnership.makeOwnedCopy(of: pixelBuffer) else {
                lock.lock()
                if runClock { clockBusy = false }
                if runScore { scoreBusy = false }
                if runPeriod { periodBusy = false }
                if runPenaltyPlayer { penaltyPlayerBusy = false }
                if runPenaltyTimer { penaltyTimerBusy = false }
                copyFailures += 1
                lock.unlock()
                return
            }
            owned = copied
        }

        // Recovery BB: the 0.30-second viewer Clock and auxiliary lanes both use
        // direct field-sized crops. Auxiliary lanes share only a lazy per-frame
        // cache and never render unused fields or a full scoreboard image.
        let hasAuxiliaryWork = runScore || runPeriod || runPenaltyPlayer || runPenaltyTimer
        let fieldPreparation: DirectRelayFieldPreparation? = hasAuxiliaryWork
            ? DirectRelayFieldPreparation(
                pixelBuffer: owned,
                layout: layout,
                boardCalibration: boardCalibration,
                previewSize: previewSize,
                previewRotationDegrees: previewRotationDegrees,
                keys: Self.allAuxiliaryRelayCropKeys,
                rectificationQueue: scoreboardRectificationQueue,
                prepared: { [weak self] cropCount, elapsedMilliseconds in
                    self?.noteAuxiliaryDirectCropBatch(
                        cropCount: cropCount,
                        elapsedMilliseconds: elapsedMilliseconds
                    )
                }
            )
            : nil

        let clockRequest = ClockRelayRequest(
            pixelBuffer: owned,
            sourceSequence: sourceSequence,
            captureGeneration: captureGeneration,
            layout: layout,
            colourProfiles: colourProfiles,
            boardCalibration: boardCalibration,
            previewSize: previewSize,
            previewRotationDegrees: previewRotationDegrees,
            sourceObservedAt: sourceObservedAt,
            sourceMonotonicTime: sourceMonotonicTime,
            scheduledDeadline: clockScheduledDeadline,
            enqueuedAt: now
        )

        lock.lock()
        copiedFrames += 1
        if queueLatestClockRequest {
            pendingClockRequest = clockRequest
        }
        lock.unlock()

        if runClock {
            scoreboardClockServiceQueue.async { [weak self] in
                autoreleasepool { self?.processClockRequestChain(startingWith: clockRequest) }
            }
        }

        // Auxiliary lanes remain latest-frame/capacity-one. Clock has already
        // been admitted separately and cannot wait for this queue.
        if hasAuxiliaryWork, let fieldPreparation {
            let request = AuxiliaryRelayRequest(
                pixelBuffer: owned,
                workToken: workToken,
                runScore: runScore,
                runPeriod: runPeriod,
                runPenaltyPlayer: runPenaltyPlayer,
                runPenaltyTimer: runPenaltyTimer,
                penaltyTimerWorkKeys: penaltyTimerWorkKeys,
                layout: layout,
                colourProfiles: colourProfiles,
                boardCalibration: boardCalibration,
                previewSize: previewSize,
                previewRotationDegrees: previewRotationDegrees,
                viewerAcceptedPenaltyPlayers: viewerAcceptedPenaltyPlayers,
                homeRosterNumbers: homeRosterNumbers,
                fieldPreparation: fieldPreparation
            )
            enqueueLatestAuxiliaryRequest(request)
        }
    }

    private func finishClockPassAndSchedulePending() {
        lock.lock()
        completedClockPasses += 1
        let next = pendingClockRequest
        pendingClockRequest = nil
        clockRerunPending = next != nil
        if next == nil { clockBusy = false }
        lock.unlock()
        if let next {
            scoreboardClockServiceQueue.async { [weak self] in
                autoreleasepool { self?.processClockRequestChain(startingWith: next) }
            }
        }
    }

    private func processClockRequestChain(startingWith startingRequest: ClockRelayRequest) {
        guard RinkLensExecutionCoordinator.shared.admitsViewerClockWork() else {
            lock.lock()
            writerCriticalScoreboardYields &+= 1
            pendingClockRequest = nil
            clockRerunPending = false
            clockBusy = false
            lock.unlock()
            RinkLensExecutionCoordinator.shared.noteScoreboardRealtimeYield()
            return
        }

        // Recovery AX: capacity-one means newest physical evidence wins even if a
        // previous Clock item reached the service queue first. Promote the latest
        // pending request before any Core Image work instead of rendering obsolete
        // source pixels and then catching up afterwards.
        var current = startingRequest
        lock.lock()
        if let latest = pendingClockRequest,
           latest.sourceMonotonicTime > current.sourceMonotonicTime {
            current = latest
            pendingClockRequest = nil
            clockRerunPending = false
        }
        activeClockImageJobs += 1
        peakClockImageJobs = max(peakClockImageJobs, activeClockImageJobs)
        lock.unlock()
        defer { lock.lock(); activeClockImageJobs = max(0, activeClockImageJobs - 1); lock.unlock() }
        let startedAt = CFAbsoluteTimeGetCurrent()
        let missedMS = max(0, (startedAt - current.scheduledDeadline) * 1_000)
        lock.lock()
        if missedMS > 150 {
            clockDeadlineMisses += 1
            maximumClockDeadlineMissMS = max(maximumClockDeadlineMissMS, missedMS)
        }
        lock.unlock()

        processDirectClock(
            pixelBuffer: current.pixelBuffer,
            processor: processor,
            sourceSequence: current.sourceSequence,
            captureGeneration: current.captureGeneration,
            layout: current.layout,
            colourProfiles: current.colourProfiles,
            boardCalibration: current.boardCalibration,
            previewSize: current.previewSize,
            previewRotationDegrees: current.previewRotationDegrees,
            sourceObservedAt: current.sourceObservedAt,
            sourceMonotonicTime: current.sourceMonotonicTime,
            scheduledDeadline: current.scheduledDeadline,
            precomputedClockCrop: nil
        )

        // Latest-only Clock: do not drain an endless chain inline. Re-enqueue the
        // newest pending Clock at the tail; superseded source frames are never FIFO.
        finishClockPassAndSchedulePending()
    }

    private func processDirectClock(
        pixelBuffer: CVPixelBuffer,
        processor: ScoreboardOCRProcessor,
        sourceSequence: Int?,
        captureGeneration: Int,
        layout: ScoreboardOCRLayout,
        colourProfiles: OCRColourProfileSet,
        boardCalibration: BoardCalibrationQuad,
        previewSize: CGSize,
        previewRotationDegrees: CGFloat,
        sourceObservedAt: Date,
        sourceMonotonicTime: CFAbsoluteTime,
        scheduledDeadline: CFAbsoluteTime = 0,
        precomputedClockCrop: CGImage? = nil
    ) {
        let started = CFAbsoluteTimeGetCurrent()
        // Recovery BI / RL-146: Clock previously bypassed the declared serial
        // rectification owner while auxiliary crops used it. Both paths therefore
        // drove the same ScoreboardOCRProcessor/CIContext concurrently, matching
        // the supplied run's 1.35-second Clock passes and deadline misses. Keep
        // Clock scheduling independent, but acknowledge its bounded crop at the
        // single physical Core Image boundary before doing CPU-only presentation.
        let rawClock = precomputedClockCrop ?? scoreboardRectificationQueue.sync {
            processor.imageRelayDirectFieldCrop(
                from: pixelBuffer,
                layout: layout,
                boardCalibration: boardCalibration,
                key: .clock,
                deviceOrientation: .landscapeLeft,
                previewSize: previewSize,
                previewRotationDegrees: previewRotationDegrees,
                // Recovery BC: the published Clock canvas is 100 px high. A 640 px
                // intermediate made the calibrated Home zone 490x163 and physically
                // held the viewer queue for multi-second passes on iPad8,9. Preserve
                // more than the final pixel height without processing surplus pixels.
                maximumDimension: 360
            )
        }
        let cropCompleted = CFAbsoluteTimeGetCurrent()
        guard let rawClock,
              let directClock = makeDirectClockImage(
                from: rawClock,
                captureGeneration: captureGeneration
              ) else {
            return
        }
        let presentationCompleted = CFAbsoluteTimeGetCurrent()

        let elapsedMS = (CFAbsoluteTimeGetCurrent() - started) * 1_000
        lock.lock()
        lastClockPresentationDiagnostic = directClock.diagnostic
        let movementDecision = clockMovementState.lastDecision
        lock.unlock()
        // Viewer-facing publication is the only Clock presentation authority.
        // Secondary numeric Clock OCR cannot delay, reject or gate this image.
        ScoreboardImageRelayStore.shared.publishDirectClock(
            rawImage: rawClock,
            image: directClock.image,
            contentHash: directClock.pixelHash,
            sourceSequence: sourceSequence,
            captureGeneration: captureGeneration,
            processingMilliseconds: elapsedMS,
            diagnostic: "\(directClock.diagnostic) stages={crop=\(String(format: "%.1f", (cropCompleted - started) * 1_000))ms presentation=\(String(format: "%.1f", (presentationCompleted - cropCompleted) * 1_000))ms} deadlineMissMs=\(String(format: "%.1f", max(0, (started - scheduledDeadline) * 1_000))) movementLast={\(movementDecision)}"
        )
        // Build 708: running/stopped authority is image-signature only. No textual
        // OCR is scheduled from the Clock crop and popup time remains the frozen image.
        processClockMovementSample(
            rawImage: rawClock,
            displayedImage: directClock.image,
            sourceSequence: sourceSequence,
            captureGeneration: captureGeneration,
            sourceObservedAt: sourceObservedAt,
            sourceMonotonicTime: sourceMonotonicTime,
            timeoutStyleCandidate: directClock.timeoutStyleCandidate
        )
    }

    private func processClockMovementSample(
        rawImage: CGImage,
        displayedImage: CGImage,
        sourceSequence: Int?,
        captureGeneration: Int,
        sourceObservedAt: Date,
        sourceMonotonicTime: CFAbsoluteTime,
        timeoutStyleCandidate: Bool
    ) {
        // Build 636 anchors movement transitions to the source frame rather than
        // the later processing callback. Popup release can therefore target the
        // real physical restart +5s even when the relay queue is briefly busy.
        let callbackNow = CFAbsoluteTimeGetCurrent()
        let sampleAge = max(0, callbackNow - sourceMonotonicTime)
        guard sampleAge <= maximumClockMovementSampleAge else {
            let staleDiagnostic = "clock-image-relay stale movement sample rejected age=\(String(format: "%.2f", sampleAge))s max=\(String(format: "%.2f", maximumClockMovementSampleAge))s sourceSequence=\(sourceSequence.map { String($0) } ?? "none")"
            lock.lock()
            var state = clockMovementState
            state.lastDecision = staleDiagnostic
            clockMovementState = state
            lock.unlock()
            return
        }

        let now = sourceMonotonicTime
        let observedDate = sourceObservedAt
        let signature = Self.clockMovementSignature(from: rawImage)
        var transitioned = false
        var transitionObservedAt: CFAbsoluteTime?
        var transitionObservedDate: Date?
        var frozenClockImage: CGImage?
        var running: Bool?
        var diagnostic = ""
        var restartCandidateEvent: (event: String, previous: [String: String], next: [String: String], reason: String)?
        let verifiedRestartEnabled = RinkLensRiskFeaturePolicy.isEnabled(.verifiedClockRestartForPopupsV2)
        var timeoutTransition: ScoreboardImageRelayTimeoutTransition?

        lock.lock()
        if RinkLensRiskFeaturePolicy.isEnabled(.semanticPenaltyEndAndTimeoutEventsV26) {
            var timeout = clockTimeoutState
            let eligibleTimeoutCandidate = timeoutStyleCandidate && clockMovementState.isRunning != true
            if timeout.pendingCandidate == eligibleTimeoutCandidate {
                timeout.matchingSamples += 1
            } else {
                timeout.pendingCandidate = eligibleTimeoutCandidate
                timeout.matchingSamples = 1
            }
            if timeout.matchingSamples >= 2, timeout.active != eligibleTimeoutCandidate {
                timeout.active = eligibleTimeoutCandidate
                timeout.startedAt = eligibleTimeoutCandidate ? now : nil
                timeoutTransition = eligibleTimeoutCandidate ? .started : .ended
                timeout.pendingCandidate = nil
                timeout.matchingSamples = 0
                var reset = clockMovementState
                reset.previousSignature = signature
                reset.stableSamples = 0
                reset.movingSamples = 0
                reset.stableRunStartedAt = nil
                reset.stableRunSignature = nil
                reset.isRunning = false
                reset.lastDecision = "timeout-style transition \(timeoutTransition?.rawValue ?? "none")"
                clockMovementState = reset
            }
            clockTimeoutState = timeout
            if timeout.active || timeout.pendingCandidate == true || timeoutTransition == .started {
                lock.unlock()
                if let timeoutTransition {
                    emitMetadata(ScoreboardImageRelayMetadataObservation(
                        kind: .clock,
                        clockRunning: false,
                        movementTransitioned: false,
                        frozenClockImage: displayedImage,
                        visualValues: [:],
                        attemptedKeys: [.clock],
                        observedAt: observedDate,
                        monotonicTime: now,
                        sourceSequence: sourceSequence,
                        captureGeneration: captureGeneration,
                        completePenaltyPlayerCycle: false,
                        timeoutTransition: timeoutTransition,
                        diagnostic: "clock timeout-style \(timeoutTransition.rawValue)"
                    ))
                }
                return
            }
            if timeoutTransition == .ended {
                lock.unlock()
                emitMetadata(ScoreboardImageRelayMetadataObservation(
                    kind: .clock,
                    clockRunning: false,
                    movementTransitioned: false,
                    frozenClockImage: displayedImage,
                    visualValues: [:],
                    attemptedKeys: [.clock],
                    observedAt: observedDate,
                    monotonicTime: now,
                    sourceSequence: sourceSequence,
                    captureGeneration: captureGeneration,
                    completePenaltyPlayerCycle: false,
                    timeoutTransition: .ended,
                    diagnostic: "clock timeout-style ended"
                ))
                return
            }
        }
        var state = clockMovementState
        if let previous = state.previousSignature, !signature.isEmpty {
            let movedFromPrevious = Self.clockSignatureMoved(previous, signature)
            let movedFromStableBaseline = state.stableRunSignature.map {
                Self.clockSignatureMoved($0, signature)
            } ?? false
            let moving = movedFromPrevious || movedFromStableBaseline
            if moving {
                state.movingSamples += 1
                state.stableSamples = 0
                state.stableRunStartedAt = nil
                state.stableRunObservedAt = nil
                state.stableRunClockImage = nil
                state.stableRunSignature = nil
                state.lastMovementObservedAt = now

                if state.isRunning != true {
                    if verifiedRestartEnabled {
                        let withinVerificationWindow = state.restartCandidateLastMovementAt.map {
                            now - $0 <= 2.5
                        } ?? false
                        if !withinVerificationWindow {
                            state.restartCandidateStartedAt = now
                            state.restartCandidateLastMovementAt = now
                            state.restartCandidateBaselineSignature = previous
                            state.restartCandidateLastDistinctSignature = signature
                            state.restartCandidateChangeCount = 1
                            restartCandidateEvent = (
                                event: "clock_restart_candidate_started",
                                previous: ["state": state.isRunning.map { String($0) } ?? "unknown"],
                                next: ["changes": "1", "state": "candidate"],
                                reason: "First material Clock digit change; awaiting a second non-oscillating signature"
                            )
                        } else if movedFromPrevious {
                            let differsFromCandidateBaseline = state.restartCandidateBaselineSignature.map {
                                Self.clockSignatureMoved($0, signature)
                            } ?? true
                            let differsFromLastDistinct = state.restartCandidateLastDistinctSignature.map {
                                Self.clockSignatureMoved($0, signature)
                            } ?? true
                            if differsFromCandidateBaseline, differsFromLastDistinct {
                                state.restartCandidateChangeCount += 1
                                state.restartCandidateLastMovementAt = now
                                state.restartCandidateLastDistinctSignature = signature
                            } else if !differsFromCandidateBaseline {
                                restartCandidateEvent = (
                                    event: "clock_restart_candidate_rejected_oscillation",
                                    previous: ["state": "candidate", "changes": String(state.restartCandidateChangeCount)],
                                    next: ["state": "stopped", "changes": "0"],
                                    reason: "Clock signature returned to the stopped baseline; candidate was camera or multiplex flicker"
                                )
                                state.restartCandidateStartedAt = nil
                                state.restartCandidateLastMovementAt = nil
                                state.restartCandidateBaselineSignature = nil
                                state.restartCandidateLastDistinctSignature = nil
                                state.restartCandidateChangeCount = 0
                            }
                        }
                        let candidateSpan = now - (state.restartCandidateStartedAt ?? now)
                        if state.restartCandidateChangeCount >= 2, candidateSpan >= 0.55 {
                            state.isRunning = true
                            state.movingRunStartedAt = now
                            transitioned = true
                            // The verified second distinct signature owns popup restart timing.
                            // Repeated copies of one flicker and A-B-A oscillation cannot
                            // release stopped-clock events before genuine play resumes.
                            transitionObservedAt = now
                            transitionObservedDate = observedDate
                            restartCandidateEvent = (
                                event: "clock_restart_verified",
                                previous: ["state": "candidate", "changes": String(state.restartCandidateChangeCount)],
                                next: ["state": "running", "verifiedAt": String(now)],
                                reason: "Two non-oscillating material Clock digit changes confirmed physical restart"
                            )
                            state.restartCandidateStartedAt = nil
                            state.restartCandidateLastMovementAt = nil
                            state.restartCandidateBaselineSignature = nil
                            state.restartCandidateLastDistinctSignature = nil
                            state.restartCandidateChangeCount = 0
                        }
                    } else {
                        // Legacy Build 610 path retained behind the feature flag.
                        state.isRunning = true
                        state.movingRunStartedAt = now
                        transitioned = true
                        transitionObservedAt = now
                        transitionObservedDate = observedDate
                    }
                }
            } else {
                if verifiedRestartEnabled,
                   state.isRunning != true,
                   let lastCandidateMovement = state.restartCandidateLastMovementAt,
                   now - lastCandidateMovement > 2.5 {
                    restartCandidateEvent = (
                        event: "clock_restart_candidate_expired",
                        previous: ["state": "candidate", "changes": String(state.restartCandidateChangeCount)],
                        next: ["state": state.isRunning.map { String($0) } ?? "unknown"],
                        reason: "No second material Clock change arrived within 2.5 seconds"
                    )
                    state.restartCandidateStartedAt = nil
                    state.restartCandidateLastMovementAt = nil
                    state.restartCandidateBaselineSignature = nil
                    state.restartCandidateLastDistinctSignature = nil
                    state.restartCandidateChangeCount = 0
                }
                if state.stableSamples == 0 || state.stableRunSignature == nil {
                    state.stableRunStartedAt = now
                    state.stableRunObservedAt = observedDate
                    // CGImage is immutable. Retaining this exact processed relay
                    // image makes the first stable crop an immutable popup source.
                    state.stableRunClockImage = displayedImage
                    state.stableRunSignature = signature
                }
                state.stableSamples += 1
                state.movingSamples = 0
                state.movingRunStartedAt = nil
                let stableDuration = now - (state.stableRunStartedAt ?? now)
                // Four samples alone can occur in less than one displayed second.
                // Build 641 requires more than two seconds of unchanged digits so
                // a missed one-second tick cannot manufacture a false stoppage.
                if state.stableSamples >= 4,
                   stableDuration >= minimumClockStopStableDuration,
                   state.isRunning != false {
                    state.isRunning = false
                    state.restartCandidateStartedAt = nil
                    state.restartCandidateLastMovementAt = nil
                    state.restartCandidateBaselineSignature = nil
                    state.restartCandidateLastDistinctSignature = nil
                    state.restartCandidateChangeCount = 0
                    transitioned = true
                    // Freeze the event Clock at the first stable crop, not at the
                    // later duration-confirmation frame.
                    transitionObservedAt = state.stableRunStartedAt ?? now
                    transitionObservedDate = state.stableRunObservedAt ?? observedDate
                    frozenClockImage = state.stableRunClockImage
                }
            }
        }
        state.previousSignature = signature
        running = state.isRunning
        if transitioned {
            let transitionStableDuration = now - (state.stableRunStartedAt ?? now)
            diagnostic = "clock-image-relay transition running=\(running.map { String($0) } ?? "unknown") stable=\(state.stableSamples) stableDuration=\(String(format: "%.2f", transitionStableDuration))s moving=\(state.movingSamples) baseline=\(state.stableRunSignature == nil ? "none" : "first-stable") frozenImage=\(frozenClockImage == nil ? "no" : "yes")"
            state.lastDecision = diagnostic
        }
        clockMovementState = state
        lock.unlock()

        if let restartCandidateEvent {
            RinkLensStructuredEventLogger.shared.record(
                domain: .clock,
                event: restartCandidateEvent.event,
                entityID: "image-relay-clock",
                previous: restartCandidateEvent.previous,
                next: restartCandidateEvent.next,
                source: "ScoreboardImageRelay.processClockMovementSample",
                reason: restartCandidateEvent.reason,
                captureGeneration: captureGeneration
            )
        }

        if transitioned {
            emitMetadata(
                ScoreboardImageRelayMetadataObservation(
                    kind: .clock,
                    clockRunning: running,
                    movementTransitioned: true,
                    frozenClockImage: frozenClockImage,
                    visualValues: [:],
                    attemptedKeys: [.clock],
                    observedAt: transitionObservedDate ?? observedDate,
                    monotonicTime: transitionObservedAt ?? now,
                    sourceSequence: sourceSequence,
                    captureGeneration: captureGeneration,
                    completePenaltyPlayerCycle: false,
                    diagnostic: diagnostic
                )
            )
        }
    }

    // Build 708: the event-timeline Clock OCR scheduler, parser, retry state
    // and ten-second sampler were intentionally removed.

    private static func cleanRelayImageHash(_ image: CGImage) -> UInt64 {
        var hash = UInt64(image.width &* 31 &+ image.height)
        if let data = image.dataProvider?.data,
           let bytes = CFDataGetBytePtr(data) {
            let length = CFDataGetLength(data)
            let stride = max(1, length / 64)
            var index = 0
            while index < length {
                hash = (hash &* 1099511628211) ^ UInt64(bytes[index])
                index += stride
            }
        }
        return hash
    }

    private static func clockMovementSignature(from image: CGImage) -> [UInt8] {
        let width = 32
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        let rendered = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return [] }
        return pixels.map { UInt8((Int($0) / 16) * 16) }
    }

    private static func clockSignatureMoved(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return true }
        var changed = 0
        var total = 0
        for (a, b) in zip(lhs, rhs) {
            let delta = abs(Int(a) - Int(b))
            total += delta
            if delta >= 32 { changed += 1 }
        }
        return changed >= 8 || total / lhs.count >= 7
    }

    private func processLane(
        name: String,
        pixelBuffer: CVPixelBuffer,
        processor: ScoreboardOCRProcessor,
        keys: Set<OCRRegionKey>,
        sourceSequence: Int?,
        captureGeneration: Int,
        layout: ScoreboardOCRLayout,
        colourProfiles: OCRColourProfileSet,
        boardCalibration: BoardCalibrationQuad,
        previewSize: CGSize,
        previewRotationDegrees: CGFloat,
        precomputedCrops: [OCRRegionKey: CGImage]? = nil,
        workToken: RelayWorkToken? = nil,
        maximumPublicationAgeSeconds: TimeInterval? = nil,
        admissionPolicy: AuxiliaryStageAdmissionPolicy = .standard
    ) {
        let started = CFAbsoluteTimeGetCurrent()
        let crops: [OCRRegionKey: CGImage]
        if let precomputedCrops {
            crops = precomputedCrops.filter { keys.contains($0.key) }
        } else {
            crops = processor.imageRelayDirectFieldCrops(
                from: pixelBuffer,
                layout: layout,
                boardCalibration: boardCalibration,
                keys: keys,
                deviceOrientation: .landscapeLeft,
                previewSize: previewSize,
                previewRotationDegrees: previewRotationDegrees
            )
        }

        if let workToken, let maximumPublicationAgeSeconds {
            guard auxiliaryStageMayContinue(
                token: workToken,
                maximumAgeSeconds: maximumPublicationAgeSeconds,
                checkpoint: "\(name)-after-crops",
                admissionPolicy: admissionPolicy
            ) else { return }
        }

        var rawImages: [OCRRegionKey: CGImage] = [:]
        var images: [OCRRegionKey: CGImage] = [:]
        var visualValues: [OCRRegionKey: String] = [:]
        var candidateValues: [OCRRegionKey: String] = [:]
        var hashes: [OCRRegionKey: UInt64] = [:]
        var acceptedDiagnostics: [String] = []
        var rejectedDiagnostics: [String] = []
        rawImages.reserveCapacity(crops.count)
        images.reserveCapacity(crops.count)
        visualValues.reserveCapacity(crops.count)
        candidateValues.reserveCapacity(crops.count)
        hashes.reserveCapacity(crops.count)

        for (key, crop) in crops {
            if let workToken, let maximumPublicationAgeSeconds {
                guard auxiliaryStageMayContinue(
                    token: workToken,
                    maximumAgeSeconds: maximumPublicationAgeSeconds,
                    checkpoint: "\(name)-before-\(key.rawValue)",
                    admissionPolicy: admissionPolicy
                ) else { return }
            }
            rawImages[key] = crop
            let profile = colourProfiles.profile(for: key)

            if key == .homeScore || key == .awayScore || key == .period {
                let recognition = Self.recogniseOCRModeVisualValue(
                    from: crop,
                    key: key,
                    colourProfile: profile,
                    sourceSequence: sourceSequence,
                    captureGeneration: captureGeneration
                )
                if let workToken, let maximumPublicationAgeSeconds {
                    guard auxiliaryStageMayContinue(
                        token: workToken,
                        maximumAgeSeconds: maximumPublicationAgeSeconds,
                        checkpoint: "\(name)-after-recognition-\(key.rawValue)",
                        admissionPolicy: admissionPolicy
                    ) else { return }
                }
                let resolved = resolveRelayVisualValue(
                    key: key,
                    candidate: recognition.value,
                    confidence: recognition.confidence,
                    parserDiagnostic: recognition.diagnostic,
                    physicalHash: Self.penaltyPlayerPerceptualHash(from: crop),
                    requiresExtendedConfirmation: recognition.requiresExtendedConfirmation
                )

                if let value = resolved.value {
                    visualValues[key] = value
                    if key == .homeScore || key == .awayScore {
                        candidateValues[key] = value
                    }
                    hashes[key] = Self.cleanRelayValueHash(value: value, key: key)
                    acceptedDiagnostics.append(
                        "\(key.rawValue)=ocr-mode-text value=\(value) {\(resolved.diagnostic)}"
                    )
                } else {
                    if key == .homeScore || key == .awayScore {
                        // Build 671: scores are numeric text fields. While a new
                        // candidate is pending or the parser misses, publish no
                        // replacement image and let the Store retain the last clean
                        // numeric value. The former physical/raw fallback briefly
                        // rendered a hollow zero (the reported “donut”) before the
                        // second score read recovered.
                        rejectedDiagnostics.append(
                            "\(key.rawValue)=score-text-held-no-image-fallback {\(resolved.diagnostic)}"
                        )
                    } else {
                        rejectedDiagnostics.append(
                            "\(key.rawValue)=ocr-mode-text waiting {\(resolved.diagnostic)}"
                        )
                    }
                }
                continue
            }

            let outcome = Self.extractIlluminatedGlyphs(
                from: crop,
                key: key,
                colourProfile: profile
            )
            guard let extracted = outcome.glyph else {
                rejectedDiagnostics.append("\(key.rawValue)=\(outcome.diagnostic)")
                continue
            }

            images[key] = extracted.image
            hashes[key] = extracted.hash
            acceptedDiagnostics.append("\(key.rawValue)=\(extracted.diagnostic)")
        }

        let elapsedMS = (CFAbsoluteTimeGetCurrent() - started) * 1_000
        let acceptedText = acceptedDiagnostics.sorted().joined(separator: ";")
        let rejectedText = rejectedDiagnostics.sorted().joined(separator: ";")
        let extractionSummary = "glyphs={\(acceptedText)} rejected={\(rejectedText)}"

        // Build 677: deliver validated Home/Away score candidates directly from
        // the score lane before Store publication or merged visual-state work.
        // The July 25 run recognised Guest 4 on dozens of frames, but no score
        // transition was published because the candidate was lost inside the
        // generic visual publication path. This small typed observation keeps
        // score confirmation independent from Clock, Period and presentation.
        if let workToken, let maximumPublicationAgeSeconds {
            let publicationValidation = validateRelayWorkToken(
                workToken,
                maximumAgeSeconds: maximumPublicationAgeSeconds
            )
            guard publicationValidation.allowed else {
                lock.lock()
                auxiliaryObsoleteLaneSkips &+= 1
                lock.unlock()
                RinkLensStructuredEventLogger.shared.record(
                    domain: .scoreboardPresentation,
                    event: "image_relay_stale_auxiliary_publication_discarded",
                    entityID: name,
                    previous: [
                        "sourceSequence": workToken.sourceSequence.map(String.init) ?? "none",
                        "generation": String(workToken.captureGeneration),
                        "attemptedKeys": keys.map(\.rawValue).sorted().joined(separator: ",")
                    ],
                    next: [
                        "mutation": "discarded-before-store-or-metadata-publication",
                        "sourceFrameAgeMs": String(format: "%.1f", publicationValidation.ageSeconds * 1_000),
                        "supersededByNewerFrameMs": String(format: "%.1f", publicationValidation.supersededSeconds * 1_000)
                    ],
                    source: "ScoreboardImageRelayEngine.processLane",
                    reason: publicationValidation.reason,
                    captureGeneration: workToken.captureGeneration,
                    authoritativeOwner: "ScoreboardImageRelayEngine"
                )
                return
            }
        }

        let directScoreCandidates = candidateValues.filter {
            $0.key == .homeScore || $0.key == .awayScore
        }
        let directScoreHashes = hashes.filter {
            directScoreCandidates[$0.key] != nil
        }
        if !directScoreCandidates.isEmpty {
            emitMetadata(
                ScoreboardImageRelayMetadataObservation(
                    kind: .scoreCandidate,
                    clockRunning: nil,
                    movementTransitioned: false,
                    frozenClockImage: nil,
                    visualValues: [:],
                    candidateValues: directScoreCandidates,
                    candidateHashes: directScoreHashes,
                    attemptedKeys: Set(directScoreCandidates.keys),
                    observedAt: Date(),
                    monotonicTime: CFAbsoluteTimeGetCurrent(),
                    sourceSequence: sourceSequence,
                    captureGeneration: captureGeneration,
                    completePenaltyPlayerCycle: false,
                    diagnostic: "direct-score-candidate lane=\(name) values=\(directScoreCandidates.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: ","))"
                )
            )
        }

        ScoreboardImageRelayStore.shared.publish(
            rawImages: rawImages,
            images: images,
            visualValues: visualValues,
            hashes: hashes,
            attemptedKeys: keys,
            lane: name,
            sourceSequence: sourceSequence,
            captureGeneration: captureGeneration,
            processingMilliseconds: elapsedMS,
            extractionSummary: extractionSummary
        )
        let merged = ScoreboardImageRelayStore.shared.snapshot().visualFieldValues
        emitMetadata(
            ScoreboardImageRelayMetadataObservation(
                kind: .visual,
                clockRunning: nil,
                movementTransitioned: false,
                frozenClockImage: nil,
                visualValues: merged,
                candidateValues: candidateValues,
                attemptedKeys: keys,
                observedAt: Date(),
                monotonicTime: CFAbsoluteTimeGetCurrent(),
                sourceSequence: sourceSequence,
                captureGeneration: captureGeneration,
                completePenaltyPlayerCycle: false,
                diagnostic: extractionSummary
            )
        )
    }



    /// Build 619 scorebug-first penalty-player lane:
    /// - crops and hashes all four player zones every 0.30 seconds;
    /// - learns a per-slot blank baseline only from three stable blank observations;
    /// - freezes a candidate only after three stable occupied observations;
    /// - runs at most three bounded metadata-recognition attempts in 2.5 seconds;
    /// - keeps physical occupancy authoritative when OCR is weak or unavailable;
    /// - supports atomic shift-and-fill transitions such as [45,56] -> [56,77].
    private func processPenaltyPlayerLane(
        name: String,
        pixelBuffer: CVPixelBuffer,
        processor: ScoreboardOCRProcessor,
        sourceSequence: Int?,
        captureGeneration: Int,
        layout: ScoreboardOCRLayout,
        colourProfiles: OCRColourProfileSet,
        boardCalibration: BoardCalibrationQuad,
        previewSize: CGSize,
        previewRotationDegrees: CGFloat,
        workToken: RelayWorkToken,
        homeRosterNumbers: Set<Int>,
        precomputedCrops: [OCRRegionKey: CGImage]? = nil
    ) {
        let started = CFAbsoluteTimeGetCurrent()
        let entryValidation = validateRelayWorkToken(workToken, maximumAgeSeconds: 2.5)
        guard entryValidation.allowed else {
            recordStalePenaltyCommitDrop(
                lane: "penalty-player",
                entityID: "penalty-player-cycle-entry",
                token: workToken,
                validation: entryValidation
            )
            return
        }
        let geometryChanges = synchronizePenaltyPlayerGeometry(layout: layout)
        let crops = precomputedCrops.map { shared in
            shared.filter { Self.penaltyPlayerRelayedKeys.contains($0.key) }
        } ?? processor.imageRelayDirectFieldCrops(
            from: pixelBuffer,
            layout: layout,
            boardCalibration: boardCalibration,
            keys: Self.penaltyPlayerRelayedKeys,
            deviceOrientation: .landscapeLeft,
            previewSize: previewSize,
            previewRotationDegrees: previewRotationDegrees
        )

        guard auxiliaryStageMayContinue(
            token: workToken,
            maximumAgeSeconds: 2.5,
            checkpoint: "penalty-player-after-crops",
            admissionPolicy: .penaltySemantic
        ) else { return }

        var hashObservations: [OCRRegionKey: RelayPenaltyPlayerHashObservation] = [:]
        for key in Self.orderedPenaltyPlayerKeys {
            guard auxiliaryStageMayContinue(
                token: workToken,
                maximumAgeSeconds: 2.5,
                checkpoint: "penalty-player-hash-\(key.rawValue)",
                admissionPolicy: .penaltySemantic
            ) else { return }
            guard let crop = crops[key] else {
                hashObservations[key] = RelayPenaltyPlayerHashObservation(
                    hash: nil,
                    previousOccupiedHash: nil,
                    previousStableIdentityHash: nil,
                    occupancy: .unknown("player-crop-missing"),
                    materialChange: false,
                    distanceFromPrevious: nil,
                    distanceFromBlank: nil,
                    baselineReady: false,
                    stableOccupiedCount: 0,
                    stableBlankCount: 0,
                    startedFromStableBlank: false,
                    stableIdentityHash: nil,
                    frozenCandidateReady: false,
                    frozenOCRAttempt: 0,
                    diagnostic: "hash-unavailable player-crop-missing"
                )
                continue
            }
            let profile = colourProfiles.profile(for: key)
            let physicalOccupancy = Self.penaltyPlayerOccupancy(
                from: crop,
                key: key,
                colourProfile: profile
            )
            recordPenaltyAmbientLightRejectionTransition(
                key: key,
                occupancy: physicalOccupancy,
                captureGeneration: captureGeneration
            )
            hashObservations[key] = observePenaltyPlayerHash(
                key: key,
                crop: crop,
                physicalOccupancy: physicalOccupancy,
                geometryChanged: geometryChanges.contains(key)
            )
        }

        // Build 621 removes continuous live player OCR. Recognition is now a
        // bounded internal service run only against a stable frozen Image Relay
        // player crop. Three stable occupied observations create the candidate;
        // the hash state permits no more than three attempts inside 2.5 seconds.
        // The resulting text is metadata only and can never replace the live
        // scorebug player image. Home and Away popup numbers use this OCR result;
        // only Home may add a roster name.
        var ocrKeys: Set<OCRRegionKey> = []
        var forcedTransitionOCRKeys: Set<OCRRegionKey> = []
        for key in Self.orderedPenaltyPlayerKeys {
            guard let hashObservation = hashObservations[key] else { continue }
            // OCR remains metadata-only and cannot run until the physical player
            // and timer boxes have confirmed the same active penalty pair.
            // Build 143 / RL-266 removes the contradictory second occupancy veto:
            // once the pair owner has acknowledged player+timer, recognise the
            // current crop if the older hash owner did not freeze a candidate.
            let pairSignal = penaltyPairSignalSnapshot(for: key)
            if pairSignal.confirmed {
                ocrKeys.insert(key)
                if !hashObservation.frozenCandidateReady {
                    forcedTransitionOCRKeys.insert(key)
                }
            }
        }

        // Build 684: an occupied player box that remains unresolved for several
        // fast-lane cycles receives a dedicated current-crop recognition pass.
        // This prevents a valid Guest penalty from staying image-only indefinitely
        // and gives sponsor/player enrichment a bounded recovery path.
        for key in Self.orderedPenaltyPlayerKeys {
            guard let hashObservation = hashObservations[key],
                  hashObservation.occupancy.isConfirmedOccupied,
                  penaltyPairSignalSnapshot(for: key).confirmed else { continue }
            let recognitionState = penaltyPlayerRecognitionSnapshot(for: key)
            if recognitionState.confirmedValue == nil,
               recognitionState.retainedEvidenceCycles >= 3 {
                ocrKeys.insert(key)
                forcedTransitionOCRKeys.insert(key)
            }
        }

        // Build 678: a blank Slot 2 is strong compaction evidence, but it is not
        // required. A third penalty can refill Slot 2 in the same scoreboard
        // update, producing [21,45] -> [45,77]. Whenever either physical slot
        // reports a material identity change and Slot 2 has a previous stable
        // identity, recognise the CURRENT crops rather than the old frozen crops.
        // Slot 1 proves the continuing Slot 2 player; an occupied Slot 2 is also
        // read so the replacement player can start without waiting for another
        // unrelated hash transition. Blank Slot 2 still accelerates the same path.
        let transitionPairs: [(OCRRegionKey, OCRRegionKey)] = [
            (.homePenalty1Player, .homePenalty2Player),
            (.awayPenalty1Player, .awayPenalty2Player)
        ]
        for (firstKey, secondKey) in transitionPairs {
            guard let firstHash = hashObservations[firstKey],
                  let secondHash = hashObservations[secondKey],
                  firstHash.occupancy.isConfirmedOccupied,
                  secondHash.previousStableIdentityHash != nil else { continue }

            let transitionEvidence = firstHash.materialChange
                || secondHash.materialChange
                || secondHash.occupancy.isConfirmedBlank
            guard transitionEvidence else { continue }

            if penaltyPairSignalSnapshot(for: firstKey).confirmed {
                ocrKeys.insert(firstKey)
                forcedTransitionOCRKeys.insert(firstKey)
            }
            if secondHash.occupancy.isConfirmedOccupied,
               penaltyPairSignalSnapshot(for: secondKey).confirmed {
                ocrKeys.insert(secondKey)
                forcedTransitionOCRKeys.insert(secondKey)
            }
        }
        guard auxiliaryStageMayContinue(
            token: workToken,
            maximumAgeSeconds: 2.5,
            checkpoint: "penalty-player-before-recognition",
            admissionPolicy: .penaltySemantic
        ) else { return }

        var observations: [OCRRegionKey: RelayPenaltyPlayerCycleObservation] = [:]
        for key in Self.orderedPenaltyPlayerKeys {
            guard auxiliaryStageMayContinue(
                token: workToken,
                maximumAgeSeconds: 2.5,
                checkpoint: "penalty-player-recognition-\(key.rawValue)",
                admissionPolicy: .penaltySemantic
            ) else { return }
            guard let hashObservation = hashObservations[key] else { continue }
            let recognition: RelayVisualRecognitionResult
            let attempted = ocrKeys.contains(key)
            let recognitionCrop: CGImage? = forcedTransitionOCRKeys.contains(key)
                ? crops[key]
                : penaltyPlayerFrozenRecognitionCrop(for: key)
            if attempted, let recognitionCrop {
                recognition = Self.recogniseOCRModeVisualValue(
                    from: recognitionCrop,
                    key: key,
                    colourProfile: colourProfiles.profile(for: key),
                    sourceSequence: sourceSequence,
                    captureGeneration: captureGeneration,
                    homeRosterNumbers: homeRosterNumbers
                )
                guard auxiliaryStageMayContinue(
                    token: workToken,
                    maximumAgeSeconds: 2.5,
                    checkpoint: "penalty-player-after-recognition-\(key.rawValue)",
                    admissionPolicy: .penaltySemantic
                ) else { return }
            } else {
                recognition = RelayVisualRecognitionResult(
                    value: nil,
                    confidence: 0,
                    diagnostic: "hash-monitor-no-ocr"
                )
            }
            observations[key] = RelayPenaltyPlayerCycleObservation(
                candidate: recognition.value,
                confidence: recognition.confidence,
                parserDiagnostic: recognition.diagnostic,
                occupancy: hashObservation.occupancy,
                ocrAttempted: attempted,
                perceptualHash: hashObservation.hash,
                hashDiagnostic: hashObservation.diagnostic
            )
        }

        // Expensive recognition work above has not yet committed semantic or viewer
        // penalty state. Revalidate the same immutable frame before any rebind,
        // recognition-state resolution, visibility change or metadata publication.
        guard auxiliaryStageMayContinue(
            token: workToken,
            maximumAgeSeconds: 2.5,
            checkpoint: "penalty-player-before-commit",
            admissionPolicy: .penaltySemantic
        ) else { return }
        let commitValidation = validateRelayWorkToken(workToken, maximumAgeSeconds: 2.5)
        guard commitValidation.allowed else {
            recordStalePenaltyCommitDrop(
                lane: "penalty-player",
                entityID: "penalty-player-cycle-commit",
                token: workToken,
                validation: commitValidation
            )
            return
        }

        let rebindings = reconcilePenaltyPlayerSlotMoves(
            observations: observations,
            hashObservations: hashObservations
        )
        for move in rebindings where move.sourceSlot == 2 && move.destinationSlot == 1 {
            ScoreboardImageRelayStore.shared.compactConfirmedPenaltySlot2ToSlot1(
                team: move.team,
                sourceSequence: sourceSequence,
                captureGeneration: captureGeneration,
                reason: "Physical player-image continuity proved Slot 2 to Slot 1 movement independently of goal-event classification; \(move.diagnostic)"
            )
        }
        // Build 621 separates viewer-facing physical player images from internal
        // recognised identity metadata. The scorebug store receives only relay
        // images for player slots; text remains inside the metadata observation.
        var metadataValues: [OCRRegionKey: String] = [:]
        let relayImages: [OCRRegionKey: CGImage] = [:]
        let relayHashes: [OCRRegionKey: UInt64] = [:]
        let publishKeys: Set<OCRRegionKey> = []
        var slotEvidence: [OCRRegionKey: ScoreboardImageRelayPenaltySlotEvidence] = [:]
        var stableOccupiedVisibilityKeys: Set<OCRRegionKey> = []
        var stableBlankVisibilityKeys: Set<OCRRegionKey> = []
        var acceptedDiagnostics: [String] = []
        var rejectedDiagnostics: [String] = []

        func firstSlotOccupancy(for secondKey: OCRRegionKey) -> RelayPenaltyPlayerOccupancy {
            switch secondKey {
            case .homePenalty2Player:
                return observations[.homePenalty1Player]?.occupancy ?? .unknown("slot1-observation-missing")
            case .awayPenalty2Player:
                return observations[.awayPenalty1Player]?.occupancy ?? .unknown("slot1-observation-missing")
            default:
                return .occupied("not-second-slot")
            }
        }

        for key in Self.orderedPenaltyPlayerKeys {
            guard let observation = observations[key] else { continue }
            let pairSignal = penaltyPairSignalSnapshot(for: key)
            let resolved = resolvePenaltyPlayerValue(
                key: key,
                candidate: observation.candidate,
                confidence: observation.confidence,
                parserDiagnostic: observation.parserDiagnostic,
                occupancy: observation.occupancy,
                ocrAttempted: observation.ocrAttempted
            )
            let slot1Occupancy = firstSlotOccupancy(for: key)
            // Build 652: player height/density is only one half of the physical
            // evidence. The matching calibrated timer box must also contain a
            // strong measured digit band. This prevents frame/label fragments in
            // an empty player box from creating a false penalty lifecycle.
            if Self.isSecondPenaltyPlayer(key), pairSignal.confirmed {
                authoriseSecondPenaltyPlayer(key)
            }
            let gateReason: String? = pairSignal.confirmed
                ? nil
                : "held-awaiting-player+timer-pair \(pairSignal.diagnostic)"

            let stableOccupiedCount = pairSignal.confirmed ? max(2, pairSignal.positiveCount) : 0
            let stableBlankCount = hashObservations[key]?.stableBlankCount ?? 0
            if pairSignal.confirmed {
                stableOccupiedVisibilityKeys.insert(key)
            }
            // One publication may not assert both occupied and blank for the same
            // slot. The visibility reducer applies blank after occupied, so the
            // stale density verdict would otherwise erase the authoritative pair
            // acknowledgement in this very commit.
            if !pairSignal.confirmed,
               observation.occupancy.isConfirmedBlank,
               stableBlankCount >= 3 {
                stableBlankVisibilityKeys.insert(key)
            }

            // Build 624: this lane is metadata-only. The direct 0.30-second
            // penalty timer lane owns both viewer-facing player and timer images.
            // Occupancy classification can therefore never suppress, clear or
            // delay the physical Image Relay pair.

            let stateSnapshot = penaltyPlayerRecognitionSnapshot(for: key)
            let physicalIdentitySnapshot = penaltyPlayerPhysicalIdentitySnapshot(for: key)
            let combinedDecision = "\(observation.hashDiagnostic); \(resolved.diagnostic)"
            let lifecycleOccupancy: ScoreboardImageRelayPenaltySlotOccupancy = {
                if pairSignal.confirmed { return .confirmedOccupied }
                if observation.occupancy.isConfirmedBlank { return .confirmedBlank }
                return .unresolved
            }()
            slotEvidence[key] = ScoreboardImageRelayPenaltySlotEvidence(
                rawCandidate: observation.candidate,
                resolvedPlayer: resolved.value,
                retainedPlayer: stateSnapshot.confirmedValue,
                confidence: observation.confidence,
                occupancy: lifecycleOccupancy,
                physicalIdentityHash: pairSignal.confirmed ? physicalIdentitySnapshot.hash : nil,
                stableOccupiedCount: stableOccupiedCount,
                stableBlankCount: hashObservations[key]?.stableBlankCount ?? 0,
                startedFromStableBlank: hashObservations[key]?.startedFromStableBlank ?? false,
                pairCandidateStartedAt: pairSignal.candidateStartedAt,
                pairConfirmedAt: pairSignal.confirmedAt,
                lifecycleAuthorised: pairSignal.confirmed,
                retainedEvidenceCycles: stateSnapshot.retainedEvidenceCycles,
                decision: gateReason.map { "\($0); \(combinedDecision)" } ?? "\(pairSignal.diagnostic); \(combinedDecision)"
            )

            if let gateReason {
                rejectedDiagnostics.append(
                    "\(key.rawValue)=\(gateReason) slot1Occupancy=\(slot1Occupancy.metadataState.rawValue) retained=\(stateSnapshot.confirmedValue ?? "empty") cycles=\(stateSnapshot.retainedEvidenceCycles) evidence={\(combinedDecision)}"
                )
            } else if let value = resolved.value {
                metadataValues[key] = value
                acceptedDiagnostics.append(
                    "\(key.rawValue)=player \(value) popup-ocr=\(observation.ocrAttempted ? "attempted" : "skipped") {\(combinedDecision)}"
                )
            } else {
                rejectedDiagnostics.append(
                    "\(key.rawValue)=inactive occupancy=\(observation.occupancy.metadataState.rawValue) ocr=\(observation.ocrAttempted ? "attempted" : "skipped") {\(combinedDecision)}"
                )
            }
        }

        func rawDescription(_ key: OCRRegionKey) -> String {
            guard let observation = observations[key] else { return "missing" }
            return "\(observation.candidate ?? "blank")@\(String(format: "%.2f", observation.confidence))/\(observation.occupancy.diagnostic)/ocr=\(observation.ocrAttempted ? "yes" : "no")/\(observation.hashDiagnostic)"
        }
        let rawCycle = "home=[s1=\(rawDescription(.homePenalty1Player)),s2=\(rawDescription(.homePenalty2Player))] away=[s1=\(rawDescription(.awayPenalty1Player)),s2=\(rawDescription(.awayPenalty2Player))]"
        let resolvedCycle = Self.orderedPenaltyPlayerKeys.map {
            "\($0.rawValue)=\(metadataValues[$0] ?? "blank")"
        }.joined(separator: ",")

        let elapsedMS = (CFAbsoluteTimeGetCurrent() - started) * 1_000
        let acceptedText = acceptedDiagnostics.sorted().joined(separator: ";")
        let rejectedText = rejectedDiagnostics.sorted().joined(separator: ";")
        let rebindText = rebindings.isEmpty ? "none" : rebindings.map(\.diagnostic).joined(separator: ",")
        let summary = "penaltyPlayers={\(acceptedText)} rejected={\(rejectedText)} raw={\(rawCycle)} resolved={\(resolvedCycle)} rebindings={\(rebindText)}"
        RinkLensOCREvidenceJournal.shared.recordEventAudit(
            stage: "image_relay_penalty_slot_cycle",
            eventKind: "penalty_state",
            source: "image-relay",
            detail: "\(rawCycle) resolved=[\(resolvedCycle)] rebindings=[\(rebindText)]"
        )
        let publicationValidation = validateRelayWorkToken(workToken, maximumAgeSeconds: 2.5)
        guard publicationValidation.allowed else {
            recordStalePenaltyCommitDrop(
                lane: "penalty-player",
                entityID: "penalty-player-cycle-publication",
                token: workToken,
                validation: publicationValidation
            )
            return
        }
        ScoreboardImageRelayStore.shared.reconcileConfirmedPenaltyVisibility(
            occupiedKeys: stableOccupiedVisibilityKeys,
            blankKeys: stableBlankVisibilityKeys,
            sourceSequence: sourceSequence,
            captureGeneration: captureGeneration,
            reason: "multiplex-safe two-illuminated-frame occupancy authority"
        )
        ScoreboardImageRelayStore.shared.publish(
            rawImages: crops,
            images: relayImages,
            visualValues: [:],
            hashes: relayHashes,
            attemptedKeys: publishKeys,
            lane: name,
            sourceSequence: sourceSequence,
            captureGeneration: captureGeneration,
            processingMilliseconds: elapsedMS,
            extractionSummary: summary
        )
        var merged = ScoreboardImageRelayStore.shared.snapshot().visualFieldValues
        metadataValues.forEach { merged[$0.key] = $0.value }
        emitMetadata(
            ScoreboardImageRelayMetadataObservation(
                kind: .visual,
                clockRunning: nil,
                movementTransitioned: false,
                frozenClockImage: nil,
                visualValues: merged,
                attemptedKeys: Self.penaltyPlayerRelayedKeys,
                observedAt: Date(),
                monotonicTime: CFAbsoluteTimeGetCurrent(),
                sourceSequence: sourceSequence,
                captureGeneration: captureGeneration,
                completePenaltyPlayerCycle: crops.count == Self.penaltyPlayerRelayedKeys.count,
                penaltySlotEvidence: slotEvidence,
                diagnostic: summary
            )
        )
    }

    private func eligiblePenaltyTimerWorkKeys(
        viewerAcceptedPenaltyPlayers: Set<OCRRegionKey>
    ) -> Set<OCRRegionKey> {
        let accepted = Self.penaltyTimerPairs.filter {
            viewerAcceptedPenaltyPlayers.contains($0.player)
        }
        if !accepted.isEmpty { return Set(accepted.map(\.timer)) }

        // R18: an unaccepted penalty must not fan out into four expensive
        // timer crops because of one noisy player observation. Require repeated
        // player occupancy (or an already-visible pair), then verify only one
        // candidate timer per two-second discovery pass. Accepted penalties keep
        // their 0.30-second active timer service above.
        let candidates = Self.penaltyTimerPairs.filter { pair in
            let physical = penaltyPlayerPhysicalIdentitySnapshot(for: pair.player)
            penaltyVisualLock.lock()
            let hasVisualState = penaltyVisualStates[pair.player] != nil
            penaltyVisualLock.unlock()
            return physical.stableCount >= 2 || hasVisualState
        }
        let ordered = candidates.sorted(by: { $0.timer.rawValue < $1.timer.rawValue })
        guard !ordered.isEmpty else { return [] }
        lock.lock()
        let index = unacceptedPenaltyTimerDiscoveryCursor % ordered.count
        unacceptedPenaltyTimerDiscoveryCursor = (index + 1) % ordered.count
        lock.unlock()
        return [ordered[index].timer]
    }

    /// Build 619 active penalty-timer lane. Confirmed player identities or current
    /// physical player-slot occupancy activate the timer crop, so OCR delay cannot
    /// suppress a genuine timer. Only those timer zones are cropped and
    /// published every 0.30 seconds. This mirrors the Clock's direct fast lane:
    /// fixed geometry, no OCR, no content-bound scaling and no 0:00 detection.
    private func processPenaltyTimerLane(
        name: String,
        pixelBuffer: CVPixelBuffer,
        processor: ScoreboardOCRProcessor,
        sourceSequence: Int?,
        captureGeneration: Int,
        layout: ScoreboardOCRLayout,
        colourProfiles: OCRColourProfileSet,
        boardCalibration: BoardCalibrationQuad,
        previewSize: CGSize,
        previewRotationDegrees: CGFloat,
        workToken: RelayWorkToken,
        viewerAcceptedPenaltyPlayers: Set<OCRRegionKey>,
        requestedTimerKeys: Set<OCRRegionKey>,
        precomputedCrops: [OCRRegionKey: CGImage]? = nil
    ) {
        let started = CFAbsoluteTimeGetCurrent()
        let allPairs = Self.penaltyTimerPairs
        let acceptedPairs = allPairs.filter { viewerAcceptedPenaltyPlayers.contains($0.player) }
        // Active viewer timers are a 0.30-second service; diagnostic discovery is
        // a two-second service. Neither may mutate current penalty state after
        // sitting behind unrelated auxiliary work for multiple seconds.
        let maximumCommitAgeSeconds: TimeInterval = acceptedPairs.isEmpty ? 2.5 : 1.0
        let fastLaneEnabled = RinkLensRiskFeaturePolicy.isEnabled(.penaltyTimerFastLaneV3)
        // Build 705: Build 703 cropped and decoded all four timer zones every
        // 0.30 seconds, producing 0.8s+ passes in the supplied match log. Process
        // only physically active pairs, unresolved transition pairs, or one final
        // clearing pass for a visual state that still exists.
        let requestedPairs = allPairs.filter { requestedTimerKeys.contains($0.timer) }
        let activePairs = acceptedPairs.isEmpty ? requestedPairs : acceptedPairs
        let allKeys = fastLaneEnabled
            ? Set(activePairs.map(\.timer))
            : Set(activePairs.flatMap { [$0.timer, $0.player] })
        let crops = precomputedCrops ?? processor.imageRelayDirectFieldCrops(
            from: pixelBuffer,
            layout: layout,
            boardCalibration: boardCalibration,
            keys: allKeys,
            deviceOrientation: .landscapeLeft,
            previewSize: previewSize,
            previewRotationDegrees: previewRotationDegrees
        )

        var images: [OCRRegionKey: CGImage] = [:]
        var hashes: [OCRRegionKey: UInt64] = [:]
        var attemptedKeys: Set<OCRRegionKey> = []
        var acceptedDiagnostics: [String] = []
        var rejectedDiagnostics: [String] = []

        var fastTimerCandidates: [OCRRegionKey: DirectPenaltyTimerCandidate] = [:]
        if fastLaneEnabled {
            for pair in activePairs {
                let timerKey = pair.timer
                guard let timerCrop = crops[timerKey],
                      let candidate = Self.makeDirectPenaltyTimerCandidate(
                        from: timerCrop,
                        key: timerKey,
                        colourProfile: colourProfiles.profile(for: timerKey)
                      ) else { continue }
                fastTimerCandidates[timerKey] = candidate
            }
        }

        for pair in activePairs {
            let playerKey = pair.player
            let timerKey = pair.timer
            let playerProfile = colourProfiles.profile(for: playerKey)
            let physicalIdentity = penaltyPlayerPhysicalIdentitySnapshot(for: playerKey)
            let stableBlankCount = penaltyPlayerStableBlankCount(for: playerKey)
            let playerCrop: CGImage? = fastLaneEnabled
                ? penaltyPlayerFrozenRecognitionCrop(for: playerKey)
                : crops[playerKey]
            let playerOccupancy: RelayPenaltyPlayerOccupancy = {
                if fastLaneEnabled {
                    if physicalIdentity.stableCount >= 2 {
                        return .occupied("player-lane-owned stableCount=\(physicalIdentity.stableCount)")
                    }
                    if stableBlankCount >= 3 {
                        return .blank("player-lane-owned stableBlank=\(stableBlankCount)")
                    }
                    return .unknown("player-lane-owned evidence unresolved")
                }
                return playerCrop.map {
                    Self.penaltyPlayerOccupancy(
                        from: $0,
                        key: playerKey,
                        colourProfile: playerProfile
                    )
                } ?? .unknown("player-crop-missing")
            }()
            let currentPlayerImage = playerCrop.flatMap { crop in
                Self.penaltyPlayerRelayImage(
                    from: crop,
                    key: playerKey,
                    colourProfile: playerProfile
                )
            }
            let timerCandidate: DirectPenaltyTimerCandidate? = {
                if fastLaneEnabled { return fastTimerCandidates[timerKey] }
                return crops[timerKey].flatMap { timerCrop in
                    Self.makeDirectPenaltyTimerCandidate(
                        from: timerCrop,
                        key: timerKey,
                        colourProfile: colourProfiles.profile(for: timerKey)
                    )
                }
            }()
            let timerAdmission = timerCandidate.map(Self.penaltyTimerGeometryAdmissionDecision)
            let timerStrong = timerAdmission?.allowed ?? false
            // Recovery V RL-055: the complete expensive crop/candidate path above
            // is side-effect free. Revalidate the immutable source frame immediately
            // before the first penalty-state mutation. A 33-second-old timer frame
            // can therefore never start, confirm, clear or rebind a current penalty.
            let commitValidation = validateRelayWorkToken(
                workToken,
                maximumAgeSeconds: maximumCommitAgeSeconds
            )
            guard commitValidation.allowed else {
                recordStalePenaltyCommitDrop(
                    lane: "penalty-timer",
                    entityID: playerKey.rawValue,
                    token: workToken,
                    validation: commitValidation
                )
                rejectedDiagnostics.append(
                    "\(playerKey.rawValue)+\(timerKey.rawValue)=stale-work-discarded {\(commitValidation.reason)}"
                )
                continue
            }

            // Build 703: the fast timer lane consumes physical player identity from
            // the player-lane owner; it never performs a second occupancy read.
            // Build 663: physical occupancy owns the penalty lifecycle. A cleaned
            // player bitmap is presentation evidence only and may legitimately be
            // unavailable during LED scan phases, focus changes or route recovery.
            let pairSignal = updatePenaltyPairSignal(
                playerKey: playerKey,
                sourceSequence: sourceSequence,
                captureGeneration: captureGeneration,
                playerOccupied: playerOccupancy.isConfirmedOccupied,
                // Use the multiplex-protected hash lane as blank authority. A
                // single dark LED scan frame from the fast timer lane cannot end
                // an active penalty, while a genuinely blank zone can override a
                // lingering timer bezel/reflection after three confirmed samples.
                playerConfirmedBlank: stableBlankCount >= 3,
                playerStableOccupiedCount: physicalIdentity.stableCount,
                playerStartedFromStableBlank: physicalIdentity.startedFromStableBlank,
                timerStrong: timerStrong,
                timerAdmissionReason: timerAdmission?.reason ?? "no-candidate"
            )
            if pairSignal.newlyCandidate,
               RinkLensRiskFeaturePolicy.isEnabled(.eventLatencyLoggingV2) {
                RinkLensStructuredEventLogger.shared.record(
                    domain: .penalty,
                    event: "penalty_physical_pair_candidate_started",
                    entityID: playerKey.rawValue,
                    previous: ["candidate": "false", "confirmed": "false"],
                    next: [
                        "candidate": "true",
                        "stablePlayer": String(physicalIdentity.stableCount),
                        "startedFromStableBlank": physicalIdentity.startedFromStableBlank ? "true" : "false",
                        "timerStrong": timerStrong ? "true" : "false"
                    ],
                    source: "ScoreboardImageRelay.penaltyPair",
                    reason: pairSignal.diagnostic,
                    captureGeneration: captureGeneration
                )
            }
            if pairSignal.newlyConfirmed {
                let candidateToConfirmMS = pairSignal.candidateStartedAt.map {
                    max(0, (CFAbsoluteTimeGetCurrent() - $0) * 1_000)
                }
                RinkLensStructuredEventLogger.shared.record(
                    domain: .penalty,
                    event: "penalty_physical_pair_confirmed",
                    entityID: playerKey.rawValue,
                    previous: ["confirmed": "false"],
                    next: [
                        "confirmed": "true",
                        "stablePlayer": String(physicalIdentity.stableCount),
                        "startedFromStableBlank": physicalIdentity.startedFromStableBlank ? "true" : "false",
                        "timerStrong": timerStrong ? "true" : "false",
                        "candidateToConfirmMs": candidateToConfirmMS.map { String(format: "%.1f", $0) } ?? "unknown"
                    ],
                    source: "ScoreboardImageRelay.penaltyPair",
                    reason: pairSignal.diagnostic + " timerAdmission=" + (timerAdmission?.reason ?? "no-candidate"),
                    captureGeneration: captureGeneration
                )
            }
            if pairSignal.cleared {
                RinkLensStructuredEventLogger.shared.record(
                    domain: .penalty,
                    event: "penalty_physical_pair_cleared",
                    entityID: playerKey.rawValue,
                    previous: ["confirmed": "true"],
                    next: ["confirmed": "false"],
                    source: "ScoreboardImageRelay.penaltyPair",
                    reason: pairSignal.diagnostic + " timerAdmission=" + (timerAdmission?.reason ?? "no-candidate"),
                    captureGeneration: captureGeneration
                )
                penaltyVisualLock.lock()
                penaltyVisualStates.removeValue(forKey: playerKey)
                penaltyVisualLock.unlock()
                attemptedKeys.formUnion([playerKey, timerKey])
                acceptedDiagnostics.append(
                    "\(playerKey.rawValue)+\(timerKey.rawValue)=visual-state-cleared \(pairSignal.diagnostic)"
                )
                continue
            }

            guard pairSignal.confirmed else {
                rejectedDiagnostics.append(
                    "\(playerKey.rawValue)+\(timerKey.rawValue)=held-awaiting-paired-signal \(pairSignal.diagnostic) player=\(playerOccupancy.metadataState.rawValue) timerStrong=\(timerStrong ? "yes" : "no")"
                )
                continue
            }

            let calibrationSignature = Self.penaltyVisualCalibrationSignature(
                playerKey: playerKey,
                timerKey: timerKey,
                layout: layout,
                colourProfiles: colourProfiles,
                boardCalibration: boardCalibration,
                previewRotationDegrees: previewRotationDegrees
            )

            penaltyVisualLock.lock()
            var state: RelayPenaltyVisualState
            if let existing = penaltyVisualStates[playerKey] {
                state = existing

                if state.captureGeneration != captureGeneration {
                    state.captureGeneration = captureGeneration
                    state.phase = .staleAwaitingReacquisition
                    // Build 663: a Broadcast/OCR route hand-off is not a physical
                    // player change. Keep the last accepted player and timer visual
                    // while fresh frames revalidate it. Calibration-signature logic
                    // below remains the authority for a genuine geometry change.
                    state.pendingPlayerReplacementHash = nil
                    state.pendingPlayerReplacementCount = 0
                    state.timerAcquisitionRect = nil
                    state.timerAcquisitionCount = 0
                    state.pendingExpansionRect = nil
                    state.pendingExpansionCount = 0
                    state.heldWeakFrameCount = 0
                    state.geometryRevision &+= 1
                    state.lastDecision = "capture-generation-reacquiring"
                }

                if state.calibrationSignature != calibrationSignature {
                    if state.pendingCalibrationSignature == calibrationSignature {
                        state.pendingCalibrationCount += 1
                    } else {
                        state.pendingCalibrationSignature = calibrationSignature
                        state.pendingCalibrationCount = 1
                    }
                    if state.pendingCalibrationCount >= 3 {
                        state.calibrationSignature = calibrationSignature
                        state.pendingCalibrationSignature = nil
                        state.pendingCalibrationCount = 0
                        state.phase = .staleAwaitingReacquisition
                        state.frozenPlayerImage = nil
                        state.frozenPlayerPixelHash = nil
                        state.frozenPlayerShapeHash = nil
                        state.pendingPlayerReplacementHash = nil
                        state.pendingPlayerReplacementCount = 0
                        state.timerAcquisitionRect = nil
                        state.timerAcquisitionCount = 0
                        state.lockedTimerRect = nil
                        state.lockedTimerCharacterCentreX = nil
                        state.lastTimerImage = nil
                        state.lastTimerPixelHash = nil
                        state.pendingExpansionRect = nil
                        state.pendingExpansionCount = 0
                        state.geometryRevision &+= 1
                        state.lastDecision = "committed-calibration-reacquiring"
                    } else {
                        state.lastDecision = "calibration-change-pending \(state.pendingCalibrationCount)/3"
                        penaltyVisualStates[playerKey] = state
                        penaltyVisualLock.unlock()
                        rejectedDiagnostics.append(
                            "\(playerKey.rawValue)+\(timerKey.rawValue)=held-calibration-pending \(state.lastDecision)"
                        )
                        continue
                    }
                } else {
                    state.pendingCalibrationSignature = nil
                    state.pendingCalibrationCount = 0
                }

                if let identity = physicalIdentity.hash,
                   let previousIdentity = state.physicalIdentityHash,
                   identity != previousIdentity {
                    nextPenaltyVisualActivationID &+= 1
                    state = Self.newPenaltyVisualState(
                        activationID: nextPenaltyVisualActivationID,
                        captureGeneration: captureGeneration,
                        calibrationSignature: calibrationSignature,
                        physicalIdentityHash: identity,
                        decision: "confirmed-physical-player-replacement"
                    )
                } else if state.physicalIdentityHash == nil,
                          physicalIdentity.stableCount >= 2,
                          let identity = physicalIdentity.hash {
                    state.physicalIdentityHash = identity
                }

                // Build 650 deliberately stopped changing the lifecycle identity on
                // every perceptual-hash movement. That protects multiplexed players,
                // but a direct physical replacement can therefore occur while the
                // retained lifecycle hash is unchanged. Confirm a materially new
                // glyph shape three times before creating a new visual activation.
                if state.phase == .locked,
                   let currentPlayerImage,
                   let currentShape = Self.penaltyPlayerPerceptualHash(from: currentPlayerImage),
                   let frozenShape = state.frozenPlayerShapeHash,
                   Self.hammingDistance(currentShape, frozenShape) >= 10 {
                    if let pending = state.pendingPlayerReplacementHash,
                       Self.hammingDistance(currentShape, pending) <= 4 {
                        state.pendingPlayerReplacementCount += 1
                    } else {
                        state.pendingPlayerReplacementHash = currentShape
                        state.pendingPlayerReplacementCount = 1
                    }
                    if state.pendingPlayerReplacementCount >= 3 {
                        nextPenaltyVisualActivationID &+= 1
                        state = Self.newPenaltyVisualState(
                            activationID: nextPenaltyVisualActivationID,
                            captureGeneration: captureGeneration,
                            calibrationSignature: calibrationSignature,
                            physicalIdentityHash: physicalIdentity.hash,
                            decision: "three-frame-physical-glyph-replacement"
                        )
                    } else {
                        state.lastDecision = "physical-glyph-replacement-pending \(state.pendingPlayerReplacementCount)/3"
                    }
                } else {
                    state.pendingPlayerReplacementHash = nil
                    state.pendingPlayerReplacementCount = 0
                }
            } else {
                nextPenaltyVisualActivationID &+= 1
                state = Self.newPenaltyVisualState(
                    activationID: nextPenaltyVisualActivationID,
                    captureGeneration: captureGeneration,
                    calibrationSignature: calibrationSignature,
                    physicalIdentityHash: physicalIdentity.stableCount >= 2 ? physicalIdentity.hash : nil,
                    decision: pairSignal.newlyConfirmed
                        ? "paired-activation-acquiring"
                        : "restored-confirmed-pair-acquiring"
                )
            }

            if state.phase != .locked {
                if state.frozenPlayerImage == nil,
                   physicalIdentity.stableCount >= 2,
                   let currentPlayerImage {
                    state.frozenPlayerImage = currentPlayerImage
                    state.frozenPlayerPixelHash = Self.canonicalRelayPixelHash(
                        currentPlayerImage,
                        key: playerKey
                    )
                    state.frozenPlayerShapeHash = Self.penaltyPlayerPerceptualHash(
                        from: currentPlayerImage
                    )
                    state.lastDecision = "player-image-frozen"
                }

                if timerStrong, let candidate = timerCandidate {
                    // Build 687 permits no provisional/full-zone publication.
                    // Two compatible clean geometry observations lock the timer;
                    // until then the player/timer pair remains visually pending.
                    let admission = Self.penaltyTimerGeometryAdmissionDecision(candidate)
                    if admission.allowed {
                        let proposed = candidate.proposedRect
                        if let first = state.timerAcquisitionRect,
                           Self.timerRectsAreCompatible(first, proposed) {
                            state.timerAcquisitionCount += 1
                            state.timerAcquisitionRect = first.union(proposed)
                        } else {
                            state.timerAcquisitionRect = proposed
                            state.timerAcquisitionCount = 1
                        }
                        if state.timerAcquisitionCount >= 2,
                           let acquired = state.timerAcquisitionRect {
                            let locked = Self.boundedRelayRect(
                                acquired,
                                sourceWidth: candidate.sourceWidth,
                                sourceHeight: candidate.sourceHeight
                            )
                            state.lockedTimerRect = locked
                            if let crop = candidate.fullZoneImage.cropping(to: locked),
                               let visible = Self.visibleAlphaBounds(in: crop) {
                                state.lockedTimerCharacterCentreX = locked.minX + visible.midX
                            } else {
                                state.lockedTimerCharacterCentreX = locked.midX
                            }
                            state.geometryRevision &+= 1
                            state.lastDecision = "timer-anchor-locked[\(admission.reason)]"
                        }
                    } else {
                        state.heldWeakFrameCount += 1
                        state.lastDecision = "timer-geometry-held[\(admission.reason)]"
                    }
                } else {
                    state.heldWeakFrameCount += 1
                    state.lastDecision = timerCandidate == nil
                        ? "acquisition-no-timer-candidate"
                        : "acquisition-timer-signal-below-threshold"
                }

                if state.frozenPlayerImage != nil, state.lockedTimerRect != nil {
                    state.phase = .locked
                    state.lastDecision = "visual-pair-locked"
                } else if state.phase == .staleAwaitingReacquisition {
                    state.phase = .acquiring
                }
            }

            guard let frozenPlayer = state.frozenPlayerImage,
                  let playerPixelHash = state.frozenPlayerPixelHash else {
                penaltyVisualStates[playerKey] = state
                penaltyVisualLock.unlock()
                rejectedDiagnostics.append(
                    "\(playerKey.rawValue)+\(timerKey.rawValue)=visual-acquiring player=pending timer=\(state.lockedTimerRect == nil ? "pending" : "ready") decision=\(state.lastDecision)"
                )
                continue
            }
            guard let presentationRect = state.lockedTimerRect else {
                penaltyVisualStates[playerKey] = state
                penaltyVisualLock.unlock()
                rejectedDiagnostics.append(
                    "\(playerKey.rawValue)+\(timerKey.rawValue)=visual-acquiring player=ready timer=pending decision=\(state.lastDecision)"
                )
                continue
            }

            var resolvedTimerRect = presentationRect
            var geometryDecision = "timer-anchor-held"
            if timerStrong,
               let candidate = timerCandidate,
               Self.timerCandidateCanEstablishGeometry(candidate) {
                let lockedRect = presentationRect
                let proposed = candidate.proposedRect
                if Self.timerRectNeedsHorizontalExpansion(locked: lockedRect, proposed: proposed),
                   Self.timerRectsAreVerticallyCompatible(lockedRect, proposed) {
                    if let pending = state.pendingExpansionRect,
                       Self.timerRectsAreCompatible(pending, proposed) {
                        state.pendingExpansionCount += 1
                        state.pendingExpansionRect = pending.union(proposed)
                    } else {
                        state.pendingExpansionRect = proposed
                        state.pendingExpansionCount = 1
                    }
                    if state.pendingExpansionCount >= 2,
                       let expansion = state.pendingExpansionRect {
                        let expanded = CGRect(
                            x: min(lockedRect.minX, expansion.minX),
                            y: lockedRect.minY,
                            width: max(lockedRect.maxX, expansion.maxX) - min(lockedRect.minX, expansion.minX),
                            height: lockedRect.height
                        )
                        resolvedTimerRect = Self.boundedRelayRect(
                            expanded,
                            sourceWidth: candidate.sourceWidth,
                            sourceHeight: candidate.sourceHeight
                        )
                        state.lockedTimerRect = resolvedTimerRect
                        state.pendingExpansionRect = nil
                        state.pendingExpansionCount = 0
                        state.geometryRevision &+= 1
                        state.acceptedExpansionCount += 1
                        geometryDecision = "timer-expansion-confirmed"
                    } else {
                        geometryDecision = "timer-expansion-pending \(state.pendingExpansionCount)/2"
                    }
                } else {
                    if proposed.width < lockedRect.width - 0.5
                        || abs(proposed.midX - lockedRect.midX) > max(2, lockedRect.width * 0.05) {
                        state.rejectedShrinkCount += 1
                        geometryDecision = "timer-shrink-or-recentre-held"
                    }
                    state.pendingExpansionRect = nil
                    state.pendingExpansionCount = 0
                }
            }

            guard timerStrong,
                  let candidate = timerCandidate,
                  let timer = Self.renderDirectPenaltyTimerImage(
                    candidate,
                    displayRect: resolvedTimerRect,
                    lockedCharacterCentreX: state.lockedTimerCharacterCentreX
                        ?? resolvedTimerRect.midX,
                    stabilisationDiagnostic: "geometry=activation-owned \(geometryDecision) activation=\(state.activationID) geometryRevision=\(state.geometryRevision)"
                  ) else {
                state.heldWeakFrameCount += 1
                state.lastDecision = "timer-current-frame-held"
                penaltyVisualStates[playerKey] = state
                penaltyVisualLock.unlock()
                rejectedDiagnostics.append(
                    "\(timerKey.rawValue)=timer-current-frame-held activation=\(state.activationID)"
                )
                continue
            }

            let timerPixelHash = Self.canonicalRelayPixelHash(timer.image, key: timerKey)
            let playerPublicationHash = Self.relayVisualPublicationHash(
                key: playerKey,
                activationID: state.activationID,
                geometryRevision: state.geometryRevision,
                pixelHash: playerPixelHash
            )
            let timerPublicationHash = Self.relayVisualPublicationHash(
                key: timerKey,
                activationID: state.activationID,
                geometryRevision: state.geometryRevision,
                pixelHash: timerPixelHash
            )
            let firstPairPublication = state.lastTimerImage == nil
            state.lastTimerImage = timer.image
            state.lastTimerPixelHash = timerPixelHash
            state.lastDecision = "locked \(geometryDecision)"
            penaltyVisualStates[playerKey] = state
            penaltyVisualLock.unlock()

            if firstPairPublication {
                attemptedKeys.formUnion([playerKey, timerKey])
                images[playerKey] = frozenPlayer
                hashes[playerKey] = playerPublicationHash
            }
            attemptedKeys.insert(timerKey)
            images[timerKey] = timer.image
            hashes[timerKey] = timerPublicationHash

            if RinkLensRiskFeaturePolicy.isEnabled(.penaltyTimerLatencyLoggingV3) {
                let publishedAt = CFAbsoluteTimeGetCurrent()
                lock.lock()
                let previousHash = lastPenaltyTimerLoggedPublicationHash[timerKey]
                let previousPublishedAt = lastPenaltyTimerPublishedAt[timerKey]
                if previousHash != timerPublicationHash {
                    lastPenaltyTimerLoggedPublicationHash[timerKey] = timerPublicationHash
                    lastPenaltyTimerPublishedAt[timerKey] = publishedAt
                }
                lock.unlock()
                if previousHash != timerPublicationHash {
                    RinkLensStructuredEventLogger.shared.record(
                        domain: .penalty,
                        event: "penalty_timer_visual_published",
                        entityID: timerKey.rawValue,
                        previous: [
                            "publicationHash": previousHash.map { String($0) } ?? "none",
                            "publishedAt": previousPublishedAt.map { String(format: "%.3f", $0) } ?? "none"
                        ],
                        next: [
                            "publicationHash": String(timerPublicationHash),
                            "sourceSequence": sourceSequence.map { String($0) } ?? "none",
                            "sourceFrameAgeMs": String(format: "%.1f", max(0, (publishedAt - workToken.sourceMonotonicTime) * 1_000)),
                            "processingMs": String(format: "%.1f", (publishedAt - started) * 1_000),
                            "publicationIntervalMs": previousPublishedAt.map { String(format: "%.1f", (publishedAt - $0) * 1_000) } ?? "none",
                            "canvas": "\(timer.image.width)x\(timer.image.height)"
                        ],
                        source: "ScoreboardImageRelay.processPenaltyTimerLane",
                        reason: "Timer pixels changed and were published through the sole viewer-presentation owner",
                        captureGeneration: captureGeneration
                    )
                }
            }

            lock.lock()
            lastPenaltyTimerPresentationDiagnostics[timerKey] =
                "activation=\(state.activationID) phase=\(state.phase.rawValue) playerCanvas=\(frozenPlayer.width)x\(frozenPlayer.height) timerCanvas=\(timer.image.width)x\(timer.image.height) rejectedShrinks=\(state.rejectedShrinkCount) acceptedExpansions=\(state.acceptedExpansionCount) weakHeld=\(state.heldWeakFrameCount) \(timer.diagnostic)"
            lock.unlock()
            acceptedDiagnostics.append(
                "\(playerKey.rawValue)+\(timerKey.rawValue)=stable-visual activation=\(state.activationID) \(geometryDecision)"
            )
        }

        let completedAt = CFAbsoluteTimeGetCurrent()
        let elapsedMS = (completedAt - started) * 1_000
        if RinkLensRiskFeaturePolicy.isEnabled(.penaltyTimerLatencyLoggingV3) {
            RinkLensStructuredEventLogger.shared.record(
                domain: .penalty,
                event: "penalty_timer_lane_completed",
                entityID: "timer-lane",
                previous: [
                    "sourceObservedAt": workToken.sourceObservedAt.ISO8601Format(),
                    "sourceMonotonicTime": String(format: "%.3f", workToken.sourceMonotonicTime)
                ],
                next: [
                    "processingMs": String(format: "%.1f", elapsedMS),
                    "sourceFrameAgeMs": String(format: "%.1f", max(0, (completedAt - workToken.sourceMonotonicTime) * 1_000)),
                    "croppedZoneCount": String(crops.count),
                    "activePairCount": String(activePairs.count),
                    "viewerAcceptedPenaltyCount": String(acceptedPairs.count),
                    "serviceClass": acceptedPairs.isEmpty ? "diagnostic-2.0s" : "accepted-viewer-0.30s",
                    "publishedTimerCount": String(images.keys.filter { Self.penaltyTimerRelayedKeys.contains($0) }.count),
                    "fastLane": fastLaneEnabled ? "true" : "false"
                ],
                source: "ScoreboardImageRelay.processPenaltyTimerLane",
                reason: "Complete timer-lane latency boundary",
                captureGeneration: captureGeneration
            )
        }
        let acceptedText = acceptedDiagnostics.sorted().joined(separator: ";")
        let rejectedText = rejectedDiagnostics.sorted().joined(separator: ";")
        let publicationValidation = validateRelayWorkToken(
            workToken,
            maximumAgeSeconds: maximumCommitAgeSeconds
        )
        guard publicationValidation.allowed else {
            recordStalePenaltyCommitDrop(
                lane: "penalty-timer",
                entityID: "penalty-timer-publication",
                token: workToken,
                validation: publicationValidation
            )
            return
        }
        ScoreboardImageRelayStore.shared.publish(
            rawImages: crops,
            images: images,
            visualValues: [:],
            hashes: hashes,
            attemptedKeys: attemptedKeys,
            lane: name,
            sourceSequence: sourceSequence,
            captureGeneration: captureGeneration,
            processingMilliseconds: elapsedMS,
            extractionSummary: "stablePenaltyRelay={\(acceptedText)} held={\(rejectedText)}"
        )
    }

    /// Build 598 Clock geometry hysteresis. Clock pixels still refresh every
    /// 0.30 seconds. The horizontal envelope can only expand, preserving outer
    /// digits, while the tightest trustworthy vertical band is retained so the
    /// preferred larger rendering cannot breathe between frames.
    private func stabilisedClockRect(
        proposed: CGRect,
        captureGeneration: Int,
        sourceWidth: Int,
        sourceHeight: Int
    ) -> (rect: CGRect, diagnostic: String) {
        let bounded = Self.boundedRelayRect(
            proposed,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )

        clockGeometryLock.lock()
        defer { clockGeometryLock.unlock() }

        let existing = clockGeometryState
        let mustReset = existing == nil
            || existing?.sourceWidth != sourceWidth
            || existing?.sourceHeight != sourceHeight

        var state: RelayClockGeometryState
        var actions: [String] = []
        let minimumTrustedHeight = max(8, CGFloat(sourceHeight) * 0.60)
        if mustReset {
            let horizontalSafety = max(2, CGFloat(sourceWidth) * 0.012)
            state = RelayClockGeometryState(
                captureGeneration: captureGeneration,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                minX: max(0, bounded.minX - horizontalSafety),
                maxX: min(CGFloat(sourceWidth), bounded.maxX + horizontalSafety),
                centreY: bounded.midY,
                preferredHeight: max(minimumTrustedHeight, bounded.height),
                updateCount: 1,
                widthExpansionCount: 0,
                tighterHeightCount: 0,
                heldCount: 0
            )
            actions.append("anchor-established")
        } else {
            state = existing!
            if state.captureGeneration != captureGeneration {
                state.captureGeneration = captureGeneration
                actions.append("generation-preserved")
            }
            state.updateCount += 1

            let horizontalSafety = max(1, CGFloat(sourceWidth) * 0.006)
            let proposedMinX = max(0, bounded.minX - horizontalSafety)
            let proposedMaxX = min(CGFloat(sourceWidth), bounded.maxX + horizontalSafety)
            if proposedMinX < state.minX - 0.5 || proposedMaxX > state.maxX + 0.5 {
                state.minX = min(state.minX, proposedMinX)
                state.maxX = max(state.maxX, proposedMaxX)
                state.widthExpansionCount += 1
                actions.append("width-expanded")
            }

            // Recovery DT / RL-004: preserve the stable vertical envelope while
            // the current trusted character band remains inside it, but do not let
            // an obsolete envelope clip real top/bottom digit strokes after a zone
            // geometry change. This is geometry acknowledgement, not OCR recovery:
            // weak/narrow bands still hold the established presentation unchanged.
            let verticalSafety = max(1, CGFloat(sourceHeight) * 0.015)
            let proposedMinY = max(0, bounded.minY - verticalSafety)
            let proposedMaxY = min(CGFloat(sourceHeight), bounded.maxY + verticalSafety)
            let stableMinY = state.centreY - state.preferredHeight / 2
            let stableMaxY = state.centreY + state.preferredHeight / 2
            let trustworthyVerticalBand = bounded.height >= minimumTrustedHeight
            let extendsOutsideStableVerticalEnvelope =
                proposedMinY < stableMinY - 0.5
                || proposedMaxY > stableMaxY + 0.5

            if trustworthyVerticalBand && extendsOutsideStableVerticalEnvelope {
                state.centreY = (proposedMinY + proposedMaxY) / 2
                state.preferredHeight = max(1, proposedMaxY - proposedMinY)
                actions.append("vertical-reanchored")
            }

            if actions.isEmpty {
                state.heldCount += 1
                actions.append("anchor-held")
            }
        }

        let resolved = Self.boundedRelayRect(
            CGRect(
                x: state.minX,
                y: state.centreY - state.preferredHeight / 2,
                width: max(1, state.maxX - state.minX),
                height: max(1, state.preferredHeight)
            ),
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )
        clockGeometryState = state

        return (
            resolved,
            String(
                format: "clockAnchor=%@ proposed=%dx%d+%d,%d stable=%dx%d+%d,%d updates=%d widthExpansions=%d tighterHeights=%d held=%d",
                actions.joined(separator: "+"),
                Int(bounded.width.rounded()),
                Int(bounded.height.rounded()),
                Int(bounded.minX.rounded()),
                Int(bounded.minY.rounded()),
                Int(resolved.width.rounded()),
                Int(resolved.height.rounded()),
                Int(resolved.minX.rounded()),
                Int(resolved.minY.rounded()),
                state.updateCount,
                state.widthExpansionCount,
                state.tighterHeightCount,
                state.heldCount
            )
        )
    }

    /// Locks the presentation centre for one player-owned activation. The envelope
    /// may expand immediately when a newly illuminated outer digit appears, but it
    /// never shrinks or recentres on a weak frame. This removes the left/right pulse
    /// while preserving the live 0.30-second pixel refresh.
    /// Build 652 requires the calibrated player and timer boxes to agree. The
    /// timer thresholds are intentionally broad and derived from the physical logs:
    /// genuine timers measured 7.4-16.0% active with alpha 255, while the failed
    /// Guest blank produced 0.0% active, alpha 52 and no measured digit band.
    private static func isStrongPenaltyTimerSignal(
        _ candidate: DirectPenaltyTimerCandidate?
    ) -> Bool {
        guard let candidate else { return false }
        // Build 687 uses one authority for activation and presentation geometry.
        // A lit bezel, reflection or complete box is not a timer. New pairs require
        // a measured, non-border-contact digit envelope. Once active, weak/dark
        // frames are handled by hold-last-clean and the bounded negative counter.
        return timerCandidateCanEstablishGeometry(candidate)
    }

    private func updatePenaltyPairSignal(
        playerKey: OCRRegionKey,
        sourceSequence: Int?,
        captureGeneration: Int,
        playerOccupied: Bool,
        playerConfirmedBlank: Bool,
        playerStableOccupiedCount: Int,
        playerStartedFromStableBlank: Bool,
        timerStrong: Bool,
        timerAdmissionReason: String
    ) -> (
        confirmed: Bool,
        newlyConfirmed: Bool,
        newlyCandidate: Bool,
        positiveCount: Int,
        candidateStartedAt: CFAbsoluteTime?,
        confirmedAt: CFAbsoluteTime?,
        cleared: Bool,
        diagnostic: String
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        recognitionLock.lock()
        defer { recognitionLock.unlock() }

        var state = penaltyPairSignalStates[playerKey] ?? RelayPenaltyPairSignalState()
        if state.captureGeneration != captureGeneration {
            state = RelayPenaltyPairSignalState()
            state.captureGeneration = captureGeneration
        }
        let wasConfirmed = state.confirmed
        var cleared = false
        var newlyCandidate = false
        let strictTimerAdmission = timerAdmissionReason == "strict-clean"
        let verifiedEdgeFilledTimer = timerAdmissionReason.hasPrefix("feature-edge-filled[")
            || timerAdmissionReason.hasPrefix("feature-repeated-edge-timer[")
        // Build 757: edge-filled timer evidence may establish a pair without a
        // historical blank baseline only when the player crop is already stably
        // occupied. Confirmation below still requires three paired observations
        // over at least 0.55 seconds, so a single sunlight/reflection frame cannot
        // create a penalty lifecycle.
        let timerEligibleForPositive = timerStrong && (
            state.confirmed
                || strictTimerAdmission
                || playerStartedFromStableBlank
                || (verifiedEdgeFilledTimer && playerStableOccupiedCount >= 3)
        )
        if playerOccupied, timerEligibleForPositive {
            let isNewSourceEvidence: Bool
            if let sourceSequence {
                isNewSourceEvidence = state.lastPositiveSourceSequence.map { sourceSequence > $0 } ?? true
            } else {
                isNewSourceEvidence = true
            }
            if isNewSourceEvidence {
                if state.positiveCount == 0 {
                    state.firstPositiveAt = now
                    newlyCandidate = true
                }
                state.positiveCount = min(4, state.positiveCount + 1)
                state.lastPositiveSourceSequence = sourceSequence
            }
            state.negativeTimerCount = 0
            state.negativePlayerBlankCount = 0
            let stablePhysicalPlayer = playerStableOccupiedCount >= 3
            // With a verified blank transition, two independent source frames are
            // sufficient. Otherwise require three. Scheduler completion spacing
            // is deliberately not evidence and cannot reset this episode.
            let requiredPositiveCount = playerStartedFromStableBlank ? 2 : 3
            let minimumEvidenceAge: CFTimeInterval = playerStartedFromStableBlank ? 0.20 : 0.55
            let evidenceAge = state.firstPositiveAt > 0 ? now - state.firstPositiveAt : 0
            if state.positiveCount >= requiredPositiveCount,
               evidenceAge >= minimumEvidenceAge,
               stablePhysicalPlayer {
                state.confirmed = true
                if !wasConfirmed { state.confirmedAt = now }
            }
            state.lastDecision = "paired-positive \(state.positiveCount)/\(requiredPositiveCount) sourceSequence=\(sourceSequence.map(String.init) ?? "none") age=\(String(format: "%.2f", evidenceAge))s stablePlayer=\(playerStableOccupiedCount) startedFromBlank=\(playerStartedFromStableBlank ? "yes" : "no") timerAdmission=\(timerAdmissionReason) confirmed=\(state.confirmed ? "yes" : "no")"
        } else if state.confirmed {
            if playerConfirmedBlank {
                // Build 671: player blank evidence has already survived the
                // multiplex-dark-frame hold in penaltyPlayerHashObservation.
                // It must therefore be allowed to clear a stale lifecycle even if
                // a timer bezel/reflection continues to look strong.
                state.negativePlayerBlankCount = min(3, state.negativePlayerBlankCount + 1)
                state.negativeTimerCount = 0
                if state.negativePlayerBlankCount >= 3 {
                    state.confirmed = false
                    state.positiveCount = 0
                    state.firstPositiveAt = 0
                    state.confirmedAt = 0
                    state.negativePlayerBlankCount = 0
                    cleared = true
                    state.lastDecision = "paired-clear player-blank=3/3 timerStrong=\(timerStrong ? "yes" : "no")"
                } else {
                    state.lastDecision = "paired-clear-player-blank \(state.negativePlayerBlankCount)/3 timerStrong=\(timerStrong ? "yes" : "no")"
                }
            } else if timerStrong {
                // The player display can be dark for an LED scan frame. An
                // unresolved player plus a live timer retains the confirmed pair.
                state.negativeTimerCount = 0
                state.negativePlayerBlankCount = 0
                state.lastDecision = "paired-hold-live-timer player=\(playerOccupied ? "yes" : "unknown")"
            } else {
                state.negativePlayerBlankCount = 0
                state.negativeTimerCount = min(5, state.negativeTimerCount + 1)
                if state.negativeTimerCount >= 5 {
                    state.confirmed = false
                    state.positiveCount = 0
                    state.firstPositiveAt = 0
                    state.confirmedAt = 0
                    state.negativeTimerCount = 0
                    cleared = true
                    state.lastDecision = "paired-clear timer-negative=5/5"
                } else {
                    state.lastDecision = "paired-clear-candidate timer-negative=\(state.negativeTimerCount)/5 player=\(playerOccupied ? "yes" : "no")"
                }
            }
        } else {
            state.negativePlayerBlankCount = 0
            state.lastDecision = "paired-candidate-held player=\(playerOccupied ? "yes" : "no") timer=\(timerStrong ? "yes" : "no") timerEligible=\(timerEligibleForPositive ? "yes" : "no") admission=\(timerAdmissionReason)"
        }
        penaltyPairSignalStates[playerKey] = state
        return (
            state.confirmed,
            !wasConfirmed && state.confirmed,
            newlyCandidate,
            state.positiveCount,
            state.firstPositiveAt > 0 ? state.firstPositiveAt : nil,
            state.confirmedAt > 0 ? state.confirmedAt : nil,
            cleared,
            state.lastDecision
        )
    }

    private func penaltyPairSignalSnapshot(
        for playerKey: OCRRegionKey
    ) -> (
        confirmed: Bool,
        positiveCount: Int,
        candidateStartedAt: CFAbsoluteTime?,
        confirmedAt: CFAbsoluteTime?,
        diagnostic: String
    ) {
        recognitionLock.lock()
        defer { recognitionLock.unlock() }
        let state = penaltyPairSignalStates[playerKey] ?? RelayPenaltyPairSignalState()
        return (
            state.confirmed,
            state.positiveCount,
            state.firstPositiveAt > 0 ? state.firstPositiveAt : nil,
            state.confirmedAt > 0 ? state.confirmedAt : nil,
            state.lastDecision
        )
    }

    private func resetPenaltyPairSignal(for playerKey: OCRRegionKey, reason: String) {
        recognitionLock.lock()
        var state = RelayPenaltyPairSignalState()
        state.lastDecision = "reset-\(reason)"
        penaltyPairSignalStates[playerKey] = state
        recognitionLock.unlock()
    }

    private func penaltyPlayerRecognitionSnapshot(
        for key: OCRRegionKey
    ) -> (confirmedValue: String?, retainedEvidenceCycles: Int) {
        recognitionLock.lock()
        defer { recognitionLock.unlock() }
        let state = recognitionStates[key] ?? RelayVisualRecognitionState()
        return (state.confirmedValue, state.retainedEvidenceCycleCount)
    }

    /// Reads the post-reconciliation physical identity. Unlike the hash observation
    /// captured before slot reconciliation, this snapshot includes any atomic
    /// Slot 2 -> Slot 1 identity transfer performed in the same cycle.
    private func penaltyPlayerPhysicalIdentitySnapshot(
        for key: OCRRegionKey
    ) -> (hash: UInt64?, stableCount: Int, startedFromStableBlank: Bool) {
        recognitionLock.lock()
        defer { recognitionLock.unlock() }
        let state = penaltyPlayerHashStates[key]
        return (
            state?.frozenCandidateHash,
            state?.occupiedCandidateCount ?? 0,
            state?.occupiedCandidateStartedFromStableBlank ?? false
        )
    }

    private func penaltyPlayerStableBlankCount(for key: OCRRegionKey) -> Int {
        recognitionLock.lock()
        defer { recognitionLock.unlock() }
        return penaltyPlayerHashStates[key]?.stableBlankCount ?? 0
    }

    private func penaltyPlayerFrozenRecognitionCrop(for key: OCRRegionKey) -> CGImage? {
        recognitionLock.lock()
        defer { recognitionLock.unlock() }
        return penaltyPlayerFrozenRecognitionCrops[key]
    }

    private func authoriseSecondPenaltyPlayer(_ key: OCRRegionKey) {
        guard Self.isSecondPenaltyPlayer(key) else { return }
        recognitionLock.lock()
        var state = recognitionStates[key] ?? RelayVisualRecognitionState()
        state.secondSlotActivationAuthorised = true
        recognitionStates[key] = state
        recognitionLock.unlock()
    }

    private func secondPenaltyPlayerIsAuthorised(_ key: OCRRegionKey) -> Bool {
        guard Self.isSecondPenaltyPlayer(key) else { return true }
        recognitionLock.lock()
        let authorised = recognitionStates[key]?.secondSlotActivationAuthorised == true
        recognitionLock.unlock()
        return authorised
    }

    private func clearPenaltyPlayerState(for key: OCRRegionKey, reason: String) {
        recognitionLock.lock()
        var state = recognitionStates[key] ?? RelayVisualRecognitionState()
        state.confirmedValue = nil
        state.pendingValue = nil
        state.pendingCount = 0
        state.consecutiveMisses = 0
        state.recentPlayerEvidence.removeAll()
        state.secondSlotActivationAuthorised = false
        state.retainedEvidenceCycleCount = 0
        state.lastConfidence = 0
        state.lastDecision = reason
        recognitionStates[key] = state
        recognitionLock.unlock()
    }

    /// Build 579 binds Image Relay recognition evidence to the exact current
    /// Calibration geometry. Moving, resizing or rotating a player zone clears
    /// its old candidate/confirmed value before the next read can activate it.
    /// Changing Penalty 1 also clears Penalty 2 for that team because slot 2 is
    /// structurally dependent on slot 1.
    private func synchronizePenaltyPlayerGeometry(layout: ScoreboardOCRLayout) -> Set<OCRRegionKey> {
        recognitionLock.lock()
        defer { recognitionLock.unlock() }
        var changed: Set<OCRRegionKey> = []

        for key in Self.orderedPenaltyPlayerKeys {
            let signature = Self.geometrySignature(for: layout[key])
            var state = recognitionStates[key] ?? RelayVisualRecognitionState()
            if state.geometrySignature == 0 {
                state.geometrySignature = signature
                recognitionStates[key] = state
                continue
            }
            guard state.geometrySignature != signature else { continue }

            state = RelayVisualRecognitionState()
            state.geometrySignature = signature
            state.lastDecision = "geometry-changed-reset"
            recognitionStates[key] = state
            penaltyPlayerHashStates[key] = RelayPenaltyPlayerHashState()
            penaltyPairSignalStates[key] = RelayPenaltyPairSignalState(
                lastDecision: "geometry-changed-reset"
            )
            changed.insert(key)

            let dependentSecond: OCRRegionKey?
            switch key {
            case .homePenalty1Player: dependentSecond = .homePenalty2Player
            case .awayPenalty1Player: dependentSecond = .awayPenalty2Player
            default: dependentSecond = nil
            }
            if let dependentSecond {
                var dependent = RelayVisualRecognitionState()
                dependent.geometrySignature = Self.geometrySignature(for: layout[dependentSecond])
                dependent.lastDecision = "slot1-geometry-changed-reset"
                recognitionStates[dependentSecond] = dependent
                penaltyPlayerHashStates[dependentSecond] = RelayPenaltyPlayerHashState()
                penaltyPairSignalStates[dependentSecond] = RelayPenaltyPairSignalState(
                    lastDecision: "slot1-geometry-changed-reset"
                )
                changed.insert(dependentSecond)
            }
        }
        return changed
    }

    private static func geometrySignature(for region: OCRRegion) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for value in [region.x, region.y, region.width, region.height, region.rotationDegrees] {
            var bits = Double(value).bitPattern
            withUnsafeBytes(of: &bits) { bytes in
                for byte in bytes {
                    hash ^= UInt64(byte)
                    hash &*= 1_099_511_628_211
                }
            }
        }
        return hash
    }

    private static func isSecondPenaltyPlayer(_ key: OCRRegionKey) -> Bool {
        key == .homePenalty2Player || key == .awayPenalty2Player
    }

    /// Build 619 atomic two-slot reconciliation. Physical hash continuity is the
    /// first authority for an existing player moving between slots. This supports
    /// both [45,56] -> [56,blank] and the real-board shift-and-fill transition
    /// [45,56] -> [56,77]. OCR identifies the newly-filled slot but is not required
    /// to move the continuing player's lifecycle and timer source.
    private struct RelayPenaltyPlayerSlotMove {
        let team: Team
        let sourceSlot: Int
        let destinationSlot: Int
        let continuingPlayer: String?
        let diagnostic: String
    }

    private func reconcilePenaltyPlayerSlotMoves(
        observations: [OCRRegionKey: RelayPenaltyPlayerCycleObservation],
        hashObservations: [OCRRegionKey: RelayPenaltyPlayerHashObservation]
    ) -> [RelayPenaltyPlayerSlotMove] {
        recognitionLock.lock()
        defer { recognitionLock.unlock() }

        var actions: [RelayPenaltyPlayerSlotMove] = []
        let teams: [(Team, OCRRegionKey, OCRRegionKey)] = [
            (.home, .homePenalty1Player, .homePenalty2Player),
            (.away, .awayPenalty1Player, .awayPenalty2Player)
        ]

        func prepareDestination(
            _ state: inout RelayVisualRecognitionState,
            player: String,
            confidence: Float,
            isSecondSlot: Bool,
            decision: String
        ) {
            state.confirmedValue = player
            state.pendingValue = nil
            state.pendingCount = 0
            state.consecutiveMisses = 0
            state.lastConfidence = confidence
            state.recentPlayerEvidence.removeAll()
            state.secondSlotActivationAuthorised = isSecondSlot
            state.retainedEvidenceCycleCount = 0
            state.lastDecision = decision
        }

        func clearSource(_ state: inout RelayVisualRecognitionState, decision: String) {
            state.confirmedValue = nil
            state.pendingValue = nil
            state.pendingCount = 0
            state.consecutiveMisses = 0
            state.recentPlayerEvidence.removeAll()
            state.secondSlotActivationAuthorised = false
            state.retainedEvidenceCycleCount = 0
            state.lastDecision = decision
        }


        /// Transfers the exact stable physical lifecycle identity when the board
        /// shifts an existing penalty between slots. If the vacated source is
        /// immediately filled, it starts a new stable-candidate sequence rather
        /// than inheriting the continuing player's identity.
        func transferPhysicalIdentity(
            continuingHash: UInt64,
            destinationKey: OCRRegionKey,
            sourceKey: OCRRegionKey,
            sourceRemainsOccupied: Bool,
            sourceCurrentHash: UInt64?
        ) {
            var destination = penaltyPlayerHashStates[destinationKey] ?? RelayPenaltyPlayerHashState()
            destination.frozenCandidateHash = continuingHash
            destination.occupiedCandidateHash = continuingHash
            destination.occupiedCandidateCount = max(3, destination.occupiedCandidateCount)
            destination.lastOccupiedHash = continuingHash
            destination.lastOccupiedObservedAt = CFAbsoluteTimeGetCurrent()
            destination.frozenOCRAttemptCount = 0
            destination.frozenOCRStartedAt = 0
            destination.lastDecision = "physical-identity-transferred-from-\(sourceKey.rawValue)"
            if let continuingCrop = penaltyPlayerFrozenRecognitionCrops[sourceKey] {
                penaltyPlayerFrozenRecognitionCrops[destinationKey] = continuingCrop
            }
            penaltyPlayerHashStates[destinationKey] = destination

            var source = penaltyPlayerHashStates[sourceKey] ?? RelayPenaltyPlayerHashState()
            if sourceRemainsOccupied,
               let sourceCurrentHash,
               Self.hammingDistance(sourceCurrentHash, continuingHash) >= 8 {
                source.frozenCandidateHash = nil
                source.occupiedCandidateHash = sourceCurrentHash
                source.occupiedCandidateCount = 1
                source.lastOccupiedHash = sourceCurrentHash
                source.lastOccupiedObservedAt = CFAbsoluteTimeGetCurrent()
                source.frozenOCRAttemptCount = 0
                source.frozenOCRStartedAt = 0
                penaltyPlayerFrozenRecognitionCrops.removeValue(forKey: sourceKey)
                source.lastDecision = "shift-fill-new-physical-candidate"
            } else if !sourceRemainsOccupied {
                source.frozenCandidateHash = nil
                source.occupiedCandidateHash = nil
                source.occupiedCandidateCount = 0
                source.lastOccupiedHash = nil
                source.lastOccupiedObservedAt = 0
                source.frozenOCRAttemptCount = 0
                source.frozenOCRStartedAt = 0
                penaltyPlayerFrozenRecognitionCrops.removeValue(forKey: sourceKey)
                source.lastDecision = "source-cleared-after-physical-rebind"
            }
            penaltyPlayerHashStates[sourceKey] = source
        }

        func acceptShiftFillCandidate(
            observation: RelayPenaltyPlayerCycleObservation,
            excluding continuing: String,
            into state: inout RelayVisualRecognitionState,
            decision: String
        ) -> String? {
            guard observation.occupancy.isConfirmedOccupied,
                  let candidate = observation.candidate,
                  candidate != continuing,
                  observation.confidence >= 0.65 else {
                clearSource(&state, decision: "\(decision) awaiting-new-player-ocr")
                return nil
            }
            prepareDestination(
                &state,
                player: candidate,
                confidence: observation.confidence,
                isSecondSlot: true,
                decision: "\(decision) new-player=\(candidate)"
            )
            return candidate
        }

        for (team, firstKey, secondKey) in teams {
            guard let firstObservation = observations[firstKey],
                  let secondObservation = observations[secondKey],
                  let firstHash = hashObservations[firstKey],
                  let secondHash = hashObservations[secondKey] else { continue }

            var firstState = recognitionStates[firstKey] ?? RelayVisualRecognitionState()
            var secondState = recognitionStates[secondKey] ?? RelayVisualRecognitionState()

            // Primary real-scoreboard path: the current Slot 1 image matches the
            // previous occupied Slot 2 image. This path is identity/image based and
            // deliberately does not require OCR, so it works for Guest penalties and
            // for Home numbers that have not yet matched the roster.
            let firstHashChangedFromOwnIdentity: Bool = {
                guard let currentFirstHash = firstHash.hash else { return false }
                if firstHash.materialChange { return true }
                guard let previousFirstIdentity = firstHash.previousStableIdentityHash else { return false }
                return Self.hammingDistance(currentFirstHash, previousFirstIdentity) >= 6
            }()

            if firstHash.occupancy.isConfirmedOccupied,
               firstHashChangedFromOwnIdentity,
               let currentFirstHash = firstHash.hash,
               let previousSecondHash = secondHash.previousOccupiedHash,
               Self.hammingDistance(currentFirstHash, previousSecondHash) <= 10,
               (secondHash.occupancy.isConfirmedBlank || secondHash.materialChange) {
                let continuingPlayer = secondState.confirmedValue
                let displaced = firstState.confirmedValue

                if let continuingPlayer {
                    prepareDestination(
                        &firstState,
                        player: continuingPlayer,
                        confidence: max(firstObservation.confidence, secondState.lastConfidence),
                        isSecondSlot: false,
                        decision: "hash-rebind-slot2-to-slot1 player=\(continuingPlayer)"
                    )
                } else {
                    clearSource(
                        &firstState,
                        decision: "hash-rebind-slot2-to-slot1 physical-identity-only"
                    )
                }

                let newPlayer: String?
                if secondHash.occupancy.isConfirmedOccupied {
                    if team == .home, let continuingPlayer {
                        newPlayer = acceptShiftFillCandidate(
                            observation: secondObservation,
                            excluding: continuingPlayer,
                            into: &secondState,
                            decision: "hash-shift-fill-slot2"
                        )
                    } else {
                        newPlayer = nil
                        clearSource(
                            &secondState,
                            decision: "hash-shift-fill-slot2 awaiting-stable-physical-identity"
                        )
                    }
                    // Physical Slot 1 is occupied and the cross-slot move is proven,
                    // so Slot 2 remains legitimate even when its new identity is pending.
                    secondState.secondSlotActivationAuthorised = true
                } else {
                    newPlayer = nil
                    clearSource(
                        &secondState,
                        decision: "hash-rebind-source-cleared player=\(continuingPlayer ?? "physical")"
                    )
                }

                if let continuingHash = secondHash.previousStableIdentityHash {
                    transferPhysicalIdentity(
                        continuingHash: continuingHash,
                        destinationKey: firstKey,
                        sourceKey: secondKey,
                        sourceRemainsOccupied: secondHash.occupancy.isConfirmedOccupied,
                        sourceCurrentHash: secondHash.hash
                    )
                }

                recognitionStates[firstKey] = firstState
                recognitionStates[secondKey] = secondState
                let physicalIdentity = secondHash.previousStableIdentityHash
                    .map { String($0, radix: 16) } ?? "pending"
                actions.append(
                    RelayPenaltyPlayerSlotMove(
                        team: team,
                        sourceSlot: 2,
                        destinationSlot: 1,
                        continuingPlayer: continuingPlayer,
                        diagnostic: "\(team.rawValue):physical=\(physicalIdentity) 2->1 player=\(continuingPlayer ?? "unresolved") displaced=\(displaced ?? "none") fill=\(newPlayer ?? (secondHash.occupancy.isConfirmedOccupied ? "pending" : "blank")) authority=hash"
                    )
                )
                continue
            }

            // OCR fallback retained for boards/crops where perceptual matching is
            // unavailable but the continuing identity is read clearly.
            if let continuing = secondState.confirmedValue,
               firstObservation.candidate == continuing,
               firstObservation.confidence >= 0.62,
               firstObservation.occupancy.isConfirmedOccupied,
               ((secondObservation.occupancy.isConfirmedBlank && secondHash.stableBlankCount >= 2)
                    || secondHash.materialChange) {
                let displaced = firstState.confirmedValue
                prepareDestination(
                    &firstState,
                    player: continuing,
                    confidence: firstObservation.confidence,
                    isSecondSlot: false,
                    decision: "ocr-rebind-slot2-to-slot1 player=\(continuing)"
                )
                let newPlayer: String?
                if secondObservation.occupancy.isConfirmedOccupied {
                    newPlayer = acceptShiftFillCandidate(
                        observation: secondObservation,
                        excluding: continuing,
                        into: &secondState,
                        decision: "ocr-shift-fill-slot2"
                    )
                    secondState.secondSlotActivationAuthorised = true
                } else {
                    newPlayer = nil
                    clearSource(
                        &secondState,
                        decision: "ocr-rebind-source-cleared player=\(continuing)"
                    )
                }
                if let continuingHash = secondHash.previousStableIdentityHash {
                    transferPhysicalIdentity(
                        continuingHash: continuingHash,
                        destinationKey: firstKey,
                        sourceKey: secondKey,
                        sourceRemainsOccupied: secondObservation.occupancy.isConfirmedOccupied,
                        sourceCurrentHash: secondHash.hash
                    )
                }
                recognitionStates[firstKey] = firstState
                recognitionStates[secondKey] = secondState
                actions.append(
                    RelayPenaltyPlayerSlotMove(
                        team: team,
                        sourceSlot: 2,
                        destinationSlot: 1,
                        continuingPlayer: continuing,
                        diagnostic: "\(team.rawValue):\(continuing) 2->1 displaced=\(displaced ?? "none") fill=\(newPlayer ?? (secondObservation.occupancy.isConfirmedOccupied ? "pending" : "blank")) authority=ocr"
                    )
                )
                continue
            }

            // Symmetric fallback retained for unusual physical boards that move a
            // continuing player from Slot 1 to Slot 2.
            if let continuing = firstState.confirmedValue,
               secondObservation.candidate == continuing,
               secondObservation.confidence >= 0.62,
               secondObservation.occupancy.isConfirmedOccupied,
               firstObservation.occupancy.isConfirmedBlank {
                let displaced = secondState.confirmedValue
                prepareDestination(
                    &secondState,
                    player: continuing,
                    confidence: secondObservation.confidence,
                    isSecondSlot: true,
                    decision: "ocr-rebind-slot1-to-slot2 player=\(continuing)"
                )
                clearSource(
                    &firstState,
                    decision: "ocr-rebind-source-cleared player=\(continuing)"
                )
                if let continuingHash = firstHash.previousStableIdentityHash {
                    transferPhysicalIdentity(
                        continuingHash: continuingHash,
                        destinationKey: secondKey,
                        sourceKey: firstKey,
                        sourceRemainsOccupied: false,
                        sourceCurrentHash: firstHash.hash
                    )
                }
                recognitionStates[firstKey] = firstState
                recognitionStates[secondKey] = secondState
                actions.append(
                    RelayPenaltyPlayerSlotMove(
                        team: team,
                        sourceSlot: 1,
                        destinationSlot: 2,
                        continuingPlayer: continuing,
                        diagnostic: "\(team.rawValue):\(continuing) 1->2 displaced=\(displaced ?? "none") authority=ocr"
                    )
                )
            }
        }
        return actions
    }

    /// Build 598 penalty activation accepts only candidates that have already passed
    /// the colour-source and geometry trust gate. Two matching trusted reads establish
    /// an empty slot. Once a player is confirmed, a different number needs three strong
    /// matching reads; a single high-confidence 69 therefore cannot displace an incumbent
    /// 89. Three genuine blank misses clear the slot. Timer 0:00 is never a clearing signal.
    private func resolvePenaltyPlayerValue(
        key: OCRRegionKey,
        candidate: String?,
        confidence: Float,
        parserDiagnostic: String,
        occupancy: RelayPenaltyPlayerOccupancy,
        ocrAttempted: Bool
    ) -> (value: String?, diagnostic: String) {
        recognitionLock.lock()
        defer { recognitionLock.unlock() }

        var state = recognitionStates[key] ?? RelayVisualRecognitionState()
        let minimumTrustedConfidence: Float = 0.65
        let replacementConfidenceFloor: Float = 0.86
        let evidenceWindow: TimeInterval = 8.0
        let now = CFAbsoluteTimeGetCurrent()

        state.recentPlayerEvidence.removeAll { now - $0.observedAt > evidenceWindow }
        if state.recentPlayerEvidence.count > 8 {
            state.recentPlayerEvidence.removeFirst(state.recentPlayerEvidence.count - 8)
        }

        // The 0.30-second hash lane deliberately skips OCR on unchanged slots.
        // An unavailable/unknown hash sample is therefore a pause, not a parser miss
        // and never increments the removal counter.
        if !ocrAttempted,
           !occupancy.isConfirmedBlank,
           !occupancy.isConfirmedOccupied {
            state.lastDecision = "hash-unavailable-held=\(state.confirmedValue ?? "empty")"
            recognitionStates[key] = state
            return (
                state.confirmedValue,
                "\(state.lastDecision) occupancy=\(occupancy.diagnostic)"
            )
        }

        // Build 609: preserve the pre-Build-608 Clock logic completely. This
        // penalty-only correction resolves contradictory evidence inside one player
        // crop: a trusted recognised player proves the slot is occupied for this
        // pass, so the separate blank classifier cannot remove the same value.
        // Genuine blank removal requires ten independent 0.30-second hash crops.
        let trustedCandidatePresent = candidate != nil && confidence >= minimumTrustedConfidence
        let candidateConfirmsIncumbent = candidate != nil
            && candidate == state.confirmedValue
            && confidence >= 0.55
        if occupancy.isConfirmedBlank,
           !trustedCandidatePresent,
           !candidateConfirmsIncumbent {
            state.consecutiveMisses += 1
            state.pendingValue = nil
            state.pendingCount = 0
            state.recentPlayerEvidence.removeAll()
            state.lastConfidence = confidence

            if let held = state.confirmedValue, state.consecutiveMisses < 10 {
                state.lastDecision = "held-player=\(held) physical-blank=\(state.consecutiveMisses)/10"
                recognitionStates[key] = state
                return (
                    held,
                    "\(state.lastDecision) occupancy=\(occupancy.diagnostic) parser={\(Self.compactDiagnostic(parserDiagnostic))}"
                )
            }

            if let cleared = state.confirmedValue {
                state.confirmedValue = nil
                state.consecutiveMisses = 0
                if Self.isSecondPenaltyPlayer(key) {
                    state.secondSlotActivationAuthorised = false
                }
                state.lastDecision = "cleared-player=\(cleared) after-10-physical-blank-crops"
            } else {
                state.lastDecision = "inactive-player physical-blank=\(min(10, state.consecutiveMisses))/10"
            }
            recognitionStates[key] = state
            return (
                nil,
                "\(state.lastDecision) occupancy=\(occupancy.diagnostic) parser={\(Self.compactDiagnostic(parserDiagnostic))}"
            )
        }

        // A genuinely blank player zone remains the sole clearing signal. Parser
        // output such as ?7, a geometry-held 77 or another nonblank unresolved value
        // proves that the physical slot is occupied and must not erase evidence.
        let compactParserDiagnostic = Self.compactDiagnostic(parserDiagnostic)
        let unresolvedOccupied = occupancy.isConfirmedOccupied
            || parserDiagnostic.contains("ocr-mode-player-held value=")
            || Self.nonBlankRejectedPlayerRaw(in: parserDiagnostic)
        guard let candidate else {
            if unresolvedOccupied {
                state.consecutiveMisses = 0
                state.retainedEvidenceCycleCount += 1
                state.lastConfidence = confidence
                state.lastDecision = "occupied-player-unresolved held=\(state.confirmedValue ?? "empty") evidence-kept cycles=\(state.retainedEvidenceCycleCount)"
                recognitionStates[key] = state
                return (
                    state.confirmedValue,
                    "\(state.lastDecision) occupancy=\(occupancy.diagnostic) \(compactParserDiagnostic)"
                )
            }

            state.consecutiveMisses += 1
            state.lastConfidence = confidence

            if let held = state.confirmedValue, state.consecutiveMisses < 10 {
                state.lastDecision = "held-player=\(held) blank-miss=\(state.consecutiveMisses)/10"
                recognitionStates[key] = state
                return (held, "\(state.lastDecision) \(compactParserDiagnostic)")
            }

            if let cleared = state.confirmedValue {
                state.confirmedValue = nil
                state.pendingValue = nil
                state.pendingCount = 0
                state.recentPlayerEvidence.removeAll()
                state.consecutiveMisses = 0
                if Self.isSecondPenaltyPlayer(key) {
                    state.secondSlotActivationAuthorised = false
                }
                state.lastDecision = "cleared-player=\(cleared) after-10-blank-misses"
            } else {
                state.lastDecision = "inactive-player blank-miss=\(min(10, state.consecutiveMisses))/10"
            }
            recognitionStates[key] = state
            return (nil, "\(state.lastDecision) \(compactParserDiagnostic)")
        }

        guard confidence >= minimumTrustedConfidence else {
            state.consecutiveMisses = 0
            state.lastConfidence = confidence
            state.lastDecision = "weak-player=\(candidate) conf=\(String(format: "%.2f", confidence)) held=\(state.confirmedValue ?? "empty") evidence-kept"
            recognitionStates[key] = state
            return (
                state.confirmedValue,
                "\(state.lastDecision) \(Self.compactDiagnostic(parserDiagnostic))"
            )
        }

        state.consecutiveMisses = 0
        state.retainedEvidenceCycleCount = 0
        state.lastConfidence = confidence

        if candidate == state.confirmedValue {
            state.pendingValue = nil
            state.pendingCount = 0
            state.recentPlayerEvidence.removeAll()
            state.lastDecision = "confirmed-player=\(candidate) unchanged"
            recognitionStates[key] = state
            return (candidate, "\(state.lastDecision) conf=\(String(format: "%.2f", confidence))")
        }

        state.recentPlayerEvidence.append(
            RelayPlayerCandidateEvidence(value: candidate, confidence: confidence, observedAt: now)
        )
        if state.recentPlayerEvidence.count > 8 {
            state.recentPlayerEvidence.removeFirst(state.recentPlayerEvidence.count - 8)
        }

        let hasIncumbent = state.confirmedValue != nil
        let persistentColourDisagreement = parserDiagnostic.contains(
            "ocr-mode-player-colour-disagreement-candidate="
        )
        let shiftFillPreauthorised = !hasIncumbent
            && state.secondSlotActivationAuthorised
            && occupancy.isConfirmedOccupied
        let votesRequired = shiftFillPreauthorised
            ? 1
            : (hasIncumbent || persistentColourDisagreement ? 3 : 2)
        let matching = state.recentPlayerEvidence.filter { evidence in
            guard evidence.value == candidate else { return false }
            return !hasIncumbent || evidence.confidence >= replacementConfidenceFloor
        }
        state.pendingValue = candidate
        state.pendingCount = matching.count

        if matching.count >= votesRequired {
            let previous = state.confirmedValue ?? "empty"
            let span = max(0, (matching.last?.observedAt ?? now) - (matching.first?.observedAt ?? now))
            let bestConfidence = matching.map(\.confidence).max() ?? confidence
            state.confirmedValue = candidate
            state.pendingValue = nil
            state.pendingCount = 0
            state.recentPlayerEvidence.removeAll()
            state.lastDecision = hasIncumbent
                ? "verified-player-replacement=\(previous)->\(candidate) votes=\(matching.count) span=\(String(format: "%.1f", span))s"
                : "window-player=\(previous)->\(candidate) votes=\(matching.count) span=\(String(format: "%.1f", span))s"
            recognitionStates[key] = state
            return (
                candidate,
                "\(state.lastDecision) bestConf=\(String(format: "%.2f", bestConfidence))"
            )
        }

        let evidenceSummary = state.recentPlayerEvidence
            .map { "\($0.value)@\(String(format: "%.2f", $0.confidence))" }
            .joined(separator: ",")
        let holdReason = hasIncumbent ? "incumbent-held" : "initial-pending"
        state.lastDecision = "\(holdReason) candidate=\(candidate) votes=\(matching.count)/\(votesRequired) replacementFloor=\(String(format: "%.2f", replacementConfidenceFloor)) window=\(evidenceWindow)s held=\(state.confirmedValue ?? "empty") evidence=[\(evidenceSummary)]"
        recognitionStates[key] = state
        return (
            state.confirmedValue,
            "\(state.lastDecision) \(Self.compactDiagnostic(parserDiagnostic))"
        )
    }

    /// Build 579: recognise from the exact original perspective-corrected field crop,
    /// using the saved colour profile and the exact dynamic-token parser used by
    /// normal OCR mode. This is used for Score, Period and penalty-player values.
    /// No alpha-only relay mask or custom seven-segment renderer is involved.
    private static func recogniseOCRModeVisualValue(
        from fieldCrop: CGImage,
        key: OCRRegionKey,
        colourProfile: OCRZoneColourProfile,
        sourceSequence: Int?,
        captureGeneration: Int,
        homeRosterNumbers: Set<Int> = []
    ) -> RelayVisualRecognitionResult {
        guard key == .homeScore || key == .awayScore || key == .period || Self.isPenaltyPlayer(key) else {
            return RelayVisualRecognitionResult(value: nil, confidence: 0, diagnostic: "not-visual-field")
        }

        let budgetMilliseconds: UInt64
        if Self.isPenaltyPlayer(key) {
            budgetMilliseconds = 150
        } else {
            budgetMilliseconds = key == .period ? 180 : 220
        }
        let deadline = DispatchTime.now().uptimeNanoseconds &+ budgetMilliseconds * 1_000_000
        let attempt = RinkLensLightweightOCRParser.parseDynamicTokens(
            from: fieldCrop,
            key: key,
            colourProfile: colourProfile,
            deadlineUptimeNanoseconds: deadline,
            sourceFrameID: sourceSequence,
            captureGeneration: captureGeneration
        )

        let acceptedRawValue: String?
        let colourDisagreementRecovery: Bool
        let scoreSequentialConflictRecovery: Bool
        let displayedScore = (key == .homeScore || key == .awayScore)
            ? ScoreboardImageRelayStore.shared.snapshot().visualValue(for: key)
            : nil
        if let direct = attempt.value,
           validatedRelayVisualValue(direct, key: key) != nil {
            acceptedRawValue = direct
            colourDisagreementRecovery = false
            scoreSequentialConflictRecovery = false
        } else if (key == .homeScore || key == .awayScore),
                  let displayedScore,
                  let currentScore = Int(displayedScore),
                  let rawNextScore = Int(attempt.rawText),
                  rawNextScore == currentScore + 1,
                  attempt.confidence >= 0.90,
                  attempt.diagnostic.contains("conflict=credible-score-mask-disagreement"),
                  attempt.diagnostic.contains("contrast raw=\(rawNextScore) conf="),
                  !attempt.diagnostic.contains("colour raw=\(rawNextScore) conf="),
                  rawNextScore != 1
                    || attempt.diagnostic.contains("score-narrow-one")
                    || attempt.diagnostic.contains("solid-font-one-shape") {
            // Build 687 golden score rule. A weaker colour mask may retain ghost
            // segments from the previous score while a stronger contrast mask sees
            // the only legal unattended transition: current + 1. Forward that next
            // score as bounded evidence, never as an immediate acceptance. The
            // confidence cap forces two matching service passes and the ViewModel's
            // unattended transition policy still rejects decreases and jumps.
            acceptedRawValue = String(rawNextScore)
            colourDisagreementRecovery = false
            scoreSequentialConflictRecovery = true
        } else if Self.isPenaltyPlayer(key),
                  attempt.confidence >= 0.72,
                  let colourCandidate = validatedRelayVisualValue(attempt.rawText, key: key),
                  attempt.diagnostic.contains("colour raw=\(colourCandidate) conf="),
                  attempt.diagnostic.contains("contrast raw="),
                  !attempt.diagnostic.contains("contrast raw=\(colourCandidate) conf=") {
            // The physical 2026-07-15 run repeatedly produced colour=45 and
            // contrast=46. Retain the colour candidate as evidence only; the
            // rolling resolver still requires repeated matching observations.
            acceptedRawValue = colourCandidate
            colourDisagreementRecovery = true
            scoreSequentialConflictRecovery = false
        } else {
            acceptedRawValue = nil
            colourDisagreementRecovery = false
            scoreSequentialConflictRecovery = false
        }

        let rosterResolution = PenaltyOCRRosterHint.resolve(
            directValue: acceptedRawValue,
            directConfidence: attempt.confidence,
            candidates: attempt.candidates,
            homeRosterNumbers: homeRosterNumbers,
            isHome: key == .homePenalty1Player || key == .homePenalty2Player
        )
        guard let rawValue = rosterResolution.value,
              let value = validatedRelayVisualValue(rawValue, key: key) else {
            return RelayVisualRecognitionResult(
                value: nil,
                confidence: attempt.confidence,
                diagnostic: "ocr-mode-rejected raw=\(attempt.rawText) conf=\(String(format: "%.2f", attempt.confidence)) \(Self.compactDiagnostic(attempt.diagnostic))"
            )
        }

        if Self.isPenaltyPlayer(key) {
            let trust = penaltyPlayerEvidenceTrust(
                diagnostic: attempt.diagnostic,
                candidate: value,
                cropWidth: fieldCrop.width,
                cropHeight: fieldCrop.height
            )
            guard trust.accepted else {
                return RelayVisualRecognitionResult(
                    value: nil,
                    confidence: attempt.confidence,
                    diagnostic: "ocr-mode-player-held value=\(value) reason=\(trust.reason) \(Self.compactDiagnostic(attempt.diagnostic))"
                )
            }
        }

        // Build 680: real Guest 4 reads used the same low-confidence generic
        // route as an earlier false 4. Keep them as sequential evidence instead
        // of discarding the OCR method outright.
        let weakGenericScore = (key == .homeScore || key == .awayScore)
            && (attempt.diagnostic.contains("connected-font-generic")
                || attempt.diagnostic.contains("generic-template"))
            && attempt.confidence < 0.86

        let evidenceConfidence = rosterResolution.source == .homeRosterHint
            ? rosterResolution.confidence
            : attempt.confidence
        let publishedConfidence = scoreSequentialConflictRecovery
            ? min(evidenceConfidence, 0.92)
            : evidenceConfidence
        let rosterDiagnostic = rosterResolution.source == .homeRosterHint
            ? "ocr-mode-home-roster-hint raw=\(attempt.rawText) resolved=\(value) candidates=\(attempt.candidates.map(\.value).joined(separator: ",")) "
            : ""
        return RelayVisualRecognitionResult(
            value: value,
            confidence: publishedConfidence,
            diagnostic: rosterDiagnostic + (scoreSequentialConflictRecovery
                ? "ocr-mode-score-sequential-conflict-candidate=\(value) conf=\(String(format: "%.2f", publishedConfidence)) two-read-confirmation-required \(Self.compactDiagnostic(attempt.diagnostic))"
                : colourDisagreementRecovery
                    ? "ocr-mode-player-colour-disagreement-candidate=\(value) conf=\(String(format: "%.2f", attempt.confidence)) repeated-confirmation-required \(Self.compactDiagnostic(attempt.diagnostic))"
                    : weakGenericScore
                        ? "ocr-mode-low-trust-generic-score=\(value) conf=\(String(format: "%.2f", attempt.confidence)) extended-confirmation-required \(Self.compactDiagnostic(attempt.diagnostic))"
                        : "ocr-mode-candidate=\(value) conf=\(String(format: "%.2f", publishedConfidence)) \(Self.compactDiagnostic(attempt.diagnostic))"),
            requiresExtendedConfirmation: weakGenericScore
        )
    }

    /// Build 619 session baseline and hash observer. The first arbitrary frame is
    /// never accepted as blank. A baseline is established only after three stable
    /// crops that the existing colour/geometry classifier also calls blank.
    private func observePenaltyPlayerHash(
        key: OCRRegionKey,
        crop: CGImage,
        physicalOccupancy: RelayPenaltyPlayerOccupancy,
        geometryChanged: Bool
    ) -> RelayPenaltyPlayerHashObservation {
        guard let currentHash = Self.penaltyPlayerPerceptualHash(from: crop) else {
            return RelayPenaltyPlayerHashObservation(
                hash: nil,
                previousOccupiedHash: nil,
                previousStableIdentityHash: nil,
                occupancy: .unknown("perceptual-hash-failed"),
                materialChange: false,
                distanceFromPrevious: nil,
                distanceFromBlank: nil,
                baselineReady: false,
                stableOccupiedCount: 0,
                stableBlankCount: 0,
                startedFromStableBlank: false,
                stableIdentityHash: nil,
                frozenCandidateReady: false,
                frozenOCRAttempt: 0,
                diagnostic: "hash-failed"
            )
        }

        let now = CFAbsoluteTimeGetCurrent()
        recognitionLock.lock()
        defer { recognitionLock.unlock() }

        var state = penaltyPlayerHashStates[key] ?? RelayPenaltyPlayerHashState()
        let previousStableIdentityHash = geometryChanged ? nil : state.frozenCandidateHash
        if geometryChanged {
            state = RelayPenaltyPlayerHashState()
            penaltyPlayerFrozenRecognitionCrops.removeValue(forKey: key)
            state.lastDecision = "geometry-changed-hash-reset"
        }

        let previousOccupiedHash: UInt64?
        if now - state.lastOccupiedObservedAt <= 4.0 {
            previousOccupiedHash = state.lastOccupiedHash
        } else {
            previousOccupiedHash = nil
        }

        let distanceFromPrevious = state.previousHash.map {
            Self.hammingDistance(currentHash, $0)
        }
        var distanceFromBlank = state.blankBaselineHash.map {
            Self.hammingDistance(currentHash, $0)
        }
        let physicalDiagnostic = physicalOccupancy.diagnostic
        let trustedPhysicalGlyph = physicalOccupancy.isConfirmedOccupied
            && !physicalDiagnostic.contains("zoneAudit=reject")
            && physicalDiagnostic.contains("signalTrust=strong")
        var effectiveOccupancy: RelayPenaltyPlayerOccupancy
        if physicalOccupancy.isConfirmedOccupied, !trustedPhysicalGlyph {
            effectiveOccupancy = .unknown(
                "untrusted-player-geometry-held; \(physicalDiagnostic)"
            )
        } else {
            effectiveOccupancy = physicalOccupancy
        }
        var baselineDecision = "baseline=missing"

        if let baseline = state.blankBaselineHash {
            let distance = Self.hammingDistance(currentHash, baseline)
            distanceFromBlank = distance
            baselineDecision = "baselineDistance=\(distance)"
            if trustedPhysicalGlyph {
                // A trusted tall digit is stronger evidence than the low-resolution
                // perceptual hash. On this board an illuminated 45 can be only 4-6
                // hash bits away from the dash/dot blank pattern. Over-wide box
                // edges and labels never receive this override.
                effectiveOccupancy = physicalOccupancy
                baselineDecision += " trusted-glyph-overrides-blank-baseline"
            } else if distance <= 6 {
                effectiveOccupancy = .blank("blank-baseline-match distance=\(distance)")
            } else if !physicalOccupancy.isConfirmedOccupied, distance >= 12 {
                effectiveOccupancy = .occupied("blank-baseline-different distance=\(distance); \(physicalOccupancy.diagnostic)")
            }
        } else if physicalOccupancy.isConfirmedBlank {
            if let candidate = state.blankCandidateHash,
               Self.hammingDistance(currentHash, candidate) <= 4 {
                state.blankCandidateCount += 1
            } else {
                state.blankCandidateHash = currentHash
                state.blankCandidateCount = 1
            }
            baselineDecision = "baselineLearning=\(state.blankCandidateCount)/3"
            if state.blankCandidateCount >= 3 {
                state.blankBaselineHash = currentHash
                state.blankCandidateHash = nil
                state.blankCandidateCount = 0
                distanceFromBlank = 0
                baselineDecision = "baseline=established"
            }
        } else {
            // Starting during an active penalty must never teach that number as blank.
            state.blankCandidateHash = nil
            state.blankCandidateCount = 0
        }

        // Build 687 baseline-aware multiplex protection. One isolated dark LED
        // scan is still held, but a sustained crop matching the learned blank
        // baseline clears promptly. This replaces the fixed 12-second hold that
        // delayed power-play penalty removal and full-strength state.
        let strongBlankBaselineMatch = distanceFromBlank.map { $0 <= 4 } ?? false
        let occupiedHoldSeconds: CFTimeInterval = strongBlankBaselineMatch ? 0.90 : 2.40
        let blankClearConfirmationCount = 2
        let hadOccupiedEvidence = state.occupiedCandidateCount > 0 || state.frozenCandidateHash != nil
        if effectiveOccupancy.isConfirmedBlank, hadOccupiedEvidence {
            let occupiedAge = now - state.lastOccupiedObservedAt
            if occupiedAge <= occupiedHoldSeconds {
                state.blankClearCandidateCount = 0
                effectiveOccupancy = .unknown(
                    "multiplex-dark-frame-held age=\(String(format: "%.2f", occupiedAge))s baselineMatch=\(strongBlankBaselineMatch ? "yes" : "no")"
                )
            } else {
                state.blankClearCandidateCount += 1
                if state.blankClearCandidateCount < blankClearConfirmationCount {
                    effectiveOccupancy = .unknown(
                        "blank-clear-pending \(state.blankClearCandidateCount)/\(blankClearConfirmationCount) age=\(String(format: "%.2f", occupiedAge))s baselineMatch=\(strongBlankBaselineMatch ? "yes" : "no")"
                    )
                }
            }
        }

        let currentMetadata = effectiveOccupancy.metadataState
        let occupancyTransition = state.previousOccupancy != .unresolved
            && currentMetadata != .unresolved
            && state.previousOccupancy != currentMetadata
        let materialChange = !geometryChanged && (
            (distanceFromPrevious ?? 0) >= 10 || occupancyTransition
        )

        var frozenCandidateReady = false
        var frozenOCRAttempt = 0
        let previousStableBlankCount = state.stableBlankCount
        if effectiveOccupancy.isConfirmedOccupied {
            state.stableBlankCount = 0
            state.blankClearCandidateCount = 0
            state.lastOccupiedHash = currentHash
            state.lastOccupiedObservedAt = now

            // Build 650: two occupied observations activate the physical slot even
            // when multiplexing changes the perceptual hash. The hash is diagnostic
            // only; it cannot reset viewer visibility, lifecycle creation or popups.
            if state.occupiedCandidateCount == 0 {
                state.occupiedCandidateStartedFromStableBlank =
                    state.previousOccupancy == .confirmedBlank && previousStableBlankCount >= 3
                state.frozenCandidateHash = currentHash
                state.frozenOCRAttemptCount = 0
                state.frozenOCRStartedAt = now
                penaltyPlayerFrozenRecognitionCrops[key] = crop
            }
            state.occupiedCandidateHash = currentHash
            state.occupiedCandidateCount = min(3, state.occupiedCandidateCount + 1)

            if state.occupiedCandidateCount >= 2 {
                if state.frozenOCRAttemptCount < 3,
                   now - state.frozenOCRStartedAt <= 2.5 {
                    state.frozenOCRAttemptCount += 1
                    frozenCandidateReady = true
                    frozenOCRAttempt = state.frozenOCRAttemptCount
                }
            }
        } else if effectiveOccupancy.isConfirmedBlank {
            // The blank has already survived the multiplex hold and repeated-clear
            // gate above, so expose it as immediately stable to all consumers.
            state.stableBlankCount = max(3, state.stableBlankCount + 1)
            state.blankClearCandidateCount = 0
            state.occupiedCandidateHash = nil
            state.occupiedCandidateCount = 0
            state.occupiedCandidateStartedFromStableBlank = false
            state.frozenCandidateHash = nil
            state.frozenOCRAttemptCount = 0
            state.frozenOCRStartedAt = 0
            penaltyPlayerFrozenRecognitionCrops.removeValue(forKey: key)
        } else if !hadOccupiedEvidence {
            state.stableBlankCount = 0
        }

        state.previousHash = currentHash
        state.previousOccupancy = currentMetadata
        state.lastDecision = "\(baselineDecision) previousDistance=\(distanceFromPrevious.map { String($0) } ?? "none") occupancy=\(currentMetadata.rawValue) material=\(materialChange ? "yes" : "no") stableOccupied=\(state.occupiedCandidateCount) stableBlank=\(state.stableBlankCount) startedFromBlank=\(state.occupiedCandidateStartedFromStableBlank ? "yes" : "no") frozenOCR=\(frozenCandidateReady ? String(frozenOCRAttempt) : "no")"
        penaltyPlayerHashStates[key] = state

        return RelayPenaltyPlayerHashObservation(
            hash: currentHash,
            previousOccupiedHash: previousOccupiedHash,
            previousStableIdentityHash: previousStableIdentityHash,
            occupancy: effectiveOccupancy,
            materialChange: materialChange,
            distanceFromPrevious: distanceFromPrevious,
            distanceFromBlank: distanceFromBlank,
            baselineReady: state.blankBaselineHash != nil,
            stableOccupiedCount: state.occupiedCandidateCount,
            stableBlankCount: state.stableBlankCount,
            startedFromStableBlank: state.occupiedCandidateStartedFromStableBlank,
            stableIdentityHash: state.occupiedCandidateCount >= 2 ? state.frozenCandidateHash : nil,
            frozenCandidateReady: frozenCandidateReady,
            frozenOCRAttempt: frozenOCRAttempt,
            diagnostic: state.lastDecision
        )
    }

    /// Records only changes into/out of the ambient-light rejection state. This is
    /// diagnostic evidence, not a second occupancy owner.
    private func recordPenaltyAmbientLightRejectionTransition(
        key: OCRRegionKey,
        occupancy: RelayPenaltyPlayerOccupancy,
        captureGeneration: Int
    ) {
        let rejected = occupancy.diagnostic.contains("ambient-light-rejected")
        penaltyAmbientLightLogLock.lock()
        let wasRejected = penaltyAmbientLightRejectedKeys.contains(key)
        if rejected { penaltyAmbientLightRejectedKeys.insert(key) }
        else { penaltyAmbientLightRejectedKeys.remove(key) }
        penaltyAmbientLightLogLock.unlock()
        guard rejected != wasRejected else { return }
        RinkLensStructuredEventLogger.shared.record(
            domain: .penalty,
            event: "penalty_ambient_light_rejection_changed",
            entityID: key.rawValue,
            previous: ["rejected": wasRejected ? "true" : "false"],
            next: [
                "rejected": rejected ? "true" : "false",
                "classification": occupancy.metadataState.rawValue
            ],
            source: "ScoreboardImageRelay.penaltyPlayerOccupancy",
            reason: occupancy.diagnostic,
            captureGeneration: captureGeneration,
            authoritativeOwner: "ScoreboardImageRelay"
        )
    }

    /// Normalised 9x8 difference hash. It is intentionally independent of OCR and
    /// resilient to small exposure shifts, crop-size changes and camera grain.
    private static func penaltyPlayerPerceptualHash(from image: CGImage) -> UInt64? {
        let width = 9
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return false }
            context.interpolationQuality = .low
            context.setShouldAntialias(false)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }

        var hash: UInt64 = 0
        var bit: UInt64 = 1
        for y in 0..<height {
            let row = y * width
            for x in 0..<(width - 1) {
                if pixels[row + x] > pixels[row + x + 1] {
                    hash |= bit
                }
                bit <<= 1
            }
        }
        return hash
    }

    private nonisolated static func hammingDistance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }

    /// Build 625 viewer-facing penalty-player image. Only a tall digit-shaped
    /// glyph is publishable. Scoreboard placeholder dashes/dots return nil, so an
    /// unused penalty row is transparent instead of relaying the placeholder cell.
    /// The detected glyph bounds, not the full Calibration crop, own display scale.
    private static func penaltyPlayerRelayImage(
        from crop: CGImage,
        key: OCRRegionKey,
        colourProfile: OCRZoneColourProfile
    ) -> CGImage? {
        let outcome = extractIlluminatedGlyphs(
            from: crop,
            key: key,
            colourProfile: colourProfile
        )
        guard let glyph = outcome.glyph?.image else { return nil }
        // Build 650 fixes the output canvas so measured character height remains
        // identical even when multiplexing changes the detected character width.
        // The operator's calibrated box controls position; the normaliser controls
        // one consistent visible height without per-frame width breathing.
        return normalisedMeasuredDisplayImage(
            glyph,
            canvasHeight: 90,
            horizontalSafetyFraction: 0.035,
            minimumCanvasAspect: 1.60
        )?.image ?? glyph
    }

    /// Uses the existing colour-aware illuminated-glyph extraction only as a
    /// physical occupancy check. It does not recognise or publish a player number.
    /// Processing failures are unknown and therefore cannot clear a slot.
    private static func penaltyPlayerOccupancy(
        from crop: CGImage,
        key: OCRRegionKey,
        colourProfile: OCRZoneColourProfile
    ) -> RelayPenaltyPlayerOccupancy {
        let outcome = extractIlluminatedGlyphs(
            from: crop,
            key: key,
            colourProfile: colourProfile
        )
        if outcome.glyph != nil {
            let diagnostic = outcome.diagnostic
            // Build 621 rejects the native-glyph full-crop fallback as occupancy
            // evidence. Build 619 treated bounds==source as a 100%-high digit and
            // therefore classified every genuinely blank slot as occupied.
            let pattern =
                #"active=([0-9.]+)% strong=([0-9.]+)% src=(\d+)x(\d+) bounds=(\d+)x(\d+)(?:\+(\d+),(\d+))?"#
            if let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(
                in: diagnostic,
                range: NSRange(diagnostic.startIndex..<diagnostic.endIndex, in: diagnostic)
               ),
                match.numberOfRanges >= 7,
                let activeRange = Range(match.range(at: 1), in: diagnostic),
               let strongRange = Range(match.range(at: 2), in: diagnostic),
               let sourceWidthRange = Range(match.range(at: 3), in: diagnostic),
               let sourceHeightRange = Range(match.range(at: 4), in: diagnostic),
               let boundsWidthRange = Range(match.range(at: 5), in: diagnostic),
               let boundsHeightRange = Range(match.range(at: 6), in: diagnostic),
               let activePercent = Double(diagnostic[activeRange]),
               let strongPercent = Double(diagnostic[strongRange]),
               let sourceWidth = Double(diagnostic[sourceWidthRange]),
               let sourceHeight = Double(diagnostic[sourceHeightRange]),
               let boundsWidth = Double(diagnostic[boundsWidthRange]),
               let boundsHeight = Double(diagnostic[boundsHeightRange]),
               sourceWidth > 0, sourceHeight > 0 {
                let widthFraction = boundsWidth / sourceWidth
                let heightFraction = boundsHeight / sourceHeight
                let boundsX: Double? = {
                    guard match.numberOfRanges > 7, match.range(at: 7).location != NSNotFound,
                        let range = Range(match.range(at: 7), in: diagnostic)
                    else { return nil }
                    return Double(diagnostic[range])
                }()
                let boundsY: Double? = {
                    guard match.numberOfRanges > 8, match.range(at: 8).location != NSNotFound,
                        let range = Range(match.range(at: 8), in: diagnostic)
                    else { return nil }
                    return Double(diagnostic[range])
                }()
                let centreX = boundsX.map { ($0 + boundsWidth / 2) / sourceWidth }
                let centreY = boundsY.map { ($0 + boundsHeight / 2) / sourceHeight }
                let borderContact =
                    (boundsX.map { $0 <= 1 || $0 + boundsWidth >= sourceWidth - 1 } ?? false)
                    || (boundsY.map { $0 <= 1 || $0 + boundsHeight >= sourceHeight - 1 } ?? false)
                let zoneAudit: String = {
                    var warnings: [String] = []
                    if widthFraction > 0.82 { warnings.append("overwide") }
                    if heightFraction < 0.31 { warnings.append("undersized") }
                    if borderContact { warnings.append("border-contact") }
                    if let centreX, !(0.12...0.88).contains(centreX) { warnings.append("horizontal-edge") }
                    if let centreY, !(0.08...0.92).contains(centreY) { warnings.append("vertical-edge") }
                    return warnings.isEmpty
                        ? "zoneAudit=pass" : "zoneAudit=warn[\(warnings.joined(separator: ","))]"
                }()
                let maximumAlpha: Double = {
                    let alphaPattern = #"aMax=(\d+)"#
                    guard let alphaRegex = try? NSRegularExpression(pattern: alphaPattern),
                          let alphaMatch = alphaRegex.firstMatch(
                            in: diagnostic,
                            range: NSRange(diagnostic.startIndex..<diagnostic.endIndex, in: diagnostic)
                          ),
                          alphaMatch.numberOfRanges >= 2,
                          let range = Range(alphaMatch.range(at: 1), in: diagnostic),
                          let value = Double(diagnostic[range]) else { return 0 }
                    return value
                }()
                let strongToActiveRatio = strongPercent / max(0.1, activePercent)
                let fractions = String(
                    format:
                        "widthFraction=%.2f heightFraction=%.2f centre=%.2f,%.2f active=%.1f%% strong=%.1f%% aMax=%.0f strongActiveRatio=%.3f %@",
                    widthFraction,
                    heightFraction,
                    centreX ?? -1,
                    centreY ?? -1,
                    activePercent,
                    strongPercent,
                    maximumAlpha,
                    strongToActiveRatio,
                    zoneAudit
                )

                let signalEvidence = RinkLensPenaltyPlayerSignalEvidence(
                    activePercent: activePercent,
                    strongPercent: strongPercent,
                    maximumAlpha: maximumAlpha,
                    widthFraction: widthFraction,
                    heightFraction: heightFraction,
                    geometryRejected: widthFraction >= 0.94 && heightFraction >= 0.94
                )
                switch RinkLensPenaltyPlayerSignalTrustPolicy.decision(for: signalEvidence) {
                case .rejectAmbient:
                    return .unknown("ambient-light-rejected \(diagnostic) \(fractions) signalTrust=ambient-rejected")
                case .trustedOccupied:
                    return .occupied("\(diagnostic) \(fractions) densityGate=occupied signalTrust=strong")
                case .holdUnresolved:
                    break
                }

                if signalEvidence.geometryRejected {
                    // The full-crop fallback is never valid glyph evidence. A very
                    // low strong-pixel result is, however, a useful raw blank signal
                    // and still requires the normal ten-frame baseline proof.
                    if strongPercent <= 4.5 {
                        return .blank(
                            "full-crop-fallback-raw-blank \(diagnostic) \(fractions)"
                        )
                    }
                    return .unknown(
                        "full-crop-segmentation-invalid \(diagnostic) \(fractions)"
                    )
                }

                // Build 650: the calibrated player box is the geometry authority.
                // Height alone is not enough: the latest logs showed empty scan/noise
                // fragments reaching 37-45% height with only 0.1-1.2% strong pixels.
                // Genuine player digits were 20-38% active and 14-33% strong.
                // Use that clear signal-density separation and never require OCR,
                // position matching or a repeated perceptual hash.
                let weakEmptySignal =
                    RinkLensPenaltyPlayerBlankEvidencePolicy.acceptsStablePlaceholderSignal(
                        activePercent: activePercent,
                        strongPercent: strongPercent
                    )
                if heightFraction >= 0.36, activePercent >= 12.0 {
                    return .unknown("ambient-contrast-insufficient \(diagnostic) \(fractions) densityGate=hold")
                }
                if weakEmptySignal {
                    return .blank("weak-empty-player-signal \(diagnostic) \(fractions) densityGate=blank")
                }
                return .unknown("uncertain-player-signal \(diagnostic) \(fractions) densityGate=hold")
            }
            return .unknown("unmeasured-player-signal \(diagnostic)")
        }

        let diagnostic = outcome.diagnostic
        let confirmedBlankPrefixes = [
            "no-illuminated-signal",
            "no-content-after-frame-removal",
            "blank-player-horizontal-only",
            "blank-player-placeholder-only",
            "no-tall-glyph"
        ]
        if confirmedBlankPrefixes.contains(where: { diagnostic.hasPrefix($0) }) {
            return .blank(diagnostic)
        }
        if diagnostic.hasPrefix("normalized-glyph-too-weak") {
            let pattern = #"aMax=(\d+) active=(\d+) strong=(\d+)"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(
                   in: diagnostic,
                   range: NSRange(diagnostic.startIndex..<diagnostic.endIndex, in: diagnostic)
               ),
               match.numberOfRanges == 4,
               let alphaRange = Range(match.range(at: 1), in: diagnostic),
               let activeRange = Range(match.range(at: 2), in: diagnostic),
               let strongRange = Range(match.range(at: 3), in: diagnostic),
               let maximumAlpha = Int(diagnostic[alphaRange]),
               let activePixels = Int(diagnostic[activeRange]),
               let strongPixels = Int(diagnostic[strongRange]),
               RinkLensPenaltyPlayerBlankEvidencePolicy.acceptsNearZeroSignal(
                   maximumAlpha: maximumAlpha,
                   activePixelCount: activePixels,
                   strongPixelCount: strongPixels
               ) {
                return .blank("near-zero-player-signal \(diagnostic)")
            }
        }
        return .unknown(diagnostic)
    }

    private static func nonBlankRejectedPlayerRaw(in diagnostic: String) -> Bool {
        let marker = "ocr-mode-rejected raw="
        guard let range = diagnostic.range(of: marker) else { return false }
        let suffix = diagnostic[range.upperBound...]
        let raw = suffix.prefix { !$0.isWhitespace }
        guard !raw.isEmpty else { return false }
        let value = String(raw)
        return value != "<blank>" && value != "--" && value != "nil"
    }

    private static func penaltyPlayerEvidenceTrust(
        diagnostic: String,
        candidate: String,
        cropWidth: Int,
        cropHeight: Int
    ) -> (accepted: Bool, reason: String) {
        let colourAndContrast = diagnostic.contains("dynamic-token accepted source=colour+contrast")
        let colourOnly = diagnostic.contains("dynamic-token accepted source=colour ")
            || diagnostic.contains("dynamic-token accepted source=colour elapsed")
        let persistentColourDisagreement = diagnostic.contains("dynamic-token rejected")
            && diagnostic.contains("colour raw=\(candidate) conf=")
            && diagnostic.contains("contrast raw=")
            && !diagnostic.contains("contrast raw=\(candidate) conf=")
        guard colourAndContrast || colourOnly || persistentColourDisagreement else {
            return (false, "contrast-only-or-unknown-source")
        }

        let colourTokens = diagnostic
            .components(separatedBy: " ; ")
            .filter { component in
                component.contains("source=colour token=")
                    && !component.contains("token=none")
                    && !component.contains("char=?")
            }
        guard !colourTokens.isEmpty else {
            return (false, "no-colour-digit-token")
        }

        let pattern = #"bounds=(\d+),(\d+) (\d+)x(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (false, "bounds-parser-unavailable")
        }

        var maximumTokenHeight = 0
        var touchesHorizontalBoundary = false
        var touchesVerticalBoundary = false
        var parsed = 0
        for token in colourTokens {
            let range = NSRange(token.startIndex..<token.endIndex, in: token)
            guard let match = regex.firstMatch(in: token, range: range), match.numberOfRanges == 5 else {
                continue
            }
            func integer(_ index: Int) -> Int? {
                guard let swiftRange = Range(match.range(at: index), in: token) else { return nil }
                return Int(token[swiftRange])
            }
            guard let x = integer(1), let y = integer(2),
                  let width = integer(3), let height = integer(4) else { continue }
            parsed += 1
            maximumTokenHeight = max(maximumTokenHeight, height)
            let maxX = x + width
            let maxY = y + height
            if x <= 1 || maxX >= cropWidth - 1 {
                touchesHorizontalBoundary = true
            }
            if y <= 0 || maxY >= cropHeight - 1 {
                touchesVerticalBoundary = true
            }
        }

        guard parsed > 0 else { return (false, "no-parseable-colour-bounds") }
        let minimumHeight = max(10, Int((Double(cropHeight) * 0.28).rounded(.up)))
        guard maximumTokenHeight >= minimumHeight else {
            return (false, "colour-token-too-small height=\(maximumTokenHeight)<\(minimumHeight)")
        }

        // Build 598 permits a complete two-digit colour read to touch a horizontal
        // board boundary after the crop has already been safety-expanded. Single
        // edge fragments and vertical-boundary artefacts remain rejected.
        if touchesHorizontalBoundary || touchesVerticalBoundary {
            let completeEdgeSafePair = candidate.count == 2
                && parsed >= 2
                && !touchesVerticalBoundary
                && maximumTokenHeight >= max(minimumHeight, Int(Double(cropHeight) * 0.34))
            guard completeEdgeSafePair else {
                return (false, "colour-token-touches-zone-boundary")
            }
            return (true, "trusted-colour-geometry-edge-safe-pair")
        }
        return (true, "trusted-colour-geometry")
    }

    private static func validatedRelayVisualValue(_ raw: String, key: OCRRegionKey) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.allSatisfy({ $0.isNumber }),
              let number = Int(trimmed) else { return nil }
        switch key {
        case .homeScore, .awayScore,
             .homePenalty1Player, .homePenalty2Player,
             .awayPenalty1Player, .awayPenalty2Player:
            guard (0...99).contains(number) else { return nil }
        case .period:
            guard (1...9).contains(number) else { return nil }
        default:
            return nil
        }
        return String(number)
    }

    /// Initial strong reads publish immediately. A lower-confidence initial read
    /// or a lower-confidence change needs two matching service passes. Very strong
    /// changes can publish on the first pass so a clear goal does not wait four
    /// seconds at the configured 2-second score cadence.
    private func resolveRelayVisualValue(
        key: OCRRegionKey,
        candidate: String?,
        confidence: Float,
        parserDiagnostic: String,
        physicalHash: UInt64?,
        requiresExtendedConfirmation: Bool = false
    ) -> (value: String?, diagnostic: String) {
        recognitionLock.lock()
        defer { recognitionLock.unlock() }

        var state = recognitionStates[key] ?? RelayVisualRecognitionState()
        if (key == .homeScore || key == .awayScore),
           state.confirmedValue == nil,
           let displayed = ScoreboardImageRelayStore.shared.snapshot().visualValue(for: key),
           Self.validatedRelayVisualValue(displayed, key: key) != nil {
            state.confirmedValue = displayed
            state.lastDecision = "score-baseline-seeded-from-clean-display=\(displayed)"
        }
        let previousPhysicalHash = state.lastPhysicalHash
        let physicalChanged: Bool
        if let previousPhysicalHash, let physicalHash {
            physicalChanged = Self.hammingDistance(previousPhysicalHash, physicalHash) >= 4
        } else {
            physicalChanged = false
        }
        if let physicalHash { state.lastPhysicalHash = physicalHash }

        let initialThreshold: Float = key == .period ? 0.80 : 0.82
        let immediateChangeThreshold: Float = key == .period ? 0.94 : 0.93

        guard let candidate else {
            state.lastConfidence = confidence
            if key == .homeScore || key == .awayScore {
                if let confirmed = state.confirmedValue {
                    // Build 662: a transient colour/contrast disagreement must not
                    // replace a trusted score such as 0 with the raw physical crop.
                    // That fallback made a zero appear as a hollow/donut glyph.
                    // Hold the accepted text until a new numeric score is confirmed.
                    state.lastDecision = "score-text-held parser-miss physicalChanged=\(physicalChanged) confirmed=\(confirmed)"
                    recognitionStates[key] = state
                    return (confirmed, "\(state.lastDecision) \(Self.compactDiagnostic(parserDiagnostic))")
                }
                state.lastDecision = "score-image-fallback no-confirmed-baseline physicalChanged=\(physicalChanged)"
                recognitionStates[key] = state
                return (nil, "\(state.lastDecision) \(Self.compactDiagnostic(parserDiagnostic))")
            }
            state.lastDecision = state.confirmedValue.map { "held=\($0) parser-miss" } ?? "no-baseline parser-miss"
            recognitionStates[key] = state
            return (state.confirmedValue, "\(state.lastDecision) \(Self.compactDiagnostic(parserDiagnostic))")
        }

        if candidate == state.confirmedValue {
            state.pendingValue = nil
            state.pendingCount = 0
            state.lastConfidence = confidence
            state.lastDecision = "confirmed=\(candidate) unchanged"
            recognitionStates[key] = state
            return (candidate, "\(state.lastDecision) conf=\(String(format: "%.2f", confidence))")
        }

        if key == .homeScore || key == .awayScore,
           ScoreboardImageRelayStore.shared.snapshot().visualValue(for: key) == candidate {
            let previous = state.confirmedValue ?? "--"
            state.confirmedValue = candidate
            state.pendingValue = nil
            state.pendingCount = 0
            state.lastConfidence = confidence
            state.lastDecision = "viewmodel-accepted=\(previous)->\(candidate)"
            recognitionStates[key] = state
            return (candidate, "\(state.lastDecision) conf=\(String(format: "%.2f", confidence))")
        }

        if key == .homeScore || key == .awayScore,
           let incoming = Int(candidate) {
            let current = state.confirmedValue.flatMap { Int($0) }
            let transition = RinkLensUnattendedScoreTransitionPolicy.evaluate(
                current: current,
                candidate: incoming
            )
            if !transition.isAllowed {
                state.pendingValue = nil
                state.pendingCount = 0
                state.lastConfidence = confidence
                state.lastDecision = "score-text-held previous=\(state.confirmedValue ?? "empty") rejected=\(candidate) reason=\(transition.reason)"
                recognitionStates[key] = state
                return (state.confirmedValue, "\(state.lastDecision) conf=\(String(format: "%.2f", confidence))")
            }
        }

        if state.confirmedValue == nil, confidence >= initialThreshold, key == .period {
            state.confirmedValue = candidate
            state.pendingValue = nil
            state.pendingCount = 0
            state.lastConfidence = confidence
            state.lastDecision = "initial-accepted=\(candidate)"
            recognitionStates[key] = state
            return (candidate, "\(state.lastDecision) conf=\(String(format: "%.2f", confidence))")
        }

        if state.confirmedValue != nil, confidence >= immediateChangeThreshold {
            let previous = state.confirmedValue ?? "--"
            state.confirmedValue = candidate
            state.pendingValue = nil
            state.pendingCount = 0
            state.lastConfidence = confidence
            state.lastDecision = "strong-change=\(previous)->\(candidate)"
            recognitionStates[key] = state
            return (candidate, "\(state.lastDecision) conf=\(String(format: "%.2f", confidence))")
        }

        if state.pendingValue == candidate {
            state.pendingCount += 1
        } else {
            state.pendingValue = candidate
            state.pendingCount = 1
        }
        state.lastConfidence = confidence

        let requiredMatches = requiresExtendedConfirmation ? 3 : 2
        if state.pendingCount >= requiredMatches {
            let previous = state.confirmedValue ?? "--"
            state.confirmedValue = candidate
            state.pendingValue = nil
            state.pendingCount = 0
            state.lastDecision = requiresExtendedConfirmation
                ? "three-read-low-trust=\(previous)->\(candidate)"
                : "two-read=\(previous)->\(candidate)"
            recognitionStates[key] = state
            return (candidate, "\(state.lastDecision) conf=\(String(format: "%.2f", confidence))")
        }

        state.lastDecision = "pending=\(candidate) count=\(state.pendingCount)/\(requiredMatches) held=\(state.confirmedValue ?? "none")"
        recognitionStates[key] = state
        if key == .homeScore || key == .awayScore {
            return (
                state.confirmedValue,
                "score-text-held \(state.lastDecision) conf=\(String(format: "%.2f", confidence)) \(Self.compactDiagnostic(parserDiagnostic))"
            )
        }
        return (
            state.confirmedValue,
            "\(state.lastDecision) conf=\(String(format: "%.2f", confidence)) \(Self.compactDiagnostic(parserDiagnostic))"
        )
    }

    private static func cleanRelayValueHash(value: String, key: OCRRegionKey) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in "build580-ocr-text-\(key.rawValue)-\(value)".utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private static func compactDiagnostic(_ value: String, limit: Int = 180) -> String {
        let compact = value.replacingOccurrences(of: "\n", with: " ")
        guard compact.count > limit else { return compact }
        return String(compact.prefix(limit)) + "…"
    }

    /// Build 614 route/manual suspension boundary. Camera work and Clock
    /// movement evidence are reset, but confirmed penalty-player identities stay
    /// intact so Command Centre, Calibration and Broadcast navigation cannot turn
    /// a capture hand-off into four penalty removals and four duplicate starts.
    func suspendPreservingPenaltyState(reason: String) {
        lock.lock()
        clockBusy = false
        scoreBusy = false
        periodBusy = false
        penaltyPlayerBusy = false
        penaltyTimerBusy = false
        clockRerunPending = false
        pendingClockRequest = nil
        nextClockDeadline = 0
        penaltyPlayerRerunPending = false
        penaltyTimerRerunPending = false
        lastClockSubmittedAt = 0
        lastScoreSubmittedAt = 0
        lastPeriodSubmittedAt = 0
        lastPenaltyPlayerSubmittedAt = 0
        lastPenaltyTimerSubmittedAt = 0
        unacceptedPenaltyTimerDiscoveryCursor = 0
        penaltyTimerConsecutiveMisses.removeAll(keepingCapacity: true)
        // Build 661 keeps visual geometry through route-only suspension. If the
        // physical capture graph changes, the accepted capture-generation check in
        // the next frame performs a retained-image reacquisition instead.
        // Preserve the last confirmed running/stopped state across route and
        // capture-generation hand-offs. Reset only frame-comparison evidence.
        // This prevents one physical stoppage being fragmented into several IDs
        // and prevents the first recovered frame from becoming a false restart.
        var preservedClockState = clockMovementState
        preservedClockState.previousSignature = nil
        preservedClockState.stableSamples = 0
        preservedClockState.movingSamples = 0
        preservedClockState.movingRunStartedAt = nil
        preservedClockState.stableRunStartedAt = nil
        preservedClockState.stableRunObservedAt = nil
        preservedClockState.stableRunClockImage = nil
        preservedClockState.stableRunSignature = nil
        preservedClockState.lastDecision = "capture-suspended-comparison-reset-state-preserved"
        clockMovementState = preservedClockState
        lock.unlock()
        recognitionLock.lock()
        for key in penaltyPlayerHashStates.keys {
            var hashState = penaltyPlayerHashStates[key] ?? RelayPenaltyPlayerHashState()
            // Build 663 keeps the confirmed physical occupancy and stable identity
            // through Broadcast/OCR navigation. Only the immediately previous frame
            // comparison is invalid across a new capture generation. A real clear
            // must still be proved by the normal five fresh blank observations.
            hashState.previousHash = nil
            hashState.blankClearCandidateCount = 0
            hashState.lastDecision = "capture-suspended-comparison-reset-occupancy-preserved"
            penaltyPlayerHashStates[key] = hashState
        }
        recognitionLock.unlock()
        // recognitionStates and verified blank baselines deliberately retained.
        RinkLensOCREvidenceJournal.shared.recordEventAudit(
            stage: "image_relay_suspended_preserving_penalties",
            eventKind: "capture",
            source: "image-relay",
            detail: reason
        )
    }

    func reset(reason: String) {
        lock.lock()
        clockBusy = false
        scoreBusy = false
        periodBusy = false
        penaltyPlayerBusy = false
        penaltyTimerBusy = false
        clockRerunPending = false
        pendingClockRequest = nil
        nextClockDeadline = 0
        penaltyPlayerRerunPending = false
        penaltyTimerRerunPending = false
        lastClockSubmittedAt = 0
        lastScoreSubmittedAt = 0
        lastPeriodSubmittedAt = 0
        lastPenaltyPlayerSubmittedAt = 0
        lastPenaltyTimerSubmittedAt = 0
        unacceptedPenaltyTimerDiscoveryCursor = 0
        penaltyTimerConsecutiveMisses.removeAll(keepingCapacity: true)
        lastPenaltyTimerLoggedPublicationHash.removeAll(keepingCapacity: true)
        lastPenaltyTimerPublishedAt.removeAll(keepingCapacity: true)
        clockMovementState = RelayClockMovementState()
        lock.unlock()
        clockGeometryLock.lock()
        clockGeometryState = nil
        clockGeometryLock.unlock()
        recognitionLock.lock()
        recognitionStates.removeAll(keepingCapacity: true)
        penaltyPlayerHashStates.removeAll(keepingCapacity: true)
        penaltyPlayerFrozenRecognitionCrops.removeAll(keepingCapacity: true)
        penaltyPairSignalStates.removeAll(keepingCapacity: true)
        recognitionLock.unlock()
        penaltyAmbientLightLogLock.lock()
        penaltyAmbientLightRejectedKeys.removeAll(keepingCapacity: true)
        penaltyAmbientLightLogLock.unlock()
        penaltyVisualLock.lock()
        penaltyVisualStates.removeAll(keepingCapacity: true)
        nextPenaltyVisualActivationID = 0
        penaltyVisualLock.unlock()
        ScoreboardImageRelayStore.shared.clear(reason: reason)
    }

    var diagnosticText: String {
        lock.lock()
        recognitionLock.lock()
        let recognitionText = recognitionStates.keys.sorted { $0.rawValue < $1.rawValue }.map { key in
            let state = recognitionStates[key] ?? RelayVisualRecognitionState()
            return "\(key.rawValue)=\(state.lastDecision)@\(String(format: "%.2f", state.lastConfidence))"
        }.joined(separator: ",")
        let playerHashText = penaltyPlayerHashStates.keys.sorted { $0.rawValue < $1.rawValue }.map { key in
            let state = penaltyPlayerHashStates[key] ?? RelayPenaltyPlayerHashState()
            return "\(key.rawValue)=\(state.lastDecision)"
        }.joined(separator: ",")
        recognitionLock.unlock()
        penaltyVisualLock.lock()
        let penaltyVisualText = penaltyVisualStates.keys.sorted { $0.rawValue < $1.rawValue }.map { key in
            let state = penaltyVisualStates[key]!
            let rect = state.lockedTimerRect.map {
                "\(Int($0.width.rounded()))x\(Int($0.height.rounded()))+\(Int($0.minX.rounded())),\(Int($0.minY.rounded()))"
            } ?? "pending"
            return "\(key.rawValue)=activation:\(state.activationID) phase:\(state.phase.rawValue) timer:\(rect) shrinkHeld:\(state.rejectedShrinkCount) expand:\(state.acceptedExpansionCount) decision:\(state.lastDecision)"
        }.joined(separator: ",")
        penaltyVisualLock.unlock()
        let timerPresentationText = lastPenaltyTimerPresentationDiagnostics.keys
            .sorted { $0.rawValue < $1.rawValue }
            .map { key in "\(key.rawValue)=\(lastPenaltyTimerPresentationDiagnostics[key] ?? "none")" }
            .joined(separator: ",")
        let clockMovement = "decision=\(clockMovementState.lastDecision) running=\(clockMovementState.isRunning.map { String($0) } ?? "unknown")"
        let value = "clockBusy=\(clockBusy) scoreBusy=\(scoreBusy) periodBusy=\(periodBusy) penaltyPlayerBusy=\(penaltyPlayerBusy) penaltyTimerBusy=\(penaltyTimerBusy) copied=\(copiedFrames) copyFailures=\(copyFailures) clockPasses=\(completedClockPasses) scorePasses=\(completedScorePasses) periodPasses=\(completedPeriodPasses) penaltyPlayerPasses=\(completedPenaltyPlayerPasses) penaltyTimerPasses=\(completedPenaltyTimerPasses) auxDirectFieldBatches=\(auxiliaryDirectFieldBatchPasses) directFieldImages=\(directFieldImagesProduced) auxiliaryDirectCrops={batches=\(auxiliaryDirectCropBatches) crops=\(auxiliaryDirectCropCount) lastMs=\(String(format: "%.1f", auxiliaryDirectCropLastMS)) maxMs=\(String(format: "%.1f", auxiliaryDirectCropMaxMS)) writerCriticalYields=\(writerCriticalScoreboardYields) topology=clock-direct-crop+lane-local-aux-direct-crops} imageJobs=clock:\(activeClockImageJobs)/peak:\(peakClockImageJobs),aux:\(activeAuxiliaryImageJobs)/peak:\(peakAuxiliaryImageJobs) droppedClockBusy=\(droppedClockBusyFrames) coalescedClockBusy=\(coalescedClockBusyRequests) pendingClock=\(clockRerunPending) clockDeadlineMisses=\(clockDeadlineMisses) clockPendingReplacements=\(clockPendingFrameReplacements) clockMaxDeadlineMissMs=\(String(format: "%.1f", maximumClockDeadlineMissMS)) droppedScoreBusy=\(droppedScoreBusyFrames) droppedPeriodBusy=\(droppedPeriodBusyFrames) droppedPenaltyPlayerBusy=\(droppedPenaltyPlayerBusyFrames) droppedPenaltyTimerBusy=\(droppedPenaltyTimerBusyFrames) coalescedPenaltyPlayerBusy=\(coalescedPenaltyPlayerBusyRequests) coalescedPenaltyTimerBusy=\(coalescedPenaltyTimerBusyRequests) pendingPenaltyPlayer=\(penaltyPlayerRerunPending) pendingPenaltyTimer=\(penaltyTimerRerunPending) auxLatest={submitted=\(auxiliaryLatestSubmissions) pendingReplaced=\(auxiliaryPendingReplacements) mergedLaneIntents=\(auxiliaryMergedLaneIntents) yielded=\(auxiliaryYieldToNewerFrameCount) obsoleteLaneSkips=\(auxiliaryObsoleteLaneSkips) pendingSequence=\(pendingAuxiliaryRequest?.workToken.sourceSequence.map(String.init) ?? "none") drainActive=\(auxiliaryDrainScheduled) executionYields=\(auxiliaryExecutionOwnerYields) stageCancels=\(auxiliaryStageCancellationCount)} staleWork={aux=\(staleAuxiliaryBatchDrops) playerCommit=\(stalePenaltyPlayerCommitDrops) timerCommit=\(stalePenaltyTimerCommitDrops)}; cadence={clockImage=0.30s image-signature-only score=2.00s period=5.00s penaltyPlayerHash=0.30s penaltyPlayerOCR=2.00s/change-trigger activePenaltyTimer=0.30s}; clockMovement={\(clockMovement)}; clockPresentation={\(lastClockPresentationDiagnostic)}; timerPresentation={\(timerPresentationText)}; penaltyVisual={\(penaltyVisualText)}; playerHash={\(playerHashText)}; ocrModeVisual={\(recognitionText)}; presentation={\(ScoreboardImageRelayPresentationDiagnostics.shared.diagnosticText)}"
        lock.unlock()
        return value
    }


    private struct DirectClockStyleDigitMask {
        let image: CGImage
        let alpha: [UInt8]
        let activePixels: Int
        let maximumAlpha: Int
        let backgroundLuma: Int
    }

    /// Build 656 single digit-mask authority for the game Clock and every
    /// penalty timer. It is deliberately luminance-led so white-hot LED centres
    /// are retained instead of leaving red glow rings around hollow centres.
    /// No colour-dominance curve, morphology or pinhole filling is applied.
    private static func makeClockStyleDigitMask(
        from image: CGImage
    ) -> DirectClockStyleDigitMask? {
        let width = image.width
        let height = image.height
        guard width > 2, height > 2 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        var source = [UInt8](repeating: 0, count: bytesPerRow * height)
        let rendered = source.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: bitmapInfo
                  ) else { return false }
            context.interpolationQuality = .none
            context.setShouldAntialias(false)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }

        let stride = max(2, min(width, height) / 24)
        var backgroundLuma: [Int] = []
        backgroundLuma.reserveCapacity((width / stride + 1) * (height / stride + 1))
        for y in Swift.stride(from: 0, to: height, by: stride) {
            for x in Swift.stride(from: 0, to: width, by: stride) {
                let i = y * bytesPerRow + x * bytesPerPixel
                let r = Int(source[i])
                let g = Int(source[i + 1])
                let b = Int(source[i + 2])
                backgroundLuma.append((77 * r + 150 * g + 29 * b) >> 8)
            }
        }
        backgroundLuma.sort()
        let darkCount = max(1, backgroundLuma.count / 3)
        let background = backgroundLuma.prefix(darkCount).reduce(0, +) / darkCount

        let insetX = max(1, width / 40)
        let insetY = max(1, height / 24)
        var output = [UInt8](repeating: 0, count: bytesPerRow * height)
        var alphaMask = [UInt8](repeating: 0, count: width * height)
        var maximumAlpha = 0
        var activePixels = 0

        for y in 0..<height {
            for x in 0..<width {
                guard x >= insetX, x < width - insetX,
                      y >= insetY, y < height - insetY else { continue }
                let i = y * bytesPerRow + x * bytesPerPixel
                let r = Int(source[i])
                let g = Int(source[i + 1])
                let b = Int(source[i + 2])
                let luma = (77 * r + 150 * g + 29 * b) >> 8
                let chroma = max(r, max(g, b)) - min(r, min(g, b))
                let lift = max(0, luma - background)
                let yellow = max(0, min(r, g) - b)
                let signal = max(lift * 3 + chroma / 2, yellow * 4 + lift)
                let alpha = max(0, min(255, (signal - 18) * 2))
                guard alpha > 0 else { continue }
                let a = UInt8(alpha)
                output[i] = a
                output[i + 1] = a
                output[i + 2] = a
                output[i + 3] = a
                alphaMask[y * width + x] = a
                maximumAlpha = max(maximumAlpha, alpha)
                if alpha >= 18 { activePixels += 1 }
            }
        }

        guard maximumAlpha >= 32,
              activePixels >= max(6, width * height / 3_000),
              let provider = CGDataProvider(data: Data(output) as CFData),
              let fullZoneImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
                    CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return nil }

        return DirectClockStyleDigitMask(
            image: fullZoneImage,
            alpha: alphaMask,
            activePixels: activePixels,
            maximumAlpha: maximumAlpha,
            backgroundLuma: background
        )
    }

    /// Build 685 rebuilds the relay image from a scrubbed alpha mask. Penalty
    /// timer boxes are real illuminated pixels, so changing crop geometry alone
    /// is insufficient when a side rule sits close to the digits. Publishing the
    /// cleaned mask guarantees removed frame rows/columns remain transparent.
    private static func monochromeRelayImage(
        alpha: [UInt8],
        width: Int,
        height: Int
    ) -> CGImage? {
        guard width > 0, height > 0, alpha.count == width * height else { return nil }
        let bytesPerRow = width * 4
        var output = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let value = alpha[y * width + x]
                let index = y * bytesPerRow + x * 4
                output[index] = value
                output[index + 1] = value
                output[index + 2] = value
                output[index + 3] = value
            }
        }
        guard let provider = CGDataProvider(data: Data(output) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
                CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Safe non-recognition fallback used only when repeated-row digit-band
    /// measurement cannot be formed. It returns the illuminated envelope after
    /// field-edge scrubbing instead of the complete calibration zone. Clock and
    /// penalty timers therefore hold the last clean image when no safe envelope
    /// can be formed; neither path may publish a complete boxed calibration zone.
    private static func cleanRelayFallbackRect(
        alpha: [UInt8],
        width: Int,
        height: Int,
        threshold: UInt8 = 32
    ) -> CGRect? {
        guard width > 4, height > 4, alpha.count == width * height else { return nil }
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        var count = 0
        for y in 0..<height {
            for x in 0..<width where alpha[y * width + x] >= threshold {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
                count += 1
            }
        }
        guard count >= max(6, width * height / 4_000), maxX >= minX, maxY >= minY else {
            return nil
        }
        let contentHeight = maxY - minY + 1
        let padX = max(1, Int((Double(contentHeight) * 0.025).rounded(.up)))
        let padY = max(1, Int((Double(contentHeight) * 0.035).rounded(.up)))
        let x0 = max(0, minX - padX)
        let x1 = min(width, maxX + 1 + padX)
        let y0 = max(0, minY - padY)
        let y1 = min(height, maxY + 1 + padY)
        guard x1 > x0, y1 > y0 else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).integral
    }

    /// Geometry-only Clock rescue for a generously sized Calibration zone.
    /// It finds the dominant illuminated row band and trims sparse outer rows/
    /// columns before presentation. The value is never recognised here; only the
    /// visible character envelope is measured so zone margins do not shrink the
    /// viewer-facing Clock.
    private static func dominantClockCharacterBand(
        alpha: [UInt8],
        width: Int,
        height: Int,
        threshold: UInt8 = 40
    ) -> TimerDigitBandMeasurement? {
        guard width > 8, height > 8, alpha.count == width * height else { return nil }

        var rowCounts = [Int](repeating: 0, count: height)
        for y in 0..<height {
            var count = 0
            for x in 0..<width where alpha[y * width + x] >= threshold { count += 1 }
            rowCounts[y] = count
        }
        let peak = rowCounts.max() ?? 0
        guard peak >= 3 else { return nil }
        let denseGate = max(2, Int((Double(peak) * 0.18).rounded(.up)))
        let qualifying = rowCounts.indices.filter { rowCounts[$0] >= denseGate }
        guard let first = qualifying.first else { return nil }

        let allowedGap = max(2, height / 28)
        var bands: [(start: Int, end: Int, score: Int)] = []
        var start = first
        var previous = first
        for row in qualifying.dropFirst() {
            if row - previous > allowedGap {
                bands.append((start, previous, rowCounts[start...previous].reduce(0, +)))
                start = row
            }
            previous = row
        }
        bands.append((start, previous, rowCounts[start...previous].reduce(0, +)))
        guard let primary = bands.max(by: { $0.score < $1.score }) else { return nil }

        let faintGate = max(1, Int((Double(peak) * 0.035).rounded(.up)))
        let recovery = max(2, height / 16)
        var minY = primary.start
        var maxY = primary.end
        if minY > 0 {
            for y in stride(from: minY - 1, through: max(0, minY - recovery), by: -1) {
                guard rowCounts[y] >= faintGate else { break }
                minY = y
            }
        }
        if maxY + 1 < height {
            for y in (maxY + 1)...min(height - 1, maxY + recovery) {
                guard rowCounts[y] >= faintGate else { break }
                maxY = y
            }
        }

        var columnCounts = [Int](repeating: 0, count: width)
        for y in minY...maxY {
            for x in 0..<width where alpha[y * width + x] >= threshold { columnCounts[x] += 1 }
        }
        let total = columnCounts.reduce(0, +)
        guard total >= 12 else { return nil }
        let trim = max(1, Int((Double(total) * 0.006).rounded(.up)))
        var cumulative = 0
        var minX = 0
        for x in 0..<width {
            cumulative += columnCounts[x]
            if cumulative >= trim { minX = x; break }
        }
        cumulative = 0
        var maxX = width - 1
        for x in stride(from: width - 1, through: 0, by: -1) {
            cumulative += columnCounts[x]
            if cumulative >= trim { maxX = x; break }
        }
        guard maxX >= minX else { return nil }

        let measuredHeight = maxY - minY + 1
        let measuredWidth = maxX - minX + 1
        let aspect = CGFloat(measuredWidth) / max(1, CGFloat(measuredHeight))
        guard measuredHeight >= max(8, height / 10),
              measuredWidth >= max(16, width / 8),
              aspect >= 1.60 else { return nil }

        let padY = max(1, Int((Double(measuredHeight) * 0.04).rounded(.up)))
        let padX = max(1, Int((Double(measuredHeight) * 0.05).rounded(.up)))
        let x0 = max(0, minX - padX)
        let y0 = max(0, minY - padY)
        let x1 = min(width, maxX + 1 + padX)
        let y1 = min(height, maxY + 1 + padY)
        let rect = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).integral

        return TimerDigitBandMeasurement(
            rect: rect,
            rawRect: rect,
            removedComponents: 0,
            retainedComponents: 0,
            rowPeak: peak,
            rowThreshold: denseGate,
            diagnostic: String(
                format: "clock-dominant-character-band measured=%dx%d+%d,%d peak=%d gate=%d bands=%d aspect=%.3f",
                Int(rect.width), Int(rect.height), Int(rect.minX), Int(rect.minY),
                peak, denseGate, bands.count, aspect
            )
        )
    }

    private struct DirectClockImage {
        let image: CGImage
        let pixelHash: UInt64
        let timeoutStyleCandidate: Bool
        let diagnostic: String
    }

    /// Direct Clock conversion retains the 0.30-second physical sampling cadence.
    /// Clock owns a bounded row/column projection rather than the semantic timer
    /// connected-component reader. The latter stores every component pixel and is
    /// appropriate for occasional timer acquisition, but the 21:52 physical run
    /// measured 1.1-4.4 seconds when it was repeated for every viewer Clock frame.
    /// Stable geometry remains owned by `stabilisedClockRect`; this pass only gives
    /// it inexpensive current-frame evidence and never recognises the Clock value.
    private func makeDirectClockImage(
        from image: CGImage,
        captureGeneration: Int
    ) -> DirectClockImage? {
        let stageStarted = CFAbsoluteTimeGetCurrent()
        let width = image.width
        let height = image.height
        guard let mask = Self.makeClockStyleDigitMask(from: image) else { return nil }
        let maskCompleted = CFAbsoluteTimeGetCurrent()

        var presentationAlpha = mask.alpha
        var presentationImage = mask.image
        var removedClockRules = (rows: 0, columns: 0)
        var digitBand = Self.dominantClockCharacterBand(
            alpha: presentationAlpha,
            width: width,
            height: height
        )
        // Sparse edge rules can defeat the projection on a badly padded zone.
        // Scrub them once and repeat the same bounded projection. Do not rebound
        // to the superseded component scanner: clean-alpha below is the declared
        // provisional fallback and the stable geometry owner prevents breathing.
        if digitBand == nil {
            removedClockRules = Self.suppressPenaltyPlayerEdgeRules(
                alpha: &presentationAlpha,
                width: width,
                height: height,
                threshold: 36
            )
            guard let cleanedPresentationImage = Self.monochromeRelayImage(
                alpha: presentationAlpha,
                width: width,
                height: height
            ) else { return nil }
            presentationImage = cleanedPresentationImage
            digitBand = Self.dominantClockCharacterBand(
                alpha: presentationAlpha,
                width: width,
                height: height
            )
        }
        let clockEnvelope = Self.widthPreservingTimerDisplayRect(
            alpha: presentationAlpha,
            width: width,
            height: height,
            digitBand: digitBand,
            policy: .clock
        )
        guard clockEnvelope.rect.width >= 1, clockEnvelope.rect.height >= 1 else {
            return nil
        }
        let measurementCompleted = CFAbsoluteTimeGetCurrent()
        let stabilised = stabilisedClockRect(
            proposed: clockEnvelope.rect,
            captureGeneration: captureGeneration,
            sourceWidth: width,
            sourceHeight: height
        )
        // Build 674 restores two source pixels above and below the measured Clock
        // band before normalisation. The popup was clipping the lower LED stroke.
        let displayRect = Self.boundedRelayRect(
            stabilised.rect.insetBy(dx: 0, dy: -2),
            sourceWidth: width,
            sourceHeight: height
        )
        let horizontalAuthorityDiagnostic = clockEnvelope.diagnostic
            + " " + stabilised.diagnostic
            + " verticalRestore=2px"
            + " fallbackFrameScrub=rows:\(removedClockRules.rows),columns:\(removedClockRules.columns)"
        let geometryCompleted = CFAbsoluteTimeGetCurrent()
        guard let displayImage = presentationImage.cropping(to: displayRect) else {
            return nil
        }
        let measuredWidth = displayImage.width
        let measuredHeight = displayImage.height
        let measurementDiagnostic = digitBand?.diagnostic ?? "digit-band-fallback=clean-alpha-envelope"
        let normalised = Self.normalisedMeasuredDisplayImage(
            displayImage,
            canvasHeight: 100,
            horizontalSafetyFraction: 0.015,
            minimumCanvasAspect: 1,
            measuredGlyphOwnsCanvasWidth: true,
            interpolationDisabled: true
        )
        let published = normalised?.image ?? displayImage
        let normalisationDiagnostic = normalised?.diagnostic ?? "canvas-fallback=display-image"
        let percent = Double(mask.activePixels) / Double(max(1, width * height)) * 100
        let normalisationCompleted = CFAbsoluteTimeGetCurrent()

        let timeoutWidthFraction = CGFloat(clockEnvelope.rect.width) / max(1, CGFloat(width))
        let pixelHash = Self.canonicalRelayPixelHash(published, key: .clock)
        let hashCompleted = CFAbsoluteTimeGetCurrent()
        let cpuStageDiagnostic = String(
            format: "cpuStages={mask=%.1fms measure=%.1fms geometry=%.1fms normalise=%.1fms hash=%.1fms}",
            (maskCompleted - stageStarted) * 1_000,
            (measurementCompleted - maskCompleted) * 1_000,
            (geometryCompleted - measurementCompleted) * 1_000,
            (normalisationCompleted - geometryCompleted) * 1_000,
            (hashCompleted - normalisationCompleted) * 1_000
        )
        return DirectClockImage(
            image: published,
            pixelHash: pixelHash,
            timeoutStyleCandidate: timeoutWidthFraction >= 0.80,
            diagnostic: String(
                format: "direct-digit-band src=%dx%d measured=%dx%d crop=%dx%d published=%dx%d heightRef=%d bg=%d %@ %@ active=%.1f%% aMax=%d mask=shared-clock-style no-recognition %@",
                width,
                height,
                measuredWidth,
                measuredHeight,
                displayImage.width,
                displayImage.height,
                published.width,
                published.height,
                measuredHeight,
                mask.backgroundLuma,
                measurementDiagnostic + " " + horizontalAuthorityDiagnostic,
                normalisationDiagnostic,
                percent,
                mask.maximumAlpha,
                cpuStageDiagnostic
            )
        )
    }


    nonisolated private struct DirectPenaltyTimerCandidate: @unchecked Sendable {
        let fullZoneImage: CGImage
        let proposedRect: CGRect
        let sourceWidth: Int
        let sourceHeight: Int
        let pipelineTitle: String
        let measurementDiagnostic: String
        let hasMeasuredDigitBand: Bool
        let activePercent: Double
        let maximumAlpha: Int
    }

    private struct DirectPenaltyTimerImage {
        let image: CGImage
        let diagnostic: String
    }

    private static func newPenaltyVisualState(
        activationID: UInt64,
        captureGeneration: Int,
        calibrationSignature: UInt64,
        physicalIdentityHash: UInt64?,
        decision: String
    ) -> RelayPenaltyVisualState {
        RelayPenaltyVisualState(
            activationID: activationID,
            phase: .acquiring,
            captureGeneration: captureGeneration,
            calibrationSignature: calibrationSignature,
            pendingCalibrationSignature: nil,
            pendingCalibrationCount: 0,
            physicalIdentityHash: physicalIdentityHash,
            frozenPlayerImage: nil,
            frozenPlayerPixelHash: nil,
            frozenPlayerShapeHash: nil,
            pendingPlayerReplacementHash: nil,
            pendingPlayerReplacementCount: 0,
            timerAcquisitionRect: nil,
            timerAcquisitionCount: 0,
            lockedTimerRect: nil,
            lockedTimerCharacterCentreX: nil,
            lastTimerImage: nil,
            lastTimerPixelHash: nil,
            geometryRevision: 0,
            pendingExpansionRect: nil,
            pendingExpansionCount: 0,
            rejectedShrinkCount: 0,
            acceptedExpansionCount: 0,
            heldWeakFrameCount: 0,
            lastDecision: decision
        )
    }

    nonisolated private static func timerGeometryRejectionReasons(
        _ candidate: DirectPenaltyTimerCandidate
    ) -> [String] {
        var reasons: [String] = []
        if !candidate.hasMeasuredDigitBand { reasons.append("no-digit-band") }
        if candidate.maximumAlpha < 160 { reasons.append("alpha-below-160") }
        if candidate.activePercent < 3.0 { reasons.append("active-below-3pct") }
        for warning in [
            "overwide", "too-narrow", "too-short", "border-contact",
            "horizontal-edge", "vertical-edge"
        ] where candidate.measurementDiagnostic.contains(warning) {
            reasons.append(warning)
        }
        return reasons
    }

    nonisolated private static func penaltyTimerGeometryAdmissionDecision(
        _ candidate: DirectPenaltyTimerCandidate
    ) -> (allowed: Bool, reason: String) {
        let reasons = timerGeometryRejectionReasons(candidate)
        if reasons.isEmpty {
            return (true, "strict-clean")
        }

        // Build 695: the physical 10:00 and 2:00 groups can legitimately fill
        // almost the complete calibrated timer zone. The previous strict gate
        // held them for 92-110 seconds even though a measured digit band, strong
        // alpha and substantial active pixels were present. Only the soft
        // overwide/border-contact warnings may be relaxed. Every structural or
        // weak-signal warning remains fail-closed.
        let featureEnabled = RinkLensRiskFeaturePolicy.isEnabled(.penaltyEdgeFilledTimerAdmissionV2)
        let repeatedEdgeRecoveryEnabled = RinkLensRiskFeaturePolicy.isEnabled(.penaltyRepeatedEdgeTimerRecoveryV22)
        let softWarnings: Set<String> = ["overwide", "border-contact"]
        let recoverableWarnings: Set<String> = ["no-digit-band", "overwide", "border-contact"]
        let reasonSet = Set(reasons)
        let strongMeasuredGroup = candidate.hasMeasuredDigitBand
            && candidate.maximumAlpha >= 200
            && candidate.activePercent >= 5.0
        if featureEnabled,
           strongMeasuredGroup,
           !reasonSet.isEmpty,
           reasonSet.isSubset(of: softWarnings) {
            return (true, "feature-edge-filled[\(reasons.joined(separator: ","))] active=\(String(format: "%.1f", candidate.activePercent)) alpha=\(candidate.maximumAlpha)")
        }
        let repeatedStrongEdgeGroup = candidate.maximumAlpha >= 220
            && candidate.activePercent >= 6.0
            && candidate.activePercent <= 48.0
        if repeatedEdgeRecoveryEnabled,
           repeatedStrongEdgeGroup,
           !reasonSet.isEmpty,
           reasonSet.isSubset(of: recoverableWarnings) {
            return (true, "feature-repeated-edge-timer[\(reasons.joined(separator: ","))] active=\(String(format: "%.1f", candidate.activePercent)) alpha=\(candidate.maximumAlpha)")
        }
        return (false, "rejected[\(reasons.joined(separator: ","))]")
    }

    nonisolated private static func timerCandidateCanEstablishGeometry(
        _ candidate: DirectPenaltyTimerCandidate
    ) -> Bool {
        penaltyTimerGeometryAdmissionDecision(candidate).allowed
    }

    private static func timerRectsAreCompatible(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let maximumWidth = max(lhs.width, rhs.width)
        let maximumHeight = max(lhs.height, rhs.height)
        let centreXTolerance = max(3, maximumWidth * 0.18)
        let centreYTolerance = max(2, maximumHeight * 0.16)
        let heightRatio = min(lhs.height, rhs.height) / max(1, maximumHeight)
        return abs(lhs.midX - rhs.midX) <= centreXTolerance
            && abs(lhs.midY - rhs.midY) <= centreYTolerance
            && heightRatio >= 0.72
    }

    private static func timerRectsAreVerticallyCompatible(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let maximumHeight = max(lhs.height, rhs.height)
        let heightRatio = min(lhs.height, rhs.height) / max(1, maximumHeight)
        return abs(lhs.midY - rhs.midY) <= max(2, maximumHeight * 0.16)
            && heightRatio >= 0.72
    }

    private static func timerRectNeedsHorizontalExpansion(
        locked: CGRect,
        proposed: CGRect
    ) -> Bool {
        proposed.minX < locked.minX - 1 || proposed.maxX > locked.maxX + 1
    }

    private static func relayVisualPublicationHash(
        key: OCRRegionKey,
        activationID: UInt64,
        geometryRevision: UInt64,
        pixelHash: UInt64
    ) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        func append(_ value: UInt64) {
            var copy = value
            withUnsafeBytes(of: &copy) { bytes in
                for byte in bytes {
                    hash ^= UInt64(byte)
                    hash &*= 1_099_511_628_211
                }
            }
        }
        for byte in key.rawValue.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        append(activationID)
        append(geometryRevision)
        append(pixelHash)
        return hash
    }

    /// Quantised alpha-grid hash. Camera grain and one-pixel edge movement do not
    /// force a presentation revision, while a real Clock/timer digit change does.
    private static func canonicalRelayPixelHash(
        _ image: CGImage,
        key: OCRRegionKey
    ) -> UInt64 {
        let grid = hashGridSize(for: key)
        let width = max(1, grid.width)
        let height = max(1, grid.height)
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let base = bytes.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.interpolationQuality = .low
            context.setShouldAntialias(false)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return UInt64(image.width &* 65_537 &+ image.height) }

        var hash: UInt64 = 14_695_981_039_346_656_037
        for index in stride(from: 3, to: pixels.count, by: 4) {
            let alpha = pixels[index]
            let quantised: UInt8
            switch alpha {
            case 0..<28: quantised = 0
            case 28..<96: quantised = 1
            case 96..<176: quantised = 2
            default: quantised = 3
            }
            hash ^= UInt64(quantised)
            hash &*= 1_099_511_628_211
        }
        hash ^= UInt64(image.width)
        hash &*= 1_099_511_628_211
        hash ^= UInt64(image.height)
        hash &*= 1_099_511_628_211
        return hash
    }

    private static func penaltyVisualCalibrationSignature(
        playerKey: OCRRegionKey,
        timerKey: OCRRegionKey,
        layout: ScoreboardOCRLayout,
        colourProfiles: OCRColourProfileSet,
        boardCalibration: BoardCalibrationQuad,
        previewRotationDegrees: CGFloat
    ) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        func append(_ value: Double) {
            var bits = value.bitPattern
            withUnsafeBytes(of: &bits) { bytes in
                for byte in bytes {
                    hash ^= UInt64(byte)
                    hash &*= 1_099_511_628_211
                }
            }
        }
        func appendText(_ value: String) {
            for byte in value.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
        }
        for region in [layout[playerKey], layout[timerKey]] {
            for value in [region.x, region.y, region.width, region.height, region.rotationDegrees] {
                append(Double(value))
            }
        }
        for point in [
            boardCalibration.topLeft,
            boardCalibration.topRight,
            boardCalibration.bottomRight,
            boardCalibration.bottomLeft
        ] {
            append(Double(point.x))
            append(Double(point.y))
        }
        append(Double(previewRotationDegrees))
        appendText(colourProfiles.profile(for: playerKey).summaryText)
        appendText(colourProfiles.profile(for: timerKey).summaryText)
        return hash
    }

    /// Returns the exact non-transparent evidence envelope used by Guided
    /// Calibration's green character box. Timer presentation uses the same centre
    /// so Home and Guest digit groups align even when their source zones contain
    /// unequal left/right margins.
    private static func visibleAlphaBounds(in image: CGImage, threshold: UInt8 = 18) -> CGRect? {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data),
              image.width > 0, image.height > 0 else { return nil }
        let length = CFDataGetLength(data)
        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        let alphaIndex = bytesPerPixel >= 4 ? 3 : bytesPerPixel - 1
        var minX = image.width
        var minY = image.height
        var maxX = -1
        var maxY = -1
        for y in 0..<image.height {
            let row = y * image.bytesPerRow
            for x in 0..<image.width {
                let offset = row + x * bytesPerPixel + alphaIndex
                guard offset < length, bytes[offset] >= threshold else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Build 588 two-dimensional timer display authority. Height and width are
    /// derived from the measured illuminated digit group, then placed on a canvas
    /// no narrower than the caller's authoritative aspect. Wider measured groups remain wider. Transparent
    /// safety margins are added and content is contain-fitted without cropping,
    /// stretching or compressing outer digits.
    private static func normalisedMeasuredDisplayImage(
        _ source: CGImage,
        canvasHeight: Int,
        horizontalSafetyFraction: CGFloat,
        minimumCanvasAspect: CGFloat,
        sourceCharacterCentreX: CGFloat? = nil,
        heightAuthoritative: Bool = false,
        fillCanvasWidth: Bool = false,
        measuredGlyphOwnsCanvasWidth: Bool = false,
        interpolationDisabled: Bool = false
    ) -> (image: CGImage, diagnostic: String)? {
        guard source.width > 0, source.height > 0, canvasHeight > 4 else { return nil }

        let verticalSafety = max(1, Int((CGFloat(canvasHeight) * 0.040).rounded()))
        let maximumDrawHeight = max(1, canvasHeight - verticalSafety * 2)
        let measuredDrawWidthAtAuthoritativeHeight = max(
            1,
            Int((CGFloat(source.width) * CGFloat(maximumDrawHeight) / CGFloat(source.height)).rounded(.up))
        )
        let measuredSafety = max(
            2,
            Int((CGFloat(measuredDrawWidthAtAuthoritativeHeight) * max(0, horizontalSafetyFraction)).rounded(.up))
        )
        let fixedCanvasWidth = max(1, Int((CGFloat(canvasHeight) * max(1, minimumCanvasAspect)).rounded(.up)))
        let canvasWidth = measuredGlyphOwnsCanvasWidth
            ? measuredDrawWidthAtAuthoritativeHeight + measuredSafety * 2
            : fixedCanvasWidth
        let minimumHorizontalSafety = measuredGlyphOwnsCanvasWidth
            ? measuredSafety
            : max(2, Int((CGFloat(canvasWidth) * max(0, horizontalSafetyFraction)).rounded(.up)))
        let maximumDrawWidth = max(1, canvasWidth - minimumHorizontalSafety * 2)
        let heightScale = CGFloat(maximumDrawHeight) / CGFloat(source.height)
        let widthScale = CGFloat(maximumDrawWidth) / CGFloat(source.width)
        let containScale = heightAuthoritative ? heightScale : min(heightScale, widthScale)
        // Build 719 Clock-only rollout. The fixed 580x100 canvas remains the
        // presentation authority, but the measured Clock now uses its full
        // drawable width instead of retaining ~136px transparent gutters on
        // both sides. Other relayed fields retain contain-fit geometry.
        let drawHeight = fillCanvasWidth
            ? maximumDrawHeight
            : max(1, Int((CGFloat(source.height) * containScale).rounded(.down)))
        let drawWidth = fillCanvasWidth
            ? maximumDrawWidth
            : max(1, Int((CGFloat(source.width) * containScale).rounded(.down)))
        let horizontalSafety = max(0, (canvasWidth - min(canvasWidth, drawWidth)) / 2)
        let defaultInset = CGFloat((canvasWidth - drawWidth) / 2)
        let horizontalInset: CGFloat = {
            guard !fillCanvasWidth, heightAuthoritative, let sourceCharacterCentreX else { return defaultInset }
            let scaledCentre = sourceCharacterCentreX * containScale
            let proposed = CGFloat(canvasWidth) * 0.5 - scaledCentre
            let lowerBound = CGFloat(canvasWidth - minimumHorizontalSafety - drawWidth)
            let upperBound = CGFloat(minimumHorizontalSafety)
            if lowerBound <= upperBound {
                return min(max(lowerBound, proposed), upperBound)
            }
            return proposed
        }()
        let verticalInset = CGFloat(max(0, (canvasHeight - drawHeight) / 2))
        let drawRect = CGRect(
            x: horizontalInset,
            y: verticalInset,
            width: CGFloat(drawWidth),
            height: CGFloat(drawHeight)
        ).integral

        let bytesPerPixel = 4
        let bytesPerRow = canvasWidth * bytesPerPixel
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        var output = [UInt8](repeating: 0, count: bytesPerRow * canvasHeight)
        let rendered = output.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: canvasWidth,
                    height: canvasHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: bitmapInfo
                  ) else { return false }
            context.clear(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
            context.interpolationQuality = interpolationDisabled ? .none : .medium
            context.setShouldAntialias(false)
            context.draw(source, in: drawRect)
            return true
        }
        guard rendered,
              let provider = CGDataProvider(data: Data(output) as CFData),
              let image = CGImage(
                width: canvasWidth,
                height: canvasHeight,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
                    CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: !interpolationDisabled,
                intent: .defaultIntent
              ) else { return nil }

        return (
            image,
            String(
                format: "canvas=%dx%d draw=%dx%d widthRef=%d heightRef=%d measuredAspect=%.3f fixedAspect=%.2f finalAspect=%.3f containScale=%.3f safety=%dx%d centre=%@ fit=%@ fixed-canvas vertical-authority",
                canvasWidth,
                canvasHeight,
                drawWidth,
                drawHeight,
                source.width,
                source.height,
                CGFloat(source.width) / max(1, CGFloat(source.height)),
                minimumCanvasAspect,
                CGFloat(canvasWidth) / max(1, CGFloat(canvasHeight)),
                containScale,
                horizontalSafety,
                Int(verticalInset.rounded()),
                heightAuthoritative ? "activation-character-centre" : "locked-envelope",
                measuredGlyphOwnsCanvasWidth
                    ? "measured-glyph-canvas"
                    : (fillCanvasWidth
                        ? "clock-canvas-width-fill"
                        : (heightAuthoritative ? "fixed-height-centred-clipped-if-needed" : "contain"))
            )
        )
    }

    private struct TimerDigitBandMeasurement {
        let rect: CGRect
        let rawRect: CGRect
        let removedComponents: Int
        let retainedComponents: Int
        let rowPeak: Int
        let rowThreshold: Int
        let diagnostic: String
    }

    private enum RelayTimerEnvelopePolicy {
        case clock
        case penaltyTimer
    }

    /// Build 595 gives the main Clock and active penalty timers one shared
    /// width-preservation boundary. The cleaned digit band remains authoritative
    /// vertically. Horizontally, the Clock keeps the complete active envelope, while
    /// penalty timers first discard only confirmed bezel/rule components attached to
    /// the extreme crop edges. Neither policy recognises or interprets timer digits.
    private static func widthPreservingTimerDisplayRect(
        alpha: [UInt8],
        width: Int,
        height: Int,
        digitBand: TimerDigitBandMeasurement?,
        policy: RelayTimerEnvelopePolicy,
        threshold: UInt8 = 28
    ) -> (rect: CGRect, diagnostic: String) {
        guard let digitBand else {
            let prefix = policy == .clock ? "clockWidth" : "timerWidth"
            if let fallback = cleanRelayFallbackRect(
                alpha: alpha,
                width: width,
                height: height,
                threshold: max(28, threshold)
            ) {
                let aspect = fallback.width / max(1, fallback.height)
                if policy != .clock || aspect >= 1.60 {
                    return (fallback, "\(prefix)=clean-alpha-fallback aspect=\(String(format: "%.3f", Double(aspect)))")
                }
                return (.zero, "clockWidth=ambiguous-tall-fallback-hold-last aspect=\(String(format: "%.3f", Double(aspect)))")
            }
            return (.zero, "\(prefix)=no-clean-envelope-hold-last")
        }

        let verticalRect = digitBand.rect.integral
        let bandMinY = max(0, Int(floor(verticalRect.minY)))
        let bandMaxY = min(height - 1, max(bandMinY, Int(ceil(verticalRect.maxY)) - 1))
        let bandHeight = max(1, bandMaxY - bandMinY + 1)
        let horizontalPad = max(1, Int((CGFloat(bandHeight) * 0.020).rounded(.up)))

        var envelopeMinX = max(0, Int(floor(digitBand.rawRect.minX)))
        var envelopeMaxX = min(width - 1, max(envelopeMinX, Int(ceil(digitBand.rawRect.maxX)) - 1))
        var rejectedCount = 0
        var retainedCount = 0
        var authority = "raw-active-envelope"

        if policy == .penaltyTimer {
            let hardEdgeX = max(2, Int((Double(width) * 0.025).rounded()))
            let components = connectedComponents(
                alpha: alpha,
                width: width,
                height: height,
                threshold: threshold
            ).filter { $0.area >= 2 }

            var leftTrim: Int?
            var rightTrim: Int?
            for component in components {
                let overlapMinY = max(component.minY, bandMinY)
                let overlapMaxY = min(component.maxY, bandMaxY)
                guard overlapMaxY >= overlapMinY else { continue }

                let widthFraction = Double(component.width) / Double(max(1, width))
                let overlapHeightFraction = Double(overlapMaxY - overlapMinY + 1) / Double(bandHeight)
                let density = Double(component.area) / Double(max(1, component.width * component.height))
                let touchesLeftExtreme = component.minX <= hardEdgeX
                let touchesRightExtreme = component.maxX >= width - 1 - hardEdgeX
                let touchesExtremeSide = touchesLeftExtreme || touchesRightExtreme
                let horizontalRule = widthFraction >= 0.30 && overlapHeightFraction <= 0.14
                let tallEdgeBezel = touchesExtremeSide
                    && widthFraction <= 0.055
                    && overlapHeightFraction >= 0.72
                let enclosingOutline = widthFraction >= 0.72
                    && overlapHeightFraction >= 0.62
                    && density < 0.42
                let shallowWideBezel = widthFraction >= 0.45 && overlapHeightFraction <= 0.18

                if horizontalRule || tallEdgeBezel || enclosingOutline || shallowWideBezel {
                    rejectedCount += 1
                    // Horizontal rules and enclosing outlines are removed by the
                    // cleaned vertical digit band. Only a positively identified tall
                    // bezel attached to an extreme side is allowed to trim width.
                    if tallEdgeBezel && touchesLeftExtreme {
                        leftTrim = max(leftTrim ?? 0, component.maxX + 1)
                    }
                    if tallEdgeBezel && touchesRightExtreme {
                        rightTrim = min(rightTrim ?? (width - 1), component.minX - 1)
                    }
                } else {
                    retainedCount += 1
                }
            }

            if let leftTrim, leftTrim <= envelopeMaxX {
                envelopeMinX = max(envelopeMinX, leftTrim)
            }
            if let rightTrim, rightTrim >= envelopeMinX {
                envelopeMaxX = min(envelopeMaxX, rightTrim)
            }
            // The red-display filter never rebuilds width from the variable union
            // of retained components. That was the source of left/right breathing.
            // It preserves the full raw illuminated envelope and applies only
            // deterministic extreme-edge bezel trims.
            authority = (leftTrim != nil || rightTrim != nil)
                ? "filtered-raw-envelope"
                : "raw-active-envelope"
        }

        let x0 = max(0, envelopeMinX - horizontalPad)
        let x1 = min(width, envelopeMaxX + 1 + horizontalPad)
        let rect = CGRect(
            x: x0,
            y: bandMinY,
            width: max(1, x1 - x0),
            height: bandHeight
        ).integral

        let prefix = policy == .clock ? "clockWidth" : "timerWidth"
        return (
            rect,
            String(
                format: "%@=%@ raw=%d cleaned=%d publish=%d pad=%d bezelRejected=%d envelopeRetained=%d",
                prefix,
                authority,
                Int(digitBand.rawRect.width.rounded()),
                Int(digitBand.rect.width.rounded()),
                Int(rect.width.rounded()),
                horizontalPad,
                rejectedCount,
                retainedCount
            )
        )
    }

    /// Builds 583-585 measure the repeated vertical digit band rather than taking the
    /// union of every lit pixel in the Calibration zone. Long horizontal rules,
    /// edge strokes and enclosing frame components are removed first. The remaining
    /// row occupancy identifies the common top/bottom of the timer digits without
    /// recognising or interpreting any number.
    private static func measureRelayDigitBand(
        alpha: [UInt8],
        width: Int,
        height: Int,
        threshold: UInt8 = 28,
        allowHorizontalEnvelopeRescue: Bool = false
    ) -> TimerDigitBandMeasurement? {
        guard width > 4, height > 4, alpha.count == width * height else { return nil }

        func bounds(of pixels: [Int]) -> CGRect? {
            guard !pixels.isEmpty else { return nil }
            var minX = width
            var minY = height
            var maxX = -1
            var maxY = -1
            for index in pixels {
                let x = index % width
                let y = index / width
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
            guard maxX >= minX, maxY >= minY else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }

        let initialPixels = alpha.indices.filter { alpha[$0] >= threshold }
        guard let rawRect = bounds(of: initialPixels) else { return nil }

        var cleaned = alpha
        let initialComponents = connectedComponents(
            alpha: cleaned,
            width: width,
            height: height,
            threshold: threshold
        ).filter { $0.area >= 2 }

        let edgeX = max(2, Int((Double(width) * 0.045).rounded()))
        let edgeY = max(2, Int((Double(height) * 0.08).rounded()))
        let removable = initialComponents.filter { component in
            let widthFraction = Double(component.width) / Double(max(1, width))
            let heightFraction = Double(component.height) / Double(max(1, height))
            let touchesSide = component.minX <= edgeX || component.maxX >= width - 1 - edgeX
            let touchesTopBottom = component.minY <= edgeY || component.maxY >= height - 1 - edgeY
            let horizontalRule = widthFraction >= 0.30 && heightFraction <= 0.12
            let verticalEdgeRule = touchesSide && heightFraction >= 0.48 && widthFraction <= 0.045
            let shallowEdgeNoise = touchesTopBottom && widthFraction >= 0.18 && heightFraction <= 0.16
            return frameLike(component, width: width, height: height)
                || horizontalRule
                || verticalEdgeRule
                || shallowEdgeNoise
        }

        if !removable.isEmpty {
            var erase = [UInt8](repeating: 0, count: cleaned.count)
            for component in removable {
                for index in component.pixels {
                    let x = index % width
                    let y = index / width
                    for ny in max(0, y - 1)...min(height - 1, y + 1) {
                        for nx in max(0, x - 1)...min(width - 1, x + 1) {
                            erase[ny * width + nx] = 1
                        }
                    }
                }
            }
            for index in cleaned.indices where erase[index] != 0 {
                cleaned[index] = 0
            }
        }

        let retained = connectedComponents(
            alpha: cleaned,
            width: width,
            height: height,
            threshold: threshold
        ).filter { component in
            guard component.area >= 2 else { return false }
            let widthFraction = Double(component.width) / Double(max(1, width))
            let heightFraction = Double(component.height) / Double(max(1, height))
            // Preserve ordinary seven-segment strokes and colon dots, but reject
            // any remaining full-zone line or near-edge hairline.
            if widthFraction >= 0.40 && heightFraction <= 0.10 { return false }
            if heightFraction >= 0.55 && widthFraction <= 0.025
                && (component.minX <= edgeX || component.maxX >= width - 1 - edgeX) { return false }
            return true
        }
        guard !retained.isEmpty else { return nil }

        var retainedMask = [UInt8](repeating: 0, count: cleaned.count)
        for component in retained {
            for index in component.pixels {
                retainedMask[index] = cleaned[index]
            }
        }

        var rowCounts = [Int](repeating: 0, count: height)
        for y in 0..<height {
            var count = 0
            for x in 0..<width where retainedMask[y * width + x] >= threshold {
                count += 1
            }
            rowCounts[y] = count
        }
        let rowPeak = rowCounts.max() ?? 0
        guard rowPeak >= 2 else { return nil }
        let rowThreshold = max(2, Int((Double(rowPeak) * 0.075).rounded()))
        let qualifyingRows = rowCounts.indices.filter { rowCounts[$0] >= rowThreshold }
        guard !qualifyingRows.isEmpty else { return nil }

        let allowedGap = max(2, height / 14)
        var bands: [(start: Int, end: Int, score: Int)] = []
        var start = qualifyingRows[0]
        var previous = qualifyingRows[0]
        for row in qualifyingRows.dropFirst() {
            if row - previous > allowedGap {
                let score = rowCounts[start...previous].reduce(0, +)
                bands.append((start, previous, score))
                start = row
            }
            previous = row
        }
        bands.append((start, previous, rowCounts[start...previous].reduce(0, +)))

        guard let primaryBand = bands.max(by: { lhs, rhs in
            if lhs.score == rhs.score {
                return (lhs.end - lhs.start) < (rhs.end - rhs.start)
            }
            return lhs.score < rhs.score
        }) else { return nil }

        var bandMinY = primaryBand.start
        var bandMaxY = primaryBand.end
        // Recover faint top/bottom segment antialiasing immediately adjacent to
        // the dense band, but do not allow remote rules to extend the measurement.
        let recovery = max(1, height / 20)
        for y in stride(from: primaryBand.start - 1, through: max(0, primaryBand.start - recovery), by: -1) {
            guard y >= 0, rowCounts[y] > 0 else { break }
            bandMinY = y
        }
        if primaryBand.end + 1 < height {
            for y in (primaryBand.end + 1)...min(height - 1, primaryBand.end + recovery) {
                guard rowCounts[y] > 0 else { break }
                bandMaxY = y
            }
        }

        var columnCounts = [Int](repeating: 0, count: width)
        for y in bandMinY...bandMaxY {
            for x in 0..<width where retainedMask[y * width + x] >= threshold {
                columnCounts[x] += 1
            }
        }
        let totalBandPixels = columnCounts.reduce(0, +)
        guard totalBandPixels >= 6 else { return nil }
        let trimCount = max(1, Int((Double(totalBandPixels) * 0.004).rounded()))
        var cumulative = 0
        var minX = 0
        for x in 0..<width {
            cumulative += columnCounts[x]
            if cumulative >= trimCount {
                minX = x
                break
            }
        }
        cumulative = 0
        var maxX = width - 1
        for x in stride(from: width - 1, through: 0, by: -1) {
            cumulative += columnCounts[x]
            if cumulative >= trimCount {
                maxX = x
                break
            }
        }
        guard maxX >= minX else { return nil }

        let measuredHeight = bandMaxY - bandMinY + 1
        var resolvedMinX = minX
        var resolvedMaxX = maxX
        var widthPolicy = "retained-columns"

        // Build 585 protects a complete multi-digit Clock group from over-aggressive
        // cleanup. Width is calculated from every non-rule component that overlaps
        // the measured vertical digit band, including narrow outer digits and colon
        // dots. Long horizontal rules, outer edge lines and enclosing outlines are
        // excluded. Build 595 resolves final Clock and penalty-timer width in the
        // shared width-preservation boundary after this vertical-band measurement.
        if allowHorizontalEnvelopeRescue {
            let verticalTolerance = max(1, measuredHeight / 10)
            let widthCandidates = initialComponents.filter { component in
                let widthFraction = Double(component.width) / Double(max(1, width))
                let heightFraction = Double(component.height) / Double(max(1, height))
                let density = Double(component.area) / Double(max(1, component.width * component.height))
                let touchesSide = component.minX <= edgeX || component.maxX >= width - 1 - edgeX
                let overlapsBand = component.maxY >= max(0, bandMinY - verticalTolerance)
                    && component.minY <= min(height - 1, bandMaxY + verticalTolerance)
                let horizontalRule = widthFraction >= 0.30 && heightFraction <= 0.12
                let verticalOuterRule = touchesSide && heightFraction >= 0.48 && widthFraction <= 0.045
                let enclosingOutline = widthFraction >= 0.72 && heightFraction >= 0.68 && density < 0.42
                return overlapsBand && !horizontalRule && !verticalOuterRule && !enclosingOutline
            }
            if let candidateMinX = widthCandidates.map(\.minX).min(),
               let candidateMaxX = widthCandidates.map(\.maxX).max() {
                let candidateWidth = candidateMaxX - candidateMinX + 1
                let candidateWidthFraction = Double(candidateWidth) / Double(max(1, width))
                let cleanedToCandidate = Double(maxX - minX + 1) / Double(max(1, candidateWidth))
                if candidateWidthFraction >= 0.30,
                   candidateWidthFraction <= 0.90,
                   cleanedToCandidate < 0.90 {
                    resolvedMinX = candidateMinX
                    resolvedMaxX = candidateMaxX
                    widthPolicy = "component-envelope-rescue"
                }
            }
        }

        let measuredWidth = resolvedMaxX - resolvedMinX + 1
        guard measuredHeight >= max(8, height / 4),
              measuredHeight <= max(10, Int((Double(height) * 0.88).rounded())),
              measuredWidth >= max(8, width / 6) else { return nil }

        let padY = max(1, Int((Double(measuredHeight) * 0.025).rounded()))
        let padX = max(1, Int((Double(measuredHeight) * 0.045).rounded()))
        let x0 = max(0, resolvedMinX - padX)
        let y0 = max(0, bandMinY - padY)
        let x1 = min(width, resolvedMaxX + 1 + padX)
        let y1 = min(height, bandMaxY + 1 + padY)
        let rect = CGRect(x: x0, y: y0, width: max(1, x1 - x0), height: max(1, y1 - y0)).integral

        let diagnostic = String(
            format: "digit-band raw=%dx%d+%d,%d measured=%dx%d+%d,%d widthPolicy=%@ removed=%d retained=%d rowPeak=%d rowGate=%d bands=%d",
            Int(rawRect.width),
            Int(rawRect.height),
            Int(rawRect.minX),
            Int(rawRect.minY),
            Int(rect.width),
            Int(rect.height),
            Int(rect.minX),
            Int(rect.minY),
            widthPolicy,
            removable.count,
            retained.count,
            rowPeak,
            rowThreshold,
            bands.count
        )
        return TimerDigitBandMeasurement(
            rect: rect,
            rawRect: rawRect,
            removedComponents: removable.count,
            retainedComponents: retained.count,
            rowPeak: rowPeak,
            rowThreshold: rowThreshold,
            diagnostic: diagnostic
        )
    }

    /// Safe penalty-timer conversion. The calibrated rectangle defines the source
    /// search area, but only the cleaned illuminated digit envelope may be published.
    /// Build 583 measures the repeated digit band after removing frame/line components;
    /// Build 687 makes every cleaning/crop failure fail closed and retain the previous
    /// clean timer. It performs no digit recognition or timer-value interpretation.
    private static func makeDirectPenaltyTimerCandidate(
        from image: CGImage,
        key: OCRRegionKey,
        colourProfile: OCRZoneColourProfile
    ) -> DirectPenaltyTimerCandidate? {
        let width = image.width
        let height = image.height
        guard let mask = makeClockStyleDigitMask(from: image) else { return nil }

        // Build 685 applies the proven outer-rule scrub before both measurement
        // and publication. Build 684 measured the unclean mask and, when the box
        // prevented a digit band, fell back to the complete 237x70 zone.
        var presentationAlpha = mask.alpha
        let removedRules = suppressPenaltyPlayerEdgeRules(
            alpha: &presentationAlpha,
            width: width,
            height: height,
            threshold: 36
        )
        guard let presentationImage = monochromeRelayImage(
            alpha: presentationAlpha,
            width: width,
            height: height
        ) else { return nil }
        let digitBand = measureRelayDigitBand(
            alpha: presentationAlpha,
            width: width,
            height: height,
            threshold: 28,
            allowHorizontalEnvelopeRescue: true
        )
        // Build 656 uses the same current-frame digit envelope as the Clock.
        // A multiplex-dark frame simply produces no candidate and the store keeps
        // the last published image; historical timer width is not accumulated.
        let timerEnvelope = widthPreservingTimerDisplayRect(
            alpha: presentationAlpha,
            width: width,
            height: height,
            digitBand: digitBand,
            // Build 662: penalty boxes contain vertical side rules that the Clock
            // zone does not. Use the existing deterministic penalty-bezel filter
            // while retaining the same Clock-style luminance mask and canvas.
            policy: .penaltyTimer
        )
        guard timerEnvelope.rect.width >= 1, timerEnvelope.rect.height >= 1 else {
            return nil
        }
        let displayRect = boundedRelayRect(
            timerEnvelope.rect,
            sourceWidth: width,
            sourceHeight: height
        )
        let widthFraction = displayRect.width / CGFloat(max(1, width))
        let heightFraction = displayRect.height / CGFloat(max(1, height))
        let centreX = displayRect.midX / CGFloat(max(1, width))
        let centreY = displayRect.midY / CGFloat(max(1, height))
        let borderContact =
            displayRect.minX <= 1 || displayRect.maxX >= CGFloat(width - 1)
            || displayRect.minY <= 1 || displayRect.maxY >= CGFloat(height - 1)
        var zoneWarnings: [String] = []
        if widthFraction > 0.90 { zoneWarnings.append("overwide") }
        if widthFraction < 0.20 { zoneWarnings.append("too-narrow") }
        if heightFraction < 0.28 { zoneWarnings.append("too-short") }
        if !(0.06...0.94).contains(centreX) { zoneWarnings.append("horizontal-edge") }
        if !(0.06...0.94).contains(centreY) { zoneWarnings.append("vertical-edge") }
        if borderContact { zoneWarnings.append("border-contact") }
        let zoneAudit =
            zoneWarnings.isEmpty
            ? "zoneAudit=pass"
            : "zoneAudit=warn[\(zoneWarnings.joined(separator: ","))]"
        let sourcePipeline = colourProfile.resolvedPipeline(for: key).shortTitle
        let measurementDiagnostic =
            (digitBand?.diagnostic ?? "digit-band-fallback=clean-alpha-envelope")
            + " " + timerEnvelope.diagnostic
            + " frameScrub=rows:\(removedRules.rows),columns:\(removedRules.columns)"
            + String(
                format: " mask=shared-clock-style no-colour-dominance no-pinhole %@ field=%@ sourceProfile=%@ fraction=%.2fx%.2f centre=%.2f,%.2f source=%dx%d bg=%d",
                zoneAudit,
                key.rawValue,
                sourcePipeline,
                widthFraction,
                heightFraction,
                centreX,
                centreY,
                width,
                height,
                mask.backgroundLuma
            )

        return DirectPenaltyTimerCandidate(
            fullZoneImage: presentationImage,
            proposedRect: displayRect,
            sourceWidth: width,
            sourceHeight: height,
            pipelineTitle: "clock-style-luminance",
            measurementDiagnostic: measurementDiagnostic,
            hasMeasuredDigitBand: digitBand != nil,
            activePercent: Double(presentationAlpha.filter { $0 >= 18 }.count) / Double(max(1, width * height)) * 100,
            maximumAlpha: Int(presentationAlpha.max() ?? 0)
        )
    }

    private static func renderDirectPenaltyTimerImage(
        _ candidate: DirectPenaltyTimerCandidate,
        displayRect: CGRect,
        lockedCharacterCentreX: CGFloat,
        stabilisationDiagnostic: String
    ) -> DirectPenaltyTimerImage? {
        let resolvedRect = boundedRelayRect(
            displayRect,
            sourceWidth: candidate.sourceWidth,
            sourceHeight: candidate.sourceHeight
        )
        guard let displayImage = candidate.fullZoneImage.cropping(to: resolvedRect) else {
            return nil
        }
        let fixedGlyphHeightEnabled = RinkLensRiskFeaturePolicy.isEnabled(.penaltyTimerFixedGlyphHeightV3)
        let contentRect: CGRect = {
            guard fixedGlyphHeightEnabled,
                  let visible = visibleAlphaBounds(in: displayImage) else {
                return CGRect(x: 0, y: 0, width: displayImage.width, height: displayImage.height)
            }
            let vertical = visible.insetBy(dx: 0, dy: -1).intersection(
                CGRect(x: 0, y: 0, width: displayImage.width, height: displayImage.height)
            ).integral
            // Build 715: preserve the activation-owned horizontal envelope.
            // Tight x-cropping around whichever digits are currently lit made
            // the timer appear to bounce left/right as digits changed.
            return CGRect(
                x: 0,
                y: vertical.minY,
                width: CGFloat(displayImage.width),
                height: vertical.height
            ).integral
        }()
        let contentImage = displayImage.cropping(to: contentRect) ?? displayImage
        let measuredWidth = contentImage.width
        let measuredHeight = contentImage.height
        // Build 703 keeps the outer timer canvas unchanged but gives every slot the
        // same authoritative illuminated height. The activation-owned character
        // centre is translated into the tight content crop, so Slot 2 cannot drift.
        let normalised = normalisedMeasuredDisplayImage(
            contentImage,
            canvasHeight: 100,
            horizontalSafetyFraction: 0.015,
            minimumCanvasAspect: BroadcastScorebugTemplateMetrics.resolvedPenaltyTimerWidthRatio(
                compact: RinkLensRiskFeaturePolicy.isEnabled(.compactPenaltyPanelV2)
            ),
            sourceCharacterCentreX: lockedCharacterCentreX - resolvedRect.minX - contentRect.minX,
            heightAuthoritative: fixedGlyphHeightEnabled
        )
        let publishedImage = normalised?.image ?? contentImage
        let normalisationDiagnostic = normalised?.diagnostic ?? "canvas-fallback=display-image"

        return DirectPenaltyTimerImage(
            image: publishedImage,
            diagnostic: String(
                format: "%@ direct-digit-band src=%dx%d measured=%dx%d crop=%dx%d published=%dx%d heightRef=%d %@ %@ %@ active=%.1f%% aMax=%d no-recognition no-zero-detection",
                candidate.pipelineTitle,
                candidate.sourceWidth,
                candidate.sourceHeight,
                measuredWidth,
                measuredHeight,
                contentImage.width,
                contentImage.height,
                publishedImage.width,
                publishedImage.height,
                measuredHeight,
                candidate.measurementDiagnostic + " horizontal=activation-envelope-locked",
                stabilisationDiagnostic,
                normalisationDiagnostic,
                candidate.activePercent,
                candidate.maximumAlpha
            )
        )
    }

    private static func boundedRelayRect(
        _ rect: CGRect,
        sourceWidth: Int,
        sourceHeight: Int
    ) -> CGRect {
        let x0 = max(0, min(sourceWidth - 1, Int(floor(rect.minX))))
        let y0 = max(0, min(sourceHeight - 1, Int(floor(rect.minY))))
        let x1 = max(x0 + 1, min(sourceWidth, Int(ceil(rect.maxX))))
        let y1 = max(y0 + 1, min(sourceHeight, Int(ceil(rect.maxY))))
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    private struct ExtractedGlyph {
        let image: CGImage
        let hash: UInt64
        let diagnostic: String
    }

    private struct GlyphExtractionOutcome {
        let glyph: ExtractedGlyph?
        let diagnostic: String
    }

    private struct RelayComponent {
        let pixels: [Int]
        let minX: Int
        let minY: Int
        let maxX: Int
        let maxY: Int

        var area: Int { pixels.count }
        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
        var centreX: Double { Double(minX + maxX) * 0.5 }
        var centreY: Double { Double(minY + maxY) * 0.5 }
    }

    private static func canonicalCanvasSize(for key: OCRRegionKey) -> (width: Int, height: Int) {
        switch key {
        case .clock:
            return (320, 92)
        case .homeScore, .awayScore:
            return (92, 92)
        case .period:
            return (64, 64)
        case .homePenalty1Player, .homePenalty2Player, .awayPenalty1Player, .awayPenalty2Player:
            return (112, 72)
        case .homePenalty1Time, .homePenalty2Time, .awayPenalty1Time, .awayPenalty2Time:
            return (184, 72)
        case .homeShots, .awayShots:
            return (92, 72)
        }
    }

    private static func hashGridSize(for key: OCRRegionKey) -> (width: Int, height: Int) {
        switch key {
        case .clock:
            return (64, 20)
        case .homeScore, .awayScore, .period:
            return (24, 24)
        case .homePenalty1Player, .homePenalty2Player, .awayPenalty1Player, .awayPenalty2Player:
            return (32, 20)
        case .homePenalty1Time, .homePenalty2Time, .awayPenalty1Time, .awayPenalty2Time:
            return (48, 20)
        case .homeShots, .awayShots:
            return (24, 20)
        }
    }

    private static func roundedUp(_ value: Int, multiple: Int) -> Int {
        guard multiple > 1 else { return value }
        return ((max(1, value) + multiple - 1) / multiple) * multiple
    }

    /// Hashes a fixed perceptual grid instead of the published pixel dimensions.
    /// This keeps overlay revisions stable when the camera grain or one-pixel
    /// component bounds move while still detecting a genuine digit transition.
    private static func stableGlyphHash(
        alpha: [UInt8],
        sourceWidth: Int,
        sourceHeight: Int,
        minX: Int,
        minY: Int,
        cropWidth: Int,
        cropHeight: Int,
        key: OCRRegionKey
    ) -> UInt64 {
        let grid = hashGridSize(for: key)
        var hash: UInt64 = 1469598103934665603
        for gy in 0..<grid.height {
            let y0 = minY + gy * cropHeight / grid.height
            let y1 = minY + max(1, (gy + 1) * cropHeight / grid.height)
            for gx in 0..<grid.width {
                let x0 = minX + gx * cropWidth / grid.width
                let x1 = minX + max(1, (gx + 1) * cropWidth / grid.width)
                var peak: UInt8 = 0
                var total = 0
                var count = 0
                for y in y0..<min(minY + cropHeight, y1) {
                    guard y >= 0, y < sourceHeight else { continue }
                    for x in x0..<min(minX + cropWidth, x1) {
                        guard x >= 0, x < sourceWidth else { continue }
                        let value = alpha[y * sourceWidth + x]
                        peak = max(peak, value)
                        total += Int(value)
                        count += 1
                    }
                }
                let average = count > 0 ? total / count : 0
                let combined = max(Int(peak) * 3 / 4, average)
                let quantized: UInt8 = combined < 20 ? 0 : UInt8(min(224, (combined / 32) * 32))
                hash ^= UInt64(quantized)
                hash &*= 1099511628211
            }
        }
        hash ^= UInt64(grid.width)
        hash &*= 1099511628211
        hash ^= UInt64(grid.height)
        hash &*= 1099511628211
        return hash
    }

    private static func isPenaltyPlayer(_ key: OCRRegionKey) -> Bool {
        switch key {
        case .homePenalty1Player, .homePenalty2Player, .awayPenalty1Player, .awayPenalty2Player:
            return true
        default:
            return false
        }
    }

    private static func connectedComponents(
        alpha: [UInt8],
        width: Int,
        height: Int,
        threshold: UInt8
    ) -> [RelayComponent] {
        guard width > 0, height > 0, alpha.count == width * height else { return [] }
        var visited = [UInt8](repeating: 0, count: alpha.count)
        var components: [RelayComponent] = []
        components.reserveCapacity(24)

        for seed in 0..<alpha.count where visited[seed] == 0 && alpha[seed] >= threshold {
            visited[seed] = 1
            var queue: [Int] = [seed]
            var head = 0
            var pixels: [Int] = []
            pixels.reserveCapacity(128)
            var minX = seed % width
            var maxX = minX
            var minY = seed / width
            var maxY = minY

            while head < queue.count {
                let index = queue[head]
                head += 1
                pixels.append(index)
                let x = index % width
                let y = index / width
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)

                let y0 = max(0, y - 1)
                let y1 = min(height - 1, y + 1)
                let x0 = max(0, x - 1)
                let x1 = min(width - 1, x + 1)
                for ny in y0...y1 {
                    for nx in x0...x1 where nx != x || ny != y {
                        let neighbour = ny * width + nx
                        guard visited[neighbour] == 0, alpha[neighbour] >= threshold else { continue }
                        visited[neighbour] = 1
                        queue.append(neighbour)
                    }
                }
            }

            components.append(
                RelayComponent(
                    pixels: pixels,
                    minX: minX,
                    minY: minY,
                    maxX: maxX,
                    maxY: maxY
                )
            )
        }
        return components
    }

    private static func frameLike(
        _ component: RelayComponent,
        width: Int,
        height: Int
    ) -> Bool {
        let widthFraction = Double(component.width) / Double(max(1, width))
        let heightFraction = Double(component.height) / Double(max(1, height))
        let edgeX = max(2, Int((Double(width) * 0.10).rounded()))
        let edgeY = max(2, Int((Double(height) * 0.12).rounded()))
        let touchesOuterBand = component.minX <= edgeX
            || component.maxX >= width - 1 - edgeX
            || component.minY <= edgeY
            || component.maxY >= height - 1 - edgeY
        let longHorizontal = widthFraction >= 0.52 && heightFraction <= 0.24
        let longVertical = heightFraction >= 0.52 && widthFraction <= 0.24
        let enclosingOutline = widthFraction >= 0.72
            && heightFraction >= 0.68
            && Double(component.area) / Double(max(1, component.width * component.height)) < 0.42
        return touchesOuterBand && (longHorizontal || longVertical || enclosingOutline)
    }


    /// Build 625 player-placeholder separator. The physical board paints dashes
    /// and dots in unused player cells, so "any illuminated pixel" cannot mean an
    /// active penalty. Real one/two-digit numbers contain strong vertical strokes
    /// spanning a substantial part of the crop; placeholder marks remain shallow.
    /// This is image geometry only and performs no character recognition.
    private static func penaltyPlayerDigitComponent(
        alpha: [UInt8],
        width: Int,
        height: Int
    ) -> RelayComponent? {
        guard width > 8, height > 8, alpha.count == width * height else { return nil }

        struct AxisRun {
            let first: Int
            let last: Int
            let activeCount: Int
            var span: Int { last - first + 1 }
            var centre: Double { Double(first + last) / 2.0 }
        }

        func clusteredRuns(_ indices: [Int], maximumGap: Int) -> [AxisRun] {
            guard let first = indices.first else { return [] }
            var runs: [AxisRun] = []
            var start = first
            var previous = first
            var activeCount = 1
            for value in indices.dropFirst() {
                if value - previous <= maximumGap + 1 {
                    previous = value
                    activeCount += 1
                } else {
                    runs.append(AxisRun(first: start, last: previous, activeCount: activeCount))
                    start = value
                    previous = value
                    activeCount = 1
                }
            }
            runs.append(AxisRun(first: start, last: previous, activeCount: activeCount))
            return runs
        }

        // Build 641 derives the player crop from a coherent digit band instead
        // of the first/last illuminated pixel in the whole calibration zone.
        // This rejects scoreboard box names above/below the digits and ignores
        // isolated frame strokes without requiring OCR.
        let strongThreshold: UInt8 = 78
        let retainedThreshold: UInt8 = 42
        let insetX = max(3, Int((Double(width) * 0.075).rounded()))
        let insetY = max(3, Int((Double(height) * 0.08).rounded()))
        let xUpper = max(insetX + 1, width - insetX)
        let yUpper = max(insetY + 1, height - insetY)
        let rowPixelGate = max(2, Int((Double(width) * 0.016).rounded()))
        let minimumVerticalSpan = max(10, Int((Double(height) * 0.30).rounded()))
        let minimumActiveRows = max(6, Int((Double(height) * 0.15).rounded()))

        // Remove persistent vertical field edges before deriving row bands. A
        // captured box edge can otherwise bridge a short label above the digits
        // into one artificially tall component and corrupt visible-height sizing.
        var fullColumnCounts = [Int](repeating: 0, count: width)
        for x in insetX..<xUpper {
            var count = 0
            for y in insetY..<yUpper where alpha[y * width + x] >= strongThreshold {
                count += 1
            }
            fullColumnCounts[x] = count
        }
        let verticalCoverageGate = max(
            minimumVerticalSpan,
            Int((Double(max(1, yUpper - insetY)) * 0.72).rounded(.up))
        )
        let excludedEdgeColumns = Set(fullColumnCounts.indices.filter { x in
            guard fullColumnCounts[x] >= verticalCoverageGate else { return false }
            let centreFraction = Double(x) / Double(max(1, width - 1))
            return centreFraction < 0.12 || centreFraction > 0.88
        })

        var rowCounts = [Int](repeating: 0, count: height)
        for y in insetY..<yUpper {
            var count = 0
            for x in insetX..<xUpper
            where !excludedEdgeColumns.contains(x)
                && alpha[y * width + x] >= strongThreshold {
                count += 1
            }
            rowCounts[y] = count
        }
        // Broad top/bottom frame strokes are not glyph rows. Keep this threshold
        // deliberately high so genuine digit crossbars remain untouched.
        let horizontalCoverageGate = max(
            rowPixelGate + 1,
            Int((Double(max(1, xUpper - insetX - excludedEdgeColumns.count)) * 0.72).rounded(.up))
        )
        let excludedFrameRows = Set(rowCounts.indices.filter { y in
            guard rowCounts[y] >= horizontalCoverageGate else { return false }
            let centreFraction = Double(y) / Double(max(1, height - 1))
            return centreFraction < 0.20 || centreFraction > 0.80
        })
        let activeRows = rowCounts.indices.filter {
            rowCounts[$0] >= rowPixelGate && !excludedFrameRows.contains($0)
        }
        let rowRuns = clusteredRuns(activeRows, maximumGap: 2).filter {
            $0.span >= minimumVerticalSpan && $0.activeCount >= minimumActiveRows
        }
        guard !rowRuns.isEmpty else { return nil }

        let imageCentreY = Double(height - 1) / 2.0
        let selectedRows = rowRuns.max { lhs, rhs in
            let lhsMass = rowCounts[lhs.first...lhs.last].reduce(0, +)
            let rhsMass = rowCounts[rhs.first...rhs.last].reduce(0, +)
            let lhsCentrePenalty = abs(lhs.centre - imageCentreY)
            let rhsCentrePenalty = abs(rhs.centre - imageCentreY)
            let lhsScore = Double(lhsMass * 5 + lhs.span * rowPixelGate) - lhsCentrePenalty * 1.5
            let rhsScore = Double(rhsMass * 5 + rhs.span * rowPixelGate) - rhsCentrePenalty * 1.5
            return lhsScore < rhsScore
        }!

        let bandPadding = max(1, height / 40)
        let bandY0 = max(insetY, selectedRows.first - bandPadding)
        let bandY1 = min(height - 1 - insetY, selectedRows.last + bandPadding)
        let bandHeight = bandY1 - bandY0 + 1
        guard bandHeight >= minimumVerticalSpan else { return nil }

        // Establish a horizontal digit envelope inside the chosen vertical band.
        // A long box edge can be tall, but it remains a narrow off-centre run and
        // is rejected. Legitimate one-digit players remain valid when central.
        var columnCounts = [Int](repeating: 0, count: width)
        for x in insetX..<xUpper where !excludedEdgeColumns.contains(x) {
            var count = 0
            for y in bandY0...bandY1
            where !excludedFrameRows.contains(y)
                && alpha[y * width + x] >= strongThreshold {
                count += 1
            }
            columnCounts[x] = count
        }
        let columnPixelGate = max(2, Int((Double(bandHeight) * 0.055).rounded()))
        let activeColumns = columnCounts.indices.filter { columnCounts[$0] >= columnPixelGate }
        let minimumRunWidth = max(3, Int((Double(width) * 0.028).rounded()))
        let narrowRunWidth = max(4, Int((Double(width) * 0.055).rounded()))
        let plausibleRuns = clusteredRuns(activeColumns, maximumGap: 1).filter { run in
            guard run.span >= minimumRunWidth else { return false }
            let centreFraction = run.centre / Double(max(1, width - 1))
            if run.span <= narrowRunWidth && (centreFraction < 0.28 || centreFraction > 0.72) {
                return false
            }
            return centreFraction >= 0.08 && centreFraction <= 0.92
        }
        guard !plausibleRuns.isEmpty else { return nil }

        let masses = plausibleRuns.map { columnCounts[$0.first...$0.last].reduce(0, +) }
        let dominantMass = masses.max() ?? 0
        let meaningfulRuns = zip(plausibleRuns, masses).compactMap { run, mass in
            mass >= max(3, dominantMass / 18) ? run : nil
        }
        guard !meaningfulRuns.isEmpty else { return nil }

        // Build 736: retain both digits even when one outer vertical stroke is
        // weak or momentarily multiplexed. Expansion is based on both source axes
        // and may extend into the calibration safety inset; only proven straight
        // frame columns remain excluded below.
        let horizontalExpansion = max(
            4,
            Int((Double(height) * 0.10).rounded()),
            Int((Double(width) * 0.045).rounded())
        )
        let x0 = max(0, (meaningfulRuns.map(\.first).min() ?? insetX) - horizontalExpansion)
        let x1 = min(width - 1, (meaningfulRuns.map(\.last).max() ?? width - 1 - insetX) + horizontalExpansion)
        guard x1 >= x0 else { return nil }

        var pixels: [Int] = []
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in bandY0...bandY1 where !excludedFrameRows.contains(y) {
            for x in x0...x1 where !excludedEdgeColumns.contains(x) {
                let index = y * width + x
                guard alpha[index] >= retainedThreshold else { continue }
                pixels.append(index)
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard !pixels.isEmpty, maxX >= minX, maxY >= minY else { return nil }

        let resolvedHeight = maxY - minY + 1
        let resolvedWidth = maxX - minX + 1
        let minimumArea = max(8, width * height / 1_000)
        guard resolvedHeight >= minimumVerticalSpan,
              resolvedWidth >= max(2, width / 30),
              pixels.count >= minimumArea else { return nil }

        return RelayComponent(
            pixels: pixels,
            minX: minX,
            minY: minY,
            maxX: maxX,
            maxY: maxY
        )
    }

    /// Removes only long straight rules attached to the outer calibration edge.
    /// It deliberately runs before player component selection so a box outline that
    /// touches a digit cannot become one giant player component. Ordinary digit
    /// segments are retained because they do not span both outer sides of the saved
    /// zone or the full top/bottom edge bands.
    private static func suppressPenaltyPlayerEdgeRules(
        alpha: inout [UInt8],
        width: Int,
        height: Int,
        threshold: UInt8 = 44
    ) -> (rows: Int, columns: Int) {
        guard width > 8, height > 8, alpha.count == width * height else {
            return (0, 0)
        }

        let yBand = max(2, Int((Double(height) * 0.12).rounded()))
        let xBand = max(2, Int((Double(width) * 0.10).rounded()))
        let sideProbe = max(2, Int((Double(width) * 0.07).rounded()))
        let verticalProbe = max(2, Int((Double(height) * 0.08).rounded()))
        var rows = Set<Int>()
        var columns = Set<Int>()

        let candidateRows = Array(0..<min(height, yBand))
            + Array(max(0, height - yBand)..<height)
        for y in candidateRows {
            var active = 0
            var left = false
            var right = false
            for x in 0..<width where alpha[y * width + x] >= threshold {
                active += 1
                if x < sideProbe { left = true }
                if x >= width - sideProbe { right = true }
            }
            let fraction = Double(active) / Double(max(1, width))
            if (left && right && fraction >= 0.34)
                || ((left || right) && fraction >= 0.58)
                || fraction >= 0.82 {
                rows.insert(y)
            }
        }

        let candidateColumns = Array(0..<min(width, xBand))
            + Array(max(0, width - xBand)..<width)
        for x in candidateColumns {
            var active = 0
            var top = false
            var bottom = false
            for y in 0..<height where alpha[y * width + x] >= threshold {
                active += 1
                if y < verticalProbe { top = true }
                if y >= height - verticalProbe { bottom = true }
            }
            let fraction = Double(active) / Double(max(1, height))
            if (top && bottom && fraction >= 0.72)
                || ((top || bottom) && fraction >= 0.88)
                || fraction >= 0.94 {
                columns.insert(x)
            }
        }

        let rowErase = Set(rows.flatMap { y in
            max(0, y - 1)...min(height - 1, y + 1)
        })
        let columnErase = Set(columns.flatMap { x in
            max(0, x - 1)...min(width - 1, x + 1)
        })
        if !rowErase.isEmpty || !columnErase.isEmpty {
            for y in 0..<height {
                for x in 0..<width where rowErase.contains(y) || columnErase.contains(x) {
                    alpha[y * width + x] = 0
                }
            }
        }
        return (rows.count, columns.count)
    }

    /// Build 569 keeps the soft Raw-zone pixels but removes physical field frames
    /// before publishing. It then isolates only the meaningful illuminated glyph
    /// components, applies tighter field-specific padding, and publishes a fully
    /// transparent output image with the scoreboard lines/background removed.
    /// Period favours the single dominant digit, while score fields suppress tiny
    /// stray components so the visible glyph occupies more of the scorebug cell.
    private static func extractIlluminatedGlyphs(
        from image: CGImage,
        key: OCRRegionKey,
        colourProfile: OCRZoneColourProfile
    ) -> GlyphExtractionOutcome {
        let width = image.width
        let height = image.height
        guard width > 4, height > 4 else {
            return GlyphExtractionOutcome(glyph: nil, diagnostic: "crop-too-small-\(width)x\(height)")
        }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        var source = [UInt8](repeating: 0, count: bytesPerRow * height)
        let sourceOK = source.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: bitmapInfo
                  ) else { return false }
            context.interpolationQuality = .high
            context.setShouldAntialias(true)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard sourceOK else {
            return GlyphExtractionOutcome(glyph: nil, diagnostic: "source-render-failed")
        }

        struct PixelSample {
            let luma: Int
            let r: Int
            let g: Int
            let b: Int
        }

        let pipeline = colourProfile.resolvedPipeline(for: key)
        let sampleStride = max(2, min(width, height) / 32)
        var samples: [PixelSample] = []
        samples.reserveCapacity((width / sampleStride + 1) * (height / sampleStride + 1))
        for y in Swift.stride(from: 0, to: height, by: sampleStride) {
            for x in Swift.stride(from: 0, to: width, by: sampleStride) {
                let index = y * bytesPerRow + x * bytesPerPixel
                let r = Int(source[index])
                let g = Int(source[index + 1])
                let b = Int(source[index + 2])
                samples.append(PixelSample(luma: (77 * r + 150 * g + 29 * b) >> 8, r: r, g: g, b: b))
            }
        }
        guard !samples.isEmpty else {
            return GlyphExtractionOutcome(glyph: nil, diagnostic: "no-background-samples")
        }
        samples.sort { $0.luma < $1.luma }

        let useLightBackground = pipeline == .darkOnLight || colourProfile.backgroundColour.isLight
        let modelCount = max(8, samples.count / 3)
        let modelSamples: ArraySlice<PixelSample>
        if useLightBackground {
            modelSamples = samples.suffix(modelCount)
        } else {
            modelSamples = samples.prefix(modelCount)
        }

        func median(_ values: [Int]) -> Int {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }

        let bgR = median(modelSamples.map { $0.r })
        let bgG = median(modelSamples.map { $0.g })
        let bgB = median(modelSamples.map { $0.b })
        let bgLuma = (77 * bgR + 150 * bgG + 29 * bgB) >> 8

        func illuminationSignal(r: Int, g: Int, b: Int) -> Int {
            let luma = (77 * r + 150 * g + 29 * b) >> 8
            let lift = luma - bgLuma
            let drop = bgLuma - luma
            let high = max(r, max(g, b))
            let low = min(r, min(g, b))
            let chroma = high - low
            let distance = max(abs(r - bgR), max(abs(g - bgG), abs(b - bgB)))

            switch pipeline {
            case .redOnBlack:
                let redLift = max(0, r - bgR)
                let dominance = max(0, r - max(g, b))
                let colourGate = min(1.0, Double(dominance + chroma / 2) / 42.0)
                let base = redLift * 2 + dominance * 4 + max(0, lift)
                return Int(Double(max(0, base)) * max(0.06, colourGate))

            case .yellowWhiteOnBlack:
                let yellowLift = min(r, g) - min(bgR, bgG)
                let yellowDominance = min(r, g) - b
                let yellow = max(0, yellowLift * 2 + yellowDominance * 3 + max(0, lift))
                let white = max(0, lift * 3 + max(0, 42 - chroma))
                return max(yellow, white)

            case .amberOrangeOnBlack:
                let redLift = r - bgR
                let greenLift = g - bgG
                let amberDominance = r - b
                return max(0, redLift + greenLift + amberDominance * 3 + max(0, lift))

            case .greenOnBlack:
                let greenLift = g - bgG
                let dominance = g - max(r, b)
                return max(0, greenLift * 2 + dominance * 3 + max(0, lift))

            case .blueCyanOnBlack:
                let blueLift = b - bgB
                let greenLift = g - bgG
                let blueDominance = b - max(r, g)
                let cyanDominance = min(g, b) - r
                return max(0, max(blueLift, greenLift) * 2 + max(blueDominance, cyanDominance) * 3 + max(0, lift))

            case .lightOnDark:
                return max(0, lift * 3 + distance)

            case .darkOnLight:
                return max(0, drop * 3 + distance)

            case .greyscale, .auto:
                let directional = colourProfile.backgroundColour.isLight ? drop : lift
                return max(0, directional * 3 + distance)
            }
        }

        let softStart: Double
        let softEnd: Double
        switch pipeline {
        case .redOnBlack, .yellowWhiteOnBlack, .amberOrangeOnBlack, .greenOnBlack, .blueCyanOnBlack:
            softStart = 18
            softEnd = 150
        case .lightOnDark, .darkOnLight:
            softStart = 22
            softEnd = 170
        case .greyscale, .auto:
            softStart = 26
            softEnd = 180
        }

        var alpha = [UInt8](repeating: 0, count: width * height)
        var maximumAlpha: UInt8 = 0
        for y in 0..<height {
            for x in 0..<width {
                let sourceIndex = y * bytesPerRow + x * bytesPerPixel
                let signal = Double(illuminationSignal(
                    r: Int(source[sourceIndex]),
                    g: Int(source[sourceIndex + 1]),
                    b: Int(source[sourceIndex + 2])
                ))
                let normalized = max(0, min(1, (signal - softStart) / max(1, softEnd - softStart)))
                let value = UInt8(max(0, min(255, Int((pow(normalized, 0.72) * 255).rounded()))))
                alpha[y * width + x] = value
                maximumAlpha = max(maximumAlpha, value)
            }
        }

        guard maximumAlpha >= 36 else {
            return GlyphExtractionOutcome(
                glyph: nil,
                diagnostic: "no-illuminated-signal aMax=\(maximumAlpha) bg=\(bgR),\(bgG),\(bgB)"
            )
        }

        var edgeRuleDiagnostic = "edgeRules=none"
        if isPenaltyPlayer(key) {
            let removed = suppressPenaltyPlayerEdgeRules(
                alpha: &alpha,
                width: width,
                height: height
            )
            maximumAlpha = alpha.max() ?? 0
            edgeRuleDiagnostic = "edgeRules=rows:\(removed.rows),columns:\(removed.columns)"
            guard maximumAlpha >= 36 else {
                return GlyphExtractionOutcome(
                    glyph: nil,
                    diagnostic: "player-edge-rules-only \(edgeRuleDiagnostic)"
                )
            }
        }

        // Build 574 fixed-cell Image Relay for Home/Away Score and Period.
        //
        // The saved zone geometry is already perspective-corrected and rotated
        // by ScoreboardOCRProcessor before this method is called. Keep that
        // fixed geometry instead of re-detecting live illuminated bounds. This
        // prevents per-frame size pulsing and preserves the operator's saved
        // straightening angle. The native crop is published directly, with no
        // intermediate nearest-neighbour enlargement.
        if key == .homeScore || key == .awayScore || key == .period {
            let insetXFraction = key == .period ? 0.08 : 0.035
            let insetYFraction = key == .period ? 0.025 : 0.035
            let minX = max(0, Int((Double(width) * insetXFraction).rounded()))
            let maxX = min(width - 1, width - 1 - minX)
            let minY = max(0, Int((Double(height) * insetYFraction).rounded()))
            let maxY = min(height - 1, height - 1 - minY)
            let cropWidth = maxX - minX + 1
            let cropHeight = maxY - minY + 1
            guard cropWidth > 2, cropHeight > 2 else {
                return GlyphExtractionOutcome(glyph: nil, diagnostic: "fixed-cell-invalid-\(cropWidth)x\(cropHeight)")
            }

            // Mild cross-neighbour alpha bridging joins the visible dots of an
            // LED segment before the one final display-size reduction. It does
            // not classify digits or change geometry, and it avoids the
            // magnified ring/"doughnut" appearance created by the previous
            // nearest-neighbour upscaling path.
            var bridgedAlpha = alpha
            if cropWidth >= 5, cropHeight >= 5 {
                for y in (minY + 1)..<maxY {
                    for x in (minX + 1)..<maxX {
                        let index = y * width + x
                        let neighbourMaximum = max(
                            alpha[index],
                            max(
                                alpha[index - 1],
                                max(
                                    alpha[index + 1],
                                    max(alpha[index - width], alpha[index + width])
                                )
                            )
                        )
                        let bridged = UInt8(
                            max(
                                Int(alpha[index]),
                                Int((Double(neighbourMaximum) * 0.72).rounded())
                            )
                        )
                        bridgedAlpha[index] = bridged
                    }
                }
            }

            let outputBytesPerRow = cropWidth * 4
            var output = [UInt8](repeating: 0, count: outputBytesPerRow * cropHeight)
            var activeCount = 0
            var strongCount = 0
            var normalizedMaximum: UInt8 = 0

            for y in 0..<cropHeight {
                for x in 0..<cropWidth {
                    let sourceAlpha = bridgedAlpha[(minY + y) * width + minX + x]
                    let value: UInt8
                    if sourceAlpha < 16 {
                        value = 0
                    } else {
                        let normalized = Double(Int(sourceAlpha) - 16) / 239.0
                        value = UInt8(max(0, min(255, Int((pow(normalized, 1.04) * 255).rounded()))))
                    }
                    let index = y * outputBytesPerRow + x * 4
                    output[index] = value
                    output[index + 1] = value
                    output[index + 2] = value
                    output[index + 3] = value
                    normalizedMaximum = max(normalizedMaximum, value)
                    if value >= 16 { activeCount += 1 }
                    if value >= 88 { strongCount += 1 }
                }
            }

            guard normalizedMaximum >= 36,
                  activeCount >= max(5, cropWidth * cropHeight / 3_200),
                  strongCount >= max(2, cropWidth * cropHeight / 10_000) else {
                return GlyphExtractionOutcome(
                    glyph: nil,
                    diagnostic: "fixed-cell-too-weak aMax=\(normalizedMaximum) active=\(activeCount) strong=\(strongCount)"
                )
            }

            let hash = stableGlyphHash(
                alpha: bridgedAlpha,
                sourceWidth: width,
                sourceHeight: height,
                minX: minX,
                minY: minY,
                cropWidth: cropWidth,
                cropHeight: cropHeight,
                key: key
            )
            guard let provider = CGDataProvider(data: Data(output) as CFData),
                  let published = CGImage(
                    width: cropWidth,
                    height: cropHeight,
                    bitsPerComponent: 8,
                    bitsPerPixel: 32,
                    bytesPerRow: outputBytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
                        CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                    ),
                    provider: provider,
                    decode: nil,
                    shouldInterpolate: true,
                    intent: .defaultIntent
                  ) else {
                return GlyphExtractionOutcome(glyph: nil, diagnostic: "fixed-cell-image-create-failed")
            }

            let label = key == .period ? "period" : "score"
            let diagnostic = String(
                format: "%@ fixed-native-%@ active=%.1f%% strong=%.1f%% src=%dx%d fixed=%dx%d+%d,%d aMax=%d bridge=0.72",
                pipeline.shortTitle,
                label,
                Double(activeCount) / Double(max(1, cropWidth * cropHeight)) * 100,
                Double(strongCount) / Double(max(1, cropWidth * cropHeight)) * 100,
                width,
                height,
                cropWidth,
                cropHeight,
                minX,
                minY,
                Int(normalizedMaximum)
            )
            return GlyphExtractionOutcome(
                glyph: ExtractedGlyph(image: published, hash: hash, diagnostic: diagnostic),
                diagnostic: diagnostic
            )
        }

        let initialComponents = connectedComponents(
            alpha: alpha,
            width: width,
            height: height,
            threshold: 44
        )
        let frameComponents = initialComponents.filter { frameLike($0, width: width, height: height) }
        if !frameComponents.isEmpty {
            var erase = [UInt8](repeating: 0, count: alpha.count)
            for component in frameComponents {
                for index in component.pixels {
                    let x = index % width
                    let y = index / width
                    for ny in max(0, y - 2)...min(height - 1, y + 2) {
                        for nx in max(0, x - 2)...min(width - 1, x + 2) {
                            erase[ny * width + nx] = 1
                        }
                    }
                }
            }
            for index in alpha.indices where erase[index] != 0 {
                alpha[index] = 0
            }
        }

        let components = connectedComponents(
            alpha: alpha,
            width: width,
            height: height,
            threshold: 30
        ).filter { $0.area >= 2 }

        guard let dominantHeight = components.map(\.height).max(),
              let dominantArea = components.map(\.area).max() else {
            return GlyphExtractionOutcome(
                glyph: nil,
                diagnostic: "no-content-after-frame-removal frames=\(frameComponents.count)"
            )
        }

        let minimumHeight = max(4, max(Int((Double(height) * 0.18).rounded()), Int((Double(dominantHeight) * 0.46).rounded())))
        let minimumArea = max(3, dominantArea / 22)
        let centralMinX = Double(width) * 0.07
        let centralMaxX = Double(width) * 0.93
        let candidateMeaningful = components.filter { component in
            component.height >= minimumHeight
                && component.area >= minimumArea
                && component.centreX >= centralMinX
                && component.centreX <= centralMaxX
        }
        let meaningful: [RelayComponent]
        switch key {
        case .period:
            meaningful = candidateMeaningful.max(by: { $0.area < $1.area }).map { [$0] } ?? []
        case .homeScore, .awayScore:
            let dominant = candidateMeaningful.map(\.area).max() ?? 0
            meaningful = candidateMeaningful
                .filter { $0.area >= max(3, dominant / 6) }
                .sorted { lhs, rhs in
                    if lhs.area == rhs.area { return lhs.minX < rhs.minX }
                    return lhs.area > rhs.area
                }
                .prefix(3)
                .map { $0 }
        case .homePenalty1Player, .homePenalty2Player, .awayPenalty1Player, .awayPenalty2Player:
            meaningful = penaltyPlayerDigitComponent(
                alpha: alpha,
                width: width,
                height: height
            ).map { [$0] } ?? []
        default:
            meaningful = candidateMeaningful
        }

        if isPenaltyPlayer(key), meaningful.isEmpty {
            return GlyphExtractionOutcome(
                glyph: nil,
                diagnostic: "blank-player-placeholder-only comps=\(components.count) frames=\(frameComponents.count) no-tall-digit-stroke"
            )
        }
        guard !meaningful.isEmpty else {
            return GlyphExtractionOutcome(
                glyph: nil,
                diagnostic: "no-tall-glyph comps=\(components.count) dominantH=\(dominantHeight) frames=\(frameComponents.count)"
            )
        }

        var minX = meaningful.map(\.minX).min() ?? 0
        var minY = meaningful.map(\.minY).min() ?? 0
        var maxX = meaningful.map(\.maxX).max() ?? width - 1
        var maxY = meaningful.map(\.maxY).max() ?? height - 1
        let contentWidth = maxX - minX + 1
        let contentHeight = maxY - minY + 1
        let paddingFractions: (x: Double, y: Double)
        switch key {
        case .period:
            paddingFractions = (0.03, 0.05)
        case .homeScore, .awayScore:
            paddingFractions = (0.04, 0.06)
        case .homePenalty1Player, .homePenalty2Player, .awayPenalty1Player, .awayPenalty2Player:
            paddingFractions = (0.04, 0.08)
        case .homePenalty1Time, .homePenalty2Time, .awayPenalty1Time, .awayPenalty2Time:
            paddingFractions = (0.05, 0.10)
        case .clock:
            paddingFractions = (0.06, 0.10)
        case .homeShots, .awayShots:
            paddingFractions = (0.05, 0.08)
        }
        let padX = max(1, Int((Double(contentWidth) * paddingFractions.x).rounded()))
        let padY = max(1, Int((Double(contentHeight) * paddingFractions.y).rounded()))
        minX = max(0, minX - padX)
        maxX = min(width - 1, maxX + padX)
        minY = max(0, minY - padY)
        maxY = min(height - 1, maxY + padY)

        let cropWidth = maxX - minX + 1
        let cropHeight = maxY - minY + 1
        guard cropWidth > 1, cropHeight > 1 else {
            return GlyphExtractionOutcome(glyph: nil, diagnostic: "invalid-content-bounds")
        }

        let canonical = canonicalCanvasSize(for: key)
        let targetAspect = Double(canonical.width) / Double(max(1, canonical.height))
        let cropAspect = Double(cropWidth) / Double(max(1, cropHeight))

        // Preserve the glyph at its native crop resolution. The published image
        // is only padded to the scorebug field aspect ratio; no bilinear resize
        // occurs here. SwiftUI/recording therefore performs the one and only
        // display-size resample. Quantised canvas dimensions also reduce pulse
        // from one-pixel component-bound movement.
        var canvasWidth = cropWidth
        var canvasHeight = cropHeight
        if cropAspect < targetAspect {
            canvasWidth = max(cropWidth, Int(ceil(Double(cropHeight) * targetAspect)))
        } else {
            canvasHeight = max(cropHeight, Int(ceil(Double(cropWidth) / targetAspect)))
        }
        canvasWidth = roundedUp(canvasWidth, multiple: 4)
        canvasHeight = roundedUp(canvasHeight, multiple: 4)
        let offsetX = max(0, (canvasWidth - cropWidth) / 2)
        let offsetY = max(0, (canvasHeight - cropHeight) / 2)

        let outputBytesPerRow = canvasWidth * 4
        var output = [UInt8](repeating: 0, count: outputBytesPerRow * canvasHeight)
        var activeCount = 0
        var strongCount = 0
        var normalizedMaximum: UInt8 = 0

        func sharpenedAlpha(_ value: UInt8) -> UInt8 {
            let sourceFloor: UInt8 = isPenaltyPlayer(key) ? 66 : 18
            guard value >= sourceFloor else { return 0 }
            let range = max(1, 255 - Int(sourceFloor))
            let normalized = Double(Int(value) - Int(sourceFloor)) / Double(range)
            let exponent = isPenaltyPlayer(key) ? 1.08 : 1.18
            let sharpened = pow(max(0, min(1, normalized)), exponent)
            return UInt8(max(0, min(255, Int((sharpened * 255).rounded()))))
        }

        for sourceY in 0..<cropHeight {
            for sourceX in 0..<cropWidth {
                let value = sharpenedAlpha(alpha[(minY + sourceY) * width + minX + sourceX])
                let outputX = offsetX + sourceX
                let outputY = offsetY + sourceY
                let outputIndex = outputY * outputBytesPerRow + outputX * 4
                output[outputIndex] = value
                output[outputIndex + 1] = value
                output[outputIndex + 2] = value
                output[outputIndex + 3] = value
                normalizedMaximum = max(normalizedMaximum, value)
                if value >= 18 { activeCount += 1 }
                if value >= 96 { strongCount += 1 }
            }
        }

        let hash = stableGlyphHash(
            alpha: alpha,
            sourceWidth: width,
            sourceHeight: height,
            minX: minX,
            minY: minY,
            cropWidth: cropWidth,
            cropHeight: cropHeight,
            key: key
        )

        guard normalizedMaximum >= 36,
              activeCount >= max(6, canvasWidth * canvasHeight / 2_400),
              strongCount >= max(2, canvasWidth * canvasHeight / 7_500) else {
            return GlyphExtractionOutcome(
                glyph: nil,
                diagnostic: "normalized-glyph-too-weak aMax=\(normalizedMaximum) active=\(activeCount) strong=\(strongCount)"
            )
        }

        guard let provider = CGDataProvider(data: Data(output) as CFData),
              let published = CGImage(
                width: canvasWidth,
                height: canvasHeight,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: outputBytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
                    CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            return GlyphExtractionOutcome(glyph: nil, diagnostic: "published-image-create-failed")
        }

        let totalPixels = canvasWidth * canvasHeight
        let diagnostic = String(
            format: "%@ native-glyph active=%.1f%% strong=%.1f%% src=%dx%d bounds=%dx%d+%d,%d canvas=%dx%d comps=%d frames=%d aMax=%d",
            pipeline.shortTitle,
            Double(activeCount) / Double(totalPixels) * 100,
            Double(strongCount) / Double(totalPixels) * 100,
            width,
            height,
            cropWidth,
            cropHeight,
            minX,
            minY,
            canvasWidth,
            canvasHeight,
            meaningful.count,
            frameComponents.count,
            Int(normalizedMaximum)
        ) + " " + edgeRuleDiagnostic
        return GlyphExtractionOutcome(
            glyph: ExtractedGlyph(image: published, hash: hash, diagnostic: diagnostic),
            diagnostic: diagnostic
        )
    }

}

struct ScoreboardImageRelayPenaltyPair {
    /// Viewer-facing player number. Build 621 renders this physical Image Relay
    /// glyph and never substitutes live OCR text into the scorebug.
    let playerImage: CGImage?
    /// Metadata/debug fallback retained for lifecycle diagnostics only.
    let player: String?
    let time: CGImage?

    var active: Bool { playerImage != nil }
}

extension ScoreboardImageRelaySnapshot {
    func penaltyPair(side: Team, slot: Int) -> ScoreboardImageRelayPenaltyPair {
        let physicalPairs: [(player: OCRRegionKey, timer: OCRRegionKey)] = side == .home
            ? [(.homePenalty1Player, .homePenalty1Time), (.homePenalty2Player, .homePenalty2Time)]
            : [(.awayPenalty1Player, .awayPenalty1Time), (.awayPenalty2Player, .awayPenalty2Time)]

        // Build 636 keeps each physical slot independently visible. Equal image
        // hashes are valid when the same player number has two simultaneous
        // penalties; visual hash deduplication must never collapse Slot 2.
        var compacted: [ScoreboardImageRelayPenaltyPair] = []
        for physical in physicalPairs {
            let playerImage = image(for: physical.player)
            guard playerImage != nil else { continue }
            // Recognised identity remains metadata and can never become a
            // live-scorebug fallback.
            compacted.append(
                ScoreboardImageRelayPenaltyPair(
                    playerImage: playerImage,
                    player: nil,
                    time: image(for: physical.timer)
                )
            )
        }

        let index = max(0, slot - 1)
        guard compacted.indices.contains(index) else {
            return ScoreboardImageRelayPenaltyPair(playerImage: nil, player: nil, time: nil)
        }
        return compacted[index]
    }

    private static func stableRelayTextHash(_ value: String) -> UInt64 {
        value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

}
#endif
