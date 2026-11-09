import Foundation

struct SpotifyDevice: Identifiable, Hashable, Decodable {
    let id: String
    let name: String
    let type: String
    let is_active: Bool
}

struct TrackRow: Identifiable, Hashable {
    let id: String
    let number: Int
    let title: String
    let durationMs: Int?
    var duration: String {
        guard let ms = durationMs else { return "" }
        return String(format: "%d:%02d", ms / 60000, (ms % 60000) / 1000)
    }
}

/// Spotify Web API client with self-throttling and 429 backoff (ported from the PWA).
@MainActor
final class SpotifyAPI {
    private let auth: SpotifyAuth
    private var backoffUntil = Date.distantPast
    private var lastCall = Date.distantPast
    private let minInterval: TimeInterval = 0.2
    var onRateLimited: ((String) -> Void)?

    init(auth: SpotifyAuth) { self.auth = auth }

    var isConnected: Bool { auth.isConnected }

    // MARK: DTOs
    private struct AlbumDTO: Decodable {
        struct Img: Decodable { let url: String }
        struct Artist: Decodable { let name: String }
        let name: String
        let uri: String
        let release_date: String?
        let total_tracks: Int?
        let images: [Img]
        let artists: [Artist]
    }
    private struct AlbumSearch: Decodable {
        struct Page: Decodable { let items: [AlbumDTO?] }
        let albums: Page?
    }

    private func result(_ a: AlbumDTO) -> AlbumResult {
        var r = AlbumResult(name: a.name, artist: a.artists.first?.name ?? "", year: String((a.release_date ?? "").prefix(4)))
        r.spotifyURI = a.uri
        r.image = URL(string: (a.images.count > 1 ? a.images[1] : a.images.first)?.url ?? "")
        r.imageLarge = URL(string: a.images.first?.url ?? "")
        r.totalTracks = a.total_tracks
        return r
    }

