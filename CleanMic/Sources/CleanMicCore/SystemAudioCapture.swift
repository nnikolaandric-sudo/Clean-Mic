import AVFoundation
import CoreAudio
import Foundation

/// Kad se uz mikrofon snima i zvuk koji izlazi iz računara (glasovi ostalih na online sastanku).
///
/// Zašto postoji: mikrofon čuje samo ono što uđe u sobu. Sa zvučnicima to uključuje i
/// glasove ostalih učesnika, ali sa slušalicama NE — oni idu direktno u uši, pa transkript
/// ostane bez pola sastanka, a izvještaj svejedno izgleda uvjerljivo.
///
/// - `auto`:   zvuk iz računara se snima samo dok su slušalice (Bluetooth, USB, priključak).
///             Na zvučnicima bi isti glas stigao dvaput (iz računara i iz mikrofona = jeka).
/// - `always`: uvijek (npr. zvučnik koji je prepoznat kao slušalice, a nije).
/// - `never`:  samo mikrofon, kao prije.
public enum SystemAudioMode: String, CaseIterable, Sendable {
    case auto
    case always
    case never

    public var title: String {
        switch self {
        case .auto: return "Automatski (kad su slušalice)"
        case .always: return "Uvijek"
        case .never: return "Nikad (samo mikrofon)"
        }
    }
}

/// Šta je trenutno izlaz zvuka: slušalice ili zvučnici.
public struct OutputRoute: Equatable, Sendable {
    public let deviceID: AudioDeviceID
    public let uid: String
    public let name: String
    public let isHeadphones: Bool
}

public enum OutputRouteDetector {
    /// Zadani izlazni uređaj, ili nil ako ga nema.
    public static func current() -> OutputRoute? {
        guard let id = defaultOutputDeviceID(),
              let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let name = stringProperty(id, kAudioObjectPropertyName) ?? "izlaz"
        return OutputRoute(deviceID: id, uid: uid, name: name, isHeadphones: isHeadphones(id))
    }

    public static func defaultOutputDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// Bluetooth i USB uređaji su slušalice/headset; ugrađeni izlaz samo ako je u priključku
    /// za slušalice. HDMI/DisplayPort/AirPlay i ugrađeni zvučnici NISU slušalice.
    static func isHeadphones(_ id: AudioDeviceID) -> Bool {
        let transport = uint32Property(id, kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal)
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeUSB:
            return true
        case kAudioDeviceTransportTypeBuiltIn:
            // Izvor ugrađenog izlaza: 'hdpn' = priključak za slušalice, 'ispk' = zvučnici.
            let source = uint32Property(id, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)
            return source == fourCC("hdpn")
        default:
            return false
        }
    }

    static func fourCC(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func uint32Property(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                       scope: AudioObjectPropertyScope) -> UInt32 {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        return value
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        let s = value.takeRetainedValue() as String
        return s.isEmpty ? nil : s
    }
}

/// Upravlja snimanjem zvuka iz računara: prati izlaz (slušalice ↔ zvučnici), diže i spušta
/// Core Audio tap, i sam se oporavlja kad se promijeni uređaj ili format.
/// Isporučuje mono 48 kHz Float32 kroz `onPCM`.
public final class SystemAudioCapture: @unchecked Sendable {
    public static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    /// Prvo podizanje taba sa novim potpisom aplikacije traje ~5 s (macOS tada provjerava
    /// dozvolu i, ako je treba, pita korisnika); svako sljedeće ~0,1 s. Ovo ga odradi unaprijed,
    /// u pozadini, da se početak sastanka ne izgubi.
    public static func prime() {
        guard #available(macOS 14.2, *), let route = OutputRouteDetector.current() else { return }
        DispatchQueue.global(qos: .utility).async {
            let started = CFAbsoluteTimeGetCurrent()
            let tap = ProcessTap()
            do {
                try tap.start(outputUID: route.uid)
                tap.stop()
                DebugLog.log(String(format: "zvuk iz računara: zagrijavanje gotovo za %.1f s", CFAbsoluteTimeGetCurrent() - started))
            } catch {
                tap.stop()
                DebugLog.log("zvuk iz računara: zagrijavanje nije uspjelo (\(error))")
            }
        }
    }

