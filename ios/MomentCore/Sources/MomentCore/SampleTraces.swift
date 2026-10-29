import Foundation

public enum SampleTraces {
    /// A long day in Yosemite, then the drive home to Berkeley as the sun sets, with a rain shower on the way.
    public static let yosemiteSunsetJSON = """
    {
      "name": "Yosemite → Berkeley at sunset",
      "start": "2026-06-20T19:40:00-07:00",
      "timeZone": "America/Los_Angeles",
      "home": { "minute": 0, "lat": 37.8715, "lon": -122.2730 },
      "previousStop": { "lat": 37.7456, "lon": -119.5936, "name": "Yosemite Valley", "stayedMinutes": 600 },
      "waypoints": [
        { "minute": 0,   "lat": 37.7456, "lon": -119.5936, "raining": false, "weather": "clear, 24°C", "place": "Yosemite National Park", "placeKind": "national park" },
        { "minute": 25,  "lat": 37.7530, "lon": -119.8020 },
        { "minute": 45,  "lat": 37.8000, "lon": -119.8740, "place": "Stanislaus National Forest", "placeKind": "national forest" },
        { "minute": 70,  "lat": 37.8385, "lon": -120.2291, "place": "Groveland", "placeKind": "small town" },
        { "minute": 110, "lat": 37.7666, "lon": -120.8471, "place": "Oakdale", "placeKind": "farmland" },
        { "minute": 120, "lat": 37.7800, "lon": -120.9800, "raining": true, "weather": "light rain, 17°C" },
        { "minute": 150, "lat": 37.7974, "lon": -121.2161, "raining": false, "weather": "clearing, 18°C", "place": "Central Valley", "placeKind": "highway" },
        { "minute": 190, "lat": 37.6819, "lon": -121.7680, "place": "Altamont Pass", "placeKind": "hills" },
        { "minute": 205, "lat": 37.7022, "lon": -121.9358, "place": "Dublin", "placeKind": "suburb" },
        { "minute": 225, "lat": 37.8044, "lon": -122.2712, "place": "Oakland", "placeKind": "city" },
        { "minute": 240, "lat": 37.8715, "lon": -122.2730, "place": "Berkeley", "placeKind": "city" }
      ]
    }
    """

    public static var yosemiteSunset: DriveTrace {
        // The JSON above is a constant checked by the scenario tests, so decoding cannot fail.
        try! JSONDecoder().decode(DriveTrace.self, from: Data(yosemiteSunsetJSON.utf8))
    }
}
