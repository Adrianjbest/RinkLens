// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation
import SwiftUI
import UIKit

// STYLE2 central design system migration: operator chrome/fonts use RinkLensDesignSystem where safe.

// MARK: - v0.9.1q Calibration Controls Consolidation

enum CalibrationControlHubPage: String, CaseIterable, Identifiable {
    case zones = "Zones"
    case colour = "Colours"
    case ocr = "Recognition"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .zones: return "square.dashed"
        case .colour: return "paintpalette"
        case .ocr: return "text.viewfinder"
        }
    }
}

@MainActor
struct CalibrationControlHubSheet: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: HockeyScoreboardViewModel
    @StateObject private var refreshDriver = OperatorControlsRefreshDriver()
    let initialPage: CalibrationControlHubPage
    @Binding var calibrationToolsVisible: Bool
    @Binding var calibrationToolsMounted: Bool
    @Binding var diagnosticsPanelEnabled: Bool
    @Binding var showingTestOCRPanel: Bool
    let onRunTestOCR: (String) -> Void
    let onOpenTemplateSettings: () -> Void

    @State private var selectedPage: CalibrationControlHubPage

    init(
        viewModel: HockeyScoreboardViewModel,
        initialPage: CalibrationControlHubPage = .zones,
        calibrationToolsVisible: Binding<Bool>,
        calibrationToolsMounted: Binding<Bool>,
        diagnosticsPanelEnabled: Binding<Bool>,
        showingTestOCRPanel: Binding<Bool>,
        onRunTestOCR: @escaping (String) -> Void,
        onOpenTemplateSettings: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.initialPage = initialPage
        self._selectedPage = State(initialValue: initialPage)
        self._calibrationToolsVisible = calibrationToolsVisible
        self._calibrationToolsMounted = calibrationToolsMounted
        self._diagnosticsPanelEnabled = diagnosticsPanelEnabled
        self._showingTestOCRPanel = showingTestOCRPanel
        self.onRunTestOCR = onRunTestOCR
        self.onOpenTemplateSettings = onOpenTemplateSettings
    }

    var body: some View {
        let _ = refreshDriver.refreshID
        NavigationStack {
            ZStack {
                BroadcastMenuBackgroundView()

                VStack(spacing: 0) {
                    pagePicker
                    sharedZoneSelector

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            switch selectedPage {
                            case .zones:
                                CalibrationZonesWorkflowPanel(
                                    viewModel: viewModel,
                                    calibrationToolsVisible: $calibrationToolsVisible,
                                    calibrationToolsMounted: $calibrationToolsMounted,
                                    diagnosticsPanelEnabled: $diagnosticsPanelEnabled,
                                    showingTestOCRPanel: $showingTestOCRPanel,
                                    onOpenTemplateSettings: onOpenTemplateSettings,
                                    onDismissForZoneEditing: {
                                        MainThreadStallMonitor.shared.markContext("sheet dismissed before zone edit")
                                        dismiss()
                                    }
                                )
                            case .colour:
                                CalibrationOCRColourProfilesPanel(
                                    viewModel: viewModel,
                                    refreshID: refreshDriver.refreshID,
                                    onRefresh: { refreshDriver.bump(reason: $0) }
                                )
                            case .ocr:
                                CalibrationOCRPanel(
                                    viewModel: viewModel,
                                    refreshID: refreshDriver.refreshID,
                                    onRefresh: { refreshDriver.bump(reason: $0) },
                                    showingTestOCRPanel: $showingTestOCRPanel,
                                    diagnosticsPanelEnabled: $diagnosticsPanelEnabled,
                                    onRunTestOCR: onRunTestOCR,
                                    onOpenTemplateSettings: onOpenTemplateSettings
                                )
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 18)
                    }
                    .rinkLensScrollPerformance("CalibrationControlHub")
                }
            }
            .navigationTitle("Calibration Controls")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .broadcastMenuText()
        .onAppear {
            refreshDriver.start()
            MainThreadStallMonitor.shared.markContext("Calibration controls hub opened: \(selectedPage.rawValue)")
        }
        .onDisappear {
            refreshDriver.stop()
            MainThreadStallMonitor.shared.markContext("Calibration controls hub dismissed")
        }
        .onChange(of: selectedPage) { _, page in
            refreshDriver.bump(reason: "calibration controls page: \(page.rawValue)")
            MainThreadStallMonitor.shared.markContext("Calibration controls page: \(page.rawValue)")
        }
    }

    private var pagePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(CalibrationControlHubPage.allCases) { page in
                    Button {
                        selectedPage = page
                    } label: {
                        Label(page.rawValue, systemImage: page.systemImage)
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .frame(minWidth: 145)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(page == selectedPage ? .black : .white.opacity(0.72))
                    .background(page == selectedPage ? Color.white : Color.white.opacity(0.08))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
                }
            }
            .padding(6)
        }
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    /// One shared selector owns the active scoreboard field for all three pages.
    /// Build 734 removes the separate Zones, Colours and Recognition pickers so
    /// changing page never presents competing controls for the same state.
    private var sharedZoneSelector: some View {
        HStack(spacing: 10) {
            Label("Selected zone", systemImage: "viewfinder")
                .font(RinkLensDesignSystem.font(.caption))
                .foregroundStyle(.white.opacity(0.72))

            Spacer(minLength: 8)

            Picker(
                "Selected scoreboard zone",
                selection: Binding(
                    get: { viewModel.selectedRegionKey },
                    set: { newKey in
                        viewModel.selectOCRRegion(newKey)
                        refreshDriver.bump(reason: "shared calibration zone: \(newKey.rawValue)")
                        MainThreadStallMonitor.shared.markContext("Calibration shared zone selected: \(newKey.rawValue)")
                    }
                )
            ) {
                ForEach(OCRRegionKey.calibrationCases) { key in
                    Text(key.likelyTitle).tag(key)
                }
            }
            .pickerStyle(.menu)
            .tint(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .broadcastMenuCard(cornerRadius: 14, opacity: 0.52)
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

}

private enum CalibrationCameraSubmenu: String, CaseIterable, Identifiable {
    case source = "Source"
    case manual = "Manual"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .source: return "camera.badge.ellipsis"
        case .manual: return "dial.medium"
        }
    }
}

private struct CalibrationCameraWorkflowPanel: View {
    let viewModel: HockeyScoreboardViewModel
    let refreshID: Int
    let onRefresh: (String) -> Void
    @State private var selectedSubmenu: CalibrationCameraSubmenu = .source

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CalibrationHubSectionHeader(
                title: "Camera",
                systemImage: "camera.viewfinder",
                help: "One clean calibration camera workflow: Source and Manual. Camera diagnostics now live under the main Diagnostics tab."
            )

            CalibrationCameraSubmenuBar(selectedSubmenu: $selectedSubmenu)

            switch selectedSubmenu {
            case .source:
                CalibrationCameraSourceSubmenu(viewModel: viewModel, refreshID: refreshID, onRefresh: onRefresh)
            case .manual:
                CalibrationCameraManualSettingsSubmenu(viewModel: viewModel)
            }
        }
    }
}

