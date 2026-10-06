import Foundation
import AVFoundation

func printUsage() {
    print("""
    CleanMic CLI — snimanje (RNNoise) + transkripcija + izvještaj (OpenRouter)

    KORIŠTENJE:
      cleanmic-cli list                          — lista input uređaja
      cleanmic-cli record-processed [trajanje] [out.wav] [--mode light|balanced|maximum]
                            [--device ID] [--system-audio auto|always|never] [--transcribe]
                                                 — mic -> RNNoise -> WAV. Bez trajanja snima
                                                   dok ne pritisneš Enter ili Ctrl+C.
                                                   Uz slušalice (auto) snima i zvuk iz računara,
                                                   da online sastanak ne ostane bez ostalih učesnika.
      cleanmic-cli record-system [trajanje] [out.wav]
                                                 — samo zvuk iz računara (bez mikrofona), za provjeru
                                                   da snimanje zvuka sistema radi i da je dozvola data
      cleanmic-cli record [trajanje] [out.wav] [--transcribe]
                                                 — isto, ali sirov mikrofon (bez RNNoise)
      cleanmic-cli process <in.wav> <out.wav> [--mode MODE]
                                                 — offline WAV -> WAV kroz NoiseProcessor
      cleanmic-cli transcribe <audio> [--language sr|hr|bs|en] [--report-model MODEL]
                            [--no-report] [--yes]
                                                 — audio -> transkript + izvještaj
      cleanmic-cli report <transkript.txt> [--audio snimak.wav] [--language sr]
                                                 — samo izvještaj iz postojećeg transkripta
                                                   (ne naplaćuje transkripciju ponovo)
      cleanmic-cli set-key <OPENROUTER_API_KEY>  — sačuvaj ključ u ~/.config/cleanmic/openrouter_key
      cleanmic-cli check-key                     — provjeri da li ključ radi
      cleanmic-cli models [tekst]                — modeli za izvještaj (ponuđeni, ili pretraga
                                                   svih na OpenRouteru: cleanmic-cli models luna)
      cleanmic-cli check-update [--current X.Y.Z] — da li na GitHubu postoji novija verzija
      cleanmic-cli selftest                      — offline provjere (bez mikrofona i mreže)
      cleanmic-cli test-rings                    — stress test RingBuffer
      cleanmic-cli help

    FLAGOVI:
      --transcribe              nakon snimanja pošalji na OpenRouter
      --language sr             hint za jezik (sr, hr, bs, en; default auto)
      --transcribe-model MODEL  default: \(OpenRouterConfig.transcribeModelDefault)
      --report-model MODEL      default: \(OpenRouterConfig.reportModelDefault)
                                ili bilo koji OpenRouter ID — vidi: cleanmic-cli models
      --no-report               samo transkript, bez izvještaja
      --yes, -y                 bez pitanja potvrdi transkripciju snimka dužeg od 1 h
      --api-key KEY             eksplicitni ključ (inače OPENROUTER_API_KEY env / config fajl)
      --verbose, -v             detaljan ispis (isti kao ~/Library/Logs/CleanMic/cleanmic.log)

    TRAJANJE: 10 | 90s | 5min | 30m | 2h — ili izostavi i snima dok ga ne zaustaviš.
    SNIMAK DUŽI OD 1 h: prije transkripcije se traži potvrda (trošak i trajanje obrade).

    PRIMJERI:
      cleanmic-cli record-processed sastanak.wav --transcribe --language sr
      cleanmic-cli record-processed 15 /tmp/clean.wav --mode balanced
      cleanmic-cli transcribe sastanak.wav --language sr
      cleanmic-cli report sastanak.transcript.txt --language sr

    IZLAZNI FAJLOVI (pored snimka):
      <ime>.transcript.txt   — transkript (dugi snimci: pasusi sa [HH:MM:SS])
      <ime>.transcript.json  — sirovi OpenRouter odgovori (usage/cost)
      <ime>.izvjestaj.md     — Sažetak + Ključne tačke + Akcije + puni transkript
    """)
}

let args = CommandLine.arguments.dropFirst().map { $0 }

if args.isEmpty || args.first == "help" || args.first == "--help" || args.first == "-h" {
    printUsage()
    exit(0)
}

/// Flagovi koji uzimaju vrijednost — da ih pozicioni argumenti preskoče.
let valueFlags: Set<String> = ["--mode", "-m", "--language", "--lang", "-l", "--transcribe-model", "--model",
                               "--report-model", "--api-key", "--audio", "--device", "--system-audio", "--current"]

