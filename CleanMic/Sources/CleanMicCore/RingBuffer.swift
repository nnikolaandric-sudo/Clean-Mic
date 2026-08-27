import Foundation

/// Swift port of PRD-03 §5 RingBuffer spec.
/// Faza 0 spike: thread-safe cirkularni buffer sa NSLock.
/// TODO Faza 1: zamijeniti sa lock-free SPSC C++ implementacijom (RingBuffer.hpp) sa atomics.
public final class RingBuffer: @unchecked Sendable {
    private var buffer: UnsafeMutablePointer<Float>
    private let capacity: Int
    private var head: Int = 0 // write position
    private var tail: Int = 0 // read position
    private var count: Int = 0
    private let lock = NSLock()

    // Metrics
    public private(set) var overrunCount: Int = 0
    public private(set) var underrunCount: Int = 0

    public init(capacityFrames: Int) {
        // round to power-of-two for future lock-free version
        let pow2 = RingBuffer.nextPowerOfTwo(capacityFrames)
        self.capacity = pow2
        self.buffer = UnsafeMutablePointer<Float>.allocate(capacity: pow2)
        self.buffer.initialize(repeating: 0, count: pow2)
    }

    deinit {
        buffer.deinitialize(count: capacity)
        buffer.deallocate()
    }

    public func reset() {
        lock.lock()
        head = 0
        tail = 0
        count = 0
        overrunCount = 0
        underrunCount = 0
        lock.unlock()
    }

    public var availableRead: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    public var availableWrite: Int {
        lock.lock()
        defer { lock.unlock() }
        return capacity - count
    }

    /// Write frames. Returns false if not enough space (overrun).
    @discardableResult
    public func write(_ data: UnsafePointer<Float>, frames: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard frames <= capacity - count else {
            overrunCount += 1
            return false
        }
        let firstChunk = min(frames, capacity - head)
        buffer.advanced(by: head).update(from: data, count: firstChunk)
        let remaining = frames - firstChunk
        if remaining > 0 {
            buffer.update(from: data.advanced(by: firstChunk), count: remaining)
        }
        head = (head + frames) % capacity
        count += frames
        return true
    }

    /// Convenience for [Float]
    @discardableResult
    public func write(_ data: [Float]) -> Bool {
        data.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return false }
            return write(base, frames: data.count)
        }
    }

    /// Read frames. Returns false if not enough data (underrun).
    @discardableResult
    public func read(into out: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard frames <= count else {
            underrunCount += 1
            return false
        }
        let firstChunk = min(frames, capacity - tail)
        out.update(from: buffer.advanced(by: tail), count: firstChunk)
        let remaining = frames - firstChunk
        if remaining > 0 {
            out.advanced(by: firstChunk).update(from: buffer, count: remaining)
        }
        tail = (tail + frames) % capacity
        count -= frames
        return true
    }

    public func read(into array: inout [Float], frames: Int) -> Bool {
        guard array.count >= frames else { return false }
        return array.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return false }
            return read(into: base, frames: frames)
        }
    }

    /// Peek without consuming (for metrics)
    public func peek(count frames: Int) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        guard frames <= count else { return nil }
        var out = [Float](repeating: 0, count: frames)
        let firstChunk = min(frames, capacity - tail)
        out.withUnsafeMutableBufferPointer { ptr in
            ptr.baseAddress?.update(from: buffer.advanced(by: tail), count: firstChunk)
            if frames > firstChunk {
                ptr.baseAddress?.advanced(by: firstChunk).update(from: buffer, count: frames - firstChunk)
            }
        }
        return out
    }

    private static func nextPowerOfTwo(_ n: Int) -> Int {
        var v = n - 1
        v |= v >> 1
        v |= v >> 2
        v |= v >> 4
        v |= v >> 8
        v |= v >> 16
        v += 1
        return max(v, 512)
    }
}
