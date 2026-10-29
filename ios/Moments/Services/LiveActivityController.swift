import Foundation
import MomentCore
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

/// The lock-screen card during a drive: the current moment, the song, and why it was picked.
@MainActor
final class LiveActivityController {
    #if canImport(ActivityKit) && os(iOS)
    private var activity: Activity<MomentActivityAttributes>?
    #endif

    func start(tripStart: Date) {
        #if canImport(ActivityKit) && os(iOS)
        guard ActivityAuthorizationInfo().areActivitiesEnabled, activity == nil else { return }
        let state = MomentActivityAttributes.ContentState(title: "Listening for moments", song: "", artist: "", reason: "")
        activity = try? Activity.request(attributes: MomentActivityAttributes(tripStart: tripStart),
                                         content: .init(state: state, staleDate: nil))
        #endif
    }

    func show(_ record: MomentRecord) {
        #if canImport(ActivityKit) && os(iOS)
        guard let activity, let played = record.played else { return }
        let state = MomentActivityAttributes.ContentState(title: record.type.displayName, song: played.track.name,
                                                          artist: played.track.artistLine, reason: record.displayReason)
        Task { await activity.update(.init(state: state, staleDate: nil)) }
        #endif
    }

    func end() {
        #if canImport(ActivityKit) && os(iOS)
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .default) }
        #endif
    }
}
