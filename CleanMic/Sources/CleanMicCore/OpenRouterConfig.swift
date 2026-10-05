import Foundation

/// OpenRouter konfiguracija — API ključ + modeli.
/// Ključ se traži ovim redom:
///   1. eksplicitni parametar (--api-key / GUI polje)
///   2. env varijabla OPENROUTER_API_KEY
///   3. fajl ~/.config/cleanmic/openrouter_key (GUI ga tu upisuje)
///   4. UserDefaults "openrouter_api_key" (GUI)
public enum OpenRouterConfig {
    public static let transcribeModelDefault = "microsoft/mai-transcribe-2"
    /// Jeftini modeli za izvještaj (redom po preporuci). Ako izabrani model
    /// padne ili ga OpenRouter ukine, ReportService proba sljedeći sa liste.
    /// Provjereno na openrouter.ai/api/v1/models 05.10.2026 —
    /// google/gemini-flash-1.5-8b više ne postoji, zamijenjen sa 2.5-flash-lite.
    public static let cheapReportModels = [
        "deepseek/deepseek-chat",
        "openai/gpt-4o-mini",
        "google/gemini-2.5-flash-lite",
        "meta-llama/llama-3.1-8b-instruct",
    ]
    public static let reportModelDefault = "deepseek/deepseek-chat"

    /// Sačuvani izbor može biti model koji više ne postoji — vrati ga na default.
    public static func normalizedReportModel(_ model: String?) -> String {
        guard let m = model?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty else {
            return reportModelDefault
        }
        return cheapReportModels.contains(m) ? m : reportModelDefault
    }

    public static let transcriptionURL = URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!
    public static let chatURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    public static let keyInfoURL = URL(string: "https://openrouter.ai/api/v1/key")!

    /// Cijena transkripcije — izmjereno iz usage polja: $0.00456 za 164 s audija.
    public static let transcribeUSDPerHour = 0.10

    public static func resolveAPIKey(explicit: String? = nil) -> String? {
        if let e = explicit?.trimmingCharacters(in: .whitespacesAndNewlines), !e.isEmpty {
            return e
        }
        if let env = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }
        // Fajl ~/.config/cleanmic/openrouter_key
        let home = FileManager.default.homeDirectoryForCurrentUser
        let keyFile = home.appendingPathComponent(".config/cleanmic/openrouter_key")
        if let data = try? Data(contentsOf: keyFile),
           let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty {
            return s
        }
        if let ud = UserDefaults.standard.string(forKey: "openrouter_api_key")?.trimmingCharacters(in: .whitespacesAndNewlines), !ud.isEmpty {
            return ud
        }
        return nil
    }

    public static func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed, forKey: "openrouter_api_key")
        // + fajl da CLI vidi isti ključ
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".config/cleanmic")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keyFile = dir.appendingPathComponent("openrouter_key")
        try? trimmed.write(to: keyFile, atomically: true, encoding: .utf8)
        // chmod 600 — ključ je tajna
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
    }

    public static var storedKeyHint: String {
        guard let k = resolveAPIKey(), k.count > 8 else { return "nije postavljen" }
        return "\(k.prefix(4))…\(k.suffix(4)) (\(k.count) znakova)"
    }
}
