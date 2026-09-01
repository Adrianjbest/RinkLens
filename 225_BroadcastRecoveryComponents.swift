// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI

// STYLE2 central design system migration: operator chrome/fonts use RinkLensDesignSystem where safe.
import UIKit
import AVFoundation
import Vision
import CoreMedia
import CoreGraphics
import CoreImage
import PhotosUI
import Foundation
#if canImport(MLKitVision) && canImport(MLKitTextRecognition) && canImport(MLKitTextRecognitionLatin)
import MLKitVision
import MLKitTextRecognition
import MLKitTextRecognitionLatin
#endif

// MARK: - v0.8.5b Broadcast Recovery Typecheck Split
// This file intentionally uses many small View structs instead of one large SwiftUI
// expression. This avoids Swift compiler type-check timeouts on iPad/Xcode.

struct BroadcastSafeCameraPageView: View {
    @ObservedObject var viewModel: HockeyScoreboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            BroadcastSafeSectionHeader(
                title: "Broadcast camera",
                systemImage: "video.fill",
                help: "Safe controls for Broadcast mode. Opening debug/recovery controls does not take ownership of the Broadcast preview session. Recovery only runs when you press Recover Camera Preview."
            )

            BroadcastRecoveryCard(viewModel: viewModel)
            BroadcastRotationCard(viewModel: viewModel)
            BroadcastAdvancedCameraSourceCard(viewModel: viewModel)
        }
    }
}

private struct BroadcastSafeSectionHeader: View {
    let title: String
    let systemImage: String
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.headline)

            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct BroadcastRecoveryCard: View {
    @ObservedObject var viewModel: HockeyScoreboardViewModel

    private var service: HockeyCameraService {
        viewModel.liveCameraService
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            recoveryTitle
            recoveryHelpText
            recoveryActions
            BroadcastPreviewRecoveryCard(viewModel: viewModel, service: service)
            BroadcastPreviewStatusGrid(service: service)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var recoveryTitle: some View {
        Label("Broadcast camera recovery", systemImage: "wrench.and.screwdriver.fill")
            .font(RinkLensDesignSystem.font(.caption))
    }

    private var recoveryHelpText: some View {
        Text("Use these controls when the Broadcast preview is visible but stops updating. They are explicit actions only; opening this page will not start, stop, reattach or reprioritise the camera.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var recoveryActions: some View {
        HStack(spacing: 8) {
            Button("Recover Camera Preview") {
                viewModel.requestCameraPreviewRecovery(for: service, reason: "operator recover from broadcast controls")
            }
            .buttonStyle(.borderedProminent)
            .disabled(service.isReconfiguring)

            Button("Refresh Camera List") {
                service.refreshAvailableCameras()
            }
            .buttonStyle(.bordered)
            .disabled(service.isReconfiguring)
        }
    }
}

private struct BroadcastPreviewStatusGrid: View {
    @ObservedObject var service: HockeyCameraService

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            BroadcastStatusRow(title: "Session running", value: service.isSessionRunning ? "Yes" : "No")
            BroadcastStatusRow(title: "Preview attached", value: service.previewLayerAttached ? "Yes" : "No")
            BroadcastStatusRow(title: "Preview ready", value: service.previewLayerReadyForDisplay ? "Yes" : "No")
            BroadcastStatusRow(title: "Last event", value: service.lastLifecycleEventText)
        }
    }
}

private struct BroadcastRotationCard: View {
    @ObservedObject var viewModel: HockeyScoreboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Manual broadcast preview rotation")
                .font(RinkLensDesignSystem.font(.caption))

            rotationButtons

