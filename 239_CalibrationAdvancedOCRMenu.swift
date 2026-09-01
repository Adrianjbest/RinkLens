// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI

// STYLE2 central design system migration: operator chrome/fonts use RinkLensDesignSystem where safe.

// MARK: - v0.9.1s Advanced OCR Settings Menu Refactor

private enum CalibrationAdvancedOCRMenuSection: String, CaseIterable, Identifiable {
    case setup = "Scope"
    case colour = "Colour"
    case thresholds = "Thresholds"
    case display = "Display"
    case snapshot = "Snapshot"
    case maintenance = "Maintenance"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .setup: return "text.viewfinder"
        case .colour: return "paintpalette"
        case .thresholds: return "checkmark.seal"
        case .display: return "eye"
        case .snapshot: return "timer"
        case .maintenance: return "wrench.and.screwdriver"
        }
    }

    var help: String {
        switch self {
        case .setup:
            return "Image Relay and Manual are the only operator modes. Internal recognition is limited to Period and a frozen Home penalty-player crop."
        case .colour:
            return "Per-rink zone colour profiles saved with the template for red, yellow, amber, green, blue, dark and light displays."
        case .thresholds:
            return "Confidence levels required before values are accepted."
        case .display:
            return "Diagnostic overlays shown on the calibration preview."
        case .snapshot:
            return "Current cadence, trust and confidence values."
        case .maintenance:
            return "Reset recognition evidence without touching zone templates."
        }
    }
}

@MainActor
struct CalibrationAdvancedOCRMenu: View {
    @ObservedObject var viewModel: HockeyScoreboardViewModel
    var refreshID: Int = 0
    var onRefresh: (String) -> Void = { _ in }
    @State private var selectedSection: CalibrationAdvancedOCRMenuSection = .setup

    var body: some View {
        let _ = refreshID
        VStack(alignment: .leading, spacing: 12) {
            BroadcastMenuHeaderLabel(
                title: "Recognition Settings",
                subtitle: "Image Relay owns the live scorebug. This menu covers only retained internal recognition and zone colour setup.",
                systemImage: "slider.horizontal.3"
            )

            menuStrip
            selectedHelpText

            Divider().opacity(0.22)

            selectedSectionBody
        }
        .calibrationHubCard()
    }

