import Foundation

/// Izvještaj iz transkripta preko OpenRouter /chat/completions (jeftin LLM).
/// Izlaz: `<ime>.izvjestaj.md` pored snimka — Sažetak, Ključne tačke, Akcije, pa puni transkript.
///
/// Šta je ovdje popravljeno:
///  - Model je ranije morao u odgovoru PREPISATI cijeli transkript, uz
///    `max_tokens: 1500`. Za sve duže od ~3 minuta odgovor bi bio odsječen
///    usred transkripta i sekcije Sažetak / Ključne tačke / Akcije nikad nisu
///    stigle na red (snimak od 13 min: izvještaj 4.4 KB, samo "## Transkript").
///    Sada model piše samo sažetak, a transkript se dodaje lokalno, cijeli.
///  - Dug transkript (sati snimka) ide dio po dio: bilješke po dijelovima, pa
///    jedan završni izvještaj iz bilješki. Tako ništa ne ispada iz konteksta.
///  - Jezik izvještaja prati izabrani jezik (ranije uvijek srpski).
///  - Ako izabrani model padne ili ga OpenRouter ukine, proba se sljedeći.
public enum ReportService {

    public struct Report {
        /// Cijeli .md fajl (zaglavlje + sažetak + transkript).
        public let markdown: String
        /// Samo ono što je napisao model (Sažetak / Ključne tačke / Akcije).
        public let summaryMarkdown: String
        public let reportPath: String
        public let modelUsed: String
        /// 1 = transkript obrađen odjednom; više = bilješke po dijelovima.
        public let chunks: Int
    }

    public enum ReportError: Error, CustomStringConvertible {
        case emptyTranscript
        case emptyResponse(String)

        public var description: String {
            switch self {
            case .emptyTranscript: return "Transkript je prazan — nema od čega napraviti izvještaj."
            case .emptyResponse(let model): return "Model \(model) je vratio prazan odgovor."
            }
        }
    }

    /// (faza, urađeno, ukupno) — npr. ("bilješke", 2, 5)
    public typealias Progress = (_ stage: String, _ done: Int, _ total: Int) -> Void

    /// Do ove dužine transkript ide modelu odjednom (~15 hiljada tokena).
    static let singlePassChars = 45_000
    static let chunkChars = 30_000
    static let maxConcurrentChunks = 3

    // MARK: - Jezik

    struct Labels {
        let languageInstruction: String
        let title: String
        let summary: String
        let keyPoints: String
        let actions: String
        let noActions: String
        let transcript: String
        let recording: String
        let date: String
        let duration: String
        let models: String
    }

    static func labels(language: String?) -> Labels {
        switch language?.lowercased() {
        case "en":
            return Labels(languageInstruction: "English",
                          title: "Report — CleanMic", summary: "Summary", keyPoints: "Key points",
                          actions: "Action items", noActions: "No explicit action items.",
                          transcript: "Transcript", recording: "Recording", date: "Date",
                          duration: "Duration", models: "Models")
        case "hr":
            return bcs("hrvatskom jeziku")
        case "bs":
            return bcs("bosanskom jeziku")
        case "sr":
            return bcs("srpskom jeziku, latinicom")
        default:
            return bcs("istom jeziku na kojem je transkript (ako je srpski/hrvatski/bosanski — latinicom)")
        }
    }

    private static func bcs(_ instruction: String) -> Labels {
        Labels(languageInstruction: instruction,
               title: "Izvještaj — CleanMic", summary: "Sažetak", keyPoints: "Ključne tačke",
               actions: "Akcije / sljedeći koraci", noActions: "Nema eksplicitnih akcija.",
               transcript: "Transkript", recording: "Snimak", date: "Datum",
               duration: "Trajanje", models: "Modeli")
    }

    // MARK: - Promptovi

    static func systemPrompt(_ l: Labels) -> String {
        """
        Ti si asistent koji od transkripta audio snimka (sastanak, razgovor, diktat) pravi tačan i pregledan izvještaj.
        Piši na: \(l.languageInstruction).
        Koristi isključivo informacije iz transkripta — ništa ne izmišljaj i ne dodaji vanjsko znanje.
        Transkript je nastao automatskim prepoznavanjem govora: ignoriši poštapalice i ponavljanja, a očigledne greške prepoznavanja (npr. pogrešno napisane nazive) tumači po kontekstu.
        Ako je transkript prekratak ili nerazumljiv, reci to jasno umjesto da nagađaš.
        """
    }

