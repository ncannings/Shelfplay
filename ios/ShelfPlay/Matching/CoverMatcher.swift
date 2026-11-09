import OSLog
import UIKit
import Vision

private let log = Logger(subsystem: "stream.shelfplay", category: "CoverMatcher")

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

    init(spotify: SpotifyAPI) { self.spotify = spotify }

    private struct Candidate {
        var album: AlbumResult
        var textScore: Double = 0
        var visualDistance: Double?
        var score: Double = 0
    }

    func identify(_ photo: UIImage, shelf: [AlbumResult], progress: (String) -> Void) async throws -> CoverMatchOutcome {
        guard let image = CoverImageProcessor.normalized(photo) else { throw CoverMatchError.unreadableImage }

        progress("Finding the sleeve…")
        let (cover, _) = await CoverImageProcessor.extractCover(from: image)
        async let printTask = CoverImageProcessor.featurePrint(of: cover)
        progress("Reading the cover…")
        var lines = await CoverImageProcessor.recognizeText(in: cover)
        if lines.isEmpty { lines = await CoverImageProcessor.recognizeText(in: image) }
        let photoPrint = await printTask
        let archivedPrint = photoPrint.flatMap(CoverImageProcessor.archive)

        // Already on the shelf? Visual match against covers scanned before.
        if let photoPrint, let hit = nearestShelfMatch(photoPrint, shelf: shelf) {
            var album = hit
            album.source = .cover
            album.coverPrint = archivedPrint
            return CoverMatchOutcome(best: album, confidence: 0.95, alternatives: [], note: "Recognised from your shelf")
        }
        log.info("OCR lines: \(lines.map(\.text).joined(separator: " | "), privacy: .public)")
        guard !lines.isEmpty else { throw CoverMatchError.noText }

        progress(CoverReader.isAvailable ? "Apple Intelligence is reading the cover…" : "Interpreting the cover…")
        let (guesses, usedModel) = await CoverReader.guesses(from: lines)
        log.info("Guesses (model: \(usedModel)): \(guesses.map { "\($0.artist) / \($0.title)" }.joined(separator: "; "), privacy: .public)")

        progress("Searching the catalogue…")
        var candidates = await search(guesses: guesses, lines: lines)
        guard !candidates.isEmpty else { throw CoverMatchError.noCandidates(lines.map(\.text)) }

        // Text agreement with what's printed on the sleeve and with the model's top reading.
        let ocrTokens = Set(lines.flatMap { TextNormalizer.tokens($0.text) })
        let top = guesses.first
        for i in candidates.indices {
            let a = candidates[i].album
            let coverage = Self.coverage(of: TextNormalizer.tokens("\(a.artist) \(a.name)"), in: ocrTokens)
            let agreement = top.map {
                (TextNormalizer.similarity($0.artist, a.artist) + TextNormalizer.similarity($0.title, a.name)) / 2
            } ?? 0
            candidates[i].textScore = 0.6 * coverage + 0.4 * agreement
        }

        // Visual re-ranking against candidate artwork.
        if let photoPrint {
            progress("Comparing artwork…")
            candidates.sort { $0.textScore > $1.textScore }
            let distances = await artworkDistances(Array(candidates.prefix(10)).map(\.album.image), to: photoPrint)
            // Ignore visual evidence that can't tell candidates apart (e.g. a failed model).
            let valid = distances.compactMap { $0 }
            if valid.count >= 2, (valid.max()! - valid.min()!) > 0.05 {
                for (i, d) in distances.enumerated() { candidates[i].visualDistance = d }
            }
        }
        for i in candidates.indices {
            if let d = candidates[i].visualDistance {
                let visual = max(0, min(1, (1.0 - d) / 0.6))
                candidates[i].score = 0.5 * visual + 0.5 * candidates[i].textScore
            } else {
                candidates[i].score = candidates[i].textScore * 0.85
            }
        }
        candidates.sort { $0.score > $1.score }
        for c in candidates.prefix(5) {
            log.info("Candidate \(c.album.artist, privacy: .public) — \(c.album.name, privacy: .public): text \(c.textScore) visual-d \(c.visualDistance ?? -1) score \(c.score)")
        }

        var best = candidates[0].album
        best.source = .cover
        best.coverPrint = archivedPrint
        if best.spotifyURI == nil, spotify.isConnected,
           let s = await spotify.searchAlbum(artist: best.artist, title: best.name) {
            best.spotifyURI = s.spotifyURI
            best.totalTracks = best.totalTracks ?? s.totalTracks
        }

        let visuallyConfirmed = (candidates[0].visualDistance ?? 2) < 0.6
        var note = usedModel ? "Identified with Apple Intelligence" : "Identified from cover text"
        if visuallyConfirmed { note += " · artwork matches" }
        let alternatives = candidates.dropFirst().prefix(5).map { c -> AlbumResult in
            var a = c.album
            a.source = .cover
            a.coverPrint = archivedPrint
            return a
        }
        return CoverMatchOutcome(best: best, confidence: candidates[0].score, alternatives: Array(alternatives), note: note)
    }

    // MARK: - Steps

    /// Nearest shelf cover, accepted only if it's close *and* clearly closer than the runner-up.
    private func nearestShelfMatch(_ print: FeaturePrintObservation, shelf: [AlbumResult]) -> AlbumResult? {
        var scored: [(AlbumResult, Double)] = []
        for album in shelf {
            guard let data = album.coverPrint, let stored = CoverImageProcessor.unarchive(data),
                  let d = try? print.distance(to: stored) else { continue }
            scored.append((album, d))
        }
        scored.sort { $0.1 < $1.1 }
        guard let best = scored.first, best.1 < 0.35 else { return nil }
        if scored.count > 1, scored[1].1 - best.1 < 0.15 { return nil }
        log.info("Shelf match \(best.0.name, privacy: .public) at distance \(best.1)")
        return best.0
    }

    private func search(guesses: [AlbumGuess], lines: [OCRLine]) async -> [Candidate] {
        var terms = guesses.prefix(3).map { $0.artist == $0.title ? $0.artist : "\($0.artist) \($0.title)" }
        terms.append(lines.prefix(3).map(\.text).joined(separator: " "))

        var found: [AlbumResult] = []
        await withTaskGroup(of: [AlbumResult].self) { group in
            for term in terms {
                group.addTask { await Catalog.appleMusicAlbums(term: term, limit: 5) }
            }
            for await batch in group { found += batch }
        }
        if spotify.isConnected {
            for g in guesses.prefix(2) {
                found += await spotify.searchAlbums(query: "album:\(g.title) artist:\(g.artist)", limit: 3)
            }
        }

        // Merge the same album from both services.
        var byKey: [String: AlbumResult] = [:]
        var order: [String] = []
        for album in found {
            let key = TextNormalizer.albumKey(artist: album.artist, title: album.name)
            if var existing = byKey[key] {
                existing.merge(album)
                byKey[key] = existing
            } else {
                byKey[key] = album
                order.append(key)
            }
        }
        return order.compactMap { byKey[$0] }.map { Candidate(album: $0) }
    }

    private func artworkDistances(_ urls: [URL?], to photo: FeaturePrintObservation) async -> [Double?] {
        await withTaskGroup(of: (Int, Double?).self) { group in
            for (i, url) in urls.enumerated() {
                group.addTask {
                    guard let url, let art = await CoverImageProcessor.downloadImage(url),
                          let artPrint = await CoverImageProcessor.featurePrint(of: art) else { return (i, nil) }
                    return (i, try? photo.distance(to: artPrint))
                }
            }
            var out = [Double?](repeating: nil, count: urls.count)
            for await (i, d) in group { out[i] = d }
            return out
        }
    }

    private static func coverage(of tokens: [String], in ocr: Set<String>) -> Double {
        guard !tokens.isEmpty else { return 0 }
        let hits = tokens.filter { t in
            ocr.contains(t) || (t.count >= 5 && ocr.contains { abs($0.count - t.count) <= 1 && TextNormalizer.levenshtein($0, t) <= 1 })
        }
        return Double(hits.count) / Double(tokens.count)
    }
}