    /// Mono, 48 kHz, Float32. Poziva se sa audio niti.
    public var onPCM: ((UnsafePointer<Float>, Int) -> Void)?
    /// Kratka poruka za korisnika (npr. "Slušalice … snimam i zvuk iz računara").
    public var onNotice: ((String) -> Void)?

    private let mode: SystemAudioMode
    private let queue = DispatchQueue(label: "cleanmic.systemaudio")
    private let lock = NSLock()

    // Stanje (queue)
    private var running = false
    private var tap: Any? // ProcessTap (macOS 14.2+)
    private var tapRoute: OutputRoute?
    private var watchdog: DispatchSourceTimer?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var pendingEvaluate: DispatchWorkItem?
    private var failedAttempts = 0
    private var lastFailure: String?

    // Dijeli se sa audio niti (lock)
    private var lastCallback: CFAbsoluteTime = 0
    private var peak: Float = 0
    private var everHeard = false
    private var everActive = false

    public init(mode: SystemAudioMode) {
        self.mode = mode
    }

    /// Je li tap trenutno uključen (slušalice ili `always`).
    public var isActive: Bool { lock.withLock { activeFlag } }
    private var activeFlag = false

    /// Je li ikad stigao čujan zvuk (iznad −60 dBFS). Ako je tap radio cijelo snimanje,
    /// a ovo je false: ili niko nije govorio, ili macOS nije dao dozvolu (tap tada šuti).
    public var heardAudio: Bool { lock.withLock { everHeard } }
    public var wasEverActive: Bool { lock.withLock { everActive } }

    /// Vršna vrijednost od zadnjeg poziva (za mjerač nivoa).
    public func takePeak() -> Float {
        lock.withLock { let p = peak; peak = 0; return p }
    }

