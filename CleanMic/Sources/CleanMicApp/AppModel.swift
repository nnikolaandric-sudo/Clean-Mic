import SwiftUI
import AVFoundation
import CoreAudio
import ServiceManagement
import CleanMicCore

struct RecordingInfo: Equatable {
    let url: URL
    let duration: Double
    let bytes: Int64

    var name: String { url.lastPathComponent }
    private var base: String { url.deletingPathExtension().path }
    var transcriptURL: URL { URL(fileURLWithPath: base + ".transcript.txt") }
    var reportURL: URL { URL(fileURLWithPath: base + ".izvjestaj.md") }
}

enum Banner: Equatable {
    case info(String)
    case warning(String)
    case error(String)
}

/// Vrijednosti koje se mijenjaju više puta u sekundi dok traje snimanje.
/// Odvojene od AppModel-a da tajmer i metri ne iscrtavaju cijeli popover.
@MainActor
final class LiveMeters: ObservableObject {
    @Published var elapsedSeconds = 0
    @Published var bytes: Int64 = 0
    @Published var input: Float = 0
    @Published var clean: Float = 0

    func reset() {
        elapsedSeconds = 0
        bytes = 0
        input = 0
        clean = 0
    }
}

@MainActor
final class AppModel: ObservableObject {
    // MARK: Snimanje
    @Published var isRecording = false
    @Published var isStopping = false
    @Published var banner: Banner?
    @Published var selectedMode: CleanMicMode = .balanced
    @Published var devices: [AudioDevice] = []
    /// nil = sistemski zadani mikrofon (prati System Settings).
    @Published var selectedDeviceUID: String?
    @Published var micPermission = DeviceLister.checkMicrophonePermission()
    @Published var lastRecording: RecordingInfo?
    let meters = LiveMeters()

    // MARK: Transkripcija / izvještaj
    @Published var isTranscribing = false
    @Published var transcribeProgress: Double = 0
    @Published var transcriptStatus = ""
    @Published var transcriptFailed = false
    /// Snimak duži od 1 h čeka potvrdu prije slanja.
    @Published var pendingConfirm: RecordingInfo?
    @Published var transcriptText = ""
    @Published var reportMarkdown = ""
    @Published var reportSummary = ""

    // MARK: Podešavanja
    @Published var apiKeyInput = ""
    @Published var apiKeyHint = ""
    @Published var hasAPIKey = false
    @Published var keyCheckStatus = ""
    @Published var transcribeLanguage = "sr"
    @Published var autoTranscribe = true
    @Published var reportModel = OpenRouterConfig.reportModelDefault
    /// "Drugi model…" u Podešavanjima: ručno upisan OpenRouter ID.
    @Published var customModelMode = false
    @Published var customModelInput = ""
    @Published var modelCheckStatus = ""
    @Published var launchAtLogin = false
    @Published var saveFolder: URL = AppModel.defaultSaveFolder

    let transcribeModel = OpenRouterConfig.transcribeModelDefault
    let languageOptions: [(code: String, name: String)] = [
        ("auto", "Automatski"), ("sr", "Srpski"), ("hr", "Hrvatski"), ("bs", "Bosanski"), ("en", "Engleski"),
    ]
    let reportModelOptions = OpenRouterConfig.reportModelOptions
    static let customModelTag = "__custom__"

    private var session: RecordingSession?
    private var pollTimer: Timer?
    private var deviceTimer: Timer?
    private let defaults = UserDefaults.standard

