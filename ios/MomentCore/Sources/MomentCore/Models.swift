import Foundation

public struct Track: Codable, Hashable, Identifiable {
    public var id: String
    public var uri: String
    public var name: String
    public var artists: [String]
    public var album: String?
    public var durationMs: Int
    public var releaseYear: Int?

    public init(id: String, uri: String, name: String, artists: [String], album: String? = nil, durationMs: Int, releaseYear: Int? = nil) {
        self.id = id
        self.uri = uri
        self.name = name
        self.artists = artists
        self.album = album
        self.durationMs = durationMs
        self.releaseYear = releaseYear
    }

    public var artistLine: String { artists.joined(separator: ", ") }
}

public enum MomentType: String, Codable, CaseIterable, Hashable {
    case sunset
    case rain
    case leavingLongStop
    case nearingHome

    public var displayName: String {
        switch self {
        case .sunset: return "Sunset"
        case .rain: return "Rain"
        case .leavingLongStop: return "Leaving a long stop"
        case .nearingHome: return "Nearing home"
        }
    }

    /// Short moments cut into the current song; long ones wait for it to end.
    public var cutsIn: Bool {
        switch self {
        case .sunset, .rain, .nearingHome: return true
        case .leavingLongStop: return false
        }
    }
}

public enum CardConfidence: String, Codable {
    case high, medium, low
}

/// How a song feels, written once per song by the LLM and used to shortlist candidates.
public struct SongCard: Codable, Hashable {
    public var trackID: String
    public var description: String
    public var moods: [String]
    public var energy: Int
    public var scenes: [String]
    public var language: String
    public var confidence: CardConfidence

    public init(trackID: String, description: String, moods: [String], energy: Int, scenes: [String], language: String, confidence: CardConfidence) {
        self.trackID = trackID
        self.description = description
        self.moods = moods
        self.energy = energy
        self.scenes = scenes
        self.language = language
        self.confidence = confidence
    }

    /// Text that represents the card for embedding similarity.
    public var embeddingText: String {
        "\(moods.joined(separator: ", ")). \(scenes.joined(separator: ", ")). \(description)"
    }
}

public struct Coordinate: Codable, Hashable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct WeatherSnapshot: Codable, Hashable {
    public var isRaining: Bool
    public var summary: String

    public init(isRaining: Bool, summary: String) {
        self.isRaining = isRaining
        self.summary = summary
    }
}

/// One reading of the driver's surroundings.
public struct ContextSample: Codable, Hashable {
    public var date: Date
    public var coordinate: Coordinate
    public var speedMps: Double
    public var weather: WeatherSnapshot?
    public var placeName: String?
    public var placeKind: String?

    public init(date: Date, coordinate: Coordinate, speedMps: Double, weather: WeatherSnapshot? = nil, placeName: String? = nil, placeKind: String? = nil) {
        self.date = date
        self.coordinate = coordinate
        self.speedMps = speedMps
        self.weather = weather
        self.placeName = placeName
        self.placeKind = placeKind
    }
}

/// A song in the user's world: their library, top tracks, or the discovery pool.
public struct LibraryEntry: Codable, Hashable {
    public var track: Track
    public var card: SongCard?
    public var isTopTrack: Bool
    public var isDiscovery: Bool

    public init(track: Track, card: SongCard? = nil, isTopTrack: Bool = false, isDiscovery: Bool = false) {
        self.track = track
        self.card = card
        self.isTopTrack = isTopTrack
        self.isDiscovery = isDiscovery
    }
}

/// Songs the user tagged for moments during setup, plus anthems that may repeat.
public struct UserTags: Codable, Hashable {
    /// MomentType.rawValue -> track ids
    public var buckets: [String: Set<String>]
    public var anthems: Set<String>

    public init(buckets: [String: Set<String>] = [:], anthems: Set<String> = []) {
        self.buckets = buckets
        self.anthems = anthems
    }

    public func tracks(for type: MomentType) -> Set<String> { buckets[type.rawValue] ?? [] }

    public func isTagged(_ trackID: String, for type: MomentType) -> Bool { tracks(for: type).contains(trackID) }

    public mutating func toggle(_ trackID: String, for type: MomentType) {
        var set = tracks(for: type)
        if set.contains(trackID) { set.remove(trackID) } else { set.insert(trackID) }
        buckets[type.rawValue] = set
    }

    public var allTagged: Set<String> { buckets.values.reduce(into: Set<String>()) { $0.formUnion($1) } }
}

public struct PickedSong: Codable, Hashable {
    public var track: Track
    public var reason: String

    public init(track: Track, reason: String) {
        self.track = track
        self.reason = reason
    }
}

/// Where a moment song came from. `baseline` is the shuffle comparison arm.
public enum PickArm: String, Codable, CaseIterable {
    case engine, discovery, baseline, offlineCache, fallbackRule

    public var displayName: String {
        switch self {
        case .engine: return "Moments"
        case .discovery: return "Discovery"
        case .baseline: return "Shuffle (comparison)"
        case .offlineCache: return "Picked ahead (no signal)"
        case .fallbackRule: return "Your tags (offline)"
        }
    }
}

public enum PlayOutcome: String, Codable {
    case pending, hit, miss, partial, unknown
}

public struct MomentRecord: Codable, Identifiable, Hashable {
    public var id: UUID
    public var type: MomentType
    public var alsoTypes: [MomentType]
    public var detail: String
    public var date: Date
    public var placeName: String?
    public var picks: [PickedSong]
    public var playedIndex: Int
    public var arm: PickArm
    public var outcome: PlayOutcome
    public var rating: Int?

    public init(id: UUID = UUID(), type: MomentType, alsoTypes: [MomentType] = [], detail: String, date: Date, placeName: String?, picks: [PickedSong], playedIndex: Int = 0, arm: PickArm, outcome: PlayOutcome = .pending, rating: Int? = nil) {
        self.id = id
        self.type = type
        self.alsoTypes = alsoTypes
        self.detail = detail
        self.date = date
        self.placeName = placeName
        self.picks = picks
        self.playedIndex = playedIndex
        self.arm = arm
        self.outcome = outcome
        self.rating = rating
    }

    public var played: PickedSong? { picks.indices.contains(playedIndex) ? picks[playedIndex] : nil }

    /// Baseline picks stay blind until rated, so the rating isn't biased.
    public var displayReason: String {
        if arm == .baseline && rating == nil { return "Picked for this moment" }
        return played?.reason ?? ""
    }
}

public struct TripRecord: Codable, Identifiable, Hashable {
    public var id: UUID
    public var start: Date
    public var end: Date?
    public var startPlace: String?
    public var endPlace: String?
    public var moments: [MomentRecord]
    public var isSimulated: Bool

    public init(id: UUID = UUID(), start: Date, end: Date? = nil, startPlace: String? = nil, endPlace: String? = nil, moments: [MomentRecord] = [], isSimulated: Bool = false) {
        self.id = id
        self.start = start
        self.end = end
        self.startPlace = startPlace
        self.endPlace = endPlace
        self.moments = moments
        self.isSimulated = isSimulated
    }
}

/// Where the driver stopped last, used to detect "leaving a long stop".
public struct StopRecord: Codable, Hashable {
    public var coordinate: Coordinate
    public var placeName: String?
    public var arrival: Date

    public init(coordinate: Coordinate, placeName: String?, arrival: Date) {
        self.coordinate = coordinate
        self.placeName = placeName
        self.arrival = arrival
    }
}