            Text("Current broadcast rotation: \(Int(viewModel.livePreviewRotationOffsetDegrees))°")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var rotationButtons: some View {
        HStack {
            Button { viewModel.rotateLivePreviewCounterClockwise() } label: {
                Label("Rotate Left", systemImage: "rotate.left")
            }
            .buttonStyle(.bordered)

            Button { viewModel.rotateLivePreviewClockwise() } label: {
                Label("Rotate Right", systemImage: "rotate.right")
            }
            .buttonStyle(.borderedProminent)

            Button("Reset") {
                viewModel.resetLivePreviewRotation()
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct BroadcastAdvancedCameraSourceCard: View {
    @ObservedObject var viewModel: HockeyScoreboardViewModel
    @State private var showAdvancedCameraControls = false

    private var service: HockeyCameraService {
        viewModel.liveCameraService
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            helpText

            if showAdvancedCameraControls {
                advancedBody
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Label("Advanced camera source controls", systemImage: "slider.horizontal.3")
                .font(RinkLensDesignSystem.font(.caption))
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showAdvancedCameraControls.toggle()
                }
            } label: {
                Text(showAdvancedCameraControls ? "Hide" : "Show")
                    .font(RinkLensDesignSystem.font(.caption))
                    .frame(minWidth: 58)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(showAdvancedCameraControls ? Color.yellow.opacity(0.9) : Color.black.opacity(0.50), in: Capsule())
                    .foregroundStyle(showAdvancedCameraControls ? Color.black : Color.white)
                    .overlay(Capsule().stroke(showAdvancedCameraControls ? Color.yellow : Color.white.opacity(0.20), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private var helpText: some View {
        Text("Source and recovery controls keep the same compact operator-control layout. Opening this panel does not auto-start, stop, rebuild or reprioritise the camera.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var advancedBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            BroadcastCameraSourceRow(viewModel: viewModel, service: service)
            BroadcastCameraActionButtons(viewModel: viewModel, service: service)
            Divider().opacity(0.35)
            BroadcastCameraStatusGrid(service: service)
            Divider().opacity(0.35)
            BroadcastQualityRows(viewModel: viewModel, service: service)
            Divider().opacity(0.35)
            BroadcastCameraControlRows(viewModel: viewModel, service: service)
        }
    }
}

private struct BroadcastCameraSourceRow: View {
    @ObservedObject var viewModel: HockeyScoreboardViewModel
    @ObservedObject var service: HockeyCameraService

    var body: some View {
        HStack(spacing: 10) {
            Text("Broadcast camera source")
                .font(RinkLensDesignSystem.font(.caption))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            cameraPicker

            if service.selectedCameraID != nil {
                Button("None", role: .destructive) {
                    CameraOwnershipTraceStore.record(.picker, owner: .broadcast, reason: "Broadcast compact picker EXPLICIT None tapped service=\(service.diagnosticInstanceID) current=\(service.selectedCameraID ?? "none")")
                    viewModel.selectLiveCamera(id: iceCastExplicitNoCameraSelectionID)
                }
                .font(.caption.weight(.semibold))
                .disabled(service.isReconfiguring)
            }
        }
    }

    private var cameraPicker: some View {
        Picker("Broadcast camera source", selection: cameraSelectionBinding) {
            Label("Choose camera", systemImage: "camera").tag(iceCastNoCameraSelectionID)
            ForEach(service.availableCameras, id: \.id) { camera in
                Text(camera.isExternal ? "External • \(camera.name)" : "Built-in • \(camera.name)")
                    .tag(camera.id)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .tint(.white)
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(Color.black.opacity(0.45), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
        .disabled(service.isReconfiguring)
    }

    private var cameraSelectionBinding: Binding<String> {
        Binding(
            get: { service.selectedCameraID ?? iceCastNoCameraSelectionID },
            set: { newID in
                CameraOwnershipTraceStore.record(.picker, owner: .broadcast, reason: "Broadcast compact picker setter service=\(service.diagnosticInstanceID) incoming=\(newID) published=\(service.selectedCameraID ?? "none") options=\(service.availableCameras.map { $0.id }.joined(separator: ","))")
                guard newID != iceCastNoCameraSelectionID else {
                    CameraOwnershipTraceStore.record(.picker, owner: .broadcast, reason: "Broadcast compact picker transient fallback ignored service=\(service.diagnosticInstanceID)")
                    return
                }
                viewModel.selectLiveCamera(id: newID)
            }
        )
    }
}

private struct BroadcastCameraActionButtons: View {
    @ObservedObject var viewModel: HockeyScoreboardViewModel
    @ObservedObject var service: HockeyCameraService

    var body: some View {
        HStack(spacing: 8) {
            BroadcastPillButton(title: "Refresh", systemImage: "arrow.clockwise", isPrimary: false) {
                service.refreshAvailableCameras()
            }
            .disabled(service.isReconfiguring)

            BroadcastPillButton(title: "Recover Preview", systemImage: "wrench.and.screwdriver.fill", isPrimary: true) {
                viewModel.requestCameraPreviewRecovery(for: service, reason: "operator recover from broadcast controls")
            }
            .disabled(service.isReconfiguring)
        }
    }
}

private struct BroadcastCameraStatusGrid: View {
    @ObservedObject var service: HockeyCameraService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            BroadcastStatusRow(title: "Session running", value: service.isSessionRunning ? "Yes" : "No")
            BroadcastStatusRow(title: "Preview attached", value: service.previewLayerAttached ? "Yes" : "No")
            BroadcastStatusRow(title: "Preview ready", value: service.previewLayerReadyForDisplay ? "Yes" : "No")
            BroadcastStatusRow(title: "Selected format", value: service.selectedResolutionFPS)
            BroadcastStatusRow(title: "Status", value: service.cameraStatusText)
            BroadcastStatusRow(title: "Last event", value: service.lastLifecycleEventText)
        }
    }
}

private struct BroadcastQualityRows: View {
    @ObservedObject var viewModel: HockeyScoreboardViewModel
    @ObservedObject var service: HockeyCameraService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            qualityHeader
            qualityStatus
            qualityActions
        }
    }

    private var qualityHeader: some View {
        HStack {
            Text("Quality")
                .font(RinkLensDesignSystem.font(.caption))
            Spacer()
            Text(service.videoFormatsLoaded ? "Formats loaded" : "Formats not loaded")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var qualityStatus: some View {
        Text(service.videoFormatLoadStatusText)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var qualityActions: some View {
        HStack(spacing: 8) {
            BroadcastPillButton(title: service.isLoadingVideoFormats ? "Refreshing" : "Refresh Formats", systemImage: "arrow.clockwise", isPrimary: false) {
                service.refreshVideoFormats(force: true)
            }
            .disabled(service.isReconfiguring || service.isLoadingVideoFormats)

            NavigationLink {
                VideoCompressionProfilePickerView(cameraService: service)
            } label: {
                BroadcastPillLabel(title: "Format", systemImage: "film", value: service.selectedCompressionProfile.rawValue)
            }
            .buttonStyle(.plain)
            .disabled(service.isReconfiguring)

            NavigationLink {
                VideoResolutionPickerView(
                    cameraService: service,
                    onSelectProfile: { viewModel.selectLiveCapabilityProfile(id: $0) }
                )
            } label: {
                BroadcastPillLabel(title: "Resolution", systemImage: "rectangle.expand.vertical", value: service.selectedResolutionLabel)
            }
            .buttonStyle(.plain)
            .disabled(service.isReconfiguring || service.isLoadingVideoFormats || service.capabilityProfiles.isEmpty)
        }
    }
}

private struct BroadcastCameraControlRows: View {
    @ObservedObject var viewModel: HockeyScoreboardViewModel
    @ObservedObject var service: HockeyCameraService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            zoomHeader
            zoomSlider
            BroadcastStatusRow(title: "Focus mode", value: service.focusModeText)
            BroadcastStatusRow(title: "Exposure mode", value: service.exposureModeText)
            focusControls
            exposureControls
        }
    }

    private var zoomHeader: some View {
        HStack {
            Text("Independent broadcast zoom")
                .font(RinkLensDesignSystem.font(.caption))
            Spacer()
            Text(String(format: "%.1fx", Double(viewModel.liveCameraZoomFactor)))
                .font(RinkLensDesignSystem.font(.caption))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var zoomSlider: some View {
        Group {
            if liveZoomRangeIsUsable {
                Slider(value: liveZoomBinding, in: safeLiveZoomRange)
                    .disabled(service.isReconfiguring)
            } else {
                Text("Zoom fixed for current camera")
                    .font(RinkLensDesignSystem.font(.caption))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var safeLiveZoomRange: ClosedRange<Double> {
        let lower = service.minZoomFactor.isFinite ? Swift.max(0.1, Double(service.minZoomFactor)) : 1.0
        let rawUpper = service.maxZoomFactor.isFinite ? Double(service.maxZoomFactor) : lower
        let upper = Swift.max(lower, rawUpper)
        return lower...upper
    }

    private var liveZoomRangeIsUsable: Bool {
        safeLiveZoomRange.upperBound > safeLiveZoomRange.lowerBound + 0.01
    }

    private var liveZoomBinding: Binding<Double> {
        Binding(
            get: { Swift.min(Swift.max(Double(viewModel.liveCameraZoomFactor), safeLiveZoomRange.lowerBound), safeLiveZoomRange.upperBound) },
            set: { viewModel.setLiveCameraZoom(CGFloat(Swift.min(Swift.max($0, safeLiveZoomRange.lowerBound), safeLiveZoomRange.upperBound))) }
        )
    }

    @ViewBuilder
    private var focusControls: some View {
        if service.supportsManualFocus {
            Slider(value: focusBinding, in: 0...1)
                .disabled(service.isReconfiguring)

            BroadcastPillButton(title: "Continuous Auto Focus", systemImage: "viewfinder", isPrimary: false) {
                service.setContinuousAutoFocus()
            }
            .disabled(service.isReconfiguring)
        } else {
            Text("Manual focus unavailable on connected camera.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var focusBinding: Binding<Double> {
        Binding(
            get: { Double(service.focusPosition) },
            set: { service.setManualFocus(position: Float($0)) }
        )
    }

    @ViewBuilder
    private var exposureControls: some View {
        if service.supportsManualISO {
            Slider(value: isoBinding, in: Double(service.minISO)...Double(service.maxISO))
                .disabled(service.isReconfiguring)

            BroadcastStatusRow(title: "ISO / Gain", value: "\(Int(service.isoValue))")

            HStack(spacing: 8) {
                BroadcastPillButton(title: "Lock Exposure", systemImage: "lock.fill", isPrimary: false) {
                    service.lockCurrentExposure()
                }
                .disabled(service.isReconfiguring)

                BroadcastPillButton(title: "Auto Exposure", systemImage: "camera.aperture", isPrimary: false) {
                    service.setAutoExposure()
                }
                .disabled(service.isReconfiguring)
            }
        } else {
            Text("Manual ISO unavailable on connected camera.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var isoBinding: Binding<Double> {
        Binding(
            get: { Double(service.isoValue) },
            set: { service.setManualISO(Float($0)) }
        )
    }
}

struct BroadcastPreviewRecoveryCard: View {
    @ObservedObject var viewModel: HockeyScoreboardViewModel
    @ObservedObject var service: HockeyCameraService

    private var diagnosticsStopped: Bool {
        !service.isSessionRunning
    }

    private var previewBroken: Bool {
        service.previewLayerAttached && !service.previewLayerReadyForDisplay
    }

    private var shouldRecover: Bool {
        diagnosticsStopped || previewBroken
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            recoveryButtonSection
            statusMessagesSection
        }
    }

    @ViewBuilder
    private var recoveryButtonSection: some View {
        if shouldRecover {
            Button(action: performRecovery) {
                recoveryButtonLabel
            }
            .buttonStyle(.borderedProminent)
            .disabled(service.isReconfiguring)
        }
    }

    private var recoveryButtonLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.clockwise.circle.fill")

            Text("Recover Camera Preview")
                .fontWeight(.semibold)
        }
    }

    @ViewBuilder
    private var statusMessagesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if diagnosticsStopped {
                Text("Broadcast preview session stopped")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            if previewBroken {
                Text("Preview attached but not ready")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    private func performRecovery() {
        viewModel.requestCameraPreviewRecovery(for: service, reason: "operator recover from broadcast controls")
    }
}

private struct BroadcastStatusRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(value)
                .font(RinkLensDesignSystem.font(.caption))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

private struct BroadcastPillButton: View {
    let title: String
    let systemImage: String
    let isPrimary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(RinkLensDesignSystem.font(.caption))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .padding(.horizontal, 10)
                .background(backgroundColor, in: Capsule())
                .foregroundStyle(foregroundColor)
                .overlay(Capsule().stroke(strokeColor, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var backgroundColor: Color {
        isPrimary ? Color.yellow.opacity(0.9) : Color.black.opacity(0.50)
    }

    private var foregroundColor: Color {
        isPrimary ? Color.black : Color.white
    }

    private var strokeColor: Color {
        isPrimary ? Color.yellow : Color.white.opacity(0.20)
    }
}

private struct BroadcastPillLabel: View {
    let title: String
    let systemImage: String
    let value: String

    var body: some View {
        Label {
            HStack(spacing: 4) {
                Text(title)
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        } icon: {
            Image(systemName: systemImage)
        }
        .font(RinkLensDesignSystem.font(.caption))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(Color.black.opacity(0.50), in: Capsule())
        .foregroundStyle(Color.white)
        .overlay(Capsule().stroke(Color.white.opacity(0.20), lineWidth: 1))
    }
}

#endif
