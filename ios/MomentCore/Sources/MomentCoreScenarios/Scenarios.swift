import Foundation
import MomentCore

// Behavior checks for MomentCore. Run with `scripts/check-core.sh` (no Xcode needed)
// or `swift test` in ios/MomentCore (Xcode).

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) throws {
    if !condition() { throw CheckFailure(description: "line \(line): \(message)") }
}

// MARK: - Fakes

final class FakeMusic: MusicController {
    var queued: [String] = []
    var skips = 0
    var failing = false

    func addToQueue(uri: String) async throws {
        if failing { throw CheckFailure(description: "spotify down") }
        queued.append(uri)
    }

    func skipToNext() async throws {
        if failing { throw CheckFailure(description: "spotify down") }
        skips += 1
    }
}

final class FakePicker: PickService {
    var requests: [PickRequestPayload] = []
    var failing = false

    func pick(_ request: PickRequestPayload) async throws -> PickResponsePayload {
        requests.append(request)
        if failing { throw CheckFailure(description: "offline") }
        return PickResponsePayload(picks: request.candidates.prefix(3).map { .init(id: $0.id, reason: "fits \(request.moment.type.rawValue)") })
    }
}

struct FixedRandom: RandomSource {
    var values: [Double]
    var index = 0
    mutating func nextDouble() -> Double {
        defer { index += 1 }
        return values.isEmpty ? 0.99 : values[index % values.count]
    }
}

func track(_ id: String, _ name: String, _ artist: String, ms: Int = 240_000) -> Track {
    Track(id: id, uri: "spotify:track:\(id)", name: name, artists: [artist], durationMs: ms)
}

func card(_ id: String, _ moods: [String], _ scenes: [String], _ description: String, confidence: CardConfidence = .high) -> SongCard {
    SongCard(trackID: id, description: description, moods: moods, energy: 3, scenes: scenes, language: "English", confidence: confidence)
}

let sunsetRoad = track("sunset", "日落大道", "梁博")
let comeAndGo = track("comego", "出现又离开", "梁博")
let greenGrass = track("grass", "Green Green Grass", "George Ezra")
let rainSong = track("rain", "Rainy Day Drive", "Some Band")
let homeSong = track("home", "Coming Home", "Another Band")
let mystery = track("mystery", "Unknown Demo", "Nobody")
let newSong = track("new", "Shotgun", "George Ezra")

func sampleLibrary() -> [LibraryEntry] {
    [
        LibraryEntry(track: sunsetRoad, card: card("sunset", ["warm", "nostalgic"], ["golden hour", "sunset drive"], "A slow-building ballad that glows like the end of the day.")),
        LibraryEntry(track: comeAndGo, card: card("comego", ["bittersweet", "reflective"], ["leaving", "open road"], "A bittersweet song about people who come and go.")),
        LibraryEntry(track: greenGrass, card: card("grass", ["carefree", "happy"], ["open highway", "summer"], "Sunny, stomping and carefree."), isTopTrack: true),
        LibraryEntry(track: rainSong, card: card("rain", ["melancholic", "cozy"], ["rainy drive"], "Soft and introspective, like rain on the windshield."), isTopTrack: true),
        LibraryEntry(track: homeSong, card: card("home", ["calm", "content", "warm"], ["coming home"], "A calm, warm song about coming home."), isTopTrack: true),
        LibraryEntry(track: mystery, card: card("mystery", ["golden"], ["golden hour", "sunset"], "Unknown.", confidence: .low)),
        LibraryEntry(track: newSong, card: card("new", ["carefree", "sunny"], ["open highway"], "Loose and sunny."), isDiscovery: true),
    ]
}

func sampleTags() -> UserTags {
    var tags = UserTags()
    tags.toggle(sunsetRoad.id, for: .sunset)
    tags.toggle(comeAndGo.id, for: .leavingLongStop)
    tags.anthems = [sunsetRoad.id]
    return tags
}

@MainActor
func makeConductor(picker: FakePicker? = FakePicker(), music: FakeMusic = FakeMusic(), random: [Double] = [0.99], discoveryEvery: Int = 0) -> MomentConductor {
    var memory = ConductorMemory()
    memory.settings.home = SampleTraces.yosemiteSunset.homeCoordinate
    memory.settings.discoveryEvery = discoveryEvery
    memory.tags = sampleTags()
    return MomentConductor(memory: memory, library: sampleLibrary(), picker: picker, music: music, embedder: nil,
                           timeZone: TimeZone(identifier: "America/Los_Angeles")!, random: FixedRandom(values: random))
}

