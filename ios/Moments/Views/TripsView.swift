import MomentCore
import SwiftUI

struct TripsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    StatsSummary(stats: model.stats)
                } header: {
                    Text("How it's doing")
                } footer: {
                    Text("Hit rate counts moment songs you played to the end against ones you skipped in the first 20 seconds. Shuffle is the comparison arm. Simulated drives aren't counted.")
                }

                Section("Trips") {
                    if model.memory.trips.isEmpty {
                        Text("No trips yet. Take a drive or run the simulation.").foregroundStyle(.secondary)
                    }
                    ForEach(model.memory.trips) { trip in
                        NavigationLink {
                            TripDetailView(tripID: trip.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title(for: trip)).font(.headline)
                                Text("\(trip.start.formatted(date: .abbreviated, time: .shortened)) · \(trip.moments.count) moments\(trip.isSimulated ? " · simulated" : "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { model.deleteTrip(model.memory.trips[index]) }
                    }
                }
            }
            .navigationTitle("Trips")
        }
    }

    func title(for trip: TripRecord) -> String {
        switch (trip.startPlace, trip.endPlace) {
        case let (a?, b?): return "\(a) → \(b)"
        case let (a?, nil): return "From \(a)"
        case let (nil, b?): return "To \(b)"
        default: return "Drive"
        }
    }
}

struct StatsSummary: View {
    let stats: [ArmStats]

    var body: some View {
        if stats.isEmpty {
            Text("Numbers show up after your first real drive.").foregroundStyle(.secondary)
        }
        ForEach(stats, id: \.arm) { s in
            HStack {
                Text(s.arm.displayName)
                Spacer()
                Text(s.hitRate.map { "\(Int(($0 * 100).rounded()))% hits" } ?? "–")
                Text(s.averageRating.map { String(format: "%.1f★", $0) } ?? "")
                    .frame(minWidth: 40, alignment: .trailing)
                Text("n=\(s.count)").foregroundStyle(.secondary).frame(minWidth: 40, alignment: .trailing)
            }
            .font(.subheadline.monospacedDigit())
        }
    }
}

struct TripDetailView: View {
    @EnvironmentObject var model: AppModel
    let tripID: UUID

    var trip: TripRecord? {
        model.memory.trips.first { $0.id == tripID } ?? model.activeTrip.flatMap { $0.id == tripID ? $0 : nil }
    }

    var body: some View {
        List {
            if let trip {
                if trip.moments.isEmpty {
                    Text("No moments on this drive.").foregroundStyle(.secondary)
                }
                ForEach(trip.moments) { moment in
                    Section {
                        MomentRow(moment: moment, showArm: true)
                        StarRating(rating: moment.rating) { model.rate(moment, in: trip, stars: $0) }
                    }
                }
            }
        }
        .navigationTitle("Recap")
    }
}

struct StarRating: View {
    let rating: Int?
    let onRate: (Int) -> Void

    var body: some View {
        HStack {
            Text(rating == nil ? "How did it fit?" : "Your rating").font(.caption).foregroundStyle(.secondary)
            Spacer()
            ForEach(1...5, id: \.self) { star in
                Button { onRate(star) } label: {
                    Image(systemName: star <= (rating ?? 0) ? "star.fill" : "star")
                }
                .buttonStyle(.borderless)
            }
        }
    }
}
