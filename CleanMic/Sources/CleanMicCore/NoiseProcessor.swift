import Foundation

// RNNoise C bridge deklaracije (iz Sources/CleanMicCore/include/RNNoiseBridge.h).
// Pozivamo se na cdecl konvenciju; librnnoise.a je staticki linkan kroz Package.swift.

@_silgen_name("cm_rnnoise_frame_size")
private func _cm_rnnoise_frame_size() -> Int32

@_silgen_name("cm_rnnoise_is_available")
private func _cm_rnnoise_is_available(_ err: UnsafeMutablePointer<CChar>?, _ err_len: Int32) -> Int32

@_silgen_name("cm_rnnoise_create")
private func _cm_rnnoise_create(_ err: UnsafeMutablePointer<CChar>?, _ err_len: Int32) -> OpaquePointer?

@_silgen_name("cm_rnnoise_destroy")
private func _cm_rnnoise_destroy(_ handle: OpaquePointer?)

@_silgen_name("cm_rnnoise_process_frame")
private func _cm_rnnoise_process_frame(_ handle: OpaquePointer?, _ output: UnsafeMutablePointer<Float>, _ input: UnsafePointer<Float>) -> Float

@_silgen_name("cm_rnnoise_reset")
private func _cm_rnnoise_reset(_ handle: UnsafeMutablePointer<OpaquePointer?>)

/// PRD-03 §6 — RNNoise wrapper.
/// Faza 0.5: pravi RNNoise C lib. Ako lib nije dostupan, init fatalError-uje
/// (hard fail po PRD dogovoru — nema mock fallbacka).
///
/// `CleanMicMode` vise NE utice na VAD threshold — VAD dolazi direktno iz
/// RNNoise-a. Mod samo mijenja post-process gain (warmth/agresivnost) i
/// opcioni gate za dodatno potiskivanje tisine.

public enum CleanMicMode: Int, CaseIterable, CustomStringConvertible {
    case light = 0
    case balanced = 1
    case maximum = 2

    public var description: String {
        switch self {
        case .light: return "Light"
        case .balanced: return "Balanced"
        case .maximum: return "Maximum"
        }
    }

    /// Udio RNNoise izlaza u finalnom miksu (wet/dry).
    /// 1.0 = cisti RNNoise, 0.0 = neobradjen ulaz.
    ///
    /// Ovo je GLAVNA razlika izmedju modova. Ranije su se razlikovali samo po
    /// `postGain`-u, koji mnozi cijeli frame uniformno — to mijenja glasnocu,
    /// ali ne i odnos govora prema buci, pa su sva tri moda davala identican
    /// SNR (izmjereno: 11.8 dB u sva tri). Wet/dry miks stvarno kontrolise
    /// koliko se agresivno potiskuje buka, po cijenu artefakata i gusenja
    /// govora — sto je trade-off koji izbor moda i treba da nudi.
    var wetMix: Float {
        switch self {
        // Vrijednosti su izabrane mjerenjem (sweep 0.40..1.00 na govoru sa
        // pink bukom, SNR / potiskivanje buke / vjernost cistom govoru /
        // glatkoca na granicama frameova):
        //   0.55 -> SNR 10.6 dB, buka -5.6 dB, vjernost -4.0 dB  (najprirodnije)
        //   0.85 -> SNR 12.9 dB, buka -7.5 dB, vjernost -0.6 dB  (najbolja buka)
        //   0.95 -> SNR 13.1 dB, buka -7.2 dB, vjernost +0.3 dB  (najveci SNR)
        // wet = 1.00 (cisti RNNoise) je mjerljivo losiji od 0.95 i po buci
        // (-6.9 dB) i po granicama (1.10x vs 1.02x) — zato maximum nije 1.0.
        case .light: return 0.55    // blago — cuva prirodnost glasa
        case .balanced: return 0.85 // preporuceno — najbolje potiskivanje buke
        case .maximum: return 0.95  // najagresivnije
        }
    }

    // VAD gate je uklonjen jer je mjerenjem pokazano da ne radi nista.
    // RNNoise VAD u pauzama ostaje visok (prosjek 0.655; 67 od 188 pauznih
    // frameova je u opsegu 0.9-1.0) jer rekurentna mreza zadrzava "govor"
    // stanje nakon govora. Gate je zato okidao samo na frameovima gdje je
    // VAD nizak — a to su tacno oni koje je RNNoise vec utisao na ~-55 dB.
    // Mjereno: sa pragom 0.80 i atenuacijom 0.90 gate okine na 102 od 655
    // frameova, a SNR, potiskivanje buke i glatkoca granica ostanu identicni
    // do jedne decimale. Za pravo dodatno potiskivanje u pauzama treba
    // procjena praga buke iz energije izlaza, ne RNNoise VAD.
}

