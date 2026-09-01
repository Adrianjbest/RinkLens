// BUILD 707 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI

// STYLE2 central design system migration: operator chrome/fonts use RinkLensDesignSystem where safe.
import UIKit
import CoreImage
import CoreVideo

// MARK: - v0.8.8h Recording UI / Broadcast-aligned export

nonisolated enum BroadcastRecordingQuickControlGeometry {
    static func startResumeSlotWidth(forResume _: Bool) -> CGFloat { 76 }
    static func manualClipSlotWidth(isRecording _: Bool) -> CGFloat { 76 }
}

struct BroadcastRecordingQuickControls: View {
    let viewModel: HockeyScoreboardViewModel
    var manualControls: AnyView? = nil
    var showsClipAndMediaControls: Bool = true
    var showsManualClipControl: Bool = true
    var showsMediaControl: Bool = true
    var showsClipFeedback: Bool = true
    @ObservedObject private var recorder = AppContainer.shared.recordingEngine
    @ObservedObject private var stream = StreamControlStore.shared
    @ObservedObject private var pixelBufferFlags = BroadcastPixelBufferRecordingRolloutStore.shared
    @State private var showMediaBrowser = false
    @State private var manualClipPressFlash = false
    @State private var showStopConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: showsClipFeedback ? 3 : 0) {
            HStack(alignment: .center, spacing: showsClipFeedback ? 7 : 5) {
                VStack(alignment: .leading, spacing: 3) {
                    compactButtonRow
                    compactStatusRow
                }
                if let manualControls {
                    Divider()
                        .frame(height: 36)
                        .overlay(Color.white.opacity(0.22))
                    manualControls
                }
            }
            if showsClipFeedback && (recorder.manualClipExportStateText != "Idle" || recorder.manualClipFeedbackText != "Clip ready") {
                Text(recorder.manualClipFeedbackText)
                    .font(RinkLensDesignSystem.font(.micro))
                    .foregroundStyle(recorder.manualClipExportStateText == "Failed" ? .red : .white)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, showsClipFeedback ? 7 : 5)
        .padding(.vertical, showsClipFeedback ? 4 : 3)
        .fixedSize(horizontal: true, vertical: false)
        .background(Color.black.opacity(showsClipFeedback ? 0.54 : 0.46), in: RoundedRectangle(cornerRadius: showsClipFeedback ? 14 : 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: showsClipFeedback ? 14 : 12, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $showMediaBrowser) {
            BroadcastRecordingMediaBrowserView()
        }
        .alert("End recording?", isPresented: $showStopConfirmation) {
            Button("Keep Recording", role: .cancel) { }
            Button("End Recording", role: .destructive) {
                viewModel.requestBroadcastRecordingStop(source: "Broadcast on-screen Stop button")
            }
        } message: {
            Text("This closes the current recording file. It cannot be resumed after it is ended.")
        }
    }

    private var compactButtonRow: some View {
        HStack(spacing: showsClipFeedback ? 5 : 4) {
            startResumeButton
            pauseButton
            stopButton
            if showsClipAndMediaControls || showsManualClipControl {
                snapshotButton
            }
            if showsClipAndMediaControls || showsMediaControl {
                mediaButton
            }
        }
        .font(showsClipFeedback ? RinkLensDesignSystem.font(.caption) : RinkLensDesignSystem.font(.micro))
    }

    private var compactStatusRow: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 9) {
                runtimeIndicator(
                    title: "REC",
                    elapsed: recorder.elapsedText,
                    active: recorder.isRecording || recorder.isPaused,
                    colour: .red
                )
                runtimeIndicator(
                    title: "LIVE",
                    elapsed: stream.publishingElapsedText(),
                    active: stream.activelyPublishingStateActive,
                    colour: .green
                )
            }
        }
    }

    private func runtimeIndicator(title: String, elapsed: String, active: Bool, colour: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(active ? colour : Color.gray.opacity(0.65))
                .frame(width: 6, height: 6)
            Text("\(title) \(elapsed)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(active ? Color.white : Color.white.opacity(0.58))
        }
    }

    private var startResumeButton: some View {
        Button {
            viewModel.requestBroadcastRecordingStartOrResume(source: "Broadcast on-screen Record button")
        } label: {
            Label(recorder.canResume ? "RESUME" : "REC", systemImage: recorder.canResume ? "play.fill" : "record.circle.fill")
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(width: BroadcastRecordingQuickControlGeometry.startResumeSlotWidth(forResume: recorder.canResume))
                .frame(minHeight: 26)
        }
        .buttonStyle(.borderedProminent)
        .tint(recorder.canResume ? .green : .red)
        .disabled(!(recorder.canStart || recorder.canResume))
    }

    private var pauseButton: some View {
        Button {
            viewModel.requestBroadcastRecordingPause(source: "Broadcast on-screen Pause button")
        } label: {
            Label("PAUSE", systemImage: "pause.fill")
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(minWidth: 54, minHeight: 26)
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .disabled(!recorder.canPause)
    }

    private var stopButton: some View {
        Button(role: .destructive) {
            if viewModel.confirmBroadcastRecordingStop {
                showStopConfirmation = true
            } else {
                viewModel.requestBroadcastRecordingStop(source: "Broadcast on-screen Stop button")
            }
        } label: {
            Label("STOP", systemImage: "stop.fill")
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(minWidth: 50, minHeight: 26)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!recorder.canStop)
    }

    private var snapshotButton: some View {
        Button {
            manualClipPressFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                manualClipPressFlash = false
            }
            viewModel.broadcastRecordingCameraService.setRecordingFrameCaptureTargetFPS(recorder.currentTargetFPSValue)
            viewModel.broadcastRecordingCameraService.enableRecordingFrameCapture(reason: "manual clip")
            recorder.saveSnapshotClip(homeTeam: viewModel.homeTeamName, awayTeam: viewModel.awayTeamName)
        } label: {
            Label(recorder.isRecording ? "CLIP" : "REC FIRST", systemImage: recorder.isRecording ? "video.badge.plus" : "record.circle")
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(width: BroadcastRecordingQuickControlGeometry.manualClipSlotWidth(isRecording: recorder.isRecording))
                .frame(minHeight: 26)
        }
        .buttonStyle(.bordered)
        .tint(manualClipPressFlash ? .green : (recorder.isRecording ? .blue : .gray))
        .scaleEffect(manualClipPressFlash ? 1.06 : 1.0)
        .animation(.easeOut(duration: 0.18), value: manualClipPressFlash)
        .disabled(!recorder.isRecording)
        .accessibilityHint("Manual clips use the active recording PixelBuffer buffer. Start recording before taking a clip.")
    }

    private var mediaButton: some View {
        Button {
            recorder.refreshPhotoLibraryStatus()
            showMediaBrowser = true
        } label: {
            Label("FILES", systemImage: "folder.fill")
                .frame(minWidth: 54, minHeight: 26)
        }
        .buttonStyle(.bordered)
        .tint(.cyan)
    }

}

