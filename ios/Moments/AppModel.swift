import CoreLocation
import Foundation
import MomentCore
import SwiftUI

/// Plays nothing; used for simulations when Spotify isn't connected or real playback is off.
final class DryRunMusic: MusicController {
    func addToQueue(uri: String) async throws {}
    func skipToNext() async throws {}
}

/// Wires sensors, Spotify, the backend and the MomentConductor together, and persists everything.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var memory: ConductorMemory
    @Published private(set) var library: [LibraryEntry]
    @Published private(set) var isLoggedIn: Bool
    @Published var status = ""
    @Published var lastError: String?
    @Published private(set) var isWorking = false
    @Published private(set) var simulationProgress: Double?
    @Published private(set) var lastMoment: MomentRecord?

    @AppStorage("autoDetectDrives") var autoDetectDrives = false
    @AppStorage("carBluetoothName") var carBluetoothName = ""
    @AppStorage("simulationPlaysMusic") var simulationPlaysMusic = true
    @AppStorage("onboarded") var onboarded = false

    let config = AppConfig.current
    private let auth: SpotifyAuth
    private let spotify: SpotifyClient
    private let backend: BackendClient
    private let weather = WeatherService()
    private let location = LocationService()
    private let places = PlaceNamer()
    private let motion = MotionService()
    private let carAudio = CarAudioMonitor()
    private let liveActivity = LiveActivityController()
    private let embedder = SentenceEmbedder()
    private var conductor: MomentConductor
    private var detector = TripDetector()
    private var automotive = false
    private var lastHandled: Date?
    private var playbackTimer: Timer?
    private var prefetchTimer: Timer?
    private var simulationTask: Task<Void, Never>?

    private let memoryStore: JSONFileStore<ConductorMemory>
    private let libraryStore: JSONFileStore<[LibraryEntry]>

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Moments")
        memoryStore = JSONFileStore(directory: dir, name: "memory")
        libraryStore = JSONFileStore(directory: dir, name: "library")
        let memory = memoryStore.load() ?? ConductorMemory()
        let library = libraryStore.load() ?? []
        self.memory = memory
        self.library = library

        auth = SpotifyAuth(config: config)
        spotify = SpotifyClient(auth: auth)
        backend = BackendClient(config: config)
        isLoggedIn = auth.isLoggedIn
        conductor = MomentConductor(memory: memory, library: library, picker: backend, music: spotify, embedder: embedder)
        attach(conductor)
        wireSensors()
        if autoDetectDrives { startDriveDetection() }
    }

    // MARK: Derived

    var topTracks: [LibraryEntry] { library.filter { $0.isTopTrack } }
    var cardCount: Int { library.filter { $0.card != nil }.count }
    var discoveryCount: Int { library.filter { $0.isDiscovery }.count }
    var isTripActive: Bool { memory.activeTrip != nil }
    var activeTrip: TripRecord? { memory.activeTrip?.record }
    var stats: [ArmStats] { Stats.byArm(memory.trips) }

    // MARK: Spotify + library

    func logIn() async {
        await run("Connecting to Spotify…") {
            try await self.auth.logIn()
            self.isLoggedIn = true
            try await self.refreshLibrary()
        }
    }

    func logOut() {
        auth.logOut()
        isLoggedIn = false
    }

    func refreshLibrary() async throws {
        let builder = LibraryBuilder(spotify: spotify, backend: backend)
        builder.onProgress = { [weak self] in self?.status = $0 }
        var updated = try await builder.importLibrary(existing: library)
        setLibrary(updated)
        await builder.buildCards(&updated, priority: memory.tags.allTagged.union(memory.tags.anthems)) { [weak self] in self?.setLibrary($0) }
        if !updated.contains(where: \.isDiscovery) {
            await builder.buildDiscoveryPool(&updated) { [weak self] in self?.setLibrary($0) }
        }
        setLibrary(updated)
        status = "\(updated.count) songs, \(updated.filter { $0.card != nil }.count) with cards."
    }

    func reloadLibrary() async {
        await run("Refreshing your library…") { try await self.refreshLibrary() }
    }

    private func setLibrary(_ entries: [LibraryEntry]) {
        library = entries
        conductor.library = entries
        try? libraryStore.save(entries)
    }

    // MARK: Setup

    func isTagged(_ id: String, _ type: MomentType) -> Bool { memory.tags.isTagged(id, for: type) }
    func isAnthem(_ id: String) -> Bool { memory.tags.anthems.contains(id) }
    func toggleTag(_ id: String, _ type: MomentType) { conductor.updateTags { $0.toggle(id, for: type) } }
    func toggleAnthem(_ id: String) {
        conductor.updateTags { tags in
            if tags.anthems.contains(id) { tags.anthems.remove(id) } else { tags.anthems.insert(id) }
        }
    }

    func setHomeToCurrentLocation() {
        guard let here = location.lastLocation else {
            lastError = "No location yet. Allow location access and try again."
            location.requestPermission()
            return
        }
        conductor.updateSettings { $0.home = Coordinate(latitude: here.coordinate.latitude, longitude: here.coordinate.longitude) }
        status = "Home set."
    }

    func setBaselineShare(_ value: Double) { conductor.updateSettings { $0.baselineShare = value } }

    func requestLocationPermission() { location.requestPermission() }

    var bluetoothOutputs: [String] { carAudio.connectedBluetoothNames }

    // MARK: Drives

    func startDriveDetection() {
        autoDetectDrives = true
        location.requestPermission()
        location.start(precise: isTripActive)
        motion.start()
        carAudio.carName = carBluetoothName
        carAudio.start()
    }

    func stopDriveDetection() {
        autoDetectDrives = false
        if !isTripActive { location.stop() }
        motion.stop()
    }

    func startTripManually() {
        if detector.forceStart() == .start { beginTrip() }
    }

    func endTripManually() {
        if detector.forceEnd() == .end || isTripActive { finishTrip() }
    }

    /// Ignore driving until this trip would have ended (riding as a passenger).
    func passengerMode() {
        if isTripActive { endTripManually() }
        detector.passengerMode = true
        status = "Passenger mode: this ride won't be tracked."
    }

    private func wireSensors() {
        location.onLocation = { [weak self] loc in self?.locationUpdated(loc) }
        motion.onActivity = { [weak self] isAutomotive in
            guard let self else { return }
            self.automotive = isAutomotive
            self.apply(self.detector.reading(automotive: isAutomotive, speedMps: self.location.lastLocation?.speed, at: Date()))
        }
        carAudio.onChange = { [weak self] connected in
            guard let self else { return }
            self.apply(self.detector.carAudio(connected: connected, at: Date()))
        }
    }

    private func apply(_ transition: TripDetector.Transition?) {
        switch transition {
        case .start: beginTrip()
        case .end: finishTrip()
        case nil: break
        }
    }

    private func locationUpdated(_ loc: CLLocation) {
        guard simulationTask == nil else { return }
        apply(detector.reading(automotive: automotive, speedMps: loc.speed >= 0 ? loc.speed : nil, at: loc.timestamp))
        guard isTripActive else { return }
        // A reading every 20 seconds is plenty for moments.
        if let last = lastHandled, loc.timestamp.timeIntervalSince(last) < 20 { return }
        lastHandled = loc.timestamp
        Task { await self.handleRealLocation(loc) }
    }

    private func handleRealLocation(_ loc: CLLocation) async {
        let coordinate = Coordinate(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude)
        async let weatherNow = weather.current(at: coordinate)
        async let place = places.describe(loc)
        let (w, p) = await (weatherNow, place)
        let sample = ContextSample(date: loc.timestamp, coordinate: coordinate, speedMps: max(0, loc.speed), weather: w, placeName: p.name, placeKind: p.kind)
        if let record = await conductor.handle(sample) { lastMoment = record }
    }

    private func beginTrip() {
        guard !isTripActive else { return }
        let loc = location.lastLocation
        let coordinate = loc.map { Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) } ?? Coordinate(latitude: 0, longitude: 0)
        conductor.startTrip(at: Date(), coordinate: coordinate, placeName: nil)
        location.start(precise: true)
        liveActivity.start(tripStart: Date())
        startTripTimers()
        status = "Drive started. Listening for moments."
        // Pick ahead right away, while there's (probably) still signal at the start of the drive.
        Task {
            if let loc { await self.handleRealLocation(loc) }
            await self.prefetch()
        }
    }

    private func finishTrip() {
        guard isTripActive else { return }
        stopTripTimers()
        let loc = location.lastLocation
        let coordinate = loc.map { Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) } ?? Coordinate(latitude: 0, longitude: 0)
        let placeName = memory.activeTrip?.lastSample?.placeName
        conductor.endTrip(at: Date(), coordinate: coordinate, placeName: placeName)
        liveActivity.end()
        if autoDetectDrives { location.start(precise: false) } else { location.stop() }
        status = "Drive ended. Rate your moments in Trips."
    }

    private func startTripTimers() {
        stopTripTimers()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.pollPlayback() }
        }
        prefetchTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.prefetch() }
        }
    }

    private func stopTripTimers() {
        playbackTimer?.invalidate()
        prefetchTimer?.invalidate()
        playbackTimer = nil
        prefetchTimer = nil
    }

    private func prefetch() async {
        await conductor.prefetch(at: Date())
    }

    private func pollPlayback() async {
        guard isLoggedIn, simulationTask == nil else { return }
        let state = try? await spotify.playbackState()
        await conductor.observe(state, at: Date())
    }

    func rate(_ moment: MomentRecord, in trip: TripRecord, stars: Int) {
        conductor.rate(momentID: moment.id, tripID: trip.id, stars: stars)
    }

    func deleteTrip(_ trip: TripRecord) {
        var memory = conductor.memory
        memory.trips.removeAll { $0.id == trip.id }
        replaceMemory(memory)
    }

    // MARK: Simulation

    var isSimulating: Bool { simulationTask != nil }

    /// Replays the sample Yosemite drive: one minute of drive per `secondsPerMinute` real seconds.
    func simulate(trace: DriveTrace = SampleTraces.yosemiteSunset, secondsPerMinute: Double = 1) {
        guard simulationTask == nil, !isTripActive else { return }
        let samples = trace.samples(stepSeconds: 60)
        guard let first = samples.first, let last = samples.last else { return }

        // A separate conductor with the trace's home, clock zone and (optionally) real playback.
        var simMemory = conductor.memory
        simMemory.settings.home = trace.homeCoordinate
        simMemory.activeTrip = nil
        let music: MusicController = (isLoggedIn && simulationPlaysMusic) ? spotify : DryRunMusic()
        let sim = MomentConductor(memory: simMemory, library: library, picker: backend, music: music, embedder: embedder,
                                  timeZone: TimeZone(identifier: trace.timeZone) ?? .current)
        sim.onChange = { [weak self] in self?.memory = $0 }
        sim.onMoment = { [weak self] record in
            self?.lastMoment = record
            self?.liveActivity.show(record)
        }

        simulationProgress = 0
        liveActivity.start(tripStart: Date())
        status = "Simulating: \(trace.name)"
        simulationTask = Task { [weak self] in
            sim.startTrip(at: first.date, coordinate: first.coordinate, placeName: first.placeName, simulated: true, previousStop: trace.previousStopRecord())
            for (i, sample) in samples.enumerated() {
                if Task.isCancelled { break }
                if let record = await sim.handle(sample), let song = record.played?.track {
                    // Close the moment right away so the simulated clock can keep moving.
                    await sim.observe(PlaybackState(trackURI: song.uri, progressMs: 1_000, durationMs: song.durationMs, isPlaying: true), at: sample.date)
                    await sim.observe(PlaybackState(trackURI: song.uri, progressMs: song.durationMs, durationMs: song.durationMs, isPlaying: true), at: sample.date)
                    await sim.observe(nil, at: sample.date)
                }
                self?.simulationProgress = Double(i + 1) / Double(samples.count)
                try? await Task.sleep(nanoseconds: UInt64(secondsPerMinute * 1_000_000_000))
            }
            sim.endTrip(at: last.date, coordinate: last.coordinate, placeName: last.placeName)
            self?.finishSimulation(sim.memory)
        }
    }

    func cancelSimulation() {
        simulationTask?.cancel()
    }

    private func finishSimulation(_ simMemory: ConductorMemory) {
        // Keep only the recap from the simulation; settings and learning stay as they were.
        var memory = conductor.memory
        if let trip = simMemory.trips.first, trip.isSimulated { memory.trips.insert(trip, at: 0) }
        replaceMemory(memory)
        liveActivity.end()
        simulationTask = nil
        simulationProgress = nil
        status = "Simulation finished. See the recap in Trips."
    }

    // MARK: Plumbing

    private func attach(_ conductor: MomentConductor) {
        conductor.onChange = { [weak self] memory in
            guard let self else { return }
            self.memory = memory
            try? self.memoryStore.save(memory)
        }
        conductor.onMoment = { [weak self] record in
            self?.lastMoment = record
            self?.liveActivity.show(record)
        }
    }

    private func replaceMemory(_ memory: ConductorMemory) {
        conductor = MomentConductor(memory: memory, library: library, picker: backend, music: spotify, embedder: embedder)
        attach(conductor)
        self.memory = memory
        try? memoryStore.save(memory)
    }

    private func run(_ message: String, _ work: @escaping () async throws -> Void) async {
        isWorking = true
        status = message
        lastError = nil
        do { try await work() } catch { lastError = error.localizedDescription }
        isWorking = false
    }
}
