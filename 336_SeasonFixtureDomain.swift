// Build 785 Recovery CV: season and fixture configuration only.
#if canImport(SwiftUI)
import Foundation

nonisolated enum RinkLensFixtureStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case scheduled, postponed, cancelled, completed
    var id: String { rawValue }
}

nonisolated struct RinkLensRosterPlayer: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var number: String
    var name: String
}

nonisolated struct RinkLensTeamProfile: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var fullName: String
    var shortName: String
    var scorebugAbbreviation: String
    var primaryLogoFileName: String? = nil
    var secondaryLogoFileName: String? = nil
    var primaryColourRGBA: String? = nil
    var secondaryColourRGBA: String? = nil
    var roster: [RinkLensRosterPlayer] = []
}

nonisolated struct RinkLensVenue: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
}

nonisolated enum RinkLensYouTubeVisibility: String, Codable, CaseIterable, Identifiable, Sendable {
    case `private`, unlisted, `public`
    var id: String { rawValue }
}

nonisolated enum RinkLensYouTubePlaylistPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, useExisting, createIfMissing
    var id: String { rawValue }
}

nonisolated struct RinkLensYouTubePublishingProfile: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var channelID: String? = nil
    var channelName: String? = nil
    var titleTemplate = "{HomeTeam} vs {AwayTeam} | Live Ice Hockey"
    var descriptionTemplate = "Watch {HomeTeam} take on {AwayTeam} live from {Venue}.\n\nFace-off: {StartTime}\nDate: {Date}"
    var categoryID = "17"
    var visibility: RinkLensYouTubeVisibility = .unlisted
    var madeForKids = false
    var enableDVR = true
    var recordFromStart = true
    var enableAutoStart = true
    var enableAutoStop = true
    var enableEmbed = true
    /// Stable YouTube liveStream identity selected for this season. This is
    /// metadata-control state only; stream transport remains StreamControlStore-owned.
    var streamID: String? = nil
    var playlistPolicy: RinkLensYouTubePlaylistPolicy = .none
    var playlistID: String? = nil
    var playlistName: String? = nil
    var thumbnailTemplateName = "Match Night"
    var publishingWindowDays = 14
}

/// Encoded presentation input for the existing scorebug owner. Keeping bytes in
/// the season domain avoids making SwiftUI colour conformances cross actors.
nonisolated struct RinkLensSeasonScorebugProfile: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var settingsData: Data
}

nonisolated struct RinkLensSeason: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var competitionName: String? = nil
    var startDate: Date? = nil
    var endDate: Date? = nil
    var defaultVenueID: UUID? = nil
    var scorebugProfileID: UUID? = nil
    var youtubeProfileID: UUID? = nil
    var teamIDs: [UUID] = []
    var fixtureIDs: [UUID] = []
}

nonisolated struct RinkLensFixture: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var seasonID: UUID
    var homeTeamID: UUID
    var awayTeamID: UUID
    var scheduledStart: Date
    var venueID: UUID? = nil
    var competitionNameOverride: String? = nil
    var status: RinkLensFixtureStatus = .scheduled
    var youtubePublication: RinkLensYouTubePublicationReference? = nil
}

nonisolated enum RinkLensYouTubePublicationState: String, Codable, Hashable, Sendable {
    case notPublished, creating, scheduled, ready, live, complete, failed
}

nonisolated struct RinkLensYouTubePublicationReference: Codable, Hashable, Sendable {
    var broadcastID: String
    var videoID: String? = nil
    var streamID: String? = nil
    var playlistItemID: String? = nil
    var publishedAt: Date? = nil
    var thumbnailUploaded = false
    var state: RinkLensYouTubePublicationState = .notPublished
    var failureMessage: String? = nil
}

nonisolated struct RinkLensSeasonCatalogue: Codable, Sendable {
    var seasons: [RinkLensSeason] = []
    var teams: [RinkLensTeamProfile] = []
    var venues: [RinkLensVenue] = []
    var fixtures: [RinkLensFixture] = []
    var scorebugProfiles: [RinkLensSeasonScorebugProfile] = []
    var youtubeProfiles: [RinkLensYouTubePublishingProfile] = []
}

nonisolated struct RinkLensResolvedTeam: Codable, Hashable, Sendable {
    let id: UUID
    let fullName: String
    let shortName: String
    let abbreviation: String
    let primaryLogoFileName: String?
    let secondaryLogoFileName: String?
    let primaryColourRGBA: String?
    let secondaryColourRGBA: String?
    let roster: [RinkLensRosterPlayer]
}

nonisolated struct RinkLensResolvedMediaMetadata: Codable, Hashable, Sendable {
    let recordingBaseName: String
    let clipBaseName: String
    let albumName: String
}

nonisolated struct RinkLensResolvedYouTubeMetadata: Codable, Hashable, Sendable {
    let title: String
    let description: String
    let categoryID: String
    let visibility: RinkLensYouTubeVisibility
    let madeForKids: Bool
    let enableDVR: Bool
    let recordFromStart: Bool
    let enableAutoStart: Bool
    let enableAutoStop: Bool
    let enableEmbed: Bool
    let streamID: String?
    let playlistPolicy: RinkLensYouTubePlaylistPolicy
    let playlistID: String?
    let playlistName: String?
    let thumbnailTemplateName: String
}

