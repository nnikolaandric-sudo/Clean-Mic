import Foundation

/// Vrijednost zaštićena lockom — za rezultate koje pune pozadinske niti.
final class LockedBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()

    init(_ value: T) { self.value = value }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }

    var get: T { withLock { $0 } }
}

enum Parallel {
    /// Pokreće `body(i)` za i u 0..<count, najviše `maxConcurrent` odjednom,
    /// i vraća rezultate po redu. Blokira pozivaoca — ne zvati sa glavne niti GUI-ja.
    ///
    /// Prva greška zaustavlja zakazivanje novih poslova i baca se kad tekući završe.
    static func map<T>(count: Int, maxConcurrent: Int, _ body: @escaping (Int) throws -> T) throws -> [T] {
        guard count > 0 else { return [] }
        let results = LockedBox([T?](repeating: nil, count: count))
        let firstError = LockedBox<Error?>(nil)
        let gate = DispatchSemaphore(value: max(1, maxConcurrent))
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "cleanmic.parallel", qos: .userInitiated, attributes: .concurrent)

        for i in 0..<count {
            gate.wait()
            if firstError.get != nil {
                gate.signal()
                break
            }
            group.enter()
            queue.async {
                defer {
                    gate.signal()
                    group.leave()
                }
                do {
                    let r = try body(i)
                    results.withLock { $0[i] = r }
                } catch {
                    firstError.withLock { if $0 == nil { $0 = error } }
                }
            }
        }
        group.wait()
        if let error = firstError.get { throw error }
        return results.get.compactMap { $0 }
    }
}
