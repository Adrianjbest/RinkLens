// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI

// STYLE2 central design system migration: operator chrome/fonts use RinkLensDesignSystem where safe.
import AVFoundation
import Vision
import CoreMedia
import CoreGraphics
import PhotosUI
import Foundation
#if canImport(MLKitVision) && canImport(MLKitTextRecognition) && canImport(MLKitTextRecognitionLatin)
import MLKitVision
import MLKitTextRecognition
import MLKitTextRecognitionLatin
#endif

struct CameraSettingsSheet: View {
    @ObservedObject var viewModel: HockeyScoreboardViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                CameraSetupSettingsEmbeddedView(viewModel: viewModel)
                    .padding(20)
                    .frame(maxWidth: 1060, alignment: .center)
                    .frame(maxWidth: .infinity)
            }
            .navigationTitle("Camera selection")
            .background(RinkLensDesignSystem.screenBackground)
        }
        .preferredColorScheme(.dark)
    }
}

struct CameraConfigurationSection: View {
    @ObservedObject private var uiStallMonitor = MainThreadStallMonitor.shared

    let title: String
    let pickerTitle: String
    @ObservedObject var service: HockeyCameraService
    let framesReceivedText: String
    let noFramesText: String
    let zoomLabel: String
    let zoom: Binding<CGFloat>
    var showStationaryLockControls: Bool = false
    var showFormatQualityControls: Bool = true
    let onSelect: (String?) -> Void
    let onSelectProfile: (String) -> Void
    let onRefresh: () -> Void
    let onRecover: () -> Void

    private var safeZoomRange: ClosedRange<Double> {
        let lower = service.minZoomFactor.isFinite ? Swift.max(0.1, Double(service.minZoomFactor)) : 1.0
        let rawUpper = service.maxZoomFactor.isFinite ? Double(service.maxZoomFactor) : lower
        let upper = Swift.max(lower, rawUpper)
        return lower...upper
    }

    private var zoomRangeIsUsable: Bool {
        safeZoomRange.upperBound > safeZoomRange.lowerBound + 0.01
    }

    private var clampedZoomValue: Double {
        Swift.min(
            Swift.max(Double(zoom.wrappedValue.isFinite ? zoom.wrappedValue : CGFloat(safeZoomRange.lowerBound)), safeZoomRange.lowerBound),
            safeZoomRange.upperBound
        )
    }

