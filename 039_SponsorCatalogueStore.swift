// BUILD 699 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(ImageIO)
import ImageIO
#endif

#if canImport(UIKit) && canImport(ImageIO)
private nonisolated struct RinkLensDecodedSponsorLogo: @unchecked Sendable {
    let id: UUID?
    let fingerprint: Int
    let cgImage: CGImage
}

private nonisolated struct RinkLensDecodedSponsorLogoBatch: @unchecked Sendable {
    let league: RinkLensDecodedSponsorLogo?
    let sponsors: [RinkLensDecodedSponsorLogo]
}

private nonisolated func rinkLensDecodeSponsorThumbnail(
    id: UUID?,
    fingerprint: Int,
    data: Data,
    maximumPixelSize: Int = 512
) -> RinkLensDecodedSponsorLogo? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        kCGImageSourceShouldCacheImmediately: true
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return RinkLensDecodedSponsorLogo(id: id, fingerprint: fingerprint, cgImage: image)
}
#endif

// MARK: - Sponsor Catalogue / Placement Rules

/// Central, lightweight sponsor catalogue for the NextGen sponsor module.
///
/// The catalogue is intentionally independent from the live Broadcast renderer.
/// It lets operators create sponsors once, assign them to one or more broadcast
/// moments, prepare league branding, and map home players to penalty sponsors.
@MainActor
final class SponsorCatalogueStore: ObservableObject {
    static let shared = SponsorCatalogueStore()

    @Published private(set) var configuration: SponsorCatalogueConfiguration
    /// Physical acknowledgement that the lock-protected output snapshot has
    /// accepted a materially different sponsor configuration. Stream/recording
    /// consumers observe this boundary instead of polling the editable catalogue.
    @Published private(set) var recordingOverlayRevision: UInt64 = 0
    #if canImport(UIKit)
    @Published private(set) var imageCacheRevision: UInt64 = 0

    private struct CachedSponsorLogo {
        let fingerprint: Int
        let image: UIImage
    }

    private var sponsorLogoCache: [UUID: CachedSponsorLogo] = [:]
    private var leagueLogoCache: CachedSponsorLogo?
    private var imageCachePrewarmInFlight = false
    private var imageCacheGeneration: UInt64 = 0
    #endif

