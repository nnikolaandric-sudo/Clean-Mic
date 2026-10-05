import AVFoundation
import AudioToolbox
import Foundation

public enum CaptureError: Error, CustomStringConvertible {
    case noInputDevice
    case engineStartFailed(Error)
    case permissionDenied

    public var description: String {
        switch self {
        case .noInputDevice: return "Nema dostupnog mikrofona"
        case .engineStartFailed(let e): return "Audio engine se nije pokrenuo: \(e.localizedDescription)"
        case .permissionDenied: return "Nema dozvole za mikrofon"
        }
    }
}

/// AVAudioEngine capture -> PCM 48k/mono/Float32 preko tapa.
/// PRD-03 §2.1 [1] -> [2]
///
/// Snimanje traje dok ga korisnik ne zaustavi, pa capture mora preživjeti ono
/// što se na laptopu stalno dešava usred snimanja: uključene slušalice,
/// AirPods, dock, buđenje iz sleepa. Sve to mijenja ulazni uređaj i zaustavlja
/// AVAudioEngine — zato se na `AVAudioEngineConfigurationChange` engine pravi
/// iznova i capture nastavlja sam.
public final class AudioCapture: @unchecked Sendable {
    private var engine = AVAudioEngine()
    private let converter = FormatConverter()
    private let stateLock = NSLock()
    private let restartQueue = DispatchQueue(label: "cleanmic.capture.restart")
    private var configObserver: NSObjectProtocol?

    private var isRunning = false
    private var restartPending = false
    private var requestedDeviceID: AudioDeviceID?
    private var lastBuffer: CFAbsoluteTime = 0
    private var restarts = 0

    /// Callback for converted PCM (48k/mono/Float32)
    public var onPCM: ((AVAudioPCMBuffer) -> Void)?

    /// For metrics / level meter
    public var onLevel: ((Float) -> Void)?

    /// Kratka poruka za korisnika (promjena mikrofona, oporavak).
    public var onNotice: ((String) -> Void)?

    public private(set) var inputFormat: AVAudioFormat?
    public private(set) var targetFormat: AVAudioFormat?

    public init() {}

    public var running: Bool { locked { isRunning } }
    /// Vrijeme zadnjeg primljenog bafera — watchdog po ovome vidi da je capture stao.
    public var lastBufferTime: CFAbsoluteTime { locked { lastBuffer } }
    public var restartCount: Int { locked { restarts } }

    /// `deviceID == nil` znači sistemski zadani ulaz (prati promjene u System Settings).
    public func start(deviceID: AudioDeviceID? = nil) throws {
        let perm = DeviceLister.checkMicrophonePermission()
        if perm == "denied" || perm == "restricted" {
            throw CaptureError.permissionDenied
        }
        locked { requestedDeviceID = deviceID }
        try startEngine()
        locked {
            isRunning = true
            lastBuffer = CFAbsoluteTimeGetCurrent()
        }
    }

    public func stop() {
        let wasRunning: Bool = locked {
            let was = isRunning
            isRunning = false
            return was
        }
        guard wasRunning else { return }
        // Na restartQueue da se ne sudari sa oporavkom koji je možda u toku.
        restartQueue.sync { teardownEngine() }
        print("[AudioCapture] ⏹ stopped")
    }

    /// Napravi engine iznova (promjena uređaja, buđenje iz sleepa, watchdog).
    public func restart(reason: String) {
        let schedule: Bool = locked {
            guard isRunning, !restartPending else { return false }
            restartPending = true
            return true
        }
        guard schedule else { return }
        // Kratka pauza: odmah nakon promjene novi uređaj često još javlja 0 kanala.
        restartQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.performRestart(reason: reason)
        }
    }

    // MARK: - Engine

    private func startEngine() throws {
        teardownEngine()
        // Svjež engine pri svakom startu — stari inputNode nakon promjene uređaja
        // zna vratiti format prethodnog uređaja.
        let engine = AVAudioEngine()
        self.engine = engine
        let inputNode = engine.inputNode

        if let dev = locked({ requestedDeviceID }), dev != 0 {
            if !Self.setInputDevice(dev, on: inputNode) {
                onNotice?("Izabrani mikrofon nije dostupan — koristim sistemski.")
            }
        }

        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw CaptureError.noInputDevice
        }
        self.inputFormat = format
        converter.configure(inputFormat: format)
        self.targetFormat = converter.targetFormat ?? format

        print("[AudioCapture] input: \(format) -> target: \(String(describing: targetFormat))")

        // 512 frames ~10ms @48k as per PRD
        inputNode.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.locked { self.lastBuffer = CFAbsoluteTimeGetCurrent() }
            if let level = self.rmsLevel(buffer: buffer) {
                self.onLevel?(level)
            }
            let converted: AVAudioPCMBuffer?
            if self.converter.needsConversion {
                converted = self.converter.convert(buffer: buffer)
            } else {
                converted = buffer
            }
            if let out = converted {
                self.onPCM?(out)
            }
        }

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.restart(reason: "promjena audio uređaja")
        }

        engine.prepare()
        do {
            try engine.start()
            print("[AudioCapture] ✅ engine started")
        } catch {
            teardownEngine()
            throw CaptureError.engineStartFailed(error)
        }
    }

    private func teardownEngine() {
        if let obs = configObserver {
            NotificationCenter.default.removeObserver(obs)
            configObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
    }

    private func performRestart(reason: String) {
        defer { locked { restartPending = false } }
        for attempt in 1...5 {
            guard locked({ isRunning }) else { return }
            do {
                try startEngine()
                locked {
                    restarts += 1
                    lastBuffer = CFAbsoluteTimeGetCurrent()
                }
                let name = DeviceLister.deviceName(currentInputDeviceID()) ?? "mikrofon"
                print("[AudioCapture] ↻ restart (\(reason)) ok, pokušaj \(attempt): \(name)")
                onNotice?("Mikrofon: \(name) — snimanje se nastavlja")
                return
            } catch {
                print("[AudioCapture] ↻ restart (\(reason)) pokušaj \(attempt) neuspješan: \(error)")
                Thread.sleep(forTimeInterval: 0.6)
            }
        }
        // Izabrani uređaj je možda trajno nestao — pređi na sistemski i pusti
        // watchdog da proba opet.
        locked { requestedDeviceID = nil }
        onNotice?("Mikrofon nije dostupan — čekam da se pojavi…")
    }

    private func currentInputDeviceID() -> AudioDeviceID {
        if let dev = locked({ requestedDeviceID }), dev != 0 { return dev }
        return DeviceLister.defaultInputDeviceID()
    }

    /// Usmjeri inputNode (AUHAL) na konkretan uređaj umjesto sistemskog.
    private static func setInputDevice(_ id: AudioDeviceID, on node: AVAudioInputNode) -> Bool {
        guard let unit = node.audioUnit else { return false }
        var dev = id
        let status = AudioUnitSetProperty(unit,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            print("[AudioCapture] setInputDevice(\(id)) status=\(status)")
        }
        return status == noErr
    }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private func rmsLevel(buffer: AVAudioPCMBuffer) -> Float? {
        guard let data = buffer.floatChannelData else { return nil }
        let ch = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }
        var sum: Float = 0
        for c in 0..<ch {
            let ptr = data[c]
            for i in 0..<frames {
                let v = ptr[i]
                sum += v * v
            }
        }
        let mean = sum / Float(frames * ch)
        return sqrt(mean)
    }
}
