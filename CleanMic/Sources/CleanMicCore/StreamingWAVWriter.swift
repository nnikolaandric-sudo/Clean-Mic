import Foundation

/// 16-bit PCM WAV za duga snimanja (snima dok se ne zaustavi).
///
/// Zašto ne `WAVWriter` (AVAudioFile, Float32):
///  - Float32 48k je 691 MB/h; 16-bit je 346 MB/h, a za govor se razlika ne čuje.
///  - AVAudioFile upisuje veličinu u header tek na zatvaranju. Ako app padne ili
///    se Mac ugasi nakon dva sata snimanja, fajl ostane sa praznim headerom.
///    Ovdje se header osvježava svakih par sekundi, pa je snimak čitljiv do
///    zadnjeg osvježenja šta god da se desi.
public final class StreamingWAVWriter {
    public enum WriteError: Error, CustomStringConvertible {
        case cannotCreate(String)
        case closed

        public var description: String {
            switch self {
            case .cannotCreate(let p): return "Ne mogu napraviti fajl: \(p)"
            case .closed: return "Fajl je već zatvoren"
            }
        }
    }

    public let url: URL
    public let sampleRate: Int
    public let channels: Int
    public private(set) var framesWritten: Int64 = 0

    /// WAV data chunk je UInt32 — ne može preko 4 GB. Uz 48k/mono/16-bit to je ~12.4 h.
    public static let maxDataBytes: Int64 = 0xFFFF_FFFF - 16 * 1024 * 1024

    private static let headerSize = 44
    private var handle: FileHandle?
    private var pending = Data()
    private var framesAtLastHeader: Int64 = 0
    private var framesFlushed: Int64 = 0

    public init(url: URL, sampleRate: Int = 48000, channels: Int = 1) throws {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: Self.header(dataBytes: 0, sampleRate: sampleRate, channels: channels)) else {
            throw WriteError.cannotCreate(url.path)
        }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        self.handle = h
        pending.reserveCapacity(96 * 1024)
    }

    deinit { close() }

    public var duration: Double { Double(framesWritten) / Double(sampleRate) }
    public var dataBytes: Int64 { framesWritten * Int64(channels) * 2 }
    public var isAtSizeLimit: Bool { dataBytes >= Self.maxDataBytes }

    /// Float -1..1 → int16 LE. Bafere se u memoriji; `flush()` upisuje na disk.
    public func write(_ samples: UnsafePointer<Float>, count: Int) throws {
        guard handle != nil else { throw WriteError.closed }
        guard count > 0 else { return }
        var block = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let v = max(-1, min(1, samples[i]))
            block[i] = Int16((v * 32767).rounded()).littleEndian
        }
        block.withUnsafeBufferPointer { pending.append($0) }
        framesWritten += Int64(count / channels)
        if pending.count >= 64 * 1024 { try flush() }
    }

    public func write(_ samples: [Float]) throws {
        try samples.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            try write(base, count: samples.count)
        }
    }

    /// Upiši baferovano na disk; header se osvježava najviše jednom u 5 s.
    public func flush() throws {
        guard let h = handle else { throw WriteError.closed }
        if !pending.isEmpty {
            try h.write(contentsOf: pending)
            pending.removeAll(keepingCapacity: true)
            framesFlushed = framesWritten
        }
        if framesFlushed - framesAtLastHeader >= Int64(sampleRate) * 5 {
            try patchHeader()
        }
    }

    public func close() {
        guard handle != nil else { return }
        try? flush()
        try? patchHeader()
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
    }

    private func patchHeader() throws {
        guard let h = handle else { return }
        let bytes = framesFlushed * Int64(channels) * 2
        try h.seek(toOffset: 0)
        try h.write(contentsOf: Self.header(dataBytes: bytes, sampleRate: sampleRate, channels: channels))
        try h.seekToEnd()
        framesAtLastHeader = framesFlushed
    }

    static func header(dataBytes: Int64, sampleRate: Int, channels: Int) -> Data {
        let size = UInt32(clamping: dataBytes)
        let byteRate = UInt32(sampleRate * channels * 2)
        var d = Data(capacity: headerSize)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8))
        u32(UInt32(clamping: Int64(size) + 36))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        u32(16)                          // fmt chunk size
        u16(1)                           // PCM
        u16(UInt16(channels))
        u32(UInt32(sampleRate))
        u32(byteRate)
        u16(UInt16(channels * 2))        // block align
        u16(16)                          // bits per sample
        d.append(contentsOf: Array("data".utf8))
        u32(size)
        return d
    }
}
