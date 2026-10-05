import Foundation
import AVFoundation

/// Transkripcija preko OpenRouter /audio/transcriptions.
/// Default model: microsoft/mai-transcribe-2.
///
/// API format (JSON, base64):
///   POST https://openrouter.ai/api/v1/audio/transcriptions
///   { "model": "microsoft/mai-transcribe-2",
///     "input_audio": { "data": "<base64>", "format": "wav" },
///     "language": "sr",            // opciono, ISO-639-1
///     "response_format": "json" }
///
/// Odgovor: { "text": "...", "usage": { "seconds": ..., "cost": ... } }
///
/// Snimanje više nema limit trajanja, pa je dug snimak pravilo, ne izuzetak:
///  - audio se svodi na 16 kHz mono 16-bit i dijeli na dijelove ≤160 s
///    (model odbija velike inpute; WAV radi, M4A provider odbija sa HTTP 400)
///  - rez je na najtišem mjestu pri kraju dijela, da ne presiječe riječ
///  - dijelovi idu paralelno (3 odjednom), svaki sa ponovnim pokušajem
///  - dio u kojem niko ne govori vraća prazan tekst — to NIJE greška
///    (ranije je jedan tihi dio obarao cijeli transkript)
///  - privremeni fajlovi idu u temp folder i brišu se (ranije su .16k.wav i
///    .partNN.wav ostajali pored snimka)
public enum TranscriptionService {

    public struct Result {
        public let text: String
        public let rawJSON: String
        public let audioPath: String
        public let transcriptPath: String
        public let durationSeconds: Double
        public let parts: Int
        /// Zbir `usage.cost` iz odgovora, ako ga provider vraća.
        public let costUSD: Double?
    }

    public enum TranscribeError: Error, CustomStringConvertible {
        case missingAPIKey
        case fileNotFound(String)
        case conversionFailed(String)
        case emptyTranscript

        public var description: String {
            switch self {
            case .missingAPIKey: return OpenRouterError.missingAPIKey.description
            case .fileNotFound(let p): return "Audio fajl ne postoji: \(p)"
            case .conversionFailed(let d): return "Priprema audija neuspješna: \(d)"
            case .emptyTranscript: return "U snimku nije prepoznat govor (prazan transkript)."
            }
        }
    }

    /// (završeno dijelova, ukupno dijelova)
    public typealias Progress = (_ done: Int, _ total: Int) -> Void

    /// Preko ovoga se prije transkripcije traži potvrda korisnika.
    public static let confirmThresholdSeconds: Double = 3600

    /// WAV do ove veličine ide direktno, bez konverzije (kratki klipovi).
    static let directUploadLimit: Int64 = 4 * 1024 * 1024
    /// 160 s na 16 kHz/16-bit = 5.1 MB. Provjereno radi; na ~8 min model odbija
    /// ("does not support large audio inputs").
    static let partSeconds: Double = 160
    static let uploadSampleRate: Double = 16000
    static let maxConcurrentUploads = 3
    /// Provider često vraća 429/502 (na testu 05.10.2026: 2 od 3 pokušaja za
    /// jedan kratak klip). Dug snimak ima 20+ dijelova i pada ako ijedan ne
    /// prođe, pa pokušaja mora biti dovoljno: čekanje 2, 4, 8, 16, 30 s.
    static let maxAttempts = 6

    // MARK: - Trajanje / potvrda

