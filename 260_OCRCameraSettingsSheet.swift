// BUILD 725 STATE CONTRACT: Settings selects the camera; Scoreboard Setup owns OCR profile and lens overrides. UI changes are projections only.
#if canImport(SwiftUI)
import SwiftUI
import AVFoundation
import Foundation

@MainActor
struct OCRCameraSettingsSheet: View {
    @ObservedObject var settingsViewModel: OCRCameraSettingsViewModel

    private var service: HockeyCameraService { settingsViewModel.ocrCameraService }
    private var operationalOverridesEnabled: Bool {
        RinkLensRiskFeaturePolicy.isEnabled(.operationalCameraOverridesV10)
    }
    private var minimalControlsEnabled: Bool {
        RinkLensRiskFeaturePolicy.isEnabled(.minimalOperatorCameraRecordingV12)
    }

    var body: some View {
        NavigationStack {
            if minimalControlsEnabled {
                minimalForm
            } else {
                legacyForm
            }
        }
        .onAppear {
            settingsViewModel.beginCameraSettingsInteraction()
        }
        .onDisappear {
            settingsViewModel.endCameraSettingsInteraction()
        }
    }

    private var minimalForm: some View {
        Form {
            Section("Source") {
                CameraSourcePickerView(
                    title: "Scoreboard camera",
                    service: service,
                    framesReceivedText: "Frames received from scoreboard camera",
                    noFramesText: "No scoreboard camera frames received yet",
                    onSelect: { settingsViewModel.selectOCRCamera(id: $0) }
                )

                Button {
                    settingsViewModel.refreshAvailableCameras()
                } label: {
                    Label("Refresh Cameras", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(service.isReconfiguring)
            }

            Section("Camera") {
                LabeledContent("Selected", value: service.selectedCameraLabel)
                LabeledContent("Format", value: service.selectedResolutionFPS)

                HStack(spacing: 8) {
                    Button("1080p30 Auto") {
                        settingsViewModel.applyOCRRoleDefaultProfile()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(service.isReconfiguring)

                    Picker("Format", selection: Binding<String>(
                        get: { service.roleDefaultProfileEnabled ? "" : (service.selectedCapabilityProfileID ?? "") },
                        set: { id in
                            guard !id.isEmpty else { return }
                            settingsViewModel.selectOCRCapabilityProfile(id: id)
                        }
                    )) {
                        Text("Default").tag("")
                        ForEach(service.capabilityProfiles) { profile in
                            Text(profile.displayLabel).tag(profile.id)
                        }
                    }
                    .disabled(service.isReconfiguring || service.capabilityProfiles.isEmpty)
                }
            }

            Section("Image") {
                Toggle("Automatic image", isOn: Binding(
                    get: { service.appleStyleAutoQualityEnabled },
                    set: { settingsViewModel.setAutomaticLensControls($0) }
                ))
                .disabled(service.isReconfiguring || !service.hasAnyAutomaticLensControl)

                LabeledContent("Zoom", value: String(format: "%.1fx", Double(settingsViewModel.cameraZoomFactor)))
                Slider(
                    value: Binding(
                        get: { min(max(Double(settingsViewModel.cameraZoomFactor), minimumZoom), maximumZoom) },
                        set: { settingsViewModel.setOCRCameraZoom(CGFloat($0)) }
                    ),
                    in: minimumZoom...maximumZoom
                )
                .disabled(service.isReconfiguring || maximumZoom <= minimumZoom)
            }

            if !service.appleStyleAutoQualityEnabled {
                manualImageSection
            }

            Section("Position") {
                HStack(spacing: 8) {
                    Button("Left") { settingsViewModel.rotateOCRPreviewCounterClockwise() }
                    Button("Right") { settingsViewModel.rotateOCRPreviewClockwise() }
                    Button("Reset") { settingsViewModel.resetOCRPreviewRotation() }
                }
                .buttonStyle(.bordered)

                HStack(spacing: 8) {
                    Button("Lock Camera") { service.lockForStationaryRole(label: "scoreboard camera") }
                    Button("Unlock") { service.unlockStationaryRole(label: "scoreboard camera") }
                }
                .disabled(service.isReconfiguring)
            }

            Section("Recovery") {
                HStack(spacing: 8) {
                    Button("Refresh Camera") { settingsViewModel.refreshAvailableCameras() }
                        .buttonStyle(.borderedProminent)
                    Button("Recover Preview") { settingsViewModel.recoverPreview() }
                        .buttonStyle(.bordered)
                }
                .disabled(service.isReconfiguring)
            }
        }
        .navigationTitle("Scoreboard Camera")
        .environment(\.isEnabled, operationalOverridesEnabled)
    }

    @ViewBuilder
    private var manualImageSection: some View {
        Section("Manual Image") {
            if service.supportsManualFocus {
                LabeledContent("Focus", value: String(format: "%.2f", Double(service.focusPosition)))
                Slider(
                    value: Binding(
                        get: { Double(service.focusPosition) },
                        set: { service.setManualFocus(position: Float($0)) }
                    ),
                    in: 0...1
                )
            }

            if service.supportsManualISO, service.maxISO > service.minISO {
                LabeledContent("ISO", value: "\(Int(service.isoValue))")
                Slider(
                    value: Binding(
                        get: { Double(service.isoValue) },
                        set: { service.setManualISO(Float($0)) }
                    ),
                    in: Double(service.minISO)...Double(service.maxISO)
                )
            }

            HStack(spacing: 8) {
                if service.supportsAutoFocus {
                    Button("Auto Focus") { service.setContinuousAutoFocus() }
                }
                if service.supportsAutoExposure {
                    Button("Auto Exposure") { service.setAutoExposure() }
                }
                if service.supportsAutoWhiteBalance {
                    Button("Auto White Balance") { service.setAutoWhiteBalance() }
                }
            }
            .buttonStyle(.bordered)
            .disabled(service.isReconfiguring)
        }
    }

    private var minimumZoom: Double {
        Double(max(0.5, service.minZoomFactor))
    }

    private var maximumZoom: Double {
        Double(max(max(0.5, service.minZoomFactor), service.maxZoomFactor))
    }

    private var legacyForm: some View {
        Form {
            if !operationalOverridesEnabled {
                Section("Rollout comparison") {
                    Text("Operational OCR camera overrides are disabled. Use the legacy Camera Setup path while comparing the previous behaviour.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Scoreboard camera profile") {
                Text("Default: 1920×1080 at 30 fps with automatic focus, exposure and white balance. Camera assignment remains in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Camera", value: service.selectedCameraLabel)
                LabeledContent("Requested / applied", value: service.selectedResolutionFPS)

                Button {
                    settingsViewModel.applyOCRRoleDefaultProfile()
                } label: {
                    Label("Use OCR Default — 1080p30 Auto", systemImage: "arrow.counterclockwise.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(service.isReconfiguring)

                Picker("Resolution / FPS override", selection: Binding<String>(
                    get: { service.roleDefaultProfileEnabled ? "" : (service.selectedCapabilityProfileID ?? "") },
                    set: { id in
                        guard !id.isEmpty else { return }
                        settingsViewModel.selectOCRCapabilityProfile(id: id)
                    }
                )) {
                    Text("Default — 1080p30 Auto").tag("")
                    ForEach(service.capabilityProfiles) { profile in
                        Text(profile.displayLabel).tag(profile.id)
                    }
                }
                .disabled(service.isReconfiguring || service.capabilityProfiles.isEmpty)
            }

            Section("Automatic image controls") {
                Toggle("Automatic focus, exposure and white balance", isOn: Binding(
                    get: { service.appleStyleAutoQualityEnabled },
                    set: { settingsViewModel.setAutomaticLensControls($0) }
                ))
                .disabled(service.isReconfiguring || !service.hasAnyAutomaticLensControl)
            }

            Section("Zoom") {
                Slider(
                    value: Binding(
                        get: { Double(settingsViewModel.cameraZoomFactor) },
                        set: { settingsViewModel.setOCRCameraZoom(CGFloat($0)) }
                    ),
                    in: minimumZoom...maximumZoom
                )
                .disabled(service.isReconfiguring || maximumZoom <= minimumZoom)
                Text(String(format: "%.1fx", Double(settingsViewModel.cameraZoomFactor)))
                    .font(.caption.monospacedDigit())
            }

            Section("Stationary scoreboard camera") {
                Text(service.stationaryHardwareLockText)
                    .font(.caption)
                HStack {
                    Button("Lock") { service.lockForStationaryRole(label: "scoreboard camera") }
                    Button("Unlock") { service.unlockStationaryRole(label: "scoreboard camera") }
                }
                .disabled(service.isReconfiguring)
            }

            Section("Preview rotation") {
                HStack {
                    Button("Rotate Left") { settingsViewModel.rotateOCRPreviewCounterClockwise() }
                    Button("Rotate Right") { settingsViewModel.rotateOCRPreviewClockwise() }
                }
                Button("Reset Rotation") { settingsViewModel.resetOCRPreviewRotation() }
                Text("Current: \(Int(settingsViewModel.ocrPreviewRotationOffsetDegrees.rounded()))°")
                    .font(.caption.monospacedDigit())
            }
        }
        .navigationTitle("OCR Camera Controls")
        .environment(\.isEnabled, operationalOverridesEnabled)
    }
}

#endif
