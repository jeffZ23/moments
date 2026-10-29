import MomentCore
import SwiftUI

struct DriveView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let trip = model.activeTrip {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(trip.isSimulated ? "Simulated drive" : "Driving", systemImage: "car.fill")
                                .font(.headline)
                            Text("Since \(trip.start.formatted(date: .omitted, time: .shortened)) · \(trip.moments.count) moments")
                                .foregroundStyle(.secondary)
                        }
                        if !trip.isSimulated {
                            Button("End drive", role: .destructive) { model.endTripManually() }
                        }
                    } else {
                        Text(model.autoDetectDrives ? "Waiting for a drive. It starts on its own." : "Drive detection is off.")
                            .foregroundStyle(.secondary)
                        Button("Start a drive now") { model.startTripManually() }
                        Button("I'm a passenger") { model.passengerMode() }
                    }
                }

                if let moment = model.lastMoment {
                    Section("Last moment") { MomentRow(moment: moment) }
                }

                Section {
                    if let progress = model.simulationProgress {
                        ProgressView(value: progress) { Text("Yosemite → Berkeley at sunset") }
                        Button("Stop simulation", role: .destructive) { model.cancelSimulation() }
                    } else {
                        Button("Simulate the Yosemite sunset drive") { model.simulate() }
                            .disabled(model.isTripActive)
                    }
                } header: {
                    Text("Try it")
                } footer: {
                    Text("Replays a 4-hour drive in 4 minutes: leaving Yosemite, sunset, a rain shower, and the last miles home. \(model.simulationPlaysMusic && model.isLoggedIn ? "Songs play in Spotify." : "Songs don't play.") Simulated drives don't train your picks.")
                }

                if !model.status.isEmpty || model.lastError != nil {
                    Section {
                        if !model.status.isEmpty { Text(model.status).foregroundStyle(.secondary) }
                        if let error = model.lastError { Text(error).foregroundStyle(.red) }
                    }
                }
            }
            .navigationTitle("Moments")
        }
    }
}

struct MomentRow: View {
    let moment: MomentRecord
    var showArm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(moment.type.displayName, systemImage: moment.type.symbol)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(moment.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let song = moment.played {
                Text(song.track.name).font(.headline)
                Text(song.track.artistLine).font(.subheadline).foregroundStyle(.secondary)
            }
            Text(moment.displayReason).font(.callout).italic()
            HStack(spacing: 8) {
                if let place = moment.placeName { Text(place) }
                if moment.outcome == .miss { Text("skipped") }
                if moment.outcome == .hit { Text("played through") }
                if showArm && (moment.arm != .baseline || moment.rating != nil) { Text(moment.arm.displayName) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

extension MomentType {
    var symbol: String {
        switch self {
        case .sunset: return "sun.horizon"
        case .rain: return "cloud.rain"
        case .leavingLongStop: return "figure.walk.departure"
        case .nearingHome: return "house"
        }
    }
}
