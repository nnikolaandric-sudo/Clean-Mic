import Foundation

/// OpenRouter konfiguracija — API ključ + modeli.
/// Ključ se traži ovim redom:
///   1. eksplicitni parametar (--api-key / GUI polje)
///   2. env varijabla OPENROUTER_API_KEY
///   3. fajl ~/.config/cleanmic/openrouter_key (GUI ga tu upisuje)
///   4. UserDefaults "openrouter_api_key" (GUI)
public enum OpenRouterConfig {
    public static let transcribeModelDefault = "microsoft/mai-transcribe-2"
    public struct ReportModelOption: Hashable {
        public let id: String
        public let name: String
    }

    /// Modeli ponuđeni u Podešavanjima (prvi je default). Bilo koji drugi
    /// OpenRouter model se može upisati ručno — vidi `OpenRouterClient.modelInfo`.
    /// Svi ID-jevi provjereni na openrouter.ai/api/v1/models 05.10.2026.
    public static let reportModelOptions = [
        ReportModelOption(id: "openai/gpt-6-luna", name: "GPT-6 Luna"),
        ReportModelOption(id: "openai/gpt-6-luna-pro", name: "GPT-6 Luna Pro"),
        ReportModelOption(id: "openai/gpt-6-sol", name: "GPT-6 Sol"),
        ReportModelOption(id: "anthropic/claude-haiku-4.5", name: "Claude Haiku 4.5"),
        ReportModelOption(id: "google/gemini-2.5-flash-lite", name: "Gemini 2.5 Flash Lite"),
        ReportModelOption(id: "deepseek/deepseek-chat", name: "DeepSeek Chat"),
        ReportModelOption(id: "openai/gpt-4o-mini", name: "GPT-4o mini"),
        ReportModelOption(id: "meta-llama/llama-3.1-8b-instruct", name: "Llama 3.1 8B"),
    ]
    public static let reportModelDefault = "openai/gpt-6-luna"
    /// Default do verzije 1.1 — koristi se samo za jednokratni prelazak na novi.
    public static let previousReportModelDefault = "deepseek/deepseek-chat"

    /// Ako izabrani model ne odgovori, ReportService proba ove redom. Samo jeftini
    /// modeli: rezerva ne smije tiho napraviti skup izvještaj.
    public static let fallbackReportModels = [
        "openai/gpt-6-luna",
        "deepseek/deepseek-chat",
        "openai/gpt-4o-mini",
        "google/gemini-2.5-flash-lite",
    ]

    /// Modeli koje OpenRouter više ne nudi (sačuvani izbor se vraća na default).
    static let removedReportModels: Set<String> = ["google/gemini-flash-1.5-8b"]

    /// Prazan ili ukinut model → default; sve ostalo (i ručno upisan ID) ostaje.
    public static func normalizedReportModel(_ model: String?) -> String {
        guard let m = model?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty,
              !removedReportModels.contains(m) else {
            return reportModelDefault
        }
        return m
    }

    public static func reportModelName(_ id: String) -> String {
        reportModelOptions.first(where: { $0.id == id })?.name ?? id
    }

    public static let transcriptionURL = URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!
    public static let chatURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    public static let keyInfoURL = URL(string: "https://openrouter.ai/api/v1/key")!
    public static let modelsURL = URL(string: "https://openrouter.ai/api/v1/models")!

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
