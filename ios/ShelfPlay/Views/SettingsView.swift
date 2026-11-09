import AuthenticationServices
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var joinCode = ""
    @State private var familyMessage: String?
    @State private var connecting = false
    @State private var versionTaps = 0
    @State private var askingCode = false
    @State private var accessCode = ""

    var body: some View {
        @Bindable var settings = model.settings
        NavigationStack {
            Form {
                Section {
                    Picker("Play with", selection: $settings.preferredService) {
                        ForEach(MusicService.allCases) { Text($0.displayName).tag($0) }
                    }
                } header: { Text("Playback") }

                Section {
                    LabeledContent("Status", value: model.appleMusic.statusText)
                    if !model.appleMusic.isAuthorized {
                        Button("Connect Apple Music") { Task { await model.appleMusic.requestAccess() } }
                    }
                } header: { Text("Apple Music") } footer: {
                    Text("With an Apple Music subscription, records play right inside ShelfPlay.")
                }

                Section {
                    if !spotifyAvailable {
                        Text("Albums open in the Spotify app.")
                    } else if model.spotifyAuth.isConnected {
                        LabeledContent("Status", value: "Connected")
                        Picker("Speaker", selection: Binding(
                            get: { model.settings.spotifyDeviceID },
                            set: { id in
                                model.settings.spotifyDeviceID = id
                                model.settings.spotifyDeviceName = model.spotifyDevices.first { $0.id == id }?.name ?? ""
                            })) {
                            Text("None — open the Spotify app").tag("")
                            ForEach(model.spotifyDevices) { Text($0.name).tag($0.id) }
                            if !model.settings.spotifyDeviceID.isEmpty,
                               !model.spotifyDevices.contains(where: { $0.id == model.settings.spotifyDeviceID }) {
                                Text(model.settings.spotifyDeviceName).tag(model.settings.spotifyDeviceID)
                            }
                        }
                        Button("Refresh speakers") { Task { await model.refreshSpotifyDevices() } }
                        Toggle("Save scans to Spotify library", isOn: $settings.saveToSpotifyLibrary)
                        Button("Disconnect Spotify", role: .destructive) { model.spotifyAuth.disconnect() }
                    } else {
                        Button {
                            Task { await connectSpotify() }
                        } label: {
                            HStack { Text("Connect Spotify"); if connecting { Spacer(); ProgressView() } }
                        }
                        .disabled(connecting)
                        TextField("Spotify Client ID (optional override)", text: $settings.spotifyClientIDOverride)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.footnote.monospaced())
                    }
                } header: { Text("Spotify") } footer: {
                    if spotifyAvailable {
                        Text("Connect to play on Spotify speakers (Premium) and build playlists from your disc’s exact tracklist. Your Spotify app needs the redirect URI \(AppConfig.spotifyRedirectURI).")
                    } else {
                        Text("Playing on Spotify speakers and building playlists needs a Spotify connection. Spotify only allows a few invited accounts until an app reaches 250,000 monthly users, so for now it’s invite-only. Apple Music works fully.")
                    }
                }
                .task { if model.spotifyAuth.isConnected { await model.refreshSpotifyDevices() } }

                Section {
                    LabeledContent("Apple Intelligence", value: CoverReader.statusText)
                } header: { Text("Cover recognition") } footer: {
                    Text("Covers are read entirely on your iPhone: Vision reads the sleeve, Apple Intelligence works out the artist and title, and the artwork is compared with catalogue covers. Nothing is sent to an AI service.")
                }

                Section {
                    if FamilySync.isAvailable {
                        if model.settings.familyCode.isEmpty {
                            Button("Create a family shelf") {
                                model.settings.familyCode = FamilySync.generateCode()
                                Task { familyMessage = await model.syncNow() }
                            }
                            HStack {
                                TextField("Family code", text: $joinCode)
                                    .textInputAutocapitalization(.characters)
                                    .autocorrectionDisabled()
                                Button("Join") {
                                    model.settings.familyCode = joinCode.trimmingCharacters(in: .whitespaces).uppercased()
                                    Task { familyMessage = await model.syncNow() }
                                }
                                .disabled(joinCode.trimmingCharacters(in: .whitespaces).count < 3)
                            }
                        } else {
                            LabeledContent("Family code") {
                                Text(model.settings.familyCode).font(.body.monospaced()).textSelection(.enabled)
                            }
                            ShareLink("Share code", item: "Join my ShelfPlay family shelf with code \(model.settings.familyCode)")
                            Button("Sync now") { Task { familyMessage = await model.syncNow() } }
                            Button("Leave family", role: .destructive) { model.settings.familyCode = "" }
                        }
                        if let familyMessage { Text(familyMessage).font(.footnote).foregroundStyle(Theme.textSecondary) }
                    } else {
                        Text("Set SHELFPLAY_API_HOST in Secrets.xcconfig to share a shelf with family.")
                            .font(.footnote).foregroundStyle(Theme.textSecondary)
                    }
                } header: { Text("Family shelf") }

                Section {
                    LabeledContent("Version", value: AppConfig.appVersion)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            versionTaps += 1
                            if versionTaps >= 5 {
                                versionTaps = 0
                                if model.settings.spotifyUnlocked { model.show("Spotify connection already enabled") }
                                else { askingCode = true }
                            }
                        }
                    Link("Source on GitHub", destination: URL(string: "https://github.com/ncannings/Shelfplay")!)
                } header: { Text("About") }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await model.appleMusic.refresh() }
            .alert("Access code", isPresented: $askingCode) {
                SecureField("Code", text: $accessCode)
                Button("Unlock") {
                    let code = accessCode
                    accessCode = ""
                    Task {
                        if await SpotifyAuth.verifyAccessCode(code) {
                            model.settings.spotifyUnlocked = true
                            model.show("Spotify connection enabled")
                        } else {
                            model.show("That code wasn’t accepted")
                        }
                    }
                }
                Button("Cancel", role: .cancel) { accessCode = "" }
            }
        }
    }

    /// Already-connected accounts stay usable; otherwise connecting needs the access code.
    private var spotifyAvailable: Bool { model.settings.spotifyUnlocked || model.spotifyAuth.isConnected }

    private func connectSpotify() async {
        connecting = true
        defer { connecting = false }
        do {
            let url = try await model.spotifyAuth.authorizationURL()
            let callback = try await webAuth.authenticate(using: url, callbackURLScheme: AppConfig.spotifyCallbackScheme,
                                                          preferredBrowserSession: .ephemeral)
            try await model.spotifyAuth.completeLogin(callback: callback)
            await model.refreshSpotifyDevices()
            model.show("Spotify connected")
        } catch {
            if (error as NSError).code != 1 { model.show(error.localizedDescription) } // 1 = user cancelled
        }
    }
}