    private let defaultsKey = "rinklens.sponsor.catalogue.configuration.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(SponsorCatalogueConfiguration.self, from: data) {
            configuration = decoded.normalized()
        } else {
            configuration = SponsorCatalogueConfiguration.defaults
        }
        updateRecordingOverlaySnapshot()
    }

    func save(source: String = "SponsorCatalogueStore", reason: String = "Persist sponsor catalogue") {
        let normalized = configuration.normalized()
        configuration = normalized
        if let data = try? JSONEncoder().encode(normalized) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        updateRecordingOverlaySnapshot()
        if RinkLensRiskFeaturePolicy.isEnabled(.sponsorRosterAuthorityV2) {
            RinkLensStructuredEventLogger.shared.record(
            domain: .sponsorRoster,
            event: "catalogue_saved",
            next: summary(configuration),
            source: source,
            reason: reason
            )
        }
    }

    func mutate(
        event: String,
        entityID: String? = nil,
        source: String = "SponsorCatalogueStore",
        reason: String,
        _ update: (inout SponsorCatalogueConfiguration) -> Void
    ) {
        let previous = summary(configuration)
        update(&configuration)
        configuration = configuration.normalized()
        save(source: source, reason: reason)
        if RinkLensRiskFeaturePolicy.isEnabled(.sponsorRosterAuthorityV2) {
            RinkLensStructuredEventLogger.shared.record(
                domain: .sponsorRoster,
                event: event,
                entityID: entityID,
                previous: previous,
                next: summary(configuration),
                source: source,
                reason: reason
            )
        }
    }

    private func summary(_ value: SponsorCatalogueConfiguration) -> [String: String] {
        [
            "league": value.league.name,
            "leagueEnabled": String(value.league.isEnabled),
            "sponsors": String(value.sponsors.count),
            "homeRoster": String(value.homeRoster.count),
            "intermissionEnabled": String(value.intermission.isEnabled),
            "outputOverlay": String(value.overlay.isOutputOverlayEnabled)
        ]
    }

    func setLeagueName(_ name: String) { mutate(event: "league_changed", entityID: "name", reason: "Operator changed league name") { $0.league.name = name } }
    func setLeagueEnabled(_ enabled: Bool) { mutate(event: "league_changed", entityID: "enabled", reason: "Operator changed league visibility") { $0.league.isEnabled = enabled } }
    func setPlacement(_ slot: SponsorPlacementSlot, sponsorID: UUID?) {
        mutate(event: "placement_changed", entityID: slot.rawValue, reason: "Operator changed sponsor placement") { value in
            switch slot {
            case .season: value.placements.seasonSponsorID = sponsorID
            case .game: value.placements.gameSponsorID = sponsorID
            case .homeGoal: value.placements.homeGoalSponsorID = sponsorID
            case .awayGoal: value.placements.awayGoalSponsorID = sponsorID
            case .homePenaltyDefault: value.placements.homePenaltyDefaultSponsorID = sponsorID
            case .awayPenalty: value.placements.awayPenaltySponsorID = sponsorID
            case .finalScore: value.placements.finalScoreSponsorID = sponsorID
            }
        }
    }
    func updateIntermission(_ update: (inout SponsorIntermissionConfiguration) -> Void) {
        mutate(event: "intermission_changed", reason: "Operator changed intermission sponsor policy") { update(&$0.intermission) }
    }
    func importHomeRoster(_ players: [SponsorPlayerAssignment]) {
        mutate(event: "roster_imported", reason: "Operator imported Home roster") { $0.homeRoster.append(contentsOf: players) }
    }

    func replaceHomeRoster(_ players: [SponsorPlayerAssignment], source: String, reason: String) {
        mutate(event: "roster_replaced", entityID: "active-game-home", source: source, reason: reason) {
            $0.homeRoster = players
        }
    }

    func setOutputOverlayEnabled(_ enabled: Bool) {
        mutate(event: "overlay_setting_changed", entityID: "output", reason: "Operator changed output overlay") { $0.overlay.isOutputOverlayEnabled = enabled }
    }

    func setBroadcastPreviewOverlayVisible(_ visible: Bool) {
        mutate(event: "overlay_setting_changed", entityID: "preview", reason: "Operator changed Broadcast preview overlay") { $0.overlay.showOverlayOnBroadcastScreen = visible }
    }

    private func updateRecordingOverlaySnapshot() {
        if SponsorRecordingOverlaySnapshotStore.shared.update(from: configuration) {
            recordingOverlayRevision &+= 1
        }
    }

    func refreshRecordingOverlaySnapshot(reason: String = "manual refresh") {
        // TEST1: recording uses a thread-safe snapshot so the 60fps writer does
        // not touch the SwiftUI sponsor catalogue every frame. Refresh it at
        // recording start/export boundaries so the recorded video matches the
        // latest visible Broadcast sponsor configuration.
        if SponsorRecordingOverlaySnapshotStore.shared.update(from: configuration) {
            recordingOverlayRevision &+= 1
        }
        MainThreadStallMonitor.shared.traceSponsorOverlay("recording sponsor snapshot refreshed reason=\(reason)")
    }

    func addSponsor() {
        let sponsor = SponsorCatalogueSponsor(
            name: "New Sponsor",
            contactName: "",
            emailAddress: "",
            notes: "",
            isActive: true,
            logoData: nil
        )
        configuration.sponsors.append(sponsor)
        save()
    }

    func updateSponsor(id: UUID, _ update: (inout SponsorCatalogueSponsor) -> Void) {
        guard let index = configuration.sponsors.firstIndex(where: { $0.id == id }) else { return }
        update(&configuration.sponsors[index])
        save()
    }

    func deleteSponsor(id: UUID) {
        #if canImport(UIKit)
        sponsorLogoCache[id] = nil
        imageCacheRevision &+= 1
        #endif
        configuration.sponsors.removeAll { $0.id == id }
        configuration.placements.clearSponsor(id)
        for index in configuration.homeRoster.indices where configuration.homeRoster[index].sponsorID == id {
            configuration.homeRoster[index].sponsorID = nil
        }
        save()
    }

    func addHomePlayer() {
        configuration.homeRoster.append(
            SponsorPlayerAssignment(number: "", name: "New Player", sponsorID: nil)
        )
        save()
    }

    func updateHomePlayer(id: UUID, _ update: (inout SponsorPlayerAssignment) -> Void) {
        guard let index = configuration.homeRoster.firstIndex(where: { $0.id == id }) else { return }
        update(&configuration.homeRoster[index])
        save()
    }

    func deleteHomePlayer(id: UUID) {
        configuration.homeRoster.removeAll { $0.id == id }
        save()
    }

    func sponsorName(for id: UUID?) -> String {
        guard let id else { return "Not assigned" }
        return configuration.sponsors.first(where: { $0.id == id })?.displayName ?? "Missing sponsor"
    }

    func activeSponsorOptions() -> [SponsorCatalogueSponsor] {
        configuration.sponsors.filter { $0.isActive }
    }

    // MARK: - ADS1 Live Sponsor Resolution

    /// Resolves a sponsor for a penalty popup at the moment the event is created.
    /// HOME penalties prefer the mapped player sponsor, then the home default.
    /// AWAY penalties use the away penalty placement.
    func resolvedPenaltySponsor(for event: BroadcastEvent) -> SponsorResolvedBroadcastSponsor? {
        guard [.penalty, .penalties, .powerPlayStart, .penaltyEnd].contains(event.type) else { return nil }
        guard let team = event.team else { return nil }

        switch team {
        case .home:
            let playerNumber = firstPenaltyPlayerNumber(for: .home, event: event)
            if let playerNumber,
               let player = homeRosterPlayer(number: playerNumber),
               let sponsor = activeSponsor(id: player.sponsorID) {
                return SponsorResolvedBroadcastSponsor(
                    sponsorID: sponsor.id,
                    title: sponsor.displayName,
                    subtitle: "PLAYER PENALTY SPONSOR",
                    playerLabel: player.displayName,
                    logoData: sponsor.logoData
                )
            }

            if let sponsor = activeSponsor(id: configuration.placements.homePenaltyDefaultSponsorID) {
                return SponsorResolvedBroadcastSponsor(
                    sponsorID: sponsor.id,
                    title: sponsor.displayName,
                    subtitle: "HOME PENALTY SPONSOR",
                    playerLabel: playerNumber.map { "#\($0)" },
                    logoData: sponsor.logoData
                )
            }

        case .away:
            let playerNumber = firstPenaltyPlayerNumber(for: .away, event: event)
            if let sponsor = activeSponsor(id: configuration.placements.awayPenaltySponsorID) {
                return SponsorResolvedBroadcastSponsor(
                    sponsorID: sponsor.id,
                    title: sponsor.displayName,
                    subtitle: "AWAY PENALTY SPONSOR",
                    playerLabel: playerNumber.map { "#\($0)" },
                    logoData: sponsor.logoData
                )
            }
        }

        return nil
    }

    func shouldShowIntermission(afterCompletedPeriod completedPeriod: Int) -> Bool {
        guard configuration.intermission.isEnabled else { return false }
        switch completedPeriod {
        case 1:
            return configuration.intermission.showBetweenFirstAndSecond
        case 2:
            return configuration.intermission.showBetweenSecondAndThird
        default:
            return false
        }
    }

    func resolvedIntermissionSlides() -> [SponsorResolvedBroadcastSponsor] {
        let intermission = configuration.intermission
        let placements = configuration.placements
        var slides: [SponsorResolvedBroadcastSponsor] = []
        var seen: Set<UUID> = []

        func appendSponsor(id: UUID?, subtitle: String, playerLabel: String? = nil) {
            guard let sponsor = activeSponsor(id: id), !seen.contains(sponsor.id) else { return }
            seen.insert(sponsor.id)
            slides.append(
                SponsorResolvedBroadcastSponsor(
                    sponsorID: sponsor.id,
                    title: sponsor.displayName,
                    subtitle: subtitle,
                    playerLabel: playerLabel,
                    logoData: sponsor.logoData
                )
            )
        }

        if intermission.includeSeasonSponsor {
            appendSponsor(id: placements.seasonSponsorID, subtitle: "SEASON SPONSOR")
        }
        if intermission.includeGameSponsor {
            appendSponsor(id: placements.gameSponsorID, subtitle: "GAME SPONSOR")
        }
        if intermission.includeGoalSponsors {
            appendSponsor(id: placements.homeGoalSponsorID, subtitle: "HOME GOAL SPONSOR")
            appendSponsor(id: placements.awayGoalSponsorID, subtitle: "AWAY GOAL SPONSOR")
        }
        if intermission.includePenaltySponsors {
            for player in configuration.homeRoster {
                appendSponsor(id: player.sponsorID, subtitle: "PLAYER PENALTY SPONSOR", playerLabel: player.displayName)
            }
            appendSponsor(id: placements.homePenaltyDefaultSponsorID, subtitle: "HOME PENALTY SPONSOR")
            appendSponsor(id: placements.awayPenaltySponsorID, subtitle: "AWAY PENALTY SPONSOR")
        }
        if intermission.includeFinalScoreSponsor {
            appendSponsor(id: placements.finalScoreSponsorID, subtitle: "FINAL SCORE SPONSOR")
        }
        if intermission.includeAllActiveCatalogueSponsors {
            for sponsor in activeSponsorOptions() where !seen.contains(sponsor.id) {
                seen.insert(sponsor.id)
                slides.append(
                    SponsorResolvedBroadcastSponsor(
                        sponsorID: sponsor.id,
                        title: sponsor.displayName,
                        subtitle: "CLUB PARTNER",
                        playerLabel: nil,
                        logoData: sponsor.logoData
                    )
                )
            }
        }

        return slides
    }

    private func activeSponsor(id: UUID?) -> SponsorCatalogueSponsor? {
        guard let id else { return nil }
        return configuration.sponsors.first(where: { $0.id == id && $0.isActive })
    }

    /// Team roster lookup used by the frozen Home penalty-player recognition
    /// service. A sponsor assignment is optional and never gates roster validity.
    func homeRosterPlayer(number: Int) -> SponsorPlayerAssignment? {
        let expected = String(number)
        return configuration.homeRoster.first { player in
            player.number.trimmingCharacters(in: .whitespacesAndNewlines) == expected
        }
    }

    private func firstPenaltyPlayerNumber(for team: Team, event: BroadcastEvent) -> Int? {
        // Build 682: the event's immutable recognised player belongs to its
        // penaltyLifecycleID. Using the first current team slot here allowed a
        // later Slot 1/Slot 2 compaction to give #45 another player's sponsor.
        // Prefer the frozen event identity and use the snapshot only for legacy
        // events that pre-date recognisedPenaltyPlayerNumber.
        if let recognised = event.recognisedPenaltyPlayerNumber {
            return recognised
        }
        return event.penaltyClockSnapshot
            .filter { $0.team == team }
            .sorted { lhs, rhs in
                if lhs.slot != rhs.slot { return lhs.slot < rhs.slot }
                return (lhs.remainingSeconds ?? 0) > (rhs.remainingSeconds ?? 0)
            }
            .compactMap(\.playerNumber)
            .first
    }

    func setLeagueLogo(data: Data?) {
        #if canImport(UIKit)
        leagueLogoCache = nil
        imageCacheRevision &+= 1
        #endif
        configuration.league.logoData = data
        save()
        prewarmImageCache(source: "SponsorCatalogueStore", reason: "League logo changed")
    }

    func setSponsorLogo(id: UUID, data: Data?) {
        #if canImport(UIKit)
        sponsorLogoCache[id] = nil
        imageCacheRevision &+= 1
        #endif
        updateSponsor(id: id) { sponsor in
            sponsor.logoData = data
        }
        prewarmImageCache(source: "SponsorCatalogueStore", reason: "Sponsor logo changed")
    }

    #if canImport(UIKit)
    func logoImage(for sponsorID: UUID?) -> UIImage? {
        guard let sponsorID,
              let data = configuration.sponsors.first(where: { $0.id == sponsorID })?.logoData else { return nil }
        guard RinkLensRiskFeaturePolicy.isEnabled(.sponsorAsyncLogoCacheV21) else {
            return UIImage(data: data)
        }
        let fingerprint = imageFingerprint(data)
        return sponsorLogoCache[sponsorID].flatMap { $0.fingerprint == fingerprint ? $0.image : nil }
    }

    var leagueLogoImage: UIImage? {
        guard let data = configuration.league.logoData else { return nil }
        guard RinkLensRiskFeaturePolicy.isEnabled(.sponsorAsyncLogoCacheV21) else {
            return UIImage(data: data)
        }
        let fingerprint = imageFingerprint(data)
        guard let cached = leagueLogoCache, cached.fingerprint == fingerprint else { return nil }
        return cached.image
    }

    func prewarmImageCache(source: String, reason: String) {
        guard RinkLensRiskFeaturePolicy.isEnabled(.sponsorAsyncLogoCacheV21) else { return }
        guard !imageCachePrewarmInFlight else { return }

        let leaguePayload: (Int, Data)? = configuration.league.logoData.map { (imageFingerprint($0), $0) }
        let sponsorPayloads: [(UUID, Int, Data)] = configuration.sponsors.compactMap { sponsor in
            guard let data = sponsor.logoData else { return nil }
            return (sponsor.id, imageFingerprint(data), data)
        }
        let leagueNeedsDecode = leaguePayload.map { payload in
            leagueLogoCache?.fingerprint != payload.0
        } ?? false
        let sponsorNeedsDecode = sponsorPayloads.contains { payload in
            sponsorLogoCache[payload.0]?.fingerprint != payload.1
        }
        guard leagueNeedsDecode || sponsorNeedsDecode else { return }

        imageCachePrewarmInFlight = true
        imageCacheGeneration &+= 1
        let generation = imageCacheGeneration
        let transactionID = UUID()
        RinkLensStructuredEventLogger.shared.record(
            domain: .sponsorRoster,
            event: "sponsor_logo_cache_prewarm_started",
            entityID: "logo-cache",
            previous: ["generation": String(generation - 1), "inFlight": "false"],
            next: ["generation": String(generation), "inFlight": "true", "logoCount": String(sponsorPayloads.count + (leaguePayload == nil ? 0 : 1))],
            source: source,
            reason: reason,
            transactionID: transactionID,
            authoritativeOwner: "SponsorCatalogueStore"
        )

        Task { @MainActor [weak self] in
            let batch = await Task.detached(priority: .utility) {
                #if canImport(ImageIO)
                let league = leaguePayload.flatMap { payload in
                    rinkLensDecodeSponsorThumbnail(id: nil, fingerprint: payload.0, data: payload.1)
                }
                let sponsors = sponsorPayloads.compactMap { payload in
                    rinkLensDecodeSponsorThumbnail(id: payload.0, fingerprint: payload.1, data: payload.2)
                }
                return RinkLensDecodedSponsorLogoBatch(league: league, sponsors: sponsors)
                #else
                return RinkLensDecodedSponsorLogoBatch(league: nil, sponsors: [])
                #endif
            }.value
            guard let self else { return }
            guard generation == self.imageCacheGeneration else {
                self.imageCachePrewarmInFlight = false
                return
            }

            if let league = batch.league {
                self.leagueLogoCache = CachedSponsorLogo(
                    fingerprint: league.fingerprint,
                    image: UIImage(cgImage: league.cgImage)
                )
            }
            for sponsor in batch.sponsors {
                guard let id = sponsor.id else { continue }
                self.sponsorLogoCache[id] = CachedSponsorLogo(
                    fingerprint: sponsor.fingerprint,
                    image: UIImage(cgImage: sponsor.cgImage)
                )
            }
            self.imageCachePrewarmInFlight = false
            self.imageCacheRevision &+= 1
            RinkLensStructuredEventLogger.shared.record(
                domain: .sponsorRoster,
                event: "sponsor_logo_cache_prewarm_completed",
                entityID: "logo-cache",
                previous: ["generation": String(generation), "inFlight": "true"],
                next: ["generation": String(generation), "inFlight": "false", "decoded": String(batch.sponsors.count + (batch.league == nil ? 0 : 1))],
                source: "SponsorCatalogueStore",
                reason: "Off-main thumbnail decoding completed",
                transactionID: transactionID,
                authoritativeOwner: "SponsorCatalogueStore"
            )
            MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("Sponsor logo cache ready"))
        }
    }

    private func imageFingerprint(_ data: Data) -> Int {
        var hasher = Hasher()
        hasher.combine(data.count)
        hasher.combine(data.prefix(64))
        hasher.combine(data.suffix(64))
        return hasher.finalize()
    }
    #else
    func prewarmImageCache(source: String, reason: String) {}
    #endif

    var diagnosticsSummary: String {
        let activeCount = configuration.sponsors.filter(\.isActive).count
        let placementCount = configuration.placements.assignedCount
        let rosterCount = configuration.homeRoster.count
        let overlay = configuration.overlay.isOutputOverlayEnabled ? "recording/stream ON" : "recording/stream OFF"
        let preview = configuration.overlay.showOverlayOnBroadcastScreen ? "iPad preview ON" : "iPad preview OFF"
        return "active sponsors=\(activeCount); assigned placements=\(placementCount); home roster entries=\(rosterCount); intermission=\(configuration.intermission.isEnabled ? "enabled" : "disabled"); sponsor overlay: \(overlay); \(preview)"
    }
}

