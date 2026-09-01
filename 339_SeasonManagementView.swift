// Build 785 Recovery CV: season configuration UI; submits intent to domain owners only.
#if canImport(SwiftUI)
import SwiftUI

struct FixtureProductionSetupCard: View {
    let viewModel: HockeyScoreboardViewModel
    let openManagement: () -> Void
    @ObservedObject private var store = RinkLensSeasonStore.shared
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BroadcastMenuHeaderLabel(title: "1. Game", subtitle: "Select a fixture, then load its configuration", systemImage: "calendar.badge.checkmark")
            if let fixture = store.selectedFixture, let pairing = pairing(for: fixture) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(pairing.home.shortName) v \(pairing.away.shortName)")
                            .font(.title3.weight(.bold))
                        Text(fixture.scheduledStart.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.white.opacity(0.68))
                        if let venue = venue(for: fixture) { Text(venue.name).font(.caption).foregroundStyle(.white.opacity(0.58)) }
                    }
                    Spacer()
                    readiness(pairing: pairing, fixture: fixture)
                }
                HStack {
                    Button("Change Fixture", action: openManagement).buttonStyle(.bordered)
                    Spacer()
                    Button("Load Game") { loadGame() }
                        .buttonStyle(.borderedProminent).tint(.cyan)
                }
            } else {
                Text("No fixture selected")
                    .font(.headline).foregroundStyle(.white.opacity(0.70))
                Button("Set Up Season & Fixtures", action: openManagement)
                    .buttonStyle(.borderedProminent).tint(.cyan)
            }
            if let errorText { Label(errorText, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
            if let active = store.gameConfigurationStore.activeSnapshot {
                Label("Loaded: \(active.homeTeam.shortName) v \(active.awayTeam.shortName) · production not started", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.green)
            }
        }
        .padding(14)
        .broadcastMenuCard(cornerRadius: 18)
    }

    private func loadGame() {
        do { let snapshot = try store.loadSelectedFixture(source: "ProductionSetup.Game", reason: "Operator pressed Load Game"); viewModel.applyGameConfigurationSnapshot(snapshot); errorText = nil }
        catch { errorText = error.localizedDescription }
    }
    private func pairing(for fixture: RinkLensFixture) -> (home: RinkLensTeamProfile, away: RinkLensTeamProfile)? {
        guard let home = store.catalogue.teams.first(where: { $0.id == fixture.homeTeamID }), let away = store.catalogue.teams.first(where: { $0.id == fixture.awayTeamID }) else { return nil }; return (home, away)
    }
    private func venue(for fixture: RinkLensFixture) -> RinkLensVenue? { fixture.venueID.flatMap { id in store.catalogue.venues.first(where: { $0.id == id }) } }
    private func readiness(pairing: (home: RinkLensTeamProfile, away: RinkLensTeamProfile), fixture: RinkLensFixture) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Label("Teams", systemImage: "checkmark.circle.fill")
            Label("Recording", systemImage: "checkmark.circle.fill")
            Label(fixture.youtubePublication == nil ? "YouTube local" : "YouTube scheduled", systemImage: fixture.youtubePublication == nil ? "circle" : "checkmark.circle.fill")
        }.font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.72))
    }
}

struct SeasonManagementView: View {
    let viewModel: HockeyScoreboardViewModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = RinkLensSeasonStore.shared
    @State private var tab: Tab = .fixtures
    @State private var seasonName = ""
    @State private var competition = ""
    @State private var teamName = ""
    @State private var teamShortName = ""
    @State private var teamAbbreviation = ""
    @State private var homeTeamID: UUID?
    @State private var awayTeamID: UUID?
    @State private var fixtureDate = Date().addingTimeInterval(86_400)
    @State private var csvText = "date,time,home,away,venue,competition\n"
    @State private var importPreview: RinkLensFixtureImportPreview?
    @State private var actionText: String?
    @State private var youtubeBusy = false
    @State private var oauthCoordinator = RinkLensYouTubeAuthorizationCoordinator()
    @State private var thumbnailPreview: UIImage?

