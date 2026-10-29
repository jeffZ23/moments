import MomentCore
import SwiftUI

/// Tag songs for each moment and star your anthems. Tagged songs get a strong boost, and are what plays with no signal.
struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @State private var moment: MomentType = .sunset
    @State private var search = ""

    var songs: [LibraryEntry] {
        let pool = model.library.filter { !$0.isDiscovery }
        let base = search.isEmpty ? Array(model.topTracks.prefix(50)) : pool
        guard !search.isEmpty else { return base }
        return base.filter { $0.track.name.localizedCaseInsensitiveContains(search) || $0.track.artistLine.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Moment", selection: $moment) {
                        ForEach(MomentType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("Tap songs that fit \(moment.displayName.lowercased()). Star a song to make it an anthem: anthems may play every time, everything else rotates.")
                }

                Section(search.isEmpty ? "Your top 50" : "Your library") {
                    if model.library.isEmpty {
                        Text("Connect Spotify in Settings to load your songs.").foregroundStyle(.secondary)
                    }
                    ForEach(songs, id: \.track.id) { entry in
                        SongTagRow(entry: entry, moment: moment)
                    }
                }
            }
            .searchable(text: $search, prompt: "Search your library")
            .navigationTitle("Moment songs")
        }
    }
}

struct SongTagRow: View {
    @EnvironmentObject var model: AppModel
    let entry: LibraryEntry
    let moment: MomentType

    var body: some View {
        let tagged = model.isTagged(entry.track.id, moment)
        HStack {
            Button { model.toggleTag(entry.track.id, moment) } label: {
                HStack {
                    Image(systemName: tagged ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(tagged ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading) {
                        Text(entry.track.name).foregroundStyle(.primary)
                        Text(entry.track.artistLine).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.borderless)
            Spacer()
            Button { model.toggleAnthem(entry.track.id) } label: {
                Image(systemName: model.isAnthem(entry.track.id) ? "star.fill" : "star")
            }
            .buttonStyle(.borderless)
        }
    }
}
