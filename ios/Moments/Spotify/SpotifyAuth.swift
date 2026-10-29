import AuthenticationServices
import CryptoKit
import Foundation
import Security
#if os(iOS)
import UIKit
#endif

struct SpotifyTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

enum SpotifyAuthError: LocalizedError {
    case notConfigured, cancelled, denied(String), badResponse, stateMismatch

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Spotify client ID or backend URL is missing from Secrets.xcconfig."
        case .cancelled: return "Spotify login was cancelled."
        case .denied(let reason): return "Spotify said no: \(reason)"
        case .badResponse: return "Unexpected response from Spotify."
        case .stateMismatch: return "Login response didn't match the request."
        }
    }
}

/// Spotify login with Authorization Code + PKCE (no client secret on the phone). Tokens live in the Keychain.
@MainActor
final class SpotifyAuth {
    static let scopes = [
        "user-top-read", "user-library-read", "user-read-recently-played",
        "user-read-playback-state", "user-modify-playback-state",
    ]

    private let config: AppConfig
    private var session: ASWebAuthenticationSession?
    private var anchorProvider: AnchorProvider?
    private(set) var tokens: SpotifyTokens?

    init(config: AppConfig) {
        self.config = config
        tokens = Keychain.load()
    }

    var isLoggedIn: Bool { tokens != nil }

    func logOut() {
        tokens = nil
        Keychain.delete()
    }

    func logIn() async throws {
        guard !config.spotifyClientID.isEmpty, let redirect = config.spotifyRedirectURI else { throw SpotifyAuthError.notConfigured }
        let verifier = Self.randomURLSafe(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = Self.randomURLSafe(16)

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: config.spotifyClientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "state", value: state),
            .init(name: "scope", value: Self.scopes.joined(separator: " ")),
        ]

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: AppConfig.callbackScheme) { url, error in
                if let url { continuation.resume(returning: url) } else {
                    let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    continuation.resume(throwing: cancelled ? SpotifyAuthError.cancelled : (error ?? SpotifyAuthError.badResponse))
                }
            }
            let provider = AnchorProvider(anchor: Self.keyWindow())
            self.anchorProvider = provider
            session.presentationContextProvider = provider
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = item("error") { throw SpotifyAuthError.denied(error) }
        guard item("state") == state else { throw SpotifyAuthError.stateMismatch }
        guard let code = item("code") else { throw SpotifyAuthError.badResponse }

        try await requestTokens([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirect,
            "client_id": config.spotifyClientID,
            "code_verifier": verifier,
        ])
    }

    /// A valid access token, refreshing it when it is about to expire.
    func accessToken() async throws -> String {
        guard let tokens else { throw SpotifyAuthError.notConfigured }
        if tokens.expiresAt.timeIntervalSinceNow > 60 { return tokens.accessToken }
        try await requestTokens([
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken,
            "client_id": config.spotifyClientID,
        ])
        return self.tokens?.accessToken ?? tokens.accessToken
    }

    private func requestTokens(_ form: [String: String]) async throws {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SpotifyAuthError.badResponse }

        struct TokenResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        let refresh = decoded.refresh_token ?? tokens?.refreshToken ?? ""
        let new = SpotifyTokens(accessToken: decoded.access_token, refreshToken: refresh, expiresAt: Date().addingTimeInterval(decoded.expires_in))
        tokens = new
        Keychain.save(new)
    }

    private static func keyWindow() -> ASPresentationAnchor {
        #if os(iOS)
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return windows.first { $0.isKeyWindow } ?? windows.first ?? ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }

    private static func randomURLSafe(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64URLEncoded
    }
}

/// Tells the login sheet which window to appear over. Created on the main actor before the sheet starts.
private final class AnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    let anchor: ASPresentationAnchor
    init(anchor: ASPresentationAnchor) { self.anchor = anchor }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

private enum Keychain {
    static let service = "moments.spotify"
    static let account = "tokens"

    static func save(_ tokens: SpotifyTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load() -> SpotifyTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(SpotifyTokens.self, from: data)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
