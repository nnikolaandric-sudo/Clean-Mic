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

    /// Post-process gain nakon RNNoise-a. RNNoise sam po sebi daje ~0dB pass-through
    /// na govoru, a ~-30dB na buci, tako da 'light' ostavlja izlaz netaknut,
    /// 'balanced' blago utise za topliji zvuk, 'maximum' jos vise.
    var postGain: Float {
        switch self {
        case .light: return 1.00
        case .balanced: return 0.92
        case .maximum: return 0.82
        }
    }

    /// Prag ispod kojeg RNNoise VAD tretiramo kao "nema govora".
    /// Iznad ovoga pustamo audio netaknut, ispod dodatno utisavamo.
    var vadGateThreshold: Float {
        switch self {
        case .light: return 0.10
        case .balanced: return 0.20
        case .maximum: return 0.35
        }
    }

    /// Koliko dodatno utisavamo kad je VAD ispod praga (0..1, linearno).
    var vadGateAttenuation: Float {
        switch self {
        case .light: return 0.0   // nema gate-a
        case .balanced: return 0.25
        case .maximum: return 0.50
        }
    }
}

public final class NoiseProcessor: @unchecked Sendable {
    /// 480 = 10ms @ 48kHz (RNNoise frame size)
    public static let frameSize: Int = 480

    private var handle: OpaquePointer?
    private var mode: CleanMicMode
    // Prealocirani temp bufferi za skaliranje (-1..1 <-> int16) — izbegava heap alloc po frejmu
    private var tmpIn = [Float](repeating: 0, count: 480)
    private var tmpOut = [Float](repeating: 0, count: 480)

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
        guard handle != nil else { return }
        withUnsafeMutablePointer(to: &handle) { ptr in
            _cm_rnnoise_reset(ptr)
        }
    }

    /// Procesira jedan 480-sample frame. Ulaz/izlaz su Float32 -1..1 (AVAudio norm).
    /// RNNoise interno ocekuje int16 skalu (-32768..32767) kao float — zato
    /// skaliramo *32768 pre i /32768 posle poziva (vidi rnnoise/examples/rnnoise_demo.c).
    /// - Returns: VAD vjerovatnoca 0..1 (direktno iz `rnnoise_process_frame`)
    @discardableResult
    public func processFrame(out: UnsafeMutablePointer<Float>, input: UnsafePointer<Float>) -> Float {
        // Skaliraj ulaz u int16 opseg za RNNoise (reuse tmpIn/tmpOut da nema alloc)
        for i in 0..<Self.frameSize {
            tmpIn[i] = input[i] * 32768.0
        }
        let vad: Float = tmpIn.withUnsafeBufferPointer { inPtr in
            tmpOut.withUnsafeMutableBufferPointer { outPtr in
                _cm_rnnoise_process_frame(handle, outPtr.baseAddress!, inPtr.baseAddress!)
            }
        }
        // Vrati u -1..1 opseg
        for i in 0..<Self.frameSize {
            let v = tmpOut[i] / 32768.0
            out[i] = min(1.0, max(-1.0, v))
        }

        // Post-processing: mode-ovani gain + opcioni VAD gate.
        // Gate je samo sigurnosna mreza; RNNoise-ov izlaz je vec dosta cist.
        let gateThreshold = mode.vadGateThreshold
        let gateAtten = mode.vadGateAttenuation
        let postGain = mode.postGain

        if gateAtten > 0 && vad < gateThreshold {
            // Primijeni gate: linearna interpolacija izmedju (1-gateAtten) pri
            // vad=0 i 1.0 pri vad=gateThreshold.
            let t = max(0, min(1, vad / gateThreshold))
            let frameGain = (1.0 - gateAtten) + gateAtten * t
            for i in 0..<Self.frameSize {
                out[i] *= frameGain * postGain
            }
        } else {
            // Nema gate-a, samo post gain.
            if postGain != 1.0 {
                for i in 0..<Self.frameSize {
                    out[i] *= postGain
                }
            }
        }
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
