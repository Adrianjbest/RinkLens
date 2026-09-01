// BUILD 699 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import UIKit

// MARK: - v0.8.8m15a Manual + Broadcast Prune
//
// These methods were moved out of 180_HockeyScoreboardViewModel.swift
// without changing behaviour. The ViewModel remains the coordinator, while
// ManualScoreController remains the single manual protection rules owner and
// BroadcastOverlayState remains the accepted display-state bridge.
@MainActor
extension HockeyScoreboardViewModel {

    private func resolvedViewerScoreboardProjection() -> RinkLensViewerScoreboardSnapshot {
        if !RinkLensRiskFeaturePolicy.isEnabled(.viewerScoreboardSnapshotV2) {
            var legacy = state
            legacy.homeTeam = homeTeamName
            legacy.awayTeam = awayTeamName
            var legacySources = Dictionary(uniqueKeysWithValues: [
                "homeTeam", "awayTeam", "clock", "homeScore", "awayScore", "period",
                "homePenalty1", "homePenalty2", "awayPenalty1", "awayPenalty2"
            ].map { ($0, "acceptedMatchState") })
            legacySources["homeTeam"] = "teamIdentity"
            legacySources["awayTeam"] = "teamIdentity"
            if manualOverrideEnabled {
                legacy.homeScore = manualScoreState.manualHomeScore ?? overrideHomeScore
                legacy.awayScore = manualScoreState.manualAwayScore ?? overrideAwayScore
                legacy.period = manualScoreState.manualPeriod ?? overridePeriod
                legacy.periodLabel = normalizedPeriodOption(defaultPeriodOption)
                legacySources["homeScore"] = "manualScore"
                legacySources["awayScore"] = "manualScore"
                legacySources["period"] = "manualScore"
            } else if isImageRelayMode {
                // Build 709: textual Clock metadata was retired in Build 708.
                // Keep the accepted match-state Clock text while the physical Clock
                // image remains owned and rendered by ScoreboardImageRelayStore.
                legacy.homeScore = imageRelayMetadataHomeScore ?? legacy.homeScore
                legacy.awayScore = imageRelayMetadataAwayScore ?? legacy.awayScore
                legacy.period = imageRelayMetadataPeriod ?? legacy.period
                if let period = imageRelayMetadataPeriod { legacy.periodLabel = "P\(period)" }
                if ScoreboardImageRelayStore.shared.snapshot().image(for: .clock) != nil {
                    legacySources["clock"] = "imageRelayPhysicalImage"
                }
                legacySources["homeScore"] = "imageRelayMetadataLegacy"
                legacySources["awayScore"] = "imageRelayMetadataLegacy"
                legacySources["period"] = "imageRelayMetadataLegacy"
            }
            return RinkLensViewerScoreboardSnapshot(state: legacy, relay: isImageRelayMode ? ScoreboardImageRelayStore.shared.snapshot() : .disabled, fieldSources: legacySources)
        }

        var output = state
        output.homeTeam = homeTeamName
        output.awayTeam = awayTeamName
        var sources = Dictionary(uniqueKeysWithValues: [
            "clock", "homeScore", "awayScore", "period",
            "homePenalty1", "homePenalty2", "awayPenalty1", "awayPenalty2"
        ].map { ($0, "acceptedMatchState") })
        sources["homeTeam"] = "teamIdentity"
        sources["awayTeam"] = "teamIdentity"

        if manualOverrideEnabled {
            output.homeScore = manualScoreState.manualHomeScore ?? overrideHomeScore
            output.awayScore = manualScoreState.manualAwayScore ?? overrideAwayScore
            output.period = manualScoreState.manualPeriod ?? overridePeriod
            output.periodLabel = normalizedPeriodOption(defaultPeriodOption)
            sources["homeScore"] = "manualScore"
            sources["awayScore"] = "manualScore"
            sources["period"] = "manualScore"
            if manualScoreState.clockOverrideActive {
                sources["clock"] = "manualScore"
            }
            return RinkLensViewerScoreboardSnapshot(state: output, relay: .disabled, fieldSources: sources)
        }

        guard isImageRelayMode else {
            return RinkLensViewerScoreboardSnapshot(state: output, relay: .disabled, fieldSources: sources)
        }
        let relay = ScoreboardImageRelayStore.shared.snapshot()
        guard relay.enabled else {
            return RinkLensViewerScoreboardSnapshot(state: output, relay: .disabled, fieldSources: sources)
        }

        // Build 785 R8: accepted MatchState remains the sole semantic source.
        // Relay pixels are filtered against that state before any renderer sees
        // them; arbitrary camera content cannot replace scores, Period, penalties
        // or manpower in the viewer snapshot.
        let viewerRelay = relay.viewerProjection(acceptedState: output)
        if viewerRelay.image(for: .clock) != nil {
            sources["clock"] = "imageRelayPhysicalImage"
        }
        return RinkLensViewerScoreboardSnapshot(state: output, relay: viewerRelay, fieldSources: sources)
    }