    public func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.installOutputListener()
            self.startWatchdog()
            self.evaluate(reason: "start")
        }
    }

    public func stop() {
        // sync: nakon povratka niko više ne zove onPCM.
        queue.sync {
            guard running else { return }
            running = false
            pendingEvaluate?.cancel()
            pendingEvaluate = nil
            watchdog?.cancel()
            watchdog = nil
            removeOutputListener()
            stopTap()
        }
    }

    // MARK: - Odluka: treba li tap

    /// Odluka "treba li tap" — izdvojeno da se može provjeriti bez uređaja.
    static func wants(mode: SystemAudioMode, route: OutputRoute?) -> Bool {
        switch mode {
        case .never: return false
        case .always: return route != nil
        case .auto: return route?.isHeadphones == true
        }
    }

    private func shouldCapture(route: OutputRoute?) -> Bool {
        Self.wants(mode: mode, route: route)
    }

    private func evaluate(reason: String) {
        guard running else { return }
        let route = OutputRouteDetector.current()
        let want = shouldCapture(route: route)

        if want, let route {
            if tap != nil, tapRoute == route { return }
            if tap != nil { stopTap() }
            startTap(route: route, reason: reason)
        } else if tap != nil {
            stopTap()
            if let route {
                notice("\(route.name): zvučnici — snimam samo mikrofon")
            } else {
                notice("Nema izlaznog uređaja — snimam samo mikrofon")
            }
        } else if reason == "start", let route {
            DebugLog.log("zvuk iz računara: isključen (\(route.name) nije slušalica, mod \(mode.rawValue))")
        }
    }

    private func notice(_ text: String) {
        DebugLog.log("zvuk iz računara: \(text)")
        onNotice?(text)
    }

    /// HAL zna poslati rafal notifikacija za jednu promjenu izlaza.
    private func scheduleEvaluate(reason: String) {
        pendingEvaluate?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.evaluate(reason: reason) }
        pendingEvaluate = work
        queue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: - Tap

    private func startTap(route: OutputRoute, reason: String) {
        guard #available(macOS 14.2, *) else { return }
        let tap = ProcessTap()
        tap.onPCM = { [weak self] ptr, n in self?.deliver(ptr, n) }
        let started = CFAbsoluteTimeGetCurrent()
        do {
            try tap.start(outputUID: route.uid)
            self.tap = tap
            DebugLog.log(String(format: "zvuk iz računara: tap pokrenut za %.2f s (%@)", CFAbsoluteTimeGetCurrent() - started, reason))
            tapRoute = route
            failedAttempts = 0
            lastFailure = nil
            lock.withLock {
                lastCallback = CFAbsoluteTimeGetCurrent()
                activeFlag = true
                everActive = true
            }
            notice(route.isHeadphones
                   ? "\(route.name): slušalice — snimam i zvuk iz računara"
                   : "\(route.name) — snimam i zvuk iz računara")
        } catch {
            tap.stop()
            failedAttempts += 1
            let text = "\(error)"
            // Isti kvar ne punimo u log svake 2 s.
            if text != lastFailure {
                lastFailure = text
                DebugLog.log("zvuk iz računara: tap nije uspio (\(text)) — probat ću ponovo")
                onNotice?("Zvuk iz računara nije dostupan (\(text)) — snimam samo mikrofon")
            }
            scheduleEvaluate(reason: "ponovni pokušaj")
        }
    }

    private func stopTap() {
        if #available(macOS 14.2, *), let t = tap as? ProcessTap {
            t.onPCM = nil
            t.stop()
        }
        tap = nil
        tapRoute = nil
        lock.withLock { activeFlag = false }
    }

    /// Sa audio niti taba.
    private func deliver(_ ptr: UnsafePointer<Float>, _ frames: Int) {
        var p: Float = 0
        for i in 0..<frames { p = max(p, abs(ptr[i])) }
        lock.withLock {
            lastCallback = CFAbsoluteTimeGetCurrent()
            if p > peak { peak = p }
            if p > 0.001 { everHeard = true }
        }
        onPCM?(ptr, frames)
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.watchdogTick() }
        watchdog = timer
        timer.resume()
    }

    private func watchdogTick() {
        guard running else { return }
        // Izlaz se promijenio a notifikacija je zakasnila (ili je ispala)?
        let route = OutputRouteDetector.current()
        if route != tapRoute || (tap == nil && shouldCapture(route: route)) {
            evaluate(reason: "watchdog: promjena izlaza")
            return
        }
        guard #available(macOS 14.2, *), let t = tap as? ProcessTap else { return }

        let age = CFAbsoluteTimeGetCurrent() - lock.withLock { lastCallback }
        if age > 3 {
            DebugLog.log("zvuk iz računara: nema bufera \(Int(age)) s — restart")
            restartTap(reason: "nema bufera")
        } else if t.formatChanged() {
            // Slušalice su prešle u telefonski profil (ili nazad): drugi sample rate.
            DebugLog.log("zvuk iz računara: format izlaza se promijenio — restart")
            restartTap(reason: "promjena formata")
        }
    }

    private func restartTap(reason: String) {
        guard let route = tapRoute ?? OutputRouteDetector.current() else { return }
        stopTap()
        startTap(route: route, reason: reason)
    }

    // MARK: - Promjena izlaza (HAL)

    private func installOutputListener() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.queue.async { self?.scheduleEvaluate(reason: "promjena izlaza") }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block) == noErr {
            outputListener = block
        }
    }

    private func removeOutputListener() {
        guard let block = outputListener else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
        outputListener = nil
    }
}

// MARK: - Core Audio process tap (macOS 14.2+)

enum SystemAudioError: Error, CustomStringConvertible {
    case status(String, OSStatus)
    case unsupportedFormat(String)

    var description: String {
        switch self {
        case .status(let what, let code): return "\(what): \(code)"
        case .unsupportedFormat(let s): return "nepodržan format \(s)"
        }
    }
}

/// Globalni tap svega što računar pušta, kroz privatni aggregate device.
/// Dozvola: macOS pita jednom ("snimanje zvuka sistema"); bez nje tap šuti, ne javlja grešku.
@available(macOS 14.2, *)
final class ProcessTap: @unchecked Sendable {
    var onPCM: ((UnsafePointer<Float>, Int) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "cleanmic.systemaudio.io", qos: .userInteractive)

