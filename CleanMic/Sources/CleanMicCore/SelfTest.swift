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

        check("Modeli: default GPT-6 Luna, ukinuti → default, ručni ID ostaje") {
            let removed = OpenRouterConfig.normalizedReportModel("google/gemini-flash-1.5-8b")
            let custom = OpenRouterConfig.normalizedReportModel("  neki/novi-model ")
            let empty = OpenRouterConfig.normalizedReportModel("")
            let ok = OpenRouterConfig.reportModelDefault == "openai/gpt-6-luna"
                && OpenRouterConfig.transcribeModelDefault == "microsoft/mai-transcribe-2"
                && removed == OpenRouterConfig.reportModelDefault && empty == OpenRouterConfig.reportModelDefault
                && custom == "neki/novi-model"
                && OpenRouterConfig.reportModelOptions.first?.id == OpenRouterConfig.reportModelDefault
                && !OpenRouterConfig.fallbackReportModels.contains("openai/gpt-6-sol")
            return (ok, "default=\(OpenRouterConfig.reportModelDefault) ukinut→\(removed) ručni→\(custom)")
        }

        check("Izvještaj: prazan red između sekcija i kad ga model izostavi") {
            let l = ReportService.labels(language: "sr")
            let cleaned = ReportService.cleanSummary("## Sažetak\nTekst.\n## Ključne tačke\n- A\n## Akcije / sljedeći koraci\n- B", labels: l)
            return (cleaned == "## Sažetak\nTekst.\n\n## Ključne tačke\n- A\n\n## Akcije / sljedeći koraci\n- B",
                    cleaned.replacingOccurrences(of: "\n", with: "⏎"))
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

        check("Zvuk iz računara: miješa se uz mikrofon, bez rupa, skokova i kašnjenja") {
            // Mikrofon šuti, iz računara teče ton 1 kHz (amplituda 0.1), oba u realnom vremenu
            // iz dvije niti sa različitim taktom (mikrofon 480 / računar 512 frameova).
            let micRing = RingBuffer(capacityFrames: 131_072)
            let outRing = RingBuffer(capacityFrames: 131_072)
            let sysRing = RingBuffer(capacityFrames: 65_536)
            let engine = ProcessingEngine(inputRing: micRing, outputRing: outRing, mode: .light)
            engine.systemRing = sysRing
            engine.start()

            let seconds = 3.0
            let micChunks = Int(seconds * 48000) / 480
            let sysChunks = Int(seconds * 48000) / 512
            let silence = [Float](repeating: 0, count: 480)
            let micThread = Thread {
                for _ in 0..<micChunks { micRing.write(silence); Thread.sleep(forTimeInterval: 0.01) }
            }
            let sysThread = Thread {
                var phase = 0
                for _ in 0..<sysChunks {
                    let chunk = (0..<512).map { Float(0.1 * sin(2 * Double.pi * 1000 * Double($0 + phase) / 48000)) }
                    sysRing.write(chunk)
                    phase += 512
                    Thread.sleep(forTimeInterval: 512.0 / 48000.0)
                }
            }
            micThread.start(); sysThread.start()
            Thread.sleep(forTimeInterval: seconds + 0.4)
            engine.stop()

            var out = [Float](repeating: 0, count: outRing.availableRead)
            _ = outRing.read(into: &out, frames: out.count)
            // Preskoči prvih 0.5 s (priming) i zadnjih 0.1 s (kraj struje).
            let body = Array(out.dropFirst(24_000).dropLast(4_800))
            guard body.count > 48_000 else { return (false, "izlaz prekratak: \(out.count)") }
            let rms = (body.reduce(0) { $0 + $1 * $1 } / Float(body.count)).squareRoot()
            let peak = body.map(abs).max() ?? 0
            var longestGap = 0, gap = 0
            for v in body { if abs(v) < 1e-5 { gap += 1; longestGap = max(longestGap, gap) } else { gap = 0 } }
            var maxJump: Float = 0
            for i in 1..<body.count where abs(body[i]) > 1e-5 && abs(body[i - 1]) > 1e-5 {
                maxJump = max(maxJump, abs(body[i] - body[i - 1]))
            }
            let idealJump: Float = 0.1 * 2 * .pi * 1000 / 48000
            // Rupe (ponestalo zvuka) i skokovi (odbacivanje viška) smiju biti rijetki, ne stalni.
            let gapsOK = longestGap < 4_800
            let ok = abs(rms - 0.0707) < 0.012 && peak < 0.11 && gapsOK && maxJump < idealJump * 1.1
            return (ok, String(format: "rms=%.4f (0.0707) vrh=%.3f najduža rupa=%d fr skok=%.4f (%.4f)",
                               rms, peak, longestGap, maxJump, idealJump))
        }

        check("Zvuk iz računara: zbroj se ograničava na ±1, nema prelijevanja") {
            var frame: [Float] = [0.9, -0.9, 0.2]
            ProcessingEngine.mix(&frame, with: [0.9, -0.9, 0.3])
            return (frame == [1, -1, 0.5], "\(frame)")
        }

        check("Izlaz: slušalice → snima se zvuk iz računara, zvučnici → ne (auto)") {
            // Samo logika odluke; uređaje ne diramo.
            let headset = OutputRoute(deviceID: 1, uid: "a", name: "AirPods", isHeadphones: true)
            let speakers = OutputRoute(deviceID: 2, uid: "b", name: "MacBook zvučnici", isHeadphones: false)
            let a = SystemAudioCapture.wants(mode: .auto, route: headset)
            let b = SystemAudioCapture.wants(mode: .auto, route: speakers)
            let c = SystemAudioCapture.wants(mode: .always, route: speakers)
            let d = SystemAudioCapture.wants(mode: .never, route: headset)
            let e = SystemAudioCapture.wants(mode: .always, route: nil)
            return (a && !b && c && !d && !e, "auto/slušalice=\(a) auto/zvučnici=\(b) uvijek/zvučnici=\(c) nikad=\(d) uvijek/bez izlaza=\(e)")
        }

        check("Ažuriranje: poređenje verzija (1.10.0 > 1.9.0, v-prefiks, kraća oznaka)") {
            let a = UpdateChecker.isNewer("1.10.0", than: "1.9.0")
            let b = UpdateChecker.isNewer("v1.3.0", than: "1.2.0")
            let c = !UpdateChecker.isNewer("1.3", than: "1.3.0")
            let d = !UpdateChecker.isNewer("1.2.0", than: "1.3.0")
            let e = !UpdateChecker.isNewer("1.3.0", than: "1.3.0")
            let f = UpdateChecker.isNewer("1.3.1", than: "1.3.0-beta")
            let g = !UpdateChecker.isNewer("smeće", than: "1.3.0")
            return (a && b && c && d && e && f && g, "\(a) \(b) \(c) \(d) \(e) \(f) \(g)")
        }

        check("Ažuriranje: izdanje sa GitHuba se čita, tuđi linkovi se odbacuju") {
            let good: [String: Any] = [
                "tag_name": "v1.4.0", "body": "Bilješke",
                "html_url": "https://github.com/nnikolaandric-sudo/Clean-Mic/releases/tag/v1.4.0",
                "assets": [
                    ["name": "SHA256.txt", "browser_download_url": "https://github.com/x/SHA256.txt"],
                    ["name": "CleanMic-1.4.0.dmg", "browser_download_url": "https://github.com/nnikolaandric-sudo/Clean-Mic/releases/download/v1.4.0/CleanMic-1.4.0.dmg"],
                ],
            ]
            let evil: [String: Any] = [
                "tag_name": "v9.9.9", "html_url": "https://evil.example.com/release",
                "assets": [],
            ]
            let evilAsset: [String: Any] = [
                "tag_name": "v9.9.9", "html_url": "https://github.com/a/b/releases/tag/v9.9.9",
                "assets": [["name": "x.dmg", "browser_download_url": "http://github.com.evil.example/x.dmg"]],
            ]
            let info = UpdateChecker.parse(good)
            let ok = info?.version == "1.4.0" && info?.downloadURL?.lastPathComponent == "CleanMic-1.4.0.dmg"
                && UpdateChecker.parse(evil) == nil && UpdateChecker.parse(evilAsset)?.downloadURL == nil
            return (ok, "verzija=\(info?.version ?? "-") dmg=\(info?.downloadURL?.lastPathComponent ?? "-")")
        }

        return checks
    }

    private static func sine(frames: Int, rate: Double, offset: Int) -> [Float] {
        (0..<frames).map { 0.25 * Float(sin(2 * Double.pi * 440 * Double($0 + offset) / rate)) }
    }
}