    var overlayState: ScoreboardState {
        resolvedViewerScoreboardProjection().state
    }

    var broadcastOverlaySnapshot: BroadcastOverlaySnapshot {
        let viewer = resolvedViewerScoreboardProjection()
        return BroadcastOverlaySnapshot(
            viewerScoreboard: viewer,
            scoreboardState: viewer.state,
            isOCRMode: isOCRMode,
            modeStatusText: operatingModeStatusText,
            strengthState: currentStrengthState,
            penalties: activePenaltyClocks,
            activeBroadcastBanner: activeBroadcastBanner,
            activeIntermissionReel: activeIntermissionReel,
            homeLogo: homeLogoImage,
            awayLogo: awayLogoImage,
            recordingBadge: RecordingBadgeState.current(),
            livePreviewRotationOffsetDegrees: livePreviewRotationOffsetDegrees,
            fieldSources: viewer.fieldSources
        )
    }

    func refreshBroadcastOverlayState() {
        broadcastOverlayState.apply(broadcastOverlaySnapshot)
    }

    func setManualOverride(_ enabled: Bool) {
        if enabled,
           scoreboardInputLifecycleStore.snapshot.mode != OperatingMode.manual.rawValue {
            _ = scoreboardInputLifecycleStore.selectMode(
                OperatingMode.manual.rawValue,
                source: "ManualBroadcast.setManualOverride",
                reason: "Manual value/protection edit requires Manual scoreboard input mode"
            )
        }
        let wasManual = manualOverrideEnabled
        // Build 674 captures the viewer-visible Image Relay values before disabling
        // the relay. Resetting metadata first caused the untouched team to seed from
        // stale MatchState (for example Home 0 instead of the visible Home 3).
        let relayHomeAtEntry = imageRelayMetadataHomeScore
        let relayAwayAtEntry = imageRelayMetadataAwayScore
        let acceptedClockAtEntry = state.clock
        let relayPeriodAtEntry = imageRelayMetadataPeriod

        if enabled, !wasManual {
            // Hide Image Relay from the Manual operator surface without deleting
            // its last complete images or saved calibration. In the Build 753 path
            // the lifecycle owner has already committed Manual, so presentation
            // cleanup must not issue a second mode/run-state mutation.
            ScoreboardImageRelayStore.shared.deactivatePresentationPreservingSnapshot(
                reason: "Manual Mode enabled — retained physical snapshot but Manual owns display"
            )
            imageRelayEngine.reset(reason: "Manual Mode enabled")
            resetImageRelayMetadata(reason: "Manual Mode enabled")
        }

        manualScoreController.setGlobalManualMode(
            enabled,
            currentHomeScore: relayHomeAtEntry ?? state.homeScore ?? overrideHomeScore,
            currentAwayScore: relayAwayAtEntry ?? state.awayScore ?? overrideAwayScore,
            currentClock: acceptedClockAtEntry,
            currentPeriod: relayPeriodAtEntry ?? state.period ?? overridePeriod
        )

        if enabled, !wasManual {
            overrideHomeScore = manualScoreState.manualHomeScore ?? state.homeScore ?? 0
            overrideAwayScore = manualScoreState.manualAwayScore ?? state.awayScore ?? 0
            overridePeriod = manualScoreState.manualPeriod ?? max(1, state.period ?? 1)
        }


        if enabled {
            userWantsOCRRunning = false
            isOCRPaused = true

            if !RinkLensProgrammeStreamCaptureRequirement.shared.isRequested(),
               (externalOCRMultiCamCoordinator.isCaptureActiveSnapshot
                || externalOCRMultiCamCoordinator.isTransitioningSnapshot) {
                Task { @MainActor in
                    await self.deactivateExternalOCRMultiCam(reason: "Manual Mode enabled")
                    if self.currentScreen == .broadcast {
                        await self.startBroadcastLiveCameraAfterExternalMultiCamRelease()
                    }
                }
            } else if RinkLensProgrammeStreamCaptureRequirement.shared.isRequested() {
                RinkLensStructuredEventLogger.shared.record(
                    domain: .capture,
                    event: "manual_mode_preserved_programme_stream_capture",
                    entityID: "broadcast",
                    previous: ["scoreboardInput": "imageRelay"],
                    next: [
                        "scoreboardInput": "manual",
                        "captureMutation": "none",
                        "programmeStreamRequirement": "active"
                    ],
                    source: "ManualBroadcast.setManualOverride",
                    reason: "Manual scoreboard input cannot remove Broadcast capture required by an active programme stream",
                    captureGeneration: externalOCRMultiCamCoordinator.snapshot.transitionGeneration,
                    authoritativeOwner: "CaptureLifecycleController"
                )
            }

            stopSyntheticClock(reason: "Manual Mode")

            if !wasManual {
                disableOCRRecognitionForManualMode()
            }
        } else if userWantsOCRRunning {
            manualScoreController.clearAllManualOverrides()
            isOCRPaused = false
        } else {
            manualScoreController.clearAllManualOverrides()
            isOCRPaused = true
        }

        updateFrameDeliveryPolicy()
    }