struct BroadcastRecordingPanel: View {
    let viewModel: HockeyScoreboardViewModel
    @ObservedObject private var recorder = AppContainer.shared.recordingEngine
    @State private var showMediaBrowser = false

    @ViewBuilder
    var body: some View {
        if RinkLensRiskFeaturePolicy.isEnabled(.minimalOperatorCameraRecordingV12) {
            BroadcastRecordingQuickControls(
                viewModel: viewModel,
                showsClipAndMediaControls: false,
                showsManualClipControl: false,
                showsMediaControl: false,
                showsClipFeedback: false
            )
        } else {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeader
                BroadcastRecordingQuickControls(viewModel: viewModel)
                recordingStatusCard
                recordingAlbumsCard
                recordingSettingsCard
            }
            .sheet(isPresented: $showMediaBrowser) {
                BroadcastRecordingMediaBrowserView()
            }
        }
    }

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Broadcast Recording", systemImage: "record.circle")
                .font(.headline)
            Text("Records the clean Broadcast output frame, excluding buttons, menus and diagnostics. Videos are saved into shorter RinkLens Photos albums for easier access.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.66))
        }
    }

    private var recordingStatusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Status").font(RinkLensDesignSystem.font(.bodyStrong))
            LabeledContent("Recording", value: recorder.state.rawValue)
            LabeledContent("Elapsed", value: recorder.elapsedText)
            LabeledContent("Current file", value: recorder.currentRecordingURL?.lastPathComponent ?? "Not recording")
            LabeledContent(
                "Quality",
                value: RinkLensRiskFeaturePolicy.isEnabled(.customRecordingOutputProfileV15)
                    ? recorder.recordingOutputPolicySummaryText
                    : "\(recorder.recordingTargetResolutionText) / \(recorder.recordingTargetFPSText) / \(recorder.recordingProfile.codec.rawValue)"
            )
            LabeledContent("Health", value: recorder.recordingHealthText)
            LabeledContent("Capture lease", value: recorder.recordingCaptureLeaseText)
            LabeledContent("Storage", value: recorder.photoLibraryStatusText)
            if let error = recorder.lastErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.95))
            }
        }
        .padding(12)
        .broadcastMenuCard(cornerRadius: 14)
    }

    private var recordingAlbumsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Albums").font(RinkLensDesignSystem.font(.bodyStrong))
                Spacer()
                Button("Access") { recorder.requestPhotoLibraryAccess() }
                    .buttonStyle(.bordered)
                Button("Browse") { showMediaBrowser = true }
                    .buttonStyle(.borderedProminent)
            }
            LabeledContent("Recordings", value: RecordingEngine.recordingsAlbumName)
            LabeledContent("Manual highlights", value: RecordingEngine.manualHighlightsAlbumName)
            LabeledContent("Auto highlights", value: RecordingEngine.autoHighlightsAlbumName)
            LabeledContent("Logs", value: RecordingEngine.logsFolderName)
            LabeledContent("Photos", value: recorder.photoLibraryStatusText)
            Text(recorder.photoLibraryAccessDetailText)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.66))
            if recorder.lastSavedAlbumName != "--" {
                Text("Last saved: \(recorder.lastSavedMediaName) → \(recorder.lastSavedAlbumName)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.66))
                    .lineLimit(2)
            }
        }
        .padding(12)
        .broadcastMenuCard(cornerRadius: 14)
    }

    private var recordingSettingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recording Source / Output Quality").font(RinkLensDesignSystem.font(.bodyStrong))
            Text("Resolution and frame rate come directly from the active Broadcast camera source. There is no separate recording format to drift out of sync.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.66))
            LabeledContent("Camera source", value: recorder.recordingCameraSourceText)
            LabeledContent("Recording dimensions", value: recorder.recordingTargetResolutionText)
            LabeledContent("Recording cadence", value: recorder.recordingTargetFPSText)
            recordingCodecPicker
            recordingBitratePicker
            recordingStabilisationPicker
            recordingBroadcastTransformPicker
            LabeledContent("Audio", value: "Not captured yet")
            Stepper("Clip pre-roll: \(recorder.snapshotClipSeconds)s + 5s post-roll", value: $recorder.snapshotClipSeconds, in: 5...60, step: 5)
            LabeledContent("Save location", value: "App files + Photos albums")
            if let warning = recorder.recordingFormatWarningText {
                Text(warning)
                    .font(RinkLensDesignSystem.font(.caption))
                    .foregroundStyle(.orange)
            }
            if recorder.shouldShowRecordingFPSWarning {
                Text(recorder.recordingFPSWarningText)
                    .font(RinkLensDesignSystem.font(.caption))
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .broadcastMenuCard(cornerRadius: 14)
    }


    private var recordingCodecPicker: some View {
        Picker("Codec", selection: Binding<BroadcastRecordingProfile.Codec>(
            get: { recorder.recordingProfile.codec },
            set: { value in
                recorder.setRecordingCodec(value)
            }
        )) {
            ForEach(BroadcastRecordingProfile.Codec.allCases) { option in
                Text(option.rawValue).tag(option)
            }
        }
        .pickerStyle(.segmented)
    }


    private var recordingBitratePicker: some View {
        Picker("Bitrate / Quality", selection: Binding<BroadcastRecordingProfile.Bitrate>(
            get: { recorder.recordingProfile.bitrate },
            set: { value in
                recorder.setRecordingBitrate(value)
            }
        )) {
            ForEach(BroadcastRecordingProfile.Bitrate.allCases) { option in
                Text(option.rawValue).tag(option)
            }
        }
        .pickerStyle(.segmented)
    }

    private var recordingStabilisationPicker: some View {
        Picker("Image Stabilisation", selection: Binding<Bool>(
            get: { viewModel.broadcastVideoStabilisationEnabled },
            set: { value in
                viewModel.setBroadcastVideoStabilisationEnabled(
                    value,
                    source: "RecordingSetup",
                    reason: "Operator changed Broadcast image stabilisation"
                )
            }
        )) {
            Text("Off").tag(false)
            Text("Automatic").tag(true)
        }
        .pickerStyle(.segmented)
    }

    private var recordingBroadcastTransformPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Whole export orientation correction")
                .font(RinkLensDesignSystem.font(.caption))
                .foregroundStyle(.white.opacity(0.66))
            HStack(spacing: 6) {
                ForEach([0, 90, 180, 270], id: \.self) { degrees in
                    Button("\(degrees)°") {
                        recorder.setRecordingBroadcastTransformCorrection(degrees)
                    }
                    .buttonStyle(.bordered)
                    .tint(recorder.recordingBroadcastTransformCorrectionDegrees == degrees ? .blue : .gray)
                }
            }
            Text("Default is 0°. The camera frame is auto-corrected first; this recovery picker rotates the whole exported video frame including scoreboard and popups. Use 90/180/270 only if the saved media is still rotated. This does not change OCR/calibration zones.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.66))
        }
    }


}

