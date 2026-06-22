import Foundation

// The mandatory PHI gate in front of ingestion, bridged to the canonical masker
// (~/code/phi-mask). This is the prod Scrubber - IdentityScrubber is only a test
// double. Text is passed on STDIN (never argv - PHI must not land in the process
// list), masked, and returned.
//
// FAIL-CLOSED: on any failure (masker missing, non-zero exit, empty output) it
// returns fully-redacted text, NEVER the original - matching phi-mask's own
// contract. A broken gate drops the data; it never leaks it.
struct PhiMaskScrubber: Scrubber {
    let dir: String   // the phi-mask package dir (the one containing `phimask/`)

    // Honors IRIS_PHIMASK_DIR; falls back to ~/code/phi-mask.
    init(dir: String? = nil) {
        self.dir = dir
            ?? ProcessInfo.processInfo.environment["IRIS_PHIMASK_DIR"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("code/phi-mask")
    }

    func scrub(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-c",
            "import sys; from phimask import mask; sys.stdout.write(mask(sys.stdin.read()).text)"]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = dir
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            inPipe.fileHandleForWriting.write(Data(text.utf8))
            inPipe.fileHandleForWriting.closeFile()
            let out = outPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0,
                  let masked = String(data: out, encoding: .utf8), !masked.isEmpty else {
                return Self.redacted
            }
            return masked
        } catch {
            return Self.redacted
        }
    }

    // Mask many texts in ONE python invocation (JSON array in, JSON array out) -
    // for bulk sources, so a first sync does not spawn a process per message.
    // FAIL-CLOSED: any failure or a count mismatch returns all-redacted.
    func scrubBatch(_ texts: [String]) -> [String] {
        guard !texts.isEmpty else { return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-c",
            "import sys, json; from phimask import mask; "
            + "sys.stdout.write(json.dumps([mask(t).text for t in json.load(sys.stdin)]))"]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = dir
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        let allRedacted = texts.map { _ in Self.redacted }
        do {
            try p.run()
            let input = try JSONSerialization.data(withJSONObject: texts)
            inPipe.fileHandleForWriting.write(input)
            inPipe.fileHandleForWriting.closeFile()
            let out = outPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0,
                  let arr = try? JSONSerialization.jsonObject(with: out) as? [String],
                  arr.count == texts.count else {
                return allRedacted
            }
            return arr
        } catch {
            return allRedacted
        }
    }

    // Emitted when masking fails - never the original input.
    static let redacted = "[REDACTED]"
}