    private func disableOCRRecognitionForManualMode() {
        ocrProcessingGeneration += 1
        isProcessing = false
        resetOCROrchestration(reason: "Manual Mode enabled")
        isOCRPaused = true

        // Clear live OCR diagnostics so Manual Mode cannot display stale OCR as active.
        latestOCRCandidateState = ScoreboardState()
        lastRawOCRText = nil
        regionOCRPreview = Dictionary(uniqueKeysWithValues: OCRRegionKey.allCases.map { ($0, "--") })
        regionOCRRecognizer = Dictionary(uniqueKeysWithValues: OCRRegionKey.allCases.map { ($0, .vision) })
        ocrFieldConfidence.removeAll()
        ocrTrustSummary = OCRTrustSummary()
        selectedRegionRawPreviewImage = nil
        selectedRegionProcessedPreviewImage = nil
        selectedRegionThresholdedPreviewImage = nil
        selectedRegionPreviewStatus = "OCR disabled in Manual Mode"
        scoreVisualHash.removeAll()
        periodVisualHash = nil
        periodLastSafetyOCRAt = 0
        penaltyPlayerVisualHash.removeAll()
        penaltyTimeVisualHash.removeAll()
        clockVisualHash = nil
        smartChangeSkippedOCRFrames = 0
        smartChangeLastDecisionText = "Smart Change Detection reset"
        lastOCRFieldCheckAt.removeAll()
        updatePixelHashingStatus(false, detail: "Manual Mode: OCR, hashing, timers and diagnostics are stopped.", force: true)
        updateRegionDetectionStates(watchedByHashing: [], ocrScheduled: [], force: true)
    }

    func toggleOCRProcessing() {
        if isOCREffectiveRunning {
            pauseOCRProcessing()
        } else {
            if operatingMode == .manual {
                setOperatingMode(.imageRelay, autoStart: true)
                return
            }
            if manualOverrideEnabled {
                setManualOverride(false)
            }
            resumeOCRProcessing()
        }
    }

    func setClockManually(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidTimer(trimmed) else {
            statusMessage = "Clock must be in M:SS or MM:SS format."
            return
        }
        setManualOverride(true)
        guard let manualClock = manualScoreController.applyManualClock(trimmed) else {
            statusMessage = "Clock must be in M:SS or MM:SS format."
            return
        }
        reduceMatchState(
            .setClock(
                manualClock,
                context: RinkLensMatchStateContext(
                    origin: .manual,
                    reason: "Operator set game clock manually"
                )
            )
        )
        ocrSmoothingEngine.reset(key: .clock)
        setAcceptedOCREvidence(
            AcceptedOCRValueState(
                acceptedText: state.clock,
                lastConfidence: 1.0,
                recognizerUsed: .segmented,
                lastUpdated: .now
            ),
            for: .clock,
            source: "ManualBroadcastPrunedActions",
            reason: "Operator set game clock manually"
        )
        statusMessage = "Clock manually set to \(state.clock ?? trimmed)."
    }

