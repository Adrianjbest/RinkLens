// BUILD 700 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import UIKit
import PhotosUI

// MARK: - RinkLens NextGen S11H Settings / Broadcast Setup

/// NextGen settings workspace.
///
/// S11H makes Command Centre -> Settings -> Broadcast Setup the clear home for
/// team logos, saved match profiles, scorebug look and event popup controls.
/// It keeps live Broadcast simple and does not alter camera, OCR, recording,
/// renderer, stream, clip-buffer, or diagnostics ownership.
struct SettingsRouteShellView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    let viewModel: HockeyScoreboardViewModel

    var body: some View {
        SettingsView(
            viewModel: viewModel,
            onReturnToCommandCentre: {
                MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("Settings -> Command Centre"))
                coordinator.navigate(to: .commandCentre)
            }
        )
    }
}

struct SettingsView: View {
    let viewModel: HockeyScoreboardViewModel
    let onReturnToCommandCentre: () -> Void

    @ObservedObject private var scoreboardSettings = BroadcastScoreboardLayoutSettings.shared
    @ObservedObject private var popupSettings = BroadcastEventPopupSettings.shared
    @ObservedObject private var appearanceSettings = RinkLensAppearanceSettings.shared
    @ObservedObject private var sponsorStore = SponsorCatalogueStore.shared
    @ObservedObject private var recorder = AppContainer.shared.recordingEngine
    @ObservedObject private var liveCamera: HockeyCameraService

    init(viewModel: HockeyScoreboardViewModel, onReturnToCommandCentre: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onReturnToCommandCentre = onReturnToCommandCentre
        _liveCamera = ObservedObject(wrappedValue: viewModel.liveCameraService)
    }

    @State private var selectedSection: SettingsSection = .profiles
    @State private var selectedHomeLogoItem: PhotosPickerItem?
    @State private var selectedAwayLogoItem: PhotosPickerItem?
    @State private var profileName = ""
    @State private var duplicateTeamTemplate: TeamIdentityTemplate?
    @State private var duplicateTeamTemplateName = ""
    @State private var deleteTeamTemplate: TeamIdentityTemplate?
    @State private var settingsPreviewPopup: BroadcastEvent?
    @State private var settingsPreviewDismissTask: Task<Void, Never>?
    @State private var hasUnsavedProfileChanges = false
    @State private var showSaveActiveProfilePrompt = false
    @State private var showNoActiveProfilePrompt = false
    @State private var pendingSettingsSection: SettingsSection?
    @State private var pendingReturnToCommandCentre = false
    @State private var homeLogoSelectionRevision = 0
    @State private var awayLogoSelectionRevision = 0
    @State private var cachedScoreboardPreviewLayout = BroadcastScoreboardLayoutSettings.shared
        .snapshot
    @State private var scorebugPreviewRefreshTask: Task<Void, Never>?
    @State private var profileAutoSaveTask: Task<Void, Never>?
    @State private var teamNamePersistenceTask: Task<Void, Never>?
    @State private var profileUIRevision = 0
    @State private var showClearSandboxConfirmation = false
    @State private var showResetConfigurationConfirmation = false
    @State private var storageMaintenanceStatus = "No storage maintenance requested"
    @State private var storageMaintenanceRunning = false
    @FocusState private var focusedSettingsField: SettingsInputField?

    /// Derived directly from the authoritative RecordingEngine state. No local
    /// mirror is retained, so Settings cannot disagree with the writer lifecycle.
    private var recordingPresentationWorkSuspended: Bool {
        RinkLensRiskFeaturePolicy.isEnabled(.recordingHiddenPresentationSuspensionV25)
            && recorder.canStop
    }

    private enum SettingsInputField: Hashable {
        case homeTeam
        case awayTeam
        case profileName
    }

    private enum SettingsSection: String, CaseIterable, Identifiable {
        case profiles
        case teamsAndLogos
        case scorebug
        case eventPopups
        case squad
        case sponsors
        case appearance
        case system

        var id: String { rawValue }

        var title: String {
            switch self {
            case .teamsAndLogos: return "Teams & Logos"
            case .appearance: return "Appearance"
            case .scorebug: return "Scorebug"
            case .eventPopups: return "Event Popups"
            case .squad: return "Squad"
            case .profiles: return "Profiles"
            case .sponsors: return "Sponsors"
            case .system: return "System"
            }
        }

        var isProfileBound: Bool {
            switch self {
            case .teamsAndLogos, .scorebug: return true
            default: return false
            }
        }

    }

    var body: some View {
        settingsAlertsView
    }

    private var settingsBaseView: some View {
        ZStack {
            SettingsBackground()

            ScrollView {
                // Build 688: Settings is a single moderate-sized workspace, not an
                // unbounded feed. A LazyVStack combined with root AnyView
                // replacement and a transient autosave banner could preserve a
                // stale scroll offset beyond the rebuilt content, leaving only the
                // background visible after Team Font or another scorebug setting
                // changed. Keep one concrete, eagerly laid-out tree so the scroll
                // container retains valid geometry throughout every edit.
                VStack(alignment: .leading, spacing: 20) {
                    header
                    sectionPicker
                    profileSaveBanner
                    selectedSectionView
                        // Recreate section-local controls only when the operator
                        // deliberately changes tabs, never for a value edit.
                        .id(selectedSection.rawValue)
                }
                .rinkLensHeavyScreenContent(maxWidth: 1180, horizontal: 28, vertical: 24)
                .padding(.top, RinkLensCommandCentreChrome.scrollContentTopClearance)
            }
            .rinkLensScrollPerformance("Settings")
        }
        .preferredColorScheme(.dark)
        .rinkLensCommandCentreReturnButton(action: requestReturnToCommandCentre)
    }

    @ViewBuilder
    private var selectedSectionView: some View {
        switch selectedSection {
        case .teamsAndLogos:
            teamsAndLogosSection
        case .appearance:
            appearanceSection
        case .scorebug:
            scorebugSection
        case .eventPopups:
            eventPopupsSection
        case .squad:
            squadSection
        case .profiles:
            profilesSection
        case .sponsors:
            sponsorsSection
        case .system:
            systemSection
        }
    }

