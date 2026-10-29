import Foundation

/// A recorded or hand-written drive that can be replayed with a fake clock and fake weather.
public struct DriveTrace: Codable, Hashable {
    public struct Waypoint: Codable, Hashable {
        /// Minutes after the trace starts.
        public var minute: Double
        public var lat: Double
        public var lon: Double
        public var raining: Bool?
        public var weather: String?
        public var place: String?
        public var placeKind: String?
    }

    public struct Stop: Codable, Hashable {
        public var lat: Double
        public var lon: Double
        public var name: String?
        /// Minutes spent there before the trace starts.
        public var stayedMinutes: Double
    }

    public var name: String
    /// ISO 8601 with offset, e.g. 2026-06-20T19:40:00-07:00
    public var start: String
    public var timeZone: String
    public var home: Waypoint?
    public var previousStop: Stop?
    public var waypoints: [Waypoint]

    public var startDate: Date? { ISO8601DateFormatter().date(from: start) }
    public var homeCoordinate: Coordinate? { home.map { Coordinate(latitude: $0.lat, longitude: $0.lon) } }
    public var durationMinutes: Double { waypoints.last?.minute ?? 0 }

    public func previousStopRecord() -> StopRecord? {
        guard let stop = previousStop, let startDate else { return nil }
        return StopRecord(coordinate: Coordinate(latitude: stop.lat, longitude: stop.lon), placeName: stop.name,
                          arrival: startDate.addingTimeInterval(-stop.stayedMinutes * 60))
    }

    /// Samples every `stepSeconds` of trace time, interpolating position and carrying weather and place forward.
    public func samples(stepSeconds: TimeInterval = 60) -> [ContextSample] {
        guard let startDate, let first = waypoints.first, waypoints.count >= 2 else { return [] }
        var result: [ContextSample] = []
        var weather = first.weather.map { WeatherSnapshot(isRaining: first.raining ?? false, summary: $0) }
        var place = first.place
        var placeKind = first.placeKind
        var segment = 0
        var t = 0.0
        let end = durationMinutes * 60

        while t <= end {
            let minute = t / 60
            while segment < waypoints.count - 2 && waypoints[segment + 1].minute <= minute { segment += 1 }
            let a = waypoints[segment], b = waypoints[segment + 1]

            // Weather and place change when a waypoint is reached.
            for w in waypoints where w.minute <= minute {
                if let summary = w.weather { weather = WeatherSnapshot(isRaining: w.raining ?? false, summary: summary) }
                if w.place != nil || w.placeKind != nil { place = w.place; placeKind = w.placeKind }
            }

            let span = max(b.minute - a.minute, 0.0001)
            let fraction = max(0, min(1, (minute - a.minute) / span))
            let ca = Coordinate(latitude: a.lat, longitude: a.lon)
            let cb = Coordinate(latitude: b.lat, longitude: b.lon)
            let speed = Geo.distance(ca, cb) / (span * 60)
            result.append(ContextSample(date: startDate.addingTimeInterval(t), coordinate: Geo.interpolate(ca, cb, fraction),
                                        speedMps: speed, weather: weather, placeName: place, placeKind: placeKind))
            t += stepSeconds
        }
        return result
    }
}

/// Saves Codable values as JSON files.
public struct JSONFileStore<Value: Codable> {
    public let url: URL

    public init(directory: URL, name: String) {
        self.url = directory.appendingPathComponent(name).appendingPathExtension("json")
    }

    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
