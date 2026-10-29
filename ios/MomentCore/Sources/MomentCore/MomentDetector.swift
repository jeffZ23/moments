import Foundation

public struct MomentSettings: Codable, Hashable {
    public var home: Coordinate?
    /// Sunset window: the sun is between these elevations in the afternoon.
    public var sunsetUpperDegrees: Double = 6
    public var sunsetLowerDegrees: Double = -4
    public var longStopMinutes: Double = 90
    public var leavingWindowMinutes: Double = 30
    public var leavingDistanceMeters: Double = 1_000
    public var nearingHomeMeters: Double = 3_000
    public var nearingHomeMinTripMinutes: Double = 15
    /// Only count "nearing home" if the trip went at least this far from home.
    public var nearingHomeMinFarMeters: Double = 5_000
    /// A stop within this radius of home counts as home, not as a long stop elsewhere.
    public var homePrivacyMeters: Double = 1_000
    /// Place names within this radius of home are never sent to the backend.
    public var placeNamePrivacyMeters: Double = 3_000
    /// Minimum gap between two moment songs.
    public var cooldownMinutes: Double = 15
    /// Share of moments that use the shuffle baseline, for evaluation.
    public var baselineShare: Double = 0.2
    /// Every Nth moment song is a discovery.
    public var discoveryEvery: Int = 5

    public init(home: Coordinate? = nil) {
        self.home = home
    }

    public func isNearHome(_ c: Coordinate) -> Bool {
        guard let home else { return false }
        return Geo.distance(home, c) <= homePrivacyMeters
    }

    /// True where place names would reveal where the driver lives.
    public func hidesPlaceNames(at c: Coordinate) -> Bool {
        guard let home else { return false }
        return Geo.distance(home, c) <= max(placeNamePrivacyMeters, homePrivacyMeters)
    }
}

/// The running state of the current trip.
public struct TripState: Codable, Hashable {
    public var record: TripRecord
    public var startCoordinate: Coordinate
    public var previousStop: StopRecord?
    public var lastSample: ContextSample?
    /// Rain state when the trip's first weather reading arrived.
    public var initialRaining: Bool?
    public var firedMoments: Set<MomentType> = []
    public var lastMomentSongAt: Date?
    public var maxDistanceFromHome: Double = 0

    public init(record: TripRecord, startCoordinate: Coordinate, previousStop: StopRecord?) {
        self.record = record
        self.startCoordinate = startCoordinate
        self.previousStop = previousStop
    }

    public var start: Date { record.start }

    public func minutes(at date: Date) -> Double { date.timeIntervalSince(start) / 60 }

    public mutating func ingest(_ sample: ContextSample, settings: MomentSettings) {
        if initialRaining == nil, let weather = sample.weather { initialRaining = weather.isRaining }
        if let home = settings.home {
            maxDistanceFromHome = max(maxDistanceFromHome, Geo.distance(home, sample.coordinate))
        }
        var merged = sample
        // Keep the last known weather and place when a sample arrives without them.
        if merged.weather == nil { merged.weather = lastSample?.weather }
        if merged.placeName == nil, merged.placeKind == nil {
            merged.placeName = lastSample?.placeName
            merged.placeKind = lastSample?.placeKind
        }
        lastSample = merged
    }

    public func inCooldown(at date: Date, settings: MomentSettings) -> Bool {
        guard let last = lastMomentSongAt else { return false }
        return date.timeIntervalSince(last) < settings.cooldownMinutes * 60
    }
}

public struct DetectedMoment: Equatable {
    /// The moment that leads (decides cut-in and the song mood).
    public var type: MomentType
    /// Other moments happening at the same time, folded into the detail.
    public var alsoTypes: [MomentType]
    public var detail: String

    public init(type: MomentType, alsoTypes: [MomentType], detail: String) {
        self.type = type
        self.alsoTypes = alsoTypes
        self.detail = detail
    }
}

public enum MomentDetector {
    /// When several moments happen together, the first in this list leads.
    static let priority: [MomentType] = [.sunset, .nearingHome, .leavingLongStop, .rain]

    /// Moments whose conditions hold right now and haven't fired this trip.
    /// Conditions are level-based (they stay true for a while), so a moment blocked by the cooldown can still fire later.
    public static func detect(trip: TripState, settings: MomentSettings) -> DetectedMoment? {
        guard let sample = trip.lastSample else { return nil }
        var found: [(MomentType, String)] = []

        for type in priority where !trip.firedMoments.contains(type) {
            if let detail = check(type, sample: sample, trip: trip, settings: settings) {
                found.append((type, detail))
            }
        }
        guard let lead = found.first else { return nil }
        let detail = found.map { $0.1 }.joined(separator: "; ")
        return DetectedMoment(type: lead.0, alsoTypes: found.dropFirst().map { $0.0 }, detail: detail)
    }

    static func check(_ type: MomentType, sample: ContextSample, trip: TripState, settings: MomentSettings) -> String? {
        switch type {
        case .sunset:
            let sun = SunCalculator.position(at: sample.date, coordinate: sample.coordinate)
            guard sun.isAfternoon,
                  sun.elevation <= settings.sunsetUpperDegrees,
                  sun.elevation >= settings.sunsetLowerDegrees else { return nil }
            return sun.elevation > 0 ? "the sun is setting, golden hour" : "the sun just went down, last light of the day"

        case .rain:
            guard let initial = trip.initialRaining, let now = sample.weather?.isRaining, now != initial else { return nil }
            return now ? "rain just started" : "the rain just stopped"

        case .leavingLongStop:
            guard let stop = trip.previousStop else { return nil }
            let stayed = trip.start.timeIntervalSince(stop.arrival) / 60
            guard stayed >= settings.longStopMinutes,
                  !settings.isNearHome(stop.coordinate),
                  trip.minutes(at: sample.date) <= settings.leavingWindowMinutes,
                  Geo.distance(stop.coordinate, sample.coordinate) >= settings.leavingDistanceMeters else { return nil }
            let hours = stayed / 60
            let duration = hours >= 1.5 ? "\(Int(hours.rounded())) hours" : "\(Int(stayed)) minutes"
            return "leaving \(stop.placeName ?? "a place") after \(duration) there"

        case .nearingHome:
            guard let home = settings.home,
                  trip.minutes(at: sample.date) >= settings.nearingHomeMinTripMinutes,
                  trip.maxDistanceFromHome >= settings.nearingHomeMinFarMeters,
                  Geo.distance(home, sample.coordinate) <= settings.nearingHomeMeters else { return nil }
            return "almost home, the last few minutes of the drive"
        }
    }
}