private struct CalibrationCameraSubmenuBar: View {
    @Binding var selectedSubmenu: CalibrationCameraSubmenu

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CalibrationCameraSubmenu.allCases) { submenu in
                    Button {
                        selectedSubmenu = submenu
                        MainThreadStallMonitor.shared.markContext("Calibration camera submenu: \(submenu.rawValue)")
                    } label: {
                        Label(submenu.rawValue, systemImage: submenu.systemImage)
                            .font(RinkLensDesignSystem.font(.caption))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(tabBackground(for: submenu), in: Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(tabBorder(for: submenu), lineWidth: 1)
                            )
                            .foregroundStyle(selectedSubmenu == submenu ? .black : .white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Camera \(submenu.rawValue)")
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tabBackground(for submenu: CalibrationCameraSubmenu) -> Color {
        selectedSubmenu == submenu ? Color.cyan.opacity(0.92) : Color.black.opacity(0.42)
    }

    private func tabBorder(for submenu: CalibrationCameraSubmenu) -> Color {
        selectedSubmenu == submenu ? Color.cyan.opacity(0.9) : Color.white.opacity(0.18)
    }
}

private struct CalibrationZonesWorkflowPanel: View {
    @ObservedObject var viewModel: HockeyScoreboardViewModel
    @Binding var calibrationToolsVisible: Bool
    @Binding var calibrationToolsMounted: Bool
    @Binding var diagnosticsPanelEnabled: Bool
    @Binding var showingTestOCRPanel: Bool
    let onOpenTemplateSettings: () -> Void
    let onDismissForZoneEditing: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CalibrationHubSectionHeader(
                title: "Zones",
                systemImage: "square.dashed",
                help: "Show the zone overlay, select a zone, resize directly on the live preview and save the layout."
            )
            CalibrationZonesPanel(
                viewModel: viewModel,
                calibrationToolsVisible: $calibrationToolsVisible,
                calibrationToolsMounted: $calibrationToolsMounted,
                diagnosticsPanelEnabled: $diagnosticsPanelEnabled,
                showingTestOCRPanel: $showingTestOCRPanel,
                onOpenTemplateSettings: onOpenTemplateSettings,
                onDismissForZoneEditing: onDismissForZoneEditing
            )
        }
    }
}

private struct CalibrationDiagnosticsWorkflowPanel: View {
    let viewModel: HockeyScoreboardViewModel
    let refreshID: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CalibrationHubSectionHeader(
                title: "Diagnostics",
                systemImage: "waveform.path.ecg.rectangle",
                help: "Breadcrumbs, gesture traces, camera health and recognition details for troubleshooting."
            )
            CalibrationCameraDiagnosticsSubmenu(viewModel: viewModel, refreshID: refreshID)
            DiagnosticsHubView(viewModel: viewModel, cameraService: viewModel.ocrCameraService)
        }
    }
}

private struct CalibrationCameraSourceSubmenu: View {
    let viewModel: HockeyScoreboardViewModel
    let refreshID: Int
    let onRefresh: (String) -> Void

    private var service: HockeyCameraService { viewModel.ocrCameraService }
    private var isEditable: Bool { !service.isReconfiguring }

    var body: some View {
        let _ = refreshID
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                BroadcastMenuSectionTitle("Camera Source", systemImage: "camera.badge.ellipsis")

                Picker("Calibration camera source", selection: sourceBinding) {
                    Text("Select camera source").tag(iceCastNoCameraSelectionID)
                    ForEach(sourceOptions) { option in
                        Text(option.title).tag(option.cameraID)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!isEditable)

                Text("Camera Source is the only place to change the Scoreboard Setup camera. External Camera appears here only; diagnostics is read-only.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)

                if service.availableCameras.isEmpty {
                    Text("No cameras found. Camera discovery runs automatically; check camera permission or reconnect the USB-C camera, then use Rescan Cameras if needed.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if !viewModel.hasExternalOCRCameraForCalibration {
                    Text("No external camera detected")
                        .font(RinkLensDesignSystem.font(.caption))
                        .foregroundStyle(.orange)
                }

                if let warning = viewModel.calibrationCameraWarningText {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(RinkLensDesignSystem.font(.caption))
                        .foregroundStyle(.orange)
                }

                CalibrationInfoRow(label: "Selected camera", value: service.selectedCameraLabel)
                CalibrationInfoRow(label: "Connection", value: service.cameraStatusText)
                CalibrationInfoRow(label: "External camera", value: viewModel.calibrationExternalCameraStatusText)

                CalibrationActionGrid {
                    CalibrationHubActionButton(title: "Rescan Cameras", systemImage: "arrow.clockwise", prominent: true) {
                        viewModel.refreshCameraLists()
                        onRefresh("calibration cameras refreshed")
                    }
                    .disabled(service.isReconfiguring)

                    CalibrationHubActionButton(title: "Recover Preview", systemImage: "arrow.clockwise.circle.fill") {
                        viewModel.requestCameraPreviewRecovery(for: service, reason: "calibration camera source recover preview")
                        onRefresh("calibration preview recovered")
                    }
                    .disabled(service.isReconfiguring)
                }
            }
            .calibrationHubCard()

            CalibrationMenuCameraOrientationCard(viewModel: viewModel)
        }
    }

    private struct SourceOption: Identifiable {
        let id: CalibrationCameraSourceKind
        let cameraID: String
        let title: String
    }

    private var sourceOptions: [SourceOption] {
        let orderedKinds: [CalibrationCameraSourceKind] = [.builtInBack, .builtInFront, .external]
        let selected = service.availableCameras.first(where: { $0.id == service.selectedCameraID })
        return orderedKinds.compactMap { kind in
            let camera = selected.flatMap { viewModel.calibrationSourceKind(for: $0) == kind ? $0 : nil }
                ?? service.availableCameras.first(where: { viewModel.calibrationSourceKind(for: $0) == kind })
            guard let camera else { return nil }
            return SourceOption(id: kind, cameraID: camera.id, title: camera.name)
        }
    }

    private var sourceBinding: Binding<String> {
        Binding(
            get: { service.selectedCameraID ?? iceCastNoCameraSelectionID },
            set: { newValue in
                guard newValue != iceCastNoCameraSelectionID else { return }
                viewModel.selectCalibrationCameraSource(id: newValue)
                onRefresh("calibration camera source selected")
            }
        )
    }
}

private struct CalibrationCameraManualSettingsSubmenu: View {
    @ObservedObject var viewModel: HockeyScoreboardViewModel

    private var service: HockeyCameraService { viewModel.ocrCameraService }
    private var isEditable: Bool { viewModel.isCalibrationManualCameraEditable && !service.isReconfiguring }
    private var supportedCapabilityProfiles: [HockeyCameraService.CapabilityProfileOption] {
        service.capabilityProfiles.filter(\.isAvailable)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                BroadcastMenuSectionTitle("Manual", systemImage: "dial.medium")

                Text("Manual is the single saved Scoreboard Setup camera profile. Use Copy Broadcast once to start from Broadcast settings; setup no longer live-follows Broadcast while Image Relay is running.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)

                CalibrationActionGrid {
                    CalibrationHubActionButton(title: "Copy Broadcast Settings", systemImage: "square.on.square", prominent: true) {
                        viewModel.copyBroadcastSettingsToCalibration(reason: "operator copied broadcast settings")
                    }
                    .disabled(service.isReconfiguring)

                    CalibrationHubActionButton(title: "Apply Locks", systemImage: "lock.fill") {
                        viewModel.applyCalibrationManualLocks(reason: "operator applied manual locks")
                    }
                    .disabled(service.isReconfiguring)
                }

                zoomSection
                Divider().overlay(Color.white.opacity(0.16))
                focusSection
                Divider().overlay(Color.white.opacity(0.16))
                exposureSection
                Divider().overlay(Color.white.opacity(0.16))
                whiteBalanceSection
                Divider().overlay(Color.white.opacity(0.16))
                resolutionFrameRateSection
                advancedManualValuesSection
            }
            .calibrationHubCard()
        }
    }

    private var zoomSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            CalibrationCameraLockToggleRow(
                title: "Zoom",
                value: String(format: "%.1fx", Double(viewModel.cameraZoomFactor)),
                isLocked: viewModel.calibrationCameraProfile.zoomLocked,
                isEnabled: viewModel.isCalibrationManualCameraEditable,
                onToggle: { viewModel.setCalibrationZoomLock($0) }
            )

