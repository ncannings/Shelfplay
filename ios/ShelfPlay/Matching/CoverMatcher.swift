import UIKit
import Vision

private let log = MatchTrace.self

struct CoverMatchOutcome {
    var best: AlbumResult
    var confidence: Double
    var alternatives: [AlbumResult]
    var note: String
}

enum CoverMatchError: LocalizedError {
    case unreadableImage, noText, noCandidates([String])
    var errorDescription: String? {
        switch self {
        case .unreadableImage: "Couldn’t read that photo."
        case .noText: "No readable text on this cover. Try the barcode, or search by name."
        case .noCandidates(let lines): "Couldn’t match “\(lines.prefix(2).joined(separator: " / "))”. Try the barcode, or search by name."
        }
    }
}

/// On-device album cover recognition:
/// 1. Vision finds and flattens the sleeve, reads its text and computes a visual feature print.
/// 2. Covers already on your shelf are recognised instantly by feature-print distance.
/// 3. Apple Intelligence (Foundation Models) interprets the OCR into artist/title hypotheses.
/// 4. Hypotheses are searched in Apple Music (and Spotify, if connected).
/// 5. Candidates are re-ranked by text agreement and by how closely their artwork matches the photo.
@MainActor
final class CoverMatcher {
    private let spotify: SpotifyAPI
    private let appleMusic: AppleMusicService

    init(spotify: SpotifyAPI, appleMusic: AppleMusicService) {
        self.spotify = spotify
        self.appleMusic = appleMusic
    }

    private struct Candidate {
        var album: AlbumResult
        var textScore: Double = 0
        var visualDistance: Double?
        var score: Double = 0
    }

    func identify(_ photo: UIImage, shelf: [AlbumResult], progress: (String) -> Void) async throws -> CoverMatchOutcome {
        guard let image = CoverImageProcessor.normalized(photo) else { throw CoverMatchError.unreadableImage }

        progress("Finding the sleeve…")
        let (cover, detected) = await CoverImageProcessor.extractCover(from: image)
        async let printTask = CoverImageProcessor.featurePrint(of: cover)
        async let fullPrintTask = CoverImageProcessor.featurePrint(of: image)
        progress("Reading the cover…")
        var lines = await CoverImageProcessor.recognizeText(in: cover)
        if lines.isEmpty { lines = await CoverImageProcessor.recognizeText(in: image) }
        let photoPrint = await printTask
        // Compare artwork against both the cropped sleeve and the whole photo, keeping the closer distance,
        // so a poor crop can't hide a match.
        let photoPrints = [photoPrint, await fullPrintTask].compactMap { $0 }
        log.write("---- New scan. Sleeve: \(detected). Feature prints: \(photoPrints.count)/2")
        let archivedPrint = photoPrint.flatMap(CoverImageProcessor.archive)

        // Already on the shelf? Visual match against covers scanned before.
        if let photoPrint, let hit = nearestShelfMatch(photoPrint, shelf: shelf) {
            var album = hit
            album.source = .cover
            album.coverPrint = archivedPrint
            return CoverMatchOutcome(best: album, confidence: 0.95, alternatives: [], note: "Recognised from your shelf")
        }
        log.write("OCR lines: \(lines.map(\.text).joined(separator: " | "))")
        guard !lines.isEmpty else { throw CoverMatchError.noText }

        progress(CoverReader.isAvailable ? "Apple Intelligence is reading the cover…" : "Interpreting the cover…")
        let (guesses, usedModel) = await CoverReader.guesses(from: lines)
        log.write("Guesses (model: \(usedModel)): \(guesses.map { "\($0.artist) / \($0.title)" }.joined(separator: "; "))")

        progress("Searching the catalogue…")
        var candidates = await search(guesses: guesses, lines: lines)
        guard !candidates.isEmpty else { throw CoverMatchError.noCandidates(lines.map(\.text)) }

        // Text agreement with what's printed on the sleeve and with the model's readings.
        let ocrTokens = Set(lines.flatMap { TextNormalizer.tokens($0.text) })
        for i in candidates.indices {
            candidates[i].textScore = Self.textScore(candidates[i].album, guesses: guesses, ocr: ocrTokens)
        }

        // Visual re-ranking against candidate artwork. Feature-print distances aren't on a fixed scale
        // (on device they run roughly 0.9–1.8 between a photo and catalogue artwork), so candidates are
        // scored relative to each other: nearest artwork 1, furthest 0. On real photos the general-purpose
        // feature print can prefer the wrong sleeve, so artwork only gets 30% of the score.
        var visualMargin: Double = 0
        if !photoPrints.isEmpty {
            progress("Comparing artwork…")
            candidates.sort { $0.textScore > $1.textScore }
            let distances = await artworkDistances(Array(candidates.prefix(12)).map(\.album.image), to: photoPrints)
            log.write("Artwork distances: \(distances.map { $0.map { String(format: "%.3f", $0) } ?? "nil" }.joined(separator: ", "))")
            let valid = distances.compactMap { $0 }.sorted()
            // Ignore visual evidence that can't tell candidates apart (e.g. a failed model).
            if valid.count >= 2, valid.last! - valid.first! > 0.05 {
                for (i, d) in distances.enumerated() { candidates[i].visualDistance = d }
                visualMargin = valid[1] - valid[0]
                let (lo, hi) = (valid.first!, valid.last!)
                for i in candidates.indices {
                    let visual = candidates[i].visualDistance.map { (hi - $0) / (hi - lo) } ?? 0
                    candidates[i].score = 0.3 * visual + 0.7 * candidates[i].textScore
                }
            } else {
                for i in candidates.indices { candidates[i].score = candidates[i].textScore }
            }
        } else {
            for i in candidates.indices { candidates[i].score = candidates[i].textScore }
        }
        candidates.sort { $0.score > $1.score }
        for c in candidates.prefix(8) {
            log.write("Candidate \(c.album.artist) — \(c.album.name): text \(String(format: "%.3f", c.textScore)) visual-d \(c.visualDistance.map { String(format: "%.3f", $0) } ?? "-") score \(String(format: "%.3f", c.score))")
        }

        // The pick's artwork is clearly the closest to the photo.
        let closest = candidates.compactMap(\.visualDistance).min()
        let visuallyConfirmed = candidates[0].visualDistance != nil && candidates[0].visualDistance == closest && visualMargin >= 0.15
        log.write("Picked: \(candidates[0].album.artist) — \(candidates[0].album.name)")
        var best = candidates[0].album
        best.source = .cover
        best.coverPrint = archivedPrint
        // A strong artwork match confirms the pairing; otherwise wait for the user to confirm it.
        best.coverPrintConfirmed = visuallyConfirmed
        if best.spotifyURI == nil, spotify.isConnected {
            let s = await spotify.findAlbum(matching: best)
            best.spotifyURI = s?.spotifyURI
            log.write("Spotify: \(s.map { "\($0.artist) — \($0.name)" } ?? "no confident match")")
        } else {
            log.write("Spotify: \(spotify.isConnected ? "already matched" : "not connected")")
        }

        var note = usedModel ? "Identified with Apple Intelligence" : "Identified from cover text"
        if visuallyConfirmed { note += " · artwork matches" }
        let alternatives = candidates.dropFirst().prefix(5).map { c -> AlbumResult in
            var a = c.album
            a.source = .cover
            a.coverPrint = archivedPrint
            a.coverPrintConfirmed = false
            return a
        }
        return CoverMatchOutcome(best: best, confidence: candidates[0].score, alternatives: Array(alternatives), note: note)
    }

