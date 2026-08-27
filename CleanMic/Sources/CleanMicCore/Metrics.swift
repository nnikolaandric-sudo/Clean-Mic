import Foundation
import Darwin

public struct EngineMetrics: CustomStringConvertible {
    public var cpuPercent: Double
    public var processingAvgMs: Double
    public var processingMaxMs: Double
    public var inputUnderruns: Int
    public var outputOverruns: Int
    public var framesProcessed: Int

    public var description: String {
        """
        Metrics:
          CPU: \(String(format:"%.1f", cpuPercent))% (approx)
          Processing: avg \(String(format:"%.2f", processingAvgMs))ms max \(String(format:"%.2f", processingMaxMs))ms
          Frames: \(framesProcessed) (~\(String(format:"%.1f", Double(framesProcessed)*0.01))s)
          Input underruns: \(inputUnderruns)  Output overruns: \(outputOverruns)
        """
    }
}

public enum MetricsCollector {
    public static func cpuPercent() -> Double {
        var info = task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_basic_info>.size) / 4
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(TASK_BASIC_INFO), $0, &count)
            }
        }
        if kerr == KERN_SUCCESS {
            // resident_size not cpu; use host_statistics for cpu? For spike just return 0 and measure via processing time.
            return 0
        }
        return 0
    }

    public static func collect(inputRing: RingBuffer, outputRing: RingBuffer, engine: ProcessingEngine) -> EngineMetrics {
        EngineMetrics(
            cpuPercent: 0, // TODO: implement via task_threads + thread_info
            processingAvgMs: engine.avgProcessingMs,
            processingMaxMs: engine.maxProcessingMs,
            inputUnderruns: inputRing.underrunCount,
            outputOverruns: outputRing.overrunCount,
            framesProcessed: engine.framesProcessed
        )
    }
}
