import ActivityKit
import SwiftUI
import WidgetKit

@main
struct MomentsWidgetBundle: WidgetBundle {
    var body: some Widget {
        MomentLiveActivity()
    }
}

struct MomentLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MomentActivityAttributes.self) { context in
            LockScreenMoment(state: context.state)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "music.note")
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.song.isEmpty ? context.state.title : context.state.song)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.reason)
                        .font(.caption)
                        .lineLimit(2)
                }
            } compactLeading: {
                Image(systemName: "music.note")
            } compactTrailing: {
                Text(context.state.title)
                    .font(.caption2)
                    .lineLimit(1)
            } minimal: {
                Image(systemName: "music.note")
            }
        }
    }
}

struct LockScreenMoment: View {
    let state: MomentActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if state.song.isEmpty {
                Text("Moments is listening to your drive")
                    .font(.headline)
            } else {
                Text("\(state.song) — \(state.artist)")
                    .font(.headline)
                    .lineLimit(1)
                Text(state.reason)
                    .font(.subheadline)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
