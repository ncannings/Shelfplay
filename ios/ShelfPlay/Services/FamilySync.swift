import Foundation

/// Family library sync against the ShelfPlay Cloudflare Worker (/api/library/*).
/// The JSON shape matches the web app, so web and iOS family members share one shelf.
enum FamilySync {
    enum SyncError: LocalizedError {
        case notConfigured, server(String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: "Family sync needs SHELFPLAY_API_HOST in Secrets.xcconfig."
            case .server(let m): m
            }
        }
    }

    static var isAvailable: Bool { AppConfig.apiBase != nil }

    static func generateCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var bytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    static func save(code: String, library: [AlbumResult]) async throws -> Int {
        guard let base = AppConfig.apiBase else { throw SyncError.notConfigured }
        // Feature prints are device-local; don't upload them.
        let entries: [[String: Any]] = library.compactMap { album in
            var a = album
            a.coverPrint = nil
            guard let data = try? JSONEncoder().encode(a),
                  var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            obj["id"] = album.libraryKey
            return obj
        }
        var req = URLRequest(url: base.appending(path: "api/library/save"), timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["family_code": code, "library_data": entries])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw SyncError.server(String(data: data, encoding: .utf8) ?? "Sync failed")
        }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["total"] as? Int ?? library.count
    }

    static func load(code: String) async throws -> [AlbumResult] {
        guard let base = AppConfig.apiBase else { throw SyncError.notConfigured }
        var c = URLComponents(url: base.appending(path: "api/library/load"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "family_code", value: code)]
        let (data, resp) = try await URLSession.shared.data(from: c.url!)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw SyncError.server("Couldn’t load family library") }
        return (try? JSONDecoder().decode([AlbumResult].self, from: data)) ?? []
    }
}
