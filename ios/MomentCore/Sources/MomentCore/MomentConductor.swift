import Foundation

/// Everything the conductor remembers between launches.
public struct ConductorMemory: Codable, Hashable {
    public var settings = MomentSettings()
    public var tags = UserTags()
    public var feedback = FeedbackStore()
    public var rotation = RotationHistory()
    public var trips: [TripRecord] = []
    public var activeTrip: TripState?
    public var lastStop: StopRecord?
    public var pickCache = PickCache()
    public var momentSongCount = 0

    public init() {}
}

/// Picks saved ahead of time for places with no signal.
public struct PickCache: Codable, Hashable {
    public struct Entry: Codable, Hashable {
        public var picks: [PickedSong]
        public var createdAt: Date
    }
    /// MomentType.rawValue -> entry
    public var entries: [String: Entry] = [:]
    public static let lifetime: TimeInterval = 3 * 3600
    public static let refreshAfter: TimeInterval = 45 * 60

    public init() {}

    public func needsRefresh(_ type: MomentType, now: Date) -> Bool {
        guard let entry = entries[type.rawValue] else { return true }
        return now.timeIntervalSince(entry.createdAt) > Self.refreshAfter
    }

    public mutating func store(_ picks: [PickedSong], for type: MomentType, at date: Date) {
        entries[type.rawValue] = Entry(picks: picks, createdAt: date)
    }

    public mutating func take(_ type: MomentType, now: Date) -> [PickedSong]? {
        guard let entry = entries.removeValue(forKey: type.rawValue),
              now.timeIntervalSince(entry.createdAt) < Self.lifetime,
              !entry.picks.isEmpty else { return nil }
        return entry.picks
    }
}

public protocol RandomSource {
    mutating func nextDouble() -> Double
}

public struct SystemRandom: RandomSource {
    public init() {}
    public mutating func nextDouble() -> Double { Double.random(in: 0..<1) }
}

/// Runs a trip: detects moments, picks songs, plays them, and learns from what happens next.
@MainActor
public final class MomentConductor {
    public private(set) var memory: ConductorMemory
    public var library: [LibraryEntry]
    public var timeZone: TimeZone

    private let picker: PickService?
    private let music: MusicController
    private let embeddings: EmbeddingCache?
    private var random: RandomSource
    private var watch: Watch?
    private var retryAfter: Date?
    /// Learning state saved before a simulated drive and restored after it, so simulations don't train the picker.
    private var beforeSimulation: (feedback: FeedbackStore, rotation: RotationHistory, count: Int, cache: PickCache)?
    /// Called whenever memory changes, so the app can persist it.
    public var onChange: ((ConductorMemory) -> Void)?
    /// Called when a moment song starts, for the Live Activity.
    public var onMoment: ((MomentRecord) -> Void)?

    public static let skipThresholdMs = 20_000
    public static let watchTimeout: TimeInterval = 12 * 60

    struct Watch {
        var recordID: UUID
        var trackURI: String
        var durationMs: Int
        var queuedAt: Date
        var startedAt: Date?
        var lastProgressMs = 0
    }

    public init(memory: ConductorMemory, library: [LibraryEntry], picker: PickService?, music: MusicController, embedder: TextEmbedder?, timeZone: TimeZone = .current, random: RandomSource = SystemRandom()) {
        self.memory = memory
        self.library = library
        self.picker = picker
        self.music = music
        self.embeddings = embedder.map(EmbeddingCache.init)
        self.timeZone = timeZone
        self.random = random
    }

    public var isTripActive: Bool { memory.activeTrip != nil }

    public func updateSettings(_ change: (inout MomentSettings) -> Void) { change(&memory.settings); changed() }
    public func updateTags(_ change: (inout UserTags) -> Void) { change(&memory.tags); changed() }

    // MARK: Trip lifecycle

