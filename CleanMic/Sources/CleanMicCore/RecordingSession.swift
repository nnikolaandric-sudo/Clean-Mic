import AVFoundation
import Foundation

/// Jedno snimanje: mikrofon → RNNoise → WAV, bez vremenskog limita.
///
/// Snima od `start()` do `stop()`. Samo se zaustavlja jedino kad bi nastavak
/// pokvario snimak: pun disk, WAV limit od 4 GB (~12 h) ili greška upisa.
///
/// Upis na disk ide sa vlastite niti, ne sa glavne. Ranije je output ring
/// praznio `Timer` na glavnom run loopu, a taj ne okida dok je otvoren meni
/// ili dok se vuče prozor — ring bi se napunio, engine stao i u snimku bi
/// ostala rupa. Kod snimanja od par sekundi to se ne vidi; kod sat vremena da.
public final class RecordingSession: @unchecked Sendable {
    public enum StopReason: Equatable {
        case user
        case sizeLimit
        case diskFull
        case writeError(String)

        public var message: String? {
            switch self {
            case .user: return nil
            case .sizeLimit: return "Dostignut maksimum jednog WAV fajla (~12 h) — snimak je sačuvan."
            case .diskFull: return "Disk je skoro pun — snimanje je zaustavljeno i sačuvano."
            case .writeError(let m): return "Greška upisa (\(m)) — snimljeno do tog trenutka je sačuvano."
            }
        }
    }

    public struct Summary {
        public let url: URL
        public let duration: Double
        public let bytes: Int64
        public let reason: StopReason
        /// Blokovi sa mikrofona koji nisu stali u ring (rupe u snimku). Treba biti 0.
        public let droppedBlocks: Int
        public let captureRestarts: Int
        /// Je li se uz mikrofon snimao i zvuk iz računara (slušalice ili mod "uvijek").
        public let systemAudioUsed: Bool
        /// Je li u tom zvuku ikad bilo čujnog signala. `systemAudioUsed && !systemAudioHeard`
        /// na online sastanku znači: nema dozvole za snimanje zvuka sistema (tap tada šuti).
        public let systemAudioHeard: Bool
    }

    public struct Snapshot {
        public let duration: Double
        public let bytes: Int64
        public let inputLevel: Float
        public let cleanLevel: Float
        public let vad: Float
        public let avgProcessingMs: Double
        public let notice: String?
    }

    /// Ispod ovoga se snimanje samo zaustavlja da ne napuni disk do kraja.
    public static let minFreeDiskBytes: Int64 = 300 * 1024 * 1024
    /// 2.7 s rezerve — raspoređivač na opterećenom laptopu zna zakasniti.
    private static let ringFrames = 131_072
    private static let frame = NoiseProcessor.frameSize

    public let outputURL: URL
    private let deviceID: AudioDeviceID?
    private let capture = AudioCapture()
    private let inputRing = RingBuffer(capacityFrames: RecordingSession.ringFrames)
    private let outputRing = RingBuffer(capacityFrames: RecordingSession.ringFrames)
    private let systemRing = RingBuffer(capacityFrames: 65_536)
    private let systemAudioMode: SystemAudioMode
    private var systemCapture: SystemAudioCapture?
    private let engine: ProcessingEngine
    private var writer: StreamingWAVWriter?

    private let lock = NSLock()
    private var running = false
    private var finished = false
    private var summary: Summary?
    private var autoStopReason: StopReason?
    private let drainDone = DispatchSemaphore(value: 0)
    private var activity: NSObjectProtocol?

    // Stanje za UI — puni se sa audio niti, čita iz snapshot().
    private var inputPeak: Float = 0
    private var cleanPeak: Float = 0
    private var vadLast: Float = 0
    private var avgMs: Double = 0
    private var noticeText: String?
    private var framesOnDisk: Int64 = 0

    /// Poziva se (sa pozadinske niti) kad se snimanje samo zaustavi.
    public var onAutoStop: ((Summary) -> Void)?

