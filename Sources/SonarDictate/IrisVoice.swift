import Foundation

// Iris's voice. She speaks her chat replies aloud through her OWN neural voice -
// voice/iris_voice.py, a unique Kokoro blend, fully on-device (see iris-handoff).
//
// This is a thin, best-effort bridge: it shells out to that script and lets it
// render + play. If her voice is not set up yet (deps not installed, script
// missing), every call is a SILENT no-op - she simply does not speak until her
// voice exists. It never throws and never blocks the UI; speech runs off-thread,
// serialized so two replies never talk over each other (the script renders to one
// shared out.wav).
enum IrisVoice {
    private static let queue = DispatchQueue(label: "sonar-dictate.voice", qos: .userInitiated)
    private static var warnedMissing = false

    // Where her voice lives. Honors IRIS_VOICE_DIR; falls back to the repo voice/.
    private static var voiceDir: String {
        if let env = ProcessInfo.processInfo.environment["IRIS_VOICE_DIR"], !env.isEmpty {
            return env
        }
        return "/Users/avespoli/code/sonar-dictate/voice"
    }

    private static var pythonPath: String { voiceDir + "/.venv/bin/python" }
    private static var scriptPath: String { voiceDir + "/iris_voice.py" }

    // Available once the venv python and her script both exist. (The deps inside
    // the venv are the user's one-time install; if they are missing the script
    // exits non-zero and she just stays quiet - still safe.)
    static var isAvailable: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: pythonPath) && fm.fileExists(atPath: scriptPath)
    }

    // Speak text aloud (best-effort, async, serialized). No-op if unavailable or
    // empty.
    static func speak(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        guard isAvailable else {
            if !warnedMissing {
                warnedMissing = true
                NSLog("SonarDictate: Iris voice not set up (\(scriptPath)); silent until installed")
            }
            return
        }
        queue.async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: pythonPath)
            p.arguments = [scriptPath, t]
            p.currentDirectoryURL = URL(fileURLWithPath: voiceDir)
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do {
                try p.run()
                p.waitUntilExit()   // hold the serial slot until playback finishes
            } catch {
                NSLog("SonarDictate: Iris voice failed: \(error)")
            }
        }
    }
}