    /// Obim izvještaja raste sa dužinom snimka: sat vremena razgovora ne staje u 3 rečenice.
    static func sizing(words: Int) -> (sentences: String, points: String) {
        switch words {
        case ..<300: return ("2–4", "3–6")
        case ..<3000: return ("4–6", "5–10")
        default: return ("6–10", "8–15")
        }
    }

    static func finalPrompt(_ l: Labels, material: String, materialTitle: String, words: Int) -> String {
        let size = sizing(words: words)
        return """
        Napravi izvještaj u Markdown formatu sa TAČNO ove tri sekcije i ovim naslovima. Bez uvoda, bez zaključka i bez prepisivanja transkripta — transkript se dodaje automatski.

        ## \(l.summary)
        (\(size.sentences) rečenica: o čemu se radi, ko učestvuje ako je jasno, glavni zaključci)

        ## \(l.keyPoints)
        (\(size.points) stavki, svaka počinje sa "- "; konkretne činjenice, brojevi, imena, nazivi, odluke)

        ## \(l.actions)
        (stavke sa "- "; ko šta treba uraditi i do kada, ako je rečeno; ako nema jasnih akcija napiši "- \(l.noActions)")

        \(materialTitle):
        \"\"\"
        \(material)
        \"\"\"
        """
    }

    static func notesPrompt(chunk: String, index: Int, total: Int) -> String {
        """
        Ovo je dio \(index) od \(total) dugog transkripta. Izvuci detaljne bilješke SAMO iz ovog dijela, bez uvoda i bez zaključka:
        - teme i tok razgovora, hronološki
        - konkretne činjenice, brojevi, imena, nazivi
        - odluke i zaključci
        - zadaci i dogovori (ko, šta, do kada)
        Piši sažeto, u stavkama sa "- ". Vremenske oznake [HH:MM:SS] zadrži gdje pomažu.

        DIO TRANSKRIPTA:
        \"\"\"
        \(chunk)
        \"\"\"
        """
    }

    // MARK: - API

