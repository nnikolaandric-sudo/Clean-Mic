import AVFoundation
import Foundation

public enum CaptureError: Error, CustomStringConvertible {
    case noInputDevice
    case engineStartFailed(Error)
    case permissionDenied

    public var description: String {
        switch self {
        case .noInputDevice: return "No input device found"
        case .engineStartFailed(let e): return "Engine start failed: \(e)"
        case .permissionDenied: return "Microphone permission denied"
        }
    }
}

/// Faza 0 spike: AVAudioEngine capture -> PCM dump via tap.
/// PRD-03 §2.1 [1] -> [2]
public final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let converter = FormatConverter()
    private var isRunning = false

    /// Callback for converted PCM (48k/mono/Float32)
    public var onPCM: ((AVAudioPCMBuffer) -> Void)?

    /// For metrics / level meter
    public var onLevel: ((Float) -> Void)?

    public private(set) var inputFormat: AVAudioFormat?
    public private(set) var targetFormat: AVAudioFormat?

    public init() {}

    public func start(deviceID: AudioDeviceID? = nil) throws {
        // Check permission
        let perm = DeviceLister.checkMicrophonePermission()
        if perm == "denied" || perm == "restricted" {
            throw CaptureError.permissionDenied
        }

        // If deviceID provided, set as default? For spike we use default input.
        // CoreAudio default device already selected by system; HAL will follow.
        // For device-specific routing we'd need HAL IOProc (Faza 1).

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }
        self.inputFormat = format
        converter.configure(inputFormat: format)
        self.targetFormat = converter.targetFormat ?? format

        print("[AudioCapture] input: \(format) -> target: \(String(describing: targetFormat))")

        // Remove previous tap if any
        inputNode.removeTap(onBus: 0)

        // 512 frames ~10ms @48k as per PRD
        let bufferSize: AVAudioFrameCount = 512
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, time in
            guard let self = self else { return }
            // Level metering on input (quick RMS)
            if let level = self.rmsLevel(buffer: buffer) {
                self.onLevel?(level)
            }
            // Convert to target format
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

        engine.prepare()
        do {
            try engine.start()
            isRunning = true
            print("[AudioCapture] ✅ engine started")
        } catch {
            throw CaptureError.engineStartFailed(error)
        }
    }

    public func stop() {
        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRunning = false
            print("[AudioCapture] ⏹ stopped")
        }
    }

    public var running: Bool { isRunning }

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
        let rms = sqrt(mean)
        // to dB-ish 0..1
        return rms
    }
}
