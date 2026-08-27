import Foundation
import AVFoundation
import CleanMicCore

func printUsage() {
    print("""
    CleanMic CLI — Faza 0 Spike (lokalno testiranje bez virtualnog drivera)

    KORIŠTENJE:
      cleanmic-cli list                          — lista input uređaja
      cleanmic-cli record [sec] [out.wav]        — snimi raw mic -> WAV (default 5s)
      cleanmic-cli record-processed [sec] [out.wav] --mode light|balanced|maximum
                                             — snimi mic -> RNNoise -> WAV
      cleanmic-cli process <in.wav> <out.wav> [--mode MODE]
                                                 — offline WAV -> WAV kroz NoiseProcessor
      cleanmic-cli test-rings                    — stress test RingBuffer
      cleanmic-cli help

    PRIMJERI:
      cleanmic-cli list
      cleanmic-cli record 5 /tmp/raw.wav
      cleanmic-cli record-processed 10 /tmp/clean.wav --mode balanced
      cleanmic-cli process /tmp/raw.wav /tmp/clean.wav --mode maximum
    """)
}

let args = CommandLine.arguments.dropFirst().map { $0 }

if args.isEmpty || args.first == "help" || args.first == "--help" || args.first == "-h" {
    printUsage()
    exit(0)
}

switch args.first! {
case "list":
    runList()
case "record":
    let sec = args.count > 1 ? Double(args[1]) ?? 5 : 5
    let out = args.count > 2 ? args[2] : "/tmp/cleanmic_raw_\(Int(Date().timeIntervalSince1970)).wav"
    runRecord(seconds: sec, outputPath: out, processed: false, mode: .balanced)
case "record-processed":
    var sec: Double = 10
    var out = "/tmp/cleanmic_processed_\(Int(Date().timeIntervalSince1970)).wav"
    var mode = CleanMicMode.balanced
    if args.count > 1, let s = Double(args[1]) { sec = s }
    if args.count > 2 && !args[2].hasPrefix("--") { out = args[2] }
    if let mIdx = args.firstIndex(where: { $0 == "--mode" || $0 == "-m" }), args.count > mIdx+1 {
        mode = parseMode(args[mIdx+1])
    }
    runRecord(seconds: sec, outputPath: out, processed: true, mode: mode)
case "process":
    guard args.count >= 3 else {
        print("❌ process zahtijeva <in.wav> <out.wav>")
        printUsage()
        exit(1)
    }
    var mode = CleanMicMode.balanced
    if let mIdx = args.firstIndex(where: { $0 == "--mode" }), args.count > mIdx+1 {
        mode = parseMode(args[mIdx+1])
    }
    runOfflineProcess(inPath: args[1], outPath: args[2], mode: mode)
case "test-rings":
    runRingTest()
default:
    print("❌ Nepoznata komanda: \(args.first!)")
    printUsage()
    exit(1)
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
}

