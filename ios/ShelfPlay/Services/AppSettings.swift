import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var preferredService: MusicService {
        didSet { defaults.set(preferredService.rawValue, forKey: "preferredService") }
    }
    var spotifyDeviceID: String {
        didSet { defaults.set(spotifyDeviceID, forKey: "spotifyDeviceID") }
    }
    var spotifyDeviceName: String {
        didSet { defaults.set(spotifyDeviceName, forKey: "spotifyDeviceName") }
    }
    var saveToSpotifyLibrary: Bool {
        didSet { defaults.set(saveToSpotifyLibrary, forKey: "saveToSpotifyLibrary") }
    }
    var familyCode: String {
        didSet { defaults.set(familyCode, forKey: "familyCode") }
    }
    var spotifyClientIDOverride: String {
        didSet { defaults.set(spotifyClientIDOverride, forKey: "spotifyClientIDOverride") }
    }

    init() {
        preferredService = MusicService(rawValue: defaults.string(forKey: "preferredService") ?? "") ?? .appleMusic
        spotifyDeviceID = defaults.string(forKey: "spotifyDeviceID") ?? ""
        spotifyDeviceName = defaults.string(forKey: "spotifyDeviceName") ?? ""
        saveToSpotifyLibrary = defaults.bool(forKey: "saveToSpotifyLibrary")
        familyCode = defaults.string(forKey: "familyCode") ?? ""
        spotifyClientIDOverride = defaults.string(forKey: "spotifyClientIDOverride") ?? ""
    }
}
