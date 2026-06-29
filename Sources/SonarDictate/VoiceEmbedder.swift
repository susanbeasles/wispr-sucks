import Accelerate
import CoreML
import Foundation

// On-device speaker embedding (tier 2). Reproduces SpeechBrain's Fbank EXACTLY (the
// constants - mel matrix + window + params - are dumped from the same SpeechBrain
// objects, see tools/voiceprint) then runs the CoreML ECAPA model to a 192-dim
// L2-normalized embedding. Single mic, no system-audio grant: only the local model.
//
// Validated bit-for-bit against tools/voiceprint golden vectors by `sonar-dictate
// voicetest`: Swift Fbank(audio) == SpeechBrain feats, and the CoreML embedding
// matches the PyTorch proof (separation gap 0.359). See
// .agent/plans/2026-06-29-124654-tier2-voiceprint-lock.md.

@available(macOS 14.0, *)
final class VoiceEmbedder {
    struct Constants: Decodable {
        let winLength: Int
        let hopLength: Int
        let nFft: Int
        let nStft: Int
        let nMels: Int
        let sampleRate: Int
        let logMultiplier: Float
        let amin: Float
        let topDb: Float
        let window: [Float]
        let melMatrixShape: [Int]   // [nStft, nMels]
        let melMatrix: [Float]      // row-major nStft x nMels
    }

    enum EmbedderError: Error, CustomStringConvertible {
        case resourceMissing(String)
        case modelLoad(String)
        var description: String {
            switch self {
            case .resourceMissing(let r): return "voiceprint resource missing: \(r)"
            case .modelLoad(let m): return "voiceprint model load failed: \(m)"
            }
        }
    }

    private let c: Constants
    private let model: MLModel
    // DFT matrices: [nStft x winLength], so re = cosM * windowedFrame, im = sinM * ...
    private let cosM: [Float]
    private let sinM: [Float]

    init() throws {
        guard let cURL = Bundle.module.url(forResource: "fbank_constants", withExtension: "json", subdirectory: "voiceprint") else {
            throw EmbedderError.resourceMissing("fbank_constants.json")
        }
        self.c = try JSONDecoder().decode(Constants.self, from: Data(contentsOf: cURL))

        // Precompute the real DFT basis for a winLength-point transform truncated to
        // nStft onesided bins (winLength is not a vDSP.DFT-supported size).
        let W = c.winLength, K = c.nStft
        var cm = [Float](repeating: 0, count: K * W)
        var sm = [Float](repeating: 0, count: K * W)
        for k in 0..<K {
            let f = -2.0 * Float.pi * Float(k) / Float(c.nFft)
            for j in 0..<W {
                cm[k * W + j] = cos(f * Float(j))
                sm[k * W + j] = sin(f * Float(j))
            }
        }
        self.cosM = cm
        self.sinM = sm

        self.model = try Self.loadModel()
    }

