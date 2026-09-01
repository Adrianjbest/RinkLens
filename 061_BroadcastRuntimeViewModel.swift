// BUILD 699 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import UIKit
import Combine

// MARK: - v0.8.8m14 Broadcast runtime bridge

/// Small Broadcast-only bridge.
///
/// v0.8.8m14 moves the accepted overlay display values into
/// BroadcastOverlayState. This runtime object remains as a low-risk bridge for
/// the existing BroadcastView so no layout, camera preview, recording, media
/// browser or overlay rendering code has to change in this phase.
@MainActor
final class BroadcastRuntimeViewModel: ObservableObject {
    /// Recovery AV: runtime presentation is session-local. A new Broadcast runtime
    /// starts empty and is populated only from the current authoritative overlay
    /// snapshot; a previous route/profile can never seed the visible scorebug.
    @Published private(set) var snapshot: BroadcastRuntimeSnapshot

    private weak var source: HockeyScoreboardViewModel?
    private var ancillaryRefreshTask: Task<Void, Never>?
    private var presentationClockTask: Task<Void, Never>?
    private var overlayCancellable: AnyCancellable?
    private var imageRelayPresentationCancellable: AnyCancellable?
    private var recordingPresentationCancellable: AnyCancellable?
    private var streamPresentationCancellable: AnyCancellable?
    private var authoritativeOverlaySnapshot: BroadcastOverlaySnapshot = .empty
    private var authoritativeClockSeconds: Int?
    private var authoritativeClockChangedAt: CFAbsoluteTime = 0
    private var presentationClockSeconds: Int?
    private var lastRefreshUptimeNanoseconds: UInt64 = 0
    private let minimumRefreshIntervalNanoseconds: UInt64 = 250_000_000
    // Build 527: the presentation may coast for three seconds between trusted
    // physical-board anchors. It never writes the estimate into MatchState and
    // never moves against the direction owned by the trusted Clock authority.
    private let maximumPresentationHoldoverSeconds: CFTimeInterval = 3.4
    private let maximumPresentationTicks = 3
    private let presentationClockPollNanoseconds: UInt64 = 200_000_000
    private(set) var coalescedRefreshCount: Int = 0
    private var presentationActive = false

    init() {
        self.snapshot = .empty
    }

    deinit {
        ancillaryRefreshTask?.cancel()
        presentationClockTask?.cancel()
        overlayCancellable?.cancel()
        imageRelayPresentationCancellable?.cancel()
        recordingPresentationCancellable?.cancel()
        streamPresentationCancellable?.cancel()
    }

    /// Bind the lightweight presentation projection for the lifetime of the
    /// persistent Broadcast host. This does not start capture, rendering, OCR or
    /// a presentation clock. It only keeps the latest authoritative value ready
    /// so the first visible Broadcast transaction cannot start from `.empty`.
    func bind(source: HockeyScoreboardViewModel) {
        if self.source !== source {
            ancillaryRefreshTask?.cancel()
            ancillaryRefreshTask = nil
            presentationClockTask?.cancel()
            presentationClockTask = nil
            overlayCancellable?.cancel()
            overlayCancellable = nil
            imageRelayPresentationCancellable?.cancel()
            imageRelayPresentationCancellable = nil
            recordingPresentationCancellable?.cancel()
            recordingPresentationCancellable = nil
            streamPresentationCancellable?.cancel()
            streamPresentationCancellable = nil
            presentationActive = false
        }
        self.source = source

        source.refreshBroadcastOverlayState()
        applyOverlaySnapshot(source.broadcastOverlayState.snapshot, reason: "persistent-host-bind", forcePublish: true)
        if overlayCancellable == nil {
            overlayCancellable = source.broadcastOverlayState.$snapshot
                .removeDuplicates()
                .sink { [weak self] next in
                    self?.applyOverlaySnapshot(next, reason: "push")
                }
        }
        if imageRelayPresentationCancellable == nil {
            // Recovery BJ / RL-147: the Image Relay store is the physical viewer-
            // image owner. Its revision acknowledgement must directly refresh the
            // retained Broadcast projection; waiting for unrelated movement
            // metadata or ancillary polling coalesced several Clock frames for up
            // to three seconds in the 21:28 run.
            imageRelayPresentationCancellable = ScoreboardImageRelayPresentation.shared.$revision
                .removeDuplicates()
                .dropFirst()
                .sink { [weak self] _ in
                    guard let self, let source = self.source else { return }
                    source.refreshBroadcastOverlayState()
                    self.applyOverlaySnapshot(
                        source.broadcastOverlayState.snapshot,
                        reason: self.presentationActive
                            ? "image-relay-revision"
                            : "hidden-image-relay-revision"
                    )
                }
        }
        if recordingPresentationCancellable == nil {
            // Recovery BK / RL-150: RecordingEngine is the sole physical state
            // owner. Route loss can acknowledge Paused while Broadcast is hidden,
            // so the retained projection must consume that acknowledgement rather
            // than wait for its visible-only ancillary poll on first re-entry.
            recordingPresentationCancellable = Publishers.CombineLatest(
                RecordingEngine.shared.$state.removeDuplicates(),
                RecordingEngine.shared.$elapsedText.removeDuplicates()
            )
            .dropFirst()
            .sink { [weak self] _, _ in
                guard let self, let source = self.source else { return }
                source.refreshBroadcastOverlayState()
                self.applyOverlaySnapshot(
                    source.broadcastOverlayState.snapshot,
                    reason: self.presentationActive
                        ? "recording-owner-change"
                        : "hidden-recording-owner-change"
                )
            }
        }
        if streamPresentationCancellable == nil {
            // Recovery CF / RL-195: StreamControlStore remains the sole stream
            // lifecycle owner. Broadcast receives its requested/acknowledged
            // runtime state through the existing immutable route projection so
            // a second tap cannot reinterpret startup intent as an immediate stop.
            streamPresentationCancellable = StreamControlStore.shared.$runtimeState
                .removeDuplicates()
                .sink { [weak self] _ in
                    self?.publishRuntimeSnapshot(reason: "stream-owner-change")
                }
        }
    }

