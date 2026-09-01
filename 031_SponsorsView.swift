// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI

// STYLE2 central design system migration: operator chrome/fonts use RinkLensDesignSystem where safe.
#if canImport(PhotosUI)
import PhotosUI
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - RinkLens Sponsor Catalogue + Placement Rules

/// Dedicated sponsor workspace.
///
/// S12A turns the earlier sponsor shell into a reusable catalogue and placement
/// model. Sponsors are created once, then associated to one or more commercial
/// broadcast moments such as season sponsor, game sponsor, goal popups,
/// player-specific home penalties, away penalties, final score and intermission
/// sponsor reels. This patch is setup/data focused and does not change camera,
/// OCR, recording, renderer or clip-buffer behaviour.
struct SponsorsRouteShellView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var runtimeStatus: AppRuntimeStatus

    @StateObject private var sponsorStore = SponsorCatalogueStore.shared

    @State private var selectedSection: SponsorSetupSection = .catalogue
    @State private var selectedSponsorID: UUID?
    @State private var selectedLeagueLogoItem: PhotosPickerItem?
    @State private var selectedSponsorLogoItem: PhotosPickerItem?
    @State private var rosterImportText = ""

    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 14)]
    let embeddedInSettings: Bool

    init(embeddedInSettings: Bool = false) {
        self.embeddedInSettings = embeddedInSettings
    }

    @ViewBuilder
    var body: some View {
        if embeddedInSettings {
            embeddedContent
                .onAppear(perform: handleAppear)
                .onChange(of: selectedLeagueLogoItem) { _, item in handleLeagueLogoItem(item) }
                .onChange(of: selectedSponsorLogoItem) { _, item in handleSponsorLogoItem(item) }
        } else {
            ZStack {
                BroadcastMenuBackgroundView()

                ScrollView {
                    embeddedContent
                        .rinkLensHeavyScreenContent(maxWidth: 1160, horizontal: 24, vertical: 22)
                }
                .rinkLensScrollPerformance("Sponsors")
            }
            .broadcastMenuText()
            .rinkLensOperatorChrome("Sponsors")
            .onAppear(perform: handleAppear)
            .onChange(of: selectedLeagueLogoItem) { _, item in handleLeagueLogoItem(item) }
            .onChange(of: selectedSponsorLogoItem) { _, item in handleSponsorLogoItem(item) }
        }
    }

    private var embeddedContent: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            header
            overviewStrip
            sectionPicker
            activeSection
        }
        .frame(maxWidth: 1160, alignment: .center)
        .frame(maxWidth: .infinity)
    }

    private func handleAppear() {
        runtimeStatus.markSponsorsModuleVisible()
        if selectedSponsorID == nil {
            selectedSponsorID = sponsorStore.configuration.sponsors.first?.id
        }
        if RinkLensRiskFeaturePolicy.isEnabled(.squadSettingsTabV21), selectedSection == .squad {
            selectedSection = .catalogue
        }
        sponsorStore.prewarmImageCache(
            source: "SponsorsRouteShellView",
            reason: "Sponsors workspace appeared"
        )
        MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("Sponsors module appeared"))
    }

    private func handleLeagueLogoItem(_ item: PhotosPickerItem?) {
        Task {
            let data = try? await item?.loadTransferable(type: Data.self)
            await MainActor.run {
                sponsorStore.setLeagueLogo(data: data ?? nil)
                MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("league sponsor graphic updated"))
            }
        }
    }

    private func handleSponsorLogoItem(_ item: PhotosPickerItem?) {
        guard let selectedSponsorID else { return }
        Task {
            let data = try? await item?.loadTransferable(type: Data.self)
            await MainActor.run {
                sponsorStore.setSponsorLogo(id: selectedSponsorID, data: data ?? nil)
                MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("sponsor catalogue logo updated"))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            if !embeddedInSettings {
                Button {
                    MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("route change requested: Sponsors -> Command Centre"))
                    coordinator.navigate(to: .commandCentre)
                } label: {
                    Label("Command Centre", systemImage: "chevron.left")
                        .font(RinkLensDesignSystem.font(.caption))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                }
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
            }

            if embeddedInSettings {
                Image(systemName: "star.circle.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Sponsors")
                    .font(embeddedInSettings ? RinkLensDesignSystem.font(.cardTitle) : RinkLensDesignSystem.font(.screenTitle))
                    .foregroundStyle(RinkLensDesignSystem.primaryText)

                Text(RinkLensRiskFeaturePolicy.isEnabled(.squadSettingsTabV21)
                     ? "Catalogue, placements and intermission sponsor reels"
                     : "Catalogue, placements, squad player sponsors and intermission reels")
                    .font(embeddedInSettings ? RinkLensDesignSystem.font(.caption) : RinkLensDesignSystem.font(.bodyStrong))
                    .foregroundStyle(embeddedInSettings ? RinkLensDesignSystem.mutedText : RinkLensDesignSystem.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button {
                sponsorStore.setOutputOverlayEnabled(!sponsorStore.configuration.overlay.isOutputOverlayEnabled)
                MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("sponsor output overlay toggled"))
            } label: {
                Label(
                    sponsorStore.configuration.overlay.isOutputOverlayEnabled ? "Output On" : "Output Off",
                    systemImage: sponsorStore.configuration.overlay.isOutputOverlayEnabled ? "antenna.radiowaves.left.and.right" : "eye.slash.fill"
                )
                .font(RinkLensDesignSystem.font(.caption))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
            .foregroundStyle(sponsorStore.configuration.overlay.isOutputOverlayEnabled ? .black : .white.opacity(0.86))
            .background(sponsorStore.configuration.overlay.isOutputOverlayEnabled ? Color.white : Color.white.opacity(0.10), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))

            HStack(spacing: 8) {
                Circle()
                    .fill(sponsorStore.configuration.placements.assignedCount > 0 ? .green : .orange)
                    .frame(width: 10, height: 10)
                Text("\(sponsorStore.configuration.placements.assignedCount) placements")
                    .font(RinkLensDesignSystem.font(.caption))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
        }
        .padding(embeddedInSettings ? 18 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if embeddedInSettings {
                RoundedRectangle(cornerRadius: RinkLensDesignSystem.cardCornerRadius, style: .continuous)
                    .fill(RinkLensDesignSystem.cardBackground)
            }
        }
        .overlay {
            if embeddedInSettings {
                RoundedRectangle(cornerRadius: RinkLensDesignSystem.cardCornerRadius, style: .continuous)
                    .stroke(RinkLensDesignSystem.border, lineWidth: 1)
            }
        }
    }

    private var overviewStrip: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
            SponsorStatusTile(title: "Catalogue", value: "\(sponsorStore.configuration.sponsors.count) sponsors", icon: "star.fill")
            SponsorStatusTile(title: "League", value: sponsorStore.configuration.league.isEnabled ? sponsorStore.configuration.league.name : "Off", icon: "shield.lefthalf.filled")
            SponsorStatusTile(title: "Placements", value: "\(sponsorStore.configuration.placements.assignedCount) assigned", icon: "rectangle.grid.2x2.fill")
            if !RinkLensRiskFeaturePolicy.isEnabled(.squadSettingsTabV21) {
                SponsorStatusTile(title: "Home Roster", value: "\(sponsorStore.configuration.homeRoster.count) players", icon: "person.text.rectangle.fill")
            }
            SponsorStatusTile(title: "Intermission", value: sponsorStore.configuration.intermission.isEnabled ? "Enabled" : "Off", icon: "play.rectangle.on.rectangle.fill")
            SponsorStatusTile(title: "Recording/Stream", value: sponsorStore.configuration.overlay.isOutputOverlayEnabled ? "Included" : "Off", icon: sponsorStore.configuration.overlay.isOutputOverlayEnabled ? "antenna.radiowaves.left.and.right" : "eye.slash.fill")
            SponsorStatusTile(title: "iPad Preview", value: sponsorStore.configuration.overlay.showOverlayOnBroadcastScreen ? "Shown" : "Hidden", icon: sponsorStore.configuration.overlay.showOverlayOnBroadcastScreen ? "ipad" : "eye.slash")
        }
    }

    private var visibleSponsorSections: [SponsorSetupSection] {
        SponsorSetupSection.allCases.filter { section in
            !RinkLensRiskFeaturePolicy.isEnabled(.squadSettingsTabV21) || section != .squad
        }
    }

    private var sectionPicker: some View {
        HStack(spacing: 8) {
            ForEach(visibleSponsorSections) { section in
                Button {
                    selectedSection = section
                    MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("Sponsors section: \(section.title)"))
                } label: {
                    Label(section.title, systemImage: section.systemImage)
                        .labelStyle(.titleAndIcon)
                        .font(RinkLensDesignSystem.font(.caption))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity)
                }
                .foregroundStyle(selectedSection == section ? .black : .white.opacity(0.82))
                .background(selectedSection == section ? .white : .white.opacity(0.08), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
            }
        }
        .padding(6)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var activeSection: some View {
        switch selectedSection {
        case .catalogue:
            catalogueSection
        case .placements:
            placementsSection
        case .squad:
            playersSection
        case .intermission:
            intermissionSection
        case .preview:
            previewSection
        }
    }

    private var catalogueSection: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            SponsorSettingsCard(title: "Sponsor Catalogue", subtitle: "Create each sponsor once, then reuse it across one or more placements.", systemImage: "star.circle.fill") {
                VStack(alignment: .leading, spacing: 12) {
                    if sponsorStore.configuration.sponsors.isEmpty {
                        Text("No sponsors yet.")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.white.opacity(0.68))
                    } else {
                        ForEach(sponsorStore.configuration.sponsors) { sponsor in
                            sponsorRow(sponsor)
                        }
                    }

                    Button {
                        sponsorStore.addSponsor()
                        selectedSponsorID = sponsorStore.configuration.sponsors.last?.id
                    } label: {
                        Label("Add sponsor", systemImage: "plus.circle.fill")
                            .font(RinkLensDesignSystem.font(.cardTitle))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            SponsorSettingsCard(title: "Sponsor Details", subtitle: "Name, contact and reusable graphic asset.", systemImage: "person.crop.rectangle.stack.fill") {
                if let sponsor = selectedSponsor {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Active sponsor", isOn: sponsorBoolBinding(\.isActive))

                        TextField("Sponsor name", text: sponsorStringBinding(\.name))
                            .sponsorTextFieldStyle()

                        TextField("Contact name", text: sponsorStringBinding(\.contactName))
                            .sponsorTextFieldStyle()

                        TextField("Email address", text: sponsorStringBinding(\.emailAddress))
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                            .sponsorTextFieldStyle()

                        TextField("Notes", text: sponsorStringBinding(\.notes), axis: .vertical)
                            .lineLimit(2...4)
                            .sponsorTextFieldStyle()

                        HStack(spacing: 12) {
                            SponsorLogoBox(title: sponsor.displayName, image: sponsorLogoImage(for: sponsor.id), fallback: "LOGO")
                                .frame(width: 132, height: 86)

                            VStack(alignment: .leading, spacing: 8) {
                                PhotosPicker(selection: $selectedSponsorLogoItem, matching: .images) {
                                    Label("Add / replace logo", systemImage: "photo.badge.plus")
                                        .font(RinkLensDesignSystem.font(.bodyStrong))
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)

                                Button(role: .destructive) {
                                    sponsorStore.setSponsorLogo(id: sponsor.id, data: nil)
                                } label: {
                                    Label("Remove logo", systemImage: "trash")
                                        .font(RinkLensDesignSystem.font(.bodyStrong))
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            }
                        }

                        Button(role: .destructive) {
                            sponsorStore.deleteSponsor(id: sponsor.id)
                            selectedSponsorID = sponsorStore.configuration.sponsors.first?.id
                        } label: {
                            Label("Delete sponsor", systemImage: "trash")
                                .font(RinkLensDesignSystem.font(.bodyStrong))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    Text("Select a sponsor to edit.")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white.opacity(0.68))
                }
            }
        }
    }

    private var placementsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SponsorSettingsCard(title: "League / Competition Branding", subtitle: "Top-left broadcast identity, for example NIHL North 2 (Laidler) plus league logo.", systemImage: "shield.lefthalf.filled") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Show league branding top left", isOn: leagueEnabledBinding)

                    TextField("League / competition name", text: leagueNameBinding)
                        .sponsorTextFieldStyle()

                    HStack(spacing: 12) {
                        SponsorLogoBox(title: sponsorStore.configuration.league.name, image: leagueLogoImage, fallback: "LEAGUE")
                            .frame(width: 150, height: 92)

                        VStack(alignment: .leading, spacing: 8) {
                            PhotosPicker(selection: $selectedLeagueLogoItem, matching: .images) {
                                Label("Add league graphic", systemImage: "photo.badge.plus")
                                    .font(RinkLensDesignSystem.font(.bodyStrong))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)

                            Button(role: .destructive) {
                                sponsorStore.setLeagueLogo(data: nil)
                            } label: {
                                Label("Remove league graphic", systemImage: "trash")
                                    .font(RinkLensDesignSystem.font(.bodyStrong))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }

            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(SponsorPlacementSlot.allCases) { slot in
                    placementCard(slot)
                }
            }
        }
    }

    private var playersSection: some View {
        SquadRosterEditor(showsHeader: false)
    }

    private var intermissionSection: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            SponsorSettingsCard(title: "Intermission Sponsor Reel", subtitle: "Between 1st/2nd and 2nd/3rd period. Pulls from selected placements and optional catalogue sponsors.", systemImage: "play.rectangle.on.rectangle.fill") {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Enable intermission sponsor reel", isOn: intermissionBoolBinding(\.isEnabled))
                    Toggle("Show between 1st and 2nd period", isOn: intermissionBoolBinding(\.showBetweenFirstAndSecond))
                    Toggle("Show between 2nd and 3rd period", isOn: intermissionBoolBinding(\.showBetweenSecondAndThird))

                    Divider().overlay(.white.opacity(0.16))

                    Toggle("Include season sponsor", isOn: intermissionBoolBinding(\.includeSeasonSponsor))
                    Toggle("Include game sponsor", isOn: intermissionBoolBinding(\.includeGameSponsor))
                    Toggle("Include home/away goal sponsors", isOn: intermissionBoolBinding(\.includeGoalSponsors))
                    Toggle("Include penalty sponsors", isOn: intermissionBoolBinding(\.includePenaltySponsors))
                    Toggle("Include final score sponsor", isOn: intermissionBoolBinding(\.includeFinalScoreSponsor))
                    Toggle("Include all active catalogue sponsors", isOn: intermissionBoolBinding(\.includeAllActiveCatalogueSponsors))

                    HStack {
                        Text("Slide duration")
                            .font(RinkLensDesignSystem.font(.bodyStrong))
                        Spacer()
                        Text("\(Int(sponsorStore.configuration.intermission.slideDurationSeconds))s")
                            .font(RinkLensDesignSystem.font(.caption))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    Slider(value: intermissionDurationBinding, in: 4...20, step: 1)
                }
            }

            SponsorSettingsCard(title: "Intermission Includes", subtitle: "Preview of the sponsor sources available to the reel.", systemImage: "list.bullet.rectangle.fill") {
                SponsorInfoGrid(rows: intermissionPreviewRows)
            }
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SponsorSettingsCard(title: "Sponsor Output", subtitle: "Two separate switches: what the operator sees on the iPad, and what is burnt into recording/streaming.", systemImage: "eye.fill") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Show sponsors on this iPad Broadcast screen", isOn: broadcastPreviewOverlayVisibleBinding)
                    Toggle("Include sponsors in recording and streaming output", isOn: outputOverlayEnabledBinding)
                    Text(sponsorStore.configuration.overlay.isOutputOverlayEnabled ? "Recording/streaming output includes sponsor overlays. The iPad preview switch only controls what the person recording sees." : "Recording/streaming output does not include sponsor overlays. You can still show sponsors on the iPad preview for setup checks.")
                        .font(RinkLensDesignSystem.font(.caption))
                        .foregroundStyle(.white.opacity(0.66))
                }
            }

            SponsorSettingsCard(title: "Broadcast Sponsor Map", subtitle: "Commercial moments and assigned sponsors. League, season and game placements are now available to the Broadcast overlay.", systemImage: "rectangle.3.group.fill") {
                SponsorInfoGrid(rows: placementPreviewRows)
            }

            SponsorSettingsCard(title: "Example Overlay Positions", subtitle: "Confirms the intended commercial model before renderer integration.", systemImage: "rectangle.on.rectangle.angled") {
                VStack(alignment: .leading, spacing: 12) {
                    sponsorPreviewOverlay
                    Text("Top left is league branding. Top right is season sponsor. Above scorebug is game sponsor. Goal, penalty, final score and intermission use the assigned catalogue sponsor rules.")
                        .font(RinkLensDesignSystem.font(.caption))
                        .foregroundStyle(.white.opacity(0.68))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func sponsorRow(_ sponsor: SponsorCatalogueSponsor) -> some View {
        Button {
            selectedSponsorID = sponsor.id
        } label: {
            HStack(spacing: 12) {
                SponsorLogoBox(title: sponsor.displayName, image: sponsorLogoImage(for: sponsor.id), fallback: "LOGO")
                    .frame(width: 54, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text(sponsor.displayName)
                        .font(.subheadline.weight(.heavy))
                    Text(sponsor.emailAddress.isEmpty ? "No email" : sponsor.emailAddress)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.60))
                        .lineLimit(1)
                }

                Spacer()

                Text(sponsor.isActive ? "Active" : "Off")
                    .font(RinkLensDesignSystem.font(.micro))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((sponsor.isActive ? Color.green : Color.gray).opacity(0.18), in: Capsule())
            }
            .padding(10)
            .background(selectedSponsorID == sponsor.id ? .white.opacity(0.16) : .white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(selectedSponsorID == sponsor.id ? 0.28 : 0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func placementCard(_ slot: SponsorPlacementSlot) -> some View {
        SponsorSettingsCard(title: slot.title, subtitle: slot.subtitle, systemImage: slot.systemImage) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Sponsor", selection: placementBinding(slot)) {
                    Text("Not assigned").tag(Optional<UUID>.none)
                    ForEach(sponsorStore.configuration.sponsors) { sponsor in
                        Text(sponsor.displayName).tag(Optional(sponsor.id))
                    }
                }
                .pickerStyle(.menu)

                SponsorInfoGrid(rows: [
                    ("Position", slot.positionText),
                    ("Trigger", slot.triggerText),
                    ("Assigned", sponsorStore.sponsorName(for: placementValue(slot)))
                ])
            }
        }
    }

    private func playerRow(_ player: SponsorPlayerAssignment) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("No.", text: playerStringBinding(player.id, \.number))
                    .frame(width: 62)
                    .sponsorTextFieldStyle()

                TextField("Player name", text: playerStringBinding(player.id, \.name))
                    .sponsorTextFieldStyle()
            }

            Picker("Penalty sponsor", selection: playerSponsorBinding(player.id)) {
                Text("Default home penalty sponsor").tag(Optional<UUID>.none)
                ForEach(sponsorStore.configuration.sponsors) { sponsor in
                    Text(sponsor.displayName).tag(Optional(sponsor.id))
                }
            }
            .pickerStyle(.menu)

            HStack {
                Text(player.displayName)
                    .font(RinkLensDesignSystem.font(.caption))
                    .foregroundStyle(.white.opacity(0.70))
                Spacer()
                Button(role: .destructive) {
                    sponsorStore.deleteHomePlayer(id: player.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.10), lineWidth: 1))
    }

    private var sponsorPreviewOverlay: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [.black.opacity(0.85), .blue.opacity(0.25), .black.opacity(0.92)], startPoint: .topLeading, endPoint: .bottomTrailing)

            VStack(spacing: 18) {
                HStack(alignment: .top) {
                    if sponsorStore.configuration.league.isEnabled {
                        HStack(spacing: 8) {
                            SponsorLogoBox(title: sponsorStore.configuration.league.name, image: leagueLogoImage, fallback: "L")
                                .frame(width: 42, height: 34)
                            Text(sponsorStore.configuration.league.name)
                                .font(RinkLensDesignSystem.font(.caption))
                        }
                        .padding(8)
                        .background(.black.opacity(0.42), in: Capsule())
                    }

                    Spacer()

                    sponsorPill(title: "Season", sponsorID: sponsorStore.configuration.placements.seasonSponsorID)
                }

                sponsorPill(title: "Game sponsor above scorebug", sponsorID: sponsorStore.configuration.placements.gameSponsorID)
                    .frame(maxWidth: 360)

                Spacer(minLength: 12)

                HStack {
                    sponsorPill(title: "Goal", sponsorID: sponsorStore.configuration.placements.homeGoalSponsorID)
                    sponsorPill(title: "Penalty", sponsorID: sponsorStore.configuration.placements.homePenaltyDefaultSponsorID)
                    sponsorPill(title: "Final", sponsorID: sponsorStore.configuration.placements.finalScoreSponsorID)
                }
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, minHeight: 270)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private func sponsorPill(title: String, sponsorID: UUID?) -> some View {
        HStack(spacing: 8) {
            SponsorLogoBox(title: sponsorStore.sponsorName(for: sponsorID), image: sponsorLogoImage(for: sponsorID), fallback: "S")
                .frame(width: 38, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(RinkLensDesignSystem.font(.micro))
                    .foregroundStyle(.white.opacity(0.55))
                Text(sponsorStore.sponsorName(for: sponsorID))
                    .font(RinkLensDesignSystem.font(.caption))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.black.opacity(0.45), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private var selectedSponsor: SponsorCatalogueSponsor? {
        guard let selectedSponsorID else { return nil }
        return sponsorStore.configuration.sponsors.first(where: { $0.id == selectedSponsorID })
    }

    private var leagueNameBinding: Binding<String> {
        Binding(
            get: { sponsorStore.configuration.league.name },
            set: { newValue in sponsorStore.setLeagueName(newValue) }
        )
    }

    private var leagueEnabledBinding: Binding<Bool> {
        Binding(
            get: { sponsorStore.configuration.league.isEnabled },
            set: { newValue in sponsorStore.setLeagueEnabled(newValue) }
        )
    }

    private var outputOverlayEnabledBinding: Binding<Bool> {
        Binding(
            get: { sponsorStore.configuration.overlay.isOutputOverlayEnabled },
            set: { sponsorStore.setOutputOverlayEnabled($0) }
        )
    }

    private var broadcastPreviewOverlayVisibleBinding: Binding<Bool> {
        Binding(
            get: { sponsorStore.configuration.overlay.showOverlayOnBroadcastScreen },
            set: { sponsorStore.setBroadcastPreviewOverlayVisible($0) }
        )
    }

    private func sponsorStringBinding(_ keyPath: WritableKeyPath<SponsorCatalogueSponsor, String>) -> Binding<String> {
        Binding(
            get: { selectedSponsor?[keyPath: keyPath] ?? "" },
            set: { newValue in
                guard let selectedSponsorID else { return }
                sponsorStore.updateSponsor(id: selectedSponsorID) { sponsor in
                    sponsor[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func sponsorBoolBinding(_ keyPath: WritableKeyPath<SponsorCatalogueSponsor, Bool>) -> Binding<Bool> {
        Binding(
            get: { selectedSponsor?[keyPath: keyPath] ?? false },
            set: { newValue in
                guard let selectedSponsorID else { return }
                sponsorStore.updateSponsor(id: selectedSponsorID) { sponsor in
                    sponsor[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func placementBinding(_ slot: SponsorPlacementSlot) -> Binding<UUID?> {
        Binding(
            get: { placementValue(slot) },
            set: { newValue in
                setPlacement(slot, newValue)
            }
        )
    }

    private func placementValue(_ slot: SponsorPlacementSlot) -> UUID? {
        let placements = sponsorStore.configuration.placements
        switch slot {
        case .season: return placements.seasonSponsorID
        case .game: return placements.gameSponsorID
        case .homeGoal: return placements.homeGoalSponsorID
        case .awayGoal: return placements.awayGoalSponsorID
        case .homePenaltyDefault: return placements.homePenaltyDefaultSponsorID
        case .awayPenalty: return placements.awayPenaltySponsorID
        case .finalScore: return placements.finalScoreSponsorID
        }
    }

    private func setPlacement(_ slot: SponsorPlacementSlot, _ sponsorID: UUID?) {
        sponsorStore.setPlacement(slot, sponsorID: sponsorID)
    }

    private func playerStringBinding(_ playerID: UUID, _ keyPath: WritableKeyPath<SponsorPlayerAssignment, String>) -> Binding<String> {
        Binding(
            get: { sponsorStore.configuration.homeRoster.first(where: { $0.id == playerID })?[keyPath: keyPath] ?? "" },
            set: { newValue in
                sponsorStore.updateHomePlayer(id: playerID) { player in
                    player[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func playerSponsorBinding(_ playerID: UUID) -> Binding<UUID?> {
        Binding(
            get: { sponsorStore.configuration.homeRoster.first(where: { $0.id == playerID })?.sponsorID },
            set: { newValue in
                sponsorStore.updateHomePlayer(id: playerID) { player in
                    player.sponsorID = newValue
                }
            }
        )
    }

    private func intermissionBoolBinding(_ keyPath: WritableKeyPath<SponsorIntermissionConfiguration, Bool>) -> Binding<Bool> {
        Binding(
            get: { sponsorStore.configuration.intermission[keyPath: keyPath] },
            set: { newValue in
                sponsorStore.updateIntermission { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    private var intermissionDurationBinding: Binding<Double> {
        Binding(
            get: { sponsorStore.configuration.intermission.slideDurationSeconds },
            set: { newValue in
                sponsorStore.updateIntermission { $0.slideDurationSeconds = newValue }
            }
        )
    }

    private func importRosterLines() {
        let lines = rosterImportText
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let players = lines.map { line -> SponsorPlayerAssignment in
            let parts = line.split(separator: " ", maxSplits: 1).map { String($0) }
            let number = parts.first ?? ""
            let name = parts.count > 1 ? parts[1] : ""
            return SponsorPlayerAssignment(number: number, name: name, sponsorID: nil)
        }
        sponsorStore.importHomeRoster(players)
        rosterImportText = ""
        MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("home sponsor roster imported"))
    }

    private var placementPreviewRows: [(String, String)] {
        SponsorPlacementSlot.allCases.map { slot in
            (slot.title, sponsorStore.sponsorName(for: placementValue(slot)))
        }
    }

    private var intermissionPreviewRows: [(String, String)] {
        [
            ("Between 1st / 2nd", sponsorStore.configuration.intermission.showBetweenFirstAndSecond ? "Yes" : "No"),
            ("Between 2nd / 3rd", sponsorStore.configuration.intermission.showBetweenSecondAndThird ? "Yes" : "No"),
            ("Season sponsor", sponsorStore.configuration.intermission.includeSeasonSponsor ? sponsorStore.sponsorName(for: sponsorStore.configuration.placements.seasonSponsorID) : "Excluded"),
            ("Game sponsor", sponsorStore.configuration.intermission.includeGameSponsor ? sponsorStore.sponsorName(for: sponsorStore.configuration.placements.gameSponsorID) : "Excluded"),
            ("Goal sponsors", sponsorStore.configuration.intermission.includeGoalSponsors ? "Home + away goal slots" : "Excluded"),
            ("Penalty sponsors", sponsorStore.configuration.intermission.includePenaltySponsors ? "Home player/default + away slot" : "Excluded"),
            ("Final score sponsor", sponsorStore.configuration.intermission.includeFinalScoreSponsor ? sponsorStore.sponsorName(for: sponsorStore.configuration.placements.finalScoreSponsorID) : "Excluded"),
            ("Slide duration", "\(Int(sponsorStore.configuration.intermission.slideDurationSeconds)) seconds")
        ]
    }

    #if canImport(UIKit)
    private var leagueLogoImage: UIImage? { sponsorStore.leagueLogoImage }
    private func sponsorLogoImage(for id: UUID?) -> UIImage? { sponsorStore.logoImage(for: id) }
    #else
    private var leagueLogoImage: Never? { nil }
    private func sponsorLogoImage(for id: UUID?) -> Never? { nil }
    #endif
}

private enum SponsorSetupSection: String, CaseIterable, Identifiable {
    case catalogue
    case placements
    case squad
    case intermission
    case preview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .catalogue: return "Catalogue"
        case .placements: return "Placements"
        case .squad: return "Squad"
        case .intermission: return "Intermission"
        case .preview: return "Preview"
        }
    }

    var systemImage: String {
        switch self {
        case .catalogue: return "star.fill"
        case .placements: return "rectangle.grid.2x2.fill"
        case .squad: return "person.3.fill"
        case .intermission: return "play.rectangle.on.rectangle.fill"
        case .preview: return "eye.fill"
        }
    }
}

enum SponsorPlacementSlot: String, CaseIterable, Identifiable {
    case season
    case game
    case homeGoal
    case awayGoal
    case homePenaltyDefault
    case awayPenalty
    case finalScore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .season: return "Season Sponsor"
        case .game: return "Game Sponsor"
        case .homeGoal: return "Home Goal Sponsor"
        case .awayGoal: return "Away Goal Sponsor"
        case .homePenaltyDefault: return "Home Penalty Default"
        case .awayPenalty: return "Away Penalty Sponsor"
        case .finalScore: return "Final Score Sponsor"
        }
    }

    var subtitle: String {
        switch self {
        case .season: return "Top right sponsor placement."
        case .game: return "Above scoreboard for the current game."
        case .homeGoal: return "Appears on next home goal popup."
        case .awayGoal: return "Appears on next away goal popup."
        case .homePenaltyDefault: return "Fallback for home penalty if selected player has no sponsor."
        case .awayPenalty: return "Single away penalty sponsor option."
        case .finalScore: return "End of game / final score sponsor."
        }
    }

    var positionText: String {
        switch self {
        case .season: return "Top right"
        case .game: return "Above scoreboard"
        case .homeGoal, .awayGoal: return "Goal popup"
        case .homePenaltyDefault, .awayPenalty: return "Penalty popup"
        case .finalScore: return "Final score overlay"
        }
    }

    var triggerText: String {
        switch self {
        case .season: return "Always available"
        case .game: return "Game start / manual"
        case .homeGoal: return "Home goal"
        case .awayGoal: return "Away goal"
        case .homePenaltyDefault: return "Home penalty"
        case .awayPenalty: return "Away penalty"
        case .finalScore: return "Final horn"
        }
    }

    var systemImage: String {
        switch self {
        case .season: return "star.circle.fill"
        case .game: return "sportscourt.fill"
        case .homeGoal, .awayGoal: return "hockey.puck.fill"
        case .homePenaltyDefault, .awayPenalty: return "exclamationmark.octagon.fill"
        case .finalScore: return "flag.checkered"
        }
    }
}



private struct SponsorSettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BroadcastMenuHeaderLabel(title: title, subtitle: subtitle, systemImage: systemImage)
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

private extension View {
    func sponsorTextFieldStyle() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
    }
}

private struct SponsorStatusTile: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(RinkLensDesignSystem.font(.cardTitle))
                .foregroundStyle(.cyan)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(RinkLensDesignSystem.font(.micro))
                    .foregroundStyle(.white.opacity(0.56))
                    .textCase(.uppercase)
                Text(value)
                    .font(RinkLensDesignSystem.font(.caption))
                    .foregroundStyle(.white.opacity(0.90))
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.10), lineWidth: 1))
    }
}

private struct SponsorInfoGrid: View {
    let rows: [(String, String)]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.0)
                        .font(RinkLensDesignSystem.font(.micro))
                        .foregroundStyle(.white.opacity(0.55))
                        .textCase(.uppercase)
                    Text(row.1)
                        .font(RinkLensDesignSystem.font(.caption))
                        .foregroundStyle(.white.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }
}

private struct SponsorLogoBox: View {
    let title: String
    #if canImport(UIKit)
    let image: UIImage?
    #else
    let image: Never?
    #endif
    let fallback: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.08))

            #if canImport(UIKit)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
            } else {
                fallbackView
            }
            #else
            fallbackView
            #endif
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
        .accessibilityLabel(title)
    }

    private var fallbackView: some View {
        Text(fallback)
            .font(RinkLensDesignSystem.font(.micro))
            .foregroundStyle(.white.opacity(0.68))
            .padding(6)
            .minimumScaleFactor(0.5)
    }
}

#endif


#if canImport(SwiftUI)

struct SponsorsSettingsEmbeddedView: View {
    var body: some View {
        SponsorsRouteShellView(embeddedInSettings: true)
            .frame(maxWidth: .infinity, alignment: .top)
    }
}

struct SquadSettingsEmbeddedView: View {
    var body: some View {
        SquadRosterEditor(showsHeader: true)
            .frame(maxWidth: .infinity, alignment: .top)
    }
}

private struct SquadRosterEditor: View {
    @ObservedObject private var sponsorStore = SponsorCatalogueStore.shared
    @State private var rosterImportText = ""

    let showsHeader: Bool
    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showsHeader {
                HStack(spacing: 14) {
                    Image(systemName: "person.3.fill")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Squad")
                            .font(RinkLensDesignSystem.font(.cardTitle))
                            .foregroundStyle(RinkLensDesignSystem.primaryText)
                        Text("Home roster, player numbers and optional penalty-sponsor assignments")
                            .font(RinkLensDesignSystem.font(.caption))
                            .foregroundStyle(RinkLensDesignSystem.mutedText)
                    }

                    Spacer()

                    Text("\(sponsorStore.configuration.homeRoster.count) players")
                        .font(RinkLensDesignSystem.font(.caption))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(18)
                .background(RinkLensDesignSystem.cardBackground, in: RoundedRectangle(cornerRadius: RinkLensDesignSystem.cardCornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: RinkLensDesignSystem.cardCornerRadius, style: .continuous).stroke(RinkLensDesignSystem.border, lineWidth: 1))
            }

            LazyVGrid(columns: columns, spacing: 14) {
                SponsorSettingsCard(title: "Import Home Roster", subtitle: "Paste one player per line. Use number then name, for example: 45 James Best.", systemImage: "square.and.arrow.down.on.square.fill") {
                    VStack(alignment: .leading, spacing: 12) {
                        TextEditor(text: $rosterImportText)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 140)
                            .padding(10)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))

                        Button {
                            importRosterLines()
                        } label: {
                            Label("Import roster lines", systemImage: "person.crop.rectangle.badge.plus")
                                .font(RinkLensDesignSystem.font(.cardTitle))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(rosterImportText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                SponsorSettingsCard(title: "Home Penalty Sponsors", subtitle: "Map individual home players to a sponsor used when that player receives a penalty.", systemImage: "person.crop.rectangle.fill") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(sponsorStore.configuration.homeRoster) { player in
                            playerRow(player)
                        }

                        Button {
                            sponsorStore.addHomePlayer()
                        } label: {
                            Label("Add player", systemImage: "plus.circle.fill")
                                .font(RinkLensDesignSystem.font(.cardTitle))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .onAppear {
            RinkLensStructuredEventLogger.shared.record(
                domain: .sponsorRoster,
                event: "squad_editor_presented",
                previous: ["visible": "false"],
                next: ["visible": "true", "playerCount": String(sponsorStore.configuration.homeRoster.count)],
                source: "SquadRosterEditor",
                reason: showsHeader ? "Operator selected Settings Squad tab" : "Rollback Sponsor Squad section displayed",
                authoritativeOwner: "SponsorCatalogueStore"
            )
            MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("Squad editor appeared"))
        }
    }

    private func playerRow(_ player: SponsorPlayerAssignment) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("No.", text: playerStringBinding(player.id, \.number))
                    .frame(width: 62)
                    .sponsorTextFieldStyle()

                TextField("Player name", text: playerStringBinding(player.id, \.name))
                    .sponsorTextFieldStyle()
            }

            Picker("Penalty sponsor", selection: playerSponsorBinding(player.id)) {
                Text("Default home penalty sponsor").tag(Optional<UUID>.none)
                ForEach(sponsorStore.configuration.sponsors) { sponsor in
                    Text(sponsor.displayName).tag(Optional(sponsor.id))
                }
            }
            .pickerStyle(.menu)

            HStack {
                Text(player.displayName)
                    .font(RinkLensDesignSystem.font(.caption))
                    .foregroundStyle(.white.opacity(0.70))
                Spacer()
                Button(role: .destructive) {
                    sponsorStore.deleteHomePlayer(id: player.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.10), lineWidth: 1))
    }

    private func playerStringBinding(_ playerID: UUID, _ keyPath: WritableKeyPath<SponsorPlayerAssignment, String>) -> Binding<String> {
        Binding(
            get: { sponsorStore.configuration.homeRoster.first(where: { $0.id == playerID })?[keyPath: keyPath] ?? "" },
            set: { newValue in
                sponsorStore.updateHomePlayer(id: playerID) { player in
                    player[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func playerSponsorBinding(_ playerID: UUID) -> Binding<UUID?> {
        Binding(
            get: { sponsorStore.configuration.homeRoster.first(where: { $0.id == playerID })?.sponsorID },
            set: { newValue in
                sponsorStore.updateHomePlayer(id: playerID) { player in
                    player.sponsorID = newValue
                }
            }
        )
    }

    private func importRosterLines() {
        let lines = rosterImportText
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let players = lines.map { line -> SponsorPlayerAssignment in
            let parts = line.split(separator: " ", maxSplits: 1).map { String($0) }
            return SponsorPlayerAssignment(
                number: parts.first ?? "",
                name: parts.count > 1 ? parts[1] : "",
                sponsorID: nil
            )
        }
        sponsorStore.importHomeRoster(players)
        rosterImportText = ""
        MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("Squad roster imported"))
    }
}

#endif