            if calibrationZoomRangeIsUsable {
                Slider(
                    value: Binding(
                        get: { calibrationClampedZoomValue },
                        set: { viewModel.setOCRCameraZoom(CGFloat($0)) }
                    ),
                    in: calibrationSafeZoomRange
                )
                .disabled(!isEditable)
            } else {
                Text("Zoom is fixed/unavailable for the current camera feed.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }


    private var calibrationSafeZoomRange: ClosedRange<Double> {
        let lower = service.minZoomFactor.isFinite ? Swift.max(0.1, Double(service.minZoomFactor)) : 1.0
        let rawUpper = service.maxZoomFactor.isFinite ? Double(service.maxZoomFactor) : lower
        let upper = Swift.max(lower, rawUpper)
        return lower...upper
    }

    private var calibrationZoomRangeIsUsable: Bool {
        calibrationSafeZoomRange.upperBound > calibrationSafeZoomRange.lowerBound + 0.01
    }

    private var calibrationClampedZoomValue: Double {
        Swift.min(
            Swift.max(Double(viewModel.cameraZoomFactor.isFinite ? viewModel.cameraZoomFactor : CGFloat(calibrationSafeZoomRange.lowerBound)), calibrationSafeZoomRange.lowerBound),
            calibrationSafeZoomRange.upperBound
        )
    }

    private var focusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            CalibrationCameraLockToggleRow(
                title: "Focus",
                value: service.focusModeText,
                isLocked: viewModel.calibrationCameraProfile.focusLocked,
                isEnabled: viewModel.isCalibrationManualCameraEditable && service.supportsManualFocus,
                onToggle: { viewModel.setCalibrationFocusLock($0) }
            )

            if service.supportsManualFocus {
                Slider(
                    value: Binding(
                        get: { Double(service.focusPosition) },
                        set: { viewModel.setCalibrationManualFocus(Float($0)) }
                    ),
                    in: 0...1
                )
                .disabled(!isEditable)
                Text("Manual focus position: \(String(format: "%.2f", Double(service.focusPosition)))")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.66))
            } else {
                Text("Manual focus unavailable on the selected camera.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
    }

    private var exposureSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            CalibrationCameraLockToggleRow(
                title: "Exposure",
                value: service.exposureModeText,
                isLocked: viewModel.calibrationCameraProfile.exposureLocked,
                isEnabled: viewModel.isCalibrationManualCameraEditable && service.supportsExposureLockOrCustom,
                onToggle: { viewModel.setCalibrationExposureLock($0) }
            )

            HStack(spacing: 8) {
                Button {
                    viewModel.setCalibrationExposureAuto()
                } label: {
                    Label("Auto", systemImage: "camera.aperture")
                        .font(RinkLensDesignSystem.font(.caption))
                }
                .buttonStyle(CalibrationHubButtonStyle(prominent: !viewModel.calibrationCameraProfile.exposureLocked, destructive: false))
                .disabled(!isEditable || !service.supportsAutoExposure)

                Button {
                    viewModel.setCalibrationExposureLock(true)
                } label: {
                    Label("Lock Current", systemImage: "lock.fill")
                        .font(RinkLensDesignSystem.font(.caption))
                }
                .buttonStyle(CalibrationHubButtonStyle(prominent: viewModel.calibrationCameraProfile.exposureLocked, destructive: false))
                .disabled(!isEditable || !service.supportsExposureLockOrCustom)
            }

            if service.supportsExposureBias {
                Text("Exposure bias: \(String(format: "%.1f", Double(service.exposureTargetBiasValue)))")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.66))
                Slider(
                    value: Binding(
                        get: { Double(service.exposureTargetBiasValue) },
                        set: { viewModel.setCalibrationExposureBias(Float($0)) }
                    ),
                    in: Double(service.minExposureTargetBias)...Double(service.maxExposureTargetBias)
                )
                .disabled(!isEditable)
            } else {
                Text("Exposure bias unavailable on the selected camera.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
            }

            if service.supportsManualISO || service.supportsManualExposureDuration {
                Text("ISO and shutter controls switch the selected camera into manual exposure where the camera supports custom exposure.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.56))
            } else {
                Text("Manual exposure values are unavailable on the selected camera. Use Auto or Lock Current Exposure.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
    }

    private var whiteBalanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            CalibrationCameraLockToggleRow(
                title: "White balance",
                value: service.whiteBalanceModeText,
                isLocked: viewModel.calibrationCameraProfile.whiteBalanceLocked,
                isEnabled: viewModel.isCalibrationManualCameraEditable && service.supportsWhiteBalanceLock,
                onToggle: { viewModel.setCalibrationWhiteBalanceLock($0) }
            )

            if service.supportsManualWhiteBalanceGains {
                Text("Temperature: \(Int(service.whiteBalanceTemperature))K")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.66))
                Slider(
                    value: Binding(
                        get: { Double(service.whiteBalanceTemperature) },
                        set: { viewModel.setCalibrationManualWhiteBalance(temperature: Float($0), tint: service.whiteBalanceTint) }
                    ),
                    in: 2_500...8_000
                )
                .disabled(!isEditable)

                Text("Tint: \(String(format: "%.0f", Double(service.whiteBalanceTint)))")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.66))
                Slider(
                    value: Binding(
                        get: { Double(service.whiteBalanceTint) },
                        set: { viewModel.setCalibrationManualWhiteBalance(temperature: service.whiteBalanceTemperature, tint: Float($0)) }
                    ),
                    in: -50...50
                )
                .disabled(!isEditable)
            } else {
                Text("White balance lock unavailable on the selected camera.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
    }

    private var resolutionFrameRateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Resolution / frame rate")
                    .font(RinkLensDesignSystem.font(.bodyStrong))
                Spacer()
                Text(service.selectedResolutionLabel)
                    .font(RinkLensDesignSystem.font(.caption))
                    .foregroundStyle(.white.opacity(0.70))
            }

            if supportedCapabilityProfiles.isEmpty {
                Text("Supported formats are loading automatically. If this remains empty, the selected camera does not advertise a 720p, 1080p, or 1440p MultiCam mode at 30/60 fps.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
            } else {
                Picker("Resolution / FPS", selection: Binding(
                    get: { service.selectedCapabilityProfileID ?? supportedCapabilityProfiles.first?.id ?? "" },
                    set: { viewModel.selectCalibrationCapabilityProfile(id: $0) }
                )) {
                    ForEach(supportedCapabilityProfiles) { profile in
                        Text(profile.displayLabel).tag(profile.id)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!isEditable)

                Text("Only camera-supported 720p, 1080p, and 1440p modes at 30 or 60 fps are shown.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.56))
            }
        }
    }

    private var advancedManualValuesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if service.supportsManualISO {
                CalibrationCameraLockToggleRow(
                    title: "ISO / gain",
                    value: "\(Int(service.isoValue))",
                    isLocked: viewModel.calibrationCameraProfile.isoLocked,
                    isEnabled: viewModel.isCalibrationManualCameraEditable,
                    onToggle: { viewModel.setCalibrationISOLock($0) }
                )
                Slider(
                    value: Binding(
                        get: { Double(service.isoValue) },
                        set: { viewModel.setCalibrationManualISO(Float($0)) }
                    ),
                    in: Double(service.minISO)...Double(service.maxISO)
                )
                .disabled(!isEditable)
            } else {
                Text("Manual ISO unavailable on the selected camera.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
            }

            if service.supportsManualExposureDuration {
                CalibrationCameraLockToggleRow(
                    title: "Shutter speed",
                    value: service.shutterSpeedText,
                    isLocked: viewModel.calibrationCameraProfile.shutterSpeedLocked,
                    isEnabled: viewModel.isCalibrationManualCameraEditable,
                    onToggle: { viewModel.setCalibrationShutterLock($0) }
                )
                Slider(
                    value: Binding(
                        get: { service.exposureDurationSeconds },
                        set: { viewModel.setCalibrationManualShutter(seconds: $0) }
                    ),
                    in: shutterRange
                )
                .disabled(!isEditable)
            } else {
                Text("Manual shutter speed unavailable on the selected camera.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
    }

    private var shutterRange: ClosedRange<Double> {
        let minValue = service.minExposureDurationSeconds.isFinite && service.minExposureDurationSeconds > 0 ? service.minExposureDurationSeconds : 1.0 / 10_000.0
        let maxValue = service.maxExposureDurationSeconds.isFinite && service.maxExposureDurationSeconds > minValue ? service.maxExposureDurationSeconds : 1.0 / 2.0
        return minValue...maxValue
    }
}

private struct CalibrationCameraDiagnosticsSubmenu: View {
    let viewModel: HockeyScoreboardViewModel
    let refreshID: Int

    private var service: HockeyCameraService { viewModel.ocrCameraService }

    var body: some View {
        let _ = refreshID
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                BroadcastMenuSectionTitle("Camera Diagnostics", systemImage: "waveform.path.ecg.rectangle")
                CalibrationInfoRow(label: "Selected camera", value: service.selectedCameraLabel)
                CalibrationInfoRow(label: "Connection status", value: service.cameraStatusText)
                CalibrationInfoRow(label: "External camera", value: viewModel.hasExternalOCRCameraForCalibration ? "Detected" : "Not detected")
                CalibrationInfoRow(label: "Active resolution", value: service.selectedResolutionFPS)
                CalibrationInfoRow(label: "Active frame rate", value: viewModel.calibrationCameraProfile.exactCaptureCadence.map { "\($0.displayText)fps" } ?? service.selectedResolutionFPS)
                CalibrationInfoRow(label: "Current zoom", value: String(format: "%.1fx", Double(viewModel.cameraZoomFactor)))
                CalibrationInfoRow(label: "Focus state", value: service.focusModeText)
                CalibrationInfoRow(label: "Exposure state", value: service.exposureModeText)
                CalibrationInfoRow(label: "Exposure bias", value: service.supportsExposureBias ? String(format: "%.1f", Double(service.exposureTargetBiasValue)) : "Unavailable")
                CalibrationInfoRow(label: "White balance state", value: service.whiteBalanceModeText)
                CalibrationInfoRow(label: "White balance temp/tint", value: service.supportsManualWhiteBalanceGains ? "\(Int(service.whiteBalanceTemperature))K / \(Int(service.whiteBalanceTint))" : "Unavailable")
                CalibrationInfoRow(label: "Lock summary", value: viewModel.calibrationCameraLockSummaryText)
                CalibrationInfoRow(label: "Preview status", value: service.hasReceivedFrames ? "Receiving frames" : "Waiting for frames")
                CalibrationInfoRow(label: "Camera profile", value: "Manual calibration profile")
                CalibrationInfoRow(label: "Preview rotation", value: "\(Int(viewModel.ocrPreviewRotationOffsetDegrees))°")
                CalibrationInfoRow(label: "Active format", value: service.activeCameraFormatDetailsText)
                CalibrationInfoRow(label: "Device / lens", value: service.activeCameraDeviceDetailsText)
                CalibrationInfoRow(label: "Stabilisation", value: service.stabilisationStatusText)
                CalibrationInfoRow(label: "Manual focus", value: service.supportsManualFocus ? "Supported" : "Unavailable")
                CalibrationInfoRow(label: "Exposure lock", value: service.supportsExposureLockOrCustom ? "Supported" : "Unavailable")
                CalibrationInfoRow(label: "Auto exposure", value: service.supportsAutoExposure ? "Supported" : "Unavailable")
                CalibrationInfoRow(label: "Manual ISO", value: service.supportsManualISO ? "Supported · \(Int(service.minISO))-\(Int(service.maxISO))" : "Unavailable")
                CalibrationInfoRow(label: "Manual shutter", value: service.supportsManualExposureDuration ? "Supported · \(service.shutterSpeedText)" : "Unavailable")
                CalibrationInfoRow(label: "Manual white balance", value: service.supportsManualWhiteBalanceGains ? "Supported · \(Int(service.whiteBalanceTemperature))K / \(Int(service.whiteBalanceTint))" : "Unavailable")
                CalibrationInfoRow(label: "Preview layer", value: service.lastPreviewLayerEventText)
            }
            .calibrationHubCard()
        }
    }
}