    private var settingsLifecycleView: some View {
        settingsBaseView
            .onAppear {
                if profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    profileName = viewModel.teamIdentityTemplates
                        .first(where: { $0.id == viewModel.selectedTeamIdentityTemplateID })?.name
                        ?? "\(viewModel.homeTeamName) vs \(viewModel.awayTeamName)"
                }
                if !recordingPresentationWorkSuspended {
                    cachedScoreboardPreviewLayout = scoreboardSettings.snapshot
                }
                MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext(
                    recordingPresentationWorkSuspended
                        ? "Settings module appeared — recording thermal isolation; preview suspended"
                        : "Settings module appeared — cached preview"
                ))
                if recordingPresentationWorkSuspended {
                    RinkLensStructuredEventLogger.shared.record(
                        domain: .recording,
                        event: "recording_hidden_presentation_suspended",
                        entityID: "settings-preview",
                        previous: ["route": "settings", "rendering": "requested"],
                        next: ["rendering": "suspended", "authoritativeSettings": "retained"],
                        source: "SettingsView.onAppear",
                        reason: "Writer session already open when Settings appeared",
                        authoritativeOwner: "RecordingEngine presentation policy"
                    )
                }
            }
            .onChange(of: recorder.state) { _, _ in
                if recordingPresentationWorkSuspended {
                    scorebugPreviewRefreshTask?.cancel()
                    scorebugPreviewRefreshTask = nil
                    settingsPreviewDismissTask?.cancel()
                    settingsPreviewDismissTask = nil
                    settingsPreviewPopup = nil
                    RinkLensStructuredEventLogger.shared.record(
                        domain: .recording,
                        event: "recording_hidden_presentation_suspended",
                        entityID: "settings-preview",
                        previous: ["rendering": "available"],
                        next: ["rendering": "suspended", "authoritativeSettings": "retained"],
                        source: "SettingsView",
                        reason: "RecordingEngine opened a writer session",
                        authoritativeOwner: "RecordingEngine presentation policy"
                    )
                } else {
                    cachedScoreboardPreviewLayout = scoreboardSettings.snapshot
                    RinkLensStructuredEventLogger.shared.record(
                        domain: .recording,
                        event: "recording_hidden_presentation_resumed",
                        entityID: "settings-preview",
                        previous: ["rendering": "suspended"],
                        next: ["rendering": "current-snapshot-only"],
                        source: "SettingsView",
                        reason: "RecordingEngine closed its writer session",
                        authoritativeOwner: "RecordingEngine presentation policy"
                    )
                }
            }
            .onDisappear {
                scorebugPreviewRefreshTask?.cancel()
                scorebugPreviewRefreshTask = nil
                teamNamePersistenceTask?.cancel()
                teamNamePersistenceTask = nil
                // Commit the final text once when Settings closes. Build 658 wrote
                // UserDefaults and profile files for every keystroke, which made
                // team-name editing visibly laggy.
                viewModel.persistWorkingTeamNames()
                // Do not cancel profileAutoSaveTask. The selected profile must
                // retain the final team-name/logo/style edit after Settings closes.
            }
    }

    private var settingsProfileChangeView: some View {
        settingsLifecycleView
            .onChange(of: scoreboardSettings.snapshot) { _, snapshot in
                markProfileBoundChange(reason: "scorebug settings changed")
                scorebugPreviewRefreshTask?.cancel()
                guard !recordingPresentationWorkSuspended else {
                    scorebugPreviewRefreshTask = nil
                    MainThreadStallMonitor.shared.markContext(
                        RinkLensBuildInfo.traceContext("Settings preview render suppressed while recording; authoritative setting retained")
                    )
                    return
                }
                scorebugPreviewRefreshTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard !Task.isCancelled else { return }
                    cachedScoreboardPreviewLayout = snapshot
                    MainThreadStallMonitor.shared.markContext(
                        RinkLensBuildInfo.traceContext("Settings cached preview layout committed off live relay")
                    )
                }
            }
    }

    private var settingsPopupChangeView: some View {
        settingsProfileChangeView
            .onChange(of: popupSettings.goalPopupsEnabled) { _, enabled in
                handleEventPopupToggleChanged(enabled: enabled, affectedType: .goal, reason: "goal popup toggle")
            }
            .onChange(of: popupSettings.penaltyPopupsEnabled) { _, enabled in
                handleEventPopupToggleChanged(enabled: enabled, affectedType: .penalty, reason: "penalty popup toggle")
            }
            .onChange(of: popupSettings.goalTeamLogosEnabled) { _, _ in
                refreshInlineEventPopupPreview(reason: "goal logo toggle")
            }
            .onChange(of: popupSettings.penaltyTeamLogosEnabled) { _, _ in
                refreshInlineEventPopupPreview(reason: "penalty logo toggle")
            }
            .onChange(of: popupSettings.useActualTeamNames) { _, _ in
                refreshInlineEventPopupPreview(reason: "actual team names toggle")
            }
    }

    private var settingsLogoChangeView: some View {
        settingsPopupChangeView
            .onChange(of: selectedHomeLogoItem) { _, item in
                guard let item else { return }
                homeLogoSelectionRevision &+= 1
                let selectionRevision = homeLogoSelectionRevision
                Task {
                    let data = try? await item.loadTransferable(type: Data.self)
                    await MainActor.run {
                        guard selectionRevision == homeLogoSelectionRevision else { return }
                        // PhotosPicker does not emit another change when the same item remains selected.
                        // Clear the transient picker value after every attempt so the operator can
                        // choose the same logo again after loading or creating a profile.
                        selectedHomeLogoItem = nil
                        guard let data, UIImage(data: data) != nil else {
                            MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("home logo load failed; picker reset"))
                            return
                        }
                        viewModel.setHomeLogo(data: data)
                        refreshProfileUI()
                        markProfileBoundChange(reason: "home logo changed")
                        MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("home logo updated; picker reset"))
                    }
                }
            }
            .onChange(of: selectedAwayLogoItem) { _, item in
                guard let item else { return }
                awayLogoSelectionRevision &+= 1
                let selectionRevision = awayLogoSelectionRevision
                Task {
                    let data = try? await item.loadTransferable(type: Data.self)
                    await MainActor.run {
                        guard selectionRevision == awayLogoSelectionRevision else { return }
                        selectedAwayLogoItem = nil
                        guard let data, UIImage(data: data) != nil else {
                            MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("away logo load failed; picker reset"))
                            return
                        }
                        viewModel.setAwayLogo(data: data)
                        refreshProfileUI()
                        markProfileBoundChange(reason: "away logo changed")
                        MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("away logo updated; picker reset"))
                    }
                }
            }
    }

    private var duplicateProfileAlertBinding: Binding<Bool> {
        Binding(get: { duplicateTeamTemplate != nil }, set: { if !$0 { duplicateTeamTemplate = nil } })
    }

    private var deleteProfileAlertBinding: Binding<Bool> {
        Binding(get: { deleteTeamTemplate != nil }, set: { if !$0 { deleteTeamTemplate = nil } })
    }

    private var duplicateProfileAlertView: some View {
        settingsLogoChangeView
            .alert("Duplicate profile", isPresented: duplicateProfileAlertBinding) {
                TextField("Profile name", text: $duplicateTeamTemplateName)
                Button("Cancel", role: .cancel) { duplicateTeamTemplate = nil }
                Button("Duplicate") {
                    if let duplicateTeamTemplate {
                        viewModel.duplicateTeamIdentityTemplate(duplicateTeamTemplate, newName: duplicateTeamTemplateName)
                        refreshProfileUI()
                    }
                    duplicateTeamTemplate = nil
                }
            } message: {
                Text("Create a copy of this saved match profile.")
            }
    }

    private var deleteProfileAlertView: some View {
        duplicateProfileAlertView
            .alert("Delete profile?", isPresented: deleteProfileAlertBinding) {
                Button("Cancel", role: .cancel) { deleteTeamTemplate = nil }
                Button("Delete", role: .destructive) {
                    if let deleteTeamTemplate {
                        viewModel.deleteTeamIdentityTemplate(deleteTeamTemplate)
                        refreshProfileUI()
                    }
                    deleteTeamTemplate = nil
                }
            } message: {
                Text("This removes the saved team names and logo references for this profile. Current live teams are not changed unless this profile is active.")
            }
    }

    private var saveProfileAlertView: some View {
        deleteProfileAlertView
            .alert("Save changes to active profile?", isPresented: $showSaveActiveProfilePrompt) {
                Button("Cancel", role: .cancel) { clearPendingProfileNavigation() }
                Button("Leave without saving", role: .destructive) { leaveProfileChangesUnsavedAndContinue() }
                Button("Save") { saveActiveProfileAndContinue() }
            } message: {
                Text("You changed Teams & Logos or Scorebug settings. Save these changes to the active profile before leaving this section?")
            }
    }

    private var settingsAlertsView: some View {
        saveProfileAlertView
            .alert("No active profile loaded", isPresented: $showNoActiveProfilePrompt) {
                Button("Cancel", role: .cancel) { clearPendingProfileNavigation() }
                Button("Go to Profiles") { routeToProfilesForSave() }
            } message: {
                Text("To save these Teams & Logos or Scorebug changes, load an existing profile or create a new one in Profiles.")
            }
            .alert("Clear local media and diagnostics?", isPresented: $showClearSandboxConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Clear Local Data", role: .destructive) { clearOperatorRequestedSandboxData() }
            } message: {
                Text("This removes recordings and clips held inside the RinkLens sandbox, exported logs, OCR evidence, structured diagnostics, caches and temporary files. Videos already in Photos are not deleted. This cannot be undone.")
            }
            .alert("Reset all configuration?", isPresented: $showResetConfigurationConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Reset on Next Launch", role: .destructive) {
                    RinkLensConfigurationResetTransaction.requestForNextLaunch()
                    storageMaintenanceStatus = "Configuration reset scheduled. Fully close and reopen RinkLens. Photos and local media are unchanged."
                }
            } message: {
                Text("On the next launch this removes saved profiles, rink calibration, camera, streaming destination/key, scorebug, sponsor and appearance preferences. Media and Photos are not deleted.")
            }
    }

    private func teamNameBinding(home: Bool) -> Binding<String> {
        Binding(
            get: { home ? viewModel.homeTeamName : viewModel.awayTeamName },
            set: { value in
                if home { viewModel.homeTeamName = value } else { viewModel.awayTeamName = value }
                // Keep typing responsive. Persist only after the operator pauses,
                // rather than writing names and profile JSON on every character.
                teamNamePersistenceTask?.cancel()
                // An active profile is persisted by the existing profile autosave.
                // Only the no-profile working names need their own delayed write.
                if viewModel.selectedTeamIdentityTemplateID == nil {
                    teamNamePersistenceTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 650_000_000)
                        guard !Task.isCancelled else { return }
                        viewModel.persistWorkingTeamNames()
                        MainThreadStallMonitor.shared.markContext(
                            RinkLensBuildInfo.traceContext("Settings working team names persisted after typing settled")
                        )
                    }
                }
                markProfileBoundChange(reason: home ? "home team changed" : "away team changed")
            }
        )
    }

    private func refreshProfileUI() {
        profileUIRevision &+= 1
        cachedScoreboardPreviewLayout = scoreboardSettings.snapshot
    }

    private func handleSettingsSectionSelection(_ section: SettingsSection) {
        guard section != selectedSection else { return }
        focusedSettingsField = nil
        MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("Settings section requested: \(section.title)"))
        if selectedSection.isProfileBound && hasUnsavedProfileChanges {
            pendingSettingsSection = section
            promptForProfileSaveIfNeeded()
        } else {
            let previousSection = selectedSection
            selectedSection = section
            RinkLensStructuredEventLogger.shared.record(
                domain: .navigation,
                event: "settings_section_changed",
                entityID: "broadcast-setup",
                previous: ["section": previousSection.rawValue],
                next: ["section": section.rawValue],
                source: "SettingsView",
                reason: "Operator selected \(section.title)",
                authoritativeOwner: "SettingsView.NavigationProjection"
            )
            MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("Settings section: \(section.title)"))
        }
    }

    private func requestReturnToCommandCentre() {
        focusedSettingsField = nil
        if selectedSection.isProfileBound && hasUnsavedProfileChanges {
            pendingReturnToCommandCentre = true
            promptForProfileSaveIfNeeded()
        } else {
            onReturnToCommandCentre()
        }
    }

    private func promptForProfileSaveIfNeeded() {
        if viewModel.selectedTeamIdentityTemplateID == nil {
            showNoActiveProfilePrompt = true
        } else {
            showSaveActiveProfilePrompt = true
        }
    }

    private func markProfileBoundChange(reason: String) {
        guard selectedSection.isProfileBound else { return }
        MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("profile-bound settings changed: \(reason)"))

        // Build 688: an active profile is already auto-saved after interaction
        // settles. Do not insert an "unsaved" banner and then remove it 700 ms
        // later, and do not force a whole Settings-tree revision after the write.
        // Those structural changes were the common path behind the blank/empty
        // Scorebug page after Team Font and other controls changed.
        if viewModel.selectedTeamIdentityTemplateID != nil {
            hasUnsavedProfileChanges = false
            profileAutoSaveTask?.cancel()
            profileAutoSaveTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                viewModel.updateActiveTeamIdentityTemplateWithCurrentScoreboardStyle()
                MainThreadStallMonitor.shared.markContext(
                    RinkLensBuildInfo.traceContext("active broadcast profile auto-saved without Settings rebuild: \(reason)")
                )
            }
            return
        }

        // With no active profile there is nowhere safe to persist the profile-
        // bound edit. Keep one stable warning banner until the operator creates
        // or loads a profile.
        hasUnsavedProfileChanges = true
    }

    private func resetTransientLogoPickerSelections() {
        homeLogoSelectionRevision &+= 1
        awayLogoSelectionRevision &+= 1
        selectedHomeLogoItem = nil
        selectedAwayLogoItem = nil
    }

    private func saveActiveProfileAndContinue() {
        viewModel.updateActiveTeamIdentityTemplateWithCurrentScoreboardStyle()
        refreshProfileUI()
        hasUnsavedProfileChanges = false
        continuePendingProfileNavigation()
    }

    private func leaveProfileChangesUnsavedAndContinue() {
        hasUnsavedProfileChanges = false
        continuePendingProfileNavigation()
    }

    private func routeToProfilesForSave() {
        pendingSettingsSection = nil
        pendingReturnToCommandCentre = false
        selectedSection = .profiles
        MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("Settings routed to Profiles for unsaved changes"))
    }

    private func clearPendingProfileNavigation() {
        pendingSettingsSection = nil
        pendingReturnToCommandCentre = false
    }

    private func continuePendingProfileNavigation() {
        if pendingReturnToCommandCentre {
            pendingReturnToCommandCentre = false
            pendingSettingsSection = nil
            onReturnToCommandCentre()
            return
        }
        if let pendingSettingsSection {
            selectedSection = pendingSettingsSection
            self.pendingSettingsSection = nil
            MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("Settings section: \(selectedSection.title)"))
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text("SETTINGS")
                    .font(.caption.weight(.heavy))
                    .tracking(1.6)
                    .foregroundStyle(.white.opacity(0.56))

                Text("Broadcast Setup")
                    .font(RinkLensDesignSystem.font(.screenTitle))
                    .foregroundStyle(RinkLensDesignSystem.primaryText)

                Text("Teams, logos, saved profiles, scorebug style and goal / penalty popups live here. Cameras, video quality and streaming controls are on the Production Setup home tile.")
                    .font(RinkLensDesignSystem.font(.body))
                    .foregroundStyle(RinkLensDesignSystem.secondaryText)

                Text(RinkLensBuildInfo.buildDisplayLine)
                    .font(RinkLensDesignSystem.font(.monoCaption))
                    .foregroundStyle(RinkLensDesignSystem.mutedText)
            }

            Spacer()
        }
    }

    private var visibleSettingsSections: [SettingsSection] {
        SettingsSection.allCases.filter { section in
            RinkLensRiskFeaturePolicy.isEnabled(.squadSettingsTabV21) || section != .squad
        }
    }

    private var sectionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(visibleSettingsSections) { section in
                    Button {
                        handleSettingsSectionSelection(section)
                    } label: {
                        Text(section.title)
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .frame(minWidth: 118)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(section == selectedSection ? .black : .white.opacity(0.72))
                    .background(section == selectedSection ? Color.white : Color.white.opacity(0.08))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
                }
            }
            .padding(6)
        }
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }

    private var teamsAndLogosSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            scoreboardPreviewCard

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16)], spacing: 16) {
                SettingsCard(title: "Team Names", subtitle: "Used by scorebug, recording filenames, clips and event popups.", systemImage: "person.2.fill") {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Home team", text: teamNameBinding(home: true))
                            .textInputAutocapitalization(.characters)
                            .focused($focusedSettingsField, equals: .homeTeam)
                            .submitLabel(.next)
                            .onSubmit { focusedSettingsField = .awayTeam }
                            .simultaneousGesture(TapGesture().onEnded { focusedSettingsField = .homeTeam })
                            .settingsTextFieldStyle()

                        TextField("Away / guest team", text: teamNameBinding(home: false))
                            .textInputAutocapitalization(.characters)
                            .focused($focusedSettingsField, equals: .awayTeam)
                            .submitLabel(.done)
                            .onSubmit { focusedSettingsField = nil }
                            .simultaneousGesture(TapGesture().onEnded { focusedSettingsField = .awayTeam })
                            .settingsTextFieldStyle()

                        Button(role: .destructive) {
                            viewModel.resetTeamsAndLogos()
                            resetTransientLogoPickerSelections()
                            refreshProfileUI()
                            markProfileBoundChange(reason: "teams and logos reset")
                            MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("teams reset"))
                        } label: {
                            Label("Reset teams and logos", systemImage: "arrow.counterclockwise")
                                .font(.subheadline.weight(.bold))
                        }
                        .buttonStyle(.bordered)
                    }
                }

                logoUploadCard(title: "Home Logo", image: viewModel.homeLogoImage, picker: $selectedHomeLogoItem) {
                    selectedHomeLogoItem = nil
                    homeLogoSelectionRevision &+= 1
                    viewModel.setHomeLogo(data: nil)
                    refreshProfileUI()
                    markProfileBoundChange(reason: "home logo removed")
                }

                logoUploadCard(title: "Away / Guest Logo", image: viewModel.awayLogoImage, picker: $selectedAwayLogoItem) {
                    selectedAwayLogoItem = nil
                    awayLogoSelectionRevision &+= 1
                    viewModel.setAwayLogo(data: nil)
                    refreshProfileUI()
                    markProfileBoundChange(reason: "away logo removed")
                }
            }
        }
    }


    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(
                title: "Central App Appearance",
                subtitle: "One style source for menus, settings, diagnostics and operator screens. Broadcast output still follows the COMPOSITE standard.",
                systemImage: "paintpalette.fill"
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Look preset", selection: Binding(
                        get: { appearanceSettings.preset },
                        set: { newPreset in
                            appearanceSettings.applyPreset(newPreset)
                            MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("appearance preset changed: \(newPreset.title)"))
                        }
                    )) {
                        ForEach(RinkLensLookPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(appearanceSettings.preset.subtitle)
                        .font(RinkLensDesignSystem.font(.caption))
                        .foregroundStyle(RinkLensDesignSystem.secondaryText)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                        appearanceColourPicker("Accent", selection: Binding(
                            get: { appearanceSettings.accentColor },
                            set: { appearanceSettings.setAccentColor($0) }
                        ))
                        appearanceColourPicker("Background", selection: Binding(
                            get: { appearanceSettings.backgroundColor },
                            set: { appearanceSettings.setBackgroundColor($0) }
                        ))
                        appearanceColourPicker("Panel", selection: Binding(
                            get: { appearanceSettings.panelColor },
                            set: { appearanceSettings.setPanelColor($0) }
                        ))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Font scale")
                                .font(RinkLensDesignSystem.font(.bodyStrong))
                            Spacer()
                            Text(String(format: "%.0f%%", appearanceSettings.fontScale * 100))
                                .font(RinkLensDesignSystem.font(.monoCaption))
                                .foregroundStyle(RinkLensDesignSystem.secondaryText)
                        }
                        Slider(value: $appearanceSettings.fontScale, in: 0.88...1.20, step: 0.02)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Corner radius")
                                .font(RinkLensDesignSystem.font(.bodyStrong))
                            Spacer()
                            Text("\(Int(appearanceSettings.cornerRadius))")
                                .font(RinkLensDesignSystem.font(.monoCaption))
                                .foregroundStyle(RinkLensDesignSystem.secondaryText)
                        }
                        Slider(value: $appearanceSettings.cornerRadius, in: 10...30, step: 1)
                    }

                    Toggle("High contrast text", isOn: $appearanceSettings.highContrastText)
                        .settingsToggleStyle()

                    HStack(spacing: 10) {
                        Button {
                            appearanceSettings.resetToDefault()
                            MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("appearance reset to default"))
                        } label: {
                            Label("Reset appearance", systemImage: "arrow.counterclockwise")
                                .font(RinkLensDesignSystem.font(.bodyStrong))
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Text(appearanceSettings.summaryText)
                            .font(RinkLensDesignSystem.font(.caption))
                            .foregroundStyle(RinkLensDesignSystem.mutedText)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }

            SettingsCard(title: "Style Coverage", subtitle: "STYLE1 introduces the shared template and applies it to Settings chrome first. Other screens can now be migrated without inventing new fonts or colours.", systemImage: "checklist.checked") {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsInfoRow(label: "Template", value: "RinkLensDesignSystem")
                    SettingsInfoRow(label: "Settings", value: "Central Appearance controls")
                    SettingsInfoRow(label: "Broadcast output", value: "COMPOSITE standard preserved")
                    SettingsInfoRow(label: "Next migration", value: "Command Centre, Media, Sponsors, Diagnostics")
                }
            }
        }
    }

    private var scorebugSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            scoreboardPreviewCard

            LazyVGrid(columns: [GridItem(.flexible(minimum: 320), spacing: 16), GridItem(.flexible(minimum: 360), spacing: 16)], alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    layoutCard
                    textCard
                    resetScorebugCard
                }

                coloursCard
            }
        }
    }

    private var resetScorebugCard: some View {
        SettingsCard(title: "Reset", subtitle: "", systemImage: "arrow.counterclockwise") {
            Button(role: .destructive) {
                scoreboardSettings.resetToDefault()
                markProfileBoundChange(reason: "scorebug reset")
                MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("scoreboard appearance reset"))
            } label: {
                Label("Reset scorebug appearance", systemImage: "arrow.counterclockwise")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private var eventPopupsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "Event Popups", subtitle: "Goal and penalty lower-third popups shown over live Broadcast and recordings.", systemImage: "rectangle.bottomthird.inset.filled") {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Show goal popups", isOn: Binding(get: { popupSettings.goalPopupsEnabled }, set: { popupSettings.goalPopupsEnabled = $0 }))
                        .settingsToggleStyle()
                    Toggle("Show penalty / power-play popups", isOn: Binding(get: { popupSettings.penaltyPopupsEnabled }, set: { popupSettings.penaltyPopupsEnabled = $0 }))
                        .settingsToggleStyle()
                    Toggle("Use logos on goal popups", isOn: Binding(get: { popupSettings.goalTeamLogosEnabled }, set: { popupSettings.goalTeamLogosEnabled = $0 }))
                        .settingsToggleStyle()
                        .disabled(!popupSettings.goalPopupsEnabled)
                        .opacity(popupSettings.goalPopupsEnabled ? 1.0 : 0.45)
                    Toggle("Use penalised team logo on penalty popups", isOn: Binding(get: { popupSettings.penaltyTeamLogosEnabled }, set: { popupSettings.penaltyTeamLogosEnabled = $0 }))
                        .settingsToggleStyle()
                        .disabled(!popupSettings.penaltyPopupsEnabled)
                        .opacity(popupSettings.penaltyPopupsEnabled ? 1.0 : 0.45)
                    Toggle("Use actual team names from Broadcast Setup", isOn: Binding(get: { popupSettings.useActualTeamNames }, set: { popupSettings.useActualTeamNames = $0 }))
                        .settingsToggleStyle()

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Popup duration")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(Int(popupSettings.popupDurationSeconds))s")
                                .font(.caption.monospacedDigit().weight(.heavy))
                                .foregroundStyle(.white.opacity(0.72))
                        }
                        Slider(value: Binding(get: { popupSettings.popupDurationSeconds }, set: { popupSettings.popupDurationSeconds = $0 }), in: 2...12, step: 1)
                    }

                    Divider().overlay(Color.white.opacity(0.14))

                    Text("Test popups")
                        .font(.caption.weight(.heavy))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.58))

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        popupTestButton("Home Goal", icon: "hockey.puck.fill") {
                            showSettingsPopupPreview(type: .goal, team: .home)
                        }
                        .disabled(!popupSettings.goalPopupsEnabled)
                        .opacity(popupSettings.goalPopupsEnabled ? 1.0 : 0.45)

                        popupTestButton("Away Goal", icon: "hockey.puck.fill") {
                            showSettingsPopupPreview(type: .goal, team: .away)
                        }
                        .disabled(!popupSettings.goalPopupsEnabled)
                        .opacity(popupSettings.goalPopupsEnabled ? 1.0 : 0.45)

                        popupTestButton("Home Penalty", icon: "exclamationmark.triangle.fill") {
                            showSettingsPopupPreview(type: .penalty, team: .home)
                        }
                        .disabled(!popupSettings.penaltyPopupsEnabled)
                        .opacity(popupSettings.penaltyPopupsEnabled ? 1.0 : 0.45)

                        popupTestButton("Away Penalty", icon: "exclamationmark.triangle.fill") {
                            showSettingsPopupPreview(type: .penalty, team: .away)
                        }
                        .disabled(!popupSettings.penaltyPopupsEnabled)
                        .opacity(popupSettings.penaltyPopupsEnabled ? 1.0 : 0.45)
                    }

                    Button(role: .destructive) {
                        popupSettings.resetToDefaults()
                        settingsPreviewPopup = nil
                        MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("event popup settings reset"))
                    } label: {
                        Label("Reset popup defaults", systemImage: "arrow.counterclockwise")
                            .font(.subheadline.weight(.bold))
                    }
                    .buttonStyle(.bordered)
                }
            }

            SettingsCard(title: "Inline Popup Preview", subtitle: "Uses the same Broadcast/recording compositor, but no full-screen Settings preview is shown.", systemImage: "play.rectangle.fill") {
                VStack(alignment: .leading, spacing: 14) {
                    if let event = settingsPreviewPopup {
                        BroadcastCanonicalOverlayPreview(
                            viewerScoreboard: .acceptedOnly(state: previewState),
                            homeLogo: popupSettings.teamLogosEnabled(for: event.type) ? viewModel.homeLogoImage : nil,
                            awayLogo: popupSettings.teamLogosEnabled(for: event.type) ? viewModel.awayLogoImage : nil,
                            modeStatusText: "Preview",
                            banner: event,
                            sponsorConfiguration: sponsorStore.configuration,
                            layout: cachedScoreboardPreviewLayout
                        )
                        .frame(maxWidth: 680)
                        .frame(maxWidth: .infinity, alignment: .center)

                        Text("Preview is inline only. The test buttons no longer enqueue a full-screen Broadcast overlay from Settings.")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.64))
                    } else {
                        Text("Use the test buttons above to show a compact inline preview. Disabled popup types stay greyed out and will not show during Broadcast.")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.white.opacity(0.68))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func showSettingsPopupPreview(type: BroadcastEventType, team: Team?) {
        guard !recordingPresentationWorkSuspended else {
            viewModel.statusMessage = "Settings popup preview is paused while recording. The live recording overlay is unchanged."
            return
        }
        guard popupSettings.isEnabled(for: type) else {
            viewModel.statusMessage = "Popup disabled for \(type.title.lowercased()). Enable it first."
            return
        }

        let nextHome = max(viewModel.state.homeScore ?? viewModel.overrideHomeScore, viewModel.overrideHomeScore)
        let nextAway = max(viewModel.state.awayScore ?? viewModel.overrideAwayScore, viewModel.overrideAwayScore)
        let event = BroadcastEvent(
            type: type,
            team: team,
            period: viewModel.state.period ?? viewModel.overridePeriod,
            gameClock: viewModel.state.clock ?? "12:34",
            homeScoreAfter: team == .home && type != .penalty ? nextHome + 1 : nextHome,
            awayScoreAfter: team == .away && type != .penalty ? nextAway + 1 : nextAway,
            strengthState: type == .penalty ? previewStrengthState(for: team) : viewModel.currentStrengthState,
            source: .manual,
            operatorConfirmed: true,
            penaltyClockSnapshot: type == .penalty ? [PenaltyClock(team: team ?? .away, slot: 1, playerNumber: 12, rawClock: "2:00", remainingSeconds: 120)] : []
        )

        settingsPreviewDismissTask?.cancel()
        settingsPreviewPopup = event
        MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("settings inline popup preview shown: \(type.title)"))

        let duration = min(max(popupSettings.popupDurationSeconds, 2.0), 12.0)
        settingsPreviewDismissTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            await MainActor.run {
                if settingsPreviewPopup?.id == event.id {
                    settingsPreviewPopup = nil
                }
            }
        }
    }

    private func handleEventPopupToggleChanged(enabled: Bool, affectedType: BroadcastEventType, reason: String) {
        if !enabled, settingsPreviewPopup?.type == affectedType {
            settingsPreviewPopup = nil
        }
        refreshInlineEventPopupPreview(reason: reason)
    }

    private func refreshInlineEventPopupPreview(reason: String) {
        MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("event popup setting changed: \(reason)"))
    }

    private func previewStrengthState(for penalisedTeam: Team?) -> StrengthState {
        switch penalisedTeam {
        case .home:
            return .awayPowerPlay(seconds: 120, advantage: "5-on-4")
        case .away:
            return .homePowerPlay(seconds: 120, advantage: "5-on-4")
        case .none:
            return .unknown
        }
    }

    private var profilesSection: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 16)], spacing: 16) {
            SettingsCard(title: "Save Current Broadcast Profile", subtitle: "Saves team names, logos and scorebug look together.", systemImage: "square.and.arrow.down.fill") {
                VStack(alignment: .leading, spacing: 12) {
                    activeProfileBadge

                    TextField("Profile name", text: $profileName)
                        .focused($focusedSettingsField, equals: .profileName)
                        .submitLabel(.done)
                        .onSubmit { focusedSettingsField = nil }
                        .simultaneousGesture(TapGesture().onEnded { focusedSettingsField = .profileName })
                        .settingsTextFieldStyle()

                    Button {
                        viewModel.saveCurrentTeamIdentityTemplate(named: profileName)
                        refreshProfileUI()
                        hasUnsavedProfileChanges = false
                        focusedSettingsField = nil
                        resetTransientLogoPickerSelections()
                        profileName = viewModel.teamIdentityTemplates
                            .first(where: { $0.id == viewModel.selectedTeamIdentityTemplateID })?.name
                            ?? profileName
                        MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("broadcast profile saved"))
                    } label: {
                        Label("Save profile", systemImage: "square.and.arrow.down")
                            .font(.headline.weight(.bold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        viewModel.updateActiveTeamIdentityTemplateWithCurrentScoreboardStyle(title: profileName)
                        refreshProfileUI()
                        hasUnsavedProfileChanges = false
                        profileName = viewModel.teamIdentityTemplates
                            .first(where: { $0.id == viewModel.selectedTeamIdentityTemplateID })?.name
                            ?? profileName
                        MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("active broadcast profile updated"))
                    } label: {
                        Label("Save active profile", systemImage: "square.and.arrow.down")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.selectedTeamIdentityTemplateID == nil)
                }
            }

            SettingsCard(title: "Saved Profiles", subtitle: "Tap the row or LOAD to apply. More contains default, duplicate and delete.", systemImage: "rectangle.stack.fill") {
                if viewModel.teamIdentityTemplates.isEmpty {
                    Text("No saved profiles yet. Add team names, logos and scorebug style, then save a profile.")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white.opacity(0.68))
                } else {
                    VStack(spacing: 10) {
                        ForEach(viewModel.teamIdentityTemplates) { template in
                            profileRow(template)
                        }
                    }
                }
            }
        }
        // Explicit profile operations may refresh only the Profiles controls.
        // Build 687 consumed this revision at the type-erased Settings root,
        // replacing the complete ScrollView during unrelated scorebug edits.
        .id(profileUIRevision)
    }

    private var settingsBroadcastPreviewGeometry: (maxWidth: CGFloat, visibleVerticalFraction: CGFloat) {
        if RinkLensRiskFeaturePolicy.isEnabled(.sharedSettingsPreviewGeometryV28) {
            // One preview-size projection for every Broadcast Setup section that
            // displays the canonical Live Broadcast Preview. Screens consume the
            // projection; they do not independently own or reset preview geometry.
            return (maxWidth: 560, visibleVerticalFraction: 0.33)
        }

        // Build 748 rollback: Teams & Logos used a larger full-height preview.
        return selectedSection == .scorebug
            ? (maxWidth: 560, visibleVerticalFraction: 0.33)
            : (maxWidth: 760, visibleVerticalFraction: 1.0)
    }

    @ViewBuilder
    private var scoreboardPreviewCard: some View {
        let previewGeometry = settingsBroadcastPreviewGeometry
        SettingsCard(title: "Live Broadcast Preview", subtitle: "", systemImage: "rectangle.3.group.fill") {
            if recordingPresentationWorkSuspended {
                VStack(spacing: 10) {
                    Image(systemName: "record.circle.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.red)
                    Text("Preview paused while recording")
                        .font(.headline.weight(.bold))
                    Text("Settings remain editable. The live Broadcast and saved recording overlay continue from the authoritative BroadcastOverlayState without building an additional Settings preview.")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.68))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                BroadcastCanonicalOverlayPreview(
                    viewerScoreboard: .acceptedOnly(state: previewState),
                    homeLogo: viewModel.homeLogoImage,
                    awayLogo: viewModel.awayLogoImage,
                    modeStatusText: "Preview",
                    sponsorConfiguration: sponsorStore.configuration,
                    layout: cachedScoreboardPreviewLayout,
                    visibleVerticalFraction: previewGeometry.visibleVerticalFraction
                )
                .frame(maxWidth: previewGeometry.maxWidth)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private var layoutCard: some View {
        SettingsCard(title: "Layout", subtitle: "", systemImage: "rectangle.inset.filled") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Show scoreboard", isOn: $scoreboardSettings.isVisible)
                    .settingsToggleStyle()

                Text("Scorebug position is locked to Top Middle.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.58))

                Picker("Logo position", selection: $scoreboardSettings.logoPosition) {
                    ForEach(BroadcastScoreboardLogoPosition.allCases) { position in
                        Text(position.title).tag(position)
                    }
                }
                .pickerStyle(.segmented)

                Divider().overlay(Color.white.opacity(0.14))

                settingsStepper("Safe margin", value: $scoreboardSettings.safeMargin, range: 12...80, step: 2, suffix: "px")
                settingsStepper("Horizontal offset", value: $scoreboardSettings.horizontalOffset, range: -220...220, step: 4, suffix: "px")
                settingsStepper("Vertical offset", value: $scoreboardSettings.verticalOffset, range: -160...160, step: 4, suffix: "px")
            }
        }
    }

    private var textCard: some View {
        SettingsCard(title: "Text", subtitle: "", systemImage: "textformat.size") {
            VStack(alignment: .leading, spacing: 14) {
                settingsStepper("Team font", value: $scoreboardSettings.teamNameFontSize, range: 20...48, step: 1, suffix: "pt")

                Text("Team font is the master scorebug size: scores, Clock, logos, centre readouts, penalties and spacing follow it.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.58))

                Picker("Weight", selection: $scoreboardSettings.teamNameFontWeight) {
                    ForEach(BroadcastScoreboardFontWeight.allCases) { weight in
                        Text(weight.title).tag(weight)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var coloursCard: some View {
        SettingsCard(title: "Colours", subtitle: "", systemImage: "paintpalette.fill") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Use one shared score colour", isOn: $scoreboardSettings.useSharedScoreColour)
                    .settingsToggleStyle()

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    scorebugColourGroup(title: "Home", systemImage: "house.fill") {
                        settingsColourPicker("Text", selection: $scoreboardSettings.homeTeamNameColour)
                        settingsColourPicker("Pill bg", selection: $scoreboardSettings.homeTeamBackgroundColour)
                        settingsColourPicker("Score", selection: $scoreboardSettings.homeScoreColour)
                            .disabled(scoreboardSettings.useSharedScoreColour)
                            .opacity(scoreboardSettings.useSharedScoreColour ? 0.45 : 1.0)
                        settingsColourPicker("Logo bg", selection: $scoreboardSettings.homeLogoContainerBackground)
                    }

                    scorebugColourGroup(title: "Away", systemImage: "airplane.departure") {
                        settingsColourPicker("Text", selection: $scoreboardSettings.awayTeamNameColour)
                        settingsColourPicker("Pill bg", selection: $scoreboardSettings.awayTeamBackgroundColour)
                        settingsColourPicker("Score", selection: $scoreboardSettings.awayScoreColour)
                            .disabled(scoreboardSettings.useSharedScoreColour)
                            .opacity(scoreboardSettings.useSharedScoreColour ? 0.45 : 1.0)
                        settingsColourPicker("Logo bg", selection: $scoreboardSettings.awayLogoContainerBackground)
                    }
                }

                scorebugColourGroup(title: "Shared", systemImage: "slider.horizontal.3") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        settingsColourPicker("Shared score", selection: $scoreboardSettings.scoreColour)
                            .disabled(!scoreboardSettings.useSharedScoreColour)
                            .opacity(scoreboardSettings.useSharedScoreColour ? 1.0 : 0.45)
                        settingsColourPicker("Clock", selection: $scoreboardSettings.clockColour)
                        settingsColourPicker("Period", selection: $scoreboardSettings.periodColour)
                        settingsColourPicker("Accent", selection: $scoreboardSettings.accentColour)
                        settingsColourPicker("Background", selection: $scoreboardSettings.scoreboardBackgroundColour)
                        settingsColourPicker("Border", selection: $scoreboardSettings.scoreboardBorderColour)
                        settingsColourPicker("Both logo bg", selection: Binding(
                            get: { scoreboardSettings.logoContainerBackground },
                            set: { newValue in
                                scoreboardSettings.logoContainerBackground = newValue
                                scoreboardSettings.homeLogoContainerBackground = newValue
                                scoreboardSettings.awayLogoContainerBackground = newValue
                            }
                        ))
                    }
                }

                logoBackgroundPreviewRow
            }
        }
    }

    private func scorebugColourGroup<Content: View>(title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(RinkLensDesignSystem.font(.bodyStrong))
                .foregroundStyle(RinkLensDesignSystem.primaryText)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RinkLensDesignSystem.controlBackground, in: RoundedRectangle(cornerRadius: RinkLensDesignSystem.controlCornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: RinkLensDesignSystem.controlCornerRadius, style: .continuous).stroke(RinkLensDesignSystem.border, lineWidth: 1))
    }

    @ViewBuilder
    private var profileSaveBanner: some View {
        if selectedSection.isProfileBound && hasUnsavedProfileChanges && focusedSettingsField == nil {
            HStack(spacing: 12) {
                Image(systemName: viewModel.selectedTeamIdentityTemplateID == nil ? "exclamationmark.triangle.fill" : "square.and.arrow.down.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(viewModel.selectedTeamIdentityTemplateID == nil ? .yellow : .green)

                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.selectedTeamIdentityTemplateID == nil ? "Changes are not linked to a profile" : "Unsaved profile changes")
                        .font(RinkLensDesignSystem.font(.bodyStrong))
                        .foregroundStyle(RinkLensDesignSystem.primaryText)
                    Text(viewModel.selectedTeamIdentityTemplateID == nil ? "Go to Profiles to create or load a profile before saving." : "Save Teams & Logos / Scorebug changes to the active profile before leaving.")
                        .font(RinkLensDesignSystem.font(.caption))
                        .foregroundStyle(RinkLensDesignSystem.secondaryText)
                }

                Spacer(minLength: 12)

                if viewModel.selectedTeamIdentityTemplateID == nil {
                    Button {
                        routeToProfilesForSave()
                    } label: {
                        Label("Go to Profiles", systemImage: "rectangle.stack.fill")
                            .font(RinkLensDesignSystem.font(.bodyStrong))
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        saveActiveProfileAndContinue()
                    } label: {
                        Label("Save to active profile", systemImage: "square.and.arrow.down")
                            .font(RinkLensDesignSystem.font(.bodyStrong))
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(14)
            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: RinkLensDesignSystem.cardCornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: RinkLensDesignSystem.cardCornerRadius, style: .continuous).stroke(RinkLensDesignSystem.border, lineWidth: 1))
        }
    }

    private var logoBackgroundPreviewRow: some View {
        HStack(spacing: 12) {
            logoBackgroundSample(title: "Home logo bg", image: viewModel.homeLogoImage, background: scoreboardSettings.homeLogoContainerBackground, accent: BroadcastTheme.homeAccent)
            logoBackgroundSample(title: "Away logo bg", image: viewModel.awayLogoImage, background: scoreboardSettings.awayLogoContainerBackground, accent: BroadcastTheme.awayAccent)
        }
    }

    private func logoBackgroundSample(title: String, image: UIImage?, background: Color, accent: Color) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(background)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(accent.opacity(0.72), lineWidth: 1))
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(6)
                } else {
                    Image(systemName: "shield.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(accent)
                }
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(RinkLensDesignSystem.font(.caption))
                    .foregroundStyle(RinkLensDesignSystem.primaryText)
                Text("Preview uses this colour in Settings, Broadcast and recording.")
                    .font(RinkLensDesignSystem.font(.caption))
                    .foregroundStyle(RinkLensDesignSystem.mutedText)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RinkLensDesignSystem.controlBackground, in: RoundedRectangle(cornerRadius: RinkLensDesignSystem.controlCornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: RinkLensDesignSystem.controlCornerRadius, style: .continuous).stroke(RinkLensDesignSystem.border, lineWidth: 1))
    }

    private var squadSection: some View {
        SquadSettingsEmbeddedView()
    }

    private var sponsorsSection: some View {
        SponsorsSettingsEmbeddedView()
    }

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "System", subtitle: "Build and operating information.", systemImage: "gearshape.2.fill") {
                VStack(alignment: .leading, spacing: 10) {
                    SettingsInfoRow(label: "Version", value: RinkLensBuildInfo.version)
                    SettingsInfoRow(label: "Build", value: "\(RinkLensBuildInfo.buildNumber)")
                    SettingsInfoRow(label: "Build date", value: RinkLensBuildInfo.buildDateTime)
                    SettingsInfoRow(label: "Broadcast mode", value: "NextGen operational")
                    SettingsInfoRow(label: "Profiles", value: "Team names + logos + scorebug style")
                    SettingsInfoRow(label: "Event popups", value: popupSettings.summaryText)
                    SettingsInfoRow(label: "Recording / stream", value: "Shared physical camera and cadence; separate encoders, bitrate, codec and destination")
                }
            }

            SettingsCard(title: "Storage & Reset", subtitle: "Explicit operator actions only. Nothing is deleted automatically.", systemImage: "externaldrive.badge.xmark") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Clear Local Media & Diagnostics removes sandbox copies and engineering logs but never deletes Photos assets. Reset Configuration is a separate next-launch transaction.")
                        .font(RinkLensDesignSystem.font(.caption))
                        .foregroundStyle(RinkLensDesignSystem.secondaryText)

                    HStack(spacing: 12) {
                        Button(role: .destructive) {
                            showClearSandboxConfirmation = true
                        } label: {
                            Label("Clear Local Media & Logs", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .disabled(storageMaintenanceRunning || (recorder.state != .idle && recorder.state != .failed))

                        Button(role: .destructive) {
                            showResetConfigurationConfirmation = true
                        } label: {
                            Label("Reset Configuration", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.bordered)
                        .disabled(storageMaintenanceRunning)
                    }

                    if storageMaintenanceRunning {
                        ProgressView("Clearing local data…")
                    }
                    Text(storageMaintenanceStatus)
                        .font(RinkLensDesignSystem.font(.caption))
                        .foregroundStyle(RinkLensDesignSystem.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Recovery CJ: quality configuration has one presentation surface in
            // Production Setup. This constant gate prevents an old persisted rollout
            // value from resurrecting the superseded System writer.
            if false {
                SettingsCard(title: "Recording Profile", subtitle: "Choose managed defaults or define the encoded video output before recording starts.", systemImage: "slider.horizontal.3") {
                    if RinkLensRiskFeaturePolicy.isEnabled(.customRecordingOutputProfileV15) {
                        VStack(alignment: .leading, spacing: 14) {
                            Toggle("Use a custom recording profile", isOn: Binding(
                                get: { recorder.customVideoSettingsEnabled },
                                set: { viewModel.setCustomRecordingVideoSettingsEnabled($0) }
                            ))

                            Text(recorder.customVideoSettingsEnabled
                                 ? "RinkLens will encode using the selections below and verify that the Broadcast camera can supply them."
                                 : "Managed profile: 1080p at 30 fps, H.264 and 8 Mbps.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if recorder.customVideoSettingsEnabled {
                                Divider()

                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Video encoder").font(.subheadline.weight(.semibold))
                                    Picker("Video encoder", selection: Binding<BroadcastRecordingProfile.Codec>(
                                        get: { recorder.customVideoCodec },
                                        set: { recorder.setCustomVideoCodec($0, source: "Settings.BroadcastSetup.System", reason: "Operator selected recording encoder") }
                                    )) {
                                        ForEach(recorder.availableCustomVideoCodecs) { codec in
                                            Text(codec.settingsTitle).tag(codec)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    Text(recorder.customVideoCodec.settingsDetail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    if !recorder.supportsHEVCRecording {
                                        Text("HEVC hardware encoding is unavailable, so Compatible (H.264) is used.")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.orange)
                                    }
                                }

                                Divider()

                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Recorded dimensions and cadence").font(.subheadline.weight(.semibold))
                                    Picker("Recorded dimensions and cadence", selection: Binding<BroadcastRecordingProfile.OutputMode>(
                                        get: { recorder.customVideoOutputMode },
                                        set: { viewModel.setCustomRecordingOutputMode($0) }
                                    )) {
                                        ForEach(BroadcastRecordingProfile.OutputMode.allCases) { mode in
                                            let available = viewModel.recordingModeIsAvailable(mode)
                                            Text(available ? mode.rawValue : "\(mode.rawValue) — unavailable")
                                                .tag(mode)
                                                .disabled(!available)
                                        }
                                    }
                                    .pickerStyle(.menu)

                                    Text(recorder.customVideoOutputMode.purposeText)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)

                                    if !viewModel.recordingModeIsAvailable(recorder.customVideoOutputMode) {
                                        Text("The selected Broadcast camera does not currently expose this exact mode. Choose another mode or camera before recording.")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.orange)
                                    }
                                }

                                Divider()

                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("Average bitrate").font(.subheadline.weight(.semibold))
                                        Spacer()
                                        Text("\(recorder.customVideoBitrateMbps) Mbps")
                                            .font(.subheadline.monospacedDigit().weight(.semibold))
                                    }
                                    Slider(value: Binding(
                                        get: { Double(recorder.customVideoBitrateMbps) },
                                        set: { recorder.setCustomVideoBitrateMbps(Int($0.rounded()), source: "Settings.BroadcastSetup.System", reason: "Operator adjusted average recording bitrate") }
                                    ), in: Double(RecordingEngine.minimumCustomVideoBitrateMbps)...Double(RecordingEngine.maximumCustomVideoBitrateMbps), step: 1)
                                    HStack {
                                        Text("Estimated video data: about \(recorder.estimatedRecordingMegabytesPerMinute) MB per minute")
                                        Spacer()
                                        Text("Sports starting point: 8–16 Mbps")
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)

                                    if recorder.customVideoBitrateMbps < recorder.customVideoOutputMode.recommendedMinimumBitrateMbps {
                                        Text("This bitrate is below the suggested starting point of \(recorder.customVideoOutputMode.recommendedMinimumBitrateMbps) Mbps for \(recorder.customVideoOutputMode.compactLabel); fast movement may lose detail.")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }

                            if RinkLensRiskFeaturePolicy.isEnabled(.broadcastVideoStabilisationAuthorityV13) {
                                Divider()
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Broadcast image stabilisation")
                                        .font(.subheadline.weight(.semibold))
                                    Picker("Broadcast image stabilisation", selection: Binding<Bool>(
                                        get: { viewModel.broadcastVideoStabilisationEnabled },
                                        set: {
                                            viewModel.setBroadcastVideoStabilisationEnabled(
                                                $0,
                                                source: "Settings.BroadcastSetup.System",
                                                reason: "Operator changed Broadcast image stabilisation"
                                            )
                                        }
                                    )) {
                                        Text("Off").tag(false)
                                        Text("Automatic").tag(true)
                                    }
                                    .pickerStyle(.segmented)
                                    Text("Applied by the Broadcast camera controller. OCR remains unstabilised so calibrated recognition zones do not move.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            SettingsInfoRow(label: "Active recording output", value: recorder.recordingOutputPolicySummaryText)
                            SettingsInfoRow(label: "Capture source", value: liveCamera.selectedResolutionFPS)

                            Text("High-frame-rate modes increase heat, encoder load and storage use. RinkLens monitors actual cadence and records any frame shortfall in diagnostics.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            if recorder.state != .idle && recorder.state != .failed {
                                Text("End the current recording before changing its output profile.")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.orange)
                            }
                        }
                        .disabled(recorder.state != .idle && recorder.state != .failed)
                        .onAppear {
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 14) {
                            SettingsInfoRow(label: "Recording source", value: "Active Broadcast camera")
                            SettingsInfoRow(label: "Resolution / FPS", value: "Inherited from camera")

                            Picker("Codec", selection: Binding<BroadcastRecordingProfile.Codec>(
                                get: { recorder.recordingProfile.codec },
                                set: { recorder.setRecordingCodec($0) }
                            )) {
                                ForEach(BroadcastRecordingProfile.Codec.allCases) { option in
                                    Text(option.rawValue).tag(option)
                                }
                            }
                            .pickerStyle(.segmented)

                            Picker("Bitrate", selection: Binding<BroadcastRecordingProfile.Bitrate>(
                                get: { recorder.recordingProfile.bitrate },
                                set: { recorder.setRecordingBitrate($0) }
                            )) {
                                ForEach(BroadcastRecordingProfile.Bitrate.allCases) { option in
                                    Text(option.rawValue).tag(option)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                }

                SettingsCard(title: "Camera & Recording", subtitle: "Reference information kept out of live operator controls.", systemImage: "video.badge.ellipsis") {
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsInfoRow(label: "Output", value: "Clean Broadcast frame")
                        SettingsInfoRow(label: "Saved to", value: "App files and Photos")
                        SettingsInfoRow(label: "Validation evidence", value: "Support logs")
                    }
                }
            }
        }
    }

    private func clearOperatorRequestedSandboxData() {
        guard !storageMaintenanceRunning else { return }
        storageMaintenanceRunning = true
        storageMaintenanceStatus = "Clearing local media and diagnostics…"
        Task { @MainActor in
            let media = await recorder.clearOperatorRequestedLocalMedia()
            let exports = await DiagnosticsLogExporter.shared.clearStoredExports()
            let ocrEvidence = await RinkLensOCREvidenceJournal.shared.clearStoredEvidence()
            let structuredEvents = await RinkLensStructuredEventLogger.shared.clearStoredEvents()
            let caches = await clearCachesAndTemporaryFiles()
            let results = [media, exports, ocrEvidence, structuredEvents, caches]
            let files = results.reduce(0) { $0 + $1.files }
            let bytes = results.reduce(Int64(0)) { $0 + $1.bytes }
            let failures = results.compactMap(\.blockedReason)
            let reclaimed = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            storageMaintenanceStatus = failures.isEmpty
                ? "Cleared \(files) local file(s), reclaiming \(reclaimed). Photos and configuration were unchanged."
                : "Cleared \(files) local file(s), reclaiming \(reclaimed). Retained items: \(failures.joined(separator: " "))"
            storageMaintenanceRunning = false
            recorder.refreshSavedMediaCounts()
            RinkLensStructuredEventLogger.shared.record(
                domain: .recording,
                event: "operator_sandbox_storage_cleared",
                entityID: "RinkLens sandbox",
                previous: ["requested": "local media, diagnostics, caches and tmp"],
                next: ["files": String(files), "bytes": String(bytes), "photos": "unchanged"],
                source: "SettingsView",
                reason: "Explicit confirmed operator storage action",
                authoritativeOwner: "Respective file owners coordinated by Settings"
            )
        }
    }

    private func clearCachesAndTemporaryFiles() async -> RinkLensStorageClearResult {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let roots = [
                fm.urls(for: .cachesDirectory, in: .userDomainMask).first,
                URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            ].compactMap { $0 }
            var files = 0
            var bytes: Int64 = 0
            var failure: String?
            for root in roots {
                let urls = (try? fm.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.fileSizeKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                for url in urls {
                    let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    do {
                        try fm.removeItem(at: url)
                        files += 1
                        bytes += size
                    } catch {
                        failure = error.localizedDescription
                    }
                }
            }
            return .init(files: files, bytes: bytes, blockedReason: failure)
        }.value
    }

    private var previewState: ScoreboardState {
        ScoreboardState(
            homeTeam: viewModel.homeTeamName.isEmpty ? "HOME" : viewModel.homeTeamName,
            awayTeam: viewModel.awayTeamName.isEmpty ? "GUEST" : viewModel.awayTeamName,
            homeScore: viewModel.state.homeScore ?? viewModel.overrideHomeScore,
            awayScore: viewModel.state.awayScore ?? viewModel.overrideAwayScore,
            clock: viewModel.state.clock ?? "12:34",
            period: viewModel.state.period ?? 2,
            periodLabel: viewModel.state.periodLabel,
            homeShots: viewModel.state.homeShots,
            awayShots: viewModel.state.awayShots
        )
    }

    private var sampleGoalEvent: BroadcastEvent {
        BroadcastEvent(type: .goal, team: .home, period: viewModel.state.period ?? 2, gameClock: viewModel.state.clock ?? "12:34", homeScoreAfter: 3, awayScoreAfter: 2, strengthState: .evenStrength, source: .manual, operatorConfirmed: true)
    }

    private var samplePenaltyEvent: BroadcastEvent {
        let penaltyClock = PenaltyClock(team: .away, slot: 1, playerNumber: 12, rawClock: "2:00", remainingSeconds: 120)
        return BroadcastEvent(type: .penalty, team: .away, period: viewModel.state.period ?? 2, gameClock: viewModel.state.clock ?? "10:11", homeScoreAfter: 3, awayScoreAfter: 2, strengthState: .homePowerPlay(seconds: 120, advantage: "5-on-4"), source: .manual, operatorConfirmed: true, penaltyClockSnapshot: [penaltyClock])
    }

    private var previewScale: CGFloat {
        let masterScale = BroadcastScorebugTemplateMetrics.primaryContentScale(for: scoreboardSettings.snapshot)
        return min(0.82, max(0.56, 0.78 / max(0.65, masterScale)))
    }

    private var activeProfileBadge: some View {
        let active = viewModel.teamIdentityTemplates.first(where: { $0.id == viewModel.selectedTeamIdentityTemplateID })
        let isDefault = active?.id == viewModel.defaultTeamIdentityTemplateID
        return HStack(spacing: 8) {
            Circle()
                .fill(active == nil ? Color.white.opacity(0.28) : Color.green.opacity(0.85))
                .frame(width: 9, height: 9)
            Text(active?.name ?? "No active profile")
                .font(.caption.weight(.heavy))
                .lineLimit(1)
            if isDefault {
                Text("DEFAULT")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(.yellow)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.10), in: Capsule(style: .continuous))
    }

    private func profileRow(_ template: TeamIdentityTemplate) -> some View {
        let isActive = viewModel.selectedTeamIdentityTemplateID == template.id
        let isDefault = viewModel.defaultTeamIdentityTemplateID == template.id

        return VStack(alignment: .leading, spacing: 10) {
            Button {
                guard !(isActive && !hasUnsavedProfileChanges) else { return }
                focusedSettingsField = nil
                resetTransientLogoPickerSelections()
                viewModel.applyTeamIdentityTemplate(template)
                profileName = template.name
                refreshProfileUI()
                hasUnsavedProfileChanges = false
                MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("broadcast profile loaded"))
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(template.name)
                            .font(.subheadline.weight(.heavy))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        profileStatusBadges(isActive: isActive, isDefault: isDefault)
                    }
                    Text("\(template.homeTeamName) vs \(template.awayTeamName)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.66))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                Text(template.scoreboardSettings == nil ? "Teams + logos" : "Teams + logos + scorebug look")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(template.scoreboardSettings == nil ? .white.opacity(0.52) : .cyan.opacity(0.86))
                    .lineLimit(1)

                Spacer(minLength: 8)

                // Loading must remain visible even in the narrow Settings column.
                Button {
                    guard !(isActive && !hasUnsavedProfileChanges) else { return }
                    focusedSettingsField = nil
                    resetTransientLogoPickerSelections()
                    viewModel.applyTeamIdentityTemplate(template)
                    profileName = template.name
                    refreshProfileUI()
                    hasUnsavedProfileChanges = false
                    MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("saved profile loaded from visible row action"))
                } label: {
                    Text(isActive && !hasUnsavedProfileChanges ? "LOADED" : "LOAD")
                        .font(.caption2.weight(.black))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isActive && !hasUnsavedProfileChanges)

                Menu {
                Button {
                    viewModel.setDefaultTeamIdentityTemplate(template)
                } label: {
                    Label(isDefault ? "Default Profile" : "Set Default", systemImage: "star.fill")
                }

                Button {
                    duplicateTeamTemplate = template
                    duplicateTeamTemplateName = "\(template.name) Copy"
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }

                Divider()

                Button(role: .destructive) {
                    deleteTeamTemplate = template
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white.opacity(0.82))
                        .frame(width: 38, height: 38)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("More actions for \(template.name)")
            }
        }
        .padding(12)
        .background(Color.white.opacity(isActive ? 0.15 : 0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(isActive ? Color.green.opacity(0.72) : Color.white.opacity(0.12), lineWidth: 1))
    }

    @ViewBuilder
    private func profileStatusBadges(isActive: Bool, isDefault: Bool) -> some View {
        if isActive || isDefault {
            HStack(spacing: 5) {
                if isActive {
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                if isDefault {
                    Label("Default", systemImage: "star.fill")
                        .foregroundStyle(.yellow)
                }
            }
            .font(.caption2.weight(.black))
            .labelStyle(.iconOnly)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.22), in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                isActive && isDefault ? "Active and default profile" : (isActive ? "Active profile" : "Default profile")
            )
        }
    }

    private func logoUploadCard(title: String, image: UIImage?, picker: Binding<PhotosPickerItem?>, remove: @escaping () -> Void) -> some View {
        SettingsCard(title: title, subtitle: "Add or remove logo used by scorebug and event popups.", systemImage: "photo.on.rectangle") {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.black.opacity(0.22))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))

                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(14)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "photo")
                                .font(.system(size: 34, weight: .bold))
                            Text("No logo selected")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.white.opacity(0.60))
                    }
                }
                .frame(height: 150)

                HStack(spacing: 10) {
                    PhotosPicker(selection: picker, matching: .images) {
                        Label("Upload", systemImage: "photo.on.rectangle")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(role: .destructive) {
                        remove()
                    } label: {
                        Label("Remove", systemImage: "xmark.circle")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(image == nil)
                }
            }
        }
    }

    private func popupTestButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
    }

    private func settingsStepper(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, step: CGFloat, suffix: String) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text("\(Int(value.wrappedValue))\(suffix)")
                    .font(.caption.monospacedDigit().weight(.heavy))
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
    }

    private func settingsColourPicker(_ title: String, selection: Binding<Color>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.76))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Spacer(minLength: 4)
            ColorPicker(title, selection: selection, supportsOpacity: true)
                .labelsHidden()
                .frame(width: 32, height: 28)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}


