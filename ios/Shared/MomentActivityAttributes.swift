#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import Foundation

/// The lock-screen Live Activity shown during a drive. Shared by the app and the widget extension.
struct MomentActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// e.g. "Sunset" or "Listening for moments"
        var title: String
        var song: String
        var artist: String
        /// The one-line reason the song was picked.
        var reason: String
    }

    var tripStart: Date
}
#endif