private struct CalibrationCameraLockToggleRow: View {
    let title: String
    let value: String
    let isLocked: Bool
    let isEnabled: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(RinkLensDesignSystem.font(.bodyStrong))
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.66))
            }
            Spacer()
            Button {
                onToggle(!isLocked)
            } label: {
                Label(isLocked ? "Locked" : "Unlocked", systemImage: isLocked ? "lock.fill" : "lock.open")
                    .font(RinkLensDesignSystem.font(.caption))
            }
            .buttonStyle(CalibrationHubButtonStyle(prominent: isLocked, destructive: false))
            .disabled(!isEnabled)
        }
    }
}

private struct CalibrationTemplatesQuickPanel: View {
    @ObservedObject var viewModel: HockeyScoreboardViewModel
    let onOpenTemplateSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CalibrationHubSectionHeader(
                title: "Zone templates",
                systemImage: "doc.on.doc",
                help: "Load, save or manage per-rink scoreboard zone layouts. Loading a profile is the only action that should reload zone coordinates."
            )

            VStack(alignment: .leading, spacing: 10) {
                Button {
                    MainThreadStallMonitor.shared.markContext("zone template manager opened")
                    onOpenTemplateSettings()
                } label: {
                    Label("Open Zone Template Manager", systemImage: "folder")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                }
                .buttonStyle(CalibrationHubButtonStyle(prominent: true, destructive: false))

                Text("Active zone template: \(viewModel.activeTemplateName ?? "None")")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.68))

                if viewModel.hasUnsavedTemplateChanges {
                    Text("Unsaved calibration changes")
                        .font(RinkLensDesignSystem.font(.caption))
                        .foregroundStyle(.orange)
                }
            }
            .calibrationHubCard()
        }
    }
}

private struct CalibrationZonesPanel: View {
    @ObservedObject var viewModel: HockeyScoreboardViewModel
    @Binding var calibrationToolsVisible: Bool
    @Binding var calibrationToolsMounted: Bool
    @Binding var diagnosticsPanelEnabled: Bool
    @Binding var showingTestOCRPanel: Bool
    let onOpenTemplateSettings: () -> Void
    let onDismissForZoneEditing: () -> Void

    @State private var confirmResetAllZones = false
    @State private var templateNameInput = ""
    @State private var renameTemplate: RinkTemplate?
    @State private var renameInput = ""
    @State private var duplicateTemplate: RinkTemplate?
    @State private var duplicateInput = ""
    @State private var deleteTemplate: RinkTemplate?

    private var activeTemplate: RinkTemplate? {
        guard let activeID = viewModel.activeTemplateID else { return nil }
        return viewModel.templateStore.templates.first(where: { $0.id == activeID })
    }

