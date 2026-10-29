import Foundation

public enum Geo {
    /// Great-circle distance in meters.
    public static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let r = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    public static func interpolate(_ a: Coordinate, _ b: Coordinate, _ t: Double) -> Coordinate {
        Coordinate(latitude: a.latitude + (b.latitude - a.latitude) * t,
                   longitude: a.longitude + (b.longitude - a.longitude) * t)
    }
}

/// Solar position from the NOAA solar calculator equations. Works offline.
public enum SunCalculator {
    public struct Position: Equatable {
        /// Degrees above the horizon (negative = below).
        public var elevation: Double
        /// True after solar noon, i.e. the sun is going down.
        public var isAfternoon: Bool
    }

    public static func position(at date: Date, coordinate: Coordinate) -> Position {
        func rad(_ d: Double) -> Double { d * .pi / 180 }
        func deg(_ r: Double) -> Double { r * 180 / .pi }

        let jd = date.timeIntervalSince1970 / 86_400 + 2_440_587.5
        let jc = (jd - 2_451_545) / 36_525

        let meanLong = (280.46646 + jc * (36000.76983 + jc * 0.0003032)).truncatingRemainder(dividingBy: 360)
        let meanAnom = 357.52911 + jc * (35999.05029 - 0.0001537 * jc)
        let ecc = 0.016708634 - jc * (0.000042037 + 0.0000001267 * jc)
        let center = sin(rad(meanAnom)) * (1.914602 - jc * (0.004817 + 0.000014 * jc))
            + sin(rad(2 * meanAnom)) * (0.019993 - 0.000101 * jc)
            + sin(rad(3 * meanAnom)) * 0.000289
        let trueLong = meanLong + center
        let omega = 125.04 - 1934.136 * jc
        let appLong = trueLong - 0.00569 - 0.00478 * sin(rad(omega))
        let meanObliq = 23 + (26 + (21.448 - jc * (46.815 + jc * (0.00059 - jc * 0.001813))) / 60) / 60
        let obliq = meanObliq + 0.00256 * cos(rad(omega))
        let decl = deg(asin(sin(rad(obliq)) * sin(rad(appLong))))

        let y = pow(tan(rad(obliq / 2)), 2)
        let eqTime = 4 * deg(
            y * sin(2 * rad(meanLong))
            - 2 * ecc * sin(rad(meanAnom))
            + 4 * ecc * y * sin(rad(meanAnom)) * cos(2 * rad(meanLong))
            - 0.5 * y * y * sin(4 * rad(meanLong))
            - 1.25 * ecc * ecc * sin(2 * rad(meanAnom))
        )

        let secondsIntoUTCDay = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400)
        let utcMinutes = (secondsIntoUTCDay < 0 ? secondsIntoUTCDay + 86_400 : secondsIntoUTCDay) / 60
        var trueSolar = (utcMinutes + eqTime + 4 * coordinate.longitude).truncatingRemainder(dividingBy: 1440)
        if trueSolar < 0 { trueSolar += 1440 }
        let hourAngle = trueSolar / 4 < 0 ? trueSolar / 4 + 180 : trueSolar / 4 - 180

        let lat = rad(coordinate.latitude)
        let cosZenith = sin(lat) * sin(rad(decl)) + cos(lat) * cos(rad(decl)) * cos(rad(hourAngle))
        let zenith = deg(acos(max(-1, min(1, cosZenith))))
        return Position(elevation: 90 - zenith, isAfternoon: hourAngle > 0)
    }
}
