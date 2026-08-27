import XCTest
@testable import CleanMicCore

final class CleanMicTests: XCTestCase {
    func testRingBufferWriteRead() {
        let ring = RingBuffer(capacityFrames: 1024)
        let data: [Float] = [1,2,3,4,5]
        XCTAssertTrue(ring.write(data))
        XCTAssertEqual(ring.availableRead, 5)
        var out = [Float](repeating: 0, count: 5)
        XCTAssertTrue(ring.read(into: &out, frames: 5))
        XCTAssertEqual(out, data)
    }

    func testNoiseProcessor() {
        let proc = NoiseProcessor(mode: .balanced)
        let input = [Float](repeating: 0.1, count: 480)
        let (out, vad) = proc.process(input: input)
        XCTAssertEqual(out.count, 480)
        XCTAssertTrue(vad >= 0 && vad <= 1)
    }
}