    private var defaultTemplate: RinkTemplate? {
        guard let defaultID = viewModel.templateStore.defaultTemplateID else { return nil }
        return viewModel.templateStore.templates.first(where: { $0.id == defaultID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            BroadcastMenuHeaderLabel(
                title: "Zone Templates",
                subtitle: "Save, load and manage scoreboard zone layouts using the same profile pattern as Broadcast scoreboard profiles.",
                systemImage: "rectangle.3.group.fill"
            )

            zoneProfilesCard
            zoneLayoutCard
        }
        .onAppear(perform: syncTemplateNameField)
        .alert("Rename Zone Template", isPresented: renamePresented) {
            TextField("Template name", text: $renameInput)
            Button("Cancel", role: .cancel) { renameTemplate = nil }
            Button("Rename") { renameSelectedTemplate() }
        } message: {
            Text("Rename this saved scoreboard zone layout without changing its zone positions.")
        }
        .alert("Duplicate Zone Template", isPresented: duplicatePresented) {
            TextField("New template name", text: $duplicateInput)
            Button("Cancel", role: .cancel) { duplicateTemplate = nil }
            Button("Duplicate") { duplicateSelectedTemplate() }
        } message: {
            Text("Create a copy of this scoreboard zone layout.")
        }
        .confirmationDialog(
            "Delete Zone Template?",
            isPresented: deletePresented,
            titleVisibility: .visible
        ) {
            if let deleteTemplate {
                Button("Delete \(deleteTemplate.name)", role: .destructive) {
                    deleteSelectedTemplate()
                }
            }
            Button("Cancel", role: .cancel) { deleteTemplate = nil }
        } message: {
            Text("This removes the saved zone template. The current editable zones are not reset unless you load another template.")
        }
        .confirmationDialog(
            "Reset all OCR zones to the default layout?",
            isPresented: $confirmResetAllZones,
            titleVisibility: .visible
        ) {
            Button("Reset All Zones", role: .destructive) { resetAllZones() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var zoneProfilesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Zone layout profiles", systemImage: "rectangle.3.group.fill")
                    .font(RinkLensDesignSystem.font(.caption))
                    .foregroundStyle(.white)
                Spacer()
                activeZoneProfileBadge
            }

            if viewModel.templateStore.templates.isEmpty {
                Text("No saved zone layout profiles yet. Position and resize the scoreboard zones, then save a profile.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.70))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(viewModel.templateStore.templates) { template in
                            zoneProfileButton(template)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            HStack(spacing: 8) {
                TextField("Profile name", text: $templateNameInput)
                    .textInputAutocapitalization(.words)
                    .textFieldStyle(BroadcastMenuTextFieldStyle())

                Button {
                    saveZoneProfile()
                } label: {
                    Label(activeTemplate == nil ? "Save profile" : "Update profile", systemImage: "square.and.arrow.down")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .disabled(cleanTemplateName().isEmpty)
            }

            Button {
                saveAsNewZoneProfile()
            } label: {
                Label("Save as new zone profile", systemImage: "plus.square.on.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(cleanTemplateName().isEmpty)

            if viewModel.hasUnsavedTemplateChanges {
                Label("Unsaved zone changes", systemImage: "exclamationmark.triangle.fill")
                    .font(RinkLensDesignSystem.font(.caption))
                    .foregroundStyle(.orange)
            }

            Text("Tap a profile to load zone positions. Long-press, or tap the menu, for Load, Set Default, Rename, Duplicate and Delete.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.62))
        }
        .padding(12)
        .broadcastMenuCard(cornerRadius: 14)
    }

    private var activeZoneProfileBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(activeTemplate == nil ? Color.white.opacity(0.28) : Color.green.opacity(0.85))
                .frame(width: 8, height: 8)
            Text(activeTemplate?.name ?? "No active profile")
                .font(RinkLensDesignSystem.font(.micro))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.10), in: Capsule(style: .continuous))
    }

    private func zoneProfileButton(_ template: RinkTemplate) -> some View {
        ZoneProfileTile(
            template: template,
            isActive: viewModel.activeTemplateID == template.id,
            isDefault: viewModel.templateStore.defaultTemplateID == template.id,
            zoneCount: OCRRegionKey.calibrationCases.count,
            onLoad: { loadTemplateForZoneEditing(template) },
            onSetDefault: { viewModel.setDefaultTemplate(template) },
            onUpdateFromCurrent: {
                loadTemplateForZoneEditing(template)
                viewModel.saveActiveTemplate(venueName: "", notes: "", imageData: nil)
            },
            onRename: {
                renameTemplate = template
                renameInput = template.name
            },
            onDuplicate: {
                duplicateTemplate = template
                duplicateInput = "\(template.name) Copy"
            },
            onDelete: { deleteTemplate = template }
        )
    }

    private var zoneLayoutCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            BroadcastMenuSectionTitle("Zone Layout", systemImage: "rectangle.dashed")

            CalibrationActionGrid {
                CalibrationHubActionButton(
                    title: calibrationToolsVisible ? "Hide Zones" : "Show Zones",
                    systemImage: calibrationToolsVisible ? "eye.slash" : "square.dashed",
                    prominent: true
                ) { toggleZoneEditor() }

                CalibrationHubActionButton(title: "Reset Selected", systemImage: "arrow.uturn.backward") {
                    resetSelectedZone()
                }

                CalibrationHubActionButton(title: "Reset All", systemImage: "trash", destructive: true, role: .destructive) {
                    confirmResetAllZones = true
                }

                CalibrationHubActionButton(
                    title: "Save Zones to Default",
                    systemImage: "square.and.arrow.down",
                    prominent: true
                ) {
                    viewModel.saveCurrentZonesToDefaultTemplate()
                    syncTemplateNameField()
                }
                .disabled(defaultTemplate == nil)
            }

            if let defaultTemplate {
                Text("Current default profile: \(defaultTemplate.name). Save Zones to Default updates its zone geometry without changing its camera, colour or team settings.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.62))
            } else {
                Text("No default profile is set. Set one from the profile menu before saving zones.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Text("The shared selector above chooses which box is active. Drag or resize it directly on the live preview. Template loading only happens when you tap a saved profile or choose Load from its menu.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.66))
        }
        .padding(12)
        .broadcastMenuCard(cornerRadius: 14)
    }

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renameTemplate != nil },
            set: { if !$0 { renameTemplate = nil } }
        )
    }

    private var duplicatePresented: Binding<Bool> {
        Binding(
            get: { duplicateTemplate != nil },
            set: { if !$0 { duplicateTemplate = nil } }
        )
    }

    private var deletePresented: Binding<Bool> {
        Binding(
            get: { deleteTemplate != nil },
            set: { if !$0 { deleteTemplate = nil } }
        )
    }

    private func syncTemplateNameField() {
        templateNameInput = activeTemplate?.name ?? defaultNewTemplateName
    }