struct SponsorCatalogueConfiguration: Codable, Equatable {
    var league: SponsorLeagueBranding = SponsorLeagueBranding()
    var sponsors: [SponsorCatalogueSponsor] = []
    var placements: SponsorPlacementAssignments = SponsorPlacementAssignments()
    var homeRoster: [SponsorPlayerAssignment] = []
    var intermission: SponsorIntermissionConfiguration = SponsorIntermissionConfiguration()
    var overlay: SponsorOverlayConfiguration = SponsorOverlayConfiguration()

    static var defaults: SponsorCatalogueConfiguration {
        SponsorCatalogueConfiguration(
            league: SponsorLeagueBranding(isEnabled: true, name: "NIHL North 2 (Laidler)", logoData: nil),
            sponsors: [
                SponsorCatalogueSponsor(name: "Season Sponsor", contactName: "", emailAddress: "", notes: "Primary season partner", isActive: true, logoData: nil),
                SponsorCatalogueSponsor(name: "Game Sponsor", contactName: "", emailAddress: "", notes: "Tonight's game sponsor", isActive: true, logoData: nil),
                SponsorCatalogueSponsor(name: "Goal Sponsor", contactName: "", emailAddress: "", notes: "Goal popup partner", isActive: true, logoData: nil)
            ],
            placements: SponsorPlacementAssignments(),
            homeRoster: [
                SponsorPlayerAssignment(number: "45", name: "Home Player", sponsorID: nil)
            ],
            intermission: SponsorIntermissionConfiguration(),
            overlay: SponsorOverlayConfiguration()
        )
    }