    func start(source: HockeyScoreboardViewModel) {
        bind(source: source)
        presentationActive = true
        // Re-resolve layout, sponsor and stream projections at the visibility
        // acknowledgement boundary even when the overlay value itself did not
        // change while the route was hidden.
        applyOverlaySnapshot(source.broadcastOverlayState.snapshot, reason: "visible-presentation-start", forcePublish: true)

        startPresentationClockTask()

        guard ancillaryRefreshTask == nil else { return }
        ancillaryRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.refreshIfChanged()
                try? await Task.sleep(nanoseconds: MainThreadStallMonitor.shared.broadcastOverlayRefreshNanoseconds())
            }
        }
    }

    /// Suspend visible-only polling while retaining the authoritative overlay
    /// subscription and its latest value. Route state therefore cannot become a
    /// second scoreboard owner, and returning to Broadcast is never seeded from
    /// an empty or previous-session presentation snapshot.
    func suspendPresentation() {
        presentationActive = false
        ancillaryRefreshTask?.cancel()
        ancillaryRefreshTask = nil
        presentationClockTask?.cancel()
        presentationClockTask = nil
        source?.setBroadcastPresentationClockText(nil)
        resetPresentationClockState(keepingOverlay: true)
    }

    func stop() {
        presentationActive = false
        ancillaryRefreshTask?.cancel()
        ancillaryRefreshTask = nil
        presentationClockTask?.cancel()
        presentationClockTask = nil
        overlayCancellable?.cancel()
        overlayCancellable = nil
        imageRelayPresentationCancellable?.cancel()
        imageRelayPresentationCancellable = nil
        recordingPresentationCancellable?.cancel()
        recordingPresentationCancellable = nil
        streamPresentationCancellable?.cancel()
        streamPresentationCancellable = nil
        source?.setBroadcastPresentationClockText(nil)
        source = nil
        resetPresentationClockState()
    }

    func refreshIfChanged() {
        guard let source else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard lastRefreshUptimeNanoseconds == 0
                || now &- lastRefreshUptimeNanoseconds >= minimumRefreshIntervalNanoseconds else {
            coalescedRefreshCount &+= 1
            return
        }
        lastRefreshUptimeNanoseconds = now
        source.refreshBroadcastOverlayState()
        applyOverlaySnapshot(source.broadcastOverlayState.snapshot, reason: "ancillary")
        // Recovery AG / RL-069: layout, sponsor and stream status are presentation
        // projections owned outside BroadcastView. Polling them here keeps one
        // narrow runtime snapshot as the live route's only observed dependency.
        publishRuntimeSnapshot(reason: "ancillary-presentation")
    }

    private func applyOverlaySnapshot(
        _ overlaySnapshot: BroadcastOverlaySnapshot,
        reason: String,
        forcePublish: Bool = false
    ) {
        authoritativeOverlaySnapshot = overlaySnapshot
        let now = CFAbsoluteTimeGetCurrent()
        let nextAuthoritativeSeconds = Self.clockSeconds(from: overlaySnapshot.viewerScoreboard.state.clock)

        if nextAuthoritativeSeconds != authoritativeClockSeconds {
            authoritativeClockSeconds = nextAuthoritativeSeconds
            authoritativeClockChangedAt = now
            reconcilePresentationWithAuthoritative(reason: reason)
        } else if authoritativeClockChangedAt == 0, nextAuthoritativeSeconds != nil {
            authoritativeClockChangedAt = now
            reconcilePresentationWithAuthoritative(reason: reason)
        }

        // Recovery AX: the persistent scorebug host must receive authoritative
        // overlay changes while hidden so its complete image is already rendered
        // when Broadcast becomes visible. This is an immutable presentation
        // projection; capture, match and overlay authority remain unchanged.
        publishRuntimeSnapshot(
            reason: presentationActive || forcePublish ? reason : "hidden-scorebug-prewarm:\(reason)"
        )
    }

    private func reconcilePresentationWithAuthoritative(reason: String) {
        guard let source else {
            presentationClockSeconds = authoritativeClockSeconds
            return
        }
        guard let anchor = authoritativeClockSeconds else {
            presentationClockSeconds = nil
            return
        }
        guard let current = presentationClockSeconds else {
            presentationClockSeconds = anchor
            return
        }

        if source.trustedClockMayRebasePresentation {
            presentationClockSeconds = anchor
            return
        }

        guard let direction = source.trustedPresentationClockDirection else {
            // Direction is still being established by the trusted authority. Its
            // accepted anchors are already sequence-checked, so show them directly
            // without inventing an independent presentation direction.
            presentationClockSeconds = anchor
            return
        }

        switch direction {
        case .countDown:
            // A delayed OCR frame may be numerically above the already-coasted
            // presentation. Never rewind a countdown within the same running epoch.
            presentationClockSeconds = min(current, anchor)
        case .countUp:
            presentationClockSeconds = max(current, anchor)
        case .auto:
            presentationClockSeconds = anchor
        }

        if presentationClockSeconds != anchor {
            MainThreadStallMonitor.shared.traceOCRPhase(
                "UX16d15l Broadcast Clock retained monotonic presentation=\(Self.clockText(from: presentationClockSeconds ?? anchor)) delayedAnchor=\(Self.clockText(from: anchor)) reason=\(reason)"
            )
        }
    }

    private func startPresentationClockTask() {
        guard presentationClockTask == nil else { return }
        presentationClockTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.updatePresentationClock()
                try? await Task.sleep(nanoseconds: self.presentationClockPollNanoseconds)
            }
        }
    }

    private func updatePresentationClock() {
        guard let source,
              let anchorSeconds = authoritativeClockSeconds else { return }

        guard source.currentScreen == .broadcast,
              source.userWantsOCRRunning,
              !source.manualOverrideEnabled else {
            resynchronisePresentationToAuthoritative(reason: "OCR inactive or manual presentation")
            return
        }

        guard source.localClockIsRunning else {
            // A physical stop or accepted period reset is the only automatic
            // running-epoch boundary allowed to rebase the presentation.
            if source.trustedClockMayRebasePresentation {
                resynchronisePresentationToAuthoritative(reason: "confirmed physical board stop/reset")
            }
            return
        }

        guard let direction = source.trustedPresentationClockDirection,
              authoritativeClockChangedAt > 0 else { return }

        let age = CFAbsoluteTimeGetCurrent() - authoritativeClockChangedAt
        guard age >= 1.0 else { return }
        guard age <= maximumPresentationHoldoverSeconds else {
            // Stale OCR freezes the current presentation value. It never restores
            // an older anchor and never changes the authoritative state.
            return
        }

        let ticks = min(maximumPresentationTicks, Int(age.rounded(.down)))
        let candidate: Int
        switch direction {
        case .countDown:
            candidate = max(0, anchorSeconds - ticks)
        case .countUp:
            candidate = anchorSeconds + ticks
        case .auto:
            return
        }

        let monotonicCandidate: Int
        if let current = presentationClockSeconds {
            switch direction {
            case .countDown: monotonicCandidate = min(current, candidate)
            case .countUp: monotonicCandidate = max(current, candidate)
            case .auto: monotonicCandidate = candidate
            }
        } else {
            monotonicCandidate = candidate
        }

        guard monotonicCandidate != presentationClockSeconds else { return }
        presentationClockSeconds = monotonicCandidate
        publishRuntimeSnapshot(reason: "presentation-interpolation")
    }

    private func resynchronisePresentationToAuthoritative(reason: String) {
        guard presentationClockSeconds != authoritativeClockSeconds else { return }
        presentationClockSeconds = authoritativeClockSeconds
        publishRuntimeSnapshot(reason: reason)
    }

    private func publishRuntimeSnapshot(reason: String) {
        var next = BroadcastRuntimeSnapshot(
            overlaySnapshot: authoritativeOverlaySnapshot,
            layout: BroadcastScoreboardLayoutSettings.shared.snapshot,
            sponsorConfiguration: SponsorCatalogueStore.shared.configuration,
            streamBroadcastSafeModeActive: StreamControlStore.shared.broadcastSafeModeActive,
            streamRuntimeState: StreamControlStore.shared.runtimeState,
            productionProfile: source?.broadcastProductionProfile ?? .smoothMotion
        )
        if let presentationClockSeconds {
            next.overlayState.clock = Self.clockText(from: presentationClockSeconds)
            next.viewerScoreboard.state.clock = next.overlayState.clock
            next.viewerScoreboard.fieldSources["clock"] = "trustedPresentationClock"
        }
        guard next != snapshot else { return }
        let previousClock = snapshot.overlayState.clock ?? "--:--"
        let nextClock = next.overlayState.clock ?? "--:--"
        snapshot = next
        source?.setBroadcastPresentationClockText(next.overlayState.clock)
        RinkLensPhysicalAcceptanceMonitor.shared.recordOverlayPresentation(
            clock: next.overlayState.clock,
            homeScore: next.overlayState.homeScore,
            awayScore: next.overlayState.awayScore,
            reason: reason
        )
        MainThreadStallMonitor.shared.notePublish(source: "broadcast overlay snapshot")
        if previousClock != nextClock {
            let authoritativeClock = authoritativeOverlaySnapshot.scoreboardState.clock ?? "--:--"
            MainThreadStallMonitor.shared.traceOCRPhase(
                "UX16d15l Broadcast runtime applied Clock \(previousClock) -> \(nextClock) source=\(reason) authoritative=\(authoritativeClock)"
            )
        }
    }

    private func resetPresentationClockState(keepingOverlay: Bool = false) {
        if !keepingOverlay {
            authoritativeOverlaySnapshot = .empty
        }
        authoritativeClockSeconds = nil
        authoritativeClockChangedAt = 0
        presentationClockSeconds = nil
    }

    private static func clockSeconds(from text: String?) -> Int? {
        guard let text else { return nil }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let minutes = Int(parts[0]),
              let seconds = Int(parts[1]),
              minutes >= 0,
              (0..<60).contains(seconds) else { return nil }
        return minutes * 60 + seconds
    }

    private static func clockText(from seconds: Int) -> String {
        let clamped = max(0, seconds)
        return String(format: "%d:%02d", clamped / 60, clamped % 60)
    }

}