func flagValue(_ names: [String]) -> String? {
    for n in names {
        if let idx = args.firstIndex(of: n), args.count > idx + 1 {
            return args[idx + 1]
        }
        // --key=value oblik
        for a in args {
            if a.hasPrefix(n + "=") {
                return String(a.dropFirst((n + "=").count))
            }
        }
    }
    return nil
}

func hasFlag(_ names: [String]) -> Bool {
    for n in names {
        if args.contains(n) { return true }
    }
    return false
}

/// Argumenti poslije komande koji nisu flagovi ni njihove vrijednosti.
func positionals() -> [String] {
    var out: [String] = []
    var skip = false
    for a in args.dropFirst() {
        if skip { skip = false; continue }
        if a.hasPrefix("-") {
            if valueFlags.contains(a) { skip = true }
            continue
        }
        out.append(a)
    }
    return out
}

/// [trajanje] [out.wav] u bilo kom redoslijedu; bez trajanja = dok se ne zaustavi.
func recordArgs(defaultPrefix: String) -> (seconds: Double?, path: String) {
    var seconds: Double?
    var path: String?
    for p in positionals() {
        if seconds == nil, let s = parseDuration(p) { seconds = s } else if path == nil { path = p }
    }
    return (seconds, path ?? "/tmp/\(defaultPrefix)_\(Int(Date().timeIntervalSince1970)).wav")
}

DebugLog.echoToStdout = hasFlag(["--verbose", "-v"])

switch args.first! {
case "list":
    runList()
case "set-key":
    guard args.count >= 2 else {
        print("❌ set-key zahtijeva ključ: cleanmic-cli set-key sk-or-v1-...")
        exit(1)
    }
    OpenRouterConfig.saveAPIKey(args[1])
    print("✅ Ključ sačuvan (~/.config/cleanmic/openrouter_key, chmod 600) + UserDefaults")
    print("   Hint: \(OpenRouterConfig.storedKeyHint)")
case "check-key":
    runCheckKey()
case "models":
    runModels(filter: positionals().first)
case "record":
    let r = recordArgs(defaultPrefix: "cleanmic_raw")
    runRecordRaw(seconds: r.seconds, outputPath: r.path)
    if hasFlag(["--transcribe"]) { runTranscribeFlow(audioPath: r.path, opts: transcribeOptsFromArgs()) }
case "record-processed":
    let r = recordArgs(defaultPrefix: "cleanmic_processed")
    let mode = flagValue(["--mode", "-m"]).map(parseMode) ?? .balanced
    let device = flagValue(["--device"]).flatMap { UInt32($0) }
    let systemAudio = flagValue(["--system-audio"]).flatMap { SystemAudioMode(rawValue: $0) } ?? .auto
    runRecordProcessed(seconds: r.seconds, outputPath: r.path, mode: mode, deviceID: device, systemAudio: systemAudio)
    if hasFlag(["--transcribe"]) { runTranscribeFlow(audioPath: r.path, opts: transcribeOptsFromArgs()) }
case "record-system":
    let r = recordArgs(defaultPrefix: "cleanmic_system")
    runRecordSystem(seconds: r.seconds, outputPath: r.path)
case "process":
    let p = positionals()
    guard p.count >= 2 else {
        print("❌ process zahtijeva <in.wav> <out.wav>")
        printUsage()
        exit(1)
    }
    runOfflineProcess(inPath: p[0], outPath: p[1], mode: flagValue(["--mode", "-m"]).map(parseMode) ?? .balanced)
case "transcribe":
    guard let audio = positionals().first else {
        print("❌ transcribe zahtijeva <audio fajl>")
        printUsage()
        exit(1)
    }
    runTranscribeFlow(audioPath: audio, opts: transcribeOptsFromArgs())
case "report":
    guard let txt = positionals().first else {
        print("❌ report zahtijeva <transkript.txt>")
        printUsage()
        exit(1)
    }
    runReportOnly(transcriptPath: txt, opts: transcribeOptsFromArgs())
case "check-update":
    let current = flagValue(["--current"]) ?? AppVersion.current
    do {
        guard let latest = try UpdateChecker.latest() else {
            print("Na GitHubu još nema izdanja.")
            exit(0)
        }
        print("Najnovije izdanje: \(latest.version)  (\(latest.pageURL.absoluteString))")
        if let dmg = latest.downloadURL { print("DMG: \(dmg.absoluteString)") }
        if UpdateChecker.isNewer(latest.version, than: current) {
            print("⬆️  Novije od \(current).")
        } else {
            print("✅ \(current) je najnovija verzija.")
        }
    } catch {
        print("❌ \(error)")
        exit(1)
    }
case "selftest":
    runSelfTest()
case "test-rings":
    runRingTest()
default:
    print("❌ Nepoznata komanda: \(args.first!)")
    printUsage()
    exit(1)
}
DebugLog.flush()