    private func toggleZoneEditor() {
        if calibrationToolsVisible {
            calibrationToolsVisible = false
            diagnosticsPanelEnabled = true
            viewModel.setOCRDiagnosticsVisible(true)
            MainThreadStallMonitor.shared.markContext("zone editor hidden")
            MainThreadStallMonitor.shared.markContext("overlay hit testing disabled")
            MainThreadStallMonitor.shared.markContext("UX14a calibration hub: zones hidden; OCR diagnostics remain visible")
        } else {
            MainThreadStallMonitor.shared.markContext("sheet dismissed before zone edit")
            MainThreadStallMonitor.shared.markContext("calibration hub: dismissing before zone editor activation")
            onDismissForZoneEditing()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                calibrationToolsMounted = true
                calibrationToolsVisible = true
                MainThreadStallMonitor.shared.markContext("zone editor shown")
                MainThreadStallMonitor.shared.markContext("overlay hit testing enabled")
                MainThreadStallMonitor.shared.markContext("calibration hub: zone editor active - OCR kept running")
                viewModel.updateFrameDeliveryPolicy(force: true)
            }
        }
        MainThreadStallMonitor.shared.notePublish(source: "calibration hub zone toggle")
    }

    private func saveZoneProfile() {
        let trimmedName = cleanTemplateName()
        if let activeTemplate {
            if trimmedName != activeTemplate.name {
                viewModel.renameTemplate(activeTemplate, newName: trimmedName)
            }
            viewModel.saveActiveTemplate(venueName: "", notes: "", imageData: nil)
            MainThreadStallMonitor.shared.markContext("zone profile updated: active layout")
        } else {
            viewModel.saveAsNewTemplate(name: trimmedName, venueName: "", notes: "", imageData: nil)
            MainThreadStallMonitor.shared.markContext("zone profile saved: first layout")
        }
        syncTemplateNameField()
        MainThreadStallMonitor.shared.notePublish(source: "broadcast-style zone profile save")
    }

    private func saveAsNewZoneProfile() {
        let name = uniqueTemplateName(from: cleanTemplateName())
        viewModel.saveAsNewTemplate(name: name, venueName: "", notes: "", imageData: nil)
        templateNameInput = name
        MainThreadStallMonitor.shared.markContext("zone profile saved as new: \(name)")
        MainThreadStallMonitor.shared.notePublish(source: "broadcast-style zone profile save as new")
    }

    private func renameSelectedTemplate() {
        guard let renameTemplate else { return }
        let trimmed = renameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        viewModel.renameTemplate(renameTemplate, newName: trimmed)
        templateNameInput = trimmed
        self.renameTemplate = nil
        MainThreadStallMonitor.shared.markContext("zone profile renamed: \(trimmed)")
    }

    private func duplicateSelectedTemplate() {
        guard let duplicateTemplate else { return }
        let trimmed = duplicateInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = uniqueTemplateName(from: trimmed.isEmpty ? "\(duplicateTemplate.name) Copy" : trimmed)
        viewModel.duplicateTemplate(duplicateTemplate, newName: name)
        self.duplicateTemplate = nil
        MainThreadStallMonitor.shared.markContext("zone profile duplicated: \(name)")
    }

    private func deleteSelectedTemplate() {
        guard let deleteTemplate else { return }
        viewModel.deleteTemplate(deleteTemplate)
        if activeTemplate?.id == deleteTemplate.id {
            templateNameInput = defaultNewTemplateName
        }
        self.deleteTemplate = nil
        MainThreadStallMonitor.shared.markContext("zone profile deleted")
    }

    private func loadTemplateForZoneEditing(_ template: RinkTemplate) {
        let existingCalibrationRotation = viewModel.calibrationRotationDegrees
        let existingOCRPreviewRotation = viewModel.ocrPreviewRotationOffsetDegrees
        let existingLivePreviewRotation = viewModel.livePreviewRotationOffsetDegrees

        viewModel.applyTemplate(template)

        viewModel.calibrationRotationDegrees = existingCalibrationRotation
        viewModel.ocrPreviewRotationOffsetDegrees = existingOCRPreviewRotation
        viewModel.livePreviewRotationOffsetDegrees = existingLivePreviewRotation
        templateNameInput = template.name
        MainThreadStallMonitor.shared.markContext("zone profile loaded: \(template.name)")
        MainThreadStallMonitor.shared.notePublish(source: "zone profile explicit load")
    }

    private func resetSelectedZone() {
        let key = viewModel.selectedRegionKey
        let previous = viewModel.ocrLayout
        var updated = previous
        updated[key] = ScoreboardOCRLayout()[key]
        viewModel.ocrLayout = updated
        viewModel.recordZoneLayoutAudit(
            before: previous,
            after: updated,
            operation: "reset-selected",
            detail: "Reset selected OCR zone \(key.rawValue)"
        )
        viewModel.hasUnsavedTemplateChanges = true
        MainThreadStallMonitor.shared.markContext("zone reset selected: \(key.rawValue)")
        MainThreadStallMonitor.shared.notePublish(source: "zone reset selected")
    }

    private func resetAllZones() {
        let previous = viewModel.ocrLayout
        let defaults = ScoreboardOCRLayout()
        viewModel.ocrLayout = defaults
        viewModel.recordZoneLayoutAudit(
            before: previous,
            after: defaults,
            operation: "reset-all",
            detail: "Reset all OCR zones to defaults"
        )
        viewModel.hasUnsavedTemplateChanges = true
        MainThreadStallMonitor.shared.markContext("zone reset all")
        MainThreadStallMonitor.shared.notePublish(source: "zone reset all")
    }

    private func cleanTemplateName() -> String {
        let trimmed = templateNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultNewTemplateName : trimmed
    }

    private func uniqueTemplateName(from base: String) -> String {
        let cleaned = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = cleaned.isEmpty ? defaultNewTemplateName : cleaned
        let existing = Set(viewModel.templateStore.templates.map { $0.name.lowercased() })
        if !existing.contains(candidate.lowercased()) { return candidate }
        var index = 2
        while existing.contains("\(candidate) \(index)".lowercased()) {
            index += 1
        }
        return "\(candidate) \(index)"
    }

    private var defaultNewTemplateName: String {
        "Zone Layout \(viewModel.templateStore.templates.count + 1)"
    }
}

private struct ZoneProfileTile: View {
    let template: RinkTemplate
    let isActive: Bool
    let isDefault: Bool
    let zoneCount: Int
    let onLoad: () -> Void
    let onSetDefault: () -> Void
    let onUpdateFromCurrent: () -> Void
    let onRename: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        tileContent
            .contentShape(Rectangle())
            .onTapGesture(perform: onLoad)
    }

    private var tileContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow
            zoneCountLabel
            cameraLabel
            badgeRow
        }
        .padding(10)
        .frame(width: 218, alignment: .leading)
        .background(tileBackground)
        .overlay(tileBorder)
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Text(template.name)
                .font(RinkLensDesignSystem.font(.caption))
                .lineLimit(1)

            Spacer(minLength: 4)

            RinkLensStableActionMenu(
                title: "Zone Profile",
                width: 370,
                actions: profileMenuActions
            ) {
                Image(systemName: "ellipsis.circle")
                    .font(RinkLensDesignSystem.font(.caption))
                    .foregroundStyle(.white.opacity(0.86))
                    .frame(width: 30, height: 30)
            }
        }
    }

    private var zoneCountLabel: some View {
        Text("\(zoneCount) scoreboard zones")
            .font(.caption2)
            .lineLimit(1)
            .foregroundStyle(.white.opacity(0.72))
    }

    private var cameraLabel: some View {
        Text("Layout + camera")
            .font(RinkLensDesignSystem.font(.micro))
            .foregroundStyle(Color.cyan.opacity(0.85))
    }

    private var badgeRow: some View {
        HStack(spacing: 6) {
            if isActive { profileBadge("ACTIVE", color: .green) }
            if isDefault { profileBadge("DEFAULT", color: .yellow) }
        }
        .frame(minHeight: 14, alignment: .leading)
    }

    private func profileBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(RinkLensDesignSystem.font(.micro))
            .foregroundStyle(color)
    }

    private var tileBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(isActive ? 0.16 : 0.08))
    }

    private var tileBorder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(isActive ? Color.green.opacity(0.8) : Color.white.opacity(0.14), lineWidth: 1)
    }

    private var profileMenuActions: [RinkLensStableMenuAction] {
        [
            .init(title: "Load zone layout", systemImage: "arrow.down.doc", action: onLoad),
            .init(title: "Set Default", systemImage: "star.fill", isSelected: isDefault, action: onSetDefault),
            .init(title: "Update From Current Zones", systemImage: "square.and.arrow.down", action: onUpdateFromCurrent),
            .init(title: "Rename", systemImage: "pencil", action: onRename),
            .init(title: "Duplicate", systemImage: "plus.square.on.square", action: onDuplicate),
            .init(title: "Delete", systemImage: "trash", isDestructive: true, action: onDelete)
        ]
    }
}

private struct CalibrationOCRPanel: View {
    @ObservedObject var viewModel: HockeyScoreboardViewModel
    @ObservedObject private var imageRelayPresentation = ScoreboardImageRelayPresentation.shared
    let refreshID: Int
    let onRefresh: (String) -> Void
    @Binding var showingTestOCRPanel: Bool
    @Binding var diagnosticsPanelEnabled: Bool
    let onRunTestOCR: (String) -> Void
    let onOpenTemplateSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CalibrationHubSectionHeader(
                title: "Scoreboard input",
                systemImage: viewModel.operatingMode == .imageRelay ? "photo.on.rectangle" : "text.viewfinder",
                help: "Choose Image Relay or Manual control. Period recognition runs internally with Image Relay and has no separate mode or switch."
            )