/// Replays the Yosemite trace through a conductor and returns the moments that fired.
@MainActor
func replay(_ conductor: MomentConductor, trace: DriveTrace = SampleTraces.yosemiteSunset) async -> [MomentRecord] {
    let samples = trace.samples(stepSeconds: 60)
    guard let first = samples.first, let last = samples.last else { return [] }
    conductor.startTrip(at: first.date, coordinate: first.coordinate, placeName: first.placeName, simulated: true, previousStop: trace.previousStopRecord())
    var records: [MomentRecord] = []
    for sample in samples {
        if let r = await conductor.handle(sample) {
            records.append(r)
            // Pretend the song plays to the end before the next sample decides anything.
            let song = r.picks[0].track
            await conductor.observe(PlaybackState(trackURI: song.uri, progressMs: 1_000, durationMs: song.durationMs, isPlaying: true), at: sample.date)
            await conductor.observe(PlaybackState(trackURI: song.uri, progressMs: song.durationMs - 5_000, durationMs: song.durationMs, isPlaying: true), at: sample.date.addingTimeInterval(1))
            await conductor.observe(PlaybackState(trackURI: "spotify:track:other", progressMs: 0, durationMs: 200_000, isPlaying: true), at: sample.date.addingTimeInterval(2))
        }
    }
    conductor.endTrip(at: last.date, coordinate: last.coordinate, placeName: last.placeName)
    return records
}

// MARK: - Scenarios

public enum Scenarios {
    @MainActor
    static let all: [(String, () async throws -> Void)] = [
        ("sun position matches Yosemite in June", sunPosition),
        ("sample trace decodes and interpolates", traceSamples),
        ("Yosemite drive fires four moments in order with cooldown", yosemiteDrive),
        ("cut-in moments skip, long moments only queue", cutInPolicy),
        ("a fast skip plays the backup pick and records a miss", skipPlaysBackup),
        ("no signal uses saved picks, then your tags", offlineFallbacks),
        ("shortlist boosts tags, drops low confidence and recent songs", shortlistRules),
        ("feedback scores and examples", feedbackRules),
        ("place names near home stay private", homePrivacy),
        ("baseline arm uses a shuffle pick and stays blind until rated", baselineArm),
        ("every Nth song comes from discovery", discoveryArm),
        ("trip detector start, passenger mode and end", tripDetector),
        ("stats compute hit rate per arm", stats),
        ("memory survives a JSON round trip", persistence),
    ]

    /// Runs every scenario, prints results, and returns the number of failures.
    @MainActor
    public static func runAll() async -> Int {
        var failures = 0
        for (name, run) in all {
            do {
                try await run()
                print("PASS  \(name)")
            } catch {
                failures += 1
                print("FAIL  \(name): \(error)")
            }
        }
        print(failures == 0 ? "\nAll \(all.count) scenarios passed." : "\n\(failures) of \(all.count) scenarios failed.")
        return failures
    }

    static func sunPosition() throws {
        let valley = Coordinate(latitude: 37.7456, longitude: -119.5936)
        let iso = ISO8601DateFormatter()
        let noon = SunCalculator.position(at: iso.date(from: "2026-06-20T13:00:00-07:00")!, coordinate: valley)
        try expect(noon.elevation > 70 && noon.elevation < 77, "solar noon elevation \(noon.elevation)")
        let sunset = SunCalculator.position(at: iso.date(from: "2026-06-20T20:28:00-07:00")!, coordinate: valley)
        try expect(abs(sunset.elevation) < 2.5, "sunset elevation \(sunset.elevation)")
        try expect(sunset.isAfternoon, "sunset should be afternoon")
        let sunrise = SunCalculator.position(at: iso.date(from: "2026-06-20T05:45:00-07:00")!, coordinate: valley)
        try expect(!sunrise.isAfternoon && abs(sunrise.elevation) < 4, "sunrise \(sunrise)")
    }

    static func traceSamples() throws {
        let trace = SampleTraces.yosemiteSunset
        let samples = trace.samples(stepSeconds: 60)
        try expect(samples.count == 241, "expected 241 samples, got \(samples.count)")
        try expect(samples[0].placeName == "Yosemite National Park", "first place")
        try expect(samples[125].weather?.isRaining == true, "raining at minute 125")
        try expect(samples[160].weather?.isRaining == false, "dry at minute 160")
        try expect(samples[60].speedMps > 5 && samples[60].speedMps < 40, "plausible speed \(samples[60].speedMps)")
        try expect(Geo.distance(samples[240].coordinate, trace.homeCoordinate!) < 10, "ends at home")
    }