/// Existing BroadcastView-facing snapshot shape.
///
/// Kept for compatibility so v0.8.8m14 changes the data source, not the visual
/// layout or the public overlay component signatures.
struct BroadcastRuntimeSnapshot: Equatable {
    var viewerScoreboard: RinkLensViewerScoreboardSnapshot
    var overlayState: ScoreboardState
    var isOCRMode: Bool
    var modeStatusText: String
    var strengthState: StrengthState
    var activePenaltyClocks: [PenaltyClock]
    var activeBroadcastBanner: BroadcastEvent?
    var activeIntermissionReel: BroadcastIntermissionReelState?
    var homeLogo: UIImage?
    var awayLogo: UIImage?
    var livePreviewRotationOffsetDegrees: CGFloat
    var recordingBadge: RecordingBadgeState

    // Recovery AG / RL-069: immutable presentation projections. BroadcastView
    // no longer observes the underlying global stores directly. Those stores
    // remain the sole mutation owners; this snapshot is read-only route input.
    var layout: BroadcastScoreboardLayoutSnapshot
    var sponsorConfiguration: SponsorCatalogueConfiguration
    var homeTeamName: String
    var awayTeamName: String
    var streamBroadcastSafeModeActive: Bool
    var streamRuntimeState: StreamControlStore.RuntimeState
    var productionProfile: BroadcastProductionProfile

