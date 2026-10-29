import Foundation

/// Decides when a drive starts and ends from motion, speed and the car's Bluetooth.
public struct TripDetector: Codable, Hashable {
    public enum Transition: Equatable { case start, end }

    public var isDriving = false
    /// Riding as a passenger: ignore driving until the current trip would have ended.
    public var passengerMode = false
    public var startNeededSeconds: TimeInterval = 60
    public var stationaryEndSeconds: TimeInterval = 5 * 60
    public var carDisconnectEndSeconds: TimeInterval = 2 * 60
    public var drivingSpeedMps = 7.0
    public var stationarySpeedMps = 1.5

    var drivingSince: Date?
    var stationarySince: Date?
    var carDisconnectedAt: Date?
    var carConnected = false

    public init() {}

    public mutating func carAudio(connected: Bool, at date: Date) -> Transition? {
        carConnected = connected
        if connected {
            carDisconnectedAt = nil
            return begin()
        }
        carDisconnectedAt = date
        return nil
    }

    /// Feed motion activity and speed readings.
    public mutating func reading(automotive: Bool, speedMps: Double?, at date: Date) -> Transition? {
        let moving = automotive || (speedMps ?? 0) >= drivingSpeedMps
        let stopped = !automotive && (speedMps ?? 0) < stationarySpeedMps

        if moving {
            stationarySince = nil
            if drivingSince == nil { drivingSince = date }
        } else {
            drivingSince = nil
            if stopped, stationarySince == nil { stationarySince = date }
            if !stopped { stationarySince = nil }
        }

        if !isDriving {
            if let since = drivingSince, date.timeIntervalSince(since) >= startNeededSeconds { return begin() }
            return nil
        }

        if let at = carDisconnectedAt, date.timeIntervalSince(at) >= carDisconnectEndSeconds { return finish() }
        if !carConnected, let since = stationarySince, date.timeIntervalSince(since) >= stationaryEndSeconds { return finish() }
        return nil
    }

    public mutating func forceStart() -> Transition? { passengerMode = false; return begin() }
    public mutating func forceEnd() -> Transition? { isDriving ? finish() : nil }

    private mutating func begin() -> Transition? {
        guard !isDriving, !passengerMode else { return nil }
        isDriving = true
        stationarySince = nil
        return .start
    }

    private mutating func finish() -> Transition? {
        isDriving = false
        passengerMode = false
        drivingSince = nil
        stationarySince = nil
        carDisconnectedAt = nil
        return .end
    }
}

public struct ArmStats: Hashable {
    public var arm: PickArm
    public var count: Int
    public var hits: Int
    public var misses: Int
    public var ratings: [Int]

    /// Share of judged moment songs that were played through.
    public var hitRate: Double? { hits + misses == 0 ? nil : Double(hits) / Double(hits + misses) }
    public var averageRating: Double? { ratings.isEmpty ? nil : Double(ratings.reduce(0, +)) / Double(ratings.count) }
}

public enum Stats {
    public static func byArm(_ trips: [TripRecord], includeSimulated: Bool = false) -> [ArmStats] {
        var table: [PickArm: ArmStats] = [:]
        for trip in trips where includeSimulated || !trip.isSimulated {
            for m in trip.moments {
                var s = table[m.arm] ?? ArmStats(arm: m.arm, count: 0, hits: 0, misses: 0, ratings: [])
                s.count += 1
                if m.outcome == .hit { s.hits += 1 }
                if m.outcome == .miss { s.misses += 1 }
                if let r = m.rating { s.ratings.append(r) }
                table[m.arm] = s
            }
        }
        return PickArm.allCases.compactMap { table[$0] }
    }
}
