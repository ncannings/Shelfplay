import Foundation
import FoundationModels

/// An artist/title hypothesis for a photographed cover.
struct AlbumGuess: Hashable, Sendable {
    var artist: String
    var title: String
}

@Generable(description: "An interpretation of which text on an album cover is the artist and which is the album title")
struct GeneratedAlbumGuess {
    @Guide(description: "The performing artist or band name, with OCR spelling mistakes corrected")
    var artist: String
    @Guide(description: "The album title. For a self-titled album, repeat the artist name.")
    var title: String
}

@Generable(description: "Interpretations of the text on an album cover")
struct GeneratedCoverReading {
    @Guide(description: "One to three interpretations, most likely first", .count(1...3))
    var guesses: [GeneratedAlbumGuess]
}

/// Uses the on-device Apple Intelligence foundation model to turn noisy OCR from a sleeve
/// into artist/title hypotheses. Falls back to a size-based heuristic when the model is unavailable.
enum CoverReader {
    static var availability: SystemLanguageModel.Availability { SystemLanguageModel.default.availability }

    static var isAvailable: Bool {
        if case .available = availability { return true }
        return false
    }

    static var statusText: String {
        switch availability {
        case .available: return "On — cover text is interpreted on-device"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "This device doesn’t support Apple Intelligence — using basic text matching"
            case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in iOS Settings for better cover matching"
            case .modelNotReady: return "Apple Intelligence model is still downloading"
            @unknown default: return "Unavailable — using basic text matching"
            }
        }
    }

    private static let instructions = """
    You identify music albums from text that OCR read off a photo of a vinyl record sleeve or CD cover.
    The text can contain OCR mistakes, record label names, catalogue numbers, track titles, stickers, \
    "Stereo", "Remastered", "Parental Advisory" and other noise — ignore those.
    Decide which text is the performing artist and which is the album title. Larger text is usually the \
    artist or the title. If only one name stands out, the album may be self-titled.
    Soundtracks and cast recordings: the album title is the film or show name (for example "Grease"), \
    and the actors' names are performers, so use the most prominent performer as the artist.
    Use your knowledge of real albums to correct misspellings and to choose between interpretations, \
    but never invent an artist or title that the text does not support.
    """

    static func guesses(from lines: [OCRLine]) async -> (guesses: [AlbumGuess], usedModel: Bool) {
        guard !lines.isEmpty else { return ([], false) }
        if isAvailable, let modelGuesses = try? await modelGuesses(from: lines), !modelGuesses.isEmpty {
            return (dedupe(modelGuesses + heuristicGuesses(from: lines)), true)
        }
        return (heuristicGuesses(from: lines), false)
    }

    private static func modelGuesses(from lines: [OCRLine]) async throws -> [AlbumGuess] {
        let listing = lines.prefix(25).map { line -> String in
            let size = line.relativeHeight > 0.08 ? "large" : line.relativeHeight > 0.035 ? "medium" : "small"
            return "- \"\(line.text)\" (\(size) text)"
        }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: "Text found on the cover, largest first:\n\(listing)\n\nWhich album is this?",
            generating: GeneratedCoverReading.self,
            options: GenerationOptions(temperature: 0.2))
        return response.content.guesses
            .map { AlbumGuess(artist: $0.artist.trimmingCharacters(in: .whitespaces), title: $0.title.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.artist.isEmpty || !$0.title.isEmpty }
    }

    /// Without the model: the two most prominent lines, in both orders.
    static func heuristicGuesses(from lines: [OCRLine]) -> [AlbumGuess] {
        let prominent = lines.prefix(4).map(\.text)
        guard let first = prominent.first else { return [] }
        guard prominent.count > 1 else { return [AlbumGuess(artist: first, title: first)] }
        return [AlbumGuess(artist: first, title: prominent[1]), AlbumGuess(artist: prominent[1], title: first)]
    }

    private static func dedupe(_ g: [AlbumGuess]) -> [AlbumGuess] {
        var seen = Set<String>()
        return g.filter { seen.insert(TextNormalizer.albumKey(artist: $0.artist, title: $0.title)).inserted }
    }
}