    @MainActor
    static func yosemiteDrive() async throws {
        let conductor = makeConductor()
        let records = await replay(conductor)
        let types = records.map(\.type)
        try expect(types == [.leavingLongStop, .sunset, .rain, .nearingHome], "fired \(types)")
        for (a, b) in zip(records, records.dropFirst()) {
            try expect(b.date.timeIntervalSince(a.date) >= 15 * 60, "cooldown between \(a.type) and \(b.type)")
        }
        try expect(records[0].detail.contains("Yosemite Valley") && records[0].detail.contains("10 hours"), "leaving detail: \(records[0].detail)")
        try expect(records[0].picks.first?.track.id == comeAndGo.id, "leaving should pick 出现又离开, got \(records[0].picks.first?.track.name ?? "-")")
        try expect(records[1].picks.first?.track.id == sunsetRoad.id, "sunset should pick 日落大道, got \(records[1].picks.first?.track.name ?? "-")")
        try expect(records.allSatisfy { $0.arm == .engine }, "all engine picks")
        let trip = conductor.memory.trips.first
        try expect(trip?.moments.count == 4 && trip?.moments.allSatisfy { $0.outcome == .hit } == true, "trip recap stores 4 hits")
        try expect(conductor.memory.lastStop == nil, "simulated trips don't move the last stop")
        try expect(conductor.memory.feedback == FeedbackStore() && conductor.memory.momentSongCount == 0, "simulations don't train the picker")
    }

    @MainActor
    static func cutInPolicy() async throws {
        let music = FakeMusic()
        let conductor = makeConductor(music: music)
        let records = await replay(conductor)
        // leaving waits (no skip); sunset, rain, nearing home cut in.
        try expect(music.queued.count == 4, "queued \(music.queued.count)")
        try expect(music.skips == 3, "skips \(music.skips)")
        try expect(records.count == 4, "records")
    }

    @MainActor
    static func skipPlaysBackup() async throws {
        let music = FakeMusic()
        let conductor = makeConductor(music: music)
        let trace = SampleTraces.yosemiteSunset
        let samples = trace.samples()
        conductor.startTrip(at: samples[0].date, coordinate: samples[0].coordinate, placeName: nil, previousStop: trace.previousStopRecord())
        var record: MomentRecord?
        for s in samples where record == nil { record = await conductor.handle(s) }
        guard let first = record else { throw CheckFailure(description: "no moment fired") }
        let song = first.picks[0].track
        let t = first.date
        await conductor.observe(PlaybackState(trackURI: song.uri, progressMs: 2_000, durationMs: song.durationMs, isPlaying: true), at: t.addingTimeInterval(5))
        await conductor.observe(PlaybackState(trackURI: song.uri, progressMs: 8_000, durationMs: song.durationMs, isPlaying: true), at: t.addingTimeInterval(10))
        await conductor.observe(PlaybackState(trackURI: "spotify:track:else", progressMs: 0, durationMs: 1, isPlaying: true), at: t.addingTimeInterval(15))

        let updated = conductor.memory.activeTrip?.record.moments.first
        try expect(updated?.playedIndex == 1, "backup should be playing, index \(updated?.playedIndex ?? -1)")
        try expect(music.queued.last == first.picks[1].track.uri, "backup queued")
        try expect(conductor.memory.feedback.score(trackID: song.id, moment: first.type) == -2, "miss scored -2")
        try expect(conductor.memory.feedback.misses.first?.name == song.name, "miss example recorded")
    }