    var body: some View {
        Section(title) {
            CameraSourcePickerView(
                title: pickerTitle,
                service: service,
                framesReceivedText: framesReceivedText,
                noFramesText: noFramesText,
                onSelect: onSelect
            )

            if service.isReconfiguring {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(service.cameraStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(service.cameraStatusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button("Refresh Cameras") {
                onRefresh()
            }
            .buttonStyle(.bordered)
            .disabled(service.isReconfiguring)

            Button("Recover Camera Preview") {
                onRecover()
            }
            .buttonStyle(.bordered)
            .disabled(service.isReconfiguring)

            Text("Use Recover Camera Preview if the video goes black. It performs the same kind of capture pipeline rebuild as changing video resolution, without changing your selected settings.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text("Application diagnostics have moved to Operator Controls > Diagnostics. Use the Diagnostics tab for shared Broadcast and Calibration debug, recovery, and reset actions.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if showFormatQualityControls {
            Section("\(title) quality") {
                Text("Selected format: \(service.selectedResolutionFPS)")
                    .font(.caption)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Format cache")
                        Spacer()
                        if service.isLoadingVideoFormats {
                            ProgressView()
                        }
                        Text(service.videoFormatsLoaded ? "Loaded" : "Not loaded")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(service.videoFormatLoadStatusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("v0.8.4h: camera formats are not rescanned when this tab opens. Use Refresh Formats only when you change camera hardware or need to select a different resolution.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    service.refreshVideoFormats(force: true)
                } label: {
                    Label(service.isLoadingVideoFormats ? "Refreshing Formats" : "Refresh Formats", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(service.isReconfiguring || service.isLoadingVideoFormats)

                NavigationLink {
                    VideoCompressionProfilePickerView(cameraService: service)
                } label: {
                    HStack {
                        Text("Video Format")
                        Spacer()
                        Text(service.selectedCompressionProfile.rawValue)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(service.isReconfiguring)

                NavigationLink {
                    VideoResolutionPickerView(
                        cameraService: service,
                        onSelectProfile: onSelectProfile
                    )
                } label: {
                    HStack {
                        Text("Video Resolution")
                        Spacer()
                        Text(service.selectedResolutionLabel)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(service.isReconfiguring || service.isLoadingVideoFormats || service.capabilityProfiles.isEmpty)
            }
        }

        Section("\(title) controls") {
            HStack {
                Text(zoomLabel)
                Spacer()
                Text(String(format: "%.1fx", Double(zoom.wrappedValue)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if zoomRangeIsUsable {
                Slider(
                    value: Binding(
                        get: { clampedZoomValue },
                        set: { zoom.wrappedValue = CGFloat(Swift.min(Swift.max($0, safeZoomRange.lowerBound), safeZoomRange.upperBound)) }
                    ),
                    in: safeZoomRange
                )
                .disabled(service.isReconfiguring)
            } else {
                Text("Zoom is fixed/unavailable for this camera feed.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Active camera: \(service.activeCameraDeviceDetailsText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Active format: \(service.activeCameraFormatDetailsText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Focus mode: \(service.focusModeText)")
                .font(.caption)
            Text("Exposure mode: \(service.exposureModeText)")
                .font(.caption)
            Text("White balance mode: \(service.whiteBalanceModeText)")
                .font(.caption)

            if showStationaryLockControls {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Stationary scoreboard camera lock")
                        .font(RinkLensDesignSystem.font(.caption))
                    Text(service.stationaryHardwareLockText)
                        .font(.caption2)
                        .foregroundStyle(service.stationaryHardwareLockActive ? .green : .secondary)
                    Text("Apply after setup when the external scoreboard camera is fixed. This locks supported focus, exposure and white balance so the scoreboard camera does not hunt while the iPad/Broadcast camera moves.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Lock Stationary Scoreboard Camera") {
                            service.lockForStationaryRole(label: "Scoreboard camera")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(service.isReconfiguring)

                        Button("Unlock") {
                            service.unlockStationaryRole(label: "Scoreboard camera")
                        }
                        .buttonStyle(.bordered)
                        .disabled(service.isReconfiguring)
                    }
                }
                .padding(.vertical, 4)
            }

            if service.supportsManualFocus {
                Slider(
                    value: Binding(
                        get: { Double(service.focusPosition) },
                        set: { service.setManualFocus(position: Float($0)) }
                    ),
                    in: 0...1
                )
                .disabled(service.isReconfiguring)
                Button("Use Continuous Auto Focus") {
                    service.setContinuousAutoFocus()
                }
                .buttonStyle(.bordered)
                .disabled(service.isReconfiguring)
            } else {
                Text("Manual focus unavailable on connected camera.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if service.supportsManualISO {
                Slider(
                    value: Binding(
                        get: { Double(service.isoValue) },
                        set: { service.setManualISO(Float($0)) }
                    ),
                    in: Double(service.minISO)...Double(service.maxISO)
                )
                .disabled(service.isReconfiguring)
                Text("ISO / Gain: \(Int(service.isoValue))")
                    .font(.caption)
                HStack {
                    Button("Lock Exposure") {
                        service.lockCurrentExposure()
                    }
                    .buttonStyle(.bordered)
                    .disabled(service.isReconfiguring)
                    Button("Auto Exposure") {
                        service.setAutoExposure()
                    }
                    .buttonStyle(.bordered)
                    .disabled(service.isReconfiguring)
                }
            } else {
                Text("Manual ISO unavailable on connected camera.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if service.supportsManualExposureDuration,
               service.minExposureDurationSeconds.isFinite,
               service.maxExposureDurationSeconds.isFinite,
               service.maxExposureDurationSeconds > service.minExposureDurationSeconds {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Shutter: \(service.shutterSpeedText)")
                        .font(.caption)
                    Slider(
                        value: Binding(
                            get: { min(max(service.exposureDurationSeconds, service.minExposureDurationSeconds), service.maxExposureDurationSeconds) },
                            set: { service.setManualExposureDuration(seconds: $0) }
                        ),
                        in: service.minExposureDurationSeconds...service.maxExposureDurationSeconds
                    )
                    .disabled(service.isReconfiguring)
                }
            }

            if service.supportsExposureBias,
               service.maxExposureTargetBias > service.minExposureTargetBias {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(format: "Exposure bias: %.1f", Double(service.exposureTargetBiasValue)))
                        .font(.caption)
                    Slider(
                        value: Binding(
                            get: { Double(service.exposureTargetBiasValue) },
                            set: { service.setExposureTargetBias(Float($0)) }
                        ),
                        in: Double(service.minExposureTargetBias)...Double(service.maxExposureTargetBias)
                    )
                    .disabled(service.isReconfiguring)
                }
            }

            if service.supportsManualWhiteBalanceGains {
                VStack(alignment: .leading, spacing: 6) {
                    Text("White balance")
                        .font(.caption)
                    Text("Temperature \(Int(service.whiteBalanceTemperature))K · Tint \(Int(service.whiteBalanceTint))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { Double(service.whiteBalanceTemperature) },
                            set: { service.setManualWhiteBalance(temperature: Float($0), tint: service.whiteBalanceTint) }
                        ),
                        in: 2500...8000
                    )
                    .disabled(service.isReconfiguring)
                    Slider(
                        value: Binding(
                            get: { Double(service.whiteBalanceTint) },
                            set: { service.setManualWhiteBalance(temperature: service.whiteBalanceTemperature, tint: Float($0)) }
                        ),
                        in: -50...50
                    )
                    .disabled(service.isReconfiguring)
                    HStack {
                        Button("Lock White Balance") {
                            service.lockCurrentWhiteBalance()
                        }
                        .buttonStyle(.bordered)
                        .disabled(service.isReconfiguring)

                        Button("Auto White Balance") {
                            service.setAutoWhiteBalance()
                        }
                        .buttonStyle(.bordered)
                        .disabled(service.isReconfiguring)
                    }
                }
            } else {
                Text("Manual white balance unavailable on connected camera.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}



typealias LiveCameraSettingsSheet = CameraSettingsSheet

#endif
