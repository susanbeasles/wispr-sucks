import Foundation
import NaturalLanguage

// On-device sentence embedding, extracted from RAGIndex so the dictation RAG and
// the eyes' perception memory share ONE embedding implementation.
//
// NLContextualEmbedding (macOS 14+, free, on-device) produces a vector per token;
// we mean-pool into one document vector. Assets are provisioned opportunistically
// by the OS - gate on assetsReady and no-op until the model is loaded.
final class TextEmbedder {
    private let embedding: NLContextualEmbedding

    init() throws {
        guard let emb = NLContextualEmbedding(language: .english) else {
            throw RAGError.embeddingUnavailable
        }
        try? emb.load()
        self.embedding = emb
    }

    var assetsReady: Bool { embedding.hasAvailableAssets }

    func vector(for text: String) throws -> [Double] {
        guard embedding.hasAvailableAssets else { throw RAGError.embeddingAssetsNotReady }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RAGError.embeddingFailed }

        let result = try embedding.embeddingResult(for: trimmed, language: .english)
        var sum: [Double] = []
        var n = 0
        result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { vec, _ in
            if sum.isEmpty { sum = Array(repeating: 0, count: vec.count) }
            for i in 0..<min(sum.count, vec.count) { sum[i] += vec[i] }
            n += 1
            return true
        }
        guard n > 0 else { throw RAGError.embeddingFailed }
        for i in 0..<sum.count { sum[i] /= Double(n) }
        return sum
    }

    // Cosine similarity in [-1, 1]. Shared by every vector store.
    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        let len = min(a.count, b.count)
        guard len > 0 else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<len {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (sqrt(na) * sqrt(nb))
    }
}