    func setOperatingMode(_ requestedMode: OperatingMode, autoStart: Bool = true) {
        let mode: OperatingMode = requestedMode == .ocr ? .imageRelay : requestedMode
        let previousMode = operatingMode
        MainThreadStallMonitor.shared.markContext(
            "Build 754 scoreboard-input owner transition previous=\(previousMode.rawValue) requested=\(requestedMode.rawValue) resolved=\(mode.rawValue) autoStart=\(autoStart)"
        )

        switch mode {
        case .ocr:
            return

        case .imageRelay:
            let returningFromManual = previousMode == .manual
            guard scoreboardInputLifecycleStore.selectMode(
                OperatingMode.imageRelay.rawValue,
                source: "ManualBroadcast.setOperatingMode",
                reason: "Operator selected Image Relay; autoStart=\(autoStart)"
            ) || scoreboardInputLifecycleStore.snapshot.mode == OperatingMode.imageRelay.rawValue else {
                return
            }

            ocrProcessingGeneration += 1
            resetOrchestrationForImageRelaySelection()
            if returningFromManual {
                beginImageRelayResumeProtection(reason: "Build 754 returned from Manual mode")
            } else {
                resetImageRelayMetadata(reason: "Image Relay selected")
            }
            manualScoreController.clearAllManualOverrides()
            latestOCRCandidateState = ScoreboardState()
            selectedRegionPreviewStatus = autoStart
                ? "Image Relay selected. Starting through the authoritative lifecycle owner."
                : "Image Relay selected. Previous zones and colour settings are retained; press Start Relay to begin."
            RinkLensPhysicalAcceptanceMonitor.shared.markNotApplicable(
                reason: "Image Relay selected — visual field freshness and recording parity apply; OCR acceptance does not"
            )

            if autoStart {
                resumeOCRProcessing()
                ocrCameraService.noteLifecycleEvent("Image Relay selected and start requested through lifecycle owner")
            } else {
                userWantsOCRRunning = false
                isOCRPaused = true
                imageRelayEngine.reset(reason: "Image Relay armed from Calibration and waiting for manual start")
                ScoreboardImageRelayStore.shared.activatePresentationWithoutProcessing(
                    reason: "Image Relay armed from Calibration; retained last valid presentation"
                )
                statusMessage = "Image Relay selected and stopped. Press Start Relay to begin."
                ocrCameraService.noteLifecycleEvent("Image Relay armed from Calibration; manual start required")
                updateFrameDeliveryPolicy(force: true)
            }

        case .manual:
            guard scoreboardInputLifecycleStore.selectMode(
                OperatingMode.manual.rawValue,
                source: "ManualBroadcast.setOperatingMode",
                reason: "Operator selected Manual scoreboard input"
            ) || scoreboardInputLifecycleStore.snapshot.mode == OperatingMode.manual.rawValue else {
                return
            }
            // ManualScoreController now receives only values/protection. It does not
            // decide the selected scoreboard input mode or remember Relay run state.
            setManualOverride(true)
            ocrCameraService.noteLifecycleEvent("Manual mode enabled: automatic processing paused, session retained")
            updateFrameDeliveryPolicy()
        }
    }


    /// Keeps the public mode switch compact while allowing Calibration to arm
    /// Image Relay without starting it. The helper name deliberately describes
    /// only the existing reset operation so no new relay presentation path exists.
    private func resetOrchestrationForImageRelaySelection() {
        resetOCROrchestration(reason: "Image Relay selected — legacy continuous OCR disabled")
    }

    func clearManualOverride(_ field: ManualScoreField) {
        manualScoreController.clearManualOverride(field)
        updateFrameDeliveryPolicy()
    }

    func clearAllManualOverrides() {
        manualScoreController.clearAllManualOverrides()
        setManualOverride(false)
    }