    @MainActor
    static func offlineFallbacks() async throws {
        // Saved-ahead picks are used when the backend fails.
        let picker = FakePicker()
        let conductor = makeConductor(picker: picker)
        let trace = SampleTraces.yosemiteSunset
        let samples = trace.samples()
        conductor.startTrip(at: samples[0].date, coordinate: samples[0].coordinate, placeName: nil, previousStop: trace.previousStopRecord())
        _ = await conductor.handle(samples[0]) // ingest only: still at the stop, nothing fires
        let upcoming = conductor.likelyUpcoming(at: samples[0].date).map(\.type)
        try expect(upcoming.contains(.sunset) && upcoming.contains(.leavingLongStop), "upcoming \(upcoming)")
        await conductor.prefetch(at: samples[0].date)
        try expect(!conductor.memory.pickCache.entries.isEmpty, "prefetch stored picks")
        picker.failing = true
        var record: MomentRecord?
        for s in samples.dropFirst() where record == nil { record = await conductor.handle(s) }
        try expect(record?.arm == .offlineCache, "expected offline cache, got \(String(describing: record?.arm))")

        // With nothing saved and no backend, it falls back to tagged songs, anthems first.
        let bare = makeConductor(picker: nil)
        let records = await replay(bare)
        try expect(records.first?.arm == .fallbackRule, "fallback arm")
        try expect(records.first?.picks.first?.track.id == comeAndGo.id, "leaving falls back to its tagged song")
        let sunset = records.first { $0.type == .sunset }
        try expect(sunset?.picks.first?.track.id == sunsetRoad.id, "sunset falls back to the anthem")
    }

    static func shortlistRules() throws {
        let moment = DetectedMoment(type: .sunset, alsoTypes: [], detail: "the sun is setting")
        let query = MomentQuery.text(for: moment, raining: false)
        let tags = sampleTags()
        let list = Shortlister.shortlist(moment: moment, query: query, library: sampleLibrary(), tags: tags, feedback: FeedbackStore(), recentlyPlayed: [greenGrass.id], embeddings: nil, discovery: false)
        let ids = list.map { $0.entry.track.id }
        try expect(ids.first == sunsetRoad.id, "tagged anthem first: \(ids)")
        try expect(!ids.contains(mystery.id), "low confidence untagged dropped")
        try expect(!ids.contains(greenGrass.id), "recently played dropped")
        try expect(!ids.contains(newSong.id), "discovery songs only in discovery mode")

        var blocked = FeedbackStore()
        blocked.adjust(homeSong, moment: .sunset, by: -4)
        let list2 = Shortlister.shortlist(moment: moment, query: query, library: sampleLibrary(), tags: tags, feedback: blocked, recentlyPlayed: [], embeddings: nil, discovery: false)
        try expect(!list2.map { $0.entry.track.id }.contains(homeSong.id), "blocked by feedback")

        let recentAnthem = Shortlister.shortlist(moment: moment, query: query, library: sampleLibrary(), tags: tags, feedback: FeedbackStore(), recentlyPlayed: [sunsetRoad.id], embeddings: nil, discovery: false)
        try expect(recentAnthem.first?.entry.track.id == sunsetRoad.id, "anthems may repeat")
    }

    static func feedbackRules() throws {
        var fb = FeedbackStore()
        fb.record(.hit, track: sunsetRoad, moment: .sunset)
        fb.record(.miss, track: greenGrass, moment: .sunset)
        fb.recordRating(5, track: sunsetRoad, moment: .sunset)
        try expect(fb.score(trackID: sunsetRoad.id, moment: .sunset) == 3, "hit + 5 stars = 3")
        try expect(fb.score(trackID: sunsetRoad.id, moment: .rain) == 0, "per moment")
        try expect(fb.score(trackID: greenGrass.id, moment: .sunset) == -2, "miss = -2")
        for _ in 0..<15 { fb.record(.miss, track: track(UUID().uuidString, "x\(Int.random(in: 0...99999))", "y"), moment: .rain) }
        try expect(fb.misses.count == FeedbackStore.maxExamples, "examples capped")
    }

    @MainActor
    static func homePrivacy() async throws {
        let picker = FakePicker()
        let conductor = makeConductor(picker: picker)
        _ = await replay(conductor)
        let summaries = picker.requests.map(\.moment)
        try expect(summaries.first?.placeName == "Yosemite National Park", "public place kept: \(summaries.first?.placeName ?? "nil")")
        try expect(summaries.first?.lastStopMinutes == 600, "last stop minutes")
        let home = summaries.first { $0.type == .nearingHome }
        try expect(home != nil && home?.placeName == nil && home?.placeKind == nil, "no place name near home")
        try expect(summaries.first?.localTime.hasPrefix("19:4") == true, "local time in trace zone: \(summaries.first?.localTime ?? "")")
    }