    public func startTrip(at date: Date, coordinate: Coordinate, placeName: String?, simulated: Bool = false, previousStop: StopRecord? = nil) {
        guard memory.activeTrip == nil else { return }
        beforeSimulation = simulated ? (memory.feedback, memory.rotation, memory.momentSongCount, memory.pickCache) : nil
        let record = TripRecord(start: date, startPlace: placeName, isSimulated: simulated)
        memory.activeTrip = TripState(record: record, startCoordinate: coordinate, previousStop: previousStop ?? memory.lastStop)
        memory.rotation.startTrip()
        watch = nil
        changed()
    }

    @discardableResult
    public func endTrip(at date: Date, coordinate: Coordinate, placeName: String?) -> TripRecord? {
        guard var trip = memory.activeTrip else { return nil }
        finishWatch(outcome: nil)
        trip = memory.activeTrip ?? trip
        trip.record.end = date
        trip.record.endPlace = placeName
        memory.trips.insert(trip.record, at: 0)
        if !trip.record.isSimulated {
            memory.lastStop = StopRecord(coordinate: coordinate, placeName: placeName, arrival: date)
        }
        if let saved = beforeSimulation {
            memory.feedback = saved.feedback
            memory.rotation = saved.rotation
            memory.momentSongCount = saved.count
            memory.pickCache = saved.cache
            beforeSimulation = nil
        }
        memory.activeTrip = nil
        changed()
        return trip.record
    }

    // MARK: Moments

    /// Feed every new reading of the surroundings. Returns the moment record if a song was started.
    @discardableResult
    public func handle(_ sample: ContextSample) async -> MomentRecord? {
        guard var trip = memory.activeTrip else { return nil }
        trip.ingest(sample, settings: memory.settings)
        memory.activeTrip = trip

        guard !trip.inCooldown(at: sample.date, settings: memory.settings),
              watch == nil,
              retryAfter.map({ sample.date >= $0 }) ?? true,
              let moment = MomentDetector.detect(trip: trip, settings: memory.settings) else { return nil }

        let summary = makeSummary(moment, trip: trip, at: sample.date)
        let (picks, arm) = await choose(moment, summary: summary, trip: trip, now: sample.date)
        guard let first = picks.first else { return nil }

        do {
            try await music.play(first.track, cutIn: moment.type.cutsIn)
        } catch {
            retryAfter = sample.date.addingTimeInterval(60) // Spotify not reachable; try again in a minute.
            return nil
        }
        retryAfter = nil

        let record = MomentRecord(type: moment.type, alsoTypes: moment.alsoTypes, detail: moment.detail, date: sample.date, placeName: summary.placeName, picks: picks, arm: arm)
        guard var current = memory.activeTrip else { return nil }
        current.firedMoments.insert(moment.type)
        current.firedMoments.formUnion(moment.alsoTypes)
        current.lastMomentSongAt = sample.date
        current.record.moments.append(record)
        memory.activeTrip = current
        memory.rotation.add(first.track.id)
        memory.momentSongCount += 1
        watch = Watch(recordID: record.id, trackURI: first.track.uri, durationMs: first.track.durationMs, queuedAt: sample.date)
        changed()
        onMoment?(record)
        return record
    }