public final class NoiseProcessor: @unchecked Sendable {
    /// 480 = 10ms @ 48kHz (RNNoise frame size)
    public static let frameSize: Int = 480

    private var handle: OpaquePointer?
    private var mode: CleanMicMode
    // Prealociran temp buffer za RNNoise izlaz — izbegava heap alloc po frejmu.
    // tmpIn vise ne treba: skaliranje u int16 opseg radi C bridge.
    private var tmpOut = [Float](repeating: 0, count: 480)
    /// RNNoise izlaz kasni za ulazom — izmjereno unakrsnom korelacijom na
    /// govoru: 337 uzoraka (7.02 ms), isto i na govoru sa bukom (338).
    /// Dry grana u wet/dry miksu mora biti zakasnjena za isto toliko, inace
    /// se mijesaju dvije verzije istog signala pomjerene u vremenu — to je
    /// comb filter, ne miks, i pravi diskontinuitete na granicama frameova.
    public static let rnnoiseDelay = 337
    /// Zadnjih `rnnoiseDelay` uzoraka prethodnog framea (delay line za dry).
    private var dryTail = [Float](repeating: 0, count: 337)

    public init(mode: CleanMicMode = .balanced) {
        self.mode = mode

        // Health check prije create — daje bolju poruku ako lib nije linkovan.
        var availErr = [CChar](repeating: 0, count: 256)
        let available = _cm_rnnoise_is_available(&availErr, 256)
        if available == 0 {
            let msg = String(cString: availErr)
            fatalError("[NoiseProcessor] RNNoise unavailable: \(msg). Did you run scripts/build-rnnoise.sh and link librnnoise.a?")
        }

        // Kreiraj state.
        var createErr = [CChar](repeating: 0, count: 256)
        guard let h = _cm_rnnoise_create(&createErr, 256) else {
            let msg = String(cString: createErr)
            fatalError("[NoiseProcessor] cm_rnnoise_create failed: \(msg)")
        }
        self.handle = h
        print("[NoiseProcessor] init mode=\(mode) (RNNoise C lib, frameSize=\(Self.frameSize))")
    }

    deinit {
        if let h = handle {
            _cm_rnnoise_destroy(h)
        }
    }

    public func setMode(_ mode: CleanMicMode) {
        self.mode = mode
        print("[NoiseProcessor] mode -> \(mode)")
    }

    public func reset() {
        for i in 0..<dryTail.count { dryTail[i] = 0 }
        guard handle != nil else { return }
        withUnsafeMutablePointer(to: &handle) { ptr in
            _cm_rnnoise_reset(ptr)
        }
    }

    /// Procesira jedan 480-sample frame. Ulaz/izlaz su Float32 -1..1 (AVAudio norm).
    ///
    /// Skaliranje u int16 opseg koji RNNoise trazi radi C bridge
    /// (`cm_rnnoise_process_frame`, vidi RNNoiseBridge.c). Ovdje se NAMJERNO
    /// ne skalira ponovo — dvostruko skaliranje salje RNNoise-u signal reda
    /// 2^30 i kvari mu VAD: izmjereno 0.600 na cistoj buci umjesto 0.060,
    /// uz dodatnih 7.3 dB gusenja govora.
    ///
    /// - Returns: VAD vjerovatnoca 0..1 (direktno iz `rnnoise_process_frame`)
    @discardableResult
    public func processFrame(out: UnsafeMutablePointer<Float>, input: UnsafePointer<Float>) -> Float {
        let vad: Float = tmpOut.withUnsafeMutableBufferPointer { outPtr in
            _cm_rnnoise_process_frame(handle, outPtr.baseAddress!, input)
        }

        let wet = mode.wetMix
        let dry = 1.0 - wet
        let d = Self.rnnoiseDelay

        for i in 0..<Self.frameSize {
            // Dry uzorak poravnat sa RNNoise izlazom: input[i - d], pri cemu
            // prvih d uzoraka dolazi iz repa prethodnog framea.
            let dryS = i < d ? dryTail[i] : input[i - d]
            let mixed = tmpOut[i] * wet + dryS * dry
            out[i] = min(1.0, max(-1.0, mixed))
        }

        // Sacuvaj rep ovog framea za dry delay u sljedecem.
        for i in 0..<d { dryTail[i] = input[Self.frameSize - d + i] }

        return vad
    }

    /// Swift-friendly wrapper
    public func process(input: [Float]) -> (output: [Float], vad: Float) {
        precondition(input.count == Self.frameSize, "RNNoise requires exactly 480 samples, got \(input.count)")
        var out = [Float](repeating: 0, count: Self.frameSize)
        let vad = out.withUnsafeMutableBufferPointer { outPtr in
            input.withUnsafeBufferPointer { inPtr in
                processFrame(out: outPtr.baseAddress!, input: inPtr.baseAddress!)
            }
        }
        return (out, vad)
    }
}