nonisolated struct RinkLensGameConfigurationSnapshot: Identifiable, Codable, Sendable {
    var id: UUID { fixtureID }
    let fixtureID: UUID
    let seasonID: UUID
    let seasonName: String
    let homeTeam: RinkLensResolvedTeam
    let awayTeam: RinkLensResolvedTeam
    let scheduledStart: Date
    let venue: RinkLensVenue?
    let competition: String?
    let scorebugProfileID: UUID?
    var scorebugSettingsData: Data? = nil
    let mediaMetadata: RinkLensResolvedMediaMetadata
    let youtubeMetadata: RinkLensResolvedYouTubeMetadata?
    let createdAt: Date
}

nonisolated enum RinkLensSeasonValidationError: LocalizedError, Equatable {
    case missingSeason, missingHomeTeam, missingAwayTeam, sameTeam
    case missingAbbreviation(String), invalidScheduledDate
    case unknownTemplateToken(String), invalidYouTubeTitleLength(Int)

    var errorDescription: String? {
        switch self {
        case .missingSeason: return "The fixture's season is missing."
        case .missingHomeTeam: return "The Home team is missing."
        case .missingAwayTeam: return "The Away team is missing."
        case .sameTeam: return "Home and Away teams must be different."
        case .missingAbbreviation(let name): return "A scorebug abbreviation is missing for \(name)."
        case .invalidScheduledDate: return "The scheduled date is invalid."
        case .unknownTemplateToken(let token): return "Unknown template token: {\(token)}."
        case .invalidYouTubeTitleLength(let count): return "YouTube titles must contain 1–100 characters; this title contains \(count)."
        }
    }
}

nonisolated struct RinkLensFixtureTemplateValues: Sendable {
    let homeTeam: String, awayTeam: String, homeShortName: String, awayShortName: String
    let date: String, startTime: String, venue: String, competition: String, season: String
    var dictionary: [String: String] {
        ["HomeTeam": homeTeam, "AwayTeam": awayTeam, "HomeShortName": homeShortName,
         "AwayShortName": awayShortName, "Date": date, "StartTime": startTime,
         "Venue": venue, "Competition": competition, "Season": season]
    }
}

