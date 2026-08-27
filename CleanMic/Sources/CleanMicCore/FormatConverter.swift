import AVFoundation

/// PRD-03 §4 — Format Converter: any input -> 48k / mono / Float32
public final class FormatConverter {
    public static let targetSampleRate: Double = 48000
    public static let targetChannels: AVAudioChannelCount = 1

    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?

    public var needsConversion: Bool = true

    public init() {}

    /// Call when input format is known (from tap)
    public func configure(inputFormat: AVAudioFormat) {
        self.inputFormat = inputFormat
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: Self.targetChannels,
            interleaved: false
        ) else { return }
        self.outputFormat = outFormat

        // bypass if already matching
        if inputFormat.sampleRate == Self.targetSampleRate &&
            inputFormat.channelCount == Self.targetChannels &&
            inputFormat.commonFormat == .pcmFormatFloat32 &&
            !inputFormat.isInterleaved {
            needsConversion = false
            converter = nil
            return
        }
        needsConversion = true
        converter = AVAudioConverter(from: inputFormat, to: outFormat)
        converter?.primeMethod = .normal
    }

    public var targetFormat: AVAudioFormat? { outputFormat }

    /// Convert single buffer (for spike: alloc per call is ok, Faza 1 will preallocate)
    public func convert(buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let outputFormat = outputFormat else { return nil }
        if !needsConversion {
            return buffer
        }
        guard let converter = converter else { return nil }

        // estimate output frame capacity
        let ratio = Self.targetSampleRate / buffer.format.sampleRate
        let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outFrames) else { return nil }

        var error: NSError?
        var handed = false
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if handed {
                outStatus.pointee = .noDataNow
                return nil
            }
            handed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error || error != nil {
            // fallback: return nil
            return nil
        }
        // If converter produced 0 frames (can happen), try alternative path
        if outBuffer.frameLength == 0 {
            // manual simple path for stereo->mono averaging if sample rates match
            if buffer.format.sampleRate == Self.targetSampleRate && buffer.format.channelCount == 2 {
                return downmixToMono(buffer: buffer, targetFormat: outputFormat)
            }
        }
        return outBuffer
    }

    private func downmixToMono(buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: buffer.frameLength) else { return nil }
        out.frameLength = buffer.frameLength
        guard let inFloat = buffer.floatChannelData, let outFloat = out.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        let chCount = Int(buffer.format.channelCount)
        if chCount == 2 {
            let ch0 = inFloat[0]
            let ch1 = inFloat[1]
            let o = outFloat[0]
            for i in 0..<frames {
                o[i] = (ch0[i] + ch1[i]) * 0.5
            }
        } else if chCount == 1 {
            let ch0 = inFloat[0]
            let o = outFloat[0]
            for i in 0..<frames { o[i] = ch0[i] }
        }
        return out
    }

    /// Utility to convert raw [Float] assuming input is already target format's sample rate
    public static func monoMixIfNeeded(_ data: [Float], channelCount: Int) -> [Float] {
        guard channelCount == 2 else { return data }
        // interleaved stereo -> mono
        var out = [Float](repeating: 0, count: data.count / 2)
        for i in 0..<out.count {
            out[i] = (data[i*2] + data[i*2+1]) * 0.5
        }
        return out
    }
}
