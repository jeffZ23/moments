import Foundation
import MomentCore

enum SpotifyError: LocalizedError {
    case http(Int, String)
    case noActiveDevice

    var errorDescription: String? {
        switch self {
        case .http(let code, let message): return "Spotify error \(code): \(message)"
        case .noActiveDevice: return "Start playing something in Spotify first, then Moments can take over."
        }
    }
}

/// The few Spotify Web API calls Moments needs. Playback control requires Spotify Premium.
@MainActor
final class SpotifyClient: MusicController {
    private let auth: SpotifyAuth
    private let base = URL(string: "https://api.spotify.com/v1/")!

    init(auth: SpotifyAuth) { self.auth = auth }

    // MARK: Library

    func topTracks(range: String) async throws -> [Track] {
        let page: Page<TrackObject> = try await get("me/top/tracks", ["limit": "50", "time_range": range])
        return page.items.compactMap(\.track)
    }

    /// Most recently saved tracks, newest first.
    func savedTracks(max: Int) async throws -> [Track] {
        var result: [Track] = []
        var offset = 0
        while result.count < max {
            let page: Page<SavedTrack> = try await get("me/tracks", ["limit": "50", "offset": String(offset)])
            result += page.items.compactMap(\.track.track)
            offset += 50
            if page.next == nil || page.items.isEmpty { break }
        }
        return Array(result.prefix(max))
    }

    func recentlyPlayed() async throws -> [Track] {
        let page: Page<PlayHistory> = try await get("me/player/recently-played", ["limit": "50"])
        return page.items.compactMap(\.track.track)
    }

    /// Search is capped at 10 results for apps in development mode.
    func search(_ query: String, limit: Int = 10) async throws -> [Track] {
        struct SearchResponse: Decodable { let tracks: Page<TrackObject> }
        let response: SearchResponse = try await get("search", ["q": query, "type": "track", "limit": String(min(limit, 10))])
        return response.tracks.items.compactMap(\.track)
    }

    // MARK: Playback

    func playbackState() async throws -> PlaybackState? {
        let (data, status) = try await send("GET", "me/player", query: ["additional_types": "track"])
        if status == 204 || data.isEmpty { return nil }
        struct Player: Decodable {
            let is_playing: Bool
            let progress_ms: Int?
            let item: TrackObject?
        }
        let player = try JSONDecoder().decode(Player.self, from: data)
        return PlaybackState(trackURI: player.item?.uri, progressMs: player.progress_ms ?? 0, durationMs: player.item?.duration_ms ?? 0, isPlaying: player.is_playing)
    }

    func addToQueue(uri: String) async throws {
        let (_, status) = try await send("POST", "me/player/queue", query: ["uri": uri])
        if status == 404 { throw SpotifyError.noActiveDevice }
    }

    func skipToNext() async throws {
        let (_, status) = try await send("POST", "me/player/next")
        if status == 404 { throw SpotifyError.noActiveDevice }
    }

    // MARK: HTTP

    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        let (data, _) = try await send("GET", path, query: query)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    private func send(_ method: String, _ path: String, query: [String: String] = [:], retried: Bool = false) async throws -> (Data, Int) {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
        if method != "GET" { request.setValue("0", forHTTPHeaderField: "Content-Length") }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429, !retried {
            let wait = Double((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2
            try await Task.sleep(nanoseconds: UInt64(min(wait, 10) * 1_000_000_000))
            return try await send(method, path, query: query, retried: true)
        }
        if status == 404 && path.hasPrefix("me/player") { return (data, status) }
        guard (200..<300).contains(status) else {
            throw SpotifyError.http(status, String(data: data, encoding: .utf8)?.prefix(200).description ?? "")
        }
        return (data, status)
    }
}

// MARK: - Wire types

private struct Page<Item: Decodable>: Decodable {
    let items: [Item]
    let next: String?
}

private struct SavedTrack: Decodable { let track: TrackObject }
private struct PlayHistory: Decodable { let track: TrackObject }

private struct TrackObject: Decodable {
    struct Artist: Decodable { let name: String }
    struct Album: Decodable {
        let name: String?
        let release_date: String?
    }

    let id: String?
    let uri: String?
    let name: String?
    let artists: [Artist]?
    let album: Album?
    let duration_ms: Int?
    let is_local: Bool?

    var track: Track? {
        guard let id, let uri, let name, is_local != true else { return nil }
        let year = album?.release_date.flatMap { Int($0.prefix(4)) }
        return Track(id: id, uri: uri, name: name, artists: (artists ?? []).map(\.name), album: album?.name, durationMs: duration_ms ?? 0, releaseYear: year)
    }
}
