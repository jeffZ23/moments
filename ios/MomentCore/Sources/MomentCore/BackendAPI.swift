import Foundation

// Wire types for the Moments backend (see backend/src/schemas.ts).

public struct MomentSummaryPayload: Codable, Hashable {
    public struct RecentPlay: Codable, Hashable {
        public var name: String
        public var artists: [String]
        public var outcome: String // "played" | "skipped"
    }

    public var type: MomentType
    public var detail: String
    public var localTime: String
    public var weather: String?
    public var placeKind: String?
    public var placeName: String?
    public var tripMinutes: Int
    public var lastStopMinutes: Int?
    public var lastStopName: String?
    public var recentPlays: [RecentPlay]

    public init(type: MomentType, detail: String, localTime: String, weather: String? = nil, placeKind: String? = nil, placeName: String? = nil, tripMinutes: Int, lastStopMinutes: Int? = nil, lastStopName: String? = nil, recentPlays: [RecentPlay] = []) {
        self.type = type
        self.detail = detail
        self.localTime = localTime
        self.weather = weather
        self.placeKind = placeKind
        self.placeName = placeName
        self.tripMinutes = tripMinutes
        self.lastStopMinutes = lastStopMinutes
        self.lastStopName = lastStopName
        self.recentPlays = recentPlays
    }
}

public struct PickCandidatePayload: Codable, Hashable {
    public struct Card: Codable, Hashable {
        public var description: String
        public var moods: [String]
        public var energy: Int
        public var scenes: [String]
        public var language: String
    }

    public var id: String
    public var name: String
    public var artists: [String]
    public var card: Card
    public var userTagged: Bool
    public var anthem: Bool
    public var isDiscovery: Bool
}

public struct PickRequestPayload: Codable, Hashable {
    public struct Examples: Codable, Hashable {
        public var hits: [FeedbackStore.Example]
        public var misses: [FeedbackStore.Example]
    }

    public var moment: MomentSummaryPayload
    public var candidates: [PickCandidatePayload]
    public var examples: Examples
    public var count: Int
}

public struct PickResponsePayload: Codable, Hashable {
    public struct Pick: Codable, Hashable {
        public var id: String
        public var reason: String

        public init(id: String, reason: String) {
            self.id = id
            self.reason = reason
        }
    }
    public var picks: [Pick]

    public init(picks: [Pick]) { self.picks = picks }
}

public struct CardsRequestPayload: Codable, Hashable {
    public struct TrackItem: Codable, Hashable {
        public var id: String
        public var name: String
        public var artists: [String]
        public var album: String?
        public var releaseYear: Int?
    }
    public var tracks: [TrackItem]

    public init(tracks: [Track]) {
        self.tracks = tracks.map { TrackItem(id: $0.id, name: $0.name, artists: Array($0.artists.prefix(5)), album: $0.album, releaseYear: $0.releaseYear) }
    }
}

public struct CardsResponsePayload: Codable, Hashable {
    public struct CardItem: Codable, Hashable {
        public var id: String
        public var description: String
        public var moods: [String]
        public var energy: Int
        public var scenes: [String]
        public var language: String
        public var confidence: CardConfidence
    }
    public var cards: [CardItem]

    public var songCards: [SongCard] {
        cards.map { SongCard(trackID: $0.id, description: $0.description, moods: $0.moods, energy: $0.energy, scenes: $0.scenes, language: $0.language, confidence: $0.confidence) }
    }
}

public struct DiscoverRequestPayload: Codable, Hashable {
    public struct TrackRef: Codable, Hashable {
        public var name: String
        public var artists: [String]

        public init(name: String, artists: [String]) {
            self.name = name
            self.artists = artists
        }
    }
    public var moment: MomentSummaryPayload
    public var tasteArtists: [String]
    public var exclude: [TrackRef]
    public var count: Int

    public init(moment: MomentSummaryPayload, tasteArtists: [String], exclude: [TrackRef], count: Int) {
        self.moment = moment
        self.tasteArtists = tasteArtists
        self.exclude = exclude
        self.count = count
    }
}

public struct DiscoverResponsePayload: Codable, Hashable {
    public struct Song: Codable, Hashable {
        public var title: String
        public var artist: String
        public var reason: String
    }
    public var songs: [Song]
}

// MARK: - Service protocols (implemented by the app, faked in tests)

public protocol PickService {
    func pick(_ request: PickRequestPayload) async throws -> PickResponsePayload
}

public struct PlaybackState: Equatable {
    public var trackURI: String?
    public var progressMs: Int
    public var durationMs: Int
    public var isPlaying: Bool

    public init(trackURI: String?, progressMs: Int, durationMs: Int, isPlaying: Bool) {
        self.trackURI = trackURI
        self.progressMs = progressMs
        self.durationMs = durationMs
        self.isPlaying = isPlaying
    }
}

public protocol MusicController {
    func addToQueue(uri: String) async throws
    func skipToNext() async throws
}

public extension MusicController {
    /// Cut-in moments queue the song and skip to it; others just queue it after the current song.
    func play(_ track: Track, cutIn: Bool) async throws {
        try await addToQueue(uri: track.uri)
        if cutIn { try await skipToNext() }
    }
}
