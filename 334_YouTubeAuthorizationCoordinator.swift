// Build 785 Recovery CV: user OAuth boundary for YouTube metadata publishing.
#if canImport(SwiftUI)
import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

nonisolated struct RinkLensYouTubeOAuthConfiguration: Sendable {
    let clientID: String
    let redirectURI: String
    var redirectScheme: String { URL(string: redirectURI)?.scheme ?? "" }

    static func fromBundle(_ bundle: Bundle = .main) throws -> Self {
        guard let clientID = bundle.object(forInfoDictionaryKey: "RinkLensYouTubeOAuthClientID") as? String,
              !clientID.isEmpty, !clientID.hasPrefix("REPLACE_ME"),
              let redirectURI = bundle.object(forInfoDictionaryKey: "RinkLensYouTubeOAuthRedirectURI") as? String,
              let url = URL(string: redirectURI), url.scheme?.isEmpty == false else {
            throw RinkLensYouTubeOAuthError.missingConfiguration
        }
        return .init(clientID: clientID, redirectURI: redirectURI)
    }
}

nonisolated enum RinkLensYouTubeOAuthError: LocalizedError, Sendable {
    case missingConfiguration, invalidCallback, stateMismatch, missingCode, tokenResponseInvalid, channelResponseInvalid, cancelled
    var errorDescription: String? {
        switch self {
        case .missingConfiguration: return "Add a real RinkLensYouTubeOAuthClientID and matching RinkLensYouTubeOAuthRedirectURI to the app configuration."
        case .invalidCallback: return "Google returned an invalid authorisation callback."
        case .stateMismatch: return "The YouTube authorisation state did not match."
        case .missingCode: return "Google did not return an authorisation code."
        case .tokenResponseInvalid: return "Google returned an invalid token response."
        case .channelResponseInvalid: return "The authorised YouTube channel could not be identified."
        case .cancelled: return "YouTube connection was cancelled."
        }
    }
}

nonisolated enum RinkLensYouTubePKCE {
    static func verifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }
    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }
}

nonisolated enum RinkLensYouTubeOAuthCallback {
    static func code(from url: URL, expectedState: String) throws -> String {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { throw RinkLensYouTubeOAuthError.invalidCallback }
        guard items.first(where: { $0.name == "state" })?.value == expectedState else { throw RinkLensYouTubeOAuthError.stateMismatch }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw RinkLensYouTubeOAuthError.missingCode }
        return code
    }
}

actor RinkLensYouTubeAuthorizationService: RinkLensYouTubeCredentialProviding {
    static let shared = RinkLensYouTubeAuthorizationService()
    private let session: URLSession
    private let store: RinkLensYouTubeCredentialStore
    init(session: URLSession = .shared, store: RinkLensYouTubeCredentialStore = .shared) { self.session = session; self.store = store }

    func validCredential() async throws -> RinkLensYouTubeCredential {
        guard let current = try store.load() else { throw RinkLensYouTubePublishingError.notAuthorised }
        if current.expiry.timeIntervalSinceNow >= 60 { return current }
        guard let refreshToken = current.refreshToken else { throw RinkLensYouTubePublishingError.notAuthorised }
        let configuration = try RinkLensYouTubeOAuthConfiguration.fromBundle()
        return try await refresh(refreshToken: refreshToken, previous: current, configuration: configuration)
    }

    func exchange(code: String, verifier: String, configuration: RinkLensYouTubeOAuthConfiguration) async throws -> RinkLensYouTubeCredential {
        let values = ["client_id": configuration.clientID, "code": code, "code_verifier": verifier,
                      "grant_type": "authorization_code", "redirect_uri": configuration.redirectURI]
        let token = try await tokenRequest(values)
        let channel = try await channelIdentity(accessToken: token.accessToken)
        let credential = RinkLensYouTubeCredential(accessToken: token.accessToken, refreshToken: token.refreshToken,
            expiry: Date().addingTimeInterval(TimeInterval(token.expiresIn)), channelID: channel.id, channelName: channel.name)
        try store.save(credential); return credential
    }

    private func refresh(refreshToken: String, previous: RinkLensYouTubeCredential, configuration: RinkLensYouTubeOAuthConfiguration) async throws -> RinkLensYouTubeCredential {
        let token = try await tokenRequest(["client_id": configuration.clientID, "refresh_token": refreshToken, "grant_type": "refresh_token"])
        let updated = RinkLensYouTubeCredential(accessToken: token.accessToken, refreshToken: token.refreshToken ?? refreshToken,
            expiry: Date().addingTimeInterval(TimeInterval(token.expiresIn)), channelID: previous.channelID, channelName: previous.channelName)
        try store.save(updated); return updated
    }

    private func tokenRequest(_ values: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = values.sorted(by: { $0.key < $1.key }).map { "\($0.key.urlFormEncoded)=\($0.value.urlFormEncoded)" }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let token = try? JSONDecoder().decode(TokenResponse.self, from: data) else { throw RinkLensYouTubeOAuthError.tokenResponseInvalid }
        return token
    }

    private func channelIdentity(accessToken: String) async throws -> (id: String, name: String) {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/channels")!
        components.queryItems = [.init(name: "part", value: "id,snippet"), .init(name: "mine", value: "true")]
        var request = URLRequest(url: components.url!); request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let item = (root["items"] as? [[String: Any]])?.first,
              let id = item["id"] as? String, let title = (item["snippet"] as? [String: Any])?["title"] as? String else { throw RinkLensYouTubeOAuthError.channelResponseInvalid }
        return (id, title)
    }

    private struct TokenResponse: Decodable {
        let accessToken: String; let expiresIn: Int; let refreshToken: String?
        enum CodingKeys: String, CodingKey { case accessToken = "access_token", expiresIn = "expires_in", refreshToken = "refresh_token" }
    }
}

@MainActor
final class RinkLensYouTubeAuthorizationCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func connect() async throws -> RinkLensYouTubeCredential {
        let configuration = try RinkLensYouTubeOAuthConfiguration.fromBundle()
        let verifier = RinkLensYouTubePKCE.verifier(), state = UUID().uuidString
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: configuration.clientID), .init(name: "redirect_uri", value: configuration.redirectURI),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: "https://www.googleapis.com/auth/youtube.force-ssl https://www.googleapis.com/auth/youtube.upload"),
            .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent"),
            .init(name: "code_challenge", value: RinkLensYouTubePKCE.challenge(for: verifier)), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state)]
        let callback = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let webSession = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: configuration.redirectScheme) { url, error in
                if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: error ?? RinkLensYouTubeOAuthError.cancelled) }
            }
            webSession.presentationContextProvider = self; webSession.prefersEphemeralWebBrowserSession = false
            self.session = webSession
            if !webSession.start() { continuation.resume(throwing: RinkLensYouTubeOAuthError.cancelled) }
        }
        session = nil
        let code = try RinkLensYouTubeOAuthCallback.code(from: callback, expectedState: state)
        return try await RinkLensYouTubeAuthorizationService.shared.exchange(code: code, verifier: verifier, configuration: configuration)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            preconditionFailure("YouTube authorisation requires an active window scene.")
        }
        return scene.windows.first(where: \.isKeyWindow) ?? ASPresentationAnchor(windowScene: scene)
    }
}

private extension Data {
    nonisolated func base64URLEncodedString() -> String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
private extension String {
    nonisolated var urlFormEncoded: String { addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? self }
}
#endif