    init(
        league: SponsorLeagueBranding = SponsorLeagueBranding(),
        sponsors: [SponsorCatalogueSponsor] = [],
        placements: SponsorPlacementAssignments = SponsorPlacementAssignments(),
        homeRoster: [SponsorPlayerAssignment] = [],
        intermission: SponsorIntermissionConfiguration = SponsorIntermissionConfiguration(),
        overlay: SponsorOverlayConfiguration = SponsorOverlayConfiguration()
    ) {
        self.league = league
        self.sponsors = sponsors
        self.placements = placements
        self.homeRoster = homeRoster
        self.intermission = intermission
        self.overlay = overlay
    }

    private enum CodingKeys: String, CodingKey {
        case league
        case sponsors
        case placements
        case homeRoster
        case intermission
        case overlay
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        league = try container.decodeIfPresent(SponsorLeagueBranding.self, forKey: .league) ?? SponsorLeagueBranding()
        sponsors = try container.decodeIfPresent([SponsorCatalogueSponsor].self, forKey: .sponsors) ?? []
        placements = try container.decodeIfPresent(SponsorPlacementAssignments.self, forKey: .placements) ?? SponsorPlacementAssignments()
        homeRoster = try container.decodeIfPresent([SponsorPlayerAssignment].self, forKey: .homeRoster) ?? []
        intermission = try container.decodeIfPresent(SponsorIntermissionConfiguration.self, forKey: .intermission) ?? SponsorIntermissionConfiguration()
        overlay = try container.decodeIfPresent(SponsorOverlayConfiguration.self, forKey: .overlay) ?? SponsorOverlayConfiguration()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(league, forKey: .league)
        try container.encode(sponsors, forKey: .sponsors)
        try container.encode(placements, forKey: .placements)
        try container.encode(homeRoster, forKey: .homeRoster)
        try container.encode(intermission, forKey: .intermission)
        try container.encode(overlay, forKey: .overlay)
    }