// MARK: - Stop / stdin

/// Jedan čitač stdin-a za cijeli proces: i "Enter zaustavlja snimanje" i
/// "Nastaviti? [d/N]" čitaju iz istog reda, da se ne otimaju za isti unos.
final class StdinLines: @unchecked Sendable {
    static let shared = StdinLines()
    private let lock = NSLock()
    private var lines: [String] = []
    private var started = false
    private var eof = false

    private func startIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        let t = Thread { [self] in
            while let line = readLine() {
                lock.lock(); lines.append(line); lock.unlock()
            }
            lock.lock(); eof = true; lock.unlock()
        }
        t.start()
    }

    /// Linija ako je stigla, bez čekanja.
    func poll() -> String? {
        startIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return lines.isEmpty ? nil : lines.removeFirst()
    }

    /// Čeka liniju; nil na EOF.
    func next() -> String? {
        startIfNeeded()
        while true {
            lock.lock()
            if !lines.isEmpty { let l = lines.removeFirst(); lock.unlock(); return l }
            let done = eof
            lock.unlock()
            if done { return nil }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}

final class StopRequest: @unchecked Sendable {
    static let shared = StopRequest()
    private let lock = NSLock()
    private var flag = false
    private var source: DispatchSourceSignal?

    var requested: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }

    /// Ctrl+C zaustavlja snimanje i čuva fajl, umjesto da ubije proces usred upisa.
    func installSIGINT() {
        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        src.setEventHandler { [self] in set() }
        src.resume()
        source = src
    }
}

let stdinIsTTY = isatty(STDIN_FILENO) != 0

/// Čeka `seconds` (ili zauvijek ako je nil) uz ispis; vraća se na Enter / Ctrl+C / `shouldStop`.
func waitWhileRecording(seconds: Double?, shouldStop: () -> Bool = { false }, status: (Double) -> String) {
    StopRequest.shared.installSIGINT()
    if seconds == nil {
        print(stdinIsTTY ? "   ⏺  Snimam — Enter ili Ctrl+C za kraj." : "   ⏺  Snimam — Ctrl+C za kraj.")
    }
    let start = Date()
    while true {
        let elapsed = Date().timeIntervalSince(start)
        if let seconds, elapsed >= seconds { break }
        if StopRequest.shared.requested || shouldStop() { break }
        if seconds == nil, stdinIsTTY, StdinLines.shared.poll() != nil { break }
        print("   ⏱  \(status(elapsed))   ", terminator: "\r")
        fflush(stdout)
        Thread.sleep(forTimeInterval: 0.2)
    }
    print("")
}

func clock(_ seconds: Double) -> String {
    let s = Int(seconds)
    return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
}

// MARK: - Transcribe helpers

/// Trajanje: "90" = 90s, "90s" = 90s, "5min"/"5m" = 300s, "1h" = 3600s
func parseDuration(_ s: String) -> Double? {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if t.hasSuffix("min"), let v = Double(t.dropLast(3)) { return v * 60 }
    if t.hasSuffix("h"), let v = Double(t.dropLast(1)) { return v * 3600 }
    if t.hasSuffix("m"), let v = Double(t.dropLast(1)) { return v * 60 }
    if t.hasSuffix("s"), let v = Double(t.dropLast(1)) { return v }
    return Double(t)
}

struct TranscribeOpts {
    var lang: String?
    var tModel: String
    var rModel: String
    var key: String?
    var noReport: Bool
}

func transcribeOptsFromArgs() -> TranscribeOpts {
    let lang = flagValue(["--language", "--lang", "-l"])
    let tModel = flagValue(["--transcribe-model", "--model"]) ?? OpenRouterConfig.transcribeModelDefault
    let rModel = flagValue(["--report-model"]) ?? OpenRouterConfig.reportModelDefault
    let key = flagValue(["--api-key"])
    let noReport = hasFlag(["--no-report"])
    return TranscribeOpts(lang: lang, tModel: tModel, rModel: rModel, key: key, noReport: noReport)
}