    public static func generate(
        transcript: String,
        audioPath: String,
        apiKey: String?,
        model: String = OpenRouterConfig.reportModelDefault,
        language: String? = nil,
        transcribeModel: String? = nil,
        durationSeconds: Double? = nil,
        progress: Progress? = nil,
        completion: @escaping (Swift.Result<Report, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                completion(.success(try generateSync(transcript: transcript, audioPath: audioPath, apiKey: apiKey,
                                                     model: model, language: language,
                                                     transcribeModel: transcribeModel,
                                                     durationSeconds: durationSeconds, progress: progress)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Blokira dok izvještaj nije gotov — zvati sa pozadinske niti (ili iz CLI-ja).
    public static func generateSync(
        transcript: String,
        audioPath: String,
        apiKey: String?,
        model: String = OpenRouterConfig.reportModelDefault,
        language: String? = nil,
        transcribeModel: String? = nil,
        durationSeconds: Double? = nil,
        progress: Progress? = nil
    ) throws -> Report {
        guard let key = OpenRouterConfig.resolveAPIKey(explicit: apiKey), !key.isEmpty else {
            throw OpenRouterError.missingAPIKey
        }
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ReportError.emptyTranscript }

        let l = labels(language: language)
        let words = clean.split(whereSeparator: { $0.isWhitespace }).count
        let started = Date()
        var modelUsed = model
        var chunkCount = 1
        DebugLog.log("izvještaj start: \(clean.count) znakova, \(words) riječi, model \(model)")

        // 1) Dug transkript → bilješke po dijelovima (dok ne stane u jedan prolaz).
        var material = clean
        var materialTitle = "TRANSKRIPT"
        var round = 0
        while material.count > singlePassChars && round < 3 {
            round += 1
            let chunks = splitText(material, maxChars: chunkChars)
            if round == 1 { chunkCount = chunks.count }
            DebugLog.log("izvještaj: krug \(round), \(chunks.count) dijelova za bilješke")
            progress?("bilješke", 0, chunks.count)
            let done = LockedBox(0)
            let system = systemPrompt(l)
            let notes: [String] = try Parallel.map(count: chunks.count, maxConcurrent: maxConcurrentChunks) { i in
                let (text, used) = try chat(system: system,
                                            user: notesPrompt(chunk: chunks[i], index: i + 1, total: chunks.count),
                                            preferredModel: model, apiKey: key, maxTokens: 2500)
                DebugLog.log("  bilješke \(i + 1)/\(chunks.count): \(text.count) znakova (\(used))")
                let n = done.withLock { (n: inout Int) -> Int in n += 1; return n }
                progress?("bilješke", n, chunks.count)
                return "### Dio \(i + 1)/\(chunks.count)\n\(text)"
            }
            material = notes.joined(separator: "\n\n")
            materialTitle = "BILJEŠKE PO DIJELOVIMA TRANSKRIPTA"
        }

        // 2) Završni izvještaj.
        progress?("sažetak", 0, 1)
        let (raw, used) = try chat(system: systemPrompt(l),
                                   user: finalPrompt(l, material: material, materialTitle: materialTitle, words: words),
                                   preferredModel: model, apiKey: key, maxTokens: 3000)
        modelUsed = used
        let summary = cleanSummary(raw, labels: l)
        guard !summary.isEmpty else { throw ReportError.emptyResponse(used) }
        progress?("sažetak", 1, 1)

        // 3) Fajl se sastavlja lokalno — transkript ulazi cijeli, bez prolaska kroz model.
        let markdown = assemble(labels: l, summary: summary, transcript: clean, audioPath: audioPath,
                                durationSeconds: durationSeconds, transcribeModel: transcribeModel,
                                reportModel: modelUsed)
        let reportPath = (audioPath as NSString).deletingPathExtension + ".izvjestaj.md"
        try markdown.write(toFile: reportPath, atomically: true, encoding: .utf8)

        let missing = [l.summary, l.keyPoints, l.actions].filter { section(named: $0, in: summary) == nil }
        DebugLog.log(String(format: "izvještaj gotov: %d znakova sažetka, model %@, dijelova %d, %.0f s%@",
                            summary.count, modelUsed, chunkCount, Date().timeIntervalSince(started),
                            missing.isEmpty ? "" : " — NEDOSTAJU sekcije: \(missing.joined(separator: ", "))"))
        return Report(markdown: markdown, summaryMarkdown: summary, reportPath: reportPath,
                      modelUsed: modelUsed, chunks: chunkCount)
    }

    // MARK: - Chat sa rezervnim modelima

    /// Proba izabrani model, pa ostale sa liste. Vraća (tekst, model koji je odgovorio).
    static func chat(system: String, user: String, preferredModel: String,
                     apiKey: String, maxTokens: Int) throws -> (String, String) {
        let candidates = [preferredModel] + OpenRouterConfig.cheapReportModels.filter { $0 != preferredModel }
        var lastError: Error = ReportError.emptyResponse(preferredModel)
        for model in candidates {
            do {
                let text = try chatOnce(system: system, user: user, model: model, apiKey: apiKey, maxTokens: maxTokens)
                return (text, model)
            } catch let e as OpenRouterError where e.isAuthOrBilling {
                throw e
            } catch {
                lastError = error
                DebugLog.log("  model \(model) nije uspio: \(error) — probam sljedeći")
            }
        }
        throw lastError
    }

    private static func chatOnce(system: String, user: String, model: String,
                                 apiKey: String, maxTokens: Int) throws -> String {
        var tokens = maxTokens
        var lastError: Error = ReportError.emptyResponse(model)
        for attempt in 1...2 {
            let body: [String: Any] = [
                "model": model,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user],
                ],
                "temperature": 0.2,
                "max_tokens": tokens,
            ]
            do {
                let json = try OpenRouterClient.postJSON(url: OpenRouterConfig.chatURL, body: body,
                                                         apiKey: apiKey, timeout: 240)
                guard let choice = (json["choices"] as? [[String: Any]])?.first else {
                    throw OpenRouterError.badResponse("nema 'choices' u odgovoru")
                }
                if let e = choice["error"] as? [String: Any] {
                    throw OpenRouterError.http((e["code"] as? Int) ?? 502, (e["message"] as? String) ?? "greška providera")
                }
                let content = ((choice["message"] as? [String: Any])?["content"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let finish = (choice["finish_reason"] as? String) ?? "?"
                if let usage = json["usage"] as? [String: Any] {
                    DebugLog.log("  chat \(model): finish=\(finish) tokeni in=\(usage["prompt_tokens"] ?? "?") out=\(usage["completion_tokens"] ?? "?")")
                }
                // Odsječen odgovor = nepotpun izvještaj. Probaj jednom sa duplo više mjesta.
                if finish == "length" && attempt == 1 {
                    tokens *= 2
                    continue
                }
                guard !content.isEmpty else { throw ReportError.emptyResponse(model) }
                return content
            } catch let e as OpenRouterError where e.isRetryable && attempt == 1 {
                lastError = e
                Thread.sleep(forTimeInterval: 3)
            }
        }
        throw lastError
    }

    // MARK: - Obrada teksta

    /// Dijeli tekst na komade ≤ maxChars, na granici pasusa/rečenice gdje može.
    static func splitText(_ text: String, maxChars: Int) -> [String] {
        guard text.count > maxChars else { return [text] }
        var chunks: [String] = []
        var rest = Substring(text)
        while rest.count > maxChars {
            let limit = rest.index(rest.startIndex, offsetBy: maxChars)
            let head = rest[..<limit]
            let floor = rest.index(rest.startIndex, offsetBy: maxChars / 2)
            var cut = limit
            if let r = head.range(of: "\n\n", options: .backwards), r.lowerBound > floor {
                cut = r.upperBound
            } else if let r = head.range(of: ". ", options: .backwards), r.lowerBound > floor {
                cut = r.upperBound
            } else if let r = head.range(of: " ", options: .backwards), r.lowerBound > floor {
                cut = r.upperBound
            }
            chunks.append(String(rest[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines))
            rest = rest[cut...]
        }
        let tail = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { chunks.append(tail) }
        return chunks
    }

    /// Modeli vole dodati ```markdown ogradu, naslov "# Izvještaj" ili uvodnu rečenicu — skini to.
    static func cleanSummary(_ raw: String, labels l: Labels) -> String {
        var lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        // Sve prije prve "## " sekcije je uvod koji nismo tražili.
        if let first = lines.firstIndex(where: { $0.hasPrefix("## ") }) {
            lines.removeFirst(first)
        } else {
            // Model nije poštovao format — sačuvaj tekst kao sažetak umjesto da ga bacimo.
            lines.removeAll { $0.hasPrefix("# ") }
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? "" : "## \(l.summary)\n\(body)"
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tekst sekcije "## <name>" (bez naslova), ili nil ako je nema.
    public static func section(named name: String, in markdown: String) -> String? {
        let lines = markdown.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: {
            $0.hasPrefix("## ") && $0.dropFirst(3).trimmingCharacters(in: .whitespaces)
                .lowercased().hasPrefix(name.lowercased())
        }) else { return nil }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex(where: { $0.hasPrefix("## ") || $0.hasPrefix("# ") }) ?? lines.endIndex
        let body = lines[(start + 1)..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    /// Sekcija "Sažetak" iz gotovog izvještaja — za prikaz u aplikaciji.
    public static func summarySection(in markdown: String) -> String? {
        section(named: "Sažetak", in: markdown) ?? section(named: "Summary", in: markdown)
    }

    static func assemble(labels l: Labels, summary: String, transcript: String, audioPath: String,
                         durationSeconds: Double?, transcribeModel: String?, reportModel: String) -> String {
        let name = (audioPath as NSString).lastPathComponent
        let created = ((try? FileManager.default.attributesOfItem(atPath: audioPath))?[.creationDate] as? Date) ?? Date()
        let df = DateFormatter()
        df.dateFormat = "dd.MM.yyyy HH:mm"

        var head = ["# \(l.title)", "", "- **\(l.recording):** \(name)", "- **\(l.date):** \(df.string(from: created))"]
        if let d = durationSeconds, d > 0 {
            head.append("- **\(l.duration):** \(humanDuration(d))")
        }
        let models = [transcribeModel, reportModel].compactMap { $0 }.joined(separator: " → ")
        head.append("- **\(l.models):** \(models)")

        return head.joined(separator: "\n")
            + "\n\n" + summary
            + "\n\n## \(l.transcript)\n\n" + transcript + "\n"
    }

    public static func humanDuration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min \(s % 60) s" }
        return "\(s / 3600) h \((s % 3600) / 60) min"
    }
}