    static var defaultSaveFolder: URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        return downloads.appendingPathComponent("CleanMic", isDirectory: true)
    }

    init() {
        selectedMode = CleanMicMode(rawValue: defaults.object(forKey: "mode") as? Int ?? 1) ?? .balanced
        selectedDeviceUID = defaults.string(forKey: "inputDeviceUID")
        autoTranscribe = defaults.object(forKey: "autoTranscribe") as? Bool ?? true
        transcribeLanguage = defaults.string(forKey: "transcribeLanguage") ?? "sr"
        // v1.2: default za izvještaj je GPT-6 Luna. Ko je ostao na starom defaultu
        // prelazi jednom; izbor napravljen poslije toga se poštuje.
        if defaults.integer(forKey: "reportModelMigration") < 2 {
            let stored = defaults.string(forKey: "reportModel")
            if stored == nil || stored == OpenRouterConfig.previousReportModelDefault {
                defaults.set(OpenRouterConfig.reportModelDefault, forKey: "reportModel")
            }
            defaults.set(2, forKey: "reportModelMigration")
        }
        reportModel = OpenRouterConfig.normalizedReportModel(defaults.string(forKey: "reportModel"))
        customModelMode = !reportModelOptions.contains(where: { $0.id == reportModel })
        customModelInput = customModelMode ? reportModel : ""
        if let path = defaults.string(forKey: "saveFolder"), !path.isEmpty {
            saveFolder = URL(fileURLWithPath: path, isDirectory: true)
        }
        refreshKeyState()
        apiKeyInput = OpenRouterConfig.resolveAPIKey() ?? ""
        launchAtLogin = SMAppService.mainApp.status == .enabled
        refreshDevices()
        restoreLastRecording()

        // .common: da tajmer radi i dok je otvoren meni ili se vuče prozor.
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDevices() }
        }
        RunLoop.main.add(t, forMode: .common)
        deviceTimer = t

        AppDelegate.shutdown = { [weak self] in self?.shutdown() }
    }

    // MARK: - Uređaji

    func refreshDevices() {
        let list = DeviceLister.listInputDevices()
        if list.map(\.id) != devices.map(\.id) || list.first?.isDefaultInput != devices.first?.isDefaultInput {
            devices = list
        }
        let perm = DeviceLister.checkMicrophonePermission()
        if perm != micPermission { micPermission = perm }
    }

    var defaultDeviceName: String {
        devices.first(where: { $0.isDefaultInput })?.name ?? "—"
    }

    var activeMicName: String {
        if let uid = selectedDeviceUID, let d = devices.first(where: { $0.uid == uid }) { return d.name }
        return defaultDeviceName
    }

    func setDevice(uid: String?) {
        selectedDeviceUID = uid
        defaults.set(uid, forKey: "inputDeviceUID")
    }

    /// UID je stabilan između pokretanja; AudioDeviceID nije.
    private func resolvedDeviceID() -> AudioDeviceID? {
        guard let uid = selectedDeviceUID else { return nil }
        return devices.first(where: { $0.uid == uid && $0.isAlive })?.id
    }

    func setMode(_ mode: CleanMicMode) {
        selectedMode = mode
        defaults.set(mode.rawValue, forKey: "mode")
        session?.setMode(mode)
    }

    // MARK: - Snimanje

    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    func startRecording() {
        guard !isRecording, !isStopping else { return }
        banner = nil

        switch DeviceLister.checkMicrophonePermission() {
        case "notDetermined":
            DeviceLister.requestMicrophonePermission { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.micPermission = DeviceLister.checkMicrophonePermission()
                    if granted { self.startRecording() }
                }
            }
            return
        case "denied", "restricted":
            micPermission = "denied"
            return
        default:
            break
        }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd_HHmmss"
        let url = saveFolder.appendingPathComponent("CleanMic_\(stamp.string(from: Date()))_\(selectedMode).wav")
        let newSession = RecordingSession(outputURL: url, mode: selectedMode, deviceID: resolvedDeviceID())
        newSession.onAutoStop = { [weak self] summary in
            Task { @MainActor in self?.recordingFinished(summary) }
        }
        do {
            try newSession.start()
        } catch {
            banner = .error("Snimanje nije pokrenuto: \(ErrorText.describe(error))")
            return
        }
        session = newSession
        isRecording = true
        pendingConfirm = nil
        meters.reset()

        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    func stopRecording() {
        guard let session, isRecording, !isStopping else { return }
        isStopping = true
        // stop() čeka da se zadnji frameovi upišu (~0.5 s) — ne na glavnoj niti.
        DispatchQueue.global(qos: .userInitiated).async {
            let summary = session.stop()
            Task { @MainActor in self.recordingFinished(summary) }
        }
    }

    private func poll() {
        guard let session else { return }
        let snap = session.snapshot()
        let seconds = Int(snap.duration)
        if seconds != meters.elapsedSeconds {
            meters.elapsedSeconds = seconds
            meters.bytes = snap.bytes
        }
        meters.input = max(snap.inputLevel, meters.input * 0.75)
        meters.clean = max(snap.cleanLevel, meters.clean * 0.75)
        if let notice = snap.notice { banner = .info(notice) }
    }

    private func recordingFinished(_ summary: RecordingSession.Summary) {
        guard session != nil else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        session = nil
        isRecording = false
        isStopping = false
        meters.reset()

        guard summary.duration >= 1 else {
            try? FileManager.default.removeItem(at: summary.url)
            banner = .warning("Snimak je kraći od sekunde — nije sačuvan.")
            return
        }
        let info = RecordingInfo(url: summary.url, duration: summary.duration, bytes: summary.bytes)
        setLastRecording(info)
        if let message = summary.reason.message {
            banner = .warning(message)
        } else if summary.droppedBlocks > 0 {
            banner = .warning("Mac je bio preopterećen — u snimku je \(summary.droppedBlocks) kratkih prekida.")
        }
        if autoTranscribe {
            requestTranscription(info)
        }
    }

    private func setLastRecording(_ info: RecordingInfo) {
        lastRecording = info
        defaults.set(info.url.path, forKey: "lastRecordingPath")
        transcriptText = ""
        reportMarkdown = ""
        reportSummary = ""
        transcriptStatus = ""
        transcriptFailed = false
        pendingConfirm = nil
        loadSidecars(for: info)
    }

    /// Transkript i izvještaj koji već stoje pored snimka.
    private func loadSidecars(for info: RecordingInfo) {
        if let t = try? String(contentsOf: info.transcriptURL, encoding: .utf8) {
            transcriptText = t
        }
        if let r = try? String(contentsOf: info.reportURL, encoding: .utf8) {
            reportMarkdown = r
            reportSummary = ReportService.summarySection(in: r) ?? ""
        }
    }

    private func restoreLastRecording() {
        guard let path = defaults.string(forKey: "lastRecordingPath"),
              FileManager.default.fileExists(atPath: path) else { return }
        openRecording(at: URL(fileURLWithPath: path))
    }

    /// Postojeći snimak (npr. sa drugog Maca ili od ranije) kao "posljednji snimak".
    func openRecording(at url: URL) {
        let duration = TranscriptionService.audioDuration(path: url.path) ?? 0
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        setLastRecording(RecordingInfo(url: url, duration: duration, bytes: bytes))
    }

    func chooseRecording() {
        let panel = NSOpenPanel()
        panel.title = "Izaberi snimak"
        panel.allowedContentTypes = [.audio]
        panel.directoryURL = saveFolder
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            openRecording(at: url)
        }
    }

    // MARK: - Transkripcija

    /// Jedini ulaz u transkripciju: provjeri ključ i pravilo "preko 1 h → potvrda".
    func requestTranscription(_ info: RecordingInfo) {
        guard !isTranscribing else { return }
        guard hasAPIKey else {
            transcriptFailed = true
            transcriptStatus = "Za transkripciju unesi OpenRouter ključ u Podešavanjima."
            return
        }
        if TranscriptionService.needsConfirmation(seconds: info.duration) {
            pendingConfirm = info
            return
        }
        startTranscription(info)
    }

    func confirmPending() {
        guard let info = pendingConfirm else { return }
        pendingConfirm = nil
        startTranscription(info)
    }

    func declinePending() {
        pendingConfirm = nil
        transcriptFailed = false
        transcriptStatus = "Transkripcija preskočena — možeš je pokrenuti kasnije."
    }

    private func startTranscription(_ info: RecordingInfo) {
        isTranscribing = true
        transcriptFailed = false
        transcribeProgress = 0.02
        transcriptStatus = "Pripremam audio…"
        let language: String? = transcribeLanguage == "auto" ? nil : transcribeLanguage
        let tModel = transcribeModel
        let path = info.url.path

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try TranscriptionService.transcribeSync(
                    audioPath: path, apiKey: nil, model: tModel, language: language,
                    progress: { done, total in
                        Task { @MainActor in
                            self.transcribeProgress = 0.05 + 0.75 * Double(done) / Double(max(total, 1))
                            self.transcriptStatus = total > 1 ? "Transkribujem — dio \(done) od \(total)…" : "Transkribujem…"
                        }
                    })
                Task { @MainActor in
                    guard self.lastRecording == info else { self.isTranscribing = false; return }
                    self.transcriptText = result.text
                    self.generateReport(for: info, transcript: result.text)
                }
            } catch {
                let message = ErrorText.describe(error)
                Task { @MainActor in
                    self.isTranscribing = false
                    self.transcriptFailed = true
                    self.transcriptStatus = "Transkripcija nije uspjela: \(message)"
                }
            }
        }
    }

    /// Samo izvještaj iz postojećeg transkripta (bez ponovne naplate transkripcije).
    func regenerateReport() {
        guard let info = lastRecording, !transcriptText.isEmpty, !isTranscribing else { return }
        guard hasAPIKey else {
            transcriptFailed = true
            transcriptStatus = "Za izvještaj unesi OpenRouter ključ u Podešavanjima."
            return
        }
        isTranscribing = true
        transcriptFailed = false
        generateReport(for: info, transcript: transcriptText)
    }

    private func generateReport(for info: RecordingInfo, transcript: String) {
        transcribeProgress = 0.82
        transcriptStatus = "Pravim izvještaj…"
        let language: String? = transcribeLanguage == "auto" ? nil : transcribeLanguage
        let rModel = reportModel
        let tModel = transcribeModel

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let report = try ReportService.generateSync(
                    transcript: transcript, audioPath: info.url.path, apiKey: nil, model: rModel,
                    language: language, transcribeModel: tModel, durationSeconds: info.duration,
                    progress: { stage, done, total in
                        guard total > 1 else { return }
                        Task { @MainActor in
                            self.transcribeProgress = 0.82 + 0.15 * Double(done) / Double(total)
                            self.transcriptStatus = "Pravim izvještaj — \(stage) \(done) od \(total)…"
                        }
                    })
                Task { @MainActor in
                    self.isTranscribing = false
                    guard self.lastRecording == info else { return }
                    self.reportMarkdown = report.markdown
                    self.reportSummary = ReportService.summarySection(in: report.summaryMarkdown) ?? report.summaryMarkdown
                    self.transcribeProgress = 1
                    self.transcriptStatus = report.modelUsed == rModel
                        ? ""
                        : "Izvještaj je napravio rezervni model (\(report.modelUsed))."
                }
            } catch {
                let message = ErrorText.describe(error)
                Task { @MainActor in
                    self.isTranscribing = false
                    self.transcriptFailed = true
                    self.transcriptStatus = "Transkript je sačuvan, ali izvještaj nije uspio: \(message)"
                }
            }
        }
    }

    // MARK: - Podešavanja

    private func refreshKeyState() {
        hasAPIKey = OpenRouterConfig.resolveAPIKey() != nil
        apiKeyHint = hasAPIKey ? OpenRouterConfig.storedKeyHint : ""
    }

    func saveKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            keyCheckStatus = "Unesi ključ pa klikni Sačuvaj."
            return
        }
        OpenRouterConfig.saveAPIKey(key)
        refreshKeyState()
        if hasAPIKey, transcriptFailed, transcriptText.isEmpty {
            transcriptStatus = ""
            transcriptFailed = false
        }
        checkKey()
    }

    func checkKey() {
        guard let key = OpenRouterConfig.resolveAPIKey() else {
            keyCheckStatus = "Ključ nije postavljen."
            return
        }
        keyCheckStatus = "Provjeravam…"
        DispatchQueue.global(qos: .userInitiated).async {
            let text: String
            do {
                text = "✓ Ključ radi — \(try OpenRouterClient.checkKey(key).summary)"
            } catch {
                text = "✗ \(ErrorText.describe(error))"
            }
            Task { @MainActor in self.keyCheckStatus = text }
        }
    }

    func setLanguage(_ code: String) {
        transcribeLanguage = code
        defaults.set(code, forKey: "transcribeLanguage")
    }

    func setReportModel(_ model: String) {
        reportModel = model
        defaults.set(model, forKey: "reportModel")
    }

    var reportModelPickerValue: String {
        customModelMode ? Self.customModelTag : reportModel
    }

    func pickReportModel(_ value: String) {
        modelCheckStatus = ""
        if value == Self.customModelTag {
            customModelMode = true
        } else {
            customModelMode = false
            setReportModel(value)
        }
    }

    /// Ručno upisan model se čuva tek kad se potvrdi da postoji na OpenRouteru —
    /// greška u kucanju bi inače izašla na vidjelo tek nakon snimljenog sastanka.
    func applyCustomReportModel() {
        let id = customModelInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            modelCheckStatus = "Upiši ID modela, npr. anthropic/claude-haiku-4.5"
            return
        }
        modelCheckStatus = "Provjeravam…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try OpenRouterClient.modelInfo(id: id) }
            Task { @MainActor in
                switch result {
                case .success(let info?):
                    self.setReportModel(info.id)
                    self.modelCheckStatus = "✓ Sačuvano: \(info.summary)"
                case .success(nil):
                    self.modelCheckStatus = "✗ Model „\(id)” ne postoji na OpenRouteru. I dalje se koristi \(self.reportModel)."
                case .failure(let error):
                    self.modelCheckStatus = "✗ \(ErrorText.describe(error))"
                }
            }
        }
    }

    func setAutoTranscribe(_ on: Bool) {
        autoTranscribe = on
        defaults.set(on, forKey: "autoTranscribe")
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            banner = .error("Pokretanje pri prijavi nije podešeno: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.title = "Folder za snimke"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = saveFolder
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            saveFolder = url
            defaults.set(url.path, forKey: "saveFolder")
        }
    }

    func openSaveFolder() {
        try? FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(saveFolder)
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return "CleanMic \(version) (\(build))"
    }

    // MARK: - Izlaz

    /// Poziva se pri gašenju aplikacije: snimak u toku se zatvara i ostaje sačuvan.
    func shutdown() {
        guard let session else { return }
        _ = session.stop()
        self.session = nil
    }
}
