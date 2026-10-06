import Foundation
import AVFoundation

/// PRD-03 §2.1 [3] — Processing Worker Thread
/// InputRing (from capture) -> 480-sample frames -> NoiseProcessor -> OutputRing
public final class ProcessingEngine: @unchecked Sendable {
    public let inputRing: RingBuffer
    public let outputRing: RingBuffer
    private let processor: NoiseProcessor
    private var running = false
    private var thread: Thread?

    // Metrics
    public private(set) var framesProcessed: Int = 0
    public private(set) var avgProcessingMs: Double = 0
    public private(set) var maxProcessingMs: Double = 0
    public private(set) var vadLast: Float = 0

    public var onMetrics: ((Double, Float) -> Void)? // (ms, vad)

    /// Zvuk iz računara (glasovi ostalih na sastanku), mono 48 kHz. Miješa se u izlaz
    /// poslije RNNoise-a — to je već čist zvuk i ne treba ga "čistiti" ponovo.
    /// Postavlja se prije `start()`.
    public var systemRing: RingBuffer?

    /// Najviše ovoliko zvuka iz računara smije čekati; više od toga je odmaklo od mikrofona
    /// (sat računara je malo brži od sata mikrofona) pa se višak odbaci.
    static let systemMaxLagFrames = 12_000 // 250 ms
    static let systemTargetLagFrames = 4_800 // 100 ms
    /// Prije prvog miješanja skupi malo zvuka da jitter ne napravi rupe.
    static let systemPrimeFrames = 960 // 20 ms

    /// Zbroji zvuk iz računara u frame mikrofona, uz ograničenje na ±1 (nema prelijevanja).
    static func mix(_ frame: inout [Float], with system: [Float]) {
        let n = min(frame.count, system.count)
        for i in 0..<n {
            frame[i] = max(-1, min(1, frame[i] + system[i]))
        }
    }

    /// Periodični ispis metrika. Isključeno po defaultu: snimanje sada traje
    /// satima, pa bi ispis svakih 5 s samo punio log.
    public var verbose = false

    public init(inputRing: RingBuffer, outputRing: RingBuffer, mode: CleanMicMode = .balanced) {
        self.inputRing = inputRing
        self.outputRing = outputRing
        self.processor = NoiseProcessor(mode: mode)
    }

    public func setMode(_ mode: CleanMicMode) {
        processor.setMode(mode)
    }

    public func start() {
        guard !running else { return }
        running = true
        framesProcessed = 0
        avgProcessingMs = 0
        maxProcessingMs = 0

        thread = Thread { [weak self] in
            self?.runLoop()
        }
        thread?.qualityOfService = .userInteractive
        thread?.name = "CleanMic.ProcessingWorker"
        thread?.start()
        print("[ProcessingEngine] ✅ worker started")
    }

    public func stop() {
        running = false
        // give thread time to exit
        Thread.sleep(forTimeInterval: 0.05)
        print("[ProcessingEngine] ⏹ worker stopped, frames=\(framesProcessed) avg=\(String(format:"%.2f", avgProcessingMs))ms max=\(String(format:"%.2f", maxProcessingMs))ms")
    }

    private func runLoop() {
        let frameSize = NoiseProcessor.frameSize
        var inBuf = [Float](repeating: 0, count: frameSize)
        var outBuf = [Float](repeating: 0, count: frameSize)

        var totalMs: Double = 0
        var systemBuf = [Float](repeating: 0, count: frameSize)
        var systemPrimed = false

        while running {
            // Wait until enough data
            if inputRing.availableRead < frameSize {
                // sleep ~2ms, not busy-wait
                Thread.sleep(forTimeInterval: 0.002)
                continue
            }
            // Check output space
            if outputRing.availableWrite < frameSize {
                Thread.sleep(forTimeInterval: 0.001)
                continue
            }

            guard inputRing.read(into: &inBuf, frames: frameSize) else { continue }

            let t0 = CFAbsoluteTimeGetCurrent()
            let vad: Float = inBuf.withUnsafeBufferPointer { inPtr in
                outBuf.withUnsafeMutableBufferPointer { outPtr in
                    processor.processFrame(out: outPtr.baseAddress!, input: inPtr.baseAddress!)
                }
            }
            let t1 = CFAbsoluteTimeGetCurrent()
            let ms = (t1 - t0) * 1000.0

            totalMs += ms
            framesProcessed += 1
            avgProcessingMs = totalMs / Double(framesProcessed)
            if ms > maxProcessingMs { maxProcessingMs = ms }
            vadLast = vad

            // Fail-safe: if processing took >10ms or NaN, bypass
            if ms > 10.0 || outBuf.contains(where: { $0.isNaN }) {
                // bypass: copy input directly
                outBuf = inBuf
            }

            // Zvuk iz računara: takt daje mikrofon, pa ovdje samo uzimamo jedan frame
            // ako ga ima. Nema ga → u ovom frameu je samo mikrofon (nikad ne čekamo).
            if let system = systemRing {
                var available = system.availableRead
                if available > Self.systemMaxLagFrames {
                    var drop = available - Self.systemTargetLagFrames
                    while drop > 0 {
                        let n = min(drop, frameSize)
                        guard system.read(into: &systemBuf, frames: n) else { break }
                        drop -= n
                    }
                    available = system.availableRead
                }
                if !systemPrimed, available >= Self.systemPrimeFrames { systemPrimed = true }
                if systemPrimed {
                    if available >= frameSize, system.read(into: &systemBuf, frames: frameSize) {
                        Self.mix(&outBuf, with: systemBuf)
                    } else {
                        systemPrimed = false // ponestalo — ponovo skupi malo prije miješanja
                    }
                }
            }

            // Write to output ring
            outBuf.withUnsafeBufferPointer { ptr in
                _ = outputRing.write(ptr.baseAddress!, frames: frameSize)
            }

            onMetrics?(ms, vad)

            if verbose && framesProcessed % 500 == 0 {
                print("[ProcessingEngine] frames=\(framesProcessed) avgMs=\(String(format:"%.2f", avgProcessingMs)) maxMs=\(String(format:"%.2f", maxProcessingMs)) vad=\(String(format:"%.2f", vad))")
            }
        }
    }
}
