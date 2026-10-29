import Foundation

/// Values injected at build time from Config.xcconfig / Secrets.xcconfig through Info.plist.
struct AppConfig {
    var spotifyClientID: String
    var backendURL: URL?
    var backendToken: String

    /// The HTTPS redirect registered with Spotify. The backend forwards it to moments://spotify-callback.
    var spotifyRedirectURI: String? {
        backendURL?.appendingPathComponent("spotify/callback").absoluteString
    }

    static let callbackScheme = "moments"

    static var current: AppConfig {
        let info = Bundle.main.infoDictionary ?? [:]
        func value(_ key: String) -> String {
            (info[key] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        let url = value("BackendURL")
        return AppConfig(spotifyClientID: value("SpotifyClientID"),
                         backendURL: url.isEmpty ? nil : URL(string: url),
                         backendToken: value("BackendToken"))
    }

    var missing: [String] {
        var result: [String] = []
        if spotifyClientID.isEmpty { result.append("SPOTIFY_CLIENT_ID") }
        if backendURL == nil { result.append("BACKEND_URL") }
        if backendToken.isEmpty { result.append("BACKEND_TOKEN") }
        return result
    }
}