    // MARK: Core request
    private func send(_ path: String, method: String = "GET", query: [String: String] = [:], json: Any? = nil,
                      throttle: Bool = true) async -> (Data, Int)? {
        guard let token = await auth.validToken() else { return nil }
        if backoffUntil > .now { return nil }
        if throttle {
            let wait = minInterval - Date.now.timeIntervalSince(lastCall)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            lastCall = .now
        }
        var c = URLComponents(string: path.hasPrefix("http") ? path : "https://api.spotify.com/v1/\(path)")!
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: c.url!, timeoutInterval: 10)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse else { return nil }
        if http.statusCode == 429 {
            let retry = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60
            backoffUntil = .now.addingTimeInterval(retry)
            onRateLimited?("Spotify rate limit — pausing for \(Int(ceil(retry / 60))) min")
            return nil
        }
        return (data, http.statusCode)
    }

    // MARK: Search
    func searchAlbums(query: String, limit: Int = 3) async -> [AlbumResult] {
        guard let (data, status) = await send("search", query: ["q": query, "type": "album", "limit": "\(limit)"]),
              status == 200, let s = try? JSONDecoder().decode(AlbumSearch.self, from: data) else { return [] }
        return (s.albums?.items ?? []).compactMap { $0 }.map(result)
    }

    func searchAlbum(artist: String, title: String) async -> AlbumResult? {
        for q in ["album:\(title) artist:\(artist)", "\(artist) \(title)"] {
            if let first = await searchAlbums(query: q, limit: 3).first { return first }
        }
        return nil
    }

    func albumByUPC(_ upc: String) async -> AlbumResult? {
        await searchAlbums(query: "upc:\(upc)", limit: 1).first
    }

    func searchTrack(title: String, artist: String) async -> (uri: String, name: String)? {
        struct S: Decodable {
            struct P: Decodable { let items: [T?] }
            struct T: Decodable { let uri: String; let name: String }
            let tracks: P?
        }
        guard let (data, status) = await send("search", query: ["q": "track:\(title) artist:\(artist)", "type": "track", "limit": "1"]),
              status == 200, let s = try? JSONDecoder().decode(S.self, from: data),
              let t = s.tracks?.items.compactMap({ $0 }).first else { return nil }
        return (t.uri, t.name)
    }

    func albumTracks(uri: String) async -> [TrackRow] {
        struct S: Decodable {
            struct T: Decodable { let id: String?; let name: String; let track_number: Int; let duration_ms: Int? }
            let items: [T]
        }
        let id = uri.replacingOccurrences(of: "spotify:album:", with: "")
        guard let (data, status) = await send("albums/\(id)/tracks", query: ["limit": "50"]), status == 200,
              let s = try? JSONDecoder().decode(S.self, from: data) else { return [] }
        return s.items.map { TrackRow(id: $0.id ?? UUID().uuidString, number: $0.track_number, title: $0.name, durationMs: $0.duration_ms) }
    }

    // MARK: Devices & playback
    func devices() async -> [SpotifyDevice] {
        struct S: Decodable { let devices: [SpotifyDevice] }
        guard let (data, _) = await send("me/player/devices", throttle: false),
              let s = try? JSONDecoder().decode(S.self, from: data) else { return [] }
        return s.devices
    }

    /// Wake the device, then start playback with retries (ported from the PWA's spotifyPlay).
    func play(deviceID: String, deviceName: String, body: [String: Any]) async -> Result<Void, PlaybackError> {
        // Device IDs change; prefer a name match.
        let list = await devices()
        let resolved = list.first(where: { !deviceName.isEmpty && $0.name == deviceName })?.id
            ?? list.first(where: { $0.id == deviceID })?.id ?? deviceID
        _ = await send("me/player", method: "PUT", json: ["device_ids": [resolved], "play": true], throttle: false)
        try? await Task.sleep(for: .seconds(1.5))
        var last: (Data, Int)?
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            last = await send("me/player/play", method: "PUT", query: ["device_id": resolved], json: body, throttle: false)
            guard let (_, status) = last else { break }
            if (200..<300).contains(status) { return .success(()) }
            if status != 404 && status != 502 { break }
        }
        guard let (data, status) = last else { return .failure(.message("Couldn’t reach Spotify")) }
        let reason = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
            .flatMap { $0["error"] as? [String: Any] }.flatMap { ($0["reason"] ?? $0["message"]) as? String } ?? ""
        if status == 404 || reason == "NO_ACTIVE_DEVICE" {
            return .failure(.message("\(deviceName.isEmpty ? "Device" : deviceName) isn’t responding. Wake it (e.g. “Alexa, play Spotify”) and try again."))
        }
        if reason == "PREMIUM_REQUIRED" { return .failure(.message("Spotify Premium is required to control speakers.")) }
        return .failure(.message(reason.isEmpty ? "Spotify error \(status)" : "\(reason) (\(status))"))
    }

    // MARK: Library & playlists
    func saveAlbumToLibrary(uri: String) async {
        _ = await send("me/library", method: "PUT", query: ["uris": uri], json: [String: String]())
    }

    func createPlaylist(name: String, trackURIs: [String]) async throws -> (id: String, uri: String, url: String) {
        struct P: Decodable {
            struct Ext: Decodable { let spotify: String? }
            let id: String; let uri: String; let name: String; let external_urls: Ext?
        }
        struct L: Decodable { let items: [P?] }
        if let (data, status) = await send("me/playlists", query: ["limit": "50"]), status == 200,
           let l = try? JSONDecoder().decode(L.self, from: data),
           let existing = l.items.compactMap({ $0 }).first(where: { $0.name == name }) {
            return (existing.id, existing.uri, existing.external_urls?.spotify ?? "")
        }
        guard let (data, status) = await send("me/playlists", method: "POST",
                                               json: ["name": name, "description": "Built by ShelfPlay", "public": false]),
              (200..<300).contains(status), let p = try? JSONDecoder().decode(P.self, from: data) else {
            throw PlaybackError.message("Couldn’t create the Spotify playlist — try reconnecting Spotify.")
        }
        for start in stride(from: 0, to: trackURIs.count, by: 100) {
            let batch = Array(trackURIs[start..<min(start + 100, trackURIs.count)])
            _ = await send("playlists/\(p.id)/items", method: "POST", json: ["uris": batch])
        }
        return (p.id, p.uri, p.external_urls?.spotify ?? "")
    }
}

enum PlaybackError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}