    func resumeImageRelayFromBroadcastManualMode(reason: String = "operator requested Image Relay from Broadcast") {
        MainThreadStallMonitor.shared.traceOCRPhase("resume Image Relay requested from manual controls reason=\(reason)")
        setOperatingMode(.imageRelay)
        statusMessage = "Image Relay resumed. Manual overrides cleared."
    }

    @available(*, deprecated, message: "Use resumeImageRelayFromBroadcastManualMode")
    func reenableOCRFromBroadcastManualMode(reason: String = "legacy operator request") {
        resumeImageRelayFromBroadcastManualMode(reason: reason)
    }

    func setControlMode(_ mode: OverlayControlMode) {
        setOperatingMode(mode)
    }

    func revertToOCR() {
        // Legacy API name retained; Build 621 returns to Image Relay.
        overrideHomeScore = state.homeScore ?? 0
        overrideAwayScore = state.awayScore ?? 0
        overridePeriod = max(1, state.period ?? 1)
        manualScoreController.clearAllManualOverrides()
        setOperatingMode(.imageRelay)
    }

    private func enterManualScoringPreservingVisibleScores() {
        let visibleHome = manualScoreState.manualHomeScore
            ?? imageRelayMetadataHomeScore
            ?? state.homeScore
            ?? overrideHomeScore
        let visibleAway = manualScoreState.manualAwayScore
            ?? imageRelayMetadataAwayScore
            ?? state.awayScore
            ?? overrideAwayScore
        let visiblePeriod = manualScoreState.manualPeriod
            ?? imageRelayMetadataPeriod
            ?? state.period
            ?? overridePeriod

        if !manualOverrideEnabled {
            setManualOverride(true)
        }

        // v0.9.1w: keep both sides seeded when a single manual score button is used.
        // Earlier manual goal actions could enter Manual Mode with only the tapped side
        // protected, leaving the opposite side to fall back to a stale zero/empty value.
        overrideHomeScore = manualScoreController.applyManualHomeScore(visibleHome)
        overrideAwayScore = manualScoreController.applyManualAwayScore(visibleAway)
        overridePeriod = manualScoreController.applyManualPeriod(visiblePeriod)
    }

    func adjustHomeScore(by delta: Int) {
        enterManualScoringPreservingVisibleScores()
        overrideHomeScore = manualScoreController.applyManualHomeScore(overrideHomeScore + delta)
        reduceMatchState(
            .setScores(
                home: overrideHomeScore,
                away: overrideAwayScore,
                context: RinkLensMatchStateContext(
                    origin: .manual,
                    reason: "Manual home score adjustment"
                )
            )
        )
    }

    func adjustAwayScore(by delta: Int) {
        enterManualScoringPreservingVisibleScores()
        overrideAwayScore = manualScoreController.applyManualAwayScore(overrideAwayScore + delta)
        reduceMatchState(
            .setScores(
                home: overrideHomeScore,
                away: overrideAwayScore,
                context: RinkLensMatchStateContext(
                    origin: .manual,
                    reason: "Manual away score adjustment"
                )
            )
        )
    }

    func registerManualHomeGoal() {
        enterManualScoringPreservingVisibleScores()
        overrideHomeScore = manualScoreController.applyManualHomeScore(overrideHomeScore + 1)
        reduceMatchState(
            .setScores(
                home: overrideHomeScore,
                away: overrideAwayScore,
                context: RinkLensMatchStateContext(
                    origin: .manual,
                    eventPolicy: [.score],
                    reason: "Manual home goal registered"
                )
            )
        )
    }

    func registerManualAwayGoal() {
        enterManualScoringPreservingVisibleScores()
        overrideAwayScore = manualScoreController.applyManualAwayScore(overrideAwayScore + 1)
        reduceMatchState(
            .setScores(
                home: overrideHomeScore,
                away: overrideAwayScore,
                context: RinkLensMatchStateContext(
                    origin: .manual,
                    eventPolicy: [.score],
                    reason: "Manual away goal registered"
                )
            )
        )
    }

    func registerManualHomePenalty(seconds: Int = 120) {
        registerManualPenalty(team: .home, seconds: seconds)
    }

    func registerManualAwayPenalty(seconds: Int = 120) {
        registerManualPenalty(team: .away, seconds: seconds)
    }

