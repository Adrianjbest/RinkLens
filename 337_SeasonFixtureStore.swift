// Build 785 Recovery CV: fixture CSV preview boundary.
#if canImport(SwiftUI)
import Foundation
import SwiftUI

@MainActor
final class RinkLensGameConfigurationStore: ObservableObject {
    @Published private(set) var activeSnapshot: RinkLensGameConfigurationSnapshot?

    func load(_ snapshot: RinkLensGameConfigurationSnapshot, source: String, reason: String) {
        let previous = activeSnapshot?.fixtureID.uuidString ?? "none"
        activeSnapshot = snapshot
        RinkLensStructuredEventLogger.shared.record(
            domain: .gameConfiguration, event: "snapshot_created", entityID: snapshot.fixtureID.uuidString,
            previous: ["fixtureID": previous], next: ["fixtureID": snapshot.fixtureID.uuidString],
            source: source, reason: reason, authoritativeOwner: "RinkLensGameConfigurationStore")
    }
}

@MainActor
final class RinkLensSeasonStore: ObservableObject {
    static let shared = RinkLensSeasonStore()
    @Published private(set) var catalogue: RinkLensSeasonCatalogue
    @Published private(set) var selectedSeasonID: UUID?
    @Published private(set) var selectedFixtureID: UUID?
    @Published private(set) var lastActionText = "Season setup ready"
    let gameConfigurationStore = RinkLensGameConfigurationStore()