    // Compile the bundled .mlpackage once, cache the compiled .mlmodelc under the app
    // support dir so later launches skip recompilation, and load it.
    private static func loadModel() throws -> MLModel {
        guard let pkg = Bundle.module.url(forResource: "ECAPA_TDNN", withExtension: "mlpackage", subdirectory: "voiceprint") else {
            throw EmbedderError.resourceMissing("ECAPA_TDNN.mlpackage")
        }
        let cached = SecureStore.baseDir.appendingPathComponent("voiceprint/ECAPA_TDNN.mlmodelc", isDirectory: true)
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        if FileManager.default.fileExists(atPath: cached.path) {
            if let m = try? MLModel(contentsOf: cached, configuration: cfg) { return m }
        }
        do {
            let compiled = try MLModel.compileModel(at: pkg)
            try? FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: cached)
            try FileManager.default.copyItem(at: compiled, to: cached)
            return try MLModel(contentsOf: cached, configuration: cfg)
        } catch {
            throw EmbedderError.modelLoad(error.localizedDescription)
        }
    }

    // MARK: - public

    // Mono audio (any length >= one frame) -> 192-dim L2-normalized embedding.
    func embed(_ audio: [Float]) throws -> [Float] {
        let feats = fbank(audio)
        return try embedFeats(feats, frames: feats.count / c.nMels)
    }

    // Embed precomputed [T, nMels] row-major feats (also used by voicetest to feed
    // the golden feats and isolate the CoreML io from the Swift Fbank).
    func embedFeats(_ feats: [Float], frames T: Int) throws -> [Float] {
        guard T > 0 else { return [] }
        let arr = try MLMultiArray(shape: [1, NSNumber(value: T), NSNumber(value: c.nMels)], dataType: .float32)
        let p = arr.dataPointer.bindMemory(to: Float.self, capacity: feats.count)
        feats.withUnsafeBufferPointer { p.update(from: $0.baseAddress!, count: feats.count) }
        let input = try MLDictionaryFeatureProvider(dictionary: ["feats": MLFeatureValue(multiArray: arr)])
        let out = try model.prediction(from: input)
        guard let emb = out.featureValue(for: "embedding")?.multiArrayValue else {
            throw EmbedderError.modelLoad("no embedding output")
        }
        var v = [Float](repeating: 0, count: emb.count)
        let ep = emb.dataPointer.bindMemory(to: Float.self, capacity: emb.count)
        for i in 0..<emb.count { v[i] = ep[i] }
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        norm = max(norm.squareRoot(), 1e-12)
        var inv = 1 / norm
        vDSP_vsmul(v, 1, &inv, &v, 1, vDSP_Length(v.count))
        return v
    }

    // Cosine similarity of two L2-normalized embeddings (just a dot product).
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var d: Float = 0
        vDSP_dotpr(a, 1, b, 1, &d, vDSP_Length(a.count))
        return d
    }

    // MARK: - Fbank (matches SpeechBrain spectral_magnitude(power=1) + Filterbank)

    // Returns [T, nMels] row-major log-mel feats with sentence mean-normalization.
    func fbank(_ audio: [Float]) -> [Float] {
        let W = c.winLength, H = c.hopLength, K = c.nStft, M = c.nMels
        let pad = c.nFft / 2

        // center pad: nFft/2 zeros each side (torch.stft center=True, pad_mode constant)
        var sig = [Float](repeating: 0, count: audio.count + 2 * pad)
        for i in 0..<audio.count { sig[pad + i] = audio[i] }
        let T = 1 + (sig.count - W) / H
        guard T > 0 else { return [] }

        var feats = [Float](repeating: 0, count: T * M)
        var frame = [Float](repeating: 0, count: W)
        var re = [Float](repeating: 0, count: K)
        var im = [Float](repeating: 0, count: K)
        var power = [Float](repeating: 0, count: K)

        for t in 0..<T {
            let off = t * H
            // windowed frame
            sig.withUnsafeBufferPointer { sp in
                c.window.withUnsafeBufferPointer { wp in
                    vDSP_vmul(sp.baseAddress! + off, 1, wp.baseAddress!, 1, &frame, 1, vDSP_Length(W))
                }
            }
            // re = cosM[KxW] * frame[W], im = sinM * frame  (real DFT, onesided)
            cosM.withUnsafeBufferPointer { cmp in
                frame.withUnsafeBufferPointer { fp in
                    vDSP_mmul(cmp.baseAddress!, 1, fp.baseAddress!, 1, &re, 1, vDSP_Length(K), 1, vDSP_Length(W))
                }
            }
            sinM.withUnsafeBufferPointer { smp in
                frame.withUnsafeBufferPointer { fp in
                    vDSP_mmul(smp.baseAddress!, 1, fp.baseAddress!, 1, &im, 1, vDSP_Length(K), 1, vDSP_Length(W))
                }
            }
            // power spectrogram = re^2 + im^2
            vDSP_vsq(re, 1, &re, 1, vDSP_Length(K))
            vDSP_vsq(im, 1, &im, 1, vDSP_Length(K))
            vDSP_vadd(re, 1, im, 1, &power, 1, vDSP_Length(K))
            // mel: power[1xK] * melMatrix[KxM] -> mel[1xM]
            power.withUnsafeBufferPointer { pp in
                melMatrix.withUnsafeBufferPointer { mp in
                    var mel = [Float](repeating: 0, count: M)
                    vDSP_mmul(pp.baseAddress!, 1, mp.baseAddress!, 1, &mel, 1, 1, vDSP_Length(M), vDSP_Length(K))
                    for m in 0..<M { feats[t * M + m] = mel[m] }
                }
            }
        }

        // log10 with amin clamp, scaled by multiplier
        var maxDb = -Float.greatestFiniteMagnitude
        for i in 0..<feats.count {
            let v = max(feats[i], c.amin)
            let db = c.logMultiplier * log10(v)
            feats[i] = db
            if db > maxDb { maxDb = db }
        }
        // per-utterance top_db clamp, then sentence mean-norm (per mel over time)
        let floorDb = maxDb - c.topDb
        for i in 0..<feats.count where feats[i] < floorDb { feats[i] = floorDb }
        for m in 0..<M {
            var mean: Float = 0
            for t in 0..<T { mean += feats[t * M + m] }
            mean /= Float(T)
            for t in 0..<T { feats[t * M + m] -= mean }
        }
        return feats
    }

    private var melMatrix: [Float] { c.melMatrix }
}
