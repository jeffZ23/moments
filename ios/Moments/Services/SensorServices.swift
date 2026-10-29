import CoreLocation
import Foundation
import MomentCore
#if os(iOS)
import AVFoundation
import CoreMotion
#endif

/// Location updates, kept running in the background while drive detection is on.
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onLocation: ((CLLocation) -> Void)?
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
    }

    var authorization: CLAuthorizationStatus { manager.authorizationStatus }
    var lastLocation: CLLocation? { manager.location }

    func requestPermission() {
        #if os(iOS)
        manager.requestAlwaysAuthorization()
        #else
        manager.requestWhenInUseAuthorization()
        #endif
    }

    /// Coarse updates between drives, precise ones during a drive.
    func start(precise: Bool) {
        manager.desiredAccuracy = precise ? kCLLocationAccuracyBest : kCLLocationAccuracyHundredMeters
        manager.distanceFilter = precise ? 25 : 100
        #if os(iOS)
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        #endif
        manager.startUpdatingLocation()
        // Relaunches the app after the system ends it, so drives are still noticed.
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.startMonitoringSignificantLocationChanges()
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in self.onLocation?(last) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.onAuthorizationChange?(status) }
    }
}

/// Turns coordinates into place names like "Yosemite National Park", rate-limited to respect the geocoder.
@MainActor
final class PlaceNamer {
    private let geocoder = CLGeocoder()
    private var last: (date: Date, location: CLLocation, name: String?, kind: String?)?

    func describe(_ location: CLLocation) async -> (name: String?, kind: String?) {
        if let last, Date().timeIntervalSince(last.date) < 300, location.distance(from: last.location) < 2_000 {
            return (last.name, last.kind)
        }
        let placemark = try? await geocoder.reverseGeocodeLocation(location).first
        let area = placemark?.areasOfInterest?.first
        let name = area ?? placemark?.locality ?? placemark?.subAdministrativeArea
        var kind = area.flatMap(Self.kind(for:))
        if kind == nil, location.speed > 24 { kind = "highway" }
        if kind == nil, placemark?.locality != nil { kind = "town or city" }
        last = (Date(), location, name, kind)
        return (name, kind)
    }

    static func kind(for name: String) -> String? {
        let lower = name.lowercased()
        let table: [(String, String)] = [
            ("national park", "national park"), ("state park", "state park"), ("national forest", "national forest"),
            ("beach", "beach"), ("lake", "lake"), ("forest", "forest"), ("mountain", "mountains"),
            ("bridge", "bridge"), ("park", "park"), ("coast", "coast"), ("bay", "bay"), ("valley", "valley"),
        ]
        return table.first { lower.contains($0.0) }?.1
    }
}

/// Motion activity ("automotive") from the motion coprocessor.
@MainActor
final class MotionService {
    var onActivity: ((Bool) -> Void)?
    #if os(iOS)
    private let manager = CMMotionActivityManager()
    #endif

    var isAvailable: Bool {
        #if os(iOS)
        return CMMotionActivityManager.isActivityAvailable()
        #else
        return false
        #endif
    }

    func start() {
        #if os(iOS)
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        manager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity, activity.confidence != .low else { return }
            self?.onActivity?(activity.automotive)
        }
        #endif
    }

    func stop() {
        #if os(iOS)
        manager.stopActivityUpdates()
        #endif
    }
}

/// Notices when the phone connects to the chosen car's Bluetooth audio.
@MainActor
final class CarAudioMonitor {
    var onChange: ((Bool) -> Void)?
    var carName: String?
    private var observer: NSObjectProtocol?

    /// Names of Bluetooth audio outputs connected right now.
    var connectedBluetoothNames: [String] {
        #if os(iOS)
        let bluetooth: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .carAudio]
        return AVAudioSession.sharedInstance().currentRoute.outputs.filter { bluetooth.contains($0.portType) }.map(\.portName)
        #else
        return []
        #endif
    }

    var isCarConnected: Bool {
        guard let carName, !carName.isEmpty else { return false }
        return connectedBluetoothNames.contains(carName)
    }

    func start() {
        #if os(iOS)
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.onChange?(self.isCarConnected)
            }
        }
        #endif
    }
}