    static let empty = BroadcastRuntimeSnapshot(
        overlaySnapshot: .empty,
        layout: BroadcastScoreboardLayoutSnapshot(),
        sponsorConfiguration: .defaults,
        streamBroadcastSafeModeActive: false,
        streamRuntimeState: .idle,
        productionProfile: .smoothMotion
    )

    init(
        overlaySnapshot: BroadcastOverlaySnapshot,
        layout: BroadcastScoreboardLayoutSnapshot,
        sponsorConfiguration: SponsorCatalogueConfiguration,
        streamBroadcastSafeModeActive: Bool,
        streamRuntimeState: StreamControlStore.RuntimeState,
        productionProfile: BroadcastProductionProfile
    ) {
        self.viewerScoreboard = overlaySnapshot.viewerScoreboard
        self.overlayState = overlaySnapshot.viewerScoreboard.state
        self.isOCRMode = overlaySnapshot.isOCRMode
        self.modeStatusText = overlaySnapshot.modeStatusText
        self.strengthState = overlaySnapshot.strengthState
        self.activePenaltyClocks = overlaySnapshot.penalties
        self.activeBroadcastBanner = overlaySnapshot.activeBroadcastBanner
        self.activeIntermissionReel = overlaySnapshot.activeIntermissionReel
        self.homeLogo = overlaySnapshot.homeLogo
        self.awayLogo = overlaySnapshot.awayLogo
        self.livePreviewRotationOffsetDegrees = overlaySnapshot.livePreviewRotationOffsetDegrees
        self.recordingBadge = overlaySnapshot.recordingBadge
        self.layout = layout
        self.sponsorConfiguration = sponsorConfiguration
        self.homeTeamName = overlaySnapshot.viewerScoreboard.state.homeTeam ?? "HOME"
        self.awayTeamName = overlaySnapshot.viewerScoreboard.state.awayTeam ?? "GUEST"
        self.streamBroadcastSafeModeActive = streamBroadcastSafeModeActive
        self.streamRuntimeState = streamRuntimeState
        self.productionProfile = productionProfile
    }

