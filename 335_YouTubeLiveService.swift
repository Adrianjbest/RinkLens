// Build 785 Recovery CV: YouTube metadata publisher; owns no media transport.
#if canImport(SwiftUI)
import Foundation
import Security

nonisolated struct RinkLensYouTubeCredential: Codable, Hashable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiry: Date
    var channelID: String?
    var channelName: String?
}

nonisolated protocol RinkLensYouTubeCredentialProviding: Sendable {
    func validCredential() async throws -> RinkLensYouTubeCredential
}

nonisolated enum RinkLensYouTubePublishingError: LocalizedError, Sendable {
    case notAuthorised, invalidResponse, missingVideoID, thumbnailTooLarge, playlistNotConfigured
    case http(status: Int, message: String)
    var errorDescription: String? {
        switch self {
        case .notAuthorised: return "Connect a YouTube channel before publishing."
        case .invalidResponse: return "YouTube returned an unreadable response."
        case .missingVideoID: return "YouTube did not return a video identity."
        case .thumbnailTooLarge: return "The thumbnail exceeds YouTube's 2 MB limit."
        case .playlistNotConfigured: return "No playlist is configured."
        case .http(let status, let message): return "YouTube HTTP \(status): \(message)"
        }
    }
}

nonisolated final class RinkLensYouTubeCredentialStore: RinkLensYouTubeCredentialProviding, @unchecked Sendable {
    static let shared = RinkLensYouTubeCredentialStore()
    private let service = "com.rinklens.youtube.oauth"
    private let account = "channel-user"
    private let lock = NSLock()

    func validCredential() async throws -> RinkLensYouTubeCredential {
        guard let value = try load(), value.expiry.timeIntervalSinceNow >= 60 else { throw RinkLensYouTubePublishingError.notAuthorised }
        return value
    }

    func load() throws -> RinkLensYouTubeCredential? {
        lock.lock(); defer { lock.unlock() }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status) }
        return try JSONDecoder().decode(RinkLensYouTubeCredential.self, from: data)
    }

    func save(_ value: RinkLensYouTubeCredential) throws {
        let data = try JSONEncoder().encode(value)
        lock.lock(); defer { lock.unlock() }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = query; attributes.forEach { insertion[$0.key] = $0.value }
            let inserted = SecItemAdd(insertion as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw KeychainError(inserted) }
        } else if status != errSecSuccess { throw KeychainError(status) }
    }

    func clear() throws {
        lock.lock(); defer { lock.unlock() }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status) }
    }

    private struct KeychainError: LocalizedError {
        let status: OSStatus
        init(_ status: OSStatus) { self.status = status }
        var errorDescription: String? { SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)." }
    }
}

nonisolated struct RinkLensYouTubeBroadcastResource: Sendable {
    let broadcastID: String
    let videoID: String?
}

nonisolated protocol RinkLensYouTubeAPIClient: Sendable {
    func createBroadcast(metadata: RinkLensResolvedYouTubeMetadata, scheduledStart: Date, accessToken: String) async throws -> RinkLensYouTubeBroadcastResource
    func updateBroadcast(id: String, metadata: RinkLensResolvedYouTubeMetadata, scheduledStart: Date, accessToken: String) async throws -> RinkLensYouTubeBroadcastResource
    func bindBroadcast(id: String, streamID: String, accessToken: String) async throws
    func uploadThumbnail(videoID: String, data: Data, accessToken: String) async throws
    func playlistID(named name: String, accessToken: String) async throws -> String?
    func createPlaylist(named name: String, accessToken: String) async throws -> String
    func playlistItemID(playlistID: String, videoID: String, accessToken: String) async throws -> String?
    func addToPlaylist(playlistID: String, videoID: String, accessToken: String) async throws -> String
}