    func choose(_ moment: DetectedMoment, summary: MomentSummaryPayload, trip: TripState, now: Date) async -> ([PickedSong], PickArm) {
        let tripTrackIDs = Set(trip.record.moments.compactMap { $0.played?.track.id })

        if random.nextDouble() < memory.settings.baselineShare,
           let pick = baselinePick(excluding: tripTrackIDs) {
            return ([pick], .baseline)
        }

        let wantsDiscovery = memory.settings.discoveryEvery > 0
            && (memory.momentSongCount + 1) % memory.settings.discoveryEvery == 0
        let raining = trip.lastSample?.weather?.isRaining ?? false
        let query = MomentQuery.text(for: moment, raining: raining)
        let recentlyPlayed = memory.rotation.recentlyPlayed()

        func shortlist(discovery: Bool) -> [Candidate] {
            Shortlister.shortlist(moment: moment, query: query, library: library, tags: memory.tags, feedback: memory.feedback, recentlyPlayed: recentlyPlayed, embeddings: embeddings, discovery: discovery)
        }

        var candidates: [Candidate] = []
        var arm = PickArm.engine
        if wantsDiscovery {
            candidates = shortlist(discovery: true)
            if !candidates.isEmpty { arm = .discovery }
        }
        if candidates.isEmpty { candidates = shortlist(discovery: false) }

        if let picker, !candidates.isEmpty {
            if let picks = try? await requestPicks(picker, summary: summary, candidates: candidates), !picks.isEmpty {
                return (picks, arm)
            }
        }
        if let cached = memory.pickCache.take(moment.type, now: now) {
            let fresh = cached.filter { !tripTrackIDs.contains($0.track.id) }
            if !fresh.isEmpty { return (fresh, .offlineCache) }
        }
        return (fallbackRule(moment, excluding: tripTrackIDs), .fallbackRule)
    }

    func requestPicks(_ picker: PickService, summary: MomentSummaryPayload, candidates: [Candidate]) async throws -> [PickedSong] {
        let request = PickRequestPayload(
            moment: summary,
            candidates: candidates.map { c in
                let card = c.entry.card ?? Shortlister.placeholderCard(for: c.entry.track)
                return PickCandidatePayload(id: c.entry.track.id, name: c.entry.track.name, artists: Array(c.entry.track.artists.prefix(5)),
                                            card: .init(description: String(card.description.prefix(400)), moods: Array(card.moods.prefix(8)), energy: card.energy, scenes: Array(card.scenes.prefix(8)), language: card.language),
                                            userTagged: c.userTagged, anthem: c.anthem, isDiscovery: c.entry.isDiscovery)
            },
            examples: .init(hits: memory.feedback.hits, misses: memory.feedback.misses),
            count: 3)
        let response = try await picker.pick(request)
        let byID = Dictionary(candidates.map { ($0.entry.track.id, $0.entry.track) }, uniquingKeysWith: { a, _ in a })
        return response.picks.compactMap { p in byID[p.id].map { PickedSong(track: $0, reason: p.reason) } }
    }

    func baselinePick(excluding: Set<String>) -> PickedSong? {
        let pool = library.filter { $0.isTopTrack && !excluding.contains($0.track.id) }
        guard !pool.isEmpty else { return nil }
        let index = min(pool.count - 1, Int(random.nextDouble() * Double(pool.count)))
        return PickedSong(track: pool[index].track, reason: "A shuffle pick from your top tracks, for comparison.")
    }

    /// On-device rule when there is no signal and nothing saved ahead: songs you tagged, anthems first.
    func fallbackRule(_ moment: DetectedMoment, excluding: Set<String>) -> [PickedSong] {
        let tags = memory.tags
        let tagged = Set(([moment.type] + moment.alsoTypes).flatMap { tags.tracks(for: $0) })
        var pool = library.filter { tagged.contains($0.track.id) && !excluding.contains($0.track.id) }
        if pool.isEmpty { pool = library.filter { tags.anthems.contains($0.track.id) && !excluding.contains($0.track.id) } }

        let anthems = pool.filter { tags.anthems.contains($0.track.id) }.sorted { $0.track.id < $1.track.id }
        var rest = pool.filter { !tags.anthems.contains($0.track.id) }.sorted { $0.track.id < $1.track.id }
        if rest.count > 1 {
            let start = min(rest.count - 1, Int(random.nextDouble() * Double(rest.count)))
            rest = Array(rest[start...] + rest[..<start])
        }
        return (anthems + rest).prefix(3).map { PickedSong(track: $0.track, reason: "You tagged this for \(moment.type.displayName.lowercased()).") }
    }

    // MARK: Playback feedback

