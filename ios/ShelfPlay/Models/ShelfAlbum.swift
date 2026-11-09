import Foundation
import SwiftData

/// A record on the user's shelf. The full album description is stored as JSON in `payload`
/// (same shape as the web app's library entries); a few fields are lifted out for sorting/search.
@Model
final class ShelfAlbum {
    @Attribute(.unique) var key: String
    var name: String
    var artist: String
    var year: String
    var imageURLString: String?
    var barcode: String?
    var appleMusicID: String?
    var scannedAt: Date
    var sourceRaw: String
    var payload: Data

    init(_ result: AlbumResult) {
        key = result.libraryKey
        name = result.name
        artist = result.artist
        year = result.year
        imageURLString = result.image?.absoluteString
        barcode = result.barcode
        appleMusicID = result.appleMusicID
        scannedAt = result.scannedAt
        sourceRaw = result.source.rawValue
        payload = (try? JSONEncoder().encode(result)) ?? Data()
    }

    var result: AlbumResult {
        (try? JSONDecoder().decode(AlbumResult.self, from: payload)) ?? AlbumResult(name: name, artist: artist, year: year)
    }

    var imageURL: URL? { imageURLString.flatMap(URL.init(string:)) }

    func update(from r: AlbumResult) {
        key = r.libraryKey
        name = r.name
        artist = r.artist
        year = r.year
        imageURLString = r.image?.absoluteString
        barcode = r.barcode
        appleMusicID = r.appleMusicID
        scannedAt = r.scannedAt
        sourceRaw = r.source.rawValue
        payload = (try? JSONEncoder().encode(r)) ?? payload
    }

    func matches(_ r: AlbumResult) -> Bool {
        if key == r.libraryKey { return true }
        if let b = r.barcode, b == barcode { return true }
        if let id = r.appleMusicID, id == appleMusicID { return true }
        return TextNormalizer.albumKey(artist: artist, title: name) == TextNormalizer.albumKey(artist: r.artist, title: r.name)
    }
}
