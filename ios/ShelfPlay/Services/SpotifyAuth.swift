import CryptoKit
import Foundation
import Observation

/// Spotify Authorization Code + PKCE as a public (secret-less) native client.
/// Tokens live in the Keychain. No server round-trip is needed.
@MainActor
@Observable
final class SpotifyAuth {
    private struct Tokens: Codable {
        var access: String
        var refresh: String?
        var expiry: Date
        var scope: String?
    }

    private(set) var isConnected = false
    private var tokens: Tokens? {
        didSet {
            isConnected = tokens != nil
            Keychain.set(tokens.flatMap { try? JSONEncoder().encode($0) }, for: "spotify.tokens")
        }
    }
    private var pendingVerifier: String?
    private var resolvedClientID: String?
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
        if let d = Keychain.get("spotify.tokens"), let t = try? JSONDecoder().decode(Tokens.self, from: d) {
            tokens = t
            isConnected = true
        }
    }

    enum AuthError: LocalizedError {
        case noClientID, stateLost, denied(String), exchange(String), notInvited
        var errorDescription: String? {
            switch self {
            case .noClientID: "No Spotify Client ID configured. Add one in Settings or Secrets.xcconfig."
            case .stateLost: "Login state lost — try again."
            case .denied(let r): "Spotify login denied: \(r)"
            case .exchange(let m): "Spotify login failed: \(m)"
            case .notInvited: "This Spotify account isn’t enabled for ShelfPlay. Spotify limits speaker control to a few invited accounts until an app reaches 250,000 monthly users. Opening albums in Spotify still works."
            }
        }
    }

    func clientID() async -> String? {
        let override = settings.spotifyClientIDOverride.trimmingCharacters(in: .whitespaces)
        if !override.isEmpty { return override }
        if !AppConfig.bundledSpotifyClientID.isEmpty { return AppConfig.bundledSpotifyClientID }
        if let resolvedClientID { return resolvedClientID }
        // Fallback: the worker serves its configured Client ID publicly.
        guard let base = AppConfig.apiBase else { return nil }
        struct Cfg: Decodable { let spotify_client_id: String }
        if let (data, _) = try? await URLSession.shared.data(from: base.appending(path: "api/config")),
           let cfg = try? JSONDecoder().decode(Cfg.self, from: data), !cfg.spotify_client_id.isEmpty {
            resolvedClientID = cfg.spotify_client_id
            return cfg.spotify_client_id
        }
        return nil
    }

    func authorizationURL() async throws -> URL {
        guard let clientID = await clientID() else { throw AuthError.noClientID }
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64URL
        pendingVerifier = verifier
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: AppConfig.spotifyRedirectURI),
            .init(name: "scope", value: AppConfig.spotifyScopes),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "show_dialog", value: "true"),
        ]
        return c.url!
    }

    func completeLogin(callback: URL) async throws {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let err = items.first(where: { $0.name == "error" })?.value { throw AuthError.denied(err) }
        guard let code = items.first(where: { $0.name == "code" })?.value,
              let verifier = pendingVerifier, let clientID = await clientID() else { throw AuthError.stateLost }
        pendingVerifier = nil
        let newTokens = try await tokenRequest([
            "client_id": clientID, "grant_type": "authorization_code", "code": code,
            "redirect_uri": AppConfig.spotifyRedirectURI, "code_verifier": verifier,
        ], previousRefresh: nil)
        // In development mode Spotify answers 403 for accounts not on the app's user list.
        var me = URLRequest(url: URL(string: "https://api.spotify.com/v1/me")!)
        me.setValue("Bearer \(newTokens.access)", forHTTPHeaderField: "Authorization")
        if let (_, resp) = try? await URLSession.shared.data(for: me), (resp as? HTTPURLResponse)?.statusCode == 403 {
            throw AuthError.notInvited
        }
        tokens = newTokens
    }

    /// Checks an operator access code with the worker (same check the web app uses).
    static func verifyAccessCode(_ code: String) async -> Bool {
        guard let base = AppConfig.apiBase, !code.isEmpty else { return false }
        var req = URLRequest(url: base.appending(path: "api/vision"), timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(code, forHTTPHeaderField: "X-Admin-Code")
        req.httpBody = Data(#"{"image_base64":""}"#.utf8)
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let status = (resp as? HTTPURLResponse)?.statusCode else { return false }
        return status != 403 && status != 404
    }

    /// A valid access token, refreshing if it expires within two minutes. Nil when not connected.
    func validToken() async -> String? {
        guard let t = tokens else { return nil }
        if t.expiry.timeIntervalSinceNow > 120 { return t.access }
        guard let refresh = t.refresh, let clientID = await clientID() else { return t.access }
        do {
            tokens = try await tokenRequest(["client_id": clientID, "grant_type": "refresh_token", "refresh_token": refresh],
                                            previousRefresh: refresh)
            return tokens?.access
        } catch {
            return nil
        }
    }

    func disconnect() { tokens = nil }

    private func tokenRequest(_ form: [String: String], previousRefresh: String?) async throws -> Tokens {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents()
        c.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        struct Resp: Decodable {
            let access_token: String?
            let refresh_token: String?
            let expires_in: Double?
            let scope: String?
            let error: String?
            let error_description: String?
        }
        let r = try JSONDecoder().decode(Resp.self, from: data)
        guard let access = r.access_token else {
            throw AuthError.exchange(r.error_description ?? r.error ?? "unknown error")
        }
        return Tokens(access: access, refresh: r.refresh_token ?? previousRefresh,
                      expiry: .now.addingTimeInterval(r.expires_in ?? 3600), scope: r.scope)
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