private func appearanceColourPicker(_ title: String, selection: Binding<Color>) -> some View {
    HStack(spacing: 12) {
        Text(title)
            .font(RinkLensDesignSystem.font(.bodyStrong))
            .foregroundStyle(RinkLensDesignSystem.primaryText)
        Spacer()
        ColorPicker(title, selection: selection, supportsOpacity: true)
            .labelsHidden()
            .frame(width: 36, height: 32)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(RinkLensDesignSystem.controlBackground, in: RoundedRectangle(cornerRadius: RinkLensDesignSystem.controlCornerRadius, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: RinkLensDesignSystem.controlCornerRadius, style: .continuous).stroke(RinkLensDesignSystem.border, lineWidth: 1))
}

private struct SettingsBackground: View {
    @ObservedObject private var appearance = RinkLensAppearanceSettings.shared

    var body: some View {
        RinkLensDesignSystem.screenBackground
            .ignoresSafeArea()
            .overlay(
                RinkLensDesignSystem.accentGlow
                    .ignoresSafeArea()
            )
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(RinkLensDesignSystem.font(.cardTitle))
                        .foregroundStyle(RinkLensDesignSystem.primaryText)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(RinkLensDesignSystem.font(.caption))
                            .foregroundStyle(RinkLensDesignSystem.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .background(RinkLensDesignSystem.cardBackground, in: RoundedRectangle(cornerRadius: RinkLensDesignSystem.cardCornerRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: RinkLensDesignSystem.cardCornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: RinkLensDesignSystem.cardCornerRadius, style: .continuous).stroke(RinkLensDesignSystem.border, lineWidth: 1))
    }
}

private struct SettingsInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(RinkLensDesignSystem.font(.caption))
                .foregroundStyle(RinkLensDesignSystem.mutedText)
            Spacer(minLength: 14)
            Text(value)
                .font(RinkLensDesignSystem.font(.monoCaption))
                .foregroundStyle(RinkLensDesignSystem.secondaryText)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
    }
}

private extension View {
    func settingsToggleStyle() -> some View {
        self
            .font(RinkLensDesignSystem.font(.bodyStrong))
            .foregroundStyle(RinkLensDesignSystem.primaryText.opacity(0.90))
    }

    func settingsTextFieldStyle() -> some View {
        self
            .textFieldStyle(.plain)
            .font(RinkLensDesignSystem.font(.bodyStrong))
            .foregroundStyle(RinkLensDesignSystem.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RinkLensDesignSystem.controlBackground, in: RoundedRectangle(cornerRadius: RinkLensDesignSystem.controlCornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: RinkLensDesignSystem.controlCornerRadius, style: .continuous).stroke(RinkLensDesignSystem.border, lineWidth: 1))
    }
}

#endif