    public init(outputURL: URL, mode: CleanMicMode, deviceID: AudioDeviceID? = nil,
                systemAudio: SystemAudioMode = .auto) {
        self.outputURL = outputURL
        self.deviceID = deviceID
        self.systemAudioMode = systemAudio
        self.engine = ProcessingEngine(inputRing: inputRing, outputRing: outputRing, mode: mode)
    }

    public func setMode(_ mode: CleanMicMode) {
        engine.setMode(mode)
    }

    public var isRunning: Bool { locked { running } }

    public func start() throws {
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if let free = Self.freeDiskBytes(at: outputURL), free < Self.minFreeDiskBytes {
            throw NSError(domain: "CleanMic", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Nema dovoljno mjesta na disku (slobodno \(Self.megabytes(free)) MB)."
            ])
        }
        writer = try StreamingWAVWriter(url: outputURL, sampleRate: 48000, channels: 1)

        capture.onPCM = { [weak self] buffer in
            guard let self, let data = buffer.floatChannelData else { return }
            self.inputRing.write(data[0], frames: Int(buffer.frameLength))
        }
        capture.onLevel = { [weak self] level in
            guard let self else { return }
            self.locked { if level > self.inputPeak { self.inputPeak = level } }
        }
        capture.onNotice = { [weak self] text in
            guard let self else { return }
            DebugLog.log("capture: \(text)")
            self.locked { self.noticeText = text }
        }
        engine.onMetrics = { [weak self] _, vad in
            guard let self else { return }
            self.locked { self.vadLast = vad }
        }

        do {
            try capture.start(deviceID: deviceID)
        } catch {
            writer?.close()
            writer = nil
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        startSystemAudio()
        engine.start()
        locked { running = true }

        // Bez ovoga macOS uspava menu-bar app bez prozora (App Nap) ili cijeli
        // laptop nakon par minuta mirovanja, i snimak tiho stane.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "CleanMic snima")

        let thread = Thread { [weak self] in self?.drainLoop() }
        thread.name = "CleanMic.RecordingWriter"
        thread.qualityOfService = .userInitiated
        thread.start()
        DebugLog.log("snimanje start → \(outputURL.lastPathComponent)")
    }

    /// Zaustavi i zatvori fajl. Blokira do ~0.5 s — ne zvati sa glavne niti GUI-ja.
    @discardableResult
    public func stop() -> Summary {
        finish(reason: .user)
    }

    public func snapshot() -> Snapshot {
        locked {
            let s = Snapshot(duration: Double(framesOnDisk) / 48000,
                             bytes: framesOnDisk * 2,
                             inputLevel: inputPeak,
                             cleanLevel: cleanPeak,
                             vad: vadLast,
                             avgProcessingMs: avgMs,
                             notice: noticeText)
            inputPeak = 0
            cleanPeak = 0
            noticeText = nil
            return s
        }
    }

    // MARK: - Writer nit