    // MARK: - Steps

    /// Nearest shelf cover, accepted only if it's close *and* clearly closer than the runner-up.
    private func nearestShelfMatch(_ print: FeaturePrintObservation, shelf: [AlbumResult]) -> AlbumResult? {
        var scored: [(AlbumResult, Double)] = []
        for album in shelf where album.coverPrintConfirmed {
            guard let data = album.coverPrint, let stored = CoverImageProcessor.unarchive(data),
                  let d = try? print.distance(to: stored) else { continue }
            scored.append((album, d))
        }
        scored.sort { $0.1 < $1.1 }
        guard let best = scored.first, best.1 < 0.35 else { return nil }
        if scored.count > 1, scored[1].1 - best.1 < 0.15 { return nil }
        log.write("Shelf match \(best.0.name) at distance \(best.1)")
        return best.0
    }

    private func search(guesses: [AlbumGuess], lines: [OCRLine]) async -> [Candidate] {
        func term(_ g: AlbumGuess) -> String { g.artist == g.title ? g.artist : "\(g.artist) \(g.title)" }
        var albumTerms = guesses.prefix(3).map(term)
        if let top = guesses.first, !top.title.isEmpty, !albumTerms.contains(top.title) { albumTerms.append(top.title) }
        if guesses.isEmpty || !CoverReader.isAvailable { albumTerms.append(lines.prefix(3).map(\.text).joined(separator: " ")) }
        let primary = guesses.first { TextNormalizer.normalize($0.artist) != TextNormalizer.normalize($0.title) } ?? guesses.first
        let songTerm = primary.map(term)
        let musicKitTerm = primary.map(term)

        var found: [AlbumResult] = []
        await withTaskGroup(of: [AlbumResult].self) { group in
            for t in albumTerms {
                group.addTask { await Catalog.appleMusicAlbums(term: t, limit: 5) }
            }
            if let songTerm {
                group.addTask { await Catalog.appleMusicAlbumsViaSongs(term: songTerm) }
            }
            for await batch in group { found += batch }
        }
        log.write("iTunes candidates: \(found.count) from album terms \(albumTerms) + song term \(songTerm ?? "-")")
        if let musicKitTerm {
            let mk = await appleMusic.searchAlbums(term: musicKitTerm)
            log.write("MusicKit candidates: \(mk.count) (authorized: \(appleMusic.isAuthorized))")
            found += mk
        }
        if spotify.isConnected {
            for g in guesses.prefix(2) {
                found += await spotify.searchAlbums(query: "album:\(g.title) artist:\(g.artist)", limit: 3)
            }
        }

        // Merge the same album from several sources.
        var byKey: [String: AlbumResult] = [:]
        var order: [String] = []
        for album in found {
            let key = album.appleMusicID.map { "am:\($0)" } ?? TextNormalizer.albumKey(artist: album.artist, title: album.name)
            let fuzzyKey = TextNormalizer.albumKey(artist: album.artist, title: album.name)
            let existingKey = byKey[key] != nil ? key : (byKey[fuzzyKey] != nil ? fuzzyKey : nil)
            if let existingKey, var existing = byKey[existingKey] {
                existing.merge(album)
                byKey[existingKey] = existing
            } else {
                byKey[key] = album
                byKey[fuzzyKey] = album
                order.append(key)
            }
        }
        return order.compactMap { byKey[$0] }.map { Candidate(album: $0) }
    }