    func normalized() -> SponsorCatalogueConfiguration {
        var copy = self
        if copy.sponsors.isEmpty {
            copy.sponsors = SponsorCatalogueConfiguration.defaults.sponsors
        }
        return copy
    }
}

struct SponsorOverlayConfiguration: Codable, Equatable, Sendable {
    var isOutputOverlayEnabled: Bool = true
    var showOverlayOnBroadcastScreen: Bool = true
}

struct SponsorRecordingOverlaySnapshot: Equatable, Sendable {
    var isOutputOverlayEnabled: Bool = true
    var leagueEnabled: Bool = false
    var leagueName: String = ""
    var leagueLogoData: Data? = nil
    var seasonSponsorName: String = ""
    var seasonSponsorLogoData: Data? = nil
    var gameSponsorName: String = ""
    var gameSponsorLogoData: Data? = nil

    var cacheKey: String {
        [
            isOutputOverlayEnabled ? "outputOn" : "outputOff",
            leagueEnabled ? "leagueOn" : "leagueOff",
            leagueName,
            String(leagueLogoData?.count ?? 0),
            seasonSponsorName,
            String(seasonSponsorLogoData?.count ?? 0),
            gameSponsorName,
            String(gameSponsorLogoData?.count ?? 0)
        ].joined(separator: "|")
    }
}

