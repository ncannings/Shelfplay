import Foundation

/// Build-time configuration injected from Support/Config.xcconfig (+ gitignored Secrets.xcconfig).
/// Nothing deployer-specific is hardcoded here.
enum AppConfig {
    static let spotifyRedirectURI = "shelfplay://callback"
    static let spotifyCallbackScheme = "shelfplay"
    static let spotifyScopes = [
        "user-read-playback-state", "user-modify-playback-state",
        "user-library-modify", "user-library-read",
        "playlist-modify-private", "playlist-modify-public",
    ].joined(separator: " ")

    static let userAgent = "ShelfPlay-iOS/1.0 (https://github.com/ncannings/Shelfplay)"

    static var bundledSpotifyClientID: String {
        clean(Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String)
    }

    /// Base URL of the ShelfPlay Cloudflare Worker (family sync, Client ID fallback). Nil if not configured.
    static var apiBase: URL? {
        let host = clean(Bundle.main.object(forInfoDictionaryKey: "ShelfPlayAPIHost") as? String)
        guard !host.isEmpty else { return nil }
        return URL(string: host.hasPrefix("http") ? host : "https://\(host)")
    }

    /// iTunes / Apple Music storefront for catalog lookups.
    static var storefront: String {
        (Locale.current.region?.identifier ?? "US").lowercased()
    }

    static var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }

    private static func clean(_ s: String?) -> String {
        let v = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Unresolved build setting, e.g. "$(SPOTIFY_CLIENT_ID)"
        return v.hasPrefix("$(") ? "" : v
    }
}