nonisolated enum RinkLensFixtureTemplateEngine {
    static func resolve(_ template: String, values: RinkLensFixtureTemplateValues) throws -> String {
        let expression = try NSRegularExpression(pattern: #"\{([^{}]+)\}"#)
        var result = template
        let matches = expression.matches(in: template, range: NSRange(template.startIndex..<template.endIndex, in: template)).reversed()
        for match in matches {
            guard let tokenRange = Range(match.range(at: 1), in: result), let wholeRange = Range(match.range(at: 0), in: result) else { continue }
            let token = String(result[tokenRange])
            guard let replacement = values.dictionary[token] else { throw RinkLensSeasonValidationError.unknownTemplateToken(token) }
            result.replaceSubrange(wholeRange, with: replacement)
        }
        return result
    }

    static func validateYouTubeTitle(_ title: String) throws {
        guard (1...100).contains(title.count) else { throw RinkLensSeasonValidationError.invalidYouTubeTitleLength(title.count) }
    }
}

nonisolated enum RinkLensYouTubePublishingWindow {
    static func fixturesDue(
        fixtures: [RinkLensFixture],
        seasonID: UUID,
        days: Int,
        now: Date = .now
    ) -> [RinkLensFixture] {
        let boundary = now.addingTimeInterval(TimeInterval(max(0, days)) * 86_400)
        return fixtures.filter {
            $0.seasonID == seasonID && $0.status == .scheduled && $0.youtubePublication == nil
                && $0.scheduledStart >= now && $0.scheduledStart <= boundary
        }.sorted { $0.scheduledStart < $1.scheduledStart }
    }
}

nonisolated enum RinkLensGameConfigurationResolver {
    static func resolve(fixtureID: UUID, catalogue: RinkLensSeasonCatalogue, now: Date = .now) throws -> RinkLensGameConfigurationSnapshot {
        guard let fixture = catalogue.fixtures.first(where: { $0.id == fixtureID }), let season = catalogue.seasons.first(where: { $0.id == fixture.seasonID }) else { throw RinkLensSeasonValidationError.missingSeason }
        guard fixture.homeTeamID != fixture.awayTeamID else { throw RinkLensSeasonValidationError.sameTeam }
        guard let home = catalogue.teams.first(where: { $0.id == fixture.homeTeamID }) else { throw RinkLensSeasonValidationError.missingHomeTeam }
        guard let away = catalogue.teams.first(where: { $0.id == fixture.awayTeamID }) else { throw RinkLensSeasonValidationError.missingAwayTeam }
        guard !home.scorebugAbbreviation.isEmpty else { throw RinkLensSeasonValidationError.missingAbbreviation(home.fullName) }
        guard !away.scorebugAbbreviation.isEmpty else { throw RinkLensSeasonValidationError.missingAbbreviation(away.fullName) }
        guard fixture.scheduledStart.timeIntervalSince1970 > 0 else { throw RinkLensSeasonValidationError.invalidScheduledDate }
        let venue = fixture.venueID.flatMap { id in catalogue.venues.first(where: { $0.id == id }) } ?? season.defaultVenueID.flatMap { id in catalogue.venues.first(where: { $0.id == id }) }
        let competition = cleaned(fixture.competitionNameOverride) ?? cleaned(season.competitionName)
        let scorebugData = season.scorebugProfileID.flatMap { id in catalogue.scorebugProfiles.first(where: { $0.id == id })?.settingsData }
        let youtubeProfile = season.youtubeProfileID.flatMap { id in catalogue.youtubeProfiles.first(where: { $0.id == id }) }
        let values = templateValues(fixture: fixture, season: season, home: home, away: away, venue: venue, competition: competition)
        let youtube: RinkLensResolvedYouTubeMetadata?
        if let profile = youtubeProfile {
            let title = try RinkLensFixtureTemplateEngine.resolve(profile.titleTemplate, values: values)
            try RinkLensFixtureTemplateEngine.validateYouTubeTitle(title)
            youtube = .init(title: title, description: try RinkLensFixtureTemplateEngine.resolve(profile.descriptionTemplate, values: values), categoryID: profile.categoryID, visibility: profile.visibility, madeForKids: profile.madeForKids, enableDVR: profile.enableDVR, recordFromStart: profile.recordFromStart, enableAutoStart: profile.enableAutoStart, enableAutoStop: profile.enableAutoStop, enableEmbed: profile.enableEmbed, streamID: profile.streamID, playlistPolicy: profile.playlistPolicy, playlistID: profile.playlistID, playlistName: profile.playlistName, thumbnailTemplateName: profile.thumbnailTemplateName)
        } else { youtube = nil }
        let date = fileDate.string(from: fixture.scheduledStart)
        let pairing = filenameComponent("\(home.shortName)-v-\(away.shortName)")
        return .init(fixtureID: fixture.id, seasonID: season.id, seasonName: season.name,
                     homeTeam: resolved(home), awayTeam: resolved(away), scheduledStart: fixture.scheduledStart,
                     venue: venue, competition: competition, scorebugProfileID: season.scorebugProfileID, scorebugSettingsData: scorebugData,
                     mediaMetadata: .init(recordingBaseName: "\(date)_\(pairing)_FullGame", clipBaseName: "\(date)_\(pairing)", albumName: "\(home.shortName) v \(away.shortName) - \(albumDate.string(from: fixture.scheduledStart))"),
                     youtubeMetadata: youtube, createdAt: now)
    }

    private static func resolved(_ value: RinkLensTeamProfile) -> RinkLensResolvedTeam {
        .init(id: value.id, fullName: value.fullName, shortName: value.shortName, abbreviation: value.scorebugAbbreviation, primaryLogoFileName: value.primaryLogoFileName, secondaryLogoFileName: value.secondaryLogoFileName, primaryColourRGBA: value.primaryColourRGBA, secondaryColourRGBA: value.secondaryColourRGBA, roster: value.roster)
    }
    private static func cleaned(_ value: String?) -> String? { let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""; return text.isEmpty ? nil : text }
    private static func filenameComponent(_ value: String) -> String { value.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).inverted).filter { !$0.isEmpty }.joined(separator: "-") }
    private static func templateValues(fixture: RinkLensFixture, season: RinkLensSeason, home: RinkLensTeamProfile, away: RinkLensTeamProfile, venue: RinkLensVenue?, competition: String?) -> RinkLensFixtureTemplateValues {
        .init(homeTeam: home.fullName, awayTeam: away.fullName, homeShortName: home.shortName, awayShortName: away.shortName, date: displayDate.string(from: fixture.scheduledStart), startTime: displayTime.string(from: fixture.scheduledStart), venue: venue?.name ?? "", competition: competition ?? "", season: season.name)
    }
    private static let fileDate: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f }()
    private static let albumDate: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "d MMM yyyy"; return f }()
    private static let displayDate: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateStyle = .long; return f }()
    private static let displayTime: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "HH:mm"; return f }()
}

nonisolated enum RinkLensRecordingFilenameResolver {
    static func filename(
        resolvedBaseName: String?,
        fallbackPrefix: String,
        homeTeam: String,
        awayTeam: String,
        ext: String,
        now: Date = .now
    ) -> String {
        if let resolvedBaseName {
            let safe = sanitize(resolvedBaseName)
            if !safe.isEmpty { return "\(safe).\(ext)" }
        }
        let teams = sanitize("\(homeTeam)_vs_\(awayTeam)")
        return "\(timestamp.string(from: now))_\(teams)_\(fallbackPrefix).\(ext)"
    }

    private static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: " ", with: "_")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_- ")).inverted)
            .joined()
    }

    private static let timestamp: DateFormatter = {
        let value = DateFormatter(); value.locale = Locale(identifier: "en_US_POSIX"); value.dateFormat = "yyyyMMdd_HHmmss"; return value
    }()
}
#endif