            ocrRunCard
            modeSpecificControls
        }
    }

    @ViewBuilder
    private var modeSpecificControls: some View {
        switch viewModel.operatingMode {
        case .ocr, .imageRelay:
            imageRelayRulesCard
            imageRelayPreviewCard
            imageRelayStatusCard

        case .manual:
            manualModeCard
        }
    }

    private var ocrRunCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Scoreboard input mode")
                    .font(RinkLensDesignSystem.font(.caption))
                    .foregroundStyle(.white.opacity(0.72))

                Picker(
                    "Scoreboard input mode",
                    selection: Binding(
                        get: { viewModel.operatingMode },
                        set: { newMode in
                            guard viewModel.operatingMode != newMode else { return }
                            if newMode == .manual {
                                viewModel.setOperatingMode(newMode)
                            } else {
                                viewModel.setOperatingMode(newMode, autoStart: false)
                            }
                            onRefresh("calibration scoreboard mode changed to \(newMode.rawValue); manual start required")
                        }
                    )
                ) {
                    Text("Image Relay").tag(OperatingMode.imageRelay)
                    Text("Manual").tag(OperatingMode.manual)
                }
                .pickerStyle(.segmented)
                .tint(.cyan)
                .accessibilityHint("Choose direct scoreboard Image Relay or manual scoreboard control")
            }

            Text(modeExplanation)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.operatingMode != .manual {
                CalibrationActionGrid {
                    CalibrationHubActionButton(
                        title: runButtonTitle,
                        systemImage: viewModel.scoreboardInputControlSystemImage,
                        prominent: true
                    ) {
                        toggleOCR()
                    }

                    CalibrationHubActionButton(title: resetButtonTitle, systemImage: "arrow.counterclockwise") {
                        viewModel.resetOCRFromCalibration()
                        onRefresh("calibration automatic scoreboard input reset")
                    }

                }
            }

            Text(runStatusText)
                .font(.caption)
                .foregroundStyle(runStatusColour)
        }
        .calibrationHubCard()
    }

    private var modeExplanation: String {
        switch viewModel.operatingMode {
        case .ocr, .imageRelay:
            return "Image Relay owns the live scorebug. Period recognition and frozen Home penalty-player recognition run internally; they cannot replace live relay images or create automatic goals."
        case .manual:
            return "Manual mode owns goals, period corrections and deliberate score changes."
        }
    }

    private var runButtonTitle: String {
        viewModel.operatingMode == .manual ? "Manual Mode" : viewModel.scoreboardInputControlTitle
    }

    private var resetButtonTitle: String {
        "Reset Relay"
    }

    private var runStatusText: String {
        switch viewModel.operatingMode {
        case .ocr, .imageRelay:
            if viewModel.scoreboardInputControlIsPhysicallyRunning {
                return "Image Relay is On and processing. The scorebug remains image-first; Period recognition is internal and goals remain manual-only."
            }
            if viewModel.scoreboardInputControlIsTransitioning,
               viewModel.scoreboardInputControlIsRequestedOn {
                return "Image Relay is starting; green appears only after physical processing is acknowledged."
            }
            return viewModel.scoreboardInputControlIsRequestedOn
                ? "Image Relay is On; processing is temporarily suspended by the current route."
                : "Image Relay is Off."
        case .manual:
            return "Automatic scoreboard input is disabled."
        }
    }

    private var runStatusColour: Color {
        switch viewModel.operatingMode {
        case .manual:
            return .orange
        case .ocr, .imageRelay:
            if viewModel.scoreboardInputControlIsPhysicallyRunning { return .green }
            if viewModel.scoreboardInputControlIsRequestedOn { return .orange }
            return .secondary
        }
    }

    private var ocrValuesCard: some View {
        let key = viewModel.selectedRegionKey
        let confidence = viewModel.ocrFieldConfidence[key]
        let accepted = viewModel.acceptedFieldState[key]
        let rawValue = confidence?.raw ?? viewModel.regionOCRPreview[key] ?? "--"
        let acceptedValue = accepted?.acceptedText ?? confidence?.accepted ?? "--"
        let confidenceText = confidence.map { "\(String(format: "%.0f", Double($0.confidence * 100)))% \($0.trustLabel)" } ?? "--"

        return VStack(alignment: .leading, spacing: 10) {
            CalibrationHubSectionHeader(
                title: "Recognition Values",
                systemImage: "text.badge.checkmark",
                help: "Verification results for the selected setup zone. These values never replace live penalty-player relay images."
            )

            CalibrationInfoRow(label: "Selected field", value: key.likelyTitle)
            CalibrationInfoRow(label: "Raw recognition", value: rawValue)
            CalibrationInfoRow(label: "Accepted value", value: acceptedValue)
            CalibrationInfoRow(label: "Confidence", value: confidenceText)
            CalibrationInfoRow(label: "Status", value: viewModel.selectedRegionPreviewStatus)
        }
        .calibrationHubCard()
    }

    private var ocrPreviewImagesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CalibrationHubSectionHeader(
                title: "Test Images",
                systemImage: "photo.on.rectangle.angled",
                help: "Shows the raw, processed and thresholded crop for the selected Scoreboard zone while Verify Zone is active."
            )

            Text(viewModel.selectedRegionPreviewStatus)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                ocrPreviewImageTile(title: "Raw", image: viewModel.selectedRegionRawPreviewImage)
                ocrPreviewImageTile(title: "Processed", image: viewModel.selectedRegionProcessedPreviewImage)
                ocrPreviewImageTile(title: "Thresholded", image: viewModel.selectedRegionThresholdedPreviewImage)
                if viewModel.selectedRegionSegmentPreviewImage != nil {
                    ocrPreviewImageTile(title: "Segments", image: viewModel.selectedRegionSegmentPreviewImage)
                }
            }
        }
        .calibrationHubCard()
    }

    private var imageRelayPreviewCard: some View {
        _ = imageRelayPresentation.revision
        let snapshot = ScoreboardImageRelayStore.shared.snapshot()
        let raw = snapshot.rawImage(for: viewModel.selectedRegionKey).map { UIImage(cgImage: $0) }
        let published = snapshot.image(for: viewModel.selectedRegionKey).map { UIImage(cgImage: $0) }
        let visualValue = snapshot.visualValue(for: viewModel.selectedRegionKey)
        let visualText: String? = {
            switch viewModel.selectedRegionKey {
            case .homeScore, .awayScore:
                return visualValue
            case .period:
                return visualValue.map { "P\($0)" }
            default:
                return nil
            }
        }()

        return VStack(alignment: .leading, spacing: 10) {
            CalibrationHubSectionHeader(
                title: "Relay Output Check",
                systemImage: "rectangle.on.rectangle",
                help: "Clock, penalty timers and penalty-player numbers publish physical Image Relay glyphs. Score and Period publish stable scorebug text; Period is the only continuously retained recognition field."
            )

            Text("Penalty-player numbers remain physical Image Relay images and are never replaced by recognition text. Home recognition is limited to a stable frozen popup crop; Guest popups always use the image. Timer imagery follows physical slot occupancy. No 0:00 detector is used.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                ocrPreviewImageTile(title: "Raw Zone", image: raw)
                if let visualText {
                    VStack(spacing: 6) {
                        Text("Published Text")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.70))
                        Text(visualText)
                            .font(.system(size: 48, weight: .black, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 72)
                            .background(Color.black.opacity(0.42))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    ocrPreviewImageTile(title: "Published Glyph", image: published)
                }
            }
        }
        .calibrationHubCard()
    }

    @ViewBuilder
    private func ocrPreviewImageTile(title: String, image: UIImage?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(RinkLensDesignSystem.font(.micro))
                .foregroundStyle(.white.opacity(0.72))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, minHeight: 74, maxHeight: 90)
                    .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .clipped()
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.28))
                    .frame(maxWidth: .infinity, minHeight: 74, maxHeight: 90)
                    .overlay(
                        Text("Waiting")
                            .font(.caption2.bold())
                            .foregroundStyle(.white.opacity(0.50))
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var imageRelayRulesCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Image Relay controls that affect the picture", systemImage: "checkmark.circle")
                .font(RinkLensDesignSystem.font(.bodyStrong))

            Text("Image Relay uses the saved board perspective, each field zone's position/size/rotation, the camera image and its rotation/focus/exposure/white-balance, plus the selected per-zone colour pipeline and crop padding.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)

            Text("There is no separate recognition mode. Internal recognition is restricted to Period and the stable frozen Home penalty-popup crop; physical hashing and occupancy remain always-on scorebug services.")
                .font(.caption)
                .foregroundStyle(.cyan.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
        }
        .calibrationHubCard()
    }

    private var imageRelayStatusCard: some View {
        _ = imageRelayPresentation.revision
        let snapshot = ScoreboardImageRelayStore.shared.snapshot()
        let expected = ScoreboardImageRelayEngine.relayedKeys
        let publishedKeys = Set(snapshot.fieldImages.keys).union(snapshot.visualFieldValues.keys)
        let missing = expected.subtracting(publishedKeys).map(\.likelyTitle).sorted()
        let ageText = snapshot.ageSeconds.map { String(format: "%.1fs", $0) } ?? "--"
        let frameText = snapshot.sourceSequence.map { String($0) } ?? "--"

        return VStack(alignment: .leading, spacing: 8) {
            CalibrationHubSectionHeader(
                title: "Live relay status",
                systemImage: "waveform.path.ecg.rectangle",
                help: "Shows whether fresh Raw zones and stable Published glyphs are being produced. Full per-field extraction details remain in All Logs."
            )
            CalibrationInfoRow(label: "Status", value: viewModel.imageRelayStatusText)
            Text("Published \(publishedKeys.count)/\(expected.count) fields • frame \(frameText) • age \(ageText)")
                .font(.caption2.monospaced())
                .foregroundStyle(.white.opacity(0.70))
            if !missing.isEmpty {
                Text("Waiting: \(missing.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.orange.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .calibrationHubCard()
    }

    private var manualModeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Manual scoreboard control", systemImage: "hand.tap")
                .font(RinkLensDesignSystem.font(.bodyStrong))
            Text("Automatic scoreboard input is stopped. Use the Broadcast manual controls for clock, score, period and penalties.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)
        }
        .calibrationHubCard()
    }

    private var calibrationPhaseRulesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Scoreboard setup verification", systemImage: "checkmark.seal")
                .font(RinkLensDesignSystem.font(.bodyStrong))
            Text("When zones are visible, all saved crops may be verified without changing the live scorebug. Period and stable frozen Home-player recognition can be inspected; penalty-player occupancy and hash evidence remain physical-image based.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)
        }
        .calibrationHubCard()
    }

    private func toggleOCR() {
        guard viewModel.operatingMode != .manual else {
            onRefresh("manual mode selected; automatic scoreboard input unchanged")
            return
        }
        guard !viewModel.scoreboardInputControlIsTransitioning else { return }
        if viewModel.scoreboardInputControlIsPaused {
            viewModel.startOCRFromCalibration()
        } else {
            viewModel.stopOCRFromCalibration()
        }
        onRefresh("calibration \(viewModel.operatingMode.rawValue) run state toggled")
    }

    private func openTestOCR() {
        onRunTestOCR("hub OCR panel")
        onRefresh("calibration test OCR opened")
    }
}

struct CalibrationActionGrid<Content: View>: View {
    private let content: () -> Content
    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            content()
        }
    }
}