final class SponsorRecordingOverlaySnapshotStore: @unchecked Sendable {
    static let shared = SponsorRecordingOverlaySnapshotStore()

    private let lock = NSLock()
    private var currentSnapshot = SponsorRecordingOverlaySnapshot()

    private init() {}

    @discardableResult
    func update(from configuration: SponsorCatalogueConfiguration) -> Bool {
        let sponsors = configuration.sponsors
        let placements = configuration.placements
        let season = sponsors.first(where: { $0.id == placements.seasonSponsorID && $0.isActive })
        let game = sponsors.first(where: { $0.id == placements.gameSponsorID && $0.isActive })
        let next = SponsorRecordingOverlaySnapshot(
            isOutputOverlayEnabled: configuration.overlay.isOutputOverlayEnabled,
            leagueEnabled: configuration.league.isEnabled,
            leagueName: configuration.league.name,
            leagueLogoData: configuration.league.logoData,
            seasonSponsorName: season?.displayName ?? "",
            seasonSponsorLogoData: season?.logoData,
            gameSponsorName: game?.displayName ?? "",
            gameSponsorLogoData: game?.logoData
        )
        lock.lock()
        let changed = currentSnapshot != next
        currentSnapshot = next
        lock.unlock()
        return changed
    }

    func snapshot() -> SponsorRecordingOverlaySnapshot {
        lock.lock()
        let snapshot = currentSnapshot
        lock.unlock()
        return snapshot
    }
}

