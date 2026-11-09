import Foundation

enum ScanSource: String, Codable, Hashable {
    case barcode, cover, search
}

enum MusicService: String, Codable, CaseIterable, Identifiable {
    case appleMusic, spotify
    var id: String { rawValue }
    var displayName: String { self == .appleMusic ? "Apple Music" : "Spotify" }
}

/// One track from the physical release (MusicBrainz), matched against streaming catalogs.
struct MatchedTrack: Codable, Hashable {
    var title: String
    var artist: String
    var disc: Int?
    var position: Int?
    var spotifyURI: String?
    var spotifyName: String?
    var appleMusicID: String?
    var found: Bool

    enum CodingKeys: String, CodingKey {
        case title, artist, disc, position, found, spotifyName
        case spotifyURI = "spotifyUri"
        case appleMusicID = "appleMusicId"
    }
}

/// An identified album. Field names in the JSON encoding match the web app's library
/// format so family libraries can be shared between the PWA and the iOS app.
struct AlbumResult: Codable, Hashable, Identifiable {
    var name: String
    var artist: String
    var year: String = ""
    var spotifyURI: String?
    var appleMusicID: String?
    var appleMusicURL: String?
    var image: URL?
    var imageLarge: URL?
    var totalTracks: Int?
    var barcode: String?
    var mbid: String?
    var mbTitle: String?
    var mbTrackCount: Int?
    var matchedTracks: [MatchedTrack]?
    var trackURIs: [String]?
    var playlistID: String?
    var playlistURI: String?
    var playlistURL: String?
    var source: ScanSource = .barcode
    var scannedAt: Date = .now
    /// Archived Vision feature print of the photographed cover, for instant re-recognition.
    var coverPrint: Data?

    var id: String { libraryKey }

    var libraryKey: String {
        if let spotifyURI { return spotifyURI }
        if let appleMusicID { return "applemusic:album:\(appleMusicID)" }
        return "local:\(artist):\(name)".lowercased()
    }

    var hasSpotify: Bool { spotifyURI != nil || !(trackURIs ?? []).isEmpty || playlistURI != nil }
    var hasAppleMusic: Bool { appleMusicID != nil }

    /// Physical release differs from the streaming match (compilations, regional editions).
    var mismatchDescription: String? {
        var parts: [String] = []
        if let mbTitle, TextNormalizer.normalize(mbTitle) != TextNormalizer.normalize(name) {
            parts.append("Your disc: “\(mbTitle)” — streaming match: “\(name)”")
        }
        if let mb = mbTrackCount, let total = totalTracks, mb > 0, total > 0, abs(mb - total) > 1 {
            parts.append("Track count: \(mb) on your disc vs \(total) streaming")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ". ")
    }

    func isSameRecord(as r: AlbumResult) -> Bool {
        if libraryKey == r.libraryKey { return true }
        if let b = barcode, b == r.barcode { return true }
        if let id = appleMusicID, id == r.appleMusicID { return true }
        return TextNormalizer.albumKey(artist: artist, title: name) == TextNormalizer.albumKey(artist: r.artist, title: r.name)
    }

    /// Fill gaps in self from another result describing the same album.
    mutating func merge(_ other: AlbumResult) {
        spotifyURI = spotifyURI ?? other.spotifyURI
        appleMusicID = appleMusicID ?? other.appleMusicID
        appleMusicURL = appleMusicURL ?? other.appleMusicURL
        image = image ?? other.image
        imageLarge = imageLarge ?? other.imageLarge
        totalTracks = totalTracks ?? other.totalTracks
        if year.isEmpty { year = other.year }
        barcode = barcode ?? other.barcode
        mbid = mbid ?? other.mbid
        mbTitle = mbTitle ?? other.mbTitle
        mbTrackCount = mbTrackCount ?? other.mbTrackCount
        matchedTracks = matchedTracks ?? other.matchedTracks
        trackURIs = trackURIs ?? other.trackURIs
        coverPrint = coverPrint ?? other.coverPrint
    }

    enum CodingKeys: String, CodingKey {
        case name, artist, year, image, imageLarge, totalTracks, barcode, mbid, mbTitle,
             mbTrackCount, matchedTracks, source, scannedAt, coverPrint
        case spotifyURI = "uri"
        case appleMusicID = "appleMusicId"
        case appleMusicURL = "appleMusicUrl"
        case trackURIs = "trackUris"
        case playlistID = "playlistId"
        case playlistURI = "playlistUri"
        case playlistURL = "playlistUrl"
    }