struct BroadcastRecordingDiagnosticsPanel: View {
    let viewModel: HockeyScoreboardViewModel
    @ObservedObject private var recorder = AppContainer.shared.recordingEngine
    @ObservedObject private var rendererDiagnostics = PersistentBroadcastRendererDiagnostics.shared
    @ObservedObject private var pacerDiagnostics = BroadcastRenderPacerDiagnostics.shared
    @ObservedObject private var clipBuffer = AppContainer.shared.clipEngine
    @ObservedObject private var pixelBufferFlags = BroadcastPixelBufferRecordingRolloutStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            diagnosticsHeader
            pixelBufferProductionPathCard
            writerStateCard
            frameTimingCard
            exportAndClipCard
            recoveryActionsCard
        }
    }

    private var diagnosticsHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Recording Diagnostics", systemImage: "record.circle")
                .font(.headline)
            Text("Detailed recording diagnostics moved out of the Recording operator controls. Use this page when investigating writer, frame, encoder, clip or export issues.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)
        }
    }


    private var pixelBufferProductionPathCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("UX16d3 Production Recording Path").font(RinkLensDesignSystem.font(.bodyStrong))
            LabeledContent("Renderer stage", value: BroadcastProductionDiagnosticLabelsV2.rendererStage(pixelBufferFlags.activeRendererStageText))
            LabeledContent("Writer path", value: BroadcastProductionDiagnosticLabelsV2.writerPath(pixelBufferFlags.activeWriterPathText))
            LabeledContent("Recording path", value: "PixelBuffer locked on")
            LabeledContent("UIImage recording path", value: "Removed")
            LabeledContent("Retired paths", value: "Legacy writer and live clip exporter removed")
            LabeledContent("Policy", value: BroadcastProductionDiagnosticLabelsV2.featureFlags(pixelBufferFlags.summaryText))
            Text(BroadcastRecordingStage8Policy.diagnosticsText)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .broadcastMenuCard(cornerRadius: 14)
    }

    private var writerStateCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Writer State").font(RinkLensDesignSystem.font(.bodyStrong))
            LabeledContent("State", value: recorder.state.rawValue)
            LabeledContent("Elapsed", value: recorder.elapsedText)
            LabeledContent("Source", value: recorder.recordingSourceText)
            LabeledContent("Render loop", value: recorder.renderLoopModeText)
            LabeledContent("Health", value: recorder.recordingHealthText)
            LabeledContent("Capture lease", value: recorder.recordingCaptureLeaseText)
            LabeledContent("Source unavailable", value: "\(recorder.cameraSourceDrops)")
            LabeledContent("Sampling duplicates", value: "\(recorder.sourceSamplingMisses)")
            LabeledContent("Cadence", value: recorder.recordingCadenceRatioText)
            LabeledContent("Writer drops", value: "\(recorder.writerDrops)")
            LabeledContent("Render drops", value: "\(recorder.renderDrops)")
            LabeledContent("Current file", value: recorder.currentRecordingURL?.lastPathComponent ?? "--")
            if let error = recorder.lastErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .broadcastMenuCard(cornerRadius: 14)
    }

    private var frameTimingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Frame Timing & Renderer").font(RinkLensDesignSystem.font(.bodyStrong))
            LabeledContent("Frames written", value: "\(recorder.framesWritten)")
            LabeledContent("Frames dropped", value: "\(recorder.framesDropped)")
            LabeledContent("Last frame age", value: recorder.lastFrameAgeText)
            LabeledContent("Target resolution", value: recorder.recordingTargetResolutionText)
            LabeledContent("Target FPS", value: recorder.recordingTargetFPSText)
            LabeledContent("Actual FPS", value: recorder.recordingActualFPSText)
            LabeledContent("FPS warning", value: recorder.recordingFPSWarningText)
            LabeledContent("Encoder backlog", value: recorder.recordingEncoderBacklogText)
            LabeledContent("Renderer mode", value: rendererDiagnostics.renderMode)
            LabeledContent("Renderer target", value: "\(rendererDiagnostics.targetFPS)fps")
            LabeledContent("Renderer actual", value: rendererDiagnostics.actualFPS)
            LabeledContent("Render time", value: rendererDiagnostics.lastRenderTimeMs)
            LabeledContent("Renderer late/merged ticks", value: "\(rendererDiagnostics.renderDrops)")
            LabeledContent("Pacer source", value: pacerDiagnostics.renderPacerSourceText)
            LabeledContent("Tick interval", value: pacerDiagnostics.actualTickIntervalText)
            LabeledContent("Source-clock drift", value: pacerDiagnostics.sourceClockDriftText)
            LabeledContent("Late tick count", value: pacerDiagnostics.lateTickCountText)
            LabeledContent("Late tick reason", value: pacerDiagnostics.lateTickReasonText)
            LabeledContent("Skipped tick", value: pacerDiagnostics.skippedTickReasonText)
            LabeledContent("Dropped/merged ticks", value: pacerDiagnostics.droppedOrMergedRenderTicksText)
            LabeledContent("Main actor wait", value: pacerDiagnostics.mainActorWaitText)
            LabeledContent("Frame input wait", value: pacerDiagnostics.frameInputWaitText)
            LabeledContent("Writer wait", value: pacerDiagnostics.writerWaitText)
            LabeledContent("Pacer summary", value: pacerDiagnostics.lastTickSummaryText)
        }
        .padding(12)
        .broadcastMenuCard(cornerRadius: 14)
    }

    private var exportAndClipCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Clip / Export / Frame Validation").font(RinkLensDesignSystem.font(.bodyStrong))
            LabeledContent("Clip", value: recorder.manualClipExportStateText)
            Text(recorder.manualClipFeedbackText)
                .font(RinkLensDesignSystem.font(.caption))
                .foregroundStyle(recorder.manualClipExportStateText == "Failed" ? .red : .secondary)
            LabeledContent("Rotation", value: recorder.recordingRotationText)
            LabeledContent("Transform", value: recorder.recordingTransformSourceText)
            LabeledContent("Raw frame", value: recorder.recordingRawFrameCorrectionText)
            LabeledContent("Black frames rejected", value: "\(recorder.recordingBlackFrameCount)")
            LabeledContent("First valid frame", value: recorder.recordingFirstValidFrameText)
            LabeledContent("Last written frame", value: recorder.recordingLastWrittenFrameText)
            LabeledContent("Frame validation", value: recorder.recordingFrameValidationText)
            LabeledContent("Clip requested", value: clipBuffer.lastClipExportRequestedDurationText)
            LabeledContent("Clip resolved", value: clipBuffer.lastClipExportResolvedDurationText)
            LabeledContent("Clip window", value: clipBuffer.lastClipExportWindowText)
            LabeledContent("Clip source", value: clipBuffer.lastClipExportSourceText)
            LabeledContent("Clip failure", value: clipBuffer.lastClipExportFailureReasonText)
            LabeledContent("Broadcast frame tap", value: viewModel.broadcastRecordingCameraService.recordingFrameCaptureStatusText)
            LabeledContent("Broadcast frame size", value: viewModel.broadcastRecordingCameraService.recordingFrameSizeText)
            LabeledContent("OCR fallback size", value: viewModel.ocrCameraService.recordingFrameSizeText)
            Text(recorder.lastDebugMessage)
                .font(.caption.monospaced())
                .foregroundStyle(.white.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .broadcastMenuCard(cornerRadius: 14)
    }

    private var recoveryActionsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recovery Actions").font(RinkLensDesignSystem.font(.bodyStrong))
            HStack {
                Button("Save Clip Test") {
                    viewModel.broadcastRecordingCameraService.setRecordingFrameCaptureTargetFPS(recorder.currentTargetFPSValue)
                    viewModel.broadcastRecordingCameraService.enableRecordingFrameCapture(reason: "clip test")
                    recorder.saveSnapshotClip(homeTeam: viewModel.homeTeamName, awayTeam: viewModel.awayTeamName)
                }
                .buttonStyle(.bordered)
                .disabled(!recorder.isRecording)

                Button("Clear Recording Debug") {
                    recorder.clearRecordingDiagnostics()
                }
                .buttonStyle(.bordered)
            }
            .font(.caption)
        }
        .padding(12)
        .broadcastMenuCard(cornerRadius: 14)
    }

}

// UX16d3 removed the unused UIImage/SwiftUI recording frame renderer.
// Preview remains camera-layer based; RecordingWriter owns the only encoded frame path.
#endif