    private enum Tab: String, CaseIterable, Identifiable { case fixtures = "Fixtures", teams = "Teams", season = "Season", youtube = "YouTube"; var id: String { rawValue } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Picker("Season section", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                ScrollView { VStack(alignment: .leading, spacing: 16) { content }.padding(.vertical, 4) }
            }
            .padding(20)
            .navigationTitle("Season & Fixtures")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { if store.selectedSeasonID == nil, let first = store.catalogue.seasons.first { store.selectSeason(first.id) } }
        }
    }

    @ViewBuilder private var content: some View {
        if let actionText { Text(actionText).font(.caption.weight(.semibold)).foregroundStyle(.cyan) }
        switch tab {
        case .season: seasonEditor
        case .teams: teamEditor
        case .fixtures: fixtureEditor
        case .youtube: youtubeEditor
        }
    }

    private var seasonEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Seasons").font(.title2.bold())
            ForEach(store.catalogue.seasons) { season in
                Button { store.selectSeason(season.id) } label: {
                    HStack { VStack(alignment: .leading) { Text(season.name).font(.headline); Text("\(store.fixtures(for: season.id).count) fixtures").font(.caption) }; Spacer(); if store.selectedSeasonID == season.id { Image(systemName: "checkmark.circle.fill") } }
                }.buttonStyle(.bordered)
            }
            Divider()
            TextField("Season name", text: $seasonName).textFieldStyle(.roundedBorder)
            TextField("Competition", text: $competition).textFieldStyle(.roundedBorder)
            Button("Create Season") { guard !seasonName.trimmingCharacters(in: .whitespaces).isEmpty else { return }; _ = store.createSeason(name: seasonName, competition: competition); seasonName = ""; actionText = "Season created" }.buttonStyle(.borderedProminent)
        }
    }

    private var teamEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reusable Teams").font(.title2.bold())
            ForEach(store.catalogue.teams) { team in HStack { Text(team.scorebugAbbreviation).font(.caption.monospaced().bold()).frame(width: 54); Text(team.fullName); Spacer(); Text("\(team.roster.count) players").font(.caption).foregroundStyle(.secondary) } }
            Divider()
            TextField("Full name", text: $teamName).textFieldStyle(.roundedBorder)
            TextField("Short name", text: $teamShortName).textFieldStyle(.roundedBorder)
            TextField("Scorebug abbreviation", text: $teamAbbreviation).textFieldStyle(.roundedBorder)
            Button("Add Team") {
                guard !teamName.isEmpty, !teamAbbreviation.isEmpty else { return }
                store.upsertTeam(.init(fullName: teamName, shortName: teamShortName.isEmpty ? teamName : teamShortName, scorebugAbbreviation: teamAbbreviation.uppercased()))
                teamName = ""; teamShortName = ""; teamAbbreviation = ""; actionText = "Team saved once for fixture reuse"
            }.buttonStyle(.borderedProminent)
            if let seasonID = store.selectedSeasonID, !viewModel.teamIdentityTemplates.isEmpty {
                Divider()
                Text("Convert Existing Profiles").font(.headline)
                ForEach(viewModel.teamIdentityTemplates) { template in
                    Button("Convert \(template.name)") {
                        do {
                            _ = try store.commitTeamIdentityMigration(template, into: seasonID)
                            actionText = "Converted \(template.name); original profile retained"
                        } catch { actionText = error.localizedDescription }
                    }.buttonStyle(.bordered)
                }
            }
        }
    }

    private var fixtureEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fixtures").font(.title2.bold())
            if let seasonID = store.selectedSeasonID {
                ForEach(store.fixtures(for: seasonID)) { fixture in
                    HStack {
                        Button { store.selectFixture(fixture.id) } label: {
                            HStack { Text(fixture.scheduledStart.formatted(date: .abbreviated, time: .shortened)); Spacer(); Text(pairingText(fixture)); if store.selectedFixtureID == fixture.id { Image(systemName: "checkmark.circle.fill") } }
                        }.buttonStyle(.bordered)
                        Menu(fixture.status.rawValue.capitalized) {
                            ForEach(RinkLensFixtureStatus.allCases) { status in
                                Button(status.rawValue.capitalized) {
                                    var updated = fixture; updated.status = status; store.upsertFixture(updated)
                                    actionText = status == .cancelled && fixture.youtubePublication != nil
                                        ? "Fixture cancelled locally; its YouTube event was left unchanged"
                                        : "Fixture status changed to \(status.rawValue)"
                                }
                            }
                        }.buttonStyle(.bordered)
                    }
                }
                Divider()
                Picker("Home", selection: $homeTeamID) { Text("Select Home").tag(UUID?.none); ForEach(store.catalogue.teams) { Text($0.fullName).tag(Optional($0.id)) } }
                Picker("Away", selection: $awayTeamID) { Text("Select Away").tag(UUID?.none); ForEach(store.catalogue.teams) { Text($0.fullName).tag(Optional($0.id)) } }
                DatePicker("Face-off", selection: $fixtureDate)
                Button("Add Fixture") { guard let homeTeamID, let awayTeamID, homeTeamID != awayTeamID else { return }; let fixture = RinkLensFixture(seasonID: seasonID, homeTeamID: homeTeamID, awayTeamID: awayTeamID, scheduledStart: fixtureDate); store.upsertFixture(fixture); store.selectFixture(fixture.id); actionText = "Fixture added" }.buttonStyle(.borderedProminent)
                Divider()
                Text("CSV Import Preview").font(.headline)
                TextEditor(text: $csvText).font(.system(.caption, design: .monospaced)).frame(minHeight: 120).overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.4)))
                Button("Validate CSV") { importPreview = RinkLensFixtureCSVImporter.preview(csv: csvText, seasonID: seasonID, teams: store.catalogue.teams, venues: store.catalogue.venues, existing: store.fixtures(for: seasonID)) }.buttonStyle(.bordered)
                if let preview = importPreview {
                    Text("\(preview.fixtures.count) valid · \(preview.issues.count) issues")
                    ForEach(preview.issues) { Text("Row \($0.row): \($0.message)").font(.caption).foregroundStyle(.orange) }
                    Button("Commit Import") { store.commitImportedFixtures(preview.fixtures); actionText = "Imported \(preview.fixtures.count) fixtures" }.buttonStyle(.borderedProminent).disabled(!preview.canCommit)
                }
            } else { Text("Create or select a season first.") }
        }
    }

    private var youtubeEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("YouTube Publishing").font(.title2.bold())
            if let season = store.selectedSeason {
                let profile = season.youtubeProfileID.flatMap { id in store.catalogue.youtubeProfiles.first(where: { $0.id == id }) }
                if let profile {
                    LabeledContent("Channel", value: profile.channelName ?? "Not connected")
                    TextField("Title template", text: youtubeBinding(profile, \.titleTemplate)).textFieldStyle(.roundedBorder)
                    Text("Description template").font(.caption.weight(.semibold))
                    TextEditor(text: youtubeBinding(profile, \.descriptionTemplate)).frame(minHeight: 100)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.4)))
                    Picker("Visibility", selection: youtubeBinding(profile, \.visibility)) {
                        ForEach(RinkLensYouTubeVisibility.allCases) { Text($0.rawValue.capitalized).tag($0) }
                    }.pickerStyle(.segmented)
                    Toggle("Made for kids", isOn: youtubeBinding(profile, \.madeForKids))
                    LabeledContent("Publishing window", value: "\(profile.publishingWindowDays) days")
                    LabeledContent("Events due", value: String(RinkLensYouTubePublishingWindow.fixturesDue(fixtures: store.catalogue.fixtures, seasonID: season.id, days: profile.publishingWindowDays).count))
                    DisclosureGroup("Broadcast Defaults") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("DVR", isOn: youtubeBinding(profile, \.enableDVR))
                            Toggle("Record from start", isOn: youtubeBinding(profile, \.recordFromStart))
                            Toggle("Auto start", isOn: youtubeBinding(profile, \.enableAutoStart))
                            Toggle("Auto stop", isOn: youtubeBinding(profile, \.enableAutoStop))
                            Toggle("Allow embedding", isOn: youtubeBinding(profile, \.enableEmbed))
                            TextField("Reusable YouTube stream ID (optional)", text: optionalYouTubeBinding(profile, \.streamID)).textFieldStyle(.roundedBorder)
                        }.padding(.top, 6)
                    }
                    Picker("Playlist", selection: youtubeBinding(profile, \.playlistPolicy)) {
                        Text("No playlist").tag(RinkLensYouTubePlaylistPolicy.none)
                        Text("Use existing").tag(RinkLensYouTubePlaylistPolicy.useExisting)
                        Text("Create if missing").tag(RinkLensYouTubePlaylistPolicy.createIfMissing)
                    }
                    if profile.playlistPolicy != .none {
                        TextField("Playlist name", text: optionalYouTubeBinding(profile, \.playlistName)).textFieldStyle(.roundedBorder)
                        TextField("Existing playlist ID (optional)", text: optionalYouTubeBinding(profile, \.playlistID)).textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Button(profile.channelID == nil ? "Connect Channel" : "Reconnect Channel") { connectYouTube(profile: profile) }
                            .buttonStyle(.bordered)
                        Button("Preview Thumbnail") { previewThumbnail() }
                            .buttonStyle(.bordered)
                            .disabled(store.selectedFixtureID == nil)
                        Button("Sync Selected Fixture") { syncSelectedFixture() }
                            .buttonStyle(.borderedProminent)
                            .disabled(youtubeBusy || store.selectedFixtureID == nil)
                    }
                    if youtubeBusy { ProgressView().controlSize(.small) }
                    if let thumbnailPreview {
                        Image(uiImage: thumbnailPreview).resizable().scaledToFit().frame(maxWidth: 520)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    if let publication = store.selectedFixture?.youtubePublication {
                        LabeledContent("Selected fixture", value: publication.state.rawValue.capitalized)
                        LabeledContent("Broadcast ID", value: publication.broadcastID)
                    }
                } else {
                    Text("No YouTube defaults yet.")
                    Button("Create Recommended Defaults") {
                        let profile = RinkLensYouTubePublishingProfile(); store.upsertYouTubeProfile(profile)
                        var updated = season; updated.youtubeProfileID = profile.id; store.upsertSeason(updated); actionText = "YouTube defaults created"
                    }.buttonStyle(.borderedProminent)
                }
                Divider()
                Label("Google authorisation is stored in Keychain. Local fixture setup and recording remain available when YouTube is offline.", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
            } else { Text("Create or select a season first.") }
        }
    }

    private func connectYouTube(profile: RinkLensYouTubePublishingProfile) {
        youtubeBusy = true; actionText = "Opening Google authorisation…"
        Task { @MainActor in
            defer { youtubeBusy = false }
            do {
                let credential = try await oauthCoordinator.connect()
                var updated = profile; updated.channelID = credential.channelID; updated.channelName = credential.channelName
                store.upsertYouTubeProfile(updated)
                actionText = "Connected to \(credential.channelName ?? "YouTube")"
            } catch { actionText = error.localizedDescription }
        }
    }

    private func previewThumbnail() {
        guard let fixtureID = store.selectedFixtureID else { return }
        do {
            let snapshot = try RinkLensGameConfigurationResolver.resolve(fixtureID: fixtureID, catalogue: store.catalogue)
            Task { @MainActor in
                do {
                    let data = try await Task.detached(priority: .utility) {
                        try RinkLensFixtureThumbnailRenderer.renderJPEG(
                            snapshot: snapshot,
                            homeLogoData: RinkLensFixtureThumbnailAssets.logoData(fileName: snapshot.homeTeam.primaryLogoFileName),
                            awayLogoData: RinkLensFixtureThumbnailAssets.logoData(fileName: snapshot.awayTeam.primaryLogoFileName))
                    }.value
                    thumbnailPreview = UIImage(data: data); actionText = "Thumbnail preview rendered from fixture data"
                } catch { actionText = error.localizedDescription }
            }
        } catch { actionText = error.localizedDescription }
    }

    private func syncSelectedFixture() {
        guard let fixtureID = store.selectedFixtureID else { return }
        youtubeBusy = true; actionText = "Resolving selected fixture…"
        Task { @MainActor in
            defer { youtubeBusy = false }
            do {
                let snapshot = try RinkLensGameConfigurationResolver.resolve(fixtureID: fixtureID, catalogue: store.catalogue)
                let existing = store.catalogue.fixtures.first(where: { $0.id == fixtureID })?.youtubePublication
                let thumbnail = try await Task.detached(priority: .utility) {
                    try RinkLensFixtureThumbnailRenderer.renderJPEG(
                        snapshot: snapshot,
                        homeLogoData: RinkLensFixtureThumbnailAssets.logoData(fileName: snapshot.homeTeam.primaryLogoFileName),
                        awayLogoData: RinkLensFixtureThumbnailAssets.logoData(fileName: snapshot.awayTeam.primaryLogoFileName))
                }.value
                actionText = existing == nil ? "Creating YouTube event…" : "Updating YouTube event…"
                let result = try await YouTubePublishingService().publishOrUpdate(
                    snapshot: snapshot, existing: existing, thumbnailJPEG: thumbnail
                ) { acknowledged in
                    await MainActor.run {
                        RinkLensSeasonStore.shared.updatePublication(acknowledged, fixtureID: fixtureID, reason: "YouTube acknowledged stable broadcast identity")
                    }
                }
                store.updatePublication(result.reference, fixtureID: fixtureID, reason: "YouTube metadata, thumbnail and playlist synchronised")
                thumbnailPreview = UIImage(data: thumbnail)
                actionText = result.createdNewBroadcast ? "YouTube event created and ready" : "YouTube event updated"
            } catch {
                if var reference = store.catalogue.fixtures.first(where: { $0.id == fixtureID })?.youtubePublication {
                    reference.state = .failed; reference.failureMessage = error.localizedDescription
                    store.updatePublication(reference, fixtureID: fixtureID, reason: "YouTube operation failed after stable identity was retained")
                }
                actionText = error.localizedDescription
            }
        }
    }

    private func pairingText(_ fixture: RinkLensFixture) -> String {
        let home = store.catalogue.teams.first(where: { $0.id == fixture.homeTeamID })?.shortName ?? "Missing"
        let away = store.catalogue.teams.first(where: { $0.id == fixture.awayTeamID })?.shortName ?? "Missing"
        return "\(home) v \(away)"
    }

    private func youtubeBinding<Value>(_ fallback: RinkLensYouTubePublishingProfile, _ keyPath: WritableKeyPath<RinkLensYouTubePublishingProfile, Value>) -> Binding<Value> {
        Binding(
            get: { store.catalogue.youtubeProfiles.first(where: { $0.id == fallback.id })?[keyPath: keyPath] ?? fallback[keyPath: keyPath] },
            set: { value in var updated = store.catalogue.youtubeProfiles.first(where: { $0.id == fallback.id }) ?? fallback; updated[keyPath: keyPath] = value; store.upsertYouTubeProfile(updated) }
        )
    }

    private func optionalYouTubeBinding(_ fallback: RinkLensYouTubePublishingProfile, _ keyPath: WritableKeyPath<RinkLensYouTubePublishingProfile, String?>) -> Binding<String> {
        Binding(
            get: { store.catalogue.youtubeProfiles.first(where: { $0.id == fallback.id })?[keyPath: keyPath] ?? fallback[keyPath: keyPath] ?? "" },
            set: { value in var updated = store.catalogue.youtubeProfiles.first(where: { $0.id == fallback.id }) ?? fallback; let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines); updated[keyPath: keyPath] = cleaned.isEmpty ? nil : cleaned; store.upsertYouTubeProfile(updated) }
        )
    }
}
#endif