struct CalibrationInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.58))
            Spacer(minLength: 12)
            Text(value)
                .font(RinkLensDesignSystem.font(.caption))
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
    }
}

struct CalibrationHubActionButton: View {
    let title: String
    let systemImage: String
    var prominent = false
    var destructive = false
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        actionButton
            .buttonStyle(CalibrationHubButtonStyle(prominent: prominent, destructive: destructive))
    }

    private var actionButton: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .contentShape(Rectangle())
        }
    }
}

private struct CalibrationHubToggleButton: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        toggleButton
            .buttonStyle(CalibrationHubButtonStyle(prominent: isOn, destructive: false))
    }

    private var toggleButton: some View {
        Button {
            isOn.toggle()
            MainThreadStallMonitor.shared.markContext("calibration tool: \(title) \(isOn ? "on" : "off")")
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .contentShape(Rectangle())
        }
    }
}

private struct CalibrationHubSectionHeader: View {
    let title: String
    let systemImage: String
    let help: String

    var body: some View {
        BroadcastMenuHeaderLabel(title: title, subtitle: help, systemImage: systemImage)
    }
}

struct CalibrationHubButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let prominent: Bool
    let destructive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
            .foregroundStyle(foregroundColor)
            .background(backgroundColor(configuration: configuration), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }

    private var foregroundColor: Color {
        if prominent && !destructive {
            return .black
        }
        return .white
    }

    private func backgroundColor(configuration: Configuration) -> Color {
        let pressedBoost = configuration.isPressed ? 0.08 : 0
        if destructive {
            return Color.red.opacity(0.72 + pressedBoost)
        }
        if prominent {
            return Color.cyan.opacity(0.90 + pressedBoost)
        }
        return Color.black.opacity(0.48 + pressedBoost)
    }

    private var borderColor: Color {
        if destructive {
            return .red.opacity(0.72)
        }
        if prominent {
            return .cyan.opacity(0.82)
        }
        return .white.opacity(0.18)
    }
}

extension View {
    func calibrationHubCard() -> some View {
        self
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .broadcastMenuCard(cornerRadius: 14, opacity: 0.52)
    }
}

// MARK: - v0.9.1s4 Compile Fix - Calibration Camera Orientation Card

private struct CalibrationMenuCameraOrientationCard: View {
    let viewModel: HockeyScoreboardViewModel

    private var currentDegrees: Int {
        Int(viewModel.ocrPreviewRotationOffsetDegrees.rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BroadcastMenuSectionTitle("Image Orientation", systemImage: "rotate.right")

            Text("Use this when the Scoreboard Setup or external camera image is sideways or upside down. This applies to the preview and scoreboard crop mapping together.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                orientationButton(title: "0° Normal", degrees: 0)
                orientationButton(title: "90° Clockwise", degrees: 90)
                orientationButton(title: "180° Upside Down", degrees: 180)
                orientationButton(title: "270° Counter-clockwise", degrees: 270)
            }

            CalibrationActionGrid {
                CalibrationHubActionButton(title: "Rotate Left", systemImage: "rotate.left") {
                    viewModel.rotateOCRPreviewCounterClockwise()
                }

                CalibrationHubActionButton(title: "Rotate Right", systemImage: "rotate.right", prominent: true) {
                    viewModel.rotateOCRPreviewClockwise()
                }
            }

            CalibrationInfoRow(label: "Current calibration/OCR rotation", value: calibrationRotationLabel(currentDegrees))
        }
        .calibrationHubCard()
    }

    private func calibrationRotationLabel(_ degrees: Int) -> String {
        switch ((degrees % 360) + 360) % 360 {
        case 0: return "0° Normal"
        case 90: return "90° Clockwise"
        case 180: return "180° Upside Down"
        case 270: return "270° Counter-clockwise"
        default: return "\(degrees)° Custom"
        }
    }

    private func orientationButton(title: String, degrees: CGFloat) -> some View {
        let selected = currentDegrees == Int(degrees.rounded())
        return Button {
            viewModel.setOCRPreviewRotationDegrees(degrees)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .font(RinkLensDesignSystem.font(.caption))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(CalibrationHubButtonStyle(prominent: selected, destructive: false))
    }
}

#endif