nonisolated final class RinkLensYouTubeRESTClient: RinkLensYouTubeAPIClient, @unchecked Sendable {
    private let session: URLSession
    private let api = URL(string: "https://www.googleapis.com/youtube/v3")!
    private let upload = URL(string: "https://www.googleapis.com/upload/youtube/v3")!
    init(session: URLSession = .shared) { self.session = session }

    func createBroadcast(metadata: RinkLensResolvedYouTubeMetadata, scheduledStart: Date, accessToken: String) async throws -> RinkLensYouTubeBroadcastResource {
        try await writeBroadcast(id: nil, metadata: metadata, scheduledStart: scheduledStart, token: accessToken)
    }
    func updateBroadcast(id: String, metadata: RinkLensResolvedYouTubeMetadata, scheduledStart: Date, accessToken: String) async throws -> RinkLensYouTubeBroadcastResource {
        try await writeBroadcast(id: id, metadata: metadata, scheduledStart: scheduledStart, token: accessToken)
    }
    func uploadThumbnail(videoID: String, data: Data, accessToken: String) async throws {
        guard data.count <= 2_000_000 else { throw RinkLensYouTubePublishingError.thumbnailTooLarge }
        var components = URLComponents(url: upload.appendingPathComponent("thumbnails/set"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "videoId", value: videoID), .init(name: "uploadType", value: "media")]
        var request = request(url: components.url!, method: "POST", token: accessToken)
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type"); request.httpBody = data
        _ = try await response(for: request)
    }
    func bindBroadcast(id: String, streamID: String, accessToken: String) async throws {
        var components = URLComponents(url: api.appendingPathComponent("liveBroadcasts/bind"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "id", value: id), .init(name: "part", value: "id,contentDetails"), .init(name: "streamId", value: streamID)]
        _ = try await object(url: components.url!, method: "POST", token: accessToken, body: nil)
    }
    func playlistID(named name: String, accessToken: String) async throws -> String? {
        var pageToken: String?
        repeat {
            var components = URLComponents(url: api.appendingPathComponent("playlists"), resolvingAgainstBaseURL: false)!
            components.queryItems = [.init(name: "part", value: "id,snippet"), .init(name: "mine", value: "true"), .init(name: "maxResults", value: "50")]
            if let pageToken { components.queryItems?.append(.init(name: "pageToken", value: pageToken)) }
            let root = try await object(url: components.url!, method: "GET", token: accessToken, body: nil)
            if let match = (root["items"] as? [[String: Any]])?.first(where: {
                (($0["snippet"] as? [String: Any])?["title"] as? String)?.caseInsensitiveCompare(name) == .orderedSame
            }), let id = match["id"] as? String { return id }
            pageToken = root["nextPageToken"] as? String
        } while pageToken != nil
        return nil
    }
    func createPlaylist(named name: String, accessToken: String) async throws -> String {
        var components = URLComponents(url: api.appendingPathComponent("playlists"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "part", value: "snippet,status")]
        let body: [String: Any] = ["snippet": ["title": name], "status": ["privacyStatus": "private"]]
        let root = try await object(url: components.url!, method: "POST", token: accessToken, body: body)
        guard let id = root["id"] as? String else { throw RinkLensYouTubePublishingError.invalidResponse }
        return id
    }
    func playlistItemID(playlistID: String, videoID: String, accessToken: String) async throws -> String? {
        var components = URLComponents(url: api.appendingPathComponent("playlistItems"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "part", value: "id"), .init(name: "playlistId", value: playlistID), .init(name: "videoId", value: videoID), .init(name: "maxResults", value: "1")]
        let object = try await object(url: components.url!, method: "GET", token: accessToken, body: nil)
        return ((object["items"] as? [[String: Any]])?.first?["id"] as? String)
    }
    func addToPlaylist(playlistID: String, videoID: String, accessToken: String) async throws -> String {
        var components = URLComponents(url: api.appendingPathComponent("playlistItems"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "part", value: "snippet")]
        let body: [String: Any] = ["snippet": ["playlistId": playlistID, "resourceId": ["kind": "youtube#video", "videoId": videoID]]]
        let object = try await object(url: components.url!, method: "POST", token: accessToken, body: body)
        guard let id = object["id"] as? String else { throw RinkLensYouTubePublishingError.invalidResponse }
        return id
    }

    private func writeBroadcast(id: String?, metadata: RinkLensResolvedYouTubeMetadata, scheduledStart: Date, token: String) async throws -> RinkLensYouTubeBroadcastResource {
        var components = URLComponents(url: api.appendingPathComponent("liveBroadcasts"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "part", value: "snippet,status,contentDetails")]
        var body: [String: Any] = [
            "snippet": ["title": metadata.title, "description": metadata.description, "categoryId": metadata.categoryID, "scheduledStartTime": Self.iso.string(from: scheduledStart)],
            "status": ["privacyStatus": metadata.visibility.rawValue, "selfDeclaredMadeForKids": metadata.madeForKids],
            "contentDetails": ["enableDvr": metadata.enableDVR, "recordFromStart": metadata.recordFromStart,
                "enableAutoStart": metadata.enableAutoStart, "enableAutoStop": metadata.enableAutoStop,
                "enableEmbed": metadata.enableEmbed, "monitorStream": ["enableMonitorStream": false, "broadcastStreamDelayMs": 0]]]
        if let id { body["id"] = id }
        let object = try await object(url: components.url!, method: id == nil ? "POST" : "PUT", token: token, body: body)
        guard let broadcastID = object["id"] as? String else { throw RinkLensYouTubePublishingError.invalidResponse }
        return .init(broadcastID: broadcastID, videoID: broadcastID)
    }
    private func object(url: URL, method: String, token: String, body: [String: Any]?) async throws -> [String: Any] {
        var request = request(url: url, method: method, token: token)
        if let body { request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let data = try await response(for: request)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RinkLensYouTubePublishingError.invalidResponse }
        return value
    }
    private func request(url: URL, method: String, token: String) -> URLRequest {
        var value = URLRequest(url: url); value.httpMethod = method; value.timeoutInterval = 30
        value.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); return value
    }
    private func response(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RinkLensYouTubePublishingError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = root?["error"] as? [String: Any]
            throw RinkLensYouTubePublishingError.http(status: http.statusCode, message: error?["message"] as? String ?? "Unknown error")
        }
        return data
    }
    private static let iso = ISO8601DateFormatter()
}

