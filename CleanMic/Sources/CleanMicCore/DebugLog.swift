import Foundation

/// Dijagnostički log u ~/Library/Logs/CleanMic/cleanmic.log.
///
/// Menu-bar app nema terminal, pa se bez fajla ne vidi zašto transkripcija ili
/// izvještaj nisu uspjeli na nekom drugom Macu. U log NIKAD ne ide API ključ
/// ni sadržaj transkripta — samo veličine, statusi, modeli i trajanja.
public enum DebugLog {
    public static let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CleanMic", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cleanmic.log")
    }()

    /// CLI hoće ispis i u terminal; GUI ga ne treba.
    nonisolated(unsafe) public static var echoToStdout = false

    private static let queue = DispatchQueue(label: "cleanmic.debuglog")
    private static let maxBytes: UInt64 = 1_000_000
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    public static func log(_ message: String) {
        let now = Date()
        queue.async {
            let line = "\(stamp.string(from: now)) \(message)\n"
            if echoToStdout { print("   · \(message)") }
            rotateIfNeeded()
            guard let data = line.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: fileURL) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    /// Sačekaj da se sve upiše (CLI prije izlaska).
    public static func flush() {
        queue.sync {}
    }

    private static func rotateIfNeeded() {
        let size = ((try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? NSNumber)?.uint64Value ?? 0
        guard size > maxBytes else { return }
        let old = fileURL.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: fileURL, to: old)
    }
}
