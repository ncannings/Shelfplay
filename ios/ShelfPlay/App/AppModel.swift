import Foundation
import Observation
import SwiftData
import UIKit

struct ResultPresentation: Identifiable {
    let id = UUID()
    var album: AlbumResult
    var alternatives: [AlbumResult] = []
    var note: String?
}

enum ActiveSheet: Identifiable {
    case result(ResultPresentation)
    case editions(barcode: String, releases: [MBRelease])
    case search
    case library
    case settings

    var id: String {
        switch self {
        case .result(let r): "result-\(r.id)"
        case .editions(let b, _): "editions-\(b)"
        case .search: "search"
        case .library: "library"
        case .settings: "settings"
        }
    }
}

enum ScanMode: String, CaseIterable, Identifiable {
    case barcode = "Barcode", cover = "Cover"
    var id: String { rawValue }
}

@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    let spotifyAuth: SpotifyAuth
    let spotify: SpotifyAPI
    let appleMusic: AppleMusicService
    let matcher: CoverMatcher
    let container: ModelContainer

    var mode: ScanMode = .barcode
    var sheet: ActiveSheet?
    var busyMessage: String?
    var toast: String?
    var status = "Point at a barcode"
    var spotifyDevices: [SpotifyDevice] = []

    private var lastBarcode: (code: String, at: Date)?
    private var toastTask: Task<Void, Never>?

    var isBusy: Bool { busyMessage != nil }
    var scannerPaused: Bool { isBusy || sheet != nil }

    init(container: ModelContainer) {
        self.container = container
        settings = AppSettings()
        spotifyAuth = SpotifyAuth(settings: settings)
        spotify = SpotifyAPI(auth: spotifyAuth)
        appleMusic = AppleMusicService()
        matcher = CoverMatcher(spotify: spotify, appleMusic: appleMusic)
        spotify.onRateLimited = { [weak self] in self?.show($0) }
        Task { await appleMusic.refresh() }
    }

    private var context: ModelContext { container.mainContext }

    func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: - Barcode

    func handleBarcode(_ raw: String) async {
        // EAN-13 with a leading zero is a UPC-A; MusicBrainz indexes the 12-digit form.
        let code = raw.count == 13 && raw.hasPrefix("0") ? String(raw.dropFirst()) : raw
        if let last = lastBarcode, last.code == code, Date.now.timeIntervalSince(last.at) < 10 { return }
        lastBarcode = (code, .now)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        if let known = shelf().first(where: { $0.barcode == code && $0.matchedTracks != nil }) {
            present(known)
            return
        }

        busyMessage = "Looking up \(code)…"
        defer { busyMessage = nil }
        async let mbTask = Catalog.musicBrainzReleases(barcode: code)
        async let amTask = Catalog.appleMusicAlbum(upc: code)
        async let spTask = spotify.albumByUPC(code)
        let (releases, appleMusic, spotifyHit) = await (mbTask, amTask, spTask)

        // Exact UPC hit in a streaming catalogue.
        if var album = spotifyHit ?? appleMusic {
            if let appleMusic { album.merge(appleMusic) }
            album.barcode = code
            if let rel = releases.first {
                album.mbid = rel.mbid
                album.mbTrackCount = rel.trackCount
                album.mbTitle = rel.title
                if TextNormalizer.normalize(rel.title) != TextNormalizer.normalize(album.name), let art = await Catalog.coverArt(mbid: rel.mbid) {
                    album.image = art.small
                    album.imageLarge = art.large
                }
            }
            if album.spotifyURI == nil, spotify.isConnected, let s = await spotify.findAlbum(matching: album) {
                album.spotifyURI = s.spotifyURI
            }
            present(album)
            return
        }

        if releases.count > 1 {
            sheet = .editions(barcode: code, releases: releases)
            status = "Pick the correct edition"
            return
        }
        if let rel = releases.first {
            busyMessage = "\(rel.artist) — \(rel.title)"
            await presentRelease(rel, barcode: code)
            return
        }
        status = "No match for \(code) — try Cover mode"
        show("\(code) wasn’t found in any catalogue")
    }

    func pickRelease(_ rel: MBRelease, barcode: String) async {
        sheet = nil
        busyMessage = "Searching \(rel.artist) — \(rel.title)…"
        defer { busyMessage = nil }
        await presentRelease(rel, barcode: barcode)
    }

    private func presentRelease(_ rel: MBRelease, barcode: String) async {
        async let found = lookup(artist: rel.artist, title: rel.title)
        async let art = Catalog.coverArt(mbid: rel.mbid)
        var album = await found ?? AlbumResult(name: rel.title, artist: rel.artist, year: rel.year)
        if let art = await art {
            album.image = art.small
            album.imageLarge = art.large
        }
        album.barcode = barcode
        album.mbid = rel.mbid
        album.mbTitle = rel.title
        album.mbTrackCount = rel.trackCount
        if album.year.isEmpty { album.year = rel.year }
        present(album)
    }

    /// Album search across Apple Music (always) and Spotify (when connected).
    func lookup(artist: String, title: String) async -> AlbumResult? {
        async let am = Catalog.appleMusicAlbum(artist: artist, title: title)
        async let sp = spotify.findAlbum(matching: AlbumResult(name: title, artist: artist))
        let (a, s) = await (am, sp)
        guard var result = s ?? a else { return nil }
        if let a, s != nil { result.merge(a) }
        return result
    }

    // MARK: - Cover & search

    func identifyCover(_ image: UIImage) async {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        busyMessage = "Reading the cover…"
        defer { busyMessage = nil }
        do {
            let outcome = try await matcher.identify(image, shelf: shelf()) { [weak self] in self?.busyMessage = $0 }
            present(outcome.best, alternatives: outcome.alternatives, note: outcome.note)
        } catch {
            status = "Not identified"
            show(error.localizedDescription)
        }
    }

    func searchCandidates(_ text: String) async -> [AlbumResult] {
        if text.allSatisfy(\.isNumber), (8...14).contains(text.count) {
            sheet = nil
            await handleBarcode(text)
            return []
        }
        async let am = Catalog.appleMusicAlbums(term: text, limit: 10)
        async let sp = spotify.searchAlbums(query: text, limit: 5)
        let (a, s) = await (am, sp)
        var merged: [String: AlbumResult] = [:]
        var order: [String] = []
        for album in s + a {
            let key = TextNormalizer.albumKey(artist: album.artist, title: album.name)
            if var existing = merged[key] { existing.merge(album); merged[key] = existing }
            else { merged[key] = album; order.append(key) }
        }
        return order.compactMap { merged[$0] }
    }

    func choose(_ album: AlbumResult, alternatives: [AlbumResult] = [], note: String? = nil) {
        present(album, alternatives: alternatives, note: note)
    }

    // MARK: - Results & library

    private func present(_ album: AlbumResult, alternatives: [AlbumResult] = [], note: String? = nil) {
        var album = album
        album.scannedAt = .now
        let saved = save(album)
        sheet = .result(ResultPresentation(album: saved, alternatives: alternatives, note: note))
        status = "\(saved.artist) — \(saved.name)"
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if settings.saveToSpotifyLibrary, let uri = saved.spotifyURI {
            Task { await spotify.saveAlbumToLibrary(uri: uri) }
        }
        syncInBackground()
    }

    func shelf() -> [AlbumResult] {
        ((try? context.fetch(FetchDescriptor<ShelfAlbum>())) ?? []).map(\.result)
    }

    /// Upsert into the shelf, merging with any existing entry for the same record.
    @discardableResult
    func save(_ album: AlbumResult) -> AlbumResult {
        let all = (try? context.fetch(FetchDescriptor<ShelfAlbum>())) ?? []
        var merged = album
        if let existing = all.first(where: { $0.matches(album) }) {
            merged.merge(existing.result)
            merged.playlistID = album.playlistID ?? existing.result.playlistID
            merged.playlistURI = album.playlistURI ?? existing.result.playlistURI
            merged.playlistURL = album.playlistURL ?? existing.result.playlistURL
            for other in all where other !== existing && other.key == merged.libraryKey { context.delete(other) }
            existing.update(from: merged)
        } else {
            if let clash = all.first(where: { $0.key == merged.libraryKey }) { context.delete(clash) }
            context.insert(ShelfAlbum(merged))
        }
        try? context.save()
        return merged
    }

    /// Swap the presented result for an alternative candidate (removes the wrong one from the shelf).
    func replace(_ wrong: AlbumResult, with right: AlbumResult, in presentation: ResultPresentation) {
        delete(wrong)
        var right = right
        right.coverPrintConfirmed = right.coverPrint != nil
        var alts = presentation.alternatives.filter { $0.libraryKey != right.libraryKey }
        alts.insert(wrong, at: 0)
        present(right, alternatives: alts, note: presentation.note)
    }

    func delete(_ album: AlbumResult) {
        let all = (try? context.fetch(FetchDescriptor<ShelfAlbum>())) ?? []
        for item in all where item.key == album.libraryKey { context.delete(item) }
        try? context.save()
    }

    // MARK: - Playback

    func play(_ album: AlbumResult, on service: MusicService? = nil) async -> Bool {
        let service = service ?? settings.preferredService
        if album.coverPrint != nil, !album.coverPrintConfirmed {
            var confirmed = album
            confirmed.coverPrintConfirmed = true
            save(confirmed)
        }
        do {
            switch service {
            case .appleMusic:
                try await appleMusic.play(album)
                status = "Playing \(album.name)"
            case .spotify:
                guard spotify.isConnected, !settings.spotifyDeviceID.isEmpty else {
                    await openInSpotify(album)
                    return true
                }
                var body: [String: Any]
                if let uris = album.trackURIs, !uris.isEmpty { body = ["uris": uris] }
                else if let p = album.playlistURI { body = ["context_uri": p] }
                else if let uri = album.spotifyURI { body = ["context_uri": uri] }
                else { await openInSpotify(album); return true }
                try await spotify.play(deviceID: settings.spotifyDeviceID, deviceName: settings.spotifyDeviceName, body: body).get()
                status = "Playing on \(settings.spotifyDeviceName.isEmpty ? "Spotify" : settings.spotifyDeviceName)"
            }
            return true
        } catch {
            show(error.localizedDescription)
            return false
        }
    }

    func openInSpotify(_ album: AlbumResult) async {
        var album = album
        if album.spotifyURI == nil, album.playlistURI == nil, spotify.isConnected,
           let s = await spotify.findAlbum(matching: album) {
            album.spotifyURI = s.spotifyURI
            save(album)
        }
        var urls: [URL] = []
        if let id = album.playlistURI ?? album.spotifyURI {
            urls.append(URL(string: id)!)
            if let p = album.playlistURL, let u = URL(string: p) { urls.append(u) }
            let parts = id.split(separator: ":")
            if parts.count == 3 { urls.append(URL(string: "https://open.spotify.com/\(parts[1])/\(parts[2])")!) }
        } else {
            // Not resolvable without a Spotify login: search by title, adding the artist only when it's a
            // single credited name (long soundtrack credits drown the title in Spotify's ranking).
            let segments = TextNormalizer.artistSegments(album.artist)
            let title = album.name.replacingOccurrences(of: #"[\(\)\[\]]"#, with: " ", options: .regularExpression)
            let query = (segments.count == 1 && !TextNormalizer.isVariousArtists(album.artist) ? "\(album.artist) \(title)" : title)
                .split(separator: " ").joined(separator: " ")
            let q = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
            urls.append(URL(string: "https://open.spotify.com/search/\(q)")!)
        }
        let target = urls.first { $0.scheme != "spotify" || UIApplication.shared.canOpenURL($0) } ?? urls.last!
        await UIApplication.shared.open(target)
    }

    func refreshSpotifyDevices() async {
        spotifyDevices = await spotify.devices()
        if settings.spotifyDeviceID.isEmpty, let first = spotifyDevices.first {
            settings.spotifyDeviceID = first.id
            settings.spotifyDeviceName = first.name
        }
    }

    // MARK: - Track-level playlist (compilations / regional editions)

    /// Matches the physical release's tracklist (MusicBrainz) on the streaming services,
    /// creates a Spotify playlist when connected, and plays it.
    func buildPlaylist(for album: AlbumResult, progress: (String) -> Void) async -> AlbumResult? {
        guard let mbid = album.mbid else { show("No MusicBrainz data for this album"); return nil }
        var updated = album
        var tracks = album.matchedTracks ?? []
        if tracks.isEmpty {
            progress("Fetching track listing…")
            tracks = await Catalog.musicBrainzTracks(mbid: mbid)
            guard !tracks.isEmpty else { show("Couldn’t fetch the track listing"); return nil }
        }
        if spotify.isConnected, tracks.contains(where: { $0.spotifyURI == nil }) {
            for i in tracks.indices where tracks[i].spotifyURI == nil {
                progress("Matching on Spotify (\(i + 1)/\(tracks.count))…")
                if let hit = await spotify.searchTrack(title: tracks[i].title, artist: tracks[i].artist) {
                    tracks[i].spotifyURI = hit.uri
                    tracks[i].spotifyName = hit.name
                    tracks[i].found = true
                }
            }
        }
        if appleMusic.isAuthorized {
            progress("Matching on Apple Music…")
            tracks = await appleMusic.matchSongs(tracks)
        }
        let found = tracks.filter(\.found).count
        guard found > 0 else { show("None of the tracks were found"); return nil }

        updated.matchedTracks = tracks
        updated.trackURIs = tracks.compactMap(\.spotifyURI)
        if let mbTitle = album.mbTitle, TextNormalizer.normalize(mbTitle) != TextNormalizer.normalize(album.name) { updated.name = mbTitle }
        if spotify.isConnected, updated.playlistURI == nil, !(updated.trackURIs ?? []).isEmpty {
            progress("Creating Spotify playlist…")
            let name = updated.artist.isEmpty ? updated.name : "\(updated.name) — \(updated.artist)"
            if let p = try? await spotify.createPlaylist(name: name, trackURIs: updated.trackURIs ?? []) {
                updated.playlistID = p.id
                updated.playlistURI = p.uri
                updated.playlistURL = p.url
            }
        }
        updated = save(updated)
        if found < tracks.count { show("\(tracks.count - found) of \(tracks.count) tracks aren’t streaming") }
        progress("Starting playback…")
        _ = await play(updated)
        return updated
    }

    // MARK: - Family sync

    func syncInBackground() {
        guard !settings.familyCode.isEmpty, FamilySync.isAvailable else { return }
        let code = settings.familyCode
        let lib = shelf()
        Task { _ = try? await FamilySync.save(code: code, library: lib) }
    }

    /// Pull family albums, merge, then push the union.
    func syncNow() async -> String {
        guard !settings.familyCode.isEmpty else { return "Join or create a family first" }
        do {
            let remote = try await FamilySync.load(code: settings.familyCode)
            let local = shelf()
            var added = 0
            for album in remote {
                if let existing = local.first(where: { $0.isSameRecord(as: album) }) {
                    var merged = existing
                    merged.merge(album)
                    // Playlists belong to each member's own Spotify account.
                    merged.playlistURI = existing.playlistURI
                    save(merged)
                } else {
                    var a = album
                    a.playlistID = nil; a.playlistURI = nil; a.playlistURL = nil
                    save(a)
                    added += 1
                }
            }
            let total = try await FamilySync.save(code: settings.familyCode, library: shelf())
            return "Synced — \(added) new, \(total) on the family shelf"
        } catch {
            return error.localizedDescription
        }
    }
}
