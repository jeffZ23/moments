import MomentCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Spotify") {
                    if model.isLoggedIn {
                        LabeledContent("Songs", value: "\(model.library.count)")
                        LabeledContent("Song cards", value: "\(model.cardCount)")
                        LabeledContent("Discovery pool", value: "\(model.discoveryCount)")
                        Button("Refresh library") { Task { await model.reloadLibrary() } }
                            .disabled(model.isWorking)
                        Button("Log out", role: .destructive) { model.logOut() }
                    } else {
                        Button("Connect Spotify") { Task { await model.logIn() } }
                            .disabled(model.isWorking)
                    }
                }

                Section {
                    Toggle("Detect drives automatically", isOn: Binding(
                        get: { model.autoDetectDrives },
                        set: { $0 ? model.startDriveDetection() : model.stopDriveDetection() }))
                    Picker("Car Bluetooth", selection: $model.carBluetoothName) {
                        Text("None").tag("")
                        ForEach(Array(Set(model.bluetoothOutputs + [model.carBluetoothName]).filter { !$0.isEmpty }).sorted(), id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    Button(model.memory.settings.home == nil ? "Set home to where I am" : "Move home to where I am") {
                        model.setHomeToCurrentLocation()
                    }
                } header: {
                    Text("Drives")
                } footer: {
                    Text("Connect to your car's Bluetooth to choose it here. Home is only used on your phone, to notice the last miles home and to keep nearby place names private.")
                }

                Section {
                    VStack(alignment: .leading) {
                        Text("Shuffle comparison: \(Int((model.memory.settings.baselineShare * 100).rounded()))% of moments")
                        Slider(value: Binding(get: { model.memory.settings.baselineShare }, set: { model.setBaselineShare($0) }), in: 0...0.5, step: 0.05)
                    }
                    Toggle("Simulation plays songs in Spotify", isOn: $model.simulationPlaysMusic)
                } header: {
                    Text("Evaluation")
                } footer: {
                    Text("Some moments get a random top track instead of a picked one, so you can check that picking actually helps. You only see which was which after rating.")
                }

                Section("Backend") {
                    if model.config.missing.isEmpty {
                        LabeledContent("URL", value: model.config.backendURL?.host ?? "")
                    } else {
                        Text("Missing in Secrets.xcconfig: \(model.config.missing.joined(separator: ", "))").foregroundStyle(.red)
                    }
                }

                if let error = model.lastError {
                    Section { Text(error).foregroundStyle(.red) }
                }
                if !model.status.isEmpty {
                    Section { Text(model.status).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("People live for a few moments. Moments notices them on your drives — a sunset, rain, leaving a place you loved, the last miles home — and plays the song that fits.")
                }
                if !model.config.missing.isEmpty {
                    Section("Setup needed") {
                        Text("Add \(model.config.missing.joined(separator: ", ")) to ios/Secrets.xcconfig and rebuild. See the README.")
                            .foregroundStyle(.red)
                    }
                }
                Section("1. Connect Spotify") {
                    if model.isLoggedIn {
                        Label("\(model.library.count) songs, \(model.cardCount) cards", systemImage: "checkmark.circle.fill")
                    } else {
                        Button("Connect Spotify (Premium)") { Task { await model.logIn() } }
                            .disabled(model.isWorking || !model.config.missing.isEmpty)
                    }
                    if model.isWorking { ProgressView(model.status) }
                }
                Section("2. Location") {
                    Button("Allow location") { model.requestLocationPermission() }
                    Button(model.memory.settings.home == nil ? "I'm home: set home here" : "Home is set ✓") { model.setHomeToCurrentLocation() }
                }
                Section("3. Tag your moment songs") {
                    NavigationLink("Pick songs for sunsets, rain, leaving and coming home") { SetupView() }
                }
                Section {
                    Button("Done") {
                        model.onboarded = true
                        model.startDriveDetection()
                    }
                }
                if let error = model.lastError {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Moments")
        }
    }
}
