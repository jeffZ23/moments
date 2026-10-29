import Foundation
import MomentCore
import NaturalLanguage

/// On-device sentence embeddings for matching song cards to moments. No network.
final class SentenceEmbedder: TextEmbedder {
    private let embedding = NLEmbedding.sentenceEmbedding(for: .english)

    func vector(for text: String) -> [Double]? {
        embedding?.vector(for: text)
    }
}

/// Imports the user's Spotify library, writes song cards, and builds the discovery pool.
@MainActor
final class LibraryBuilder {
    private let spotify: SpotifyClient
    private let backend: BackendClient
    var onProgress: ((String) -> Void)?

    static let maxSavedTracks = 500
    static let cardBatchSize = 40
    static let discoveryArtists = 15
    static let discoveryPerArtist = 3

    init(spotify: SpotifyClient, backend: BackendClient) {
        self.spotify = spotify
        self.backend = backend
    }

    /// Top tracks (all time ranges), recently played and recently saved songs, de-duplicated.
    func importLibrary(existing: [LibraryEntry]) async throws -> [LibraryEntry] {
        onProgress?("Reading your top tracks…")
        var top: [Track] = []
        for range in ["short_term", "medium_term", "long_term"] {
            top += try await spotify.topTracks(range: range)
        }
        onProgress?("Reading recently played and saved songs…")
        let recent = (try? await spotify.recentlyPlayed()) ?? []
        let saved = (try? await spotify.savedTracks(max: Self.maxSavedTracks)) ?? []

        let topIDs = Set(top.map(\.id))
        let oldCards = Dictionary(existing.compactMap { e in e.card.map { (e.track.id, $0) } }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var entries: [LibraryEntry] = []
        for track in top + recent + saved where seen.insert(track.id).inserted {
            entries.append(LibraryEntry(track: track, card: oldCards[track.id], isTopTrack: topIDs.contains(track.id)))
        }
        // Keep the discovery pool across re-imports.
        entries += existing.filter { $0.isDiscovery && !seen.contains($0.track.id) }
        return entries
    }

    /// Writes cards for songs that don't have one yet, tagged songs first. Calls `save` after each batch so progress survives.
    func buildCards(_ library: inout [LibraryEntry], priority: Set<String>, save: ([LibraryEntry]) -> Void) async {
        let missing = library.indices
            .filter { library[$0].card == nil }
            .sorted { (priority.contains(library[$0].track.id) ? 0 : 1, $0) < (priority.contains(library[$1].track.id) ? 0 : 1, $1) }
        guard !missing.isEmpty else { return }

        var done = 0
        for start in stride(from: 0, to: missing.count, by: Self.cardBatchSize) {
            let batch = Array(missing[start..<min(start + Self.cardBatchSize, missing.count)])
            onProgress?("Writing song cards… \(done)/\(missing.count)")
            guard let cards = try? await backend.cards(for: batch.map { library[$0].track }) else { continue }
            let byID = Dictionary(cards.map { ($0.trackID, $0) }, uniquingKeysWith: { a, _ in a })
            for index in batch { library[index].card = byID[library[index].track.id] }
            done += batch.count
            save(library)
        }
        onProgress?("Song cards ready.")
    }

    /// Unheard songs by artists you already love; the LLM fills in only if that comes up short.
    func buildDiscoveryPool(_ library: inout [LibraryEntry], save: ([LibraryEntry]) -> Void) async {
        let known = Set(library.map(\.track.id))
        let knownNames = Set(library.map { $0.track.name.lowercased() })
        var artistCounts: [String: Int] = [:]
        for entry in library where entry.isTopTrack && !entry.isDiscovery {
            if let artist = entry.track.artists.first { artistCounts[artist, default: 0] += 1 }
        }
        let artists = artistCounts.sorted { $0.value > $1.value }.prefix(Self.discoveryArtists).map(\.key)
        guard !artists.isEmpty else { return }

        onProgress?("Finding new songs from artists you love…")
        var pool: [Track] = []
        for artist in artists {
            let results = (try? await spotify.search("artist:\"\(artist)\"")) ?? []
            let fresh = results.filter { !known.contains($0.id) && !knownNames.contains($0.name.lowercased()) && $0.artists.first == artist }
            pool += fresh.prefix(Self.discoveryPerArtist)
        }

        if pool.count < 10 {
            pool += await llmDiscovery(tasteArtists: artists, exclude: library.map(\.track), known: known.union(pool.map(\.id)))
        }

        var seen = known
        let entries = pool.filter { seen.insert($0.id).inserted }.map { LibraryEntry(track: $0, isDiscovery: true) }
        guard !entries.isEmpty else { return }
        library += entries
        await buildCards(&library, priority: [], save: save)
    }

    private func llmDiscovery(tasteArtists: [String], exclude: [Track], known: Set<String>) async -> [Track] {
        var found: [Track] = []
        for type in MomentType.allCases {
            let moment = MomentSummaryPayload(type: type, detail: "any \(type.displayName.lowercased()) moment on a drive", localTime: "any time", tripMinutes: 30)
            let request = DiscoverRequestPayload(moment: moment, tasteArtists: Array(tasteArtists.prefix(30)),
                                                 exclude: exclude.prefix(100).map { .init(name: $0.name, artists: Array($0.artists.prefix(5))) }, count: 4)
            guard let songs = try? await backend.discover(request).songs else { continue }
            for song in songs {
                // Only keep suggestions Spotify confirms exist.
                let hits = (try? await spotify.search("track:\"\(song.title)\" artist:\"\(song.artist)\"", limit: 1)) ?? []
                if let track = hits.first, !known.contains(track.id) { found.append(track) }
            }
        }
        return found
    }
}
