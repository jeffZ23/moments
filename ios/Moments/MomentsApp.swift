import SwiftUI

@main
struct MomentsApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.onboarded {
            TabView {
                DriveView().tabItem { Label("Drive", systemImage: "car") }
                TripsView().tabItem { Label("Trips", systemImage: "list.bullet.rectangle") }
                SetupView().tabItem { Label("Moments", systemImage: "music.note.list") }
                SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
            }
        } else {
            OnboardingView()
        }
    }
}