    @MainActor
    static func baselineArm() async throws {
        let conductor = makeConductor(random: [0.1, 0.0])
        let trace = SampleTraces.yosemiteSunset
        let samples = trace.samples()
        conductor.startTrip(at: samples[0].date, coordinate: samples[0].coordinate, placeName: nil, previousStop: trace.previousStopRecord())
        var record: MomentRecord?
        for s in samples where record == nil { record = await conductor.handle(s) }
        try expect(record?.arm == .baseline, "baseline arm")
        try expect(sampleLibrary().first { $0.track.id == record?.picks.first?.track.id }?.isTopTrack == true, "from top tracks")
        try expect(record?.displayReason == "Picked for this moment", "blind until rated")
        guard let r = record, let tripID = conductor.memory.activeTrip?.record.id else { return }
        conductor.rate(momentID: r.id, tripID: tripID, stars: 2)
        let rated = conductor.memory.activeTrip?.record.moments.first
        try expect(rated?.displayReason.contains("shuffle") == true, "revealed after rating")
    }

    @MainActor
    static func discoveryArm() async throws {
        let picker = FakePicker()
        let conductor = makeConductor(picker: picker, discoveryEvery: 1)
        let records = await replay(conductor)
        try expect(records.first?.arm == .discovery, "first song is discovery: \(String(describing: records.first?.arm))")
        try expect(picker.requests.first?.candidates.allSatisfy(\.isDiscovery) == true, "discovery candidates only")
        // The pool has one song; once used, later moments fall back to the library.
        try expect(records.dropFirst().allSatisfy { $0.arm == .engine }, "pool exhausted -> engine")
    }

    static func tripDetector() throws {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var d = TripDetector()
        try expect(d.reading(automotive: true, speedMps: 10, at: t0) == nil, "not yet")
        try expect(d.reading(automotive: true, speedMps: 12, at: t0.addingTimeInterval(61)) == .start, "starts after 60s")
        try expect(d.reading(automotive: false, speedMps: 0, at: t0.addingTimeInterval(120)) == nil, "short stop")
        try expect(d.reading(automotive: false, speedMps: 0, at: t0.addingTimeInterval(200)) == nil, "still short")
        try expect(d.reading(automotive: true, speedMps: 10, at: t0.addingTimeInterval(220)) == nil, "traffic light resets")
        try expect(d.reading(automotive: false, speedMps: 0, at: t0.addingTimeInterval(300)) == nil, "stop again")
        try expect(d.reading(automotive: false, speedMps: 0, at: t0.addingTimeInterval(601)) == .end, "ends after 5 min stopped")

        var p = TripDetector()
        p.passengerMode = true
        _ = p.reading(automotive: true, speedMps: 20, at: t0)
        try expect(p.reading(automotive: true, speedMps: 20, at: t0.addingTimeInterval(120)) == nil, "passenger ignored")
        try expect(p.forceStart() == .start, "manual start overrides")

        var car = TripDetector()
        try expect(car.carAudio(connected: true, at: t0) == .start, "car bluetooth starts")
        _ = car.carAudio(connected: false, at: t0.addingTimeInterval(10))
        try expect(car.reading(automotive: false, speedMps: 0, at: t0.addingTimeInterval(140)) == .end, "car disconnect ends after 2 min")
    }

    static func stats() throws {
        let pick = PickedSong(track: sunsetRoad, reason: "")
        let trip = TripRecord(start: Date(), moments: [
            MomentRecord(type: .sunset, detail: "", date: Date(), placeName: nil, picks: [pick], arm: .engine, outcome: .hit, rating: 5),
            MomentRecord(type: .rain, detail: "", date: Date(), placeName: nil, picks: [pick], arm: .engine, outcome: .miss, rating: 3),
            MomentRecord(type: .rain, detail: "", date: Date(), placeName: nil, picks: [pick], arm: .baseline, outcome: .miss),
        ])
        let s = Stats.byArm([trip])
        try expect(s.first { $0.arm == .engine }?.hitRate == 0.5, "engine 50%")
        try expect(s.first { $0.arm == .engine }?.averageRating == 4, "engine avg 4")
        try expect(s.first { $0.arm == .baseline }?.hitRate == 0, "baseline 0%")
        var sim = trip
        sim.isSimulated = true
        try expect(Stats.byArm([sim]).isEmpty, "simulated trips excluded")
    }

    @MainActor
    static func persistence() async throws {
        let conductor = makeConductor()
        _ = await replay(conductor)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("moments-\(UUID().uuidString)")
        let store = JSONFileStore<ConductorMemory>(directory: dir, name: "memory")
        try store.save(conductor.memory)
        let loaded = store.load()
        try expect(loaded == conductor.memory, "round trip equal")
        try? FileManager.default.removeItem(at: dir)
    }
}