    /// Feed Spotify's playback state every few seconds during a trip.
    public func observe(_ state: PlaybackState?, at date: Date) async {
        guard var w = watch else { return }
        let isOurs = state?.trackURI == w.trackURI

        if w.startedAt == nil {
            if isOurs {
                w.startedAt = date
                w.lastProgressMs = state?.progressMs ?? 0
                watch = w
            } else if date.timeIntervalSince(w.queuedAt) > Self.watchTimeout {
                finishWatch(outcome: .unknown)
            }
            return
        }

        if isOurs {
            w.lastProgressMs = max(w.lastProgressMs, state?.progressMs ?? 0)
            watch = w
            return
        }

        // Our song is no longer playing: decide how it went.
        let progress = w.lastProgressMs
        if progress < Self.skipThresholdMs {
            await handleSkip(at: date)
        } else if progress >= Int(Double(w.durationMs) * 0.8) || w.durationMs - progress < 15_000 {
            finishWatch(outcome: .hit)
        } else {
            finishWatch(outcome: .partial)
        }
    }

    /// A skip within 20 seconds counts as a miss and plays the next pick right away.
    func handleSkip(at date: Date) async {
        guard let w = watch, var trip = memory.activeTrip,
              let index = trip.record.moments.firstIndex(where: { $0.id == w.recordID }) else { watch = nil; return }
        var record = trip.record.moments[index]
        if let skipped = record.played {
            memory.feedback.record(.miss, track: skipped.track, moment: record.type)
        }
        let nextIndex = record.playedIndex + 1
        if record.picks.indices.contains(nextIndex) {
            let next = record.picks[nextIndex]
            // The driver already skipped to something; play the backup now.
            if (try? await music.play(next.track, cutIn: true)) != nil {
                record.playedIndex = nextIndex
                trip.record.moments[index] = record
                memory.activeTrip = trip
                memory.rotation.add(next.track.id)
                watch = Watch(recordID: record.id, trackURI: next.track.uri, durationMs: next.track.durationMs, queuedAt: date)
                changed()
                onMoment?(record)
                return
            }
        }
        record.outcome = .miss
        trip.record.moments[index] = record
        memory.activeTrip = trip
        watch = nil
        changed()
    }

    func finishWatch(outcome: PlayOutcome?) {
        guard let w = watch else { return }
        watch = nil
        guard var trip = memory.activeTrip,
              let index = trip.record.moments.firstIndex(where: { $0.id == w.recordID }) else { return }
        let final = outcome ?? (w.startedAt == nil ? .unknown : .partial)
        trip.record.moments[index].outcome = final
        if let played = trip.record.moments[index].played {
            memory.feedback.record(final, track: played.track, moment: trip.record.moments[index].type)
        }
        memory.activeTrip = trip
        changed()
    }

    /// 1-5 stars from the trip recap.
    public func rate(momentID: UUID, tripID: UUID, stars: Int) {
        let stars = max(1, min(5, stars))
        func apply(_ record: inout MomentRecord) {
            let previous = record.rating
            record.rating = stars
            guard previous == nil, let played = record.played else { return }
            memory.feedback.recordRating(stars, track: played.track, moment: record.type)
        }
        if let t = memory.trips.firstIndex(where: { $0.id == tripID }),
           let m = memory.trips[t].moments.firstIndex(where: { $0.id == momentID }) {
            apply(&memory.trips[t].moments[m])
        } else if var trip = memory.activeTrip, trip.record.id == tripID,
                  let m = trip.record.moments.firstIndex(where: { $0.id == momentID }) {
            apply(&trip.record.moments[m])
            memory.activeTrip = trip
        }
        changed()
    }

    // MARK: Picking ahead