    private func drainLoop() {
        var tmp = [Float](repeating: 0, count: Self.frame)
        var lastHousekeeping = CFAbsoluteTimeGetCurrent()
        var lastDiskCheck = lastHousekeeping

        loop: while true {
            // Pročitaj PRIJE pražnjenja: kad je `running` već false, engine je
            // stao, pa ovaj prolaz sigurno pokupi i zadnje frameove.
            let stillRunning = locked { running }
            var wrote = false
            while outputRing.availableRead >= Self.frame {
                guard outputRing.read(into: &tmp, frames: Self.frame) else { break }
                do {
                    try writer?.write(tmp)
                } catch {
                    requestAutoStop(.writeError(error.localizedDescription))
                    break loop
                }
                var energy: Float = 0
                for v in tmp { energy += v * v }
                let rms = (energy / Float(Self.frame)).squareRoot()
                let frames = writer?.framesWritten ?? 0
                locked {
                    if rms > cleanPeak { cleanPeak = rms }
                    framesOnDisk = frames
                }
                wrote = true
            }

            if !stillRunning { break }

            let now = CFAbsoluteTimeGetCurrent()
            if now - lastHousekeeping >= 1 {
                lastHousekeeping = now
                do {
                    try writer?.flush()
                } catch {
                    requestAutoStop(.writeError(error.localizedDescription))
                    break
                }
                locked { avgMs = engine.avgProcessingMs }
                if writer?.isAtSizeLimit == true {
                    requestAutoStop(.sizeLimit)
                    break
                }
                if now - lastDiskCheck >= 5 {
                    lastDiskCheck = now
                    if let free = Self.freeDiskBytes(at: outputURL), free < Self.minFreeDiskBytes {
                        requestAutoStop(.diskFull)
                        break
                    }
                }
                // Watchdog: mikrofon šuti 3 s (sleep/wake, isključen uređaj) → digni capture opet.
                if now - capture.lastBufferTime > 3 {
                    capture.restart(reason: "nema zvuka sa mikrofona")
                }
            }
            if !wrote { Thread.sleep(forTimeInterval: 0.005) }
        }
        drainDone.signal()

        if let reason = locked({ autoStopReason }) {
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let s = finish(reason: reason)
                onAutoStop?(s)
            }
        }
    }

    private func requestAutoStop(_ reason: StopReason) {
        locked { if autoStopReason == nil { autoStopReason = reason } }
    }

    private func finish(reason: StopReason) -> Summary {
        let alreadyFinishing: Bool = locked {
            if finished { return true }
            finished = true
            return false
        }
        if alreadyFinishing {
            // Auto-stop i korisnik u istom trenutku — sačekaj rezultat prvog poziva.
            while true {
                if let s = locked({ summary }) { return s }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }

        capture.stop()
        systemCapture?.stop()
        // Pusti engine da obradi ono što je još u ulaznom ringu.
        let deadline = CFAbsoluteTimeGetCurrent() + 0.4
        while inputRing.availableRead >= Self.frame && CFAbsoluteTimeGetCurrent() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        engine.stop()
        locked { running = false }
        _ = drainDone.wait(timeout: .now() + 3)

        writer?.close()
        let frames = writer?.framesWritten ?? 0
        writer = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }

        let s = Summary(url: outputURL,
                        duration: Double(frames) / 48000,
                        bytes: frames * 2 + 44,
                        reason: reason,
                        droppedBlocks: inputRing.overrunCount,
                        captureRestarts: capture.restartCount,
                        systemAudioUsed: systemCapture?.wasEverActive ?? false,
                        systemAudioHeard: systemCapture?.heardAudio ?? false)
        locked { summary = s }
        DebugLog.log(String(format: "snimanje stop: %.1f s, %@ MB, ispušteno blokova=%d, restart capture=%d, zvuk iz računara=%@, razlog=%@",
                            s.duration, Self.megabytes(s.bytes), s.droppedBlocks, s.captureRestarts,
                            s.systemAudioUsed ? (s.systemAudioHeard ? "da, čujan" : "da, ali tih") : "ne", "\(reason)"))
        return s
    }

    // MARK: - Zvuk iz računara

    /// Uz mikrofon snima i ono što računar pušta (glasovi ostalih), kad su slušalice.
    private func startSystemAudio() {
        guard systemAudioMode != .never, SystemAudioCapture.isSupported else { return }
        let system = SystemAudioCapture(mode: systemAudioMode)
        system.onPCM = { [weak self] ptr, frames in
            self?.systemRing.write(ptr, frames: frames)
        }
        system.onNotice = { [weak self] text in
            guard let self else { return }
            self.locked { self.noticeText = text }
        }
        engine.systemRing = systemRing
        systemCapture = system
        system.start()
    }

    // MARK: - Helpers

    static func freeDiskBytes(at url: URL) -> Int64? {
        let dir = url.deletingLastPathComponent()
        let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.0f", Double(bytes) / 1024 / 1024)
    }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