    @MainActor
    init(source: HockeyScoreboardViewModel) {
        source.refreshBroadcastOverlayState()
        self.init(
            overlaySnapshot: source.broadcastOverlayState.snapshot,
            layout: BroadcastScoreboardLayoutSettings.shared.snapshot,
            sponsorConfiguration: SponsorCatalogueStore.shared.configuration,
            streamBroadcastSafeModeActive: StreamControlStore.shared.broadcastSafeModeActive,
            streamRuntimeState: StreamControlStore.shared.runtimeState,
            productionProfile: source.broadcastProductionProfile
        )
    }

    static func == (lhs: BroadcastRuntimeSnapshot, rhs: BroadcastRuntimeSnapshot) -> Bool {
        lhs.viewerScoreboard.isMateriallyEqual(to: rhs.viewerScoreboard) &&
        lhs.overlayState == rhs.overlayState &&
        lhs.isOCRMode == rhs.isOCRMode &&
        lhs.modeStatusText == rhs.modeStatusText &&
        lhs.strengthState == rhs.strengthState &&
        lhs.activePenaltyClocks == rhs.activePenaltyClocks &&
        lhs.activeBroadcastBanner == rhs.activeBroadcastBanner &&
        lhs.activeIntermissionReel == rhs.activeIntermissionReel &&
        lhs.livePreviewRotationOffsetDegrees == rhs.livePreviewRotationOffsetDegrees &&
        lhs.recordingBadge == rhs.recordingBadge &&
        lhs.layout == rhs.layout &&
        lhs.sponsorConfiguration == rhs.sponsorConfiguration &&
        lhs.homeTeamName == rhs.homeTeamName &&
        lhs.awayTeamName == rhs.awayTeamName &&
        lhs.streamBroadcastSafeModeActive == rhs.streamBroadcastSafeModeActive &&
        lhs.streamRuntimeState == rhs.streamRuntimeState &&
        lhs.productionProfile == rhs.productionProfile &&
        sameRuntimeImage(lhs.homeLogo, rhs.homeLogo) &&
        sameRuntimeImage(lhs.awayLogo, rhs.awayLogo)
    }
}

private func sameRuntimeImage(_ lhs: UIImage?, _ rhs: UIImage?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
        return true
    case let (left?, right?):
        return left === right
    default:
        return false
    }
}

#endif
