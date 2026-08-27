import AVFoundation
import Foundation

/// Simple WAV writer for PCM 48k/mono/Float32 -> 16-bit WAV file
/// Used for PRD-03 §10 offline test and capture dump.
public final class WAVWriter {
    private var file: AVAudioFile?
    private let url: URL
    public let format: AVAudioFormat

    public init(url: URL, sampleRate: Double = 48000, channels: AVAudioChannelCount = 1) throws {
        self.url = url
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false) else {
            throw NSError(domain: "WAVWriter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create format"])
        }
        self.format = fmt
        // AVAudioFile will create WAV if extension is .wav
        try? FileManager.default.removeItem(at: url)
        self.file = try AVAudioFile(forWriting: url, settings: fmt.settings)
    }

    public func write(buffer: AVAudioPCMBuffer) throws {
        try file?.write(from: buffer)
    }

    public func write(floats: [Float]) throws {
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(floats.count)) else { return }
        buf.frameLength = AVAudioFrameCount(floats.count)
        if let ptr = buf.floatChannelData?[0] {
            floats.withUnsafeBufferPointer { src in
                ptr.update(from: src.baseAddress!, count: floats.count)
            }
        }
        try file?.write(from: buf)
    }

    public func close() {
        file = nil
    }

    public var fileURL: URL { url }
}

public enum WAVReader {
    public static func readFloats(url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "WAVReader", code: -1)
        }
        try file.read(into: buffer)
        // convert to mono Float32 array
        var out: [Float] = []
        if let data = buffer.floatChannelData {
            let ch = Int(format.channelCount)
            let frames = Int(buffer.frameLength)
            out.reserveCapacity(frames)
            if ch == 1 {
                out.append(contentsOf: UnsafeBufferPointer(start: data[0], count: frames))
            } else {
                for i in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<ch { sum += data[c][i] }
                    out.append(sum / Float(ch))
                }
            }
        }
        return (out, format.sampleRate)
    }
}