func requireKey(_ explicit: String?) {
    if OpenRouterConfig.resolveAPIKey(explicit: explicit) == nil {
        print("❌ Nema OpenRouter ključa.")
        print("   Rješenje: export OPENROUTER_API_KEY=sk-or-...  ili  cleanmic-cli set-key sk-or-...")
        exit(1)
    }
}

/// Snimak duži od 1 h: traži potvrdu prije slanja (trošak + trajanje obrade).
func confirmIfLong(audioPath: String, duration: Double) {
    guard TranscriptionService.needsConfirmation(seconds: duration) else { return }
    let cost = TranscriptionService.estimatedCostUSD(seconds: duration)
    let eta = TranscriptionService.estimatedProcessingSeconds(audioSeconds: duration)
    print("⚠️  Snimak traje \(ReportService.humanDuration(duration)) — duže od 1 h.")
    print(String(format: "   Transkripcija: oko $%.2f, obrada oko %@.", cost, ReportService.humanDuration(eta)))
    if hasFlag(["--yes", "-y"]) {
        print("   Potvrđeno sa --yes.")
        return
    }
    guard stdinIsTTY else {
        print("❌ Potrebna potvrda: pokreni ponovo sa --yes.")
        exit(2)
    }
    print("   Nastaviti? [d/N] ", terminator: "")
    fflush(stdout)
    let answer = (StdinLines.shared.next() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    guard ["d", "da", "y", "yes"].contains(answer) else {
        print("ℹ️  Preskočeno. Kasnije: cleanmic-cli transcribe \"\(audioPath)\" --yes")
        exit(0)
    }
}

func runTranscribeFlow(audioPath: String, opts: TranscribeOpts) {
    print("\n🎧 Transkripcija: \(audioPath)")
    print("   Model: \(opts.tModel)  Jezik: \(opts.lang ?? "auto")")
    requireKey(opts.key)
    guard FileManager.default.fileExists(atPath: audioPath) else {
        print("❌ Fajl ne postoji: \(audioPath)")
        exit(1)
    }
    let duration = TranscriptionService.audioDuration(path: audioPath) ?? 0
    if duration > 0 { print("   Trajanje: \(ReportService.humanDuration(duration))") }
    confirmIfLong(audioPath: audioPath, duration: duration)

    do {
        let res = try TranscriptionService.transcribeSync(
            audioPath: audioPath, apiKey: opts.key, model: opts.tModel, language: opts.lang,
            progress: { done, total in
                if total > 1 { print("   ⏳ dio \(done)/\(total)") } else if done == 0 { print("   ⏳ šaljem na OpenRouter…") }
            })
        let cost = res.costUSD.map { String(format: ", $%.4f", $0) } ?? ""
        print("✅ Transkript (\(res.text.count) znakova, \(res.parts) dio/dijelova\(cost)) → \(res.transcriptPath)")
        print("   ----")
        print(res.text.prefix(800))
        if res.text.count > 800 { print("   ... (skraćeno, puni tekst u .transcript.txt)") }
        print("   ----")

        if opts.noReport {
            print("ℹ️  --no-report: preskačem izvještaj.")
            return
        }
        generateReport(transcript: res.text, audioPath: audioPath, duration: duration, opts: opts)
    } catch {
        print("❌ Transkripcija neuspješna: \(error)")
        print("   Detalji: \(DebugLog.fileURL.path)")
        DebugLog.flush()
        exit(1)
    }
}

func generateReport(transcript: String, audioPath: String, duration: Double?, opts: TranscribeOpts) {
    print("\n📝 Izvještaj (\(opts.rModel)) ...")
    do {
        let rep = try ReportService.generateSync(
            transcript: transcript, audioPath: audioPath, apiKey: opts.key, model: opts.rModel,
            language: opts.lang, transcribeModel: opts.tModel, durationSeconds: duration,
            progress: { stage, done, total in
                if total > 1 { print("   ⏳ \(stage) \(done)/\(total)") }
            })
        let via = rep.modelUsed == opts.rModel ? "" : " (odgovorio rezervni model \(rep.modelUsed))"
        let how = rep.chunks > 1 ? ", obrađeno u \(rep.chunks) dijelova" : ""
        print("✅ Izvještaj → \(rep.reportPath)\(via)\(how)")
        print("   ----")
        print(rep.summaryMarkdown)
        print("   ----")
    } catch {
        print("❌ Izvještaj neuspješan: \(error)")
        print("   Transkript je sačuvan. Ponovi samo izvještaj: cleanmic-cli report <transkript.txt>")
        print("   Detalji: \(DebugLog.fileURL.path)")
        DebugLog.flush()
        exit(1)
    }
}

/// Samo izvještaj iz postojećeg .transcript.txt — bez ponovne transkripcije.
func runReportOnly(transcriptPath: String, opts: TranscribeOpts) {
    guard let transcript = try? String(contentsOfFile: transcriptPath, encoding: .utf8) else {
        print("❌ Ne mogu pročitati transkript: \(transcriptPath)")
        exit(1)
    }
    requireKey(opts.key)
    // sastanak.transcript.txt → sastanak.wav (izvještaj ide pored snimka)
    var base = (transcriptPath as NSString).deletingPathExtension
    if base.hasSuffix(".transcript") { base = String(base.dropLast(".transcript".count)) }
    let audio = flagValue(["--audio"]) ?? (base + ".wav")
    let duration = TranscriptionService.audioDuration(path: audio)
    print("📄 Transkript: \(transcriptPath) (\(transcript.count) znakova)")
    generateReport(transcript: transcript, audioPath: audio, duration: duration, opts: opts)
}

func runCheckKey() {
    guard let key = OpenRouterConfig.resolveAPIKey(explicit: flagValue(["--api-key"])) else {
        print("❌ Nema OpenRouter ključa. cleanmic-cli set-key sk-or-...")
        exit(1)
    }
    print("🔑 Ključ: \(OpenRouterConfig.storedKeyHint)")
    do {
        let info = try OpenRouterClient.checkKey(key)
        print("✅ Ključ radi — \(info.summary)")
    } catch {
        print("❌ \(error)")
        exit(1)
    }
}

/// Bez filtera: ponuđeni modeli sa cijenama. Sa filterom: pretraga svih modela na OpenRouteru.
func runModels(filter: String?) {
    do {
        let all = try OpenRouterClient.listModels()
        let shown: [OpenRouterClient.ModelInfo]
        if let f = filter?.lowercased(), !f.isEmpty {
            shown = all.filter { ($0.id + " " + $0.name).lowercased().contains(f) }.sorted { $0.id < $1.id }
            print("🔎 Modeli na OpenRouteru koji sadrže „\(f)” (\(shown.count) od \(all.count)):\n")
        } else {
            shown = OpenRouterConfig.reportModelOptions.compactMap { option in all.first(where: { $0.id == option.id }) }
            print("📋 Modeli za izvještaj (default: \(OpenRouterConfig.reportModelDefault))")
            print("   Transkripcija: \(OpenRouterConfig.transcribeModelDefault)\n")
            let missing = OpenRouterConfig.reportModelOptions.filter { o in !all.contains(where: { $0.id == o.id }) }
            for m in missing { print("  ⚠️  \(m.id) više nije na OpenRouteru") }
        }
        for m in shown {
            let price = (m.inputPerM != nil && m.outputPerM != nil)
                ? String(format: "$%.2f / $%.2f po M tokena", m.inputPerM!, m.outputPerM!) : "cijena nepoznata"
            let mark = m.id == OpenRouterConfig.reportModelDefault ? "★" : " "
            print("  \(mark) \(m.id.padding(toLength: 40, withPad: " ", startingAt: 0)) \(price)")
        }
        if shown.isEmpty { print("  (nema rezultata)") }
        print("\nUpotreba: cleanmic-cli report <transkript.txt> --report-model <ID>")
    } catch {
        print("❌ \(error)")
        exit(1)
    }
}

func runSelfTest() {
    print("🧪 CleanMic selftest (offline)\n")
    let checks = SelfTest.runAll()
    for c in checks {
        print("  \(c.passed ? "✅" : "❌") \(c.name)")
        print("       \(c.detail)")
    }
    let failed = checks.filter { !$0.passed }.count
    print("\n\(failed == 0 ? "✅ Sve provjere prošle" : "❌ Palo: \(failed)") (\(checks.count - failed)/\(checks.count))")
    if failed > 0 { exit(1) }
}

// MARK: - Commands

func parseMode(_ s: String) -> CleanMicMode {
    switch s.lowercased() {
    case "light": return .light
    case "balanced": return .balanced
    case "maximum", "max": return .maximum
    default: return .balanced
    }
}

func runList() {
    print("🎙  CleanMic — Input Devices")
    print("   Permission: \(DeviceLister.checkMicrophonePermission())\n")
    if DeviceLister.checkMicrophonePermission() == "notDetermined" {
        print("   ℹ︎  Requesting microphone permission...")
        let sem = DispatchSemaphore(value: 0)
        DeviceLister.requestMicrophonePermission { granted in
            print("   Permission \(granted ? "granted ✅" : "denied ❌")")
            sem.signal()
        }
        sem.wait()
        Thread.sleep(forTimeInterval: 0.5)
    }

    let devices = DeviceLister.listInputDevices()
    if devices.isEmpty {
        print("   ⚠️  Nema input uređaja")
    } else {
        for (i, d) in devices.enumerated() {
            print("  \(i+1). \(d)")
        }
        print("\n   Default: \(DeviceLister.defaultInputDeviceID())")
        print("   Ukupno: \(devices.count) input uređaja")
    }

    // Also show AVAudioEngine current input
    let engine = AVAudioEngine()
    let fmt = engine.inputNode.outputFormat(forBus: 0)
    print("\n   AVAudioEngine inputNode format: \(fmt)")
    if fmt.channelCount == 0 {
        print("   ⚠️  inputNode ima 0 kanala — možda nema dozvole ili nema mic-a")
    }
    print("\n   OpenRouter ključ: \(OpenRouterConfig.storedKeyHint)")
}

func ensureMicPermission() {
    let perm = DeviceLister.checkMicrophonePermission()
    print("   Permission: \(perm)")
    if perm == "denied" || perm == "restricted" {
        print("❌ Mikrofon permission denied. Odobri u System Settings -> Privacy & Security -> Microphone")
        exit(1)
    }
    if perm == "notDetermined" {
        print("   ℹ︎  Tražim dozvolu...")
        let sem = DispatchSemaphore(value: 0)
        let granted = LockedFlag()
        DeviceLister.requestMicrophonePermission { g in if g { granted.set() }; sem.signal() }
        sem.wait()
        if !granted.isSet {
            print("❌ Permission denied")
            exit(1)
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

func printRecorded(_ url: URL) {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let size = attrs[.size] as? UInt64 else {
        print("❌ File nije kreiran ili prazan")
        return
    }
    print("✅ Snimljeno: \(url.path) (\(String(format: "%.1f", Double(size) / 1024 / 1024)) MB)")
    if let file = try? AVAudioFile(forReading: url) {
        let d = Double(file.length) / file.processingFormat.sampleRate
        print("   File: \(Int(file.fileFormat.sampleRate)) Hz, \(file.fileFormat.channelCount) ch, trajanje \(ReportService.humanDuration(d))")
    } else {
        print("   ⚠️  Ne mogu pročitati file")
    }
    print("   ▶️  Play: afplay \"\(url.path)\"")
}

/// mic -> RNNoise -> WAV, ista putanja koda kao u aplikaciji (RecordingSession).
func runRecordProcessed(seconds: Double?, outputPath: String, mode: CleanMicMode, deviceID: AudioDeviceID?,
                        systemAudio: SystemAudioMode) {
    let length = seconds.map { ReportService.humanDuration($0) } ?? "dok se ne zaustavi"
    print("🎙  CleanMic Record + RNNoise (\(mode)) — \(length) -> \(outputPath)")
    if let route = OutputRouteDetector.current() {
        let kind = route.isHeadphones ? "slušalice" : "zvučnici"
        print("   🔈 Izlaz: \(route.name) (\(kind)) — zvuk iz računara: \(systemAudio.title)")
    }
    ensureMicPermission()

    let session = RecordingSession(outputURL: URL(fileURLWithPath: outputPath), mode: mode, deviceID: deviceID,
                                   systemAudio: systemAudio)
    do {
        try session.start()
    } catch {
        print("❌ Start failed: \(error)")
        runList()
        exit(1)
    }
    waitWhileRecording(seconds: seconds, shouldStop: { !session.isRunning }) { _ in
        let s = session.snapshot()
        return String(format: "%@  %5.1f MB  ulaz %.3f  čisto %.3f  vad %.2f  %.2f ms/frame",
                      clock(s.duration), Double(s.bytes) / 1024 / 1024, s.inputLevel, s.cleanLevel, s.vad, s.avgProcessingMs)
    }
    let summary = session.stop()
    if let msg = summary.reason.message { print("⚠️  \(msg)") }
    print("   Ispušteno blokova: \(summary.droppedBlocks)  Restart mikrofona: \(summary.captureRestarts)")
    if summary.systemAudioUsed {
        print(summary.systemAudioHeard
              ? "   Zvuk iz računara: snimljen"
              : "   ⚠️  Zvuk iz računara je bio tih cijelo vrijeme — provjeri dozvolu (System Settings → Privacy & Security → Screen & System Audio Recording)")
    }
    printRecorded(summary.url)
}

/// Samo zvuk iz računara -> WAV. Dijagnostika: pusti nešto i vidi da li stiže.
func runRecordSystem(seconds: Double?, outputPath: String) {
    guard SystemAudioCapture.isSupported else {
        print("❌ Snimanje zvuka iz računara traži macOS 14.2 ili noviji.")
        exit(1)
    }
    let length = seconds.map { ReportService.humanDuration($0) } ?? "dok se ne zaustavi"
    print("🔊  CleanMic zvuk iz računara — \(length) -> \(outputPath)")
    if let route = OutputRouteDetector.current() {
        print("   🔈 Izlaz: \(route.name) (\(route.isHeadphones ? "slušalice" : "zvučnici"))")
    }
    let writer: StreamingWAVWriter
    do {
        writer = try StreamingWAVWriter(url: URL(fileURLWithPath: outputPath), sampleRate: 48000, channels: 1)
    } catch {
        print("❌ Writer error: \(error)")
        exit(1)
    }
    let lock = NSLock()
    var frames = 0
    let capture = SystemAudioCapture(mode: .always)
    capture.onNotice = { print("\n   ℹ️  \($0)") }
    capture.onPCM = { ptr, count in
        lock.lock()
        defer { lock.unlock() }
        try? writer.write(ptr, count: count)
        frames += count
    }
    capture.start()
    waitWhileRecording(seconds: seconds) { elapsed in
        lock.lock()
        let n = frames
        lock.unlock()
        return String(format: "%@  %.1f s zvuka  nivo %.3f", clock(elapsed), Double(n) / 48000, capture.takePeak())
    }
    capture.stop()
    lock.lock()
    writer.close()
    lock.unlock()
    print(capture.heardAudio
          ? "   Zvuk iz računara: snimljen"
          : "   ⚠️  Nije stigao čujan zvuk. Ako je nešto svirano: dozvola nije data (System Settings → Privacy & Security → Screen & System Audio Recording).")
    printRecorded(URL(fileURLWithPath: outputPath))
}

/// Sirov mikrofon -> WAV (bez RNNoise) — za AB poređenje sa record-processed.
func runRecordRaw(seconds: Double?, outputPath: String) {
    let length = seconds.map { ReportService.humanDuration($0) } ?? "dok se ne zaustavi"
    print("🎙  CleanMic Record (raw) — \(length) -> \(outputPath)")
    ensureMicPermission()

    let outURL = URL(fileURLWithPath: outputPath)
    let capture = AudioCapture()
    let writer: StreamingWAVWriter
    do {
        writer = try StreamingWAVWriter(url: outURL, sampleRate: 48000, channels: 1)
    } catch {
        print("❌ Writer error: \(error)")
        exit(1)
    }
    // Tap isporučuje bafere serijski, pa writer ne treba lock; zatvara se tek nakon capture.stop().
    capture.onPCM = { buffer in
        guard let data = buffer.floatChannelData else { return }
        try? writer.write(data[0], count: Int(buffer.frameLength))
    }
    do {
        try capture.start()
    } catch {
        print("❌ Start failed: \(error)")
        runList()
        exit(1)
    }
    waitWhileRecording(seconds: seconds) { elapsed in "\(clock(elapsed)) snimam…" }
    capture.stop()
    writer.close()
    printRecorded(outURL)
}

func runOfflineProcess(inPath: String, outPath: String, mode: CleanMicMode) {
    print("🔄 Offline process: \(inPath) -> \(outPath) [\(mode)]")
    let inURL = URL(fileURLWithPath: inPath)
    let outURL = URL(fileURLWithPath: outPath)
    guard FileManager.default.fileExists(atPath: inURL.path) else {
        print("❌ Ulazni fajl ne postoji: \(inPath)")
        exit(1)
    }

    do {
        let (samples, sr) = try WAVReader.readFloats(url: inURL)
        print("   Input: \(samples.count) samples @\(Int(sr))Hz (~\(String(format:"%.2f", Double(samples.count)/sr))s)")

        // Resample to 48k if needed (simple: if sr != 48k, warn and process anyway chunked)
        if sr != 48000 {
            print("   ⚠️  Input nije 48k (\(Int(sr))Hz). Za Fazu 0 spike procesiramo bez resampling-a, rezultat će biti pitch-shiftovan. TODO: AVAudioConverter.")
        }

        // Chunk into 480
        let proc = NoiseProcessor(mode: mode)
        var output: [Float] = []
        output.reserveCapacity(samples.count)

        let t0 = CFAbsoluteTimeGetCurrent()
        var frames = 0
        var maxMs: Double = 0
        var totalMs: Double = 0

        // Pad to multiple of 480
        let paddedCount = ((samples.count + 479) / 480) * 480
        var padded = samples
        if padded.count < paddedCount {
            padded.append(contentsOf: [Float](repeating: 0, count: paddedCount - padded.count))
        }

        for i in stride(from: 0, to: padded.count, by: 480) {
            let chunk = Array(padded[i..<i+480])
            var out = [Float](repeating: 0, count: 480)
            let ft0 = CFAbsoluteTimeGetCurrent()
            let vad = out.withUnsafeMutableBufferPointer { outPtr in
                chunk.withUnsafeBufferPointer { inPtr in
                    proc.processFrame(out: outPtr.baseAddress!, input: inPtr.baseAddress!)
                }
            }
            let ft1 = CFAbsoluteTimeGetCurrent()
            let ms = (ft1 - ft0) * 1000
            totalMs += ms
            if ms > maxMs { maxMs = ms }
            frames += 1
            output.append(contentsOf: out)
            if frames % 200 == 0 {
                print("   ... \(frames) frames vad=\(String(format:"%.2f", vad))")
            }
        }
        let t1 = CFAbsoluteTimeGetCurrent()
        let total = (t1 - t0) * 1000
        print("   ✅ Processed \(frames) frames in \(String(format:"%.1f", total))ms avg=\(String(format:"%.3f", totalMs/Double(frames)))ms max=\(String(format:"%.3f", maxMs))ms")

        // Write output
        let writer = try WAVWriter(url: outURL, sampleRate: 48000, channels: 1)
        // Trim to original length
        let trimmed = Array(output.prefix(samples.count))
        try writer.write(floats: trimmed)
        writer.close()
        print("✅ Upisano: \(outURL.path)")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: outURL.path), let size = attrs[.size] as? UInt64 {
            print("   Size: \(size) bytes")
        }
        print("   ▶️  AB test: afplay \"\(inPath)\"  vs  afplay \"\(outPath)\"")

    } catch {
        print("❌ Greška: \(error)")
        exit(1)
    }
}

func runRingTest() {
    print("🧪 RingBuffer stress test — 2 threada, 2s")
    let ring = RingBuffer(capacityFrames: 16384)
    let framesPerWrite = 512
    let iterations = 5000
    var writeCount = 0
    var readCount = 0
    let group = DispatchGroup()

    group.enter()
    DispatchQueue.global(qos: .userInteractive).async {
        var data = [Float](repeating: 0.5, count: framesPerWrite)
        for i in 0..<iterations {
            data[0] = Float(i % 100) / 100.0
            while !ring.write(data) {
                Thread.sleep(forTimeInterval: 0.001)
            }
            writeCount += 1
        }
        group.leave()
    }

    group.enter()
    DispatchQueue.global(qos: .userInteractive).async {
        var out = [Float](repeating: 0, count: framesPerWrite)
        var reads = 0
        while reads < iterations {
            if ring.read(into: &out, frames: framesPerWrite) {
                reads += 1
                readCount = reads
            } else {
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
        group.leave()
    }

    group.wait()
    print("✅ writeCount=\(writeCount) readCount=\(readCount) overruns=\(ring.overrunCount) underruns=\(ring.underrunCount)")
    if ring.overrunCount == 0 && ring.underrunCount == 0 {
        print("   ✅ PASS — nema over/underrun (idealno)")
    } else {
        print("   ⚠️  Over/underrun prisutni — ring premali ili scheduling jitter (očekivano na load-u)")
    }
}