    private var format = AudioStreamBasicDescription()
    private var interleaved = true
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
                                       channels: 1, interleaved: false)!
    private var mono = [Float](repeating: 0, count: 8192)

    func start(outputUID: String) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "CleanMic zvuk iz računara"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw SystemAudioError.status("AudioHardwareCreateProcessTap", status) }

        format = try readTapFormat()
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32, format.mChannelsPerFrame > 0, format.mSampleRate > 0 else {
            throw SystemAudioError.unsupportedFormat("\(format.mSampleRate) Hz, \(format.mChannelsPerFrame) ch, \(format.mBitsPerChannel) bit")
        }
        interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        try prepareConverter()

        let aggregateUID = UUID().uuidString
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "CleanMic zvuk iz računara",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregateID)
        guard status == noErr else { throw SystemAudioError.status("AudioHardwareCreateAggregateDevice", status) }

        status = AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, ioQueue) { [weak self] _, input, _, _, _ in
            self?.handle(input)
        }
        guard status == noErr, ioProc != nil else { throw SystemAudioError.status("AudioDeviceCreateIOProcID", status) }

        status = AudioDeviceStart(aggregateID, ioProc)
        guard status == noErr else { throw SystemAudioError.status("AudioDeviceStart", status) }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProc {
                AudioDeviceStop(aggregateID, ioProc)
                AudioDeviceDestroyIOProcID(aggregateID, ioProc)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        ioProc = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Je li tap sada u drugom formatu nego kad je pokrenut?
    func formatChanged() -> Bool {
        guard tapID != kAudioObjectUnknown, let now = try? readTapFormat() else { return false }
        return now.mSampleRate != format.mSampleRate || now.mChannelsPerFrame != format.mChannelsPerFrame
    }

    private func readTapFormat() throws -> AudioStreamBasicDescription {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard status == noErr else { throw SystemAudioError.status("kAudioTapPropertyFormat", status) }
        return asbd
    }

    private func prepareConverter() throws {
        converter = nil
        sourceFormat = nil
        guard format.mSampleRate != 48000 else { return }
        guard let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.mSampleRate,
                                      channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: src, to: target) else {
            throw SystemAudioError.unsupportedFormat("resampling \(format.mSampleRate) → 48000")
        }
        sourceFormat = src
        converter = conv
    }

    // MARK: - Audio nit

    private func handle(_ input: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard list.count > 0 else { return }

        // Svedi na mono (srednja vrijednost kanala), na izvornom sample rateu.
        let frames: Int
        if interleaved {
            let channels = max(Int(list[0].mNumberChannels), 1)
            frames = Int(list[0].mDataByteSize) / (MemoryLayout<Float>.size * channels)
            guard frames > 0, let data = list[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            ensureCapacity(frames)
            if channels == 1 {
                mono.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: data, count: frames) }
            } else {
                let scale = 1 / Float(channels)
                for i in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels { sum += data[i * channels + c] }
                    mono[i] = sum * scale
                }
            }
        } else {
            frames = Int(list[0].mDataByteSize) / MemoryLayout<Float>.size
            guard frames > 0 else { return }
            ensureCapacity(frames)
            let scale = 1 / Float(list.count)
            for i in 0..<frames { mono[i] = 0 }
            for buffer in list {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let n = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
                for i in 0..<n { mono[i] += data[i] * scale }
            }
        }

        guard let converter, let sourceFormat else {
            mono.withUnsafeBufferPointer { onPCM?($0.baseAddress!, frames) }
            return
        }

        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        inBuffer.frameLength = AVAudioFrameCount(frames)
        mono.withUnsafeBufferPointer { inBuffer.floatChannelData![0].update(from: $0.baseAddress!, count: frames) }

        let ratio = target.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio) + 32
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        // Bafer se predaje samo jednom; vraćen drugi put converter ga potroši dvaput.
        var handed = false
        var error: NSError?
        converter.convert(to: outBuffer, error: &error) { _, status in
            if handed {
                status.pointee = .noDataNow
                return nil
            }
            handed = true
            status.pointee = .haveData
            return inBuffer
        }
        guard error == nil, outBuffer.frameLength > 0, let out = outBuffer.floatChannelData?[0] else { return }
        onPCM?(out, Int(outBuffer.frameLength))
    }

    private func ensureCapacity(_ frames: Int) {
        if mono.count < frames { mono = [Float](repeating: 0, count: frames) }
    }
}
