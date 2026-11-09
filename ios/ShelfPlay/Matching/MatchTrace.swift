import Foundation
import OSLog

/// Diagnostics for cover matching. Always goes to the unified log; debug builds also append to
/// Documents/match-trace.log so a trace can be pulled off a device with devicectl.
enum MatchTrace {
    private static let logger = Logger(subsystem: "stream.shelfplay", category: "CoverMatcher")
    private static let queue = DispatchQueue(label: "shelfplay.trace")

    static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "match-trace.log")
    }

    static func callAsFunction(_ message: String) { write(message) }

    static func write(_ message: String) {
        logger.info("\(message, privacy: .public)")
        #if DEBUG
        let line = "\(ISO8601DateFormatter().string(from: .now)) \(message)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: fileURL)
            }
        }
        #endif
    }
}
