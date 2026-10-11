import Foundation
import NaturalLanguage

/// A small vector index for finding passages by meaning.
///
/// Each passage becomes a list of numbers from Apple's on-device text model
/// (`NLContextualEmbedding`, macOS 14 and later). Passages about the same idea
/// end up close together even when they share no words. On its own this model is
/// noisy, so `Brain` never trusts it alone: its ranking is fused with the keyword
/// ranking, and each one covers for the other's misses.

enum VectorMath {
    /// The average of the non-empty vectors. Subtracting it removes what every
    /// passage has in common, which is most of what this model returns.
    static func centre(_ vectors: [[Float]]) -> [Float] {
        guard let size = vectors.first(where: { !$0.isEmpty })?.count else { return [] }
        var mean = [Float](repeating: 0, count: size)
        var count: Float = 0
        for v in vectors where v.count == size {
            for i in 0..<size { mean[i] += v[i] }
            count += 1
        }
        return count > 0 ? mean.map { $0 / count } : mean
    }

    /// `v` with `mean` taken away, scaled to length one. Empty stays empty.
    static func unit(_ v: [Float], minus mean: [Float]) -> [Float] {
        guard !v.isEmpty, v.count == mean.count else { return [] }
        var out = [Float](repeating: 0, count: v.count)
        var total: Float = 0
        for i in 0..<v.count { out[i] = v[i] - mean[i]; total += out[i] * out[i] }
        let length = total.squareRoot()
        return length > 1e-9 ? out.map { $0 / length } : []
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var sum: Float = 0
        for i in 0..<a.count { sum += a[i] * b[i] }
        return sum
    }

    /// Reciprocal rank fusion: one ranking out of several. An item scores
    /// 1 / (k + its place) in each list it appears in, so being high in either
    /// list counts and being high in both counts most.
    static func fuse(_ lists: [[Int]], k: Double = 60) -> [(index: Int, score: Double)] {
        var scores: [Int: Double] = [:]
        for list in lists {
            for (place, item) in list.enumerated() { scores[item, default: 0] += 1 / (k + Double(place + 1)) }
        }
        return scores.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { (index: $0.key, score: $0.value) }
    }
}

/// Turns text into a vector with the system's text model. Returns an empty
/// vector where the model is missing, so callers fall back to keywords.
enum Embedder {
    private static let lock = NSLock()
    private static var loaded = false
    private static var model: AnyObject?

    static var dimension: Int {
        if #available(macOS 14.0, *) { return (prepare() as? NLContextualEmbedding)?.dimension ?? 0 }
        return 0
    }

    static var available: Bool { dimension > 0 }

    private static func prepare() -> AnyObject? {
        lock.lock(); defer { lock.unlock() }
        if loaded { return model }
        loaded = true
        if #available(macOS 14.0, *), let m = NLContextualEmbedding(language: .english), m.hasAvailableAssets {
            if (try? m.load()) != nil { model = m }
        }
        return model
    }

    static func vector(_ text: String) -> [Float] {
        guard #available(macOS 14.0, *), let m = prepare() as? NLContextualEmbedding else { return [] }
        let clipped = String(text.prefix(1200))
        guard !clipped.isEmpty, let result = try? m.embeddingResult(for: clipped, language: .english) else { return [] }
        var sum = [Float](repeating: 0, count: m.dimension)
        var count: Float = 0
        result.enumerateTokenVectors(in: clipped.startIndex..<clipped.endIndex) { v, _ in
            for i in 0..<min(v.count, sum.count) { sum[i] += Float(v[i]) }
            count += 1
            return true
        }
        return count > 0 ? sum.map { $0 / count } : []
    }
}

/// Vectors for a fixed set of passages, in the same order as the passages.
struct VectorIndex {
    private let vectors: [[Float]]
    private let mean: [Float]

    /// `raw` holds one vector per passage, empty where none could be made.
    init(raw: [[Float]]) {
        let centre = VectorMath.centre(raw)
        mean = centre
        vectors = raw.map { VectorMath.unit($0, minus: centre) }
    }

    var count: Int { vectors.filter { !$0.isEmpty }.count }

    /// The passages nearest in meaning to `query` (a raw vector), nearest first,
    /// leaving out any below `floor` and any `allowed` rejects.
    func nearest(_ query: [Float], limit: Int, floor: Float = 0.3, allowed: (Int) -> Bool = { _ in true }) -> [(index: Int, score: Float)] {
        let q = VectorMath.unit(query, minus: mean)
        guard !q.isEmpty else { return [] }
        var hits: [(Int, Float)] = []
        for (i, v) in vectors.enumerated() where !v.isEmpty && allowed(i) {
            let s = VectorMath.dot(q, v)
            if s >= floor { hits.append((i, s)) }
        }
        hits.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        return hits.prefix(limit).map { (index: $0.0, score: $0.1) }
    }

    // MARK: Disk

    /// Vectors are kept beside the passage cache as raw 32-bit floats.
    static func read(_ url: URL, count: Int, dimension: Int) -> [[Float]]? {
        guard dimension > 0, let data = try? Data(contentsOf: url),
              data.count == count * dimension * MemoryLayout<Float>.size else { return nil }
        return data.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            return (0..<count).map { Array(floats[($0 * dimension)..<(($0 + 1) * dimension)]) }
        }
    }

    static func write(_ vectors: [[Float]], to url: URL, dimension: Int) {
        var flat = [Float]()
        flat.reserveCapacity(vectors.count * dimension)
        for v in vectors { flat.append(contentsOf: v.count == dimension ? v : [Float](repeating: 0, count: dimension)) }
        let data = flat.withUnsafeBufferPointer { Data(buffer: $0) }
        try? data.write(to: url, options: .atomic)
    }
}