struct SponsorLeagueBranding: Codable, Equatable {
    var isEnabled: Bool = true
    var name: String = "NIHL North 2 (Laidler)"
    var logoData: Data? = nil
}

struct SponsorCatalogueSponsor: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String
    var contactName: String
    var emailAddress: String
    var notes: String
    var isActive: Bool
    var logoData: Data?

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unnamed sponsor" : trimmed
    }
}

struct SponsorPlacementAssignments: Codable, Equatable {
    var seasonSponsorID: UUID? = nil
    var gameSponsorID: UUID? = nil
    var homeGoalSponsorID: UUID? = nil
    var awayGoalSponsorID: UUID? = nil
    var homePenaltyDefaultSponsorID: UUID? = nil
    var awayPenaltySponsorID: UUID? = nil
    var finalScoreSponsorID: UUID? = nil

    var assignedCount: Int {
        [seasonSponsorID, gameSponsorID, homeGoalSponsorID, awayGoalSponsorID, homePenaltyDefaultSponsorID, awayPenaltySponsorID, finalScoreSponsorID]
            .compactMap { $0 }
            .count
    }

    mutating func clearSponsor(_ sponsorID: UUID) {
        if seasonSponsorID == sponsorID { seasonSponsorID = nil }
        if gameSponsorID == sponsorID { gameSponsorID = nil }
        if homeGoalSponsorID == sponsorID { homeGoalSponsorID = nil }
        if awayGoalSponsorID == sponsorID { awayGoalSponsorID = nil }
        if homePenaltyDefaultSponsorID == sponsorID { homePenaltyDefaultSponsorID = nil }
        if awayPenaltySponsorID == sponsorID { awayPenaltySponsorID = nil }
        if finalScoreSponsorID == sponsorID { finalScoreSponsorID = nil }
    }
}

struct SponsorPlayerAssignment: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var number: String
    var name: String
    var sponsorID: UUID?

    var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNumber = number.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedNumber.isEmpty { return trimmedName.isEmpty ? "Unnamed player" : trimmedName }
        return "#\(trimmedNumber) \(trimmedName.isEmpty ? "Unnamed player" : trimmedName)"
    }
}

struct SponsorIntermissionConfiguration: Codable, Equatable {
    var isEnabled: Bool = true
    var showBetweenFirstAndSecond: Bool = true
    var showBetweenSecondAndThird: Bool = true
    var includeSeasonSponsor: Bool = true
    var includeGameSponsor: Bool = true
    var includeGoalSponsors: Bool = true
    var includePenaltySponsors: Bool = true
    var includeFinalScoreSponsor: Bool = true
    var includeAllActiveCatalogueSponsors: Bool = false
    var slideDurationSeconds: Double = 8
}

#endif
