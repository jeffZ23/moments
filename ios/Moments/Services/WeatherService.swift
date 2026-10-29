import Foundation
import MomentCore

/// Current weather from Open-Meteo (free, no API key). Only coarse coordinates are sent.
final class WeatherService {
    private var cache: (date: Date, coordinate: Coordinate, snapshot: WeatherSnapshot)?
    static let refreshInterval: TimeInterval = 10 * 60

    func current(at coordinate: Coordinate, now: Date = Date()) async -> WeatherSnapshot? {
        if let cache, now.timeIntervalSince(cache.date) < Self.refreshInterval, Geo.distance(cache.coordinate, coordinate) < 10_000 {
            return cache.snapshot
        }
        // Round to ~1 km so the exact position isn't shared.
        let lat = (coordinate.latitude * 100).rounded() / 100
        let lon = (coordinate.longitude * 100).rounded() / 100
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(lat)),
            .init(name: "longitude", value: String(lon)),
            .init(name: "current", value: "temperature_2m,precipitation,weather_code"),
        ]
        do {
            let (data, _) = try await URLSession.shared.data(from: components.url!)
            struct Response: Decodable {
                struct Current: Decodable {
                    let temperature_2m: Double?
                    let precipitation: Double?
                    let weather_code: Int?
                }
                let current: Current
            }
            let current = try JSONDecoder().decode(Response.self, from: data).current
            let code = current.weather_code ?? 0
            let raining = (current.precipitation ?? 0) > 0.1 || Self.rainCodes.contains(code)
            var summary = Self.describe(code)
            if let t = current.temperature_2m { summary += ", \(Int(t.rounded()))°C" }
            let snapshot = WeatherSnapshot(isRaining: raining, summary: summary)
            cache = (now, coordinate, snapshot)
            return snapshot
        } catch {
            return cache?.snapshot
        }
    }

    // WMO weather codes: https://open-meteo.com/en/docs
    static let rainCodes: Set<Int> = [51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82, 95, 96, 99]

    static func describe(_ code: Int) -> String {
        switch code {
        case 0: return "clear"
        case 1, 2: return "partly cloudy"
        case 3: return "overcast"
        case 45, 48: return "foggy"
        case 51, 53, 55, 56, 57: return "drizzle"
        case 61, 80: return "light rain"
        case 63, 81: return "rain"
        case 65, 82: return "heavy rain"
        case 66, 67: return "freezing rain"
        case 71, 73, 75, 77, 85, 86: return "snow"
        case 95, 96, 99: return "thunderstorm"
        default: return "cloudy"
        }
    }
}