    private var menuStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CalibrationAdvancedOCRMenuSection.allCases) { section in
                    Button {
                        selectedSection = section
                        onRefresh("recognition menu: \(section.rawValue)")
                        MainThreadStallMonitor.shared.markContext("recognition menu: \(section.rawValue)")
                    } label: {
                        Label(section.rawValue, systemImage: section.systemImage)
                            .font(RinkLensDesignSystem.font(.caption))
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .foregroundStyle(selectedSection == section ? .black : .white)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(selectedSection == section ? Color.cyan.opacity(0.92) : Color.white.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(selectedSection == section ? Color.cyan.opacity(0.9) : Color.white.opacity(0.16), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 1)
        }
    }

    private var selectedHelpText: some View {
        Text(selectedSection.help)
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.66))
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var selectedSectionBody: some View {
        switch selectedSection {
        case .setup:
            setupSection
        case .colour:
            colourSection
        case .thresholds:
            thresholdsSection
        case .display:
            displaySection
        case .snapshot:
            snapshotSection
        case .maintenance:
            maintenanceSection
        }
    }

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Image Relay", systemImage: "rectangle.on.rectangle")
                .font(RinkLensDesignSystem.font(.bodyStrong))
            Text("Live clock, scores, player numbers and penalty timers remain scorebug-first. Player numbers are physical Image Relay images and recognition cannot replace them.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.66))

            Divider().opacity(0.22)

            Label("Retained internal recognition", systemImage: "text.viewfinder")
                .font(RinkLensDesignSystem.font(.bodyStrong))
            Text("Period runs internally every 5 seconds. A stable frozen Home penalty-player crop receives at most three roster-match attempts in 2.5 seconds. Guest popups always use the frozen Image Relay image.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var colourSection: some View {
        CalibrationOCRColourProfilesPanel(viewModel: viewModel, refreshID: refreshID, onRefresh: onRefresh)
    }

    private var thresholdsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            thresholdRow(title: "Period", value: $viewModel.ocrThresholds.period)
            thresholdRow(title: "Frozen Home Player", value: $viewModel.ocrThresholds.penaltyPlayer)
        }
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Show Recognition Boxes", isOn: $viewModel.ocrDiagnosticDisplayOptions.showOCRBoxes)
            Toggle("Show Raw Recognition Values", isOn: $viewModel.ocrDiagnosticDisplayOptions.showOCRRawValues)
            Toggle("Show Recognition Confidence", isOn: $viewModel.ocrDiagnosticDisplayOptions.showOCRConfidence)
            Toggle("Show Recogniser Colours", isOn: $viewModel.ocrDiagnosticDisplayOptions.showRecogniserColours)
            Toggle("Show Accepted Values", isOn: $viewModel.ocrDiagnosticDisplayOptions.showAcceptedValues)
        }
    }

    private var snapshotSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            tuningRow("Period", viewModel.ocrTuningSnapshot.period)
            tuningRow("Frozen Home player", viewModel.ocrTuningSnapshot.penaltyPlayer)
        }
    }

    private var maintenanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    viewModel.resetOCRTrustState()
                    onRefresh("recognition evidence reset")
                } label: {
                    Label("Reset Recognition Evidence", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(CalibrationHubButtonStyle(prominent: false, destructive: false))

                Button {
                    viewModel.clearDebugHistory()
                    onRefresh("recognition history cleared")
                } label: {
                    Label("Clear Recognition History", systemImage: "trash")
                }
                .buttonStyle(CalibrationHubButtonStyle(prominent: false, destructive: false))
            }

            Text("These actions reset retained recognition evidence only. They do not load, save or alter zone templates or stop Image Relay.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.66))
        }
    }

    private func thresholdRow(title: String, value: Binding<Float>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(title): \(String(format: "%.2f", value.wrappedValue))")
                    .font(RinkLensDesignSystem.font(.caption))
                Spacer()
                Button("−") { value.wrappedValue = max(0.30, value.wrappedValue - 0.02) }
                    .buttonStyle(CalibrationHubButtonStyle(prominent: false, destructive: false))
                Button("+") { value.wrappedValue = min(0.95, value.wrappedValue + 0.02) }
                    .buttonStyle(CalibrationHubButtonStyle(prominent: false, destructive: false))
            }
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Float($0) }
                ),
                in: 0.30...0.95
            )
        }
    }

    private func tuningRow(_ title: String, _ tuning: OCRZoneTuning) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(RinkLensDesignSystem.font(.caption))
            Spacer(minLength: 12)
            Text("cadence \(String(format: "%.1fs", tuning.cadenceSeconds)) / confidence \(String(format: "%.2f", tuning.confidence)) / trust \(tuning.trust)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.66))
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - UX14x Direct Per-Zone OCR Colour Profiles Screen

struct CalibrationOCRColourProfilesPanel: View {
    @ObservedObject var viewModel: HockeyScoreboardViewModel
    var refreshID: Int = 0
    var onRefresh: (String) -> Void = { _ in }

    private let quickPipelines: [OCRColourPipeline] = [
        .auto,
        .redOnBlack,
        .yellowWhiteOnBlack,
        .amberOrangeOnBlack,
        .greenOnBlack,
        .blueCyanOnBlack,
        .lightOnDark,
        .darkOnLight,
        .greyscale
    ]

    var body: some View {
        let _ = refreshID
        VStack(alignment: .leading, spacing: 14) {
            BroadcastMenuHeaderLabel(
                title: viewModel.operatingMode == .imageRelay ? "Image Relay Colour Masks" : "Zone Colour Profiles",
                subtitle: viewModel.operatingMode == .imageRelay
                    ? "Select the illuminated character colour and background for each relay zone. Crop padding also affects the relayed image."
                    : "Set the character colour, background and extraction pipeline per zone. These values save with the active rink/template.",
                systemImage: "paintpalette"
            )

            selectedZoneCard
            zoneTableCard
            editorCard
            defaultsCard
        }
    }

    private var selectedZoneCard: some View {
        let key = viewModel.selectedRegionKey
        let profile = viewModel.ocrColourProfiles.profile(for: key)
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Selected zone")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.58))
                Text(key.likelyTitle)
                    .font(RinkLensDesignSystem.font(.bodyStrong))
                Text(profile.summaryText)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.66))
            }

            Text("Use the shared selector above, or tap a row below, then edit that zone's colour profile.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.62))
        }
        .calibrationHubCard()
    }

    private var zoneTableCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CalibrationAdvancedOCRSectionHeader(
                title: "Per-zone summary",
                systemImage: "list.bullet.rectangle",
                help: "Tap a row to edit that zone. Home/Away scores and penalty timers can use red-on-black while clock and period use yellow/white-on-black."
            )

            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(OCRRegionKey.calibrationCases) { key in
                    zoneSummaryRow(key)
                }
            }
        }
        .calibrationHubCard()
    }

    private func zoneSummaryRow(_ key: OCRRegionKey) -> some View {
        let profile = viewModel.ocrColourProfiles.profile(for: key)
        let isSelected = viewModel.selectedRegionKey == key
        return Button {
            viewModel.selectOCRRegion(key)
            onRefresh("OCR colour row selected: \(key.rawValue)")
            MainThreadStallMonitor.shared.markContext("UX14x OCR colour row selected: \(key.rawValue)")
        } label: {
            HStack(spacing: 10) {
                Text(key.likelyTitle)
                    .font(RinkLensDesignSystem.font(.caption))
                    .foregroundStyle(isSelected ? .black : .white)
                    .frame(width: 132, alignment: .leading)

                Text(profile.usesAutomaticPipelineSelection
                     ? "Auto→\(profile.resolvedPipeline(for: key).shortTitle)"
                     : "Fixed→\(profile.resolvedPipeline(for: key).shortTitle)")
                    .font(.caption2.bold())
                    .foregroundStyle(isSelected ? .black.opacity(0.82) : .cyan)
                    .frame(width: 96, alignment: .leading)

                Text("\(profile.characterColour.title) on \(profile.backgroundColour.title)")
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .black.opacity(0.72) : .white.opacity(0.66))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Spacer(minLength: 6)

                Text("\(Int((profile.cropPaddingPercent * 100).rounded()))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isSelected ? .black.opacity(0.70) : .white.opacity(0.52))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected ? Color.cyan.opacity(0.92) : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.cyan.opacity(0.95) : Color.white.opacity(0.14), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var editorCard: some View {
        let key = viewModel.selectedRegionKey
        return VStack(alignment: .leading, spacing: 12) {
            CalibrationAdvancedOCRSectionHeader(
                title: "Edit \(key.likelyTitle)",
                systemImage: "slider.horizontal.3",
                help: "These controls update only the selected zone. Save or update the rink zone profile/template to make the settings persistent for that rink."
            )

            quickPipelineButtons(for: key)
            colourProfileEditor(for: key)
        }
        .calibrationHubCard()
    }

    private func quickPipelineButtons(for key: OCRRegionKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick pipeline")
                .font(RinkLensDesignSystem.font(.caption))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(quickPipelines) { pipeline in
                        let profile = viewModel.ocrColourProfiles.profile(for: key)
                        let active = pipeline == .auto
                            ? profile.usesAutomaticPipelineSelection
                            : !profile.usesAutomaticPipelineSelection && profile.resolvedPipeline(for: key) == pipeline
                        Button {
                            setPipeline(pipeline, for: key)
                        } label: {
                            Text(pipeline.shortTitle)
                                .font(.caption.bold())
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .foregroundStyle(active ? .black : .white)
                                .background(active ? Color.yellow.opacity(0.92) : Color.black.opacity(0.42), in: Capsule())
                                .overlay(Capsule().stroke(active ? Color.yellow.opacity(0.92) : Color.white.opacity(0.18), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func colourProfileEditor(for key: OCRRegionKey) -> some View {
        let profile = viewModel.bindingForOCRColourProfile(key)
        return VStack(alignment: .leading, spacing: 12) {
            profilePickerBlock(
                title: "Pipeline",
                help: profile.wrappedValue.usesAutomaticPipelineSelection
                    ? OCRColourPipeline.auto.helpText
                    : profile.wrappedValue.pipeline.helpText
            ) {
                Picker("Pipeline", selection: Binding(
                    get: {
                        profile.wrappedValue.usesAutomaticPipelineSelection
                            ? .auto
                            : profile.wrappedValue.pipeline
                    },
                    set: { newValue in
                        var updated = profile.wrappedValue
                        updated.setPipelineSelection(newValue, for: key)
                        profile.wrappedValue = updated
                        onRefresh("OCR colour pipeline changed: \(key.rawValue) \(updated.pipelineSelectionStatus(for: key))")
                    }
                )) {
                    ForEach(OCRColourPipeline.allCases) { pipeline in
                        Text(pipeline.title).tag(pipeline)
                    }
                }
                .pickerStyle(.menu)
            }

            HStack(alignment: .top, spacing: 12) {
                profilePickerBlock(title: "Character colour", help: "Colour of the scoreboard character in this zone.") {
                    Picker("Character colour", selection: Binding(
                        get: { profile.wrappedValue.characterColour },
                        set: { newValue in
                            var updated = profile.wrappedValue
                            updated.characterColour = newValue
                            profile.wrappedValue = updated
                            onRefresh("OCR character colour changed: \(key.rawValue)")
                        }
                    )) {
                        ForEach(OCRCharacterColour.allCases) { colour in
                            Text(colour.title).tag(colour)
                        }
                    }
                    .pickerStyle(.menu)
                }

                profilePickerBlock(title: "Background", help: "Background behind the character.") {
                    Picker("Background", selection: Binding(
                        get: { profile.wrappedValue.backgroundColour },
                        set: { newValue in
                            var updated = profile.wrappedValue
                            updated.backgroundColour = newValue
                            profile.wrappedValue = updated
                            onRefresh("OCR background colour changed: \(key.rawValue)")
                        }
                    )) {
                        ForEach(OCRBackgroundColour.allCases) { colour in
                            Text(colour.title).tag(colour)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Button {
                    let result = viewModel.autoDetectSelectedZoneCharacterColour()
                    onRefresh(result)
                } label: {
                    Label("Detect visible character colour", systemImage: "eyedropper.halffull")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)

                Text("Samples the perspective-aligned selected-zone crop used by OCR/Image Relay geometry. If no character is confidently visible, the established default for this zone is applied.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.66))
            }

            VStack(alignment: .leading, spacing: 5) {
                Toggle("Auto-select pipeline from calibrated colours", isOn: Binding(
                    get: { profile.wrappedValue.usesAutomaticPipelineSelection },
                    set: { newValue in
                        var updated = profile.wrappedValue
                        updated.setAutomaticPipelineSelection(newValue, for: key)
                        profile.wrappedValue = updated
                        onRefresh("OCR pipeline mode changed: \(key.rawValue) \(updated.pipelineSelectionStatus(for: key))")
                    }
                ))

                Text("Auto uses the saved character/background colours to select the processing pipeline. It does not continuously resample the camera. Guided Calibration Auto refreshes the colours and enables this mode; Pick Colour samples one stroke and fixes the matching pipeline.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.66))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Crop padding: \(Int((profile.wrappedValue.cropPaddingPercent * 100).rounded()))%")
                    .font(RinkLensDesignSystem.font(.caption))
                Slider(
                    value: Binding(
                        get: { profile.wrappedValue.cropPaddingPercent },
                        set: { newValue in
                            var updated = profile.wrappedValue
                            updated.cropPaddingPercent = newValue
                            profile.wrappedValue = updated
                            onRefresh("OCR crop padding changed: \(key.rawValue)")
                        }
                    ),
                    in: 0.0...0.15
                )
                Text(viewModel.operatingMode == .imageRelay
                     ? "Padding is saved per zone and changes the raw crop used by Image Relay. Keep it small unless illuminated edges are being cut off."
                     : "Padding is saved per zone and used by the OCR processing profile. Keep it small unless the crop is cutting off digit edges.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.66))
            }
        }
    }

    private var defaultsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CalibrationAdvancedOCRSectionHeader(
                title: "Rink/template defaults",
                systemImage: "star.square",
                help: "Reset to sensible hockey scoreboard defaults, then save the active rink/template when the profiles look right."
            )

            Text(viewModel.ocrColourProfiles.compactSummary)
                .font(.caption2.monospaced())
                .foregroundStyle(.white.opacity(0.70))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    viewModel.applyOCRColourProfileDefaults()
                    onRefresh("OCR colour profile defaults")
                    MainThreadStallMonitor.shared.markContext("UX14x OCR colour defaults applied")
                } label: {
                    Label("Reset defaults", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(CalibrationHubButtonStyle(prominent: false, destructive: false))

                Button {
                    setCommonScoreboardDefaults()
                } label: {
                    Label("Apply common board", systemImage: "paintpalette.fill")
                }
                .buttonStyle(CalibrationHubButtonStyle(prominent: true, destructive: false))
            }

            Text("Common board = Clock/Period yellow-white on black, scores and penalty timers red on black, penalty player numbers yellow-white on black.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
        }
        .calibrationHubCard()
    }

    private func profilePickerBlock<Content: View>(title: String, help: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(RinkLensDesignSystem.font(.caption))
            content()
            Text(help)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func setPipeline(_ pipeline: OCRColourPipeline, for key: OCRRegionKey) {
        var profiles = viewModel.ocrColourProfiles
        var profile = profiles.profile(for: key)
        profile.setPipelineSelection(pipeline, for: key)
        if pipeline != .auto {
            profile.backgroundColour = pipeline == .darkOnLight ? .white : .black
            switch pipeline {
            case .redOnBlack:
                profile.characterColour = .red
            case .yellowWhiteOnBlack:
                profile.characterColour = .yellow
            case .amberOrangeOnBlack:
                profile.characterColour = .amber
            case .greenOnBlack:
                profile.characterColour = .green
            case .blueCyanOnBlack:
                profile.characterColour = .cyan
            case .lightOnDark:
                profile.characterColour = .white
            case .darkOnLight:
                profile.characterColour = .black
            case .greyscale:
                profile.characterColour = .auto
                profile.backgroundColour = .auto
            case .auto:
                break
            }
        }
        profiles[key] = profile
        viewModel.ocrColourProfiles = profiles
        onRefresh("OCR quick pipeline \(pipeline.shortTitle): \(key.rawValue) \(profile.pipelineSelectionStatus(for: key))")
        MainThreadStallMonitor.shared.markContext("UX16d40a20 OCR pipeline mode \(profile.pipelineSelectionStatus(for: key)): \(key.rawValue)")
    }

    private func setCommonScoreboardDefaults() {
        var profiles = OCRColourProfileSet.defaults
        for key in OCRRegionKey.calibrationCases {
            profiles[key] = OCRZoneColourProfile.defaultProfile(for: key)
        }
        viewModel.ocrColourProfiles = profiles
        onRefresh("OCR common colour-profile defaults")
        MainThreadStallMonitor.shared.markContext("UX14x OCR common colour-profile defaults applied")
    }
}

private struct CalibrationAdvancedOCRSectionHeader: View {
    let title: String
    let systemImage: String
    let help: String

    var body: some View {
        BroadcastMenuHeaderLabel(title: title, subtitle: help, systemImage: systemImage)
    }
}


#endif