    // MARK: - Text scoring

    /// Words that describe an edition rather than identify an album.
    private static let editionWords: Set<String> = [
        "original", "soundtrack", "motion", "picture", "from", "music", "edition", "deluxe", "remastered",
        "remaster", "version", "expanded", "anniversary", "recording", "cast", "ost", "score", "film", "feat",
    ]
    private static var variantWords: Set<String> { TextNormalizer.variantWords }

    private static func coreTokens(_ s: String) -> [String] {
        TextNormalizer.tokens(s).filter { !editionWords.contains($0) }
    }

    private static func artistSegments(_ s: String) -> [String] { TextNormalizer.artistSegments(s) }

    /// Fraction of `needle` tokens found in `haystack` tokens (fuzzy for long words).
    private static func containment(_ needle: [String], in haystack: Set<String>) -> Double {
        guard !needle.isEmpty else { return 0 }
        let hits = needle.filter { t in
            haystack.contains(t) || (t.count >= 5 && haystack.contains { abs($0.count - t.count) <= 1 && TextNormalizer.levenshtein($0, t) <= 1 })
        }
        return Double(hits.count) / Double(needle.count)
    }

    static func textScore(_ a: AlbumResult, guesses: [AlbumGuess], ocr: Set<String>) -> Double {
        let titleTokens = coreTokens(a.name)
        let isVarious = TextNormalizer.normalize(a.artist).contains("various artists")
        let segments = artistSegments(a.artist)

        // Is the candidate's title printed on the sleeve? Is one of its credited artists?
        let titleOnCover = containment(titleTokens, in: ocr)
        let artistOnCover = isVarious ? 0.5 : (segments.map { containment(coreTokens($0), in: ocr) }.max() ?? 0)

        // Agreement with the best-matching Apple Intelligence reading.
        let titleSet = Set(titleTokens)
        let agreement = guesses.prefix(3).enumerated().map { i, g -> Double in
            let gTitle = coreTokens(g.title)
            // Title agreement is symmetric containment so "Grease" ≈ "Grease (Original Soundtrack…)".
            let t = gTitle.isEmpty ? 0 : max(containment(gTitle, in: titleSet), containment(titleTokens, in: Set(gTitle)))
            let gArtist = coreTokens(g.artist)
            // A "Grease / Grease" reading says nothing about the artist when other readings name one.
            let selfTitledGuess = guesses.count > 1 && TextNormalizer.normalize(g.artist) == TextNormalizer.normalize(g.title)
            let ar = (isVarious || selfTitledGuess) ? 0.5 : (segments.map { seg -> Double in
                let segTokens = coreTokens(seg)
                return max(containment(gArtist, in: Set(segTokens)), containment(segTokens, in: Set(gArtist)))
            }.max() ?? 0)
            let rankWeight = i == 0 ? 1.0 : 0.85
            return (0.7 * t + 0.3 * ar) * rankWeight
        }.max() ?? 0

        var score = 0.35 * titleOnCover + 0.15 * artistOnCover + 0.5 * agreement
        // "Greatest Hits", "Live" … only when the sleeve says so.
        let variantHits = Set(TextNormalizer.tokens("\(a.name) \(a.artist)")).intersection(variantWords)
        if !variantHits.isEmpty, variantHits.isDisjoint(with: ocr) { score -= 0.3 }
        // Self-titled albums only when the guess is self-titled.
        if !segments.isEmpty, TextNormalizer.normalize(a.name) == TextNormalizer.normalize(a.artist),
           let top = guesses.first, TextNormalizer.normalize(top.title) != TextNormalizer.normalize(top.artist) {
            score -= 0.2
        }
        return max(0, min(1, score))
    }

    private func artworkDistances(_ urls: [URL?], to photos: [FeaturePrintObservation]) async -> [Double?] {
        await withTaskGroup(of: (Int, Double?).self) { group in
            for (i, url) in urls.enumerated() {
                group.addTask {
                    guard let url, let art = await CoverImageProcessor.downloadImage(url),
                          let artPrint = await CoverImageProcessor.featurePrint(of: art) else { return (i, nil) }
                    return (i, photos.compactMap { try? $0.distance(to: artPrint) }.min())
                }
            }
            var out = [Double?](repeating: nil, count: urls.count)
            for await (i, d) in group { out[i] = d }
            return out
        }
    }

}