    private let defaults: UserDefaults
    private static let catalogueKey = "rinklens.season.catalogue.v1"
    private static let seasonKey = "rinklens.season.selectedSeasonID"
    private static let fixtureKey = "rinklens.season.selectedFixtureID"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.catalogueKey), let value = try? JSONDecoder().decode(RinkLensSeasonCatalogue.self, from: data) { catalogue = value }
        else { catalogue = .init() }
        selectedSeasonID = defaults.string(forKey: Self.seasonKey).flatMap(UUID.init(uuidString:))
        selectedFixtureID = defaults.string(forKey: Self.fixtureKey).flatMap(UUID.init(uuidString:))
    }

    var selectedSeason: RinkLensSeason? { selectedSeasonID.flatMap { id in catalogue.seasons.first(where: { $0.id == id }) } }
    var selectedFixture: RinkLensFixture? { selectedFixtureID.flatMap { id in catalogue.fixtures.first(where: { $0.id == id }) } }

    func createSeason(name: String, competition: String?) -> UUID {
        let value = RinkLensSeason(name: name.trimmingCharacters(in: .whitespacesAndNewlines), competitionName: competition?.trimmingCharacters(in: .whitespacesAndNewlines))
        catalogue.seasons.append(value); selectedSeasonID = value.id; selectedFixtureID = nil
        persist(event: "season_created", entityID: value.id, reason: "Operator created season")
        return value.id
    }

    func selectSeason(_ id: UUID?) { selectedSeasonID = id; selectedFixtureID = nil; persistSelection() }
    func selectFixture(_ id: UUID?) { selectedFixtureID = id; persistSelection() }

    func upsertTeam(_ value: RinkLensTeamProfile) {
        if let index = catalogue.teams.firstIndex(where: { $0.id == value.id }) { catalogue.teams[index] = value }
        else { catalogue.teams.append(value) }
        persist(event: "team_profile_saved", entityID: value.id, reason: "Reusable team committed")
    }

    func upsertVenue(_ value: RinkLensVenue) {
        if let index = catalogue.venues.firstIndex(where: { $0.id == value.id }) { catalogue.venues[index] = value }
        else { catalogue.venues.append(value) }
        persist(event: "venue_saved", entityID: value.id, reason: "Venue committed")
    }

    func upsertSeason(_ value: RinkLensSeason) {
        if let index = catalogue.seasons.firstIndex(where: { $0.id == value.id }) { catalogue.seasons[index] = value }
        else { catalogue.seasons.append(value) }
        persist(event: "season_saved", entityID: value.id, reason: "Season defaults committed")
    }

    func upsertYouTubeProfile(_ value: RinkLensYouTubePublishingProfile) {
        if let index = catalogue.youtubeProfiles.firstIndex(where: { $0.id == value.id }) { catalogue.youtubeProfiles[index] = value }
        else { catalogue.youtubeProfiles.append(value) }
        persist(event: "youtube_profile_saved", entityID: value.id, reason: "YouTube defaults committed")
    }

    func upsertScorebugProfile(_ value: RinkLensSeasonScorebugProfile) {
        if let index = catalogue.scorebugProfiles.firstIndex(where: { $0.id == value.id }) { catalogue.scorebugProfiles[index] = value }
        else { catalogue.scorebugProfiles.append(value) }
        persist(event: "scorebug_profile_saved", entityID: value.id, reason: "Existing scorebug-owner settings referenced by season")
    }

    func upsertFixture(_ value: RinkLensFixture) {
        if let index = catalogue.fixtures.firstIndex(where: { $0.id == value.id }) { catalogue.fixtures[index] = value }
        else { catalogue.fixtures.append(value) }
        if let index = catalogue.seasons.firstIndex(where: { $0.id == value.seasonID }), !catalogue.seasons[index].fixtureIDs.contains(value.id) { catalogue.seasons[index].fixtureIDs.append(value.id) }
        persist(event: "fixture_saved", entityID: value.id, reason: "Fixture committed")
    }

    func commitImportedFixtures(_ values: [RinkLensFixture]) {
        for value in values {
            if let index = catalogue.fixtures.firstIndex(where: { $0.id == value.id }) { catalogue.fixtures[index] = value }
            else { catalogue.fixtures.append(value) }
            if let index = catalogue.seasons.firstIndex(where: { $0.id == value.seasonID }), !catalogue.seasons[index].fixtureIDs.contains(value.id) { catalogue.seasons[index].fixtureIDs.append(value.id) }
        }
        persist(event: "fixtures_imported", entityID: selectedSeasonID, reason: "Validated fixture import committed")
    }

    func updatePublication(_ reference: RinkLensYouTubePublicationReference?, fixtureID: UUID, reason: String) {
        guard let index = catalogue.fixtures.firstIndex(where: { $0.id == fixtureID }) else { return }
        catalogue.fixtures[index].youtubePublication = reference
        persist(event: "youtube_publication_updated", entityID: fixtureID, reason: reason)
    }

    struct TeamIdentityMigrationResult: Equatable {
        let teamIDs: [UUID]
        let scorebugProfileID: UUID?
    }

    /// Explicit, idempotent conversion boundary for the historical paired-team
    /// profile. The source value is read only and remains available for rollback
    /// until a physical migration acceptance test permits its later deletion.
    func commitTeamIdentityMigration(_ source: TeamIdentityTemplate, into seasonID: UUID) throws -> TeamIdentityMigrationResult {
        guard let seasonIndex = catalogue.seasons.firstIndex(where: { $0.id == seasonID }) else {
            throw RinkLensSeasonValidationError.missingSeason
        }
        func resolvedTeam(name: String, logoFileName: String?) -> RinkLensTeamProfile {
            if let existing = catalogue.teams.first(where: { $0.fullName.caseInsensitiveCompare(name) == .orderedSame }) {
                return existing
            }
            let abbreviation = String(name.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.compactMap(\.first).prefix(5)).uppercased()
            let value = RinkLensTeamProfile(fullName: name, shortName: name, scorebugAbbreviation: abbreviation.isEmpty ? String(name.prefix(5)).uppercased() : abbreviation, primaryLogoFileName: logoFileName)
            catalogue.teams.append(value)
            return value
        }
        let home = resolvedTeam(name: source.homeTeamName, logoFileName: source.homeLogoFileName)
        let away = resolvedTeam(name: source.awayTeamName, logoFileName: source.awayLogoFileName)
        var season = catalogue.seasons[seasonIndex]
        for id in [home.id, away.id] where !season.teamIDs.contains(id) { season.teamIDs.append(id) }
        if season.scorebugProfileID == nil, let settings = source.scoreboardSettings,
           let data = try? JSONEncoder().encode(settings) {
            let profile = RinkLensSeasonScorebugProfile(name: source.name, settingsData: data)
            catalogue.scorebugProfiles.append(profile); season.scorebugProfileID = profile.id
        }
        catalogue.seasons[seasonIndex] = season
        persist(event: "legacy_team_profile_migrated", entityID: seasonID, reason: "Operator explicitly converted existing paired-team profile without deleting source")
        return .init(teamIDs: [home.id, away.id], scorebugProfileID: season.scorebugProfileID)
    }

    func loadSelectedFixture(source: String, reason: String) throws -> RinkLensGameConfigurationSnapshot {
        guard let selectedFixtureID else { throw RinkLensSeasonValidationError.missingSeason }
        let snapshot = try RinkLensGameConfigurationResolver.resolve(fixtureID: selectedFixtureID, catalogue: catalogue)
        gameConfigurationStore.load(snapshot, source: source, reason: reason)
        lastActionText = "Loaded \(snapshot.homeTeam.shortName) v \(snapshot.awayTeam.shortName)"
        return snapshot
    }

    func fixtures(for seasonID: UUID) -> [RinkLensFixture] { catalogue.fixtures.filter { $0.seasonID == seasonID }.sorted { $0.scheduledStart < $1.scheduledStart } }

    private func persist(event: String, entityID: UUID?, reason: String) {
        if let data = try? JSONEncoder().encode(catalogue) { defaults.set(data, forKey: Self.catalogueKey) }
        persistSelection()
        RinkLensStructuredEventLogger.shared.record(domain: .season, event: event, entityID: entityID?.uuidString,
            next: ["seasons": String(catalogue.seasons.count), "teams": String(catalogue.teams.count), "fixtures": String(catalogue.fixtures.count)],
            source: "RinkLensSeasonStore", reason: reason, authoritativeOwner: "RinkLensSeasonStore")
    }

    private func persistSelection() {
        defaults.set(selectedSeasonID?.uuidString, forKey: Self.seasonKey)
        defaults.set(selectedFixtureID?.uuidString, forKey: Self.fixtureKey)
    }
}

