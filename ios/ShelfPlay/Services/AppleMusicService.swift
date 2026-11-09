import Foundation
import MusicKit
import Observation
import UIKit

/// Apple Music playback through MusicKit. Plays directly inside ShelfPlay (ApplicationMusicPlayer),
/// falling back to opening the Music app when the user has no subscription.
@MainActor
@Observable
final class AppleMusicService {
    private(set) var authorization: MusicAuthorization.Status = MusicAuthorization.currentStatus
    private(set) var canPlayCatalog = false

    var isAuthorized: Bool { authorization == .authorized }

    var statusText: String {
        switch authorization {
        case .authorized: canPlayCatalog ? "Connected — plays inside ShelfPlay" : "Connected — no subscription, opens the Music app"
        case .denied: "Access denied — enable in iOS Settings › ShelfPlay"
        case .restricted: "Restricted on this device"
        default: "Not connected"
        }
    }

    func refresh() async {
        authorization = MusicAuthorization.currentStatus
        guard isAuthorized else { return }
        canPlayCatalog = (try? await MusicSubscription.current)?.canPlayCatalogContent ?? false
    }

    func requestAccess() async {
        authorization = await MusicAuthorization.request()
        await refresh()
    }

    /// Song IDs for the physical release's tracklist (used for compilations that differ from the streaming album).
    func matchSongs(_ tracks: [MatchedTrack]) async -> [MatchedTrack] {
        guard isAuthorized else { return tracks }
        var out = tracks
        for i in out.indices where out[i].appleMusicID == nil {
            var req = MusicCatalogSearchRequest(term: "\(out[i].title) \(out[i].artist)", types: [Song.self])
            req.limit = 3
            guard let songs = try? await req.response().songs else { continue }
            let want = TextNormalizer.normalize(out[i].title)
            let song = songs.first { TextNormalizer.normalize($0.title) == want } ?? songs.first
            if let song {
                out[i].appleMusicID = song.id.rawValue
                out[i].found = true
            }
        }
        return out
    }

    /// Apple Music API catalog search — far better ranking than the public iTunes search.
    /// Requires MusicKit to be enabled for the App ID; returns [] otherwise.
    func searchAlbums(term: String, limit: Int = 8) async -> [AlbumResult] {
        guard isAuthorized else { return [] }
        var req = MusicCatalogSearchRequest(term: term, types: [Album.self])
        req.limit = limit
        guard let albums = try? await req.response().albums else { return [] }
        return albums.map { a in
            var r = AlbumResult(name: a.title, artist: a.artistName,
                                year: a.releaseDate.map { String(Calendar.current.component(.year, from: $0)) } ?? "")
            r.appleMusicID = a.id.rawValue
            r.appleMusicURL = a.url?.absoluteString
            r.image = a.artwork?.url(width: 300, height: 300)
            r.imageLarge = a.artwork?.url(width: 600, height: 600)
            r.totalTracks = a.trackCount
            return r
        }
    }

    func play(_ album: AlbumResult) async throws {
        if !isAuthorized { await requestAccess() }
        guard isAuthorized, canPlayCatalog else {
            if openInMusicApp(album) { return }
            throw PlaybackError.message("Allow Apple Music access in Settings to play here.")
        }
        let player = ApplicationMusicPlayer.shared
        let songIDs = (album.matchedTracks ?? []).compactMap(\.appleMusicID)
        if !songIDs.isEmpty {
            let resp = try await MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: songIDs.map { MusicItemID($0) }).response()
            var byID: [String: Song] = [:]
            for s in resp.items { byID[s.id.rawValue] = s }
            let ordered = songIDs.compactMap { byID[$0] }
            guard !ordered.isEmpty else { throw PlaybackError.message("Those tracks aren’t available on Apple Music.") }
            player.queue = ApplicationMusicPlayer.Queue(for: ordered)
        } else if let id = album.appleMusicID {
            let resp = try await MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: MusicItemID(id)).response()
            guard let item = resp.items.first else { throw PlaybackError.message("Album not available in your Apple Music storefront.") }
            player.queue = [item]
        } else {
            throw PlaybackError.message("Not found on Apple Music.")
        }
        try await player.play()
    }

    @discardableResult
    func openInMusicApp(_ album: AlbumResult) -> Bool {
        let url: URL?
        if let s = album.appleMusicURL { url = URL(string: s) }
        else if let id = album.appleMusicID { url = URL(string: "https://music.apple.com/\(AppConfig.storefront)/album/\(id)") }
        else {
            let q = "\(album.artist) \(album.name)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            url = URL(string: "https://music.apple.com/\(AppConfig.storefront)/search?term=\(q)")
        }
        guard let url else { return false }
        UIApplication.shared.open(url)
        return true
    }
}