    private func registerManualPenalty(team: Team, seconds: Int) {
        setManualOverride(true)
        reduceMatchState(
            .registerPenalty(
                team: team,
                seconds: seconds,
                context: RinkLensMatchStateContext(
                    origin: .manual,
                    eventPolicy: [.penalty],
                    reason: "Manual \(team.rawValue) penalty registered"
                )
            )
        )
    }

    func clearManualPenalties() {
        setManualOverride(true)
        reduceMatchState(
            .clearPenalties(
                context: RinkLensMatchStateContext(
                    origin: .manual,
                    reason: "Operator cleared all manual penalties"
                )
            )
        )
    }

    func undoLastBroadcastEvent() {
        guard let event = matchEventJournal.popLastTimeline(source: "ManualBroadcast", reason: "Operator undid last broadcast event") else { return }
        if activeBroadcastBanner?.id == event.id {
        }
        clearBroadcastBannerQueue()
        bannerDismissTask?.cancel()

        if event.isImageRelayCue {
            statusMessage = "Last Image Relay event cue removed. Relayed scoreboard images were unchanged."
            return
        }

        guard event.type == .goal || event.type == .powerPlayGoal || event.type == .shortHandedGoal else { return }
        setManualOverride(true)
        switch event.team {
        case .home:
            overrideHomeScore = manualScoreController.applyManualHomeScore((event.homeScoreAfter ?? overrideHomeScore) - 1)
        case .away:
            overrideAwayScore = manualScoreController.applyManualAwayScore((event.awayScoreAfter ?? overrideAwayScore) - 1)
        case .none:
            break
        }
        reduceMatchState(
            .setScores(
                home: overrideHomeScore,
                away: overrideAwayScore,
                context: RinkLensMatchStateContext(
                    origin: .manual,
                    reason: "Undo last broadcast goal event"
                )
            )
        )
        statusMessage = "Last broadcast event undone."
    }

    func clearBroadcastTimeline() {
        matchEventJournal.clearTimeline(source: "ManualBroadcast", reason: "Operator cleared broadcast timeline")
        clearStoppedClockBroadcastEventState()
        clearBroadcastBannerQueue()
        bannerDismissTask?.cancel()
    }

    func adjustPeriod(by delta: Int) {
        // ADS1: if the intermission reel is already active, Period + means
        // "start the next period" rather than accidentally jumping from P2 to P3.
        if delta > 0, activeIntermissionReel != nil {
            dismissSponsorIntermission(reason: "manual period start")
            return
        }

        setManualOverride(true)
        overridePeriod = manualScoreController.applyManualPeriod(clampedPeriod(overridePeriod + delta))
        defaultPeriodOption = String(overridePeriod)
        reduceMatchState(
            .setPeriod(
                overridePeriod,
                label: normalizedPeriodOption(String(overridePeriod)),
                context: RinkLensMatchStateContext(
                    origin: .manual,
                    eventPolicy: [.period],
                    reason: "Manual period adjustment"
                )
            )
        )
    }

    func adjustHomeShots(by delta: Int) {
        setManualOverride(true)
        reduceMatchState(
            .setShots(
                home: max(0, min(99, (state.homeShots ?? 0) + delta)),
                away: state.awayShots,
                context: RinkLensMatchStateContext(
                    origin: .manual,
                    reason: "Manual home shots adjustment"
                )
            )
        )
    }

    func adjustAwayShots(by delta: Int) {
        setManualOverride(true)
        reduceMatchState(
            .setShots(
                home: state.homeShots,
                away: max(0, min(99, (state.awayShots ?? 0) + delta)),
                context: RinkLensMatchStateContext(
                    origin: .manual,
                    reason: "Manual away shots adjustment"
                )
            )
        )
    }

    func setManualPeriod(_ period: Int) {
        setManualOverride(true)
        overridePeriod = manualScoreController.applyManualPeriod(clampedPeriod(period))
        defaultPeriodOption = String(overridePeriod)
        reduceMatchState(
            .setPeriod(
                overridePeriod,
                label: normalizedPeriodOption(String(overridePeriod)),
                context: RinkLensMatchStateContext(
                    origin: .manual,
                    reason: "Manual period value selected"
                )
            )
        )
    }

}

#endif