    /// Moments likely to happen in the next while, given where the trip is now.
    public func likelyUpcoming(at date: Date) -> [DetectedMoment] {
        guard let trip = memory.activeTrip, let sample = trip.lastSample else { return [] }
        var result: [DetectedMoment] = []
        let s = memory.settings

        if !trip.firedMoments.contains(.sunset) {
            let soon = SunCalculator.position(at: date.addingTimeInterval(90 * 60), coordinate: sample.coordinate)
            let now = SunCalculator.position(at: date, coordinate: sample.coordinate)
            if now.isAfternoon, now.elevation > s.sunsetLowerDegrees, soon.elevation <= s.sunsetUpperDegrees {
                result.append(DetectedMoment(type: .sunset, alsoTypes: [], detail: "the sun is setting, golden hour"))
            }
        }
        if !trip.firedMoments.contains(.leavingLongStop), let stop = trip.previousStop,
           trip.start.timeIntervalSince(stop.arrival) / 60 >= s.longStopMinutes,
           trip.minutes(at: date) <= s.leavingWindowMinutes {
            result.append(DetectedMoment(type: .leavingLongStop, alsoTypes: [], detail: "leaving \(stop.placeName ?? "a place") after a long stay"))
        }
        if !trip.firedMoments.contains(.nearingHome), let home = s.home,
           Geo.distance(home, sample.coordinate) > s.nearingHomeMeters,
           trip.maxDistanceFromHome >= s.nearingHomeMinFarMeters,
           Geo.distance(home, sample.coordinate) < trip.maxDistanceFromHome * 0.6 {
            result.append(DetectedMoment(type: .nearingHome, alsoTypes: [], detail: "almost home, the last few minutes of the drive"))
        }
        return result
    }

    /// Call while there is signal (e.g. every 15 minutes) to save picks for places without it.
    public func prefetch(at date: Date) async {
        guard let picker, let trip = memory.activeTrip else { return }
        for moment in likelyUpcoming(at: date) where memory.pickCache.needsRefresh(moment.type, now: date) {
            let query = MomentQuery.text(for: moment, raining: trip.lastSample?.weather?.isRaining ?? false)
            let candidates = Shortlister.shortlist(moment: moment, query: query, library: library, tags: memory.tags, feedback: memory.feedback, recentlyPlayed: memory.rotation.recentlyPlayed(), embeddings: embeddings, discovery: false)
            guard !candidates.isEmpty else { continue }
            let summary = makeSummary(moment, trip: trip, at: date)
            if let picks = try? await requestPicks(picker, summary: summary, candidates: candidates), !picks.isEmpty {
                memory.pickCache.store(picks, for: moment.type, at: date)
                changed()
            }
        }
    }

    // MARK: Summary

    func makeSummary(_ moment: DetectedMoment, trip: TripState, at date: Date) -> MomentSummaryPayload {
        let sample = trip.lastSample
        let s = memory.settings
        let nearHome = moment.type == .nearingHome || (sample.map { s.hidesPlaceNames(at: $0.coordinate) } ?? false)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm, EEEE"

        var lastStopMinutes: Int?
        var lastStopName: String?
        if let stop = trip.previousStop, !s.hidesPlaceNames(at: stop.coordinate) {
            lastStopMinutes = Int(trip.start.timeIntervalSince(stop.arrival) / 60)
            lastStopName = stop.placeName
        }

        let recent = trip.record.moments.suffix(5).compactMap { m -> MomentSummaryPayload.RecentPlay? in
            guard let played = m.played else { return nil }
            return .init(name: played.track.name, artists: played.track.artists, outcome: m.outcome == .miss ? "skipped" : "played")
        }

        return MomentSummaryPayload(
            type: moment.type,
            detail: moment.detail,
            localTime: formatter.string(from: date),
            weather: sample?.weather?.summary,
            placeKind: nearHome ? nil : sample?.placeKind,
            placeName: nearHome ? nil : sample?.placeName,
            tripMinutes: max(0, Int(trip.minutes(at: date))),
            lastStopMinutes: lastStopMinutes,
            lastStopName: lastStopName,
            recentPlays: recent)
    }

    private func changed() { onChange?(memory) }
}