func runRecord(seconds: Double, outputPath: String, processed: Bool, mode: CleanMicMode) {
    print("🎙  CleanMic Record\(processed ? " + Processed(\(mode))" : "") — \(seconds)s -> \(outputPath)")

    // Check permission
    let perm = DeviceLister.checkMicrophonePermission()
    print("   Permission: \(perm)")
    if perm == "denied" || perm == "restricted" {
        print("❌ Mikrofon permission denied. Odobri u System Settings -> Privacy & Security -> Microphone")
        exit(1)
    }
    if perm == "notDetermined" {
        print("   ℹ︎  Tražim dozvolu...")
        let sem = DispatchSemaphore(value: 0)
        var granted = false
        DeviceLister.requestMicrophonePermission { g in granted = g; sem.signal() }
        sem.wait()
        if !granted {
            print("❌ Permission denied")
            exit(1)
        }
        Thread.sleep(forTimeInterval: 0.5)
    }

    let outURL = URL(fileURLWithPath: outputPath)
    let capture = AudioCapture()
    var writer: WAVWriter?

    // For processed mode: setup rings + engine
    var inputRing: RingBuffer?
    var outputRing: RingBuffer?
    var procEngine: ProcessingEngine?

    var rawWriter: WAVWriter? // fallback
    var processedWriter: WAVWriter?

    // Setup writers lazy after we know format
    let startSem = DispatchSemaphore(value: 0)
    var started = false
    var startError: Error?

    // We need to handle first PCM to create writer
    capture.onPCM = { buffer in
        // First buffer: create writer
        if writer == nil && rawWriter == nil && processedWriter == nil {
            if processed {
                // For processed: feed inputRing, don't write directly
                // Also create processed writer for outputRing drain
                return
            } else {
                do {
                    let w = try WAVWriter(url: outURL, sampleRate: buffer.format.sampleRate, channels: buffer.format.channelCount)
                    writer = w
                    print("   📝 Writer: \(buffer.format) -> \(outURL.path)")
                } catch {
                    print("❌ Writer error: \(error)")
                }
            }
        }
        if !processed {
            try? writer?.write(buffer: buffer)
        }
        // Level logging every ~1s
    }

    // If processed: inputRing -> procEngine -> outputRing -> writer
    if processed {
        inputRing = RingBuffer(capacityFrames: 16384)
        outputRing = RingBuffer(capacityFrames: 16384)
        procEngine = ProcessingEngine(inputRing: inputRing!, outputRing: outputRing!, mode: mode)

        // capture feeds inputRing
        capture.onPCM = { buffer in
            guard let data = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let ch = Int(buffer.format.channelCount)
            // Convert to mono if needed (already converted to 48k/mono by capture's converter)
            // For spike, assume capture already 48k/mono Float32
            // So just copy channel 0
            if ch >= 1 {
                inputRing?.write(data[0], frames: frames)
            }
        }

        // Drain outputRing to file in separate timer
        procEngine?.start()
    }

    // Start capture
    do {
        try capture.start()
        started = true
    } catch {
        startError = error
    }

    if let e = startError {
        print("❌ Start failed: \(e)")
        // Show devices for debug
        runList()
        exit(1)
    }

    // Progress + writer setup for processed
    if processed {
        // Need to poll outputRing and write to file
        // Create writer with target format 48k/mono
        do {
            processedWriter = try WAVWriter(url: outURL, sampleRate: 48000, channels: 1)
            print("   📝 Processed writer: 48k/mono -> \(outURL.path)")
        } catch {
            print("❌ Writer error: \(error)")
            exit(1)
        }

        // Background drain
        let drainQueue = DispatchQueue(label: "drain")
        var draining = true
        drainQueue.async {
            var tmp = [Float](repeating: 0, count: NoiseProcessor.frameSize)
            while draining || (outputRing?.availableRead ?? 0) > 0 {
                if (outputRing?.availableRead ?? 0) >= NoiseProcessor.frameSize {
                    let ok = outputRing?.read(into: &tmp, frames: NoiseProcessor.frameSize) ?? false
                    if ok {
                        try? processedWriter?.write(floats: tmp)
                    }
                } else {
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
            print("   drain finished")
        }

        // Timer for progress
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            let elapsed = Date().timeIntervalSince(start)
            let remaining = seconds - elapsed
            let availIn = inputRing?.availableRead ?? 0
            let availOut = outputRing?.availableRead ?? 0
            let frames = procEngine?.framesProcessed ?? 0
            print(String(format: "   ⏱  %.1f/%.1fs  inRing:%5d outRing:%5d frames:%5d vad:%.2f avgMs:%.2f",
                         elapsed, seconds, availIn, availOut, frames, procEngine?.vadLast ?? 0, procEngine?.avgProcessingMs ?? 0), terminator: "\r")
            fflush(stdout)
            Thread.sleep(forTimeInterval: 0.1)
        }
        print("")
        draining = false
        // let drain finish
        Thread.sleep(forTimeInterval: 0.3)
        capture.stop()
        procEngine?.stop()
        processedWriter?.close()

        // Metrics
        if let ir = inputRing, let or = outputRing, let pe = procEngine {
            let m = MetricsCollector.collect(inputRing: ir, outputRing: or, engine: pe)
            print(m.description)
        }
        drainQueue.sync { }

    } else {
        // Raw mode: simple sleep
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            let elapsed = Date().timeIntervalSince(start)
            print(String(format: "   ⏱  %.1f/%.1fs recording...", elapsed, seconds), terminator: "\r")
            fflush(stdout)
            Thread.sleep(forTimeInterval: 0.1)
        }
        print("")
        capture.stop()
        writer?.close()
    }

    // Verify file
    if let attrs = try? FileManager.default.attributesOfItem(atPath: outURL.path), let size = attrs[.size] as? UInt64 {
        print("✅ Snimljeno: \(outURL.path) (\(size) bytes, \(String(format:"%.1f", Double(size)/1024)) KB)")
        // Try to read back
        do {
            let file = try AVAudioFile(forReading: outURL)
            print("   File: \(file.processingFormat) frames=\(file.length) duration=\(String(format:"%.2f", Double(file.length)/file.processingFormat.sampleRate))s")
        } catch {
            print("   ⚠️  Ne mogu pročitati file: \(error)")
        }
        print("   ▶️  Play: afplay \"\(outURL.path)\"  ili  open \"\(outURL.path)\"")
    } else {
        print("❌ File nije kreiran ili prazan")
    }
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

        var t0 = CFAbsoluteTimeGetCurrent()
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