nonisolated struct RinkLensYouTubePublishResult: Sendable {
    let reference: RinkLensYouTubePublicationReference
    let createdNewBroadcast: Bool
}

actor YouTubePublishingService {
    private let api: any RinkLensYouTubeAPIClient
    private let credentials: any RinkLensYouTubeCredentialProviding
    init(api: any RinkLensYouTubeAPIClient = RinkLensYouTubeRESTClient(), credentials: any RinkLensYouTubeCredentialProviding = RinkLensYouTubeAuthorizationService.shared) {
        self.api = api; self.credentials = credentials
    }

    func publishOrUpdate(
        snapshot: RinkLensGameConfigurationSnapshot,
        existing: RinkLensYouTubePublicationReference?,
        thumbnailJPEG: Data?,
        onBroadcastResolved: @Sendable (RinkLensYouTubePublicationReference) async -> Void = { _ in }
    ) async throws -> RinkLensYouTubePublishResult {
        guard let metadata = snapshot.youtubeMetadata else { throw RinkLensYouTubePublishingError.invalidResponse }
        let credential = try await credentials.validCredential()
        let broadcast: RinkLensYouTubeBroadcastResource, created: Bool
        if let id = existing?.broadcastID, !id.isEmpty {
            broadcast = try await api.updateBroadcast(id: id, metadata: metadata, scheduledStart: snapshot.scheduledStart, accessToken: credential.accessToken); created = false
        } else {
            broadcast = try await api.createBroadcast(metadata: metadata, scheduledStart: snapshot.scheduledStart, accessToken: credential.accessToken); created = true
        }
        guard let videoID = broadcast.videoID else { throw RinkLensYouTubePublishingError.missingVideoID }
        var reference = existing ?? .init(broadcastID: broadcast.broadcastID)
        reference.broadcastID = broadcast.broadcastID; reference.videoID = videoID; reference.publishedAt = .now; reference.state = .scheduled; reference.failureMessage = nil
        // This is the physical acknowledgement boundary for the remote identity.
        // Persist it before thumbnail/playlist work so a partial failure cannot
        // cause the next operator action to create a duplicate broadcast.
        await onBroadcastResolved(reference)
        RinkLensStructuredEventLogger.shared.record(
            domain: .youtubePublishing, event: created ? "broadcast_created" : "broadcast_updated",
            entityID: snapshot.fixtureID.uuidString,
            next: ["broadcastID": broadcast.broadcastID], source: "YouTubePublishingService",
            reason: created ? "YouTube acknowledged scheduled broadcast creation" : "YouTube acknowledged scheduled broadcast update",
            authoritativeOwner: "RinkLensSeasonStore")
        if let streamID = metadata.streamID, !streamID.isEmpty, reference.streamID != streamID {
            try await api.bindBroadcast(id: broadcast.broadcastID, streamID: streamID, accessToken: credential.accessToken)
            reference.streamID = streamID
            await onBroadcastResolved(reference)
            RinkLensStructuredEventLogger.shared.record(
                domain: .youtubePublishing, event: "stream_bound", entityID: snapshot.fixtureID.uuidString,
                next: ["broadcastID": broadcast.broadcastID, "streamID": streamID], source: "YouTubePublishingService",
                reason: "YouTube acknowledged reusable liveStream binding", authoritativeOwner: "RinkLensSeasonStore")
        }
        if let thumbnailJPEG, !reference.thumbnailUploaded {
            try await api.uploadThumbnail(videoID: videoID, data: thumbnailJPEG, accessToken: credential.accessToken); reference.thumbnailUploaded = true
            RinkLensStructuredEventLogger.shared.record(
                domain: .youtubePublishing, event: "thumbnail_uploaded", entityID: snapshot.fixtureID.uuidString,
                next: ["videoID": videoID], source: "YouTubePublishingService",
                reason: "YouTube acknowledged fixture thumbnail upload", authoritativeOwner: "RinkLensSeasonStore")
        }
        if metadata.playlistPolicy != .none, reference.playlistItemID == nil {
            let playlistID: String
            if let configured = metadata.playlistID, !configured.isEmpty {
                playlistID = configured
            } else if metadata.playlistPolicy == .createIfMissing,
                      let name = metadata.playlistName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                if let existingPlaylistID = try await api.playlistID(named: name, accessToken: credential.accessToken) {
                    playlistID = existingPlaylistID
                } else {
                    playlistID = try await api.createPlaylist(named: name, accessToken: credential.accessToken)
                }
            } else { throw RinkLensYouTubePublishingError.playlistNotConfigured }
            if let existingItemID = try await api.playlistItemID(
                playlistID: playlistID,
                videoID: videoID,
                accessToken: credential.accessToken
            ) {
                reference.playlistItemID = existingItemID
            } else {
                reference.playlistItemID = try await api.addToPlaylist(
                    playlistID: playlistID,
                    videoID: videoID,
                    accessToken: credential.accessToken
                )
            }
            RinkLensStructuredEventLogger.shared.record(
                domain: .youtubePublishing, event: "playlist_linked", entityID: snapshot.fixtureID.uuidString,
                next: ["videoID": videoID, "playlistItemID": reference.playlistItemID ?? "existing"],
                source: "YouTubePublishingService", reason: "YouTube playlist membership acknowledged",
                authoritativeOwner: "RinkLensSeasonStore")
        }
        reference.state = .ready
        return .init(reference: reference, createdNewBroadcast: created)
    }
}
#endif