    public static func audioDuration(path: String) -> Double? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return nil }
        return Double(file.length) / rate
    }

    public static func needsConfirmation(seconds: Double) -> Bool {
        seconds > confirmThresholdSeconds
    }

    public static func estimatedCostUSD(seconds: Double) -> Double {
        seconds / 3600 * OpenRouterConfig.transcribeUSDPerHour
    }

    /// Gruba procjena trajanja obrade: ~15 s po grupi od 3 paralelna dijela
    /// (uz povremeni ponovni pokušaj) + ~90 s za izvještaj dugog transkripta.
    public static func estimatedProcessingSeconds(audioSeconds: Double) -> Double {
        let parts = max(1, (audioSeconds / partSeconds).rounded(.up))
        return (parts / Double(maxConcurrentUploads)).rounded(.up) * 15 + 90
    }

    // MARK: - API

    public static func transcribe(
        audioPath: String,
        apiKey: String?,
        model: String = OpenRouterConfig.transcribeModelDefault,
        language: String? = nil,
        progress: Progress? = nil,
        completion: @escaping (Swift.Result<Result, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                completion(.success(try transcribeSync(audioPath: audioPath, apiKey: apiKey, model: model,
                                                       language: language, progress: progress)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Blokira dok transkript nije gotov — zvati sa pozadinske niti (ili iz CLI-ja).
    public static func transcribeSync(
        audioPath: String,
        apiKey: String?,
        model: String = OpenRouterConfig.transcribeModelDefault,
        language: String? = nil,
        progress: Progress? = nil
    ) throws -> Result {
        guard let key = OpenRouterConfig.resolveAPIKey(explicit: apiKey), !key.isEmpty else {
            throw TranscribeError.missingAPIKey
        }
        guard FileManager.default.fileExists(atPath: audioPath) else {
            throw TranscribeError.fileNotFound(audioPath)
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CleanMic-transcribe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let started = Date()
        let duration = audioDuration(path: audioPath) ?? 0
        let parts = try prepareParts(audioPath: audioPath, workDir: workDir)
        DebugLog.log(String(format: "transkripcija start: %@ (%.0f s, %d dijelova, model %@, jezik %@)",
                            (audioPath as NSString).lastPathComponent, duration, parts.count, model, language ?? "auto"))
        progress?(0, parts.count)

        let lang = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let doneCount = LockedBox(0)
        let responses: [PartResponse] = try Parallel.map(count: parts.count, maxConcurrent: maxConcurrentUploads) { i in
            let r = try uploadWithRetry(part: parts[i], index: i, total: parts.count,
                                        apiKey: key, model: model, language: lang)
            let done = doneCount.withLock { (n: inout Int) -> Int in n += 1; return n }
            progress?(done, parts.count)
            return r
        }

        let text = joinTranscript(parts: zip(parts, responses).map { (start: $0.0.startSeconds, text: $0.1.text) })
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            DebugLog.log("transkripcija: svi dijelovi prazni")
            throw TranscribeError.emptyTranscript
        }

        let base = (audioPath as NSString).deletingPathExtension
        let txtPath = base + ".transcript.txt"
        let jsonPath = base + ".transcript.json"
        try text.write(toFile: txtPath, atomically: true, encoding: .utf8)
        try? ("[\n" + responses.map(\.raw).joined(separator: ",\n") + "\n]")
            .write(toFile: jsonPath, atomically: true, encoding: .utf8)

        let costs = responses.compactMap(\.costUSD)
        let cost = costs.isEmpty ? nil : costs.reduce(0, +)
        DebugLog.log(String(format: "transkripcija gotova: %d znakova, %d/%d dijelova sa govorom, %.0f s obrade, trošak %@",
                            text.count, responses.filter { !$0.text.isEmpty }.count, parts.count,
                            Date().timeIntervalSince(started), cost.map { String(format: "$%.4f", $0) } ?? "n/a"))
        return Result(text: text, rawJSON: jsonPath, audioPath: audioPath, transcriptPath: txtPath,
                      durationSeconds: duration, parts: parts.count, costUSD: cost)
    }

    // MARK: - Priprema fajlova

    struct Part {
        let path: String
        let startSeconds: Double
    }

    /// Kratak WAV ide direktno; sve ostalo → 16 kHz mono → dijelovi ≤ `partSeconds`.
    static func prepareParts(audioPath: String, workDir: URL) throws -> [Part] {
        let isWAV = (audioPath as NSString).pathExtension.lowercased() == "wav"
        if isWAV && fileSize(audioPath) <= directUploadLimit {
            return [Part(path: audioPath, startSeconds: 0)]
        }
        let dsPath = workDir.appendingPathComponent("full16k.wav").path
        try runAfconvert(src: audioPath, dst: dsPath)
        return try splitAtQuietPoints(src: dsPath, workDir: workDir)
    }

    static func fileSize(_ path: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Bilo koji audio → 16 kHz mono 16-bit WAV (1 h: 346 MB → 115 MB).
    static func runAfconvert(src: String, dst: String) throws {
        try? FileManager.default.removeItem(atPath: dst)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", src, dst]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            throw TranscribeError.conversionFailed("afconvert se ne može pokrenuti: \(error.localizedDescription)")
        }
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: dst) else {
            let detail = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw TranscribeError.conversionFailed("afconvert exit=\(p.terminationStatus) \(detail.prefix(200))")
        }
    }

    /// Dijeli 16 kHz WAV na dijelove ≤ `partSeconds`, režući na najtišem mjestu
    /// u zadnjih 8 s svakog dijela.
    static func splitAtQuietPoints(src: String, workDir: URL,
                                   partSeconds: Double = TranscriptionService.partSeconds) throws -> [Part] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: URL(fileURLWithPath: src))
        } catch {
            throw TranscribeError.conversionFailed("ne mogu otvoriti \(src): \(error.localizedDescription)")
        }
        let rate = file.processingFormat.sampleRate
        let total = Int(file.length)
        let maxFrames = Int(partSeconds * rate)
        guard total > 0, maxFrames > 0 else { throw TranscribeError.conversionFailed("prazan audio") }
        if total <= maxFrames { return [Part(path: src, startSeconds: 0)] }

        var out: [Part] = []
        var pos = 0
        while pos < total {
            let remaining = total - pos
            // Rep kraći od 1 s nema smisla slati zasebno — pripoji ga ovom dijelu.
            let isLast = remaining <= maxFrames + Int(rate)
            let n = isLast ? remaining : maxFrames
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(n)) else {
                throw TranscribeError.conversionFailed("nema memorije za dio \(out.count + 1)")
            }
            file.framePosition = AVAudioFramePosition(pos)
            try file.read(into: buf, frameCount: AVAudioFrameCount(n))
            let got = Int(buf.frameLength)
            if got == 0 { break }

            var cut = got
            if !isLast, let data = buf.floatChannelData?[0] {
                cut = quietestCut(samples: data, count: got, rate: rate)
            }
            buf.frameLength = AVAudioFrameCount(cut)

            let partPath = workDir.appendingPathComponent(String(format: "part%03d.wav", out.count + 1)).path
            // Scope zatvara AVAudioFile (i upisuje header) prije uploada.
            do {
                let outFile = try AVAudioFile(forWriting: URL(fileURLWithPath: partPath),
                                              settings: file.fileFormat.settings)
                try outFile.write(from: buf)
            }
            out.append(Part(path: partPath, startSeconds: Double(pos) / rate))
            pos += cut
        }
        guard !out.isEmpty else { throw TranscribeError.conversionFailed("prazan split") }
        return out
    }

    /// Indeks (u uzorcima) sredine najtišeg prozora od 200 ms u zadnjih 8 s.
    static func quietestCut(samples: UnsafePointer<Float>, count: Int, rate: Double) -> Int {
        let window = max(1, Int(0.2 * rate))
        let hop = max(1, Int(0.05 * rate))
        let searchStart = max(count / 2, count - Int(8 * rate))
        guard searchStart + window < count else { return count }
        var best = count
        var bestEnergy = Float.greatestFiniteMagnitude
        var start = searchStart
        while start + window <= count {
            var e: Float = 0
            for i in start..<(start + window) { e += samples[i] * samples[i] }
            // <= : među jednako tihim mjestima uzmi kasnije, da dio bude što duži.
            if e <= bestEnergy {
                bestEnergy = e
                best = start + window / 2
            }
            start += hop
        }
        return best
    }

    /// Više dijelova → pasus po dijelu sa vremenskom oznakom, da se u dugom
    /// transkriptu zna gdje je šta rečeno.
    static func joinTranscript(parts: [(start: Double, text: String)]) -> String {
        let spoken = parts
            .map { (start: $0.start, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.text.isEmpty }
        if parts.count <= 1 { return spoken.first?.text ?? "" }
        return spoken.map { "[\(timestamp($0.start))] \($0.text)" }.joined(separator: "\n\n")
    }

    static func timestamp(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    // MARK: - Upload

    struct PartResponse {
        let text: String
        let raw: String
        let costUSD: Double?
    }

    private static func uploadWithRetry(part: Part, index: Int, total: Int, apiKey: String,
                                        model: String, language: String?) throws -> PartResponse {
        var lastError: Error = TranscribeError.emptyTranscript
        for attempt in 1...maxAttempts {
            let t0 = Date()
            do {
                let r = try uploadOne(path: part.path, apiKey: apiKey, model: model, language: language)
                DebugLog.log(String(format: "  dio %d/%d ok: %d znakova, %.1f s%@", index + 1, total, r.text.count,
                                    Date().timeIntervalSince(t0), attempt > 1 ? " (pokušaj \(attempt))" : ""))
                return r
            } catch let e as OpenRouterError where e.isRetryable && attempt < maxAttempts {
                lastError = e
                DebugLog.log("  dio \(index + 1)/\(total) pokušaj \(attempt) neuspješan: \(e) — ponavljam")
                Thread.sleep(forTimeInterval: min(30, pow(2, Double(attempt))))
            } catch {
                DebugLog.log("  dio \(index + 1)/\(total) greška: \(error)")
                throw error
            }
        }
        throw lastError
    }

    private static func uploadOne(path: String, apiKey: String, model: String, language: String?) throws -> PartResponse {
        guard let audio = try? Data(contentsOf: URL(fileURLWithPath: path)), !audio.isEmpty else {
            throw TranscribeError.fileNotFound(path)
        }
        var body: [String: Any] = [
            "model": model,
            "input_audio": ["data": audio.base64EncodedString(), "format": "wav"],
            "response_format": "json",
        ]
        if let language, !language.isEmpty, language != "auto" {
            body["language"] = language
        }
        let json = try OpenRouterClient.postJSON(url: OpenRouterConfig.transcriptionURL, body: body,
                                                 apiKey: apiKey, timeout: 300)
        let text = (json["text"] as? String) ?? ""
        let cost = ((json["usage"] as? [String: Any])?["cost"] as? NSNumber)?.doubleValue
        let raw = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return PartResponse(text: text, raw: raw, costUSD: cost)
    }
}