nonisolated struct RinkLensFixtureImportIssue: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case malformedRow, badDate, unknownTeam, duplicate }
    let id = UUID()
    let row: Int
    let kind: Kind
    let message: String
}

nonisolated struct RinkLensFixtureImportPreview: Sendable {
    let fixtures: [RinkLensFixture]
    let issues: [RinkLensFixtureImportIssue]
    var canCommit: Bool { issues.isEmpty && !fixtures.isEmpty }
}

nonisolated enum RinkLensFixtureCSVImporter {
    static func preview(csv: String, seasonID: UUID, teams: [RinkLensTeamProfile], venues: [RinkLensVenue], existing: [RinkLensFixture], calendar: Calendar = .current) -> RinkLensFixtureImportPreview {
        let rows = csv.split(whereSeparator: { $0.isNewline }).map(String.init)
        guard rows.count > 1 else { return .init(fixtures: [], issues: [.init(row: 1, kind: .malformedRow, message: "CSV requires a header and fixture row.")]) }
        let header = parse(rows[0]).map { $0.lowercased() }
        let required = ["date", "time", "home", "away", "venue", "competition"]
        guard required.allSatisfy(header.contains) else { return .init(fixtures: [], issues: [.init(row: 1, kind: .malformedRow, message: "Header must contain date,time,home,away,venue,competition.")]) }
        let index = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($0.element, $0.offset) })
        var output: [RinkLensFixture] = [], issues: [RinkLensFixtureImportIssue] = []
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HH:mm"; formatter.isLenient = false
        func team(_ name: String) -> RinkLensTeamProfile? { teams.first { $0.fullName.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame || $0.shortName.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame } }
        for (offset, raw) in rows.dropFirst().enumerated() {
            let row = offset + 2, columns = parse(raw)
            guard columns.count >= header.count,
                  let di = index["date"], let ti = index["time"], let hi = index["home"], let ai = index["away"], let vi = index["venue"], let ci = index["competition"] else { issues.append(.init(row: row, kind: .malformedRow, message: "Row does not match header.")); continue }
            guard let date = formatter.date(from: "\(columns[di]) \(columns[ti])") else { issues.append(.init(row: row, kind: .badDate, message: "Invalid date or time.")); continue }
            guard let home = team(columns[hi]) else { issues.append(.init(row: row, kind: .unknownTeam, message: "Unknown Home team: \(columns[hi]).")); continue }
            guard let away = team(columns[ai]) else { issues.append(.init(row: row, kind: .unknownTeam, message: "Unknown Away team: \(columns[ai]).")); continue }
            if (existing + output).contains(where: { $0.seasonID == seasonID && $0.homeTeamID == home.id && $0.awayTeamID == away.id && abs($0.scheduledStart.timeIntervalSince(date)) < 60 }) { issues.append(.init(row: row, kind: .duplicate, message: "Duplicate fixture.")); continue }
            let venueName = columns[vi].trimmingCharacters(in: .whitespacesAndNewlines)
            let venueID = venues.first { $0.name.caseInsensitiveCompare(venueName) == .orderedSame }?.id
            output.append(.init(seasonID: seasonID, homeTeamID: home.id, awayTeamID: away.id, scheduledStart: date, venueID: venueID, competitionNameOverride: columns[ci].trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return .init(fixtures: output, issues: issues)
    }

    private static func parse(_ row: String) -> [String] {
        var fields: [String] = [], field = "", quoted = false
        for character in row {
            if character == "\"" { quoted.toggle() }
            else if character == "," && !quoted { fields.append(field); field = "" }
            else { field.append(character) }
        }
        fields.append(field); return fields
    }
}
#endif
