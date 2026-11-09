import Foundation

/// Unauthenticated catalog lookups: MusicBrainz, Cover Art Archive and the iTunes Search API
/// (whose album IDs are Apple Music catalog IDs).
enum Catalog {
    private static func get(_ url: URL, timeout: TimeInterval = 8) async -> Data? {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue(AppConfig.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                MatchTrace.write("HTTP \(status) from \(url.host() ?? "")\(url.path())")
                return nil
            }
            return data
        } catch {
            MatchTrace.write("Request failed \(url.host() ?? ""): \(error.localizedDescription)")
            return nil
        }
    }

    private static func url(_ base: String, _ q: [String: String]) -> URL {
        var c = URLComponents(string: base)!
        c.queryItems = q.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url!
    }

    // MARK: MusicBrainz
    private struct MBSearch: Decodable {
        struct Credit: Decodable { let name: String }
        struct LabelInfo: Decodable { struct L: Decodable { let name: String? }; let label: L? }
        struct Media: Decodable { let format: String?; let trackCount: Int?
            enum CodingKeys: String, CodingKey { case format; case trackCount = "track-count" } }
        struct Release: Decodable {
            let id: String; let title: String; let date: String?; let country: String?
            let artistCredit: [Credit]?; let labelInfo: [LabelInfo]?; let trackCount: Int?; let media: [Media]?
            enum CodingKeys: String, CodingKey {
                case id, title, date, country, media
                case artistCredit = "artist-credit", labelInfo = "label-info", trackCount = "track-count"
            }
        }
        let releases: [Release]?
    }

    /// Unique (by title+artist) releases for a barcode.
    static func musicBrainzReleases(barcode: String) async -> [MBRelease] {
        guard let data = await get(url("https://musicbrainz.org/ws/2/release/", ["query": "barcode:\(barcode)", "fmt": "json", "limit": "10"])),
              let s = try? JSONDecoder().decode(MBSearch.self, from: data) else { return [] }
        var seen = Set<String>()
        return (s.releases ?? []).compactMap { r in
            let rel = MBRelease(mbid: r.id, title: r.title, artist: r.artistCredit?.first?.name ?? "",
                                year: String((r.date ?? "").prefix(4)), country: r.country ?? "",
                                label: r.labelInfo?.first?.label?.name ?? "",
                                trackCount: r.trackCount ?? (r.media ?? []).reduce(0) { $0 + ($1.trackCount ?? 0) },
                                format: r.media?.first?.format ?? "")
            return seen.insert((rel.title + "|" + rel.artist).lowercased()).inserted ? rel : nil
        }
    }

    static func musicBrainzTracks(mbid: String) async -> [MatchedTrack] {
        struct R: Decodable {
            struct Credit: Decodable { let name: String }
            struct Recording: Decodable { let title: String?; let artistCredit: [Credit]?
                enum CodingKeys: String, CodingKey { case title; case artistCredit = "artist-credit" } }
            struct Track: Decodable { let title: String?; let position: Int?; let recording: Recording? }
            struct Media: Decodable { let position: Int?; let tracks: [Track]? }
            let media: [Media]?
            let artistCredit: [Credit]?
            enum CodingKeys: String, CodingKey { case media; case artistCredit = "artist-credit" }
        }
        guard let data = await get(url("https://musicbrainz.org/ws/2/release/\(mbid)", ["inc": "recordings artist-credits", "fmt": "json"]), timeout: 10),
              let r = try? JSONDecoder().decode(R.self, from: data) else { return [] }
        return (r.media ?? []).flatMap { m in
            (m.tracks ?? []).map { t in
                MatchedTrack(title: t.title ?? t.recording?.title ?? "",
                             artist: t.recording?.artistCredit?.first?.name ?? r.artistCredit?.first?.name ?? "",
                             disc: m.position, position: t.position, found: false)
            }
        }
    }

    static func coverArt(mbid: String) async -> (small: URL, large: URL)? {
        struct R: Decodable {
            struct Img: Decodable { let front: Bool; let thumbnails: [String: String]? }
            let images: [Img]
        }
        guard let data = await get(URL(string: "https://coverartarchive.org/release/\(mbid)/")!, timeout: 5),
              let r = try? JSONDecoder().decode(R.self, from: data),
              let t = r.images.first(where: \.front)?.thumbnails else { return nil }
        let fix = { (s: String?) in URL(string: (s ?? "").replacingOccurrences(of: "http://", with: "https://")) }
        guard let small = fix(t["250"] ?? t["small"]), let large = fix(t["500"] ?? t["large"]) else { return nil }
        return (small, large)
    }

    // MARK: iTunes / Apple Music catalog
    private struct ITunesResponse: Decodable {
        struct Item: Decodable {
            let wrapperType: String?
            let collectionId: Int?
            let collectionName: String?
            let artistName: String?
            let artworkUrl100: String?
            let releaseDate: String?
            let trackCount: Int?
            let collectionViewUrl: String?
            let trackId: Int?
            let trackName: String?
            let trackNumber: Int?
            let discNumber: Int?
            let trackTimeMillis: Int?
        }
        let results: [Item]
    }

    private static func albumResult(_ i: ITunesResponse.Item) -> AlbumResult? {
        guard let id = i.collectionId, let name = i.collectionName else { return nil }
        var r = AlbumResult(name: name.replacingOccurrences(of: " - Single", with: "").replacingOccurrences(of: " - EP", with: ""),
                            artist: i.artistName ?? "", year: String((i.releaseDate ?? "").prefix(4)))
        r.appleMusicID = String(id)
        r.appleMusicURL = i.collectionViewUrl
        if let art = i.artworkUrl100 {
            r.image = URL(string: art.replacingOccurrences(of: "100x100bb", with: "300x300bb"))
            r.imageLarge = URL(string: art.replacingOccurrences(of: "100x100bb", with: "600x600bb"))
        }
        r.totalTracks = i.trackCount
        return r
    }

    static func appleMusicAlbums(term: String, limit: Int = 5) async -> [AlbumResult] {
        guard !term.trimmingCharacters(in: .whitespaces).isEmpty,
              let data = await get(url("https://itunes.apple.com/search", ["term": term, "entity": "album", "limit": "\(limit)", "country": AppConfig.storefront]), timeout: 6),
              let r = try? JSONDecoder().decode(ITunesResponse.self, from: data) else { return [] }
        return r.results.compactMap(albumResult)
    }

    /// Albums found through their songs. The iTunes album search misses many soundtracks and
    /// compilations (e.g. the 1978 Grease soundtrack) that a song search surfaces immediately.
    static func appleMusicAlbumsViaSongs(term: String, maxAlbums: Int = 6) async -> [AlbumResult] {
        guard !term.trimmingCharacters(in: .whitespaces).isEmpty,
              let data = await get(url("https://itunes.apple.com/search", ["term": term, "entity": "song", "limit": "20", "country": AppConfig.storefront]), timeout: 6),
              let r = try? JSONDecoder().decode(ITunesResponse.self, from: data) else { return [] }
        var ids: [Int] = []
        for item in r.results { if let id = item.collectionId, !ids.contains(id) { ids.append(id) } }
        return await appleMusicAlbums(ids: Array(ids.prefix(maxAlbums)))
    }

    static func appleMusicAlbums(ids: [Int]) async -> [AlbumResult] {
        guard !ids.isEmpty,
              let data = await get(url("https://itunes.apple.com/lookup", ["id": ids.map(String.init).joined(separator: ","), "country": AppConfig.storefront]), timeout: 6),
              let r = try? JSONDecoder().decode(ITunesResponse.self, from: data) else { return [] }
        let albums = r.results.filter { $0.wrapperType == "collection" }.compactMap(albumResult)
        return ids.compactMap { id in albums.first { $0.appleMusicID == String(id) } }
    }

    static func appleMusicAlbum(artist: String, title: String) async -> AlbumResult? {
        let results = await appleMusicAlbums(term: "\(artist) \(title)", limit: 5)
        let wantArtist = TextNormalizer.normalize(artist)
        let wantTitle = TextNormalizer.normalize(title)
        return results.first { TextNormalizer.normalize($0.artist) == wantArtist && TextNormalizer.normalize($0.name) == wantTitle }
            ?? results.first { TextNormalizer.normalize($0.artist).contains(wantArtist) || wantArtist.contains(TextNormalizer.normalize($0.artist)) }
            ?? results.first
    }

    static func appleMusicAlbum(upc: String) async -> AlbumResult? {
        guard let data = await get(url("https://itunes.apple.com/lookup", ["upc": upc, "entity": "album", "country": AppConfig.storefront]), timeout: 6),
              let r = try? JSONDecoder().decode(ITunesResponse.self, from: data) else { return nil }
        return r.results.first(where: { $0.wrapperType == "collection" }).flatMap(albumResult)
    }

    static func appleMusicTracks(albumID: String) async -> [TrackRow] {
        guard let data = await get(url("https://itunes.apple.com/lookup", ["id": albumID, "entity": "song", "country": AppConfig.storefront]), timeout: 6),
              let r = try? JSONDecoder().decode(ITunesResponse.self, from: data) else { return [] }
        return r.results.filter { $0.wrapperType == "track" }
            .sorted { (($0.discNumber ?? 1), ($0.trackNumber ?? 0)) < (($1.discNumber ?? 1), ($1.trackNumber ?? 0)) }
            .map { TrackRow(id: String($0.trackId ?? 0), number: $0.trackNumber ?? 0, title: $0.trackName ?? "", durationMs: $0.trackTimeMillis) }
    }
}
