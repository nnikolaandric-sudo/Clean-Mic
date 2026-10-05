import AVFoundation
import Foundation

/// Offline provjere (bez mikrofona, bez mreže, bez ključa): `cleanmic-cli selftest`.
/// Namijenjeno za brzu potvrdu na novom Macu da build radi kako treba.
public enum SelfTest {
    public struct Check {
        public let name: String
        public let passed: Bool
        public let detail: String
    }

    public static func runAll() -> [Check] {
        var checks: [Check] = []
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CleanMic-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func check(_ name: String, _ body: () throws -> (Bool, String)) {
            do {
                let (ok, detail) = try body()
                checks.append(Check(name: name, passed: ok, detail: detail))
            } catch {
                checks.append(Check(name: name, passed: false, detail: "greška: \(error)"))
            }
        }

        check("WAV writer: 3 s → ispravan 16-bit fajl") {
            let url = dir.appendingPathComponent("w.wav")
            let w = try StreamingWAVWriter(url: url)
            for block in 0..<300 { try w.write(sine(frames: 480, rate: 48000, offset: block * 480)) }
            w.close()
            let f = try AVAudioFile(forReading: url)
            let size = TranscriptionService.fileSize(url.path)
            let ok = f.length == 144_000 && f.fileFormat.sampleRate == 48000
                && f.fileFormat.channelCount == 1 && size == 44 + 288_000
            return (ok, "frames=\(f.length) rate=\(Int(f.fileFormat.sampleRate)) bytes=\(size)")
        }

        check("WAV writer: header važi i bez zatvaranja (pad aplikacije)") {
            let url = dir.appendingPathComponent("crash.wav")
            let w = try StreamingWAVWriter(url: url)
            for block in 0..<1200 { try w.write(sine(frames: 480, rate: 48000, offset: block * 480)) }
            try w.flush()
            // Namjerno bez close(): čitamo fajl kakav bi ostao na disku.
            let f = try AVAudioFile(forReading: url)
            let seconds = Double(f.length) / 48000
            w.close()
            return (seconds >= 6, String(format: "čitljivo %.1f s od 12 s bez close()", seconds))
        }

        check("Dijeljenje dugog audija: rez pada u tišinu, ništa se ne gubi") {
            // 50 s na 16 kHz: 4 s tona, 1 s tišine, ponavljano.
            let rate = 16000.0
            let src = dir.appendingPathComponent("long16k.wav")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            ]
            let total = Int(50 * rate)
            do {
                let out = try AVAudioFile(forWriting: src, settings: settings)
                let buf = AVAudioPCMBuffer(pcmFormat: out.processingFormat, frameCapacity: AVAudioFrameCount(total))!
                buf.frameLength = AVAudioFrameCount(total)
                let p = buf.floatChannelData![0]
                for i in 0..<total {
                    let inCycle = Double(i).truncatingRemainder(dividingBy: 5 * rate)
                    p[i] = inCycle < 4 * rate ? 0.3 * Float(sin(2 * Double.pi * 220 * Double(i) / rate)) : 0
                }
                try out.write(from: buf)
            }
            let parts = try TranscriptionService.splitAtQuietPoints(src: src.path, workDir: dir, partSeconds: 20)
            var frames = 0
            var maxPart = 0.0
            var cutsInSilence = true
            for (i, part) in parts.enumerated() {
                let f = try AVAudioFile(forReading: URL(fileURLWithPath: part.path))
                let n = Int(f.length)
                frames += n
                maxPart = max(maxPart, Double(n) / rate)
                if i < parts.count - 1 {
                    // Zadnjih 50 ms dijela mora biti tišina.
                    let tail = 800
                    let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(tail))!
                    f.framePosition = AVAudioFramePosition(n - tail)
                    try f.read(into: buf, frameCount: AVAudioFrameCount(tail))
                    let p = buf.floatChannelData![0]
                    var peak: Float = 0
                    for j in 0..<Int(buf.frameLength) { peak = max(peak, abs(p[j])) }
                    if peak > 0.01 { cutsInSilence = false }
                }
            }
            // Zadnji dio smije biti do 1 s duži (rep se pripaja umjesto da ide zasebno).
            let ok = parts.count == 3 && frames == total && maxPart <= 21.0 && cutsInSilence
            return (ok, "dijelova=\(parts.count) uzoraka=\(frames)/\(total) najduži=\(String(format: "%.1f", maxPart)) s rezovi u tišini=\(cutsInSilence)")
        }

        check("Transkript: tihi dio ne obara cijeli transkript") {
            let t = TranscriptionService.joinTranscript(parts: [
                (start: 0, text: "Prvi dio."), (start: 160, text: "   "), (start: 320, text: "Treći dio."),
            ])
            let ok = t == "[00:00:00] Prvi dio.\n\n[00:05:20] Treći dio."
            return (ok, t.replacingOccurrences(of: "\n", with: "⏎"))
        }

        check("Potvrda transkripcije samo preko 1 h") {
            let ok = !TranscriptionService.needsConfirmation(seconds: 3600)
                && TranscriptionService.needsConfirmation(seconds: 3601)
                && !TranscriptionService.needsConfirmation(seconds: 600)
            return (ok, "prag \(Int(TranscriptionService.confirmThresholdSeconds)) s")
        }

        check("Izvještaj: dug tekst se dijeli bez gubitka riječi") {
            let sentence = "Ovo je rečenica broj jedan o sastanku. "
            let text = String(repeating: sentence, count: 3000)   // ~117k znakova
            let chunks = ReportService.splitText(text, maxChars: ReportService.chunkChars)
            let wordsIn = text.split(separator: " ").count
            let wordsOut = chunks.reduce(0) { $0 + $1.split(separator: " ").count }
            let ok = chunks.count >= 4 && chunks.allSatisfy { $0.count <= ReportService.chunkChars } && wordsIn == wordsOut
            return (ok, "komada=\(chunks.count) riječi \(wordsOut)/\(wordsIn)")
        }

        check("Izvještaj: čišćenje odgovora modela (```ograda, uvod)") {
            let l = ReportService.labels(language: "sr")
            let raw = "Evo izvještaja:\n```markdown\n# Izvještaj\n## Sažetak\nTekst.\n\n## Ključne tačke\n- A\n```"
            let cleaned = ReportService.cleanSummary(raw, labels: l)
            let noHeadings = ReportService.cleanSummary("Samo običan tekst bez naslova.", labels: l)
            let ok = cleaned.hasPrefix("## Sažetak") && !cleaned.contains("```") && !cleaned.contains("Evo izvještaja")
                && noHeadings.hasPrefix("## Sažetak\nSamo običan")
            return (ok, cleaned.replacingOccurrences(of: "\n", with: "⏎"))
        }

        check("Izvještaj: sažetak prvi, transkript cijeli na kraju") {
            let l = ReportService.labels(language: "sr")
            let transcript = String(repeating: "Riječ ", count: 5000) + "KRAJ_TRANSKRIPTA"
            let summary = "## Sažetak\nKratko.\n\n## Ključne tačke\n- Jedna\n\n## Akcije / sljedeći koraci\n- Nema eksplicitnih akcija."
            let md = ReportService.assemble(labels: l, summary: summary, transcript: transcript,
                                            audioPath: "/tmp/CleanMic_test.wav", durationSeconds: 4000,
                                            transcribeModel: "t-model", reportModel: "r-model")
            let iSummary = md.range(of: "## Sažetak")?.lowerBound
            let iTranscript = md.range(of: "## Transkript")?.lowerBound
            let ok = md.hasSuffix("KRAJ_TRANSKRIPTA\n") && iSummary != nil && iTranscript != nil && iSummary! < iTranscript!
                && md.contains("1 h 6 min") && ReportService.summarySection(in: md) == "Kratko."
                && ReportService.section(named: "Akcije", in: md) != nil
            return (ok, "\(md.count) znakova, sažetak='\(ReportService.summarySection(in: md) ?? "nil")'")
        }

        check("Izvještaj: jezik prati izbor (en → engleski naslovi)") {
            let en = ReportService.labels(language: "en")
            let auto = ReportService.labels(language: nil)
            return (en.summary == "Summary" && auto.summary == "Sažetak", "en=\(en.summary) auto=\(auto.summary)")
        }

        check("Modeli: ukinuti model se vraća na default") {
            let m = OpenRouterConfig.normalizedReportModel("google/gemini-flash-1.5-8b")
            let keep = OpenRouterConfig.normalizedReportModel("openai/gpt-4o-mini")
            return (m == OpenRouterConfig.reportModelDefault && keep == "openai/gpt-4o-mini", "\(m), \(keep)")
        }

        check("OpenRouter greške: čitljiva poruka") {
            let data = #"{"error":{"code":402,"message":"Insufficient credits","metadata":{"raw":"top up"}}}"#.data(using: .utf8)
            let msg = OpenRouterClient.errorMessage(from: data)
            let friendly = OpenRouterError.http(402, msg).description
            return (msg == "Insufficient credits — top up" && friendly.contains("kredita"), msg)
        }

        check("RNNoise: obrada framea radi") {
            let proc = NoiseProcessor(mode: .balanced)
            let (out, vad) = proc.process(input: sine(frames: 480, rate: 48000, offset: 0))
            return (out.count == 480 && vad >= 0 && vad <= 1 && !out.contains(where: { $0.isNaN }), String(format: "vad=%.2f", vad))
        }

        return checks
    }

    private static func sine(frames: Int, rate: Double, offset: Int) -> [Float] {
        (0..<frames).map { 0.25 * Float(sin(2 * Double.pi * 440 * Double($0 + offset) / rate)) }
    }
}