    init(name: String, artist: String, year: String = "", source: ScanSource = .barcode) {
        self.name = name
        self.artist = artist
        self.year = year
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        artist = (try? c.decode(String.self, forKey: .artist)) ?? ""
        year = (try? c.decode(String.self, forKey: .year)) ?? ""
        spotifyURI = try? c.decodeIfPresent(String.self, forKey: .spotifyURI)
        appleMusicID = try? c.decodeIfPresent(String.self, forKey: .appleMusicID)
        appleMusicURL = try? c.decodeIfPresent(String.self, forKey: .appleMusicURL)
        image = (try? c.decodeIfPresent(String.self, forKey: .image)).flatMap { $0.flatMap(URL.init(string:)) }
        imageLarge = (try? c.decodeIfPresent(String.self, forKey: .imageLarge)).flatMap { $0.flatMap(URL.init(string:)) }
        totalTracks = try? c.decodeIfPresent(Int.self, forKey: .totalTracks)
        barcode = try? c.decodeIfPresent(String.self, forKey: .barcode)
        mbid = try? c.decodeIfPresent(String.self, forKey: .mbid)
        mbTitle = try? c.decodeIfPresent(String.self, forKey: .mbTitle)
        mbTrackCount = try? c.decodeIfPresent(Int.self, forKey: .mbTrackCount)
        matchedTracks = try? c.decodeIfPresent([MatchedTrack].self, forKey: .matchedTracks)
        trackURIs = try? c.decodeIfPresent([String].self, forKey: .trackURIs)
        playlistID = try? c.decodeIfPresent(String.self, forKey: .playlistID)
        playlistURI = try? c.decodeIfPresent(String.self, forKey: .playlistURI)
        playlistURL = try? c.decodeIfPresent(String.self, forKey: .playlistURL)
        source = (try? c.decodeIfPresent(ScanSource.self, forKey: .source)) ?? .barcode
        if let s = try? c.decodeIfPresent(String.self, forKey: .scannedAt),
           let d = ISO8601DateFormatter.withFractional.date(from: s) ?? ISO8601DateFormatter().date(from: s) {
            scannedAt = d
        } else {
            scannedAt = .now
        }
        coverPrint = try? c.decodeIfPresent(Data.self, forKey: .coverPrint)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(artist, forKey: .artist)
        try c.encode(year, forKey: .year)
        try c.encodeIfPresent(spotifyURI, forKey: .spotifyURI)
        try c.encodeIfPresent(appleMusicID, forKey: .appleMusicID)
        try c.encodeIfPresent(appleMusicURL, forKey: .appleMusicURL)
        try c.encodeIfPresent(image?.absoluteString, forKey: .image)
        try c.encodeIfPresent(imageLarge?.absoluteString, forKey: .imageLarge)
        try c.encodeIfPresent(totalTracks, forKey: .totalTracks)
        try c.encodeIfPresent(barcode, forKey: .barcode)
        try c.encodeIfPresent(mbid, forKey: .mbid)
        try c.encodeIfPresent(mbTitle, forKey: .mbTitle)
        try c.encodeIfPresent(mbTrackCount, forKey: .mbTrackCount)
        try c.encodeIfPresent(matchedTracks, forKey: .matchedTracks)
        try c.encodeIfPresent(trackURIs, forKey: .trackURIs)
        try c.encodeIfPresent(playlistID, forKey: .playlistID)
        try c.encodeIfPresent(playlistURI, forKey: .playlistURI)
        try c.encodeIfPresent(playlistURL, forKey: .playlistURL)
        try c.encode(source, forKey: .source)
        try c.encode(ISO8601DateFormatter.withFractional.string(from: scannedAt), forKey: .scannedAt)
        try c.encodeIfPresent(coverPrint, forKey: .coverPrint)
    }
}

extension ISO8601DateFormatter {
    static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// A MusicBrainz release, used when a barcode maps to several editions.
struct MBRelease: Identifiable, Hashable {
    var id: String { mbid }
    let mbid: String
    let title: String
    let artist: String
    let year: String
    let country: String
    let label: String
    let trackCount: Int
    let format: String
}

enum TextNormalizer {
    /// Lowercased, diacritic-free, punctuation-free, with edition noise removed.
    static func normalize(_ s: String) -> String {
        var t = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .current)
        // Strip bracketed edition notes: (Remastered 2011), [Deluxe Edition] ...
        t = t.replacingOccurrences(of: #"[\(\[][^\)\]]*[\)\]]"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s-\s.*(remaster|edition|deluxe|version|single|ep).*$"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "&", with: " and ")
        t = t.replacingOccurrences(of: #"[^a-z0-9 ]"#, with: " ", options: .regularExpression)
        return t.split(separator: " ").joined(separator: " ")
    }

    static func tokens(_ s: String) -> [String] {
        let stop: Set<String> = ["the", "a", "an", "of", "and"]
        return normalize(s).split(separator: " ").map(String.init).filter { $0.count >= 2 && !stop.contains($0) }
    }

    static func albumKey(artist: String, title: String) -> String {
        normalize(artist) + "|" + normalize(title)
    }

    /// Token-overlap similarity in 0...1.
    static func similarity(_ a: String, _ b: String) -> Double {
        let ta = Set(tokens(a)), tb = Set(tokens(b))
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        return Double(ta.intersection(tb).count) / Double(max(ta.count, tb.count))
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}
