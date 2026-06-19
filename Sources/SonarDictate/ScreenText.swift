import CoreGraphics
import Vision

// The eyes' OCR stage: a CGImage of the watched region -> the readable text on
// it, in reading order. On-device (Vision framework), no network.
//
// PHI: input is the user's screen and the output text can be PHI. It stays in
// memory and is handed to the delta gate / reasoner; never written in cleartext.
enum ScreenText {
    // Returns the recognized text (newline-joined lines), or "" on failure - the
    // loop treats empty as "nothing readable this tick".
    static func recognize(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }
        guard let results = request.results else { return "" }

        var lines: [String] = []
        lines.reserveCapacity(results.count)
        for observation in results {
            if let best = observation.topCandidates(1).first {
                lines.append(best.string)
            }
        }
        return lines.joined(separator: "\n")
    }
}
