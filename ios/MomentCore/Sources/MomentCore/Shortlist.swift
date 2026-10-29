import Foundation

public protocol TextEmbedder {
    /// A sentence vector for the text, or nil if the embedder can't handle it.
    func vector(for text: String) -> [Double]?
}

/// Caches vectors per key so the library is embedded once.
public final class EmbeddingCache {
    private let embedder: TextEmbedder
    private var vectors: [String: [Double]] = [:]

    public init(embedder: TextEmbedder) { self.embedder = embedder }

    public func vector(key: String, text: String) -> [Double]? {
        if let cached = vectors[key] { return cached }
        let v = embedder.vector(for: text)
        if let v { vectors[key] = v }
        return v
    }

    public func query(_ text: String) -> [Double]? { embedder.vector(for: text) }
}

public enum MomentQuery {
    /// The feeling we look for at each moment, matched against song cards.
    public static func text(for moment: DetectedMoment, raining: Bool) -> String {
        var parts: [String] = []
        for type in [moment.type] + moment.alsoTypes {
            switch type {
            case .sunset:
                parts.append("golden hour, sunset drive, warm, nostalgic, reflective, end of the day")
            case .rain:
                parts.append(raining
                    ? "rainy drive, rain on the windshield, melancholic, cozy, calm, introspective"
                    : "after the rain, fresh air, hopeful, bright, clearing sky")
            case .leavingLongStop:
                parts.append("leaving, farewell, bittersweet, memories, open road, end of an adventure")
            case .nearingHome:
                parts.append("coming home, almost home, calm, content, warm, familiar streets")
            }
        }
        parts.append(moment.detail)
        return parts.joined(separator: ". ")
    }
}

public struct Candidate: Hashable {
    public var entry: LibraryEntry
    public var score: Double
    public var userTagged: Bool
    public var anthem: Bool
}

public enum Shortlister {
    public static let tagBonus = 0.35
    public static let anthemBonus = 0.15
    public static let feedbackWeight = 0.05
    public static let blockScore = -4

    /// Narrows the library to the songs most likely to fit the moment; the LLM picks among these.
    public static func shortlist(
        moment: DetectedMoment,
        query: String,
        library: [LibraryEntry],
        tags: UserTags,
        feedback: FeedbackStore,
        recentlyPlayed: Set<String>,
        embeddings: EmbeddingCache?,
        discovery: Bool,
        limit: Int = 30
    ) -> [Candidate] {
        let queryVector = embeddings?.query(query)
        let queryTokens = tokens(query)

        var results: [Candidate] = []
        for entry in library where entry.isDiscovery == discovery {
            let id = entry.track.id
            let tagged = tags.isTagged(id, for: moment.type) || moment.alsoTypes.contains { tags.isTagged(id, for: $0) }
            let anthem = tags.anthems.contains(id)

            guard let card = entry.card ?? (tagged ? placeholderCard(for: entry.track) : nil) else { continue }
            if card.confidence == .low && !tagged { continue }
            if recentlyPlayed.contains(id) && !anthem { continue }
            let fb = feedback.score(trackID: id, moment: moment.type)
            if fb <= blockScore { continue }

            var similarity: Double
            if let qv = queryVector, let cv = embeddings?.vector(key: id, text: card.embeddingText) {
                similarity = cosine(qv, cv)
            } else {
                similarity = jaccard(queryTokens, tokens(card.embeddingText))
            }
            if tagged { similarity += tagBonus }
            if anthem { similarity += anthemBonus }
            similarity += max(-0.5, min(0.5, Double(fb) * feedbackWeight))
            results.append(Candidate(entry: entry, score: similarity, userTagged: tagged, anthem: anthem))
        }
        results.sort { $0.score > $1.score || ($0.score == $1.score && $0.entry.track.id < $1.entry.track.id) }
        return Array(results.prefix(limit))
    }

    static func placeholderCard(for track: Track) -> SongCard {
        SongCard(trackID: track.id, description: "A song the driver tagged for this moment.", moods: [], energy: 3, scenes: [], language: "unknown", confidence: .medium)
    }

    public static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (sqrt(na) * sqrt(nb))
    }

    static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 })
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b).count
        return union == 0 ? 0 : Double(a.intersection(b).count) / Double(union)
    }
}

/// Learns which songs work for which moments.
public struct FeedbackStore: Codable, Hashable {
    public struct Example: Codable, Hashable {
        public var name: String
        public var artists: [String]
        public var moment: MomentType
    }

    /// trackID -> MomentType.rawValue -> score
    public var scores: [String: [String: Int]] = [:]
    public var hits: [Example] = []
    public var misses: [Example] = []
    public static let maxExamples = 10

    public init() {}

    public func score(trackID: String, moment: MomentType) -> Int { scores[trackID]?[moment.rawValue] ?? 0 }

    public mutating func adjust(_ track: Track, moment: MomentType, by delta: Int) {
        scores[track.id, default: [:]][moment.rawValue, default: 0] += delta
    }

    public mutating func record(_ outcome: PlayOutcome, track: Track, moment: MomentType) {
        let example = Example(name: track.name, artists: track.artists, moment: moment)
        switch outcome {
        case .hit:
            adjust(track, moment: moment, by: 1)
            hits = Array(([example] + hits.filter { $0 != example }).prefix(Self.maxExamples))
        case .miss:
            adjust(track, moment: moment, by: -2)
            misses = Array(([example] + misses.filter { $0 != example }).prefix(Self.maxExamples))
        case .pending, .partial, .unknown:
            break
        }
    }

    public mutating func recordRating(_ stars: Int, track: Track, moment: MomentType) {
        if stars >= 4 { adjust(track, moment: moment, by: 2) }
        if stars <= 2 { adjust(track, moment: moment, by: -2) }
    }
}

/// Which songs played on recent trips, so picked-for-you songs rotate.
public struct RotationHistory: Codable, Hashable {
    public var trips: [[String]] = []
    public static let window = 5

    public init() {}

    public func recentlyPlayed() -> Set<String> {
        trips.suffix(Self.window).reduce(into: Set<String>()) { $0.formUnion($1) }
    }

    public mutating func startTrip() {
        trips.append([])
        if trips.count > Self.window { trips.removeFirst(trips.count - Self.window) }
    }

    public mutating func add(_ trackID: String) {
        if trips.isEmpty { trips.append([]) }
        trips[trips.count - 1].append(trackID)
    }
}
